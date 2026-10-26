//! Area family: min area, min enclosed (hole) area, cheesing, aspect ratio,
//! region density, count, total area and whole-die density. In: one layer,
//! self-merged into figures and decomposed into disjoint rectangles. Out:
//! one violation per offending figure, hole, region or die. Ported from
//! crates/check/src/drc/rules/area.rs (`merge_layer`, `figure_owners`,
//! `report_figures`, `min_area`, `cheesing`, `min_enclosed_area`, `die_of`,
//! `merge_within`, `global_density`, `count`, `total_area`,
//! `region_density`, `aspect_ratio`); the windowed densities are in
//! `area_density.zig`, the critical areas in `area_critical.zig`.
//!
//! Contents:
//! - `pub fn mergeLayer(c: *const Ctx, layer: LayerId, any: bool) Error!bool`
//! - `pub fn figureOwners(c: *const Ctx, layer: LayerId) Error!void`
//! - `pub fn dieOf(store: *const GeometryStore, boundary: ?LayerId, drawn: u32) Bbox`
//! - `pub fn mergeWithin(c: *const Ctx, layer: LayerId, die: Bbox) Error!bool`
//! - `pub fn minArea(c: *const Ctx, r: LayerArea) Error!Verdict`, `cheesing`, `minEnclosedArea`,
//!   `aspectRatio`, `regionDensity`, `count`, `totalArea`, `globalDensity`
//! - `pub fn toF64(v: i128) f64`

const std = @import("std");
const geom = @import("geom");
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

/// What `reportFigures` asks of one figure.
const Judge = enum { min_area, cheesing };

/// The layer merged into `s.p.layer_out` and, when rectilinear, decomposed
/// into `s.rects` CSR by figure (else `s.rect_start` empty). With `any`, a
/// layer with edges at any angle is taken. False is refused.
pub fn mergeLayer(c: *const Ctx, layer: LayerId, any: bool) Error!bool {
    const s = c.s;
    const drawn = (if (any) try s.p.validated.getAny(c.gpa, c.store, layer) else try s.p.validated.get(c.gpa, c.store, layer)) orelse return false;
    try geom.derive.mergeInto(c.gpa, drawn, &s.p.layer_out);
    if (drawn.isRectilinear()) {
        try geom.rects.decomposeInto(c.gpa, &s.p.layer_out, &s.rects, &s.rect_start);
    } else {
        s.rects.clearRetainingCapacity();
        s.rect_start.clearRetainingCapacity();
    }
    return true;
}

/// The lowest drawn row under each figure `mergeLayer` filled, into
/// `s.owners`: an outer row whose polygon covers part of the figure.
pub fn figureOwners(c: *const Ctx, layer: LayerId) Error!void {
    const s = c.s;
    const drawn = (try s.p.validated.getAny(c.gpa, c.store, layer)).?;
    if (!drawn.isRectilinear()) return rects.ownersByPointInto(c.gpa, &s.p.layer_out, drawn, &s.owners);
    try s.p.rects_a.build(c.gpa, c.store, layer, drawn);
    try rects.ownersOfInto(c.gpa, &s.p.layer_out, &s.p.rects_a, &s.owners);
}

/// The die: the `boundary` layer's extent, or the drawn layers'
/// `0..drawn` (a derived layer is not layout).
pub fn dieOf(store: *const GeometryStore, boundary: ?LayerId, drawn: u32) Bbox {
    var die = Bbox.empty;
    if (boundary) |b| {
        for (store.layerBboxes(b)) |box| die = die.merge(box);
        return die;
    }
    for (0..drawn) |l| for (store.layerBboxes(@fromBackingInt(@as(u16, @intCast(l))))) |box| {
        die = die.merge(box);
    };
    return die;
}

/// The merged layer's rectangles clipped to the die, into `s.rects`. False
/// is refused.
pub fn mergeWithin(c: *const Ctx, layer: LayerId, die: Bbox) Error!bool {
    if (!try mergeLayer(c, layer, false)) return false;
    var kept: usize = 0;
    for (c.s.rects.items) |r| {
        const clip = r.intersection(die) orelse continue;
        if (!(clip.xlo < clip.xhi and clip.ylo < clip.yhi)) continue;
        c.s.rects.items[kept] = clip;
        kept += 1;
    }
    c.s.rects.shrinkRetainingCapacity(kept);
    return true;
}

