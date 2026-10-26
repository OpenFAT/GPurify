//! Whether every ERC row holds values its kind can: every limit, rating
//! and lifetime finite and positive, every distance positive, every
//! fraction in `0 ..= 1` (a duty cycle also above 0), a `density_cmp` or
//! `esd_path` row bounding something, a `well_bias` row naming a model, the
//! model and clamp lists of the kinds that need one not empty, the AC and
//! voltage tables in order, and `max_drivers`/`max_gates` at least 1. The
//! deck builder holds each row to this as it is filed; a table built in
//! code is held to the same. In: a `RuleSet`. Out: nothing, or the first
//! failing value as a named error, the row and engine parameter (or what is
//! out of order) in the `Diagnostic`. Ported from
//! crates/check/src/erc/ruleset.rs (`RuleSet::validate`, `check_row`,
//! `Check`).
//!
//! Contents:
//! - `pub fn validate(rs: *const RuleSet, diag: *Diagnostic) Error!void`
//! - `pub fn validateRow(rs: *const RuleSet, kind: Kind, r: u32, diag: *Diagnostic) Error!void`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const StrId = geom.StrId;
const params = @import("../drc/params.zig");
const Error = params.Error;
const Diagnostic = params.Diagnostic;
const Kind = @import("kinds.zig").Kind;
const RuleSet = @import("rule_set.zig").RuleSet;
const more = @import("validate_more.zig");

/// Every row, table by table in `Kind` order, each row's values in the
/// order its kind reads them.
pub fn validate(rs: *const RuleSet, diag: *Diagnostic) Error!void {
    inline for (@typeInfo(Kind).@"enum".field_names) |name| {
        const k = @field(Kind, name);
        for (0..rs.head(k).len()) |r| try validateRow(rs, k, @intCast(r), diag);
    }
}

