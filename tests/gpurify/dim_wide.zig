//! `wide_dependent_spacing` (DRC-025) and `attached_wide_spacing` (DRC-028)
//! as exhaustive fixtures. Ported from tests/exhaustive/drc_dimension.rs
//! (`wide_spacing`, `attached_wide_spacing`).
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

const limit: i64 = 301;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try wideSpacingInto(arena, depth, out);
    try attachedWideSpacingInto(arena, depth, out);
}

// ---- private ----

fn one(arena: Allocator, f: Finding) ![]const Finding {
    return arena.dupe(Finding, &.{f});
}

/// `wide_space(met1; width: 1000nm) >= 301nm` (`wide_dependent_spacing`,
/// DRC-025): the wide part is where a 1000 square fits (exactly 1000 wide
/// counts); pairs in different figures where either has one, measured from
/// that part, at the midpoint of the nearest points.
///
/// The plate width swept around the threshold beside a line 200 off; the
/// gap swept at a wide plate; a thin tab of a wide plate 200 from a line
/// that is 500 from the plate (not held); a 1200 x 1000 plate drawn as two
/// 1200 x 500 halves, neither wide alone (two row pairs, both held); two
/// thin lines; a thin line between the plate and another line (the far pair
/// has no wide part); a thin staircase 100 from the plate over
/// y = 1500..2000 whose box reaches far below, marked on the gap it measures
/// (F66); a plate whose facing side the wide part's rectangles cut in three,
/// marked at the middle of the whole side (F92).
fn wideSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule wd wide_space(met1; width: 1000nm) >= 301nm");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 1000)) |w| {
        const findings: []const Finding = if (w >= 1000) try one(arena, c.pin(.length(200), 2 * w + 200, 3000)) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "plate_width/{s}", .{try c.side(arena, w, 1000)}), try c.met1(arena, &.{ .{ 0, 0, w, 3000 }, .{ w + 200, 0, w + 300, 3000 } }), findings });
    }
    for (try c.sweep(arena, depth, limit)) |g| {
        const findings: []const Finding = if (g < limit) try one(arena, c.pin(.length(g), 4000 + g, 3000)) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "gap/{s}", .{try c.side(arena, g, limit)}), try c.met1(arena, &.{ .{ 0, 0, 2000, 3000 }, .{ 2000 + g, 0, 2100 + g, 3000 } }), findings });
    }
    var tab: Layout = .{};
    try tab.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, 3000 }, .{ 900, 3000 }, .{ 900, 2000 }, .{ 0, 2000 } });
    try tab.rect(arena, "met1", 1200, 2500, 1300, 3000);
    try shapes.append(arena, .{ "thin_tab_not_held", tab, &.{} });
    try shapes.append(arena, .{ "thin_tab_touching_not_held", try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 900, 2000, 1000, 3000 }, .{ 1200, 2500, 1300, 3000 } }), &.{} });
    try shapes.append(arena, .{ "wide_only_merged", try c.met1(arena, &.{ .{ 0, 0, 1200, 500 }, .{ 0, 500, 1200, 1000 }, .{ 1400, 0, 1500, 1000 } }), try arena.dupe(Finding, &.{ Finding.length(200).pinned(1300, 250), Finding.length(200).pinned(1300, 750) }) });
    try shapes.append(arena, .{ "two_thin_lines", try c.met1(arena, &.{ .{ 0, 0, 100, 3000 }, .{ 300, 0, 400, 3000 } }), &.{} });
    try shapes.append(arena, .{ "line_between", try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 2100, 0, 2200, 2000 }, .{ 2400, 0, 2500, 2000 } }), try one(arena, Finding.length(100).pinned(2050, 1000)) });
    // A 100-wide staircase: up from y = 1500 at x = 2100..2200, and an arm
    // x = 2200..2300 down to y = -1000. The plate's side x = 2000 faces it
    // nearest, 100, over y = 1500..2000 (the arm is 200 off): marked at
    // (2050, 1750). The boxes' gap is centred at (2050, 1000).
    var stair: Layout = .{};
    try stair.rect(arena, "met1", 0, 0, 2000, 2000);
    try stair.polygon(arena, "met1", &.{ .{ 2100, 1500 }, .{ 2200, 1500 }, .{ 2200, -1000 }, .{ 2300, -1000 }, .{ 2300, 1600 }, .{ 2200, 1600 }, .{ 2200, 4000 }, .{ 2100, 4000 } });
    try shapes.append(arena, .{ "staircase_beside_the_plate", stair, try one(arena, c.pin(.length(100), 2000 + 2100, 1500 + 2000)) });
    // A 3000 x 2000 plate with a 1000-wide arm below x = 500..1500, all of
    // it wide, and a line 200 above its top y = 2000. Cut into vertical
    // slabs, the wide part's top is three sides, x = 0..500, 500..1500 and
    // 1500..3000, in the orientations where it lies along x: one stretch,
    // marked at (1500, 2100), not at the longest piece's (2250, 2100) (F92).
    var slabs: Layout = .{};
    try slabs.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 500, 0 }, .{ 500, -1000 }, .{ 1500, -1000 }, .{ 1500, 0 }, .{ 3000, 0 }, .{ 3000, 2000 }, .{ 0, 2000 } });
    try slabs.rect(arena, "met1", 0, 2200, 3000, 2300);
    try shapes.append(arena, .{ "wide_side_cut_into_slabs", slabs, try one(arena, c.pin(.length(200), 3000, 2000 + 2200)) });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "wide_dependent_spacing/{s}", .{s[0]}), &.{"DRC-025"}, deck, s[1], &.{.{ "wd", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "wide_dependent_spacing", &.{"DRC-025"}, "rule wd wide_space(met1; width: 1000nm) >= 301nm", &.{"wd"}));
}

