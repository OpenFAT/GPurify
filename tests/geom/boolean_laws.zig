//! Laws for the exact rectilinear booleans, over named configurations:
//! identical layers, disjoint layers, one layer nested in another. Ported
//! from crates/geom/tests/core/boolean_laws.rs (the general case is
//! boolean_random.zig's).
//!
//! Region equality is asserted as "each difference is empty and the areas
//! agree", which needs only the empty result to be expressible.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const shapes = testgen.shapes;
const Rng = testgen.Rng;
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const Bbox = geom.Bbox;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const totalArea = fx.totalArea;

const a_layer: u16 = 0;
const b_layer: u16 = 1;

/// Two layers whose shapes never meet: `A` on the left, `B` well to the right,
/// translated by `d`, with the areas the generator's closed forms state.
const Disjoint = struct {
    store: GeometryStore = .empty,
    a: ValidatedLayer = .empty,
    b: ValidatedLayer = .empty,
    area_a: DbuArea = 100 * 50 + shapes.lShapeArea(90, 20) + shapes.uShapeArea(80, 15, 25),
    area_b: DbuArea = 60 * 60 + shapes.lShapeArea(70, 30),

    fn init(d: [2]i64) !Disjoint {
        var t: Disjoint = .{};
        errdefer t.deinit();
        var lb: shapes.LayoutBuilder = .init(2);
        defer lb.deinit(gpa);
        const dx, const dy = d;
        _ = try lb.rect(gpa, a_layer, dx, dy, dx + 100, dy + 50);
        _ = try lb.shape(gpa, a_layer, shapes.lShape(dx, dy + 200, 90, 20));
        _ = try lb.shape(gpa, a_layer, shapes.uShape(dx, dy + 500, 80, 15, 25));
        _ = try lb.rect(gpa, b_layer, dx + 10_000, dy, dx + 10_060, dy + 60);
        _ = try lb.shape(gpa, b_layer, shapes.lShape(dx + 10_000, dy + 200, 70, 30));
        var ids: shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &t.store, &ids);
        t.a = try fx.validated(&t.store, a_layer, .rectilinear);
        t.b = try fx.validated(&t.store, b_layer, .rectilinear);
        return t;
    }

    fn deinit(t: *Disjoint) void {
        t.store.deinit(gpa);
        t.a.deinit(gpa);
        t.b.deinit(gpa);
    }
};

/// Per polygon: its box, area and hole count, for a reproducibility check.
const Summary = struct { box: Bbox, area: DbuArea, holes: u32 };

// ---- private ----

/// Region equality, so that only an empty result has to be representable:
/// neither region has area the other lacks, and their areas agree.
fn expectSameRegion(left: *const ValidatedLayer, right: *const ValidatedLayer) !void {
    var d = try fx.run(.not, left, right);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(DbuArea, 0), totalArea(&d));
    var e = try fx.run(.not, right, left);
    defer e.deinit(gpa);
    try testing.expectEqual(@as(DbuArea, 0), totalArea(&e));
    try testing.expectEqual(totalArea(left), totalArea(right));
}

fn summarize(l: *const ValidatedLayer, out: *std.ArrayList(Summary)) !void {
    out.clearRetainingCapacity();
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        try out.append(gpa, .{ .box = p.bbox(), .area = shapes.polygonArea(p), .holes = p.ringCount() - 1 });
    }
}

test "a layer unioned intersected and subtracted with itself behaves" {
    // Oracle: law. Self-union and self-intersection are idempotent, and a layer
    // minus itself is nothing at all. These hold for arbitrary operands, and the
    // operands here are three non-convex shapes whose bounding boxes overstate
    // them, so an implementation working on boxes fails.
    var t = try Disjoint.init(.{ 0, 0 });
    defer t.deinit();
    try testing.expectEqual(t.area_a, totalArea(&t.a));
    var u = try fx.run(.@"or", &t.a, &t.a);
    defer u.deinit(gpa);
    try expectSameRegion(&u, &t.a);
    var m = try fx.run(.@"and", &t.a, &t.a);
    defer m.deinit(gpa);
    try expectSameRegion(&m, &t.a);
    var d = try fx.run(.not, &t.a, &t.a);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), d.len());
}

