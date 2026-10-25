//! testgen: seeded generators and oracles for the suites; never shipped.
//! Ported from crates/testgen/src/{rng,prop,shapes,graph}.rs (wave 1); the
//! GDS writer, assertions, violations, netlists, scale and oracles land in
//! wave 2. Only re-exports.
//!
//! Contents:
//! - `Rng` (testgen/rng.zig)
//! - `prop`: `check`, `seeds`, `parseSeeds`, `shrinkRects`, `Why`, `LayerRect` (testgen/prop.zig)
//! - `graph`: `graphWithPartition`, `GraphCase` (testgen/graph.zig)

pub const Rng = @import("testgen/rng.zig").Rng;
pub const prop = @import("testgen/prop.zig");
pub const graph = @import("testgen/graph.zig");

test {
    _ = @import("testgen/rng.zig");
    _ = prop;
    _ = graph;
}
