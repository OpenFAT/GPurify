//! GMRES, its residual, and its refusal to return an approximation. Ported
//! from crates/extract/tests/field/solve.rs.
//!
//! The solver takes its operator as a generic parameter, so a small dense
//! matrix written out here is a legal operator, its exact solution is
//! arithmetic, and the solver is exercised independently of everything it
//! normally multiplies. Nothing here consults an implementation for an
//! answer: either the matrix is small enough to invert on paper, or the
//! right-hand side was formed by applying the operator to a solution chosen
//! first.
//!
//! Contents: test operators `Dense.apply` and `Poisoned.apply`, then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const solve = extract.solve;
const gpa = testing.allocator;

/// A dense operator, row-major: `f64` throughout, allocating nothing in
/// `apply`.
const Dense = struct {
    n: usize,
    a: []f64,

    fn deinit(d: *Dense) void {
        gpa.free(d.a);
    }

    fn of(rows: []const []const f64) !Dense {
        const n = rows.len;
        const a = try gpa.alloc(f64, n * n);
        for (rows, 0..) |row, i| {
            try testing.expectEqual(n, row.len);
            @memcpy(a[i * n ..][0..n], row);
        }
        return .{ .n = n, .a = a };
    }

    /// A strictly diagonally dominant symmetric matrix, nonsingular and well
    /// enough conditioned that a converged answer is meaningful.
    fn randomDominant(rng: *Rng, n: usize) !Dense {
        const a = try gpa.alloc(f64, n * n);
        @memset(a, 0.0);
        for (0..n) |i| {
            for (i + 1..n) |j| {
                const off = rng.unit() * 2.0 - 1.0;
                a[i * n + j] = off;
                a[j * n + i] = off;
            }
        }
        for (0..n) |i| {
            var row: f64 = 0.0;
            for (0..n) |j| {
                if (j != i) row += @abs(a[i * n + j]);
            }
            a[i * n + i] = row + 1.0 + rng.unit();
        }
        return .{ .n = n, .a = a };
    }

    pub fn apply(d: *const Dense, x: []const f64, y: []f64) void {
        std.debug.assert(x.len == d.n and y.len == d.n);
        for (y, 0..) |*out, i| {
            var s: f64 = 0.0;
            for (0..d.n) |j| s += d.a[i * d.n + j] * x[j];
            out.* = s;
        }
    }

    /// `b` such that this operator maps `x` to it: the solution is chosen,
    /// then the right-hand side is derived.
    fn rhsFor(d: *const Dense, x: []const f64) ![]f64 {
        const b = try gpa.alloc(f64, d.n);
        d.apply(x, b);
        return b;
    }
};

const Poisoned = struct {
    pub fn apply(_: Poisoned, _: []const f64, y: []f64) void {
        @memset(y, std.math.nan(f64));
    }
};

const tight: solve.Options = .{ .tolerance = 1e-12, .restart = 40, .max_iterations = 400 };

// ---- private ----

fn randomVector(rng: *Rng, n: usize, scale: f64, shift: f64) ![]f64 {
    const v = try gpa.alloc(f64, n);
    for (v) |*x| x.* = rng.unit() * scale - shift;
    return v;
}

test "the residual of an exact solution is zero and of a zero guess is one" {
    // Oracle: closed form. The true relative residual of the exact solution
    // is zero and of a zero guess is one, because the numerator is then the
    // norm of the right-hand side itself.
    var a = try Dense.of(&.{ &.{ 4, 1 }, &.{ 1, 3 } });
    defer a.deinit();
    const x = [_]f64{ 2, -5 };
    const b = try a.rhsFor(&x);
    defer gpa.free(b);
    var scratch: [2]f64 = undefined;
    try testing.expectApproxEqAbs(@as(f64, 0), solve.residual(&a, b, &x, &scratch), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), solve.residual(&a, b, &.{ 0, 0 }, &scratch), 1e-15);
}

test "the residual is linear in the error it measures" {
    // Oracle: closed form. For a linear operator `A(2x) - b` is `Ax` when `b`
    // is `Ax`, so the residual at twice the solution is exactly one, and at
    // three times it two.
    var rng: Rng = .init(83);
    var a = try Dense.randomDominant(&rng, 6);
    defer a.deinit();
    const x = try randomVector(&rng, 6, 6.0, 3.0);
    defer gpa.free(x);
    const b = try a.rhsFor(x);
    defer gpa.free(b);
    var scratch: [6]f64 = undefined;
    var scaled: [6]f64 = undefined;
    for (&scaled, x) |*s, v| s.* = v * 2.0;
    try testing.expectApproxEqAbs(@as(f64, 1), solve.residual(&a, b, &scaled, &scratch), 1e-12);
    for (&scaled, x) |*s, v| s.* = v * 3.0;
    try testing.expectApproxEqAbs(@as(f64, 2), solve.residual(&a, b, &scaled, &scratch), 1e-12);
}

