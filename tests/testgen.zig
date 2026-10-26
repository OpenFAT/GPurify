//! testgen: seeded generators and oracles for the suites; never shipped.
//! Ported from crates/testgen/src/{rng,prop,shapes,graph}.rs (wave 1); the
//! GDS writer, assertions, violations, netlists, scale and oracles land in
//! wave 2. Only re-exports.
//!
//! Contents:
//! - `Rng` (testgen/rng.zig)
//! - `prop`: `check`, `seeds`, `parseSeeds`, `shrinkRects`, `Why`, `LayerRect` (testgen/prop.zig)
//! - `graph`: `graphWithPartition`, `GraphCase` (testgen/graph.zig)
//! - `shapes`: `LayoutBuilder`, `Ids`, `rect`, `hole`, `lShape`, `plusShape`, `uShape`, `randomRectilinearLayer`, `polygonArea` (testgen/shapes.zig)
//! - `assertions` and its functions re-exported: `assertClose`, `assertCloseRelative`, `assertRuleRan`, `assertClean`,
//!   `assertOnlyViolation`, `assertHasViolation`, `assertViolationsEq`, `assertBytesIdentical` (testgen/assertions.zig)

pub const Rng = @import("testgen/rng.zig").Rng;
pub const prop = @import("testgen/prop.zig");
pub const graph = @import("testgen/graph.zig");
pub const shapes = @import("testgen/shapes.zig");
pub const assertions = @import("testgen/assertions.zig");
pub const assertClose = assertions.assertClose;
pub const assertCloseRelative = assertions.assertCloseRelative;
pub const assertRuleRan = assertions.assertRuleRan;
pub const assertClean = assertions.assertClean;
pub const assertOnlyViolation = assertions.assertOnlyViolation;
pub const assertHasViolation = assertions.assertHasViolation;
pub const assertViolationsEq = assertions.assertViolationsEq;
pub const assertBytesIdentical = assertions.assertBytesIdentical;

test {
    _ = @import("testgen/rng.zig");
    _ = prop;
    _ = graph;
    _ = shapes;
    _ = assertions;
}
