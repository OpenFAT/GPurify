//! The electrical kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/electrical.rs.
//!
//! Contents:
//! - `pub fn checkP2pResistance(r: Record, design: Design, networks: ?*const NetNetworks, t: *const P2pResistanceTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const IrDropTable) Allocator.Error!void`
//! - `pub fn checkEmCurrentDensity(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmCurrentDensityTable) Allocator.Error!void`
//! - `pub fn checkEmAc(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmAcTable) Allocator.Error!void`
//! - `pub fn checkElectromigration(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const ElectromigrationTable) Allocator.Error!void`
//! - `pub fn checkDynamicIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const DynamicIrDropTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkEmThermal(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const EmThermalTable, height_nm: []const f64) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const Grid = geom.Grid;
const IntentMap = @import("facts.zig").IntentMap;
const Kelvin = @import("electrical_tables.zig").Kelvin;
const NetNetworks = @import("power_grid.zig").NetNetworks;
const Power = @import("power_grid.zig").Power;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("electrical_tables.zig");
const DynamicIrDropTable = tables.DynamicIrDropTable;
const ElectromigrationTable = tables.ElectromigrationTable;
const EmAcTable = tables.EmAcTable;
const EmCurrentDensityTable = tables.EmCurrentDensityTable;
const EmThermalTable = tables.EmThermalTable;
const IrDropTable = tables.IrDropTable;
const P2pResistanceTable = tables.P2pResistanceTable;

/// `P2pResistanceTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkP2pResistance(r: Record, design: Design, networks: ?*const NetNetworks, t: *const P2pResistanceTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = networks;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `IrDropTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const IrDropTable) Allocator.Error!void {
    _ = power;
    _ = intent;
    try r.fillRows(&t.head, .refused);
}

/// `EmCurrentDensityTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEmCurrentDensity(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmCurrentDensityTable) Allocator.Error!void {
    _ = power;
    _ = intent;
    _ = grid;
    try r.fillRows(&t.head, .refused);
}

/// `EmAcTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEmAc(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmAcTable) Allocator.Error!void {
    _ = power;
    _ = intent;
    _ = grid;
    try r.fillRows(&t.head, .refused);
}

/// `ElectromigrationTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkElectromigration(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const ElectromigrationTable) Allocator.Error!void {
    _ = power;
    _ = intent;
    _ = grid;
    _ = temperature;
    try r.fillRows(&t.head, .refused);
}

/// `DynamicIrDropTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkDynamicIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const DynamicIrDropTable, scratch: *Scratch) Allocator.Error!void {
    _ = power;
    _ = intent;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `EmThermalTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkEmThermal(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const EmThermalTable, height_nm: []const f64) Allocator.Error!void {
    _ = power;
    _ = intent;
    _ = grid;
    _ = temperature;
    _ = height_nm;
    try r.fillRows(&t.head, .refused);
}
