//! Region questions over validated layers, answered exactly: a layer cut
//! into labelled rectangles, which rectangles overlap a query, which drawn
//! row owns each merged figure, the boundary distance between two store
//! rows, and which store rows are holes of which outers. In: a
//! `GeometryStore` and `ValidatedLayer`s. Out: caller-owned tables and
//! exact integer measures. Ported from crates/check/src/drc/rules/mod.rs
//! (`LayerRects`..`poly_dist2`, `seg_dist2`, `figure_point`) and
//! crates/check/src/topology/net.rs (`Holes`, `in_material`).
//!
//! Contents:
//! - `pub const no_label: u32`
//! - `pub const LayerRects = struct`, `deinit`, `build(lr: *LayerRects, gpa: Allocator, store: *const GeometryStore, layer: LayerId, drawn: *const ValidatedLayer) Allocator.Error!void`,
//!   `len(lr: *const LayerRects) u32`, `of(lr: *const LayerRects, poly: u32) []const Bbox`,
//!   `rowLabelsInto(lr: *const LayerRects, gpa: Allocator, out: *std.ArrayList(u32)) Allocator.Error!void`
//! - `pub const SortedRects = struct`, `deinit`, `build(s: *SortedRects, gpa: Allocator, rects: []const Bbox, labels: []const u32) Allocator.Error!void`,
//!   `overlapping(s: *const SortedRects, q: Bbox) Overlap`, `Overlap.next(o: *Overlap) ?Hit`, `pub const Hit = struct { clip: Bbox, label: u32 }`
//! - `pub fn figureRectsInto(gpa: Allocator, figures: *const ValidatedLayer, out: *SortedRects) Allocator.Error!void`
//! - `pub fn ownersOfInto(gpa: Allocator, figures: *const ValidatedLayer, drawn: *const LayerRects, out: *std.ArrayList(PolyId)) Allocator.Error!void`
//! - `pub fn ownersByPointInto(gpa: Allocator, figures: *const ValidatedLayer, drawn: *const ValidatedLayer, out: *std.ArrayList(PolyId)) Allocator.Error!void`
//! - `pub fn figuresHolding(gpa: Allocator, figures: *const ValidatedLayer, drawn: *const ValidatedLayer, home: []?u32) Allocator.Error!void`
//! - `pub fn figurePoint(poly: Polygon) Point`
//! - `pub fn mid(a: Dbu, b: Dbu) Dbu`, `pub fn gapMidpoint(a: Bbox, b: Bbox) Point`, `pub fn segBbox(s: Seg) Bbox`
//! - `pub fn bboxGap2(a: Bbox, b: Bbox) DbuArea`
//! - `pub fn polyDist2(store: *const GeometryStore, a: PolyId, b: PolyId) DbuArea`
//! - `pub fn segDist2(p: Seg, q: Seg) DbuArea`
//! - `pub const Holes = struct`, `deinit`, `build(h: *Holes, gpa: Allocator, store: *const GeometryStore, layers: []const LayerId) Allocator.Error!void`,
//!   `isHole(h: *const Holes, poly: PolyId) bool`, `holesOf(h: *const Holes, outer: PolyId) []const PolyId`,
//!   `outers(h: *const Holes) []const PolyId`, `holes(h: *const Holes) []const PolyId`
//! - `pub fn inMaterial(store: *const GeometryStore, holes: *const Holes, outer: PolyId, p: Point) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const Polygon = geom.Polygon;
const ops = geom.ops;
const derive = geom.derive;
const no_shape = @import("report.zig").no_shape;

/// A `LayerRects.poly_of_row` slot no polygon claimed (a row of a layer
/// validated elsewhere).
pub const no_label: u32 = std.math.maxInt(u32);

