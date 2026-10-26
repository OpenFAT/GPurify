//! Five topology rules against a breadth-first search over the extracted
//! net graph, sharing no code with `erc.topology` or `erc.supply`. Ported
//! from tests/exhaustive/erc_reference.rs (`intent_of`, `Expected`,
//! `search`, `findings`,
//! `topology_rules_agree_with_a_search_of_the_extracted_graph`).

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
const report = check.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
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

/// One finding as the reference reads it: its net and its count.
const Found = struct {
    net: u32,
    count: u32,

    fn less(_: void, a: Found, b: Found) bool {
        return if (a.net != b.net) a.net < b.net else a.count < b.count;
    }
};

/// What each rule must find, from the extracted tables alone, nets as
/// extraction numbered them.
const Expected = struct {
    floating: []const Found,
    esd: []const Found,
    drivers: []const Found,
    tied: []const Found,
    fanout: []const Found,
};

/// One device as the search reads it: its model, terminal nets and roles.
const Dev = struct { model: StrId, nets: []const NetId, roles: []const TerminalRole };

/// A transistor's gate and channel ends.
const Channel = struct { gate: u32, ends: [2]u32 };

// ---- private ----

/// Intent declaring `supplies` as `(net, role)`, ascending, every one in a
/// 1.8 V domain.
fn intentOf(nets: []const NetId, roles: []const SupplyRole) !IntentMap {
    var m: IntentMap = .{ .declared = true };
    errdefer m.deinit(gpa);
    var order: [8]usize = undefined;
    for (order[0..nets.len], 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order[0..nets.len], nets, struct {
        fn less(n: []const NetId, a: usize, b: usize) bool {
            return @backingInt(n[a]) < @backingInt(n[b]);
        }
    }.less);
    for (order[0..nets.len]) |i| {
        try m.supply_net.append(gpa, nets[i]);
        try m.supply_role.append(gpa, roles[i]);
        try m.supply_domain.append(gpa, @fromBackingInt(0));
        try m.supply_voltage.append(gpa, .{ .raw = 1800.0 });
    }
    return m;
}

fn roleOf(intent: *const IntentMap, n: u32) ?SupplyRole {
    for (intent.supply_net.items, intent.supply_role.items) |s, role| if (@backingInt(s) == n) return role;
    return null;
}

fn endOf(d: Dev, role: TerminalRole) ?u32 {
    for (d.nets, d.roles) |net, r| if (std.meta.eql(r, role)) return @backingInt(net);
    return null;
}

/// A diode clamp counts only when operation cannot forward-bias it: a
/// ground at 0 mV, a power supply at 1800 mV, the other net strictly
/// between. Between two supplies, or two other nets, it is taken as wired.
fn forward(intent: *const IntentMap, d: Dev) bool {
    const anode = endOf(d, .{ .pin = 0 }) orelse return false;
    const cathode = endOf(d, .{ .pin = 1 }) orelse return false;
    const a = roleOf(intent, anode);
    const c = roleOf(intent, cathode);
    if ((a == null) == (c == null)) return false;
    if (a) |role| return role == .power;
    return c.? == .ground;
}

