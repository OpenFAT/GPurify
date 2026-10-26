//! The port impedance matrix of a filament network. In: branch filaments
//! (geometry, resistance, node pair) and one port per net. Out: `Z[q][p]`,
//! the voltage across port `q` for a unit current into port `p`, every other
//! port open, from a dense nodal solve `A Zb⁻¹ Aᵀ V = I` of
//! `Zb = R + jωL`. Ported from crates/extract/src/field/henry.rs.
//!
//! `Zb`'s rows are assembled on the host threads (`rows.zig`), each row's
//! partial inductances taken lower filament first, so the matrix is the same
//! for any thread count.
//!
//! Contents:
//! - `pub const Complex = struct { re: f64, im: f64 }` with `zero`, `add`, `sub`, `mul`, `div`, `norm` (num-complex 0.4's arithmetic, operation for operation)
//! - `pub const FilamentSet = struct`, `FilamentSet.empty`, `deinit`, `len(set) usize`,
//!   `push(set, gpa, p1: Vec3, p2: Vec3, w: f64, h: f64, sigma: f64, n1: u32, n2: u32) Allocator.Error!void`,
//!   `pushOhm(set, gpa, p1: Vec3, p2: Vec3, w: f64, h: f64, ohm: f64, n1: u32, n2: u32) Allocator.Error!void`
//! - `pub fn componentsInto(gpa: Allocator, n1: []const u32, n2: []const u32, nodes: u32, out: []u32) Allocator.Error!void`
//! - `pub fn portImpedanceInto(gpa: Allocator, threads: u16, set: *const FilamentSet, nodes: u32, port_a: []const u32, port_b: []const u32, frequency_hz: f64, z: []Complex) (error{Singular} || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const filament = @import("filament.zig");
const Filament = filament.Filament;
const Vec3 = filament.Vec3;
const row_threads = @import("rows.zig");

/// `re + i·im`, with num-complex 0.4's arithmetic operation for operation, so
/// every impedance keeps Rust's bits.
pub const Complex = struct {
    re: f64,
    im: f64,

    pub const zero: Complex = .{ .re = 0, .im = 0 };

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }

    pub fn div(a: Complex, b: Complex) Complex {
        const norm_sqr = b.re * b.re + b.im * b.im;
        return .{ .re = (a.re * b.re + a.im * b.im) / norm_sqr, .im = (a.im * b.re - a.re * b.im) / norm_sqr };
    }

    /// `|z|` through `hypot`, so no square overflows.
    pub fn norm(a: Complex) f64 {
        return std.math.hypot(a.re, a.im);
    }
};

/// Branch filaments, SoA: geometry, DC resistance, and node pair.
pub const FilamentSet = struct {
    fil: std.ArrayList(Filament) = .empty,
    r: std.ArrayList(f64) = .empty,
    n1: std.ArrayList(u32) = .empty,
    n2: std.ArrayList(u32) = .empty,

    pub const empty: FilamentSet = .{};

    pub fn deinit(set: *FilamentSet, gpa: Allocator) void {
        set.fil.deinit(gpa);
        set.r.deinit(gpa);
        set.n1.deinit(gpa);
        set.n2.deinit(gpa);
    }

    pub fn len(set: *const FilamentSet) usize {
        return set.fil.items.len;
    }

    /// A conductor piece of conductivity `sigma`: `R = length / (σ w h)`.
    pub fn push(set: *FilamentSet, gpa: Allocator, p1: Vec3, p2: Vec3, w: f64, h: f64, sigma: f64, n1: u32, n2: u32) Allocator.Error!void {
        const length = filament.norm(p2 - p1);
        try set.pushOhm(gpa, p1, p2, w, h, length / (sigma * (w * h)), n1, n2);
    }

    /// A piece whose resistance is stated, not derived: a via cut.
    pub fn pushOhm(set: *FilamentSet, gpa: Allocator, p1: Vec3, p2: Vec3, w: f64, h: f64, ohm: f64, n1: u32, n2: u32) Allocator.Error!void {
        // Normalized twice, as the width frame always was: the bits depend on it.
        const wdir = filament.defaultWdir(filament.normalized(filament.normalized(p2 - p1)));
        try set.fil.append(gpa, .{ .a = p1, .b = p2, .w = w, .t = h, .wdir = wdir });
        try set.r.append(gpa, ohm);
        try set.n1.append(gpa, n1);
        try set.n2.append(gpa, n2);
    }
};