/// A layer validated straight from the store, cut into disjoint rectangles,
/// CSR by polygon, so containment and overlap areas are exact sums.
/// Invariant: `start` is CSR over `rects`, one longer than `row`.
pub const LayerRects = struct {
    rects: std.ArrayList(Bbox) = .empty,
    start: std.ArrayList(u32) = .empty,
    /// Per store row on the layer (offset from its first), the polygon
    /// holding it, holes included.
    poly_of_row: std.ArrayList(u32) = .empty,
    /// Each polygon's outer store row.
    row: std.ArrayList(PolyId) = .empty,

    pub fn deinit(lr: *LayerRects, gpa: Allocator) void {
        lr.rects.deinit(gpa);
        lr.start.deinit(gpa);
        lr.poly_of_row.deinit(gpa);
        lr.row.deinit(gpa);
    }

    /// Refills from one layer validated straight from `store`; asserts it is
    /// rectilinear (as the decomposition does).
    pub fn build(lr: *LayerRects, gpa: Allocator, store: *const GeometryStore, layer: LayerId, drawn: *const ValidatedLayer) Allocator.Error!void {
        try geom.rects.decomposeInto(gpa, drawn, &lr.rects, &lr.start);
        const rows = store.polysOnLayer(layer);
        try lr.poly_of_row.resize(gpa, rows.len());
        @memset(lr.poly_of_row.items, no_label);
        try lr.row.resize(gpa, drawn.len());
        for (lr.row.items, 0..) |*outer, poly| {
            const p = drawn.get(@intCast(poly));
            for (0..p.ringCount()) |k| lr.poly_of_row.items[@backingInt(p.row(@intCast(k))) - rows.start] = @intCast(poly);
            outer.* = p.provenance();
        }
    }

    pub fn len(lr: *const LayerRects) u32 {
        return @intCast(lr.row.items.len);
    }

    /// Polygon `poly`'s rectangles.
    pub fn of(lr: *const LayerRects, poly: u32) []const Bbox {
        return lr.rects.items[lr.start.items[poly]..lr.start.items[poly + 1]];
    }

    /// Each rectangle's polygon's outer row, parallel to `rects`, into `out`
    /// (cleared and refilled): the labels `SortedRects.build` takes.
    pub fn rowLabelsInto(lr: *const LayerRects, gpa: Allocator, out: *std.ArrayList(u32)) Allocator.Error!void {
        try out.resize(gpa, lr.rects.items.len);
        for (lr.row.items, lr.start.items[0..lr.row.items.len], lr.start.items[1..]) |row, from, to| {
            @memset(out.items[from..to], @backingInt(row));
        }
    }
};

/// Labelled rectangles sorted by `xlo` (ties by input order), for "which of
/// these overlap that with positive area". A label is a `u32`: a figure, a
/// store row, a net. Invariant: `rects` ascends by `xlo`, parallel to
/// `labels`; `reach` is the widest rectangle.
pub const SortedRects = struct {
    rects: std.ArrayList(Bbox) = .empty,
    labels: std.ArrayList(u32) = .empty,
    /// How far left of a query a hit can start.
    reach: i64 = 0,

    pub const Hit = struct { clip: Bbox, label: u32 };

    /// The hits of one query, in `xlo` order.
    pub const Overlap = struct {
        s: *const SortedRects,
        q: Bbox,
        at: usize,
        end: usize,

        /// The next rectangle overlapping the query with positive area,
        /// clipped to it.
        pub fn next(o: *Overlap) ?Hit {
            while (o.at < o.end) {
                const i = o.at;
                o.at += 1;
                const c = o.s.rects.items[i].intersection(o.q) orelse continue;
                if (c.xlo < c.xhi and c.ylo < c.yhi) return .{ .clip = c, .label = o.s.labels.items[i] };
            }
            return null;
        }
    };

    pub fn deinit(s: *SortedRects, gpa: Allocator) void {
        s.rects.deinit(gpa);
        s.labels.deinit(gpa);
    }

    /// Refills from parallel `rects` and `labels`.
    pub fn build(s: *SortedRects, gpa: Allocator, rects: []const Bbox, labels: []const u32) Allocator.Error!void {
        assert(rects.len == labels.len and rects.len <= std.math.maxInt(u32));
        const perm = try gpa.alloc(u32, rects.len);
        defer gpa.free(perm);
        for (perm, 0..) |*p, i| p.* = @intCast(i);
        std.mem.sortUnstable(u32, perm, rects, struct {
            fn less(r: []const Bbox, a: u32, b: u32) bool {
                return r[a].xlo < r[b].xlo or (r[a].xlo == r[b].xlo and a < b);
            }
        }.less);
        try s.rects.resize(gpa, rects.len);
        try s.labels.resize(gpa, rects.len);
        s.reach = 0;
        for (perm, s.rects.items, s.labels.items) |p, *r, *l| {
            r.* = rects[p];
            l.* = labels[p];
            s.reach = @max(s.reach, r.xhi - r.xlo);
        }
    }

    pub fn overlapping(s: *const SortedRects, q: Bbox) Overlap {
        const items = s.rects.items;
        const lo = partition(items, q.xlo - s.reach, false);
        const hi = partition(items, q.xhi, false);
        return .{ .s = s, .q = q, .at = lo, .end = @max(hi, lo) };
    }
};

