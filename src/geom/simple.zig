//! Whether an open coordinate run crosses itself. In: one run (`xs`, `ys`).
//! Out: true when two non-adjacent edges share a point, touching included;
//! with pinches allowed, a vertex the run passes twice as parts of one
//! figure meeting at a point is not such a touch. Ported from
//! crates/geom/src/ops.rs (`self_intersects*`, `pinches_are_corners`).
//!
//! Contents:
//! - `pub const Pinches = enum { cross, allowed }`
//! - `pub fn selfIntersects(gpa: Allocator, xs: []const Dbu, ys: []const Dbu, pinches: Pinches) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Dbu = @import("dbu.zig").Dbu;
const ops = @import("ops.zig");
const Point = ops.Point;
const Seg = ops.Seg;

/// How a touch at a twice-visited vertex reads: as a crossing (`cross`), or
/// as a pinch when the edges out of it alternate (`allowed`, what
/// validation admits).
pub const Pinches = enum { cross, allowed };

/// One edge of a run, with the x-interval the sweep orders it on; ids
/// differing by 1 or `n - 1` are adjacent.
const SweptEdge = struct {
    xlo: Dbu,
    xhi: Dbu,
    seg: Seg,
    id: u32,

    fn lessThan(_: void, a: SweptEdge, b: SweptEdge) bool {
        return a.xlo < b.xlo;
    }
};

/// One ray out of a twice-visited point, and whether it is a way on.
const Ray = struct {
    dir: [2]i64,
    on: bool,

    fn lessThan(_: void, a: Ray, b: Ray) bool {
        return ops.angleCmp(a.dir, b.dir) == .lt;
    }
};

const Visit = struct {
    x: Dbu,
    y: Dbu,
    i: u32,

    fn lessThan(_: void, a: Visit, b: Visit) bool {
        if (a.x != b.x) return a.x < b.x;
        if (a.y != b.y) return a.y < b.y;
        return a.i < b.i;
    }
};

/// Whether two non-adjacent edges of the run share a point; a run of fewer
/// than four vertices never does. With `.allowed`, a touch where edges meet
/// end to end is no crossing when every such point is a pinch: the edges out
/// of it point in distinct directions and, taken counter-clockwise round it,
/// alternate between a way back and a way on (no point near the vertex is
/// covered twice). Edges at any angle are read exactly.
///
/// Sweeps edges by x: the all-pairs verdict at the cost of the pairs whose
/// x-intervals overlap, `O(n log n)` for typical rings and `O(n²)` when every
/// edge spans a common x.
pub fn selfIntersects(gpa: Allocator, xs: []const Dbu, ys: []const Dbu, pinches: Pinches) Allocator.Error!bool {
    assert(xs.len == ys.len);
    const n = xs.len;
    // Under four edges, every pair shares a vertex.
    if (n < 4) return false;
    const last: u32 = @intCast(n - 1);

    const edges = try gpa.alloc(SweptEdge, n);
    defer gpa.free(edges);
    for (edges, 0..) |*e, i| e.* = swept(ops.ringEdge(xs, ys, i), @intCast(i));
    std.mem.sortUnstable(SweptEdge, edges, {}, SweptEdge.lessThan);

    var found = false;
    var touched = false;
    for (edges, 0..) |e, i| {
        const rest = edges[i + 1 ..];
        const window = std.sort.partitionPoint(SweptEdge, rest, e.xhi, startsBy);
        for (rest[0..window]) |o| {
            const apart = @max(e.id, o.id) - @min(e.id, o.id);
            if (apart == 1 or apart == last) continue;
            if (!ops.segmentsIntersect(e.seg, o.seg)) continue;
            const touch = pinches == .allowed and meetOnlyAtAnEnd(e.seg, o.seg);
            found = found or !touch;
            touched = touched or touch;
        }
    }
    // Edges meeting end to end put one point at two places in the run.
    if (found) return true;
    if (!touched) return false;
    return !try pinchesAreCorners(gpa, xs, ys);
}

// ---- private ----

fn swept(seg: Seg, id: u32) SweptEdge {
    return .{ .xlo = @min(seg.a.x, seg.b.x), .xhi = @max(seg.a.x, seg.b.x), .seg = seg, .id = id };
}

fn startsBy(xhi: Dbu, o: SweptEdge) bool {
    return o.xlo <= xhi;
}

/// Whether two segments share one endpoint of each and no other point: the
/// shared end, and no stretch of a common line out of it.
fn meetOnlyAtAnEnd(p: Seg, q: Seg) bool {
    var shared: u32 = 0;
    var overlap = false;
    for ([2][2]Point{ .{ p.a, p.b }, .{ p.b, p.a } }) |pe| {
        for ([2][2]Point{ .{ q.a, q.b }, .{ q.b, q.a } }) |qe| {
            const end = pe[0];
            if (!end.eql(qe[0])) continue;
            shared += 1;
            const along = @as(i128, pe[1].x - end.x) * (qe[1].x - end.x) + @as(i128, pe[1].y - end.y) * (qe[1].y - end.y);
            overlap = overlap or (ops.cross(end, pe[1], qe[1]) == 0 and along > 0);
        }
    }
    return shared == 1 and !overlap;
}

/// Whether every point the run visits more than once is a pinch. Material
/// lies left of travel, so going round the point it starts after each way on
/// and ends after each way back: alternation is exactly "no point near the
/// vertex is covered twice". A straight pass through a touch, turns that
/// differ, or a crossing put two ways back, or two ways on, side by side.
fn pinchesAreCorners(gpa: Allocator, xs: []const Dbu, ys: []const Dbu) Allocator.Error!bool {
    const n = xs.len;
    const visits = try gpa.alloc(Visit, n);
    defer gpa.free(visits);
    for (visits, 0..) |*v, i| v.* = .{ .x = xs[i], .y = ys[i], .i = @intCast(i) };
    std.mem.sortUnstable(Visit, visits, {}, Visit.lessThan);
    var rays: std.ArrayList(Ray) = .empty;
    defer rays.deinit(gpa);

    var lo: usize = 0;
    while (lo < n) {
        var hi = lo + 1;
        while (hi < n and visits[hi].x == visits[lo].x and visits[hi].y == visits[lo].y) hi += 1;
        defer lo = hi;
        if (hi - lo < 2) continue;
        rays.clearRetainingCapacity();
        for (visits[lo..hi]) |v| {
            try rays.append(gpa, .{ .dir = toward(xs, ys, v.i, (v.i + n - 1) % n), .on = false });
            try rays.append(gpa, .{ .dir = toward(xs, ys, v.i, (v.i + 1) % n), .on = true });
        }
        std.mem.sort(Ray, rays.items, {}, Ray.lessThan);
        const r = rays.items;
        for (r, 0..) |here, k| {
            const next = r[(k + 1) % r.len];
            if (ops.angleCmp(here.dir, next.dir) == .eq or here.on == next.on) return false;
        }
    }
    return true;
}

fn toward(xs: []const Dbu, ys: []const Dbu, from: usize, to: usize) [2]i64 {
    return .{ xs[to] - xs[from], ys[to] - ys[from] };
}
