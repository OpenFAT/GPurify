//! DSPF 1.4, the parasitic network as a flat SPICE-like file for a
//! simulator. In: a canonical `ParasiticNetwork`, the names of its nets
//! (the labels, or a `Subckt`'s), the header, and with a `Subckt` its
//! devices. Out: the DSPF text; an unnamed net is refused. Ported from
//! src/export/parasitic.rs (`write_dspf`); the instance section is new.
//!
//! Ground net `0`. The header carries `*|DESIGN` (the layout path),
//! `*|DATE` only with a timestamp, `*|VERSION`, and the deck path as a
//! comment. Then per net `*|NET` with its total capacitance and one `*|S`
//! line per node, its layer standing in for a position the network does
//! not carry. Then every element as a card, `R`, `C`, `L` and `K` each
//! numbered from 1, capacitances in `f` and inductances in `p`; a `K` card
//! names the two `L` cards it couples and `k = M / √(L₁L₂)`.
//!
//! With a `Subckt` (`writeDspfSubckt`) the nets take its names, and the
//! devices are DSPF's instances: a node a device terminal sits on is
//! declared by one `*|I (node instance pin B 0 L<layer>)` line per terminal
//! in place of its `*|S`, the instance pin being that node (the closed
//! forms put no resistance between a terminal and the region it touches),
//! the pin `d`, `g`, `s`, `b` (MOS), `c`, `b`, `e`, `s` (BJT) or its
//! position from 1; and after the element cards, `* instance section` and
//! each device's card on the same node names (`XM1 out:3 inp:1 ...`).
//!
//! Contents:
//! - `pub fn writeDspf(w: *std.Io.Writer, gpa: Allocator, network: *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void`
//! - `pub fn writeDspfSubckt(w: *std.Io.Writer, gpa: Allocator, network: *const ParasiticNetwork, s: *const Subckt, head: *const Header, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom");
const StrTable = geom.StrTable;
const DeviceKind = @import("ingest").deck.DeviceKind;
const PortTable = @import("check").topology.PortTable;
const network_mod = @import("extract").network;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const float = geom.float;
const header = @import("header.zig");
const Header = header.Header;
const Error = header.Error;
const Diagnostic = header.Diagnostic;
const net = @import("network.zig");
const Names = net.Names;
const subckt = @import("subckt.zig");
const Subckt = subckt.Subckt;

