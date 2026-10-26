//! Multi-patterning: colouring, anchored colouring and pre-coloured mask
//! spacing, as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`bar_cycle`, `multi_patterning`,
//! `colour_spacing`, `anchored_patterning`).
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
    try multiPatterningInto(arena, depth, out);
    try colourSpacingInto(arena, out);
    try anchoredPatterningInto(arena, out);
}

// ---- private ----

/// A cycle of `n >= 4` bars around a 4000 nm square frame, each `gap` from
/// the next and far from every other: the bottom side split into `ceil((n -
/// 2) / 2)` bars, the top into the rest, and one bar up each side.
fn barCycle(arena: Allocator, n: i64, gap: i64) !Layout {
    const s: i64 = 4000;
    const t: i64 = 100;
    const bottom = @divTrunc(n - 1, 2);
    const top = n - 2 - bottom;
    var layout: Layout = .{};
    try layout.rect(arena, "met1", s - t, t + gap, s, s);
    try layout.rect(arena, "met1", 0, t + gap, t, s - t - gap);
    try piecesInto(arena, &layout, s, bottom, gap, 0, t);
    try piecesInto(arena, &layout, s - t - gap, top, gap, s - t, s);
    return layout;
}

/// `k` bars splitting `[0, to]` with `gap` between, each spanning `[ylo, yhi]`.
fn piecesInto(arena: Allocator, layout: *Layout, to: i64, k: i64, gap: i64, ylo: i64, yhi: i64) !void {
    const len = @divTrunc(to - (k - 1) * gap, k);
    var i: i64 = 0;
    while (i < k) : (i += 1) {
        const lo = i * (len + gap);
        try layout.rect(arena, "met1", lo, ylo, if (i == k - 1) to else lo + len, yhi);
    }
}

