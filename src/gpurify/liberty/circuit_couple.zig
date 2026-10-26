//! The rectangle graph's coupling: each analytical coupling element placed
//! between the closest rectangles of the two regions it was measured
//! between, then every net's ground and every net pair's coupling rescaled
//! to a field solve's totals. In: the `Builder`, the analytical network and
//! its problem, the field network. Out: the builder's capacitor table.
//! Ported from src/liberty/circuit.rs (`Builder::{couplings, node_rects,
//! closest, calibrate}`).
//!
//! Contents:
//! - `pub fn couplings(b: *Builder, analytical: *const ParasiticNetwork, problem: extract.analytical.Problem, diag: *Diagnostic) Error!void`
//! - `pub fn calibrate(b: *Builder, field: *const ParasiticNetwork) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const NetId = @import("check").topology.net.NetId;
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const NodeId = extract.network.NodeId;
const Diagnostic = @import("spec.zig").Diagnostic;
const Error = @import("circuit.zig").Error;
const graph = @import("circuit_graph.zig");
const Builder = graph.Builder;

/// The analytical extractor's coupling between wire layers (diffusions and
/// wells couple through junctions, the models' job), each element on the
/// closest pair of rectangles of its two regions.
pub fn couplings(b: *Builder, analytical: *const ParasiticNetwork, problem: extract.analytical.Problem, diag: *Diagnostic) Error!void {
    const rects_of = try nodeRects(b, analytical, problem, diag);
    for (analytical.from.items, analytical.to.items, analytical.kind.items, analytical.value.items) |from, to, kind, femto| {
        if (kind != .coupling_cap or to == .ground) continue;
        if (!b.isWire(analytical.node_layer.items[@backingInt(from)]) or !b.isWire(analytical.node_layer.items[@backingInt(to)])) continue;
        const pair = closest(b, rects_of[@backingInt(from)].items, rects_of[@backingInt(to)].items) orelse continue;
        try b.cap(Builder.rectNode(pair[0]), Builder.rectNode(pair[1]), femto * 1e-15);
    }
}

/// Rescales each solved net's ground and each solved pair's coupling to the
/// field solve's totals; solved capacitance with nothing analytical to
/// carry it goes on the nets' anchors.
pub fn calibrate(b: *Builder, field: *const ParasiticNetwork) Allocator.Error!void {
    const a = b.arena;
    const nets = b.net_rects.len;
    const solved = try a.alloc(bool, nets);
    @memset(solved, false);
    for (field.node_net.items) |net| if (net < nets) {
        solved[net] = true;
    };
    var target_ground: Totals(u32) = .empty;
    var target_pair: Totals([2]u32) = .empty;
    for (field.from.items, field.to.items, field.kind.items, field.value.items) |from, to, kind, femto| {
        const near = field.node_net.items[@backingInt(from)];
        const farads = @max(femto, 0.0) * 1e-15;
        switch (kind) {
            .ground_cap => if (to == .ground) try add(u32, a, &target_ground, near, farads),
            .coupling_cap => if (to != .ground) {
                const far = field.node_net.items[@backingInt(to)];
                try add([2]u32, a, &target_pair, .{ @min(near, far), @max(near, far) }, farads);
            },
            .resistance, .inductance, .mutual_inductance, .substrate_resistance => {},
        }
    }
    // Current totals, by the same keys.
    var have_ground: Totals(u32) = .empty;
    var have_pair: Totals([2]u32) = .empty;
    const keys = b.sortedCaps();
    for (keys, b.caps.values()) |key, f| switch (classify(b, key)) {
        .ground => |n| try add(u32, a, &have_ground, n, f),
        .pair => |p| try add([2]u32, a, &have_pair, p, f),
        .other => {},
    };
    for (keys, b.caps.values()) |key, *f| {
        const scale = switch (classify(b, key)) {
            .ground => |n| if (solved[n]) (target_ground.get(n) orelse 0.0) / have_ground.get(n).? else continue,
            .pair => |p| if (solved[p[0]] and solved[p[1]]) (target_pair.get(p) orelse 0.0) / have_pair.get(p).? else continue,
            .other => continue,
        };
        if (std.math.isFinite(scale)) f.* *= scale;
    }
    sortTotals(u32, &target_ground);
    for (target_ground.keys(), target_ground.values()) |net, f| {
        if (have_ground.contains(net) or net >= nets) continue;
        const node = try b.anchor(@fromBackingInt(net));
        try b.cap(node, graph.ground, f);
    }
    sortTotals([2]u32, &target_pair);
    for (target_pair.keys(), target_pair.values()) |p, f| {
        if (have_pair.contains(p) or p[0] >= nets or p[1] >= nets) continue;
        const x = try b.anchor(@fromBackingInt(p[0]));
        const y = try b.anchor(@fromBackingInt(p[1]));
        try b.cap(x, y, f);
    }
}

