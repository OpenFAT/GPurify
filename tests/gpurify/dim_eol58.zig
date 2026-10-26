//! `eol_within_spacing` with the `LEF58_SPACING ENDOFLINE` qualifiers
//! (DRC-029), as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`lef58_eol`, `eol58`).
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

/// A 1000 wide line ending at y = 0 (drc_dimension.rs's `LINE`).
const line = c.Rect{ 0, -5000, 1000, 0 };

/// A bar 1000 above the line, inside the keep-out.
const bar_above = c.Rect{ -3000, 1000, 4000, 2000 };

/// `eol_space(met1; eol_width: 1300nm, within: 600nm, .., side_length: ..,
/// opposite_width: .., parallel_more: .., end_prl: .., wrong_dir: ..,
/// extension: .., enclose_cut: ..) >= 1200nm` (`eol_within_spacing` with
/// the `LEF58_SPACING ENDOFLINE` qualifiers, DRC-029). The line is a 1000
/// wide line ending at y = 0 and the probe a bar 1000 above it, inside the
/// keep-out, so every case that applies the rule finds 1000.
///
/// Oracle: the definitions, shapes by construction. LEF/DEF 5.7 (ISPD 2018
/// posting) pp. 129-138:
/// - `MAXLENGTH 3um`: "if the EOL is more than maxLength along both sides,
///   the rule does not apply": a straight line, its sides swept around 3000;
/// - `MINLENGTH 3um [TWOSIDES]`: "if the EOL length is less than minLength
///   along both sides, the rule does not apply", with `TWOSIDES` along any
///   one: a line whose right side turns after a length swept around 3000,
///   its left side 5000;
/// - `OPPOSITEWIDTH 800nm`: the bar's thickness swept around 800, and a bar
///   only partly thin over the keep-out (Figure 1-50 e, a violation);
/// - `SUBTRACTEOLWIDTH`: `PARALLELEDGE 2.1 WITHIN 0.5` searches 2100 - 1000
///   = 1100 out: a neighbour's distance swept around 1100;
/// - `PARALLELEDGE ... MINLENGTH 3um`: the parallel edge beside a side
///   shorter than 3000 is ignored: the line's left side, where the
///   neighbour is, swept around 3000;
/// - `ENCLOSECUT BELOW 0.6 CUTSPACING ..`: "a cut ... less than encloseDist
///   away from the EOL edge, and the cut-edge to metal-edge space beyond
///   the EOL edge is less than cutToMetalSpace": the cut's enclosure swept
///   around 600, then, with the cut 100 in and a 1200 space, the bar's depth
///   swept around 1100, and no cut.
///
/// `OpenROAD`'s `TritonRoute` (`FlexGC_eol.cpp`) is the reading for the rest:
/// `WRONGDIRSPACING 1.5` on a horizontal layer holds this end (horizontal,
/// so a vertical wire's) to 1500, the depth swept, and on a vertical layer
/// keeps 1200; `ENDPRLSPACING 1.6 PRL 0.3` flags a block 1400 out whose run
/// along the end itself is swept around 300, and one at a run of 200 whose
/// depth is swept around 1600; `ENDTOEND 1.4 EXTENSION 0.1` pairs two ends
/// 1300 apart only while their spans widened by 100 overlap, the second
/// line's offset swept around 1200; `ALLCUTS` needs every cut in the band
/// close to the bar, so of two cuts 1100 and 1500 from it one is enough only
/// without it. Every case is placed under all eight symmetries, the
/// wrong-direction ones under the four that keep the axes.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    var axis: std.ArrayList(Fixture) = .empty;
    const max_length = try lef58Eol(arena, &.{.{ "side_length", "(length: 3um, maximum: true, two_sides: false)" }});
    for (try c.sweep(arena, depth, 3000)) |s| {
        try case(arena, &cases, try named(arena, "max_length", s, 3000), max_length, try c.met1(arena, &.{ .{ 0, -s, 1000, 0 }, bar_above }), try found(arena, s <= 3000));
    }
    for ([_]bool{ false, true }) |two_sides| {
        const deck = try lef58Eol(arena, &.{.{ "side_length", try std.fmt.allocPrint(arena, "(length: 3um, maximum: false, two_sides: {})", .{two_sides}) }});
        for (try c.sweep(arena, depth, 3000)) |r| {
            try case(arena, &cases, try std.fmt.allocPrint(arena, "min_length/two_sides_{}/{s}", .{ two_sides, try c.side(arena, r, 3000) }), deck, try c.met1(arena, &.{ .{ 0, -r, 1000, 0 }, .{ 0, -6000, 2000, -r }, bar_above }), try found(arena, !two_sides or r >= 3000));
        }
    }
    const opposite = try lef58Eol(arena, &.{.{ "opposite_width", "800nm" }});
    for (try c.sweep(arena, depth, 800)) |t| {
        try case(arena, &cases, try named(arena, "opposite_width", t, 800), opposite, try c.met1(arena, &.{ line, .{ -3000, 1000, 4000, 1000 + t } }), try found(arena, t < 800));
    }
    try case(arena, &cases, "opposite_width/partly_thin", opposite, try c.met1(arena, &.{ line, .{ -3000, 1000, 500, 1500 }, .{ 500, 1000, 4000, 3000 } }), try found(arena, true));
    const subtract = try lef58Eol(arena, &.{ .{ "parallel", "(space: 2100nm, within: 500nm, two_edges: false)" }, .{ "parallel_more", "(subtract_eol_width: true, min_length: none)" } });
    for (try c.sweep(arena, depth, 1100)) |p| {
        try case(arena, &cases, try named(arena, "subtract_eol_width", p, 1100), subtract, try c.met1(arena, &.{ line, bar_above, .{ -p - 2000, -5000, -p, 0 } }), try found(arena, p < 1100));
    }
    const side_min = try lef58Eol(arena, &.{ .{ "parallel", "(space: 1100nm, within: 500nm, two_edges: false)" }, .{ "parallel_more", "(subtract_eol_width: false, min_length: 3um)" } });
    for (try c.sweep(arena, depth, 3000)) |l| {
        try case(arena, &cases, try named(arena, "parallel_min_length", l, 3000), side_min, try c.met1(arena, &.{ .{ 0, -l, 1000, 0 }, .{ -400, -6000, 1000, -l }, bar_above, .{ -2500, -2000, -500, 0 } }), try found(arena, l >= 3000));
    }
    const enclosed = try cut(arena, 600, 2000);
    for (try c.sweep(arena, depth, 600)) |e| {
        var layout = try c.met1(arena, &.{ line, bar_above });
        try layout.rect(arena, "via", 200, -e - 400, 800, -e);
        try case(arena, &cases, try named(arena, "enclose_cut/within", e, 600), enclosed, layout, try found(arena, e < 600));
    }
    const spaced = try cut(arena, 600, 1200);
    for (try c.sweep(arena, depth, 1100)) |g| {
        var layout = try c.met1(arena, &.{ line, .{ -3000, g, 4000, g + 1000 } });
        try layout.rect(arena, "via", 200, -500, 800, -100);
        try case(arena, &cases, try named(arena, "enclose_cut/space", g, 1100), spaced, layout, if (g < 1100) try one(arena, c.pin(.length(g), 1000, g)) else &.{});
    }
    try case(arena, &cases, "enclose_cut/no_cut", enclosed, try c.met1(arena, &.{ line, bar_above }), &.{});
    // Two cuts in the band, 1100 and 1500 from the bar: one is enough, but
    // not with ALLCUTS.
    for ([_]bool{ false, true }) |all| {
        var layout = try c.met1(arena, &.{ line, bar_above });
        try layout.rect(arena, "via", 200, -500, 450, -100);
        try layout.rect(arena, "via", 550, -900, 800, -500);
        const deck = try lef58Eol(arena, &.{.{ "enclose_cut", try std.fmt.allocPrint(arena, "(cut: via, within: 600nm, space: 1200nm, all_cuts: {})", .{all}) }});
        try case(arena, &cases, try std.fmt.allocPrint(arena, "enclose_cut/all_cuts_{}", .{all}), deck, layout, try found(arena, !all));
    }
    for ([_]bool{ true, false }) |horizontal| {
        const deck = try lef58Eol(arena, &.{.{ "wrong_dir", try std.fmt.allocPrint(arena, "(space: 1500nm, horizontal: {})", .{horizontal}) }});
        for (try c.sweep(arena, depth, 1500)) |g| {
            const need: i64 = if (horizontal) 1500 else 1200;
            // A quarter turn swaps the layer's directions: axis symmetries only.
            const findings: []const Finding = if (g < need) try one(arena, c.pin(.length(g), 1000, g)) else &.{};
            try axis.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol58/wrong_dir/horizontal_{}/{s}", .{ horizontal, try c.side(arena, g, 1500) }), &.{"DRC-029"}, deck, try c.met1(arena, &.{ line, .{ -3000, g, 4000, g + 1000 } }), &.{.{ "e", findings }}));
        }
    }
    const end_prl = try lef58Eol(arena, &.{.{ "end_prl", "(space: 1600nm, prl: 300nm)" }});
    for (try c.sweep(arena, depth, 300)) |p| {
        try case(arena, &cases, try named(arena, "end_prl/run", p, 300), end_prl, try c.met1(arena, &.{ line, .{ 1000 - p, 1400, 3000, 2400 } }), if (p <= 300) try one(arena, c.pin(.length(1400), 2000 - p, 1400)) else &.{});
    }
    for (try c.sweep(arena, depth, 1600)) |d| {
        try case(arena, &cases, try named(arena, "end_prl/depth", d, 1600), end_prl, try c.met1(arena, &.{ line, .{ 800, d, 3000, d + 1000 } }), if (d < 1600) try one(arena, c.pin(.length(d), 1800, d)) else &.{});
    }
    const extension = try lef58Eol(arena, &.{ .{ "end_to_end", "1400nm" }, .{ "extension", "100nm" } });
    for (try c.sweep(arena, depth, 1200)) |x| {
        try case(arena, &cases, try named(arena, "extension", x, 1200), extension, try c.met1(arena, &.{ line, .{ x, 1300, x + 1000, 6300 } }), if (x < 1200) try one(arena, .length(1300)) else &.{});
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try c.everyAxisPlacementInto(arena, axis.items, out);
}

