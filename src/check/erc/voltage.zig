//! Static voltage propagation from the declared supplies, conditional on
//! gate voltage. In: nets, devices, an `IntentMap`. Out: `NetVoltage`, per
//! net the span of supply voltages (and domain nominals, and power/ground
//! domain bits) that can reach it through conducting device channels.
//!
//! Model: MOS source to drain and every pin of a resistor, diode or BJT
//! conduct; gates, bulks and capacitors pass nothing; a supply net is fixed
//! at its domain's nominal (power) or 0 V (ground) and stops propagation. A
//! MOS whose deck row states `on_gate_min` (`on_gate_max`) conducts only
//! while its gate can reach that voltage or more (less), judged on its gate
//! net's range (Calibre PERC's conditional propagation, Siemens white paper
//! 81822, figure 1). A gate no supply could reach even with every channel on
//! is driven from outside, so its switch may conduct; so may a switch whose
//! gate floats. The result is the least fixed point; no threshold drop, no
//! body effect. Catalog ERC-F1. Ported from crates/check/src/erc/voltage.rs.
//!
//! Contents:
//! - `pub const NetVoltage = struct`, `deinit`, `known(v, net: NetId) bool`, `worstDelta(v, a: NetId, b: NetId) ?f64`,
//!   `powerOf(v, net: NetId) u64`, `groundOf(v, net: NetId) u64`
//! - `pub fn isChannel(kind: DeviceKind, role: TerminalRole) bool`
//! - `pub fn propagateInto(gpa: Allocator, nets: *const NetTable, devices: *const DeviceTable, intent: *const IntentMap, out: *NetVoltage) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const DeviceKind = @import("ingest").deck.DeviceKind;
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const device_ = @import("../topology/device.zig");
const DeviceTable = device_.DeviceTable;
const TerminalRole = device_.TerminalRole;
const IntentMap = @import("facts.zig").IntentMap;

/// What each net can see, indexed by `NetId`; every column has one row per
/// net of the extraction `propagateInto` was given.
pub const NetVoltage = struct {
    /// Lowest reachable voltage, mV; `lo > hi` when no supply reaches.
    lo: std.ArrayList(f64) = .empty,
    /// Highest reachable voltage, mV; -inf when no supply reaches.
    hi: std.ArrayList(f64) = .empty,
    /// Lowest domain nominal among the reaching supplies (a ground counts
    /// its domain's nominal here, not 0 V).
    nominal_lo: std.ArrayList(f64) = .empty,
    nominal_hi: std.ArrayList(f64) = .empty,
    /// Bit `d`: a power (ground) supply of domain `d` reaches the net.
    power: std.ArrayList(u64) = .empty,
    ground: std.ArrayList(u64) = .empty,

    pub fn deinit(v: *NetVoltage, gpa: Allocator) void {
        inline for (columns) |f| @field(v, f).deinit(gpa);
    }

    /// Some supply reaches `net`; false for `.none`.
    pub fn known(v: *const NetVoltage, net: NetId) bool {
        if (net == .none) return false;
        const i = @backingInt(net);
        return v.lo.items[i] <= v.hi.items[i];
    }

    /// The largest `|V(a) - V(b)|` the two nets can reach, mV; null unless
    /// both are known.
    pub fn worstDelta(v: *const NetVoltage, a: NetId, b: NetId) ?f64 {
        if (!v.known(a) or !v.known(b)) return null;
        const i = @backingInt(a);
        const j = @backingInt(b);
        return @max(v.hi.items[i] - v.lo.items[j], v.hi.items[j] - v.lo.items[i]);
    }

    pub fn powerOf(v: *const NetVoltage, net: NetId) u64 {
        return if (net == .none) 0 else v.power.items[@backingInt(net)];
    }

    pub fn groundOf(v: *const NetVoltage, net: NetId) u64 {
        return if (net == .none) 0 else v.ground.items[@backingInt(net)];
    }

    const columns = .{ "lo", "hi", "nominal_lo", "nominal_hi", "power", "ground" };

    fn reset(v: *NetVoltage, gpa: Allocator, count: usize) Allocator.Error!void {
        inline for (columns) |f| @field(v, f).clearRetainingCapacity();
        try v.lo.appendNTimes(gpa, inf, count);
        try v.nominal_lo.appendNTimes(gpa, inf, count);
        try v.hi.appendNTimes(gpa, -inf, count);
        try v.nominal_hi.appendNTimes(gpa, -inf, count);
        try v.power.appendNTimes(gpa, 0, count);
        try v.ground.appendNTimes(gpa, 0, count);
    }

    fn range(v: *const NetVoltage, net: usize) Range {
        return .{ .lo = v.lo.items[net], .hi = v.hi.items[net], .nominal_lo = v.nominal_lo.items[net], .nominal_hi = v.nominal_hi.items[net], .power = v.power.items[net], .ground = v.ground.items[net] };
    }

    /// Widens row `net` to cover `with`; true when anything grew.
    fn widen(v: *NetVoltage, net: usize, with: Range) bool {
        const old = v.range(net);
        const new = old.merge(with);
        if (std.meta.eql(new, old)) return false;
        v.lo.items[net] = new.lo;
        v.hi.items[net] = new.hi;
        v.nominal_lo.items[net] = new.nominal_lo;
        v.nominal_hi.items[net] = new.nominal_hi;
        v.power.items[net] = new.power;
        v.ground.items[net] = new.ground;
        return true;
    }
};

