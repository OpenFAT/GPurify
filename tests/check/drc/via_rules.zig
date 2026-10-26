//! Via family: `redundant_via`, `via_array_spacing`, `cut_spacing`,
//! `cut_class_spacing`, `minimum_cut`, `via_stack`. Ported from
//! crates/check/tests/drc/via_rules.rs.
//!
//! Distance is between nearest points, not centres: a centre-based test
//! over-counts neighbours for large cuts and can call an isolated via
//! redundant, so the cut side is 100 and the pitches are stated so the two
//! readings differ.

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
const RuleSet = check.drc.RuleSet;
const Measurement = check.report.Measurement;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const no_shape = check.report.no_shape;

/// `count` cuts of side 100 in a row at `pitch`, the first centred on the
/// origin.
const CutRow = struct {
    built: common.Built,
    cuts: [4]geom.PolyId,

    fn deinit(r: *CutRow) void {
        r.built.deinit();
    }
};

const C: geom.LayerId = @fromBackingInt(2);

/// sky130 licon.2 to licon.2d as one table: classes 170 x 170 and 190 x
/// 2000, END then SIDE per class.
const licon_cells = [16]i64{ 170, 170, 510, 510, 170, 170, 510, 510, 510, 510, 350, 510, 510, 510, 510, 510 };

// ---- private ----

fn cutRow(count: usize, pitch: i64) !CutRow {
    var lb = LayoutBuilder.init(1);
    var handles: [4]testgen.shapes.Handle = undefined;
    for (0..count) |i| {
        const cx = @as(i64, @intCast(i)) * pitch;
        handles[i] = try lb.rect(gpa, 0, cx - 50, -50, cx + 50, 50);
    }
    var out: CutRow = .{ .built = try common.finish(&lb), .cuts = undefined };
    for (0..count) |i| out.cuts[i] = out.built.of(handles[i]);
    return out;
}

fn run1(sink: *Sink, store: *const geom.GeometryStore, rule: Rule) !void {
    try common.runRules(sink, store, &common.single(rule));
}

fn runSet(sink: *Sink, store: *const geom.GeometryStore, set: *const RuleSet) !void {
    try check.drc.run(gpa, .cpu, null, set, store, null, &sink.out, &sink.runs);
}

fn redundant(min_count: u16, within: i64) Rule {
    return .{ .redundant_via = .{ .layer = A, .min_count = min_count, .within = within } };
}

fn array(threshold: u16, limit: i64) Rule {
    return .{ .via_array_spacing = .{ .layer = A, .array_threshold = threshold, .limit = limit } };
}

fn cutSpacing(center: bool, adjacent: u16, within: i64, limit: i64) Rule {
    return .{ .cut_spacing = .{ .layer = A, .center = center, .adjacent = adjacent, .within = within, .limit = limit } };
}

fn examined(sink: *const Sink) !u64 {
    return (try testgen.assertRuleRan(sink.runs.items, RULE)).examined;
}

fn lonely(sink: *const Sink, at: [2]i64, measured: u32, limit: u32, cut: geom.PolyId) !void {
    _ = try testgen.assertHasViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = at[0], .y = at[1] }, .measured = .count(measured), .limit = .count(limit), .shape_a = cut, .shape_b = no_shape });
}

fn liconTable(short: *const [2]i64, long: *const [2]i64, space: *const [16]i64) check.drc.tables.CutClassTable {
    return .{ .short = short, .long = long, .space = space };
}

