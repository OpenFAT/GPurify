//! Self-aligned double patterning, stitches and trim/cut layers, as
//! exhaustive fixtures. Ported from tests/exhaustive/drc_overlay.rs
//! (`sadp_colours`, `sadp_line_ends`, `stitch`, `trim_cut`).
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
    try sadpColoursInto(arena, out);
    try sadpLineEndsInto(arena, out);
    try stitchInto(arena, out);
    try trimCutInto(arena, out);
}

// ---- private ----

/// `sadp` (DRC-128): US 2015/0286764 A1's bands on its own numbers, S_INT
/// 72 nm and S_LRG 120 nm, with 24 nm tracks. A triangle of 500 nm squares
/// whose bottom pair is `g01` apart and whose top bar is `g02` above both
/// has one edge of the bottom gap's band and two of the top gap's, so its
/// different-colour count is odd exactly when `g01` is under 72 nm
/// (\[0015\]: a loop "is not decomposable due to the odd number of DC
/// edges"): one finding, 1 odd cycle against 0, for 50/100 (one DC edge,
/// FIG. 1N's kind) and 50/50 (three); none for 100/50 (two DC edges, even)
/// and 150/50 (the bottom pair is colour-free, no cycle). A U whose arms are
/// 50 nm apart is a different-colour edge to itself: one finding. FIG. 1R
/// (\[0020\]): 24 nm lines 72 nm then 24 nm either side of a 72 nm line
/// colour without a cycle, and the track row flags the 72 nm line (two
/// tracks: 72 (the measured width; its limit is the legal 24 under it)); at
/// 120 nm (three tracks) it is clean. Breaks if a same-colour edge counts as
/// a different one (100/50 flags), the bands are read inclusive at 72
/// (50/100 clears), or the width rule allows even track counts.
fn sadpColoursInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "m", "o" }, "rule c sadp(m; different: 72nm, same: 120nm, track_width: none, track_space: none)\n" ++
        "rule t sadp(m; different: 72nm, same: 120nm, track_width: 24nm, track_space: 24nm)\n");
    const wide500: Finding = .length(500);
    const odd_triangle = [_]Finding{ c.count(1), wide500, wide500, wide500 };
    const Case = struct { name: []const u8, layout: Layout, c: []const Finding, t: []const Finding };
    const cases_spec = [_]Case{
        .{ .name = "one_dc_edge", .layout = try triangle(arena, 50, 100), .c = &.{c.count(1)}, .t = &odd_triangle },
        .{ .name = "three_dc_edges", .layout = try triangle(arena, 50, 50), .c = &.{c.count(1)}, .t = &odd_triangle },
        .{ .name = "two_dc_edges", .layout = try triangle(arena, 100, 50), .c = &.{}, .t = odd_triangle[1..] },
        .{ .name = "colour_free_pair", .layout = try triangle(arena, 150, 50), .c = &.{}, .t = odd_triangle[1..] },
        .{ .name = "self_conflict", .layout = try sq(arena, &.{ .{ 0, 0, 24, 500 }, .{ 74, 0, 98, 500 }, .{ 0, 0, 98, 24 } }), .c = &.{c.count(1)}, .t = &.{c.count(1)} },
        .{ .name = "fig_1r/72", .layout = try fig1r(arena, 72), .c = &.{}, .t = &.{.length(72)} },
        .{ .name = "fig_1r/120", .layout = try fig1r(arena, 120), .c = &.{}, .t = &.{} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_spec) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "sadp/{s}", .{s.name}), &.{"DRC-128"}, deck, s.layout, &.{ .{ "c", s.c }, .{ "t", s.t } }));
    try c.everyPlacementInto(arena, cases.items, out);
    var empty: Fixture = .init("sadp/empty", &.{"DRC-128"}, deck, harness.drc);
    try empty.layout.rect(arena, "o", 0, 0, 100, 100);
    try empty.claim(arena, .outcome("c", .skipped));
    try empty.claim(arena, .outcome("t", .skipped));
    try out.append(arena, empty);
}

/// `m` rectangles.
fn sq(arena: Allocator, boxes: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, "m", boxes);
    return l;
}

/// Two 500 nm squares `g01` apart under a bar `g02` above both.
fn triangle(arena: Allocator, g01: i64, g02: i64) !Layout {
    return sq(arena, &.{ .{ 0, 0, 500, 500 }, .{ 500 + g01, 0, 1000 + g01, 500 }, .{ 0, 500 + g02, 1000 + g01, 1000 + g02 } });
}

