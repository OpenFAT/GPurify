//! `notch` (DRC-024) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`notch`).
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

/// `notch(met1) >= 101nm` (`notch`, DRC-024): one finding per merged figure,
/// at the middle of its narrowest notch, the gap between two parallel edges
/// of one figure facing each other across empty space. At the limit is legal.
///
/// A U drawn as one polygon and as three touching rectangles (merged first);
/// the same gap between two separate bars, which is spacing and not a notch;
/// a slot hole (a narrow hole is a notch); a comb with two notches (one
/// finding, the narrower); a figure whose only narrow gap is corner to corner
/// (not measured).
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 101;
    const deck = try c.oneLayerDeck(arena, "rule n notch(met1) >= 101nm");
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |g| {
        const sd = try c.side(arena, g, limit);
        const narrow = g < limit;
        const Case = struct { []const u8, Layout, []const Finding };
        var u_shape: Layout = .{};
        try u_shape.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000 + g, 0 }, .{ 1000 + g, 2000 }, .{ 500 + g, 2000 }, .{ 500 + g, 500 }, .{ 500, 500 }, .{ 500, 2000 }, .{ 0, 2000 } });
        var slot: Layout = .{};
        try slot.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 2000, 2000 }, .{ 900, 500, 900 + g, 1500 }));
        const shapes = [_]Case{
            .{ "u_shape", u_shape, try one(arena, narrow, g, 1000 + g, 2500) },
            .{ "u_three_rects", try c.met1(arena, &.{ .{ 0, 0, 1000 + g, 500 }, .{ 0, 500, 500, 2000 }, .{ 500 + g, 500, 1000 + g, 2000 } }), try one(arena, narrow, g, 1000 + g, 2500) },
            .{ "separate_bars", try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 500 + g, 0, 1000 + g, 2000 } }), &.{} },
            .{ "slot_hole", slot, try one(arena, narrow, g, 1800 + g, 2000) },
            // Teeth g apart, then 50 apart: one finding, the 50.
            .{ "comb", try c.met1(arena, &.{ .{ 0, 0, 500, 2500 }, .{ 500, 0, 2000, 500 }, .{ 500, 500 + g, 2000, 1000 + g }, .{ 500, 1050 + g, 2000, 1550 + g } }), try arena.dupe(Finding, &.{c.pin(.length(50), 2500, 2050 + 2 * g)}) },
        };
        for (shapes) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "notch/{s}/{s}", .{ s[0], sd }), &.{"DRC-024"}, deck, s[1], &.{.{ "n", s[2] }}));
    }
    // Two squares 50 apart corner to corner, joined round the far side; every
    // facing gap is at least 450.
    try cases.append(arena, try c.fixture(arena, "notch/corner_gap", &.{"DRC-024"}, deck, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 }, .{ 0, 1000, 500, 3000 }, .{ 0, 2500, 2050, 3000 }, .{ 1550, 2050, 2050, 2500 } }), &.{.{ "n", &.{} }}));
    // An island 50 inside a 1000 hole: the gap is spacing between two
    // figures, and the hole itself is 1000 wide.
    var island: Layout = .{};
    try island.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 3000, 3000 }, .{ 1000, 1000, 2000, 2000 }));
    try island.rect(arena, "met1", 1050, 1050, 1950, 1950);
    try cases.append(arena, try c.fixture(arena, "notch/island_in_hole", &.{"DRC-024"}, deck, island, &.{.{ "n", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "notch", &.{"DRC-024"}, "rule n notch(met1) >= 101nm", &.{"n"}));
}

// ---- private ----

/// One finding of `g` at the doubled midpoint when the gap is short.
fn one(arena: Allocator, short: bool, g: i64, x2: i64, y2: i64) ![]const Finding {
    return if (short) arena.dupe(Finding, &.{c.pin(.length(g), x2, y2)}) else &.{};
}

test "every notch fixture holds" {
    // Oracle: each fixture's expected answer, derived from `notch`'s
    // definition (the doc comment above): the gap swept one grid step either
    // side of its limit, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
