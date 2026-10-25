//! The boolean sweep for operands with an edge at any angle, by snap
//! rounding. In: flat rings on the grid. Out: the result's rings on the
//! grid, outers counter-clockwise, holes clockwise, in the connected corner
//! model (`boolean.unionInto`). Ported from
//! crates/geom/src/boolean/anyangle.rs.
//!
//! Two edges at arbitrary angles cross at a rational point the result cannot
//! keep. `snapRound` rounds every crossing to its nearest grid point and
//! bends every edge passing that point's pixel through it (snap rounding:
//! J. D. Hobby, "Practical segment intersection with finite precision
//! output", Computational Geometry 13 (1999) 199-214; L. Guibas and D.
//! Marimont, "Rounding arrangements dynamically", IJCGA 8 (1998) 157-176), so
//! rounded edges meet only at grid points and no crossing is created. An
//! edge no rounded crossing bends keeps its shape; a vertex near it becomes
//! a point it passes only once the edge is bent anyway, as KLayout's edge
//! processor makes such a vertex a weak attractor (`dbEdgeProcessor.cc`,
//! `is_point_on_fuzzy`, `add_attractor`). A sweep reads each operand's
//! winding on both sides of every rounded edge; the boundary is where the
//! operation's answer changes. Every predicate is exact in `i128` over the
//! whole domain.
//!
//! Contents:
//! - `pub fn combineInto(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const flat = @import("flat_rings.zig");
const Rings = flat.Rings;
const Op = flat.Op;
const octilinear = @import("boolean_octilinear.zig");
const Piece = octilinear.Piece;

const P = [2]i64;

/// One directed ring edge and the operand it came from.
const Edge = struct { a: P, b: P, right: bool };

/// One edge of the rounded arrangement, `p < q` (by x, then y), with each
/// operand's winding: `+1` per ring edge running `p` to `q`, `-1` back.
const Frag = struct { p: P, q: P, wind: [2]i32 };

/// A fragment in a slab and the winding just above it.
const Above = struct { frag: u32, w: [2]i32 };

/// A bound on an edge's parameter `t`: `num / den` (`den > 0`), and whether
/// `t` may equal it.
const Bound = struct {
    num: i128,
    den: i128,
    closed: bool,

    fn order(a: Bound, b: Bound) std.math.Order {
        return std.math.order(a.num * b.den, b.num * a.den);
    }
};

/// A point that may route edges: an edge end, a rounded crossing, or both.
/// A hot point bends every edge whose pixel span holds it; otherwise only an
/// edge it lies on exactly is cut there.
const Hot = struct { at: P, hot: bool };

/// Orders non-vertical fragments by height at `x2 / 2`.
const OrderAt = struct {
    frags: []const Frag,
    x2: i64,

    fn lessThan(c: OrderAt, i: u32, j: u32) bool {
        return orderAt(c.frags[i], c.frags[j], c.x2) == .lt;
    }
};

/// Whether a slab fragment lies below the middle `mid2 / 2` of a vertical
/// fragment at `x2 / 2`.
const Below = struct {
    frags: []const Frag,
    x2: i64,
    mid2: i128,

    fn under(c: Below, g: Above) bool {
        const nd = yAt(c.frags[g.frag], c.x2);
        return 2 * nd[0] < c.mid2 * nd[1];
    }
};

/// One routing point of an edge and the parameter at which it enters its
/// pixel.
const Stop = struct {
    enter: Bound,
    at: P,

    fn lessThan(_: void, a: Stop, b: Stop) bool {
        return switch (a.enter.order(b.enter)) {
            .lt => true,
            .gt => false,
            .eq => a.enter.closed and !b.enter.closed,
        };
    }
};

