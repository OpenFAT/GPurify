//! A net's conductors: on each layer, the union of the net's drawn polygons,
//! one region per piece that current can cross, each cut into disjoint
//! rectangles. Ported from crates/extract/src/conductor.rs.
//!
//! In: one net's polygon rows. Out: `Regions`, ascending by layer. The closed
//! forms and the inductance filaments read regions, not drawn polygons, so a
//! wire is the same conductor however it was drawn: pieces that abut share no
//! edge, and pieces that overlap count the overlap once (testing-plan F44,
//! F45). A region is edge-connected: the merge joins two pieces that meet
//! only at a corner into one polygon (the corner model of
//! `geom.boolean.unionInto`), but a corner is a neck of zero width that
//! carries no current, so the merged polygon is split there into its pieces
//! that share an edge of positive length (testing-plan F76).
//!
//! Contents:
//! - `pub const Regions = struct`, `Regions.empty`, `deinit`, `len(r: *const Regions) u32`,
//!   `rectsOf(r: *const Regions, region: u32) []const Bbox`,
//!   `pushNet(r: *Regions, gpa: Allocator, store: *const GeometryStore, polys: []const PolyId, net: u32, keep_layer: []const bool) Allocator.Error!?LayerId`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;

/// Regions as columns, in the order they were pushed. Region `r` owns
/// `rects[rect_start[r]..rect_start[r + 1]]`: vertical slabs ascending in x,
/// each slab's rectangles ascending in y, as `geom.rects.decomposeInto`
/// cuts them.
pub const Regions = struct {
    net: std.ArrayList(u32) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
    area: std.ArrayList(DbuArea) = .empty,
    /// Holes included; a corner the region touches another at adds nothing.
    perimeter: std.ArrayList(Dbu) = .empty,
    rect_start: std.ArrayList(u32) = .empty,
    rects: std.ArrayList(Bbox) = .empty,
    /// Reused by every `pushNet`; its contents mean nothing between calls.
    scratch: Scratch = .{},

    pub const empty: Regions = .{};

    pub fn deinit(r: *Regions, gpa: Allocator) void {
        r.net.deinit(gpa);
        r.layer.deinit(gpa);
        r.area.deinit(gpa);
        r.perimeter.deinit(gpa);
        r.rect_start.deinit(gpa);
        r.rects.deinit(gpa);
        r.scratch.deinit(gpa);
    }

    pub fn len(r: *const Regions) u32 {
        return @intCast(r.net.items.len);
    }

    pub fn rectsOf(r: *const Regions, region: u32) []const Bbox {
        return r.rects.items[r.rect_start.items[region]..r.rect_start.items[region + 1]];
    }

    /// Appends the regions of `polys` (one net's rows, ascending, so grouped
    /// by layer) on every layer `keep_layer` marks, ascending by layer, each
    /// layer's in the order the merge gives them; a merged polygon split at a
    /// corner gives its pieces in the order of their first rectangles, each
    /// keeping its rectangles' order. Returns null, or the layer whose shapes
    /// do not validate as simple rectilinear rings, so cannot be merged
    /// exactly; regions pushed before it stay. A layer past `keep_layer` is
    /// not kept.
    pub fn pushNet(r: *Regions, gpa: Allocator, store: *const GeometryStore, polys: []const PolyId, net: u32, keep_layer: []const bool) Allocator.Error!?LayerId {
        if (r.rect_start.items.len == 0) try r.rect_start.append(gpa, 0);
        const s = &r.scratch;
        var at: usize = 0;
        while (at < polys.len) {
            const layer = store.polyLayer(polys[at]);
            var end = at + 1;
            while (end < polys.len and store.polyLayer(polys[end]) == layer) end += 1;
            defer at = end;
            const l = @backingInt(layer);
            if (l >= keep_layer.len or !keep_layer[l]) continue;

            s.builder.deinit(gpa);
            s.builder = .empty;
            for (polys[at..end]) |poly| {
                const ring = store.polyVerts(poly);
                _ = try s.builder.push(gpa, @fromBackingInt(0), ring.xs, ring.ys);
            }
            try s.builder.finish(gpa, 1, &s.store, &s.permutation);
            if (try geom.view.validateLayer(gpa, &s.store, @fromBackingInt(0), .rectilinear, &s.drawn) != null) return layer;
            // One polygon (holes bound to it) is already its own union.
            const shape = if (s.drawn.len() > 1) blk: {
                try geom.derive.mergeInto(gpa, &s.drawn, &s.merged);
                break :blk &s.merged;
            } else &s.drawn;
            try geom.rects.decomposeInto(gpa, shape, &s.cut, &s.cut_start);
            for (0..shape.len()) |polygon| {
                const rects = s.cut.items[s.cut_start.items[polygon]..s.cut_start.items[polygon + 1]];
                try s.piece.split(gpa, rects);
                for (s.piece.shared.items, 0..) |shared, piece| {
                    var perimeter: Dbu = -2 * shared;
                    const first = r.rects.items.len;
                    for (rects, s.piece.label.items) |rect, of| {
                        if (of != piece) continue;
                        perimeter += 2 * (rect.width() + rect.height());
                        try r.rects.append(gpa, rect);
                    }
                    try r.net.append(gpa, net);
                    try r.layer.append(gpa, layer);
                    try r.area.append(gpa, geom.rects.coveredArea(r.rects.items[first..]));
                    try r.perimeter.append(gpa, perimeter);
                    assert(r.rects.items.len <= std.math.maxInt(u32));
                    try r.rect_start.append(gpa, @intCast(r.rects.items.len));
                }
            }
        }
        return null;
    }
};

