//! The extracted layout as a circuit a simulator can run: `Loaded` +
//! `Extracted`, the spec's pins and the wire parasitics → a `Circuit` in SI
//! units, every node numbered, node 0 the simulator's ground. Ported from
//! src/liberty/circuit.rs (`Wires`, `Param`, `Circuit`, `CircuitError`,
//! `pin_nets`, `substrate_nets`, `build`); the builder's transforms are
//! circuit_*.zig.
//!
//! Two shapes. `.lumped` is one node per net and no wire elements: the
//! device netlist, for leakage and the static capacitance sweep.
//! `.distributed` is a rectangle graph: every conductor polygon cut into
//! slab rectangles, each a node; two rectangles sharing an edge joined by
//! the sheet resistance centre to centre, each via cut its own resistor,
//! each device terminal on the rectangle that touches its channel. Ground C
//! per rectangle from the stack (area less what lies over a channel, plus
//! the perimeter no same-net rectangle covers); coupling the analytical
//! extractor's, placed between the two closest rectangles of its regions;
//! a field solve, when given, rescales every net's ground and every net
//! pair's coupling to the solved totals without moving them.
//!
//! Contents:
//! - `pub const Wires = union(enum) { lumped, distributed: Distributed }`, `pub const Distributed`
//! - `pub const Param = union(enum) { length, area, count }`
//! - `pub const Circuit = struct`, `Circuit.terminalsOf(c, d: usize) []const u32`, `Circuit.paramsOf(c, d: usize) Params`, `Circuit.pinNets(c, p: usize) []const NetId`
//! - `pub const Error = error{ MissingPin, ShortedPins, Geometry, Disconnected } || Allocator.Error`
//! - `pub fn pinNetsInto(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, macro: *const MacroSpec, start: *std.ArrayList(u32), nets: *std.ArrayList(NetId), diag: *Diagnostic) Error!void`
//! - `pub fn build(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, macro: *const MacroSpec, wires: Wires, diag: *Diagnostic) Error!Circuit`
//! - `Circuit.deviceCount(c) usize`

const std = @import("std");
const Allocator = std.mem.Allocator;
const check = @import("check");
const topology = check.topology;
const NetId = topology.net.NetId;
const TerminalRole = topology.device.TerminalRole;
const DeviceKind = @import("ingest").deck.DeviceKind;
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const Loaded = @import("../load.zig").Loaded;
const Extracted = @import("../extracted.zig").Extracted;
const spec = @import("spec.zig");
const MacroSpec = spec.MacroSpec;
const Diagnostic = spec.Diagnostic;
const graph = @import("circuit_graph.zig");
const Builder = graph.Builder;
const rects = @import("circuit_rects.zig");
const couple = @import("circuit_couple.zig");
const devices = @import("circuit_devices.zig");
const finish = @import("circuit_finish.zig");

/// Where wire parasitics come from.
pub const Wires = union(enum) {
    /// No wire elements; one node per net (`analytical`, `field`).
    lumped,
    /// The rectangle graph (`spice`, `statistical`).
    distributed: Distributed,
};

/// The analytical extraction the couplings come from, the problem it was
/// extracted over (its regions place each coupling), and an optional field
/// solve, one node per net, whose totals every net and pair is rescaled to.
pub const Distributed = struct {
    analytical: *const ParasiticNetwork,
    problem: extract.analytical.Problem,
    field: ?*const ParasiticNetwork,
};

/// A device parameter value, SI: metres (written divided by the scale),
/// square metres (by its square), or a count written as is.
pub const Param = union(enum) { length: f64, area: f64, count: u32 };

/// The circuit, SI units. Nodes are `0..node_count`, node 0 ground. Devices
/// are CSR over terminals (card order: `d g s b`, `c b e`, pins in order)
/// and over parameters, in device-table order.
pub const Circuit = struct {
    node_count: u32 = 0,
    device_kind: std.ArrayList(DeviceKind) = .empty,
    device_model: std.ArrayList([]const u8) = .empty,
    terminal_start: std.ArrayList(u32) = .empty,
    terminal_node: std.ArrayList(u32) = .empty,
    terminal_net: std.ArrayList(NetId) = .empty,
    terminal_role: std.ArrayList(TerminalRole) = .empty,
    param_start: std.ArrayList(u32) = .empty,
    /// `w`, `l`, `nf`, `as`, `ad`, `ps`, `pd`, `area`, `perim`/`pj`, `sa`, `sb`.
    param_name: std.ArrayList([]const u8) = .empty,
    param_value: std.ArrayList(Param) = .empty,
    resistor_a: std.ArrayList(u32) = .empty,
    resistor_b: std.ArrayList(u32) = .empty,
    resistor_ohms: std.ArrayList(f64) = .empty,
    /// `b == 0` is to ground; ascending by `(a, b)`, `a > b`.
    capacitor_a: std.ArrayList(u32) = .empty,
    capacitor_b: std.ArrayList(u32) = .empty,
    capacitor_farads: std.ArrayList(f64) = .empty,
    /// Per spec pin, in spec order.
    pin_node: std.ArrayList(u32) = .empty,
    /// Per spec pin, the layout nets it is: CSR, each run ascending.
    pin_net_start: std.ArrayList(u32) = .empty,
    pin_net: std.ArrayList(NetId) = .empty,

    pub const Params = struct { names: []const []const u8, values: []const Param };

    pub fn deviceCount(c: *const Circuit) usize {
        return c.device_kind.items.len;
    }

    pub fn terminalsOf(c: *const Circuit, d: usize) []const u32 {
        return c.terminal_node.items[c.terminal_start.items[d]..c.terminal_start.items[d + 1]];
    }

    pub fn paramsOf(c: *const Circuit, d: usize) Params {
        const from = c.param_start.items[d];
        const to = c.param_start.items[d + 1];
        return .{ .names = c.param_name.items[from..to], .values = c.param_value.items[from..to] };
    }

    pub fn pinNets(c: *const Circuit, p: usize) []const NetId {
        return c.pin_net.items[c.pin_net_start.items[p]..c.pin_net_start.items[p + 1]];
    }
};

