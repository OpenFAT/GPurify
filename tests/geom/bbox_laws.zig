//! Laws and closed forms for `Bbox`, ported from
//! crates/geom/tests/core/bbox_laws.rs.
//!
//! Making `overlaps` strict on one axis once produced zero failures across the
//! Rust suite. The touching cases below are written out on both axes and at
//! the corner for that reason, and the inclusive boundary of `within` is
//! checked on the passing side and one database unit past it. Random draws
//! use `std.Random.DefaultPrng` with the Rust seeds until testgen lands.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const max = geom.max_abs_dbu;

fn bbox(xlo: Dbu, ylo: Dbu, xhi: Dbu, yhi: Dbu) Bbox {
    return .{ .xlo = xlo, .ylo = ylo, .xhi = xhi, .yhi = yhi };
}

/// Arbitrary non-empty boxes, seeded.
fn arbitraryBoxes(comptime count: usize, seed: u64) [count]Bbox {
    var p = std.Random.DefaultPrng.init(seed);
    const r = p.random();
    var out: [count]Bbox = undefined;
    for (&out) |*b| {
        const x0 = r.intRangeLessThan(Dbu, -10_000, 10_000);
        const x1 = r.intRangeLessThan(Dbu, -10_000, 10_000);
        const y0 = r.intRangeLessThan(Dbu, -10_000, 10_000);
        const y1 = r.intRangeLessThan(Dbu, -10_000, 10_000);
        b.* = bbox(@min(x0, x1), @min(y0, y1), @max(x0, x1), @max(y0, y1));
    }
    return out;
}

test "empty is the identity of union" {
    // Oracle: law. The identity element of a fold is a property of the operation,
    // so it must hold against every box rather than against a chosen one.
    try testing.expect(Bbox.empty.isEmpty());
    for (arbitraryBoxes(256, 1)) |b| {
        try testing.expectEqual(b, Bbox.empty.merge(b));
        try testing.expectEqual(b, b.merge(Bbox.empty));
    }
    try testing.expectEqual(Bbox.empty, Bbox.empty.merge(Bbox.empty));
}

test "union is a commutative associative idempotent join" {
    // Oracle: law. Union is a join: commutative, associative, idempotent, and
    // monotone. An implementation that mixed up a `min` and a `max` on one axis
    // breaks commutativity or containment here whichever way it leans.
    const boxes = arbitraryBoxes(64, 2);
    for (boxes, 0..) |a, i| {
        try testing.expectEqual(a, a.merge(a));
        for (boxes[i + 1 ..]) |b| {
            const ab = a.merge(b);
            try testing.expectEqual(ab, b.merge(a));
            try testing.expect(ab.contains(a) and ab.contains(b));
            for (boxes[0..4]) |c| try testing.expectEqual(ab.merge(c), a.merge(b.merge(c)));
        }
    }
}

test "a point on the coordinate domain edge folds exactly" {
    // Oracle: closed form. `EMPTY` is built from `±MAX_ABS_DBU`, and its doc
    // comment claims that dominates the coordinate domain *with equality*. A
    // sentinel one unit inside the domain would silently drop the extreme point.
    const top = Bbox.empty.include(max, max);
    try testing.expectEqual(Bbox.point(max, max), top);
    try testing.expect(!top.isEmpty());
    const whole = top.include(-max, -max);
    try testing.expectEqual(bbox(-max, -max, max, max), whole);
    // The bound exists so this product fits `i128`: (2 * 2^40)^2 = 2^82.
    try testing.expectEqual(@as(geom.DbuArea, 1 << 82), whole.area());
}

test "include folds a run of points the same way of_points does" {
    // Oracle: law. `include` is `union` against a degenerate box, so folding a run
    // of points one at a time must agree with unioning their singleton boxes — and
    // with `Bbox::of_points`.
    var p = std.Random.DefaultPrng.init(3);
    const r = p.random();
    var xs: [40]Dbu = undefined;
    var ys: [40]Dbu = undefined;
    for (1..41) |run| {
        for (xs[0..run], ys[0..run]) |*x, *y| {
            x.* = r.intRangeLessThan(Dbu, -5_000, 5_000);
            y.* = r.intRangeLessThan(Dbu, -5_000, 5_000);
        }
        var folded = Bbox.empty;
        for (xs[0..run], ys[0..run]) |x, y| {
            folded = folded.include(x, y);
            try testing.expectEqual(folded, folded.merge(Bbox.point(x, y)));
        }
        try testing.expectEqual(folded, Bbox.ofPoints(xs[0..run], ys[0..run]));
    }
    try testing.expectEqual(Bbox.empty, Bbox.ofPoints(&.{}, &.{}));
}

