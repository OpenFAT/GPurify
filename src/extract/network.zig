//! The extracted parasitic network, as SoA node and element columns. In:
//! elements pushed by the extraction methods. Out: the table the SPEF, DSPF
//! and SPICE writers read, sorted canonically. Ported from
//! crates/extract/src/network.rs (its data types and the operations the
//! field-solve readout needs).
//!
//! A `NodeId` is a row of the node columns, so it means something only
//! inside the network that issued it. Rust's `Parasitic` enum of typed
//! quantities is two columns here: `kind` and `value`, the value at the
//! kind's fixed unit (ohms, femtofarads, picohenries).
//!
//! Contents:
//! - `pub const NodeId = enum(u32)`, `NodeId.ground`, `NodeId.at(index: usize) NodeId`
//! - `pub const Kind = enum(u8) { resistance, ground_cap, coupling_cap, inductance, mutual_inductance, substrate_resistance }`
//! - `pub const ParasiticNetwork = struct`, `ParasiticNetwork.empty`, `deinit`, `clear`, `nodeCount`, `elementCount`,
//!   `push(n: *ParasiticNetwork, gpa: Allocator, from: NodeId, to: NodeId, kind: Kind, value: f64) Allocator.Error!void`,
//!   `firstNode(n, net: u32) ?NodeId`, `sortCanonical(n: *ParasiticNetwork, gpa: Allocator) Allocator.Error!void`,
//!   `capacitancePerNetInto(n, gpa: Allocator, out: *std.ArrayList(f64)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;

/// A node: a row of `ParasiticNetwork.node_net`. `ground` stands for the
/// substrate as an element's far node.
pub const NodeId = enum(u32) {
    ground = std.math.maxInt(u32),
    _,

    /// The node at row `index`; asserts it fits below `ground`.
    pub fn at(index: usize) NodeId {
        assert(index < std.math.maxInt(u32));
        return @fromBackingInt(@intCast(index));
    }
};

/// One element's kind, at a fixed unit per kind: ohms, femtofarads,
/// picohenries. Its order is the canonical order's kind order.
pub const Kind = enum(u8) {
    /// Series resistance between two nodes of one net.
    resistance,
    /// Capacitance from a net to ground, the substrate.
    ground_cap,
    /// Capacitance between two different nets.
    coupling_cap,
    /// Series inductance of a field-solved net, between its two nodes.
    inductance,
    /// Mutual inductance between two field-solved nets' series inductances:
    /// near node the first net's, far node the second's, each its
    /// inductance's near node (the SPICE dot convention). Signed.
    mutual_inductance,
    /// Resistance through the silicon between two nets' substrate contacts,
    /// or from one to the grounded backside.
    substrate_resistance,
};

