//! Overlay family past enclosure: cut sizes on metal-width bands, max
//! enclosure, extension past a reference, gate corners, overlap and the
//! distance from any point of a well to a tap. In: two validated layers or
//! their merged figures. Out: one violation per offending cut, figure, gate
//! or well. Ported from crates/check/src/drc/rules/overlay.rs
//! (`metal_width_via`, `max_enclosure`, `beyond`, `min_extension`,
//! `gate_extension`, `just_past`, `gate_corner`, `concave_corners`,
//! `overlap`, `max_distance_to_tap`, `ceil_sqrt`).
//!
//! Contents:
//! - `pub fn metalWidthVia(c: *const Ctx, r: MetalWidthVia) Error!Verdict`
//! - `pub fn maxEnclosure(c: *const Ctx, r: PlainEnclosure) Error!Verdict`
//! - `pub fn minExtension(c: *const Ctx, r: MinExtension) Error!Verdict`
//! - `pub fn gateCorner(c: *const Ctx, r: GateCorner) Error!Verdict`
//! - `pub fn overlap(c: *const Ctx, r: TwoLayers) Error!Verdict`
//! - `pub fn maxDistanceToTap(c: *const Ctx, r: MaxDistanceToTap) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const PolyId = geom.PolyId;
const Polygon = geom.Polygon;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const SortedRects = rects.SortedRects;
const proximity_inside = @import("../proximity_inside.zig");
const taps = @import("../topology/taps.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const strips = @import("overlay_strips.zig");
const Side = strips.Side;
const enc = @import("overlay_enclosure.zig");
const presence = @import("presence.zig");
const Cut = presence.Cut;

/// A gate edge's straight-out run past it, on one side.
const Run = struct { d: Dbu, side: Side, edge: Bbox };

/// `LEF58_METALWIDTHVIAMAP` (DRC-067): each drawn cut on a wire of `below`
/// in its band and one of `above` in its band must be a `width x height`
/// box, either way round. One violation per offending cut, at its centre.
/// `examined` counts held cuts.
pub fn metalWidthVia(c: *const Ctx, r: rows.MetalWidthVia) Error!Verdict {
    const gpa = c.gpa;
    var parts: [2][2]SortedRects = .{ .{ .{}, .{} }, .{ .{}, .{} } };
    defer for (&parts) |*p| for (p) |*x| x.deinit(gpa);
    var has: [2][2]bool = undefined;
    for ([2]geom.LayerId{ r.below, r.above }, [2]rows.WireBand{ r.below_band, r.above_band }, 0..) |metal, band, i| {
        const drawn = try c.s.p.validated.get(gpa, c.store, metal) orelse return report.refused;
        has[i][0] = try enc.widePart(gpa, drawn, band.from, &parts[i][0]);
        has[i][1] = try enc.widePart(gpa, drawn, band.below, &parts[i][1]);
    }
    const cuts = c.store.polysOnLayer(r.cut);
    var examined: u64 = 0;
    for (cuts.start..cuts.end) |row| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        const b = c.store.polyBbox(poly);
        const held = for (0..2) |i| {
            const from_ok = has[i][0] and enc.covers(&parts[i][0], &.{b}, b.area());
            const over = has[i][1] and enc.covers(&parts[i][1], &.{b}, b.area());
            if (!from_ok or over) break false;
        } else true;
        if (!held) continue;
        examined += 1;
        const w = b.xhi - b.xlo;
        const h = b.yhi - b.ylo;
        if ((w == r.width and h == r.height) or (w == r.height and h == r.width)) continue;
        try c.finding(r.cut, geom.ops.centre(b), .count(0), .count(1), poly);
    }
    return scratch.ran(examined);
}

