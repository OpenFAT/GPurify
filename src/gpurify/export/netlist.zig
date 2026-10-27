//! The extracted circuit as a SPICE subcircuit, optionally with its
//! parasitics. In: the net count, the device table, the ports, and a
//! parasitic network or none. Out: the netlist text. Ported from
//! src/export/netlist.rs.
//!
//! The subcircuit is `TOP` (never the layout path, which the header keeps
//! out of the body); its pins are the labelled nets in ascending net order.
//! Devices go out in ascending `DeviceId`, terminals reordered onto their
//! card positions (drain, gate, source, bulk), sizes as the exact integers
//! measured in database units (the file says so: no grid is passed), a
//! shared measure as the quoted quotient `'70000/2'`. A net is its label,
//! or `n` and its id lengthened with `_` until no label has that name;
//! SPICE carries its own netlist, so it numbers an anonymous net where
//! SPEF and DSPF refuse it. With parasitics, a net's nodes are `net:i`,
//! every terminal and pin sits on its net's first node (the network has no
//! terminal-to-node column), and elements are cards `Rp`, `Cp`, `Lp`, `Kp`
//! and the element's row.
//!
//! Contents:
//! - `pub fn writeSpice(w: *std.Io.Writer, gpa: Allocator, net_count: u32, devices: *const DeviceTable, ports: *const PortTable, strings: *const StrTable, parasitics: ?*const ParasiticNetwork, head: *const Header, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom");
const StrTable = geom.StrTable;
const topology = @import("check").topology;
const NetId = topology.NetId;
const PortTable = topology.PortTable;
const DeviceTable = topology.DeviceTable;
const TerminalRole = topology.TerminalRole;
const network_mod = @import("extract").network;
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const float = geom.float;
const header = @import("header.zig");
const Header = header.Header;
const Error = header.Error;
const Diagnostic = header.Diagnostic;
const net = @import("network.zig");

/// What names a node: the tables, and a scratch buffer for fallback names.
const Ctx = struct {
    w: *Writer,
    gpa: Allocator,
    ports: *const PortTable,
    strings: *const StrTable,
    spliced: ?*const ParasiticNetwork,
    diag: *Diagnostic,
    name: *std.ArrayList(u8),
};