test "area is conserved under union and intersection" {
    // Oracle: law. `area(a ∪ b) + area(a ∩ b) == area(a) + area(b)` — inclusion
    // and exclusion, which holds for every pair of regions. On disjoint operands
    // the intersection contributes nothing, so the union has to account for both
    // operands exactly: an implementation that dropped or double-counted a polygon
    // fails on the left-hand side.
    var t = try Disjoint.init(.{ 0, 0 });
    defer t.deinit();
    var u = try fx.run(.@"or", &t.a, &t.b);
    defer u.deinit(gpa);
    var m = try fx.run(.@"and", &t.a, &t.b);
    defer m.deinit(gpa);
    try testing.expectEqual(t.area_a + t.area_b, totalArea(&u) + totalArea(&m));
    try testing.expectEqual(@as(DbuArea, 0), totalArea(&m));
    try testing.expectEqual(t.area_a + t.area_b, totalArea(&u));
    // No shape merged or vanished.
    try testing.expectEqual(t.a.len() + t.b.len(), u.len());
}

test "the intersection is a subset and the union a superset of each operand" {
    // Oracle: law. `a ∩ b ⊆ a` and `a ∪ b ⊇ a`, for any operands, expressed the
    // only way a subset is expressible here: the part of the smaller region that
    // escapes the larger one has no area. The last assertion makes the other four
    // mean something: on these disjoint operands `a − b` is the whole of `a`,
    // which no vacuous subtraction produces.
    var t = try Disjoint.init(.{ 0, 0 });
    defer t.deinit();
    var m = try fx.run(.@"and", &t.a, &t.b);
    defer m.deinit(gpa);
    var j = try fx.run(.@"or", &t.a, &t.b);
    defer j.deinit(gpa);
    for ([_][2]*const ValidatedLayer{ .{ &m, &t.a }, .{ &m, &t.b }, .{ &t.a, &j }, .{ &t.b, &j } }) |pair| {
        var escaped = try fx.run(.not, pair[0], pair[1]);
        defer escaped.deinit(gpa);
        try testing.expectEqual(@as(DbuArea, 0), totalArea(&escaped));
    }
    var escaped = try fx.run(.not, &t.a, &t.b);
    defer escaped.deinit(gpa);
    try testing.expectEqual(t.area_a, totalArea(&escaped));
    try testing.expectEqual(t.a.len(), escaped.len());
}

test "union and intersection commute" {
    // Oracle: law. Union and intersection commute. Operand order changes nothing
    // about a region, so the two orderings must describe the same one — and the
    // generated corpus is asymmetric enough that an implementation reading only
    // its first operand fails.
    var t = try Disjoint.init(.{ 0, 0 });
    defer t.deinit();
    for ([_]fx.Kind{ .@"or", .@"and" }) |kind| {
        var forward = try fx.run(kind, &t.a, &t.b);
        defer forward.deinit(gpa);
        var backward = try fx.run(kind, &t.b, &t.a);
        defer backward.deinit(gpa);
        try expectSameRegion(&forward, &backward);
    }
}

test "difference and intersection partition the first operand" {
    // Oracle: law. `(a − b) ∪ (a ∩ b) == a`: difference and intersection partition
    // the first operand, so putting them back together recovers it. This is the
    // law that fails if a subtraction quietly drops a sliver, which is one of the
    // three fail-open defects the previous implementation carried.
    var t = try Disjoint.init(.{ 0, 0 });
    defer t.deinit();
    var d = try fx.run(.not, &t.a, &t.b);
    defer d.deinit(gpa);
    var m = try fx.run(.@"and", &t.a, &t.b);
    defer m.deinit(gpa);
    var rebuilt = try fx.run(.@"or", &d, &m);
    defer rebuilt.deinit(gpa);
    try expectSameRegion(&rebuilt, &t.a);
    try testing.expectEqual(totalArea(&t.a), totalArea(&d) + totalArea(&m));
}

test "identical layers union and intersect to themselves and subtract to nothing" {
    // Oracle: construct-from-answer. Two layers holding identical geometry are the
    // same region, so the union is that region, the intersection is that region,
    // and the difference is empty. This is the fully-overlapping case, which the
    // disjoint corpus above cannot reach.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    for ([_]u16{ a_layer, b_layer }) |l| {
        _ = try lb.rect(gpa, l, 0, 0, 120, 80);
        _ = try lb.shape(gpa, l, shapes.lShape(300, 0, 100, 40));
        _ = try lb.shape(gpa, l, shapes.uShape(0, 300, 90, 20, 30));
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var a = try fx.validated(&store, a_layer, .rectilinear);
    defer a.deinit(gpa);
    var b = try fx.validated(&store, b_layer, .rectilinear);
    defer b.deinit(gpa);
    const expected: DbuArea = 120 * 80 + shapes.lShapeArea(100, 40) + shapes.uShapeArea(90, 20, 30);
    try testing.expectEqual(expected, totalArea(&a));
    try testing.expectEqual(expected, totalArea(&b));
    for ([_]fx.Kind{ .@"or", .@"and" }) |kind| {
        var out = try fx.run(kind, &a, &b);
        defer out.deinit(gpa);
        try testing.expectEqual(expected, totalArea(&out));
        try expectSameRegion(&out, &a);
    }
    var ab = try fx.run(.not, &a, &b);
    defer ab.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), ab.len());
    var ba = try fx.run(.not, &b, &a);
    defer ba.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), ba.len());
}

