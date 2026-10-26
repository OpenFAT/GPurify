//! The one-layer spacing kinds through deck text: end of line (plain, LEF
//! `ENDOFLINE ... WITHIN`, keep-out), run length, corners, wide and
//! attached-wide spacing, net spacing, the spacing tables, forbidden
//! spacing, span length and exact pitch. Each case's oracle is restated on
//! its test. Ported from crates/check/tests/drc/spacing_deck.rs.

const std = @import("std");
const testing = std.testing;
const common = @import("common.zig");
const F = common.Finding;
const Layout = common.Layout;
const gpa = common.gpa;
const met1 = common.met1;
const steps = common.steps;
const opt = common.opt;
const everywhere = common.everywhere;

/// A 1000 wide line ending at y = 0.
const line = [4]i64{ 0, -5000, 1000, 0 };

/// The ASAP7 M1 tip table (DRM r1p7, Table 3.12.1).
const tips_table =
    \\rule t tip_space_table(met1;
    \\    length: [0nm, 24nm, 37nm],
    \\    space: [[31nm, 31nm, 25nm],
    \\            [31nm, 27nm, 25nm],
    \\            [25nm, 25nm, 18nm]])
;

/// 180 everywhere, 220 for a pair whose wider shape is wider than 300
/// running alongside for more than 1000.
const table_rule =
    \\rule t space_table(met1;
    \\    prl:   [0nm, 1000nm],
    \\    width: [0nm, 300nm],
    \\    space: [[180nm, 180nm],
    \\            [180nm, 220nm]])
;

/// LEF/DEF 5.8's two-width table in nm.
const two_widths =
    \\rule t two_width_table(met1;
    \\    width: [0nm, 250nm, 1500nm, 3000nm],
    \\    prl:   [none, 0nm, 1500nm, 3000nm],
    \\    space: [[150nm, 200nm, 500nm, 1000nm],
    \\            [200nm, 250nm, 500nm, 1000nm],
    \\            [500nm, 500nm, 600nm, 1000nm],
    \\            [1000nm, 1000nm, 1000nm, 1200nm]])
;

// ---- private ----

fn deck(arena: std.mem.Allocator, rules: []const u8) ![]const u8 {
    return common.oneLayerDeck(arena, rules);
}

fn poly(layer: []const u8, points: []const [2]i64) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    try l.polygon(layer, points);
    return l;
}

/// `l` with `boxes` added on `layer`.
fn with(l: Layout, layer: []const u8, boxes: []const [4]i64) !Layout {
    var out = l;
    try out.rects(layer, boxes);
    return out;
}

fn withPoly(l: Layout, layer: []const u8, points: []const [2]i64) !Layout {
    var out = l;
    try out.polygon(layer, points);
    return out;
}

fn ringed(layer: []const u8, outer: [4]i64, hole: [4]i64) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    try common.ring(&l, layer, outer, hole);
    return l;
}

/// LEF/DEF 5.8 Example 1-18 in nm, `SPACING 1.2 ENDOFLINE 1.3 WITHIN 0.6`.
fn lefEol(arena: std.mem.Allocator, parallel: []const u8, end_to_end: []const u8) ![]const u8 {
    return deck(arena, try std.fmt.allocPrint(arena, "rule e eol_space(met1; eol_width: 1300nm, within: 600nm, parallel: {s}, end_to_end: {s}) >= 1200nm", .{ parallel, end_to_end }));
}

/// Two 1000 squares `d` apart on both axes, and what a Euclidean minimum of
/// 101 finds: the floored gap, midway between the corners.
fn diagonalPair(d: i64) !Layout {
    return met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1000 + d, 1000 + d, 2000 + d, 2000 + d } });
}

fn diagonalFound(d: i64) common.Opt {
    const gap2 = 2 * d * d;
    return opt(gap2 < 101 * 101, F.length(common.floorSqrt(gap2)).atHalf(2000 + d, 2000 + d));
}

fn netDeck(arena: std.mem.Allocator, rules: []const u8) ![]const u8 {
    return common.newDeck(arena, &.{ "met1", "via1", "met2" }, try std.fmt.allocPrint(arena, "connect conductors [met1, met2]\nconnect touch_within_layer\nconnect via via1 [met1, met2]\n{s}", .{rules}));
}

fn diamond(x: i64, y: i64, r: i64) [4][2]i64 {
    return .{ .{ x, y - r }, .{ x + r, y }, .{ x, y + r }, .{ x - r, y } };
}

fn held(gap2: i64) common.Opt {
    return opt(gap2 < 301 * 301, F.length(common.floorSqrt(gap2)));
}

fn hv() !Layout {
    return with(try common.layoutOf("nwell", &.{.{ 0, 0, 3000, 3000 }}), "hvi", &.{.{ -500, -500, 3500, 3500 }});
}

fn tablePair(d: []const u8, name: []const u8, wa: i64, g: i64, r: i64) !void {
    const need: i64 = if (wa > 300) (if (r > 1000) 220 else 180) else 180;
    try everywhere(name, d, try met1(&.{ .{ 0, 0, wa, 2000 }, .{ wa + g, 2000 - r, wa + g + 100, 4000 - r } }), "t", opt(g < need, F.length(g).atHalf(2 * wa + g, 4000 - r)));
}

fn tips(wa: i64, wb: i64, g: i64) !Layout {
    return met1(&.{ .{ 0, 0, wa, 1000 }, .{ 0, 1000 + g, wb, 2000 + g } });
}

fn classNeed(w: i64) i64 {
    return if (w < 24) 31 else if (w < 37) 27 else 18;
}

