//! `eol_keep_out` with its qualifiers, and `eol_extension_spacing`
//! (DRC-030), as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`eol_keep_out_qualifiers`,
//! `eol_keep_out`, `eol_extension_spacing`).
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

/// A 1000 wide line ending at y = 0 (drc_dimension.rs's `LINE`).
const line = c.Rect{ 0, -5000, 1000, 0 };

const keep_out_rule = "rule k eol_keep_out(met1; eol_width: 1300nm, backward: 200nm, side: 300nm, forward: 1000nm)";

const extension_rule = "rule x eol_extension_space(met1; eol_width: [110nm, 150nm], extension: [140nm, 120nm], end_to_end: [none, 130nm], side_length: none) >= 100nm";

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try eolKeepOutQualifiersInto(arena, depth, out);
    try eolKeepOutInto(arena, depth, out);
    try eolExtensionSpacingInto(arena, depth, out);
}

// ---- private ----

fn one(arena: Allocator, f: Finding) ![]const Finding {
    return arena.dupe(Finding, &.{f});
}

fn named(arena: Allocator, stem: []const u8, value: i64, limit: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ stem, try c.side(arena, value, limit) });
}

fn qualifierDeck(arena: Allocator, except: []const u8, corner: bool) ![]const u8 {
    return c.oneLayerDeck(arena, try std.fmt.allocPrint(arena, "rule k eol_keep_out(met1; eol_width: 1300nm, backward: 200nm, side: 300nm, forward: 1000nm, except_within: {s}, corner_only: {})", .{ except, corner }));
}

