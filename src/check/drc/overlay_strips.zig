//! How far a host polygon reaches past an inner one, per enclosure reading:
//! straight out from each side (projection), at each end of a side, at each
//! convex corner, between parallel edges facing the same way, or Euclidean
//! to the host's boundary. In: a rectilinear inner polygon (its box or
//! rectangles) and its rectilinear host. Out: one enclosure value and where
//! to report it. Ported from crates/check/src/drc/rules/overlay.rs
//! (`Side`, `far`, `strips`, `strip_ends`, `adjacent_enclosure`,
//! `boundary_dist2`, `apart_enclosure`, `Mode`, `enclosure_of`,
//! `saturate`, `side_midpoint`, `outward`).
//!
//! Contents:
//! - `pub const Side = enum(u8) { left, right, bottom, top }`, `pub const Mode = enum`
//! - `pub const Reading = struct { value: Dbu, at: ?Point }`, `pub const Margin = struct { d: Dbu, side: Side }`
//! - `pub fn far() Dbu`, `pub fn saturate(d2: i128) i128`
//! - `pub fn outward(a: Point, b: Point) Side`
//! - `pub fn strips(inner: Bbox, host: Polygon) [4]Margin`
//! - `pub fn sideMidpoint(inner: Bbox, margin: Dbu, side: Side) Point`
//! - `pub fn enclosureOf(inner: Polygon, rects_in: []const Bbox, host: Polygon, mode: Mode) Reading`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const Polygon = geom.Polygon;
const rects = @import("../rects.zig");
const parts = @import("parts.zig");

/// The side of an inner edge a host reaches past, in tie order.
pub const Side = enum(u8) { left, right, bottom, top };

/// How an enclosure rule reads an inner polygon in its host.
pub const Mode = enum {
    /// Euclidean to the host's boundary (`min_enclosure`).
    every_side,
    /// The better axis of straight-out readings (`asymmetric_enclosure`).
    opposite,
    /// Facing parallel edges, coincident ones exempt (`noncoincident_enclosure`).
    non_coincident,
    /// The better axis's widest straight-out reading, which must be 0 (`full_width`).
    full_width,
    /// One of the two edges at each convex corner, read there (`adjacent_enclosure`).
    adjacent,
};

/// An enclosure value and where to report it (null: the inner box's centre).
pub const Reading = struct { value: Dbu, at: ?Point };

/// A margin on one side.
pub const Margin = struct { d: Dbu, side: Side };

/// An inner edge's reading: its margin, side and box.
const Edge = struct { d: Dbu, side: Side, edge: Bbox };

/// A facing pair apart: its squared distance and report point.
const Apart = struct { d2: DbuArea, at: Point };

/// The widest margin the domain holds, 2^41: no real one exceeds it.
pub fn far() Dbu {
    return 2 * geom.max_abs_dbu;
}

/// `isqrt` takes at most `max_abs_dbu²`; a larger distance saturates there.
pub fn saturate(d2: i128) i128 {
    return @min(d2, geom.mulWide(geom.max_abs_dbu, geom.max_abs_dbu));
}

/// The side of an edge `a -> b` its shape does not lie on (material left).
pub fn outward(a: Point, b: Point) Side {
    if (a.x != b.x) return if (b.x > a.x) .bottom else .top;
    return if (b.y > a.y) .right else .left;
}

/// How far the host reaches past a box `inner` on each side, read along the
/// side's own strip: the nearest host edge, holes included, facing it.
pub fn strips(inner: Bbox, host: Polygon) [4]Margin {
    var m = [4]Dbu{ far(), far(), far(), far() };
    var it = geom.width.polyEdges(host);
    while (it.next()) |e| {
        if (e.a.x == e.b.x) {
            if (@min(e.a.y, e.b.y) < inner.yhi and @max(e.a.y, e.b.y) > inner.ylo) {
                if (e.a.x <= inner.xlo) m[0] = @min(m[0], inner.xlo - e.a.x);
                if (e.a.x >= inner.xhi) m[1] = @min(m[1], e.a.x - inner.xhi);
            }
        } else if (@min(e.a.x, e.b.x) < inner.xhi and @max(e.a.x, e.b.x) > inner.xlo) {
            if (e.a.y <= inner.ylo) m[2] = @min(m[2], inner.ylo - e.a.y);
            if (e.a.y >= inner.yhi) m[3] = @min(m[3], e.a.y - inner.yhi);
        }
    }
    return .{ .{ .d = m[0], .side = .left }, .{ .d = m[1], .side = .right }, .{ .d = m[2], .side = .bottom }, .{ .d = m[3], .side = .top } };
}