// ---- private ----

/// Farads summed per key in arrival order; sorted before any order-bound read.
fn Totals(comptime K: type) type {
    return std.AutoArrayHashMapUnmanaged(K, f64);
}

/// What a capacitor joins, by the nets of its rectangle nodes.
const Joins = union(enum) { ground: u32, pair: [2]u32, other };

fn classify(b: *const Builder, key: [2]u32) Joins {
    const near = rectNet(b, key[0]);
    const far = rectNet(b, key[1]);
    if (key[0] == graph.ground) return if (far) |n| .{ .ground = n } else .other;
    if (near != null and far != null and near.? != far.?) return .{ .pair = .{ @min(near.?, far.?), @max(near.?, far.?) } };
    return .other;
}

/// The net of a rectangle node; null for ground and hubs.
fn rectNet(b: *const Builder, node: u32) ?u32 {
    if (node == 0 or node - 1 >= b.rect_net.items.len) return null;
    return @backingInt(b.rect_net.items[node - 1]);
}

fn add(comptime K: type, a: Allocator, totals: *Totals(K), key: K, farads: f64) Allocator.Error!void {
    const slot = try totals.getOrPut(a, key);
    if (!slot.found_existing) slot.value_ptr.* = 0.0;
    slot.value_ptr.* += farads;
}

fn sortTotals(comptime K: type, totals: *Totals(K)) void {
    const Ctx = struct {
        keys: []const K,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            if (K == u32) return c.keys[x] < c.keys[y];
            const p = c.keys[x];
            const q = c.keys[y];
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    };
    totals.sort(Ctx{ .keys = totals.keys() });
}

/// This circuit's rectangles in each analytical node's region, by node:
/// those of the node's net and layer sharing area with one of the region's
/// rectangles, ascending.
fn nodeRects(b: *Builder, analytical: *const ParasiticNetwork, problem: extract.analytical.Problem, diag: *Diagnostic) Error![]std.ArrayList(u32) {
    const a = b.arena;
    var node: std.ArrayList(NodeId) = .empty;
    var region: std.ArrayList(Bbox) = .empty;
    var refusal: extract.analytical.Refusal = .{};
    extract.analytical.nodeRectsInto(a, problem, &node, &region, &refusal) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Undescribed, error.UndescribedVia, error.InvalidGeometry => {
            const name = b.loaded.strings.resolve(b.loaded.deck.deck.layers.name(refusal.layer));
            diag.message = try a.print("layer {s} is not valid rectilinear geometry: not valid rectilinear geometry, so its conductors cannot be merged exactly", .{name});
            return error.Geometry;
        },
    };
    const out = try a.alloc(std.ArrayList(u32), analytical.nodeCount());
    @memset(out, .empty);
    var found: std.ArrayList(u32) = .empty;
    for (node.items, region.items) |n, box| {
        const i = @backingInt(n);
        const layer = analytical.node_layer.items[i];
        const index = for (b.index.items) |*entry| (if (entry.layer == layer) break &entry.index) else continue;
        try index.query(a, box, &found);
        const net = analytical.node_net.items[i];
        for (found.items) |r| {
            const s = graph.shared(b.rect.items[r], box);
            if (@backingInt(b.rect_net.items[r]) == net and s[0] > 0 and s[1] > 0) try out[i].append(a, r);
        }
    }
    for (out) |*list| {
        std.mem.sortUnstable(u32, list.items, {}, std.sort.asc(u32));
        var kept: usize = 0;
        for (list.items) |r| {
            if (kept > 0 and list.items[kept - 1] == r) continue;
            list.items[kept] = r;
            kept += 1;
        }
        list.shrinkRetainingCapacity(kept);
    }
    return out;
}

/// The closest pair, one of `ps` and one of `qs`; the first in rectangle
/// order on a tie.
fn closest(b: *const Builder, ps: []const u32, qs: []const u32) ?[2]u32 {
    var best: ?[2]u32 = null;
    var best_d: i128 = 0;
    for (ps) |p| for (qs) |q| {
        const d = graph.gap2(b.rect.items[p], b.rect.items[q]);
        if (best == null or d < best_d) {
            best = .{ p, q };
            best_d = d;
        }
    };
    return best;
}