test "the identity operator solves to the right hand side itself" {
    // Oracle: closed form. The identity maps every vector to itself, so the
    // solution of `I x = b` is `b`.
    var a = try Dense.of(&.{ &.{ 1, 0, 0 }, &.{ 0, 1, 0 }, &.{ 0, 0, 1 } });
    defer a.deinit();
    const b = [_]f64{ 3, -1, 0.5 };
    var x = [_]f64{ 0, 0, 0 };
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    const converged = try solve.gmres(gpa, &a, &b, tight, &x, &ws, &failure);
    for (x, b) |got, want| try testing.expectApproxEqAbs(want, got, 1e-12);
    try testing.expect(converged.residual <= tight.tolerance);
}

test "a diagonal system solves component by component" {
    // Oracle: closed form. A diagonal system decouples completely, so each
    // component is its own right-hand side over its own diagonal entry.
    const diagonal = [_]f64{ 0.5, 2, 8, 100, 0.125, 3 };
    const n = diagonal.len;
    var a: Dense = .{ .n = n, .a = try gpa.alloc(f64, n * n) };
    defer a.deinit();
    @memset(a.a, 0.0);
    for (diagonal, 0..) |d, i| a.a[i * n + i] = d;
    const b = [_]f64{ 1, -4, 16, 50, 0.25, -9 };
    var x: [n]f64 = @splat(0.0);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    _ = try solve.gmres(gpa, &a, &b, tight, &x, &ws, &failure);
    for (x, b, diagonal) |got, rhs, d| try testing.expectApproxEqRel(rhs / d, got, 1e-10);
}

test "gmres recovers a solution the right hand side was built from" {
    // Oracle: construct-from-answer, over generated well-conditioned systems
    // at several sizes: a solver right on one matrix is not right.
    var rng: Rng = .init(89);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    for ([_]usize{ 1, 2, 3, 7, 16, 33 }) |n| {
        var a = try Dense.randomDominant(&rng, n);
        defer a.deinit();
        const expected = try randomVector(&rng, n, 10.0, 5.0);
        defer gpa.free(expected);
        const b = try a.rhsFor(expected);
        defer gpa.free(b);
        const x = try gpa.alloc(f64, n);
        defer gpa.free(x);
        @memset(x, 0.0);
        var failure: solve.Failure = .{};
        const converged = try solve.gmres(gpa, &a, b, tight, x, &ws, &failure);
        for (x, expected) |got, want| try testing.expectApproxEqAbs(want, got, 1e-8);
        try testing.expect(converged.iterations > 0 and converged.iterations <= tight.max_iterations);
    }
}

test "the reported residual is the one residual recomputes" {
    // Oracle: law. The residual a solve reports is the true one, recomputed
    // explicitly, not the recurrence estimate GMRES carries internally, so
    // handing the solution back to `residual` gives the same number.
    var rng: Rng = .init(97);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    for ([_]usize{ 4, 11, 25 }) |n| {
        var a = try Dense.randomDominant(&rng, n);
        defer a.deinit();
        const b = try randomVector(&rng, n, 2.0, 1.0);
        defer gpa.free(b);
        const x = try gpa.alloc(f64, n);
        defer gpa.free(x);
        @memset(x, 0.0);
        const scratch = try gpa.alloc(f64, n);
        defer gpa.free(scratch);
        var failure: solve.Failure = .{};
        const converged = try solve.gmres(gpa, &a, b, tight, x, &ws, &failure);
        try testing.expectApproxEqAbs(solve.residual(&a, b, x, scratch), converged.residual, 1e-14);
    }
}

test "exhausting the iteration budget is an error and not an approximation" {
    // Oracle: law. One iteration against a system with several distinct
    // eigenvalues cannot reach 1e-14: `NotConverged`, carrying the finite
    // residual actually reached, never a quietly returned approximation.
    var a = try Dense.of(&.{ &.{ 7, 1, 0.5, 0.25 }, &.{ 1, 5, -1.5, 0.75 }, &.{ 0.5, -1.5, 9, 2 }, &.{ 0.25, 0.75, 2, 4 } });
    defer a.deinit();
    const b = [_]f64{ 1, -2, 3, -4 };
    const options: solve.Options = .{ .tolerance = 1e-14, .restart = 1, .max_iterations = 1 };
    var x: [4]f64 = @splat(0.0);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    try testing.expectError(error.NotConverged, solve.gmres(gpa, &a, &b, options, &x, &ws, &failure));
    try testing.expectEqual(1, failure.iterations);
    try testing.expect(failure.residual > options.tolerance and std.math.isFinite(failure.residual));
}