test "eol space holds each line end keep out" {
    // Oracle: gaps and widths by construction: tip to tip and tip to side,
    // the gap swept; the line width swept around 200 at a gap of 50 (a 200
    // wide end is no end of line); lines side by side; a wide shape just
    // beside the keep-out; a line end facing its own figure; a 300 wide end
    // drawn as three strips; a shared edge under a bar; a hole's slot whose
    // end keeps out into the hole, 90 from an island (at (500, 1005)); the
    // slot's end that would reach through the band if pushed the wrong way.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule eol eol_space(met1; eol_width: 200nm) >= 101nm");
    for (steps(101)) |g| {
        const found = opt(g < 101, F.length(g).atHalf(100, 4000 + g));
        try everywhere("tip_to_tip", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 0, 2000 + g, 100, 4000 + g } }), "eol", found);
        try everywhere("tip_to_side", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ -1000, 2000 + g, 1100, 2200 + g } }), "eol", found);
    }
    for (steps(200)) |w| {
        try everywhere("line_width", d, try met1(&.{ .{ 0, 0, w, 2000 }, .{ 0, 2050, w, 4050 } }), "eol", opt(w < 200, F.length(50).atHalf(w, 4050)));
    }
    const none: []const F = &.{};
    try everywhere("side_by_side", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 150, 0, 250, 2000 } }), "eol", none);
    try everywhere("beside_the_keep_out", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 110, 2050, 2000, 4000 } }), "eol", none);
    try everywhere("facing_its_own_figure", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 0, -500, 1000, 0 }, .{ 900, -500, 1000, 1550 }, .{ 0, 1050, 1000, 1550 } }), "eol", none);
    try everywhere("wide_end_drawn_as_strips", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 100, 0, 200, 2000 }, .{ 200, 0, 300, 2000 }, .{ 0, 2050, 300, 4050 } }), "eol", none);
    try everywhere("shared_edge_is_no_end", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ -500, 1000, 600, 1050 }, .{ -200, 1080, 300, 1500 } }), "eol", none);
    try everywhere("hole_end_of_line", d, try met1(&.{
        .{ -500, -500, 1500, 0 }, .{ -500, 0, 0, 1600 },      .{ 1000, 0, 1500, 1600 },
        .{ 0, 1000, 450, 1600 },  .{ 550, 1000, 1000, 1600 }, .{ 450, 1050, 550, 1600 },
        .{ 100, 100, 900, 960 },
    }), "eol", &[_]F{F.length(90).atHalf(450 + 550, 1050 + 960)});
    try everywhere("hole_end_keeps_out_of_the_band", d, try with(try ringed("met1", .{ 0, 0, 200, 1000 }, .{ 50, 50, 150, 950 }), "met1", &.{.{ -500, 1030, 700, 1500 }}), "eol", none);
}

test "eol within space reads lef endofline" {
    // Oracle: LEF Figures 1-23 and 1-24, every distance drawn: a bar's depth
    // swept around 1200; a square 300 above, its side swept around 600 past
    // the end; an edge with a concave corner (no end); an end facing its own
    // figure. With PARALLELEDGE 1.1 WITHIN 0.5 a bar 1000 above fails only
    // with a neighbour beside the line (its distance swept around 1100, its
    // top around 500 behind the end); none, clean. TWOEDGES needs both
    // sides. With end_to_end 1400nm two facing ends need 1400, an end
    // facing a side 1200.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const plain = try lefEol(al, "none", "none");
    const parallel = try lefEol(al, "(space: 1100nm, within: 500nm, two_edges: false)", "none");
    const two_edges = try lefEol(al, "(space: 1100nm, within: 500nm, two_edges: true)", "none");
    const ends = try lefEol(al, "none", "1400nm");
    const bar_above = [4]i64{ -3000, 1000, 4000, 2000 };
    const at_1000 = [_]F{F.length(1000).atHalf(1000, 1000)};
    const none: []const F = &.{};
    for (steps(1200)) |g| try everywhere("depth", plain, try met1(&.{ line, .{ -2000, g, 3000, g + 1000 } }), "e", opt(g < 1200, F.length(g).atHalf(1000, g)));
    for (steps(600)) |dd| try everywhere("within", plain, try met1(&.{ line, .{ 1000 + dd, 300, 3000 + dd, 2300 } }), "e", opt(dd < 600, F.length(300).atHalf(2600 + dd, 300)));
    try everywhere("concave_corner_is_no_end", plain, try met1(&.{ .{ -3000, -5000, 4000, -1000 }, .{ 0, -1000, 1000, 0 }, .{ -3000, -900, -500, 3000 } }), "e", none);
    try everywhere("facing_its_own_figure", plain, try met1(&.{ line, .{ 0, -6000, 3000, -5000 }, .{ 2000, -6000, 3000, 1000 }, .{ -2000, 1000, 3000, 2000 } }), "e", none);
    for (steps(1100)) |p| try everywhere("parallel_space", parallel, try met1(&.{ line, bar_above, .{ -p - 2000, -5000, -p, 0 } }), "e", opt(p < 1100, at_1000[0]));
    for (steps(-500)) |t| try everywhere("parallel_within", parallel, try met1(&.{ line, bar_above, .{ -2500, -5000, -500, t } }), "e", opt(t > -500, at_1000[0]));
    try everywhere("no_parallel_edge", parallel, try met1(&.{ line, bar_above }), "e", none);
    try everywhere("two_edges/one_side", two_edges, try met1(&.{ line, bar_above, .{ -2500, -5000, -500, 0 } }), "e", none);
    try everywhere("two_edges/both_sides", two_edges, try met1(&.{ line, bar_above, .{ -2500, -5000, -500, 0 }, .{ 1500, -5000, 3500, 0 } }), "e", &at_1000);
    for (steps(1400)) |g| try everywhere("end_to_end", ends, try met1(&.{ line, .{ 0, g, 1000, g + 5000 } }), "e", opt(g < 1400, F.length(g).atHalf(1000, g)));
    try everywhere("end_to_side_keeps_the_limit", ends, try met1(&.{ line, .{ -2000, 1300, 3000, 2300 } }), "e", none);
}

