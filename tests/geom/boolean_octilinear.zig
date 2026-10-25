//! The booleans on octilinear operands: edges at 0, 45 and 90 degrees.
//! Ported from crates/geom/tests/core/boolean_octilinear.rs.
//!
//! The oracle is exact and independent of the sweep. On the integer grid
//! every line an octilinear edge can lie on is a side or a diagonal of a unit
//! cell, so each cell splits into four quarter triangles (bottom, right, top,
//! left, meeting at the centre), and every operand and result is constant on
//! each open quarter triangle. The oracle reads each operand inside each
//! quarter triangle, applies the set operation triangle by triangle, then the
//! snapping rule `boolean.unionInto` states: a lone triangle that differs from
//! the other three (a right-angled corner at the centre) takes their value,
//! and two opposite triangles of material with the other two empty (a pinch)
//! fill the cell. The engine's result is read at the same points.
//!
//! Oracle: the quarter-triangle exact reference above, the snapping rule as
//! `boolean::union_into` documents it, the eight symmetries of the grid, the
//! 45-degree rotation law, and hand-derived configurations.

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

const side = fx.oct_side;
/// Per cell, its four quarter triangles (bottom, right, top, left).
const Cells = [side * side][4]bool;
const Map = *const fn ([2]i64) [2]i64;

/// Each polygon's outer ring, rotated to start at its least vertex, and its
/// area doubled.
const Figure = struct { ring: [][2]i64, doubled: i128 };

// ---- private ----

/// One to four shapes on each of three layers.
fn generate(arena: Allocator, rng: *Rng) Allocator.Error![]const Shape {
    var list: std.ArrayList(Shape) = .empty;
    for (0..3) |layer| {
        const count = rng.range(1, 5);
        for (0..@intCast(count)) |_| try list.append(arena, .{ .layer = @intCast(layer), .pts = try fx.randomOctShape(arena, rng) });
    }
    return list.items;
}

fn shrink(arena: Allocator, shapes: []const Shape) Allocator.Error![]const []const Shape {
    return fx.dropOne(Shape, arena, shapes, false);
}

/// Even-odd: is the point inside the closed ring? It lies on no edge; every
/// coordinate is at one scale.
fn inside(ring: []const [2]i64, px: i64, py: i64) bool {
    var odd = false;
    for (ring, 0..) |a, i| {
        const b = ring[(i + 1) % ring.len];
        if ((a[1] > py) != (b[1] > py)) {
            const s = (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]);
            if ((s > 0) == (b[1] > a[1])) odd = !odd;
        }
    }
    return odd;
}

/// The probe inside each quarter triangle of cell `(i, j)`, at four times
/// scale.
fn probes(i: usize, j: usize) [4][2]i64 {
    const x: i64 = @intCast(4 * i);
    const y: i64 = @intCast(4 * j);
    return .{ .{ x + 2, y + 1 }, .{ x + 3, y + 2 }, .{ x + 2, y + 3 }, .{ x + 1, y + 2 } };
}

/// Each quarter triangle of a layer: inside an odd number of its rings
/// (outer, hole and island alike), read at `map` of the probe.
fn sampled(l: *const ValidatedLayer, map: Map) !Cells {
    var rings: std.ArrayList([]const [2]i64) = .empty;
    defer {
        for (rings.items) |r| gpa.free(r);
        rings.deinit(gpa);
    }
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            const pts = try gpa.alloc([2]i64, r.xs.len);
            for (pts, r.xs, r.ys) |*q, x, y| q.* = .{ 4 * x, 4 * y };
            try rings.append(gpa, pts);
        }
    }
    var out: Cells = undefined;
    for (0..side) |j| for (0..side) |i| {
        for (probes(i, j), 0..) |probe, t| {
            const q = map(probe);
            var count: usize = 0;
            for (rings.items) |r| count += @intFromBool(inside(r, q[0], q[1]));
            out[j * side + i][t] = count % 2 == 1;
        }
    };
    return out;
}

