//! The voltage_rules tests of kinds outside the domain and ESD families:
//! `esd_topological` (the supply family's), `forward_diode` and
//! `guard_ring_bias` (the latch-up family's), on the same hand-drawn
//! netlists. Ported from crates/check/tests/erc/voltage_rules.rs (`pads`,
//! `run_esd`, `backwards`, `rails` and their five tests). Unwired until
//! those kinds land (their rows refuse today); add it to tests/check.zig
//! then.
//!
//! Oracle throughout: construct-from-answer on hand-drawn netlists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const common = @import("common.zig");
const circuit_ = @import("circuit.zig");
const Circuit = circuit_.Circuit;
const build = circuit_.build;
const mos = circuit_.mos;
const twoPin = circuit_.twoPin;
const StrId = geom.StrId;
const PolyId = geom.PolyId;
const Measurement = check.report.Measurement;
const erc = check.erc;
const IntentMap = erc.facts.IntentMap;
const deinitTable = erc.rule_set.deinitTable;
const gpa = common.gpa;

const core: u32 = 1;

// ---- private ----

/// Nets: 0 VDD, 1 VSS, 2 PAD, 3 PAD2; every rail is a pad. PAD has an up
/// diode to VDD and a down diode from VSS. PAD2 has only the up diode; its
/// resistor to VSS is not a clamp model and must not count.
fn pads(a: Allocator, rail_clamp: bool) !Circuit {
    var devices: std.ArrayList(circuit_.DeviceSpec) = .empty;
    try devices.appendSlice(a, &.{
        try twoPin(a, .diode, "esd_diode", 2, 0),
        try twoPin(a, .diode, "esd_diode", 1, 2),
        try twoPin(a, .diode, "esd_diode", 3, 0),
        try twoPin(a, .resistor, "rpoly", 3, 1),
    });
    if (rail_clamp) try devices.append(a, try mos(a, "rail_clamp", 1, 1, 0, 1));
    return build(4, devices.items);
}

/// VDD the core's power, VSS its ground.
fn rails(c: *const Circuit) !IntentMap {
    return c.intent(&.{ .{ .net = 0, .role = .power, .domain = core, .mv = 1_800 }, .{ .net = 1, .role = .ground, .domain = core, .mv = 1_800 } });
}

/// One `esd_topological` row over the rails, clamps `esd_diode` and (when
/// the circuit names it) `rail_clamp`.
fn runEsd(c: *const Circuit, id: StrId, sink: *common.Sink) !void {
    var intent = try rails(c);
    defer intent.deinit(gpa);
    var t: erc.supply_tables.EsdTopologicalTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, id, .@"error");
    try t.pad.append(gpa, c.case.layers.rail);
    try t.clamp.append(gpa, c.model("esd_diode"));
    if (c.strings.get("rail_clamp")) |s| try t.clamp.append(gpa, s);
    try t.clamp_start.appendSlice(gpa, &.{ 0, @intCast(t.clamp.items.len) });
    try erc.supply.checkEsdTopological(sink.record(), c.design(), &intent, &t);
}

/// Nets: 0 VDD, 1 VSS, 2 SIG; a `dio` diode with its anode on VDD and its
/// cathode on VSS, and a resistor from SIG to VSS.
fn backwards(a: Allocator) !Circuit {
    return build(3, &.{ try twoPin(a, .diode, "dio", 0, 1), try twoPin(a, .resistor, "rs", 2, 1) });
}

fn on(c: *const Circuit, n: usize) PolyId {
    return c.case.expected_net_polys[n][0];
}

test "a pad missing its vss clamp is flagged and one with both is clean" {
    // Oracle: construct-from-answer, read off `pads`: PAD has a clamp to
    // each rail, PAD2 only to VDD (its resistor is no clamp model), and the
    // rails reach only themselves: three of four pads flagged.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try pads(arena.allocator(), false);
    defer c.deinit();
    var sink: common.Sink = .{};
    defer sink.deinit();
    const id = common.rule(13);
    try runEsd(&c, id, &sink);
    const run = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(@as(u64, 4), run.examined);
    try testing.expectEqual(@as(u32, 3), run.violations);
    try testing.expectEqualSlices(PolyId, &.{ on(&c, 0), on(&c, 1), on(&c, 3) }, sink.out.shape_a.items);
    for (0..sink.out.len()) |i| try testing.expect(sink.out.get(@intCast(i)).measured.eql(Measurement.count(1)));
}

