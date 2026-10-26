//! Net-aware DRC rows as exhaustive fixtures: same- and different-net
//! spacing, net spacing on a derived layer, the distance to a well tap, a
//! short between two labelled nets, and floating interconnect. Ported from
//! tests/exhaustive/drc_overlay.rs (`net_spacing`, `derived_net_spacing`,
//! `tap_distance`, `labelled_short`, `dangling_metal`).
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
    try netSpacingInto(arena, out);
    try derivedNetSpacingInto(arena, out);
    try tapDistanceInto(arena, out);
    try labelledShortInto(arena, out);
    try danglingMetalInto(arena, out);
}

// ---- private ----

/// Two met1 bars `g` apart, 500 wide and 1000 tall.
fn bars(arena: Allocator, g: i64) !Layout {
    return c.met1(arena, &.{ .{ 0, 0, 500, 1000 }, .{ 500 + g, 0, 1000 + g, 1000 } });
}

/// `space(met1; nets: same) >= 200nm` and `space(met1; nets: different) >=
/// 300nm` (`net_spacing`, DRC-080): pairs of shapes in different merged
/// figures, on the same net or on different extracted nets, closer than the
/// limit.
///
/// Two met1 bars a swept gap apart: strapped through cuts and met2 into one
/// net (only the same-net rule sees them), or left apart (only the
/// different-net rule); and abutting (one figure, no pair).
fn netSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "cut", "met2" },
        \\connect conductors [met1, met2]
        \\connect touch_within_layer
        \\connect via cut [met1, met2]
        \\rule same space(met1; nets: same) >= 200nm
        \\rule diff space(met1; nets: different) >= 300nm
        \\
    );
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(200)) |sw| {
        const g = sw.value;
        var l = try bars(arena, g);
        try c.rects(arena, &l, "cut", &.{ .{ 200, 450, 300, 550 }, .{ 700 + g, 450, 800 + g, 550 } });
        try l.rect(arena, "met2", 100, 400, 900 + g, 600);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "net_spacing/strapped/{s}", .{sw.side}), &.{"DRC-080"}, deck, l, &.{ .{ "same", try c.below(arena, g, 200) }, .{ "diff", &.{} } }));
    }
    for (c.sweep3(300)) |sw| {
        var l = try bars(arena, sw.value);
        try l.rect(arena, "met2", 3000, 0, 3100, 100);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "net_spacing/separate/{s}", .{sw.side}), &.{"DRC-080"}, deck, l, &.{ .{ "same", &.{} }, .{ "diff", try c.below(arena, sw.value, 300) } }));
    }
    var abut = try bars(arena, 0);
    try abut.rect(arena, "met2", 3000, 0, 3100, 100);
    try cases.append(arena, try c.fixture(arena, "net_spacing/abutting", &.{"DRC-080"}, deck, abut, &.{ .{ "same", &.{} }, .{ "diff", &.{} } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// An HV well: n-well `[0, 3000]²` under `hvi`.
fn hv(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "nwell", 0, 0, 3000, 3000);
    try l.rect(arena, "hvi", -500, -500, 3500, 3500);
    return l;
}

/// Net spacing on a derived layer (DRC-081): sky130 hvnwell.8 "Min space
/// between HV_nwell and any nwell on different nets" 2 µm, the HV n-well the
/// n-well under `hvi`: `space(hv_nwell, nwell; nets: different) >= 2um`,
/// `hv_nwell = nwell.interacting(hvi)`, which takes the nets of the n-well
/// it is computed from.
///
/// Oracle: nets by construction: an HV well and a plain well 1999, 2000,
/// 2001 apart (separate wells: one finding of 1999); the same two joined by
/// an n-well bridge (one net: nothing, though 1000 apart); the HV well
/// against its own n-well (one net, overlapping: nothing; a derived shape on
/// no net would refuse the rule). And `nwell or hvi` with the `hvi` shape
/// bridging two separate wells is one shape over two nets: on no net, so
/// the rule refuses rather than guess.
fn derivedNetSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "nwell", "hvi" },
        \\connect conductors [nwell]
        \\connect touch_within_layer
        \\layer hv_nwell = nwell.interacting(hvi)
        \\rule hvnwell.8 space(hv_nwell, nwell; nets: different) >= 2um
        \\
    );
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(2000)) |sw| {
        var l = try hv(arena);
        try l.rect(arena, "nwell", 3000 + sw.value, 0, 6000 + sw.value, 3000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "derived_net_spacing/apart/{s}", .{sw.side}), &.{"DRC-081"}, deck, l, &.{.{ "hvnwell.8", try c.below(arena, sw.value, 2000) }}));
    }
    var bridged = try hv(arena);
    try c.rects(arena, &bridged, "nwell", &.{ .{ 4000, 0, 7000, 3000 }, .{ 3000, 1000, 4000, 2000 } });
    try cases.append(arena, try c.fixture(arena, "derived_net_spacing/bridged", &.{"DRC-081"}, deck, bridged, &.{.{ "hvnwell.8", &.{} }}));
    try cases.append(arena, try c.fixture(arena, "derived_net_spacing/alone", &.{"DRC-081"}, deck, try hv(arena), &.{.{ "hvnwell.8", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
    const either = try c.newDeck(arena, &.{ "nwell", "hvi" },
        \\connect conductors [nwell]
        \\connect touch_within_layer
        \\layer either = nwell or hvi
        \\rule e space(either, nwell; nets: different) >= 2um
        \\
    );
    var f: Fixture = .init("derived_net_spacing/two_nets_under_one_shape", &.{"DRC-081"}, either, harness.drc);
    try c.rects(arena, &f.layout, "nwell", &.{ .{ 0, 0, 1000, 1000 }, .{ 2000, 0, 3000, 1000 } });
    try f.layout.rect(arena, "hvi", 500, 400, 2500, 600);
    try f.claim(arena, .outcome("e", .refused));
    try out.append(arena, f);
}

/// A finding of `d` when it is past the tap limit.
fn above(arena: Allocator, d: i64, limit: i64) ![]const Finding {
    return if (d > limit) c.lengths(arena, &.{d}) else &.{};
}

/// `tap_distance(nwell, ntap) <= 1000nm` (`max_distance_to_tap`, ERC-D1):
/// one finding per well row whose furthest point is more than the limit
/// from every tap's edges, measuring that distance rounded up; a well with
/// no tap at all measures 2^40, and an empty well layer is skipped.
///
/// Shapes: a bar whose far end is 999/1000/1001 from the tap; a corner tap
/// with the far corner at Euclidean 999.2/1000/1000.8 (rounded up to 1001);
/// taps at both ends (the middle is furthest); two wells, one too long; no
/// tap; no well. And a well ring, derived as `nwell not hole`, with taps
/// all round it: the rule measures its hole as filled (one finding, 500),
/// and the hole's ring is not a well of its own (F34). And a tap with a
/// real hole (`ntap not hole`) over the whole well, whose centre lies in
/// the hole 1001/1000/999 from its edge (holes count).
fn tapDistanceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 1000;
    const deck = try c.newDeck(arena, &.{ "nwell", "ntap" }, "rule lu tap_distance(nwell, ntap) <= 1000nm\n");
    const cat: []const []const u8 = &.{"ERC-D1"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(limit)) |sw| {
        var l: Layout = .{};
        try l.rect(arena, "ntap", 0, 0, 100, 500);
        try l.rect(arena, "nwell", 0, 0, 100 + sw.value, 500);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "tap_distance/bar/{s}", .{sw.side}), cat, deck, l, &.{.{ "lu", try above(arena, sw.value, limit) }}));
    }
    const corners = [_]struct { i64, []const u8, []const Finding }{
        .{ 799, "below", &.{} },
        .{ 800, "at", &.{} },
        .{ 801, "above", try c.lengths(arena, &.{1001}) },
    };
    for (corners) |k| {
        var l: Layout = .{};
        try l.rect(arena, "ntap", 0, 0, 100, 100);
        try l.rect(arena, "nwell", 0, 0, 700, 100 + k[0]);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "tap_distance/corner/{s}", .{k[1]}), cat, deck, l, &.{.{ "lu", k[2] }}));
    }
    var both: Layout = .{};
    try both.rect(arena, "nwell", 0, 0, 3000, 100);
    try c.rects(arena, &both, "ntap", &.{ .{ 0, 0, 100, 100 }, .{ 2900, 0, 3000, 100 } });
    try cases.append(arena, try c.fixture(arena, "tap_distance/both_ends", cat, deck, both, &.{.{ "lu", try c.lengths(arena, &.{1400}) }}));
    var two: Layout = .{};
    try two.rect(arena, "nwell", 0, 0, 1500, 100);
    try two.rect(arena, "ntap", 0, 0, 100, 100);
    try two.rect(arena, "nwell", 0, 1000, 1000, 1100);
    try two.rect(arena, "ntap", 0, 1000, 100, 1100);
    try cases.append(arena, try c.fixture(arena, "tap_distance/two_wells", cat, deck, two, &.{.{ "lu", try c.lengths(arena, &.{1400}) }}));
    var no_tap: Layout = .{};
    try no_tap.rect(arena, "nwell", 0, 0, 1000, 100);
    try cases.append(arena, try c.fixture(arena, "tap_distance/no_tap", cat, deck, no_tap, &.{.{ "lu", try c.lengths(arena, &.{1 << 40}) }}));
    var no_well: Fixture = .init("tap_distance/no_well", cat, deck, harness.drc);
    try no_well.layout.rect(arena, "ntap", 0, 0, 100, 100);
    try no_well.claim(arena, .outcome("lu", .skipped));
    try cases.append(arena, no_well);
    const deck_ring = try c.newDeck(arena, &.{ "nwell", "hole", "ntap" }, "layer ring = nwell not hole\nrule lu tap_distance(ring, ntap) <= 200nm\n");
    var ring_well: Layout = .{};
    try ring_well.rect(arena, "nwell", 0, 0, 1000, 1000);
    try ring_well.rect(arena, "hole", 100, 100, 900, 900);
    try c.ring(arena, &ring_well, "ntap", .{ -100, -100, 1100, 1100 }, .{ 0, 0, 1000, 1000 });
    try cases.append(arena, try c.fixture(arena, "tap_distance/ring_well", cat, deck_ring, ring_well, &.{.{ "lu", try c.lengths(arena, &.{500}) }}));
    // A tap with a real hole, `ntap not hole`, over the whole well: the
    // well's centre is in the hole, `1100 - h` from its edge.
    const deck_tap_ring = try c.newDeck(arena, &.{ "nwell", "hole", "ntap" }, "layer tap_ring = ntap not hole\nrule lu tap_distance(nwell, tap_ring) <= 1000nm\n");
    for (c.sweep3(100)) |sw| {
        const h = sw.value;
        var l: Layout = .{};
        try l.rect(arena, "nwell", 0, 0, 2200, 2200);
        try l.rect(arena, "ntap", 0, 0, 2200, 2200);
        try l.rect(arena, "hole", h, h, 2200 - h, 2200 - h);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "tap_distance/tap_ring/{s}", .{sw.side}), cat, deck_tap_ring, l, &.{.{ "lu", try above(arena, 1100 - h, limit) }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `boxes` on met1, labelled `a` at its left end and `b` at its right.
fn named(arena: Allocator, boxes: []const c.Rect, a: []const u8, b: []const u8) !Layout {
    var l = try c.met1(arena, boxes);
    try l.label(arena, "lbl", 100, 250, a);
    try l.label(arena, "lbl", 1900, 250, b);
    return l;
}

/// A short between two labelled nets (DRC-086): a DRC run reports it as one
/// `lvs.net_seed_conflict` row (testing-plan F14), so the run does not
/// pass, and where it runs as `lvs.short_path`, one row per step between
/// the polygons joining the two labelled shapes. Shorted on one shape (one
/// row, 1 of 1), through two abutting shapes (one step) and through a chain
/// of three (two steps); two labels naming one net and two separate
/// labelled shapes pass.
///
/// Oracle: the steps counted by hand from the drawn chain (`check_layout`'s
/// doc: the fewest polygons joining the two labelled ones).
fn labelledShortInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "lbl" },
        \\connect conductors [met1]
        \\connect touch_within_layer
        \\connect label lbl names met1
        \\rule w width(met1) >= 100nm
        \\
    );
    const Case = struct { name: []const u8, layout: Layout, steps: ?[]const u32 };
    const cases = [_]Case{
        .{ .name = "one_shape", .layout = try named(arena, &.{.{ 0, 0, 2000, 500 }}, "A", "B"), .steps = &.{1} },
        .{ .name = "abutting_shapes", .layout = try named(arena, &.{ .{ 0, 0, 1000, 500 }, .{ 1000, 0, 2000, 500 } }, "A", "B"), .steps = &.{1} },
        .{ .name = "chain_of_three", .layout = try named(arena, &.{ .{ 0, 0, 700, 500 }, .{ 700, 0, 1300, 500 }, .{ 1300, 0, 2000, 500 } }, "A", "B"), .steps = &.{ 1, 2 } },
        .{ .name = "same_name", .layout = try named(arena, &.{.{ 0, 0, 2000, 500 }}, "A", "A"), .steps = null },
        .{ .name = "separate_shapes", .layout = try named(arena, &.{ .{ 0, 0, 900, 500 }, .{ 1100, 0, 2000, 500 } }, "A", "B"), .steps = null },
    };
    var fixtures: std.ArrayList(Fixture) = .empty;
    for (cases) |k| {
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "labelled_short/{s}", .{k.name}), &.{"DRC-086"}, deck, harness.drc);
        f.layout = k.layout;
        try f.claim(arena, .clean("w"));
        if (k.steps) |steps| {
            try f.claim(arena, .rule("lvs.net_seed_conflict", &.{.any()}));
            const counts = try arena.alloc(Finding, steps.len);
            for (steps, counts) |n, *o| o.* = c.count(n);
            try f.claim(arena, .rule("lvs.short_path", counts));
            try f.claim(arena, .{ .passes = false });
        } else try f.claim(arena, .{ .passes = true });
        try fixtures.append(arena, f);
    }
    try c.everyPlacementInto(arena, fixtures.items, out);
}