const inf = std.math.inf(f64);

/// One net's row of `NetVoltage`.
const Range = struct {
    lo: f64,
    hi: f64,
    nominal_lo: f64,
    nominal_hi: f64,
    power: u64,
    ground: u64,

    /// Nothing reached: the identity of `merge`.
    const empty: Range = .{ .lo = inf, .hi = -inf, .nominal_lo = inf, .nominal_hi = -inf, .power = 0, .ground = 0 };

    fn merge(a: Range, b: Range) Range {
        return .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi), .nominal_lo = @min(a.nominal_lo, b.nominal_lo), .nominal_hi = @max(a.nominal_hi, b.nominal_hi), .power = a.power | b.power, .ground = a.ground | b.ground };
    }
};

/// A MOS switch's gate net and when it conducts.
const Switch = struct {
    gate: NetId,
    /// `on_gate_min` (true: conducts at or above `at`) or `on_gate_max`.
    at_least: bool,
    /// mV.
    at: f64,

    /// Null for a channel that always conducts: not a MOS, or no condition.
    fn of(devices: *const DeviceTable, d: u32) ?Switch {
        if (devices.kind.items[d] != .mos) return null;
        const value = if (d < devices.value.items.len) devices.value.items[d] else @import("ingest").deck.DeviceValue{};
        const at_least, const at = if (value.on_gate_min_mv) |v| .{ true, v } else if (value.on_gate_max_mv) |v| .{ false, v } else return null;
        const t = devices.terminalsOf(@fromBackingInt(d));
        const gate = for (t.roles, t.nets) |role, net| {
            if (role == .gate) break net;
        } else NetId.none;
        return .{ .gate = gate, .at_least = at_least, .at = at };
    }

    /// The gate's range can turn the switch on; false while unreached.
    fn canTurnOn(s: Switch, v: *const NetVoltage) bool {
        if (!reached(v, s.gate)) return false;
        const g = @backingInt(s.gate);
        return if (s.at_least) v.hi.items[g] >= s.at else v.lo.items[g] <= s.at;
    }
};

/// What a propagation reads besides the voltages it writes.
const Graph = struct {
    devices: *const DeviceTable,
    /// Per net: a declared supply, fixed.
    supply: []const bool,
    /// Devices on each net, CSR.
    start: []const u32,
    adjacent: []const u32,
    switches: []const ?Switch,

    /// Runs the queued devices to a fixed point: a conducting device widens
    /// each non-supply channel net to the union of all of them, and a net
    /// that grows queues every device on it.
    fn relax(g: Graph, free: []const bool, queue: *std.ArrayList(u32), queued: []bool, out: *NetVoltage) void {
        while (queue.pop()) |d| {
            queued[d] = false;
            const on = if (g.switches[d]) |s| free[d] or s.canTurnOn(out) else true;
            if (!on) continue;
            const kind = g.devices.kind.items[d];
            const t = g.devices.terminalsOf(@fromBackingInt(d));
            var merged = Range.empty;
            for (t.nets, t.roles) |net, role| if (g.onChannel(kind, net, role)) {
                merged = merged.merge(out.range(@backingInt(net)));
            };
            for (t.nets, t.roles) |net, role| {
                if (!g.onChannel(kind, net, role)) continue;
                const i = @backingInt(net);
                if (g.supply[i] or !out.widen(i, merged)) continue;
                for (g.adjacent[g.start[i]..g.start[i + 1]]) |next| if (!queued[next]) {
                    queued[next] = true;
                    queue.appendAssumeCapacity(next);
                };
            }
        }
    }

    fn onChannel(g: Graph, kind: DeviceKind, net: NetId, role: TerminalRole) bool {
        return net != .none and @backingInt(net) < g.supply.len and isChannel(kind, role);
    }
};

