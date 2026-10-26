//! The row kernels on the host threads against their scalar oracles, bit for
//! bit. Ported from the in-file tests of crates/extract/src/field/matvec.rs
//! (`the_simd_matvec_matches_the_scalar_fold_bit_for_bit`) and
//! dielectric.rs (`the_simd_field_rows_match_the_scalar_fold_bit_for_bit`):
//! Rust checked its SIMD tiles against a scalar fold; here the threaded row
//! blocks are checked against the fold written out once more.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const operators = @import("operators.zig");
const gpa = testing.allocator;

/// Sizes crossing every row-block boundary, and one large enough that the
/// threads actually start (`rows.zig`'s work threshold).
const sizes = [_]usize{ 0, 1, 63, 64, 3 * 64 + 1, 600 };

// ---- private ----

fn scalarPotential(m: *const extract.matvec.Potential, i: usize, x: []const f64) f64 {
    var acc: f64 = 0.0;
    for (0..m.cx.len) |j| {
        const dx = m.cx[i] - m.cx[j];
        const dy = m.cy[i] - m.cy[j];
        const dz = m.cz[i] - m.cz[j];
        const iz = m.cz[i] + m.cz[j];
        const plane = dx * dx + dy * dy;
        const soft = m.radius[i] * m.radius[j];
        const w = 2.0 * m.k[i] * m.k[j] * x[j] / (m.k[i] + m.k[j]);
        acc += w / @sqrt(plane + dz * dz + soft) - w / @sqrt(plane + iz * iz + soft);
    }
    for (m.near.start.items[i]..m.near.start.items[i + 1]) |e| acc = acc + m.near.value.items[e] * x[m.near.column.items[e]];
    return acc;
}

fn scalarField(f: *const extract.dielectric.Field, r: usize, x: []const f64) f64 {
    const row = f.first + r;
    var field: f64 = 0.0;
    for (0..f.cx.len) |p| {
        if (p == row) continue;
        const dx = f.cx[row] - f.cx[p];
        const dy = f.cy[row] - f.cy[p];
        const dz = f.cz[row] - f.cz[p];
        const image = f.cz[row] + f.cz[p];
        const plane = dx * dx + dy * dy;
        const r2 = plane + dz * dz;
        const s2 = plane + image * image;
        field += x[p] * (dz / (r2 * @sqrt(r2)) - image / (s2 * @sqrt(s2)));
    }
    for (f.near.start.items[r]..f.near.start.items[r + 1]) |e| field = field + f.near.value.items[e] * x[f.near.column.items[e]];
    return f.scale[r] * (x[row] * f.inverse_area[r] - f.weight[r] * field);
}

test "the potential rows match the scalar fold bit for bit at any thread count" {
    // Oracle: the scalar row fold, written out independently above: dense
    // ascending-j sum, then the near corrections in column order. Every
    // thread count gives the same bits.
    var rng: Rng = .init(11);
    for (sizes) |n| {
        for ([_]u16{ 1, 3, 8 }) |threads| {
            var m = try operators.randomPotential(gpa, &rng, n, threads);
            defer m.deinit(gpa);
            const x = try operators.randomCharges(gpa, &rng, n);
            defer gpa.free(x);
            const y = try gpa.alloc(f64, n);
            defer gpa.free(y);
            @memset(y, std.math.nan(f64));
            m.apply(x, y);
            for (y, 0..) |got, i| try testing.expectEqual(@as(u64, @bitCast(scalarPotential(&m, i, x))), @as(u64, @bitCast(got)));
        }
    }
}

test "the field rows match the scalar fold bit for bit at any thread count" {
    // Oracle: the scalar row fold of the interface rows, its diagonal
    // skipped, then the near corrections, then the row scale; after 0, 1 and
    // 5 conductor panels, at every row count crossing a block boundary.
    var rng: Rng = .init(7);
    for ([_]usize{ 0, 1, 5 }) |first| {
        for (sizes) |rows| {
            for ([_]u16{ 1, 8 }) |threads| {
                var f = try operators.randomField(gpa, &rng, first, rows, threads);
                defer f.deinit(gpa);
                const n = first + rows;
                const x = try operators.randomCharges(gpa, &rng, n);
                defer gpa.free(x);
                const y = try gpa.alloc(f64, n);
                defer gpa.free(y);
                @memset(y, std.math.nan(f64));
                f.apply(x, y);
                for (0..rows) |r| try testing.expectEqual(@as(u64, @bitCast(scalarField(&f, r, x))), @as(u64, @bitCast(y[first + r])));
            }
        }
    }
}
