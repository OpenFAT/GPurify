//! The analytical spatial joins. In: every region's rectangles and every
//! via cut as drawn, in one store (`RectStore`), each row tagged with its
//! region's net and node. Out: lateral and interlayer coupling capacitances
//! and via-array resistances, appended to the network. Ported from
//! crates/extract/src/analytical.rs (`rect_store`, `couple_into`,
//! `vias_into`).
//!
//! The joins measure conductors, not drawn polygons: a bar drawn in pieces
//! is one region's rectangles, disjoint, so nothing is counted twice.
//!
//! Contents:
//! - `pub const RectStore = struct`, `RectStore.empty`, `deinit`,
//!   `build(rs: *RectStore, gpa: Allocator, store: *const GeometryStore, cut_layers: []const LayerId, regions: *const Regions, node_of: []const NodeId) Allocator.Error!void`
//! - `pub fn coupleInto(gpa: Allocator, rects: *const RectStore, problem: Problem, out: *ParasiticNetwork) Allocator.Error!void`
//! - `pub fn viasInto(gpa: Allocator, rects: *const RectStore, problem: Problem, out: *ParasiticNetwork, refusal: *Refusal) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const index = geom.index;
const stack_mod = @import("stack.zig");
const Stack = stack_mod.Stack;
const none = stack_mod.none;
const Regions = @import("conductor.zig").Regions;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const closed_form = @import("closed_form.zig");
const analytical = @import("analytical.zig");
const Problem = analytical.Problem;
const Error = analytical.Error;
const Refusal = analytical.Refusal;

/// Every region's rectangles on its layer and every cut on a via layer, in
/// one store, rows grouped by layer. `net[row]` and `node[row]` are the
/// row's region's; a cut's are `none` and `ground`.
pub const RectStore = struct {
    store: GeometryStore = .empty,
    net: std.ArrayList(u32) = .empty,
    node: std.ArrayList(NodeId) = .empty,

    pub const empty: RectStore = .{};

    pub fn deinit(rs: *RectStore, gpa: Allocator) void {
        rs.store.deinit(gpa);
        rs.net.deinit(gpa);
        rs.node.deinit(gpa);
    }

    /// Rebuilds from `regions` (each region's node in `node_of`) and every
    /// polygon of `store` on `cut_layers`.
    pub fn build(rs: *RectStore, gpa: Allocator, store: *const GeometryStore, cut_layers: []const LayerId, regions: *const Regions, node_of: []const NodeId) Allocator.Error!void {
        assert(node_of.len == regions.len());
        var builder: geom.GeometryStoreBuilder = .empty;
        defer builder.deinit(gpa);
        var arrival_net: std.ArrayList(u32) = .empty;
        defer arrival_net.deinit(gpa);
        var arrival_node: std.ArrayList(NodeId) = .empty;
        defer arrival_node.deinit(gpa);
        for (0..regions.len()) |region| {
            for (regions.rectsOf(@intCast(region))) |r| {
                _ = try builder.push(gpa, regions.layer.items[region], &.{ r.xlo, r.xhi, r.xhi, r.xlo }, &.{ r.ylo, r.ylo, r.yhi, r.yhi });
                try arrival_net.append(gpa, regions.net.items[region]);
                try arrival_node.append(gpa, node_of[region]);
            }
        }
        const layers = try gpa.dupe(LayerId, cut_layers);
        defer gpa.free(layers);
        std.mem.sortUnstable(LayerId, layers, {}, layerLess);
        for (layers, 0..) |layer, k| {
            if (k > 0 and layers[k - 1] == layer) continue;
            const rows = store.polysOnLayer(layer);
            for (rows.start..rows.end) |row| {
                const ring = store.polyVerts(@fromBackingInt(@intCast(row)));
                _ = try builder.push(gpa, layer, ring.xs, ring.ys);
                try arrival_net.append(gpa, none);
                try arrival_node.append(gpa, .ground);
            }
        }
        var permutation: std.ArrayList(u32) = .empty;
        defer permutation.deinit(gpa);
        try builder.finish(gpa, @intCast(store.layerCount()), &rs.store, &permutation);
        try rs.net.resize(gpa, permutation.items.len);
        try rs.node.resize(gpa, permutation.items.len);
        for (permutation.items, rs.net.items, rs.node.items) |old, *net, *node| {
            net.* = arrival_net.items[old];
            node.* = arrival_node.items[old];
        }
    }
};

