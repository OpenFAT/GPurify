//! The DC solve, against Ohm's law and Kirchhoff's. Every test reads a
//! `PowerGrid` built column by column and the `PowerSolution` solved from
//! it: a closed form where the network is a series chain or a parallel
//! bundle, a law where it is arbitrary (the stronger kind: it holds on any
//! grid the generator emits). Ported from
//! crates/check/tests/erc/power_grid_laws.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const testgen = @import("testgen");
const erc = check.erc;
const PowerGrid = erc.power_grid.PowerGrid;
const PowerSolution = erc.power_grid.PowerSolution;
const PowerDiag = erc.power_grid.PowerDiag;
const SolveScratch = erc.power_solve.SolveScratch;
const common = @import("common.zig");
const gpa = common.gpa;
const assertClose = testgen.assertClose;
const assertCloseRelative = testgen.assertCloseRelative;

// ---- private ----

fn isPad(grid: *const PowerGrid, node: u32) bool {
    return std.mem.indexOfScalar(u32, grid.source_node.items, node) != null;
}

/// The solve's refusal of `grid`, and what it names.
fn refusal(grid: *const PowerGrid) !struct { err: anyerror, at: u32 } {
    var scratch: SolveScratch = .{};
    defer scratch.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    var diag: PowerDiag = .{};
    erc.power_solve.solveInto(gpa, grid, &scratch, &solution, &diag) catch |e| return .{ .err = e, .at = diag.at };
    return error.Solved;
}

test "series resistances add between the pad and the load" {
    // Oracle: closed form. Resistances in series add, so the drop at the
    // k-th node of a uniform chain carrying one current is `k * I * R`,
    // checked at every node: a solver lumping the chain into one resistor
    // passes the total and fails the profile.
    var grid = try common.seriesChain(4, 2.5, 1_800.0, 1_000.0);
    defer grid.deinit(gpa);
    var s = try common.solve(&grid);
    defer s.deinit(gpa);
    // 1000 µA through 2.5 Ω is 2.5 mV per resistor.
    for (0..5) |node| {
        const expected = 2.5 * @as(f64, @floatFromInt(node));
        const drop = s.node_drop.items[node].raw;
        if (node == 0) try assertClose("the drop at the pad", drop, 0.0, 1e-9) else try assertCloseRelative("a node drop", drop, expected, 1e-8);
        try assertCloseRelative("a node voltage", s.node_voltage.items[node].raw, 1_800.0 - expected, 1e-9);
    }
    for (s.branch_current.items) |c| try assertCloseRelative("a branch current", c.raw, 1_000.0, 1e-8);
}

test "parallel conductances add between the pad and the load" {
    // Oracle: closed form. Conductances in parallel add: four 8 Ω strands
    // are 2 Ω and each carries a quarter of the current. A solver that
    // assigns into its Laplacian keeps one strand and reports 8 Ω.
    var grid = try common.parallelBundle(4, 8.0, 1_800.0, 1_000.0);
    defer grid.deinit(gpa);
    var s = try common.solve(&grid);
    defer s.deinit(gpa);
    try assertClose("the drop at the pad", s.node_drop.items[0].raw, 0.0, 1e-9);
    try assertCloseRelative("the drop at the load", s.node_drop.items[1].raw, 2.0, 1e-8);
    for (s.branch_current.items[0..4]) |c| try assertCloseRelative("a strand current", c.raw, 250.0, 1e-8);
}

test "kirchhoff's current law holds at every node of a solved grid" {
    // Oracle: law. The signed branch currents at every non-pad node sum to
    // the current drawn there, on arbitrary generated grids; either sign
    // inverted fails on any grid with two edges at a node.
    for ([_]u64{ 1, 2, 3 }) |seed| {
        var grid = try common.randomGrid(seed, 24, 12);
        defer grid.deinit(gpa);
        var s = try common.solve(&grid);
        defer s.deinit(gpa);
        const net_in = try gpa.alloc(f64, grid.nodeCount());
        defer gpa.free(net_in);
        @memset(net_in, 0.0);
        for (grid.edge_from.items, grid.edge_to.items, s.branch_current.items) |from, to, c| {
            net_in[from] -= c.raw;
            net_in[to] += c.raw;
        }
        for (net_in, 0..) |into, node| {
            // A pad sources whatever the rest draws: the global law, below.
            if (isPad(&grid, @intCast(node))) continue;
            try assertClose("Kirchhoff's current law", into, grid.node_load.items[node].raw, 1e-6);
        }
    }
}