/// The rings of `op(a, b)` into `out` (cleared and refilled).
pub fn combineInto(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    for ([2]*const Rings{ a, b }, [2]bool{ false, true }) |rings, right| {
        for (0..rings.count()) |k| {
            const lo, const hi = rings.range(k);
            const n = hi - lo;
            for (0..n) |i| {
                const s = lo + i;
                const t = lo + (i + 1) % n;
                try edges.append(gpa, .{ .a = .{ rings.xs.items[s], rings.ys.items[s] }, .b = .{ rings.xs.items[t], rings.ys.items[t] }, .right = right });
            }
        }
    }
    var frags: std.ArrayList(Frag) = .empty;
    defer frags.deinit(gpa);
    try snapRound(gpa, edges.items, &frags);
    const fr = frags.items;

    var xs: std.ArrayList(i64) = .empty;
    defer xs.deinit(gpa);
    for (fr) |f| try xs.appendSlice(gpa, &.{ f.p[0], f.q[0] });
    std.mem.sortUnstable(i64, xs.items, {}, std.sort.asc(i64));
    xs.shrinkRetainingCapacity(dedup(i64, xs.items));
    // Non-vertical fragments by left end; vertical ones by x.
    var sloped: std.ArrayList(u32) = .empty;
    defer sloped.deinit(gpa);
    var upright: std.ArrayList(u32) = .empty;
    defer upright.deinit(gpa);
    for (fr, 0..) |f, i| try (if (f.p[0] != f.q[0]) &sloped else &upright).append(gpa, @intCast(i));
    std.mem.sortUnstable(u32, sloped.items, fr, struct {
        fn lessThan(c: []const Frag, i: u32, j: u32) bool {
            return c[i].p[0] < c[j].p[0];
        }
    }.lessThan);
    std.mem.sortUnstable(u32, upright.items, fr, struct {
        fn lessThan(c: []const Frag, i: u32, j: u32) bool {
            return lessP(c[i].p, c[j].p);
        }
    }.lessThan);

    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(gpa);
    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(gpa);
    // The slab ending at the current x: its fragments bottom to top, each
    // with the winding just above it.
    var before: std.ArrayList(Above) = .empty;
    defer before.deinit(gpa);
    var now: std.ArrayList(Above) = .empty;
    defer now.deinit(gpa);
    var next_sloped: usize = 0;
    var next_upright: usize = 0;
    for (xs.items, 0..) |x, k| {
        // Vertical fragments at `x`: the winding just left of each is the
        // left slab's below its middle; no fragment ends inside one.
        while (next_upright < upright.items.len and fr[upright.items[next_upright]].p[0] == x) : (next_upright += 1) {
            const f = fr[upright.items[next_upright]];
            const mid2: i128 = @as(i128, f.p[1]) + f.q[1];
            const below = std.sort.partitionPoint(Above, before.items, Below{ .frags = fr, .x2 = 2 * x, .mid2 = mid2 }, Below.under);
            const left: [2]i32 = if (below == 0) .{ 0, 0 } else before.items[below - 1].w;
            // Running up, `p` to `q`, a ring's material is on the left.
            const right = add(left, f.wind, -1);
            if (op.apply(left[0] != 0, left[1] != 0) and !op.apply(right[0] != 0, right[1] != 0)) try pushPiece(gpa, &pieces, f.p, f.q);
            if (!op.apply(left[0] != 0, left[1] != 0) and op.apply(right[0] != 0, right[1] != 0)) try pushPiece(gpa, &pieces, f.q, f.p);
        }
        if (k + 1 == xs.items.len) {
            assert(next_sloped == sloped.items.len);
            break;
        }
        const next = xs.items[k + 1];
        var kept: usize = 0;
        for (active.items) |i| {
            if (fr[i].q[0] <= x) continue;
            active.items[kept] = i;
            kept += 1;
        }
        active.shrinkRetainingCapacity(kept);
        while (next_sloped < sloped.items.len and fr[sloped.items[next_sloped]].p[0] == x) : (next_sloped += 1) {
            try active.append(gpa, sloped.items[next_sloped]);
        }
        std.mem.sort(u32, active.items, OrderAt{ .frags = fr, .x2 = x + next }, OrderAt.lessThan);
        now.clearRetainingCapacity();
        var w = [2]i32{ 0, 0 };
        for (active.items, 0..) |i, n| {
            if (n + 1 < active.items.len) {
                // Snap rounding leaves no two fragments crossing.
                const j = active.items[n + 1];
                assert(orderAt(fr[i], fr[j], 2 * x) != .gt and orderAt(fr[i], fr[j], 2 * next) != .gt);
            }
            const f = fr[i];
            const above = add(w, f.wind, 1);
            // Only a fragment's first slab emits it; running toward +x, a
            // ring's material is above.
            if (f.p[0] == x) {
                const in_below = op.apply(w[0] != 0, w[1] != 0);
                const in_above = op.apply(above[0] != 0, above[1] != 0);
                if (!in_below and in_above) try pushPiece(gpa, &pieces, f.p, f.q);
                if (in_below and !in_above) try pushPiece(gpa, &pieces, f.q, f.p);
            }
            w = above;
            try now.append(gpa, .{ .frag = i, .w = w });
        }
        // A dropped fragment would trace a ring of the wrong area.
        assert(w[0] == 0 and w[1] == 0);
        std.mem.swap(std.ArrayList(Above), &before, &now);
    }
    try octilinear.link(gpa, pieces.items, out);
}

