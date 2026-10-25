//! The derived-layer operations on layers at any angle. Ported from
//! crates/geom/tests/core/derive_anyangle.rs.
//!
//! Oracle: the Pythagorean rotation law. `(x, y) → (3x − 4y, 4x + 3y)` maps
//! the grid into itself and every length times 5, and every line through two
//! grid points of a rectilinear layout onto one whose lattice points are the
//! images of its own, so on the images of random rectangles (edges along
//! (3, 4) and (−4, 3)) every operation must return the image of what it
//! returns on the rectangles, exactly: edges, edge booleans, edge parts,
//! selections, holes and areas (times 25). Nothing rounds, so any difference
//! is a defect of the any-angle path.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const testgen = @import("testgen");
const prop = testgen.prop;
const Rng = testgen.Rng;
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const derive = geom.derive;
const Seg = geom.Seg;
const ValidatedLayer = geom.ValidatedLayer;

const Ring = []const [2]i64;
const Case = [2][]const Ring;
const Map = *const fn ([2]i64) [2]i64;

// ---- private ----

fn turn(p: [2]i64) [2]i64 {
    return .{ 3 * p[0] - 4 * p[1], 4 * p[0] + 3 * p[1] };
}

fn identity(p: [2]i64) [2]i64 {
    return p;
}

fn rectangles(arena: Allocator, rng: *Rng) Allocator.Error![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    const n = rng.range(1, 5);
    for (0..@intCast(n)) |_| {
        const x = rng.range(-12, 10);
        const y = rng.range(-12, 10);
        const w = rng.range(1, 13 - x);
        const h = rng.range(1, 13 - y);
        try out.append(arena, try arena.dupe([2]i64, &.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } }));
    }
    return out.items;
}

fn generate(arena: Allocator, rng: *Rng) Allocator.Error!Case {
    const a = try rectangles(arena, rng);
    return .{ a, try rectangles(arena, rng) };
}

fn shrink(arena: Allocator, c: Case) Allocator.Error![]const Case {
    var out: std.ArrayList(Case) = .empty;
    for (try fx.dropOne(Ring, arena, c[0], false)) |fewer| try out.append(arena, .{ fewer, c[1] });
    for (try fx.dropOne(Ring, arena, c[1], false)) |fewer| try out.append(arena, .{ c[0], fewer });
    return out.items;
}

fn image(arena: Allocator, rings: []const Ring) ![]const Ring {
    const out = try arena.alloc(Ring, rings.len);
    for (out, rings) |*o, r| {
        const pts = try arena.alloc([2]i64, r.len);
        for (pts, r) |*q, p| q.* = turn(p);
        o.* = pts;
    }
    return out;
}

/// Segments through `map`, sorted.
fn segs(arena: Allocator, edges: []const Seg, map: Map) ![]const [4]i64 {
    const out = try arena.alloc([4]i64, edges.len);
    for (out, edges) |*o, s| {
        const a = map(.{ s.a.x, s.a.y });
        const b = map(.{ s.b.x, s.b.y });
        o.* = .{ a[0], a[1], b[0], b[1] };
    }
    std.mem.sort([4]i64, out, {}, struct {
        fn lessThan(_: void, p: [4]i64, q: [4]i64) bool {
            return std.mem.order(i64, &p, &q) == .lt;
        }
    }.lessThan);
    return out;
}

fn sameSegs(arena: Allocator, why: *prop.Why, what: []const u8, want: []const Seg, got: []const Seg) !void {
    const w = try segs(arena, want, turn);
    const g = try segs(arena, got, identity);
    if (w.len != g.len or !std.mem.eql(i64, @ptrCast(w), @ptrCast(g))) return why.fail("{s}: {any} turned, {any} computed", .{ what, w, g });
}

fn sameRings(why: *prop.Why, what: []const u8, want: *const ValidatedLayer, got: *const ValidatedLayer) !void {
    var w = try fx.edgeSet(want, turn, false);
    defer w.deinit(gpa);
    var g = try fx.edgeSet(got, identity, false);
    defer g.deinit(gpa);
    if (w.items.len != g.items.len or !std.mem.eql(i64, @ptrCast(w.items), @ptrCast(g.items))) return why.fail("{s}: rings differ", .{what});
}

