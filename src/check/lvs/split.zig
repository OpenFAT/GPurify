//! Split gates: a `Graph` → the same graph with the inner nets of every set
//! of transistor chains drawn as split fingers joined, so reduction then
//! merges the fingers in parallel. A chain is MOS channels in series from a
//! net through inner nets, each joining exactly two channel ends of two
//! transistors and no port, to another net. Two chains are fingers of one
//! when they start and end on the same nets and agree position by position
//! in model, gate and bulk nets and `L`; their inner nets are joined in
//! order. This is KLayout's `split_gates` (`DeviceClassMOS3Transistor::
//! join_split_gates`, src/db/db/dbNetlistDeviceClasses.cc), applied to both
//! sides, with a chain started from either channel end.
//!
//! Contents:
//! - `pub fn joinSplitGates(gpa: Allocator, g: *Graph, length: ?StrId) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const StrId = @import("geom").StrId;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const law = @import("reduce_law.zig");
const Role = std.meta.Tag(@import("../topology/device.zig").TerminalRole);

/// One chain from the start net being walked: its end net and its runs of
/// `Walk.devices` and `Walk.inner`, in order from the start.
const Chain = struct { end: u32, devices: [2]u32, inner: [2]u32 };

/// `joinSplitGates`' working tables, dead on return.
const Walk = struct {
    chains: std.ArrayList(Chain) = .empty,
    devices: std.ArrayList(u32) = .empty,
    inner: std.ArrayList(u32) = .empty,

    fn deinit(w: *Walk, gpa: Allocator) void {
        w.chains.deinit(gpa);
        w.devices.deinit(gpa);
        w.inner.deinit(gpa);
    }
};

/// Joins the inner nets of split-finger chains in `g`, in place; `length`
/// is the interned `l`, null when no netlist states one. A joined net takes
/// the lowest row of its group and that row's name; surviving nets keep
/// their order. An inner net is walked once, from the first start net (in
/// net order) that reaches it.
pub fn joinSplitGates(gpa: Allocator, g: *Graph, length: ?StrId) Allocator.Error!void {
    const nets = g.netCount();
    const inner = try gpa.alloc(bool, nets);
    defer gpa.free(inner);
    for (inner, 0..) |*slot, n| slot.* = isInner(g, @intCast(n));
    for (g.port_net.items) |n| inner[n] = false;
    const seen = try gpa.alloc(bool, nets);
    defer gpa.free(seen);
    @memset(seen, false);
    const parent = try gpa.alloc(u32, nets);
    defer gpa.free(parent);
    for (parent, 0..) |*p, n| p.* = @intCast(n);
    var w: Walk = .{};
    defer w.deinit(gpa);
    var joined = false;
    for (0..nets) |start| {
        if (inner[start]) continue;
        w.chains.clearRetainingCapacity();
        w.devices.clearRetainingCapacity();
        w.inner.clearRetainingCapacity();
        const on = g.terminalsOn(@intCast(start));
        for (on.devices, on.roles) |device, role| {
            if (!law.isChannel(role) or g.device_kind.items[device] != .mos) continue;
            try walkChain(gpa, g, inner, seen, @intCast(start), device, &w);
        }
        // Each chain against every earlier one of this start.
        for (w.chains.items, 0..) |a, i| for (w.chains.items[0..i]) |b| {
            if (a.end != b.end or !fingersOfOne(g, &w, a, b, length)) continue;
            const ia = w.inner.items[a.inner[0]..a.inner[1]];
            const ib = w.inner.items[b.inner[0]..b.inner[1]];
            for (ia, ib) |x, y| graph.join(parent, x, y);
            joined = true;
        };
    }
    if (joined) try renumberNets(gpa, g, parent);
}

// ---- private ----

/// A net with exactly two terminals, channel ends of two different MOS.
fn isInner(g: *const Graph, net: u32) bool {
    const on = g.terminalsOn(net);
    if (on.devices.len != 2 or on.devices[0] == on.devices[1]) return false;
    for (on.devices, on.roles) |d, role| {
        if (!law.isChannel(role) or g.device_kind.items[d] != .mos) return false;
    }
    return true;
}

