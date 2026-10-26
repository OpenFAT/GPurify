//! Width family: min width and notch (facing edge pairs of one merged
//! figure), max width, exact cut size, cut classes, allowed widths and
//! protrusion width. In: one layer of the store. Out: one violation per
//! offending merged figure, on the lowest drawn row under it. Exact on the
//! whole input domain. Ported from crates/check/src/drc/rules/width.rs
//! (`facing`, `max_width`, `cut_size`, `cut_class`, `allowed_width`,
//! `protrusion_width`).
//!
//! Contents:
//! - `pub fn facing(c: *const Ctx, layer: LayerId, limit: Dbu, gap: Gap) Error!Verdict`
//! - `pub fn maxWidth(c: *const Ctx, r: LayerLimit) Error!Verdict`
//! - `pub fn cutSize(c: *const Ctx, r: CutSize) Error!Verdict`
//! - `pub fn cutClass(c: *const Ctx, r: CutClass) Error!Verdict`
//! - `pub fn allowedWidth(c: *const Ctx, r: AllowedWidth) Error!Verdict`
//! - `pub fn protrusionWidth(c: *const Ctx, r: ProtrusionWidth) Error!Verdict`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const ValidatedLayer = geom.ValidatedLayer;
const Polygon = geom.Polygon;
const Gap = geom.width.Gap;
const isqrt = geom.ops.isqrt;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const ran = scratch.ran;

/// Min width (`.width`: Euclidean at concave corners) and notch (`.notch`:
/// facing edges across empty space only). One violation per offending
/// figure of the self-merged layer. `examined` is the drawn polygon count.
/// A layer with 45-degree edges is measured by `narrowestPair2`, one at any
/// other angle by `narrowestPairAny`, each figure named by the lowest drawn
/// row inside it.
pub fn facing(c: *const Ctx, layer: LayerId, limit: Dbu, gap: Gap) Error!Verdict {
    const s = c.s;
    const drawn = try s.p.validated.getAny(c.gpa, c.store, layer) orelse return report.refused;
    const polys: u64 = drawn.len();
    const figures = &s.p.layer_out;
    try geom.derive.mergeInto(c.gpa, drawn, figures);
    if (!drawn.isRectilinear()) {
        try rects.ownersByPointInto(c.gpa, figures, drawn, &s.owners);
        for (s.owners.items, 0..) |owner, idx| {
            const poly = figures.get(@intCast(idx));
            const twice: i128, const at = if (drawn.isOctilinear()) blk: {
                const f = try geom.width.narrowestPair2(c.gpa, poly, gap, limit) orelse continue;
                break :blk .{ f.d2, f.at };
            } else blk: {
                // A fraction's floor compares and floors as the fraction does.
                const f = try geom.width.narrowestPairAny(c.gpa, poly, gap, limit) orelse continue;
                break :blk .{ f.d2.floor, f.at };
            };
            // Floored: twice a square halved, then rooted.
            try c.finding(layer, at, .length(isqrt(@divTrunc(twice, 2))), .length(limit), owner);
        }
        return ran(polys);
    }
    try s.p.rects_a.build(c.gpa, c.store, layer, drawn);
    try rects.ownersOfInto(c.gpa, figures, &s.p.rects_a, &s.owners);
    for (s.owners.items, 0..) |owner, idx| {
        const poly = figures.get(@intCast(idx));
        // A convex shape has no notch, and that is not a violation.
        var best = try geom.width.narrowestFacing(c.gpa, poly, gap, &s.facing);
        // Width is Euclidean: a diagonal neck between concave corners counts.
        if (gap == .width) if (try geom.width.narrowestNeck(c.gpa, poly, limit)) |neck| {
            if (best == null or neck.gap < best.?.gap) best = neck;
        };
        const found = best orelse continue;
        if (found.gap < limit) try c.finding(layer, found.at, .length(found.gap), .length(limit), owner);
    }
    return ran(polys);
}

/// Max width: one violation per region of the merged layer where a
/// `limit + 1` square fits, reported at the region's narrowest facing pair,
/// on the lowest drawn row under it. `examined` counts drawn polygons.
pub fn maxWidth(c: *const Ctx, r: rows.LayerLimit) Error!Verdict {
    const s = c.s;
    const drawn = try s.p.validated.get(c.gpa, c.store, r.layer) orelse return report.refused;
    const polys: u64 = drawn.len();
    var wide: std.ArrayList(Bbox) = .empty;
    defer wide.deinit(c.gpa);
    try scratch.wideRectsInto(c.gpa, drawn, r.limit + 1, &wide);
    if (wide.items.len == 0) return ran(polys);
    try s.p.rects_a.build(c.gpa, c.store, r.layer, drawn);
    var regions: ValidatedLayer = .empty;
    defer regions.deinit(c.gpa);
    try scratch.boxesLayer(c.gpa, wide.items, &regions);
    const figures = &s.p.layer_out;
    try geom.derive.mergeInto(c.gpa, &regions, figures);
    try rects.ownersOfInto(c.gpa, figures, &s.p.rects_a, &s.owners);
    for (s.owners.items, 0..) |owner, idx| {
        // Every validated polygon has a facing pair across its own material.
        const found = (try geom.width.narrowestFacing(c.gpa, figures.get(@intCast(idx)), .width, &s.facing)).?;
        try c.finding(r.layer, found.at, .length(found.gap), .length(r.limit), owner);
    }
    return ran(polys);
}

