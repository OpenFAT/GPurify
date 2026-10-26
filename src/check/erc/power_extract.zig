//! The supply grid and the forced-current stress networks, built from
//! layout. In: the store, nets, devices, the intent's supplies and budgets
//! (or one `Stress`), the process. Out: a `PowerGrid` (or a `StressGrid`)
//! whose every polygon is a chain of resistors along its long box axis,
//! tapped where something connects and once at its own centre (so an
//! unconnected shape is an island, not absent). Ported from
//! crates/check/src/erc/power.rs (`extract_into`, `extract_stress_into`,
//! `Stress`, `StressGrid`, `discarded_budget`, `tap_nearest`).
//!
//! Contents:
//! - `pub fn extractInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, devices: *const DeviceTable, intent: *const IntentMap, process: Process, out: *PowerGrid, diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub const Stress = struct`, `pub const StressGrid = struct`, `StressGrid.deinit`
//! - `pub fn extractStressInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, devices: *const DeviceTable, process: Process, stress: Stress, out: *StressGrid, diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub fn discardedBudget(gpa: Allocator, grid: *const PowerGrid, intent: *const IntentMap) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Point = geom.Point;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const centre = geom.ops.centre;
const report = @import("../report.zig");
const Microamps = report.Microamps;
const Ohms = report.Ohms;
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const device_ = @import("../topology/device.zig");
const DeviceTable = device_.DeviceTable;
const DeviceId = device_.DeviceId;
const IntentMap = @import("facts.zig").IntentMap;
const grid_ = @import("power_grid.zig");
const Process = grid_.Process;
const PowerGrid = grid_.PowerGrid;
const PowerError = grid_.PowerError;
const PowerDiag = grid_.PowerDiag;
const not_a_node = grid_.not_a_node;
const chain = @import("power_chain.zig");
const taps_ = @import("power_taps.zig");
const TapIndex = taps_.TapIndex;
const TapTable = taps_.TapTable;
const links_ = @import("power_links.zig");

/// One forced-current stress: the nets a discharge path spans, where the
/// current enters and leaves, and the devices that carry it net to net.
pub const Stress = struct {
    /// The nets the network spans, ascending, distinct.
    nets: []const NetId,
    /// The polygon the current enters at; it taps its net's conducting
    /// shape nearest its box centre, at that centre.
    source: PolyId,
    /// The net `source` taps when it is on no path net itself (a device
    /// marker); null taps the source's own net.
    source_net: ?NetId = null,
    current: Microamps,
    /// The net the current leaves by, one of `nets`.
    sink: NetId,
    /// The sink's pins, each tapped as `source` is and held at 0 mV. Empty
    /// holds the sink's feed point instead.
    pins: []const PolyId,
    /// The devices that conduct between nets: each joins every pair of the
    /// distinct path nets its terminals touch, at its attach point on each.
    devices: []const DeviceId,
    /// The resistance one device puts between two of its nets; positive.
    device_resistance: Ohms,
};

/// A stress network solved by `power_solve.solveInto`: every node's voltage
/// is its rise above the held pins. Its last `device.len` edges are
/// `.device` edges, in `device` order.
pub const StressGrid = struct {
    grid: PowerGrid = .{},
    /// The node the current enters at.
    entry: u32 = 0,
    device: std.ArrayList(DeviceId) = .empty,

    pub fn deinit(s: *StressGrid, gpa: Allocator) void {
        s.grid.deinit(gpa);
        s.device.deinit(gpa);
    }
};

