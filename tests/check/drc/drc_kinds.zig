//! Presence, net-aware, table and spacing rule kinds, end to end: deck text,
//! a layout of rectangles, derived layers computed, nets extracted, the DRC
//! rule set run. Ported from the root tests/drc_kinds.rs (first half; the
//! rest is drc_kinds_edges.zig); the Rust file round-trips each layout
//! through GDSII, which is ingest's to test, so here the store is drawn
//! directly.
//!
//! Oracle throughout: construct-from-answer. Every layout is drawn on a 1 nm
//! grid so the expected measurement is read off the coordinates by hand, and
//! the rules are the foundry's own wording (sky130 periphery rules, gf180
//! NW.2a/2b, IHP Metal1 M1.e/f). Each test also draws a case a plausible
//! wrong implementation would get wrong, named where it is drawn.
//!
//! Contents:
//! - `pub const Rect`, `pub const sky130`, `pub const ihp_m1`
//! - `pub fn runRects(text: []const u8, rects: []const Rect) !common.Run`
//! - `pub fn pairs(r: *common.Run, rule: []const u8) ![]const [2]Measurement`, `pub fn len(v: i64) Measurement`
//! - `pub fn countOf(got: []const [2]Measurement, want: [2]Measurement) usize`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;
const Measurement = check.report.Measurement;
const Outcome = check.report.Outcome;

/// A rectangle on a named layer: `[xlo, ylo, xhi, yhi]`.
pub const Rect = struct { []const u8, [4]i64 };

pub const sky130 =
    \\grid 5nm
    \\layer diff  = gds(65, 20)
    \\layer tap   = gds(65, 44)
    \\layer poly  = gds(66, 20)
    \\layer licon = gds(66, 44)
    \\layer npc   = gds(95, 20)
    \\layer nsdm  = gds(93, 44)
    \\layer psdm  = gds(94, 20)
    \\layer met1  = gds(68, 20)
    \\
;

/// IHP SG13G2 Metal1: M1.b 0.18; M1.e 0.22 "if at least one line is wider
/// than 0.3 µm and the parallel run is more than 1.0 µm"; M1.f 0.60 for
/// wider than 10 µm and a run of more than 10 µm.
pub const ihp_m1 =
    \\grid 5nm
    \\layer met1 = gds(8, 0)
    \\rule M1.bef space_table(met1;
    \\    prl:   [0um, 1um, 10um],
    \\    width: [0um, 0.3um, 10um],
    \\    space: [[180nm, 180nm, 180nm],
    \\            [180nm, 220nm, 220nm],
    \\            [180nm, 220nm, 600nm]])
    \\
;

const gf180_nwell =
    \\grid 5nm
    \\layer nwell = gds(21, 0)
    \\layer cont  = gds(33, 0)
    \\layer met1  = gds(34, 0)
    \\connect conductors [nwell, met1]
    \\connect via cont [nwell, met1]
    \\rule NW.2a space(nwell; nets: same) >= 600nm
    \\rule NW.2b space(nwell; nets: different) >= 1400nm
    \\
;

/// Parse `text`, draw `rects`, derive, extract and run the DRC rules.
pub fn runRects(text: []const u8, rects: []const Rect) !common.Run {
    var layout: common.Layout = .{};
    defer layout.deinit();
    for (rects) |r| try layout.rect(r[0], r[1][0], r[1][1], r[1][2], r[1][3]);
    return common.run(text, &layout);
}

/// The rule's findings as `(measured, limit)`.
pub fn pairs(r: *common.Run, rule: []const u8) ![]const [2]Measurement {
    const row = r.row(rule);
    const out = try r.arena.allocator().alloc([2]Measurement, row.findings.len);
    for (out, row.findings) |*o, f| o.* = .{ f.measured, f.limit };
    return out;
}

pub fn len(v: i64) Measurement {
    return .length(v);
}

pub fn countOf(got: []const [2]Measurement, want: [2]Measurement) usize {
    var n: usize = 0;
    for (got) |g| n += @intFromBool(std.meta.eql(g, want));
    return n;
}

// ---- private ----

fn area(v: i128) Measurement {
    return .area(v);
}

fn withSky130(arena: std.mem.Allocator, rules: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ sky130, rules, "\n" });
}

