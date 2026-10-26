//! The six intent-gated rules, run both ways over the same design: without
//! declared intent each records `skipped(no_design_intent)`, with it each
//! examines something. A test covering only the second half would pass
//! against exactly the silent-clean bug the gate exists to prevent. Ported
//! from crates/check/tests/erc/intent_gate.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const ingest = @import("ingest");
const common = @import("common.zig");
const gpa = common.gpa;
const erc = check.erc;
const report = check.report;
const topology = check.topology;
const NetId = topology.NetId;
const NetTable = topology.NetTable;
const DeviceTable = topology.DeviceTable;
const IntentMap = erc.facts.IntentMap;
const NetVoltage = erc.voltage.NetVoltage;
const Power = erc.power_grid.Power;
const el = erc.electrical_tables;
const esd = erc.esd_tables;
const nl = testgen.netlist;

/// A supply grid and its solution, so the four solve-reading rules have
/// something real to be gated over.
const Powered = struct {
    grid: erc.power_grid.PowerGrid,
    solution: erc.power_grid.PowerSolution,

    fn init() !Powered {
        var grid = try common.seriesChain(4, 2.5, 1_800.0, 1_000.0);
        errdefer grid.deinit(gpa);
        return .{ .grid = grid, .solution = try common.solve(&grid) };
    }

    fn deinit(p: *Powered) void {
        p.grid.deinit(gpa);
        p.solution.deinit(gpa);
    }

    fn solved(p: *const Powered) Power {
        return .{ .solved = .{ .grid = &p.grid, .solution = &p.solution } };
    }
};

/// One MOS with each terminal on its own net, extracted from a layout
/// emitted from that netlist.
const OneTransistor = struct {
    strings: geom.StrTable = .empty,
    case: nl.NetlistCase = undefined,
    nets: NetTable = .{},
    devices: DeviceTable = .{},

    fn init(t: *OneTransistor) !void {
        t.* = .{};
        const spec: nl.NetlistSpec = .{ .nets = 4, .devices = &.{.{ .kind = .mos, .model = "nch", .terminals = &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 }, .{ .role = .drain, .net = 2 }, .{ .role = .bulk, .net = 3 } } }} };
        t.case = try nl.layoutFromNetlist(gpa, spec, .{}, &t.strings);
        try topology.extractNetsInto(gpa, &t.case.store, &t.case.connectivity, &t.nets);
        try topology.recogniseInto(gpa, &t.case.store, &t.nets, &t.case.recognition, &t.devices);
    }

    fn deinit(t: *OneTransistor) void {
        t.devices.deinit(gpa);
        t.nets.deinit(gpa);
        t.case.deinit(gpa);
        t.strings.deinit(gpa);
    }

    fn design(t: *const OneTransistor) erc.head.Design {
        return .{ .store = &t.case.store, .nets = &t.nets, .devices = &t.devices };
    }

    /// The extracted net id of the netlist's net `n`.
    fn netOf(t: *const OneTransistor, n: usize) NetId {
        return t.nets.netOf(t.case.expected_net_polys[n][0]);
    }

    /// Intent declaring every one of the four nets, at the given millivolts.
    fn fourDomains(t: *const OneTransistor, millivolt: [4]f64) !IntentMap {
        var rows: [4]struct { NetId, f64 } = undefined;
        for (&rows, 0..) |*row, n| row.* = .{ t.netOf(n), millivolt[n] };
        std.mem.sortUnstable(@TypeOf(rows[0]), &rows, {}, struct {
            fn less(_: void, a: @TypeOf(rows[0]), b: @TypeOf(rows[0])) bool {
                return @backingInt(a[0]) < @backingInt(b[0]);
            }
        }.less);
        var m: IntentMap = .{ .declared = true };
        errdefer m.deinit(gpa);
        for (rows, 0..) |row, d| {
            try m.supply_net.append(gpa, row[0]);
            try m.supply_role.append(gpa, if (row[1] > 0.0) .power else .ground);
            try m.supply_domain.append(gpa, @fromBackingInt(@as(u32, @intCast(d))));
            try m.supply_voltage.append(gpa, .{ .raw = row[1] });
        }
        return m;
    }
};