test "eol keep out measures the intruding area" {
    // Oracle: areas by hand: the box's far side swept with a bar's bottom
    // around y = 1000 (1600 x (1000 - g)), its side with a block's left
    // around x = 1300 ((300 - d) x 500), its back with a block beside the
    // line whose top is swept around y = -200 (200 x (b + 200)); two figures
    // inside (350000 and 420000); a bar drawn as two rectangles (one figure,
    // 800000); the line's own figure turning back into the box.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule k eol_keep_out(met1; eol_width: 1300nm, backward: 200nm, side: 300nm, forward: 1000nm)");
    for (steps(1000)) |g| try everywhere("forward", d, try met1(&.{ line, .{ -2000, g, 3000, g + 500 } }), "k", opt(g < 1000, F.area(1600 * (1000 - g)).atHalf(1000, g + 1000)));
    for (steps(300)) |dd| try everywhere("side", d, try met1(&.{ line, .{ 1000 + dd, 500, 3000 + dd, 2500 } }), "k", opt(dd < 300, F.area((300 - dd) * 500).atHalf(2300 + dd, 1500)));
    for (steps(-200)) |b| try everywhere("backward", d, try met1(&.{ line, .{ 1100, b - 2000, 3100, b } }), "k", opt(b > -200, F.area(200 * (b + 200)).atHalf(2400, b - 200)));
    try everywhere("two_figures", d, try met1(&.{ line, .{ -2000, 300, 200, 1800 }, .{ 700, 300, 2500, 1800 } }), "k", &[_]F{ F.area(350_000).atHalf(-100, 1300), F.area(420_000).atHalf(2000, 1300) });
    try everywhere("one_figure_drawn_twice", d, try met1(&.{ line, .{ -2000, 500, 500, 1500 }, .{ 500, 500, 3000, 1500 } }), "k", &[_]F{F.area(800_000).atHalf(1000, 1500)});
    try everywhere("own_figure_in_the_box", d, try met1(&.{ line, .{ 0, -6000, 3000, -5000 }, .{ 2000, -6000, 3000, 1100 }, .{ -500, 600, 3000, 1100 } }), "k", &[_]F{});
}

test "prl space holds pairs that run far enough" {
    // Oracle: runs and gaps by construction: the run swept around 500 at a
    // gap of 100; the gap swept at a long run; an L whose box would
    // overstate the run (its facing edges run 100: clean); a diagonal pair;
    // touching shapes; a wire of four 500 segments beside another, held
    // under a 600 threshold by its whole 2000 run, one finding per segment.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try deck(al, "rule prl prl_space(met1; prl: 500nm) >= 101nm");
    for (steps(500)) |r| try everywhere("run", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 200, 2000 - r, 300, 4000 - r } }), "prl", opt(r >= 500, F.length(100).atHalf(300, 4000 - r)));
    for (steps(101)) |g| try everywhere("gap", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 100 + g, 0, 200 + g, 2000 } }), "prl", opt(g < 101, F.length(g).atHalf(200 + g, 2000)));
    const none: []const F = &.{};
    try everywhere("l_box_overstates_run", d, try with(try poly("met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 100 }, .{ 100, 100 }, .{ 100, 2000 }, .{ 0, 2000 } }), "met1", &.{.{ 200, 1900, 1500, 2000 }}), "prl", none);
    try everywhere("diagonal", d, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 } }), "prl", none);
    try everywhere("touching", d, try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 100, 0, 200, 2000 } }), "prl", none);
    try everywhere("segmented_run", try deck(al, "rule prl prl_space(met1; prl: 600nm) >= 101nm"), try met1(&.{ .{ 0, 0, 100, 2000 }, .{ 200, 0, 300, 500 }, .{ 200, 500, 300, 1000 }, .{ 200, 1000, 300, 1500 }, .{ 200, 1500, 300, 2000 } }), "prl", &[_]F{
        F.length(100).atPoint(150, 250), F.length(100).atPoint(150, 750), F.length(100).atPoint(150, 1250), F.length(100).atPoint(150, 1750),
    });
}

test "corner space measures facing convex corners" {
    // Oracle: the diagonal swept over 70, 71, 72 (98.99, 100.4, 101.8); a
    // pair 50 apart on x and 1 on y (50.01, reported 50); no gap on one
    // axis; side by side; corner to corner but one figure; an L whose arm's
    // corner (1000, 100) faces a square's (1050, 150): √5000, 70; a hook
    // whose inner corner (1060, 1060) faces the square's (1000, 1000):
    // √7200, 84; a square's corner a bar on top turns into an edge.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule cc corner_space(met1) >= 101nm");
    for ([_]i64{ 70, 71, 72 }) |dd| try everywhere("diagonal", d, try diagonalPair(dd), "cc", diagonalFound(dd));
    const none: []const F = &.{};
    try everywhere("skew", d, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1001, 2050, 2001 } }), "cc", &[_]F{F.length(50)});
    try everywhere("no_gap_on_one_axis", d, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1000, 2050, 2000 } }), "cc", none);
    try everywhere("side_by_side", d, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 0, 2050, 1000 } }), "cc", none);
    try everywhere("one_figure", d, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 }, .{ -500, 0, 0, 3500 }, .{ -500, 3000, 2050, 3500 }, .{ 1050, 2050, 2050, 3000 } }), "cc", none);
    try everywhere("l_corner_inside_its_box", d, try with(try poly("met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 100, 100 }, .{ 100, 1000 }, .{ 0, 1000 } }), "met1", &.{.{ 1050, 150, 1150, 250 }}), "cc", &[_]F{F.length(70).atHalf(1000 + 1050, 100 + 150)});
    try everywhere("corner_beside_an_edge_gap", d, try withPoly(try met1(&.{.{ 0, 0, 1000, 1000 }}), "met1", &.{ .{ 1050, -500 }, .{ 1600, -500 }, .{ 1600, 1500 }, .{ 1060, 1500 }, .{ 1060, 1060 }, .{ 1500, 1060 }, .{ 1500, 500 }, .{ 1050, 500 } }), "cc", &[_]F{F.length(84).atHalf(1000 + 1060, 1000 + 1060)});
    try everywhere("row_corner_inside_a_figure_edge", d, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 0, 1000, 1000, 1010 }, .{ 1050, 1005, 2050, 2005 } }), "cc", none);
}

