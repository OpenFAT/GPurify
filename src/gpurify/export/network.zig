//! What the SPEF, DSPF and SPICE writers read off a parasitic network
//! before and while they write it: the refusals checked up front, where a
//! node sits, how an element is carded, which inductances a mutual one
//! couples, and the names nets and nodes go out under. Ported from
//! src/export/{mod,parasitic}.rs (`check_labels_one_to_one`,
//! `check_canonical`, `check_finite`, `node_place`, `spice_card`,
//! `mutual_couplings`, `node_name`, `put_net_name`).
//!
//! Names are escaped once on write (IEEE 1481-1998 §B.2: `\` before every
//! special character), so extract's readers, which unescape once, read the
//! label back. The divider `/` and bus delimiters `[` `]` the header
//! declares are pathname syntax and stay bare; a name holding whitespace
//! or a control byte has no escape a reader splitting on blanks can undo,
//! so it is refused. Rust wrote names raw.
//!
//! Contents:
//! - `pub const Card = struct { letter: u8, slot: u2, suffix: []const u8 }`, `pub fn card(kind: Kind) Card`
//! - `pub const Coupling = struct { a: u32, b: u32, k: f64 }`
//! - `pub fn checkLabels(ports: *const PortTable, net: NetId, diag: *Diagnostic) Error!void`
//! - `pub fn checkCanonical(network: *const ParasiticNetwork, diag: *Diagnostic) Error!void`
//! - `pub fn checkFinite(network: *const ParasiticNetwork, diag: *Diagnostic) Error!void`
//! - `pub fn mutualCouplingsInto(gpa: Allocator, network: *const ParasiticNetwork, out: *std.ArrayList(?Coupling), diag: *Diagnostic) Error!void`
//! - `pub fn nodePlace(network: *const ParasiticNetwork, node: NodeId, diag: *Diagnostic) Error!struct { net: u32, index: u32 }`
//! - `pub fn netRunEnd(node_net: []const u32, start: usize) usize`
//! - `pub fn writeNodeName(w: *std.Io.Writer, network: *const ParasiticNetwork, node: NodeId, ports: *const PortTable, strings: *const StrTable, diag: *Diagnostic) Error!void`
//! - `pub fn writeNetName(w: *std.Io.Writer, net: u32, ports: *const PortTable, strings: *const StrTable, diag: *Diagnostic) Error!void`
//! - `pub const Spelling = enum { dspf, spice }`, `pub const Names = struct { net_name, spelling, pin_node }`
//! - `pub fn writeNodeAs(w: *std.Io.Writer, network: *const ParasiticNetwork, node: NodeId, names: Names, diag: *Diagnostic) Error!void`
//! - `pub fn writeNameAs(w: *std.Io.Writer, net: u32, names: Names, diag: *Diagnostic) Error!void`
//! - `pub fn checkSpiceName(text: []const u8, diag: *Diagnostic) Error!void`
//! - `pub fn writeElements(w: *std.Io.Writer, gpa: Allocator, network: *const ParasiticNetwork, couplings: []const ?Coupling, names: Names, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const geom = @import("geom");
const StrTable = geom.StrTable;
const topology = @import("check").topology;
const NetId = topology.NetId;
const PortTable = topology.PortTable;
const network_mod = @import("extract").network;
const Kind = network_mod.Kind;
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const float = geom.float;
const header = @import("header.zig");
const Error = header.Error;
const Diagnostic = header.Diagnostic;

/// A SPICE card's prefix letter, its counter slot (DSPF numbers each letter
/// apart) and unit suffix: SPICE reads a bare number as SI, so fF carries
/// `f` and pH `p`. A mutual inductance's `K` card states its coefficient.
pub const Card = struct { letter: u8, slot: u2, suffix: []const u8 };

/// A mutual inductance as a `K` card states it: the rows of the two series
/// inductances it couples, and `k = M / √(L_a L_b)`.
pub const Coupling = struct { a: u32, b: u32, k: f64 };

/// How a writer spells a node.
pub const Spelling = enum {
    /// `net:index`, every name escaped as SPEF escapes it.
    dspf,
    /// The net's bare name on its pin node, `net#index` on any other; a
    /// name a SPICE card cannot carry is refused.
    spice,
};

/// The names a writer gives nodes, by layout net: its name (null: none, so
/// `UnnamedNet`) and, spelling SPICE, its pin node (`.ground`: none).
pub const Names = struct {
    net_name: []const ?[]const u8,
    spelling: Spelling,
    pin_node: []const NodeId = &.{},
};

pub fn card(kind: Kind) Card {
    return switch (kind) {
        .resistance, .substrate_resistance => .{ .letter = 'R', .slot = 0, .suffix = "" },
        .ground_cap, .coupling_cap => .{ .letter = 'C', .slot = 1, .suffix = "f" },
        .inductance => .{ .letter = 'L', .slot = 2, .suffix = "p" },
        .mutual_inductance => .{ .letter = 'K', .slot = 3, .suffix = "" },
    };
}

