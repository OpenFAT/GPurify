//! Enclosure: each inner polygon on its best host, a figure of the merged
//! outer layer that covers all of its area, read by the rule's mode; only
//! the inner polygons the wire band (and LEF's `EXCEPTEXTRACUT` and
//! `LENGTH`) selects are held. In: two rectilinear layers. Out: one
//! violation per inner polygon enclosed less than the limit (an unhosted one
//! measures 0). Ported from crates/check/src/drc/rules/overlay.rs
//! (`enclosure`, `wide_part`, `redundant_cuts`, `overhang_length`,
//! `pair_layers`); layers with a slanted edge go to
//! `overlay_octilinear.zig`.
//!
//! Contents:
//! - `pub fn enclosure(c: *const Ctx, outer: LayerId, inner_layer: LayerId, limit: Dbu, wire: WireBand, mode: Mode) Error!Verdict`
//! - `pub fn widePart(gpa: Allocator, drawn: *const ValidatedLayer, width: ?Dbu, out: *SortedRects) Error!bool`
//! - `pub fn covers(part: *const SortedRects, boxes: []const Bbox, area: DbuArea) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const SortedRects = rects.SortedRects;
const proximity_inside = @import("../proximity_inside.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const strips = @import("overlay_strips.zig");
const Mode = strips.Mode;
const octilinear = @import("overlay_octilinear.zig");

/// Below the most negative real margin: seeds the host fold.
const unhosted: i64 = -(1 << 42);

/// Per inner polygon on its best host; `examined` counts the held ones.
pub fn enclosure(c: *const Ctx, outer: LayerId, inner_layer: LayerId, limit: Dbu, wire: rows.WireBand, mode: Mode) Error!Verdict {
    const gpa = c.gpa;
    const s = c.s;
    {
        const hosts_any = try s.p.validated.getAny(gpa, c.store, outer) orelse return report.refused;
        const drawn_any = try s.p.validated.getAny(gpa, c.store, inner_layer) orelse return report.refused;
        if (!(hosts_any.isRectilinear() and drawn_any.isRectilinear())) return octilinear.enclosureOctilinear(c, outer, inner_layer, limit, wire, mode);
    }
    var redundant: std.ArrayList(bool) = .empty;
    defer redundant.deinit(gpa);
    if (wire.extra_cut) |extra| if (!try redundantCutsInto(c, inner_layer, outer, extra, &redundant)) return report.refused;
    const hosts = try s.p.validated.get(gpa, c.store, outer) orelse return report.refused;
    const drawn = try s.p.validated.get(gpa, c.store, inner_layer) orelse return report.refused;
    try s.p.index_b.build(gpa, c.store, outer);
    try geom.index.crossLayerPairsInto(gpa, c.store, inner_layer, &s.p.index_b, 0, &s.p.pairs);
    const host_rects = &s.rects_b;
    try host_rects.build(gpa, c.store, outer, hosts);
    const host_first = c.store.polysOnLayer(outer).start;
    const merged = &s.p.layer_out;
    try geom.derive.mergeInto(gpa, hosts, merged);
    // The parts of the outer layer at least `from` and `below` wide.
    var from: SortedRects = .{};
    defer from.deinit(gpa);
    var below: SortedRects = .{};
    defer below.deinit(gpa);
    const has_from = try widePart(gpa, hosts, if (wire.from > 0) wire.from else null, &from);
    const has_below = try widePart(gpa, hosts, wire.below, &below);
    const inner_rects = &s.p.rects_a;
    try inner_rects.build(gpa, c.store, inner_layer, drawn);
    const inner_boxes = drawn.bboxes();
    try geom.rects.decomposeInto(gpa, merged, &s.rects, &s.rect_start);
    // Each drawn host polygon lies in exactly one merged figure.
    var by_figure: SortedRects = .{};
    defer by_figure.deinit(gpa);
    {
        const labels = try gpa.alloc(u32, s.rects.items.len);
        defer gpa.free(labels);
        for (0..merged.len()) |f| @memset(labels[s.rect_start.items[f]..s.rect_start.items[f + 1]], @intCast(f));
        try by_figure.build(gpa, s.rects.items, labels);
    }
    const figure_of = try gpa.alloc(?u32, host_rects.len());
    defer gpa.free(figure_of);
    for (figure_of, 0..) |*f, h| {
        f.* = null;
        const mine = host_rects.of(@intCast(h));
        if (mine.len == 0) continue;
        var hits = by_figure.overlapping(mine[0]);
        if (hits.next()) |hit| f.* = hit.label;
    }
    var examined: u64 = 0;
    var under: std.ArrayList(u32) = .empty;
    defer under.deinit(gpa);
    for (0..inner_rects.len()) |poly| {
        const inner = inner_rects.row.items[poly];
        const inner_box = inner_boxes[poly];
        const mine = inner_rects.of(@intCast(poly));
        const area = geom.rects.coveredArea(mine);
        if (has_from and !covers(&from, mine, area)) continue;
        if (has_below and covers(&below, mine, area)) continue;
        if (wire.extra_cut) |extra| if (redundant.items[poly] != extra.only) continue;
        if (wire.length[0] != null or wire.length[1] != null) {
            under.clearRetainingCapacity();
            var hits = by_figure.overlapping(inner_box);
            while (hits.next()) |h| if (std.mem.indexOfScalar(u32, under.items, h.label) == null) try under.append(gpa, h.label);
            var overhang: i64 = 0;
            for (under.items) |f| overhang = @max(overhang, try overhangLength(gpa, figureRects(s, f), inner_box));
            if (wire.length[0]) |least| if (overhang < least) continue;
            if (wire.length[1]) |short| if (overhang >= short) continue;
        }
        examined += 1;
        // Best host; a tie goes to the lowest row.
        var best: i64 = unhosted;
        var best_row: u32 = std.math.maxInt(u32);
        var best_at: ?geom.Point = null;
        const lo = std.sort.lowerBound(geom.index.Pair, s.p.pairs.items, inner, pairA);
        const hi = std.sort.upperBound(geom.index.Pair, s.p.pairs.items, inner, pairA);
        for (s.p.pairs.items[lo..hi]) |pair| {
            const h = host_rects.poly_of_row.items[@backingInt(pair.b) - host_first];
            const figure = figure_of[h] orelse continue;
            const host = @backingInt(host_rects.row.items[h]);
            const theirs = figureRects(s, figure);
            var covered: DbuArea = 0;
            for (mine) |box| covered += geom.rects.clippedArea(theirs, box);
            if (covered != area) continue;
            const reading = strips.enclosureOf(drawn.get(@intCast(poly)), mine, merged.get(figure), mode);
            // A full-width reading is a maximum: the best host has the least.
            const score = if (mode == .full_width) -reading.value else reading.value;
            if (score > best or (score == best and host < best_row)) {
                best = score;
                best_row = host;
                best_at = reading.at;
            }
        }
        const hosted = best > unhosted;
        const host_id: PolyId = @fromBackingInt(best_row);
        if (mode == .full_width) {
            // An unhosted inner is `must_be_inside`'s; a host spanned is met.
            if (!hosted or best == 0) continue;
            try c.push(.{ .rule = c.rule, .layer = inner_layer, .severity = .@"error", .at = best_at orelse rects.centre(inner_box), .measured = .length(@min(-best, geom.max_abs_dbu)), .limit = .length(0), .shape_a = inner, .shape_b = host_id });
            continue;
        }
        const measured: Measurement = .length(std.math.clamp(best, 0, geom.max_abs_dbu));
        if (!measured.violates(.length(limit), .minimum)) continue;
        const at = if (hosted and best_at != null) best_at.? else rects.centre(inner_box);
        try c.push(.{ .rule = c.rule, .layer = inner_layer, .severity = .@"error", .at = at, .measured = measured, .limit = .length(limit), .shape_a = inner, .shape_b = if (hosted) host_id else report.no_shape });
    }
    return scratch.ran(examined);
}

/// The part of `drawn` at least `width` wide, indexed into `out`; false
/// (and `out` untouched) for no width.
pub fn widePart(gpa: Allocator, drawn: *const ValidatedLayer, width: ?Dbu, out: *SortedRects) Error!bool {
    const w = width orelse return false;
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    try scratch.wideRectsInto(gpa, drawn, w, &boxes);
    const zeros = try gpa.alloc(u32, boxes.items.len);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    try out.build(gpa, boxes.items, zeros);
    return true;
}

/// Whether `part` covers all `area` of `boxes`.
pub fn covers(part: *const SortedRects, boxes: []const Bbox, area: DbuArea) bool {
    var covered: DbuArea = 0;
    for (boxes) |box| {
        var hits = part.overlapping(box);
        while (hits.next()) |h| covered += h.clip.area();
    }
    return covered == area;
}

// ---- private ----

fn pairA(want: PolyId, p: geom.index.Pair) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(p.a));
}

