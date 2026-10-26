//! Supply, substrate and pad integrity: topological, but geometry-aware.
//! Oracle throughout: construct-from-answer: each layout is drawn so its
//! answer is decided by the drawing (a well with a tap and one without, a
//! conductor carrying both tap types, a net whose halves meet only through
//! a resistive body, a region whose furthest point from its tap is exactly
//! ten thousand units away on a 6-8-10 triangle). Ported from
//! crates/check/tests/erc/supply_rules.rs; its esd_latchup case
//! (`esd_latchup_reports_narrow_rings_and_rings_far_from_a_supply`) is the
//! reliability family's.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const Connectivity = @import("ingest").deck.Connectivity;
const erc = check.erc;
const supply = erc.supply;
const tables = erc.supply_tables;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const common = @import("common.zig");
const layouts = @import("layouts.zig");
const Drawn = layouts.Drawn;
const Extracted = layouts.Extracted;
const gpa = common.gpa;

// ---- private ----

fn l(i: u16) LayerId {
    return @fromBackingInt(i);
}

/// Layer 0 the well, layer 1 the tap; the right well's handle.
fn wells(tapped: bool) !struct { Drawn, PolyId } {
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
    const right = try lb.rect(gpa, 0, 3_000, 0, 4_000, 1_000);
    _ = try lb.rect(gpa, 1, 200, 200, 800, 800);
    if (tapped) _ = try lb.rect(gpa, 1, 3_200, 200, 3_800, 800);
    const d = try Drawn.init(&lb, .{});
    return .{ d, d.ids.of(right) };
}

fn floatingWell(d: *const Drawn, id: StrId, s: *common.Sink) !void {
    var t: erc.topology_tables.FloatingWellTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.well.append(gpa, l(0));
    try t.tap.append(gpa, l(1));
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.topology.checkFloatingWell(s.record(), d.design(), &t, &scratch);
}

fn missingTie(d: *const Drawn, id: StrId, limit: i64, s: *common.Sink) !void {
    var t: tables.MissingTieTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.region.append(gpa, l(0));
    try t.tap.append(gpa, l(1));
    try t.max_distance.append(gpa, limit);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try supply.checkMissingTie(s.record(), d.design(), &t, &scratch);
}

/// Layer 0 metal, 1 cut, 2 the n-tap, 3 the p-tap; `shorted`: one metal
/// shape carries both, else two carry one each.
fn taps(shorted: bool) !Drawn {
    var lb = LayoutBuilder.init(4);
    if (shorted) {
        _ = try lb.rect(gpa, 0, 0, 0, 3_000, 1_000);
    } else {
        _ = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
        _ = try lb.rect(gpa, 0, 2_000, 0, 3_000, 1_000);
    }
    _ = try lb.rect(gpa, 2, 0, 0, 1_000, 1_000);
    _ = try lb.rect(gpa, 3, 2_000, 0, 3_000, 1_000);
    _ = try lb.rect(gpa, 1, 400, 400, 600, 600);
    _ = try lb.rect(gpa, 1, 2_400, 400, 2_600, 600);
    return Drawn.init(&lb, layouts.viaConnectivity(1, &.{ 2, 3 }));
}

/// The shorted taps plus a scope shape (layer 4) round the n-tap when
/// `scoped`, else away from both.
fn scopedTaps(scoped: bool) !Drawn {
    var lb = LayoutBuilder.init(5);
    _ = try lb.rect(gpa, 0, 0, 0, 3_000, 1_000);
    _ = try lb.rect(gpa, 2, 0, 0, 1_000, 1_000);
    _ = try lb.rect(gpa, 3, 2_000, 0, 3_000, 1_000);
    _ = try lb.rect(gpa, 1, 400, 400, 600, 600);
    _ = try lb.rect(gpa, 1, 2_400, 400, 2_600, 600);
    if (scoped) _ = try lb.rect(gpa, 4, -500, -500, 1_500, 1_500) else _ = try lb.rect(gpa, 4, 10_000, 0, 12_000, 2_000);
    return Drawn.init(&lb, layouts.viaConnectivity(1, &.{ 2, 3 }));
}

fn supplyShort(d: *const Drawn, id: StrId, within: ?LayerId, s: *common.Sink) !void {
    var t: tables.SupplyShortTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.tap_a.append(gpa, l(2));
    try t.tap_b.append(gpa, l(3));
    try t.within.append(gpa, within);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try supply.checkSupplyShort(s.record(), d.design(), &t, &scratch);
}

