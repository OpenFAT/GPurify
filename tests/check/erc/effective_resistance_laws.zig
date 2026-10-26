//! Effective resistance, against its closed forms and its laws. It is a
//! metric on a network's nodes, so it obeys the triangle inequality and
//! Rayleigh monotonicity on any network: the strongest tests here, and the
//! two a path length or a sum of squares cannot pass. Ported from
//! crates/check/tests/erc/effective_resistance_laws.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const testgen = @import("testgen");
const erc = check.erc;
const NetNetworks = erc.power_grid.NetNetworks;
const Probe = erc.power_probe.Probe;
const ProbeScratch = erc.power_probe.ProbeScratch;
const common = @import("common.zig");
const gpa = common.gpa;
const assertClose = testgen.assertClose;
const assertCloseRelative = testgen.assertCloseRelative;

/// Every terminal pair of a one-row network, in `gpa`.
const Probes = struct {
    items: []Probe,

    fn deinit(p: Probes) void {
        gpa.free(p.items);
    }

    fn of(p: Probes, a: u32, b: u32) f64 {
        return common.probeOf(p.items, a, b) catch unreachable;
    }
};

// ---- private ----

fn probe(networks: *const NetNetworks) !Probes {
    var scratch: ProbeScratch = .{};
    defer scratch.deinit(gpa);
    var out: std.ArrayList(Probe) = .empty;
    errdefer out.deinit(gpa);
    var diag: erc.power_grid.PowerDiag = .{};
    try erc.power_probe.effectiveResistanceInto(gpa, networks, 0, &scratch, &out, &diag);
    return .{ .items = try out.toOwnedSlice(gpa) };
}

/// A connected network of arbitrary shape: a spanning path of random
/// resistances, `chords` extra edges, three terminals spread along it.
fn randomNetwork(seed: u64, nodes: u32, chords: u32) !NetNetworks {
    std.debug.assert(nodes >= 3);
    var rng = testgen.Rng.init(seed);
    var edges: std.ArrayList([3]f64) = .empty;
    defer edges.deinit(gpa);
    for (0..nodes - 1) |n| try edges.append(gpa, .{ @floatFromInt(n), @floatFromInt(n + 1), 0.5 + 9.5 * rng.unit() });
    for (0..chords) |_| {
        const from = rng.below(nodes);
        const to = rng.below(nodes);
        if (from != to) try edges.append(gpa, .{ @floatFromInt(from), @floatFromInt(to), 0.5 + 9.5 * rng.unit() });
    }
    return common.oneRowNetwork(nodes, &.{ 0, nodes / 2, nodes - 1 }, edges.items);
}

/// A network's edges as `(from, to, ohms)` rows, in `gpa`.
fn edgesOf(n: *const NetNetworks) ![][3]f64 {
    const out = try gpa.alloc([3]f64, n.edge_from.items.len);
    for (out, n.edge_from.items, n.edge_to.items, n.edge_resistance.items) |*e, f, t, r| e.* = .{ @floatFromInt(f), @floatFromInt(t), r.raw };
    return out;
}

test "a single edge reports its own resistance" {
    // Oracle: closed form. One resistor between two terminals is that
    // resistor, in ohms, nothing rescaled.
    var n = try common.oneRowNetwork(2, &.{ 0, 1 }, &.{.{ 0, 1, 47.0 }});
    defer n.deinit(gpa);
    const p = try probe(&n);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqual(@as(u32, 0), p.items[0].a);
    try testing.expectEqual(@as(u32, 1), p.items[0].b);
    try assertCloseRelative("a lone resistor", p.items[0].ohms.raw, 47.0, 1e-9);
}

