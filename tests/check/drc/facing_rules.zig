//! Spacing kinds read off the edges of the merged layer (`facing*.zig`),
//! and the two-width spacing table. Every case asserts what was measured,
//! the limit it was held to, the marker, and `examined`, so a table looked
//! up in the wrong cell or a pair dropped from the scan shows. Ported from
//! crates/check/tests/drc/facing_rules.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const Sink = common.Sink;
const gpa = common.gpa;
const A = common.a;
const RULE = common.rule_id;
const drc = check.drc;
const Rule = drc.Rule;
const RuleSet = drc.RuleSet;
const ClassTable = drc.tables.ClassTable;
const SpanTable = drc.tables.SpanTable;
const Measurement = check.report.Measurement;
const RuleRun = check.report.RuleRun;
const LayoutBuilder = testgen.shapes.LayoutBuilder;

/// The ASAP7 M1 table, DRM r1p7 Table 3.12.1: edges below 24 nm, from 24 to
/// 36 nm, above 36 nm; M1.S.1 18, M1.S.2 25, M1.S.3 27, M1.S.4 31, M1.S.5 31.
const asap7_m1: ClassTable = .{ .class = &.{ 0, 24, 37 }, .prl = &.{}, .space = &.{ 31, 31, 25, 31, 27, 25, 25, 25, 18 } };

const tips_rule: Rule = .{ .tip_spacing_table = .{ .layer = A, .table = 0 } };

/// A 1000 wide line ending at y = 0, so its top is an end of line.
const line = [4]i64{ 0, -5000, 1000, 0 };

/// A 7000 wide bar 1000 above the line, inside its keep-out.
const bar_above = [4]i64{ -3000, 1000, 4000, 2000 };

/// `LEF58_EOLKEEPOUT 1.3 EXTENSION 0.2 0.3 1.0` in nanometres: the line's
/// end keeps out x = -300..1300, y = -200..1000.
const keep_out: Rule = .{ .eol_keep_out = .{ .layer = A, .eol_width = 1300, .backward = 200, .side = 300, .forward = 1000, .except_within = null, .corner_only = false } };

/// LEF/DEF 5.8's two-width table ("Two-Width Spacing Tables") in
/// nanometres: widths 0, 250, 1500 and 3000 with runs none, 0, 1500, 3000.
const lef_two_widths: ClassTable = .{ .class = &.{ 0, 250, 1500, 3000 }, .prl = &.{ null, 0, 1500, 3000 }, .space = &.{ 150, 200, 500, 1000, 200, 250, 500, 1000, 500, 500, 600, 1000, 1000, 1000, 1000, 1200 } };

const two_widths: Rule = .{ .two_width_spacing_table = .{ .layer = A, .table = 0 } };

/// LEF 5.8's METAL2 span tables: horizontal spans 60, 80, 120, 160 or at
/// least 200; vertical spans 120, 160 or at least 200.
const lef_spans: Rule = .{ .span_length = .{ .layer = A, .table = 0 } };

const lef_span_table: SpanTable = .{ .x = &.{ 60, 80, 120, 160, 200 }, .y = &.{ 120, 160, 200 } };

/// ASAP7 FIN.S.1, "Exact vertical FIN pitch", 27 nm.
const fin_pitch: Rule = .{ .exact_pitch = .{ .layer = A, .vertical = true, .pitch = 27 } };

/// A forbidden range of 100 to 150 for runs longer than 200.
const forbidden: Rule = .{ .forbidden_spacing = .{ .layer = A, .min = 100, .max = 150, .prl = 200 } };

// ---- private ----

/// Runs `rule` alone over rectangles on layer A, with `class_tables` and
/// `span_tables` for a table kind.
fn go(rects: []const [4]i64, rule: Rule, class_tables: []const ClassTable, span_tables: []const SpanTable) !Sink {
    var lb = LayoutBuilder.init(1);
    for (rects) |r| _ = try lb.rect(gpa, 0, r[0], r[1], r[2], r[3]);
    var built = try common.finish(&lb);
    defer built.deinit();
    return runOn(&built.store, &.{rule}, class_tables, span_tables);
}

fn runOn(store: *const geom.GeometryStore, rules: []const Rule, class_tables: []const ClassTable, span_tables: []const SpanTable) !Sink {
    var set: RuleSet = .{};
    defer set.deinit(gpa);
    for (class_tables) |t| _ = try set.addClassTable(gpa, t);
    for (span_tables) |t| _ = try set.addSpanTable(gpa, t);
    for (rules) |r| try set.push(gpa, RULE, r, .@"error");
    var sink: Sink = .{};
    errdefer sink.deinit();
    try drc.run(gpa, .cpu, null, &set, store, null, &sink.out, &sink.runs);
    return sink;
}

/// The findings' measured lengths, in output order.
fn expectLengths(s: *const Sink, want: []const i64) !void {
    try testing.expectEqual(want.len, s.out.len());
    for (want, 0..) |w, k| try testing.expectEqual(Measurement.length(w), s.out.get(@intCast(k)).measured);
}

fn expectLimits(s: *const Sink, want: []const i64) !void {
    try testing.expectEqual(want.len, s.out.len());
    for (want, 0..) |w, k| try testing.expectEqual(Measurement.length(w), s.out.get(@intCast(k)).limit);
}

fn expectAreas(s: *const Sink, want: []const i128) !void {
    try testing.expectEqual(want.len, s.out.len());
    for (want, 0..) |w, k| try testing.expectEqual(Measurement.area(w), s.out.get(@intCast(k)).measured);
}

fn expectAt(s: *const Sink, want: []const [2]i64) !void {
    try testing.expectEqual(want.len, s.out.len());
    for (want, 0..) |w, k| {
        const at = s.out.get(@intCast(k)).at;
        try testing.expectEqual(w, [2]i64{ at.x, at.y });
    }
}

fn examined(s: *const Sink) !u64 {
    return (try testgen.assertRuleRan(s.runs.items, RULE)).examined;
}

/// The one rule's run row, whatever it examined.
fn only(s: *const Sink) !RuleRun {
    try testing.expectEqual(@as(usize, 1), s.runs.items.len);
    return s.runs.items[0];
}

