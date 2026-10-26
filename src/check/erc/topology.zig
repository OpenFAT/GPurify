//! The topology kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/topology.rs.
//!
//! Contents:
//! - `pub fn checkFloatingGate(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, t: *const FloatingGateTable) Allocator.Error!void`
//! - `pub fn checkFloatingWell(r: Record, design: Design, t: *const FloatingWellTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkMultipleDrivers(r: Record, design: Design, intent: *const IntentMap, t: *const MultipleDriversTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkUnconnectedPin(r: Record, design: Design, facts: *const NetFacts, t: *const UnconnectedPinTable) Allocator.Error!void`
//! - `pub fn checkFanout(r: Record, design: Design, t: *const FanoutTable) Allocator.Error!void`
//! - `pub fn checkSupplyPath(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, intent: *const IntentMap, t: *const SupplyPathTable) Allocator.Error!void`
//! - `pub fn checkGatePath(r: Record, design: Design, intent: *const IntentMap, t: *const GatePathTable) Allocator.Error!void`
//! - `pub fn checkNetType(r: Record, design: Design, facts: *const NetFacts, types: *const NetTypes, t: *const NetTypeTable) Allocator.Error!void`
//! - `pub fn checkCombinationalLoop(r: Record, design: Design, intent: *const IntentMap, t: *const CombinationalLoopTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetFacts = @import("facts.zig").NetFacts;
const NetTypes = @import("facts.zig").NetTypes;
const PortTable = @import("../topology/port.zig").PortTable;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("topology_tables.zig");
const CombinationalLoopTable = tables.CombinationalLoopTable;
const FanoutTable = tables.FanoutTable;
const FloatingGateTable = tables.FloatingGateTable;
const FloatingWellTable = tables.FloatingWellTable;
const GatePathTable = tables.GatePathTable;
const MultipleDriversTable = tables.MultipleDriversTable;
const NetTypeTable = tables.NetTypeTable;
const SupplyPathTable = tables.SupplyPathTable;
const UnconnectedPinTable = tables.UnconnectedPinTable;

/// `FloatingGateTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkFloatingGate(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, t: *const FloatingGateTable) Allocator.Error!void {
    _ = design;
    _ = facts;
    _ = ports;
    try r.fillRows(&t.head, .refused);
}

/// `FloatingWellTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkFloatingWell(r: Record, design: Design, t: *const FloatingWellTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `MultipleDriversTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkMultipleDrivers(r: Record, design: Design, intent: *const IntentMap, t: *const MultipleDriversTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `UnconnectedPinTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkUnconnectedPin(r: Record, design: Design, facts: *const NetFacts, t: *const UnconnectedPinTable) Allocator.Error!void {
    _ = design;
    _ = facts;
    try r.fillRows(&t.head, .refused);
}

/// `FanoutTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkFanout(r: Record, design: Design, t: *const FanoutTable) Allocator.Error!void {
    _ = design;
    try r.fillRows(&t.head, .refused);
}

/// `SupplyPathTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkSupplyPath(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, intent: *const IntentMap, t: *const SupplyPathTable) Allocator.Error!void {
    _ = design;
    _ = facts;
    _ = ports;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `GatePathTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkGatePath(r: Record, design: Design, intent: *const IntentMap, t: *const GatePathTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `NetTypeTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkNetType(r: Record, design: Design, facts: *const NetFacts, types: *const NetTypes, t: *const NetTypeTable) Allocator.Error!void {
    _ = design;
    _ = facts;
    _ = types;
    try r.fillRows(&t.head, .refused);
}

/// `CombinationalLoopTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkCombinationalLoop(r: Record, design: Design, intent: *const IntentMap, t: *const CombinationalLoopTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}
