//! The DC solve of a `PowerGrid`: pads eliminated, the reduced Laplacian
//! assembled (CSR, diagonal first), factorised IC(0) as `L D Lᵀ` (the
//! diagonal on breakdown), and solved by preconditioned conjugate gradient
//! to `1e-10` of the starting residual. In: a grid. Out: a `PowerSolution`
//! (voltages, drops, branch currents), or the first refusal. Ported from
//! crates/check/src/erc/power.rs (`SolveScratch`, `assemble_into`,
//! `factorise_into`, `precondition`, `conjugate_gradient`, `pose_into`,
//! `solve_into`).
//!
//! Determinism: `dot`, `nrm2` and `spmv` are geom.linalg's strict left
//! folds (their order decides alpha and the convergence verdict); `axpy` and
//! `xpay` run through the Gompute zip specs on the CPU, bit-identical to
//! the scalar loops. ponytail: the solve stays on the CPU, because IC(0)'s
//! triangular solves are sequential; a GPU path would precondition by
//! Jacobi or level-scheduled triangular solves, upload `x` per iteration
//! through `geom.bulk`, and keep the folds here.
//!
//! Contents:
//! - `pub const SolveScratch = struct`, `deinit`, `pub const Entry = struct { col: u32, value: f64 }`, `pub const Branch = struct { a: u32, b: u32, g: f64 }`
//! - `pub const relative_tolerance: f64`, `pub const max_iterations: u32`
//! - `pub fn solveInto(gpa: Allocator, grid: *const PowerGrid, scratch: *SolveScratch, out: *PowerSolution, diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub fn poseInto(gpa: Allocator, grid: *const PowerGrid, scratch: *SolveScratch, diag: *PowerDiag) (PowerError || Allocator.Error)!u32`
//! - `pub fn assembleGridInto(gpa: Allocator, grid: *const PowerGrid, scratch: *SolveScratch, unknowns: u32) Allocator.Error!void`
//! - `pub fn assembleInto(gpa: Allocator, scratch: *SolveScratch, unknowns: u32) Allocator.Error!void`
//! - `pub fn factoriseInto(gpa: Allocator, scratch: *SolveScratch, unknowns: u32) Allocator.Error!void`
//! - `pub fn conjugateGradient(gpa: Allocator, scratch: *SolveScratch, diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub fn badResistance(resistance: []const Ohms, diag: *PowerDiag) PowerError!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const g = @import("gompute");
const geom = @import("geom");
const linalg = geom.linalg;
const Ohms = @import("../report.zig").Ohms;
const grid_ = @import("power_grid.zig");
const PowerGrid = grid_.PowerGrid;
const PowerSolution = grid_.PowerSolution;
const PowerError = grid_.PowerError;
const PowerDiag = grid_.PowerDiag;
const ua_per_mv_ohm = grid_.ua_per_mv_ohm;
const not_an_unknown = grid_.not_a_node;

/// CG stops once the residual is this fraction of the initial one.
pub const relative_tolerance: f64 = 1e-10;
/// CG refuses after this many iterations.
pub const max_iterations: u32 = 20_000;

/// The linear-solve workspace, reused solve after solve.
pub const SolveScratch = struct {
    /// The reduced Laplacian, CSR, slot 0 of each row its diagonal;
    /// duplicate columns stay duplicated (the mat-vec sums them).
    row_start: std.ArrayList(u32) = .empty,
    col: std.ArrayList(u32) = .empty,
    value: std.ArrayList(f64) = .empty,
    rhs: std.ArrayList(f64) = .empty,
    x: std.ArrayList(f64) = .empty,
    r: std.ArrayList(f64) = .empty,
    p: std.ArrayList(f64) = .empty,
    ap: std.ArrayList(f64) = .empty,
    z: std.ArrayList(f64) = .empty,
    /// The diagonal preconditioner, as reciprocals.
    inv_diag: std.ArrayList(f64) = .empty,
    /// IC(0): the unit lower triangle's strict part, CSR, columns ascending
    /// and merged, and the pivots `D`. Empty: use the diagonal.
    l_start: std.ArrayList(u32) = .empty,
    l_col: std.ArrayList(u32) = .empty,
    l_val: std.ArrayList(f64) = .empty,
    l_diag: std.ArrayList(f64) = .empty,
    row_stage: std.ArrayList(Entry) = .empty,
    unknown_of_node: std.ArrayList(u32) = .empty,
    node_of_unknown: std.ArrayList(u32) = .empty,
    cursor: std.ArrayList(u32) = .empty,
    diag: std.ArrayList(f64) = .empty,
    /// Edges in unknown space: `(a, b, conductance)`, a pad end `not_an_unknown`.
    branch: std.ArrayList(Branch) = .empty,
    pairs: std.ArrayList([2]u32) = .empty,
    labels: std.ArrayList(u32) = .empty,
    reached: std.ArrayList(bool) = .empty,

    pub const Entry = struct { col: u32, value: f64 };
    pub const Branch = struct { a: u32, b: u32, g: f64 };

    pub fn deinit(s: *SolveScratch, gpa: Allocator) void {
        inline for (@typeInfo(SolveScratch).@"struct".field_names) |f| @field(s, f).deinit(gpa);
    }
};

