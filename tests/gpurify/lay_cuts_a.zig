//! Cut spacing, redundant vias and minimum cuts as exhaustive fixtures.
//! Ported from tests/exhaustive/drc_overlay.rs (`cut_spacing`,
//! `redundant_via`, `minimum_cut_thin`, `minimum_cut`).
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
    try cutSpacingInto(arena, out);
    try redundantViaInto(arena, out);
    try minimumCutThinInto(arena, out);
    try minimumCutInto(arena, out);
}

// ---- private ----

/// `n` copies of the finding `f`.
fn repeated(arena: Allocator, f: Finding, n: usize) ![]const Finding {
    const out = try arena.alloc(Finding, n);
    @memset(out, f);
    return out;
}

/// The same pair of cuts on one cut layer and across two.
fn bothInto(arena: Allocator, decks: [2][]const u8, name: []const u8, first: c.Rect, second: c.Rect, findings: []const Finding, cases: *std.ArrayList(Fixture)) !void {
    var one: Layout = .{};
    try c.rects(arena, &one, "cut", &.{ first, second });
    try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cut_spacing/one_layer/{s}", .{name}), &.{"DRC-060"}, decks[0], one, &.{.{ "via.2", findings }}));
    var two: Layout = .{};
    try two.rect(arena, "via1", first[0], first[1], first[2], first[3]);
    try two.rect(arena, "via2", second[0], second[1], second[2], second[3]);
    try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cut_spacing/two_layers/{s}", .{name}), &.{"DRC-065"}, decks[1], two, &.{.{ "v12", findings }}));
}