/// Appends lateral coupling (same layer, facing within `halo` thicknesses,
/// `ε₀εr·t·L/S`) and interlayer coupling (overlapping plates on two
/// conductor layers, `ε₀εr·A/d`, `εr` the dielectric above the lower plate)
/// between rectangles of different nets, each pair once, lower net first.
/// A non-positive or non-finite value is left out.
pub fn coupleInto(gpa: Allocator, rects: *const RectStore, problem: Problem, out: *ParasiticNetwork) Allocator.Error!void {
    const store = &rects.store;
    const stack = problem.stack;
    var index_a: index.SpatialIndex = .empty;
    defer index_a.deinit(gpa);
    var index_b: index.SpatialIndex = .empty;
    defer index_b.deinit(gpa);
    var pairs: std.ArrayList(index.Pair) = .empty;
    defer pairs.deinit(gpa);
    const per_um: f64 = @floatFromInt(problem.grid.dbu_per_um);
    for (problem.conductors, 0..) |layer, position| {
        const row = stackRow(stack, layer) orelse continue;
        const thickness_nm = stack_mod.value(stack.thickness_nm, row);
        const coefficient = closed_form.epsilon0_af_per_um * stack_mod.value(stack.dielectric_k, row) * thickness_nm / closed_form.nm_per_um;
        const reach = @min(thickness_nm * per_um / closed_form.nm_per_um * problem.halo, @as(f64, @floatFromInt(geom.max_abs_dbu)));
        // Truncated as Rust's `as` does; a NaN or sub-unit reach is none.
        const halo: Dbu = if (reach >= 1.0) @intFromFloat(reach) else 0;
        if (coefficient > 0.0 and halo > 0) {
            try index_a.build(gpa, store, layer);
            try index.candidatePairsInto(gpa, store, &index_a, halo, &pairs);
            for (pairs.items) |p| {
                if (sameNet(rects, p)) continue;
                const f = facing(store.polyBbox(p.a), store.polyBbox(p.b)) orelse continue;
                try pushCoupling(gpa, rects, p, closed_form.couplingCapacitance(coefficient, f.run, f.gap, problem.grid), out);
            }
        }
        // Each layer pair once; lower and upper come from the stack heights.
        for (problem.conductors[position + 1 ..]) |above| {
            const other = stackRow(stack, above) orelse continue;
            const low_first = stack_mod.value(stack.height_nm, row) <= stack_mod.value(stack.height_nm, other);
            const lower = if (low_first) row else other;
            const upper = if (low_first) other else row;
            const gap_nm = stack_mod.value(stack.height_nm, upper) - (stack_mod.value(stack.height_nm, lower) + stack_mod.value(stack.thickness_nm, lower));
            if (!(gap_nm > 0.0)) continue;
            const k = stack_mod.value(stack.dielectric_k, lower);
            if (!(k > 0.0)) continue;
            const per_um2 = closed_form.epsilon0_af_per_um * k / (gap_nm / closed_form.nm_per_um);
            try index_b.build(gpa, store, if (low_first) above else layer);
            try index.crossLayerPairsInto(gpa, store, if (low_first) layer else above, &index_b, 0, &pairs);
            for (pairs.items) |p| {
                if (sameNet(rects, p)) continue;
                const overlap = store.polyBbox(p.a).intersection(store.polyBbox(p.b)) orelse continue;
                if (overlap.width() <= 0 or overlap.height() <= 0) continue;
                try pushCoupling(gpa, rects, p, closed_form.groundCapacitance(per_um2, 0.0, overlap.area(), 0, problem.grid), out);
            }
        }
    }
}