/// Invariant: every net's nodes occupy one contiguous run of `node_net`, in
/// ascending net order, and the elements are in canonical order
/// (`sortCanonical`). The extraction entry points establish both; `push`
/// checks neither.
pub const ParasiticNetwork = struct {
    /// The net of each node.
    node_net: std.ArrayList(u32) = .empty,
    /// The layer of each node: the layer of the polygon an analytical node
    /// starts, or a field-solved net's lowest layer.
    node_layer: std.ArrayList(LayerId) = .empty,
    /// Each element's near node.
    from: std.ArrayList(NodeId) = .empty,
    /// Each element's far node, `ground` only for a ground capacitance or a
    /// substrate resistance.
    to: std.ArrayList(NodeId) = .empty,
    kind: std.ArrayList(Kind) = .empty,
    value: std.ArrayList(f64) = .empty,

    pub const empty: ParasiticNetwork = .{};

    pub fn deinit(n: *ParasiticNetwork, gpa: Allocator) void {
        inline for (@typeInfo(ParasiticNetwork).@"struct".field_names) |f| @field(n, f).deinit(gpa);
    }

    pub fn clear(n: *ParasiticNetwork) void {
        inline for (@typeInfo(ParasiticNetwork).@"struct".field_names) |f| @field(n, f).clearRetainingCapacity();
    }

    pub fn nodeCount(n: *const ParasiticNetwork) usize {
        return n.node_net.items.len;
    }

    pub fn elementCount(n: *const ParasiticNetwork) usize {
        return n.from.items.len;
    }

    /// Appends one element; canonical order is lost until `sortCanonical`.
    pub fn push(n: *ParasiticNetwork, gpa: Allocator, from: NodeId, to: NodeId, kind: Kind, value: f64) Allocator.Error!void {
        try n.from.append(gpa, from);
        try n.to.append(gpa, to);
        try n.kind.append(gpa, kind);
        try n.value.append(gpa, value);
    }

    /// `net`'s first node, or null when no node is on it. A binary search, so
    /// it relies on each net's nodes being one ascending run.
    pub fn firstNode(n: *const ParasiticNetwork, net: u32) ?NodeId {
        const nets = n.node_net.items;
        const at_ = std.sort.lowerBound(u32, nets, net, orderU32);
        return if (at_ < nets.len and nets[at_] == net) NodeId.at(at_) else null;
    }

    /// Sorts the elements into canonical order: by `from`, then far node with
    /// ground first, then kind, then the value's bits. The key is total, so
    /// any permutation of the same elements sorts to the same columns. The
    /// node columns are not touched.
    pub fn sortCanonical(n: *ParasiticNetwork, gpa: Allocator) Allocator.Error!void {
        const count = n.elementCount();
        const rows = try gpa.alloc(Row, count);
        defer gpa.free(rows);
        for (rows, n.from.items, n.to.items, n.kind.items, n.value.items) |*r, from, to, kind, value| r.* = .{ .from = from, .to = to, .kind = kind, .value = value };
        std.mem.sortUnstable(Row, rows, {}, Row.lessThan);
        for (rows, n.from.items, n.to.items, n.kind.items, n.value.items) |r, *from, *to, *kind, *value| {
            from.* = r.from;
            to.* = r.to;
            kind.* = r.kind;
            value.* = r.value;
        }
    }

    /// Every net's total capacitance in fF into `out` (cleared), indexed by
    /// net: a coupling counts on both of its nets. Each net's sum is a strict
    /// fold in element order. An element whose node is past `node_net`
    /// counts onto no net.
    pub fn capacitancePerNetInto(n: *const ParasiticNetwork, gpa: Allocator, out: *std.ArrayList(f64)) Allocator.Error!void {
        var nets: usize = 0;
        for (n.node_net.items) |net| nets = @max(nets, @as(usize, net) + 1);
        try out.resize(gpa, nets);
        @memset(out.items, 0.0);
        for (n.from.items, n.to.items, n.kind.items, n.value.items) |from, to, kind, value| {
            switch (kind) {
                .ground_cap, .coupling_cap => {},
                .resistance, .inductance, .mutual_inductance, .substrate_resistance => continue,
            }
            const near = n.netOf(from);
            const far = if (to == .ground) near else n.netOf(to);
            if (near) |net| out.items[net] += value;
            if (far) |net| {
                if (near == null or net != near.?) out.items[net] += value;
            }
        }
    }

    fn netOf(n: *const ParasiticNetwork, node: NodeId) ?u32 {
        const i = @backingInt(node);
        return if (i < n.node_net.items.len) n.node_net.items[i] else null;
    }
};

/// One element with its canonical key: `from`, far node (ground first),
/// kind, value bits.
const Row = struct {
    from: NodeId,
    to: NodeId,
    kind: Kind,
    value: f64,

    fn key(r: Row) struct { u32, u64, u8, u64 } {
        const far: u64 = if (r.to == .ground) 0 else @as(u64, @backingInt(r.to)) + 1;
        return .{ @backingInt(r.from), far, @backingInt(r.kind), @bitCast(r.value) };
    }

    fn lessThan(_: void, a: Row, b: Row) bool {
        const ka = a.key();
        const kb = b.key();
        inline for (0..4) |i| {
            if (ka[i] != kb[i]) return ka[i] < kb[i];
        }
        return false;
    }
};

// ---- private ----

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

test "a network sorts ground first then by far node and counts couplings on both nets" {
    // Oracle: the Rust doc example, hand-derived. Net 0 has nodes 0 and 1,
    // net 1 node 2; after sorting, ground comes first, then by far node; a
    // coupling counts on both of its nets, so the totals are 2.5 and 0.5 fF.
    const gpa = std.testing.allocator;
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try n.node_net.appendSlice(gpa, &.{ 0, 0, 1 });
    try n.node_layer.appendNTimes(gpa, @fromBackingInt(3), 3);
    try n.push(gpa, .at(0), .at(2), .coupling_cap, 0.5);
    try n.push(gpa, .at(0), .at(1), .resistance, 12.0);
    try n.push(gpa, .at(0), .ground, .ground_cap, 2.0);
    try n.sortCanonical(gpa);
    try std.testing.expectEqualSlices(NodeId, &.{ .ground, .at(1), .at(2) }, n.to.items);
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try n.capacitancePerNetInto(gpa, &totals);
    try std.testing.expectEqualSlices(f64, &.{ 2.5, 0.5 }, totals.items);
    try std.testing.expectEqual(NodeId.at(2), n.firstNode(1).?);
    try std.testing.expectEqual(null, n.firstNode(5));
}
