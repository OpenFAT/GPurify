//! The value checks `validate.zig` composes (`Check`: finite, positive,
//! not negative, a positive length, a fraction), and the longer per-kind
//! checks: the AC current tables, `em_thermal`, `esd_cross_domain`,
//! `esd_path`, `conditional_tie`, the model limits, `reliability` and
//! `voltage_spacing`. In: one row of one table. Out: nothing, or the first
//! failing value as a named error with the row and parameter in the
//! `Diagnostic`. Ported from crates/check/src/erc/ruleset.rs (`Check`,
//! `check_row`'s longer arms).
//!
//! Contents:
//! - `pub const Check = struct { rule, diag }`, `finite`, `positive`, `notNegative`, `length`, `fraction`,
//!   `nonPositive`, `missing`, `wrong`, `badTable`, `notAFraction`
//! - `pub fn span(items: anytype, start: []const u32, r: u32) @TypeOf(items)`, `pub fn empty(start: []const u32, r: u32) bool`
//! - `pub fn emAc(c: Check, t: *const EmAcTable, r: u32) Error!void`, `emThermal`, `esdCrossDomain`, `esdPath`,
//!   `conditionalTie`, `modelLimit`, `reliability`, `voltageSpacing`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const StrId = geom.StrId;
const params = @import("../drc/params.zig");
const Error = params.Error;
const Diagnostic = params.Diagnostic;
const electrical = @import("electrical_tables.zig");
const esd = @import("esd_tables.zig");
const latchup = @import("latchup_tables.zig");
const domain = @import("domain_tables.zig");

/// The value checks for one rule's row.
pub const Check = struct {
    rule: StrId,
    diag: *Diagnostic,

    fn fail(c: Check, err: Error, param: []const u8) Error {
        c.diag.* = .{ .rule = c.rule, .param = param };
        return err;
    }

    /// A finite number: an infinite limit would pass everything.
    pub fn finite(c: Check, param: []const u8, v: f64) Error!void {
        if (!std.math.isFinite(v)) return c.wrong(param);
    }

    /// A finite, strictly positive number.
    pub fn positive(c: Check, param: []const u8, v: f64) Error!void {
        try c.finite(param, v);
        if (!(v > 0.0)) return c.nonPositive(param);
    }

    /// A finite number of zero or more.
    pub fn notNegative(c: Check, param: []const u8, v: f64) Error!void {
        try c.finite(param, v);
        if (!(v >= 0.0)) return c.nonPositive(param);
    }

    /// A strictly positive distance.
    pub fn length(c: Check, param: []const u8, v: Dbu) Error!void {
        if (v <= 0) return c.nonPositive(param);
    }

    /// A fraction in `0 ..= 1`.
    pub fn fraction(c: Check, param: []const u8, v: f64) Error!void {
        try c.finite(param, v);
        if (!(v >= 0.0 and v <= 1.0)) return c.notAFraction(param);
    }

    pub fn nonPositive(c: Check, param: []const u8) Error {
        return c.fail(error.NonPositiveLimit, param);
    }

    pub fn missing(c: Check, param: []const u8) Error {
        return c.fail(error.MissingParam, param);
    }

    pub fn wrong(c: Check, param: []const u8) Error {
        return c.fail(error.WrongParamType, param);
    }

    pub fn notAFraction(c: Check, param: []const u8) Error {
        return c.fail(error.NotAFraction, param);
    }

    pub fn badTable(c: Check, why: []const u8) Error {
        c.diag.* = .{ .rule = c.rule, .why = why };
        return error.BadTable;
    }
};

/// Row `r`'s run of a CSR column.
pub fn span(items: anytype, start: []const u32, r: u32) @TypeOf(items) {
    return items[start[r]..start[r + 1]];
}

/// Row `r` of a CSR column is empty.
pub fn empty(start: []const u32, r: u32) bool {
    return start[r] == start[r + 1];
}

pub fn emAc(c: Check, t: *const electrical.EmAcTable, r: u32) Error!void {
    const frequencies = span(t.frequency.items, t.frequency_start.items, r);
    const widths = span(t.width.items, t.width_start.items, r);
    const density = span(t.density.items, t.density_start.items, r);
    for (frequencies) |f| try c.positive("frequency", f);
    for (widths) |w| if (w < 0) return c.nonPositive("width");
    for (density) |d| try c.positive("density", d.raw);
    try c.positive("max_current_per_cut", t.max_current_per_cut.items[r].raw);
    if (!strictlyRising(f64, frequencies) or !strictlyRising(Dbu, widths)) return c.badTable("an AC current table's frequencies and widths rise strictly");
    if (frequencies.len == 0 or widths.len == 0 or density.len != frequencies.len * widths.len) return c.badTable("an AC current table has one density per frequency and width");
}

pub fn emThermal(c: Check, t: *const electrical.EmThermalTable, r: u32) Error!void {
    const s = t.layer_start.items;
    for (span(t.max_density.items, s, r), span(t.max_current_per_cut.items, s, r), span(t.blech_limit.items, s, r)) |density, cut, blech| {
        try c.positive("max_density", density.raw);
        try c.positive("max_current_per_cut", cut.raw);
        try c.positive("blech_limit", blech.raw);
    }
    try c.positive("reference_temperature", t.reference_temperature.items[r].raw);
    try c.positive("activation_energy_ev", t.activation_energy_ev.items[r]);
    try c.positive("current_exponent", t.current_exponent.items[r]);
    try c.positive("thermal_conductivity", t.thermal_conductivity.items[r]);
    try c.positive("sigma", t.sigma.items[r]);
    // Zero spreading is a one-dimensional heat path; less is no geometry.
    try c.finite("heat_spreading", t.heat_spreading.items[r]);
    if (t.heat_spreading.items[r] < 0.0) return c.nonPositive("heat_spreading");
    // A characterisation at 0 or 1 has no quantile; a budget of 0 flags
    // any wire that carries current.
    for ([_]struct { []const u8, f64 }{ .{ "limit_failure", t.limit_failure.items[r] }, .{ "max_failure", t.max_failure.items[r] } }) |p| {
        try c.fraction(p[0], p[1]);
        if (p[1] <= 0.0) return c.nonPositive(p[0]);
    }
    if (t.limit_failure.items[r] >= 1.0) return c.notAFraction("limit_failure");
}

