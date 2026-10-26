//! An `f64` as Rust formats it in the three forms Liberty and SPICE text
//! use: `{:e}` (`exp`, shortest digits, every number the simulator reads),
//! `{:.N}` (`fixed`) and `{:.Ne}` (`sci`), both the exact binary value
//! rounded half to even, so a `.lib` matches the Rust tool's bytes. Cites:
//! Rust `core::fmt::float` (rustc 1.95); geom.float for the shortest digits.
//!
//! ponytail: three Rust formats geom.float lacks; move them there when a
//! second module needs one.
//!
//! Contents:
//! - `pub fn exp(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void`
//! - `pub fn fixed(w: *std.Io.Writer, v: f64, comptime decimals: u8) std.Io.Writer.Error!void`
//! - `pub fn sci(w: *std.Io.Writer, v: f64, comptime decimals: u8) std.Io.Writer.Error!void`

const std = @import("std");
const Writer = std.Io.Writer;
const Managed = std.math.big.int.Managed;
const float = @import("geom").float;

/// Rust's `{:e}`: the shortest round-trip digits as `d[.ddd]e<exp>`
/// (`1.8e0`, `1e-18`, `0e0`); `NaN`, `inf`.
pub fn exp(w: *Writer, v: f64) Writer.Error!void {
    if (!std.math.isFinite(v)) return float.display(w, v);
    var buf: [400]u8 = undefined;
    var plain: Writer = .fixed(&buf);
    float.display(&plain, @abs(v)) catch unreachable;
    const text = plain.buffered();
    // Digits without the point, and where the point sat among them.
    var digits: [400]u8 = undefined;
    var n: usize = 0;
    var point: usize = text.len;
    for (text, 0..) |c, i| {
        if (c == '.') point = i else {
            digits[n] = c;
            n += 1;
        }
    }
    if (point == text.len) point = n;
    var first: usize = 0;
    while (first < n and digits[first] == '0') first += 1;
    if (std.math.signbit(v)) try w.writeByte('-');
    if (first == n) return w.writeAll("0e0");
    var last = n;
    while (digits[last - 1] == '0') last -= 1;
    try w.writeByte(digits[first]);
    if (last > first + 1) try w.print(".{s}", .{digits[first + 1 .. last]});
    try w.print("e{d}", .{@as(i64, @intCast(point)) - @as(i64, @intCast(first)) - 1});
}

/// Rust's `{:.N}`: the exact value rounded half to even to `decimals`
/// places, never an exponent, the sign kept (`-0.0000000000`).
pub fn fixed(w: *Writer, v: f64, comptime decimals: u8) Writer.Error!void {
    if (!std.math.isFinite(v)) return float.display(w, v);
    var digits: [400]u8 = undefined;
    const text = scaledDigits(@abs(v), decimals, &digits);
    if (std.math.signbit(v)) try w.writeByte('-');
    if (text.len <= decimals) {
        try w.writeAll("0.");
        try w.splatByteAll('0', decimals - text.len);
        return w.writeAll(text);
    }
    try w.writeAll(text[0 .. text.len - decimals]);
    if (decimals > 0) try w.print(".{s}", .{text[text.len - decimals ..]});
}

/// Rust's `{:.Ne}`: `decimals + 1` significant digits of the exact value,
/// rounded half to even (`1.250000000e-5`, `0.000000000e0`).
pub fn sci(w: *Writer, v: f64, comptime decimals: u8) Writer.Error!void {
    if (!std.math.isFinite(v)) return float.display(w, v);
    if (std.math.signbit(v)) try w.writeByte('-');
    const a = @abs(v);
    if (a == 0) {
        try w.writeAll("0.");
        try w.splatByteAll('0', decimals);
        return w.writeAll("e0");
    }
    var e: i32 = @intFromFloat(@floor(@log10(a)));
    var digits: [400]u8 = undefined;
    var text = scaledDigits(a, @as(i32, decimals) - e, &digits);
    // The estimate is off by one near a power of ten, or the rounding
    // carried into a new digit: rescale from the value, never the digits.
    while (text.len != decimals + 1) {
        e += if (text.len > decimals + 1) 1 else -1;
        text = scaledDigits(a, @as(i32, decimals) - e, &digits);
    }
    try w.writeByte(text[0]);
    if (decimals > 0) try w.print(".{s}", .{text[1..]});
    try w.print("e{d}", .{e});
}