/// Component id per node into `out` (union-find over the branches
/// `n1[b]–n2[b]`), numbered in ascending order of each component's first
/// node.
pub fn componentsInto(gpa: Allocator, n1: []const u32, n2: []const u32, nodes: u32, out: []u32) Allocator.Error!void {
    assert(out.len == nodes and n1.len == n2.len);
    const parent = try gpa.alloc(u32, nodes);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (n1, n2) |a, b| {
        const ra = find(parent, a);
        const rb = find(parent, b);
        if (ra != rb) parent[ra] = rb;
    }
    const label = try gpa.alloc(u32, nodes);
    defer gpa.free(label);
    @memset(label, std.math.maxInt(u32));
    var next: u32 = 0;
    for (out, 0..) |*c, node| {
        const r = find(parent, @intCast(node));
        if (label[r] == std.math.maxInt(u32)) {
            label[r] = next;
            next += 1;
        }
        c.* = label[r];
    }
}

/// The port impedance matrix at `frequency_hz` into `z` (`ports × ports`,
/// row-major), ports `port_a[p] → port_b[p]`: `z[q][p]` is the voltage across
/// port `q` for a unit current into port `p`, every other port open. One
/// ground node per galvanically connected component: a port's negative
/// terminal, else the component's lowest node. `Singular` when either
/// factorisation meets an exactly zero pivot column. O(B²) filament-pair
/// integrals and an O(B³) complex factorisation for B branches, then an
/// O(N³) one for N nodes.
pub fn portImpedanceInto(gpa: Allocator, threads: u16, set: *const FilamentSet, nodes: u32, port_a: []const u32, port_b: []const u32, frequency_hz: f64, z: []Complex) (error{Singular} || Allocator.Error)!void {
    const nb = set.len();
    const ports = port_a.len;
    assert(port_b.len == ports and z.len == ports * ports);
    const comp = try gpa.alloc(u32, nodes);
    defer gpa.free(comp);
    try componentsInto(gpa, set.n1.items, set.n2.items, nodes, comp);
    var ncomp: u32 = 0;
    for (comp) |c| ncomp = @max(ncomp, c + 1);
    const ground_of_comp = try gpa.alloc(u32, @max(ncomp, 1));
    defer gpa.free(ground_of_comp);
    @memset(ground_of_comp, std.math.maxInt(u32));
    for (port_b) |c| {
        if (ground_of_comp[comp[c]] == std.math.maxInt(u32)) ground_of_comp[comp[c]] = c;
    }
    for (comp, 0..) |c, node| {
        if (ground_of_comp[c] == std.math.maxInt(u32)) ground_of_comp[c] = @intCast(node);
    }
    const is_ground = try gpa.alloc(bool, nodes);
    defer gpa.free(is_ground);
    @memset(is_ground, false);
    for (ground_of_comp) |gnd| {
        if (gnd != std.math.maxInt(u32)) is_ground[gnd] = true;
    }
    const red_of = try gpa.alloc(u32, nodes);
    defer gpa.free(red_of);
    var nred: u32 = 0;
    for (red_of, is_ground) |*r, gnd| {
        r.* = if (gnd) std.math.maxInt(u32) else nred;
        if (!gnd) nred += 1;
    }

    // Zb = R (diagonal) + jωL: the upper triangle by rows on the threads,
    // then mirrored.
    // ponytail: host threads only. A GPU Zb wants the pairs binned by formula
    // (brick, centreline, quadrature) first so warps don't diverge
    // (ARCHITECTURE.md, GPU), and the O(B³) LU after it dominates anyway.
    const w = 2.0 * std.math.pi * frequency_hz;
    const zb = try gpa.alloc(Complex, nb * nb);
    defer gpa.free(zb);
    const Rows = struct {
        set: *const FilamentSet,
        zb: []Complex,
        w: f64,
        fn run(c: @This(), lo: u32, hi: u32) void {
            const n = c.set.len();
            const fils = c.set.fil.items;
            for (lo..hi) |i| {
                const row = c.zb[i * n ..][0..n];
                row[i] = Complex.add(.{ .re = 0, .im = c.w * filament.selfInductance(fils[i]) }, .{ .re = c.set.r.items[i], .im = 0 });
                for (i + 1..n) |j| row[j] = .{ .re = 0, .im = c.w * filament.mutual(fils[i], fils[j]) };
            }
        }
    };
    row_threads.forBlocks(threads, @intCast(nb), @as(u64, nb) * nb * 64, Rows{ .set = set, .zb = zb, .w = w }, Rows.run);
    for (0..nb) |i| {
        for (0..i) |j| zb[i * nb + j] = zb[j * nb + i];
    }
    const piv = try gpa.alloc(u32, nb);
    defer gpa.free(piv);
    if (!luFactor(threads, zb, nb, piv)) return error.Singular;

    // X[:, n] = Zb⁻¹ (Aᵀ column n) for every non-ground node, then the
    // reduced nodal admittance Yn = A X, scattered per branch.
    const yn = try gpa.alloc(Complex, @as(usize, nred) * nred);
    defer gpa.free(yn);
    @memset(yn, Complex.zero);
    const rhs = try gpa.alloc(Complex, nb);
    defer gpa.free(rhs);
    const xc = try gpa.alloc(Complex, nb);
    defer gpa.free(xc);
    // ponytail: one LU solve per node, serial; Rust ran them on rayon. Threads with per-thread scratch when nets grow large.
    for (0..nodes) |node| {
        if (is_ground[node]) continue;
        @memset(rhs, Complex.zero);
        for (set.n1.items, set.n2.items, rhs) |b1, b2, *r| {
            if (b1 == node) r.* = r.add(.{ .re = 1, .im = 0 });
            if (b2 == node) r.* = r.sub(.{ .re = 1, .im = 0 });
        }
        luSolve(zb, nb, piv, rhs, xc);
        const rn = red_of[node];
        for (set.n1.items, set.n2.items, xc) |b1, b2, x| {
            if (!is_ground[b1]) yn[red_of[b1] * nred + rn] = yn[red_of[b1] * nred + rn].add(x);
            if (!is_ground[b2]) yn[red_of[b2] * nred + rn] = yn[red_of[b2] * nred + rn].sub(x);
        }
    }
    const ypiv = try gpa.alloc(u32, nred);
    defer gpa.free(ypiv);
    if (!luFactor(threads, yn, nred, ypiv)) return error.Singular;

    // Unit current into each port p; the voltage across every port q is Z[q][p].
    const inject = try gpa.alloc(Complex, nred);
    defer gpa.free(inject);
    const v = try gpa.alloc(Complex, nred);
    defer gpa.free(v);
    for (port_a, port_b, 0..) |a, c, p| {
        @memset(inject, Complex.zero);
        if (!is_ground[a]) inject[red_of[a]] = inject[red_of[a]].add(.{ .re = 1, .im = 0 });
        if (!is_ground[c]) inject[red_of[c]] = inject[red_of[c]].sub(.{ .re = 1, .im = 0 });
        luSolve(yn, nred, ypiv, inject, v);
        for (port_a, port_b, 0..) |aq, cq, q| {
            const va = if (is_ground[aq]) Complex.zero else v[red_of[aq]];
            const vc = if (is_ground[cq]) Complex.zero else v[red_of[cq]];
            z[q * ports + p] = va.sub(vc);
        }
    }
}

