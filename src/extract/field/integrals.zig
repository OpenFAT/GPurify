//! Closed-form integrals over a uniformly charged rectangle: its potential,
//! its vertical field, and its Galerkin coefficients with another panel.
//! In: panel geometry (`panel.Ref`). Out: the exact entries the near pairs
//! of the potential and field operators hold. Ported from
//! crates/extract/src/field/{matvec,dielectric}.rs.
//!
//! Device-safe: only `+ - * /`, `@sqrt` and `gompute.math` (one body on
//! every target), so a GPU near-pair build gives the CPU's bits. Rust's libm
//! `asinh`, `atan` and `hypot` are replaced by `asinh` here and Gompute's
//! `atan`, `log`, `log1p`: the same values to an ulp or two, not the same
//! bits.
//!
//! Contents:
//! - `pub fn selfIntegral(a: f64, b: f64) f64`
//! - `pub fn rectanglePotential(point: [3]f64, p: Ref) f64`
//! - `pub fn galerkin(target: Ref, source: Ref, same: bool) f64`
//! - `pub fn verticalField(point: [3]f64, p: Ref) f64`
//! - `pub fn fieldExact(target: Ref, source: Ref, same: bool) f64`
//! - `pub fn asinh(x: f64) f64`, `pub fn hypot(a: f64, b: f64) f64`

const std = @import("std");
const g = @import("gompute");
const Ref = @import("panel.zig").Ref;

/// Gauss–Legendre nodes and weights on `[−1, 1]`, four points: exact for a
/// polynomial of degree 7, and the potential of a near rectangle is smooth
/// over the panel it is averaged on but for a logarithmic edge.
const gauss_x = [4]f64{ -0.861_136_311_594_052_6, -0.339_981_043_584_856_3, 0.339_981_043_584_856_3, 0.861_136_311_594_052_6 };

const gauss_w = [4]f64{ 0.347_854_845_137_453_9, 0.652_145_154_862_546_1, 0.652_145_154_862_546_1, 0.347_854_845_137_453_9 };

/// `∫∫ ∫∫ dA dA' / |r − r'|` over one `a × b` rectangle, twice:
/// `(2/3)(a³ + b³ − d³) + 2a²b asinh(b/a) + 2ab² asinh(a/b)`, `d = √(a² + b²)`.
/// For a unit square, `4 ln(1 + √2) − (4/3)(√2 − 1)`.
pub fn selfIntegral(a: f64, b: f64) f64 {
    const d = hypot(a, b);
    return 2.0 / 3.0 * (a * a * a + b * b * b - d * d * d) +
        2.0 * a * a * b * asinh(b / a) +
        2.0 * a * b * b * asinh(a / b);
}

/// `∫∫ dA / |p − r|` over `p`'s rectangle, at `point`: the potential of a
/// unit surface density, in units of `1/(4πε)`, in metres. With `u`, `v` the
/// panel's coordinates less the point's and `z` the point's height off its
/// plane, the antiderivative of `1/R` is
/// `u asinh(v/√(u² + z²)) + v asinh(u/√(v² + z²)) − z atan(uv/(zR))`,
/// taken between the corners (this form of `u ln(v + R)` has no logarithm
/// of zero on the panel's own edges). At a square's centre it is
/// `4a ln(1 + √2)` for a side `a`.
pub fn rectanglePotential(point: [3]f64, p: Ref) f64 {
    const n: usize = p.normal;
    const u = (n + 1) % 3;
    const v = (n + 2) % 3;
    const z = point[n] - p.centre[n];
    const du = p.centre[u] - point[u];
    const dv = p.centre[v] - point[v];
    const hu = p.half[0];
    const hv = p.half[1];
    return corner(du + hu, dv + hv, z) - corner(du - hu, dv + hv, z) - corner(du + hu, dv - hv, z) + corner(du - hu, dv - hv, z);
}