/// Each quarter triangle of the drawn shapes on `layer`: inside any of them.
fn drawn(shapes: []const Shape, layer: u16) !Cells {
    var out: Cells = undefined;
    for (0..side) |j| for (0..side) |i| {
        for (probes(i, j), 0..) |probe, t| {
            var any = false;
            for (shapes) |s| {
                if (s.layer != layer) continue;
                var ring: [8][2]i64 = undefined;
                for (s.pts, 0..) |p, k| ring[k] = .{ 4 * p[0], 4 * p[1] };
                any = any or inside(ring[0..s.pts.len], probe[0], probe[1]);
            }
            out[j * side + i][t] = any;
        }
    };
    return out;
}

/// The set operation triangle by triangle, exact (no snapping).
fn exact(a: Cells, b: Cells, kind: fx.Kind) Cells {
    var out: Cells = undefined;
    for (&out, a, b) |*o, p, q| {
        for (o, p, q) |*t, x, y| t.* = switch (kind) {
            .@"or" => x or y,
            .@"and" => x and y,
            .not => x and !y,
        };
    }
    return out;
}

/// The snapping rule of `boolean.unionInto`, cell by cell.
fn snapped(cells: Cells) Cells {
    var out = cells;
    for (&out) |*t| {
        const filled = @as(u8, @intFromBool(t[0])) + @intFromBool(t[1]) + @intFromBool(t[2]) + @intFromBool(t[3]);
        switch (filled) {
            // A right-angled corner at the centre: the odd one takes the others' value.
            1, 3 => t.* = @splat(filled == 3),
            // Opposite triangles alike: material in two opposite sectors, a pinch.
            2 => if (t[0] == t[2]) {
                t.* = @splat(true);
            },
            else => {},
        }
    }
    return out;
}

fn compare(why: *prop.Why, name: []const u8, got: Cells, want: Cells) !void {
    for (got, want, 0..) |g, w, i| {
        if (!std.mem.eql(bool, &g, &w)) return why.fail("{s}: cell ({d}, {d}) has triangles {any} in the result and {any} in the oracle", .{ name, i % side, i / side, g, w });
    }
}

fn identity(p: [2]i64) [2]i64 {
    return p;
}

fn validatedOct(store: *const geom.GeometryStore, l: u16) !ValidatedLayer {
    return fx.validated(store, l, .octilinear);
}

/// Every operation, each way round, and composed forms, against the oracle.
fn property(_: Allocator, shapes: []const Shape, why: *prop.Why) anyerror!void {
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    try fx.storeOfShapes(shapes, 3, &store);
    var a = try validatedOct(&store, 0);
    defer a.deinit(gpa);
    var b = try validatedOct(&store, 1);
    defer b.deinit(gpa);
    var c = try validatedOct(&store, 2);
    defer c.deinit(gpa);
    const ra = try drawn(shapes, 0);
    const rb = try drawn(shapes, 1);
    const rc = try drawn(shapes, 2);
    const cases = [_]struct { kind: fx.Kind, swap: bool }{
        .{ .kind = .@"or", .swap = false }, .{ .kind = .@"or", .swap = true }, .{ .kind = .@"and", .swap = false },
        .{ .kind = .not, .swap = false },   .{ .kind = .not, .swap = true },
    };
    for (cases) |cs| {
        var got = if (cs.swap) try fx.run(cs.kind, &b, &a) else try fx.run(cs.kind, &a, &b);
        defer got.deinit(gpa);
        const want = if (cs.swap) exact(rb, ra, cs.kind) else exact(ra, rb, cs.kind);
        try compare(why, @tagName(cs.kind), try sampled(&got, identity), snapped(want));
    }
    // Composed: each step snaps, in the oracle as in the engine.
    var b_or_c = try fx.run(.@"or", &b, &c);
    defer b_or_c.deinit(gpa);
    const rbc = snapped(exact(rb, rc, .@"or"));
    try compare(why, "B or C", try sampled(&b_or_c, identity), rbc);
    for ([_]fx.Kind{ .@"and", .not }) |kind| {
        var got = try fx.run(kind, &a, &b_or_c);
        defer got.deinit(gpa);
        try compare(why, "A op (B or C)", try sampled(&got, identity), snapped(exact(ra, rbc, kind)));
    }
    // A merge snaps nothing a drawn layer holds: its vertices are on the
    // grid and only crossings can fall between grid points.
    var merged = try fx.run(.@"or", &a, &.empty);
    defer merged.deinit(gpa);
    try compare(why, "A merged", try sampled(&merged, identity), snapped(exact(ra, ra, .@"or")));
}

