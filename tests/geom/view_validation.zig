//! Validation: what a `Polygon` is allowed to promise, and what gets refused
//! before one can exist. Ported from crates/geom/tests/core/view_validation.rs.
//!
//! The refusals matter as much as the acceptances. Validation fails closed,
//! so every rejected input is checked for the specific defect and the
//! specific row, not merely for failure: the previous implementation
//! dropped a hole with no containing outer without a word, which removes
//! area from a verification result.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const shapes = testgen.shapes;
const Rng = testgen.Rng;
const ops = geom.ops;
const view = geom.view;
const Bbox = geom.Bbox;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ValidatedLayer = geom.ValidatedLayer;
const Defect = view.Defect;
const Ring = geom.Ring;
const polygonArea = shapes.polygonArea;

const gpa = testing.allocator;
const layer: u16 = 0;
const other: u16 = 1;

/// A raw run on a layer, pushed past `LayoutBuilder`'s preconditions.
const Run = struct { layer: u16, xs: []const i64, ys: []const i64 };

/// A store and a validated layer read from it, freed together.
const Fixture = struct {
    store: GeometryStore = .empty,
    out: ValidatedLayer = .empty,

    fn deinit(f: *Fixture) void {
        f.store.deinit(gpa);
        f.out.deinit(gpa);
    }

    fn validate(f: *Fixture, l: u16, angles: view.Angles) !?Defect {
        return view.validateLayer(gpa, &f.store, lid(l), angles, &f.out);
    }
};

// ---- private ----

fn lid(l: u16) LayerId {
    return @fromBackingInt(l);
}

fn pid(r: u32) PolyId {
    return @fromBackingInt(r);
}

fn storeOf(runs: []const Run, store: *GeometryStore) !void {
    var builder: geom.GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    for (runs) |r| _ = try builder.push(gpa, lid(r.layer), r.xs, r.ys);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try builder.finish(gpa, 2, store, &perm);
}

fn wind(r: Ring) ?ops.Winding {
    return ops.windingOf(r.xs, r.ys);
}

fn area2(r: Ring) DbuArea {
    return ops.area2(r.xs, r.ys);
}

/// Sum of every polygon's area; the order rows take within a layer is not
/// part of the store's interface.
fn totalArea(l: *const ValidatedLayer) DbuArea {
    var total: DbuArea = 0;
    for (0..l.len()) |i| total += polygonArea(l.get(@intCast(i)));
    return total;
}

test "ring defect names what layer validation refuses" {
    // Oracle: differential against the layer validator. On a rectilinear ring,
    // `ring_defect` names exactly the defect `validate_layer_into` reports for
    // a layer holding that ring alone, and nothing for a valid ring or a lone
    // clockwise one (an orphan hole is the layer's defect, not the ring's).
    // Staircases over a 4 x 4 lattice cross, touch and double back often.
    var rng = Rng.init(0x51_6e_5f_de);
    for (0..5000) |_| {
        const k: usize = @intCast(rng.range(1, 6));
        var px: [5]i64 = undefined;
        var py: [5]i64 = undefined;
        for (px[0..k]) |*v| v.* = rng.range(0, 4);
        for (py[0..k]) |*v| v.* = rng.range(0, 4);
        var xs: [10]i64 = undefined;
        var ys: [10]i64 = undefined;
        for (0..k) |i| {
            xs[2 * i] = px[i];
            xs[2 * i + 1] = px[(i + 1) % k];
            ys[2 * i] = py[i];
            ys[2 * i + 1] = py[i];
        }
        var f: Fixture = .{};
        defer f.deinit();
        try storeOf(&.{.{ .layer = layer, .xs = xs[0 .. 2 * k], .ys = ys[0 .. 2 * k] }}, &f.store);
        const got = try f.validate(layer, .rectilinear);
        const want: ?Defect = if (got) |d| switch (d) {
            .orphan_hole => null,
            else => d,
        } else null;
        const row = pid(f.store.polysOnLayer(lid(layer)).start);
        const r = f.store.polyVerts(row);
        try testing.expectEqual(want, try view.ringDefect(gpa, r.xs, r.ys, row));
    }
}

