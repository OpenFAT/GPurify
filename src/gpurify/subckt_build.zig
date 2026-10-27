//! The extracted circuit named for a simulator (catalog PEX-017): a loaded
//! and extracted design, its run's outputs and one of its parasitic
//! networks → the `Subckt` the SPICE and DSPF writers print
//! (export/subckt.zig). Every device terminal sits on the network node of
//! the region it touches (`extract.analytical.siteNodesInto`), a pin on
//! the region its label is on.
//!
//! With a reference the names are the schematic's, read through the LVS
//! pairing (`lvs.Traced.reference_mate` and the rows each reduced node
//! stands for): the `.subckt` is the reference's top cell, its pins that
//! cell's ports in order, each net the reference net it pairs with, each
//! device the reference card it pairs with (`XM1`; flattened, ngspice's
//! `m.x1.m1`, or `x1.xm1` for a subcircuit card; the extra fingers of a
//! parallel merge `XM1_2`, `XM1_3`). A layout net no pair names (one a
//! series merge consumed, or a floating piece) is `n<id>`. Without one, the
//! cell is the layout's file stem, the nets their labels, the pins the
//! labelled nets in ascending net order and each device its family's letter
//! and layout index (`M3`).
//!
//! Contents:
//! - `pub const Error = error{Refused} || Allocator.Error`
//! - `pub fn buildInto(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, outputs: *const Outputs, layout_path: []const u8, network: *const ParasiticNetwork, out: *Subckt, why: *[]const u8) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;
const check = @import("check");
const topology = check.topology;
const DeviceId = topology.DeviceId;
const lvs = check.lvs;
const extract = @import("extract");
const analytical = extract.analytical;
const NodeId = extract.network.NodeId;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const Outputs = @import("run.zig").Outputs;
const subckt = @import("export/subckt.zig");
const Subckt = subckt.Subckt;

/// `Refused`: no netlist can be written; `why` says why, naming what.
pub const Error = error{Refused} || Allocator.Error;

/// Where a site's region index lands in the network written.
const Place = struct {
    network: *const ParasiticNetwork,
    /// Ascending; such a net is one node and its far end.
    field_solved: []const u32,
    /// A `c` or `cc` extraction: every net is one node.
    lumped: bool,

    /// Net `n`'s node for its region `local` (`no_site`: its first);
    /// `.ground` when the net has none.
    fn nodeOf(p: Place, n: u32, local: u32) NodeId {
        const first = p.network.firstNode(n) orelse return .ground;
        const solved = std.sort.binarySearch(u32, p.field_solved, n, orderU32) != null;
        const at = @backingInt(first) + if (local == analytical.no_site or p.lumped or solved) 0 else local;
        assert(p.network.node_net.items[at] == n);
        return .at(at);
    }
};

