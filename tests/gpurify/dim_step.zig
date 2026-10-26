//! LEF `MINSTEP` and `LEF58_MINSTEP` (`min_step`, `min_step_adjacent`,
//! DRC-020) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`min_step_adjacent`, `min_step`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");

/// A bump on a bar, and where its sides stand.
const Bump = struct { layout: Layout, l: i64, r: i64 };

/// The `min_step` rows, in deck order.
const step_ids = [_][]const u8{ "out", "sum", "in", "st", "e1", "e2" };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try minStepAdjacentInto(arena, depth, out);
    try minStepInto(arena, depth, out);
}

// ---- private ----

fn dupe(arena: Allocator, findings: []const Finding) ![]const Finding {
    return arena.dupe(Finding, findings);
}

/// Pinned findings first: the harness pairs greedily, so an unpinned one
/// must not take a pinned one's match.
fn pinnedFirst(arena: Allocator, findings: []const Finding) ![]const Finding {
    const out = try arena.dupe(Finding, findings);
    std.mem.sort(Finding, out, {}, struct {
        fn less(_: void, a: Finding, b: Finding) bool {
            return a.at != null and b.at == null;
        }
    }.less);
    return out;
}

/// A bump `w` wide and `h` high on a 1000 x 200 bar, from x = l to r.
fn bump(arena: Allocator, w: i64, h: i64) !Bump {
    const l = 500 - @divTrunc(w, 2);
    const r = l + w;
    var layout: Layout = .{};
    try layout.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 200 }, .{ r, 200 }, .{ r, 200 + h }, .{ l, 200 + h }, .{ l, 200 }, .{ 0, 200 } });
    return .{ .layout = layout, .l = l, .r = r };
}

/// One `min_step_adjacent` case, its four rows in `adj`, `adj.rect`, `eol`,
/// `between` order.
fn adjacentCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, rows: [4][]const Finding, cases: *std.ArrayList(Fixture)) !void {
    try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_step_adjacent/{s}", .{name}), &.{"DRC-020"}, deck, layout, &.{
        .{ "adj", try pinnedFirst(arena, rows[0]) },
        .{ "adj.rect", try pinnedFirst(arena, rows[1]) },
        .{ "eol", try pinnedFirst(arena, rows[2]) },
        .{ "between", try pinnedFirst(arena, rows[3]) },
    }));
}

