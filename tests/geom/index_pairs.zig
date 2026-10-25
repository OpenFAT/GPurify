//! Candidate-pair generation, from outside the module: the returned list is a
//! superset of the exact predicate, ascending and free of duplicates, and the
//! same list twice. Ported from crates/geom/tests/core/index_pairs.rs.
//!
//! The superset direction is the one that costs correctness: a pair absent
//! from this list is never checked again, so an over-eager prune is a
//! spacing rule silently passing shapes the foundry would reject. A pair
//! wrongly present costs one exact re-check, so the comparison is one-sided.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const shapes = testgen.shapes;
const Rng = testgen.Rng;
const index = geom.index;
const Pair = index.Pair;
const SpatialIndex = index.SpatialIndex;
const Dbu = geom.Dbu;
const GeometryStore = geom.GeometryStore;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;

const gpa = testing.allocator;
const a_layer: u16 = 0;
const b_layer: u16 = 1;
const spec: shapes.RandomLayerSpec = .{ .cells = 16, .cell = 400, .density = 0.4 };

// ---- private ----

fn lid(l: u16) LayerId {
    return @fromBackingInt(l);
}

fn pid(r: usize) PolyId {
    return @fromBackingInt(@intCast(r));
}

fn key(p: Pair) u64 {
    return @as(u64, @backingInt(p.a)) << 32 | @backingInt(p.b);
}

fn contains(pairs: []const Pair, p: Pair) bool {
    for (pairs) |q| if (key(q) == key(p)) return true;
    return false;
}

fn strictlyAscending(pairs: []const Pair) bool {
    for (pairs[0..pairs.len -| 1], pairs[@min(1, pairs.len)..]) |p, q| if (key(p) >= key(q)) return false;
    return true;
}

/// The exact predicate the prune may approximate, as an O(n²) scan: two
/// boxes within `distance` on both axes, inclusive. `a < b` on one layer.
fn allPairs(store: *const GeometryStore, la: u16, lb: u16, distance: Dbu) !std.ArrayList(Pair) {
    var out: std.ArrayList(Pair) = .empty;
    errdefer out.deinit(gpa);
    const ar = store.polysOnLayer(lid(la));
    const br = store.polysOnLayer(lid(lb));
    for (ar.start..ar.end) |a| for (br.start..br.end) |b| {
        if (la == lb and a >= b) continue;
        if (store.polyBbox(pid(a)).within(store.polyBbox(pid(b)), distance)) try out.append(gpa, .{ .a = pid(a), .b = pid(b) });
    };
    return out;
}

/// A layer of squares at a known density, plus a second layer offset from
/// it so the cross-layer pairs are non-trivial.
fn twoLayers(seed: u64, store: *GeometryStore) !void {
    var rng = Rng.init(seed);
    var lb: shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    _ = try shapes.randomRectilinearLayer(&lb, gpa, &rng, a_layer, .{ 0, 0 }, spec);
    _ = try shapes.randomRectilinearLayer(&lb, gpa, &rng, b_layer, .{ 150, 150 }, spec);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, store, &ids);
}

/// The candidate pairs at 150 of a seed-84 random layer placed at `origin`.
fn translated(origin: [2]i64, s: shapes.RandomLayerSpec) !std.ArrayList(Pair) {
    var lb: shapes.LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    var rng = Rng.init(84);
    _ = try shapes.randomRectilinearLayer(&lb, gpa, &rng, a_layer, origin, s);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, lid(a_layer));
    var out: std.ArrayList(Pair) = .empty;
    errdefer out.deinit(gpa);
    try index.candidatePairsInto(gpa, &store, &ix, 150, &out);
    return out;
}

test "every pair within the distance survives the prune" {
    // Oracle: law, against an `O(n²)` scan of the exact predicate. The prune may
    // return extra pairs; it may not lose one. Run across several distances,
    // because the cell size is derived from the geometry and a distance far larger
    // than a cell is where a one-cell search radius stops being enough.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try twoLayers(81, &store);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, lid(a_layer));
    try testing.expect(!ix.isEmpty());
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    for ([_]Dbu{ 0, 1, 5, 60, 400, 1_500 }) |d| {
        try index.candidatePairsInto(gpa, &store, &ix, d, &out);
        var exact = try allPairs(&store, a_layer, a_layer, d);
        defer exact.deinit(gpa);
        for (exact.items) |p| try testing.expect(contains(out.items, p));
        try testing.expect(out.items.len >= exact.items.len);
        if (d >= 60) try testing.expect(exact.items.len > 0);
    }
}

