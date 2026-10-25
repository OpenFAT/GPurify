//! The store's one structural invariant: rows are grouped by layer, and the
//! permutation `finish` returns is the map back to the order they arrived
//! in. Ported from crates/geom/tests/core/store_layout.rs.
//!
//! `ingest` permutes its provenance columns by that permutation. Nothing in
//! the type system holds the two tables together, so if the permutation is
//! wrong a violation is reported against the wrong cell of the wrong
//! instance and every geometric assertion in the tree still passes.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const shapes = testgen.shapes;
const Rng = testgen.Rng;
const Bbox = geom.Bbox;
const GeometryStore = geom.GeometryStore;
const GeometryStoreBuilder = geom.GeometryStoreBuilder;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;

const gpa = testing.allocator;
const layers = 5;

/// One arrival: its layer and its open run.
const Arrival = struct { layer: u16, xs: []const i64, ys: []const i64 };

const r0 = shapes.rect(0, 0, 10, 10);
const r1 = shapes.rect(100, 100, 140, 130);
const l2 = shapes.lShape(50, 50, 40, 12);
const u_3 = shapes.uShape(-200, -200, 60, 10, 20);
const r4 = shapes.rect(-10, -10, -5, -5);
const r5 = shapes.rect(7, -300, 27, -280);
const r6 = shapes.rect(1_000, 1_000, 1_010, 1_040);
const r7 = shapes.rect(-1_000, 500, -900, 600);

/// The shapes every test here builds from, in arrival order: layers
/// interleaved, layer 2 left with no geometry, and a shape on the last
/// layer so the trailing offset is not the easy case.
const arrivals = [_]Arrival{
    .{ .layer = 3, .xs = &r0[0], .ys = &r0[1] },
    .{ .layer = 0, .xs = &r1[0], .ys = &r1[1] },
    .{ .layer = 3, .xs = &l2[0], .ys = &l2[1] },
    .{ .layer = 0, .xs = &u_3[0], .ys = &u_3[1] },
    .{ .layer = 4, .xs = &r4[0], .ys = &r4[1] },
    .{ .layer = 0, .xs = &r5[0], .ys = &r5[1] },
    .{ .layer = 3, .xs = &r6[0], .ys = &r6[1] },
    .{ .layer = 1, .xs = &r7[0], .ys = &r7[1] },
};

// ---- private ----

fn layerId(l: u16) LayerId {
    return @fromBackingInt(l);
}

fn polyId(r: usize) PolyId {
    return @fromBackingInt(@intCast(r));
}

fn build(store: *GeometryStore, permutation: *std.ArrayList(u32)) !void {
    var builder: GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    for (arrivals, 0..) |a, row| {
        // `push` returns the pre-sort row index.
        try testing.expectEqual(@as(u32, @intCast(row)), try builder.push(gpa, layerId(a.layer), a.xs, a.ys));
    }
    try builder.finish(gpa, layers, store, permutation);
}

fn expectRing(store: *const GeometryStore, id: PolyId, xs: []const i64, ys: []const i64) !void {
    const r = store.polyVerts(id);
    try testing.expectEqualSlices(i64, xs, r.xs);
    try testing.expectEqualSlices(i64, ys, r.ys);
}

test "the permutation maps every sorted row back to the row it arrived as" {
    // Oracle: construct-from-answer. The test knows which layer each shape was
    // pushed onto and in what order, so it knows what the permutation must say.
    // `permutation[new_row] == old_row` is the contract `ingest` relies on, and it
    // is checked here against the arrival list rather than against the store.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var permutation: std.ArrayList(u32) = .empty;
    defer permutation.deinit(gpa);
    try build(&store, &permutation);
    try testing.expectEqual(@as(u32, arrivals.len), store.polyCount());
    try testing.expectEqual(@as(u32, layers), store.layerCount());
    // A permutation, not merely a map: every arrival row appears exactly once.
    var seen: [arrivals.len]u32 = undefined;
    @memcpy(&seen, permutation.items);
    std.mem.sortUnstable(u32, &seen, {}, std.sort.asc(u32));
    for (seen, 0..) |s, i| try testing.expectEqual(@as(u32, @intCast(i)), s);
    for (permutation.items, 0..) |old, new| {
        const a = arrivals[old];
        try testing.expectEqual(layerId(a.layer), store.polyLayer(polyId(new)));
        try expectRing(&store, polyId(new), a.xs, a.ys);
    }
}