test "convex corner space reads the larger axis gap" {
    // Oracle: diagonal pairs d apart on both axes: the larger gap is d, the
    // Euclidean one d√2. A pair 50 apart on y with the x gap swept around
    // 101: the larger gap is the x gap; Euclidean, 111.8 at 100, clean.
    // Side by side; one figure. With except_eol 200nm a 100 wide line end's
    // corners are exempt on either shape, two wide squares' are not.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const square = try deck(al, "rule c corner_space(met1; corner_to_corner: false, except_eol: none) >= 101nm");
    const euclid = try deck(al, "rule c corner_space(met1; corner_to_corner: true, except_eol: none) >= 101nm");
    const eol = try deck(al, "rule c corner_space(met1; corner_to_corner: false, except_eol: 200nm) >= 101nm");
    for ([_]i64{ 70, 71, 72, 100, 101 }) |dd| {
        try everywhere("diagonal/square", square, try diagonalPair(dd), "c", opt(dd < 101, F.length(dd).atHalf(2000 + dd, 2000 + dd)));
        try everywhere("diagonal/euclidean", euclid, try diagonalPair(dd), "c", diagonalFound(dd));
    }
    for (steps(101)) |dd| try everywhere("skewed", square, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1000 + dd, 1050, 2000 + dd, 2050 } }), "c", opt(dd < 101, F.length(dd).atHalf(2000 + dd, 2050)));
    const none: []const F = &.{};
    try everywhere("skewed_euclidean", euclid, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1100, 1050, 2100, 2050 } }), "c", none);
    try everywhere("side_by_side", square, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 0, 2050, 1000 } }), "c", none);
    try everywhere("one_figure", square, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1000, 1000, 2000, 2000 } }), "c", none);
    try everywhere("except_eol/line_end", eol, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 150, 1050, 1150, 2050 } }), "c", none);
    try everywhere("except_eol/other_line_end", eol, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 1150, 2050 } }), "c", none);
    try everywhere("except_eol/wide_corners", eol, try met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 } }), "c", &[_]F{F.length(50).atHalf(2050, 2050)});
    try everywhere("line_end_without_except", square, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 150, 1050, 1150, 2050 } }), "c", &[_]F{F.length(50).atHalf(250, 2050)});
}

test "wide space holds pairs beside a wide part" {
    // Oracle: widths and gaps by construction: the plate width swept around
    // 1000 beside a line 200 off; the gap swept at a wide plate; a thin tab
    // of a wide plate 200 from a line 500 from the plate (not held), as one
    // polygon and as touching rectangles; a 1200 x 1000 plate drawn as two
    // halves (two row pairs, both held, at (1300, 250) and (1300, 750)); two
    // thin lines; a thin line between the plate and another (only the near
    // pair); a staircase 100 from the plate over y = 1500..2000 (marked at
    // (2050, 1750)); a plate whose facing side the wide part's rectangles
    // cut in three (marked at the whole side's middle (1500, 2100)).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule wd wide_space(met1; width: 1000nm) >= 301nm");
    for (steps(1000)) |w| try everywhere("plate_width", d, try met1(&.{ .{ 0, 0, w, 3000 }, .{ w + 200, 0, w + 300, 3000 } }), "wd", opt(w >= 1000, F.length(200).atHalf(2 * w + 200, 3000)));
    for (steps(301)) |g| try everywhere("gap", d, try met1(&.{ .{ 0, 0, 2000, 3000 }, .{ 2000 + g, 0, 2100 + g, 3000 } }), "wd", opt(g < 301, F.length(g).atHalf(4000 + g, 3000)));
    const finger = [_][2]i64{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, 3000 }, .{ 900, 3000 }, .{ 900, 2000 }, .{ 0, 2000 } };
    const none: []const F = &.{};
    try everywhere("thin_tab_not_held", d, try with(try poly("met1", &finger), "met1", &.{.{ 1200, 2500, 1300, 3000 }}), "wd", none);
    try everywhere("thin_tab_touching_not_held", d, try met1(&.{ .{ 0, 0, 2000, 2000 }, .{ 900, 2000, 1000, 3000 }, .{ 1200, 2500, 1300, 3000 } }), "wd", none);
    try everywhere("wide_only_merged", d, try met1(&.{ .{ 0, 0, 1200, 500 }, .{ 0, 500, 1200, 1000 }, .{ 1400, 0, 1500, 1000 } }), "wd", &[_]F{ F.length(200).atPoint(1300, 250), F.length(200).atPoint(1300, 750) });
    try everywhere("two_thin_lines", d, try met1(&.{ .{ 0, 0, 100, 3000 }, .{ 300, 0, 400, 3000 } }), "wd", none);
    try everywhere("line_between", d, try met1(&.{ .{ 0, 0, 2000, 2000 }, .{ 2100, 0, 2200, 2000 }, .{ 2400, 0, 2500, 2000 } }), "wd", &[_]F{F.length(100).atPoint(2050, 1000)});
    try everywhere("staircase_beside_the_plate", d, try withPoly(try met1(&.{.{ 0, 0, 2000, 2000 }}), "met1", &.{ .{ 2100, 1500 }, .{ 2200, 1500 }, .{ 2200, -1000 }, .{ 2300, -1000 }, .{ 2300, 1600 }, .{ 2200, 1600 }, .{ 2200, 4000 }, .{ 2100, 4000 } }), "wd", &[_]F{F.length(100).atHalf(2000 + 2100, 1500 + 2000)});
    try everywhere("wide_side_cut_into_slabs", d, try with(try poly("met1", &.{ .{ 0, 0 }, .{ 500, 0 }, .{ 500, -1000 }, .{ 1500, -1000 }, .{ 1500, 0 }, .{ 3000, 0 }, .{ 3000, 2000 }, .{ 0, 2000 } }), "met1", &.{.{ 0, 2200, 3000, 2300 }}), "wd", &[_]F{F.length(200).atHalf(3000, 2000 + 2200)});
}

