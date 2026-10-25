//! The booleans on operands with edges at any angle: snap rounding. Ported
//! from crates/geom/tests/core/boolean_anyangle.rs.
//!
//! Oracle, brute force: snap rounding moves every boundary point less than
//! half a unit along each axis (`boolean.unionInto`), so at every point
//! farther than half a unit along some axis from every operand edge (outside
//! every edge's closed L∞ band of radius ½) the result holds exactly the
//! points the set operation of the operands' exact windings holds. The
//! oracle reads both by even-odd ray casts at quarter-grid sample points,
//! exact in integers, never through the engine. Also: the eight symmetries
//! of the grid about the origin (rounding a half away from zero is
//! symmetric), shapes that do not cross merging to themselves, and
//! hand-derived crossings.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const testgen = @import("testgen");
const prop = testgen.prop;
const Rng = testgen.Rng;
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const Shape = fx.Shape;
const ValidatedLayer = geom.ValidatedLayer;

/// Operands live in `[-side, side]²`.
const side = 24;
const Ring = []const [2]i64;
const Map = *const fn ([2]i64) [2]i64;
const kinds = [_]fx.Kind{ .@"or", .@"and", .not };

// ---- private ----

/// A star-shaped polygon round a centre, its 3 to 7 vertices at distinct
/// angles: simple, at any angle, counter-clockwise.
fn randomStar(arena: Allocator, rng: *Rng) Allocator.Error!Ring {
    while (true) {
        const cx = rng.range(-side / 2, side / 2);
        const cy = rng.range(-side / 2, side / 2);
        const n = rng.range(3, 8);
        var pts: std.ArrayList([2]i64) = .empty;
        for (0..@intCast(n)) |_| {
            const x = rng.range(-side, side + 1);
            const p = [2]i64{ x, rng.range(-side, side + 1) };
            if (p[0] != cx or p[1] != cy) try pts.append(arena, p);
        }
        // By angle round the centre, exactly: half-plane, then cross product.
        const Ctx = struct { cx: i64, cy: i64 };
        const ctx: Ctx = .{ .cx = cx, .cy = cy };
        const S = struct {
            fn half(c: Ctx, p: [2]i64) bool {
                return p[1] < c.cy or (p[1] == c.cy and p[0] < c.cx);
            }
            fn turn(c: Ctx, p: [2]i64, q: [2]i64) i64 {
                return (p[0] - c.cx) * (q[1] - c.cy) - (p[1] - c.cy) * (q[0] - c.cx);
            }
            fn lessThan(c: Ctx, p: [2]i64, q: [2]i64) bool {
                if (half(c, p) != half(c, q)) return !half(c, p);
                return turn(c, p, q) > 0;
            }
        };
        std.mem.sort([2]i64, pts.items, ctx, S.lessThan);
        const k = pts.items.len;
        var ok = k >= 3;
        for (0..k) |i| {
            const p = pts.items[i];
            const q = pts.items[(i + 1) % k];
            // Distinct angles, and the centre strictly inside: every turn
            // round it under 180 degrees.
            if (i + 1 < k and S.turn(ctx, p, q) == 0 and S.half(ctx, p) == S.half(ctx, q)) ok = false;
            if (S.turn(ctx, p, q) <= 0) ok = false;
        }
        if (ok) return pts.items;
    }
}

fn generate(arena: Allocator, rng: *Rng) Allocator.Error![]const Shape {
    var list: std.ArrayList(Shape) = .empty;
    for (0..2) |layer| {
        const count = rng.range(1, 4);
        for (0..@intCast(count)) |_| try list.append(arena, .{ .layer = @intCast(layer), .pts = try randomStar(arena, rng) });
    }
    return list.items;
}

fn shrink(arena: Allocator, shapes: []const Shape) Allocator.Error![]const []const Shape {
    return fx.dropOne(Shape, arena, shapes, false);
}

fn validatedAny(store: *const geom.GeometryStore, l: u16) !ValidatedLayer {
    return fx.validated(store, l, .any);
}

