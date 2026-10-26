//! Device-region (MEOL) capacitance (catalog PEX-011): the capacitance
//! inside a transistor's footprint its SPICE model leaves to extraction,
//! from the gate to the source and drain contacts and to the diffusion
//! beside it. In: the network, the MOS devices as plain columns (check's
//! `DeviceTable` rows whose model a `pex_device` line names and whose width
//! is measured, filled by the engine), and the `pex_device` lines. Out: a
//! coupling from the gate net's first node to the source net's and to the
//! drain net's. Ported from crates/extract/src/device_region.rs.
//!
//! Each side of a gate gets `(gate_contact + gate_diffusion) · W`: a finger
//! has one source and one drain side of its width, so however the width is
//! split into fingers each net totals `W` of sides. StarRC and Quantus
//! extract these from the foundry's cross-section; no open PDK publishes
//! one, so the deck states the coefficients. A side on the gate's own net
//! adds nothing. Not modelled: trench-contact and gate resistance (the
//! network has no node inside a device).
//!
//! Contents:
//! - `pub const Mos = struct { model, width, gate, source, drain }`
//! - `pub fn addInto(gpa: Allocator, network: *ParasiticNetwork, devices: Mos, models: []const DeviceParasitics, grid: Grid) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const ingest = @import("ingest");
const DeviceParasitics = ingest.deck.DeviceParasitics;
const none = @import("stack.zig").none;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;

/// The MOS devices, one row each, as parallel columns.
pub const Mos = struct {
    /// The row of `models` (the `pex_device` line) naming the device's model.
    model: []const u32,
    /// The measured gate width.
    width: []const Dbu,
    /// Each terminal's net, `none` for a terminal the device lacks.
    gate: []const u32,
    source: []const u32,
    drain: []const u32,
};

/// Appends every device's region capacitances, then restores canonical
/// order. A device whose gate net has no node, or a side whose net has
/// none, adds nothing; nor does a value that is not positive.
pub fn addInto(gpa: Allocator, network: *ParasiticNetwork, devices: Mos, models: []const DeviceParasitics, grid: Grid) Allocator.Error!void {
    const n = devices.model.len;
    assert(devices.width.len == n and devices.gate.len == n and devices.source.len == n and devices.drain.len == n);
    if (n == 0) return;
    const per_um: f64 = @floatFromInt(grid.dbu_per_um);
    for (devices.model, devices.width, devices.gate, devices.source, devices.drain) |model, width, gate, source, drain| {
        const m = models[model];
        const ff = (m.gate_contact_af_um + m.gate_diffusion_af_um) * (@as(f64, @floatFromInt(width)) / per_um) / 1000.0;
        if (!(ff > 0.0)) continue;
        const gate_node = if (gate == none) continue else network.firstNode(gate) orelse continue;
        for ([2]u32{ source, drain }) |side| {
            if (side == none or side == gate) continue;
            const node = network.firstNode(side) orelse continue;
            try network.push(gpa, gate_node, node, .coupling_cap, ff);
        }
    }
    try network.sortCanonical(gpa);
}

test "each side of a gate gets the coefficients times its width" {
    // Oracle: the module's definition, hand-derived: 0.3 + 0.2 aF/µm over a
    // 2 µm gate is 1 aF = 0.001 fF on each side off the gate's net; a
    // device whose drain is its gate net gets its source side only.
    const gpa = std.testing.allocator;
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try n.node_net.appendSlice(gpa, &.{ 0, 0, 1, 2 });
    try n.node_layer.appendNTimes(gpa, @fromBackingInt(0), 4);
    const models = [_]DeviceParasitics{.{ .model = "nfet", .gate_contact_af_um = 0.3, .gate_diffusion_af_um = 0.2 }};
    try addInto(gpa, &n, .{ .model = &.{ 0, 0 }, .width = &.{ 2_000, 2_000 }, .gate = &.{ 0, 0 }, .source = &.{ 1, 2 }, .drain = &.{ 2, 0 } }, &models, .{ .dbu_per_um = 1000 });
    try std.testing.expectEqualSlices(NodeId, &.{ .at(0), .at(0), .at(0) }, n.from.items);
    try std.testing.expectEqualSlices(NodeId, &.{ .at(2), .at(3), .at(3) }, n.to.items);
    for (n.value.items) |v| try std.testing.expectApproxEqAbs(0.001, v, 1e-15);
}
