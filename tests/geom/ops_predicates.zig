//! Exact predicates: segment intersection, point-in-ring, simplicity, signed
//! area, distances and the integer square root. Ported from
//! crates/geom/tests/core/ops_predicates.rs.
//!
//! The previous implementation's mutation survivors were all degenerate
//! cases, so the cases here are degenerate on purpose: collinear triples,
//! shared endpoints, overlapping collinear segments, points exactly on a
//! boundary, and perfect squares with their immediate neighbours.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const testgen = @import("testgen");
const shapes = testgen.shapes;
const Rng = testgen.Rng;
const ops = geom.ops;
const Seg = geom.Seg;
const Point = geom.Point;
const DbuArea = geom.DbuArea;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const point = shapes.point;
const max = geom.max_abs_dbu;

const gpa = testing.allocator;

/// One shape on layer zero, validated; the store outlives the layer.
const Validated = struct {
    store: GeometryStore = .empty,
    layer: ValidatedLayer = .empty,

    fn init(s: anytype) !Validated {
        var v: Validated = .{};
        errdefer v.deinit();
        var lb: shapes.LayoutBuilder = .init(1);
        defer lb.deinit(gpa);
        _ = try lb.shape(gpa, 0, s);
        var ids: shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &v.store, &ids);
        try testing.expectEqual(null, try geom.view.validateLayer(gpa, &v.store, @fromBackingInt(0), .rectilinear, &v.layer));
        return v;
    }

    fn deinit(v: *Validated) void {
        v.store.deinit(gpa);
        v.layer.deinit(gpa);
    }
};

// ---- private ----

fn seg(ax: i64, ay: i64, bx: i64, by: i64) Seg {
    return .{ .a = point(ax, ay), .b = point(bx, by) };
}

fn flip(s: Seg) Seg {
    return .{ .a = s.b, .b = s.a };
}

/// Twice the signed area by the shoelace formula in `i128`, computed here
/// and not read back out of the code under test.
fn shoelace(xs: []const i64, ys: []const i64) i128 {
    var twice: i128 = 0;
    for (0..xs.len) |i| {
        const j = (i + 1) % xs.len;
        twice += @as(i128, xs[i]) * ys[j] - @as(i128, xs[j]) * ys[i];
    }
    return twice;
}

fn drawSeg(rng: *Rng, lo: i64, hi: i64) Seg {
    const ax = rng.range(lo, hi);
    const ay = rng.range(lo, hi);
    const bx = rng.range(lo, hi);
    return seg(ax, ay, bx, rng.range(lo, hi));
}

fn inRing(r: geom.Ring, p: Point) bool {
    return ops.pointInRing(r.xs, r.ys, p);
}

test "segments intersect covers endpoints and collinear overlap" {
    // Oracle: construct-from-answer. Shapes in a real layout touch constantly, so
    // the endpoint and collinear cases decide whether a spacing rule sees a pair at
    // all. Each assertion names the configuration it is, and the disjoint cases sit
    // one database unit clear of the touching ones.
    const meet = [_][2]Seg{
        // Proper crossing: the interiors meet at one point.
        .{ seg(0, 0, 10, 10), seg(0, 10, 10, 0) },
        // A shared endpoint, in each of the four ways two endpoints pair up.
        .{ seg(0, 0, 10, 0), seg(10, 0, 10, 10) },
        .{ seg(0, 0, 10, 0), seg(10, 10, 10, 0) },
        .{ seg(10, 0, 0, 0), seg(10, 0, 10, 10) },
        .{ seg(10, 0, 0, 0), seg(10, 10, 10, 0) },
        // T-junction: an endpoint lands in the other segment's interior.
        .{ seg(0, 0, 10, 0), seg(5, 0, 5, 10) },
        .{ seg(5, 0, 5, 10), seg(0, 0, 10, 0) },
        // Collinear, overlapping over a run of points, in every operand order.
        .{ seg(0, 0, 10, 0), seg(5, 0, 15, 0) },
        .{ seg(0, 0, 10, 0), seg(2, 0, 8, 0) },
        .{ seg(2, 0, 8, 0), seg(0, 0, 10, 0) },
        .{ seg(0, 0, 10, 0), seg(15, 0, 5, 0) },
        .{ seg(0, 0, 0, 10), seg(0, 4, 0, 20) },
        // Collinear, meeting at exactly one shared endpoint.
        .{ seg(0, 0, 10, 0), seg(10, 0, 20, 0) },
        // Degenerate segments: a point on the other segment, and on itself.
        .{ seg(5, 0, 5, 0), seg(0, 0, 10, 0) },
        .{ seg(5, 0, 5, 0), seg(5, 0, 5, 0) },
    };
    for (meet) |c| try testing.expect(ops.segmentsIntersect(c[0], c[1]));
    const apart = [_][2]Seg{
        // Collinear and clear by one unit: the boundary that decides the rule.
        .{ seg(0, 0, 10, 0), seg(11, 0, 20, 0) },
        .{ seg(0, 0, 0, 10), seg(0, 11, 0, 20) },
        // Parallel, never meeting.
        .{ seg(0, 0, 10, 0), seg(0, 1, 10, 1) },
        // Skew: the lines cross, but outside both segments.
        .{ seg(0, 0, 4, 4), seg(6, 0, 10, 10) },
        // A point beside a segment, and two distinct points.
        .{ seg(5, 1, 5, 1), seg(0, 0, 10, 0) },
        .{ seg(5, 1, 5, 1), seg(9, 9, 9, 9) },
    };
    for (apart) |c| try testing.expect(!ops.segmentsIntersect(c[0], c[1]));
}

