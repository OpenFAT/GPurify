//! A supply grid's response to one switching event per node, from rest. In:
//! a `PowerGrid` and a `Stimulus` (each node's triangular current pulse and
//! decap). Out: each node's drop of largest magnitude, signed as
//! `PowerSolution.node_drop` (a pad's is zero). Backward Euler with a fixed
//! step `h` (the shortest rise over `steps_per_rise`) solves
//! `(G + C/h) r[k+1] = (C/h) r[k] + i[k+1]` with the static solve's
//! preconditioned CG, factorised once (Kouroussis and Najm, DAC 2003). Once
//! every pulse has ended the walk stops at the first step in which no drop
//! grew (`(G + C/h)⁻¹ C/h` is nonnegative, so none can grow again), else at
//! the window. Ported from crates/check/src/erc/power.rs (`Stimulus`,
//! `transient_into`, `STEPS_PER_RISE`).
//!
//! Contents:
//! - `pub const steps_per_rise: u32`
//! - `pub const Stimulus = struct`, `deinit`
//! - `pub fn transientInto(gpa: Allocator, grid: *const PowerGrid, stimulus: *const Stimulus, scratch: *SolveScratch, out: *std.ArrayList(Millivolts), diag: *PowerDiag) (PowerError || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const report = @import("../report.zig");
const Millivolts = report.Millivolts;
const Microamps = report.Microamps;
const grid_ = @import("power_grid.zig");
const PowerGrid = grid_.PowerGrid;
const PowerError = grid_.PowerError;
const PowerDiag = grid_.PowerDiag;
const solve = @import("power_solve.zig");
const SolveScratch = solve.SolveScratch;

/// Backward-Euler steps per rise of the fastest switching node. Even, so
/// its peak falls on a step. At 128 the peak of an RC node's response to
/// its pulse reads low by at most 0.61 % of the closed form.
pub const steps_per_rise: u32 = 128;

/// One switching event per node; every column one row per grid node.
pub const Stimulus = struct {
    /// The peak of the node's triangular pulse, signed as `node_load`;
    /// zero for a node that does not switch.
    node_peak: std.ArrayList(Microamps) = .empty,
    /// The pulse's base, ps: it rises for the first half, falls for the
    /// second. Read only where the peak is not zero.
    node_rise_ps: std.ArrayList(f64) = .empty,
    /// Capacitance to an ideal reference, pF: the node's decap.
    node_cap_pf: std.ArrayList(f64) = .empty,
    /// How long after the pulses start the grid is followed, ps.
    window_ps: f64 = 0.0,

    pub fn deinit(s: *Stimulus, gpa: Allocator) void {
        s.node_peak.deinit(gpa);
        s.node_rise_ps.deinit(gpa);
        s.node_cap_pf.deinit(gpa);
    }
};

/// Microamps per millivolt from pF over ps: `pF · mV / ps = mA`.
const ua_per_mv_per_pf_ps: f64 = 1_000.0;

/// Fills `out` (one row per node) with each node's worst transient drop.
/// Refusals as `solveInto` for the grid, and `NotFinite` (`diag` the node)
/// for a peak or decap not finite, a negative decap, a switching node's
/// rise not positive and finite, or a non-finite response. No switching
/// node: zeros, never an error. One CG solve per step, at most
/// `window / h` steps. Asserts one stimulus row per node.
pub fn transientInto(gpa: Allocator, grid: *const PowerGrid, stimulus: *const Stimulus, scratch: *SolveScratch, out: *std.ArrayList(Millivolts), diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    // ponytail: one fixed step for the whole window; a step that grows
    // after the pulses if long windows cost too many solves.
    const nodes = grid.nodeCount();
    const peak = stimulus.node_peak.items;
    const rise = stimulus.node_rise_ps.items;
    const cap = stimulus.node_cap_pf.items;
    assert(peak.len == nodes and rise.len == nodes and cap.len == nodes);
    out.clearRetainingCapacity();
    try out.appendNTimes(gpa, .{ .raw = 0.0 }, nodes);
    var shortest: ?f64 = null;
    for (peak, rise, cap, 0..) |p, r, c, node| {
        const good = std.math.isFinite(p.raw) and std.math.isFinite(c) and c >= 0.0 and (p.raw == 0.0 or (std.math.isFinite(r) and r > 0.0));
        if (!good) {
            diag.at = @intCast(node);
            return error.NotFinite;
        }
        if (p.raw != 0.0) shortest = if (shortest) |s| @min(s, r) else r;
    }
    const fastest = shortest orelse return;

    const s = scratch;
    const unknowns = try solve.poseInto(gpa, grid, s, diag);
    try solve.assembleGridInto(gpa, grid, s, unknowns);
    const per_rise: f64 = @floatFromInt(steps_per_rise);
    const step_ps = fastest / per_rise;
    // Each unknown's `C/h`, on its diagonal and in its right-hand side, and
    // its pulse's length in steps: exactly `steps_per_rise` for the fastest.
    const decap = try gpa.alloc(f64, unknowns);
    defer gpa.free(decap);
    const span = try gpa.alloc(f64, unknowns);
    defer gpa.free(span);
    const previous = try gpa.alloc(f64, unknowns);
    defer gpa.free(previous);
    @memset(previous, 0.0);
    var pulses_end: f64 = 0.0;
    for (0..unknowns) |u| {
        const node = s.node_of_unknown.items[u];
        const c = ua_per_mv_per_pf_ps * cap[node] / step_ps;
        const slot = s.row_start.items[u];
        s.value.items[slot] += c;
        s.inv_diag.items[u] = 1.0 / s.value.items[slot];
        decap[u] = c;
        span[u] = per_rise * (rise[node] / fastest);
        if (peak[node].raw != 0.0) pulses_end = @max(pulses_end, span[u]);
    }
    try solve.factoriseInto(gpa, s, unknowns);
    const last = @min(@max(stimulus.window_ps / step_ps, pulses_end), @as(f64, std.math.maxInt(u32)));

    s.x.clearRetainingCapacity();
    try s.x.appendNTimes(gpa, 0.0, unknowns);
    try s.rhs.resize(gpa, unknowns);
    var step: u32 = 0;
    while (@as(f64, @floatFromInt(step)) < last) {
        step += 1;
        const at: f64 = @floatFromInt(step);
        for (s.rhs.items, s.x.items, decap, span, s.node_of_unknown.items) |*b, x, c, sp, node| {
            const fraction = at / sp;
            const shape = if (fraction <= 1.0) 1.0 - @abs(2.0 * fraction - 1.0) else 0.0;
            b.* = c * x + peak[node].raw * shape;
        }
        try solve.conjugateGradient(gpa, s, diag);
        var grew = false;
        for (previous, s.x.items, s.node_of_unknown.items) |*before, drop, node| {
            if (!std.math.isFinite(drop)) {
                diag.at = node;
                return error.NotFinite;
            }
            grew = grew or @abs(drop) > @abs(before.*);
            before.* = drop;
            if (@abs(drop) > @abs(out.items[node].raw)) out.items[node] = .{ .raw = drop };
        }
        if (at >= pulses_end and !grew) break;
    }
}
