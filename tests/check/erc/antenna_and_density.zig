//! Antenna ratios and windowed density: areas over areas, so each has a
//! closed form stated by drawing it, or (density) by asking
//! `randomRectilinearLayer` for disjoint geometry whose covered area it
//! computed while placing it. Ported from
//! crates/check/tests/erc/antenna_and_density.rs.

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
const Violations = report.Violations;
const topology = check.topology;
const NetTable = topology.NetTable;
const DeviceTable = topology.DeviceTable;
const LayerId = geom.LayerId;
const DbuArea = geom.DbuArea;
const at = erc.antenna_tables;
const Stack = at.Stack;
const AntennaMeasure = at.AntennaMeasure;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Handle = testgen.shapes.Handle;

/// A drawn layout and the nets its connectivity extracts (none without one).
const Drawn = struct {
    lb: LayoutBuilder,
    store: geom.GeometryStore = .empty,
    ids: testgen.shapes.Ids = .{},
    nets: NetTable = .{},
    devices: DeviceTable = .{},

    fn init(layers: u16) Drawn {
        return .{ .lb = LayoutBuilder.init(layers) };
    }

    fn rect(d: *Drawn, layer: u16, xlo: i64, ylo: i64, xhi: i64, yhi: i64) !Handle {
        return d.lb.rect(gpa, layer, xlo, ylo, xhi, yhi);
    }

    fn finish(d: *Drawn, connectivity: ?ingest.deck.Connectivity) !void {
        try d.lb.finish(gpa, &d.store, &d.ids);
        if (connectivity) |c| try topology.extractNetsInto(gpa, &d.store, &c, &d.nets);
    }

    fn deinit(d: *Drawn) void {
        d.lb.deinit(gpa);
        d.store.deinit(gpa);
        d.ids.deinit(gpa);
        d.nets.deinit(gpa);
        d.devices.deinit(gpa);
    }

    fn design(d: *const Drawn) erc.head.Design {
        return .{ .store = &d.store, .nets = &d.nets, .devices = &d.devices };
    }
};

/// A collector edge of a test row: layer and measure.
const Collect = struct { layer: u16, measure: AntennaMeasure = .area };

/// SKY130's met1 antenna rule in its DRM form: MAX_EGAR 400, K 400 per µm²,
/// diode_bonus 2200.
const sky130_met1: [3]f64 = .{ 400.0, 2200.0, 400.0 };

/// The sky130 LEF's met1 `ANTENNADIFFSIDEAREARATIO PWL ( ( 0 400 )
/// ( 0.0125 400 ) ( 0.0225 2609 ) ( 22.5 11600 ) )`, in nm².
const sky130_met1_pwl = [_]at.AreaPoint{ .{ .area = 0, .value = 400.0 }, .{ .area = 12_500, .value = 400.0 }, .{ .area = 22_500, .value = 2609.0 }, .{ .area = 22_500_000, .value = 11600.0 } };

// ---- private ----

fn lid(n: u16) LayerId {
    return @fromBackingInt(n);
}

/// The ratio on violation `row`; fails unless it is one.
fn measuredRatio(v: *const Violations, row: u32) !f64 {
    const m = v.get(row).measured;
    if (m.kind != .ratio) return error.NotARatio;
    return m.float();
}

/// A gate (layer 2) joined by a via (layer 1) to a metal wire (layer 0) four
/// times its area: a ratio of exactly four.
fn gateOnALongWire(d: *Drawn) !geom.PolyId {
    d.* = .init(3);
    _ = try d.rect(0, 0, 0, 4_000, 1_000);
    const gate = try d.rect(2, 0, 0, 1_000, 1_000);
    _ = try d.rect(1, 400, 400, 600, 600);
    try d.finish(.{ .conductors = &.{ lid(0), lid(2) }, .via_cut = &.{lid(1)}, .via_connects = &.{.{ lid(0), lid(2) }} });
    return d.ids.of(gate);
}

