//! Metal fill in an extraction (catalog PEX-012). In: a `ParasiticNetwork`
//! in which every fill piece was extracted as a net of its own, and how the
//! deck treats each such net. Out: the network with every fill net's nodes
//! and elements gone and their effect folded into the other nets' elements.
//! Ported from crates/extract/src/fill.rs.
//!
//! The treatments are StarRC's and Quantus's: `grounded` fill turns a net's
//! coupling to a piece into capacitance to ground; `ignored` fill is not
//! there, every element touching it dropped; `floating` fill is a conductor
//! with no charge, eliminated from the capacitive network by the Schur
//! complement over its nodes (a Kron reduction, Kron 1939): with `Y` the
//! nodal capacitance matrix, the nets' matrix becomes `Y_aa − Y_af Y_ff⁻¹
//! Y_fa`. A net coupled to a lone piece by `c₁`, another by `c₂`, the piece
//! to ground by `c_g`, gets `c₁c₂ / (c₁ + c₂ + c_g)` to the other net:
//! series capacitors. Pieces coupled to each other are eliminated together.
//! A fill net is one conductor; its resistance plays no part.
//!
//! Contents:
//! - `pub const Treatment` (ingest's `FillTreatment`), `pub const Fill = struct { net: u32, treatment: Treatment }`
//! - `pub const max_cluster: usize`
//! - `pub const Error = error{Cluster} || Allocator.Error`, `pub const Refusal = struct { pieces: usize }`
//! - `pub fn treat(gpa: Allocator, network: *ParasiticNetwork, fills: []const Fill, refusal: *Refusal) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ingest = @import("ingest");
const cholesky = @import("cholesky.zig");
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;

/// How the deck treats fill (`pex_fill <layer> floating|grounded|ignored`).
pub const Treatment = ingest.deck.FillTreatment;

/// One fill net and its treatment.
pub const Fill = struct { net: u32, treatment: Treatment };

/// The most floating pieces one cluster may hold: its reduction is a dense
/// solve, 32 MiB at this size.
// ponytail: dense per cluster; a sparse factorisation lifts it if a fill array ever couples into one cluster this large.
pub const max_cluster: usize = 2048;

pub const Error = error{
    /// Floating pieces couple into a cluster larger than `max_cluster`;
    /// `Refusal.pieces` is its size.
    Cluster,
} || Allocator.Error;

pub const Refusal = struct { pieces: usize = 0 };

/// One end of a capacitance: a net's node, a fill piece (its net), or ground.
const End = struct {
    tag: enum(u8) { node, fill, ground },
    id: u32,

    const ground: End = .{ .tag = .ground, .id = 0 };

    fn eql(a: End, b: End) bool {
        return a.tag == b.tag and a.id == b.id;
    }
};

/// A floating piece's capacitance to another end, in the order found.
const Entry = struct { piece: u32, there: End, ff: f64 };

