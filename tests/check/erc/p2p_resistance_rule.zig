//! Point-to-point resistance, and the network that tells it apart from a
//! proxy: the measurement is the effective resistance of the whole network
//! between two attach points, which disagrees with a path length and a sum
//! of squares on anything with a parallel route. Ported from
//! crates/check/tests/erc/p2p_resistance_rule.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const gpa = common.gpa;
const erc = check.erc;
const report = check.report;
const NetNetworks = erc.power_grid.NetNetworks;
const P2pResistanceTable = erc.electrical_tables.P2pResistanceTable;

/// A store with two pads and a net whose attach points `strands` equal
/// straps join: effective `ohm / strands`, one route `ohm`, squares
/// `strands * ohm^2`.
const Strapped = struct {
    store: geom.GeometryStore = .empty,
    ids: testgen.shapes.Ids = .{},
    networks: NetNetworks = .{},
    a: geom.PolyId = undefined,
    b: geom.PolyId = undefined,

    fn init(strands: u32, ohm: f64) !Strapped {
        var s: Strapped = .{};
        var lb = testgen.shapes.LayoutBuilder.init(1);
        defer lb.deinit(gpa);
        const left = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
        const right = try lb.rect(gpa, 0, 5_000, 0, 6_000, 1_000);
        try lb.finish(gpa, &s.store, &s.ids);
        s.a = s.ids.of(left);
        s.b = s.ids.of(right);
        var edges: [8][3]f64 = undefined;
        for (edges[0..strands]) |*e| e.* = .{ 0, 1, ohm };
        s.networks = try common.oneRowNetwork(2, &.{ 0, 1 }, edges[0..strands]);
        s.networks.node_poly.items[0] = s.a;
        s.networks.node_poly.items[1] = s.b;
        s.networks.node_at.items[0] = testgen.shapes.point(500, 500);
        s.networks.node_at.items[1] = testgen.shapes.point(5_500, 500);
        return s;
    }

    fn deinit(s: *Strapped) void {
        s.store.deinit(gpa);
        s.ids.deinit(gpa);
        s.networks.deinit(gpa);
    }
};

// ---- private ----

fn table(id: geom.StrId, max_ohm: f64) !P2pResistanceTable {
    var t: P2pResistanceTable = .{ .head = try common.head(id) };
    try t.max_resistance.append(gpa, .{ .raw = max_ohm });
    return t;
}

/// Runs the rule over one net's network into `sink`.
fn run(sink: *common.Sink, store: *const geom.GeometryStore, networks: *const NetNetworks, rules: *const P2pResistanceTable) !void {
    const nets: check.topology.NetTable = .{};
    const devices: check.topology.DeviceTable = .{};
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.electrical.checkP2pResistance(sink.record(), .{ .store = store, .nets = &nets, .devices = &devices }, networks, rules, &scratch);
}

