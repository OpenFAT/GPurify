//! Edge family: checks on an edge layer (`diff.edges() not tap.edges()`).
//! In: the store's axis-aligned edges, each with its shape on the left. Out:
//! one violation per offending edge or edge pair, at the edge's midpoint or
//! the gap's, naming no shape (an edge has no store row). A non-axis edge
//! is refused. Ported from crates/check/src/drc/rules/edge.rs.
//!
//! Contents:
//! - `pub fn minLength(c: *const Ctx, r: LayerLimit) Error!Verdict`
//! - `pub fn spacing(c: *const Ctx, r: EdgeSpacing) Error!Verdict`
//! - `pub fn facing(c: *const Ctx, layer: LayerId, limit: Dbu, prl: Dbu, inside: bool) Error!Verdict`
//! - `pub fn enclosure(c: *const Ctx, r: EdgeEnclosure) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const segBbox = rects.segBbox;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

/// An edge shorter than `limit` (sky130 difftap.4). `examined` counts edges.
pub fn minLength(c: *const Ctx, r: rows.LayerLimit) Error!Verdict {
    const edges = c.store.edgesOnLayer(r.layer);
    if (!axisAligned(edges)) return report.refused;
    for (edges) |e| {
        const measured = length(e);
        if (measured < r.limit) try c.finding(r.layer, geom.ops.centre(segBbox(e)), .length(measured), .length(r.limit), report.no_shape);
    }
    return scratch.ran(edges.len);
}

/// Two parallel edges closer than the limit, edge to edge (Euclidean, so
/// also end to end), whatever side their shapes are on; touching edges are
/// no spacing, perpendicular ones are not measured (KLayout's default,
/// sky130 difftap.5 and .7). `examined` counts the parallel pairs measured.
pub fn spacing(c: *const Ctx, r: rows.EdgeSpacing) Error!Verdict {
    const first = c.store.edgesOnLayer(r.a);
    const second = if (r.b) |b| c.store.edgesOnLayer(b) else first;
    if (!axisAligned(first) or !axisAligned(second)) return report.refused;
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(c.gpa);
    try nearPairsInto(c.gpa, first, second, r.b == null, r.limit, &pairs);
    const limit2 = geom.mulWide(r.limit, r.limit);
    var examined: u64 = 0;
    for (pairs.items) |p| {
        const e = first[p[0]];
        const f = second[p[1]];
        if (horizontal(e) != horizontal(f)) continue;
        examined += 1;
        const d2 = geom.ops.segSegDist2(e, f);
        if (d2 > 0 and d2 < limit2) try c.finding(r.a, rects.gapMidpoint(segBbox(e), segBbox(f)), .length(geom.ops.isqrt(d2)), .length(r.limit), report.no_shape);
    }
    return scratch.ran(examined);
}

/// Two parallel edges whose shapes lie between them (`inside`, a width:
/// sky130 poly.1b) or away from each other (a spacing: ASAP7 M4.S.2),
/// overlapping in projection by more than `prl`, closer than `limit`
/// straight across. `examined` counts the parallel pairs within reach that
/// overlap by more than `prl`.
pub fn facing(c: *const Ctx, layer: LayerId, limit: Dbu, prl: Dbu, inside: bool) Error!Verdict {
    const edges = c.store.edgesOnLayer(layer);
    if (!axisAligned(edges)) return report.refused;
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(c.gpa);
    try nearPairsInto(c.gpa, edges, edges, true, limit, &pairs);
    var examined: u64 = 0;
    for (pairs.items) |p| {
        const e = edges[p[0]];
        const f = edges[p[1]];
        if (horizontal(e) != horizontal(f) or (prl != 0 and run(e, f) <= prl)) continue;
        examined += 1;
        const gap = facingGap(e, f, inside) orelse continue;
        if (gap < limit) try c.finding(layer, rects.gapMidpoint(segBbox(e), segBbox(f)), .length(gap), .length(limit), report.no_shape);
    }
    return scratch.ran(examined);
}

