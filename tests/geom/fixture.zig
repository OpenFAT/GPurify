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
//! - `pub const oct_side`, `pub fn randomOctShape(arena: std.mem.Allocator, rng: *Rng) ![]const [2]i64`
//! - `pub fn dropOne(comptime T: type, arena: std.mem.Allocator, items: []const T, keep_nonempty: bool) ![]const []const T`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const view = geom.view;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const shapes = @import("testgen").shapes;
const Rng = @import("testgen").Rng;

pub const gpa = testing.allocator;

/// `randomOctShape` draws inside `[0, oct_side]²`.
pub const oct_side = 16;

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

/// A random octilinear shape inside `[0, oct_side]²`, counter-clockwise: a
/// rectangle with chamfered corners, a diamond, a right triangle, or a
/// parallelogram (boolean_octilinear.rs's `random_shape`).
pub fn randomOctShape(arena: std.mem.Allocator, rng: *Rng) ![]const [2]i64 {
    const s = oct_side;
    var pts: std.ArrayList([2]i64) = .empty;
    switch (rng.range(0, 4)) {
        0 => {
            const x0 = rng.range(0, s - 1);
            const y0 = rng.range(0, s - 1);
            const x1 = rng.range(x0 + 1, s + 1);
            const y1 = rng.range(y0 + 1, s + 1);
            const most = @divTrunc(@min(x1 - x0, y1 - y0), 2);
            var c: [4]i64 = undefined;
            for (&c) |*v| v.* = rng.range(0, most + 1);
            const all = [8][2]i64{
                .{ x0 + c[0], y0 }, .{ x1 - c[1], y0 }, .{ x1, y0 + c[1] }, .{ x1, y1 - c[2] },
                .{ x1 - c[2], y1 }, .{ x0 + c[3], y1 }, .{ x0, y1 - c[3] }, .{ x0, y0 + c[0] },
            };
            // Consecutive repeats dropped, the closing vertex included.
            for (all) |p| {
                if (pts.items.len > 0 and std.mem.eql(i64, &pts.items[pts.items.len - 1], &p)) continue;
                try pts.append(arena, p);
            }
            while (pts.items.len > 1 and std.mem.eql(i64, &pts.items[0], &pts.items[pts.items.len - 1])) _ = pts.pop();
        },
        1 => {
            const r = rng.range(1, @divTrunc(s, 2) + 1);
            const cx = rng.range(r, s - r + 1);
            const cy = rng.range(r, s - r + 1);
            try pts.appendSlice(arena, &.{ .{ cx + r, cy }, .{ cx, cy + r }, .{ cx - r, cy }, .{ cx, cy - r } });
        },
        2 => {
            const e = rng.range(1, s + 1);
            const x = rng.range(0, s - e + 1);
            const y = rng.range(0, s - e + 1);
            try pts.appendSlice(arena, switch (rng.range(0, 4)) {
                0 => &.{ .{ x, y }, .{ x + e, y }, .{ x, y + e } },
                1 => &.{ .{ x, y }, .{ x + e, y }, .{ x + e, y + e } },
                2 => &.{ .{ x + e, y }, .{ x + e, y + e }, .{ x, y + e } },
                else => &.{ .{ x, y }, .{ x + e, y + e }, .{ x, y + e } },
            });
        },
        else => {
            const w = rng.range(1, @divTrunc(s, 2) + 1);
            const h = rng.range(1, @divTrunc(s, 2) + 1);
            const x = rng.range(0, s - w - h + 1);
            const y = rng.range(0, s - h + 1);
            if (rng.range(0, 2) == 0) {
                try pts.appendSlice(arena, &.{ .{ x, y }, .{ x + w, y }, .{ x + w + h, y + h }, .{ x + h, y + h } });
            } else {
                try pts.appendSlice(arena, &.{ .{ x + h, y }, .{ x + h + w, y }, .{ x + w, y + h }, .{ x, y + h } });
            }
        },
    }
    return pts.items;
}

/// Every candidate with one element dropped, empty candidates left out when
/// `keep_nonempty`.
pub fn dropOne(comptime T: type, arena: std.mem.Allocator, items: []const T, keep_nonempty: bool) ![]const []const T {
    var out: std.ArrayList([]const T) = .empty;
    for (0..items.len) |skip| {
        if (keep_nonempty and items.len == 1) continue;
        const fewer = try arena.alloc(T, items.len - 1);
        @memcpy(fewer[0..skip], items[0..skip]);
        @memcpy(fewer[skip..], items[skip + 1 ..]);
        try out.append(arena, fewer);
    }
    return out.items;
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
