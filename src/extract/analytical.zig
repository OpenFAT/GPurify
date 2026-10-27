//! Closed-form extraction from the deck's process stack: the analytical
//! spine. In: every net's polygons (`NetPolys`), the deck's conductors,
//! global layers and vias, its stack. Out: a canonical `ParasiticNetwork`,
//! per conductor region a series R and a ground C, lateral and interlayer
//! coupling C, and via R. Ported from crates/extract/src/analytical.rs (the
//! spine, the regions and their R and C; the spatial joins are joins.zig,
//! the formulas closed_form.zig).
//!
//! A region is one edge-connected piece of a net's merged shapes on one
//! layer (conductor.zig), so a wire reads the same however it was cut into
//! polygons. R is `Rs·L/W` of the rectangle with the region's area and
//! perimeter; C is `Ca·A + Cf·P`. Both coupling terms are parallel-plate (no
//! fringing, no shielding), so lateral coupling is a lower bound.
//!
//! Contents:
//! - `pub const Problem = struct { store, nets, conductors, global, vias, stack, halo, grid }`
//! - `pub const Error = error{ Undescribed, UndescribedVia, InvalidGeometry } || Allocator.Error`
//! - `pub const Refusal = struct { layer: LayerId }`
//! - `pub fn extractInto(gpa: Allocator, problem: Problem, out: *ParasiticNetwork, refusal: *Refusal) Error!void`
//! - `pub fn nodeRectsInto(gpa: Allocator, problem: Problem, node: *std.ArrayList(NodeId), rect: *std.ArrayList(Bbox), refusal: *Refusal) Error!void`
//! - `pub const Sites = struct { net, box, layer_start, layer }`, `pub const no_site: u32`
//! - `pub fn siteNodesInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetPolys, global: []const LayerId, sites: Sites, out: []u32, refusal: *Refusal) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const stack_mod = @import("stack.zig");
const Stack = stack_mod.Stack;
const Vias = stack_mod.Vias;
const NetPolys = @import("net_polys.zig").NetPolys;
const Regions = @import("conductor.zig").Regions;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const closed_form = @import("closed_form.zig");
const joins = @import("joins.zig");

/// What the closed forms read: the store and its nets, the deck's `connect`
/// lines as plain columns, its stack, its coupling reach and the grid.
pub const Problem = struct {
    store: *const GeometryStore,
    nets: *const NetPolys,
    /// The layers that carry a net, in deck order: the coupling joins visit
    /// them in this order.
    conductors: []const LayerId,
    /// The `connect global` layers: no parasitics, no stack row needed.
    global: []const LayerId,
    vias: Vias,
    stack: Stack,
    /// Lateral coupling reach in thicknesses of the layer (the deck's
    /// `coupling_halo`); two rectangles farther apart do not couple.
    halo: f64,
    grid: Grid,
};

/// Why the closed forms refused a design; `Refusal.layer` names the layer
/// whose parasitics are unknown, rather than reading it as a perfect wire.
pub const Error = error{
    /// A conductor layer holds a net's shapes, but no stack row gives it a
    /// positive, finite sheet resistance.
    Undescribed,
    /// A via layer has a cut joining two conductor plates, but no stack row
    /// gives it a positive, finite resistance per cut.
    UndescribedVia,
    /// A net's shapes on the layer are not simple rectilinear rings, so they
    /// cannot be merged into conductors exactly.
    InvalidGeometry,
} || Allocator.Error;

pub const Refusal = struct { layer: LayerId = @fromBackingInt(0) };

/// Places to find on the network, one row each: a net, a box on it (a
/// device's channel, a label's shape), and the layers its region may be on,
/// CSR (`layer[layer_start[i]..layer_start[i + 1]]`).
pub const Sites = struct {
    net: []const u32,
    box: []const Bbox,
    layer_start: []const u32,
    layer: []const LayerId,
};

/// A site no region meets.
pub const no_site: u32 = std.math.maxInt(u32);