/// A terminal in this role conducts DC through the device.
pub fn isChannel(kind: DeviceKind, role: TerminalRole) bool {
    return role != .gate and role != .bulk and kind != .capacitor;
}

/// Propagates the declared supplies over conducting channels; `out` is
/// refilled to `nets.netCount()` rows. Three passes: every channel on, to
/// find the gates no supply can reach (their switches are free); then the
/// switches judged on their gates, from the supplies alone; then, while a
/// switch's gate is still unreached (it floats), that switch freed and the
/// propagation resumed. Ranges only grow, so this ends.
pub fn propagateInto(gpa: Allocator, nets: *const NetTable, devices: *const DeviceTable, intent: *const IntentMap, out: *NetVoltage) Allocator.Error!void {
    const count = nets.netCount();
    const n_dev = devices.len();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const supply = try arena.alloc(bool, count);
    @memset(supply, false);
    for (intent.supply_net.items) |net| if (net != .none and @backingInt(net) < count) {
        supply[@backingInt(net)] = true;
    };
    // Devices on each net, CSR.
    const start = try arena.alloc(u32, count + 1);
    @memset(start, 0);
    for (devices.terminal_net.items) |net| if (net != .none and @backingInt(net) < count) {
        start[@backingInt(net) + 1] += 1;
    };
    for (1..start.len) |at| start[at] += start[at - 1];
    const fill = try arena.dupe(u32, start);
    const adjacent = try arena.alloc(u32, start[count]);
    for (0..n_dev) |d| for (devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d)))).nets) |net| {
        if (net == .none or @backingInt(net) >= count) continue;
        adjacent[fill[@backingInt(net)]] = @intCast(d);
        fill[@backingInt(net)] += 1;
    };
    const switches = try arena.alloc(?Switch, n_dev);
    for (switches, 0..) |*s, d| s.* = Switch.of(devices, @intCast(d));
    const g: Graph = .{ .devices = devices, .supply = supply, .start = start, .adjacent = adjacent, .switches = switches };

    var queue: std.ArrayList(u32) = .empty;
    try queue.ensureTotalCapacity(arena, n_dev);
    const queued = try arena.alloc(bool, n_dev);
    const all_free = try arena.alloc(bool, n_dev);
    @memset(all_free, true);

    // Every channel conducting: which gates any supply can reach at all.
    try seed(gpa, intent, count, out);
    enqueueAll(&queue, queued, n_dev);
    g.relax(all_free, &queue, queued, out);
    const free = try arena.alloc(bool, n_dev);
    for (free, switches) |*f, s| f.* = if (s) |sw| !reached(out, sw.gate) else false;

    try seed(gpa, intent, count, out);
    enqueueAll(&queue, queued, n_dev);
    while (true) {
        g.relax(free, &queue, queued, out);
        for (switches, 0..) |s, d| {
            const floating = if (s) |sw| !reached(out, sw.gate) else false;
            if (floating and !free[d]) {
                free[d] = true;
                queued[d] = true;
                queue.appendAssumeCapacity(@intCast(d));
            }
        }
        if (queue.items.len == 0) return;
    }
}

// ---- private ----

/// Every supply's own row, refilled from nothing.
fn seed(gpa: Allocator, intent: *const IntentMap, count: u32, out: *NetVoltage) Allocator.Error!void {
    try out.reset(gpa, count);
    for (intent.supply_net.items, 0..) |net, row| {
        if (net == .none or @backingInt(net) >= count) continue;
        const nominal = intent.supply_voltage.items[row].raw;
        const b = @as(u64, 1) << @intCast(@backingInt(intent.supply_domain.items[row]));
        const volts: f64, const power: u64, const ground: u64 = switch (intent.supply_role.items[row]) {
            .power => .{ nominal, b, 0 },
            .ground => .{ 0.0, 0, b },
        };
        _ = out.widen(@backingInt(net), .{ .lo = volts, .hi = volts, .nominal_lo = nominal, .nominal_hi = nominal, .power = power, .ground = ground });
    }
}

/// Every device queued, device 0 popped first.
fn enqueueAll(queue: *std.ArrayList(u32), queued: []bool, n: u32) void {
    queue.clearRetainingCapacity();
    var d = n;
    while (d > 0) {
        d -= 1;
        queue.appendAssumeCapacity(d);
    }
    @memset(queued, true);
}

/// Some supply reaches `net`, a net of `v`'s extraction.
fn reached(v: *const NetVoltage, net: NetId) bool {
    return net != .none and @backingInt(net) < v.lo.items.len and v.known(net);
}
