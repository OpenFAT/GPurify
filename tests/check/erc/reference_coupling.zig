//! `esd_ground_coupling` and `esd_cross_domain` against naive closures over
//! the extracted net graph, sharing no code with `erc.esd` or
//! `erc.voltage`. Ported from tests/exhaustive/erc_reference.rs
//! (`coupling_circuit`, `ground_groups`, `domain_circuit`,
//! `ground_coupling_agrees_with_a_closure_over_the_extracted_graph`,
//! `cross_domain_agrees_with_a_reach_fixpoint`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const StrTable = geom.StrTable;
const Rng = testgen.Rng;
const nl = testgen.netlist;
const NetId = check.topology.NetId;
const TerminalRole = check.topology.TerminalRole;
const Terminals = check.topology.device.Terminals;
const SupplyRole = ingest.intent.SupplyRole;
const erc = check.erc;
const IntentMap = erc.facts.IntentMap;
const circuit = @import("reference_circuit.zig");
const Circuit = circuit.Circuit;
const SupplySpec = circuit.SupplySpec;
const common = @import("common.zig");
const gpa = common.gpa;

/// A diode as the closure reads it: anode and cathode nets.
const Diode = struct { anode: NetId, cathode: NetId };

/// A supply row: its net, role and domain.
const Row = struct { net: NetId, role: SupplyRole, domain: u32 };

// ---- private ----

/// Two to five grounds and a power supply on eight to twelve nets, and
/// diodes of model `clamp`: between two random grounds, an anti-parallel
/// pair one time in two and a single diode otherwise, and a few more on
/// random nets.
fn couplingCircuit(rng: *Rng, strings: *StrTable) !Circuit {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nets: u32 = 8 + @as(u32, @intCast(rng.below(5)));
    const grounds: u32 = 2 + @as(u32, @intCast(rng.below(4)));
    var supplies: std.ArrayList(SupplySpec) = .empty;
    for (0..grounds) |n| try supplies.append(a, .{ .net = @intCast(n), .role = .ground });
    try supplies.append(a, .{ .net = grounds, .role = .power });
    var devices: std.ArrayList(nl.DeviceSpec) = .empty;
    for (0..rng.below(grounds + 1)) |_| {
        const an: u32 = @intCast(rng.below(grounds));
        const ca: u32 = @intCast(rng.below(grounds));
        try devices.append(a, try diode(a, an, ca));
        if (rng.below(2) == 0) try devices.append(a, try diode(a, ca, an));
    }
    for (0..rng.below(4)) |_| {
        const an: u32 = @intCast(rng.below(nets));
        const ca: u32 = @intCast(rng.below(nets));
        try devices.append(a, try diode(a, an, ca));
    }
    if (devices.items.len == 0) try devices.append(a, try diode(a, nets - 1, nets - 2));
    return circuit.built(nets, devices.items, supplies.items, strings);
}

fn diode(a: Allocator, anode: u32, cathode: u32) !nl.DeviceSpec {
    const t = try a.alloc(nl.TerminalSpec, 2);
    t[0] = .{ .role = .{ .pin = 0 }, .net = anode };
    t[1] = .{ .role = .{ .pin = 1 }, .net = cathode };
    return .{ .kind = .diode, .model = "clamp", .terminals = t };
}

/// Ground groups of `grounds` (ascending): two merge while an anti-parallel
/// pair of `diodes` joins a member of each. One label per ground, the
/// lowest index of its group.
fn groundGroups(arena: Allocator, grounds: []const NetId, diodes: []const Diode) ![]usize {
    const group = try arena.alloc(usize, grounds.len);
    for (group, 0..) |*g, i| g.* = i;
    while (true) {
        var merged = false;
        for (grounds, 0..) |gi, i| for (grounds, 0..) |gj, j| {
            const pair = contains(diodes, gi, gj) and contains(diodes, gj, gi);
            if (!pair or group[i] == group[j]) continue;
            const old = @max(group[i], group[j]);
            const new = @min(group[i], group[j]);
            for (group) |*g| if (g.* == old) {
                g.* = new;
            };
            merged = true;
        };
        if (!merged) return group;
    }
}

fn contains(diodes: []const Diode, anode: NetId, cathode: NetId) bool {
    for (diodes) |d| if (d.anode == anode and d.cathode == cathode) return true;
    return false;
}

fn lessNet(_: void, x: NetId, y: NetId) bool {
    return @backingInt(x) < @backingInt(y);
}