/// Fills `out` (cleared) for `network`, which must be one of `outputs`'
/// networks. Refused: with a reference, a comparison that did not run or
/// did not match, a black box or a must-connect join (their pieces are not
/// the layout's nets one to one), a reference pin no layout net pairs
/// with; without one, a label naming two nets or a net carrying two labels.
/// Every name and row lives in `arena`.
pub fn buildInto(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, outputs: *const Outputs, layout_path: []const u8, network: *const ParasiticNetwork, out: *Subckt, why: *[]const u8) Error!void {
    try out.clear(arena);
    const devices = &extracted.devices;
    const net_count = extracted.nets.netCount();
    const unit_nm = loaded.deck.deck.devices.netlist_scale_nm orelse 1e9;
    out.unit_nm = unit_nm;
    out.dbu_per_unit = unit_nm * @as(f64, @floatFromInt(loaded.grid.dbu_per_um)) / 1000.0;
    try out.net_name.appendNTimes(arena, null, net_count);
    try out.pin_node.appendNTimes(arena, .ground, net_count);
    const device_name = try arena.alloc(?[]const u8, devices.len());
    @memset(device_name, null);

    // The names: the schematic's through the pairing, else the layout's.
    if (loaded.reference) |*reference| {
        try pairedNames(arena, loaded, extracted, outputs, reference, out, device_name, why);
    } else try labelNames(arena, loaded, extracted, layout_path, out, device_name, why);
    try fallbackNetNames(arena, out);

    // Every terminal's and pin's site, then the node each lands on.
    const terminals = devices.terminal_net.items.len;
    const pins = out.pin_net.items.len;
    const sites = try sitesOf(arena, loaded, extracted, out.pin_net.items);
    const local = try arena.alloc(u32, terminals + pins);
    var refusal: analytical.Refusal = .{};
    var nets: extract.NetPolys = .empty;
    try nets.buildInto(arena, extracted.nets.netColumn(), net_count);
    analytical.siteNodesInto(arena, &loaded.store, &nets, loaded.deck.deck.connectivity.global, sites, local, &refusal) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(arena, why, "layer {d} is not valid geometry, so no terminal can be placed on it", .{@backingInt(refusal.layer)}),
    };
    const place: Place = .{ .network = network, .field_solved = outputs.field_solved, .lumped = switch (loaded.deck.deck.extraction.kind) {
        .c, .cc => true,
        .r, .rc, .rcc => false,
    } };
    for (out.pin_net.items, local[terminals..]) |n, l| out.pin_node.items[n] = place.nodeOf(n, l);

    // Each device's card: terminals in card order, on their nodes; sizes.
    var order: std.ArrayList(u32) = .empty;
    for (0..devices.len()) |d| {
        const id: DeviceId = @fromBackingInt(@intCast(d));
        const kind = devices.kind.items[d];
        try out.device_name.append(arena, device_name[d].?);
        try out.device_model.append(arena, loaded.strings.resolve(devices.model.items[d]));
        try out.device_kind.append(arena, kind);
        const t = devices.terminalsOf(id);
        const first = devices.terminal_start.items[d];
        order.clearRetainingCapacity();
        for (0..t.nets.len) |i| try order.append(arena, @intCast(i));
        std.sort.insertion(u32, order.items, t.roles, rankLess);
        for (order.items) |i| {
            const n = @backingInt(t.nets[i]);
            try out.terminal_net.append(arena, n);
            try out.terminal_node.append(arena, place.nodeOf(n, local[first + i]));
        }
        try out.terminal_start.append(arena, @intCast(out.terminal_net.items.len));
        const params = devices.paramsOf(id);
        for (params.names, params.measures) |param, measure| {
            const name = topology.card.cardName(kind, param) orelse continue;
            try out.param_name.append(arena, name);
            try out.param_value.append(arena, switch (measure) {
                .length => |v| .{ .length = @floatFromInt(v) },
                .area => |v| .{ .area = @floatFromInt(v) },
                .count => |v| .{ .count = v },
                .length_share => |s| .{ .length = @as(f64, @floatFromInt(s.length)) / @as(f64, @floatFromInt(s.ways)) },
                .area_share => |s| .{ .area = @as(f64, @floatFromInt(s.area)) / @as(f64, @floatFromInt(s.ways)) },
            });
        }
        try out.param_start.append(arena, @intCast(out.param_name.items.len));
    }
    try refuseDuplicateDevices(arena, out.device_name.items, why);
}

// ---- private ----

