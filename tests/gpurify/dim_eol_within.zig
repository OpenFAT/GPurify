//! `eol_within_spacing` (DRC-029), LEF's `SPACING ENDOFLINE`, as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs (`lef_eol`,
//! `LINE`, `eol_within_spacing`).
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

/// A 1000 wide line ending at y = 0: its top is an end of line (shorter
/// than 1300, both corners convex) facing up, its keep-out x in
/// (-600, 1600), y from 0 up to 1200.
const line = c.Rect{ 0, -5000, 1000, 0 };

/// `eol_space(met1; eol_width: 1300nm, within: 600nm, parallel: ..,
/// end_to_end: ..) >= 1200nm` (`eol_within_spacing`, DRC-029), LEF's
/// `SPACING ENDOFLINE`: a facing edge of another figure in an end's keep-out
/// (the end widened by `within` each side, out to the limit) fails by its
/// depth; one finding per pair of figures, at the middle of the stretch
/// where the facing edge overlaps the widened end.
///
/// Without `parallel`: a 5000 wide bar's depth swept around 1200 (LEF
/// Figure 1-23 a, b); a 2000 square 300 above, its side swept around 600
/// past the end (Figure 1-23 c, d: within is "less than"); a 1000 long edge
/// whose one corner is concave (no end, clean); an end facing its own figure.
/// With `PARALLELEDGE 1.1 WITHIN 0.5` (Figure 1-24), a bar 1000 above fails
/// only with a neighbour beside the line: its distance swept around 1100,
/// its top swept around 500 behind the end's line; none at all, clean. With
/// `TWOEDGES`, one side is not enough and two are. With `end_to_end:
/// 1400nm`, two ends facing each other need 1400 (swept), and an end facing
/// a side still 1200.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    const plain = try lefEol(arena, "none", "none");
    const parallel = try lefEol(arena, "(space: 1100nm, within: 500nm, two_edges: false)", "none");
    const two_edges = try lefEol(arena, "(space: 1100nm, within: 500nm, two_edges: true)", "none");
    const ends = try lefEol(arena, "none", "1400nm");
    // A 7000 wide bar 1000 above the line: inside the keep-out, its bottom
    // overlapping the widened end over x = -600..1600.
    const bar_above = c.Rect{ -3000, 1000, 4000, 2000 };
    const at_1000 = try one(arena, c.pin(.length(1000), 1000, 1000));
    for (try c.sweep(arena, depth, 1200)) |g| {
        const findings: []const Finding = if (g < 1200) try one(arena, c.pin(.length(g), 1000, g)) else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "depth/{s}", .{try c.side(arena, g, 1200)}), plain, try c.met1(arena, &.{ line, .{ -2000, g, 3000, g + 1000 } }), findings);
    }
    for (try c.sweep(arena, depth, 600)) |d| {
        const findings: []const Finding = if (d < 600) try one(arena, c.pin(.length(300), 2600 + d, 300)) else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "within/{s}", .{try c.side(arena, d, 600)}), plain, try c.met1(arena, &.{ line, .{ 1000 + d, 300, 3000 + d, 2300 } }), findings);
    }
    // A tab on a base: its left side is 1000 long but its lower corner is
    // concave, so it is no end, and the wide shape 500 to its left is clean.
    try case(arena, &cases, "concave_corner_is_no_end", plain, try c.met1(arena, &.{ .{ -3000, -5000, 4000, -1000 }, .{ 0, -1000, 1000, 0 }, .{ -3000, -900, -500, 3000 } }), &.{});
    // The line's end faces a bar 1000 above that a frame joins to the line.
    try case(arena, &cases, "facing_its_own_figure", plain, try c.met1(arena, &.{ line, .{ 0, -6000, 3000, -5000 }, .{ 2000, -6000, 3000, 1000 }, .{ -2000, 1000, 3000, 2000 } }), &.{});
    for (try c.sweep(arena, depth, 1100)) |p| {
        const findings: []const Finding = if (p < 1100) at_1000 else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "parallel_space/{s}", .{try c.side(arena, p, 1100)}), parallel, try c.met1(arena, &.{ line, bar_above, .{ -p - 2000, -5000, -p, 0 } }), findings);
    }
    for (try c.sweep(arena, depth, -500)) |t| {
        const findings: []const Finding = if (t > -500) at_1000 else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "parallel_within/{s}", .{try c.side(arena, t, -500)}), parallel, try c.met1(arena, &.{ line, bar_above, .{ -2500, -5000, -500, t } }), findings);
    }
    try case(arena, &cases, "no_parallel_edge", parallel, try c.met1(arena, &.{ line, bar_above }), &.{});
    try case(arena, &cases, "two_edges/one_side", two_edges, try c.met1(arena, &.{ line, bar_above, .{ -2500, -5000, -500, 0 } }), &.{});
    try case(arena, &cases, "two_edges/both_sides", two_edges, try c.met1(arena, &.{ line, bar_above, .{ -2500, -5000, -500, 0 }, .{ 1500, -5000, 3500, 0 } }), at_1000);
    for (try c.sweep(arena, depth, 1400)) |g| {
        const findings: []const Finding = if (g < 1400) try one(arena, c.pin(.length(g), 1000, g)) else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "end_to_end/{s}", .{try c.side(arena, g, 1400)}), ends, try c.met1(arena, &.{ line, .{ 0, g, 1000, g + 5000 } }), findings);
    }
    try case(arena, &cases, "end_to_side_keeps_the_limit", ends, try c.met1(arena, &.{ line, .{ -2000, 1300, 3000, 2300 } }), &.{});
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "eol_within_spacing", &.{"DRC-029"}, "rule e eol_space(met1; eol_width: 1300nm, within: 600nm, parallel: none, end_to_end: none) >= 1200nm", &.{"e"}));
}

// ---- private ----

/// LEF/DEF 5.8 Example 1-18 in nanometres, `SPACING 1.2 ENDOFLINE 1.3
/// WITHIN 0.6`, with `parallel` and `end_to_end` as the deck writes them.
fn lefEol(arena: Allocator, parallel: []const u8, end_to_end: []const u8) ![]const u8 {
    return c.oneLayerDeck(arena, try std.fmt.allocPrint(arena, "rule e eol_space(met1; eol_width: 1300nm, within: 600nm, parallel: {s}, end_to_end: {s}) >= 1200nm", .{ parallel, end_to_end }));
}

fn one(arena: Allocator, f: Finding) ![]const Finding {
    return arena.dupe(Finding, &.{f});
}

fn case(arena: Allocator, cases: *std.ArrayList(Fixture), shape: []const u8, deck: []const u8, layout: Layout, findings: []const Finding) !void {
    try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_within_spacing/{s}", .{shape}), &.{"DRC-029"}, deck, layout, &.{.{ "e", findings }}));
}

test "every eol_within_spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived by construction from
    // LEF/DEF 5.8's `SPACING ENDOFLINE` (Example 1-18, Figures 1-23 and
    // 1-24), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
