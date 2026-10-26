//! Quasi-static inductance: selected nets in, per-net series L and R and
//! the mutual inductance between nets out. Ported from
//! crates/extract/src/field/henry.rs.
//!
//! Each net's shapes are merged per layer and cut into disjoint rectangles,
//! as the closed forms read them (`conductor.zig`). A region of one
//! rectangle is a filament along its long axis (short side × layer
//! thickness), its current uniform; a region of several, where the wire
//! turns or changes width and the current crowds, is a grid of cells joined
//! face to face (`henry_grid.zig`), so a right-angle bend's corner square
//! reads close to the 0.559 squares of Hall's conformal map (*Thin Solid
//! Films* 1(4), 1967). Layers join through vias: each cut sharing a point
//! with the net's rectangles on both its plates lands on the rectangle it
//! overlaps most on each (the lowest on a tie) and is a filament between its
//! landings carrying the layer's resistance per cut. One port per net runs
//! across its two most distant rectangle ends. Out: `InductMatrix`, the port
//! impedance matrix at 1 MHz (`henry_solve.zig`): each net's
//! `L = Im(Z_ii)/ω` and `R = Re(Z_ii)`, and `M_ij = Im(Z_ij)/ω`, the
//! open-circuit mutual inductance (Ruehli 1972; Kamon, Tsuk & White 1994).
//! Each port's current enters at the lower of its two end points in node
//! order (`x`, then `y`, then layer) and leaves at the other, so two parallel
//! wires drawn side by side read a positive `M`.
//!
//! Contents:
//! - `pub const frequency_hz: f64`
//! - `pub const InductMatrix = struct`, `InductMatrix.empty`, `deinit`
//! - `pub const Error = error{ NoSheetResistance, NoThickness, EmptyNet, Singular, InvalidGeometry, Disconnected } || Allocator.Error`
//! - `pub const Refusal = struct { layer: u16, net: u32 }`
//! - `pub const Problem = struct { store, nets, global, vias, stack, grid }`
//! - `pub fn extractInductanceInto(gpa: Allocator, threads: u16, problem: Problem, selected: []const u32, out: *InductMatrix, refusal: *Refusal) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const stack_mod = @import("../stack.zig");
const Stack = stack_mod.Stack;
const Vias = stack_mod.Vias;
const NetPolys = @import("../net_polys.zig").NetPolys;
const Regions = @import("../conductor.zig").Regions;
const Vec3 = @import("filament.zig").Vec3;
const henry_grid = @import("henry_grid.zig");
const NodeKey = henry_grid.NodeKey;
const Line = henry_grid.Line;
const CellGrid = henry_grid.CellGrid;
const henry_solve = @import("henry_solve.zig");
const FilamentSet = henry_solve.FilamentSet;
const Complex = henry_solve.Complex;

/// The one frequency the impedance is extracted at: 1 MHz, where skin effect
/// is negligible on chip and ωL is still well above round-off next to R.
pub const frequency_hz: f64 = 1e6;

/// Per-net self inductance (H) and series resistance (Ω), one row per
/// selected net in ascending order, and the inductance matrix between them.
pub const InductMatrix = struct {
    net: std.ArrayList(u32) = .empty,
    /// Series inductance between the net's port terminals.
    l_henry: std.ArrayList(f64) = .empty,
    /// Row-major `n × n`: `Im(Z_ij)/ω`, the voltage across net `i`'s port per
    /// unit current through net `j`'s, every other port open. The diagonal is
    /// `l_henry`. Reciprocal to round-off; signed by the ports' orientation.
    m_henry: std.ArrayList(f64) = .empty,
    /// Series resistance between the port terminals: at 1 MHz and one
    /// filament across each rectangle's width, the DC resistance.
    r_ohm: std.ArrayList(f64) = .empty,

    pub const empty: InductMatrix = .{};

    pub fn deinit(m: *InductMatrix, gpa: Allocator) void {
        m.net.deinit(gpa);
        m.l_henry.deinit(gpa);
        m.m_henry.deinit(gpa);
        m.r_ohm.deinit(gpa);
    }
};

