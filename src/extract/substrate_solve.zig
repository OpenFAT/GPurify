//! The substrate solve: a layered silicon's port admittance matrix. In: the
//! profile (layers top-down, the backside), the die's extent and every port
//! edge, and which port covers each top-face grid node. Out: `Y`, the
//! current into each port with one port at 1 V and the rest (and a grounded
//! backside) at 0 V. Ported from crates/extract/src/substrate.rs
//! (`admittance`).
//!
//! Laplace's equation `∇·(σ∇V) = 0` on a tensor-product grid by box
//! integration: every cell contributes to each of its twelve edges `σ ·
//! (face area / 4) / (edge length)`, a resistor network (Verghese,
//! Schmerbeck and Allstot, Kluwer 1995) on a graded grid. Lines lie on every
//! port edge and layer interface; between them the cells grow from `h₀` by
//! `r`: refinement `k` takes `h₀ = shortest gap / 4^(k+1)` and `r = 1 +
//! 2^-(k+1)` (Rust's docs said `2^(k+1)`; its code, kept here, is
//! `4^(k+1)`). With `σ` a function of depth
//! alone the operator separates: in the modes of the two lateral axes each
//! mode `(a, b)` is a tridiagonal system in depth whose elimination to the
//! top face is one number `s_ab`, so the top face's operator is `S = (Ux⊗Uy)
//! diag(s) (Ux⊗Uy)ᵀ` exactly. Jacobi-preconditioned conjugate gradients solve
//! `S` on the free top-face nodes, each port held at 1 V in turn.
//!
//! Contents:
//! - `pub const Backside = enum { grounded, floating }`, `pub const Profile = struct { layers: []const [2]f64, backside: Backside }`
//! - `pub const Lines = struct`, `Lines.empty`, `deinit`
//! - `pub const Admittance = struct`, `Admittance.empty`, `deinit`, `at`, `toBackside`, `between`
//! - `pub const Error = error{ TooLarge, NoConvergence } || Allocator.Error`, `pub const Refusal = struct { lines: usize }`
//! - `pub const max_lines: usize`, `pub const no_port: u32`
//! - `pub fn linesInto(gpa: Allocator, profile: Profile, domain: [4]f64, xs: []const f64, ys: []const f64, level: u32, out: *Lines, refusal: *Refusal) Error!void`
//! - `pub fn admittanceInto(gpa: Allocator, threads: u16, profile: Profile, lines: *const Lines, held: []const u32, ports: u32, out: *Admittance) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const modes = @import("substrate_modes.zig");
const rows = @import("field/rows.zig");

pub const Backside = enum { grounded, floating };

/// A layered substrate: each layer's `(thickness µm, resistivity Ω·µm)`,
/// top-down, both positive; and its backside, a grounded contact or one
/// that carries no current.
pub const Profile = struct { layers: []const [2]f64, backside: Backside };

/// A solve's grid lines, µm: the two lateral axes and depth from the top.
pub const Lines = struct {
    x: std.ArrayList(f64) = .empty,
    y: std.ArrayList(f64) = .empty,
    z: std.ArrayList(f64) = .empty,

    pub const empty: Lines = .{};

    pub fn deinit(l: *Lines, gpa: Allocator) void {
        l.x.deinit(gpa);
        l.y.deinit(gpa);
        l.z.deinit(gpa);
    }
};

/// A solve's port admittance matrix: `y[p * ports + q]`, the current (A)
/// into the silicon at port `p` with port `q` at 1 V and every other port
/// (and a grounded backside) at 0 V; `nodes`, the grid's node count.
pub const Admittance = struct {
    ports: u32 = 0,
    y: std.ArrayList(f64) = .empty,
    nodes: usize = 0,

    pub const empty: Admittance = .{};

    pub fn deinit(a: *Admittance, gpa: Allocator) void {
        a.y.deinit(gpa);
    }

    /// `Y[p][q]`, siemens.
    pub fn at(a: *const Admittance, p: usize, q: usize) f64 {
        return a.y.items[p * a.ports + q];
    }

    /// The conductance from port `p` to the backside, siemens: the row sum,
    /// symmetrised with the column's.
    pub fn toBackside(a: *const Admittance, p: usize) f64 {
        var sum: f64 = 0.0;
        for (0..a.ports) |q| sum += 0.5 * (a.at(p, q) + a.at(q, p));
        return sum;
    }

    /// The conductance between ports `p` and `q`, siemens, symmetrised.
    pub fn between(a: *const Admittance, p: usize, q: usize) f64 {
        return -0.5 * (a.at(p, q) + a.at(q, p));
    }
};

