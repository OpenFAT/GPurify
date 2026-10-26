//! The extraction type: which parasitics the written network keeps. In: an
//! extracted `ParasiticNetwork` holding its node invariant, and the deck's
//! `extraction` statement. Out: the same network, reduced in place and
//! sorted canonically. Ported from crates/extract/src/reduce.rs.
//!
//! The types are Calibre's ("R", "C+CC", "RC", "RCC"; "lumped C"):
//!
//! | Deck | Keeps | Coupling |
//! |---|---|---|
//! | `rcc` | everything | kept |
//! | `rc` | R, L, ground C | grounded |
//! | `r` | R, L | dropped, with ground C |
//! | `cc` | one node per net: ground C | kept, summed per pair of nets |
//! | `c` | one node per net: ground C | grounded |
//!
//! A field-solved net's series and mutual inductance, and a substrate
//! resistance, sit with its resistance. To ground a coupling is to replace
//! it by a capacitance to ground of the same value at each of its two
//! nodes, as OpenRCX does below `-coupling_threshold`; in `cc` and `rcc` a
//! coupling below the deck's threshold is grounded so. To lump a net is to
//! merge its nodes into its first: its R and L drop out, its ground
//! capacitances sum into one element and its couplings to each other net
//! into one.
//!
//! Contents:
//! - `pub fn reduce(gpa: Allocator, network: *ParasiticNetwork, extraction: Extraction) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ingest = @import("ingest");
const Extraction = ingest.deck.Extraction;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;

/// One coupling between two merged nodes, in element order.
const Coupling = struct { lo: u32, hi: u32, value: f64 };

/// Reduces `network` to `extraction`'s type, then sorts it canonically;
/// `rcc` with no threshold changes nothing but the order. Every net keeps
/// its total capacitance, to round-off, except under `r`, which drops it.
/// Under `c` and `cc` each net keeps one node, so every `NodeId` read before
/// is stale after.
pub fn reduce(gpa: Allocator, network: *ParasiticNetwork, extraction: Extraction) Allocator.Error!void {
    const kind = extraction.kind;
    const keeps_resistance, const keeps_capacitance, const lumps = switch (kind) {
        .r => .{ true, false, false },
        .rc, .rcc => .{ true, true, false },
        .c, .cc => .{ false, true, true },
    };
    // A coupling below this is grounded: every one where none is kept, and
    // none (not even a field solve's slightly negative one) without a
    // positive threshold.
    const threshold: f64 = if (!kind.keepsCoupling())
        std.math.inf(f64)
    else if (extraction.coupling_threshold_af > 0.0)
        extraction.coupling_threshold_af / 1e3
    else
        -std.math.inf(f64);

    const from = try gpa.dupe(NodeId, network.from.items);
    defer gpa.free(from);
    const to = try gpa.dupe(NodeId, network.to.items);
    defer gpa.free(to);
    const kinds = try gpa.dupe(network_mod.Kind, network.kind.items);
    defer gpa.free(kinds);
    const values = try gpa.dupe(f64, network.value.items);
    defer gpa.free(values);
    network.from.clearRetainingCapacity();
    network.to.clearRetainingCapacity();
    network.kind.clearRetainingCapacity();
    network.value.clearRetainingCapacity();
    for (from, to, kinds, values) |near, far, k, v| {
        switch (k) {
            .resistance, .inductance, .mutual_inductance, .substrate_resistance => if (keeps_resistance) try network.push(gpa, near, far, k, v),
            .ground_cap => if (keeps_capacitance) try network.push(gpa, near, far, k, v),
            .coupling_cap => {
                if (!keeps_capacitance) continue;
                if (v < threshold) {
                    try network.push(gpa, near, .ground, .ground_cap, v);
                    if (far != .ground) try network.push(gpa, far, .ground, .ground_cap, v);
                } else try network.push(gpa, near, far, k, v);
            },
        }
    }
    if (lumps) try lump(gpa, network);
    try network.sortCanonical(gpa);
}

// ---- private ----

/// Merges every net's nodes into the first of its run; sums its ground
/// capacitances into one element and its couplings to each other net into
/// one, each a strict fold in element order. Only capacitances are left by
/// then. A coupling between two nodes of one net, shorted by the merge,
/// drops out.
fn lump(gpa: Allocator, network: *ParasiticNetwork) Allocator.Error!void {
    const merged = try gpa.alloc(u32, network.nodeCount());
    defer gpa.free(merged);
    var nodes: u32 = 0;
    for (network.node_net.items, 0..) |net, row| {
        if (row == 0 or network.node_net.items[row - 1] != net) {
            network.node_net.items[nodes] = net;
            network.node_layer.items[nodes] = network.node_layer.items[row];
            nodes += 1;
        }
        merged[row] = nodes - 1;
    }
    network.node_net.shrinkRetainingCapacity(nodes);
    network.node_layer.shrinkRetainingCapacity(nodes);

    const ground = try gpa.alloc(f64, nodes);
    defer gpa.free(ground);
    @memset(ground, 0.0);
    const grounded = try gpa.alloc(bool, nodes);
    defer gpa.free(grounded);
    @memset(grounded, false);
    var couplings: std.ArrayList(Coupling) = .empty;
    defer couplings.deinit(gpa);
    for (network.from.items, network.to.items, network.kind.items, network.value.items) |from, to, kind, value| {
        const near = merged[@backingInt(from)];
        switch (kind) {
            .ground_cap => {
                ground[near] += value;
                grounded[near] = true;
            },
            .coupling_cap => {
                if (to == .ground) continue;
                const far = merged[@backingInt(to)];
                if (far != near) try couplings.append(gpa, .{ .lo = @min(near, far), .hi = @max(near, far), .value = value });
            },
            .resistance, .inductance, .mutual_inductance, .substrate_resistance => {},
        }
    }
    network.from.clearRetainingCapacity();
    network.to.clearRetainingCapacity();
    network.kind.clearRetainingCapacity();
    network.value.clearRetainingCapacity();
    for (ground, grounded, 0..) |ff, seen, node| {
        if (seen) try network.push(gpa, .at(node), .ground, .ground_cap, ff);
    }
    // Stable, so each pair's run keeps element order and folds as Rust's map did.
    std.mem.sort(Coupling, couplings.items, {}, couplingLess);
    var at: usize = 0;
    while (at < couplings.items.len) {
        const c = couplings.items[at];
        var sum: f64 = 0.0;
        while (at < couplings.items.len and couplings.items[at].lo == c.lo and couplings.items[at].hi == c.hi) : (at += 1) sum += couplings.items[at].value;
        try network.push(gpa, .at(c.lo), .at(c.hi), .coupling_cap, sum);
    }
}

fn couplingLess(_: void, a: Coupling, b: Coupling) bool {
    return a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi);
}
