//! A deck's ERC rules, stored: one SoA table per kind (`Tables`, each field
//! named for its kind), the deck order as `(kind, row)` slots, and the deck
//! views the stage kinds read (the etch stack, the connectivity, the layer
//! heights). In: rows filed by the deck builder (`build.zig`) or a test.
//! Out: the tables the spine (`run.zig`) reads. Ported from
//! crates/check/src/erc/ruleset.rs (`RuleSet`'s fields, `len`).
//!
//! Contents:
//! - `pub fn TableOf(comptime k: Kind) type`, `pub const Tables`, `pub const Slot = struct { kind: Kind, row: u32 }`
//! - `pub const RuleSet = struct`, `deinit`, `len(rs) u32`, `isEmpty(rs) bool`, `head(rs, k: Kind) *const RuleHead`,
//!   `file(rs, gpa: Allocator, k: Kind) Allocator.Error!void`, `stack(rs) Stack`
//! - `pub fn deinitTable(gpa: Allocator, t: anytype) void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;
const Connectivity = @import("ingest").deck.Connectivity;
const Kind = @import("kinds.zig").Kind;
const RuleHead = @import("head.zig").RuleHead;
const topology = @import("topology_tables.zig");
const supply = @import("supply_tables.zig");
const antenna = @import("antenna_tables.zig");
const electrical = @import("electrical_tables.zig");
const esd = @import("esd_tables.zig");
const latchup = @import("latchup_tables.zig");
const domain = @import("domain_tables.zig");

/// One table per kind, each field named for its kind.
pub const Tables = blk: {
    const names = @typeInfo(Kind).@"enum".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (names, 0..) |n, i| {
        types[i] = TableOf(@field(Kind, n));
        attrs[i] = .{ .default_value_ptr = &@as(types[i], .{}) };
    }
    break :blk @Struct(.auto, null, names, &types, &attrs);
};

/// One rule in deck order: its kind and its row of that kind's table.
pub const Slot = struct { kind: Kind, row: u32 };

/// Every ERC rule a deck configures. Invariant: every table keeps its
/// columns' row counts (see the family `*_tables.zig` files), and `order`
/// holds one slot per row of every table, in deck order.
pub const RuleSet = struct {
    tables: Tables = .{},
    order: std.ArrayList(Slot) = .empty,
    /// The gate terminal layer (the first) of every `device mos` row, for
    /// the antenna rows.
    gates: std.ArrayList(LayerId) = .empty,
    /// The deck's connectivity (a view into the deck's arena): the antenna
    /// rows' etch stack and the soft-connection rows' nets.
    connectivity: Connectivity = .{},
    /// The deck's layer heights, nm (a view): `em_thermal`'s heat paths.
    height_nm: []const f64 = &.{},

    pub fn deinit(rs: *RuleSet, gpa: Allocator) void {
        inline for (@typeInfo(Tables).@"struct".field_names) |k| deinitTable(gpa, &@field(rs.tables, k));
        rs.order.deinit(gpa);
        rs.gates.deinit(gpa);
    }

    /// Rule rows across every table: the `RuleRun`s a run records.
    pub fn len(rs: *const RuleSet) u32 {
        return @intCast(rs.order.items.len);
    }

    pub fn isEmpty(rs: *const RuleSet) bool {
        return rs.len() == 0;
    }

    /// Kind `k`'s head.
    pub fn head(rs: *const RuleSet, k: Kind) *const RuleHead {
        return switch (k) {
            inline else => |kk| &@field(rs.tables, @tagName(kk)).head,
        };
    }

    /// Appends the slot of kind `k`'s newest row to the deck order.
    pub fn file(rs: *RuleSet, gpa: Allocator, k: Kind) Allocator.Error!void {
        const rows = rs.head(k).len();
        assert(rows > 0);
        try rs.order.append(gpa, .{ .kind = k, .row = rows - 1 });
    }

    /// The etch stack the antenna rows cut their stage nets from.
    pub fn stack(rs: *const RuleSet) antenna.Stack {
        const c = rs.connectivity;
        return .{ .conductors = c.conductors, .via_cut = c.via_cut, .via_connects = c.via_connects, .intra_layer_touch = c.intra_layer_touch, .gates = rs.gates.items };
    }
};

