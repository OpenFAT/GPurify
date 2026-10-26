//! DSPF 1.4, the parasitic network as a flat SPICE-like file for a
//! simulator. In: a canonical `ParasiticNetwork`, the ports that name its
//! nets, the header. Out: the DSPF text; an unnamed net is refused. Ported
//! from src/export/parasitic.rs (`write_dspf`).
//!
//! Ground net `0`. The header carries `*|DESIGN` (the layout path),
//! `*|DATE` only with a timestamp, `*|VERSION`, and the deck path as a
//! comment. Then per net `*|NET` with its total capacitance and one `*|S`
//! line per node, its layer standing in for a position the network does
//! not carry. Then every element as a card, `R`, `C`, `L` and `K` each
//! numbered from 1, capacitances in `f` and inductances in `p`; a `K` card
//! names the two `L` cards it couples and `k = M / √(L₁L₂)`.
//!
//! Contents:
//! - `pub fn writeDspf(w: *std.Io.Writer, gpa: Allocator, network: *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom");
const StrTable = geom.StrTable;
const PortTable = @import("check").topology.PortTable;
const network_mod = @import("extract").network;
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const float = @import("float.zig");
const header = @import("header.zig");
const Header = header.Header;
const Error = header.Error;
const Diagnostic = header.Diagnostic;
const net = @import("network.zig");

/// Writes `network`. Refused before the first byte: what `writeSpef`
/// refuses there, and a mutual inductance on a node no inductance starts
/// at or larger than its two inductances allow. Refused while writing: an
/// element on a node outside the network, an unnamed net. `gpa` holds the
/// totals, card numbers and couplings until the write returns.
pub fn writeDspf(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void {
    const nets = network.node_net.items;
    try net.checkCanonical(network, diag);
    var start: usize = 0;
    while (start < nets.len) : (start = net.netRunEnd(nets, start)) try net.checkLabels(ports, @fromBackingInt(nets[start]), diag);
    var couplings: std.ArrayList(?net.Coupling) = .empty;
    defer couplings.deinit(gpa);
    try net.mutualCouplingsInto(gpa, network, &couplings, diag);

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
        try net.writeNetName(w, nets[node], ports, strings, diag);
        try w.writeByte(' ');
        try float.fixed6(w, totals.items[nets[node]]);
        try w.writeAll("f\n");
        for (node..node_end) |row| {
            try w.writeAll("*|S (");
            try net.writeNodeName(w, network, .at(row), ports, strings, diag);
            try w.print(" L{d})\n", .{@backingInt(network.node_layer.items[row])});
        }
        try w.writeByte('\n');
        node = node_end;
    }
    // Numbered per letter, so `R1` and `C1` are two cards, and numbered
    // first, so a `K` card can name an `L` card written after it.
    const number = try gpa.alloc(u32, network.elementCount());
    defer gpa.free(number);
    var next: [4]u32 = @splat(1);
    for (network.kind.items, number) |kind, *n| {
        const slot = net.card(kind).slot;
        n.* = next[slot];
        next[slot] += 1;
    }
    for (0..network.elementCount()) |row| {
        if (couplings.items[row]) |k| {
            try w.print("K{d} L{d} L{d} ", .{ number[row], number[k.a], number[k.b] });
            try float.fixed6(w, k.k);
            try w.writeByte('\n');
            continue;
        }
        const c = net.card(network.kind.items[row]);
        try w.print("{c}{d} ", .{ c.letter, number[row] });
        try net.writeNodeName(w, network, network.from.items[row], ports, strings, diag);
        // A missing far end is ground; checkCanonical allows it only on a
        // capacitance or a substrate resistance.
        const to = network.to.items[row];
        if (to == .ground) try w.writeAll(" 0") else {
            try w.writeByte(' ');
            try net.writeNodeName(w, network, to, ports, strings, diag);
        }
        try w.writeByte(' ');
        try float.fixed6(w, network.value.items[row]);
        try w.print("{s}\n", .{c.suffix});
    }
}
