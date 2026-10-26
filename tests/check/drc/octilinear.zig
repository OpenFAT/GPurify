//! The DRC kinds proved on 45-degree geometry (H12, DRC-038) on base
//! layers: deck text, polygons on `met1` and `met2`, and the DRC rule set.
//! Ported from crates/check/tests/drc/octilinear.rs.
//!
//! Oracle throughout: construct-from-answer on a 1 nm grid, each measurement
//! read off the coordinates by hand, each rule passing exactly at its
//! measurement and failing one unit above it. The shape a plausible wrong
//! implementation gets wrong is drawn on purpose: a 45-degree gap of `7/√2`
//! (`√24.5`, so 4.95), which a squared distance rounded up to 25 passes at a
//! limit of 5; IHP SG13G2 M1.g/M1.i are the foundry rules these measure.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;
const Measurement = check.report.Measurement;
const Outcome = check.report.Outcome;
const Layout = common.Layout;
const Finding = common.Finding;

/// A ring on a named layer.
const Ring = struct { layer: []const u8, points: []const [2]i64 };

/// A run's rows, with lookups by rule; owns everything.
const Found = struct {
    run: common.Run,

    fn deinit(f: *Found) void {
        f.run.deinit();
    }

    /// The rule's findings as `(measured, limit)`.
    fn of(f: *Found, rule: []const u8) ![]const [2]Measurement {
        const row = f.run.row(rule);
        const out = try f.run.arena.allocator().alloc([2]Measurement, row.findings.len);
        for (out, row.findings) |*o, x| o.* = .{ x.measured, x.limit };
        return out;
    }

    fn outcome(f: *const Found, rule: []const u8) Outcome {
        return f.run.row(rule).outcome;
    }

    /// Every finding and outcome as sorted text.
    fn summary(f: *Found) ![]const []const u8 {
        const al = f.run.arena.allocator();
        var all: std.ArrayList([]const u8) = .empty;
        for (f.run.rows) |row| {
            try all.append(al, try std.fmt.allocPrint(al, "{s} {any}", .{ row.id, row.outcome }));
            for (row.findings) |x| try all.append(al, try std.fmt.allocPrint(al, "{s} {t} {d} {t} {d}", .{ row.id, x.measured.kind, x.measured.raw, x.limit.kind, x.limit.raw }));
        }
        std.mem.sort([]const u8, all.items, {}, lessText);
        return all.items;
    }
};

/// The U with arms 100 wide, a base 50 tall and a slot 100 wide.
const u_shape = [8][2]i64{ .{ 0, 0 }, .{ 300, 0 }, .{ 300, 200 }, .{ 200, 200 }, .{ 200, 50 }, .{ 100, 50 }, .{ 100, 200 }, .{ 0, 200 } };

/// A 100-square on met2 with every corner chamfered by 30: a host whose
/// 45-degree edges lie on `x + y = 30`, `x - y = 70`, `x + y = 170` and
/// `y - x = 70`.
const octagon_host: Ring = .{ .layer = "met2", .points = &.{ .{ 30, 0 }, .{ 70, 0 }, .{ 100, 30 }, .{ 100, 70 }, .{ 70, 100 }, .{ 30, 100 }, .{ 0, 70 }, .{ 0, 30 } } };

// ---- private ----

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn len(v: i64) Measurement {
    return .length(v);
}

fn area(v: i128) Measurement {
    return .area(v);
}

fn layoutOf(rings: []const Ring) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    for (rings) |r| try l.polygon(r.layer, r.points);
    return l;
}

/// Parse `rules` under `met1`, `met2` and `region`, draw `layout`, and run.
fn runLayout(rules: []const u8, layout: *const Layout) !Found {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    return .{ .run = try common.run(try common.deck(arena.allocator(), rules), layout) };
}

fn runOn(rules: []const u8, rings: []const Ring) !Found {
    var layout = try layoutOf(rings);
    defer layout.deinit();
    return runLayout(rules, &layout);
}

/// [`runOn`] with every ring on `met1`.
fn run(rules: []const u8, rings: []const []const [2]i64) !Found {
    var layout: Layout = .{};
    defer layout.deinit();
    for (rings) |r| try layout.polygon("met1", r);
    return runLayout(rules, &layout);
}

