//! Rules read off a merged figure's chords, corners and rectangles: span
//! lengths (`LEF58_SPANLENGTHTABLE`), convex-corner spacing
//! (`LEF58_CORNERSPACING CONVEXCORNER`) and exact pitch (ASAP7 FIN.S.1).
//! In: one rectilinear layer. Out: one violation per illegal chord region,
//! per pair of figures, or per neighbouring pair. Ported from
//! crates/check/src/drc/rules/facing.rs (`span_length`, `chords`,
//! `figure_corners`, `convex_corner_spacing`, `exact_pitch`).
//!
//! Contents:
//! - `pub fn spanLength(c: *const Ctx, r: LayerTable) Error!Verdict`
//! - `pub fn convexCornerSpacing(c: *const Ctx, r: ConvexCornerSpacing) Error!Verdict`
//! - `pub fn exactPitch(c: *const Ctx, r: ExactPitch) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const proximity = @import("../proximity.zig");
const rows = @import("rows.zig");
const tables = @import("tables.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const fe = @import("facing_edges.zig");
const Edge = fe.Edge;

/// One region of an unchanged chord: the chord `lo..hi` over the lines
/// `from..to`.
const Chord = struct { lo: i64, hi: i64, from: i64, to: i64 };

/// A convex corner of a merged figure: its vertex, its outward diagonal
/// (each ±1), its figure, and whether it is an end of line's corner.
const Corner = struct { x: i64, y: i64, sx: i64, sy: i64, figure: u32, on_end: bool };

/// A pair of facing corners closer than the limit.
const CornerHit = struct { a: u32, b: u32, gap: i128, p: Point, q: Point };

/// A rectangle along the pitch's axis, across it, and its figure.
const Strip = struct { lo: i64, hi: i64, across_lo: i64, across_hi: i64, figure: u32 };

/// Every chord a horizontal or vertical line cuts from a merged figure must
/// be legal on its axis's list. One finding per maximal region of an
/// unchanged illegal chord. `examined` counts regions, both axes.
pub fn spanLength(c: *const Ctx, r: rows.LayerTable) Error!Verdict {
    const gpa = c.gpa;
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const spans = c.rs.spanTable(r.table);
    const figures = &c.s.p.layer_out;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try fe.figureEdgesInto(gpa, figures, &edges);
    std.mem.sort(Edge, edges.items, {}, struct {
        fn less(_: void, x: Edge, y: Edge) bool {
            return x.figure < y.figure or (x.figure == y.figure and @intFromBool(x.vertical) < @intFromBool(y.vertical));
        }
    }.less);
    var chords: std.ArrayList(Chord) = .empty;
    defer chords.deinit(gpa);
    var examined: u64 = 0;
    var at: usize = 0;
    while (at < edges.items.len) {
        var stop = at;
        while (stop < edges.items.len and edges.items[stop].figure == edges.items[at].figure and edges.items[stop].vertical == edges.items[at].vertical) stop += 1;
        defer at = stop;
        const figure = edges.items[at].figure;
        // A figure's vertical edges bound its horizontal chords (the `x`
        // list); its horizontal edges its vertical chords (`y`).
        const across_x = edges.items[at].vertical;
        const legal = if (across_x) spans.x else spans.y;
        // EXCEPTOTHERSPAN: a rectangle's span is held only when its span
        // the other way exceeds the list's exception.
        const poly = figures.get(figure);
        const box = poly.bbox();
        const except = if (across_x) spans.x_except else spans.y_except;
        const other = if (across_x) box.height() else box.width();
        if (poly.outer().xs.len == 4 and poly.ringCount() == 1) if (except) |e| if (other <= e) continue;
        try chordsInto(gpa, edges.items[at..stop], &chords);
        for (chords.items) |ch| {
            examined += 1;
            const next = tables.nextLegal(legal, ch.hi - ch.lo) orelse continue;
            const region: Bbox = if (across_x) .{ .xlo = ch.lo, .ylo = ch.from, .xhi = ch.hi, .yhi = ch.to } else .{ .xlo = ch.from, .ylo = ch.lo, .xhi = ch.to, .yhi = ch.hi };
            try c.finding(r.layer, rects.centre(region), .length(ch.hi - ch.lo), .length(next), c.s.owners.items[figure]);
        }
    }
    return scratch.ran(examined);
}

/// Facing convex corners of different figures closer than the limit by the
/// larger axis gap, or Euclidean with `corner_to_corner`; with `except_eol`
/// an end of line's corners on either figure are exempt. `examined` counts
/// the facing pairs of corners judged.
pub fn convexCornerSpacing(c: *const Ctx, r: rows.ConvexCornerSpacing) Error!Verdict {
    const gpa = c.gpa;
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(gpa);
    try figureCornersInto(gpa, &c.s.p.layer_out, r.except_eol, &corners);
    const reach = r.limit;
    const need: i128 = if (r.corner_to_corner) geom.mulWide(reach, reach) else reach;
    var hits: std.ArrayList(CornerHit) = .empty;
    defer hits.deinit(gpa);
    var examined: u64 = 0;
    // Each corner facing +x against the corners right of it, facing back.
    for (corners.items) |k| {
        if (k.sx <= 0) continue;
        var at = std.sort.partitionPoint(Corner, corners.items, k.x, struct {
            fn before(x: i64, item: Corner) bool {
                return item.x <= x;
            }
        }.before);
        while (at < corners.items.len and corners.items[at].x - k.x < reach) : (at += 1) {
            const o = corners.items[at];
            const facing = o.sx < 0 and o.sy == -k.sy and std.math.sign(o.y - k.y) == k.sy;
            if (!facing or o.figure == k.figure or k.on_end or o.on_end) continue;
            examined += 1;
            const dx: i128 = o.x - k.x;
            const dy: i128 = @abs(o.y - k.y);
            const gap = if (r.corner_to_corner) dx * dx + dy * dy else @max(dx, dy);
            if (gap < need) try hits.append(gpa, .{ .a = @min(k.figure, o.figure), .b = @max(k.figure, o.figure), .gap = gap, .p = .{ .x = k.x, .y = k.y }, .q = .{ .x = o.x, .y = o.y } });
        }
    }
    std.mem.sortUnstable(CornerHit, hits.items, {}, struct {
        fn less(_: void, x: CornerHit, y: CornerHit) bool {
            return x.a < y.a or (x.a == y.a and (x.b < y.b or (x.b == y.b and x.gap < y.gap)));
        }
    }.less);
    var at: usize = 0;
    while (at < hits.items.len) {
        var stop = at;
        var nearest: proximity.Nearest = .{};
        defer nearest.deinit(gpa);
        const first = hits.items[at];
        while (stop < hits.items.len and hits.items[stop].a == first.a and hits.items[stop].b == first.b) : (stop += 1) {
            if (hits.items[stop].gap == first.gap) try nearest.add(gpa, .{ .a = hits.items[stop].p, .b = hits.items[stop].p }, .{ .a = hits.items[stop].q, .b = hits.items[stop].q });
        }
        const measured: Dbu = if (r.corner_to_corner) geom.ops.isqrt(first.gap) else @intCast(first.gap);
        try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = nearest.result().?.at, .measured = .length(measured), .limit = .length(r.limit), .shape_a = c.s.owners.items[first.a], .shape_b = c.s.owners.items[first.b] });
        at = stop;
    }
    return scratch.ran(examined);
}

