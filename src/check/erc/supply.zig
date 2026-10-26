//! The supply kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/supply.rs.
//!
//! Contents:
//! - `pub fn checkSupplyShort(r: Record, design: Design, t: *const SupplyShortTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkSoftConnection(r: Record, design: Design, t: *const SoftConnectionTable, connectivity: *const Connectivity, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkMissingTie(r: Record, design: Design, t: *const MissingTieTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkTieHighLow(r: Record, design: Design, facts: *const NetFacts, intent: *const IntentMap, t: *const TieHighLowTable) Allocator.Error!void`
//! - `pub fn checkEsdTopological(r: Record, design: Design, intent: *const IntentMap, t: *const EsdTopologicalTable) Allocator.Error!void`
//! - `pub fn checkFloatingSupply(r: Record, design: Design, ports: *const PortTable, intent: *const IntentMap, process: Process, t: *const FloatingSupplyTable) Allocator.Error!void`
//! - `pub fn checkMixedTag(r: Record, design: Design, t: *const MixedTagTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Connectivity = @import("ingest").deck.Connectivity;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetFacts = @import("facts.zig").NetFacts;
const PortTable = @import("../topology/port.zig").PortTable;
const Process = @import("power_grid.zig").Process;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("supply_tables.zig");
const EsdTopologicalTable = tables.EsdTopologicalTable;
const FloatingSupplyTable = tables.FloatingSupplyTable;
const MissingTieTable = tables.MissingTieTable;
const MixedTagTable = tables.MixedTagTable;
const SoftConnectionTable = tables.SoftConnectionTable;
const SupplyShortTable = tables.SupplyShortTable;
const TieHighLowTable = tables.TieHighLowTable;

/// `SupplyShortTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkSupplyShort(r: Record, design: Design, t: *const SupplyShortTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `SoftConnectionTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkSoftConnection(r: Record, design: Design, t: *const SoftConnectionTable, connectivity: *const Connectivity, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = connectivity;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `MissingTieTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkMissingTie(r: Record, design: Design, t: *const MissingTieTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `TieHighLowTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkTieHighLow(r: Record, design: Design, facts: *const NetFacts, intent: *const IntentMap, t: *const TieHighLowTable) Allocator.Error!void {
    _ = design;
    _ = facts;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `EsdTopologicalTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdTopological(r: Record, design: Design, intent: *const IntentMap, t: *const EsdTopologicalTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `FloatingSupplyTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkFloatingSupply(r: Record, design: Design, ports: *const PortTable, intent: *const IntentMap, process: Process, t: *const FloatingSupplyTable) Allocator.Error!void {
    _ = design;
    _ = ports;
    _ = intent;
    _ = process;
    try r.fillRows(&t.head, .refused);
}

/// `MixedTagTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkMixedTag(r: Record, design: Design, t: *const MixedTagTable) Allocator.Error!void {
    _ = design;
    try r.fillRows(&t.head, .refused);
}
