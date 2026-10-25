//! The corner model: material that meets only at a corner is joined there.
//! Ported from crates/geom/tests/core/corner_model.rs.
//!
//! `boolean.unionInto` states it. Two cells touching at a corner are one
//! polygon, and the corner is a neck of width 0. Empty space does not pass a
//! corner where material meets, so a ring closed only at a corner encloses a
//! hole. A polygon is one 8-connected component of the cells, a hole one
//! 4-connected component of the space it encloses, however the cells were
//! drawn.
//!
//! Oracle: that definition, applied by hand to cells of side `s`. Pictures
//! are rows top to bottom, `#` a cell.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const width = geom.width;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const Defect = geom.view.Defect;

const s: i64 = 100;
const CellMap = *const fn (i64, i64, i64) [2]i64;

/// A polygon's area and its holes' areas, ascending.
const Figure = struct { area: i128, holes: [4]i128 = @splat(0), hole_count: usize = 0 };

const maps = [8]CellMap{
    struct {
        fn f(_: i64, x: i64, y: i64) [2]i64 {
            return .{ x, y };
        }
    }.f,
    struct {
        fn f(n: i64, x: i64, y: i64) [2]i64 {
            return .{ n - 1 - y, x };
        }
    }.f,
    struct {
        fn f(n: i64, x: i64, y: i64) [2]i64 {
            return .{ n - 1 - x, n - 1 - y };
        }
    }.f,
    struct {
        fn f(n: i64, x: i64, y: i64) [2]i64 {
            return .{ y, n - 1 - x };
        }
    }.f,
    struct {
        fn f(n: i64, x: i64, y: i64) [2]i64 {
            return .{ n - 1 - x, y };
        }
    }.f,
    struct {
        fn f(n: i64, x: i64, y: i64) [2]i64 {
            return .{ x, n - 1 - y };
        }
    }.f,
    struct {
        fn f(_: i64, x: i64, y: i64) [2]i64 {
            return .{ y, x };
        }
    }.f,
    struct {
        fn f(n: i64, x: i64, y: i64) [2]i64 {
            return .{ n - 1 - y, n - 1 - x };
        }
    }.f,
};

// ---- private ----

/// The cells of a picture as `(column, row)`, row 0 at the bottom.
fn cells(picture: []const u8, out: *std.ArrayList([2]i64)) !void {
    out.clearRetainingCapacity();
    const rows = std.mem.count(u8, picture, "|") + 1;
    var it = std.mem.splitScalar(u8, picture, '|');
    var r: i64 = 0;
    while (it.next()) |row| : (r += 1) {
        for (row, 0..) |ch, x| {
            if (ch == '#') try out.append(gpa, .{ @intCast(x), @as(i64, @intCast(rows)) - 1 - r });
        }
    }
}

/// One counter-clockwise ring per cell, each starting at corner `start`.
fn draw(list: []const [2]i64, start: usize, store: *GeometryStore) !void {
    var lb: @import("testgen").shapes.LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    for (list) |c| {
        const x0 = c[0] * s;
        const y0 = c[1] * s;
        var xs = [4]i64{ x0, x0 + s, x0 + s, x0 };
        var ys = [4]i64{ y0, y0, y0 + s, y0 + s };
        std.mem.rotate(i64, &xs, start);
        std.mem.rotate(i64, &ys, start);
        _ = try lb.push(gpa, 0, &xs, &ys);
    }
    var ids: @import("testgen").shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, store, &ids);
}

/// One ring of raw vertices on the layer.
fn ringStore(points: []const [2]i64, store: *GeometryStore) !void {
    try fx.storeOfShapes(&.{.{ .layer = 0, .pts = points }}, 1, store);
}

fn merged(store: *const GeometryStore) !ValidatedLayer {
    var drawn = try fx.validated(store, 0, .rectilinear);
    defer drawn.deinit(gpa);
    return fx.run(.@"or", &drawn, &.empty);
}

