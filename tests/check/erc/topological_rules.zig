//! The rules that ask only what is connected to what. Oracle throughout:
//! construct-from-answer: `layoutFromNetlist` emits a layout from a netlist
//! decided before any polygon was drawn, so the floating gate, the contended
//! net, the unreached conductor and the tied-off input are placed
//! deliberately and each must be found on its net, at that net's own
//! polygon. Every clean assertion goes through `assertClean`, which insists
//! the rule ran and examined something. Ported from
//! crates/check/tests/erc/topological_rules.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const erc = check.erc;
const topo = erc.topology;
const tables = erc.topology_tables;
const nl = testgen.netlist;
const common = @import("common.zig");
const layouts = @import("layouts.zig");
const Extracted = layouts.Extracted;
const mos = layouts.mos;
const gpa = common.gpa;

/// Two transistors whose channels meet on net 2, gated from `gate_a` and
/// `gate_b`: an nch from rail 3 and a pch from rail 4. With `output_first`
/// the nch's output end is the one extraction calls its source.
const Contended = struct {
    nch: [4]nl.TerminalSpec,
    pch: [4]nl.TerminalSpec,
    devices: [2]nl.DeviceSpec = undefined,

    fn spec(c: *Contended) nl.NetlistSpec {
        c.devices = .{ mos("nch", &c.nch), mos("pch", &c.pch) };
        return .{ .nets = 5, .devices = &c.devices };
    }
};

// ---- private ----

fn gsdb(g: u32, s: u32, d: u32, b: u32) [4]nl.TerminalSpec {
    return .{ .{ .role = .gate, .net = g }, .{ .role = .source, .net = s }, .{ .role = .drain, .net = d }, .{ .role = .bulk, .net = b } };
}

fn floatingGate(id: StrId, are_ports: bool) !tables.FloatingGateTable {
    var t: tables.FloatingGateTable = .{ .head = try common.head(id) };
    try t.labels_are_ports.append(gpa, are_ports);
    return t;
}

fn maxDrivers(id: StrId) !tables.MultipleDriversTable {
    var t: tables.MultipleDriversTable = .{ .head = try common.head(id) };
    try t.max_drivers.append(gpa, 1);
    return t;
}

fn contendedOutput(gate_a: u32, gate_b: u32, output_first: bool) Contended {
    const source: u32, const drain: u32 = if (output_first) .{ 2, 3 } else .{ 3, 2 };
    return .{ .nch = gsdb(gate_a, source, drain, 3), .pch = gsdb(gate_b, 4, 2, 4) };
}

/// One `multiple_drivers` row at `max: 1`, rails 4 (power) and 3 (ground).
fn drivers(e: *const Extracted, id: StrId, s: *common.Sink) !void {
    var t = try maxDrivers(id);
    defer erc.rule_set.deinitTable(gpa, &t);
    var intent = try e.rails(4, 3);
    defer intent.deinit(gpa);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try topo.checkMultipleDrivers(s.record(), e.design(), &intent, &t, &scratch);
}

/// One violation, on netlist net `net`, at its lowest polygon.
fn oneViolationOn(e: *const Extracted, v: *const check.report.Violations, id: StrId, net: usize) !void {
    try testing.expectEqual(@as(u32, 1), v.len());
    try testing.expectEqual(id, v.rule.items[0]);
    try testing.expectEqual(check.report.Severity.@"error", v.severity.items[0]);
    try testing.expectEqual(e.lowestPoly(net), v.shape_a.items[0]);
    try testing.expectEqual(e.case.store.polyLayer(e.lowestPoly(net)), v.layer.items[0]);
    try common.assertAtIsOnANamedShape(&e.case.store, v, 0);
}

fn sortPolys(p: []PolyId) void {
    std.mem.sortUnstable(PolyId, p, {}, struct {
        fn less(_: void, a: PolyId, b: PolyId) bool {
            return @backingInt(a) < @backingInt(b);
        }
    }.less);
}