/// FIG. 1R: 24 nm lines 72 nm either side of a `middle` wide line.
fn fig1r(arena: Allocator, middle: i64) !Layout {
    return sq(arena, &.{ .{ 0, 0, 24, 500 }, .{ 96, 0, 96 + middle, 500 }, .{ 120 + middle, 0, 144 + middle, 500 } });
}

/// `sadp_line_end` (DRC-128): Xu et al. (TCAD 2015) Table II on its own
/// example (w = s = 24, w_r = 44, s_r = 46, w_e = 6, w_sp = 24 nm, p. 703):
/// tip 44 - 12 = 32, overlap 46 + 12 = 58, corner sqrt(32^2 - 24^2) = 21.2,
/// stated 22, and offset 44 nm. Horizontal lines 24 nm tall on tracks 48 nm
/// apart (24 nm between them, the `adjacent` gap). At one unit under each
/// limit one finding measures the gap, overlap or offset; at the limit,
/// none: one track, ends 31 / 32 apart; adjacent tracks, ends facing apart
/// overlapping 57 / 58; not overlapping, 21 / 22 apart along the track;
/// flush at one end and 43 / 44 apart at the other. Lines three tracks apart
/// interact with nothing. Breaks if a rule is read inclusive, the tracks'
/// gap is not the `adjacent` test, or flush ends count as an offset.
fn sadpLineEndsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{"m"}, "rule le sadp_line_end(m; adjacent: 24nm, tip: 32nm, overlap: 58nm, corner: 22nm, offset: 44nm)\n");
    const Case = struct { name: []const u8, b: [2]i64, track: i64, le: []const Finding };
    const cases_spec = [_]Case{
        .{ .name = "tip/under", .b = .{ 531, 1000 }, .track = 0, .le = &.{.length(31)} },
        .{ .name = "tip/at", .b = .{ 532, 1000 }, .track = 0, .le = &.{} },
        .{ .name = "overlap/under", .b = .{ 443, 1000 }, .track = 1, .le = &.{.length(57)} },
        .{ .name = "overlap/at", .b = .{ 442, 1000 }, .track = 1, .le = &.{} },
        .{ .name = "corner/under", .b = .{ 521, 1000 }, .track = 1, .le = &.{.length(21)} },
        .{ .name = "corner/at", .b = .{ 522, 1000 }, .track = 1, .le = &.{} },
        .{ .name = "offset/under", .b = .{ 0, 543 }, .track = 1, .le = &.{.length(43)} },
        .{ .name = "offset/at", .b = .{ 0, 544 }, .track = 1, .le = &.{} },
        .{ .name = "three_tracks", .b = .{ 443, 1000 }, .track = 3, .le = &.{} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_spec) |s| {
        const layout = try sq(arena, &.{ .{ 0, 0, 500, 24 }, .{ s.b[0], 48 * s.track, s.b[1], 48 * s.track + 24 } });
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "sadp_line_end/{s}", .{s.name}), &.{"DRC-128"}, deck, layout, &.{.{ "le", s.le }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Stitches (DRC-103), written in the deck language: a wire split across
/// masks `c1` and `c2` overlaps itself where the pieces meet, and that
/// overlap must run at least the overlap margin along the wire,
/// `overlap(c1, c2) >= 10nm` (Ghaida et al., IEEE TCAD 2013, Table I: 10 nm;
/// Kahng et al., ICCAD 2008: the overlap length), and must sit where no
/// other figure is within the same-mask spacing, `space(c1 and c2, (c1 or
/// c2).not_interacting(c1 and c2)) >= 110nm` ("stitches should be located
/// only in non-violating parts", Ghaida et al.).
///
/// A 40 nm wire, its two pieces overlapping 9/10/11 along it, with a `c1`
/// wire 500 above; and the same wire overlapping 20, with that `c1` wire
/// 109/110/111 above. Orientation-free: all symmetries.
fn stitchInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "c1", "c2" }, "rule ST.OV overlap(c1, c2) >= 10nm\n" ++
        "rule ST.SP space(c1 and c2, (c1 or c2).not_interacting(c1 and c2)) >= 110nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(10)) |sw| {
        const layout = try wire(arena, sw.value, .{ 0, 540, 1000, 580 });
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "stitch/overlap/{s}", .{sw.side}), &.{"DRC-103"}, deck, layout, &.{ .{ "ST.OV", try c.below(arena, sw.value, 10) }, .{ "ST.SP", &.{} } }));
    }
    for (c.sweep3(110)) |sw| {
        const g = sw.value;
        const layout = try wire(arena, 20, .{ 0, 40 + g, 1000, 80 + g });
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "stitch/keep_out/{s}", .{sw.side}), &.{"DRC-103"}, deck, layout, &.{ .{ "ST.OV", &.{} }, .{ "ST.SP", try c.below(arena, g, 110) } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// A 40 nm wire split across `c1` and `c2` overlapping `t`, and a `c1`
/// wire `other`.
fn wire(arena: Allocator, t: i64, other: c.Rect) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "c1", 0, 0, 500, 40);
    try l.rect(arena, "c2", 500 - t, 0, 1000, 40);
    try l.rect(arena, "c1", other[0], other[1], other[2], other[3]);
    return l;
}

