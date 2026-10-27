//! The circuit builder's tables: rectangles (one proto node each), proto
//! nodes joined by a disjoint set, resistors, capacitors and the per-layer
//! rectangle index, plus the box arithmetic every builder transform shares.
//! In: `Loaded` + `Extracted`. Out: a `Builder` the circuit_*.zig transforms
//! fill and `finish` numbers. Ported from src/liberty/circuit.rs (`Union`,
//! `RectIndex`, `shared`, `gap2`, `Builder::{new, proto, rect_node,
//! anchor, anchor_hub, stack_row, is_wire, resistor, cap}`; its `contact`
//! is geom's `Bbox.contact`, which PEX's site placement shares).
//!
//! Proto node 0 is ground; rectangle `r` is proto node `r + 1`; a net with
//! no rectangle (or a substrate contact) gets a hub node on first use.
//! Everything lives in the caller's arena.
//!
//! Contents:
//! - `pub const ground: u32`, `pub const none: u32`
//! - `pub const RectIndex = struct`, `init(cell: i64) RectIndex`, `insert`, `query`
//! - `pub const Builder = struct`, `init`, `proto`, `rectNode`, `find`, `join`, `anchor`, `anchorHub`, `stackRow`, `isWire`, `resistor`, `cap`, `sortedCaps`
//! - `pub fn findIn(parent: []u32, start: u32) u32`, `pub fn joinIn(parent: []u32, x: u32, y: u32) void`
//! - `pub fn shared(a: Bbox, b: Bbox) [2]i64`, `pub fn gap2(a: Bbox, b: Bbox) i128`
//! - `pub const LayerIndex = struct { layer, index }`, `Builder.stack(b) *const ProcessStack`, `lessThan`: the sort context's hook

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const NetId = @import("check").topology.net.NetId;
const ProcessStack = @import("ingest").deck.ProcessStack;
const Loaded = @import("../load.zig").Loaded;
const Extracted = @import("../extracted.zig").Extracted;

/// The simulator's ground, proto node 0 and final node 0.
pub const ground: u32 = 0;

/// No hub yet.
pub const none: u32 = std.math.maxInt(u32);

/// Rectangles bucketed on a uniform grid; one over more than `big_cells`
/// cells is kept in a list every query scans instead.
pub const RectIndex = struct {
    cell: i64,
    buckets: std.AutoHashMapUnmanaged([2]i64, std.ArrayList(u32)) = .empty,
    big: std.ArrayList(u32) = .empty,

    pub fn init(cell: i64) RectIndex {
        return .{ .cell = @max(cell, 1) };
    }

    pub fn insert(x: *RectIndex, arena: Allocator, id: u32, b: Bbox) Allocator.Error!void {
        const c = x.cells(b);
        if ((c[2] - c[0] + 1) * (c[3] - c[1] + 1) > big_cells) return x.big.append(arena, id);
        var gx = c[0];
        while (gx <= c[2]) : (gx += 1) {
            var gy = c[1];
            while (gy <= c[3]) : (gy += 1) {
                const slot = try x.buckets.getOrPut(arena, .{ gx, gy });
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(arena, id);
            }
        }
    }

    /// Every id whose cells meet `b`'s, each once, ascending, into `out`.
    pub fn query(x: *const RectIndex, arena: Allocator, b: Bbox, out: *std.ArrayList(u32)) Allocator.Error!void {
        out.clearRetainingCapacity();
        const c = x.cells(b);
        var gx = c[0];
        while (gx <= c[2]) : (gx += 1) {
            var gy = c[1];
            while (gy <= c[3]) : (gy += 1) {
                if (x.buckets.get(.{ gx, gy })) |ids| try out.appendSlice(arena, ids.items);
            }
        }
        try out.appendSlice(arena, x.big.items);
        std.mem.sortUnstable(u32, out.items, {}, std.sort.asc(u32));
        var kept: usize = 0;
        for (out.items) |id| {
            if (kept > 0 and out.items[kept - 1] == id) continue;
            out.items[kept] = id;
            kept += 1;
        }
        out.shrinkRetainingCapacity(kept);
    }

    fn cells(x: *const RectIndex, b: Bbox) [4]i64 {
        return .{ @divFloor(b.xlo, x.cell), @divFloor(b.ylo, x.cell), @divFloor(b.xhi, x.cell), @divFloor(b.yhi, x.cell) };
    }
};

/// One conductor layer's rectangle index.
pub const LayerIndex = struct { layer: LayerId, index: RectIndex };

