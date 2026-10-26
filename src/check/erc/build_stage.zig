//! The process-stage and electrical kinds' row builders: `antenna`,
//! `antenna_electrical`, `density_cmp`, `electromigration`, `em_rms`,
//! `em_peak`, `em_current_density`, `em_thermal`, `p2p_resistance`, and the
//! head-only kinds. In: one deck row (`Ctx`). Out: its columns pushed onto
//! its kind's table, parameters read in Rust's order (which decides the
//! first error). Ported from crates/check/src/erc/ruleset.rs
//! (`RuleSet::from_deck`, those arms).
//!
//! Contents:
//! - `pub fn antenna(c: Ctx) Error!void`, `antennaElectrical`, `densityCmp`, `electromigration`,
//!   `emAc(c: Ctx, t: *EmAcTable) Error!void`, `emCurrentDensity`, `emThermal`, `p2pResistance`,
//!   `noLayers(c: Ctx, h: *RuleHead) Error!void`

const std = @import("std");
const geom = @import("geom");
const LayerId = geom.LayerId;
const Error = @import("../drc/params.zig").Error;
const RuleHead = @import("head.zig").RuleHead;
const compile = @import("compile.zig");
const Ctx = compile.Ctx;
const pushCsr = compile.pushCsr;
const antenna_ = @import("antenna_tables.zig");
const AntennaMeasure = antenna_.AntennaMeasure;
const electrical = @import("electrical_tables.zig");
const EmAcTable = electrical.EmAcTable;
const CurrentDensity = electrical.CurrentDensity;

pub fn antenna(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(2);
    const max_ratio = try row.number("max_ratio");
    const measure = try row.antennaMeasure();
    const diode = try row.optLayer("diode_layer");
    const diode_area = try row.optArea("diode_area");
    const diode_min = try row.optArea("diode_min");
    const t = &c.rs.tables.antenna;
    try row.head(c.gpa, &t.head);
    try t.gate.append(c.gpa, layers[0]);
    try t.diode.append(c.gpa, diode);
    try t.diode_area.append(c.gpa, diode_area);
    try t.diode_min.append(c.gpa, diode_min);
    for (layers[1..]) |l| try t.collector_measure.append(c.gpa, cutByArea(c, l, measure));
    try t.max_ratio.append(c.gpa, max_ratio);
    try pushCsr(c.gpa, &t.collector_start, &t.collector, layers[1..]);
}

pub fn antennaElectrical(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(2);
    const max_ratio = try row.number("max_ratio");
    const measure = try row.antennaMeasure();
    const diode = try row.optLayer("diode_layer");
    const credit = try row.optNumber("diode_credit") orelse 0.0;
    const bonus = try row.optNumber("diode_bonus") orelse 0.0;
    const minus = try row.optNumber("area_minus_diode") orelse 0.0;
    const plus = try row.optNumber("gate_plus_diode") orelse 0.0;
    const reduce = try row.areaTable("diode_reduce_area", "diode_reduce");
    const diode_max = try row.areaTable("diode_max_ratio_area", "diode_max_ratio");
    const cut_factor = try row.number("cut_factor");
    const exempt = try row.optLayer("exempt_layer");
    const t = &c.rs.tables.antenna_electrical;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.gate.append(gpa, layers[0]);
    for (layers[1..]) |l| try t.collector_measure.append(gpa, cutByArea(c, l, measure));
    try pushCsr(gpa, &t.collector_start, &t.collector, layers[1..]);
    try t.cut_factor.append(gpa, cut_factor);
    try t.diode.append(gpa, diode);
    try t.diode_credit.append(gpa, credit);
    try t.diode_bonus.append(gpa, bonus);
    try t.area_minus_diode.append(gpa, minus);
    try t.gate_plus_diode.append(gpa, plus);
    try pushCsr(gpa, &t.diode_reduce_start, &t.diode_reduce, reduce);
    try pushCsr(gpa, &t.diode_max_ratio_start, &t.diode_max_ratio, diode_max);
    try t.exempt.append(gpa, exempt);
    try t.max_ratio.append(gpa, max_ratio);
}

pub fn densityCmp(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(1);
    const window = [2]geom.Dbu{ try row.length("window_x"), try row.length("window_y") };
    const step = [2]geom.Dbu{ try row.length("step_x"), try row.length("step_y") };
    const min_density = try row.optNumber("min_density");
    const max_density = try row.optNumber("max_density");
    const max_delta = try row.optNumber("max_neighbour_delta");
    const partial = try row.flagOr("include_partial_windows", true);
    // The three coefficients are one model: all or none.
    const cmp: ?antenna_.CmpModel = if (row.r.stated("cmp_target_density")) .{
        .target_density = try row.number("cmp_target_density"),
        .thickness_sensitivity = try row.length("cmp_thickness_sensitivity"),
        .max_abs_thickness_delta = try row.length("cmp_max_abs_thickness_delta"),
    } else null;
    const t = &c.rs.tables.density_cmp;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.layer.append(gpa, layers[0]);
    try t.window.append(gpa, window);
    try t.step.append(gpa, step);
    try t.min_density.append(gpa, min_density);
    try t.max_density.append(gpa, max_density);
    try t.max_neighbour_delta.append(gpa, max_delta);
    try t.cmp.append(gpa, cmp);
    try t.include_partial_windows.append(gpa, partial);
}

