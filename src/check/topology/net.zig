//! Net extraction: which shapes are electrically one conductor. Two shapes
//! join when they are on one conductor layer and touch (with
//! `intra_layer_touch`), or when a via cut on the right layer shares a point
//! with both; every shape on a global layer is one net. Labels join nothing.
//! In: a `GeometryStore` and the deck's `Connectivity`. Out: a `NetTable`,
//! nets ranked by their least polygon. Ported from
//! crates/check/src/topology/{net,mod}.rs (`Holes` and `in_material` moved to
//! rects.zig).
//!
//! Contents:
//! - `pub const NetId = enum(u32) { none = maxInt(u32), _ }`
//! - `pub const NetTable = struct`, `deinit`, `netCount(t: *const NetTable) u32`,
//!   `isGlobalOnly(t: *const NetTable, net: NetId) bool`, `netOf(t: *const NetTable, poly: PolyId) NetId`,
//!   `netColumn(t: *const NetTable) []const u32`, `polysOf(t: *const NetTable, net: NetId) []const PolyId`,
//!   `sameNet(t: *const NetTable, a: PolyId, b: PolyId) bool`,
//!   `pathInto(t: *const NetTable, gpa: Allocator, from: PolyId, to: PolyId, out: *std.ArrayList(PolyId)) Allocator.Error!bool`
//! - `pub fn extractNetsInto(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, out: *NetTable) Allocator.Error!void`
//! - `pub fn intraLayerEdgesInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, out: *std.ArrayList([2]u32)) Allocator.Error!void`
//! - `pub fn viaEdgesInto(gpa: Allocator, store: *const GeometryStore, cut: LayerId, connects: [2]LayerId, out: *std.ArrayList([2]u32)) Allocator.Error!void`
//! - `pub fn viaCutsInto(gpa: Allocator, store: *const GeometryStore, cut: LayerId, connects: [2]LayerId, out: *std.ArrayList([3]u32)) Allocator.Error!void`
//! - `pub fn polysIntersect(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, a: PolyId, b: PolyId) Allocator.Error!bool`
//! - `pub fn retainIntersectingInto(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, pairs: []const Pair, out: *std.ArrayList(Pair)) Allocator.Error!void`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const SpatialIndex = geom.index.SpatialIndex;
const Pair = geom.index.Pair;
const ops = geom.ops;
const Connectivity = @import("ingest").deck.Connectivity;
const rects = @import("../rects.zig");
const Holes = rects.Holes;

