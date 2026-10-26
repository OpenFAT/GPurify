//! `forbidden` (DRC-006), a maximum area through it (DRC-018), and
//! `aspect_ratio` (DRC-022) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`forbidden`, `max_area`, `ratio`,
//! `aspect_ratio`).
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
    try forbiddenInto(arena, out);
    try maxAreaInto(arena, depth, out);
    try aspectRatioInto(arena, depth, out);
}

// ---- private ----

/// Rectangles on `layer`.
fn on(arena: Allocator, layer: []const u8, boxes: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, boxes);
    return l;
}

/// `a` on `met1` and `b` on `met2`.
fn both(arena: Allocator, a: []const c.Rect, b: []const c.Rect) !Layout {
    var l = try on(arena, "met1", a);
    try c.rects(arena, &l, "met2", b);
    return l;
}

/// A `region` square `[0, 1000]²` and `boxes` on `met1`.
fn region(arena: Allocator, boxes: []const c.Rect) !Layout {
    var l = try on(arena, "region", &.{.{ 0, 0, 1000, 1000 }});
    try c.rects(arena, &l, "met1", boxes);
    return l;
}

/// `forbidden` (DRC-006): every shape of the layer, as stored and not
/// merged, one finding each measuring its area without holes, at a vertex
/// of its outer ring (which one is not stated, so not pinned).
///
/// `forbidden(met2)`: two overlapping and two abutting rectangles (two
/// each), a holed square, nothing on `met2`. `forbidden(met1 and met2)`: an
/// overlap, shapes that only touch or meet at a corner (no shape), two
/// overlapping `met1` rectangles whose union meets `met2` (the derived
/// layer is merged: one shape). `forbidden(met1 not region)`: a shape
/// straddling the region, and shapes inside it or filling it exactly.
fn forbiddenInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var holed: Layout = .{};
    try holed.polygon(arena, "met2", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 400, 400, 600, 600 }));
    const Case = struct { []const u8, []const u8, Layout, []const Finding };
    const cases_in = [_]Case{
        .{ "overlapping_drawn", "met2", try on(arena, "met2", &.{ .{ 0, 0, 100, 100 }, .{ 50, 0, 150, 100 } }), &.{ .area(10_000), .area(10_000) } },
        .{ "abutting_drawn", "met2", try on(arena, "met2", &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } }), &.{ .area(10_000), .area(10_000) } },
        .{ "holed", "met2", holed, &.{.area(960_000)} },
        .{ "other_layer_only", "met2", try on(arena, "met1", &.{.{ 0, 0, 100, 100 }}), &.{} },
        .{ "and_overlap", "met1 and met2", try both(arena, &.{.{ 0, 0, 1000, 1000 }}, &.{.{ 500, 0, 1500, 1000 }}), &.{.area(500_000)} },
        .{ "and_touching", "met1 and met2", try both(arena, &.{.{ 0, 0, 1000, 1000 }}, &.{.{ 1000, 0, 2000, 1000 }}), &.{} },
        .{ "and_corner", "met1 and met2", try both(arena, &.{.{ 0, 0, 1000, 1000 }}, &.{.{ 1000, 1000, 2000, 2000 }}), &.{} },
        .{ "and_merged_operand", "met1 and met2", try both(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 0, 500, 1000, 1500 } }, &.{.{ 500, 0, 1500, 1500 }}), &.{.area(750_000)} },
        .{ "outside_region", "met1 not region", try region(arena, &.{.{ 500, 0, 1500, 1000 }}), &.{.area(500_000)} },
        .{ "inside_region", "met1 not region", try region(arena, &.{.{ 200, 200, 800, 800 }}), &.{} },
        .{ "fills_region", "met1 not region", try region(arena, &.{.{ 0, 0, 1000, 1000 }}), &.{} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_in) |k| {
        const deck = try c.threeLayerDeck(arena, try std.fmt.allocPrint(arena, "rule f forbidden({s})", .{k[1]}));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "forbidden/{s}", .{k[0]}), &.{"DRC-006"}, deck, k[2], &.{.{ "f", k[3] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "forbidden", &.{"DRC-006"}, "rule f forbidden(met1)", &.{"f"}));
}

