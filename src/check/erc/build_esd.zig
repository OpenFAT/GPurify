//! The ESD and reliability kinds' row builders: `esd_latchup`,
//! `esd_cross_domain`, `esd_exposed`, `esd_ground_coupling`,
//! `esd_parasitic`, `esd_path`, `esd_pin_pair`, `esd_clamp_resistance`,
//! `esd_topological`, `reliability` and `hv_domain`. In: one deck row
//! (`Ctx`). Out: its columns pushed onto its kind's table, parameters read
//! in Rust's order. Ported from crates/check/src/erc/ruleset.rs
//! (`RuleSet::from_deck`, those arms).
//!
//! Contents:
//! - `pub fn esdLatchup(c: Ctx) Error!void`, `esdCrossDomain`, `esdExposed`, `esdGroundCoupling`, `esdParasitic`,
//!   `esdPath`, `esdPinPair`, `esdClampResistance`, `esdTopological`, `reliability`, `hvDomain`

const std = @import("std");
const Error = @import("../drc/params.zig").Error;
const compile = @import("compile.zig");
const Ctx = compile.Ctx;
const pushCsr = compile.pushCsr;

pub fn esdLatchup(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(2);
    const width = try row.length("min_guard_ring_width");
    const tap = try row.length("max_tap_distance");
    const clamps = try row.models("clamp");
    const t = &c.rs.tables.esd_latchup;
    try row.head(c.gpa, &t.head);
    try t.pad.append(c.gpa, layers[0]);
    try pushCsr(c.gpa, &t.clamp_start, &t.clamp, clamps);
    try t.guard_ring.append(c.gpa, layers[1]);
    try t.min_guard_ring_width.append(c.gpa, width);
    try t.max_tap_distance.append(c.gpa, tap);
}

pub fn esdCrossDomain(c: Ctx) Error!void {
    const row = c.row;
    _ = try row.layers(0);
    const diodes = try row.models("diode");
    const local = try row.models("local");
    const t = &c.rs.tables.esd_cross_domain;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try pushCsr(gpa, &t.diode_start, &t.diode, diodes);
    try pushCsr(gpa, &t.local_start, &t.local, local);
    try pushCsr(gpa, &t.resistor_start, &t.resistor, try row.models("resistor"));
    try t.min_series.append(gpa, ohms(try row.optNumber("min_series")));
    try t.max_ground_resistance.append(gpa, ohms(try row.optNumber("max_ground_resistance")));
    try t.coupling_resistance.append(gpa, ohms(try row.optNumber("coupling_resistance")));
}

pub fn esdExposed(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(1);
    const clamps = try row.models("clamp");
    const resistors = try row.models("resistor");
    const rated = try row.models("rated");
    const min_series = ohms(try row.optNumber("min_series"));
    const t = &c.rs.tables.esd_exposed;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.pad.append(gpa, layers[0]);
    try pushCsr(gpa, &t.clamp_start, &t.clamp, clamps);
    try pushCsr(gpa, &t.resistor_start, &t.resistor, resistors);
    try pushCsr(gpa, &t.rated_start, &t.rated, rated);
    try t.min_series.append(gpa, min_series);
}

pub fn esdGroundCoupling(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const diodes = try c.row.models("diode");
    const t = &c.rs.tables.esd_ground_coupling;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.diode_start, &t.diode, diodes);
}

pub fn esdParasitic(c: Ctx) Error!void {
    const layers = try c.row.layers(2);
    const spacing = try c.row.length("min_spacing");
    const t = &c.rs.tables.esd_parasitic;
    try c.row.head(c.gpa, &t.head);
    try t.pad.append(c.gpa, layers[0]);
    try t.diffusion.append(c.gpa, layers[1]);
    try t.min_spacing.append(c.gpa, spacing);
}