/// One electrical net: a dense rank over `0..netCount()`, ascending by each
/// net's least `PolyId`, so ids are canonical across runs and threads.
/// `none`: the polygon is on no net; never listed, and `sameNet` is false
/// for it even against itself.
pub const NetId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Which net each polygon belongs to, both ways. Only polygons on a
/// conductor or global layer have a net; a hole row is on its polygon's net.
/// Invariant: `net_start` is CSR over `polys`, each net's polygons
/// ascending; `poly_net` has one row per store row.
pub const NetTable = struct {
    poly_net: std.ArrayList(NetId) = .empty,
    net_start: std.ArrayList(u32) = .empty,
    polys: std.ArrayList(PolyId) = .empty,
    /// Every join the last extraction made, `(a, b)` store rows: kept for
    /// `pathInto` and so a second extraction reuses the allocation.
    edges: std.ArrayList([2]u32) = .empty,
    labels: std.ArrayList(u32) = .empty,
    scratch: EdgeScratch = .{},
    /// Hole rows bound to their outers, over every layer of the store.
    holes: Holes = .{},
    /// Per net: every shape is on a global layer (the substrate alone).
    global_only: std.ArrayList(bool) = .empty,

    pub fn deinit(t: *NetTable, gpa: Allocator) void {
        t.poly_net.deinit(gpa);
        t.net_start.deinit(gpa);
        t.polys.deinit(gpa);
        t.edges.deinit(gpa);
        t.labels.deinit(gpa);
        t.scratch.deinit(gpa);
        t.holes.deinit(gpa);
        t.global_only.deinit(gpa);
    }

    /// Nets; `none` is not one of them.
    pub fn netCount(t: *const NetTable) u32 {
        return @intCast(@max(t.net_start.items.len, 1) - 1);
    }

    pub fn isGlobalOnly(t: *const NetTable, net: NetId) bool {
        return t.global_only.items[@backingInt(net)];
    }

    pub fn netOf(t: *const NetTable, poly: PolyId) NetId {
        return t.poly_net.items[@backingInt(poly)];
    }

    /// Every store row's net as raw `u32`s, `maxInt(u32)` for none: the
    /// column the proximity net rules take (`proximity.no_net` matches).
    pub fn netColumn(t: *const NetTable) []const u32 {
        return @ptrCast(t.poly_net.items);
    }

    /// One net's polygons, ascending; empty for `none`.
    pub fn polysOf(t: *const NetTable, net: NetId) []const PolyId {
        if (net == .none) return &.{};
        const n = @backingInt(net);
        return t.polys.items[t.net_start.items[n]..t.net_start.items[n + 1]];
    }

    /// False when either polygon is on no net.
    pub fn sameNet(t: *const NetTable, a: PolyId, b: PolyId) bool {
        const na = t.netOf(a);
        return na != .none and na == t.netOf(b);
    }

    /// The fewest polygons joining `from` to `to` through the extraction's
    /// joins, `from` first and `to` last, into `out` (cleared and refilled):
    /// the path a breadth-first walk taking each polygon's neighbours lowest
    /// first reaches `to` along, so the same on every run. False when they
    /// are on different nets or none, or the table holds no joins. Where a
    /// short between two labelled nets runs (catalog LVS-005). `O(joins)`.
    pub fn pathInto(t: *const NetTable, gpa: Allocator, from: PolyId, to: PolyId, out: *std.ArrayList(PolyId)) Allocator.Error!bool {
        out.clearRetainingCapacity();
        const rows = t.poly_net.items.len;
        const f = @backingInt(from);
        const g = @backingInt(to);
        if (f >= rows or g >= rows) return false;
        const net = t.poly_net.items[f];
        if (net == .none or net != t.poly_net.items[g]) return false;
        if (f == g) {
            try out.append(gpa, from);
            return true;
        }
        // The net's joins as CSR, each list ascending: a deterministic walk.
        const start = try gpa.alloc(u32, rows + 1);
        defer gpa.free(start);
        @memset(start, 0);
        for (t.edges.items) |e| if (onNet(t, e, net)) {
            start[e[0]] += 1;
            start[e[1]] += 1;
        };
        var sum: u32 = 0;
        for (start) |*slot| {
            const degree = slot.*;
            slot.* = sum;
            sum += degree;
        }
        const next_free = try gpa.dupe(u32, start);
        defer gpa.free(next_free);
        const neighbour = try gpa.alloc(u32, sum);
        defer gpa.free(neighbour);
        for (t.edges.items) |e| if (onNet(t, e, net)) {
            for ([2][2]u32{ e, .{ e[1], e[0] } }) |d| {
                neighbour[next_free[d[0]]] = d[1];
                next_free[d[0]] += 1;
            }
        };
        for (start[0..rows], start[1..]) |lo, hi| std.mem.sortUnstable(u32, neighbour[lo..hi], {}, std.sort.asc(u32));
        const parent = try gpa.alloc(u32, rows);
        defer gpa.free(parent);
        @memset(parent, no_parent);
        parent[f] = f;
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(gpa);
        try queue.append(gpa, f);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const at = queue.items[head];
            if (at == g) {
                var step = at;
                try out.append(gpa, to);
                while (step != f) {
                    step = parent[step];
                    try out.append(gpa, @fromBackingInt(step));
                }
                std.mem.reverse(PolyId, out.items);
                return true;
            }
            for (neighbour[start[at]..start[at + 1]]) |n| {
                if (parent[n] != no_parent) continue;
                parent[n] = at;
                try queue.append(gpa, n);
            }
        }
        return false;
    }
};

const no_parent: u32 = std.math.maxInt(u32);

