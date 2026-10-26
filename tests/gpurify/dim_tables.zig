//! The spacing tables (DRC-025, DRC-026, DRC-027, DRC-031) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs
//! (`spacing_table`, `two_width_spacing_table`, `tip_spacing_table`).
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

/// The table every `spacing_table` fixture uses: 180 everywhere, 220 for a
/// pair whose wider shape is wider than 300 running alongside for more than
/// 1000.
const table =
    \\rule t space_table(met1;
    \\    prl:   [0nm, 1000nm],
    \\    width: [0nm, 300nm],
    \\    space: [[180nm, 180nm],
    \\            [180nm, 220nm]])
;

/// LEF/DEF 5.8's two-width table ("Two-Width Spacing Tables"), in
/// nanometres: widths 0, 0.25, 1.5 and 3.0 µm with runs none, 0, 1.5 and
/// 3.0 µm, and the manual's cells.
const two_widths =
    \\rule t two_width_table(met1;
    \\    width: [0nm, 250nm, 1500nm, 3000nm],
    \\    prl:   [none, 0nm, 1500nm, 3000nm],
    \\    space: [[150nm, 200nm, 500nm, 1000nm],
    \\            [200nm, 250nm, 500nm, 1000nm],
    \\            [500nm, 500nm, 600nm, 1000nm],
    \\            [1000nm, 1000nm, 1000nm, 1200nm]])
;

/// The ASAP7 M1 tip table (DRM r1p7, Table 3.12.1): edges below 24 nm, from
/// 24 to 36 nm, and above 36 nm; M1.S.1 side to side 18, M1.S.2 tip to side
/// 25, M1.S.3 tip to tip 27 (both 24 to 36), M1.S.4 31 (both below 24),
/// M1.S.5 31 (one of each).
const tips_table =
    \\rule t tip_space_table(met1;
    \\    length: [0nm, 24nm, 37nm],
    \\    space: [[31nm, 31nm, 25nm],
    \\            [31nm, 27nm, 25nm],
    \\            [25nm, 25nm, 18nm]])
;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try spacingTableInto(arena, depth, out);
    try twoWidthSpacingTableInto(arena, depth, out);
    try tipSpacingTableInto(arena, depth, out);
}

// ---- private ----

/// One finding at the doubled midpoint `(x2, y2)` when `g < need`.
fn found(arena: Allocator, g: i64, need: i64, x2: i64, y2: i64) ![]const Finding {
    return if (g < need) arena.dupe(Finding, &.{c.pin(.length(g), x2, y2)}) else &.{};
}

/// A one-row fixture on rule `t`.
fn tableCase(arena: Allocator, name: []const u8, catalog: []const []const u8, deck: []const u8, layout: Layout, findings: []const Finding) !Fixture {
    return c.fixture(arena, name, catalog, deck, layout, &.{.{ "t", findings }});
}

/// A `wa`-wide line and a 100-wide one, `g` apart, overlapping by `r`.
fn tablePair(arena: Allocator, deck: []const u8, name: []const u8, catalog: []const []const u8, wa: i64, g: i64, r: i64) !Fixture {
    const column: usize = @intFromBool(r > 1000);
    const row_need: i64 = if (wa > 300) ([2]i64{ 180, 220 })[column] else 180;
    const findings = try found(arena, g, @max(row_need, 180), 2 * wa + g, 4000 - r);
    return tableCase(arena, try std.fmt.allocPrint(arena, "spacing_table/{s}", .{name}), catalog, deck, try c.met1(arena, &.{ .{ 0, 0, wa, 2000 }, .{ wa + g, 2000 - r, wa + g + 100, 4000 - r } }), findings);
}

