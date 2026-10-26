//! Cut spacing kinds as exhaustive fixtures: lonely cuts, via arrays and
//! centre-to-centre spacing. Ported from tests/exhaustive/drc_overlay.rs
//! (`max_cut_spacing`, `via_array_spacing`, `center_spacing`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");
const Rect = c.Rect;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try maxCutSpacingInto(arena, out);
    try viaArraySpacingInto(arena, depth, out);
    try centerSpacingInto(arena, out);
}

// ---- private ----

/// A layout of `rs` on `layer`.
fn boxes(arena: Allocator, layer: []const u8, rs: []const Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, rs);
    return l;
}

/// A 100 nm cut with its lower left corner at `(x, y)`.
fn cut(x: i64, y: i64) Rect {
    return .{ x, y, x + 100, y + 100 };
}

/// One finding measuring `d` at each of `at`.
fn far(arena: Allocator, d: i64, at: []const [2]i64) ![]const Finding {
    const found = try arena.alloc(Finding, at.len);
    for (at, found) |p, *f| f.* = Finding.length(d).pinned(p[0], p[1]);
    return found;
}

/// `max_space(v1) <= 1000nm` and `max_space(big, v1) <= 1000nm` with `big =
/// v1.with_bbox_min(>= 150nm)` (`max_cut_spacing`, DRC-034):
/// `LEF58_MAXSPACING 1.0 [CUTCLASS]` as `OpenROAD`'s `getLonelyVias` reads
/// it, a cut (of the class) with no other cut on the layer whose centre is
/// within 1000 of its own lonely, one finding at its centre measuring the
/// nearest centre distance rounded up.
///
/// Oracle: centres placed by construction: two 100 cuts 999, 1000 and 1001
/// apart (both lonely only at 1001); a 600 x 800 diagonal (1000, legal) and
/// a 600 x 801 one (1000.8, both lonely at 1001); a lone cut (no other: a
/// count of 0 against 1); a chain 1000 then 1500 apart, whose far cut alone
/// is lonely (1500). With a class: a 200 cut 900 from a 100 cut is not
/// lonely, the 100 cut is not held; 1200 apart, the 200 cut is lonely; a 200
/// cut alone does not count its own row on the whole layer.
fn maxCutSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{"v1"}, "layer big = v1.with_bbox_min(>= 150nm)\nrule lone max_space(v1) <= 1000nm\nrule cls max_space(big, v1) <= 1000nm\n");
    const Case = struct { []const u8, Layout, []const Finding, []const Finding };
    const none = try arena.dupe(Finding, &.{c.count(0)});
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(1000)) |sw| {
        const d = sw.value;
        const lonely: []const Finding = if (d > 1000) try far(arena, d, &.{ .{ 50, 50 }, .{ d + 50, 50 } }) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "pair/{s}", .{sw.side}), try boxes(arena, "v1", &.{ cut(0, 0), cut(d, 0) }), lonely, &.{} });
    }
    try list.append(arena, .{ "diagonal/at", try boxes(arena, "v1", &.{ cut(0, 0), cut(600, 800) }), &.{}, &.{} });
    try list.append(arena, .{ "diagonal/above", try boxes(arena, "v1", &.{ cut(0, 0), cut(600, 801) }), try far(arena, 1001, &.{ .{ 50, 50 }, .{ 650, 851 } }), &.{} });
    try list.append(arena, .{ "alone", try boxes(arena, "v1", &.{cut(0, 0)}), none, &.{} });
    try list.append(arena, .{ "chain", try boxes(arena, "v1", &.{ cut(0, 0), cut(1000, 0), cut(2500, 0) }), try far(arena, 1500, &.{.{ 2550, 50 }}), &.{} });
    // A 200 cut centred at (100, 100).
    const big: Rect = .{ 0, 0, 200, 200 };
    try list.append(arena, .{ "class/near", try boxes(arena, "v1", &.{ big, .{ 950, 50, 1050, 150 } }), &.{}, &.{} });
    try list.append(arena, .{ "class/far", try boxes(arena, "v1", &.{ big, .{ 1250, 50, 1350, 150 } }), try far(arena, 1200, &.{ .{ 100, 100 }, .{ 1300, 100 } }), try far(arena, 1200, &.{.{ 100, 100 }}) });
    try list.append(arena, .{ "class/alone", try boxes(arena, "v1", &.{big}), none, none });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "max_cut_spacing/{s}", .{cs[0]}), &.{"DRC-034"}, deck, cs[1], &.{ .{ "lone", cs[2] }, .{ "cls", cs[3] } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `n` 100 nm cuts in a row, `g` apart.
fn row(arena: Allocator, n: i64, g: i64) ![]const Rect {
    const rs = try arena.alloc(Rect, @intCast(n));
    for (rs, 0..) |*r, i| {
        const x = @as(i64, @intCast(i)) * (100 + g);
        r.* = .{ x, 0, x + 100, 100 };
    }
    return rs;
}

/// A row's findings: each of its `n - 1` gaps when it is an array (more
/// than 3) closer than the limit.
fn rowFindings(arena: Allocator, n: i64, g: i64) ![]const Finding {
    if (!(n > 3 and g < 100)) return &.{};
    const found = try arena.alloc(Finding, @intCast(n - 1));
    for (found) |*f| f.* = .length(g);
    return found;
}

/// A via-array fixture: `cuts` on `cut` beside an `other` shape.
fn viaArrayCase(arena: Allocator, deck: []const u8, name: []const u8, cuts: []const Rect, findings: []const Finding) !Fixture {
    var l: Layout = .{};
    try l.rect(arena, "other", -1000, -1000, -900, -900);
    try c.rects(arena, &l, "cut", cuts);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "via_array_spacing/{s}", .{name}), &.{"DRC-062"}, deck, l, &.{.{ "cnt.b1", findings }});
}