test "the pads deliver exactly what the loads draw" {
    // Oracle: law. Charge is conserved over the grid: the current the pads
    // deliver equals the current the loads draw (catches a pad elimination
    // that dropped a term).
    var grid = try common.randomGrid(7, 20, 9);
    defer grid.deinit(gpa);
    var s = try common.solve(&grid);
    defer s.deinit(gpa);
    var drawn: f64 = 0.0;
    for (grid.node_load.items) |l| drawn += l.raw;
    var delivered: f64 = 0.0;
    for (grid.edge_from.items, grid.edge_to.items, s.branch_current.items) |from, to, c| {
        if (isPad(&grid, from)) delivered += c.raw;
        if (isPad(&grid, to)) delivered -= c.raw;
    }
    try assertCloseRelative("the current leaving the pads", delivered, drawn, 1e-8);
}

test "every node drop is its nominal less its solved voltage" {
    // Oracle: law. `node_drop` is nominal minus solved on any grid; stored,
    // it is the one place a sign error would hide from every rule at once.
    var grid = try common.randomGrid(11, 16, 6);
    defer grid.deinit(gpa);
    var s = try common.solve(&grid);
    defer s.deinit(gpa);
    for (s.node_drop.items, grid.node_nominal.items, s.node_voltage.items) |d, n, v| try assertClose("a node drop", d.raw, n.raw - v.raw, 1e-9);
}

test "scaling every load scales every drop by the same factor" {
    // Oracle: law. A resistive network is linear: doubling every load
    // doubles every drop and branch current, which fails against any
    // additive term the loads do not explain.
    var grid = try common.randomGrid(13, 18, 8);
    defer grid.deinit(gpa);
    var reference = try common.solve(&grid);
    defer reference.deinit(gpa);
    var doubled = try common.randomGrid(13, 18, 8);
    defer doubled.deinit(gpa);
    for (doubled.node_load.items) |*l| l.raw *= 2.0;
    var scaled = try common.solve(&doubled);
    defer scaled.deinit(gpa);
    for (reference.node_drop.items, scaled.node_drop.items) |r, s| {
        const expected = 2.0 * r.raw;
        if (@abs(expected) < 1e-12) try assertClose("a zero drop stays zero", s.raw, 0.0, 1e-9) else try assertCloseRelative("a doubled drop", s.raw, expected, 1e-8);
    }
    for (reference.branch_current.items, scaled.branch_current.items) |r, s| {
        const expected = 2.0 * r.raw;
        if (@abs(expected) < 1e-12) continue;
        try assertCloseRelative("a doubled current", s.raw, expected, 1e-8);
    }
}

test "a pad sits at exactly the voltage it was fixed at" {
    // Oracle: law. A pad is a boundary condition, returned unchanged;
    // "near" is not the contract.
    var grid = try common.seriesChain(3, 1.0, 1_800.0, 500.0);
    defer grid.deinit(gpa);
    var s = try common.solve(&grid);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(f64, 1_800.0), s.node_voltage.items[0].raw);
    try testing.expectEqualSlices(u32, &.{0}, grid.source_node.items);
    try testing.expectEqual(@as(f64, 1_800.0), grid.source_voltage.items[0].raw);
}

test "a grid with no pad is refused rather than solved" {
    // Oracle: construct-from-answer, fail closed. With no pad the system is
    // singular; returning the initial guess would read clean.
    var b: common.GridBuilder = .{};
    defer b.grid.deinit(gpa);
    _ = try b.node(0, 1_800.0, 0.0);
    _ = try b.node(1_000, 1_800.0, 100.0);
    try b.edge(0, 1, 1.0);
    const got = try refusal(&b.grid);
    try testing.expectEqual(error.Unanchored, got.err);
}

