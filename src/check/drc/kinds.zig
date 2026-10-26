//! Every DRC rule kind, once, by the name a deck row resolves to
//! (`min_width` for `width(L) >= len`), in Rust's `Rule` variant order. In:
//! nothing (a comptime table). Out: `Kind` and its names, which the deck
//! compiler checks a row against and the spine switches on. Ported from
//! crates/check/src/deck/rules.rs (`DRC_KINDS`).
//!
//! Contents:
//! - `pub const Kind = enum(u8)`, `Kind.name(k: Kind) []const u8`
//! - `pub fn byName(name: []const u8) ?Kind`
//! - `pub const count: u32`

const std = @import("std");

/// One DRC kind. Disjoint from `erc/kinds.zig`'s names.
pub const Kind = enum(u8) {
    min_width,
    max_width,
    cut_size,
    min_edge_length,
    notch,
    min_spacing,
    min_spacing_diff,
    projection_spacing,
    eol_spacing,
    prl_spacing,
    corner_to_corner,
    wide_dependent_spacing,
    min_area,
    min_enclosed_area,
    cheesing,
    density,
    global_density,
    critical_area,
    mean_critical_area,
    density_balance,
    via_redundancy,
    dfm_score,
    pattern_match,
    cut_area_change,
    cover_density,
    min_enclosure,
    noncoincident_enclosure,
    full_width,
    asymmetric_enclosure,
    max_enclosure,
    adjacent_enclosure,
    min_extension,
    gate_corner,
    overlap,
    max_distance_to_tap,
    off_grid,
    angle,
    redundant_via,
    minimum_cut,
    via_stack,
    metal_width_via,
    stack_spacing,
    max_cut_spacing,
    via_array_spacing,
    cut_spacing,
    cut_class_spacing,
    multi_patterning,
    anchored_patterning,
    sadp,
    sadp_line_end,
    forbidden,
    must_contain,
    must_be_inside,
    net_spacing,
    spacing_table,
    attached_wide_spacing,
    edge_min_length,
    edge_spacing,
    edge_enclosure,
    count,
    aspect_ratio,
    total_area,
    cut_class,
    edge_width,
    edge_facing_space,
    region_density,
    allowed_width,
    min_interior_angle,
    polygon_validity,
    min_step,
    min_step_adjacent,
    tip_spacing_table,
    forbidden_spacing,
    eol_within_spacing,
    eol_keep_out,
    eol_extension_spacing,
    origin,
    protrusion_width,
    keep_out_zone,
    two_width_spacing_table,
    span_length,
    convex_corner_spacing,
    exact_pitch,

    /// The name a deck row resolves to.
    pub fn name(k: Kind) []const u8 {
        return @tagName(k);
    }
};

/// How many kinds there are.
pub const count: u32 = @typeInfo(Kind).@"enum".field_names.len;

/// The kind a deck row's resolved name names, or null for none of DRC's.
pub fn byName(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

test "the kind list is Rust's, 83 names in variant order" {
    // Oracle: crates/check/src/deck/rules.rs `DRC_KINDS`, first, last and length.
    try std.testing.expectEqual(@as(u32, 83), count);
    try std.testing.expectEqual(Kind.min_width, byName("min_width").?);
    try std.testing.expectEqualStrings("exact_pitch", @as(Kind, @fromBackingInt(@intCast(count - 1))).name());
    try std.testing.expectEqual(null, byName("antenna"));
}
