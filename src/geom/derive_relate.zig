//! Selection of whole polygons by their relation to another layer:
//! interacting, inside, outside, overlapping, covering, and the figure each
//! part lies in. In: merged `ValidatedLayer`s. Out: a selection of `a`
//! (`*Into`, polygons kept with their store rows) or one flag per polygon.
//! KLayout's definitions; exact at any angle. Ported from
//! crates/geom/src/derive.rs (the relations).
//!
//! Contents:
//! - `pub fn interactingInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, keep: bool, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn insideInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn insideFlags(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, flags: []bool) Allocator.Error!void`
//! - `pub fn outsideInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn overlappingInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, keep: bool, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn overlappingFlags(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, flags: []bool) Allocator.Error!void`
//! - `pub fn coveringInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, keep: bool, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn holdingFigures(gpa: Allocator, figures: *const ValidatedLayer, parts: *const ValidatedLayer, home: []?u32) Allocator.Error!void`
//! - `pub fn interiorPoint8(poly: Polygon) [2]i64`
//! - `pub fn containsScaled(poly: Polygon, px: i64, py: i64, scale: i64) bool`
//! - `pub fn insideAny(layer: *const ValidatedLayer, polys: []const u32, px: i64, py: i64, scale: i64) bool`
//! - `pub fn boxPairs(gpa: Allocator, a: []const Bbox, b: []const Bbox, out: *std.ArrayList([2]u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Bbox = @import("bbox.zig").Bbox;
const ops = @import("ops.zig");
const Point = ops.Point;
const Seg = ops.Seg;
const store_mod = @import("store.zig");
const view = @import("view.zig");
const ValidatedLayer = view.ValidatedLayer;
const Polygon = view.Polygon;
const index = @import("index.zig");
const boolean = @import("boolean.zig");
const width = @import("width.zig");

/// KLayout `interacting` (`keep`) / `not_interacting`: polygons of `a` that
/// touch or overlap `b`; a shared corner counts.
pub fn interactingInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, keep: bool, out: *ValidatedLayer) Allocator.Error!void {
    // ponytail: pairwise edge test, O(edges(p) * edges(q)) per candidate
    // pair; a per-pair sweep if huge merged polygons make this slow.
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    try boxPairs(gpa, a.bboxes(), b.bboxes(), &pairs);
    const hit = try gpa.alloc(bool, a.len());
    defer gpa.free(hit);
    @memset(hit, !keep);
    for (pairs.items) |pq| {
        if (polysMeet(a.get(pq[0]), b.get(pq[1]))) hit[pq[0]] = keep;
    }
    try a.selectInto(gpa, hit, out);
}

/// KLayout `inside`: polygons of `a` covered by `b`; touching `b`'s
/// boundary from inside is covered.
pub fn insideInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void {
    const flags = try gpa.alloc(bool, a.len());
    defer gpa.free(flags);
    try insideFlags(gpa, a, b, flags);
    try a.selectInto(gpa, flags, out);
}

/// Per polygon of `a`: whether `b` covers it (`insideInto`'s test). Where
/// polygons of `a` overlap, a part of their union `b` leaves uncovered
/// counts against each that holds a point of it near its lowest convex
/// corner. Asserts one flag per polygon.
pub fn insideFlags(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, flags: []bool) Allocator.Error!void {
    var rest: ValidatedLayer = .empty;
    defer rest.deinit(gpa);
    try boolean.subtractionInto(gpa, a, b, &rest);
    try freeOf(gpa, a, &rest, flags);
}

/// KLayout `outside`: polygons of `a` sharing no area with `b`; touching is
/// outside.
pub fn outsideInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void {
    return overlappingInto(gpa, a, b, false, out);
}

/// KLayout `overlapping` (`keep`): polygons of `a` sharing area with `b`;
/// touching is not overlapping. `!keep` is `outsideInto`.
pub fn overlappingInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, keep: bool, out: *ValidatedLayer) Allocator.Error!void {
    const flags = try gpa.alloc(bool, a.len());
    defer gpa.free(flags);
    try overlappingFlags(gpa, a, b, flags);
    for (flags) |*f| f.* = f.* == keep;
    try a.selectInto(gpa, flags, out);
}

/// Per polygon of `a`, in order: whether it shares area with `b`. Touching
/// is not sharing.
pub fn overlappingFlags(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, flags: []bool) Allocator.Error!void {
    var common: ValidatedLayer = .empty;
    defer common.deinit(gpa);
    try boolean.intersectionInto(gpa, a, b, &common);
    try freeOf(gpa, a, &common, flags);
    for (flags) |*f| f.* = !f.*;
}