/// `eol_keep_out(met1; eol_width: 1300nm, backward: 200nm, side: 300nm,
/// forward: 1000nm, except_within: .., corner_only: ..)` (DRC-030):
/// `LEF58_EOLKEEPOUT 1.3 EXTENSION 0.2 0.3 1.0` with `EXCEPTWITHIN` and
/// `CORNERONLY` as `OpenROAD`'s `TritonRoute` reads them (no public text
/// defines `LEF58_EOLKEEPOUT`). The line's end keeps out x = -300..1300, y
/// = -200..1000.
///
/// Oracle: `TritonRoute`'s boxes (`getEolKeepOutQueryBox`,
/// `getEolKeepOutExceptWithinRects`), shapes by construction:
/// - `EXCEPTWITHIN 0.4 0.8`: the side zones are x = -800..-400 and
///   1400..1800, y = -200..1000; a 1500 tall block from x = -250 to a right
///   side swept around 1400 intrudes over 1550 x 500 and is exempt only once
///   it reaches into the right zone with a positive area (1401);
/// - `CORNERONLY`: a block's lower-left corner at (500, y), y swept around
///   1000, intrudes (one vertex) only strictly inside the box; a bar crossing
///   the whole box with no vertex in it is no intruder, though the plain rule
///   flags its 1600 x 500 inside.
fn eolKeepOutQualifiersInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    const except = try qualifierDeck(arena, "(low: 400nm, high: 800nm)", false);
    for (try c.sweep(arena, depth, 1400)) |w| {
        const findings: []const Finding = if (w <= 1400) try one(arena, c.pin(.area(1550 * 500), 1050, 1500)) else &.{};
        try cases.append(arena, try c.fixture(arena, try named(arena, "eol_keep_out_qualifiers/except_within", w, 1400), &.{"DRC-030"}, except, try c.met1(arena, &.{ line, .{ -250, 500, w, 2000 } }), &.{.{ "k", findings }}));
    }
    const corner = try qualifierDeck(arena, "none", true);
    for (try c.sweep(arena, depth, 1000)) |y| {
        const findings: []const Finding = if (y < 1000) try one(arena, c.pin(c.count(1), 1000, 2 * y)) else &.{};
        try cases.append(arena, try c.fixture(arena, try named(arena, "eol_keep_out_qualifiers/corner_only", y, 1000), &.{"DRC-030"}, corner, try c.met1(arena, &.{ line, .{ 500, y, 3000, 3000 } }), &.{.{ "k", findings }}));
    }
    for ([_]bool{ true, false }) |corner_only| {
        const findings: []const Finding = if (corner_only) &.{} else try one(arena, c.pin(.area(1600 * 500), 1000, 1500));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_keep_out_qualifiers/crossing_bar/corner_only_{}", .{corner_only}), &.{"DRC-030"}, try qualifierDeck(arena, "none", corner_only), try c.met1(arena, &.{ line, .{ -3000, 500, 4000, 2000 } }), &.{.{ "k", findings }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `eol_keep_out(met1; eol_width: 1300nm, backward: 200nm, side: 300nm,
/// forward: 1000nm)` (`eol_keep_out`, DRC-030), `LEF58_EOLKEEPOUT 1.3
/// EXTENSION 0.2 0.3 1.0`: the line's end (1000 wide, both corners convex)
/// keeps out x = -300..1300, y = -200..1000; each other figure overlapping
/// that box with a positive area is one finding, measuring the area inside,
/// at the centre of its box.
///
/// The box's far side swept with a bar's bottom around y = 1000, its side
/// with a block's left side around x = 1300, its back with a block beside
/// the line whose top is swept around y = -200 (touching is outside). Two
/// figures inside are two findings; a bar drawn as two rectangles is one
/// figure, one finding with the summed area; the line's own figure turning
/// back into the box is not an intruder.
fn eolKeepOutInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, keep_out_rule);
    var cases: std.ArrayList(Fixture) = .empty;
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 1000)) |g| {
        const findings: []const Finding = if (g < 1000) try one(arena, c.pin(.area(1600 * (1000 - g)), 1000, g + 1000)) else &.{};
        try shapes.append(arena, .{ try named(arena, "forward", g, 1000), try c.met1(arena, &.{ line, .{ -2000, g, 3000, g + 500 } }), findings });
    }
    for (try c.sweep(arena, depth, 300)) |d| {
        const findings: []const Finding = if (d < 300) try one(arena, c.pin(.area((300 - d) * 500), 2300 + d, 1500)) else &.{};
        try shapes.append(arena, .{ try named(arena, "side", d, 300), try c.met1(arena, &.{ line, .{ 1000 + d, 500, 3000 + d, 2500 } }), findings });
    }
    for (try c.sweep(arena, depth, -200)) |b| {
        const findings: []const Finding = if (b > -200) try one(arena, c.pin(.area(200 * (b + 200)), 2400, b - 200)) else &.{};
        try shapes.append(arena, .{ try named(arena, "backward", b, -200), try c.met1(arena, &.{ line, .{ 1100, b - 2000, 3100, b } }), findings });
    }
    try shapes.append(arena, .{ "two_figures", try c.met1(arena, &.{ line, .{ -2000, 300, 200, 1800 }, .{ 700, 300, 2500, 1800 } }), try arena.dupe(Finding, &.{ c.pin(.area(350_000), -100, 1300), c.pin(.area(420_000), 2000, 1300) }) });
    try shapes.append(arena, .{ "one_figure_drawn_twice", try c.met1(arena, &.{ line, .{ -2000, 500, 500, 1500 }, .{ 500, 500, 3000, 1500 } }), try one(arena, c.pin(.area(800_000), 1000, 1500)) });
    try shapes.append(arena, .{ "own_figure_in_the_box", try c.met1(arena, &.{ line, .{ 0, -6000, 3000, -5000 }, .{ 2000, -6000, 3000, 1100 }, .{ -500, 600, 3000, 1100 } }), &.{} });
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_keep_out/{s}", .{s[0]}), &.{"DRC-030"}, deck, s[1], &.{.{ "k", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "eol_keep_out", &.{"DRC-030"}, keep_out_rule, &.{"k"}));
}