test "layer ranges partition every row and an empty layer is an empty range" {
    // Oracle: law. The layer offsets are CSR, so the ranges must be consecutive,
    // must cover every row exactly once, and must agree row for row with
    // `poly_layer`. A layer with no geometry is an empty range in the middle of
    // that chain, not a gap and not an error.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var permutation: std.ArrayList(u32) = .empty;
    defer permutation.deinit(gpa);
    try build(&store, &permutation);
    var boundary: u32 = 0;
    for (0..layers) |l| {
        const range = store.polysOnLayer(layerId(@intCast(l)));
        try testing.expectEqual(boundary, range.start);
        try testing.expect(range.end >= range.start);
        for (range.start..range.end) |row| try testing.expectEqual(layerId(@intCast(l)), store.polyLayer(polyId(row)));
        boundary = range.end;
    }
    try testing.expectEqual(store.polyCount(), boundary);
    // Layer 2 was never pushed onto. It has to answer with an empty range so a
    // rule naming it reports no violations rather than failing to find it.
    try testing.expectEqual(@as(u32, 0), store.polysOnLayer(layerId(2)).len());
    try testing.expectEqual(@as(usize, 0), store.layerBboxes(layerId(2)).len);
    // Counts by layer, from the arrival list.
    for ([_][2]u32{ .{ 0, 3 }, .{ 1, 1 }, .{ 2, 0 }, .{ 3, 3 }, .{ 4, 1 } }) |c| {
        try testing.expectEqual(c[1], store.polysOnLayer(layerId(@intCast(c[0]))).len());
    }
}

test "every bounding box is the box of that polygons own vertices" {
    // Oracle: law. A polygon's precomputed bounding box is by definition the fold
    // of `include` over that polygon's own vertices and nothing else, and
    // `layer_bboxes` is exactly the column slice covered by the layer's range. Two
    // derived views of one column agreeing is what stops the offset arithmetic
    // drifting.
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var permutation: std.ArrayList(u32) = .empty;
    defer permutation.deinit(gpa);
    try build(&store, &permutation);
    for (0..store.polyCount()) |row| {
        const r = store.polyVerts(polyId(row));
        try testing.expectEqual(Bbox.ofPoints(r.xs, r.ys), store.polyBbox(polyId(row)));
    }
    for (0..layers) |l| {
        const range = store.polysOnLayer(layerId(@intCast(l)));
        const column = store.layerBboxes(layerId(@intCast(l)));
        try testing.expectEqual(@as(usize, range.len()), column.len);
        for (column, range.start..) |b, row| try testing.expectEqual(store.polyBbox(polyId(row)), b);
    }
}