/// Two metal islands bridged by a resistive body on layer 2, or one metal
/// shape with the body alongside; the islands' handles.
fn bridged(two_islands: bool) !struct { Drawn, ?[2]PolyId } {
    var lb = LayoutBuilder.init(3);
    var halves: ?[2]testgen.shapes.Handle = null;
    if (two_islands) {
        halves = .{ try lb.rect(gpa, 0, 0, 0, 1_000, 1_000), try lb.rect(gpa, 0, 3_000, 0, 4_000, 1_000) };
    } else _ = try lb.rect(gpa, 0, 0, 0, 4_000, 1_000);
    _ = try lb.rect(gpa, 2, 0, 200, 4_000, 800);
    _ = try lb.rect(gpa, 1, 400, 400, 600, 600);
    _ = try lb.rect(gpa, 1, 3_400, 400, 3_600, 600);
    const d = try Drawn.init(&lb, layouts.viaConnectivity(1, &.{2}));
    return .{ d, if (halves) |h| .{ d.ids.of(h[0]), d.ids.of(h[1]) } else null };
}

fn softConnection(d: *const Drawn, id: StrId, connectivity: Connectivity, s: *common.Sink) !void {
    var t: tables.SoftConnectionTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.soft_start.appendSlice(gpa, &.{ 0, 1 });
    try t.soft.append(gpa, l(2));
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try supply.checkSoftConnection(s.record(), d.design(), &t, &connectivity, &scratch);
}

/// One transistor, gate and first channel end on net 0, other end on
/// `other_end`, bulk on net 2.
fn tiedOff(terms: *[4]testgen.netlist.TerminalSpec, devs: *[1]testgen.netlist.DeviceSpec, other_end: u32) testgen.netlist.NetlistSpec {
    terms.* = .{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 0 }, .{ .role = .drain, .net = other_end }, .{ .role = .bulk, .net = 2 } };
    devs.* = .{layouts.mos("nch", terms)};
    return .{ .nets = 3, .devices = devs };
}

fn tieHighLow(e: *const Extracted, intent: *const erc.facts.IntentMap, id: StrId, s: *common.Sink) !void {
    var t: tables.TieHighLowTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try supply.checkTieHighLow(s.record(), e.design(), &e.facts, intent, &t);
}

test "a well with no tap inside it is flagged at that well" {
    // Oracle: construct-from-answer. Two wells, one with a tap inside; the
    // untapped one is the polygon the violation names.
    var w = try wells(false);
    defer w[0].deinit();
    const id = common.rule(50);
    var s: common.Sink = .{};
    defer s.deinit();
    try floatingWell(&w[0], id, &s);
    try testing.expectEqual(@as(u32, 1), s.out.len());
    try testing.expectEqual(id, s.out.rule.items[0]);
    try testing.expectEqual(w[1], s.out.shape_a.items[0]);
    try testing.expectEqual(l(0), s.out.layer.items[0]);
    try common.assertAtIsOnANamedShape(&w[0].store, &s.out, 0);
    const run = try testgen.assertRuleRan(s.runs.items, id);
    try testing.expectEqual(@as(u64, 2), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "wells that each hold a tap are clean" {
    // Oracle: construct-from-answer. A tap in each well: nothing found,
    // both wells examined.
    var w = try wells(true);
    defer w[0].deinit();
    const id = common.rule(51);
    var s: common.Sink = .{};
    defer s.deinit();
    try floatingWell(&w[0], id, &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "a tap in the notch of an L shaped well does not tie it" {
    // Oracle: construct-from-answer. The tap lies in the L's notch: inside
    // its box, outside the well, so the well is untied.
    var lb = LayoutBuilder.init(2);
    const well = try lb.shape(gpa, 0, testgen.shapes.lShape(0, 0, 4_000, 1_000));
    _ = try lb.rect(gpa, 1, 2_000, 2_000, 3_000, 3_000);
    var d = try Drawn.init(&lb, .{});
    defer d.deinit();
    const id = common.rule(52);
    var s: common.Sink = .{};
    defer s.deinit();
    try floatingWell(&d, id, &s);
    try testing.expectEqual(@as(u32, 1), s.out.len());
    try testing.expectEqual(d.ids.of(well), s.out.shape_a.items[0]);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(s.runs.items, id)).examined);
}

test "a well ring drawn as bands is one well" {
    // Oracle: construct-from-answer. Four abutting bands are one well: a
    // tap on one band ties it, a tap in the hole ties nothing, and the well
    // is named by its lowest drawn row.
    for ([_][4]i64{ .{ 3_000, 6_500, 5_000, 7_500 }, .{ 3_000, 3_000, 5_000, 5_000 } }, [_]bool{ false, true }) |tap, flagged| {
        var lb = LayoutBuilder.init(2);
        const bands = [_]testgen.shapes.Handle{
            try lb.rect(gpa, 0, 0, 0, 8_000, 2_000),
            try lb.rect(gpa, 0, 0, 6_000, 8_000, 8_000),
            try lb.rect(gpa, 0, 0, 2_000, 2_000, 6_000),
            try lb.rect(gpa, 0, 6_000, 2_000, 8_000, 6_000),
        };
        _ = try lb.rect(gpa, 1, tap[0], tap[1], tap[2], tap[3]);
        var d = try Drawn.init(&lb, .{});
        defer d.deinit();
        var lowest = d.ids.of(bands[0]);
        for (bands[1..]) |b| if (@backingInt(d.ids.of(b)) < @backingInt(lowest)) {
            lowest = d.ids.of(b);
        };
        const id = common.rule(53);
        var s: common.Sink = .{};
        defer s.deinit();
        try floatingWell(&d, id, &s);
        try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(s.runs.items, id)).examined);
        try testing.expectEqual(@as(u32, @intFromBool(flagged)), s.out.len());
        if (flagged) try testing.expectEqual(lowest, s.out.shape_a.items[0]);
    }
}