/// Exact cut size: every merged figure a `width x height` rectangle, either
/// way round. A wrong side reports that side against its target; a
/// non-rectangle with the right box its area against `width * height`.
/// `examined` counts figures.
pub fn cutSize(c: *const Ctx, r: rows.CutSize) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const short = @min(r.width, r.height);
    const long = @max(r.width, r.height);
    const figures = &c.s.p.layer_out;
    for (c.s.owners.items, 0..) |owner, idx| {
        const poly = figures.get(@intCast(idx));
        const b = poly.bbox();
        const bs = @min(b.width(), b.height());
        const bl = @max(b.width(), b.height());
        const measured: report.Measurement, const limit: report.Measurement = if (bs != short)
            .{ .length(bs), .length(short) }
        else if (bl != long)
            .{ .length(bl), .length(long) }
        else if (!isRectangle(poly)) blk: {
            var twice: DbuArea = 0;
            for (0..poly.ringCount()) |k| {
                const ring = poly.ring(@intCast(k));
                twice += geom.ops.area2(ring.xs, ring.ys);
            }
            break :blk .{ .area(@divTrunc(twice, 2)), .area(geom.mulWide(short, long)) };
        } else continue;
        try c.finding(r.layer, rects.centre(b), measured, limit, owner);
    }
    return ran(figures.len());
}

/// Cut classes (sky130 via.1b, LEF58 `CUTCLASS`): every merged figure a
/// rectangle with no hole whose `(short, long)` sides are a class. One
/// violation per figure in none, at its box's centre, measuring the classes
/// it matches (0) against 1. `examined` counts figures.
pub fn cutClass(c: *const Ctx, r: rows.CutClass) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const classes = c.rs.classes.get(r.classes);
    const figures = &c.s.p.layer_out;
    for (c.s.owners.items, 0..) |owner, idx| {
        const poly = figures.get(@intCast(idx));
        const b = poly.bbox();
        const sides: [2]Dbu = .{ @min(b.width(), b.height()), @max(b.width(), b.height()) };
        const known = for (classes) |k| {
            if (k[0] == sides[0] and k[1] == sides[1]) break true;
        } else false;
        if (isRectangle(poly) and known) continue;
        try c.finding(r.layer, rects.centre(b), .count(0), .count(1), owner);
    }
    return ran(figures.len());
}

/// Allowed widths (sky130 rpm.1b, LEF58 `WIDTHTABLE`): each merged figure's
/// narrowest width one of the list, or with `open_last` at least its last,
/// compared squared and so exactly. One violation per figure in none, at the
/// centre of its first rectangle, measuring the width (floored) against the
/// nearest allowed one. `examined` counts figures.
pub fn allowedWidth(c: *const Ctx, r: rows.AllowedWidth) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const s = c.s;
    const allowed = c.rs.widths.get(r.widths);
    const last = allowed[allowed.len - 1];
    const figures = &s.p.layer_out;
    try geom.rects.decomposeInto(c.gpa, figures, &s.rects, &s.rect_start);
    for (s.owners.items, 0..) |owner, idx| {
        const width2 = try geom.width.narrowestWidth2(c.gpa, figures.get(@intCast(idx)), &s.facing);
        const exact = for (allowed) |w| {
            if (geom.mulWide(w, w) == width2) break true;
        } else false;
        if (exact or (r.open_last and width2 >= geom.mulWide(last, last))) continue;
        const width = isqrt(width2);
        var nearest = allowed[0];
        for (allowed) |w| if (@abs(w - width) < @abs(nearest - width)) {
            nearest = w;
        };
        const first = s.rects.items[s.rect_start.items[idx]];
        try c.finding(r.layer, rects.centre(first), .length(width), .length(nearest), owner);
    }
    return ran(figures.len());
}

/// LEF `PROTRUSIONWIDTH width1 LENGTH 0 WIDTH width2` (`limit`, `wide`):
/// each narrow part of a merged figure (no `limit` square covers it)
/// touching the figure's wide part (a `wide` square fits there) is one
/// violation, measuring its narrowest width, at its box's centre, on the
/// lowest drawn row under it. `examined` counts merged figures.
pub fn protrusionWidth(c: *const Ctx, r: rows.ProtrusionWidth) Error!Verdict {
    const s = c.s;
    const gpa = c.gpa;
    const drawn = try s.p.validated.get(gpa, c.store, r.layer) orelse return report.refused;
    const figures = &s.p.layer_out;
    try geom.derive.mergeInto(gpa, drawn, figures);
    try s.p.rects_a.build(gpa, c.store, r.layer, drawn);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var layer: ValidatedLayer = .empty;
    defer layer.deinit(gpa);
    var narrow: ValidatedLayer = .empty;
    defer narrow.deinit(gpa);
    var attached: ValidatedLayer = .empty;
    defer attached.deinit(gpa);
    try scratch.wideRectsInto(gpa, figures, r.limit, &boxes);
    try scratch.boxesLayer(gpa, boxes.items, &layer);
    try geom.boolean.subtractionInto(gpa, figures, &layer, &narrow);
    try scratch.wideRectsInto(gpa, figures, r.wide, &boxes);
    try scratch.boxesLayer(gpa, boxes.items, &layer);
    try geom.derive.interactingInto(gpa, &narrow, &layer, true, &attached);
    try rects.ownersOfInto(gpa, &attached, &s.p.rects_a, &s.owners);
    for (s.owners.items, 0..) |owner, idx| {
        const part = attached.get(@intCast(idx));
        const width = isqrt(try geom.width.narrowestWidth2(gpa, part, &s.facing));
        try c.finding(r.layer, rects.centre(part.bbox()), .length(width), .length(r.limit), owner);
    }
    return ran(figures.len());
}

// ---- private ----

/// An outer ring of four vertices and no hole.
fn isRectangle(poly: Polygon) bool {
    return poly.outer().xs.len == 4 and poly.ringCount() == 1;
}
