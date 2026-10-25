//! The width and notch of octilinear polygons (`width.narrowestPair2`), and
//! the edge-pair relation. Ported from crates/geom/tests/core/width_pairs.rs.
//!
//! Oracle: on rectilinear polygons, a differential against the rectilinear
//! measures (`narrowestWidth2`, `narrowestFacing`); on 45-degree polygons,
//! hand-derived widths; and the edge-pair port in `relation` against
//! `narrowestPair2`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const testgen = @import("testgen");
const prop = testgen.prop;
const Rng = testgen.Rng;
const point = testgen.shapes.point;
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const width = geom.width;
const relation = geom.relation;
const Seg = geom.Seg;
const ValidatedLayer = geom.ValidatedLayer;

const Ring = []const [2]i64;
const far: i64 = 1_000;

// ---- private ----

/// Two to six random rectangles on a 40-unit grid, as rings.
fn rectangles(arena: Allocator, rng: *Rng) Allocator.Error![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    const n = rng.range(2, 7);
    for (0..@intCast(n)) |_| {
        const x = rng.range(0, 36);
        const y = rng.range(0, 36);
        const w = rng.range(1, 41 - x);
        const h = rng.range(1, 41 - y);
        try out.append(arena, try arena.dupe([2]i64, &.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } }));
    }
    return out.items;
}

fn shrinkRings(arena: Allocator, rings: []const Ring) Allocator.Error![]const []const Ring {
    return fx.dropOne(Ring, arena, rings, false);
}

fn shrinkNonEmpty(arena: Allocator, rings: []const Ring) Allocator.Error![]const []const Ring {
    return fx.dropOne(Ring, arena, rings, true);
}

fn pair2(poly: geom.Polygon, gap: width.Gap) !?i128 {
    const f = try width.narrowestPair2(gpa, poly, gap, far) orelse return null;
    return f.d2;
}

/// The general measure equals the rectilinear one on every figure: width
/// twice-squared, notch twice-squared, or both absent.
fn agrees(_: Allocator, rings: []const Ring, why: *prop.Why) anyerror!void {
    var layer = try fx.layerOf(rings, .octilinear, true);
    defer layer.deinit(gpa);
    var scratch: width.FacingScratch = .{};
    defer scratch.deinit(gpa);
    for (0..layer.len()) |i| {
        const poly = layer.get(@intCast(i));
        const w = 2 * try width.narrowestWidth2(gpa, poly, &scratch);
        const general = try pair2(poly, .width);
        if (general == null or general.? != w) return why.fail("figure {d}: width {d} rectilinear, {?d} general", .{ i, w, general });
        const facing = try width.narrowestFacing(gpa, poly, .notch, &scratch);
        const notch: ?i128 = if (facing) |f| 2 * geom.mulWide(f.gap, f.gap) else null;
        const general_notch = try pair2(poly, .notch);
        if (!std.meta.eql(notch, general_notch)) return why.fail("figure {d}: notch {?d} rectilinear, {?d} general", .{ i, notch, general_notch });
    }
}

fn width2(rings: []const Ring) !?i128 {
    var layer = try fx.layerOf(rings, .octilinear, true);
    defer layer.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), layer.len());
    return pair2(layer.get(0), .width);
}

fn reversed(s: Seg) Seg {
    return .{ .a = s.b, .b = s.a };
}

/// KLayout's width read edge pair by edge pair through `relation` (every
/// ordered pair of a figure's edges, its own pair apart) equals
/// `narrowestPair2` on every figure, as twice squares, or both find nothing.
fn pairsAgree(_: Allocator, rings: []const Ring, why: *prop.Why) anyerror!void {
    var layer = try fx.layerOf(rings, .octilinear, true);
    defer layer.deinit(gpa);
    var edges: std.ArrayList(Seg) = .empty;
    defer edges.deinit(gpa);
    for (0..layer.len()) |idx| {
        const poly = layer.get(@intCast(idx));
        edges.clearRetainingCapacity();
        var it = width.polyEdges(poly);
        while (it.next()) |s| try edges.append(gpa, reversed(s));
        var by_pairs: ?i128 = null;
        for (edges.items, 0..) |e, i| for (edges.items, 0..) |f, j| {
            if (i == j) continue;
            const d2 = relation.pairThreshold2(.width, .euclidean, .when_touching, e, f) orelse continue;
            if (by_pairs == null or d2 < by_pairs.?) by_pairs = d2;
        };
        const narrowest = try pair2(poly, .width);
        if (!std.meta.eql(by_pairs, narrowest)) return why.fail("figure {d}: {?d} by pairs, {?d} narrowest", .{ idx, by_pairs, narrowest });
    }
}

