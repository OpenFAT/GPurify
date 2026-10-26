//! `min_width` (DRC-010), its Euclidean neck, as exhaustive fixtures.
//! Ported from tests/exhaustive/drc_dimension.rs (`min_width`,
//! `min_width_neck`).
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
    try minWidthInto(arena, depth, out);
    try minWidthNeckInto(arena, depth, out);
}

// ---- private ----

/// `width(met1) >= 100nm` (`min_width`, DRC-010): one finding per merged
/// figure narrower than the limit, measuring its narrowest width, at the
/// middle of that gap.
///
/// Swept at the limit and one step either side: at the limit is legal
/// (`>=`). Shapes:
/// - a plain bar;
/// - an L whose one arm carries the width under test and whose other arm
///   is wide, so a check that measures the bounding box, or only the first
///   arm it meets, is caught;
/// - the bar drawn as two abutting halves, each narrower than the limit,
///   which merge into one legal or illegal figure: a check that does not
///   merge flags halves that are fine together; the same with overlapping
///   halves, and a narrow rectangle drawn inside the bar (it adds no width);
/// - a plus and a U, each with two narrow arms but one figure, so one
///   finding (a check reporting per arm or per drawn rectangle reports more);
/// - a narrow tab on a wide plate (a bounding-box width passes it);
/// - a ring, drawn as one holed polygon and as four abutting bands, whose
///   band is the width (a check blind to holes sees only the outer square);
/// - three separate bars, two of them too narrow: one finding each.
fn minWidthInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    const deck = try c.oneLayerDeck(arena, "rule w width(met1) >= 100nm");
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |w| {
        const narrow = w < limit;
        const sd = try c.side(arena, w, limit);
        // One finding at the doubled midpoint when the width is short.
        const one = struct {
            fn at(a: Allocator, short: bool, width: i64, x2: i64, y2: i64) ![]const Finding {
                return if (short) a.dupe(Finding, &.{c.pin(.length(width), x2, y2)}) else &.{};
            }
        }.at;
        const unpinned: []const Finding = if (narrow) try arena.dupe(Finding, &.{.length(w)}) else &.{};
        const Case = struct { []const u8, Layout, []const Finding };
        var shapes: std.ArrayList(Case) = .empty;
        try shapes.append(arena, .{ "bar", try c.met1(arena, &.{.{ 0, 0, w, 2000 }}), try one(arena, narrow, w, w, 2000) });
        var l_shape: Layout = .{};
        try l_shape.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 600 }, .{ w, 600 }, .{ w, 2000 }, .{ 0, 2000 } });
        try shapes.append(arena, .{ "l_shape", l_shape, try one(arena, narrow, w, w, 2600) });
        try shapes.append(arena, .{ "abutting_halves", try c.met1(arena, &.{ .{ 0, 0, @divTrunc(w, 2), 2000 }, .{ @divTrunc(w, 2), 0, w, 2000 } }), try one(arena, narrow, w, w, 2000) });
        try shapes.append(arena, .{ "overlapping_halves", try c.met1(arena, &.{ .{ 0, 0, 60, 2000 }, .{ 40, 0, w, 2000 } }), try one(arena, narrow, w, w, 2000) });
        // A narrow rectangle drawn inside a wide one adds no width of its own.
        try shapes.append(arena, .{ "narrow_inside_wide", try c.met1(arena, &.{ .{ 0, 0, w, 2000 }, .{ 20, 0, 50, 2000 } }), try one(arena, narrow, w, w, 2000) });
        // Four arms of width w meet in a w-square: four tied gaps.
        const lo: i64 = 1000;
        const hi = 1000 + w;
        var plus: Layout = .{};
        try plus.polygon(arena, "met1", &.{ .{ lo, 0 }, .{ hi, 0 }, .{ hi, lo }, .{ 2100, lo }, .{ 2100, hi }, .{ hi, hi }, .{ hi, 2100 }, .{ lo, 2100 }, .{ lo, hi }, .{ 0, hi }, .{ 0, lo }, .{ lo, lo } });
        try shapes.append(arena, .{ "plus", plus, unpinned });
        try shapes.append(arena, .{ "plus_overlapping", try c.met1(arena, &.{ .{ 0, lo, 2100, hi }, .{ lo, 0, hi, 2100 } }), unpinned });
        // Two arms of width w on a 500-high base: two tied gaps, one figure.
        var u_shape: Layout = .{};
        try u_shape.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 2000 }, .{ 1000 - w, 2000 }, .{ 1000 - w, 500 }, .{ w, 500 }, .{ w, 2000 }, .{ 0, 2000 } });
        try shapes.append(arena, .{ "u_shape", u_shape, unpinned });
        try shapes.append(arena, .{ "u_three_rects", try c.met1(arena, &.{ .{ 0, 0, 1000, 500 }, .{ 0, 500, w, 2000 }, .{ 1000 - w, 500, 1000, 2000 } }), unpinned });
        var tab: Layout = .{};
        try tab.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 900 + w, 2000 }, .{ 900 + w, 3000 }, .{ 900, 3000 }, .{ 900, 2000 }, .{ 0, 2000 } });
        try shapes.append(arena, .{ "tab_on_plate", tab, try one(arena, narrow, w, 1800 + w, 5000) });
        try shapes.append(arena, .{ "tab_touching_plate", try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 900, 2000, 900 + w, 3000 } }), try one(arena, narrow, w, 1800 + w, 5000) });
        var ring: Layout = .{};
        try ring.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ w, w, 1000 - w, 1000 - w }));
        try shapes.append(arena, .{ "ring", ring, unpinned });
        try shapes.append(arena, .{ "ring_of_bands", try c.met1(arena, &.{ .{ 0, 0, 1000, w }, .{ 0, 1000 - w, 1000, 1000 }, .{ 0, w, w, 1000 - w }, .{ 1000 - w, w, 1000, 1000 - w } }), unpinned });
        // Bars of widths w, 60 and 140, 2000 apart: one finding per narrow bar.
        var bars: Layout = .{};
        var found: std.ArrayList(Finding) = .empty;
        for ([_]i64{ w, 60, 140 }, 0..) |width, i| {
            const x: i64 = @as(i64, @intCast(i)) * 2000;
            try bars.rect(arena, "met1", x, 0, x + width, 2000);
            if (width < limit) try found.append(arena, c.pin(.length(width), 2 * x + width, 2000));
        }
        try shapes.append(arena, .{ "three_bars", bars, found.items });
        for (shapes.items) |s| try cases.append(arena, try c.counted(arena, try std.fmt.allocPrint(arena, "min_width/{s}/{s}", .{ s[0], sd }), &.{"DRC-010"}, deck, s[1], "w", s[2]));
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "min_width", &.{"DRC-010"}, "rule w width(met1) >= 100nm", &.{"w"}));
}