fn expectFindings(want: []const [2]Measurement, got: []const [2]Measurement) !void {
    try testing.expectEqualSlices([2]Measurement, want, got);
}

/// A 45-degree bar 100 long between the lines `y = x + c` and `y = x + c +
/// d`, its ends cut by a step (one horizontal and one vertical edge), so
/// every corner is 90 or 135 degrees and none is an acute tip. Its width is
/// `d/√2`.
fn bar(c: i64, d: i64) [6][2]i64 {
    const s = @divTrunc(d, 2);
    return .{ .{ 0, c }, .{ 100, 100 + c }, .{ 100, 100 + c + d - s }, .{ 100 - s, 100 + c + d - s }, .{ -s, c + d - s }, .{ -s, c } };
}

/// A 45-degree bar between the lines `y = x + c` and `y = x + c + d`, 1000
/// long in x, each end inside a pad 1010 wide: its narrowest width is the
/// bar's own.
fn padded(c: i64, d: i64) [3][4][2]i64 {
    return .{
        .{ .{ 0, c }, .{ 1000, 1000 + c }, .{ 1000, 1000 + c + d }, .{ 0, c + d } },
        pad(-1000, 10, c - 1000, c + d + 1010),
        pad(990, 2000, c - 10, 2000 + c + d),
    };
}