/// Each merged outer figure holding inner figures must lie inside their
/// union grown by `limit` (square corners). One violation per offending
/// figure, at its part beyond the limit, measuring the least whole growth
/// that covers it. `examined` counts outer figures holding an inner one.
pub fn maxEnclosure(c: *const Ctx, r: rows.PlainEnclosure) Error!Verdict {
    const gpa = c.gpa;
    const s = c.s;
    var inner_figures: ValidatedLayer = .empty;
    defer inner_figures.deinit(gpa);
    var outer_figures: ValidatedLayer = .empty;
    defer outer_figures.deinit(gpa);
    if (!try proximity_inside.mergedInto(gpa, c.store, r.inner, &s.p, &inner_figures)) return report.refused;
    if (!try proximity_inside.mergedInto(gpa, c.store, r.outer, &s.p, &outer_figures)) return report.refused;
    var inner_cut: Cut = .{};
    defer inner_cut.deinit(gpa);
    try inner_cut.of(gpa, &inner_figures);
    var outer_cut: Cut = .{};
    defer outer_cut.deinit(gpa);
    try outer_cut.of(gpa, &outer_figures);
    const home = try gpa.alloc(?u32, inner_cut.count());
    defer gpa.free(home);
    try presence.hostsInto(gpa, &inner_cut, &outer_cut, home);
    try s.p.rects_a.build(gpa, c.store, r.outer, (try s.p.validated.get(gpa, c.store, r.outer)).?);
    try rects.ownersOfInto(gpa, &outer_figures, &s.p.rects_a, &s.owners);
    var held: std.ArrayList(Bbox) = .empty;
    defer held.deinit(gpa);
    var excess: ValidatedLayer = .empty;
    defer excess.deinit(gpa);
    var examined: u64 = 0;
    for (0..outer_cut.count()) |f| {
        held.clearRetainingCapacity();
        for (home, 0..) |h, i| if (h) |hh| if (hh == f) try held.appendSlice(gpa, inner_cut.figure(@intCast(i)));
        if (held.items.len == 0) continue;
        examined += 1;
        const host = outer_cut.figure(@intCast(f));
        try beyond(gpa, host, held.items, r.limit, &excess);
        if (excess.len() == 0) continue;
        // The least growth covering the host: past `limit`, at most the
        // host's own span.
        var span = Bbox.empty;
        for (host) |b| span = span.merge(b);
        var lo = r.limit;
        var hi = @max(span.xhi - span.xlo, span.yhi - span.ylo);
        var probe: ValidatedLayer = .empty;
        defer probe.deinit(gpa);
        while (hi - lo > 1) {
            const at = lo + @divTrunc(hi - lo, 2);
            try beyond(gpa, host, held.items, at, &probe);
            if (probe.len() == 0) hi = at else lo = at;
        }
        var excess_cut: Cut = .{};
        defer excess_cut.deinit(gpa);
        try excess_cut.of(gpa, &excess);
        try c.finding(r.outer, geom.ops.centre(excess_cut.figure(0)[0]), .length(hi), .length(r.limit), s.owners.items[f]);
    }
    return scratch.ran(examined);
}