/// Solves the grid for node voltages and branch currents; `out` is
/// refilled. Pads are eliminated first (leaving an SPD system) and an
/// island no pad reaches is refused before CG, which on a singular system
/// converges to nonsense. Refusals, `diag` naming the node or edge:
/// `NotFinite` for a non-finite nominal, load or pad voltage or result,
/// `BadResistance`, `Unanchored`, `UnanchoredIsland`, `NotConverged`.
pub fn solveInto(gpa: Allocator, grid: *const PowerGrid, scratch: *SolveScratch, out: *PowerSolution, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    out.node_voltage.clearRetainingCapacity();
    out.node_drop.clearRetainingCapacity();
    out.branch_current.clearRetainingCapacity();
    // Non-finite inputs first: a NaN would pass every check downstream.
    for (grid.node_nominal.items, grid.node_load.items, 0..) |v, i, node| if (!v.isFinite() or !i.isFinite()) {
        diag.at = @intCast(node);
        return error.NotFinite;
    };
    for (grid.source_voltage.items, grid.source_node.items) |v, node| if (!v.isFinite()) {
        diag.at = node;
        return error.NotFinite;
    };
    const unknowns = try poseInto(gpa, grid, scratch, diag);
    const s = scratch;

    // Start at nominal (pads at their fixed voltage), so the residual
    // measures interconnect loss and the tolerance is a fraction of the drop.
    try out.node_voltage.appendSlice(gpa, grid.node_nominal.items);
    const volts = out.node_voltage.items;
    for (grid.source_node.items, grid.source_voltage.items) |node, v| volts[node] = v;
    s.x.clearRetainingCapacity();
    s.rhs.clearRetainingCapacity();
    // Kirchhoff: the Laplacian row is minus the load.
    for (s.node_of_unknown.items) |node| {
        try s.x.append(gpa, volts[node].raw);
        try s.rhs.append(gpa, -grid.node_load.items[node].raw);
    }
    // A conductance to a pad moves `g * v` to the right-hand side; the bin
    // slot past the end absorbs the other rows' zero terms.
    try s.rhs.append(gpa, 0.0);
    for (grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |from, to, r| {
        const cond = ua_per_mv_ohm / r.raw;
        const a = s.unknown_of_node.items[from];
        const b = s.unknown_of_node.items[to];
        const a_unknown = a != not_an_unknown;
        const b_unknown = b != not_an_unknown;
        s.rhs.items[@min(a, unknowns)] += cond * volts[to].raw * @as(f64, @floatFromInt(@intFromBool(a_unknown and !b_unknown)));
        s.rhs.items[@min(b, unknowns)] += cond * volts[from].raw * @as(f64, @floatFromInt(@intFromBool(b_unknown and !a_unknown)));
    }
    s.rhs.shrinkRetainingCapacity(unknowns);

    try assembleGridInto(gpa, grid, s, unknowns);
    try factoriseInto(gpa, s, unknowns);
    try conjugateGradient(gpa, s, diag);

    // Pads keep their exact fixed voltage.
    for (s.node_of_unknown.items, s.x.items) |node, x| volts[node] = .{ .raw = x };
    for (grid.node_nominal.items, volts) |nominal, v| try out.node_drop.append(gpa, nominal.sub(v));
    for (grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |from, to, r| {
        const across = volts[from].raw - volts[to].raw;
        try out.branch_current.append(gpa, .{ .raw = across * (ua_per_mv_ohm / r.raw) });
    }
    if (!out.isConsistentWith(grid)) {
        diag.at = blk: {
            for (volts, out.node_drop.items, 0..) |v, d, node| if (!v.isFinite() or !d.isFinite()) break :blk @intCast(node);
            for (out.branch_current.items, 0..) |c, e| if (!c.isFinite()) break :blk grid.edge_from.items[e];
            break :blk 0;
        };
        return error.NotFinite;
    }
}

/// Refuses a grid no solve can pose (an edge not positive and finite, no
/// pad, an island no pad reaches) and numbers its unknowns: every node but
/// a pad, ascending. Returns how many.
pub fn poseInto(gpa: Allocator, grid: *const PowerGrid, scratch: *SolveScratch, diag: *PowerDiag) (PowerError || Allocator.Error)!u32 {
    const nodes = grid.nodeCount();
    try badResistance(grid.edge_resistance.items, diag);
    if (grid.source_node.items.len == 0) return error.Unanchored;
    const s = scratch;
    s.pairs.clearRetainingCapacity();
    for (grid.edge_from.items, grid.edge_to.items) |a, b| try s.pairs.append(gpa, .{ a, b });
    try geom.connectivity.componentsInto(gpa, nodes, s.pairs.items, &s.labels);
    s.reached.clearRetainingCapacity();
    try s.reached.appendNTimes(gpa, false, nodes);
    for (grid.source_node.items) |pad| s.reached.items[s.labels.items[pad]] = true;
    for (s.labels.items, 0..) |l, node| if (!s.reached.items[l]) {
        diag.at = @intCast(node);
        return error.UnanchoredIsland;
    };
    // Every non-pad node gets an unknown; a pad's is `not_an_unknown`
    // (`reached` reused as the pad mask).
    @memset(s.reached.items, false);
    for (grid.source_node.items) |pad| s.reached.items[pad] = true;
    s.unknown_of_node.clearRetainingCapacity();
    try s.unknown_of_node.appendNTimes(gpa, not_an_unknown, nodes);
    s.node_of_unknown.clearRetainingCapacity();
    for (s.reached.items, 0..) |pad, node| if (!pad) {
        s.unknown_of_node.items[node] = @intCast(s.node_of_unknown.items.len);
        try s.node_of_unknown.append(gpa, @intCast(node));
    };
    return @intCast(s.node_of_unknown.items.len);
}

/// Assembles the grid's reduced Laplacian over the unknowns `poseInto`
/// numbered.
pub fn assembleGridInto(gpa: Allocator, grid: *const PowerGrid, scratch: *SolveScratch, unknowns: u32) Allocator.Error!void {
    scratch.branch.clearRetainingCapacity();
    for (grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |a, b, r| {
        try scratch.branch.append(gpa, .{ .a = scratch.unknown_of_node.items[a], .b = scratch.unknown_of_node.items[b], .g = ua_per_mv_ohm / r.raw });
    }
    try assembleInto(gpa, scratch, unknowns);
}

/// The reduced Laplacian (CSR, diagonal first per row) and its inverse
/// diagonal from `scratch.branch`. A pad end loads the other end's
/// diagonal and adds no off-diagonal; each diagonal accumulates in edge
/// order.
pub fn assembleInto(gpa: Allocator, scratch: *SolveScratch, unknowns: u32) Allocator.Error!void {
    const s = scratch;
    s.cursor.clearRetainingCapacity();
    try s.cursor.appendNTimes(gpa, 0, unknowns);
    s.diag.clearRetainingCapacity();
    try s.diag.appendNTimes(gpa, 0.0, unknowns);
    for (s.branch.items) |br| if (br.a != not_an_unknown and br.b != not_an_unknown) {
        s.cursor.items[br.a] += 1;
        s.cursor.items[br.b] += 1;
    };
    // Offsets; slot zero of every row is the diagonal.
    s.row_start.clearRetainingCapacity();
    try s.row_start.append(gpa, 0);
    var running: u32 = 0;
    for (s.cursor.items) |*count| {
        const first = running;
        running += 1 + count.*;
        try s.row_start.append(gpa, running);
        count.* = first + 1;
    }
    try s.col.resize(gpa, running);
    try s.value.resize(gpa, running);
    @memset(s.value.items, 0.0);
    for (0..unknowns) |i| s.col.items[s.row_start.items[i]] = @intCast(i);
    for (s.branch.items) |br| {
        const a_unknown = br.a != not_an_unknown;
        const b_unknown = br.b != not_an_unknown;
        if (a_unknown) s.diag.items[br.a] += br.g;
        if (b_unknown) s.diag.items[br.b] += br.g;
        if (a_unknown and b_unknown) for ([2][2]u32{ .{ br.a, br.b }, .{ br.b, br.a } }) |pair| {
            const k = s.cursor.items[pair[0]];
            s.col.items[k] = pair[1];
            s.value.items[k] = -br.g;
            s.cursor.items[pair[0]] += 1;
        };
    }
    s.inv_diag.clearRetainingCapacity();
    for (0..unknowns) |i| {
        // Every unknown reaches a pad through positive conductance.
        assert(s.diag.items[i] > 0.0);
        assert(s.cursor.items[i] == s.row_start.items[i + 1]);
        s.value.items[s.row_start.items[i]] = s.diag.items[i];
        try s.inv_diag.append(gpa, 1.0 / s.diag.items[i]);
    }
}

/// IC(0): the assembled matrix factorised with zero fill as `L D Lᵀ`,
/// duplicate columns merged. Without square roots a factor of a network
/// with exact binary values is exact: on a tree, where zero fill drops
/// nothing, CG lands on the solution in one step, so a closed-form drop is
/// the same bits near 0 mV as on a power rail. On breakdown the factor is
/// left empty, which selects the diagonal (a partial factor would diverge).
pub fn factoriseInto(gpa: Allocator, scratch: *SolveScratch, unknowns: u32) Allocator.Error!void {
    const s = scratch;
    s.l_start.clearRetainingCapacity();
    s.l_col.clearRetainingCapacity();
    s.l_val.clearRetainingCapacity();
    s.l_diag.clearRetainingCapacity();
    try s.l_diag.appendNTimes(gpa, 0.0, unknowns);
    try s.l_start.append(gpa, 0);
    // The pattern: each row's strict lower entries, sorted and merged.
    for (0..unknowns) |i| {
        s.row_stage.clearRetainingCapacity();
        for (s.row_start.items[i]..s.row_start.items[i + 1]) |k| if (s.col.items[k] < i) {
            try s.row_stage.append(gpa, .{ .col = s.col.items[k], .value = s.value.items[k] });
        };
        std.mem.sortUnstable(SolveScratch.Entry, s.row_stage.items, {}, struct {
            fn less(_: void, a: SolveScratch.Entry, b: SolveScratch.Entry) bool {
                return a.col < b.col;
            }
        }.less);
        for (s.row_stage.items) |e| {
            const fresh = s.l_col.items.len == s.l_start.items[i] or s.l_col.items[s.l_col.items.len - 1] != e.col;
            if (fresh) {
                try s.l_col.append(gpa, e.col);
                try s.l_val.append(gpa, 0.0);
            }
            s.l_val.items[s.l_val.items.len - 1] += e.value;
        }
        try s.l_start.append(gpa, @intCast(s.l_col.items.len));
    }
    // The factorisation in row order; each sparse dot a two-pointer merge.
    const lc = s.l_col.items;
    const lv = s.l_val.items;
    const ld = s.l_diag.items;
    for (0..unknowns) |i| {
        const from = s.l_start.items[i];
        const to = s.l_start.items[i + 1];
        var d = s.value.items[s.row_start.items[i]];
        for (from..to) |t| {
            const j = lc[t];
            var sum = lv[t];
            var p: usize = from;
            var q: usize = s.l_start.items[j];
            const q_end = s.l_start.items[j + 1];
            while (p < t and q < q_end) {
                const cp = lc[p];
                const cq = lc[q];
                const hit: f64 = @floatFromInt(@intFromBool(cp == cq));
                sum -= lv[p] * lv[q] * ld[cp] * hit;
                p += @intFromBool(cp <= cq);
                q += @intFromBool(cq <= cp);
            }
            const v = sum / ld[j];
            lv[t] = v;
            d -= v * sum;
        }
        if (!(d > 0.0 and std.math.isFinite(d))) {
            s.l_start.clearRetainingCapacity();
            s.l_col.clearRetainingCapacity();
            s.l_val.clearRetainingCapacity();
            s.l_diag.clearRetainingCapacity();
            return;
        }
        ld[i] = d;
    }
}

/// Preconditioned CG on the assembled and factorised system, from the guess
/// in `scratch.x`. A NaN residual refuses (`NotConverged`).
pub fn conjugateGradient(gpa: Allocator, scratch: *SolveScratch, diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    const s = scratch;
    const n = s.x.items.len;
    inline for (.{ &s.z, &s.ap, &s.r, &s.p }) |v| try v.resize(gpa, n);
    const x = s.x.items;
    const r = s.r.items;
    const p = s.p.items;
    const ap = s.ap.items;
    const z = s.z.items;
    @memset(z, 0.0);
    // A length mismatch is a bug here, never a run-time case.
    var axpy = g.Kernel(linalg.axpy, .cpu).init(0) catch unreachable;
    var xpay = g.Kernel(linalg.xpay, .cpu).init(0) catch unreachable;
    linalg.spmv(s.row_start.items, s.col.items, s.value.items, x, ap);
    for (r, s.rhs.items, ap) |*ri, b, ax| ri.* = b - ax;
    precondition(s, r, z);
    @memcpy(p, z);
    var rz = linalg.dot(r, z);
    const initial = linalg.nrm2(r);
    const goal = initial * relative_tolerance;
    var residual = initial;
    var iterations: u32 = 0;
    while (residual > goal and iterations < max_iterations) : (iterations += 1) {
        linalg.spmv(s.row_start.items, s.col.items, s.value.items, p, ap);
        const pap = linalg.dot(p, ap);
        // Non-positive `p·Ap`: the floating-point floor; the test below decides.
        if (!(pap > 0.0)) break;
        const alpha = rz / pap;
        axpy.run(p, x, x, .{ .alpha = alpha }) catch unreachable;
        axpy.run(ap, r, r, .{ .alpha = -alpha }) catch unreachable;
        precondition(s, r, z);
        const next = linalg.dot(r, z);
        xpay.run(z, p, p, .{ .beta = next / rz }) catch unreachable;
        rz = next;
        residual = linalg.nrm2(r);
    }
    if (!(residual <= goal)) {
        diag.at = max_iterations;
        return error.NotConverged;
    }
}

/// The first edge without a positive finite resistance (zero would short
/// two nodes and hide a drop), named in `diag`.
pub fn badResistance(resistance: []const Ohms, diag: *PowerDiag) PowerError!void {
    for (resistance, 0..) |r, e| if (!(r.raw > 0.0 and r.isFinite())) {
        diag.at = @intCast(e);
        return error.BadResistance;
    };
}

// ---- private ----

/// `z = M⁻¹ r`: forward and back substitution through the IC(0) factor,
/// or the diagonal when the factor is empty.
fn precondition(s: *const SolveScratch, r: []const f64, z: []f64) void {
    const n = z.len;
    if (s.l_diag.items.len == 0) {
        for (z, r, s.inv_diag.items) |*zi, ri, d| zi.* = ri * d;
        return;
    }
    const ls = s.l_start.items;
    const lc = s.l_col.items;
    const lv = s.l_val.items;
    // `L y = r`, ascending; `L` has a unit diagonal.
    for (0..n) |i| {
        var sum = r[i];
        for (ls[i]..ls[i + 1]) |t| sum -= lv[t] * z[lc[t]];
        z[i] = sum;
    }
    // `D w = y`.
    for (z, s.l_diag.items) |*zi, d| zi.* /= d;
    // `Lᵀ z = w`, descending, scattering each row back over the rows above.
    var i = n;
    while (i > 0) {
        i -= 1;
        const v = z[i];
        for (ls[i]..ls[i + 1]) |t| z[lc[t]] -= lv[t] * v;
    }
}

test "an incomplete factor reproduces the matrix wherever the matrix is nonzero" {
    // Oracle: the defining property of IC(0): `L D L^T` equals the matrix on
    // its sparsity pattern, checked entry by entry on a four-node cycle with
    // one pad; a cycle drops fill, so the factor must differ somewhere.
    const gpa = std.testing.allocator;
    const N = 4;
    var s: SolveScratch = .{};
    defer s.deinit(gpa);
    try s.branch.appendSlice(gpa, &.{
        .{ .a = 0, .b = 1, .g = 2.0 },               .{ .a = 1, .b = 2, .g = 4.0 },
        .{ .a = 2, .b = 3, .g = 8.0 },               .{ .a = 3, .b = 0, .g = 16.0 },
        .{ .a = 0, .b = not_an_unknown, .g = 32.0 },
    });
    try assembleInto(gpa, &s, N);
    try factoriseInto(gpa, &s, N);
    try std.testing.expect(s.l_diag.items.len != 0);
    var a = std.mem.zeroes([N][N]f64);
    for (0..N) |i| for (s.row_start.items[i]..s.row_start.items[i + 1]) |t| {
        a[i][s.col.items[t]] += s.value.items[t];
    };
    var l = std.mem.zeroes([N][N]f64);
    for (0..N) |i| {
        l[i][i] = 1.0;
        for (s.l_start.items[i]..s.l_start.items[i + 1]) |t| l[i][s.l_col.items[t]] = s.l_val.items[t];
    }
    var holes: usize = 0;
    for (0..N) |i| for (0..N) |j| {
        var llt: f64 = 0.0;
        for (0..N) |k| llt += l[i][k] * s.l_diag.items[k] * l[j][k];
        if (a[i][j] == 0.0) {
            holes += @intFromBool(@abs(llt) > 1e-9);
            continue;
        }
        try std.testing.expect(@abs(llt - a[i][j]) < 1e-9 * @abs(a[i][j]));
    };
    try std.testing.expect(holes > 0);
}