/// `LEF58_MINSTEP`'s qualifiers (`min_step_adjacent`, DRC-020), as
/// `OpenROAD` `TritonRoute` reads them, each short edge (under 50) judged
/// by its neighbours in ring order, one finding per offending short edge at
/// the centre of the box of it and the edges judged with it (its
/// neighbours, or the end of line and short edge after it):
/// - `adj`: `min_step(met1; adjacent: 60nm, except_rectangle: false) >=
///   50nm` (`MINADJACENTLENGTH 0.06`), an edge before or after shorter
///   than 60;
/// - `adj.rect`: the same with `except_rectangle: true` (`EXCEPTRECTANGLE`);
/// - `eol`: `min_step(met1; adjacent: 30nm, adjacent_eol: 120nm,
///   except_rectangle: false) >= 50nm` (`NOADJACENTEOL 0.12`), also an end
///   of line (both corners convex) shorter than 120 before or after it;
/// - `between`: `min_step(met1; between_eol: 120nm) >= 50nm`
///   (`NOBETWEENEOL 0.12`), a short edge, an end of line under 120 and a
///   short edge in a row.
///
/// Oracle: `TritonRoute`'s `checkMetalShape_lef58MinStep_minAdjLength` and
/// `_noBetweenEol`, every length by construction and swept one step either
/// side of its limit:
/// - a bump 40 high on a bar, its top swept around 60: each 40 side offends
///   `adj` while the top is under 60, and `eol` always (the top is an end
///   of line under 120); under 50 the top is short too and offends `adj`
///   beside the 40 sides; the side, the top and the other side are one
///   `between` finding;
/// - a bump 40 wide, its height swept around 50: its top (40) offends `adj`
///   only beside sides under 60, and `eol` beside sides under 30; below 50
///   the sides are short too and offend `adj`, `eol` (beside the top's end
///   of line) and `between`;
/// - a 40 x 56 rectangle: its 40 ends offend `adj` beside 56 sides and
///   `eol` beside the sides' ends of line, `EXCEPTRECTANGLE` exempts it,
///   and each end starts a `between` row;
/// - a tab 40 wide on a bar's end, its end of line swept around 120: the
///   tab's 40 top offends `eol` only while that end is under 120, and `adj`
///   once the tab's inner side (200 less the end) is under 60;
/// - a tip 40 long on a bar's end, its end swept around 120: under 120 its
///   two 40 sides offend `eol` and make one `between` row.
fn minStepAdjacentInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule adj min_step(met1; adjacent: 60nm, except_rectangle: false) >= 50nm\n" ++
        "rule adj.rect min_step(met1; adjacent: 60nm, except_rectangle: true) >= 50nm\n" ++
        "rule eol min_step(met1; adjacent: 30nm, adjacent_eol: 120nm, except_rectangle: false) >= 50nm\n" ++
        "rule between min_step(met1; between_eol: 120nm) >= 50nm");
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 60)) |t| {
        const b = try bump(arena, t, 40);
        // The right side's box runs from the top's far end to the bar's right
        // corner, the left side's from the bar's left corner to the top's far
        // end; both 200 to 240 high.
        const sides = [_]Finding{ c.pin(.length(40), b.l + 1000, 440), c.pin(.length(40), b.r, 440) };
        var adj: std.ArrayList(Finding) = .empty;
        if (t < 60) try adj.appendSlice(arena, &sides);
        // Under 50 the top is a short edge too, beside 40 sides; its box is
        // the top and both sides.
        if (t < 50) try adj.append(arena, c.pin(.length(t), b.l + b.r, 440));
        const name = try std.fmt.allocPrint(arena, "bump_top/{s}", .{try c.side(arena, t, 60)});
        try adjacentCase(arena, deck, name, b.layout, .{ adj.items, adj.items, &sides, try dupe(arena, &.{c.pin(.length(40), b.l + b.r, 440)}) }, &cases);
    }
    for (try c.sweep(arena, depth, 50)) |h| {
        if (h <= 0) continue;
        const b = try bump(arena, 40, h);
        // The top's box is the top and both sides.
        const top = c.pin(.length(40), b.l + b.r, 400 + h);
        var adj: std.ArrayList(Finding) = .empty;
        if (h < 60) try adj.append(arena, top);
        // Under 30 the sides are short enough for the `eol` rule's own
        // `MINADJACENTLENGTH 0.03`.
        var eol: std.ArrayList(Finding) = .empty;
        if (h < 30) try eol.append(arena, top);
        var between: std.ArrayList(Finding) = .empty;
        if (h < 50) {
            const sides = [_]Finding{ c.pin(.length(h), b.l + 1000, 400 + h), c.pin(.length(h), b.r, 400 + h) };
            try adj.appendSlice(arena, &sides);
            try eol.appendSlice(arena, &sides);
            try between.append(arena, c.pin(.length(h), b.l + b.r, 400 + h));
        }
        const name = try std.fmt.allocPrint(arena, "bump_height/{s}", .{try c.side(arena, h, 50)});
        try adjacentCase(arena, deck, name, b.layout, .{ adj.items, adj.items, eol.items, between.items }, &cases);
    }
    const ends = [_]Finding{ Finding.length(40).pinned(20, 28), Finding.length(40).pinned(20, 28) };
    try adjacentCase(arena, deck, "rectangle", try c.met1(arena, &.{.{ 0, 0, 40, 56 }}), .{ &ends, &.{}, &ends, &ends }, &cases);
    for (try c.sweep(arena, depth, 120)) |e| {
        const eol: []const Finding = if (e < 120) try dupe(arena, &.{Finding.length(40).pinned(1020, 100)}) else &.{};
        // Past 140 the tab's inner side, 200 - e, is under 60.
        const adj: []const Finding = if (e > 140) try dupe(arena, &.{Finding.length(40).pinned(1020, 100)}) else &.{};
        var tab: Layout = .{};
        try tab.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1040, 0 }, .{ 1040, e }, .{ 1000, e }, .{ 1000, 200 }, .{ 0, 200 } });
        const name = try std.fmt.allocPrint(arena, "tab_end/{s}", .{try c.side(arena, e, 120)});
        try adjacentCase(arena, deck, name, tab, .{ adj, adj, eol, &.{} }, &cases);
    }
    for (try c.sweep(arena, depth, 120)) |e| {
        const short = e < 120;
        const eol: []const Finding = if (short) try dupe(arena, &.{ c.pin(.length(40), 2040, 100 + e), c.pin(.length(40), 2040, 500) }) else &.{};
        const between: []const Finding = if (short) try dupe(arena, &.{c.pin(.length(40), 2040, 200 + e)}) else &.{};
        var tip: Layout = .{};
        try tip.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 1040, 100 }, .{ 1040, 100 + e }, .{ 1000, 100 + e }, .{ 1000, 400 }, .{ 0, 400 } });
        const name = try std.fmt.allocPrint(arena, "tip/{s}", .{try c.side(arena, e, 120)});
        try adjacentCase(arena, deck, name, tip, .{ &.{}, &.{}, eol, between }, &cases);
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "min_step_adjacent", &.{"DRC-020"}, "rule adj min_step(met1; adjacent: 60nm, except_rectangle: false) >= 50nm", &.{"adj"}));
}

