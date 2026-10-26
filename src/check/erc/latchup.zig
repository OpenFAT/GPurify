//! The latchup kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/latchup.rs.
//!
//! Contents:
//! - `pub fn checkGuardRingBias(r: Record, design: Design, intent: *const IntentMap, t: *const GuardRingBiasTable) Allocator.Error!void`
//! - `pub fn checkTieArea(r: Record, design: Design, t: *const TieAreaTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkGuardRing(r: Record, design: Design, t: *const GuardRingTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkForwardDiode(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ForwardDiodeTable) Allocator.Error!void`
//! - `pub fn checkConditionalTie(r: Record, design: Design, t: *const ConditionalTieTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkLatchupVictim(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const LatchupVictimTable, scratch: *Scratch) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("latchup_tables.zig");
const ConditionalTieTable = tables.ConditionalTieTable;
const ForwardDiodeTable = tables.ForwardDiodeTable;
const GuardRingBiasTable = tables.GuardRingBiasTable;
const GuardRingTable = tables.GuardRingTable;
const LatchupVictimTable = tables.LatchupVictimTable;
const TieAreaTable = tables.TieAreaTable;

/// `GuardRingBiasTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkGuardRingBias(r: Record, design: Design, intent: *const IntentMap, t: *const GuardRingBiasTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `TieAreaTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkTieArea(r: Record, design: Design, t: *const TieAreaTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `GuardRingTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkGuardRing(r: Record, design: Design, t: *const GuardRingTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `ForwardDiodeTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkForwardDiode(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ForwardDiodeTable) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    try r.fillRows(&t.head, .refused);
}

/// `ConditionalTieTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkConditionalTie(r: Record, design: Design, t: *const ConditionalTieTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `LatchupVictimTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkLatchupVictim(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const LatchupVictimTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = intent;
    _ = voltage;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}
