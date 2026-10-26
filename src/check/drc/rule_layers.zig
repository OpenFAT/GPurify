//! Which layers a rule reads: its main layers (refused when one is an
//! uncomputed derived layer; every finding reports on one of them) and the
//! rest (anchors, density boundaries, an upper cut layer), which together
//! decide when the spine forgets a layer's validation. In: one `Rule`. Out:
//! up to seven layers, null past them. Ported from
//! crates/check/src/drc/ruleset.rs (`Rule::layers`, `Rule::more_layers`).
//!
//! Contents:
//! - `pub const Layers = struct { main: [3]?LayerId, more: [4]?LayerId }`, `pub fn layersOf(rule: Rule) Layers`

const geom = @import("geom");
const LayerId = geom.LayerId;
const Rule = @import("rows.zig").Rule;

/// The layers one rule reads.
pub const Layers = struct {
    /// One to three main layers, null past them.
    main: [3]?LayerId,
    /// Anchors, a density boundary, an upper cut layer; null past them.
    more: [4]?LayerId = @splat(null),
};

/// The layers `rule` reads. An `off_grid` and a `via_stack` read raw rows,
/// never validated, and declare none; an `angle` without a layer reads
/// every drawn one and declares none.
pub fn layersOf(rule: Rule) Layers {
    return switch (rule) {
        .min_width, .max_width, .min_edge_length, .notch, .min_spacing, .corner_to_corner, .edge_min_length, .edge_width => |r| one(r.layer),
        .cut_size => |r| one(r.layer),
        .eol_spacing => |r| one(r.layer),
        .prl_spacing => |r| one(r.layer),
        .wide_dependent_spacing => |r| one(r.layer),
        .min_area, .min_enclosed_area, .total_area => |r| one(r.layer),
        .cheesing => |r| one(r.layer),
        .critical_area => |r| one(r.layer),
        .mean_critical_area => |r| one(r.layer),
        .redundant_via => |r| one(r.layer),
        .via_array_spacing => |r| one(r.layer),
        .cut_spacing => |r| one(r.layer),
        .cut_class_spacing, .spacing_table, .tip_spacing_table, .two_width_spacing_table, .span_length => |r| one(r.layer),
        .multi_patterning => |r| one(r.layer),
        .anchored_patterning => |r| .{ .main = of(r.layer, null, null).main, .more = r.anchors },
        .sadp => |r| one(r.layer),
        .sadp_line_end => |r| one(r.layer),
        .forbidden, .origin => |r| one(r.layer),
        .attached_wide_spacing => |r| one(r.layer),
        .count => |r| one(r.layer),
        .aspect_ratio => |r| one(r.layer),
        .cut_class => |r| one(r.layer),
        .edge_facing_space => |r| one(r.layer),
        .allowed_width => |r| one(r.layer),
        .min_step => |r| one(r.layer),
        .min_step_adjacent => |r| one(r.layer),
        .forbidden_spacing => |r| one(r.layer),
        .eol_keep_out => |r| one(r.layer),
        .eol_extension_spacing => |r| one(r.layer),
        .keep_out_zone => |r| one(r.layer),
        .protrusion_width => |r| one(r.layer),
        .pattern_match => |r| one(r.layer),
        .convex_corner_spacing => |r| one(r.layer),
        .exact_pitch => |r| one(r.layer),
        .edge_spacing => |r| of(r.a, r.b, null),
        .net_spacing => |r| of(r.layer, r.other, null),
        .density => |r| of(r.layer, r.boundary, null),
        .global_density => |r| of(r.layer, r.boundary, null),
        .eol_within_spacing => |r| of(r.layer, if (r.lef58.enclose_cut) |e| e.cut else null, null),
        .min_enclosure, .asymmetric_enclosure => |r| of(r.outer, r.inner, if (r.wire.extra_cut) |e| e.other else null),
        .min_spacing_diff, .projection_spacing, .overlap => |r| of(r.a, r.b, null),
        .density_balance => |r| .{ .main = of(r.a, r.b, null).main, .more = .{ r.boundary, null, null, null } },
        .cover_density => |r| .{ .main = of(r.layer, r.cover, null).main, .more = .{ r.boundary, null, null, null } },
        .max_enclosure, .adjacent_enclosure, .noncoincident_enclosure => |r| of(r.outer, r.inner, null),
        .full_width => |r| of(r.outer, r.inner, null),
        .min_extension => |r| of(r.layer, r.reference, null),
        .gate_corner => |r| of(r.layer, r.reference, null),
        .max_distance_to_tap => |r| of(r.well, r.tap, null),
        .must_contain => |r| of(r.outer, r.inner, null),
        .must_be_inside => |r| of(r.inner, r.outer, null),
        .region_density => |r| of(r.layer, r.region, null),
        .edge_enclosure => |r| of(r.edges, r.outer, null),
        .minimum_cut => |r| of(r.cut, r.wide, r.other),
        .cut_area_change => |r| .{ .main = of(r.pre, r.post, r.lower).main, .more = .{ r.upper, null, null, null } },
        .dfm_score => |r| of(r.layer, r.outer, null),
        .via_redundancy => |r| of(r.cut, r.lower, r.upper),
        .angle => |r| of(r.layer, null, null),
        .min_interior_angle => |r| of(r.layer, null, null),
        .polygon_validity => |r| of(r.layer, null, null),
        .off_grid, .via_stack => of(null, null, null),
        .max_cut_spacing => |r| of(r.cut, r.others, null),
        .stack_spacing => |r| of(r.a, r.b, r.metal),
        .metal_width_via => |r| of(r.cut, r.below, r.above),
    };
}

// ---- private ----

fn one(layer: LayerId) Layers {
    return of(layer, null, null);
}

fn of(a: ?LayerId, b: ?LayerId, c: ?LayerId) Layers {
    return .{ .main = .{ a, b, c } };
}
