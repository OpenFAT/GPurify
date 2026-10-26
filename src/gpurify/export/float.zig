//! An `f64` as the Rust tool printed it, so the report bytes match its
//! goldens. In: one `f64`. Out: Rust's `{}` (`display`), `{:?}` (`debug`)
//! or `{:.6}` (`fixed6`, every number in JSON, SPEF, DSPF and SPICE) text.
//! Cites: Rust `core::fmt::float` (rustc 1.95), whose output on 300k values
//! was the differential oracle when this file was written.
//!
//! Zig's `{d}` is nearly Rust's `{}` (the shortest round-trip digits, never
//! an exponent), but prints `nan`, and Zig's Ryū rounds an exact tie in the
//! last digit to even where Rust rounds it up (612 of 300k values). Zig's
//! `{d:.6}` rounds the shortest digits, not the exact binary value, so
//! `1e30` loses its tail digits: `fixed6` works on the exact value.
//!
//! Contents:
//! - `pub fn display(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void`
//! - `pub fn debug(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void`
//! - `pub fn fixed6(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

/// Shortest round-trip digits: `d₁.d₂… · 10^point`, no trailing zero (`0`
/// is the one digit `0`).
const Digits = struct { buf: [24]u8, len: u8, point: i32 };

/// Rust's `{}`: the shortest digits that read back as `v`, in plain decimal
/// (`2100`, `0.0000004`, `-0`); `NaN`, `inf`, `-inf`.
pub fn display(w: *Writer, v: f64) Writer.Error!void {
    if (try special(w, v)) return;
    try plain(w, shortest(@abs(v)), "");
}

/// Rust's `{:?}`: `display` with at least one decimal (`2100.0`), but the
/// shortest exponent form (`1e-5`, `1.5e16`) below `1e-4` or from `1e16`.
pub fn debug(w: *Writer, v: f64) Writer.Error!void {
    if (try special(w, v)) return;
    const a = @abs(v);
    const d = shortest(a);
    if (!((a != 0 and a < 1e-4) or a >= 1e16)) return plain(w, d, ".0");
    const digits = d.buf[0..d.len];
    try w.writeByte(digits[0]);
    if (digits.len > 1) try w.print(".{s}", .{digits[1..]});
    try w.print("e{d}", .{d.point});
}

/// Rust's `{:.6}`: the exact binary value rounded to six decimals, never an
/// exponent (`1e30` is `1000000000000000019884624838656.000000`, anything
/// below `5e-7` in magnitude `0.000000`, keeping its sign); `NaN`, `inf`.
pub fn fixed6(w: *Writer, v: f64) Writer.Error!void {
    if (std.math.isNan(v)) return w.writeAll("NaN");
    if (std.math.isInf(v)) return w.writeAll(if (v < 0) "-inf" else "inf");
    if (std.math.signbit(v)) try w.writeByte('-');
    const bits: u64 = @bitCast(v);
    const biased: i32 = @intCast(bits >> 52 & 0x7ff);
    const fraction = bits & ((1 << 52) - 1);
    // |v| = mantissa · 2^exponent exactly.
    const mantissa: u64 = if (biased == 0) fraction else fraction | (1 << 52);
    const exponent: i32 = (if (biased == 0) 1 else biased) - 1075;
    if (exponent >= 0) {
        try bigInteger(w, mantissa, @intCast(exponent));
        return w.writeAll(".000000");
    }
    const shift: u32 = @intCast(-exponent);
    var whole: u64 = if (shift >= 64) 0 else mantissa >> @intCast(shift);
    const frac: u128 = if (shift >= 64) mantissa else mantissa & ((@as(u64, 1) << @intCast(shift)) - 1);
    // frac · 10^6 / 2^shift, rounded half to even; below 2^84, so exact in
    // u128, and zero for any shift past 85.
    const scaled = frac * 1_000_000;
    var micros: u64 = 0;
    if (shift < 128) {
        const s: u7 = @intCast(shift);
        micros = @intCast(scaled >> s);
        const rem = scaled - (@as(u128, micros) << s);
        const half = @as(u128, 1) << (s - 1);
        if (rem > half or (rem == half and micros & 1 == 1)) micros += 1;
    }
    if (micros == 1_000_000) {
        micros = 0;
        whole += 1;
    }
    try w.print("{d}.{d:0>6}", .{ whole, micros });
}

// ---- private ----

