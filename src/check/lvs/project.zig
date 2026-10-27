//! Projection of both sides into a `Graph`: the layout from a topology
//! extraction, the reference from one subcircuit of a netlist. In: the
//! extracted `NetTable`/`DeviceTable`/`PortTable`, or a `Netlist` and a
//! subcircuit. Out: a `Graph` (cleared and refilled). Ported from
//! crates/check/src/lvs/graph.rs (`from_layout`, `from_reference`,
//! `comparable`, `card_role`, `spice_param_name`).
//!
//! Contents:
//! - `pub const Design = struct { store, nets, devices }`
//! - `pub fn spiceParamName(param: DeviceParam) []const u8`
//! - `pub fn fromLayoutInto(gpa: Allocator, nets: *const NetTable, devices: *const DeviceTable, ports: *const PortTable, strings: *const StrTable, grid: ?Grid, out: *Graph) Allocator.Error!void`
//! - `pub fn fromReferenceInto(gpa: Allocator, netlist: *const Netlist, subckt: SubcktId, out: *Graph) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const GeometryStore = geom.GeometryStore;
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
const Netlist = ingest.netlist.Netlist;
const SubcktId = ingest.netlist.SubcktId;
const device_mod = @import("../topology/device.zig");
const DeviceTable = device_mod.DeviceTable;
const DeviceParam = device_mod.DeviceParam;
const TerminalRole = device_mod.TerminalRole;
const NetTable = @import("../topology/net.zig").NetTable;
const PortTable = @import("../topology/port.zig").PortTable;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;

/// The extracted design LVS's layout checks read: the store and the net
/// and device tables extracted from it.
pub const Design = struct {
    store: *const GeometryStore,
    nets: *const NetTable,
    devices: *const DeviceTable,
};

/// The SPICE parameter name each measured `DeviceParam` compares under.
pub fn spiceParamName(param: DeviceParam) []const u8 {
    return switch (param) {
        .width => "w",
        .length => "l",
        .area => "area",
        .perimeter => "perim",
        .fins => "nfin",
        .fingers => "nf",
        .source_area => "as",
        .drain_area => "ad",
        .source_perimeter => "ps",
        .drain_perimeter => "pd",
        .emitter_area => "ae",
        .emitter_perimeter => "pe",
    };
}

