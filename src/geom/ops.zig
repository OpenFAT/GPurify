//! Exact geometric predicates and measures, integer-only: products in `i128`,
//! and the squared distances to a skew line in `i256`. In: points, segments
//! and open coordinate runs (`xs`, `ys`; the last vertex joins the first).
//! Out: intersection and containment answers, signed areas, windings and
//! squared distances. Ported from crates/geom/src/{ops,wide}.rs; `centre`
//! (check/erc) and `ringEdge` (check/topology/net.rs) moved down here.
//!
//! Rust's hand-rolled 256-bit `I256` is Zig's native `i256`.
//!
//! Contents:
//! - `pub const Point = struct { x: Dbu, y: Dbu }`, `Point.eql(a: Point, b: Point) bool`, `pub const Seg = struct { a: Point, b: Point }`
//! - `pub const Ring = struct { xs: []const Dbu, ys: []const Dbu }`
//! - `pub const Winding = enum { ccw, cw }`
//! - `pub const Twice = struct { floor: i128, inexact: bool }`, `Twice.whole(v: i128) Twice`,
//!   `Twice.lessThan(a: Twice, b: Twice) bool`, `Twice.min(a: Twice, b: Twice) Twice`
//! - `pub fn cross(a: Point, b: Point, c: Point) i128`
//! - `pub fn angleCmp(a: [2]i64, b: [2]i64) std.math.Order`
//! - `pub fn segmentsIntersect(p: Seg, q: Seg) bool`
//! - `pub fn pointInRing(xs: []const Dbu, ys: []const Dbu, p: Point) bool`
//! - `pub fn area2(xs: []const Dbu, ys: []const Dbu) DbuArea`
//! - `pub fn windingOf(xs: []const Dbu, ys: []const Dbu) ?Winding`
//! - `pub fn pointSegDist2(p: Point, seg: Seg) DbuArea`
//! - `pub fn isqrt(value: DbuArea) Dbu`
//! - `pub fn segSegDist2(p: Seg, q: Seg) DbuArea`
//! - `pub const PointNear = struct`, `pub fn pointSegNear2(p: Point, seg: Seg) PointNear`
//! - `pub fn pointSegTwice2(p: Point, seg: Seg) Twice`
//! - `pub fn segSegTwice2(p: Seg, q: Seg) Twice`
//! - `pub const SegNear = struct`, `pub fn segSegNear2(p: Seg, q: Seg) SegNear`
//! - `pub fn twiceRatio(num: i256, den: i256) Twice`
//! - `pub fn cmpProducts(a: i128, b: i128, c: i128, d: i128) std.math.Order`
//! - `pub fn centre(b: Bbox) Point`
//! - `pub fn ringEdge(xs: []const Dbu, ys: []const Dbu, i: usize) Seg`

const std = @import("std");
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const DbuArea = dbu.DbuArea;
const Bbox = @import("bbox.zig").Bbox;

/// A coordinate pair, by value. Some measures return doubled coordinates in
/// one (a half-grid point), and say so.
pub const Point = struct {
    x: Dbu,
    y: Dbu,

    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
};

/// A closed segment, both ends included. On an edge layer the direction
/// carries meaning: the material lies left of travel from `a` to `b`.
pub const Seg = struct { a: Point, b: Point };

/// One open ring, borrowed: vertex `i` is `(xs[i], ys[i])` and the last
/// joins the first. `area2(r.xs, r.ys)` is its doubled signed area.
pub const Ring = struct { xs: []const Dbu, ys: []const Dbu };

/// Positive signed area is counter-clockwise, an outer boundary; negative
/// is clockwise, a hole.
pub const Winding = enum { ccw, cw };