test "attached wide space holds what is attached to the wide part" {
    // Oracle: a 2000 plate with a 100 wide finger up its middle, and a line
    // 200 beside the finger starting `a` above the plate: the attached stub
    // reaches 300 up the finger, so the line is `min(a, √(200² + (a −
    // 300)²))` from the grown part and `a` from the plate, floored. A thin
    // line between the plate and another line holds only the near pair.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule wd wide_space(met1; width: 1000nm) >= 301nm\nrule aw wide_space(met1; width: 1000nm, attached: 300nm) >= 301nm");
    const finger = [_][2]i64{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, 3000 }, .{ 900, 3000 }, .{ 900, 2000 }, .{ 0, 2000 } };
    for ([_]i64{ 100, 250, 300, 400, 500, 600 }) |a| {
        const stub2 = if (a <= 300) 200 * 200 else 200 * 200 + (a - 300) * (a - 300);
        var l = try with(try poly("met1", &finger), "met1", &.{.{ 1200, 2000 + a, 1300, 3000 }});
        defer l.deinit();
        const wd = held(a * a);
        const aw = held(@min(stub2, a * a));
        try common.checkEverywhere("finger", d, &l, &.{ .{ .id = "wd", .findings = common.slice(&wd) }, .{ .id = "aw", .findings = common.slice(&aw) } });
    }
    var l = try met1(&.{ .{ 0, 0, 2000, 2000 }, .{ 2100, 0, 2200, 2000 }, .{ 2400, 0, 2500, 2000 } });
    defer l.deinit();
    const near = [_]F{F.length(100).atPoint(2050, 1000)};
    try common.checkEverywhere("line_between", d, &l, &.{ .{ .id = "wd", .findings = &near }, .{ .id = "aw", .findings = &near } });
}

test "net space tells one net from two" {
    // Oracle: nets by construction: two bars g apart strapped through vias
    // and met2 (one net: only the same-net rule holds them) or not (two
    // nets); touching bars (one figure, no pair); an empty met1.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try netDeck(arena.allocator(), "rule sn space(met1; nets: same) >= 301nm\nrule dn space(met1; nets: different) >= 301nm\n");
    const none: []const F = &.{};
    for (steps(301)) |g| {
        const near = opt(g < 301, F.length(g).atHalf(1000 + g, 2000));
        var bars = try met1(&.{ .{ 0, 0, 500, 2000 }, .{ 500 + g, 0, 1000 + g, 2000 } });
        defer bars.deinit();
        var strapped = try met1(&.{ .{ 0, 0, 500, 2000 }, .{ 500 + g, 0, 1000 + g, 2000 } });
        defer strapped.deinit();
        try strapped.rects("via1", &.{ .{ 200, 200, 300, 300 }, .{ 700 + g, 200, 800 + g, 300 } });
        try strapped.rect("met2", 100, 100, 900 + g, 400);
        try common.checkEverywhere("strapped", d, &strapped, &.{ .{ .id = "sn", .findings = common.slice(&near) }, .{ .id = "dn", .findings = none } });
        try common.checkEverywhere("apart", d, &bars, &.{ .{ .id = "sn", .findings = none }, .{ .id = "dn", .findings = common.slice(&near) } });
    }
    var touching = try met1(&.{ .{ 0, 0, 500, 2000 }, .{ 500, 0, 1000, 2000 } });
    defer touching.deinit();
    try common.checkEverywhere("touching", d, &touching, &.{ .{ .id = "sn", .findings = none }, .{ .id = "dn", .findings = none } });
    var vacuous = try common.layoutOf("met2", &.{.{ 0, 0, 1000, 1000 }});
    defer vacuous.deinit();
    try common.checkEverywhere("vacuous", d, &vacuous, &.{ .{ .id = "sn", .findings = none }, .{ .id = "dn", .findings = none } });
}

test "net space across two layers reads their nets" {
    // Oracle: nets and gaps by construction: the met2 bar g = 300, 301, 302
    // right of the met1 bar (two nets: g at the gap's midpoint below 301);
    // the same bars strapped by a met2 bar and a via onto met1 (one net:
    // nothing); a met2 bar drawn across the met1 bar (overlap: 0).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try netDeck(arena.allocator(), "rule dn2 space(met1, met2; nets: different) >= 301nm\n");
    for (steps(301)) |g| {
        try everywhere("apart", d, try with(try met1(&.{.{ 0, 0, 500, 2000 }}), "met2", &.{.{ 500 + g, 0, 1000 + g, 2000 }}), "dn2", opt(g < 301, F.length(g).atHalf(1000 + g, 2000)));
        var joined = try with(try met1(&.{ .{ 0, 0, 500, 2000 }, .{ 0, 2000, 500, 2500 } }), "met2", &.{ .{ 500 + g, 0, 1000 + g, 2000 }, .{ 0, 2000, 1000 + g, 2500 } });
        try joined.rect("via1", 200, 2200, 300, 2300);
        try everywhere("one_net", d, joined, "dn2", &[_]F{});
    }
    try everywhere("crossing", d, try with(try met1(&.{.{ 0, 0, 500, 2000 }}), "met2", &.{.{ -500, 900, 1000, 1100 }}), "dn2", &[_]F{F.length(0)});
}