/// The five rules re-derived from their documentation over the extracted
/// net graph.
fn search(arena: Allocator, c: *const Circuit, intent: *const IntentMap, clamp: StrId) !Expected {
    const nets = c.nets.netCount();
    const devs = try arena.alloc(Dev, c.devices.len());
    for (devs, 0..) |*d, i| {
        const t = c.devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(i))));
        d.* = .{ .model = c.devices.model.items[i], .nets = t.nets, .roles = t.roles };
    }
    var floating: std.ArrayList(Found) = .empty;
    var tied: std.ArrayList(Found) = .empty;
    var fanout: std.ArrayList(Found) = .empty;
    for (0..nets) |nn| {
        const n: u32 = @intCast(nn);
        // floating_gate: every terminal on the net is a gate, and there is one.
        // tie_high_low: a rail that reaches a gate. fanout: two gates or more.
        var gates: u32 = 0;
        var others: u32 = 0;
        for (devs) |d| for (d.nets, d.roles) |net, r| {
            if (@backingInt(net) != n) continue;
            if (std.meta.eql(r, TerminalRole.gate)) gates += 1 else others += 1;
        };
        if (gates > 0 and others == 0) try floating.append(arena, .{ .net = n, .count = 0 });
        if (roleOf(intent, n) != null and gates > 0) try tied.append(arena, .{ .net = n, .count = 0 });
        if (gates > 1) try fanout.append(arena, .{ .net = n, .count = gates });
    }

    // esd_topological, every net a pad: from the pad through any terminal of
    // a clamp; onward only from a supply.
    var esd: std.ArrayList(Found) = .empty;
    const seen = try arena.alloc(bool, nets);
    var queue: std.ArrayList(u32) = .empty;
    for (0..nets) |pp| {
        const pad: u32 = @intCast(pp);
        @memset(seen, false);
        queue.clearRetainingCapacity();
        try queue.append(arena, pad);
        seen[pad] = true;
        var power = false;
        var ground = false;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const net = queue.items[head];
            if (roleOf(intent, net)) |role| switch (role) {
                .power => power = true,
                .ground => ground = true,
            } else if (net != pad) continue;
            for (devs) |d| {
                if (d.model != clamp or forward(intent, d)) continue;
                const touches = for (d.nets) |t| {
                    if (@backingInt(t) == net) break true;
                } else false;
                if (!touches) continue;
                for (d.nets) |t| if (!seen[@backingInt(t)]) {
                    seen[@backingInt(t)] = true;
                    try queue.append(arena, @backingInt(t));
                };
            }
        }
        const rails = @as(u32, @intFromBool(power)) + @intFromBool(ground);
        if (rails < 2) try esd.append(arena, .{ .net = pad, .count = rails });
    }

    // multiple_drivers: a transistor with a channel end on a non-rail net
    // pulls it when a search from its other end, through every transistor
    // with a channel end on the nets reached, stopping at rails and never
    // back through the net, reaches a rail; networks sharing a gate net are
    // one driver.
    var channels: std.ArrayList(Channel) = .empty;
    for (devs) |d| {
        const g = endOf(d, .gate) orelse continue;
        const s = endOf(d, .source) orelse continue;
        const dr = endOf(d, .drain) orelse continue;
        try channels.append(arena, .{ .gate = g, .ends = .{ s, dr } });
    }
    var drivers: std.ArrayList(Found) = .empty;
    for (0..nets) |nn| {
        const n: u32 = @intCast(nn);
        if (roleOf(intent, n) != null) continue;
        var networks: std.ArrayList([]const u32) = .empty;
        for (channels.items) |ch| {
            if (ch.ends[0] != n and ch.ends[1] != n) continue;
            var gates: std.ArrayList(u32) = .empty;
            try gates.append(arena, ch.gate);
            @memset(seen, false);
            queue.clearRetainingCapacity();
            try queue.append(arena, far(ch.ends, n));
            var reached = false;
            var head: usize = 0;
            while (head < queue.items.len) : (head += 1) {
                const at = queue.items[head];
                if (at == n or seen[at]) continue;
                seen[at] = true;
                if (roleOf(intent, at) != null) {
                    reached = true;
                    continue;
                }
                for (channels.items) |e| if (e.ends[0] == at or e.ends[1] == at) {
                    try gates.append(arena, e.gate);
                    try queue.append(arena, far(e.ends, at));
                };
            }
            if (reached) try networks.append(arena, gates.items);
        }
        const classes = try classCount(arena, networks.items);
        if (classes > 1) try drivers.append(arena, .{ .net = n, .count = classes });
    }
    return .{ .floating = floating.items, .esd = esd.items, .drivers = drivers.items, .tied = tied.items, .fanout = fanout.items };
}

fn far(ends: [2]u32, n: u32) u32 {
    return if (ends[0] == n) ends[1] else ends[0];
}

/// The classes of `networks` under "shares a gate net".
fn classCount(arena: Allocator, networks: []const []const u32) !u32 {
    const class = try arena.alloc(usize, networks.len);
    for (class, 0..) |*x, i| x.* = i;
    var merged = true;
    while (merged) {
        merged = false;
        for (networks, 0..) |a, i| for (networks, 0..) |b, j| {
            if (class[j] <= class[i]) continue;
            const shares = for (a) |g| {
                if (std.mem.indexOfScalar(u32, b, g) != null) break true;
            } else false;
            if (!shares) continue;
            const old = class[j];
            const new = class[i];
            for (class) |*x| if (x.* == old) {
                x.* = new;
            };
            merged = true;
        };
    }
    std.mem.sort(usize, class, {}, std.sort.asc(usize));
    var distinct: u32 = 0;
    for (class, 0..) |x, i| distinct += @intFromBool(i == 0 or x != class[i - 1]);
    return distinct;
}