/// A store keeps a polygon's hole as its own clockwise row; this binds each
/// hole row to its outer, so nothing drawn inside a hole touches the ring.
/// Invariant: `owner` has one slot per store row; `of_outer`/`of_hole` are
/// parallel, ascending by `(outer, hole)`.
pub const Holes = struct {
    owner: std.ArrayList(u32) = .empty,
    of_outer: std.ArrayList(PolyId) = .empty,
    of_hole: std.ArrayList(PolyId) = .empty,
    /// Validation scratch, dead between builds.
    layer: ValidatedLayer = .empty,

    pub fn deinit(h: *Holes, gpa: Allocator) void {
        h.owner.deinit(gpa);
        h.of_outer.deinit(gpa);
        h.of_hole.deinit(gpa);
        h.layer.deinit(gpa);
    }

    /// Rebinds for `layers` of `store`. A layer that fails octilinear
    /// validation keeps its rows as drawn: DRC reports the invalid shape.
    pub fn build(h: *Holes, gpa: Allocator, store: *const GeometryStore, layers: []const LayerId) Allocator.Error!void {
        try h.owner.resize(gpa, store.polyCount());
        @memset(h.owner.items, no_owner);
        var keys: std.ArrayList(u64) = .empty;
        defer keys.deinit(gpa);
        for (layers) |layer| {
            const rows = store.polysOnLayer(layer);
            const clockwise = for (rows.start..rows.end) |row| {
                const r = store.polyVerts(@fromBackingInt(@intCast(row)));
                if (ops.windingOf(r.xs, r.ys) == .cw) break true;
            } else false;
            if (!clockwise) continue;
            if (try geom.view.validateLayer(gpa, store, layer, .octilinear, &h.layer) != null) continue;
            for (0..h.layer.len()) |poly| {
                const p = h.layer.get(@intCast(poly));
                const outer = @backingInt(p.row(0));
                for (1..p.ringCount()) |k| {
                    const hole = @backingInt(p.row(@intCast(k)));
                    h.owner.items[hole] = outer;
                    try keys.append(gpa, @as(u64, outer) << 32 | hole);
                }
            }
        }
        std.mem.sortUnstable(u64, keys.items, {}, std.sort.asc(u64));
        try h.of_outer.resize(gpa, keys.items.len);
        try h.of_hole.resize(gpa, keys.items.len);
        for (keys.items, h.of_outer.items, h.of_hole.items) |k, *o, *x| {
            o.* = @fromBackingInt(@intCast(k >> 32));
            x.* = @fromBackingInt(@truncate(k));
        }
    }

    pub fn isHole(h: *const Holes, poly: PolyId) bool {
        const i = @backingInt(poly);
        return i < h.owner.items.len and h.owner.items[i] != no_owner;
    }

    /// The hole rows bound to `outer`, ascending.
    pub fn holesOf(h: *const Holes, outer: PolyId) []const PolyId {
        const from = std.sort.lowerBound(PolyId, h.of_outer.items, outer, orderPoly);
        const to = std.sort.upperBound(PolyId, h.of_outer.items, outer, orderPoly);
        return h.of_hole.items[from..to];
    }

    /// Every binding's outer, parallel to `holes()`, ascending.
    pub fn outers(h: *const Holes) []const PolyId {
        return h.of_outer.items;
    }

    pub fn holes(h: *const Holes) []const PolyId {
        return h.of_hole.items;
    }
};

const no_owner: u32 = std.math.maxInt(u32);

/// A merged layer's rectangles, each labelled with its figure, into `out`.
pub fn figureRectsInto(gpa: Allocator, figures: *const ValidatedLayer, out: *SortedRects) Allocator.Error!void {
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, figures, &rects, &start);
    const labels = try gpa.alloc(u32, rects.items.len);
    defer gpa.free(labels);
    for (start.items[0 .. start.items.len - 1], start.items[1..], 0..) |from, to, f| @memset(labels[from..to], @intCast(f));
    try out.build(gpa, rects.items, labels);
}