/// `patterning(met1; colors: k) >= 100nm` for k of 1, 2 and 3
/// (`multi_patterning`, DRC-100, DRC-101): figures closer than 100 nm
/// conflict, and a layer whose conflict graph needs more than k masks is one
/// finding counting k + 1; an empty layer is skipped.
///
/// Each layout's chromatic number is known by construction: a triangle of
/// mutual gaps 99/100/101 (3, or 1 when no gap conflicts); a pair at 99/100/
/// 101 (2 or 1); cycles of 4 to 7 bars (2 when even, 3 when odd); a 2 x 2
/// block at 50 nm whose diagonals are 70.7 apart (K4, 4); a triangle whose
/// two lower shapes abut, merging into one figure (2); two squares touching
/// only at a corner (one figure, 1); a shape drawn inside another, 50 nm from
/// its boundary (one figure, 1), and that pair beside a third (2); an island
/// 50 nm inside a ring's hole (a real gap, 2); one shape (1); none. A figure
/// whose own notch is below 100 nm conflicts with itself (Calibre's
/// self-conflict) and no palette colours it: a U whose arms are 99/100/101
/// apart, and a ring whose slot hole is (one figure, 1, at 100 and above).
/// Nightly: cycles of 4 to 15 bars.
fn multiPatterningInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "other" }, "rule mp1 patterning(met1; colors: 1) >= 100nm\n" ++
        "rule mp2 patterning(met1; colors: 2) >= 100nm\n" ++
        "rule mp3 patterning(met1; colors: 3) >= 100nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(100)) |sw| {
        const g = sw.value;
        const conflicts = g < 100;
        var triangle: Layout = .{};
        try c.rects(arena, &triangle, "met1", &.{ .{ 0, 0, 500, 500 }, .{ 500 + g, 0, 1000 + g, 500 }, .{ 0, 500 + g, 1000 + g, 1000 + g } });
        try cases.append(arena, try mpCase(arena, deck, try std.fmt.allocPrint(arena, "triangle/{s}", .{sw.side}), triangle, if (conflicts) 3 else 1));
        const notched: u32 = if (conflicts) std.math.maxInt(u32) else 1;
        var u: Layout = .{};
        try u.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000 + g, 0 }, .{ 1000 + g, 2000 }, .{ 500 + g, 2000 }, .{ 500 + g, 500 }, .{ 500, 500 }, .{ 500, 2000 }, .{ 0, 2000 } });
        try cases.append(arena, try mpCase(arena, deck, try std.fmt.allocPrint(arena, "u_notch/{s}", .{sw.side}), u, notched));
        var slot: Layout = .{};
        try c.ring(arena, &slot, "met1", .{ 0, 0, 2000, 2000 }, .{ 900, 500, 900 + g, 1500 });
        try cases.append(arena, try mpCase(arena, deck, try std.fmt.allocPrint(arena, "slot_hole/{s}", .{sw.side}), slot, notched));
        const pair = try c.met1(arena, &.{ .{ 0, 0, 500, 500 }, .{ 500 + g, 0, 1000 + g, 500 } });
        try cases.append(arena, try mpCase(arena, deck, try std.fmt.allocPrint(arena, "pair/{s}", .{sw.side}), pair, if (conflicts) 2 else 1));
    }
    const longest: i64 = switch (depth) {
        .nightly => 15,
        .merge => 7,
    };
    var n: i64 = 4;
    while (n <= longest) : (n += 1) {
        try cases.append(arena, try mpCase(arena, deck, try std.fmt.allocPrint(arena, "cycle/{d}", .{n}), try barCycle(arena, n, 50), if (@mod(n, 2) == 0) 2 else 3));
    }
    try cases.append(arena, try mpCase(arena, deck, "k4", try c.met1(arena, &.{ .{ 0, 0, 500, 500 }, .{ 550, 0, 1050, 500 }, .{ 0, 550, 500, 1050 }, .{ 550, 550, 1050, 1050 } }), 4));
    try cases.append(arena, try mpCase(arena, deck, "merged_triangle", try c.met1(arena, &.{ .{ 0, 0, 500, 500 }, .{ 500, 0, 1000, 500 }, .{ 0, 550, 1000, 1050 } }), 2));
    try cases.append(arena, try mpCase(arena, deck, "single", try c.met1(arena, &.{.{ 0, 0, 500, 500 }}), 1));
    // An island 50 nm inside a ring's hole is a real gap; a shape drawn
    // inside another's material, its boundary 50 nm from the other's, is one
    // figure with it.
    var island = try c.met1(arena, &.{.{ 550, 550, 1450, 1450 }});
    try c.ring(arena, &island, "met1", .{ 0, 0, 2000, 2000 }, .{ 500, 500, 1500, 1500 });
    try cases.append(arena, try mpCase(arena, deck, "island_in_hole", island, 2));
    try cases.append(arena, try mpCase(arena, deck, "drawn_inside", try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 50, 50, 1950, 1950 } }), 1));
    try cases.append(arena, try mpCase(arena, deck, "corner_touch", try c.met1(arena, &.{ .{ 0, 0, 500, 500 }, .{ 500, 500, 1000, 1000 } }), 1));
    try cases.append(arena, try mpCase(arena, deck, "drawn_inside_beside_one", try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 50, 50, 1950, 1950 }, .{ 2050, 0, 2550, 2000 } }), 2));
    var empty: Fixture = .init("multi_patterning/empty", &.{"DRC-100"}, deck, harness.drc);
    try empty.layout.rect(arena, "other", 0, 0, 100, 100);
    for ([_][]const u8{ "mp1", "mp2", "mp3" }) |id| try empty.claim(arena, .outcome(id, .skipped));
    try cases.append(arena, empty);
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One `multi_patterning` case: each `mpk` row finds one count of k + 1
/// when the layout's chromatic number is above k.
fn mpCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, chromatic: u32) !Fixture {
    var rows: [3]c.Row = undefined;
    for (&rows, [_][]const u8{ "mp1", "mp2", "mp3" }, 1..) |*r, id, k| {
        r.* = .{ id, if (chromatic > k) try arena.dupe(Finding, &.{c.count(@intCast(k + 1))}) else &.{} };
    }
    return c.fixture(arena, try std.fmt.allocPrint(arena, "multi_patterning/{s}", .{name}), &.{ "DRC-100", "DRC-101" }, deck, layout, &rows);
}

