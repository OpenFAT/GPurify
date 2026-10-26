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
    const text = strings.resolve(name);
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

// ---- private ----

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