/// Twice a squared distance that may be a fraction: its floor, and whether
/// the true value lies above it. It compares against a whole bound `B` as
/// the true value does under `<` (`v < B` iff `floor < B`); its ceiling
/// (`floor + inexact`) does under `<=` and `>`.
pub const Twice = struct {
    floor: i128,
    inexact: bool,

    pub fn whole(v: i128) Twice {
        return .{ .floor = v, .inexact = false };
    }

    /// The order of the true values: floor first, then a fraction above.
    pub fn lessThan(a: Twice, b: Twice) bool {
        return a.floor < b.floor or (a.floor == b.floor and !a.inexact and b.inexact);
    }

    pub fn min(a: Twice, b: Twice) Twice {
        return if (b.lessThan(a)) b else a;
    }
};

/// Twice a squared distance, and the nearest point with both coordinates
/// doubled.
pub const PointNear = struct { d2: i128, at2: Point };

/// Twice a squared distance between two segments and a nearest point on
/// each, doubled.
pub const SegNear = struct { d2: i128, on_p2: Point, on_q2: Point };

/// `(b - a) × (c - a)`. Differences reach `2^41`, the product 83 bits.
pub fn cross(a: Point, b: Point, c: Point) i128 {
    const ux: i128 = b.x - a.x;
    const uy: i128 = b.y - a.y;
    const vx: i128 = c.x - a.x;
    const vy: i128 = c.y - a.y;
    return ux * vy - uy * vx;
}

/// The counter-clockwise order of two non-zero directions by their angle
/// from `+x` in `[0, 2π)`: exact, by half-plane and then by the sign of the
/// cross product. Components up to `2^62` in magnitude.
pub fn angleCmp(a: [2]i64, b: [2]i64) std.math.Order {
    const la = lowerHalf(a);
    const lb = lowerHalf(b);
    if (la != lb) return if (la) .gt else .lt;
    const turn = @as(i128, a[0]) * b[1] - @as(i128, a[1]) * b[0];
    return std.math.order(@as(i128, 0), turn);
}

/// Whether two closed segments share a point; touching counts, collinear
/// overlap counts.
pub fn segmentsIntersect(p: Seg, q: Seg) bool {
    // Each endpoint's side of the other segment's line.
    const d1 = sign(cross(q.a, q.b, p.a));
    const d2 = sign(cross(q.a, q.b, p.b));
    const d3 = sign(cross(p.a, p.b, q.a));
    const d4 = sign(cross(p.a, p.b, q.b));
    // A strict straddle both ways; a zero is an endpoint on the line.
    const proper = d1 * d2 < 0 and d3 * d4 < 0;
    return proper or (d1 == 0 and inSegBox(q, p.a)) or (d2 == 0 and inSegBox(q, p.b)) or
        (d3 == 0 and inSegBox(p, q.a)) or (d4 == 0 and inSegBox(p, q.b));
}

/// Whether `p` lies inside the open run, the boundary counting as inside (a
/// via on a conductor edge is connected): an even-odd ray cast toward `+x`
/// with the half-open vertex rule, or an exact on-edge test. A run of fewer
/// than three vertices holds nothing.
pub fn pointInRing(xs: []const Dbu, ys: []const Dbu, p: Point) bool {
    assert(xs.len == ys.len);
    const n = xs.len;
    if (n < 3) return false;
    var crossings = false;
    var boundary = false;
    // Seeded with the last vertex, so the closing edge comes first.
    var a: Point = .{ .x = xs[n - 1], .y = ys[n - 1] };
    for (xs, ys) |bx, by| {
        const b: Point = .{ .x = bx, .y = by };
        const side = cross(a, b, p);
        boundary = boundary or (side == 0 and inSegBox(.{ .a = a, .b = b }, p));
        // Half-open: a vertex is counted by exactly one of its two edges.
        const straddles = (a.y > p.y) != (b.y > p.y);
        crossings = crossings != (straddles and side != 0 and (side > 0) == (b.y > a.y));
        a = b;
    }
    return boundary or crossings;
}

