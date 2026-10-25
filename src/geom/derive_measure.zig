//! Selection of whole polygons by a measure of their own: area, width,
//! bounding box, a fitting rectangle, and being a box. In: a merged
//! `ValidatedLayer` and inclusive bounds. Out: the selected polygons, with
//! their store rows. Ported from crates/geom/src/derive.rs (the measures).
//!
//! Contents:
//! - `pub fn withAreaInto(gpa: Allocator, a: *const ValidatedLayer, lo: i128, hi: i128, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn withWidthInto(gpa: Allocator, a: *const ValidatedLayer, lo: i128, hi: i128, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub fn withBboxInto(gpa: Allocator, a: *const ValidatedLayer, side: Side, lo: i128, hi: i128, out: *ValidatedLayer) Allocator.Error!void`, `pub const Side = enum { longer, shorter }`
//! - `pub fn withRectInto(gpa: Allocator, a: *const ValidatedLayer, w: Dbu, h: Dbu, keep: bool, out: *ValidatedLayer) Error!void`
//! - `pub fn rectanglesInto(gpa: Allocator, a: *const ValidatedLayer, square: bool, keep: bool, out: *ValidatedLayer) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const Bbox = @import("bbox.zig").Bbox;
const ops = @import("ops.zig");
const Twice = ops.Twice;
const view = @import("view.zig");
const ValidatedLayer = view.ValidatedLayer;
const boolean = @import("boolean.zig");
const rects = @import("rects.zig");
const width = @import("width.zig");
const size = @import("derive_size.zig");
const Error = size.Error;
const relate = @import("derive_relate.zig");

/// Which side of a bounding box `withBboxInto` reads.
pub const Side = enum { longer, shorter };

/// KLayout `with_area`: polygons whose area in square grid units, holes
/// excluded, is in `lo..=hi`. Exact for an octilinear polygon too, whose
/// area can be a half unit: it is compared doubled.
pub fn withAreaInto(gpa: Allocator, a: *const ValidatedLayer, lo: i128, hi: i128, out: *ValidatedLayer) Allocator.Error!void {
    const keep = try gpa.alloc(bool, a.len());
    defer gpa.free(keep);
    const lo2 = lo *| 2;
    const hi2 = hi *| 2;
    for (keep, 0..) |*k, i| {
        const p = a.get(@intCast(i));
        var twice: i128 = 0;
        for (0..p.ringCount()) |r| {
            const ring = p.ring(@intCast(r));
            twice += ops.area2(ring.xs, ring.ys);
        }
        k.* = twice >= lo2 and twice <= hi2;
    }
    try a.selectInto(gpa, keep, out);
}

/// Polygons whose narrowest width as the `width` rule measures it (diagonal
/// necks count; at 45 degrees `narrowestPair2`'s, at any angle
/// `narrowestPairAny`'s) has twice its square in `lo..=hi`. Twice a squared
/// width is whole at 45 degrees, so a strict bound is exact as an inclusive
/// one (`> 70` is `9801..`); at any angle the bounds' parity keeps their
/// strictness (`widthIn`).
pub fn withWidthInto(gpa: Allocator, a: *const ValidatedLayer, lo: i128, hi: i128, out: *ValidatedLayer) Allocator.Error!void {
    var scratch: width.FacingScratch = .{};
    defer scratch.deinit(gpa);
    const keep = try gpa.alloc(bool, a.len());
    defer gpa.free(keep);
    for (keep, 0..) |*k, i| {
        const poly = a.get(@intCast(i));
        if (a.isRectilinear()) {
            const w2 = 2 * try width.narrowestWidth2(gpa, poly, &scratch);
            k.* = w2 >= lo and w2 <= hi;
        } else if (a.isOctilinear()) {
            const f = try width.narrowestPair2(gpa, poly, .width, dbu.max_abs_dbu);
            k.* = if (f) |w| w.d2 >= lo and w.d2 <= hi else false;
        } else {
            const f = try width.narrowestPairAny(gpa, poly, .width, dbu.max_abs_dbu);
            k.* = if (f) |w| widthIn(w.d2, lo, hi) else false;
        }
    }
    try a.selectInto(gpa, keep, out);
}

/// KLayout `with_bbox_max` (`.longer`) or `with_bbox_min`: polygons whose
/// box's longer, or shorter, side in grid units lies in `lo..=hi`. For a
/// straight feature, the longer side is its length.
pub fn withBboxInto(gpa: Allocator, a: *const ValidatedLayer, side: Side, lo: i128, hi: i128, out: *ValidatedLayer) Allocator.Error!void {
    const keep = try gpa.alloc(bool, a.len());
    defer gpa.free(keep);
    for (keep, a.bboxes()) |*k, b| {
        const v: i128 = switch (side) {
            .longer => @max(b.width(), b.height()),
            .shorter => @min(b.width(), b.height()),
        };
        k.* = v >= lo and v <= hi;
    }
    try a.selectInto(gpa, keep, out);
}

