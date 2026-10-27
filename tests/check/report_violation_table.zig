//! The violation table: pushing rows, concatenating tables, and the
//! canonical order. Oracles: law and determinism; ordering tests shuffle
//! first, with a seed, because the claim is that the sort key is total.
//! Ported from crates/check/tests/report/violation_table.rs.
//!
//! One change: Rust's ratio-ordering test paired a `Ratio` measured with a
//! `Count` limit, which its own docs forbid and the Zig table cannot hold
//! (one kind per row); the limit is a ratio here.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const report = check.report;
const Measurement = report.Measurement;
const Severity = report.Severity;
const Violation = report.Violation;
const Violations = report.Violations;
const Rng = testgen.Rng;
const point = testgen.shapes.point;

const gpa = testing.allocator;

// ---- private ----

/// Two values in each of the six key fields, walked in exactly the promised
/// order, so the nested loops enumerate the answer. Fields outside the key
/// vary independently: `measured` is the position, `limit` counts down,
/// severity cycles with period three.
fn orderedCorpus() [64]Violation {
    var rows: [64]Violation = undefined;
    var n: u32 = 0;
    for ([_]u32{ 2, 5 }) |r| for ([_]u16{ 1, 8 }) |l| for ([_]i64{ -40, 40 }) |y| for ([_]i64{ -40, 40 }) |x|
        for ([_]u32{ 3, 7 }) |sa| for ([_]u32{ 11, 13 }) |sb| {
            rows[n] = .{
                .rule = @fromBackingInt(r),
                .layer = @fromBackingInt(l),
                .severity = severityFor(n),
                .at = point(x, y),
                .measured = .count(n),
                .limit = .count(1_000 - n),
                .shape_a = @fromBackingInt(sa),
                .shape_b = @fromBackingInt(sb),
            };
            n += 1;
        };
    return rows;
}

fn severityFor(tag: u32) Severity {
    return if (tag % 3 == 0) .warning else .@"error";
}

/// The ordered corpus plus a single-shape twin of every row; only that the
/// twins land in the same place under every input order is asserted.
fn totalityCorpus() [128]Violation {
    var rows: [128]Violation = undefined;
    const ordered = orderedCorpus();
    @memcpy(rows[0..64], &ordered);
    for (ordered, 64..) |row, tag| {
        var twin = row;
        twin.shape_b = report.no_shape;
        twin.measured = .count(@intCast(tag));
        twin.limit = .count(@intCast(1_000 - tag));
        twin.severity = severityFor(@intCast(tag));
        rows[tag] = twin;
    }
    return rows;
}

fn tableOf(rows: []const Violation) !Violations {
    var table: Violations = .{};
    errdefer table.deinit(gpa);
    for (rows) |row| try table.push(gpa, row);
    return table;
}

fn sortedFromShuffle(rows: []const Violation, seed: u64) !Violations {
    const shuffled = try gpa.dupe(Violation, rows);
    defer gpa.free(shuffled);
    var rng = Rng.init(seed);
    rng.shuffle(Violation, shuffled);
    var table = try tableOf(shuffled);
    errdefer table.deinit(gpa);
    try table.sortCanonical(gpa);
    try assertColumnsParallel(&table);
    return table;
}