/// The table type kind `k` files its rows into. `em_rms`/`em_peak` share
/// one type, as do `gate_oxide`/`drain_source`.
pub fn TableOf(comptime k: Kind) type {
    return switch (k) {
        .antenna => antenna.AntennaTable,
        .antenna_electrical => antenna.AntennaElectricalTable,
        .density_cmp => antenna.DensityCmpTable,
        .conditional_tie => latchup.ConditionalTieTable,
        .dielectric_field => domain.DielectricFieldTable,
        .domain_crossing => domain.DomainCrossingTable,
        .drain_source, .gate_oxide => domain.ModelLimitTable,
        .dynamic_ir_drop => electrical.DynamicIrDropTable,
        .electromigration => electrical.ElectromigrationTable,
        .em_current_density => electrical.EmCurrentDensityTable,
        .em_rms, .em_peak => electrical.EmAcTable,
        .em_thermal => electrical.EmThermalTable,
        .esd_cross_domain => esd.EsdCrossDomainTable,
        .esd_exposed => esd.EsdExposedTable,
        .esd_ground_coupling => esd.EsdGroundCouplingTable,
        .esd_latchup => esd.EsdLatchupTable,
        .esd_parasitic => esd.EsdParasiticTable,
        .esd_path => esd.EsdPathTable,
        .esd_pin_pair => esd.EsdPinPairTable,
        .esd_clamp_resistance => esd.EsdClampResistanceTable,
        .esd_topological => supply.EsdTopologicalTable,
        .fanout => topology.FanoutTable,
        .floating_gate => topology.FloatingGateTable,
        .floating_well => topology.FloatingWellTable,
        .power_switch => domain.PowerSwitchTable,
        .matching => latchup.MatchingTable,
        .floating_supply => supply.FloatingSupplyTable,
        .forward_diode => latchup.ForwardDiodeTable,
        .combinational_loop => topology.CombinationalLoopTable,
        .gate_path => topology.GatePathTable,
        .guard_ring => latchup.GuardRingTable,
        .guard_ring_bias => latchup.GuardRingBiasTable,
        .hot_carrier => domain.HotCarrierTable,
        .hv_domain => esd.HvDomainTable,
        .hv_tag => domain.HvTagTable,
        .ir_drop => electrical.IrDropTable,
        .latchup_victim => latchup.LatchupVictimTable,
        .missing_isolation => domain.MissingIsolationTable,
        .missing_level_shifter => domain.MissingLevelShifterTable,
        .missing_tie => supply.MissingTieTable,
        .mixed_tag => supply.MixedTagTable,
        .multiple_drivers => topology.MultipleDriversTable,
        .net_type => topology.NetTypeTable,
        .p2p_resistance => electrical.P2pResistanceTable,
        .reliability => esd.ReliabilityTable,
        .soft_connection => supply.SoftConnectionTable,
        .supply_short => supply.SupplyShortTable,
        .supply_path => topology.SupplyPathTable,
        .tie_area => latchup.TieAreaTable,
        .tie_high_low => supply.TieHighLowTable,
        .unconnected_pin => topology.UnconnectedPinTable,
        .undriven_gate => domain.UndrivenGateTable,
        .voltage_spacing => domain.VoltageSpacingTable,
        .well_bias => domain.WellBiasTable,
        .well_sharing => domain.WellSharingTable,
    };
}

/// Frees every column of a rule table (any `*_tables.zig` type).
pub fn deinitTable(gpa: Allocator, t: anytype) void {
    inline for (@typeInfo(@TypeOf(t.*)).@"struct".field_names) |f| @field(t, f).deinit(gpa);
}

test "every kind has a table, and a filed row reads back in deck order" {
    // Oracle: round trip. Two kinds interleaved keep their deck order and
    // each row lands in its own kind's table.
    const gpa = std.testing.allocator;
    var rs: RuleSet = .{};
    defer rs.deinit(gpa);
    try rs.tables.fanout.head.push(gpa, @fromBackingInt(1), .@"error");
    try rs.tables.fanout.max_gates.append(gpa, 4);
    try rs.file(gpa, .fanout);
    try rs.tables.ir_drop.head.push(gpa, @fromBackingInt(2), .warning);
    try rs.file(gpa, .ir_drop);
    try rs.tables.fanout.head.push(gpa, @fromBackingInt(3), .@"error");
    try rs.tables.fanout.max_gates.append(gpa, 8);
    try rs.file(gpa, .fanout);
    try std.testing.expectEqual(@as(u32, 3), rs.len());
    try std.testing.expectEqual(Slot{ .kind = .fanout, .row = 1 }, rs.order.items[2]);
    try std.testing.expectEqual(@as(u32, 2), rs.head(.fanout).len());
}
