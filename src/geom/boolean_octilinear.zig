//! The boolean sweep for octilinear operands: every edge horizontal,
//! vertical or at 45 degrees. In: flat rings at doubled scale (every
//! coordinate times two), so two octilinear edges always cross at an
//! integer. Out: the result's rings at doubled scale, in the connected
//! corner model; `snapInto` then moves a vertex between grid points onto the
//! grid. Ported from crates/geom/src/boolean/octilinear.rs.
//!
//! The sweep cuts the plane into vertical slabs at every vertex and every
//! crossing, so inside a slab no two edges cross and each operand's winding
//! is constant between consecutive edges. A slab's result boundary is where
//! the operation's answer changes; the vertical boundary is where two
//! neighbouring slabs' answers differ along their shared line. Every
//! coordinate formed is an integer combination of the input's: exact.
//!
//! Contents:
//! - `pub const Piece = struct { sx: i64, sy: i64, ex: i64, ey: i64 }`
//! - `pub fn combineInto(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void`
//! - `pub fn link(gpa: Allocator, pieces: []const Piece, out: *Rings) Allocator.Error!void`
//! - `pub fn offGrid(rings: *const Rings) bool`
//! - `pub fn snapInto(gpa: Allocator, rings: *const Rings, out: *Rings) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ops = @import("ops.zig");
const flat = @import("flat_rings.zig");
const Rings = flat.Rings;
const Op = flat.Op;

/// One boundary segment of the result, its material on the left.
pub const Piece = struct {
    sx: i64,
    sy: i64,
    ex: i64,
    ey: i64,

    fn head(p: Piece) [2]i64 {
        return .{ p.sx, p.sy };
    }

    fn tail(p: Piece) [2]i64 {
        return .{ p.ex, p.ey };
    }

    /// Whether `o` runs the same way: parallel, not opposite; exact at any angle.
    fn sameWay(p: Piece, o: Piece) bool {
        const ax: i128 = p.ex - p.sx;
        const ay: i128 = p.ey - p.sy;
        const bx: i128 = o.ex - o.sx;
        const by: i128 = o.ey - o.sy;
        return ax * by == ay * bx and ax * bx + ay * by > 0;
    }
};

/// One non-vertical edge of an operand, its left end first.
const Edge = struct {
    x0: i64,
    y0: i64,
    x1: i64,
    /// Rise per unit of x: -1, 0 or 1.
    slope: i64,
    /// `+1` where the ring runs toward `+x` (material above), else `-1`.
    wind: i32,
    /// The right operand's.
    right: bool,

    fn yAt(e: Edge, x: i64) i64 {
        return e.y0 + e.slope * (x - e.x0);
    }

    fn lessThan(_: void, a: Edge, b: Edge) bool {
        return a.x0 < b.x0;
    }
};

/// The order of two edges just right of `x`: by height at `x`, then slope.
const OrderAt = struct {
    edges: []const Edge,
    x: i64,

    fn lessThan(c: OrderAt, p: u32, q: u32) bool {
        const e = c.edges[p];
        const f = c.edges[q];
        const ye = e.yAt(c.x);
        const yf = f.yAt(c.x);
        return ye < yf or (ye == yf and e.slope < f.slope);
    }
};

/// One ray out of a boundary point: its direction, whether it leaves the
/// point, and its piece.
const Ray = struct {
    dir: [2]i64,
    out: bool,
    piece: u32,

    fn lessThan(_: void, a: Ray, b: Ray) bool {
        return ops.angleCmp(a.dir, b.dir) == .lt;
    }
};

