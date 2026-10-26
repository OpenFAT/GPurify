//! Restarted GMRES with an outer residual-refinement loop. Host `f64`.
//! In: an operator writing `y = A x`, a right-hand side, options. Out: the
//! solution in the caller's `x`, and the explicitly recomputed residual.
//! Ported from crates/extract/src/field/solve.rs.
//!
//! Every reduction is a strict ascending fold (`geom.linalg`); the iteration
//! trajectory, and so the low bits of every capacitance, depend on it.
//! GMRES is Saad & Schultz (1986). The operator is any value with
//! `apply(op, x: []const f64, y: []f64) void` for vectors of one length; it
//! need not be symmetric.
//!
//! Contents:
//! - `pub const Options = struct { tolerance: f64, restart: u32, max_iterations: u32 }`, `Options.default`
//! - `pub const Error = error{ NotConverged, Breakdown, NonFinite } || Allocator.Error`
//! - `pub const Failure = struct { residual: f64, iterations: u32 }`
//! - `pub const Converged = struct { residual: f64, iterations: u32, restarts: u32 }`
//! - `pub const Workspace = struct`, `Workspace.empty`, `deinit`
//! - `pub fn gmres(gpa: Allocator, op: anytype, b: []const f64, options: Options, x: []f64, ws: *Workspace, failure: *Failure) Error!Converged`
//! - `pub fn refine(gpa: Allocator, op: anytype, b: []const f64, options: Options, x: []f64, ws: *Workspace, failure: *Failure) Error!Converged`
//! - `pub fn residual(op: anytype, b: []const f64, x: []const f64, scratch: []f64) f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const linalg = geom.linalg;

/// Convergence target and iteration budgets for `gmres` and `refine`.
pub const Options = struct {
    /// Relative residual to reach; a worse answer is an error.
    tolerance: f64,
    /// Iterations before restarting; bounds the Krylov basis.
    restart: u32,
    /// Total budget across restarts; exhausting it is `error.NotConverged`.
    max_iterations: u32,

    /// What the field solve uses for every column.
    pub const default: Options = .{ .tolerance = 1e-10, .restart = 50, .max_iterations = 1_000 };
};

/// Why a solve produced no answer. Every member is a refusal: no
/// capacitance is reported from a solve that did not reach its tolerance.
/// `Failure` carries the values.
pub const Error = error{
    /// The explicit relative residual stayed above the tolerance: the
    /// iteration budget ran out, or a refinement pass stopped reducing it.
    NotConverged,
    /// The Krylov basis met a direction the operator maps to zero, so the
    /// least-squares step is singular.
    Breakdown,
    /// The operator produced a NaN or infinity.
    NonFinite,
} || Allocator.Error;

/// What a failed solve reached: the explicit residual (`NotConverged` only)
/// and the iterations spent.
pub const Failure = struct {
    residual: f64 = 0,
    iterations: u32 = 0,
};

/// What a converged solve achieved.
pub const Converged = struct {
    /// True relative residual, recomputed explicitly.
    residual: f64,
    /// Krylov iterations, one operator application each; the explicit
    /// residual checks are not counted, and a `refine` pass counts at least
    /// one.
    iterations: u32,
    /// Restarts for `gmres`; refinement passes for `refine`.
    restarts: u32,
};

/// Krylov basis, Hessenberg, Givens and residual buffers, reused across
/// columns. Only an allocation cache: its contents mean nothing between
/// calls, and each call resizes it to the problem at hand.
pub const Workspace = struct {
    krylov: std.ArrayList(f64) = .empty,
    hessenberg: std.ArrayList(f64) = .empty,
    givens_c: std.ArrayList(f64) = .empty,
    givens_s: std.ArrayList(f64) = .empty,
    residual: std.ArrayList(f64) = .empty,
    correction: std.ArrayList(f64) = .empty,
    /// `refine`'s own: its right-hand side, explicit residual and step.
    rhs: std.ArrayList(f64) = .empty,
    scratch: std.ArrayList(f64) = .empty,
    step: std.ArrayList(f64) = .empty,

    pub const empty: Workspace = .{};

    pub fn deinit(ws: *Workspace, gpa: Allocator) void {
        inline for (@typeInfo(Workspace).@"struct".field_names) |name| @field(ws, name).deinit(gpa);
    }
};