fn octShapes(arena: Allocator, rng: *Rng) Allocator.Error![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    const n = rng.range(1, 5);
    for (0..@intCast(n)) |_| try out.append(arena, try fx.randomOctShape(arena, rng));
    return out.items;
}

fn segment(a: [2]i64, b: [2]i64) Seg {
    return .{ .a = point(a[0], a[1]), .b = point(b[0], b[1]) };
}

test "the general width and notch are the rectilinear ones on rectilinear figures" {
    // Oracle: differential against `narrowest_width2` and `narrowest_facing`
    // on random merged rectangles (overlaps, necks, notches, holes, corner
    // touches), over 300 named seeds.
    try prop.check(gpa, []const Ring, "width_pairs", 300, &.{}, rectangles, shrinkRings, agrees);
}

test "octilinear widths are euclidean" {
    // Oracle: hand-derived Euclidean widths. A 45-degree bar with square ends
    // between `y = x` and `y = x + 10` is `10/√2` wide (twice squared, 100); a
    // diamond of radius 10 is `10·√2` across its parallel sides (400), its
    // corners being right angles; a right triangle's two 45-degree tips are
    // acute, so 0 wide. A 20-square with corners chamfered by 2 pairs each
    // chamfer with the side across, at 135 degrees, as `KLayout`'s Euclidean
    // `width` does: from the chamfer's end (18, 0) to the side's end (0, 2),
    // `√328` (656), under 20. And two gf180mcu `fd_pv` unit structures the
    // foundry's deck flags (shifted to the origin): NW.1a, a 2580 x 1720 box
    // chamfered at one corner whose side next to the chamfer is 855 long; DF.1a,
    // an L of 221-wide arms whose outer corner is cut by a 158 chamfer, its
    // inner corner (221, 221) `284/√2` from the chamfer's line `x + y = 158`.
    try testing.expectEqual(@as(?i128, 2 * 855 * 855), try width2(&.{&.{ .{ 0, 0 }, .{ 2580, 0 }, .{ 2580, 1720 }, .{ 865, 1720 }, .{ 0, 855 } }}));
    try testing.expectEqual(@as(?i128, 284 * 284), try width2(&.{&.{ .{ 158, 0 }, .{ 884, 0 }, .{ 884, 221 }, .{ 221, 221 }, .{ 221, 884 }, .{ 0, 884 }, .{ 0, 158 } }}));
    try testing.expectEqual(@as(?i128, 100), try width2(&.{&.{ .{ 0, 0 }, .{ 40, 40 }, .{ 35, 45 }, .{ -5, 5 } }}));
    try testing.expectEqual(@as(?i128, 400), try width2(&.{&.{ .{ 10, 0 }, .{ 0, 10 }, .{ -10, 0 }, .{ 0, -10 } }}));
    try testing.expectEqual(@as(?i128, 656), try width2(&.{&.{ .{ 2, 0 }, .{ 18, 0 }, .{ 20, 2 }, .{ 20, 18 }, .{ 18, 20 }, .{ 2, 20 }, .{ 0, 18 }, .{ 0, 2 } }}));
    try testing.expectEqual(@as(?i128, 0), try width2(&.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } }}));
}

