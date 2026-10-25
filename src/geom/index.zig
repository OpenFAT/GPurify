//! Spatial index and candidate pairs. In: one layer's bounding boxes from a
//! `GeometryStore`. Out: the `(a, b)` row pairs whose boxes are within a
//! distance, ascending and deduplicated: a superset of the true pairs that
//! never misses one, so a check prunes with it and measures each pair
//! exactly. Ported from crates/geom/src/index.rs.
//!
//! Contents:
//! - `pub const Pair = struct { a: PolyId, b: PolyId }`
//! - `pub const SpatialIndex = struct`, `SpatialIndex.empty`, `deinit`,
//!   `build(ix: *SpatialIndex, gpa: Allocator, store: *const GeometryStore, layer: LayerId) Allocator.Error!void`,
//!   `isEmpty(ix: *const SpatialIndex) bool`
//! - `pub fn candidatePairsInto(gpa: Allocator, store: *const GeometryStore, ix: *const SpatialIndex, distance: Dbu, out: *std.ArrayList(Pair)) Allocator.Error!void`
//! - `pub fn crossLayerPairsInto(gpa: Allocator, store: *const GeometryStore, a_layer: LayerId, b_index: *const SpatialIndex, distance: Dbu, out: *std.ArrayList(Pair)) Allocator.Error!void`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Dbu = @import("dbu.zig").Dbu;
const Bbox = @import("bbox.zig").Bbox;
const ids = @import("ids.zig");
const LayerId = ids.LayerId;
const PolyId = ids.PolyId;
const GeometryStore = @import("store.zig").GeometryStore;

/// Two store rows; on one layer `a < b`.
pub const Pair = struct {
    a: PolyId,
    b: PolyId,

    fn key(p: Pair) u64 {
        return @as(u64, @backingInt(p.a)) << 32 | @backingInt(p.b);
    }
};

/// A two-level uniform grid over one layer's boxes. A box is filed under
/// every cell it overlaps, and each level's cell is at least as wide as its
/// widest box, so a box spans at most 2 x 2 cells (`<= 4n` filings) however
/// the scales mix. Answers for the store it was built from only.
pub const SpatialIndex = struct {
    /// The layer built, or null for an index never built: an empty pair
    /// list must always mean "no pairs", never "never asked".
    layer: ?LayerId = null,
    /// Boxes no wider than the fine cell; non-empty whenever the layer is.
    fine: Level = .{},
    /// Boxes wider than the fine cell; empty when there are none.
    coarse: Level = .{},

    pub const empty: SpatialIndex = .{};

    pub fn deinit(ix: *SpatialIndex, gpa: Allocator) void {
        ix.fine.deinit(gpa);
        ix.coarse.deinit(gpa);
    }

    /// Rebuilds over one layer of `store`, in `O(n)` space and expected time
    /// for `n` polygons, reusing the allocations.
    pub fn build(ix: *SpatialIndex, gpa: Allocator, store: *const GeometryStore, layer: LayerId) Allocator.Error!void {
        const bboxes = store.layerBboxes(layer);
        const first = store.polysOnLayer(layer).start;
        ix.layer = layer;
        ix.fine.clear();
        ix.coarse.clear();
        const n = bboxes.len;
        if (n == 0) return;

        var extent = Bbox.empty;
        for (bboxes) |b| extent = extent.merge(b);
        const span_x = extent.xhi - extent.xlo + 1;
        const span_y = extent.yhi - extent.ylo + 1;

        // The median extent, widened until the bucket table is O(rows)
        // whatever the aspect ratio.
        const extents = try gpa.alloc(i64, n);
        defer gpa.free(extents);
        for (extents, bboxes) |*e, b| e.* = boxExtent(b);
        const widest = std.mem.max(i64, extents);
        // ponytail: a full sort for the median, O(n log n); a select if a
        // profile shows index builds.
        std.mem.sortUnstable(i64, extents, {}, std.sort.asc(i64));
        const side: i64 = @max(std.math.sqrt(@as(u64, 4 * n + 64)), 1);
        const fine_cell = @max(extents[n / 2], 1, divCeil(span_x, side), divCeil(span_y, side));

        try ix.fine.build(gpa, bboxes, first, extent, fine_cell, 0);
        if (widest > fine_cell) try ix.coarse.build(gpa, bboxes, first, extent, widest, fine_cell + 1);
    }

    /// No rows: the layer has no polygons, or the index was never built.
    pub fn isEmpty(ix: *const SpatialIndex) bool {
        return ix.fine.rows.items.len == 0 and ix.coarse.rows.items.len == 0;
    }
};

