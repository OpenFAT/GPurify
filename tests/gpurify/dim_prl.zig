//! `prl_spacing` (DRC-026) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`prl_spacing`).
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

/// `prl_space(met1; prl: 500nm) >= 101nm` (`prl_spacing`, DRC-026): pairs
/// in different figures whose run (the longest length over which edges of
/// their merged figures facing each other at most 101 apart project onto
/// each other) is at least 500 are held to 101. One finding per pair, at
/// the midpoint of the nearest points.
///
/// The run swept around 500 at a gap of 100 (at 500 the limit applies); the
/// gap swept at a long run; an L whose box would overstate the run against
/// a short bar (its facing edges run 100: clean, F49); a diagonal pair (no
/// run); touching shapes (one figure); a wire drawn as segments, each
/// shorter than the threshold, which runs its whole length beside the
/// other wire.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 101;
    const rule = "rule prl prl_space(met1; prl: 500nm) >= 101nm";
    const deck = try c.oneLayerDeck(arena, rule);
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 500)) |r| {
        const findings: []const Finding = if (r >= 500) try one(arena, c.pin(.length(100), 300, 4000 - r)) else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "run/{s}", .{try c.side(arena, r, 500)}), deck, try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 200, 2000 - r, 300, 4000 - r } }), findings);
    }
    for (try c.sweep(arena, depth, limit)) |g| {
        const findings: []const Finding = if (g < limit) try one(arena, c.pin(.length(g), 200 + g, 2000)) else &.{};
        try case(arena, &cases, try std.fmt.allocPrint(arena, "gap/{s}", .{try c.side(arena, g, limit)}), deck, try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 100 + g, 0, 200 + g, 2000 } }), findings);
    }
    // The L's arm faces the bar's end, x = 100 against x = 200, over
    // y = 1900..2000: a run of 100. Its long arm's top, y = 100, faces the
    // bar's underside 1800 away, past the limit. The boxes would overlap by
    // 1300 on x.
    var l_box: Layout = .{};
    try l_box.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 100 }, .{ 100, 100 }, .{ 100, 2000 }, .{ 0, 2000 } });
    try l_box.rect(arena, "met1", 200, 1900, 1500, 2000);
    try case(arena, &cases, "l_box_overstates_run", deck, l_box, &.{});
    try case(arena, &cases, "diagonal", deck, try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 } }), &.{});
    try case(arena, &cases, "touching", deck, try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 100, 0, 200, 2000 } }), &.{});
    // A line 100 from another that runs 2000 beside it, drawn as four
    // 500-long segments: the figures run 2000 alongside, past a 600
    // threshold, so each segment's pair is held to the limit; read off each
    // segment's box, the run would be 500 and the wire would escape it.
    try case(arena, &cases, "segmented_run", try c.oneLayerDeck(arena, "rule prl prl_space(met1; prl: 600nm) >= 101nm"), try c.met1(arena, &.{ .{ 0, 0, 100, 2000 }, .{ 200, 0, 300, 500 }, .{ 200, 500, 300, 1000 }, .{ 200, 1000, 300, 1500 }, .{ 200, 1500, 300, 2000 } }), &.{
        Finding.length(100).pinned(150, 250),
        Finding.length(100).pinned(150, 750),
        Finding.length(100).pinned(150, 1250),
        Finding.length(100).pinned(150, 1750),
    });
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "prl_spacing", &.{"DRC-026"}, rule, &.{"prl"}));
}

// ---- private ----

fn one(arena: Allocator, f: Finding) ![]const Finding {
    return arena.dupe(Finding, &.{f});
}

fn case(arena: Allocator, cases: *std.ArrayList(Fixture), shape: []const u8, deck: []const u8, layout: Layout, findings: []const Finding) !void {
    try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "prl_spacing/{s}", .{shape}), &.{"DRC-026"}, deck, layout, &.{.{ "prl", findings }}));
}

test "every prl_spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived from `prl_spacing`'s
    // definition (the doc comment above): the run and the gap swept one
    // grid step either side, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
