//! Random field operators for the row-kernel differentials: the potential
//! and field rows' columns drawn from a seed, with a few near pairs per row.
//! Shared by kernels.zig (host threads against the scalar oracle) and
//! gpu.zig (device against host).
//!
//! Contents:
//! - `pub fn randomPotential(gpa: Allocator, rng: *Rng, n: usize, threads: u16) !extract.matvec.Potential`
//! - `pub fn randomField(gpa: Allocator, rng: *Rng, first: usize, rows: usize, threads: u16) !extract.dielectric.Field`
//! - `pub fn randomCharges(gpa: Allocator, rng: *Rng, n: usize) ![]f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const extract = @import("extract");
const testgen = @import("testgen");
const Rng = testgen.Rng;

/// `n` panels within 10 µm of the origin, every fourth on its predecessor's
/// centroid (so `r2` is the softening alone), each row with up to three near
/// pairs at random ascending columns.
pub fn randomPotential(gpa: Allocator, rng: *Rng, n: usize, threads: u16) !extract.matvec.Potential {
    var m: extract.matvec.Potential = .{ .cx = &.{}, .cy = &.{}, .cz = &.{}, .radius = &.{}, .k = &.{}, .near = .empty, .threads = threads };
    errdefer m.deinit(gpa);
    m.cx = try gpa.alloc(f64, n);
    m.cy = try gpa.alloc(f64, n);
    m.cz = try gpa.alloc(f64, n);
    m.radius = try gpa.alloc(f64, n);
    m.k = try gpa.alloc(f64, n);
    for (0..n) |i| {
        for ([_][]f64{ m.cx, m.cy, m.cz }) |col| col[i] = if (i % 4 == 3) col[i - 1] else rng.unit() * 2e-5 - 1e-5;
        m.radius[i] = 1e-9 + rng.unit() * 1e-7;
        m.k[i] = 1e10 * (1.0 + rng.unit() * 11.0);
    }
    try randomNear(gpa, rng, n, n, &m.near);
    return m;
}

/// `first` conductor panels then `rows` interface panels, centroids in a
/// 20 µm box, random row weights and scales, up to three near pairs a row.
pub fn randomField(gpa: Allocator, rng: *Rng, first: usize, rows: usize, threads: u16) !extract.dielectric.Field {
    const n = first + rows;
    var f: extract.dielectric.Field = .{ .first = @intCast(first), .cx = &.{}, .cy = &.{}, .cz = &.{}, .weight = &.{}, .scale = &.{}, .inverse_area = &.{}, .near = .empty, .threads = threads };
    errdefer f.deinit(gpa);
    f.cx = try gpa.alloc(f64, n);
    f.cy = try gpa.alloc(f64, n);
    f.cz = try gpa.alloc(f64, n);
    for ([_][]f64{ f.cx, f.cy, f.cz }) |col| {
        for (col) |*v| v.* = rng.unit() * 2e-5;
    }
    f.weight = try gpa.alloc(f64, rows);
    f.scale = try gpa.alloc(f64, rows);
    f.inverse_area = try gpa.alloc(f64, rows);
    for (f.weight, f.scale, f.inverse_area) |*w, *s, *inv| {
        w.* = rng.unit() - 0.5;
        s.* = 1e6 * rng.unit();
        inv.* = 1e12 * rng.unit();
    }
    try randomNear(gpa, rng, rows, n, &f.near);
    return f;
}

/// Charges in ±1 fC, with exact zeros and a repeated tiny value mixed in.
pub fn randomCharges(gpa: Allocator, rng: *Rng, n: usize) ![]f64 {
    const x = try gpa.alloc(f64, n);
    for (x, 0..) |*v, i| v.* = switch (i % 5) {
        0 => 0.0,
        1 => -1e-18,
        else => rng.unit() * 2e-15 - 1e-15,
    };
    return x;
}

// ---- private ----

fn randomNear(gpa: Allocator, rng: *Rng, rows: usize, columns: usize, out: *extract.NearPairs) !void {
    try out.start.append(gpa, 0);
    for (0..rows) |_| {
        const count = if (columns == 0) 0 else rng.below(4);
        var at: usize = 0;
        for (0..count) |_| {
            if (at >= columns) break;
            at += @intCast(rng.below(@max(columns - at, 1)));
            if (at >= columns) break;
            try out.column.append(gpa, @intCast(at));
            try out.value.append(gpa, rng.unit() * 1e9 - 5e8);
            at += 1;
        }
        try out.start.append(gpa, @intCast(out.column.items.len));
    }
}
