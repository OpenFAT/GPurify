//! The antenna kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/antenna.rs.
//!
//! Contents:
//! - `pub fn checkAntenna(r: Record, design: Design, pins: []const MacroPinAntenna, t: *const AntennaTable, stack: Stack, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkAntennaElectrical(r: Record, design: Design, pins: []const MacroPinAntenna, grid: Grid, t: *const AntennaElectricalTable, stack: Stack, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkDensityCmp(r: Record, design: Design, die: Bbox, t: *const DensityCmpTable, scratch: *Scratch) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Bbox = geom.Bbox;
const Design = @import("head.zig").Design;
const Grid = geom.Grid;
const MacroPinAntenna = @import("antenna_tables.zig").MacroPinAntenna;
const Scratch = @import("scratch.zig").Scratch;
const Stack = @import("antenna_tables.zig").Stack;
const tables = @import("antenna_tables.zig");
const AntennaElectricalTable = tables.AntennaElectricalTable;
const AntennaTable = tables.AntennaTable;
const DensityCmpTable = tables.DensityCmpTable;

/// `AntennaTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkAntenna(r: Record, design: Design, pins: []const MacroPinAntenna, t: *const AntennaTable, stack: Stack, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = pins;
    _ = stack;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `AntennaElectricalTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkAntennaElectrical(r: Record, design: Design, pins: []const MacroPinAntenna, grid: Grid, t: *const AntennaElectricalTable, stack: Stack, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = pins;
    _ = grid;
    _ = stack;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}

/// `DensityCmpTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkDensityCmp(r: Record, design: Design, die: Bbox, t: *const DensityCmpTable, scratch: *Scratch) Allocator.Error!void {
    _ = design;
    _ = die;
    _ = scratch;
    try r.fillRows(&t.head, .refused);
}