/// A gate under a two-level stack, all one net: metal 1 (layer 0) twice the
/// gate (layer 2), metal 2 (layer 3) ten times it; stage ratios 2 and 12.
fn gateUnderATwoLevelStack(d: *Drawn) !geom.PolyId {
    d.* = .init(5);
    _ = try d.rect(0, 0, 0, 2_000, 1_000);
    const gate = try d.rect(2, 0, 0, 1_000, 1_000);
    _ = try d.rect(3, 0, 0, 10_000, 1_000);
    _ = try d.rect(1, 400, 400, 600, 600);
    _ = try d.rect(4, 1_500, 400, 1_700, 600);
    try d.finish(.{ .conductors = &.{ lid(0), lid(2), lid(3) }, .via_cut = &.{ lid(1), lid(4) }, .via_connects = &.{ .{ lid(0), lid(2) }, .{ lid(0), lid(3) } } });
    return d.ids.of(gate);
}

/// Appends one `antenna` row over `collectors` to `t`.
fn antennaRow(t: *at.AntennaTable, id: geom.StrId, gate: u16, collectors: []const Collect, max_ratio: f64) !void {
    try t.head.push(gpa, id, .@"error");
    if (t.collector_start.items.len == 0) try t.collector_start.append(gpa, 0);
    try t.gate.append(gpa, lid(gate));
    for (collectors) |c| {
        try t.collector.append(gpa, lid(c.layer));
        try t.collector_measure.append(gpa, c.measure);
    }
    try t.collector_start.append(gpa, @intCast(t.collector.items.len));
    try t.max_ratio.append(gpa, max_ratio);
    try t.diode.append(gpa, null);
    try t.diode_area.append(gpa, null);
    try t.diode_min.append(gpa, null);
}

fn runAntenna(sink: *common.Sink, d: *const Drawn, t: *const at.AntennaTable, stack: Stack) !void {
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.antenna.checkAntenna(sink.record(), d.design(), &.{}, t, stack, &scratch);
}

/// One antenna row (rule 90) over `stack`, against no finished nets (the
/// row builds its own at its etch step).
fn runStaged(sink: *common.Sink, d: *const Drawn, stack: Stack, gate: u16, collectors: []const Collect, max_ratio: f64) !void {
    var t: at.AntennaTable = .{};
    defer erc.rule_set.deinitTable(gpa, &t);
    try antennaRow(&t, common.rule(90), gate, collectors, max_ratio);
    try runAntenna(sink, d, &t, stack);
}

/// A die-sized window over layer 0, with only the bounds given.
fn densityTable(id: geom.StrId, side: i64, min: ?f64, max: ?f64) !at.DensityCmpTable {
    var t: at.DensityCmpTable = .{ .head = try common.head(id) };
    try t.layer.append(gpa, lid(0));
    try t.window.append(gpa, .{ side, side });
    try t.step.append(gpa, .{ side, side });
    try t.min_density.append(gpa, min);
    try t.max_density.append(gpa, max);
    try t.max_neighbour_delta.append(gpa, null);
    try t.cmp.append(gpa, null);
    try t.include_partial_windows.append(gpa, true);
    return t;
}

fn dieOf(side: i64) geom.Bbox {
    return .{ .xlo = 0, .ylo = 0, .xhi = side, .yhi = side };
}

fn runDensity(sink: *common.Sink, d: *const Drawn, die: geom.Bbox, t: *const at.DensityCmpTable) !void {
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.antenna.checkDensityCmp(sink.record(), d.design(), die, t, &scratch);
}

/// A 1 µm² gate (layer 2) joined by a cut (layer 1) to a wire on layer 0
/// of `wire` rectangles and, with `diode`, a diode (layer 3) of `(w, h)` nm
/// joined to the wire by a second cut.
fn gateWireDiode(d: *Drawn, wire: []const [4]i64, diode: ?[2]i64) !void {
    d.* = .init(4);
    for (wire) |w| _ = try d.rect(0, w[0], w[1], w[2], w[3]);
    _ = try d.rect(2, 0, 0, 1_000, 1_000);
    _ = try d.rect(1, 400, 400, 600, 600);
    if (diode) |wh| {
        _ = try d.rect(3, 2_000, 0, 2_000 + wh[0], wh[1]);
        _ = try d.rect(1, 2_100, 100, 2_200, 200);
    }
    try d.finish(.{ .conductors = &.{ lid(0), lid(2), lid(3) }, .via_cut = &.{ lid(1), lid(1) }, .via_connects = &.{ .{ lid(0), lid(2) }, .{ lid(0), lid(3) } }, .intra_layer_touch = true });
}

/// A wire of `um2` µm², a micrometre wide.
fn wireOf(um2: i64) [1][4]i64 {
    return .{.{ 0, 0, um2 * 1_000, 1_000 }};
}

