//! Partial-inductance integrals for straight rectangular current filaments.
//! In: two filaments (centre line, cross-section and its frame). Out: their
//! mutual partial inductance, or one's self inductance, in henries. Ported
//! from crates/extract/src/field/filament.rs.
//!
//! `M = (µ₀/4π)(û₁·û₂) ∬ ds dt / |r₁(s) − r₂(t)|`: exact Hoer–Love brick for
//! close parallel pairs, centreline closed form for far parallel pairs,
//! Gauss–Legendre cubature otherwise; Grover/Rosa closed form for self terms.
//!
//! Contents:
//! - `pub const Vec3 = @Vector(3, f64)`, `pub fn dot(a: Vec3, b: Vec3) f64`, `pub fn cross(a: Vec3, b: Vec3) Vec3`,
//!   `pub fn norm(a: Vec3) f64`, `pub fn normalized(a: Vec3) Vec3`
//! - `pub const Filament = struct { a: Vec3, b: Vec3, w: f64, t: f64, wdir: Vec3 }`, `Filament.init(a, b, w, t) Filament`,
//!   `length(f) f64`, `dir(f) Vec3`
//! - `pub fn defaultWdir(axis: Vec3) Vec3`
//! - `pub fn mutual(f1: Filament, f2: Filament) f64`
//! - `pub fn mutualParallel(f1: Filament, f2: Filament) f64`
//! - `pub fn mutualQuadrature(f1: Filament, f2: Filament) f64`
//! - `pub fn mutualBrick(fj: Filament, fm: Filament) ?f64`
//! - `pub fn selfInductanceBar(l: f64, w: f64, t: f64) f64`
//! - `pub fn selfInductance(f: Filament) f64`

const std = @import("std");

/// A 3-D point or vector, metres: `x` and `y` the layout plane, `z` height.
pub const Vec3 = @Vector(3, f64);

/// A straight current filament of finite rectangular cross-section; current
/// flows from `a` to `b`, uniform over the cross-section, which is what
/// partial inductance assumes. `wdir` must be a unit vector perpendicular to
/// `b − a`; it is not checked, and a skewed frame makes the exact brick
/// formula fall back to the centre-line one.
pub const Filament = struct {
    a: Vec3,
    b: Vec3,
    /// Cross-section width along `wdir`, metres.
    w: f64,
    /// Cross-section thickness, perpendicular to both the axis and `wdir`.
    t: f64,
    wdir: Vec3,

    /// The filament from `a` to `b` with the canonical width direction:
    /// horizontal for any axis not near vertical, so `t` is the vertical size
    /// of a wire in the layout plane.
    pub fn init(a: Vec3, b: Vec3, w: f64, t: f64) Filament {
        return .{ .a = a, .b = b, .w = w, .t = t, .wdir = defaultWdir(normalized(b - a)) };
    }

    pub fn length(f: Filament) f64 {
        return norm(f.b - f.a);
    }

    /// The unit axis from `a` to `b`, or zero for a zero-length filament.
    pub fn dir(f: Filament) Vec3 {
        return normalized(f.b - f.a);
    }
};

/// µ₀/4π with the classical µ₀ = 4π×10⁻⁷, as the Grover/Rosa formulas assume.
const mu0_over_4pi: f64 = 1e-7;

/// Gauss–Legendre nodes and weights on [-1, 1], n = 8.
const gl8_x = [8]f64{ -0.960_289_856_497_536_2, -0.796_666_477_413_626_7, -0.525_532_409_916_329, -0.183_434_642_495_649_8, 0.183_434_642_495_649_8, 0.525_532_409_916_329, 0.796_666_477_413_626_7, 0.960_289_856_497_536_2 };

const gl8_w = [8]f64{ 0.101_228_536_290_376_3, 0.222_381_034_453_374_5, 0.313_706_645_877_887_3, 0.362_683_783_378_362, 0.362_683_783_378_362, 0.313_706_645_877_887_3, 0.222_381_034_453_374_5, 0.101_228_536_290_376_3 };

/// joelself.c EPS: relative magnitude below which a coordinate is treated as
/// zero inside `evalEq` (guards the log/atan singular terms).
const brick_eps: f64 = 1e-13;

