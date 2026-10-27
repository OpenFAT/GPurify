//! Width family: `min_width`, `max_width`, `cut_size`, `min_edge_length`,
//! `notch`. Each case is one geometry against the limit at its answer
//! (clean) and one unit past it. Ported from
//! crates/check/tests/drc/width_rules.rs.

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
const Rule = check.drc.Rule;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Ids = testgen.shapes.Ids;
const GeometryStore = geom.GeometryStore;

/// A store and its handles, freed together.
const Layout = struct {
    store: GeometryStore = .empty,
    ids: Ids = .{},

    fn deinit(l: *Layout) void {
        l.store.deinit(gpa);
        l.ids.deinit(gpa);
    }
};

// ---- private ----

fn finish(lb: *LayoutBuilder) !Layout {
    var l: Layout = .{};
    try lb.finish(gpa, &l.store, &l.ids);
    lb.deinit(gpa);
    return l;
}

/// A rectangle exactly `measured` units across and 1000 long.
fn widthCase(measured: i64, limit: i64) !testgen.violation.ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .width = .{ .layer = A, .run = 1_000 } } }, .{ 0, 0 }, .{ .length = measured }, .{ .length = limit });
}

fn one(rule: Rule) [1]common.Item {
    return .{.{ .id = RULE, .rule = rule }};
}

fn minWidth(limit: i64) [1]common.Item {
    return one(.{ .min_width = .{ .layer = A, .limit = limit } });
}

fn maxWidth(limit: i64) [1]common.Item {
    return one(.{ .max_width = .{ .layer = A, .limit = limit } });
}

fn cutSize(w: i64, h: i64) [1]common.Item {
    return one(.{ .cut_size = .{ .layer = A, .width = w, .height = h } });
}

fn notch(limit: i64) [1]common.Item {
    return one(.{ .notch = .{ .layer = A, .limit = limit } });
}

fn edgeCase(limit: i64) !testgen.violation.ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .edge_length = .{ .layer = A, .body = 1_000 } } }, .{ 0, 0 }, .{ .length = 40 }, .{ .length = limit });
}

fn notchCase(limit: i64) !testgen.violation.ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .notch = .{ .layer = A, .arm = 400, .thickness = 100 } } }, .{ 0, 0 }, .{ .length = 60 }, .{ .length = limit });
}

/// A U drawn as three touching rectangles, arms 80 units apart.
fn fracturedU() !Layout {
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 300, 100);
    _ = try lb.rect(gpa, 0, 0, 100, 110, 500);
    _ = try lb.rect(gpa, 0, 190, 100, 300, 500);
    return finish(&lb);
}

test "a width one unit under the limit is reported at the narrow span with its measurement" {
    // Oracle: construct-from-answer. The generator built a rectangle 200
    // units across, so 200 is the measurement and the coordinate it is
    // measured at is the rectangle's centre.
    var case = try widthCase(200, 201);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &minWidth(201));
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, case.shapes), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "a width exactly at the limit is clean and the rule says it looked" {
    // Oracle: construct-from-answer, the other side of the same unit.
    var case = try widthCase(200, 200);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &minWidth(200));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, case.shapes), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a width one unit over the maximum is reported with the same measurement" {
    // Oracle: construct-from-answer. Same scan and measurement as
    // min_width, compared the other way: 200 is above 199 and not above 200.
    var case = try widthCase(200, 199);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &maxWidth(199));
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    try testing.expectEqual(@as(u64, case.shapes), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a width exactly at the maximum is clean" {
    // Oracle: construct-from-answer. Drawn exactly 200 wide; a maximum is
    // violated only above it.
    var case = try widthCase(200, 200);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &maxWidth(200));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "two short edges on one shape are two violations at two coordinates" {
    // Oracle: construct-from-answer. The rectangle (-20, 0)..(20, 1000) has
    // two 40-unit edges, along y = 0 and y = 1000, reported per edge at
    // their midpoints (0, 0) and (0, 1000); four edges examined.
    var case = try edgeCase(41);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &one(.{ .min_edge_length = .{ .layer = A, .limit = 41 } }));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    for ([2][2]i64{ .{ 0, 0 }, .{ 0, 1_000 } }) |p| {
        var want = case.expected;
        want.at = .{ .x = p[0], .y = p[1] };
        _ = try testgen.assertHasViolation(&sink.out, want);
    }
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 4), run.examined);
    try testing.expectEqual(@as(u32, 2), run.violations);
}

test "edges exactly at the minimum length are clean over a nonzero edge count" {
    // Oracle: construct-from-answer. Every edge is at least the 40 limit.
    var case = try edgeCase(40);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &one(.{ .min_edge_length = .{ .layer = A, .limit = 40 } }));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 4), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a notch one unit under the limit is reported inside the void" {
    // Oracle: construct-from-answer. A U's internal gap is a notch: the
    // point is inside the bounding box and outside the polygon.
    var case = try notchCase(61);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &notch(61));
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    try testing.expectEqual(@as(u64, case.shapes), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a notch exactly at the limit is clean" {
    // Oracle: construct-from-answer. The notch is drawn exactly 60 wide.
    var case = try notchCase(60);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &notch(60));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a notch across two rectangles of one merged figure is still a notch" {
    // Oracle: construct-from-answer, and the `notch_no_outer_merge` defect:
    // a U whose arms are 80 apart has an 80-unit notch however it is
    // fractured.
    var l = try fracturedU();
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &notch(81));
    _ = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(80)));
}