/// Types the rules of a deck that parses; the error and the row it names.
fn typeErr(text: []const u8) !struct { ?anyerror, []const u8 } {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    var cd = check.deck.compile.compile(gpa, arena.allocator(), text, try geom.Grid.init(1000), &strings, &diag) catch |e| {
        const id = if (@backingInt(diag.rule.rule) != std.math.maxInt(u32)) strings.resolve(diag.rule.rule) else "";
        return .{ e, if (std.mem.eql(u8, id, "t")) "t" else if (std.mem.eql(u8, id, "fs")) "fs" else "?" };
    };
    cd.deinit(gpa);
    return .{ null, "" };
}

test "licon 17 flags the triple overlap and not a licon that only abuts" {
    // sky130 licon.17 "Licons may not overlap both poly and (diff or tap)",
    // written with the layer expression inline. The licon over poly and diff
    // reports the area of the triple overlap, 100 x 50. The licon that only
    // abuts a poly and a diff on two of its sides overlaps neither.
    // Oracle: foundry example, sky130 licon.17, by hand: the triple overlap is
    // x 0..100, y 0..50, area 5000; the abutting licon and the one over poly
    // alone overlap no diff or tap.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try runRects(try withSky130(arena.allocator(), "rule licon.17 forbidden(licon and poly and (diff or tap))"), &.{
        .{ "licon", .{ 0, 0, 170, 170 } },       .{ "poly", .{ -100, 0, 100, 50 } },
        .{ "diff", .{ -100, -100, 500, 50 } },   .{ "licon", .{ 2_000, 0, 2_170, 170 } },
        .{ "poly", .{ 1_800, 0, 2_000, 170 } },  .{ "tap", .{ 2_170, 0, 2_400, 170 } },
        .{ "licon", .{ 4_000, 0, 4_170, 170 } }, .{ "poly", .{ 3_900, -100, 4_300, 300 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{.{ area(5000), area(0) }}, try pairs(&r, "licon.17"));
}

test "psd 6 flags the part of the butting edge outside the implant" {
    // sky130 n/psd.6 "Enclosure of diff/tap butting edge by nsdm (psdm)" is
    // 0: the butting edge may not leave the implant. An implant reaching the
    // butting edge exactly is clean; one covering only its upper half leaves
    // 250 of the 500-long edge outside.
    // Oracle: foundry example, sky130 n/psd.6 (enclosure of the butting edge
    // 0), by hand: the second implant covers y 2250..2500 of the 500-long
    // edge, leaving 250 bare with its midpoint at (1000, 2125).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try runRects(try withSky130(arena.allocator(), "layer butt = tap.edges() and diff.edges()\nrule psd.6 forbidden(butt.outside_part(psdm))"), &.{
        .{ "diff", .{ 0, 0, 1_000, 500 } },          .{ "tap", .{ 1_000, 0, 1_500, 500 } },
        .{ "psdm", .{ 1_000, -125, 1_625, 625 } },   .{ "diff", .{ 0, 2_000, 1_000, 2_500 } },
        .{ "tap", .{ 1_000, 2_000, 1_500, 2_500 } }, .{ "psdm", .{ 1_000, 2_250, 1_625, 2_625 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{.{ len(250), len(0) }}, try pairs(&r, "psd.6"));
    try testing.expectEqual([2]i64{ 1_000, 2_125 }, r.row("psd.6").findings[0].at);
}

test "licon 16 counts only licons entirely on the tap" {
    // sky130 licon.16 "every tap must enclose at least one licon1". A licon
    // straddling the tap's edge is not enclosed. The L-shaped tap's bounding
    // box holds a licon that sits in the L's notch, off the tap.
    // Oracle: foundry example, sky130 licon.16, by hand: the first tap holds
    // its licon; the straddling licon and the one in the L's notch are on no
    // tap entirely, so two taps hold 0 of 1.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try runRects(try withSky130(arena.allocator(), "rule licon.16 contains(tap, licon) >= 1"), &.{
        .{ "tap", .{ 0, 0, 500, 500 } },           .{ "licon", .{ 100, 100, 270, 270 } },
        .{ "tap", .{ 1_000, 0, 1_500, 500 } },     .{ "licon", .{ 1_400, 100, 1_570, 270 } },
        .{ "tap", .{ 3_000, 0, 4_000, 300 } },     .{ "tap", .{ 3_000, 300, 3_300, 1_000 } },
        .{ "licon", .{ 3_500, 500, 3_670, 670 } },
    });
    defer r.deinit();
    const c = [2]Measurement{ .count(0), .count(1) };
    try testing.expectEqualSlices([2]Measurement, &.{ c, c }, try pairs(&r, "licon.16"));
}

