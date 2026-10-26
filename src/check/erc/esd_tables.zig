//! The ESD and reliability kinds' rule tables, one SoA row per deck row:
//! what `esd_path`, `esd_pin_pair`, `esd_clamp_resistance`,
//! `esd_ground_coupling`, `esd_cross_domain`, `esd_parasitic`,
//! `esd_exposed`, `reliability`, `hv_domain` and `esd_latchup` rows state.
//! In: rows pushed by the deck builder or a test. Out: the columns their
//! transforms read. Ported from crates/check/src/erc/rules/{esd,
//! reliability}.rs (the `*Table` structs).
//!
//! Contents:
//! - `pub const EsdPathTable`, `EsdPinPairTable`, `EsdClampResistanceTable`, `EsdGroundCouplingTable`,
//!   `EsdCrossDomainTable`, `EsdParasiticTable`, `EsdExposedTable`
//! - `pub const ReliabilityTable`, `HvDomainTable`, `EsdLatchupTable`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const report = @import("../report.zig");
const Millivolts = report.Millivolts;
const Microamps = report.Microamps;
const Ohms = report.Ohms;
const RuleHead = @import("head.zig").RuleHead;
const electrical = @import("electrical_tables.zig");
const CurrentDensity = electrical.CurrentDensity;
const Kelvin = electrical.Kelvin;

/// `esd_path` rows: the pad and source layers, the clamp models (CSR), the
/// stress current and clamp resistance, and the optional limits.
pub const EsdPathTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    source: std.ArrayList(LayerId) = .empty,
    clamp_start: std.ArrayList(u32) = .empty,
    clamp: std.ArrayList(StrId) = .empty,
    current: std.ArrayList(Microamps) = .empty,
    clamp_resistance: std.ArrayList(Ohms) = .empty,
    max_resistance: std.ArrayList(?Ohms) = .empty,
    clamp_it2: std.ArrayList(?CurrentDensity) = .empty,
    max_density: std.ArrayList(?CurrentDensity) = .empty,
    max_current_per_cut: std.ArrayList(?Microamps) = .empty,
    max_voltage: std.ArrayList(?Millivolts) = .empty,
    min_width: std.ArrayList(?Dbu) = .empty,
    clamp_voltage: std.ArrayList(?Millivolts) = .empty,
};

/// `esd_pin_pair` rows: the pad layer, clamps (CSR), stress and limit.
pub const EsdPinPairTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    clamp_start: std.ArrayList(u32) = .empty,
    clamp: std.ArrayList(StrId) = .empty,
    current: std.ArrayList(Microamps) = .empty,
    clamp_resistance: std.ArrayList(Ohms) = .empty,
    max_resistance: std.ArrayList(Ohms) = .empty,
};

/// `esd_clamp_resistance` rows: the pad layer, clamps (CSR), the limit.
pub const EsdClampResistanceTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    clamp_start: std.ArrayList(u32) = .empty,
    clamp: std.ArrayList(StrId) = .empty,
    max_resistance: std.ArrayList(Ohms) = .empty,
};

/// `esd_ground_coupling` rows: the coupling diode models, CSR.
pub const EsdGroundCouplingTable = struct {
    head: RuleHead = .{},
    diode_start: std.ArrayList(u32) = .empty,
    diode: std.ArrayList(StrId) = .empty,
};

/// `esd_cross_domain` rows: the diode, local and resistor models (CSR) and
/// the optional resistance limits.
pub const EsdCrossDomainTable = struct {
    head: RuleHead = .{},
    diode_start: std.ArrayList(u32) = .empty,
    diode: std.ArrayList(StrId) = .empty,
    local_start: std.ArrayList(u32) = .empty,
    local: std.ArrayList(StrId) = .empty,
    resistor_start: std.ArrayList(u32) = .empty,
    resistor: std.ArrayList(StrId) = .empty,
    min_series: std.ArrayList(?Ohms) = .empty,
    max_ground_resistance: std.ArrayList(?Ohms) = .empty,
    coupling_resistance: std.ArrayList(?Ohms) = .empty,
};

/// `esd_parasitic` rows: the pad and diffusion layers, the spacing.
pub const EsdParasiticTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    diffusion: std.ArrayList(LayerId) = .empty,
    min_spacing: std.ArrayList(Dbu) = .empty,
};

/// `esd_exposed` rows: the pad layer, the clamp, resistor and rated models
/// (CSR), the optional series resistance.
pub const EsdExposedTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    clamp_start: std.ArrayList(u32) = .empty,
    clamp: std.ArrayList(StrId) = .empty,
    resistor_start: std.ArrayList(u32) = .empty,
    resistor: std.ArrayList(StrId) = .empty,
    rated_start: std.ArrayList(u32) = .empty,
    rated: std.ArrayList(StrId) = .empty,
    min_series: std.ArrayList(?Ohms) = .empty,
};

/// `reliability` rows: the lifetime model's terms.
pub const ReliabilityTable = struct {
    head: RuleHead = .{},
    required_lifetime_hours: std.ArrayList(f64) = .empty,
    reference_lifetime_hours: std.ArrayList(f64) = .empty,
    reference_stress: std.ArrayList(Millivolts) = .empty,
    stress_exponent: std.ArrayList(f64) = .empty,
    reference_temperature: std.ArrayList(Kelvin) = .empty,
    activation_energy_ev: std.ArrayList(f64) = .empty,
    duty_cycle: std.ArrayList(f64) = .empty,
    max_abs_voltage: std.ArrayList(Millivolts) = .empty,
};

/// `hv_domain` rows: the most domain delta and the optional isolation layer.
pub const HvDomainTable = struct {
    head: RuleHead = .{},
    max_domain_delta: std.ArrayList(Millivolts) = .empty,
    isolation: std.ArrayList(?LayerId) = .empty,
};

/// `esd_latchup` rows: the pad layer, clamps (CSR), the guard ring layer,
/// its least width and the most tap distance.
pub const EsdLatchupTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    clamp_start: std.ArrayList(u32) = .empty,
    clamp: std.ArrayList(StrId) = .empty,
    guard_ring: std.ArrayList(LayerId) = .empty,
    min_guard_ring_width: std.ArrayList(Dbu) = .empty,
    max_tap_distance: std.ArrayList(Dbu) = .empty,
};