test "the point of a region furthest from its tap is reported with its distance" {
    // Oracle: construct-from-answer, exact: a 9000 x 7000 region with the
    // tap filling the corner to (1000, 1000); the opposite corner is 8000
    // across and 6000 up, 10000 away on the 6-8-10 triangle.
    var lb = LayoutBuilder.init(2);
    const region = try lb.rect(gpa, 0, 0, 0, 9_000, 7_000);
    _ = try lb.rect(gpa, 1, 0, 0, 1_000, 1_000);
    var d = try Drawn.init(&lb, .{});
    defer d.deinit();
    const id = common.rule(53);
    var s: common.Sink = .{};
    defer s.deinit();
    try missingTie(&d, id, 5_000, &s);
    try testing.expectEqual(@as(u32, 1), s.out.len());
    try testing.expectEqual(d.ids.of(region), s.out.shape_a.items[0]);
    try testing.expectEqual(geom.Point{ .x = 9_000, .y = 7_000 }, s.out.at.items[0]);
    try testing.expectEqual(@as(i128, 10_000), s.out.measured.items[0]);
    try testing.expectEqual(@as(i128, 5_000), s.out.limit.items[0]);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(s.runs.items, id)).examined);
}

test "a region within the stated tap distance is clean" {
    // Oracle: construct-from-answer. The same layout against a limit that
    // covers its furthest point.
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 0, 0, 9_000, 7_000);
    _ = try lb.rect(gpa, 1, 0, 0, 1_000, 1_000);
    var d = try Drawn.init(&lb, .{});
    defer d.deinit();
    const id = common.rule(54);
    var s: common.Sink = .{};
    defer s.deinit();
    try missingTie(&d, id, 20_000, &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "one conductor carrying both tap types is a supply short" {
    // Oracle: construct-from-answer. One metal shape carries an n-tie and a
    // p-tie: two tap markers on one extracted net.
    var d = try taps(true);
    defer d.deinit();
    const id = common.rule(55);
    var s: common.Sink = .{};
    defer s.deinit();
    try supplyShort(&d, id, null, &s);
    try testing.expectEqual(@as(u32, 1), s.out.len());
    try testing.expectEqual(id, s.out.rule.items[0]);
    const shorted = d.nets.netOf(s.out.shape_a.items[0]);
    try testing.expect(std.mem.indexOfScalar(PolyId, d.nets.polysOf(shorted), s.out.shape_a.items[0]) != null);
    try common.assertAtIsOnANamedShape(&d.store, &s.out, 0);
    try testing.expectEqual(@as(u64, 2), (try testgen.assertRuleRan(s.runs.items, id)).examined);
}

test "two conductors each carrying one tap type are clean" {
    // Oracle: construct-from-answer. Each net carries one tie.
    var d = try taps(false);
    defer d.deinit();
    const id = common.rule(56);
    var s: common.Sink = .{};
    defer s.deinit();
    try supplyShort(&d, id, null, &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "a scoped tap inside its scope still shorts" {
    // Oracle: construct-from-answer. The n-tap inside the scope: a short.
    var d = try scopedTaps(true);
    defer d.deinit();
    const id = common.rule(57);
    var s: common.Sink = .{};
    defer s.deinit();
    try supplyShort(&d, id, l(4), &s);
    try testing.expectEqual(@as(u32, 1), s.out.len());
    try testing.expectEqual(id, s.out.rule.items[0]);
}

test "a scoped tap outside its scope is not counted" {
    // Oracle: construct-from-answer. The n-tap outside every scope shape:
    // the scoped row is clean.
    var d = try scopedTaps(false);
    defer d.deinit();
    const id = common.rule(58);
    var s: common.Sink = .{};
    defer s.deinit();
    try supplyShort(&d, id, l(4), &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "a net held together only by a resistive body is flagged on both halves" {
    // Oracle: construct-from-answer. The two islands are one net joined only
    // through the body on layer 2: without the soft layer the net falls in
    // two, and the finding names a shape on each side.
    var b = try bridged(true);
    defer b[0].deinit();
    const halves = b[1].?;
    const id = common.rule(57);
    var s: common.Sink = .{};
    defer s.deinit();
    try softConnection(&b[0], id, layouts.viaConnectivity(1, &.{2}), &s);
    try testing.expectEqual(@as(u32, 1), s.out.len());
    try testing.expectEqual(id, s.out.rule.items[0]);
    const named = [2]PolyId{ s.out.shape_a.items[0], s.out.shape_b.items[0] };
    try testing.expect((named[0] == halves[0] and named[1] == halves[1]) or (named[0] == halves[1] and named[1] == halves[0]));
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(s.runs.items, id)).examined);
}

test "a net that survives losing its soft layer is clean" {
    // Oracle: construct-from-answer. One metal shape: still one component
    // without the soft layer.
    var b = try bridged(false);
    defer b[0].deinit();
    const id = common.rule(58);
    var s: common.Sink = .{};
    defer s.deinit();
    try softConnection(&b[0], id, layouts.viaConnectivity(1, &.{2}), &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "a rail reaching a gate is flagged" {
    // Oracle: construct-from-answer. Net 0 is a declared power rail carrying
    // a gate: tied straight to the rail, whichever end extraction calls the
    // source (F28).
    for ([_]u32{ 1, 0 }) |other_end| {
        var terms: [4]testgen.netlist.TerminalSpec = undefined;
        var devs: [1]testgen.netlist.DeviceSpec = undefined;
        var e = try Extracted.init(tiedOff(&terms, &devs, other_end));
        defer e.deinit();
        var intent = try e.rails(0, 2);
        defer intent.deinit(gpa);
        const id = common.rule(59);
        var s: common.Sink = .{};
        defer s.deinit();
        try tieHighLow(&e, &intent, id, &s);
        try testing.expectEqual(@as(u32, 1), s.out.len());
        try testing.expectEqual(id, s.out.rule.items[0]);
        try testing.expectEqual(e.lowestPoly(0), s.out.shape_a.items[0]);
        try testing.expectEqual(e.case.store.polyLayer(e.lowestPoly(0)), s.out.layer.items[0]);
        try common.assertAtIsOnANamedShape(&e.case.store, &s.out, 0);
        const run = try testgen.assertRuleRan(s.runs.items, id);
        try testing.expectEqual(@as(u64, 1), run.examined);
        try testing.expectEqual(@as(u32, 1), run.violations);
    }
}

test "a gate on a signal net is not tied off whatever its channel end is called" {
    // Oracle: construct-from-answer. The rails are nets 1 and 2, so net 0 is
    // a signal and no gate is tied off (F28).
    var terms: [4]testgen.netlist.TerminalSpec = undefined;
    var devs: [1]testgen.netlist.DeviceSpec = undefined;
    var e = try Extracted.init(tiedOff(&terms, &devs, 1));
    defer e.deinit();
    var intent = try e.rails(1, 2);
    defer intent.deinit(gpa);
    const id = common.rule(60);
    var s: common.Sink = .{};
    defer s.deinit();
    try tieHighLow(&e, &intent, id, &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "tie high low skips without intent" {
    // Oracle: construct-from-answer. Without intent no net is a rail: the
    // rule skips rather than report every gate clean.
    var terms: [4]testgen.netlist.TerminalSpec = undefined;
    var devs: [1]testgen.netlist.DeviceSpec = undefined;
    var e = try Extracted.init(tiedOff(&terms, &devs, 1));
    defer e.deinit();
    const none: erc.facts.IntentMap = .{};
    const id = common.rule(62);
    var s: common.Sink = .{};
    defer s.deinit();
    try tieHighLow(&e, &none, id, &s);
    try common.assertSkippedForIntent(s.runs.items, &s.out, id);
}

test "esd topological skips without intent" {
    // Oracle: construct-from-answer. Without intent no net is a rail, so a
    // pad cannot be shown to reach one: skipped.
    const devs = [_]testgen.netlist.DeviceSpec{
        layouts.mos("nch", &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 } }),
        .{ .kind = .diode, .model = "esd_clamp", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 1 }, .{ .role = .{ .pin = 1 }, .net = 2 } } },
    };
    var e = try Extracted.init(.{ .nets = 3, .devices = &devs });
    defer e.deinit();
    const id = common.rule(61);
    var s: common.Sink = .{};
    defer s.deinit();
    var t: tables.EsdTopologicalTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.pad.append(gpa, e.case.layers.rail);
    try t.clamp_start.appendSlice(gpa, &.{ 0, 1 });
    try t.clamp.append(gpa, e.case.expected_devices[1].model);
    const none: erc.facts.IntentMap = .{};
    try supply.checkEsdTopological(s.record(), e.design(), &none, &t);
    try testing.expectEqual(@as(u32, 0), s.out.len());
    try testing.expectEqual(check.report.Outcome{ .skipped = .no_design_intent }, s.runs.items[0].outcome);
}

test "two overlapping shapes left by the soft layer are one piece" {
    // Oracle: construct-from-answer: layer-0 shapes [0, 2000] and [1000,
    // 4000] overlap (touch within a layer is on), the body on layer 2 cut
    // to both; without the soft layer one component: examined and clean.
    var lb = LayoutBuilder.init(3);
    _ = try lb.rect(gpa, 0, 0, 0, 2_000, 1_000);
    _ = try lb.rect(gpa, 0, 1_000, 0, 4_000, 1_000);
    _ = try lb.rect(gpa, 2, 0, 200, 4_000, 800);
    _ = try lb.rect(gpa, 1, 400, 400, 600, 600);
    _ = try lb.rect(gpa, 1, 3_400, 400, 3_600, 600);
    var connectivity = layouts.viaConnectivity(1, &.{2});
    connectivity.intra_layer_touch = true;
    var d = try Drawn.init(&lb, connectivity);
    defer d.deinit();
    const id = common.rule(59);
    var s: common.Sink = .{};
    defer s.deinit();
    try softConnection(&d, id, connectivity, &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(s.runs.items, id)).examined);
}

test "mixed tag flags only an untagged figure sharing a net with a tagged one" {
    // Oracle: construct-from-answer. Wells on layer 0: W1 and W2 strapped on
    // layer 2 through cuts (one net), W2 under the tag on layer 3; W4 tagged
    // alone; W3 untagged alone. Four figures examined, one violation: W1,
    // measuring 1 tagged figure on its net against 0, naming W2.
    var lb = LayoutBuilder.init(4);
    const w1 = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
    const w2 = try lb.rect(gpa, 0, 3_000, 0, 4_000, 1_000);
    _ = try lb.rect(gpa, 0, 9_000, 0, 10_000, 1_000);
    _ = try lb.rect(gpa, 0, 6_000, 0, 7_000, 1_000);
    _ = try lb.rect(gpa, 2, 0, 300, 4_000, 700);
    _ = try lb.rect(gpa, 1, 400, 400, 600, 600);
    _ = try lb.rect(gpa, 1, 3_400, 400, 3_600, 600);
    _ = try lb.rect(gpa, 3, 2_900, -100, 4_100, 1_100);
    _ = try lb.rect(gpa, 3, 8_900, -100, 10_100, 1_100);
    var d = try Drawn.init(&lb, layouts.viaConnectivity(1, &.{2}));
    defer d.deinit();
    const id = common.rule(62);
    var s: common.Sink = .{};
    defer s.deinit();
    var t: tables.MixedTagTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.layer.append(gpa, l(0));
    try t.tag.append(gpa, l(3));
    try supply.checkMixedTag(s.record(), d.design(), &t);
    try testing.expectEqual(@as(u64, 4), (try testgen.assertRuleRan(s.runs.items, id)).examined);
    try testing.expectEqualSlices(StrId, &.{id}, s.out.rule.items);
    try testing.expectEqualSlices(PolyId, &.{d.ids.of(w1)}, s.out.shape_a.items);
    try testing.expectEqualSlices(PolyId, &.{d.ids.of(w2)}, s.out.shape_b.items);
    try testing.expectEqualSlices(i128, &.{1}, s.out.measured.items);
    try testing.expectEqualSlices(i128, &.{0}, s.out.limit.items);
}
