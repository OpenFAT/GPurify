//! Rectilinear decomposition into disjoint rectangles, so areas sum exactly.
//! In: a rectilinear `ValidatedLayer`. Out: rectangles in canonical vertical
//! slabs, CSR by polygon, and their (clipped) areas. Ported from
//! crates/geom/src/rects.rs.
//!
//! Contents:
//! - `pub fn decomposeInto(gpa: Allocator, layer: *const ValidatedLayer, rects: *std.ArrayList(Bbox), poly_start: *std.ArrayList(u32)) Allocator.Error!void`
//! - `pub fn coveredArea(rects: []const Bbox) DbuArea`
//! - `pub fn clippedArea(rects: []const Bbox, window: Bbox) DbuArea`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const DbuArea = dbu.DbuArea;
const Bbox = @import("bbox.zig").Bbox;
const ops = @import("ops.zig");
const ValidatedLayer = @import("view.zig").ValidatedLayer;

/// One edge as `(lo, hi, y)`. A vertical edge has `lo == hi`, so it never
/// survives into a slab and its `y` is never read.
const Span = struct {
    lo: Dbu,
    hi: Dbu,
    y: Dbu,

    fn lessThan(_: void, a: Span, b: Span) bool {
        if (a.lo != b.lo) return a.lo < b.lo;
        if (a.hi != b.hi) return a.hi < b.hi;
        return a.y < b.y;
    }
};

/// Every polygon cut into disjoint rectangles by vertical slabs at its
/// vertex x-coordinates (canonical): polygon `i` owns
/// `rects[poly_start[i]..poly_start[i + 1]]`, each slab's rectangles
/// ascending in y. Both outputs are cleared and refilled. Asserts the layer
/// is rectilinear: a 45-degree edge has no such decomposition, and a wrong
/// one would be a silent wrong area.
pub fn decomposeInto(gpa: Allocator, layer: *const ValidatedLayer, rects: *std.ArrayList(Bbox), poly_start: *std.ArrayList(u32)) Allocator.Error!void {
    assert(layer.isRectilinear());
    rects.clearRetainingCapacity();
    poly_start.clearRetainingCapacity();
    try poly_start.append(gpa, 0);

    var edges: std.ArrayList(Span) = .empty;
    defer edges.deinit(gpa);
    var slabs: std.ArrayList(Dbu) = .empty;
    defer slabs.deinit(gpa);
    var active: std.ArrayList(Span) = .empty;
    defer active.deinit(gpa);
    var cuts: std.ArrayList(Dbu) = .empty;
    defer cuts.deinit(gpa);

    for (0..layer.len()) |idx| {
        const poly = layer.get(@intCast(idx));
        edges.clearRetainingCapacity();
        slabs.clearRetainingCapacity();
        for (0..poly.ringCount()) |k| {
            const r = poly.ring(@intCast(k));
            try slabs.appendSlice(gpa, r.xs);
            for (0..r.xs.len) |i| {
                const e = ops.ringEdge(r.xs, r.ys, i);
                try edges.append(gpa, .{ .lo = @min(e.a.x, e.b.x), .hi = @max(e.a.x, e.b.x), .y = e.a.y });
            }
        }
        std.mem.sortUnstable(Dbu, slabs.items, {}, std.sort.asc(Dbu));
        const xs = slabs.items[0..dedup(slabs.items)];
        std.mem.sortUnstable(Span, edges.items, {}, Span.lessThan);

        // Both slab bounds ascend, so an edge enters `active` once and
        // leaves once.
        active.clearRetainingCapacity();
        var started: usize = 0;
        for (xs[0 .. xs.len - 1], xs[1..]) |x0, x1| {
            while (started < edges.items.len and edges.items[started].lo <= x0) : (started += 1) {
                try active.append(gpa, edges.items[started]);
            }
            // Survivors are exactly the edges with `lo <= x0 and hi >= x1`.
            var kept: usize = 0;
            for (active.items) |e| {
                if (e.hi < x1) continue;
                active.items[kept] = e;
                kept += 1;
            }
            active.shrinkRetainingCapacity(kept);

            cuts.clearRetainingCapacity();
            for (active.items) |e| try cuts.append(gpa, e.y);
            std.mem.sortUnstable(Dbu, cuts.items, {}, std.sort.asc(Dbu));
            // A slab crosses a closed polygon's boundary an even number of
            // times; even-odd fill takes the runs between crossings 1-2, 3-4...
            assert(cuts.items.len % 2 == 0);
            var i: usize = 0;
            while (i < cuts.items.len) : (i += 2) {
                try rects.append(gpa, .{ .xlo = x0, .ylo = cuts.items[i], .xhi = x1, .yhi = cuts.items[i + 1] });
            }
        }
        assert(rects.items.len <= std.math.maxInt(u32));
        try poly_start.append(gpa, @intCast(rects.items.len));
    }
}

/// Total area of disjoint rectangles.
pub fn coveredArea(rects: []const Bbox) DbuArea {
    var total: DbuArea = 0;
    for (rects) |r| total += r.area();
    return total;
}

/// The area of rectangles clipped to a window, per axis
/// `max(0, min(hi) - max(lo))`.
pub fn clippedArea(rects: []const Bbox, window: Bbox) DbuArea {
    var total: DbuArea = 0;
    for (rects) |r| {
        const w = @max(@min(r.xhi, window.xhi) - @max(r.xlo, window.xlo), 0);
        const h = @max(@min(r.yhi, window.yhi) - @max(r.ylo, window.ylo), 0);
        total += dbu.mulWide(w, h);
    }
    return total;
}

// ---- private ----

/// Drops consecutive repeats of a sorted slice in place; returns the length.
fn dedup(items: []Dbu) usize {
    var kept: usize = 0;
    for (items) |v| {
        if (kept > 0 and items[kept - 1] == v) continue;
        items[kept] = v;
        kept += 1;
    }
    return kept;
}