/// Twice the signed area of an open run, by the shoelace formula; positive
/// for counter-clockwise, zero under three vertices. Asserts equal lengths.
pub fn area2(xs: []const Dbu, ys: []const Dbu) DbuArea {
    assert(xs.len == ys.len);
    if (xs.len < 3) return 0;
    var twice: DbuArea = 0;
    var px = xs[xs.len - 1];
    var py = ys[ys.len - 1];
    // Each term is under 2^82.
    for (xs, ys) |x, y| {
        twice += dbu.mulWide(px, y) - dbu.mulWide(x, py);
        px = x;
        py = y;
    }
    return twice;
}

/// The winding, from the sign of `area2`; null for zero signed area (a run
/// that encloses nothing or doubles back on itself).
pub fn windingOf(xs: []const Dbu, ys: []const Dbu) ?Winding {
    const a = area2(xs, ys);
    return if (a > 0) .ccw else if (a < 0) .cw else null;
}

/// The squared distance from a point to a closed segment, rounded up to a
/// whole square unit: zero only when `p` is on it, so a comparison against a
/// squared limit never passes a point that is too close.
pub fn pointSegDist2(p: Point, seg: Seg) DbuArea {
    const vx: i128 = seg.b.x - seg.a.x;
    const vy: i128 = seg.b.y - seg.a.y;
    // Axis-aligned, or a point: clamp `p` into the segment's box.
    if (vx == 0 or vy == 0) {
        const dx = gapOutside(p.x, seg.a.x, seg.b.x);
        const dy = gapOutside(p.y, seg.a.y, seg.b.y);
        return dx * dx + dy * dy;
    }
    const wx: i128 = p.x - seg.a.x;
    const wy: i128 = p.y - seg.a.y;
    // The projection of `w` on `v`, scaled by `|v|²`.
    const along = vx * wx + vy * wy;
    const len2 = vx * vx + vy * vy;
    if (along <= 0) return wx * wx + wy * wy;
    if (along >= len2) {
        const ux: i128 = p.x - seg.b.x;
        const uy: i128 = p.y - seg.b.y;
        return ux * ux + uy * uy;
    }
    // Foot strictly inside: `ceil(cross² / |v|²)`.
    const drop = @abs(cross(seg.a, seg.b, p));
    const scale = @abs(len2);
    const dist2: u128 = if (std.math.mul(u128, drop, drop)) |num|
        num / scale + @intFromBool(num % scale != 0)
    else |_|
        ceilSqDiv(drop, scale);
    // At most the squared diagonal of the ±2^40 domain, 2^83.
    assert(dist2 < 1 << 84);
    return @intCast(dist2);
}

/// The integer square root, truncating; negatives give 0 and results clamp
/// to `max_abs_dbu`.
pub fn isqrt(value: DbuArea) Dbu {
    const root: u64 = std.math.sqrt(@as(u128, @intCast(@max(value, 0))));
    return @intCast(@min(root, dbu.max_abs_dbu));
}

/// The squared distance between two closed segments; zero when they touch.
pub fn segSegDist2(p: Seg, q: Seg) DbuArea {
    if (segmentsIntersect(p, q)) return 0;
    // Disjoint segments are nearest at an endpoint of one of them.
    return @min(@min(pointSegDist2(p.a, q), pointSegDist2(p.b, q)), @min(pointSegDist2(q.a, p), pointSegDist2(q.b, p)));
}

