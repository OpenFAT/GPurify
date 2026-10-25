//! Index handles, one per table, so passing a layer where a polygon row is
//! expected is a type error. Convert with `@backingInt` / `@fromBackingInt`.
//!
//! Contents:
//! - `pub const LayerId = enum(u16)`
//! - `pub const PolyId = enum(u32)`

/// A layer as numbered by `ingest`: dense from 0, drawn layers before the
/// layers a deck derives from them.
pub const LayerId = enum(u16) { _ };

/// A polygon row of the geometry store; also indexes `ingest`'s provenance
/// columns.
pub const PolyId = enum(u32) { _ };