/// Two or three domains, each a power and a ground supply, on ten to
/// fourteen nets; six to nineteen transistors with every terminal on any
/// net; anti-parallel pairs and single diodes (`clamp`) between the grounds.
fn domainCircuit(arena: Allocator, rng: *Rng, strings: *StrTable, domain_of: *std.ArrayList(u32)) !Circuit {
    const domains: u32 = 2 + @as(u32, @intCast(rng.below(2)));
    const nets: u32 = 10 + @as(u32, @intCast(rng.below(5)));
    var supplies: std.ArrayList(SupplySpec) = .empty;
    for (0..domains) |dd| {
        const d: u32 = @intCast(dd);
        try supplies.append(arena, .{ .net = 2 * d, .role = .power });
        try supplies.append(arena, .{ .net = 2 * d + 1, .role = .ground });
        try domain_of.appendSlice(arena, &.{ d, d });
    }
    var devices: std.ArrayList(nl.DeviceSpec) = .empty;
    for (0..6 + rng.below(14)) |_| {
        const t = try arena.alloc(nl.TerminalSpec, 4);
        for (t, [_]TerminalRole{ .gate, .source, .drain, .bulk }) |*x, role| x.* = .{ .role = role, .net = @intCast(rng.below(nets)) };
        try devices.append(arena, .{ .kind = .mos, .model = "mos", .terminals = t });
    }
    // Each pair of grounds: an anti-parallel pair one time in two, a single
    // diode one time in four, nothing otherwise.
    for (0..domains) |x| for (x + 1..domains) |y| {
        const ga: u32 = @intCast(2 * x + 1);
        const gc: u32 = @intCast(2 * y + 1);
        switch (rng.below(4)) {
            0 => {},
            1 => try devices.append(arena, try diode(arena, ga, gc)),
            else => {
                try devices.append(arena, try diode(arena, ga, gc));
                try devices.append(arena, try diode(arena, gc, ga));
            },
        }
    };
    return circuit.built(nets, devices.items, supplies.items, strings);
}

fn terminalsOf(c: *const Circuit, d: usize) Terminals {
    return c.devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
}

fn channel(role: TerminalRole) bool {
    return switch (role) {
        .gate, .bulk => false,
        .source, .drain, .base, .emitter, .collector, .pin => true,
    };
}

fn supplyRow(rows: []const Row, n: NetId) ?Row {
    for (rows) |r| if (r.net == n) return r;
    return null;
}

fn roleNet(t: Terminals, role: TerminalRole) ?NetId {
    for (t.nets, t.roles) |n, r| if (std.meta.eql(r, role)) return n;
    return null;
}

/// A net's power and ground domain bits: its own as a supply, else its
/// component's reach.
fn masks(rows: []const Row, comp: []const usize, reach: []const [2]u64, n: NetId) [2]u64 {
    if (supplyRow(rows, n)) |s| {
        const bit = @as(u64, 1) << @intCast(s.domain);
        return if (s.role == .power) .{ bit, 0 } else .{ 0, bit };
    }
    return reach[comp[@backingInt(n)]];
}

/// Domains `x` and `y` are coupled when equal, or a ground of each shares a
/// group.
fn coupledDomains(ground_domain: []const u32, group: []const usize, x: u32, y: u32) bool {
    if (x == y) return true;
    for (ground_domain, group) |di, gi| for (ground_domain, group) |dj, gj| {
        if (di == x and dj == y and gi == gj) return true;
    };
    return false;
}

fn lessPoly(_: void, x: geom.PolyId, y: geom.PolyId) bool {
    return @backingInt(x) < @backingInt(y);
}

