//! The conditional voltage propagation against a brute-force sweep of its
//! definition, sharing no code with `erc.voltage`. Ported from
//! tests/exhaustive/erc_reference.rs (`naive_propagation`,
//! `voltage_propagation_agrees_with_a_naive_sweep_of_the_extracted_graph`).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const NetId = check.topology.NetId;
const TerminalRole = check.topology.TerminalRole;
const IntentMap = check.erc.facts.IntentMap;
const NetVoltage = check.erc.voltage.NetVoltage;
const circuit = @import("reference_circuit.zig");
const Circuit = circuit.Circuit;
const gpa = testing.allocator;

/// One net's reach, or null when no supply reaches it.
const Reach = ?struct { lo: f64, hi: f64, nominal_lo: f64, nominal_hi: f64, power: u64 };

/// A MOS switch's gate condition.
const Condition = struct { at_least: bool, at: f64 };

// ---- private ----

fn merge(a: Reach, b: Reach) Reach {
    const x = a orelse return b;
    const y = b orelse return a;
    return .{ .lo = @min(x.lo, y.lo), .hi = @max(x.hi, y.hi), .nominal_lo = @min(x.nominal_lo, y.nominal_lo), .nominal_hi = @max(x.nominal_hi, y.nominal_hi), .power = x.power | y.power };
}

fn eql(a: Reach, b: Reach) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

/// The propagation of `erc.voltage`'s doc comment by brute force: supplies
/// fixed at their voltage (0 V for a ground); every conducting device widens
/// each of its non-supply channel nets (every terminal but a gate or bulk; a
/// capacitor has none) to the union of all of them, swept over every device
/// until nothing changes. A conditioned MOS conducts when its gate's range
/// reaches the condition, or when its gate is free: unreached with every
/// channel on, or still unreached after a sweep. Fills `want` (with
/// conditions) and `everything` (every channel on).
fn naivePropagation(c: *const Circuit, intent: *const IntentMap, want: []Reach, everything: []Reach) !void {
    const n_dev = c.devices.len();
    const free = try gpa.alloc(bool, n_dev);
    defer gpa.free(free);
    @memset(free, true);
    try sweep(c, intent, free, everything);
    for (free, 0..) |*f, d| f.* = if (gateOf(c, @intCast(d))) |g| everything[g] == null else true;
    while (true) {
        try sweep(c, intent, free, want);
        var any = false;
        for (free, 0..) |*f, d| {
            if (condition(c, @intCast(d)) == null or f.*) continue;
            const floating = if (gateOf(c, @intCast(d))) |g| want[g] == null else true;
            if (floating) {
                f.* = true;
                any = true;
            }
        }
        if (!any) return;
    }
}

fn supplyRow(intent: *const IntentMap, n: usize) ?usize {
    for (intent.supply_net.items, 0..) |s, row| if (@backingInt(s) == n) return row;
    return null;
}

fn gateOf(c: *const Circuit, d: u32) ?usize {
    const t = c.devices.terminalsOf(@fromBackingInt(d));
    for (t.nets, t.roles) |net, role| if (role == .gate) return @backingInt(net);
    return null;
}

fn condition(c: *const Circuit, d: u32) ?Condition {
    if (c.devices.kind.items[d] != .mos) return null;
    const v = c.devices.value.items[d];
    if (v.on_gate_min_mv) |at| return .{ .at_least = true, .at = at };
    if (v.on_gate_max_mv) |at| return .{ .at_least = false, .at = at };
    return null;
}