test "a rail clamp completes every pad path" {
    // Oracle: construct-from-answer. The rail clamp joins VDD to VSS, which
    // completes PAD2's path and each rail's: four pads, none flagged.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try pads(arena.allocator(), true);
    defer c.deinit();
    var sink: common.Sink = .{};
    defer sink.deinit();
    const id = common.rule(14);
    try runEsd(&c, id, &sink);
    const run = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(@as(u64, 4), run.examined);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "a diode from vdd to vss is forward biased" {
    // Oracle: construct-from-answer: anode at 1.8 V, cathode at 0 V, and no
    // polygon of the marker layer (the rails) encloses the diode's marker,
    // so it is flagged at 1800 mV.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try backwards(arena.allocator());
    defer c.deinit();
    var intent = try rails(&c);
    defer intent.deinit(gpa);
    var v = try c.voltage(&intent);
    defer v.deinit(gpa);
    var t: erc.latchup_tables.ForwardDiodeTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, common.rule(18), .@"error");
    try t.marker.append(gpa, c.case.layers.rail);
    try t.model_start.appendSlice(gpa, &.{ 0, 1 });
    try t.model.append(gpa, c.model("dio"));
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.latchup.checkForwardDiode(sink.record(), c.design(), &intent, &v, &t);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(Measurement.voltage(.{ .raw = 1_800 })));
}

test "a p ring belongs on a ground" {
    // Oracle: construct-from-answer, read off `backwards`: the rails are
    // the ring polygons; VDD measures 1800 mV against 0, SIG 0 supplies
    // against 1, VSS nothing.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try backwards(arena.allocator());
    defer c.deinit();
    var intent = try rails(&c);
    defer intent.deinit(gpa);
    var t: erc.latchup_tables.GuardRingBiasTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, common.rule(19), .@"error");
    try t.ring.append(gpa, c.case.layers.rail);
    try t.power.append(gpa, false);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.latchup.checkGuardRingBias(sink.record(), c.design(), &intent, &t);
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    const vdd_first = @backingInt(sink.out.shape_a.items[0]) < @backingInt(sink.out.shape_a.items[1]);
    const vdd: u32 = if (vdd_first) 0 else 1;
    try testing.expectEqual(on(&c, 0), sink.out.shape_a.items[vdd]);
    try testing.expect(sink.out.get(vdd).measured.eql(Measurement.voltage(.{ .raw = 1_800 })));
    try testing.expectEqual(on(&c, 2), sink.out.shape_a.items[1 - vdd]);
    try testing.expect(sink.out.get(1 - vdd).measured.eql(Measurement.count(0)));
}

test "a pad with only forward wired diodes reaches no rail" {
    // Oracle: construct-from-answer, per `reverseBiased`'s contract: nets 0
    // VDD, 1 VSS, 2 PAD; a diode VDD → PAD (anode at 1.8 V) and one PAD →
    // VSS (cathode at 0 V), plus the rail clamp so the rails themselves are
    // clean: three pads examined, PAD alone flagged, reaching 0 rail kinds
    // of 2.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try build(3, &.{ try twoPin(a, .diode, "esd_diode", 0, 2), try twoPin(a, .diode, "esd_diode", 2, 1), try mos(a, "rail_clamp", 1, 1, 0, 1) });
    defer c.deinit();
    var sink: common.Sink = .{};
    defer sink.deinit();
    const id = common.rule(15);
    try runEsd(&c, id, &sink);
    const run = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(@as(u64, 3), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
    try testing.expectEqualSlices(PolyId, &.{on(&c, 2)}, sink.out.shape_a.items);
    try testing.expect(sink.out.get(0).measured.eql(Measurement.count(0)));
}