const Scratch = struct {
    builder: geom.GeometryStoreBuilder = .empty,
    store: GeometryStore = .empty,
    permutation: std.ArrayList(u32) = .empty,
    drawn: ValidatedLayer = .empty,
    merged: ValidatedLayer = .empty,
    cut: std.ArrayList(Bbox) = .empty,
    cut_start: std.ArrayList(u32) = .empty,
    piece: Pieces = .{},

    fn deinit(s: *Scratch, gpa: Allocator) void {
        s.builder.deinit(gpa);
        s.store.deinit(gpa);
        s.permutation.deinit(gpa);
        s.drawn.deinit(gpa);
        s.merged.deinit(gpa);
        s.cut.deinit(gpa);
        s.cut_start.deinit(gpa);
        s.piece.deinit(gpa);
    }
};

/// One merged polygon's rectangles split into the pieces that share an edge
/// of positive length: the polygon less the corners it touches itself at.
const Pieces = struct {
    /// The piece of each rectangle, numbered in order of first rectangle.
    label: std.ArrayList(u32) = .empty,
    /// Per piece, the length of the edges its rectangles share, which its
    /// perimeter does not count.
    shared: std.ArrayList(Dbu) = .empty,
    /// Union-find parents, by rectangle.
    parent: std.ArrayList(u32) = .empty,
    /// The first rectangle and length of every shared edge.
    edge_rect: std.ArrayList(u32) = .empty,
    edge_len: std.ArrayList(Dbu) = .empty,
    piece_of_root: std.ArrayList(u32) = .empty,

    fn deinit(p: *Pieces, gpa: Allocator) void {
        inline for (@typeInfo(Pieces).@"struct".field_names) |name| @field(p, name).deinit(gpa);
    }

    /// Splits `rects`, cut as `decomposeInto` cuts one polygon: vertical
    /// slabs ascending in x, each slab's rectangles ascending in y and
    /// disjoint. So two rectangles share an edge only stacked in one slab or
    /// side by side in two slabs that abut, and a sweep finds every such pair.
    fn split(p: *Pieces, gpa: Allocator, rects: []const Bbox) Allocator.Error!void {
        assert(rects.len < std.math.maxInt(u32));
        try p.parent.resize(gpa, rects.len);
        for (p.parent.items, 0..) |*parent, k| parent.* = @intCast(k);
        p.edge_rect.clearRetainingCapacity();
        p.edge_len.clearRetainingCapacity();
        var slab: usize = 0;
        while (slab < rects.len) {
            const end = slabEnd(rects, slab);
            for (slab + 1..end) |k| {
                if (rects[k - 1].yhi == rects[k].ylo) try p.join(gpa, k - 1, k, rects[k].width());
            }
            // The next slab, if it abuts this one: walk both columns up.
            const next = slabEnd(rects, end);
            if (next > end and rects[end].xlo == rects[slab].xhi) {
                var i = slab;
                var j = end;
                while (i < end and j < next) {
                    const overlap = @min(rects[i].yhi, rects[j].yhi) - @max(rects[i].ylo, rects[j].ylo);
                    if (overlap > 0) try p.join(gpa, i, j, overlap);
                    if (rects[i].yhi <= rects[j].yhi) i += 1 else j += 1;
                }
            }
            slab = end;
        }
        p.label.clearRetainingCapacity();
        p.shared.clearRetainingCapacity();
        try p.piece_of_root.resize(gpa, rects.len);
        @memset(p.piece_of_root.items, std.math.maxInt(u32));
        for (0..rects.len) |k| {
            const top = p.root(k);
            if (p.piece_of_root.items[top] == std.math.maxInt(u32)) {
                p.piece_of_root.items[top] = @intCast(p.shared.items.len);
                try p.shared.append(gpa, 0);
            }
            try p.label.append(gpa, p.piece_of_root.items[top]);
        }
        for (p.edge_rect.items, p.edge_len.items) |k, length| p.shared.items[p.label.items[k]] += length;
    }

    fn root(p: *Pieces, start: usize) u32 {
        var k = start;
        while (p.parent.items[k] != k) {
            const up = p.parent.items[k];
            p.parent.items[k] = p.parent.items[up];
            k = up;
        }
        return @intCast(k);
    }

    fn join(p: *Pieces, gpa: Allocator, a: usize, b: usize, length: Dbu) Allocator.Error!void {
        const ra = p.root(a);
        const rb = p.root(b);
        p.parent.items[@max(ra, rb)] = @min(ra, rb);
        try p.edge_rect.append(gpa, @intCast(a));
        try p.edge_len.append(gpa, length);
    }
};

