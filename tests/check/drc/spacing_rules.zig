//! Spacing family: the rules built on a candidate-pair prune. Every case
//! asserts the report point and `examined`. Ported from
//! crates/check/tests/drc/spacing_rules.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const Sink = common.Sink;
const gpa = common.gpa;
const A = common.a;
const B = common.b;
const RULE = common.rule_id;
const Rule = check.drc.Rule;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const ViolationCase = testgen.violation.ViolationCase;

// ---- private ----

/// Two 200-sided squares facing across an exact gap, 400 tall.
fn spaced(gap: i64, limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .spacing = .{ .layer = A, .extent = 200 } } }, .{ 0, 0 }, .{ .length = gap }, .{ .length = limit });
}

fn separation(limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .separation = .{ .a = A, .b = B, .size = 200 } } }, .{ 0, 0 }, .{ .length = 100 }, .{ .length = limit });
}

fn endOfLine(limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .end_of_line = .{ .layer = A, .width = 40, .extent = 300 } } }, .{ 0, 0 }, .{ .length = 100 }, .{ .length = limit });
}

fn cornerCase(limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .corner_to_corner = .{ .layer = A, .size = 100, .legs = .{ 60, 80 } } } }, .{ 0, 0 }, .{ .length = 100 }, .{ .length = limit });
}

/// Runs one rule over a case and returns its sink.
fn runOne(store: *const geom.GeometryStore, rule: Rule) !Sink {
    var sink: Sink = .{};
    errdefer sink.deinit();
    try common.runRules(&sink, store, &common.single(rule));
    return sink;
}