/// Minimum area of each merged figure, edges at any angle included (an
/// area a half unit short is short). `examined` counts figures.
pub fn minArea(c: *const Ctx, r: rows.LayerArea) Error!Verdict {
    if (!try mergeLayer(c, r.layer, true)) return report.refused;
    return scratch.ran(try reportFigures(c, r.layer, r.limit, .min_area));
}

/// Cheesing: a figure above `limit` with no hole. `examined` counts figures.
pub fn cheesing(c: *const Ctx, r: rows.Cheesing) Error!Verdict {
    if (!try mergeLayer(c, r.layer, false)) return report.refused;
    return scratch.ran(try reportFigures(c, r.layer, r.max_unslotted, .cheesing));
}

/// Minimum hole area of the merged figures, at the hole's box centre (a
/// hole's area floored). `examined` counts holes.
pub fn minEnclosedArea(c: *const Ctx, r: rows.LayerArea) Error!Verdict {
    if (!try mergeLayer(c, r.layer, true)) return report.refused;
    try figureOwners(c, r.layer);
    var examined: u64 = 0;
    for (c.s.owners.items, 0..) |owner, idx| {
        const poly = c.s.p.layer_out.get(@intCast(idx));
        for (1..poly.ringCount()) |k| {
            examined += 1;
            const hole = poly.ring(@intCast(k));
            // A hole winds clockwise; its area floored, a half unit dropped.
            const area = @divTrunc(-geom.ops.area2(hole.xs, hole.ys), 2);
            if (!Measurement.area(area).violates(.area(r.limit), .minimum)) continue;
            try c.finding(r.layer, geom.ops.centre(Bbox.ofPoints(hole.xs, hole.ys)), .area(area), .area(r.limit), owner);
        }
    }
    return scratch.ran(examined);
}

/// Each merged figure's bounding-box aspect ratio, longer side over
/// shorter (sky130 capm.6), against a maximum, at the centre of its first
/// rectangle. `examined` counts figures.
pub fn aspectRatio(c: *const Ctx, r: rows.AspectRatio) Error!Verdict {
    if (!try mergeLayer(c, r.layer, false)) return report.refused;
    try figureOwners(c, r.layer);
    const s = c.s;
    for (s.owners.items, 0..) |owner, idx| {
        const b = s.p.layer_out.get(@intCast(idx)).bbox();
        const ratio = toF64(@max(b.width(), b.height())) / toF64(@min(b.width(), b.height()));
        if (!Measurement.ratio(ratio).violates(.ratio(r.limit), .maximum)) continue;
        try c.finding(r.layer, geom.ops.centre(s.rects.items[s.rect_start.items[idx]]), .ratio(ratio), .ratio(r.limit), owner);
    }
    return scratch.ran(s.p.layer_out.len());
}

/// Per merged figure of `region`, the area of the merged layer inside it
/// over its own area (sky130 vpp.5a), against a minimum or a maximum; one
/// violation per region figure, on `region`, at its first rectangle's
/// centre. `examined` counts region figures.
pub fn regionDensity(c: *const Ctx, r: rows.RegionDensity) Error!Verdict {
    const gpa = c.gpa;
    const s = c.s;
    if (!try mergeLayer(c, r.region, false)) return report.refused;
    try figureOwners(c, r.region);
    const owners = try gpa.dupe(PolyId, s.owners.items);
    defer gpa.free(owners);
    const regions = try gpa.dupe(Bbox, s.rects.items);
    defer gpa.free(regions);
    const starts = try gpa.dupe(u32, s.rect_start.items);
    defer gpa.free(starts);
    if (!try mergeLayer(c, r.layer, false)) return report.refused;
    const zeros = try gpa.alloc(u32, s.rects.items.len);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    var material: rects.SortedRects = .{};
    defer material.deinit(gpa);
    try material.build(gpa, s.rects.items, zeros);
    for (owners, 0..) |owner, figure| {
        const mine = regions[starts[figure]..starts[figure + 1]];
        var covered: DbuArea = 0;
        for (mine) |box| {
            var hits = material.overlapping(box);
            while (hits.next()) |h| covered += h.clip.area();
        }
        const fraction = toF64(covered) / toF64(geom.rects.coveredArea(mine));
        if (!Measurement.ratio(fraction).violates(.ratio(r.limit), r.sense)) continue;
        try c.finding(r.region, geom.ops.centre(mine[0]), .ratio(fraction), .ratio(r.limit), owner);
    }
    return scratch.ran(owners.len);
}