/// Solves `A x = b` from the caller's `x`, which holds the answer on return;
/// asserts `x` as long as `b`. Returns the explicitly recomputed residual,
/// not the GMRES recurrence estimate: relative to `‖b‖`, or absolute when `b`
/// is zero. On an error `x` keeps the progress of every completed cycle and
/// `failure` what was reached. One operator application per iteration, plus
/// O(n · restart) per iteration for the orthogonalisation.
pub fn gmres(gpa: Allocator, op: anytype, b: []const f64, options: Options, x: []f64, ws: *Workspace, failure: *Failure) Error!Converged {
    assert(x.len == b.len);
    const n = b.len;
    // Basis no larger than the space; `max(1)` so `restart == 0` still progresses.
    const m = @max(@min(@as(usize, options.restart), n), 1);
    const b_scale = scaleOf(linalg.nrm2(b));

    try resizeZeroed(gpa, &ws.krylov, (m + 1) * n);
    try resizeZeroed(gpa, &ws.hessenberg, (m + 1) * (m + 1));
    try resizeZeroed(gpa, &ws.givens_c, m);
    try resizeZeroed(gpa, &ws.givens_s, m);
    try resizeZeroed(gpa, &ws.correction, n);
    try resizeZeroed(gpa, &ws.residual, n);
    const krylov = ws.krylov.items;
    const h = ws.hessenberg.items;
    const w = ws.correction.items;

    // `h`: `m` columns of `m+1` rows (column `k` at `k*(m+1)`), then the
    // rotated right-hand side `g` at `g0`, overwritten by `y` in back
    // substitution.
    const g0 = m * (m + 1);
    var iterations: u32 = 0;
    var cycles: u32 = 0;
    while (true) {
        // Leaves `b − A x` in `ws.residual`: this cycle's `r0`.
        const rel = residual(op, b, x, ws.residual.items);
        if (!std.math.isFinite(rel)) return fail(failure, error.NonFinite, 0, iterations);
        if (rel <= options.tolerance) return .{ .residual = rel, .iterations = iterations, .restarts = cycles -| 1 };
        if (iterations >= options.max_iterations) return fail(failure, error.NotConverged, rel, iterations);
        cycles += 1;

        const beta = linalg.nrm2(ws.residual.items);
        const inv_beta = 1.0 / beta;
        for (krylov[0..n], ws.residual.items) |*v, r| v.* = r * inv_beta;
        @memset(h[g0 .. g0 + m + 1], 0.0);
        h[g0] = beta;

        var k: usize = 0;
        while (k < m and iterations < options.max_iterations) {
            iterations += 1;
            op.apply(krylov[k * n ..][0..n], w);
            // One finiteness check per matvec, before anything reaches `x`.
            if (!std.math.isFinite(linalg.dot(w, w))) return fail(failure, error.NonFinite, 0, iterations);

            // Modified Gram-Schmidt. `w + (−h)·v` is `w − h·v` to the bit:
            // negation is exact.
            const col = k * (m + 1);
            for (0..k + 1) |i| {
                const basis = krylov[i * n ..][0..n];
                const hi = linalg.dot(basis, w);
                h[col + i] = hi;
                for (w, basis) |*wj, vj| wj.* = -hi * vj + wj.*;
            }
            const hk1 = linalg.nrm2(w);
            h[col + k + 1] = hk1;

            // Replay earlier rotations, then annihilate the subdiagonal.
            for (0..k) |i| {
                const c = ws.givens_c.items[i];
                const s = ws.givens_s.items[i];
                const upper = h[col + i];
                const lower = h[col + i + 1];
                h[col + i] = c * upper + s * lower;
                h[col + i + 1] = c * lower - s * upper;
            }
            const hk = h[col + k];
            const rot = std.math.hypot(hk, hk1);
            // A vanished column: identity rotation, reported as `Breakdown` below.
            const c: f64 = if (rot == 0.0) 1.0 else hk / rot;
            const s: f64 = if (rot == 0.0) 0.0 else hk1 / rot;
            ws.givens_c.items[k] = c;
            ws.givens_s.items[k] = s;
            h[col + k] = c * hk + s * hk1;
            h[col + k + 1] = 0.0;
            const gk = h[g0 + k];
            h[g0 + k] = c * gk;
            h[g0 + k + 1] = -s * gk;
            k += 1;

            // Early exit on the recurrence estimate; the explicit residual decides.
            if (@abs(h[g0 + k]) / b_scale <= options.tolerance) break;
            // Happy breakdown (also catches NaN).
            if (!(hk1 > 0.0)) break;
            const inv = 1.0 / hk1;
            for (krylov[k * n ..][0..n], w) |*v, wj| v.* = wj * inv;
        }

        // Back-substitute `R y = g` in place.
        var i = k;
        while (i > 0) {
            i -= 1;
            var acc = h[g0 + i];
            for (i + 1..k) |j| acc -= h[j * (m + 1) + i] * h[g0 + j];
            const diagonal = h[i * (m + 1) + i];
            if (diagonal == 0.0) return fail(failure, error.Breakdown, 0, iterations);
            h[g0 + i] = acc / diagonal;
        }
        // `x += Σ y_i v_i`, ascending `i`.
        for (0..k) |j| {
            const yj = h[g0 + j];
            for (x, krylov[j * n ..][0..n]) |*xv, v| xv.* = yj * v + xv.*;
        }
    }
}