/// Min extension of `layer` past `reference`, per gate (each figure of the
/// area the merged layers share), on the lowest drawn row of each layer
/// under it; shapes that only touch make no gate. `examined` counts gates.
pub fn minExtension(c: *const Ctx, r: rows.MinExtension) Error!Verdict {
    const gpa = c.gpa;
    const s = c.s;
    var lines: ValidatedLayer = .empty;
    defer lines.deinit(gpa);
    if (!try proximity_inside.mergedInto(gpa, c.store, r.layer, &s.p, &lines)) return report.refused;
    const drawn_ref = try s.p.validated.get(gpa, c.store, r.reference) orelse return report.refused;
    try s.rects_b.build(gpa, c.store, r.reference, drawn_ref);
    const gates = &s.p.layer_out;
    try geom.boolean.intersectionInto(gpa, &lines, drawn_ref, gates);
    try s.p.rects_a.build(gpa, c.store, r.layer, (try s.p.validated.get(gpa, c.store, r.layer)).?);
    var line_of: SortedRects = .{};
    defer line_of.deinit(gpa);
    try rects.figureRectsInto(gpa, &lines, &line_of);
    var refs: SortedRects = .{};
    defer refs.deinit(gpa);
    {
        var labels: std.ArrayList(u32) = .empty;
        defer labels.deinit(gpa);
        try s.rects_b.rowLabelsInto(gpa, &labels);
        try refs.build(gpa, s.rects_b.rects.items, labels.items);
    }
    try geom.rects.decomposeInto(gpa, gates, &s.rects, &s.rect_start);
    var line_rows: std.ArrayList(PolyId) = .empty;
    defer line_rows.deinit(gpa);
    var ref_rows: std.ArrayList(PolyId) = .empty;
    defer ref_rows.deinit(gpa);
    try rects.ownersOfInto(gpa, gates, &s.p.rects_a, &line_rows);
    try rects.ownersOfInto(gpa, gates, &s.rects_b, &ref_rows);
    for (line_rows.items, ref_rows.items, 0..) |line_row, ref_row, g| {
        const inside = s.rects.items[s.rect_start.items[g]];
        var hits = line_of.overlapping(inside);
        const f = hits.next().?.label;
        const ext = gateExtension(gates.get(@intCast(g)), lines.get(f), &refs);
        if (ext.d < r.limit) try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = ext.at, .measured = .length(ext.d), .limit = .length(r.limit), .shape_a = line_row, .shape_b = ref_row });
    }
    return scratch.ran(gates.len());
}

/// A gate's shape (sky130 poly.10, poly.11): each concave corner of the area
/// the merged layers share that is a concave corner of `layer` (a bend) or,
/// with `of_reference`, of `reference`, at the corner. `examined` counts
/// gates.
pub fn gateCorner(c: *const Ctx, r: rows.GateCorner) Error!Verdict {
    const gpa = c.gpa;
    const s = c.s;
    var lines: ValidatedLayer = .empty;
    defer lines.deinit(gpa);
    var refs: ValidatedLayer = .empty;
    defer refs.deinit(gpa);
    if (!try proximity_inside.mergedInto(gpa, c.store, r.layer, &s.p, &lines)) return report.refused;
    if (!try proximity_inside.mergedInto(gpa, c.store, r.reference, &s.p, &refs)) return report.refused;
    var gates: ValidatedLayer = .empty;
    defer gates.deinit(gpa);
    try geom.boolean.intersectionInto(gpa, &lines, &refs, &gates);
    var corners: std.ArrayList(Point) = .empty;
    defer corners.deinit(gpa);
    const of = if (r.of_reference) &refs else &lines;
    for (0..of.len()) |f| try concaveCornersInto(gpa, of.get(@intCast(f)), &corners);
    std.mem.sortUnstable(Point, corners.items, {}, lessPoint);
    try s.p.rects_a.build(gpa, c.store, r.layer, (try s.p.validated.get(gpa, c.store, r.layer)).?);
    try s.rects_b.build(gpa, c.store, r.reference, (try s.p.validated.get(gpa, c.store, r.reference)).?);
    var a_rows: std.ArrayList(PolyId) = .empty;
    defer a_rows.deinit(gpa);
    var b_rows: std.ArrayList(PolyId) = .empty;
    defer b_rows.deinit(gpa);
    try rects.ownersOfInto(gpa, &gates, &s.p.rects_a, &a_rows);
    try rects.ownersOfInto(gpa, &gates, &s.rects_b, &b_rows);
    var own: std.ArrayList(Point) = .empty;
    defer own.deinit(gpa);
    for (a_rows.items, b_rows.items, 0..) |a_row, b_row, g| {
        own.clearRetainingCapacity();
        try concaveCornersInto(gpa, gates.get(@intCast(g)), &own);
        for (own.items) |p| {
            if (std.sort.binarySearch(Point, corners.items, p, orderPoint) == null) continue;
            try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = p, .measured = .count(1), .limit = .count(0), .shape_a = a_row, .shape_b = b_row });
        }
    }
    return scratch.ran(gates.len());
}