/// Projects a topology extraction: device row `k` is `DeviceId` `k`, net row
/// `k` is `NetId` `k`, `port_net` ascending. A net's name is its port label.
/// Terminals keep the recogniser's order and roles, a resistor's or
/// inductor's ends both `pin = 0`. A measure is emitted in metres (area in
/// m², a share its fraction) only when its SPICE name is interned (so a
/// reference can state it) and a grid is given. A resistor's `r = sheet·l/w`
/// and a capacitor's `c = area_cap·area + fringe_cap·perim`, and an
/// inductor's `ind`, follow from the measures and the recogniser's
/// `DeviceValue` under the same rule; a coefficient the deck omits is not
/// computed. `devices` and `ports` must come from `nets`.
pub fn fromLayoutInto(gpa: Allocator, nets: *const NetTable, devices: *const DeviceTable, ports: *const PortTable, strings: *const StrTable, grid: ?Grid, out: *Graph) Allocator.Error!void {
    inline for (@typeInfo(Graph).@"struct".field_names) |f| @field(out, f).clearRetainingCapacity();
    const net_count = nets.netCount();
    try out.device_kind.appendSlice(gpa, devices.kind.items);
    try out.device_model.appendSlice(gpa, devices.model.items);
    try out.device_terminal_start.appendSlice(gpa, devices.terminal_start.items);
    try out.terminal_role.appendSlice(gpa, devices.terminal_role.items);
    for (0..devices.len()) |d| {
        const from = devices.terminal_start.items[d];
        const to = devices.terminal_start.items[d + 1];
        for (out.terminal_role.items[from..to]) |*role| role.* = comparable(devices.kind.items[d], role.*);
    }
    try out.terminal_net.ensureTotalCapacity(gpa, devices.terminal_net.items.len);
    for (devices.terminal_net.items) |n| out.terminal_net.appendAssumeCapacity(@backingInt(n));

    const metre_per_dbu: ?f64 = if (grid) |g| 1e-6 / @as(f64, @floatFromInt(g.dbu_per_um)) else null;
    try out.device_param_start.append(gpa, 0);
    for (0..devices.len()) |d| {
        // `w`, `l`, `area`, `perim` in metres whether or not interned: `r`
        // and `c` follow from them.
        var w: ?f64 = null;
        var l: ?f64 = null;
        var area: ?f64 = null;
        var perim: ?f64 = null;
        const params = devices.paramsOf(@fromBackingInt(@intCast(d)));
        for (params.names, params.measures) |name, measure| {
            const value: f64 = switch (measure) {
                .count => |c| @floatFromInt(c),
                .length => |v| if (metre_per_dbu) |s| @as(f64, @floatFromInt(v)) * s else continue,
                .area => |v| if (metre_per_dbu) |s| @as(f64, @floatFromInt(v)) * s * s else continue,
                .length_share => |v| if (metre_per_dbu) |s| @as(f64, @floatFromInt(v.length)) * s / @as(f64, @floatFromInt(v.ways)) else continue,
                .area_share => |v| if (metre_per_dbu) |s| @as(f64, @floatFromInt(v.area)) * s * s / @as(f64, @floatFromInt(v.ways)) else continue,
            };
            switch (name) {
                .width => w = value,
                .length => l = value,
                .area => area = value,
                .perimeter => perim = value,
                .fins, .fingers, .source_area, .drain_area, .source_perimeter, .drain_perimeter, .emitter_area, .emitter_perimeter => {},
            }
            if (strings.get(spiceParamName(name))) |id| try out.param.append(gpa, .{ .name = id, .value = value });
        }
        const law: ingest.deck.DeviceValue = if (d < devices.value.items.len) devices.value.items[d] else .{};
        // Ω/□ times squares.
        const r: ?f64 = if (law.sheet_ohm_sq != null and l != null and w != null) law.sheet_ohm_sq.? * l.? / w.? else null;
        // aF/µm² is 1e-6 F/m², aF/µm is 1e-12 F/m.
        const area_term: ?f64 = if (law.area_cap_af_um2 != null and area != null) law.area_cap_af_um2.? * 1e-6 * area.? else null;
        const fringe_term: ?f64 = if (law.fringe_cap_af_um != null and perim != null) law.fringe_cap_af_um.? * 1e-12 * perim.? else null;
        const c: ?f64 = if (area_term == null and fringe_term == null) null else (area_term orelse 0.0) + (fringe_term orelse 0.0);
        // nH to henries; every device of the recogniser has it.
        const ind: ?f64 = if (law.inductance_nh) |nh| nh * 1e-9 else null;
        for ([_]struct { []const u8, ?f64 }{ .{ "r", r }, .{ "c", c }, .{ "ind", ind } }) |row| {
            if (strings.get(row[0])) |id| if (row[1]) |v| try out.param.append(gpa, .{ .name = id, .value = v });
        }
        try out.device_param_start.append(gpa, @intCast(out.param.items.len));
    }

    // ponytail: O(nets · log ports) through `nameOf`; a linear merge over
    // `ports.net` is the upgrade if a profile shows it.
    try out.net_name.ensureTotalCapacity(gpa, net_count);
    for (0..net_count) |n| {
        const name = ports.nameOf(@fromBackingInt(@intCast(n)));
        out.net_name.appendAssumeCapacity(name);
        if (name != null) try out.port_net.append(gpa, @intCast(n));
    }
    try graph.transposeInto(gpa, out, net_count);
}

