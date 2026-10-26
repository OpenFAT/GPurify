//! What the solve-reading rules do once past their intent gate: the drop a
//! node sits at, which edges a per-layer limit covers, and where an
//! impossible parameter must refuse rather than pass. Ported from
//! crates/check/tests/erc/electrical_limits.rs.

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
const Measurement = report.Measurement;
const PowerGrid = erc.power_grid.PowerGrid;
const PowerSolution = erc.power_grid.PowerSolution;
const Power = erc.power_grid.Power;
const IntentMap = erc.facts.IntentMap;
const NetLimits = ingest.intent.NetLimits;
const el = erc.electrical_tables;
const ReliabilityTable = erc.esd_tables.ReliabilityTable;

const Chain = struct {
    grid: PowerGrid,
    solution: PowerSolution,

    fn series(resistors: u32, ohm: f64, nominal: f64, load: f64) !Chain {
        var g = try common.seriesChain(resistors, ohm, nominal, load);
        errdefer g.deinit(gpa);
        return .{ .grid = g, .solution = try common.solve(&g) };
    }

    /// Edges 0-1, 1-2 on layer 0 and 2-3, 3-4 on layer 1, 1 mA at node 4.
    fn twoLayer() !Chain {
        var b: common.GridBuilder = .{};
        errdefer b.grid.deinit(gpa);
        for (0..5) |n| _ = try b.node(@as(i64, @intCast(n)) * 1_000, 1_800.0, if (n == 4) 1_000.0 else 0.0);
        try b.pad(0, 1_800.0);
        try b.edgeOn(@fromBackingInt(0), 0, 1, 1.0);
        try b.edgeOn(@fromBackingInt(0), 1, 2, 1.0);
        try b.edgeOn(@fromBackingInt(1), 2, 3, 1.0);
        try b.edgeOn(@fromBackingInt(1), 3, 4, 1.0);
        return .{ .grid = b.grid, .solution = try common.solve(&b.grid) };
    }

    /// Nodes held at `mv`, no solve: reliability reads only the voltages.
    fn heldAt(mv: []const f64) !Chain {
        var b: common.GridBuilder = .{};
        errdefer b.grid.deinit(gpa);
        for (mv, 0..) |_, k| _ = try b.node(@as(i64, @intCast(k)) * 1_000, 1_800.0, 0.0);
        var s: PowerSolution = .{};
        for (mv) |v| try s.node_voltage.append(gpa, .{ .raw = v });
        return .{ .grid = b.grid, .solution = s };
    }

    fn deinit(c: *Chain) void {
        c.grid.deinit(gpa);
        c.solution.deinit(gpa);
    }

    fn power(c: *const Chain) Power {
        return solved(&c.grid, &c.solution);
    }
};

// ---- private ----

/// Intent declaring net 0 a 1.8 V supply (net 1 its ground), net 0 with
/// exactly `limits`.
fn intentWith(limits: NetLimits) !IntentMap {
    var m = try common.declaredSupplies(@fromBackingInt(0), @fromBackingInt(1), 1_800.0);
    try common.limitNet(&m, @fromBackingInt(0), limits);
    return m;
}

fn solved(g: *const PowerGrid, s: *const PowerSolution) Power {
    return .{ .solved = .{ .grid = g, .solution = s } };
}

/// The row naming `poly`; fails when none does.
fn rowNaming(v: *const report.Violations, poly: u32) !u32 {
    for (v.shape_a.items, 0..) |p, row| if (@backingInt(p) == poly) return @intCast(row);
    return error.NoRow;
}

fn irDrop(sink: *common.Sink, power: Power, limits: NetLimits, id: geom.StrId) !void {
    var intent = try intentWith(limits);
    defer intent.deinit(gpa);
    var t: el.IrDropTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try erc.electrical.checkIrDrop(sink.record(), power, &intent, &t);
}

fn densityTable(id: geom.StrId, layer: geom.LayerId, limit: f64) !el.EmCurrentDensityTable {
    var t: el.EmCurrentDensityTable = .{ .head = try common.head(id) };
    try t.layer_start.appendSlice(gpa, &.{ 0, 1 });
    try t.layer.append(gpa, layer);
    try t.max_density.append(gpa, .{ .raw = limit });
    try t.max_current_per_cut.append(gpa, .{ .raw = 200.0 });
    try t.narrow.append(gpa, null);
    return t;
}