// ---- private ----

/// The decimal digits of `a · 10^k` rounded half to even, no leading zero
/// (`""` for zero), into `buf`. Exact: big integers over the binary value.
fn scaledDigits(a: f64, k: i32, buf: []u8) []const u8 {
    var mem: [1 << 16]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    return scaledDigitsIn(fba.allocator(), a, k, buf) catch unreachable;
}

fn scaledDigitsIn(gpa: std.mem.Allocator, a: f64, k: i32, buf: []u8) ![]const u8 {
    const bits: u64 = @bitCast(a);
    const biased: i32 = @intCast(bits >> 52 & 0x7ff);
    const fraction = bits & ((1 << 52) - 1);
    const mantissa: u64 = if (biased == 0) fraction else fraction | (1 << 52);
    const e2: i32 = (if (biased == 0) 1 else biased) - 1075;
    // a · 10^k = num / den.
    var num = try Managed.initSet(gpa, mantissa);
    var den = try Managed.initSet(gpa, 1);
    var ten = try Managed.initSet(gpa, 10);
    var power = try Managed.init(gpa);
    try power.pow(&ten, @abs(k));
    if (k >= 0) try num.mul(&num, &power) else try den.mul(&den, &power);
    if (e2 >= 0) try num.shiftLeft(&num, @intCast(e2)) else try den.shiftLeft(&den, @intCast(-e2));
    var q = try Managed.init(gpa);
    var r = try Managed.init(gpa);
    try q.divTrunc(&r, &num, &den);
    try r.shiftLeft(&r, 1);
    const one = try Managed.initSet(gpa, 1);
    switch (r.order(den)) {
        .gt => try q.add(&q, &one),
        .eq => if (q.isOdd()) try q.add(&q, &one),
        .lt => {},
    }
    if (q.eqlZero()) return buf[0..0];
    const text = try q.toString(gpa, 10, .lower);
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

test "numbers print as rustc prints them" {
    // Oracle: rustc 1.95 `format!("{:e}")`, `{:.10}` and `{:.9e}` of each
    // value, hand-checked against the exact binary expansion where the
    // rounding is a tie (0.125 to two places is 0.12, half to even; 2.5e-5
    // is exactly 2.50000000000000011...e-5, so it rounds as written).
    const cases_exp = [_]struct { f64, []const u8 }{
        .{ 1.8, "1.8e0" },      .{ 1e-18, "1e-18" },   .{ 0.0, "0e0" },             .{ -2.5e-9, "-2.5e-9" },
        .{ 10.0, "1e1" },       .{ 1e-6, "1e-6" },     .{ 123.456, "1.23456e2" },   .{ 4e-7, "4e-7" },
        .{ 1e30, "1e30" },      .{ 2100.0, "2.1e3" },  .{ 0.0230506, "2.30506e-2" }, .{ -0.0, "-0e0" },
    };
    const cases_fixed = [_]struct { f64, []const u8 }{
        .{ 1.5, "1.5000000000" }, .{ 0.002302, "0.0023020000" }, .{ -0.002, "-0.0020000000" }, .{ 1.8, "1.8000000000" },
        .{ 25.0, "25.0000000000" }, .{ 0.181284, "0.1812840000" },
    };
    const cases_sci = [_]struct { f64, []const u8 }{
        .{ 1.25e-5, "1.250000000e-5" }, .{ 0.0005, "5.000000000e-4" }, .{ 9.99999999999e-4, "1.000000000e-3" }, .{ -3e-15, "-3.000000000e-15" },
    };
    var buf: [128]u8 = undefined;
    for (cases_exp) |c| {
        var w: Writer = .fixed(&buf);
        try exp(&w, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
    for (cases_fixed) |c| {
        var w: Writer = .fixed(&buf);
        try fixed(&w, c[0], 10);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
    for (cases_sci) |c| {
        var w: Writer = .fixed(&buf);
        try sci(&w, c[0], 9);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
    var w: Writer = .fixed(&buf);
    try fixed(&w, 0.125, 2);
    try std.testing.expectEqualStrings("0.12", w.buffered());
}
