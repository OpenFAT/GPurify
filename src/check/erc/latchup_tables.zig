//! The latchup and matching kinds' rule tables, one SoA row per deck row:
//! what `guard_ring_bias`, `tie_area`, `guard_ring`, `forward_diode`,
//! `conditional_tie`, `latchup_victim` and `matching` rows state. In: rows
//! pushed by the deck builder or a test. Out: the columns their transforms
//! read. Ported from crates/check/src/erc/rules/{latchup,matching}.rs (the
//! `*Table` structs).
//!
//! Contents:
//! - `pub const GuardRingBiasTable`, `TieAreaTable`, `GuardRingTable`, `ForwardDiodeTable`, `ConditionalTieTable`,
//!   `LatchupVictimTable`, `MatchingTable`
//! - `pub const Near = struct { layer: LayerId, within: Dbu }`, `pub const Bias = struct { layer: LayerId, above: bool }`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const RuleHead = @import("head.zig").RuleHead;

/// A guard-ring condition: only near `layer`, within `within`.
pub const Near = struct { layer: LayerId, within: Dbu };

/// A latchup-victim bias condition: the layer an aggressor's junction sits
/// in (its well or tie), and whether the junction injects when its net
/// rises above that polygon's (true, a P+ in an N-well; `forward: 0` in the
/// deck) or falls below it (an N+ in the substrate).
pub const Bias = struct { layer: LayerId, above: bool };

/// `guard_ring_bias` rows: the ring layer, power (else ground) bias.
pub const GuardRingBiasTable = struct {
    head: RuleHead = .{},
    ring: std.ArrayList(LayerId) = .empty,
    power: std.ArrayList(bool) = .empty,
};

/// `tie_area` rows: the region, contact and channel layers, the least ratio.
pub const TieAreaTable = struct {
    head: RuleHead = .{},
    region: std.ArrayList(LayerId) = .empty,
    contact: std.ArrayList(LayerId) = .empty,
    channel: std.ArrayList(LayerId) = .empty,
    min_ratio: std.ArrayList(f64) = .empty,
};

/// `guard_ring` rows: the target and ring layers and the optional limits.
pub const GuardRingTable = struct {
    head: RuleHead = .{},
    target: std.ArrayList(LayerId) = .empty,
    ring: std.ArrayList(LayerId) = .empty,
    max_space: std.ArrayList(?Dbu) = .empty,
    min_width: std.ArrayList(?Dbu) = .empty,
    pad: std.ArrayList(?LayerId) = .empty,
    near: std.ArrayList(?Near) = .empty,
    clear: std.ArrayList(?LayerId) = .empty,
};

/// `forward_diode` rows: the marker layer and the models, CSR.
pub const ForwardDiodeTable = struct {
    head: RuleHead = .{},
    marker: std.ArrayList(LayerId) = .empty,
    model_start: std.ArrayList(u32) = .empty,
    model: std.ArrayList(StrId) = .empty,
};

/// `conditional_tie` rows: the four layers, the reach, and the spacing
/// thresholds with one more distance limit than thresholds (each CSR).
pub const ConditionalTieTable = struct {
    head: RuleHead = .{},
    region: std.ArrayList(LayerId) = .empty,
    tap: std.ArrayList(LayerId) = .empty,
    well: std.ArrayList(LayerId) = .empty,
    other: std.ArrayList(LayerId) = .empty,
    within: std.ArrayList(Dbu) = .empty,
    spacing_start: std.ArrayList(u32) = .empty,
    spacing: std.ArrayList(Dbu) = .empty,
    max_distance_start: std.ArrayList(u32) = .empty,
    max_distance: std.ArrayList(Dbu) = .empty,
};

/// `latchup_victim` rows: the aggressor, region and tap layers, the
/// reaches, and the optional pad and bias conditions.
pub const LatchupVictimTable = struct {
    head: RuleHead = .{},
    aggressor: std.ArrayList(LayerId) = .empty,
    region: std.ArrayList(LayerId) = .empty,
    tap: std.ArrayList(LayerId) = .empty,
    within: std.ArrayList(Dbu) = .empty,
    max_distance: std.ArrayList(Dbu) = .empty,
    pad: std.ArrayList(?LayerId) = .empty,
    bias: std.ArrayList(?Bias) = .empty,
};

/// `matching` rows: the group marker layer and the tolerance.
pub const MatchingTable = struct {
    head: RuleHead = .{},
    group: std.ArrayList(LayerId) = .empty,
    tolerance: std.ArrayList(Dbu) = .empty,
};