/// An `antenna_electrical` row on `gateWireDiode`: credit, bonus and limit
/// (`model`) and a `diode_max_ratio` table in nm².
fn creditRow(id: geom.StrId, model: [3]f64, table: []const at.AreaPoint, diode: ?u16) !at.AntennaElectricalTable {
    var t: at.AntennaElectricalTable = .{ .head = try common.head(id) };
    try t.gate.append(gpa, lid(2));
    try t.collector_start.appendSlice(gpa, &.{ 0, 1 });
    try t.collector.append(gpa, lid(0));
    try t.collector_measure.append(gpa, .area);
    try t.diode.append(gpa, if (diode) |l| lid(l) else null);
    try t.diode_credit.append(gpa, model[0]);
    try t.diode_bonus.append(gpa, model[1]);
    try t.cut_factor.append(gpa, 1.0);
    try t.area_minus_diode.append(gpa, 0.0);
    try t.gate_plus_diode.append(gpa, 0.0);
    try t.diode_reduce_start.appendSlice(gpa, &.{ 0, 0 });
    try t.diode_max_ratio_start.appendSlice(gpa, &.{ 0, @intCast(table.len) });
    try t.diode_max_ratio.appendSlice(gpa, table);
    try t.exempt.append(gpa, null);
    try t.max_ratio.append(gpa, model[2]);
    return t;
}

/// The one fix hint of an `antenna_electrical` run over `wire` and `diode`,
/// the run's examined count checked at one; fails unless one row.
fn fixOf(wire: []const [4]i64, diode: ?[2]i64, model: [3]f64, table: []const at.AreaPoint) !?Measurement {
    var d: Drawn = undefined;
    try gateWireDiode(&d, wire, diode);
    defer d.deinit();
    const id = common.rule(90);
    var t = try creditRow(id, model, table, 3);
    defer erc.rule_set.deinitTable(gpa, &t);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.antenna.checkAntennaElectrical(sink.record(), d.design(), &.{}, common.manufacturingGrid(), &t, .{}, &scratch);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    return sink.out.fixOf(0);
}

fn expectFix(want: ?DbuArea, got: ?Measurement) !void {
    if (want) |area| {
        try testing.expect(got != null and got.?.eql(Measurement.area(area)));
    } else try testing.expectEqual(null, got);
}

test "a per stage antenna ratio is the collecting area over the gate area" {
    // Oracle: closed form. 4 µm² of wire on a 1 µm² gate is exactly 4,
    // reported at the gate (what fails and takes a diode), not the wire.
    var d: Drawn = undefined;
    const gate = try gateOnALongWire(&d);
    defer d.deinit();
    const id = common.rule(70);
    var t: at.AntennaTable = .{};
    defer erc.rule_set.deinitTable(gpa, &t);
    try antennaRow(&t, id, 2, &.{.{ .layer = 0 }}, 3.0);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runAntenna(&sink, &d, &t, .{});
    const v = &sink.out;
    try testing.expectEqual(@as(u32, 1), v.len());
    try testing.expectEqual(id, v.rule.items[0]);
    try testing.expectEqual(gate, v.shape_a.items[0]);
    try testgen.assertCloseRelative("the antenna ratio", try measuredRatio(v, 0), 4.0, 1e-12);
    try testing.expect(v.get(0).limit.eql(Measurement.ratio(3.0)));
    try common.assertAtIsOnANamedShape(&d.store, v, 0);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
}

test "an antenna ratio under its limit is clean" {
    // Oracle: closed form. The same 4 against 5: only the verdict changes,
    // and the clean assertion still insists the gate net was examined.
    var d: Drawn = undefined;
    _ = try gateOnALongWire(&d);
    defer d.deinit();
    const id = common.rule(71);
    var t: at.AntennaTable = .{};
    defer erc.rule_set.deinitTable(gpa, &t);
    try antennaRow(&t, id, 2, &.{.{ .layer = 0 }}, 5.0);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runAntenna(&sink, &d, &t, .{});
    try testgen.assertClean(sink.runs.items, &sink.out, id);
}

