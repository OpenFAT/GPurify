//! Devices and nets a deck's `lvs` statements take out of the comparison,
//! and nets they join: `lvs ignore`, `lvs ignore_shorted`, `lvs max_res`,
//! `lvs min_caps`, `lvs filter_unused`, `lvs ignore_parameter`, and the
//! must-connect nets of `lvs connect_implicit`/`lvs connect_explicit`. In:
//! a `Graph` and the controls. Out: the graph rewritten in place, and the
//! rows kept. Ported from crates/check/src/lvs/controls.rs (`left_out`,
//! `drop_ignored_devices`, `filter_unused`, `retain_devices`,
//! `must_connect`, `join_must_connect`, `restore_rows`,
//! `drop_ignored_params`).
//!
//! Contents:
//! - `pub fn dropIgnoredDevices(gpa: Allocator, g: *Graph, controls: *const LvsControls, values: [2]?StrId, kept: *std.ArrayList(u32)) Allocator.Error!bool`
//! - `pub fn filterUnused(gpa: Allocator, g: *Graph, controls: *const LvsControls, kept: *std.ArrayList(u32)) Allocator.Error!bool`
//! - `pub fn retainDevices(gpa: Allocator, g: *Graph, kept: []const u32) Allocator.Error!void`
//! - `pub fn mustConnect(name: StrId, strings: *const StrTable, controls: *const LvsControls) bool`
//! - `pub fn joinMustConnect(gpa: Allocator, g: *Graph, controls: *const LvsControls, strings: *const StrTable) Allocator.Error!void`
//! - `pub fn restoreRows(rows: []u32, kept: []const u32) void`
//! - `pub fn dropIgnoredParams(gpa: Allocator, g: *Graph, controls: *const LvsControls) Allocator.Error!void`
//! - private `IgnoreCtx`: its `rewrite` is `pub` only because `graph.rewriteParams` looks it up at comptime

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const LvsControls = ingest.deck.LvsControls;
const globMatches = ingest.globMatches;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Param = graph.Param;
const no_net = graph.no_net;

const IgnoreCtx = struct {
    controls: *const LvsControls,

    pub fn rewrite(c: IgnoreCtx, gpa: Allocator, g: *const Graph, device: u32, out: *std.ArrayList(Param)) Allocator.Error!void {
        const model = g.device_model.items[device];
        for (g.paramsOf(device)) |p| {
            const ignored = for (c.controls.ignore_parameter) |row| (if (row.model == model and row.param == p.name) break true) else false;
            if (!ignored) try out.append(gpa, p);
        }
    }
};

/// Drops every device `lvs ignore`, `lvs ignore_shorted`, `lvs max_res` or
/// `lvs min_caps` leaves out (`values` names `r` and `c`) with the nets only
/// they reached, as if never drawn or written. Returns whether anything was
/// dropped; then `kept` holds the given rows kept, ascending.
pub fn dropIgnoredDevices(gpa: Allocator, g: *Graph, controls: *const LvsControls, values: [2]?StrId, kept: *std.ArrayList(u32)) Allocator.Error!bool {
    kept.clearRetainingCapacity();
    if (controls.ignore.len == 0 and controls.ignore_shorted.len == 0 and controls.max_res == null and controls.min_caps == null) return false;
    for (0..g.deviceCount()) |d| {
        if (!leftOut(g, @intCast(d), controls, values)) try kept.append(gpa, @intCast(d));
    }
    if (kept.items.len == g.deviceCount()) return false;
    try retainDevices(gpa, g, kept.items);
    return true;
}

/// Drops every layout transistor an `lvs filter_unused` option matches
/// (catalog LVS-048; Calibre's `LVS FILTER UNUSED OPTION ... LAYOUT`, US
/// 8,751,985 B1 col. 7), with the nets only they reached. One pass: each is
/// judged on the graph as drawn. Returns whether anything was dropped.
pub fn filterUnused(gpa: Allocator, g: *Graph, controls: *const LvsControls, kept: *std.ArrayList(u32)) Allocator.Error!bool {
    kept.clearRetainingCapacity();
    if (controls.filter_unused.len == 0) return false;
    const is_port = try gpa.alloc(bool, g.netCount());
    defer gpa.free(is_port);
    @memset(is_port, false);
    for (g.port_net.items) |n| is_port[n] = true;
    for (0..g.deviceCount()) |d| {
        if (!unused(g, @intCast(d), controls, is_port)) try kept.append(gpa, @intCast(d));
    }
    if (kept.items.len == g.deviceCount()) return false;
    try retainDevices(gpa, g, kept.items);
    return true;
}

