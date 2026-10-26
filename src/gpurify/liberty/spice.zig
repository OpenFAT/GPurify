//! The simulator's input text: the macro as a `.subckt` and one testbench
//! deck per corner. In: a `Circuit`, the spec and a corner. Out: ngspice
//! text, every value in SI base units except device lengths and areas,
//! divided by `Simulator.scale` and its square for `.option scale`. Ported
//! from src/liberty/spice.rs (`si`, `node`, `write_subckt`, `scale_option`,
//! `pin_node`, `pin_source`, `pin_load`, `Precision`, `write_deck`).
//!
//! Every pin is driven by a source the characterizer rewrites (`alter`)
//! before each analysis: `vp<i>` on pin `i`'s node `p<i>`, DC on a supply,
//! a PWL on an input, clock or analog pin; output `i` carries load `cp<i>`.
//!
//! Contents:
//! - `pub fn si(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void`, `pub const Si`, `pub fn fmtSi(value: f64) Si`
//! - `pub fn writeSubckt(c: *const Circuit, macro: *const MacroSpec, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn writeScaleOption(sim: Simulator, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn writeParam(w: *std.Io.Writer, name: []const u8, value: Param, scale: f64) std.Io.Writer.Error!void`
//! - `pub const Precision = struct { reltol, abstol, vntol, trtol }`
//! - `pub fn writeDeck(macro: *const MacroSpec, corner: *const CornerSpec, subckt: []const u8, precision: Precision, statistical: bool, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const Writer = std.Io.Writer;
const spec = @import("spec.zig");
const MacroSpec = spec.MacroSpec;
const CornerSpec = spec.CornerSpec;
const Simulator = spec.Simulator;
const circuit = @import("circuit.zig");
const Circuit = circuit.Circuit;
const Param = circuit.Param;
const numbers = @import("numbers.zig");

/// A number as the simulator reads it: Rust's `{:e}` (`1.8e0`), never an
/// SI suffix, which SPICE reads without case (`M` is milli).
pub fn si(w: *Writer, value: f64) Writer.Error!void {
    return numbers.exp(w, value);
}

/// `si` as a `{f}` argument.
pub const Si = struct {
    value: f64,
    pub fn format(s: Si, w: *Writer) Writer.Error!void {
        return si(w, s.value);
    }
};

pub fn fmtSi(value: f64) Si {
    return .{ .value = value };
}

/// Appends the macro as `.subckt <cell>`, ports in spec order: device cards
/// `<prefix>d<i>`, wire resistors `Rw<i>`, capacitors `Cw<i>`, node 0
/// ground and every other node `n<k>`.
pub fn writeSubckt(c: *const Circuit, macro: *const MacroSpec, w: *Writer) Writer.Error!void {
    try w.print(".subckt {s}", .{macro.cell});
    for (c.pin_node.items) |n| try w.print(" {f}", .{Node{ .n = n }});
    try w.writeByte('\n');
    for (0..c.deviceCount()) |d| {
        try w.print("{s}d{d}", .{ macro.simulator.prefix, d });
        for (c.terminalsOf(d)) |n| try w.print(" {f}", .{Node{ .n = n }});
        try w.print(" {s}", .{c.device_model.items[d]});
        const params = c.paramsOf(d);
        for (params.names, params.values) |name, value| try writeParam(w, name, value, macro.simulator.scale);
        try w.writeByte('\n');
    }
    for (c.resistor_a.items, c.resistor_b.items, c.resistor_ohms.items, 0..) |a, b, ohms, i|
        try w.print("Rw{d} {f} {f} {f}\n", .{ i, Node{ .n = a }, Node{ .n = b }, fmtSi(ohms) });
    for (c.capacitor_a.items, c.capacitor_b.items, c.capacitor_farads.items, 0..) |a, b, farads, i|
        try w.print("Cw{d} {f} {f} {f}\n", .{ i, Node{ .n = a }, Node{ .n = b }, fmtSi(farads) });
    try w.print(".ends {s}\n", .{macro.cell});
}

/// The `.option scale` line; nothing when the scale is exactly one.
pub fn writeScaleOption(sim: Simulator, w: *Writer) Writer.Error!void {
    if (sim.scale == 1.0) return;
    try w.print(".option scale={f}\n", .{fmtSi(sim.scale)});
}