test "a validated polygon has the area its generator states" {
    // Oracle: closed form. The generator states each shape's area as a formula in
    // its own parameters, and `PolygonRef::area` must agree exactly. The L, plus
    // and U are here because their bounding boxes overstate them: an
    // implementation measuring the box passes on the rectangle and fails on the
    // other three.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    const handles = [4]shapes.Handle{
        try lb.shape(gpa, layer, shapes.rect(0, 0, 40, 25)),
        try lb.shape(gpa, layer, shapes.lShape(0, 0, 100, 30)),
        try lb.shape(gpa, layer, shapes.plusShape(500, 500, 60, 8)),
        try lb.shape(gpa, layer, shapes.uShape(-300, -300, 100, 20, 40)),
    };
    const areas = [4]i128{ 1_000, shapes.lShapeArea(100, 30), shapes.plusShapeArea(60, 8), shapes.uShapeArea(100, 20, 40) };
    var f: Fixture = .{};
    defer f.deinit();
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &f.store, &ids);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(@as(u32, 4), f.out.len());
    // No holes, so polygons sit in store-row order: the handle's row less the
    // layer's first row is the index into the layer.
    const first = f.store.polysOnLayer(lid(layer)).start;
    for (handles, areas) |h, a| {
        const id = ids.of(h);
        const poly = f.out.get(@backingInt(id) - first);
        try testing.expectEqual(a, polygonArea(poly));
        try testing.expectEqual(f.store.polyBbox(id), poly.bbox());
        try testing.expectEqual(@as(u32, 1), poly.ringCount());
    }
}

test "every validated outer ring winds counter clockwise and is simple" {
    // Oracle: law. Validation's whole output is a promise about the rings it
    // produced: the outer boundary winds counter-clockwise, its doubled signed
    // area is therefore positive, and the run does not cross itself. Asserted over
    // a generated layer so it is a property of the pass rather than of a fixture.
    var rng = Rng.init(41);
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    for (0..120) |_| {
        const x = rng.range(-200_000, 200_000);
        const y = rng.range(-200_000, 200_000);
        switch (rng.below(3)) {
            0 => {
                const w = rng.range(1, 900);
                _ = try lb.rect(gpa, layer, x, y, x + w, y + rng.range(1, 900));
            },
            1 => {
                const arm = rng.range(4, 800);
                _ = try lb.shape(gpa, layer, shapes.lShape(x, y, arm, rng.range(1, arm)));
            },
            else => {
                const arm = rng.range(4, 800);
                const t = rng.range(1, arm);
                _ = try lb.shape(gpa, layer, shapes.uShape(x, y, arm, t, rng.range(1, 400)));
            },
        }
    }
    var f: Fixture = .{};
    defer f.deinit();
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &f.store, &ids);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(@as(u32, 120), f.out.len());
    for (0..120) |i| {
        const poly = f.out.get(@intCast(i));
        const outer = poly.outer();
        try testing.expectEqual(ops.Winding.ccw, wind(outer).?);
        try testing.expect(area2(outer) > 0);
        try testing.expect(!try geom.simple.selfIntersects(gpa, outer.xs, outer.ys, .cross));
        try testing.expect(outer.xs.len >= 4);
        try testing.expectEqual(Bbox.ofPoints(outer.xs, outer.ys), poly.bbox());
        // With no holes, the polygon's area is half its outer's doubled area.
        try testing.expectEqual(area2(outer), 2 * polygonArea(poly));
    }
}

test "a hole winds clockwise and its area is subtracted from its container" {
    // Oracle: closed form. A hole is subtracted, so the polygon's area is the
    // outer rectangle less the inner one, and the hole's ring winds clockwise
    // while the outer winds counter-clockwise.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, layer, 0, 0, 100, 100);
    _ = try lb.shape(gpa, layer, shapes.hole(20, 20, 60, 50));
    var f: Fixture = .{};
    defer f.deinit();
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &f.store, &ids);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(@as(u32, 1), f.out.len());
    const poly = f.out.get(0);
    try testing.expectEqual(@as(DbuArea, 100 * 100 - 40 * 30), polygonArea(poly));
    try testing.expectEqual(ops.Winding.ccw, wind(poly.outer()).?);
    try testing.expectEqual(@as(DbuArea, 2 * 100 * 100), area2(poly.outer()));
    try testing.expectEqual(@as(u32, 2), poly.ringCount());
    try testing.expectEqual(ops.Winding.cw, wind(poly.ring(1)).?);
    // A clockwise ring has negative doubled area.
    try testing.expectEqual(@as(DbuArea, -2 * 40 * 30), area2(poly.ring(1)));
    // The polygon's box is the outer boundary's; a hole cannot grow it.
    try testing.expectEqual(Bbox{ .xlo = 0, .ylo = 0, .xhi = 100, .yhi = 100 }, poly.bbox());
}