/// The lowest drawn row under each figure of `figures` (a boolean result,
/// whose own rows are its scratch store's), into `out` (cleared and
/// refilled); `no_shape` for a figure over nothing drawn. Both rectilinear.
pub fn ownersOfInto(gpa: Allocator, figures: *const ValidatedLayer, drawn: *const LayerRects, out: *std.ArrayList(PolyId)) Allocator.Error!void {
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try drawn.rowLabelsInto(gpa, &labels);
    var under: SortedRects = .{};
    defer under.deinit(gpa);
    try under.build(gpa, drawn.rects.items, labels.items);
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, figures, &rects, &start);
    try out.resize(gpa, figures.len());
    for (out.items, start.items[0..figures.len()], start.items[1..]) |*owner, from, to| {
        var least: u32 = std.math.maxInt(u32);
        for (rects.items[from..to]) |r| {
            var hits = under.overlapping(r);
            while (hits.next()) |h| least = @min(least, h.label);
        }
        owner.* = @fromBackingInt(least);
    }
}

/// The lowest drawn row inside each figure of `figures` (the merge of
/// `drawn`), either at 45 degrees: each drawn polygon lies in exactly one
/// figure, found by a point inside it. `no_shape` for a figure holding none.
pub fn ownersByPointInto(gpa: Allocator, figures: *const ValidatedLayer, drawn: *const ValidatedLayer, out: *std.ArrayList(PolyId)) Allocator.Error!void {
    try out.resize(gpa, figures.len());
    @memset(out.items, no_shape);
    const home = try gpa.alloc(?u32, drawn.len());
    defer gpa.free(home);
    try figuresHolding(gpa, figures, drawn, home);
    for (home, 0..) |h, poly| {
        const figure = h orelse continue;
        const row = drawn.get(@intCast(poly)).provenance();
        if (@backingInt(row) < @backingInt(out.items[figure])) out.items[figure] = row;
    }
}

/// Per polygon of `drawn`, into `home`: the figure of `figures` holding a
/// point just inside it near its lowest convex corner, or null. Where
/// `figures` is the merge of a layer `drawn` lies in, the figure it lies in.
pub fn figuresHolding(gpa: Allocator, figures: *const ValidatedLayer, drawn: *const ValidatedLayer, home: []?u32) Allocator.Error!void {
    assert(home.len == drawn.len());
    if (!(figures.isOctilinear() and drawn.isOctilinear())) {
        // At any angle no point near a corner is safely inside at a small
        // scale: the figure sharing area.
        return derive.holdingFigures(gpa, figures, drawn, home);
    }
    var by_xlo: SortedRects = .{};
    defer by_xlo.deinit(gpa);
    const ids = try gpa.alloc(u32, figures.len());
    defer gpa.free(ids);
    for (ids, 0..) |*id, f| id.* = @intCast(f);
    try by_xlo.build(gpa, figures.bboxes(), ids);
    for (home, 0..) |*slot, poly| {
        const shape = drawn.get(@intCast(poly));
        const p8 = derive.interiorPoint8(shape);
        const b = shape.bbox();
        // A figure holding the shape starts at or left of it, within reach.
        const lo = partition(by_xlo.rects.items, b.xhi - by_xlo.reach, false);
        const hi = partition(by_xlo.rects.items, b.xlo, true);
        slot.* = null;
        for (by_xlo.rects.items[lo..@max(hi, lo)], by_xlo.labels.items[lo..@max(hi, lo)]) |f, figure| {
            if (f.contains(b) and derive.containsScaled(figures.get(figure), p8[0], p8[1], 8)) {
                slot.* = figure;
                break;
            }
        }
    }
}