test "segment intersection is symmetric in both operands and both endpoints" {
    // Oracle: law. Sharing a point is symmetric and does not depend on which end
    // of a segment is called `a`, so all four rewritings of a pair agree for
    // arbitrary segments. The old survivors were asymmetric checks that read one
    // operand's endpoints and not the other's.
    var rng = Rng.init(23);
    var met: u32 = 0;
    for (0..600) |_| {
        // A tight range, so collinear and touching cases actually occur.
        const p = drawSeg(&rng, -6, 6);
        const q = drawSeg(&rng, -6, 6);
        const base = ops.segmentsIntersect(p, q);
        met += @intFromBool(base);
        try testing.expectEqual(base, ops.segmentsIntersect(q, p));
        try testing.expectEqual(base, ops.segmentsIntersect(flip(p), q));
        try testing.expectEqual(base, ops.segmentsIntersect(p, flip(q)));
    }
    try testing.expect(met > 0);
}

test "segments touch exactly when their distance is zero" {
    // Oracle: law. Two segments share a point exactly when the distance between
    // them is zero. Two independently written predicates agreeing over arbitrary
    // input is a stronger claim than either agreeing with a fixture.
    var rng = Rng.init(24);
    for (0..600) |_| {
        const p = drawSeg(&rng, -6, 6);
        const q = drawSeg(&rng, -6, 6);
        try testing.expectEqual(ops.segmentsIntersect(p, q), ops.segSegDist2(p, q) == 0);
        try testing.expectEqual(ops.segSegDist2(p, q), ops.segSegDist2(q, p));
    }
}

test "point to segment distance is the perpendicular or the nearer endpoint" {
    // Oracle: closed form. The squared distance from a point to a segment is
    // either the perpendicular drop, when the foot lands inside the segment, or
    // the nearer endpoint. Both branches are written out, plus the degenerate
    // segment where they coincide.
    const base = seg(0, 0, 10, 0);
    const cases = [_]struct { p: Point, want: DbuArea }{
        // Perpendicular foot inside the segment.
        .{ .p = point(5, 10), .want = 100 },
        .{ .p = point(0, 3), .want = 9 },
        .{ .p = point(10, 4), .want = 16 },
        // Foot beyond an endpoint: that endpoint's distance.
        .{ .p = point(-5, 0), .want = 25 },
        .{ .p = point(15, 0), .want = 25 },
        .{ .p = point(-3, 4), .want = 25 },
        .{ .p = point(13, 4), .want = 25 },
    };
    for (cases) |c| try testing.expectEqual(c.want, ops.pointSegDist2(c.p, base));
    // On the segment, both endpoints included.
    for ([_]i64{ 0, 1, 5, 9, 10 }) |x| try testing.expectEqual(@as(DbuArea, 0), ops.pointSegDist2(point(x, 0), base));
    // A degenerate segment is a point.
    const dot = seg(4, 4, 4, 4);
    try testing.expectEqual(@as(DbuArea, 0), ops.pointSegDist2(point(4, 4), dot));
    try testing.expectEqual(@as(DbuArea, 25), ops.pointSegDist2(point(7, 8), dot));
    // A diagonal segment: (2, 6) drops onto y = x at (4, 4), 4 + 4.
    try testing.expectEqual(@as(DbuArea, 8), ops.pointSegDist2(point(2, 6), seg(0, 0, 10, 10)));
}