/// KLayout `covering` (`keep`) / `not_covering`: polygons of `a` that hold a
/// whole polygon of `b`, which may touch `a`'s boundary from inside
/// (`insideInto` with the operands swapped).
pub fn coveringInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, keep: bool, out: *ValidatedLayer) Allocator.Error!void {
    var held: ValidatedLayer = .empty;
    defer held.deinit(gpa);
    try insideInto(gpa, b, a, &held);
    // Each held polygon is connected and inside `a`, so it lies in one
    // polygon of `a`.
    const flags = try gpa.alloc(bool, a.len());
    defer gpa.free(flags);
    try freeOf(gpa, a, &held, flags);
    for (flags) |*f| f.* = f.* != keep;
    try a.selectInto(gpa, flags, out);
}

/// Per polygon of `parts`: the lowest polygon of `figures` it shares area
/// with, or null, into `home` (one row per part). Where `figures` is a merge
/// that `parts` lies in, that is the figure holding it, at any angle.
pub fn holdingFigures(gpa: Allocator, figures: *const ValidatedLayer, parts: *const ValidatedLayer, home: []?u32) Allocator.Error!void {
    // ponytail: a boolean per pair whose boxes meet; one overlay sweep
    // labelling both operands' faces if large any-angle layers get slow.
    assert(home.len == parts.len());
    @memset(home, null);
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    try sharingArea(gpa, parts, figures, &pairs);
    for (pairs.items) |ji| {
        if (home[ji[0]] == null) home[ji[0]] = ji[1];
    }
}

/// A point strictly inside a polygon's material, at eight times scale: one
/// step into the material from a convex corner of its outer ring, along the
/// corner's bisector, trying the corners lowest first. On the octilinear
/// grid no edge but those through a vertex passes within `1/√2` of it, so a
/// step of at most `√8 / 8` stays in the corner. Asserts one is found, which
/// validation guarantees.
pub fn interiorPoint8(poly: Polygon) [2]i64 {
    const r = poly.outer();
    const n = r.xs.len;
    var best: ?[2]i64 = null;
    var best_key: [2]i64 = undefined;
    // Lowest, then leftmost, convex corner whose probe lands in material;
    // a linear scan for the least key, retried past corners that fail.
    var tried_below: ?[2]i64 = null;
    while (best == null) {
        var found: ?usize = null;
        for (0..n) |v| {
            const key = [2]i64{ r.ys[v], r.xs[v] };
            if (tried_below) |t| if (std.mem.order(i64, &key, &t) != .gt) continue;
            if (found == null or std.mem.order(i64, &key, &best_key) == .lt) {
                found = v;
                best_key = key;
            }
        }
        // Panics on a polygon with no such corner, which validation rules out.
        const v = found.?;
        tried_below = best_key;
        // Every visit of this point, in ring order.
        for (0..n) |w| {
            if (r.xs[w] != r.xs[v] or r.ys[w] != r.ys[v]) continue;
            const back = toward(r, w, (w + n - 1) % n);
            const on = toward(r, w, (w + 1) % n);
            // Convex: turning left from the way in (`-back`) to the way out.
            if (back[1] * on[0] - back[0] * on[1] <= 0) continue;
            const probe = [2]i64{ 8 * r.xs[w] + back[0] + on[0], 8 * r.ys[w] + back[1] + on[1] };
            if (containsScaled(poly, probe[0], probe[1], 8)) {
                best = probe;
                break;
            }
        }
    }
    return best.?;
}

/// Whether the point `(px / scale, py / scale)`, on none of its rings, is in
/// a polygon's material: inside its outer and no hole. Exact at any angle.
pub fn containsScaled(poly: Polygon, px: i64, py: i64, scale: i64) bool {
    return crossesOdd(poly, px, py, scale);
}

/// Even-odd over several polygons of one layer: the point lies in an odd
/// number of their rings.
pub fn insideAny(layer: *const ValidatedLayer, polys: []const u32, px: i64, py: i64, scale: i64) bool {
    var inside = false;
    for (polys) |p| inside = inside != crossesOdd(layer.get(p), px, py, scale);
    return inside;
}

/// Every `(i, j)` whose boxes share a point, `i` into `a` and `j` into `b`,
/// into `out` (cleared and refilled), ascending.
pub fn boxPairs(gpa: Allocator, a: []const Bbox, b: []const Bbox, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (a.len == 0 or b.len == 0) return;
    var builder: store_mod.GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    try builder.ensureUnusedCapacity(gpa, a.len + b.len, 2 * (a.len + b.len));
    for ([2][]const Bbox{ a, b }, 0..) |boxes, layer| {
        for (boxes) |r| _ = try builder.push(gpa, @fromBackingInt(@intCast(layer)), &.{ r.xlo, r.xhi }, &.{ r.ylo, r.yhi });
    }
    var store: store_mod.GeometryStore = .empty;
    defer store.deinit(gpa);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try builder.finish(gpa, 2, &store, &perm);
    var ix: index.SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, @fromBackingInt(1));
    var pairs: std.ArrayList(index.Pair) = .empty;
    defer pairs.deinit(gpa);
    try index.crossLayerPairsInto(gpa, &store, @fromBackingInt(0), &ix, 0, &pairs);
    const first_b: u32 = @intCast(a.len);
    for (pairs.items) |p| try out.append(gpa, .{ @backingInt(p.a), @backingInt(p.b) - first_b });
}

