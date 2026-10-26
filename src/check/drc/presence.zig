//! Presence family: what must not exist, and what must hold or lie inside
//! what. In: one or two validated layers, merged (touching shapes are one),
//! except that `forbidden` reports shapes as drawn. Out: one violation per
//! offending shape, figure or edge. Ported from
//! crates/check/src/drc/rules/presence.rs (`forbidden`, `must_contain`,
//! `must_be_inside`, `hosts`, `inside_point`, `count_broken`); the
//! containment kernel itself is `proximity_inside.zig`'s.
//!
//! Contents:
//! - `pub fn forbidden(c: *const Ctx, r: LayerOnly) Error!Verdict`
//! - `pub fn mustContain(c: *const Ctx, r: MustContain) Error!Verdict`
//! - `pub fn mustBeInside(c: *const Ctx, r: MustBeInside) Error!Verdict`
//! - `pub const Cut = struct`, `Cut.deinit`, `Cut.of(c, gpa: Allocator, figures: *const ValidatedLayer) Allocator.Error!void`,
//!   `Cut.figure(c, f: u32) []const Bbox`, `Cut.count(c) u32`
//! - `pub fn hostsInto(gpa: Allocator, inner: *const Cut, outer: *const Cut, home: []?u32) Allocator.Error!void`
//! - `Everyone.judge(_: Everyone, _: PolyId) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const PolyId = geom.PolyId;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const proximity_inside = @import("../proximity_inside.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

/// A merged layer's rectangles, CSR by figure.
pub const Cut = struct {
    rects: std.ArrayList(Bbox) = .empty,
    start: std.ArrayList(u32) = .empty,

    pub fn deinit(c: *Cut, gpa: Allocator) void {
        c.rects.deinit(gpa);
        c.start.deinit(gpa);
    }

    pub fn of(c: *Cut, gpa: Allocator, figures: *const ValidatedLayer) Allocator.Error!void {
        try geom.rects.decomposeInto(gpa, figures, &c.rects, &c.start);
    }

    pub fn figure(c: *const Cut, f: u32) []const Bbox {
        return c.rects.items[c.start.items[f]..c.start.items[f + 1]];
    }

    pub fn count(c: *const Cut) u32 {
        return @intCast(c.start.items.len -| 1);
    }
};

/// Judges every figure.
const Everyone = struct {
    pub fn judge(_: Everyone, _: PolyId) bool {
        return true;
    }
};

/// Every shape on the layer, as drawn (its area, floored), and every edge
/// of an edge layer (its length, floored). `examined` counts both.
pub fn forbidden(c: *const Ctx, r: rows.LayerOnly) Error!Verdict {
    const drawn = try c.s.p.validated.getAny(c.gpa, c.store, r.layer) orelse return report.refused;
    for (0..drawn.len()) |idx| {
        const poly = drawn.get(@intCast(idx));
        var twice: i128 = 0;
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            twice += geom.ops.area2(ring.xs, ring.ys);
        }
        const outer = poly.outer();
        try c.finding(r.layer, .{ .x = outer.xs[0], .y = outer.ys[0] }, .area(@divTrunc(twice, 2)), .area(0), poly.provenance());
    }
    const edges = c.store.edgesOnLayer(r.layer);
    for (edges) |e| {
        const b = rects.segBbox(e);
        const d = geom.ops.isqrt(geom.mulWide(b.xhi - b.xlo, b.xhi - b.xlo) + geom.mulWide(b.yhi - b.ylo, b.yhi - b.ylo));
        try c.finding(r.layer, geom.ops.centre(b), .length(d), .length(0), report.no_shape);
    }
    return scratch.ran(@as(u64, drawn.len()) + edges.len);
}

