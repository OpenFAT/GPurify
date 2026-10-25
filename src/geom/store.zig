//! The one place a polygon lives. In: rings as `(layer, xs, ys)` in arrival
//! order (`GeometryStoreBuilder.push`), and derived layers appended whole.
//! Out: `GeometryStore`, one column per field, rows grouped by layer, and
//! the arrival permutation. Ported from crates/geom/src/store.rs;
//! `firstVertex` moved down from check/erc.
//!
//! Contents:
//! - `pub const Rows = struct { start: u32, end: u32 }`, `Rows.len(r: Rows) u32`
//! - `pub const GeometryStore = struct`, `GeometryStore.empty`, `deinit`,
//!   `polyCount(s: *const GeometryStore) u32`, `layerCount(s: *const GeometryStore) u32`,
//!   `polysOnLayer(s: *const GeometryStore, layer: LayerId) Rows`,
//!   `polyVerts(s: *const GeometryStore, poly: PolyId) Ring`,
//!   `polyBbox(s: *const GeometryStore, poly: PolyId) Bbox`,
//!   `polyLayer(s: *const GeometryStore, poly: PolyId) LayerId`,
//!   `layerBboxes(s: *const GeometryStore, layer: LayerId) []const Bbox`,
//!   `polyContainsPoint(s: *const GeometryStore, poly: PolyId, p: Point) bool`,
//!   `firstVertex(s: *const GeometryStore, poly: PolyId) Point`,
//!   `markUncomputed(s: *GeometryStore, gpa: Allocator, layer: LayerId) Allocator.Error!void`,
//!   `isUncomputed(s: *const GeometryStore, layer: LayerId) bool`,
//!   `edgesOnLayer(s: *const GeometryStore, layer: LayerId) []const Seg`,
//!   `appendEdges(s: *GeometryStore, gpa: Allocator, layer: LayerId, edges: []const Seg) Allocator.Error!void`,
//!   `appendLayer(s: *GeometryStore, gpa: Allocator, layer: LayerId, xs: []const Dbu, ys: []const Dbu, vert_start: []const u32, vert_len: []const u32) Allocator.Error!void`
//! - `pub const GeometryStoreBuilder = struct`, `GeometryStoreBuilder.empty`, `deinit`,
//!   `ensureUnusedCapacity(b: *GeometryStoreBuilder, gpa: Allocator, polys: usize, verts: usize) Allocator.Error!void`,
//!   `push(b: *GeometryStoreBuilder, gpa: Allocator, layer: LayerId, xs: []const Dbu, ys: []const Dbu) Allocator.Error!u32`,
//!   `finish(b: *const GeometryStoreBuilder, gpa: Allocator, layer_count: u16, store: *GeometryStore, permutation: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Dbu = @import("dbu.zig").Dbu;
const Bbox = @import("bbox.zig").Bbox;
const ids = @import("ids.zig");
const LayerId = ids.LayerId;
const PolyId = ids.PolyId;
const ops = @import("ops.zig");
const Point = ops.Point;
const Ring = ops.Ring;
const Seg = ops.Seg;

/// A run of store rows, `start..end`.
pub const Rows = struct {
    start: u32,
    end: u32,

    pub fn len(r: Rows) u32 {
        return r.end - r.start;
    }
};