pub fn esdCrossDomain(c: Check, t: *const esd.EsdCrossDomainTable, r: u32) Error!void {
    if (empty(t.diode_start.items, r)) return c.missing("diode");
    const min_series = t.min_series.items[r];
    const ground = t.max_ground_resistance.items[r];
    const coupling = t.coupling_resistance.items[r];
    if (min_series) |v| try c.positive("min_series", v.raw);
    if (ground) |v| try c.positive("max_ground_resistance", v.raw);
    if (coupling) |v| try c.positive("coupling_resistance", v.raw);
    if (min_series != null and empty(t.resistor_start.items, r)) return c.missing("resistor");
    // The ground resistance and the coupling's are one statement.
    if (ground != null and coupling == null) return c.missing("coupling_resistance");
    if (ground == null and coupling != null) return c.missing("max_ground_resistance");
}

pub fn esdPath(c: Check, t: *const esd.EsdPathTable, r: u32) Error!void {
    try c.positive("current", t.current.items[r].raw);
    try c.positive("clamp_resistance", t.clamp_resistance.items[r].raw);
    const limits = [_]struct { []const u8, ?f64 }{
        .{ "max_resistance", raw(t.max_resistance.items[r]) },
        .{ "clamp_it2", raw(t.clamp_it2.items[r]) },
        .{ "max_density", raw(t.max_density.items[r]) },
        .{ "max_current_per_cut", raw(t.max_current_per_cut.items[r]) },
        .{ "max_voltage", raw(t.max_voltage.items[r]) },
    };
    var bounded = false;
    for (limits) |l| if (l[1]) |v| {
        try c.positive(l[0], v);
        bounded = true;
    };
    if (t.min_width.items[r]) |w| try c.length("min_width", w);
    if (t.clamp_voltage.items[r]) |v| try c.positive("clamp_voltage", v.raw);
    // A row bounding nothing would report clean forever.
    if (!bounded and t.min_width.items[r] == null) return c.missing("max_resistance");
}

pub fn conditionalTie(c: Check, t: *const latchup.ConditionalTieTable, r: u32) Error!void {
    try c.length("within", t.within.items[r]);
    const spacing = span(t.spacing.items, t.spacing_start.items, r);
    const limits = span(t.max_distance.items, t.max_distance_start.items, r);
    for (spacing) |v| try c.length("spacing", v);
    for (limits) |v| try c.length("max_distance", v);
    // One more limit than thresholds, thresholds ascending.
    if (limits.len != spacing.len + 1 or !strictlyRising(Dbu, spacing)) return c.wrong("max_distance");
}

pub fn modelLimit(c: Check, t: *const domain.ModelLimitTable, r: u32) Error!void {
    if (empty(t.model_start.items, r)) return c.missing("model");
    try c.positive("max_voltage", t.max_voltage.items[r].raw);
}

pub fn reliability(c: Check, t: *const esd.ReliabilityTable, r: u32) Error!void {
    try c.positive("required_lifetime_hours", t.required_lifetime_hours.items[r]);
    try c.positive("reference_lifetime_hours", t.reference_lifetime_hours.items[r]);
    try c.positive("reference_stress", t.reference_stress.items[r].raw);
    try c.positive("stress_exponent", t.stress_exponent.items[r]);
    try c.positive("reference_temperature", t.reference_temperature.items[r].raw);
    try c.positive("activation_energy_ev", t.activation_energy_ev.items[r]);
    try c.positive("max_abs_voltage", t.max_abs_voltage.items[r].raw);
    // A zero duty cycle makes every lifetime infinite.
    try c.fraction("duty_cycle", t.duty_cycle.items[r]);
    if (t.duty_cycle.items[r] <= 0.0) return c.nonPositive("duty_cycle");
}

pub fn voltageSpacing(c: Check, t: *const domain.VoltageSpacingTable, r: u32) Error!void {
    const voltage = span(t.voltage.items, t.step_start.items, r);
    const space = span(t.space.items, t.step_start.items, r);
    if (voltage.len == 0) return c.missing("voltage");
    for (voltage) |v| try c.finite("voltage", v.raw);
    var rising = voltage[0].raw >= 0.0;
    for (voltage[0 .. voltage.len - 1], voltage[1..]) |a, b| rising = rising and a.raw < b.raw;
    if (!rising) return c.badTable("a voltage table's voltages start at 0 V or more and rise strictly");
    for (space) |s| try c.length("space", s);
    for (space[0..space.len -| 1], space[@min(1, space.len)..]) |a, b| if (b < a) return c.badTable("a voltage table's spaces never fall as the voltage rises");
}

// ---- private ----

fn strictlyRising(comptime T: type, items: []const T) bool {
    for (items[0..items.len -| 1], items[@min(1, items.len)..]) |a, b| if (a >= b) return false;
    return true;
}

fn raw(v: anytype) ?f64 {
    return if (v) |x| x.raw else null;
}
