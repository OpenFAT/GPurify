//! Dense P2P Laplace matvec: the panel potential-coefficient matrix times a
//! charge vector, without forming the matrix. In: the mesh's panels and each
//! one's permittivity. Out: `y = P x`, one potential per row. Ported from
//! crates/extract/src/field/matvec.rs. A kernel-owning file: the row body
//! `potentialRow` runs on host threads (`Potential.apply`) and as the device
//! kernel `extract_potential_rows` (`gpu.zig` launches it), so the two agree
//! bit for bit.
//!
//! The substrate is a grounded plane at `z = 0`, by the method of images:
//! each panel's charge `q` at height `z` is paired with `−q` at `−z`, so the
//! potential vanishes on the plane and a conductor's charge is its
//! capacitance to the substrate (Jackson, *Classical Electrodynamics*, 3e,
//! §2.1). Far pairs interact centroid to centroid through a softened
//! distance. A near pair, and each panel with itself, is integrated over
//! both rectangles, the Galerkin coefficient of potential (Ruehli &
//! Brennan, 1973; `integrals.zig`); its exact entry less the dense one is a
//! near-pair correction (`near.zig`). Integrated, a cube's capacitance rises
//! monotonically toward its published value as the panels shrink
//! (testing-plan F77).
//!
//! Contents:
//! - `pub const vacuum_permittivity: f64`, `pub const near_factor: f64`, `pub const gpu_block: u32`
//! - `pub const Potential = struct`, `deinit`,
//!   `init(gpa: Allocator, threads: u16, panels: Panels.Slice, epsilon: []const f64, rows: u32) Allocator.Error!Potential`,
//!   `apply(m: *const Potential, x: []const f64, y: []f64) void`, `cols(m: *const Potential) Cols`
//! - `pub const Cols = struct { n, cx, cy, cz, radius, k, near_start, near_col, near_val }`
//! - `pub fn potentialRow(c: anytype, i: usize, x: anytype) f64`
//! - `pub fn potentialDense(comptime W: comptime_int, c: anytype, i: usize, x: anytype) lanes.Lane(W)`
//! - private `Rule.count`, `Rule.fill`: the near-pair rule interface `near.zig` calls

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const g = @import("gompute");
const panel = @import("panel.zig");
const Ref = panel.Ref;
const Panels = panel.Panels;
const integrals = @import("integrals.zig");
const near_mod = @import("near.zig");
const NearPairs = near_mod.NearPairs;
const row_threads = @import("rows.zig");
const lanes = @import("lanes.zig");
const P = g.GlobalPtr;

/// Vacuum permittivity, F/m. CODATA 2018.
pub const vacuum_permittivity: f64 = 8.854_187_812_8e-12;

/// A pair is near, and integrated over both rectangles, when its centroids
/// are closer than this many times the sum of the two panels' half-diagonals.
/// At 3.05 a 1 µm cube's capacitance rises monotonically under refinement (2
/// to 63 panels a side). The limit is kept off a lattice distance: every
/// squared centroid distance between equal squares of side `a` is a multiple
/// of `a²/4`, and were the limit one, round-off in the absolute centroids
/// would decide the pair (the F46 class). `2 · 3.05² a² = 18.605 a²` is
/// `0.105 a²` from the nearest.
pub const near_factor: f64 = 3.05;

/// Threads per device block of the row kernels.
pub const gpu_block: u32 = 128;

