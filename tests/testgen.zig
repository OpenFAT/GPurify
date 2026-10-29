//! testgen: seeded generators and oracles for the suites; never shipped.
//! Ported from crates/testgen/src/{rng,prop,shapes,graph}.rs (wave 1) and
//! {assertions,violation,netlist,scale,gds}.rs (wave 2). oracle.rs (external
//! tool lookup and runs) waits for the first differential test that needs
//! it. Only re-exports.
//!
//! Contents:
//! - `Rng` (testgen/rng.zig)
//! - `prop`: `check`, `seeds`, `parseSeeds`, `shrinkRects`, `Why`, `LayerRect` (testgen/prop.zig)
//! - `graph`: `graphWithPartition`, `GraphCase` (testgen/graph.zig)
//! - `gds`: `writeStore`, `writeStoreLabelled`, `writeLibrary`, `Structure`, `Placement`, `Array`, `Label`, `Error` (testgen/gds.zig)
//! - `shapes`: `LayoutBuilder`, `Ids`, `rect`, `hole`, `lShape`, `plusShape`, `uShape`, `randomRectilinearLayer`, `polygonArea` (testgen/shapes.zig)
//! - `assertions` and its functions re-exported: `assertClose`, `assertCloseRelative`, `assertRuleRan`, `assertClean`,
//!   `assertOnlyViolation`, `assertHasViolation`, `assertViolationsEq`, `assertBytesIdentical` (testgen/assertions.zig)
//! - `netlist`: `layoutFromNetlist`, `NetlistSpec`, `DeviceSpec`, `TerminalSpec`, `Floorplan`, `NetlistCase` (testgen/netlist.zig)
//! - `scale`: `scaleCorpus`, `ScaleSpec`, `ScaleCorpus` (testgen/scale.zig)
//! - `violation`: `layoutWithViolation`, `Amount`, `ShapeKind`, `ViolationShape`, `ViolationCase` (testgen/violation.zig)
//! - `oracle`: `run`, `Error`, `Diagnostic`: the comparison tools (testgen/oracle.zig)

pub const Rng = @import("testgen/rng.zig").Rng;
pub const prop = @import("testgen/prop.zig");
pub const graph = @import("testgen/graph.zig");
pub const shapes = @import("testgen/shapes.zig");
pub const gds = @import("testgen/gds.zig");
pub const assertions = @import("testgen/assertions.zig");
pub const netlist = @import("testgen/netlist.zig");
pub const scale = @import("testgen/scale.zig");
pub const violation = @import("testgen/violation.zig");
pub const oracle = @import("testgen/oracle.zig");
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
    _ = netlist;
    _ = scale;
    _ = violation;
    _ = oracle;
}
