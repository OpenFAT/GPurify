//! Voltage propagation and the domain and ESD rules that read it. Ported
//! from crates/check/tests/erc/voltage_rules.rs (its domain, esd and
//! propagation tests; the esd_topological, forward_diode and
//! guard_ring_bias tests are the supply and latchup suites').
//!
//! Oracle throughout: construct-from-answer on hand-drawn netlists, each
//! small enough that the range every net can reach is read off the
//! schematic: an inverter's output swings between the rails of the
//! inverter that drives it.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen_nl = @import("testgen").netlist;
const common = @import("common.zig");
const circuit_ = @import("circuit.zig");
const Circuit = circuit_.Circuit;
const build = circuit_.build;
const mos = circuit_.mos;
const twoPin = circuit_.twoPin;
const StrId = geom.StrId;
const report = check.report;
const Measurement = report.Measurement;
const NetId = check.topology.NetId;
const erc = check.erc;
const IntentMap = erc.facts.IntentMap;
const NetVoltage = erc.voltage.NetVoltage;
const tables = erc.domain_tables;
const deinitTable = erc.rule_set.deinitTable;
const gpa = common.gpa;

const io: u32 = 0;

const core: u32 = 1;

// ---- private ----

fn modelLimit(id: StrId, models: []const StrId, max_mv: f64) !tables.ModelLimitTable {
    var t: tables.ModelLimitTable = .{};
    try t.head.push(gpa, id, .@"error");
    try t.model_start.appendSlice(gpa, &.{ 0, @intCast(models.len) });
    try t.model.appendSlice(gpa, models);
    try t.max_voltage.append(gpa, .{ .raw = max_mv });
    return t;
}

fn shifters(id: StrId, models: []const StrId) !tables.MissingLevelShifterTable {
    var t: tables.MissingLevelShifterTable = .{};
    try t.head.push(gpa, id, .@"error");
    try t.shifter_start.appendSlice(gpa, &.{ 0, @intCast(models.len) });
    try t.shifter.appendSlice(gpa, models);
    return t;
}

/// Nets: 0 VDD33, 1 VDD18, 2 VSS, 3 IN (driven by nothing), 4 A, 5 Y. A
/// 3.3 V inverter (IN to A) drives a 1.8 V inverter (A to Y).
fn direct(a: std.mem.Allocator) !Circuit {
    return build(6, &.{
        try mos(a, "pfet33", 3, 0, 4, 0),
        try mos(a, "nfet33", 3, 2, 4, 2),
        try mos(a, "pfet18", 4, 1, 5, 1),
        try mos(a, "nfet18", 4, 2, 5, 2),
    });
}

/// VSS is the core domain's ground, stated at the domain's nominal as the
/// intent reader does.
fn twoDomains(c: *const Circuit) !IntentMap {
    return c.intent(&.{ .{ .net = 0, .role = .power, .domain = io, .mv = 3_300 }, .{ .net = 1, .role = .power, .domain = core, .mv = 1_800 }, .{ .net = 2, .role = .ground, .domain = core, .mv = 1_800 } });
}

fn expectVolts(v: *const report.Violations, row: u32, mv: f64) !void {
    try testing.expect(v.get(row).measured.eql(Measurement.voltage(.{ .raw = mv })));
}

/// The intent of one switch: VH and VSS, and G held at `gate` mV (a ground
/// at 0 V, a power supply of its own domain otherwise), or null for a gate
/// no supply reaches. Nets: 0 VH (3.3 V), 1 G, 2 X, 3 VSS.
fn gateAt(c: *const Circuit, gate: ?f64) !IntentMap {
    var s: [3]circuit_.Supply = .{ .{ .net = 0, .role = .power, .domain = io, .mv = 3_300 }, .{ .net = 3, .role = .ground, .domain = io, .mv = 3_300 }, undefined };
    var n: usize = 2;
    if (gate) |mv| {
        s[2] = if (mv > 0) .{ .net = 1, .role = .power, .domain = core, .mv = mv } else .{ .net = 1, .role = .ground, .domain = core, .mv = 1_000 };
        n = 3;
    }
    return c.intent(s[0..n]);
}

