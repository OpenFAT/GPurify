//! The edges of a merged layer as the facing kinds read them: each maximal
//! edge with its orientation, the way it faces, its corners and the lengths
//! of its neighbours, sorted so the edges facing back at one lie in one
//! band; the pairs that face across empty space; and one report per pair of
//! figures. In: a merged `ValidatedLayer`. Out: sorted `Edge` rows, visits,
//! violations. Ported from crates/check/src/drc/rules/facing.rs (`Edge`,
//! `figure_edges`, `each_facing`, `Hit`, `report_pairs`, `hit`,
//! `keep_out_box`, `near`, `sides_hold`).
//!
//! Contents:
//! - `pub const Edge = struct`, `Edge.length(e: Edge) i64`, `pub fn lessEdge(_: void, a: Edge, b: Edge) bool`
//! - `pub fn figureEdgesInto(gpa: Allocator, figures: *const ValidatedLayer, out: *std.ArrayList(Edge)) Allocator.Error!void`
//! - `pub fn bandStart(edges: []const Edge, vertical: bool, faces_up: bool, pos: i64) usize`
//! - `pub fn eachFacing(edges: []const Edge, reach: i64, visitor: anytype) !void`
//! - `pub const Hit = struct`, `pub fn hit(e: Edge, f: Edge, gap: i64, lo: i64, hi: i64, need: i64) Hit`
//! - `pub fn reportPairs(c: *const Ctx, layer: LayerId, owners: []const PolyId, hits: []Hit) Allocator.Error!void`
//! - `pub fn keepOutBox(end: Edge, backward: i64, side: i64, forward: i64) Bbox`
//! - `pub fn nearInto(gpa: Allocator, edges: []const Edge, area: Bbox, out: *std.ArrayList(u32)) Allocator.Error!void`
//! - `pub fn sidesHold(e: Edge, side: ?SideLength) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ValidatedLayer = geom.ValidatedLayer;
const proximity = @import("../proximity.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const runs_ = @import("runs.zig");

/// One edge of a merged figure. Sorted by orientation, then the way it
/// faces, then its line and span (`lessEdge`).
pub const Edge = struct {
    /// The edge runs along y (its line is `x = pos`).
    vertical: bool,
    /// It faces toward higher coordinates: its material lies below its line
    /// (left of it, for a vertical edge).
    faces_up: bool,
    pos: i64,
    lo: i64,
    hi: i64,
    /// The merged figure it bounds.
    figure: u32,
    /// Both of its corners are convex: a line end's corners.
    convex: bool,
    /// The lengths of the edges meeting it at its low and high end.
    sides: [2]i64,

    pub fn length(e: Edge) i64 {
        return e.hi - e.lo;
    }
};

/// One offending approach between two figures: the figures (lower first),
/// the gap judged, the space it needed, and the stretch of each side.
pub const Hit = struct { a: u32, b: u32, gap: i64, need: i64, p: Seg, q: Seg };

pub fn lessEdge(_: void, a: Edge, b: Edge) bool {
    return std.mem.order(i64, &keyOf(a), &keyOf(b)) == .lt;
}

/// Every edge of every figure (a merged layer, so each edge is a maximal
/// run with its material on its left), sorted, into `out`.
pub fn figureEdgesInto(gpa: Allocator, figures: *const ValidatedLayer, out: *std.ArrayList(Edge)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (0..figures.len()) |figure| {
        const poly = figures.get(@intCast(figure));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            const n = ring.xs.len;
            for (0..n) |i| {
                const l = runs_.lineOf(geom.ops.ringEdge(ring.xs, ring.ys, i));
                if (l.hi <= l.lo) continue;
                const before = edgeLength(ring, (i + n - 1) % n);
                const after = edgeLength(ring, (i + 1) % n);
                try out.append(gpa, .{
                    .vertical = l.vertical,
                    // Material on the left: an up-travelling vertical edge
                    // faces +x, a left-travelling horizontal one +y.
                    .faces_up = l.forward == l.vertical,
                    .pos = l.pos,
                    .lo = l.lo,
                    .hi = l.hi,
                    .figure = @intCast(figure),
                    .convex = convexAt(ring, i) and convexAt(ring, (i + 1) % n),
                    // The edge before meets this one at its start, the low
                    // end when it travels up.
                    .sides = if (l.forward) .{ before, after } else .{ after, before },
                });
            }
        }
    }
    std.mem.sortUnstable(Edge, out.items, {}, lessEdge);
}

/// The first edge at or past `(vertical, faces_up, pos)` in sort order.
pub fn bandStart(edges: []const Edge, vertical: bool, faces_up: bool, pos: i64) usize {
    const probe = [3]i64{ @intFromBool(vertical), @intFromBool(faces_up), pos };
    return std.sort.partitionPoint(Edge, edges, probe, struct {
        fn before(p: [3]i64, e: Edge) bool {
            const k = keyOf(e);
            return std.mem.order(i64, k[0..3], &p) == .lt;
        }
    }.before);
}

/// Calls `visitor.visit(e, f, gap, lo, hi)` for every two edges (sorted)
/// that face each other across empty space at most `reach` apart over a
/// positive run: the edge facing up first, then the one facing down from
/// above it. Edges whose spans meet only at a point do not face.
pub fn eachFacing(edges: []const Edge, reach: i64, visitor: anytype) !void {
    for (edges) |e| {
        if (!e.faces_up) continue;
        // ponytail: every down edge within `reach` above each up edge;
        // quadratic only where many edges share one `reach`-wide band.
        var at = bandStart(edges, e.vertical, false, e.pos + 1);
        while (at < edges.len) : (at += 1) {
            const f = edges[at];
            if (f.vertical != e.vertical or f.faces_up or f.pos - e.pos > reach) break;
            const lo = @max(e.lo, f.lo);
            const hi = @min(e.hi, f.hi);
            if (hi > lo) try visitor.visit(e, f, f.pos - e.pos, lo, hi);
        }
    }
}