test "ground coupling agrees with a closure over the extracted graph" {
    // Oracle: a naive closure over the extracted net graph. On three hundred
    // generated circuits, the declared grounds start as groups of one, and
    // any two groups merge while an anti-parallel pair of `clamp` diodes
    // (anode on one ground and cathode on the other, and another the other
    // way round, as extraction bound them) joins a member of each.
    // `esd_ground_coupling` flags exactly each group but the one holding the
    // lowest-numbered ground, at its lowest-numbered ground.
    var rng = Rng.init(0xc6_0004);
    var flagged: u32 = 0;
    var coupled: u32 = 0;
    for (0..300) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        var c = try couplingCircuit(&rng, &strings);
        defer c.deinit();
        const clamp = try strings.intern(gpa, "clamp");
        const id = try strings.intern(gpa, "rule");

        // The intent: every supply in one 1.8 V domain, ascending by net.
        const nets = try a.alloc(NetId, c.supplies.items.len);
        for (nets, c.supplies.items) |*n, s| n.* = c.net(s.net);
        const order = try a.alloc(usize, nets.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, nets, struct {
            fn less(n: []const NetId, x: usize, y: usize) bool {
                return @backingInt(n[x]) < @backingInt(n[y]);
            }
        }.less);
        var intent: IntentMap = .{ .declared = true };
        defer intent.deinit(gpa);
        var grounds: std.ArrayList(NetId) = .empty;
        for (order) |i| {
            const role: SupplyRole = c.supplies.items[i].role;
            try intent.supply_net.append(gpa, nets[i]);
            try intent.supply_role.append(gpa, role);
            try intent.supply_domain.append(gpa, @fromBackingInt(0));
            try intent.supply_voltage.append(gpa, .{ .raw = 1800.0 });
            if (role == .ground) try grounds.append(a, nets[i]);
        }

        var diodes: std.ArrayList(Diode) = .empty;
        for (0..c.devices.len()) |d| {
            if (c.devices.model.items[d] != clamp or c.devices.kind.items[d] != .diode) continue;
            const t = c.devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            var pins: [2]NetId = undefined;
            for (t.nets, t.roles) |n, role| switch (role) {
                .pin => |k| pins[k] = n,
                .gate, .source, .drain, .bulk, .base, .emitter, .collector => {},
            };
            try diodes.append(a, .{ .anode = pins[0], .cathode = pins[1] });
        }
        const group = try groundGroups(a, grounds.items, diodes.items);
        var seen: std.ArrayList(usize) = .empty;
        var want: std.ArrayList(NetId) = .empty;
        for (group, 0..) |g, i| {
            if (std.mem.indexOfScalar(usize, seen.items, g) != null) continue;
            if (seen.items.len > 0) try want.append(a, grounds.items[i]);
            try seen.append(a, g);
        }

        var sink: common.Sink = .{};
        defer sink.deinit();
        var t: erc.esd_tables.EsdGroundCouplingTable = .{ .head = try common.head(id) };
        defer erc.rule_set.deinitTable(gpa, &t);
        try t.diode_start.appendSlice(gpa, &.{ 0, 1 });
        try t.diode.append(gpa, clamp);
        try erc.esd.checkEsdGroundCoupling(sink.record(), c.design(), &intent, &t);
        const got = try a.alloc(NetId, sink.out.len());
        for (got, 0..) |*n, row| n.* = c.nets.netOf(sink.out.get(@intCast(row)).shape_a);
        std.mem.sort(NetId, got, {}, lessNet);
        std.mem.sort(NetId, want.items, {}, lessNet);
        try testing.expectEqualSlices(NetId, want.items, got);
        flagged += @intFromBool(want.items.len > 0);
        coupled += @intFromBool(seen.items.len < grounds.items.len);
    }
    try testing.expect(flagged >= 20 and coupled >= 20);
}