/// Walks one chain from `start` through `first` and files it in `w` when
/// it crosses at least one inner net no earlier chain crossed.
fn walkChain(gpa: Allocator, g: *const Graph, inner: []const bool, seen: []bool, start: u32, first: u32, w: *Walk) Allocator.Error!void {
    const devices_from: u32 = @intCast(w.devices.items.len);
    const inner_from: u32 = @intCast(w.inner.items.len);
    var device = first;
    var at = start;
    const end: u32 = while (true) {
        try w.devices.append(gpa, device);
        const next = otherEnd(g, device, at) orelse break no_net;
        if (!inner[next]) break next;
        // Reached from another start already: a chain of its own there.
        if (seen[next]) break no_net;
        seen[next] = true;
        try w.inner.append(gpa, next);
        const on = g.terminalsOn(next);
        device = if (on.devices[0] == device) on.devices[1] else on.devices[0];
        at = next;
    };
    if (end == no_net or w.inner.items.len == inner_from) {
        // Not a chain to compare; whatever it marked stays seen, as in KLayout.
        w.devices.shrinkRetainingCapacity(devices_from);
        w.inner.shrinkRetainingCapacity(inner_from);
        return;
    }
    try w.chains.append(gpa, .{
        .end = end,
        .devices = .{ devices_from, @intCast(w.devices.items.len) },
        .inner = .{ inner_from, @intCast(w.inner.items.len) },
    });
}

/// The net at `device`'s channel end other than `at`; null when both ends
/// are on `at` or the device has no channel end there.
fn otherEnd(g: *const Graph, device: u32, at: u32) ?u32 {
    const ends = graph.channelEnds(g, device);
    const source = ends[0] orelse return null;
    const drain = ends[1] orelse return null;
    if (source == drain) return null;
    if (source == at) return drain;
    if (drain == at) return source;
    return null;
}

/// Two chains of one start and end, position by position: one model, the
/// same gate and bulk nets, the same `L` bits (both unstated agrees).
fn fingersOfOne(g: *const Graph, w: *const Walk, a: Chain, b: Chain, length: ?StrId) bool {
    const da = w.devices.items[a.devices[0]..a.devices[1]];
    const db = w.devices.items[b.devices[0]..b.devices[1]];
    if (da.len != db.len) return false;
    for (da, db) |x, y| {
        if (g.device_model.items[x] != g.device_model.items[y]) return false;
        for ([2]Role{ .gate, .bulk }) |role| {
            if (netOfRole(g, x, role) != netOfRole(g, y, role)) return false;
        }
        if (lengthBits(g, x, length) != lengthBits(g, y, length)) return false;
    }
    return true;
}

/// The net of `device`'s first terminal of `role`, `no_net` for none.
fn netOfRole(g: *const Graph, device: u32, role: Role) u32 {
    const t = g.terminalsOf(device);
    for (t.nets, t.roles) |n, r| if (std.meta.activeTag(r) == role) return n;
    return no_net;
}

/// `device`'s `L` as bits; null when it states none.
fn lengthBits(g: *const Graph, device: u32, length: ?StrId) ?u64 {
    const name = length orelse return null;
    for (g.paramsOf(device)) |p| if (p.name == name) return @bitCast(p.value);
    return null;
}

/// Every terminal, name, origin and port moved to its group's lowest net, the
/// surviving nets renumbered in order and the net side rebuilt.
fn renumberNets(gpa: Allocator, g: *Graph, parent: []u32) Allocator.Error!void {
    const new_net = try gpa.alloc(u32, parent.len);
    defer gpa.free(new_net);
    var kept: u32 = 0;
    for (0..parent.len) |n| {
        const head = graph.find(parent, @intCast(n));
        if (head != n) {
            // A group's head is its lowest row, renumbered before it.
            assert(head < n);
            new_net[n] = new_net[head];
            continue;
        }
        new_net[n] = kept;
        g.net_name.items[kept] = g.net_name.items[n];
        if (g.net_origin.items.len != 0) g.net_origin.items[kept] = g.net_origin.items[n];
        kept += 1;
    }
    g.net_name.shrinkRetainingCapacity(kept);
    if (g.net_origin.items.len != 0) g.net_origin.shrinkRetainingCapacity(kept);
    for (g.terminal_net.items) |*n| {
        if (n.* != no_net) n.* = new_net[n.*];
    }
    for (g.port_net.items) |*n| n.* = new_net[n.*];
    try graph.transposeInto(gpa, g, kept);
}

