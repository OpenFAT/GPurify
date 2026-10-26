//! The rectangle graph's wires: conductor polygons → rectangles (one node
//! each), sheet resistors across shared edges, joins across overlaps, one
//! resistor per via cut, ground capacitance per rectangle, and the check
//! that every net is one piece. In: the `Builder`'s loaded layout. Out: its
//! rectangle, resistor and capacitor tables. Ported from
//! src/liberty/circuit.rs (`Builder::{rectangles, resistors, overlaps,
//! connected, join_rects, vias, ground_caps}`).
//!
//! Contents:
//! - `pub fn rectangles(b: *Builder, diag: *Diagnostic) Error!void`
//! - `pub fn resistors(b: *Builder) Allocator.Error!void`
//! - `pub fn overlaps(b: *Builder) Allocator.Error!void`
//! - `pub fn vias(b: *Builder) Allocator.Error!void`
//! - `pub fn groundCaps(b: *Builder) Allocator.Error!void`
//! - `pub fn connected(b: *Builder, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const Diagnostic = @import("spec.zig").Diagnostic;
const Error = @import("circuit.zig").Error;
const graph = @import("circuit_graph.zig");
const Builder = graph.Builder;
const RectIndex = graph.RectIndex;
const shared = graph.shared;

/// One rectangle side on a sweep line: `starts` 0 where a rectangle ends, 1
/// where one starts, so endings sort first.
const Side = struct {
    at: i64,
    starts: u8,
    lo: i64,
    hi: i64,
    id: u32,

    fn lessThan(_: void, p: Side, q: Side) bool {
        if (p.at != q.at) return p.at < q.at;
        if (p.starts != q.starts) return p.starts < q.starts;
        if (p.lo != q.lo) return p.lo < q.lo;
        if (p.hi != q.hi) return p.hi < q.hi;
        return p.id < q.id;
    }
};

/// Cuts every conductor polygon on a net into rectangles; one proto node
/// each. `Geometry` for a layer that is not valid rectilinear geometry.
pub fn rectangles(b: *Builder, diag: *Diagnostic) Error!void {
    const a = b.arena;
    const loaded = b.loaded;
    const store = &loaded.store;
    var layer: geom.ValidatedLayer = .empty;
    var cut: std.ArrayList(Bbox) = .empty;
    var start: std.ArrayList(u32) = .empty;
    const cell = 4 * loaded.grid.dbu_per_um;
    for (loaded.deck.deck.connectivity.conductors) |conductor| {
        if (@backingInt(conductor) >= store.layerCount() or store.polysOnLayer(conductor).len() == 0) continue;
        if (try geom.view.validateLayer(a, store, conductor, .rectilinear, &layer)) |defect| {
            const name = loaded.strings.resolve(loaded.deck.deck.layers.name(conductor));
            diag.message = try a.print("layer {s} is not valid rectilinear geometry: {s}", .{ name, @tagName(defect) });
            return error.Geometry;
        }
        try geom.rects.decomposeInto(a, &layer, &cut, &start);
        var index: RectIndex = .init(cell);
        for (0..layer.len()) |poly| {
            const net = b.extracted.nets.netOf(layer.get(@intCast(poly)).provenance());
            if (net == .none) continue;
            for (cut.items[start.items[poly]..start.items[poly + 1]]) |r| {
                const id: u32 = @intCast(b.rect.items.len);
                std.debug.assert(try b.proto() == Builder.rectNode(id));
                try b.rect.append(a, r);
                try b.rect_layer.append(a, conductor);
                try b.rect_net.append(a, net);
                try b.rect_shared.append(a, 0);
                try b.net_rects[@backingInt(net)].append(a, id);
                try index.insert(a, id, r);
            }
        }
        try b.index.append(a, .{ .layer = conductor, .index = index });
    }
    std.mem.sortUnstable(graph.LayerIndex, b.index.items, {}, layerLess);
}