// ---- private ----

fn lessP(a: P, b: P) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

fn eqlP(a: P, b: P) bool {
    return a[0] == b[0] and a[1] == b[1];
}

fn dedup(comptime T: type, items: []T) usize {
    var kept: usize = 0;
    for (items) |v| {
        if (kept > 0 and std.meta.eql(items[kept - 1], v)) continue;
        items[kept] = v;
        kept += 1;
    }
    return kept;
}

fn cross(o: P, a: P, b: P) i128 {
    const ax: i128 = a[0] - o[0];
    const ay: i128 = a[1] - o[1];
    const bx: i128 = b[0] - o[0];
    const by: i128 = b[1] - o[1];
    return ax * by - ay * bx;
}

/// `n / d` to the nearest integer, a half away from zero, as KLayout rounds
/// a coordinate (`coord_traits::rounded`).
fn roundDiv(n0: i128, d0: i128) i64 {
    const n = if (d0 < 0) -n0 else n0;
    const d = if (d0 < 0) -d0 else d0;
    const q = @divTrunc(2 * @as(i128, @intCast(@abs(n))) + d, 2 * d);
    return @intCast(if (n < 0) -q else q);
}

/// Where two edges cross at a point inside both, rounded to the grid; null
/// when they do not, or only touch (an end on the other, a shared stretch).
fn crossing(s: Edge, e: Edge) ?P {
    const d1 = std.math.sign(cross(e.a, e.b, s.a));
    const d2 = std.math.sign(cross(e.a, e.b, s.b));
    const d3 = std.math.sign(cross(s.a, s.b, e.a));
    const d4 = std.math.sign(cross(s.a, s.b, e.b));
    if (d1 * d2 >= 0 or d3 * d4 >= 0) return null;
    const dx: i128 = s.b[0] - s.a[0];
    const dy: i128 = s.b[1] - s.a[1];
    const fx: i128 = e.b[0] - e.a[0];
    const fy: i128 = e.b[1] - e.a[1];
    const wx: i128 = e.a[0] - s.a[0];
    const wy: i128 = e.a[1] - s.a[1];
    // s.a + t·d on e: t = (w × f) / (d × f), both under 2^84 in magnitude.
    const den = dx * fy - dy * fx;
    const num = wx * fy - wy * fx;
    return .{ roundDiv(@as(i128, s.a[0]) * den + dx * num, den), roundDiv(@as(i128, s.a[1]) * den + dy * num, den) };
}

