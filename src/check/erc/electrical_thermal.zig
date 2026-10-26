//! Thermal-aware and statistical electromigration (`em_thermal`): each
//! grid edge derated by Black's equation to its own temperature (the run's
//! plus its Joule self-heating, Banerjee et al. eqs. 7, 8, 10, 14), and the
//! chip's weakest-link failure probability over every mortal edge, each a
//! lognormal about Black's median (JEP122). In: a solved supply grid, the
//! layer heights, one table. Out: violations and each row's run. Ported
//! from crates/check/src/erc/rules/electrical.rs (`ThermalRow`,
//! `edge_temperatures`, `check_thermal_branches`, `check_em_thermal`'s row
//! loop, `normal_cdf`, `erfc_of_magnitude`, `normal_quantile`).
//!
//! Contents:
//! - `pub fn thermalRows(r: Record, solved: Solved, grid: Grid, operating: Kelvin, t: *const EmThermalTable, height_nm: []const f64) Allocator.Error!void`
//! - `pub fn normalCdf(z: f64) f64`, `pub fn normalQuantile(p: f64) f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Microamps = report.Microamps;
const Record = @import("head.zig").Record;
const grid_ = @import("power_grid.zig");
const Solved = grid_.Solved;
const electrical = @import("electrical_tables.zig");
const CurrentDensity = electrical.CurrentDensity;
const Kelvin = electrical.Kelvin;
const EmThermalTable = electrical.EmThermalTable;
const allowedCurrent = @import("em_allowed.zig").allowedCurrent;
const current = @import("electrical_current.zig");
const Head = current.Head;

/// One row, borrowed.
const Row = struct {
    head: Head,
    layer: []const LayerId,
    max_density: []const CurrentDensity,
    max_current_per_cut: []const Microamps,
    blech_limit: []const Microamps,
    reference: Kelvin,
    activation_energy_ev: f64,
    current_exponent: f64,
    sigma: f64,
    /// `Φ⁻¹(limit_failure)`.
    limit_z: f64,
    max_failure: f64,
};

/// Every `em_thermal` row over the solved grid, each edge at its own
/// temperature above `operating`. `examined` counts the row's mortal
/// in-scope edges; the chip's finding follows the edges', at the edge
/// likeliest to fail, a ratio against `max_failure`. A row refuses when its
/// parameters are unusable.
pub fn thermalRows(r: Record, solved: Solved, grid: Grid, operating: Kelvin, t: *const EmThermalTable, height_nm: []const f64) Allocator.Error!void {
    const gpa = r.gpa;
    var blech: std.ArrayList(f64) = .empty;
    defer blech.deinit(gpa);
    try current.blechProductsInto(gpa, solved.grid, solved.solution, &blech);
    const temperature = try gpa.alloc(f64, solved.grid.edgeCount());
    defer gpa.free(temperature);
    for (t.head.rule.items, t.head.severity.items, 0..) |id, severity, row| {
        const before = r.out.len();
        const sigma = t.sigma.items[row];
        const limit_failure = t.limit_failure.items[row];
        const max_failure = t.max_failure.items[row];
        const conductivity = t.thermal_conductivity.items[row];
        const spreading = t.heat_spreading.items[row];
        const usable = current.arrheniusDerating(operating, t.reference_temperature.items[row], t.activation_energy_ev.items[row], t.current_exponent.items[row]) != null and
            std.math.isFinite(sigma) and sigma > 0.0 and std.math.isFinite(conductivity) and conductivity > 0.0 and
            std.math.isFinite(spreading) and spreading >= 0.0 and limit_failure > 0.0 and limit_failure < 1.0 and
            max_failure > 0.0 and max_failure <= 1.0;
        if (!usable) {
            try r.run(id, before, .refused, 0);
            continue;
        }
        const from = t.layer_start.items[row];
        const to = t.layer_start.items[row + 1];
        const thermal: Row = .{
            .head = .{ .rule = id, .severity = severity },
            .layer = t.layer.items[from..to],
            .max_density = t.max_density.items[from..to],
            .max_current_per_cut = t.max_current_per_cut.items[from..to],
            .blech_limit = t.blech_limit.items[from..to],
            .reference = t.reference_temperature.items[row],
            .activation_energy_ev = t.activation_energy_ev.items[row],
            .current_exponent = t.current_exponent.items[row],
            .sigma = sigma,
            .limit_z = normalQuantile(limit_failure),
            .max_failure = max_failure,
        };
        try edgeTemperatures(gpa, solved, grid, height_nm, conductivity, spreading, operating.raw, temperature);
        const examined = try branches(r, solved, grid, &thermal, blech.items, temperature);
        try r.run(id, before, .ran, examined);
    }
}