// ---- private ----

/// Example 1-18's rule with the `LEF58_SPACING ENDOFLINE` qualifiers: each
/// of `stated` (a deck parameter and its value), the rest `none`; `via`
/// declared for `enclose_cut`.
fn lef58Eol(arena: Allocator, stated: []const [2][]const u8) ![]const u8 {
    var params: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "parallel", "end_to_end", "side_length", "opposite_width", "parallel_more", "end_prl", "wrong_dir", "extension", "enclose_cut" }) |name| {
        const value = for (stated) |s| (if (std.mem.eql(u8, s[0], name)) break s[1]) else "none";
        try params.print(arena, ", {s}: {s}", .{ name, value });
    }
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\nlayer via = gds(68, 44)\nrule e eol_space(met1; eol_width: 1300nm, within: 600nm{s}) >= 1200nm\n", .{params.items});
}

fn cut(arena: Allocator, within: i64, space: i64) ![]const u8 {
    return lef58Eol(arena, &.{.{ "enclose_cut", try std.fmt.allocPrint(arena, "(cut: via, within: {d}nm, space: {d}nm, all_cuts: false)", .{ within, space }) }});
}

/// The probe bar's one finding when the rule applies.
fn found(arena: Allocator, hit: bool) ![]const Finding {
    return if (hit) one(arena, c.pin(.length(1000), 1000, 1000)) else &.{};
}

fn one(arena: Allocator, f: Finding) ![]const Finding {
    return arena.dupe(Finding, &.{f});
}

fn named(arena: Allocator, stem: []const u8, value: i64, limit: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ stem, try c.side(arena, value, limit) });
}

fn case(arena: Allocator, cases: *std.ArrayList(Fixture), shape: []const u8, deck: []const u8, layout: Layout, findings: []const Finding) !void {
    try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "eol58/{s}", .{shape}), &.{"DRC-029"}, deck, layout, &.{.{ "e", findings }}));
}

test "every eol58 fixture holds" {
    // Oracle: the definitions, shapes by construction: LEF/DEF 5.7 pp.
    // 129-138 for the `LEF58_SPACING ENDOFLINE` qualifiers, `TritonRoute`'s
    // `FlexGC_eol.cpp` for `WRONGDIRSPACING`, `ENDPRLSPACING`, `EXTENSION`
    // and `ALLCUTS`; under every symmetry (the wrong-direction cases the
    // four that keep the axes) at two translations.
    try c.checkGenerated(fixturesInto);
}