/// Each polygon's area and its holes' areas, ascending.
fn figures(l: *const ValidatedLayer, out: *std.ArrayList(Figure)) !void {
    out.clearRetainingCapacity();
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        var f: Figure = .{ .area = @import("testgen").shapes.polygonArea(p) };
        for (1..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            f.holes[f.hole_count] = @divExact(-geom.ops.area2(r.xs, r.ys), 2);
            f.hole_count += 1;
        }
        std.mem.sort(i128, f.holes[0..f.hole_count], {}, std.sort.asc(i128));
        try out.append(gpa, f);
    }
    std.mem.sort(Figure, out.items, {}, struct {
        fn lessThan(_: void, a: Figure, b: Figure) bool {
            return a.area < b.area;
        }
    }.lessThan);
}

fn expectFigures(l: *const ValidatedLayer, want: []const Figure) !void {
    var got: std.ArrayList(Figure) = .empty;
    defer got.deinit(gpa);
    try figures(l, &got);
    try testing.expectEqualSlices(Figure, want, got.items);
}

test "cells joined only at corners are one polygon" {
    // Oracle: the corner model `union_into` states (a polygon is one 8-connected
    // component of cells, a hole one 4-connected component of the space it
    // encloses), applied by hand: `.#.|#.#`, three cells meeting at two
    // corners, are one polygon of 30 000 with no hole, and its ring passes each
    // of the two touch points twice.
    var list: std.ArrayList([2]i64) = .empty;
    defer list.deinit(gpa);
    try cells(".#.|#.#", &list);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try draw(list.items, 0, &store);
    var layer = try merged(&store);
    defer layer.deinit(gpa);
    try expectFigures(&layer, &.{.{ .area = 30_000 }});
    const outer = layer.get(0).outer();
    for ([_][2]i64{ .{ s, s }, .{ 2 * s, s } }) |corner| {
        var visits: usize = 0;
        for (outer.xs, outer.ys) |x, y| visits += @intFromBool(x == corner[0] and y == corner[1]);
        try testing.expectEqual(@as(usize, 2), visits);
    }
}

test "a corner is a neck of width zero and the gap beside it a notch" {
    // Oracle: the corner model `union_into` states, applied by hand: the touch
    // point is a width of 0, and the gap between the two lower cells, inside
    // the one figure, faces itself at `S`.
    var list: std.ArrayList([2]i64) = .empty;
    defer list.deinit(gpa);
    try cells(".#.|#.#", &list);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try draw(list.items, 0, &store);
    var layer = try merged(&store);
    defer layer.deinit(gpa);
    var scratch: width.FacingScratch = .{};
    defer scratch.deinit(gpa);
    try testing.expectEqual(@as(i64, 0), try width.narrowestWidth(gpa, layer.get(0), &scratch));
    const notch = (try width.narrowestFacing(gpa, layer.get(0), .notch, &scratch)).?;
    try testing.expectEqual(s, notch.gap);
}

test "a ring closed only at a corner encloses a hole however it is drawn" {
    // Oracle: the corner model `union_into` states, applied by hand, counted
    // from the pictures (7 cells round 1 empty, 11 round 3), and a metamorphic
    // relation: every symmetry of the square, drawing order and starting
    // corner gives the same figure.
    const cases = [_]struct { picture: []const u8, n: i64, cells_in: i128, empty_in: i128 }{
        .{ .picture = "###|#.#|.##", .n = 3, .cells_in = 7, .empty_in = 1 },
        .{ .picture = "##..|#.##|#..#|####", .n = 4, .cells_in = 11, .empty_in = 3 },
    };
    var list: std.ArrayList([2]i64) = .empty;
    defer list.deinit(gpa);
    var image: std.ArrayList([2]i64) = .empty;
    defer image.deinit(gpa);
    for (cases) |c| {
        const want = [_]Figure{.{ .area = c.cells_in * s * s, .holes = .{ c.empty_in * s * s, 0, 0, 0 }, .hole_count = 1 }};
        try cells(c.picture, &list);
        for (maps) |map| {
            image.clearRetainingCapacity();
            for (list.items) |p| try image.append(gpa, map(c.n, p[0], p[1]));
            for (0..2) |_| {
                for (0..4) |start| {
                    var store: GeometryStore = .empty;
                    defer store.deinit(gpa);
                    try draw(image.items, start, &store);
                    var layer = try merged(&store);
                    defer layer.deinit(gpa);
                    try expectFigures(&layer, &want);
                }
                std.mem.reverse([2]i64, image.items);
            }
        }
    }
}