test "the cumulative antenna ratio with no diode is the same division" {
    // Oracle: closed form. With no diode the cumulative form reduces to the
    // same division: 4, not 5 (a rule counting the gate into its own
    // numerator).
    var d: Drawn = undefined;
    const gate = try gateOnALongWire(&d);
    defer d.deinit();
    const id = common.rule(72);
    var t = try creditRow(id, .{ 0.0, 0.0, 3.0 }, &.{}, null);
    defer erc.rule_set.deinitTable(gpa, &t);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.antenna.checkAntennaElectrical(sink.record(), d.design(), &.{}, common.manufacturingGrid(), &t, .{}, &scratch);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(gate, sink.out.shape_a.items[0]);
    try testgen.assertCloseRelative("the cumulative ratio", try measuredRatio(&sink.out, 0), 4.0, 1e-12);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
}

test "a cumulative antenna check measures each fabrication stage over what exists at it" {
    // Oracle: closed form. One row per stage: metal 1 alone reads 2, metal 1
    // and metal 2 read 12. A rule measuring the final stack at every stage
    // reads 12 twice; one collecting only the stage's own layer reads 10.
    var d: Drawn = undefined;
    const gate = try gateUnderATwoLevelStack(&d);
    defer d.deinit();
    const early = common.rule(80);
    const late = common.rule(81);
    var t: at.AntennaTable = .{};
    defer erc.rule_set.deinitTable(gpa, &t);
    try antennaRow(&t, early, 2, &.{.{ .layer = 0 }}, 1.0);
    try antennaRow(&t, late, 2, &.{ .{ .layer = 0 }, .{ .layer = 3 } }, 1.0);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runAntenna(&sink, &d, &t, .{});
    try testing.expectEqual(@as(usize, 2), sink.runs.items.len);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, early)).examined);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, late)).examined);
    try testing.expectEqualSlices(geom.StrId, &.{ early, late }, sink.out.rule.items);
    for (sink.out.shape_a.items) |s| try testing.expectEqual(gate, s);
    try testgen.assertCloseRelative("metal 1 only", try measuredRatio(&sink.out, 0), 2.0, 1e-12);
    try testgen.assertCloseRelative("both metals", try measuredRatio(&sink.out, 1), 12.0, 1e-12);
}

test "each later fabrication stage reports at least the ratio the one before it did" {
    // Oracle: law. Cumulative collecting area only grows as the stack is
    // built, so a later stage never measures less over the same gate.
    var d: Drawn = undefined;
    _ = try gateUnderATwoLevelStack(&d);
    defer d.deinit();
    const stages = [_]geom.StrId{ common.rule(82), common.rule(83) };
    var t: at.AntennaTable = .{};
    defer erc.rule_set.deinitTable(gpa, &t);
    try antennaRow(&t, stages[0], 2, &.{.{ .layer = 0 }}, std.math.floatMin(f64));
    try antennaRow(&t, stages[1], 2, &.{ .{ .layer = 0 }, .{ .layer = 3 } }, std.math.floatMin(f64));
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runAntenna(&sink, &d, &t, .{});
    try testing.expectEqual(@as(usize, 2), sink.runs.items.len);
    var ratios: [2]f64 = undefined;
    for (stages, &ratios) |id, *ratio| {
        const row = std.mem.indexOfScalar(geom.StrId, sink.out.rule.items, id) orelse return error.StageDidNotReport;
        ratio.* = try measuredRatio(&sink.out, @intCast(row));
    }
    try testing.expect(ratios[0] <= ratios[1]);
}

test "gf180 ant 2 sidewall area of metal1 over a derived gate" {
    // Oracle: foundry example, gf180 ANT.2, by hand: 2 x 1000.2 um x 0.55 um
    // = 1100.22 um2 of sidewall over a 1 um2 gate, a ratio of 1100.22.
    const poly = 0;
    const gate = 1;
    const contact = 2;
    const metal1 = 3;
    var d: Drawn = .init(4);
    defer d.deinit();
    _ = try d.rect(poly, 0, 0, 3_000, 1_000);
    const gate_poly = try d.rect(gate, 0, 0, 1_000, 1_000);
    _ = try d.rect(contact, 2_400, 400, 2_600, 600);
    _ = try d.rect(metal1, 2_000, 400, 1_002_000, 600);
    try d.finish(null);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runStaged(&sink, &d, .{ .conductors = &.{ lid(poly), lid(metal1) }, .via_cut = &.{lid(contact)}, .via_connects = &.{.{ lid(poly), lid(metal1) }}, .intra_layer_touch = true }, gate, &.{.{ .layer = metal1, .measure = .{ .sidewall = 550 } }}, 400.0);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(d.ids.of(gate_poly), sink.out.shape_a.items[0]);
    try testgen.assertCloseRelative("the sidewall ratio", try measuredRatio(&sink.out, 0), 1100.22, 1e-12);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, common.rule(90))).examined);
}