test "each kind of invalid geometry is refused by name" {
    // Oracle: construct-from-answer. Each run below is invalid for exactly one
    // stated reason, so the error and the polygon it names are both known before
    // the pass runs. Fail closed: a shape the tool cannot represent is an error,
    // never a silently skipped row.
    const h = shapes.hole(0, 0, 10, 10);
    const cases = [_]struct { run: Run, want: Defect }{
        // Three coincident vertices: no distinct points, so no boundary.
        .{ .run = .{ .layer = layer, .xs = &.{ 5, 5, 5 }, .ys = &.{ 5, 5, 5 } }, .want = .{ .degenerate = pid(0) } },
        // A bowtie: four distinct vertices whose boundary crosses itself.
        .{ .run = .{ .layer = layer, .xs = &.{ 0, 10, 10, 0 }, .ys = &.{ 0, 10, 0, 10 } }, .want = .{ .self_intersecting = pid(0) } },
        // A clockwise ring with nothing containing it.
        .{ .run = .{ .layer = layer, .xs = &h[0], .ys = &h[1] }, .want = .{ .orphan_hole = pid(0) } },
        // A triangle: simple, non-degenerate, not rectilinear; refused, never
        // approximated.
        .{ .run = .{ .layer = layer, .xs = &.{ 0, 10, 5 }, .ys = &.{ 0, 0, 9 } }, .want = .{ .not_rectilinear = pid(0) } },
    };
    for (cases) |c| {
        var f: Fixture = .{};
        defer f.deinit();
        try storeOf(&.{c.run}, &f.store);
        try testing.expectEqual(c.want, (try f.validate(layer, .rectilinear)).?);
        try testing.expectEqual(@as(u32, 0), f.out.len());
    }
}

test "an invalid polygon is named by the store row it occupies" {
    // Oracle: construct-from-answer. The error names a [`PolyId`], which is a
    // *store* row and not an index into the layer being validated. Three rectangles
    // occupy layer zero, so the bowtie on layer one cannot be row zero however the
    // sort arranges the rest — and an implementation reporting the within-layer
    // index would say `PolyId(0)` here.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, layer, 0, 0, 40, 40);
    _ = try lb.rect(gpa, layer, 100, 0, 140, 40);
    _ = try lb.rect(gpa, layer, 300, 0, 340, 40);
    const bowtie = try lb.push(gpa, other, &.{ 200, 210, 210, 200 }, &.{ 0, 10, 0, 10 });
    var f: Fixture = .{};
    defer f.deinit();
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &f.store, &ids);
    try testing.expect(@backingInt(ids.of(bowtie)) >= 3);
    try testing.expectEqual(Defect{ .self_intersecting = ids.of(bowtie) }, (try f.validate(other, .rectilinear)).?);
    // The layer holding only good geometry still validates.
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(@as(u32, 3), f.out.len());
}

test "validation reads one layer and clears the buffer it is given" {
    // Oracle: law. `validate_layer_into` reads one layer and only that layer, and
    // the buffer it fills is cleared first — both are what let a caller hoist one
    // `ValidatedLayer` above a loop over layers. A pass that appended instead of
    // clearing would still produce a plausible result on the first call.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    for (0..6) |i| {
        const x: i64 = @intCast(i * 100);
        _ = try lb.rect(gpa, layer, x, 0, x + 50, 50);
    }
    for (0..2) |i| {
        const x: i64 = @intCast(i * 100);
        _ = try lb.rect(gpa, other, x, 500, x + 20, 520);
    }
    var f: Fixture = .{};
    defer f.deinit();
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &f.store, &ids);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(@as(u32, 6), f.out.len());
    try testing.expectEqual(@as(DbuArea, 6 * 50 * 50), totalArea(&f.out));
    // The same buffer, reused: six stale rows must not survive.
    try testing.expectEqual(null, try f.validate(other, .rectilinear));
    try testing.expectEqual(@as(u32, 2), f.out.len());
    try testing.expectEqual(@as(DbuArea, 2 * 20 * 20), totalArea(&f.out));
    // And back again: reuse is symmetric, not a one-way shrink.
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(@as(u32, 6), f.out.len());
}

