//! Short-circuit critical area: where a square defect's centre makes it
//! overlap two different merged figures, for one defect size or the mean
//! over a size distribution. In: one rectilinear layer. Out: at most one
//! violation per rule, at the centre of the critical area's box, naming no
//! shape. Ported from crates/check/src/drc/rules/area.rs (`critical_area`,
//! `mean_critical_area`, `short_area`).
//!
//! Contents:
//! - `pub fn criticalArea(c: *const Ctx, r: CriticalArea) Error!Verdict`
//! - `pub fn meanCriticalArea(c: *const Ctx, r: MeanCriticalArea) Error!Verdict`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const rects = @import("../rects.zig");
const Verdict = report.Verdict;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const area = @import("area.zig");

/// One defect size's measure: the critical area, its box, the figures.
const Short = struct { area: DbuArea, extent: Bbox, figures: u64 };

/// The critical area for a square defect of half-side `radius`: the union
/// over every pair of figures of their intersection, each grown by
/// `radius`. One violation when above `limit`. `examined` counts figures.
pub fn criticalArea(c: *const Ctx, r: rows.CriticalArea) Error!Verdict {
    const s = try shortArea(c, r.layer, r.radius) orelse return report.refused;
    if (s.area > r.limit) try c.finding(r.layer, rects.centre(s.extent), .area(s.area), .area(r.limit), report.no_shape);
    return scratch.ran(s.figures);
}

/// The mean critical area over the deck's defect sizes, `Σ weight · area`,
/// each term as `criticalArea` measures it; one violation when above
/// `limit`, at the centre of every size's box, the mean floored.
/// `examined` counts figures.
pub fn meanCriticalArea(c: *const Ctx, r: rows.MeanCriticalArea) Error!Verdict {
    const sizes = c.rs.defectSizes(r.sizes);
    var mean: f64 = 0;
    var extent = Bbox.empty;
    var examined: u64 = 0;
    for (sizes.radius, sizes.weight) |radius, weight| {
        const s = try shortArea(c, r.layer, radius) orelse return report.refused;
        mean += weight * area.toF64(s.area);
        extent = extent.merge(s.extent);
        examined = s.figures;
    }
    if (mean > area.toF64(r.limit)) try c.finding(r.layer, rects.centre(extent), .area(@intFromFloat(@floor(mean))), .area(r.limit), report.no_shape);
    return scratch.ran(examined);
}

// ---- private ----

/// Null when the layer does not merge or growing leaves the domain.
// ponytail: every pair of figures by their grown boxes, O(figures²); sweep
// by x if a large layer makes this slow.
fn shortArea(c: *const Ctx, layer: LayerId, radius: Dbu) Error!?Short {
    if (!try area.mergeLayer(c, layer, false)) return null;
    const gpa = c.gpa;
    const s = c.s;
    const grown = try gpa.alloc(Bbox, s.rects.items.len);
    defer gpa.free(grown);
    for (grown, s.rects.items) |*g, b| {
        g.* = .{ .xlo = b.xlo - radius, .ylo = b.ylo - radius, .xhi = b.xhi + radius, .yhi = b.yhi + radius };
        if (!geom.inDomain(g.xlo) or !geom.inDomain(g.ylo) or !geom.inDomain(g.xhi) or !geom.inDomain(g.yhi)) return null;
    }
    const starts = s.rect_start.items;
    const n = starts.len -| 1;
    const reach = try gpa.alloc(Bbox, n);
    defer gpa.free(reach);
    for (reach, 0..) |*box, f| {
        box.* = Bbox.empty;
        for (grown[starts[f]..starts[f + 1]]) |b| box.* = box.merge(b);
    }
    var critical: std.ArrayList(Bbox) = .empty;
    defer critical.deinit(gpa);
    for (0..n) |i| for (i + 1..n) |j| {
        if (positive(reach[i].intersection(reach[j])) == null) continue;
        for (grown[starts[i]..starts[i + 1]]) |a| for (grown[starts[j]..starts[j + 1]]) |b| {
            if (positive(a.intersection(b))) |p| try critical.append(gpa, p);
        };
    };
    if (critical.items.len == 0) return .{ .area = 0, .extent = Bbox.empty, .figures = n };
    var pieces: ValidatedLayer = .empty;
    defer pieces.deinit(gpa);
    try scratch.boxesLayer(gpa, critical.items, &pieces);
    try geom.derive.mergeInto(gpa, &pieces, &s.p.layer_out);
    try geom.rects.decomposeInto(gpa, &s.p.layer_out, &s.rects, &s.rect_start);
    var extent = Bbox.empty;
    for (s.rects.items) |b| extent = extent.merge(b);
    return .{ .area = geom.rects.coveredArea(s.rects.items), .extent = extent, .figures = n };
}

fn positive(b: ?Bbox) ?Bbox {
    const box = b orelse return null;
    return if (box.xlo < box.xhi and box.ylo < box.yhi) box else null;
}