/// Row `r` of kind `kind`'s table. Asserts the table keeps its row
/// invariants.
pub fn validateRow(rs: *const RuleSet, kind: Kind, r: u32, diag: *Diagnostic) Error!void {
    const c: more.Check = .{ .rule = rs.head(kind).rule.items[r], .diag = diag };
    const t = &rs.tables;
    switch (kind) {
        .antenna => {
            const a = &t.antenna;
            try c.positive("max_ratio", a.max_ratio.items[r]);
            // A floor with no per-ratio area would name no hint.
            const area = a.diode_area.items[r];
            const min = a.diode_min.items[r];
            if (area == null and min != null) return c.missing("diode_area");
            if (area) |v| if (v <= 0) return c.nonPositive("diode_area");
            if (min) |v| if (v <= 0) return c.nonPositive("diode_min");
            for (more.span(a.collector_measure.items, a.collector_start.items, r)) |m| switch (m) {
                .area => {},
                .sidewall => |thickness| try c.length("sidewall_thickness", thickness),
            };
        },
        .antenna_electrical => {
            const a = &t.antenna_electrical;
            try c.positive("max_ratio", a.max_ratio.items[r]);
            try c.finite("diode_credit", a.diode_credit.items[r]);
            try c.finite("diode_bonus", a.diode_bonus.items[r]);
            try c.notNegative("area_minus_diode", a.area_minus_diode.items[r]);
            try c.notNegative("gate_plus_diode", a.gate_plus_diode.items[r]);
            try c.positive("cut_factor", a.cut_factor.items[r]);
            for (more.span(a.collector_measure.items, a.collector_start.items, r)) |m| switch (m) {
                .area => {},
                .sidewall => |thickness| try c.length("sidewall_thickness", thickness),
            };
            for (more.span(a.diode_reduce.items, a.diode_reduce_start.items, r)) |p| try c.notNegative("diode_reduce", p.value);
            for (more.span(a.diode_max_ratio.items, a.diode_max_ratio_start.items, r)) |p| try c.positive("diode_max_ratio", p.value);
        },
        .density_cmp => {
            const d = &t.density_cmp;
            try c.length("window_x", d.window.items[r][0]);
            try c.length("window_y", d.window.items[r][1]);
            try c.length("step_x", d.step.items[r][0]);
            try c.length("step_y", d.step.items[r][1]);
            if (d.min_density.items[r]) |v| try c.fraction("min_density", v);
            if (d.max_density.items[r]) |v| try c.fraction("max_density", v);
            if (d.max_neighbour_delta.items[r]) |v| try c.fraction("max_neighbour_delta", v);
            if (d.cmp.items[r]) |m| {
                try c.fraction("cmp_target_density", m.target_density);
                try c.length("cmp_max_abs_thickness_delta", m.max_abs_thickness_delta);
            }
            // A row bounding nothing would report clean forever.
            if (d.min_density.items[r] == null and d.max_density.items[r] == null and d.max_neighbour_delta.items[r] == null and d.cmp.items[r] == null) return c.missing("max_density");
        },
        .electromigration => {
            const e = &t.electromigration;
            const s = e.layer_start.items;
            for (more.span(e.max_density.items, s, r), more.span(e.max_current_per_cut.items, s, r), more.span(e.blech_limit.items, s, r)) |density, cut, blech| {
                try c.positive("max_density", density.raw);
                try c.positive("max_current_per_cut", cut.raw);
                try c.positive("blech_limit", blech.raw);
            }
            try c.positive("reference_temperature", e.reference_temperature.items[r].raw);
            try c.positive("activation_energy_ev", e.activation_energy_ev.items[r]);
            try c.positive("current_exponent", e.current_exponent.items[r]);
        },
        .em_rms => try more.emAc(c, &t.em_rms, r),
        .em_peak => try more.emAc(c, &t.em_peak, r),
        .em_current_density => {
            const e = &t.em_current_density;
            const s = e.layer_start.items;
            for (more.span(e.max_density.items, s, r), more.span(e.max_current_per_cut.items, s, r), more.span(e.narrow.items, s, r)) |density, cut, narrow| {
                try c.positive("max_density", density.raw);
                try c.positive("max_current_per_cut", cut.raw);
                if (narrow) |n| {
                    try c.length("narrow_width", n.width);
                    try c.positive("narrow_current", n.current.raw);
                }
            }
        },
        .em_thermal => try more.emThermal(c, &t.em_thermal, r),
        .esd_latchup => {
            const e = &t.esd_latchup;
            try c.length("min_guard_ring_width", e.min_guard_ring_width.items[r]);
            try c.length("max_tap_distance", e.max_tap_distance.items[r]);
            if (more.empty(e.clamp_start.items, r)) return c.missing("clamp");
        },
        .esd_cross_domain => try more.esdCrossDomain(c, &t.esd_cross_domain, r),
        .power_switch => if (more.empty(t.power_switch.model_start.items, r)) return c.missing("model"),
        .hot_carrier => {
            if (more.empty(t.hot_carrier.model_start.items, r)) return c.missing("model");
            try c.length("max_length", t.hot_carrier.max_length.items[r]);
        },
        .well_sharing => if (more.empty(t.well_sharing.model_start.items, r)) return c.missing("model"),
        .esd_pin_pair => {
            const e = &t.esd_pin_pair;
            if (more.empty(e.clamp_start.items, r)) return c.missing("clamp");
            try c.positive("current", e.current.items[r].raw);
            try c.positive("clamp_resistance", e.clamp_resistance.items[r].raw);
            try c.positive("max_resistance", e.max_resistance.items[r].raw);
        },
        .esd_clamp_resistance => {
            const e = &t.esd_clamp_resistance;
            if (more.empty(e.clamp_start.items, r)) return c.missing("clamp");
            try c.positive("max_resistance", e.max_resistance.items[r].raw);
        },
        .esd_topological => if (more.empty(t.esd_topological.clamp_start.items, r)) return c.missing("clamp"),
        .esd_path => try more.esdPath(c, &t.esd_path, r),
        .esd_ground_coupling => if (more.empty(t.esd_ground_coupling.diode_start.items, r)) return c.missing("diode"),
        .esd_exposed => if (more.empty(t.esd_exposed.clamp_start.items, r)) return c.missing("clamp"),
        .esd_parasitic => try c.length("min_spacing", t.esd_parasitic.min_spacing.items[r]),
        .forward_diode => if (more.empty(t.forward_diode.model_start.items, r)) return c.missing("model"),
        .guard_ring => {
            const g = &t.guard_ring;
            if (g.max_space.items[r]) |v| try c.length("max_space", v);
            if (g.min_width.items[r]) |v| try c.length("min_width", v);
            if (g.near.items[r]) |n| try c.length("within", n.within);
        },
        .tie_area => try c.fraction("min_ratio", t.tie_area.min_ratio.items[r]),
        .conditional_tie => try more.conditionalTie(c, &t.conditional_tie, r),
        .latchup_victim => {
            try c.length("within", t.latchup_victim.within.items[r]);
            try c.length("max_distance", t.latchup_victim.max_distance.items[r]);
        },
        .gate_oxide => try more.modelLimit(c, &t.gate_oxide, r),
        .drain_source => try more.modelLimit(c, &t.drain_source, r),
        // A row naming no model would check nothing.
        .well_bias => if (more.empty(t.well_bias.pmos_start.items, r) and more.empty(t.well_bias.nmos_start.items, r)) return c.missing("pmos"),
        .hv_domain => try c.positive("max_domain_delta", t.hv_domain.max_domain_delta.items[r].raw),
        .missing_tie => try c.length("max_distance", t.missing_tie.max_distance.items[r]),
        // Zero permitted drivers flags every driven net.
        .multiple_drivers => if (t.multiple_drivers.max_drivers.items[r] == 0) return c.nonPositive("max_drivers"),
        .p2p_resistance => try c.positive("max_resistance", t.p2p_resistance.max_resistance.items[r].raw),
        .reliability => try more.reliability(c, &t.reliability, r),
        .hv_tag => try c.positive("voltage", t.hv_tag.voltage.items[r].raw),
        .dielectric_field => try c.positive("max_field", t.dielectric_field.max_field.items[r]),
        // Zero permitted gates flags every gate net.
        .fanout => if (t.fanout.max_gates.items[r] == 0) return c.nonPositive("max_gates"),
        .voltage_spacing => try more.voltageSpacing(c, &t.voltage_spacing, r),
        // Nothing beyond the layers and models each row names.
        .domain_crossing, .dynamic_ir_drop, .floating_gate, .floating_well, .matching, .floating_supply, .combinational_loop, .gate_path, .guard_ring_bias, .ir_drop, .missing_isolation, .missing_level_shifter, .mixed_tag, .net_type, .soft_connection, .supply_short, .supply_path, .tie_high_low, .unconnected_pin, .undriven_gate => {},
    }
}
