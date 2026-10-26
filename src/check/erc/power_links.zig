//! A network's conductors and connections, and its resistors: which layers
//! carry current and at what sheet resistance (refusing an unknown one),
//! every touch and via cut between two conductor polygons, a supply's feed
//! shape, and the edges one network's taps make (`edgesInto`, in the
//! solver's assembly order: every chain, then the metal links, then the
//! vias). In: the store, the deck's connectivity and stack, a network's
//! shapes and resolved taps. Out: masks, links, edges. Ported from
//! crates/check/src/erc/power.rs (`conductor_mask`, `sheet_resistances`,
//! `connections_into`, `push_edges`, `feed_shape`, `conducting`).
//!
//! Contents:
//! - `pub fn conductorMaskInto(gpa: Allocator, connectivity: *const Connectivity, layers: u32, out: *std.ArrayList(bool)) Allocator.Error!void`
//! - `pub fn sheetResistancesInto(gpa: Allocator, process: Process, layers: u32, out: *std.ArrayList(f64), diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub const Connections = struct`, `deinit`, `retainNoded(c, shape_of: []const u32)`
//! - `pub fn connectionsInto(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, out: *Connections) Allocator.Error!void`
//! - `pub fn conductingInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, conductor: []const bool, net: NetId, out: *std.ArrayList(PolyId)) Allocator.Error!void`
//! - `pub fn feedShape(store: *const GeometryStore, process: Process, shapes: []const PolyId) u32`
//! - `pub fn edgesInto(gpa: Allocator, store: *const GeometryStore, process: Process, sheet: []const f64, shape: []const PolyId, taps: *const TapTable, metal: Linked, via: Linked, profile: *ChainProfile, out: *std.ArrayList(Edge)) Allocator.Error!void`
//! - `pub const Linked = struct { links: []const Link, first: u32 }`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const Connectivity = @import("ingest").deck.Connectivity;
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const grid_ = @import("power_grid.zig");
const Process = grid_.Process;
const PowerError = grid_.PowerError;
const PowerDiag = grid_.PowerDiag;
const Edge = grid_.PowerGrid.Edge;
const not_a_node = grid_.not_a_node;
const chain = @import("power_chain.zig");
const ChainProfile = chain.ChainProfile;
const taps_ = @import("power_taps.zig");
const TapTable = taps_.TapTable;
const Link = taps_.Link;
const testing = std.testing;

/// A link list and the first tap request of its ends.
pub const Linked = struct { links: []const Link, first: u32 };

/// Every connection between two conductor polygons, by kind.
pub const Connections = struct {
    /// Touching pairs on one conductor layer.
    metal: std.ArrayList(Link) = .empty,
    /// Pairs joined by one cut, with the cut (four cuts, four rows).
    via: std.ArrayList(Link) = .empty,

    pub fn deinit(c: *Connections, gpa: Allocator) void {
        c.metal.deinit(gpa);
        c.via.deinit(gpa);
    }

    /// Keeps only links between two shapes that have a node (`shape_of`
    /// not `not_a_node`): a cut into a global layer lands on no node.
    pub fn retainNoded(c: *Connections, shape_of: []const u32) void {
        inline for (.{ &c.metal, &c.via }) |list| {
            var kept: usize = 0;
            for (list.items) |l| if (shape_of[l.a] != not_a_node and shape_of[l.b] != not_a_node) {
                list.items[kept] = l;
                kept += 1;
            };
            list.shrinkRetainingCapacity(kept);
        }
    }
};

/// Which layers carry current, indexed by layer, sized to cover every
/// conductor and at least `layers`.
pub fn conductorMaskInto(gpa: Allocator, connectivity: *const Connectivity, layers: u32, out: *std.ArrayList(bool)) Allocator.Error!void {
    var bound: usize = layers;
    for (connectivity.conductors) |l| bound = @max(bound, @as(usize, @backingInt(l)) + 1);
    out.clearRetainingCapacity();
    try out.appendNTimes(gpa, false, bound);
    for (connectivity.conductors) |l| out.items[@backingInt(l)] = true;
}

/// Sheet resistance of every current-carrying layer (each conductor, and
/// each cut between two non-global conductors), indexed by layer, 0 for the
/// rest. A missing, non-positive or non-finite value refuses
/// (`NoSheetResistance`, the layer in `diag`): zero would short a rail.
pub fn sheetResistancesInto(gpa: Allocator, process: Process, layers: u32, out: *std.ArrayList(f64), diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    const c = process.connectivity;
    var bound: usize = layers;
    for (c.conductors) |l| bound = @max(bound, @as(usize, @backingInt(l)) + 1);
    for (c.via_cut, c.via_connects) |cut, ends| if (carries(c, ends)) {
        bound = @max(bound, @as(usize, @backingInt(cut)) + 1);
    };
    out.clearRetainingCapacity();
    try out.appendNTimes(gpa, 0.0, bound);
    for (c.conductors) |l| try readSheet(process, l, out.items, diag);
    for (c.via_cut, c.via_connects) |cut, ends| if (carries(c, ends)) try readSheet(process, cut, out.items, diag);
}

