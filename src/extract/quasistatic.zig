//! Field-solved extraction as a `ParasiticNetwork`. In: the selected nets,
//! solved by `capacitance.zig` and `henry.zig`. Out: one node per net
//! carrying the Maxwell matrix (row sum to ground, `−C_ij` coupling), a
//! second node per net for series L and R when asked, a mutual inductance
//! between every pair of those nets, and the overlay of all of it onto the
//! analytical network. Ported from crates/extract/src/quasistatic.rs.
//!
//! The engine's order is `extractInto`, then `extractInductanceInto` on the
//! same network, then `overlay` onto the analytical network.
//!
//! Contents:
//! - `pub fn extractInto(gpa: Allocator, device: Device, problem: capacitance.Problem, selected: []const u32, matrix: *CapMatrix, out: *ParasiticNetwork, diag: *capacitance.Diagnostic) capacitance.Error!capacitance.Accuracy`
//! - `pub fn extractInductanceInto(gpa: Allocator, threads: u16, problem: henry.Problem, selected: []const u32, matrix: *InductMatrix, out: *ParasiticNetwork, refusal: *henry.Refusal) henry.Error!void`
//! - `pub fn overlay(gpa: Allocator, network: *ParasiticNetwork, solved: *const ParasiticNetwork) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Device = geom.Device;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const stack_mod = @import("stack.zig");
const NetPolys = @import("net_polys.zig").NetPolys;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const capacitance = @import("field/capacitance.zig");
const CapMatrix = capacitance.CapMatrix;
const henry = @import("field/henry.zig");
const InductMatrix = henry.InductMatrix;

const femtofarads_per_farad: f64 = 1e15;
const picohenries_per_henry: f64 = 1e12;

/// Field-solves the capacitance of `selected` into `matrix`, then reads it
/// out into `out` (cleared): one node per selected net, ascending, on the
/// net's lowest layer that is not global, carrying its row sum as a ground
/// capacitance, and every pair `i < j` a coupling of `−C_ij`. Every pair is
/// written, even a zero or slightly negative one, and a zero is `+0.0`,
/// never `−0.0`. Errors are `capacitance.extractInto`'s; `out` is left
/// cleared then.
pub fn extractInto(gpa: Allocator, device: Device, problem: capacitance.Problem, selected: []const u32, matrix: *CapMatrix, out: *ParasiticNetwork, diag: *capacitance.Diagnostic) capacitance.Error!capacitance.Accuracy {
    out.clear();
    const accuracy = try capacitance.extractInto(gpa, device, problem, selected, matrix, diag);
    const n = matrix.dim();
    try pushAnchors(gpa, problem.store, problem.nets, problem.global, matrix.net.items, out);
    const v = matrix.value.items;
    for (0..n) |row| {
        // Strict left fold in ascending index order: a reported capacitance.
        var ground: f64 = 0.0;
        for (v[row * n ..][0..n]) |c| ground += c;
        try out.push(gpa, .at(row), .ground, .ground_cap, ground * femtofarads_per_farad);
        for (row + 1..n) |other| {
            // `0 − x`, not `−x`: a pair with no field between them (a net of
            // junctions only has no panels) reads +0, never −0 (F80).
            try out.push(gpa, .at(row), .at(other), .coupling_cap, 0.0 - v[row * n + other] * femtofarads_per_farad);
        }
    }
    return accuracy;
}

/// Solves per-net inductance and resistance for `selected` and appends them
/// to `out`, which is empty or the one-node-per-net network `extractInto`
/// built over the same selection. Each net gains a far node beside its
/// anchor (node `i` becomes `2i`, its far node `2i + 1`), joined by the
/// series L and R, so every `NodeId` read before is stale after. Every pair
/// `i < j` gains a mutual inductance from `i`'s anchor to `j`'s: the mean of
/// `M_ij` and `M_ji`, which agree to round-off. The new elements break
/// canonical order until the network is sorted or `overlay` sorts it.
/// Errors are `henry.extractInductanceInto`'s; `out` is unchanged then.
pub fn extractInductanceInto(gpa: Allocator, threads: u16, problem: henry.Problem, selected: []const u32, matrix: *InductMatrix, out: *ParasiticNetwork, refusal: *henry.Refusal) henry.Error!void {
    try henry.extractInductanceInto(gpa, threads, problem, selected, matrix, refusal);
    if (out.nodeCount() == 0) try pushAnchors(gpa, problem.store, problem.nets, problem.global, matrix.net.items, out);
    assert(std.mem.eql(u32, out.node_net.items, matrix.net.items));
    const n = matrix.net.items.len;
    const old_net = try gpa.dupe(u32, out.node_net.items);
    defer gpa.free(old_net);
    const old_layer = try gpa.dupe(LayerId, out.node_layer.items);
    defer gpa.free(old_layer);
    out.node_net.clearRetainingCapacity();
    out.node_layer.clearRetainingCapacity();
    for (old_net, old_layer) |net, layer| {
        try out.node_net.appendNTimes(gpa, net, 2);
        try out.node_layer.appendNTimes(gpa, layer, 2);
    }
    for (out.from.items) |*from| from.* = .at(2 * @as(usize, @backingInt(from.*)));
    for (out.to.items) |*to| {
        if (to.* != .ground) to.* = .at(2 * @as(usize, @backingInt(to.*)));
    }
    for (0..n) |row| {
        const anchor: NodeId = .at(2 * row);
        const far: NodeId = .at(2 * row + 1);
        try out.push(gpa, anchor, far, .inductance, matrix.l_henry.items[row] * picohenries_per_henry);
        try out.push(gpa, anchor, far, .resistance, matrix.r_ohm.items[row]);
    }
    const m = matrix.m_henry.items;
    for (0..n) |row| {
        for (row + 1..n) |other| {
            // `0 + x`, so no pair reads −0 (F80).
            const mean = (m[row * n + other] + m[other * n + row]) / 2.0;
            try out.push(gpa, .at(2 * row), .at(2 * other), .mutual_inductance, 0.0 + mean * picohenries_per_henry);
        }
    }
}