test "an operator producing a non finite value fails rather than returning one" {
    // Oracle: law. An operator producing NaN is `NonFinite`, not a NaN
    // propagated into the answer: every comparison against it afterwards is
    // false, including the ones that would have caught it.
    const b = [_]f64{ 1, 1, 1 };
    var x: [3]f64 = @splat(0.0);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    try testing.expectError(error.NonFinite, solve.gmres(gpa, Poisoned{}, &b, tight, &x, &ws, &failure));
}

test "refinement of an operator producing a non finite value fails rather than returning one" {
    // Oracle: law, as above, for `refine`, which the field solve calls for
    // every column. Its true residual on a NaN operator is NaN, which
    // compares false against the tolerance in its loop and its final check,
    // so before C7 it returned the zero guess as converged: a capacitance of
    // zero, reported (testing-plan F9 follow-up, N-c7-1).
    const b = [_]f64{ 1, 1, 1 };
    var x: [3]f64 = @splat(0.0);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    try testing.expectError(error.NonFinite, solve.refine(gpa, Poisoned{}, &b, tight, &x, &ws, &failure));
}

test "refinement reaches the same solution as a bare solve" {
    // Oracle: construct-from-answer. Refinement is used unconditionally, so
    // it must reach the same solution GMRES does on an operator that is
    // already `f64`-exact.
    var rng: Rng = .init(101);
    var a = try Dense.randomDominant(&rng, 12);
    defer a.deinit();
    const expected = try randomVector(&rng, 12, 8.0, 4.0);
    defer gpa.free(expected);
    const b = try a.rhsFor(expected);
    defer gpa.free(b);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    var plain: [12]f64 = @splat(0.0);
    _ = try solve.gmres(gpa, &a, b, tight, &plain, &ws, &failure);
    var refined: [12]f64 = @splat(0.0);
    const converged = try solve.refine(gpa, &a, b, tight, &refined, &ws, &failure);
    for (refined, plain, expected) |r, p, want| {
        try testing.expectApproxEqAbs(want, r, 1e-8);
        try testing.expectApproxEqAbs(p, r, 1e-8);
    }
    try testing.expect(converged.residual <= tight.tolerance);
}

test "solving the same system twice gives bit identical answers" {
    // Oracle: determinism. Two solves of one system from one workspace, with
    // a different system solved in between so the workspace carries other
    // state into the repeat, give the same bits and the same convergence.
    var rng: Rng = .init(103);
    var a = try Dense.randomDominant(&rng, 20);
    defer a.deinit();
    const b = try randomVector(&rng, 20, 2.0, 1.0);
    defer gpa.free(b);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    var failure: solve.Failure = .{};
    var first: [20]f64 = @splat(0.0);
    const first_result = try solve.gmres(gpa, &a, b, tight, &first, &ws, &failure);
    const ones: [20]f64 = @splat(1.0);
    const other = try a.rhsFor(&ones);
    defer gpa.free(other);
    var interference: [20]f64 = @splat(0.0);
    _ = try solve.gmres(gpa, &a, other, tight, &interference, &ws, &failure);
    var second: [20]f64 = @splat(0.0);
    const second_result = try solve.gmres(gpa, &a, b, tight, &second, &ws, &failure);
    try testing.expectEqualSlices(u64, @ptrCast(&first), @ptrCast(&second));
    try testing.expectEqual(first_result, second_result);
}

test "restarting bounds the krylov basis without changing the answer" {
    // Oracle: law. A solve restarted every few iterations reaches the same
    // answer as one that never restarts; a restart that lost the iterate
    // would show here. The iteration count is not asserted: across restart
    // lengths it is not monotone in general.
    var rng: Rng = .init(107);
    var a = try Dense.randomDominant(&rng, 24);
    defer a.deinit();
    const expected = try randomVector(&rng, 24, 4.0, 2.0);
    defer gpa.free(expected);
    const b = try a.rhsFor(expected);
    defer gpa.free(b);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    for ([_]u32{ 3, 8, 24, 100 }) |restart| {
        var x: [24]f64 = @splat(0.0);
        var failure: solve.Failure = .{};
        const converged = try solve.gmres(gpa, &a, b, .{ .tolerance = 1e-11, .restart = restart, .max_iterations = 2_000 }, &x, &ws, &failure);
        for (x, expected) |got, want| try testing.expectApproxEqAbs(want, got, 1e-7);
        try testing.expect(converged.residual <= 1e-11);
    }
}

test "the default solve options are internally coherent" {
    // Oracle: law. A tolerance that is not a positive fraction admits every
    // answer or none, and a budget below one restart cycle makes the restart
    // unreachable.
    const o = solve.Options.default;
    try testing.expect(o.tolerance > 0.0 and o.tolerance < 1.0);
    try testing.expect(o.restart >= 1);
    try testing.expect(o.max_iterations >= o.restart);
}