/// Flat layout geometry: one row per ring, a column per field, rows grouped
/// by layer so a layer is one range (`polysOnLayer`). A row is one stored
/// ring, not yet a polygon: a hole is its own clockwise row, bound to its
/// outer only by validation. Rows are immutable once stored and layers only
/// appended, so a `PolyId` stays valid for the store's life.
///
/// Invariants: `layer_start` and `edge_layer_start` are CSR offsets,
/// `layer_count + 1` long (empty only in `empty`); row `i`'s vertices are
/// `verts_*[poly_vert_start[i]..][0..poly_vert_len[i]]` and its box their
/// box; `uncomputed` ascends.
pub const GeometryStore = struct {
    verts_x: std.ArrayList(Dbu) = .empty,
    verts_y: std.ArrayList(Dbu) = .empty,
    poly_layer: std.ArrayList(LayerId) = .empty,
    poly_vert_start: std.ArrayList(u32) = .empty,
    poly_vert_len: std.ArrayList(u32) = .empty,
    poly_bbox: std.ArrayList(Bbox) = .empty,
    layer_start: std.ArrayList(u32) = .empty,
    /// Edge layers' segments, material left of travel, grouped by layer.
    edges: std.ArrayList(Seg) = .empty,
    edge_layer_start: std.ArrayList(u32) = .empty,
    /// Derived layers that could not be computed; each stays empty.
    uncomputed: std.ArrayList(LayerId) = .empty,

    pub const empty: GeometryStore = .{};

    pub fn deinit(s: *GeometryStore, gpa: Allocator) void {
        inline for (@typeInfo(GeometryStore).@"struct".field_names) |name| @field(s, name).deinit(gpa);
    }

    /// Polygon rows over every layer.
    pub fn polyCount(s: *const GeometryStore) u32 {
        return @intCast(s.poly_layer.items.len);
    }

    /// The `layer_count` given to `finish`, empty layers included.
    pub fn layerCount(s: *const GeometryStore) u32 {
        return @intCast(@max(s.layer_start.items.len, 1) - 1);
    }

    /// One layer's rows. Asserts the layer is in the table, so "no such
    /// layer" never reads as "empty layer".
    pub fn polysOnLayer(s: *const GeometryStore, layer: LayerId) Rows {
        const l = @backingInt(layer);
        assert(l < s.layerCount());
        return .{ .start = s.layer_start.items[l], .end = s.layer_start.items[l + 1] };
    }

    /// One row's ring, open.
    pub fn polyVerts(s: *const GeometryStore, poly: PolyId) Ring {
        const i = @backingInt(poly);
        const start = s.poly_vert_start.items[i];
        const len = s.poly_vert_len.items[i];
        return .{ .xs = s.verts_x.items[start..][0..len], .ys = s.verts_y.items[start..][0..len] };
    }

    pub fn polyBbox(s: *const GeometryStore, poly: PolyId) Bbox {
        return s.poly_bbox.items[@backingInt(poly)];
    }

    pub fn polyLayer(s: *const GeometryStore, poly: PolyId) LayerId {
        return s.poly_layer.items[@backingInt(poly)];
    }

    /// One layer's boxes in row order: element `i` is row `start + i`.
    pub fn layerBboxes(s: *const GeometryStore, layer: LayerId) []const Bbox {
        const rows = s.polysOnLayer(layer);
        return s.poly_bbox.items[rows.start..rows.end];
    }

    /// Whether `p` lies inside one row's ring, boundary inclusive (labels sit
    /// on corners and edges). Reads that ring only: a point in a hole is
    /// inside its outer row.
    pub fn polyContainsPoint(s: *const GeometryStore, poly: PolyId, p: Point) bool {
        const r = s.polyVerts(poly);
        return ops.pointInRing(r.xs, r.ys, p);
    }

    /// A point on a row for a violation: vertex zero, which lies on the
    /// shape (a box corner of an L sits in the notch).
    pub fn firstVertex(s: *const GeometryStore, poly: PolyId) Point {
        const r = s.polyVerts(poly);
        return .{ .x = r.xs[0], .y = r.ys[0] };
    }

    /// Marks a derived layer that could not be computed. It stays empty, and
    /// validating it is the `uncomputed` defect, so every rule that reads it
    /// refuses and nothing else is touched.
    pub fn markUncomputed(s: *GeometryStore, gpa: Allocator, layer: LayerId) Allocator.Error!void {
        const at = std.sort.lowerBound(LayerId, s.uncomputed.items, layer, orderLayer);
        if (at < s.uncomputed.items.len and s.uncomputed.items[at] == layer) return;
        try s.uncomputed.insert(gpa, at, layer);
    }

    pub fn isUncomputed(s: *const GeometryStore, layer: LayerId) bool {
        return std.sort.binarySearch(LayerId, s.uncomputed.items, layer, orderLayer) != null;
    }

    /// One edge layer's segments; empty on a polygon layer.
    pub fn edgesOnLayer(s: *const GeometryStore, layer: LayerId) []const Seg {
        const l = @backingInt(layer);
        assert(l < s.layerCount());
        return s.edges.items[s.edge_layer_start.items[l]..s.edge_layer_start.items[l + 1]];
    }

    /// Appends one whole edge layer's segments. Asserts no later layer holds
    /// segments yet.
    pub fn appendEdges(s: *GeometryStore, gpa: Allocator, layer: LayerId, edges: []const Seg) Allocator.Error!void {
        const l = @backingInt(layer);
        assert(l < s.layerCount());
        assert(s.edge_layer_start.items[l] == s.edges.items.len);
        assert(s.edges.items.len + edges.len <= std.math.maxInt(u32));
        try s.edges.appendSlice(gpa, edges);
        for (s.edge_layer_start.items[l + 1 ..]) |*offset| offset.* += @intCast(edges.len);
    }

    /// Appends one whole layer's rings after every stored row: ring `i` is
    /// `xs[vert_start[i]..][0..vert_len[i]]` and the same of `ys`. How
    /// derived layers are added, in ascending id order, after `finish`; the
    /// rings are stored as given, not validated. Asserts parallel columns,
    /// every run inside `xs`, and that no later layer holds rows yet (they
    /// would land in another layer's range). On error the store is unchanged.
    pub fn appendLayer(s: *GeometryStore, gpa: Allocator, layer: LayerId, xs: []const Dbu, ys: []const Dbu, vert_start: []const u32, vert_len: []const u32) Allocator.Error!void {
        const l = @backingInt(layer);
        assert(xs.len == ys.len and vert_start.len == vert_len.len);
        assert(l < s.layerCount());
        assert(s.layer_start.items[l] == s.polyCount());
        // A wrapped cursor would hand `polyVerts` another polygon's coordinates.
        assert(s.verts_x.items.len + xs.len <= std.math.maxInt(u32));
        const rings = vert_start.len;
        try s.verts_x.ensureUnusedCapacity(gpa, xs.len);
        try s.verts_y.ensureUnusedCapacity(gpa, ys.len);
        try s.poly_layer.ensureUnusedCapacity(gpa, rings);
        try s.poly_vert_start.ensureUnusedCapacity(gpa, rings);
        try s.poly_vert_len.ensureUnusedCapacity(gpa, rings);
        try s.poly_bbox.ensureUnusedCapacity(gpa, rings);

        const base: u32 = @intCast(s.verts_x.items.len);
        s.verts_x.appendSliceAssumeCapacity(xs);
        s.verts_y.appendSliceAssumeCapacity(ys);
        for (vert_start, vert_len) |start, len| {
            assert(start + len <= xs.len);
            s.poly_layer.appendAssumeCapacity(layer);
            s.poly_vert_start.appendAssumeCapacity(base + start);
            s.poly_vert_len.appendAssumeCapacity(len);
            s.poly_bbox.appendAssumeCapacity(.ofPoints(xs[start..][0..len], ys[start..][0..len]));
        }
        // Every later layer was empty, so its offset moves by the same amount.
        for (s.layer_start.items[l + 1 ..]) |*offset| offset.* += @intCast(rings);
    }
};