/// Each merged `outer` figure must hold between `min_count` and `max_count`
/// merged `inner` figures entirely (licon.16, rpm.1g); one straddling the
/// outer's edge is not held. `examined` counts outer figures.
pub fn mustContain(c: *const Ctx, r: rows.MustContain) Error!Verdict {
    const gpa = c.gpa;
    const s = &c.s.p;
    const a = try s.validated.getAny(gpa, c.store, r.outer) orelse return report.refused;
    const b = try s.validated.getAny(gpa, c.store, r.inner) orelse return report.refused;
    var outer_figures: ValidatedLayer = .empty;
    defer outer_figures.deinit(gpa);
    var inner_figures: ValidatedLayer = .empty;
    defer inner_figures.deinit(gpa);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    var held: std.ArrayList(u32) = .empty;
    defer held.deinit(gpa);
    var at_of: std.ArrayList(geom.Point) = .empty;
    defer at_of.deinit(gpa);
    if (!(a.isRectilinear() and b.isRectilinear())) {
        try geom.derive.mergeInto(gpa, a, &outer_figures);
        try geom.derive.mergeInto(gpa, b, &inner_figures);
        try rects.ownersByPointInto(gpa, &outer_figures, a, &owners);
        // Held: an inner figure the outer covers, in the figure holding it.
        const covered = try gpa.alloc(bool, inner_figures.len());
        defer gpa.free(covered);
        try geom.derive.insideFlags(gpa, &inner_figures, &outer_figures, covered);
        const home = try gpa.alloc(?u32, inner_figures.len());
        defer gpa.free(home);
        try rects.figuresHolding(gpa, &outer_figures, &inner_figures, home);
        try held.appendNTimes(gpa, 0, outer_figures.len());
        for (home, covered) |h, cov| if (h) |host| if (cov) {
            held.items[host] += 1;
        };
        for (0..outer_figures.len()) |f| try at_of.append(gpa, rects.figurePoint(outer_figures.get(@intCast(f))));
    } else {
        if (!try proximity_inside.mergedInto(gpa, c.store, r.inner, s, &inner_figures)) return report.refused;
        if (!try proximity_inside.mergedInto(gpa, c.store, r.outer, s, &outer_figures)) return report.refused;
        var inner_cut: Cut = .{};
        defer inner_cut.deinit(gpa);
        try inner_cut.of(gpa, &inner_figures);
        var outer_cut: Cut = .{};
        defer outer_cut.deinit(gpa);
        try outer_cut.of(gpa, &outer_figures);
        const home = try gpa.alloc(?u32, inner_cut.count());
        defer gpa.free(home);
        try hostsInto(gpa, &inner_cut, &outer_cut, home);
        try held.appendNTimes(gpa, 0, outer_figures.len());
        for (home) |h| if (h) |host| {
            held.items[host] += 1;
        };
        try s.rects_a.build(gpa, c.store, r.outer, a);
        try rects.ownersOfInto(gpa, &outer_figures, &s.rects_a, &owners);
        for (0..outer_cut.count()) |f| try at_of.append(gpa, geom.ops.centre(outer_cut.figure(@intCast(f))[0]));
    }
    for (held.items, owners.items, at_of.items) |count, owner, at| {
        const broken = if (count < r.min_count) r.min_count else if (count > r.max_count) r.max_count else continue;
        try c.finding(r.outer, at, .count(count), .count(broken), owner);
    }
    return scratch.ran(held.items.len);
}

/// Each merged `inner` figure must lie entirely inside `outer`, touching its
/// edge from inside allowed (licon.18); reports the area left outside.
/// `examined` counts inner figures.
pub fn mustBeInside(c: *const Ctx, r: rows.MustBeInside) Error!Verdict {
    return proximity_inside.insideWhere(c.gpa, c.store, c.rule, r.inner, r.outer, &c.s.p, c.out, Everyone{});
}

/// Per inner figure, into `home`: the outer figure covering all of it, or
/// null. Outer figures share no area, so a covered inner figure lies in
/// exactly one.
pub fn hostsInto(gpa: Allocator, inner: *const Cut, outer: *const Cut, home: []?u32) Allocator.Error!void {
    assert(home.len == inner.count());
    const labels = try gpa.alloc(u32, outer.rects.items.len);
    defer gpa.free(labels);
    for (0..outer.count()) |f| @memset(labels[outer.start.items[f]..outer.start.items[f + 1]], @intCast(f));
    var sorted: rects.SortedRects = .{};
    defer sorted.deinit(gpa);
    try sorted.build(gpa, outer.rects.items, labels);
    for (home, 0..) |*slot, f| {
        const mine = inner.figure(@intCast(f));
        var covered: DbuArea = 0;
        var host: ?u32 = null;
        for (mine) |box| {
            var hits = sorted.overlapping(box);
            while (hits.next()) |h| {
                covered += h.clip.area();
                host = h.label;
            }
        }
        slot.* = if (covered == geom.rects.coveredArea(mine)) host else null;
    }
}