fn emDensity(sink: *common.Sink, power: Power, t: *const el.EmCurrentDensityTable) !void {
    var intent = try intentWith(.{});
    defer intent.deinit(gpa);
    try erc.electrical.checkEmCurrentDensity(sink.record(), power, &intent, common.manufacturingGrid(), t);
}

fn emTable(id: geom.StrId, reference_kelvin: f64, layer: geom.LayerId) !el.ElectromigrationTable {
    var t: el.ElectromigrationTable = .{ .head = try common.head(id) };
    try t.layer_start.appendSlice(gpa, &.{ 0, 1 });
    try t.layer.append(gpa, layer);
    try t.max_density.append(gpa, .{ .raw = 1e12 });
    try t.max_current_per_cut.append(gpa, .{ .raw = 200.0 });
    try t.blech_limit.append(gpa, .{ .raw = 1e-9 });
    try t.reference_temperature.append(gpa, .{ .raw = reference_kelvin });
    try t.activation_energy_ev.append(gpa, 0.7);
    try t.current_exponent.append(gpa, 2.0);
    return t;
}

fn reliabilityTable(id: geom.StrId, required_hours: f64, duty: f64, cap_mv: f64, reference_k: f64) !ReliabilityTable {
    var t: ReliabilityTable = .{ .head = try common.head(id) };
    try t.required_lifetime_hours.append(gpa, required_hours);
    try t.reference_lifetime_hours.append(gpa, 10_000.0);
    try t.reference_stress.append(gpa, .{ .raw = 2_000.0 });
    try t.stress_exponent.append(gpa, 4.0);
    try t.reference_temperature.append(gpa, .{ .raw = reference_k });
    try t.activation_energy_ev.append(gpa, 0.6);
    try t.duty_cycle.append(gpa, duty);
    try t.max_abs_voltage.append(gpa, .{ .raw = cap_mv });
    return t;
}

fn reliability(sink: *common.Sink, power: Power, kelvin: f64, t: *const ReliabilityTable) !void {
    var intent = try intentWith(.{});
    defer intent.deinit(gpa);
    try erc.reliability.checkReliability(sink.record(), power, &intent, .{ .raw = kelvin }, t);
}

test "ir drop reports each node that exceeds its net's absolute limit" {
    // Oracle: closed form. A milliamp through a chain of 2.5 ohm resistors
    // drops 2.5 mV per resistor: nodes at 0, 2.5, 5, 7.5, 10 mV below
    // nominal; against 6 mV exactly the last two, each reporting its own drop.
    var c = try Chain.series(4, 2.5, 1_800.0, 1_000.0);
    defer c.deinit();
    const id = common.rule(20);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try irDrop(&sink, c.power(), .{ .max_drop = .{ .raw = 6.0 } }, id);
    const v = &sink.out;
    try testing.expectEqual(@as(u32, 2), v.len());
    for ([_]struct { u32, f64 }{ .{ 3, 7.5 }, .{ 4, 10.0 } }) |case| {
        const row = try rowNaming(v, case[0]);
        try testing.expectEqual(id, v.rule.items[row]);
        try testing.expectEqual(c.grid.node_at.items[case[0]], v.at.items[row]);
        try testing.expectEqual(c.grid.node_layer.items[case[0]], v.layer.items[row]);
        try testing.expect(v.get(row).limit.eql(Measurement.voltage(.{ .raw = 6.0 })));
        try testgen.assertCloseRelative("the drop", v.get(row).measured.float(), case[1], 1e-6);
    }
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u32, 2), r.violations);
}

test "ir drop applies the fractional limit against the domain's nominal" {
    // Oracle: closed form. 0.2 % of a 1.8 V nominal is 3.6 mV, so three of
    // the five nodes are over where the 6 mV absolute limit caught two.
    var c = try Chain.series(4, 2.5, 1_800.0, 1_000.0);
    defer c.deinit();
    const id = common.rule(21);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try irDrop(&sink, c.power(), .{ .max_drop_fraction = 0.002 }, id);
    try testing.expectEqual(@as(u32, 3), sink.out.len());
    for ([_]u32{ 2, 3, 4 }) |node| {
        const row = try rowNaming(&sink.out, node);
        try testing.expectEqual(c.grid.node_at.items[node], sink.out.at.items[row]);
        try testing.expect(sink.out.get(row).measured.float() > 3.6);
    }
    try testing.expectEqual(@as(u32, 3), (try common.runOf(sink.runs.items, id)).violations);
}