/// The number of merged figures on the layer against a minimum or a maximum
/// (IHP npn13G2.bR), one violation at the die's centre. `examined` counts
/// figures, and is one when there are none; nothing drawn is skipped.
pub fn count(c: *const Ctx, r: rows.Count) Error!Verdict {
    const die = dieOf(c.store, null, c.drawn);
    if (die.isEmpty()) return .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };
    if (!try mergeLayer(c, r.layer, false)) return report.refused;
    const figures = c.s.p.layer_out.len();
    if (Measurement.count(figures).violates(.count(r.limit), r.sense)) try c.finding(r.layer, geom.ops.centre(die), .count(figures), .count(r.limit), firstRowOrNone(c.store, r.layer));
    return scratch.ran(@max(figures, 1));
}

/// The area the merged layer covers, holes excluded, against a maximum (IHP
/// MIM.gR), one violation at the die's centre. `examined` counts figures;
/// nothing drawn is skipped.
pub fn totalArea(c: *const Ctx, r: rows.LayerArea) Error!Verdict {
    const die = dieOf(c.store, null, c.drawn);
    if (die.isEmpty()) return .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };
    if (!try mergeLayer(c, r.layer, false)) return report.refused;
    const area = geom.rects.coveredArea(c.s.rects.items);
    if (Measurement.area(area).violates(.area(r.limit), .maximum)) try c.finding(r.layer, geom.ops.centre(die), .area(area), .area(r.limit), firstRowOrNone(c.store, r.layer));
    return scratch.ran(c.s.p.layer_out.len());
}

/// Whole-die density (gf180 M1.4, IHP M1.j/k): the merged layer's area
/// inside the die over the die's, one violation at the die's centre.
/// `examined` is one; an empty die is skipped.
pub fn globalDensity(c: *const Ctx, r: rows.GlobalDensity) Error!Verdict {
    const die = dieOf(c.store, r.boundary, c.drawn);
    if (die.isEmpty()) return .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };
    if (!try mergeWithin(c, r.layer, die)) return report.refused;
    const fraction = toF64(geom.rects.coveredArea(c.s.rects.items)) / toF64(die.area());
    if (Measurement.ratio(fraction).violates(.ratio(r.limit), r.sense)) try c.finding(r.layer, geom.ops.centre(die), .ratio(fraction), .ratio(r.limit), firstRowOrNone(c.store, r.layer));
    return scratch.ran(1);
}

pub fn toF64(v: i128) f64 {
    return @floatFromInt(v);
}

// ---- private ----

/// One violation per merged figure `judge` rejects, at its first
/// rectangle's centre; on a layer with slanted edges the area floored at a
/// point of the figure's material. Returns the figure count.
fn reportFigures(c: *const Ctx, layer: LayerId, limit: DbuArea, judge: Judge) Error!u64 {
    try figureOwners(c, layer);
    const s = c.s;
    for (s.owners.items, 0..) |owner, figure| {
        const poly = s.p.layer_out.get(@intCast(figure));
        var area: DbuArea = undefined;
        var at: geom.Point = undefined;
        if (s.rect_start.items.len == 0) {
            var twice: i128 = 0;
            for (0..poly.ringCount()) |k| {
                const ring = poly.ring(@intCast(k));
                twice += geom.ops.area2(ring.xs, ring.ys);
            }
            area = @divFloor(twice, 2);
            at = rects.figurePoint(poly);
        } else {
            const mine = s.rects.items[s.rect_start.items[figure]..s.rect_start.items[figure + 1]];
            area = geom.rects.coveredArea(mine);
            at = geom.ops.centre(mine[0]);
        }
        const violates = switch (judge) {
            .min_area => Measurement.area(area).violates(.area(limit), .minimum),
            .cheesing => Measurement.area(area).violates(.area(limit), .maximum) and poly.ringCount() == 1,
        };
        if (violates) try c.finding(layer, at, .area(area), .area(limit), owner);
    }
    return s.p.layer_out.len();
}

/// The layer's first row, or no shape for an empty layer.
fn firstRowOrNone(store: *const GeometryStore, layer: LayerId) PolyId {
    const r = store.polysOnLayer(layer);
    return if (r.len() == 0) report.no_shape else @fromBackingInt(r.start);
}