/// Why an inductance solve was refused; each names what is missing rather
/// than solving without it. `Refusal` carries the layer or net.
pub const Error = error{
    /// A selected polygon's layer (or a joining via layer) has no stack row,
    /// or a sheet resistance that is not positive and finite.
    NoSheetResistance,
    /// A selected polygon's layer has a thickness that is not positive.
    NoThickness,
    /// A selected net has no polygons off the global layers.
    EmptyNet,
    /// `Zb` or the reduced nodal admittance has an exactly zero pivot column.
    Singular,
    /// A net's shapes on a layer are not valid rectilinear rings.
    InvalidGeometry,
    /// A net's pieces do not all join through shared edges and vias (two
    /// pieces meeting only at a corner, say), so its port impedance is
    /// undefined.
    Disconnected,
} || Allocator.Error;

/// The layer or net a refusal names.
pub const Refusal = struct { layer: u16 = 0, net: u32 = 0 };

/// What the solve reads: the store and its nets, the deck's global layers
/// and vias, its stack and the grid.
pub const Problem = struct {
    store: *const GeometryStore,
    nets: *const NetPolys,
    global: []const LayerId,
    vias: Vias,
    stack: Stack,
    grid: Grid,
};

/// Where a via cut lands: a node key on a line, or a point (doubled
/// database units) on a gridded rectangle.
const Landing = union(enum) {
    key: NodeKey,
    cell: struct { rect: u32, x2: i64, y2: i64 },
};

const Via = struct { from: Landing, to: Landing, cut: Bbox, ohm: f64 };

/// A stop on a line: the rectangle and the coordinate along its axis.
const Stop = struct {
    rect: u32,
    along: i64,

    fn lessThan(_: void, a: Stop, c: Stop) bool {
        if (a.rect != c.rect) return a.rect < c.rect;
        return a.along < c.along;
    }
};

/// A rectangle end: its node key and the rectangle.
const End = struct {
    key: NodeKey,
    rect: u32,

    fn lessThan(_: void, a: End, c: End) bool {
        const o = NodeKey.order(a.key, c.key);
        if (o != .eq) return o == .lt;
        return a.rect < c.rect;
    }
};

