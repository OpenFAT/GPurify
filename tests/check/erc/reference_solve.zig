//! Naive references for the grid solves, written from the definitions and
//! sharing no code with the engine: a dense nodal solve (Gaussian
//! elimination with partial pivoting on the full conductance matrix)
//! against the IC(0)-preconditioned CG solve and the `ir_drop` findings
//! read from it (`erc.electrical.checkIrDrop`), and the same elimination
//! stepped by backward Euler through one switching event against the
//! transient, each within a tolerance derived from the solve's stopping
//! rule. Ported from tests/exhaustive/erc_reference.rs (`supply_grid`,
//! `gauss`, `dense_nodal_solve`, `switching`, `dense_transient` and their
//! tests).
//!
//! Contents:
//! - `pub fn supplyGrid(rng: *Rng, k: u32, power: bool) !PowerGrid`
//! - `pub fn gaussInto(a: []f64, b: []f64, x: []f64) void`
//! - `pub fn denseNodalSolve(grid: *const PowerGrid, voltages: []f64) !f64`

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const erc = check.erc;
const PowerGrid = erc.power_grid.PowerGrid;
const PowerSolution = erc.power_grid.PowerSolution;
const PowerDiag = erc.power_grid.PowerDiag;
const Stimulus = erc.power_transient.Stimulus;
const IntentMap = erc.facts.IntentMap;
const common = @import("common.zig");
const gpa = common.gpa;

/// µA through one ohm per mV across it: Ohm's law in the grid's units.
const ua_per_mv_per_siemens: f64 = 1000.0;

const none = std.math.maxInt(usize);

/// A `k × k` mesh of one supply net at 1 µm pitch: every mesh edge and a
/// few random chords between 0.05 and 5 Ω, one to three pads, each node
/// drawing up to 0.5 mA. A power grid (1.8 V) draws its loads, a ground
/// grid (0 V) has them injected; the first pad sits at the nominal, any
/// other up to 2 mV off, so current also flows between pads.
pub fn supplyGrid(rng: *Rng, k: u32, power: bool) !PowerGrid {
    const nominal: f64 = if (power) 1800.0 else 0.0;
    const n = k * k;
    var g: PowerGrid = .{};
    errdefer g.deinit(gpa);
    for (0..n) |node| {
        const load = 500.0 * rng.unit();
        try g.pushNode(gpa, .{ .net = @fromBackingInt(0), .at = .{ .x = @as(i64, @intCast(node % k)) * 1000, .y = @as(i64, @intCast(node / k)) * 1000 }, .poly = @fromBackingInt(@as(u32, @intCast(node))), .layer = @fromBackingInt(0), .nominal = .{ .raw = nominal }, .load = .{ .raw = if (power) load else -load } });
    }
    for (0..n) |node| {
        const a: u32 = @intCast(node);
        if (node % k + 1 < k) try edge(&g, a, a + 1, rng);
        if (node + k < n) try edge(&g, a, a + k, rng);
    }
    for (0..k) |_| {
        const a: u32 = @intCast(rng.below(n));
        const b: u32 = @intCast(rng.below(n));
        if (a != b) try edge(&g, a, b, rng);
    }
    var pads: std.ArrayList(u32) = .empty;
    defer pads.deinit(gpa);
    for (0..rng.below(3) + 1) |_| try pads.append(gpa, @intCast(rng.below(n)));
    std.mem.sortUnstable(u32, pads.items, {}, std.sort.asc(u32));
    var kept: usize = 0;
    for (pads.items) |p| if (kept == 0 or pads.items[kept - 1] != p) {
        pads.items[kept] = p;
        kept += 1;
    };
    pads.shrinkRetainingCapacity(kept);
    const first = rng.below(pads.items.len);
    for (pads.items, 0..) |pad, i| {
        const off: f64 = if (i == first) 0.0 else 2.0 * rng.unit();
        try g.source_node.append(gpa, pad);
        try g.source_voltage.append(gpa, .{ .raw = if (power) nominal - off else nominal + off });
    }
    return g;
}