test "a point and a segment are zero area but not empty" {
    // Oracle: law. Emptiness is `lo > hi`, which is a strictly different claim
    // from zero area: a point and a segment are both zero-area and both contain
    // points.
    const point = Bbox.point(7, -3);
    try testing.expect(!point.isEmpty());
    try testing.expectEqual(0, point.area());
    try testing.expectEqual(0, point.width());
    try testing.expectEqual(0, point.height());

    const horizontal = bbox(0, 5, 10, 5);
    const vertical = bbox(5, 0, 5, 10);
    for ([_]Bbox{ horizontal, vertical }) |degenerate| {
        try testing.expect(!degenerate.isEmpty());
        try testing.expectEqual(0, degenerate.area());
    }
    try testing.expectEqual(10, horizontal.width());
    try testing.expectEqual(0, horizontal.height());
    try testing.expectEqual(0, vertical.width());
    try testing.expectEqual(10, vertical.height());

    try testing.expect(Bbox.empty.isEmpty());
    // Empty on one axis only is still empty; the predicate is a disjunction.
    try testing.expect(bbox(10, 0, 0, 10).isEmpty());
    try testing.expect(bbox(0, 10, 10, 0).isEmpty());
}

test "boxes sharing only an edge or a corner overlap" {
    // Oracle: construct-from-answer. Two boxes sharing only an edge share a line
    // of points, so they overlap. This is the exact mutation that survived the
    // whole previous suite, which is why every edge and the corner are written out.
    const a = bbox(0, 0, 10, 10);
    try testing.expect(a.overlaps(bbox(10, 0, 20, 10)));
    try testing.expect(a.overlaps(bbox(-10, 0, 0, 10)));
    try testing.expect(a.overlaps(bbox(0, 10, 10, 20)));
    try testing.expect(a.overlaps(bbox(0, -10, 10, 0)));
    try testing.expect(a.overlaps(bbox(10, 10, 20, 20)));
    try testing.expect(a.overlaps(bbox(-10, -10, 0, 0)));
    // One database unit further out on either axis and they genuinely miss.
    try testing.expect(!a.overlaps(bbox(11, 0, 20, 10)));
    try testing.expect(!a.overlaps(bbox(0, 11, 10, 20)));
    try testing.expect(!a.overlaps(bbox(11, 11, 20, 20)));
    try testing.expect(!a.overlaps(Bbox.empty));
    try testing.expect(!Bbox.empty.overlaps(a));
}

test "within is inclusive at exactly the stated distance" {
    // Oracle: construct-from-answer. `within` is the spacing-rule prune, and the
    // only failure that matters is rejecting a pair at exactly the limit. Both
    // axes, both sides of the boundary, plus distance zero is `overlaps`.
    const a = bbox(0, 0, 10, 10);
    const right = bbox(15, 0, 25, 10);
    try testing.expect(a.within(right, 5));
    try testing.expect(!a.within(right, 4));
    const above = bbox(0, 15, 10, 25);
    try testing.expect(above.within(a, 5));
    try testing.expect(!a.within(above, 4));
    // Diagonal separation is per-axis, not Euclidean: both axes must be within.
    const diagonal = bbox(15, 15, 25, 25);
    try testing.expect(a.within(diagonal, 5));
    try testing.expect(!a.within(diagonal, 4));
    try testing.expect(a.within(bbox(10, 0, 20, 10), 0));
    try testing.expect(!a.within(bbox(11, 0, 20, 10), 0));
}

test "within is monotone in distance and agrees with overlaps at zero" {
    // Oracle: law. `within` is monotone in its distance and agrees with
    // `overlaps` at zero, for any pair.
    const boxes = arbitraryBoxes(48, 4);
    for (boxes, 0..) |a, i| {
        for (boxes[i + 1 ..]) |b| {
            try testing.expectEqual(a.overlaps(b), a.within(b, 0));
            var previous = a.within(b, 0);
            for (1..64) |d| {
                const distance: Dbu = @intCast(d);
                const now = a.within(b, distance);
                try testing.expect(now or !previous);
                try testing.expectEqual(now, b.within(a, distance));
                previous = now;
            }
        }
    }
}

