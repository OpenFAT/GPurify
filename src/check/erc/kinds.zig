//! Every ERC rule kind's name, in Rust's order: just the name table, so the
//! deck compiler can tell an ERC row from an unknown kind (and refuse it by
//! name until the ERC port, wave 4). In: nothing. Out: `names`, `isKind`.
//! Ported from crates/check/src/deck/rules.rs (`ERC_KINDS`).
//!
//! Contents:
//! - `pub const names: []const []const u8`
//! - `pub fn isKind(name: []const u8) bool`

const std = @import("std");

/// Every ERC kind, disjoint from `drc/kinds.zig`.
pub const names = [_][]const u8{
    "antenna",
    "antenna_electrical",
    "conditional_tie",
    "density_cmp",
    "dielectric_field",
    "domain_crossing",
    "drain_source",
    "dynamic_ir_drop",
    "electromigration",
    "em_current_density",
    "em_rms",
    "em_peak",
    "em_thermal",
    "esd_cross_domain",
    "esd_exposed",
    "esd_ground_coupling",
    "esd_latchup",
    "esd_parasitic",
    "esd_path",
    "esd_pin_pair",
    "esd_clamp_resistance",
    "esd_topological",
    "fanout",
    "floating_gate",
    "floating_well",
    "power_switch",
    "matching",
    "floating_supply",
    "forward_diode",
    "combinational_loop",
    "gate_oxide",
    "gate_path",
    "guard_ring",
    "guard_ring_bias",
    "hot_carrier",
    "hv_domain",
    "hv_tag",
    "ir_drop",
    "latchup_victim",
    "missing_isolation",
    "missing_level_shifter",
    "missing_tie",
    "mixed_tag",
    "multiple_drivers",
    "net_type",
    "p2p_resistance",
    "reliability",
    "soft_connection",
    "supply_short",
    "supply_path",
    "tie_area",
    "tie_high_low",
    "unconnected_pin",
    "undriven_gate",
    "voltage_spacing",
    "well_bias",
    "well_sharing",
};

pub fn isKind(name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "the ERC name table is Rust's 57 kinds" {
    // Oracle: crates/check/src/deck/rules.rs `ERC_KINDS`: first, last, length.
    try std.testing.expectEqual(@as(usize, 57), names.len);
    try std.testing.expect(isKind("antenna") and isKind("well_sharing"));
    try std.testing.expect(!isKind("min_width"));
}
