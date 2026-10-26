//! Geometry at any size whose net partition is known by construction, so
//! one corpus serves both a benchmark and an assertion. In: a `ScaleSpec`.
//! Out: a `ScaleCorpus`. A comb per net (a rail on layer 0, `fingers` stubs
//! on layer 1, a cut per stub on layer 2), nets in disjoint y bands and
//! blocks in disjoint regions placed by recursively quartering a region
//! with the gap scaled by level. Ported from crates/testgen/src/scale.rs.
//!
//! Contents:
//! - `pub const ScaleSpec = struct`, `pub const ScaleCorpus = struct`, `ScaleCorpus.deinit(c: *ScaleCorpus, gpa: Allocator) void`
//! - `pub fn scaleCorpus(gpa: Allocator, spec: ScaleSpec) Allocator.Error!ScaleCorpus`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const Connectivity = @import("ingest").deck.Connectivity;
const shapes = @import("shapes.zig");
const Handle = shapes.Handle;
const Rng = @import("rng.zig").Rng;

/// How big a corpus to build.
pub const ScaleSpec = struct {
    /// Fixes the whole corpus: one seed, one store, byte for byte.
    seed: u64,
    /// Total polygons, rounded down to what whole combs express.
    polygons: u32,
    /// Electrically distinct nets, one comb each.
    nets: u32,
    /// Levels of block nesting, one or more.
    hierarchy_depth: u8,
};

/// A corpus and everything known about it without running anything. The
/// expectation slices live in `arena`, the store in the caller's `gpa`.
pub const ScaleCorpus = struct {
    arena: std.heap.ArenaAllocator,
    store: GeometryStore,
    /// Rails and fingers conduct, cuts join them, touching does not.
    connectivity: Connectivity,
    /// Every conductor polygon on net `n`, ascending (cuts are no
    /// conductor and are not listed).
    expected_net_polys: []const []const PolyId,
    /// Polygons emitted, cuts included: `nets * (1 + 2 * fingers)`.
    polygons: u32,

    pub fn deinit(c: *ScaleCorpus, gpa: Allocator) void {
        c.store.deinit(gpa);
        c.arena.deinit();
    }
};

/// Rails, fingers and cuts.
const lower: u16 = 0;

const upper: u16 = 1;

const cut: u16 = 2;

const rail_height: i64 = 200;

/// Exceeds the rail plus the finger height, so no band reaches the next.
const band_pitch: i64 = 1_000;

const finger_width: i64 = 120;

const finger_pitch: i64 = 400;

/// Leaves clearance to the band above: 200 + 600 against 1000.
const finger_height: i64 = 600;

/// Small enough to sit inside the rail-and-finger overlap.
const cut_size: i64 = 80;

/// Gap between adjacent leaf blocks at the innermost level.
const block_gap: i64 = 4_000;