test "a lone cut is reported at the cut with the count it had" {
    // Oracle: construct-from-answer. A single cut has a neighbourhood
    // population of one (itself) against a requirement of two, so it is a
    // single point of failure and is reported at the cut with the count it
    // had.
    var case = try testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .via_array = .{ .cut = A, .size = 100, .pitch = 400 } } }, .{ 0, 0 }, .{ .count = 1 }, .{ .count = 2 });
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, redundant(2, 500));
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 1), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "a neighbourhood radius reaches exactly as far as it says and no further" {
    // Oracle: construct-from-answer. Two cuts at a pitch of 400 have 300
    // units of clear space between their nearest edges, so a neighbourhood
    // radius of exactly 300 reaches and one of 299 does not. That single
    // unit flips both cuts from doubled to isolated, and it is measured
    // between nearest points: a centre-based reading would call the gap 400
    // and get both answers wrong.
    var row = try cutRow(2, 400);
    defer row.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &row.built.store, redundant(2, 300));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 2), try examined(&sink));
    try run1(&sink, &row.built.store, redundant(2, 299));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    for (0..2) |i| try lonely(&sink, .{ @as(i64, @intCast(i)) * 400, 0 }, 1, 2, row.cuts[i]);
    try testing.expectEqual(@as(u64, 2), try examined(&sink));
}

test "a triple via requirement counts the cut itself among the three" {
    // Oracle: construct-from-answer. A triple-via requirement is the same
    // arithmetic one higher: three cuts in reach of each other satisfy a
    // requirement of three, and the outer two of a row of three do not once
    // the radius only reaches their immediate neighbour.
    var row = try cutRow(3, 400);
    defer row.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &row.built.store, redundant(3, 700));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 3), try examined(&sink));
    try run1(&sink, &row.built.store, redundant(3, 300));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    try lonely(&sink, .{ 0, 0 }, 2, 3, row.cuts[0]);
    try lonely(&sink, .{ 800, 0 }, 2, 3, row.cuts[2]);
}

test "pairs inside an array exactly at the limit are clean" {
    // Oracle: construct-from-answer. Four cuts at a pitch of 200 leave gaps
    // of 100 between neighbours, so with a limit of 100 they form one
    // cluster of four (larger than a threshold of three, and therefore an
    // array) and no pair inside it is below the limit. Clean, over a nonzero
    // population: `examined` counts the three adjacent pairs judged.
    var row = try cutRow(4, 200);
    defer row.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &row.built.store, array(3, 100));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 3), try examined(&sink));
}

test "every short pair inside an array is its own violation at its own gap" {
    // Oracle: construct-from-answer. One unit more limit and every adjacent
    // pair in the same array is short by one. Three violations rather than
    // one per cluster: a six-by-six array with one bad column has a specific
    // place to fix, and reporting the cluster loses it.
    var row = try cutRow(4, 200);
    defer row.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &row.built.store, array(3, 101));
    try testing.expectEqual(@as(u32, 3), sink.out.len());
    for (0..3) |i| {
        _ = try testgen.assertHasViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = @as(i64, @intCast(i)) * 200 + 100, .y = 0 }, .measured = .length(100), .limit = .length(101), .shape_a = row.cuts[i], .shape_b = row.cuts[i + 1] });
    }
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 3), run.examined);
    try testing.expectEqual(@as(u32, 3), run.violations);
}