/// Even-odd: is `(px, py) / 4` inside the ring (at unit scale)? It lies on
/// no edge.
fn inside4(ring: Ring, px: i64, py: i64) bool {
    var odd = false;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        const ax = 4 * p[0];
        const ay = 4 * p[1];
        const bx = 4 * q[0];
        const by = 4 * q[1];
        if ((ay > py) != (by > py)) {
            const s = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
            if ((s > 0) == (by > ay)) odd = !odd;
        }
    }
    return odd;
}

/// Whether the segment `a`-`b` meets the closed box `[x0, x1] x [y0, y1]`,
/// all at one scale: Liang-Barsky clipping with rational parameters.
fn meetsBox(a: [2]i64, b: [2]i64, x0: i64, x1: i64, y0: i64, y1: i64) bool {
    var lo = [2]i128{ 0, 1 };
    var hi = [2]i128{ 1, 1 };
    for ([2][4]i64{ .{ a[0], b[0], x0, x1 }, .{ a[1], b[1], y0, y1 } }) |axis| {
        const d: i128 = axis[1] - axis[0];
        const s: i128 = axis[0];
        const min: i128 = axis[2];
        const max: i128 = axis[3];
        if (d == 0) {
            if (s < min or s > max) return false;
            continue;
        }
        const enter: [2]i128 = if (d > 0) .{ min - s, d } else .{ s - max, -d };
        const leave: [2]i128 = if (d > 0) .{ max - s, d } else .{ s - min, -d };
        if (enter[0] * lo[1] > lo[0] * enter[1]) lo = enter;
        if (leave[0] * hi[1] < hi[0] * leave[1]) hi = leave;
    }
    return lo[0] * hi[1] <= hi[0] * lo[1];
}

fn ringsOf(arena: Allocator, l: *const ValidatedLayer) ![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            const pts = try arena.alloc([2]i64, r.xs.len);
            for (pts, r.xs, r.ys) |*q, x, y| q.* = .{ x, y };
            try out.append(arena, pts);
        }
    }
    return out.items;
}

fn opOf(kind: fx.Kind, p: bool, q: bool) bool {
    return switch (kind) {
        .@"or" => p or q,
        .@"and" => p and q,
        .not => p and !q,
    };
}

/// The result agrees with the exact set operation at every quarter-grid point
/// farther than half a unit, along some axis, from every operand edge.
fn agrees(arena: Allocator, why: *prop.Why, got: *const ValidatedLayer, a: []const Ring, b: []const Ring, kind: fx.Kind) !void {
    var edges: std.ArrayList([2][2]i64) = .empty;
    for ([2][]const Ring{ a, b }) |rs| for (rs) |r| for (r, 0..) |p, i| {
        const q = r[(i + 1) % r.len];
        try edges.append(arena, .{ .{ 4 * p[0], 4 * p[1] }, .{ 4 * q[0], 4 * q[1] } });
    };
    const result = try ringsOf(arena, got);
    var checked: usize = 0;
    var py: i64 = -4 * side - 4;
    while (py <= 4 * side + 4) : (py += 3) {
        var px: i64 = -4 * side - 4;
        while (px <= 4 * side + 4) : (px += 3) {
            var near = false;
            for (edges.items) |e| near = near or meetsBox(e[0], e[1], px - 2, px + 2, py - 2, py + 2);
            if (near) continue;
            checked += 1;
            var in_a = false;
            for (a) |r| in_a = in_a or inside4(r, px, py);
            var in_b = false;
            for (b) |r| in_b = in_b or inside4(r, px, py);
            var count: usize = 0;
            for (result) |r| count += @intFromBool(inside4(r, px, py));
            const want = opOf(kind, in_a, in_b);
            if (want != (count % 2 == 1)) return why.fail("{s}: at ({d}, {d})/4 the result says {}, the operands {}", .{ @tagName(kind), px, py, count % 2 == 1, want });
        }
    }
    if (checked == 0) return why.fail("{s}: no sample point clear of the edges", .{@tagName(kind)});
}