/// X's reached range under `gateAt(gate)`, or null when unreached.
fn reaches(c: *const Circuit, gate: ?f64) !?[2]f64 {
    var intent = try gateAt(c, gate);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    const x = c.net(2);
    if (!v.known(x)) return null;
    return .{ v.lo.items[@backingInt(x)], v.hi.items[@backingInt(x)] };
}

/// Nets: 0 VDD1, 1 VSS1, 2 VDD2, 3 VSS2, 4 SIG, 5 OUT, 6 IN. An IO inverter
/// (IN to SIG) on VDD1/VSS1 drives a core inverter (SIG to OUT) on
/// VDD2/VSS2; `coupled` adds anti-parallel `dio` diodes between the grounds.
fn crossing(a: std.mem.Allocator, coupled: bool) !Circuit {
    var devices: std.ArrayList(circuit_.DeviceSpec) = .empty;
    try devices.appendSlice(a, &.{
        try mos(a, "pfet", 6, 0, 4, 0),     try mos(a, "nfet", 6, 1, 4, 1),
        try mos(a, "pfet", 4, 2, 5, 2),     try mos(a, "nfet", 4, 3, 5, 3),
        // A rail diode, so `dio` is named either way.
        try twoPin(a, .diode, "dio", 1, 0),
    });
    if (coupled) try devices.appendSlice(a, &.{ try twoPin(a, .diode, "dio", 1, 3), try twoPin(a, .diode, "dio", 3, 1) });
    return build(7, devices.items);
}

fn runCrossing(c: *const Circuit, id: StrId, sink: *common.Sink) !void {
    var intent = try c.intent(&.{ .{ .net = 0, .role = .power, .domain = io, .mv = 1_800 }, .{ .net = 1, .role = .ground, .domain = io, .mv = 1_800 }, .{ .net = 2, .role = .power, .domain = core, .mv = 1_800 }, .{ .net = 3, .role = .ground, .domain = core, .mv = 1_800 } });
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    var t: erc.esd_tables.EsdCrossDomainTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, id, .@"error");
    try t.diode_start.appendSlice(gpa, &.{ 0, 1 });
    try t.diode.append(gpa, c.model("dio"));
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
    try erc.esd.checkEsdCrossDomain(sink.record(), c.design(), &intent, &v, .{ .grid = common.manufacturingGrid(), .stack = &stack, .connectivity = &connectivity }, &t, &scratch);
}

/// Nets: 0 VDD, 1 VSS, 2 PAD, 3 IN2. PAD is the one net with an emitter
/// (the pad layer); a series `rs` resistor carries it to IN2, the gate of
/// an nfet. `clamped` adds an up diode IN2 to VDD and a down diode VSS to IN2.
fn exposed(a: std.mem.Allocator, clamped: bool) !Circuit {
    var devices: std.ArrayList(circuit_.DeviceSpec) = .empty;
    const bjt_terms = try a.dupe(testgen_nl.TerminalSpec, &.{ .{ .role = .base, .net = 2 }, .{ .role = .emitter, .net = 2 }, .{ .role = .collector, .net = 2 } });
    try devices.appendSlice(a, &.{
        .{ .kind = .bjt, .model = "npn", .terminals = bjt_terms },
        try twoPin(a, .resistor, "rs", 2, 3),
        try mos(a, "nfet", 3, 1, 1, 1),
        try twoPin(a, .diode, "dio", 1, 0),
    });
    if (clamped) try devices.appendSlice(a, &.{ try twoPin(a, .diode, "dio", 3, 0), try twoPin(a, .diode, "dio", 1, 3) });
    return build(4, devices.items);
}

