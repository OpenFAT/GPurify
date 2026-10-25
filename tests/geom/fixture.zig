//! Helpers the geom suite files share: building a store from rings or
//! shapes, validating and merging a layer, and reading a layer back as
//! areas and directed edges. In: integer rings. Out: owned layers the caller
//! deinits with `testing.allocator`.
//!
//! Contents:
//! - `pub const gpa`
//! - `pub const Shape = struct { layer: u16, pts: []const [2]i64 }`
//! - `pub fn storeOfShapes(shapes: []const Shape, layers: u16, store: *GeometryStore) !void`
//! - `pub fn layerOf(rings: []const []const [2]i64, angles: view.Angles, merge: bool) !ValidatedLayer`
//! - `pub fn validated(store: *const GeometryStore, layer: u16, angles: view.Angles) !ValidatedLayer`
//! - `pub fn totalArea(l: *const ValidatedLayer) DbuArea`, `pub fn twiceArea(l: *const ValidatedLayer) i128`
//! - `pub const DirEdge = [2][2]i64`, `pub fn edgeSet(l: *const ValidatedLayer, map: anytype, mirror: bool) !std.ArrayList(DirEdge)`
//! - `pub fn run(kind: Kind, a: *const ValidatedLayer, b: *const ValidatedLayer) !ValidatedLayer`, `pub const Kind = enum { @"or", @"and", not }`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const view = geom.view;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const shapes = @import("testgen").shapes;

pub const gpa = testing.allocator;

/// One drawn polygon: its layer and its open vertex list.
pub const Shape = struct { layer: u16, pts: []const [2]i64 };

/// A directed boundary edge, `(from, to)`.
pub const DirEdge = [2][2]i64;

/// A boolean, named as the decks name them.
pub const Kind = enum { @"or", @"and", not };

/// Every shape pushed through `LayoutBuilder` into `store`.
pub fn storeOfShapes(list: []const Shape, layers: u16, store: *GeometryStore) !void {
    var lb: shapes.LayoutBuilder = .init(layers);
    defer lb.deinit(gpa);
    var xs: std.ArrayList(i64) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(i64) = .empty;
    defer ys.deinit(gpa);
    for (list) |s| {
        xs.clearRetainingCapacity();
        ys.clearRetainingCapacity();
        for (s.pts) |p| {
            try xs.append(gpa, p[0]);
            try ys.append(gpa, p[1]);
        }
        _ = try lb.push(gpa, s.layer, xs.items, ys.items);
    }
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, store, &ids);
}

/// One layer of `store`, validated; a defect fails the test.
pub fn validated(store: *const GeometryStore, layer: u16, angles: view.Angles) !ValidatedLayer {
    var out: ValidatedLayer = .empty;
    errdefer out.deinit(gpa);
    try testing.expectEqual(null, try view.validateLayer(gpa, store, @fromBackingInt(layer), angles, &out));
    return out;
}

/// A layer of the given rings validated under `angles`, merged when asked.
pub fn layerOf(rings: []const []const [2]i64, angles: view.Angles, merge: bool) !ValidatedLayer {
    var list: std.ArrayList(Shape) = .empty;
    defer list.deinit(gpa);
    for (rings) |r| try list.append(gpa, .{ .layer = 0, .pts = r });
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try storeOfShapes(list.items, 1, &store);
    var raw = try validated(&store, 0, angles);
    if (!merge) return raw;
    defer raw.deinit(gpa);
    var out: ValidatedLayer = .empty;
    errdefer out.deinit(gpa);
    try geom.boolean.unionInto(gpa, &raw, &.empty, &out);
    return out;
}

/// The layer's area: every ring's doubled signed area (holes negative),
/// halved.
pub fn totalArea(l: *const ValidatedLayer) DbuArea {
    return @divExact(twiceArea(l), 2);
}

pub fn twiceArea(l: *const ValidatedLayer) i128 {
    var doubled: i128 = 0;
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            doubled += geom.ops.area2(r.xs, r.ys);
        }
    }
    return doubled;
}

/// Every directed boundary edge of a layer through `map` (reversed when the
/// map mirrors), sorted: equal for equal regions whatever vertex each ring
/// starts at.
pub fn edgeSet(l: *const ValidatedLayer, map: anytype, mirror: bool) !std.ArrayList(DirEdge) {
    var out: std.ArrayList(DirEdge) = .empty;
    errdefer out.deinit(gpa);
    for (0..l.len()) |i| {
        const p = l.get(@intCast(i));
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            for (0..r.xs.len) |v| {
                const w = (v + 1) % r.xs.len;
                const a = map(.{ r.xs[v], r.ys[v] });
                const b = map(.{ r.xs[w], r.ys[w] });
                try out.append(gpa, if (mirror) .{ b, a } else .{ a, b });
            }
        }
    }
    std.mem.sortUnstable(DirEdge, out.items, {}, struct {
        fn lessThan(_: void, a: DirEdge, b: DirEdge) bool {
            return std.mem.order(i64, &@as([4]i64, @bitCast(a)), &@as([4]i64, @bitCast(b))) == .lt;
        }
    }.lessThan);
    return out;
}

/// `kind(a, b)` into a fresh layer.
pub fn run(kind: Kind, a: *const ValidatedLayer, b: *const ValidatedLayer) !ValidatedLayer {
    var out: ValidatedLayer = .empty;
    errdefer out.deinit(gpa);
    switch (kind) {
        .@"or" => try geom.boolean.unionInto(gpa, a, b, &out),
        .@"and" => try geom.boolean.intersectionInto(gpa, a, b, &out),
        .not => try geom.boolean.subtractionInto(gpa, a, b, &out),
    }
    return out;
}