/// One level: a CSR bucket table over the boxes whose extent lies in
/// `min_ext..=cell`. Bucket `k` holds `rows[bucket_start[k]..bucket_start[k + 1]]`,
/// store rows ascending.
const Level = struct {
    cell: i64 = 1,
    /// The union of the layer's boxes, so both levels share one origin.
    extent: Bbox = Bbox.empty,
    min_ext: i64 = 0,
    nx: u32 = 0,
    ny: u32 = 0,
    bucket_start: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(u32) = .empty,

    fn deinit(l: *Level, gpa: Allocator) void {
        l.bucket_start.deinit(gpa);
        l.rows.deinit(gpa);
    }

    fn clear(l: *Level) void {
        l.cell = 1;
        l.extent = Bbox.empty;
        l.nx = 0;
        l.ny = 0;
        l.bucket_start.clearRetainingCapacity();
        l.rows.clearRetainingCapacity();
    }

    /// The inclusive cell rectangle `b` occupies, or null when its extent is
    /// outside this level's `min_ext..=cell`.
    fn footprint(l: *const Level, b: Bbox) ?[4]u32 {
        const ext = boxExtent(b);
        if (ext < l.min_ext or ext > l.cell) return null;
        const c = cellSpan(b.xlo, b.xhi, l.extent.xlo, l.cell, l.nx);
        const r = cellSpan(b.ylo, b.yhi, l.extent.ylo, l.cell, l.ny);
        return .{ c[0], c[1], r[0], r[1] };
    }

    /// Files every member box under every cell it overlaps.
    fn build(l: *Level, gpa: Allocator, bboxes: []const Bbox, first_row: u32, extent: Bbox, cell: i64, min_ext: i64) Allocator.Error!void {
        l.clear();
        l.cell = cell;
        l.extent = extent;
        l.min_ext = min_ext;
        l.nx = axisCells(extent.xhi - extent.xlo + 1, cell);
        l.ny = axisCells(extent.yhi - extent.ylo + 1, cell);
        const nx: usize = l.nx;
        const buckets = nx * l.ny;
        try l.bucket_start.appendNTimes(gpa, 0, buckets + 1);
        const starts = l.bucket_start.items;

        var members: usize = 0;
        for (bboxes) |b| {
            const f = l.footprint(b) orelse continue;
            members += 1;
            for (f[2]..f[3] + 1) |r| for (f[0]..f[1] + 1) |c| {
                starts[r * nx + c + 1] += 1;
            };
        }
        // No members: an absence, not an empty grid.
        if (members == 0) return l.clear();

        for (1..buckets + 1) |k| starts[k] += starts[k - 1];
        try l.rows.resize(gpa, starts[buckets]);
        // `starts[k]` doubles as bucket `k`'s write cursor. Rows are filed
        // ascending, which the `b > a` binary search relies on.
        for (bboxes, first_row..) |b, poly| {
            const f = l.footprint(b) orelse continue;
            for (f[2]..f[3] + 1) |r| for (f[0]..f[1] + 1) |c| {
                const k = r * nx + c;
                l.rows.items[starts[k]] = @intCast(poly);
                starts[k] += 1;
            };
        }
        // Each cursor holds its bucket's end: shift right to restore offsets.
        std.mem.copyBackwards(u32, starts[1..], starts[0..buckets]);
        starts[0] = 0;
        assert(starts[buckets] == l.rows.items.len);
    }

    /// The region one bucket covers, clipped to the extent.
    fn cellBbox(l: *const Level, col: u32, row: u32) Bbox {
        const x = l.extent.xlo + @as(i64, col) * l.cell;
        const y = l.extent.ylo + @as(i64, row) * l.cell;
        return .{ .xlo = x, .ylo = y, .xhi = @min(x + l.cell - 1, l.extent.xhi), .yhi = @min(y + l.cell - 1, l.extent.yhi) };
    }
};

const Same = enum { same, cross };

/// Every pair of polygons on the index's layer whose boxes are within
/// `distance` on both axes (touching at 0), into `out` (cleared and
/// refilled), `a < b`, ascending and deduplicated. `store` must be the one
/// `ix` was built from. Asserts `ix` was built.
pub fn candidatePairsInto(gpa: Allocator, store: *const GeometryStore, ix: *const SpatialIndex, distance: Dbu, out: *std.ArrayList(Pair)) Allocator.Error!void {
    try prunePairs(gpa, store, ix, ix.layer.?, distance, .same, out);
}

/// Every pair between two different layers whose boxes are within
/// `distance`, `a` from `a_layer` and `b` from `b_index`'s layer, into `out`
/// (cleared and refilled), ascending and deduplicated: the same superset
/// contract. Only the `b` side needs an index. Asserts `b_index` was built.
pub fn crossLayerPairsInto(gpa: Allocator, store: *const GeometryStore, a_layer: LayerId, b_index: *const SpatialIndex, distance: Dbu, out: *std.ArrayList(Pair)) Allocator.Error!void {
    assert(b_index.layer != null);
    try prunePairs(gpa, store, b_index, a_layer, distance, .cross, out);
}