/// Projects one subcircuit of a reference netlist. Roles come from card
/// position: MOS drain, gate, source, bulk; BJT collector, base, emitter,
/// then `pin = 3`; every other kind `pin = position` (a resistor's and an
/// inductor's both `pin = 0`). Device and net rows follow the netlist's
/// order within the subcircuit; every net is named; parameters are copied
/// as stated; `port_net` keeps port order. A terminal on a net of another
/// subcircuit lands on no net. Only the subcircuit's own device cards are
/// kept, so flatten first (testing-plan F1).
pub fn fromReferenceInto(gpa: Allocator, netlist: *const Netlist, subckt: SubcktId, out: *Graph) Allocator.Error!void {
    inline for (@typeInfo(Graph).@"struct".field_names) |f| @field(out, f).clearRetainingCapacity();
    const span = netlist.devicesOf(subckt);
    const first = span[0];
    const last = span[1];

    // `rank[reference row]`: the graph net, or `no_net` for another cell's.
    const rank = try gpa.alloc(u32, netlist.net_subckt.items.len);
    defer gpa.free(rank);
    var net_count: u32 = 0;
    for (netlist.net_subckt.items, rank, 0..) |owner, *slot, row| {
        if (owner == subckt) {
            slot.* = net_count;
            net_count += 1;
            try out.net_name.append(gpa, netlist.net_name.items[row]);
        } else slot.* = no_net;
    }

    try out.device_kind.appendSlice(gpa, netlist.device_kind.items[first..last]);
    try out.device_model.appendSlice(gpa, netlist.device_model.items[first..last]);
    const terminals = try rebaseInto(gpa, netlist.device_terminal_start.items, first, last, &out.device_terminal_start);
    const params = try rebaseInto(gpa, netlist.device_param_start.items, first, last, &out.device_param_start);
    for (netlist.terminal_net.items[terminals[0]..terminals[1]]) |n| try out.terminal_net.append(gpa, rank[@backingInt(n)]);
    try out.param.appendSlice(gpa, netlist.param.items[params[0]..params[1]]);
    for (0..last - first) |d| {
        const kind = netlist.device_kind.items[first + d];
        const width = out.device_terminal_start.items[d + 1] - out.device_terminal_start.items[d];
        for (0..width) |position| try out.terminal_role.append(gpa, cardRole(kind, position));
    }
    for (netlist.portsOf(subckt)) |n| try out.port_net.append(gpa, rank[@backingInt(n)]);
    try graph.transposeInto(gpa, out, net_count);
}

// ---- private ----

/// One CSR offset column's run `first..=last` rebased to zero into `out`; a
/// netlist without the column still owes the graph a terminator. Returns
/// the source payload span.
fn rebaseInto(gpa: Allocator, column: []const u32, first: u32, last: u32, out: *std.ArrayList(u32)) Allocator.Error![2]u32 {
    if (column.len <= last) {
        try out.append(gpa, 0);
        return .{ 0, 0 };
    }
    const offsets = column[first .. last + 1];
    for (offsets) |offset| try out.append(gpa, offset - offsets[0]);
    return .{ offsets[0], offsets[offsets.len - 1] };
}

/// The role LVS compares a terminal under: a resistor's or inductor's two
/// ends are interchangeable, so both become `pin = 0`; every other role is
/// kept (testing-plan F15).
fn comparable(kind: DeviceKind, role: TerminalRole) TerminalRole {
    return switch (kind) {
        .resistor, .inductor => switch (role) {
            .pin => .{ .pin = 0 },
            .gate, .source, .drain, .bulk, .base, .emitter, .collector => role,
        },
        .mos, .bjt, .capacitor, .diode, .cell => role,
    };
}

/// A SPICE card position to its role: drain-first MOS, collector-first BJT.
fn cardRole(kind: DeviceKind, position: usize) TerminalRole {
    const named: []const TerminalRole = switch (kind) {
        .mos => &.{ .drain, .gate, .source, .bulk },
        .bjt => &.{ .collector, .base, .emitter },
        .resistor, .capacitor, .diode, .inductor, .cell => &.{},
    };
    if (position < named.len) return named[position];
    return comparable(kind, .{ .pin = @intCast(@min(position, std.math.maxInt(u8))) });
}