/// Each rectangle's neighbours past it on the axis, the nearest overlapping
/// it across, must have centre lines exactly `pitch` apart. A figure that is
/// not a rectangle refuses the layer. `examined` counts neighbouring pairs.
pub fn exactPitch(c: *const Ctx, r: rows.ExactPitch) Error!Verdict {
    const gpa = c.gpa;
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const figures = &c.s.p.layer_out;
    var strips: std.ArrayList(Strip) = .empty;
    defer strips.deinit(gpa);
    for (0..figures.len()) |figure| {
        const poly = figures.get(@intCast(figure));
        if (poly.outer().xs.len != 4 or poly.ringCount() != 1) return report.refused;
        const b = poly.bbox();
        try strips.append(gpa, if (r.vertical)
            .{ .lo = b.ylo, .hi = b.yhi, .across_lo = b.xlo, .across_hi = b.xhi, .figure = @intCast(figure) }
        else
            .{ .lo = b.xlo, .hi = b.xhi, .across_lo = b.ylo, .across_hi = b.yhi, .figure = @intCast(figure) });
    }
    std.mem.sortUnstable(Strip, strips.items, {}, struct {
        fn less(_: void, x: Strip, y: Strip) bool {
            return std.mem.order(i64, &.{ x.lo, x.hi, x.across_lo, x.across_hi, x.figure }, &.{ y.lo, y.hi, y.across_lo, y.across_hi, y.figure }) == .lt;
        }
    }.less);
    var examined: u64 = 0;
    for (strips.items) |s| {
        // ponytail: scans past every rectangle starting beyond this one
        // until the nearest overlapping row; quadratic for columns that
        // never overlap across.
        var at = std.sort.partitionPoint(Strip, strips.items, s.hi, struct {
            fn before(hi: i64, x: Strip) bool {
                return x.lo < hi;
            }
        }.before);
        var row: ?i64 = null;
        while (at < strips.items.len) : (at += 1) {
            const n = strips.items[at];
            if (row) |nearest| if (n.lo > nearest) break;
            const from = @max(s.across_lo, n.across_lo);
            const to = @min(s.across_hi, n.across_hi);
            if (to <= from) continue;
            row = n.lo;
            examined += 1;
            // Twice the distance between the centre lines, exact.
            const twice = (n.lo + n.hi) - (s.lo + s.hi);
            if (twice == 2 * r.pitch) continue;
            const along = rects.mid(s.hi, n.lo);
            const across = rects.mid(from, to);
            const at_point: Point = if (r.vertical) .{ .x = across, .y = along } else .{ .x = along, .y = across };
            try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = at_point, .measured = .length(@divFloor(twice, 2)), .limit = .length(r.pitch), .shape_a = c.s.owners.items[s.figure], .shape_b = c.s.owners.items[n.figure] });
        }
    }
    return scratch.ran(examined);
}