test "a ring closed at a corner drawn as one boundary merges to the same hole" {
    // Oracle: the corner model `union_into` states, applied by hand: the
    // boundary encloses seven cells, 70 000, and the merge gives the one-cell
    // hole of 10 000 the cell drawing gives.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try ringStore(&.{ .{ 100, 100 }, .{ 100, 0 }, .{ 300, 0 }, .{ 300, 300 }, .{ 0, 300 }, .{ 0, 100 }, .{ 100, 100 }, .{ 100, 200 }, .{ 200, 200 }, .{ 200, 100 } }, &store);
    // A boundary touching itself at a corner is valid.
    var drawn = try fx.validated(&store, 0, .rectilinear);
    defer drawn.deinit(gpa);
    try expectFigures(&drawn, &.{.{ .area = 70_000 }});
    var layer = try merged(&store);
    defer layer.deinit(gpa);
    try expectFigures(&layer, &.{.{ .area = 70_000, .holes = .{ 10_000, 0, 0, 0 }, .hole_count = 1 }});
}

test "an island joined to its frame at a corner is part of the frame" {
    // Oracle: the corner model `union_into` states, applied by hand: in
    // `#####|#...#|#.#.#|##..#|#####` the centre cell meets the frame only at
    // its lower left corner, so 18 cells join into one polygon of 180 000
    // round one hole of seven empty cells, 70 000.
    var list: std.ArrayList([2]i64) = .empty;
    defer list.deinit(gpa);
    try cells("#####|#...#|#.#.#|##..#|#####", &list);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try draw(list.items, 0, &store);
    var layer = try merged(&store);
    defer layer.deinit(gpa);
    try expectFigures(&layer, &.{.{ .area = 180_000, .holes = .{ 70_000, 0, 0, 0 }, .hole_count = 1 }});
}

test "a boundary through a corner twice is valid" {
    // Oracle: the corner model `union_into` states, applied by hand: two 100
    // squares meeting at a corner are one figure of 20 000.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try ringStore(&.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 200, 100 }, .{ 200, 200 }, .{ 100, 200 }, .{ 100, 100 }, .{ 0, 100 } }, &store);
    var layer = try fx.validated(&store, 0, .rectilinear);
    defer layer.deinit(gpa);
    try expectFigures(&layer, &.{.{ .area = 20_000 }});
}

test "a crossing or a spike at a twice visited vertex is refused" {
    // Oracle: the corner model's limit, as `union_into` states it: only a corner
    // touch is admitted, so a boundary passing a vertex straight twice crosses
    // itself and a spike doubles back; both are `SelfIntersecting`.
    const crossing = [_][2]i64{ .{ -200, 0 }, .{ 0, 0 }, .{ 200, 0 }, .{ 200, 100 }, .{ 0, 100 }, .{ 0, 0 }, .{ 0, -100 }, .{ -200, -100 } };
    const spike = [_][2]i64{ .{ -100, 0 }, .{ 0, 0 }, .{ 0, 100 }, .{ 0, 0 }, .{ 100, 0 }, .{ 100, -100 }, .{ -100, -100 } };
    for ([_][]const [2]i64{ &crossing, &spike }) |pts| {
        var store: GeometryStore = .empty;
        defer store.deinit(gpa);
        try ringStore(pts, &store);
        var out: ValidatedLayer = .empty;
        defer out.deinit(gpa);
        try testing.expectEqual(Defect{ .self_intersecting = @fromBackingInt(0) }, (try geom.view.validateLayer(gpa, &store, @fromBackingInt(0), .rectilinear, &out)).?);
    }
}