/// `space_table` (`spacing_table`, DRC-025, DRC-026, DRC-027): the column of
/// the last `prl` strictly exceeded by the run of the merged figures' edges
/// facing each other at most that column's cell apart, the row of the last
/// `width` the wider shape strictly exceeds (measured on its part that
/// wide), the first row always applied to whole shapes. One finding per
/// pair, measuring its distance, at the midpoint of the points it measured.
///
/// A `wa`-wide line beside a 100-wide one, `g` apart with a run `r`: the
/// width swept around 300 (exactly 300 is the first row), the run around
/// 1000 (exactly 1000 is the first column), the gap around 220 and, for two
/// thin lines, around 180. A thin tab of a wide plate is held to the first
/// row only; a ring's own hole is never a pair; touching lines are one
/// figure. A wire drawn as short segments takes the column of its whole
/// run. An L whose box would overstate the run, and a pair whose long run
/// lies past the cell it would select, keep the first column (F49).
fn spacingTableInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, table);
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 300)) |wa| try cases.append(arena, try tablePair(arena, deck, try std.fmt.allocPrint(arena, "width/{s}", .{try c.side(arena, wa, 300)}), &.{ "DRC-025", "DRC-027" }, wa, 200, 2000));
    for (try c.sweep(arena, depth, 1000)) |r| try cases.append(arena, try tablePair(arena, deck, try std.fmt.allocPrint(arena, "run/{s}", .{try c.side(arena, r, 1000)}), &.{"DRC-026"}, 400, 200, r));
    for (try c.sweep(arena, depth, 220)) |g| try cases.append(arena, try tablePair(arena, deck, try std.fmt.allocPrint(arena, "gap_wide/{s}", .{try c.side(arena, g, 220)}), &.{ "DRC-025", "DRC-026" }, 400, g, 2000));
    for (try c.sweep(arena, depth, 180)) |g| try cases.append(arena, try tablePair(arena, deck, try std.fmt.allocPrint(arena, "gap_thin/{s}", .{try c.side(arena, g, 180)}), &.{"DRC-026"}, 100, g, 2000));
    var thin_tab: Layout = .{};
    try thin_tab.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, 4000 }, .{ 900, 4000 }, .{ 900, 2000 }, .{ 0, 2000 } });
    try thin_tab.rect(arena, "met1", 1200, 2500, 1300, 4000);
    var own_hole: Layout = .{};
    try own_hole.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 2000, 2000 }, .{ 100, 100, 1900, 1900 }));
    const clean = [_]struct { []const u8, Layout }{
        .{ "thin_tab_first_row", thin_tab },
        .{ "own_hole", own_hole },
        .{ "touching", try c.met1(arena, &.{ .{ 0, 0, 400, 2000 }, .{ 400, 0, 500, 2000 } }) },
    };
    for (clean) |s| try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "spacing_table/{s}", .{s[0]}), &.{"DRC-025"}, deck, s[1], &.{}));
    // A 400-wide line and an L, 200 apart only where the L's top arm reaches
    // in, over y = 1900..2000 (run 100); its long arm faces the line 1100
    // away, past every cell. The run is 100, column 0: 180, and 200 is
    // clean. The boxes would overlap by 2000 on y (column 1: 220, F49).
    var l_box: Layout = .{};
    try l_box.rect(arena, "met1", 0, 0, 400, 2000);
    try l_box.polygon(arena, "met1", &.{ .{ 1500, 0 }, .{ 1600, 0 }, .{ 1600, 2000 }, .{ 600, 2000 }, .{ 600, 1900 }, .{ 1500, 1900 } });
    try cases.append(arena, try tableCase(arena, "spacing_table/l_box_overstates_run", &.{"DRC-026"}, deck, l_box, &.{}));
    // Each cell takes the run of the edges facing closer than itself. Two
    // thin lines (row 0: 180, then 200 past a 1000 run): a bar 230 off
    // running 3000, and a stub on it reaching to 190 for 50. Within 200 the
    // run is the stub's 50, so column 0 holds: 190 is clean. The bar's run
    // counts only for a cell wider than 230.
    const within_deck = try c.oneLayerDeck(arena,
        \\rule t space_table(met1;
        \\    prl:   [0nm, 1000nm],
        \\    width: [0nm, 300nm],
        \\    space: [[180nm, 200nm],
        \\            [180nm, 260nm]])
    );
    try cases.append(arena, try tableCase(arena, "spacing_table/run_within_the_cell", &.{"DRC-026"}, within_deck, try c.met1(arena, &.{ .{ 0, 0, 100, 3000 }, .{ 330, 0, 430, 3000 }, .{ 290, 1000, 330, 1050 } }), &.{}));
    // A 400-wide line and a 100-wide one 200 apart, running 2000 alongside,
    // the thin one drawn as four 500-long segments: the figures' run passes
    // 1000, so each segment's pair is held to 220; read off each segment's
    // box (run 500: 180), the wire would escape the second column.
    try cases.append(arena, try tableCase(arena, "spacing_table/segmented_run", &.{"DRC-026"}, deck, try c.met1(arena, &.{ .{ 0, 0, 400, 2000 }, .{ 600, 0, 700, 500 }, .{ 600, 500, 700, 1000 }, .{ 600, 1000, 700, 1500 }, .{ 600, 1500, 700, 2000 } }), &.{
        Finding.length(200).pinned(500, 250),
        Finding.length(200).pinned(500, 750),
        Finding.length(200).pinned(500, 1250),
        Finding.length(200).pinned(500, 1750),
    }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "spacing_table", &.{"DRC-025"}, table, &.{"t"}));
}