/// The network every net appends to: nodes, branches, ports and each net's
/// node range for the one-circuit check.
const Builder = struct {
    gpa: Allocator,
    p: Problem,
    refusal: *Refusal,
    /// One database unit, in metres.
    scale: f64,
    nodes: std.ArrayList(Vec3) = .empty,
    set: FilamentSet = .empty,
    port_a: std.ArrayList(u32) = .empty,
    port_b: std.ArrayList(u32) = .empty,
    span_net: std.ArrayList(u32) = .empty,
    span_from: std.ArrayList(u32) = .empty,
    span_to: std.ArrayList(u32) = .empty,

    fn deinit(b: *Builder) void {
        b.nodes.deinit(b.gpa);
        b.set.deinit(b.gpa);
        b.port_a.deinit(b.gpa);
        b.port_b.deinit(b.gpa);
        b.span_net.deinit(b.gpa);
        b.span_from.deinit(b.gpa);
        b.span_to.deinit(b.gpa);
    }

    /// Conductivity and thickness (m) of a described layer; σ = 1/(Rsq · t)
    /// reproduces the sheet resistance through the thickness.
    fn conductor(b: *Builder, layer: u16) Error![2]f64 {
        const s = b.p.stack;
        const rows = @min(s.sheet_res_ohm_sq.len, s.thickness_nm.len, s.height_nm.len);
        const sheet = if (layer < s.sheet_res_ohm_sq.len) s.sheet_res_ohm_sq[layer] else 0.0;
        const thickness_m = (if (layer < s.thickness_nm.len) s.thickness_nm[layer] else 0.0) * 1e-9;
        if (layer >= rows or !(sheet > 0.0) or !std.math.isFinite(sheet)) {
            b.refusal.layer = layer;
            return error.NoSheetResistance;
        }
        if (!(thickness_m > 0.0)) {
            b.refusal.layer = layer;
            return error.NoThickness;
        }
        return .{ 1.0 / (sheet * thickness_m), thickness_m };
    }

    /// A node's place, metres: half a database unit per doubled unit, at the
    /// middle of its layer's thickness.
    fn position(b: *const Builder, key: NodeKey) Vec3 {
        const s = b.p.stack;
        const h = if (key.layer < s.height_nm.len) s.height_nm[key.layer] else 0.0;
        const t = if (key.layer < s.thickness_nm.len) s.thickness_nm[key.layer] else 0.0;
        const z = (h + t / 2.0) * 1e-9;
        return .{ @as(f64, @floatFromInt(key.x)) * b.scale / 2.0, @as(f64, @floatFromInt(key.y)) * b.scale / 2.0, z };
    }

    fn metres(b: *const Builder, v: Dbu) f64 {
        return @as(f64, @floatFromInt(v)) * b.scale;
    }

    fn addNet(b: *Builder, net: u32, keep: []const bool) Error!void {
        const gpa = b.gpa;
        var regions: Regions = .empty;
        defer regions.deinit(gpa);
        if (try regions.pushNet(gpa, b.p.store, b.p.nets.polysOf(net), net, keep)) |bad| {
            b.refusal.layer = @backingInt(bad);
            return error.InvalidGeometry;
        }
        if (regions.len() == 0) {
            b.refusal.net = net;
            return error.EmptyNet;
        }
        for (regions.layer.items) |layer| _ = try b.conductor(@backingInt(layer));

        // A region of several rectangles is gridded; one rectangle carries
        // its current uniformly, as one filament. A line's index is its
        // rectangle's index in `regions.rects`.
        const rect_count = regions.rects.items.len;
        const region_of = try gpa.alloc(u32, rect_count);
        defer gpa.free(region_of);
        const lines = try gpa.alloc(Line, rect_count);
        defer gpa.free(lines);
        const line_layer = try gpa.alloc(u16, rect_count);
        defer gpa.free(line_layer);
        const gridded = try gpa.alloc(bool, regions.len());
        defer gpa.free(gridded);
        var stops: std.ArrayList(Stop) = .empty;
        defer stops.deinit(gpa);
        var any_grid = false;
        for (0..regions.len()) |region| {
            const from = regions.rect_start.items[region];
            const to = regions.rect_start.items[region + 1];
            gridded[region] = to - from > 1;
            any_grid = any_grid or gridded[region];
            for (from..to) |rect| {
                region_of[rect] = @intCast(region);
                lines[rect] = .of(regions.rects.items[rect]);
                line_layer[rect] = @backingInt(regions.layer.items[region]);
                if (!gridded[region]) try stops.appendSlice(gpa, &.{ .{ .rect = @intCast(rect), .along = lines[rect].lo }, .{ .rect = @intCast(rect), .along = lines[rect].hi } });
            }
        }

        var vias: std.ArrayList(Via) = .empty;
        defer vias.deinit(gpa);
        try b.landVias(&regions, lines, line_layer, region_of, gridded, &stops, &vias);
        std.mem.sort(Stop, stops.items, {}, Stop.lessThan);
        stops.shrinkRetainingCapacity(dedup(Stop, stops.items, stopEql));

        // Node order is the sorted key order: a function of the geometry alone.
        var keys: std.ArrayList(NodeKey) = .empty;
        defer keys.deinit(gpa);
        for (stops.items) |s| try keys.append(gpa, lines[s.rect].key(s.along, line_layer[s.rect]));
        std.mem.sort(NodeKey, keys.items, {}, NodeKey.lessThan);
        keys.shrinkRetainingCapacity(dedup(NodeKey, keys.items, NodeKey.eql));
        const base: u32 = @intCast(b.nodes.items.len);
        for (keys.items) |k| try b.nodes.append(gpa, b.position(k));
        const node_of = NodeOf{ .base = base, .keys = keys.items };

        var run: usize = 0;
        while (run < stops.items.len) {
            var end = run + 1;
            while (end < stops.items.len and stops.items[end].rect == stops.items[run].rect) end += 1;
            defer run = end;
            const rect = stops.items[run].rect;
            const line = lines[rect];
            const c = try b.conductor(line_layer[rect]);
            for (stops.items[run .. end - 1], stops.items[run + 1 .. end]) |s0, s1| {
                const n1 = node_of.of(line.key(s0.along, line_layer[rect]));
                const n2 = node_of.of(line.key(s1.along, line_layer[rect]));
                try b.set.push(gpa, b.nodes.items[n1], b.nodes.items[n2], b.metres(line.width), c[1], c[0], n1, n2);
            }
        }

        // Every gridded region's cells and the filaments between them.
        const grids = try gpa.alloc(?CellGrid, regions.len());
        defer gpa.free(grids);
        @memset(grids, null);
        defer for (grids) |*grid| if (grid.*) |*live| live.deinit(gpa);
        for (0..regions.len()) |region| {
            if (!gridded[region]) continue;
            const layer = @backingInt(regions.layer.items[region]);
            const c = try b.conductor(layer);
            const z = b.position(.{ .x = 0, .y = 0, .layer = layer })[2];
            grids[region] = try CellGrid.build(gpa, regions.rectsOf(@intCast(region)), @intCast(b.nodes.items.len));
            const grid = &grids[region].?;
            for (grid.centres.items) |centre| try b.nodes.append(gpa, .{ centre[0] * b.scale, centre[1] * b.scale, z });
            try grid.filamentsInto(gpa, b.scale, c[1], c[0], b.nodes.items, &b.set);
        }
        for (vias.items) |via| {
            const n1 = resolve(via.from, node_of, grids, region_of);
            const n2 = resolve(via.to, node_of, grids, region_of);
            try b.set.pushOhm(gpa, b.nodes.items[n1], b.nodes.items[n2], b.metres(via.cut.xhi - via.cut.xlo), b.metres(via.cut.yhi - via.cut.ylo), via.ohm, n1, n2);
        }

        var pa: u32 = undefined;
        var pb: u32 = undefined;
        if (any_grid) {
            // The two most distant ends of any rectangle, lower key first; a
            // gridded rectangle's end is a terminal across its whole edge.
            var ends: std.ArrayList(End) = .empty;
            defer ends.deinit(gpa);
            for (lines, line_layer, 0..) |line, layer, rect| try ends.appendSlice(gpa, &.{ .{ .key = line.key(line.lo, layer), .rect = @intCast(rect) }, .{ .key = line.key(line.hi, layer), .rect = @intCast(rect) } });
            std.mem.sort(End, ends.items, {}, End.lessThan);
            ends.shrinkRetainingCapacity(dedup(End, ends.items, endEql));
            const at = try gpa.alloc(Vec3, ends.items.len);
            defer gpa.free(at);
            for (at, ends.items) |*a, e| a.* = b.position(e.key);
            const pair = mostDistantPair(at);
            const first = try b.terminal(ends.items[pair[0]], node_of, grids, region_of, line_layer, &regions);
            const second = if (pair[1] == pair[0]) first else try b.terminal(ends.items[pair[1]], node_of, grids, region_of, line_layer, &regions);
            pa = first;
            pb = second;
        } else {
            const pair = mostDistantPair(b.nodes.items[base..]);
            pa = base + @as(u32, @intCast(pair[0]));
            pb = base + @as(u32, @intCast(pair[1]));
        }
        try b.port_a.append(gpa, pa);
        try b.port_b.append(gpa, pb);
        try b.span_net.append(gpa, net);
        try b.span_from.append(gpa, base);
        try b.span_to.append(gpa, @intCast(b.nodes.items.len));
    }

    /// Every via cut joining two of the net's plates, landed on each: on a
    /// gridded region the cell under the middle of what the cut and the
    /// rectangle share; on a line its centre's projection, pushed as a stop.
    // ponytail: scans every cut on the layer per net; a spatial query if selections meet chip-scale via layers.
    fn landVias(b: *Builder, regions: *const Regions, lines: []const Line, line_layer: []const u16, region_of: []const u32, gridded: []const bool, stops: *std.ArrayList(Stop), vias: *std.ArrayList(Via)) Error!void {
        const rects = regions.rects.items;
        for (b.p.vias.cut, b.p.vias.connects) |cut_layer, plates| {
            const lower = @backingInt(plates[0]);
            const upper = @backingInt(plates[1]);
            var below: Bbox = .empty;
            var above: Bbox = .empty;
            for (rects, line_layer) |r, l| {
                if (l == lower) below = below.merge(r);
                if (l == upper) above = above.merge(r);
            }
            const window = below.intersection(above) orelse continue;
            const rows = b.p.store.polysOnLayer(cut_layer);
            for (rows.start..rows.end) |row| {
                const cut = b.p.store.polyBbox(@fromBackingInt(@intCast(row)));
                if (!cut.overlaps(window)) continue;
                const a = land(rects, line_layer, lower, cut) orelse continue;
                const c = land(rects, line_layer, upper, cut) orelse continue;
                const cl = @backingInt(cut_layer);
                const sheet = b.p.stack.sheet_res_ohm_sq;
                const ohm = if (cl < sheet.len) sheet[cl] else 0.0;
                if (!(ohm > 0.0 and std.math.isFinite(ohm))) {
                    b.refusal.layer = cl;
                    return error.NoSheetResistance;
                }
                const x = cut.xlo + cut.xhi;
                const y = cut.ylo + cut.yhi;
                var landing: [2]Landing = undefined;
                for ([2]u32{ a, c }, &landing) |rect, *out| {
                    if (gridded[region_of[rect]]) {
                        const r = rects[rect];
                        const shared = cut.intersection(r) orelse r;
                        // Half a unit inside the rectangle, so a cut that only
                        // touches its edge still lands on its own cell.
                        out.* = .{ .cell = .{
                            .rect = rect,
                            .x2 = std.math.clamp(shared.xlo + shared.xhi, 2 * r.xlo + 1, 2 * r.xhi - 1),
                            .y2 = std.math.clamp(shared.ylo + shared.yhi, 2 * r.ylo + 1, 2 * r.yhi - 1),
                        } };
                    } else {
                        const along = lines[rect].project(x, y);
                        try stops.append(b.gpa, .{ .rect = rect, .along = along });
                        out.* = .{ .key = lines[rect].key(along, line_layer[rect]) };
                    }
                }
                try vias.append(b.gpa, .{ .from = landing[0], .to = landing[1], .cut = cut, .ohm = ohm });
            }
        }
    }

    /// A port end's node: on a line, its key's node; on a gridded rectangle,
    /// a new terminal node joined to every cell along that edge.
    fn terminal(b: *Builder, end: End, node_of: NodeOf, grids: []const ?CellGrid, region_of: []const u32, line_layer: []const u16, regions: *const Regions) Error!u32 {
        const grid = &(grids[region_of[end.rect]] orelse return node_of.of(end.key));
        const c = try b.conductor(line_layer[end.rect]);
        const node: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.gpa, b.position(end.key));
        try grid.terminalInto(b.gpa, regions.rects.items[end.rect], end.key, node, b.scale, c[1], c[0], b.nodes.items, &b.set);
        return node;
    }
};

