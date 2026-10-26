//! Edge widths and facing spacing (DRC-011, DRC-016) as exhaustive
//! fixtures: a transistor's channel, width and spacing in one direction,
//! and wrong-direction spacing. Ported from
//! tests/exhaustive/drc_dimension.rs (`channel`, `directional`,
//! `wrong_direction_spacing`).
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
const Symmetry = harness.Symmetry;
const c = @import("drc_common.zig");

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try channelInto(arena, depth, out);
    try directionalInto(arena, depth, out);
    try wrongDirectionSpacingInto(arena, depth, out);
}

// ---- private ----

/// A diffusion `[0, 1000] x [0, w]` and `polys` on `poly`.
fn fet(arena: Allocator, w: i64, polys: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, "diff", &.{.{ 0, 0, 1000, w }});
    try c.rects(arena, &l, "poly", polys);
    return l;
}

/// One finding pinned at the doubled midpoint when `v` is under `limit`.
fn short(arena: Allocator, v: i64, limit: i64, x2: i64, y2: i64) ![]const Finding {
    return if (v < limit) arena.dupe(Finding, &.{c.pin(.length(v), x2, y2)}) else &.{};
}

/// A transistor's channel length and width (`edge_width`, DRC-011: sky130
/// poly.1b "min channel length (poly width)", difftap.2 "minimum channel
/// width (diff and poly)", IHP Gat.a1 to a4, GF180 PL.2): `width(gate.edges()
/// not diff.edges()) >= 150nm` measures the gap between the gate's sides
/// inside the diffusion, `width(gate.edges() and diff.edges()) >= 420nm` the
/// gap between its sides on the diffusion's edge; one finding per pair, at
/// the middle of the gap, measuring it.
///
/// Oracle: channels drawn to a length and a width, each swept one step
/// either side of its limit with the other legal. A gate 300 long and 200
/// wide: its length passes and its width fails, where a plain `width(gate)`
/// would read 200 for both. Two fingers on one diffusion: the sides facing
/// across the shared source are face to face and not a width, and the outer
/// sides, 450 apart, are no finding at 150; at a length of 149 each finger
/// is one finding. An empty layout.
fn channelInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = "grid 1nm\nlayer diff = gds(65, 20)\nlayer poly = gds(66, 20)\nlayer gate = poly and diff\nlayer lsides = gate.edges() not diff.edges()\nlayer wsides = gate.edges() and diff.edges()\nrule l width(lsides) >= 150nm\nrule w width(wsides) >= 420nm\n";
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 150)) |l| {
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "channel/length/{s}", .{try c.side(arena, l, 150)}), &.{"DRC-011"}, deck, try fet(arena, 1000, &.{.{ 450, -200, 450 + l, 1200 }}), &.{ .{ "l", try short(arena, l, 150, 900 + l, 1000) }, .{ "w", &.{} } }));
    }
    for (try c.sweep(arena, depth, 420)) |w| {
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "channel/width/{s}", .{try c.side(arena, w, 420)}), &.{"DRC-011"}, deck, try fet(arena, w, &.{.{ 450, -200, 600, w + 200 }}), &.{ .{ "l", &.{} }, .{ "w", try short(arena, w, 420, 1050, w) } }));
    }
    try cases.append(arena, try c.fixture(arena, "channel/long_and_narrow", &.{"DRC-011"}, deck, try fet(arena, 200, &.{.{ 450, -200, 750, 400 }}), &.{ .{ "l", &.{} }, .{ "w", &.{Finding.length(200).pinned(600, 100)} } }));
    try cases.append(arena, try c.fixture(arena, "channel/two_fingers", &.{"DRC-011"}, deck, try fet(arena, 1000, &.{ .{ 300, -200, 450, 1200 }, .{ 600, -200, 750, 1200 } }), &.{ .{ "l", &.{} }, .{ "w", &.{} } }));
    try cases.append(arena, try c.fixture(arena, "channel/two_short_fingers", &.{"DRC-011"}, deck, try fet(arena, 1000, &.{ .{ 300, -200, 449, 1200 }, .{ 600, -200, 749, 1200 } }), &.{ .{ "l", &.{ .length(149), .length(149) } }, .{ "w", &.{} } }));
    try c.everyPlacementInto(arena, cases.items, out);
    var diff: Layout = .{};
    try c.rects(arena, &diff, "diff", &.{.{ 0, 0, 1000, 1000 }});
    try out.append(arena, try c.fixture(arena, "channel/empty", &.{"DRC-011"}, deck, diff, &.{ .{ "l", &.{} }, .{ "w", &.{} } }));
}