/// What both extractions share: the sheet resistances, the conductor mask,
/// the shapes, their links and taps.
const Builder = struct {
    gpa: Allocator,
    store: *const GeometryStore,
    conductor: std.ArrayList(bool) = .empty,
    sheet: std.ArrayList(f64) = .empty,
    shape: std.ArrayList(PolyId) = .empty,
    shape_of_poly: std.ArrayList(u32) = .empty,
    links: links_.Connections = .{},
    taps: TapTable = .{},
    index: TapIndex = .{},
    metal_req: u32 = 0,
    via_req: u32 = 0,

    fn deinit(b: *Builder) void {
        b.conductor.deinit(b.gpa);
        b.sheet.deinit(b.gpa);
        b.shape.deinit(b.gpa);
        b.shape_of_poly.deinit(b.gpa);
        b.links.deinit(b.gpa);
        b.taps.deinit(b.gpa);
        b.index.deinit(b.gpa);
    }

    /// Fallible before anything is written: a missing sheet resistance refuses.
    fn prepare(b: *Builder, process: Process, layers: u32, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
        try links_.conductorMaskInto(b.gpa, process.connectivity, layers, &b.conductor);
        try links_.sheetResistancesInto(b.gpa, process, layers, &b.sheet, diag);
    }

    /// The links between two noded shapes, and a centre tap on every shape
    /// then both ends of every link.
    fn linkShapes(b: *Builder, process: Process) Allocator.Error!void {
        try b.shape_of_poly.appendNTimes(b.gpa, not_a_node, b.store.polyCount());
        for (b.shape.items, 0..) |p, i| b.shape_of_poly.items[@backingInt(p)] = @intCast(i);
        try links_.connectionsInto(b.gpa, b.store, process.connectivity, &b.links);
        b.links.retainNoded(b.shape_of_poly.items);
        for (b.shape.items, 0..) |p, i| {
            const host = b.store.polyBbox(p);
            _ = try b.taps.push(b.gpa, @intCast(i), chain.tapOn(host, host));
        }
        b.metal_req = try b.taps.pushLinks(b.gpa, b.store, b.links.metal.items, b.shape_of_poly.items);
        b.via_req = try b.taps.pushLinks(b.gpa, b.store, b.links.via.items, b.shape_of_poly.items);
    }

    /// A tap request on the shape of `span` nearest `at`, at `at`; null
    /// when the span is empty.
    /// ponytail: rebuilds the nearest-shape index per query; a stress has a
    /// few pins and clamps.
    fn tapNearest(b: *Builder, span: [2]u32, at: Point) Allocator.Error!?u32 {
        if (span[1] == span[0]) return null;
        try b.index.buildInto(b.gpa, b.store, b.shape.items[span[0]..span[1]]);
        const local = b.index.nearest(at);
        const host = b.store.polyBbox(b.shape.items[span[0] + local]);
        return try b.taps.push(b.gpa, span[0] + local, chain.tapOn(host, Bbox.point(at.x, at.y)));
    }

    /// The node at shape `s`'s own centre (after `finish`).
    fn centreNode(b: *const Builder, s: u32) u32 {
        const host = b.store.polyBbox(b.shape.items[s]);
        const want = chain.tapOn(host, host);
        const run = b.taps.chainOf(s);
        const at = std.sort.binarySearch(geom.Dbu, b.taps.node_along.items[run[0]..run[1]], want, struct {
            fn order(x: geom.Dbu, y: geom.Dbu) std.math.Order {
                return std.math.order(x, y);
            }
        }.order) orelse unreachable; // every shape carries a tap at its own centre
        return run[0] + @as(u32, @intCast(at));
    }

    /// Appends the network's resistors to `g`.
    fn edges(b: *Builder, process: Process, g: *PowerGrid) Allocator.Error!void {
        var list: std.ArrayList(PowerGrid.Edge) = .empty;
        defer list.deinit(b.gpa);
        var profile: chain.ChainProfile = .{};
        defer profile.deinit(b.gpa);
        try links_.edgesInto(b.gpa, b.store, process, b.sheet.items, b.shape.items, &b.taps, .{ .links = b.links.metal.items, .first = b.metal_req }, .{ .links = b.links.via.items, .first = b.via_req }, &profile, &list);
        for (list.items) |e| try g.pushEdge(b.gpa, e);
    }
};

/// The span of shapes each path net owns.
const RunOf = struct {
    nets: []const NetId,
    start: []const u32,

    fn find(r: RunOf, net: NetId) ?usize {
        return std.sort.binarySearch(NetId, r.nets, net, orderNet);
    }

    /// Asserts `net` is a path net.
    fn of(r: RunOf, net: NetId) [2]u32 {
        const row = r.find(net).?;
        return .{ r.start[row], r.start[row + 1] };
    }
};

