//! The supply kinds' rule tables, one SoA row per deck row: what
//! `supply_short`, `soft_connection`, `missing_tie`, `tie_high_low`,
//! `esd_topological`, `mixed_tag` and `floating_supply` rows state. In: rows
//! pushed by the deck builder or a test. Out: the columns their transforms
//! read. Ported from crates/check/src/erc/rules/supply.rs (the `*Table`
//! structs; `SoftConnectionTable.connectivity` is the rule set's, passed to
//! the transform).
//!
//! Contents:
//! - `pub const SupplyShortTable`, `SoftConnectionTable`, `MissingTieTable`, `TieHighLowTable`, `EsdTopologicalTable`,
//!   `MixedTagTable`, `FloatingSupplyTable`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const RuleHead = @import("head.zig").RuleHead;

/// `supply_short` rows: the two tap layers, and the region they share.
pub const SupplyShortTable = struct {
    head: RuleHead = .{},
    tap_a: std.ArrayList(LayerId) = .empty,
    tap_b: std.ArrayList(LayerId) = .empty,
    within: std.ArrayList(?LayerId) = .empty,
};

/// `soft_connection` rows: the soft layers, CSR by `soft_start`.
pub const SoftConnectionTable = struct {
    head: RuleHead = .{},
    soft_start: std.ArrayList(u32) = .empty,
    soft: std.ArrayList(LayerId) = .empty,
};

/// `missing_tie` rows: the region and tap layers and the reach.
pub const MissingTieTable = struct {
    head: RuleHead = .{},
    region: std.ArrayList(LayerId) = .empty,
    tap: std.ArrayList(LayerId) = .empty,
    max_distance: std.ArrayList(Dbu) = .empty,
};

/// `tie_high_low` rows: the head alone.
pub const TieHighLowTable = struct {
    head: RuleHead = .{},
};

/// `esd_topological` rows: the pad layer and the clamp models, CSR.
pub const EsdTopologicalTable = struct {
    head: RuleHead = .{},
    pad: std.ArrayList(LayerId) = .empty,
    clamp_start: std.ArrayList(u32) = .empty,
    clamp: std.ArrayList(StrId) = .empty,
};

/// `mixed_tag` rows: the layer and its tag layer.
pub const MixedTagTable = struct {
    head: RuleHead = .{},
    layer: std.ArrayList(LayerId) = .empty,
    tag: std.ArrayList(LayerId) = .empty,
};

/// `floating_supply` rows: the head alone.
pub const FloatingSupplyTable = struct {
    head: RuleHead = .{},
};
