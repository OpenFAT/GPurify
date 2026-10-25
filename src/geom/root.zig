//! geom: coordinates, quantities, stored geometry, and exact integer geometry
//! on it (ARCHITECTURE.md). Only re-exports; geom's Gompute kernel root.
//!
//! A layout coordinate is a `Dbu`, an `i64` count of database units within
//! ±`max_abs_dbu` (`2^40`). Two coordinates multiply into a `DbuArea`
//! (`i128`) that cannot overflow, so every predicate and measure is exact
//! integer arithmetic. A physical value is a `Qty(dim, prefix)`; `Grid.toDbu`
//! crosses from physical length to grid units exactly or not at all.
//!
//! Rings live in a `GeometryStore` (rows grouped by layer); `view.validateLayer`
//! turns one layer into a `ValidatedLayer` every algorithm below reads. Functions
//! named `*Into` clear and refill a caller-owned output.
//!
//! Contents:
//! - `Dbu`, `DbuArea`, `max_abs_dbu`, `inDomain`, `mulWide`, `Grid`, `GridError` (dbu.zig)
//! - `Qty`, `Dimension`, `Prefix`, `celsius`, `mul`, `div`, `Product`, `Quotient` (qty.zig)
//! - `StrTable`, `StrId` (intern.zig)
//! - `LayerId`, `PolyId` (ids.zig)
//! - `Bbox` (bbox.zig)
//! - `Device` (device.zig)
//! - `linalg`: `dot`, `nrm2`, `spmv`, and the `axpy` / `xpay` Gompute specs
//! - `connectivity`: `componentsInto`
//! - `ops`: `Point`, `Seg`, `Ring`, predicates and exact distances
//! - `simple`: `selfIntersects`
//! - `store`: `GeometryStore`, `GeometryStoreBuilder`
//! - `view`: `ValidatedLayer`, `Polygon`, `validateLayer`, `ringDefect`
//! - `index`: `SpatialIndex`, `candidatePairsInto`, `crossLayerPairsInto`
//! - `rects`: `decomposeInto`, `coveredArea`, `clippedArea`
//! - aliases: `Point`, `Seg`, `Ring`, `GeometryStore`, `GeometryStoreBuilder`,
//!   `ValidatedLayer`, `Polygon`

const dbu = @import("dbu.zig");
const qty = @import("qty.zig");
const intern = @import("intern.zig");
const ids = @import("ids.zig");
const bbox = @import("bbox.zig");
const device = @import("device.zig");
pub const linalg = @import("linalg.zig");
pub const connectivity = @import("connectivity.zig");
pub const ops = @import("ops.zig");
pub const simple = @import("simple.zig");
pub const store = @import("store.zig");
pub const view = @import("view.zig");
pub const index = @import("index.zig");
pub const rects = @import("rects.zig");

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

pub const Point = ops.Point;
pub const Seg = ops.Seg;
pub const Ring = ops.Ring;
pub const GeometryStore = store.GeometryStore;
pub const GeometryStoreBuilder = store.GeometryStoreBuilder;
pub const ValidatedLayer = view.ValidatedLayer;
pub const Polygon = view.Polygon;

// The device compile reads only this root's comptime blocks: name every
// kernel-owning file here.
comptime {
    _ = linalg;
}

test {
    _ = dbu;
    _ = qty;
    _ = intern;
    _ = linalg;
    _ = connectivity;
    _ = ops;
    _ = simple;
    _ = store;
    _ = view;
    _ = index;
    _ = rects;
}