test "ir drop reports a node sitting above its domain's nominal" {
    // Oracle: closed form. A pad driven 800 mV above a 1.8 V nominal with no
    // load puts every node exactly 800 mV over; a 500 mV overvoltage limit
    // catches all three.
    var b: common.GridBuilder = .{};
    for (0..3) |n| _ = try b.node(@as(i64, @intCast(n)) * 1_000, 1_800.0, 0.0);
    try b.pad(0, 2_600.0);
    try b.edge(0, 1, 1.0);
    try b.edge(1, 2, 1.0);
    var c: Chain = .{ .grid = b.grid, .solution = try common.solve(&b.grid) };
    defer c.deinit();
    const id = common.rule(22);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try irDrop(&sink, c.power(), .{ .max_overvoltage = .{ .raw = 500.0 } }, id);
    try testing.expectEqual(@as(u32, 3), sink.out.len());
    for (0..3) |row| {
        try testing.expect(sink.out.get(@intCast(row)).limit.eql(Measurement.voltage(.{ .raw = 500.0 })));
        try testgen.assertClose("the overvoltage", sink.out.get(@intCast(row)).measured.float(), 800.0, 1e-6);
    }
    try testing.expectEqual(@as(u32, 3), (try common.runOf(sink.runs.items, id)).violations);
}

test "em current density examines only the edges on a limited layer" {
    // Oracle: construct-from-answer. Four edges, two on each of two layers,
    // one limited layer: `examined` is two whichever limit is set, and no
    // row names the unlimited layer.
    var c = try Chain.twoLayer();
    defer c.deinit();
    for ([_]f64{ 1e-30, 1e30 }) |limit| {
        const id = common.rule(23);
        var t = try densityTable(id, @fromBackingInt(1), limit);
        defer erc.rule_set.deinitTable(gpa, &t);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try emDensity(&sink, c.power(), &t);
        const r = try common.runOf(sink.runs.items, id);
        try testing.expectEqual(report.Outcome.ran, r.outcome);
        try testing.expectEqual(@as(u64, 2), r.examined);
        for (sink.out.layer.items) |l| try testing.expectEqual(@as(u16, 1), @backingInt(l));
    }
}

test "em current density reports everything below a tiny limit and nothing below a huge one" {
    // Oracle: law. Every branch carries the same current, so against an
    // unreachably small limit both limited edges are violations and against
    // an unreachably large one none are.
    var c = try Chain.twoLayer();
    defer c.deinit();
    const strict = common.rule(24);
    var t = try densityTable(strict, @fromBackingInt(0), 1e-30);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try emDensity(&sink, c.power(), &t);
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    try testing.expectEqual(@as(u32, 2), (try common.runOf(sink.runs.items, strict)).violations);
    const lax = common.rule(25);
    var t2 = try densityTable(lax, @fromBackingInt(0), 1e30);
    defer erc.rule_set.deinitTable(gpa, &t2);
    var sink2: common.Sink = .{};
    defer sink2.deinit();
    try emDensity(&sink2, c.power(), &t2);
    try testgen.assertClean(sink2.runs.items, &sink2.out, lax);
}

test "an electromigration reference temperature that is not absolute is refused" {
    // Oracle: construct-from-answer, on the fail-closed path. 358.15 K is
    // 85 °C and the rule runs; the bare 0 and -40 a Celsius deck would give
    // have no Arrhenius factor, and the honest answer is a refusal.
    var c = try Chain.twoLayer();
    defer c.deinit();
    var intent = try intentWith(.{});
    defer intent.deinit(gpa);
    const good = common.rule(26);
    var t = try emTable(good, 358.15, @fromBackingInt(0));
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.electrical.checkElectromigration(sink.record(), c.power(), &intent, common.manufacturingGrid(), common.operating_temperature, &t);
    try testing.expectEqual(report.Outcome.ran, (try common.runOf(sink.runs.items, good)).outcome);
    for ([_]f64{ 0.0, -40.0 }, 0..) |kelvin, k| {
        const id = common.rule(27 + @as(u32, @intCast(k)));
        var bad = try emTable(id, kelvin, @fromBackingInt(0));
        defer erc.rule_set.deinitTable(gpa, &bad);
        var s: common.Sink = .{};
        defer s.deinit();
        try erc.electrical.checkElectromigration(s.record(), c.power(), &intent, common.manufacturingGrid(), common.operating_temperature, &bad);
        try testing.expectEqual(report.Outcome.refused, (try common.runOf(s.runs.items, id)).outcome);
        try testing.expect(std.mem.indexOfScalar(geom.StrId, s.out.rule.items, id) == null);
    }
}

