//! Booleans of layers at any angle by an x-sweep with nonzero-winding
//! occupancy: exact on rectilinear and octilinear layers, snap-rounded at
//! any other angle. In: `ValidatedLayer` operands, or one raw GDS ring
//! (`canonicalRingsInto`). Out: a merged `ValidatedLayer`, outers CCW and
//! holes CW, whose rows are a scratch store's, not the operands'. Ported
//! from crates/geom/src/boolean.rs.
//!
//! Rectilinear operands take the slab sweep (`boolean_slab.zig`); operands
//! with a 45-degree edge the trapezoid sweep at doubled scale
//! (`boolean_octilinear.zig`), then a snap of any vertex between grid
//! points; operands at any other angle the snap-rounded sweep
//! (`boolean_anyangle.zig`).
//!
//! Contents:
//! - `pub const Rings` (flat_rings.zig)
//! - `pub fn unionInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn intersectionInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn subtractionInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn canonicalRingsInto(gpa: Allocator, xs: []const i64, ys: []const i64, out: *Rings) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const flat = @import("flat_rings.zig");
const Op = flat.Op;
const store_mod = @import("store.zig");
const view = @import("view.zig");
const ValidatedLayer = view.ValidatedLayer;
const slab = @import("boolean_slab.zig");
const octilinear = @import("boolean_octilinear.zig");
const anyangle = @import("boolean_anyangle.zig");

pub const Rings = flat.Rings;

/// The layer of the one-layer store `emitRings` builds.
const result_layer: u16 = 0;

/// The union of two validated layers into `out` (cleared and refilled),
/// merged: overlapping and abutting polygons come out as one.
///
/// The corner model is "connected". Material meeting only at a corner is
/// joined there: two cells touching at a corner are one polygon, its outer
/// ring passing the corner twice, the corner a neck of width 0. Empty space
/// does not pass such a corner, so a ring of material closed only at a corner
/// encloses a hole touching the outer there. A polygon is one 8-connected
/// component of the material, each hole one 4-connected component of the
/// space it encloses, however the input was drawn. At any angle the rule is
/// the same: material meeting at a point is one figure.
///
/// Off-grid vertices are snapped. With 45-degree edges a result vertex can
/// fall at a half-grid point where a rising and a falling diagonal cross; it
/// is replaced by the two grid points half a diagonal step from it along its
/// edges, joined by a unit axis edge (a convex corner loses, a concave one
/// gains, a quarter-unit triangle; a pinch becomes a unit neck), so every
/// edge stays octilinear and every vertex on the grid (IHP SG13G2 rule 3.1).
/// KLayout instead rounds such a point to the nearest grid point.
///
/// At any other angle, crossings are rounded to the nearest grid point, a
/// half away from zero, as KLayout rounds them, and every edge passing that
/// point's pixel is bent through it: snap rounding (Hobby 1999; Guibas and
/// Marimont 1998). An edge end in a bent edge's pixel span bends it too; an
/// edge nothing bends keeps its shape. Every boundary point moves less than
/// half a unit along each axis.
///
/// Validated operands always produce valid rings; an invalid traced result
/// is an internal fault and asserts.
pub fn unionInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void {
    return combineInto(gpa, a, b, .unite, out);
}

/// The intersection, merged as `unionInto`'s. A shared edge or corner has no
/// area and is not in the result.
pub fn intersectionInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void {
    return combineInto(gpa, a, b, .intersect, out);
}

/// `a` minus `b`, merged as `unionInto`'s.
pub fn subtractionInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, out: *ValidatedLayer) Allocator.Error!void {
    return combineInto(gpa, a, b, .subtract, out);
}