/// The parameters at which the edge `a`-`b` lies in the pixel of the grid
/// point `h`, as `[enter, leave]`, or null when it misses it. The pixel of
/// `h` is the set of points rounding to it (half away from zero): `[c - ½,
/// c + ½)` across each axis for `c > 0`, `(c - ½, c + ½]` for `c < 0`,
/// `(-½, ½)` for `c = 0`, so pixels tile the plane and are symmetric under
/// the grid's eight symmetries.
fn pixelSpan(a: P, b: P, h: P) ?[2]Bound {
    var lo: Bound = .{ .num = 0, .den = 1, .closed = true };
    var hi: Bound = .{ .num = 1, .den = 1, .closed = true };
    for ([2]usize{ 0, 1 }) |axis| {
        const c = h[axis];
        // Doubled: the pixel spans 2c - 1 .. 2c + 1.
        const low: i128 = 2 * c - 1;
        const high: i128 = 2 * c + 1;
        const low_closed = c > 0;
        const high_closed = c < 0;
        const start: i128 = 2 * a[axis];
        const delta: i128 = 2 * (b[axis] - a[axis]);
        if (delta == 0) {
            const above = start > low or (start == low and low_closed);
            const below = start < high or (start == high and high_closed);
            if (!(above and below)) return null;
            continue;
        }
        const enter = boundAt(if (delta > 0) low else high, if (delta > 0) low_closed else high_closed, start, delta);
        const leave = boundAt(if (delta > 0) high else low, if (delta > 0) high_closed else low_closed, start, delta);
        switch (enter.order(lo)) {
            .gt => lo = enter,
            .eq => lo.closed = lo.closed and enter.closed,
            .lt => {},
        }
        switch (leave.order(hi)) {
            .lt => hi = leave,
            .eq => hi.closed = hi.closed and leave.closed,
            .gt => {},
        }
    }
    return switch (lo.order(hi)) {
        .lt => .{ lo, hi },
        .eq => if (lo.closed and hi.closed) .{ lo, hi } else null,
        .gt => null,
    };
}

fn boundAt(edge: i128, closed: bool, start: i128, delta: i128) Bound {
    const num = edge - start;
    return if (delta < 0) .{ .num = -num, .den = -delta, .closed = closed } else .{ .num = num, .den = delta, .closed = closed };
}

/// Whether the grid point `h` lies on the closed segment `a`-`b`.
fn onSegment(a: P, b: P, h: P) bool {
    return cross(a, b, h) == 0 and h[0] >= @min(a[0], b[0]) and h[0] <= @max(a[0], b[0]) and
        h[1] >= @min(a[1], b[1]) and h[1] <= @max(a[1], b[1]);
}

/// The run of `points` (sorted by coordinate; `Hot` or `P`) whose x lies in
/// `[x0, x1]`, to filter by y.
fn inBoxRange(comptime T: type, points: []const T, x0: i64, x1: i64) [2]usize {
    const S = struct {
        fn x(v: T) i64 {
            return if (T == Hot) v.at[0] else v[0];
        }
        fn before(at: i64, v: T) bool {
            return x(v) < at;
        }
        fn atOrBefore(at: i64, v: T) bool {
            return x(v) <= at;
        }
    };
    return .{ std.sort.partitionPoint(T, points, x0, S.before), std.sort.partitionPoint(T, points, x1, S.atOrBefore) };
}

fn edgeBox(e: Edge) [4]i64 {
    return .{ @min(e.a[0], e.b[0]), @max(e.a[0], e.b[0]), @min(e.a[1], e.b[1]), @max(e.a[1], e.b[1]) };
}