test "a net carrying only a gate is flagged at its own polygon" {
    // Oracle: construct-from-answer. Net 0 carries the transistor's gate and
    // nothing else; the other three nets each carry a source, a drain or a
    // bulk and are left alone.
    var e = try Extracted.init(.{ .nets = 4, .devices = &.{mos("nch", &gsdb(0, 1, 2, 3))} });
    defer e.deinit();
    const id = common.rule(40);
    var s: common.Sink = .{};
    defer s.deinit();
    var t = try floatingGate(id, false);
    defer erc.rule_set.deinitTable(gpa, &t);
    const ports: check.topology.PortTable = .{};
    try topo.checkFloatingGate(s.record(), e.design(), &e.facts, &ports, &t);
    try oneViolationOn(&e, &s.out, id, 0);
    const run = try testgen.assertRuleRan(s.runs.items, id);
    try testing.expectEqual(@as(u64, 1), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "a gate net that a drain also reaches is clean" {
    // Oracle: construct-from-answer. The gate net also carries a second
    // transistor's drain: driven, not floating.
    var e = try Extracted.init(.{ .nets = 4, .devices = &.{ mos("nch", &gsdb(0, 1, 2, 3)), mos("nch", &.{
        .{ .role = .gate, .net = 1 }, .{ .role = .drain, .net = 0 }, .{ .role = .source, .net = 2 }, .{ .role = .bulk, .net = 3 },
    }) } });
    defer e.deinit();
    const id = common.rule(41);
    var s: common.Sink = .{};
    defer s.deinit();
    var t = try floatingGate(id, false);
    defer erc.rule_set.deinitTable(gpa, &t);
    const ports: check.topology.PortTable = .{};
    try topo.checkFloatingGate(s.record(), e.design(), &e.facts, &ports, &t);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "a labelled gate only net is clean only where labels are ports" {
    // Oracle: construct-from-answer. The gate-only net, labelled: a label
    // alone still floats; on a row reading labels as ports it is a block
    // input driven from outside, so clean.
    var e = try Extracted.init(.{ .nets = 4, .devices = &.{mos("nch", &gsdb(0, 1, 2, 3))} });
    defer e.deinit();
    var labels: @import("ingest").Provenance = .{};
    defer labels.deinit(gpa);
    try labels.label(gpa, e.lowestPoly(0), try e.strings.intern(gpa, "in"));
    var ports: check.topology.PortTable = .{};
    defer ports.deinit(gpa);
    try check.topology.bindPortsInto(gpa, &e.nets, labels.labels(), &ports);
    const id = common.rule(42);
    for ([_]bool{ false, true }) |are_ports| {
        var s: common.Sink = .{};
        defer s.deinit();
        var t = try floatingGate(id, are_ports);
        defer erc.rule_set.deinitTable(gpa, &t);
        try topo.checkFloatingGate(s.record(), e.design(), &e.facts, &ports, &t);
        if (are_ports) try testgen.assertClean(s.runs.items, &s.out, id) else try oneViolationOn(&e, &s.out, id, 0);
    }
}

test "a net with two independently gated pull networks is flagged with its driver count" {
    // Oracle: construct-from-answer. Net 2 is pulled down to rail 3 from
    // gate 0 and up to rail 4 from gate 1: two drivers against a maximum of
    // one, whichever channel end extraction calls the source (F28).
    for ([_]bool{ false, true }) |output_first| {
        var spec = contendedOutput(0, 1, output_first);
        var e = try Extracted.init(spec.spec());
        defer e.deinit();
        const id = common.rule(42);
        var s: common.Sink = .{};
        defer s.deinit();
        try drivers(&e, id, &s);
        try oneViolationOn(&e, &s.out, id, 2);
        try testing.expectEqual(@as(i128, 2), s.out.measured.items[0]);
        try testing.expectEqual(@as(i128, 1), s.out.limit.items[0]);
        const run = try testgen.assertRuleRan(s.runs.items, id);
        try testing.expectEqual(@as(u64, 1), run.examined);
        try testing.expectEqual(@as(u32, 1), run.violations);
    }
}

test "two pull networks sharing one gate net are one driver and are clean" {
    // Oracle: construct-from-answer. An inverter: one driver.
    var spec = contendedOutput(0, 0, false);
    var e = try Extracted.init(spec.spec());
    defer e.deinit();
    const id = common.rule(43);
    var s: common.Sink = .{};
    defer s.deinit();
    try drivers(&e, id, &s);
    try testgen.assertClean(s.runs.items, &s.out, id);
}

test "a pass gate drives only what reaches a rail through it" {
    // Oracle: construct-from-answer. An inverter drives net 2; a pass
    // transistor joins net 2 to net 5. Alone, it reaches no rail: one
    // driver. With a pull-down on net 5 gated from net 6, nets 2 and 5 each
    // have two drivers.
    for ([_]bool{ false, true }) |pulled| {
        var base = contendedOutput(0, 0, false);
        _ = base.spec();
        const pass = mos("nch", &.{ .{ .role = .gate, .net = 1 }, .{ .role = .source, .net = 5 }, .{ .role = .drain, .net = 2 }, .{ .role = .bulk, .net = 3 } });
        const pull = mos("nch", &.{ .{ .role = .gate, .net = 6 }, .{ .role = .source, .net = 3 }, .{ .role = .drain, .net = 5 }, .{ .role = .bulk, .net = 3 } });
        const all = [_]nl.DeviceSpec{ base.devices[0], base.devices[1], pass, pull };
        var e = try Extracted.init(.{ .nets = 7, .devices = if (pulled) all[0..4] else all[0..3] });
        defer e.deinit();
        const id = common.rule(47);
        var s: common.Sink = .{};
        defer s.deinit();
        try drivers(&e, id, &s);
        const run = try testgen.assertRuleRan(s.runs.items, id);
        try testing.expectEqual(@as(u64, 2), run.examined);
        if (!pulled) {
            try testgen.assertClean(s.runs.items, &s.out, id);
            continue;
        }
        var flagged = [_]PolyId{ s.out.shape_a.items[0], s.out.shape_a.items[1] };
        var want = [_]PolyId{ e.lowestPoly(2), e.lowestPoly(5) };
        sortPolys(&flagged);
        sortPolys(&want);
        try testing.expectEqualSlices(PolyId, &want, &flagged);
        for (s.out.measured.items) |m| try testing.expectEqual(@as(i128, 2), m);
    }
}

test "multiple drivers skips without intent" {
    // Oracle: construct-from-answer. Without intent no net is a rail, so no
    // pull network can be told from a pass gate: skipped, not clean.
    var spec = contendedOutput(0, 1, false);
    var e = try Extracted.init(spec.spec());
    defer e.deinit();
    const id = common.rule(48);
    var s: common.Sink = .{};
    defer s.deinit();
    var t = try maxDrivers(id);
    defer erc.rule_set.deinitTable(gpa, &t);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    const none: erc.facts.IntentMap = .{};
    try topo.checkMultipleDrivers(s.record(), e.design(), &none, &t, &scratch);
    try common.assertSkippedForIntent(s.runs.items, &s.out, id);
}

test "a conductor on a net no device reaches is flagged" {
    // Oracle: construct-from-answer. Every net gets a rail; net 2's reaches
    // no device terminal. Three rails examined, exactly one reported.
    var e = try Extracted.init(.{ .nets = 3, .devices = &.{mos("nch", &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 } })} });
    defer e.deinit();
    const id = common.rule(44);
    var s: common.Sink = .{};
    defer s.deinit();
    var t: tables.UnconnectedPinTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.layer_start.appendSlice(gpa, &.{ 0, 1 });
    try t.layer.append(gpa, e.case.layers.rail);
    try topo.checkUnconnectedPin(s.record(), e.design(), &e.facts, &t);
    try oneViolationOn(&e, &s.out, id, 2);
    try testing.expectEqual(@as(u64, 3), (try testgen.assertRuleRan(s.runs.items, id)).examined);
}

test "an unconnected pin rule naming no layer examines nothing" {
    // Oracle: construct-from-answer. An empty layer list has nothing to
    // examine, and its run row says so.
    var e = try Extracted.init(.{ .nets = 2, .devices = &.{mos("nch", &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 } })} });
    defer e.deinit();
    const id = common.rule(45);
    var s: common.Sink = .{};
    defer s.deinit();
    var t: tables.UnconnectedPinTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.layer_start.appendSlice(gpa, &.{ 0, 0 });
    try topo.checkUnconnectedPin(s.record(), e.design(), &e.facts, &t);
    const run = try common.runOf(s.runs.items, id);
    try testing.expectEqual(@as(u64, 0), run.examined);
    try testing.expectEqual(@as(u32, 0), run.violations);
    try testing.expectEqual(@as(u32, 0), s.out.len());
}

test "running the topological rules twice produces identical rows" {
    // Oracle: determinism. The same layout run twice gives the same rows in
    // the same order, coordinates included.
    var spec = contendedOutput(0, 1, false);
    var e = try Extracted.init(spec.spec());
    defer e.deinit();
    const id = common.rule(46);
    var first: common.Sink = .{};
    defer first.deinit();
    var second: common.Sink = .{};
    defer second.deinit();
    try drivers(&e, id, &first);
    try drivers(&e, id, &second);
    try testgen.assertViolationsEq(&first.out, &second.out);
    try testing.expectEqualSlices(check.report.RuleRun, first.runs.items, second.runs.items);
}
