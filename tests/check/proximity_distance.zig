//! The pair-distance row kernel from outside the module: the capped path
//! against the exact one, the body against a scalar oracle, and thread
//! partitions against one thread. Ported from the in-file tests of
//! crates/check/src/drc/rules/mod.rs (`capped_distances_agree_with_poly_dist2`,
//! `capped_dist2_simd_matches_scalar`, the SIMD-vs-scalar oracle becoming
//! body-vs-scalar), plus the thread-partition law.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const check = @import("check");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const Pair = geom.index.Pair;
const dist = check.proximity_distance;
const gap_cap = dist.gap_cap;
const pairDistancesInto = dist.pairDistancesInto;
const cappedDist2 = dist.cappedDist2;
const cappedDistancesCpu = dist.cappedDistancesCpu;
const segBbox = check.rects.segBbox;

/// Rust's in-file xorshift, so the corpus is the one its tests drew from.
const TestRng = struct {
    state: u64,

    fn below(r: *TestRng, n: i64) i64 {
        r.state ^= r.state << 13;
        r.state ^= r.state >> 7;
        r.state ^= r.state << 17;
        return @intCast(r.state % @abs(n));
    }

    fn coord(r: *TestRng, centre: i64, spread: i64) Dbu {
        return std.math.clamp(centre + r.below(2 * spread + 1) - spread, -geom.max_abs_dbu, geom.max_abs_dbu);
    }

    /// A closed ring of `n` vertices, every edge axis-aligned (it may
    /// self-cross or double back): moves alternate in x and y, and the last
    /// vertex shares a coordinate with the first.
    fn rectRing(r: *TestRng, n: usize, c: [2]i64, spread: i64, xs: []i64, ys: []i64) void {
        for (0..n) |i| {
            if (i == 0) {
                xs[0] = r.coord(c[0], spread);
                ys[0] = r.coord(c[1], spread);
            } else if (i % 2 == 1) {
                xs[i] = r.coord(c[0], spread);
                ys[i] = ys[i - 1];
            } else {
                xs[i] = xs[i - 1];
                ys[i] = r.coord(c[1], spread);
            }
        }
        if (n >= 2) {
            if ((n - 1) % 2 == 1) xs[n - 1] = xs[0] else ys[n - 1] = ys[0];
        }
    }

    fn freeRing(r: *TestRng, n: usize, c: [2]i64, spread: i64, xs: []i64, ys: []i64) void {
        for (xs[0..n], ys[0..n]) |*x, *y| {
            x.* = r.coord(c[0], spread);
            y.* = r.coord(c[1], spread);
        }
    }
};

// ---- private ----

fn testStore(gpa: Allocator, rings: []const [2][]const i64, store: *GeometryStore) !void {
    var b: geom.GeometryStoreBuilder = .empty;
    defer b.deinit(gpa);
    for (rings) |r| _ = try b.push(gpa, @fromBackingInt(0), r[0], r[1]);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try b.finish(gpa, 1, store, &perm);
}

test "capped distances agree with polyDist2" {
    // Oracle: differential against the exact i128 path (`gap_cap` itself as
    // the limit): equal below `gap_cap²`, never under it above, over random
    // rectilinear and free rings; non-rectilinear pairs fall back.
    const gpa = std.testing.allocator;
    var r: TestRng = .{ .state = 0x2545_f491_4f6c_dd1d };
    const cap2 = @as(DbuArea, gap_cap) * gap_cap;
    var xs: [6][14]i64 = undefined;
    var ys: [6][14]i64 = undefined;
    var pairs: [15]Pair = undefined;
    var n_pairs: usize = 0;
    for (0..6) |a| for (a + 1..6) |b| {
        pairs[n_pairs] = .{ .a = @fromBackingInt(@intCast(a)), .b = @fromBackingInt(@intCast(b)) };
        n_pairs += 1;
    };
    var exact: std.ArrayList(DbuArea) = .empty;
    defer exact.deinit(gpa);
    var capped: std.ArrayList(DbuArea) = .empty;
    defer capped.deinit(gpa);
    for (0..400) |round| {
        const spreads = [_]i64{ 10, 1_000, gap_cap, geom.max_abs_dbu };
        const spread = spreads[round % 4];
        const centre: i64 = if (round % 7 == 0) geom.max_abs_dbu - 5 else 0;
        var rings: [6][2][]const i64 = undefined;
        for (&rings, 0..) |*ring, k| {
            const c = [2]i64{ r.coord(centre, spread), r.coord(0, spread) };
            const n: usize = if (r.below(3) == 0) blk: {
                const n = 3 + @as(usize, @intCast(r.below(5)));
                r.freeRing(n, c, @divTrunc(spread, 4) + 1, &xs[k], &ys[k]);
                break :blk n;
            } else blk: {
                const n = 2 * (1 + @as(usize, @intCast(r.below(7))));
                r.rectRing(n, c, @divTrunc(spread, 4) + 1, &xs[k], &ys[k]);
                break :blk n;
            };
            ring.* = .{ xs[k][0..n], ys[k][0..n] };
        }
        var store: GeometryStore = .empty;
        defer store.deinit(gpa);
        try testStore(gpa, &rings, &store);
        try pairDistancesInto(gpa, .cpu, null, &store, pairs[0..n_pairs], gap_cap, &exact);
        try pairDistancesInto(gpa, .cpu, null, &store, pairs[0..n_pairs], gap_cap - 1, &capped);
        for (exact.items, capped.items) |e, c| {
            if (e < cap2) try std.testing.expectEqual(e, c) else try std.testing.expect(c >= cap2);
        }
    }
}

