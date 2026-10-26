//! `min_spacing` (DRC-023) and `min_spacing_diff` (DRC-047) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs (`diagonals`,
//! `diagonal_pair`, `hook_beside_a_square`, `tucked_marker`,
//! `min_spacing`, `min_spacing_diff`).
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

/// A shape's name under its generator, its layout and its findings.
const Case = struct { []const u8, Layout, []const Finding };

const diff_deck = "grid 1nm\nlayer poly = gds(66, 20)\nlayer diff = gds(65, 20)\nrule sd space(poly, diff) >= 101nm\nrule ds space(diff, poly) >= 101nm\n";

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try minSpacingInto(arena, depth, out);
    try minSpacingDiffInto(arena, depth, out);
}

// ---- private ----

/// The diagonal offsets swept for Euclidean corner gaps: `d` on both axes,
/// so the gap is `d·√2`, around a limit of 101 (70 gives 98.99, 71 gives
/// 100.41, 72 gives 101.82).
fn diagonals(arena: Allocator, depth: Depth) ![]const i64 {
    return switch (depth) {
        .merge => arena.dupe(i64, &.{ 70, 71, 72 }),
        .nightly => blk: {
            const all = try arena.alloc(i64, 90);
            for (all, 1..) |*d, i| d.* = @intCast(i);
            break :blk all;
        },
    };
}

/// Two 1000 squares `d` apart on both axes, and what a Euclidean minimum
/// of 101 finds: the floored gap, midway between the facing corners.
fn diagonalPair(arena: Allocator, first: []const u8, second: []const u8, d: i64) !Case {
    var layout: Layout = .{};
    try layout.rect(arena, first, 0, 0, 1000, 1000);
    try layout.rect(arena, second, 1000 + d, 1000 + d, 2000 + d, 2000 + d);
    const gap2 = 2 * d * d;
    const findings: []const Finding = if (gap2 < 101 * 101) try arena.dupe(Finding, &.{c.pin(.length(c.floorSqrt(gap2)), 2000 + d, 2000 + d)}) else &.{};
    return .{ try std.fmt.allocPrint(arena, "diagonal/d{d}", .{d}), layout, findings };
}

/// The square `[0, 1000]²` and a hook beside it: the hook's left side,
/// x = 1050, runs down from y = 500 to -500, facing the square's right edge
/// 50 away over y = 0..500; its inner corner (1060, 1060) faces the
/// square's corner (1000, 1000) diagonally, √7200 = 84.9 away. The hook's
/// box spans y = -500..1500, so the boxes' gap is centred at (1025, 500),
/// on neither.
fn hookBesideASquare(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 1000, 1000);
    try l.polygon(arena, "met1", &.{ .{ 1050, -500 }, .{ 1600, -500 }, .{ 1600, 1500 }, .{ 1060, 1500 }, .{ 1060, 1060 }, .{ 1500, 1060 }, .{ 1500, 500 }, .{ 1050, 500 } });
    return l;
}

/// The finding for a square `[100 + g, 1000]²` tucked into the L of arms
/// `[0, 1000] x [0, 100]` and `[0, 100] x [0, 1000]`, g apart: two nearest
/// stretches of one length, 900 - g, tie. The L's y = 100 faces the
/// square's y = 100 + g over x = 100 + g..1000, midpoint ((1100 + g) / 2,
/// (200 + g) / 2), and the L's x = 100 faces x = 100 + g, its mirror across
/// y = x. The marker is the middle of the box bounding the two: ((650 + g)
/// / 2, (650 + g) / 2), on the diagonal the pair is symmetric across,
/// pinned where whole (F82). Either midpoint alone would follow drawing
/// order, and a transposed layout would report the other.
fn tuckedMarker(g: i64) Finding {
    return c.pin(.length(g), 650 + g, 650 + g);
}

/// The L of arms `[0, 1000] x [0, 100]` and `[0, 100] x [0, 1000]` on
/// `host`, and the square `[100 + g, 1000]²` on `guest`.
fn tuckedIntoL(arena: Allocator, host: []const u8, guest: []const u8, g: i64) !Layout {
    var l: Layout = .{};
    try l.polygon(arena, host, &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 100, 100 }, .{ 100, 1000 }, .{ 0, 1000 } });
    try l.rect(arena, guest, 100 + g, 100 + g, 1000, 1000);
    return l;
}

/// The 3000 square with a 1000 hole on `host`, and an island g inside the
/// hole on `guest`.
fn islandInHole(arena: Allocator, host: []const u8, guest: []const u8, g: i64) !Layout {
    var l: Layout = .{};
    try l.polygon(arena, host, try c.holed(arena, .{ 0, 0, 3000, 3000 }, .{ 1000, 1000, 2000, 2000 }));
    try l.rect(arena, guest, 1000 + g, 1000 + g, 2000 - g, 2000 - g);
    return l;
}

