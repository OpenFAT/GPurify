//! The corner model, rule by rule: shapes that meet only at a corner are one
//! figure, the corner a neck of width 0, and a ring closed only at a corner
//! encloses a hole (`Rule`'s "merged", `geom.boolean.unionInto`). Ported
//! from crates/check/tests/drc/corner_model.rs.
//!
//! Oracle: that definition, applied by hand. Before it every rule but the
//! spacing kinds read the shapes as separate figures, so testing-plan F38
//! and F51's gap was neither a notch nor a space.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const Sink = common.Sink;
const gpa = common.gpa;
const A = common.a;
const RULE = common.rule_id;
const Rule = check.drc.Rule;
const Measurement = check.report.Measurement;
const LayoutBuilder = testgen.shapes.LayoutBuilder;

// ---- private ----

fn run1(sink: *Sink, built: *const common.Built, rule: Rule) !void {
    try common.runRules(sink, &built.store, &common.single(rule));
}

fn expectOne(sink: *const Sink, measured: Measurement, at: ?[2]i64) !void {
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(measured, sink.out.get(0).measured);
    if (at) |p| try testing.expectEqual(@import("geom").Point{ .x = p[0], .y = p[1] }, sink.out.get(0).at);
}

/// Two 100-squares meeting at (100, 100).
fn kissing() !common.Built {
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 0, 100, 100, 200, 200);
    return common.finish(&lb);
}

test "a gap between parts joined at corners is a notch and not a space" {
    // F38's squares (0, 0)-(10, 10), (10, 10)-(20, 20) and (20, 0)-(30, 10)
    // are one figure joined at two corners.
    //
    // Oracle: the corner model `union_into` states (touching at a corner is
    // one figure), applied by hand: the 10 gap is a notch of 10 at (15, 5),
    // flagged under 11 and not under 10, and never a space.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 10, 10);
    _ = try lb.rect(gpa, 0, 10, 10, 20, 20);
    _ = try lb.rect(gpa, 0, 20, 0, 30, 10);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built, .{ .notch = .{ .layer = A, .limit = 11 } });
    try expectOne(&sink, .length(10), .{ 15, 5 });
    try run1(&sink, &built, .{ .notch = .{ .layer = A, .limit = 10 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try run1(&sink, &built, .{ .min_spacing = .{ .layer = A, .limit = 1_000 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a corner contact is a width of zero" {
    // Oracle: the corner model `union_into` states, applied by hand: two
    // squares meeting at (100, 100) are one figure with a neck of 0 there.
    var built = try kissing();
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built, .{ .min_width = .{ .layer = A, .limit = 1 } });
    try expectOne(&sink, .length(0), .{ 100, 100 });
}

test "min area sums a figure joined at a corner" {
    // Oracle: the corner model `union_into` states, applied by hand: the two
    // squares are one figure of 20 000, clean at 20 000 and reported once
    // against 20 001.
    var built = try kissing();
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built, .{ .min_area = .{ .layer = A, .limit = 20_000 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try run1(&sink, &built, .{ .min_area = .{ .layer = A, .limit = 20_001 } });
    try expectOne(&sink, .area(20_000), null);
}

test "a hole round an island joined at a corner excludes the island" {
    // `#####|#...#|#.#.#|##..#|#####` on 100-cells: the centre cell meets
    // the frame only at its lower left corner, so it is part of the frame.
    //
    // Oracle: the corner model `union_into` states, applied by hand to the
    // picture: one hole of seven cells, 70 000, centred on (250, 250), and
    // one figure of 18 cells, 180 000.
    const picture = [5][]const u8{ "#####", "#...#", "#.#.#", "##..#", "#####" };
    var lb = LayoutBuilder.init(1);
    for (picture, 0..) |row, k| {
        const y: i64 = @intCast(4 - k);
        for (row, 0..) |cell, x_| {
            const x: i64 = @intCast(x_);
            if (cell == '#') _ = try lb.rect(gpa, 0, x * 100, y * 100, x * 100 + 100, y * 100 + 100);
        }
    }
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built, .{ .min_enclosed_area = .{ .layer = A, .limit = 80_000 } });
    try expectOne(&sink, .area(70_000), .{ 250, 250 });
    try run1(&sink, &built, .{ .min_area = .{ .layer = A, .limit = 180_001 } });
    try expectOne(&sink, .area(180_000), null);
}
