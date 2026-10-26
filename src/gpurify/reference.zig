//! A reference netlist given as text → the `Netlist` and its top. Ported
//! from src/engine/pipeline.rs (`read_references`, `read_reference_text`,
//! `spectre_by_opener`).
//!
//! The dialect is the first subcircuit opener's (`subckt` Spectre,
//! `.subckt` SPICE); the file name decides only when there is none.
//! Structural Verilog places the netlist's subcircuits as cells, as Netgen
//! reads a digital top level over its cell library (catalog LVS-075).
//!
//! Contents:
//! - `pub const Text = struct { text, spectre_by_name }`, `pub const Read = struct { netlist, top }`
//! - `pub fn readReferences(gpa: Allocator, netlist: ?Text, verilog: []const []const u8, devices: *const DeviceRecognition, strings: *StrTable, diag: *Diagnostic) Error!Read`
//! - `pub fn readReferenceText(gpa: Allocator, source: []const u8, spectre_by_name: bool, devices: *const DeviceRecognition, strings: *StrTable, diag: *Diagnostic) Error!Netlist`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const netlist_ = ingest.netlist;
const Netlist = netlist_.Netlist;
const SubcktId = netlist_.SubcktId;
const Error = netlist_.Error;
const Diagnostic = netlist_.Diagnostic;
const DeviceRecognition = ingest.deck.DeviceRecognition;

/// A SPICE or Spectre netlist's text, and whether its file was named as
/// Spectre (`.scs`, `.spectre`).
pub const Text = struct { text: []const u8, spectre_by_name: bool };

/// The netlist read and its top: with Verilog, the one module no other
/// places (unused library cells aside); without, the one subcircuit nothing
/// places. Null when that is not unique.
pub const Read = struct { netlist: Netlist, top: ?SubcktId };

/// Reads `netlist` (if any), then `verilog` over it.
pub fn readReferences(gpa: Allocator, netlist: ?Text, verilog: []const []const u8, devices: *const DeviceRecognition, strings: *StrTable, diag: *Diagnostic) Error!Read {
    var out: Netlist = if (netlist) |t| try readReferenceText(gpa, t.text, t.spectre_by_name, devices, strings, diag) else .{};
    errdefer out.deinit(gpa);
    if (verilog.len == 0) return .{ .netlist = out, .top = try out.top(gpa) };
    const modules = try netlist_.readVerilogInto(gpa, verilog, strings, &out, diag);
    return .{ .netlist = out, .top = try out.topIn(gpa, modules[0], modules[1]) };
}

/// Reads `source` in its opener's dialect, Spectre by name when it has none.
pub fn readReferenceText(gpa: Allocator, source: []const u8, spectre_by_name: bool, devices: *const DeviceRecognition, strings: *StrTable, diag: *Diagnostic) Error!Netlist {
    const spectre = spectreByOpener(source) orelse spectre_by_name;
    return if (spectre)
        netlist_.readSpectre(gpa, source, strings, devices, diag)
    else
        netlist_.readSpice(gpa, source, strings, devices, diag);
}

// ---- private ----

/// Whether the first subcircuit opener is Spectre's; null when none says.
fn spectreByOpener(source: []const u8) ?bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t\r\x0b\x0c");
        if (std.mem.startsWith(u8, line, "*") or std.mem.startsWith(u8, line, "//")) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r\x0b\x0c()");
        const head = tokens.next() orelse continue;
        if (std.mem.eql(u8, head, "subckt")) return true;
        if (std.ascii.eqlIgnoreCase(head, ".subckt")) return false;
    }
    return null;
}

test "the first subcircuit opener names the dialect, comments and other cards aside" {
    // Oracle: the Spectre and SPICE manuals' openers (`subckt`, `.subckt`),
    // hand-worked over four sources.
    try std.testing.expectEqual(true, spectreByOpener("// c\nsimulator lang=spectre\nsubckt inv (a y)\n"));
    try std.testing.expectEqual(false, spectreByOpener("* subckt in a comment\n.SUBCKT inv a y\n"));
    try std.testing.expectEqual(@as(?bool, null), spectreByOpener("M1 d g s b nch\n"));
    try std.testing.expectEqual(true, spectreByOpener("  subckt(x)\n.subckt y\n"));
}