/// Writes `network`, each net named by its label. Refused before the first
/// byte: what `writeSpef` refuses there, and a mutual inductance on a node
/// no inductance starts at or larger than its two inductances allow.
/// Refused while writing: an element on a node outside the network, an
/// unnamed net. `gpa` holds the names, totals, card numbers and couplings
/// until the write returns.
pub fn writeDspf(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void {
    const nets = network.node_net.items;
    try net.checkCanonical(network, diag);
    var start: usize = 0;
    while (start < nets.len) : (start = net.netRunEnd(nets, start)) try net.checkLabels(ports, @fromBackingInt(nets[start]), diag);
    const names = try gpa.alloc(?[]const u8, if (nets.len == 0) 0 else @as(usize, nets[nets.len - 1]) + 1);
    defer gpa.free(names);
    for (names, 0..) |*n, i| n.* = if (ports.nameOf(@fromBackingInt(@intCast(i)))) |id| strings.resolve(id) else null;
    return writeNamed(w, gpa, network, names, null, head, diag);
}

/// Writes `network` named as `s` names it, its devices DSPF's instances
/// (module doc); refused as `writeDspf` refuses, but for the labels.
pub fn writeDspfSubckt(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, s: *const Subckt, head: *const Header, diag: *Diagnostic) Error!void {
    try net.checkCanonical(network, diag);
    return writeNamed(w, gpa, network, s.net_name.items, s, head, diag);
}

// ---- private ----

/// The file, nets named by `net_name`, `s`'s devices as instances.
fn writeNamed(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, net_name: []const ?[]const u8, s: ?*const Subckt, head: *const Header, diag: *Diagnostic) Error!void {
    const nets = network.node_net.items;
    const names: Names = .{ .net_name = net_name, .spelling = .dspf };
    var couplings: std.ArrayList(?net.Coupling) = .empty;
    defer couplings.deinit(gpa);
    try net.mutualCouplingsInto(gpa, network, &couplings, diag);
    // Each node's terminals (device, card position), CSR, from `s`.
    const on_start = try gpa.alloc(u32, nets.len + 1);
    defer gpa.free(on_start);
    @memset(on_start, 0);
    var on: std.ArrayList([2]u32) = .empty;
    defer on.deinit(gpa);
    if (s) |c| try terminalsByNodeInto(gpa, c, on_start, &on);

    try w.print("*|DSPF \"1.4\"\n*|DESIGN \"{s}\"\n", .{head.layout_path});
    if (head.timestamp) |stamp| try w.print("*|DATE \"{s}\"\n", .{stamp});
    try w.print("*|VENDOR \"gpurify\"\n*|PROGRAM \"gpurify\"\n*|VERSION \"{s}\"\n* deck {s}\n", .{ head.tool_version, head.deck_path });
    try w.writeAll("*|DIVIDER /\n*|DELIMITER :\n*|GROUND_NET 0\n\n");

    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try network.capacitancePerNetInto(gpa, &totals);
    // Per-net declarations first, then the element cards.
    var node: usize = 0;
    while (node < nets.len) {
        const node_end = net.netRunEnd(nets, node);
        try w.writeAll("*|NET ");
        try net.writeNameAs(w, nets[node], names, diag);
        try w.writeByte(' ');
        try float.fixed6(w, totals.items[nets[node]]);
        try w.writeAll("f\n");
        for (node..node_end) |row| {
            const layer = @backingInt(network.node_layer.items[row]);
            const here = on.items[on_start[row]..on_start[row + 1]];
            if (here.len == 0) {
                try w.writeAll("*|S (");
                try net.writeNodeAs(w, network, .at(row), names, diag);
                try w.print(" L{d})\n", .{layer});
            }
            for (here) |t| {
                const c = s.?;
                try w.writeAll("*|I (");
                try net.writeNodeAs(w, network, .at(row), names, diag);
                try w.print(" {s} ", .{c.device_name.items[t[0]]});
                try writePin(w, c.device_kind.items[t[0]], t[1]);
                try w.print(" B 0 L{d})\n", .{layer});
            }
        }
        try w.writeByte('\n');
        node = node_end;
    }
    try net.writeElements(w, gpa, network, couplings.items, names, diag);
    const c = s orelse return;
    try w.writeAll("\n* instance section\n");
    for (0..c.deviceCount()) |d| try subckt.writeCard(w, network, c, d, names, diag);
}

/// The `(device, card position)` of every terminal on a node of the
/// network, bucketed by node: CSR into `start` (one longer than the
/// nodes, zeroed) and `out`, devices ascending within a node.
fn terminalsByNodeInto(gpa: Allocator, s: *const Subckt, start: []u32, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    for (s.terminal_node.items) |node| if (node != .ground) {
        std.debug.assert(@backingInt(node) + 1 < start.len);
        start[@backingInt(node) + 1] += 1;
    };
    for (1..start.len) |i| start[i] += start[i - 1];
    try out.resize(gpa, start[start.len - 1]);
    const next = try gpa.dupe(u32, start[0 .. start.len - 1]);
    defer gpa.free(next);
    for (0..s.deviceCount()) |d| {
        for (s.terminalsOf(d).nodes, 0..) |node, position| if (node != .ground) {
            const slot = &next[@backingInt(node)];
            out.items[slot.*] = .{ @intCast(d), @intCast(position) };
            slot.* += 1;
        };
    }
}

/// A terminal's pin name: `d g s b` on a MOS card, `c b e s` on a BJT's,
/// else its position from 1.
fn writePin(w: *Writer, kind: DeviceKind, position: u32) Writer.Error!void {
    const named: []const u8 = switch (kind) {
        .mos => "dgsb",
        .bjt => "cbes",
        .resistor, .capacitor, .diode, .inductor, .cell => "",
    };
    if (position < named.len) return w.writeByte(named[position]);
    try w.print("{d}", .{position + 1});
}