/// Edge pairs the direct scan may examine before the sweep pays for itself
/// (a rounded tuning constant, not measured).
const direct_pair_budget: usize = 1 << 10;

/// The edge builders' working storage, dead between calls.
const EdgeScratch = struct {
    index: SpatialIndex = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    touching: std.ArrayList(Pair) = .empty,
    on_lower: std.ArrayList(Pair) = .empty,
    on_upper: std.ArrayList(Pair) = .empty,
    landings: std.ArrayList([3]u32) = .empty,

    fn deinit(s: *EdgeScratch, gpa: Allocator) void {
        s.index.deinit(gpa);
        s.pairs.deinit(gpa);
        s.touching.deinit(gpa);
        s.on_lower.deinit(gpa);
        s.on_upper.deinit(gpa);
        s.landings.deinit(gpa);
    }
};

/// Extracts nets from geometry into `out` (cleared and refilled). Only
/// polygons on a `conductors` or `global` layer get a net. Polygons join
/// when they are on one conductor layer and share a point (with
/// `intra_layer_touch`), when a cut on a `via_cut` layer shares a point with
/// one on each of the two layers it connects (the cut is on no net), or
/// when they are on one global layer. Boxes only prune; every join is an
/// exact test. Asserts every layer named is in the store, and the store's
/// rows fit `u32`.
pub fn extractNetsInto(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, out: *NetTable) Allocator.Error!void {
    const rows = store.polyCount();
    const all_layers = try gpa.alloc(LayerId, store.layerCount());
    defer gpa.free(all_layers);
    for (all_layers, 0..) |*l, i| l.* = @fromBackingInt(@intCast(i));
    try out.holes.build(gpa, store, all_layers);
    out.edges.clearRetainingCapacity();
    if (connectivity.intra_layer_touch) {
        for (connectivity.conductors) |layer| try intraLayerEdgesAppend(gpa, store, &out.holes, layer, &out.scratch, &out.edges);
    }
    for (connectivity.via_cut, connectivity.via_connects) |cut, connects| {
        try viaEdgesAppend(gpa, store, &out.holes, cut, connects, &out.scratch, &out.edges);
    }
    // A global layer is one net: chain its shapes, holes included.
    for (connectivity.global) |layer| {
        const r = store.polysOnLayer(layer);
        if (r.len() < 2) continue;
        for (r.start + 1..r.end) |row| try out.edges.append(gpa, .{ r.start, @intCast(row) });
    }
    const conducts = try gpa.alloc(bool, store.layerCount());
    defer gpa.free(conducts);
    @memset(conducts, false);
    for (connectivity.conductors) |l| conducts[@backingInt(l)] = true;
    for (connectivity.global) |l| conducts[@backingInt(l)] = true;
    // A hole row is part of its outer's polygon: it shares the outer's net.
    for (out.holes.outers(), out.holes.holes()) |outer, hole| {
        if (!conducts[@backingInt(store.polyLayer(outer))]) continue;
        const o = @backingInt(outer);
        const h = @backingInt(hole);
        try out.edges.append(gpa, .{ @min(o, h), @max(o, h) });
    }
    try geom.connectivity.componentsInto(gpa, rows, out.edges.items, &out.labels);

    // Labels to dense ids: a label is its component's least row, so walking
    // rows ascending ranks nets by their least polygon.
    try out.poly_net.resize(gpa, rows);
    const rank = try gpa.alloc(u32, rows);
    defer gpa.free(rank);
    @memset(rank, no_parent);
    var next: u32 = 0;
    for (out.poly_net.items, out.labels.items, 0..) |*net, label, row| {
        if (!conducts[@backingInt(store.polyLayer(@fromBackingInt(@intCast(row))))]) {
            net.* = .none;
            continue;
        }
        if (rank[label] == no_parent) {
            rank[label] = next;
            next += 1;
        }
        net.* = @fromBackingInt(rank[label]);
    }
    try rebuildIndex(gpa, out.poly_net.items, next, &out.net_start, &out.polys);
    if (builtin.mode == .debug) assert(partitionHolds(out));
    try out.global_only.resize(gpa, next);
    @memset(out.global_only.items, true);
    for (out.poly_net.items, 0..) |net, row| {
        if (net == .none) continue;
        const layer = store.polyLayer(@fromBackingInt(@intCast(row)));
        if (std.mem.indexOfScalar(LayerId, connectivity.global, layer) == null) out.global_only.items[@backingInt(net)] = false;
    }
}

