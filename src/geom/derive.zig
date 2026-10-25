//! Derived-layer operations past the three booleans, as one namespace: the
//! deck's sizing, selection by relation or measure, holes, extents and edge
//! layers. Only re-exports; crates/geom/src/derive.rs split along its
//! transforms.
//!
//! Contents:
//! - `Error`, `mergeInto`, `sizedInto`, `holesInto`, `extentsInto`, `boxesInto` (derive_size.zig)
//! - `withAreaInto`, `withWidthInto`, `withBboxInto`, `Side`, `withRectInto`, `rectanglesInto` (derive_measure.zig)
//! - `interactingInto`, `insideInto`, `insideFlags`, `outsideInto`, `overlappingInto`, `overlappingFlags`,
//!   `coveringInto`, `holdingFigures`, `interiorPoint8`, `containsScaled` (derive_relate.zig)
//! - `EdgeOp`, `Extension`, `edgesInto`, `edgeBooleanInto`, `edgePartInto`, `edgeInteractingInto`,
//!   `extendedInto`, `withLengthInto` (derive_edges.zig)

const size = @import("derive_size.zig");
const measure = @import("derive_measure.zig");
const relate = @import("derive_relate.zig");
const edges = @import("derive_edges.zig");

pub const Error = size.Error;
pub const mergeInto = size.mergeInto;
pub const sizedInto = size.sizedInto;
pub const holesInto = size.holesInto;
pub const extentsInto = size.extentsInto;
pub const boxesInto = size.boxesInto;

pub const withAreaInto = measure.withAreaInto;
pub const withWidthInto = measure.withWidthInto;
pub const withBboxInto = measure.withBboxInto;
pub const Side = measure.Side;
pub const withRectInto = measure.withRectInto;
pub const rectanglesInto = measure.rectanglesInto;

pub const interactingInto = relate.interactingInto;
pub const insideInto = relate.insideInto;
pub const insideFlags = relate.insideFlags;
pub const outsideInto = relate.outsideInto;
pub const overlappingInto = relate.overlappingInto;
pub const overlappingFlags = relate.overlappingFlags;
pub const coveringInto = relate.coveringInto;
pub const holdingFigures = relate.holdingFigures;
pub const interiorPoint8 = relate.interiorPoint8;
pub const containsScaled = relate.containsScaled;

pub const EdgeOp = edges.EdgeOp;
pub const Extension = edges.Extension;
pub const edgesInto = edges.edgesInto;
pub const edgeBooleanInto = edges.edgeBooleanInto;
pub const edgePartInto = edges.edgePartInto;
pub const edgeInteractingInto = edges.edgeInteractingInto;
pub const extendedInto = edges.extendedInto;
pub const withLengthInto = edges.withLengthInto;