fn expectClean(s: *const Sink) !void {
    try testing.expectEqual(@as(u32, 0), s.out.len());
}

/// Two lines `wa` and `wb` wide, tip to tip `gap` apart.
fn tips(wa: i64, wb: i64, gap: i64) [2][4]i64 {
    return .{ .{ 0, 0, wa, 1000 }, .{ 0, 1000 + gap, wb, 2000 + gap } };
}

/// Two 1000 long bars `gap` apart.
fn bars(gap: i64) [2][4]i64 {
    return .{ .{ 0, 0, 100, 1000 }, .{ 100 + gap, 0, 200 + gap, 1000 } };
}

/// LEF/DEF 5.8 Example 1-18 in nanometres: `SPACING 1.2 ENDOFLINE 1.3
/// WITHIN 0.6`, with `parallel` and `end_to_end`.
fn lefEol(parallel: ?drc.rows.EolParallel, end_to_end: ?i64) Rule {
    return .{ .eol_within_spacing = .{ .layer = A, .eol_width = 1300, .within = 600, .parallel = parallel, .end_to_end = end_to_end, .limit = 1200 } };
}

/// `PARALLELEDGE 1.1 WITHIN 0.5`, with or without `TWOEDGES`.
fn parallelEdge(two_edges: bool) drc.rows.EolParallel {
    return .{ .space = 1100, .within = 500, .two_edges = two_edges };
}

/// LEF/DEF 5.7's example (p. 170) in nanometres: `EOLEXTENSIONSPACING 0.1
/// ENDOFLINE 0.11 EXTENSION 0.14 ENDOFLINE 0.15 EXTENSION 0.12 ENDTOEND
/// 0.13`, with `MINLENGTH side_length`.
fn extensionRule(side_length: ?drc.rows.SideLengthTwo) Rule {
    return .{ .eol_extension_spacing = .{ .layer = A, .rows = .{ .{ .eol_width = 110, .extension = 140, .end_to_end = null }, .{ .eol_width = 150, .extension = 120, .end_to_end = 130 }, null }, .side_length = side_length, .limit = 100 } };
}

/// A line `w` wide whose top end is at y = 0, x = 0..w.
fn upLine(w: i64) [4]i64 {
    return .{ 0, -2000, w, 0 };
}

/// A 500 tall bar across x = -1000..1100 whose bottom is `g` above y = 0:
/// no edge of it is an end of line.
fn bar(g: i64) [4]i64 {
    return .{ -1000, g, 1100, g + 500 };
}

/// Lines `wa` and `wb` wide, `gap` apart, running alongside for `run`.
fn lines(wa: i64, wb: i64, gap: i64, run: i64) [2][4]i64 {
    return .{ .{ 0, 0, wa, 2000 }, .{ wa + gap, 2000 - run, wa + gap + wb, 4000 - run } };
}

fn corners(corner_to_corner: bool, except_eol: ?i64) Rule {
    return .{ .convex_corner_spacing = .{ .layer = A, .corner_to_corner = corner_to_corner, .except_eol = except_eol, .limit = 101 } };
}

/// Three 7 nm fins `p` apart.
fn fins(p: i64) [3][4]i64 {
    return .{ .{ 0, 0, 1000, 7 }, .{ 0, p, 1000, p + 7 }, .{ 0, 2 * p, 1000, 2 * p + 7 } };
}

/// A deck on a 1 nm grid with layer `met1`, compiled.
fn compileDeck(text: []const u8, strings: *geom.StrTable, diag: *check.deck.compile.Diag, arena: std.mem.Allocator) !check.deck.compile.CompiledDeck {
    return check.deck.compile.compile(gpa, arena, text, try geom.Grid.init(1000), strings, diag);
}

/// A triangle on layer A, which no rectilinear kind can read.
fn triangle() !common.Built {
    var lb = LayoutBuilder.init(1);
    _ = try lb.push(gpa, 0, &.{ 0, 100, 0 }, &.{ 0, 0, 100 });
    return common.finish(&lb);
}

// -------------------------------------------------------- tip_spacing_table

test "tips one unit inside their cell are reported with that cell" {
    // Oracle: ASAP7 M1.S.3, two tips 24 to 36 nm wide need 27; construct
    // from answer for the marker, the middle of the 30-wide stretch the two
    // ends face each other over, (15, (1000 + 1026) / 2). A lookup in any
    // other cell reads 31, 25 or 18.
    var s = try go(&tips(30, 30, 26), tips_rule, &.{asap7_m1}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{26});
    try expectLimits(&s, &.{27});
    try expectAt(&s, &.{.{ 15, 1013 }});
    try testing.expect(s.out.get(0).shape_b != check.report.no_shape);
    try testing.expectEqual(@as(u64, 1), try examined(&s));
}