/// `via_array_space(cut; array: 3) >= 100nm` (`via_array_spacing`,
/// DRC-062): cuts joined by gaps of at most 100 nm form a cluster, a cluster
/// of more than 3 is an array, and each pair in an array closer than 100 nm
/// is one finding measuring its gap, at the midpoint of its nearest points.
///
/// Shapes: rows of 3 and 4 cuts at 99/100/101 (3 is not an array; at 100 the
/// row is one array with no close pair; at 101 nothing joins); a 3 x 3 grid
/// at 90 (12 side pairs; the diagonals are 127 apart); two close pairs
/// joined into one array by a 100 nm gap, and kept apart by 101; an array
/// with a cut drawn overlapping another (cuts are as drawn: a gap of 0); an
/// L-shaped cut marked on the stretch it measured, not its box (F82); an
/// empty layer. Nightly: rows of 1 to 6 cuts at 95 to 105.
fn viaArraySpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "cut", "other" }, "rule cnt.b1 via_array_space(cut; array: 3) >= 100nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(100)) |sw| for ([_]i64{ 3, 4 }) |n| {
        try cases.append(arena, try viaArrayCase(arena, deck, try std.fmt.allocPrint(arena, "row{d}/{s}", .{ n, sw.side }), try row(arena, n, sw.value), try rowFindings(arena, n, sw.value)));
    };
    var grid: std.ArrayList(Rect) = .empty;
    for (0..3) |i| for (0..3) |j| {
        const x = @as(i64, @intCast(i)) * 190;
        const y = @as(i64, @intCast(j)) * 190;
        try grid.append(arena, .{ x, y, x + 100, y + 100 });
    };
    const ninety: [12]i64 = @splat(90);
    try cases.append(arena, try viaArrayCase(arena, deck, "grid3x3", grid.items, try c.lengths(arena, &ninety)));
    const pairs = [_]struct { i64, []const u8, []const i64 }{ .{ 100, "joined_pairs", &.{ 90, 90 } }, .{ 101, "separate_pairs", &.{} } };
    for (pairs) |p| {
        const x3 = 290 + p[0];
        try cases.append(arena, try viaArrayCase(arena, deck, p[1], &.{ .{ 0, 0, 100, 100 }, .{ 190, 0, 290, 100 }, .{ x3, 0, x3 + 100, 100 }, .{ x3 + 190, 0, x3 + 290, 100 } }, try c.lengths(arena, p[2])));
    }
    var doubled: std.ArrayList(Rect) = .empty;
    try doubled.appendSlice(arena, try row(arena, 4, 100));
    try doubled.append(arena, .{ -50, 0, 50, 100 });
    try cases.append(arena, try viaArrayCase(arena, deck, "overlapping_cut", doubled.items, try c.lengths(arena, &.{0})));
    // F82: the second cut is an L, its foot x = 190..290 up to y = 50 and its
    // stem x = 240..290 up to y = 200. The first cut's right side, x = 100,
    // faces the foot's left side x = 190 only over y = 0..50: 90, marked at
    // (145, 25). The boxes' gap is centred at (145, 50), beside the foot.
    // The stem's right side faces the third cut over y = 0..100 at (335, 50),
    // and the third the fourth at (525, 50).
    var l_cut: Layout = .{};
    try l_cut.rect(arena, "other", -1000, -1000, -900, -900);
    try c.rects(arena, &l_cut, "cut", &.{ .{ 0, 0, 100, 100 }, .{ 380, 0, 480, 100 }, .{ 570, 0, 670, 100 } });
    try l_cut.polygon(arena, "cut", &.{ .{ 190, 0 }, .{ 290, 0 }, .{ 290, 200 }, .{ 240, 200 }, .{ 240, 50 }, .{ 190, 50 } });
    const marked = [_]Finding{ Finding.length(90).pinned(145, 25), Finding.length(90).pinned(335, 50), Finding.length(90).pinned(525, 50) };
    try cases.append(arena, try c.fixture(arena, "via_array_spacing/l_cut_beside_a_square", &.{"DRC-062"}, deck, l_cut, &.{.{ "cnt.b1", &marked }}));
    try cases.append(arena, try viaArrayCase(arena, deck, "empty", &.{}, &.{}));
    if (depth == .nightly) {
        var n: i64 = 1;
        while (n <= 6) : (n += 1) {
            var g: i64 = 95;
            while (g <= 105) : (g += 1) try cases.append(arena, try viaArrayCase(arena, deck, try std.fmt.allocPrint(arena, "rows/n{d}_g{d}", .{ n, g }), try row(arena, n, g), try rowFindings(arena, n, g)));
        }
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `space(cut, center) >= 300nm` (`cut_spacing`, DRC-061, LEF `SPACING
/// CENTERTOCENTER`): one finding per pair of drawn cuts whose bounding-box
/// centres are closer than the limit, measuring that distance floored.
///
/// Oracle: the cuts are drawn so their centres are a chosen distance apart;
/// the diagonal pair at centre offsets (180, 239/240/241) is 299.2, 300 and
/// 300.8 apart (a 180-240-300 triangle).
///
/// Shapes: two 100 nm squares, swept; a 100 nm and a 200 nm cut, swept,
/// whose 150 nm edge gap an edge measure would flag at every step; a 101 nm
/// and a 100 nm cut, whose centres are a half unit off the grid (299.5
/// floors to 299, 300.5 passes); the diagonal pair; overlapping cuts (50)
/// and a cut nested in another (0); a row of three at a 250 nm pitch (the
/// outer pair, 500 apart, passes); an empty layer.
fn centerSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 300;
    const deck = try c.newDeck(arena, &.{"cut"}, "rule c2c space(cut, center) >= 300nm\n");
    const Case = struct { []const u8, []const Rect, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(limit)) |sw| {
        const d = sw.value;
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "squares/{s}", .{sw.side}), try arena.dupe(Rect, &.{ .{ 0, 0, 100, 100 }, .{ d, 0, d + 100, 100 } }), try c.below(arena, d, limit) });
        // Centres 50 and x + 100 apart by d: x = d - 50.
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "unequal/{s}", .{sw.side}), try arena.dupe(Rect, &.{ .{ 0, 0, 100, 100 }, .{ d - 50, 0, d + 150, 100 } }), try c.below(arena, d, limit) });
        // Centres 50.5 and x + 50 along x, both 50 along y: d - 0.5 apart
        // for x = d, floored to d - 1.
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "half_unit/{s}", .{sw.side}), try arena.dupe(Rect, &.{ .{ 0, 0, 101, 100 }, .{ d, 0, d + 100, 100 } }), try c.below(arena, d - 1, limit) });
    }
    const diagonals = [_]struct { i64, []const u8, []const i64 }{ .{ 239, "below", &.{299} }, .{ 240, "at", &.{} }, .{ 241, "above", &.{} } };
    for (diagonals) |dg| try list.append(arena, .{ try std.fmt.allocPrint(arena, "diagonal/{s}", .{dg[1]}), try arena.dupe(Rect, &.{ .{ 0, 0, 100, 100 }, .{ 180, dg[0], 280, dg[0] + 100 } }), try c.lengths(arena, dg[2]) });
    try list.append(arena, .{ "overlapping", &.{ .{ 0, 0, 100, 100 }, .{ 50, 0, 150, 100 } }, try c.lengths(arena, &.{50}) });
    try list.append(arena, .{ "nested", &.{ .{ 0, 0, 300, 300 }, .{ 100, 100, 200, 200 } }, try c.lengths(arena, &.{0}) });
    try list.append(arena, .{ "row_of_three", &.{ .{ 0, 0, 100, 100 }, .{ 250, 0, 350, 100 }, .{ 500, 0, 600, 100 } }, try c.lengths(arena, &.{ 250, 250 }) });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "center_spacing/{s}", .{cs[0]}), &.{"DRC-061"}, deck, try boxes(arena, "cut", cs[1]), &.{.{ "c2c", cs[2] }}));
    var other: Layout = .{};
    try other.rect(arena, "other", 0, 0, 100, 100);
    try cases.append(arena, try c.fixture(arena, "center_spacing/empty", &.{"DRC-061"}, try c.newDeck(arena, &.{ "cut", "other" }, "rule c2c space(cut, center) >= 300nm\n"), other, &.{.{ "c2c", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every lonely-cut, via-array and centre-spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived by construction from
    // the rule's definition (the doc comments above, the LEF manual's
    // statements), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