fn figureRects(s: *const scratch.Scratch, f: u32) []const Bbox {
    return s.rects.items[s.rect_start.items[f]..s.rect_start.items[f + 1]];
}

/// `EXCEPTEXTRACUT` (DRC-043): per polygon of the validated `inner` layer,
/// whether another lies on the same merged figure of `outer` and of
/// `extra.other` (the lowest figure its box overlaps) at most `within` from
/// it, box to box, into `out`. False when a layer does not validate.
fn redundantCutsInto(c: *const Ctx, inner: LayerId, outer: LayerId, extra: rows.ExtraCut, out: *std.ArrayList(bool)) Error!bool {
    const gpa = c.gpa;
    var on: [2]SortedRects = .{ .{}, .{} };
    defer for (&on) |*o| o.deinit(gpa);
    for ([2]LayerId{ outer, extra.other }, &on) |metal, *o| {
        var figures: ValidatedLayer = .empty;
        defer figures.deinit(gpa);
        if (!try proximity_inside.mergedInto(gpa, c.store, metal, &c.s.p, &figures)) return false;
        try rects.figureRectsInto(gpa, &figures, o);
    }
    const boxes = (try c.s.p.validated.get(gpa, c.store, inner) orelse return false).bboxes();
    const key = try gpa.alloc(?[2]u32, boxes.len);
    defer gpa.free(key);
    for (key, boxes) |*k, b| {
        const first = lowest(&on[0], b);
        const second = lowest(&on[1], b);
        k.* = if (first != null and second != null) .{ first.?, second.? } else null;
    }
    var near: SortedRects = .{};
    defer near.deinit(gpa);
    const ids = try gpa.alloc(u32, boxes.len);
    defer gpa.free(ids);
    for (ids, 0..) |*id, i| id.* = @intCast(i);
    try near.build(gpa, boxes, ids);
    const reach = geom.mulWide(extra.within, extra.within);
    // A box grown one past `within` overlaps, with positive area, every box
    // at most `within` from it.
    const grow = extra.within + 1;
    try out.resize(gpa, boxes.len);
    for (out.items, boxes, key, 0..) |*o, b, k, i| {
        o.* = false;
        const mine = k orelse continue;
        var hits = near.overlapping(.{ .xlo = b.xlo - grow, .ylo = b.ylo - grow, .xhi = b.xhi + grow, .yhi = b.yhi + grow });
        while (hits.next()) |h| {
            if (h.label == i) continue;
            const theirs = key[h.label] orelse continue;
            if (theirs[0] == mine[0] and theirs[1] == mine[1] and rects.bboxGap2(b, boxes[h.label]) <= reach) {
                o.* = true;
                break;
            }
        }
    }
    return true;
}