/// Twice the squared distance from `p` to a closed segment, and the
/// segment's nearest point, doubled. Exact when the segment is horizontal,
/// vertical or at 45 degrees (twice such a squared distance is whole and the
/// foot a half-grid point); at any other angle the distance is twice
/// `pointSegDist2` (rounded up) and the point is rounded.
pub fn pointSegNear2(p: Point, seg: Seg) PointNear {
    const ax = seg.a.x;
    const ay = seg.a.y;
    const vx = seg.b.x - ax;
    const vy = seg.b.y - ay;
    const wx = p.x - ax;
    const wy = p.y - ay;
    const along = @as(i128, vx) * wx + @as(i128, vy) * wy;
    const len2 = @as(i128, vx) * vx + @as(i128, vy) * vy;
    if (along <= 0) return nearTo(p, ax, ay);
    if (along >= len2) return nearTo(p, seg.b.x, seg.b.y);
    // The foot keeps `p`'s coordinate along an axis segment.
    if (vx == 0) return nearTo(p, ax, p.y);
    if (vy == 0) return nearTo(p, p.x, ay);
    if (@abs(vx) == @abs(vy)) {
        // `v = k·s`: twice the squared offset is `(s × w)²`, and the foot,
        // doubled, is `2a + (s·w)·s`.
        const sx: i64 = std.math.sign(vx);
        const sy: i64 = std.math.sign(vy);
        const side: i128 = sx * wy - sy * wx;
        const t = sx * wx + sy * wy;
        return .{ .d2 = side * side, .at2 = .{ .x = 2 * ax + t * sx, .y = 2 * ay + t * sy } };
    }
    const scaled = struct {
        fn at(a: i64, v: i64, al: i128, l2: i128) i64 {
            return @intCast(@as(i128, 2 * a) + @divFloor(2 * al * v, l2));
        }
    }.at;
    return .{ .d2 = 2 * pointSegDist2(p, seg), .at2 = .{ .x = scaled(ax, vx, along, len2), .y = scaled(ay, vy, along, len2) } };
}

/// Twice the squared distance from `p` to a closed segment at any angle,
/// exactly, as a `Twice`; whole on axis and 45-degree segments.
pub fn pointSegTwice2(p: Point, seg: Seg) Twice {
    const vx: i128 = seg.b.x - seg.a.x;
    const vy: i128 = seg.b.y - seg.a.y;
    const wx: i128 = p.x - seg.a.x;
    const wy: i128 = p.y - seg.a.y;
    const along = vx * wx + vy * wy;
    const len2 = vx * vx + vy * vy;
    if (along <= 0) return .whole(nearTo(p, seg.a.x, seg.a.y).d2);
    if (along >= len2) return .whole(nearTo(p, seg.b.x, seg.b.y).d2);
    const side: i256 = cross(seg.a, seg.b, p);
    return twiceRatio(side * side, len2);
}

/// `pointSegTwice2` between two closed segments; zero when they touch.
pub fn segSegTwice2(p: Seg, q: Seg) Twice {
    if (segmentsIntersect(p, q)) return .whole(0);
    return pointSegTwice2(p.a, q).min(pointSegTwice2(p.b, q)).min(pointSegTwice2(q.a, p)).min(pointSegTwice2(q.b, p));
}

/// Twice the squared distance between two closed segments, with a nearest
/// point on each, doubled; zero at a shared point when they touch. Exact on
/// axis and 45-degree segments, as `pointSegNear2`.
pub fn segSegNear2(p: Seg, q: Seg) SegNear {
    const candidates = [4]struct { near: PointNear, end: Point, from_p: bool }{
        .{ .near = pointSegNear2(p.a, q), .end = doubled(p.a), .from_p = true },
        .{ .near = pointSegNear2(p.b, q), .end = doubled(p.b), .from_p = true },
        .{ .near = pointSegNear2(q.a, p), .end = doubled(q.a), .from_p = false },
        .{ .near = pointSegNear2(q.b, p), .end = doubled(q.b), .from_p = false },
    };
    // The first least, as Rust's `min_by_key`.
    var best = candidates[0];
    for (candidates[1..]) |c| {
        if (c.near.d2 < best.near.d2) best = c;
    }
    if (best.near.d2 > 0 and segmentsIntersect(p, q)) {
        // A proper crossing, reported at the nearer ends' middle.
        const mid: Point = .{ .x = midpoint(best.end.x, best.near.at2.x), .y = midpoint(best.end.y, best.near.at2.y) };
        return .{ .d2 = 0, .on_p2 = mid, .on_q2 = mid };
    }
    if (best.from_p) return .{ .d2 = best.near.d2, .on_p2 = best.end, .on_q2 = best.near.at2 };
    return .{ .d2 = best.near.d2, .on_p2 = best.near.at2, .on_q2 = best.end };
}