/// A net's line nodes: `base` plus a key's place in the sorted keys.
const NodeOf = struct {
    base: u32,
    keys: []const NodeKey,

    fn of(n: NodeOf, key: NodeKey) u32 {
        const i = std.sort.binarySearch(NodeKey, n.keys, key, orderKey) orelse unreachable;
        return n.base + @as(u32, @intCast(i));
    }

    fn orderKey(a: NodeKey, k: NodeKey) std.math.Order {
        return NodeKey.order(a, k);
    }
};

/// Solves per-net L and R, and the mutual inductance between every pair, for
/// `selected` in one magnetoquasistatic solve into `out` (cleared), one row
/// per net in ascending order. Shapes on a global layer carry no modelled
/// current: they are left out and need no stack row, so a net whose pieces
/// join only through one is not one circuit. Nets are checked in ascending
/// order, each net's layers ascending. `Zb`'s rows are assembled on
/// `threads` host threads.
pub fn extractInductanceInto(gpa: Allocator, threads: u16, problem: Problem, selected: []const u32, out: *InductMatrix, refusal: *Refusal) Error!void {
    out.net.clearRetainingCapacity();
    out.l_henry.clearRetainingCapacity();
    out.m_henry.clearRetainingCapacity();
    out.r_ohm.clearRetainingCapacity();
    const order = try gpa.dupe(u32, selected);
    defer gpa.free(order);
    std.mem.sortUnstable(u32, order, {}, std.sort.asc(u32));

    var b: Builder = .{ .gpa = gpa, .p = problem, .refusal = refusal, .scale = 1e-6 / @as(f64, @floatFromInt(problem.grid.dbu_per_um)) };
    defer b.deinit();
    const keep = try gpa.alloc(bool, problem.store.layerCount());
    defer gpa.free(keep);
    for (keep, 0..) |*k, l| k.* = !stack_mod.isGlobal(problem.global, @fromBackingInt(@intCast(l)));
    for (order) |net| {
        try b.addNet(net, keep);
        try out.net.append(gpa, net);
    }

    const nodes: u32 = @intCast(b.nodes.items.len);
    const component = try gpa.alloc(u32, nodes);
    defer gpa.free(component);
    try henry_solve.componentsInto(gpa, b.set.n1.items, b.set.n2.items, nodes, component);
    for (b.span_net.items, b.span_from.items, b.span_to.items) |net, from, to| {
        for (component[from..to]) |c| {
            if (c != component[from]) {
                refusal.net = net;
                return error.Disconnected;
            }
        }
    }
    const n = b.port_a.items.len;
    const z = try gpa.alloc(Complex, n * n);
    defer gpa.free(z);
    try henry_solve.portImpedanceInto(gpa, threads, &b.set, nodes, b.port_a.items, b.port_b.items, frequency_hz, z);
    const w = 2.0 * std.math.pi * frequency_hz;
    for (0..n) |p| {
        try out.l_henry.append(gpa, z[p * n + p].im / w);
        try out.r_ohm.append(gpa, z[p * n + p].re);
    }
    for (z) |zqp| try out.m_henry.append(gpa, zqp.im / w);
}

