//! Triage clustering against hand-derived and brute-force answers. Ported
//! from src/engine/triage.rs's tests.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const testgen = @import("testgen");
const triage = @import("gpurify").triage;
const gpa = testing.allocator;

// ---- private ----

fn table(rows: []const [3]i64) !check.report.Violations {
    var out: check.report.Violations = .{};
    errdefer out.deinit(gpa);
    for (rows) |r| try out.push(gpa, .{ .rule = @fromBackingInt(@as(u32, @intCast(r[0]))), .layer = @fromBackingInt(0), .severity = .@"error", .at = .{ .x = r[1], .y = r[2] }, .measured = .count(0), .limit = .count(1), .shape_a = @fromBackingInt(0), .shape_b = check.report.no_shape });
    return out;
}

test "a chain links and a far marker stays alone" {
    // Oracle: hand-derived single linkage at reach 10: a chain 0–8–16 is one
    // cluster though its ends are 16 apart; a marker 11 away stays alone;
    // another rule's marker on the chain is its own cluster; largest first.
    var v = try table(&.{ .{ 1, 0, 0 }, .{ 1, 8, 0 }, .{ 1, 16, 0 }, .{ 1, 27, 0 }, .{ 2, 8, 0 } });
    defer v.deinit(gpa);
    var c: triage.Clusters = .{};
    defer c.deinit(gpa);
    try triage.clusterInto(gpa, &v, 10, &c);
    try testing.expectEqual(3, c.len());
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, c.rowsOf(0));
    try testing.expectEqualSlices(u32, &.{3}, c.rowsOf(1));
    try testing.expectEqualSlices(u32, &.{4}, c.rowsOf(2));
    try testing.expectEqual(0, c.lo.items[0].x);
    try testing.expectEqual(16, c.hi.items[0].x);
}

test "clusters match a brute-force flood fill" {
    // Oracle: naive reference (catalog FLOW-010): on 40 seeded tables the
    // clusters are the connected components of the "same rule and at most
    // reach apart" graph, found by flood fill over all pairs.
    for (0..40) |seed| {
        var rng: testgen.Rng = .init(seed);
        const n: usize = @intCast(rng.range(1, 60));
        var rows: [60][3]i64 = undefined;
        for (rows[0..n]) |*r| r.* = .{ rng.range(0, 3), rng.range(-100, 100), rng.range(-100, 100) };
        const reach = rng.range(0, 30);
        var v = try table(rows[0..n]);
        defer v.deinit(gpa);
        var c: triage.Clusters = .{};
        defer c.deinit(gpa);
        try triage.clusterInto(gpa, &v, reach, &c);
        // Label of each row by the clusters, and by flood fill.
        var got: [60]u32 = undefined;
        for (0..c.len()) |k| for (c.rowsOf(@intCast(k))) |r| {
            got[r] = @intCast(k);
        };
        var want: [60]?u32 = @splat(null);
        var label: u32 = 0;
        for (0..n) |start| {
            if (want[start] != null) continue;
            var stack: [60]usize = undefined;
            var top: usize = 1;
            stack[0] = start;
            want[start] = label;
            while (top > 0) {
                top -= 1;
                const a = stack[top];
                for (0..n) |b| if (want[b] == null and rows[a][0] == rows[b][0] and
                    (rows[a][1] - rows[b][1]) * (rows[a][1] - rows[b][1]) + (rows[a][2] - rows[b][2]) * (rows[a][2] - rows[b][2]) <= reach * reach)
                {
                    want[b] = label;
                    stack[top] = b;
                    top += 1;
                };
            }
            label += 1;
        }
        try testing.expectEqual(label, c.len());
        // Same partition: two rows share a cluster exactly when they share a component.
        for (0..n) |a| for (0..n) |b| try testing.expectEqual(want[a].? == want[b].?, got[a] == got[b]);
    }
}