/// `Φ(z) = erfc(-z / √2) / 2`, within about 1e-13 relative wherever it
/// does not underflow.
pub fn normalCdf(z: f64) f64 {
    const x = -z * std.math.sqrt1_2;
    const tail = 0.5 * erfcOfMagnitude(@abs(x));
    return if (x >= 0.0) tail else 1.0 - tail;
}

/// `z` with `Φ(z) = p` for `0 < p < 1`: bisection on `normalCdf` down to
/// adjacent floats.
pub fn normalQuantile(p: f64) f64 {
    var lo: f64 = -40.0;
    var hi: f64 = 40.0;
    while (true) {
        const mid = 0.5 * (lo + hi);
        if (mid <= lo or mid >= hi) return hi;
        if (normalCdf(mid) < p) lo = mid else hi = mid;
    }
}

// ---- private ----

/// Each edge's temperature into `out`: `run` plus a metal segment's own
/// rise `I² R θ`, `θ = t / (K L (W + φ t))`; a cut takes the larger rise of
/// the metal at its two nodes. No heat or height 0: no rise.
fn edgeTemperatures(gpa: Allocator, solved: Solved, grid: Grid, height_nm: []const f64, conductivity: f64, spreading: f64, run: f64, out: []f64) Allocator.Error!void {
    const power = solved.grid;
    const node_rise = try gpa.alloc(f64, power.nodeCount());
    defer gpa.free(node_rise);
    @memset(node_rise, 0.0);
    @memset(out, 0.0);
    for (0..power.edgeCount()) |e| {
        if (power.edge_kind.items[e] != .metal) continue;
        // Everything in SI: amperes, ohms, metres.
        const l = @backingInt(power.edge_layer.items[e]);
        const height = (if (l < height_nm.len) height_nm[l] else 0.0) * 1e-9;
        const amps = solved.solution.branch_current.items[e].base();
        const heat = amps * amps * power.edge_resistance.items[e].raw;
        if (!(height > 0.0 and heat > 0.0)) continue;
        const length = grid.toLength(power.edge_length.items[e]).base();
        const width = grid.toLength(power.edge_width.items[e]).base();
        const theta = height / (conductivity * length * (width + spreading * height));
        out[e] = heat * theta;
        for ([2]u32{ power.edge_from.items[e], power.edge_to.items[e] }) |n| node_rise[n] = @max(node_rise[n], out[e]);
    }
    for (0..power.edgeCount()) |e| if (power.edge_kind.items[e] != .metal) {
        out[e] = @max(node_rise[power.edge_from.items[e]], node_rise[power.edge_to.items[e]]);
    };
    for (out) |*v| v.* = run + v.*;
}

