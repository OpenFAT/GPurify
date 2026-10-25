//! Graphs whose connected components are known before anything runs. In:
//! component sizes and a seeded `Rng`. Out: a `GraphCase` (edges, the label
//! every node must get, the members of each component). Node-to-component
//! assignment and the edge list are both shuffled, so a component is never
//! a contiguous block of indices and no test depends on edge order. Ported
//! from crates/testgen/src/graph.rs.
//!
//! Contents:
//! - `pub const GraphCase = struct`, `GraphCase.deinit(c: *GraphCase, gpa: Allocator) void`,
//!   `GraphCase.component(c: *const GraphCase, k: usize) []const u32`
//! - `pub fn graphWithPartition(gpa: Allocator, rng: *Rng, sizes: []const u32, extra_edges: u32) Allocator.Error!GraphCase`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Rng = @import("rng.zig").Rng;

/// A graph and its partition. Component `k`'s members, ascending, are
/// `members[start[k]..start[k + 1]]`, in the requested size order.
pub const GraphCase = struct {
    node_count: u32,
    /// Undirected, shuffled, with both endpoint orders occurring.
    edges: [][2]u32,
    /// `expected[n]` is the least node of `n`'s component.
    expected: []u32,
    members: []u32,
    start: []u32,

    pub fn deinit(c: *GraphCase, gpa: Allocator) void {
        gpa.free(c.edges);
        gpa.free(c.expected);
        gpa.free(c.members);
        gpa.free(c.start);
    }

    pub fn component(c: *const GraphCase, k: usize) []const u32 {
        return c.members[c.start[k]..c.start[k + 1]];
    }
};

/// A graph whose components have exactly `sizes`: each a random spanning
/// tree plus, over all components, up to `extra_edges` redundant edges
/// (self-loops and repeats allowed; a draw on a singleton adds nothing).
/// The same `rng` state gives the same graph, edge order included. Asserts
/// a non-empty `sizes` with no zero.
pub fn graphWithPartition(gpa: Allocator, rng: *Rng, sizes: []const u32, extra_edges: u32) Allocator.Error!GraphCase {
    assert(sizes.len > 0);
    var node_count: u32 = 0;
    for (sizes) |s| {
        assert(s > 0);
        node_count += s;
    }

    // Shuffling the deal stops a component being a contiguous index block.
    const owner = try gpa.alloc(u32, node_count);
    defer gpa.free(owner);
    var at: usize = 0;
    for (sizes, 0..) |s, k| {
        @memset(owner[at..][0..s], @intCast(k));
        at += s;
    }
    rng.shuffle(u32, owner);

    const start = try gpa.alloc(u32, sizes.len + 1);
    errdefer gpa.free(start);
    start[0] = 0;
    for (sizes, 0..) |s, k| start[k + 1] = start[k] + s;
    const members = try gpa.alloc(u32, node_count);
    errdefer gpa.free(members);
    const cursor = try gpa.dupe(u32, start[0..sizes.len]);
    defer gpa.free(cursor);
    for (owner, 0..) |k, node| {
        members[cursor[k]] = @intCast(node);
        cursor[k] += 1;
    }

    var edges: std.ArrayList([2]u32) = .empty;
    errdefer edges.deinit(gpa);
    // A spanning tree per component: member `i` joins a uniformly chosen
    // earlier member, the sparsest edge set that still connects it.
    for (0..sizes.len) |k| {
        const m = members[start[k]..start[k + 1]];
        for (1..m.len) |i| try edges.append(gpa, .{ m[rng.below(i)], m[i] });
    }
    // Redundant edges, drawn within a component so the partition holds.
    for (0..extra_edges) |_| {
        const k = rng.below(sizes.len);
        const m = members[start[k]..start[k + 1]];
        if (m.len < 2) continue;
        const a = rng.below(m.len);
        const b = rng.below(m.len);
        try edges.append(gpa, .{ m[a], m[b] });
    }
    // Half the edges transposed: the list is undirected, never ascending.
    for (edges.items) |*e| {
        // Copied first: `e.* = .{ e[1], e[0] }` would read the slot it just wrote.
        const was = e.*;
        if (rng.unit() < 0.5) e.* = .{ was[1], was[0] };
    }
    rng.shuffle([2]u32, edges.items);

    const expected = try gpa.alloc(u32, node_count);
    errdefer gpa.free(expected);
    for (0..sizes.len) |k| {
        const m = members[start[k]..start[k + 1]];
        for (m) |node| expected[node] = m[0];
    }
    return .{
        .node_count = node_count,
        .edges = try edges.toOwnedSlice(gpa),
        .expected = expected,
        .members = members,
        .start = start,
    };
}

test "no edge crosses a component and every component is connected" {
    // Oracle: differential against an independent flood fill over the edges,
    // and the dealt partition: every edge joins two nodes of one component.
    const gpa = std.testing.allocator;
    var rng = Rng.init(42);
    var case = try graphWithPartition(gpa, &rng, &.{ 1, 5, 12, 3, 40 }, 25);
    defer case.deinit(gpa);
    for (case.edges) |e| try std.testing.expectEqual(case.expected[e[0]], case.expected[e[1]]);

    // Flood fill by repeated relaxation, not the union-find under test.
    const seen = try gpa.alloc(bool, case.node_count);
    defer gpa.free(seen);
    for (0..case.start.len - 1) |k| {
        const m = case.component(k);
        @memset(seen, false);
        seen[m[0]] = true;
        var grew = true;
        while (grew) {
            grew = false;
            for (case.edges) |e| {
                if (seen[e[0]] != seen[e[1]]) {
                    seen[e[0]] = true;
                    seen[e[1]] = true;
                    grew = true;
                }
            }
        }
        try std.testing.expectEqual(m.len, std.mem.count(bool, seen, &.{true}));
    }
}

test "every label is the minimum index of its component" {
    // Oracle: the generator's documented labelling, recomputed from the dealt
    // members: each label is the minimum node index of its component.
    const gpa = std.testing.allocator;
    var rng = Rng.init(9);
    var case = try graphWithPartition(gpa, &rng, &.{ 7, 7, 7 }, 10);
    defer case.deinit(gpa);
    for (0..3) |k| {
        const m = case.component(k);
        for (m) |node| try std.testing.expectEqual(std.mem.min(u32, m), case.expected[node]);
    }
}
