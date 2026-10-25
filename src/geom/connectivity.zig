//! Connected components over an edge list, by union-find with union by rank
//! and path halving. In: a node count and undirected edges. Out: one label
//! per node, the least node of its component, so the labelling does not
//! depend on edge order. Ported from crates/geom/src/connectivity.rs.
//!
//! Contents:
//! - `pub fn componentsInto(gpa: Allocator, node_count: u32, edges: []const [2]u32, out: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Labels every node with its component's least node, into `out` (cleared
/// and refilled to `node_count` rows). Near-linear in nodes plus edges.
/// Asserts every edge names a node below `node_count`.
pub fn componentsInto(gpa: Allocator, node_count: u32, edges: []const [2]u32, out: *std.ArrayList(u32)) Allocator.Error!void {
    const parent = try gpa.alloc(u32, node_count);
    defer gpa.free(parent);
    // A tree height, at most log2(node_count) < 32 under union by rank.
    const rank = try gpa.alloc(u8, node_count);
    defer gpa.free(rank);
    try out.resize(gpa, node_count);

    for (parent, 0..) |*p, i| p.* = @intCast(i);
    @memset(rank, 0);
    for (edges) |e| {
        assert(e[0] < node_count and e[1] < node_count);
        const ra = find(parent, e[0]);
        const rb = find(parent, e[1]);
        if (ra == rb) continue;
        const lo, const hi = if (rank[ra] < rank[rb]) .{ ra, rb } else .{ rb, ra };
        parent[lo] = hi;
        rank[hi] += @intFromBool(rank[lo] == rank[hi]);
    }

    // Ascending: the first node of a component reached is its least. A
    // root's own row holds its component's label from then on, which is
    // also that row's answer; no other row is read before it is written.
    const label = out.items;
    @memset(label, std.math.maxInt(u32));
    for (0..node_count) |i| {
        const root = find(parent, @intCast(i));
        if (label[root] == std.math.maxInt(u32)) label[root] = @intCast(i);
        label[i] = label[root];
    }
}

// ---- private ----

/// The root of `node`, halving the path on the way.
fn find(parent: []u32, node: u32) u32 {
    var x = node;
    while (parent[x] != x) {
        const grand = parent[parent[x]];
        parent[x] = grand;
        x = grand;
    }
    return x;
}