fn runExposed(c: *const Circuit, id: StrId, sink: *common.Sink) !void {
    var intent = try c.intent(&.{ .{ .net = 0, .role = .power, .domain = core, .mv = 1_800 }, .{ .net = 1, .role = .ground, .domain = core, .mv = 1_800 } });
    defer intent.deinit(gpa);
    var t: erc.esd_tables.EsdExposedTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, id, .@"error");
    try t.pad.append(gpa, c.case.layers.layerOf(.emitter));
    try t.clamp_start.appendSlice(gpa, &.{ 0, 1 });
    try t.clamp.append(gpa, c.model("dio"));
    try t.resistor_start.appendSlice(gpa, &.{ 0, 1 });
    try t.resistor.append(gpa, c.model("rs"));
    try t.rated_start.appendSlice(gpa, &.{ 0, 0 });
    try t.min_series.append(gpa, null);
    try erc.esd.checkEsdExposed(sink.record(), c.design(), &intent, &t);
}

test "propagation gives each inverter output its own rails" {
    // Oracle: construct-from-answer, read off `direct`'s schematic: VDD33 is
    // 3.3 V in the IO domain, VSS 0 V in none, A swings 0 to 3.3 V (the IO
    // inverter's rails), Y 0 to 1.8 V, and IN, driven by nothing through a
    // channel, is unknown.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try direct(arena.allocator());
    defer c.deinit();
    var intent = try twoDomains(&c);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    const Range = struct { f64, f64, u64 };
    const range = struct {
        fn of(cc: *const Circuit, vv: *const NetVoltage, n: usize) Range {
            const i = @backingInt(cc.net(n));
            return .{ vv.lo.items[i], vv.hi.items[i], vv.power.items[i] };
        }
    }.of;
    try testing.expectEqual(Range{ 3_300, 3_300, 1 << io }, range(&c, &v, 0));
    try testing.expectEqual(Range{ 0, 0, 0 }, range(&c, &v, 2));
    try testing.expectEqual(Range{ 0, 3_300, 1 << io }, range(&c, &v, 4));
    try testing.expectEqual(Range{ 0, 1_800, 1 << core }, range(&c, &v, 5));
    try testing.expect(!v.known(c.net(3)));
}

test "a 3v3 signal on a 1v8 gate overstresses it and lacks a level shifter" {
    // Oracle: construct-from-answer, read off `direct`'s schematic: both
    // 1.8 V devices see A's 3.3 V across the oxide against a 1.98 V rating,
    // both lack a shifter, and their own channels see only 1.8 V.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try direct(a);
    defer c.deinit();
    var intent = try twoDomains(&c);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    const thin = try c.models(a, &.{ "pfet18", "nfet18" });
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t = try modelLimit(common.rule(1), thin, 1_980);
        defer deinitTable(gpa, &t);
        try erc.domain.checkGateOxide(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(1));
        try testing.expectEqual(report.Outcome.ran, run.outcome);
        try testing.expectEqual(@as(u64, 2), run.examined);
        try testing.expectEqual(@as(u32, 2), run.violations);
        for (0..2) |row| {
            try expectVolts(&sink.out, @intCast(row), 3_300);
            try testing.expectEqual(c.case.expected_devices[row + 2].marker, sink.out.shape_a.items[row]);
        }
    }
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t = try shifters(common.rule(2), &.{});
        defer deinitTable(gpa, &t);
        try erc.domain.checkMissingLevelShifter(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(2));
        try testing.expectEqual(@as(u64, 2), run.examined);
        try testing.expectEqual(@as(u32, 2), run.violations);
        try testing.expect(sink.out.get(0).measured.eql(.count(1)));
    }
    {
        // The same limits on healthy 1.8 V channels: 1.8 V drain to source.
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t = try modelLimit(common.rule(3), thin, 1_980);
        defer deinitTable(gpa, &t);
        try erc.domain.checkDrainSource(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(3));
        try testing.expectEqual(@as(u64, 2), run.examined);
        try testing.expectEqual(@as(u32, 0), run.violations);
    }
}