fn render(table: *const Violations) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..table.len()) |i| {
        const line = try std.fmt.allocPrint(gpa, "{any}\n", .{table.get(@intCast(i))});
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// The SoA invariant with no compiler behind it.
fn assertColumnsParallel(table: *const Violations) !void {
    const rows = table.rule.items.len;
    inline for (.{ "layer", "severity", "at", "kind", "measured", "limit", "shape_a", "shape_b" }) |name| {
        try testing.expectEqual(rows, @field(table, name).items.len);
    }
}

fn lineLess(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn freeLines(lines: *std.ArrayList([]u8)) void {
    for (lines.items) |l| gpa.free(l);
    lines.deinit(gpa);
}

test "sortCanonical orders by rule then layer then y then x then shapes" {
    // Oracle: construct-from-answer. The corpus is the cartesian product of
    // two values in each key field, enumerated in the promised order, so its
    // sorted form is known before any sort; shuffling makes the input
    // arbitrary.
    const rows = orderedCorpus();
    var expected = try tableOf(&rows);
    defer expected.deinit(gpa);
    for (0..16) |seed| {
        var actual = try sortedFromShuffle(&rows, seed);
        defer actual.deinit(gpa);
        try testgen.assertViolationsEq(&actual, &expected);
    }
}

test "sortCanonical gives one byte sequence whatever order the rows arrived in" {
    // Oracle: law, and the determinism gate. A total key makes the sorted
    // table a function of the set of rows, not of their arrival order.
    const rows = totalityCorpus();
    var first_table = try sortedFromShuffle(&rows, 0);
    defer first_table.deinit(gpa);
    const first = try render(&first_table);
    defer gpa.free(first);
    for (1..32) |seed| {
        var again_table = try sortedFromShuffle(&rows, seed);
        defer again_table.deinit(gpa);
        const again = try render(&again_table);
        defer gpa.free(again);
        try testgen.assertBytesIdentical("sortCanonical", first, again);
    }
}

test "sorting an already canonical table moves nothing" {
    // Oracle: law. Sorting under a total order is idempotent; the empty and
    // the one-row table are what a clean run produces.
    const rows = totalityCorpus();
    var table = try sortedFromShuffle(&rows, 101);
    defer table.deinit(gpa);
    const once = try render(&table);
    defer gpa.free(once);
    try table.sortCanonical(gpa);
    const twice = try render(&table);
    defer gpa.free(twice);
    try testgen.assertBytesIdentical("a second sortCanonical", once, twice);

    var empty: Violations = .{};
    try empty.sortCanonical(gpa);
    try testing.expectEqual(@as(u32, 0), empty.len());

    const single = orderedCorpus()[0..1];
    var one_row = try tableOf(single);
    defer one_row.deinit(gpa);
    try one_row.sortCanonical(gpa);
    var want = try tableOf(single);
    defer want.deinit(gpa);
    try testgen.assertViolationsEq(&one_row, &want);
}

test "sortCanonical preserves the multiset of rows" {
    // Oracle: law. A sort permutes; sorting one column apart from the rest
    // would leave rows that were never pushed. Compared as sorted renderings.
    const rows = totalityCorpus();
    var before = try tableOf(&rows);
    defer before.deinit(gpa);
    var after = try sortedFromShuffle(&rows, 77);
    defer after.deinit(gpa);
    var a: std.ArrayList([]u8) = .empty;
    defer freeLines(&a);
    var b: std.ArrayList([]u8) = .empty;
    defer freeLines(&b);
    for (0..before.len()) |i| try a.append(gpa, try std.fmt.allocPrint(gpa, "{any}", .{before.get(@intCast(i))}));
    for (0..after.len()) |i| try b.append(gpa, try std.fmt.allocPrint(gpa, "{any}", .{after.get(@intCast(i))}));
    std.mem.sortUnstable([]u8, a.items, {}, lineLess);
    std.mem.sortUnstable([]u8, b.items, {}, lineLess);
    for (a.items, b.items) |x, y| try testing.expectEqualStrings(x, y);
}

test "a pushed row reads back out of the columns unchanged" {
    // Oracle: law. `push` is the inverse of reading the columns back; `len`
    // counts what was pushed at every step, the empty table included.
    const rows = orderedCorpus();
    var table: Violations = .{};
    defer table.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), table.len());
    for (rows, 1..) |row, count| {
        try table.push(gpa, row);
        try testing.expectEqual(@as(u32, @intCast(count)), table.len());
    }
    try assertColumnsParallel(&table);
    var want = try tableOf(&rows);
    defer want.deinit(gpa);
    try testgen.assertViolationsEq(&table, &want);
}

test "get returns the row that was pushed at that index" {
    // Oracle: law. `get` and `push` are the two halves of one round trip.
    const rows = orderedCorpus();
    var table: Violations = .{};
    defer table.deinit(gpa);
    for (rows) |row| try table.push(gpa, row);
    for (rows, 0..) |row, i| try testing.expectEqualDeep(row, table.get(@intCast(i)));
}

test "concatenation order is invisible after the canonical sort" {
    // Oracle: law. The same rows split anywhere, extended in either order,
    // sort to the same table, and to the known answer; before the sort,
    // `extend` appends.
    const rows = orderedCorpus();
    var expected = try tableOf(&rows);
    defer expected.deinit(gpa);
    for (0..8) |seed| {
        var rng = Rng.init(seed);
        var shuffled = rows;
        rng.shuffle(Violation, &shuffled);
        const split: usize = @intCast(rng.below(shuffled.len));
        var head = try tableOf(shuffled[0..split]);
        defer head.deinit(gpa);
        var tail = try tableOf(shuffled[split..]);
        defer tail.deinit(gpa);

        var forwards = try tableOf(shuffled[0..split]);
        defer forwards.deinit(gpa);
        try forwards.extend(gpa, &tail);
        try assertColumnsParallel(&forwards);
        var whole = try tableOf(&shuffled);
        defer whole.deinit(gpa);
        try testgen.assertViolationsEq(&forwards, &whole);
        try forwards.sortCanonical(gpa);

        var backwards = try tableOf(shuffled[split..]);
        defer backwards.deinit(gpa);
        try backwards.extend(gpa, &head);
        try backwards.sortCanonical(gpa);

        try testgen.assertViolationsEq(&forwards, &expected);
        try testgen.assertViolationsEq(&backwards, &expected);
    }
}