test "two validations of one store agree ring for ring" {
    // Oracle: determinism. Validation is the input to every boolean and every
    // rule, so two passes over one store must produce the same rings in the same
    // order with the same windings. Ring order is part of the interface — holes
    // follow their outer — so a reordering is a defect and not a detail.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, layer, 0, 0, 200, 200);
    _ = try lb.shape(gpa, layer, shapes.hole(20, 20, 60, 60));
    _ = try lb.shape(gpa, layer, shapes.hole(100, 100, 180, 150));
    _ = try lb.shape(gpa, layer, shapes.lShape(400, 400, 90, 25));
    _ = try lb.shape(gpa, layer, shapes.uShape(-500, -500, 80, 15, 30));
    var f: Fixture = .{};
    defer f.deinit();
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &f.store, &ids);
    var second: ValidatedLayer = .empty;
    defer second.deinit(gpa);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    try testing.expectEqual(null, try view.validateLayer(gpa, &f.store, lid(layer), .rectilinear, &second));
    try testing.expectEqual(f.out.len(), second.len());
    for (0..f.out.len()) |i| {
        const a = f.out.get(@intCast(i));
        const b = second.get(@intCast(i));
        try testing.expectEqual(polygonArea(a), polygonArea(b));
        try testing.expectEqual(a.bbox(), b.bbox());
        try testing.expectEqual(a.ringCount(), b.ringCount());
        for (0..a.ringCount()) |k| {
            const ra = a.ring(@intCast(k));
            const rb = b.ring(@intCast(k));
            try testing.expectEqualSlices(i64, ra.xs, rb.xs);
            try testing.expectEqualSlices(i64, ra.ys, rb.ys);
            try testing.expectEqual(wind(ra), wind(rb));
        }
    }
    // Both holes are subtracted, which fixes that holes accumulate rather
    // than the last one winning. Found by hole count: row order within a
    // layer is not part of the store's interface.
    try testing.expectEqual(@as(u32, 3), f.out.len());
    for (0..3) |i| {
        const poly = f.out.get(@intCast(i));
        if (poly.ringCount() != 3) continue;
        try testing.expectEqual(@as(DbuArea, 200 * 200 - 40 * 40 - 80 * 50), polygonArea(poly));
        break;
    } else return error.TestExpectedTwoHoles;
}

test "octilinear validation takes 45 degree edges and refuses other angles" {
    // Oracle: the definition of `Angles`. A diamond's four edges are at 45
    // degrees: the rectilinear validator refuses it, the octilinear one takes it
    // as a layer that is not rectilinear, of area `2·10² = 200`. A triangle with
    // a 2:1 edge is refused by both.
    var f: Fixture = .{};
    defer f.deinit();
    try storeOf(&.{
        .{ .layer = layer, .xs = &.{ 10, 0, -10, 0 }, .ys = &.{ 0, 10, 0, -10 } },
        .{ .layer = other, .xs = &.{ 0, 20, 0 }, .ys = &.{ 0, 10, 10 } },
    }, &f.store);
    try testing.expectEqual(Defect{ .not_rectilinear = pid(0) }, (try f.validate(layer, .rectilinear)).?);
    try testing.expectEqual(null, try f.validate(layer, .octilinear));
    try testing.expect(!f.out.isRectilinear());
    try testing.expectEqual(@as(DbuArea, 200), totalArea(&f.out));
    try testing.expectEqual(Defect{ .not_octilinear = pid(1) }, (try f.validate(other, .octilinear)).?);
    var sq: Fixture = .{};
    defer sq.deinit();
    try storeOf(&.{.{ .layer = layer, .xs = &.{ 0, 10, 10, 0 }, .ys = &.{ 0, 0, 10, 10 } }}, &sq.store);
    try testing.expectEqual(null, try sq.validate(layer, .octilinear));
    // A square validated octilinear is rectilinear.
    try testing.expect(sq.out.isRectilinear());
}

test "a ring meeting itself at a diagonal vertex is a pinch only if it alternates" {
    // Oracle: the pinch rule `ValidityError::SelfIntersecting` states, at 45
    // degrees. Two triangles meeting tip to tip at (2, 2), drawn as one ring,
    // leave the point along four directions that alternate in and out: valid,
    // area `4 + 4`. The ring that passes the point straight once and turns
    // there once puts two ways out side by side: refused.
    var tips: Fixture = .{};
    defer tips.deinit();
    try storeOf(&.{.{ .layer = layer, .xs = &.{ 0, 4, 2, 4, 0, 2 }, .ys = &.{ 0, 0, 2, 4, 4, 2 } }}, &tips.store);
    try testing.expectEqual(null, try tips.validate(layer, .octilinear));
    try testing.expectEqual(@as(DbuArea, 8), totalArea(&tips.out));
    var straight: Fixture = .{};
    defer straight.deinit();
    try storeOf(&.{.{ .layer = layer, .xs = &.{ 0, 2, 4, 4, 2, 0 }, .ys = &.{ 0, 2, 4, 0, 2, 4 } }}, &straight.store);
    try testing.expectEqual(Defect{ .self_intersecting = pid(0) }, (try straight.validate(layer, .octilinear)).?);
}