/// Edges `a < b` from shapes touching on one conductor layer, into `out`
/// (cleared and refilled).
pub fn intraLayerEdgesInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var holes: Holes = .{};
    defer holes.deinit(gpa);
    try holes.build(gpa, store, &.{layer});
    var scratch: EdgeScratch = .{};
    defer scratch.deinit(gpa);
    try intraLayerEdgesAppend(gpa, store, &holes, layer, &scratch, out);
}

/// Edges `(lower, upper)` from a via cut sharing a point with shapes on
/// both layers it joins, ascending and deduplicated, into `out` (cleared
/// and refilled). A cut over one layer only is no edge.
pub fn viaEdgesInto(gpa: Allocator, store: *const GeometryStore, cut: LayerId, connects: [2]LayerId, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var holes: Holes = .{};
    defer holes.deinit(gpa);
    try holes.build(gpa, store, &.{ cut, connects[0], connects[1] });
    var scratch: EdgeScratch = .{};
    defer scratch.deinit(gpa);
    try viaEdgesAppend(gpa, store, &holes, cut, connects, &scratch, out);
}

/// Every `(cut, lower, upper)` a via cut joins, one row per cut and pair,
/// ascending by cut, into `out` (cleared and refilled). Unlike
/// `viaEdgesInto`, a stack of cuts is not merged.
pub fn viaCutsInto(gpa: Allocator, store: *const GeometryStore, cut: LayerId, connects: [2]LayerId, out: *std.ArrayList([3]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var holes: Holes = .{};
    defer holes.deinit(gpa);
    try holes.build(gpa, store, &.{ cut, connects[0], connects[1] });
    var scratch: EdgeScratch = .{};
    defer scratch.deinit(gpa);
    try landingsAppend(gpa, store, &holes, cut, connects, &scratch, out);
}

/// Whether two store rows share at least one point, holes excluded: the
/// exact re-test behind every box prune. A hole row is never a polygon of
/// its own here.
pub fn polysIntersect(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, a: PolyId, b: PolyId) Allocator.Error!bool {
    if (holes.isHole(a) or holes.isHole(b)) return false;
    const ra = store.polyVerts(a);
    const rb = store.polyVerts(b);
    if (ra.xs.len == 0 or rb.xs.len == 0) return false;
    // A hole's edge is the polygon's boundary too.
    for (0..holes.holesOf(a).len + 1) |i| {
        const ring_a = store.polyVerts(if (i == 0) a else holes.holesOf(a)[i - 1]);
        for (0..holes.holesOf(b).len + 1) |j| {
            const ring_b = store.polyVerts(if (j == 0) b else holes.holesOf(b)[j - 1]);
            if (try ringsMeet(gpa, ring_a, ring_b)) return true;
        }
    }
    // Boundaries that do not meet are nested or disjoint: one vertex decides,
    // off every boundary, so inclusive containment is strict here.
    return rects.inMaterial(store, holes, b, .{ .x = ra.xs[0], .y = ra.ys[0] }) or
        rects.inMaterial(store, holes, a, .{ .x = rb.xs[0], .y = rb.ys[0] });
}

/// The pairs whose polygons really intersect, in input order, into `out`
/// (cleared and refilled).
pub fn retainIntersectingInto(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, pairs: []const Pair, out: *std.ArrayList(Pair)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (pairs) |p| if (try polysIntersect(gpa, store, holes, p.a, p.b)) try out.append(gpa, p);
}

// ---- private ----

fn onNet(t: *const NetTable, e: [2]u32, net: NetId) bool {
    const rows = t.poly_net.items.len;
    return e[0] < rows and e[1] < rows and t.poly_net.items[e[0]] == net and t.poly_net.items[e[1]] == net;
}

/// The reverse CSR index of a per-polygon net assignment over `net_count`
/// nets.
fn rebuildIndex(gpa: Allocator, poly_net: []const NetId, net_count: u32, net_start: *std.ArrayList(u32), polys: *std.ArrayList(PolyId)) Allocator.Error!void {
    try net_start.resize(gpa, @as(usize, net_count) + 1);
    @memset(net_start.items, 0);
    for (poly_net) |net| if (net != .none) {
        net_start.items[@backingInt(net) + 1] += 1;
    };
    for (1..net_start.items.len) |i| net_start.items[i] += net_start.items[i - 1];
    const cursor = try gpa.dupe(u32, net_start.items[0..net_count]);
    defer gpa.free(cursor);
    try polys.resize(gpa, net_start.items[net_count]);
    for (poly_net, 0..) |net, row| if (net != .none) {
        const slot = &cursor[@backingInt(net)];
        polys.items[slot.*] = @fromBackingInt(@intCast(row));
        slot.* += 1;
    };
}

/// Every polygon with a net is listed once, under it; each net ascends; nets
/// rank by their least polygon.
fn partitionHolds(t: *const NetTable) bool {
    var listed: usize = 0;
    var least: ?u32 = null;
    for (0..t.netCount()) |n| {
        const polys = t.polysOf(@fromBackingInt(@intCast(n)));
        listed += polys.len;
        if (polys.len == 0) return false;
        const first = @backingInt(polys[0]);
        if (least != null and first <= least.?) return false;
        least = first;
        for (polys, 0..) |p, i| {
            if (i > 0 and @backingInt(polys[i - 1]) >= @backingInt(p)) return false;
            if (@backingInt(t.netOf(p)) != n) return false;
        }
    }
    var with_net: usize = 0;
    for (t.poly_net.items) |net| with_net += @intFromBool(net != .none);
    return listed == with_net;
}

fn intraLayerEdgesAppend(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, layer: LayerId, scratch: *EdgeScratch, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    try scratch.index.build(gpa, store, layer);
    // Distance zero counts touching: shapes sharing only an edge are one.
    try geom.index.candidatePairsInto(gpa, store, &scratch.index, 0, &scratch.pairs);
    try retainIntersectingInto(gpa, store, holes, scratch.pairs.items, &scratch.touching);
    for (scratch.touching.items) |p| try out.append(gpa, .{ @backingInt(p.a), @backingInt(p.b) });
}

/// Appends a via layer's `(lower, upper)` edges, sorting and deduplicating
/// only those: a stack of cuts over one pair of shapes is one edge.
fn viaEdgesAppend(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, cut: LayerId, connects: [2]LayerId, scratch: *EdgeScratch, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    scratch.landings.clearRetainingCapacity();
    try landingsAppend(gpa, store, holes, cut, connects, scratch, &scratch.landings);
    const base = out.items.len;
    for (scratch.landings.items) |l| try out.append(gpa, .{ l[1], l[2] });
    const tail = out.items[base..];
    std.mem.sortUnstable([2]u32, tail, {}, lessPair);
    var kept: usize = 0;
    for (tail) |e| {
        if (kept > 0 and std.mem.eql(u32, &tail[kept - 1], &e)) continue;
        tail[kept] = e;
        kept += 1;
    }
    out.shrinkRetainingCapacity(base + kept);
}

fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

/// Appends `(cut, lower, upper)` for every pair of conductors a cut lands
/// on, ascending by cut.
fn landingsAppend(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, cut: LayerId, connects: [2]LayerId, scratch: *EdgeScratch, out: *std.ArrayList([3]u32)) Allocator.Error!void {
    if (store.polysOnLayer(cut).len() == 0) return;
    try cutsLandingOn(gpa, store, holes, cut, connects[0], scratch, &scratch.on_lower);
    try cutsLandingOn(gpa, store, holes, cut, connects[1], scratch, &scratch.on_upper);
    // Both lists ascend by `(cut, conductor)`: merge on the cut column.
    const lower = scratch.on_lower.items;
    const upper = scratch.on_upper.items;
    var lo: usize = 0;
    var hi: usize = 0;
    while (lo < lower.len and hi < upper.len) {
        const a = @backingInt(lower[lo].a);
        const b = @backingInt(upper[hi].a);
        if (a < b) {
            lo += 1;
            continue;
        }
        if (b < a) {
            hi += 1;
            continue;
        }
        var lo_end = lo;
        while (lo_end < lower.len and @backingInt(lower[lo_end].a) == a) lo_end += 1;
        var hi_end = hi;
        while (hi_end < upper.len and @backingInt(upper[hi_end].a) == a) hi_end += 1;
        for (lower[lo..lo_end]) |l| for (upper[hi..hi_end]) |u| {
            try out.append(gpa, .{ a, @backingInt(l.b), @backingInt(u.b) });
        };
        lo = lo_end;
        hi = hi_end;
    }
}

/// Every `(cut, conductor)` pair where the cut really lands, ascending.
fn cutsLandingOn(gpa: Allocator, store: *const GeometryStore, holes: *const Holes, cut: LayerId, layer: LayerId, scratch: *EdgeScratch, out: *std.ArrayList(Pair)) Allocator.Error!void {
    try scratch.index.build(gpa, store, layer);
    try geom.index.crossLayerPairsInto(gpa, store, cut, &scratch.index, 0, &scratch.pairs);
    try retainIntersectingInto(gpa, store, holes, scratch.pairs.items, out);
}

/// Whether any edge of one ring meets any edge of the other, touching
/// included.
fn ringsMeet(gpa: Allocator, a: geom.Ring, b: geom.Ring) Allocator.Error!bool {
    if (a.xs.len *| b.xs.len <= direct_pair_budget) return ringsMeetDirect(a, b);
    return ringsMeetSweep(gpa, a, b);
}

/// `ringsMeet` by exhaustive pair scan; the reference implementation.
fn ringsMeetDirect(a: geom.Ring, b: geom.Ring) bool {
    for (0..a.xs.len) |i| {
        const e = ops.ringEdge(a.xs, a.ys, i);
        for (0..b.xs.len) |j| if (ops.segmentsIntersect(e, ops.ringEdge(b.xs, b.ys, j))) return true;
    }
    return false;
}

/// `ringsMeet` by plane sweep over edges ascending by left x: an entering
/// edge is tested against the other ring's live edges, then joins its own.
fn ringsMeetSweep(gpa: Allocator, a: geom.Ring, b: geom.Ring) Allocator.Error!bool {
    const rings = [2]geom.Ring{ a, b };
    var order: [2][]u32 = undefined;
    var span: [2][][2]Dbu = undefined;
    var live: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&live) |*l| l.deinit(gpa);
    var made: usize = 0;
    defer for (0..made) |k| {
        gpa.free(order[k]);
        gpa.free(span[k]);
    };
    for (rings, 0..) |r, k| {
        span[k] = try gpa.alloc([2]Dbu, r.xs.len);
        order[k] = gpa.alloc(u32, r.xs.len) catch |err| {
            gpa.free(span[k]);
            return err;
        };
        made += 1;
        for (span[k], order[k], 0..) |*s, *o, i| {
            const nx = r.xs[if (i + 1 == r.xs.len) 0 else i + 1];
            s.* = .{ @min(r.xs[i], nx), @max(r.xs[i], nx) };
            o.* = @intCast(i);
        }
        std.mem.sortUnstable(u32, order[k], span[k], struct {
            fn less(sp: [][2]Dbu, x: u32, y: u32) bool {
                return sp[x][0] < sp[y][0] or (sp[x][0] == sp[y][0] and sp[x][1] < sp[y][1]);
            }
        }.less);
    }
    var next = [2]usize{ 0, 0 };
    while (next[0] < order[0].len or next[1] < order[1].len) {
        // `maxInt(i64)` is outside the domain, so a spent side never wins.
        var key: [2]i64 = undefined;
        for (&key, 0..) |*kk, k| kk.* = if (next[k] < order[k].len) span[k][order[k][next[k]]][0] else std.math.maxInt(i64);
        const sweep_x = @min(key[0], key[1]);
        for (&live, 0..) |*l, k| {
            var kept: usize = 0;
            for (l.items) |e| {
                if (span[k][e][1] < sweep_x) continue;
                l.items[kept] = e;
                kept += 1;
            }
            l.shrinkRetainingCapacity(kept);
        }
        const side: usize = if (key[0] <= key[1]) 0 else 1;
        const other = 1 - side;
        const edge = order[side][next[side]];
        next[side] += 1;
        const e = ops.ringEdge(rings[side].xs, rings[side].ys, edge);
        for (live[other].items) |j| if (ops.segmentsIntersect(e, ops.ringEdge(rings[other].xs, rings[other].ys, j))) return true;
        try live[side].append(gpa, edge);
    }
    return false;
}

