//! The two closed_form.rs tests that read other families' kinds
//! (`multiple_drivers`, topology; `floating_supply`, supply), through
//! closed_form.zig's runner. Not wired into tests/check.zig until those
//! families are ported: their stubs refuse every row. Ported from
//! crates/check/tests/erc/closed_form.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const cf = @import("closed_form.zig");
const fixture = @import("fixture.zig");
const Measurement = check.report.Measurement;
const Outcome = check.report.Outcome;
const Layout = fixture.Layout;

test "a conductor without a sheet resistance refuses only the rows that read one" {
    // Oracle: construct-from-answer. `li` has no `pex` row, so its resistance
    // is unknown, never zero: `ir_drop` and `p2p_resistance` read one and
    // are refused, `multiple_drivers` reads none and runs.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var l: Layout = .{};
    try cf.named(arena, &l, "met1", 0, 0, 4_000, 1_000, "VDD");
    try cf.loadAt(arena, &l, 3_000, 0);
    const rules = "layer li = gds(9, 0)\nconnect conductors [li]\nrule ir ir_drop()\nrule p2p p2p_resistance(; max: 10ohm)\nrule drivers multiple_drivers(; max: 1)\n";
    const r = try cf.erc(arena, rules, try cf.intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "{\"net\":\"VDD\",\"max_drop_mv\":100,\"budget_current_ua\":1000}"), l);
    try testing.expectEqual(Outcome.refused, (try r.run("ir")).outcome);
    try testing.expectEqual(Outcome.refused, (try r.run("p2p")).outcome);
    try testing.expectEqual(Outcome.ran, (try r.run("drivers")).outcome);
}

test "floating supply flags every piece but the fed one" {
    // Oracle: the kind's documented rule, construct-from-answer: VDD as a
    // met2 bar (the highest layer, so the feed) and two met1 bars, none
    // touching: three pieces examined, the two met1 pieces flagged, each 0
    // connections against 1. A supply in one piece flags nothing.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const supply = try cf.intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "");
    var l: Layout = .{};
    try cf.named(arena, &l, "met1", 0, 0, 1_000, 1_000, "VDD");
    try cf.named(arena, &l, "met2", 0, 3_000, 1_000, 4_000, "VDD");
    try cf.named(arena, &l, "met1", 0, 6_000, 1_000, 7_000, "VDD");
    const r = try cf.erc(arena, "rule fs floating_supply()\n", supply, l);
    const run = try r.run("fs");
    try testing.expectEqual(Outcome.ran, run.outcome);
    try testing.expectEqual(@as(u64, 3), run.examined);
    const rows = try r.rows("fs");
    try testing.expectEqual(@as(usize, 2), rows.len);
    var ys: [2]i64 = undefined;
    for (rows, &ys) |f, *y| {
        try testing.expectEqualStrings("met1", f.layer);
        try testing.expectEqual(@as(i64, 0), f.at[0]);
        try testing.expect(f.measured.eql(Measurement.count(0)) and f.limit.?.eql(Measurement.count(1)));
        y.* = f.at[1];
    }
    std.mem.sortUnstable(i64, &ys, {}, std.sort.asc(i64));
    try testing.expectEqual([2]i64{ 0, 6_000 }, ys);

    var one: Layout = .{};
    try cf.named(arena, &one, "met1", 0, 0, 1_000, 1_000, "VDD");
    const single = try cf.erc(arena, "rule fs floating_supply()\n", supply, one);
    try testing.expectEqual(Outcome.ran, (try single.run("fs")).outcome);
    try testing.expectEqual(@as(usize, 0), (try single.rows("fs")).len);
}