/// Refuses `net` unless it carries at most its own one label: several
/// labels are a short (`ShortedLabels`), and a label also on another net
/// is an open (`SplitLabel`).
pub fn checkLabels(ports: *const PortTable, net: NetId, diag: *Diagnostic) Error!void {
    const names = ports.namesOf(net);
    if (names.len > 1) {
        diag.labels = names;
        return error.ShortedLabels;
    }
    if (names.len == 1 and ports.netOf(names[0]) != net) {
        diag.labels = names;
        return error.SplitLabel;
    }
}

/// Refuses a network not in the order the writers read it: nodes grouped
/// by ascending net, elements by ascending `from`; then a far node missing
/// from anything but a capacitance or substrate resistance; then
/// `checkFinite`. Checked in every build mode, since an out-of-order
/// network writes a plausible description of the wrong circuit.
pub fn checkCanonical(network: *const ParasiticNetwork, diag: *Diagnostic) Error!void {
    if (!std.sort.isSorted(u32, network.node_net.items, {}, std.sort.asc(u32)))
        return refuse(diag, "a parasitic network whose nodes are not grouped by net");
    const from = network.from.items;
    for (1..from.len) |i| if (@backingInt(from[i - 1]) > @backingInt(from[i]))
        return refuse(diag, "a parasitic network whose elements are not in canonical order");
    for (network.to.items, network.kind.items) |to, kind| {
        const may_ground = switch (kind) {
            .ground_cap, .coupling_cap, .substrate_resistance => true,
            .resistance, .inductance, .mutual_inductance => false,
        };
        if (to == .ground and !may_ground) return refuse(diag, "a resistance or inductance with no far node");
    }
    return checkFinite(network, diag);
}

/// Refuses a NaN or infinite element: it prints as a number no reader
/// parses, or one no simulator should believe.
pub fn checkFinite(network: *const ParasiticNetwork, diag: *Diagnostic) Error!void {
    for (network.value.items) |v| if (!std.math.isFinite(v)) return refuse(diag, "a non-finite parasitic value");
}

/// Each element's `Coupling` into `out` (cleared), null for all but a
/// mutual inductance. Refuses one on a node no inductance starts at, or
/// whose `|k|` is not at most 1 (NaN included): no passive pair is.
pub fn mutualCouplingsInto(gpa: Allocator, network: *const ParasiticNetwork, out: *std.ArrayList(?Coupling), diag: *Diagnostic) Error!void {
    const inductor = try gpa.alloc(?u32, network.nodeCount());
    defer gpa.free(inductor);
    @memset(inductor, null);
    for (network.kind.items, network.from.items, 0..) |kind, from, row| {
        if (kind != .inductance) continue;
        const i = @backingInt(from);
        if (i < inductor.len and inductor[i] == null) inductor[i] = @intCast(row);
    }
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(gpa, network.elementCount());
    for (network.kind.items, network.from.items, network.to.items, network.value.items) |kind, from, to, mutual| {
        if (kind != .mutual_inductance) {
            out.appendAssumeCapacity(null);
            continue;
        }
        const a = inductorAt(inductor, from) orelse return refuse(diag, "a mutual inductance on a node no inductance starts at");
        const b = inductorAt(inductor, to) orelse return refuse(diag, "a mutual inductance on a node no inductance starts at");
        const k = mutual / @sqrt(network.value.items[a] * network.value.items[b]);
        if (!(@abs(k) <= 1.0)) return refuse(diag, "a mutual inductance larger than the two inductances it couples allow");
        out.appendAssumeCapacity(.{ .a = a, .b = b, .k = k });
    }
}

/// The net `node` sits on, and its index within that net's run of nodes.
pub fn nodePlace(network: *const ParasiticNetwork, node: NodeId, diag: *Diagnostic) Error!struct { net: u32, index: u32 } {
    const nets = network.node_net.items;
    const row = @backingInt(node);
    if (row >= nets.len) return refuse(diag, "a parasitic element on a node outside the network");
    const first = std.sort.lowerBound(u32, nets, nets[row], orderU32);
    return .{ .net = nets[row], .index = @intCast(row - first) };
}

/// The end of the run of nodes that starts at `start`, all on one net.
pub fn netRunEnd(node_net: []const u32, start: usize) usize {
    var end = start + 1;
    while (end < node_net.len and node_net[end] == node_net[start]) end += 1;
    return end;
}

/// `net:index`, the name SPEF and DSPF give a node.
pub fn writeNodeName(w: *Writer, network: *const ParasiticNetwork, node: NodeId, ports: *const PortTable, strings: *const StrTable, diag: *Diagnostic) Error!void {
    const place = try nodePlace(network, node, diag);
    try writeNetName(w, place.net, ports, strings, diag);
    try w.print(":{d}", .{place.index});
}