// ---- private ----

/// Intent declaring the grid's one net a supply, with drop limits on it.
fn supplyIntent() !IntentMap {
    var m = try common.declaredSupplies(@fromBackingInt(0), @fromBackingInt(1), 1_800.0);
    errdefer m.deinit(gpa);
    try common.limitNet(&m, @fromBackingInt(0), .{ .max_drop = .{ .raw = 6.0 }, .max_drop_fraction = 0.05, .max_overvoltage = .{ .raw = 100.0 }, .budget_current_ua = 1_000.0 });
    return m;
}

/// A one-row electromigration table. `reference_temperature` is kelvin:
/// 358.15 K is 85 °C.
fn electromigrationTable(id: geom.StrId, layer: geom.LayerId) !el.ElectromigrationTable {
    var t: el.ElectromigrationTable = .{ .head = try common.head(id) };
    try t.layer_start.appendSlice(gpa, &.{ 0, 1 });
    try t.layer.append(gpa, layer);
    try t.max_density.append(gpa, .{ .raw = 1e6 });
    try t.max_current_per_cut.append(gpa, .{ .raw = 200.0 });
    try t.blech_limit.append(gpa, .{ .raw = 1.0 });
    try t.reference_temperature.append(gpa, .{ .raw = 358.15 });
    try t.activation_energy_ev.append(gpa, 0.7);
    try t.current_exponent.append(gpa, 2.0);
    return t;
}

fn reliabilityTable(id: geom.StrId) !esd.ReliabilityTable {
    var t: esd.ReliabilityTable = .{ .head = try common.head(id) };
    try t.required_lifetime_hours.append(gpa, 87_600.0);
    try t.reference_lifetime_hours.append(gpa, 10_000.0);
    try t.reference_stress.append(gpa, .{ .raw = 2_000.0 });
    try t.stress_exponent.append(gpa, 4.0);
    try t.reference_temperature.append(gpa, .{ .raw = 398.15 });
    try t.activation_energy_ev.append(gpa, 0.6);
    try t.duty_cycle.append(gpa, 0.5);
    try t.max_abs_voltage.append(gpa, .{ .raw = 1_950.0 });
    return t;
}

test "no intent file resolves to a map that says nothing was declared" {
    // Oracle: construct-from-answer. `resolveIntentInto` is the single place
    // the optional becomes a table, and `declared` the flag six rules read
    // first: no intent file gives a map that says so, and is not usable.
    const ports: topology.PortTable = .{};
    const nets: NetTable = .{};
    var m: IntentMap = .{};
    defer m.deinit(gpa);
    try erc.facts.resolveIntentInto(gpa, null, &ports, &nets, &m);
    try testing.expect(!m.declared);
    try testing.expect(!m.isUsable());
    try testing.expectEqual(null, m.nominalVoltage(@fromBackingInt(0)));
    const limits = m.limitsOf(@fromBackingInt(0));
    try testing.expect(limits.max_drop == null and limits.max_drop_fraction == null and limits.max_overvoltage == null and limits.budget_current_ua == null);
}

test "a map holding declared supplies is usable and answers only about them" {
    // Oracle: construct-from-answer. A lookup that answered about an
    // undeclared net would hand a gated rule a voltage nobody stated.
    var m = try supplyIntent();
    defer m.deinit(gpa);
    try testing.expect(m.declared);
    try testing.expect(m.isUsable());
    try testing.expectEqual(@as(f64, 1_800.0), m.nominalVoltage(@fromBackingInt(0)).?.raw);
    try testing.expectEqual(null, m.nominalVoltage(@fromBackingInt(7)));
    try testing.expectEqual(@as(f64, 6.0), m.limitsOf(@fromBackingInt(0)).max_drop.?.raw);
    try testing.expectEqual(null, m.limitsOf(@fromBackingInt(1)).max_drop);
}