/// GMRES inside an outer loop that recomputes the true residual after each
/// single-cycle correction solve:
///
/// ```text
/// r ← b − A x
/// while ‖r‖/‖b‖ > tolerance:  solve A d = r (one Krylov cycle); x ← x + d; r ← b − A x
/// ```
///
/// Stops early when a pass fails to reduce the residual. A pass whose inner
/// GMRES did not converge still applies its correction, since recomputing
/// the true residual is what decides. `Breakdown` and `NonFinite` from an
/// inner solve end the refinement at once; a true residual that is not
/// finite is `NonFinite`, never converged. Asserts `x` as long as `b`.
pub fn refine(gpa: Allocator, op: anytype, b: []const f64, options: Options, x: []f64, ws: *Workspace, failure: *Failure) Error!Converged {
    assert(x.len == b.len);
    const n = b.len;
    try resizeZeroed(gpa, &ws.rhs, n);
    try resizeZeroed(gpa, &ws.scratch, n);
    try resizeZeroed(gpa, &ws.step, n);

    var achieved = residual(op, b, x, ws.scratch.items);
    var iterations: u32 = 0;
    var restarts: u32 = 0;
    while (achieved > options.tolerance and iterations < options.max_iterations) {
        // `scratch` already holds `b − A x`: the correction's right-hand side.
        std.mem.swap(std.ArrayList(f64), &ws.rhs, &ws.scratch);
        @memset(ws.step.items, 0.0);
        const inner: Options = .{
            .tolerance = options.tolerance,
            .restart = options.restart,
            // One Krylov cycle; the outer pass is the restart.
            .max_iterations = @min(options.restart, options.max_iterations - iterations),
        };
        // An unconverged correction is still a correction; only breakdown is fatal.
        var inner_failure: Failure = .{};
        const spent = if (gmres(gpa, op, ws.rhs.items, inner, ws.step.items, ws, &inner_failure)) |step|
            step.iterations
        else |err| switch (err) {
            error.NotConverged => inner_failure.iterations,
            error.Breakdown, error.NonFinite, error.OutOfMemory => |fatal| {
                failure.* = inner_failure;
                return fatal;
            },
        };
        iterations +|= @max(spent, 1);
        restarts +|= 1;
        for (x, ws.step.items) |*value, delta| value.* += delta;

        const next = residual(op, b, x, ws.scratch.items);
        if (next >= achieved) {
            achieved = next;
            break;
        }
        achieved = next;
    }
    // A NaN residual compares false against the tolerance, so it is caught
    // here and never read as converged.
    if (!std.math.isFinite(achieved)) return fail(failure, error.NonFinite, 0, iterations);
    if (achieved > options.tolerance) return fail(failure, error.NotConverged, achieved, iterations);
    return .{ .residual = achieved, .iterations = iterations, .restarts = restarts };
}

/// True relative residual `‖b − Ax‖ / ‖b‖`, absolute when `b` is zero; leaves
/// `b − A x` in `scratch`. Asserts all three of one length.
pub fn residual(op: anytype, b: []const f64, x: []const f64, scratch: []f64) f64 {
    assert(b.len == x.len and b.len == scratch.len);
    op.apply(x, scratch);
    for (scratch, b) |*ax, bi| ax.* = bi - ax.*;
    return linalg.nrm2(scratch) / scaleOf(linalg.nrm2(b));
}

// ---- private ----

/// Denominator of a relative residual: `‖b‖`, or 1 for `b = 0`.
fn scaleOf(norm_b: f64) f64 {
    return if (norm_b == 0.0) 1.0 else norm_b;
}

fn resizeZeroed(gpa: Allocator, list: *std.ArrayList(f64), n: usize) Allocator.Error!void {
    try list.resize(gpa, n);
    @memset(list.items, 0.0);
}

fn fail(failure: *Failure, err: Error, reached: f64, iterations: u32) Error {
    failure.* = .{ .residual = reached, .iterations = iterations };
    return err;
}
