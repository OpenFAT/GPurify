//! The extracted circuit as a simulator's `.subckt`: devices on the
//! parasitic network's nodes, pins in order, and the network's elements.
//! In: a canonical `ParasiticNetwork`, the `Subckt` naming it, the header
//! and the corner it is. Out: the netlist text, which ESPice, ngspice, or
//! Spectre under `simulator lang=spice` reads. Replaces the port of
//! src/export/netlist.rs, which wrote `TOP` in database units with every
//! terminal on its net's first node.
//!
//! A comment line names the run (`pex: <layout>, deck <deck>, reference
//! <netlist>, corner <name>`), another the unit of every size (the deck's
//! `netlist_scale`, which a bench's `.option scale` must match, or the
//! metre). Then `.subckt <name> <pins>`, each pin its net's name; each
//! device's card, its terminals in card order on their nodes, its model
//! and sizes; every element as DSPF carries it (`R`, `C`, `L`, `K` each
//! numbered from 1, `f` and `p` suffixes); `.ends <name>`. A node is its
//! net's name on the net's pin node and `net#index` on any other, `index`
//! its place among the net's nodes as DSPF's `net:index` counts it; a
//! terminal on a net with no node is the net's bare name.
//!
//! Contents:
//! - `pub fn writeSpice(w: *std.Io.Writer, gpa: Allocator, network: *const ParasiticNetwork, s: *const Subckt, corner: []const u8, head: *const Header, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom");
const float = geom.float;
const ParasiticNetwork = @import("extract").network.ParasiticNetwork;
const header = @import("header.zig");
const Header = header.Header;
const Error = header.Error;
const Diagnostic = header.Diagnostic;
const net = @import("network.zig");
const Names = net.Names;
const subckt = @import("subckt.zig");
const Subckt = subckt.Subckt;

/// Writes `s` over `network`, `corner`'s extraction. Refused before the
/// first byte: what `writeDspf` refuses there, a subcircuit name a card
/// cannot carry. Refused while writing: a
/// pin, terminal or element on a net with no name, a name a card cannot
/// carry (`network.writeNameAs`). `gpa` holds the card numbers and
/// couplings until the write returns.
pub fn writeSpice(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, s: *const Subckt, corner: []const u8, head: *const Header, diag: *Diagnostic) Error!void {
    try net.checkCanonical(network, diag);
    try net.checkSpiceName(s.name, diag);
    var couplings: std.ArrayList(?net.Coupling) = .empty;
    defer couplings.deinit(gpa);
    try net.mutualCouplingsInto(gpa, network, &couplings, diag);
    const names: Names = .{ .net_name = s.net_name.items, .spelling = .spice, .pin_node = s.pin_node.items };

    try w.print("* {s} pex: {s}, deck {s}, ", .{ head.tool_version, head.layout_path, head.deck_path });
    if (head.reference_path) |path| try w.print("reference {s}", .{path}) else try w.writeAll("no reference, so devices are named by layout index and cannot be back-annotated");
    try w.print(", corner {s}\n", .{corner});
    if (head.timestamp) |stamp| try w.print("* written: {s}\n", .{stamp});
    // A bench that reads sizes in another unit simulates other devices.
    try w.writeAll("* sizes in units of ");
    try float.debug(w, s.unit_nm / 1e9);
    try w.writeAll(" m: a bench's .option scale must say the same\n");
    try w.print(".subckt {s}", .{s.name});
    for (s.pin_net.items) |pin| {
        try w.writeByte(' ');
        try net.writeNameAs(w, pin, names, diag);
    }
    try w.writeByte('\n');
    for (0..s.deviceCount()) |d| try subckt.writeCard(w, network, s, d, names, diag);
    try net.writeElements(w, gpa, network, couplings.items, names, diag);
    try w.print(".ends {s}\n", .{s.name});
}
