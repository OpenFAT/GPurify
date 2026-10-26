//! Critical area, the redundant-via rate, DFM scoring and pattern matching,
//! as exhaustive fixtures. Ported from tests/exhaustive/drc_overlay.rs
//! (`mean_critical_area`, `critical_area`, `via_redundancy`, `dfm_score`,
//! `pattern_match`).
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
    try meanCriticalAreaInto(arena, out);
    try criticalAreaInto(arena, out);
    try viaRedundancyInto(arena, out);
    try dfmScoreInto(arena, out);
    try patternMatchInto(arena, out);
}

// ---- private ----

/// A finding measuring a fraction, unpinned.
fn fraction(r: f64) Finding {
    return .{ .measured = .ratio(r), .at = null };
}

/// `met1` lines 1000 x 100 at each `y`.
fn lines(arena: Allocator, ys: []const i64) !Layout {
    var l: Layout = .{};
    for (ys) |y| try l.rect(arena, "met1", 0, y, 1000, y + 100);
    return l;
}

/// The mean critical area over a deck-sampled defect-size distribution
/// (`mean_critical_area`, DRC-112): radii 50, 150, 250 nm weighted 1/2,
/// 1/4, 1/4, limits 144999, 145000, 145001 nm².
///
/// Oracle: the closed form per radius (two lines 1000 long, 200 apart:
/// `(1000 + 2r)(2r - 200)`, 0 below r = 100): 0, 130000 and 450000, so the
/// mean is 32500 + 112500 = 145000, found only against 144999, at the
/// centre of the largest radius's region, (500, 200). Lines 600 apart are
/// out of reach of every radius: nothing. Taking one radius's area, or
/// summing without the weights, breaks the limits.
fn meanCriticalAreaInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{"met1"}, "rule below critical_area(met1; radii: [50nm, 150nm, 250nm], weights: [0.5, 0.25, 0.25]) <= 144999nm2\n" ++
        "rule at critical_area(met1; radii: [50nm, 150nm, 250nm], weights: [0.5, 0.25, 0.25]) <= 145000nm2\n" ++
        "rule above critical_area(met1; radii: [50nm, 150nm, 250nm], weights: [0.5, 0.25, 0.25]) <= 145001nm2\n");
    const Case = struct { []const u8, i64, []const Finding };
    const cases_spec = [_]Case{
        .{ "two_lines", 200, &.{Finding.area(145_000).pinned(500, 200)} },
        .{ "out_of_reach", 600, &.{} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_spec) |s| {
        const layout = try lines(arena, &.{ 0, 100 + s[1] });
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "mean_critical_area/{s}", .{s[0]}), &.{"DRC-112"}, deck, layout, &.{ .{ "below", s[2] }, .{ "at", &.{} }, .{ "above", &.{} } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `critical_area(met1; radius: r) <= a` (`critical_area`, DRC-112): the
/// short-circuit critical area for a square defect of half-side `r`, the
/// union over every pair of figures of their intersection once each is
/// grown by `r`, reported once when above the limit, measuring it, at the
/// centre of its box.
///
/// Closed form (Papadopoulou and Lee, 1999; Koren and Koren, 1998): two
/// parallel lines of length 1000 and a gap 200, under a defect of half-side
/// 150, have `(1000 + 300)(300 - 200) = 130000`, against limits one square
/// unit either side and at it. Three such lines 200 apart under half-side
/// 350 overlap three ways: the pairwise regions cover 1700 x 800 =
/// 1360000, not their sum (the 150 defect sees 260000 there, above every
/// limit). Lines 400 apart are out of reach of a 300 defect and leave
/// 510000 under a 700 one, within its 1 um2; one L-shaped figure has no pair.
fn criticalAreaInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{"met1"}, "rule below critical_area(met1; radius: 150nm) <= 129999nm2\n" ++
        "rule at critical_area(met1; radius: 150nm) <= 130000nm2\n" ++
        "rule above critical_area(met1; radius: 150nm) <= 130001nm2\n" ++
        "rule wide critical_area(met1; radius: 350nm) <= 1um2\n");
    const three = [_]Finding{Finding.area(260_000).pinned(500, 350)};
    const Case = struct { []const u8, Layout, [4][]const Finding };
    const cases_spec = [_]Case{
        .{ "two_lines", try lines(arena, &.{ 0, 300 }), .{ &.{Finding.area(130_000).pinned(500, 200)}, &.{}, &.{}, &.{} } },
        .{ "three_lines", try lines(arena, &.{ 0, 300, 600 }), .{ &three, &three, &three, &.{Finding.area(1_360_000).pinned(500, 350)} } },
        .{ "apart", try lines(arena, &.{ 0, 500 }), .{ &.{}, &.{}, &.{}, &.{} } },
        .{ "one_figure", try c.met1(arena, &.{ .{ 0, 0, 1000, 100 }, .{ 0, 100, 100, 1000 } }), .{ &.{}, &.{}, &.{}, &.{} } },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_spec) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "critical_area/{s}", .{s[0]}), &.{"DRC-112"}, deck, s[1], &.{
        .{ "below", s[2][0] },
        .{ "at", s[2][1] },
        .{ "above", s[2][2] },
        .{ "wide", s[2][3] },
    }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// The redundant-via rate (`via_redundancy`, DRC-117, Xu et al. ASP-DAC