test "a skew distance past 128 bits is exact and rounds up" {
    // Oracle: hand-derived closed form. The segment `±(3m, 4m)` has `|v|² =
    // 100m²`; from `p = (4n + k, -3n)` the cross product is `-(50n + 8k)m`, so
    // the squared drop is `(50n + 8k)² / 100`: `25n²` exactly at `k = 0`, and
    // `25n² + 8n + 0.64`, rounded up to `25n² + 8n + 1`, at `k = 1`. At `m = n =
    // 2^37` the cross product squared passes `2^158`, past `u128`, so this is
    // the 256-bit division and its rounding.
    const m: i64 = 1 << 37;
    const n: i64 = 1 << 37;
    const slant = seg(-3 * m, -4 * m, 3 * m, 4 * m);
    const n2 = @as(i128, n) * n;
    try testing.expectEqual(25 * n2, ops.pointSegDist2(point(4 * n, -3 * n), slant));
    try testing.expectEqual(25 * n2 + 8 * @as(i128, n) + 1, ops.pointSegDist2(point(4 * n + 1, -3 * n), slant));
}

test "segment distance is bounded by its endpoint distances" {
    // Oracle: closed form for the parallel and collinear cases, law for the rest.
    // Segment distance is bounded above by the distance from any of the four
    // endpoints to the other segment, which pins it without stating an answer.
    // Two parallel horizontal segments three apart; two collinear four apart;
    // perpendicular, nearest between an endpoint and an interior.
    try testing.expectEqual(@as(DbuArea, 9), ops.segSegDist2(seg(0, 0, 10, 0), seg(0, 3, 10, 3)));
    try testing.expectEqual(@as(DbuArea, 16), ops.segSegDist2(seg(0, 0, 10, 0), seg(14, 0, 20, 0)));
    try testing.expectEqual(@as(DbuArea, 36), ops.segSegDist2(seg(0, 0, 10, 0), seg(5, 6, 5, 20)));
    var rng = Rng.init(25);
    for (0..400) |_| {
        const p = drawSeg(&rng, -20, 20);
        const q = drawSeg(&rng, -20, 20);
        const d = ops.segSegDist2(p, q);
        for ([_]Point{ p.a, p.b }) |probe| try testing.expect(d <= ops.pointSegDist2(probe, q));
        for ([_]Point{ q.a, q.b }) |probe| try testing.expect(d <= ops.pointSegDist2(probe, p));
    }
}

test "isqrt is exact at perfect squares and rounds toward zero beside them" {
    // Oracle: closed form. `isqrt` rounds toward zero, so its defining boundary is
    // a perfect square and the values either side of it. An off-by-one here broke
    // three tests in the old tree and still survived a mutation, so the sweep runs
    // over every square up to a thousand and then over the domain's far end.
    for (0..1_001) |k| {
        const n: i64 = @intCast(k);
        const square = @as(i128, n) * n;
        try testing.expectEqual(n, ops.isqrt(square));
        // From n == 1 up, n² ± 1 lie strictly between neighbouring squares.
        if (n > 0) {
            try testing.expectEqual(n - 1, ops.isqrt(square - 1));
            try testing.expectEqual(n, ops.isqrt(square + 1));
        }
    }
    // max_abs_dbu squared is the largest area two legal coordinates make, and
    // its root comes back exact rather than saturating.
    const m: i128 = max;
    try testing.expectEqual(max, ops.isqrt(m * m));
    try testing.expectEqual(max - 1, ops.isqrt(m * m - 1));
}

test "isqrt satisfies its defining inequality for arbitrary values" {
    // Oracle: law. The integer square root is defined by
    // `r * r <= v < (r + 1) * (r + 1)`, which is checkable against any value
    // without knowing the answer beforehand. The values are products of two legal
    // coordinates, which is the only way an area is produced anywhere in the tree.
    var rng = Rng.init(26);
    for (0..2_000) |_| {
        const a = rng.range(0, max);
        const value = @as(i128, a) * rng.range(0, max);
        // The floor of the root, by bisection over the integers.
        var low: i64 = 0;
        var high: i64 = max + 1;
        while (low + 1 < high) {
            const mid = low + @divTrunc(high - low, 2);
            if (@as(i128, mid) * mid <= value) low = mid else high = mid;
        }
        try testing.expectEqual(low, ops.isqrt(value));
    }
}