test "overlaps contains and intersection agree on every pair" {
    // Oracle: law. Three predicates describe the same relation from three angles,
    // so they must agree on every input: an intersection exists precisely when the
    // boxes overlap, it is contained in both, and containment implies the
    // intersection is the contained box.
    const boxes = arbitraryBoxes(96, 5);
    for (boxes, 0..) |a, i| {
        try testing.expect(a.contains(a));
        try testing.expectEqual(a, a.intersection(a).?);
        for (boxes[i + 1 ..]) |b| {
            const meet = a.intersection(b);
            try testing.expectEqual(a.overlaps(b), meet != null);
            try testing.expectEqual(meet, b.intersection(a));
            if (meet) |m| {
                try testing.expect(!m.isEmpty());
                try testing.expect(a.contains(m) and b.contains(m));
                try testing.expect(a.merge(b).contains(m));
            }
            if (a.contains(b)) {
                try testing.expectEqual(b, a.intersection(b).?);
                try testing.expect(a.overlaps(b));
                try testing.expectEqual(a, a.merge(b));
            }
        }
    }
}

test "width height and area are the closed form of the bounds" {
    // Oracle: closed form. Width, height and area of an inclusive box are
    // differences of its own bounds, and area is the product taken in `i128`
    // because the `i64` product would wrap at the coordinate domain's edge.
    const cases = [_][4]Dbu{ .{ 0, 0, 10, 5 }, .{ -40, -40, -10, -30 }, .{ -1_000_000, 7, 1_000_000, 9 }, .{ 3, 3, 3, 3 } };
    for (cases) |c| {
        const b = bbox(c[0], c[1], c[2], c[3]);
        try testing.expectEqual(c[2] - c[0], b.width());
        try testing.expectEqual(c[3] - c[1], b.height());
        try testing.expectEqual(@as(geom.DbuArea, c[2] - c[0]) * (c[3] - c[1]), b.area());
    }
}

test "of_points is translation equivariant and area preserving" {
    // Oracle: law. A bounding box is defined by its extremes, so translating every
    // input translates the box and leaves its area alone.
    var p = std.Random.DefaultPrng.init(6);
    const r = p.random();
    var xs: [27]Dbu = undefined;
    var ys: [27]Dbu = undefined;
    var xs_moved: [27]Dbu = undefined;
    var ys_moved: [27]Dbu = undefined;
    for (0..64) |_| {
        const run = 3 + r.uintLessThan(usize, 24);
        const dx = r.intRangeLessThan(Dbu, -500_000, 500_000);
        const dy = r.intRangeLessThan(Dbu, -500_000, 500_000);
        for (xs[0..run], ys[0..run], xs_moved[0..run], ys_moved[0..run]) |*x, *y, *xm, *ym| {
            x.* = r.intRangeLessThan(Dbu, -100_000, 100_000);
            y.* = r.intRangeLessThan(Dbu, -100_000, 100_000);
            xm.* = x.* + dx;
            ym.* = y.* + dy;
        }
        const here = Bbox.ofPoints(xs[0..run], ys[0..run]);
        const there = Bbox.ofPoints(xs_moved[0..run], ys_moved[0..run]);
        try testing.expectEqual(here.area(), there.area());
        try testing.expectEqual(here.width(), there.width());
        try testing.expectEqual(here.height(), there.height());
        try testing.expectEqual(bbox(here.xlo + dx, here.ylo + dy, here.xhi + dx, here.yhi + dy), there);
    }
}

test "every empty box covers no area in both profiles" {
    // Oracle: construct-from-answer, on the sentinel rather than on a shape. An
    // empty box contains no points, so it covers no area. `EMPTY` inverts both
    // spans, and two negatives multiply back to `+2^82`; a box empty on one axis
    // only comes out negative unless clamped.
    try testing.expectEqual(0, Bbox.empty.area());
    for ([_]Bbox{ bbox(10, 0, -10, 20), bbox(0, 10, 20, -10) }) |empty| {
        try testing.expect(empty.isEmpty());
        try testing.expectEqual(0, empty.area());
    }
    // One point folded into the sentinel is a point, not an empty box.
    const edge = Bbox.empty.include(max, max);
    try testing.expect(!edge.isEmpty());
    try testing.expectEqual(0, edge.area());
}