test "a thin device across 3v3 is a drain source overvoltage" {
    // Oracle: construct-from-answer. The 1.98 V-rated models sit in the 3.3 V
    // inverter, whose drain A swings to 3.3 V against a 0 V source, so both
    // are flagged at 3.3 V.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try direct(a);
    defer c.deinit();
    var intent = try twoDomains(&c);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    var t = try modelLimit(common.rule(4), try c.models(a, &.{ "pfet33", "nfet33" }), 1_980);
    defer deinitTable(gpa, &t);
    try erc.domain.checkDrainSource(sink.record(), c.design(), &intent, &v, &t);
    const run = try common.runOf(sink.runs.items, common.rule(4));
    try testing.expectEqual(@as(u64, 2), run.examined);
    try testing.expectEqual(@as(u32, 2), run.violations);
    try expectVolts(&sink.out, 0, 3_300);
}

test "the same signal through a declared level shifter is clean" {
    // Oracle: construct-from-answer, read off `shifted`'s schematic: B swings
    // 0 to 1.8 V, A's 3.3 V is within the shifter's 3.63 V, the declared
    // shifter needs no shifter of its own, an undeclared one is the crossing,
    // and no channel joins the two supplies.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Nets: 0 VDD33, 1 VDD18, 2 VSS, 3 IN, 4 A, 5 Y, 6 B.
    var c = try build(7, &.{
        try mos(a, "pfet33", 3, 0, 4, 0), try mos(a, "nfet33", 3, 2, 4, 2),
        try mos(a, "ls_p", 4, 1, 6, 1),   try mos(a, "ls_n", 4, 2, 6, 2),
        try mos(a, "pfet18", 6, 1, 5, 1), try mos(a, "nfet18", 6, 2, 5, 2),
    });
    defer c.deinit();
    var intent = try twoDomains(&c);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var thin = try modelLimit(common.rule(5), try c.models(a, &.{ "pfet18", "nfet18" }), 1_980);
        defer deinitTable(gpa, &thin);
        var rated = try modelLimit(common.rule(6), try c.models(a, &.{ "ls_p", "ls_n" }), 3_630);
        defer deinitTable(gpa, &rated);
        try erc.domain.checkGateOxide(sink.record(), c.design(), &intent, &v, &thin);
        try erc.domain.checkGateOxide(sink.record(), c.design(), &intent, &v, &rated);
        try testing.expectEqual(@as(u64, 2), (try common.runOf(sink.runs.items, common.rule(5))).examined);
        try testing.expectEqual(@as(u64, 2), (try common.runOf(sink.runs.items, common.rule(6))).examined);
        try testing.expectEqual(@as(u32, 0), sink.out.len());
    }
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t = try shifters(common.rule(7), try c.models(a, &.{ "ls_p", "ls_n" }));
        defer deinitTable(gpa, &t);
        try erc.domain.checkMissingLevelShifter(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(7));
        try testing.expectEqual(@as(u64, 2), run.examined);
        try testing.expectEqual(@as(u32, 0), run.violations);
    }
    {
        // Undeclared, the shifter's own devices are the domain crossing.
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t = try shifters(common.rule(8), &.{});
        defer deinitTable(gpa, &t);
        try erc.domain.checkMissingLevelShifter(sink.record(), c.design(), &intent, &v, &t);
        try testing.expectEqual(@as(u32, 2), (try common.runOf(sink.runs.items, common.rule(8))).violations);
        try testing.expectEqual(c.case.expected_devices[2].marker, sink.out.shape_a.items[0]);
    }
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t: tables.DomainCrossingTable = .{};
        defer deinitTable(gpa, &t);
        try t.head.push(gpa, common.rule(9), .@"error");
        try erc.domain.checkDomainCrossing(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(9));
        try testing.expectEqual(@as(u64, 6), run.examined);
        try testing.expectEqual(@as(u32, 0), run.violations);
    }
}

