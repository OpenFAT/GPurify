//! The f64 vector kernels ERC power's CG and extract's GMRES share. In: f64
//! columns and a CSR matrix. Out: dot products, norms, a mat-vec, and the two
//! elementwise updates as Gompute `zip` specs. Ported from
//! crates/geom/src/linalg.rs.
//!
//! `dot`, `nrm2` and `spmv` are strict left folds in ascending index order.
//! That order is interface (it decides CG's alpha and the convergence
//! verdict), so they stay on the CPU and are never reassociated. `axpy` and
//! `xpay` are elementwise, so they run on either backend through
//! `g.Kernel(spec, backend)`, bit-identically: Zig's strict float mode never
//! contracts `a * x + y` into an FMA.
//!
//! A kernel-owning file: it imports only `std` and `gompute`, and `root.zig`
//! names it from a comptime block so the device compile sees its specs.
//!
//! Contents:
//! - `pub fn dot(a: []const f64, b: []const f64) f64`
//! - `pub fn nrm2(a: []const f64) f64`
//! - `pub fn spmv(row_start: []const u32, col: []const u32, value: []const f64, v: []const f64, out: []f64) void`
//! - `pub const axpy`: `out[i] = alpha * x[i] + y[i]`, params `pub const Axpy = struct { alpha: f64 }`
//! - `pub const xpay`: `out[i] = z[i] + beta * p[i]`, params `pub const Xpay = struct { beta: f64 }`
//! - `pub const wide_probe`: `out[i] = (a[i] * b[i]) / d` through `i128`,
//!   params `pub const WideProbe = struct { d: i64 }` (the device i128 probe)

const std = @import("std");
const assert = std.debug.assert;
const g = @import("gompute");

/// `y += alpha * x`, called as `run(x, y, y, .{ .alpha = a })`: the output may
/// alias `y`, since each lane reads its inputs before it writes.
pub const axpy = g.zip("geom_axpy", f64, f64, f64, Axpy, axpyBody, .{});
pub const Axpy = struct { alpha: f64 };

/// `p = z + beta * p`, CG's search-direction update, called as
/// `run(z, p, p, .{ .beta = b })`.
pub const xpay = g.zip("geom_xpay", f64, f64, f64, Xpay, xpayBody, .{});
pub const Xpay = struct { beta: f64 };

/// The device probe that `i128` lowers on nvptx and amdgcn: an `i128` product
/// and an `i128` division inside a kernel body. Gompute buffers are at most 64
/// bits wide, so the wide value lives only inside the body, as an area would.
pub const wide_probe = g.zip("geom_wide_probe", i64, i64, i64, WideProbe, wideProbeBody, .{});
pub const WideProbe = struct { d: i64 };

comptime {
    g.exportKernels(@This());
}