test "net space on a derived layer takes its sources nets" {
    // Oracle: nets by construction (sky130 hvnwell.8, 2 um between HV
    // n-well and any n-well on different nets): an HV well and a plain well
    // 1999, 2000, 2001 apart (one finding of 1999); the two joined by an
    // n-well bridge (one net: nothing); the HV well against its own n-well
    // (nothing). `nwell or hvi` with the hvi shape bridging two wells is
    // one shape over two nets: refused.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{ "nwell", "hvi" }, "connect conductors [nwell]\nconnect touch_within_layer\nlayer hv_nwell = nwell.interacting(hvi)\nrule hvnwell.8 space(hv_nwell, nwell; nets: different) >= 2um\n");
    for (steps(2000)) |g| try everywhere("apart", d, try with(try hv(), "nwell", &.{.{ 3000 + g, 0, 6000 + g, 3000 }}), "hvnwell.8", common.below(g, 2000));
    try everywhere("bridged", d, try with(try hv(), "nwell", &.{ .{ 4000, 0, 7000, 3000 }, .{ 3000, 1000, 4000, 2000 } }), "hvnwell.8", &[_]F{});
    try everywhere("alone", d, try hv(), "hvnwell.8", &[_]F{});
    const either = try common.newDeck(al, &.{ "nwell", "hvi" }, "connect conductors [nwell]\nconnect touch_within_layer\nlayer either = nwell or hvi\nrule e space(either, nwell; nets: different) >= 2um\n");
    var l = try with(try common.layoutOf("nwell", &.{ .{ 0, 0, 1000, 1000 }, .{ 2000, 0, 3000, 1000 } }), "hvi", &.{.{ 500, 400, 2500, 600 }});
    defer l.deinit();
    var r = try common.run(either, &l);
    defer r.deinit();
    try testing.expectEqual(@import("check").report.Outcome.refused, r.row("e").outcome);
}

test "space table picks the cell of width and run" {
    // Oracle: a wa-wide line beside a 100 wide one, g apart with a run r:
    // the width swept around 300 (exactly 300 is the first row), the run
    // around 1000 (exactly 1000 the first column), the gap around 220 and,
    // for two thin lines, around 180. A thin tab of a wide plate is held to
    // the first row; a ring's own hole is no pair; touching lines are one
    // figure; an L whose box would overstate the run keeps the first
    // column; a bar beside a stub keeps column 0 within the cell; a wire of
    // four segments takes the column of its whole run.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try deck(al, table_rule);
    for (steps(300)) |wa| try tablePair(d, "width", wa, 200, 2000);
    for (steps(1000)) |r| try tablePair(d, "run", 400, 200, r);
    for (steps(220)) |g| try tablePair(d, "gap_wide", 400, g, 2000);
    for (steps(180)) |g| try tablePair(d, "gap_thin", 100, g, 2000);
    const none: []const F = &.{};
    try everywhere("thin_tab_first_row", d, try with(try poly("met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, 4000 }, .{ 900, 4000 }, .{ 900, 2000 }, .{ 0, 2000 } }), "met1", &.{.{ 1200, 2500, 1300, 4000 }}), "t", none);
    try everywhere("own_hole", d, try ringed("met1", .{ 0, 0, 2000, 2000 }, .{ 100, 100, 1900, 1900 }), "t", none);
    try everywhere("touching", d, try met1(&.{ .{ 0, 0, 400, 2000 }, .{ 400, 0, 500, 2000 } }), "t", none);
    try everywhere("l_box_overstates_run", d, try withPoly(try met1(&.{.{ 0, 0, 400, 2000 }}), "met1", &.{ .{ 1500, 0 }, .{ 1600, 0 }, .{ 1600, 2000 }, .{ 600, 2000 }, .{ 600, 1900 }, .{ 1500, 1900 } }), "t", none);
    const cell = try deck(al,
        \\rule t space_table(met1;
        \\    prl:   [0nm, 1000nm],
        \\    width: [0nm, 300nm],
        \\    space: [[180nm, 200nm],
        \\            [180nm, 260nm]])
    );
    try everywhere("run_within_the_cell", cell, try met1(&.{ .{ 0, 0, 100, 3000 }, .{ 330, 0, 430, 3000 }, .{ 290, 1000, 330, 1050 } }), "t", none);
    try everywhere("segmented_run", d, try met1(&.{ .{ 0, 0, 400, 2000 }, .{ 600, 0, 700, 500 }, .{ 600, 500, 700, 1000 }, .{ 600, 1000, 700, 1500 }, .{ 600, 1500, 700, 2000 } }), "t", &[_]F{
        F.length(200).atPoint(500, 250), F.length(200).atPoint(500, 750), F.length(200).atPoint(500, 1250), F.length(200).atPoint(500, 1750),
    });
}

test "two width table reads each shapes width and run" {
    // Oracle: LEF's own worked example, each gap swept around its space:
    // widths 250 and 250 with no run, 150; 250 and 260 with no run, 150; 250
    // and 260 with a run of 100, 200; 260 and 260 with a run of 100, 250.
    // The 1500 run swept between two 1600 wide plates 550 apart (600 only
    // past it). A 260 wide line 220 from the thin tab of a 2 um plate is
    // clean. A ring's own hole and touching shapes are no pair.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), two_widths);
    const cases = [_][5]i64{ .{ 0, 250, 250, 0, 150 }, .{ 1, 250, 260, 0, 150 }, .{ 2, 250, 260, 100, 200 }, .{ 3, 260, 260, 100, 250 } };
    for (cases) |cs| {
        const wa = cs[1];
        const wb = cs[2];
        const r = cs[3];
        const need = cs[4];
        for (steps(need)) |g| try everywhere("two_widths", d, try met1(&.{ .{ 0, 0, wa, 2000 }, .{ wa + g, 2000 - r, wa + g + wb, 4000 - r } }), "t", opt(g < need, F.length(g).atHalf(2 * wa + g, 4000 - r)));
    }
    for (steps(1500)) |r| try everywhere("run_1500", d, try met1(&.{ .{ 0, 0, 1600, 3000 }, .{ 2150, 3000 - r, 3750, 6000 - r } }), "t", opt(r > 1500, F.length(550).atHalf(3750, 6000 - r)));
    const none: []const F = &.{};
    try everywhere("thin_tab_is_thin", d, try met1(&.{ .{ 0, 0, 2000, 2000 }, .{ 900, 2000, 1000, 3000 }, .{ 1220, 2500, 1480, 4000 } }), "t", none);
    try everywhere("own_hole", d, try ringed("met1", .{ 0, 0, 2000, 2000 }, .{ 100, 100, 1900, 1900 }), "t", none);
    try everywhere("touching", d, try met1(&.{ .{ 0, 0, 400, 2000 }, .{ 400, 0, 500, 2000 } }), "t", none);
}

test "tip space table classes whole edges by length" {
    // Oracle: each ASAP7 rule's gap swept around its value (side to side
    // 18, tip to side 25 from a 20 and a 30 wide line, tip to tip 27, 31,
    // 31); each class boundary swept at a gap between its two cells (tips
    // 23, 24, 25 wide 28 apart; 36, 37, 38 wide 20 apart). Clean: a diagonal
    // pair, a notch inside one figure, a 30 wide tip drawn as two strips 28
    // from another. Three bars: two findings; a figure 15 and 10 away along
    // two steps: one finding, at the nearer.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), tips_table);
    for (steps(18)) |g| try everywhere("side_to_side", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 100 + g, 0, 200 + g, 1000 } }), "t", opt(g < 18, F.length(g).atHalf(200 + g, 1000)));
    for ([_]i64{ 20, 30 }) |w| for (steps(25)) |g| {
        try everywhere("tip_to_side", d, try met1(&.{ .{ 0, 0, w, 1000 }, .{ -500, 1000 + g, 500, 1100 + g } }), "t", opt(g < 25, F.length(g).atHalf(w, 2000 + g)));
    };
    for ([_][3]i64{ .{ 30, 30, 27 }, .{ 20, 20, 31 }, .{ 30, 20, 31 } }) |cs| for (steps(cs[2])) |g| {
        try everywhere("tip_to_tip", d, try tips(cs[0], cs[1], g), "t", opt(g < cs[2], F.length(g).atHalf(@min(cs[0], cs[1]), 2000 + g)));
    };
    for (steps(24)) |w| try everywhere("class_24", d, try tips(w, w, 28), "t", opt(28 < classNeed(w), F.length(28).atHalf(w, 2028)));
    for (steps(37)) |w| try everywhere("class_37", d, try tips(w, w, 20), "t", opt(20 < classNeed(w), F.length(20).atHalf(w, 2020)));
    const none: []const F = &.{};
    try everywhere("diagonal", d, try met1(&.{ .{ 0, 0, 30, 1000 }, .{ 40, 1010, 70, 2000 } }), "t", none);
    try everywhere("notch_in_one_figure", d, try met1(&.{ .{ 0, 0, 20, 500 }, .{ 30, 0, 50, 500 }, .{ 0, -20, 50, 0 } }), "t", none);
    try everywhere("tip_drawn_as_strips", d, try met1(&.{ .{ 0, 0, 15, 1000 }, .{ 15, 0, 30, 1000 }, .{ 0, 1028, 30, 2028 } }), "t", none);
    try everywhere("three_bars", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 110, 0, 210, 1000 }, .{ 220, 0, 320, 1000 } }), "t", &[_]F{ F.length(10).atPoint(105, 500), F.length(10).atPoint(215, 500) });
    try everywhere("nearest_of_two_steps", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 115, 0, 215, 400 }, .{ 110, 400, 210, 1000 } }), "t", &[_]F{F.length(10).atPoint(105, 700)});
}