/// `2 · num / den` as a `Twice`, for `num >= 0` and `den > 0`: a
/// twice-squared distance at any angle. Asserts the quotient fits an
/// `i128`, which every distance in the domain does.
pub fn twiceRatio(num: i256, den: i256) Twice {
    assert(num >= 0 and den > 0);
    const twice = 2 * num;
    return .{ .floor = @intCast(@divFloor(twice, den)), .inexact = @mod(twice, den) != 0 };
}

/// `a · b` against `c · d`, exactly, for any `i128` operands.
pub fn cmpProducts(a: i128, b: i128, c: i128, d: i128) std.math.Order {
    return std.math.order(@as(i256, a) * b, @as(i256, c) * d);
}

/// The centre of a box, each coordinate the midpoint rounded toward zero (so
/// up for a negative odd sum).
pub fn centre(b: Bbox) Point {
    return .{ .x = midpoint(b.xlo, b.xhi), .y = midpoint(b.ylo, b.yhi) };
}

/// The closed segment from vertex `i` of an open run to the next, wrapping.
pub fn ringEdge(xs: []const Dbu, ys: []const Dbu, i: usize) Seg {
    const next = if (i + 1 == xs.len) 0 else i + 1;
    return .{ .a = .{ .x = xs[i], .y = ys[i] }, .b = .{ .x = xs[next], .y = ys[next] } };
}

// ---- private ----

fn lowerHalf(v: [2]i64) bool {
    return v[1] < 0 or (v[1] == 0 and v[0] < 0);
}

fn sign(v: i128) i8 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

/// With a zero `cross`, exactly "`p` is on the segment `s`".
fn inSegBox(s: Seg, p: Point) bool {
    return p.x >= @min(s.a.x, s.b.x) and p.x <= @max(s.a.x, s.b.x) and
        p.y >= @min(s.a.y, s.b.y) and p.y <= @max(s.a.y, s.b.y);
}

/// How far `v` lies outside the interval spanned by `a` and `b`, signed;
/// zero within.
fn gapOutside(v: Dbu, a: Dbu, b: Dbu) i128 {
    return std.math.clamp(v, @min(a, b), @max(a, b)) - v;
}

/// `ceil(a² / d)` for `a, d < 2^84`, `d > 0`, where `a²` is past `u128`.
/// Out of line and cold: only points near the domain's corners reach it,
/// and inlined it kept the division out of its callers' loops.
noinline fn ceilSqDiv(a: u128, d: u128) u128 {
    @branchHint(.cold);
    const sq = @as(u256, a) * a;
    return @intCast(sq / d + @intFromBool(sq % d != 0));
}

fn nearTo(p: Point, x: i64, y: i64) PointNear {
    const dx: i128 = p.x - x;
    const dy: i128 = p.y - y;
    return .{ .d2 = 2 * (dx * dx + dy * dy), .at2 = .{ .x = 2 * x, .y = 2 * y } };
}

fn doubled(p: Point) Point {
    return .{ .x = 2 * p.x, .y = 2 * p.y };
}

/// `(a + b) / 2` rounded toward zero, without overflow (Rust's
/// `i64::midpoint`).
fn midpoint(a: i64, b: i64) i64 {
    return @intCast(@divTrunc(@as(i128, a) + b, 2));
}

test "wide arithmetic matches i128 and powers of two" {
    // Oracle: closed form against `i128` arithmetic where it fits, and
    // `(2^100)^2 / 2^150 = 2^50` beyond it.
    const big = @as(i256, 1 << 100) * (1 << 100);
    try std.testing.expectEqual(Twice{ .floor = 1 << 51, .inexact = false }, twiceRatio(big, @as(i256, 1 << 100) * (1 << 50)));
    try std.testing.expectEqual(Twice{ .floor = 2, .inexact = true }, twiceRatio(5, 4));
    try std.testing.expectEqual(std.math.Order.gt, cmpProducts(1 << 100, 3, 1 << 101, 1));
    try std.testing.expectEqual(std.math.Order.lt, cmpProducts(-(1 << 100), 3, 1 << 101, 1));
}
