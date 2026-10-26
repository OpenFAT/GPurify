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
const spacing = @import("spacing.zig");
const spacing_ends = @import("spacing_ends.zig");
const spacing_net = @import("spacing_net.zig");
const spacing_table = @import("spacing_table.zig");
const facing_edges = @import("facing_edges.zig");
const facing = @import("facing.zig");
const facing_keep_out = @import("facing_keep_out.zig");
const facing_span = @import("facing_span.zig");
const density = @import("density.zig");
const area = @import("area.zig");
const area_density = @import("area_density.zig");
const area_critical = @import("area_critical.zig");

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
        .via_redundancy,
        .dfm_score,
        .cut_area_change,
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
        .edge_min_length,
        .edge_spacing,
        .edge_enclosure,
        .edge_width,
        .edge_facing_space,
        .min_interior_angle,
        .polygon_validity,
        .origin,
        .keep_out_zone,
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
        .min_spacing => |r| spacing.minSpacing(c, r),
        .min_spacing_diff => |r| spacing.minSpacingDiff(c, r),
        .projection_spacing => |r| spacing.projectionSpacing(c, r),
        .eol_spacing => |r| spacing_ends.eolSpacing(c, r),
        .prl_spacing => |r| spacing.prlSpacing(c, r),
        .corner_to_corner => |r| spacing_ends.cornerToCorner(c, r),
        .wide_dependent_spacing => |r| spacing.wideDependent(c, r.layer, r.width_threshold, 0, r.limit),
        .attached_wide_spacing => |r| spacing.wideDependent(c, r.layer, r.width_threshold, r.attached, r.limit),
        .net_spacing => |r| spacing_net.netSpacing(c, r),
        .stack_spacing => |r| spacing_net.stackSpacing(c, r),
        .spacing_table => |r| spacing_table.spacingTable(c, r),
        .two_width_spacing_table => |r| spacing_table.twoWidthTable(c, r),
        .tip_spacing_table => |r| facing.tipSpacingTable(c, r),
        .forbidden_spacing => |r| facing.forbiddenSpacing(c, r),
        .eol_within_spacing => |r| facing.eolWithinSpacing(c, r),
        .eol_keep_out => |r| facing_keep_out.eolKeepOut(c, r),
        .eol_extension_spacing => |r| facing_keep_out.eolExtensionSpacing(c, r),
        .span_length => |r| facing_span.spanLength(c, r),
        .convex_corner_spacing => |r| facing_span.convexCornerSpacing(c, r),
        .exact_pitch => |r| facing_span.exactPitch(c, r),
        .min_area => |r| area.minArea(c, r),
        .min_enclosed_area => |r| area.minEnclosedArea(c, r),
        .cheesing => |r| area.cheesing(c, r),
        .aspect_ratio => |r| area.aspectRatio(c, r),
        .region_density => |r| area.regionDensity(c, r),
        .count => |r| area.count(c, r),
        .total_area => |r| area.totalArea(c, r),
        .global_density => |r| area.globalDensity(c, r),
        .density => |r| area_density.density(c, r),
        .density_balance => |r| area_density.densityBalance(c, r),
        .cover_density => |r| area_density.coverDensity(c, r),
        .critical_area => |r| area_critical.criticalArea(c, r),
        .mean_critical_area => |r| area_critical.meanCriticalArea(c, r),
        // ponytail: families still to port refuse (never pass) until their
        // file lands; the deck compiler refuses these kinds by name.
        .via_redundancy,
        .dfm_score,
        .cut_area_change,
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
        .edge_min_length,
        .edge_spacing,
        .edge_enclosure,
        .edge_width,
        .edge_facing_space,
        .min_interior_angle,
        .polygon_validity,
        .origin,
        .keep_out_zone,
        => report.refused,
    };
}
