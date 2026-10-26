//! The substrate grid's lines and each lateral axis's modes. In: an axis's
//! break points (port edges, layer interfaces) and the refinement's first
//! cell and growth ratio. Out: the graded lines, and per lateral axis the
//! generalised eigenpairs `K v = λ D v` of its 1D Neumann stiffness `K` and
//! dual lengths `D`. Ported from crates/extract/src/substrate.rs (`graded`,
//! `distinct`, `tridiagonal_eigen`, `modes`).
//!
//! Contents:
//! - `pub fn gradedInto(gpa: Allocator, breaks: []const f64, h0: f64, ratio: f64, out: *std.ArrayList(f64)) Allocator.Error!void`
//! - `pub fn distinct(v: []f64) []f64`
//! - `pub fn modesInto(gpa: Allocator, lines: []const f64, lambda: *std.ArrayList(f64), u: *std.ArrayList(f64)) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Lines from `breaks` (sorted) into `out` (cleared), each gap filled with
/// cells growing from `h0` at both ends by `ratio`, mirrored about its
/// midpoint and stretched to reach it exactly.
pub fn gradedInto(gpa: Allocator, breaks: []const f64, h0: f64, ratio: f64, out: *std.ArrayList(f64)) Allocator.Error!void {
    assert(breaks.len > 0 and h0 > 0.0 and ratio >= 1.0);
    out.clearRetainingCapacity();
    try out.append(gpa, breaks[0]);
    var steps: std.ArrayList(f64) = .empty;
    defer steps.deinit(gpa);
    for (breaks[0 .. breaks.len - 1], breaks[1..]) |a, b| {
        const half = (b - a) / 2.0;
        steps.clearRetainingCapacity();
        var step = h0;
        var sum: f64 = 0.0;
        while (sum + step <= half) {
            try steps.append(gpa, step);
            sum += step;
            step *= ratio;
        }
        if (steps.items.len == 0) {
            try steps.append(gpa, half);
            sum = half;
        }
        const scale = half / sum;
        var at = a;
        for (steps.items) |s| {
            at += s * scale;
            try out.append(gpa, at);
        }
        out.items[out.items.len - 1] = a + half;
        var k = steps.items.len;
        while (k > 1) {
            k -= 1;
            try out.append(gpa, out.items[out.items.len - 1] + steps.items[k] * scale);
        }
        try out.append(gpa, b);
    }
}

/// `v` sorted (total order) with repeats removed, as a prefix of `v`.
pub fn distinct(v: []f64) []f64 {
    std.mem.sortUnstable(f64, v, {}, totalLess);
    if (v.len == 0) return v;
    var n: usize = 1;
    for (v[1..]) |x| {
        if (x != v[n - 1]) {
            v[n] = x;
            n += 1;
        }
    }
    return v[0..n];
}

/// One axis's grid as modes into `lambda` and `u` (cleared): `(λ, U)` with
/// `U = D^½ W`, `W` orthonormal, so `K = U Λ Uᵀ` and `D = U Uᵀ`;
/// `u[i * n + a]` is line `i`'s entry of mode `a`. False when an eigenvalue
/// takes more than 64 sweeps.
pub fn modesInto(gpa: Allocator, lines: []const f64, lambda: *std.ArrayList(f64), u: *std.ArrayList(f64)) Allocator.Error!bool {
    const n = lines.len;
    assert(n >= 2);
    const gap = try gpa.alloc(f64, n - 1);
    defer gpa.free(gap);
    for (gap, lines[0 .. n - 1], lines[1..]) |*g, lo, hi| g.* = hi - lo;
    const dual = try gpa.alloc(f64, n);
    defer gpa.free(dual);
    for (dual, 0..) |*d, i| d.* = 0.5 * ((if (i > 0) gap[i - 1] else 0.0) + (if (i < n - 1) gap[i] else 0.0));
    try lambda.resize(gpa, n);
    for (lambda.items, dual, 0..) |*diag, d, i| diag.* = ((if (i > 0) 1.0 / gap[i - 1] else 0.0) + (if (i < n - 1) 1.0 / gap[i] else 0.0)) / d;
    const off = try gpa.alloc(f64, n);
    defer gpa.free(off);
    @memset(off, 0.0);
    for (off[0 .. n - 1], 0..) |*e, i| e.* = -1.0 / (gap[i] * @sqrt(dual[i] * dual[i + 1]));
    try u.resize(gpa, n * n);
    if (!tridiagonalEigen(lambda.items, off, u.items)) return false;
    for (dual, 0..) |d, i| {
        const root = @sqrt(d);
        for (u.items[i * n ..][0..n]) |*w| w.* *= root;
    }
    return true;
}

// ---- private ----

