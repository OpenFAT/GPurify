//! Another tool's parasitic netlist as a `ParasiticNetwork`, the part both
//! readers share. In: the nets, node declarations and elements a SPEF
//! (spef.zig) or DSPF (dspf.zig) reader collected, names unescaped once.
//! Out: a `Read`, the net names ascending and the network on them (net `i`
//! is name `i`), in fF, Ω and pH. Ported from crates/extract/src/foreign.rs.
//!
//! A node belongs to the net that declares it, else to the net its prefix
//! names (`net:3` is `net`'s), else to the net whose resistor or first
//! capacitor terminal it is. A net's first node is its driver: its first
//! declared driving node, else the first node an element names. A coupling
//! listed once in each of its two nets' sections is one capacitor; listed
//! twice within one section, it is two.
//!
//! Contents:
//! - `pub const Error = error{ Unsupported, SectionBeforeNet, OrphanNode, BadNumber, UnknownUnit, Malformed, DuplicateNet, NoNets, ElementToGround, TooManyNodes } || Allocator.Error`
//! - `pub const Diagnostic = struct { line: u32, token: []const u8 }`
//! - `pub const Read = struct`, `Read.empty`, `deinit`, `nameCount`, `name(r: *const Read, net: u32) []const u8`,
//!   `onNamesInto(r: *const Read, gpa: Allocator, names: []const []const u8, out: *ParasiticNetwork) Allocator.Error!void`
//! - `pub const Kind = enum { cap, res, ind }`, `pub const Collect = struct`, `Collect.init`, `deinit`, `net`, `declare`, `element`, `build`
//! - `pub fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8`
//! - `pub fn number(text: []const u8) ?f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;

/// Why a parasitic netlist could not be read; `Diagnostic` says where.
pub const Error = error{
    /// A construct not read: `*R_NET`, `*D_PNET`, `*R_PNET`, `*DEFINE`, `*PDEFINE`.
    Unsupported,
    /// A `*CONN`, `*CAP`, `*RES` or `*INDUC` section (DSPF: a node
    /// declaration) before any net.
    SectionBeforeNet,
    /// A node no net declares, no element of its own net names, and whose
    /// name before the delimiter is no net's.
    OrphanNode,
    /// A value that is not a finite number or `min:typ:max` triplet.
    BadNumber,
    /// A `*C_UNIT`, `*R_UNIT` or `*L_UNIT` of an unknown unit.
    UnknownUnit,
    /// A line of the wrong shape for where it stands.
    Malformed,
    /// A net listed twice.
    DuplicateNet,
    /// No `*D_NET` (DSPF: `*|NET`) in the file.
    NoNets,
    /// A resistance or inductance with one node, or to ground.
    ElementToGround,
    /// More nodes than a `NodeId` holds.
    TooManyNodes,
} || Allocator.Error;

/// Where a read failed: the 1-based line (0 for the file as a whole) and
/// the token at fault, a slice of the input or of the read's own names.
pub const Diagnostic = struct { line: u32 = 0, token: []const u8 = "" };

/// A parasitic netlist as read. Net `i`'s name is
/// `name_bytes[name_start[i]..name_start[i + 1]]`, names ascending, escapes
/// removed; every net's driver is its first node; the network is canonical.
pub const Read = struct {
    name_bytes: std.ArrayList(u8) = .empty,
    name_start: std.ArrayList(u32) = .empty,
    network: ParasiticNetwork = .empty,

    pub const empty: Read = .{};

    pub fn deinit(r: *Read, gpa: Allocator) void {
        r.name_bytes.deinit(gpa);
        r.name_start.deinit(gpa);
        r.network.deinit(gpa);
    }

    pub fn nameCount(r: *const Read) u32 {
        return @intCast(r.name_start.items.len -| 1);
    }

    pub fn name(r: *const Read, net: u32) []const u8 {
        return r.name_bytes.items[r.name_start.items[net]..r.name_start.items[net + 1]];
    }

    /// The network into `out` (overwritten) with its nets renumbered onto
    /// `names`, a sorted list holding every name of this file (the union of
    /// two files' names, so their networks share net ids). Nodes keep their
    /// order. Asserts `names` is sorted and holds every name.
    pub fn onNamesInto(r: *const Read, gpa: Allocator, names: []const []const u8, out: *ParasiticNetwork) Allocator.Error!void {
        for (1..names.len) |i| assert(std.mem.order(u8, names[i - 1], names[i]) == .lt);
        out.clear();
        inline for (.{ "node_layer", "from", "to", "kind", "value" }) |f| try @field(out, f).appendSlice(gpa, @field(r.network, f).items);
        try out.node_net.ensureTotalCapacity(gpa, r.network.node_net.items.len);
        for (r.network.node_net.items) |net| {
            const at = std.sort.binarySearch([]const u8, names, r.name(net), orderStr) orelse unreachable;
            out.node_net.appendAssumeCapacity(@intCast(at));
        }
    }
};

