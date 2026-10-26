//! SPEF (IEEE 1481-1998), the parasitic network for a timing tool. In: a
//! canonical `ParasiticNetwork` (or a nominal one and its process corners),
//! the ports that name its nets, the header. Out: the SPEF text; an
//! unnamed net is refused, not invented. Ported from
//! src/export/parasitic.rs (`write_spef`, `write_spef_corners`,
//! `write_spef_values`, `spef_section`).
//!
//! Units `1 FF`, `1 OHM` and `0.000001 UH` (one picohenry: the standard's
//! inductance units stop at `UH`). The header has every field `header_def`
//! requires, in its order, the deck path as a comment. Then one `*D_NET`
//! per net in ascending net order, with its total capacitance (coupling
//! included), one bidirectional `*CONN` port, and `*CAP`, `*RES` and
//! `*INDUC` sections, node `i` of a net named `net:i`. A coupling
//! capacitance is listed in both nets' `*CAP`, each net's node first, as
//! OpenSTA's reader (`SpefReader::makeCapacitor`) needs. A mutual
//! inductance, which the standard lacks, is a comment in the first net's
//! block, `// mutual <node> <node> <pH>`; so is a substrate resistance,
//! `// substrate <node> <node | 0> <Ω>`. With corners, every value is a
//! `min:typ:max` triplet (envelope.zig).
//!
//! Contents:
//! - `pub fn writeSpef(w: *std.Io.Writer, gpa: Allocator, network: *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void`
//! - `pub fn writeSpefCorners(w: *std.Io.Writer, gpa: Allocator, nominal: *const ParasiticNetwork, corners: []const *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const geom = @import("geom");
const StrTable = geom.StrTable;
const PortTable = @import("check").topology.PortTable;
const network_mod = @import("extract").network;
const Kind = network_mod.Kind;
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const float = geom.float;
const header = @import("header.zig");
const Header = header.Header;
const Error = header.Error;
const Diagnostic = header.Diagnostic;
const net = @import("network.zig");
const envelopeInto = @import("envelope.zig").envelopeInto;

/// One `*D_NET` block's three element sections.
const Section = enum { cap, res, induc };

/// What every line of one write names nodes through; `values[0]` gives the
/// nodes and elements, and each value goes out once per network.
const Ctx = struct {
    w: *Writer,
    values: []const *const ParasiticNetwork,
    ports: *const PortTable,
    strings: *const StrTable,
    diag: *Diagnostic,
};