test "a gate joined only through upper metal does not share the charge at metal1" {
    // Oracle: hand-derived, with the per-etch-step convention of SVRF/KLayout
    // decks and LEF CAR: at metal1 gate A alone reads 6; summed over the
    // stages A reads 6/1 + 6/2 = 9 and B 1/1 + 6/2 = 4, at the limit.
    const poly = 0;
    const contact = 1;
    const metal1 = 2;
    const via1 = 3;
    const metal2 = 4;
    var d: Drawn = .init(5);
    defer d.deinit();
    const gate_a = try d.rect(poly, 0, 0, 1_000, 1_000);
    _ = try d.rect(poly, 10_000, 0, 11_000, 1_000);
    _ = try d.rect(contact, 400, 400, 600, 600);
    _ = try d.rect(contact, 10_400, 400, 10_600, 600);
    _ = try d.rect(metal1, 0, 0, 6_000, 1_000);
    _ = try d.rect(metal1, 10_000, 0, 11_000, 1_000);
    _ = try d.rect(via1, 5_400, 400, 5_600, 600);
    _ = try d.rect(via1, 10_400, 400, 10_600, 600);
    _ = try d.rect(metal2, 5_000, 0, 11_000, 1_000);
    try d.finish(null);
    const stack: Stack = .{ .conductors = &.{ lid(poly), lid(metal1), lid(metal2) }, .via_cut = &.{ lid(contact), lid(via1) }, .via_connects = &.{ .{ lid(poly), lid(metal1) }, .{ lid(metal1), lid(metal2) } }, .intra_layer_touch = true };
    for ([_]struct { []const Collect, f64 }{ .{ &.{.{ .layer = metal1 }}, 6.0 }, .{ &.{ .{ .layer = metal1 }, .{ .layer = metal2 } }, 9.0 } }) |c| {
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runStaged(&sink, &d, stack, poly, c[0], 4.0);
        try testing.expectEqual(@as(u32, 1), sink.out.len());
        try testing.expectEqual(d.ids.of(gate_a), sink.out.shape_a.items[0]);
        try testgen.assertCloseRelative("gate A", try measuredRatio(&sink.out, 0), c[1], 1e-12);
        try testing.expectEqual(@as(u64, 2), (try testgen.assertRuleRan(sink.runs.items, common.rule(90))).examined);
    }
}

test "a gate joins its poly not the well it sits in" {
    // Oracle: construct-from-answer. The gate's poly collects no metal, so
    // the gate is clean under a ratio of 1; joined to the well instead it
    // would read the tap's 10 um2.
    const well = 0;
    const tap = 1;
    const tie = 2;
    const poly = 3;
    const gate = 4;
    const contact = 5;
    const metal1 = 6;
    var d: Drawn = .init(7);
    defer d.deinit();
    _ = try d.rect(well, -20_000, -5_000, 20_000, 5_000);
    _ = try d.rect(tap, -15_000, 0, -10_000, 1_000);
    _ = try d.rect(tie, -15_000, 0, -10_000, 1_000);
    _ = try d.rect(contact, -12_600, 400, -12_400, 600);
    _ = try d.rect(metal1, -15_000, 0, -5_000, 1_000);
    _ = try d.rect(poly, 0, 0, 1_000, 1_000);
    _ = try d.rect(gate, 0, 0, 1_000, 1_000);
    try d.finish(null);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runStaged(&sink, &d, .{ .conductors = &.{ lid(tap), lid(well), lid(poly), lid(metal1) }, .via_cut = &.{ lid(tie), lid(contact) }, .via_connects = &.{ .{ lid(tap), lid(well) }, .{ lid(tap), lid(metal1) } }, .intra_layer_touch = true }, gate, &.{.{ .layer = metal1 }}, 1.0);
    try testgen.assertClean(sink.runs.items, &sink.out, common.rule(90));
}