test "tips exactly at their cell are clean and still examined" {
    // Oracle: construct-from-answer. A gap exactly at its cell meets the
    // rule; the facing pair was still examined.
    var s = try go(&tips(30, 30, 27), tips_rule, &.{asap7_m1}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(@as(u64, 1), try examined(&s));
}

test "the last threshold a length reaches picks its class" {
    // Oracle: ASAP7 M1.S.3 against M1.S.4. A 24 wide tip reaches the 24 nm
    // threshold, so it is in the middle class and 26 apart breaks 27; a 23
    // wide one is below it and breaks 31. Classing by "exceeds" would put
    // 24 in the first class too.
    var s = try go(&.{ .{ 0, 0, 24, 1000 }, .{ 0, 1026, 24, 2026 }, .{ 5000, 0, 5023, 1000 }, .{ 5000, 1026, 5023, 2026 } }, tips_rule, &.{asap7_m1}, &.{});
    defer s.deinit();
    try testing.expectEqual(@as(u32, 2), s.out.len());
    var limits: [2]i128 = .{ s.out.get(0).limit.exact(), s.out.get(1).limit.exact() };
    std.mem.sortUnstable(i128, &limits, {}, std.sort.asc(i128));
    try testing.expectEqual([2]i128{ 27, 31 }, limits);
    for (0..2) |k| try testing.expectEqual(Measurement.length(26), s.out.get(@intCast(k)).measured);
}

test "edges meeting only at a point do not face" {
    // Oracle: construct-from-answer. Two tips whose spans meet only at the
    // point x = 30 do not face each other: their gap is diagonal, a corner
    // rule's. A scan accepting a zero-length overlap would hold them to 31.
    var s = try go(&.{ .{ 0, 0, 30, 1000 }, .{ 30, 1010, 60, 2000 } }, tips_rule, &.{asap7_m1}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(check.report.Outcome.ran, (try only(&s)).outcome);
    try testing.expectEqual(@as(u64, 0), (try only(&s)).examined);
}

test "the scan reaches one unit inside the widest cell" {
    // Oracle: construct-from-answer at the scan's reach. Two 20 wide tips
    // need 31, the table's widest cell: 30 apart is the farthest pair that
    // can fail and is examined and reported; 31 apart cannot fail and is not
    // examined.
    var s = try go(&tips(20, 20, 30), tips_rule, &.{asap7_m1}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{30});
    try expectLimits(&s, &.{31});
    try testing.expectEqual(@as(u64, 1), try examined(&s));
    var t = try go(&tips(20, 20, 31), tips_rule, &.{asap7_m1}, &.{});
    defer t.deinit();
    try expectClean(&t);
    try testing.expectEqual(@as(u64, 0), (try only(&t)).examined);
}

test "the nearer of two offending steps is the finding" {
    // Oracle: construct-from-answer. A bar's side faces one figure along two
    // steps, 15 apart over y = 0..400 and 10 apart over y = 400..1000; both
    // break M1.S.1's 18. One finding for the pair of figures, the nearer
    // step, marked in its middle (105, 700).
    var s = try go(&.{ .{ 0, 0, 100, 1000 }, .{ 115, 0, 215, 400 }, .{ 110, 400, 210, 1000 } }, tips_rule, &.{asap7_m1}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{10});
    try expectLimits(&s, &.{18});
    try expectAt(&s, &.{.{ 105, 700 }});
    try testing.expectEqual(@as(u64, 2), try examined(&s));
}

// -------------------------------------------------------- forbidden_spacing

test "both ends of the range are forbidden and one step out is legal" {
    // Oracle: `TritonRoute`'s `isForbiddenSpacing`, a closed range. Both
    // ends of it are forbidden and reported against the narrowest legal gap
    // above it, 151, at the middle of the gap; one step outside either end
    // is legal though still examined.
    for ([_]struct { i64, bool }{ .{ 99, false }, .{ 100, true }, .{ 150, true }, .{ 151, false } }) |cs| {
        const gap = cs[0];
        var s = try go(&bars(gap), forbidden, &.{}, &.{});
        defer s.deinit();
        if (cs[1]) {
            try expectLengths(&s, &.{gap});
            try expectLimits(&s, &.{151});
            try expectAt(&s, &.{.{ @divFloor(200 + gap, 2), 500 }});
        } else try expectClean(&s);
        try testing.expectEqual(@as(u64, @intFromBool(gap <= 150)), (try only(&s)).examined);
    }
}

test "a run must be longer than prl" {
    // Oracle: `TritonRoute`'s `isValidPrl`, a run strictly longer than
    // `prl`. Two bars 120 apart overlapping by 200 are not judged at all; by
    // 201 they are, and fail.
    var s = try go(&.{ .{ 0, 0, 100, 1000 }, .{ 220, 800, 320, 1800 } }, forbidden, &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(@as(u64, 0), (try only(&s)).examined);
    var t = try go(&.{ .{ 0, 0, 100, 1000 }, .{ 220, 799, 320, 1799 } }, forbidden, &.{}, &.{});
    defer t.deinit();
    try expectLengths(&t, &.{120});
    try testing.expectEqual(@as(u64, 1), (try only(&t)).examined);
}

test "a narrower legal gap does not hide a forbidden one" {
    // Oracle: construct-from-answer. A figure faces a bar 90 away along one
    // step (below the range: legal) and 130 along another (forbidden): the
    // finding is the forbidden 130, marked in the middle of its stretch
    // (165, 700), not the nearer legal gap.
    var s = try go(&.{ .{ 0, 0, 100, 1000 }, .{ 190, 0, 290, 400 }, .{ 230, 400, 330, 1000 } }, forbidden, &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{130});
    try expectAt(&s, &.{.{ 165, 700 }});
    try testing.expectEqual(@as(u64, 2), try examined(&s));
}

// ------------------------------------------------------- eol_within_spacing

test "a facing edge inside the keep out fails by its depth" {
    // Oracle: LEF 5.8 Figure 1-23 b, construct-from-answer for the marker. A
    // bar 1199 above the end is one unit inside the keep-out: depth 1199,
    // marked over the end widened by 600, x = -600..1600, midway up the gap.
    // The line's two ends and the bar's two 1000 long sides are the ends of
    // line examined.
    var s = try go(&.{ line, .{ -2000, 1199, 3000, 2199 } }, lefEol(null, null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{1199});
    try expectLimits(&s, &.{1200});
    try expectAt(&s, &.{.{ 500, 599 }});
    try testing.expectEqual(@as(u64, 4), try examined(&s));
    var t = try go(&.{ line, .{ -2000, 1200, 3000, 2200 } }, lefEol(null, null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "the keep out reaches less than within past the end" {
    // Oracle: LEF 5.8 Figure 1-23 c and d, "within (that is, less than)
    // eolWithin". A square 300 above whose side lies 599 past the end's side
    // is in the keep-out; 600 past it is not.
    var s = try go(&.{ line, .{ 1599, 300, 3599, 2300 } }, lefEol(null, null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{300});
    var t = try go(&.{ line, .{ 1600, 300, 3600, 2300 } }, lefEol(null, null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "an edge with a concave corner is no end" {
    // Oracle: `TritonRoute`'s end of line, both corners convex. A tab's side
    // is 1000 long but meets its base at a concave corner, so it is no end:
    // the wide shape 500 beside it is clean, and only the tab's top is
    // examined.
    var s = try go(&.{ .{ -3000, -5000, 4000, -1000 }, .{ 0, -1000, 1000, 0 }, .{ -3000, -900, -500, 3000 } }, lefEol(null, null), &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(@as(u64, 1), try examined(&s));
}

test "a parallel edge beside the line triggers the rule" {
    // Oracle: LEF 5.8 Figure 1-24, `PARALLELEDGE 1.1 WITHIN 0.5`. The bar
    // 1000 above fails only when a neighbour runs beside the line less than
    // 1100 from its side (1099 does, 1100 does not), with its top reaching
    // less than 500 behind the end's line (-499 does, -500 does not).
    const rule = lefEol(parallelEdge(false), null);
    for ([_]struct { [4]i64, bool }{
        .{ .{ -3099, -5000, -1099, 0 }, true },
        .{ .{ -3100, -5000, -1100, 0 }, false },
        .{ .{ -2500, -5000, -500, -499 }, true },
        .{ .{ -2500, -5000, -500, -500 }, false },
    }) |cs| {
        var s = try go(&.{ line, bar_above, cs[0] }, rule, &.{}, &.{});
        defer s.deinit();
        if (cs[1]) try expectLengths(&s, &.{1000}) else try expectClean(&s);
    }
    var s = try go(&.{ line, bar_above }, rule, &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
}

test "two edges needs a parallel edge on both sides" {
    // Oracle: LEF 5.8 Figure 1-19, `TWOEDGES`. One neighbour beside the line
    // is not enough; one on each side is.
    const rule = lefEol(parallelEdge(true), null);
    const left = [4]i64{ -2500, -5000, -500, 0 };
    const right = [4]i64{ 1500, -5000, 3500, 0 };
    var s = try go(&.{ line, bar_above, left }, rule, &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
    var t = try go(&.{ line, bar_above, left, right }, rule, &.{}, &.{});
    defer t.deinit();
    try expectLengths(&t, &.{1000});
}

test "two ends facing each other need the end to end space" {
    // Oracle: `LEF58_SPACING ENDOFLINE ... ENDTOEND`, construct-from-answer.
    // Two ends of line 1399 apart need the end-to-end 1400; an end 1300
    // below a wide bar (no end) needs only 1200.
    const rule = lefEol(null, 1400);
    var s = try go(&.{ line, .{ 0, 1399, 1000, 6399 } }, rule, &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{1399});
    try expectLimits(&s, &.{1400});
    var t = try go(&.{ line, .{ -2000, 1300, 3000, 2300 } }, rule, &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

// -------------------------------------------------------------- eol_keep_out

test "a shape one unit inside the far side of the box is reported by area" {
    // Oracle: construct-from-answer, the box as `TritonRoute`'s
    // `getEolKeepOutQueryBox` builds it. A bar whose bottom is 999 past the
    // end overlaps the box by 1600 x 1, marked at the centre of that strip,
    // (500, 999) floored; at 1000 it only touches the box. The line's two
    // ends and the bar's two 500 long sides are the ends examined.
    var s = try go(&.{ line, .{ -2000, 999, 3000, 1499 } }, keep_out, &.{}, &.{});
    defer s.deinit();
    try expectAreas(&s, &.{1600});
    try testing.expectEqual(Measurement.area(0), s.out.get(0).limit);
    try expectAt(&s, &.{.{ 500, 999 }});
    try testing.expectEqual(@as(u64, 4), try examined(&s));
    var t = try go(&.{ line, .{ -2000, 1000, 3000, 1500 } }, keep_out, &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "the box reaches side past the end and backward behind it" {
    // Oracle: construct-from-answer at the box's side and back. A block 299
    // past the end's side overlaps it by 1 x 500, at 300 it touches; a block
    // beside the line whose top is 199 behind the end overlaps by 200 x 1,
    // at 200 behind it touches.
    for ([_]struct { [4]i64, ?i128 }{
        .{ .{ 1299, 500, 3299, 2500 }, 500 },
        .{ .{ 1300, 500, 3300, 2500 }, null },
        .{ .{ 1100, -2199, 3100, -199 }, 200 },
        .{ .{ 1100, -2200, 3100, -200 }, null },
    }) |cs| {
        var s = try go(&.{ line, cs[0] }, keep_out, &.{}, &.{});
        defer s.deinit();
        if (cs[1]) |a| try expectAreas(&s, &.{a}) else try expectClean(&s);
    }
}

test "each intruding figure is one finding" {
    // Oracle: construct-from-answer. One finding per intruding figure: two
    // blocks are two (500 x 700 and 600 x 700), a bar drawn as two
    // rectangles is one with the summed 1600 x 500, and the line's own
    // figure turning back into the box is none.
    var s = try go(&.{ line, .{ -2000, 300, 200, 1800 }, .{ 700, 300, 2500, 1800 } }, keep_out, &.{}, &.{});
    defer s.deinit();
    try testing.expectEqual(@as(u32, 2), s.out.len());
    var areas: [2]i128 = .{ s.out.get(0).measured.exact(), s.out.get(1).measured.exact() };
    std.mem.sortUnstable(i128, &areas, {}, std.sort.asc(i128));
    try testing.expectEqual([2]i128{ 350_000, 420_000 }, areas);
    var t = try go(&.{ line, .{ -2000, 500, 500, 1500 }, .{ 500, 500, 3000, 1500 } }, keep_out, &.{}, &.{});
    defer t.deinit();
    try expectAreas(&t, &.{800_000});
    var u = try go(&.{ line, .{ 0, -6000, 3000, -5000 }, .{ 2000, -6000, 3000, 1100 }, .{ -500, 600, 3000, 1100 } }, keep_out, &.{}, &.{});
    defer u.deinit();
    try expectClean(&u);
}

// ------------------------------------------------------ eol_extension_spacing

test "figure 1 73 a a narrow end is swept by its row's extension" {
    // Oracle: LEF 5.7 Figure 1-73 a, construct-from-answer. A 100 wide end
    // (below 0.11) swept 140 needs 100 past that: a bar 239 above it is 99
    // away, marked midway across the 99 gap over the end, (50, (140 + 239) /
    // 2) floored; at 240 it is clean. The line's two ends are examined.
    var s = try go(&.{ upLine(100), bar(239) }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{99});
    try expectLimits(&s, &.{100});
    try expectAt(&s, &.{.{ 50, 189 }});
    try testing.expect(s.out.get(0).shape_b != check.report.no_shape);
    try testing.expectEqual(@as(u64, 2), try examined(&s));
    var t = try go(&.{ upLine(100), bar(240) }, extensionRule(null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "each end takes the first row wider than it" {
    // Oracle: LEF 5.7 ("find the last row where the width is less than
    // eolWidth"), construct-from-answer. An end below 110 is swept 140, so a
    // bar fails below 240; from 110 to below 150 it is swept 120 and fails
    // below 220; an edge of 150, the largest width, is no end at all, so a
    // bar 1 away is clean and nothing is examined.
    for ([_][2]i64{ .{ 109, 140 }, .{ 110, 120 }, .{ 149, 120 } }) |cs| {
        var s = try go(&.{ upLine(cs[0]), bar(cs[1] + 99) }, extensionRule(null), &.{}, &.{});
        defer s.deinit();
        try expectLengths(&s, &.{99});
        var t = try go(&.{ upLine(cs[0]), bar(cs[1] + 100) }, extensionRule(null), &.{}, &.{});
        defer t.deinit();
        try expectClean(&t);
    }
    var s = try go(&.{ upLine(150), bar(1) }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(check.report.Outcome.ran, (try only(&s)).outcome);
    try testing.expectEqual(@as(u64, 0), (try only(&s)).examined);
}

test "figure 1 73 b end to end each end takes its own row" {
    // Oracle: LEF 5.7 Figure 1-73 b, construct-from-answer. End to end, a
    // 100 wide end (no `ENDTOEND` on its row: 140) faces a 120 wide one
    // (`ENDTOEND` 130): 369 apart, the boxes are 369 - 140 - 130 = 99 apart,
    // found from each end, both marked at (50, (140 + 239) / 2) floored; 370
    // apart is clean. `TritonRoute`'s 120 for the second end would pass 369.
    var s = try go(&.{ upLine(100), .{ 0, 369, 120, 2369 } }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{ 99, 99 });
    try expectAt(&s, &.{ .{ 50, 189 }, .{ 50, 189 } });
    try testing.expectEqual(@as(u64, 4), try examined(&s));
    var t = try go(&.{ upLine(100), .{ 0, 370, 120, 2370 } }, extensionRule(null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "figure 1 73 c end to end both take end to end" {
    // Oracle: LEF 5.7 Figure 1-73 c, construct-from-answer. Two 120 wide
    // ends end to end are each swept 130: 359 apart they are 99 apart,
    // marked at (60, (130 + 229) / 2) floored; 360 apart is clean
    // (`EXTENSION` alone would need only 340).
    var s = try go(&.{ upLine(120), .{ 0, 359, 120, 2359 } }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{ 99, 99 });
    try expectAt(&s, &.{ .{ 60, 179 }, .{ 60, 179 } });
    var t = try go(&.{ upLine(120), .{ 0, 360, 120, 2360 } }, extensionRule(null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "figure 1 73 d end to side takes the extension" {
    // Oracle: LEF 5.7 Figure 1-73 d, construct-from-answer on a 60-80-100
    // triangle. A 120 wide end beside a wire (not an end) is swept 120, end
    // to side: the wire's corner 60 right of it and 199 above its line is
    // sqrt(60^2 + 79^2) = 99.2 from the box, reported floored as 99 at
    // ((120 + 180) / 2, (120 + 199) / 2) floored; 200 above is exactly 100
    // and clean (an `ENDTOEND` 130 sweep would still fail there).
    var s = try go(&.{ upLine(120), .{ 180, 199, 680, 2199 } }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{99});
    try expectAt(&s, &.{.{ 150, 159 }});
    try testing.expectEqual(@as(u64, 2), try examined(&s));
    var t = try go(&.{ upLine(120), .{ 180, 200, 680, 2200 } }, extensionRule(null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
}

test "a short edge with a concave corner is no end" {
    // Oracle: the end-of-line definition (both corners convex). A 100 long
    // step whose inner corner is concave is no end: a bar 1 above it is
    // clean and nothing is examined (the figure's other edges are 200 or
    // longer).
    var s = try go(&.{ .{ 0, -2000, 200, 0 }, .{ 0, -2000, 300, -500 }, .{ 250, -499, 1250, 1 } }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(check.report.Outcome.ran, (try only(&s)).outcome);
    try testing.expectEqual(@as(u64, 0), (try only(&s)).examined);
}

test "min length and two sides gate the end" {
    // Oracle: LEF 5.7 `MINLENGTH minLength [TWOSIDES]`: "the rule does not
    // apply if the end-of-line length is less than minLength along both
    // sides", and with `TWOSIDES` "along any one side". The end's sides are
    // 2000 and 300 long (a foot meets its right side 300 below it); a bar
    // 239 above fails only where the rule applies.
    for ([_]struct { i64, bool, bool }{ .{ 1000, false, true }, .{ 2001, false, false }, .{ 300, true, true }, .{ 301, true, false } }) |cs| {
        var s = try go(&.{ upLine(100), .{ 100, -2000, 600, -300 }, bar(239) }, extensionRule(.{ .length = cs[0], .two_sides = cs[1] }), &.{}, &.{});
        defer s.deinit();
        try testing.expectEqual(@as(u32, @intFromBool(cs[2])), s.out.len());
        try testing.expectEqual(@as(u64, @intFromBool(cs[2])), (try only(&s)).examined);
    }
}

test "a neighbour behind the end's line is not checked" {
    // Oracle: `TritonRoute`'s query region (`getMetalEolExtQueryRegion`, no
    // reach behind the end's line, and `segIntersect`'s strict overlap). A
    // block 50 beside the swept end whose top is on the end's line is not a
    // neighbour; 1 above it, its side reaches past the line and is 50 away.
    for ([_]i64{ -1, 0 }) |top| {
        var s = try go(&.{ upLine(100), .{ 150, top - 1000, 1150, top } }, extensionRule(null), &.{}, &.{});
        defer s.deinit();
        try expectClean(&s);
    }
    var s = try go(&.{ upLine(100), .{ 150, -999, 1150, 1 } }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{50});
}

test "the end's own figure is no neighbour" {
    // Oracle: the kind's contract (other figures only). The line's own
    // figure hooking back 200 above its end, 60 from the box, is not a
    // neighbour.
    var s = try go(&.{ upLine(100), .{ 100, -2000, 1100, -1500 }, .{ 1000, -1500, 1100, 300 }, .{ -1000, 200, 1100, 300 } }, extensionRule(null), &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
}

test "extension rows are at most three and rise" {
    // Oracle: LEF 5.7 ("at the most three statements", "eolWidth values
    // should be increased"). The deck refuses a fourth row and widths that
    // do not rise, naming the rule's line; a rule built in code with its
    // widths out of order is a bad table.
    for ([_][2][]const u8{
        .{ "eol_width: [10nm, 20nm, 30nm, 40nm], extension: [1nm, 1nm, 1nm, 1nm], end_to_end: [none, none, none, none]", "at most three rows" },
        .{ "eol_width: [150nm, 110nm], extension: [140nm, 120nm], end_to_end: [none, 130nm]", "`eol_width` must rise strictly" },
        .{ "eol_width: [110nm, 150nm], extension: [140nm], end_to_end: [none, 130nm]", "one entry per `eol_width`" },
    }) |cs| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const text = try std.fmt.allocPrint(arena.allocator(), "grid 1nm\nlayer met1 = gds(68, 20)\nrule t eol_extension_space(met1; {s}, side_length: none) >= 100nm\n", .{cs[0]});
        var strings: geom.StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: check.deck.compile.Diag = .{};
        try testing.expectError(error.Invalid, compileDeck(text, &strings, &diag, arena.allocator()));
        var hit = false;
        for (diag.deck.diagnostics) |d| hit = hit or (d.line == 3 and std.mem.indexOf(u8, d.message, cs[1]) != null);
        if (!hit) for (diag.deck.diagnostics) |d| std.debug.print("{d}: {s}\n", .{ d.line, d.message });
        try testing.expect(hit);
    }
    var rule = extensionRule(null);
    std.mem.swap(?drc.rows.EolExtension, &rule.eol_extension_spacing.rows[0], &rule.eol_extension_spacing.rows[1]);
    var rs: RuleSet = .{};
    defer rs.deinit(gpa);
    var diag: drc.params.Diagnostic = .{};
    try testing.expectError(error.BadTable, drc.validate.validate(RULE, rule, &rs, &diag));
}

test "the deck spells extension rows" {
    // Oracle: the deck spelling in docs/src/reference/drc/spacing.md (DRC-030),
    // one list element per row, `none` for a row without `ENDTOEND`.
    const text = "grid 1nm\nlayer met1 = gds(68, 20)\n" ++
        "rule t eol_extension_space(met1; eol_width: [110nm, 150nm], extension: [140nm, 120nm], " ++
        "end_to_end: [none, 130nm], side_length: (length: 300nm, two_sides: true)) >= 100nm\n";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    var deck = try compileDeck(text, &strings, &diag, arena.allocator());
    defer deck.deinit(gpa);
    try testing.expectEqualDeep(extensionRule(.{ .length = 300, .two_sides = true }), deck.drc.get(0));
}

// --------------------------------------------------- two_width_spacing_table

test "lef's worked example picks each cell" {
    // Oracle: LEF 5.8's worked example, verbatim: "If width1 = 0.25, width2
    // = 0.25, and prl = 0.0, then spacing = 0.15. If width1 = 0.25, width2 =
    // 0.26, and prl = 0.0, then spacing = 0.15. If width1 = 0.25, width2 =
    // 0.26, and prl = 0.1, then spacing = 0.20. If width1 = 0.26, width2 =
    // 0.26, and prl = 0.1, then spacing = 0.25." Each pair one unit under
    // its space reports that space as its limit.
    for ([_][4]i64{ .{ 250, 250, 0, 150 }, .{ 250, 260, 0, 150 }, .{ 250, 260, 100, 200 }, .{ 260, 260, 100, 250 } }) |cs| {
        var s = try go(&lines(cs[0], cs[1], cs[3] - 1, cs[2]), two_widths, &.{lef_two_widths}, &.{});
        defer s.deinit();
        try expectLengths(&s, &.{cs[3] - 1});
        try expectLimits(&s, &.{cs[3]});
        try testing.expectEqual(@as(u64, 1), try examined(&s));
        var t = try go(&lines(cs[0], cs[1], cs[3], cs[2]), two_widths, &.{lef_two_widths}, &.{});
        defer t.deinit();
        try expectClean(&t);
    }
}

test "a width's run must be exceeded" {
    // Oracle: construct-from-answer. Two 1600 wide plates 550 apart need 600
    // only when they run alongside for more than the 1500 width's run: at
    // 1500 they are held to 250 and pass; at 1501 they fail 600, marked in
    // the middle of the 1501 run.
    var s = try go(&.{ .{ 0, 0, 1600, 3000 }, .{ 2150, 1500, 3750, 4500 } }, two_widths, &.{lef_two_widths}, &.{});
    defer s.deinit();
    try expectClean(&s);
    var t = try go(&.{ .{ 0, 0, 1600, 3000 }, .{ 2150, 1499, 3750, 4499 } }, two_widths, &.{lef_two_widths}, &.{});
    defer t.deinit();
    try expectLengths(&t, &.{550});
    try expectLimits(&t, &.{600});
    try expectAt(&t, &.{.{ 1875, 2249 }});
}

test "a thin tab of a wide plate is held as thin" {
    // Oracle: construct-from-answer. A 260 wide line 220 from the 100 wide
    // tab of a 2 µm plate: the tab is not wider than 250, the plate is 500
    // away, so every cell passes (a whole-shape width would hold the tab to
    // 250). Both rows of the plate's figure pair with the line.
    var s = try go(&.{ .{ 0, 0, 2000, 2000 }, .{ 900, 2000, 1000, 3000 }, .{ 1220, 2500, 1480, 4000 } }, two_widths, &.{lef_two_widths}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(@as(u64, 2), try examined(&s));
}

// ---------------------------------------------------------------- span_length

test "a span is legal exactly on the list or past its last" {
    // Oracle: `LEF58_SPANLENGTHTABLE`, "all of the given span lengths are
    // exact values, except for the last one, which is greater than equal to
    // the value". A vertical wire 61 wide is between 60 and 80 and reports
    // 80 as the shortest legal span above it, at the wire's centre; 59
    // reports 60; 60 and 201 are legal.
    var s = try go(&.{.{ 0, 0, 61, 1000 }}, lef_spans, &.{}, &.{lef_span_table});
    defer s.deinit();
    try expectLengths(&s, &.{61});
    try expectLimits(&s, &.{80});
    try expectAt(&s, &.{.{ 30, 500 }});
    try testing.expectEqual(@as(u64, 2), try examined(&s));
    var t = try go(&.{.{ 0, 0, 59, 1000 }}, lef_spans, &.{}, &.{lef_span_table});
    defer t.deinit();
    try expectLimits(&t, &.{60});
    for ([_]i64{ 60, 201 }) |w| {
        var u = try go(&.{.{ 0, 0, w, 1000 }}, lef_spans, &.{}, &.{lef_span_table});
        defer u.deinit();
        try expectClean(&u);
    }
}

test "a chord that stays the same is one region" {
    // Oracle: construct-from-answer. A U whose right arm steps from 100 to
    // 150 wide: the left arm's 100 is one region from y = 100 to 1000 though
    // the step splits the lines at y = 500, and the base's 100 one region
    // from x = 100 to 900 though the step splits it at x = 850. Four
    // findings over the eight regions of unchanged chord.
    var s = try go(&.{ .{ 0, 0, 1000, 100 }, .{ 0, 0, 100, 1000 }, .{ 900, 0, 1000, 500 }, .{ 850, 500, 1000, 1000 } }, lef_spans, &.{}, &.{lef_span_table});
    defer s.deinit();
    const F = [3]i128;
    var found: [4]F = undefined;
    try testing.expectEqual(@as(u32, 4), s.out.len());
    for (&found, 0..) |*f, k| {
        const v = s.out.get(@intCast(k));
        f.* = .{ v.at.x, v.at.y, v.measured.exact() };
    }
    std.mem.sortUnstable(F, &found, {}, struct {
        fn less(_: void, p: F, q: F) bool {
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    }.less);
    try testing.expectEqual([4]F{ .{ 50, 550, 100 }, .{ 500, 50, 100 }, .{ 925, 750, 150 }, .{ 950, 300, 100 } }, found);
    try testing.expectEqual(@as(u64, 8), try examined(&s));
}

// ---------------------------------------------------- convex_corner_spacing

test "the corner distance is the larger axis gap or euclidean" {
    // Oracle: `TritonRoute`'s `maxXY`, the longer side of the box between
    // two facing corners. Corners 100 apart on x and 50 on y are 100 apart
    // by the larger gap, under 101, marked midway (1050, 1025); Euclidean
    // they are 111.8 apart and clean. Two squares 71 apart on both axes are
    // 71 by the larger gap and 100.4, floored to 100, Euclidean.
    const skewed = [_][4]i64{ .{ 0, 0, 1000, 1000 }, .{ 1100, 1050, 2100, 2050 } };
    var s = try go(&skewed, corners(false, null), &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{100});
    try expectLimits(&s, &.{101});
    try expectAt(&s, &.{.{ 1050, 1025 }});
    try testing.expectEqual(@as(u64, 1), try examined(&s));
    var t = try go(&skewed, corners(true, null), &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
    const diagonal = [_][4]i64{ .{ 0, 0, 1000, 1000 }, .{ 1071, 1071, 2071, 2071 } };
    var u = try go(&diagonal, corners(false, null), &.{}, &.{});
    defer u.deinit();
    try expectLengths(&u, &.{71});
    var v = try go(&diagonal, corners(true, null), &.{}, &.{});
    defer v.deinit();
    try expectLengths(&v, &.{100});
}

test "an end of line's corners are exempt on either shape" {
    // Oracle: `LEF58_CORNERSPACING ... EXCEPTEOL eolWidth`, as `TritonRoute`
    // skips a corner on an edge shorter than `eolWidth` whose corners are
    // both convex, on either shape. A 100 wide line end's corner 50 from a
    // square's is exempt with `except_eol: 200`, whichever shape the line
    // is; two squares' corners are not, and neither is the line's without
    // the exception.
    const line_first = [_][4]i64{ .{ 0, 0, 100, 1000 }, .{ 150, 1050, 1150, 2050 } };
    const line_second = [_][4]i64{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 1150, 2050 } };
    const squares = [_][4]i64{ .{ 0, 0, 1000, 1000 }, .{ 1050, 1050, 2050, 2050 } };
    const with = corners(false, 200);
    var s = try go(&line_first, with, &.{}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(@as(u64, 0), (try only(&s)).examined);
    var t = try go(&line_second, with, &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
    var u = try go(&squares, with, &.{}, &.{});
    defer u.deinit();
    try expectLengths(&u, &.{50});
    var v = try go(&line_first, corners(false, null), &.{}, &.{});
    defer v.deinit();
    try expectLengths(&v, &.{50});
}

// ---------------------------------------------------------------- exact_pitch

test "neighbouring fins off the pitch are reported once per pair" {
    // Oracle: ASAP7 FIN.S.1, construct-from-answer for the markers. Fins 26
    // apart are off the 27 pitch twice, each pair marked in the middle of
    // its gap; at 27 they are clean. Both neighbouring pairs are examined
    // either way.
    var s = try go(&fins(26), fin_pitch, &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{ 26, 26 });
    try expectLimits(&s, &.{ 27, 27 });
    var ys: [2]i64 = .{ s.out.get(0).at.y, s.out.get(1).at.y };
    std.mem.sortUnstable(i64, &ys, {}, std.sort.asc(i64));
    try testing.expectEqual([2]i64{ 16, 42 }, ys);
    for (0..2) |k| try testing.expectEqual(@as(i64, 500), s.out.get(@intCast(k)).at.x);
    try testing.expectEqual(@as(u64, 2), try examined(&s));
    var t = try go(&fins(27), fin_pitch, &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
    try testing.expectEqual(@as(u64, 2), try examined(&t));
}

test "a missing fin is a double pitch and a bent one refuses" {
    // Oracle: construct-from-answer. A missing fin leaves its neighbours 54
    // apart, a violation; a fin that does not overlap another across is no
    // neighbour of it; a bent shape refuses the rule.
    var s = try go(&.{ .{ 0, 0, 1000, 7 }, .{ 0, 27, 1000, 34 }, .{ 0, 81, 1000, 88 } }, fin_pitch, &.{}, &.{});
    defer s.deinit();
    try expectLengths(&s, &.{54});
    var t = try go(&.{ .{ 0, 0, 1000, 7 }, .{ 2000, 30, 3000, 37 } }, fin_pitch, &.{}, &.{});
    defer t.deinit();
    try expectClean(&t);
    try testing.expectEqual(@as(u64, 0), (try only(&t)).examined);
    var lb = LayoutBuilder.init(1);
    _ = try lb.push(gpa, 0, &.{ 0, 1000, 1000, 7, 7, 0 }, &.{ 0, 0, 7, 7, 500, 500 });
    var bent = try common.finish(&lb);
    defer bent.deinit();
    var u = try runOn(&bent.store, &.{fin_pitch}, &.{}, &.{});
    defer u.deinit();
    try testing.expectEqual(check.report.Outcome.refused, (try only(&u)).outcome);
}

// ---------------------------------------------------------------- the deck

test "the deck spells each kind's parameters" {
    // Oracle: construct-from-answer, the deck language
    // (docs/src/reference/drc/spacing.md, DRC-029, DRC-030, DRC-033, DRC-036).
    // Each new kind's deck row builds exactly the rule its parameters spell,
    // with optional parameters given and left out.
    const text = "grid 1nm\nlayer met1 = gds(68, 20)\n" ++
        "rule e eol_space(met1; eol_width: 1300nm, within: 600nm, " ++
        "parallel: (space: 1100nm, within: 500nm, two_edges: true), end_to_end: 1400nm) >= 1200nm\n" ++
        "rule p eol_space(met1; eol_width: 1300nm, within: 0nm, parallel: none, end_to_end: none) >= 1200nm\n" ++
        "rule k eol_keep_out(met1; eol_width: 1300nm, backward: 0nm, side: 300nm, forward: 1000nm)\n" ++
        "rule f forbidden_space(met1; min: 100nm, max: 150nm, prl: 0nm)\n" ++
        "rule s span_length(met1; x: [60nm, 200nm], y: [120nm])\n";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    var deck = try compileDeck(text, &strings, &diag, arena.allocator());
    defer deck.deinit(gpa);
    const want = [_]Rule{
        .{ .eol_within_spacing = .{ .layer = A, .eol_width = 1300, .within = 600, .parallel = parallelEdge(true), .end_to_end = 1400, .limit = 1200 } },
        .{ .eol_within_spacing = .{ .layer = A, .eol_width = 1300, .within = 0, .parallel = null, .end_to_end = null, .limit = 1200 } },
        .{ .eol_keep_out = .{ .layer = A, .eol_width = 1300, .backward = 0, .side = 300, .forward = 1000, .except_within = null, .corner_only = false } },
        .{ .forbidden_spacing = .{ .layer = A, .min = 100, .max = 150, .prl = 0 } },
        lef_spans,
    };
    try testing.expectEqual(@as(u32, want.len), deck.drc.len());
    for (want, 0..) |w, i| try testing.expectEqualDeep(w, deck.drc.get(@intCast(i)));
    try testing.expectEqualDeep(SpanTable{ .x = &.{ 60, 200 }, .y = &.{120} }, deck.drc.spanTable(0));
}

test "malformed tables and ranges are refused at load" {
    // Oracle: the kinds' contracts. A tip table that is not symmetric, a
    // forbidden range that ends before it starts, a two-width table whose
    // first width states a run, and a span list that does not rise are each
    // refused when the rules are built, never run.
    for ([_][]const u8{
        "tip_space_table(met1; length: [0nm, 24nm], space: [[31nm, 25nm], [27nm, 18nm]])",
        "forbidden_space(met1; min: 150nm, max: 100nm, prl: 0nm)",
        "two_width_table(met1; width: [0nm, 250nm], prl: [0nm, 0nm], space: [[150nm, 200nm], [200nm, 250nm]])",
        "span_length(met1; x: [120nm, 120nm], y: [60nm])",
    }) |rule| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const text = try std.fmt.allocPrint(arena.allocator(), "grid 1nm\nlayer met1 = gds(68, 20)\nrule t {s}\n", .{rule});
        var strings: geom.StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: check.deck.compile.Diag = .{};
        try testing.expectError(error.BadTable, compileDeck(text, &strings, &diag, arena.allocator()));
        try testing.expectEqualStrings("t", strings.resolve(diag.rule.rule));
    }
}

test "every new kind refuses a layer that does not validate" {
    // Oracle: the kinds' contract. Every new kind refuses a layer it cannot
    // represent exactly (a triangle), and never reads it as clean.
    var built = try triangle();
    defer built.deinit();
    const rules = [_]Rule{
        tips_rule,
        .{ .two_width_spacing_table = .{ .layer = A, .table = 1 } },
        forbidden,
        lefEol(parallelEdge(false), 1400),
        keep_out,
        extensionRule(null),
        lef_spans,
        corners(false, 200),
        fin_pitch,
    };
    var s = try runOn(&built.store, &rules, &.{ asap7_m1, lef_two_widths }, &.{.{ .x = &.{60}, .y = &.{60} }});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(@as(usize, 9), s.runs.items.len);
    for (s.runs.items) |r| try testing.expectEqual(check.report.Outcome.refused, r.outcome);
}

test "a layer that does not validate is refused" {
    // Oracle: the kind's contract. A layer the rule cannot represent exactly
    // (a triangle) is refused, never read as clean.
    var built = try triangle();
    defer built.deinit();
    var s = try runOn(&built.store, &.{tips_rule}, &.{asap7_m1}, &.{});
    defer s.deinit();
    try expectClean(&s);
    try testing.expectEqual(check.report.Outcome.refused, (try only(&s)).outcome);
}