/// A star of `n` vertices centred on `(cx, cy)`, alternating two radii so
/// edge x-extents overlap heavily.
fn star(n: usize, cx: i64, cy: i64, near: f64, far: f64, xs: []i64, ys: []i64) void {
    for (0..n) |i| {
        const radius = if (i % 2 == 0) far else near;
        const theta = std.math.tau * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        xs[i] = cx + @as(i64, @intFromFloat(@cos(theta) * radius));
        ys[i] = cy + @as(i64, @intFromFloat(@sin(theta) * radius));
    }
}

test "a stated assignment builds the reverse index it implies" {
    // Oracle: construct-from-answer. Polygons 1 and 4 are on net 0 and 0 and
    // 2 on net 1, so the index is two nets of two, each ascending; markers
    // alone give no net.
    const gpa = std.testing.allocator;
    var net_start: std.ArrayList(u32) = .empty;
    defer net_start.deinit(gpa);
    var polys: std.ArrayList(PolyId) = .empty;
    defer polys.deinit(gpa);
    const n = struct {
        fn of(v: u32) NetId {
            return @fromBackingInt(v);
        }
    }.of;
    try rebuildIndex(gpa, &.{ n(1), n(0), n(1), .none, n(0) }, 2, &net_start, &polys);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4 }, net_start.items);
    const p = struct {
        fn of(v: u32) PolyId {
            return @fromBackingInt(v);
        }
    }.of;
    try std.testing.expectEqualSlices(PolyId, &.{ p(1), p(4), p(0), p(2) }, polys.items);
    try rebuildIndex(gpa, &.{ .none, .none }, 0, &net_start, &polys);
    try std.testing.expectEqualSlices(u32, &.{0}, net_start.items);
    try std.testing.expectEqual(@as(usize, 0), polys.items.len);
}