test "a layer covering half the die reads as a density of one half" {
    // Oracle: closed form. Half a square die is exactly 0.5 in one die-sized
    // window; both bounds are checked from the same geometry, since a rule
    // swapping them passes a test stating only one.
    var d: Drawn = .init(1);
    defer d.deinit();
    _ = try d.rect(0, 0, 0, 1_000, 2_000);
    try d.finish(null);
    const die = dieOf(2_000);
    for ([_]struct { u32, ?f64, ?f64, f64 }{ .{ 73, null, 0.4, 0.4 }, .{ 74, 0.6, null, 0.6 } }) |c| {
        const id = common.rule(c[0]);
        var t = try densityTable(id, 2_000, c[1], c[2]);
        defer erc.rule_set.deinitTable(gpa, &t);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runDensity(&sink, &d, die, &t);
        try testing.expectEqual(@as(u32, 1), sink.out.len());
        try testgen.assertCloseRelative("the density", try measuredRatio(&sink.out, 0), 0.5, 1e-12);
        try testing.expect(sink.out.get(0).limit.eql(Measurement.ratio(c[3])));
        try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
    }
    const between = common.rule(75);
    var t = try densityTable(between, 2_000, 0.4, 0.6);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runDensity(&sink, &d, die, &t);
    try testgen.assertClean(sink.runs.items, &sink.out, between);
}