test "a resistor ladder matches its series-parallel closed form" {
    // Oracle: closed form. A stage is one series resistor and a parallel
    // pair, so `rungs` stages are `rungs * (series + parallel / 2)`; the
    // interior nodes are Kron-eliminated onto the same number.
    const series = 1.5;
    const parallel = 3.0;
    for ([_]u32{ 1, 2, 7 }) |rungs| {
        var edges: std.ArrayList([3]f64) = .empty;
        defer edges.deinit(gpa);
        for (0..rungs) |stage| {
            const a: f64 = @floatFromInt(2 * stage);
            try edges.appendSlice(gpa, &.{ .{ a, a + 1, series }, .{ a + 1, a + 2, parallel }, .{ a + 1, a + 2, parallel } });
        }
        var n = try common.oneRowNetwork(2 * rungs + 1, &.{ 0, 2 * rungs }, edges.items);
        defer n.deinit(gpa);
        const p = try probe(&n);
        defer p.deinit();
        try assertCloseRelative("a ladder", p.of(0, 2 * rungs), @as(f64, @floatFromInt(rungs)) * (series + parallel / 2.0), 1e-9);
    }
}

test "parallel strands between two terminals divide the resistance" {
    // Oracle: closed form. Conductances in parallel add: `k` equal strands
    // are `R / k`; a Laplacian built by assignment keeps one strand.
    for ([_]u32{ 1, 2, 4, 8 }) |strands| {
        var edges: std.ArrayList([3]f64) = .empty;
        defer edges.deinit(gpa);
        for (0..strands) |_| try edges.append(gpa, .{ 0, 1, 8.0 });
        var n = try common.oneRowNetwork(2, &.{ 0, 1 }, edges.items);
        defer n.deinit(gpa);
        const p = try probe(&n);
        defer p.deinit();
        try assertCloseRelative("parallel strands", p.items[0].ohms.raw, 8.0 / @as(f64, @floatFromInt(strands)), 1e-9);
    }
}

test "subdividing an edge leaves every effective resistance unchanged" {
    // Oracle: law. Splitting one resistor into two series halves through a
    // new interior node changes no terminal-pair resistance: the invariance
    // under Kron elimination, on a generated network.
    var base = try randomNetwork(5, 9, 4);
    defer base.deinit(gpa);
    const before = try probe(&base);
    defer before.deinit();
    const nodes = base.node_start.items[1];
    const all = try edgesOf(&base);
    defer gpa.free(all);
    var edges: std.ArrayList([3]f64) = .empty;
    defer edges.deinit(gpa);
    try edges.appendSlice(gpa, all[1..]);
    const fresh: f64 = @floatFromInt(nodes);
    try edges.appendSlice(gpa, &.{ .{ all[0][0], fresh, all[0][2] / 2.0 }, .{ fresh, all[0][1], all[0][2] / 2.0 } });
    var split = try common.oneRowNetwork(nodes + 1, &.{ 0, nodes / 2, nodes - 1 }, edges.items);
    defer split.deinit(gpa);
    const after = try probe(&split);
    defer after.deinit();
    try testing.expectEqual(before.items.len, after.items.len);
    for (before.items, after.items) |x, y| {
        try testing.expectEqual(x.a, y.a);
        try testing.expectEqual(x.b, y.b);
        try assertCloseRelative("a pair after subdivision", y.ohms.raw, x.ohms.raw, 1e-9);
    }
}

test "effective resistance obeys the triangle inequality" {
    // Oracle: law. A metric: no detour through a third terminal is shorter
    // than the direct measurement.
    for ([_]u64{ 1, 2, 3, 4 }) |seed| {
        var n = try randomNetwork(seed, 11, 6);
        defer n.deinit(gpa);
        const p = try probe(&n);
        defer p.deinit();
        const t = n.terminal.items;
        for (t) |a| for (t) |b| for (t) |c| {
            if (a == b or b == c or a == c) continue;
            try testing.expect(p.of(a, c) <= (p.of(a, b) + p.of(b, c)) * (1.0 + 1e-9));
        };
    }
}

test "adding a conductance never raises any effective resistance" {
    // Oracle: law, Rayleigh monotonicity: a strap across the network cannot
    // raise the resistance between any pair.
    for ([_]u64{ 11, 12, 13 }) |seed| {
        var base = try randomNetwork(seed, 10, 3);
        defer base.deinit(gpa);
        const before = try probe(&base);
        defer before.deinit();
        const all = try edgesOf(&base);
        defer gpa.free(all);
        var edges: std.ArrayList([3]f64) = .empty;
        defer edges.deinit(gpa);
        try edges.appendSlice(gpa, all);
        try edges.append(gpa, .{ 0, 9, 0.25 });
        var strapped = try common.oneRowNetwork(10, base.terminal.items, edges.items);
        defer strapped.deinit(gpa);
        const after = try probe(&strapped);
        defer after.deinit();
        for (before.items) |x| try testing.expect(after.of(x.a, x.b) <= x.ohms.raw * (1.0 + 1e-9));
    }
}

