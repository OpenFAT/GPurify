//! The closed forms of Weste & Harris, *CMOS VLSI Design* 4e (2011), ch. 6,
//! in the deck's units. In: deck coefficients (Ω/□, Ω per cut, aF/µm²,
//! aF/µm) and geometry in database units on a `Grid`. Out: Ω and fF. Ported
//! from the formula half of crates/extract/src/analytical.rs.
//!
//! Contents:
//! - `pub const epsilon0_af_per_um: f64`, `pub const nm_per_um: f64`
//! - `pub fn micrometres(v: Dbu, grid: Grid) f64`
//! - `pub fn segmentResistance(sheet_ohm_sq: f64, length: Dbu, width: Dbu) f64`
//! - `pub fn viaResistance(per_cut_ohm: f64, cuts: u32) f64`
//! - `pub fn groundCapacitance(area_af_um2: f64, fringe_af_um: f64, area: DbuArea, perimeter: Dbu, grid: Grid) f64`
//! - `pub fn couplingCapacitance(coefficient_af_um: f64, facing: Dbu, separation: Dbu, grid: Grid) f64`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Grid = geom.Grid;

/// Vacuum permittivity, attofarads per micrometre (CODATA 2018).
pub const epsilon0_af_per_um: f64 = 8.8541878128;

pub const nm_per_um: f64 = 1000.0;

/// Divided by, never multiplied by `1e-3`, which is not exact in `f64`.
const af_per_ff: f64 = 1000.0;

const grid_1nm: Grid = .{ .dbu_per_um = 1000 };

/// `|v| <= 2^41`, exact in `f64`.
pub fn micrometres(v: Dbu, grid: Grid) f64 {
    return @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(grid.dbu_per_um));
}

/// Series resistance of a run, `sheet × length / width`, Ω. `width` must be
/// positive.
pub fn segmentResistance(sheet_ohm_sq: f64, length: Dbu, width: Dbu) f64 {
    return sheet_ohm_sq * (@as(f64, @floatFromInt(length)) / @as(f64, @floatFromInt(width)));
}

/// A via array's resistance, Ω: per cut over the cut count, the cuts in
/// parallel.
pub fn viaResistance(per_cut_ohm: f64, cuts: u32) f64 {
    return per_cut_ohm / @as(f64, @floatFromInt(cuts));
}

/// Capacitance to the plane beneath, fF: `area × area_coeff + perimeter ×
/// fringe_coeff`, two separate products so `f(a, 0) + f(0, b) == f(a, b)`
/// holds exactly.
pub fn groundCapacitance(area_af_um2: f64, fringe_af_um: f64, area: DbuArea, perimeter: Dbu, grid: Grid) f64 {
    const per_um: f64 = @floatFromInt(grid.dbu_per_um);
    const plate = area_af_um2 * (@as(f64, @floatFromInt(area)) / (per_um * per_um));
    const fringe = fringe_af_um * micrometres(perimeter, grid);
    return (plate + fringe) / af_per_ff;
}

/// Capacitance between two facing sidewalls, fF: `k × L / S`, `k` in aF per
/// µm at 1 µm. `separation` must be positive.
pub fn couplingCapacitance(coefficient_af_um: f64, facing: Dbu, separation: Dbu, grid: Grid) f64 {
    const ratio = micrometres(facing, grid) / micrometres(separation, grid);
    return coefficient_af_um * ratio / af_per_ff;
}

// ---- private ----

fn expectRelative(got: f64, want: f64, tolerance: f64) !void {
    try std.testing.expectApproxEqRel(want, got, tolerance);
}

test "a ten square run of a hundred milliohm layer is one ohm" {
    // Oracle: closed form, `0.1 × 10` written out; no implementation is
    // consulted to know it.
    try std.testing.expectApproxEqAbs(1.0, segmentResistance(0.1, 10_000, 1_000), 1e-12);
}

test "sheet resistance depends on aspect ratio and not on absolute size" {
    // Oracle: closed form. Squares are dimensionless, so one aspect ratio at
    // three wildly different sizes is one resistance; a stray grid factor
    // fails this and passes the worked example.
    const reference = segmentResistance(2.5, 400, 100);
    try std.testing.expectApproxEqAbs(10.0, reference, 1e-12);
    for ([_]i64{ 1, 97, 1_000_000 }) |scale| try expectRelative(segmentResistance(2.5, 400 * scale, 100 * scale), reference, 1e-12);
}

test "segment resistance adds when a run is cut in half" {
    // Oracle: law. Resistance in series adds, for any width and sheet.
    for ([_]f64{ 0.05, 1.0, 42.0 }) |sheet| {
        for ([_]i64{ 3, 250, 90_000 }) |w| try expectRelative(segmentResistance(sheet, 15_000, w), 2.0 * segmentResistance(sheet, 7_500, w), 1e-12);
    }
}

test "doubling conductor width halves its resistance" {
    // Oracle: law. Width is the denominator of the square count.
    try expectRelative(segmentResistance(0.7, 5_000, 500), segmentResistance(0.7, 5_000, 250) / 2.0, 1e-12);
}