/// Each edge enclosed by `outer` by at least the limit, straight out from
/// the edge across its length, on the side away from its shape (sky130
/// n/psd.5a). `examined` counts edges.
pub fn enclosure(c: *const Ctx, r: rows.EdgeEnclosure) Error!Verdict {
    const gpa = c.gpa;
    const list = c.store.edgesOnLayer(r.edges);
    const drawn = try c.s.p.validated.get(gpa, c.store, r.outer) orelse return report.refused;
    if (!axisAligned(list)) return report.refused;
    var figures: ValidatedLayer = .empty;
    defer figures.deinit(gpa);
    try geom.derive.mergeInto(gpa, drawn, &figures);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, &figures, &boxes, &start);
    const zeros = try gpa.alloc(u32, boxes.items.len);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    var outer: rects.SortedRects = .{};
    defer outer.deinit(gpa);
    try outer.build(gpa, boxes.items, zeros);
    for (list) |e| {
        if (e.a.eql(e.b)) continue;
        const measured = try coveredDepth(gpa, e, r.limit, &outer);
        if (measured < r.limit) try c.finding(r.edges, geom.ops.centre(segBbox(e)), .length(measured), .length(r.limit), report.no_shape);
    }
    return scratch.ran(list.len);
}

// ---- private ----

fn axisAligned(edges: []const Seg) bool {
    for (edges) |e| if (e.a.x != e.b.x and e.a.y != e.b.y) return false;
    return true;
}

fn horizontal(e: Seg) bool {
    return e.a.y == e.b.y;
}

fn length(e: Seg) Dbu {
    const b = segBbox(e);
    return (b.xhi - b.xlo) + (b.yhi - b.ylo);
}

/// Edge pairs `(i into a, j into b)` whose boxes come within `limit` on
/// both axes, sorted; `i < j` when `b` is `a` itself.
fn nearPairsInto(gpa: Allocator, a: []const Seg, b: []const Seg, same: bool, limit: Dbu, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var by_xlo: std.ArrayList(struct { box: Bbox, j: u32 }) = .empty;
    defer by_xlo.deinit(gpa);
    var reach: i64 = 0;
    for (b, 0..) |e, j| {
        const box = segBbox(e);
        reach = @max(reach, box.xhi - box.xlo);
        try by_xlo.append(gpa, .{ .box = box, .j = @intCast(j) });
    }
    const Entry = @TypeOf(by_xlo.items[0]);
    std.mem.sort(Entry, by_xlo.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return x.box.xlo < y.box.xlo;
        }
    }.less);
    for (a, 0..) |e, i| {
        const r = segBbox(e);
        const lo = std.sort.partitionPoint(Entry, by_xlo.items, r.xlo - reach - limit, struct {
            fn before(bound: i64, q: Entry) bool {
                return q.box.xlo < bound;
            }
        }.before);
        for (by_xlo.items[lo..]) |q| {
            if (q.box.xlo > r.xhi + limit) break;
            const near = q.box.xlo - r.xhi < limit and r.xlo - q.box.xhi < limit and q.box.ylo - r.yhi < limit and r.ylo - q.box.yhi < limit;
            if (near and (!same or i < q.j)) try out.append(gpa, .{ @intCast(i), q.j });
        }
    }
    std.mem.sortUnstable([2]u32, out.items, {}, struct {
        fn less(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    }.less);
}

/// The sign of the normal into an axis edge's shape (its left side).
fn inward(e: Seg) [2]i64 {
    return .{ -std.math.sign(e.b.y - e.a.y), std.math.sign(e.b.x - e.a.x) };
}