/// A graph of MOS cards `(gate, source, drain)` on nets numbered from 0,
/// every net named, the given nets ports.
fn testGraph(gpa: Allocator, cards: []const [3]u32, nets: u32, ports: []const u32) Allocator.Error!Graph {
    var g: Graph = .{};
    errdefer g.deinit(gpa);
    try g.device_terminal_start.append(gpa, 0);
    try g.device_param_start.append(gpa, 0);
    for (cards) |c| {
        try g.device_kind.append(gpa, .mos);
        try g.device_model.append(gpa, @fromBackingInt(@as(u32, 1)));
        try g.terminal_net.appendSlice(gpa, &c);
        try g.terminal_role.appendSlice(gpa, &.{ .gate, .source, .drain });
        try g.device_terminal_start.append(gpa, @intCast(g.terminal_net.items.len));
        try g.device_param_start.append(gpa, 0);
    }
    for (0..nets) |n| try g.net_name.append(gpa, @fromBackingInt(@as(u32, @intCast(n + 100))));
    try g.port_net.appendSlice(gpa, ports);
    try graph.transposeInto(gpa, &g, nets);
    return g;
}

test "two A-B chains between the same nets are one chain: their middle nets join" {
    // Oracle: hand-worked, KLayout's split_gates. Nets: 0 A, 1 B, 2 Y, 3
    // VSS, 4 and 5 the two middles. Fingers Y-A-4-B-VSS and Y-A-5-B-VSS: 4
    // and 5 join under 4, and VSS becomes row 3, the old 5 gone.
    const gpa = std.testing.allocator;
    var g = try testGraph(gpa, &.{ .{ 0, 2, 4 }, .{ 1, 4, 3 }, .{ 0, 2, 5 }, .{ 1, 5, 3 } }, 6, &.{ 0, 1, 2, 3 });
    defer g.deinit(gpa);
    try joinSplitGates(gpa, &g, null);
    g.assertValid();
    try std.testing.expectEqual(5, g.netCount());
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4, 1, 4, 3, 0, 2, 4, 1, 4, 3 }, g.terminal_net.items);
}

test "a joined net keeps its group's lowest origin, and the rest keep theirs" {
    // Oracle: hand-worked, the first test inside a comparison, whose
    // working copy numbers each net by its given row (origin = 10 + row):
    // 4 and 5 join under 4, so 5's origin goes and the others stay in order.
    const gpa = std.testing.allocator;
    var g = try testGraph(gpa, &.{ .{ 0, 2, 4 }, .{ 1, 4, 3 }, .{ 0, 2, 5 }, .{ 1, 5, 3 } }, 6, &.{ 0, 1, 2, 3 });
    defer g.deinit(gpa);
    try g.net_origin.appendSlice(gpa, &.{ 10, 11, 12, 13, 14, 15 });
    try joinSplitGates(gpa, &g, null);
    g.assertValid();
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13, 14 }, g.net_origin.items);
}

test "chains whose gates come in another order, or that end apart, stay apart" {
    // Oracle: hand-worked. Y-A-4-B-VSS against Y-B-5-A-VSS: the gates
    // differ position by position. Y-A-6-B-VSS against Y-A-7-B-OUT (net 8):
    // the ends differ. Neither pair joins, so nothing changes.
    const gpa = std.testing.allocator;
    var g = try testGraph(gpa, &.{ .{ 0, 2, 4 }, .{ 1, 4, 3 }, .{ 1, 2, 5 }, .{ 0, 5, 3 } }, 6, &.{ 0, 1, 2, 3 });
    defer g.deinit(gpa);
    const before = try gpa.dupe(u32, g.terminal_net.items);
    defer gpa.free(before);
    try joinSplitGates(gpa, &g, null);
    try std.testing.expectEqualSlices(u32, before, g.terminal_net.items);
    var h = try testGraph(gpa, &.{ .{ 0, 2, 6 }, .{ 1, 6, 3 }, .{ 0, 2, 7 }, .{ 1, 7, 8 } }, 9, &.{ 0, 1, 2, 3, 8 });
    defer h.deinit(gpa);
    try joinSplitGates(gpa, &h, null);
    try std.testing.expectEqual(9, h.netCount());
}

test "a middle net that is a port is not joined" {
    // Oracle: hand-worked. The split NAND of the first test with net 4 a
    // port: it is no inner net, so neither chain crosses one.
    const gpa = std.testing.allocator;
    var g = try testGraph(gpa, &.{ .{ 0, 2, 4 }, .{ 1, 4, 3 }, .{ 0, 2, 5 }, .{ 1, 5, 3 } }, 6, &.{ 0, 1, 2, 3, 4 });
    defer g.deinit(gpa);
    try joinSplitGates(gpa, &g, null);
    try std.testing.expectEqual(6, g.netCount());
}
