//! The topological kinds' rule tables, one SoA row per deck row: what
//! `floating_gate`, `floating_well`, `multiple_drivers`, `unconnected_pin`,
//! `fanout`, `supply_path`, `gate_path`, `net_type` and
//! `combinational_loop` rows state. In: rows pushed by the deck builder or a
//! test. Out: the columns their transforms read. Ported from
//! crates/check/src/erc/rules/topology.rs (the `*Table` structs).
//!
//! Contents:
//! - `pub const FloatingGateTable`, `FloatingWellTable`, `MultipleDriversTable`, `UnconnectedPinTable`, `FanoutTable`,
//!   `SupplyPathTable`, `GatePathTable`, `NetTypeTable`, `CombinationalLoopTable`
//! - `pub const Condition = struct { name: StrId, negated: bool }`

const std = @import("std");
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const RuleHead = @import("head.zig").RuleHead;

/// `floating_gate` rows. `labels_are_ports`: a labelled net counts as a
/// port.
pub const FloatingGateTable = struct {
    head: RuleHead = .{},
    labels_are_ports: std.ArrayList(bool) = .empty,
};

/// `floating_well` rows: the well and tap layers.
pub const FloatingWellTable = struct {
    head: RuleHead = .{},
    well: std.ArrayList(LayerId) = .empty,
    tap: std.ArrayList(LayerId) = .empty,
};

/// `multiple_drivers` rows: the most drivers a net may have.
pub const MultipleDriversTable = struct {
    head: RuleHead = .{},
    max_drivers: std.ArrayList(u32) = .empty,
};

/// `unconnected_pin` rows: the pin layers, CSR by `layer_start`.
pub const UnconnectedPinTable = struct {
    head: RuleHead = .{},
    layer_start: std.ArrayList(u32) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
};

/// `fanout` rows: the most gates a net may drive.
pub const FanoutTable = struct {
    head: RuleHead = .{},
    max_gates: std.ArrayList(u32) = .empty,
};

/// `supply_path` rows: `both` asks for a path to power and to ground.
pub const SupplyPathTable = struct {
    head: RuleHead = .{},
    both: std.ArrayList(bool) = .empty,
    labels_are_ports: std.ArrayList(bool) = .empty,
};

/// `gate_path` rows: toward ground (`ground`) or power, and the most
/// devices on the path.
pub const GatePathTable = struct {
    head: RuleHead = .{},
    ground: std.ArrayList(bool) = .empty,
    max_devices: std.ArrayList(u32) = .empty,
};

/// One net-type condition term: the type or set `name` present, or absent
/// when `negated` (US20100306720A1 [0262]).
pub const Condition = struct { name: StrId, negated: bool };

/// `net_type` rows (US20100306720A1): the `net`, `path` and `break`
/// conditions and the `exclude` models, each list CSR by its start.
pub const NetTypeTable = struct {
    head: RuleHead = .{},
    net_start: std.ArrayList(u32) = .empty,
    net: std.ArrayList(Condition) = .empty,
    path_start: std.ArrayList(u32) = .empty,
    path: std.ArrayList(Condition) = .empty,
    break_start: std.ArrayList(u32) = .empty,
    breaks: std.ArrayList(Condition) = .empty,
    exclude_start: std.ArrayList(u32) = .empty,
    exclude: std.ArrayList(StrId) = .empty,
};

/// `combinational_loop` rows: the head alone.
pub const CombinationalLoopTable = struct {
    head: RuleHead = .{},
};