/// Each case under every symmetry at every offset; a placement with a
/// quarter turn takes `turned` for its deck.
fn placeTurnedInto(arena: Allocator, cases: []const Fixture, turned: []const u8, out: *std.ArrayList(Fixture)) !void {
    for (cases) |*f| for (c.offsets) |o| for (Symmetry.all) |s| {
        var placed = try f.transformed(arena, s, o[0], o[1]);
        if (s.turns % 2 == 1) placed.deck = turned;
        try out.append(arena, placed);
    };
}

fn directionalDeck(arena: Allocator, turned: bool) ![]const u8 {
    const h: []const u8 = if (turned) "vertical" else "horizontal";
    const v: []const u8 = if (turned) "horizontal" else "vertical";
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met4 = gds(71, 20)\nlayer h = met4.edges().{s}()\nlayer v = met4.edges().{s}()\nrule w1 width(h) >= 24nm\nrule w5 width(v) >= 44nm\nrule s1 facing_space(h) >= 24nm\nrule s2 facing_space(v) >= 40nm\n", .{ h, v });
}

fn met4(arena: Allocator, boxes: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, "met4", boxes);
    return l;
}

/// Width and spacing in one direction (DRC-016: ASAP7 M4.W.1 "minimum
/// vertical width of M4" 24, M4.W.5 "minimum horizontal width" 44, M4.S.1
/// "minimum vertical spacing" 24, M4.S.2 "minimum horizontal spacing" 40):
/// `width` (`edge_width`) and `facing_space` (`edge_facing_space`) on
/// `met4.edges().horizontal()` (a vertical measure) and `.vertical()`.
///
/// Oracle: wires drawn to a width or gap, each swept one step either side
/// of its limit: a horizontal wire's thickness is a vertical width, two
/// horizontal wires' gap a vertical spacing, and the same transposed. One
/// gap of 30 between two horizontal wires passes (24) where the same gap
/// between two vertical wires fails (40): a direction-blind spacing reads
/// both alike. A U whose arms are 30 apart is a horizontal notch, which
/// `facing_space` measures as `KLayout`'s `space` does, while each arm's 50
/// is a width and not a spacing. A quarter turn swaps the axes, so the
/// turned placements swap `horizontal()` and `vertical()` in the deck and
/// keep the expectation.
fn directionalInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const flat = try directionalDeck(arena, false);
    const Case = struct { []const u8, Layout, [4][]const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 24)) |t| if (t > 0) {
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "vertical_width/{s}", .{try c.side(arena, t, 24)}), try met4(arena, &.{.{ 0, 0, 1000, t }}), .{ try short(arena, t, 24, 1000, t), &.{}, &.{}, &.{} } });
    };
    for (try c.sweep(arena, depth, 44)) |t| if (t > 0) {
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "horizontal_width/{s}", .{try c.side(arena, t, 44)}), try met4(arena, &.{.{ 0, 0, t, 1000 }}), .{ &.{}, try short(arena, t, 44, t, 1000), &.{}, &.{} } });
    };
    for (try c.sweep(arena, depth, 24)) |g| if (g > 0) {
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "vertical_space/{s}", .{try c.side(arena, g, 24)}), try met4(arena, &.{ .{ 0, 0, 1000, 50 }, .{ 0, 50 + g, 1000, 100 + g } }), .{ &.{}, &.{}, try short(arena, g, 24, 1000, 100 + g), &.{} } });
    };
    for (try c.sweep(arena, depth, 40)) |g| if (g > 0) {
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "horizontal_space/{s}", .{try c.side(arena, g, 40)}), try met4(arena, &.{ .{ 0, 0, 50, 1000 }, .{ 50 + g, 0, 100 + g, 1000 } }), .{ &.{}, &.{}, &.{}, try short(arena, g, 40, 100 + g, 1000) } });
    };
    try shapes.append(arena, .{ "same_gap_two_directions", try met4(arena, &.{ .{ 0, 0, 1000, 50 }, .{ 0, 80, 1000, 130 }, .{ 2000, 0, 2050, 1000 }, .{ 2080, 0, 2130, 1000 } }), .{ &.{}, &.{}, &.{}, &.{Finding.length(30).pinned(2065, 500)} } });
    var notch: Layout = .{};
    try notch.polygon(arena, "met4", &.{ .{ 0, 0 }, .{ 130, 0 }, .{ 130, 500 }, .{ 80, 500 }, .{ 80, 50 }, .{ 50, 50 }, .{ 50, 500 }, .{ 0, 500 } });
    try shapes.append(arena, .{ "notch", notch, .{ &.{}, &.{}, &.{}, &.{Finding.length(30).pinned(65, 275)} } });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "directional/{s}", .{s[0]}), &.{"DRC-016"}, flat, s[1], &.{ .{ "w1", s[2][0] }, .{ "w5", s[2][1] }, .{ "s1", s[2][2] }, .{ "s2", s[2][3] } }));
    try placeTurnedInto(arena, cases.items, try directionalDeck(arena, true), out);
}