test "a u turned 45 degrees keeps its width and notch times root two" {
    // Oracle: the 45-degree law, construct-from-answer. A U with arms 10
    // wide, a base 5 tall and a slot 10 wide measures width 5 and notch 10
    // (twice squared, 50 and 200); turned by `(x, y) -> (x - y, x + y)`, which
    // turns every direction 45 degrees and stretches every length by `√2`, it
    // measures twice each square (100 and 400).
    const u = [_][2]i64{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 20 }, .{ 20, 20 }, .{ 20, 5 }, .{ 10, 5 }, .{ 10, 20 }, .{ 0, 20 } };
    var turned: [u.len][2]i64 = undefined;
    for (&turned, u) |*t, p| t.* = .{ p[0] - p[1], p[0] + p[1] };
    for ([_]struct { ring: Ring, w: i128, notch: i128 }{ .{ .ring = &u, .w = 50, .notch = 200 }, .{ .ring = &turned, .w = 100, .notch = 400 } }) |c| {
        var layer = try fx.layerOf(&.{c.ring}, .octilinear, true);
        defer layer.deinit(gpa);
        try testing.expectEqual(@as(?i128, c.w), try pair2(layer.get(0), .width));
        try testing.expectEqual(@as(?i128, c.notch), try pair2(layer.get(0), .notch));
    }
}

test "the edge pair relation reads width as narrowest pair2" {
    // Oracle: differential between two implementations of `KLayout`'s
    // unshielded Euclidean width, `narrowest_pair2` (held to `KLayout` itself by
    // the nightly mirror differential) and the edge-pair port in
    // `gpurify_geom::relation`, on random merged octilinear shapes (chamfered
    // rectangles, diamonds, right triangles, parallelograms) over 300 named
    // seeds. A port that misreads a cut, an angle, a zero-distance mode or a
    // near part disagrees on some figure.
    try prop.check(gpa, []const Ring, "relation_width", 300, &.{}, octShapes, shrinkNonEmpty, pairsAgree);
}

test "the narrowest pair is reported midway between its two nearest points" {
    // Oracle: hand-derived. The 10 x 4 box at `(2, 6)` is narrowest across its
    // top and bottom edges, 4 apart: twice squared, 32. Its report point is the
    // midpoint of an end of one of those edges and that end's foot on the
    // other, so it lies on the box's middle line `y = 8`, at `x = 2` or `x = 12`.
    var layer = try fx.layerOf(&.{&.{ .{ 2, 6 }, .{ 12, 6 }, .{ 12, 10 }, .{ 2, 10 } }}, .octilinear, true);
    defer layer.deinit(gpa);
    const f = (try width.narrowestPair2(gpa, layer.get(0), .width, far)).?;
    try testing.expectEqual(@as(i128, 32), f.d2);
    try testing.expectEqual(@as(i64, 8), f.at.y);
    try testing.expect(f.at.x == 2 or f.at.x == 12);
}

test "edges that cross are zero apart by projection" {
    // Oracle: hand-derived. In `KLayout`'s orientation `a` is the top edge of a
    // shape below `y = 0`, and the slanted `b`, its shape up and to the right,
    // crosses `a` at `(8, 0)`: the two edges touch, so under the default zero
    // mode the pair is reported at distance 0 by projection. Only the part of
    // `b` above `a`'s line, `(2, 6)`-`(8, 0)`, faces `a`; read whole, `b`'s
    // lower end would put the nearest projected point at `(10, -2)`, 2 off.
    try testing.expectEqual(@as(?i128, 0), relation.pairThreshold2(.space, .projection, .when_touching, segment(.{ 0, 0 }, .{ 10, 0 }), segment(.{ 14, -6 }, .{ 2, 6 })));
}

test "a projected reach is the square distance over the edge and none past it" {
    // Oracle: hand-derived. `a` is the top edge of a shape below `y = 0` and
    // `b` the bottom edge of one above `y = 4`, both in `KLayout`'s orientation:
    // the point `(5, 4)` of `b` stands square over `a` at 4, twice squared 32,
    // and `(15, 4)` is past `a`'s end, so no projection reaches it.
    const a = segment(.{ 0, 0 }, .{ 10, 0 });
    const b = segment(.{ 20, 4 }, .{ 0, 4 });
    try testing.expectEqual(@as(?i128, 32), relation.projectedReach2(.space, .when_touching, a, b, point(5, 4)));
    try testing.expectEqual(@as(?i128, null), relation.projectedReach2(.space, .when_touching, a, b, point(15, 4)));
}