/// Midpoint of the strip `margin` wide on one side of `inner`.
pub fn sideMidpoint(inner: Bbox, margin: Dbu, side: Side) Point {
    const cx = rects.mid(inner.xlo, inner.xhi);
    const cy = rects.mid(inner.ylo, inner.yhi);
    return switch (side) {
        .left => .{ .x = rects.mid(inner.xlo - margin, inner.xlo), .y = cy },
        .right => .{ .x = rects.mid(inner.xhi, inner.xhi + margin), .y = cy },
        .bottom => .{ .x = cx, .y = rects.mid(inner.ylo - margin, inner.ylo) },
        .top => .{ .x = cx, .y = rects.mid(inner.yhi, inner.yhi + margin) },
    };
}

/// A contained inner polygon's enclosure in `host` under `mode`, and where
/// to report it. See the Rust doc of `enclosure_of`: non-coincident reads
/// facing pairs apart; every side the Euclidean distance (reported in the
/// strip of the least enclosed side of a rectangle); opposite the better
/// axis of straight-out readings; full width the better axis's widest
/// reading; adjacent one edge per convex corner.
pub fn enclosureOf(inner: Polygon, rects_in: []const Bbox, host: Polygon, mode: Mode) Reading {
    switch (mode) {
        .non_coincident => {
            const found = apartEnclosure(inner, host) orelse return .{ .value = far(), .at = null };
            return .{ .value = geom.ops.isqrt(saturate(found.d2)), .at = found.at };
        },
        .adjacent => return adjacentEnclosure(inner, host),
        .full_width, .opposite => {
            // Per axis (vertical edges, horizontal edges): the most (full
            // width) or least (opposite) enclosed edge.
            var pick: [2]?Edge = .{ null, null };
            var it = geom.width.polyEdges(inner);
            while (it.next()) |e| {
                const edge = Bbox.point(e.a.x, e.a.y).include(e.b.x, e.b.y);
                const side = outward(e.a, e.b);
                const run = strips(edge, host)[@backingInt(side)].d;
                const slot = &pick[@intFromBool(e.a.y == e.b.y)];
                const better = if (slot.*) |p| (if (mode == .full_width)
                    run > p.d or (run == p.d and @backingInt(side) < @backingInt(p.side))
                else
                    run < p.d or (run == p.d and @backingInt(side) < @backingInt(p.side))) else true;
                if (better) slot.* = .{ .d = run, .side = side, .edge = edge };
            }
            const x = pick[0].?;
            const y = pick[1].?;
            const chosen = if (mode == .full_width) (if (x.d <= y.d) x else y) else (if (x.d >= y.d) x else y);
            return .{ .value = chosen.d, .at = sideMidpoint(chosen.edge, chosen.d, chosen.side) };
        },
        .every_side => {
            var d2: i128 = std.math.maxInt(i128);
            for (0..host.ringCount()) |k| d2 = @min(d2, parts.rectsRingDist2(rects_in, host.ring(@intCast(k))));
            const value = geom.ops.isqrt(saturate(d2));
            if (rects_in.len != 1) return .{ .value = value, .at = null };
            const box = inner.bbox();
            const m = strips(box, host);
            const least = lesser(lesser(m[0], m[1]), lesser(m[2], m[3]));
            return .{ .value = value, .at = sideMidpoint(box, value, least.side) };
        },
    }
}

// ---- private ----

/// The smaller of two margins, the first on a tie.
fn lesser(a: Margin, b: Margin) Margin {
    return if (a.d <= b.d) a else b;
}