/// Extracts every net into `out` (cleared), left in canonical order. Net
/// `k`'s nodes follow those of nets `0..k`; a net of `n` regions has `n + 1`
/// nodes, its regions ascending by layer: region `i` puts a ground C on node
/// `i` and a resistor from node `i` to `i + 1`. A net with no region (shapes
/// on global layers only) has no node. An element that comes out zero is
/// left out.
///
/// Errors, in this order: `Undescribed` for the lowest non-global layer that
/// holds a net's shape and is not described; `InvalidGeometry` for the first
/// net, in net order, with a layer that does not validate; `UndescribedVia`
/// for the first via row, in deck order, with a cut on both plates and no
/// resistance per cut. `out` holds no usable network then.
pub fn extractInto(gpa: Allocator, problem: Problem, out: *ParasiticNetwork, refusal: *Refusal) Error!void {
    out.clear();
    try refuseUndescribed(gpa, problem, refusal);
    var regions: Regions = .empty;
    defer regions.deinit(gpa);
    try regionsInto(gpa, problem.store, problem.nets, problem.global, &regions, refusal);
    const node_of = try gpa.alloc(NodeId, regions.len());
    defer gpa.free(node_of);
    try nodesInto(gpa, &regions, problem.stack, problem.grid, node_of, out);
    var rects: joins.RectStore = .empty;
    defer rects.deinit(gpa);
    try rects.build(gpa, problem.store, problem.vias.cut, &regions, node_of);
    try joins.coupleInto(gpa, &rects, problem, out);
    try joins.viasInto(gpa, &rects, problem, out, refusal);
    try out.sortCanonical(gpa);
}

/// The conductor rectangles behind the nodes `extractInto` allocates for
/// the same problem: each region's disjoint rectangles tagged with its node,
/// ascending by node, into `node` and `rect` (cleared). A net's closing node
/// has none. A caller placing elements on geometry of its own (the Liberty
/// circuit) reads each node's place here. Errors: `InvalidGeometry`, as
/// `extractInto` gives it.
pub fn nodeRectsInto(gpa: Allocator, problem: Problem, node: *std.ArrayList(NodeId), rect: *std.ArrayList(Bbox), refusal: *Refusal) Error!void {
    node.clearRetainingCapacity();
    rect.clearRetainingCapacity();
    var regions: Regions = .empty;
    defer regions.deinit(gpa);
    try regionsInto(gpa, problem.store, problem.nets, problem.global, &regions, refusal);
    var next: usize = 0;
    for (0..regions.len()) |r| {
        const rects = regions.rectsOf(@intCast(r));
        try node.appendNTimes(gpa, .at(next), rects.len);
        try rect.appendSlice(gpa, rects);
        // A net's last region is followed by its closing node.
        const closes = r + 1 == regions.len() or regions.net.items[r + 1] != regions.net.items[r];
        next += @as(usize, 1) + @intFromBool(closes);
    }
}

/// Each site's node in the network `extractInto` builds over the same
/// store, nets and global layers, as its index in its net's run of nodes
/// (region `i` of a net is its node `i`): the region of the site's net, on
/// one of its layers, whose rectangles touch or cover its box most (the
/// lower on a tie), into `out`, one per site; `no_site` where none meets it
/// (a net drawn only on global layers, a box no region of those layers
/// touches). A corner is no touch. Errors: `InvalidGeometry`, as
/// `extractInto` gives it.
///
/// ponytail: each site scans its net's regions; a spatial index per net
/// when a net of thousands of regions carries thousands of sites.
pub fn siteNodesInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetPolys, global: []const LayerId, sites: Sites, out: []u32, refusal: *Refusal) Error!void {
    assert(out.len == sites.net.len and sites.box.len == sites.net.len and sites.layer_start.len == sites.net.len + 1);
    var regions: Regions = .empty;
    defer regions.deinit(gpa);
    try regionsInto(gpa, store, nets, global, &regions, refusal);
    // Each net's regions are one run: nets ascend, so a CSR over them.
    const net_count = nets.start.items.len -| 1;
    const first = try gpa.alloc(u32, net_count + 1);
    defer gpa.free(first);
    @memset(first, 0);
    for (regions.net.items) |n| first[n + 1] += 1;
    for (1..first.len) |n| first[n] += first[n - 1];
    for (sites.net, sites.box, out, 0..) |net, box, *node, i| {
        node.* = no_site;
        if (net >= net_count) continue;
        const layers = sites.layer[sites.layer_start[i]..sites.layer_start[i + 1]];
        var best: i128 = 0;
        for (first[net]..first[net + 1]) |r| {
            if (std.mem.findScalar(LayerId, layers, regions.layer.items[r]) == null) continue;
            var touch: i128 = 0;
            for (regions.rectsOf(@intCast(r))) |rect| touch += rect.contact(box);
            if (touch > best) {
                best = touch;
                node.* = @intCast(r - first[net]);
            }
        }
    }
}

