//! check suite, ported from crates/check/tests/{report,topology,lvs}, plus the
//! dependency-order gate.
test {
    _ = @import("check");
    _ = @import("check/import_order.zig");
    _ = @import("check/report_measurement.zig");
    _ = @import("check/report_rule_run.zig");
    _ = @import("check/report_violation_table.zig");
    _ = @import("check/proximity_distance.zig");
    _ = @import("check/proximity_pairs.zig");
    _ = @import("check/topology_edges.zig");
    _ = @import("check/topology_extraction.zig");
    _ = @import("check/topology_devices.zig");
    _ = @import("check/topology_ports.zig");
    _ = @import("check/topology_laws.zig");
    _ = @import("check/lvs/digest.zig");
    _ = @import("check/lvs/graph.zig");
    _ = @import("check/lvs/compare.zig");
    _ = @import("check/lvs/reduce.zig");
    _ = @import("check/lvs/controls.zig");
    _ = @import("check/lvs/gates.zig");
    _ = @import("check/lvs/checks.zig");
}