// ---- private ----

/// The chords lines across one figure cut, from its edges of one
/// orientation, into `out`: one per maximal stretch of lines over which the
/// chord stays the same. Lines are read between consecutive edge ends, where
/// no vertex lies; the material between two crossed edges alternates.
fn chordsInto(gpa: Allocator, edges: []const Edge, out: *std.ArrayList(Chord)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var cuts: std.ArrayList(i64) = .empty;
    defer cuts.deinit(gpa);
    for (edges) |e| try cuts.appendSlice(gpa, &.{ e.lo, e.hi });
    std.mem.sortUnstable(i64, cuts.items, {}, std.sort.asc(i64));
    var kept: usize = 0;
    for (cuts.items) |v| {
        if (kept > 0 and cuts.items[kept - 1] == v) continue;
        cuts.items[kept] = v;
        kept += 1;
    }
    const uniq = cuts.items[0..kept];
    var open: std.ArrayList([3]i64) = .empty;
    defer open.deinit(gpa);
    var crossing: std.ArrayList(i64) = .empty;
    defer crossing.deinit(gpa);
    for (1..uniq.len) |k| {
        const from = uniq[k - 1];
        const to = uniq[k];
        crossing.clearRetainingCapacity();
        for (edges) |e| if (e.lo <= from and e.hi >= to) try crossing.append(gpa, e.pos);
        std.mem.sortUnstable(i64, crossing.items, {}, std.sort.asc(i64));
        const pairs = crossing.items[0 .. crossing.items.len - crossing.items.len % 2];
        // A chord that stops here closes its region; a new one opens one.
        var still: usize = 0;
        for (open.items) |o| {
            const goes_on = hasPair(pairs, o[0], o[1]);
            if (goes_on) {
                open.items[still] = o;
                still += 1;
            } else try out.append(gpa, .{ .lo = o[0], .hi = o[1], .from = o[2], .to = from });
        }
        open.shrinkRetainingCapacity(still);
        var p: usize = 0;
        while (p < pairs.len) : (p += 2) {
            const known = for (open.items) |o| {
                if (o[0] == pairs[p] and o[1] == pairs[p + 1]) break true;
            } else false;
            if (!known) try open.append(gpa, .{ pairs[p], pairs[p + 1], from });
        }
    }
    const end = if (uniq.len > 0) uniq[uniq.len - 1] else 0;
    for (open.items) |o| try out.append(gpa, .{ .lo = o[0], .hi = o[1], .from = o[2], .to = end });
}