/// The potential, in units of `1/(4πε)`, of a unit charge spread evenly over
/// `source`, less its image in the substrate, averaged over `target`: 4 × 4
/// Gauss–Legendre points of `rectanglePotential`. When the two are one panel
/// (`same`), its own term is `selfIntegral` instead, and only the image is a
/// quadrature.
pub fn galerkin(target: Ref, source: Ref, same: bool) f64 {
    const n: usize = target.normal;
    const u = (n + 1) % 3;
    const v = (n + 2) % 3;
    var sum: f64 = 0.0;
    for (gauss_x, gauss_w) |a, wa| {
        for (gauss_x, gauss_w) |b, wb| {
            var point = target.centre;
            point[u] += a * target.half[0];
            point[v] += b * target.half[1];
            const image = [3]f64{ point[0], point[1], -point[2] };
            const direct = if (same) 0.0 else rectanglePotential(point, source);
            sum += wa * wb * (direct - rectanglePotential(image, source));
        }
    }
    // The weights sum to 2 on each axis.
    var entry = sum / 4.0 / source.area;
    if (same) {
        const a = 2.0 * source.half[0];
        const b = 2.0 * source.half[1];
        entry += selfIntegral(a, b) / (source.area * source.area);
    }
    return entry;
}

/// `∫∫ (p_z − z') / R³ dA'` over `p`'s rectangle at `point`: the vertical
/// field of a unit surface density, in units of `1/(4πε₀)`. A horizontal
/// panel in the point's own plane gives 0 (outside it the field is in the
/// plane; on it, the principal value).
pub fn verticalField(point: [3]f64, p: Ref) f64 {
    if (p.normal == 2) {
        const w = point[2] - p.centre[2];
        if (w == 0.0) return 0.0;
        const x1 = p.centre[0] - p.half[0] - point[0];
        const x2 = p.centre[0] + p.half[0] - point[0];
        const y1 = p.centre[1] - p.half[1] - point[1];
        const y2 = p.centre[1] + p.half[1] - point[1];
        // The solid-angle antiderivative of w / R³.
        return solid(x2, y2, w) - solid(x1, y2, w) - solid(x2, y1, w) + solid(x1, y1, w);
    }
    // A vertical panel: its horizontal axis and half-widths; the panel's axes
    // are `normal + 1` and `normal + 2` (mod 3), so z is the second for a
    // panel normal to x and the first for one normal to y.
    const n: usize = p.normal;
    const across: usize = if (n == 0) 1 else 0;
    const half_across = if (n == 0) p.half[0] else p.half[1];
    const half_z = if (n == 0) p.half[1] else p.half[0];
    const a = point[n] - p.centre[n];
    const o1 = p.centre[across] - half_across - point[across];
    const o2 = p.centre[across] + half_across - point[across];
    // ∫ (z − z')/R³ dz' = 1/R at the far end less at the near end, then
    // ∫ do / √(b² + o²) = asinh(o / b).
    return endTerm(a, point[2], p.centre[2] + half_z, o1, o2) - endTerm(a, point[2], p.centre[2] - half_z, o1, o2);
}

/// The exact vertical field at `target`'s centroid per unit charge on
/// `source`, less its image's: `(F(source) − F(image)) / A`, in units of
/// `1/(4πε₀)`. With `same`, the source's own direct part is the principal
/// value, 0, and only its image counts.
pub fn fieldExact(target: Ref, source: Ref, same: bool) f64 {
    const direct = if (same) 0.0 else verticalField(target.centre, source);
    var mirrored = source;
    mirrored.centre[2] = -source.centre[2];
    return (direct - verticalField(target.centre, mirrored)) / source.area;
}

/// musl's `asinh` (Zig's `std.math.asinh`) over Gompute's `log` and `log1p`,
/// so it compiles for the GPU.
pub fn asinh(x: f64) f64 {
    const bits: u64 = @bitCast(x);
    const e = (bits >> 52) & 0x7FF;
    var r: f64 = @bitCast(bits & (std.math.maxInt(u64) >> 1));
    if (e >= 0x3FF + 26) {
        r = g.math.log(r) + 0.693147180559945309417232121458176568;
    } else if (e >= 0x3FF + 1) {
        r = g.math.log(2 * r + 1 / (@sqrt(r * r + 1) + r));
    } else if (e >= 0x3FF - 26) {
        r = g.math.log1p(r + r * r / (@sqrt(r * r + 1) + 1));
    }
    return if (bits >> 63 != 0) -r else r;
}