/// The symmetry `t` of `[0, side]²` at scale `k`: the identity, the mirrors
/// and the quarter turns.
fn symmetry(comptime t: usize, comptime k: i64) Map {
    return struct {
        fn f(p: [2]i64) [2]i64 {
            const s = k * side;
            var x = p[0];
            var y = p[1];
            if (t & 4 != 0) std.mem.swap(i64, &x, &y);
            if (t & 1 != 0) x = s - x;
            if (t & 2 != 0) y = s - y;
            return .{ x, y };
        }
    }.f;
}

/// Whether a symmetry reverses orientation: one mirror, or a swap of axes.
fn mirrors(t: usize) bool {
    return ((t & 1 != 0) != (t & 2 != 0)) != (t & 4 != 0);
}

/// The shapes moved by `map`, re-wound counter-clockwise when it mirrors.
fn moved(arena: Allocator, shapes: []const Shape, map: Map, mirror: bool) ![]const Shape {
    const out = try arena.alloc(Shape, shapes.len);
    for (out, shapes) |*o, s| {
        const pts = try arena.alloc([2]i64, s.pts.len);
        for (pts, s.pts) |*q, p| q.* = map(p);
        if (mirror) std.mem.reverse([2]i64, pts);
        o.* = .{ .layer = s.layer, .pts = pts };
    }
    return out;
}

/// Each operation commutes with every symmetry of the grid: the snapping
/// rule and the corner model treat every direction alike.
fn symmetric(arena: Allocator, shapes: []const Shape, why: *prop.Why) anyerror!void {
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    try fx.storeOfShapes(shapes, 3, &store);
    var a = try validatedOct(&store, 0);
    defer a.deinit(gpa);
    var b = try validatedOct(&store, 1);
    defer b.deinit(gpa);
    inline for (1..8) |t| {
        const image = try moved(arena, shapes, symmetry(t, 1), mirrors(t));
        var image_store: geom.GeometryStore = .empty;
        defer image_store.deinit(gpa);
        try fx.storeOfShapes(image, 3, &image_store);
        var ta = try validatedOct(&image_store, 0);
        defer ta.deinit(gpa);
        var tb = try validatedOct(&image_store, 1);
        defer tb.deinit(gpa);
        for ([_]fx.Kind{ .@"or", .@"and", .not }) |kind| {
            var here = try fx.run(kind, &a, &b);
            defer here.deinit(gpa);
            var there = try fx.run(kind, &ta, &tb);
            defer there.deinit(gpa);
            try compare(why, "under a symmetry", try sampled(&there, symmetry(t, 4)), try sampled(&here, identity));
        }
    }
}

fn turn(p: [2]i64) [2]i64 {
    return .{ p[0] - p[1], p[0] + p[1] };
}

/// The 45-degree rotation law. `(x, y) → (x − y, x + y)` turns every
/// octilinear direction into another and takes every half-grid point onto the
/// grid, so the rotated operation snaps nothing: read at the rotated probes it
/// is the exact operation, triangle by triangle.
fn rotated(arena: Allocator, shapes: []const Shape, why: *prop.Why) anyerror!void {
    const image = try moved(arena, shapes, turn, false);
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    try fx.storeOfShapes(image, 3, &store);
    var a = try validatedOct(&store, 0);
    defer a.deinit(gpa);
    var b = try validatedOct(&store, 1);
    defer b.deinit(gpa);
    const ra = try drawn(shapes, 0);
    const rb = try drawn(shapes, 1);
    for ([_]fx.Kind{ .@"or", .@"and", .not }) |kind| {
        var got = try fx.run(kind, &a, &b);
        defer got.deinit(gpa);
        try compare(why, "turned 45 degrees", try sampled(&got, turn), exact(ra, rb, kind));
    }
}

