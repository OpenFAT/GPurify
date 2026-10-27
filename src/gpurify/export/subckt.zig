//! The extracted circuit as the SPICE and DSPF writers print it: one
//! subcircuit's name and pins, every layout net's name and pin node, and the
//! devices with their terminals on the parasitic network's nodes. In: what
//! `gpurify.subckt_build.buildInto` fills. Out: the device cards, written
//! here for both writers, which name nodes their own way.
//!
//! Contents:
//! - `pub const Value = union(enum) { length, area, count }`
//! - `pub const Subckt = struct`, `deinit`, `clear`, `deviceCount`, `terminalsOf`, `paramsOf`
//! - `pub fn writeCard(w: *std.Io.Writer, network: *const ParasiticNetwork, s: *const Subckt, device: usize, names: Names, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const float = @import("geom").float;
const DeviceKind = @import("ingest").deck.DeviceKind;
const network_mod = @import("extract").network;
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const header = @import("header.zig");
const Error = header.Error;
const Diagnostic = header.Diagnostic;
const net = @import("network.zig");
const Names = net.Names;

/// A device parameter: a length in database units, an area in their square
/// (both written divided by the scale, as `.option scale` reads them back),
/// or a count.
pub const Value = union(enum) { length: f64, area: f64, count: u32 };

/// One subcircuit. Nets are the layout's `NetId` rows. Invariants: the
/// `*_start` columns are CSR, one longer than the device columns;
/// `net_name` and `pin_node` hold one row per layout net; every
/// `terminal_node` and `pin_node` that is not `.ground` is a node of its
/// net.
pub const Subckt = struct {
    /// The `.subckt` name: the reference's top cell, or the layout file's
    /// stem. Every name is text the run owns.
    name: []const u8 = "",
    /// The pins in order, each a layout net.
    pin_net: std.ArrayList(u32) = .empty,
    /// Each net's name; null for one the writers have no name for.
    net_name: std.ArrayList(?[]const u8) = .empty,
    /// Each pin net's pin node, which SPICE writes bare; `.ground` for a
    /// net that is no pin, or has no node.
    pin_node: std.ArrayList(NodeId) = .empty,
    /// Each device's card name, its letter first (`XM1`).
    device_name: std.ArrayList([]const u8) = .empty,
    device_model: std.ArrayList([]const u8) = .empty,
    device_kind: std.ArrayList(DeviceKind) = .empty,
    /// Terminals in card order: MOS drain, gate, source, bulk; BJT
    /// collector, base, emitter; a passive's pins in turn.
    terminal_start: std.ArrayList(u32) = .empty,
    terminal_net: std.ArrayList(u32) = .empty,
    /// The node each terminal sits on; `.ground` when its net has none.
    terminal_node: std.ArrayList(NodeId) = .empty,
    param_start: std.ArrayList(u32) = .empty,
    /// The card's names for them (`w`, `nf`, `ad`, ...).
    param_name: std.ArrayList([]const u8) = .empty,
    param_value: std.ArrayList(Value) = .empty,
    /// The written length unit, nm: the deck's `netlist_scale`, or the
    /// metre (1e9).
    unit_nm: f64 = 1e9,
    /// Database units per written length unit.
    dbu_per_unit: f64 = 1.0,

    pub fn deinit(s: *Subckt, gpa: Allocator) void {
        inline for (@typeInfo(Subckt).@"struct".field_names) |f| {
            if (@typeInfo(@FieldType(Subckt, f)) == .@"struct") @field(s, f).deinit(gpa);
        }
    }

    /// Every row gone, the CSR columns holding their first offset.
    pub fn clear(s: *Subckt, gpa: Allocator) Allocator.Error!void {
        inline for (@typeInfo(Subckt).@"struct".field_names) |f| {
            if (@typeInfo(@FieldType(Subckt, f)) == .@"struct") @field(s, f).clearRetainingCapacity();
        }
        try s.terminal_start.append(gpa, 0);
        try s.param_start.append(gpa, 0);
    }

    pub fn deviceCount(s: *const Subckt) usize {
        return s.device_name.items.len;
    }

    /// One device's terminals: their nets and nodes, card order.
    pub fn terminalsOf(s: *const Subckt, device: usize) struct { nets: []const u32, nodes: []const NodeId } {
        const from = s.terminal_start.items[device];
        const to = s.terminal_start.items[device + 1];
        return .{ .nets = s.terminal_net.items[from..to], .nodes = s.terminal_node.items[from..to] };
    }

    pub fn paramsOf(s: *const Subckt, device: usize) struct { names: []const []const u8, values: []const Value } {
        const from = s.param_start.items[device];
        const to = s.param_start.items[device + 1];
        return .{ .names = s.param_name.items[from..to], .values = s.param_value.items[from..to] };
    }
};

/// `device`'s card and a newline: its name, each terminal's node as
/// `names` spells it (its net's bare name where the net has no node), its
/// model and its parameters.
pub fn writeCard(w: *Writer, network: *const ParasiticNetwork, s: *const Subckt, device: usize, names: Names, diag: *Diagnostic) Error!void {
    try w.writeAll(s.device_name.items[device]);
    const t = s.terminalsOf(device);
    for (t.nets, t.nodes) |n, node| {
        try w.writeByte(' ');
        if (node == .ground) try net.writeNameAs(w, n, names, diag) else try net.writeNodeAs(w, network, node, names, diag);
    }
    try w.print(" {s}", .{s.device_model.items[device]});
    try writeParams(w, s, device);
    try w.writeByte('\n');
}

// ---- private ----

/// ` name=value` for each of `device`'s parameters: a length divided by
/// the scale, an area by its square, each one division from database units
/// so `4200` nm at 1 µm reads `4.2`, in the shortest digits that read back
/// (`4.2e-6` below 1e-4); a count as itself.
fn writeParams(w: *Writer, s: *const Subckt, device: usize) Writer.Error!void {
    const params = s.paramsOf(device);
    for (params.names, params.values) |name, value| {
        try w.print(" {s}=", .{name});
        switch (value) {
            .length => |dbu| try float.debug(w, dbu / s.dbu_per_unit),
            .area => |dbu2| try float.debug(w, dbu2 / (s.dbu_per_unit * s.dbu_per_unit)),
            .count => |n| try w.print("{d}", .{n}),
        }
    }
}