/// The case's only violation, and the examined count.
fn expectOnly(case: *const ViolationCase, rule: Rule, examined: u64) !void {
    var sink = try runOne(&case.store, rule);
    defer sink.deinit();
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    try testing.expectEqual(examined, (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

/// Clean, over `examined` items.
fn expectClean(store: *const geom.GeometryStore, rule: Rule, examined: u64) !void {
    var sink = try runOne(store, rule);
    defer sink.deinit();
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(examined, (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

/// Ran over an empty population: nothing judged, nothing found.
fn expectNothingJudged(store: *const geom.GeometryStore, rule: Rule) !void {
    var sink = try runOne(store, rule);
    defer sink.deinit();
    try testing.expectEqual(@as(usize, 1), sink.runs.items.len);
    try testing.expectEqual(check.report.Outcome.ran, sink.runs.items[0].outcome);
    try testing.expectEqual(@as(u64, 0), sink.runs.items[0].examined);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

fn minSpacing(limit: i64) Rule {
    return .{ .min_spacing = .{ .layer = A, .limit = limit } };
}

fn huge() Rule {
    return .{ .wide_dependent_spacing = .{ .layer = A, .width_threshold = 3_000, .limit = 280 } };
}

/// A 10 um plate with a 140-wide, 1000-long tab off its top.
fn plateWithTab(lb: *LayoutBuilder) !testgen.shapes.Handle {
    return lb.push(gpa, 0, &.{ 0, 10_000, 10_000, 5_140, 5_140, 5_000, 5_000, 0 }, &.{ 0, 0, 10_000, 10_000, 11_000, 11_000, 10_000, 10_000 });
}

test "a gap one unit under the limit is reported at the midpoint of that gap" {
    // Oracle: construct-from-answer. Two shapes exactly 100 apart, reported
    // at the gap's midpoint; 101 is the smallest limit that fails it, over
    // one candidate pair.
    var case = try spaced(100, 101);
    defer case.deinit(gpa);
    try expectOnly(&case, minSpacing(101), 1);
}

test "a gap exactly at the limit is clean and the pair was still examined" {
    // Oracle: construct-from-answer. A gap at the limit meets it; the pair
    // is still generated and measured.
    var case = try spaced(100, 100);
    defer case.deinit(gpa);
    try expectClean(&case.store, minSpacing(100), 1);
}

test "two shapes of one merged figure have no gap to violate" {
    // Oracle: construct-from-answer. Overlapping shapes are one figure: the
    // pair is a candidate, dropped after figure labelling.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 400, 200);
    _ = try lb.rect(gpa, 0, 300, 0, 700, 200);
    var built = try common.finish(&lb);
    defer built.deinit();
    try expectClean(&built.store, minSpacing(1_000), 1);
}

test "spacing exempts the intra figure gap that notch now reports" {
    // Oracle: construct-from-answer. Three rectangles of a fractured U merge
    // into one figure, and `docs/deck.md` makes a gap between two parts of
    // one shape a notch that `space` never measures: clean under 81.
    // (Ported from width_rules.rs.)
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 300, 100);
    _ = try lb.rect(gpa, 0, 0, 100, 110, 500);
    _ = try lb.rect(gpa, 0, 190, 100, 300, 500);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink = try runOne(&built.store, minSpacing(81));
    defer sink.deinit();
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a cross layer gap one unit under the limit is reported at the midpoint" {
    // Oracle: construct-from-answer. A shape on A and one on B 100 apart,
    // reported at the midpoint on layer A against 101.
    var case = try separation(101);
    defer case.deinit(gpa);
    try expectOnly(&case, .{ .min_spacing_diff = .{ .a = A, .b = B, .limit = 101 } }, 1);
}

test "a cross layer gap exactly at the limit is clean and the pair was examined" {
    // Oracle: construct-from-answer. The pair at its limit is clean and was
    // still measured.
    var case = try separation(100);
    defer case.deinit(gpa);
    try expectClean(&case.store, .{ .min_spacing_diff = .{ .a = A, .b = B, .limit = 100 } }, 1);
}

test "two layers that meet have a spacing of zero and have failed" {
    // Oracle: construct-from-answer. Two layers never merge; squares meeting
    // at one point measure 0, marked at that point (100, 100).
    var lb = LayoutBuilder.init(2);
    const lower = try lb.rect(gpa, 0, 0, 0, 100, 100);
    const upper = try lb.rect(gpa, 1, 100, 100, 200, 200);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink = try runOne(&built.store, .{ .min_spacing_diff = .{ .a = A, .b = B, .limit = 50 } });
    defer sink.deinit();
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 100, .y = 100 }, .measured = .length(0), .limit = .length(50), .shape_a = built.of(lower), .shape_b = built.of(upper) });
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an end of line one unit under its enlarged limit is reported at the gap" {
    // Oracle: construct-from-answer. A 40-unit end faces a wide neighbour
    // across 100; with eol_width 41 it is an end of line, held to 101.
    var case = try endOfLine(101);
    defer case.deinit(gpa);
    try expectOnly(&case, .{ .eol_spacing = .{ .layer = A, .eol_width = 41, .limit = 101 } }, 1);
}

test "a qualifying end of line exactly at its limit is clean" {
    // Oracle: construct-from-answer. At its enlarged limit, and the
    // qualifying pair was counted.
    var case = try endOfLine(100);
    defer case.deinit(gpa);
    try expectClean(&case.store, .{ .eol_spacing = .{ .layer = A, .eol_width = 41, .limit = 100 } }, 1);
}

test "an edge exactly at the end of line width is not an end of line" {
    // Oracle: construct-from-answer. An edge exactly eol_width long is not
    // shorter than it: nothing judged.
    var case = try endOfLine(101);
    defer case.deinit(gpa);
    try expectNothingJudged(&case.store, .{ .eol_spacing = .{ .layer = A, .eol_width = 40, .limit = 101 } });
}

test "a pair at the parallel run threshold is held to the larger limit" {
    // Oracle: construct-from-answer. The pair runs 400 alongside, reaching a
    // 400 threshold, so the 101 limit applies and 100 fails it.
    var case = try spaced(100, 101);
    defer case.deinit(gpa);
    try expectOnly(&case, .{ .prl_spacing = .{ .layer = A, .prl_threshold = 400, .limit = 101 } }, 1);
}

test "a run one unit short of the threshold is not judged by this rule" {
    // Oracle: construct-from-answer. A 400 run does not reach 401.
    var case = try spaced(100, 101);
    defer case.deinit(gpa);
    try expectNothingJudged(&case.store, .{ .prl_spacing = .{ .layer = A, .prl_threshold = 401, .limit = 101 } });
}

test "a qualifying run exactly at the larger limit is clean" {
    // Oracle: construct-from-answer. Held to 100, sitting exactly at it.
    var case = try spaced(100, 100);
    defer case.deinit(gpa);
    try expectClean(&case.store, .{ .prl_spacing = .{ .layer = A, .prl_threshold = 400, .limit = 100 } }, 1);
}

test "a diagonal corner gap is measured exactly on a pythagorean offset" {
    // Oracle: construct-from-answer on the 60-80-100 triple: the nearest
    // corners are exactly 100 apart, marked at their midpoint.
    var case = try cornerCase(101);
    defer case.deinit(gpa);
    try expectOnly(&case, .{ .corner_to_corner = .{ .layer = A, .limit = 101 } }, 1);
}

test "a diagonal corner gap exactly at the limit is clean" {
    // Oracle: closed form. Legs 60 and 80 are a corner gap of exactly 100.
    var case = try cornerCase(100);
    defer case.deinit(gpa);
    try expectClean(&case.store, .{ .corner_to_corner = .{ .layer = A, .limit = 100 } }, 1);
}

test "a pair that overlaps on an axis is not a corner to corner situation" {
    // Oracle: construct-from-answer. Shapes facing across an edge belong to
    // min_spacing; this rule judges none.
    var case = try spaced(100, 101);
    defer case.deinit(gpa);
    try expectNothingJudged(&case.store, .{ .corner_to_corner = .{ .layer = A, .limit = 1_000 } });
}

test "a pair containing a wide shape is held to the wide limit" {
    // Oracle: construct-from-answer. 200 squares are wide at threshold 200:
    // the 101 limit applies to the 100 gap.
    var case = try spaced(100, 101);
    defer case.deinit(gpa);
    try expectOnly(&case, .{ .wide_dependent_spacing = .{ .layer = A, .width_threshold = 200, .limit = 101 } }, 1);
}

test "a qualifying wide pair exactly at the wide limit is clean" {
    // Oracle: construct-from-answer. At the wide limit, over one pair.
    var case = try spaced(100, 100);
    defer case.deinit(gpa);
    try expectClean(&case.store, .{ .wide_dependent_spacing = .{ .layer = A, .width_threshold = 200, .limit = 100 } }, 1);
}

test "a shape one unit narrower than the wide threshold does not trigger the rule" {
    // Oracle: construct-from-answer. No 201 square fits a 200 square.
    var case = try spaced(100, 101);
    defer case.deinit(gpa);
    try expectNothingJudged(&case.store, .{ .wide_dependent_spacing = .{ .layer = A, .width_threshold = 201, .limit = 101 } });
}

test "sky130 m1.3ab a plate with a thin tab is still huge where the plate is" {
    // Oracle: foundry example, sky130 m1.3ab (0.28 um from huge met1, the
    // part wider than 3 um), by hand: the wire is 200 from the 10 um plate,
    // one violation of 200 naming the plate and the wire.
    var lb = LayoutBuilder.init(1);
    const plate = try plateWithTab(&lb);
    const wire = try lb.rect(gpa, 0, 10_200, 0, 10_340, 5_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink = try runOne(&built.store, huge());
    defer sink.deinit();
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    const v = sink.out.get(0);
    try testing.expect(v.measured.eql(.length(200)));
    try testing.expectEqual(built.of(plate), v.shape_a);
    try testing.expectEqual(built.of(wire), v.shape_b);
}

test "sky130 m1.3ab the thin tab is not huge" {
    // Oracle: foundry example, sky130 m1.3ab, by hand: the wire is 200 from
    // the tab's end and 1200 from the plate: no huge neighbour within 280.
    var lb = LayoutBuilder.init(1);
    _ = try plateWithTab(&lb);
    _ = try lb.rect(gpa, 0, 4_000, 11_200, 6_000, 11_340);
    var built = try common.finish(&lb);
    defer built.deinit();
    try expectClean(&built.store, huge(), 1);
}

test "a plate drawn as two narrow rectangles is huge" {
    // Oracle: hand-derived. Two 2 um rectangles merge into a 4 um plate,
    // and the wire is 200 from it: one violation of 200.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 2_000, 4_000);
    _ = try lb.rect(gpa, 0, 2_000, 0, 4_000, 4_000);
    _ = try lb.rect(gpa, 0, 4_200, 0, 4_340, 4_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink = try runOne(&built.store, huge());
    defer sink.deinit();
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(200)));
}

test "a huge plate is not spaced against its own hole" {
    // Oracle: construct-from-answer. The only other shape is exactly 280
    // away, and the plate's own hole is its boundary: one pair, clean.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 8_000, 8_000);
    _ = try lb.shape(gpa, 0, testgen.shapes.hole(3_000, 3_000, 5_000, 5_000));
    _ = try lb.rect(gpa, 0, 8_280, 0, 8_420, 8_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    try expectClean(&built.store, huge(), 1);
}

test "projection spacing measures only facing edges" {
    // Oracle: construct-from-answer (KLayout's projection metric, sky130
    // lvtn.3b): squares 100 apart side by side face over their height, one
    // finding of 100 at (250, 100); offset by 100 on both axes they face
    // nowhere and pass, though 141 apart by Euclid.
    const rule: Rule = .{ .projection_spacing = .{ .a = A, .b = B, .limit = 235 } };
    var lb = LayoutBuilder.init(2);
    const left = try lb.rect(gpa, 0, 0, 0, 200, 200);
    const right = try lb.rect(gpa, 1, 300, 0, 500, 200);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink = try runOne(&built.store, rule);
    defer sink.deinit();
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 250, .y = 100 }, .measured = .length(100), .limit = .length(235), .shape_a = built.of(left), .shape_b = built.of(right) });
    var lb2 = LayoutBuilder.init(2);
    _ = try lb2.rect(gpa, 0, 0, 0, 200, 200);
    _ = try lb2.rect(gpa, 1, 300, 300, 500, 500);
    var off = try common.finish(&lb2);
    defer off.deinit();
    try expectClean(&off.store, rule, 1);
}