pub fn connectionsInto(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, out: *Connections) Allocator.Error!void {
    out.metal.clearRetainingCapacity();
    out.via.clearRetainingCapacity();
    if (connectivity.intra_layer_touch) {
        var pairs: std.ArrayList([2]u32) = .empty;
        defer pairs.deinit(gpa);
        for (connectivity.conductors) |layer| {
            try net_.intraLayerEdgesInto(gpa, store, layer, &pairs);
            for (pairs.items) |p| try out.metal.append(gpa, .{ .a = p[0], .b = p[1], .layer = layer, .cut = not_a_node });
        }
    }
    var cuts: std.ArrayList([3]u32) = .empty;
    defer cuts.deinit(gpa);
    for (connectivity.via_cut, connectivity.via_connects) |cut, ends| {
        try net_.viaCutsInto(gpa, store, cut, ends, &cuts);
        for (cuts.items) |c| try out.via.append(gpa, .{ .a = c[1], .b = c[2], .layer = cut, .cut = c[0] });
    }
}

/// Appends `net`'s polygons on conducting layers, in order, holes out (a
/// hole shares its outer's net but is no conductor: as a node nothing
/// would link it and the solve would refuse it as an island).
pub fn conductingInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, conductor: []const bool, net: NetId, out: *std.ArrayList(PolyId)) Allocator.Error!void {
    for (nets.polysOf(net)) |p| {
        if (!conductor[@backingInt(store.polyLayer(p))] or nets.holes.isHole(p)) continue;
        try out.append(gpa, p);
    }
}

/// The index in `shapes` of a supply's feed point: supply enters from the
/// top, so its highest-layer, then largest-box, then lowest-index shape. A
/// missing `height_nm` reads as the substrate. Asserts `shapes` is not empty.
pub fn feedShape(store: *const GeometryStore, process: Process, shapes: []const PolyId) u32 {
    std.debug.assert(shapes.len > 0);
    var anchor: u32 = 0;
    var best_h = -std.math.inf(f64);
    var best_a: i128 = std.math.minInt(i128);
    const heights = process.stack.height_nm;
    for (shapes, 0..) |p, offset| {
        const l = @backingInt(store.polyLayer(p));
        const h = if (l < heights.len) heights[l] else 0.0;
        const a = store.polyBbox(p).area();
        if (h > best_h or (h == best_h and a > best_a)) {
            best_h = h;
            best_a = a;
            anchor = @intCast(offset);
        }
    }
    return anchor;
}

/// One network's edges, appended to `out` in assembly order: every shape's
/// chain, then the metal links, then the vias. Node indices are `taps`'.
pub fn edgesInto(gpa: Allocator, store: *const GeometryStore, process: Process, sheet: []const f64, shape: []const PolyId, taps: *const TapTable, metal: Linked, via: Linked, profile: *ChainProfile, out: *std.ArrayList(Edge)) Allocator.Error!void {
    for (shape, 0..) |poly, index| {
        const layer = store.polyLayer(poly);
        try profile.build(gpa, store, poly);
        const run = taps.chainOf(@intCast(index));
        var n = run[0];
        while (n + 1 < run[1]) : (n += 1) {
            const a = taps.node_along.items[n];
            const b = taps.node_along.items[n + 1];
            const seg = profile.segment(a, b);
            try out.append(gpa, .{
                .from = n,
                .to = n + 1,
                .ohms = sheet[@backingInt(layer)] * seg.squares,
                .width = seg.narrow,
                // Floored at one unit: a zero length would be Blech-immortal.
                .length = @max(b - a, 1),
                .layer = layer,
                .kind = .metal,
            });
        }
    }
    for (metal.links, 0..) |l, k| {
        const from = taps.req_node.items[metal.first + 2 * k];
        const to = taps.req_node.items[metal.first + 2 * k + 1];
        const width = chain.conductorWidth(store.polyBbox(@fromBackingInt(l.a)), store.polyBbox(@fromBackingInt(l.b)));
        // The shapes touch: the two taps coincide, so this is the floor.
        const length = chain.runLength(nodeAt(store, shape, taps, from), nodeAt(store, shape, taps, to));
        try out.append(gpa, .{ .from = from, .to = to, .ohms = sheet[@backingInt(l.layer)] * chain.squares(length, width), .width = width, .length = length, .layer = l.layer, .kind = .metal });
    }
    for (via.links, 0..) |l, k| {
        const a: PolyId = @fromBackingInt(l.a);
        const b: PolyId = @fromBackingInt(l.b);
        // One square of the cut layer per cut; each cut is its own edge.
        try out.append(gpa, .{
            .from = taps.req_node.items[via.first + 2 * k],
            .to = taps.req_node.items[via.first + 2 * k + 1],
            .ohms = sheet[@backingInt(l.layer)],
            .width = chain.conductorWidth(store.polyBbox(a), store.polyBbox(b)),
            .length = chain.viaLength(process, store.polyLayer(a), store.polyLayer(b)),
            .layer = l.layer,
            .kind = .via,
        });
    }
}