/// Folds every fill net of `fills` (ascending, distinct) into the rest of
/// `network` by its treatment and removes its nodes; the other nets' nodes
/// keep their order, renumbered down, and the network ends canonical. A
/// cluster of floating pieces with no capacitance to anything changes
/// nothing and is dropped. Errors: `Cluster`, `network` then unchanged.
pub fn treat(gpa: Allocator, network: *ParasiticNetwork, fills: []const Fill, refusal: *Refusal) Error!void {
    if (fills.len == 0) return;
    for (1..fills.len) |i| assert(fills[i - 1].net < fills[i].net);
    const net_of = network.node_net.items;
    var kept: ParasiticNetwork = .empty;
    defer kept.deinit(gpa);
    var floating: std.ArrayList(Entry) = .empty;
    defer floating.deinit(gpa);
    for (network.from.items, network.to.items, network.kind.items, network.value.items) |from, to, kind, value| {
        const a = endOf(fills, net_of, from);
        const b = endOf(fills, net_of, to);
        if (a.tag != .fill and b.tag != .fill) {
            try kept.push(gpa, from, to, kind, value);
            continue;
        }
        switch (kind) {
            .ground_cap, .coupling_cap => {},
            // A fill piece's resistance and inductance carry no current.
            .resistance, .inductance, .mutual_inductance, .substrate_resistance => continue,
        }
        for ([2][2]End{ .{ a, b }, .{ b, a } }) |pair| {
            const here = pair[0];
            var there = pair[1];
            if (here.tag != .fill or there.eql(here)) continue;
            switch (treatmentOf(fills, here.id).?) {
                .ignored => {},
                .grounded => if (there.tag == .node) try kept.push(gpa, .at(there.id), .ground, .ground_cap, value),
                .floating => {
                    // A grounded piece is ground to a floating one; an
                    // ignored one is not there.
                    if (there.tag == .fill) switch (treatmentOf(fills, there.id).?) {
                        .floating => {},
                        .grounded => there = End.ground,
                        .ignored => continue,
                    };
                    try floating.append(gpa, .{ .piece = here.id, .there = there, .ff = value });
                },
            }
        }
    }
    try eliminate(gpa, floating.items, net_of, &kept, refusal);
    // Drop the fill nets' nodes, renumbering the rest in order.
    const new_id = try gpa.alloc(u32, net_of.len);
    defer gpa.free(new_id);
    var out: ParasiticNetwork = .empty;
    errdefer out.deinit(gpa);
    for (net_of, network.node_layer.items, new_id) |net, layer, *id| {
        if (treatmentOf(fills, net) != null) continue;
        id.* = @intCast(out.node_net.items.len);
        try out.node_net.append(gpa, net);
        try out.node_layer.append(gpa, layer);
    }
    for (kept.from.items, kept.to.items, kept.kind.items, kept.value.items) |from, to, kind, value| {
        const far: NodeId = if (to == .ground) .ground else .at(new_id[@backingInt(to)]);
        try out.push(gpa, .at(new_id[@backingInt(from)]), far, kind, value);
    }
    try out.sortCanonical(gpa);
    network.deinit(gpa);
    network.* = out;
}

// ---- private ----

fn treatmentOf(fills: []const Fill, net: u32) ?Treatment {
    var lo: usize = 0;
    var hi: usize = fills.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (fills[mid].net < net) lo = mid + 1 else hi = mid;
    }
    return if (lo < fills.len and fills[lo].net == net) fills[lo].treatment else null;
}

fn endOf(fills: []const Fill, net_of: []const u32, node: NodeId) End {
    if (node == .ground) return End.ground;
    const net = net_of[@backingInt(node)];
    return if (treatmentOf(fills, net) != null) .{ .tag = .fill, .id = net } else .{ .tag = .node, .id = @backingInt(node) };
}

/// The Kron reduction of every cluster of floating pieces (pieces joined by
/// capacitance), appending each new coupling and ground capacitance to
/// `kept`. Clusters go in order of their lowest piece; each piece's entries
/// fold in the order found.
fn eliminate(gpa: Allocator, entries: []Entry, net_of: []const u32, kept: *ParasiticNetwork, refusal: *Refusal) Error!void {
    std.mem.sort(Entry, entries, {}, entryLess);
    // The pieces, ascending, and each one's run of entries.
    var pieces: std.ArrayList(u32) = .empty;
    defer pieces.deinit(gpa);
    var run_start: std.ArrayList(u32) = .empty;
    defer run_start.deinit(gpa);
    for (entries, 0..) |e, i| {
        if (i > 0 and entries[i - 1].piece == e.piece) continue;
        try pieces.append(gpa, e.piece);
        try run_start.append(gpa, @intCast(i));
    }
    try run_start.append(gpa, @intCast(entries.len));
    const p = pieces.items;
    const parent = try gpa.alloc(u32, p.len);
    defer gpa.free(parent);
    for (parent, 0..) |*x, k| x.* = @intCast(k);
    for (0..p.len) |k| {
        for (entries[run_start.items[k]..run_start.items[k + 1]]) |e| {
            if (e.there.tag != .fill) continue;
            const a = root(parent, @intCast(k));
            const b = root(parent, @intCast(std.sort.binarySearch(u32, p, e.there.id, orderU32).?));
            parent[@max(a, b)] = @min(a, b);
        }
    }
    // Members of each cluster, ascending, clusters by root (their lowest piece).
    const by_root = try gpa.alloc(u32, p.len);
    defer gpa.free(by_root);
    for (by_root, 0..) |*x, k| x.* = @intCast(k);
    for (parent, 0..) |_, k| parent[k] = root(parent, @intCast(k));
    std.mem.sort(u32, by_root, @as([]const u32, parent), memberLess);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    var nodes: std.ArrayList(u32) = .empty;
    defer nodes.deinit(gpa);
    var at: usize = 0;
    while (at < by_root.len) {
        members.clearRetainingCapacity();
        const r = parent[by_root[at]];
        while (at < by_root.len and parent[by_root[at]] == r) : (at += 1) try members.append(gpa, by_root[at]);
        if (members.items.len > max_cluster) {
            refusal.pieces = members.items.len;
            return error.Cluster;
        }
        nodes.clearRetainingCapacity();
        for (members.items) |k| {
            for (entries[run_start.items[k]..run_start.items[k + 1]]) |e| {
                if (e.there.tag == .node) try nodes.append(gpa, e.there.id);
            }
        }
        std.mem.sortUnstable(u32, nodes.items, {}, std.sort.asc(u32));
        nodes.shrinkRetainingCapacity(dedup(nodes.items));
        try reduceCluster(gpa, entries, run_start.items, p, members.items, nodes.items, net_of, kept);
    }
}