fn figures(l: *const ValidatedLayer, out: *std.ArrayList(Figure)) !void {
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        const r = p.outer();
        const ring = try gpa.alloc([2]i64, r.xs.len);
        var least: usize = 0;
        for (ring, r.xs, r.ys, 0..) |*q, x, y, k| {
            q.* = .{ x, y };
            if (x < r.xs[least] or (x == r.xs[least] and y < r.ys[least])) least = k;
        }
        std.mem.rotate([2]i64, ring, least);
        var doubled: i128 = 0;
        for (0..p.ringCount()) |k| {
            const rk = p.ring(@intCast(k));
            doubled += geom.ops.area2(rk.xs, rk.ys);
        }
        try out.append(gpa, .{ .ring = ring, .doubled = doubled });
    }
}

fn freeFigures(list: *std.ArrayList(Figure)) void {
    for (list.items) |f| gpa.free(f.ring);
    list.deinit(gpa);
}

fn expectRing(want: []const [2]i64, got: []const [2]i64) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqual(w, g);
}

test "every octilinear boolean is its quarter triangle reference" {
    // Oracle: the quarter-triangle exact reference and the snapping rule in the
    // module doc, over 100 named seeds and the committed regressions.
    try prop.check(gpa, []const Shape, "boolean_octilinear", 100, &.{}, generate, shrink, property);
}

test "octilinear booleans commute with the symmetries of the grid" {
    // Oracle: the symmetry law in `symmetric`: the eight symmetries of the grid
    // commute with every operation, over 25 named seeds.
    try prop.check(gpa, []const Shape, "boolean_octilinear_symmetry", 25, &.{}, generate, shrink, symmetric);
}

test "an operation turned 45 degrees is the exact operation" {
    // Oracle: the 45-degree rotation law in `rotated`, against the exact
    // quarter-triangle reference, over 50 named seeds.
    try prop.check(gpa, []const Shape, "boolean_octilinear_turn", 50, &.{}, generate, shrink, rotated);
}

test "a convex corner between grid points is cut to a unit edge" {
    // Oracle: hand-derived. `x ≥ 0, y ≥ x, x + y ≤ 3` is the triangle (0, 0),
    // (1.5, 1.5), (0, 3) of area 2.25; its apex is a convex right angle at a
    // half-grid point, so the snap cuts the tip at (1, 1)-(1, 2): area 2.
    var a = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 3, 0 }, .{ 0, 3 } }}, .octilinear, false);
    defer a.deinit(gpa);
    var b = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 3, 3 }, .{ 0, 3 } }}, .octilinear, false);
    defer b.deinit(gpa);
    var got = try fx.run(.@"and", &a, &b);
    defer got.deinit(gpa);
    var figs: std.ArrayList(Figure) = .empty;
    defer freeFigures(&figs);
    try figures(&got, &figs);
    try testing.expectEqual(@as(usize, 1), figs.items.len);
    try expectRing(&.{ .{ 0, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 3 } }, figs.items[0].ring);
    // 2.25 less the quarter-unit tip, doubled.
    try testing.expectEqual(@as(i128, 4), figs.items[0].doubled);
    try testing.expect(!got.isRectilinear());
}

test "a concave corner between grid points is filled to a unit edge" {
    // Oracle: hand-derived. The two triangles' union has a concave right angle
    // at (1.5, 1.5): exact area 4.5 + 4.5 - 2.25 = 6.75, and the snap fills the
    // tip of the empty sector at (2, 2)-(1, 2): area 7.
    var a = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 3, 0 }, .{ 0, 3 } }}, .octilinear, false);
    defer a.deinit(gpa);
    var b = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 } }}, .octilinear, false);
    defer b.deinit(gpa);
    var got = try fx.run(.@"or", &a, &b);
    defer got.deinit(gpa);
    var figs: std.ArrayList(Figure) = .empty;
    defer freeFigures(&figs);
    try figures(&got, &figs);
    try testing.expectEqual(@as(usize, 1), figs.items.len);
    try expectRing(&.{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 }, .{ 2, 2 }, .{ 1, 2 }, .{ 0, 3 } }, figs.items[0].ring);
    try testing.expectEqual(@as(i128, 14), figs.items[0].doubled);
}

