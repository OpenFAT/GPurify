//! Per-net resistor networks, built from layout without design intent. In:
//! the store, nets, devices (or a list of points on one net), the process.
//! Out: `NetNetworks`, one CSR row per net with at least two device attach
//! points (or one row with a terminal at each point), its node indices
//! local to the row; the same chain model as the supply grid, each net's
//! links sorted by `(net, a, b, layer, cut)` and a device attaching once per
//! net. Ported from crates/check/src/erc/power.rs (`extract_nets_into`,
//! `extract_points_into`, `net_slice`).
//!
//! Contents:
//! - `pub fn extractNetsInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, devices: *const DeviceTable, process: Process, out: *NetNetworks, diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub fn extractPointsInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, process: Process, net: NetId, points: []const Point, out: *NetNetworks, nodes: *std.ArrayList(u32), diag: *PowerDiag) (PowerError || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Point = geom.Point;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const centre = geom.ops.centre;
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const DeviceTable = @import("../topology/device.zig").DeviceTable;
const grid_ = @import("power_grid.zig");
const Process = grid_.Process;
const PowerGrid = grid_.PowerGrid;
const NetNetworks = grid_.NetNetworks;
const PowerError = grid_.PowerError;
const PowerDiag = grid_.PowerDiag;
const not_a_node = grid_.not_a_node;
const chain = @import("power_chain.zig");
const taps_ = @import("power_taps.zig");
const TapIndex = taps_.TapIndex;
const TapTable = taps_.TapTable;
const Link = taps_.Link;
const links_ = @import("power_links.zig");

/// The scratch both builders fill.
const Shared = struct {
    gpa: Allocator,
    conductor: std.ArrayList(bool) = .empty,
    sheet: std.ArrayList(f64) = .empty,
    candidate: std.ArrayList(PolyId) = .empty,
    shape_in_row: std.ArrayList(u32) = .empty,
    links: links_.Connections = .{},
    taps: TapTable = .{},
    edges: std.ArrayList(PowerGrid.Edge) = .empty,
    profile: chain.ChainProfile = .{},

    fn deinit(s: *Shared) void {
        s.conductor.deinit(s.gpa);
        s.sheet.deinit(s.gpa);
        s.candidate.deinit(s.gpa);
        s.shape_in_row.deinit(s.gpa);
        s.links.deinit(s.gpa);
        s.taps.deinit(s.gpa);
        s.edges.deinit(s.gpa);
        s.profile.deinit(s.gpa);
    }

    fn prepare(s: *Shared, store: *const GeometryStore, process: Process, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
        try links_.conductorMaskInto(s.gpa, process.connectivity, store.layerCount(), &s.conductor);
        try links_.sheetResistancesInto(s.gpa, process, store.layerCount(), &s.sheet, diag);
    }

    /// A centre tap on every shape, then both ends of every link; the first
    /// metal and via requests.
    fn tapShapes(s: *Shared, store: *const GeometryStore, shapes: []const PolyId, metal: []const Link, via: []const Link) Allocator.Error![2]u32 {
        for (shapes, 0..) |p, i| {
            const host = store.polyBbox(p);
            _ = try s.taps.push(s.gpa, @intCast(i), chain.tapOn(host, host));
        }
        const m = try s.taps.pushLinks(s.gpa, store, metal, s.shape_in_row.items);
        const v = try s.taps.pushLinks(s.gpa, store, via, s.shape_in_row.items);
        return .{ m, v };
    }

    /// Appends one row's terminals, nodes and edges and closes its offsets.
    fn pushRow(s: *Shared, store: *const GeometryStore, process: Process, shapes: []const PolyId, terminal: []const u32, metal: []const Link, via: []const Link, reqs: [2]u32, out: *NetNetworks) Allocator.Error!void {
        const gpa = s.gpa;
        try out.terminal.appendSlice(gpa, terminal);
        for (s.taps.node_shape.items, s.taps.node_along.items) |owner, along| {
            const poly = shapes[owner];
            try out.node_poly.append(gpa, poly);
            try out.node_at.append(gpa, chain.tapPoint(store.polyBbox(poly), along));
        }
        s.edges.clearRetainingCapacity();
        try links_.edgesInto(gpa, store, process, s.sheet.items, shapes, &s.taps, .{ .links = metal, .first = reqs[0] }, .{ .links = via, .first = reqs[1] }, &s.profile, &s.edges);
        for (s.edges.items) |e| {
            try out.edge_from.append(gpa, e.from);
            try out.edge_to.append(gpa, e.to);
            try out.edge_resistance.append(gpa, .{ .raw = e.ohms });
        }
        try out.node_start.append(gpa, @intCast(out.node_poly.items.len));
        try out.terminal_start.append(gpa, @intCast(out.terminal.items.len));
        try out.edge_start.append(gpa, @intCast(out.edge_from.items.len));
    }
};