/// The rings of `op(a, b)` into `out` (cleared and refilled), at the doubled
/// scale the operands are given at. Cost: `O(s · k)` for `s` slabs
/// (vertices plus crossings) and `k` edges crossing a slab.
pub fn combineInto(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try edgesInto(gpa, a, false, &edges);
    try edgesInto(gpa, b, true, &edges);
    std.mem.sort(Edge, edges.items, {}, Edge.lessThan);

    var xs: std.ArrayList(i64) = .empty;
    defer xs.deinit(gpa);
    try xs.appendSlice(gpa, a.xs.items);
    try xs.appendSlice(gpa, b.xs.items);
    std.mem.sortUnstable(i64, xs.items, {}, std.sort.asc(i64));
    xs.shrinkRetainingCapacity(dedupI64(xs.items));

    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(gpa);
    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(gpa);
    // Heights at `x` where the slab ending there changes answer.
    var left: std.ArrayList(i64) = .empty;
    defer left.deinit(gpa);
    var starts: std.ArrayList(i64) = .empty;
    defer starts.deinit(gpa);
    var ends: std.ArrayList(i64) = .empty;
    defer ends.deinit(gpa);
    var next_edge: usize = 0;
    var next_vertex: usize = 0;
    if (xs.items.len == 0) return link(gpa, pieces.items, out);
    var x = xs.items[0];

    while (true) {
        while (next_vertex < xs.items.len and xs.items[next_vertex] <= x) next_vertex += 1;
        var kept: usize = 0;
        for (active.items) |e| {
            if (edges.items[e].x1 <= x) continue;
            active.items[kept] = e;
            kept += 1;
        }
        active.shrinkRetainingCapacity(kept);
        while (next_edge < edges.items.len and edges.items[next_edge].x0 <= x) : (next_edge += 1) {
            try active.append(gpa, @intCast(next_edge));
        }
        // Stable and adaptive: the order only changes where edges cross at `x`.
        std.mem.sort(u32, active.items, OrderAt{ .edges = edges.items, .x = x }, OrderAt.lessThan);

        if (next_vertex == xs.items.len) {
            // Past the last vertex every edge has ended.
            assert(active.items.len == 0);
            try verticals(gpa, x, left.items, &.{}, &pieces);
            break;
        }
        // The slab runs to the next vertex or the nearest crossing of two
        // neighbours, whichever is first; neighbours cross first
        // (Bentley-Ottmann), so no two edges cross inside it.
        var next = xs.items[next_vertex];
        for (active.items[0..active.items.len -| 1], active.items[@min(1, active.items.len)..]) |p, q| {
            const e = edges.items[p];
            const f = edges.items[q];
            if (e.slope > f.slope) {
                const gap = f.yAt(x) - e.yAt(x);
                const rate = e.slope - f.slope;
                assert(gap > 0 and @rem(gap, rate) == 0);
                next = @min(next, x + @divExact(gap, rate));
            }
        }

        starts.clearRetainingCapacity();
        ends.clearRetainingCapacity();
        var in_a: i32 = 0;
        var in_b: i32 = 0;
        var inside = false;
        var k: usize = 0;
        while (k < active.items.len) {
            const head = edges.items[active.items[k]];
            const y = head.yAt(x);
            // Edges on one line through this slab are one boundary candidate.
            while (k < active.items.len) : (k += 1) {
                const e = edges.items[active.items[k]];
                if (e.yAt(x) != y or e.slope != head.slope) break;
                if (e.right) in_b += e.wind else in_a += e.wind;
            }
            const above = op.apply(in_a != 0, in_b != 0);
            if (above == inside) continue;
            const y_end = head.yAt(next);
            // Material above: run toward +x; below: toward -x.
            try pieces.append(gpa, if (above) .{ .sx = x, .sy = y, .ex = next, .ey = y_end } else .{ .sx = next, .sy = y_end, .ex = x, .ey = y });
            try starts.append(gpa, y);
            try ends.append(gpa, y_end);
            inside = above;
        }
        // Every operand's winding returns to zero above it.
        assert(!inside);
        try verticals(gpa, x, left.items, starts.items, &pieces);
        std.mem.swap(std.ArrayList(i64), &left, &ends);
        x = next;
    }
    try link(gpa, pieces.items, out);
}