test "via resistance divides by the number of cuts" {
    // Oracle: closed form. A 5 Ω cut is 5 Ω alone and 1.25 Ω in a four-cut
    // array: cuts are resistors in parallel.
    try std.testing.expectApproxEqAbs(5.0, viaResistance(5.0, 1), 1e-12);
    try std.testing.expectApproxEqAbs(2.5, viaResistance(5.0, 2), 1e-12);
    try std.testing.expectApproxEqAbs(1.25, viaResistance(5.0, 4), 1e-12);
}

test "via conductance adds over every cut count" {
    // Oracle: law. Conductances add, so `n` cuts is `1/n` of one, for every
    // `n`, not only the sizes a special case would have seen.
    const one = viaResistance(3.3, 1);
    for (1..65) |cuts| try expectRelative(viaResistance(3.3, @intCast(cuts)) * @as(f64, @floatFromInt(cuts)), one, 1e-12);
}

test "a four by nine micrometre plate is seventy one point six attofarads" {
    // Oracle: closed form. 36 µm² and 26 µm at 1.7 aF/µm² and 0.4 aF/µm:
    // `1.7 × 36 + 0.4 × 26 = 71.6` aF, 0.0716 fF. The one case that catches
    // a formula off by the grid factor itself.
    try std.testing.expectApproxEqAbs(0.0716, groundCapacitance(1.7, 0.4, 4_000 * 9_000, 2 * (4_000 + 9_000), grid_1nm), 1e-12);
}

test "ground capacitance superposes its area and fringe terms" {
    // Oracle: law. Area plus fringe, computed together or apart, agree; both
    // terms must contribute.
    const area: DbuArea = 4_000 * 9_000;
    const perimeter: Dbu = 2 * (4_000 + 9_000);
    const both = groundCapacitance(1.7, 0.4, area, perimeter, grid_1nm);
    const area_only = groundCapacitance(1.7, 0.0, area, perimeter, grid_1nm);
    const fringe_only = groundCapacitance(0.0, 0.4, area, perimeter, grid_1nm);
    try std.testing.expect(area_only > 0.0 and fringe_only > 0.0);
    try expectRelative(both, area_only + fringe_only, 1e-12);
}

test "ground capacitance is linear in each deck coefficient" {
    // Oracle: law. Each term is its coefficient times a geometric quantity.
    const area: DbuArea = 2_500 * 2_500;
    const perimeter: Dbu = 4 * 2_500;
    const reference = groundCapacitance(1.0, 1.0, area, perimeter, grid_1nm);
    const area_share = groundCapacitance(1.0, 0.0, area, perimeter, grid_1nm);
    try expectRelative(groundCapacitance(3.0, 1.0, area, perimeter, grid_1nm), reference + 2.0 * area_share, 1e-12);
    const fringe_share = groundCapacitance(0.0, 1.0, area, perimeter, grid_1nm);
    try expectRelative(groundCapacitance(1.0, 3.0, area, perimeter, grid_1nm), reference + 2.0 * fringe_share, 1e-12);
}

test "the fringe share of a square plate falls inversely with the plate side" {
    // Oracle: closed form, as a limit. For a square of side `s` the fringe
    // term goes as `4s` and the area term as `s²`, so a thousandfold wider
    // plate has a thousandth the fringe share, whatever a unit is worth; and
    // at a billion units the total is the plate plus exactly that share.
    const Share = struct {
        fn of(side: i64) !f64 {
            const area: DbuArea = @as(DbuArea, side) * side;
            const plate = groundCapacitance(1.0, 0.0, area, 4 * side, grid_1nm);
            const fringe = groundCapacitance(0.0, 1.0, area, 4 * side, grid_1nm);
            try std.testing.expect(plate > 0.0 and fringe > 0.0);
            return fringe / plate;
        }
    };
    const small = try Share.of(1_000);
    const large = try Share.of(1_000_000);
    const vast = try Share.of(1_000_000_000);
    try std.testing.expect(small > large and large > vast);
    try expectRelative(small / large, 1000.0, 1e-9);
    try expectRelative(large / vast, 1000.0, 1e-9);
    const area: DbuArea = 1_000_000_000 * 1_000_000_000;
    const total = groundCapacitance(1.0, 1.0, area, 4_000_000_000, grid_1nm);
    const plate = groundCapacitance(1.0, 0.0, area, 4_000_000_000, grid_1nm);
    try expectRelative(total / plate, 1.0 + vast, 1e-12);
}

test "coupling capacitance scales with facing length and falls with separation" {
    // Oracle: law. Proportional to the facing length and the coefficient,
    // strictly falling with separation.
    const reference = couplingCapacitance(2.0, 6_000, 300, grid_1nm);
    try std.testing.expect(reference > 0.0);
    try expectRelative(couplingCapacitance(2.0, 12_000, 300, grid_1nm), 2.0 * reference, 1e-12);
    try expectRelative(couplingCapacitance(4.0, 6_000, 300, grid_1nm), 2.0 * reference, 1e-12);
    var previous = std.math.inf(f64);
    for ([_]i64{ 100, 300, 900, 2_700, 8_100 }) |s| {
        const v = couplingCapacitance(2.0, 6_000, s, grid_1nm);
        try std.testing.expect(v > 0.0 and v < previous);
        previous = v;
    }
}
