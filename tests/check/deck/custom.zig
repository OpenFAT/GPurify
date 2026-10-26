//! The custom-rule runner keeps the report's contract whatever the user's
//! function does (deck-library plan §4.4; testing-plan L9b). Ported from
//! crates/check/tests/deck/custom.rs. A Zig panic aborts the process (no
//! unwinding), so `a_panic_refuses_the_rule_and_the_run_goes_on` has no
//! counterpart; `custom_rules_are_equal_field_by_field` tests Rust's
//! `PartialEq`, which the Zig struct does not define.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const custom = check.deck.custom;
const Measurement = check.report.Measurement;
const RuleRun = check.report.RuleRun;
const Violations = check.report.Violations;
const gpa = testing.allocator;

const full: geom.LayerId = @fromBackingInt(0);
const empty: geom.LayerId = @fromBackingInt(1);
const other: geom.LayerId = @fromBackingInt(2);

/// One check and the layers its rule reads.
const Case = struct { check: custom.CustomCheck, inputs: []const geom.LayerId };

/// What one run of custom rules gave.
const Ran = struct {
    out: Violations = .{},
    runs: std.ArrayList(RuleRun) = .empty,

    fn deinit(r: *Ran) void {
        r.out.deinit(gpa);
        r.runs.deinit(gpa);
    }
};

/// Counts calls of `nondeterministic`.
var calls: u32 = 0;

// ---- private ----

/// Three rectangles on layer 0 inside (0, 0)..(1000, 1000); layer 1 empty;
/// layer 2 one rectangle.
fn layout(store: *geom.GeometryStore, ids: *testgen.shapes.Ids) !void {
    var lb = testgen.shapes.LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 0, 400, 400, 500, 500);
    _ = try lb.rect(gpa, 0, 900, 900, 1000, 1000);
    _ = try lb.rect(gpa, 2, 200, 200, 300, 300);
    try lb.finish(gpa, store, ids);
}

/// Runs `cases`, one rule each, named `r0`, `r1`, ...
fn run(cases: []const Case, store: *const geom.GeometryStore, strings: *geom.StrTable) !Ran {
    var rules: [4]custom.CustomRule = undefined;
    for (cases, 0..) |c, at| {
        var name: [4]u8 = undefined;
        rules[at] = .{ .id = try strings.intern(gpa, try std.fmt.bufPrint(&name, "r{d}", .{at})), .inputs = c.inputs, .severity = .@"error", .check = c.check };
    }
    var r: Ran = .{};
    errdefer r.deinit();
    try custom.runCustom(gpa, rules[0..cases.len], store, null, try geom.Grid.init(1000), strings, &r.out, &r.runs);
    return r;
}

fn runOn(cases: []const Case) !Ran {
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try layout(&store, &ids);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    return run(cases, &store, &strings);
}

fn findsNothing(_: *const custom.CustomCtx, _: *custom.Findings) std.mem.Allocator.Error!void {}

/// Flags every shape of input 0, in store order, once.
fn flagsEach(ctx: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    const rows = ctx.shapes(ctx.input(0));
    for (rows.start..rows.end) |r| try out.flag(ctx, @fromBackingInt(@as(u32, @intCast(r))), .length(1));
}

/// The same findings as `flagsEach`, last first and each three times.
fn flagsEachShuffled(ctx: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    const rows = ctx.shapes(ctx.input(0));
    for (0..3) |_| {
        var r = rows.end;
        while (r > rows.start) {
            r -= 1;
            try out.flag(ctx, @fromBackingInt(r), .length(1));
        }
    }
}

fn one(layer: geom.LayerId, x: i64, y: i64, measured: Measurement) custom.Finding {
    return .{ .layer = layer, .at = .{ .x = x, .y = y }, .shape_a = check.report.no_shape, .measured = measured, .limit = measured };
}

fn outsideTheExtent(ctx: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    try out.push(one(ctx.input(0), 5000, 0, .length(1)));
}

fn onAnUndeclaredLayer(_: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    try out.push(one(other, 250, 250, .length(1)));
}

fn measuresNan(ctx: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    try out.push(one(ctx.input(0), 50, 50, .ratio(std.math.nan(f64))));
}

/// Flags the first shape on odd calls and the last on even ones.
fn nondeterministic(ctx: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    const rows = ctx.shapes(ctx.input(0));
    calls += 1;
    try out.flag(ctx, @fromBackingInt(if (calls % 2 == 0) rows.start else rows.end - 1), .length(1));
}

/// Two rectangles on input 0 must be at least `50 + w / 2` apart, `w` the
/// wider one's shorter side (Calibre eqDRC's form).
fn widthDependentSpace(ctx: *const custom.CustomCtx, out: *custom.Findings) std.mem.Allocator.Error!void {
    var pairs: std.ArrayList(geom.index.Pair) = .empty;
    defer pairs.deinit(gpa);
    try ctx.pairsWithin(gpa, 0, 0, 1000, &pairs);
    for (pairs.items) |p| {
        const a = ctx.store.polyBbox(p.a);
        const b = ctx.store.polyBbox(p.b);
        const need = 50 + @divTrunc(@max(@min(a.width(), a.height()), @min(b.width(), b.height())), 2);
        const gap = @max(b.xlo - a.xhi, a.xlo - b.xhi);
        if (gap < need) try out.flag(ctx, p.a, .length(gap));
    }
}