/// Builds the supply grid; `out` is cleared and refilled. Only declared
/// supplies get nodes. Each rail's budget spreads uniformly over its
/// device terminals (one number per net is all the intent carries), and the
/// rail is anchored at one pad, its feed shape's centre, which
/// over-reports drop. `NoSheetResistance` (`diag` the layer) whether or not
/// any supply is declared, with `out` left empty.
pub fn extractInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, devices: *const DeviceTable, intent: *const IntentMap, process: Process, out: *PowerGrid, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    out.clear();
    var b: Builder = .{ .gpa = gpa, .store = store };
    defer b.deinit();
    try b.prepare(process, store.layerCount(), diag);
    // Every supply's conducting shapes, grouped by supply.
    var supply_of_shape: std.ArrayList(u32) = .empty;
    defer supply_of_shape.deinit(gpa);
    var supply_start: std.ArrayList(u32) = .empty;
    defer supply_start.deinit(gpa);
    try supply_start.append(gpa, 0);
    for (intent.supply_net.items, 0..) |net, s| {
        try links_.conductingInto(gpa, store, nets, b.conductor.items, net, &b.shape);
        try supply_of_shape.appendNTimes(gpa, @intCast(s), b.shape.items.len - supply_of_shape.items.len);
        try supply_start.append(gpa, @intCast(b.shape.items.len));
    }
    try b.linkShapes(process);

    // One tap per device on the rail, on the nearest shape its marker
    // touches (else the nearest), and one load share per terminal it lands
    // on the rail (source and drain both draw).
    var attach: std.ArrayList(u32) = .empty;
    defer attach.deinit(gpa);
    const Load = struct { req: u32, share: f64 };
    var load: std.ArrayList(Load) = .empty;
    defer load.deinit(gpa);
    for (intent.supply_net.items, 0..) |net, s| {
        const from = supply_start.items[s];
        const to = supply_start.items[s + 1];
        attach.clearRetainingCapacity();
        if (to == from) continue;
        try b.index.buildInto(gpa, store, b.shape.items[from..to]);
        for (devices.devicesOn(net)) |d| {
            const marker_box = store.polyBbox(devices.marker.items[@backingInt(d)]);
            const marker = centre(marker_box);
            const host_index = from + b.index.host(marker_box);
            const host = store.polyBbox(b.shape.items[host_index]);
            const req = try b.taps.push(gpa, host_index, chain.tapOn(host, Bbox.point(marker.x, marker.y)));
            const here = std.mem.count(NetId, devices.terminalsOf(d).nets, &.{net});
            try attach.appendNTimes(gpa, req, here);
        }
        // A rail with no terminal stays unloaded; `discardedBudget` reports
        // it to the rules rather than refusing the stage. Ground injects.
        const sign: f64 = switch (intent.supply_role.items[s]) {
            .power => 1.0,
            .ground => -1.0,
        };
        const share = sign * (intent.limitsOf(net).budget_current_ua orelse 0.0) / @as(f64, @floatFromInt(attach.items.len));
        for (attach.items) |req| try load.append(gpa, .{ .req = req, .share = share });
    }

    // Nodes: one per distinct tap, ascending by shape then along its chain.
    try b.taps.finish(gpa, @intCast(b.shape.items.len));
    for (b.taps.node_shape.items, b.taps.node_along.items) |owner, along| {
        const s = supply_of_shape.items[owner];
        const poly = b.shape.items[owner];
        try out.pushNode(gpa, .{ .net = intent.supply_net.items[s], .at = chain.tapPoint(store.polyBbox(poly), along), .poly = poly, .layer = store.polyLayer(poly), .nominal = intent.heldAt(s), .load = .{ .raw = 0.0 } });
    }
    for (load.items) |l| {
        const node = b.taps.req_node.items[l.req];
        out.node_load.items[node] = out.node_load.items[node].add(.{ .raw = l.share });
    }
    // The anchor: no input marks pads, and supply enters from the top.
    for (0..intent.supply_net.items.len) |s| {
        const from = supply_start.items[s];
        const to = supply_start.items[s + 1];
        if (to == from) continue;
        const anchor = from + links_.feedShape(store, process, b.shape.items[from..to]);
        try out.source_node.append(gpa, b.centreNode(anchor));
        try out.source_voltage.append(gpa, intent.heldAt(s));
    }
    try b.edges(process, out);
}

