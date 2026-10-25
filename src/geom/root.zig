//! geom: coordinates, quantities, ids and boxes; the rest of geometry lands
//! in wave 1 (ARCHITECTURE.md). Only re-exports.
//!
//! A layout coordinate is a `Dbu`, an `i64` count of database units within
//! ±`max_abs_dbu` (`2^40`). Two coordinates multiply into a `DbuArea`
//! (`i128`) that cannot overflow, so every predicate and measure is exact
//! integer arithmetic. A physical value is a `Qty(dim, prefix)`; `Grid.toDbu`
//! crosses from physical length to grid units exactly or not at all.
//!
//! Contents:
//! - `Dbu`, `DbuArea`, `max_abs_dbu`, `inDomain`, `mulWide`, `Grid`, `GridError` (dbu.zig)
//! - `Qty`, `Dimension`, `Prefix`, `celsius`, `mul`, `div`, `Product`, `Quotient` (qty.zig)
//! - `StrTable`, `StrId` (intern.zig)
//! - `LayerId`, `PolyId` (ids.zig)
//! - `Bbox` (bbox.zig)
//! - `Device` (device.zig)

const dbu = @import("dbu.zig");
const qty = @import("qty.zig");
const intern = @import("intern.zig");
const ids = @import("ids.zig");
const bbox = @import("bbox.zig");
const device = @import("device.zig");

pub const Dbu = dbu.Dbu;
pub const DbuArea = dbu.DbuArea;
pub const max_abs_dbu = dbu.max_abs_dbu;
pub const inDomain = dbu.inDomain;
pub const mulWide = dbu.mulWide;
pub const Grid = dbu.Grid;
pub const GridError = dbu.GridError;

pub const Qty = qty.Qty;
pub const Dimension = qty.Dimension;
pub const Prefix = qty.Prefix;
pub const celsius = qty.celsius;
pub const mul = qty.mul;
pub const div = qty.div;
pub const Product = qty.Product;
pub const Quotient = qty.Quotient;

pub const StrTable = intern.StrTable;
pub const StrId = intern.StrId;

pub const LayerId = ids.LayerId;
pub const PolyId = ids.PolyId;

pub const Bbox = bbox.Bbox;
pub const Device = device.Device;

test {
    _ = dbu;
    _ = qty;
    _ = intern;
}