/// The perpendicular gap between two parallel axis edges that are apart,
/// overlap in projection by a positive length, and face back to back
/// (`inside`) or face to face; null otherwise.
fn facingGap(e: Seg, f: Seg, inside: bool) ?Dbu {
    const be = segBbox(e);
    const bf = segBbox(f);
    const h = horizontal(e);
    if (h != horizontal(f)) return null;
    const overlap = if (h) @min(be.xhi, bf.xhi) - @max(be.xlo, bf.xlo) else @min(be.yhi, bf.yhi) - @max(be.ylo, bf.ylo);
    const from_e_to_f = if (h) bf.ylo - be.ylo else bf.xlo - be.xlo;
    if (overlap <= 0 or from_e_to_f == 0) return null;
    const toward = std.math.sign(from_e_to_f);
    const ne = inward(e);
    const nf = inward(f);
    const ae = if (h) ne[1] else ne[0];
    const af = if (h) nf[1] else nf[0];
    // Back to back: each edge's shape lies toward the other edge.
    const ok = if (inside) ae == toward and af == -toward else ae == -toward and af == toward;
    return if (ok) @intCast(@abs(from_e_to_f)) else null;
}

/// How far two parallel axis edges overlap along their line; negative when
/// they do not.
fn run(e: Seg, f: Seg) i64 {
    const be = segBbox(e);
    const bf = segBbox(f);
    return if (horizontal(e)) @min(be.xhi, bf.xhi) - @max(be.xlo, bf.xlo) else @min(be.yhi, bf.yhi) - @max(be.ylo, bf.ylo);
}

/// The strip `depth` deep outside an axis edge, whether its depth runs
/// along y, and +1 when depth grows with the coordinate.
const Strip = struct { band: Bbox, along_y: bool, sign: i64 };

fn strip(e: Seg, depth: Dbu) Strip {
    var b = segBbox(e);
    if (horizontal(e)) {
        // Travelling +x the shape is above, so outside is below.
        const sign: i64 = if (e.b.x > e.a.x) -1 else 1;
        b.ylo = clamped(if (sign < 0) e.a.y - depth else e.a.y);
        b.yhi = clamped(if (sign < 0) e.a.y else e.a.y + depth);
        return .{ .band = b, .along_y = true, .sign = sign };
    }
    // Travelling +y the shape is to the left, so outside is to the right.
    const sign: i64 = if (e.b.y > e.a.y) 1 else -1;
    b.xlo = clamped(if (sign < 0) e.a.x - depth else e.a.x);
    b.xhi = clamped(if (sign < 0) e.a.x else e.a.x + depth);
    return .{ .band = b, .along_y = false, .sign = sign };
}

/// How deep `outer` covers the strip outside `e` without a gap: the depth
/// of the first slice across the strip it does not cover, or `depth`.
fn coveredDepth(gpa: Allocator, e: Seg, depth: Dbu, outer: *const rects.SortedRects) Allocator.Error!Dbu {
    const s = strip(e, depth);
    var clips: std.ArrayList(Bbox) = .empty;
    defer clips.deinit(gpa);
    var hits = outer.overlapping(s.band);
    while (hits.next()) |h| try clips.append(gpa, h.clip);
    const origin = if (s.along_y) e.a.y else e.a.x;
    // Coverage across a slice changes only at a clip's near or far side.
    var cuts: std.ArrayList(i64) = .empty;
    defer cuts.deinit(gpa);
    try cuts.appendSlice(gpa, &.{ 0, depth });
    for (clips.items) |cl| {
        const lo = if (s.along_y) cl.ylo else cl.xlo;
        const hi = if (s.along_y) cl.yhi else cl.xhi;
        try cuts.appendSlice(gpa, &.{ (lo - origin) * s.sign, (hi - origin) * s.sign });
    }
    std.mem.sortUnstable(i64, cuts.items, {}, std.sort.asc(i64));
    var prev: ?i64 = null;
    for (cuts.items) |t| {
        defer prev = t;
        const p = prev orelse continue;
        if (p == t) continue;
        const near = origin + s.sign * p;
        const far = origin + s.sign * t;
        var slice = s.band;
        if (s.along_y) {
            slice.ylo = @min(near, far);
            slice.yhi = @max(near, far);
        } else {
            slice.xlo = @min(near, far);
            slice.xhi = @max(near, far);
        }
        var covered: DbuArea = 0;
        for (clips.items) |cl| if (cl.intersection(slice)) |x| {
            covered += x.area();
        };
        if (covered != slice.area()) return p;
    }
    return depth;
}

fn clamped(v: i64) i64 {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
