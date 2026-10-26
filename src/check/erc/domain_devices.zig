//! The device-list kinds of the domain family: `power_switch`,
//! `hot_carrier` and `well_sharing`, dispatched with the topological kinds.
//! Stubs until ported: each records every row of its table refused, never
//! clean. Ported from crates/check/src/erc/rules/domain.rs.
//!
//! Contents:
//! - `pub fn checkPowerSwitch(r: Record, design: Design, intent: *const IntentMap, switched: []const NetId, states: []const NetVoltage, t: *const PowerSwitchTable) Allocator.Error!void`
//! - `pub fn checkHotCarrier(r: Record, design: Design, intent: *const IntentMap, t: *const HotCarrierTable) Allocator.Error!void`
//! - `pub fn checkWellSharing(r: Record, design: Design, t: *const WellSharingTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetId = @import("../topology/net.zig").NetId;
const NetVoltage = @import("voltage.zig").NetVoltage;
const tables = @import("domain_tables.zig");
const HotCarrierTable = tables.HotCarrierTable;
const PowerSwitchTable = tables.PowerSwitchTable;
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