test "a well below its source and a pass gate between domains are flagged" {
    // Oracle: construct-from-answer, read off the schematic: OUT and X reach
    // 3.3 V through the pass gate, so both 1.8 V-well pfets are 1.5 V
    // forward-biased, and every channel touches OUT or X, which reaches both
    // domains. Nets: 0 VDD33, 1 VDD18, 2 VSS, 3 OUT, 4 X.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try build(5, &.{ try mos(a, "pfet", 2, 0, 3, 1), try mos(a, "nfet", 0, 2, 3, 2), try mos(a, "nfet", 0, 3, 4, 2), try mos(a, "pfet", 2, 1, 4, 1) });
    defer c.deinit();
    var intent = try twoDomains(&c);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t: tables.WellBiasTable = .{};
        defer deinitTable(gpa, &t);
        try t.head.push(gpa, common.rule(10), .@"error");
        try t.pmos_start.appendSlice(gpa, &.{ 0, 1 });
        try t.pmos.append(gpa, c.model("pfet"));
        try t.nmos_start.appendSlice(gpa, &.{ 0, 1 });
        try t.nmos.append(gpa, c.model("nfet"));
        try erc.domain.checkWellBias(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(10));
        try testing.expectEqual(@as(u64, 4), run.examined);
        try testing.expectEqual(@as(u32, 2), run.violations);
        try expectVolts(&sink.out, 0, 1_500);
        try testing.expectEqual(c.case.expected_devices[0].marker, sink.out.shape_a.items[0]);
        try testing.expectEqual(c.case.expected_devices[3].marker, sink.out.shape_a.items[1]);
    }
    {
        var sink: common.Sink = .{};
        defer sink.deinit();
        var t: tables.DomainCrossingTable = .{};
        defer deinitTable(gpa, &t);
        try t.head.push(gpa, common.rule(11), .@"error");
        try erc.domain.checkDomainCrossing(sink.record(), c.design(), &intent, &v, &t);
        const run = try common.runOf(sink.runs.items, common.rule(11));
        try testing.expectEqual(@as(u64, 4), run.examined);
        try testing.expectEqual(@as(u32, 4), run.violations);
        try testing.expect(sink.out.get(0).measured.eql(.count(2)));
    }
}

test "the voltage rules skip without intent" {
    // Oracle: the documented contract of an intent-gated row: with no supply
    // declared it records `Skipped(NoDesignIntent)` and reports nothing.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try direct(a);
    defer c.deinit();
    const none: IntentMap = .{};
    var v = try c.voltage(&none);
    defer v.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    var t = try modelLimit(common.rule(12), try c.models(a, &.{"nfet18"}), 1_980);
    defer deinitTable(gpa, &t);
    try erc.domain.checkGateOxide(sink.record(), c.design(), &none, &v, &t);
    try common.assertSkippedForIntent(sink.runs.items, &sink.out, common.rule(12));
}

test "a switch passes voltage only when its gate can turn it on" {
    // Oracle: the public Calibre PERC white paper (Siemens 81822, figure 1):
    // "The NMOS is ON when the voltage at gate pin is >= 1 V, and OFF when the
    // voltage at gate pin is < 1 V"; "The PMOS is ON when the voltage at gate
    // pin is <= 0 V, and OFF when the voltage at gate pin is > 0 V". An ON
    // switch passes VH (3.3 V) to X; an OFF one leaves X unreached. Each
    // threshold is swept a millivolt either side, and a gate no supply
    // reaches may be anything, so its switch conducts.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const on: ?[2]f64 = .{ 3_300, 3_300 };
    {
        var nmos = try build(4, &.{try mos(a, "sw", 1, 0, 2, 3)});
        defer nmos.deinit();
        try nmos.setSwitch(0, 1_000, null);
        for ([_]struct { f64, bool }{ .{ 999, false }, .{ 1_000, true }, .{ 1_001, true }, .{ 0, false } }) |case| {
            try testing.expectEqual(if (case[1]) on else null, try reaches(&nmos, case[0]));
        }
        try testing.expectEqual(on, try reaches(&nmos, null));
    }
    {
        var pmos = try build(4, &.{try mos(a, "sw", 1, 0, 2, 3)});
        defer pmos.deinit();
        try pmos.setSwitch(0, null, 0);
        for ([_]struct { f64, bool }{ .{ 0, true }, .{ 1, false }, .{ 3_300, false } }) |case| {
            try testing.expectEqual(if (case[1]) on else null, try reaches(&pmos, case[0]));
        }
    }
    var plain = try build(4, &.{try mos(a, "sw", 1, 0, 2, 3)});
    defer plain.deinit();
    try testing.expectEqual(on, try reaches(&plain, 0));
}