/// `√(a² + b²)`, unscaled: every length here is metres or a ratio of them,
/// far from overflow.
pub fn hypot(a: f64, b: f64) f64 {
    return @sqrt(a * a + b * b);
}

// ---- private ----

fn corner(u: f64, v: f64, z: f64) f64 {
    var sum: f64 = 0.0;
    if (u != 0.0) sum += u * asinh(v / hypot(u, z));
    if (v != 0.0) sum += v * asinh(u / hypot(v, z));
    if (z != 0.0) {
        const r = @sqrt(u * u + v * v + z * z);
        sum -= z * g.math.atan(u * v / (z * r));
    }
    return sum;
}

fn solid(u: f64, v: f64, w: f64) f64 {
    return g.math.atan(u * v / (w * @sqrt(u * u + v * v + w * w)));
}

fn endTerm(a: f64, pz: f64, z_end: f64, o1: f64, o2: f64) f64 {
    const b = @max(hypot(a, pz - z_end), std.math.floatMin(f64));
    return asinh(o2 / b) - asinh(o1 / b);
}

fn plate(normal: u2, centre: [3]f64, half: [2]f64) Ref {
    return .{ .centre = centre, .half = half, .area = 4.0 * half[0] * half[1], .normal = normal };
}

test "a charged rectangle has its closed form potential on its own plane" {
    // Oracle: closed forms. A uniformly charged square of side `a` has the
    // potential `4a ln(1 + √2)` at its centre and half that at a corner (the
    // square is four quarter-squares seen from their shared corner); a
    // rectangle `a × b`, `2 (a asinh(b/a) + b asinh(a/b))` at its centre. A
    // panel normal to x or y gives the same as one normal to z.
    const square = 4.0 * std.math.log1p(@as(f64, @sqrt(2.0)));
    for (0..3) |normal| {
        const p = plate(@intCast(normal), @splat(0.0), .{ 0.5, 0.5 });
        const centre = rectanglePotential(@splat(0.0), p);
        try std.testing.expect(@abs(centre - square) <= 1e-15 * square);
        var at: [3]f64 = @splat(0.0);
        at[(normal + 1) % 3] = 0.5;
        at[(normal + 2) % 3] = -0.5;
        try std.testing.expect(@abs(2.0 * rectanglePotential(at, p) - square) <= 1e-15 * square);
    }
    const a: f64 = 3.0;
    const b: f64 = 1.0;
    const want = 2.0 * (a * std.math.asinh(b / a) + b * std.math.asinh(a / b));
    const got = rectanglePotential(@splat(0.0), plate(2, @splat(0.0), .{ a / 2.0, b / 2.0 }));
    try std.testing.expect(@abs(got - want) <= 1e-14 * want);
}

test "a charged rectangle matches quadrature and its far field" {
    // Oracle: numerical quadrature, and the point-charge limit. Off the
    // plane, the closed form matches a 1000 × 1000 midpoint sum of `1/R` over
    // the panel to 1e-6 (the rule's error at that point is about 1e-7); far
    // away it is the total charge over the distance, to the next multipole's
    // `(a/d)²` share, 1e-4 at a hundred sides off.
    const p = plate(2, @splat(0.0), .{ 0.5, 0.25 });
    const point = [3]f64{ 0.3, -0.1, 0.4 };
    const n = 1000;
    const du = 1.0 / @as(f64, n);
    const dv = 0.5 / @as(f64, n);
    var sum: f64 = 0.0;
    for (0..n) |i| {
        for (0..n) |j| {
            const u = -0.5 + (@as(f64, @floatFromInt(i)) + 0.5) * du;
            const v = -0.25 + (@as(f64, @floatFromInt(j)) + 0.5) * dv;
            const r = @sqrt((point[0] - u) * (point[0] - u) + (point[1] - v) * (point[1] - v) + point[2] * point[2]);
            sum += du * dv / r;
        }
    }
    const exact = rectanglePotential(point, p);
    try std.testing.expect(@abs(exact - sum) <= 1e-6 * sum);
    for ([_][3]f64{ .{ 0, 0, 100 }, .{ 100, 0, 0 }, .{ -60, 80, 0 } }) |far| {
        const monopole = p.area / @sqrt(far[0] * far[0] + far[1] * far[1] + far[2] * far[2]);
        try std.testing.expect(@abs(rectanglePotential(far, p) - monopole) <= 1e-4 * monopole);
    }
}

