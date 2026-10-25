//! KLayout's edge-pair relation, exact. In: two directed edges in KLayout's
//! orientation (material right of travel: a GPurify ring reversed), the
//! relation, the metric and the zero-distance mode. Out: the least distance
//! at which the pair is reported, as twice its square, or null when no
//! distance reports it. Ported from crates/geom/src/relation.rs.
//!
//! A port of `EdgeRelationFilter::check` with the default `angle_limit` (90
//! degrees) and no projection bounds, and of `euclidian_near_part_of_edge` /
//! `var_near_part_of_edge` (`dbEdgePairRelations.cc`): each edge is cut to the
//! other's inner side, and a pair holds at a distance `d` when each edge has a
//! stretch of positive length within `d` of the other, Euclidean or measured
//! square to it over its span (projection). KLayout computes that in floating
//! point; here every crossing and distance is exact. On octilinear edges
//! (`pairThreshold2`) every crossing of an axis edge with a 45-degree line is
//! a lattice point; at any other angle (`pairThresholdAny`, Euclidean only)
//! an edge is cut at a rational point and the distance compared in `i256`.
//!
//! Contents:
//! - `pub const Relation = enum { width, space, overlap, inside }`
//! - `pub const Metric = enum { euclidean, projection }`
//! - `pub const Zero = enum { never, when_touching, when_overlapping }`
//! - `pub fn pairThreshold2(relation: Relation, metric: Metric, zero: Zero, a: Seg, b: Seg) ?i128`
//! - `pub fn projectedReach2(relation: Relation, zero: Zero, a: Seg, b: Seg, v: Point) ?i128`
//! - `pub fn pairThresholdAny(relation: Relation, zero: Zero, a: Seg, b: Seg) ?Twice`

const std = @import("std");
const assert = std.debug.assert;
const ops = @import("ops.zig");
const Point = ops.Point;
const Seg = ops.Seg;
const Twice = ops.Twice;

/// Which sides of the two edges face each other (`edge_relation_type`).
pub const Relation = enum {
    /// Two edges of one polygon across its material (`width`).
    width,
    /// Two edges across empty space (`space`, `notch`, `separation`).
    space,
    /// The first edge's polygon around the second's (`enclosing`).
    overlap,
    /// The first edge's polygon inside the second's (`enclosed`, `inside`).
    inside,
};

/// How a distance between two edges is measured.
pub const Metric = enum {
    /// Point to point (`euclidian`).
    euclidean,
    /// Square to the edge, over its span (`projection`).
    projection,
};

/// When a pair at distance 0 is reported (`zero_distance_mode`).
pub const Zero = enum {
    /// Never (`without_touching_edges`).
    never,
    /// Where the edges touch (the default).
    when_touching,
    /// Where collinear edges overlap (`without_touching_corners`).
    when_overlapping,
};

const P = [2]i64;

/// A directed edge, possibly a point.
const E = struct {
    p1: P,
    p2: P,

    fn of(s: Seg) E {
        return .{ .p1 = .{ s.a.x, s.a.y }, .p2 = .{ s.b.x, s.b.y } };
    }

    fn seg(e: E) Seg {
        return .{ .a = pt(e.p1), .b = pt(e.p2) };
    }

    fn swapped(e: E) E {
        return .{ .p1 = e.p2, .p2 = e.p1 };
    }

    fn d(e: E) [2]i128 {
        return .{ e.p2[0] - e.p1[0], e.p2[1] - e.p1[1] };
    }

    fn degenerate(e: E) bool {
        return eqlP(e.p1, e.p2);
    }

    /// `1` left of travel, `-1` right, `0` on the line.
    fn sideOf(e: E, p: P) i32 {
        const v = e.d();
        const c = v[0] * (p[1] - e.p1[1]) - v[1] * (p[0] - e.p1[0]);
        return if (c > 0) 1 else if (c < 0) -1 else 0;
    }

    fn parallel(e: E, o: E) bool {
        const a = e.d();
        const b = o.d();
        return a[0] * b[1] == a[1] * b[0];
    }
};

/// The part of an edge on another's inner side, when it has one: all of it,
/// or the stretch from this end to where it crosses the other's line.
const Part = union(enum) { whole, from: P };

/// `Part` at any angle: the crossing is the rational point `(x / w, y / w)`,
/// `w > 0`.
const PartAny = union(enum) { whole, cut: struct { keep: P, x: i256, y: i256, w: i256 } };