/// Writes the subcircuit; `parasitics` null writes the schematic alone.
/// Refused before the first byte: a split or shorted label (a pin is one
/// node, so labels must name nets one to one), and with parasitics a NaN
/// or infinite value or a mutual inductance no two inductances explain.
/// Refused after the `.subckt` line: a port bound to a net outside
/// `0..net_count`; while writing: an element on a node outside the network.
pub fn writeSpice(w: *Writer, gpa: Allocator, net_count: u32, devices: *const DeviceTable, ports: *const PortTable, strings: *const StrTable, parasitics: ?*const ParasiticNetwork, head: *const Header, diag: *Diagnostic) Error!void {
    for (0..net_count) |n| try net.checkLabels(ports, @fromBackingInt(@intCast(n)), diag);
    var couplings: std.ArrayList(?net.Coupling) = .empty;
    defer couplings.deinit(gpa);
    if (parasitics) |network| {
        try net.checkFinite(network, diag);
        try net.mutualCouplingsInto(gpa, network, &couplings, diag);
    }
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    const c: Ctx = .{ .w = w, .gpa = gpa, .ports = ports, .strings = strings, .spliced = parasitics, .diag = diag, .name = &name };

    try w.print("* {s} SPICE netlist\n* deck: {s}\n* layout: {s}\n", .{ head.tool_version, head.deck_path, head.layout_path });
    if (head.timestamp) |stamp| try w.print("* written: {s}\n", .{stamp});
    // No `Grid` here to name a physical unit; saying so keeps a simulator
    // from reading database units as metres.
    try w.writeAll("* lengths below are in database units\n.subckt TOP");
    // ponytail: O(nets · log ports) through `nameOf`; a merge of the port
    // column against 0..net_count is one pass if pin lists grow.
    var pins: u32 = 0;
    for (0..net_count) |n| {
        const id: NetId = @fromBackingInt(@intCast(n));
        if (ports.nameOf(id) == null) continue;
        pins += 1;
        try w.writeByte(' ');
        try terminalNode(c, id);
    }
    try w.writeByte('\n');
    // A binding to a net past `net_count` was never reached above: its pin
    // is missing while device cards name the node, so fail closed.
    if (pins != ports.len()) {
        diag.what = "a port bound to a net outside the extraction";
        return error.Unrepresentable;
    }

    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    for (0..devices.len()) |d| {
        const id: topology.DeviceId = @fromBackingInt(@intCast(d));
        const letter: u8 = switch (devices.kind.items[d]) {
            .mos => 'M',
            .bjt => 'Q',
            .resistor => 'R',
            .capacitor => 'C',
            .diode => 'D',
            .inductor => 'L',
            .cell => 'X',
        };
        // Parasitic cards carry a `p` in the same slot, so `R0` and `Rp0`
        // cannot collide.
        try w.print("{c}{d}", .{ letter, d });
        // Terminals in card order, two of one rank in the recogniser's
        // (a stable sort).
        const terminals = devices.terminalsOf(id);
        order.clearRetainingCapacity();
        for (0..terminals.roles.len) |t| try order.append(gpa, @intCast(t));
        std.mem.sort(u32, order.items, terminals.roles, rankLess);
        for (order.items) |t| {
            try w.writeByte(' ');
            try terminalNode(c, terminals.nets[t]);
        }
        try w.print(" {s}", .{strings.resolve(devices.model.items[d])});
        const params = devices.paramsOf(id);
        for (params.names, params.measures) |param, measure| {
            const key = switch (param) {
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
            // Exact integers: a coordinate has no grid here to become a
            // physical quantity. A share is the exact quotient, quoted.
            const raw: i128, const ways: u32 = switch (measure) {
                .length => |v| .{ v, 1 },
                .area => |v| .{ v, 1 },
                .count => |v| .{ v, 1 },
                .length_share => |s| .{ s.length, s.ways },
                .area_share => |s| .{ s.area, s.ways },
            };
            if (ways == 1) try w.print(" {s}={d}", .{ key, raw }) else try w.print(" {s}='{d}/{d}'", .{ key, raw, ways });
        }
        try w.writeByte('\n');
    }

    if (parasitics) |network| for (0..network.elementCount()) |row| {
        if (couplings.items[row]) |k| {
            try w.print("Kp{d} Lp{d} Lp{d} ", .{ row, k.a, k.b });
            try float.fixed6(w, k.k);
            try w.writeByte('\n');
            continue;
        }
        // The card `writeDspf` gives the element, so the two files agree.
        const card = net.card(network.kind.items[row]);
        try w.print("{c}p{d} ", .{ card.letter, row });
        try node(c, network, network.from.items[row]);
        const to = network.to.items[row];
        // SPICE's ground: a missing far end is a capacitance to it.
        if (to == .ground) try w.writeAll(" 0") else {
            try w.writeByte(' ');
            try node(c, network, to);
        }
        try w.writeByte(' ');
        try float.fixed6(w, network.value.items[row]);
        try w.print("{s}\n", .{card.suffix});
    };
    try w.writeAll(".ends TOP\n");
}

// ---- private ----

/// Where a terminal sits on its family's card: `Mname nd ng ns nb`; a
/// passive's pin by position.
fn cardRank(role: TerminalRole) u16 {
    return switch (role) {
        .drain, .collector => 0,
        .gate, .base => 1,
        .source, .emitter => 2,
        .bulk => 3,
        .pin => |position| position,
    };
}

fn rankLess(roles: []const TerminalRole, a: u32, b: u32) bool {
    return cardRank(roles[a]) < cardRank(roles[b]);
}

/// The node a terminal of `n` sits on: its net's first parasitic node, or
/// the plain net name where it has none (or no network was given).
fn terminalNode(c: Ctx, n: NetId) Error!void {
    if (c.spliced) |network| if (network.firstNode(@backingInt(n))) |first| return node(c, network, first);
    try netName(c, n);
}

/// `net:index`, the net half through `netName`'s fallback, unlike SPEF.
fn node(c: Ctx, network: *const ParasiticNetwork, at: NodeId) Error!void {
    const place = try net.nodePlace(network, at, c.diag);
    try netName(c, @fromBackingInt(place.net));
    try c.w.print(":{d}", .{place.index});
}

/// A net's label, or `n<id>` lengthened with `_` until no port carries it,
/// so a label literally `n7` cannot short net 7 to its net.
fn netName(c: Ctx, n: NetId) Error!void {
    if (c.ports.nameOf(n)) |name| return c.w.writeAll(c.strings.resolve(name));
    c.name.clearRetainingCapacity();
    try c.name.print(c.gpa, "n{d}", .{@backingInt(n)});
    while (c.strings.get(c.name.items)) |taken| {
        if (c.ports.netsOf(taken).len == 0) break;
        try c.name.append(c.gpa, '_');
    }
    try c.w.writeAll(c.name.items);
}