/// Builds the network a forced current flows through; `out` is cleared and
/// refilled. The nets are chains as in `extractInto`; each listed device
/// adds `device_resistance` between its attach points on every two path
/// nets it touches. The entry node draws `-current`, the held nodes sit at
/// 0 mV, every nominal is 0 mV, so after a solve a node's voltage is the
/// stress voltage there. Asserts the source is on a path net (or names
/// one) and the source net and sink have conducting shapes.
pub fn extractStressInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, devices: *const DeviceTable, process: Process, stress: Stress, out: *StressGrid, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    out.grid.clear();
    out.device.clearRetainingCapacity();
    out.entry = 0;
    var b: Builder = .{ .gpa = gpa, .store = store };
    defer b.deinit();
    try b.prepare(process, store.layerCount(), diag);
    // Every path net's conducting shapes, grouped by net.
    var net_of_shape: std.ArrayList(NetId) = .empty;
    defer net_of_shape.deinit(gpa);
    var net_start: std.ArrayList(u32) = .empty;
    defer net_start.deinit(gpa);
    try net_start.append(gpa, 0);
    for (stress.nets) |net| {
        try links_.conductingInto(gpa, store, nets, b.conductor.items, net, &b.shape);
        try net_of_shape.appendNTimes(gpa, net, b.shape.items.len - net_of_shape.items.len);
        try net_start.append(gpa, @intCast(b.shape.items.len));
    }
    try b.linkShapes(process);
    const run = RunOf{ .nets = stress.nets, .start = net_start.items };

    const source = store.polyBbox(stress.source);
    const entry_net = stress.source_net orelse nets.netOf(stress.source);
    const entry_req = (try b.tapNearest(run.of(entry_net), centre(source))).?;
    var held_req: std.ArrayList(u32) = .empty;
    defer held_req.deinit(gpa);
    for (stress.pins) |pin| if (try b.tapNearest(run.of(stress.sink), centre(store.polyBbox(pin)))) |r| try held_req.append(gpa, r);
    if (stress.pins.len == 0) {
        const span = run.of(stress.sink);
        assert(span[1] > span[0]);
        const anchor = span[0] + links_.feedShape(store, process, b.shape.items[span[0]..span[1]]);
        const host = store.polyBbox(b.shape.items[anchor]);
        try held_req.append(gpa, try b.taps.push(gpa, anchor, chain.tapOn(host, host)));
    }
    // Per device: its attach request on each path net it touches, CSR.
    var attach_device: std.ArrayList(DeviceId) = .empty;
    defer attach_device.deinit(gpa);
    var attach_start: std.ArrayList(u32) = .empty;
    defer attach_start.deinit(gpa);
    var attach_req: std.ArrayList(u32) = .empty;
    defer attach_req.deinit(gpa);
    try attach_start.append(gpa, 0);
    var touched: std.ArrayList(NetId) = .empty;
    defer touched.deinit(gpa);
    for (stress.devices) |d| {
        touched.clearRetainingCapacity();
        for (devices.terminalsOf(d).nets) |n| if (run.find(n) != null) try touched.append(gpa, n);
        std.mem.sortUnstable(NetId, touched.items, {}, lessNet);
        touched.shrinkRetainingCapacity(dedupNets(touched.items));
        if (touched.items.len < 2) continue;
        const marker = centre(store.polyBbox(devices.marker.items[@backingInt(d)]));
        for (touched.items) |n| if (try b.tapNearest(run.of(n), marker)) |r| try attach_req.append(gpa, r);
        try attach_device.append(gpa, d);
        try attach_start.append(gpa, @intCast(attach_req.items.len));
    }

    try b.taps.finish(gpa, @intCast(b.shape.items.len));
    const g = &out.grid;
    for (b.taps.node_shape.items, b.taps.node_along.items) |owner, along| {
        const poly = b.shape.items[owner];
        try g.pushNode(gpa, .{ .net = net_of_shape.items[owner], .at = chain.tapPoint(store.polyBbox(poly), along), .poly = poly, .layer = store.polyLayer(poly), .nominal = .{ .raw = 0.0 }, .load = .{ .raw = 0.0 } });
    }
    out.entry = b.taps.req_node.items[entry_req];
    // An injection is a negative load.
    g.node_load.items[out.entry] = .{ .raw = -stress.current.raw };
    for (held_req.items) |r| try g.source_node.append(gpa, b.taps.req_node.items[r]);
    std.mem.sortUnstable(u32, g.source_node.items, {}, std.sort.asc(u32));
    g.source_node.shrinkRetainingCapacity(dedupU32(g.source_node.items));
    try g.source_voltage.appendNTimes(gpa, .{ .raw = 0.0 }, g.source_node.items.len);
    try b.edges(process, g);
    for (attach_device.items, 0..) |d, k| {
        const layer = store.polyLayer(devices.marker.items[@backingInt(d)]);
        const reqs = attach_req.items[attach_start.items[k]..attach_start.items[k + 1]];
        for (reqs, 0..) |ra, i| for (reqs[i + 1 ..]) |rb| {
            try g.pushEdge(gpa, .{ .from = b.taps.req_node.items[ra], .to = b.taps.req_node.items[rb], .ohms = stress.device_resistance.raw, .width = 1, .length = 1, .layer = layer, .kind = .device });
            try out.device.append(gpa, d);
        };
    }
}