// ---- private ----

fn find(parent: []u32, x: u32) u32 {
    var r = x;
    while (parent[r] != r) r = parent[r];
    var c = x;
    while (parent[c] != r) {
        const next = parent[c];
        parent[c] = r;
        c = next;
    }
    return r;
}

/// Dense complex LU with partial pivoting (PA = LU) in place, row-major
/// `n × n`, `piv` the row order; false when a pivot column is exactly zero.
/// The rows under a pivot update independently, on the host threads when
/// the trailing block is large, bit-identical to serial.
fn luFactor(threads: u16, lu: []Complex, n: usize, piv: []u32) bool {
    for (piv, 0..) |*p, i| p.* = @intCast(i);
    for (0..n) |k| {
        var p = k;
        var max = lu[k * n + k].norm();
        for (k + 1..n) |i| {
            const m = lu[i * n + k].norm();
            if (m > max) {
                max = m;
                p = i;
            }
        }
        if (max == 0.0) return false;
        if (p != k) {
            for (0..n) |j| std.mem.swap(Complex, &lu[k * n + j], &lu[p * n + j]);
            std.mem.swap(u32, &piv[k], &piv[p]);
        }
        const Update = struct {
            lu: []Complex,
            n: usize,
            k: usize,
            fn run(c: @This(), lo: u32, hi: u32) void {
                const pivot = c.lu[c.k * c.n + c.k];
                const pivot_row = c.lu[c.k * c.n ..][0..c.n];
                for (lo..hi) |r| {
                    const row = c.lu[(c.k + 1 + r) * c.n ..][0..c.n];
                    const factor = row[c.k].div(pivot);
                    row[c.k] = factor;
                    for (c.k + 1..c.n) |j| row[j] = row[j].sub(factor.mul(pivot_row[j]));
                }
            }
        };
        const below: u32 = @intCast(n - k - 1);
        row_threads.forBlocks(threads, below, @as(u64, below) * (n - k), Update{ .lu = lu, .n = n, .k = k }, Update.run);
    }
    return true;
}

/// `x` with `L U x = P b`, from `luFactor`'s output.
fn luSolve(factors: []const Complex, n: usize, piv: []const u32, b: []const Complex, x: []Complex) void {
    for (x, piv) |*xi, p| xi.* = b[p];
    for (0..n) |i| {
        var sum = x[i];
        for (0..i) |j| sum = sum.sub(factors[i * n + j].mul(x[j]));
        x[i] = sum;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var sum = x[i];
        for (i + 1..n) |j| sum = sum.sub(factors[i * n + j].mul(x[j]));
        x[i] = sum.div(factors[i * n + i]);
    }
}
