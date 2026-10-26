//! Deck switches, exemption regions and warning rules as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_overlay.rs (`rule_flags`,
//! `exemption`, `drc_warning`).
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

/// IHP SG13G2 TM2.bR as `pdks/ihp_sg13g2.deck` transcribes it.
const tm2_br = "space_table(topmetal2; prl: [0um, 50um], width: [0um, 5um], space: [[2um, 2um], [2um, 5um]])";

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try ruleFlagsInto(arena, out);
    try exemptionInto(arena, out);
    try drcWarningInto(arena, out);
}

// ---- private ----

/// A rule flag (DRC-092: a deck switch, as sky130's deck switches and a
/// Calibre deck's `#IFDEF`): `let strict = true | false`, then `if strict {
/// rule w width(m) >= 200nm }` and `if not strict { rule w width(m) >=
/// 100nm }`, the `not` block nesting a second switch that adds a rule only
/// when both hold. One id, so which block was read shows in its limit.
///
/// Oracle: the switch's documented reading (the block is read when the name
/// is true, its `not` form when false): a bar 199, 200, 201 wide is held to
/// 200 when strict (a finding of 199) and to 100 when not (none); the nested
/// rule runs only with `strict` false and `edges` true.
fn ruleFlagsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(200)) |sw| {
        const w = sw.value;
        for ([_][2]bool{ .{ true, true }, .{ false, true }, .{ false, false } }) |flags| {
            const strict = flags[0];
            const edges = flags[1];
            const deck = try c.newDeck(arena, &.{"m"}, try std.fmt.allocPrint(arena, "let strict = {}\nlet edges = {}\nif strict {{\n    rule w width(m) >= 200nm\n}}\nif not strict {{\n    rule w width(m) >= 100nm\n    if edges {{\n        rule e edge_length(m) >= 10um\n    }}\n}}\n", .{ strict, edges }));
            var bar: Layout = .{};
            try bar.rect(arena, "m", 0, 0, w, 3000);
            var f = try c.fixture(arena, try std.fmt.allocPrint(arena, "rule_flags/{}_{}/{s}", .{ strict, edges, sw.side }), &.{"DRC-092"}, deck, bar, &.{.{ "w", if (strict) try c.below(arena, w, 200) else &.{} }});
            // Every edge of the bar is under 10 um.
            if (!strict and edges) try f.claim(arena, .rule("e", &.{ .any(), .any(), .any(), .any() }));
            try cases.append(arena, f);
        }
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// An exemption region (DRC-092): `width(met1 not areaid) >= 100nm` flags a
/// narrow bar outside the region (swept), not one inside it, the part of a
/// bar left outside a region that covers only half of it, and the 50 nm
/// sliver a region leaves of a wide plate.
fn exemptionInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "areaid" }, "layer met1_chk = met1 not areaid\nrule m1.1 width(met1_chk) >= 100nm\n");
    const cat: []const []const u8 = &.{ "DRC-092", "DRC-120" };
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(100)) |sw| {
        var l = try c.met1(arena, &.{.{ 0, 0, sw.value, 1000 }});
        try l.rect(arena, "areaid", 2000, 0, 3000, 1000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "exemption/outside/{s}", .{sw.side}), cat, deck, l, &.{.{ "m1.1", try c.below(arena, sw.value, 100) }}));
    }
    const fixed = [_]struct { []const u8, c.Rect, c.Rect, []const Finding }{
        .{ "inside", .{ 0, 0, 50, 1000 }, .{ -500, -500, 500, 1500 }, &.{} },
        .{ "half_inside", .{ 0, 0, 50, 2000 }, .{ -500, -500, 500, 1000 }, try c.lengths(arena, &.{50}) },
        // The exemption cuts a wide plate, and what it leaves is a narrow sliver.
        .{ "leaves_sliver", .{ 0, 0, 1000, 1000 }, .{ -500, -500, 950, 1500 }, try c.lengths(arena, &.{50}) },
    };
    for (fixed) |k| {
        var l = try c.met1(arena, &.{k[1]});
        try c.rects(arena, &l, "areaid", &.{k[2]});
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "exemption/{s}", .{k[0]}), cat, deck, l, &.{.{ "m1.1", k[3] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Two 6 um x 60 um `topmetal2` bars `g` apart.
fn tm2Bars(arena: Allocator, g: i64) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, "topmetal2", &.{ .{ 0, 0, 6000, 60_000 }, .{ 6000 + g, 0, 12_000 + g, 60_000 } });
    return l;
}

/// A DRC rule written `warning` (DRC-110): a foundry's recommended rule.
/// deck.md, "Rules": its findings are reported as the same rule unmarked
/// would report them, but do not fail the run.
///
/// The rule is IHP SG13G2 TM2.bR as `pdks/ihp_sg13g2.deck` transcribes it
/// (a spacing table: 5 um between `TopMetal2` lines wider than 5 um running
/// in parallel for more than 50 um), beside the required TM2.b (2 um), on
/// two 6 um x 60 um bars swept about the recommended 5 um. Below it, the
/// warning rule reports the gap and the run still passes; at and above it,
/// nothing. The same layout under the unmarked rule fails the run below the
/// limit.
fn drcWarningInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const warned = try c.newDeck(arena, &.{"topmetal2"}, "rule TM2.b space(topmetal2) >= 2um\nrule TM2.bR warning " ++ tm2_br ++ "\n");
    const unmarked = try c.newDeck(arena, &.{"topmetal2"}, "rule TM2.bR " ++ tm2_br ++ "\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(5000)) |sw| {
        const g = sw.value;
        var w: Fixture = .init(try std.fmt.allocPrint(arena, "drc_warning/tm2_br/{s}", .{sw.side}), &.{"DRC-110"}, warned, harness.drc);
        w.layout = try tm2Bars(arena, g);
        try w.claim(arena, .clean("TM2.b"));
        try w.claim(arena, .rule("TM2.bR", try c.below(arena, g, 5000)));
        try w.claim(arena, .{ .passes = true });
        try cases.append(arena, w);
        var u: Fixture = .init(try std.fmt.allocPrint(arena, "drc_warning/unmarked/{s}", .{sw.side}), &.{"DRC-110"}, unmarked, harness.drc);
        u.layout = try tm2Bars(arena, g);
        try u.claim(arena, .rule("TM2.bR", try c.below(arena, g, 5000)));
        try u.claim(arena, .{ .passes = g >= 5000 });
        try cases.append(arena, u);
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every rule-flag, exemption and warning fixture holds" {
    // Oracle: each fixture's expected answer, derived from the deck's
    // documented reading of a switch, an exemption and a `warning` rule
    // (the doc comments above), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
