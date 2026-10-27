//! Derived layers that build new shapes: merge, sizing, holes, extents and
//! boxes. In: merged `ValidatedLayer`s (a boolean result or `mergeInto`'s).
//! Out: a merged layer (`extentsInto`, `boxesInto`: one box per polygon,
//! overlaps kept). Semantics follow KLayout's merged-polygon definitions;
//! exact at any angle but where a boolean snaps or rounds a vertex. Ported
//! from crates/geom/src/derive.rs (the shape builders).
//!
//! Contents:
//! - `pub const Error = error{ NotRectilinear, OutOfRange, Invalid } || Allocator.Error`
//! - `pub fn mergeInto(gpa: Allocator, a: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn sizedInto(gpa: Allocator, a: *const ValidatedLayer, dx: Dbu, dy: Dbu, out: *ValidatedLayer) Error!void`
//! - `pub fn holesInto(gpa: Allocator, a: *const ValidatedLayer, out: *ValidatedLayer) Error!void`
//! - `pub fn extentsInto(gpa: Allocator, a: *const ValidatedLayer, out: *ValidatedLayer) Error!void`
//! - `pub fn boxesInto(gpa: Allocator, boxes: []const Bbox, out: *ValidatedLayer) Error!void`
//! - `pub fn complementInto(gpa: Allocator, a: *const ValidatedLayer, dx: Dbu, dy: Dbu, out: *ValidatedLayer) Error!bool`
//! - `pub fn mergedInto(gpa: Allocator, builder: *const GeometryStoreBuilder, out: *ValidatedLayer) Error!void`
//! - `pub fn pushRect(gpa: Allocator, builder: *GeometryStoreBuilder, r: Bbox) Allocator.Error!void`
//! - `pub fn grown(r: Bbox, dx: Dbu, dy: Dbu) Error!Bbox`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const Bbox = @import("bbox.zig").Bbox;
const ops = @import("ops.zig");
const Point = ops.Point;
const store_mod = @import("store.zig");
const GeometryStoreBuilder = store_mod.GeometryStoreBuilder;
const view = @import("view.zig");
const ValidatedLayer = view.ValidatedLayer;
const boolean = @import("boolean.zig");
const rects = @import("rects.zig");
const width = @import("width.zig");

/// Why a derived layer could not be computed.
pub const Error = error{
    /// An operation that builds axis-parallel boxes was given an edge that
    /// is not horizontal or vertical (`extendedInto`, `withRectInto`).
    NotRectilinear,
    /// A grown coordinate would leave ±`max_abs_dbu`.
    OutOfRange,
    /// The rings an operation built failed validation (a box with no area).
    Invalid,
} || Allocator.Error;

/// The one layer of every scratch store here.
const only: @import("ids.zig").LayerId = @fromBackingInt(0);