test "two builds of the same pushes agree on every column" {
    // Oracle: determinism. The store is the input to every downstream verdict, so
    // two builds of the same pushes must agree on the permutation, the layer
    // column, the coordinate columns and the bounding boxes. Pre-sizing is an
    // allocation decision and must not be a semantic one, so the second build uses
    // `with_capacity` and the third the default.
    var vertices: usize = 0;
    for (arrivals) |a| vertices += a.xs.len;
    var sized: GeometryStoreBuilder = .empty;
    defer sized.deinit(gpa);
    try sized.ensureUnusedCapacity(gpa, arrivals.len, vertices);
    for (arrivals) |a| _ = try sized.push(gpa, layerId(a.layer), a.xs, a.ys);
    var sized_store: GeometryStore = .empty;
    defer sized_store.deinit(gpa);
    var sized_perm: std.ArrayList(u32) = .empty;
    defer sized_perm.deinit(gpa);
    try sized.finish(gpa, layers, &sized_store, &sized_perm);

    var first: GeometryStore = .empty;
    defer first.deinit(gpa);
    var first_perm: std.ArrayList(u32) = .empty;
    defer first_perm.deinit(gpa);
    try build(&first, &first_perm);
    var second: GeometryStore = .empty;
    defer second.deinit(gpa);
    var second_perm: std.ArrayList(u32) = .empty;
    defer second_perm.deinit(gpa);
    try build(&second, &second_perm);

    try testing.expectEqualSlices(u32, first_perm.items, second_perm.items);
    try testing.expectEqualSlices(u32, first_perm.items, sized_perm.items);
    for ([_]*const GeometryStore{ &second, &sized_store }) |s| {
        try testing.expectEqual(first.polyCount(), s.polyCount());
        try testing.expectEqual(first.layerCount(), s.layerCount());
        for (0..first.polyCount()) |row| {
            const id = polyId(row);
            try testing.expectEqual(first.polyLayer(id), s.polyLayer(id));
            try testing.expectEqual(first.polyBbox(id), s.polyBbox(id));
            const want = first.polyVerts(id);
            try expectRing(s, id, want.xs, want.ys);
        }
    }
}

