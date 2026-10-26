//! `corner_to_corner` and `convex_corner_spacing` (DRC-032) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs
//! (`corner_to_corner`, `corner_deck`, `convex_corner_spacing`, and the
//! `diagonals`, `diagonal_pair` and `hook_beside_a_square` helpers they share
//! with `min_spacing`).
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

/// Two squares and what a Euclidean minimum of 101 finds between them.
const Pair = struct { layout: Layout, findings: []const Finding };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try cornerToCornerInto(arena, depth, out);
    try convexCornerSpacingInto(arena, depth, out);
}

// ---- private ----

/// The diagonal offsets swept for Euclidean corner gaps: `d` on both axes,
/// so the gap is `d·√2`, around a limit of 101 (70 gives 98.99, 71 gives
/// 100.41, 72 gives 101.82).
fn diagonals(arena: Allocator, depth: Depth) ![]const i64 {
    switch (depth) {
        .merge => return arena.dupe(i64, &.{ 70, 71, 72 }),
        .nightly => {
            const out = try arena.alloc(i64, 90);
            for (out, 1..) |*d, v| d.* = @intCast(v);
            return out;
        },
    }
}

/// Two 1000 squares `d` apart on both axes, and what a Euclidean minimum of
/// 101 finds: the floored gap, midway between the facing corners.
fn diagonalPair(arena: Allocator, first: []const u8, second: []const u8, d: i64) !Pair {
    var layout: Layout = .{};
    try layout.rect(arena, first, 0, 0, 1000, 1000);
    try layout.rect(arena, second, 1000 + d, 1000 + d, 2000 + d, 2000 + d);
    const gap2 = 2 * d * d;
    const findings: []const Finding = if (gap2 < 101 * 101) try arena.dupe(Finding, &.{c.pin(.length(c.floorSqrt(gap2)), 2000 + d, 2000 + d)}) else &.{};
    return .{ .layout = layout, .findings = findings };
}

/// The square `[0, 1000]²` and a hook beside it: the hook's left side,
/// x = 1050, runs down from y = 500 to -500, facing the square's right edge
/// 50 away over y = 0..500; its inner corner (1060, 1060) faces the square's
/// corner (1000, 1000) diagonally, √7200 = 84.9 away. The hook's box spans
/// y = -500..1500, so the boxes' gap is centred at (1025, 500), on neither.
fn hookBesideASquare(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 1000, 1000);
    try l.polygon(arena, "met1", &.{ .{ 1050, -500 }, .{ 1600, -500 }, .{ 1600, 1500 }, .{ 1060, 1500 }, .{ 1060, 1060 }, .{ 1500, 1060 }, .{ 1500, 500 }, .{ 1050, 500 } });
    return l;
}

fn one(arena: Allocator, f: Finding) ![]const Finding {
    return arena.dupe(Finding, &.{f});
}

/// `corner_space(met1) >= 101nm` (`corner_to_corner`, DRC-032): pairs in
/// different figures with convex corners of the merged layer facing each
/// other (each beyond the other on both axes), measured between the nearest
/// such corners, Euclidean, midway between those corners.
///
/// The diagonal swept; a pair 50 apart on x and 1 on y (apart on both:
/// 50.01, reported 50); the same with no gap on y (facing across an edge:
/// `min_spacing`'s); side by side; two squares 50 apart corner to corner but
/// one figure. An L whose arm's corner faces a square diagonally though its
/// box overlaps the square on y; a hook facing a square across an edge and,
/// further on, corner to corner (the corners are held); a square's corner
/// that a shape on top of it turns into a stretch of the figure's edge (not
/// a corner).
fn cornerToCornerInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule cc corner_space(met1) >= 101nm");
    var cases: std.ArrayList(Fixture) = .empty;
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try diagonals(arena, depth)) |d| {
        const p = try diagonalPair(arena, "met1", "met1", d);
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "diagonal/d{d}", .{d}), p.layout, p.findings });
    }
    try shapes.append(arena, .{ "skew", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1001, 2050, 2001 } }), try one(arena, .length(50)) });
    try shapes.append(arena, .{ "no_gap_on_one_axis", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1000, 2050, 2000 } }), &.{} });
    try shapes.append(arena, .{ "side_by_side", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 0, 2050, 1000 } }), &.{} });
    try shapes.append(arena, .{ "one_figure", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 }, .{ -500, 0, 0, 3500 }, .{ -500, 3000, 2050, 3500 }, .{ 1050, 2050, 2050, 3000 } }), &.{} });
    // An L with a 100-thick arm along the bottom to x = 1000, and a square
    // whose corner (1050, 150) is 50 past the arm's corner (1000, 100) on
    // both axes: √5000, 70, marked midway between the corners (F66). The L's
    // box reaches y = 1000, past the square's.
    var l_corner: Layout = .{};
    try l_corner.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 100, 100 }, .{ 100, 1000 }, .{ 0, 1000 } });
    try l_corner.rect(arena, "met1", 1050, 150, 1150, 250);
    try shapes.append(arena, .{ "l_corner_inside_its_box", l_corner, try one(arena, c.pin(.length(70), 1000 + 1050, 100 + 150)) });
    // A hook whose left side faces the square's right edge 50 away, below
    // y = 500, and whose inner corner (1060, 1060) faces the square's corner
    // (1000, 1000): √7200, 84, marked midway between the corners, not on the
    // edge gap (F66). The edge gap is `min_spacing`'s; the corners are this
    // rule's.
    try shapes.append(arena, .{ "corner_beside_an_edge_gap", try hookBesideASquare(arena), try one(arena, c.pin(.length(84), 1000 + 1060, 1000 + 1060)) });
    // A square with a 10-thick bar on top, flush with its right side: the
    // square's corner (1000, 1000) is a stretch of the figure's right edge,
    // which runs to y = 1010 and faces a shape from y = 1005 across 50. No
    // corner faces it.
    try shapes.append(arena, .{ "row_corner_inside_a_figure_edge", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 0, 1000, 1000, 1010 }, .{ 1050, 1005, 2050, 2005 } }), &.{} });
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "corner_to_corner/{s}", .{s[0]}), &.{"DRC-032"}, deck, s[1], &.{.{ "cc", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "corner_to_corner", &.{"DRC-032"}, "rule cc corner_space(met1) >= 101nm", &.{"cc"}));
}

