//! Assertions over violation tables, rule runs and float comparisons. In: a
//! report and the answer a generator built. Out: `error.AssertionFailed`
//! after printing what differed, so a failing test reads as a diagnosis (Rust
//! panicked; a Zig test cannot catch a panic, so these return an error).
//! Rows compare by exact equality in every field, floats included. Ported
//! from crates/testgen/src/assertions.rs.
//!
//! Contents:
//! - `pub const Error = error{AssertionFailed}`
//! - `pub fn assertClose(what: []const u8, actual: f64, expected: f64, tolerance: f64) Error!void`
//! - `pub fn assertCloseRelative(what: []const u8, actual: f64, expected: f64, tolerance: f64) Error!void`
//! - `pub fn assertRuleRan(runs: []const RuleRun, rule: StrId) Error!RuleRun`
//! - `pub fn assertClean(runs: []const RuleRun, violations: *const Violations, rule: StrId) Error!void`
//! - `pub fn assertOnlyViolation(violations: *const Violations, expected: Violation) Error!void`
//! - `pub fn assertHasViolation(violations: *const Violations, expected: Violation) Error!u32`
//! - `pub fn assertViolationsEq(actual: *const Violations, expected: *const Violations) Error!void`
//! - `pub fn assertBytesIdentical(what: []const u8, first: []const u8, second: []const u8) Error!void`
//! - `pub fn netPartition(gpa: Allocator, nets: *const NetTable) Allocator.Error![][]const PolyId`
//! - `pub fn portNames(gpa: Allocator, ports: *const PortTable, nets: *const NetTable) Allocator.Error![]?StrId`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const check = @import("check");
const report = check.report;
const RuleRun = report.RuleRun;
const Violation = report.Violation;
const Violations = report.Violations;
const NetTable = check.topology.NetTable;
const PortTable = check.topology.PortTable;

pub const Error = error{
    /// The assertion did not hold; stderr says which field and values.
    AssertionFailed,
};

/// `actual` within `tolerance` of `expected`, inclusive; both finite.
pub fn assertClose(what: []const u8, actual: f64, expected: f64, tolerance: f64) Error!void {
    if (!std.math.isFinite(actual) or !std.math.isFinite(expected))
        return fail("{s}: {d} and {d} must both be finite", .{ what, actual, expected });
    const err = @abs(actual - expected);
    if (!(err <= tolerance)) return fail("{s}: {d} is not within {d} of {d} (off by {d})", .{ what, actual, tolerance, expected, err });
}

/// `|actual - expected| / |expected| <= tolerance`; both finite, and an
/// expected zero fails (a relative tolerance around zero admits everything).
pub fn assertCloseRelative(what: []const u8, actual: f64, expected: f64, tolerance: f64) Error!void {
    if (!std.math.isFinite(actual) or !std.math.isFinite(expected))
        return fail("{s}: {d} and {d} must both be finite", .{ what, actual, expected });
    if (expected == 0) return fail("{s}: a relative tolerance around zero admits every value; use assertClose", .{what});
    const err = @abs((actual - expected) / expected);
    if (!(err <= tolerance)) return fail("{s}: {d} differs from {d} by {d} relative, over {d}", .{ what, actual, expected, err, tolerance });
}

/// Exactly one run names `rule`, it ran, and it examined at least one item
/// (a rule that ran on nothing exercised none of its logic). Returns it.
pub fn assertRuleRan(runs: []const RuleRun, rule: StrId) Error!RuleRun {
    var found: ?RuleRun = null;
    var matches: usize = 0;
    for (runs) |r| if (r.rule == rule) {
        found = r;
        matches += 1;
    };
    const run = found orelse return fail("no RuleRun for rule {d} among {d} runs", .{ @backingInt(rule), runs.len });
    if (matches != 1) return fail("rule {d} has {d} RuleRun rows; a run row must be attributable to one rule", .{ @backingInt(rule), matches });
    switch (run.outcome) {
        .ran => {},
        .skipped, .refused => return fail("rule {d} did not run: {any}", .{ @backingInt(rule), run.outcome }),
    }
    if (run.examined == 0) return fail("rule {d} ran but examined nothing", .{@backingInt(rule)});
    return run;
}

/// `assertRuleRan`, and the rule found nothing: no counted violation and no
/// row naming it.
pub fn assertClean(runs: []const RuleRun, violations: *const Violations, rule: StrId) Error!void {
    const run = try assertRuleRan(runs, rule);
    if (run.violations != 0) return fail("rule {d} reports {d} violations in its RuleRun", .{ @backingInt(rule), run.violations });
    for (violations.rule.items, 0..) |r, i| if (r == rule) {
        describe(violations);
        return fail("rule {d} was expected clean but row {d} names it", .{ @backingInt(rule), i });
    };
}

/// The table holds exactly one row, and it is `expected`.
pub fn assertOnlyViolation(violations: *const Violations, expected: Violation) Error!void {
    if (violations.len() != 1) {
        describe(violations);
        return fail("expected exactly one violation, found {d}", .{violations.len()});
    }
    try assertRow(violations, 0, expected);
}

/// The first row equal to `expected` in every field.
pub fn assertHasViolation(violations: *const Violations, expected: Violation) Error!u32 {
    for (0..violations.len()) |i| if (rowEql(violations.get(@intCast(i)), expected)) return @intCast(i);
    describe(violations);
    return fail("no row matches {any}", .{expected});
}

