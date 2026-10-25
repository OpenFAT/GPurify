//! Physical quantities: an `f64` count of `10^prefix` base units of one
//! `Dimension`, so `Qty(.capacitance, .atto)` is attofarads and adding volts
//! to millivolts does not compile. In: raw `f64` values. Out: same-dimension
//! sums, rescales, ratios, and the cross-dimension products and quotients the
//! engine uses (Ohm's law, area, current density), always at `.base`.
//! Cites: the SI prefix table (BIPM SI Brochure, 9th ed., Table 7).
//!
//! Contents:
//! - `pub const Dimension = enum`, `Dimension.symbol(d: Dimension) []const u8`
//! - `pub const Prefix = enum(i8)`, `Prefix.letter(p: Prefix) []const u8`
//! - `pub fn Qty(comptime dim: Dimension, comptime prefix: Prefix) type`, with
//!   `base(q) f64`, `to(q, comptime p: Prefix) Qty(dim, p)`, `isFinite(q) bool`,
//!   `add(a, b)`, `sub(a, b)`, `neg(q)`, `scale(q, factor: f64)`,
//!   `format(q, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub fn celsius(degrees: f64) Qty(.temperature, .base)`
//! - `pub fn mul(a: anytype, b: anytype) Product(@TypeOf(a), @TypeOf(b))`
//! - `pub fn div(a: anytype, b: anytype) Quotient(@TypeOf(a), @TypeOf(b))`
//! - `pub fn Product(comptime A: type, comptime B: type) type`
//! - `pub fn Quotient(comptime A: type, comptime B: type) type`
//! - `pub fn powi(base: f64, exponent: i32) f64`

const std = @import("std");

/// A physical dimension. `symbol` is the SI symbol of the base unit, ASCII.
pub const Dimension = enum {
    /// Physical distance. Distinct from `Dbu`, which is a grid index.
    length,
    /// Physical area. Distinct from `DbuArea`.
    area,
    voltage,
    current,
    resistance,
    capacitance,
    inductance,
    /// Current per unit width, as electromigration limits are specified.
    current_density,
    /// Absolute temperature, kelvin always: an Arrhenius `1/T` divides by
    /// zero at 0 °C. `celsius` converts at the deck boundary.
    temperature,

    /// ASCII (`ohm`, not `Ω`), so reports diff as plain text.
    pub fn symbol(d: Dimension) []const u8 {
        return switch (d) {
            .length => "m",
            .area => "m^2",
            .voltage => "V",
            .current => "A",
            .resistance => "ohm",
            .capacitance => "F",
            .inductance => "H",
            .current_density => "A/m",
            .temperature => "K",
        };
    }
};

/// SI decimal exponents. Exhaustive: the Rust tool allowed any `i8` and
/// formatted the rest as `3e-7 F`, but no quantity in it used one.
pub const Prefix = enum(i8) {
    atto = -18,
    femto = -15,
    pico = -12,
    nano = -9,
    micro = -6,
    milli = -3,
    /// The base unit. Cross-dimension products and quotients land here.
    base = 0,
    kilo = 3,
    mega = 6,
    giga = 9,

    /// The prefix letter; `u` for micro (ASCII, like `ohm`), `""` for base.
    pub fn letter(p: Prefix) []const u8 {
        return switch (p) {
            .atto => "a",
            .femto => "f",
            .pico => "p",
            .nano => "n",
            .micro => "u",
            .milli => "m",
            .base => "",
            .kilo => "k",
            .mega => "M",
            .giga => "G",
        };
    }
};

/// `lhs * rhs => out`. Capacitance and inductance are terminal.
const products = [_]struct { Dimension, Dimension, Dimension }{
    .{ .length, .length, .area },
    .{ .current, .resistance, .voltage },
};

/// `num / den => out`.
const quotients = [_]struct { Dimension, Dimension, Dimension }{
    .{ .voltage, .current, .resistance },
    .{ .voltage, .resistance, .current },
    .{ .current, .length, .current_density },
};