/// A net's label, escaped; `UnnamedNet` for a net without one.
pub fn writeNetName(w: *Writer, net: u32, ports: *const PortTable, strings: *const StrTable, diag: *Diagnostic) Error!void {
    const name = ports.nameOf(@fromBackingInt(net)) orelse {
        diag.net = net;
        return error.UnnamedNet;
    };
    try writeEscaped(w, strings.resolve(name), diag);
}

/// `node` as `names` spells it.
pub fn writeNodeAs(w: *Writer, network: *const ParasiticNetwork, node: NodeId, names: Names, diag: *Diagnostic) Error!void {
    const place = try nodePlace(network, node, diag);
    try writeNameAs(w, place.net, names, diag);
    switch (names.spelling) {
        .dspf => try w.print(":{d}", .{place.index}),
        .spice => if (names.pin_node[place.net] != node) try w.print("#{d}", .{place.index}),
    }
}

/// Net `net`'s name as `names` spells it; `UnnamedNet` for none, and
/// SPICE's refusal of a name `checkSpiceName` refuses.
pub fn writeNameAs(w: *Writer, net: u32, names: Names, diag: *Diagnostic) Error!void {
    const text = (if (net < names.net_name.len) names.net_name[net] else null) orelse {
        diag.net = net;
        return error.UnnamedNet;
    };
    switch (names.spelling) {
        .dspf => try writeEscaped(w, text, diag),
        .spice => {
            try checkSpiceName(text, diag);
            try w.writeAll(text);
        },
    }
}

/// Refuses a name a SPICE card would read as syntax: empty, or holding a
/// blank, a control byte, `=`, `,`, a quote, a parenthesis or `#` (the node
/// suffix, so `out#3` cannot be another net's name).
pub fn checkSpiceName(text: []const u8, diag: *Diagnostic) Error!void {
    if (text.len == 0) return refuse(diag, "an empty name");
    for (text) |c| if (c <= ' ' or c == 0x7f or std.mem.findScalar(u8, "=,'\"()#", c) != null)
        return refuse(diag, "a name holding a character a SPICE card reads as syntax");
}

/// Every element as a card, `R`, `C`, `L` and `K` each numbered from 1,
/// capacitances in `f` and inductances in `p`, a missing far end `0`; a
/// `K` card names the two `L` cards `couplings` gives it and `k`. Numbered
/// before writing, so a `K` card can name an `L` card written after it.
/// `gpa` holds the numbers until it returns.
pub fn writeElements(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, couplings: []const ?Coupling, names: Names, diag: *Diagnostic) Error!void {
    const number = try gpa.alloc(u32, network.elementCount());
    defer gpa.free(number);
    var next: [4]u32 = @splat(1);
    for (network.kind.items, number) |kind, *n| {
        const slot = card(kind).slot;
        n.* = next[slot];
        next[slot] += 1;
    }
    for (0..network.elementCount()) |row| {
        if (couplings[row]) |k| {
            try w.print("K{d} L{d} L{d} ", .{ number[row], number[k.a], number[k.b] });
            try float.fixed6(w, k.k);
            try w.writeByte('\n');
            continue;
        }
        const c = card(network.kind.items[row]);
        try w.print("{c}{d} ", .{ c.letter, number[row] });
        try writeNodeAs(w, network, network.from.items[row], names, diag);
        // A missing far end is ground; checkCanonical allows it only on a
        // capacitance or a substrate resistance.
        const to = network.to.items[row];
        if (to == .ground) try w.writeAll(" 0") else {
            try w.writeByte(' ');
            try writeNodeAs(w, network, to, names, diag);
        }
        try w.writeByte(' ');
        try float.fixed6(w, network.value.items[row]);
        try w.print("{s}\n", .{c.suffix});
    }
}

// ---- private ----

/// `text` escaped once (module doc); a blank or control byte refused.
fn writeEscaped(w: *Writer, text: []const u8, diag: *Diagnostic) Error!void {
    for (text) |c| if (c <= ' ' or c == 0x7f) return refuse(diag, "a net name holding whitespace or a control character");
    for (text) |c| {
        const bare = std.ascii.isAlphanumeric(c) or c >= 0x80 or switch (c) {
            '_', '/', '[', ']' => true,
            else => false,
        };
        if (!bare) try w.writeByte('\\');
        try w.writeByte(c);
    }
}

fn refuse(diag: *Diagnostic, what: []const u8) error{Unrepresentable} {
    diag.what = what;
    return error.Unrepresentable;
}

fn inductorAt(inductor: []const ?u32, node: NodeId) ?u32 {
    const i = @backingInt(node);
    return if (i < inductor.len) inductor[i] else null;
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}