test "forbidden space flags gaps inside the range" {
    // Oracle: the gap swept around both ends of the range (99 and 151
    // legal), the run swept around 200 at a gap of 120 (200 is not more than
    // 200). Clean: a diagonal pair, a U whose arms are 120 apart (one
    // figure). Three bars 120 apart: two findings. A figure 90 away along
    // one step and 130 along another: the 90 is below the range, the finding
    // is the 130.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule f forbidden_space(met1; min: 100nm, max: 150nm, prl: 200nm)");
    for ([_]i64{ 100, 150 }) |limit| for (steps(limit)) |g| {
        try everywhere("gap", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 100 + g, 0, 200 + g, 1000 } }), "f", opt(g >= 100 and g <= 150, F.length(g).atHalf(200 + g, 1000)));
    };
    for (steps(200)) |r| try everywhere("run", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 220, 1000 - r, 320, 2000 - r } }), "f", opt(r > 200, F.length(120).atHalf(320, 2000 - r)));
    const none: []const F = &.{};
    try everywhere("diagonal", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 220, 1100, 320, 2000 } }), "f", none);
    try everywhere("one_figure", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 220, 0, 320, 1000 }, .{ 0, -100, 320, 0 } }), "f", none);
    try everywhere("three_bars", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 220, 0, 320, 1000 }, .{ 440, 0, 540, 1000 } }), "f", &[_]F{ F.length(120).atPoint(160, 500), F.length(120).atPoint(380, 500) });
    try everywhere("narrower_step_is_legal", d, try met1(&.{ .{ 0, 0, 100, 1000 }, .{ 190, 0, 290, 400 }, .{ 230, 400, 330, 1000 } }), "f", &[_]F{F.length(130).atPoint(165, 700)});
}