pub fn esdPath(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layersFrom(1);
    if (layers.len > 2) _ = try row.layersWhere(2, false);
    const clamps = try row.models("clamp");
    const current = try row.number("current");
    const clamp_resistance = try row.number("clamp_resistance");
    const max_resistance = try row.optNumber("max_resistance");
    const clamp_it2 = try row.optNumber("clamp_it2");
    const max_density = try row.optNumber("max_density");
    const per_cut = try row.optNumber("max_current_per_cut");
    const max_voltage = try row.optNumber("max_voltage");
    const min_width = try row.optLength("min_width");
    const clamp_voltage = try row.optNumber("clamp_voltage");
    const t = &c.rs.tables.esd_path;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.pad.append(gpa, layers[0]);
    try t.source.append(gpa, layers[layers.len - 1]);
    try pushCsr(gpa, &t.clamp_start, &t.clamp, clamps);
    try t.current.append(gpa, .{ .raw = current });
    try t.clamp_resistance.append(gpa, .{ .raw = clamp_resistance });
    try t.max_resistance.append(gpa, ohms(max_resistance));
    try t.clamp_it2.append(gpa, if (clamp_it2) |v| .{ .raw = v } else null);
    try t.max_density.append(gpa, if (max_density) |v| .{ .raw = v } else null);
    try t.max_current_per_cut.append(gpa, if (per_cut) |v| .{ .raw = v } else null);
    try t.max_voltage.append(gpa, if (max_voltage) |v| .{ .raw = v } else null);
    try t.min_width.append(gpa, min_width);
    try t.clamp_voltage.append(gpa, if (clamp_voltage) |v| .{ .raw = v } else null);
}

pub fn esdPinPair(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(1);
    const clamps = try row.models("clamp");
    const current = try row.number("current");
    const clamp_resistance = try row.number("clamp_resistance");
    const max_resistance = try row.number("max_resistance");
    const t = &c.rs.tables.esd_pin_pair;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.pad.append(gpa, layers[0]);
    try pushCsr(gpa, &t.clamp_start, &t.clamp, clamps);
    try t.current.append(gpa, .{ .raw = current });
    try t.clamp_resistance.append(gpa, .{ .raw = clamp_resistance });
    try t.max_resistance.append(gpa, .{ .raw = max_resistance });
}

pub fn esdClampResistance(c: Ctx) Error!void {
    const layers = try c.row.layers(1);
    const clamps = try c.row.models("clamp");
    const max_resistance = try c.row.number("max_resistance");
    const t = &c.rs.tables.esd_clamp_resistance;
    try c.row.head(c.gpa, &t.head);
    try t.pad.append(c.gpa, layers[0]);
    try pushCsr(c.gpa, &t.clamp_start, &t.clamp, clamps);
    try t.max_resistance.append(c.gpa, .{ .raw = max_resistance });
}

pub fn esdTopological(c: Ctx) Error!void {
    const layers = try c.row.layers(1);
    const clamps = try c.row.models("clamp");
    const t = &c.rs.tables.esd_topological;
    try c.row.head(c.gpa, &t.head);
    try t.pad.append(c.gpa, layers[0]);
    try pushCsr(c.gpa, &t.clamp_start, &t.clamp, clamps);
}

pub fn reliability(c: Ctx) Error!void {
    const row = c.row;
    _ = try row.layers(0);
    const required = try row.number("required_lifetime_hours");
    const reference_life = try row.number("reference_lifetime_hours");
    const stress = try row.number("reference_stress");
    const exponent = try row.number("stress_exponent");
    const temperature = try row.number("reference_temperature");
    const activation = try row.number("activation_energy_ev");
    const max_abs = try row.number("max_abs_voltage");
    const duty = try row.number("duty_cycle");
    const t = &c.rs.tables.reliability;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.required_lifetime_hours.append(gpa, required);
    try t.reference_lifetime_hours.append(gpa, reference_life);
    try t.reference_stress.append(gpa, .{ .raw = stress });
    try t.stress_exponent.append(gpa, exponent);
    try t.reference_temperature.append(gpa, .{ .raw = temperature });
    try t.activation_energy_ev.append(gpa, activation);
    try t.duty_cycle.append(gpa, duty);
    try t.max_abs_voltage.append(gpa, .{ .raw = max_abs });
}

pub fn hvDomain(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const delta = try c.row.number("max_domain_delta");
    const isolation = try c.row.optLayer("isolation");
    const t = &c.rs.tables.hv_domain;
    try c.row.head(c.gpa, &t.head);
    try t.max_domain_delta.append(c.gpa, .{ .raw = delta });
    try t.isolation.append(c.gpa, isolation);
}

// ---- private ----

fn ohms(v: ?f64) ?@import("../report.zig").Ohms {
    return if (v) |x| .{ .raw = x } else null;
}