/// A maximum area, `forbidden(met1.with_area(> 10000nm2))` (DRC-018),
/// beside one at 35000: `with_area` reads merged shapes without their
/// holes, and `forbidden` reports each with its area. At the limit is legal
/// (`>`).
///
/// A 100-wide rectangle whose height is swept around 100; a square with a
/// 1 nm bite or bump; two halves that merge into 10100; a holed square of
/// 30000 whose filled area (40000) would break the 35000 rule.
fn maxAreaInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule ma forbidden(met1.with_area(> 10000nm2))\nrule mb forbidden(met1.with_area(> 35000nm2))");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 100)) |h| {
        const findings: []const Finding = if (h > 100) try arena.dupe(Finding, &.{.area(100 * h)}) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "rect/{s}", .{try c.side(arena, h, 100)}), try c.met1(arena, &.{.{ 0, 0, 100, h }}), findings });
    }
    var bite: Layout = .{};
    try bite.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 99 }, .{ 99, 99 }, .{ 99, 100 }, .{ 0, 100 } });
    try shapes.append(arena, .{ "bite", bite, &.{} });
    var bump: Layout = .{};
    try bump.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 1, 100 }, .{ 1, 101 }, .{ 0, 101 } });
    try shapes.append(arena, .{ "bump", bump, &.{.area(10_001)} });
    try shapes.append(arena, .{ "halves", try c.met1(arena, &.{ .{ 0, 0, 50, 101 }, .{ 50, 0, 100, 101 } }), &.{.area(10_100)} });
    var holed: Layout = .{};
    try holed.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 200, 200 }, .{ 50, 50, 150, 150 }));
    try shapes.append(arena, .{ "holed", holed, &.{.area(30_000)} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "max_area/{s}", .{s[0]}), &.{"DRC-018"}, deck, s[1], &.{ .{ "ma", s[2] }, .{ "mb", &.{} } }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "max_area", &.{"DRC-018"}, "rule ma forbidden(met1.with_area(> 10000nm2))", &.{"ma"}));
}

/// A finding whose measured value is a ratio.
fn ratio(r: f64) Finding {
    return .{ .measured = .ratio(r), .at = null };
}

/// A bar `l` long and 100 wide against a ratio of `limit` hundredths: its
/// ratio pinned at the bar's centre when above.
fn barRatio(arena: Allocator, l: i64, limit: i64) ![]const Finding {
    if (l <= limit) return &.{};
    return arena.dupe(Finding, &.{c.pin(ratio(@as(f64, @floatFromInt(l)) / 100.0), 100, l)});
}

/// `aspect_ratio(met1) <= 3` (`aspect_ratio`, DRC-022: sky130 capm.6
/// "maximum aspect ratio (length/width)", li.2 "max ratio of length to
/// width"): one finding per merged figure whose bounding box's longer side
/// over its shorter is above the limit, measuring that ratio, at the centre
/// of the figure's first rectangle.
///
/// Oracle: ratios fixed by construction, the limit swept one grid step
/// either side (a 100-wide bar 299, 300 and 301 long; and 249, 250, 251
/// under a limit of 2.5, a ratio the deck writes as a decimal): at the
/// limit is legal. The 301 bar drawn as two abutting halves (each 1.5
/// alone: a check that does not merge passes it); an L of two 400 x 100
/// arms (its box is square: a check per drawn row or per rectangle flags
/// each arm at 4); a square joined at a corner to a 400 x 100 bar (one
/// figure of box 500 x 200 under the corner model, 2.5; the bar alone would
/// read 4); a 1000 x 200 ring (5, its hole changes nothing); an empty layer.
fn aspectRatioInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule ar aspect_ratio(met1) <= 3");
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 300)) |l| {
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "aspect_ratio/bar/{s}", .{try c.side(arena, l, 300)}), &.{"DRC-022"}, deck, try c.met1(arena, &.{.{ 0, 0, 100, l }}), &.{.{ "ar", try barRatio(arena, l, 300) }}));
    }
    var ring: Layout = .{};
    try ring.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 200 }, .{ 100, 50, 900, 150 }));
    const Case = struct { []const u8, Layout, []const Finding };
    const named = [_]Case{
        .{ "halves", try c.met1(arena, &.{ .{ 0, 0, 100, 150 }, .{ 0, 150, 100, 301 } }), &.{ratio(3.01)} },
        .{ "l_of_two_long_arms", try c.met1(arena, &.{ .{ 0, 0, 400, 100 }, .{ 0, 100, 100, 400 } }), &.{} },
        .{ "bar_joined_at_a_corner", try c.met1(arena, &.{ .{ 0, 0, 100, 100 }, .{ 100, 100, 500, 200 } }), &.{} },
        .{ "ring", ring, &.{ratio(5.0)} },
    };
    for (named) |k| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "aspect_ratio/{s}", .{k[0]}), &.{"DRC-022"}, deck, k[1], &.{.{ "ar", k[2] }}));
    const decimal = try c.oneLayerDeck(arena, "rule ar aspect_ratio(met1) <= 2.5");
    for (try c.sweep(arena, depth, 250)) |l| {
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "aspect_ratio/decimal/{s}", .{try c.side(arena, l, 250)}), &.{"DRC-022"}, decimal, try c.met1(arena, &.{.{ 0, 0, 100, l }}), &.{.{ "ar", try barRatio(arena, l, 250) }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "aspect_ratio", &.{"DRC-022"}, "rule ar aspect_ratio(met1) <= 3", &.{"ar"}));
}

test "every forbidden, max_area and aspect_ratio fixture holds" {
    // Oracle: each fixture's expected answer, derived from the rule's
    // definition (the doc comments above): areas and ratios fixed by
    // construction, limits swept one grid step either side, under every
    // symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
