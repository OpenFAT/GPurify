//! The lane axis of the row kernels: `W` independent rows evaluated
//! together, lane `k` doing row `i + k`'s exact scalar operation sequence,
//! so every lane's bits are the scalar row's (`simd-first`: one body generic
//! over `W`, `W == 1` the device's and the oracle's). In: column pointers.
//! Out: lane values. Device-safe.
//!
//! Contents:
//! - `pub const host_lanes: comptime_int`
//! - `pub fn Lane(comptime W: comptime_int) type`
//! - `pub fn load(comptime W: comptime_int, column: anytype, i: usize) Lane(W)`
//! - `pub fn splat(comptime W: comptime_int, v: f64) Lane(W)`
//! - `pub fn lane(comptime W: comptime_int, v: Lane(W), k: usize) f64`
//! - `pub fn index(comptime W: comptime_int, i: usize) LaneIndex(W)`, `pub fn LaneIndex(comptime W: comptime_int) type`

const std = @import("std");

/// Rows the host evaluates together: two AVX2 vectors of `f64`, as Rust's
/// tile of 8.
pub const host_lanes = 8;

/// `f64` for one lane (the device has no vectors to spare), a vector of `W`
/// otherwise.
pub fn Lane(comptime W: comptime_int) type {
    return if (W == 1) f64 else @Vector(W, f64);
}

pub fn LaneIndex(comptime W: comptime_int) type {
    return if (W == 1) usize else @Vector(W, usize);
}

/// `column[i..i + W]` as lanes.
pub inline fn load(comptime W: comptime_int, column: anytype, i: usize) Lane(W) {
    if (W == 1) return column[i];
    return column[i..][0..W].*;
}

pub inline fn splat(comptime W: comptime_int, v: f64) Lane(W) {
    return if (W == 1) v else @splat(v);
}

pub inline fn lane(comptime W: comptime_int, v: Lane(W), k: usize) f64 {
    return if (W == 1) v else v[k];
}

/// The row index of each lane: `i, i + 1, …`.
pub inline fn index(comptime W: comptime_int, i: usize) LaneIndex(W) {
    if (W == 1) return i;
    return @as(@Vector(W, usize), @splat(i)) + std.simd.iota(usize, W);
}