test "a gate behind a switch that never turns on floats and its switch conducts" {
    // Oracle: construct-from-answer. With every channel conducting, G would
    // reach VH, so G is not an input to the cell; but switch 0 is always off,
    // so G floats, may be anything, and switch 1 may conduct: X reaches 3.3 V
    // and G stays unreached. Nets: 0 VH, 1 VSS, 2 G, 3 X.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try build(4, &.{ try mos(a, "sw", 1, 0, 2, 1), try mos(a, "sw", 2, 0, 3, 1) });
    defer c.deinit();
    try c.setSwitch(0, 1_000, null);
    try c.setSwitch(1, 1_000, null);
    var intent = try c.intent(&.{ .{ .net = 0, .role = .power, .domain = io, .mv = 3_300 }, .{ .net = 1, .role = .ground, .domain = io, .mv = 3_300 } });
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    try testing.expect(!v.known(c.net(2)));
    const x = @backingInt(c.net(3));
    try testing.expectEqual([2]f64{ 3_300, 3_300 }, [2]f64{ v.lo.items[x], v.hi.items[x] });
}

test "a gate range from propagation decides the switch it drives" {
    // Oracle: construct-from-answer. A swings 0 to 1.8 V in the core domain,
    // which never reaches 2.5 V, so the first switch is off and OUT is
    // unreached; it reaches 1 V, so the second conducts and B sits at VH's
    // 3.3 V in the I/O domain. Nets: 0 VDD, 1 VSS, 2 VH, 3 IN, 4 A, 5 OUT, 6 B.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try build(7, &.{ try mos(a, "pfet18", 3, 0, 4, 0), try mos(a, "nfet18", 3, 1, 4, 1), try mos(a, "sw", 4, 2, 5, 1), try mos(a, "sw", 4, 2, 6, 1) });
    defer c.deinit();
    try c.setSwitch(2, 2_500, null);
    try c.setSwitch(3, 1_000, null);
    var intent = try c.intent(&.{ .{ .net = 0, .role = .power, .domain = core, .mv = 1_800 }, .{ .net = 1, .role = .ground, .domain = core, .mv = 1_800 }, .{ .net = 2, .role = .power, .domain = io, .mv = 3_300 } });
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    try testing.expect(!v.known(c.net(5)));
    const an = @backingInt(c.net(4));
    try testing.expectEqual([2]f64{ 0, 1_800 }, [2]f64{ v.lo.items[an], v.hi.items[an] });
    try testing.expectEqual(@as(u64, 1 << core), v.power.items[an]);
    const b = @backingInt(c.net(6));
    try testing.expectEqual([2]f64{ 3_300, 3_300 }, [2]f64{ v.lo.items[b], v.hi.items[b] });
    try testing.expectEqual(@as(u64, 1 << io), v.power.items[b]);
}

test "a crossing with coupled grounds is protected" {
    // Oracle: construct-from-answer, read off `crossing`: SIG swings on
    // VDD1, which neither core channel reaches, so both core transistors are
    // receivers; the IO pair's gate IN reaches no supply and is none. The
    // anti-parallel pair puts VSS1 and VSS2 in one group.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try crossing(arena.allocator(), true);
    defer c.deinit();
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runCrossing(&c, common.rule(15), &sink);
    const run = try common.runOf(sink.runs.items, common.rule(15));
    try testing.expectEqual(@as(u64, 2), run.examined);
    try testing.expectEqual(@as(u32, 0), run.violations);
}