test "extending by an empty table changes nothing" {
    // Oracle: law. Extending by an empty table is the identity: what a
    // gatherer does on every rule that found nothing.
    const rows = orderedCorpus();
    var table = try tableOf(&rows);
    defer table.deinit(gpa);
    const empty: Violations = .{};
    try table.extend(gpa, &empty);
    try assertColumnsParallel(&table);
    var want = try tableOf(&rows);
    defer want.deinit(gpa);
    try testgen.assertViolationsEq(&table, &want);
}

test "a warning never outranks an error" {
    // Oracle: the documented order, `warning < error`, so the max over a
    // run's findings is its worst.
    try testing.expect(@backingInt(Severity.warning) < @backingInt(Severity.@"error"));
    try testing.expectEqual(Severity.@"error", @as(Severity, @fromBackingInt(@max(@backingInt(Severity.@"error"), @backingInt(Severity.warning)))));
}

test "rows differing only in a ratio sort by its numeric value" {
    // Oracle: law. Rows equal in every key field but a ratio sort by the
    // ratio in numeric order, the sign deciding first: the input is the
    // answer reversed.
    const ratios = [_]f64{ -3.0, -0.5, -0.0, 0.25, 2.0, 1e300 };
    var rows: [ratios.len]Violation = undefined;
    for (&rows, 0..) |*r, i| r.* = .{
        .rule = @fromBackingInt(1),
        .layer = @fromBackingInt(1),
        .severity = .@"error",
        .at = point(0, 0),
        .measured = .ratio(ratios[ratios.len - 1 - i]),
        .limit = .ratio(0),
        .shape_a = @fromBackingInt(0),
        .shape_b = report.no_shape,
    };
    var table = try tableOf(&rows);
    defer table.deinit(gpa);
    try table.sortCanonical(gpa);
    for (ratios, 0..) |want, i| try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(table.get(@intCast(i)).measured.float())));
}

test "a fix hint follows its row through the sort, extend and truncate" {
    // Oracle: law. The sparse hint column is part of its row: after a sort
    // the row carrying the hint still carries it, `extend` offsets it, and
    // `truncate` drops it with its row.
    const rows = orderedCorpus();
    var table = try tableOf(&rows);
    defer table.deinit(gpa);
    try table.setFix(gpa, 5, .area(42));
    const tagged = table.get(5);
    var reversed: Violations = .{};
    defer reversed.deinit(gpa);
    var i: u32 = table.len();
    while (i > 0) {
        i -= 1;
        try reversed.pushRow(gpa, &table, i);
    }
    try reversed.sortCanonical(gpa);
    for (0..reversed.len()) |r| {
        const has = reversed.fixOf(@intCast(r)) != null;
        try testing.expectEqual(std.meta.eql(reversed.get(@intCast(r)), tagged), has);
    }
    try table.extend(gpa, &reversed);
    try testing.expect(table.fixOf(5 + rows.len) != null);
    table.truncate(rows.len);
    try testing.expectEqual(@as(usize, 1), table.fix_row.items.len);
}

test "a short's labels follow their row through the sort, extend and truncate" {
    // Oracle: law, as the fix hint's: the sparse label column is part of its
    // row through `pushRow`, the sort, `extend` and `truncate`.
    const rows = orderedCorpus();
    var table = try tableOf(&rows);
    defer table.deinit(gpa);
    const names: [2]geom.StrId = .{ @fromBackingInt(3), @fromBackingInt(4) };
    try table.setLabels(gpa, 5, names);
    const tagged = table.get(5);
    var reversed: Violations = .{};
    defer reversed.deinit(gpa);
    var i: u32 = table.len();
    while (i > 0) {
        i -= 1;
        try reversed.pushRow(gpa, &table, i);
    }
    try reversed.sortCanonical(gpa);
    for (0..reversed.len()) |r| {
        const has = reversed.labelsOf(@intCast(r));
        try testing.expectEqual(std.meta.eql(reversed.get(@intCast(r)), tagged), has != null);
        if (has) |got| try testing.expectEqual(names, got);
    }
    try table.extend(gpa, &reversed);
    try testing.expect(table.labelsOf(5 + rows.len) != null);
    table.truncate(rows.len);
    try testing.expectEqual(@as(usize, 1), table.label_row.items.len);
}