/// One network per net with at least two device attach points; `out` is
/// cleared and refilled, rows ascending by net. Each device on the net taps
/// the nearest shape its marker touches (else the nearest); one with a
/// terminal on the net is an attach point, once. `NoSheetResistance` as
/// `power_extract.extractInto`, `out` left empty.
pub fn extractNetsInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, devices: *const DeviceTable, process: Process, out: *NetNetworks, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    out.clear();
    var s: Shared = .{ .gpa = gpa };
    defer s.deinit();
    try s.prepare(store, process, diag);
    // Every net's conducting shapes, grouped by net, and each shape's index
    // within its own net (the row-local space the network is stated in).
    var candidate_start: std.ArrayList(u32) = .empty;
    defer candidate_start.deinit(gpa);
    try candidate_start.append(gpa, 0);
    try s.shape_in_row.appendNTimes(gpa, not_a_node, store.polyCount());
    for (0..nets.netCount()) |n| {
        const first = s.candidate.items.len;
        try links_.conductingInto(gpa, store, nets, s.conductor.items, @fromBackingInt(@as(u32, @intCast(n))), &s.candidate);
        for (s.candidate.items[first..], 0..) |p, i| s.shape_in_row.items[@backingInt(p)] = @intCast(i);
        try candidate_start.append(gpa, @intCast(s.candidate.items.len));
    }
    // Links sorted by net (both ends share it) so each net's run is a slice.
    try links_.connectionsInto(gpa, store, process.connectivity, &s.links);
    s.links.retainNoded(s.shape_in_row.items);
    inline for (.{ &s.links.metal, &s.links.via }) |list| std.mem.sortUnstable(Link, list.items, nets, lessByNet);

    var terminal: std.ArrayList(u32) = .empty;
    defer terminal.deinit(gpa);
    var attach: std.ArrayList(u32) = .empty;
    defer attach.deinit(gpa);
    var index: TapIndex = .{};
    defer index.deinit(gpa);
    for (0..nets.netCount()) |n| {
        const id: NetId = @fromBackingInt(@as(u32, @intCast(n)));
        const from = candidate_start.items[n];
        const to = candidate_start.items[n + 1];
        const shapes = s.candidate.items[from..to];
        s.taps.clear();
        terminal.clearRetainingCapacity();
        attach.clearRetainingCapacity();
        const metal = netSlice(s.links.metal.items, id, nets);
        const via = netSlice(s.links.via.items, id, nets);
        const reqs = try s.tapShapes(store, shapes, metal, via);
        if (shapes.len > 0) {
            try index.buildInto(gpa, store, shapes);
            for (devices.devicesOn(id)) |d| {
                const marker_box = store.polyBbox(devices.marker.items[@backingInt(d)]);
                const marker = centre(marker_box);
                const local = index.host(marker_box);
                const host = store.polyBbox(shapes[local]);
                const req = try s.taps.push(gpa, local, chain.tapOn(host, Bbox.point(marker.x, marker.y)));
                if (std.mem.indexOfScalar(NetId, devices.terminalsOf(d).nets, id) != null) try attach.append(gpa, req);
            }
        }
        try s.taps.finish(gpa, @intCast(shapes.len));
        for (attach.items) |r| try terminal.append(gpa, s.taps.req_node.items[r]);
        sortDedup(&terminal);
        // Under two attach points: no pair to measure, so no row.
        if (terminal.items.len < 2) continue;
        try out.net.append(gpa, id);
        try s.pushRow(store, process, shapes, terminal.items, metal, via, reqs, out);
    }
    // Offsets are `rows + 1` long once there is a row, and empty otherwise.
    if (out.net.items.len > 0) inline for (.{ &out.node_start, &out.terminal_start, &out.edge_start }) |c| try c.insert(gpa, 0, 0);
}

