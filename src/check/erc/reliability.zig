//! The reliability kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/reliability.rs.
//!
//! Contents:
//! - `pub fn checkReliability(r: Record, power: Power, intent: *const IntentMap, temperature: Kelvin, t: *const ReliabilityTable) Allocator.Error!void`
//! - `pub fn checkHvDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvDomainTable) Allocator.Error!void`
//! - `pub fn checkEsdLatchup(r: Record, design: Design, intent: *const IntentMap, t: *const EsdLatchupTable, scratch: *Scratch) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;
const Kelvin = @import("electrical_tables.zig").Kelvin;
const NetVoltage = @import("voltage.zig").NetVoltage;
const Power = @import("power_grid.zig").Power;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("esd_tables.zig");
const EsdLatchupTable = tables.EsdLatchupTable;
const HvDomainTable = tables.HvDomainTable;
const ReliabilityTable = tables.ReliabilityTable;

/// `ReliabilityTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkReliability(r: Record, power: Power, intent: *const IntentMap, temperature: Kelvin, t: *const ReliabilityTable) Allocator.Error!void {
    _ = power;
    _ = intent;
    _ = temperature;
    try r.fillRows(&t.head, .refused);
}

/// `HvDomainTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkHvDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvDomainTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `EsdLatchupTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdLatchup(r: Record, design: Design, intent: *const IntentMap, t: *const EsdLatchupTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}