/// `two_width_table` (`two_width_spacing_table`, DRC-027): a pair needs the
/// cell at the last width that applies to each shape, a width applying to
/// a shape wider than it whose figures run alongside for more than its run.
///
/// LEF's own worked example (SE), each case's gap swept one step around its
/// space: widths 250 and 250 with no run, 150; 250 and 260 with no run,
/// 150; 250 and 260 with a run of 100, 200; 260 and 260 with a run of 100,
/// 250. The 1500 run swept around 1500 between two 1600 wide plates 550
/// apart (600 only past it). A 260 wide line 220 from the thin tab of a
/// 2 µm plate is clean: the plate is wide, the tab is not (holding the
/// whole shape to its widest part would ask 250). A ring's own hole, and
/// touching shapes, are no pair.
fn twoWidthSpacingTableInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, two_widths);
    var cases: std.ArrayList(Fixture) = .empty;
    // Lines `wa` and `wb` wide, `g` apart, overlapping by `r` along y.
    const examples = [_]struct { []const u8, i64, i64, i64, i64 }{
        .{ "w250_w250_run0", 250, 250, 0, 150 },
        .{ "w250_w260_run0", 250, 260, 0, 150 },
        .{ "w250_w260_run100", 250, 260, 100, 200 },
        .{ "w260_w260_run100", 260, 260, 100, 250 },
    };
    for (examples) |e| {
        const example, const wa, const wb, const r, const need = e;
        for (try c.sweep(arena, depth, need)) |g| {
            try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "two_width_spacing_table/lef_example/{s}/{s}", .{ example, try c.side(arena, g, need) }), &.{"DRC-027"}, deck, try c.met1(arena, &.{ .{ 0, 0, wa, 2000 }, .{ wa + g, 2000 - r, wa + g + wb, 4000 - r } }), try found(arena, g, need, 2 * wa + g, 4000 - r)));
        }
    }
    for (try c.sweep(arena, depth, 1500)) |r| {
        const findings: []const Finding = if (r > 1500) try arena.dupe(Finding, &.{c.pin(.length(550), 3750, 6000 - r)}) else &.{};
        try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "two_width_spacing_table/run_1500/{s}", .{try c.side(arena, r, 1500)}), &.{"DRC-027"}, deck, try c.met1(arena, &.{ .{ 0, 0, 1600, 3000 }, .{ 2150, 3000 - r, 3750, 6000 - r } }), findings));
    }
    try cases.append(arena, try tableCase(arena, "two_width_spacing_table/thin_tab_is_thin", &.{"DRC-027"}, deck, try c.met1(arena, &.{ .{ 0, 0, 2000, 2000 }, .{ 900, 2000, 1000, 3000 }, .{ 1220, 2500, 1480, 4000 } }), &.{}));
    var own_hole: Layout = .{};
    try own_hole.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 2000, 2000 }, .{ 100, 100, 1900, 1900 }));
    try cases.append(arena, try tableCase(arena, "two_width_spacing_table/own_hole", &.{"DRC-027"}, deck, own_hole, &.{}));
    try cases.append(arena, try tableCase(arena, "two_width_spacing_table/touching", &.{"DRC-027"}, deck, try c.met1(arena, &.{ .{ 0, 0, 400, 2000 }, .{ 400, 0, 500, 2000 } }), &.{}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "two_width_spacing_table", &.{"DRC-027"}, two_widths, &.{"t"}));
}

/// Two lines `wa` and `wb` wide, tip to tip `g` apart, both starting at
/// x = 0: they face each other over the narrower width.
fn tips(arena: Allocator, wa: i64, wb: i64, g: i64) !Layout {
    return c.met1(arena, &.{ .{ 0, 0, wa, 1000 }, .{ 0, 1000 + g, wb, 2000 + g } });
}

/// The tip table's cell for two tips both `w` wide.
fn classNeed(w: i64) i64 {
    return if (w < 24) 31 else if (w < 37) 27 else 18;
}