/// 2005 with deck-supplied values): cuts `v` 100 square between `m1` and
/// `m2`, a second cut 200 along an axis, 100 from every cut, a rate of 0.5
/// signing off.
///
/// Oracle: the rate `1 - dead / vias` by hand: a cut on a 1000 square pad
/// (room: rate 1), on pads no larger than itself (dead: 0, found), two cuts
/// on such a pad (doubled already: 1); a cut whose only free neighbour lies
/// 99, 100, 101 from a stray cut (dead at 99: found); one dead of two vias
/// (0.5, at the sign-off) and two of three (1/3, found).
fn viaRedundancyInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "v", "m1", "m2" }, "rule vr via_redundancy(v, m1, m2; pitch: 200nm, space: 100nm) >= 0.5\n");
    var cases: std.ArrayList(Fixture) = .empty;
    var room: Layout = .{};
    try roomy(arena, &room);
    try cases.append(arena, try vrCase(arena, deck, "room", room, try rate(arena, 0, 1)));
    var no_room: Layout = .{};
    try tight(arena, &no_room, 0);
    try cases.append(arena, try vrCase(arena, deck, "no_room", no_room, try rate(arena, 1, 1)));
    var doubled: Layout = .{};
    try pad(arena, &doubled, .{ 0, 0, 100, 300 });
    try doubled.rect(arena, "v", 0, 0, 100, 100);
    try doubled.rect(arena, "v", 0, 200, 100, 300);
    try cases.append(arena, try vrCase(arena, deck, "doubled", doubled, try rate(arena, 0, 1)));
    var one_of_two: Layout = .{};
    try roomy(arena, &one_of_two);
    try tight(arena, &one_of_two, 3000);
    try cases.append(arena, try vrCase(arena, deck, "one_of_two", one_of_two, try rate(arena, 1, 2)));
    var two_of_three: Layout = .{};
    try roomy(arena, &two_of_three);
    try tight(arena, &two_of_three, 3000);
    try tight(arena, &two_of_three, 5000);
    try cases.append(arena, try vrCase(arena, deck, "two_of_three", two_of_three, try rate(arena, 2, 3)));
    // Only +x is free: the strip ends 100 below and above the cut and at its
    // left; m2 ends past the neighbour at 400; a stray cut on m1 alone.
    for (c.sweep3(100)) |sw| {
        const gap = sw.value;
        var stray: Layout = .{};
        try stray.rect(arena, "m1", 0, 0, 2000, 300);
        try stray.rect(arena, "m2", 100, 0, 400, 300);
        try stray.rect(arena, "v", 100, 100, 200, 200);
        try stray.rect(arena, "v", 400 + gap, 100, 500 + gap, 200);
        try cases.append(arena, try vrCase(arena, deck, try std.fmt.allocPrint(arena, "stray/{s}", .{sw.side}), stray, try rate(arena, @intFromBool(gap < 100), 1)));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// An `m1` and `m2` pad over `r`.
fn pad(arena: Allocator, l: *Layout, r: c.Rect) !void {
    try l.rect(arena, "m1", r[0], r[1], r[2], r[3]);
    try l.rect(arena, "m2", r[0], r[1], r[2], r[3]);
}

/// A cut on a pad no larger than itself, at `x`.
fn tight(arena: Allocator, l: *Layout, x: i64) !void {
    try pad(arena, l, .{ x, 0, x + 100, 100 });
    try l.rect(arena, "v", x, 0, x + 100, 100);
}

/// A cut on a 1000 square pad.
fn roomy(arena: Allocator, l: *Layout) !void {
    try pad(arena, l, .{ 0, 0, 1000, 1000 });
    try l.rect(arena, "v", 100, 100, 200, 200);
}

/// The rate `1 - dead / vias`, a finding below 0.5.
fn rate(arena: Allocator, dead: u32, vias: u32) ![]const Finding {
    const r = 1.0 - @as(f64, @floatFromInt(dead)) / @as(f64, @floatFromInt(vias));
    return if (r < 0.5) arena.dupe(Finding, &.{fraction(r)}) else &.{};
}

fn vrCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, found: []const Finding) !Fixture {
    return c.fixture(arena, try std.fmt.allocPrint(arena, "via_redundancy/{s}", .{name}), &.{"DRC-117"}, deck, layout, &.{.{ "vr", found }});
}

