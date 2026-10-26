//! Grid family: `off_grid` and `angle`. Angles are exact: an edge lies on an
//! allowed line (0/45/90/135 degrees) or it does not. Ported from
//! crates/check/tests/drc/grid_rules.rs.

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

/// 0 and 90 degrees.
const rectilinear: u8 = 0b0101;

// ---- private ----

fn run1(sink: *Sink, store: *const geom.GeometryStore, rule: Rule) !void {
    try common.runRules(sink, store, &common.single(rule));
}

fn square(x: i64, y: i64, size: i64) !common.Built {
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, x, y, x + size, y + size);
    return common.finish(&lb);
}

fn triangle() !testgen.violation.ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .angle = .{ .layer = A, .run = .{ 100, 100 } } } }, .{ 0, 0 }, .{ .ratio = 45.0 }, .{ .count = 1 });
}

test "every vertex off the pitch is reported at that vertex with its offset" {
    // Oracle: construct-from-answer. A square whose x coordinates are 7 and
    // 57 sits seven units off a pitch of fifty at all four vertices: four
    // violations, each 7 at its own vertex; examined counts vertices.
    var case = try testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .off_grid = .{ .layer = A, .size = 50, .grid = 50 } } }, .{ 7, 0 }, .{ .length = 7 }, .{ .length = 0 });
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .off_grid = .{ .pitch = 50 } });
    try testing.expectEqual(@as(u32, 4), sink.out.len());
    for ([_][2]i64{ .{ 7, 0 }, .{ 57, 0 }, .{ 57, 50 }, .{ 7, 50 } }) |p| {
        var want = case.expected;
        want.at = .{ .x = p[0], .y = p[1] };
        _ = try testgen.assertHasViolation(&sink.out, want);
    }
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 4), run.examined);
    try testing.expectEqual(@as(u32, 4), run.violations);
}

test "a shape on the lattice is clean and the same shape one unit off is not" {
    // Oracle: construct-from-answer. A square on the lattice is clean; the
    // same square translated by one is four violations of one unit each.
    var aligned = try square(0, 0, 50);
    defer aligned.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &aligned.store, .{ .off_grid = .{ .pitch = 50 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 4), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    var nudged = try square(1, 0, 50);
    defer nudged.deinit();
    try run1(&sink, &nudged.store, .{ .off_grid = .{ .pitch = 50 } });
    try testing.expectEqual(@as(u32, 4), sink.out.len());
    _ = try testgen.assertHasViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 1, .y = 0 }, .measured = .length(1), .limit = .length(0), .shape_a = @fromBackingInt(nudged.store.polysOnLayer(A).start), .shape_b = check.report.no_shape });
}

test "an edge parallel to no allowed direction is reported at the vertex it leaves" {
    // Oracle: construct-from-answer. The triangle's hypotenuse rises 100
    // over 100, parallel to neither rectilinear direction: one of three
    // edges is illegal, measured as the allowed lines matched (0) against 1.
    var case = try triangle();
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .angle = .{ .layer = null, .allowed = rectilinear } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    var want = case.expected;
    want.measured = .count(0);
    want.limit = .count(1);
    _ = try testgen.assertHasViolation(&sink.out, want);
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 3), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "an edge parallel to an allowed direction is clean" {
    // Oracle: construct-from-answer. The triangle under a rule also allowing
    // the diagonals is clean, and a rectangle is clean under the
    // rectilinear rule; both ran.
    var case = try triangle();
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .angle = .{ .layer = null, .allowed = rectilinear | 0b0010 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 3), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    var rectangle = try square(0, 0, 200);
    defer rectangle.deinit();
    try run1(&sink, &rectangle.store, .{ .angle = .{ .layer = null, .allowed = rectilinear } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 4), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "sky130 x.2 a 45 degree diff edge fails a per layer row" {
    // Oracle: foundry example, sky130 x.2 (90 degrees only on diff, 45
    // allowed elsewhere): the chamfered diff shape is the one violation of
    // its five edges; the same shape on met1 passes a row allowing 45.
    var lb = LayoutBuilder.init(2);
    const chamfered = try lb.push(gpa, 0, &.{ 0, 1_000, 1_000, 500, 0 }, &.{ 0, 0, 500, 1_000, 1_000 });
    _ = try lb.push(gpa, 1, &.{ 0, 1_000, 1_000, 500, 0 }, &.{ 0, 0, 500, 1_000, 1_000 });
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, .{ .angle = .{ .layer = A, .allowed = 0b0101 } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(built.of(chamfered), sink.out.get(0).shape_a);
    try testing.expectEqual(@as(u64, 5), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try run1(&sink, &built.store, .{ .angle = .{ .layer = common.b, .allowed = 0b1111 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}