fn ringsOfLayer(arena: Allocator, shapes: []const Shape, layer: u16) ![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    for (shapes) |s| if (s.layer == layer) try out.append(arena, s.pts);
    return out.items;
}

fn property(arena: Allocator, shapes: []const Shape, why: *prop.Why) anyerror!void {
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    try fx.storeOfShapes(shapes, 2, &store);
    var a = try validatedAny(&store, 0);
    defer a.deinit(gpa);
    var b = try validatedAny(&store, 1);
    defer b.deinit(gpa);
    const ra = try ringsOfLayer(arena, shapes, 0);
    const rb = try ringsOfLayer(arena, shapes, 1);
    for (kinds) |kind| {
        var got = try fx.run(kind, &a, &b);
        defer got.deinit(gpa);
        try agrees(arena, why, &got, ra, rb, kind);
        var back = try fx.run(kind, &b, &a);
        defer back.deinit(gpa);
        try agrees(arena, why, &back, rb, ra, kind);
    }
}

/// The symmetry `t` of the grid about the origin.
fn symmetry(comptime t: usize) Map {
    return struct {
        fn f(p: [2]i64) [2]i64 {
            var x = p[0];
            var y = p[1];
            if (t & 4 != 0) std.mem.swap(i64, &x, &y);
            return .{ if (t & 1 == 0) x else -x, if (t & 2 == 0) y else -y };
        }
    }.f;
}

fn mirrors(t: usize) bool {
    return ((t & 1 != 0) != (t & 2 != 0)) != (t & 4 != 0);
}

fn identity(p: [2]i64) [2]i64 {
    return p;
}

fn symmetric(arena: Allocator, shapes: []const Shape, why: *prop.Why) anyerror!void {
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    try fx.storeOfShapes(shapes, 2, &store);
    var a = try validatedAny(&store, 0);
    defer a.deinit(gpa);
    var b = try validatedAny(&store, 1);
    defer b.deinit(gpa);
    inline for (1..8) |t| {
        const image = try arena.alloc(Shape, shapes.len);
        for (image, shapes) |*o, s| {
            const pts = try arena.alloc([2]i64, s.pts.len);
            for (pts, s.pts) |*q, p| q.* = symmetry(t)(p);
            if (mirrors(t)) std.mem.reverse([2]i64, pts);
            o.* = .{ .layer = s.layer, .pts = pts };
        }
        var image_store: geom.GeometryStore = .empty;
        defer image_store.deinit(gpa);
        try fx.storeOfShapes(image, 2, &image_store);
        var ta = try validatedAny(&image_store, 0);
        defer ta.deinit(gpa);
        var tb = try validatedAny(&image_store, 1);
        defer tb.deinit(gpa);
        for (kinds) |kind| {
            var here_l = try fx.run(kind, &a, &b);
            defer here_l.deinit(gpa);
            var there_l = try fx.run(kind, &ta, &tb);
            defer there_l.deinit(gpa);
            var here = try fx.edgeSet(&here_l, symmetry(t), mirrors(t));
            defer here.deinit(gpa);
            var there = try fx.edgeSet(&there_l, identity, false);
            defer there.deinit(gpa);
            if (!std.mem.eql(i64, @ptrCast(here.items), @ptrCast(there.items))) return why.fail("{s} under symmetry {d}", .{ @tagName(kind), t });
        }
    }
}

fn expectSameEdges(a: *const ValidatedLayer, b: *const ValidatedLayer) !void {
    var ea = try fx.edgeSet(a, identity, false);
    defer ea.deinit(gpa);
    var eb = try fx.edgeSet(b, identity, false);
    defer eb.deinit(gpa);
    try testing.expectEqualSlices(fx.DirEdge, eb.items, ea.items);
}