/// `a` with overlapping and abutting polygons merged (KLayout merged
/// semantics).
pub fn mergeInto(gpa: Allocator, a: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void {
    return boolean.unionInto(gpa, a, &.empty, out);
}

/// KLayout `sized(dx, dy)`: the Minkowski sum with the box
/// `[-dx, dx] x [-dy, dy]` when both are at least 0, the erosion by it when
/// both are at most 0; a part no wider than `2|dx|` across x (or `2|dy|`
/// across y) shrinks away. A 45-degree or skew edge moves `dx` in x and `dy`
/// in y (the box), where KLayout moves edges along their normals: the definition
/// docs/src/reference/deck/layers.md (Angled edges) gives. Asserts `dx` and
/// `dy` do not differ in sign: one axis grown and the other shrunk is no one
/// Minkowski operation.
pub fn sizedInto(gpa: Allocator, a: *const ValidatedLayer, dx: Dbu, dy: Dbu, out: *ValidatedLayer) Error!void {
    assert(std.math.sign(dx) * std.math.sign(dy) >= 0);
    if (dx >= 0 and dy >= 0) return growInto(gpa, a, dx, dy, out);
    // Erosion is the complement of growing the complement, within a frame
    // far enough out that its own border does not erode `a`.
    var outside: ValidatedLayer = .empty;
    defer outside.deinit(gpa);
    if (!try complementInto(gpa, a, -dx, -dy, &outside)) return mergeInto(gpa, a, out);
    var eaten: ValidatedLayer = .empty;
    defer eaten.deinit(gpa);
    try growInto(gpa, &outside, -dx, -dy, &eaten);
    try boolean.subtractionInto(gpa, a, &eaten, out);
}

/// KLayout `holes`: every hole of `a` as a filled polygon, merged, so a hole
/// holding an island covers the island too.
pub fn holesInto(gpa: Allocator, a: *const ValidatedLayer, out: *ValidatedLayer) Error!void {
    var builder: GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    var xs: std.ArrayList(Dbu) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(Dbu) = .empty;
    defer ys.deinit(gpa);
    for (0..a.len()) |i| {
        const p = a.get(@intCast(i));
        for (1..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            // Holes wind clockwise; reversed they are outers.
            xs.clearRetainingCapacity();
            ys.clearRetainingCapacity();
            try xs.appendSlice(gpa, r.xs);
            try ys.appendSlice(gpa, r.ys);
            std.mem.reverse(Dbu, xs.items);
            std.mem.reverse(Dbu, ys.items);
            _ = try builder.push(gpa, only, xs.items, ys.items);
        }
    }
    try mergedInto(gpa, &builder, out);
}

/// KLayout `extents`: each polygon's box, one polygon per box, unmerged
/// ("The boxes will not be merged").
pub fn extentsInto(gpa: Allocator, a: *const ValidatedLayer, out: *ValidatedLayer) Error!void {
    return boxesInto(gpa, a.bboxes(), out);
}

/// One rectangle per box, unmerged. A box with no area is `error.Invalid`.
pub fn boxesInto(gpa: Allocator, boxes: []const Bbox, out: *ValidatedLayer) Error!void {
    var builder: GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    try builder.ensureUnusedCapacity(gpa, boxes.len, 4 * boxes.len);
    for (boxes) |b| try pushRect(gpa, &builder, b);
    var store: store_mod.GeometryStore = .empty;
    defer store.deinit(gpa);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try builder.finish(gpa, 1, &store, &perm);
    if (try view.validateLayer(gpa, &store, only, .rectilinear, out) != null) return error.Invalid;
}

/// `a`'s bounding box grown by `dx` each way in x and `dy` in y, minus `a`,
/// into `out`: its complement as far as that frame reaches. False, `out`
/// untouched, for an empty `a`.
pub fn complementInto(gpa: Allocator, a: *const ValidatedLayer, dx: Dbu, dy: Dbu, out: *ValidatedLayer) Error!bool {
    if (a.len() == 0) return false;
    var extent = Bbox.empty;
    for (a.bboxes()) |b| extent = extent.merge(b);
    var frame: ValidatedLayer = .empty;
    defer frame.deinit(gpa);
    try boxesInto(gpa, &.{try grown(extent, dx, dy)}, &frame);
    try boolean.subtractionInto(gpa, &frame, a, out);
    return true;
}

/// Validates the builder's rings as one layer at any angle, then merges
/// them into `out`.
pub fn mergedInto(gpa: Allocator, builder: *const GeometryStoreBuilder, out: *ValidatedLayer) Error!void {
    var store: store_mod.GeometryStore = .empty;
    defer store.deinit(gpa);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try builder.finish(gpa, 1, &store, &perm);
    var raw: ValidatedLayer = .empty;
    defer raw.deinit(gpa);
    if (try view.validateLayer(gpa, &store, only, .any, &raw) != null) return error.Invalid;
    try mergeInto(gpa, &raw, out);
}

pub fn pushRect(gpa: Allocator, builder: *GeometryStoreBuilder, r: Bbox) Allocator.Error!void {
    _ = try builder.push(gpa, only, &.{ r.xlo, r.xhi, r.xhi, r.xlo }, &.{ r.ylo, r.ylo, r.yhi, r.yhi });
}

/// `r` grown by `dx` left and right and `dy` above and below, refused past
/// the coordinate domain.
pub fn grown(r: Bbox, dx: Dbu, dy: Dbu) Error!Bbox {
    return .{ .xlo = try at(r.xlo - dx), .ylo = try at(r.ylo - dy), .xhi = try at(r.xhi + dx), .yhi = try at(r.yhi + dy) };
}

// ---- private ----

fn at(v: i64) Error!Dbu {
    return if (dbu.inDomain(v)) v else error.OutOfRange;
}

/// `a` grown by the box `[-dx, dx] x [-dy, dy]`, `dx, dy >= 0`: exact, since
/// the Minkowski sum distributes over union. A rectilinear layer is the union
/// of its rectangles grown; any other is itself together with each boundary
/// edge swept by the box, since a point the sum adds lies within the box of
/// some boundary point.
fn growInto(gpa: Allocator, a: *const ValidatedLayer, dx: Dbu, dy: Dbu, out: *ValidatedLayer) Error!void {
    var builder: GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    if (!a.isRectilinear()) {
        for (0..a.len()) |i| {
            const p = a.get(@intCast(i));
            // Outer and holes as rows: every ring adds its winding.
            for (0..p.ringCount()) |k| {
                const r = p.ring(@intCast(k));
                _ = try builder.push(gpa, only, r.xs, r.ys);
            }
            if (dx == 0 and dy == 0) continue;
            var it = width.polyEdges(p);
            while (it.next()) |s| {
                var xs: [6]Dbu = undefined;
                var ys: [6]Dbu = undefined;
                const n = try sweptBox(s.a, s.b, dx, dy, &xs, &ys);
                _ = try builder.push(gpa, only, xs[0..n], ys[0..n]);
            }
        }
        return mergedInto(gpa, &builder, out);
    }
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try rects.decomposeInto(gpa, a, &boxes, &start);
    try builder.ensureUnusedCapacity(gpa, boxes.items.len, 4 * boxes.items.len);
    for (boxes.items) |r| try pushRect(gpa, &builder, try grown(r, dx, dy));
    try mergedInto(gpa, &builder, out);
}

/// The edge `p`-`q` swept by the box `[-dx, dx] x [-dy, dy]` (not both 0):
/// its convex hull, counter-clockwise, into `xs`/`ys`; a box for an axis
/// edge, else a hexagon (a parallelogram when `dx` or `dy` is 0). Returns
/// the vertex count; refused past the coordinate domain.
fn sweptBox(p: Point, q: Point, dx: Dbu, dy: Dbu, xs: *[6]Dbu, ys: *[6]Dbu) Error!usize {
    const l, const r = if (p.x < q.x or (p.x == q.x and p.y <= q.y)) .{ p, q } else .{ q, p };
    var corners: [6][2]i64 = undefined;
    var n: usize = 6;
    if (l.x == r.x or l.y == r.y) {
        const x0 = @min(l.x, r.x) - dx;
        const x1 = @max(l.x, r.x) + dx;
        const y0 = @min(l.y, r.y) - dy;
        const y1 = @max(l.y, r.y) + dy;
        corners[0..4].* = .{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        n = 4;
    } else if (r.y > l.y) {
        // Rising: `l` is the lower end.
        corners = .{ .{ l.x - dx, l.y - dy }, .{ l.x + dx, l.y - dy }, .{ r.x + dx, r.y - dy }, .{ r.x + dx, r.y + dy }, .{ r.x - dx, r.y + dy }, .{ l.x - dx, l.y + dy } };
    } else {
        // Falling: `l` is the upper end.
        corners = .{ .{ l.x - dx, l.y - dy }, .{ r.x - dx, r.y - dy }, .{ r.x + dx, r.y - dy }, .{ r.x + dx, r.y + dy }, .{ l.x + dx, l.y + dy }, .{ l.x - dx, l.y + dy } };
    }
    // A zero `dx` or `dy` folds two corners of the hexagon into one.
    var kept: usize = 0;
    for (corners[0..n]) |c| {
        if (kept > 0 and std.mem.eql(i64, &corners[kept - 1], &c)) continue;
        corners[kept] = c;
        kept += 1;
    }
    while (kept > 1 and std.mem.eql(i64, &corners[0], &corners[kept - 1])) kept -= 1;
    for (corners[0..kept], 0..) |c, i| {
        xs[i] = try at(c[0]);
        ys[i] = try at(c[1]);
    }
    return kept;
}
