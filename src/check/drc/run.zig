//! The DRC spine: every rule of a `RuleSet`, one at a time, in deck order.
//! In: the set, the store, its net column (or none) and the backend. Out:
//! `out` refilled with the rules' violations in rule order (not yet
//! canonical; see `Violations.sortCanonical`) and `runs` with exactly one
//! `RuleRun` per rule. A rule on an uncomputed derived layer is refused, a
//! warning rule's findings are warnings, and each layer's validation is
//! dropped after the last rule that reads it. Ported from
//! crates/check/src/drc/ruleset.rs (`RuleSet::run_with_nets`, `dfm_scored`).
//!
//! Contents:
//! - `pub fn ported(kind: Kind) bool` (interim, until every family lands)
//! - `pub fn run(gpa: Allocator, device: Device, rs: *const RuleSet, store: *const GeometryStore, poly_net: ?[]const u32, out: *Violations, runs: *std.ArrayList(RuleRun)) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Device = geom.Device;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const Verdict = report.Verdict;
const RuleSet = @import("rule_set.zig").RuleSet;
const Rule = @import("rows.zig").Rule;
const Kind = @import("kinds.zig").Kind;
const layersOf = @import("rule_layers.zig").layersOf;
const scratch = @import("scratch.zig");
const Scratch = scratch.Scratch;
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const width = @import("width.zig");
const width_edges = @import("width_edges.zig");
const width_step = @import("width_step.zig");
const pattern = @import("pattern.zig");

/// Runs every rule of `rs` over `store`. `out` and `runs` are cleared
/// first. `poly_net` is the extraction's net column (`NetTable.netColumn`)
/// or null, which a net rule records as refused. Each layer is validated at
/// most once per call.
pub fn run(gpa: Allocator, device: Device, rs: *const RuleSet, store: *const GeometryStore, poly_net: ?[]const u32, out: *Violations, runs: *std.ArrayList(RuleRun)) Error!void {
    out.truncate(0);
    runs.clearRetainingCapacity();
    if (poly_net) |nets| assert(nets.len == store.polyCount());
    var s: Scratch = .{ .p = .{ .device = device } };
    defer s.deinit(gpa);
    // Layers `0..drawn` are drawn; the rest are the deck's derived ones.
    const drawn: u32 = if (rs.first_derived) |l| @min(@backingInt(l), store.layerCount()) else store.layerCount();
    // The last rule reading each layer; its validation is dropped after it.
    var last_use: std.ArrayList(u32) = .empty;
    defer last_use.deinit(gpa);
    for (0..rs.len()) |at| {
        const read = layersOf(rs.get(@intCast(at)));
        for (read.main ++ read.more) |maybe| if (maybe) |l| {
            const i = @backingInt(l);
            if (i >= last_use.items.len) try last_use.appendNTimes(gpa, 0, i + 1 - last_use.items.len);
            last_use.items[i] = @intCast(at);
        };
    }
    for (0..rs.len()) |at| {
        const rule = rs.get(@intCast(at));
        const before = out.len();
        const c: Ctx = .{ .gpa = gpa, .store = store, .rule = rs.id.items[at], .s = &s, .out = out, .drawn = drawn, .rs = rs, .poly_net = poly_net };
        const read = layersOf(rule);
        // A rule on a derived layer that could not be computed refuses; the
        // rest run (N-H12-1).
        const uncomputed = for (read.main) |maybe| {
            if (maybe) |l| if (store.isUncomputed(l)) break true;
        } else false;
        const verdict = if (uncomputed) report.refused else try dispatch(&c, rule);
        if (rs.severity.items[at] == .warning) @memset(out.severity.items[before..], .warning);
        try report.recordRun(gpa, runs, out, before, c.rule, verdict.outcome, verdict.examined);
        // A rule over every layer (`angle` with none, `off_grid`,
        // `via_stack`) declares none; any other reports only on its own.
        if (read.main[0] != null) for (out.layer.items[before..]) |l| {
            assert(std.mem.indexOfScalar(?LayerId, &read.main, l) != null);
        };
        for (read.main ++ read.more) |maybe| if (maybe) |l| {
            if (last_use.items[@backingInt(l)] == at) s.p.validated.forget(gpa, l);
        };
    }
}

