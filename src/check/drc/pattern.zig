//! Pattern family: a deck-supplied window of shapes found wherever the
//! layout matches it exactly, in any of the eight orientations. In: one
//! rectilinear layer and a pattern (window, shapes, don't-care boxes). Out:
//! one violation per distinct matching window placement. Exact on the grid.
//! Ported from crates/check/src/drc/rules/pattern.rs and
//! crates/check/src/drc/ruleset.rs (`Pattern::is_valid`, `Pattern::anchor`).
//!
//! Contents:
//! - `pub fn isValid(gpa: Allocator, window: [2]Dbu, shapes: []const Bbox, ignore: []const Bbox) Error!bool`
//! - `pub fn anchorOf(gpa: Allocator, window: [2]Dbu, shapes: []const Bbox, ignore: []const Bbox) Error!?[2]i64`
//! - `pub fn patternMatch(c: *const Ctx, r: PatternMatch) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const rects = @import("../rects.zig");
const Verdict = report.Verdict;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

/// A positive window, every shape and don't-care box a rectangle with
/// positive sides inside it, and an anchor for the shapes.
pub fn isValid(gpa: Allocator, window: [2]Dbu, shapes: []const Bbox, ignore: []const Bbox) Error!bool {
    if (window[0] <= 0 or window[1] <= 0 or shapes.len == 0) return false;
    for ([2][]const Bbox{ shapes, ignore }) |list| for (list) |b| {
        if (!(b.xlo < b.xhi and b.ylo < b.yhi and b.xlo >= 0 and b.ylo >= 0 and b.xhi <= window[0] and b.yhi <= window[1])) return false;
    };
    return try anchorOf(gpa, window, shapes, ignore) != null;
}

/// The least `(x, y)` corner of the merged shapes strictly inside the window
/// and in no don't-care box (edges included): a match puts a corner of the
/// layout there, so only the layout's corners need trying.
pub fn anchorOf(gpa: Allocator, window: [2]Dbu, shapes: []const Bbox, ignore: []const Bbox) Error!?[2]i64 {
    var merged: ValidatedLayer = .empty;
    defer merged.deinit(gpa);
    try region(gpa, shapes, &merged);
    var best: ?[2]i64 = null;
    for (0..merged.len()) |idx| {
        const poly = merged.get(@intCast(idx));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            for (ring.xs, ring.ys) |x, y| {
                if (!(x > 0 and y > 0 and x < window[0] and y < window[1])) continue;
                const ignored = for (ignore) |b| {
                    if (b.xlo <= x and x <= b.xhi and b.ylo <= y and y <= b.yhi) break true;
                } else false;
                if (ignored) continue;
                if (best == null or x < best.?[0] or (x == best.?[0] and y < best.?[1])) best = .{ x, y };
            }
        }
    }
    return best;
}

/// Every placement of the pattern: each orientation with its anchor on a
/// corner of the merged layer, where the layer clipped to the placed window
/// equals the placed shapes outside the placed don't-care boxes. One
/// violation per distinct window, at its centre, measuring the shapes'
/// area, naming no shape. `examined` counts placements tried.
// ponytail: every corner in every orientation, each verified by booleans
// over the whole layer; index the layer's rectangles by window if a large
// layout makes this slow.
pub fn patternMatch(c: *const Ctx, r: rows.PatternMatch) Error!Verdict {
    const gpa = c.gpa;
    const window = c.rs.pattern_window.items[r.pattern];
    const shapes = c.rs.pattern_shapes.get(r.pattern);
    const ignore = c.rs.pattern_ignore.get(r.pattern);
    const drawn = try c.s.p.validated.get(gpa, c.store, r.layer) orelse return report.refused;
    var figures: ValidatedLayer = .empty;
    defer figures.deinit(gpa);
    try geom.derive.mergeInto(gpa, drawn, &figures);
    const anchor = try anchorOf(gpa, window, shapes, ignore) orelse return report.refused;
    var corners: std.ArrayList([2]i64) = .empty;
    defer corners.deinit(gpa);
    for (0..figures.len()) |idx| {
        const poly = figures.get(@intCast(idx));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            for (ring.xs, ring.ys) |x, y| try corners.append(gpa, .{ x, y });
        }
    }
    const frame: Bbox = .{ .xlo = 0, .ylo = 0, .xhi = window[0], .yhi = window[1] };
    var shape_layer: ValidatedLayer = .empty;
    defer shape_layer.deinit(gpa);
    try region(gpa, shapes, &shape_layer);
    const shape_area = try areaOf(gpa, &shape_layer);
    var found: std.ArrayList(Bbox) = .empty;
    defer found.deinit(gpa);
    var placed_shapes: std.ArrayList(Bbox) = .empty;
    defer placed_shapes.deinit(gpa);
    var placed_ignore: std.ArrayList(Bbox) = .empty;
    defer placed_ignore.deinit(gpa);
    var examined: u64 = 0;
    for (0..8) |o| {
        const a = orient(@intCast(o), anchor);
        for (corners.items) |v| {
            examined += 1;
            const shift: [2]i64 = .{ v[0] - a[0], v[1] - a[1] };
            const placed_window = placed(@intCast(o), frame, shift);
            const seen = for (found.items) |f| {
                if (std.meta.eql(f, placed_window)) break true;
            } else false;
            if (seen) continue;
            try placedInto(gpa, @intCast(o), shapes, shift, &placed_shapes);
            try placedInto(gpa, @intCast(o), ignore, shift, &placed_ignore);
            if (try matches(gpa, &figures, placed_window, placed_shapes.items, placed_ignore.items)) try found.append(gpa, placed_window);
        }
    }
    std.mem.sortUnstable(Bbox, found.items, {}, lessBox);
    for (found.items) |b| try c.push(.{
        .rule = c.rule,
        .layer = r.layer,
        .severity = .@"error",
        .at = rects.centre(b),
        .measured = .area(shape_area),
        .limit = .area(0),
        .shape_a = report.no_shape,
        .shape_b = report.no_shape,
    });
    return scratch.ran(examined);
}