/// DFM scoring (`dfm_score`, DRC-111, arXiv:1805.10016 with deck-supplied
/// values): required 100 nm, recommended 200 nm, failure rate 0.5, sign-off
/// 0.9, over `space(m)`, `width(m)` and `enclosure(v, m)`.
///
/// Oracle: the score by hand: a finding at `g` scores `(g - 100) / 100`,
/// clamped to `[0, 1]`, and the design `Π 1 - 0.5 (1 - score)`: a gap of
/// 179, 180, 181 (0.895, found; 0.9 and 0.905 pass), 200 (no finding of the
/// check), two gaps of 150 (0.75², 0.5625; scoring each alone passes
/// neither of them past the product), a gap of 50 (below the required value:
/// 0.5); a bar 150 wide (0.75); a via enclosed by 150 (0.75).
fn dfmScoreInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "m", "v" }, "rule ds dfm_score(m; check: space, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n" ++
        "rule dw dfm_score(m; check: width, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n" ++
        "rule de dfm_score(v, m; check: enclosure, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n");
    var cases: std.ArrayList(Fixture) = .empty;
    const spaces = [_][]const i32{ &.{179}, &.{180}, &.{181}, &.{200}, &.{ 150, 150 }, &.{50} };
    for (spaces) |gaps| {
        var name: std.ArrayList(u8) = .empty;
        for (gaps, 0..) |g, i| try name.print(arena, "{s}{d}", .{ if (i > 0) "_" else "", g });
        // Bars 1000 wide and tall, `gaps` apart in a row.
        var bars: Layout = .{};
        try bars.rect(arena, "m", 0, 0, 1000, 1000);
        var x: i64 = 0;
        for (gaps) |g| {
            x += 1000 + @as(i64, g);
            try bars.rect(arena, "m", x, 0, x + 1000, 1000);
        }
        try cases.append(arena, try dfmCase(arena, deck, try std.fmt.allocPrint(arena, "space/{s}", .{name.items}), &bars, .{ try score(arena, gaps), &.{}, &.{} }));
    }
    var bar: Layout = .{};
    try bar.rect(arena, "m", 0, 0, 150, 1000);
    try cases.append(arena, try dfmCase(arena, deck, "width/150", &bar, .{ &.{}, try score(arena, &.{150}), &.{} }));
    var enclosed: Layout = .{};
    try enclosed.rect(arena, "m", 0, 0, 400, 400);
    try enclosed.rect(arena, "v", 150, 150, 250, 250);
    try cases.append(arena, try dfmCase(arena, deck, "enclosure/150", &enclosed, .{ &.{}, &.{}, try score(arena, &.{150}) }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// The design score of findings at `gaps`, one finding below 0.9.
fn score(arena: Allocator, gaps: []const i32) ![]const Finding {
    var d: f64 = 1.0;
    for (gaps) |g| {
        const s = std.math.clamp(@as(f64, @floatFromInt(g - 100)) / 100.0, 0.0, 1.0);
        d *= 1.0 - 0.5 * (1.0 - s);
    }
    return if (gaps.len == 0 or d >= 0.9) &.{} else arena.dupe(Finding, &.{fraction(d)});
}

/// Every layout also holds a plate far off with a via 300 inside it, so
/// each check has shapes to read and finds nothing there.
fn dfmCase(arena: Allocator, deck: []const u8, name: []const u8, layout: *Layout, rows: [3][]const Finding) !Fixture {
    try layout.rect(arena, "m", 9000, 0, 10_000, 1000);
    try layout.rect(arena, "v", 9300, 300, 9400, 400);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "dfm_score/{s}", .{name}), &.{"DRC-111"}, deck, layout.*, &.{ .{ "ds", rows[0] }, .{ "dw", rows[1] }, .{ "de", rows[2] } });
}