/// Min overlap: each figure of the area the merged layers share, measured as
/// `min_width` measures a figure, on the lowest drawn row of each layer
/// under it. `examined` counts the figures.
pub fn overlap(c: *const Ctx, r: rows.TwoLayers) Error!Verdict {
    const gpa = c.gpa;
    const s = c.s;
    var merged_a: ValidatedLayer = .empty;
    defer merged_a.deinit(gpa);
    if (!try proximity_inside.mergedInto(gpa, c.store, r.a, &s.p, &merged_a)) return report.refused;
    const drawn_b = try s.p.validated.get(gpa, c.store, r.b) orelse return report.refused;
    try s.rects_b.build(gpa, c.store, r.b, drawn_b);
    const shared = &s.p.layer_out;
    try geom.boolean.intersectionInto(gpa, &merged_a, drawn_b, shared);
    try s.p.rects_a.build(gpa, c.store, r.a, (try s.p.validated.get(gpa, c.store, r.a)).?);
    var a_rows: std.ArrayList(PolyId) = .empty;
    defer a_rows.deinit(gpa);
    var b_rows: std.ArrayList(PolyId) = .empty;
    defer b_rows.deinit(gpa);
    try rects.ownersOfInto(gpa, shared, &s.p.rects_a, &a_rows);
    try rects.ownersOfInto(gpa, shared, &s.rects_b, &b_rows);
    for (a_rows.items, b_rows.items, 0..) |a_row, b_row, idx| {
        const poly = shared.get(@intCast(idx));
        var best = (try geom.width.narrowestFacing(gpa, poly, .width, &s.facing)).?;
        if (try geom.width.narrowestNeck(gpa, poly, r.limit)) |neck| if (neck.gap < best.gap) {
            best = neck;
        };
        if (best.gap < r.limit) try c.push(.{ .rule = c.rule, .layer = r.a, .severity = .@"error", .at = best.at, .measured = .length(best.gap), .limit = .length(r.limit), .shape_a = a_row, .shape_b = b_row });
    }
    return scratch.ran(shared.len());
}

/// Max distance from any point of a well to the nearest tap (IHP LU.a/b,
/// gf180 DF.13/14), the exact furthest point to the taps' edges, rounded
/// up. `examined` counts wells; an empty well layer is skipped.
/// ponytail: a point inside a tap measures to the tap's edge, not zero, so a
/// well under a wide tap over-reports by up to half the tap's width (fails
/// closed); an inside test per probe fixes it if it ever matters.
pub fn maxDistanceToTap(c: *const Ctx, r: rows.MaxDistanceToTap) Error!Verdict {
    const gpa = c.gpa;
    if (c.store.polysOnLayer(r.well).len() == 0) return .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };
    if (try c.s.p.validated.get(gpa, c.store, r.well) == null) return report.refused;
    var untied: taps.Untied = .{};
    defer untied.deinit(gpa);
    const examined = try taps.untiedPoints(gpa, c.store, r.well, r.tap, r.limit, &c.s.p.layer_out, &untied) orelse return report.refused;
    for (untied.poly.items, untied.at.items, untied.worst2.items) |well, at, worst| {
        try c.finding(r.well, at, .length(ceilSqrt(worst)), .length(r.limit), well);
    }
    return scratch.ran(examined);
}

// ---- private ----

/// `sqrt(d2)` rounded up, so an exceeded limit reads as exceeded.
fn ceilSqrt(d2: DbuArea) Dbu {
    const root = geom.ops.isqrt(d2);
    return root + @intFromBool(geom.mulWide(root, root) != d2);
}