fn pad(x0: i64, x1: i64, y0: i64, y1: i64) [4][2]i64 {
    return .{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
}

/// `rules` on `rings` find the same under all eight grid symmetries.
fn holdsUnderSymmetries(rules: []const u8, rings: []const Ring) !void {
    var layout = try layoutOf(rings);
    defer layout.deinit();
    var base = try runLayout(rules, &layout);
    defer base.deinit();
    const want = try base.summary();
    for (common.symmetries[1..]) |s| {
        var moved = try layout.transformed(s, 0, 0);
        defer moved.deinit();
        var found = try runLayout(rules, &moved);
        defer found.deinit();
        const got = try found.summary();
        try testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "a 45 degree bar is as wide as its perpendicular" {
    // DRC-038, diagonal width; DRC-037, bent 45-degree features.
    // Oracle: hand-derived. The bar between `y = x` and `y = x + 7` is `7/√2
    // = √24.5 ≈ 4.95` wide: `width >= 5nm` flags it at 4 (floored), `width >=
    // 4nm` passes. A width squared and rounded up (25) would pass at 5. The
    // bar between `y = x` and `y = x + 283` is `200.1` wide: clean at 200,
    // 200 at 201.
    const p7 = padded(0, 7);
    var found = try run("rule w5 width(met1) >= 5nm\nrule w4 width(met1) >= 4nm", &.{ &p7[0], &p7[1], &p7[2] });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("w5"));
    try expectFindings(&.{.{ len(4), len(5) }}, try found.of("w5"));
    try testing.expectEqual(@as(usize, 0), (try found.of("w4")).len);
    const p283 = padded(0, 283);
    var wide = try run("rule w200 width(met1) >= 200nm\nrule w201 width(met1) >= 201nm", &.{ &p283[0], &p283[1], &p283[2] });
    defer wide.deinit();
    try testing.expectEqual(@as(usize, 0), (try wide.of("w200")).len);
    try expectFindings(&.{.{ len(200), len(201) }}, try wide.of("w201"));
}

test "two 45 degree bars are as far apart as their lines" {
    // DRC-038, diagonal spacing.
    // Oracle: hand-derived. Bars between `y = x .. x + 10` and `y = x + 17 ..
    // x + 27` are `7/√2 ≈ 4.95` apart, the nearest any two of their points
    // come (two parallel strips): `space >= 5nm` flags them at 4, `>= 4nm`
    // passes. IHP M1.i measures the space of 45-degree lines this way
    // (Euclidean).
    const b0 = bar(0, 10);
    const b1 = bar(17, 10);
    var found = try run("rule s5 space(met1) >= 5nm\nrule s4 space(met1) >= 4nm", &.{ &b0, &b1 });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("s5"));
    try expectFindings(&.{.{ len(4), len(5) }}, try found.of("s5"));
    try testing.expectEqual(@as(usize, 0), (try found.of("s4")).len);
}

test "a turned u has its width and notch times root two" {
    // Oracle: the 45-degree law, construct-from-answer. A U with arms 100
    // wide, a base 50 tall and a slot 100 wide, turned by `(x, y) -> (x - y,
    // x + y)` (45 degrees, every length times `√2`): width `50·√2 ≈ 70.7`,
    // notch `100·√2 ≈ 141.4`. Each rule flags it one unit above the floor and
    // passes at the floor.
    var turned: [8][2]i64 = undefined;
    for (&turned, u_shape) |*t, p| t.* = .{ p[0] - p[1], p[0] + p[1] };
    var found = try run("rule w71 width(met1) >= 71nm\nrule w70 width(met1) >= 70nm\nrule n142 notch(met1) >= 142nm\nrule n141 notch(met1) >= 141nm", &.{&turned});
    defer found.deinit();
    try expectFindings(&.{.{ len(70), len(71) }}, try found.of("w71"));
    try testing.expectEqual(@as(usize, 0), (try found.of("w70")).len);
    try expectFindings(&.{.{ len(141), len(142) }}, try found.of("n142"));
    try testing.expectEqual(@as(usize, 0), (try found.of("n141")).len);
}

test "half unit areas and diagonal edge lengths compare exactly" {
    // Oracle: hand-derived. The right triangle with legs 9 has area 40.5:
    // `area >= 41nm2` flags it at 40 (floored), `>= 40nm2` passes. A diamond
    // of radius 10 has four edges `10·√2 ≈ 14.14` long: `edge_length >= 15nm`
    // flags all four at 14, `>= 14nm` none.
    var found = try run("rule a41 area(met1) >= 41nm2\nrule a40 area(met1) >= 40nm2", &.{&.{ .{ 0, 0 }, .{ 9, 0 }, .{ 0, 9 } }});
    defer found.deinit();
    try expectFindings(&.{.{ area(40), area(41) }}, try found.of("a41"));
    try testing.expectEqual(@as(usize, 0), (try found.of("a40")).len);
    var edges = try run("rule e15 edge_length(met1) >= 15nm\nrule e14 edge_length(met1) >= 14nm", &.{&.{ .{ 10, 0 }, .{ 0, 10 }, .{ -10, 0 }, .{ 0, -10 } }});
    defer edges.deinit();
    const e = [2]Measurement{ len(14), len(15) };
    try expectFindings(&.{ e, e, e, e }, try edges.of("e15"));
    try testing.expectEqual(@as(usize, 0), (try edges.of("e14")).len);
}

test "an edge a tip touches is one edge" {
    // Oracle: hand-derived, as KLayout reads an edge (one straight stretch
    // of boundary). A 100 x 50 box with a triangle standing on its top edge by
    // its 90-degree tip, at (50, 50), is one figure (the connected corner
    // model) whose ring leaves the top edge at the tip and comes back to it:
    // the top is still one edge 100 long. `edge_length >= 60nm` flags the
    // box's two 50-long sides only; the triangle's sides are `50·√2 ≈ 70.7`.
    var found = try run("rule e60 edge_length(met1) >= 60nm", &.{ &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 50 }, .{ 0, 50 } }, &.{ .{ 50, 50 }, .{ 100, 100 }, .{ 0, 100 } } });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("e60"));
    const e = [2]Measurement{ len(50), len(60) };
    try expectFindings(&.{ e, e }, try found.of("e60"));
}

test "a corner on an edge is a neck" {
    // Oracle: hand-derived, as KLayout's Euclidean `width` reads a corner on
    // an edge (its zero distance when touching; the mirror differential's
    // layouts 683, 716, 820 and 1038 found it). A 100 x 50 box with a diamond
    // (90-degree corners, `30·√2 ≈ 42.4` across) standing on its top edge by
    // one corner, at (50, 50), is one figure (the connected corner model)
    // with a 0-wide neck there. Without that pair it would be 42.
    var found = try run("rule w45 width(met1) >= 45nm", &.{ &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 50 }, .{ 0, 50 } }, &.{ .{ 50, 50 }, .{ 80, 80 }, .{ 50, 110 }, .{ 20, 80 } } });
    defer found.deinit();
    try expectFindings(&.{.{ len(0), len(45) }}, try found.of("w45"));
}

