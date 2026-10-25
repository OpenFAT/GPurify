//! Connected components, and the one property that makes their output usable
//! as a net label: the label is the least node in the component. Ported from
//! crates/geom/tests/core/connectivity_components.rs.
//!
//! Any correct union-find partitions the nodes. Only a canonical labelling
//! gives the same labels twice, and `topology` compares extracted nets by
//! label rather than by set. So the tests assert the label and not merely the
//! partition, and shuffle the edge list before every comparison.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const graphWithPartition = testgen.graph.graphWithPartition;
const componentsInto = geom.connectivity.componentsInto;

const gpa = testing.allocator;

// ---- private ----

/// Components are named by their least node, the one row labelled with itself.
fn componentCount(labels: []const u32) u32 {
    var n: u32 = 0;
    for (labels, 0..) |l, i| n += @intFromBool(l == i);
    return n;
}

test "every node is labelled with the minimum index in its component" {
    // Oracle: construct-from-answer. The generator deals nodes into components of
    // stated sizes before drawing an edge, so the partition and every label are
    // facts about how the graph was built. Nodes are dealt by a shuffled
    // assignment, so a component is not a contiguous block of indices and an
    // implementation that labels by block fails.
    var rng = Rng.init(71);
    var case = try graphWithPartition(gpa, &rng, &.{ 1, 2, 5, 13, 1, 40, 7 }, 60);
    defer case.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try componentsInto(gpa, case.node_count, case.edges, &labels);
    try testing.expectEqualSlices(u32, case.expected, labels.items);
    try testing.expectEqual(@as(u32, 7), componentCount(labels.items));
    // The same claim stated as sets, which is what catches a labelling that
    // happened to agree numerically while merging the wrong nodes.
    for (0..7) |k| {
        const m = case.component(k);
        for (m) |node| try testing.expectEqual(std.mem.min(u32, m), labels.items[node]);
    }
}

test "a label is always a node that carries that same label" {
    // Oracle: law. The label of a component is the minimum index in it, by
    // definition, so the property is checkable from the output alone without
    // consulting the generator's answer. Over a graph with an isolated node, a
    // pair, and a large component, all interleaved in the index space.
    var rng = Rng.init(72);
    var case = try graphWithPartition(gpa, &rng, &.{ 1, 2, 3, 30, 1, 1, 19 }, 45);
    defer case.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try componentsInto(gpa, case.node_count, case.edges, &labels);
    try testing.expectEqual(@as(usize, case.node_count), labels.items.len);
    for (labels.items, 0..) |label, node| {
        try testing.expect(label <= node);
        try testing.expectEqual(label, labels.items[label]);
    }
    // Every edge joins two nodes with the same label. Together with the
    // minimality above, that is the definition of a connected component.
    for (case.edges) |e| try testing.expectEqual(labels.items[e[0]], labels.items[e[1]]);
}

test "two edge orderings of one graph give identical labels" {
    // Oracle: law. The labels are a function of the graph, not of the order its
    // edges arrived in. Shuffling with the seeded generator is what turns that
    // promise into something a test can fail; a fixture with a sorted edge list
    // cannot.
    var rng = Rng.init(73);
    var case = try graphWithPartition(gpa, &rng, &.{ 9, 4, 17, 1, 25 }, 80);
    defer case.deinit(gpa);
    var reference: std.ArrayList(u32) = .empty;
    defer reference.deinit(gpa);
    try componentsInto(gpa, case.node_count, case.edges, &reference);
    const shuffled = try gpa.dupe([2]u32, case.edges);
    defer gpa.free(shuffled);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    for (0..12) |_| {
        rng.shuffle([2]u32, shuffled);
        // Transposing endpoints too: the edge list is undirected, so `(a, b)`
        // and `(b, a)` are the same edge and must produce the same labels.
        for (shuffled) |*e| {
            const was = e.*;
            if (rng.unit() < 0.5) e.* = .{ was[1], was[0] };
        }
        try componentsInto(gpa, case.node_count, shuffled, &labels);
        try testing.expectEqualSlices(u32, reference.items, labels.items);
    }
}

test "an empty edge list leaves every node in its own component" {
    // Oracle: construct-from-answer. With no edges every node is alone, so its
    // label is itself and the component count is the node count. This is the case
    // an implementation that never initialises its parent array silently gets
    // wrong, and the one an isolated node in a larger graph hides.
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    for ([_]u32{ 0, 1, 2, 37 }) |node_count| {
        try componentsInto(gpa, node_count, &.{}, &labels);
        try testing.expectEqual(@as(usize, node_count), labels.items.len);
        for (labels.items, 0..) |label, i| try testing.expectEqual(@as(u32, @intCast(i)), label);
        try testing.expectEqual(node_count, componentCount(labels.items));
    }
}

