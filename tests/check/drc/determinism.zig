//! The determinism gate: two runs agree row for row; translating the design
//! translates only the report; a warning rule demotes only its own rows.
//! Ported from crates/check/tests/drc/determinism.rs.

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
const OTHER = common.other_rule;
const RuleSet = check.drc.RuleSet;
const LayoutBuilder = testgen.shapes.LayoutBuilder;

// ---- private ----

/// A 12 x 12 grid of 150 squares at a 250 pitch on A over one B plate,
/// shifted by `shift`: several rules' worth of findings.
fn busyLayout(shift: i64) !common.Built {
    var lb = LayoutBuilder.init(2);
    for (0..12) |column| for (0..12) |row| {
        const x = @as(i64, @intCast(column)) * 250 + shift;
        const y = @as(i64, @intCast(row)) * 250 + shift;
        _ = try lb.rect(gpa, 0, x, y, x + 150, y + 150);
    };
    _ = try lb.rect(gpa, 1, shift - 100, shift - 100, shift + 3_100, shift + 3_100);
    return common.finish(&lb);
}

/// Min spacing and min width, both firing; RULE as a warning when `warn`.
fn twoRules(set: *RuleSet, warn: bool) !void {
    try set.push(gpa, RULE, .{ .min_spacing = .{ .layer = A, .limit = 200 } }, if (warn) .warning else .@"error");
    try set.push(gpa, OTHER, .{ .min_width = .{ .layer = A, .limit = 200 } }, .@"error");
}

fn runOnce(set: *const RuleSet, store: *const geom.GeometryStore, sink: *Sink) !void {
    try check.drc.run(gpa, .cpu, null, set, store, null, &sink.out, &sink.runs);
    try sink.out.sortCanonical(gpa);
}

test "two runs of one design produce identical violations and identical run rows" {
    // Oracle: determinism. The same rule set over the same geometry produces
    // the same rows in the same order, twice. The canonical sort is what
    // makes the order part of the interface, so comparing the tables row for
    // row is a stronger claim than comparing them as sets.
    var built = try busyLayout(0);
    defer built.deinit();
    var set: RuleSet = .{};
    defer set.deinit(gpa);
    try twoRules(&set, false);
    var first: Sink = .{};
    defer first.deinit();
    var second: Sink = .{};
    defer second.deinit();
    try runOnce(&set, &built.store, &first);
    try runOnce(&set, &built.store, &second);
    try testing.expect(first.out.len() > 0);
    try testgen.assertViolationsEq(&first.out, &second.out);
    try testing.expectEqualSlices(check.report.RuleRun, first.runs.items, second.runs.items);
}

test "translating the whole design translates the report and changes nothing else" {
    // Oracle: law. Translating every input by the same vector translates
    // every reported coordinate by that vector and changes nothing else: the
    // same rows, the same measurements, the same `examined` counts. Layout
    // geometry has no privileged origin.
    const shift: i64 = 1_000_000;
    var set: RuleSet = .{};
    defer set.deinit(gpa);
    try twoRules(&set, false);
    var at_origin = try busyLayout(0);
    defer at_origin.deinit();
    var moved_layout = try busyLayout(shift);
    defer moved_layout.deinit();
    var origin: Sink = .{};
    defer origin.deinit();
    var moved: Sink = .{};
    defer moved.deinit();
    try runOnce(&set, &at_origin.store, &origin);
    try runOnce(&set, &moved_layout.store, &moved);
    try testing.expect(origin.out.len() > 0);
    try testing.expectEqualSlices(check.report.RuleRun, origin.runs.items, moved.runs.items);
    try testing.expectEqual(origin.out.len(), moved.out.len());
    for (0..origin.out.len()) |k| {
        const o = origin.out.get(@intCast(k));
        const m = moved.out.get(@intCast(k));
        try testing.expectEqual(o.rule, m.rule);
        try testing.expectEqual(o.layer, m.layer);
        try testing.expectEqual(o.measured, m.measured);
        try testing.expectEqual(o.limit, m.limit);
        try testing.expectEqual(o.shape_a, m.shape_a);
        try testing.expectEqual(o.shape_b, m.shape_b);
        try testing.expectEqual(o.at.x + shift, m.at.x);
        try testing.expectEqual(o.at.y + shift, m.at.y);
    }
}

test "a warning rule demotes its own findings and no other rule's" {
    // Oracle: the `RuleSet::warnings` contract
    // (docs/src/reference/deck/rules.md, Severity; catalog DRC-110). A rule the
    // deck writes `warning` reports exactly what it reports unmarked, every
    // finding demoted to a warning, and the rule beside it keeps its errors:
    // marking one rule changes the severity column of its own rows and nothing
    // else.
    var built = try busyLayout(0);
    defer built.deinit();
    var plain: RuleSet = .{};
    defer plain.deinit(gpa);
    try twoRules(&plain, false);
    var marked: RuleSet = .{};
    defer marked.deinit(gpa);
    try twoRules(&marked, true);
    var errors: Sink = .{};
    defer errors.deinit();
    var warned: Sink = .{};
    defer warned.deinit();
    try runOnce(&plain, &built.store, &errors);
    try runOnce(&marked, &built.store, &warned);
    try testing.expectEqualSlices(check.report.RuleRun, errors.runs.items, warned.runs.items);
    try testing.expect(std.mem.indexOfScalar(geom.StrId, errors.out.rule.items, RULE) != null);
    try testing.expect(std.mem.indexOfScalar(geom.StrId, errors.out.rule.items, OTHER) != null);
    try testing.expectEqual(errors.out.len(), warned.out.len());
    for (0..warned.out.len()) |k| {
        const e = errors.out.get(@intCast(k));
        const w = warned.out.get(@intCast(k));
        try testing.expectEqual(e.rule, w.rule);
        try testing.expectEqual(e.measured, w.measured);
        try testing.expectEqual(check.report.Severity.@"error", e.severity);
        try testing.expectEqual(if (w.rule == RULE) check.report.Severity.warning else check.report.Severity.@"error", w.severity);
    }
}