test "a diamond hole is measured" {
    // Oracle: hand-derived. A 40 square with a diamond hole of radius 5 (area
    // `2·5² = 50`), the hole a clockwise row of its own: `hole_area >=
    // 51nm2` flags the hole at 50, `>= 50nm2` passes.
    var found = try run("rule h51 hole_area(met1) >= 51nm2\nrule h50 hole_area(met1) >= 50nm2", &.{ &.{ .{ 0, 0 }, .{ 40, 0 }, .{ 40, 40 }, .{ 0, 40 } }, &.{ .{ 15, 20 }, .{ 20, 25 }, .{ 25, 20 }, .{ 20, 15 } } });
    defer found.deinit();
    try expectFindings(&.{.{ area(50), area(51) }}, try found.of("h51"));
    try testing.expectEqual(@as(usize, 0), (try found.of("h50")).len);
}

test "a kind not proved on 45 degree edges still refuses them" {
    // Oracle: the rule's documented scope (`docs/limitations.md`): a kind not
    // yet proved on 45-degree geometry records `Refused` on such a layer,
    // never a clean `Ran`.
    const b = bar(0, 10);
    var found = try run("rule p prl_space(met1; prl: 50nm) >= 20nm", &.{&b});
    defer found.deinit();
    try testing.expectEqual(Outcome.refused, found.outcome("p"));
}

test "the 45 degree kinds are invariant under the symmetries of the grid" {
    // DRC-002, DRC-037, DRC-038: every kind proved on 45-degree shapes gives
    // the same findings under all eight symmetries of the grid.
    // Oracle: metamorphic, the symmetry law: a mirror or a quarter turn maps
    // a 45-degree edge to a 45-degree edge and preserves every distance and
    // area, so each rule's measurements and limits are those of the
    // untransformed layout, which the tests above derive by hand.
    var turned: [8][2]i64 = undefined;
    for (&turned, u_shape) |*t, p| t.* = .{ p[0] - p[1] + 1000, p[0] + p[1] };
    const b0 = bar(0, 7);
    const b1 = bar(14, 10);
    const rings = [_]Ring{
        .{ .layer = "met1", .points = &b0 },
        .{ .layer = "met1", .points = &b1 },
        .{ .layer = "met1", .points = &.{ .{ 500, 0 }, .{ 509, 0 }, .{ 500, 9 } } },
        .{ .layer = "met1", .points = &.{ .{ 700, 0 }, .{ 710, 10 }, .{ 700, 20 }, .{ 690, 10 } } },
        .{ .layer = "met1", .points = &turned },
    };
    const rules = "rule w5 width(met1) >= 5nm\nrule n142 notch(met1) >= 142nm\nrule s5 space(met1) >= 5nm\nrule a41 area(met1) >= 41nm2\nrule e15 edge_length(met1) >= 15nm";
    var base = try runOn(rules, &rings);
    defer base.deinit();
    var any: usize = 0;
    for (base.run.rows) |row| any += row.findings.len;
    try testing.expect(any > 0);
    try holdsUnderSymmetries(rules, &rings);
}

test "enclosure reads a 45 degree host and inner" {
    // DRC-040 on 45-degree shapes (H12b): `enclosure` is the Euclidean
    // distance from the inner shape to its host's boundary, a 45-degree host
    // edge included.
    // Oracle: hand-derived, and the symmetry law. A 20-square at (40..60)² in
    // `octagon_host` is 40 from every side, but its corner (40, 40) is `(80 -
    // 30)/√2 = √1250 ≈ 35.36` from the chamfer `x + y = 30`: `>= 36nm` flags
    // it at 35 (floored), `>= 35nm` passes. A diamond of radius 10 at (50, 50)
    // is 40 from the sides at its tips and `(100 - 30 - 10)/√2 ≈ 42.4` from a
    // chamfer at its nearest edge: `>= 41nm` flags it at 40. A square poking
    // past the chamfer is not hosted: 0.
    const square: Ring = .{ .layer = "met1", .points = &.{ .{ 40, 40 }, .{ 60, 40 }, .{ 60, 60 }, .{ 40, 60 } } };
    var found = try runOn("rule e36 enclosure(met1, met2) >= 36nm\nrule e35 enclosure(met1, met2) >= 35nm", &.{ octagon_host, square });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("e36"));
    try expectFindings(&.{.{ len(35), len(36) }}, try found.of("e36"));
    try testing.expectEqual(@as(usize, 0), (try found.of("e35")).len);
    const diamond: Ring = .{ .layer = "met1", .points = &.{ .{ 50, 40 }, .{ 60, 50 }, .{ 50, 60 }, .{ 40, 50 } } };
    var d = try runOn("rule e41 enclosure(met1, met2) >= 41nm", &.{ octagon_host, diamond });
    defer d.deinit();
    try expectFindings(&.{.{ len(40), len(41) }}, try d.of("e41"));
    const out: Ring = .{ .layer = "met1", .points = &.{ .{ 5, 5 }, .{ 25, 5 }, .{ 25, 25 }, .{ 5, 25 } } };
    var o = try runOn("rule e1 enclosure(met1, met2) >= 1nm", &.{ octagon_host, out });
    defer o.deinit();
    try expectFindings(&.{.{ len(0), len(1) }}, try o.of("e1"));
    try holdsUnderSymmetries("rule e36 enclosure(met1, met2) >= 36nm", &.{ octagon_host, square, diamond });
}