test "contains counts touching inner shapes as one" {
    // Two licons that touch are one shape, so a tap holding only that pair
    // holds one, short of two.
    // Oracle: `docs/deck.md`'s `contains` ("touching inner shapes count as
    // one"): the first tap holds two apart, the second one touching pair, 1
    // of 2.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try runRects(try withSky130(arena.allocator(), "rule two contains(tap, licon) >= 2"), &.{
        .{ "tap", .{ 0, 0, 1_000, 500 } },         .{ "licon", .{ 100, 100, 270, 270 } },
        .{ "licon", .{ 500, 100, 670, 270 } },     .{ "tap", .{ 2_000, 0, 3_000, 500 } },
        .{ "licon", .{ 2_100, 100, 2_270, 270 } }, .{ "licon", .{ 2_270, 100, 2_440, 270 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{.{ .count(1), .count(2) }}, try pairs(&r, "two"));
}

test "licon 18 reports the area outside the npc" {
    // sky130 licon.18 "npc must enclose `poly_licon`". A poly licon touching
    // the npc edge from inside is enclosed; one sticking 20 out of it leaves
    // 20 x 170 outside. The third sits in the notch of an L-shaped npc.
    // Oracle: foundry example, sky130 licon.18, by hand: the second licon
    // sticks 20 out of its npc, 20 x 170 outside; the third, in the L's notch,
    // is wholly outside, 170 x 170.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try runRects(try withSky130(arena.allocator(), "rule licon.18 inside(licon and poly, npc)"), &.{
        .{ "poly", .{ -500, -500, 6_000, 1_500 } }, .{ "npc", .{ 0, 0, 500, 500 } },
        .{ "licon", .{ 330, 100, 500, 270 } },      .{ "npc", .{ 1_000, 0, 1_500, 500 } },
        .{ "licon", .{ 1_350, 100, 1_520, 270 } },  .{ "npc", .{ 3_000, 0, 4_000, 300 } },
        .{ "npc", .{ 3_000, 300, 3_300, 1_000 } },  .{ "licon", .{ 3_500, 500, 3_670, 670 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{ .{ area(20 * 170), area(0) }, .{ area(170 * 170), area(0) } }, try pairs(&r, "licon.18"));
}

test "nwell spacing follows the extracted net not the drawing" {
    // gf180 NW.2a "Min. Nwell spacing to Nwell at the same potential 0.6" and
    // NW.2b "... at different potential 1.4". W1 and W2 are 500 apart and
    // tied through metal, so they are one net: NW.2a flags them and NW.2b
    // does not. W3 is 800 from W2 and tied to nothing: NW.2b flags it.
    // Oracle: foundry example, gf180 NW.2a (0.6 um, same potential) and NW.2b
    // (1.4 um, different), by hand: W1 and W2 are one net through the strap,
    // 500 apart; W3 is 800 from W2 on its own net.
    var r = try runRects(gf180_nwell, &.{
        .{ "nwell", .{ 0, 0, 2_000, 2_000 } },        .{ "nwell", .{ 2_500, 0, 4_500, 2_000 } },
        .{ "nwell", .{ 5_300, 0, 7_300, 2_000 } },    .{ "cont", .{ 1_000, 1_000, 1_200, 1_200 } },
        .{ "cont", .{ 3_000, 1_000, 3_200, 1_200 } }, .{ "met1", .{ 900, 900, 3_300, 1_300 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{.{ len(500), len(600) }}, try pairs(&r, "NW.2a"));
    try testing.expectEqualSlices([2]Measurement, &.{.{ len(800), len(1_400) }}, try pairs(&r, "NW.2b"));
    try testing.expectEqual(Outcome.ran, r.row("NW.2b").outcome);
}

test "net spacing on a layer that is not a conductor is refused at load" {
    // A layer that carries no net cannot be asked which net it is on.
    // Oracle: `docs/deck.md`'s `space(L; nets: ...)`: "`L` must be a
    // conductor", and this deck connects nothing.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.deck.Diag = .{};
    const got = ingest.deck.parseDeck(arena.allocator(), gpa, "grid 5nm\nlayer nwell = gds(21, 0)\nrule NW.2b space(nwell; nets: different) >= 1400nm\n", try geom.Grid.init(1000), &strings, &diag);
    try testing.expectError(error.Malformed, got);
    try testing.expect(std.mem.indexOf(u8, diag.malformed, "not a conductor") != null);
}

test "net spacing without nets is refused not clean" {
    // Without nets the rule cannot run, and says so.
    // Oracle: the contract of `RuleSet::run`, which records one `RuleRun` row
    // per rule and `Refused` for a net spacing rule without nets. The deck
    // has two rules, NW.2a and NW.2b, so two refused rows that examined
    // nothing and no violation.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    var cd = try check.deck.compile.compile(gpa, arena.allocator(), gf180_nwell, try geom.Grid.init(1000), &strings, &diag);
    defer cd.deinit(gpa);
    var lb = @import("testgen").shapes.LayoutBuilder.init(@intCast(cd.deck.layers.len()));
    _ = try lb.rect(gpa, 2, 0, 0, 100, 100);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: common.Sink = .{};
    defer sink.deinit();
    try check.drc.run(gpa, .cpu, &cd.drc, &built.store, null, &sink.out, &sink.runs);
    try testing.expectEqual(@as(usize, 2), sink.runs.items.len);
    for (sink.runs.items) |run| {
        try testing.expectEqual(Outcome.refused, run.outcome);
        try testing.expectEqual(@as(u64, 0), run.examined);
        try testing.expectEqual(@as(u32, 0), run.violations);
    }
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "m1 e f pick the cell by the wider line and the run" {
    // Each pair 200 apart unless noted, read against the row of the wider
    // line and the column of the run: two 200-wide lines, run 2 µm: 180,
    // clean; 400 and 200 wide, run 2 µm: 220, flagged; 400 and 200, run 800:
    // 180, clean; 300 and 200: 300 is not wider than 0.3, clean; a 12 µm plate
    // and a line 500 off it, run 11 µm: 600, flagged; a 12 µm plate with a
    // 200-wide tab 3 µm long, and a line 500 past the tab's end: only the tab
    // is near, 180 applies, clean.
    // Oracle: foundry example, IHP SG13G2 Metal1 M1.b/e/f as a spacing table,
    // each pair's cell picked by hand in the list above: two pairs flagged,
    // 200 against 220 and 500 against 600.
    var r = try runRects(ihp_m1, &.{
        .{ "met1", .{ 0, 0, 200, 2_000 } },               .{ "met1", .{ 400, 0, 600, 2_000 } },
        .{ "met1", .{ 2_000, 0, 2_400, 2_000 } },         .{ "met1", .{ 2_600, 0, 2_800, 2_000 } },
        .{ "met1", .{ 4_000, 0, 4_400, 800 } },           .{ "met1", .{ 4_600, 0, 4_800, 800 } },
        .{ "met1", .{ 6_000, 0, 6_300, 2_000 } },         .{ "met1", .{ 6_500, 0, 6_700, 2_000 } },
        .{ "met1", .{ 10_000, 0, 22_000, 12_000 } },      .{ "met1", .{ 22_500, 0, 22_700, 11_000 } },
        .{ "met1", .{ 30_000, 0, 42_000, 12_000 } },      .{ "met1", .{ 35_000, 12_000, 35_200, 15_000 } },
        .{ "met1", .{ 35_000, 15_500, 35_200, 17_000 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{ .{ len(200), len(220) }, .{ len(500), len(600) } }, try pairs(&r, "M1.bef"));
}

test "m1 s 1 to 5 pick the cell by both facing edges" {
    // ASAP7 M1.S.1 to M1.S.5 (DRM r1p7, Table 3.12.1) as one tip table. Five
    // pairs, each 26 apart, read off the table by the lengths of the two edges
    // that face each other: two 1000 nm sides, 18, clean; a 20 wide tip under
    // a 1000 wide bar, 25, clean; two 30 wide tips, 27, flagged; two 20 wide
    // tips, 31, flagged; a 30 wide tip facing a 20 wide one, 31, flagged.
    // Oracle: the ASAP7 M1.S.1 to M1.S.5 values (foundry rule),
    // construct-from-answer for the pairs.
    const deck =
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\rule M1.S tip_space_table(met1;
        \\    length: [0nm, 24nm, 37nm],
        \\    space:  [[31nm, 31nm, 25nm],
        \\             [31nm, 27nm, 25nm],
        \\             [25nm, 25nm, 18nm]])
        \\
    ;
    var r = try runRects(deck, &.{
        .{ "met1", .{ 0, 0, 100, 1_000 } },       .{ "met1", .{ 126, 0, 226, 1_000 } },
        .{ "met1", .{ 2_000, 0, 2_020, 1_000 } }, .{ "met1", .{ 1_500, 1_026, 2_500, 1_126 } },
        .{ "met1", .{ 4_000, 0, 4_030, 1_000 } }, .{ "met1", .{ 4_000, 1_026, 4_030, 2_026 } },
        .{ "met1", .{ 6_000, 0, 6_020, 1_000 } }, .{ "met1", .{ 6_000, 1_026, 6_020, 2_026 } },
        .{ "met1", .{ 8_000, 0, 8_030, 1_000 } }, .{ "met1", .{ 8_000, 1_026, 8_020, 2_026 } },
    });
    defer r.deinit();
    const got = try pairs(&r, "M1.S");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(26), len(27) }));
    try testing.expectEqual(@as(usize, 2), countOf(got, .{ len(26), len(31) }));
    try testing.expectEqual(Outcome.ran, r.row("M1.S").outcome);
}

test "an asymmetric tip table is refused at load" {
    // A tip table must be symmetric: which of two facing edges is "first" is
    // not a property of the layout, so an asymmetric table has no meaning and
    // the deck is refused when the rules are built.
    // Oracle: the kind's contract (a tip table is symmetric),
    // construct-from-answer.
    const got = try typeErr("grid 1nm\nlayer met1 = gds(68, 20)\nrule t tip_space_table(met1; length: [0nm, 24nm], space: [[31nm, 25nm], [27nm, 18nm]])\n");
    try testing.expectEqual(@as(?anyerror, error.BadTable), got[0]);
    try testing.expectEqualStrings("t", got[1]);
}

test "lef two width example gives the manual's spacings" {
    // LEF/DEF 5.8 Language Reference, "Two-Width Spacing Tables", written as
    // the manual prints it, and its four worked cases, each pair 1 nm under
    // the space the manual gives: 0.25 and 0.25, prl 0.0, 0.15; 0.25 and
    // 0.26, prl 0.0, 0.15; 0.25 and 0.26, prl 0.1, 0.20; 0.26 and 0.26, prl
    // 0.1, 0.25.
    // Oracle: LEF/DEF 5.8's own worked example (spec example).
    const deck =
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\rule tw two_width_table(met1;
        \\    width: [0um, 0.25um, 1.5um, 3um],
        \\    prl:   [none, 0um, 1.5um, 3um],
        \\    space: [[0.15um, 0.2um, 0.5um, 1um],
        \\            [0.2um, 0.25um, 0.5um, 1um],
        \\            [0.5um, 0.5um, 0.6um, 1um],
        \\            [1um, 1um, 1um, 1.2um]])
        \\
    ;
    var r = try runRects(deck, &.{
        .{ "met1", .{ 0, 0, 250, 2_000 } },         .{ "met1", .{ 399, 2_000, 649, 4_000 } },
        .{ "met1", .{ 10_000, 0, 10_250, 2_000 } }, .{ "met1", .{ 10_399, 2_000, 10_659, 4_000 } },
        .{ "met1", .{ 20_000, 0, 20_250, 2_000 } }, .{ "met1", .{ 20_449, 1_900, 20_709, 3_900 } },
        .{ "met1", .{ 30_000, 0, 30_260, 2_000 } }, .{ "met1", .{ 30_509, 1_900, 30_769, 3_900 } },
    });
    defer r.deinit();
    const got = try pairs(&r, "tw");
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqual(@as(usize, 2), countOf(got, .{ len(149), len(150) }));
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(199), len(200) }));
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(249), len(250) }));
}

