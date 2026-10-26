//! Every ERC rule kind, once, by the name a deck row resolves to, in Rust's
//! order: what the deck compiler checks a row against and the rule set
//! files rows under. In: nothing (a comptime table). Out: `Kind` and its
//! names. Ported from crates/check/src/deck/rules.rs (`ERC_KINDS`).
//!
//! Contents:
//! - `pub const Kind = enum(u8)`, `pub const names: [count][]const u8`, `pub const count: u32`
//! - `pub fn byName(name: []const u8) ?Kind`, `pub fn isKind(name: []const u8) bool`

const std = @import("std");

/// One ERC kind, in Rust's `ERC_KINDS` order. Disjoint from `drc/kinds.zig`'s.
pub const Kind = enum(u8) {
    antenna,
    antenna_electrical,
    conditional_tie,
    density_cmp,
    dielectric_field,
    domain_crossing,
    drain_source,
    dynamic_ir_drop,
    electromigration,
    em_current_density,
    em_rms,
    em_peak,
    em_thermal,
    esd_cross_domain,
    esd_exposed,
    esd_ground_coupling,
    esd_latchup,
    esd_parasitic,
    esd_path,
    esd_pin_pair,
    esd_clamp_resistance,
    esd_topological,
    fanout,
    floating_gate,
    floating_well,
    power_switch,
    matching,
    floating_supply,
    forward_diode,
    combinational_loop,
    gate_oxide,
    gate_path,
    guard_ring,
    guard_ring_bias,
    hot_carrier,
    hv_domain,
    hv_tag,
    ir_drop,
    latchup_victim,
    missing_isolation,
    missing_level_shifter,
    missing_tie,
    mixed_tag,
    multiple_drivers,
    net_type,
    p2p_resistance,
    reliability,
    soft_connection,
    supply_short,
    supply_path,
    tie_area,
    tie_high_low,
    unconnected_pin,
    undriven_gate,
    voltage_spacing,
    well_bias,
    well_sharing,
};

/// Every ERC kind's name, in `Kind` order.
pub const names = blk: {
    const fields = @typeInfo(Kind).@"enum".field_names;
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = f;
    break :blk out;
};

/// How many kinds there are.
pub const count: u32 = names.len;

/// The kind a deck row's resolved name names, or null for none of ERC's.
pub fn byName(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

pub fn isKind(name: []const u8) bool {
    return byName(name) != null;
}

test "the ERC name table is Rust's 57 kinds" {
    // Oracle: crates/check/src/deck/rules.rs `ERC_KINDS`: first, last, length.
    try std.testing.expectEqual(@as(usize, 57), names.len);
    try std.testing.expect(isKind("antenna") and isKind("well_sharing"));
    try std.testing.expect(!isKind("min_width"));
}