/// The sign, then `NaN`, `inf`; true when `v` was one of those.
fn special(w: *Writer, v: f64) Writer.Error!bool {
    if (std.math.isNan(v)) {
        try w.writeAll("NaN");
        return true;
    }
    if (std.math.signbit(v)) try w.writeByte('-');
    if (std.math.isInf(v)) try w.writeAll("inf");
    return std.math.isInf(v);
}

/// `d` in plain decimal; `whole_suffix` after a value with no fraction.
fn plain(w: *Writer, d: Digits, whole_suffix: []const u8) Writer.Error!void {
    const digits = d.buf[0..d.len];
    const whole = d.point + 1;
    if (whole <= 0) {
        try w.writeAll("0.");
        try w.splatByteAll('0', @intCast(-whole));
        return w.writeAll(digits);
    }
    const n: usize = @intCast(whole);
    if (n >= digits.len) {
        try w.writeAll(digits);
        try w.splatByteAll('0', n - digits.len);
        return w.writeAll(whole_suffix);
    }
    try w.print("{s}.{s}", .{ digits[0..n], digits[n..] });
}

/// Zig's shortest digits of finite `a >= 0` (its `{e}`), with an exact tie
/// rounded up as Rust's Grisu/Dragon do, where Zig's Ryū rounds it to even:
/// `169700940171274.125` is Rust's `169700940171274.13`.
fn shortest(a: f64) Digits {
    var d: Digits = undefined;
    var text_buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{e}", .{a}) catch unreachable;
    const e_at = std.mem.findScalar(u8, text, 'e').?;
    d.point = std.fmt.parseInt(i32, text[e_at + 1 ..], 10) catch unreachable;
    d.len = 0;
    for (text[0..e_at]) |c| if (c != '.') {
        d.buf[d.len] = c;
        d.len += 1;
    };
    const m = std.fmt.parseInt(u64, d.buf[0..d.len], 10) catch unreachable;
    if (a == 0 or !isMidpoint(a, m, d.point + 1 - @as(i32, d.len))) return d;
    // Round the last digit up, carrying; then drop the zeros it leaves.
    var i: usize = d.len;
    while (i > 0) {
        i -= 1;
        if (d.buf[i] != '9') {
            d.buf[i] += 1;
            break;
        }
        d.buf[i] = '0';
    } else {
        d.buf[0] = '1';
        d.point += 1;
    }
    while (d.len > 1 and d.buf[d.len - 1] == '0') d.len -= 1;
    return d;
}

/// Whether `a` is exactly `(m + 1/2) · 10^k`. With `2a = odd · 2^t`, that
/// is `t == k` and `odd == (2m + 1) · 5^k`; both sides are odd.
fn isMidpoint(a: f64, m: u64, k: i32) bool {
    const bits: u64 = @bitCast(a);
    const biased: i32 = @intCast(bits >> 52 & 0x7ff);
    const fraction = bits & ((1 << 52) - 1);
    const mantissa: u64 = if (biased == 0) fraction else fraction | (1 << 52);
    const zeros: i32 = @ctz(mantissa);
    const odd: u128 = mantissa >> @intCast(zeros);
    const t = (if (biased == 0) 1 else biased) - 1075 + zeros + 1;
    // Past 5^27 one side outgrows the other: 2m + 1 < 2^58, odd < 2^53.
    if (t != k or k > 27 or k < -27) return false;
    const five = std.math.pow(u128, 5, @abs(k));
    const target = 2 * @as(u128, m) + 1;
    return if (k >= 0) odd == target * five else odd * five == target;
}

/// `mantissa · 2^exponent` in decimal, every digit exact: base-10^9 limbs,
/// least significant first, doubled up to 30 bits at a time.
fn bigInteger(w: *Writer, mantissa: u64, exponent: u32) Writer.Error!void {
    const base = 1_000_000_000;
    // 2^1024 has 309 digits: 35 limbs.
    var limbs: [36]u64 = undefined;
    limbs[0] = mantissa % base;
    limbs[1] = mantissa / base % base;
    limbs[2] = mantissa / base / base;
    var len: usize = 3;
    var left = exponent;
    while (left > 0) {
        const step: u6 = @intCast(@min(left, 30));
        left -= step;
        var carry: u64 = 0;
        for (limbs[0..len]) |*limb| {
            const x = (limb.* << step) + carry;
            limb.* = x % base;
            carry = x / base;
        }
        while (carry > 0) : (len += 1) {
            limbs[len] = carry % base;
            carry /= base;
        }
    }
    while (len > 1 and limbs[len - 1] == 0) len -= 1;
    assert(len <= limbs.len);
    try w.print("{d}", .{limbs[len - 1]});
    var i = len - 1;
    while (i > 0) {
        i -= 1;
        try w.print("{d:0>9}", .{limbs[i]});
    }
}