/// Appends one resistor per via array: the cuts of a via row that land on
/// the same two regions, `Rcut / n`. A cut lands on the lowest region whose
/// rectangle shares a point with its box, touching included, as net
/// extraction joins; a cut missing a plate is left out, and a via into a
/// global layer joins nothing. Errors: `UndescribedVia`, naming the first
/// via row with a landed cut and no resistance per cut.
pub fn viasInto(gpa: Allocator, rects: *const RectStore, problem: Problem, out: *ParasiticNetwork, refusal: *Refusal) Error!void {
    const no_region = std.math.maxInt(u32);
    const store = &rects.store;
    var plate_index: index.SpatialIndex = .empty;
    defer plate_index.deinit(gpa);
    var pairs: std.ArrayList(index.Pair) = .empty;
    defer pairs.deinit(gpa);
    // By the cut's row: the lowest node on each side; a miss keeps the sentinel.
    const landing = try gpa.alloc([2]u32, store.polyCount());
    defer gpa.free(landing);
    @memset(landing, .{ no_region, no_region });
    var arrays: std.ArrayList([2]u32) = .empty;
    defer arrays.deinit(gpa);
    for (problem.vias.cut, problem.vias.connects) |cut_layer, plates| {
        if (stack_mod.isGlobal(problem.global, plates[0]) or stack_mod.isGlobal(problem.global, plates[1])) continue;
        for (plates, 0..) |plate_layer, side| {
            try plate_index.build(gpa, store, plate_layer);
            try index.crossLayerPairsInto(gpa, store, cut_layer, &plate_index, 0, &pairs);
            for (pairs.items) |p| {
                if (!store.polyBbox(p.a).overlaps(store.polyBbox(p.b))) continue;
                const slot = &landing[@backingInt(p.a)][side];
                slot.* = @min(slot.*, @backingInt(rects.node.items[@backingInt(p.b)]));
            }
        }
        arrays.clearRetainingCapacity();
        const cuts = store.polysOnLayer(cut_layer);
        for (landing[cuts.start..cuts.end]) |*l| {
            if (l[0] != no_region and l[1] != no_region) try arrays.append(gpa, l.*);
            l.* = .{ no_region, no_region };
        }
        if (arrays.items.len == 0) continue;
        if (!stack_mod.described(problem.stack, cut_layer)) {
            refusal.layer = cut_layer;
            return error.UndescribedVia;
        }
        std.mem.sortUnstable([2]u32, arrays.items, {}, pairLess);
        const per_cut = problem.stack.sheet_res_ohm_sq[@backingInt(cut_layer)];
        var at: usize = 0;
        while (at < arrays.items.len) {
            var end = at + 1;
            while (end < arrays.items.len and std.mem.eql(u32, &arrays.items[end], &arrays.items[at])) end += 1;
            const key = arrays.items[at];
            try out.push(gpa, .at(key[0]), .at(key[1]), .resistance, closed_form.viaResistance(per_cut, @intCast(end - at)));
            at = end;
        }
    }
}

// ---- private ----

/// A layer's stack row, or null past the stack.
fn stackRow(stack: Stack, layer: LayerId) ?usize {
    const row = @backingInt(layer);
    return if (row < stack.sheet_res_ohm_sq.len) row else null;
}

/// Whether a pair is on one net, or touches a cut (no net).
fn sameNet(rects: *const RectStore, p: index.Pair) bool {
    const a = rects.net.items[@backingInt(p.a)];
    const b = rects.net.items[@backingInt(p.b)];
    return a == b or a == none or b == none;
}

/// The run two same-layer boxes share and the gap across it; null for a
/// corner, an overlap, or touching boxes.
fn facing(a: Bbox, b: Bbox) ?struct { run: Dbu, gap: Dbu } {
    const along_x = @min(a.xhi, b.xhi) - @max(a.xlo, b.xlo);
    const along_y = @min(a.yhi, b.yhi) - @max(a.ylo, b.ylo);
    if (along_x > 0 and along_y < 0) return .{ .run = along_x, .gap = -along_y };
    if (along_y > 0 and along_x < 0) return .{ .run = along_y, .gap = -along_x };
    return null;
}

/// One coupling element between the rows' nodes, lower net first.
fn pushCoupling(gpa: Allocator, rects: *const RectStore, p: index.Pair, ff: f64, out: *ParasiticNetwork) Allocator.Error!void {
    if (!(ff > 0.0 and std.math.isFinite(ff))) return;
    const a = @backingInt(p.a);
    const b = @backingInt(p.b);
    const a_first = rects.net.items[a] < rects.net.items[b];
    const lo = if (a_first) a else b;
    const hi = if (a_first) b else a;
    try out.push(gpa, rects.node.items[lo], rects.node.items[hi], .coupling_cap, ff);
}

fn layerLess(_: void, a: LayerId, b: LayerId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn pairLess(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}
