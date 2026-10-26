//! A net's polygons, from the per-polygon net column. In: `poly_net` (check's
//! `NetTable` column, `stack.none` for a polygon on no net) and the net
//! count. Out: `NetPolys`, each net's rows ascending, as CSR. The field
//! solver reads nets through this, never through check's types.
//!
//! Contents:
//! - `pub const NetPolys = struct`, `NetPolys.empty`, `deinit`,
//!   `buildInto(np: *NetPolys, gpa: Allocator, poly_net: []const u32, net_count: u32) Allocator.Error!void`,
//!   `polysOf(np: *const NetPolys, net: u32) []const PolyId`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const PolyId = geom.PolyId;
const none = @import("stack.zig").none;

/// `polys[start[n]..start[n + 1]]` is net `n`'s rows, ascending.
pub const NetPolys = struct {
    start: std.ArrayList(u32) = .empty,
    polys: std.ArrayList(PolyId) = .empty,

    pub const empty: NetPolys = .{};

    pub fn deinit(np: *NetPolys, gpa: Allocator) void {
        np.start.deinit(gpa);
        np.polys.deinit(gpa);
    }

    /// Clears and refills from `poly_net`. Asserts every net below
    /// `net_count` or `none`.
    pub fn buildInto(np: *NetPolys, gpa: Allocator, poly_net: []const u32, net_count: u32) Allocator.Error!void {
        assert(poly_net.len < none);
        try np.start.resize(gpa, @as(usize, net_count) + 2);
        @memset(np.start.items, 0);
        for (poly_net) |net| {
            if (net == none) continue;
            assert(net < net_count);
            np.start.items[net + 2] += 1;
        }
        // Exclusive scan shifted by one, so the fill below bumps `start[n + 1]`
        // to the end of net `n`.
        for (2..np.start.items.len) |n| np.start.items[n] += np.start.items[n - 1];
        try np.polys.resize(gpa, np.start.items[np.start.items.len - 1]);
        for (poly_net, 0..) |net, row| {
            if (net == none) continue;
            np.polys.items[np.start.items[net + 1]] = @fromBackingInt(@intCast(row));
            np.start.items[net + 1] += 1;
        }
        np.start.shrinkRetainingCapacity(@as(usize, net_count) + 1);
    }

    /// Net `net`'s rows, ascending; empty for `none` or a net past the table.
    pub fn polysOf(np: *const NetPolys, net: u32) []const PolyId {
        if (net >= np.start.items.len -| 1) return &.{};
        return np.polys.items[np.start.items[net]..np.start.items[net + 1]];
    }
};

test "a net's rows come back ascending and a row on no net nowhere" {
    // Oracle: hand-derived. Rows 0..5 on nets 1, none, 0, 1, 0: net 0 holds
    // rows 2 and 4, net 1 rows 0 and 3, and `none` holds nothing.
    const gpa = std.testing.allocator;
    var np: NetPolys = .empty;
    defer np.deinit(gpa);
    try np.buildInto(gpa, &.{ 1, none, 0, 1, 0 }, 2);
    const want0 = [_]PolyId{ @fromBackingInt(2), @fromBackingInt(4) };
    const want1 = [_]PolyId{ @fromBackingInt(0), @fromBackingInt(3) };
    try std.testing.expectEqualSlices(PolyId, &want0, np.polysOf(0));
    try std.testing.expectEqualSlices(PolyId, &want1, np.polysOf(1));
    try std.testing.expectEqual(0, np.polysOf(none).len);
}