test "a reliability duty cycle outside the unit interval is refused" {
    // Oracle: construct-from-answer, on the fail-closed path: a duty cycle is
    // a fraction of the lifetime under stress, in 0 ..= 1.
    var c = try Chain.series(3, 1.0, 1_800.0, 500.0);
    defer c.deinit();
    for ([_]f64{ 1.5, -0.1 }, 0..) |duty, k| {
        const id = common.rule(30 + @as(u32, @intCast(k)));
        var t = try reliabilityTable(id, 87_600.0, duty, 1_950.0, 398.15);
        defer erc.rule_set.deinitTable(gpa, &t);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try reliability(&sink, c.power(), common.operating_temperature.raw, &t);
        try testing.expectEqual(report.Outcome.refused, (try common.runOf(sink.runs.items, id)).outcome);
        try testing.expect(std.mem.indexOfScalar(geom.StrId, sink.out.rule.items, id) == null);
    }
}

test "a node over the absolute voltage cap is reported with its own voltage" {
    // Oracle: construct-from-answer. Every node sits between 1.79 and 1.80 V,
    // so a 1.0 V cap catches all five, each measuring a node's own solved
    // voltage.
    var c = try Chain.series(4, 2.5, 1_800.0, 1_000.0);
    defer c.deinit();
    const id = common.rule(32);
    var t = try reliabilityTable(id, 87_600.0, 0.5, 1_000.0, 398.15);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try reliability(&sink, c.power(), common.operating_temperature.raw, &t);
    try testing.expectEqual(report.Outcome.ran, (try common.runOf(sink.runs.items, id)).outcome);
    var over: u32 = 0;
    for (0..sink.out.len()) |row| {
        const v = sink.out.get(@intCast(row));
        if (v.measured.kind != .voltage) continue;
        over += 1;
        try testing.expect(v.limit.eql(Measurement.voltage(.{ .raw = 1_000.0 })));
        const reported = v.measured.float();
        try testing.expect(reported > 1_000.0);
        const matches = for (c.solution.node_voltage.items) |nv| {
            if (@abs(nv.raw - reported) < 1e-6) break true;
        } else false;
        try testing.expect(matches);
    }
    try testing.expectEqual(c.grid.nodeCount(), over);
}

test "reliability predicts each node's lifetime in closed form" {
    // Oracle: closed form. At the reference temperature the Arrhenius factor
    // is 1, so the unit life is 10 000 / 0.5 = 20 000 h, and nodes at 0, 1,
    // 2, 4 and -4 V live forever, 320 000, 20 000, 1 250 and 1 250 h: against
    // a required 20 000 h only the two 4 V nodes fail, and against a 3 V cap
    // the same two. At 358.15 K the life scales by
    // `exp(0.6 / 8.617333262e-5 · (1/358.15 - 1/398.15))` (CODATA k).
    var c = try Chain.heldAt(&.{ 0.0, 1_000.0, 2_000.0, 4_000.0, -4_000.0 });
    defer c.deinit();
    const id = common.rule(40);
    var t = try reliabilityTable(id, 20_000.0, 0.5, 3_000.0, 398.15);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try reliability(&sink, c.power(), 398.15, &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u64, 5), r.examined);
    const cap = Measurement.voltage(.{ .raw = 3_000.0 });
    const required = Measurement.ratio(20_000.0);
    const want = [_]struct { u32, Measurement, Measurement }{
        .{ 3, Measurement.voltage(.{ .raw = 4_000.0 }), cap }, .{ 3, Measurement.ratio(1_250.0), required },
        .{ 4, Measurement.voltage(.{ .raw = 4_000.0 }), cap }, .{ 4, Measurement.ratio(1_250.0), required },
    };
    try testing.expectEqual(@as(u32, want.len), sink.out.len());
    // Rows come node by node, the cap before the life.
    for (want, 0..) |w, row| {
        const v = sink.out.get(@intCast(row));
        try testing.expectEqual(w[0], @backingInt(v.shape_a));
        try testing.expect(v.measured.eql(w[1]));
        try testing.expect(v.limit.eql(w[2]));
        try testing.expectEqual(c.grid.node_at.items[w[0]], v.at);
    }
    // Colder than the reference: every life longer by the Arrhenius factor.
    const thermal = @exp(0.6 / 8.617_333_262e-5 * (1.0 / 358.15 - 1.0 / 398.15));
    const id2 = common.rule(41);
    var t2 = try reliabilityTable(id2, 1e12, 0.5, 1e9, 398.15);
    defer erc.rule_set.deinitTable(gpa, &t2);
    var s2: common.Sink = .{};
    defer s2.deinit();
    try reliability(&s2, c.power(), 358.15, &t2);
    try testing.expectEqual(report.Outcome.ran, (try common.runOf(s2.runs.items, id2)).outcome);
    const lives = [_]struct { u32, f64 }{ .{ 1, 320_000.0 }, .{ 2, 20_000.0 }, .{ 3, 1_250.0 }, .{ 4, 1_250.0 } };
    try testing.expectEqual(@as(u32, lives.len), s2.out.len());
    for (lives, 0..) |l, row| {
        const v = s2.out.get(@intCast(row));
        try testing.expectEqual(report.Kind.ratio, v.measured.kind);
        try testing.expectEqual(l[0], @backingInt(v.shape_a));
        try testgen.assertCloseRelative("a node's life", v.measured.float(), l[1] * thermal, 1e-9);
    }
}