/// Walks boundary pieces into rings, flat into `out` (cleared and refilled).
/// Where several pieces arrive at a point, each continues along the
/// departure next counter-clockwise from the way it came in, across the
/// empty sector to its right: every empty sector stays apart and the
/// material sectors join, the connected corner model at any angle. A run of
/// collinear pieces through a point no other piece visits is one edge.
pub fn link(gpa: Allocator, pieces: []const Piece, out: *Rings) Allocator.Error!void {
    const count = pieces.len;
    const by_head = try gpa.alloc(u32, count);
    defer gpa.free(by_head);
    const by_tail = try gpa.alloc(u32, count);
    defer gpa.free(by_tail);
    for (by_head, by_tail, 0..) |*h, *t, i| {
        h.* = @intCast(i);
        t.* = @intCast(i);
    }
    std.mem.sortUnstable(u32, by_head, pieces, struct {
        fn lessThan(p: []const Piece, a: u32, b: u32) bool {
            return std.mem.order(i64, &p[a].head(), &p[b].head()) == .lt;
        }
    }.lessThan);
    std.mem.sortUnstable(u32, by_tail, pieces, struct {
        fn lessThan(p: []const Piece, a: u32, b: u32) bool {
            return std.mem.order(i64, &p[a].tail(), &p[b].tail()) == .lt;
        }
    }.lessThan);
    const next = try gpa.alloc(u32, count);
    defer gpa.free(next);
    @memset(next, std.math.maxInt(u32));
    // Whether a piece's tail is reached by no other piece.
    const alone = try gpa.alloc(bool, count);
    defer gpa.free(alone);
    @memset(alone, true);
    var rays: std.ArrayList(Ray) = .empty;
    defer rays.deinit(gpa);

    var h: usize = 0;
    var t: usize = 0;
    while (t < count) {
        const point = pieces[by_tail[t]].tail();
        var t_end = t;
        while (t_end < count and std.mem.eql(i64, &pieces[by_tail[t_end]].tail(), &point)) t_end += 1;
        var h_end = h;
        while (h_end < count and std.mem.eql(i64, &pieces[by_head[h_end]].head(), &point)) h_end += 1;
        // A dropped piece would trace a ring of the wrong area.
        assert(h_end - h == t_end - t);
        if (t_end - t == 1) {
            next[by_tail[t]] = by_head[h];
        } else {
            rays.clearRetainingCapacity();
            for (by_tail[t..t_end]) |s| {
                const p = pieces[s];
                try rays.append(gpa, .{ .dir = .{ p.sx - p.ex, p.sy - p.ey }, .out = false, .piece = s });
                alone[s] = false;
            }
            for (by_head[h..h_end]) |s| {
                const p = pieces[s];
                try rays.append(gpa, .{ .dir = .{ p.ex - p.sx, p.ey - p.sy }, .out = true, .piece = s });
            }
            std.mem.sort(Ray, rays.items, {}, Ray.lessThan);
            for (rays.items, 0..) |r, k| {
                if (r.out) continue;
                const following = rays.items[(k + 1) % rays.items.len];
                // A region's boundary alternates in and out round a point.
                assert(following.out);
                next[r.piece] = following.piece;
            }
        }
        h = h_end;
        t = t_end;
    }

    try out.reset(gpa);
    const used = try gpa.alloc(bool, count);
    defer gpa.free(used);
    @memset(used, false);
    var cycle: std.ArrayList(u32) = .empty;
    defer cycle.deinit(gpa);
    for (0..count) |seed| {
        if (used[seed]) continue;
        cycle.clearRetainingCapacity();
        var cur = seed;
        while (true) {
            used[cur] = true;
            try cycle.append(gpa, @intCast(cur));
            cur = next[cur];
            if (cur == seed) break;
            // `next` is a permutation.
            assert(!used[cur]);
        }
        const c = cycle.items;
        for (c, 0..) |s, k| {
            const before = c[(k + c.len - 1) % c.len];
            if (alone[before] and pieces[before].sameWay(pieces[s])) continue;
            try out.push(gpa, pieces[s].sx, pieces[s].sy);
        }
        try out.closeRing(gpa);
    }
}

/// Whether some vertex lies between grid points: an odd doubled coordinate.
pub fn offGrid(rings: *const Rings) bool {
    for (rings.xs.items) |c| if (@rem(c, 2) != 0) return true;
    for (rings.ys.items) |c| if (@rem(c, 2) != 0) return true;
    return false;
}

