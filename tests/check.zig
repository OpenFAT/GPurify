//! check suite, ported from crates/check/tests/{report,topology}, plus the
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
    _ = @import("check/drc/width_rules.zig");
    _ = @import("check/drc/spacing_rules.zig");
    _ = @import("check/drc/spacing_deck.zig");
    _ = @import("check/drc/density_kernel.zig");
    _ = @import("check/drc/area_rules.zig");
    _ = @import("check/drc/density_rules.zig");
}