/// A point of a figure's material for its marker: one step inside from its
/// lowest convex corner, floored to the grid; for a figure with an edge at
/// another angle than a multiple of 45 degrees, that corner itself.
pub fn figurePoint(poly: Polygon) Point {
    const r = poly.outer();
    var skew = false;
    for (0..r.xs.len) |i| {
        const e = ops.ringEdge(r.xs, r.ys, i);
        const dx = e.b.x - e.a.x;
        const dy = e.b.y - e.a.y;
        skew = skew or (dx != 0 and dy != 0 and @abs(dx) != @abs(dy));
    }
    if (skew) {
        var v: usize = 0;
        for (1..r.xs.len) |i| {
            if (r.ys[i] < r.ys[v] or (r.ys[i] == r.ys[v] and r.xs[i] < r.xs[v])) v = i;
        }
        return .{ .x = r.xs[v], .y = r.ys[v] };
    }
    const p8 = derive.interiorPoint8(poly);
    return .{ .x = @divFloor(p8[0], 8), .y = @divFloor(p8[1], 8) };
}

/// Midpoint of two coordinates, floored on both sides of the origin.
pub fn mid(a: Dbu, b: Dbu) Dbu {
    return @divFloor(a + b, 2);
}

/// The middle of the interval two boxes share, or of the gap between them:
/// a pairwise violation's report point.
pub fn gapMidpoint(a: Bbox, b: Bbox) Point {
    return .{ .x = mid(@max(a.xlo, b.xlo), @min(a.xhi, b.xhi)), .y = mid(@max(a.ylo, b.ylo), @min(a.yhi, b.yhi)) };
}

pub fn segBbox(s: Seg) Bbox {
    return Bbox.point(s.a.x, s.a.y).include(s.b.x, s.b.y);
}

/// Squared distance between two boxes, zero where they touch or overlap: a
/// lower bound on the distance between anything inside them.
pub fn bboxGap2(a: Bbox, b: Bbox) DbuArea {
    const dx: DbuArea = @max(@max(a.xlo, b.xlo) - @min(a.xhi, b.xhi), 0);
    const dy: DbuArea = @max(@max(a.ylo, b.ylo) - @min(a.yhi, b.yhi), 0);
    return dx * dx + dy * dy;
}

/// Squared distance between two store rows' boundaries, as `segDist2` reads
/// each pair of edges; zero exactly when they touch or cross. Quadratic in
/// the two ring sizes, box-pruned.
pub fn polyDist2(store: *const GeometryStore, a: PolyId, b: PolyId) DbuArea {
    const ra = store.polyVerts(a);
    const rb = store.polyVerts(b);
    const box_b = Bbox.ofPoints(rb.xs, rb.ys);
    var best: DbuArea = std.math.maxInt(DbuArea);
    for (0..ra.xs.len) |i| {
        const sa = ops.ringEdge(ra.xs, ra.ys, i);
        const box_a = segBbox(sa);
        if (bboxGap2(box_a, box_b) >= best) continue;
        for (0..rb.xs.len) |j| {
            const sb = ops.ringEdge(rb.xs, rb.ys, j);
            if (bboxGap2(box_a, segBbox(sb)) < best) best = @min(best, segDist2(sa, sb));
        }
    }
    return best;
}

/// Squared distance between two segments as the spacing family compares
/// it. Exact for axis-parallel segments; at 45 degrees a half unit is
/// floored, which compares against any whole squared limit as the true value
/// does (`24.5 < 25` and `24 < 25`); at any other angle the fraction is
/// floored the same way. A gap under one unit reads 1, so only touching
/// reads 0.
pub fn segDist2(p: Seg, q: Seg) DbuArea {
    const dp = [2]i64{ p.b.x - p.a.x, p.b.y - p.a.y };
    const dq = [2]i64{ q.b.x - q.a.x, q.b.y - q.a.y };
    if (isAxis(dp) and isAxis(dq)) return ops.segSegDist2(p, q);
    const twice: ops.Twice = if (isOctilinear(dp) and isOctilinear(dq))
        .whole(ops.segSegNear2(p, q).d2)
    else
        ops.segSegTwice2(p, q);
    if (twice.floor == 0 and !twice.inexact) return 0;
    return @max(@divTrunc(twice.floor, 2), 1);
}

/// Inside the outer ring and inside none of its holes, boundaries counting
/// as inside.
pub fn inMaterial(store: *const GeometryStore, holes: *const Holes, outer: PolyId, p: Point) bool {
    if (!store.polyContainsPoint(outer, p)) return false;
    for (holes.holesOf(outer)) |hole| if (store.polyContainsPoint(hole, p)) return false;
    return true;
}

// ---- private ----