test "lef example 1 18 holds the end of line within" {
    // LEF/DEF 5.8 Language Reference, Example 1-18 and Figure 1-23:
    // `SPACING 1.2 ENDOFLINE 1.3 WITHIN 0.6`. Four 1 µm lines, each with one
    // shape above: a) a bar 1.2 above, clean; b) a bar 1.0 above, flagged; c)
    // a block 0.8 above whose side is 0.5 past the end's, flagged; d) the
    // block 0.6 past, clean (within is "less than" 0.6).
    // Oracle: LEF/DEF 5.8 Example 1-18 and Figure 1-23 (spec example).
    var r = try runRects("grid 1nm\nlayer met1 = gds(68, 20)\nrule e eol_space(met1; eol_width: 1.3um, within: 0.6um, parallel: none, end_to_end: none) >= 1.2um\n", &.{
        .{ "met1", .{ 0, -5_000, 1_000, 0 } },       .{ "met1", .{ -2_000, 1_200, 3_000, 2_200 } },
        .{ "met1", .{ 10_000, -5_000, 11_000, 0 } }, .{ "met1", .{ 8_000, 1_000, 13_000, 2_000 } },
        .{ "met1", .{ 20_000, -5_000, 21_000, 0 } }, .{ "met1", .{ 21_500, 800, 23_500, 2_800 } },
        .{ "met1", .{ 30_000, -5_000, 31_000, 0 } }, .{ "met1", .{ 31_600, 800, 33_600, 2_800 } },
    });
    defer r.deinit();
    const got = try pairs(&r, "e");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(1_000), len(1_200) }));
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(800), len(1_200) }));
}