/// The panels as SoA columns, reduced to what the kernel reads, and the near
/// pairs of the rows `apply` writes. Owns its columns.
pub const Potential = struct {
    /// Centroids, metres.
    cx: []f64,
    cy: []f64,
    cz: []f64,
    /// Effective radius `√A / self_potential_shape`: the softening
    /// (`|Δc|² + ρ_i ρ_j`) of the dense far-field kernel, which keeps it
    /// finite on the diagonal; near pairs replace what it gives there.
    radius: []f64,
    /// `1 / (4π ε₀ ε_r)` for the dielectric around each panel.
    k: []f64,
    near: NearPairs,
    threads: u16,

    /// The kernel over `panels`, each in the dielectric `epsilon` gives it
    /// (all 1 for the total-charge formulation of a stratified stack, where
    /// every charge sits in vacuum), and the near pairs of its first `rows`
    /// panels: the rows `apply` writes. O(`rows` · P) distance tests, then a
    /// closed form for each near pair.
    // ponytail: every pair is tested for nearness; a spatial index when the dense product itself is replaced.
    pub fn init(gpa: Allocator, threads: u16, panels: Panels.Slice, epsilon: []const f64, rows: u32) Allocator.Error!Potential {
        const n = panels.len;
        assert(epsilon.len == n and rows <= n and n < std.math.maxInt(u32));
        var m: Potential = .{ .cx = &.{}, .cy = &.{}, .cz = &.{}, .radius = &.{}, .k = &.{}, .near = .empty, .threads = threads };
        errdefer m.deinit(gpa);
        m.cx = try gpa.dupe(f64, panels.items(.cx));
        m.cy = try gpa.dupe(f64, panels.items(.cy));
        m.cz = try gpa.dupe(f64, panels.items(.cz));
        m.radius = try gpa.alloc(f64, n);
        for (m.radius, panels.items(.area)) |*r, area| r.* = @sqrt(area) / self_potential_shape;
        m.k = try gpa.alloc(f64, n);
        for (m.k, epsilon) |*k, eps| k.* = 1.0 / (four_pi_eps0 * eps);
        try m.near.buildInto(gpa, threads, rows, @intCast(n), Rule{ .m = &m, .panels = panels });
        return m;
    }

    pub fn deinit(m: *Potential, gpa: Allocator) void {
        gpa.free(m.cx);
        gpa.free(m.cy);
        gpa.free(m.cz);
        gpa.free(m.radius);
        gpa.free(m.k);
        m.near.deinit(gpa);
    }

    /// The columns the row body reads.
    pub fn cols(m: *const Potential) Cols {
        return .{
            .n = m.cx.len,
            .cx = m.cx.ptr,
            .cy = m.cy.ptr,
            .cz = m.cz.ptr,
            .radius = m.radius.ptr,
            .k = m.k.ptr,
            .near_start = m.near.start.items.ptr,
            .near_col = m.near.column.items.ptr,
            .near_val = m.near.value.items.ptr,
        };
    }

    /// `y := P x` on the host threads, row by row through `potentialRow`.
    /// Writes the first `rows` entries of `y` and reads one entry of `x` per
    /// panel; asserts both long enough, so a short vector never solves a
    /// prefix.
    pub fn apply(m: *const Potential, x: []const f64, y: []f64) void {
        const rows = m.near.rows();
        assert(x.len >= m.cx.len and y.len >= rows);
        const Body = struct {
            c: Cols,
            x: [*]const f64,
            y: [*]f64,
            fn run(b: @This(), lo: u32, hi: u32) void {
                const W = lanes.host_lanes;
                var i: usize = lo;
                while (i + W <= hi) : (i += W) {
                    const dense_rows: [W]f64 = potentialDense(W, b.c, i, b.x);
                    for (dense_rows, i..) |d, row| b.y[row] = near_mod.foldRow(b.c.near_start, b.c.near_col, b.c.near_val, row, b.x, d);
                }
                while (i < hi) : (i += 1) b.y[i] = potentialRow(b.c, i, b.x);
            }
        };
        row_threads.forBlocks(m.threads, rows, @as(u64, rows) * m.cx.len, Body{ .c = m.cols(), .x = x.ptr, .y = y.ptr }, Body.run);
    }
};

/// What `potentialRow` reads: host many-pointers here, the same fields as
/// device pointers in the kernel.
pub const Cols = struct {
    n: usize,
    cx: [*]const f64,
    cy: [*]const f64,
    cz: [*]const f64,
    radius: [*]const f64,
    k: [*]const f64,
    near_start: [*]const u32,
    near_col: [*]const u32,
    near_val: [*]const f64,
};

/// `4πε₀`, the denominator of the free-space Green's function.
const four_pi_eps0: f64 = 4.0 * std.math.pi * vacuum_permittivity;

/// `4 ln(1 + √2)`: `√A` over this is a square panel's effective
/// self-potential radius.
const self_potential_shape: f64 = 3.525_494_348_078_172;

/// The potential operator's near pairs: column `j` of row `i` is near when
/// it is the diagonal or within `near_factor`; its value is `w_ij` times the
/// mean of the two quadratures (panel `j`'s potential averaged over `i` and
/// `i`'s over `j`, equal but for the quadrature's error, so the matrix stays
/// symmetric and the solve reciprocal), less the dense kernel's entry.
const Rule = struct {
    m: *const Potential,
    panels: Panels.Slice,

    pub fn count(r: Rule, i: u32) u32 {
        const a = r.ref(i);
        var n: u32 = 0;
        for (0..r.panels.len) |j| n += @intFromBool(j == i or near_mod.near(a, r.ref(j), near_factor));
        return n;
    }

    pub fn fill(r: Rule, i: u32, column: []u32, value: []f64) void {
        const a = r.ref(i);
        var slot: usize = 0;
        for (0..r.panels.len) |j| {
            const b = r.ref(j);
            if (j != i and !near_mod.near(a, b, near_factor)) continue;
            const ik = r.m.k[i];
            const jk = r.m.k[j];
            const weight = 2.0 * ik * jk / (ik + jk);
            const exact = if (j == i)
                weight * integrals.galerkin(b, b, true)
            else
                weight * 0.5 * (integrals.galerkin(a, b, false) + integrals.galerkin(b, a, false));
            column[slot] = @intCast(j);
            value[slot] = exact - dense(r.m, i, j);
            slot += 1;
        }
        assert(slot == column.len);
    }

    fn ref(r: Rule, j: usize) Ref {
        return .of(r.panels.get(j));
    }
};