fn wrongDirectionDeck(arena: Allocator, turned: bool) ![]const u8 {
    const across: []const u8 = if (turned) "horizontal" else "vertical";
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\nlayer wd = met1.edges().{s}().with_length(>= 150nm)\nrule wd facing_space(wd; prl: 100nm) >= 120nm\n", .{across});
}

/// `LEF58_SPACING 0.12 WRONGDIRECTION NONEOL 0.15 PRL 0.1` on a horizontal
/// layer (DRC-016), written `facing_space(wd; prl: 100nm) >= 120nm` over
/// `wd = met1.edges().vertical().with_length(>= 150nm)`: as `OpenROAD`
/// `TritonRoute`'s `checkMetalSpacing_wrongDir` reads it, the edges across
/// the layer's direction, either one shorter than the `NONEOL` width
/// skipped, a pair judged only when it overlaps by more than the `PRL`, and
/// closer than the spacing a violation.
///
/// Oracle: bars drawn to a gap, a run and an edge length, each swept one
/// step either side of its limit: the gap around 120 (119 fails), the
/// overlap around 100 at a gap of 60 (101 fails, 100 is not more than the
/// run), the edge length around 150 at a gap of 60 (149 is skipped). A tall
/// bar facing a short one (140, under 150) is not judged; two bars stacked
/// end to end (horizontal edges) are not either; a pair offset diagonally
/// has no run. A quarter turn makes the layer vertical, so the turned
/// placements take `horizontal()` and keep the expectation.
fn wrongDirectionSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const flat = try wrongDirectionDeck(arena, false);
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 120)) |g| if (g > 0) {
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "gap/{s}", .{try c.side(arena, g, 120)}), try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 100 + g, 0, 200 + g, 1000 } }), try short(arena, g, 120, 200 + g, 1000) });
    };
    for (try c.sweep(arena, depth, 100)) |r| if (r > 0) {
        const findings: []const Finding = if (r > 100) try arena.dupe(Finding, &.{c.pin(.length(60), 260, 2000 - r)}) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "run/{s}", .{try c.side(arena, r, 100)}), try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 160, 1000 - r, 260, 2000 - r } }), findings });
    };
    for (try c.sweep(arena, depth, 150)) |h| if (h > 0) {
        const findings: []const Finding = if (h >= 150) try arena.dupe(Finding, &.{c.pin(.length(60), 260, h)}) else &.{};
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "noneol/{s}", .{try c.side(arena, h, 150)}), try c.met1(arena, &.{ .{ 0, 0, 100, h }, .{ 160, 0, 260, h } }), findings });
    };
    try shapes.append(arena, .{ "short_partner", try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 160, 400, 260, 540 } }), &.{} });
    try shapes.append(arena, .{ "end_to_end", try c.met1(arena, &.{ .{ 0, 0, 1000, 100 }, .{ 0, 160, 1000, 260 } }), &.{} });
    try shapes.append(arena, .{ "diagonal", try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 160, 1000, 260, 2000 } }), &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "wrong_direction/{s}", .{s[0]}), &.{"DRC-016"}, flat, s[1], &.{.{ "wd", s[2] }}));
    try placeTurnedInto(arena, cases.items, try wrongDirectionDeck(arena, true), out);
}

test "every channel and directional fixture holds" {
    // Oracle: each fixture's expected answer, derived from the rule's
    // definition (the doc comments above): channels, wires and gaps drawn to
    // a size, each swept one grid step either side of its limit, under every
    // symmetry at two translations (a quarter turn swapping the deck's axes).
    try c.checkGenerated(fixturesInto);
}
