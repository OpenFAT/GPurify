//! The parasitic network table: canonical element order and per-net
//! capacitance summed in that order. Ported from
//! crates/extract/tests/pex/network.rs.
//!
//! Contents: helpers `nodesAcross`, `nodesOn`, `cap`, `serialise`, `Element`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const network = extract.network;
const NodeId = network.NodeId;
const ParasiticNetwork = network.ParasiticNetwork;
const gpa = testing.allocator;

const Element = struct { from: NodeId, to: NodeId, kind: network.Kind, value: f64 };

// ---- private ----

/// A network whose nodes sit on the listed nets, one node per entry.
fn nodesAcross(nets: []const u32) !ParasiticNetwork {
    var n: ParasiticNetwork = .empty;
    try n.node_net.appendSlice(gpa, nets);
    try n.node_layer.appendNTimes(gpa, @fromBackingInt(0), nets.len);
    return n;
}

/// A network of `count` nodes, all on `net`.
fn nodesOn(net: u32, count: usize) !ParasiticNetwork {
    var n: ParasiticNetwork = .empty;
    try n.node_net.appendNTimes(gpa, net, count);
    try n.node_layer.appendNTimes(gpa, @fromBackingInt(0), count);
    return n;
}

fn cap(n: *const ParasiticNetwork, net: usize) !f64 {
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try n.capacitancePerNetInto(gpa, &totals);
    return if (net < totals.items.len) totals.items[net] else 0.0;
}

fn serialise(n: *const ParasiticNetwork, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.node_net.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.node_layer.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.from.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.to.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.kind.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.value.items));
}

test "net capacitance is the sum of the capacitive elements on that net" {
    // Oracle: closed form. A net carrying 1.5 fF and 2.25 fF to ground and
    // 0.75 fF of coupling holds 4.5 fF, which is addition; a resistor large
    // enough to be obvious sits in the same network and must not count.
    var n = try nodesAcross(&.{ 0, 0, 1 });
    defer n.deinit(gpa);
    try n.push(gpa, .at(0), .ground, .ground_cap, 1.5);
    try n.push(gpa, .at(1), .ground, .ground_cap, 2.25);
    try n.push(gpa, .at(0), .at(2), .coupling_cap, 0.75);
    try n.push(gpa, .at(2), .ground, .ground_cap, 10.0);
    try n.push(gpa, .at(0), .at(1), .resistance, 1_000.0);
    try testing.expectApproxEqAbs(@as(f64, 4.5), try cap(&n, 0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10.75), try cap(&n, 1), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try cap(&n, 2), 1e-12);
}

test "net capacitance is additive over the elements pushed" {
    // Oracle: law. Capacitance to ground is additive, so every element pushed
    // twice holds twice the capacitance, over seeded arbitrary values.
    var rng: Rng = .init(31);
    var once = try nodesOn(0, 8);
    defer once.deinit(gpa);
    var twice = try nodesOn(0, 8);
    defer twice.deinit(gpa);
    for (0..8) |i| {
        const value = 0.1 + rng.unit();
        try once.push(gpa, .at(i), .ground, .ground_cap, value);
        try twice.push(gpa, .at(i), .ground, .ground_cap, value);
        try twice.push(gpa, .at(i), .ground, .ground_cap, value);
    }
    const single = try cap(&once, 0);
    try testing.expect(single > 0.0);
    try testing.expectApproxEqRel(2.0 * single, try cap(&twice, 0), 1e-12);
}

test "sort canonical maps every permutation of the same rows to the same bytes" {
    // Oracle: law. Canonical order is a function of the rows, so any
    // permutation of them sorts to the same bytes: the determinism gate the
    // old tree's hash-map order failed.
    var rng: Rng = .init(37);
    var rows: [18]Element = undefined;
    for (0..6) |i| {
        rows[3 * i] = .{ .from = .at(i), .to = .ground, .kind = .ground_cap, .value = 0.5 + rng.unit() };
        rows[3 * i + 1] = .{ .from = .at(i), .to = .at(i + 1), .kind = .resistance, .value = 1.0 + rng.unit() };
        rows[3 * i + 2] = .{ .from = .at(i), .to = .at(i + 1), .kind = .coupling_cap, .value = rng.unit() };
    }
    var reference = try nodesOn(0, 8);
    defer reference.deinit(gpa);
    for (rows) |r| try reference.push(gpa, r.from, r.to, r.kind, r.value);
    try reference.sortCanonical(gpa);
    var canonical: std.ArrayList(u8) = .empty;
    defer canonical.deinit(gpa);
    try serialise(&reference, &canonical);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (0..8) |_| {
        var shuffled = rows;
        rng.shuffle(Element, &shuffled);
        var n = try nodesOn(0, 8);
        defer n.deinit(gpa);
        for (shuffled) |r| try n.push(gpa, r.from, r.to, r.kind, r.value);
        try n.sortCanonical(gpa);
        try serialise(&n, &bytes);
        try testing.expectEqualSlices(u8, canonical.items, bytes.items);
    }
}