/// The schematic's names through the comparison's pairing (module doc).
fn pairedNames(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, outputs: *const Outputs, reference: *const @import("ingest").netlist.Netlist, out: *Subckt, device_name: []?[]const u8, why: *[]const u8) Error!void {
    const strings = &loaded.strings;
    const traced = if (outputs.lvs) |*t| t else return refuse(arena, why, "the layout was not compared with its reference (LVS did not run), so no device or net can be named in its terms", .{});
    switch (traced.verdict) {
        .match => {},
        .mismatch => return refuse(arena, why, "the layout does not match its reference: LVS found {d} discrepancies, so no netlist is written", .{traced.found.items.len}),
        .inconclusive => |w| return refuse(arena, why, "the comparison with the reference did not conclude ({t}), so no netlist is written", .{w}),
    }
    if (loaded.provenance.box_cell.items.len != 0) return refuse(arena, why, "the layout places black boxes, whose pins are not one layout net each, so no netlist is written", .{});
    const controls = &loaded.deck.deck.lvs;
    if (controls.connect_implicit.len + controls.connect_explicit.len != 0) return refuse(arena, why, "the deck joins must-connect nets for LVS (`lvs connect_implicit`/`connect_explicit`), whose pieces a netlist cannot keep apart", .{});

    const top = (try reference.top(arena)).?; // LVS matched on the unique top
    out.name = strings.resolve(reference.subckt_name.items[@backingInt(top)]);
    var ref_graph: lvs.Graph = .{};
    try lvs.fromReferenceInto(arena, reference, top, &ref_graph);
    const ld: u32 = @intCast(traced.layout_row_start.items.len - 1);
    const rd: u32 = @intCast(traced.reference_row_start.items.len - 1);
    const mates = traced.reference_mate.items;
    assert(mates.len == @as(usize, rd) + traced.reference_net_origin.items.len);

    // Nets: each pair names its layout net, and maps the reference's.
    const layout_of = try arena.alloc(u32, ref_graph.netCount());
    @memset(layout_of, lvs.compare.unpaired);
    for (mates[rd..], traced.reference_net_origin.items) |mate, ref_row| {
        if (mate == lvs.compare.unpaired) continue;
        const layout_row = traced.layout_net_origin.items[mate - ld];
        out.net_name.items[layout_row] = strings.resolve(ref_graph.net_name.items[ref_row].?);
        layout_of[ref_row] = layout_row;
    }
    for (ref_graph.port_net.items) |p| {
        if (layout_of[p] == lvs.compare.unpaired) return refuse(arena, why, "reference pin {s} pairs with no layout net", .{strings.resolve(ref_graph.net_name.items[p].?)});
        try out.pin_net.append(arena, layout_of[p]);
    }

    // Devices: each reduced layout device's rows take its mate's cards,
    // spread evenly when the counts differ.
    const reduced_mate = try arena.alloc(u32, ld);
    @memset(reduced_mate, lvs.compare.unpaired);
    for (mates[0..rd], 0..) |mate, r| if (mate != lvs.compare.unpaired) {
        reduced_mate[mate] = @intCast(r);
    };
    const first_card = reference.devicesOf(top)[0];
    for (reduced_mate, 0..) |mate, g| {
        assert(mate != lvs.compare.unpaired); // a match pairs every device
        const rows = traced.layoutRowsOf(@intCast(g));
        const refs = traced.referenceRowsOf(mate);
        var last: usize = refs.len;
        var again: usize = 0;
        for (rows, 0..) |d, i| {
            const j = i * refs.len / rows.len;
            again = if (j == last) again + 1 else 1;
            last = j;
            const card = try cardName(arena, reference, strings, first_card + refs[j]);
            device_name[d] = if (again == 1) card else try std.fmt.allocPrint(arena, "{s}_{d}", .{ card, again });
        }
    }
    // A device the deck's `lvs ignore` or `filter_unused` left out of the
    // comparison is still drawn: it keeps its layout name.
    for (device_name, 0..) |*name, d| if (name.* == null) {
        name.* = try layoutName(arena, extracted.devices.kind.items[d], d);
    };
}

/// The layout's own names (module doc).
fn labelNames(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, layout_path: []const u8, out: *Subckt, device_name: []?[]const u8, why: *[]const u8) Error!void {
    const ports = &extracted.ports;
    out.name = std.fs.path.stem(layout_path);
    for (out.net_name.items, 0..) |*name, n| {
        const id: topology.NetId = @fromBackingInt(@intCast(n));
        const labels = ports.namesOf(id);
        if (labels.len == 0) continue;
        const text = loaded.strings.resolve(labels[0]);
        if (labels.len > 1) return refuse(arena, why, "net {d} carries {d} labels ({s} first), a short no pin can name", .{ n, labels.len, text });
        if (ports.netOf(labels[0]) == null) return refuse(arena, why, "label {s} names {d} nets, an open no pin can join", .{ text, ports.netsOf(labels[0]).len });
        name.* = text;
        try out.pin_net.append(arena, @intCast(n));
    }
    for (device_name, extracted.devices.kind.items, 0..) |*name, kind, d| name.* = try layoutName(arena, kind, d);
}

/// `n<id>` for every net still unnamed, lengthened with `_` until no other
/// net has that name in any case, so a schematic net literally `n7` or `N7`
/// keeps its own: SPICE reads node names case-blind.
fn fallbackNetNames(arena: Allocator, out: *Subckt) Allocator.Error!void {
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    for (out.net_name.items) |name| if (name) |text| try taken.put(arena, try std.ascii.allocLowerString(arena, text), {});
    for (out.net_name.items, 0..) |*name, n| if (name.* == null) {
        var text = try std.fmt.allocPrint(arena, "n{d}", .{n});
        while (taken.contains(text)) text = try std.fmt.allocPrint(arena, "{s}_", .{text});
        try taken.put(arena, text, {});
        name.* = text;
    };
}