/// Writes `network`. Refused before the first byte: a network out of
/// canonical order, a resistance or inductance with no far node, a NaN or
/// infinite value (`Unrepresentable`); a split or shorted label. Refused
/// while writing: an element on a node outside the network, an unnamed
/// net. `gpa` holds the per-net totals until the write returns.
pub fn writeSpef(w: *Writer, gpa: Allocator, network: *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void {
    try net.checkCanonical(network, diag);
    try writeValues(.{ .w = w, .values = &.{network}, .ports = ports, .strings = strings, .diag = diag }, gpa, head);
}

/// Writes `nominal` with every value the triplet `min:typ:max` over it and
/// `corners`: each slot's smallest value, the nominal's, the largest
/// (envelope.zig). Without corners, `writeSpef` byte for byte. Refuses as
/// `writeSpef` for any network, and corners whose nodes differ or that
/// lack a resistance or inductance another has.
pub fn writeSpefCorners(w: *Writer, gpa: Allocator, nominal: *const ParasiticNetwork, corners: []const *const ParasiticNetwork, ports: *const PortTable, strings: *const StrTable, head: *const Header, diag: *Diagnostic) Error!void {
    try net.checkCanonical(nominal, diag);
    if (corners.len == 0) return writeValues(.{ .w = w, .values = &.{nominal}, .ports = ports, .strings = strings, .diag = diag }, gpa, head);
    for (corners) |corner| {
        try net.checkCanonical(corner, diag);
        if (!std.mem.eql(u32, corner.node_net.items, nominal.node_net.items)) {
            diag.what = "process corners whose networks have different nodes";
            return error.Unrepresentable;
        }
    }
    var three: [3]ParasiticNetwork = @splat(.empty);
    defer for (&three) |*n| n.deinit(gpa);
    try envelopeInto(gpa, nominal, corners, &three, diag);
    try writeValues(.{ .w = w, .values = &.{ &three[0], &three[1], &three[2] }, .ports = ports, .strings = strings, .diag = diag }, gpa, head);
}

// ---- private ----

/// The file over `c.values`, each canonical and aligned element for element.
fn writeValues(c: Ctx, gpa: Allocator, head: *const Header) Error!void {
    const network = c.values[0];
    const nets = network.node_net.items;
    assert(c.values.len <= 3);
    for (c.values) |aligned| assert(std.mem.eql(Kind, aligned.kind.items, network.kind.items));
    var start: usize = 0;
    while (start < nets.len) : (start = net.netRunEnd(nets, start)) try net.checkLabels(c.ports, @fromBackingInt(nets[start]), c.diag);

    const w = c.w;
    try w.print("*SPEF \"IEEE 1481-1998\"\n*DESIGN \"{s}\"\n*DATE \"{s}\"\n", .{ head.layout_path, head.timestamp orelse "" });
    try w.print("*VENDOR \"gpurify\"\n*PROGRAM \"gpurify\"\n*VERSION \"{s}\"\n// deck {s}\n", .{ head.tool_version, head.deck_path });
    try w.writeAll("*DESIGN_FLOW \"EXTRACTED\"\n*DIVIDER /\n*DELIMITER :\n*BUS_DELIMITER [ ]\n" ++
        "*T_UNIT 1 NS\n*C_UNIT 1 FF\n*R_UNIT 1 OHM\n*L_UNIT 0.000001 UH\n\n");

    var totals: [3]std.ArrayList(f64) = @splat(.empty);
    defer for (&totals) |*t| t.deinit(gpa);
    for (c.values, totals[0..c.values.len]) |aligned, *t| try aligned.capacitancePerNetInto(gpa, t);
    // Each coupling between two nets by its far node's net, so that net's
    // section lists it too, as `far_net << 32 | row`, ascending.
    var incoming: std.ArrayList(u64) = .empty;
    defer incoming.deinit(gpa);
    for (network.kind.items, network.from.items, network.to.items, 0..) |kind, from, to, row| {
        if (kind != .coupling_cap) continue;
        const near = try net.nodePlace(network, from, c.diag);
        const far = try net.nodePlace(network, to, c.diag);
        if (far.net != near.net) try incoming.append(gpa, @as(u64, far.net) << 32 | row);
    }
    std.mem.sortUnstable(u64, incoming.items, {}, std.sort.asc(u64));

    // One `*D_NET` per run of nodes; two cursors, sound after checkCanonical.
    var element: usize = 0;
    var mirror: usize = 0;
    var node: usize = 0;
    while (node < nets.len) {
        const node_end = net.netRunEnd(nets, node);
        const id = nets[node];
        try w.writeAll("*D_NET ");
        try net.writeNetName(w, id, c.ports, c.strings, c.diag);
        try w.writeByte(' ');
        for (totals[0..c.values.len], 0..) |t, k| {
            if (k > 0) try w.writeByte(':');
            try float.fixed6(w, t.items[id]);
        }
        // No per-terminal direction is known, so one bidirectional port.
        try w.writeAll("\n*CONN\n*P ");
        try net.writeNetName(w, id, c.ports, c.strings, c.diag);
        try w.writeAll(" B\n");

        var element_end = element;
        while (element_end < network.elementCount() and @backingInt(network.from.items[element_end]) < node_end) element_end += 1;
        var mirror_end = mirror;
        while (mirror_end < incoming.items.len and incoming.items[mirror_end] >> 32 <= id) mirror_end += 1;

        try section(c, element, element_end, incoming.items[mirror..mirror_end], .cap);
        try section(c, element, element_end, &.{}, .res);
        try section(c, element, element_end, &.{}, .induc);
        // IEEE 1481 has no mutual inductance, nor a resistor between two
        // nets or to ground: comments keep both in the file.
        for (element..element_end) |row| if (network.kind.items[row] == .mutual_inductance) {
            try w.writeAll("// mutual ");
            try elementLine(c, row, .from_first);
        };
        for (element..element_end) |row| if (network.kind.items[row] == .substrate_resistance) {
            try w.writeAll("// substrate ");
            try elementLine(c, row, .from_first);
        };
        try w.writeAll("*END\n\n");
        node = node_end;
        element = element_end;
        mirror = mirror_end;
    }
    // A row no net claimed points outside the node columns.
    if (element != network.elementCount()) {
        c.diag.what = "a parasitic element on a node outside the network";
        return error.Unrepresentable;
    }
}

/// One numbered section over rows `[lo, hi)` of its kinds, then `mirrored`
/// (`far_net << 32 | row`), other nets' couplings onto this one.
fn section(c: Ctx, lo: usize, hi: usize, mirrored: []const u64, which: Section) Error!void {
    const network = c.values[0];
    try c.w.writeAll(switch (which) {
        .cap => "*CAP\n",
        .res => "*RES\n",
        .induc => "*INDUC\n",
    });
    var index: u32 = 1;
    for (lo..hi) |row| {
        const in: ?Section = switch (network.kind.items[row]) {
            .ground_cap, .coupling_cap => .cap,
            .resistance => .res,
            .inductance => .induc,
            .mutual_inductance, .substrate_resistance => null,
        };
        if (in != which) continue;
        try c.w.print("{d} ", .{index});
        try elementLine(c, row, .from_first);
        index += 1;
    }
    for (mirrored) |entry| {
        try c.w.print("{d} ", .{index});
        try elementLine(c, @as(u32, @truncate(entry)), .far_first);
        index += 1;
    }
}

/// `<node> [<node> | 0] <values>\n` for element `row`. A missing far node is
/// omitted on a capacitance, `0` (ground) on a substrate resistance, and
/// refused on anything else.
fn elementLine(c: Ctx, row: usize, order: enum { from_first, far_first }) Error!void {
    const network = c.values[0];
    const from = network.from.items[row];
    const to = network.to.items[row];
    const first, const second = switch (order) {
        .from_first => .{ from, to },
        .far_first => .{ to, from },
    };
    try net.writeNodeName(c.w, network, first, c.ports, c.strings, c.diag);
    if (second != .ground) {
        try c.w.writeByte(' ');
        try net.writeNodeName(c.w, network, second, c.ports, c.strings, c.diag);
    } else switch (network.kind.items[row]) {
        .ground_cap, .coupling_cap => {},
        .substrate_resistance => try c.w.writeAll(" 0"),
        .resistance, .inductance, .mutual_inductance => {
            c.diag.what = "a resistance or inductance with no far node";
            return error.Unrepresentable;
        },
    }
    try c.w.writeByte(' ');
    for (c.values, 0..) |aligned, k| {
        if (k > 0) try c.w.writeByte(':');
        try float.fixed6(c.w, aligned.value.items[row]);
    }
    try c.w.writeByte('\n');
}