/// Trim and cut layers (DRC-105), written in the deck language: ASAP7's
/// gate cut, DRM Table 3.6.1. GCUT.W.1 `width(GCUT) >= 17nm`;
/// GCUT.GATE.EX.1 `extension(GCUT, GATE) >= 17nm`, past each gate edge it
/// crosses; GCUT.AUX.1 "GCUT layer may not exist without the layer GATE",
/// `forbidden(GCUT.not_interacting(GATE))`; GCUT.AUX.2 "GCUT layer vertical
/// edge may not lie inside, or coincide with, the GATE layer", the vertical
/// GCUT edges strictly inside GATE or on a GATE edge.
///
/// A 20 x 200 gate. A 17-tall cut across it reaching 16/17/18 past each
/// side (EX.1 at the limit); a cut 16/17/18 tall reaching 30 past (W.1 at
/// the limit); a cut ending inside the gate and one ending on its far edge
/// (each a 17 nm vertical edge for AUX.2, and an extension of 0); a cut away
/// from any gate (AUX.1, its area). AUX.2 names an axis, so only the
/// symmetries that keep each axis apply.
fn trimCutInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "GATE", "GCUT" }, "rule GCUT.W.1 width(GCUT) >= 17nm\n" ++
        "rule GCUT.GATE.EX.1 extension(GCUT, GATE) >= 17nm\n" ++
        "rule GCUT.AUX.1 forbidden(GCUT.not_interacting(GATE))\n" ++
        "rule GCUT.AUX.2 forbidden(GCUT.edges().vertical().inside_part(GATE) " ++
        "or (GCUT.edges().vertical() and GATE.edges()))\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(17)) |sw| {
        const e = sw.value;
        try cases.append(arena, try trimCase(arena, deck, try std.fmt.allocPrint(arena, "extension/{s}", .{sw.side}), .{ -e, 90, 20 + e, 107 }, .{ &.{}, try c.below(arena, e, 17), &.{}, &.{} }));
    }
    for (c.sweep3(17)) |sw| {
        const h = sw.value;
        try cases.append(arena, try trimCase(arena, deck, try std.fmt.allocPrint(arena, "width/{s}", .{sw.side}), .{ -30, 90, 50, 90 + h }, .{ try c.below(arena, h, 17), &.{}, &.{}, &.{} }));
    }
    try cases.append(arena, try trimCase(arena, deck, "ends_inside", .{ -30, 90, 10, 107 }, .{ &.{}, try c.lengths(arena, &.{0}), &.{}, try c.lengths(arena, &.{17}) }));
    try cases.append(arena, try trimCase(arena, deck, "ends_on_edge", .{ -30, 90, 20, 107 }, .{ &.{}, try c.lengths(arena, &.{0}), &.{}, try c.lengths(arena, &.{17}) }));
    try cases.append(arena, try trimCase(arena, deck, "alone", .{ 100, 90, 150, 107 }, .{ &.{}, &.{}, try c.areas(arena, &.{850}), &.{} }));
    try c.everyAxisPlacementInto(arena, cases.items, out);
}

/// One `trim_cut` case: the gate and `cut`, and the four rules' findings.
fn trimCase(arena: Allocator, deck: []const u8, name: []const u8, cut: c.Rect, rules: [4][]const Finding) !Fixture {
    var layout: Layout = .{};
    try layout.rect(arena, "GATE", 0, 0, 20, 200);
    try layout.rect(arena, "GCUT", cut[0], cut[1], cut[2], cut[3]);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "trim_cut/{s}", .{name}), &.{"DRC-105"}, deck, layout, &.{
        .{ "GCUT.W.1", rules[0] },
        .{ "GCUT.GATE.EX.1", rules[1] },
        .{ "GCUT.AUX.1", rules[2] },
        .{ "GCUT.AUX.2", rules[3] },
    });
}

test "every sadp, stitch and trim fixture holds" {
    // Oracle: each fixture's expected answer, derived from the cited
    // patents' and papers' own numbers (the doc comments above), under
    // every symmetry (every axis-keeping one for trim_cut) at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