/// A finding for a squared gap under the limit, floored to a nm.
fn held(arena: Allocator, gap2: i64) ![]const Finding {
    return if (gap2 < limit * limit) one(arena, .length(c.floorSqrt(gap2))) else &.{};
}

/// `wide_space(met1; width: 1000nm, attached: 300nm) >= 301nm`
/// (`attached_wide_spacing`, DRC-028) beside the same rule without
/// `attached`: the wide part grown by 300 and clipped to its own figure
/// also holds what is attached to it.
///
/// A 2000 plate with a 100-wide finger up its middle, and a line 200 beside
/// the finger starting `a` above the plate: the attached stub reaches 300
/// up the finger, so the line is `min(a, √(200² + (a − 300)²))` from the
/// grown part and `a` from the plate. A thin line inside the grown square
/// but in another figure is not attached, so the line beyond it is not held.
fn attachedWideSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule wd wide_space(met1; width: 1000nm) >= 301nm\nrule aw wide_space(met1; width: 1000nm, attached: 300nm) >= 301nm");
    var starts: std.ArrayList(i64) = .empty;
    switch (depth) {
        .merge => try starts.appendSlice(arena, &.{ 100, 400, 600 }),
        .nightly => {
            var a: i64 = 100;
            while (a <= 700) : (a += 10) try starts.append(arena, a);
        },
    }
    var cases: std.ArrayList(Fixture) = .empty;
    for (starts.items) |a| {
        const stub2 = if (a <= 300) 200 * 200 else 200 * 200 + (a - 300) * (a - 300);
        var finger: Layout = .{};
        try finger.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, 3000 }, .{ 900, 3000 }, .{ 900, 2000 }, .{ 0, 2000 } });
        try finger.rect(arena, "met1", 1200, 2000 + a, 1300, 3000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "attached_wide_spacing/finger/a{d}", .{a}), &.{ "DRC-025", "DRC-028" }, deck, finger, &.{ .{ "wd", try held(arena, a * a) }, .{ "aw", try held(arena, @min(stub2, a * a)) } }));
    }
    const between = try one(arena, Finding.length(100).pinned(2050, 1000));
    try cases.append(arena, try c.fixture(arena, "attached_wide_spacing/line_between", &.{ "DRC-025", "DRC-028" }, deck, try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 2100, 0, 2200, 2000 }, .{ 2400, 0, 2500, 2000 } }), &.{ .{ "wd", between }, .{ "aw", between } }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "attached_wide_spacing", &.{"DRC-028"}, "rule aw wide_space(met1; width: 1000nm, attached: 300nm) >= 301nm", &.{"aw"}));
}

test "every wide spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived from the definitions
    // of `wide_dependent_spacing` and `attached_wide_spacing` (the doc
    // comments above): the plate width and the gap swept around their
    // limits, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