test "p2p resistance reports the effective resistance between the attach points" {
    // Oracle: closed form, on the network that distinguishes the three
    // candidate answers. Four eight-ohm straps in parallel are two ohms; a
    // sum along one route would report eight, the sum-of-squares proxy 256.
    var s = try Strapped.init(4, 8.0);
    defer s.deinit();
    const id = common.rule(1);
    var t = try table(id, 1.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try run(&sink, &s.store, &s.networks, &t);
    const v = &sink.out;
    try testing.expectEqual(@as(u32, 1), v.len());
    try testing.expectEqual(id, v.rule.items[0]);
    try testing.expectEqual(report.Severity.@"error", v.severity.items[0]);
    try testing.expectEqual(s.a, v.shape_a.items[0]);
    try testing.expectEqual(s.b, v.shape_b.items[0]);
    try testing.expectEqual(s.store.polyLayer(s.a), v.layer.items[0]);
    try testgen.assertCloseRelative("the reported resistance", v.get(0).measured.float(), 2.0, 1e-9);
    try testing.expect(v.get(0).limit.eql(report.Measurement.resistance(.{ .raw = 1.0 })));
    try common.assertAtIsOnANamedShape(&s.store, v, 0);
    const r = try testgen.assertRuleRan(sink.runs.items, id);
    try testing.expectEqual(@as(u32, 1), r.violations);
    try testing.expectEqual(@as(u64, 1), r.examined);
}

test "a net whose strands sum over the limit still passes on its effective resistance" {
    // Oracle: closed form, the discriminating case: the same four straps
    // against ten ohms. Effective 2 passes; the strand sum (32) and the sum
    // of squares (256) both fail, so a proxy reports a violation here.
    var s = try Strapped.init(4, 8.0);
    defer s.deinit();
    const id = common.rule(2);
    var t = try table(id, 10.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try run(&sink, &s.store, &s.networks, &t);
    try testgen.assertClean(sink.runs.items, &sink.out, id);
}

test "adding a parallel strap lowers the resistance the rule reports" {
    // Oracle: law. Rayleigh monotonicity at the level of the rule: adding
    // metal in parallel can only lower the reported number, here exactly
    // 8 / strands.
    const id = common.rule(3);
    var previous = std.math.inf(f64);
    for ([_]u32{ 1, 2, 4, 8 }) |strands| {
        var s = try Strapped.init(strands, 8.0);
        defer s.deinit();
        var t = try table(id, 1e-6);
        defer erc.rule_set.deinitTable(gpa, &t);
        var sink: common.Sink = .{};
        defer sink.deinit();
        try run(&sink, &s.store, &s.networks, &t);
        try testing.expectEqual(@as(u32, 1), sink.out.len());
        const measured = sink.out.get(0).measured.float();
        try testing.expect(measured < previous);
        try testgen.assertCloseRelative("straps", measured, 8.0 / @as(f64, @floatFromInt(strands)), 1e-9);
        previous = measured;
    }
}

test "a design with no probeable net runs and examines nothing" {
    // Oracle: construct-from-answer. A net with fewer than two attach points
    // has no row, so there is no pair: the rule still records itself, ran,
    // with nothing examined.
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    var lb = testgen.shapes.LayoutBuilder.init(1);
    defer lb.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    const id = common.rule(4);
    var t = try table(id, 5.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    const none: NetNetworks = .{};
    var sink: common.Sink = .{};
    defer sink.deinit();
    try run(&sink, &store, &none, &t);
    const r = try common.runOf(sink.runs.items, id);
    try testing.expectEqual(report.Outcome.ran, r.outcome);
    try testing.expectEqual(@as(u64, 0), r.examined);
    try testing.expectEqual(@as(u32, 0), r.violations);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "each configured rule row produces its own run row" {
    // Oracle: construct-from-answer. Two rows at two limits give two run
    // rows, and only the tighter one reports.
    var s = try Strapped.init(4, 8.0);
    defer s.deinit();
    const tight = common.rule(5);
    const loose = common.rule(6);
    var t: P2pResistanceTable = .{};
    defer erc.rule_set.deinitTable(gpa, &t);
    try t.head.push(gpa, tight, .@"error");
    try t.head.push(gpa, loose, .warning);
    try t.max_resistance.appendSlice(gpa, &.{ .{ .raw = 1.0 }, .{ .raw = 10.0 } });
    var sink: common.Sink = .{};
    defer sink.deinit();
    try run(&sink, &s.store, &s.networks, &t);
    try testing.expectEqual(@as(usize, 2), sink.runs.items.len);
    try testing.expectEqual(@as(u32, 1), (try common.runOf(sink.runs.items, tight)).violations);
    try testing.expectEqual(@as(u32, 0), (try common.runOf(sink.runs.items, loose)).violations);
    try testing.expectEqualSlices(geom.StrId, &.{tight}, sink.out.rule.items);
}

test "running the rule twice produces identical violation columns" {
    // Oracle: determinism. The same net probed twice through two fresh
    // scratches gives the same columns, the reported coordinate included.
    var s = try Strapped.init(4, 8.0);
    defer s.deinit();
    const id = common.rule(7);
    var t = try table(id, 1.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    var first: common.Sink = .{};
    defer first.deinit();
    var second: common.Sink = .{};
    defer second.deinit();
    try run(&first, &s.store, &s.networks, &t);
    try run(&second, &s.store, &s.networks, &t);
    try testgen.assertViolationsEq(&first.out, &second.out);
    try testing.expectEqualDeep(first.runs.items, second.runs.items);
}
