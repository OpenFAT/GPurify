//! `eol_spacing` (DRC-029, DRC-031) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`eol_spacing`).
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

const rule = "rule eol eol_space(met1; eol_width: 200nm) >= 101nm";

/// `eol_space(met1; eol_width: 200nm) >= 101nm` (`eol_spacing`, DRC-029,
/// DRC-031): an edge strictly shorter than 200 is an end of line; its
/// keep-out is its own span pushed 101 straight out. One finding per pair
/// of separate figures with an edge in a keep-out, measuring the nearest
/// approach, at its midpoint.
///
/// Tip to tip and tip to side (not told apart), the gap swept; the line
/// width swept around `eol_width` at a gap of 50 (a 200-wide end is not an
/// end of line); two lines side by side (no end faces the other); a wide
/// shape just beside the keep-out (no sideways reach, though Euclidean 51
/// away); a line end facing its own figure (one figure, not a pair). Ends
/// are the merged layer's edges: a wide end drawn as strips is no end, nor
/// is an edge two shapes share, whose keep-out would run through its own
/// figure; a hole's short edge keeps out into the hole, not through the
/// band beyond it.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 101;
    const deck = try c.oneLayerDeck(arena, rule);
    var cases: std.ArrayList(Fixture) = .empty;
    const both: []const []const u8 = &.{ "DRC-029", "DRC-031" };
    const ends: []const []const u8 = &.{"DRC-029"};
    for (try c.sweep(arena, depth, limit)) |g| {
        const findings: []const Finding = if (g < limit) try arena.dupe(Finding, &.{c.pin(.length(g), 100, 4000 + g)}) else &.{};
        const tag = try c.side(arena, g, limit);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_spacing/tip_to_tip/{s}", .{tag}), both, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 0, 2000 + g, 100, 4000 + g } }), &.{.{ "eol", findings }}));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_spacing/tip_to_side/{s}", .{tag}), both, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ -1000, 2000 + g, 1100, 2200 + g } }), &.{.{ "eol", findings }}));
    }
    for (try c.sweep(arena, depth, 200)) |w| {
        const findings: []const Finding = if (w < 200) try arena.dupe(Finding, &.{c.pin(.length(50), w, 4050)}) else &.{};
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_spacing/line_width/{s}", .{try c.side(arena, w, 200)}), ends, deck, try c.met1(arena, &.{ .{ 0, 0, w, 2000 }, .{ 0, 2050, w, 4050 } }), &.{.{ "eol", findings }}));
    }
    const clean = [_]struct { []const u8, Layout }{
        .{ "side_by_side", try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 150, 0, 250, 2000 } }) },
        .{ "beside_the_keep_out", try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 110, 2050, 2000, 4000 } }) },
        .{ "facing_its_own_figure", try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 0, -500, 1000, 0 }, .{ 900, -500, 1000, 1550 }, .{ 0, 1050, 1000, 1550 } }) },
    };
    for (clean) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_spacing/{s}", .{s[0]}), ends, deck, s[1], &.{.{ "eol", &.{} }}));
    // A 300-wide line drawn as three 100-wide strips: its end is 300 wide,
    // not an end of line, so the line end 50 past it is legal.
    try cases.append(arena, try c.fixture(arena, "eol_spacing/wide_end_drawn_as_strips", ends, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 100, 0, 200, 2000 }, .{ 200, 0, 300, 2000 }, .{ 0, 2050, 300, 4050 } }), &.{.{ "eol", &.{} }}));
    // A 100-wide line under a 50-thick bar 1100 wide, and a 500-wide shape
    // 30 above the bar. The line's top edge is the bar's to share, not an
    // end of line; read as one, its keep-out runs up through the bar to the
    // shape, 80 from the line. The bar's 50-long sides are ends, keeping
    // out sideways.
    try cases.append(arena, try c.fixture(arena, "eol_spacing/shared_edge_is_no_end", ends, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ -500, 1000, 600, 1050 }, .{ -200, 1080, 300, 1500 } }), &.{.{ "eol", &.{} }}));
    // A square hole with a 100-wide, 50-deep slot in its top. The slot's top
    // edge is an end of line whose keep-out is pushed out of the material,
    // down into the hole, where an 800-wide island's top edge sits 90 below
    // it: marked between the two, at (500, 1005), not in the island (F66).
    var slot: Layout = .{};
    try slot.polygon(arena, "met1", &.{ .{ 0, -500 }, .{ 1500, -500 }, .{ 1500, 1600 }, .{ -500, 1600 }, .{ -500, -500 }, .{ 0, -500 }, .{ 0, 0 }, .{ 0, 1000 }, .{ 450, 1000 }, .{ 450, 1050 }, .{ 550, 1050 }, .{ 550, 1000 }, .{ 1000, 1000 }, .{ 1000, 0 }, .{ 0, 0 } });
    try slot.rect(arena, "met1", 100, 100, 900, 960);
    try cases.append(arena, try c.fixture(arena, "eol_spacing/hole_end_of_line", ends, deck, slot, &.{.{ "eol", &.{c.pin(.length(90), 450 + 550, 1050 + 960)} }}));
    // The other way: a 100-wide slot hole in a ring whose band past the
    // slot's end is 50 thick, and a wide shape 30 beyond the band. The
    // slot's end keeps out down the slot, so nothing is near it; pushed the
    // wrong way it would reach through the band to the shape, 80 away.
    var band: Layout = .{};
    try band.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 200, 1000 }, .{ 50, 50, 150, 950 }));
    try band.rect(arena, "met1", -500, 1030, 700, 1500);
    try cases.append(arena, try c.fixture(arena, "eol_spacing/hole_end_keeps_out_of_the_band", ends, deck, band, &.{.{ "eol", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "eol_spacing", ends, rule, &.{"eol"}));
}

test "every eol_spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived from `eol_spacing`'s
    // definition (the doc comment above): the gap and the line width swept
    // one grid step either side of their limits, under every symmetry at
    // two translations.
    try c.checkGenerated(fixturesInto);
}