// ---- private ----

/// A cut between two conductors neither of which is global carries current.
fn carries(c: *const Connectivity, ends: [2]LayerId) bool {
    for (ends) |e| if (std.mem.indexOfScalar(LayerId, c.global, e) != null) return false;
    return true;
}

fn readSheet(process: Process, layer: LayerId, sheet: []f64, diag: *PowerDiag) PowerError!void {
    const i = @backingInt(layer);
    const rows = process.stack.sheet_res_ohm_sq;
    const v = if (i < rows.len) rows[i] else std.math.nan(f64);
    if (!(v > 0.0 and std.math.isFinite(v))) {
        diag.at = i;
        return error.NoSheetResistance;
    }
    sheet[i] = v;
}

/// Where node `n` sits: on its shape's centre line.
fn nodeAt(store: *const GeometryStore, shape: []const PolyId, taps: *const TapTable, n: u32) geom.Point {
    const host = store.polyBbox(shape[taps.node_shape.items[n]]);
    return chain.tapPoint(host, taps.node_along.items[n]);
}

test "sheet resistances refuse a carrying layer without one" {
    // Oracle: the documented contract, construct-from-answer: conductors 0
    // and 2 at 0.1 and 0.2 Ω/sq and cut 1 at 5 Ω read back by layer; each
    // carrying layer's value made zero, negative, infinite or missing is
    // refused naming that layer; cut 3 into global layer 4 needs no row.
    const l = struct {
        fn id(i: u16) LayerId {
            return @fromBackingInt(i);
        }
    }.id;
    const connectivity: Connectivity = .{
        .conductors = &.{ l(0), l(2), l(4) },
        .via_cut = &.{ l(1), l(3) },
        .via_connects = &.{ .{ l(0), l(2) }, .{ l(2), l(4) } },
        .global = &.{l(4)},
    };
    const gpa = testing.allocator;
    var out: std.ArrayList(f64) = .empty;
    defer out.deinit(gpa);
    var diag: PowerDiag = .{};
    const Read = struct {
        fn run(c: *const Connectivity, sheet: []f64, layers: u32, o: *std.ArrayList(f64), d: *PowerDiag) !void {
            const stack: @import("ingest").deck.ProcessStack = .{ .sheet_res_ohm_sq = sheet };
            try sheetResistancesInto(testing.allocator, .{ .grid = try geom.Grid.init(1000), .stack = &stack, .connectivity = c }, layers, o, d);
        }
    };
    var full = [_]f64{ 0.1, 5.0, 0.2, std.math.nan(f64), 0.3 };
    try Read.run(&connectivity, &full, 6, &out, &diag);
    try testing.expectEqualSlices(f64, &.{ 0.1, 5.0, 0.2, 0.0, 0.3, 0.0 }, out.items);
    var zeroed = [_]f64{ 0.1, 5.0, 0.2, 0.0, 0.3 };
    try Read.run(&connectivity, &zeroed, 2, &out, &diag);
    try testing.expectEqual(@as(usize, 5), out.items.len);
    for ([_]struct { u32, f64 }{ .{ 0, 0.0 }, .{ 1, -1.0 }, .{ 2, std.math.inf(f64) }, .{ 4, std.math.nan(f64) } }) |case| {
        var sheet = [_]f64{ 0.1, 5.0, 0.2, 0.0, 0.3 };
        sheet[case[0]] = case[1];
        try testing.expectError(error.NoSheetResistance, Read.run(&connectivity, &sheet, 5, &out, &diag));
        try testing.expectEqual(case[0], diag.at);
    }
    var short = [_]f64{ 0.1, 5.0 };
    try testing.expectError(error.NoSheetResistance, Read.run(&connectivity, &short, 5, &out, &diag));
    try testing.expectEqual(@as(u32, 2), diag.at);
}
