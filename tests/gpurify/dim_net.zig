//! `net_spacing` on one layer (DRC-080) and between two layers (DRC-081) as
//! exhaustive fixtures. Ported from tests/exhaustive/drc_dimension.rs
//! (`NET_DECK`, `net_spacing`, `net_spacing_two_layers`).
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

/// The net-spacing deck: two metals joined through `via1`, labels on `met1`.
const net_deck =
    \\grid 1nm
    \\layer met1 = gds(68, 20)
    \\layer via1 = gds(68, 44)
    \\layer met2 = gds(69, 20)
    \\layer met1_label = gds(68, 5)
    \\connect conductors [met1, met2]
    \\connect touch_within_layer
    \\connect via via1 [met1, met2]
    \\connect label met1_label names met1
    \\rule sn space(met1; nets: same) >= 301nm
    \\rule dn space(met1; nets: different) >= 301nm
    \\
;

/// The two-layer deck: `met1` and `met2` labelled, `poly` not a conductor.
const two_layer_deck =
    \\grid 1nm
    \\layer met1 = gds(68, 20)
    \\layer via1 = gds(68, 44)
    \\layer met2 = gds(69, 20)
    \\layer met1_label = gds(68, 5)
    \\layer met2_label = gds(69, 5)
    \\layer poly = gds(66, 20)
    \\connect conductors [met1, met2]
    \\connect touch_within_layer
    \\connect via via1 [met1, met2]
    \\connect label met1_label names met1
    \\connect label met2_label names met2
    \\rule dn2 space(met1, met2; nets: different) >= 301nm
    \\
;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try netSpacingInto(arena, depth, out);
    try netSpacingTwoLayersInto(arena, depth, out);
}

// ---- private ----

/// A copy of `l` whose lists own their items, so appending to it leaves `l`
/// untouched.
fn dupe(arena: Allocator, l: Layout) !Layout {
    var out: Layout = .{};
    try out.shapes.appendSlice(arena, l.shapes.items);
    try out.labels.appendSlice(arena, l.labels.items);
    try out.instances.appendSlice(arena, l.instances.items);
    try out.cells.appendSlice(arena, l.cells.items);
    return out;
}

/// The gap's one finding at its midpoint when `g` is below the limit.
fn near(arena: Allocator, g: i64) ![]const Finding {
    return if (g < limit) arena.dupe(Finding, &.{c.pin(.length(g), 1000 + g, 2000)}) else &.{};
}

/// `deck` that fails to compile: the run does not pass.
fn refused(arena: Allocator, name: []const u8, deck: []const u8) !Fixture {
    var f: Fixture = .init(name, &.{"DRC-081"}, deck, harness.drc);
    f.layout = try c.met1(arena, &.{.{ 0, 0, 500, 2000 }});
    try f.claim(arena, .{ .passes = false });
    return f;
}

/// `space(met1; nets: same) >= 301nm` and `nets: different` (`net_spacing`,
/// DRC-080): pairs in different figures, by extracted net, at the midpoint
/// of the nearest points.
///
/// Two bars `g` apart, strapped through vias and `met2` (one net: only the
/// same-net rule holds them) or not (two nets); labels with different names
/// and with one name (a name does not join nets: they stay two); touching
/// bars (one figure, no pair). A deck naming a non-conductor is refused.
fn netSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |g| {
        const found = try near(arena, g);
        const bars = try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 500 + g, 0, 1000 + g, 2000 } });
        var strapped = try dupe(arena, bars);
        try c.rects(arena, &strapped, "via1", &.{ .{ 200, 200, 300, 300 }, .{ 700 + g, 200, 800 + g, 300 } });
        try c.rects(arena, &strapped, "met2", &.{.{ 100, 100, 900 + g, 400 }});
        var labelled = try dupe(arena, bars);
        try labelled.label(arena, "met1_label", 250, 1000, "A");
        try labelled.label(arena, "met1_label", 750 + g, 1000, "B");
        var one_name = try dupe(arena, bars);
        try one_name.label(arena, "met1_label", 250, 1000, "A");
        try one_name.label(arena, "met1_label", 750 + g, 1000, "A");
        const tag = try c.side(arena, g, limit);
        const shapes = [_]struct { []const u8, Layout, bool }{
            .{ "strapped", strapped, true },
            .{ "apart", bars, false },
            .{ "labelled_apart", labelled, false },
            .{ "one_name_apart", one_name, false },
        };
        for (shapes) |s| {
            const sn: []const Finding = if (s[2]) found else &.{};
            const dn: []const Finding = if (s[2]) &.{} else found;
            try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "net_spacing/{s}/{s}", .{ s[0], tag }), &.{"DRC-080"}, net_deck, s[1], &.{ .{ "sn", sn }, .{ "dn", dn } }));
        }
    }
    try cases.append(arena, try c.fixture(arena, "net_spacing/touching", &.{"DRC-080"}, net_deck, try c.met1(arena, &.{ .{ 0, 0, 500, 2000 }, .{ 500, 0, 1000, 2000 } }), &.{ .{ "sn", &.{} }, .{ "dn", &.{} } }));
    try c.everyPlacementInto(arena, cases.items, out);
    var vacuous: Layout = .{};
    try c.rects(arena, &vacuous, "met2", &.{.{ 0, 0, 1000, 1000 }});
    try out.append(arena, try c.fixture(arena, "net_spacing/vacuous", &.{"DRC-080"}, net_deck, vacuous, &.{ .{ "sn", &.{} }, .{ "dn", &.{} } }));
    var not_conductor: Fixture = .init("net_spacing/not_a_conductor", &.{"DRC-080"}, try c.oneLayerDeck(arena, "rule dn space(met1; nets: different) >= 301nm"), harness.drc);
    not_conductor.layout = try c.met1(arena, &.{.{ 0, 0, 500, 2000 }});
    try not_conductor.claim(arena, .{ .passes = false });
    try out.append(arena, not_conductor);
}