test "the row kernel body matches its scalar oracle at every edge count" {
    // Oracle: differential against a scalar loop over every edge pair's
    // boxes, clamped per axis, at every edge count 0 to 13 on either side;
    // and, below `gap_cap²`, against the exact `ops.segSegDist2` minimum.
    const gpa = std.testing.allocator;
    var r: TestRng = .{ .state = 0x9e37_79b9_7f4a_7c15 };
    var xs: [2][13]i64 = undefined;
    var ys: [2][13]i64 = undefined;
    for (0..14) |n| for (0..14) |m| for ([_]i64{ 3, gap_cap, geom.max_abs_dbu }) |spread| {
        r.rectRing(n, .{ 0, 0 }, spread, &xs[0], &ys[0]);
        r.rectRing(m, .{ 0, 0 }, spread, &xs[1], &ys[1]);
        var store: GeometryStore = .empty;
        defer store.deinit(gpa);
        try testStore(gpa, &.{ .{ xs[0][0..n], ys[0][0..n] }, .{ xs[1][0..m], ys[1][0..m] } }, &store);
        const got = cappedDist2(0, 1, store.poly_vert_start.items, store.poly_vert_len.items, store.verts_x.items, store.verts_y.items);
        var want: i64 = std.math.maxInt(i64);
        var exact: DbuArea = std.math.maxInt(DbuArea);
        for (0..n) |i| for (0..m) |j| {
            const p = geom.ops.ringEdge(xs[0][0..n], ys[0][0..n], i);
            const q = geom.ops.ringEdge(xs[1][0..m], ys[1][0..m], j);
            const pb = segBbox(p);
            const qb = segBbox(q);
            const gx = std.math.clamp(@max(pb.xlo, qb.xlo) - @min(pb.xhi, qb.xhi), 0, gap_cap);
            const gy = std.math.clamp(@max(pb.ylo, qb.ylo) - @min(pb.yhi, qb.yhi), 0, gap_cap);
            want = @min(want, gx * gx + gy * gy);
            exact = @min(exact, geom.ops.segSegDist2(p, q));
        };
        try std.testing.expectEqual(want, got);
        if (exact < @as(DbuArea, gap_cap) * gap_cap) try std.testing.expectEqual(exact, @as(DbuArea, got));
    };
}

test "threaded blocks give the bits one thread gives" {
    // Oracle: law. Each pair's distance depends on that pair alone, so any
    // block partition gives the same column: 1 thread against 8, at sizes 0,
    // 1, block - 1, block, and 3 * block + 1 (block = 1024 pairs a thread).
    const gpa = std.testing.allocator;
    var r: TestRng = .{ .state = 0x1234_5678_9abc_def1 };
    var coords: [64][2][8]i64 = undefined;
    var rings: [64][2][]const i64 = undefined;
    for (&rings, &coords) |*ring, *c| {
        r.rectRing(8, .{ r.coord(0, 5000), r.coord(0, 5000) }, 300, &c[0], &c[1]);
        ring.* = .{ &c[0], &c[1] };
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try testStore(gpa, &rings, &store);
    const pairs = try gpa.alloc(Pair, 3 * 1024 + 1);
    defer gpa.free(pairs);
    for (pairs, 0..) |*p, i| p.* = .{ .a = @fromBackingInt(@intCast(i % 64)), .b = @fromBackingInt(@intCast((i * 7 + 3) % 64)) };
    const one = try gpa.alloc(i64, pairs.len);
    defer gpa.free(one);
    const many = try gpa.alloc(i64, pairs.len);
    defer gpa.free(many);
    for ([_]usize{ 0, 1, 1023, 1024, 3 * 1024 + 1 }) |n| {
        try cappedDistancesCpu(&store, pairs[0..n], 1, one[0..n]);
        try cappedDistancesCpu(&store, pairs[0..n], 8, many[0..n]);
        try std.testing.expectEqualSlices(i64, one[0..n], many[0..n]);
    }
}

test "a resident store uploads nothing while every call stays on the cpu" {
    // Oracle: the laziness rule (geom/resident.zig): only a call that goes
    // to the GPU uploads, so the CPU backend, and a GPU backend whose
    // threshold the call is under, leave the copy empty; the answers are the
    // per-call path's.
    const gpa = std.testing.allocator;
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try testStore(gpa, &.{ .{ &.{ 0, 10, 10, 0 }, &.{ 0, 0, 10, 10 } }, .{ &.{ 20, 30, 30, 20 }, &.{ 0, 0, 10, 10 } } }, &store);
    const pairs = [_]Pair{.{ .a = @fromBackingInt(0), .b = @fromBackingInt(1) }};
    var resident: geom.ResidentStore = .empty;
    defer resident.deinit();
    var got: std.ArrayList(DbuArea) = .empty;
    defer got.deinit(gpa);
    const under: geom.Device = .{ .backend = .cuda, .min_work = .never, .threads = 2 };
    for ([_]geom.Device{ .cpu, under }) |device| {
        try pairDistancesInto(gpa, device, &resident, &store, &pairs, 100, &got);
        try std.testing.expectEqualSlices(DbuArea, &.{100}, got.items);
        try std.testing.expect(resident.buffer == .cpu);
    }
}