/// `findings` when `near`, else none.
fn when(arena: Allocator, near: bool, findings: []const Finding) ![]const Finding {
    return if (near) arena.dupe(Finding, findings) else &.{};
}

/// `space(met1) >= 101nm` (`min_spacing`, DRC-023): one finding per pair
/// of rows in different merged figures closer than the limit, Euclidean, at
/// the midpoint of the nearest points (the middle of the stretch where the
/// two run alongside at that distance). At the limit is legal.
///
/// Side by side and corner to corner (Euclidean: a Chebyshev or Manhattan
/// gap reads differently); touching, overlapping, corner-touching and
/// nested shapes (one figure, no gap); a notch and a narrow own hole
/// (inside one figure, not spacing); an island in a hole (keeps its gap to
/// the hole's edge), and in a hole closed by four bands (one finding per
/// band); a square tucked into an L's corner (the boxes overlap, the shapes
/// do not); a figure drawn as two halves near a bar (one finding per row
/// pair); three bars with two short gaps; a hook beside a square, marked on
/// the 50 gap it measures, not on its box (F66); a side drawn as two
/// collinear edges, marked at the middle of the whole side (F92).
fn minSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 101;
    const deck = try c.oneLayerDeck(arena, "rule s space(met1) >= 101nm");
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, limit)) |g| {
        const near = g < limit;
        const tag = try c.side(arena, g, limit);
        const name = struct {
            fn of(a: Allocator, shape: []const u8, t: []const u8) ![]const u8 {
                return std.fmt.allocPrint(a, "{s}/{s}", .{ shape, t });
            }
        }.of;
        try shapes.append(arena, .{ try name(arena, "side_by_side", tag), try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 500 + g, 0, 1000 + g, 2000 } }), try when(arena, near, &.{c.pin(.length(g), 1000 + g, 2000)}) });
        try shapes.append(arena, .{ try name(arena, "island_in_hole", tag), try islandInHole(arena, "met1", "met1", g), try when(arena, near, &.{.length(g)}) });
        // The same hole closed by four bands: one finding per band.
        try shapes.append(arena, .{ try name(arena, "island_in_bands", tag), try c.met1(arena, &.{ .{ 0, 0, 3000, 1000 }, .{ 0, 2000, 3000, 3000 }, .{ 0, 1000, 1000, 2000 }, .{ 2000, 1000, 3000, 2000 }, .{ 1000 + g, 1000 + g, 2000 - g, 2000 - g } }), try when(arena, near, &.{
            c.pin(.length(g), 3000, 2000 + g),
            c.pin(.length(g), 3000, 4000 - g),
            c.pin(.length(g), 2000 + g, 3000),
            c.pin(.length(g), 4000 - g, 3000),
        }) });
        // A square tucked into an L's corner: the boxes overlap, the shapes
        // are g apart, marked at `tuckedMarker`.
        try shapes.append(arena, .{ try name(arena, "tucked_into_l", tag), try tuckedIntoL(arena, "met1", "met1", g), try when(arena, near, &.{tuckedMarker(g)}) });
        try shapes.append(arena, .{ try name(arena, "halves_near_a_bar", tag), try c.met1(arena, &.{ .{ 0, 0, 500, 1000 }, .{ 0, 1000, 500, 2000 }, .{ 500 + g, 0, 1000 + g, 2000 } }), try when(arena, near, &.{
            c.pin(.length(g), 1000 + g, 1000),
            c.pin(.length(g), 1000 + g, 3000),
        }) });
        var three: std.ArrayList(Finding) = .empty;
        try three.append(arena, Finding.length(50).pinned(525, 1000));
        if (near) try three.append(arena, c.pin(.length(g), 2100 + g, 2000));
        try shapes.append(arena, .{ try name(arena, "three_bars", tag), try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 550, 0, 1050, 2000 }, .{ 1050 + g, 0, 1550 + g, 2000 } }), three.items });
    }
    for (try diagonals(arena, depth)) |d| try shapes.append(arena, try diagonalPair(arena, "met1", "met1", d));
    // The nearest points are x = 1000 and x = 1050 over y = 0..500: marked
    // at the middle of that stretch (the corners' 84.9 is no nearer).
    try shapes.append(arena, .{ "hook_beside_a_square", try hookBesideASquare(arena), try arena.dupe(Finding, &.{c.pin(.length(50), 1000 + 1050, 500)}) });
    // A square whose side x = 1000 is drawn as two edges, split by a
    // collinear vertex at y = 300, faces a bar 50 off over y = 0..1000: one
    // stretch, marked at its middle (1025, 500), not at the longer piece's
    // (1025, 650) (F92).
    var split: Layout = .{};
    try split.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 300 }, .{ 1000, 1000 }, .{ 0, 1000 } });
    try split.rect(arena, "met1", 1050, 0, 2000, 1000);
    try shapes.append(arena, .{ "side_split_by_a_vertex", split, try arena.dupe(Finding, &.{c.pin(.length(50), 1000 + 1050, 1000)}) });
    var own_hole: Layout = .{};
    try own_hole.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 100, 100, 150, 900 }));
    const clean = [_]struct { []const u8, Layout }{
        .{ "touching", try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 500, 0, 1000, 2000 } }) },
        .{ "overlapping", try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 400, 0, 900, 2000 } }) },
        .{ "corner_touching", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1000, 1000, 2000, 2000 } }) },
        .{ "nested", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 400, 400, 600, 600 } }) },
        .{ "notch", try c.met1(arena, &.{ .{ 0, 0, 1050, 500 }, .{ 0, 500, 500, 2000 }, .{ 550, 500, 1050, 2000 } }) },
        .{ "narrow_own_hole", own_hole },
    };
    for (clean) |s| try shapes.append(arena, .{ s[0], s[1], &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_spacing/{s}", .{s[0]}), &.{"DRC-023"}, deck, s[1], &.{.{ "s", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "min_spacing", &.{"DRC-023"}, "rule s space(met1) >= 101nm", &.{"s"}));
}

/// `poly` and `diff` rectangles.
fn two(arena: Allocator, poly: []const c.Rect, diff: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, "poly", poly);
    try c.rects(arena, &l, "diff", diff);
    return l;
}