/// `tip_space_table` (`tip_spacing_table`, DRC-031): whole edges of the
/// merged layer in different figures that face each other over a positive
/// run need the cell of their two length classes; one finding per pair of
/// figures, its smallest offending gap, at the middle of the stretch the
/// two edges face each other over.
///
/// Each ASAP7 rule's gap swept around its value (FR; positive gaps only, as
/// shapes that touch merge): side to side, tip to side from a 20 and from a
/// 30 wide line, tip to tip at both widths and mixed. Each class boundary
/// swept at a gap between its two cells: tips 23, 24 and 25 wide 28 apart
/// (31 below 24, 27 from it), and 36, 37 and 38 wide 20 apart (27 to 36, 18
/// above). Clean: a diagonal pair (no run), a notch inside one figure, and
/// a 30 wide tip drawn as two 15 wide strips 28 from another (one 30 wide
/// end, 27; a check classing drawn edges would ask 31). Three bars, two
/// findings; a figure facing a bar 15 and 10 away along two steps, one
/// finding at the nearer.
fn tipSpacingTableInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, tips_table);
    var cases: std.ArrayList(Fixture) = .empty;
    const cat: []const []const u8 = &.{"DRC-031"};
    for (try c.sweep(arena, depth, 18)) |g| if (g > 0) {
        try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "tip_spacing_table/side_to_side/{s}", .{try c.side(arena, g, 18)}), cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 100 + g, 0, 200 + g, 1000 } }), try found(arena, g, 18, 200 + g, 1000)));
    };
    for ([_]i64{ 20, 30 }) |w| for (try c.sweep(arena, depth, 25)) |g| if (g > 0) {
        try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "tip_spacing_table/tip_to_side/w{d}/{s}", .{ w, try c.side(arena, g, 25) }), cat, deck, try c.met1(arena, &.{ .{ 0, 0, w, 1000 }, .{ -500, 1000 + g, 500, 1100 + g } }), try found(arena, g, 25, w, 2000 + g)));
    };
    const rules = [_]struct { []const u8, i64, i64, i64 }{ .{ "s3", 30, 30, 27 }, .{ "s4", 20, 20, 31 }, .{ "s5", 30, 20, 31 } };
    for (rules) |ru| {
        const rule, const wa, const wb, const need = ru;
        for (try c.sweep(arena, depth, need)) |g| if (g > 0) {
            try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "tip_spacing_table/tip_to_tip/{s}/{s}", .{ rule, try c.side(arena, g, need) }), cat, deck, try tips(arena, wa, wb, g), try found(arena, g, need, @min(wa, wb), 2000 + g)));
        };
    }
    for (try c.sweep(arena, depth, 24)) |w| if (w > 0) {
        try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "tip_spacing_table/class_24/{s}", .{try c.side(arena, w, 24)}), cat, deck, try tips(arena, w, w, 28), try found(arena, 28, classNeed(w), w, 2028)));
    };
    for (try c.sweep(arena, depth, 37)) |w| {
        try cases.append(arena, try tableCase(arena, try std.fmt.allocPrint(arena, "tip_spacing_table/class_37/{s}", .{try c.side(arena, w, 37)}), cat, deck, try tips(arena, w, w, 20), try found(arena, 20, classNeed(w), w, 2020)));
    }
    try cases.append(arena, try tableCase(arena, "tip_spacing_table/diagonal", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 30, 1000 }, .{ 40, 1010, 70, 2000 } }), &.{}));
    try cases.append(arena, try tableCase(arena, "tip_spacing_table/notch_in_one_figure", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 20, 500 }, .{ 30, 0, 50, 500 }, .{ 0, -20, 50, 0 } }), &.{}));
    try cases.append(arena, try tableCase(arena, "tip_spacing_table/tip_drawn_as_strips", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 15, 1000 }, .{ 15, 0, 30, 1000 }, .{ 0, 1028, 30, 2028 } }), &.{}));
    try cases.append(arena, try tableCase(arena, "tip_spacing_table/three_bars", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 110, 0, 210, 1000 }, .{ 220, 0, 320, 1000 } }), &.{
        Finding.length(10).pinned(105, 500),
        Finding.length(10).pinned(215, 500),
    }));
    // A bar's 1000-long side x = 100 faces a figure stepped 15 away below
    // y = 400 and 10 away above it: both 400 and 600 long, 18 apart needed;
    // the nearer step is the finding, over y = 400..1000.
    try cases.append(arena, try tableCase(arena, "tip_spacing_table/nearest_of_two_steps", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 115, 0, 215, 400 }, .{ 110, 400, 210, 1000 } }), &.{Finding.length(10).pinned(105, 700)}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "tip_spacing_table", &.{"DRC-031"}, tips_table, &.{"t"}));
}

test "every spacing table fixture holds" {
    // Oracle: each fixture's expected answer, derived from the table kinds'
    // definitions (the doc comments above; LEF/DEF 5.8's two-width example
    // and the ASAP7 M1 tip table): each limit swept one grid step either
    // side, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