/// One `min_step` case: one polygon, a row per rule.
fn stepCase(arena: Allocator, deck: []const u8, name: []const u8, points: []const [2]i64, rows: [6][]const Finding, cases: *std.ArrayList(Fixture)) !void {
    var f: Fixture = .init(try std.fmt.allocPrint(arena, "min_step/{s}", .{name}), &.{"DRC-020"}, deck, harness.drc);
    try f.layout.polygon(arena, "met1", points);
    for (step_ids, rows) |id, found| try f.claim(arena, Expect.rule(id, found));
    try cases.append(arena, f);
}

/// A 1000 square whose top right corner is a staircase of two edges `s`.
fn outsideTwo(s: i64) [6][2]i64 {
    return .{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 1000 - s }, .{ 1000 - s, 1000 - s }, .{ 1000 - s, 1000 }, .{ 0, 1000 } };
}

/// LEF `MINSTEP` variants (`min_step`, DRC-020) at a minStepLength of 50
/// nm: `corner: outside` with and without `length_sum: 80nm`, `corner:
/// inside`, `corner: step`, `max_edges: 1` and `max_edges: 2`. One finding
/// per run of edges shorter than 50 that its row rejects, at the centre of
/// the run's vertices, measuring the run's edge count (or its length, with
/// `length_sum`).
///
/// Oracle: LEF 5.8's own examples. Its Figure 1-14 a (two 40 nm edges at
/// an outside corner, 80 in all) and d (four, 160): "MINSTEP 0.05" rejects
/// both, and "MINSTEP 0.05 LENGTHSUM 0.08" passes a and rejects d (Example
/// 1-16). Figure 1-15's MAXEDGES: more short edges in a row than allowed is
/// a violation, as many is not. Beside them, by construction: two short
/// edges at an inside corner (`inside` only), one short jog between two
/// edges running the same way (`step` only), a 40 nm wide line whose short
/// ends are no corner and no step, and the outside staircase swept at 49,
/// 50 and 51.
fn minStepInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule out min_step(met1; corner: outside, length_sum: none) >= 50nm\n" ++
        "rule sum min_step(met1; corner: outside, length_sum: 80nm) >= 50nm\n" ++
        "rule in min_step(met1; corner: inside, length_sum: none) >= 50nm\n" ++
        "rule st min_step(met1; corner: step, length_sum: none) >= 50nm\n" ++
        "rule e1 min_step(met1; max_edges: 1) >= 50nm\n" ++
        "rule e2 min_step(met1; max_edges: 2) >= 50nm");
    const none: [6][]const Finding = @splat(&.{});
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 50)) |s| {
        if (s <= 0 or s >= 500) continue;
        var rows = none;
        if (s < 50) {
            const two = try dupe(arena, &.{c.pin(c.count(2), 2000 - s, 2000 - s)});
            rows[0] = two;
            if (2 * s > 80) rows[1] = try dupe(arena, &.{c.pin(.length(2 * s), 2000 - s, 2000 - s)});
            rows[4] = two;
        }
        const points = outsideTwo(s);
        try stepCase(arena, deck, try std.fmt.allocPrint(arena, "outside_two/{s}", .{try c.side(arena, s, 50)}), &points, rows, &cases);
    }
    const fig_a = outsideTwo(40);
    try stepCase(arena, deck, "lef_figure_a", &fig_a, .{ &.{c.count(2).pinned(980, 980)}, &.{}, &.{}, &.{}, &.{c.count(2).pinned(980, 980)}, &.{} }, &cases);
    try stepCase(arena, deck, "lef_figure_d", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 920 }, .{ 960, 920 }, .{ 960, 960 }, .{ 920, 960 }, .{ 920, 1000 }, .{ 0, 1000 } }, .{
        &.{c.count(4).pinned(960, 960)},
        &.{Finding.length(160).pinned(960, 960)},
        &.{},
        &.{},
        &.{c.count(4).pinned(960, 960)},
        &.{c.count(4).pinned(960, 960)},
    }, &cases);
    try stepCase(arena, deck, "inside_two", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 500 }, .{ 540, 500 }, .{ 540, 540 }, .{ 500, 540 }, .{ 500, 1000 }, .{ 0, 1000 } }, .{ &.{}, &.{}, &.{c.count(2).pinned(520, 520)}, &.{}, &.{c.count(2).pinned(520, 520)}, &.{} }, &cases);
    try stepCase(arena, deck, "step", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 500 }, .{ 500, 500 }, .{ 500, 540 }, .{ 0, 540 } }, .{ &.{}, &.{}, &.{}, &.{c.count(1).pinned(500, 520)}, &.{}, &.{} }, &cases);
    try stepCase(arena, deck, "line_end", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 40 }, .{ 0, 40 } }, none, &cases);
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every min_step fixture holds" {
    // Oracle: each fixture's expected answer, derived from LEF 5.8's
    // MINSTEP examples and TritonRoute's LEF58_MINSTEP readings (the doc
    // comments above), swept one grid step either side, under every
    // symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
