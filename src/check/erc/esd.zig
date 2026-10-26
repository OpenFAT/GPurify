//! The ESD kinds' entries: each skips without usable intent where its
//! kind needs the rails, then runs its transform (esd_path.zig,
//! esd_pins.zig, esd_cross.zig, esd_exposed.zig). In: the design, the
//! intent, the voltages, the process, a kind's table. Out: violations and
//! one `RuleRun` per row. Ported from crates/check/src/erc/rules/esd.rs.
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
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const Process = @import("power_grid.zig").Process;
const Scratch = @import("scratch.zig").Scratch;
const path = @import("esd_path.zig");
const pins = @import("esd_pins.zig");
const cross = @import("esd_cross.zig");
const exposed = @import("esd_exposed.zig");
const tables = @import("esd_tables.zig");
const EsdClampResistanceTable = tables.EsdClampResistanceTable;
const EsdCrossDomainTable = tables.EsdCrossDomainTable;
const EsdExposedTable = tables.EsdExposedTable;
const EsdGroundCouplingTable = tables.EsdGroundCouplingTable;
const EsdParasiticTable = tables.EsdParasiticTable;
const EsdPathTable = tables.EsdPathTable;
const EsdPinPairTable = tables.EsdPinPairTable;

/// ESD discharge paths under a forced current (catalog ERC-C2/C6/C7/C8/
/// C14/D4): pin pairs whose path resistance or rise is too high, clamps,
/// wires and cuts carrying more than their rating, wires too narrow.
pub fn checkEsdPath(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPathTable, scratch: *Scratch) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try path.esdPath(r, design, intent, process, t, scratch);
}

/// Pin-to-pin path resistance between two signal pins (ERC-C6).
pub fn checkEsdPinPair(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPinPairTable, scratch: *Scratch) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try pins.esdPinPair(r, design, intent, process, t, scratch);
}

/// A clamp too far (too resistive) from its pad (ERC-C14). Needs no intent.
pub fn checkEsdClampResistance(r: Record, design: Design, process: Process, t: *const EsdClampResistanceTable, scratch: *Scratch) Allocator.Error!void {
    try pins.esdClampResistance(r, design, process, t, scratch);
}

/// Declared grounds not coupled into one group (ERC-C5).
pub fn checkEsdGroundCoupling(r: Record, design: Design, intent: *const IntentMap, t: *const EsdGroundCouplingTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try cross.esdGroundCoupling(r, design, intent, t);
}

/// A signal crossing power domains unprotected (ERC-C4, ERC-C9).
pub fn checkEsdCrossDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, process: Process, t: *const EsdCrossDomainTable, scratch: *Scratch) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try cross.esdCrossDomain(r, design, intent, voltage, process, t, scratch);
}

/// A pad junction close to another net's (ERC-C10). Needs no intent.
pub fn checkEsdParasitic(r: Record, design: Design, t: *const EsdParasiticTable) Allocator.Error!void {
    try exposed.esdParasitic(r, design, t);
}

/// Transistors a pad exposes unprotected (ERC-C3).
pub fn checkEsdExposed(r: Record, design: Design, intent: *const IntentMap, t: *const EsdExposedTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try exposed.esdExposed(r, design, intent, t);
}