fn sameRows(a: *const Violations, b: *const Violations) bool {
    if (a.len() != b.len()) return false;
    for (0..a.len()) |k| {
        const x = a.get(@intCast(k));
        const y = b.get(@intCast(k));
        if (x.rule != y.rule or !x.at.eql(y.at) or x.shape_a != y.shape_a or !x.measured.eql(y.measured)) return false;
    }
    return true;
}

test "an empty input is skipped and examined comes from the runner" {
    // Oracle: construct-from-answer, L9b "accounting survives user code":
    // 3 shapes on layer 0, 1 on layer 2, none on layer 1. The skipped rule's
    // check would refuse it if called.
    var r = try runOn(&.{ .{ .check = outsideTheExtent, .inputs = &.{empty} }, .{ .check = findsNothing, .inputs = &.{full} }, .{ .check = findsNothing, .inputs = &.{ empty, other } } });
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.out.len());
    try testing.expectEqual(check.report.Outcome{ .skipped = .empty_layer }, r.runs.items[0].outcome);
    try testing.expectEqual(@as(u64, 0), r.runs.items[0].examined);
    try testing.expectEqual(check.report.Outcome.ran, r.runs.items[1].outcome);
    try testing.expectEqual(@as(u64, 3), r.runs.items[1].examined);
    try testing.expectEqual(check.report.Outcome.ran, r.runs.items[2].outcome);
    try testing.expectEqual(@as(u64, 1), r.runs.items[2].examined);
}

test "unsorted and repeated findings are canonical" {
    // Oracle: law, L9b "determinism survives user code": the canonical
    // order and dedup depend only on the set of findings.
    var sorted = try runOn(&.{.{ .check = flagsEach, .inputs = &.{full} }});
    defer sorted.deinit();
    var shuffled = try runOn(&.{.{ .check = flagsEachShuffled, .inputs = &.{full} }});
    defer shuffled.deinit();
    try testing.expectEqual(@as(u32, 3), sorted.out.len());
    try testing.expect(sameRows(&sorted.out, &shuffled.out));
    try testing.expectEqual(sorted.runs.items[0].violations, shuffled.runs.items[0].violations);
}

test "an insane finding refuses the rule" {
    // Oracle: construct-from-answer, L9b "findings are sane": the layout's
    // extent is (0, 0)..(1000, 1000), so (5000, 0) is outside it; layer 2 is
    // not the rule's input; NaN is no measurement.
    var r = try runOn(&.{ .{ .check = outsideTheExtent, .inputs = &.{full} }, .{ .check = onAnUndeclaredLayer, .inputs = &.{full} }, .{ .check = measuresNan, .inputs = &.{full} } });
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.out.len());
    for (r.runs.items) |run_| {
        try testing.expectEqual(check.report.Outcome.refused, run_.outcome);
        try testing.expectEqual(@as(u64, 3), run_.examined);
    }
}

test "the run twice comparison catches a nondeterministic rule" {
    // Oracle: determinism, L9b: two runs of one deck over one layout must
    // be row-identical.
    for ([_]struct { custom.CustomCheck, bool }{ .{ flagsEach, true }, .{ nondeterministic, false } }) |c| {
        var first = try runOn(&.{.{ .check = c[0], .inputs = &.{full} }});
        defer first.deinit();
        var second = try runOn(&.{.{ .check = c[0], .inputs = &.{full} }});
        defer second.deinit();
        try testing.expectEqual(c[1], sameRows(&first.out, &second.out));
    }
}

test "an equation based limit is a custom rule" {
    // Oracle: the equation by hand: bars 100 and 200 wide, 1000 tall, side
    // by side, need `50 + 200 / 2 = 150`; gaps 149, 150, 151 give one
    // finding of 149 and none at or above 150.
    for ([_]i64{ 149, 150, 151 }) |gap| {
        var lb = testgen.shapes.LayoutBuilder.init(1);
        defer lb.deinit(gpa);
        _ = try lb.rect(gpa, 0, 0, 0, 100, 1000);
        _ = try lb.rect(gpa, 0, 100 + gap, 0, 300 + gap, 1000);
        var store: geom.GeometryStore = .empty;
        defer store.deinit(gpa);
        var ids: testgen.shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &store, &ids);
        var strings: geom.StrTable = .empty;
        defer strings.deinit(gpa);
        var r = try run(&.{.{ .check = widthDependentSpace, .inputs = &.{full} }}, &store, &strings);
        defer r.deinit();
        try testing.expectEqual(check.report.Outcome.ran, r.runs.items[0].outcome);
        if (gap < 150) {
            try testing.expectEqual(@as(u32, 1), r.out.len());
            try testing.expect(r.out.get(0).measured.eql(.length(gap)));
        } else try testing.expectEqual(@as(u32, 0), r.out.len());
    }
}