pub const Error = error{
    /// A lateral axis would hold more than `max_lines` lines; `Refusal.lines`
    /// is how many.
    TooLarge,
    /// An axis's modes, or conjugate gradients, did not converge.
    NoConvergence,
} || Allocator.Error;

pub const Refusal = struct { lines: usize = 0 };

/// The most lines on one lateral axis: the axis's modes are dense, `n²`
/// values found in `O(n³)`, which bounds a design's ports to some hundreds.
pub const max_lines: usize = 1500;

/// A top-face node no port covers, in `held`.
pub const no_port: u32 = std.math.maxInt(u32);

/// `S` on the top face: `out = (Ux⊗Uy) diag(s) (Ux⊗Uy)ᵀ v`, `v[i * ny + j]`.
/// Each stage writes disjoint rows, each row's sums folded in index order,
/// so any thread count gives the same bits.
// ponytail: dense mode transforms on host threads, O(nx·ny·(nx+ny)) per apply; GPU row kernels (one body for host and device, as field/rows.zig and field/gpu.zig run the BEM rows) when a profile shows substrate solves dominate.
const Operator = struct {
    nx: usize,
    ny: usize,
    ux: []const f64,
    uy: []const f64,
    s: []const f64,
    work: []f64,
    threads: u16,

    fn apply(op: *Operator, v: []const f64, out: []f64) void {
        const cost: u64 = @intCast(op.nx * op.ny * @max(op.nx, op.ny));
        const rows_x: u32 = @intCast(op.nx);
        // work = Uxᵀ v; out = (work Uy) ∘ s; work = Ux out; out = work Uyᵀ.
        rows.forBlocks(op.threads, rows_x, cost, Stage{ .op = op, .in = v, .out = op.work }, Stage.transposeX);
        rows.forBlocks(op.threads, rows_x, cost, Stage{ .op = op, .in = op.work, .out = out }, Stage.alongYScaled);
        rows.forBlocks(op.threads, rows_x, cost, Stage{ .op = op, .in = out, .out = op.work }, Stage.backX);
        rows.forBlocks(op.threads, rows_x, cost, Stage{ .op = op, .in = op.work, .out = out }, Stage.backY);
    }

    /// `S`'s diagonal, `Σ_ab s_ab Ux[i,a]² Uy[j,b]²`, through `T[a, j] =
    /// Σ_b s_ab Uy[j,b]²` (the same folds as summing per `(i, j)`).
    fn diagonal(op: *const Operator, arena: Allocator) Allocator.Error![]f64 {
        const nx = op.nx;
        const ny = op.ny;
        const t = try arena.alloc(f64, nx * ny);
        for (0..nx) |a| {
            for (0..ny) |j| {
                var sum: f64 = 0.0;
                for (0..ny) |b| sum += op.s[a * ny + b] * (op.uy[j * ny + b] * op.uy[j * ny + b]);
                t[a * ny + j] = sum;
            }
        }
        const out = try arena.alloc(f64, nx * ny);
        for (0..nx) |i| {
            for (0..ny) |j| {
                var sum: f64 = 0.0;
                for (0..nx) |a| sum += (op.ux[i * nx + a] * op.ux[i * nx + a]) * t[a * ny + j];
                out[i * ny + j] = sum;
            }
        }
        return out;
    }
};

/// One transform stage over rows `lo..hi` of its output.
const Stage = struct {
    op: *const Operator,
    in: []const f64,
    out: []f64,

    /// `out[a, :] = Σ_i Ux[i, a] in[i, :]`.
    fn transposeX(st: Stage, lo: u32, hi: u32) void {
        const nx = st.op.nx;
        const ny = st.op.ny;
        for (lo..hi) |a| {
            const row = st.out[a * ny ..][0..ny];
            @memset(row, 0.0);
            for (0..nx) |i| axpy(row, st.op.ux[i * nx + a], st.in[i * ny ..][0..ny]);
        }
    }

    /// `out[a, :] = (Σ_j in[a, j] Uy[j, :]) ∘ s[a, :]`.
    fn alongYScaled(st: Stage, lo: u32, hi: u32) void {
        const ny = st.op.ny;
        for (lo..hi) |a| {
            const row = st.out[a * ny ..][0..ny];
            @memset(row, 0.0);
            for (0..ny) |j| axpy(row, st.in[a * ny + j], st.op.uy[j * ny ..][0..ny]);
            for (row, st.op.s[a * ny ..][0..ny]) |*o, w| o.* *= w;
        }
    }

    /// `out[i, :] = Σ_a Ux[i, a] in[a, :]`.
    fn backX(st: Stage, lo: u32, hi: u32) void {
        const nx = st.op.nx;
        const ny = st.op.ny;
        for (lo..hi) |i| {
            const row = st.out[i * ny ..][0..ny];
            @memset(row, 0.0);
            for (0..nx) |a| axpy(row, st.op.ux[i * nx + a], st.in[a * ny ..][0..ny]);
        }
    }

    /// `out[i, j] = Σ_b in[i, b] Uy[j, b]`.
    fn backY(st: Stage, lo: u32, hi: u32) void {
        const ny = st.op.ny;
        for (lo..hi) |i| {
            const row = st.in[i * ny ..][0..ny];
            for (0..ny) |j| st.out[i * ny + j] = dot(row, st.op.uy[j * ny ..][0..ny]);
        }
    }
};