test "an island no pad reaches is refused and named" {
    // Oracle: construct-from-answer, fail closed. Node 2 is joined to
    // nothing, so the error names node 2.
    var b: common.GridBuilder = .{};
    defer b.grid.deinit(gpa);
    _ = try b.node(0, 1_800.0, 0.0);
    _ = try b.node(1_000, 1_800.0, 100.0);
    _ = try b.node(2_000, 1_800.0, 100.0);
    try b.pad(0, 1_800.0);
    try b.edge(0, 1, 1.0);
    const got = try refusal(&b.grid);
    try testing.expectEqual(error.UnanchoredIsland, got.err);
    try testing.expectEqual(@as(u32, 2), got.at);
}

test "a zero resistance edge is refused rather than shorted" {
    // Oracle: construct-from-answer, fail closed. A zero resistance shorts
    // two nodes and hides a drop; the error names edge 1, the zero one.
    var b: common.GridBuilder = .{};
    defer b.grid.deinit(gpa);
    _ = try b.node(0, 1_800.0, 0.0);
    _ = try b.node(1_000, 1_800.0, 0.0);
    _ = try b.node(2_000, 1_800.0, 100.0);
    try b.pad(0, 1_800.0);
    try b.edge(0, 1, 1.0);
    try b.edge(1, 2, 0.0);
    const got = try refusal(&b.grid);
    try testing.expectEqual(error.BadResistance, got.err);
    try testing.expectEqual(@as(u32, 1), got.at);
}

test "a solution is consistent only with the grid it matches" {
    // Oracle: law. Both answers of `isConsistentWith` matter: a solution of
    // this grid is consistent; one shorter than the node column, or holding
    // a NaN drop, an infinite current or a NaN voltage, is not.
    var grid = try common.seriesChain(3, 2.0, 1_800.0, 400.0);
    defer grid.deinit(gpa);
    var s = try common.solve(&grid);
    defer s.deinit(gpa);
    try testing.expect(s.isConsistentWith(&grid));
    _ = s.node_voltage.pop();
    try testing.expect(!s.isConsistentWith(&grid));
    const Break = enum { drop, current, voltage };
    for ([_]Break{ .drop, .current, .voltage }) |which| {
        var bad = try common.solve(&grid);
        defer bad.deinit(gpa);
        switch (which) {
            .drop => bad.node_drop.items[1].raw = std.math.nan(f64),
            .current => bad.branch_current.items[0].raw = std.math.inf(f64),
            .voltage => bad.node_voltage.items[1].raw = std.math.nan(f64),
        }
        try testing.expect(!bad.isConsistentWith(&grid));
    }
}

test "solving one grid twice produces identical columns" {
    // Oracle: determinism. Byte-identical columns across two runs: the
    // reduction order depends on nothing but the grid.
    var grid = try common.randomGrid(29, 32, 20);
    defer grid.deinit(gpa);
    var first = try common.solve(&grid);
    defer first.deinit(gpa);
    var second = try common.solve(&grid);
    defer second.deinit(gpa);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first.node_voltage.items), std.mem.sliceAsBytes(second.node_voltage.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first.node_drop.items), std.mem.sliceAsBytes(second.node_drop.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first.branch_current.items), std.mem.sliceAsBytes(second.branch_current.items));
}

test "one scratch solving two grids gives each its own answer" {
    // Oracle: law. A reused scratch leaves no trace: solving A then B
    // through one scratch gives exactly what solving B alone gives.
    var first = try common.seriesChain(6, 3.0, 1_800.0, 900.0);
    defer first.deinit(gpa);
    var second = try common.parallelBundle(3, 9.0, 1_200.0, 600.0);
    defer second.deinit(gpa);
    var alone = try common.solve(&second);
    defer alone.deinit(gpa);
    var scratch: SolveScratch = .{};
    defer scratch.deinit(gpa);
    var s: PowerSolution = .{};
    defer s.deinit(gpa);
    var diag: PowerDiag = .{};
    try erc.power_solve.solveInto(gpa, &first, &scratch, &s, &diag);
    try erc.power_solve.solveInto(gpa, &second, &scratch, &s, &diag);
    try testing.expectEqual(alone.node_voltage.items.len, s.node_voltage.items.len);
    for (alone.node_voltage.items, s.node_voltage.items) |a, b| try assertClose("a node after a reused scratch", b.raw, a.raw, 1e-9);
}