test "pairs are ascending deduplicated and ordered the same way twice" {
    // Oracle: law. Pairs come out with `a < b` and in ascending order with no
    // duplicates. That is part of the interface, not a detail: output ordering is
    // gated, and a rule that reported one violation per candidate would report it
    // twice for a duplicated pair.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try twoLayers(82, &store);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, lid(a_layer));
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    try index.candidatePairsInto(gpa, &store, &ix, 250, &out);
    try testing.expect(out.items.len > 0);
    for (out.items) |p| {
        try testing.expect(@backingInt(p.a) < @backingInt(p.b));
        try testing.expectEqual(lid(a_layer), store.polyLayer(p.a));
        try testing.expectEqual(lid(a_layer), store.polyLayer(p.b));
    }
    try testing.expect(strictlyAscending(out.items));
    // The same call into a buffer already holding the answer: refilled.
    const first = try gpa.dupe(Pair, out.items);
    defer gpa.free(first);
    try index.candidatePairsInto(gpa, &store, &ix, 250, &out);
    try testing.expectEqualSlices(Pair, first, out.items);
    // Rebuilding into a reused allocation must not change the answer either.
    var reused: SpatialIndex = .empty;
    defer reused.deinit(gpa);
    try reused.build(gpa, &store, lid(b_layer));
    try reused.build(gpa, &store, lid(a_layer));
    try index.candidatePairsInto(gpa, &store, &reused, 250, &out);
    try testing.expectEqualSlices(Pair, first, out.items);
}

test "a pair at exactly the distance is a candidate" {
    // Oracle: construct-from-answer. Two squares placed an exact gap apart are a
    // candidate at that gap and, since the prune is a superset, still a candidate
    // at anything larger. The generator fixes the geometry, so the answer is known
    // before the index is built.
    var lb: shapes.LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    const pair = try shapes.spacedPair(&lb, gpa, a_layer, .{ 0, 0 }, 40, 100);
    // A third shape far away, so the index has more than one occupied cell.
    const lonely = try lb.rect(gpa, a_layer, 100_000, 100_000, 100_100, 100_100);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    const a = @backingInt(ids.of(pair[0]));
    const b = @backingInt(ids.of(pair[1]));
    const expected: Pair = .{ .a = pid(@min(a, b)), .b = pid(@max(a, b)) };
    const far = @backingInt(ids.of(lonely));
    const e0 = @backingInt(expected.a);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, lid(a_layer));
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    for ([_]Dbu{ 40, 41, 100 }) |d| {
        try index.candidatePairsInto(gpa, &store, &ix, d, &out);
        try testing.expect(contains(out.items, expected));
        try testing.expect(!contains(out.items, .{ .a = pid(@min(e0, far)), .b = pid(@max(e0, far)) }));
    }
    // One unit short of the gap: the exact predicate says no, so the prune may.
    try index.candidatePairsInto(gpa, &store, &ix, 39, &out);
    var exact = try allPairs(&store, a_layer, a_layer, 39);
    defer exact.deinit(gpa);
    for (exact.items) |p| try testing.expect(contains(out.items, p));
}

test "every cross layer pair within the distance survives the prune" {
    // Oracle: law, again against an `O(n²)` scan. Cross-layer pairing is a
    // separate function because it cannot use `a < b` to halve its work, so it is
    // a separate chance to drop a pair — and the pairs it emits must name one
    // polygon from each layer, in that order.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try twoLayers(83, &store);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, lid(b_layer));
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    for ([_]Dbu{ 0, 10, 200, 900 }) |d| {
        try index.crossLayerPairsInto(gpa, &store, lid(a_layer), &ix, d, &out);
        var exact = try allPairs(&store, a_layer, b_layer, d);
        defer exact.deinit(gpa);
        for (exact.items) |p| try testing.expect(contains(out.items, p));
        for (out.items) |p| {
            try testing.expectEqual(lid(a_layer), store.polyLayer(p.a));
            try testing.expectEqual(lid(b_layer), store.polyLayer(p.b));
        }
        try testing.expect(strictlyAscending(out.items));
    }
    try testing.expect(out.items.len > 0);
    // Determinism, into a reused buffer.
    const first = try gpa.dupe(Pair, out.items);
    defer gpa.free(first);
    try index.crossLayerPairsInto(gpa, &store, lid(a_layer), &ix, 900, &out);
    try testing.expectEqualSlices(Pair, first, out.items);
}