/// Replaces the analytical rows of every net `solved` has nodes for with
/// the solved rows, then sorts canonically. The mesh never sees an unsolved
/// neighbour, so an analytical element between a solved net and an unsolved
/// one is kept, moved onto the solved net's first node; elements within or
/// between solved nets are dropped. Both networks hold the node invariant.
/// Every node is renumbered, so a `NodeId` read from `network` before is
/// stale after.
pub fn overlay(gpa: Allocator, network: *ParasiticNetwork, solved: *const ParasiticNetwork) Allocator.Error!void {
    var analytical = network.*;
    defer analytical.deinit(gpa);
    network.* = .empty;
    var nets: usize = 0;
    if (analytical.node_net.items.len > 0) nets = @max(nets, @as(usize, analytical.node_net.items[analytical.node_net.items.len - 1]) + 1);
    if (solved.node_net.items.len > 0) nets = @max(nets, @as(usize, solved.node_net.items[solved.node_net.items.len - 1]) + 1);
    const replaced = try gpa.alloc(bool, nets);
    defer gpa.free(replaced);
    @memset(replaced, false);
    for (solved.node_net.items) |net| replaced[net] = true;

    // Two-way merge by net: both sides ascend and, with replaced rows
    // skipped, share no net, so the result keeps one contiguous ascending
    // range per net.
    const coarse_map = try gpa.alloc(u32, analytical.nodeCount());
    defer gpa.free(coarse_map);
    const fine_map = try gpa.alloc(u32, solved.nodeCount());
    defer gpa.free(fine_map);
    const anchor = try gpa.alloc(u32, nets);
    defer gpa.free(anchor);
    @memset(anchor, 0);
    var coarse: usize = 0;
    var fine: usize = 0;
    const a_nets = analytical.node_net.items;
    const s_nets = solved.node_net.items;
    while (true) {
        while (coarse < a_nets.len and replaced[a_nets[coarse]]) coarse += 1;
        const has_coarse = coarse < a_nets.len;
        const has_fine = fine < s_nets.len;
        if (!has_coarse and !has_fine) break;
        const take_coarse = if (has_coarse and has_fine) a_nets[coarse] < s_nets[fine] else has_coarse;
        const id: u32 = @intCast(network.node_net.items.len);
        if (take_coarse) {
            coarse_map[coarse] = id;
            try network.node_net.append(gpa, a_nets[coarse]);
            try network.node_layer.append(gpa, analytical.node_layer.items[coarse]);
            coarse += 1;
        } else {
            const net = s_nets[fine];
            if (fine == 0 or s_nets[fine - 1] != net) anchor[net] = id;
            fine_map[fine] = id;
            try network.node_net.append(gpa, net);
            try network.node_layer.append(gpa, solved.node_layer.items[fine]);
            fine += 1;
        }
    }
    for (coarse_map, a_nets) |*mapped, net| {
        if (replaced[net]) mapped.* = anchor[net];
    }
    for (analytical.from.items, analytical.to.items, analytical.kind.items, analytical.value.items) |from, to, kind, value| {
        const from_solved = replaced[a_nets[@backingInt(from)]];
        const to_solved = to == .ground or replaced[a_nets[@backingInt(to)]];
        if (from_solved and to_solved) continue;
        try network.push(gpa, remap(coarse_map, from), remap(coarse_map, to), kind, value);
    }
    for (solved.from.items, solved.to.items, solved.kind.items, solved.value.items) |from, to, kind, value| {
        try network.push(gpa, remap(fine_map, from), remap(fine_map, to), kind, value);
    }
    try network.sortCanonical(gpa);
}

// ---- private ----

/// One node per net, anchored on the net's lowest layer that is not global
/// (a global layer carries nothing of the network); `maxInt(u16)` for a net
/// with no such layer.
fn pushAnchors(gpa: Allocator, store: *const GeometryStore, nets: *const NetPolys, global: []const LayerId, order: []const u32, out: *ParasiticNetwork) Allocator.Error!void {
    try out.node_net.appendSlice(gpa, order);
    for (order) |net| {
        var low: u16 = std.math.maxInt(u16);
        for (nets.polysOf(net)) |p| {
            const layer = store.polyLayer(p);
            if (!stack_mod.isGlobal(global, layer)) low = @min(low, @backingInt(layer));
        }
        try out.node_layer.append(gpa, @fromBackingInt(low));
    }
}

fn remap(map: []const u32, node: NodeId) NodeId {
    return if (node == .ground) .ground else .at(map[@backingInt(node)]);
}
