//! Rectilinear decomposition: the rectangles tile the polygon and nothing
//! else. Ported from crates/geom/tests/core/rects_decomposition.rs.
//!
//! Two claims carry everything downstream: the rectangles are exact, so
//! their areas sum to the polygon's with no correction, and disjoint, so the
//! sum is not an over-count. `min_area`, density and occupancy all measure
//! through them.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const shapes = testgen.shapes;
const Rng = testgen.Rng;
const rects = geom.rects;
const Bbox = geom.Bbox;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;

const gpa = testing.allocator;

/// A store, a validated layer of it, and a decomposition's two outputs.
const Fixture = struct {
    store: GeometryStore = .empty,
    layer: ValidatedLayer = .empty,
    rects: std.ArrayList(Bbox) = .empty,
    start: std.ArrayList(u32) = .empty,

    fn deinit(f: *Fixture) void {
        f.store.deinit(gpa);
        f.layer.deinit(gpa);
        f.rects.deinit(gpa);
        f.start.deinit(gpa);
    }

    fn load(f: *Fixture, lb: *shapes.LayoutBuilder) !void {
        var ids: shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &f.store, &ids);
    }

    fn decompose(f: *Fixture, l: u16) !void {
        try testing.expectEqual(null, try geom.view.validateLayer(gpa, &f.store, @fromBackingInt(l), .rectilinear, &f.layer));
        try rects.decomposeInto(gpa, &f.layer, &f.rects, &f.start);
    }
};

// ---- private ----

fn bbox(xlo: i64, ylo: i64, xhi: i64, yhi: i64) Bbox {
    return .{ .xlo = xlo, .ylo = ylo, .xhi = xhi, .yhi = yhi };
}

/// Whether two rectangles share interior area, from the bounds, so it cannot
/// agree with a broken decomposition for the reason a broken `overlaps` would.
fn interiorsMeet(a: Bbox, b: Bbox) bool {
    return a.xlo < b.xhi and b.xlo < a.xhi and a.ylo < b.yhi and b.ylo < a.yhi;
}

test "a decomposition covers exactly the area of the polygon it came from" {
    // Oracle: closed form. Each shape's area is stated by the generator as a
    // formula in its parameters, and an exact decomposition must reproduce it
    // exactly. The L, plus and U are here because their bounding boxes overstate
    // them, so a slab sweep that lost or duplicated a slab fails on them and
    // passes on the rectangle.
    var lb: shapes.LayoutBuilder = .init(4);
    defer lb.deinit(gpa);
    // Each shape on its own layer, so it is polygon zero of its layer.
    _ = try lb.shape(gpa, 0, shapes.rect(0, 0, 40, 25));
    _ = try lb.shape(gpa, 1, shapes.lShape(0, 0, 100, 30));
    _ = try lb.shape(gpa, 2, shapes.plusShape(0, 0, 60, 8));
    _ = try lb.shape(gpa, 3, shapes.uShape(0, 0, 100, 20, 40));
    const areas = [4]i128{ 1_000, shapes.lShapeArea(100, 30), shapes.plusShapeArea(60, 8), shapes.uShapeArea(100, 20, 40) };
    var f: Fixture = .{};
    defer f.deinit();
    try f.load(&lb);
    for (areas, 0..) |area, l| {
        try f.decompose(@intCast(l));
        try testing.expectEqual(@as(usize, 2), f.start.items.len);
        try testing.expectEqual(@as(u32, 0), f.start.items[0]);
        try testing.expectEqual(f.rects.items.len, f.start.items[1]);
        try testing.expect(f.rects.items.len > 0);
        try testing.expectEqual(area, rects.coveredArea(f.rects.items));
        var sum: DbuArea = 0;
        for (f.rects.items) |r| sum += r.area();
        try testing.expectEqual(sum, rects.coveredArea(f.rects.items));
    }
}

test "the rectangles of one polygon are pairwise disjoint" {
    // Oracle: law. Disjointness is what makes the sum a sum. Asserted pairwise
    // over a generated layer, and asserted *per polygon*: rectangles of different
    // polygons may legitimately abut, but two rectangles of one polygon sharing
    // interior area is a double count.
    var rng = Rng.init(61);
    var lb: shapes.LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    var stated: i128 = 0;
    for (0..80) |_| {
        const x = rng.range(-100_000, 100_000);
        const y = rng.range(-100_000, 100_000);
        const arm = rng.range(4, 600);
        const thickness = rng.range(1, arm);
        if (rng.unit() < 0.5) {
            _ = try lb.shape(gpa, 0, shapes.lShape(x, y, arm, thickness));
            stated += shapes.lShapeArea(arm, thickness);
        } else {
            const gap = rng.range(1, 300);
            _ = try lb.shape(gpa, 0, shapes.uShape(x, y, arm, thickness, gap));
            stated += shapes.uShapeArea(arm, thickness, gap);
        }
    }
    var f: Fixture = .{};
    defer f.deinit();
    try f.load(&lb);
    try f.decompose(0);
    try testing.expectEqual(@as(usize, f.layer.len()) + 1, f.start.items.len);
    var total: DbuArea = 0;
    for (0..f.layer.len()) |i| {
        const own = f.rects.items[f.start.items[i]..f.start.items[i + 1]];
        try testing.expect(own.len > 0);
        for (own, 0..) |a, k| {
            try testing.expect(a.xlo < a.xhi and a.ylo < a.yhi);
            for (own[k + 1 ..]) |b| try testing.expect(!interiorsMeet(a, b));
        }
        try testing.expectEqual(shapes.polygonArea(f.layer.get(@intCast(i))), rects.coveredArea(own));
        total += rects.coveredArea(own);
    }
    try testing.expectEqual(stated, total);
}