/// One net's network as `extractNetsInto` builds it, with a terminal at
/// each of `points` instead of at its devices (what a point-to-point
/// resistance report measures between, catalog PEX-016): each point taps
/// the conducting shape of the net that holds it, boundary included. Fills
/// `nodes` with each point's node, in order. `NotOnNet` (`diag` the point's
/// index) for a point on no conducting shape of the net.
pub fn extractPointsInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, process: Process, net: NetId, points: []const Point, out: *NetNetworks, nodes: *std.ArrayList(u32), diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    out.clear();
    nodes.clearRetainingCapacity();
    var s: Shared = .{ .gpa = gpa };
    defer s.deinit();
    try s.prepare(store, process, diag);
    try links_.conductingInto(gpa, store, nets, s.conductor.items, net, &s.candidate);
    try s.shape_in_row.appendNTimes(gpa, not_a_node, store.polyCount());
    for (s.candidate.items, 0..) |p, i| s.shape_in_row.items[@backingInt(p)] = @intCast(i);
    try links_.connectionsInto(gpa, store, process.connectivity, &s.links);
    s.links.retainNoded(s.shape_in_row.items);
    const shapes = s.candidate.items;
    const reqs = try s.tapShapes(store, shapes, s.links.metal.items, s.links.via.items);
    var requests: std.ArrayList(u32) = .empty;
    defer requests.deinit(gpa);
    for (points, 0..) |at, k| {
        const local = for (shapes, 0..) |p, i| {
            if (store.polyContainsPoint(p, at)) break i;
        } else {
            diag.at = @intCast(k);
            return error.NotOnNet;
        };
        const host = store.polyBbox(shapes[local]);
        try requests.append(gpa, try s.taps.push(gpa, @intCast(local), chain.tapOn(host, Bbox.point(at.x, at.y))));
    }
    try s.taps.finish(gpa, @intCast(shapes.len));
    for (requests.items) |r| try nodes.append(gpa, s.taps.req_node.items[r]);
    var terminal: std.ArrayList(u32) = .empty;
    defer terminal.deinit(gpa);
    try terminal.appendSlice(gpa, nodes.items);
    sortDedup(&terminal);
    try out.net.append(gpa, net);
    try s.pushRow(store, process, shapes, terminal.items, s.links.metal.items, s.links.via.items, reqs, out);
    inline for (.{ &out.node_start, &out.terminal_start, &out.edge_start }) |c| try c.insert(gpa, 0, 0);
}

// ---- private ----

fn lessByNet(nets: *const NetTable, x: Link, y: Link) bool {
    const kx = [5]u32{ @backingInt(nets.netOf(@fromBackingInt(x.a))), x.a, x.b, @backingInt(x.layer), x.cut };
    const ky = [5]u32{ @backingInt(nets.netOf(@fromBackingInt(y.a))), y.a, y.b, @backingInt(y.layer), y.cut };
    return std.mem.order(u32, &kx, &ky) == .lt;
}

/// One net's run of a link list sorted by net.
fn netSlice(links: []const Link, net: NetId, nets: *const NetTable) []const Link {
    const want = @backingInt(net);
    return links[firstAbove(links, nets, want, false)..firstAbove(links, nets, want, true)];
}

/// The first link whose net is at or above `want` (`past`: above).
fn firstAbove(links: []const Link, nets: *const NetTable, want: u32, past: bool) usize {
    var lo: usize = 0;
    var hi: usize = links.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const n = @backingInt(nets.netOf(@fromBackingInt(links[mid].a)));
        if (n < want or (past and n == want)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn sortDedup(list: *std.ArrayList(u32)) void {
    std.mem.sortUnstable(u32, list.items, {}, std.sort.asc(u32));
    var kept: usize = 0;
    for (list.items) |v| if (kept == 0 or list.items[kept - 1] != v) {
        list.items[kept] = v;
        kept += 1;
    };
    list.shrinkRetainingCapacity(kept);
}
