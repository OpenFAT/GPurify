//! The process-stage kinds' rule tables, one SoA row per deck row, and the
//! values they carry: what `antenna`, `antenna_electrical` and
//! `density_cmp` rows state, the etch stack the antenna rows cut their
//! stage nets from, and a placed macro pin's LEF antenna data. In: rows
//! pushed by the deck builder or a test. Out: the columns their transforms
//! read. Ported from crates/check/src/erc/rules/antenna.rs (`AntennaTable`,
//! `AntennaElectricalTable`, `DensityCmpTable`, `AntennaMeasure`, `CmpModel`,
//! `Stack`, `MacroPinAntenna`; the stack is the rule set's, passed to the
//! transforms).
//!
//! Contents:
//! - `pub const AntennaMeasure = union(enum) { area, sidewall: Dbu }`
//! - `pub const Stack = struct`, `pub const MacroPinAntenna = struct`, `pub const PinValue = struct`
//! - `pub const CmpModel = struct`, `pub const AreaPoint = struct { area: DbuArea, value: f64 }`
//! - `pub const AntennaTable`, `AntennaElectricalTable`, `DensityCmpTable`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const AntennaKind = @import("ingest").lefdef.AntennaKind;
const RuleHead = @import("head.zig").RuleHead;

/// What a row counts as collecting area, one measure for all its
/// collectors: the merged layer's area (`sidewall: none`), or its
/// perimeter times the etched thickness (`sidewall: len`). A cut always
/// collects by area.
pub const AntennaMeasure = union(enum) {
    area,
    sidewall: Dbu,
};

/// The deck's connectivity the antenna rows cut each etch stage's nets
/// from. A view into the deck's (or a test's) slices.
pub const Stack = struct {
    /// Conductor layers bottom-up, as `connect conductors` lists them: the
    /// order decides which conductors stand at a stage.
    conductors: []const LayerId = &.{},
    /// Each `connect via` row: the cut and the two conductors it joins.
    via_cut: []const LayerId = &.{},
    via_connects: []const [2]LayerId = &.{},
    intra_layer_touch: bool = false,
    /// The gate terminal layer (the first) of every `device mos` row.
    gates: []const LayerId = &.{},
};

/// One `ANTENNA*` statement of a pin: its kind, the layer it names (or
/// every layer), its value (µm² or a ratio).
pub const PinValue = struct { kind: AntennaKind, layer: ?LayerId, value: f64 };

/// A placed macro pin's LEF antenna data (LEF/DEF 5.8 Appendix C), on its
/// polygon's net.
pub const MacroPinAntenna = struct {
    poly: PolyId,
    values: []const PinValue,
};

/// The CMP thickness model of a `density_cmp` row: all three or none.
pub const CmpModel = struct {
    target_density: f64,
    thickness_sensitivity: Dbu,
    max_abs_thickness_delta: Dbu,
};

/// One point of a piecewise-linear table over area.
pub const AreaPoint = struct { area: DbuArea, value: f64 };

/// `antenna` rows: the gate layer, the collector layers (CSR) and each
/// one's measure, the ratio limit, and the optional diode.
pub const AntennaTable = struct {
    head: RuleHead = .{},
    gate: std.ArrayList(LayerId) = .empty,
    collector_start: std.ArrayList(u32) = .empty,
    collector: std.ArrayList(LayerId) = .empty,
    collector_measure: std.ArrayList(AntennaMeasure) = .empty,
    max_ratio: std.ArrayList(f64) = .empty,
    diode: std.ArrayList(?LayerId) = .empty,
    diode_area: std.ArrayList(?DbuArea) = .empty,
    diode_min: std.ArrayList(?DbuArea) = .empty,
};

/// `antenna_electrical` rows: as `antenna`, with the diode credit terms
/// and the two area tables (CSR by their starts).
pub const AntennaElectricalTable = struct {
    head: RuleHead = .{},
    gate: std.ArrayList(LayerId) = .empty,
    collector_start: std.ArrayList(u32) = .empty,
    collector: std.ArrayList(LayerId) = .empty,
    collector_measure: std.ArrayList(AntennaMeasure) = .empty,
    cut_factor: std.ArrayList(f64) = .empty,
    diode: std.ArrayList(?LayerId) = .empty,
    diode_credit: std.ArrayList(f64) = .empty,
    diode_bonus: std.ArrayList(f64) = .empty,
    area_minus_diode: std.ArrayList(f64) = .empty,
    gate_plus_diode: std.ArrayList(f64) = .empty,
    diode_reduce_start: std.ArrayList(u32) = .empty,
    diode_reduce: std.ArrayList(AreaPoint) = .empty,
    diode_max_ratio_start: std.ArrayList(u32) = .empty,
    diode_max_ratio: std.ArrayList(AreaPoint) = .empty,
    exempt: std.ArrayList(?LayerId) = .empty,
    max_ratio: std.ArrayList(f64) = .empty,
};

/// `density_cmp` rows: the layer, window and step, the bounds, and the
/// optional CMP model.
pub const DensityCmpTable = struct {
    head: RuleHead = .{},
    layer: std.ArrayList(LayerId) = .empty,
    window: std.ArrayList([2]Dbu) = .empty,
    step: std.ArrayList([2]Dbu) = .empty,
    min_density: std.ArrayList(?f64) = .empty,
    max_density: std.ArrayList(?f64) = .empty,
    max_neighbour_delta: std.ArrayList(?f64) = .empty,
    cmp: std.ArrayList(?CmpModel) = .empty,
    include_partial_windows: std.ArrayList(bool) = .empty,
};
