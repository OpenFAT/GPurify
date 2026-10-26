//! `max_width` (DRC-012) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`max_width`).
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

/// `width(met1) <= 1001nm` (`max_width`, DRC-012): one finding per
/// connected region where a 1002 square fits, measuring the region's
/// narrowest gap, at its middle. At the limit is legal (`<=`).
///
/// Shapes: a bar (wide in one axis only below the limit); the bar as
/// abutting or overlapping halves (merged first); a plate with a thin tab
/// and an L with one wide arm (the region is the wide part, not the
/// bounding box); a ring whose band carries the width (wide all round only
/// when the band is); a dumbbell, two regions joined by a thin bar (two
/// findings, not one per figure), and joined by a wide bar (one region, its
/// narrowest gap the bar).
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 1001;
    const deck = try c.oneLayerDeck(arena, "rule mx width(met1) <= 1001nm");
    const catalog: []const []const u8 = &.{"DRC-012"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |w| {
        const wide = w > limit;
        const sd = try c.side(arena, w, limit);
        const Case = struct { []const u8, Layout, []const Finding };
        var shapes: std.ArrayList(Case) = .empty;
        try shapes.append(arena, .{ "bar", try c.met1(arena, &.{.{ 0, 0, w, 5000 }}), try one(arena, wide, w, w, 5000) });
        try shapes.append(arena, .{ "abutting_halves", try c.met1(arena, &.{ .{ 0, 0, @divTrunc(w, 2), 5000 }, .{ @divTrunc(w, 2), 0, w, 5000 } }), try one(arena, wide, w, w, 5000) });
        try shapes.append(arena, .{ "overlapping_halves", try c.met1(arena, &.{ .{ 0, 0, 600, 5000 }, .{ 400, 0, w, 5000 } }), try one(arena, wide, w, w, 5000) });
        var plate: Layout = .{};
        try plate.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ w, 0 }, .{ w, 3000 }, .{ 100, 3000 }, .{ 100, 5000 }, .{ 0, 5000 } });
        try shapes.append(arena, .{ "plate_with_tab", plate, try one(arena, wide, w, w, 3000) });
        try shapes.append(arena, .{ "plate_and_touching_tab", try c.met1(arena, &.{ .{ 0, 0, w, 3000 }, .{ 0, 3000, 100, 5000 } }), try one(arena, wide, w, w, 3000) });
        var l_arm: Layout = .{};
        try l_arm.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 5000, 0 }, .{ 5000, w }, .{ 500, w }, .{ 500, 5000 }, .{ 0, 5000 } });
        try shapes.append(arena, .{ "l_one_wide_arm", l_arm, try one(arena, wide, w, 5000, w) });
        // Four tied bands: the marker is not pinned.
        var ring: Layout = .{};
        try ring.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 2 * w + 2000, 2 * w + 2000 }, .{ w, w, w + 2000, w + 2000 }));
        try shapes.append(arena, .{ "ring", ring, if (wide) try arena.dupe(Finding, &.{.length(w)}) else &.{} });
        for (shapes.items) |s| try cases.append(arena, try c.counted(arena, try std.fmt.allocPrint(arena, "max_width/{s}/{s}", .{ s[0], sd }), catalog, deck, s[1], "mx", s[2]));
    }
    try cases.append(arena, try c.counted(arena, "max_width/dumbbell", catalog, deck, try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 3000, 0, 5000, 2000 }, .{ 2000, 900, 3000, 1000 } }), "mx", &.{ Finding.length(2000).pinned(1000, 1000), Finding.length(2000).pinned(4000, 1000) }));
    // The bar is wide too, so the plates and the bar are one region, and its
    // narrowest gap is the bar's height.
    try cases.append(arena, try c.counted(arena, "max_width/dumbbell_wide_bar", catalog, deck, try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 3000, 0, 5000, 2000 }, .{ 2000, 500, 3000, 1502 } }), "mx", &.{Finding.length(1002).pinned(2500, 1001)}));
    try cases.append(arena, try c.counted(arena, "max_width/two_plates", catalog, deck, try c.met1(arena, &.{ .{ 0, 0, 1500, 1500 }, .{ 3000, 0, 4600, 1600 } }), "mx", &.{ Finding.length(1500).pinned(750, 750), Finding.length(1600).pinned(3800, 800) }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "max_width", catalog, "rule mx width(met1) <= 1001nm", &.{"mx"}));
}

// ---- private ----

/// One finding at the doubled midpoint when the width is wide.
fn one(arena: Allocator, wide: bool, w: i64, x2: i64, y2: i64) ![]const Finding {
    return if (wide) arena.dupe(Finding, &.{c.pin(.length(w), x2, y2)}) else &.{};
}

test "every max_width fixture holds" {
    // Oracle: each fixture's expected answer, derived from `max_width`'s
    // definition (the doc comment above): the width swept one grid step
    // either side of its limit, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
