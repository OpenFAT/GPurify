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
const grid = @import("grid.zig");
const edge = @import("edge.zig");
const presence = @import("presence.zig");
const overlay_strips = @import("overlay_strips.zig");
const overlay_enclosure = @import("overlay_enclosure.zig");
const overlay_octilinear = @import("overlay_octilinear.zig");
const overlay = @import("overlay.zig");
const dfm = @import("dfm.zig");
const via_cuts = @import("via_cuts.zig");
const via_stack = @import("via_stack.zig");
const via_connectors = @import("via_connectors.zig");
const patterning = @import("patterning.zig");

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
        .min_enclosure => |r| overlay_enclosure.enclosure(c, r.outer, r.inner, r.limit, r.wire, .every_side),
        .noncoincident_enclosure => |r| overlay_enclosure.enclosure(c, r.outer, r.inner, r.limit, .any, .non_coincident),
        .full_width => |r| overlay_enclosure.enclosure(c, r.outer, r.inner, 0, .any, .full_width),
        .asymmetric_enclosure => |r| overlay_enclosure.enclosure(c, r.outer, r.inner, r.limit, r.wire, .opposite),
        .adjacent_enclosure => |r| overlay_enclosure.enclosure(c, r.outer, r.inner, r.limit, .any, .adjacent),
        .max_enclosure => |r| overlay.maxEnclosure(c, r),
        .min_extension => |r| overlay.minExtension(c, r),
        .gate_corner => |r| overlay.gateCorner(c, r),
        .overlap => |r| overlay.overlap(c, r),
        .max_distance_to_tap => |r| overlay.maxDistanceToTap(c, r),
        .metal_width_via => |r| overlay.metalWidthVia(c, r),
        .forbidden => |r| presence.forbidden(c, r),
        .must_contain => |r| presence.mustContain(c, r),
        .must_be_inside => |r| presence.mustBeInside(c, r),
        .dfm_score => |r| dfm.dfmScore(c, r),
        .off_grid => |r| grid.offGrid(c, r),
        .angle => |r| grid.angle(c, r),
        .min_interior_angle => |r| grid.minInteriorAngle(c, r),
        .polygon_validity => |r| grid.polygonValidity(c, r),
        .origin => |r| grid.origin(c, r),
        .edge_min_length => |r| edge.minLength(c, r),
        .edge_spacing => |r| edge.spacing(c, r),
        .edge_enclosure => |r| edge.enclosure(c, r),
        .edge_width => |r| edge.facing(c, r.layer, r.limit, 0, true),
        .edge_facing_space => |r| edge.facing(c, r.layer, r.limit, r.prl, false),
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
        .max_cut_spacing => |r| via_cuts.maxCutSpacing(c, r),
        .redundant_via => |r| via_cuts.redundantVia(c, r),
        .via_array_spacing => |r| via_cuts.viaArraySpacing(c, r),
        .cut_spacing => |r| via_cuts.cutSpacing(c, r),
        .cut_class_spacing => |r| via_cuts.cutClassSpacing(c, r),
        .keep_out_zone => |r| via_cuts.keepOutZone(c, r),
        .minimum_cut => |r| via_stack.minimumCut(c, r),
        .via_stack => |r| via_stack.viaStack(c, r),
        .cut_area_change => |r| via_connectors.cutAreaChange(c, r),
        .via_redundancy => |r| via_connectors.viaRedundancy(c, r),
        .multi_patterning => |r| patterning.multiPatterning(c, r),
        .anchored_patterning => |r| patterning.anchoredPatterning(c, r),
        .sadp => |r| patterning.sadp(c, r),
        .sadp_line_end => |r| patterning.sadpLineEnd(c, r),
    };
}