/// Whether this build runs `kind`: the deck compiler refuses a kind it does
/// not (`error.KindNotPorted`) until its family lands.
pub fn ported(kind: Kind) bool {
    return switch (kind) {
        .min_spacing,
        .min_spacing_diff,
        .projection_spacing,
        .eol_spacing,
        .prl_spacing,
        .corner_to_corner,
        .wide_dependent_spacing,
        .min_area,
        .min_enclosed_area,
        .cheesing,
        .density,
        .global_density,
        .critical_area,
        .mean_critical_area,
        .density_balance,
        .via_redundancy,
        .dfm_score,
        .cut_area_change,
        .cover_density,
        .min_enclosure,
        .noncoincident_enclosure,
        .full_width,
        .asymmetric_enclosure,
        .max_enclosure,
        .adjacent_enclosure,
        .min_extension,
        .gate_corner,
        .overlap,
        .max_distance_to_tap,
        .off_grid,
        .angle,
        .redundant_via,
        .minimum_cut,
        .via_stack,
        .metal_width_via,
        .stack_spacing,
        .max_cut_spacing,
        .via_array_spacing,
        .cut_spacing,
        .cut_class_spacing,
        .multi_patterning,
        .anchored_patterning,
        .sadp,
        .sadp_line_end,
        .forbidden,
        .must_contain,
        .must_be_inside,
        .net_spacing,
        .spacing_table,
        .attached_wide_spacing,
        .edge_min_length,
        .edge_spacing,
        .edge_enclosure,
        .count,
        .aspect_ratio,
        .total_area,
        .edge_width,
        .edge_facing_space,
        .region_density,
        .min_interior_angle,
        .polygon_validity,
        .tip_spacing_table,
        .forbidden_spacing,
        .eol_within_spacing,
        .eol_keep_out,
        .eol_extension_spacing,
        .origin,
        .keep_out_zone,
        .two_width_spacing_table,
        .span_length,
        .convex_corner_spacing,
        .exact_pitch,
        => false,
        else => true,
    };
}

// ---- private ----

/// One rule row, by kind.
fn dispatch(c: *const Ctx, rule: Rule) Error!Verdict {
    return switch (rule) {
        .min_width => |r| width.facing(c, r.layer, r.limit, .width),
        .max_width => |r| width.maxWidth(c, r),
        .cut_size => |r| width.cutSize(c, r),
        .min_edge_length => |r| width_edges.minEdgeLength(c, r),
        .notch => |r| width.facing(c, r.layer, r.limit, .notch),
        .cut_class => |r| width.cutClass(c, r),
        .allowed_width => |r| width.allowedWidth(c, r),
        .protrusion_width => |r| width.protrusionWidth(c, r),
        .min_step => |r| width_step.minStep(c, r),
        .min_step_adjacent => |r| width_step.minStepAdjacent(c, r),
        .pattern_match => |r| pattern.patternMatch(c, r),
        // ponytail: families still to port refuse (never pass) until their
        // file lands; the deck compiler refuses these kinds by name.
        .min_spacing,
        .min_spacing_diff,
        .projection_spacing,
        .eol_spacing,
        .prl_spacing,
        .corner_to_corner,
        .wide_dependent_spacing,
        .min_area,
        .min_enclosed_area,
        .cheesing,
        .density,
        .global_density,
        .critical_area,
        .mean_critical_area,
        .density_balance,
        .via_redundancy,
        .dfm_score,
        .cut_area_change,
        .cover_density,
        .min_enclosure,
        .noncoincident_enclosure,
        .full_width,
        .asymmetric_enclosure,
        .max_enclosure,
        .adjacent_enclosure,
        .min_extension,
        .gate_corner,
        .overlap,
        .max_distance_to_tap,
        .off_grid,
        .angle,
        .redundant_via,
        .minimum_cut,
        .via_stack,
        .metal_width_via,
        .stack_spacing,
        .max_cut_spacing,
        .via_array_spacing,
        .cut_spacing,
        .cut_class_spacing,
        .multi_patterning,
        .anchored_patterning,
        .sadp,
        .sadp_line_end,
        .forbidden,
        .must_contain,
        .must_be_inside,
        .net_spacing,
        .spacing_table,
        .attached_wide_spacing,
        .edge_min_length,
        .edge_spacing,
        .edge_enclosure,
        .count,
        .aspect_ratio,
        .total_area,
        .edge_width,
        .edge_facing_space,
        .region_density,
        .min_interior_angle,
        .polygon_validity,
        .tip_spacing_table,
        .forbidden_spacing,
        .eol_within_spacing,
        .eol_keep_out,
        .eol_extension_spacing,
        .origin,
        .keep_out_zone,
        .two_width_spacing_table,
        .span_length,
        .convex_corner_spacing,
        .exact_pitch,
        => report.refused,
    };
}