// ---- private ----

/// The longer side of a box; decides which level holds it.
fn boxExtent(b: Bbox) i64 {
    return @max(b.xhi - b.xlo, b.yhi - b.ylo);
}

fn divCeil(a: i64, b: i64) i64 {
    return @divFloor(a + b - 1, b);
}

/// Cells along one axis for its inclusive unit count. A wrap would misfile
/// rows, so the count is asserted.
fn axisCells(span: i64, cell: i64) u32 {
    const cells = divCeil(span, cell);
    assert(cells > 0 and cells <= std.math.maxInt(u32));
    return @intCast(cells);
}

/// The cells a coordinate range touches, clamped to the grid (cells past the
/// edge hold nothing, so folding them onto the border loses no row).
fn cellSpan(lo: i64, hi: i64, origin: i64, cell: i64, cells: u32) [2]u32 {
    const last: i64 = cells - 1;
    const a = @min(@divFloor(@max(lo - origin, 0), cell), last);
    const b = @min(@divFloor(@max(hi - origin, 0), cell), last);
    return .{ @intCast(a), @intCast(b) };
}

fn pairLess(_: void, p: Pair, q: Pair) bool {
    return p.key() < q.key();
}

/// Gathers every row `ix` can reach from each row of `layer`, keeps the
/// pairs whose boxes are within `distance`, then sorts and dedups, into
/// `out`. With `.same`, `ix` holds `layer` itself and only `a < b` is
/// emitted. Filtering before the sort is the fast order: the gathered
/// superset is ~100x what survives.
fn prunePairs(gpa: Allocator, store: *const GeometryStore, ix: *const SpatialIndex, layer: LayerId, distance: Dbu, comptime mode: Same, out: *std.ArrayList(Pair)) Allocator.Error!void {
    assert(distance >= 0);
    out.clearRetainingCapacity();
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |row| {
        const a: PolyId = @fromBackingInt(@intCast(row));
        // A row lives in exactly one level, so the two gathers never overlap.
        try gatherLevel(gpa, &ix.fine, distance, a, store.polyBbox(a), mode, out);
        try gatherLevel(gpa, &ix.coarse, distance, a, store.polyBbox(a), mode, out);
    }
    var kept: usize = 0;
    for (out.items) |p| {
        out.items[kept] = p;
        kept += @intFromBool(store.polyBbox(p.a).within(store.polyBbox(p.b), distance));
    }
    out.shrinkRetainingCapacity(kept);
    // A box filed under several cells is gathered several times.
    std.mem.sortUnstable(Pair, out.items, {}, pairLess);
    kept = 0;
    for (out.items) |p| {
        if (kept > 0 and out.items[kept - 1].key() == p.key()) continue;
        out.items[kept] = p;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
    if (builtin.mode == .debug) assertComplete(store, ix.layer.?, layer, distance, mode, out.items);
}

/// On up to 4096 row pairs, the brute-force scan the index exists to avoid:
/// no pair of boxes within `distance` may be missing.
fn assertComplete(store: *const GeometryStore, b_layer: LayerId, a_layer: LayerId, distance: Dbu, comptime mode: Same, pairs: []const Pair) void {
    const ar = store.polysOnLayer(a_layer);
    const br = store.polysOnLayer(b_layer);
    if (@as(u64, ar.len()) * br.len() > 1 << 12) return;
    for (ar.start..ar.end) |a| for (br.start..br.end) |b| {
        if (mode == .same and a >= b) continue;
        const p: Pair = .{ .a = @fromBackingInt(@intCast(a)), .b = @fromBackingInt(@intCast(b)) };
        if (!store.polyBbox(p.a).within(store.polyBbox(p.b), distance)) continue;
        assert(std.sort.binarySearch(Pair, pairs, p, struct {
            fn order(want: Pair, item: Pair) std.math.Order {
                return std.math.order(want.key(), item.key());
            }
        }.order) != null);
    };
}

/// Every row of one level that `a_box` grown by `distance` can reach,
/// appended paired with `a`.
fn gatherLevel(gpa: Allocator, grid: *const Level, distance: Dbu, a: PolyId, a_box: Bbox, comptime mode: Same, out: *std.ArrayList(Pair)) Allocator.Error!void {
    if (grid.rows.items.len == 0) return;
    // Whole cells with `pad > distance`: rounds up (fail closed); the bucket
    // test below takes the slop back out.
    const pad = (@divFloor(distance, grid.cell) + 1) * grid.cell;
    const c = cellSpan(a_box.xlo - pad, a_box.xhi + pad, grid.extent.xlo, grid.cell, grid.nx);
    const r = cellSpan(a_box.ylo - pad, a_box.yhi + pad, grid.extent.ylo, grid.cell, grid.ny);
    for (r[0]..r[1] + 1) |row| for (c[0]..c[1] + 1) |col| {
        if (!grid.cellBbox(@intCast(col), @intCast(row)).within(a_box, distance)) continue;
        const k = row * grid.nx + col;
        const seg = grid.rows.items[grid.bucket_start.items[k]..grid.bucket_start.items[k + 1]];
        // Ascending rows: `b > a` is a suffix, which also drops the self-pair.
        const from = switch (mode) {
            .same => std.sort.partitionPoint(u32, seg, @backingInt(a), struct {
                fn atOrBefore(ra: u32, item: u32) bool {
                    return item <= ra;
                }
            }.atOrBefore),
            .cross => 0,
        };
        try out.ensureUnusedCapacity(gpa, seg.len - from);
        for (seg[from..]) |b| out.appendAssumeCapacity(.{ .a = a, .b = @fromBackingInt(b) });
    };
}

fn mix(v0: u64) u64 {
    var v = v0 +% 0x9E37_79B9_7F4A_7C15;
    v = (v ^ (v >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    v = (v ^ (v >> 27)) *% 0x94D0_49BB_1331_11EB;
    return v ^ (v >> 31);
}

/// Two sizes of square jittered over a lattice of 400-unit cells, two
/// interleaved layers.
fn corpus(gpa: Allocator, seed: u64, cells: u64, store: *GeometryStore) Allocator.Error!void {
    var builder: @import("store.zig").GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    const origins = [2][2]i64{ .{ 0, 0 }, .{ 170, 90 } };
    for (origins, 0..) |o, layer| {
        for (0..cells) |row| for (0..cells) |col| {
            const draw = mix(seed ^ (row << 20) ^ col);
            if (draw & 1 == 0) continue;
            const side: u64 = if (draw & 2 == 0) 80 else 200;
            const room = 400 - side;
            const x: i64 = o[0] + @as(i64, @intCast(col * 400 + (draw >> 8) % room));
            const y: i64 = o[1] + @as(i64, @intCast(row * 400 + (draw >> 30) % room));
            const s: i64 = @intCast(side);
            _ = try builder.push(gpa, @fromBackingInt(@intCast(layer)), &.{ x, x + s, x + s, x }, &.{ y, y, y + s, y + s });
        };
    }
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try builder.finish(gpa, 2, store, &perm);
}

fn allPairs(gpa: Allocator, store: *const GeometryStore, a_layer: LayerId, b_layer: LayerId, distance: Dbu, comptime mode: Same) Allocator.Error!std.ArrayList(Pair) {
    var want: std.ArrayList(Pair) = .empty;
    const ar = store.polysOnLayer(a_layer);
    const br = store.polysOnLayer(b_layer);
    for (ar.start..ar.end) |a| for (br.start..br.end) |b| {
        if (mode == .same and a >= b) continue;
        const p: Pair = .{ .a = @fromBackingInt(@intCast(a)), .b = @fromBackingInt(@intCast(b)) };
        if (store.polyBbox(p.a).within(store.polyBbox(p.b), distance)) try want.append(gpa, p);
    };
    return want;
}

test "same layer pairs equal the all pairs scan" {
    // Oracle: the O(n^2) scan of the exact box predicate, same layer.
    const gpa = std.testing.allocator;
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try corpus(gpa, 92, 12, &store);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, @fromBackingInt(0));
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    for ([_]Dbu{ 0, 25, 250, 2_000 }) |d| {
        try candidatePairsInto(gpa, &store, &ix, d, &out);
        var want = try allPairs(gpa, &store, @fromBackingInt(0), @fromBackingInt(0), d, .same);
        defer want.deinit(gpa);
        try std.testing.expectEqualSlices(Pair, want.items, out.items);
    }
}

test "cross layer pairs equal the all pairs scan" {
    // Oracle: the O(n^2) scan of the exact box predicate, cross layer.
    const gpa = std.testing.allocator;
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try corpus(gpa, 93, 10, &store);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, @fromBackingInt(1));
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    for ([_]Dbu{ 0, 30, 400 }) |d| {
        try crossLayerPairsInto(gpa, &store, @fromBackingInt(0), &ix, d, &out);
        var want = try allPairs(gpa, &store, @fromBackingInt(0), @fromBackingInt(1), d, .cross);
        defer want.deinit(gpa);
        try std.testing.expect(want.items.len > 0);
        try std.testing.expectEqualSlices(Pair, want.items, out.items);
    }
}