/// `min_width`'s Euclidean neck (DRC-010): two squares overlapping at a
/// corner by `d` leave a neck between two concave corners `d·√2` apart,
/// which no facing pair of edges sees. The rule measures it Euclidean,
/// floors the reported value, and compares exactly; the marker is the
/// corners' midpoint.
///
/// Swept two ways: `d` at a fixed limit, and the limit around a fixed
/// `d = 70` (neck √9800 ≈ 98.99), so a limit of 99 fails and reports 98. A
/// Chebyshev or Manhattan neck, or a neck rounded up, reads differently.
fn minWidthNeckInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var overlaps: std.ArrayList(i64) = .empty;
    var limits: std.ArrayList(i64) = .empty;
    switch (depth) {
        .merge => {
            try overlaps.appendSlice(arena, &.{ 70, 71, 72 });
            try limits.appendSlice(arena, &.{ 98, 99, 100 });
        },
        .nightly => {
            for (2..101) |d| try overlaps.append(arena, @intCast(d));
            for (90..111) |l| try limits.append(arena, @intCast(l));
        },
    }
    var cases: std.ArrayList(Fixture) = .empty;
    for (overlaps.items) |d| try neckInto(arena, d, 100, &cases);
    for (limits.items) |limit| if (limit != 100) try neckInto(arena, 70, limit, &cases);
    try c.everyPlacementInto(arena, cases.items, out);
}

fn neckInto(arena: Allocator, d: i64, limit: i64, cases: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, try std.fmt.allocPrint(arena, "rule w width(met1) >= {d}nm", .{limit}));
    const gap2 = 2 * d * d;
    const findings: []const Finding = if (gap2 < limit * limit) try arena.dupe(Finding, &.{c.pin(.length(c.floorSqrt(gap2)), 2000 - d, 2000 - d)}) else &.{};
    const far = 2000 - d;
    var polygon: Layout = .{};
    try polygon.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 1000 - d }, .{ far, 1000 - d }, .{ far, far }, .{ 1000 - d, far }, .{ 1000 - d, 1000 }, .{ 0, 1000 } });
    const drawings = [_]struct { []const u8, Layout }{
        .{ "overlapping", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 1000 - d, 1000 - d, far, far } }) },
        .{ "polygon", polygon },
    };
    for (drawings) |dr| try cases.append(arena, try c.counted(arena, try std.fmt.allocPrint(arena, "min_width/neck_{s}/d{d}/limit{d}", .{ dr[0], d, limit }), &.{"DRC-010"}, deck, dr[1], "w", findings));
}

test "every min_width fixture holds" {
    // Oracle: each fixture's expected answer, derived from `min_width`'s
    // definition (the doc comments above): the width swept one grid step
    // either side of its limit, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