/// Sheet resistance across every edge two same-net, same-layer rectangles
/// share, centre to centre.
pub fn resistors(b: *Builder) Allocator.Error!void {
    const a = b.arena;
    var sides: std.ArrayList(Side) = .empty;
    for (b.index.items) |entry| {
        const rho = if (b.stackRow(entry.layer)) |row| b.stack().sheet_res_ohm_sq[row] else 0.0;
        for ([_]bool{ true, false }) |vertical| {
            sides.clearRetainingCapacity();
            for (b.rect.items, b.rect_layer.items, 0..) |r, layer, id| {
                if (layer != entry.layer) continue;
                const s: [4]i64 = if (vertical) .{ r.xlo, r.xhi, r.ylo, r.yhi } else .{ r.ylo, r.yhi, r.xlo, r.xhi };
                try sides.append(a, .{ .at = s[1], .starts = 0, .lo = s[2], .hi = s[3], .id = @intCast(id) });
                try sides.append(a, .{ .at = s[0], .starts = 1, .lo = s[2], .hi = s[3], .id = @intCast(id) });
            }
            std.mem.sortUnstable(Side, sides.items, {}, Side.lessThan);
            var run: usize = 0;
            while (run < sides.items.len) {
                var end = run;
                while (end < sides.items.len and sides.items[end].at == sides.items[run].at) end += 1;
                var split = run;
                while (split < end and sides.items[split].starts == 0) split += 1;
                const ending = sides.items[run..split];
                const starting = sides.items[split..end];
                var i: usize = 0;
                var j: usize = 0;
                while (i < ending.len and j < starting.len) {
                    const p = ending[i];
                    const q = starting[j];
                    const overlap = @min(p.hi, q.hi) - @max(p.lo, q.lo);
                    if (overlap > 0) try joinRects(b, p.id, q.id, overlap, rho, vertical);
                    if (p.hi < q.hi) i += 1 else j += 1;
                }
                run = end;
            }
        }
    }
}

/// Two same-net rectangles that overlap are one piece of metal: joined, the
/// resistance across the overlap dropped (optimistic, never an open).
pub fn overlaps(b: *Builder) Allocator.Error!void {
    var found: std.ArrayList(u32) = .empty;
    for (0..b.rect.items.len) |r| {
        const index = indexOf(b, b.rect_layer.items[r]) orelse continue;
        try index.query(b.arena, b.rect.items[r], &found);
        for (found.items) |other| {
            if (other <= r or b.rect_net.items[other] != b.rect_net.items[r]) continue;
            const s = shared(b.rect.items[r], b.rect.items[other]);
            if (s[0] > 0 and s[1] > 0) b.join(Builder.rectNode(@intCast(r)), Builder.rectNode(other));
        }
    }
}

/// One resistor per via cut, between the rectangles it lands on most; a
/// cut on substrate (no rectangles) lands on its net's hub.
pub fn vias(b: *Builder) Allocator.Error!void {
    const store = &b.loaded.store;
    const connectivity = &b.loaded.deck.deck.connectivity;
    var found: std.ArrayList(u32) = .empty;
    for (connectivity.via_cut, connectivity.via_connects) |cut, plates| {
        if (@backingInt(cut) >= store.layerCount()) continue;
        const per_cut = if (b.stackRow(cut)) |row| b.stack().sheet_res_ohm_sq[row] else 0.0;
        const rows = store.polysOnLayer(cut);
        for (rows.start..rows.end) |poly| {
            const box = store.polyBbox(@fromBackingInt(@intCast(poly)));
            var ends: [2]?u32 = .{ null, null };
            for (&ends, plates) |*slot, layer| {
                const index = indexOf(b, layer) orelse continue;
                try index.query(b.arena, box, &found);
                var best: i128 = 0;
                for (found.items) |r| {
                    const s = shared(b.rect.items[r], box);
                    if (s[0] <= 0 or s[1] <= 0) continue;
                    const area = @as(i128, s[0]) * s[1];
                    if (slot.* == null or area > best) {
                        slot.* = r;
                        best = area;
                    }
                }
            }
            if (ends[0] != null and ends[1] != null) {
                if (b.rect_net.items[ends[0].?] == b.rect_net.items[ends[1].?])
                    try b.resistor(Builder.rectNode(ends[0].?), Builder.rectNode(ends[1].?), per_cut);
            } else if (ends[0] orelse ends[1]) |r| {
                const hub = try b.anchorHub(b.rect_net.items[r]);
                try b.resistor(Builder.rectNode(r), hub, per_cut);
            }
        }
    }
}