/// Calibre `ENCLOSE RECTANGLE` (`keep`) or `NOT ENCLOSE RECTANGLE`: the
/// polygons of merged `a` that can hold an axis-aligned `w` x `h` box, either
/// way round, its boundary allowed on theirs (KLayout forum thread 2141).
/// Exact on rectilinear input: a polygon with whole-unit vertices holds the
/// box exactly when its erosion by `[0, w - 1] x [0, h - 1]` keeps a positive
/// area. `error.NotRectilinear` for a layer with a 45-degree edge; asserts
/// `w, h > 0`.
pub fn withRectInto(gpa: Allocator, a: *const ValidatedLayer, w: Dbu, h: Dbu, keep: bool, out: *ValidatedLayer) Error!void {
    assert(w > 0 and h > 0);
    if (!a.isRectilinear()) return error.NotRectilinear;
    const flags = try gpa.alloc(bool, a.len());
    defer gpa.free(flags);
    const turned = try gpa.alloc(bool, a.len());
    defer gpa.free(turned);
    var room: ValidatedLayer = .empty;
    defer room.deinit(gpa);
    try roomInto(gpa, a, w, h, &room);
    try relate.overlappingFlags(gpa, a, &room, flags);
    if (w != h) {
        try roomInto(gpa, a, h, w, &room);
        try relate.overlappingFlags(gpa, a, &room, turned);
        for (flags, turned) |*f, t| f.* = f.* or t;
    }
    for (flags) |*f| f.* = f.* == keep;
    try a.selectInto(gpa, flags, out);
}

/// KLayout `rectangles` / `squares` (`keep`), or `non_rectangles` /
/// `non_squares`: the polygons of merged `a` that are, or are not, one axis
/// box with no hole (with `square`, equal sides). A rectangle drawn as
/// abutting pieces is one rectangle; two boxes meeting at a corner are one
/// polygon that is none.
pub fn rectanglesInto(gpa: Allocator, a: *const ValidatedLayer, square: bool, keep: bool, out: *ValidatedLayer) Allocator.Error!void {
    const flags = try gpa.alloc(bool, a.len());
    defer gpa.free(flags);
    for (flags, 0..) |*f, i| {
        const poly = a.get(@intCast(i));
        const b = poly.bbox();
        // A merged ring has no collinear vertex: four corners, every edge
        // horizontal or vertical, are a box (a diamond has four too).
        const r = poly.outer();
        var axis = true;
        for (0..r.xs.len) |v| {
            const e = ops.ringEdge(r.xs, r.ys, v);
            axis = axis and (e.a.x == e.b.x or e.a.y == e.b.y);
        }
        const boxed = r.xs.len == 4 and axis and poly.ringCount() == 1;
        f.* = (boxed and (!square or b.width() == b.height())) == keep;
    }
    try a.selectInto(gpa, flags, out);
}

// ---- private ----

/// Whether a width at any angle lies in a deck's bounds, whose strictness the
/// parity of each end keeps: a lower end `2a²` is `>= a` and `2a² + 1` is
/// `> a`, either of which the ceiling meets exactly; an upper end `2b²` is
/// `<= b`, which the ceiling meets, and `2b² - 1` is `< b`, which the floor
/// meets.
fn widthIn(w: Twice, lo: i128, hi: i128) bool {
    const ceil = w.floor + @intFromBool(w.inexact);
    const top = if (@mod(hi, 2) == 0) ceil else w.floor;
    return lo <= ceil and top <= hi;
}

/// The lower-left corners at which a `w` x `h` box fits in `a`, less one
/// unit each way: `a` minus everything within `[-(w - 1), 0] x [-(h - 1), 0]`
/// of its complement (taken in a frame reaching `w`, `h` past its extent).
fn roomInto(gpa: Allocator, a: *const ValidatedLayer, w: Dbu, h: Dbu, out: *ValidatedLayer) Error!void {
    var outside: ValidatedLayer = .empty;
    defer outside.deinit(gpa);
    if (!try size.complementInto(gpa, a, w, h, &outside)) return size.mergeInto(gpa, a, out);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try rects.decomposeInto(gpa, &outside, &boxes, &start);
    var builder: @import("store.zig").GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    try builder.ensureUnusedCapacity(gpa, boxes.items.len, 4 * boxes.items.len);
    for (boxes.items) |r| {
        const xlo = r.xlo - (w - 1);
        const ylo = r.ylo - (h - 1);
        if (!dbu.inDomain(xlo) or !dbu.inDomain(ylo)) return error.OutOfRange;
        try size.pushRect(gpa, &builder, .{ .xlo = xlo, .ylo = ylo, .xhi = r.xhi, .yhi = r.yhi });
    }
    var eaten: ValidatedLayer = .empty;
    defer eaten.deinit(gpa);
    try size.mergedInto(gpa, &builder, &eaten);
    try boolean.subtractionInto(gpa, a, &eaten, out);
}
