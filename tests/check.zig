//! check suite, ported from crates/check/tests/{report,topology}, plus the
//! dependency-order gate.
test {
    _ = @import("check");
    _ = @import("check/report_measurement.zig");
    _ = @import("check/report_rule_run.zig");
    _ = @import("check/report_violation_table.zig");
    _ = @import("check/proximity_distance.zig");
    _ = @import("check/proximity_pairs.zig");
}