test "a hole stays with the outer stored before it" {
    // Oracle: construct-from-answer. Row order: a 30-square with a notch from
    // its top down to its middle (it holds the hole's corners but not its
    // middle), then a 100-square, then the hole `[40, 60]²` stored after it.
    // The hole belongs to the 100-square (area `100² - 20²`); the notched
    // square keeps its own area, `30² - 10·15`; each decomposes into
    // rectangles of exactly its area. (N-s2-2: IHP's `sg13g2_stdcell.gds`
    // places every top cell at the origin, so a keyhole Activ lies under
    // other cells' Activ; bound by smallest box alone, the hole went to the
    // overlapping shape.)
    var f: Fixture = .{};
    defer f.deinit();
    try storeOf(&.{
        .{ .layer = layer, .xs = &.{ 35, 65, 65, 55, 55, 45, 45, 35 }, .ys = &.{ 35, 35, 65, 65, 50, 50, 65, 65 } },
        .{ .layer = layer, .xs = &.{ 0, 100, 100, 0 }, .ys = &.{ 0, 0, 100, 100 } },
        .{ .layer = layer, .xs = &.{ 40, 40, 60, 60 }, .ys = &.{ 40, 60, 60, 40 } },
    }, &f.store);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    const want = [2]struct { holes: u32, area: DbuArea }{ .{ .holes = 0, .area = 30 * 30 - 10 * 15 }, .{ .holes = 1, .area = 100 * 100 - 20 * 20 } };
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, &f.out, &rects, &start);
    for (want, 0..) |w, i| {
        const poly = f.out.get(@intCast(i));
        try testing.expectEqual(w.holes, poly.ringCount() - 1);
        try testing.expectEqual(w.area, polygonArea(poly));
        try testing.expectEqual(w.area, geom.rects.coveredArea(rects.items[start.items[i]..start.items[i + 1]]));
    }
}

test "a selection reads its angles from the polygons it keeps" {
    // Oracle: construct-from-answer. From a layer holding a box, a triangle
    // with a 45-degree edge and one with an edge at another angle, a selection
    // is rectilinear exactly when it leaves out both triangles, and octilinear
    // exactly when it leaves out the second.
    var f: Fixture = .{};
    defer f.deinit();
    try storeOf(&.{
        .{ .layer = layer, .xs = &.{ 0, 10, 10, 0 }, .ys = &.{ 0, 0, 10, 10 } },
        .{ .layer = layer, .xs = &.{ 20, 30, 20 }, .ys = &.{ 0, 0, 10 } },
        .{ .layer = layer, .xs = &.{ 40, 50, 40 }, .ys = &.{ 0, 0, 20 } },
    }, &f.store);
    try testing.expectEqual(null, try f.validate(layer, .any));
    var out: ValidatedLayer = .empty;
    defer out.deinit(gpa);
    const cases = [_]struct { keep: [3]bool, rectilinear: bool, octilinear: bool }{
        .{ .keep = .{ true, false, false }, .rectilinear = true, .octilinear = true },
        .{ .keep = .{ false, true, false }, .rectilinear = false, .octilinear = true },
        .{ .keep = .{ false, false, true }, .rectilinear = false, .octilinear = false },
    };
    for (cases) |c| {
        try f.out.selectInto(gpa, &c.keep, &out);
        try testing.expectEqual(c.rectilinear, out.isRectilinear());
        try testing.expectEqual(c.octilinear, out.isOctilinear());
    }
}

test "a hole stored after its outer stays with it though a smaller outer holds it too" {
    // Oracle: hand-derived from the binding rule `validate_layer_with`
    // documents: a hole stored right after an outer that contains it is that
    // outer's, even where a smaller outer contains it too. Rows: a far square,
    // a small square around the hole, a big square around both, then the hole.
    // The big square holds it and the small one holds none.
    var f: Fixture = .{};
    defer f.deinit();
    try storeOf(&.{
        .{ .layer = layer, .xs = &.{ 100, 110, 110, 100 }, .ys = &.{ 0, 0, 10, 10 } },
        .{ .layer = layer, .xs = &.{ -8, 8, 8, -8 }, .ys = &.{ -8, -8, 8, 8 } },
        .{ .layer = layer, .xs = &.{ -50, 50, 50, -50 }, .ys = &.{ -50, -50, 50, 50 } },
        .{ .layer = layer, .xs = &.{ -5, -5, 5, 5 }, .ys = &.{ -5, 5, 5, -5 } },
    }, &f.store);
    try testing.expectEqual(null, try f.validate(layer, .rectilinear));
    for ([_]u32{ 0, 0, 1 }, 0..) |holes, i| try testing.expectEqual(holes, f.out.get(@intCast(i)).ringCount() - 1);
}
