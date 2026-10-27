//! The circuit's device cards: every recognised device → its terminals on
//! the rectangles that touch its channel (the bulk on its net's anchor) and
//! its parameters as topology measured them, plus BSIM4 `sa`/`sb` for a MOS
//! whose channel direction can be told. In: the `Builder` and the device
//! table. Out: the `Circuit`'s device columns, nodes still proto nodes.
//! Ported from src/liberty/circuit.rs (`Builder::{devices, touching_node}`,
//! `Active::lod`, `card_rank`).
//!
//! A MOS's `as`, `ps`, `ad`, `pd` are topology's diffusion measures, the
//! ones LVS compares (testing-plan F100): a shared diffusion split between
//! the fingers sharing it, holes out of the area and in the perimeter. A
//! bipolar's emitter measures are no ngspice instance parameter.
//!
//! Contents:
//! - `pub fn devices(b: *Builder, out: *Circuit) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const topology = @import("check").topology;
const NetId = topology.net.NetId;
const TerminalRole = topology.device.TerminalRole;
const circuit = @import("circuit.zig");
const Circuit = circuit.Circuit;
const Param = circuit.Param;
const graph = @import("circuit_graph.zig");
const Builder = graph.Builder;
const RectIndex = graph.RectIndex;

/// One terminal in card order.
const Card = struct {
    rank: u8,
    net: NetId,
    role: TerminalRole,

    fn lessThan(_: void, p: Card, q: Card) bool {
        return p.rank < q.rank;
    }
};

/// The active region a channel sits in: its source/drain diffusions and the
/// other channels, which tile it between the isolation edges.
const Active = struct {
    store: *const geom.GeometryStore,
    sd_index: RectIndex,
    sd_polys: std.ArrayList(PolyId) = .empty,
    channels: RectIndex,
    markers: std.ArrayList(Bbox) = .empty,

    /// BSIM4 length of diffusion: from each side of the gate to the
    /// isolation edge along the channel's centre line, walking across any
    /// diffusion and other finger in the way. Null when the channel's
    /// direction cannot be told.
    ///
    /// ponytail: one centre line, by bounding boxes; an irregular active
    /// region wants the width-weighted `1/(SA + L/2)` average BSIM4 defines.
    fn lod(x: *const Active, a: Allocator, gate: Bbox, touching: []const u32) Allocator.Error!?[2]i64 {
        // Current flows across the edge a source/drain diffusion abuts.
        var along_x = false;
        var along_y = false;
        for (touching) |p| {
            const s = graph.shared(x.store.polyBbox(x.sd_polys.items[p]), gate);
            along_x = along_x or (s[0] == 0 and s[1] > 0);
            along_y = along_y or (s[1] == 0 and s[0] > 0);
        }
        if (along_x == along_y) return null;
        const g = axis(gate, along_x);
        const centre: i64 = @intCast(@divTrunc(@as(i128, g[2]) + g[3], 2));
        const left = try x.walk(a, g[0], -1, centre, along_x);
        const right = try x.walk(a, g[1], 1, centre, along_x);
        return .{ g[0] - left, right - g[1] };
    }

    /// From `start` outward along the centre line, each step landing on a
    /// box that starts where the last ended; where the walk stops.
    fn walk(x: *const Active, a: Allocator, start: i64, outward: i64, centre: i64, along_x: bool) Allocator.Error!i64 {
        var at = start;
        var found: std.ArrayList(u32) = .empty;
        var boxes: std.ArrayList(Bbox) = .empty;
        for (0..1024) |_| {
            const probe: Bbox = if (along_x) .point(at, centre) else .point(centre, at);
            boxes.clearRetainingCapacity();
            try x.sd_index.query(a, probe, &found);
            for (found.items) |p| try boxes.append(a, x.store.polyBbox(x.sd_polys.items[p]));
            try x.channels.query(a, probe, &found);
            for (found.items) |m| try boxes.append(a, x.markers.items[m]);
            var next: ?i64 = null;
            for (boxes.items) |box| {
                const c = axis(box, along_x);
                if (c[2] > centre or c[3] < centre) continue;
                if (outward > 0 and c[0] == at and c[1] > at) next = if (next) |n| @max(n, c[1]) else c[1];
                if (outward < 0 and c[1] == at and c[0] < at) next = if (next) |n| @min(n, c[0]) else c[0];
            }
            at = next orelse return at;
        }
        return at;
    }
};