/// The least distance, twice squared, at which KLayout reports the pair
/// `(a, b)` under `relation`, `metric` and `zero` with its default
/// `angle_limit`; null when it never does. A check at `d` reports the pair
/// when the result is below `2·d²`. Both edges octilinear.
pub fn pairThreshold2(relation: Relation, metric: Metric, zero: Zero, a: Seg, b: Seg) ?i128 {
    const f = facing(relation, a, b) orelse return null;
    const second = near(metric, zero, f[0], f[1]) orelse return null;
    const first = near(metric, zero, f[1], f[0]) orelse return null;
    return @max(first, second);
}

/// The least distance, twice squared, at which the part of `b` that
/// `pairThreshold2` reports under projection reaches `v`, a point of `b`:
/// `v` on `a`'s inner side, its foot on `a`. Null when it never does. With
/// `pairThreshold2` this reads whether a reported edge reaches a corner of
/// its polygon (KLayout's `second_edges` meeting at a corner).
pub fn projectedReach2(relation: Relation, zero: Zero, a: Seg, b: Seg, v: Point) ?i128 {
    const o = oriented(relation, .of(a), .of(b));
    const an = o[0];
    const vp: P = .{ v.x, v.y };
    const part = innerPart(zero, an, o[1]) orelse return null;
    if (!ops.segmentsIntersect(part.seg(), (E{ .p1 = vp, .p2 = vp }).seg())) return null;
    const d = an.d();
    const along = sprod(.{ vp[0] - an.p1[0], vp[1] - an.p1[1] }, d);
    if (along < 0 or along > sprod(d, d)) return null;
    return perp2(an, vp);
}

/// `pairThreshold2` under the Euclidean metric at any angle, exact, as a
/// `Twice` (a fraction where a skew edge is involved). On octilinear edges it
/// is `pairThreshold2(...)`, whole.
pub fn pairThresholdAny(relation: Relation, zero: Zero, a: Seg, b: Seg) ?Twice {
    const f = facing(relation, a, b) orelse return null;
    const second = nearAny(zero, f[0], f[1]) orelse return null;
    const first = nearAny(zero, f[1], f[0]) orelse return null;
    return if (first.lessThan(second)) second else first;
}

// ---- private ----

fn pt(p: P) Point {
    return .{ .x = p[0], .y = p[1] };
}

fn eqlP(a: P, b: P) bool {
    return a[0] == b[0] and a[1] == b[1];
}

fn sprod(a: [2]i128, b: [2]i128) i128 {
    return a[0] * b[0] + a[1] * b[1];
}

/// KLayout's `include_zero_flag`.
fn includeZero(zero: Zero, a: E, b: E) bool {
    const s1 = a.sideOf(b.p1);
    const s2 = a.sideOf(b.p2);
    if (s1 == 0 and s2 == 0) return switch (zero) {
        .when_touching => ops.segmentsIntersect(a.seg(), b.seg()),
        // Collinear and sharing a stretch of positive length.
        .when_overlapping => blk: {
            const v = a.d();
            const a1 = sprod(.{ a.p1[0], a.p1[1] }, v);
            const a2 = sprod(.{ a.p2[0], a.p2[1] }, v);
            const b1 = sprod(.{ b.p1[0], b.p1[1] }, v);
            const b2 = sprod(.{ b.p2[0], b.p2[1] }, v);
            break :blk @max(@min(a1, a2), @min(b1, b2)) < @min(@max(a1, a2), @max(b1, b2));
        },
        .never => false,
    };
    if ((s1 == 0 or s2 == 0) and !eqlP(a.p1, b.p2) and !eqlP(a.p2, b.p1)) {
        return zero == .when_touching and ops.segmentsIntersect(a.seg(), b.seg());
    }
    return false;
}

/// Where `g` crosses `e`'s line, on the lattice: an axis edge and a
/// 45-degree line, or a 45-degree edge and an axis line, cross at one.
fn cutPoint(g: E, e: E) P {
    const ed = e.d();
    const gd = g.d();
    assert(ed[0] * gd[1] - ed[1] * gd[0] != 0);
    const wx: i128 = e.p1[0] - g.p1[0];
    const wy: i128 = e.p1[1] - g.p1[1];
    // g.p1 + t·g.d on e's line: t = (w × e.d) / (g.d × e.d).
    return alongLattice(g, wx * ed[1] - wy * ed[0], gd[0] * ed[1] - gd[1] * ed[0]);
}

/// The point `g.p1 + (num / den)·g.d`, which must be a lattice point.
fn alongLattice(g: E, num: i128, den: i128) P {
    const gd = g.d();
    var out: P = undefined;
    for (&out, g.p1, gd) |*o, p, dv| {
        const v = dv * num;
        assert(@rem(v, den) == 0);
        o.* = p + @as(i64, @intCast(@divTrunc(v, den)));
    }
    return out;
}

