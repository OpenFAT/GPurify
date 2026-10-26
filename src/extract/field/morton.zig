//! Spatial order of a mesh's panels: Morton keys quantised against the
//! panels' own bounds, the exact centroid as the tiebreak. In: panel
//! centroids and the conductor bands. Out: a permutation sorting each band
//! (never across bands). The order is the matvec's summation order, so it
//! fixes output bits. Ported from crates/extract/src/field/mesh.rs.
//!
//! Contents:
//! - `pub fn bandOrderInto(gpa: Allocator, cx: []const f64, cy: []const f64, cz: []const f64, band_start: []const u32, order: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Bits per axis in a Morton key.
const morton_bits = 21;

const morton_max: u64 = (1 << morton_bits) - 1;

/// `morton_max` as `f64` (exact).
const morton_span: f64 = 2_097_151.0;

const Ctx = struct {
    key: []const u64,
    cx: []const f64,
    cy: []const f64,
    cz: []const f64,

    /// Morton key, then z, y, x by total order.
    fn lessThan(c: Ctx, a: u32, b: u32) bool {
        if (c.key[a] != c.key[b]) return c.key[a] < c.key[b];
        for ([_][]const f64{ c.cz, c.cy, c.cx }) |col| {
            const o = totalOrder(col[a], col[b]);
            if (o != .eq) return o == .lt;
        }
        return false;
    }
};

/// `order` (cleared) becomes the permutation that sorts each band
/// `band_start[b]..band_start[b + 1]` by Morton key, then z, y, x. Asserts
/// the bands CSR over the panels.
pub fn bandOrderInto(gpa: Allocator, cx: []const f64, cy: []const f64, cz: []const f64, band_start: []const u32, order: *std.ArrayList(u32)) Allocator.Error!void {
    const n = cx.len;
    assert(cy.len == n and cz.len == n and band_start[band_start.len - 1] == n);
    var lo: [3]f64 = @splat(std.math.inf(f64));
    var hi: [3]f64 = @splat(-std.math.inf(f64));
    for (cx, cy, cz) |x, y, z| {
        for ([3]f64{ x, y, z }, 0..) |v, axis| {
            lo[axis] = @min(lo[axis], v);
            hi[axis] = @max(hi[axis], v);
        }
    }
    // A degenerate axis collapses to one cell rather than dividing by zero.
    var scale: [3]f64 = undefined;
    for (&scale, lo, hi) |*s, l, h| s.* = if (h - l > 0.0) morton_span / (h - l) else 0.0;
    const key = try gpa.alloc(u64, n);
    defer gpa.free(key);
    for (key, cx, cy, cz) |*k, x, y, z| k.* = morton3(quantise(x, lo[0], scale[0]), quantise(y, lo[1], scale[1]), quantise(z, lo[2], scale[2]));

    try order.resize(gpa, n);
    for (order.items, 0..) |*o, i| o.* = @intCast(i);
    const ctx: Ctx = .{ .key = key, .cx = cx, .cy = cy, .cz = cz };
    for (band_start[0 .. band_start.len - 1], band_start[1..]) |from, to| {
        std.mem.sort(u32, order.items[from..to], ctx, Ctx.lessThan);
    }
}

// ---- private ----

/// IEEE total order, as Rust's `f64::total_cmp`.
fn totalOrder(a: f64, b: f64) std.math.Order {
    const flip = struct {
        fn key(v: f64) i64 {
            const bits: i64 = @bitCast(v);
            return bits ^ @as(i64, @bitCast(@as(u64, @bitCast(bits >> 63)) >> 1));
        }
    };
    return std.math.order(flip.key(a), flip.key(b));
}

/// One coordinate as a `morton_bits`-wide integer; saturating, NaN to zero,
/// so the key is total.
fn quantise(value: f64, lo: f64, scale: f64) u64 {
    const raw = (value - lo) * scale;
    if (!(raw > 0.0)) return 0;
    if (raw >= @as(f64, @floatFromInt(morton_max))) return morton_max;
    return @intFromFloat(raw);
}

/// Interleave three `morton_bits`-wide integers, `x` in the low bit of each
/// triple.
fn morton3(x: u64, y: u64, z: u64) u64 {
    return spread3(x) | spread3(y) << 1 | spread3(z) << 2;
}

/// Spread the low `morton_bits` of `v` so bit `i` lands at bit `3 * i`.
fn spread3(v: u64) u64 {
    var x = v & morton_max;
    x = (x | x << 32) & 0x001f_0000_0000_ffff;
    x = (x | x << 16) & 0x001f_0000_ff00_00ff;
    x = (x | x << 8) & 0x100f_00f0_0f00_f00f;
    x = (x | x << 4) & 0x10c3_0c30_c30c_30c3;
    x = (x | x << 2) & 0x1249_2492_4924_9249;
    return x;
}

comptime {
    assert(morton_max == 2_097_151);
}

test "spreading moves bit i to bit three i" {
    // Oracle: the definition in `spread3`'s doc: bit `i` lands at bit `3i`,
    // for every `i`, and bits above the axis width are masked off.
    for (0..morton_bits) |i| try std.testing.expectEqual(@as(u64, 1) << @intCast(3 * i), spread3(@as(u64, 1) << @intCast(i)));
    try std.testing.expectEqual(0, spread3(0));
    try std.testing.expectEqual(morton_bits, @popCount(spread3(morton_max)));
    try std.testing.expectEqual(spread3(morton_max), spread3(morton_max | 1 << morton_bits));
}

test "a key keeps all three axes in disjoint bits" {
    // Oracle: round trip. Gathering every third bit of the key from offsets
    // 0, 1 and 2 gives back `x`, `y` and `z`.
    const x: u64 = 0b1011;
    const y: u64 = 0b0110;
    const z: u64 = 0b1101;
    const key = morton3(x, y, z);
    for ([_]u64{ x, y, z }, 0..) |want, shift| {
        var bits: u64 = 0;
        for (0..morton_bits) |i| bits |= (key >> @intCast(3 * i + shift) & 1) << @intCast(i);
        try std.testing.expectEqual(want, bits);
    }
    try std.testing.expectEqual(0, morton3(0, 0, 0));
    try std.testing.expectEqual(3 * morton_bits, @popCount(morton3(morton_max, morton_max, morton_max)));
}

test "quantising is monotone and total" {
    // Oracle: hand-derived from `quantise`'s doc (saturating, NaN to zero):
    // 0 maps to 0, the span's end to `morton_max`, a quarter to a quarter of
    // it, and out-of-range, NaN and infinite inputs to the ends.
    const scale = morton_span / 4.0;
    try std.testing.expectEqual(0, quantise(0.0, 0.0, scale));
    try std.testing.expectEqual(morton_max, quantise(4.0, 0.0, scale));
    try std.testing.expectEqual(morton_max / 4, quantise(1.0, 0.0, scale));
    try std.testing.expect(quantise(1.0, 0.0, scale) < quantise(2.0, 0.0, scale));
    try std.testing.expectEqual(0, quantise(-1.0, 0.0, scale));
    try std.testing.expectEqual(morton_max, quantise(9.0, 0.0, scale));
    try std.testing.expectEqual(0, quantise(std.math.nan(f64), 0.0, scale));
    try std.testing.expectEqual(morton_max, quantise(std.math.inf(f64), 0.0, scale));
    try std.testing.expectEqual(0, quantise(7.0, 0.0, 0.0));
}