/// `space(poly, diff) >= 101nm` and the same rule with the layers swapped
/// (`min_spacing_diff`, DRC-047): one finding per pair of a poly and a diff
/// shape closer than the limit, Euclidean, at the midpoint of the nearest
/// points. Nothing is exempt: touching, overlapping, nested and
/// corner-touching pairs measure 0. Shapes are not merged, so a diff drawn
/// as two halves is two pairs. Two poly shapes near each other are not
/// measured. The distance is symmetric, so both rules find the same.
fn minSpacingDiffInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 101;
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, limit)) |g| {
        const near = g < limit;
        const tag = try c.side(arena, g, limit);
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "side_by_side/{s}", .{tag}), try two(arena, &.{.{ 0, 0, 500, 2000 }}, &.{.{ 500 + g, 0, 1000 + g, 2000 }}), try when(arena, near, &.{c.pin(.length(g), 1000 + g, 2000)}) });
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "island_in_hole/{s}", .{tag}), try islandInHole(arena, "poly", "diff", g), try when(arena, near, &.{.length(g)}) });
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "tucked_into_l/{s}", .{tag}), try tuckedIntoL(arena, "poly", "diff", g), try when(arena, near, &.{tuckedMarker(g)}) });
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "halves/{s}", .{tag}), try two(arena, &.{.{ 0, 0, 500, 2000 }}, &.{ .{ 500 + g, 0, 1000 + g, 1000 }, .{ 500 + g, 1000, 1000 + g, 2000 } }), try when(arena, near, &.{
            c.pin(.length(g), 1000 + g, 1000),
            c.pin(.length(g), 1000 + g, 3000),
        }) });
    }
    for (try diagonals(arena, depth)) |d| try shapes.append(arena, try diagonalPair(arena, "poly", "diff", d));
    try shapes.append(arena, .{ "touching", try two(arena, &.{.{ 0, 0, 500, 2000 }}, &.{.{ 500, 0, 1000, 2000 }}), try arena.dupe(Finding, &.{Finding.length(0).pinned(500, 1000)}) });
    try shapes.append(arena, .{ "overlapping", try two(arena, &.{.{ 0, 0, 500, 2000 }}, &.{.{ 400, 0, 900, 2000 }}), try arena.dupe(Finding, &.{.length(0)}) });
    try shapes.append(arena, .{ "nested", try two(arena, &.{.{ 0, 0, 1000, 1000 }}, &.{.{ 400, 400, 600, 600 }}), try arena.dupe(Finding, &.{.length(0)}) });
    try shapes.append(arena, .{ "corner_touching", try two(arena, &.{.{ 0, 0, 1000, 1000 }}, &.{.{ 1000, 1000, 2000, 2000 }}), try arena.dupe(Finding, &.{Finding.length(0).pinned(1000, 1000)}) });
    try shapes.append(arena, .{ "same_layer_only", try two(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 550, 0, 1050, 2000 } }, &.{}), &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_spacing_diff/{s}", .{s[0]}), &.{"DRC-047"}, diff_deck, s[1], &.{ .{ "sd", s[2] }, .{ "ds", s[2] } }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.fixture(arena, "min_spacing_diff/vacuous", &.{"DRC-047"}, diff_deck, try two(arena, &.{.{ 0, 0, 500, 2000 }}, &.{}), &.{ .{ "sd", &.{} }, .{ "ds", &.{} } }));
}

test "every min_spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived from the definitions
    // of `min_spacing` and `min_spacing_diff` (the doc comments above): the
    // gap swept one grid step either side of its limit, Euclidean corner
    // gaps at d·√2, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