/// Row `i` of `P x`: `Σ_j w_ij x_j (1/√(|c_i − c_j|² + ρ_i ρ_j) − 1/√(|c_i − c̄_j|² + ρ_i ρ_j))`,
/// `w_ij = 2 k_i k_j / (k_i + k_j)`, `c̄_j` panel `j`'s image in the plane
/// `z = 0`, then the near pairs' corrections. A strict ascending-j fold with
/// separate multiply and add (Zig's strict float mode never contracts to an
/// FMA), then the corrections in column order: the output bits depend on it.
/// The harmonic mean of `k` is exact in a uniform stack, where every `k` is
/// one value. `c` is a `Cols` or the kernel's device columns.
pub inline fn potentialRow(c: anytype, i: usize, x: anytype) f64 {
    return near_mod.foldRow(c.near_start, c.near_col, c.near_val, i, x, potentialDense(1, c, i, x));
}

/// The dense sums of rows `i..i + W`, lane `k` row `i + k`'s exact
/// sequence of `potentialRow`'s fold (`lanes.zig`): the host's tiles at
/// `W = host_lanes`, the device and the oracle at `W = 1`.
pub inline fn potentialDense(comptime W: comptime_int, c: anytype, i: usize, x: anytype) lanes.Lane(W) {
    const V = lanes.Lane(W);
    const ix = lanes.load(W, c.cx, i);
    const iy = lanes.load(W, c.cy, i);
    const iz = lanes.load(W, c.cz, i);
    const ir = lanes.load(W, c.radius, i);
    const ik = lanes.load(W, c.k, i);
    const two_ik = lanes.splat(W, 2.0) * ik;
    var potential: V = lanes.splat(W, 0.0);
    var j: usize = 0;
    while (j < c.n) : (j += 1) {
        const jz = lanes.splat(W, c.cz[j]);
        const dx = ix - lanes.splat(W, c.cx[j]);
        const dy = iy - lanes.splat(W, c.cy[j]);
        const dz = iz - jz;
        // Panel j's image sits at -cz[j].
        const image_z = iz + jz;
        const plane = dx * dx + dy * dy;
        const soft = ir * lanes.splat(W, c.radius[j]);
        const r2 = plane + dz * dz + soft;
        const image2 = plane + image_z * image_z + soft;
        const jk = lanes.splat(W, c.k[j]);
        const weight = two_ik * jk * lanes.splat(W, x[j]) / (ik + jk);
        potential += weight / @sqrt(r2) - weight / @sqrt(image2);
    }
    return potential;
}

// ---- private ----

/// The dense kernel's entry `P_ij`, as `potentialRow` forms it.
fn dense(m: *const Potential, i: usize, j: usize) f64 {
    const dx = m.cx[i] - m.cx[j];
    const dy = m.cy[i] - m.cy[j];
    const dz = m.cz[i] - m.cz[j];
    const image_z = m.cz[i] + m.cz[j];
    const plane = dx * dx + dy * dy;
    const soft = m.radius[i] * m.radius[j];
    const ik = m.k[i];
    const jk = m.k[j];
    const weight = 2.0 * ik * jk / (ik + jk);
    return weight / @sqrt(plane + dz * dz + soft) - weight / @sqrt(plane + image_z * image_z + soft);
}

fn potentialKernel(n: u64, rows: u64, cx: P(f64), cy: P(f64), cz: P(f64), radius: P(f64), k: P(f64), near_start: P(u32), near_col: P(u32), near_val: P(f64), x: P(f64), y: P(f64)) callconv(g.kernel_callconv) void {
    const i = g.globalIdX(gpu_block);
    if (i >= rows) return;
    const c = .{ .n = n, .cx = cx, .cy = cy, .cz = cz, .radius = radius, .k = k, .near_start = near_start, .near_col = near_col, .near_val = near_val };
    y[i] = potentialRow(c, i, x);
}

comptime {
    if (g.is_device) g.exportRaw("extract_potential_rows", &potentialKernel);
}
