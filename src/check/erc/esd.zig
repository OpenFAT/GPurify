//! The esd kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/esd.rs.
//!
//! Contents:
//! - `pub fn checkEsdPath(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPathTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkEsdPinPair(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPinPairTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkEsdClampResistance(r: Record, design: Design, process: Process, t: *const EsdClampResistanceTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkEsdGroundCoupling(r: Record, design: Design, intent: *const IntentMap, t: *const EsdGroundCouplingTable) Allocator.Error!void`
//! - `pub fn checkEsdCrossDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, process: Process, t: *const EsdCrossDomainTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkEsdParasitic(r: Record, design: Design, t: *const EsdParasiticTable) Allocator.Error!void`
//! - `pub fn checkEsdExposed(r: Record, design: Design, intent: *const IntentMap, t: *const EsdExposedTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const Process = @import("power_grid.zig").Process;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("esd_tables.zig");
const EsdClampResistanceTable = tables.EsdClampResistanceTable;
const EsdCrossDomainTable = tables.EsdCrossDomainTable;
const EsdExposedTable = tables.EsdExposedTable;
const EsdGroundCouplingTable = tables.EsdGroundCouplingTable;
const EsdParasiticTable = tables.EsdParasiticTable;
const EsdPathTable = tables.EsdPathTable;
const EsdPinPairTable = tables.EsdPinPairTable;

/// `EsdPathTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdPath(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPathTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = process;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `EsdPinPairTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdPinPair(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPinPairTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = process;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `EsdClampResistanceTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdClampResistance(r: Record, design: Design, process: Process, t: *const EsdClampResistanceTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = process;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `EsdGroundCouplingTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdGroundCoupling(r: Record, design: Design, intent: *const IntentMap, t: *const EsdGroundCouplingTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `EsdCrossDomainTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdCrossDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, process: Process, t: *const EsdCrossDomainTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    _ = process;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `EsdParasiticTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdParasitic(r: Record, design: Design, t: *const EsdParasiticTable) Allocator.Error!void {
    _ = design;
    try r.fillRows(&t.head, .refused);
}

/// `EsdExposedTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEsdExposed(r: Record, design: Design, intent: *const IntentMap, t: *const EsdExposedTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}