/// Every ring with each vertex between grid points snapped onto the grid,
/// into `out` (cleared and refilled), at doubled scale. Such a vertex is
/// where a rising and a falling 45-degree edge meet, at `(i + ½, j + ½)`; it
/// is replaced by the two grid points half a diagonal step from it, back
/// along its way in and on along its way out, joined by a unit axis edge:
/// the tip of the right angle is cut off. A convex corner loses a
/// quarter-unit triangle, a concave one gains one, and a pinch becomes a neck
/// one unit wide. The rings may then hold a slit or a vanished sliver, which
/// a pass through `combineInto` removes.
pub fn snapInto(gpa: Allocator, rings: *const Rings, out: *Rings) Allocator.Error!void {
    try out.reset(gpa);
    for (0..rings.count()) |k| {
        const lo, const hi = rings.range(k);
        const n = hi - lo;
        for (0..n) |i| {
            const x = rings.xs.items[lo + i];
            const y = rings.ys.items[lo + i];
            if (@rem(x, 2) == 0) {
                // A crossing is on the grid or at a half-grid point.
                assert(@rem(y, 2) == 0);
                try out.push(gpa, x, y);
                continue;
            }
            const back = lo + (i + n - 1) % n;
            const on = lo + (i + 1) % n;
            const in_x = std.math.sign(x - rings.xs.items[back]);
            const in_y = std.math.sign(y - rings.ys.items[back]);
            const out_x = std.math.sign(rings.xs.items[on] - x);
            const out_y = std.math.sign(rings.ys.items[on] - y);
            // Only two diagonals pass a half-grid point.
            assert(in_x != 0 and in_y != 0 and out_x != 0 and out_y != 0);
            try out.push(gpa, x - in_x, y - in_y);
            try out.push(gpa, x + out_x, y + out_y);
        }
        try out.closeRing(gpa);
    }
}

// ---- private ----

fn dedupI64(items: []i64) usize {
    var kept: usize = 0;
    for (items) |v| {
        if (kept > 0 and items[kept - 1] == v) continue;
        items[kept] = v;
        kept += 1;
    }
    return kept;
}

/// Every non-vertical edge of one operand, appended. Asserts each is
/// octilinear: a skew edge would cross others between grid points.
fn edgesInto(gpa: Allocator, rings: *const Rings, right: bool, out: *std.ArrayList(Edge)) Allocator.Error!void {
    for (0..rings.count()) |k| {
        const lo, const hi = rings.range(k);
        const n = hi - lo;
        for (0..n) |i| {
            const a = lo + i;
            const b = lo + (i + 1) % n;
            const xa = rings.xs.items[a];
            const ya = rings.ys.items[a];
            const xb = rings.xs.items[b];
            const yb = rings.ys.items[b];
            if (xa == xb) continue;
            const dx = xb - xa;
            const dy = yb - ya;
            assert(dy == 0 or @abs(dy) == @abs(dx));
            try out.append(gpa, .{
                .x0 = @min(xa, xb),
                .y0 = if (xa < xb) ya else yb,
                .x1 = @max(xa, xb),
                .slope = std.math.sign(dy) * std.math.sign(dx),
                .wind = if (xb > xa) 1 else -1,
                .right = right,
            });
        }
    }
}

/// The boundary pieces on the vertical line `x`: where the answer just left
/// of it (`left`, the heights at which the slab ending at `x` changes
/// answer) differs from the answer just right of it (`right`). Material on
/// the left of a piece: up where the left side is inside. One piece per gap
/// between consecutive heights, so a piece never passes a point where
/// another boundary piece ends.
fn verticals(gpa: Allocator, x: i64, left: []const i64, right: []const i64, pieces: *std.ArrayList(Piece)) Allocator.Error!void {
    var i: usize = 0;
    var j: usize = 0;
    var left_in = false;
    var right_in = false;
    const max = std.math.maxInt(i64);
    while (i < left.len or j < right.len) {
        const y = @min(if (i < left.len) left[i] else max, if (j < right.len) right[j] else max);
        while (i < left.len and left[i] == y) : (i += 1) left_in = !left_in;
        while (j < right.len and right[j] == y) : (j += 1) right_in = !right_in;
        if (left_in == right_in) continue;
        // Both sides are outside above their last height, so one follows.
        const above = @min(if (i < left.len) left[i] else max, if (j < right.len) right[j] else max);
        const from, const to = if (left_in) .{ y, above } else .{ above, y };
        try pieces.append(gpa, .{ .sx = x, .sy = from, .ex = x, .ey = to });
    }
}
