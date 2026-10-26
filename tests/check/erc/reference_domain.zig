//! `well_bias` and `missing_level_shifter`, fed by the engine's own
//! propagation, against a breadth-first search from each net that shares no
//! code with `erc.voltage` or `erc.domain`. Ported from
//! tests/exhaustive/erc_reference.rs (`NOMINALS`, `reach`,
//! `bias_and_shifters`, `voltage_rules_agree_with_a_search_from_each_net`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const Rng = testgen.Rng;
const topology = check.topology;
const NetId = topology.NetId;
const TerminalRole = topology.TerminalRole;
const SupplyRole = ingest.intent.SupplyRole;
const erc = check.erc;
const IntentMap = erc.facts.IntentMap;
const circuit = @import("reference_circuit.zig");
const Circuit = circuit.Circuit;
const common = @import("common.zig");
const gpa = common.gpa;

/// The domain nominals the circuits draw their supplies from, mV: three
/// domains, so a gate and a channel can be reached by different ones.
const nominals = [3]f64{ 1800.0, 3300.0, 5000.0 };

/// A supply as the reference reads it: its net, role and domain index.
const Supply = struct { net: NetId, role: SupplyRole, domain: u32 };

/// What a net reaches: lowest and highest voltage, power-domain bits.
const Reach = struct { lo: f64, hi: f64, power: u64 };

/// One finding: the device and its measure.
const Found = struct { device: usize, measured: f64 };

/// One rule's findings in device order, and how many devices it examined.
const Judged = struct { found: []const Found, examined: u64 };

/// The three model names a circuit's transistors are drawn from.
const Models = struct { pmos: StrId, nmos: StrId, shifter: StrId };

// ---- private ----

/// What `from` can reach, re-derived from `erc.voltage`'s doc by a search
/// from the net itself: a supply sits at its domain's nominal (power) or
/// 0 V (ground) and passes nothing on; any other net reaches, through
/// device channels (a MOS's source and drain, every pin of a diode, never a
/// gate, a bulk or a capacitor), every supply some chain of channels joins
/// it to. Null when no supply is reached.
fn reach(arena: Allocator, c: *const Circuit, supplies: []const Supply, from: NetId) !?Reach {
    if (from == .none) return null;
    if (held(supplies, from)) |h| return h;
    const seen = try arena.alloc(bool, c.nets.netCount());
    @memset(seen, false);
    seen[@backingInt(from)] = true;
    var queue: std.ArrayList(NetId) = .empty;
    try queue.append(arena, from);
    var found: ?Reach = null;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const net = queue.items[head];
        if (held(supplies, net)) |h| {
            found = if (found) |f| .{ .lo = @min(f.lo, h.lo), .hi = @max(f.hi, h.hi), .power = f.power | h.power } else h;
            continue;
        }
        for (0..c.devices.len()) |d| {
            if (c.devices.kind.items[d] == .capacitor) continue;
            const t = c.devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const touches = for (t.nets, t.roles) |n, role| {
                if (n == net and channel(role)) break true;
            } else false;
            if (!touches) continue;
            for (t.nets, t.roles) |n, role| if (n != .none and channel(role) and !seen[@backingInt(n)]) {
                seen[@backingInt(n)] = true;
                try queue.append(arena, n);
            };
        }
    }
    return found;
}

fn channel(role: TerminalRole) bool {
    return switch (role) {
        .gate, .bulk => false,
        .source, .drain, .base, .emitter, .collector, .pin => true,
    };
}

fn held(supplies: []const Supply, net: NetId) ?Reach {
    for (supplies) |s| if (s.net == net) return switch (s.role) {
        .power => .{ .lo = nominals[s.domain], .hi = nominals[s.domain], .power = @as(u64, 1) << @intCast(s.domain) },
        .ground => .{ .lo = 0.0, .hi = 0.0, .power = 0 },
    };
    return null;
}

fn at(c: *const Circuit, d: usize, role: TerminalRole) NetId {
    const t = c.devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
    for (t.nets, t.roles) |n, r| if (std.meta.eql(r, role)) return n;
    return .none;
}

/// `well_bias` and `missing_level_shifter` re-derived from their doc over
/// `reach`.
fn biasAndShifters(arena: Allocator, c: *const Circuit, supplies: []const Supply, m: Models) ![2]Judged {
    var bias: std.ArrayList(Found) = .empty;
    var shifters: std.ArrayList(Found) = .empty;
    var bias_examined: u64 = 0;
    var shift_examined: u64 = 0;
    for (0..c.devices.len()) |d| {
        const model = c.devices.model.items[d];
        const source = try reach(arena, c, supplies, at(c, d, .source));
        const drain = try reach(arena, c, supplies, at(c, d, .drain));
        // well_bias: a pmos end above its bulk's lowest, an nmos end below
        // its bulk's highest; examined when the bulk and an end are reached.
        const biased = (model == m.pmos or model == m.nmos) and (source != null or drain != null);
        if (biased) if (try reach(arena, c, supplies, at(c, d, .bulk))) |bulk| {
            var excess: f64 = undefined;
            if (model == m.pmos) {
                var top = -std.math.inf(f64);
                for ([_]?Reach{ source, drain }) |e| if (e) |x| {
                    top = @max(top, x.hi);
                };
                excess = top - bulk.lo;
            } else {
                var bottom = std.math.inf(f64);
                for ([_]?Reach{ source, drain }) |e| if (e) |x| {
                    bottom = @min(bottom, x.lo);
                };
                excess = bulk.hi - bottom;
            }
            bias_examined += 1;
            if (excess > 0.0) try bias.append(arena, .{ .device = d, .measured = excess });
        };
        // missing_level_shifter: power domains that reach a transistor's
        // gate and neither its source nor its drain; examined when power
        // reaches the gate and the channel.
        if (c.devices.kind.items[d] == .mos and model != m.shifter) {
            const gate = if (try reach(arena, c, supplies, at(c, d, .gate))) |g| g.power else 0;
            const chan = (if (source) |s| s.power else 0) | (if (drain) |x| x.power else 0);
            if (gate != 0 and chan != 0) {
                shift_examined += 1;
                const count = @popCount(gate & ~chan);
                if (count > 0) try shifters.append(arena, .{ .device = d, .measured = @floatFromInt(count) });
            }
        }
    }
    return .{ .{ .found = bias.items, .examined = bias_examined }, .{ .found = shifters.items, .examined = shift_examined } };
}