/// `corner_space(met1; corner_to_corner: .., except_eol: ..) >= 101nm`.
fn cornerDeck(arena: Allocator, corner_to_corner: bool, except_eol: []const u8) ![]const u8 {
    return c.oneLayerDeck(arena, try std.fmt.allocPrint(arena, "rule c corner_space(met1; corner_to_corner: {}, except_eol: {s}) >= 101nm", .{ corner_to_corner, except_eol }));
}

/// `corner_space(met1; corner_to_corner: .., except_eol: ..) >= 101nm`
/// (`convex_corner_spacing`, DRC-032), `LEF58_CORNERSPACING CONVEXCORNER`:
/// facing convex corners of different figures measured by the larger axis
/// gap (`TritonRoute`'s `maxXY`), or Euclidean with `corner_to_corner`; one
/// finding per pair of figures, midway between the nearest corners.
///
/// Diagonal pairs `d` apart on both axes: the larger gap is `d`, the
/// Euclidean one `d·√2` (the same pairs as `corner_to_corner`). A pair 50
/// apart on y with the x gap swept around 101: the larger gap is the x gap,
/// and Euclidean it is clean at 100 (111.8). Side by side, no facing
/// corners; touching at a corner, one figure. With `except_eol: 200nm`, a
/// 100 wide line end's corners are exempt on either shape, and two wide
/// squares' are not.
fn convexCornerSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const square = try cornerDeck(arena, false, "none");
    const euclid = try cornerDeck(arena, true, "none");
    const eol = try cornerDeck(arena, false, "200nm");
    const Case = struct { []const u8, []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try diagonals(arena, depth)) |d| {
        const p = try diagonalPair(arena, "met1", "met1", d);
        const larger: []const Finding = if (d < 101) try one(arena, c.pin(.length(d), 2000 + d, 2000 + d)) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "diagonal/square/d{d}", .{d}), square, p.layout, larger });
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "diagonal/euclidean/d{d}", .{d}), euclid, p.layout, p.findings });
    }
    for (try c.sweep(arena, depth, 101)) |d| {
        const findings: []const Finding = if (d < 101) try one(arena, c.pin(.length(d), 2000 + d, 2050)) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "skewed/{s}", .{try c.side(arena, d, 101)}), square, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1000 + d, 1050, 2000 + d, 2050 } }), findings });
    }
    try shapes.append(arena, .{ "skewed_euclidean", euclid, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1100, 1050, 2100, 2050 } }), &.{} });
    try shapes.append(arena, .{ "side_by_side", square, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 0, 2050, 1000 } }), &.{} });
    try shapes.append(arena, .{ "one_figure", square, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1000, 1000, 2000, 2000 } }), &.{} });
    try shapes.append(arena, .{ "except_eol/line_end", eol, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 150, 1050, 1150, 2050 } }), &.{} });
    try shapes.append(arena, .{ "except_eol/other_line_end", eol, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 1150, 2050 } }), &.{} });
    try shapes.append(arena, .{ "except_eol/wide_corners", eol, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 } }), try one(arena, c.pin(.length(50), 2050, 2050)) });
    try shapes.append(arena, .{ "line_end_without_except", square, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 150, 1050, 1150, 2050 } }), try one(arena, c.pin(.length(50), 250, 2050)) });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "convex_corner_spacing/{s}", .{s[0]}), &.{"DRC-032"}, s[1], s[2], &.{.{ "c", s[3] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "convex_corner_spacing", &.{"DRC-032"}, "rule c corner_space(met1; corner_to_corner: false, except_eol: none) >= 101nm", &.{"c"}));
}

test "every corner spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived from the definitions
    // of `corner_to_corner` and `convex_corner_spacing` (the doc comments
    // above): diagonal gaps swept around the limit, Euclidean or by the
    // larger axis gap, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