/// Some net states a non-zero `budget_current_ua` and carries no load on
/// the grid (the budget never reached the solve: a rail with no device
/// terminal, or a limited net that is no supply). Exact: the loads sum to
/// the signed budget or to ±0.
pub fn discardedBudget(gpa: Allocator, grid: *const PowerGrid, intent: *const IntentMap) Allocator.Error!bool {
    // One pass over the nodes; each limited net's loads summed in node order.
    const load = try gpa.alloc(f64, intent.limit_net.items.len);
    defer gpa.free(load);
    @memset(load, 0.0);
    var last_net: NetId = .none;
    var last_row: ?usize = null;
    for (grid.node_net.items, grid.node_load.items) |net, node_load| {
        if (net != last_net) {
            last_net = net;
            last_row = std.sort.binarySearch(NetId, intent.limit_net.items, net, orderNet);
        }
        if (last_row) |row| load[row] += node_load.raw;
    }
    for (intent.limit.items, load) |limits, l| {
        const budget = limits.budget_current_ua orelse continue;
        if (budget != 0.0 and l == 0.0) return true;
    }
    return false;
}

// ---- private ----

fn orderNet(a: NetId, b: NetId) std.math.Order {
    return std.math.order(@backingInt(a), @backingInt(b));
}

fn lessNet(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn dedupNets(items: []NetId) usize {
    var kept: usize = 0;
    for (items) |n| if (kept == 0 or items[kept - 1] != n) {
        items[kept] = n;
        kept += 1;
    };
    return kept;
}

fn dedupU32(items: []u32) usize {
    var kept: usize = 0;
    for (items) |n| if (kept == 0 or items[kept - 1] != n) {
        items[kept] = n;
        kept += 1;
    };
    return kept;
}

/// Rust's in-file xorshift.
fn xorshift(state: *u64, m: u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.* % m;
}

test "discarded budget agrees with a per-net masked sum" {
    // Oracle: differential against a naive masked sum over every node per
    // net, over 500 random grids with zero and cancelling loads.
    const gpa = std.testing.allocator;
    var state: u64 = 0x9E37_79B9_7F4A_7C15;
    var grid: PowerGrid = .{};
    defer grid.deinit(gpa);
    var intent: IntentMap = .{};
    defer intent.deinit(gpa);
    for (0..500) |_| {
        grid.clear();
        intent.limit_net.clearRetainingCapacity();
        intent.limit.clearRetainingCapacity();
        for (0..xorshift(&state, 12)) |_| {
            try grid.node_net.append(gpa, @fromBackingInt(@as(u32, @intCast(xorshift(&state, 4)))));
            // Zeros and cancelling pairs are the interesting loads.
            const loads = [_]f64{ 0.0, -0.0, 1.5, -1.5, 2.0 };
            try grid.node_load.append(gpa, .{ .raw = loads[xorshift(&state, 5)] });
        }
        for (0..5) |n| if (xorshift(&state, 2) == 0) {
            try intent.limit_net.append(gpa, @fromBackingInt(@as(u32, @intCast(n))));
            const budgets = [_]?f64{ null, 0.0, 3.0 };
            try intent.limit.append(gpa, .{ .budget_current_ua = budgets[xorshift(&state, 3)] });
        };
        var naive = false;
        for (intent.limit_net.items, intent.limit.items) |net, limits| {
            var l: f64 = 0.0;
            for (grid.node_net.items, grid.node_load.items) |n, x| l += @as(f64, @floatFromInt(@intFromBool(n == net))) * x.raw;
            if (limits.budget_current_ua) |budget| naive = naive or (budget != 0.0 and l == 0.0);
        }
        try std.testing.expectEqual(naive, try discardedBudget(gpa, &grid, &intent));
    }
}