/// Cut-to-cut spacing `space(cut) >= 100nm` (`min_spacing` on a cut layer,
/// DRC-060) and cross-layer cut spacing `space(via1, via2) >= 100nm`
/// (`min_spacing_diff`, DRC-065): one finding per pair closer than the
/// limit, measuring the Euclidean gap floored.
///
/// Shapes: side by side, swept; diagonal at (60, 79/80/81) beyond the first
/// cut's corner, so the gap is exactly 99.2, 100 and 100.8; two cuts on one
/// layer abutting, and touching only at a corner (one figure, no gap); a
/// via2 stacked on a via1 (0).
fn cutSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    const deck_one = try c.newDeck(arena, &.{"cut"}, "rule via.2 space(cut) >= 100nm\n");
    const deck_two = try c.newDeck(arena, &.{ "via1", "via2" }, "rule v12 space(via1, via2) >= 100nm\n");
    const decks = [2][]const u8{ deck_one, deck_two };
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(limit)) |sw| {
        const g = sw.value;
        try bothInto(arena, decks, try std.fmt.allocPrint(arena, "side/{s}", .{sw.side}), .{ 0, 0, 100, 100 }, .{ 100 + g, 0, 200 + g, 100 }, try c.below(arena, g, limit), &cases);
    }
    const Diagonal = struct { i64, []const u8, []const Finding };
    const diagonals = [_]Diagonal{
        .{ 79, "below", try c.lengths(arena, &.{99}) },
        .{ 80, "at", &.{} },
        .{ 81, "above", &.{} },
    };
    for (diagonals) |d| try bothInto(arena, decks, try std.fmt.allocPrint(arena, "diagonal/{s}", .{d[1]}), .{ 0, 0, 100, 100 }, .{ 160, 100 + d[0], 260, 200 + d[0] }, d[2], &cases);
    var abutting: Layout = .{};
    try c.rects(arena, &abutting, "cut", &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } });
    try cases.append(arena, try c.fixture(arena, "cut_spacing/one_layer/abutting", &.{"DRC-060"}, deck_one, abutting, &.{.{ "via.2", &.{} }}));
    var stacked: Layout = .{};
    try stacked.rect(arena, "via1", 0, 0, 100, 100);
    try stacked.rect(arena, "via2", 0, 0, 100, 100);
    try cases.append(arena, try c.fixture(arena, "cut_spacing/two_layers/stacked", &.{"DRC-065"}, deck_two, stacked, &.{.{ "v12", try c.lengths(arena, &.{0}) }}));
    var corner_touch: Layout = .{};
    try c.rects(arena, &corner_touch, "cut", &.{ .{ 0, 0, 100, 100 }, .{ 100, 100, 200, 200 } });
    try cases.append(arena, try c.fixture(arena, "cut_spacing/one_layer/corner_touch", &.{"DRC-060"}, deck_one, corner_touch, &.{.{ "via.2", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One `redundant_via` fixture: `cuts` beside a far `other` square.
fn redundantCase(arena: Allocator, deck: []const u8, name: []const u8, cuts: []const c.Rect, two: []const Finding, three: []const Finding) !Fixture {
    var l: Layout = .{};
    try l.rect(arena, "other", -1000, -1000, -900, -900);
    try c.rects(arena, &l, "cut", cuts);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "redundant_via/{s}", .{name}), &.{ "DRC-066", "DRC-117" }, deck, l, &.{ .{ "two", two }, .{ "three", three } });
}

/// `redundant_via(cut; within: 100nm) >= 2`, and `>= 3` (`redundant_via`,
/// DRC-066 and DRC-117): one finding per drawn cut with fewer cuts, itself
/// included, within 100 nm (inclusive, Euclidean), measuring the count.
///
/// Shapes: a pair side by side at 99/100/101; a pair diagonal at Euclidean
/// 99.2/100/100.8; one cut alone; two abutting and two overlapping cuts
/// (each counts the other: cuts are counted as drawn); a row of three, where
/// the ends see two and the middle three; an empty layer.
fn redundantViaInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const within: i64 = 100;
    const deck = try c.newDeck(arena, &.{ "cut", "other" }, "rule two redundant_via(cut; within: 100nm) >= 2\nrule three redundant_via(cut; within: 100nm) >= 3\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(within)) |sw| {
        const g = sw.value;
        const alone: u32 = if (g > within) 1 else 2;
        const two: []const Finding = if (g > within) try repeated(arena, c.count(1), 2) else &.{};
        try cases.append(arena, try redundantCase(arena, deck, try std.fmt.allocPrint(arena, "pair/{s}", .{sw.side}), &.{ .{ 0, 0, 100, 100 }, .{ 100 + g, 0, 200 + g, 100 } }, two, try repeated(arena, c.count(alone), 2)));
    }
    const Diagonal = struct { i64, []const u8, bool };
    for ([_]Diagonal{ .{ 79, "below", true }, .{ 80, "at", true }, .{ 81, "above", false } }) |d| {
        const n: u32 = if (d[2]) 2 else 1;
        const two: []const Finding = if (d[2]) &.{} else try repeated(arena, c.count(1), 2);
        try cases.append(arena, try redundantCase(arena, deck, try std.fmt.allocPrint(arena, "diagonal/{s}", .{d[1]}), &.{ .{ 0, 0, 100, 100 }, .{ 160, 100 + d[0], 260, 200 + d[0] } }, two, try repeated(arena, c.count(n), 2)));
    }
    try cases.append(arena, try redundantCase(arena, deck, "single", &.{.{ 0, 0, 100, 100 }}, &.{c.count(1)}, &.{c.count(1)}));
    const pair_of_two = try repeated(arena, c.count(2), 2);
    try cases.append(arena, try redundantCase(arena, deck, "abutting", &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } }, &.{}, pair_of_two));
    try cases.append(arena, try redundantCase(arena, deck, "overlapping", &.{ .{ 0, 0, 100, 100 }, .{ 50, 0, 150, 100 } }, &.{}, pair_of_two));
    try cases.append(arena, try redundantCase(arena, deck, "row_of_three", &.{ .{ 0, 0, 100, 100 }, .{ 200, 0, 300, 100 }, .{ 400, 0, 500, 100 } }, &.{}, pair_of_two));
    try cases.append(arena, try redundantCase(arena, deck, "empty", &.{}, &.{}, &.{}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// A bar `long` x `high` with a 50 wide stub up from x = 1000 and a 30 cut
/// `gap` above the bar's top.
fn stub(arena: Allocator, long: i64, high: i64, gap: i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "m1", 0, 0, long, high);
    try l.rect(arena, "m1", 1000, high, 1050, high + 2000);
    try l.rect(arena, "via", 1010, high + gap, 1040, high + gap + 30);
    return l;
}

/// One `minimum_cut_thin` fixture: `layout` with the `m2` bar over the stub
/// added after it.
fn thinCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, findings: []const Finding) !Fixture {
    var l = layout;
    try l.rect(arena, "m2", 900, -500, 1200, 3000);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "minimum_cut_thin/{s}", .{name}), &.{"DRC-066"}, deck, l, &.{.{ "mct", findings }});
}

/// A one-cut via held: one finding, its count 1, at the cut.
fn heldAt(arena: Allocator, x: i64, y: i64) ![]const Finding {
    return arena.dupe(Finding, &.{c.count(1).pinned(x, y)});
}