/// How much of `other` lies on `e`'s inner (right) side, `e`'s line counted
/// in as `includeZero` says; null for none of it.
fn innerEnd(zero: Zero, e: E, other: E) ?Part {
    var s1: i32 = undefined;
    var s2: i32 = undefined;
    if (e.degenerate()) {
        const hit = ops.segmentsIntersect(other.seg(), e.seg());
        s1 = if (hit) 0 else -1;
        s2 = s1;
    } else {
        s1 = e.sideOf(other.p1);
        s2 = e.sideOf(other.p2);
    }
    const thr: i32 = if (includeZero(zero, e, other)) 0 else -1;
    if (s1 > thr and s2 > thr) return null;
    if (s2 > thr) return .{ .from = other.p1 };
    if (s1 > thr) return .{ .from = other.p2 };
    return .whole;
}

/// `other` cut to `e`'s inner side, its kept end first (every reader of the
/// part is blind to its direction); null when nothing of it is there.
fn innerPart(zero: Zero, e: E, other: E) ?E {
    return switch (innerEnd(zero, e, other) orelse return null) {
        .whole => other,
        .from => |end| .{ .p1 = end, .p2 = cutPoint(other, e) },
    };
}

/// Twice the squared Euclidean distance between two edges, either possibly
/// a point.
fn dist2(a: E, b: E) i128 {
    if (a.degenerate() and b.degenerate()) {
        const dx: i128 = a.p1[0] - b.p1[0];
        const dy: i128 = a.p1[1] - b.p1[1];
        return 2 * (dx * dx + dy * dy);
    }
    if (a.degenerate()) return ops.pointSegNear2(pt(a.p1), b.seg()).d2;
    if (b.degenerate()) return ops.pointSegNear2(pt(b.p1), a.seg()).d2;
    return ops.segSegNear2(a.seg(), b.seg()).d2;
}

/// Twice the squared distance of `p` from `e`'s line, square to it.
fn perp2(e: E, p: P) i128 {
    const v = e.d();
    const sx: i128 = std.math.sign(v[0]);
    const sy: i128 = std.math.sign(v[1]);
    // On the octilinear grid `e.d` is a whole multiple of (sx, sy).
    const c = sx * (p[1] - e.p1[1]) - sy * (p[0] - e.p1[0]);
    return @divTrunc(2 * c * c, sx * sx + sy * sy);
}

/// The least `d` (twice squared) at which `other` has a near part against
/// `e` under `metric`: a stretch of positive length on `e`'s inner side,
/// within `d` of `e` (Euclidean), or within `d` square to `e`'s line over
/// `e`'s span (projection); a single point only where the cut leaves one.
fn near(metric: Metric, zero: Zero, e: E, other: E) ?i128 {
    const g = innerPart(zero, e, other) orelse return null;
    switch (metric) {
        .euclidean => return dist2(e, g),
        .projection => {},
    }
    const v = e.d();
    const span = sprod(v, v);
    const a1 = sprod(.{ g.p1[0] - e.p1[0], g.p1[1] - e.p1[1] }, v);
    const a2 = sprod(.{ g.p2[0] - e.p1[0], g.p2[1] - e.p1[1] }, v);
    if (g.degenerate()) return if (a1 >= 0 and a1 <= span) perp2(e, g.p1) else null;
    if (e.parallel(g)) {
        const lo = @max(@min(a1, a2), 0);
        const hi = @min(@max(a1, a2), span);
        return if (lo < hi) perp2(e, g.p1) else null;
    }
    // `g` square to `e` (the angle test excluded it before here).
    if (a1 == a2) return null;
    if (@max(@min(a1, a2), 0) >= @min(@max(a1, a2), span)) return null;
    // The stretch of `g` whose foot falls on `e` ends where along(t) is 0 or
    // `span`, lattice points.
    return @min(perp2(e, footAt(g, a1, a2, 0)), perp2(e, footAt(g, a1, a2, span)));
}

/// The point of `g` whose foot on the other edge is `target`, clamped to
/// `g`: `t = (target - a1) / (a2 - a1)` in `[0, 1]`.
fn footAt(g: E, a1: i128, a2: i128, target: i128) P {
    var num = target - a1;
    var den = a2 - a1;
    if (den < 0) {
        num = -num;
        den = -den;
    }
    if (num <= 0) return g.p1;
    if (num >= den) return g.p2;
    return alongLattice(g, num, den);
}

