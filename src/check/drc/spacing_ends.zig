//! End-of-line and corner-to-corner spacing: pairs judged only where one
//! shape faces an end of line of the merged layer, or where convex corners
//! of the two face each other. In: one rectilinear layer. Out: one violation
//! per offending pair, at the midpoint of its nearest measured points.
//! Ported from crates/check/src/drc/rules/spacing.rs (`eol_spacing`,
//! `eol_zone`, `eol_hits`, `corner_to_corner`, `convex_corners`,
//! `corner_gap`).
//!
//! Contents:
//! - `pub fn eolSpacing(c: *const Ctx, r: EolSpacing) Error!Verdict`
//! - `pub fn cornerToCorner(c: *const Ctx, r: LayerLimit) Error!Verdict`
//! - `pub fn eolZone(edge: Seg, depth: Dbu) Bbox`
//! - private judges with the `measure` and `at` methods `judgedPairs` calls

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const proximity = @import("../proximity.zig");
const Nearest = proximity.Nearest;
const rows = @import("rows.zig");
const tables = @import("tables.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const runs_ = @import("runs.zig");
const Line = runs_.Line;
const parts = @import("parts.zig");

/// An end of line of the merged layer: its edge and that edge on its line.
const End = struct { line: Line, edge: Seg };

/// A convex corner: its vertex, then the diagonal it faces out along, each
/// component ±1. Ordered field by field.
const Corner = [4]i64;

/// Judges a pair at the nearest approach of either shape to an end of line
/// the other lies on.
const EolJudge = struct {
    store: *const GeometryStore,
    ends: []const End,
    eol_width: Dbu,
    limit: Dbu,

    pub fn measure(j: EolJudge, a: PolyId, b: PolyId, _: DbuArea) ?DbuArea {
        var least: Least = .{};
        eolHits(j, a, b, &least, Least.add) catch unreachable;
        eolHits(j, b, a, &least, Least.add) catch unreachable;
        return least.d2;
    }

    pub fn at(j: EolJudge, gpa: Allocator, a: PolyId, b: PolyId, d2: DbuArea) Allocator.Error!Point {
        var n: Collect = .{ .gpa = gpa };
        defer n.nearest.deinit(gpa);
        try eolHits(j, a, b, &n, Collect.add);
        try eolHits(j, b, a, &n, Collect.add);
        return parts.marker(j.store, a, b, d2, n.nearest.result());
    }
};

/// Judges a pair at its nearest facing convex corners.
const CornerJudge = struct {
    store: *const GeometryStore,
    corners: []const Corner,

    pub fn measure(j: CornerJudge, a: PolyId, b: PolyId, _: DbuArea) ?DbuArea {
        var least: Least = .{};
        cornerPairs(j, a, b, &least, Least.add) catch unreachable;
        return least.d2;
    }

    pub fn at(j: CornerJudge, gpa: Allocator, a: PolyId, b: PolyId, d2: DbuArea) Allocator.Error!Point {
        var n: Collect = .{ .gpa = gpa };
        defer n.nearest.deinit(gpa);
        try cornerPairs(j, a, b, &n, Collect.add);
        return parts.marker(j.store, a, b, d2, n.nearest.result());
    }
};

/// The least squared distance over the pairs fed to it.
const Least = struct {
    d2: ?DbuArea = null,

    fn add(l: *Least, p: Seg, q: Seg) error{}!void {
        const d = geom.ops.segSegDist2(p, q);
        l.d2 = if (l.d2) |old| @min(old, d) else d;
    }
};

/// The nearest approach over the pairs fed to it.
const Collect = struct {
    gpa: Allocator,
    nearest: Nearest = .{},

    fn add(c: *Collect, p: Seg, q: Seg) Allocator.Error!void {
        return c.nearest.add(c.gpa, p, q);
    }
};

/// End-of-line spacing, the ends read off the merged layer. `examined`
/// counts separate pairs where either shape lies on an end of line facing
/// the other.
pub fn eolSpacing(c: *const Ctx, r: rows.EolSpacing) Error!Verdict {
    const s = &c.s.p;
    if (!try proximity.prepareMerged(c.gpa, c.store, r.layer, r.limit, s)) return report.refused;
    var edges: std.ArrayList(Seg) = .empty;
    defer edges.deinit(c.gpa);
    try geom.derive.edgesInto(c.gpa, &s.layer_out, &edges);
    var ends: std.ArrayList(End) = .empty;
    defer ends.deinit(c.gpa);
    for (edges.items) |e| {
        const l = runs_.lineOf(e);
        if (tables.isEndOfLine(l.hi - l.lo, r.eol_width)) try ends.append(c.gpa, .{ .line = l, .edge = e });
    }
    std.mem.sortUnstable(End, ends.items, {}, lessEnd);
    const judge: EolJudge = .{ .store = c.store, .ends = ends.items, .eol_width = r.eol_width, .limit = r.limit };
    return scratch.ran(try proximity.judgedPairs(c.gpa, c.store, c.rule, r.layer, r.limit, s, c.out, judge));
}

/// Corner-to-corner spacing between convex corners of the merged layer that
/// face each other. `examined` counts separate pairs with facing corners.
pub fn cornerToCorner(c: *const Ctx, r: rows.LayerLimit) Error!Verdict {
    const s = &c.s.p;
    if (!try proximity.prepareMerged(c.gpa, c.store, r.layer, r.limit, s)) return report.refused;
    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(c.gpa);
    for (0..s.layer_out.len()) |idx| {
        const poly = s.layer_out.get(@intCast(idx));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            for (0..ring.xs.len) |i| if (convexCorner(ring, i)) |corner| try corners.append(c.gpa, corner);
        }
    }
    std.mem.sortUnstable(Corner, corners.items, {}, lessCorner);
    const judge: CornerJudge = .{ .store = c.store, .corners = corners.items };
    return scratch.ran(try proximity.judgedPairs(c.gpa, c.store, c.rule, r.layer, r.limit, s, c.out, judge));
}