/// One site per device terminal (in the device table's order), then one
/// per pin: a terminal's box is its device's marker and its layers every
/// terminal layer the deck's statements for that model name; a pin's box
/// is its label's polygon, on that polygon's layer.
fn sitesOf(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, pin_net: []const u32) Allocator.Error!analytical.Sites {
    const store = &loaded.store;
    const devices = &extracted.devices;
    const rec = &loaded.deck.deck.devices;
    var net: std.ArrayList(u32) = .empty;
    var box: std.ArrayList(geom.Bbox) = .empty;
    var layer_start: std.ArrayList(u32) = .empty;
    var layer: std.ArrayList(LayerId) = .empty;
    var layers: std.ArrayList(LayerId) = .empty;
    try layer_start.append(arena, 0);
    for (0..devices.len()) |d| {
        layers.clearRetainingCapacity();
        for (rec.model, rec.kind, 0..) |model, kind, row| {
            if (model != devices.model.items[d] or kind != devices.kind.items[d]) continue;
            for (rec.terminal[rec.terminal_start[row]..rec.terminal_start[row + 1]]) |l| {
                if (std.mem.findScalar(LayerId, layers.items, l) == null) try layers.append(arena, l);
            }
        }
        const marker = store.polyBbox(devices.marker.items[d]);
        for (devices.terminalsOf(@fromBackingInt(@intCast(d))).nets) |n| {
            try net.append(arena, @backingInt(n));
            try box.append(arena, marker);
            try layer.appendSlice(arena, layers.items);
            try layer_start.append(arena, @intCast(layer.items.len));
        }
    }
    const ports = &extracted.ports;
    for (pin_net) |n| {
        try net.append(arena, n);
        // A pin LVS paired with an unlabelled net has no label to sit at.
        const row = std.sort.lowerBound(topology.NetId, ports.net.items, @as(topology.NetId, @fromBackingInt(n)), orderNet);
        if (row < ports.net.items.len and @backingInt(ports.net.items[row]) == n) {
            const poly = ports.poly.items[row];
            try box.append(arena, store.polyBbox(poly));
            try layer.append(arena, store.polyLayer(poly));
        } else try box.append(arena, .{ .xlo = 0, .ylo = 0, .xhi = 0, .yhi = 0 });
        try layer_start.append(arena, @intCast(layer.items.len));
    }
    return .{ .net = net.items, .box = box.items, .layer_start = layer_start.items, .layer = layer.items };
}

/// A reference card's name as a flat netlist calls it: its own at the top,
/// else under its innermost placement's path, ngspice's way: `x1.xm1` for
/// a subcircuit card, `m.x1.m1` for a primitive.
fn cardName(arena: Allocator, reference: *const @import("ingest").netlist.Netlist, strings: *const geom.StrTable, row: u32) Allocator.Error![]const u8 {
    const own = strings.resolve(reference.device_name.items[row]);
    var path: ?[]const u8 = null;
    var span: u32 = std.math.maxInt(u32);
    for (reference.placements.items) |p| {
        if (row < p.devices[0] or row >= p.devices[1] or p.devices[1] - p.devices[0] >= span) continue;
        span = p.devices[1] - p.devices[0];
        path = strings.resolve(p.path);
    }
    const at = path orelse return own;
    if (std.ascii.toLower(own[0]) == 'x') return std.fmt.allocPrint(arena, "{s}.{s}", .{ at, own });
    return std.fmt.allocPrint(arena, "{c}.{s}.{s}", .{ own[0], at, own });
}

/// A device's name by family letter and layout index: `M3`, `Q0`.
fn layoutName(arena: Allocator, kind: @import("ingest").deck.DeviceKind, d: usize) Allocator.Error![]const u8 {
    const letter: u8 = switch (kind) {
        .mos => 'M',
        .bjt => 'Q',
        .resistor => 'R',
        .capacitor => 'C',
        .diode => 'D',
        .inductor => 'L',
        .cell => 'X',
    };
    return std.fmt.allocPrint(arena, "{c}{d}", .{ letter, d });
}

/// Two cards of one name are one instance to a simulator.
fn refuseDuplicateDevices(arena: Allocator, names: []const []const u8, why: *[]const u8) Error!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (names) |name| {
        if ((try seen.getOrPut(arena, name)).found_existing) return refuse(arena, why, "two devices would both be named {s}", .{name});
    }
}

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

fn rankLess(roles: []const topology.TerminalRole, a: u32, b: u32) bool {
    return topology.card.cardRank(roles[a]) < topology.card.cardRank(roles[b]);
}

fn orderU32(want: u32, item: u32) std.math.Order {
    return std.math.order(want, item);
}

fn orderNet(want: topology.NetId, item: topology.NetId) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(item));
}

test "a fallback name steps past a label that differs only in case" {
    // Oracle: SPICE node names are case-blind (ngspice folds them to lower
    // case), so net 1's fallback cannot be `n1` beside a net labelled `N1`;
    // net 2's `n2` collides with nothing.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Subckt = .{};
    try out.net_name.appendSlice(arena, &.{ "N1", null, null });
    try fallbackNetNames(arena, &out);
    try std.testing.expectEqualStrings("N1", out.net_name.items[0].?);
    try std.testing.expectEqualStrings("n1_", out.net_name.items[1].?);
    try std.testing.expectEqualStrings("n2", out.net_name.items[2].?);
}