// ---- private ----

fn toward(r: ops.Ring, from: usize, to: usize) [2]i64 {
    return .{ std.math.sign(r.xs[to] - r.xs[from]), std.math.sign(r.ys[to] - r.ys[from]) };
}

/// Even-odd for `(px / scale, py / scale)`, on no ring: the edges a `+x` ray
/// crosses, half-open in y, exactly at any angle.
fn crossesOdd(poly: Polygon, px0: i64, py0: i64, scale: i64) bool {
    const k: i128 = scale;
    const px: i128 = px0;
    const py: i128 = py0;
    var inside = false;
    var it = width.polyEdges(poly);
    while (it.next()) |s| {
        const ax = @as(i128, s.a.x) * k;
        const ay = @as(i128, s.a.y) * k;
        const bx = @as(i128, s.b.x) * k;
        const by = @as(i128, s.b.y) * k;
        if ((ay > py) != (by > py)) {
            // Left of an upward edge, or right of a downward one, is where
            // the ray crosses it.
            const side = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
            if ((side > 0) == (by > ay)) inside = !inside;
        }
    }
    return inside;
}

/// Whether two closed polygons share a point: their boundaries meet, or one
/// lies inside the other.
fn polysMeet(p: Polygon, q: Polygon) bool {
    var ip = width.polyEdges(p);
    while (ip.next()) |s| {
        var iq = width.polyEdges(q);
        while (iq.next()) |t| if (ops.segmentsIntersect(s, t)) return true;
    }
    // No boundary contact: a vertex of either is off the other's rings.
    const pv = p.outer();
    const qv = q.outer();
    return containsScaled(q, 2 * pv.xs[0], 2 * pv.ys[0], 2) or containsScaled(p, 2 * qv.xs[0], 2 * qv.ys[0], 2);
}

/// Per polygon of `a`: false when it holds part of `parts` (a subset of `a`
/// by area), else true, into `free`.
fn freeOf(gpa: Allocator, a: *const ValidatedLayer, parts: *const ValidatedLayer, free: []bool) Allocator.Error!void {
    assert(free.len == a.len());
    @memset(free, true);
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    if (!(a.isOctilinear() and parts.isOctilinear())) {
        // At any angle no point near a corner is safely inside at a small
        // fixed scale: a polygon holds part of `parts` exactly when their
        // intersection has area.
        try sharingArea(gpa, a, parts, &pairs);
        for (pairs.items) |pq| free[pq[0]] = false;
        return;
    }
    // One point inside each part: it lies inside exactly one polygon of `a`.
    const probes = try gpa.alloc([2]i64, parts.len());
    defer gpa.free(probes);
    for (probes, 0..) |*p, i| p.* = interiorPoint8(parts.get(@intCast(i)));
    try boxPairs(gpa, parts.bboxes(), a.bboxes(), &pairs);
    for (pairs.items) |rp| {
        const probe = probes[rp[0]];
        if (containsScaled(a.get(rp[1]), probe[0], probe[1], 8)) free[rp[1]] = false;
    }
}

/// Whether the grid point `p` lies in a polygon's material and on none of
/// its rings.
fn strictlyIn(poly: Polygon, p: Point) bool {
    var it = width.polyEdges(poly);
    while (it.next()) |s| if (ops.segmentsIntersect(s, .{ .a = p, .b = p })) return false;
    return crossesOdd(poly, p.x, p.y, 1);
}

/// Every `(i, j)` where polygon `i` of `a` and polygon `j` of `b` share area,
/// ascending, among the pairs whose boxes meet: a vertex of either strictly
/// inside the other shares (the polygon has area at its vertex); otherwise
/// the intersection of the two polygons alone decides.
fn sharingArea(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    try boxPairs(gpa, a.bboxes(), b.bboxes(), &pairs);
    var one: ValidatedLayer = .empty;
    defer one.deinit(gpa);
    var other: ValidatedLayer = .empty;
    defer other.deinit(gpa);
    var common: ValidatedLayer = .empty;
    defer common.deinit(gpa);
    out.clearRetainingCapacity();
    for (pairs.items) |ij| {
        const p = a.get(ij[0]);
        const q = b.get(ij[1]);
        var shares = strictlyIn(p, firstOf(q)) or strictlyIn(q, firstOf(p));
        if (!shares) {
            try a.copyPolygonInto(gpa, ij[0], &one);
            try b.copyPolygonInto(gpa, ij[1], &other);
            try boolean.intersectionInto(gpa, &one, &other, &common);
            shares = common.len() > 0;
        }
        if (shares) try out.append(gpa, ij);
    }
}

fn firstOf(poly: Polygon) Point {
    const r = poly.outer();
    return .{ .x = r.xs[0], .y = r.ys[0] };
}