test "any angle booleans agree with the exact operation away from the rounding" {
    // Oracle: the brute-force winding reference in the module doc, over 150
    // named seeds of one to three random any-angle stars per operand.
    try prop.check(gpa, []const Shape, "any_angle_booleans_agree_with_the_exact_operation_away_from_the_rounding", 150, &.{}, generate, shrink, property);
}

test "any angle booleans commute with the grid symmetries" {
    // Oracle: metamorphic, the eight grid symmetries, over 100 named seeds.
    try prop.check(gpa, []const Shape, "any_angle_booleans_commute_with_the_grid_symmetries", 100, &.{}, generate, shrink, symmetric);
}

test "a crossing between grid points rounds to the nearest one" {
    // Oracle: hand-derived. `A` = (0,0),(10,0),(0,3) and `B` = (0,0),(10,0),
    // (10,3). The crossing rounds a half away from zero to (5, 2), and both
    // slanted sides pass its pixel `[4.5, 5.5) x [1.5, 2.5)` at x = 5, so both
    // bend through it: A and B is the triangle (0,0),(10,0),(5,2), area 10
    // (exactly 7.5 unrounded); A or B is 30 less the notch (0,3),(5,2),(10,3)
    // of area 5, so 25; A not B is (0,0),(5,2),(0,3), area 7.5.
    var a = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 3 } }}, .any, false);
    defer a.deinit(gpa);
    var b = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 3 } }}, .any, false);
    defer b.deinit(gpa);
    var want = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 2 } }}, .any, false);
    defer want.deinit(gpa);
    var meet = try fx.run(.@"and", &a, &b);
    defer meet.deinit(gpa);
    try expectSameEdges(&meet, &want);
    try testing.expectEqual(@as(i128, 20), fx.twiceArea(&meet));
    var join = try fx.run(.@"or", &a, &b);
    defer join.deinit(gpa);
    try testing.expectEqual(@as(i128, 50), fx.twiceArea(&join));
    var diff = try fx.run(.not, &a, &b);
    defer diff.deinit(gpa);
    try testing.expectEqual(@as(i128, 15), fx.twiceArea(&diff));
}

test "shapes that cross nothing merge to themselves" {
    // Oracle: construct-from-answer; the drawn rings are the answer: no
    // crossing, so nothing is rounded and no edge bends.
    var layer = try fx.layerOf(&.{ &.{ .{ 0, 0 }, .{ 7, 2 }, .{ 3, 9 } }, &.{ .{ 20, 0 }, .{ 31, 5 }, .{ 26, 13 }, .{ 19, 6 } } }, .any, false);
    defer layer.deinit(gpa);
    var merged = try fx.run(.@"or", &layer, &.empty);
    defer merged.deinit(gpa);
    try expectSameEdges(&merged, &layer);
}

test "a bent edge attracts the vertices in its pixels" {
    // Oracle: hand-derived. `A` = (0,0),(20,0),(20,1),(0,1) and the triangle
    // (2,-3),(3,-3),(10,4) of `B` cross between grid points, and the vertex
    // (9, 2) of `B`'s second triangle (9,2),(12,2),(9,5) lies within a unit of
    // the bent slanted side. The result must stay valid and agree with the
    // operation away from every edge (the module oracle), whatever bends.
    const ra: []const Ring = &.{&.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 1 }, .{ 0, 1 } }};
    const rb: []const Ring = &.{ &.{ .{ 2, -3 }, .{ 3, -3 }, .{ 10, 4 } }, &.{ .{ 9, 2 }, .{ 12, 2 }, .{ 9, 5 } } };
    var a = try fx.layerOf(ra, .any, false);
    defer a.deinit(gpa);
    var b = try fx.layerOf(rb, .any, false);
    defer b.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (kinds) |kind| {
        var got = try fx.run(kind, &a, &b);
        defer got.deinit(gpa);
        var why: prop.Why = .{};
        agrees(arena_state.allocator(), &why, &got, ra, rb, kind) catch |err| {
            std.debug.print("{s}\n", .{why.buf[0..why.len]});
            return err;
        };
    }
}
