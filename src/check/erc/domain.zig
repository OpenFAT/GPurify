//! The domain kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/domain.rs.
//!
//! Contents:
//! - `pub fn checkPowerSwitch(r: Record, design: Design, intent: *const IntentMap, switched: []const NetId, states: []const NetVoltage, t: *const PowerSwitchTable) Allocator.Error!void`
//! - `pub fn checkHotCarrier(r: Record, design: Design, intent: *const IntentMap, t: *const HotCarrierTable) Allocator.Error!void`
//! - `pub fn checkWellSharing(r: Record, design: Design, t: *const WellSharingTable) Allocator.Error!void`
//! - `pub fn checkGateOxide(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void`
//! - `pub fn checkDrainSource(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void`
//! - `pub fn checkWellBias(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const WellBiasTable) Allocator.Error!void`
//! - `pub fn checkMissingLevelShifter(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const MissingLevelShifterTable) Allocator.Error!void`
//! - `pub fn checkDomainCrossing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const DomainCrossingTable) Allocator.Error!void`
//! - `pub fn checkVoltageSpacing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const VoltageSpacingTable) Allocator.Error!void`
//! - `pub fn checkHvTag(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvTagTable) Allocator.Error!void`
//! - `pub fn checkDielectricField(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, grid: Grid, t: *const DielectricFieldTable) Allocator.Error!void`
//! - `pub fn checkUndrivenGate(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const UndrivenGateTable) Allocator.Error!void`
//! - `pub fn checkMissingIsolation(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const MissingIsolationTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const Grid = geom.Grid;
const IntentMap = @import("facts.zig").IntentMap;
const NetId = @import("../topology/net.zig").NetId;
const NetVoltage = @import("voltage.zig").NetVoltage;
const tables = @import("domain_tables.zig");
const DielectricFieldTable = tables.DielectricFieldTable;
const DomainCrossingTable = tables.DomainCrossingTable;
const HotCarrierTable = tables.HotCarrierTable;
const HvTagTable = tables.HvTagTable;
const MissingIsolationTable = tables.MissingIsolationTable;
const MissingLevelShifterTable = tables.MissingLevelShifterTable;
const ModelLimitTable = tables.ModelLimitTable;
const PowerSwitchTable = tables.PowerSwitchTable;
const UndrivenGateTable = tables.UndrivenGateTable;
const VoltageSpacingTable = tables.VoltageSpacingTable;
const WellBiasTable = tables.WellBiasTable;
const WellSharingTable = tables.WellSharingTable;

/// `PowerSwitchTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkPowerSwitch(r: Record, design: Design, intent: *const IntentMap, switched: []const NetId, states: []const NetVoltage, t: *const PowerSwitchTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = switched;
    _ = states;
    try r.fillRows(&t.head, .refused);
}

/// `HotCarrierTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkHotCarrier(r: Record, design: Design, intent: *const IntentMap, t: *const HotCarrierTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `WellSharingTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkWellSharing(r: Record, design: Design, t: *const WellSharingTable) Allocator.Error!void {
    _ = design;
    try r.fillRows(&t.head, .refused);
}

/// `ModelLimitTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkGateOxide(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `ModelLimitTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkDrainSource(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `WellBiasTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkWellBias(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const WellBiasTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `MissingLevelShifterTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkMissingLevelShifter(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const MissingLevelShifterTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `DomainCrossingTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkDomainCrossing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const DomainCrossingTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `VoltageSpacingTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkVoltageSpacing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const VoltageSpacingTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `HvTagTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkHvTag(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvTagTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `DielectricFieldTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkDielectricField(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, grid: Grid, t: *const DielectricFieldTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    _ = grid;
    try r.fillRows(&t.head, .refused);
}

/// `UndrivenGateTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkUndrivenGate(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const UndrivenGateTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    _ = states;
    try r.fillRows(&t.head, .refused);
}

/// `MissingIsolationTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkMissingIsolation(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const MissingIsolationTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    _ = states;
    try r.fillRows(&t.head, .refused);
}