test "lowering one resistance never raises any effective resistance" {
    // Oracle: law, Rayleigh monotonicity in its other form (catches a
    // solver reading conductance where it meant resistance).
    var base = try randomNetwork(21, 8, 3);
    defer base.deinit(gpa);
    const before = try probe(&base);
    defer before.deinit();
    const edges = try edgesOf(&base);
    defer gpa.free(edges);
    edges[2][2] /= 10.0;
    var cut = try common.oneRowNetwork(8, base.terminal.items, edges);
    defer cut.deinit(gpa);
    const after = try probe(&cut);
    defer after.deinit();
    for (before.items) |x| try testing.expect(after.of(x.a, x.b) <= x.ohms.raw * (1.0 + 1e-9));
}

test "every terminal pair appears once ascending with a positive resistance" {
    // Oracle: law. The output's shape is interface: every unordered pair of
    // a connected network once, `a < b`, ascending, positive and finite.
    var n = try randomNetwork(31, 12, 7);
    defer n.deinit(gpa);
    const p = try probe(&n);
    defer p.deinit();
    const k = n.terminal.items.len;
    try testing.expectEqual(k * (k - 1) / 2, p.items.len);
    for (p.items[0 .. p.items.len - 1], p.items[1..]) |x, y| try testing.expect(x.a < y.a or (x.a == y.a and x.b < y.b));
    for (p.items) |x| {
        try testing.expect(x.a < x.b);
        try testing.expect(x.ohms.raw > 0.0 and std.math.isFinite(x.ohms.raw));
    }
}

test "a terminal pair in another component is absent rather than infinite" {
    // Oracle: construct-from-answer. Terminals 0 and 1 are joined through
    // node 2 (5 + 5 Ω); terminal 3 sits alone, so only one pair is reported.
    var n = try common.oneRowNetwork(4, &.{ 0, 1, 3 }, &.{ .{ 0, 2, 5.0 }, .{ 2, 1, 5.0 } });
    defer n.deinit(gpa);
    const p = try probe(&n);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqual(@as(u32, 0), p.items[0].a);
    try testing.expectEqual(@as(u32, 1), p.items[0].b);
    try assertCloseRelative("the connected pair", p.items[0].ohms.raw, 10.0, 1e-9);
}

test "probing one network twice produces identical output" {
    // Oracle: determinism. Two runs agree bit for bit.
    var n = try randomNetwork(41, 14, 9);
    defer n.deinit(gpa);
    const first = try probe(&n);
    defer first.deinit();
    const second = try probe(&n);
    defer second.deinit();
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first.items), std.mem.sliceAsBytes(second.items));
}

test "probing a second network through one scratch replaces the first answer" {
    // Oracle: law. A reused scratch leaves nothing behind and the output is
    // cleared, not appended to.
    var first = try common.oneRowNetwork(2, &.{ 0, 1 }, &.{.{ 0, 1, 100.0 }});
    defer first.deinit(gpa);
    var second = try common.oneRowNetwork(2, &.{ 0, 1 }, &.{.{ 0, 1, 25.0 }});
    defer second.deinit(gpa);
    var scratch: ProbeScratch = .{};
    defer scratch.deinit(gpa);
    var out: std.ArrayList(Probe) = .empty;
    defer out.deinit(gpa);
    var diag: erc.power_grid.PowerDiag = .{};
    try erc.power_probe.effectiveResistanceInto(gpa, &first, 0, &scratch, &out, &diag);
    try erc.power_probe.effectiveResistanceInto(gpa, &second, 0, &scratch, &out, &diag);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try assertClose("the second network", out.items[0].ohms.raw, 25.0, 1e-9);
}