/// The snap-rounded arrangement of every edge, into `out`: each edge cut at,
/// or bent through, its routing points, as fragments meeting only at their
/// ends; coincident fragments are one, windings summed, and one whose
/// windings cancel is dropped. A rounded crossing (hot) bends every edge
/// whose pixel span holds it; an edge end bends an edge already bent whose
/// pixel span holds it, which makes it hot in turn, to a fixed point; and a
/// point lying exactly on an edge cuts it without moving it.
fn snapRound(gpa: Allocator, edges: []const Edge, out: *std.ArrayList(Frag)) Allocator.Error!void {
    // ponytail: candidate points by an x-sorted scan and edge pairs by
    // x-overlap, O(n²) when every edge spans one column; a grid of buckets
    // if large curved layers make this slow.
    var points: std.ArrayList(Hot) = .empty;
    defer points.deinit(gpa);
    for (edges) |e| try points.append(gpa, .{ .at = e.a, .hot = false });
    const order = try gpa.alloc(u32, edges.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sortUnstable(u32, order, edges, struct {
        fn lessThan(es: []const Edge, i: u32, j: u32) bool {
            return edgeBox(es[i])[0] < edgeBox(es[j])[0];
        }
    }.lessThan);
    for (order, 0..) |i, k| {
        const xmax = edgeBox(edges[i])[1];
        for (order[k + 1 ..]) |j| {
            if (edgeBox(edges[j])[0] > xmax) break;
            if (crossing(edges[i], edges[j])) |at| try points.append(gpa, .{ .at = at, .hot = true });
        }
    }
    // By point, hot first, then one row per point.
    std.mem.sortUnstable(Hot, points.items, {}, struct {
        fn lessThan(_: void, a: Hot, b: Hot) bool {
            if (!eqlP(a.at, b.at)) return lessP(a.at, b.at);
            return a.hot and !b.hot;
        }
    }.lessThan);
    var kept: usize = 0;
    for (points.items) |h| {
        if (kept > 0 and eqlP(points.items[kept - 1].at, h.at)) continue;
        points.items[kept] = h;
        kept += 1;
    }
    points.shrinkRetainingCapacity(kept);
    const pts = points.items;

    // Bent edges attract the edge ends in their pixel spans, which bend
    // other edges in turn.
    const bent = try gpa.alloc(bool, edges.len);
    defer gpa.free(bent);
    while (true) {
        for (edges, bent) |e, *bt| {
            const bx = edgeBox(e);
            const r = inBoxRange(Hot, pts, bx[0], bx[1]);
            bt.* = false;
            for (pts[r[0]..r[1]]) |h| {
                if (h.at[1] < bx[2] or h.at[1] > bx[3]) continue;
                if (h.hot and !onSegment(e.a, e.b, h.at) and pixelSpan(e.a, e.b, h.at) != null) bt.* = true;
            }
        }
        var grew = false;
        for (edges, bent) |e, bt| {
            if (!bt) continue;
            const bx = edgeBox(e);
            const r = inBoxRange(Hot, pts, bx[0], bx[1]);
            for (pts[r[0]..r[1]]) |*h| {
                if (h.at[1] < bx[2] or h.at[1] > bx[3]) continue;
                if (!h.hot and pixelSpan(e.a, e.b, h.at) != null) {
                    h.hot = true;
                    grew = true;
                }
            }
        }
        if (!grew) break;
    }

    var frags: std.ArrayList(Frag) = .empty;
    defer frags.deinit(gpa);
    var route: std.ArrayList(Stop) = .empty;
    defer route.deinit(gpa);
    for (edges) |e| {
        const bx = edgeBox(e);
        const r = inBoxRange(Hot, pts, bx[0], bx[1]);
        route.clearRetainingCapacity();
        for (pts[r[0]..r[1]]) |h| {
            if (h.at[1] < bx[2] or h.at[1] > bx[3]) continue;
            if (!h.hot and !onSegment(e.a, e.b, h.at)) continue;
            const span = pixelSpan(e.a, e.b, h.at) orelse continue;
            try route.append(gpa, .{ .enter = span[0], .at = h.at });
        }
        // Pixels are disjoint, so an edge enters them in a strict order; a
        // closed entry comes before an open one at the same parameter.
        std.mem.sort(Stop, route.items, {}, Stop.lessThan);
        const w: usize = @intFromBool(e.right);
        for (route.items[0..route.items.len -| 1], route.items[@min(1, route.items.len)..]) |from, to| {
            assert(!eqlP(from.at, to.at));
            var wind = [2]i32{ 0, 0 };
            const forward = lessP(from.at, to.at);
            wind[w] = if (forward) 1 else -1;
            try frags.append(gpa, if (forward) .{ .p = from.at, .q = to.at, .wind = wind } else .{ .p = to.at, .q = from.at, .wind = wind });
        }
    }
    try cutAndMerge(gpa, frags.items, out);
}

/// Cuts each fragment at every fragment end lying exactly inside it, so
/// fragments meet only at their ends and coincide whole or not at all; then
/// merges coincident ones, summing windings, and drops cancelled ones.
fn cutAndMerge(gpa: Allocator, frags: []const Frag, out: *std.ArrayList(Frag)) Allocator.Error!void {
    var ends: std.ArrayList(P) = .empty;
    defer ends.deinit(gpa);
    for (frags) |f| try ends.appendSlice(gpa, &.{ f.p, f.q });
    std.mem.sortUnstable(P, ends.items, {}, struct {
        fn lessThan(_: void, a: P, b: P) bool {
            return lessP(a, b);
        }
    }.lessThan);
    ends.shrinkRetainingCapacity(dedup(P, ends.items));
    var cut: std.ArrayList(Frag) = .empty;
    defer cut.deinit(gpa);
    var stops: std.ArrayList(P) = .empty;
    defer stops.deinit(gpa);
    for (frags) |f| {
        const y0 = @min(f.p[1], f.q[1]);
        const y1 = @max(f.p[1], f.q[1]);
        stops.clearRetainingCapacity();
        const r = inBoxRange(P, ends.items, f.p[0], f.q[0]);
        for (ends.items[r[0]..r[1]]) |v| {
            if (v[1] >= y0 and v[1] <= y1 and onSegment(f.p, f.q, v)) try stops.append(gpa, v);
        }
        // `p < q` by (x, y), and so is every point between them on the
        // segment; `ends` is sorted, so `stops` already is.
        for (stops.items[0..stops.items.len -| 1], stops.items[@min(1, stops.items.len)..]) |a, b| {
            try cut.append(gpa, .{ .p = a, .q = b, .wind = f.wind });
        }
    }
    std.mem.sortUnstable(Frag, cut.items, {}, struct {
        fn lessThan(_: void, a: Frag, b: Frag) bool {
            if (!eqlP(a.p, b.p)) return lessP(a.p, b.p);
            return lessP(a.q, b.q);
        }
    }.lessThan);
    out.clearRetainingCapacity();
    for (cut.items) |f| {
        if (out.items.len > 0) {
            const m = &out.items[out.items.len - 1];
            if (eqlP(m.p, f.p) and eqlP(m.q, f.q)) {
                m.wind[0] += f.wind[0];
                m.wind[1] += f.wind[1];
                continue;
            }
        }
        try out.append(gpa, f);
    }
    var kept: usize = 0;
    for (out.items) |f| {
        if (f.wind[0] == 0 and f.wind[1] == 0) continue;
        out.items[kept] = f;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
}

/// A non-vertical fragment's height at `x2 / 2`, as `num / den`, `den > 0`.
fn yAt(f: Frag, x2: i64) [2]i128 {
    const dx: i128 = f.q[0] - f.p[0];
    const dy: i128 = f.q[1] - f.p[1];
    return .{ 2 * @as(i128, f.p[1]) * dx + dy * (@as(i128, x2) - 2 * @as(i128, f.p[0])), 2 * dx };
}

fn orderAt(f: Frag, g: Frag, x2: i64) std.math.Order {
    const a = yAt(f, x2);
    const b = yAt(g, x2);
    return std.math.order(a[0] * b[1], b[0] * a[1]);
}

fn add(w: [2]i32, v: [2]i32, sign: i32) [2]i32 {
    return .{ w[0] + sign * v[0], w[1] + sign * v[1] };
}

fn pushPiece(gpa: Allocator, pieces: *std.ArrayList(Piece), from: P, to: P) Allocator.Error!void {
    try pieces.append(gpa, .{ .sx = from[0], .sy = from[1], .ex = to[0], .ey = to[1] });
}
