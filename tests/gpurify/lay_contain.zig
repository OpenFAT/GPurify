//! Containment and insideness between layers (`must_contain`,
//! `must_be_inside`) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`must_contain`, `must_be_inside`).
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
    _ = depth;
    try mustContainInto(arena, out);
    try mustBeInsideInto(arena, out);
}

// ---- private ----

/// One `must_contain` fixture: `held` is what each tap figure holds.
fn containCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, held: []const u32) !Fixture {
    var one: std.ArrayList(Finding) = .empty;
    var two: std.ArrayList(Finding) = .empty;
    var most: std.ArrayList(Finding) = .empty;
    var exact: std.ArrayList(Finding) = .empty;
    for (held) |h| {
        if (h < 1) try one.append(arena, c.count(h));
        if (h < 2) try two.append(arena, c.count(h));
        if (h > 1) try most.append(arena, c.count(h));
        if (h != 2) try exact.append(arena, c.count(h));
    }
    return c.fixture(arena, try std.fmt.allocPrint(arena, "must_contain/{s}", .{name}), &.{ "DRC-048", "DRC-049" }, deck, layout, &.{
        .{ "one", one.items },
        .{ "two", two.items },
        .{ "most", most.items },
        .{ "exact", exact.items },
    });
}

/// The tap every `must_contain` case starts from: `[0, 1000] x [0, 500]`.
fn tap(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "tap", 0, 0, 1000, 500);
    return l;
}