/// The part of `host` that `held` grown by `by` (square corners) does not
/// cover, into `out`.
fn beyond(gpa: Allocator, host: []const Bbox, held: []const Bbox, by: i64, out: *ValidatedLayer) Error!void {
    const grown = try gpa.alloc(Bbox, held.len);
    defer gpa.free(grown);
    for (grown, held) |*g, b| g.* = .{ .xlo = clamped(b.xlo - by), .ylo = clamped(b.ylo - by), .xhi = clamped(b.xhi + by), .yhi = clamped(b.yhi + by) };
    var a: ValidatedLayer = .empty;
    defer a.deinit(gpa);
    var b: ValidatedLayer = .empty;
    defer b.deinit(gpa);
    try scratch.boxesLayer(gpa, host, &a);
    try scratch.boxesLayer(gpa, grown, &b);
    try geom.boolean.subtractionInto(gpa, &a, &b, out);
}

/// The one-unit strip just past `edge` (a degenerate box) on `side`.
fn justPast(edge: Bbox, side: Side) Bbox {
    var b = edge;
    switch (side) {
        .left => b.xlo -= 1,
        .right => b.xhi += 1,
        .bottom => b.ylo -= 1,
        .top => b.yhi += 1,
    }
    return b;
}

/// How far `line` runs past one gate, and where: an axis is crossed when
/// every gate edge facing along it lies on the reference's boundary; each
/// such edge measures the line's run past it, the gate the least over its
/// crossed axes (first side on a tie); crossed along neither, 0 at the
/// gate's centre.
fn gateExtension(gate: Polygon, line: Polygon, reference: *const SortedRects) struct { d: Dbu, at: Point } {
    var crossed = [2]bool{ true, true };
    var best: [2]?Run = .{ null, null };
    var it = geom.width.polyEdges(gate);
    while (it.next()) |e| {
        const edge = Bbox.point(e.a.x, e.a.y).include(e.b.x, e.b.y);
        const side = strips.outward(e.a, e.b);
        const axis = @intFromBool(e.a.y == e.b.y);
        var hits = reference.overlapping(justPast(edge, side));
        if (hits.next() != null) {
            crossed[axis] = false;
            continue;
        }
        const run = strips.strips(edge, line)[@backingInt(side)].d;
        if (best[axis] == null or run < best[axis].?.d or (run == best[axis].?.d and @backingInt(side) < @backingInt(best[axis].?.side))) best[axis] = .{ .d = run, .side = side, .edge = edge };
    }
    var pick: ?Run = null;
    for (0..2) |axis| if (crossed[axis]) if (best[axis]) |b| {
        if (pick == null or b.d < pick.?.d or (b.d == pick.?.d and @backingInt(b.side) < @backingInt(pick.?.side))) pick = b;
    };
    const p = pick orelse return .{ .d = 0, .at = geom.ops.centre(gate.bbox()) };
    return .{ .d = p.d, .at = strips.sideMidpoint(p.edge, p.d, p.side) };
}

/// Every concave corner of `poly`, holes included, appended to `out`: a
/// right turn where the material lies on the left of travel.
fn concaveCornersInto(gpa: Allocator, poly: Polygon, out: *std.ArrayList(Point)) Allocator.Error!void {
    for (0..poly.ringCount()) |k| {
        const ring = poly.ring(@intCast(k));
        const n = ring.xs.len;
        for (0..n) |i| {
            const p = (i + n - 1) % n;
            const q = (i + 1) % n;
            const turn = geom.mulWide(ring.xs[i] - ring.xs[p], ring.ys[q] - ring.ys[i]) - geom.mulWide(ring.ys[i] - ring.ys[p], ring.xs[q] - ring.xs[i]);
            if (turn < 0) try out.append(gpa, .{ .x = ring.xs[i], .y = ring.ys[i] });
        }
    }
}

fn lessPoint(_: void, a: Point, b: Point) bool {
    return a.x < b.x or (a.x == b.x and a.y < b.y);
}

fn orderPoint(want: Point, item: Point) std.math.Order {
    if (want.x != item.x) return std.math.order(want.x, item.x);
    return std.math.order(want.y, item.y);
}

fn clamped(v: i64) i64 {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