/// joelself.c `DEG_TOL`: cross-section dimension / length ratio below which
/// the filament is degenerate and the brick formula is skipped.
const deg_tol: f64 = 1.1e-4;

/// x, y, z summed in that order.
pub fn dot(a: Vec3, b: Vec3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// The right-handed cross product `a × b`.
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn norm(a: Vec3) f64 {
    return @sqrt(dot(a, a));
}

/// Unit vector; zero for a zero-length input.
pub fn normalized(a: Vec3) Vec3 {
    const n = norm(a);
    if (n == 0.0) return @splat(0.0);
    return a / @as(Vec3, @splat(n));
}

/// Canonical width direction ⊥ `axis`.
pub fn defaultWdir(axis: Vec3) Vec3 {
    const helper: Vec3 = if (@abs(axis[2]) < 0.99) .{ 0, 0, 1 } else .{ 1, 0, 0 };
    return normalized(cross(helper, axis));
}

/// Exact brick–brick (Hoer–Love) for close parallel filaments where the
/// finite cross-section matters, centreline closed form for parallel
/// filaments that are far (or degenerate), quadrature otherwise.
pub fn mutual(f1: Filament, f2: Filament) f64 {
    const c = @abs(dot(f1.dir(), f2.dir()));
    if (!(c > 1.0 - 1e-9)) return mutualQuadrature(f1, f2);
    // The centreline formula errs by O((w/ρ)²), so switch to the exact brick
    // formula when close.
    const axis = f1.dir();
    const dv = f2.a - f1.a;
    const rho = norm(dv - axis * @as(Vec3, @splat(dot(dv, axis))));
    const scale = @max(@max(f1.w, f1.t), @max(f2.w, f2.t));
    if (rho < 10.0 * scale) {
        if (mutualBrick(f1, f2)) |m| return m;
    }
    return mutualParallel(f1, f2);
}

/// Mutual partial inductance between two parallel filaments, from the
/// Neumann double integral in closed form along their common axis.
pub fn mutualParallel(f1: Filament, f2: Filament) f64 {
    const dir1 = f1.dir();
    const sign = std.math.sign(dot(dir1, f2.dir()));
    const x2 = dot(f1.b - f1.a, dir1);
    const y1 = dot(f2.a - f1.a, dir1);
    const y2 = dot(f2.b - f1.a, dir1);
    // Perpendicular separation: distance between the two infinite lines.
    const d = f2.a - f1.a;
    const perp = d - dir1 * @as(Vec3, @splat(dot(d, dir1)));
    return mutualParallelReduced(norm(perp), 0.0, x2, @min(y1, y2), @max(y1, y2), sign);
}

/// Gauss–Legendre cubature of the Neumann double integral, any orientation:
/// accurate for non-touching pairs.
pub fn mutualQuadrature(f1: Filament, f2: Filament) f64 {
    const dir1 = f1.dir();
    const dir2 = f2.dir();
    const half1 = f1.length() * 0.5;
    const half2 = f2.length() * 0.5;
    var acc: f64 = 0.0;
    for (gl8_x, gl8_w) |xi, wi| {
        const p1 = f1.a + dir1 * @as(Vec3, @splat((xi + 1.0) * half1));
        for (gl8_x, gl8_w) |xj, wj| {
            const p2 = f2.a + dir2 * @as(Vec3, @splat((xj + 1.0) * half2));
            const r = norm(p1 - p2);
            if (r > 0.0) acc += wi * wj / r;
        }
    }
    // Jacobians half1, half2 from the [-1,1] -> [0,l] maps.
    return mu0_over_4pi * dot(dir1, dir2) * acc * half1 * half2;
}

/// Exact mutual partial inductance between two parallel rectangular bricks
/// with aligned (or 90°-rotated) cross-section frames (Hoer & Love 1965,
/// FastHenry joelself.c). Null outside the formula's domain: non-parallel
/// axes, skewed cross-sections, degenerate tape or line cross-sections,
/// where the centreline formulas are the correct limits.
pub fn mutualBrick(fj: Filament, fm: Filament) ?f64 {
    const zj = fj.dir();
    if (@abs(dot(zj, fm.dir())) < 1.0 - 1e-9) return null;
    const xj = fj.wdir;
    const yj = normalized(cross(zj, xj));
    // m's cross-section relative to j's frame: aligned or perpendicular only.
    const wm_along_x = @abs(dot(fm.wdir, xj));
    const whperp = if (wm_along_x > 1.0 - 1e-6) false else if (wm_along_x < 1e-6) true else return null;
    const a = fj.w;
    const b = fj.t;
    const c = if (whperp) fm.w else fm.t;
    const d = if (whperp) fm.t else fm.w;
    const l1 = fj.length();
    const l2 = fm.length();
    if (a / @max(l1, b) < deg_tol or b / @max(l1, a) < deg_tol or c / @max(l2, d) < deg_tol or d / @max(l2, c) < deg_tol) return null;
    // Corner-origin offsets (joelself.c's numerically fixed form: subtract
    // the big endpoints first, then add the small corner vector).
    const vo = xj * @as(Vec3, @splat(a * 0.5)) + yj * @as(Vec3, @splat(b * 0.5));
    const end = (fm.a - fj.a) + vo;
    const e = dot(xj, end) - d * 0.5;
    const p = dot(yj, end) - c * 0.5;
    var l3 = dot(zj, end);
    const l3_1 = dot(zj, (fm.b - fj.a) + vo);
    var sign: f64 = 1.0;
    if (l3 > l3_1) {
        sign = -1.0; // m runs antiparallel to j
        l3 = l3_1;
    }
    const total = brickToBrick(e, a, d, p, b, c, l3, l1, l2) / (a * b * c * d);
    return sign * mu0_over_4pi * total;
}

/// Self partial inductance, in henries, of a straight rectangular bar of
/// length `l`, width `w`, thickness `t`, metres — the Grover/Rosa closed form
/// `L = (µ₀/2π) l [ln(2l/(w+t)) + 1/2 + 0.2235 (w+t)/l]`. Valid for
/// `l ≳ w + t`, to a fraction of a percent at wire-like aspect ratios. A
/// zero `l` or `w + t` gives a non-finite result.
pub fn selfInductanceBar(l: f64, w: f64, t: f64) f64 {
    const wt = w + t;
    return 2.0 * mu0_over_4pi * l * (@log(2.0 * l / wt) + 0.5 + 0.223_5 * wt / l);
}

pub fn selfInductance(f: Filament) f64 {
    return selfInductanceBar(f.length(), f.w, f.t);
}

// ---- private ----

/// `P(u) = u·asinh(u/ρ) − √(u²+ρ²)`, the parallel closed form's antiderivative.
fn parallelPrimitive(u: f64, rho: f64) f64 {
    return u * std.math.asinh(u / rho) - @sqrt(u * u + rho * rho);
}

/// The parallel closed form on the reduced geometry: separation `rho`, axial
/// ends `x1..x2` and `y1..y2`, `sign` û₁·û₂.
fn mutualParallelReduced(rho_in: f64, x1: f64, x2: f64, y1: f64, y2: f64, sign: f64) f64 {
    // Floor rho against the log singularity of exactly collinear filaments.
    const rho = @max(rho_in, 1e-30);
    const integral = parallelPrimitive(y2 - x1, rho) - parallelPrimitive(y2 - x2, rho) - parallelPrimitive(y1 - x1, rho) + parallelPrimitive(y1 - x2, rho);
    return sign * mu0_over_4pi * integral;
}

fn logTerm(x: f64, ysq: f64, zsq: f64, len: f64) f64 {
    return ((6.0 * zsq - ysq) * ysq - zsq * zsq) * x * @log((x + len) / @sqrt(ysq + zsq));
}

fn tanTerm(x: f64, y: f64, z: f64, zsq: f64, len: f64) f64 {
    return x * y * z * zsq * std.math.atan(x * y / (z * len));
}

/// joelself.c `eval_eq`: the Hoer–Love primitive at one corner combination.
fn evalEq(x: f64, y: f64, z: f64, ref_len: f64) f64 {
    const one_over_ref = 1.0 / @max(ref_len, @abs(x) + @abs(y) + @abs(z));
    const one_over_ref_sq = one_over_ref * one_over_ref;
    const xsq = x * x;
    const ysq = y * y;
    const zsq = z * z;
    const len = @sqrt(xsq + ysq + zsq);
    var ret = (1.0 / 60.0) * len * (xsq * (xsq - 3.0 * ysq) + ysq * (ysq - 3.0 * zsq) + zsq * (zsq - 3.0 * xsq));
    const near_zero = @as(u32, @intFromBool(@abs(x * one_over_ref) < brick_eps)) + @intFromBool(@abs(y * one_over_ref) < brick_eps) + @intFromBool(@abs(z * one_over_ref) < brick_eps);
    const near_zero_sq = @as(u32, @intFromBool(@abs(xsq * one_over_ref_sq) < brick_eps)) + @intFromBool(@abs(ysq * one_over_ref_sq) < brick_eps) + @intFromBool(@abs(zsq * one_over_ref_sq) < brick_eps);
    if (near_zero_sq < 2) ret += (1.0 / 24.0) * (logTerm(x, ysq, zsq, len) + logTerm(y, xsq, zsq, len) + logTerm(z, xsq, ysq, len));
    if (near_zero < 1) ret -= (1.0 / 6.0) * (tanTerm(x, y, z, zsq, len) + tanTerm(x, z, y, ysq, len) + tanTerm(z, y, x, xsq, len));
    return ret;
}

/// joelself.c `brick_to_brick`: the 4×4×4 corner-combination sum.
fn brickToBrick(e: f64, a: f64, d: f64, p: f64, b: f64, c: f64, l3: f64, l1: f64, l2: f64) f64 {
    const q = [4]f64{ e - a, e + d - a, e + d, e };
    const r = [4]f64{ p - b, p + c - b, p + c, p };
    const s = [4]f64{ l3 - l1, l3 + l2 - l1, l3 + l2, l3 };
    var total: f64 = 0.0;
    for (q, 0..) |qi, i| {
        for (r, 0..) |rj, j| {
            for (s, 0..) |sk, k| {
                const sign: f64 = if ((i + j + k) % 2 == 0) 1.0 else -1.0;
                total += sign * evalEq(qi, rj, sk, a);
            }
        }
    }
    return total;
}

/// A thin filament: a 1e-9 cross-section is degenerate (`deg_tol`), so these
/// exercise the centreline paths; the brick tests use fat sections.
fn fil(a: Vec3, b: Vec3) Filament {
    return .init(a, b, 1e-9, 1e-9);
}

fn offset(wd: Vec3, hd: Vec3, i: usize, j: usize, nsub: f64, w: f64, t: f64) Vec3 {
    const fi: f64 = @floatFromInt(i);
    const fj: f64 = @floatFromInt(j);
    return wd * @as(Vec3, @splat(((fi + 0.5) / nsub - 0.5) * w)) + hd * @as(Vec3, @splat(((fj + 0.5) / nsub - 0.5) * t));
}

test "collinear touching matches closed form" {
    // Oracle: closed form, the mutual inductance of two touching collinear
    // filaments, M = (µ₀/4π)[(l+m)ln(l+m) − l·ln l − m·ln m], to 1e-9.
    const l = 1e-3;
    const m = 2e-3;
    const got = mutual(fil(.{ 0, 0, 0 }, .{ l, 0, 0 }), fil(.{ l, 0, 0 }, .{ l + m, 0, 0 }));
    const exact = mu0_over_4pi * ((l + m) * @log(l + m) - l * @log(l) - m * @log(m));
    try std.testing.expect(@abs((got - exact) / exact) < 1e-9);
}

test "perpendicular mutual is zero" {
    // Oracle: closed form. The Neumann integral carries the factor `dir1 . dir2`,
    // which is exactly 0 for perpendicular filaments.
    try std.testing.expectEqual(@as(f64, 0.0), mutual(fil(.{ 0, 0, 0 }, .{ 1e-3, 0, 0 }), fil(.{ 2e-3, 1e-4, 0 }, .{ 2e-3, 1.1e-3, 0 })));
}

test "touching elbow quadrature accuracy" {
    // Oracle: differential against a 16 x 16 subdivision of the pair, which
    // converges on the singular corner, to 2 %.
    const l = 1e-3;
    const c = std.math.sqrt1_2;
    const f1 = fil(.{ -l, 0, 0 }, .{ 0, 0, 0 });
    const f2 = fil(.{ 0, 0, 0 }, .{ l * c, l * c, 0 });
    const nsub = 16;
    var refv: f64 = 0.0;
    const d1 = f1.b - f1.a;
    const d2 = f2.b - f2.a;
    for (0..nsub) |i| {
        const fi: f64 = @floatFromInt(i);
        const a1 = f1.a + d1 * @as(Vec3, @splat(fi / nsub));
        const b1 = f1.a + d1 * @as(Vec3, @splat((fi + 1) / nsub));
        for (0..nsub) |j| {
            const fj: f64 = @floatFromInt(j);
            const a2 = f2.a + d2 * @as(Vec3, @splat(fj / nsub));
            const b2 = f2.a + d2 * @as(Vec3, @splat((fj + 1) / nsub));
            refv += mutualQuadrature(.init(a1, b1, f1.w, f1.t), .init(a2, b2, f2.w, f2.t));
        }
    }
    try std.testing.expect(@abs((mutual(f1, f2) - refv) / refv) < 0.02);
}

test "brick matches centerline when far" {
    // Oracle: law: at a separation 250 times the width the cross-section no
    // longer matters, so the brick formula equals the centreline formula to
    // 1e-5.
    const f1 = Filament.init(.{ 0, 0, 0 }, .{ 1e-3, 0, 0 }, 2e-5, 1e-5);
    const f2 = Filament.init(.{ 0, 5e-3, 0 }, .{ 1e-3, 5e-3, 0 }, 2e-5, 1e-5);
    const brick = mutualBrick(f1, f2).?;
    const line = mutualParallel(f1, f2);
    try std.testing.expect(@abs((brick - line) / line) < 1e-5);
}

test "brick matches cross section subdivision" {
    // Oracle: differential against the uniform-current definition of M: the
    // average of centreline mutuals over a 16 x 16 subdivision of each
    // cross-section, to 0.2 %; and the centreline formula alone is worse.
    const w = 2e-5;
    const t = 1e-5;
    const f1 = Filament.init(.{ 0, 0, 0 }, .{ 1e-3, 0, 0 }, w, t);
    const wd = f1.wdir;
    const hd = normalized(cross(f1.dir(), wd));
    // Side-by-side touching: centre-to-centre = w along the width direction.
    const shift = wd * @as(Vec3, @splat(w));
    const f2: Filament = .{ .a = f1.a + shift, .b = f1.b + shift, .w = w, .t = t, .wdir = wd };
    const nsub = 16;
    var refv: f64 = 0.0;
    for (0..nsub) |i1_| for (0..nsub) |j1_| {
        const o1 = offset(wd, hd, i1_, j1_, nsub, w, t);
        for (0..nsub) |i2_| for (0..nsub) |j2_| {
            const o2 = offset(wd, hd, i2_, j2_, nsub, w, t);
            refv += mutualParallel(.init(f1.a + o1, f1.b + o1, 1e-12, 1e-12), .init(f2.a + o2, f2.b + o2, 1e-12, 1e-12));
        };
    };
    refv /= nsub * nsub * nsub * nsub;
    const brick = mutualBrick(f1, f2).?;
    const line = mutualParallel(f1, f2);
    try std.testing.expect(@abs((brick - refv) / refv) < 2e-3);
    try std.testing.expect(@abs(brick - refv) < @abs(line - refv));
}

test "a 100 µm wire is about 0.11 nH" {
    // Oracle: the Rust doc example: a 100 µm wire, 1 µm wide and 0.5 µm
    // thick, reads 1.08e-10 H to 1e-12.
    try std.testing.expect(@abs(selfInductanceBar(100e-6, 1e-6, 0.5e-6) - 1.08e-10) < 0.01e-10);
}