/// Same-mask and different-mask spacing of pre-coloured shapes (DRC-102),
/// as a deck writes LEF `SPACING ... SAMEMASK`: each mask's shapes are a
/// layer (`met1 and c1`), so same-mask spacing is `space` on it and
/// different-mask spacing is `space` between two of them. Two 500 x 500
/// squares `g` apart, swept about the 100 nm same-mask limit: both on mask
/// 1, the same-mask rule reports the gap below it; one on each mask, only
/// the 40 nm different-mask rule applies and the gap clears it.
fn colourSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "c1", "c2" }, "rule same space(met1 and c1) >= 100nm\n" ++
        "rule apart space(met1 and c1, met1 and c2) >= 40nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(100)) |sw| {
        const g = sw.value;
        for ([_][]const u8{ "same", "apart" }) |mode| {
            var squares = try c.met1(arena, &.{ .{ 0, 0, 500, 500 }, .{ 500 + g, 0, 1000 + g, 500 } });
            try squares.rect(arena, "c1", 0, 0, 500, 500);
            const same = std.mem.eql(u8, mode, "same");
            try squares.rect(arena, if (same) "c1" else "c2", 500 + g, 0, 1000 + g, 500);
            try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "colour_spacing/{s}/{s}", .{ mode, sw.side }), &.{"DRC-102"}, deck, squares, &.{
                .{ "same", if (same) try c.below(arena, g, 100) else &.{} },
                .{ "apart", &.{} },
            }));
        }
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `patterning(met1, c1, c2; colors: 2) >= 100nm` (`anchored_patterning`,
/// DRC-101, DRC-102): a figure sharing area with a `c1` shape must take mask
/// 1, with a `c2` shape mask 2, and an anchor conflict is a component two
/// masks can split but not with its anchors. Its finding names the lowest
/// anchored figure and the first whose chain of conflicts to it has the
/// wrong parity, at the middle of the gap between them, or one figure both
/// anchor layers claim, at its centre; it measures 3 masks against 2. The
/// plain `patterning(met1; colors: 2)` row beside it reports what no split
/// fixes.
///
/// Bars 100 x 500, 150 apart in x (a 50 gap, a conflict), in a chain, as
/// US8473873B2's FIG. 1, 5 and 6: four bars anchored alike at both ends
/// (three conflicts, odd: an anchor path), or apart (honoured); five bars
/// (four conflicts) alike (honoured) or apart (a path); four unanchored; the
/// end anchored only in part (any overlap anchors); an anchor that only
/// touches its bar (no anchor); one bar under both anchor layers (anchor
/// self-conflict); a triangle with an anchor (no split at all: the plain
/// row's). With three masks: a triangle with two corners anchored to mask 1
/// (the lowest anchored, 4 against 3), and with one anchor per mask
/// (honoured). The empty layer is skipped.
fn anchoredPatterningInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "c1", "c2", "c3" }, "rule odd patterning(met1; colors: 2) >= 100nm\n" ++
        "rule ap patterning(met1, c1, c2; colors: 2) >= 100nm\n" ++
        "rule ap3 patterning(met1, c1, c2, c3; colors: 3) >= 100nm\n");
    const Anchor = struct { []const u8, c.Rect };
    const Case = struct { name: []const u8, triangle: bool, bars: i64, anchors: []const Anchor, odd: []const Finding, ap: []const Finding, ap3: []const Finding };
    const cases_spec = [_]Case{
        .{ .name = "chain4/alike", .triangle = false, .bars = 4, .anchors = &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c1", .{ 450, 0, 550, 500 } } }, .odd = &.{}, .ap = &.{c.count(3).pinned(275, 250)}, .ap3 = &.{} },
        .{ .name = "chain4/apart", .triangle = false, .bars = 4, .anchors = &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c2", .{ 450, 0, 550, 500 } } }, .odd = &.{}, .ap = &.{}, .ap3 = &.{} },
        .{ .name = "chain5/alike", .triangle = false, .bars = 5, .anchors = &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c1", .{ 600, 0, 700, 500 } } }, .odd = &.{}, .ap = &.{}, .ap3 = &.{} },
        .{ .name = "chain5/apart", .triangle = false, .bars = 5, .anchors = &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c2", .{ 600, 0, 700, 500 } } }, .odd = &.{}, .ap = &.{c.count(3).pinned(350, 250)}, .ap3 = &.{} },
        .{ .name = "chain4/unanchored", .triangle = false, .bars = 4, .anchors = &.{}, .odd = &.{}, .ap = &.{}, .ap3 = &.{} },
        .{ .name = "chain4/partial_anchor", .triangle = false, .bars = 4, .anchors = &.{ .{ "c1", .{ 0, 0, 50, 50 } }, .{ "c1", .{ 450, 0, 550, 500 } } }, .odd = &.{}, .ap = &.{c.count(3).pinned(275, 250)}, .ap3 = &.{} },
        .{ .name = "chain4/touching_anchor", .triangle = false, .bars = 4, .anchors = &.{ .{ "c1", .{ -100, 0, 0, 500 } }, .{ "c1", .{ 450, 0, 550, 500 } } }, .odd = &.{}, .ap = &.{}, .ap3 = &.{} },
        .{ .name = "self_conflict", .triangle = false, .bars = 1, .anchors = &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c2", .{ 0, 0, 100, 500 } } }, .odd = &.{}, .ap = &.{c.count(3).pinned(50, 250)}, .ap3 = &.{c.count(4).pinned(50, 250)} },
        .{ .name = "odd_cycle", .triangle = true, .bars = 0, .anchors = &.{.{ "c1", .{ 0, 0, 500, 500 } }}, .odd = &.{c.count(3)}, .ap = &.{}, .ap3 = &.{} },
        .{ .name = "triangle/alike", .triangle = true, .bars = 0, .anchors = &.{ .{ "c1", .{ 0, 0, 500, 500 } }, .{ "c1", .{ 550, 0, 1050, 500 } } }, .odd = &.{c.count(3)}, .ap = &.{}, .ap3 = &.{c.count(4).pinned(250, 250)} },
        .{ .name = "triangle/each", .triangle = true, .bars = 0, .anchors = &.{ .{ "c1", .{ 0, 0, 500, 500 } }, .{ "c2", .{ 550, 0, 1050, 500 } }, .{ "c3", .{ 0, 550, 1050, 1050 } } }, .odd = &.{c.count(3)}, .ap = &.{}, .ap3 = &.{} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_spec) |spec| {
        var layout: Layout = .{};
        if (spec.triangle) {
            try c.rects(arena, &layout, "met1", &.{ .{ 0, 0, 500, 500 }, .{ 550, 0, 1050, 500 }, .{ 0, 550, 1050, 1050 } });
        } else {
            var i: i64 = 0;
            while (i < spec.bars) : (i += 1) try layout.rect(arena, "met1", 150 * i, 0, 150 * i + 100, 500);
        }
        for (spec.anchors) |a| try layout.rect(arena, a[0], a[1][0], a[1][1], a[1][2], a[1][3]);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "anchored_patterning/{s}", .{spec.name}), &.{ "DRC-101", "DRC-102" }, deck, layout, &.{ .{ "odd", spec.odd }, .{ "ap", spec.ap }, .{ "ap3", spec.ap3 } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
    var empty: Fixture = .init("anchored_patterning/empty", &.{"DRC-101"}, deck, harness.drc);
    try empty.layout.rect(arena, "c1", 0, 0, 100, 100);
    try empty.claim(arena, .outcome("ap", .skipped));
    try empty.claim(arena, .outcome("ap3", .skipped));
    try out.append(arena, empty);
}

test "every multi-patterning fixture holds" {
    // Oracle: each fixture's expected answer, derived by construction from
    // the conflict graph's chromatic number and anchor parity (the doc
    // comments above), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