test "a fractured notch exactly at the limit is clean" {
    // Oracle: construct-from-answer. `fracturedU`'s gap is 80, the limit.
    var l = try fracturedU();
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &notch(80));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a convex shape has no notch to report" {
    // Oracle: construct-from-answer. A convex shape has no facing pair
    // whose gap lies outside it.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 40, 40);
    var l = try finish(&lb);
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &notch(1_000_000));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "ihp slt.c a plate with a thin tab is as wide as the plate" {
    // Oracle: foundry example, IHP Slt.c (metal wider than 30 um must be
    // slotted), and docs/src/reference/drc/dimension.md (DRC-012): one
    // violation of 40 um.
    var lb = LayoutBuilder.init(1);
    const plate = try lb.push(gpa, 0, &.{ 0, 40_000, 40_000, 20_200, 20_200, 20_000, 20_000, 0 }, &.{ 0, 0, 40_000, 40_000, 41_000, 41_000, 40_000, 40_000 });
    var l = try finish(&lb);
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &maxWidth(30_000));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(40_000)));
    try testing.expectEqual(l.ids.of(plate), sink.out.get(0).shape_a);
    try testing.expectEqual(check.report.no_shape, sink.out.get(0).shape_b);
}

test "two abutting narrow rectangles are as wide as their union" {
    // Oracle: hand-derived. The two 20 um rectangles merge into a 40 um
    // plate: one violation of 40 um, naming the first drawn row.
    var lb = LayoutBuilder.init(1);
    const first = try lb.rect(gpa, 0, 0, 0, 20_000, 40_000);
    _ = try lb.rect(gpa, 0, 20_000, 0, 40_000, 40_000);
    var l = try finish(&lb);
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &maxWidth(30_000));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(40_000)));
    try testing.expectEqual(l.ids.of(first), sink.out.get(0).shape_a);
    try testing.expectEqual(@as(u64, 2), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "sky130 licon.1 a slot is not a licon" {
    // Oracle: foundry example, sky130 licon.1 (min and max L and W 0.17
    // um): a 0.17 x 0.34 slot meets a 0.17 maximum width but not the exact
    // size, measured 340 at its centre (85, 170).
    var lb = LayoutBuilder.init(1);
    const slot = try lb.rect(gpa, 0, 0, 0, 170, 340);
    var l = try finish(&lb);
    defer l.deinit();
    var widths: Sink = .{};
    defer widths.deinit();
    try common.runRules(&widths, &l.store, &maxWidth(170));
    try testgen.assertClean(widths.runs.items, &widths.out, RULE);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &cutSize(170, 170));
    try testgen.assertOnlyViolation(&sink.out, .{
        .rule = RULE,
        .layer = A,
        .severity = .@"error",
        .at = .{ .x = 85, .y = 170 },
        .measured = .length(340),
        .limit = .length(170),
        .shape_a = l.ids.of(slot),
        .shape_b = check.report.no_shape,
    });
}

test "sky130 licon.1 a square passes and two abutting squares do not" {
    // Oracle: foundry example, sky130 licon.1, and
    // docs/src/explanation/measuring.md (Shapes merge before they are measured:
    // touching cuts are one shape): the lone square passes, the pair is one
    // 340 slot, blamed on its first drawn row.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 5_000, 0, 5_170, 170);
    const first = try lb.rect(gpa, 0, 0, 0, 170, 170);
    _ = try lb.rect(gpa, 0, 170, 0, 340, 170);
    var l = try finish(&lb);
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &cutSize(170, 170));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(340)));
    try testing.expectEqual(l.ids.of(first), sink.out.get(0).shape_a);
    try testing.expectEqual(@as(u64, 2), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a cut size accepts either orientation and refuses a non-rectangle" {
    // Oracle: docs/src/reference/drc/dimension.md (DRC-013)'s
    // `size(L) == len x len` (either way round), by hand: both rectangles pass,
    // the L reports its area 510 * 100 + 100 * 70.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 170, 510);
    _ = try lb.rect(gpa, 0, 1_000, 0, 1_510, 170);
    _ = try lb.push(gpa, 0, &.{ 2_000, 2_510, 2_510, 2_100, 2_100, 2_000 }, &.{ 0, 0, 100, 100, 170, 170 });
    var l = try finish(&lb);
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &cutSize(170, 510));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.area(510 * 100 + 100 * 70)));
}

test "a notch names the lowest drawn row of its own figure" {
    // Oracle: construct-from-answer. The square left of the U is the
    // merge's figure 0, the U figure 1; the finding names the U's lowest
    // drawn row, its base.
    var lb = LayoutBuilder.init(1);
    const base = try lb.rect(gpa, 0, 1_000, 0, 1_300, 100);
    _ = try lb.rect(gpa, 0, 1_000, 100, 1_110, 500);
    _ = try lb.rect(gpa, 0, 1_190, 100, 1_300, 500);
    const square = try lb.rect(gpa, 0, 0, 0, 100, 100);
    var l = try finish(&lb);
    defer l.deinit();
    try testing.expect(@backingInt(l.ids.of(base)) < @backingInt(l.ids.of(square)));
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &notch(81));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(l.ids.of(base), sink.out.get(0).shape_a);
}

test "a diagonal neck between concave corners is a width violation" {
    // Oracle: KLayout's Euclidean width (`sky130A_mr.drc` m1.1). The inner
    // corners are 90 and 100 apart: 134² < 18100 < 135², so 135 reports
    // 134 and 134 is clean.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 200, 300, 500);
    _ = try lb.rect(gpa, 0, 210, 0, 510, 300);
    var l = try finish(&lb);
    defer l.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &l.store, &minWidth(135));
    _ = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(134)));
    try common.runRules(&sink, &l.store, &minWidth(134));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}