/// The canonical rings of one raw GDS ring, outers CCW and holes CW, into
/// `out` (cleared and refilled). GDSII writes a polygon with holes as one
/// weakly simple keyhole ring, which validation refuses as self-intersecting;
/// retracing it through the sweep cancels the slit and yields the outer and
/// holes. Every angle is read (snapped or rounded as `unionInto` states), so
/// nothing is refused; vertex 0 of a result need not be the input's.
/// Asserts parallel columns within ±`max_abs_dbu`.
pub fn canonicalRingsInto(gpa: Allocator, xs: []const i64, ys: []const i64, out: *Rings) Allocator.Error!void {
    assert(xs.len == ys.len);
    var skew = false;
    var steep = false;
    for (xs, ys, 0..) |x, y, i| {
        assert(dbu.inDomain(x) and dbu.inDomain(y));
        const j = if (i + 1 < xs.len) i + 1 else 0;
        const dx = xs[j] - x;
        const dy = ys[j] - y;
        skew = skew or (dx != 0 and dy != 0);
        steep = steep or (dx != 0 and dy != 0 and @abs(dx) != @abs(dy));
    }
    var ring: Rings = .{};
    defer ring.deinit(gpa);
    try ring.reset(gpa);
    try ring.xs.appendSlice(gpa, xs);
    try ring.ys.appendSlice(gpa, ys);
    try ring.closeRing(gpa);
    const none: Rings = .{};
    if (steep) return anyangle.combineInto(gpa, &ring, &none, .unite, out);
    if (skew) {
        ring.scale(2);
        return octilinearRings(gpa, &ring, &none, .unite, out);
    }
    return slab.combineInto(gpa, &ring, &none, .unite, out);
}

// ---- private ----

/// The set operation over the cheapest sweep both operands allow.
fn combineInto(gpa: Allocator, a: *const ValidatedLayer, b: *const ValidatedLayer, op: Op, out: *ValidatedLayer) Allocator.Error!void {
    var ra: Rings = .{};
    defer ra.deinit(gpa);
    var rb: Rings = .{};
    defer rb.deinit(gpa);
    var result: Rings = .{};
    defer result.deinit(gpa);
    try collectRings(gpa, a, &ra);
    try collectRings(gpa, b, &rb);
    if (!(a.isOctilinear() and b.isOctilinear())) {
        try anyangle.combineInto(gpa, &ra, &rb, op, &result);
    } else if (!(a.isRectilinear() and b.isRectilinear())) {
        ra.scale(2);
        rb.scale(2);
        try octilinearRings(gpa, &ra, &rb, op, &result);
    } else {
        try slab.combineInto(gpa, &ra, &rb, op, &result);
    }
    try emitRings(gpa, &result, out);
}

/// Every ring of every polygon of one operand, flattened.
fn collectRings(gpa: Allocator, layer: *const ValidatedLayer, rings: *Rings) Allocator.Error!void {
    try rings.reset(gpa);
    for (0..layer.len()) |idx| {
        const poly = layer.get(@intCast(idx));
        for (0..poly.ringCount()) |k| {
            const r = poly.ring(@intCast(k));
            try rings.xs.appendSlice(gpa, r.xs);
            try rings.ys.appendSlice(gpa, r.ys);
            try rings.closeRing(gpa);
        }
    }
}

/// The rings of `op(a, b)` for operands at doubled scale, by the octilinear
/// sweep, snapped onto the grid and halved, into `out`.
fn octilinearRings(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void {
    try octilinear.combineInto(gpa, a, b, op, out);
    if (octilinear.offGrid(out)) {
        var snapped: Rings = .{};
        defer snapped.deinit(gpa);
        try octilinear.snapInto(gpa, out, &snapped);
        // The snapped rings may hold a slit or a vanished sliver; tracing
        // them again leaves only their region.
        try octilinear.combineInto(gpa, &snapped, &.{}, .unite, out);
        // A snapped boundary crosses itself only at grid points.
        assert(!octilinear.offGrid(out));
    }
    for (out.xs.items) |*c| c.* = @divExact(c.*, 2);
    for (out.ys.items) |*c| c.* = @divExact(c.*, 2);
}

/// Validates flat rings into `out` through a one-layer store, so hole
/// binding has one implementation (`view`).
fn emitRings(gpa: Allocator, rings: *const Rings, out: *ValidatedLayer) Allocator.Error!void {
    var builder: store_mod.GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    try builder.ensureUnusedCapacity(gpa, rings.count(), rings.xs.items.len);
    for (0..rings.count()) |k| {
        const lo, const hi = rings.range(k);
        _ = try builder.push(gpa, @fromBackingInt(result_layer), rings.xs.items[lo..hi], rings.ys.items[lo..hi]);
    }
    var store: store_mod.GeometryStore = .empty;
    defer store.deinit(gpa);
    var permutation: std.ArrayList(u32) = .empty;
    defer permutation.deinit(gpa);
    try builder.finish(gpa, 1, &store, &permutation);
    const defect = try view.validateLayer(gpa, &store, @fromBackingInt(result_layer), .any, out);
    // An invalid traced result is an internal fault: crash where a fuzzer
    // sees it rather than refuse a rule.
    if (defect) |d| std.debug.panic("a traced boolean result failed validation: {any}", .{d});
}

fn shoelace(r: *const Rings, k: usize) i128 {
    const lo, const hi = r.range(k);
    var twice: i128 = 0;
    for (lo..hi) |i| {
        const j = if (i + 1 == hi) lo else i + 1;
        twice += @as(i128, r.xs.items[i]) * r.ys.items[j] - @as(i128, r.xs.items[j]) * r.ys.items[i];
    }
    return twice;
}

fn layerArea(l: *const ValidatedLayer) i128 {
    var doubled: i128 = 0;
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            doubled += @import("ops.zig").area2(r.xs, r.ys);
        }
    }
    return @divExact(doubled, 2);
}