/// LEF `MINIMUMCUT 2 WIDTH 0.11 LENGTH 2.0 WITHIN 0.5` on `m1` (Minimum
/// Cut Rule Example 4 scaled by a tenth): `min_cuts(via, m1, m2; width:
/// 110nm, length: 2000nm, distance: 500nm) >= 2` (`minimum_cut`, DRC-066),
/// "the rule applies for thin wires directly connected to wide wires, if
/// the wide wire has a width that is greater than width and a length that
/// is greater than length, and the vias on the thin wire are less than
/// distance from the wide wire ... and does not check the wide wire
/// itself". A one-cut via held is one finding, its count 1, at the cut.
///
/// Oracle: the LEF text and Figure 1-11, wires drawn to a width, a length
/// and a distance, each swept one step either side: a 50 wide stub up from
/// a 200 x 3000 bar with a 30 cut 499, 500 and 501 above the bar (held
/// below 500); the bar 1999, 2000 and 2001 long (held above 2000); the bar
/// 110 and 111 high (wide only above 110). Not held: a cut on the bar
/// itself, a two-cut via on the stub, and a thin wire 100 off the bar but
/// not joined to it.
fn minimumCutThinInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "via", "m1", "m2" }, "rule mct min_cuts(via, m1, m2; width: 110nm, length: 2000nm, distance: 500nm) >= 2\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(500)) |sw| {
        const gap = sw.value;
        const found: []const Finding = if (gap < 500) try heldAt(arena, 1025, 215 + gap) else &.{};
        try cases.append(arena, try thinCase(arena, deck, try std.fmt.allocPrint(arena, "distance/{s}", .{sw.side}), try stub(arena, 3000, 200, gap), found));
    }
    for (c.sweep3(2000)) |sw| {
        const long = sw.value;
        const found: []const Finding = if (long > 2000) try heldAt(arena, 1025, 315) else &.{};
        try cases.append(arena, try thinCase(arena, deck, try std.fmt.allocPrint(arena, "length/{s}", .{sw.side}), try stub(arena, long, 200, 100), found));
    }
    const Width = struct { i64, []const Finding };
    for ([_]Width{ .{ 110, &.{} }, .{ 111, try heldAt(arena, 1025, 226) } }) |w| {
        try cases.append(arena, try thinCase(arena, deck, try std.fmt.allocPrint(arena, "width/{d}", .{w[0]}), try stub(arena, 3000, w[0], 100), w[1]));
    }
    var on_wide: Layout = .{};
    try on_wide.rect(arena, "m1", 0, 0, 3000, 200);
    try on_wide.rect(arena, "via", 1010, 100, 1040, 130);
    try cases.append(arena, try thinCase(arena, deck, "on_the_wide_wire", on_wide, &.{}));
    var two_cuts = try stub(arena, 3000, 200, 100);
    try two_cuts.rect(arena, "via", 1010, 360, 1040, 390);
    try cases.append(arena, try thinCase(arena, deck, "two_cuts", two_cuts, &.{}));
    var not_joined: Layout = .{};
    try not_joined.rect(arena, "m1", 0, 0, 3000, 200);
    try not_joined.rect(arena, "m1", 1000, 300, 1050, 2300);
    try not_joined.rect(arena, "via", 1010, 400, 1040, 430);
    try cases.append(arena, try thinCase(arena, deck, "not_joined", not_joined, &.{}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One `minimum_cut` fixture: each count a finding of `mc` or `mcw`.
fn minCutCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, mc: []const u32, mcw: []const u32) !Fixture {
    const counts = struct {
        fn of(a: Allocator, n: []const u32) ![]const Finding {
            const fs = try a.alloc(Finding, n.len);
            for (n, fs) |v, *f| f.* = c.count(v);
            return fs;
        }
    }.of;
    return c.fixture(arena, try std.fmt.allocPrint(arena, "minimum_cut/{s}", .{name}), &.{"DRC-066"}, deck, layout, &.{ .{ "mc", try counts(arena, mc) }, .{ "mcw", try counts(arena, mcw) } });
}

/// The 3000 nm `m1` plate every `minimum_cut` case starts from.
fn plate(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "m1", 0, 0, 3000, 3000);
    return l;
}