// ---- private ----

/// The lowest non-global layer that holds a net's shape and is not
/// described.
fn refuseUndescribed(gpa: Allocator, problem: Problem, refusal: *Refusal) Error!void {
    const on_net = try gpa.alloc(bool, problem.store.layerCount());
    defer gpa.free(on_net);
    @memset(on_net, false);
    for (problem.nets.polys.items) |poly| on_net[@backingInt(problem.store.polyLayer(poly))] = true;
    for (on_net, 0..) |held, l| {
        const layer: LayerId = @fromBackingInt(@intCast(l));
        if (!held or stack_mod.isGlobal(problem.global, layer) or stack_mod.described(problem.stack, layer)) continue;
        refusal.layer = layer;
        return error.Undescribed;
    }
}

/// Every net's regions, nets ascending, so the nodes `nodesInto` allocates
/// are grouped by net. A global layer makes none.
fn regionsInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetPolys, global: []const LayerId, regions: *Regions, refusal: *Refusal) Error!void {
    const keep = try gpa.alloc(bool, store.layerCount());
    defer gpa.free(keep);
    for (keep, 0..) |*k, l| k.* = !stack_mod.isGlobal(global, @fromBackingInt(@intCast(l)));
    const net_count: u32 = @intCast(nets.start.items.len -| 1);
    for (0..net_count) |net| {
        if (try regions.pushNet(gpa, store, nets.polysOf(@intCast(net)), @intCast(net), keep)) |layer| {
            refusal.layer = layer;
            return error.InvalidGeometry;
        }
    }
}

/// Every region's node, ground C and R, net by net, into `out`; each
/// region's node into `node_of`. Region `i` of a net is a resistor from node
/// `i` to `i + 1`, chained in region order (a comb's fingers come out in
/// series; the net's total is unchanged), and a net closes on one more node.
/// Length and width are the sides of the rectangle with the region's area
/// and perimeter, the roots of `t² − (P/2)t + A`.
fn nodesInto(gpa: Allocator, regions: *const Regions, stack: Stack, grid: Grid, node_of: []NodeId, out: *ParasiticNetwork) Allocator.Error!void {
    const n = regions.len();
    assert(node_of.len == n);
    const ohm = try gpa.alloc(f64, n);
    defer gpa.free(ohm);
    const ff = try gpa.alloc(f64, n);
    defer gpa.free(ff);
    // Per-region closed forms: a plain map, every region independent. A
    // region's layer is described: `refuseUndescribed` ran first.
    for (regions.layer.items, regions.area.items, regions.perimeter.items, ohm, ff) |layer, area, perimeter, *r, *c| {
        const row = @backingInt(layer);
        // A rectilinear outline is never too fat for a rectangle: `(P/2)² ≥
        // 4A` holds for its box and only grows from there.
        const half = @divTrunc(perimeter, 2);
        const spread = geom.ops.isqrt(@max(@as(i128, half) * half - 4 * area, 0));
        const long = @divTrunc(half + spread, 2);
        const short = @divTrunc(half - spread, 2);
        r.* = if (short > 0) closed_form.segmentResistance(stack.sheet_res_ohm_sq[row], long, short) else 0.0;
        c.* = closed_form.groundCapacitance(stack_mod.value(stack.area_cap_af_um2, row), stack_mod.value(stack.fringe_cap_af_um, row), area, perimeter, grid);
    }
    var first: usize = 0;
    while (first < n) {
        const net = regions.net.items[first];
        var end = first;
        while (end < n and regions.net.items[end] == net) end += 1;
        for (first..end) |region| {
            const node: NodeId = .at(out.node_net.items.len);
            assert(@backingInt(node) + 1 < std.math.maxInt(u32));
            try out.node_net.append(gpa, net);
            try out.node_layer.append(gpa, regions.layer.items[region]);
            node_of[region] = node;
            // Zero values are dropped: a zero-ohm resistor is a short.
            if (ff[region] > 0.0 and std.math.isFinite(ff[region])) try out.push(gpa, node, .ground, .ground_cap, ff[region]);
            if (ohm[region] > 0.0 and std.math.isFinite(ohm[region])) try out.push(gpa, node, .at(@backingInt(node) + 1), .resistance, ohm[region]);
        }
        try out.node_net.append(gpa, net);
        try out.node_layer.append(gpa, regions.layer.items[end - 1]);
        first = end;
    }
}