/// The first rectangle whose `xlo` is not below `bound` (`inclusive`: not
/// at or below), over rectangles ascending by `xlo`.
fn partition(rects: []const Bbox, bound: i64, inclusive: bool) usize {
    var lo: usize = 0;
    var hi: usize = rects.len;
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        const before = if (inclusive) rects[m].xlo <= bound else rects[m].xlo < bound;
        if (before) lo = m + 1 else hi = m;
    }
    return lo;
}

fn isAxis(d: [2]i64) bool {
    return d[0] == 0 or d[1] == 0;
}

fn isOctilinear(d: [2]i64) bool {
    return d[0] == 0 or d[1] == 0 or @abs(d[0]) == @abs(d[1]);
}

fn orderPoly(want: PolyId, item: PolyId) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(item));
}

fn seg(ax: i64, ay: i64, bx: i64, by: i64) Seg {
    return .{ .a = .{ .x = ax, .y = ay }, .b = .{ .x = bx, .y = by } };
}

test "segDist2 floors 45-degree half units and other angles alike" {
    // Oracle: `seg_dist2`'s contract, hand values. Two 45-degree lines `y =
    // x` and `y = x + 7` are `7/√2` apart, squared 24.5, floored to 24 (a
    // rounding up would read 25); `y = x + 1` is squared 0.5, read 1;
    // touching reads 0; axis-aligned segments 3 along and 4 across read 16.
    // Segments of slope 1/2 on `y = x/2` and `y = x/2 + 3` are `3/√1.25`
    // apart, squared `9 - 9/5 = 7.2`: floored to 7 (a rounding up would
    // read 8).
    const diagonal = seg(0, 0, 10, 10);
    try std.testing.expectEqual(@as(DbuArea, 24), segDist2(diagonal, seg(0, 7, 10, 17)));
    try std.testing.expectEqual(@as(DbuArea, 1), segDist2(diagonal, seg(0, 1, 10, 11)));
    try std.testing.expectEqual(@as(DbuArea, 0), segDist2(diagonal, seg(10, 10, 20, 0)));
    try std.testing.expectEqual(@as(DbuArea, 16 + 9), segDist2(seg(0, 0, 10, 0), seg(13, 4, 23, 4)));
    try std.testing.expectEqual(@as(DbuArea, 16), segDist2(seg(0, 0, 10, 0), seg(3, 4, 13, 4)));
    try std.testing.expectEqual(@as(DbuArea, 7), segDist2(seg(0, 0, 20, 10), seg(0, 3, 20, 13)));
}

test "sorted rects answer overlap queries as a brute-force scan does" {
    // Oracle: brute force. Every query's hits, clipped, equal the scan of
    // every rectangle keeping a positive-area intersection, in xlo order.
    const gpa = std.testing.allocator;
    var rects: [40]Bbox = undefined;
    var labels: [40]u32 = undefined;
    var state: u64 = 0x2545_f491_4f6c_dd1d;
    for (&rects, &labels, 0..) |*r, *l, i| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const x: i64 = @intCast((state >> 33) % 200);
        const y: i64 = @intCast((state >> 13) % 200);
        const w: i64 = @intCast(1 + (state >> 45) % 60);
        r.* = .{ .xlo = x, .ylo = y, .xhi = x + w, .yhi = y + @divTrunc(w, 2) + 1 };
        l.* = @intCast(i);
    }
    var sorted: SortedRects = .{};
    defer sorted.deinit(gpa);
    try sorted.build(gpa, &rects, &labels);
    var q: i64 = 0;
    while (q < 240) : (q += 17) {
        const query: Bbox = .{ .xlo = q, .ylo = @divTrunc(q, 2), .xhi = q + 30, .yhi = @divTrunc(q, 2) + 50 };
        var got: u64 = 0;
        var count: usize = 0;
        var hits = sorted.overlapping(query);
        while (hits.next()) |h| {
            got |= @as(u64, 1) << @intCast(h.label);
            count += 1;
            try std.testing.expectEqual(rects[h.label].intersection(query).?, h.clip);
        }
        var want: u64 = 0;
        for (rects, 0..) |r, i| if (r.intersection(query)) |c| if (c.xlo < c.xhi and c.ylo < c.yhi) {
            want |= @as(u64, 1) << @intCast(i);
        };
        try std.testing.expectEqual(want, got);
        try std.testing.expectEqual(@as(usize, @popCount(want)), count);
    }
}
