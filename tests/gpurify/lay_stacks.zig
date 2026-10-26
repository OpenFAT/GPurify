//! Via stacks, the metal-width via map and stacked-cut spacing as
//! exhaustive fixtures. Ported from tests/exhaustive/drc_overlay.rs
//! (`via_stack`, `metal_width_via`, `stack_spacing`, `via_stack_single`).
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
    try viaStackInto(arena, out);
    try metalWidthViaInto(arena, out);
    try stackSpacingInto(arena, out);
    try viaStackSingleInto(arena, out);
}

// ---- private ----

/// A 100 nm cut on `layer` at `(x, y)`.
fn cut(arena: Allocator, layout: *Layout, layer: []const u8, x: i64, y: i64) !void {
    try layout.rect(arena, layer, x, y, x + 100, y + 100);
}

/// `via_stack(v1, v2, v3, v4) <= 2` (`via_stack`, DRC-065, LEF
/// `MAXVIASTACK 2`): a cut stacks on a cut of the layer below that it
/// overlaps; the cut third from the bottom of each stack taller than two is
/// one finding, measuring the stack's height.
///
/// Oracle: LEF/DEF 5.8 "a via is considered to be in a stack with another
/// via if the cut of the first via overlaps any part of the cut of the
/// second via", on stacks drawn to a height.
///
/// Shapes, 100 nm cuts: stacks of two, three and four aligned cuts (the
/// four-high stack is reported once, on its third cut, measuring 4); a stack
/// of three whose cuts overlap by half; a v3 cut beside the v2 cut, not on
/// it (two stacks of two); a v2 cut abutting the v1 cut (touching is not
/// stacking); a v1 cut under two v2 cuts each carrying a v3 (two stacks of
/// three, two findings).
fn viaStackInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "v1", "v2", "v3", "v4" }, "rule stack via_stack(v1, v2, v3, v4) <= 2\n");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    const Tower = struct { usize, []const Finding };
    for ([_]Tower{ .{ 2, &.{} }, .{ 3, &.{c.count(3)} }, .{ 4, &.{c.count(4)} } }) |t| {
        var l: Layout = .{};
        const layers = [_][]const u8{ "v1", "v2", "v3", "v4" };
        for (layers[0..t[0]]) |layer| try cut(arena, &l, layer, 0, 0);
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "tower/{d}", .{t[0]}), l, t[1] });
    }
    var half: Layout = .{};
    try cut(arena, &half, "v1", 0, 0);
    try cut(arena, &half, "v2", 50, 0);
    try cut(arena, &half, "v3", 100, 0);
    try shapes.append(arena, .{ "half_overlap", half, &.{c.count(3)} });
    var broken: Layout = .{};
    try cut(arena, &broken, "v1", 0, 0);
    try cut(arena, &broken, "v2", 0, 0);
    try cut(arena, &broken, "v3", 300, 0);
    try cut(arena, &broken, "v4", 300, 0);
    try shapes.append(arena, .{ "broken", broken, &.{} });
    var abutting: Layout = .{};
    try cut(arena, &abutting, "v1", 0, 0);
    try cut(arena, &abutting, "v2", 100, 0);
    try cut(arena, &abutting, "v3", 100, 0);
    try shapes.append(arena, .{ "abutting", abutting, &.{} });
    var branching: Layout = .{};
    try branching.rect(arena, "v1", 0, 0, 300, 100);
    try branching.rect(arena, "v2", 0, 0, 100, 100);
    try branching.rect(arena, "v2", 200, 0, 300, 100);
    try branching.rect(arena, "v3", 0, 0, 100, 100);
    try branching.rect(arena, "v3", 200, 0, 300, 100);
    try shapes.append(arena, .{ "branching", branching, &.{ c.count(3), c.count(3) } });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "via_stack/{s}", .{s[0]}), &.{"DRC-065"}, deck, s[1], &.{.{ "stack", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One `metal_width_via` fixture: an `m1` bar `w1` high crossing an `m2`
/// bar `w2` wide, a `cw` x `ch` cut where they cross; `vm` and `vr` say
/// which rows find the cut wrong (a count of 0).
fn widthViaCase(arena: Allocator, deck: []const u8, name: []const u8, w1: i64, w2: i64, cw: i64, ch: i64, vm: bool, vr: bool) !Fixture {
    var l: Layout = .{};
    try l.rect(arena, "m1", 0, 0, 1000, w1);
    try l.rect(arena, "m2", 460, -500, 460 + w2, 500);
    try l.rect(arena, "v1", 480, 5, 480 + cw, 5 + ch);
    const wrong: []const Finding = &.{c.count(0)};
    return c.fixture(arena, try std.fmt.allocPrint(arena, "metal_width_via/{s}", .{name}), &.{"DRC-067"}, deck, l, &.{
        .{ "vm", if (vm) wrong else &.{} },
        .{ "vr", if (vr) wrong else &.{} },
    });
}

/// `LEF58_METALWIDTHVIAMAP` (`metal_width_via`, DRC-067), as `OpenROAD`
/// parses it (`VIA cutLayer w1 w2 viaName`: the via where the metal below is
/// w1 wide and above w2; four numbers, two ranges): `vm`, exact widths 50
/// and 80 with a 30 x 30 cut (`OpenROAD`'s own test entry `VIA via1 0.5 0.8
/// M2_M1_via` scaled by a tenth); `vr`, ranges 40..60 and 70..90 with a 30
/// x 40 cut, either way round.
///
/// Oracle: the parser's grammar, wires drawn to a width: an `m1` bar `w1`
/// high crossing an `m2` bar `w2` wide, a cut where they cross. The mapped
/// cut passes, a 40 x 40 cut fails both rows while both widths are in their
/// bands: `w1` swept around 50 (only 50 is `vm`'s) and `w2` around 80 (only
/// 80); a 40 x 30 cut is `vr`'s 30 x 40 turned; a cut off the bars is held
/// by neither.
fn metalWidthViaInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "v1", "m1", "m2" }, "rule vm via_map(v1, m1, m2; below_min: 50nm, below_max: 50nm, above_min: 80nm, " ++
        "above_max: 80nm, cut: 30nm x 30nm)\n" ++
        "rule vr via_map(v1, m1, m2; below_min: 40nm, below_max: 60nm, above_min: 70nm, " ++
        "above_max: 90nm, cut: 30nm x 40nm)\n");
    var cases: std.ArrayList(Fixture) = .empty;
    try cases.append(arena, try widthViaCase(arena, deck, "mapped", 50, 80, 30, 30, false, true));
    try cases.append(arena, try widthViaCase(arena, deck, "range_mapped", 50, 80, 30, 40, true, false));
    try cases.append(arena, try widthViaCase(arena, deck, "range_turned", 50, 80, 40, 30, true, false));
    for (c.sweep3(50)) |sw| try cases.append(arena, try widthViaCase(arena, deck, try std.fmt.allocPrint(arena, "below/{s}", .{sw.side}), sw.value, 80, 40, 40, sw.value == 50, true));
    for (c.sweep3(80)) |sw| try cases.append(arena, try widthViaCase(arena, deck, try std.fmt.allocPrint(arena, "above/{s}", .{sw.side}), 50, sw.value, 40, 40, sw.value == 80, true));
    var off: Layout = .{};
    try off.rect(arena, "m1", 0, 0, 1000, 50);
    try off.rect(arena, "m2", 460, -500, 540, 500);
    try off.rect(arena, "v1", 2000, 2000, 2040, 2040);
    try cases.append(arena, try c.fixture(arena, "metal_width_via/off_the_wires", &.{"DRC-067"}, deck, off, &.{ .{ "vm", &.{} }, .{ "vr", &.{} } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One net: pads on every metal over both cuts.
fn pads(arena: Allocator) !Layout {
    var l: Layout = .{};
    for ([_][]const u8{ "m1", "m2", "m3" }) |m| try l.rect(arena, m, -500, -500, 1000, 600);
    return l;
}

/// `stack_space(v2, v1, m2; same_net: true) >= 200nm` (`ss`, LEF Spacing
/// Rule Example 7's `SPACING 0.20 SAMENET LAYER cut12 STACK` on cut23, the
/// cuts' nets read off `m2`) and `stack_space(v2, v1, m2) >= 200nm` (`all`)
/// (`stack_spacing`, DRC-065):
/// "same-net cuts on two different layers can be stacked if they are
/// aligned. If the cuts are not the same size, the smaller cut must be
/// completely covered by the larger cut ... If both cuts are the same size,
/// the centers of the cuts must be aligned ... otherwise, the cuts must have
/// cutSpacing between them".
///
/// Oracle: the LEF text, cuts by construction, one net through an `m2` pad
/// unless stated: aligned equal cuts and a cut covered by a larger one
/// (stacked, legal); equal cuts offset by half (overlapping, not aligned: a
/// gap of 0); a `v1` cut beside the `v2` cut 199, 200 and 201 away; two
/// cuts 150 apart on different nets, which only `all` holds.
fn stackSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "m1", "v1", "m2", "v2", "m3" }, "connect conductors [m1, m2, m3]\nconnect touch_within_layer\n" ++
        "connect via v1 [m1, m2]\nconnect via v2 [m2, m3]\n" ++
        "rule ss stack_space(v2, v1, m2; same_net: true) >= 200nm\n" ++
        "rule all stack_space(v2, v1, m2) >= 200nm\n");
    const Case = struct { []const u8, Layout, []const Finding, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    var aligned = try pads(arena);
    try aligned.rect(arena, "v1", 0, 0, 100, 100);
    try aligned.rect(arena, "v2", 0, 0, 100, 100);
    try shapes.append(arena, .{ "aligned", aligned, &.{}, &.{} });
    var covered = try pads(arena);
    try covered.rect(arena, "v1", -20, -20, 120, 120);
    try covered.rect(arena, "v2", 0, 0, 100, 100);
    try shapes.append(arena, .{ "covered", covered, &.{}, &.{} });
    var offset = try pads(arena);
    try offset.rect(arena, "v1", 50, 0, 150, 100);
    try offset.rect(arena, "v2", 0, 0, 100, 100);
    try shapes.append(arena, .{ "offset", offset, &.{.length(0)}, &.{.length(0)} });
    for (c.sweep3(200)) |sw| {
        const g = sw.value;
        const near = try c.below(arena, g, 200);
        var l = try pads(arena);
        try l.rect(arena, "v1", 100 + g, 0, 200 + g, 100);
        try l.rect(arena, "v2", 0, 0, 100, 100);
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "apart/{s}", .{sw.side}), l, near, near });
    }
    // Two nets: separate pads under each cut.
    var two_nets: Layout = .{};
    for ([_][]const u8{ "m1", "m2", "m3" }) |m| {
        try two_nets.rect(arena, m, -100, -100, 200, 200);
        try two_nets.rect(arena, m, 250, -100, 550, 200);
    }
    try two_nets.rect(arena, "v1", 250, 0, 350, 100);
    try two_nets.rect(arena, "v2", 0, 0, 100, 100);
    try shapes.append(arena, .{ "different_nets", two_nets, &.{}, &.{.length(150)} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "stack_spacing/{s}", .{s[0]}), &.{"DRC-065"}, deck, s[1], &.{ .{ "ss", s[2] }, .{ "all", s[3] } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Metal pads over every layer, and a cut at x on the listed cut layers;
/// `double` cut layers get a second cut 300 to the right on the same pads.
fn tower(arena: Allocator, cuts: []const []const u8, double: []const []const u8) !Layout {
    var l: Layout = .{};
    for ([_][]const u8{ "m1", "m2", "m3", "m4", "m5" }) |m| try l.rect(arena, m, -100, -100, 500, 200);
    for (cuts) |v| try l.rect(arena, v, 0, 0, 100, 100);
    for (double) |v| try l.rect(arena, v, 300, 0, 400, 100);
    return l;
}

/// `via_stack(m1, v1, m2, v2, m3, v3, m4, v4, m5, single) <= 2`
/// (`via_stack`, DRC-065): LEF `MAXVIASTACK 2` over single-cut vias only, "A
/// double-cut or larger via interrupts the stack".
///
/// Oracle: the LEF text's own example, "a via stack consisting of single
/// via12, single via23, double-cut via34, and single via45 has a single-cut
/// stack of height 2 for via12 and via23, and a single-cut stack of height 1
/// for via45" (legal at 2); three single cuts stacked (height 3, the top cut
/// reported); the same with the middle via doubled (no stack over 1); and a
/// tower of four single cuts where two of its cuts at one layer sit on
/// different metal figures, still single (height 4, reported at the third).
fn viaStackSingleInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "m1", "v1", "m2", "v2", "m3", "v3", "m4", "v4", "m5" }, "rule stack via_stack(m1, v1, m2, v2, m3, v3, m4, v4, m5, single) <= 2\n");
    var split = try tower(arena, &.{ "v1", "v2", "v3", "v4" }, &.{});
    try split.rect(arena, "m3", 1000, -100, 1500, 200);
    try split.rect(arena, "v2", 1100, 0, 1200, 100);
    const Case = struct { []const u8, Layout, []const Finding };
    const shapes = [_]Case{
        .{ "lef_example", try tower(arena, &.{ "v1", "v2", "v3", "v4" }, &.{"v3"}), &.{} },
        .{ "three_single", try tower(arena, &.{ "v1", "v2", "v3" }, &.{}), &.{c.count(3).pinned(50, 50)} },
        .{ "middle_double", try tower(arena, &.{ "v1", "v2", "v3" }, &.{"v2"}), &.{} },
        .{ "split_pads", split, &.{c.count(4).pinned(50, 50)} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "via_stack_single/{s}", .{s[0]}), &.{"DRC-065"}, deck, s[1], &.{.{ "stack", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every via-stack and stacked-cut fixture holds" {
    // Oracle: each stack height, cut size, wire width and gap is drawn by
    // construction (the LEF MAXVIASTACK, LEF58_METALWIDTHVIAMAP and SPACING
    // STACK texts); every finding follows from it and the rule's bound,
    // under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
