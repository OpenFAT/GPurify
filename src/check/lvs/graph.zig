//! The bipartite device/net graph both sides are projected to before
//! matching: SoA device and net columns with CSR incidence in both
//! directions, plus the small shared pieces every LVS pass reads (role and
//! kind codes, the union-find forest, the transpose). In: columns written by
//! `project.zig` or by hand. Out: the same columns, the net side rebuilt.
//! Ported from crates/check/src/lvs/graph.rs (the struct, `transpose_into`,
//! `find`/`join`/`groups_by_root`, `channel_ends`) and the codes of
//! crates/check/src/lvs/refine.rs.
//!
//! Contents:
//! - `pub const Param`, `pub const no_net: u32`
//! - `pub const Terminals`, `pub const NetTerminals`
//! - `pub const Graph = struct`, `deinit`, `clone(g: *const Graph, gpa: Allocator) Allocator.Error!Graph`,
//!   `deviceCount(g: *const Graph) u32`, `netCount(g: *const Graph) u32`,
//!   `terminalsOf(g: *const Graph, device: u32) Terminals`, `terminalsOn(g: *const Graph, net: u32) NetTerminals`,
//!   `paramsOf(g: *const Graph, device: u32) []const Param`
//! - `pub fn transposeInto(gpa: Allocator, g: *Graph, net_count: u32) Allocator.Error!void`
//! - `pub fn rewriteParams(gpa: Allocator, g: *Graph, ctx: anytype) Allocator.Error!void`
//! - `pub fn roleEql(a: TerminalRole, b: TerminalRole) bool`, `pub fn roleCode(role: TerminalRole) u64`,
//!   `pub fn kindCode(kind: DeviceKind) u64`
//! - `pub fn channelEnds(g: *const Graph, device: u32) [2]?u32`
//! - `pub fn find(root: []u32, device: u32) u32`, `pub fn join(root: []u32, a: u32, b: u32) void`
//! - `pub fn groupsByRootInto(gpa: Allocator, root: []u32, rows: []const u32, start: *std.ArrayList(u32), out: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const StrId = geom.StrId;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
const TerminalRole = @import("../topology/device.zig").TerminalRole;

/// `(name, value)`: a lowercased, interned SPICE name and a value in SI base
/// units (metres, square metres, a plain count). The reference netlist's row.
pub const Param = ingest.netlist.Param;

/// A terminal on no net.
pub const no_net: u32 = std.math.maxInt(u32);

/// One device's terminals, parallel.
pub const Terminals = struct { nets: []const u32, roles: []const TerminalRole };

/// One net's terminals, parallel, ascending by device.
pub const NetTerminals = struct { devices: []const u32, roles: []const TerminalRole };

/// A netlist reduced to what matching needs. Devices and nets are numbered
/// separately, each from zero. Invariants (every transform keeps them, and
/// every reader assumes them):
/// - `device_kind`/`device_model` one row per device, `net_name` one per net;
/// - each `*_start` column is CSR, one offset per row plus a terminator
///   (empty only when its table and payload are empty);
/// - every `terminal_net` is a net row or `no_net`;
/// - `net_terminal_*` is the transpose of the device side, ascending by
///   device within a net, a terminal on no net on none;
/// - every `port_net` is a net row.
pub const Graph = struct {
    /// With `device_model`, the class a device starts refinement in.
    device_kind: std.ArrayList(DeviceKind) = .empty,
    device_model: std.ArrayList(StrId) = .empty,
    device_terminal_start: std.ArrayList(u32) = .empty,
    terminal_net: std.ArrayList(u32) = .empty,
    /// Matching reads roles, never positions.
    terminal_role: std.ArrayList(TerminalRole) = .empty,
    device_param_start: std.ArrayList(u32) = .empty,
    param: std.ArrayList(Param) = .empty,
    net_terminal_start: std.ArrayList(u32) = .empty,
    net_terminal_device: std.ArrayList(u32) = .empty,
    net_terminal_role: std.ArrayList(TerminalRole) = .empty,
    /// The reference's net name, or the layout's port label.
    net_name: std.ArrayList(?StrId) = .empty,
    /// Nets that are ports of this cell; a series merge never consumes one.
    port_net: std.ArrayList(u32) = .empty,

    pub fn deinit(g: *Graph, gpa: Allocator) void {
        inline for (@typeInfo(Graph).@"struct".field_names) |f| @field(g, f).deinit(gpa);
    }

    pub fn clone(g: *const Graph, gpa: Allocator) Allocator.Error!Graph {
        var out: Graph = .{};
        errdefer out.deinit(gpa);
        inline for (@typeInfo(Graph).@"struct".field_names) |f| {
            try @field(out, f).appendSlice(gpa, @field(g, f).items);
        }
        return out;
    }

    pub fn deviceCount(g: *const Graph) u32 {
        return @intCast(g.device_kind.items.len);
    }

    pub fn netCount(g: *const Graph) u32 {
        return @intCast(g.net_name.items.len);
    }

    /// One device's terminals in the order the graph was built with.
    pub fn terminalsOf(g: *const Graph, device: u32) Terminals {
        const from = g.device_terminal_start.items[device];
        const to = g.device_terminal_start.items[device + 1];
        return .{ .nets = g.terminal_net.items[from..to], .roles = g.terminal_role.items[from..to] };
    }

    /// Every terminal on one net, ascending by device.
    pub fn terminalsOn(g: *const Graph, net: u32) NetTerminals {
        const from = g.net_terminal_start.items[net];
        const to = g.net_terminal_start.items[net + 1];
        return .{ .devices = g.net_terminal_device.items[from..to], .roles = g.net_terminal_role.items[from..to] };
    }

    /// One device's parameters, in the order stated.
    pub fn paramsOf(g: *const Graph, device: u32) []const Param {
        const from = g.device_param_start.items[device];
        const to = g.device_param_start.items[device + 1];
        return g.param.items[from..to];
    }
};