/// `x` solving `a x = b` for a dense row-major `n × n` matrix, by Gaussian
/// elimination with partial pivoting; `a` and `b` are consumed.
pub fn gaussInto(a: []f64, b: []f64, x: []f64) void {
    const n = b.len;
    for (0..n) |col| {
        var pivot = col;
        for (col + 1..n) |i| if (@abs(a[i * n + col]) > @abs(a[pivot * n + col])) {
            pivot = i;
        };
        if (pivot != col) {
            for (0..n) |c| std.mem.swap(f64, &a[col * n + c], &a[pivot * n + c]);
            std.mem.swap(f64, &b[col], &b[pivot]);
        }
        for (col + 1..n) |row| {
            const factor = a[row * n + col] / a[col * n + col];
            if (factor == 0.0) continue;
            for (col..n) |c| a[row * n + c] -= factor * a[col * n + c];
            b[row] -= factor * b[col];
        }
    }
    var row = n;
    while (row > 0) {
        row -= 1;
        var tail: f64 = 0.0;
        for (row + 1..n) |c| tail += a[row * n + c] * x[c];
        x[row] = (b[row] - tail) / a[row * n + row];
    }
}

/// The grid's node voltages from the full conductance matrix, into
/// `voltages`, and the tolerance the engine is held to: the solve stops at
/// `1e-10` of its starting residual; the reduced matrix is a diagonally
/// dominant M-matrix, so `‖e‖∞ ≤ ‖A⁻¹‖∞ ‖r‖∞` with `‖A⁻¹‖∞` the largest
/// entry of `A⁻¹ 1`, and rounding adds at most `6 n ε ‖A‖∞ ‖v‖∞`.
pub fn denseNodalSolve(grid: *const PowerGrid, voltages: []f64) !f64 {
    const n = grid.nodeCount();
    const unknown = try gpa.alloc(usize, n);
    defer gpa.free(unknown);
    var m: usize = 0;
    for (unknown, 0..) |*slot, node| {
        slot.* = if (isPad(grid, node)) none else blk: {
            m += 1;
            break :blk m - 1;
        };
    }
    for (voltages, grid.node_nominal.items) |*v, q| v.* = q.raw;
    for (grid.source_node.items, grid.source_voltage.items) |node, v| voltages[node] = v.raw;
    const a = try gpa.alloc(f64, m * m);
    defer gpa.free(a);
    @memset(a, 0.0);
    const b = try gpa.alloc(f64, m);
    defer gpa.free(b);
    for (unknown, 0..) |row, node| if (row != none) {
        b[row] = -grid.node_load.items[node].raw;
    };
    for (grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |i, j, r| {
        const g = ua_per_mv_per_siemens / r.raw;
        for ([2][2]usize{ .{ i, j }, .{ j, i } }) |pair| {
            const row = unknown[pair[0]];
            if (row == none) continue;
            a[row * m + row] += g;
            if (unknown[pair[1]] == none) b[row] += g * voltages[pair[1]] else a[row * m + unknown[pair[1]]] -= g;
        }
    }
    // The residual at the engine's start: every unknown at its nominal.
    var r0: f64 = 0.0;
    var norm_a: f64 = 0.0;
    for (0..m) |row| {
        var ax: f64 = 0.0;
        var abs_row: f64 = 0.0;
        var col: usize = 0;
        for (unknown, 0..) |u, node| if (u != none) {
            ax += a[row * m + col] * grid.node_nominal.items[node].raw;
            abs_row += @abs(a[row * m + col]);
            col += 1;
        };
        r0 += (b[row] - ax) * (b[row] - ax);
        norm_a = @max(norm_a, abs_row);
    }
    r0 = @sqrt(r0);
    const inverse_norm = try inverseNorm(a, m);
    const x = try gpa.alloc(f64, m);
    defer gpa.free(x);
    gaussInto(a, b, x);
    for (unknown, 0..) |row, node| if (row != none) {
        voltages[node] = x[row];
    };
    var largest: f64 = 0.0;
    for (voltages) |v| largest = @max(largest, @abs(v));
    return inverse_norm * (1e-10 * r0 + 6.0 * @as(f64, @floatFromInt(m)) * std.math.floatEps(f64) * norm_a * largest);
}

// ---- private ----

fn edge(g: *PowerGrid, a: u32, b: u32, rng: *Rng) !void {
    try g.pushEdge(gpa, .{ .from = a, .to = b, .ohms = 0.05 * std.math.pow(f64, 100.0, rng.unit()), .width = 1000, .length = 1000, .layer = @fromBackingInt(0), .kind = .metal });
}

fn isPad(grid: *const PowerGrid, node: usize) bool {
    return std.mem.indexOfScalar(u32, grid.source_node.items, @intCast(node)) != null;
}

/// `‖A⁻¹‖∞` of an M-matrix: the largest entry of `A⁻¹ 1`; `a` is kept.
fn inverseNorm(a: []const f64, m: usize) !f64 {
    const copy = try gpa.dupe(f64, a);
    defer gpa.free(copy);
    const ones = try gpa.alloc(f64, m);
    defer gpa.free(ones);
    @memset(ones, 1.0);
    const x = try gpa.alloc(f64, m);
    defer gpa.free(x);
    gaussInto(copy, ones, x);
    var best: f64 = 0.0;
    for (x) |v| best = @max(best, v);
    return best;
}

/// The `ir_drop` half: a `max_drop` limit between two reference drops (past
/// the lowest third) more than twice `tolerance` apart flags exactly the
/// nodes whose reference drop is above it, each within `tolerance`. False
/// when no such gap exists.
fn irDropAgrees(grid: *const PowerGrid, solution: *const PowerSolution, reference: []const f64, tolerance: f64, power: bool) !bool {
    // The drop toward the other rail: down for power, up for ground.
    const nominal = grid.node_nominal.items[0].raw;
    const drop = try gpa.alloc(f64, reference.len);
    defer gpa.free(drop);
    for (drop, reference) |*d, v| d.* = if (power) nominal - v else v - nominal;
    const sorted = try gpa.dupe(f64, drop);
    defer gpa.free(sorted);
    std.mem.sortUnstable(f64, sorted, {}, std.sort.asc(f64));
    const limit = for (sorted.len / 3..sorted.len -| 1) |i| {
        if (sorted[i + 1] - sorted[i] > 2.0 * tolerance) break 0.5 * (sorted[i] + sorted[i + 1]);
    } else return false;

    // One supply on net 0 in a 1.8 V domain, limited to `limit`.
    var intent: IntentMap = .{ .declared = true };
    defer intent.deinit(gpa);
    try intent.supply_net.append(gpa, @fromBackingInt(0));
    try intent.supply_role.append(gpa, if (power) .power else .ground);
    try intent.supply_domain.append(gpa, @fromBackingInt(0));
    try intent.supply_voltage.append(gpa, .{ .raw = 1800.0 });
    try common.limitNet(&intent, @fromBackingInt(0), .{ .max_drop = .{ .raw = limit } });
    var t: erc.electrical_tables.IrDropTable = .{ .head = try common.head(common.rule(1)) };
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.electrical.checkIrDrop(sink.record(), .{ .solved = .{ .grid = grid, .solution = solution } }, &intent, &t);

    // Exactly the nodes above the limit, in any order.
    var flagged: u32 = 0;
    for (drop, 0..) |d, node| if (d > limit) {
        flagged += 1;
        const row = for (0..sink.out.len()) |row| {
            if (sink.out.at.items[row].eql(grid.node_at.items[node])) break row;
        } else return error.NodeNotFlagged;
        try testing.expect(@abs(sink.out.get(@intCast(row)).measured.float() - d) <= tolerance);
    };
    try testing.expectEqual(flagged, sink.out.len());
    return true;
}

/// One switching event: every node's load times three as its triangle's
/// peak, a rise of 50 or 100 ps, 0 to 5 pF of decap, followed for 300 ps.
fn switching(rng: *Rng, grid: *const PowerGrid) !Stimulus {
    var s: Stimulus = .{ .window_ps = 300.0 };
    errdefer s.deinit(gpa);
    for (grid.node_load.items) |l| try s.node_peak.append(gpa, .{ .raw = 3.0 * l.raw });
    for (0..grid.nodeCount()) |_| try s.node_rise_ps.append(gpa, if (rng.below(2) == 0) 50.0 else 100.0);
    for (0..grid.nodeCount()) |_| try s.node_cap_pf.append(gpa, 5.0 * rng.unit());
    return s;
}

/// Each node's drop of largest magnitude through the event, by backward
/// Euler on the dense `G + C/h` (every step solved by `gaussInto`), into
/// `best`, and the tolerance: `A⁻¹ C/h` has row sums at most one, so the
/// steps' errors add, each bounded as in `denseNodalSolve` from the warm
/// start.
fn denseTransient(grid: *const PowerGrid, s: *const Stimulus, best: []f64) !f64 {
    const n = grid.nodeCount();
    const unknown = try gpa.alloc(usize, n);
    defer gpa.free(unknown);
    var node_of: std.ArrayList(usize) = .empty;
    defer node_of.deinit(gpa);
    for (unknown, 0..) |*slot, node| {
        slot.* = if (isPad(grid, node)) none else node_of.items.len;
        if (slot.* != none) try node_of.append(gpa, node);
    }
    const m = node_of.items.len;
    const per_rise: f64 = @floatFromInt(erc.power_transient.steps_per_rise);
    var shortest = std.math.inf(f64);
    for (s.node_peak.items, s.node_rise_ps.items) |p, r| if (p.raw != 0.0) {
        shortest = @min(shortest, r);
    };
    const h = shortest / per_rise;
    const c = try gpa.alloc(f64, m);
    defer gpa.free(c);
    const span = try gpa.alloc(f64, m);
    defer gpa.free(span);
    for (node_of.items, c, span) |node, *cc, *sp| {
        cc.* = 1000.0 * s.node_cap_pf.items[node] / h;
        sp.* = per_rise * (s.node_rise_ps.items[node] / shortest);
    }
    const a = try gpa.alloc(f64, m * m);
    defer gpa.free(a);
    @memset(a, 0.0);
    for (c, 0..) |cap, row| a[row * m + row] += cap;
    for (grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |i, j, r| {
        const g = ua_per_mv_per_siemens / r.raw;
        for ([2][2]usize{ .{ i, j }, .{ j, i } }) |pair| {
            const row = unknown[pair[0]];
            if (row == none) continue;
            a[row * m + row] += g;
            if (unknown[pair[1]] != none) a[row * m + unknown[pair[1]]] -= g;
        }
    }
    const last = s.window_ps / h;
    const resp = try gpa.alloc(f64, m);
    defer gpa.free(resp);
    @memset(resp, 0.0);
    @memset(best, 0.0);
    const rhs = try gpa.alloc(f64, m);
    defer gpa.free(rhs);
    const work = try gpa.alloc(f64, m * m);
    defer gpa.free(work);
    var start_residual: f64 = 0.0;
    var largest: f64 = 0.0;
    var k: u32 = 0;
    while (@as(f64, @floatFromInt(k)) < last) {
        k += 1;
        for (rhs, 0..) |*b, row| {
            const fraction = @as(f64, @floatFromInt(k)) / span[row];
            const shape = if (fraction <= 1.0) 1.0 - @abs(2.0 * fraction - 1.0) else 0.0;
            b.* = c[row] * resp[row] + s.node_peak.items[node_of.items[row]].raw * shape;
        }
        var residual: f64 = 0.0;
        for (0..m) |row| {
            var ax: f64 = 0.0;
            for (0..m) |col| ax += a[row * m + col] * resp[col];
            residual += (rhs[row] - ax) * (rhs[row] - ax);
        }
        start_residual = @max(start_residual, @sqrt(residual));
        @memcpy(work, a);
        gaussInto(work, rhs, resp);
        for (resp, node_of.items) |v, node| {
            largest = @max(largest, @abs(v));
            if (@abs(v) > @abs(best[node])) best[node] = v;
        }
    }
    var norm_a: f64 = 0.0;
    for (0..m) |row| {
        var abs_row: f64 = 0.0;
        for (0..m) |col| abs_row += @abs(a[row * m + col]);
        norm_a = @max(norm_a, abs_row);
    }
    const inverse_norm = try inverseNorm(a, m);
    const per_step = inverse_norm * (1e-10 * start_residual + 6.0 * @as(f64, @floatFromInt(m)) * std.math.floatEps(f64) * norm_a * largest);
    return @as(f64, @floatFromInt(k)) * per_step;
}

test "supply grids solve as a dense nodal solve does" {
    // Oracle: a dense nodal solve. On forty generated supply grids, power and
    // ground, 2 × 2 to 8 × 8, every node voltage the engine solves is within the
    // tolerance [`dense_nodal_solve`] derives of the dense solve's, and an
    // `ir_drop` row whose limit sits between two of the reference drops more
    // than twice that tolerance apart flags exactly the nodes whose reference
    // drop is above it, each measured within the tolerance.
    // (The `ir_drop` half is `irDropAgrees`, below.)
    var rng = Rng.init(0xc6_0001);
    var checked: u32 = 0;
    for (0..40) |case| {
        const power = case % 2 == 0;
        const k: u32 = @intCast(2 + case / 2 % 7);
        var grid = try supplyGrid(&rng, k, power);
        defer grid.deinit(gpa);
        const reference = try gpa.alloc(f64, grid.nodeCount());
        defer gpa.free(reference);
        const tolerance = try denseNodalSolve(&grid, reference);
        var s = try common.solve(&grid);
        defer s.deinit(gpa);
        for (reference, s.node_voltage.items) |want, got| try testing.expect(@abs(got.raw - want) <= tolerance);
        if (try irDropAgrees(&grid, &s, reference, tolerance, power)) checked += 1;
    }
    try testing.expect(checked >= 30);
}

test "switching grids step as a dense backward euler does" {
    // Oracle: a dense backward-Euler reference. On forty generated grids,
    // power and ground, 2 × 2 to 8 × 8, with mixed rise times and random
    // decap, every node's largest drop through one switching event is within
    // the tolerance `denseTransient` derives of the dense walk's, and every
    // pad's is zero.
    var rng = Rng.init(0xe1_1001);
    for (0..40) |case| {
        const power = case % 2 == 0;
        const k: u32 = @intCast(2 + case / 2 % 7);
        var grid = try supplyGrid(&rng, k, power);
        defer grid.deinit(gpa);
        var stimulus = try switching(&rng, &grid);
        defer stimulus.deinit(gpa);
        const reference = try gpa.alloc(f64, grid.nodeCount());
        defer gpa.free(reference);
        const tolerance = try denseTransient(&grid, &stimulus, reference);
        var scratch: erc.power_solve.SolveScratch = .{};
        defer scratch.deinit(gpa);
        var got: std.ArrayList(check.report.Millivolts) = .empty;
        defer got.deinit(gpa);
        var diag: PowerDiag = .{};
        try erc.power_transient.transientInto(gpa, &grid, &stimulus, &scratch, &got, &diag);
        for (reference, got.items) |want, have| try testing.expect(@abs(have.raw - want) <= tolerance);
    }
}