test "a noncoincident enclosure exempts an edge on a chamfer" {
    // DRC-054 on 45-degree shapes (H12b): a non-coincident enclosure exempts
    // an inner edge lying on the host's 45-degree edge, and pairs an inner
    // edge with a host edge at 45 degrees to it, as KLayout's `enclosing`
    // does.
    // Oracle: hand-derived, and the symmetry law. The right triangle (10,
    // 20), (20, 10), (20, 20) in `octagon_host` has its hypotenuse on the
    // chamfer `x + y = 30`: `enclosure` reads 0 there, but the non-coincident
    // reading skips that coincident pair. Its right edge pairs with the
    // chamfer `x - y = 70` (45 degrees to it), nearest from (20, 10) to the
    // chamfer's end (70, 0), `√2600 ≈ 50.99`, and its top edge likewise with
    // `y - x = 70`: `>= 50nm` passes, `>= 51nm` flags at 50 (floored).
    const triangle: Ring = .{ .layer = "met1", .points = &.{ .{ 20, 10 }, .{ 20, 20 }, .{ 10, 20 } } };
    const rules = "rule e1 enclosure(met1, met2) >= 1nm\nrule n50 enclosure(met1, met2, noncoincident) >= 50nm\nrule n51 enclosure(met1, met2, noncoincident) >= 51nm";
    const layout = [_]Ring{ octagon_host, triangle };
    var found = try runOn(rules, &layout);
    defer found.deinit();
    try expectFindings(&.{.{ len(0), len(1) }}, try found.of("e1"));
    try testing.expectEqual(@as(usize, 0), (try found.of("n50")).len);
    try expectFindings(&.{.{ len(50), len(51) }}, try found.of("n51"));
    try holdsUnderSymmetries(rules, &layout);
}

test "straight out enclosures read a chamfer at its nearest point" {
    // DRC-041 and DRC-042 on 45-degree hosts (H12b): opposite and adjacent
    // enclosure read a rectangle straight out to a 45-degree host edge at its
    // point nearest the rectangle's side; an inner shape with a 45-degree
    // edge has no straight-out reading and refuses.
    // Oracle: hand-derived, and the symmetry law. The 20-square at (10..30,
    // 40..60) in `octagon_host` reads 10 left and 70 right; below, the
    // chamfer `x + y = 30` over x 10..30 comes nearest at (10, 20): 20;
    // above, `y - x = 70` at (10, 80): 20. Opposite: `max(min(10, 70),
    // min(20, 20)) = 20`, so `>= 21nm` flags at 20 and `>= 20nm` passes.
    // Adjacent: the left corners' better side is the horizontal one, 20; the
    // right corners' the vertical one, 70: `>= 21nm` flags at 20.
    const square: Ring = .{ .layer = "met1", .points = &.{ .{ 10, 40 }, .{ 30, 40 }, .{ 30, 60 }, .{ 10, 60 } } };
    const rules = "rule o21 enclosure(met1, met2, opposite) >= 21nm\nrule o20 enclosure(met1, met2, opposite) >= 20nm\nrule a21 enclosure(met1, met2, adjacent) >= 21nm";
    const layout = [_]Ring{ octagon_host, square };
    var found = try runOn(rules, &layout);
    defer found.deinit();
    try expectFindings(&.{.{ len(20), len(21) }}, try found.of("o21"));
    try testing.expectEqual(@as(usize, 0), (try found.of("o20")).len);
    try expectFindings(&.{.{ len(20), len(21) }}, try found.of("a21"));
    try holdsUnderSymmetries(rules, &layout);
    const diamond: Ring = .{ .layer = "met1", .points = &.{ .{ 50, 40 }, .{ 60, 50 }, .{ 50, 60 }, .{ 40, 50 } } };
    var d = try runOn(rules, &.{ octagon_host, diamond });
    defer d.deinit();
    try testing.expectEqual(Outcome.refused, d.outcome("o21"));
    try testing.expectEqual(Outcome.refused, d.outcome("a21"));
}