test "cross domain agrees with a reach fixpoint" {
    // Oracle: a fixpoint of the supplies' reach and a naive closure over the
    // grounds. On six hundred generated multi-domain circuits, each net's
    // power and ground domains are found from the doc of `erc.voltage`
    // (non-supply nets on one device's channel, a MOS source and drain or a
    // diode's pins, share their reach, relabelled to a fixpoint; a supply on
    // a channel reaches the other channel nets), and a receiver is a MOS
    // whose gate sees a power domain its channel does not.
    // `esd_cross_domain` flags exactly the receivers with a driver ground and
    // a receiver ground of different domains in different groups.
    var rng = Rng.init(0xc6_0005);
    var flagged: u32 = 0;
    var protected: u32 = 0;
    for (0..600) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        var domain_of: std.ArrayList(u32) = .empty;
        var c = try domainCircuit(a, &rng, &strings, &domain_of);
        defer c.deinit();
        const clamp = try strings.intern(gpa, "clamp");
        const id = try strings.intern(gpa, "rule");

        const rows = try a.alloc(Row, c.supplies.items.len);
        for (rows, c.supplies.items, domain_of.items) |*r, s, d| r.* = .{ .net = c.net(s.net), .role = s.role, .domain = d };
        std.mem.sort(Row, rows, {}, struct {
            fn less(_: void, x: Row, y: Row) bool {
                return @backingInt(x.net) < @backingInt(y.net);
            }
        }.less);
        var intent: IntentMap = .{ .declared = true };
        defer intent.deinit(gpa);
        for (rows) |r| {
            try intent.supply_net.append(gpa, r.net);
            try intent.supply_role.append(gpa, r.role);
            try intent.supply_domain.append(gpa, @fromBackingInt(r.domain));
            try intent.supply_voltage.append(gpa, .{ .raw = 1800.0 });
        }

        // Reach, from the definition: channel nets that are no supply share
        // one component, relabelled to a fixpoint.
        const count = c.nets.netCount();
        const comp = try a.alloc(usize, count);
        for (comp, 0..) |*x, i| x.* = i;
        var changed = true;
        while (changed) {
            changed = false;
            for (0..c.devices.len()) |d| {
                const t = terminalsOf(&c, d);
                var low: ?usize = null;
                for (t.nets, t.roles) |n, role| if (channel(role) and supplyRow(rows, n) == null) {
                    low = @min(low orelse comp[@backingInt(n)], comp[@backingInt(n)]);
                };
                for (t.nets, t.roles) |n, role| if (channel(role) and supplyRow(rows, n) == null and low.? < comp[@backingInt(n)]) {
                    comp[@backingInt(n)] = low.?;
                    changed = true;
                };
            }
        }
        const reach = try a.alloc([2]u64, count);
        @memset(reach, .{ 0, 0 });
        for (0..c.devices.len()) |d| {
            const t = terminalsOf(&c, d);
            for (t.nets, t.roles) |sn, sr| {
                if (!channel(sr)) continue;
                const s = supplyRow(rows, sn) orelse continue;
                const bit = @as(u64, 1) << @intCast(s.domain);
                for (t.nets, t.roles) |n, role| if (channel(role) and supplyRow(rows, n) == null) {
                    reach[comp[@backingInt(n)]][@intFromBool(s.role == .ground)] |= bit;
                };
            }
        }
        // Ground groups, then domains coupled when a ground of each shares one.
        var grounds: std.ArrayList(NetId) = .empty;
        var ground_domain: std.ArrayList(u32) = .empty;
        for (rows) |r| if (r.role == .ground) {
            try grounds.append(a, r.net);
            try ground_domain.append(a, r.domain);
        };
        var diodes: std.ArrayList(Diode) = .empty;
        for (0..c.devices.len()) |d| {
            if (c.devices.kind.items[d] != .diode or c.devices.model.items[d] != clamp) continue;
            const t = terminalsOf(&c, d);
            var pins: [2]NetId = undefined;
            for (t.nets, t.roles) |n, role| switch (role) {
                .pin => |k| pins[k] = n,
                .gate, .source, .drain, .bulk, .base, .emitter, .collector => {},
            };
            try diodes.append(a, .{ .anode = pins[0], .cathode = pins[1] });
        }
        const group = try groundGroups(a, grounds.items, diodes.items);
        var want: std.ArrayList(geom.PolyId) = .empty;
        for (0..c.devices.len()) |d| {
            if (c.devices.kind.items[d] != .mos) continue;
            const t = terminalsOf(&c, d);
            const g = roleNet(t, .gate) orelse continue;
            const s = roleNet(t, .source) orelse continue;
            const dr = roleNet(t, .drain) orelse continue;
            const gm = masks(rows, comp, reach, g);
            const sm = masks(rows, comp, reach, s);
            const dm = masks(rows, comp, reach, dr);
            const cp = sm[0] | dm[0];
            const cg = sm[1] | dm[1];
            if (gm[0] == 0 or cp == 0 or gm[0] & ~cp == 0 or gm[1] == 0 or cg == 0) continue;
            var all = true;
            for (0..64) |x| for (0..64) |y| {
                if ((gm[1] >> @intCast(x)) & 1 == 0 or (cg >> @intCast(y)) & 1 == 0) continue;
                if (!coupledDomains(ground_domain.items, group, @intCast(x), @intCast(y))) all = false;
            };
            if (all) protected += 1 else try want.append(a, c.devices.marker.items[d]);
        }

        var voltage: erc.voltage.NetVoltage = .{};
        defer voltage.deinit(gpa);
        try erc.voltage.propagateInto(gpa, &c.nets, &c.devices, &intent, &voltage);
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t: erc.esd_tables.EsdCrossDomainTable = .{ .head = try common.head(id) };
        defer erc.rule_set.deinitTable(gpa, &t);
        try t.diode_start.appendSlice(gpa, &.{ 0, 1 });
        try t.diode.append(gpa, clamp);
        try t.local_start.appendSlice(gpa, &.{ 0, 0 });
        try t.resistor_start.appendSlice(gpa, &.{ 0, 0 });
        try t.min_series.append(gpa, null);
        try t.max_ground_resistance.append(gpa, null);
        try t.coupling_resistance.append(gpa, null);
        // No series or ground limit: the process is never read.
        const stack: ingest.deck.ProcessStack = .{};
        const connectivity: ingest.deck.Connectivity = .{};
        var scratch: erc.scratch.Scratch = .{};
        defer scratch.deinit(gpa);
        try erc.esd.checkEsdCrossDomain(sink.record(), c.design(), &intent, &voltage, .{ .grid = common.manufacturingGrid(), .stack = &stack, .connectivity = &connectivity }, &t, &scratch);
        const got = try a.alloc(geom.PolyId, sink.out.len());
        for (got, 0..) |*p, row| p.* = sink.out.get(@intCast(row)).shape_a;
        std.mem.sort(geom.PolyId, got, {}, lessPoly);
        std.mem.sort(geom.PolyId, want.items, {}, lessPoly);
        try testing.expectEqualSlices(geom.PolyId, want.items, got);
        flagged += @intFromBool(want.items.len > 0);
    }
    try testing.expect(flagged >= 20 and protected >= 20);
}