test "a cluster exactly at the array threshold is not yet an array" {
    // Oracle: construct-from-answer. A cluster of four is not larger than a
    // threshold of four, so it is not an array and its pairs keep the
    // layer's ordinary spacing. The `examined` count falling to zero is what
    // distinguishes that from a pass.
    var row = try cutRow(4, 200);
    defer row.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &row.built.store, array(4, 101));
    try testing.expectEqual(@as(usize, 1), sink.runs.items.len);
    try testing.expectEqual(@as(u64, 0), sink.runs.items[0].examined);
    try testing.expectEqual(@as(u32, 0), sink.runs.items[0].violations);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "centre to centre spacing measures between cut centres" {
    // Oracle: construct-from-answer (LEF `SPACING CENTERTOCENTER`). A 100
    // cut centred on the origin and a 300 x 100 cut centred 299 to its right
    // are 299 apart centre to centre (149 edge to edge): one finding of 299
    // under a 300 requirement, midway between the centres at (149, 0). At
    // 300 apart they pass.
    var lb = LayoutBuilder.init(1);
    const small = try lb.rect(gpa, 0, -50, -50, 50, 50);
    const big = try lb.rect(gpa, 0, 149, -50, 449, 50);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, cutSpacing(true, 0, 0, 300));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 149, .y = 0 }, .measured = .length(299), .limit = .length(300), .shape_a = built.of(small), .shape_b = built.of(big) });
    try testing.expectEqual(@as(u64, 2), try examined(&sink));
    var row = try cutRow(2, 300);
    defer row.deinit();
    try run1(&sink, &row.built.store, cutSpacing(true, 0, 0, 300));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "adjacent cuts hold only a cut with enough close neighbours" {
    // Oracle: LEF/DEF 5.8 Figure 1-6, "SPACING 0.22 ADJACENTCUTS 3 WITHIN
    // 0.25". In a row of 100 cuts at a 300 pitch (gap 200), each cut has at
    // most two neighbours within 250, so nothing is held and the 200 gaps
    // pass a 220 requirement. A fourth cut 200 above the second gives that
    // cut three neighbours: its three pairs, each 200 apart, fail, and the
    // pair of the first and third cuts, 500 apart, does not.
    var row = try cutRow(3, 300);
    defer row.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &row.built.store, cutSpacing(false, 3, 250, 220));
    try testing.expectEqual(check.report.Outcome.ran, sink.runs.items[0].outcome);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
    try testing.expectEqual(@as(u64, 0), sink.runs.items[0].examined);
    var lb = LayoutBuilder.init(1);
    for ([_]i64{ 0, 300, 600 }) |x| _ = try lb.rect(gpa, 0, x - 50, -50, x + 50, 50);
    _ = try lb.rect(gpa, 0, 250, 250, 350, 350);
    var built = try common.finish(&lb);
    defer built.deinit();
    try run1(&sink, &built.store, cutSpacing(false, 3, 250, 220));
    try testing.expectEqual(@as(u32, 3), sink.out.len());
    for (0..3) |k| try testing.expectEqual(Measurement.length(200), sink.out.get(@intCast(k)).measured);
    try testing.expectEqual(@as(u64, 1), try examined(&sink));
}

test "a cut class table reads slots end to end and side by side" {
    // Oracle: the sky130 manual (licon.2b, licon.2c). Two slotted licons 349
    // apart end to end break licon.2b's 350; side by side, 509 apart, they
    // break licon.2c's 510; 400 apart end to end they pass. Each finding
    // names the cell it broke.
    const table = liconTable(&.{ 170, 190 }, &.{ 170, 2_000 }, &licon_cells);
    try testing.expect(table.isValid());
    var set: RuleSet = .{};
    defer set.deinit(gpa);
    const t = try set.addCutClassTable(gpa, table);
    try set.push(gpa, RULE, .{ .cut_class_spacing = .{ .layer = A, .table = t } }, .@"error");
    const cases = [_]struct { [4]i64, ?[2]i64 }{
        .{ .{ 0, 2_349, 190, 4_349 }, .{ 349, 350 } },
        .{ .{ 699, 0, 889, 2_000 }, .{ 509, 510 } },
        .{ .{ 0, 2_400, 190, 4_400 }, null },
    };
    var sink: Sink = .{};
    defer sink.deinit();
    for (cases) |cs| {
        var lb = LayoutBuilder.init(1);
        _ = try lb.rect(gpa, 0, 0, 0, 190, 2_000);
        _ = try lb.rect(gpa, 0, cs[0][0], cs[0][1], cs[0][2], cs[0][3]);
        var built = try common.finish(&lb);
        defer built.deinit();
        try runSet(&sink, &built.store, &set);
        if (cs[1]) |want| {
            try testing.expectEqual(@as(u32, 1), sink.out.len());
            try testing.expectEqual(Measurement.length(want[0]), sink.out.get(0).measured);
            try testing.expectEqual(Measurement.length(want[1]), sink.out.get(0).limit);
        } else try testing.expectEqual(@as(u32, 0), sink.out.len());
        try testing.expectEqual(@as(u64, 1), try examined(&sink));
    }
}

