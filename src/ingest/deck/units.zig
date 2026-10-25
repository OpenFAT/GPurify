//! Exact decimals: a number's text → `m · 10^e` with an `i128` mantissa, so
//! a deck length is checked against the grid exactly and converted to `f64`
//! by one correctly rounded parse. Ported from crates/ingest/src/deck/parse.rs
//! (`Dec`).
//!
//! Contents:
//! - `pub const Dec`, `Dec.parse(text: []const u8, neg: bool) ?Dec`, `Dec.shifted(d: Dec, shift: i32) Dec`,
//!   `Dec.toF64(d: Dec) f64`, `Dec.at(d: Dec, e: i32) ?i128`,
//!   `Dec.isMultipleOf(d: Dec, of: Dec) ?bool`, `Dec.integer(d: Dec) ?i128`

const std = @import("std");

/// An exact decimal, `m * 10^e`.
pub const Dec = struct {
    m: i128,
    e: i32,

    /// Digits, an optional fraction, an optional exponent; null when the
    /// mantissa or exponent does not fit.
    pub fn parse(text: []const u8, neg: bool) ?Dec {
        const e_at = std.mem.indexOfAny(u8, text, "eE");
        const body = if (e_at) |i| text[0..i] else text;
        const exp: i32 = if (e_at) |i| std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return null else 0;
        const dot = std.mem.indexOfScalar(u8, body, '.');
        const whole = if (dot) |i| body[0..i] else body;
        const frac = if (dot) |i| body[i + 1 ..] else "";
        var digits: i128 = 0;
        if (whole.len + frac.len == 0) return null;
        for ([2][]const u8{ whole, frac }) |part| for (part) |c| {
            if (c < '0' or c > '9') return null;
            const m = @mulWithOverflow(digits, 10);
            if (m[1] != 0) return null;
            const a = @addWithOverflow(m[0], c - '0');
            if (a[1] != 0) return null;
            digits = a[0];
        };
        const frac_len = std.math.cast(i32, frac.len) orelse return null;
        const e = @subWithOverflow(exp, frac_len);
        if (e[1] != 0) return null;
        return .{ .m = if (neg) -digits else digits, .e = e[0] };
    }

    pub fn shifted(d: Dec, shift: i32) Dec {
        return .{ .m = d.m, .e = d.e + shift };
    }

    /// Correctly rounded, so the same decimal always gives the same `f64`.
    pub fn toF64(d: Dec) f64 {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}e{d}", .{ d.m, d.e }) catch unreachable;
        return std.fmt.parseFloat(f64, s) catch unreachable;
    }

    /// `m` rescaled to exponent `e <= d.e`, if it fits.
    pub fn at(d: Dec, e: i32) ?i128 {
        const diff = @as(i64, d.e) - e;
        if (diff < 0) return null;
        const scale = std.math.powi(i128, 10, std.math.cast(u32, diff) orelse return null) catch return null;
        const m = @mulWithOverflow(scale, d.m);
        return if (m[1] == 0) m[0] else null;
    }

    pub fn isMultipleOf(d: Dec, of: Dec) ?bool {
        const e = @min(d.e, of.e);
        const o = of.at(e) orelse return null;
        const self_at = d.at(e) orelse return null;
        return o != 0 and @rem(self_at, o) == 0;
    }

    pub fn integer(d: Dec) ?i128 {
        if (d.e >= 0) return d.at(0);
        const div = std.math.powi(i128, 10, std.math.cast(u32, -@as(i64, d.e)) orelse return null) catch return null;
        return if (@rem(d.m, div) == 0) @divTrunc(d.m, div) else null;
    }
};

test "a decimal reads exactly and tests multiples exactly" {
    // Oracle: hand-derived. 0.14 is 14e-2, which 5e0 (a 5 nm grid in nm, so
    // 140 nm) divides once shifted by 3; 1.5e2 is 150; 39 nines overflow i128.
    const d = Dec.parse("0.14", false).?;
    try std.testing.expectEqual(Dec{ .m = 14, .e = -2 }, d);
    try std.testing.expectEqual(true, d.shifted(3).isMultipleOf(.{ .m = 5, .e = 0 }).?);
    try std.testing.expectEqual(false, Dec.parse("142", false).?.isMultipleOf(.{ .m = 5, .e = 0 }).?);
    try std.testing.expectEqual(@as(i128, 150), Dec.parse("1.5e2", false).?.integer().?);
    try std.testing.expectEqual(null, Dec.parse("1.5", false).?.integer());
    try std.testing.expectEqual(-0.14, Dec.parse("0.14", true).?.toF64());
    try std.testing.expectEqual(null, Dec.parse("9999999999999999999999999999999999999999", false));
}