test "fixed6, display and debug match rustc on its own vectors" {
    // Oracle: rustc 1.95 `format!("{} {:?} {:.6}")` on each value, copied
    // from the scratch program's output (the same program ran 300k random
    // and decimal-shaped values through this file with no difference).
    const cases = [_]struct { u64, []const u8, []const u8, []const u8 }{
        .{ 0x0000000000000000, "0", "0.0", "0.000000" },
        .{ 0x8000000000000000, "-0", "-0.0", "-0.000000" },
        .{ 0x40a0680000000000, "2100", "2100.0", "2100.000000" },
        .{ 0x40f81cd6e9e1b08a, "98765.4321", "98765.4321", "98765.432100" },
        .{ 0x3e9ad7f29abcaf48, "0.0000004", "4e-7", "0.000000" },
        .{ 0x3ea0c6f7a0b5ed8d, "0.0000005", "5e-7", "0.000000" },
        .{ 0x3eb92a737110e454, "0.0000015", "1.5e-6", "0.000002" },
        .{ 0x46293e5939a08cea, "1000000000000000000000000000000", "1e30", "1000000000000000019884624838656.000000" },
        .{ 0x3f1a36e2eb1c432d, "0.0001", "0.0001", "0.000100" },
        .{ 0x3f1a36d1bd105b06, "0.000099999", "9.9999e-5", "0.000100" },
        .{ 0x4341c37937e08000, "10000000000000000", "1e16", "10000000000000000.000000" },
        .{ 0x4341c37937e07fff, "9999999999999998", "9999999999999998.0", "9999999999999998.000000" },
        .{ 0x441ac53a7e04bcda, "123456789012345680000", "1.2345678901234568e20", "123456789012345683968.000000" },
        .{ 0x44b52d02c7e14af6, "100000000000000000000000", "1e23", "99999999999999991611392.000000" },
        .{ 0x3feffffef39085f5, "0.9999995", "0.9999995", "1.000000" },
        .{ 0x3feffffef39085f4, "0.9999994999999999", "0.9999994999999999", "0.999999" },
        .{ 0x3ff000008637bd06, "1.0000005", "1.0000005", "1.000001" },
        .{ 0xbe112e0be826d695, "-0.000000001", "-1e-9", "-0.000000" },
        .{ 0x3ea0c6f7a0b5ed8e, "0.0000005000000000000001", "5.000000000000001e-7", "0.000001" },
        .{ 0xc356345785d8a000, "-25000000000000000", "-2.5e16", "-25000000000000000.000000" },
        // Exact ties, which Rust rounds up and Zig's `{d}` to even.
        .{ 0x42e34af288390144, "169700940171274.13", "169700940171274.13", "169700940171274.125000" },
        .{ 0x430774f32101e012, "825314005498882.3", "825314005498882.3", "825314005498882.250000" },
        .{ 0x7ff8000000000000, "NaN", "NaN", "NaN" },
        .{ 0x7ff0000000000000, "inf", "inf", "inf" },
        .{ 0xfff0000000000000, "-inf", "-inf", "-inf" },
        .{ 0x0000000000000001, "0." ++ @as([323]u8, @splat('0')) ++ "5", "5e-324", "0.000000" },
    };
    var buf: [400]u8 = undefined;
    for (cases) |c| {
        const v: f64 = @bitCast(c[0]);
        inline for (.{ display, debug, fixed6 }, 1..) |f, k| {
            var w: Writer = .fixed(&buf);
            try f(&w, v);
            try std.testing.expectEqualStrings(c[k], w.buffered());
        }
    }
}

test "fixed6 writes the largest double's every digit" {
    // Oracle: rustc 1.95 `format!("{:.6}", f64::MAX)`, the exact value of
    // (2 - 2^-52) · 2^1023.
    var buf: [400]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try fixed6(&w, std.math.floatMax(f64));
    try std.testing.expectEqualStrings("179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.000000", w.buffered());
}