/// ` name=value`: a length divided by `scale`, an area by its square.
pub fn writeParam(w: *Writer, name: []const u8, value: Param, scale: f64) Writer.Error!void {
    switch (value) {
        .length => |m| try w.print(" {s}={f}", .{ name, fmtSi(m / scale) }),
        .area => |m2| try w.print(" {s}={f}", .{ name, fmtSi(m2 / (scale * scale)) }),
        .count => |n| try w.print(" {s}={d}", .{ name, n }),
    }
}

/// Tolerances every analysis runs at.
pub const Precision = struct {
    reltol: f64,
    /// A.
    abstol: f64,
    /// V.
    vntol: f64,
    /// Truncation-error overestimate; 1 trusts the error estimate fully.
    trtol: f64,
};

/// Appends one corner's testbench: its model lines (`mc_models` when
/// `statistical`), the macro as `xdut`, a DC source on every supply, a
/// rewritable PWL source on every input, clock and analog pin (an analog pin
/// starts at its bias), a load on every output, and `.end`. No analysis:
/// a session sends those.
pub fn writeDeck(macro: *const MacroSpec, corner: *const CornerSpec, subckt: []const u8, precision: Precision, statistical: bool, w: *Writer) Writer.Error!void {
    const sim = macro.simulator;
    try w.print("* {s} at {s}\n", .{ macro.cell, corner.name });
    for (if (statistical) corner.mc_models else corner.models) |line| try w.print("{s}\n", .{line});
    try writeScaleOption(sim, w);
    try w.print(".option reltol={f} abstol={f} vntol={f} trtol={f}\n", .{ fmtSi(precision.reltol), fmtSi(precision.abstol), fmtSi(precision.vntol), fmtSi(precision.trtol) });
    for (sim.options) |option| try w.print(".option {s}\n", .{option});
    try w.print(".temp {f}\n", .{fmtSi(corner.temperature)});
    try w.writeAll(subckt);
    try w.writeAll("xdut");
    for (0..macro.pins.len) |i| try w.print(" p{d}", .{i});
    try w.print(" {s}\n", .{macro.cell});
    for (macro.pins, 0..) |pin, i| switch (pin.role) {
        .power, .ground, .nwell, .pwell => try w.print("vp{d} p{d} 0 DC {f}\n", .{ i, i, fmtSi(corner.supplies.get(pin.name).?) }),
        .output => try w.print("cp{d} p{d} 0 1e-18\n", .{ i, i }),
        .input, .clock, .analog => try w.print("vp{d} p{d} 0 PWL(0 {f}) AC 0\n", .{ i, i, fmtSi(pin.bias orelse 0.0) }),
    };
    try w.writeAll(".end\n");
}

// ---- private ----

/// A node name: `0` for ground, else `n<k>`.
const Node = struct {
    n: u32,
    pub fn format(node: Node, w: *Writer) Writer.Error!void {
        if (node.n == 0) return w.writeByte('0');
        try w.print("n{d}", .{node.n});
    }
};

test "a subckt writes nodes, scaled parameters and wire elements" {
    // Oracle: construct-from-answer, by spice.rs's card spellings: pins in
    // spec order on their nodes, `Xd0` with a 1 µm length over a 1e-6 scale
    // written `l=1e0`, ground as `0`, numbers in `{:e}`.
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Circuit = .{ .node_count = 3 };
    try c.pin_node.appendSlice(a, &.{ 1, 2 });
    try c.device_kind.append(a, .mos);
    try c.device_model.append(a, "nfet");
    try c.terminal_start.appendSlice(a, &.{ 0, 2 });
    try c.terminal_node.appendSlice(a, &.{ 1, 0 });
    try c.param_start.appendSlice(a, &.{ 0, 2 });
    try c.param_name.appendSlice(a, &.{ "l", "nf" });
    try c.param_value.appendSlice(a, &.{ .{ .length = 1e-6 }, .{ .count = 2 } });
    try c.resistor_a.append(a, 1);
    try c.resistor_b.append(a, 2);
    try c.resistor_ohms.append(a, 12.5);
    try c.capacitor_a.append(a, 2);
    try c.capacitor_b.append(a, 0);
    try c.capacitor_farads.append(a, 1e-15);
    const macro: MacroSpec = .{ .cell = "m", .pins = &.{ .{ .name = "a", .role = .input }, .{ .name = "y", .role = .output } }, .corners = &.{} };
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeSubckt(&c, &macro, &w);
    try std.testing.expectEqualStrings(".subckt m n1 n2\nXd0 n1 0 nfet l=1e0 nf=2\nRw0 n1 n2 1.25e1\nCw0 n2 0 1e-15\n.ends m\n", w.buffered());
}