test "area2 is twice the polygon area and flips sign with winding" {
    // Oracle: closed form. Shoelace over a run the test wrote, doubled, against
    // the areas the generator states as formulas in its own doc comments. The
    // generator's tests prove those formulas; this proves `area2` agrees with them
    // and that reversing a run negates the result.
    const Case = struct { xs: []const i64, ys: []const i64, area: i128 };
    const a = shapes.rect(0, 0, 10, 5);
    const b = shapes.rect(-30, -30, -10, -10);
    const l = shapes.lShape(0, 0, 100, 30);
    const p = shapes.plusShape(11, -7, 50, 2);
    const u = shapes.uShape(4, 4, 100, 20, 40);
    const cases = [_]Case{
        .{ .xs = &a[0], .ys = &a[1], .area = 50 },
        .{ .xs = &b[0], .ys = &b[1], .area = 400 },
        .{ .xs = &l[0], .ys = &l[1], .area = shapes.lShapeArea(100, 30) },
        .{ .xs = &p[0], .ys = &p[1], .area = shapes.plusShapeArea(50, 2) },
        .{ .xs = &u[0], .ys = &u[1], .area = shapes.uShapeArea(100, 20, 40) },
    };
    for (cases) |c| {
        try testing.expectEqual(2 * c.area, ops.area2(c.xs, c.ys));
        try testing.expectEqual(shoelace(c.xs, c.ys), ops.area2(c.xs, c.ys));
        try testing.expectEqual(ops.Winding.ccw, ops.windingOf(c.xs, c.ys).?);
        var rx: [12]i64 = undefined;
        var ry: [12]i64 = undefined;
        for (c.xs, c.ys, 0..) |x, y, i| {
            rx[c.xs.len - 1 - i] = x;
            ry[c.xs.len - 1 - i] = y;
        }
        try testing.expectEqual(-2 * c.area, ops.area2(rx[0..c.xs.len], ry[0..c.xs.len]));
        try testing.expectEqual(ops.Winding.cw, ops.windingOf(rx[0..c.xs.len], ry[0..c.xs.len]).?);
    }
}

test "area2 is invariant under translation and rotation of the start vertex" {
    // Oracle: law. Signed area is a property of the region, so it survives a
    // translation and a change of start vertex. Winding follows its sign for the
    // same reason, and a run enclosing nothing has no winding at all.
    var rng = Rng.init(27);
    for (0..48) |_| {
        const arm = rng.range(20, 400);
        const thickness = rng.range(1, arm);
        const x0 = rng.range(-1_000, 1_000);
        const s = shapes.lShape(x0, rng.range(-1_000, 1_000), arm, thickness);
        const expected = 2 * shapes.lShapeArea(arm, thickness);
        try testing.expectEqual(expected, ops.area2(&s[0], &s[1]));
        const dx = rng.range(-100_000, 100_000);
        const dy = rng.range(-100_000, 100_000);
        var moved = s;
        for (&moved[0]) |*x| x.* += dx;
        for (&moved[1]) |*y| y.* += dy;
        try testing.expectEqual(expected, ops.area2(&moved[0], &moved[1]));
        try testing.expectEqual(ops.windingOf(&s[0], &s[1]), ops.windingOf(&moved[0], &moved[1]));
        for (1..6) |start| {
            var r = s;
            std.mem.rotate(i64, &r[0], start);
            std.mem.rotate(i64, &r[1], start);
            try testing.expectEqual(expected, ops.area2(&r[0], &r[1]));
        }
    }
    // Runs enclosing nothing: three collinear points, and a path that retraces
    // itself. Zero signed area is not clockwise and not counter-clockwise.
    try testing.expectEqual(@as(DbuArea, 0), ops.area2(&.{ 0, 10, 20 }, &.{ 0, 0, 0 }));
    try testing.expectEqual(null, ops.windingOf(&.{ 0, 10, 20 }, &.{ 0, 0, 0 }));
    try testing.expectEqual(@as(DbuArea, 0), ops.area2(&.{ 0, 10, 20, 10 }, &.{ 0, 0, 0, 0 }));
    try testing.expectEqual(null, ops.windingOf(&.{ 0, 10, 20, 10 }, &.{ 0, 0, 0, 0 }));
}