test "ir drop skips without intent and examines every limited node with it" {
    // Oracle: construct-from-answer, on the gate. No solve, or a solve with
    // nothing declared, give the same loud skip; with both the rule examines
    // the chain's five nodes, all on the one limited net.
    var powered = try Powered.init();
    defer powered.deinit();
    const id = common.rule(10);
    var t: el.IrDropTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    var intent = try supplyIntent();
    defer intent.deinit(gpa);
    const none: IntentMap = .{};
    for ([_]struct { Power, *const IntentMap }{ .{ .no_supply, &intent }, .{ powered.solved(), &none } }) |c| {
        var sink: common.Sink = .{};
        defer sink.deinit();
        try erc.electrical.checkIrDrop(sink.record(), c[0], c[1], &t);
        try common.assertSkippedForIntent(sink.runs.items, &sink.out, id);
    }
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.electrical.checkIrDrop(sink.record(), powered.solved(), &intent, &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u64, 5), r.examined);
}

test "em current density skips without intent and examines limited edges with it" {
    // Oracle: construct-from-answer, on the gate. No branch currents without
    // a solve; with one, the rule examines the four edges on its layer.
    var powered = try Powered.init();
    defer powered.deinit();
    const id = common.rule(11);
    var t: el.EmCurrentDensityTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.layer_start.appendSlice(gpa, &.{ 0, 1 });
    try t.layer.append(gpa, @fromBackingInt(0));
    try t.max_density.append(gpa, .{ .raw = 1e9 });
    try t.max_current_per_cut.append(gpa, .{ .raw = 200.0 });
    try t.narrow.append(gpa, null);
    var intent = try supplyIntent();
    defer intent.deinit(gpa);
    var skipped: common.Sink = .{};
    defer skipped.deinit();
    try erc.electrical.checkEmCurrentDensity(skipped.record(), .no_supply, &intent, common.manufacturingGrid(), &t);
    try common.assertSkippedForIntent(skipped.runs.items, &skipped.out, id);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.electrical.checkEmCurrentDensity(sink.record(), powered.solved(), &intent, common.manufacturingGrid(), &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u64, 4), r.examined);
}

