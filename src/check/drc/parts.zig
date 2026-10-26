//! Wide parts and where a part-measured pair is marked: each polygon's
//! rectangles of its figure's wide region (grown by an attached distance),
//! the distance from such parts to another ring, and the marker of the
//! nearest approach between them. In: a layer's `LayerRects`, its component
//! labels and the wide rectangles. Out: CSR parts per polygon, squared
//! distances, report points. Ported from crates/check/src/drc/rules/
//! {spacing.rs (`wide_parts`, `marker`, `wide_at`, `rect_ring_pairs`,
//! `rect_sides`), mod.rs (`rects_ring_dist2`)}.
//!
//! Contents:
//! - `pub const Parts = struct`, `Parts.deinit`, `Parts.of(p, poly: u32) []const Bbox`
//! - `pub fn widePartsInto(gpa: Allocator, polys: *const LayerRects, labels: []const u32, first_row: u32, wide: []const Bbox, attached: Dbu, out: *Parts) Allocator.Error!void`
//! - `pub fn rectSides(r: Bbox) [4]Seg`
//! - `pub fn rectsRingDist2(boxes: []const Bbox, ring: Ring) DbuArea`
//! - `pub fn marker(store: *const GeometryStore, a: PolyId, b: PolyId, d2: DbuArea, found: ?Found) Point`
//! - `pub fn addRectRing(n: *Nearest, gpa: Allocator, boxes: []const Bbox, ring: Ring) Allocator.Error!void`
//! - `pub fn wideAt(gpa: Allocator, store: *const GeometryStore, a: PolyId, b: PolyId, wide_a: []const Bbox, wide_b: []const Bbox, d2: DbuArea) Allocator.Error!Point`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const Ring = geom.Ring;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const rects = @import("../rects.zig");
const LayerRects = rects.LayerRects;
const SortedRects = rects.SortedRects;
const proximity = @import("../proximity.zig");
const Nearest = proximity.Nearest;
const Found = proximity.Found;

/// Each polygon's wide rectangles, CSR by polygon.
pub const Parts = struct {
    rects: std.ArrayList(Bbox) = .empty,
    start: std.ArrayList(u32) = .empty,

    pub fn deinit(p: *Parts, gpa: Allocator) void {
        p.rects.deinit(gpa);
        p.start.deinit(gpa);
    }

    pub fn of(p: *const Parts, poly: u32) []const Bbox {
        return p.rects.items[p.start.items[poly]..p.start.items[poly + 1]];
    }
};

/// Every `wide` rectangle of each polygon's own figure (component `labels`,
/// by row offset from `first_row`), grown by `attached`, clipped to the
/// polygon rectangle by rectangle, into `out`.
pub fn widePartsInto(gpa: Allocator, polys: *const LayerRects, labels: []const u32, first_row: u32, wide: []const Bbox, attached: Dbu, out: *Parts) Allocator.Error!void {
    var row_labels: std.ArrayList(u32) = .empty;
    defer row_labels.deinit(gpa);
    try polys.rowLabelsInto(gpa, &row_labels);
    var drawn: SortedRects = .{};
    defer drawn.deinit(gpa);
    try drawn.build(gpa, polys.rects.items, row_labels.items);
    // A wide rectangle lies in one figure: the one of any drawn rectangle it overlaps.
    var grown_rects: std.ArrayList(Bbox) = .empty;
    defer grown_rects.deinit(gpa);
    var grown_labels: std.ArrayList(u32) = .empty;
    defer grown_labels.deinit(gpa);
    for (wide) |r| {
        var hits = drawn.overlapping(r);
        const hit = hits.next() orelse continue;
        try grown_rects.append(gpa, .{ .xlo = clamped(r.xlo - attached), .ylo = clamped(r.ylo - attached), .xhi = clamped(r.xhi + attached), .yhi = clamped(r.yhi + attached) });
        try grown_labels.append(gpa, labels[hit.label - first_row]);
    }
    var grown: SortedRects = .{};
    defer grown.deinit(gpa);
    try grown.build(gpa, grown_rects.items, grown_labels.items);
    out.rects.clearRetainingCapacity();
    out.start.clearRetainingCapacity();
    try out.start.append(gpa, 0);
    for (0..polys.len()) |poly| {
        const mine = labels[@backingInt(polys.row.items[poly]) - first_row];
        for (polys.of(@intCast(poly))) |r| {
            var hits = grown.overlapping(r);
            while (hits.next()) |h| if (h.label == mine) try out.rects.append(gpa, h.clip);
        }
        try out.start.append(gpa, @intCast(out.rects.items.len));
    }
}

/// A rectangle's four sides, counter-clockwise from its lower-left corner.
pub fn rectSides(r: Bbox) [4]Seg {
    const c = [4]Point{ .{ .x = r.xlo, .y = r.ylo }, .{ .x = r.xhi, .y = r.ylo }, .{ .x = r.xhi, .y = r.yhi }, .{ .x = r.xlo, .y = r.yhi } };
    return .{ .{ .a = c[0], .b = c[1] }, .{ .a = c[1], .b = c[2] }, .{ .a = c[2], .b = c[3] }, .{ .a = c[3], .b = c[0] } };
}

/// Squared distance from a set of rectangles' sides to one ring's edges;
/// the largest `DbuArea` for no rectangles.
pub fn rectsRingDist2(boxes: []const Bbox, ring: Ring) DbuArea {
    var best: DbuArea = std.math.maxInt(DbuArea);
    for (0..ring.xs.len) |i| {
        const e = geom.ops.ringEdge(ring.xs, ring.ys, i);
        for (boxes) |r| for (rectSides(r)) |side| {
            best = @min(best, geom.ops.segSegDist2(side, e));
        };
    }
    return best;
}

/// Where a pair measured `d2` apart is reported: `found`'s point when it
/// measures `d2`; else (a pair nested one in the other) the middle of the
/// overlap of the two rows' boxes.
pub fn marker(store: *const GeometryStore, a: PolyId, b: PolyId, d2: DbuArea, found: ?Found) Point {
    if (found) |f| if (f.d2 == d2) return f.at;
    return rects.gapMidpoint(store.polyBbox(a), store.polyBbox(b));
}

/// Every side of each of `boxes` paired with every edge of `ring`, into `n`.
pub fn addRectRing(n: *Nearest, gpa: Allocator, boxes: []const Bbox, ring: Ring) Allocator.Error!void {
    for (boxes) |r| for (rectSides(r)) |side| for (0..ring.xs.len) |i| {
        try n.add(gpa, side, geom.ops.ringEdge(ring.xs, ring.ys, i));
    };
}

/// `marker` for a pair measured from the wide parts of either shape to the
/// other's ring.
pub fn wideAt(gpa: Allocator, store: *const GeometryStore, a: PolyId, b: PolyId, wide_a: []const Bbox, wide_b: []const Bbox, d2: DbuArea) Allocator.Error!Point {
    var n: Nearest = .{};
    defer n.deinit(gpa);
    try addRectRing(&n, gpa, wide_a, store.polyVerts(b));
    try addRectRing(&n, gpa, wide_b, store.polyVerts(a));
    return marker(store, a, b, d2, n.result());
}

// ---- private ----

fn clamped(v: i64) Dbu {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