test "self intersects finds a crossing and accepts every generated shape" {
    // Oracle: construct-from-answer. A bowtie is the canonical crossing run and a
    // pinched rectangle is its rectilinear equivalent, while every shape the
    // generator emits is simple by construction. Adjacent edges share an endpoint
    // and the closing edge shares two, and neither of those is a crossing.
    const si = geom.simple.selfIntersects;
    try testing.expect(try si(gpa, &.{ 0, 10, 10, 0 }, &.{ 0, 10, 0, 10 }, .cross));
    // The edge from (10, 10) down to (10, -5) crosses the opening edge from
    // (0, 0) to (20, 0) at (10, 0), interior to both.
    try testing.expect(try si(gpa, &.{ 0, 20, 20, 10, 10, 30, 30, 0 }, &.{ 0, 0, 10, 10, -5, -5, 20, 20 }, .cross));
    const r = shapes.rect(0, 0, 10, 5);
    const l = shapes.lShape(0, 0, 100, 30);
    const p = shapes.plusShape(0, 0, 50, 2);
    const u = shapes.uShape(0, 0, 100, 20, 40);
    try testing.expect(!try si(gpa, &r[0], &r[1], .cross));
    try testing.expect(!try si(gpa, &l[0], &l[1], .cross));
    try testing.expect(!try si(gpa, &p[0], &p[1], .cross));
    try testing.expect(!try si(gpa, &u[0], &u[1], .cross));
    // A triangle is not rectilinear, but simplicity is a separate question.
    try testing.expect(!try si(gpa, &.{ 0, 10, 5 }, &.{ 0, 0, 9 }, .cross));
}

test "point in ring includes the boundary and excludes the reflex notch" {
    // Oracle: construct-from-answer. A via landing exactly on a conductor edge is
    // connected, so the boundary counts as inside. The L is the shape whose
    // bounding box lies about it: the square from (30, 30) to (100, 100) is inside
    // the box and outside the polygon, so an implementation measuring the box
    // passes on rectangles and fails here.
    var v = try Validated.init(shapes.lShape(0, 0, 100, 30));
    defer v.deinit();
    const ring = v.layer.get(0).outer();
    for ([_][2]i64{ .{ 50, 15 }, .{ 15, 50 }, .{ 15, 15 }, .{ 29, 29 } }) |q| try testing.expect(inRing(ring, point(q[0], q[1])));
    // An edge midpoint on each of the six edges, a convex and a reflex vertex.
    for ([_][2]i64{ .{ 50, 0 }, .{ 100, 15 }, .{ 65, 30 }, .{ 30, 65 }, .{ 15, 100 }, .{ 0, 50 }, .{ 0, 0 }, .{ 30, 30 } }) |q| {
        try testing.expect(inRing(ring, point(q[0], q[1])));
    }
    // The notch a bounding box would wrongly claim, and points clear of the L.
    for ([_][2]i64{ .{ 60, 60 }, .{ 99, 99 }, .{ 31, 31 }, .{ 50, 31 }, .{ -1, 50 }, .{ 101, 15 }, .{ 15, 101 }, .{ 50, -1 } }) |q| {
        try testing.expect(!inRing(ring, point(q[0], q[1])));
    }
}

test "point in ring is invariant under translation" {
    // Oracle: law. Membership is a property of the region, so translating the ring
    // and the probe together cannot change the answer — for a probe inside, one
    // outside, or one exactly on the boundary. The U's notch means the probe grid
    // lands in all three.
    var rng = Rng.init(28);
    var probes: [200][2]i64 = undefined;
    for (&probes) |*q| {
        const x = rng.range(-20, 100);
        q.* = .{ x, rng.range(-20, 120) };
    }
    var here = try Validated.init(shapes.uShape(0, 0, 100, 20, 40));
    defer here.deinit();
    const here_ring = here.layer.get(0).outer();
    var agreed_inside: u32 = 0;
    for (0..8) |_| {
        const dx = rng.range(-500_000, 500_000);
        const dy = rng.range(-500_000, 500_000);
        var there = try Validated.init(shapes.uShape(dx, dy, 100, 20, 40));
        defer there.deinit();
        const there_ring = there.layer.get(0).outer();
        for (probes) |q| {
            const in_here = inRing(here_ring, point(q[0], q[1]));
            try testing.expectEqual(in_here, inRing(there_ring, point(q[0] + dx, q[1] + dy)));
            agreed_inside += @intFromBool(in_here);
        }
    }
    try testing.expect(agreed_inside > 0);
}
