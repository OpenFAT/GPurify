//! What "clean" is allowed to mean: an empty violation table comes from a
//! rule that ran, one that was skipped and one that refused alike; only the
//! `RuleRun` tells them apart. Ported from crates/check/tests/report/rule_run.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const report = check.report;
const RuleRun = report.RuleRun;
const Violations = report.Violations;

const rule: geom.StrId = @fromBackingInt(31);
const other_rule: geom.StrId = @fromBackingInt(32);

/// A rule that executed, looked at shapes, and found nothing.
const ran_clean: RuleRun = .{ .rule = rule, .outcome = .ran, .examined = 4_096, .violations = 0 };

test "a clean assertion accepts only a rule that ran and examined shapes" {
    // Oracle: construct-from-answer. Accepts a rule that ran, examined
    // shapes and found nothing; rejects the same record skipped (either
    // reason), refused, examining nothing or holding a violation.
    const empty: Violations = .{};
    try testgen.assertClean(&.{ran_clean}, &empty, rule);
    var rejected = [_]RuleRun{ ran_clean, ran_clean, ran_clean, ran_clean, ran_clean };
    rejected[0].examined = 0;
    rejected[1].outcome = .{ .skipped = .empty_layer };
    rejected[2].outcome = .{ .skipped = .no_design_intent };
    rejected[3].outcome = .refused;
    rejected[4].violations = 1;
    for (rejected) |run| try testing.expectError(error.AssertionFailed, testgen.assertClean(&.{run}, &empty, rule));
}

test "a rule with no run record is not clean" {
    // Oracle: construct-from-answer. No record is "the dispatcher never
    // reached it", and a record naming another rule is no evidence.
    const empty: Violations = .{};
    try testing.expectError(error.AssertionFailed, testgen.assertClean(&.{}, &empty, rule));
    try testing.expectError(error.AssertionFailed, testgen.assertClean(&.{ran_clean}, &empty, other_rule));
}

test "a rule recorded twice cannot be asserted on" {
    // Oracle: construct-from-answer. One rule, one row: two records refuse;
    // one among other rules is the ordinary case.
    try testing.expectError(error.AssertionFailed, testgen.assertRuleRan(&.{ ran_clean, ran_clean }, rule));
    var other = ran_clean;
    other.rule = other_rule;
    try testing.expectEqual(ran_clean, try testgen.assertRuleRan(&.{ other, ran_clean }, rule));
}