/// The keep-out an end of line projects: its span pushed `depth` out of its
/// material (to the right of travel), clamped to the coordinate domain.
pub fn eolZone(edge: Seg, depth: Dbu) Bbox {
    // Out of the material: the direction of travel turned clockwise.
    const nx = std.math.sign(edge.b.y - edge.a.y);
    const ny = -std.math.sign(edge.b.x - edge.a.x);
    const span = rects.segBbox(edge);
    return .{
        .xlo = clamped(span.xlo + @min(nx, 0) * depth),
        .ylo = clamped(span.ylo + @min(ny, 0) * depth),
        .xhi = clamped(span.xhi + @max(nx, 0) * depth),
        .yhi = clamped(span.yhi + @max(ny, 0) * depth),
    };
}

// ---- private ----

/// Feeds `sink` each part of an end of line `eol` draws with each edge of
/// `other` reaching into that end's keep-out. A drawn edge lies on an end
/// when they share a line, a direction and a stretch of it.
fn eolHits(j: EolJudge, eol: PolyId, other: PolyId, sink: anytype, comptime add: anytype) !void {
    const ring = j.store.polyVerts(eol);
    const far = j.store.polyVerts(other);
    for (0..ring.xs.len) |i| {
        const l = runs_.lineOf(geom.ops.ringEdge(ring.xs, ring.ys, i));
        // An end overlapping this edge is shorter than `eol_width`: it starts past this.
        const probe: Line = .{ .vertical = l.vertical, .pos = l.pos, .forward = l.forward, .lo = l.lo - j.eol_width, .hi = std.math.minInt(i64) };
        var at = std.sort.partitionPoint(End, j.ends, probe, struct {
            fn before(p: Line, e: End) bool {
                return runs_.lessLine({}, e.line, p);
            }
        }.before);
        while (at < j.ends.len) : (at += 1) {
            const e = j.ends[at];
            if (e.line.vertical != l.vertical or e.line.pos != l.pos or e.line.forward != l.forward or e.line.lo >= l.hi) break;
            if (e.line.hi <= l.lo) continue;
            const zone = eolZone(e.edge, j.limit);
            const piece = runs_.onLine(l.vertical, l.pos, @max(e.line.lo, l.lo), @min(e.line.hi, l.hi));
            for (0..far.xs.len) |k| {
                const f = geom.ops.ringEdge(far.xs, far.ys, k);
                if (zone.overlaps(rects.segBbox(f))) try add(sink, piece, f);
            }
        }
    }
}