/// Rebuilds the net side from the device side, in place: terminals land
/// ascending by device within each net, a terminal on no net (or past
/// `net_count`) on none.
pub fn transposeInto(gpa: Allocator, g: *Graph, net_count: u32) Allocator.Error!void {
    const start = &g.net_terminal_start;
    start.clearRetainingCapacity();
    try start.appendNTimes(gpa, 0, @as(usize, net_count) + 1);
    for (g.terminal_net.items) |net| {
        if (net < net_count) start.items[net] += 1;
    }
    // Inclusive prefix: `start[n]` is bucket `n`'s end, `start[net_count]`
    // the terminator.
    for (1..@as(usize, net_count) + 1) |b| start.items[b] += start.items[b - 1];
    const filed = start.items[net_count];
    try g.net_terminal_device.resize(gpa, filed);
    try g.net_terminal_role.resize(gpa, filed);
    // Each end doubles as a descending write cursor, coming to rest on the
    // bucket's start.
    var device = g.deviceCount();
    while (device > 0) {
        device -= 1;
        const from = g.device_terminal_start.items[device];
        var slot = g.device_terminal_start.items[device + 1];
        while (slot > from) {
            slot -= 1;
            const net = g.terminal_net.items[slot];
            if (net >= net_count) continue;
            const at = start.items[net] - 1;
            g.net_terminal_device.items[at] = device;
            g.net_terminal_role.items[at] = g.terminal_role.items[slot];
            start.items[net] = at;
        }
    }
}

/// Rebuilds the parameter column device by device: `ctx.rewrite(g, device,
/// out)` appends `device`'s new parameters to `out`, reading the old ones
/// from `g`. Rung 5 (comptime `ctx`): six passes rewrite parameters, each
/// with its own rule, and the loop around them is this one.
pub fn rewriteParams(gpa: Allocator, g: *Graph, ctx: anytype) Allocator.Error!void {
    var param: std.ArrayList(Param) = .empty;
    errdefer param.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    errdefer start.deinit(gpa);
    try param.ensureTotalCapacity(gpa, g.param.items.len);
    try start.ensureTotalCapacity(gpa, @as(usize, g.deviceCount()) + 1);
    start.appendAssumeCapacity(0);
    for (0..g.deviceCount()) |device| {
        try ctx.rewrite(gpa, g, @as(u32, @intCast(device)), &param);
        try start.append(gpa, @intCast(param.items.len));
    }
    g.param.deinit(gpa);
    g.device_param_start.deinit(gpa);
    g.param = param;
    g.device_param_start = start;
}

pub fn roleEql(a: TerminalRole, b: TerminalRole) bool {
    return std.meta.eql(a, b);
}