/// An element's kind as read, before its nodes are placed.
pub const Kind = enum { cap, res, ind };

/// What a reader collects before the network is built. Every name lives in
/// `arena`, the read's scratch, freed when the read ends.
pub const Collect = struct {
    arena: Allocator,
    /// Every net's name, in file order.
    nets: std.ArrayList([]const u8) = .empty,
    /// Per net, its driver: the first node declared to drive; null for none.
    driver: std.ArrayList(?[]const u8) = .empty,
    /// Node name to the net that declares it (its first declaration wins).
    declared: std.StringHashMapUnmanaged(u32) = .empty,
    element_net: std.ArrayList(u32) = .empty,
    element_a: std.ArrayList([]const u8) = .empty,
    /// The far node; null for a capacitance to ground.
    element_b: std.ArrayList(?[]const u8) = .empty,
    element_kind: std.ArrayList(Kind) = .empty,
    /// fF, Ω or pH.
    element_value: std.ArrayList(f64) = .empty,
    element_line: std.ArrayList(u32) = .empty,
    delimiter: u8 = ':',

    pub fn init(arena: Allocator) Collect {
        return .{ .arena = arena };
    }

    /// A new net named `unescaped`; returns its index.
    pub fn net(c: *Collect, unescaped: []const u8) Allocator.Error!u32 {
        try c.nets.append(c.arena, unescaped);
        try c.driver.append(c.arena, null);
        return @intCast(c.nets.items.len - 1);
    }

    /// Declares node `unescaped` on net `on`; a driving node becomes the
    /// net's driver unless it has one.
    pub fn declare(c: *Collect, on: u32, unescaped: []const u8, drives: bool) Allocator.Error!void {
        if (drives and c.driver.items[on] == null) c.driver.items[on] = unescaped;
        const slot = try c.declared.getOrPut(c.arena, unescaped);
        if (!slot.found_existing) slot.value_ptr.* = on;
    }

    pub fn element(c: *Collect, on: u32, a: []const u8, b: ?[]const u8, kind: Kind, value: f64, line: u32) Allocator.Error!void {
        try c.element_net.append(c.arena, on);
        try c.element_a.append(c.arena, a);
        try c.element_b.append(c.arena, b);
        try c.element_kind.append(c.arena, kind);
        try c.element_value.append(c.arena, value);
        try c.element_line.append(c.arena, line);
    }

    /// The network into `out` (cleared): nets sorted by name, each net's
    /// nodes in order of first mention (its driver first), elements
    /// canonical.
    pub fn build(c: *Collect, gpa: Allocator, out: *Read, diag: *Diagnostic) Error!void {
        out.name_bytes.clearRetainingCapacity();
        out.name_start.clearRetainingCapacity();
        out.network.clear();
        if (c.nets.items.len == 0) return error.NoNets;
        var by_name: std.StringHashMapUnmanaged(u32) = .empty;
        for (c.nets.items, 0..) |n, k| {
            const slot = try by_name.getOrPut(c.arena, n);
            if (slot.found_existing) {
                diag.* = .{ .token = n };
                return error.DuplicateNet;
            }
            slot.value_ptr.* = @intCast(k);
        }
        try c.placeNodes(&by_name, diag);
        // Nodes per net, in order of first mention, the driver first.
        const nets = c.nets.items.len;
        const order = try c.arena.alloc(std.ArrayList([]const u8), nets);
        @memset(order, .empty);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (c.driver.items, order) |d, *o| {
            const node = d orelse continue;
            try o.append(c.arena, node);
            try seen.put(c.arena, node, {});
        }
        for (c.element_a.items, c.element_b.items) |a, b| {
            for ([2]?[]const u8{ a, b }) |maybe| {
                const node = maybe orelse continue;
                if ((try seen.getOrPut(c.arena, node)).found_existing) continue;
                try order[c.declared.get(node).?].append(c.arena, node);
            }
        }
        const rank = try c.arena.alloc(u32, nets);
        for (rank, 0..) |*r, k| r.* = @intCast(k);
        std.mem.sortUnstable(u32, rank, c.nets.items, nameLess);
        var node_id: std.StringHashMapUnmanaged(NodeId) = .empty;
        const n = &out.network;
        for (rank, 0..) |old, new| {
            for (order[old].items) |node| {
                if (n.node_net.items.len >= std.math.maxInt(u32)) return error.TooManyNodes;
                try node_id.put(c.arena, node, .at(n.node_net.items.len));
                try n.node_net.append(gpa, @intCast(new));
                try n.node_layer.append(gpa, @fromBackingInt(0));
            }
            try out.name_start.append(gpa, @intCast(out.name_bytes.items.len));
            try out.name_bytes.appendSlice(gpa, c.nets.items[old]);
        }
        try out.name_start.append(gpa, @intCast(out.name_bytes.items.len));
        try c.pushElements(gpa, &node_id, n, diag);
        try n.sortCanonical(gpa);
    }

    // ---- private ----

    /// Gives every element node no net declares a net: its prefix's, else
    /// the element's own for a resistor terminal or a capacitor's first.
    fn placeNodes(c: *Collect, by_name: *const std.StringHashMapUnmanaged(u32), diag: *Diagnostic) Error!void {
        for (c.element_a.items, c.element_b.items, c.element_kind.items, c.element_net.items, c.element_line.items) |a, b, kind, own_net, line| {
            for ([2]?[]const u8{ a, b }, [2]bool{ true, kind != .cap }) |maybe, own| {
                const node = maybe orelse continue;
                if (c.declared.contains(node)) continue;
                const prefix = if (std.mem.lastIndexOfScalar(u8, node, c.delimiter)) |at| by_name.get(node[0..at]) else null;
                const of = prefix orelse by_name.get(node) orelse if (own) own_net else {
                    diag.* = .{ .line = line, .token = node };
                    return error.OrphanNode;
                };
                try c.declared.put(c.arena, node, of);
            }
        }
    }

    /// Every element onto its nodes. A coupling between two nodes of two
    /// nets, by unordered pair, remembers the net whose section listed it,
    /// so the other net's listing is not counted again.
    fn pushElements(c: *Collect, gpa: Allocator, node_id: *const std.StringHashMapUnmanaged(NodeId), n: *ParasiticNetwork, diag: *Diagnostic) Error!void {
        var couplings: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
        for (c.element_net.items, c.element_a.items, c.element_b.items, c.element_kind.items, c.element_value.items, c.element_line.items) |own, a_name, b_name, kind, value, line| {
            const a = node_id.get(a_name).?;
            const b: NodeId = if (b_name) |name| node_id.get(name).? else .ground;
            switch (kind) {
                .res, .ind => {
                    if (b == .ground) {
                        diag.* = .{ .line = line, .token = a_name };
                        return error.ElementToGround;
                    }
                    try n.push(gpa, a, b, if (kind == .res) .resistance else .inductance, value);
                },
                .cap => {
                    if (b == .ground) {
                        try n.push(gpa, a, b, .ground_cap, value);
                        continue;
                    }
                    // Two nodes of one net: a capacitor that shorts itself
                    // out of every net total; read as written.
                    if (n.node_net.items[@backingInt(a)] != n.node_net.items[@backingInt(b)]) {
                        const key = [2]u32{ @min(@backingInt(a), @backingInt(b)), @max(@backingInt(a), @backingInt(b)) };
                        if (couplings.get(key)) |listed| {
                            if (listed != own) {
                                _ = couplings.remove(key);
                                continue;
                            }
                        }
                        try couplings.put(c.arena, key, own);
                    }
                    try n.push(gpa, a, b, .coupling_cap, value);
                },
            }
        }
    }
};

/// `raw` with every `\` escape removed (`\x` reads `x`), in `arena`.
pub fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            if (i == raw.len) break;
        }
        out.appendAssumeCapacity(raw[i]);
    }
    return out.items;
}

/// A finite number, or a `min:typ:max` triplet's typical value; null for
/// anything else.
pub fn number(text: []const u8) ?f64 {
    var parts = std.mem.splitScalar(u8, text, ':');
    const first = parts.next().?;
    const typ = if (parts.next()) |second| blk: {
        _ = parts.next() orelse return null;
        if (parts.next() != null) return null;
        break :blk second;
    } else first;
    const v = std.fmt.parseFloat(f64, typ) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

// ---- private ----

fn orderStr(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

fn nameLess(names: [][]const u8, a: u32, b: u32) bool {
    return std.mem.order(u8, names[a], names[b]) == .lt;
}