test "reliability refuses a row whose model has no meaning" {
    // Oracle: construct-from-answer: each row differs from a legal one in
    // the one value the rule's documentation says it refuses (a temperature
    // at 0 K, no reference stress, an unbounded exponent, an unbounded or
    // zero required life, an unbounded cap, a zero duty, an unbounded
    // reference life, a node at NaN).
    var c = try Chain.heldAt(&.{ 0.0, 1_000.0, 2_000.0 });
    defer c.deinit();
    const id = common.rule(42);
    const Break = enum { reference_zero, no_stress, inf_exponent, inf_required, zero_required, inf_cap, zero_duty, inf_reference_life };
    {
        var legal = try reliabilityTable(id, 1e9, 0.5, 1e9, 398.15);
        defer erc.rule_set.deinitTable(gpa, &legal);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try reliability(&sink, c.power(), 398.15, &legal);
        try testing.expectEqual(report.Outcome.ran, (try common.runOf(sink.runs.items, id)).outcome);
        var cold: common.Sink = .{};
        defer cold.deinit();
        try reliability(&cold, c.power(), 0.0, &legal);
        try testing.expectEqual(report.Outcome.refused, (try common.runOf(cold.runs.items, id)).outcome);
        try testing.expectEqual(@as(u32, 0), cold.out.len());
        var nan = try Chain.heldAt(&.{ 0.0, std.math.nan(f64), 1.0 });
        defer nan.deinit();
        var s3: common.Sink = .{};
        defer s3.deinit();
        try reliability(&s3, nan.power(), 398.15, &legal);
        try testing.expectEqual(report.Outcome.refused, (try common.runOf(s3.runs.items, id)).outcome);
        try testing.expectEqual(@as(u32, 0), s3.out.len());
    }
    inline for (@typeInfo(Break).@"enum".field_names) |name| {
        var t = try reliabilityTable(id, 1e9, 0.5, 1e9, 398.15);
        defer erc.rule_set.deinitTable(gpa, &t);
        const inf = std.math.inf(f64);
        switch (@field(Break, name)) {
            .reference_zero => t.reference_temperature.items[0] = .{ .raw = 0.0 },
            .no_stress => t.reference_stress.items[0] = .{ .raw = 0.0 },
            .inf_exponent => t.stress_exponent.items[0] = inf,
            .inf_required => t.required_lifetime_hours.items[0] = inf,
            .zero_required => t.required_lifetime_hours.items[0] = 0.0,
            .inf_cap => t.max_abs_voltage.items[0] = .{ .raw = inf },
            .zero_duty => t.duty_cycle.items[0] = 0.0,
            .inf_reference_life => t.reference_lifetime_hours.items[0] = inf,
        }
        var sink: common.Sink = .{};
        defer sink.deinit();
        try reliability(&sink, c.power(), 398.15, &t);
        try testing.expectEqual(report.Outcome.refused, (try common.runOf(sink.runs.items, id)).outcome);
        try testing.expectEqual(@as(u32, 0), sink.out.len());
    }
}