test "a rectangle with itself has its closed form double integral" {
    // Oracle: a published value and quadrature. The double integral of
    // `1/R` over a unit square is `4 ln(1 + √2) − (4/3)(√2 − 1)`, the mean
    // inverse distance between two points of the square; over a 2 × 1
    // rectangle it is the closed-form potential averaged over the rectangle,
    // here by a 400 × 400 midpoint sum, good to 1e-5.
    const square = 4.0 * std.math.log1p(@as(f64, @sqrt(2.0))) - 4.0 / 3.0 * (@sqrt(2.0) - 1.0);
    try std.testing.expect(@abs(selfIntegral(1.0, 1.0) - square) <= 1e-15 * square);
    const p = plate(2, @splat(0.0), .{ 1.0, 0.5 });
    const n = 400;
    const du = 2.0 / @as(f64, n);
    const dv = 1.0 / @as(f64, n);
    var sum: f64 = 0.0;
    for (0..n) |i| {
        for (0..n) |j| {
            const at = [3]f64{ -1.0 + (@as(f64, @floatFromInt(i)) + 0.5) * du, -0.5 + (@as(f64, @floatFromInt(j)) + 0.5) * dv, 0.0 };
            sum += du * dv * rectanglePotential(at, p);
        }
    }
    try std.testing.expect(@abs(selfIntegral(2.0, 1.0) - sum) <= 1e-5 * sum);
}

test "the vertical field of a rectangle matches quadrature" {
    // Oracle: quadrature and the point-charge limit. Over and beside
    // horizontal and vertical panels, the closed form matches a 400 × 400
    // midpoint sum of `(z − z')/R³` to 1e-5; in the panel's own plane a
    // horizontal panel gives nothing; far away a panel is its charge over
    // the distance squared, times the cosine to the vertical.
    const cases = [_]struct { Ref, [3]f64 }{
        .{ plate(2, .{ 0, 0, 0 }, .{ 0.5, 0.5 }), .{ 0, 0, 0.7 } },
        .{ plate(2, .{ 0.3, -0.2, 0.1 }, .{ 1.0, 0.25 }), .{ 1.9, 0.4, -0.6 } },
        .{ plate(0, .{ 0, 0, 0 }, .{ 0.5, 0.3 }), .{ 0.8, 0.1, 0.9 } },
        .{ plate(1, .{ 0, 0, 0 }, .{ 0.4, 0.6 }), .{ 0.2, -0.7, -0.5 } },
    };
    for (cases) |c| {
        const p = c[0];
        const point = c[1];
        const n = 400;
        const nn: usize = p.normal;
        const u = (nn + 1) % 3;
        const v = (nn + 2) % 3;
        const du = 2.0 * p.half[0] / @as(f64, n);
        const dv = 2.0 * p.half[1] / @as(f64, n);
        var sum: f64 = 0.0;
        for (0..n) |i| {
            for (0..n) |j| {
                var q = p.centre;
                q[u] += -p.half[0] + (@as(f64, @floatFromInt(i)) + 0.5) * du;
                q[v] += -p.half[1] + (@as(f64, @floatFromInt(j)) + 0.5) * dv;
                const d = [3]f64{ point[0] - q[0], point[1] - q[1], point[2] - q[2] };
                const r = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
                sum += du * dv * d[2] / (r * r * r);
            }
        }
        try std.testing.expect(@abs(verticalField(point, p) - sum) <= 1e-5 * @max(@abs(sum), 1e-3));
    }
    const square = plate(2, @splat(0.0), .{ 0.5, 0.5 });
    try std.testing.expect(@abs(verticalField(.{ 3, 0, 0 }, square)) < 1e-15);
    const monopole = square.area * 40.0 / (50.0 * 50.0 * 50.0);
    try std.testing.expect(@abs(verticalField(.{ 0, 30, 40 }, square) - monopole) <= 1e-3 * monopole);
}
