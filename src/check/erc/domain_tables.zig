//! The voltage-domain kinds' rule tables, one SoA row per deck row: what
//! `gate_oxide`, `drain_source`, `well_bias`, `missing_level_shifter`,
//! `domain_crossing`, `voltage_spacing`, `dielectric_field`, `hv_tag`,
//! `undriven_gate`, `missing_isolation`, `power_switch`, `hot_carrier` and
//! `well_sharing` rows state. In: rows pushed by the deck builder or a
//! test. Out: the columns their transforms read. Ported from
//! crates/check/src/erc/rules/domain.rs (the `*Table` structs).
//!
//! Contents:
//! - `pub const ModelLimitTable`, `WellBiasTable`, `MissingLevelShifterTable`, `DomainCrossingTable`, `VoltageSpacingTable`,
//!   `DielectricFieldTable`, `HvTagTable`, `UndrivenGateTable`, `MissingIsolationTable`, `PowerSwitchTable`,
//!   `HotCarrierTable`, `WellSharingTable`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const Millivolts = @import("../report.zig").Millivolts;
const RuleHead = @import("head.zig").RuleHead;

/// `gate_oxide` and `drain_source` rows: the models (CSR), the most voltage.
pub const ModelLimitTable = struct {
    head: RuleHead = .{},
    model_start: std.ArrayList(u32) = .empty,
    model: std.ArrayList(StrId) = .empty,
    max_voltage: std.ArrayList(Millivolts) = .empty,
};

/// `well_bias` rows: the PMOS and NMOS models, each CSR.
pub const WellBiasTable = struct {
    head: RuleHead = .{},
    pmos_start: std.ArrayList(u32) = .empty,
    pmos: std.ArrayList(StrId) = .empty,
    nmos_start: std.ArrayList(u32) = .empty,
    nmos: std.ArrayList(StrId) = .empty,
};

/// `missing_level_shifter` rows: the shifter models, CSR.
pub const MissingLevelShifterTable = struct {
    head: RuleHead = .{},
    shifter_start: std.ArrayList(u32) = .empty,
    shifter: std.ArrayList(StrId) = .empty,
};

/// `domain_crossing` rows: the head alone.
pub const DomainCrossingTable = struct {
    head: RuleHead = .{},
};

/// `voltage_spacing` rows: the layer, the optional other layer, and the
/// voltage-to-space steps (CSR by `step_start`, both columns).
pub const VoltageSpacingTable = struct {
    head: RuleHead = .{},
    layer: std.ArrayList(LayerId) = .empty,
    other: std.ArrayList(?LayerId) = .empty,
    step_start: std.ArrayList(u32) = .empty,
    voltage: std.ArrayList(Millivolts) = .empty,
    space: std.ArrayList(Dbu) = .empty,
};

/// `dielectric_field` rows: the layer, the optional other layer, the most
/// field, and the vertical gap between the two (null: not stated).
pub const DielectricFieldTable = struct {
    head: RuleHead = .{},
    layer: std.ArrayList(LayerId) = .empty,
    other: std.ArrayList(?LayerId) = .empty,
    max_field: std.ArrayList(f64) = .empty,
    vertical_nm: std.ArrayList(?f64) = .empty,
};

/// `hv_tag` rows: the layer, its tag layer, the voltage that needs it.
pub const HvTagTable = struct {
    head: RuleHead = .{},
    layer: std.ArrayList(LayerId) = .empty,
    tag: std.ArrayList(LayerId) = .empty,
    voltage: std.ArrayList(Millivolts) = .empty,
};

/// `undriven_gate` rows: the head alone.
pub const UndrivenGateTable = struct {
    head: RuleHead = .{},
};

/// `missing_isolation` rows: the isolation models, CSR.
pub const MissingIsolationTable = struct {
    head: RuleHead = .{},
    isolation_start: std.ArrayList(u32) = .empty,
    isolation: std.ArrayList(StrId) = .empty,
};

/// `power_switch` rows: the switch models, CSR.
pub const PowerSwitchTable = struct {
    head: RuleHead = .{},
    model_start: std.ArrayList(u32) = .empty,
    model: std.ArrayList(StrId) = .empty,
};

/// `hot_carrier` rows: the models (CSR) and the most channel length.
pub const HotCarrierTable = struct {
    head: RuleHead = .{},
    model_start: std.ArrayList(u32) = .empty,
    model: std.ArrayList(StrId) = .empty,
    max_length: std.ArrayList(Dbu) = .empty,
};

/// `well_sharing` rows: the models (CSR), and whether resistors count.
pub const WellSharingTable = struct {
    head: RuleHead = .{},
    model_start: std.ArrayList(u32) = .empty,
    model: std.ArrayList(StrId) = .empty,
    resistors: std.ArrayList(bool) = .empty,
};