/// The hit for facing edges `e` and `f` of different figures, `gap` apart
/// over `lo..hi`, that needed `need`.
pub fn hit(e: Edge, f: Edge, gap: i64, lo: i64, hi: i64, need: i64) Hit {
    return .{ .a = @min(e.figure, f.figure), .b = @max(e.figure, f.figure), .gap = gap, .need = need, .p = runs_.onLine(e.vertical, e.pos, lo, hi), .q = runs_.onLine(f.vertical, f.pos, lo, hi) };
}

/// One violation per pair of figures among `hits` (sorted in place): its
/// smallest gap, held to the largest need at that gap, at the middle of
/// their nearest stretches; the shapes are the figures' `owners`.
pub fn reportPairs(c: *const Ctx, layer: LayerId, owners: []const PolyId, hits: []Hit) Allocator.Error!void {
    std.mem.sortUnstable(Hit, hits, {}, struct {
        fn less(_: void, x: Hit, y: Hit) bool {
            return std.mem.order(i64, &.{ x.a, x.b, x.gap }, &.{ y.a, y.b, y.gap }) == .lt;
        }
    }.less);
    var at: usize = 0;
    while (at < hits.len) {
        var end = at;
        while (end < hits.len and hits[end].a == hits[at].a and hits[end].b == hits[at].b) end += 1;
        const gap = hits[at].gap;
        var need: i64 = std.math.minInt(i64);
        var nearest: proximity.Nearest = .{};
        defer nearest.deinit(c.gpa);
        for (hits[at..end]) |h| {
            if (h.gap != gap) break;
            need = @max(need, h.need);
            try nearest.add(c.gpa, h.p, h.q);
        }
        try c.push(proximity.spacingViolation(c.rule, layer, owners[hits[at].a], owners[hits[at].b], nearest.result().?, need));
        at = end;
    }
}

/// The keep-out box of the end of line `end`: its span widened by `side`
/// each side, from `backward` behind its line to `forward` past it, clamped
/// to the coordinate domain.
pub fn keepOutBox(end: Edge, backward: i64, side: i64, forward: i64) Bbox {
    const along_lo = clamped(end.lo - side);
    const along_hi = clamped(end.hi + side);
    const across_lo = clamped(if (end.faces_up) end.pos - backward else end.pos - forward);
    const across_hi = clamped(if (end.faces_up) end.pos + forward else end.pos + backward);
    return if (end.vertical)
        .{ .xlo = across_lo, .ylo = along_lo, .xhi = across_hi, .yhi = along_hi }
    else
        .{ .xlo = along_lo, .ylo = across_lo, .xhi = along_hi, .yhi = across_hi };
}

/// The indices of the edges whose segment meets `area`, its boundary
/// included, into `out`, by band.
pub fn nearInto(gpa: Allocator, edges: []const Edge, area: Bbox, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for ([4][2]bool{ .{ false, false }, .{ false, true }, .{ true, false }, .{ true, true } }) |band| {
        const vertical = band[0];
        // A vertical edge's line is an x, its span a stretch of y.
        const lo = if (vertical) area.xlo else area.ylo;
        const hi = if (vertical) area.xhi else area.yhi;
        const along_lo = if (vertical) area.ylo else area.xlo;
        const along_hi = if (vertical) area.yhi else area.xhi;
        // ponytail: every edge of the band across `area`, filtered along it.
        var at = bandStart(edges, vertical, band[1], lo);
        while (at < edges.len) : (at += 1) {
            const e = edges[at];
            if (e.vertical != vertical or e.faces_up != band[1] or e.pos > hi) break;
            if (e.lo <= along_hi and along_lo <= e.hi) try out.append(gpa, @intCast(at));
        }
    }
}

/// `MINLENGTH [TWOSIDES]` / `MAXLENGTH`: whether the edges meeting `e` (both
/// with `two_sides`) are at least (at most with `maximum`) the side length;
/// true with none.
pub fn sidesHold(e: Edge, side: ?rows.SideLength) bool {
    const s = side orelse return true;
    const holds = struct {
        fn f(sl: rows.SideLength, l: i64) bool {
            return if (sl.maximum) l <= sl.length else l >= sl.length;
        }
    }.f;
    const first = holds(s, e.sides[0]);
    const second = holds(s, e.sides[1]);
    return if (s.two_sides) first and second else first or second;
}

// ---- private ----

fn keyOf(e: Edge) [9]i64 {
    return .{ @intFromBool(e.vertical), @intFromBool(e.faces_up), e.pos, e.lo, e.hi, e.figure, @intFromBool(e.convex), e.sides[0], e.sides[1] };
}

/// A left turn at vertex `i` is a convex corner: the material is on the
/// left of travel, outer rings and holes alike.
fn convexAt(ring: geom.Ring, i: usize) bool {
    const n = ring.xs.len;
    const back = (i + n - 1) % n;
    const next = (i + 1) % n;
    return geom.mulWide(ring.xs[i] - ring.xs[back], ring.ys[next] - ring.ys[i]) > geom.mulWide(ring.ys[i] - ring.ys[back], ring.xs[next] - ring.xs[i]);
}

/// Edge `i`'s length, Manhattan.
fn edgeLength(ring: geom.Ring, i: usize) i64 {
    const j = (i + 1) % ring.xs.len;
    return @intCast(@abs(ring.xs[j] - ring.xs[i]) + @abs(ring.ys[j] - ring.ys[i]));
}

fn clamped(v: i64) i64 {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