test "clipped area is the covered area inside the window and nothing outside it" {
    // Oracle: closed form. Clipping to a window that contains everything is the
    // covered area; clipping to a window that touches nothing is zero; and
    // clipping a rectangle to a window that halves it is half. The last is the
    // only one of the three that can distinguish a real clip from a containment
    // test, which is why the window is placed to cut through the shapes rather
    // than around them.
    var lb: shapes.LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    // Two rectangles, both straddling x = 100.
    _ = try lb.rect(gpa, 0, 0, 0, 200, 50);
    _ = try lb.rect(gpa, 0, 50, 100, 150, 200);
    var f: Fixture = .{};
    defer f.deinit();
    try f.load(&lb);
    try f.decompose(0);
    const r = f.rects.items;
    const covered = rects.coveredArea(r);
    try testing.expectEqual(@as(DbuArea, 200 * 50 + 100 * 100), covered);
    // A window swallowing everything, and exactly the shapes' extent.
    try testing.expectEqual(covered, rects.clippedArea(r, bbox(-10, -10, 400, 400)));
    try testing.expectEqual(covered, rects.clippedArea(r, bbox(0, 0, 200, 200)));
    // A window nowhere near them.
    try testing.expectEqual(@as(DbuArea, 0), rects.clippedArea(r, bbox(10_000, 10_000, 20_000, 20_000)));
    // The left half: 100 x 50 of the low rectangle and 50 x 100 of the high.
    try testing.expectEqual(@as(DbuArea, 100 * 50 + 50 * 100), rects.clippedArea(r, bbox(0, 0, 100, 200)));
    // The two halves of a window partition the covered area.
    try testing.expectEqual(covered, rects.clippedArea(r, bbox(0, 0, 100, 200)) + rects.clippedArea(r, bbox(100, 0, 200, 200)));
    // A horizontal band that catches only the low rectangle.
    try testing.expectEqual(@as(DbuArea, 200 * 50), rects.clippedArea(r, bbox(0, 0, 200, 50)));
}

test "clipped area is monotone and bounded by the window and the shapes" {
    // Oracle: law. A window's clipped area is bounded by the covered area and by
    // the window's own area, is monotone as the window grows, and is exactly the
    // covered area once the window contains the shapes' bounding box. Checked over
    // arbitrary windows against a generated layer, where no closed form is
    // available.
    var rng = Rng.init(62);
    var lb: shapes.LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    const placed = try shapes.randomRectilinearLayer(&lb, gpa, &rng, 0, .{ 0, 0 }, .{ .cells = 24, .cell = 500, .density = 0.35 });
    var f: Fixture = .{};
    defer f.deinit();
    try f.load(&lb);
    try f.decompose(0);
    try testing.expectEqual(placed.shapes, f.layer.len());
    const r = f.rects.items;
    const covered = rects.coveredArea(r);
    // The generator states the covered area exactly: the squares do not touch.
    try testing.expectEqual(placed.covered, covered);
    try testing.expectEqual(covered, rects.clippedArea(r, bbox(-1, -1, placed.extent + 1, placed.extent + 1)));
    for (0..64) |_| {
        const x = rng.range(-1_000, placed.extent);
        const y = rng.range(-1_000, placed.extent);
        const w = rng.range(1, 6_000);
        const h = rng.range(1, 6_000);
        const window = bbox(x, y, x + w, y + h);
        const inside = rects.clippedArea(r, window);
        try testing.expect(inside <= covered);
        try testing.expect(inside <= window.area());
        try testing.expect(inside >= 0);
        // Grown on every side, a window cannot lose area.
        try testing.expect(rects.clippedArea(r, bbox(x - 250, y - 250, x + w + 250, y + h + 250)) >= inside);
    }
}

test "two decompositions of one layer produce the same rectangles in the same order" {
    // Oracle: determinism. The doc comment names the decomposition canonical — the
    // same polygon always decomposes the same way — because the determinism gate
    // needs it. Run it twice into buffers that already hold a different result,
    // which is how a caller reusing one buffer across layers actually calls it.
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    _ = try lb.shape(gpa, 0, shapes.plusShape(0, 0, 60, 8));
    _ = try lb.shape(gpa, 0, shapes.uShape(500, 0, 90, 15, 30));
    _ = try lb.shape(gpa, 0, shapes.lShape(0, 500, 100, 30));
    _ = try lb.rect(gpa, 1, 0, 0, 10, 10);
    var f: Fixture = .{};
    defer f.deinit();
    try f.load(&lb);
    try f.decompose(0);
    const first_rects = try gpa.dupe(Bbox, f.rects.items);
    defer gpa.free(first_rects);
    const first_start = try gpa.dupe(u32, f.start.items);
    defer gpa.free(first_start);
    // Reuse the buffers for another layer, then come back.
    try f.decompose(1);
    try testing.expectEqual(@as(usize, 2), f.start.items.len);
    try testing.expectEqual(@as(usize, 1), f.rects.items.len);
    try testing.expectEqual(@as(DbuArea, 100), rects.coveredArea(f.rects.items));
    try f.decompose(0);
    try testing.expectEqualSlices(Bbox, first_rects, f.rects.items);
    try testing.expectEqualSlices(u32, first_start, f.start.items);
    try testing.expect(first_rects.len >= 3);
}