// ---- private ----

/// The rectangle on `layer` that `cut` overlaps most (the lowest index on a
/// tie), or null when it overlaps none.
fn land(rects: []const Bbox, line_layer: []const u16, layer: u16, cut: Bbox) ?u32 {
    var best: ?u32 = null;
    var best_area: geom.DbuArea = -1;
    for (rects, line_layer, 0..) |r, l, i| {
        if (l != layer or !cut.overlaps(r)) continue;
        const shared = if (cut.intersection(r)) |s| s.area() else 0;
        if (shared > best_area) {
            best_area = shared;
            best = @intCast(i);
        }
    }
    return best;
}

fn resolve(landing: Landing, node_of: NodeOf, grids: []const ?CellGrid, region_of: []const u32) u32 {
    return switch (landing) {
        .key => |k| node_of.of(k),
        // A cut lands inside the rectangle it overlaps.
        .cell => |c| grids[region_of[c.rect]].?.cellAt(c.x2, c.y2).?,
    };
}

/// The two most distant points; ties keep the first pair in scan order.
// ponytail: O(n²) over one net's nodes; rotating calipers if nets grow large.
fn mostDistantPair(nodes: []const Vec3) [2]usize {
    if (nodes.len == 1) return .{ 0, 0 };
    var best: f64 = -1.0;
    var pair: [2]usize = .{ 0, 1 };
    for (0..nodes.len) |i| {
        for (i + 1..nodes.len) |j| {
            const d = nodes[i] - nodes[j];
            const d2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
            if (d2 > best) {
                best = d2;
                pair = .{ i, j };
            }
        }
    }
    return pair;
}

fn stopEql(a: Stop, c: Stop) bool {
    return a.rect == c.rect and a.along == c.along;
}

fn endEql(a: End, c: End) bool {
    return a.rect == c.rect and NodeKey.eql(a.key, c.key);
}

/// Drops consecutive duplicates in place; returns the kept count.
fn dedup(comptime T: type, items: []T, comptime eql: fn (T, T) bool) usize {
    if (items.len == 0) return 0;
    var kept: usize = 1;
    for (items[1..]) |v| {
        if (eql(v, items[kept - 1])) continue;
        items[kept] = v;
        kept += 1;
    }
    return kept;
}