/// Appends one card per recognised device, in device-table order.
pub fn devices(b: *Builder, out: *Circuit) Allocator.Error!void {
    const a = b.arena;
    const store = &b.loaded.store;
    const table = &b.extracted.devices;
    const cell = 4 * b.loaded.grid.dbu_per_um;
    // Source/drain layers of every MOS recogniser, and their polygons.
    const recognisers = &b.loaded.deck.deck.devices;
    var sd_layers: std.ArrayList(LayerId) = .empty;
    for (recognisers.kind, 0..) |kind, row| if (kind == .mos) {
        const terminals = recognisers.terminal[recognisers.terminal_start[row]..recognisers.terminal_start[row + 1]];
        try sd_layers.appendSlice(a, terminals[@min(1, terminals.len)..@min(3, terminals.len)]);
    };
    std.mem.sortUnstable(LayerId, sd_layers.items, {}, layerLess);
    var active: Active = .{ .store = store, .sd_index = .init(cell), .channels = .init(cell) };
    for (sd_layers.items, 0..) |layer, i| {
        if (i > 0 and sd_layers.items[i - 1] == layer) continue;
        if (@backingInt(layer) >= store.layerCount()) continue;
        const rows = store.polysOnLayer(layer);
        for (rows.start..rows.end) |row| {
            try active.sd_index.insert(a, @intCast(active.sd_polys.items.len), store.polyBbox(@fromBackingInt(@intCast(row))));
            try active.sd_polys.append(a, @fromBackingInt(@intCast(row)));
        }
    }
    for (table.kind.items, table.marker.items) |kind, marker| if (kind == .mos) {
        try active.channels.insert(a, @intCast(active.markers.items.len), store.polyBbox(marker));
        try active.markers.append(a, store.polyBbox(marker));
    };

    try out.terminal_start.append(a, 0);
    try out.param_start.append(a, 0);
    var touches: std.ArrayList(u32) = .empty;
    var found: std.ArrayList(u32) = .empty;
    var card: std.ArrayList(Card) = .empty;
    for (0..table.len()) |d| {
        const kind = table.kind.items[d];
        const marker = store.polyBbox(table.marker.items[d]);
        const terms = table.terminalsOf(@fromBackingInt(@intCast(d)));
        card.clearRetainingCapacity();
        for (terms.nets, terms.roles) |net, role| try card.append(a, .{ .rank = topology.card.cardRank(role), .net = net, .role = role });
        std.sort.insertion(Card, card.items, {}, Card.lessThan);
        try out.device_kind.append(a, kind);
        try out.device_model.append(a, b.loaded.strings.resolve(table.model.items[d]));
        for (card.items) |c| {
            const node = switch (c.role) {
                .bulk => try b.anchor(c.net),
                .gate, .source, .drain, .base, .emitter, .collector, .pin => try touchingNode(b, c.net, marker, &found),
            };
            try out.terminal_node.append(a, node);
            try out.terminal_net.append(a, c.net);
            try out.terminal_role.append(a, c.role);
        }
        try out.terminal_start.append(a, @intCast(out.terminal_node.items.len));
        const params = table.paramsOf(@fromBackingInt(@intCast(d)));
        for (params.names, params.measures) |param, measure| {
            const key: []const u8 = switch (param) {
                .area, .perimeter => if (kind == .mos) continue else if (param == .area) "area" else if (kind == .diode) "pj" else "perim",
                .emitter_area, .emitter_perimeter => continue,
                .source_area => "as",
                .drain_area => "ad",
                .source_perimeter => "ps",
                .drain_perimeter => "pd",
                .width => "w",
                .length => "l",
                .fins => "nfin",
                .fingers => "nf",
            };
            const um = b.um;
            const value: Param = switch (measure) {
                .length => |v| .{ .length = @as(f64, @floatFromInt(v)) * um },
                .area => |v| .{ .area = @as(f64, @floatFromInt(v)) * um * um },
                .count => |n| .{ .count = n },
                .length_share => |s| .{ .length = @as(f64, @floatFromInt(s.length)) * um / @as(f64, @floatFromInt(s.ways)) },
                .area_share => |s| .{ .area = @as(f64, @floatFromInt(s.area)) * um * um / @as(f64, @floatFromInt(s.ways)) },
            };
            try out.param_name.append(a, key);
            try out.param_value.append(a, value);
        }
        if (kind == .mos) {
            // The diffusion polygons the channel abuts.
            touches.clearRetainingCapacity();
            try active.sd_index.query(a, marker, &found);
            for (found.items) |p| if (store.polyBbox(active.sd_polys.items[p]).contact(marker) > 0) try touches.append(a, p);
            if (try active.lod(a, marker, touches.items)) |lod| {
                try out.param_name.append(a, "sa");
                try out.param_value.append(a, .{ .length = @as(f64, @floatFromInt(lod[0])) * b.um });
                try out.param_name.append(a, "sb");
                try out.param_value.append(a, .{ .length = @as(f64, @floatFromInt(lod[1])) * b.um });
            }
        }
        try out.param_start.append(a, @intCast(out.param_name.items.len));
    }
}

// ---- private ----

/// Coordinates along the channel (`lo`, `hi`) and across it.
fn axis(b: Bbox, along_x: bool) [4]i64 {
    return if (along_x) .{ b.xlo, b.xhi, b.ylo, b.yhi } else .{ b.ylo, b.yhi, b.xlo, b.xhi };
}

/// The rectangle of `net` touching `marker` most (the first on a tie); the
/// net's anchor if none touches.
fn touchingNode(b: *Builder, net: NetId, marker: Bbox, found: *std.ArrayList(u32)) Allocator.Error!u32 {
    var best: ?u32 = null;
    var best_c: i64 = 0;
    for (b.index.items) |*entry| {
        try entry.index.query(b.arena, marker, found);
        for (found.items) |r| {
            if (b.rect_net.items[r] != net) continue;
            const c = b.rect.items[r].contact(marker);
            if (c > 0 and (best == null or c > best_c or (c == best_c and r < best.?))) {
                best = r;
                best_c = c;
            }
        }
    }
    return if (best) |r| Builder.rectNode(r) else b.anchor(net);
}

fn layerLess(_: void, p: LayerId, q: LayerId) bool {
    return @backingInt(p) < @backingInt(q);
}