/// LEF `MINIMUMCUT 2 WIDTH 1.0` on `m1`, vias from `m2`: `min_cuts(via, m1,
/// m2; width: 1000nm) >= 2` (`mc`) and with `within: 300nm` (`mcw`,
/// `MINIMUMCUT 2 WIDTH 1.0 WITHIN 0.3`) (`minimum_cut`, DRC-066): a via is
/// the cuts joining one `m1` figure to one `m2` figure, split by `within`
/// into groups of cuts closer than 300 nm; one held by the part of `m1`
/// wider than 1000 nm needs two cuts, and each of its cuts is reported with
/// its count.
///
/// Oracle: LEF/DEF 5.8 "the number of cuts a via must have when it is on a
/// wide wire or pin whose width is greater than width", on vias and wires
/// drawn to a count and a width.
///
/// Shapes, 100 nm cuts on a 3000 nm `m1` plate: one cut under an `m2` pad;
/// two under one pad 200 apart (one via, one group) and 400 apart (one via,
/// two groups under `within`); two cuts under two pads (two vias); a cut
/// with no `m2` over it; a wire 999, 1000 and 1001 wide with one cut (held
/// only when strictly wider); a cut on a 500 nm tab off the plate (not
/// held); a cut on no `m1` (not held).
fn minimumCutInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "via", "m1", "m2" }, "rule mc min_cuts(via, m1, m2; width: 1000nm) >= 2\nrule mcw min_cuts(via, m1, m2; width: 1000nm, within: 300nm) >= 2\n");
    var cases: std.ArrayList(Fixture) = .empty;
    var single = try plate(arena);
    try single.rect(arena, "via", 1000, 1000, 1100, 1100);
    try single.rect(arena, "m2", 900, 900, 1200, 1200);
    try cases.append(arena, try minCutCase(arena, deck, "single", single, &.{1}, &.{1}));
    const Pair = struct { i64, []const u8, []const u32 };
    for ([_]Pair{ .{ 200, "pair_close", &.{} }, .{ 400, "pair_far", &.{ 1, 1 } } }) |p| {
        const x = 1100 + p[0];
        var l = try plate(arena);
        try l.rect(arena, "via", 1000, 1000, 1100, 1100);
        try l.rect(arena, "via", x, 1000, x + 100, 1100);
        try l.rect(arena, "m2", 900, 900, x + 200, 1200);
        try cases.append(arena, try minCutCase(arena, deck, p[1], l, &.{}, p[2]));
    }
    var two_pads = try plate(arena);
    try two_pads.rect(arena, "via", 1000, 1000, 1100, 1100);
    try two_pads.rect(arena, "via", 1300, 1000, 1400, 1100);
    try two_pads.rect(arena, "m2", 900, 900, 1150, 1200);
    try two_pads.rect(arena, "m2", 1250, 900, 1500, 1200);
    try cases.append(arena, try minCutCase(arena, deck, "two_pads", two_pads, &.{ 1, 1 }, &.{ 1, 1 }));
    var no_far = try plate(arena);
    try no_far.rect(arena, "via", 1000, 1000, 1100, 1100);
    try cases.append(arena, try minCutCase(arena, deck, "no_far_metal", no_far, &.{1}, &.{1}));
    const Wire = struct { i64, bool };
    for ([_]Wire{ .{ 999, false }, .{ 1000, false }, .{ 1001, true } }) |w| {
        const one: []const u32 = if (w[1]) &.{1} else &.{};
        var l: Layout = .{};
        try l.rect(arena, "m1", 0, 0, 5000, w[0]);
        try l.rect(arena, "via", 2000, 100, 2100, 200);
        try l.rect(arena, "m2", 1900, 0, 2200, 300);
        try cases.append(arena, try minCutCase(arena, deck, try std.fmt.allocPrint(arena, "wire/{d}", .{w[0]}), l, one, one));
    }
    var narrow_tab = try plate(arena);
    try narrow_tab.rect(arena, "m1", 3000, 1000, 4000, 1500);
    try narrow_tab.rect(arena, "via", 3500, 1200, 3600, 1300);
    try narrow_tab.rect(arena, "m2", 3400, 1100, 3700, 1400);
    try cases.append(arena, try minCutCase(arena, deck, "narrow_tab", narrow_tab, &.{}, &.{}));
    var off_metal = try plate(arena);
    try off_metal.rect(arena, "via", 5000, 5000, 5100, 5100);
    try off_metal.rect(arena, "m2", 4900, 4900, 5200, 5200);
    try cases.append(arena, try minCutCase(arena, deck, "off_metal", off_metal, &.{}, &.{}));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every cut-spacing and minimum-cut fixture holds" {
    // Oracle: each gap, count and wire dimension is drawn by construction
    // (the LEF MINIMUMCUT text and Figure 1-11 for the minimum cuts); every
    // finding follows from it and the rule's bound, under every symmetry at
    // two translations.
    try c.checkGenerated(fixturesInto);
}