/// `eol_extension_space(met1; eol_width: [110nm, 150nm], extension:
/// [140nm, 120nm], end_to_end: [none, 130nm], side_length: none) >= 100nm`
/// (`eol_extension_spacing`, DRC-030): LEF/DEF 5.7's example
/// `EOLEXTENSIONSPACING 0.1 ENDOFLINE 0.11 EXTENSION 0.14 ENDOFLINE 0.15
/// EXTENSION 0.12 ENDTOEND 0.13` (p. 170). An end shorter than 110 is swept
/// 140 out of its line, one from 110 to below 150 swept 120, or 130 facing
/// another end head-on; each other figure with an edge past the end's line
/// closer than 100 to the swept box is one finding per end, measuring the
/// distance (floored), at the middle of the gap (floored).
///
/// Figure 1-73's four situations, each swept about its boundary: (a) a 100
/// wide end below a bar `g` above it, 140 + 100: failing below 240; (b) a
/// 100 wide end facing a 120 wide one, 140 + 130 + 100: below 370, found
/// from each end; (c) two 120 wide ends, 130 + 130 + 100: below 360; (d) a
/// 120 wide end beside a wire whose corner is 60 across and `h` above the
/// end's line, sqrt(60^2 + (h - 120)^2) from the box: below h = 200. A
/// 150 wide end is no end. A block 50 beside the end is no neighbour while
/// its top is on the end's line or behind it, and 50 away once past it.
fn eolExtensionSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, extension_rule);
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 240)) |g| {
        const findings: []const Finding = if (g < 240) try one(arena, c.pin(.length(g - 140), 100, g + 140)) else &.{};
        try shapes.append(arena, .{ try named(arena, "a_end_to_bar", g, 240), try c.met1(arena, &.{ up(100), .{ -1000, g, 1100, g + 500 } }), findings });
    }
    for (try c.sweep(arena, depth, 370)) |g| {
        const f = c.pin(.length(g - 270), 100, g + 10);
        const findings: []const Finding = if (g < 370) try arena.dupe(Finding, &.{ f, f }) else &.{};
        try shapes.append(arena, .{ try named(arena, "b_end_to_end_mixed", g, 370), try c.met1(arena, &.{ up(100), .{ 0, g, 120, g + 2000 } }), findings });
    }
    for (try c.sweep(arena, depth, 360)) |g| {
        const f = c.pin(.length(g - 260), 120, g);
        const findings: []const Finding = if (g < 360) try arena.dupe(Finding, &.{ f, f }) else &.{};
        try shapes.append(arena, .{ try named(arena, "c_end_to_end", g, 360), try c.met1(arena, &.{ up(120), .{ 0, g, 120, g + 2000 } }), findings });
    }
    for (try c.sweep(arena, depth, 200)) |h| {
        const d2 = 3600 + (h - 120) * (h - 120);
        const findings: []const Finding = if (h < 200) try one(arena, c.pin(.length(c.floorSqrt(d2)), 300, h + 120)) else &.{};
        try shapes.append(arena, .{ try named(arena, "d_end_to_side", h, 200), try c.met1(arena, &.{ up(120), .{ 180, h, 680, h + 2000 } }), findings });
    }
    try shapes.append(arena, .{ "not_an_end", try c.met1(arena, &.{ up(150), .{ -1000, 1, 1100, 501 } }), &.{} });
    for (try c.sweep(arena, depth, 1)) |top| {
        const findings: []const Finding = if (top >= 1) try one(arena, c.pin(.length(50), 250, top)) else &.{};
        try shapes.append(arena, .{ try named(arena, "behind", top, 1), try c.met1(arena, &.{ up(100), .{ 150, top - 1000, 1150, top } }), findings });
    }
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol_extension_spacing/{s}", .{s[0]}), &.{"DRC-030"}, deck, s[1], &.{.{ "x", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "eol_extension_spacing", &.{"DRC-030"}, extension_rule, &.{"x"}));
}

/// A `w` wide line ending at y = 0.
fn up(w: i64) c.Rect {
    return .{ 0, -2000, w, 0 };
}

test "every eol_keep_out and eol_extension_spacing fixture holds" {
    // Oracle: `TritonRoute`'s keep-out boxes for `LEF58_EOLKEEPOUT` and its
    // qualifiers, and LEF/DEF 5.7's `EOLEXTENSIONSPACING` example (p. 170,
    // Figure 1-73), shapes by construction, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