/// A terminal's role as a signature number. Interchangeable roles share a
/// code: MOS source and drain, and a resistor's two ends (both built
/// `pin = 0`). Emitter and collector never share, nor a diode's or a
/// capacitor's pins (testing-plan F15).
pub fn roleCode(role: TerminalRole) u64 {
    return switch (role) {
        .gate => 0,
        .source, .drain => 1,
        .bulk => 3,
        .base => 4,
        .emitter => 5,
        .collector => 6,
        .pin => |position| 16 + @as(u64, position),
    };
}

pub fn kindCode(kind: DeviceKind) u64 {
    return switch (kind) {
        .mos => 0,
        .bjt => 1,
        .resistor => 2,
        .capacitor => 3,
        .diode => 4,
        .inductor => 5,
        .cell => 6,
    };
}

/// The nets of a device's source and drain, where it has them: the first
/// terminal of each role.
pub fn channelEnds(g: *const Graph, device: u32) [2]?u32 {
    const t = g.terminalsOf(device);
    var ends: [2]?u32 = .{ null, null };
    for (t.nets, t.roles) |net, role| switch (role) {
        .source => if (ends[0] == null) {
            ends[0] = net;
        },
        .drain => if (ends[1] == null) {
            ends[1] = net;
        },
        .gate, .bulk, .base, .emitter, .collector, .pin => {},
    };
    return ends;
}

/// The group root of `device` in the union-find forest `root`, halving the
/// path. The root is the set's lowest index (`join` points the higher root
/// at the lower), so an order derived from roots is a function of the
/// input, not of the join order.
pub fn find(root: []u32, device: u32) u32 {
    var at = device;
    while (root[at] != at) {
        const grand = root[root[at]];
        root[at] = grand;
        at = grand;
    }
    return at;
}

/// Merges the sets of `a` and `b` under the lower root.
pub fn join(root: []u32, a: u32, b: u32) void {
    const left = find(root, a);
    const right = find(root, b);
    root[@max(left, right)] = @min(left, right);
}

/// `rows` grouped by their root, CSR into `out` (both cleared): groups in
/// the order their first row comes, rows in `rows` order within each.
pub fn groupsByRootInto(gpa: Allocator, root: []u32, rows: []const u32, start: *std.ArrayList(u32), out: *std.ArrayList(u32)) Allocator.Error!void {
    start.clearRetainingCapacity();
    out.clearRetainingCapacity();
    const group_of = try gpa.alloc(u32, root.len);
    defer gpa.free(group_of);
    @memset(group_of, no_net);
    // Count per group, then place: two passes keep the payload one array.
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);
    for (rows) |row| {
        const head = find(root, row);
        if (group_of[head] == no_net) {
            group_of[head] = @intCast(sizes.items.len);
            try sizes.append(gpa, 0);
        }
        sizes.items[group_of[head]] += 1;
    }
    try start.ensureTotalCapacity(gpa, sizes.items.len + 1);
    start.appendAssumeCapacity(0);
    for (sizes.items) |size| start.appendAssumeCapacity(start.items[start.items.len - 1] + size);
    try out.resize(gpa, rows.len);
    @memset(sizes.items, 0);
    for (rows) |row| {
        const group = group_of[find(root, row)];
        out.items[start.items[group] + sizes.items[group]] = row;
        sizes.items[group] += 1;
    }
}

// ---- private ----

test "the transpose lists each net's terminals ascending by device" {
    // Oracle: construct-from-answer. Two devices share net 1; a terminal on
    // no net is filed nowhere.
    const gpa = std.testing.allocator;
    var g: Graph = .{};
    defer g.deinit(gpa);
    try g.device_kind.appendSlice(gpa, &.{ .mos, .mos });
    try g.device_model.appendSlice(gpa, &.{ @fromBackingInt(@intCast(1)), @fromBackingInt(@intCast(1)) });
    try g.device_terminal_start.appendSlice(gpa, &.{ 0, 2, 4 });
    try g.terminal_net.appendSlice(gpa, &.{ 0, 1, 1, no_net });
    try g.terminal_role.appendSlice(gpa, &.{ .gate, .source, .drain, .gate });
    try g.device_param_start.appendSlice(gpa, &.{ 0, 0, 0 });
    try g.net_name.appendSlice(gpa, &.{ null, null });
    try transposeInto(gpa, &g, 2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3 }, g.net_terminal_start.items);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, g.net_terminal_device.items);
}