test "a cut class table must be symmetric with distinct classes" {
    // Oracle: construct-from-answer. A table whose cells are not symmetric,
    // or whose two classes are one size, is not a table the rule can read.
    var cells = licon_cells;
    cells[1] = 200;
    try testing.expect(!liconTable(&.{ 170, 190 }, &.{ 170, 2_000 }, &cells).isValid());
    try testing.expect(!liconTable(&.{ 170, 170 }, &.{ 170, 170 }, &licon_cells).isValid());
}

test "a via on a wire wider than the limit needs the cut count" {
    // Oracle: LEF/DEF 5.8 Minimum Cut Rule Example 1, "two via cuts are
    // required for metal4 wires that are greater than 0.5 um": on a 600 wide
    // wire, a via of one cut under its own pad fails with its count, one of
    // two cuts under one pad passes, and on a 500 wide wire (not greater) a
    // single cut passes. Layer A holds the cuts, B the wide metal, C the far
    // metal.
    const rule: Rule = .{ .minimum_cut = .{ .cut = A, .wide = B, .other = C, .width = 500, .thin = null, .within = null, .min_count = 2 } };
    const cases = [_]struct { i64, u32, ?u32 }{ .{ 600, 1, 1 }, .{ 600, 2, null }, .{ 500, 1, null } };
    var sink: Sink = .{};
    defer sink.deinit();
    for (cases) |cs| {
        var lb = LayoutBuilder.init(3);
        _ = try lb.rect(gpa, 1, 0, 0, 5_000, cs[0]);
        const lone = try lb.rect(gpa, 0, 1_000, 100, 1_100, 200);
        if (cs[1] == 2) _ = try lb.rect(gpa, 0, 1_200, 100, 1_300, 200);
        _ = try lb.rect(gpa, 2, 900, 0, 1_400, 300);
        var built = try common.finish(&lb);
        defer built.deinit();
        try run1(&sink, &built.store, rule);
        if (cs[2]) |count| {
            _ = try testgen.assertHasViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 1_050, .y = 150 }, .measured = .count(count), .limit = .count(2), .shape_a = built.of(lone), .shape_b = no_shape });
        } else {
            try testing.expectEqual(check.report.Outcome.ran, sink.runs.items[0].outcome);
            try testing.expectEqual(@as(u32, 0), sink.out.len());
        }
        try testing.expectEqual(@as(u64, @intFromBool(cs[0] > 500)), sink.runs.items[0].examined);
    }
}

test "a stack of overlapping cuts taller than the limit is reported once" {
    // Oracle: LEF/DEF 5.8 "Maximum Via Stack": a cut is in a stack with
    // another when it overlaps any part of it. Three aligned cuts on three
    // layers under a limit of two: the third cut is reported, measuring 3.
    // With the middle cut moved off the bottom one there are two stacks,
    // each within the limit.
    var set: RuleSet = .{};
    defer set.deinit(gpa);
    const stack = try set.stacks.push(gpa, &.{ A, B, C });
    try set.push(gpa, RULE, .{ .via_stack = .{ .stack = stack, .single = false, .max_height = 2 } }, .@"error");
    var sink: Sink = .{};
    defer sink.deinit();
    for ([_]struct { i64, ?u32 }{ .{ 0, 3 }, .{ 300, null } }) |cs| {
        const middle = cs[0];
        var lb = LayoutBuilder.init(3);
        _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
        _ = try lb.rect(gpa, 1, middle, 0, middle + 100, 100);
        const top = try lb.rect(gpa, 2, middle, 0, middle + 100, 100);
        var built = try common.finish(&lb);
        defer built.deinit();
        try runSet(&sink, &built.store, &set);
        if (cs[1]) |height| {
            try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = C, .severity = .@"error", .at = .{ .x = middle + 50, .y = 50 }, .measured = .count(height), .limit = .count(2), .shape_a = built.of(top), .shape_b = no_shape });
        } else try testgen.assertClean(sink.runs.items, &sink.out, RULE);
        try testing.expectEqual(@as(u64, 3), try examined(&sink));
    }
}