/// A count of `10^prefix` base units of `dim`. `raw` is unchecked: a NaN is
/// stored as given, and `isFinite` is how a consumer refuses it.
pub fn Qty(comptime dim: Dimension, comptime prefix: Prefix) type {
    return struct {
        raw: f64,

        const Self = @This();
        pub const dimension = dim;
        pub const exponent = prefix;

        /// The value in base units: `3 aF` gives `3e-18`.
        pub fn base(q: Self) f64 {
            return q.to(.base).raw;
        }

        /// Restates at prefix `p`. One multiply: at `p == prefix` the factor
        /// is exactly 1.0, so the value comes back bit for bit.
        pub fn to(q: Self, comptime p: Prefix) Qty(dim, p) {
            const factor = comptime powi(10.0, @as(i32, @backingInt(prefix)) - @backingInt(p));
            return .{ .raw = q.raw * factor };
        }

        /// A NaN limit compares false against everything and silently passes
        /// a rule, so reports check this.
        pub fn isFinite(q: Self) bool {
            return std.math.isFinite(q.raw);
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .raw = a.raw + b.raw };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .raw = a.raw - b.raw };
        }

        pub fn neg(q: Self) Self {
            return .{ .raw = -q.raw };
        }

        /// Scales by a dimensionless factor.
        pub fn scale(q: Self, factor: f64) Self {
            return .{ .raw = q.raw * factor };
        }

        /// Writes `<value> <prefix><symbol>`: `1.8 V`, `3 aF`, `200 mohm`.
        /// The value is the shortest round-tripping decimal (`{d}`), so a
        /// report diff is about the number. Use with `{f}`.
        pub fn format(q: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{d} {s}{s}", .{ q.raw, prefix.letter(), dim.symbol() });
        }
    };
}

/// A Celsius reading as an absolute temperature: the one place the 273.15
/// offset appears.
pub fn celsius(degrees: f64) Qty(.temperature, .base) {
    return .{ .raw = degrees + 273.15 };
}

/// Product of two quantities of any prefixes, at `.base`. Declared pairs only,
/// either order: length × length, current × resistance.
pub fn mul(a: anytype, b: anytype) Product(@TypeOf(a), @TypeOf(b)) {
    return .{ .raw = a.base() * b.base() };
}

/// Quotient of two quantities. Same dimension: the bare `f64` ratio (an
/// antenna ratio; both prefixes must match so they cancel). Otherwise the
/// declared quotients at `.base`: V/I, V/R, I/L. A zero denominator gives inf,
/// not an error: a zero resistance is a legal short.
pub fn div(a: anytype, b: anytype) Quotient(@TypeOf(a), @TypeOf(b)) {
    const ratio = comptime Quotient(@TypeOf(a), @TypeOf(b)) == f64;
    return if (ratio) a.raw / b.raw else .{ .raw = a.base() / b.base() };
}

pub fn Product(comptime A: type, comptime B: type) type {
    const out: Dimension = for (products) |p| {
        if (p[0] == A.dimension and p[1] == B.dimension) break p[2];
        if (p[1] == A.dimension and p[0] == B.dimension) break p[2];
    } else @compileError("no product " ++ @tagName(A.dimension) ++ " * " ++ @tagName(B.dimension));
    return Qty(out, .base);
}

pub fn Quotient(comptime A: type, comptime B: type) type {
    if (A == B) return f64;
    if (A.dimension == B.dimension) @compileError("a ratio needs both operands at one prefix");
    const out: Dimension = for (quotients) |q| {
        if (q[0] == A.dimension and q[1] == B.dimension) break q[2];
    } else @compileError("no quotient " ++ @tagName(A.dimension) ++ " / " ++ @tagName(B.dimension));
    return Qty(out, .base);
}

/// `base^exponent` by square-and-multiply, the same steps as compiler-rt's
/// `__powidf2` that Rust's `f64::powi` lowers to, so scale factors match the
/// Rust tool bit for bit.
pub fn powi(base: f64, exponent: i32) f64 {
    var result: f64 = 1.0;
    var square = base;
    var n = exponent;
    while (true) {
        if (n & 1 != 0) result *= square;
        n = @divTrunc(n, 2);
        if (n == 0) break;
        square *= square;
    }
    return if (exponent < 0) 1.0 / result else result;
}

test "powi matches exact powers of ten" {
    // Oracle: closed form. 10^k is exact in f64 for |k| <= 22.
    try std.testing.expectEqual(@as(f64, 1e22), powi(10.0, 22));
    try std.testing.expectEqual(@as(f64, 1.0), powi(10.0, 0));
    try std.testing.expectEqual(1.0 / 1e9, powi(10.0, -9));
}