test "regrouping by layer loses no row and invents none" {
    // Oracle: law. Sorting by layer regroups rows and must not lose, duplicate or
    // relabel one: the arrival rows a layer's range names are exactly the arrivals
    // that were pushed onto that layer. Over four hundred generated shapes, so it
    // is a property of the sort rather than of the eight-row fixture above.
    // Membership only; the order within a layer is the determinism test's.
    var rng = Rng.init(31);
    var builder: GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    var arrivals_of: [layers]std.ArrayList(u32) = @splat(.empty);
    defer for (&arrivals_of) |*a| a.deinit(gpa);
    for (0..400) |arrival| {
        const layer: u16 = @intCast(rng.below(5));
        const x = rng.range(-50_000, 50_000);
        const y = rng.range(-50_000, 50_000);
        const w = rng.range(1, 500);
        const h = rng.range(1, 500);
        const s = shapes.rect(x, y, x + w, y + h);
        _ = try builder.push(gpa, layerId(layer), &s[0], &s[1]);
        try arrivals_of[layer].append(gpa, @intCast(arrival));
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var permutation: std.ArrayList(u32) = .empty;
    defer permutation.deinit(gpa);
    try builder.finish(gpa, layers, &store, &permutation);
    for (arrivals_of, 0..) |expected, l| {
        const range = store.polysOnLayer(layerId(@intCast(l)));
        const found = try gpa.dupe(u32, permutation.items[range.start..range.end]);
        defer gpa.free(found);
        std.mem.sortUnstable(u32, found, {}, std.sort.asc(u32));
        try testing.expectEqualSlices(u32, expected.items, found);
    }
}

test "handles resolve to the rows holding the geometry they were pushed with" {
    // Oracle: construct-from-answer. `LayoutBuilder` is how every other test in
    // the suite names a shape it deliberately made wrong, and it names it by
    // inverting this permutation. If the two disagree, every construct-from-answer
    // test in the workspace is asserting against the wrong polygon.
    var lb: shapes.LayoutBuilder = .init(layers);
    defer lb.deinit(gpa);
    var handles: [arrivals.len]shapes.Handle = undefined;
    for (arrivals, &handles) |a, *h| h.* = try lb.push(gpa, a.layer, a.xs, a.ys);
    try testing.expectEqual(@as(u32, 8), lb.pushed);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    for (arrivals, handles) |a, h| {
        try testing.expectEqual(layerId(a.layer), store.polyLayer(ids.of(h)));
        try expectRing(&store, ids.of(h), a.xs, a.ys);
    }
}

test "a polygon contains the points on its boundary as well as its interior" {
    // Oracle: construct-from-answer, on a shape whose inside and outside this test
    // states rather than derives. `poly_contains_point` is boundary-inclusive:
    // GDSII fixes no relationship between a `TEXT` and a shape, and every
    // established convention (KLayout: "inside or on the edge of") treats an
    // on-edge label as attached. The slanted edge is the case worth having:
    // `point_seg_dist2` rounds an oblique distance away from zero, so a
    // `dist2 == 0` test would never fire for a point genuinely on such an edge.
    var lb: shapes.LayoutBuilder = .init(layers);
    defer lb.deinit(gpa);
    // A right triangle: (0,0) -> (400,0) -> (0,400).
    const triangle = try lb.push(gpa, 0, &.{ 0, 400, 0 }, &.{ 0, 0, 400 });
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    const poly = ids.of(triangle);
    // Well inside, the three vertices, the midpoints of the horizontal,
    // vertical and slanted edges, and another point on the slanted edge.
    for ([_][2]i64{ .{ 100, 100 }, .{ 0, 0 }, .{ 400, 0 }, .{ 0, 400 }, .{ 200, 0 }, .{ 0, 200 }, .{ 200, 200 }, .{ 100, 300 } }) |p| {
        try testing.expect(store.polyContainsPoint(poly, shapes.point(p[0], p[1])));
    }
    // Just outside the slanted edge, left of the vertical, below the
    // horizontal, the box corner the triangle does not reach, far away.
    for ([_][2]i64{ .{ 201, 200 }, .{ -1, 100 }, .{ 100, -1 }, .{ 400, 400 }, .{ 5000, 5000 } }) |p| {
        try testing.expect(!store.polyContainsPoint(poly, shapes.point(p[0], p[1])));
    }
}

test "appended rings and edges land on their own layer" {
    // Oracle: construct-from-answer. Two rings appended after `finish` to an
    // empty layer become that layer's rows, after every row already stored,
    // with the vertices and boxes they were given; the layer after it stays
    // empty. Segments appended to the last layer come back from it and from no
    // other.
    var builder: GeometryStoreBuilder = .empty;
    defer builder.deinit(gpa);
    const base = shapes.rect(0, 0, 10, 10);
    _ = try builder.push(gpa, layerId(0), &base[0], &base[1]);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var permutation: std.ArrayList(u32) = .empty;
    defer permutation.deinit(gpa);
    try builder.finish(gpa, 3, &store, &permutation);

    // A box at `xs[0..4]` and a triangle at `xs[4..7]`.
    const xs = [_]i64{ 20, 30, 30, 20, 40, 50, 40 };
    const ys = [_]i64{ 0, 0, 5, 5, 0, 0, 8 };
    try store.appendLayer(gpa, layerId(1), &xs, &ys, &.{ 0, 4 }, &.{ 4, 3 });
    try testing.expectEqual(@as(u32, 3), store.polyCount());
    try testing.expectEqual(geom.store.Rows{ .start = 1, .end = 3 }, store.polysOnLayer(layerId(1)));
    try testing.expectEqual(geom.store.Rows{ .start = 3, .end = 3 }, store.polysOnLayer(layerId(2)));
    try testing.expectEqual(layerId(1), store.polyLayer(polyId(1)));
    try expectRing(&store, polyId(2), xs[4..], ys[4..]);
    try testing.expectEqual(Bbox{ .xlo = 40, .ylo = 0, .xhi = 50, .yhi = 8 }, store.polyBbox(polyId(2)));

    const edge: geom.Seg = .{ .a = shapes.point(0, 0), .b = shapes.point(10, 0) };
    try store.appendEdges(gpa, layerId(2), &.{edge});
    try testing.expectEqualSlices(geom.Seg, &.{edge}, store.edgesOnLayer(layerId(2)));
    try testing.expectEqual(@as(usize, 0), store.edgesOnLayer(layerId(1)).len);
}
