//! Integer layout coordinates and the exact conversion to physical length.
//! In: raw `i64` counts and `Qty(.length, _)` lengths. Out: `Dbu`
//! coordinates within ±`max_abs_dbu`, `DbuArea` products, and lengths back in
//! nanometres. A length converts exactly or not at all: rounding a spacing
//! limit down passes shapes the foundry would reject.
//!
//! Contents:
//! - `pub const Dbu = i64`, `pub const DbuArea = i128`
//! - `pub const max_abs_dbu: Dbu`
//! - `pub fn inDomain(raw: i64) bool`
//! - `pub fn mulWide(a: Dbu, b: Dbu) DbuArea`
//! - `pub const GridError = error{ NotFinite, NotOnGrid, OutOfRange, BadResolution }`
//! - `pub const Grid = struct`, `Grid.init(dbu_per_um: i64) GridError!Grid`,
//!   `Grid.toDbu(grid: Grid, length: anytype) GridError!Dbu`,
//!   `Grid.toLength(grid: Grid, coord: Dbu) Qty(.length, .nano)`

const std = @import("std");
const assert = std.debug.assert;
const qty = @import("qty.zig");
const Qty = qty.Qty;

/// One coordinate on a layout's `Grid`, in database units. Every coordinate a
/// reader stores lies within ±`max_abs_dbu` (`inDomain`). Sums and
/// differences may leave that range (a box's width can be `2^41`); a computed
/// value re-enters stored geometry only after an `inDomain` check.
pub const Dbu = i64;

/// An area or squared distance in square database units. The product of two
/// in-domain `Dbu` is at most `2^80`, so `mulWide` never overflows.
pub const DbuArea = i128;

/// `2^40`: two in-domain coordinates multiply to at most `2^80`, which keeps
/// `DbuArea` overflow-free, and `2^40 * 1000 < 2^53` keeps `toLength` exact.
pub const max_abs_dbu: Dbu = 1 << 40;

/// Each member is checked in declaration order by `Grid.toDbu`, except
/// `BadResolution`, which only `Grid.init` returns.
pub const GridError = error{
    /// The length was NaN or an infinity.
    NotFinite,
    /// The length is not a whole number of grid units, including a non-zero
    /// length too small to reach one unit.
    NotOnGrid,
    /// The length is outside ±`max_abs_dbu` units.
    OutOfRange,
    /// The resolution was zero or negative.
    BadResolution,
};

/// The resolution a layout is expressed on, from its GDSII `UNITS` record.
/// Invariant: `dbu_per_um > 0`, established by `init`.
pub const Grid = struct {
    /// Database units per micrometre: `1000` for a 1 nm grid.
    dbu_per_um: i64,

    pub fn init(dbu_per_um: i64) GridError!Grid {
        if (dbu_per_um <= 0) return error.BadResolution;
        return .{ .dbu_per_um = dbu_per_um };
    }

    /// Converts a `Qty(.length, _)` to grid units, exactly or not at all.
    /// Errors in this order, which is part of the interface: `NotFinite`,
    /// `OutOfRange`, `NotOnGrid`.
    pub fn toDbu(grid: Grid, length: anytype) GridError!Dbu {
        const L = @TypeOf(length);
        comptime assert(L.dimension == .length);
        assert(grid.dbu_per_um > 0);
        if (!length.isFinite()) return error.NotFinite;

        // A separate power-of-ten multiply or divide, never one factor:
        // 10^-3 is inexact in f64.
        const exponent = comptime @as(i32, @backingInt(L.exponent)) + 6;
        const per_um: f64 = @floatFromInt(grid.dbu_per_um);
        const units = if (exponent >= 0)
            length.raw * (comptime qty.powi(10.0, exponent)) * per_um
        else
            length.raw * per_um / (comptime qty.powi(10.0, -exponent));

        // Negated rather than `>`, so a NaN born of `0 * inf` is refused.
        if (!(@abs(units) <= @as(f64, @floatFromInt(max_abs_dbu)))) return error.OutOfRange;
        // Second clause: a non-zero length that underflowed to 0 is refused.
        if (units != @trunc(units) or (units == 0.0 and length.raw != 0.0)) return error.NotOnGrid;
        return @intFromFloat(units);
    }

    /// Converts a coordinate to nanometres. Total: the result is the
    /// correctly rounded `coord * 1000 / dbu_per_um`, and for an in-domain
    /// coordinate the numerator is exact, so `toDbu(toLength(c)) == c`.
    pub fn toLength(grid: Grid, coord: Dbu) Qty(.length, .nano) {
        const c: f64 = @floatFromInt(coord);
        return .{ .raw = c * 1000.0 / @as(f64, @floatFromInt(grid.dbu_per_um)) };
    }
};

/// Whether `raw` lies within ±`max_abs_dbu`. Defined on `minInt(i64)` too.
pub fn inDomain(raw: i64) bool {
    return @abs(raw) <= max_abs_dbu;
}

/// The only route from coordinates to an area. Exact for any two `i64`.
pub fn mulWide(a: Dbu, b: Dbu) DbuArea {
    return @as(DbuArea, a) * b;
}
