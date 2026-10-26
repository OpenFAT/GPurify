//! Clustering a large result set for triage (catalog FLOW-010): the
//! violations of one rule that lie together are one cluster, so a
//! systematic error (one cell placed a thousand times) reads as one line.
//! In: a violation table and a reach. Out: `Clusters`, CSR. Ported from
//! src/engine/triage.rs.
//!
//! Definition: single-linkage clustering (Sibson, "SLINK", The Computer
//! Journal 16(1), 1973) of each rule's markers under the Euclidean
//! distance: two markers of one rule at most `reach` apart are in one
//! cluster, and so is everything linked to them. Order: largest first, then
//! by rule id, then by lower-left corner, so the output depends only on the
//! violations. O(n·k): markers bucket into `reach`-sided cells and only the
//! 3 × 3 cells around one are searched.
//!
//! Contents:
//! - `pub const Clusters = struct`, `Clusters.deinit(c, gpa: Allocator) void`, `Clusters.len(c) u32`, `Clusters.rowsOf(c, k: u32) []const u32`
//! - `pub fn clusterInto(gpa: Allocator, violations: *const Violations, reach: Dbu, out: *Clusters) Allocator.Error!void`
//! - `pub fn root(parent: []u32, k: u32) u32`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Point = geom.Point;
const StrId = geom.StrId;
const Violations = @import("check").report.Violations;

/// Cluster `k` is `rule[k]` with violation rows
/// `rows[start[k]..start[k + 1]]` ascending, their markers' bbox `lo`..`hi`.
pub const Clusters = struct {
    rule: std.ArrayList(StrId) = .empty,
    lo: std.ArrayList(Point) = .empty,
    hi: std.ArrayList(Point) = .empty,
    start: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(u32) = .empty,

    pub fn deinit(c: *Clusters, gpa: Allocator) void {
        inline for (@typeInfo(Clusters).@"struct".field_names) |f| @field(c, f).deinit(gpa);
    }

    pub fn len(c: *const Clusters) u32 {
        return @intCast(c.rule.items.len);
    }

    pub fn rowsOf(c: *const Clusters, k: u32) []const u32 {
        return c.rows.items[c.start.items[k]..c.start.items[k + 1]];
    }
};

/// Orders rows by (rule, cell x, cell y), then row.
const Key = struct {
    v: *const Violations,
    side: i64,
    fn cell(k: @This(), row: u32) [3]i64 {
        const p = k.v.at.items[row];
        return .{ @backingInt(k.v.rule.items[row]), @divFloor(p.x, k.side), @divFloor(p.y, k.side) };
    }
    fn less(k: @This(), a: u32, b: u32) bool {
        return switch (std.mem.order(i64, &k.cell(a), &k.cell(b))) {
            .lt => true,
            .gt => false,
            .eq => a < b,
        };
    }
};

/// The single-linkage clusters of `violations` at `reach` grid units
/// (0 joins only markers at one point), into `out` (cleared first).
pub fn clusterInto(gpa: Allocator, violations: *const Violations, reach_in: Dbu, out: *Clusters) Allocator.Error!void {
    inline for (@typeInfo(Clusters).@"struct".field_names) |f| @field(out, f).clearRetainingCapacity();
    const reach = @max(reach_in, 0);
    const side = @max(reach, 1);
    const n = violations.len();
    const at = violations.at.items;
    // Rows by (rule, cell): one sort replaces the per-rule cell maps.
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const key: Key = .{ .v = violations, .side = side };
    std.mem.sort(u32, order, key, Key.less);
    const parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const reach2 = @as(i128, reach) * reach;
    for (order) |a| {
        const ca = key.cell(a);
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i64 = -1;
            while (dy <= 1) : (dy += 1) {
                const want: [3]i64 = .{ ca[0], ca[1] + dx, ca[2] + dy };
                for (cellRows(order, key, want)) |b| {
                    if (b <= a) continue;
                    const ex: i128 = at[a].x - at[b].x;
                    const ey: i128 = at[a].y - at[b].y;
                    if (ex * ex + ey * ey <= reach2) {
                        const ra = root(parent, a);
                        const rb = root(parent, b);
                        parent[@max(ra, rb)] = @min(ra, rb);
                    }
                }
            }
        }
    }
    // Each root's members ascending: rows ascend within each root.
    var members: std.ArrayList([2]u32) = .empty; // (root, row)
    defer members.deinit(gpa);
    for (0..n) |r| try members.append(gpa, .{ root(parent, @intCast(r)), @intCast(r) });
    std.mem.sort([2]u32, members.items, {}, lessPair);
    const Group = struct { first: u32, end: u32 };
    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(gpa);
    var s: u32 = 0;
    while (s < members.items.len) {
        var e = s;
        while (e < members.items.len and members.items[e][0] == members.items[s][0]) e += 1;
        try groups.append(gpa, .{ .first = s, .end = e });
        s = e;
    }
    const Ctx = struct {
        m: []const [2]u32,
        v: *const Violations,
        fn lo(c: @This(), g: Group) Point {
            var p = c.v.at.items[c.m[g.first][1]];
            for (c.m[g.first..g.end]) |r| p = .{ .x = @min(p.x, c.v.at.items[r[1]].x), .y = @min(p.y, c.v.at.items[r[1]].y) };
            return p;
        }
        fn less(c: @This(), a: Group, b: Group) bool {
            const sa = a.end - a.first;
            const sb = b.end - b.first;
            if (sa != sb) return sa > sb;
            const ra = @backingInt(c.v.rule.items[c.m[a.first][1]]);
            const rb = @backingInt(c.v.rule.items[c.m[b.first][1]]);
            if (ra != rb) return ra < rb;
            const la = c.lo(a);
            const lb = c.lo(b);
            return if (la.x != lb.x) la.x < lb.x else la.y < lb.y;
        }
    };
    const ctx: Ctx = .{ .m = members.items, .v = violations };
    std.mem.sort(Group, groups.items, ctx, Ctx.less);
    try out.start.append(gpa, 0);
    for (groups.items) |g| {
        var hi = at[members.items[g.first][1]];
        for (members.items[g.first..g.end]) |m| {
            try out.rows.append(gpa, m[1]);
            hi = .{ .x = @max(hi.x, at[m[1]].x), .y = @max(hi.y, at[m[1]].y) };
        }
        try out.rule.append(gpa, violations.rule.items[members.items[g.first][1]]);
        try out.lo.append(gpa, ctx.lo(g));
        try out.hi.append(gpa, hi);
        try out.start.append(gpa, @intCast(out.rows.items.len));
    }
}

/// The union-find root of `k`, halving the path.
pub fn root(parent: []u32, k_in: u32) u32 {
    var k = k_in;
    while (parent[k] != k) {
        parent[k] = parent[parent[k]];
        k = parent[k];
    }
    return k;
}

// ---- private ----

/// The rows of `order` (sorted by `key`) in cell `want`.
fn cellRows(order: []const u32, key: Key, want: [3]i64) []const u32 {
    const Probe = struct {
        key: Key,
        want: [3]i64,
        fn below(p: @This(), row: u32) bool {
            return std.mem.order(i64, &p.key.cell(row), &p.want) == .lt;
        }
        fn atMost(p: @This(), row: u32) bool {
            return std.mem.order(i64, &p.key.cell(row), &p.want) != .gt;
        }
    };
    const probe: Probe = .{ .key = key, .want = want };
    const from = std.sort.partitionPoint(u32, order, probe, Probe.below);
    const to = std.sort.partitionPoint(u32, order, probe, Probe.atMost);
    return order[from..to];
}

fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
    return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
}
