//! check: everything that reads a design and reports on it (ARCHITECTURE.md).
//! Only re-exports; check's Gompute kernel root.
//!
//! Files import only files above them in this order (a test in
//! tests/check.zig greps for back edges): report → rects → proximity →
//! topology/ → drc/ → erc/ → lvs/ → deck/.
//!
//! Contents:
//! - `report`: `Violations`, `Violation`, `Measurement`, `RuleRun`, `recordRun`, ...
pub const report = @import("report.zig");

test {
    _ = report;
}