test "a forbidden range is closed at both ends" {
    // A forbidden range written as `LEF58_TWOWIRESFORBIDDENSPACING 0.10 0.15
    // PRL 0.20`, which TritonRoute reads closed on both ends with the run
    // strictly longer than 0.20. Three pairs of 1 µm bars: 99 apart (legal),
    // 100 (forbidden) and 150 (forbidden). The limit reported is the
    // narrowest legal gap above the range, 151.
    // Oracle: TritonRoute's `isForbiddenSpacing` and `isValidPrl`,
    // construct-from-answer.
    var r = try runRects("grid 1nm\nlayer met1 = gds(68, 20)\nrule fs forbidden_space(met1; min: 100nm, max: 150nm, prl: 200nm)\n", &.{
        .{ "met1", .{ 0, 0, 100, 1_000 } },       .{ "met1", .{ 199, 0, 299, 1_000 } },
        .{ "met1", .{ 2_000, 0, 2_100, 1_000 } }, .{ "met1", .{ 2_200, 0, 2_300, 1_000 } },
        .{ "met1", .{ 4_000, 0, 4_100, 1_000 } }, .{ "met1", .{ 4_250, 0, 4_350, 1_000 } },
    });
    defer r.deinit();
    const got = try pairs(&r, "fs");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(100), len(151) }));
    try testing.expectEqual(@as(usize, 1), countOf(got, .{ len(150), len(151) }));
}