test "a contained layer unions to its container and intersects to itself" {
    // Oracle: construct-from-answer. When every shape of `b` lies strictly inside a
    // shape of `a`, the union is `a` and the intersection is `b`.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, a_layer, 0, 0, 1_000, 1_000);
    _ = try lb.rect(gpa, a_layer, 2_000, 0, 3_000, 1_000);
    _ = try lb.rect(gpa, b_layer, 100, 100, 400, 400);
    _ = try lb.rect(gpa, b_layer, 500, 600, 900, 900);
    _ = try lb.rect(gpa, b_layer, 2_100, 100, 2_900, 900);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var a = try fx.validated(&store, a_layer, .rectilinear);
    defer a.deinit(gpa);
    var b = try fx.validated(&store, b_layer, .rectilinear);
    defer b.deinit(gpa);
    const area_a: DbuArea = 2 * 1_000 * 1_000;
    const area_b: DbuArea = 300 * 300 + 400 * 300 + 800 * 800;
    try testing.expectEqual(area_a, totalArea(&a));
    try testing.expectEqual(area_b, totalArea(&b));
    var u = try fx.run(.@"or", &a, &b);
    defer u.deinit(gpa);
    try expectSameRegion(&u, &a);
    try testing.expectEqual(area_a, totalArea(&u));
    var m = try fx.run(.@"and", &a, &b);
    defer m.deinit(gpa);
    try expectSameRegion(&m, &b);
    try testing.expectEqual(area_b, totalArea(&m));
    // Inclusion-exclusion again, now with a non-empty intersection.
    try testing.expectEqual(area_a + area_b, totalArea(&u) + totalArea(&m));
}

test "a boolean result is invariant under translation of every input" {
    // Oracle: law. A boolean is a statement about regions, so translating every
    // input translates the result and changes no area. Coordinate-independence is
    // the law an implementation cannot dodge by special-casing a fixture's
    // coordinates.
    var base = try Disjoint.init(.{ 0, 0 });
    defer base.deinit();
    var base_union = try fx.run(.@"or", &base.a, &base.b);
    defer base_union.deinit(gpa);
    var rng = Rng.init(51);
    for (0..8) |_| {
        const dx = rng.range(-400_000, 400_000);
        var t = try Disjoint.init(.{ dx, rng.range(-400_000, 400_000) });
        defer t.deinit();
        try testing.expectEqual(t.area_a, totalArea(&t.a));
        try testing.expectEqual(t.area_b, totalArea(&t.b));
        var u = try fx.run(.@"or", &t.a, &t.b);
        defer u.deinit(gpa);
        try testing.expectEqual(totalArea(&base_union), totalArea(&u));
        try testing.expectEqual(base_union.len(), u.len());
    }
}

test "two runs of one boolean produce the same polygons in the same order" {
    // Oracle: determinism. A boolean that produced its polygons in a different order
    // on a second run would make every report non-reproducible. Run the same union
    // twice into a buffer that already holds a different result, which is exactly
    // how a caller reuses one.
    var t = try Disjoint.init(.{ 0, 0 });
    defer t.deinit();
    var buffer: ValidatedLayer = .empty;
    defer buffer.deinit(gpa);
    try geom.boolean.intersectionInto(gpa, &t.a, &t.b, &buffer);
    var first: std.ArrayList(Summary) = .empty;
    defer first.deinit(gpa);
    var second: std.ArrayList(Summary) = .empty;
    defer second.deinit(gpa);
    try geom.boolean.unionInto(gpa, &t.a, &t.b, &buffer);
    try summarize(&buffer, &first);
    try geom.boolean.unionInto(gpa, &t.a, &t.b, &buffer);
    try summarize(&buffer, &second);
    try testing.expectEqualSlices(Summary, first.items, second.items);
    try testing.expect(first.items.len > 0);
}
