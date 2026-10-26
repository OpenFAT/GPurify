//! `min_area` (DRC-017) and `min_enclosed_area` (DRC-019) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs (`min_area`,
//! `min_enclosed_area`).
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

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try minAreaInto(arena, depth, out);
    try minEnclosedAreaInto(arena, depth, out);
}

// ---- private ----

/// `area(met1) >= 10000nm2` (`min_area`, DRC-017): one finding per merged
/// figure smaller than the limit, measuring its area without its holes. At
/// the limit is legal; the marker is "one of its rectangles", so not
/// pinned.
///
/// A 100-wide rectangle whose height is swept around 100; the same drawn as
/// two 50-wide halves (merged first); a square with a 1 nm bite (9999) or
/// bump (10001); a holed square whose filled area would pass.
fn minAreaInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const rule = "rule a area(met1) >= 10000nm2";
    const deck = try c.oneLayerDeck(arena, rule);
    const cat: []const []const u8 = &.{"DRC-017"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 100)) |h| {
        const findings: []const Finding = if (h < 100) try arena.dupe(Finding, &.{.area(100 * h)}) else &.{};
        const tag = try c.side(arena, h, 100);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_area/rect/{s}", .{tag}), cat, deck, try c.met1(arena, &.{.{ 0, 0, 100, h }}), &.{.{ "a", findings }}));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_area/halves/{s}", .{tag}), cat, deck, try c.met1(arena, &.{ .{ 0, 0, 50, h }, .{ 50, 0, 100, h } }), &.{.{ "a", findings }}));
    }
    var bite: Layout = .{};
    try bite.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 99 }, .{ 99, 99 }, .{ 99, 100 }, .{ 0, 100 } });
    try cases.append(arena, try c.fixture(arena, "min_area/bite", cat, deck, bite, &.{.{ "a", &.{.area(9999)} }}));
    var bump: Layout = .{};
    try bump.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 1, 100 }, .{ 1, 101 }, .{ 0, 101 } });
    try cases.append(arena, try c.fixture(arena, "min_area/bump", cat, deck, bump, &.{.{ "a", &.{} }}));
    var holed: Layout = .{};
    try holed.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 120, 120 }, .{ 20, 20, 100, 100 }));
    try cases.append(arena, try c.fixture(arena, "min_area/holed", cat, deck, holed, &.{.{ "a", &.{.area(8000)} }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "min_area", cat, rule, &.{"a"}));
}

/// `hole_area(met1) >= 10000nm2` (`min_enclosed_area`, DRC-019): one
/// finding per hole of the merged layer smaller than the limit, measuring
/// its area, at the centre of its box. At the limit is legal.
///
/// A plate with a 100-high hole whose width is swept around 100, drawn as
/// one holed polygon and as four touching bands (a hole only the union
/// has); two holes in one figure; the gap between two bars (not a hole).
fn minEnclosedAreaInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const rule = "rule h hole_area(met1) >= 10000nm2";
    const deck = try c.oneLayerDeck(arena, rule);
    const cat: []const []const u8 = &.{"DRC-019"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 100)) |hx| {
        const findings: []const Finding = if (hx < 100) try arena.dupe(Finding, &.{c.pin(.area(100 * hx), 800 + hx, 900)}) else &.{};
        const tag = try c.side(arena, hx, 100);
        var holed: Layout = .{};
        try holed.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 400, 400, 400 + hx, 500 }));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_enclosed_area/holed/{s}", .{tag}), cat, deck, holed, &.{.{ "h", findings }}));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_enclosed_area/bands/{s}", .{tag}), cat, deck, try c.met1(arena, &.{ .{ 0, 0, 1000, 400 }, .{ 0, 500, 1000, 1000 }, .{ 0, 400, 400, 500 }, .{ 400 + hx, 400, 1000, 500 } }), &.{.{ "h", findings }}));
    }
    try cases.append(arena, try c.fixture(arena, "min_enclosed_area/two_holes", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 2000, 400 }, .{ 0, 500, 2000, 1000 }, .{ 0, 400, 400, 500 }, .{ 480, 400, 1200, 500 }, .{ 1290, 400, 2000, 500 } }), &.{.{ "h", &.{
        Finding.area(8000).pinned(440, 450),
        Finding.area(9000).pinned(1245, 450),
    } }}));
    try cases.append(arena, try c.fixture(arena, "min_enclosed_area/gap_between_bars", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 599, 0, 1100, 2000 } }), &.{.{ "h", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "min_enclosed_area", cat, rule, &.{"h"}));
}

test "every min_area and hole_area fixture holds" {
    // Oracle: each fixture's expected answer, derived from `min_area` and
    // `min_enclosed_area`'s definitions (the doc comments above): each
    // limit swept one grid step either side, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