test "an empty or single polygon layer yields no pairs" {
    // Oracle: construct-from-answer. A layer with no geometry indexes to an empty
    // index and yields no pairs, and a layer with one polygon yields none either —
    // there is no pair to make. Both must be answers rather than errors, because a
    // PDK's layer table is mostly empty layers.
    var lb: shapes.LayoutBuilder = .init(3);
    defer lb.deinit(gpa);
    const low = try lb.rect(gpa, a_layer, 0, 0, 10, 10);
    const high = try lb.rect(gpa, a_layer, 5, 5, 15, 15);
    _ = try lb.rect(gpa, b_layer, 0, 0, 10, 10);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);

    var empty: SpatialIndex = .empty;
    defer empty.deinit(gpa);
    try empty.build(gpa, &store, lid(2));
    try testing.expect(empty.isEmpty());
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, .{ .a = pid(9), .b = pid(9) });
    try index.candidatePairsInto(gpa, &store, &empty, 1_000, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    var single: SpatialIndex = .empty;
    defer single.deinit(gpa);
    try single.build(gpa, &store, lid(b_layer));
    try testing.expect(!single.isEmpty());
    try index.candidatePairsInto(gpa, &store, &single, 1_000, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // The occupied layer produces its one pair, named, not counted: a prune
    // emitting one pair of the wrong two polygons satisfies a count.
    var occupied: SpatialIndex = .empty;
    defer occupied.deinit(gpa);
    try occupied.build(gpa, &store, lid(a_layer));
    try index.candidatePairsInto(gpa, &store, &occupied, 0, &out);
    const a = @backingInt(ids.of(low));
    const b = @backingInt(ids.of(high));
    try testing.expectEqualSlices(Pair, &.{.{ .a = pid(@min(a, b)), .b = pid(@max(a, b)) }}, out.items);

    // A cross-layer query against the empty index is empty from either side.
    try index.crossLayerPairsInto(gpa, &store, lid(a_layer), &empty, 1_000, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try index.crossLayerPairsInto(gpa, &store, lid(2), &occupied, 1_000, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the candidate list is invariant under translation of every shape" {
    // Oracle: law. Candidate pairing is a statement about relative positions, so
    // translating every shape translates nothing about which pairs are candidates.
    // A uniform translation preserves the store's row order, so the pair list
    // comes back identical outright.
    const s: shapes.RandomLayerSpec = .{ .cells = 12, .cell = 300, .density = 0.5 };
    var base = try translated(.{ 0, 0 }, s);
    defer base.deinit(gpa);
    try testing.expect(base.items.len > 0);
    var rng = Rng.init(84);
    for (0..6) |_| {
        const ox = rng.range(-400_000, 400_000);
        var moved = try translated(.{ ox, rng.range(-400_000, 400_000) }, s);
        defer moved.deinit(gpa);
        try testing.expectEqualSlices(Pair, base.items, moved.items);
    }
}

test "no candidate pair names one polygon twice or a row of another layer" {
    // Oracle: law. The prune is allowed to be generous but not arbitrary. Every
    // pair it emits names two *distinct* rows of the *queried* layer, and since the
    // list is ascending with `a < b` it cannot be longer than the layer's complete
    // pair count — a list that exceeds that bound is emitting something twice or
    // naming a row it was never given.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    try twoLayers(85, &store);
    var ix: SpatialIndex = .empty;
    defer ix.deinit(gpa);
    try ix.build(gpa, &store, lid(a_layer));
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(gpa);
    try index.candidatePairsInto(gpa, &store, &ix, 100, &out);
    try testing.expect(out.items.len > 0);
    const rows = store.polysOnLayer(lid(a_layer)).len();
    try testing.expect(rows >= 2);
    try testing.expect(out.items.len <= rows * (rows - 1) / 2);
    for (out.items) |p| {
        try testing.expect(p.a != p.b);
        try testing.expectEqual(lid(a_layer), store.polyLayer(p.a));
        try testing.expectEqual(lid(a_layer), store.polyLayer(p.b));
    }
}
