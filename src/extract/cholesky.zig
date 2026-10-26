//! Dense Cholesky factorisation and solve, for the symmetric positive
//! definite systems of `compare` (a net's conductance matrix) and `fill` (a
//! floating cluster's capacitance matrix). In: an `m × m` row-major matrix.
//! Out: its lower factor, and solutions through it. Ported from
//! crates/extract/src/cholesky.rs.
//!
//! Every sum is a strict fold in index order, so a result's bits are a
//! function of the matrix alone.
//!
//! Contents:
//! - `pub fn factorInPlace(a: []f64, m: usize) bool`
//! - `pub fn solveInPlace(l: []const f64, m: usize, y: []f64) void`

const std = @import("std");
const assert = std.debug.assert;

/// Overwrites the lower triangle of the symmetric positive definite `a`
/// (`m × m`, row-major) with its Cholesky factor `L`; false at a pivot that is
/// not positive, `a` then partly overwritten. The upper triangle is not read.
pub fn factorInPlace(a: []f64, m: usize) bool {
    assert(a.len == m * m);
    for (0..m) |j| {
        var pivot = a[j * m + j];
        for (0..j) |k| pivot -= a[j * m + k] * a[j * m + k];
        if (!(pivot > 0.0)) return false;
        pivot = @sqrt(pivot);
        a[j * m + j] = pivot;
        for (j + 1..m) |i| {
            var value = a[i * m + j];
            for (0..j) |k| value -= a[i * m + k] * a[j * m + k];
            a[i * m + j] = value / pivot;
        }
    }
    return true;
}

/// Overwrites `y` (holding `b`) with `x`, `L Lᵀ x = b`, `L` from
/// `factorInPlace`.
pub fn solveInPlace(l: []const f64, m: usize, y: []f64) void {
    assert(l.len == m * m and y.len == m);
    for (0..m) |i| {
        for (0..i) |k| y[i] -= l[i * m + k] * y[k];
        y[i] /= l[i * m + i];
    }
    var i = m;
    while (i > 0) {
        i -= 1;
        for (i + 1..m) |k| y[i] -= l[k * m + i] * y[k];
        y[i] /= l[i * m + i];
    }
}

test "a factor reproduces its matrix and solves a system built from its answer" {
    // Oracle: hand-derived and construct-from-answer. `[[4, 2], [2, 5]]` is
    // `L Lᵀ` with `L = [[2, 0], [1, 2]]`, exact; and `x = [1, -2]` gives
    // `b = [0, -8]`, which the solve takes back to `x` exactly.
    var a = [_]f64{ 4, 2, 2, 5 };
    try std.testing.expect(factorInPlace(&a, 2));
    try std.testing.expectEqual(@as(f64, 2), a[0]);
    try std.testing.expectEqual(@as(f64, 1), a[2]);
    try std.testing.expectEqual(@as(f64, 2), a[3]);
    var y = [_]f64{ 0, -8 };
    solveInPlace(&a, 2, &y);
    try std.testing.expectEqual([2]f64{ 1, -2 }, y);
}

test "a matrix that is not positive definite is refused" {
    // Oracle: closed form. `[[1, 2], [2, 1]]` has eigenvalues 3 and -1, so
    // its second pivot `1 - 4 = -3` is negative.
    var a = [_]f64{ 1, 2, 2, 1 };
    try std.testing.expect(!factorInPlace(&a, 2));
}