/// The findings of one run, sorted; each marker's shape is its net's
/// lowest-numbered polygon as laid out.
fn findings(arena: Allocator, c: *const Circuit, out: *const Violations, runs: []const RuleRun) ![]const Found {
    try testing.expectEqual(@as(usize, 1), runs.len);
    const found = try arena.alloc(Found, out.len());
    for (found, 0..) |*f, row| {
        const v = out.get(@intCast(row));
        try testing.expectEqual(report.Kind.count, v.measured.kind);
        const n = c.nets.netOf(v.shape_a);
        const lowest = for (c.case.expected_net_polys, 0..) |polys, k| {
            if (c.net(@intCast(k)) == n) break polys[0];
        } else null;
        try testing.expectEqual(lowest, v.shape_a);
        f.* = .{ .net = @backingInt(n), .count = @intCast(v.measured.raw) };
    }
    std.mem.sort(Found, found, {}, Found.less);
    return found;
}

test "topology rules agree with a search of the extracted graph" {
    // Oracle: a breadth-first search over the extracted net graph. On three
    // hundred generated circuits, each rule finds exactly the nets, with the
    // counts, that `search` derives from the rules' documentation, every
    // finding at its net's lowest-numbered polygon as laid out.
    var rng = Rng.init(0xc6_0002);
    var nonempty: [5]u32 = @splat(0);
    for (0..300) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        var c = try circuit.randomCircuit(&rng, &strings);
        defer c.deinit();
        var supply_nets: [8]NetId = undefined;
        var supply_roles: [8]SupplyRole = undefined;
        for (c.supplies.items, 0..) |s, i| {
            supply_nets[i] = c.net(s.net);
            supply_roles[i] = s.role;
        }
        var intent = try intentOf(supply_nets[0..c.supplies.items.len], supply_roles[0..c.supplies.items.len]);
        defer intent.deinit(gpa);
        const clamp = try strings.intern(gpa, "clamp");
        const id = try strings.intern(gpa, "rule");
        const design = c.design();
        var facts: erc.facts.NetFacts = .{};
        defer facts.deinit(gpa);
        try erc.facts.classifyNetsInto(gpa, &c.nets, &c.devices, &facts);
        const want = try search(a, &c, &intent, clamp);

        var head = try common.head(id);
        defer head.deinit(gpa);
        var got: [5][]const Found = undefined;
        for (0..5) |k| {
            var sink: common.Sink = .{};
            defer sink.deinit();
            const r = sink.record();
            switch (k) {
                0 => {
                    var t: erc.topology_tables.FloatingGateTable = .{ .head = head };
                    defer t.labels_are_ports.deinit(gpa);
                    try t.labels_are_ports.append(gpa, false);
                    var ports: topology.PortTable = .{};
                    try erc.topology.checkFloatingGate(r, design, &facts, &ports, &t);
                },
                1 => {
                    var t: erc.supply_tables.EsdTopologicalTable = .{ .head = head };
                    defer t.pad.deinit(gpa);
                    defer t.clamp_start.deinit(gpa);
                    defer t.clamp.deinit(gpa);
                    try t.pad.append(gpa, c.case.layers.rail);
                    try t.clamp_start.appendSlice(gpa, &.{ 0, 1 });
                    try t.clamp.append(gpa, clamp);
                    try erc.supply.checkEsdTopological(r, design, &intent, &t);
                },
                2 => {
                    var t: erc.topology_tables.MultipleDriversTable = .{ .head = head };
                    defer t.max_drivers.deinit(gpa);
                    try t.max_drivers.append(gpa, 1);
                    var scratch: erc.scratch.Scratch = .{};
                    defer scratch.deinit(gpa);
                    try erc.topology.checkMultipleDrivers(r, design, &intent, &t, &scratch);
                },
                3 => {
                    const t: erc.supply_tables.TieHighLowTable = .{ .head = head };
                    try erc.supply.checkTieHighLow(r, design, &facts, &intent, &t);
                },
                else => {
                    var t: erc.topology_tables.FanoutTable = .{ .head = head };
                    defer t.max_gates.deinit(gpa);
                    try t.max_gates.append(gpa, 1);
                    try erc.topology.checkFanout(r, design, &t);
                },
            }
            got[k] = try findings(a, &c, &sink.out, sink.runs.items);
        }
        const wants = [5][]const Found{ want.floating, want.esd, want.drivers, want.tied, want.fanout };
        for (got, wants, &nonempty) |g, w, *seen| {
            try testing.expectEqualSlices(Found, w, g);
            seen.* += @intFromBool(w.len > 0);
        }
    }
    for (nonempty) |n| try testing.expect(n >= 20);
}