test "a union conserves area against its intersection" {
    // Oracle: law, inclusion-exclusion: area(A or B) + area(A and B) = area(A)
    // + area(B), with the overlap hand-derived as 50 x 50 and the union one L.
    const gpa = std.testing.allocator;
    var builder: store_mod.GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    _ = try builder.push(gpa, @fromBackingInt(0), &.{ 0, 100, 100, 0 }, &.{ 0, 0, 100, 100 });
    _ = try builder.push(gpa, @fromBackingInt(1), &.{ 50, 150, 150, 50 }, &.{ 50, 50, 150, 150 });
    var store: store_mod.GeometryStore = .empty;
    defer store.deinit(gpa);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try builder.finish(gpa, 2, &store, &perm);
    var a: ValidatedLayer = .empty;
    defer a.deinit(gpa);
    var b: ValidatedLayer = .empty;
    defer b.deinit(gpa);
    try std.testing.expectEqual(null, try view.validateLayer(gpa, &store, @fromBackingInt(0), .rectilinear, &a));
    try std.testing.expectEqual(null, try view.validateLayer(gpa, &store, @fromBackingInt(1), .rectilinear, &b));
    var joined: ValidatedLayer = .empty;
    defer joined.deinit(gpa);
    var shared: ValidatedLayer = .empty;
    defer shared.deinit(gpa);
    try unionInto(gpa, &a, &b, &joined);
    try intersectionInto(gpa, &a, &b, &shared);
    try std.testing.expectEqual(@as(i128, 50 * 50), layerArea(&shared));
    try std.testing.expectEqual(@as(i128, 100 * 100 + 100 * 100), layerArea(&joined) + layerArea(&shared));
    try std.testing.expectEqual(@as(u32, 1), joined.len());
}

test "a keyhole ring decomposes into its outer and its hole" {
    // Oracle: closed form — a keyhole ring denotes an outer minus its hole.
    //
    // The input is the ring `KLayout` writes for a 1000x1000 square with a
    // 400x400 hole: one weakly simple loop that runs in to the hole along
    // `y = 700` and back out along the same line. `validate_layer_into`
    // refuses it, so a reader that passed it through refused every layer it
    // appeared on. Decomposed, it is two rings whose signed areas sum to the
    // area the shape has.
    const gpa = std.testing.allocator;
    var out: Rings = .{};
    defer out.deinit(gpa);
    try canonicalRingsInto(gpa, &.{ 0, 0, 300, 300, 700, 700, 0, 0, 1000, 1000 }, &.{ 0, 700, 700, 300, 300, 700, 700, 1000, 1000, 0 }, &out);
    try std.testing.expectEqual(@as(u32, 2), out.count());
    var signed = [2]i128{ @divExact(shoelace(&out, 0), 2), @divExact(shoelace(&out, 1), 2) };
    std.mem.sort(i128, &signed, {}, std.sort.asc(i128));
    // The hole comes back clockwise and the outer counter-clockwise.
    try std.testing.expectEqual([2]i128{ -400 * 400, 1000 * 1000 }, signed);
}

test "a simple ring decomposes to itself" {
    // Oracle: construct-from-answer. A 400 square is already simple, so its
    // decomposition is one ring of four corners, shoelace area 400^2, positive
    // (counter-clockwise).
    const gpa = std.testing.allocator;
    var out: Rings = .{};
    defer out.deinit(gpa);
    try canonicalRingsInto(gpa, &.{ 0, 400, 400, 0 }, &.{ 0, 0, 400, 400 }, &out);
    try std.testing.expectEqual(@as(u32, 1), out.count());
    try std.testing.expectEqual(@as(usize, 4), out.xs.items.len);
    try std.testing.expectEqual(@as(i128, 2 * 400 * 400), shoelace(&out, 0));
}