/// Keeps only device rows `kept` (ascending), dropping every net that lost
/// its last terminal with the others and is no port. A net nothing ever
/// held stays. Survivors keep their order.
pub fn retainDevices(gpa: Allocator, g: *Graph, kept: []const u32) Allocator.Error!void {
    const nets = g.netCount();
    const held = try gpa.alloc(bool, nets);
    defer gpa.free(held);
    @memset(held, false);
    for (g.port_net.items) |n| held[n] = true;
    for (kept) |d| for (g.terminalsOf(d).nets) |n| {
        if (n < nets) held[n] = true;
    };
    const new_net = try gpa.alloc(u32, nets);
    defer gpa.free(new_net);
    var next: u32 = 0;
    for (new_net, 0..) |*slot, n| {
        const survives = held[n] or g.terminalsOn(@intCast(n)).devices.len == 0;
        slot.* = if (survives) next else no_net;
        next += @intFromBool(survives);
    }
    var out: Graph = .{};
    errdefer out.deinit(gpa);
    for (g.net_name.items, new_net) |name, slot| if (slot != no_net) try out.net_name.append(gpa, name);
    for (g.net_origin.items, 0..) |origin, n| if (new_net[n] != no_net) try out.net_origin.append(gpa, origin);
    for (g.port_net.items) |n| try out.port_net.append(gpa, new_net[n]);
    try out.device_terminal_start.append(gpa, 0);
    try out.device_param_start.append(gpa, 0);
    for (kept) |d| {
        try out.device_kind.append(gpa, g.device_kind.items[d]);
        try out.device_model.append(gpa, g.device_model.items[d]);
        const t = g.terminalsOf(d);
        for (t.nets) |n| try out.terminal_net.append(gpa, if (n < nets) new_net[n] else no_net);
        try out.terminal_role.appendSlice(gpa, t.roles);
        try out.device_terminal_start.append(gpa, @intCast(out.terminal_net.items.len));
        try out.param.appendSlice(gpa, g.paramsOf(d));
        try out.device_param_start.append(gpa, @intCast(out.param.items.len));
    }
    try graph.transposeInto(gpa, &out, next);
    g.deinit(gpa);
    g.* = out;
}

/// Whether a layout net labelled `name` is a must-connect net: its label
/// matches an `lvs connect_implicit` pattern, or is in an `lvs
/// connect_explicit` group.
pub fn mustConnect(name: StrId, strings: *const StrTable, controls: *const LvsControls) bool {
    return explicitGroup(controls, name) != null or implicit(controls, strings, name);
}

/// Joins the layout's must-connect nets in place, as KLayout's
/// `connect_implicit`/`connect_explicit` join them for LVS (catalog
/// LVS-002): the nets of one label an implicit pattern matches are one net,
/// and so are the nets labelled with one explicit group's names (an explicit
/// group first). The joined net is the lowest of its nets, with its label;
/// the other rows go, survivors keep their order. Devices are unchanged.
/// The open stays an open on the layout: `checkLayout` reports it.
pub fn joinMustConnect(gpa: Allocator, g: *Graph, controls: *const LvsControls, strings: *const StrTable) Allocator.Error!void {
    if (controls.connect_implicit.len == 0 and controls.connect_explicit.len == 0) return;
    // Joined before a comparison numbers origins, so none to keep here.
    std.debug.assert(g.net_origin.items.len == 0);
    // Each must-connect net's key: `(0, group)` explicit, `(1, label)`
    // implicit; the first net of a key stays.
    var first: std.ArrayList(struct { key: [2]u32, row: u32 }) = .empty;
    defer first.deinit(gpa);
    const new_net = try gpa.alloc(u32, g.netCount());
    defer gpa.free(new_net);
    var kept: u32 = 0;
    for (g.net_name.items, new_net, 0..) |name, *slot, n| {
        const key: ?[2]u32 = if (name) |nm| keyOf(controls, strings, nm) else null;
        if (key) |k| {
            const joined = for (first.items) |f| (if (f.key[0] == k[0] and f.key[1] == k[1]) break f.row) else null;
            if (joined) |row| {
                slot.* = row;
                continue;
            }
            try first.append(gpa, .{ .key = k, .row = kept });
        }
        slot.* = kept;
        g.net_name.items[kept] = g.net_name.items[n];
        kept += 1;
    }
    g.net_name.shrinkRetainingCapacity(kept);
    for (g.terminal_net.items) |*n| {
        if (n.* < new_net.len) n.* = new_net[n.*];
    }
    for (g.port_net.items) |*n| n.* = new_net[n.*];
    std.mem.sortUnstable(u32, g.port_net.items, {}, std.sort.asc(u32));
    var ports: usize = 0;
    for (g.port_net.items) |n| {
        if (ports > 0 and g.port_net.items[ports - 1] == n) continue;
        g.port_net.items[ports] = n;
        ports += 1;
    }
    g.port_net.shrinkRetainingCapacity(ports);
    try graph.transposeInto(gpa, g, kept);
}