test "a forbidden range that ends before it starts is refused at load" {
    // A range that ends before it starts forbids nothing a deck could mean,
    // and is refused when the rules are built.
    // Oracle: the kind's contract (min at most max), construct-from-answer.
    const got = try typeErr("grid 1nm\nlayer met1 = gds(68, 20)\nrule fs forbidden_space(met1; min: 150nm, max: 100nm, prl: 0nm)\n");
    try testing.expectEqual(@as(?anyerror, error.BadTable), got[0]);
    try testing.expectEqualStrings("fs", got[1]);
}

test "lef influence holds the stub's first micron to the wide spacing" {
    // LEF/DEF 5.8 Language Reference, "Using Spacing Rules": `SPACING 0.5
    // RANGE 2.01 2000.0 INFLUENCE 1.000`, "Stub wires <= 1.0 um from wide
    // wires >= 2.01 require 0.5 um spacing", written as one row. Two 2.01 µm
    // wires, each with a 0.2 µm stub 2 µm long, and a line 0.45 µm beside the
    // stub: the first starts beside the stub's first micron, flagged against
    // 0.5; the second beside only the stub past its first micron, clean.
    // Oracle: LEF/DEF 5.8's INFLUENCE example rule and its stated meaning
    // (spec example), distances derived by hand.
    var r = try runRects("grid 1nm\nlayer met1 = gds(68, 20)\nrule inf wide_space(met1; width: 2.01um, attached: 1um) >= 0.5um\n", &.{
        .{ "met1", .{ 0, 0, 10_000, 2_010 } },          .{ "met1", .{ 5_000, 2_010, 5_200, 4_010 } },
        .{ "met1", .{ 5_650, 2_510, 5_850, 4_000 } },   .{ "met1", .{ 20_000, 0, 30_000, 2_010 } },
        .{ "met1", .{ 25_000, 2_010, 25_200, 4_010 } }, .{ "met1", .{ 25_650, 3_260, 25_850, 4_500 } },
    });
    defer r.deinit();
    try testing.expectEqualSlices([2]Measurement, &.{.{ len(450), len(500) }}, try pairs(&r, "inf"));
}
