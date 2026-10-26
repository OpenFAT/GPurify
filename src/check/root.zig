//! check: everything that reads a design and reports on it (ARCHITECTURE.md).
//! Only re-exports; check's Gompute kernel root.
//!
//! Files import only files above them in this order (a test in
//! tests/check.zig greps for back edges): report → rects → proximity →
//! topology/ → drc/ → erc/ → lvs/ → deck/.
//!
//! Contents:
//! - `report`: `Violations`, `Violation`, `Measurement`, `RuleRun`, `recordRun`, ...
//! - `rects`: `LayerRects`, `SortedRects`, owners, `polyDist2`, `segDist2`, `Holes`, `inMaterial`, ...
pub const report = @import("report.zig");
pub const rects = @import("rects.zig");

// ---- private ----

/// `std.testing.refAllDecls`, recursing into the namespaces and types this
/// module declares, so a pub function no test calls yet is still compiled.
fn refAll(comptime T: type) void {
    const std = @import("std");
    inline for (comptime std.meta.declarations(T)) |name| {
        const decl = @field(T, name);
        if (@TypeOf(decl) == type) switch (@typeInfo(decl)) {
            .@"struct", .@"union", .@"enum" => refAll(decl),
            else => {},
        } else _ = &@field(T, name);
    }
}

test {
    // Every pub body analyzed, called by a test yet or not.
    refAll(@This());
    _ = report;
    _ = rects;
}