test "electromigration skips without intent and reaches the edges with it" {
    // Oracle: construct-from-answer, on the gate: the with-intent run must
    // reach the edges, or the skip is indistinguishable from a dead rule.
    var powered = try Powered.init();
    defer powered.deinit();
    const id = common.rule(12);
    var t = try electromigrationTable(id, @fromBackingInt(0));
    defer erc.rule_set.deinitTable(gpa, &t);
    var intent = try supplyIntent();
    defer intent.deinit(gpa);
    var skipped: common.Sink = .{};
    defer skipped.deinit();
    try erc.electrical.checkElectromigration(skipped.record(), .no_supply, &intent, common.manufacturingGrid(), common.operating_temperature, &t);
    try common.assertSkippedForIntent(skipped.runs.items, &skipped.out, id);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.electrical.checkElectromigration(sink.record(), powered.solved(), &intent, common.manufacturingGrid(), common.operating_temperature, &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expect(r.examined > 0);
}

test "reliability skips without intent and evaluates nodes with it" {
    // Oracle: construct-from-answer, on the gate. A lifetime against a stress
    // nobody stated is a number, not a verdict; stated, the solved nodes are
    // evaluated.
    var powered = try Powered.init();
    defer powered.deinit();
    const id = common.rule(13);
    var t = try reliabilityTable(id);
    defer erc.rule_set.deinitTable(gpa, &t);
    var intent = try supplyIntent();
    defer intent.deinit(gpa);
    const none: IntentMap = .{};
    for ([_]struct { Power, *const IntentMap }{ .{ .no_supply, &intent }, .{ powered.solved(), &none } }) |c| {
        var sink: common.Sink = .{};
        defer sink.deinit();
        try erc.reliability.checkReliability(sink.record(), c[0], c[1], common.operating_temperature, &t);
        try common.assertSkippedForIntent(sink.runs.items, &sink.out, id);
    }
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.reliability.checkReliability(sink.record(), powered.solved(), &intent, common.operating_temperature, &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expect(r.examined > 0);
}

test "hv domain skips without intent and flags the straddling device with it" {
    // Oracle: construct-from-answer, on the gate and the measurement. With no
    // domains every device spans zero, so an ungated rule reports clean; with
    // them the one transistor straddles 3.3 V and 0 V and is reported at its
    // marker polygon.
    var one: OneTransistor = undefined;
    try one.init();
    defer one.deinit();
    const id = common.rule(14);
    var t: esd.HvDomainTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.max_domain_delta.append(gpa, .{ .raw = 1_000.0 });
    try t.isolation.append(gpa, null);
    const none: IntentMap = .{};
    const no_voltage: NetVoltage = .{};
    var skipped: common.Sink = .{};
    defer skipped.deinit();
    try erc.reliability.checkHvDomain(skipped.record(), one.design(), &none, &no_voltage, &t);
    try common.assertSkippedForIntent(skipped.runs.items, &skipped.out, id);

    var intent = try one.fourDomains(.{ 3_300.0, 0.0, 0.0, 0.0 });
    defer intent.deinit(gpa);
    var voltage: NetVoltage = .{};
    defer voltage.deinit(gpa);
    try erc.voltage.propagateInto(gpa, &one.nets, &one.devices, &intent, &voltage);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.reliability.checkHvDomain(sink.record(), one.design(), &intent, &voltage, &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u64, 1), r.examined);
    const v = &sink.out;
    try testing.expectEqual(@as(u32, 1), v.len());
    try testing.expectEqual(id, v.rule.items[0]);
    try testing.expectEqual(one.case.expected_devices[0].marker, v.shape_a.items[0]);
    try testing.expect(v.get(0).measured.eql(report.Measurement.voltage(.{ .raw = 3_300.0 })));
    try testing.expect(v.get(0).limit.eql(report.Measurement.voltage(.{ .raw = 1_000.0 })));
    try common.assertAtIsOnANamedShape(&one.case.store, v, 0);
}

test "esd latchup skips without intent and counts pads and rings with it" {
    // Oracle: construct-from-answer, on the gate and the count. With no
    // supplies there is no discharge target and every pad would pass; with
    // them the rule examines four pad nets and the one guard ring, and no
    // device is of the clamp model, so all four pads are reported (a count
    // the spec decides, not the run).
    var one: OneTransistor = undefined;
    try one.init();
    defer one.deinit();
    const id = common.rule(15);
    var t: esd.EsdLatchupTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.pad.append(gpa, one.case.layers.rail);
    try t.guard_ring.append(gpa, one.case.layers.marker);
    try t.min_guard_ring_width.append(gpa, 100);
    try t.max_tap_distance.append(gpa, 100_000);
    try t.clamp_start.appendSlice(gpa, &.{ 0, 1 });
    try t.clamp.append(gpa, common.rule(99));
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    const none: IntentMap = .{};
    var skipped: common.Sink = .{};
    defer skipped.deinit();
    try erc.reliability.checkEsdLatchup(skipped.record(), one.design(), &none, &t, &scratch);
    try common.assertSkippedForIntent(skipped.runs.items, &skipped.out, id);

    var intent = try one.fourDomains(.{ 1_800.0, 0.0, 1_800.0, 0.0 });
    defer intent.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.reliability.checkEsdLatchup(sink.record(), one.design(), &intent, &t, &scratch);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u64, 5), r.examined);
    try testing.expectEqual(@as(u32, 4), r.violations);
    try testing.expectEqual(@as(usize, 4), std.mem.count(geom.StrId, sink.out.rule.items, &.{id}));
}