/// Σ aᵢ·bᵢ, folded left to right in index order. Asserts equal lengths: a
/// short zip would drop terms.
pub fn dot(a: []const f64, b: []const f64) f64 {
    assert(a.len == b.len);
    var s: f64 = 0.0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// ‖a‖₂, the square root of `dot(a, a)`.
pub fn nrm2(a: []const f64) f64 {
    return @sqrt(dot(a, a));
}

/// `out[i]` = row `i` of a CSR matrix times `v`, each row folded in stored
/// order. Asserts a well-formed CSR: `row_start` one longer than `out`,
/// ending at the entry count `col.len == value.len`, monotone, with every
/// column inside `v`.
pub fn spmv(row_start: []const u32, col: []const u32, value: []const f64, v: []const f64, out: []f64) void {
    assert(row_start.len == out.len + 1);
    assert(col.len == value.len);
    assert(row_start[out.len] == col.len);
    for (out, row_start[0..out.len], row_start[1..]) |*row, from, to| {
        assert(from <= to);
        var acc: f64 = 0.0;
        for (col[from..to], value[from..to]) |c, x| acc += x * v[c];
        row.* = acc;
    }
}

// ---- private ----

fn axpyBody(x: anytype, y: anytype, p: Axpy) @TypeOf(x) {
    return g.splat(@TypeOf(x), p.alpha) * x + y;
}

fn xpayBody(z: anytype, p: anytype, q: Xpay) @TypeOf(z) {
    return z + g.splat(@TypeOf(z), q.beta) * p;
}

fn wideProbeBody(a: i64, b: i64, p: WideProbe) i64 {
    return @truncate(@divTrunc(@as(i128, a) * b, p.d));
}

/// Deterministic values mixing ordinary floats with the edge cases: signed
/// zero, subnormal, the infinities and NaN. The ordinary ones carry a full
/// 53-bit mantissa, so a fused multiply-add rounds differently from the
/// strict pair. (Rust's `f64::from_bits(h >> 2) % 1e6 - 5e5` was almost
/// always exactly `-5e5`: products of those are exact, and the Rust test
/// passed with an FMA.)
fn column(out: []f64, seed: u64) void {
    const edge = [_]f64{ 0.0, -0.0, 5e-324, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };
    for (out, 0..) |*v, i| {
        const h = std.math.rotl(u64, (seed ^ i) *% 0x9E37_79B9_7F4A_7C15, 29);
        const unit = @as(f64, @floatFromInt(h >> 11)) / 0x1p53;
        v.* = if (h % 11 == 0) edge[(h >> 8) % edge.len] else unit * 1e6 - 5e5;
    }
}

test "the lane kernels match their scalar loops bit for bit" {
    // Oracle: differential against the scalar loops `y[j] += alpha * x[j]`
    // and `p[j] = z[j] + beta * p[j]`, bit for bit (no FMA either side), at
    // every length 0 to 13, so every vector tail is crossed.
    var kx = try g.Kernel(axpy, .cpu).init(0);
    defer kx.deinit();
    var kp = try g.Kernel(xpay, .cpu).init(0);
    defer kp.deinit();
    var x_buf: [13]f64 = undefined;
    var y_buf: [13]f64 = undefined;
    var got_buf: [13]f64 = undefined;
    var want_buf: [13]f64 = undefined;
    for (0..14) |n| {
        const x = x_buf[0..n];
        const y = y_buf[0..n];
        const got = got_buf[0..n];
        const want = want_buf[0..n];
        for (0..8) |seed| {
            column(x, seed);
            column(y, seed + 100);
            var k: [1]f64 = undefined;
            column(&k, seed + 200);
            @memcpy(got, y);
            @memcpy(want, y);
            try kx.run(x, got, got, .{ .alpha = k[0] });
            for (want, x) |*w, xj| w.* += k[0] * xj;
            try std.testing.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
            @memcpy(got, y);
            @memcpy(want, y);
            try kp.run(x, got, got, .{ .beta = k[0] });
            for (want, x) |*w, zj| w.* = zj + k[0] * w.*;
            try std.testing.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
        }
    }
}

test "spmv reads the csr it is given" {
    // Oracle: hand-derived. `[[2, 0, 1], [0, 3, 0], [1, 0, 4]] * [1, 2, 3]` is
    // `[5, 6, 13]`.
    var out: [3]f64 = undefined;
    spmv(&.{ 0, 2, 3, 5 }, &.{ 0, 2, 1, 0, 2 }, &.{ 2, 1, 3, 1, 4 }, &.{ 1, 2, 3 }, &out);
    try std.testing.expectEqual([3]f64{ 5, 6, 13 }, out);
}

test "the empty case is zero and not a panic" {
    // Oracle: closed form. An empty sum is 0, so the empty dot product and
    // norm are 0.
    try std.testing.expectEqual(@as(f64, 0), dot(&.{}, &.{}));
    try std.testing.expectEqual(@as(f64, 0), nrm2(&.{}));
    var out: [0]f64 = .{};
    spmv(&.{0}, &.{}, &.{}, &.{1.0}, &out);
}

test "the wide probe divides an i128 product" {
    // Oracle: hand-derived. (2^40 * 2^40) / 2^30 = 2^50, whose product is
    // past i64; and -7 * 3 / 2 truncates toward zero to -10.
    var k = try g.Kernel(wide_probe, .cpu).init(0);
    defer k.deinit();
    var out: [2]i64 = undefined;
    try k.run(&.{ 1 << 40, -7 }, &.{ 1 << 40, 3 }, &out, .{ .d = 1 << 30 });
    try std.testing.expectEqual(@as(i64, 1 << 50), out[0]);
    try k.run(&.{-7}, &.{3}, out[0..1], .{ .d = 2 });
    try std.testing.expectEqual(@as(i64, -10), out[0]);
}