/// Accumulates rings in arrival order; `finish` sorts them by layer into a
/// `GeometryStore`. Row `i` is `verts_*[poly_vert_start[i]..][0..poly_vert_len[i]]`.
pub const GeometryStoreBuilder = struct {
    verts_x: std.ArrayList(Dbu) = .empty,
    verts_y: std.ArrayList(Dbu) = .empty,
    poly_layer: std.ArrayList(LayerId) = .empty,
    poly_vert_start: std.ArrayList(u32) = .empty,
    poly_vert_len: std.ArrayList(u32) = .empty,

    pub const empty: GeometryStoreBuilder = .{};

    pub fn deinit(b: *GeometryStoreBuilder, gpa: Allocator) void {
        inline for (@typeInfo(GeometryStoreBuilder).@"struct".field_names) |name| @field(b, name).deinit(gpa);
    }

    /// Room for `polys` more rings of `verts` vertices in total, so a reader
    /// that knows its counts allocates once.
    pub fn ensureUnusedCapacity(b: *GeometryStoreBuilder, gpa: Allocator, polys: usize, verts: usize) Allocator.Error!void {
        try b.verts_x.ensureUnusedCapacity(gpa, verts);
        try b.verts_y.ensureUnusedCapacity(gpa, verts);
        try b.poly_layer.ensureUnusedCapacity(gpa, polys);
        try b.poly_vert_start.ensureUnusedCapacity(gpa, polys);
        try b.poly_vert_len.ensureUnusedCapacity(gpa, polys);
    }

    /// Appends one open ring (no repeated closing vertex) and returns its
    /// arrival row, the value `finish`'s permutation maps back to.
    /// Counter-clockwise is an outer and clockwise a hole; nothing is checked
    /// until validation. Asserts parallel columns and that the totals fit
    /// `u32` (unequal columns would pair one polygon's x with the next's y).
    pub fn push(b: *GeometryStoreBuilder, gpa: Allocator, layer: LayerId, xs: []const Dbu, ys: []const Dbu) Allocator.Error!u32 {
        assert(xs.len == ys.len);
        // The run's end must fit too, or `finish`'s u32 cursor wraps.
        assert(b.verts_x.items.len + xs.len <= std.math.maxInt(u32));
        assert(b.poly_layer.items.len < std.math.maxInt(u32));
        try b.ensureUnusedCapacity(gpa, 1, xs.len);
        const row: u32 = @intCast(b.poly_layer.items.len);
        b.poly_vert_start.appendAssumeCapacity(@intCast(b.verts_x.items.len));
        b.poly_vert_len.appendAssumeCapacity(@intCast(xs.len));
        b.verts_x.appendSliceAssumeCapacity(xs);
        b.verts_y.appendSliceAssumeCapacity(ys);
        b.poly_layer.appendAssumeCapacity(layer);
        return row;
    }

    /// Sorts the rings by layer, stably, into `store` and computes their
    /// boxes; `permutation[new_row] == old_row` (both cleared and refilled),
    /// so a reader permutes its own per-ring columns by it. `layer_count`
    /// comes from the deck: a layer with no shapes still gets an empty
    /// range, and derived layers can be appended later. `O(rings + vertices
    /// + layer_count)`. Asserts every ring's layer is below `layer_count`.
    pub fn finish(b: *const GeometryStoreBuilder, gpa: Allocator, layer_count: u16, store: *GeometryStore, permutation: *std.ArrayList(u32)) Allocator.Error!void {
        const rows = b.poly_layer.items.len;
        store.deinit(gpa);
        store.* = .empty;
        errdefer store.deinit(gpa);
        try store.layer_start.appendNTimes(gpa, 0, @as(usize, layer_count) + 1);
        try store.edge_layer_start.appendNTimes(gpa, 0, @as(usize, layer_count) + 1);
        const starts = store.layer_start.items;
        // A histogram offset by one, prefix-summed in place into CSR offsets.
        for (b.poly_layer.items) |layer| {
            assert(@backingInt(layer) < layer_count);
            starts[@as(usize, @backingInt(layer)) + 1] += 1;
        }
        for (0..layer_count) |l| starts[l + 1] += starts[l];

        // Arrivals in ascending order to per-layer cursors: stable.
        const cursor = try gpa.dupe(u32, starts[0..layer_count]);
        defer gpa.free(cursor);
        try permutation.resize(gpa, rows);
        for (b.poly_layer.items, 0..) |layer, old| {
            const slot = &cursor[@backingInt(layer)];
            permutation.items[slot.*] = @intCast(old);
            slot.* += 1;
        }

        try store.verts_x.ensureTotalCapacity(gpa, b.verts_x.items.len);
        try store.verts_y.ensureTotalCapacity(gpa, b.verts_y.items.len);
        try store.poly_layer.ensureTotalCapacity(gpa, rows);
        try store.poly_vert_start.ensureTotalCapacity(gpa, rows);
        try store.poly_vert_len.ensureTotalCapacity(gpa, rows);
        try store.poly_bbox.ensureTotalCapacity(gpa, rows);
        // Coordinates are permuted too, so one layer's runs stay contiguous.
        for (permutation.items) |old| {
            const from = b.poly_vert_start.items[old];
            const len = b.poly_vert_len.items[old];
            const xs = b.verts_x.items[from..][0..len];
            const ys = b.verts_y.items[from..][0..len];
            store.poly_layer.appendAssumeCapacity(b.poly_layer.items[old]);
            store.poly_vert_start.appendAssumeCapacity(@intCast(store.verts_x.items.len));
            store.poly_vert_len.appendAssumeCapacity(len);
            store.poly_bbox.appendAssumeCapacity(.ofPoints(xs, ys));
            store.verts_x.appendSliceAssumeCapacity(xs);
            store.verts_y.appendSliceAssumeCapacity(ys);
        }
        assert(starts[layer_count] == rows);
    }
};

// ---- private ----

fn orderLayer(a: LayerId, b: LayerId) std.math.Order {
    return std.math.order(@backingInt(a), @backingInt(b));
}