test "exact pitch wants centre lines exactly apart" {
    // Oracle: three fins and three gates, the pitch swept one step either
    // side: both pairs off the pitch, none at it. A missing fin is a pitch
    // of 54. Fins that do not overlap across are no neighbours. A bent shape
    // refuses. Placed under the symmetries that keep the axes.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const fins = try deck(al, "rule p pitch(met1, vertical) == 27nm");
    const gates = try deck(al, "rule p pitch(met1, horizontal) == 54nm");
    for (steps(27)) |p| {
        const found = [_]F{ F.length(p).atHalf(1000, p + 7), F.length(p).atHalf(1000, 3 * p + 7) };
        try common.axes("fins", fins, try met1(&.{ .{ 0, 0, 1000, 7 }, .{ 0, p, 1000, p + 7 }, .{ 0, 2 * p, 1000, 2 * p + 7 } }), "p", if (p == 27) &[_]F{} else &found);
    }
    for (steps(54)) |p| {
        const found = [_]F{ F.length(p).atHalf(p + 20, 1000), F.length(p).atHalf(3 * p + 20, 1000) };
        try common.axes("gates", gates, try met1(&.{ .{ 0, 0, 20, 1000 }, .{ p, 0, p + 20, 1000 }, .{ 2 * p, 0, 2 * p + 20, 1000 } }), "p", if (p == 54) &[_]F{} else &found);
    }
    try common.axes("missing_fin", fins, try met1(&.{ .{ 0, 0, 1000, 7 }, .{ 0, 27, 1000, 34 }, .{ 0, 81, 1000, 88 } }), "p", &[_]F{F.length(54).atHalf(1000, 115)});
    try common.axes("no_overlap_across", fins, try met1(&.{ .{ 0, 0, 1000, 7 }, .{ 2000, 30, 3000, 37 } }), "p", &[_]F{});
    var bent = try poly("met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 7 }, .{ 7, 7 }, .{ 7, 500 }, .{ 0, 500 } });
    defer bent.deinit();
    var r = try common.run(fins, &bent);
    defer r.deinit();
    try testing.expectEqual(@import("check").report.Outcome.refused, r.row("p").outcome);
}

test "span length reads each axis list" {
    // Oracle: LEF's own lists, each value and one step either side: a
    // vertical wire's width on x, a horizontal piece's height on y. A U with
    // a stepped arm: the left arm's 100 is one region, the base's 100 one
    // region across the step. A ring's band, four regions. A 200 long piece
    // drawn as two halves is one legal span. Under the axis symmetries.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule s span_length(met1; x: [60nm, 80nm, 120nm, 160nm, 200nm], y: [120nm, 160nm, 200nm])");
    for ([_]i64{ 60, 80, 120, 160, 200 }) |v| for (steps(v)) |w| {
        const legal = w == 60 or w == 80 or w == 120 or w == 160 or w >= 200;
        try common.axes("x", d, try met1(&.{.{ 0, 0, w, 1000 }}), "s", opt(!legal, F.length(w).atHalf(w, 1000)));
    };
    for ([_]i64{ 120, 160, 200 }) |v| for (steps(v)) |h| {
        const legal = h == 120 or h == 160 or h >= 200;
        try common.axes("y", d, try met1(&.{.{ 0, 0, 1000, h }}), "s", opt(!legal, F.length(h).atHalf(1000, h)));
    };
    try common.axes("stepped_u", d, try met1(&.{ .{ 0, 0, 1000, 100 }, .{ 0, 0, 100, 1000 }, .{ 900, 0, 1000, 500 }, .{ 850, 500, 1000, 1000 } }), "s", &[_]F{
        F.length(100).atHalf(100, 1100), F.length(100).atHalf(1900, 600), F.length(150).atHalf(1850, 1500), F.length(100).atHalf(1000, 100),
    });
    try common.axes("ring", d, try ringed("met1", .{ 0, 0, 1000, 1000 }, .{ 100, 100, 900, 900 }), "s", &[_]F{
        F.length(100).atHalf(100, 1000), F.length(100).atHalf(1900, 1000), F.length(100).atHalf(1000, 100), F.length(100).atHalf(1000, 1900),
    });
    try common.axes("drawn_in_halves", d, try met1(&.{ .{ 0, 0, 100, 120 }, .{ 100, 0, 200, 120 } }), "s", &[_]F{});
}

test "span length except skips short crosswise spans" {
    // Oracle: a 150 wide rectangle, its height swept around 200: its 150
    // horizontal span is held only above 200, its vertical span (199 to
    // 201, illegal on y) always. An L is held with no exception: its 150 x
    // 100 foot reports 150.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try deck(arena.allocator(), "rule s span_length(met1; x: [100nm, 300nm], y: [100nm, 300nm], x_except: 200nm, y_except: none)");
    for (steps(200)) |h| {
        const found = [_]F{ F.length(h).atHalf(150, h), F.length(150).atHalf(150, h) };
        try common.axes("rectangle", d, try met1(&.{.{ 0, 0, 150, h }}), "s", found[0..if (h > 200) 2 else 1]);
    }
    try common.axes("l_shape", d, try met1(&.{ .{ 0, 0, 150, 100 }, .{ 0, 100, 100, 1000 } }), "s", &[_]F{F.length(150).atPoint(75, 50)});
}

test "a 45 degree pair is marked at its nearest points" {
    // Oracle: points by construction: two diamonds of radius 10, tips (10,
    // 0) and (20, 0), 10 apart, marked at (15, 0); a diamond and a square
    // whose left side is at x = 20, marked at (15, 0); diamonds touching tip
    // to tip at (10, 0), 0 there; a radius-5 diamond inside a radius-30 one,
    // 0, at the boxes' common centre (0, 0).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "a", "b" }, "rule s space(a, b) >= 20nm\n");
    try everywhere("tip_to_tip", d, try withPoly(try poly("a", &diamond(0, 0, 10)), "b", &diamond(30, 0, 10)), "s", &[_]F{F.length(10).atPoint(15, 0)});
    try everywhere("tip_to_side", d, try with(try poly("a", &diamond(0, 0, 10)), "b", &.{.{ 20, -5, 30, 5 }}), "s", &[_]F{F.length(10).atPoint(15, 0)});
    try everywhere("touching", d, try withPoly(try poly("a", &diamond(0, 0, 10)), "b", &diamond(20, 0, 10)), "s", &[_]F{F.length(0).atPoint(10, 0)});
    try everywhere("nested", d, try withPoly(try poly("a", &diamond(0, 0, 30)), "b", &diamond(0, 0, 5)), "s", &[_]F{F.length(0).atPoint(0, 0)});
}