/// The lowest figure label whose rectangle overlaps `b` with positive area.
fn lowest(on: *const SortedRects, b: Bbox) ?u32 {
    var least: ?u32 = null;
    var hits = on.overlapping(b);
    while (hits.next()) |h| least = if (least) |l| @min(l, h.label) else h.label;
    return least;
}

/// LEF `ENCLOSURE ... LENGTH`'s overhang length of box `b` on a figure's
/// rectangles: the longer of the runs of material along the horizontal and
/// vertical line through `b`'s centre, each the run containing the centre,
/// ends included; 0 when the centre is on no rectangle.
// ponytail: scans the host figure's rectangles per cut; index the runs if a
// plate holds many cuts under a `length:` rule.
fn overhangLength(gpa: Allocator, boxes: []const Bbox, b: Bbox) Allocator.Error!i64 {
    // Twice the coordinates, so a half-unit centre is whole.
    const cx = b.xlo + b.xhi;
    const cy = b.ylo + b.yhi;
    var across: std.ArrayList([2]i64) = .empty;
    defer across.deinit(gpa);
    var up: std.ArrayList([2]i64) = .empty;
    defer up.deinit(gpa);
    for (boxes) |r| {
        if (2 * r.ylo <= cy and cy <= 2 * r.yhi) try across.append(gpa, .{ 2 * r.xlo, 2 * r.xhi });
        if (2 * r.xlo <= cx and cx <= 2 * r.xhi) try up.append(gpa, .{ 2 * r.ylo, 2 * r.yhi });
    }
    return @max(runThrough(across.items, cx), runThrough(up.items, cy));
}

/// The merged run of `spans` containing `at`, halved; 0 for none.
fn runThrough(spans: [][2]i64, at: i64) i64 {
    std.mem.sortUnstable([2]i64, spans, {}, struct {
        fn less(_: void, x: [2]i64, y: [2]i64) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    }.less);
    var cur: ?[2]i64 = null;
    for (spans) |s| {
        if (cur) |*cc| {
            if (s[0] <= cc[1]) {
                cc[1] = @max(cc[1], s[1]);
                continue;
            }
            if (cc[0] <= at and at <= cc[1]) break;
        }
        cur = s;
    }
    const run = cur orelse return 0;
    return if (run[0] <= at and at <= run[1]) @divTrunc(run[1] - run[0], 2) else 0;
}