/// Equal row for row, in order, fix hints aside.
pub fn assertViolationsEq(actual: *const Violations, expected: *const Violations) Error!void {
    if (actual.len() != expected.len()) {
        describe(actual);
        describe(expected);
        return fail("violation tables differ in length: {d} against {d}", .{ actual.len(), expected.len() });
    }
    for (0..actual.len()) |i| try assertRow(actual, @intCast(i), expected.get(@intCast(i)));
}

/// Byte-identical output, else the offset of the first difference and up
/// to 24 bytes either side from each.
pub fn assertBytesIdentical(what: []const u8, first: []const u8, second: []const u8) Error!void {
    if (std.mem.eql(u8, first, second)) return;
    const at = std.mem.indexOfDiff(u8, first, second).?;
    const from = at -| 24;
    return fail("{s} is not deterministic: {d} and {d} bytes, first difference at {d}\nfirst:  {s}\nsecond: {s}", .{
        what, first.len, second.len, at, first[from..@min(at + 24, first.len)], second[from..@min(at + 24, second.len)],
    });
}

/// Each net's polygons by `NetId`, as the table holds them; compare with a
/// generator's `expected_net_polys`. Caller frees the outer slice only (the
/// inner ones borrow `nets`).
pub fn netPartition(gpa: Allocator, nets: *const NetTable) Allocator.Error![][]const PolyId {
    const out = try gpa.alloc([]const PolyId, nets.netCount());
    for (out, 0..) |*polys, n| polys.* = nets.polysOf(@fromBackingInt(@intCast(n)));
    return out;
}

/// Each net's name by `NetId`. Caller frees.
pub fn portNames(gpa: Allocator, ports: *const PortTable, nets: *const NetTable) Allocator.Error![]?StrId {
    const out = try gpa.alloc(?StrId, nets.netCount());
    for (out, 0..) |*name, n| name.* = ports.nameOf(@fromBackingInt(@intCast(n)));
    return out;
}

// ---- private ----

fn fail(comptime fmt: []const u8, args: anytype) Error {
    std.debug.print(fmt ++ "\n", args);
    return error.AssertionFailed;
}

fn rowEql(a: Violation, b: Violation) bool {
    return a.rule == b.rule and a.layer == b.layer and a.severity == b.severity and a.at.eql(b.at) and
        a.measured.eql(b.measured) and a.limit.eql(b.limit) and a.shape_a == b.shape_a and a.shape_b == b.shape_b;
}

/// One row field by field, so the failure names the field.
fn assertRow(violations: *const Violations, row: u32, expected: Violation) Error!void {
    const actual = violations.get(row);
    if (actual.rule != expected.rule) return fail("row {d}: rule {d}, expected {d}", .{ row, @backingInt(actual.rule), @backingInt(expected.rule) });
    if (actual.layer != expected.layer) return fail("row {d}: layer {d}, expected {d}", .{ row, @backingInt(actual.layer), @backingInt(expected.layer) });
    if (actual.severity != expected.severity) return fail("row {d}: severity {t}, expected {t}", .{ row, actual.severity, expected.severity });
    if (!actual.at.eql(expected.at)) return fail("row {d}: reported at {any}, expected {any}", .{ row, actual.at, expected.at });
    if (!actual.measured.eql(expected.measured)) return fail("row {d}: measured {f}, expected {f}", .{ row, actual.measured, expected.measured });
    if (!actual.limit.eql(expected.limit)) return fail("row {d}: limit {f}, expected {f}", .{ row, actual.limit, expected.limit });
    if (actual.shape_a != expected.shape_a or actual.shape_b != expected.shape_b)
        return fail("row {d}: shapes ({d}, {d}), expected ({d}, {d})", .{ row, @backingInt(actual.shape_a), @backingInt(actual.shape_b), @backingInt(expected.shape_a), @backingInt(expected.shape_b) });
}

fn describe(violations: *const Violations) void {
    if (violations.len() == 0) std.debug.print("  (no rows)\n", .{});
    for (0..violations.len()) |i| std.debug.print("  [{d}] {any}\n", .{ i, violations.get(@intCast(i)) });
}

test "absolute tolerance is the boundary it says it is" {
    // Oracle: hand-derived. |1.0005 - 1| = 5e-4 is inside 1e-3 and |1.01 - 1|
    // = 1e-2 outside; a NaN is outside any tolerance.
    try assertClose("a length", 1.0005, 1.0, 1e-3);
    try std.testing.expectError(error.AssertionFailed, assertClose("a length", 1.01, 1.0, 1e-3));
    try std.testing.expectError(error.AssertionFailed, assertClose("a length", std.math.nan(f64), 1.0, 1e-3));
}

test "relative tolerance scales with magnitude and refuses zero" {
    // Oracle: hand-derived, against the documented contract. 0.5 / 1000 =
    // 5e-4 is inside 1e-3 and 5e-4 outside 1e-6, and an expected zero fails
    // ("use assertClose").
    try assertCloseRelative("a resistance", 1000.5, 1000.0, 1e-3);
    try std.testing.expectError(error.AssertionFailed, assertCloseRelative("a resistance", 1.0005, 1.0, 1e-6));
    try std.testing.expectError(error.AssertionFailed, assertCloseRelative("a resistance", 0.0, 0.0, 1e-3));
}

test "byte comparison catches a single differing byte" {
    // Oracle: construct-from-answer. Byte 137 has one bit flipped, so the two
    // buffers differ in exactly one byte.
    var base: [200]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @intCast(i % 251);
    try assertBytesIdentical("a report", &base, &base);
    var altered = base;
    altered[137] ^= 1;
    try std.testing.expectError(error.AssertionFailed, assertBytesIdentical("a report", &base, &altered));
}
