//! The electrical kinds' rule tables, one SoA row per deck row: what
//! `p2p_resistance`, `ir_drop`, `dynamic_ir_drop`, `em_current_density`,
//! `em_rms`, `em_peak`, `electromigration` and `em_thermal` rows state; a
//! per-layer limit column runs parallel to its layer column. In: rows
//! pushed by the deck builder or a test. Out: the columns their transforms
//! read. Ported from crates/check/src/erc/rules/electrical.rs (the `*Table`
//! structs; `EmThermalTable.height_nm` is the rule set's, passed to the
//! transform).
//!
//! Contents:
//! - `pub const boltzmann_ev_per_k: f64`, `pub const CurrentDensity`, `pub const Kelvin`, `pub const Narrow = struct { width: Dbu, current: Microamps }`
//! - `pub const P2pResistanceTable`, `IrDropTable`, `DynamicIrDropTable`, `EmCurrentDensityTable`, `EmAcTable`,
//!   `ElectromigrationTable`, `EmThermalTable`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const report = @import("../report.zig");
const Microamps = report.Microamps;
const Ohms = report.Ohms;
const RuleHead = @import("head.zig").RuleHead;

/// Boltzmann's constant in eV/K: activation energies are stated in eV.
pub const boltzmann_ev_per_k: f64 = 8.617_333_262e-5;

/// Current per conductor width, A/m (= µA/µm).
pub const CurrentDensity = geom.Qty(.current_density, .base);
/// Absolute temperature.
pub const Kelvin = geom.Qty(.temperature, .base);

/// A narrow-wire band: wires at most `width` wide carry `current`.
pub const Narrow = struct { width: Dbu, current: Microamps };

/// `p2p_resistance` rows: the most resistance between two attach points.
pub const P2pResistanceTable = struct {
    head: RuleHead = .{},
    max_resistance: std.ArrayList(Ohms) = .empty,
};

/// `ir_drop` rows: the head alone (limits are the intent's).
pub const IrDropTable = struct {
    head: RuleHead = .{},
};

/// `dynamic_ir_drop` rows: the head alone.
pub const DynamicIrDropTable = struct {
    head: RuleHead = .{},
};

/// `em_current_density` rows: per layer (CSR), the density and per-cut
/// limits and the optional narrow band.
pub const EmCurrentDensityTable = struct {
    head: RuleHead = .{},
    layer_start: std.ArrayList(u32) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
    max_density: std.ArrayList(CurrentDensity) = .empty,
    max_current_per_cut: std.ArrayList(Microamps) = .empty,
    narrow: std.ArrayList(?Narrow) = .empty,
};

/// `em_rms` and `em_peak` rows: the layers, the frequency and width axes
/// and the density per (frequency, width), each CSR, and the per-cut limit.
pub const EmAcTable = struct {
    head: RuleHead = .{},
    layer_start: std.ArrayList(u32) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
    frequency_start: std.ArrayList(u32) = .empty,
    frequency: std.ArrayList(f64) = .empty,
    width_start: std.ArrayList(u32) = .empty,
    width: std.ArrayList(Dbu) = .empty,
    density_start: std.ArrayList(u32) = .empty,
    density: std.ArrayList(CurrentDensity) = .empty,
    max_current_per_cut: std.ArrayList(Microamps) = .empty,
};

/// `electromigration` rows: per-layer limits (CSR) and Black's equation
/// terms per row.
pub const ElectromigrationTable = struct {
    head: RuleHead = .{},
    layer_start: std.ArrayList(u32) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
    max_density: std.ArrayList(CurrentDensity) = .empty,
    max_current_per_cut: std.ArrayList(Microamps) = .empty,
    blech_limit: std.ArrayList(Microamps) = .empty,
    reference_temperature: std.ArrayList(Kelvin) = .empty,
    activation_energy_ev: std.ArrayList(f64) = .empty,
    current_exponent: std.ArrayList(f64) = .empty,
};

/// `em_thermal` rows: as `electromigration`, with the self-heating and
/// failure-statistics terms.
pub const EmThermalTable = struct {
    head: RuleHead = .{},
    layer_start: std.ArrayList(u32) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
    max_density: std.ArrayList(CurrentDensity) = .empty,
    max_current_per_cut: std.ArrayList(Microamps) = .empty,
    blech_limit: std.ArrayList(Microamps) = .empty,
    reference_temperature: std.ArrayList(Kelvin) = .empty,
    activation_energy_ev: std.ArrayList(f64) = .empty,
    current_exponent: std.ArrayList(f64) = .empty,
    thermal_conductivity: std.ArrayList(f64) = .empty,
    heat_spreading: std.ArrayList(f64) = .empty,
    sigma: std.ArrayList(f64) = .empty,
    limit_failure: std.ArrayList(f64) = .empty,
    max_failure: std.ArrayList(f64) = .empty,
};