/// `contains(tap, licon) >= 1`, `>= 2`, `<= 1` and `== 2` (`must_contain`,
/// DRC-048 and DRC-049), and `contains(nwell, ntap) >= 1` (DRC-085, tap
/// presence per well): one finding per merged outer figure holding fewer, or
/// more, merged inner figures entirely than its bound, measuring what it
/// holds.
///
/// Oracle: each case states how many licons each tap holds, by
/// construction, and every rule's findings follow from that count and the
/// rule's bound.
///
/// Shapes: none, one, two and three held; one touching the tap's edge from
/// inside (held); one straddling the edge and one touching it from outside
/// (not held); two touching or overlapping licons (one figure); a tap of two
/// abutting halves holding a licon across the seam; two taps; a licon in a
/// tap ring's hole (not held); an empty tap layer. For wells: tapped,
/// untapped, a tap across the well's edge.
fn mustContainInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck_tap = try c.newDeck(arena, &.{ "tap", "licon" }, "rule one contains(tap, licon) >= 1\nrule two contains(tap, licon) >= 2\n" ++
        "rule most contains(tap, licon) <= 1\nrule exact contains(tap, licon) == 2\n");
    var cases: std.ArrayList(Fixture) = .empty;
    const Held = struct { []const u8, []const c.Rect, u32 };
    const held = [_]Held{
        .{ "none", &.{}, 0 },
        .{ "one", &.{.{ 100, 100, 200, 200 }}, 1 },
        .{ "two", &.{ .{ 100, 100, 200, 200 }, .{ 400, 100, 500, 200 } }, 2 },
        .{ "three", &.{ .{ 100, 100, 200, 200 }, .{ 400, 100, 500, 200 }, .{ 700, 100, 800, 200 } }, 3 },
        .{ "edge_inside", &.{.{ 0, 0, 100, 100 }}, 1 },
        .{ "straddling", &.{.{ 950, 100, 1050, 200 }}, 0 },
        .{ "touching_outside", &.{.{ 1000, 100, 1100, 200 }}, 0 },
        .{ "touching_pair", &.{ .{ 100, 100, 200, 200 }, .{ 200, 100, 300, 200 } }, 1 },
        .{ "overlapping_pair", &.{ .{ 100, 100, 250, 200 }, .{ 200, 100, 300, 200 } }, 1 },
    };
    for (held) |h| {
        var l = try tap(arena);
        try c.rects(arena, &l, "licon", h[1]);
        try cases.append(arena, try containCase(arena, deck_tap, h[0], l, &.{h[2]}));
    }
    var halves: Layout = .{};
    try halves.rect(arena, "tap", 0, 0, 500, 500);
    try halves.rect(arena, "tap", 500, 0, 1000, 500);
    try halves.rect(arena, "licon", 450, 100, 550, 200);
    try cases.append(arena, try containCase(arena, deck_tap, "tap_halves", halves, &.{1}));
    var two_taps = try tap(arena);
    try two_taps.rect(arena, "licon", 100, 100, 200, 200);
    try two_taps.rect(arena, "tap", 2000, 0, 3000, 500);
    try cases.append(arena, try containCase(arena, deck_tap, "two_taps", two_taps, &.{ 1, 0 }));
    var empty_tap: Layout = .{};
    try empty_tap.rect(arena, "licon", 100, 100, 200, 200);
    try cases.append(arena, try containCase(arena, deck_tap, "empty_tap", empty_tap, &.{}));
    var in_hole: Layout = .{};
    try in_hole.rect(arena, "licon", 450, 200, 550, 300);
    try c.ring(arena, &in_hole, "tap", .{ 0, 0, 1000, 500 }, .{ 300, 100, 700, 400 });
    try cases.append(arena, try containCase(arena, deck_tap, "in_hole", in_hole, &.{0}));

    const deck_well = try c.newDeck(arena, &.{ "nwell", "ntap" }, "rule nwell.4 contains(nwell, ntap) >= 1\n");
    const Well = struct { []const u8, []const c.Rect, []const Finding };
    const wells = [_]Well{
        .{ "tapped", &.{.{ 100, 100, 300, 300 }}, &.{} },
        .{ "untapped", &.{}, &.{c.count(0)} },
        .{ "tap_across_edge", &.{.{ 1900, 100, 2100, 300 }}, &.{c.count(0)} },
    };
    for (wells) |w| {
        var l: Layout = .{};
        try l.rect(arena, "nwell", 0, 0, 2000, 1000);
        try c.rects(arena, &l, "ntap", w[1]);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "well_tap/{s}", .{w[0]}), &.{ "DRC-085", "DRC-048" }, deck_well, l, &.{.{ "nwell.4", w[2] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// The npc every `must_be_inside` case starts from: `[0, 1000]^2`.
fn npc(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "npc", 0, 0, 1000, 1000);
    return l;
}

/// `inside(licon, npc)` (`must_be_inside`, DRC-048): one finding per merged
/// licon figure not covered by one merged npc figure, measuring the area
/// left outside the npc.
///
/// npc is `[0, 1000]^2`. Shapes: inside; touching npc's edge from inside;
/// straddling the edge by 1, 50 and 99 nm of its 100; outside, and touching
/// from outside (the whole area); spanning a 10 nm gap between two npc
/// shapes (the gap's area); spanning the seam of two abutting npc shapes
/// (inside); a licon inside touching one that sticks out (one figure); a
/// licon in an npc ring's hole (all outside) and across the hole's edge
/// (half); each layer empty.
fn mustBeInsideInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "npc", "licon" }, "rule licon.18 inside(licon, npc)\n");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    const whole = try c.areas(arena, &.{10_000});

    var inside = try npc(arena);
    try inside.rect(arena, "licon", 100, 100, 200, 200);
    try shapes.append(arena, .{ "inside", inside, &.{} });
    var touching_inside = try npc(arena);
    try touching_inside.rect(arena, "licon", 0, 0, 100, 100);
    try shapes.append(arena, .{ "touching_inside", touching_inside, &.{} });
    var outside = try npc(arena);
    try outside.rect(arena, "licon", 1100, 400, 1200, 500);
    try shapes.append(arena, .{ "outside", outside, whole });
    var touching_outside = try npc(arena);
    try touching_outside.rect(arena, "licon", 1000, 400, 1100, 500);
    try shapes.append(arena, .{ "touching_outside", touching_outside, whole });
    var across_gap = try npc(arena);
    try across_gap.rect(arena, "npc", 1010, 0, 2000, 1000);
    try across_gap.rect(arena, "licon", 950, 400, 1060, 500);
    try shapes.append(arena, .{ "across_gap", across_gap, try c.areas(arena, &.{1000}) });
    var across_seam: Layout = .{};
    try across_seam.rect(arena, "npc", 0, 0, 1000, 1000);
    try across_seam.rect(arena, "npc", 1000, 0, 2000, 1000);
    try across_seam.rect(arena, "licon", 950, 400, 1050, 500);
    try shapes.append(arena, .{ "across_seam", across_seam, &.{} });
    var touching_licons = try npc(arena);
    try touching_licons.rect(arena, "licon", 800, 400, 900, 500);
    try touching_licons.rect(arena, "licon", 900, 400, 1100, 500);
    try shapes.append(arena, .{ "touching_licons", touching_licons, whole });
    try shapes.append(arena, .{ "empty_licon", try npc(arena), &.{} });
    var in_hole: Layout = .{};
    try in_hole.rect(arena, "licon", 450, 450, 550, 550);
    try c.ring(arena, &in_hole, "npc", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
    try shapes.append(arena, .{ "in_hole", in_hole, whole });
    var across_hole_edge: Layout = .{};
    try across_hole_edge.rect(arena, "licon", 250, 450, 350, 550);
    try c.ring(arena, &across_hole_edge, "npc", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
    try shapes.append(arena, .{ "across_hole_edge", across_hole_edge, try c.areas(arena, &.{5_000}) });
    var empty_npc: Layout = .{};
    try empty_npc.rect(arena, "licon", 0, 0, 100, 100);
    try shapes.append(arena, .{ "empty_npc", empty_npc, whole });
    for ([_]i64{ 1, 50, 99 }) |k| {
        var l = try npc(arena);
        try l.rect(arena, "licon", 1000 - k, 400, 1100 - k, 500);
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "straddling/{d}", .{k}), l, try c.areas(arena, &.{@as(i128, 100 - k) * 100}) });
    }
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "must_be_inside/{s}", .{s[0]}), &.{"DRC-048"}, deck, s[1], &.{.{ "licon.18", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every containment fixture holds" {
    // Oracle: each case states how many inner figures each outer figure
    // holds, or how much area lies outside, by construction; every rule's
    // findings follow from that and its bound, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