/// How far the host reaches past a box `inner` at each end of each side,
/// `[left, right, bottom, top]` as `{low end, high end}`, read straight out
/// just inside that end.
fn stripEnds(inner: Bbox, host: Polygon) [4][2]Dbu {
    var ends: [4][2]Dbu = @splat(.{ far(), far() });
    var it = geom.width.polyEdges(host);
    while (it.next()) |e| {
        if (e.a.x == e.b.x) {
            const lo = @min(e.a.y, e.b.y);
            const hi = @max(e.a.y, e.b.y);
            const low = lo <= inner.ylo and hi > inner.ylo;
            const high = lo < inner.yhi and hi >= inner.yhi;
            if (e.a.x <= inner.xlo) keep(&ends[0], low, high, inner.xlo - e.a.x);
            if (e.a.x >= inner.xhi) keep(&ends[1], low, high, e.a.x - inner.xhi);
        } else {
            const lo = @min(e.a.x, e.b.x);
            const hi = @max(e.a.x, e.b.x);
            const low = lo <= inner.xlo and hi > inner.xlo;
            const high = lo < inner.xhi and hi >= inner.xhi;
            if (e.a.y <= inner.ylo) keep(&ends[2], low, high, inner.ylo - e.a.y);
            if (e.a.y >= inner.yhi) keep(&ends[3], low, high, e.a.y - inner.yhi);
        }
    }
    return ends;
}

fn keep(slot: *[2]Dbu, low: bool, high: bool, d: Dbu) void {
    if (low) slot[0] = @min(slot[0], d);
    if (high) slot[1] = @min(slot[1], d);
}

/// One of the two sides at each convex corner: the least, over corners, of
/// the better edge meeting there read at that corner's end, reported in
/// the strip past the better edge of the worst corner.
fn adjacentEnclosure(inner: Polygon, host: Polygon) Reading {
    const ring = inner.outer();
    const n = ring.xs.len;
    var worst: ?Edge = null;
    for (0..n) |i| {
        const u = vertex(ring, i + n - 1);
        const v = vertex(ring, i);
        const w = vertex(ring, i + 1);
        // Counter-clockwise outer ring: a left turn is a convex corner.
        if ((v.x - u.x) * (w.y - v.y) - (v.y - u.y) * (w.x - v.x) <= 0) continue;
        const e1 = atEnd(u, v, v, host);
        const e2 = atEnd(v, w, v, host);
        // `(d1, s2) >= (d2, s1)` picks the first edge.
        const first_wins = e1.d > e2.d or (e1.d == e2.d and @backingInt(e2.side) >= @backingInt(e1.side));
        const better = if (first_wins) e1 else e2;
        const replace = if (worst) |wst| better.d < wst.d or (better.d == wst.d and @backingInt(better.side) < @backingInt(wst.side)) else true;
        if (replace) worst = better;
    }
    const wst = worst.?;
    return .{ .value = wst.d, .at = sideMidpoint(wst.edge, wst.d, wst.side) };
}

/// An edge `a -> b`'s reading at its endpoint `p`, outward from the inner.
fn atEnd(a: Point, b: Point, p: Point, host: Polygon) Edge {
    const edge = Bbox.point(a.x, a.y).include(b.x, b.y);
    const side = outward(a, b);
    const e = stripEnds(edge, host)[@backingInt(side)];
    const at_low = if (a.x == b.x) p.y == edge.ylo else p.x == edge.xlo;
    return .{ .d = if (at_low) e[0] else e[1], .side = side, .edge = edge };
}

fn vertex(ring: geom.Ring, i: usize) Point {
    return .{ .x = ring.xs[i % ring.xs.len], .y = ring.ys[i % ring.xs.len] };
}

/// The least Euclidean distance between an inner edge and a parallel host
/// edge facing the same way at or beyond it, over pairs that do not touch,
/// and the middle of the gap between that pair's boxes; null when every
/// such pair touches.
fn apartEnclosure(inner: Polygon, host: Polygon) ?Apart {
    var best: ?Apart = null;
    var it = geom.width.polyEdges(inner);
    while (it.next()) |e| {
        const side = outward(e.a, e.b);
        var ht = geom.width.polyEdges(host);
        while (ht.next()) |f| {
            if (outward(f.a, f.b) != side) continue;
            const beyond = switch (side) {
                .left => f.a.x <= e.a.x,
                .right => f.a.x >= e.a.x,
                .bottom => f.a.y <= e.a.y,
                .top => f.a.y >= e.a.y,
            };
            const d2 = geom.ops.segSegDist2(e, f);
            if (!beyond or d2 == 0) continue;
            if (best) |b| if (b.d2 <= d2) continue;
            best = .{ .d2 = d2, .at = rects.gapMidpoint(rects.segBbox(e), rects.segBbox(f)) };
        }
    }
    return best;
}
