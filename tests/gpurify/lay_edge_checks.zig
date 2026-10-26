//! Checks on edge layers (`edge_min_length`, `edge_spacing`,
//! `edge_enclosure`) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`edge_min_length`, `edge_spacing`,
//! `edge_enclosure`).
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

/// The catalog rows every edge check proves.
const catalog: []const []const u8 = &.{ "DRC-051", "DRC-122" };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try edgeMinLengthInto(arena, out);
    try edgeSpacingInto(arena, out);
    try edgeEnclosureInto(arena, out);
}

// ---- private ----

/// `n` findings each measuring `v` when `v` is below `limit`, else none.
fn repeatedBelow(arena: Allocator, v: i64, limit: i64, n: usize) ![]const Finding {
    if (v >= limit) return &.{};
    const values = try arena.alloc(i64, n);
    @memset(values, v);
    return c.lengths(arena, values);
}

/// `length(tap.edges() and diff.edges()) >= 100nm` (`edge_min_length`,
/// DRC-051, sky130 difftap.4): one finding per butting edge shorter than
/// the limit, measuring it.
///
/// Shapes: a tap whose whole side butts a taller diffusion, and one butting
/// only part of its side, swept; a tap overlapping the diffusion, which
/// leaves no butting edge.
fn edgeMinLengthInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    const deck = try c.newDeck(arena, &.{ "diff", "tap" }, "layer butt = tap.edges() and diff.edges()\nrule difftap.4 length(butt) >= 100nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(limit)) |sw| {
        const len = sw.value;
        var whole: Layout = .{};
        try whole.rect(arena, "tap", 0, 0, 500, len);
        try whole.rect(arena, "diff", 500, -200, 1500, 800);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_min_length/whole_side/{s}", .{sw.side}), catalog, deck, whole, &.{.{ "difftap.4", try c.below(arena, len, limit) }}));
        var part: Layout = .{};
        try part.rect(arena, "tap", 0, 0, 500, 300);
        try part.rect(arena, "diff", 500, 300 - len, 1500, 1000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_min_length/part_side/{s}", .{sw.side}), catalog, deck, part, &.{.{ "difftap.4", try c.below(arena, len, limit) }}));
    }
    var overlapping: Layout = .{};
    try overlapping.rect(arena, "tap", 0, 0, 600, 50);
    try overlapping.rect(arena, "diff", 500, -200, 1500, 800);
    try cases.append(arena, try c.fixture(arena, "edge_min_length/overlapping", catalog, deck, overlapping, &.{.{ "difftap.4", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `space(butt) >= 200nm` on the butting edges (`edge_spacing`, DRC-051,
/// sky130 difftap.5), and `space(tap.edges(), nsdm.edges()) >= 200nm`: one
/// finding per pair of parallel edges closer than the limit, measured edge
/// to edge, Euclidean; perpendicular edges are not paired.
///
/// Shapes: a tap between two diffusions (its two butting edges face each
/// other across its width); two taps whose butting edges are collinear, end
/// to end; a tap inside nsdm, whose four facing pairs are the margin apart.
fn edgeSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 200;
    const deck_butt = try c.newDeck(arena, &.{ "diff", "tap" }, "layer butt = tap.edges() and diff.edges()\nrule difftap.5 space(butt) >= 200nm\n");
    const deck_two = try c.newDeck(arena, &.{ "tap", "nsdm" }, "rule e2 space(tap.edges(), nsdm.edges()) >= 200nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(limit)) |sw| {
        const g = sw.value;
        var between: Layout = .{};
        try between.rect(arena, "diff", -1000, -500, 0, 1000);
        try between.rect(arena, "tap", 0, 0, g, 500);
        try between.rect(arena, "diff", g, -500, g + 1000, 1000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_spacing/between/{s}", .{sw.side}), catalog, deck_butt, between, &.{.{ "difftap.5", try c.below(arena, g, limit) }}));
        var end_to_end: Layout = .{};
        try end_to_end.rect(arena, "tap", 0, 0, 500, 300);
        try end_to_end.rect(arena, "tap", 0, 300 + g, 500, 600 + g);
        try end_to_end.rect(arena, "diff", 500, -500, 1500, 1500);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_spacing/end_to_end/{s}", .{sw.side}), catalog, deck_butt, end_to_end, &.{.{ "difftap.5", try c.below(arena, g, limit) }}));
        var two: Layout = .{};
        try two.rect(arena, "tap", 0, 0, 400, 400);
        try two.rect(arena, "nsdm", -g, -g, 400 + g, 400 + g);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_spacing/two_layers/{s}", .{sw.side}), catalog, deck_two, two, &.{.{ "e2", try repeatedBelow(arena, g, limit, 4) }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One `edge_enclosure` fixture: `layout` with the diffusion
/// `[0, 1000] x [0, 500]` added after it.
fn enclosureCase(arena: Allocator, name: []const u8, deck: []const u8, layout: Layout, findings: []const Finding) !Fixture {
    var l = layout;
    try l.rect(arena, "diff", 0, 0, 1000, 500);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "edge_enclosure/{s}", .{name}), catalog, deck, l, &.{.{ "nsd.5a", findings }});
}

/// `enclosure(diff.edges(), nsdm) >= 100nm` and `enclosure(diff.edges() not
/// tap.edges(), nsdm) >= 100nm` (`edge_enclosure`, DRC-051, sky130 nsd.5a):
/// one finding per edge whose strip straight out, along its whole length, is
/// covered less than the limit deep, measuring the covered depth.
///
/// Diffusion is `[0, 1000] x [0, 500]`. Shapes: one side's margin swept, and
/// all four; nsdm stopping short of the diffusion's top (three edges at 0);
/// nsdm missing only a corner square diagonally off the diffusion (clean:
/// the documented diagonal blind spot); no nsdm at all; a hole in nsdm 50 nm
/// out from one edge (covered 50 deep); the butting edge to a tap excluded,
/// with nsdm not reaching over the tap; and a diffusion ring, whose hole
/// edges face into the hole: nsdm filling it covers them, nsdm reaching
/// 50 nm into it covers them 50 deep.
fn edgeEnclosureInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    const deck_all = try c.newDeck(arena, &.{ "diff", "tap", "nsdm" }, "rule nsd.5a enclosure(diff.edges(), nsdm) >= 100nm\n");
    const deck_butt = try c.newDeck(arena, &.{ "diff", "tap", "nsdm" }, "rule nsd.5a enclosure(diff.edges() not tap.edges(), nsdm) >= 100nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        var one_side: Layout = .{};
        try one_side.rect(arena, "nsdm", -300, -300, 1000 + m, 800);
        try cases.append(arena, try enclosureCase(arena, try std.fmt.allocPrint(arena, "one_side/{s}", .{sw.side}), deck_all, one_side, try c.below(arena, m, limit)));
        var every_side: Layout = .{};
        try every_side.rect(arena, "nsdm", -m, -m, 1000 + m, 500 + m);
        try cases.append(arena, try enclosureCase(arena, try std.fmt.allocPrint(arena, "every_side/{s}", .{sw.side}), deck_all, every_side, try repeatedBelow(arena, m, limit, 4)));
        var butting: Layout = .{};
        try butting.rect(arena, "tap", -400, 0, 0, 500);
        try butting.rect(arena, "nsdm", 0, -m, 1000 + m, 500 + m);
        try cases.append(arena, try enclosureCase(arena, try std.fmt.allocPrint(arena, "butting_excluded/{s}", .{sw.side}), deck_butt, butting, try repeatedBelow(arena, m, limit, 3)));
    }
    var short_of_top: Layout = .{};
    try short_of_top.rect(arena, "nsdm", -300, -300, 1300, 400);
    try cases.append(arena, try enclosureCase(arena, "short_of_top", deck_all, short_of_top, try c.lengths(arena, &.{ 0, 0, 0 })));
    var corner_missing: Layout = .{};
    try corner_missing.polygon(arena, "nsdm", &.{ .{ -300, -300 }, .{ 1300, -300 }, .{ 1300, 500 }, .{ 1000, 500 }, .{ 1000, 800 }, .{ -300, 800 } });
    try cases.append(arena, try enclosureCase(arena, "corner_missing", deck_all, corner_missing, &.{}));
    try cases.append(arena, try enclosureCase(arena, "no_nsdm", deck_all, .{}, try c.lengths(arena, &.{ 0, 0, 0, 0 })));
    var hole_in_strip: Layout = .{};
    try c.ring(arena, &hole_in_strip, "nsdm", .{ -300, -300, 1300, 800 }, .{ 1050, 100, 1150, 400 });
    try cases.append(arena, try enclosureCase(arena, "hole_in_strip", deck_all, hole_in_strip, try c.lengths(arena, &.{50})));
    // A diffusion ring: its hole's edges face into the hole, so nsdm reaching
    // 50 nm into the hole covers them 50 deep, and nsdm filling it covers them.
    const Ring = struct { []const u8, ?c.Rect, []const Finding };
    const rings = [_]Ring{
        .{ "ring_hole_covered", null, &.{} },
        .{ "ring_hole_partly", .{ 350, 350, 650, 650 }, try c.lengths(arena, &.{ 50, 50, 50, 50 }) },
    };
    for (rings) |r| {
        var l: Layout = .{};
        if (r[1]) |hole| {
            try c.ring(arena, &l, "nsdm", .{ -200, -200, 1200, 1200 }, hole);
        } else try l.rect(arena, "nsdm", -200, -200, 1200, 1200);
        try c.ring(arena, &l, "diff", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_enclosure/{s}", .{r[0]}), catalog, deck_all, l, &.{.{ "nsd.5a", r[2] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every edge-layer check fixture holds" {
    // Oracle: each butting or facing edge, and each strip's covered depth,
    // is a number the layout was drawn to have; every finding follows from
    // it and the rule's limit, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