/// A transistor with its source contacted up to met1.
fn transistor(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "diff", 0, 0, 1000, 400);
    try l.rect(arena, "poly", 450, -200, 550, 600);
    try l.rect(arena, "cont", 100, 150, 200, 250);
    try l.rect(arena, "met1", 50, 100, 250, 300);
    return l;
}

/// Floating interconnect (DRC-084, `unconnected_pin(met1)`, an ERC kind): a
/// met1 shape whose net reaches no device terminal is flagged, one wired
/// through a contact to a transistor's source is not, and one touching that
/// wired shape shares its net.
fn danglingMetalInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "diff", "poly", "cont", "met1" },
        \\layer gate = poly and diff
        \\layer sd = diff not poly
        \\connect conductors [sd, poly, met1]
        \\connect touch_within_layer
        \\connect via cont [sd, met1]
        \\device mos gate model "n" terminals [poly, sd, sd]
        \\rule x.22 unconnected_pin(met1)
        \\
    );
    var touch = try transistor(arena);
    try touch.rect(arena, "met1", 250, 100, 1500, 300);
    var floating = try transistor(arena);
    try floating.rect(arena, "met1", 2000, 0, 2200, 200);
    const cases = [_]struct { []const u8, Layout, []const Finding }{
        .{ "wired", try transistor(arena), &.{} },
        .{ "wired_through_touch", touch, &.{} },
        .{ "floating", floating, &.{.any()} },
    };
    var fixtures: std.ArrayList(Fixture) = .empty;
    for (cases) |k| {
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "dangling_metal/{s}", .{k[0]}), &.{"DRC-084"}, deck, .{ .erc = true });
        f.layout = k[1];
        try f.claim(arena, .rule("x.22", k[2]));
        try fixtures.append(arena, f);
    }
    try c.everyPlacementInto(arena, fixtures.items, out);
}

test "every net, tap and floating-metal fixture holds" {
    // Oracle: each fixture's expected answer, derived by construction from
    // the rule's definition (the doc comments above): nets, distances and
    // short-path steps counted by hand, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