test "component count is the number of distinct labels" {
    // Oracle: closed form. A path of `n` nodes is one component; `n` disjoint
    // pairs are `n` components; a star is one. Each answer is arithmetic on the
    // construction, so `component_count` is checked against a number the test
    // derived rather than against a rerun of the labelling.
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    // A path through every node, joined back to front so the edge list is
    // not in index order.
    var path: [49][2]u32 = undefined;
    for (&path, 1..) |*e, n| e.* = .{ @intCast(50 - n), @intCast(49 - n) };
    try componentsInto(gpa, 50, &path, &labels);
    try testing.expectEqual(@as(u32, 1), componentCount(labels.items));
    for (labels.items) |l| try testing.expectEqual(@as(u32, 0), l);

    // Twenty-five disjoint pairs. The label of each is its lower node.
    var pairs: [25][2]u32 = undefined;
    for (&pairs, 0..) |*e, n| e.* = .{ @intCast(2 * n + 1), @intCast(2 * n) };
    try componentsInto(gpa, 50, &pairs, &labels);
    try testing.expectEqual(@as(u32, 25), componentCount(labels.items));
    for (0..25) |n| {
        try testing.expectEqual(@as(u32, @intCast(2 * n)), labels.items[2 * n]);
        try testing.expectEqual(@as(u32, @intCast(2 * n)), labels.items[2 * n + 1]);
    }

    // A star centred on the highest node: everything still labels to zero,
    // because the label is the minimum index and not the root the union-find
    // happened to choose.
    var star: [49][2]u32 = undefined;
    for (&star, 0..) |*e, n| e.* = .{ 49, @intCast(n) };
    try componentsInto(gpa, 50, &star, &labels);
    try testing.expectEqual(@as(u32, 1), componentCount(labels.items));
    for (labels.items) |l| try testing.expectEqual(@as(u32, 0), l);
}

test "redundant edges inside a component change nothing" {
    // Oracle: law. Redundant edges are no-ops. Adding an edge inside a component
    // that is already connected cannot change a single label, whatever order the
    // redundant edges arrive in — which is the union-find's "both nodes already
    // found" path, and the one place a rank or path-halving bug shows up.
    const sizes = [_]u32{ 6, 1, 14, 3, 22 };
    var rng = Rng.init(74);
    var sparse = try graphWithPartition(gpa, &rng, &sizes, 0);
    defer sparse.deinit(gpa);
    var reference: std.ArrayList(u32) = .empty;
    defer reference.deinit(gpa);
    try componentsInto(gpa, sparse.node_count, sparse.edges, &reference);
    try testing.expectEqualSlices(u32, sparse.expected, reference.items);

    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var densest: usize = 0;
    for ([_]u32{ 1, 10, 200 }) |extra| {
        var again = Rng.init(74);
        var dense = try graphWithPartition(gpa, &again, &sizes, extra);
        defer dense.deinit(gpa);
        try componentsInto(gpa, dense.node_count, dense.edges, &labels);
        try testing.expectEqualSlices(u32, reference.items, labels.items);
        densest = dense.edges.len;
    }
    try testing.expect(densest > sparse.edges.len);
}

test "two runs agree and the output buffer is refilled not appended to" {
    // Oracle: determinism. Two runs of the labelling on one graph must be
    // identical, and the output buffer is cleared and refilled rather than
    // appended to — which is what lets a caller hoist one buffer above a loop over
    // nets. Filling it with a wrong answer first is how that gets checked.
    var rng = Rng.init(75);
    var case = try graphWithPartition(gpa, &rng, &.{ 11, 2, 33, 1 }, 40);
    defer case.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try labels.appendNTimes(gpa, std.math.maxInt(u32), 500);
    try componentsInto(gpa, case.node_count, case.edges, &labels);
    try testing.expectEqual(@as(usize, case.node_count), labels.items.len);
    const first = try gpa.dupe(u32, labels.items);
    defer gpa.free(first);
    try componentsInto(gpa, case.node_count, case.edges, &labels);
    try testing.expectEqualSlices(u32, first, labels.items);
    try testing.expectEqualSlices(u32, case.expected, labels.items);
}