test "sort canonical is idempotent and preserves every row" {
    // Oracle: law. Sorting a sorted table is the identity, and sorting never
    // invents, drops or alters a row: the element count and total
    // capacitance are the same either side of it.
    var rng: Rng = .init(41);
    var n = try nodesOn(0, 5);
    defer n.deinit(gpa);
    for (0..4) |i| {
        try n.push(gpa, .at(i + 1), .ground, .ground_cap, rng.unit() + 0.25);
        try n.push(gpa, .at(i), .at(i + 1), .resistance, rng.unit() + 1.0);
    }
    const elements = n.elementCount();
    const capacitance = try cap(&n, 0);
    try n.sortCanonical(gpa);
    var once: std.ArrayList(u8) = .empty;
    defer once.deinit(gpa);
    try serialise(&n, &once);
    try testing.expectEqual(elements, n.elementCount());
    try testing.expectApproxEqRel(capacitance, try cap(&n, 0), 1e-12);
    try n.sortCanonical(gpa);
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    try serialise(&n, &again);
    try testing.expectEqualSlices(u8, once.items, again.items);
}

test "sort canonical orders by from then by to with ground first" {
    // Oracle: law. The stated order is by `from`, then by `to` with ground
    // first; asserting the predicate stops the permutation test above from
    // being met by any stable order at all.
    var n = try nodesOn(0, 5);
    defer n.deinit(gpa);
    try n.push(gpa, .at(3), .at(4), .resistance, 2.0);
    try n.push(gpa, .at(1), .ground, .ground_cap, 1.0);
    try n.push(gpa, .at(3), .ground, .ground_cap, 3.0);
    try n.push(gpa, .at(0), .at(2), .resistance, 4.0);
    try n.push(gpa, .at(1), .at(2), .coupling_cap, 5.0);
    try n.sortCanonical(gpa);
    var last: [2]u64 = .{ 0, 0 };
    for (n.from.items, n.to.items) |from, to| {
        const key = [2]u64{ @backingInt(from), if (to == .ground) 0 else @as(u64, @backingInt(to)) + 1 };
        try testing.expect(key[0] > last[0] or (key[0] == last[0] and key[1] >= last[1]));
        last = key;
    }
}

test "capacitance per net matches a per net fold bit for bit" {
    // Oracle: one strict fold per net over every element, the definition:
    // the one-pass totals match it bit for bit, a coupling counts on both
    // nets, a net with no node holds +0, and a node past the column counts
    // nowhere.
    var rng: Rng = .init(97);
    var n = try nodesAcross(&.{ 0, 0, 2, 3, 3 });
    defer n.deinit(gpa);
    for (0..64) |_| {
        const from: NodeId = .at(rng.below(5));
        const to: NodeId = .at(rng.below(5));
        switch (rng.below(3)) {
            0 => try n.push(gpa, from, .ground, .ground_cap, rng.unit()),
            1 => try n.push(gpa, from, to, .coupling_cap, rng.unit()),
            else => try n.push(gpa, from, to, .resistance, rng.unit()),
        }
    }
    try n.push(gpa, .at(9), .ground, .ground_cap, 100.0);
    try n.sortCanonical(gpa);
    var all: std.ArrayList(f64) = .empty;
    defer all.deinit(gpa);
    try n.capacitancePerNetInto(gpa, &all);
    try testing.expectEqual(4, all.items.len);
    for (all.items, 0..) |total, net_index| {
        const net: u32 = @intCast(net_index);
        var expected: f64 = 0.0;
        for (n.from.items, n.to.items, n.kind.items, n.value.items) |from, to, kind, value| {
            if (kind != .ground_cap and kind != .coupling_cap) continue;
            const near: ?u32 = if (@backingInt(from) < 5) n.node_net.items[@backingInt(from)] else null;
            const far: ?u32 = if (to == .ground) near else if (@backingInt(to) < 5) n.node_net.items[@backingInt(to)] else null;
            if (near == net or far == net) expected += value;
        }
        try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(total)));
    }
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(all.items[1])));
    for (all.items) |c| try testing.expect(c < 100.0);
}