/// The builder's tables; see the module doc for the node numbering.
pub const Builder = struct {
    arena: Allocator,
    loaded: *const Loaded,
    extracted: *const Extracted,
    /// Metres per database unit.
    um: f64,
    rect: std.ArrayList(Bbox) = .empty,
    rect_layer: std.ArrayList(LayerId) = .empty,
    rect_net: std.ArrayList(NetId) = .empty,
    /// Same-net perimeter each rectangle shares with a neighbour, dbu.
    rect_shared: std.ArrayList(i64) = .empty,
    /// Rectangles per net.
    net_rects: []std.ArrayList(u32),
    /// One per conductor layer holding rectangles, ascending by layer.
    index: std.ArrayList(LayerIndex) = .empty,
    /// One proto node per net, lazily; `none` until then.
    hub: []u32,
    /// Disjoint-set parents over proto nodes; the smallest member is the
    /// root, so numbering does not depend on union order.
    parent: std.ArrayList(u32) = .empty,
    resistor_a: std.ArrayList(u32) = .empty,
    resistor_b: std.ArrayList(u32) = .empty,
    resistor_ohms: std.ArrayList(f64) = .empty,
    /// `(lo, hi)` proto pair → farads, summed in call order.
    caps: std.AutoArrayHashMapUnmanaged([2]u32, f64) = .empty,

    pub fn init(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted) Allocator.Error!Builder {
        const nets = extracted.nets.netCount();
        const net_rects = try arena.alloc(std.ArrayList(u32), nets);
        @memset(net_rects, .empty);
        const hub = try arena.alloc(u32, nets);
        @memset(hub, none);
        var b: Builder = .{
            .arena = arena,
            .loaded = loaded,
            .extracted = extracted,
            .um = 1e-6 / @as(f64, @floatFromInt(loaded.grid.dbu_per_um)),
            .net_rects = net_rects,
            .hub = hub,
        };
        try b.parent.append(arena, ground);
        return b;
    }

    pub fn proto(b: *Builder) Allocator.Error!u32 {
        const id: u32 = @intCast(b.parent.items.len);
        try b.parent.append(b.arena, id);
        return id;
    }

    pub fn rectNode(r: u32) u32 {
        return r + 1;
    }

    pub fn find(b: *Builder, start: u32) u32 {
        return findIn(b.parent.items, start);
    }

    pub fn join(b: *Builder, x: u32, y: u32) void {
        joinIn(b.parent.items, x, y);
    }

    /// The node a net stands for when nothing more specific is known: its
    /// largest rectangle (the first on a tie), or its hub.
    pub fn anchor(b: *Builder, net: NetId) Allocator.Error!u32 {
        var best: ?u32 = null;
        for (b.net_rects[@backingInt(net)].items) |r| {
            if (best == null or b.rect.items[r].area() > b.rect.items[best.?].area()) best = r;
        }
        if (best) |r| return rectNode(r);
        return b.anchorHub(net);
    }

    /// A net's hub even when it has rectangles: substrate contacts meet there.
    pub fn anchorHub(b: *Builder, net: NetId) Allocator.Error!u32 {
        const i = @backingInt(net);
        if (b.hub[i] == none) b.hub[i] = try b.proto();
        return b.hub[i];
    }

    pub fn stack(b: *const Builder) *const ProcessStack {
        return &b.loaded.deck.deck.stack;
    }

    pub fn stackRow(b: *const Builder, layer: LayerId) ?usize {
        const row = @backingInt(layer);
        return if (row < b.stack().sheet_res_ohm_sq.len) row else null;
    }

    /// Whether the stack gives `layer` wire capacitance.
    pub fn isWire(b: *const Builder, layer: LayerId) bool {
        const row = b.stackRow(layer) orelse return false;
        return b.stack().area_cap_af_um2[row] > 0.0 or b.stack().fringe_cap_af_um[row] > 0.0;
    }

    /// A resistor; a zero or non-finite one joins its ends instead.
    pub fn resistor(b: *Builder, x: u32, y: u32, ohms: f64) Allocator.Error!void {
        if (ohms > 0.0 and std.math.isFinite(ohms)) {
            try b.resistor_a.append(b.arena, x);
            try b.resistor_b.append(b.arena, y);
            try b.resistor_ohms.append(b.arena, ohms);
        } else b.join(x, y);
    }

    pub fn cap(b: *Builder, x: u32, y: u32, farads: f64) Allocator.Error!void {
        if (!(farads > 0.0 and std.math.isFinite(farads)) or x == y) return;
        const slot = try b.caps.getOrPut(b.arena, .{ @min(x, y), @max(x, y) });
        if (!slot.found_existing) slot.value_ptr.* = 0.0;
        slot.value_ptr.* += farads;
    }

    /// The capacitor keys ascending (`BTreeMap` order); sorts in place.
    pub fn sortedCaps(b: *Builder) []const [2]u32 {
        const Ctx = struct {
            keys: []const [2]u32,
            pub fn lessThan(c: @This(), x: usize, y: usize) bool {
                const p = c.keys[x];
                const q = c.keys[y];
                return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
            }
        };
        b.caps.sort(Ctx{ .keys = b.caps.keys() });
        return b.caps.keys();
    }
};

const big_cells: i64 = 64;

/// Lengths along x and y two boxes share; negative is a gap.
pub fn shared(a: Bbox, b: Bbox) [2]i64 {
    return .{ @min(a.xhi, b.xhi) - @max(a.xlo, b.xlo), @min(a.yhi, b.yhi) - @max(a.ylo, b.ylo) };
}

pub fn gap2(a: Bbox, b: Bbox) i128 {
    const s = shared(a, b);
    const dx: i128 = @max(-s[0], 0);
    const dy: i128 = @max(-s[1], 0);
    return dx * dx + dy * dy;
}

/// The root of `start` in a disjoint set, halving the path.
pub fn findIn(parent: []u32, start: u32) u32 {
    var x = start;
    while (parent[x] != x) {
        const up = parent[x];
        parent[x] = parent[up];
        x = up;
    }
    return x;
}

/// Joins two sets under the smaller root.
pub fn joinIn(parent: []u32, x: u32, y: u32) void {
    const a = findIn(parent, x);
    const b = findIn(parent, y);
    parent[@max(a, b)] = @min(a, b);
}

// ---- private ----

test "a union keeps its smallest member as the root whatever the order" {
    // Oracle: construct-from-answer. Joining {3, 1} then {2, 3} roots all
    // three at 1, and 0 stays alone, in either join order.
    for ([_][2][2]u32{ .{ .{ 3, 1 }, .{ 2, 3 } }, .{ .{ 2, 3 }, .{ 1, 2 } } }) |joins| {
        var parent = [_]u32{ 0, 1, 2, 3 };
        for (joins) |j| joinIn(&parent, j[0], j[1]);
        for ([_]u32{ 1, 2, 3 }) |x| try std.testing.expectEqual(1, findIn(&parent, x));
        try std.testing.expectEqual(0, findIn(&parent, 0));
    }
}