/// Pattern matching (`pattern`, DRC-114): a 300 nm window holding an L of
/// 100-wide arms, `p` exact and `pd` with the window's upper-right
/// `[150, 300]²` don't-care; one finding per matching window, measuring the
/// L's 50000 nm².
///
/// Oracle: matches by construction from the patents' definition (the
/// layout inside the window equals the pattern, in any of the eight
/// orientations, don't-care regions matching anything): the L drawn exactly
/// (both match), with arms running on past the window (both: only the
/// window is compared), its arm 99, 100, 101 wide (only 100), a square in
/// the window's upper-right (only `pd`) and one beside the inner corner
/// (neither), two Ls apart (two each), and a solid 300 square (neither).
/// Every case is placed under the eight symmetries, so a mirrored L is
/// matched too.
fn patternMatchInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const ell_shapes = "shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm, 100nm x 300nm]";
    const deck = try c.newDeck(arena, &.{"m"}, "rule p pattern(m; window: 300nm x 300nm, " ++ ell_shapes ++ ", ignore: none)\n" ++
        "rule pd pattern(m; window: 300nm x 300nm, " ++ ell_shapes ++ ", ignore: [150nm x 150nm, 300nm x 300nm])\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(100)) |sw| {
        const n: usize = @intFromBool(sw.value == 100);
        var l: Layout = .{};
        try ell(arena, &l, 0, sw.value, 300);
        try cases.append(arena, try patternCase(arena, deck, try std.fmt.allocPrint(arena, "arm/{s}", .{sw.side}), l, n, n));
    }
    var long_arms: Layout = .{};
    try ell(arena, &long_arms, 0, 100, 600);
    try cases.append(arena, try patternCase(arena, deck, "long_arms", long_arms, 1, 1));
    var dont_care: Layout = .{};
    try ell(arena, &dont_care, 0, 100, 300);
    try dont_care.rect(arena, "m", 200, 200, 250, 250);
    try cases.append(arena, try patternCase(arena, deck, "square_in_the_dont_care", dont_care, 0, 1));
    var by_corner: Layout = .{};
    try ell(arena, &by_corner, 0, 100, 300);
    try by_corner.rect(arena, "m", 120, 120, 140, 140);
    try cases.append(arena, try patternCase(arena, deck, "square_by_the_corner", by_corner, 0, 0));
    var two: Layout = .{};
    try ell(arena, &two, 0, 100, 300);
    try ell(arena, &two, 2000, 100, 300);
    try cases.append(arena, try patternCase(arena, deck, "two", two, 2, 2));
    var solid: Layout = .{};
    try solid.rect(arena, "m", 0, 0, 300, 300);
    try cases.append(arena, try patternCase(arena, deck, "solid", solid, 0, 0));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// An L at `x`: a `run` long base `arm` tall and a 100 wide arm up to `run`.
fn ell(arena: Allocator, l: *Layout, x: i64, arm: i64, run: i64) !void {
    try l.rect(arena, "m", x, 0, x + run, arm);
    try l.rect(arena, "m", x, arm, x + 100, run);
}

fn patternCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, p: usize, pd: usize) !Fixture {
    const found = try arena.alloc(Finding, @max(p, pd));
    @memset(found, .area(50_000));
    return c.fixture(arena, try std.fmt.allocPrint(arena, "pattern/{s}", .{name}), &.{"DRC-114"}, deck, layout, &.{ .{ "p", found[0..p] }, .{ "pd", found[0..pd] } });
}

test "every critical-area, redundancy, dfm and pattern fixture holds" {
    // Oracle: each fixture's expected answer, from the closed forms and
    // hand-computed rates, scores and matches in the doc comments above,
    // under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