test "inside and contains read 45 degree figures" {
    // DRC-091 and DRC-092 on 45-degree shapes (H12b): `inside` and `contains`
    // read 45-degree figures exactly.
    // Oracle: hand-derived, and the symmetry law. In `octagon_host` (met2): a
    // diamond of radius 10 at (50, 50) lies inside; one at (15, 15) is cut in
    // half by the chamfer `x + y = 30`, so `inside(met1, met2)` reports its
    // outside half, `10² = 100`; a half-unit triangle (0, 0), (1, 0), (0, 1)
    // past the host's corner is all outside, area 0.5, reported rounded up as
    // 1. `contains(met2, met1) >= 2` counts the one diamond held: 1, short of
    // 2.
    const rules = "rule i inside(met1, met2)\nrule c contains(met2, met1) >= 2";
    const layout = [_]Ring{
        octagon_host,
        .{ .layer = "met1", .points = &.{ .{ 50, 40 }, .{ 60, 50 }, .{ 50, 60 }, .{ 40, 50 } } },
        .{ .layer = "met1", .points = &.{ .{ 15, 5 }, .{ 25, 15 }, .{ 15, 25 }, .{ 5, 15 } } },
        .{ .layer = "met1", .points = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } } },
    };
    var found = try runOn(rules, &layout);
    defer found.deinit();
    const inside = try found.run.arena.allocator().dupe([2]Measurement, try found.of("i"));
    std.mem.sort([2]Measurement, inside, {}, struct {
        fn less(_: void, p: [2]Measurement, q: [2]Measurement) bool {
            return p[0].raw < q[0].raw;
        }
    }.less);
    try expectFindings(&.{ .{ area(1), area(0) }, .{ area(100), area(0) } }, inside);
    try expectFindings(&.{.{ Measurement.count(1), Measurement.count(2) }}, try found.of("c"));
    try holdsUnderSymmetries(rules, &layout);
}

test "contains counts 45 degree figures against each bound" {
    // DRC-048 and DRC-049 on 45-degree figures: `contains` counts each
    // diamond the octagonal host holds against every bound, at and either
    // side of the count.
    // Oracle: counts fixed by construction. Two diamonds of radius 10 at (50,
    // 25) and (50, 75) lie inside `octagon_host` (their tips 15 and 85 high
    // stay inside the chamfers `x + y = 30` and `y - x = 70`): the host holds
    // 2. `>= 1`, `>= 2`, `== 2` and `<= 2` hold (the count at a bound is
    // legal); `>= 3` is short (2 against 3) and `<= 1` over (2 against 1).
    const rules = "rule one contains(met2, met1) >= 1\nrule two contains(met2, met1) >= 2\nrule three contains(met2, met1) >= 3\nrule most contains(met2, met1) <= 1\nrule most2 contains(met2, met1) <= 2\nrule exact contains(met2, met1) == 2";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    var layout = try layoutOf(&.{
        octagon_host,
        .{ .layer = "met1", .points = &.{ .{ 50, 15 }, .{ 60, 25 }, .{ 50, 35 }, .{ 40, 25 } } },
        .{ .layer = "met1", .points = &.{ .{ 50, 65 }, .{ 60, 75 }, .{ 50, 85 }, .{ 40, 75 } } },
    });
    defer layout.deinit();
    const claims = try common.byRule(al, &.{ "one", "two", "three", "most", "most2", "exact" }, &.{
        .{ "three", Finding.count(2).limitOf(.count(3)) },
        .{ "most", Finding.count(2).limitOf(.count(1)) },
    });
    try common.checkEverywhere("two_diamonds", try common.deck(al, rules), &layout, claims);
}