test "a die quartered into four windows reports each window's own density" {
    // Oracle: construct-from-answer. Two left windows full, two right empty:
    // a 0.9 ceiling catches two, a 0.1 floor the other two; four windows
    // examined either way.
    var d: Drawn = .init(1);
    defer d.deinit();
    _ = try d.rect(0, 0, 0, 1_000, 2_000);
    try d.finish(null);
    const die = dieOf(2_000);
    for ([_]struct { u32, ?f64, ?f64, f64 }{ .{ 76, null, 0.9, 1.0 }, .{ 77, 0.1, null, 0.0 } }) |c| {
        const id = common.rule(c[0]);
        var t = try densityTable(id, 1_000, c[1], c[2]);
        defer erc.rule_set.deinitTable(gpa, &t);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runDensity(&sink, &d, die, &t);
        try testing.expectEqual(@as(u64, 4), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
        try testing.expectEqual(@as(u32, 2), sink.out.len());
        for (0..2) |row| try testgen.assertClose("a window", try measuredRatio(&sink.out, @intCast(row)), c[3], 1e-12);
    }
}

test "windowed density over generated geometry matches the area the generator covered" {
    // Oracle: closed form, on arbitrary geometry. The generator's squares are
    // disjoint and it reports their covered area, so a window over the whole
    // region reads `covered / extent²` exactly. Bounding boxes read high.
    var rng = testgen.Rng.init(97);
    var d: Drawn = .init(1);
    defer d.deinit();
    const placed = try testgen.shapes.randomRectilinearLayer(&d.lb, gpa, &rng, 0, .{ 0, 0 }, .{ .cells = 8, .cell = 500, .density = 0.35 });
    try d.finish(null);
    const extent: f64 = @floatFromInt(placed.extent);
    const expected = @as(f64, @floatFromInt(placed.covered)) / (extent * extent);
    const id = common.rule(78);
    var t = try densityTable(id, placed.extent, null, expected / 2.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runDensity(&sink, &d, dieOf(placed.extent), &t);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testgen.assertCloseRelative("the density of generated geometry", try measuredRatio(&sink.out, 0), expected, 1e-12);
}

test "every window's density is a fraction between zero and one" {
    // Oracle: law. A covered fraction lies in [0, 1] for every window of
    // every layout; summing overlaps, or dividing by an unclipped window,
    // escapes it.
    for ([_]u64{ 1, 2, 3 }) |seed| {
        var rng = testgen.Rng.init(seed);
        var d: Drawn = .init(1);
        defer d.deinit();
        const placed = try testgen.shapes.randomRectilinearLayer(&d.lb, gpa, &rng, 0, .{ 0, 0 }, .{ .cells = 6, .cell = 400, .density = 0.5 });
        try d.finish(null);
        const id = common.rule(79);
        var t = try densityTable(id, @divTrunc(placed.extent, 3), 1.000_001, null);
        defer erc.rule_set.deinitTable(gpa, &t);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runDensity(&sink, &d, dieOf(placed.extent), &t);
        try testing.expectEqual(@as(u64, 9), (try testgen.assertRuleRan(sink.runs.items, id)).examined);
        try testing.expectEqual(@as(u32, 9), sink.out.len());
        for (0..9) |row| {
            const density = try measuredRatio(&sink.out, @intCast(row));
            try testing.expect(density >= 0.0 and density <= 1.0);
        }
    }
}

test "an antenna fix hint is the drm rule solved for the diode area" {
    // Oracle: closed form, the SKY130 DRM's antenna rule solved for the diode
    // area (catalog ERC-A15). EGAR = ratio - 400 diode - 2200 <= 400 gives
    // (ratio - 2600)/400 µm²: 2650 needs 0.125 µm², 3000 needs 1 µm²; at
    // 2500 the bonus alone clears it, so one nm²; a net holding 0.5 µm² at
    // 3000 needs 0.5 µm² more.
    try expectFix(125_000, try fixOf(&wireOf(2650), null, sky130_met1, &.{}));
    try expectFix(1_000_000, try fixOf(&wireOf(3000), null, sky130_met1, &.{}));
    try expectFix(1, try fixOf(&wireOf(2500), null, sky130_met1, &.{}));
    try expectFix(500_000, try fixOf(&wireOf(3000), .{ 500, 1_000 }, sky130_met1, &.{}));
}

test "an antenna fix hint reads a pwl limit table backwards" {
    // Oracle: closed form, the sky130 LEF's PWL read backwards (catalog
    // ERC-A15): at 2500, 12 500 + 2100 / 0.2209 = 22 006.6, so 22 007 nm²;
    // at 2650, 22 500 + 41 / 0.0004 = 125 000 nm² (the DRM form agrees); at
    // 12 000 the table holds 11 600 past its last point: no hint.
    const pwl: [3]f64 = .{ 0.0, 0.0, 400.0 };
    try expectFix(22_007, try fixOf(&wireOf(2500), null, pwl, &sky130_met1_pwl));
    try expectFix(125_000, try fixOf(&wireOf(2650), null, pwl, &sky130_met1_pwl));
    try expectFix(null, try fixOf(&wireOf(12_000), null, pwl, &sky130_met1_pwl));
}

test "an antenna fix hint matches the patent's worked solve" {
    // Oracle: spec example, US 9,142,556 B2 col. 6: a ratio of 25478.59873
    // against "(c)×400+2200" needs "(c)>58.196" µm²: 23 278.59873 / 400 =
    // 58.196 496 825 µm², 58 196 497 nm² rounded up.
    const wire = [_][4]i64{ .{ 0, 0, 200_000, 127_392 }, .{ 0, 127_392, 19_873, 127_402 } };
    try expectFix(58_196_497, try fixOf(&wire, null, .{ 400.0, 0.0, 2200.0 }, &.{}));
}

test "an antenna fix hint is ihp note 4" {
    // Oracle: spec example, IHP SG13G2 Ant.g Note 4, "PDarea (µm²) = 0.02 x
    // (Vn_area / (GatPoly over Activ)_area)" with Ant.g's 0.16 µm² diode as
    // the least (catalog ERC-A15): 100 needs 2 µm², 25 needs 0.5 µm², 5
    // needs 0.1 floored to 0.16; a row without `diode_area` names none.
    const Case = struct { um2: i64, max_ratio: f64, hint: bool, want: ?DbuArea };
    for ([_]Case{
        .{ .um2 = 100, .max_ratio = 20.0, .hint = true, .want = 2_000_000 },
        .{ .um2 = 25, .max_ratio = 20.0, .hint = true, .want = 500_000 },
        .{ .um2 = 5, .max_ratio = 1.0, .hint = true, .want = 160_000 },
        .{ .um2 = 100, .max_ratio = 20.0, .hint = false, .want = null },
    }) |c| {
        var d: Drawn = undefined;
        try gateWireDiode(&d, &wireOf(c.um2), null);
        defer d.deinit();
        var t: at.AntennaTable = .{};
        defer erc.rule_set.deinitTable(gpa, &t);
        try antennaRow(&t, common.rule(91), 2, &.{.{ .layer = 0 }}, c.max_ratio);
        if (c.hint) {
            t.diode_area.items[0] = 20_000;
            t.diode_min.items[0] = 160_000;
        }
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runAntenna(&sink, &d, &t, .{});
        try testing.expectEqual(@as(u32, 1), sink.out.len());
        try expectFix(c.want, sink.out.fixOf(0));
    }
}