/// One cluster's Schur complement onto its `nodes`: `M = Y_faᵀ Y_ff⁻¹
/// Y_fa`, `M_ij` the capacitance node `i` sees to node `j` through the
/// cluster, and what it sees to the cluster less all of `M`'s row, to
/// ground. A cluster with no capacitance is singular and changes nothing.
fn reduceCluster(gpa: Allocator, entries: []const Entry, run_start: []const u32, pieces: []const u32, members: []const u32, nodes: []const u32, net_of: []const u32, kept: *ParasiticNetwork) Allocator.Error!void {
    const k = members.len;
    const m = nodes.len;
    const yff = try gpa.alloc(f64, k * k);
    defer gpa.free(yff);
    @memset(yff, 0.0);
    const yfa = try gpa.alloc(f64, k * m);
    defer gpa.free(yfa);
    @memset(yfa, 0.0);
    for (members, 0..) |piece, a| {
        for (entries[run_start[piece]..run_start[piece + 1]]) |e| {
            yff[a * k + a] += e.ff;
            switch (e.there.tag) {
                .ground => {},
                .node => yfa[a * m + std.sort.binarySearch(u32, nodes, e.there.id, orderU32).?] -= e.ff,
                .fill => {
                    const other: u32 = @intCast(std.sort.binarySearch(u32, pieces, e.there.id, orderU32).?);
                    yff[a * k + std.sort.binarySearch(u32, members, other, orderU32).?] -= e.ff;
                },
            }
        }
    }
    if (!cholesky.factorInPlace(yff, k)) return;
    // X = Y_ff⁻¹ Y_fa, column `j` at `x[j * k ..]`.
    const x = try gpa.alloc(f64, m * k);
    defer gpa.free(x);
    for (0..m) |j| {
        const column = x[j * k ..][0..k];
        for (column, 0..) |*c, a| c.* = yfa[a * m + j];
        cholesky.solveInPlace(yff, k, column);
    }
    for (0..m) |i| {
        var to_cluster: f64 = 0.0;
        for (0..k) |a| to_cluster += -yfa[a * m + i];
        var through: f64 = 0.0;
        for (0..m) |j| {
            var mij: f64 = 0.0;
            for (0..k) |a| mij += -yfa[a * m + i] * -x[j * k + a];
            through += mij;
            if (j > i and mij > 0.0 and net_of[nodes[i]] != net_of[nodes[j]]) try kept.push(gpa, .at(nodes[i]), .at(nodes[j]), .coupling_cap, mij);
        }
        const ground = to_cluster - through;
        if (ground > 0.0) try kept.push(gpa, .at(nodes[i]), .ground, .ground_cap, ground);
    }
}

/// The union-find root of `start`, halving the path.
fn root(parent: []u32, start: u32) u32 {
    var k = start;
    while (parent[k] != k) {
        parent[k] = parent[parent[k]];
        k = parent[k];
    }
    return k;
}

fn dedup(sorted: []u32) usize {
    if (sorted.len == 0) return 0;
    var n: usize = 1;
    for (sorted[1..]) |v| {
        if (v != sorted[n - 1]) {
            sorted[n] = v;
            n += 1;
        }
    }
    return n;
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return a.piece < b.piece;
}

fn memberLess(roots: []const u32, a: u32, b: u32) bool {
    return roots[a] < roots[b] or (roots[a] == roots[b] and a < b);
}

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