/// Per rectangle, ground capacitance: the area not over a MOS channel (the
/// model counts that as gate oxide) and the perimeter no same-net
/// rectangle covers.
pub fn groundCaps(b: *Builder) Allocator.Error!void {
    const a = b.arena;
    const store = &b.loaded.store;
    const devices = &b.extracted.devices;
    var channels: RectIndex = .init(4 * b.loaded.grid.dbu_per_um);
    for (devices.kind.items, devices.marker.items, 0..) |kind, marker, d|
        if (kind == .mos) try channels.insert(a, @intCast(d), store.polyBbox(marker));
    var found: std.ArrayList(u32) = .empty;
    const um = b.um * 1e6;
    for (b.rect.items, b.rect_layer.items, b.rect_shared.items, 0..) |r, layer, shared_dbu, i| {
        const row = b.stackRow(layer) orelse continue;
        const area_af = b.stack().area_cap_af_um2[row];
        const fringe_af = b.stack().fringe_cap_af_um[row];
        if (area_af <= 0.0 and fringe_af <= 0.0) continue;
        try channels.query(a, r, &found);
        var covered: i128 = 0;
        for (found.items) |d| {
            const s = shared(r, store.polyBbox(devices.marker.items[d]));
            covered += @as(i128, @max(s[0], 0)) * @max(s[1], 0);
        }
        const area = @as(f64, @floatFromInt(@max(r.area() - covered, 0))) * um * um;
        const perimeter = @as(f64, @floatFromInt(@max(2 * (r.width() + r.height()) - shared_dbu, 0))) * um;
        try b.cap(Builder.rectNode(@intCast(i)), graph.ground, (area_af * area + fringe_af * perimeter) * 1e-18);
    }
}

/// Every net with rectangles is one piece through its resistors and joins,
/// or a terminal on it would float in simulation: `Disconnected` otherwise.
pub fn connected(b: *Builder, diag: *Diagnostic) Error!void {
    const a = b.arena;
    const pieces = try a.dupe(u32, b.parent.items);
    for (b.resistor_a.items, b.resistor_b.items) |x, y| graph.joinIn(pieces, x, y);
    var roots: std.ArrayList(u32) = .empty;
    for (b.net_rects, 0..) |list, net| {
        roots.clearRetainingCapacity();
        for (list.items) |r| try roots.append(a, graph.findIn(pieces, Builder.rectNode(r)));
        std.mem.sortUnstable(u32, roots.items, {}, std.sort.asc(u32));
        var count: usize = 0;
        for (roots.items, 0..) |root, i| count += @intFromBool(i == 0 or roots.items[i - 1] != root);
        if (count <= 1) continue;
        const name = if (b.extracted.ports.nameOf(@fromBackingInt(@intCast(net)))) |n| b.loaded.strings.resolve(n) else try a.print("#{d}", .{net});
        diag.message = try a.print("net {s} falls apart into {d} unconnected pieces in the resistor network, so a simulation of it would leave a terminal floating", .{ name, count });
        return error.Disconnected;
    }
}

// ---- private ----

fn layerLess(_: void, p: graph.LayerIndex, q: graph.LayerIndex) bool {
    return @backingInt(p.layer) < @backingInt(q.layer);
}

fn indexOf(b: *const Builder, layer: LayerId) ?*const RectIndex {
    for (b.index.items) |*entry| if (entry.layer == layer) return &entry.index;
    return null;
}

fn joinRects(b: *Builder, p: u32, q: u32, overlap: i64, rho: f64, vertical: bool) Allocator.Error!void {
    if (b.rect_net.items[p] != b.rect_net.items[q]) return;
    b.rect_shared.items[p] += overlap;
    b.rect_shared.items[q] += overlap;
    const ohms = rho * (halfSquares(b.rect.items[p], vertical) + halfSquares(b.rect.items[q], vertical));
    try b.resistor(Builder.rectNode(p), Builder.rectNode(q), ohms);
}

/// Half a rectangle's squares along the current.
fn halfSquares(r: Bbox, vertical: bool) f64 {
    const along: f64 = @floatFromInt(if (vertical) r.width() else r.height());
    const across: f64 = @floatFromInt(if (vertical) r.height() else r.width());
    return along / (2.0 * across);
}