/// The grid under `domain` (`[x0, y0, x1, y1]`, µm) at refinement `level`
/// into `out`: lines on the domain's edges, every port edge in `xs` and `ys`
/// inside it, every layer interface, graded between. Errors: `TooLarge`.
pub fn linesInto(gpa: Allocator, profile: Profile, domain: [4]f64, xs: []const f64, ys: []const f64, level: u32, out: *Lines, refusal: *Refusal) Error!void {
    var xb: std.ArrayList(f64) = .empty;
    defer xb.deinit(gpa);
    var yb: std.ArrayList(f64) = .empty;
    defer yb.deinit(gpa);
    for ([2]*std.ArrayList(f64){ &xb, &yb }, [2][]const f64{ xs, ys }, [2][2]f64{ .{ domain[0], domain[2] }, .{ domain[1], domain[3] } }) |b, cuts, span| {
        try b.appendSlice(gpa, &span);
        for (cuts) |v| if (v > span[0] and v < span[1]) try b.append(gpa, v);
        b.shrinkRetainingCapacity(modes.distinct(b.items).len);
    }
    var zb: std.ArrayList(f64) = .empty;
    defer zb.deinit(gpa);
    try zb.append(gpa, 0.0);
    for (profile.layers) |layer| try zb.append(gpa, zb.items[zb.items.len - 1] + layer[0]);
    var shortest = std.math.inf(f64);
    for ([2][]const f64{ xb.items, yb.items }) |b| {
        for (b[0 .. b.len - 1], b[1..]) |lo, hi| shortest = @min(shortest, hi - lo);
    }
    const halving: f64 = @floatFromInt(@as(u32, 1) << @intCast(@min(level, 14)));
    const h0 = shortest / (4.0 * halving * halving);
    const ratio = 1.0 + 0.5 / halving;
    try modes.gradedInto(gpa, xb.items, h0, ratio, &out.x);
    try modes.gradedInto(gpa, yb.items, h0, ratio, &out.y);
    try modes.gradedInto(gpa, zb.items, h0, ratio, &out.z);
    const most = @max(out.x.items.len, out.y.items.len);
    if (most > max_lines) {
        refusal.lines = most;
        return error.TooLarge;
    }
}