// ---- private ----

/// `p` under orientation `o` (0 to 7): mirrored in the y axis when `o >=
/// 4`, then turned `o % 4` quarter turns counter-clockwise.
fn orient(o: u8, p: [2]i64) [2]i64 {
    var x = if (o >= 4) -p[0] else p[0];
    var y = p[1];
    for (0..o % 4) |_| {
        const t = x;
        x = -y;
        y = t;
    }
    return .{ x, y };
}

/// `b` under orientation `o`, then moved by `shift`.
fn placed(o: u8, b: Bbox, shift: [2]i64) Bbox {
    const p = orient(o, .{ b.xlo, b.ylo });
    const q = orient(o, .{ b.xhi, b.yhi });
    return .{ .xlo = @min(p[0], q[0]) + shift[0], .ylo = @min(p[1], q[1]) + shift[1], .xhi = @max(p[0], q[0]) + shift[0], .yhi = @max(p[1], q[1]) + shift[1] };
}

fn placedInto(gpa: Allocator, o: u8, boxes: []const Bbox, shift: [2]i64, out: *std.ArrayList(Bbox)) Allocator.Error!void {
    try out.resize(gpa, boxes.len);
    for (out.items, boxes) |*p, b| p.* = placed(o, b, shift);
}

/// The merged region of `boxes`.
fn region(gpa: Allocator, boxes: []const Bbox, out: *ValidatedLayer) Error!void {
    var raw: ValidatedLayer = .empty;
    defer raw.deinit(gpa);
    try scratch.boxesLayer(gpa, boxes, &raw);
    try geom.derive.mergeInto(gpa, &raw, out);
}

fn areaOf(gpa: Allocator, layer: *const ValidatedLayer) Allocator.Error!DbuArea {
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, layer, &boxes, &start);
    return geom.rects.coveredArea(boxes.items);
}

/// Whether `figures` clipped to `window` equals `shapes`, both outside the
/// don't-care boxes: their symmetric difference there has no area.
fn matches(gpa: Allocator, figures: *const ValidatedLayer, window: Bbox, shapes: []const Bbox, ignore: []const Bbox) Error!bool {
    var frame: ValidatedLayer = .empty;
    defer frame.deinit(gpa);
    try scratch.boxesLayer(gpa, &.{window}, &frame);
    var clipped: ValidatedLayer = .empty;
    defer clipped.deinit(gpa);
    try geom.boolean.intersectionInto(gpa, figures, &frame, &clipped);
    var ignored: ValidatedLayer = .empty;
    defer ignored.deinit(gpa);
    try region(gpa, ignore, &ignored);
    var wanted: ValidatedLayer = .empty;
    defer wanted.deinit(gpa);
    try region(gpa, shapes, &wanted);
    var have: ValidatedLayer = .empty;
    defer have.deinit(gpa);
    try geom.boolean.subtractionInto(gpa, &clipped, &ignored, &have);
    var want: ValidatedLayer = .empty;
    defer want.deinit(gpa);
    try geom.boolean.subtractionInto(gpa, &wanted, &ignored, &want);
    var both: ValidatedLayer = .empty;
    defer both.deinit(gpa);
    try geom.boolean.intersectionInto(gpa, &have, &want, &both);
    const common = try areaOf(gpa, &both);
    return try areaOf(gpa, &have) == common and try areaOf(gpa, &want) == common;
}

fn lessBox(_: void, a: Bbox, b: Bbox) bool {
    const ka = [4]i64{ a.xlo, a.ylo, a.xhi, a.yhi };
    const kb = [4]i64{ b.xlo, b.ylo, b.xhi, b.yhi };
    return std.mem.order(i64, &ka, &kb) == .lt;
}