/// `space(met1, met2; nets: different) >= 301nm` (`net_spacing` between two
/// layers, DRC-081, as sky130 nwell.7 "nwell and deep nwell on separate
/// nets"). Oracle: the rule's definition by hand. A met1 bar and a met2 bar
/// `g` apart on two nets (unlabelled, or labelled A and B) are flagged at
/// the midpoint of the gap when `g` is below the limit; the same bars on
/// one net, the met2 bar run over the met1 bar's end through a via, are not
/// judged however close; a met2 bar crossing the met1 bar on another net
/// overlaps it, a distance of 0. A non-conductor layer and `nets: same`
/// across two layers are refused.
fn netSpacingTwoLayersInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |g| {
        const found = try near(arena, g);
        var bars = try c.met1(arena, &.{.{ 0, 0, 500, 2000 }});
        try c.rects(arena, &bars, "met2", &.{.{ 500 + g, 0, 1000 + g, 2000 }});
        var joined = try dupe(arena, bars);
        try c.rects(arena, &joined, "met2", &.{.{ 0, 2000, 1000 + g, 2500 }});
        try c.rects(arena, &joined, "met1", &.{.{ 0, 2000, 500, 2500 }});
        try c.rects(arena, &joined, "via1", &.{.{ 200, 2200, 300, 2300 }});
        var labelled = try dupe(arena, bars);
        try labelled.label(arena, "met1_label", 250, 1000, "A");
        try labelled.label(arena, "met2_label", 750 + g, 1000, "B");
        const tag = try c.side(arena, g, limit);
        const shapes = [_]struct { []const u8, Layout, []const Finding }{
            .{ "apart", bars, found },
            .{ "labelled_apart", labelled, found },
            .{ "one_net", joined, &.{} },
        };
        for (shapes) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "net_spacing/two_layers/{s}/{s}", .{ s[0], tag }), &.{"DRC-081"}, two_layer_deck, s[1], &.{.{ "dn2", s[2] }}));
    }
    var crossing = try c.met1(arena, &.{.{ 0, 0, 500, 2000 }});
    try c.rects(arena, &crossing, "met2", &.{.{ -500, 900, 1000, 1100 }});
    try cases.append(arena, try c.fixture(arena, "net_spacing/two_layers/crossing", &.{"DRC-081"}, two_layer_deck, crossing, &.{.{ "dn2", try arena.dupe(Finding, &.{.length(0)}) }}));
    try c.everyPlacementInto(arena, cases.items, out);
    const rule = "rule dn2 space(met1, met2; nets: different) >= 301nm";
    const swaps = [_]struct { []const u8, []const u8 }{
        .{ "not_a_conductor", "rule dn2 space(met1, poly; nets: different) >= 301nm" },
        .{ "same_nets", "rule sn2 space(met1, met2; nets: same) >= 301nm" },
    };
    for (swaps) |s| {
        const deck = try std.mem.replaceOwned(u8, arena, two_layer_deck, rule, s[1]);
        try out.append(arena, try refused(arena, try std.fmt.allocPrint(arena, "net_spacing/two_layers/{s}", .{s[0]}), deck));
    }
}

test "every net spacing fixture holds" {
    // Oracle: each fixture's expected answer, derived from `net_spacing`'s
    // definition by hand (the doc comments above): pairs judged by
    // extracted net, the gap swept around the limit, under every symmetry
    // at two translations; a deck naming a non-conductor, or `nets: same`
    // across two layers, refused.
    try c.checkGenerated(fixturesInto);
}