fn commutes(arena: Allocator, c: Case, why: *prop.Why) anyerror!void {
    var a = try fx.layerOf(c[0], .any, true);
    defer a.deinit(gpa);
    var b = try fx.layerOf(c[1], .any, true);
    defer b.deinit(gpa);
    var ta = try fx.layerOf(try image(arena, c[0]), .any, true);
    defer ta.deinit(gpa);
    var tb = try fx.layerOf(try image(arena, c[1]), .any, true);
    defer tb.deinit(gpa);

    var ea: std.ArrayList(Seg) = .empty;
    defer ea.deinit(gpa);
    var eb: std.ArrayList(Seg) = .empty;
    defer eb.deinit(gpa);
    var tea: std.ArrayList(Seg) = .empty;
    defer tea.deinit(gpa);
    var teb: std.ArrayList(Seg) = .empty;
    defer teb.deinit(gpa);
    try derive.edgesInto(gpa, &a, &ea);
    try derive.edgesInto(gpa, &b, &eb);
    try derive.edgesInto(gpa, &ta, &tea);
    try derive.edgesInto(gpa, &tb, &teb);
    try sameSegs(arena, why, "edges", ea.items, tea.items);

    var x: std.ArrayList(Seg) = .empty;
    defer x.deinit(gpa);
    var tx: std.ArrayList(Seg) = .empty;
    defer tx.deinit(gpa);
    for ([_]derive.EdgeOp{ .@"and", .not, .@"or" }) |op| {
        try derive.edgeBooleanInto(gpa, ea.items, eb.items, op, &x);
        try derive.edgeBooleanInto(gpa, tea.items, teb.items, op, &tx);
        try sameSegs(arena, why, "edge boolean", x.items, tx.items);
    }
    for ([_]bool{ true, false }) |inside| {
        try derive.edgePartInto(gpa, ea.items, &b, inside, &x);
        try derive.edgePartInto(gpa, tea.items, &tb, inside, &tx);
        try sameSegs(arena, why, "edge part", x.items, tx.items);
    }
    for ([_]bool{ true, false }) |keep| {
        try derive.edgeInteractingInto(gpa, ea.items, &b, keep, &x);
        try derive.edgeInteractingInto(gpa, tea.items, &tb, keep, &tx);
        try sameSegs(arena, why, "edge interacting", x.items, tx.items);
    }
    // A side k units long turns into one 5k long.
    try derive.withLengthInto(gpa, ea.items, 3, 8, &x);
    try derive.withLengthInto(gpa, tea.items, 15, 40, &tx);
    try sameSegs(arena, why, "with_length", x.items, tx.items);

    var s: ValidatedLayer = .empty;
    defer s.deinit(gpa);
    var ts: ValidatedLayer = .empty;
    defer ts.deinit(gpa);
    for ([_]bool{ true, false }) |keep| {
        try derive.interactingInto(gpa, &a, &b, keep, &s);
        try derive.interactingInto(gpa, &ta, &tb, keep, &ts);
        try sameRings(why, "interacting", &s, &ts);
        try derive.overlappingInto(gpa, &a, &b, keep, &s);
        try derive.overlappingInto(gpa, &ta, &tb, keep, &ts);
        try sameRings(why, "overlapping", &s, &ts);
        try derive.coveringInto(gpa, &a, &b, keep, &s);
        try derive.coveringInto(gpa, &ta, &tb, keep, &ts);
        try sameRings(why, "covering", &s, &ts);
    }
    try derive.insideInto(gpa, &a, &b, &s);
    try derive.insideInto(gpa, &ta, &tb, &ts);
    try sameRings(why, "inside", &s, &ts);
    try derive.holesInto(gpa, &a, &s);
    try derive.holesInto(gpa, &ta, &ts);
    try sameRings(why, "holes", &s, &ts);
    try derive.withAreaInto(gpa, &a, 20, 150, &s);
    try derive.withAreaInto(gpa, &ta, 500, 3750, &ts);
    try sameRings(why, "with_area", &s, &ts);
}

test "derived layers commute with a pythagorean turn" {
    // Oracle: the Pythagorean rotation law in the module doc, over 200 named
    // seeds of one to four rectangles on each of two layers.
    try prop.check(gpa, Case, "derive_anyangle_turn", 200, &.{}, generate, shrink, commutes);
}

test "a part of a slanted edge ends on its lattice" {
    // Oracle: hand-derived. The edge (0,0)→(9,3) runs on the lattice
    // (3k, k); the square (4,-5),(10,-5),(10,5),(4,5) crosses it at x = 4,
    // between the lattice points (3,1) and (6,2), so the part inside is
    // (6,2)→(9,3) and the part outside (0,0)→(3,1).
    const edge = [_]Seg{.{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 9, .y = 3 } }};
    var square = try fx.layerOf(&.{&.{ .{ 4, -5 }, .{ 10, -5 }, .{ 10, 5 }, .{ 4, 5 } }}, .any, true);
    defer square.deinit(gpa);
    var out: std.ArrayList(Seg) = .empty;
    defer out.deinit(gpa);
    try derive.edgePartInto(gpa, &edge, &square, true, &out);
    try testing.expectEqualSlices(Seg, &.{.{ .a = .{ .x = 6, .y = 2 }, .b = .{ .x = 9, .y = 3 } }}, out.items);
    try derive.edgePartInto(gpa, &edge, &square, false, &out);
    try testing.expectEqualSlices(Seg, &.{.{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 3, .y = 1 } }}, out.items);
}