test "a crossing with uncoupled grounds flags each receiver" {
    // Oracle: construct-from-answer: VSS1 and VSS2 share no diode, so each of
    // the two receivers measures 0 coupled pairs against 1.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try crossing(arena.allocator(), false);
    defer c.deinit();
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runCrossing(&c, common.rule(16), &sink);
    const run = try common.runOf(sink.runs.items, common.rule(16));
    try testing.expectEqual(@as(u64, 2), run.examined);
    try testing.expectEqual(@as(u32, 2), run.violations);
    for (0..2) |row| try testing.expect(sink.out.get(@intCast(row)).measured.eql(.count(0)));
}

test "a gate behind a series resistor needs both clamps" {
    // Oracle: construct-from-answer, read off `exposed`: the resistor carries
    // PAD to IN2, so the nfet's gate is exposed; bare, its clamps reach 0 rail
    // kinds of the 2 it needs, and with the up and the down diode both.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    {
        var c = try exposed(arena.allocator(), false);
        defer c.deinit();
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runExposed(&c, common.rule(17), &sink);
        try testing.expectEqual(@as(u32, 1), sink.out.len());
        try testing.expect(sink.out.get(0).measured.eql(.count(0)));
        try testing.expectEqual(@as(u64, 1), (try common.runOf(sink.runs.items, common.rule(17))).examined);
    }
    {
        var c = try exposed(arena.allocator(), true);
        defer c.deinit();
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runExposed(&c, common.rule(17), &sink);
        try testing.expectEqual(@as(u32, 0), sink.out.len());
        try testing.expectEqual(@as(u64, 1), (try common.runOf(sink.runs.items, common.rule(17))).examined);
    }
}

test "a supply or terminal past the extraction is ignored" {
    // Oracle: metamorphic: the same circuit (a resistor from a 1.8 V supply
    // to a second net, which so reaches 1.8 V) propagated again with a
    // resistor between `NetId(count)` and `NetId::NONE` appended and
    // `NetId(count)` declared a supply gives the same ranges on every net.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try build(2, &.{try twoPin(arena.allocator(), .resistor, "r", 0, 1)});
    defer c.deinit();
    var intent = try c.intent(&.{.{ .net = 0, .role = .power, .domain = core, .mv = 1_800 }});
    defer intent.deinit(gpa);
    var before = try c.voltage(&intent);
    defer before.deinit(gpa);
    try testing.expectEqual(@as(f64, 1_800), before.hi.items[@backingInt(c.net(1))]);
    const past: NetId = @fromBackingInt(c.nets.netCount());
    const d = &c.devices;
    const first = d.terminal_start.items[d.terminal_start.items.len - 1];
    try d.kind.append(gpa, .resistor);
    try d.marker.append(gpa, d.marker.items[0]);
    try d.model.append(gpa, d.model.items[0]);
    try d.terminal_net.appendSlice(gpa, &.{ past, .none });
    try d.terminal_role.appendSlice(gpa, &.{ .{ .pin = 0 }, .{ .pin = 1 } });
    try d.terminal_start.append(gpa, first + 2);
    try intent.supply_net.append(gpa, past);
    try intent.supply_role.append(gpa, .power);
    try intent.supply_domain.append(gpa, @fromBackingInt(io));
    try intent.supply_voltage.append(gpa, .{ .raw = 5_000 });
    var after = try c.voltage(&intent);
    defer after.deinit(gpa);
    try testing.expectEqualSlices(f64, before.lo.items, after.lo.items);
    try testing.expectEqualSlices(f64, before.hi.items, after.hi.items);
    try testing.expectEqualSlices(f64, before.nominal_lo.items, after.nominal_lo.items);
    try testing.expectEqualSlices(f64, before.nominal_hi.items, after.nominal_hi.items);
}