/// Feeds `sink` every pair of convex corners of the merged layer facing
/// each other, one at a vertex of `a` and one at a vertex of `b`: each
/// beyond the other on both axes, out along its own diagonal.
fn cornerPairs(j: CornerJudge, a: PolyId, b: PolyId, sink: anytype, comptime add: anytype) !void {
    const ra = j.store.polyVerts(a);
    const rb = j.store.polyVerts(b);
    for (0..ra.xs.len) |i| {
        const p = mergedCorner(j.corners, ra, i) orelse continue;
        for (0..rb.xs.len) |k| {
            const q = mergedCorner(j.corners, rb, k) orelse continue;
            const facing = std.math.sign(q[0] - p[0]) == p[2] and std.math.sign(q[1] - p[1]) == p[3] and q[2] == -p[2] and q[3] == -p[3];
            if (!facing) continue;
            const pp: Point = .{ .x = p[0], .y = p[1] };
            const qq: Point = .{ .x = q[0], .y = q[1] };
            try add(sink, .{ .a = pp, .b = pp }, .{ .a = qq, .b = qq });
        }
    }
}

/// Vertex `i` of `ring` as a convex corner that is also one of the merged
/// layer's, else null.
fn mergedCorner(corners: []const Corner, ring: geom.Ring, i: usize) ?Corner {
    const corner = convexCorner(ring, i) orelse return null;
    const at = std.sort.lowerBound(Corner, corners, corner, orderCorner);
    return if (at < corners.len and std.mem.eql(i64, &corners[at], &corner)) corner else null;
}

/// Vertex `i` of a ring wound with its material on the left, when it turns
/// left: its point and its outward diagonal (along the edge coming in,
/// against the one leaving).
fn convexCorner(ring: geom.Ring, i: usize) ?Corner {
    const n = ring.xs.len;
    const back = (i + n - 1) % n;
    const next = (i + 1) % n;
    const inx = ring.xs[i] - ring.xs[back];
    const iny = ring.ys[i] - ring.ys[back];
    const outx = ring.xs[next] - ring.xs[i];
    const outy = ring.ys[next] - ring.ys[i];
    if (!(geom.mulWide(inx, outy) > geom.mulWide(iny, outx))) return null;
    return .{ ring.xs[i], ring.ys[i], std.math.sign(inx - outx), std.math.sign(iny - outy) };
}

fn lessEnd(_: void, x: End, y: End) bool {
    return runs_.lessLine({}, x.line, y.line) or (!runs_.lessLine({}, y.line, x.line) and lessSeg(x.edge, y.edge));
}

fn lessSeg(x: Seg, y: Seg) bool {
    const kx = [4]i64{ x.a.x, x.a.y, x.b.x, x.b.y };
    const ky = [4]i64{ y.a.x, y.a.y, y.b.x, y.b.y };
    return std.mem.order(i64, &kx, &ky) == .lt;
}

fn lessCorner(_: void, x: Corner, y: Corner) bool {
    return std.mem.order(i64, &x, &y) == .lt;
}

fn orderCorner(want: Corner, item: Corner) std.math.Order {
    return std.mem.order(i64, &want, &item);
}

fn clamped(v: i64) Dbu {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
