//! The ring and region geometry the latchup, ESD and reliability kinds
//! share: the figures of a merged layer narrower than a limit
//! (`narrowRingsInto`), whether one polygon of a decomposed layer covers a
//! box (`encloses`), the distance between two regions (zero when one holds
//! the other), and the nets a pad layer's polygons are on. In: the store,
//! nets, a layer. Out: rows, booleans, squared distances. Ported from
//! crates/check/src/erc/rules/{reliability,latchup}.rs (`narrow_rings`,
//! `encloses`, `poly_dist2`, `pad_nets`).
//!
//! Contents:
//! - `pub const Narrow = struct { poly: PolyId, band: Dbu }`
//! - `pub fn narrowRingsInto(gpa: Allocator, design: Design, layer: LayerId, limit: Dbu, scratch: *Scratch, out: *std.ArrayList(Narrow)) Allocator.Error!bool`
//! - `pub fn encloses(rects: []const Bbox, start: []const u32, inner: Bbox) bool`
//! - `pub fn regionDist2(store: *const GeometryStore, a: PolyId, b: PolyId) DbuArea`
//! - `pub fn padNetsInto(gpa: Allocator, design: Design, pad: LayerId, out: *std.ArrayList(NetId)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ops = geom.ops;
const rects = @import("../rects.zig");
const NetId = @import("../topology/net.zig").NetId;
const pointInRegion = @import("../topology/taps.zig").pointInRegion;
const Design = @import("head.zig").Design;
const Scratch = @import("scratch.zig").Scratch;

/// A figure narrower than the limit: the lowest drawn row under it, and its
/// narrowest band.
pub const Narrow = struct { poly: PolyId, band: Dbu };

/// Every figure of the merged `layer` narrower than `limit`, ascending by
/// `(row, band)`: facing edges across material and diagonal necks between
/// concave corners, the measure of DRC `width`. False (and `out` empty)
/// when the layer will not validate rectilinear.
pub fn narrowRingsInto(gpa: Allocator, design: Design, layer: LayerId, limit: Dbu, scratch: *Scratch, out: *std.ArrayList(Narrow)) Allocator.Error!bool {
    out.clearRetainingCapacity();
    if (try geom.view.validateLayer(gpa, design.store, layer, .rectilinear, &scratch.layer_a) != null) return false;
    var drawn: rects.LayerRects = .{};
    defer drawn.deinit(gpa);
    try drawn.build(gpa, design.store, layer, &scratch.layer_a);
    const nothing: geom.ValidatedLayer = .empty;
    try geom.boolean.unionInto(gpa, &scratch.layer_a, &nothing, &scratch.layer_b);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    try rects.ownersOfInto(gpa, &scratch.layer_b, &drawn, &owners);
    var facing: geom.width.FacingScratch = .{};
    defer facing.deinit(gpa);
    for (owners.items, 0..) |owner, idx| {
        const figure = scratch.layer_b.get(@intCast(idx));
        var band: ?Dbu = null;
        if (try geom.width.narrowestFacing(gpa, figure, .width, &facing)) |f| band = f.gap;
        if (try geom.width.narrowestNeck(gpa, figure, limit)) |f| band = @min(band orelse f.gap, f.gap);
        const b = band orelse continue;
        if (b < limit) try out.append(gpa, .{ .poly = owner, .band = b });
    }
    std.mem.sortUnstable(Narrow, out.items, {}, struct {
        fn less(_: void, x: Narrow, y: Narrow) bool {
            if (x.poly != y.poly) return @backingInt(x.poly) < @backingInt(y.poly);
            return x.band < y.band;
        }
    }.less);
    return true;
}

/// One polygon of a decomposed layer (`rects[start[p] .. start[p + 1]]`,
/// holes left out) covers all of `inner`: its area inside `inner` is all of
/// `inner`'s. Exact, so a cover drawn on `inner`'s own edges covers it.
pub fn encloses(boxes: []const Bbox, start: []const u32, inner: Bbox) bool {
    if (start.len < 2) return false;
    for (start[0 .. start.len - 1], start[1..]) |from, to| {
        if (geom.rects.clippedArea(boxes[from..to], inner) == inner.area()) return true;
    }
    return false;
}

/// Squared distance between two polygons' outlines; zero when they touch
/// or one lies in the other.
pub fn regionDist2(store: *const GeometryStore, a: PolyId, b: PolyId) DbuArea {
    const ra = store.polyVerts(a);
    const rb = store.polyVerts(b);
    if (pointInRegion(rb.xs, rb.ys, .{ .x = ra.xs[0], .y = ra.ys[0] }) or pointInRegion(ra.xs, ra.ys, .{ .x = rb.xs[0], .y = rb.ys[0] })) return 0;
    var best: DbuArea = std.math.maxInt(DbuArea);
    for (0..ra.xs.len) |i| {
        const edge = ops.ringEdge(ra.xs, ra.ys, i);
        for (0..rb.xs.len) |j| best = @min(best, ops.segSegDist2(edge, ops.ringEdge(rb.xs, rb.ys, j)));
    }
    return best;
}

/// Every net holding a polygon of `pad`, ascending; none on a design never
/// extracted.
pub fn padNetsInto(gpa: Allocator, design: Design, pad: LayerId, out: *std.ArrayList(NetId)) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (design.nets.netCount() == 0) return;
    const rows = design.store.polysOnLayer(pad);
    for (0..rows.len()) |k| {
        const net = design.nets.netOf(@fromBackingInt(rows.start + @as(u32, @intCast(k))));
        if (net != .none) try out.append(gpa, net);
    }
    std.mem.sortUnstable(NetId, out.items, {}, struct {
        fn less(_: void, x: NetId, y: NetId) bool {
            return @backingInt(x) < @backingInt(y);
        }
    }.less);
    var kept: usize = 0;
    for (out.items) |n| if (kept == 0 or out.items[kept - 1] != n) {
        out.items[kept] = n;
        kept += 1;
    };
    out.shrinkRetainingCapacity(kept);
}