test "a pinch between grid points becomes a unit neck" {
    // Oracle: hand-derived, and the connected corner model. Each operand is two
    // overlapping triangles that together miss one sector at (1.5, 1.5); their
    // intersection is the left and right sectors, meeting only at that point,
    // exact area 4.5. Connected, they are one figure, and the snap fills the
    // tips of both empty sectors: a neck one unit wide, area 5.
    var a = try fx.layerOf(&.{ &.{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 } }, &.{ .{ 0, 0 }, .{ 3, 0 }, .{ 0, 3 } } }, .octilinear, false);
    defer a.deinit(gpa);
    var b = try fx.layerOf(&.{ &.{ .{ 0, 0 }, .{ 3, 3 }, .{ 0, 3 } }, &.{ .{ 3, 0 }, .{ 3, 3 }, .{ 0, 3 } } }, .octilinear, false);
    defer b.deinit(gpa);
    var got = try fx.run(.@"and", &a, &b);
    defer got.deinit(gpa);
    var figs: std.ArrayList(Figure) = .empty;
    defer freeFigures(&figs);
    try figures(&got, &figs);
    // Material meeting at a point is one figure.
    try testing.expectEqual(@as(usize, 1), figs.items.len);
    try expectRing(&.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 1 }, .{ 3, 0 }, .{ 3, 3 }, .{ 2, 2 }, .{ 1, 2 }, .{ 0, 3 } }, figs.items[0].ring);
    try testing.expectEqual(@as(i128, 10), figs.items[0].doubled);
}

test "a diamond touching an edge at its vertex joins it" {
    // Oracle: the connected corner model at 45 degrees, hand-derived: a diamond
    // whose bottom vertex touches the middle of a square's top edge is one
    // figure, its ring passing the touch point twice; area 100 + 50.
    var square = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }}, .octilinear, false);
    defer square.deinit(gpa);
    var diamond = try fx.layerOf(&.{&.{ .{ 5, 10 }, .{ 10, 15 }, .{ 5, 20 }, .{ 0, 15 } }}, .octilinear, false);
    defer diamond.deinit(gpa);
    var got = try fx.run(.@"or", &square, &diamond);
    defer got.deinit(gpa);
    var figs: std.ArrayList(Figure) = .empty;
    defer freeFigures(&figs);
    try figures(&got, &figs);
    try testing.expectEqual(@as(usize, 1), figs.items.len);
    try testing.expectEqual(@as(i128, 2 * (100 + 50)), figs.items[0].doubled);
    var visits: usize = 0;
    for (figs.items[0].ring) |p| visits += @intFromBool(p[0] == 5 and p[1] == 10);
    try testing.expectEqual(@as(usize, 2), visits);
}

test "an octilinear keyhole decomposes into its outer and its hole" {
    // Oracle: hand-derived. A diamond of radius 10 with a 4-square hole, written
    // as one keyhole ring through a vertical slit, is its outer diamond (200)
    // and its hole (16), wound opposite ways.
    var out: geom.boolean.Rings = .{};
    defer out.deinit(gpa);
    // The outer from (0, -10), up the slit, the hole clockwise, back down.
    try geom.boolean.canonicalRingsInto(gpa, &.{ 0, 10, 0, -10, 0, 0, -2, -2, 2, 2, 0 }, &.{ -10, 0, 10, 0, -10, -2, -2, 2, 2, -2, -2 }, &out);
    try testing.expectEqual(@as(u32, 2), out.count());
    var signed: [2]i128 = undefined;
    for (&signed, 0..) |*s, k| s.* = geom.ops.area2(out.xs.items[out.start.items[k]..out.start.items[k + 1]], out.ys.items[out.start.items[k]..out.start.items[k + 1]]);
    std.mem.sort(i128, &signed, {}, std.sort.asc(i128));
    try testing.expectEqual([2]i128{ -2 * 16, 2 * 200 }, signed);
}