fn hasPair(pairs: []const i64, lo: i64, hi: i64) bool {
    var p: usize = 0;
    while (p < pairs.len) : (p += 2) if (pairs[p] == lo and pairs[p + 1] == hi) return true;
    return false;
}

/// Every convex corner of a merged layer, sorted; with `eol`, a corner on
/// an edge strictly shorter than `eol` whose two corners are convex is an
/// end of line's.
fn figureCornersInto(gpa: Allocator, figures: *const geom.ValidatedLayer, eol: ?Dbu, out: *std.ArrayList(Corner)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (0..figures.len()) |figure| {
        const poly = figures.get(@intCast(figure));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            const n = ring.xs.len;
            for (0..n) |i| {
                const t = turn(ring, i);
                if (!t.convex) continue;
                const on_end = endShorter(ring, (i + n - 1) % n, eol) or endShorter(ring, i, eol);
                try out.append(gpa, .{ .x = ring.xs[i], .y = ring.ys[i], .sx = t.sx, .sy = t.sy, .figure = @intCast(figure), .on_end = on_end });
            }
        }
    }
    std.mem.sortUnstable(Corner, out.items, {}, struct {
        fn less(_: void, x: Corner, y: Corner) bool {
            return std.mem.order(i64, &.{ x.x, x.y, x.sx, x.sy, x.figure, @intFromBool(x.on_end) }, &.{ y.x, y.y, y.sx, y.sy, y.figure, @intFromBool(y.on_end) }) == .lt;
        }
    }.less);
}

/// Vertex `i` turns from edge `i - 1` into edge `i`: a left turn is
/// convex, its outward diagonal along the edge in, against the one leaving.
fn turn(ring: geom.Ring, i: usize) struct { convex: bool, sx: i64, sy: i64 } {
    const n = ring.xs.len;
    const back = (i + n - 1) % n;
    const next = (i + 1) % n;
    const inx = ring.xs[i] - ring.xs[back];
    const iny = ring.ys[i] - ring.ys[back];
    const outx = ring.xs[next] - ring.xs[i];
    const outy = ring.ys[next] - ring.ys[i];
    return .{ .convex = geom.mulWide(inx, outy) > geom.mulWide(iny, outx), .sx = std.math.sign(inx - outx), .sy = std.math.sign(iny - outy) };
}

/// Edge `i` (vertex `i` to `i + 1`) is shorter than `eol` with both
/// corners convex.
fn endShorter(ring: geom.Ring, i: usize, eol: ?Dbu) bool {
    const w = eol orelse return false;
    const n = ring.xs.len;
    const j = (i + 1) % n;
    const len = @abs(ring.xs[j] - ring.xs[i]) + @abs(ring.ys[j] - ring.ys[i]);
    return len < w and turn(ring, i).convex and turn(ring, j).convex;
}