/// One run's findings, read back to the device whose marker they sit on.
fn judged(arena: Allocator, c: *const Circuit, sink: *const common.Sink) !Judged {
    try testing.expectEqual(@as(usize, 1), sink.runs.items.len);
    const found = try arena.alloc(Found, sink.out.len());
    for (found, 0..) |*f, row| {
        const v = sink.out.get(@intCast(row));
        const device = std.mem.indexOfScalar(geom.PolyId, c.devices.marker.items, v.shape_a) orelse return error.OffMarker;
        const measured: f64 = switch (v.measured.kind) {
            .count => @floatFromInt(v.measured.raw),
            .voltage => v.measured.float(),
            .length, .area, .ratio, .current, .resistance => return error.UnexpectedKind,
        };
        f.* = .{ .device = device, .measured = measured };
    }
    std.mem.sort(Found, found, {}, struct {
        fn less(_: void, a: Found, b: Found) bool {
            return a.device < b.device;
        }
    }.less);
    return .{ .found = found, .examined = sink.runs.items[0].examined };
}

test "voltage rules agree with a search from each net" {
    // Oracle: a naive reference over the extracted graph of three hundred
    // generated circuits (`reach`, a breadth-first search from each net, and
    // `biasAndShifters`, the rules' doc), each MOS a `pmos`, an `nmos` or a
    // level shifter at random and each supply in one of three domains at
    // 1.8, 3.3 or 5 V. A supply that propagates onward, a gate or bulk that
    // conducts, or a bias or domain test the wrong way round breaks it.
    var rng = Rng.init(0x9_1003);
    var nonempty: [2]u32 = @splat(0);
    for (0..300) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        var c = try circuit.randomCircuit(&rng, &strings);
        defer c.deinit();
        const m: Models = .{ .pmos = try strings.intern(gpa, "pmos"), .nmos = try strings.intern(gpa, "nmos"), .shifter = try strings.intern(gpa, "shifter") };
        for (c.devices.kind.items, c.devices.model.items) |kind, *model| {
            if (kind == .mos) model.* = ([_]StrId{ m.pmos, m.nmos, m.shifter })[rng.below(3)];
        }
        const supplies = try a.alloc(Supply, c.supplies.items.len);
        for (supplies, c.supplies.items) |*s, spec| s.* = .{ .net = c.net(spec.net), .role = spec.role, .domain = @intCast(rng.below(3)) };
        std.mem.sort(Supply, supplies, {}, struct {
            fn less(_: void, x: Supply, y: Supply) bool {
                return @backingInt(x.net) < @backingInt(y.net);
            }
        }.less);
        var intent: IntentMap = .{ .declared = true };
        defer intent.deinit(gpa);
        for (supplies) |s| {
            try intent.supply_net.append(gpa, s.net);
            try intent.supply_role.append(gpa, s.role);
            try intent.supply_domain.append(gpa, @fromBackingInt(s.domain));
            try intent.supply_voltage.append(gpa, .{ .raw = nominals[s.domain] });
        }
        const id = try strings.intern(gpa, "rule");
        const design = c.design();
        var voltage: erc.voltage.NetVoltage = .{};
        defer voltage.deinit(gpa);
        try erc.voltage.propagateInto(gpa, &c.nets, &c.devices, &intent, &voltage);

        var bias_sink: common.Sink = .{};
        defer bias_sink.deinit();
        {
            var t: erc.domain_tables.WellBiasTable = .{ .head = try common.head(id) };
            defer erc.rule_set.deinitTable(gpa, &t);
            try t.pmos_start.appendSlice(gpa, &.{ 0, 1 });
            try t.pmos.append(gpa, m.pmos);
            try t.nmos_start.appendSlice(gpa, &.{ 0, 1 });
            try t.nmos.append(gpa, m.nmos);
            try erc.domain.checkWellBias(bias_sink.record(), design, &intent, &voltage, &t);
        }
        var shift_sink: common.Sink = .{};
        defer shift_sink.deinit();
        {
            var t: erc.domain_tables.MissingLevelShifterTable = .{ .head = try common.head(id) };
            defer erc.rule_set.deinitTable(gpa, &t);
            try t.shifter_start.appendSlice(gpa, &.{ 0, 1 });
            try t.shifter.append(gpa, m.shifter);
            try erc.domain.checkMissingLevelShifter(shift_sink.record(), design, &intent, &voltage, &t);
        }
        const got = [2]Judged{ try judged(a, &c, &bias_sink), try judged(a, &c, &shift_sink) };
        const want = try biasAndShifters(a, &c, supplies, m);
        for (got, want, &nonempty) |g, w, *n| {
            try testing.expectEqual(w.examined, g.examined);
            try testing.expectEqual(w.found.len, g.found.len);
            for (g.found, w.found) |x, y| {
                try testing.expectEqual(y.device, x.device);
                try testing.expectApproxEqAbs(y.measured, x.measured, 1e-9);
            }
            n.* += @intFromBool(w.found.len > 0);
        }
    }
    for (nonempty) |n| try testing.expect(n >= 10);
}