/// Builds the corpus `spec` describes. `fingers = (polygons / nets - 1) /
/// 2`. Nets are dealt round-robin over `4^(depth - 1)` leaf blocks, then
/// shuffled, so a net's index says nothing about where it lies. Asserts
/// `nets > 0`, `hierarchy_depth > 0` and `polygons >= 3 * nets`.
pub fn scaleCorpus(gpa: Allocator, spec: ScaleSpec) Allocator.Error!ScaleCorpus {
    assert(spec.nets > 0 and spec.hierarchy_depth > 0 and spec.polygons >= 3 * spec.nets);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const fingers = (spec.polygons / spec.nets - 1) / 2;
    var rng = Rng.init(spec.seed);
    const blocks = std.math.pow(u32, 4, spec.hierarchy_depth - 1);
    const bands = std.math.divCeil(u32, spec.nets, blocks) catch unreachable;
    // The block side covers the taller axis: the rail with its fingers, and
    // the whole band stack (sized on one alone, a stack overruns into the
    // block above, where a cut bridges two combs).
    const block_side = @max(@as(i64, fingers + 1) * finger_pitch, @as(i64, bands) * band_pitch);
    var origins: std.ArrayList([2]i64) = .empty;
    _ = try tile(a, spec.hierarchy_depth, block_side, block_gap, &origins);
    assert(origins.items.len == blocks);
    const block_of_net = try a.alloc(u32, spec.nets);
    for (block_of_net, 0..) |*b, n| b.* = @intCast(n % blocks);
    rng.shuffle(u32, block_of_net);
    var lb = shapes.LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const band_in_block = try a.alloc(i64, blocks);
    @memset(band_in_block, 0);
    const net_handles = try a.alloc([]Handle, spec.nets);
    for (block_of_net, net_handles) |block, *handles| {
        const o = origins.items[block];
        const y = o[1] + band_in_block[block] * band_pitch;
        band_in_block[block] += 1;
        handles.* = try a.alloc(Handle, fingers + 1);
        const rail_width = @as(i64, fingers) * finger_pitch + finger_width;
        handles.*[0] = try lb.rect(gpa, lower, o[0], y, o[0] + rail_width, y + rail_height);
        for (0..fingers) |f| {
            const x = o[0] + @as(i64, @intCast(f)) * finger_pitch;
            handles.*[f + 1] = try lb.rect(gpa, upper, x, y, x + finger_width, y + finger_height);
            const cx = x + @divTrunc(finger_width, 2) - @divTrunc(cut_size, 2);
            const cy = y + @divTrunc(rail_height, 2) - @divTrunc(cut_size, 2);
            _ = try lb.rect(gpa, cut, cx, cy, cx + cut_size, cy + cut_size);
        }
    }
    var store: GeometryStore = .empty;
    errdefer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    const expected = try a.alloc([]const PolyId, spec.nets);
    for (expected, net_handles) |*e, handles| {
        const rows = try a.alloc(PolyId, handles.len);
        for (rows, handles) |*r, h| r.* = ids.of(h);
        std.mem.sortUnstable(PolyId, rows, {}, lessPoly);
        e.* = rows;
    }
    const conductors = try a.dupe(LayerId, &.{ @fromBackingInt(lower), @fromBackingInt(upper) });
    const via_cut = try a.dupe(LayerId, &.{@fromBackingInt(cut)});
    const via_connects = try a.dupe([2]LayerId, &.{.{ @fromBackingInt(lower), @fromBackingInt(upper) }});
    return .{
        .arena = arena,
        .store = store,
        .connectivity = .{ .conductors = conductors, .via_cut = via_cut, .via_connects = via_connects, .intra_layer_touch = false },
        .expected_net_polys = expected,
        .polygons = lb.pushed,
    };
}

// ---- private ----

fn lessPoly(_: void, x: PolyId, y: PolyId) bool {
    return @backingInt(x) < @backingInt(y);
}

/// Recursively quarters a region: appends every leaf origin to `out` and
/// returns the region's side.
fn tile(arena: Allocator, depth: u8, leaf: i64, pad: i64, out: *std.ArrayList([2]i64)) Allocator.Error!i64 {
    if (depth <= 1) {
        try out.append(arena, .{ 0, 0 });
        return leaf;
    }
    var inner_origins: std.ArrayList([2]i64) = .empty;
    const inner = try tile(arena, depth - 1, leaf, pad, &inner_origins);
    const step = inner + pad * depth;
    for (0..2) |qy| for (0..2) |qx| for (inner_origins.items) |o| {
        try out.append(arena, .{ o[0] + @as(i64, @intCast(qx)) * step, o[1] + @as(i64, @intCast(qy)) * step });
    };
    return inner + step;
}

test "tiling depth gives four to the power of its levels" {
    // Oracle: closed form. Each level below the first quarters every
    // region, so depth `d` has `4^(d-1)` leaves.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (1..6) |depth| {
        var origins: std.ArrayList([2]i64) = .empty;
        _ = try tile(arena.allocator(), @intCast(depth), 1_000, 100, &origins);
        try std.testing.expectEqual(std.math.pow(usize, 4, depth - 1), origins.items.len);
    }
}

test "leaves are distinct and inside the reported extent" {
    // Oracle: law. Leaf origins are distinct, and each leaf, `leaf` on a
    // side, lies in `[0, extent]` on both axes.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var origins: std.ArrayList([2]i64) = .empty;
    const leaf = 1_000;
    const extent = try tile(arena.allocator(), 4, leaf, 100, &origins);
    for (origins.items, 0..) |o, i| {
        try std.testing.expect(o[0] >= 0 and o[1] >= 0 and o[0] + leaf <= extent and o[1] + leaf <= extent);
        for (origins.items[i + 1 ..]) |q| try std.testing.expect(o[0] != q[0] or o[1] != q[1]);
    }
}

test "no two leaves overlap" {
    // Oracle: law. Two squares of side `leaf` are disjoint when their
    // origins differ by at least `leaf` on one axis, for every pair.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var origins: std.ArrayList([2]i64) = .empty;
    const leaf = 500;
    _ = try tile(arena.allocator(), 3, leaf, 80, &origins);
    for (origins.items, 0..) |o, i| for (origins.items[i + 1 ..]) |q| {
        try std.testing.expect(@abs(q[0] - o[0]) >= leaf or @abs(q[1] - o[1]) >= leaf);
    };
}