/// One row over every edge on its layers, then the chip's failure
/// probability against `max_failure`; returns the mortal in-scope edges.
fn branches(r: Record, solved: Solved, grid: Grid, row: *const Row, blech: []const f64, temperature: []const f64) Allocator.Error!u64 {
    const power = solved.grid;
    var examined: u64 = 0;
    // The log of the probability that no segment has failed, and the
    // segment likeliest to have.
    var survives: f64 = 0.0;
    var likeliest: ?struct { edge: u32, failed: f64 } = null;
    for (0..power.edgeCount()) |e| {
        const at = std.mem.indexOfScalar(LayerId, row.layer, power.edge_layer.items[e]) orelse continue;
        if (blech[e] <= row.blech_limit[at].raw) continue;
        examined += 1;
        // Too hot for any finite derating carries nothing.
        const derate = current.arrheniusDerating(.{ .raw = temperature[e] }, row.reference, row.activation_energy_ev, row.current_exponent) orelse 0.0;
        // An `em_thermal` row states no narrow-line band.
        const allowed = allowedCurrent(power.edge_kind.items[e], power.edge_width.items[e], grid, row.max_density[at], row.max_current_per_cut[at], null).scale(derate);
        const amps = @abs(solved.solution.branch_current.items[e].raw);
        const measured = Measurement.current(.{ .raw = amps });
        const limit = Measurement.current(allowed);
        if (measured.violates(limit, .maximum)) try current.edgeViolation(r, power, @intCast(e), row.head, measured, limit);
        // A segment that carries nothing does not wear.
        if (amps > 0.0) {
            const usage = amps / allowed.raw;
            const failed = normalCdf(row.limit_z + row.current_exponent / row.sigma * @log(usage));
            survives += std.math.log1p(-failed);
            if (likeliest == null or failed > likeliest.?.failed) likeliest = .{ .edge = @intCast(e), .failed = failed };
        }
    }
    if (likeliest) |l| {
        const measured = Measurement.ratio(-std.math.expm1(survives));
        const limit = Measurement.ratio(row.max_failure);
        if (measured.violates(limit, .maximum)) try current.edgeViolation(r, power, l.edge, row.head, measured, limit);
    }
    return examined;
}

/// `erfc(x)` for `x >= 0`: below 1.5 one minus the power series of A&S
/// 7.1.6 (all terms positive), from 1.5 their continued fraction 7.1.14,
/// evaluated from its 80th term back.
fn erfcOfMagnitude(x: f64) f64 {
    const gauss = @exp(-x * x);
    const two_sqrt_pi = std.math.two_sqrtpi;
    if (x < 1.5) {
        var term = x;
        var sum = x;
        for (1..50) |n| {
            term *= 2.0 * x * x / @as(f64, @floatFromInt(2 * n + 1));
            sum += term;
        }
        return 1.0 - two_sqrt_pi * gauss * sum;
    }
    var fraction = x;
    var k: u32 = 80;
    while (k >= 1) : (k -= 1) fraction = x + @as(f64, @floatFromInt(k)) / 2.0 / fraction;
    return 0.5 * two_sqrt_pi * gauss / fraction;
}

test "the normal distribution matches its tables" {
    // Oracle: published values of the standard normal distribution
    // (Abramowitz and Stegun Table 26.1 and its quantiles, to the digits the
    // C library's `erfc` gives): Φ(1), Φ(-5), Φ(-8) deep in the tail,
    // Φ(0) = 1/2, and the 0.1 % and 2.5 % quantiles. The series and the
    // continued fraction meet at |z| = 1.5 √2, so one value sits each side.
    for ([_][2]f64{ .{ 1.0, 0.841_344_746_068_542_9 }, .{ 0.0, 0.5 }, .{ -2.0, 0.022_750_131_948_179_21 }, .{ -2.2, 0.013_903_447_513_498_597 }, .{ -5.0, 2.866_515_718_791_939e-7 }, .{ -8.0, 6.220_960_574_271_784e-16 } }) |c| {
        try std.testing.expect(@abs((normalCdf(c[0]) - c[1]) / c[1]) <= 1e-12);
    }
    for ([_][2]f64{ .{ 0.001, -3.090_232_306_167_813 }, .{ 0.025, -1.959_963_984_540_054 } }) |c| {
        try std.testing.expect(@abs(normalQuantile(c[0]) - c[1]) <= 1e-12);
    }
}