/// Rewrites rows of a graph a drop filtered as rows of the graph it was
/// given (`kept[row]`).
pub fn restoreRows(rows: []u32, kept: []const u32) void {
    for (rows) |*row| row.* = kept[row.*];
}

/// Drops every parameter `lvs ignore_parameter` names for its device's
/// model: as if no card stated it and the layout measured none.
pub fn dropIgnoredParams(gpa: Allocator, g: *Graph, controls: *const LvsControls) Allocator.Error!void {
    if (controls.ignore_parameter.len == 0) return;
    try graph.rewriteParams(gpa, g, IgnoreCtx{ .controls = controls });
}

// ---- private ----

/// Whether `device` is left out: its model ignored; a resistor stating an
/// `r` above `max_res` or a capacitor a `c` below `min_caps` (aF), KLayout's
/// thresholds; or ignored when shorted with every terminal on one net.
fn leftOut(g: *const Graph, device: u32, controls: *const LvsControls, values: [2]?StrId) bool {
    const model = g.device_model.items[device];
    if (std.mem.indexOfScalar(StrId, controls.ignore, model) != null) return true;
    const params = g.paramsOf(device);
    const open = switch (g.device_kind.items[device]) {
        .resistor => if (controls.max_res) |limit| (if (stated(params, values[0])) |r| r > limit else false) else false,
        .capacitor => if (controls.min_caps) |limit| (if (stated(params, values[1])) |c| c < limit * 1e-18 else false) else false,
        .mos, .bjt, .diode, .inductor, .cell => false,
    };
    if (open) return true;
    if (std.mem.indexOfScalar(StrId, controls.ignore_shorted, model) == null) return false;
    const nets = g.terminalsOf(device).nets;
    if (nets.len == 0 or nets[0] == no_net) return false;
    for (nets) |n| if (n != nets[0]) return false;
    return true;
}

fn stated(params: []const Param, name: ?StrId) ?f64 {
    const n = name orelse return null;
    for (params) |p| if (p.name == n) return p.value;
    return null;
}

/// Whether an `lvs filter_unused` option matches `device`, a MOS.
fn unused(g: *const Graph, device: u32, controls: *const LvsControls, is_port: []const bool) bool {
    if (g.device_kind.items[device] != .mos) return false;
    const t = g.terminalsOf(device);
    const ends = graph.channelEnds(g, device);
    var gate: ?u32 = null;
    for (t.nets, t.roles) |n, role| if (role == .gate and gate == null) {
        gate = n;
    };
    const source = ends[0];
    const drain = ends[1];
    for (controls.filter_unused) |option| {
        const hit = switch (option) {
            .ae => floats(g, is_port, gate) and floats(g, is_port, source) and floats(g, is_port, drain),
            .af => source != null and drain != null and source.? == drain.?,
            .ag => for (t.nets) |n| (if (n != t.nets[0]) break false) else true,
            .c => supply(g, controls, gate) and (floats(g, is_port, source) or floats(g, is_port, drain)),
            .u => floats(g, is_port, source) and floats(g, is_port, drain),
        };
        if (hit) return true;
    }
    return false;
}

/// A terminal on no net, or on a net no port and touched by nothing else.
fn floats(g: *const Graph, is_port: []const bool, net: ?u32) bool {
    const n = net orelse return false;
    return n == no_net or (!is_port[n] and g.terminalsOn(n).devices.len == 1);
}

fn supply(g: *const Graph, controls: *const LvsControls, net: ?u32) bool {
    const n = net orelse return false;
    if (n >= g.netCount()) return false;
    const name = g.net_name.items[n] orelse return false;
    return std.mem.indexOfScalar(StrId, controls.supply, name) != null;
}

fn explicitGroup(controls: *const LvsControls, name: StrId) ?u32 {
    for (controls.connect_explicit, 0..) |group, at| {
        if (std.mem.indexOfScalar(StrId, group, name) != null) return @intCast(at);
    }
    return null;
}

fn implicit(controls: *const LvsControls, strings: *const StrTable, name: StrId) bool {
    const text = strings.resolve(name);
    for (controls.connect_implicit) |pattern| if (globMatches(pattern, text)) return true;
    return false;
}

fn keyOf(controls: *const LvsControls, strings: *const StrTable, name: StrId) ?[2]u32 {
    if (explicitGroup(controls, name)) |group| return .{ 0, group };
    if (implicit(controls, strings, name)) return .{ 1, @backingInt(name) };
    return null;
}