fn totalLess(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// The eigenvalues (into `d`) and orthonormal eigenvectors (into `z`,
/// `z[k * n + i]` component `k` of vector `i`) of the symmetric tridiagonal
/// matrix with diagonal `d` and off-diagonal `e` (`e[i]` joining `i` and
/// `i + 1`, `e[n - 1]` zero): implicit QL with shifts (Bowdler, Martin,
/// Reinsch and Wilkinson, Numer. Math. 11, 1968, EISPACK's `tql2`). False
/// when an eigenvalue takes more than 64 sweeps.
fn tridiagonalEigen(d: []f64, e: []f64, z: []f64) bool {
    const n = d.len;
    assert(e.len == n and z.len == n * n);
    @memset(z, 0.0);
    for (0..n) |i| z[i * n + i] = 1.0;
    for (0..n) |l| {
        var sweeps: u32 = 0;
        while (true) {
            var m = l;
            while (m + 1 < n) : (m += 1) {
                const scale = @abs(d[m]) + @abs(d[m + 1]);
                if (@abs(e[m]) <= std.math.floatEps(f64) * scale) break;
            }
            if (m == l) break;
            sweeps += 1;
            if (sweeps > 64) return false;
            var g = (d[l + 1] - d[l]) / (2.0 * e[l]);
            var r = std.math.hypot(g, 1.0);
            g = d[m] - d[l] + e[l] / (g + std.math.copysign(r, g));
            var s: f64 = 1.0;
            var c: f64 = 1.0;
            var p: f64 = 0.0;
            var i = m;
            var deflated = false;
            while (i > l) {
                i -= 1;
                const f = s * e[i];
                const b = c * e[i];
                r = std.math.hypot(f, g);
                e[i + 1] = r;
                if (r == 0.0) {
                    d[i + 1] -= p;
                    e[m] = 0.0;
                    deflated = true;
                    break;
                }
                s = f / r;
                c = g / r;
                g = d[i + 1] - p;
                r = (d[i] - g) * s + 2.0 * c * b;
                p = s * r;
                d[i + 1] = g + p;
                g = c * r - b;
                for (0..n) |k| {
                    const zf = z[k * n + i + 1];
                    z[k * n + i + 1] = s * z[k * n + i] + c * zf;
                    z[k * n + i] = c * z[k * n + i] - s * zf;
                }
            }
            if (deflated) continue;
            d[l] -= p;
            e[l] = g;
            e[m] = 0.0;
        }
    }
    return true;
}

test "an axis's modes diagonalise its stiffness in its dual lengths" {
    // Oracle: law. For any graded axis, `U Uᵀ = D` (the dual lengths, on
    // the diagonal) and `U Λ Uᵀ = K` (the 1D stiffness: `1/Δ` per gap), to
    // round-off; the constant mode has λ = 0 (a Neumann axis).
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(f64) = .empty;
    defer lines.deinit(gpa);
    try gradedInto(gpa, &.{ -4.0, -0.5, 0.5, 4.0 }, 0.25, 1.5, &lines);
    const x = lines.items;
    const n = x.len;
    try std.testing.expect(n > 6);
    for (x[0 .. n - 1], x[1..]) |a, b| try std.testing.expect(b > a);
    var lambda: std.ArrayList(f64) = .empty;
    defer lambda.deinit(gpa);
    var u: std.ArrayList(f64) = .empty;
    defer u.deinit(gpa);
    try std.testing.expect(try modesInto(gpa, x, &lambda, &u));
    var smallest: f64 = std.math.inf(f64);
    for (lambda.items) |l| smallest = @min(smallest, @abs(l));
    try std.testing.expect(smallest < 1e-9);
    for (0..n) |i| {
        for (0..n) |j| {
            var d: f64 = 0.0;
            var k: f64 = 0.0;
            for (0..n) |a| {
                d += u.items[i * n + a] * u.items[j * n + a];
                k += u.items[i * n + a] * lambda.items[a] * u.items[j * n + a];
            }
            const want_d: f64 = if (i != j) 0.0 else 0.5 * ((if (i > 0) x[i] - x[i - 1] else 0.0) + (if (i < n - 1) x[i + 1] - x[i] else 0.0));
            var want_k: f64 = 0.0;
            if (i + 1 == j) want_k = -1.0 / (x[j] - x[i]);
            if (j + 1 == i) want_k = -1.0 / (x[i] - x[j]);
            if (i == j) want_k = (if (i > 0) 1.0 / (x[i] - x[i - 1]) else 0.0) + (if (i < n - 1) 1.0 / (x[i + 1] - x[i]) else 0.0);
            try std.testing.expectApproxEqAbs(want_d, d, 1e-12);
            try std.testing.expectApproxEqAbs(want_k, k, 1e-9);
        }
    }
}