pub fn electromigration(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(1);
    const max_density: CurrentDensity = .{ .raw = try row.number("max_density") };
    const per_cut = try row.number("max_current_per_cut");
    const blech = try row.number("blech_limit");
    const reference = try row.number("reference_temperature");
    const activation = try row.number("activation_energy_ev");
    const exponent = try row.number("current_exponent");
    const t = &c.rs.tables.electromigration;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.max_density.appendNTimes(gpa, max_density, layers.len);
    try t.max_current_per_cut.appendNTimes(gpa, .{ .raw = per_cut }, layers.len);
    try t.blech_limit.appendNTimes(gpa, .{ .raw = blech }, layers.len);
    try t.reference_temperature.append(gpa, .{ .raw = reference });
    try t.activation_energy_ev.append(gpa, activation);
    try t.current_exponent.append(gpa, exponent);
    try pushCsr(gpa, &t.layer_start, &t.layer, layers);
}

pub fn emAc(c: Ctx, t: *EmAcTable) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(1);
    const frequency = try row.numbers("frequency");
    const width = try row.lengths("width");
    const density = try row.numbers("density");
    const per_cut = try row.number("max_current_per_cut");
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try pushCsr(gpa, &t.layer_start, &t.layer, layers);
    try pushCsr(gpa, &t.frequency_start, &t.frequency, frequency);
    try pushCsr(gpa, &t.width_start, &t.width, width);
    if (t.density_start.items.len == 0) try t.density_start.append(gpa, 0);
    for (density) |v| try t.density.append(gpa, .{ .raw = v });
    try t.density_start.append(gpa, @intCast(t.density.items.len));
    try t.max_current_per_cut.append(gpa, .{ .raw = per_cut });
}

pub fn emCurrentDensity(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(1);
    const max_density = try row.number("max_density");
    const per_cut = try row.number("max_current_per_cut");
    // The band's width and current are one statement: both or none.
    const narrow: ?electrical.Narrow = if (try row.optLength("narrow_width")) |w| .{ .width = w, .current = .{ .raw = try row.number("narrow_current") } } else null;
    const t = &c.rs.tables.em_current_density;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.max_density.appendNTimes(gpa, .{ .raw = max_density }, layers.len);
    try t.max_current_per_cut.appendNTimes(gpa, .{ .raw = per_cut }, layers.len);
    try t.narrow.appendNTimes(gpa, narrow, layers.len);
    try pushCsr(gpa, &t.layer_start, &t.layer, layers);
}

pub fn emThermal(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(1);
    const max_density = try row.number("max_density");
    const per_cut = try row.number("max_current_per_cut");
    const blech = try row.number("blech_limit");
    const reference = try row.number("reference_temperature");
    const activation = try row.number("activation_energy_ev");
    const exponent = try row.number("current_exponent");
    const conductivity = try row.number("thermal_conductivity");
    const spreading = try row.number("heat_spreading");
    const sigma = try row.number("sigma");
    const limit_failure = try row.number("limit_failure");
    const max_failure = try row.number("max_failure");
    const t = &c.rs.tables.em_thermal;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.max_density.appendNTimes(gpa, .{ .raw = max_density }, layers.len);
    try t.max_current_per_cut.appendNTimes(gpa, .{ .raw = per_cut }, layers.len);
    try t.blech_limit.appendNTimes(gpa, .{ .raw = blech }, layers.len);
    try t.reference_temperature.append(gpa, .{ .raw = reference });
    try t.activation_energy_ev.append(gpa, activation);
    try t.current_exponent.append(gpa, exponent);
    try t.thermal_conductivity.append(gpa, conductivity);
    try t.heat_spreading.append(gpa, spreading);
    try t.sigma.append(gpa, sigma);
    try t.limit_failure.append(gpa, limit_failure);
    try t.max_failure.append(gpa, max_failure);
    try pushCsr(gpa, &t.layer_start, &t.layer, layers);
}

pub fn p2pResistance(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const max_resistance = try c.row.number("max_resistance");
    const t = &c.rs.tables.p2p_resistance;
    try c.row.head(c.gpa, &t.head);
    try t.max_resistance.append(c.gpa, .{ .raw = max_resistance });
}

/// A kind with no layer and no parameter: the head alone.
pub fn noLayers(c: Ctx, h: *RuleHead) Error!void {
    _ = try c.row.layers(0);
    try c.row.head(c.gpa, h);
}

// ---- private ----

/// A cut collects by its area whatever the row's measure: LEF's cut
/// layers "do not use side area modelling".
fn cutByArea(c: Ctx, layer: LayerId, measure: AntennaMeasure) AntennaMeasure {
    return if (std.mem.indexOfScalar(LayerId, c.deck.connectivity.via_cut, layer) != null) .area else measure;
}