/// Solves the grid `lines` for `ports` ports into `out`. `held[i * ny + j]`
/// is the port covering top-face node `(x[i], y[j])`, `no_port` for none.
/// The mode transforms run on up to `threads` threads, row by row, so the
/// result is the same for any thread count. Errors: `NoConvergence`.
pub fn admittanceInto(gpa: Allocator, threads: u16, profile: Profile, lines: *const Lines, held: []const u32, ports: u32, out: *Admittance) Error!void {
    const x = lines.x.items;
    const y = lines.y.items;
    const z = lines.z.items;
    const nx = x.len;
    const ny = y.len;
    const n = nx * ny;
    assert(held.len == n and profile.layers.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lx: std.ArrayList(f64) = .empty;
    var ux: std.ArrayList(f64) = .empty;
    var ly: std.ArrayList(f64) = .empty;
    var uy: std.ArrayList(f64) = .empty;
    if (!try modes.modesInto(arena, x, &lx, &ux) or !try modes.modesInto(arena, y, &ly, &uy)) return error.NoConvergence;
    const s = try depthEliminated(arena, profile, z, lx.items, ly.items);
    var op: Operator = .{ .nx = nx, .ny = ny, .ux = ux.items, .uy = uy.items, .s = s, .work = try arena.alloc(f64, n), .threads = threads };
    const diag = try op.diagonal(arena);
    const v = try arena.alloc(f64, n);
    const r = try arena.alloc(f64, n);
    const zv = try arena.alloc(f64, n);
    const p = try arena.alloc(f64, n);
    const ap = try arena.alloc(f64, n);
    try out.y.resize(gpa, @as(usize, ports) * ports);
    @memset(out.y.items, 0.0);
    out.ports = ports;
    out.nodes = n * z.len;
    for (0..ports) |driven| {
        // The held nodes at their voltages; r = −S v on the free ones.
        for (v, held) |*value, h| value.* = @floatFromInt(@intFromBool(h == driven));
        op.apply(v, r);
        for (r) |*value| value.* = -value.*;
        free(held, r);
        const norm_b = @sqrt(dot(r, r));
        if (norm_b > 0.0) {
            for (zv, r, diag) |*zk, rk, dk| zk.* = rk / dk;
            free(held, zv);
            @memcpy(p, zv);
            var rz = dot(r, zv);
            var converged = false;
            for (0..10 * @max(n, 100)) |_| {
                op.apply(p, ap);
                free(held, ap);
                const alpha = rz / dot(p, ap);
                for (v, r, p, ap) |*vk, *rk, pk, apk| {
                    vk.* += alpha * pk;
                    rk.* -= alpha * apk;
                }
                if (@sqrt(dot(r, r)) <= 1e-12 * norm_b) {
                    converged = true;
                    break;
                }
                for (zv, r, diag) |*zk, rk, dk| zk.* = rk / dk;
                free(held, zv);
                const next = dot(r, zv);
                const beta = next / rz;
                rz = next;
                for (p, zv) |*pk, zk| pk.* = zk + beta * pk.*;
            }
            if (!converged) return error.NoConvergence;
        }
        // The current into the silicon at each port's nodes.
        op.apply(v, ap);
        for (held, ap) |h, current| {
            if (h != no_port) out.y.items[@as(usize, h) * ports + driven] += current;
        }
    }
}

// ---- private ----

fn axpy(row: []f64, c: f64, from: []const f64) void {
    for (row, from) |*r, f| r.* += c * f;
}

/// A strict left fold.
fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0.0;
    for (a, b) |p, q| sum += p * q;
    return sum;
}

/// Zeroes the held entries.
fn free(held: []const u32, out: []f64) void {
    for (held, out) |h, *value| {
        if (h != no_port) value.* = 0.0;
    }
}

/// Each lateral mode's depth system `Kz + (λa + λb) Bz` eliminated down to
/// the top face: one number per mode `ab = a * ny + b`. A grounded backside
/// holds the last line, which leaves the system; its gap's conductance stays
/// on the line above.
fn depthEliminated(arena: Allocator, profile: Profile, z: []const f64, lx: []const f64, ly: []const f64) Allocator.Error![]f64 {
    const nz = z.len;
    const cells = nz - 1;
    const bottom = try arena.alloc(f64, profile.layers.len);
    var depth: f64 = 0.0;
    for (profile.layers, bottom) |layer, *b| {
        depth += layer[0];
        b.* = depth;
    }
    const sigma = try arena.alloc(f64, cells);
    const edge = try arena.alloc(f64, cells);
    for (sigma, edge, z[0..cells], z[1..]) |*sg, *e, top, low| {
        const mid = 0.5 * (top + low);
        var layer: usize = 0;
        while (layer < bottom.len and bottom[layer] < mid) layer += 1;
        sg.* = 1.0 / profile.layers[@min(layer, profile.layers.len - 1)][1];
        e.* = sg.* / (low - top);
    }
    const bz = try arena.alloc(f64, nz);
    for (bz, 0..) |*b, k| b.* = 0.5 * ((if (k > 0) sigma[k - 1] * (z[k] - z[k - 1]) else 0.0) + (if (k < cells) sigma[k] * (z[k + 1] - z[k]) else 0.0));
    const last = switch (profile.backside) {
        .grounded => nz - 2,
        .floating => nz - 1,
    };
    const s = try arena.alloc(f64, lx.len * ly.len);
    for (s, 0..) |*out, ab| {
        const mu = lx[ab / ly.len] + ly[ab % ly.len];
        var q = diagAt(edge, bz, mu, last);
        var k = last;
        while (k > 1) {
            k -= 1;
            q = diagAt(edge, bz, mu, k) - edge[k] * edge[k] / q;
        }
        out.* = if (last == 0) diagAt(edge, bz, mu, 0) else diagAt(edge, bz, mu, 0) - edge[0] * edge[0] / q;
    }
    return s;
}

fn diagAt(edge: []const f64, bz: []const f64, mu: f64, k: usize) f64 {
    return (if (k > 0) edge[k - 1] else 0.0) + (if (k < edge.len) edge[k] else 0.0) + mu * bz[k];
}