fn sweep(c: *const Circuit, intent: *const IntentMap, free: []const bool, r: []Reach) !void {
    for (r, 0..) |*x, n| x.* = if (supplyRow(intent, n)) |row| blk: {
        const nominal = intent.supply_voltage.items[row].raw;
        break :blk switch (intent.supply_role.items[row]) {
            .power => .{ .lo = nominal, .hi = nominal, .nominal_lo = nominal, .nominal_hi = nominal, .power = @as(u64, 1) << @intCast(@backingInt(intent.supply_domain.items[row])) },
            .ground => .{ .lo = 0.0, .hi = 0.0, .nominal_lo = nominal, .nominal_hi = nominal, .power = 0 },
        };
    } else null;
    var channel: std.ArrayList(usize) = .empty;
    defer channel.deinit(gpa);
    while (true) {
        var changed = false;
        for (0..c.devices.len()) |dd| {
            const d: u32 = @intCast(dd);
            const on = if (condition(c, d)) |cond| free[d] or blk: {
                const g = gateOf(c, d) orelse break :blk false;
                const reach = r[g] orelse break :blk false;
                break :blk if (cond.at_least) reach.hi >= cond.at else reach.lo <= cond.at;
            } else true;
            if (!on) continue;
            const kind = c.devices.kind.items[d];
            const t = c.devices.terminalsOf(@fromBackingInt(d));
            channel.clearRetainingCapacity();
            for (t.nets, t.roles) |net, role| if (role != .gate and role != .bulk and kind != .capacitor) try channel.append(gpa, @backingInt(net));
            var all: Reach = null;
            for (channel.items) |n| all = merge(all, r[n]);
            for (channel.items) |n| {
                const widened = merge(r[n], all);
                if (supplyRow(intent, n) == null and !eql(widened, r[n])) {
                    r[n] = widened;
                    changed = true;
                }
            }
        }
        if (!changed) return;
    }
}

test "voltage propagation agrees with a naive sweep of the extracted graph" {
    // Oracle: a naive sweep of the propagation rules (`naivePropagation`).
    // On two hundred generated circuits, extracted, with a random gate
    // condition (on_gate_min, on_gate_max or none, at 0, 0.9, 1.8 or 3.3 V)
    // on each transistor and the supplies spread over three domains at 1.8,
    // 3.3 and 0.9 V, every net's range, domain nominals and power mask equal
    // the sweep's; in at least twenty circuits the conditions change some
    // net's reach, so a propagation that ignores them fails.
    var rng = Rng.init(0xf1_0001);
    const volts = [_]f64{ 1800.0, 3300.0, 900.0 };
    var conditioned: u32 = 0;
    for (0..200) |_| {
        var strings: geom.StrTable = .empty;
        defer strings.deinit(gpa);
        var c = try circuit.randomCircuit(&rng, &strings);
        defer c.deinit();
        try c.devices.value.resize(gpa, c.devices.len());
        for (c.devices.value.items, c.devices.kind.items) |*v, kind| {
            v.* = .{};
            if (kind != .mos) continue;
            const levels = [_]f64{ 0.0, 900.0, 1800.0, 3300.0 };
            const at = levels[rng.below(4)];
            switch (rng.below(3)) {
                0 => {},
                1 => v.on_gate_min_mv = at,
                else => v.on_gate_max_mv = at,
            }
        }
        const Row = struct { net: NetId, role: ingest.intent.SupplyRole, domain: u32 };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(gpa);
        for (c.supplies.items) |s| try rows.append(gpa, .{ .net = c.net(s.net), .role = s.role, .domain = @intCast(rng.below(3)) });
        std.mem.sort(Row, rows.items, {}, struct {
            fn less(_: void, x: Row, y: Row) bool {
                return @backingInt(x.net) < @backingInt(y.net);
            }
        }.less);
        var intent: IntentMap = .{ .declared = true };
        defer intent.deinit(gpa);
        for (rows.items) |row| {
            try intent.supply_net.append(gpa, row.net);
            try intent.supply_role.append(gpa, row.role);
            try intent.supply_domain.append(gpa, @fromBackingInt(row.domain));
            try intent.supply_voltage.append(gpa, .{ .raw = volts[row.domain] });
        }
        var got: NetVoltage = .{};
        defer got.deinit(gpa);
        try check.erc.voltage.propagateInto(gpa, &c.nets, &c.devices, &intent, &got);
        const count = c.nets.netCount();
        const want = try gpa.alloc(Reach, count);
        defer gpa.free(want);
        const everything = try gpa.alloc(Reach, count);
        defer gpa.free(everything);
        try naivePropagation(&c, &intent, want, everything);
        var differs = false;
        for (want, everything, 0..) |w, e, n| {
            const net: NetId = @fromBackingInt(@as(u32, @intCast(n)));
            const have: Reach = if (got.known(net)) .{ .lo = got.lo.items[n], .hi = got.hi.items[n], .nominal_lo = got.nominal_lo.items[n], .nominal_hi = got.nominal_hi.items[n], .power = got.power.items[n] } else null;
            try testing.expect(eql(have, w));
            differs = differs or !eql(w, e);
        }
        conditioned += @intFromBool(differs);
    }
    try testing.expect(conditioned >= 20);
}