/// `a` and `b` turned so the side each is read from is its right.
fn oriented(relation: Relation, a: E, b: E) [2]E {
    const a_turned = relation == .space or relation == .inside;
    const b_turned = relation == .space or relation == .overlap;
    return .{ if (a_turned) a.swapped() else a, if (b_turned) b.swapped() else b };
}

/// `oriented`, or null when the edges, both of positive length, run at 90
/// degrees or less to each other once `a` faces `b` (KLayout's default
/// `angle_limit`): such a pair is never reported.
fn facing(relation: Relation, a: Seg, b: Seg) ?[2]E {
    const ae = E.of(a);
    const be = E.of(b);
    const aa = if (relation == .overlap or relation == .inside) ae.swapped() else ae;
    if (!ae.degenerate() and !be.degenerate() and sprod(aa.d(), be.d()) >= 0) return null;
    return oriented(relation, ae, be);
}

/// The Euclidean distance, as a `Twice`, from `e` to the part of `other` on
/// `e`'s inner side, at any angle; null when nothing of it is there. The
/// part may end where `other` crosses `e`'s line, at `c = (X / W, Y / W)`;
/// then the candidates are its whole end to `e`, `c` to `e`'s ends (`c` lies
/// on `e`'s line, outside `e` unless the two meet), and `e`'s ends to the part.
fn nearAny(zero: Zero, e: E, other: E) ?Twice {
    const part = innerPartAny(zero, e, other) orelse return null;
    const c = switch (part) {
        .whole => return ops.segSegTwice2(e.seg(), other.seg()),
        .cut => |c| c,
    };
    if (ops.segmentsIntersect(e.seg(), other.seg())) return .whole(0);
    // From `keep` toward `c`, along `other`.
    const od = other.d();
    const u: [2]i128 = if (eqlP(c.keep, other.p1)) od else .{ -od[0], -od[1] };
    const along_c = (c.x - @as(i256, c.keep[0]) * c.w) * u[0] + (c.y - @as(i256, c.keep[1]) * c.w) * u[1];
    var best = ops.pointSegTwice2(pt(c.keep), e.seg()).min(toCut(c.x, c.y, c.w, e.p1)).min(toCut(c.x, c.y, c.w, e.p2)).min(toPart(c.keep, u, along_c, c, e.p1));
    if (!e.degenerate()) best = best.min(toPart(c.keep, u, along_c, c, e.p2));
    return best;
}

/// Twice the squared distance from the cut point `(x / w, y / w)` to `p`.
fn toCut(x: i256, y: i256, w: i256, p: P) Twice {
    const dx = x - @as(i256, p[0]) * w;
    const dy = y - @as(i256, p[1]) * w;
    return ops.twiceRatio(dx * dx + dy * dy, w * w);
}

/// Twice the squared distance from `p` to the part running from `keep`
/// along `u` to the cut point.
fn toPart(keep: P, u: [2]i128, along_c: i256, c: anytype, p: P) Twice {
    const along = sprod(.{ p[0] - keep[0], p[1] - keep[1] }, u);
    if (along <= 0) return ops.pointSegTwice2(pt(p), .{ .a = pt(keep), .b = pt(keep) });
    if (@as(i256, along) * c.w >= along_c) return toCut(c.x, c.y, c.w, p);
    const side: i256 = u[0] * (p[1] - keep[1]) - u[1] * (p[0] - keep[0]);
    return ops.twiceRatio(side * side, sprod(u, u));
}

/// `innerPart` at any angle: null when nothing of `other` is on `e`'s inner
/// side, `.whole` when all of it is, else the part from its end `keep` to
/// where `other` crosses `e`'s line.
fn innerPartAny(zero: Zero, e: E, other: E) ?PartAny {
    const keep = switch (innerEnd(zero, e, other) orelse return null) {
        .whole => return .whole,
        .from => |k| k,
    };
    // other.p1 + t·od on e's line: t = cross(ed, e.p1 - other.p1) / cross(ed, od).
    const ed = e.d();
    const od = other.d();
    const wx: i128 = e.p1[0] - other.p1[0];
    const wy: i128 = e.p1[1] - other.p1[1];
    var num = ed[0] * wy - ed[1] * wx;
    var den = ed[0] * od[1] - ed[1] * od[0];
    if (den < 0) {
        num = -num;
        den = -den;
    }
    const w: i256 = den;
    return .{ .cut = .{
        .keep = keep,
        .x = @as(i256, other.p1[0]) * w + @as(i256, od[0]) * num,
        .y = @as(i256, other.p1[1]) * w + @as(i256, od[1]) * num,
        .w = w,
    } };
}