/// Nets 0 (signal a), 1 and 2 (fill) and 3 (signal b), one node each;
/// `caps` are `(near, far, fF)`, far `null` for ground.
fn treated(caps: []const struct { u32, ?u32, f64 }, fills: []const Fill) !ParasiticNetwork {
    const testing_gpa = std.testing.allocator;
    var n: ParasiticNetwork = .empty;
    errdefer n.deinit(testing_gpa);
    try n.node_net.appendSlice(testing_gpa, &.{ 0, 1, 2, 3 });
    try n.node_layer.appendNTimes(testing_gpa, @fromBackingInt(0), 4);
    for (caps) |c| {
        if (c[1]) |far| try n.push(testing_gpa, .at(c[0]), .at(far), .coupling_cap, c[2]) else try n.push(testing_gpa, .at(c[0]), .ground, .ground_cap, c[2]);
    }
    try n.sortCanonical(testing_gpa);
    var refusal: Refusal = .{};
    try treat(testing_gpa, &n, fills, &refusal);
    return n;
}

/// The coupling between the two signal nets, and each one's ground C.
fn readBack(n: *const ParasiticNetwork) [3]f64 {
    var out: [3]f64 = .{ 0, 0, 0 };
    for (n.from.items, n.kind.items, n.value.items) |from, kind, v| {
        const on_a = n.node_net.items[@backingInt(from)] == 0;
        switch (kind) {
            .coupling_cap => out[0] += v,
            .ground_cap => out[if (on_a) 1 else 2] += v,
            .resistance, .inductance, .mutual_inductance, .substrate_resistance => {},
        }
    }
    return out;
}

test "one floating piece puts its couplings in series" {
    // Oracle: closed form, series capacitors: a to a floating piece 2 fF,
    // the piece to b 3 fF and to ground 1 fF: a–b `2·3/6 = 1` fF, a to
    // ground `2·1/6`, b `3·1/6`; the fill's nodes are gone and a direct
    // 0.5 fF a–b coupling stays.
    var n = try treated(&.{ .{ 0, 1, 2.0 }, .{ 1, 3, 3.0 }, .{ 1, null, 1.0 }, .{ 0, 3, 0.5 } }, &.{ .{ .net = 1, .treatment = .floating }, .{ .net = 2, .treatment = .floating } });
    defer n.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, n.node_net.items);
    const got = readBack(&n);
    try std.testing.expectApproxEqAbs(1.5, got[0], 1e-12);
    try std.testing.expectApproxEqAbs(2.0 / 6.0, got[1], 1e-12);
    try std.testing.expectApproxEqAbs(0.5, got[2], 1e-12);
}

test "a chain of floating pieces is eliminated together" {
    // Oracle: closed form: a, two floating pieces and b in a chain of three
    // 3 fF capacitors is 1 fF from a to b, nothing to ground.
    var n = try treated(&.{ .{ 0, 1, 3.0 }, .{ 1, 2, 3.0 }, .{ 2, 3, 3.0 } }, &.{ .{ .net = 1, .treatment = .floating }, .{ .net = 2, .treatment = .floating } });
    defer n.deinit(std.testing.allocator);
    const got = readBack(&n);
    try std.testing.expectApproxEqAbs(1.0, got[0], 1e-12);
    try std.testing.expectApproxEqAbs(0.0, got[1], 1e-12);
    try std.testing.expectApproxEqAbs(0.0, got[2], 1e-12);
}

test "grounded fill grounds and ignored fill drops" {
    // Oracle: the treatments' definitions: grounded, a's 2 fF and b's 3 fF
    // to the piece go to ground and no coupling appears; ignored, both are
    // dropped; a grounded piece beside a floating one is ground to it, so a
    // sees 2 fF in series with 2 fF, 1 fF to ground.
    const caps = [_]struct { u32, ?u32, f64 }{ .{ 0, 1, 2.0 }, .{ 1, 3, 3.0 }, .{ 1, null, 1.0 } };
    var g = try treated(&caps, &.{.{ .net = 1, .treatment = .grounded }});
    defer g.deinit(std.testing.allocator);
    try std.testing.expectEqual([3]f64{ 0.0, 2.0, 3.0 }, readBack(&g));
    var i = try treated(&caps, &.{.{ .net = 1, .treatment = .ignored }});
    defer i.deinit(std.testing.allocator);
    try std.testing.expectEqual([3]f64{ 0.0, 0.0, 0.0 }, readBack(&i));
    var f = try treated(&.{ .{ 0, 1, 2.0 }, .{ 1, 2, 2.0 } }, &.{ .{ .net = 1, .treatment = .floating }, .{ .net = 2, .treatment = .grounded } });
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual([3]f64{ 0.0, 1.0, 0.0 }, readBack(&f));
}