// ---- private ----

/// The end of the slab (same `xlo`, `xhi`) starting at `from`; `from` itself
/// at the end of `rects`.
fn slabEnd(rects: []const Bbox, from: usize) usize {
    var end = from;
    while (end < rects.len and rects[end].xlo == rects[from].xlo and rects[end].xhi == rects[from].xhi) end += 1;
    return end;
}

fn regionsOf(gpa: Allocator, boxes: []const [4]i64, out: *Regions) !void {
    // Every box on one net: the fixtures below are each one net, drawn in
    // pieces (the shared fixture of the Rust tests ran check's net
    // extraction, whose answer here is one net by construction).
    var b: geom.GeometryStoreBuilder = .empty;
    defer b.deinit(gpa);
    for (boxes) |r| _ = try b.push(gpa, @fromBackingInt(0), &.{ r[0], r[2], r[2], r[0] }, &.{ r[1], r[1], r[3], r[3] });
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try b.finish(gpa, 1, &store, &perm);
    const polys = try gpa.alloc(PolyId, boxes.len);
    defer gpa.free(polys);
    for (polys, 0..) |*p, i| p.* = @fromBackingInt(@intCast(i));
    try std.testing.expectEqual(null, try out.pushNet(gpa, &store, polys, 0, &.{true}));
}

test "pieces of one conductor are one region with the outline's measures" {
    // Oracle: definition. A 12 x 1 bar drawn as three abutting pieces, and
    // an L drawn as two bars that overlap at the corner, are each one
    // region with the outline's own area and perimeter: 12 and 26 for the
    // bar; `20 + 12 - 1 = 31` and `2 (20 + 12) = 64` for the L.
    const gpa = std.testing.allocator;
    var bar: Regions = .empty;
    defer bar.deinit(gpa);
    try regionsOf(gpa, &.{ .{ 0, 0, 4, 1 }, .{ 4, 0, 8, 1 }, .{ 8, 0, 12, 1 } }, &bar);
    try std.testing.expectEqual(1, bar.len());
    try std.testing.expectEqual(12, bar.area.items[0]);
    try std.testing.expectEqual(26, bar.perimeter.items[0]);
    try std.testing.expectEqualSlices(Bbox, &.{.{ .xlo = 0, .ylo = 0, .xhi = 12, .yhi = 1 }}, bar.rectsOf(0));

    var l: Regions = .empty;
    defer l.deinit(gpa);
    try regionsOf(gpa, &.{ .{ 0, 0, 20, 1 }, .{ 19, 0, 20, 12 } }, &l);
    try std.testing.expectEqual(1, l.len());
    try std.testing.expectEqual(31, l.area.items[0]);
    try std.testing.expectEqual(64, l.perimeter.items[0]);
}

test "a corner touch is two regions of one net" {
    // Oracle: definition (F76: a corner is a neck of zero width, which
    // carries no current). Two 4 x 1 bars meeting only at a corner are one
    // net, which the merge makes one polygon, but two regions: each its own
    // bar, area 4 and perimeter `2 (4 + 1) = 10`, in the order of their first
    // rectangles. Read as one region they were the rectangle of area 8 and
    // perimeter 20, `(5 + √17) / (5 − √17)`, about 10.4 squares through a point.
    const gpa = std.testing.allocator;
    var regions: Regions = .empty;
    defer regions.deinit(gpa);
    try regionsOf(gpa, &.{ .{ 0, 0, 4, 1 }, .{ 4, 1, 8, 2 } }, &regions);
    try std.testing.expectEqual(2, regions.len());
    try std.testing.expectEqual(regions.net.items[0], regions.net.items[1]);
    for ([_][2]i64{ .{ 0, 0 }, .{ 4, 1 } }, 0..) |lo, region| {
        try std.testing.expectEqual(4, regions.area.items[region]);
        try std.testing.expectEqual(10, regions.perimeter.items[region]);
        const want: Bbox = .{ .xlo = lo[0], .ylo = lo[1], .xhi = lo[0] + 4, .yhi = lo[1] + 1 };
        try std.testing.expectEqualSlices(Bbox, &.{want}, regions.rectsOf(@intCast(region)));
    }
}

test "a figure touching itself at a corner is one region" {
    // Oracle: definition. A figure that touches itself at a corner but is
    // edge-connected throughout stays one region: the cells `###`, `#.#`,
    // `.##` (top row first) are seven unit squares joined by six shared
    // edges, so area 7 and perimeter `7 * 4 - 2 * 6 = 16`, the outer
    // outline's 12 plus the enclosed cell's 4.
    const gpa = std.testing.allocator;
    var regions: Regions = .empty;
    defer regions.deinit(gpa);
    try regionsOf(gpa, &.{ .{ 0, 2, 3, 3 }, .{ 0, 1, 1, 2 }, .{ 2, 0, 3, 2 }, .{ 1, 0, 2, 1 } }, &regions);
    try std.testing.expectEqual(1, regions.len());
    try std.testing.expectEqual(7, regions.area.items[0]);
    try std.testing.expectEqual(16, regions.perimeter.items[0]);
}