test "the sweep and the exhaustive scan agree on every ring pair" {
    // Oracle: differential against `ringsMeetDirect`, the exhaustive scan,
    // on star pairs either side of the pair budget, meeting and apart; and
    // the law that meeting is symmetric.
    comptime assert(8 * 8 <= direct_pair_budget and 64 * 64 > direct_pair_budget);
    const gpa = std.testing.allocator;
    var ax: [129]i64 = undefined;
    var ay: [129]i64 = undefined;
    var bx: [129]i64 = undefined;
    var by: [129]i64 = undefined;
    var saw_meeting = false;
    var saw_apart = false;
    for ([_]usize{ 3, 8, 33, 64, 129 }) |n| {
        star(n, 0, 0, 400, 1000, &ax, &ay);
        for ([_]usize{ 3, 8, 33, 64, 129 }) |m| for ([_]i64{ 0, 300, 900, 1600, 4000 }) |offset| {
            star(m, offset, 0, 80, 200, &bx, &by);
            const a: geom.Ring = .{ .xs = ax[0..n], .ys = ay[0..n] };
            const b: geom.Ring = .{ .xs = bx[0..m], .ys = by[0..m] };
            const direct = ringsMeetDirect(a, b);
            try std.testing.expectEqual(direct, try ringsMeetSweep(gpa, a, b));
            try std.testing.expectEqual(direct, try ringsMeetSweep(gpa, b, a));
            saw_meeting = saw_meeting or direct;
            saw_apart = saw_apart or !direct;
        };
    }
    try std.testing.expect(saw_meeting and saw_apart);
}