/// `MissingPin`: a spec pin names no net (no label, and no substrate
/// geometry for the spec's `substrate`). `ShortedPins`: two pins labelled on
/// one net. `Geometry`: a conductor layer that is not valid rectilinear
/// geometry. `Disconnected`: a net whose resistor network falls apart. The
/// last two at `.distributed` only. `diag.message` is circuit.rs's text.
pub const Error = error{ MissingPin, ShortedPins, Geometry, Disconnected } || Allocator.Error;

/// The layout nets each spec pin is, in spec order, as CSR into `start` and
/// `nets` (cleared): every net its label is on, plus every net holding
/// substrate geometry for the spec's `substrate`. Each run is ascending and
/// never empty; a label on several nets (an open) gives all of them.
pub fn pinNetsInto(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, macro: *const MacroSpec, start: *std.ArrayList(u32), nets: *std.ArrayList(NetId), diag: *Diagnostic) Error!void {
    start.clearRetainingCapacity();
    nets.clearRetainingCapacity();
    const substrate = try substrateNets(arena, loaded, extracted);
    // `(label net, pin)`: two pins whose labels share a net are shorted.
    var labelled: std.ArrayList([2]u32) = .empty;
    try start.append(arena, 0);
    for (macro.pins, 0..) |pin, index| {
        const from = nets.items.len;
        if (loaded.strings.get(pin.name)) |id| for (extracted.ports.netsOf(id)) |net| {
            try nets.append(arena, net);
            try labelled.append(arena, .{ @backingInt(net), @intCast(index) });
        };
        const is_substrate = if (macro.substrate) |s| std.mem.eql(u8, s, pin.name) else false;
        if (is_substrate) try nets.appendSlice(arena, substrate);
        const run = sortDedup(nets.items[from..]);
        nets.shrinkRetainingCapacity(from + run);
        if (run == 0) {
            const hint = if (is_substrate) ", and the deck declares no substrate geometry" else "";
            diag.message = try arena.print("pin {s} names no net in the layout: no label carries it{s}", .{ pin.name, hint });
            return error.MissingPin;
        }
        try start.append(arena, @intCast(nets.items.len));
    }
    std.mem.sortUnstable([2]u32, labelled.items, {}, pairLess);
    for (labelled.items[0..labelled.items.len -| 1], labelled.items[@min(1, labelled.items.len)..]) |a, b| if (a[0] == b[0]) {
        diag.message = try arena.print("pins {s} and {s} are labelled on one net: the layout shorts them", .{ macro.pins[a[1]].name, macro.pins[b[1]].name });
        return error.ShortedPins;
    };
}

/// Builds the circuit for `macro` with wires as `wires` says. Node numbers
/// do not depend on hash or union order. Errors: `MissingPin`,
/// `ShortedPins`, and at `.distributed` also `Geometry` and `Disconnected`.
pub fn build(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, macro: *const MacroSpec, wires: Wires, diag: *Diagnostic) Error!Circuit {
    var out: Circuit = .{};
    try pinNetsInto(arena, loaded, extracted, macro, &out.pin_net_start, &out.pin_net, diag);
    var b = try Builder.init(arena, loaded, extracted);
    switch (wires) {
        .lumped => {},
        .distributed => |d| {
            try rects.rectangles(&b, diag);
            try rects.resistors(&b);
            try rects.overlaps(&b);
            try rects.vias(&b);
            try rects.groundCaps(&b);
            try couple.couplings(&b, d.analytical, d.problem, diag);
            if (d.field) |field| try couple.calibrate(&b, field);
        },
    }
    try devices.devices(&b, &out);
    if (wires == .distributed) try rects.connected(&b, diag);
    try finish.finish(&b, macro, &out);
    return out;
}

// ---- private ----

/// Every net holding a shape on a global (substrate) layer, ascending.
fn substrateNets(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted) Allocator.Error![]NetId {
    var nets: std.ArrayList(NetId) = .empty;
    for (loaded.deck.deck.connectivity.global) |layer| {
        if (@backingInt(layer) >= loaded.store.layerCount()) continue;
        const rows = loaded.store.polysOnLayer(layer);
        for (rows.start..rows.end) |row| {
            const net = extracted.nets.netOf(@fromBackingInt(@intCast(row)));
            if (net != .none) try nets.append(arena, net);
        }
    }
    nets.shrinkRetainingCapacity(sortDedup(nets.items));
    return nets.items;
}

/// Sorts `items` ascending and moves each value's first copy to the front;
/// the count kept.
fn sortDedup(items: []NetId) usize {
    std.mem.sortUnstable(NetId, items, {}, netLess);
    var kept: usize = 0;
    for (items) |n| {
        if (kept > 0 and items[kept - 1] == n) continue;
        items[kept] = n;
        kept += 1;
    }
    return kept;
}

fn netLess(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn pairLess(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}
