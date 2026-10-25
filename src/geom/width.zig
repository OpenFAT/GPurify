//! Widths and notches of one validated polygon. In: a `Polygon`. Out: the
//! narrowest distance across its material (width) or across empty space
//! between its own edges (notch), and where it is. A scanline sweep per axis
//! finds facing rectilinear edges, a corner scan the diagonal necks, and an
//! edge-pair scan the octilinear and any-angle measures. Exact on the whole
//! domain but where a length is floored (`narrowestWidth2` keeps it
//! squared). Ported from crates/geom/src/width.rs.
//!
//! Contents:
//! - `pub const Gap = enum { width, notch }`
//! - `pub const Found = struct { gap: Dbu, at: Point }`, `pub const Found2 = struct { d2: i128, at: Point }`,
//!   `pub const FoundAny = struct { d2: Twice, at: Point }`
//! - `pub const EdgeIter = struct`, `EdgeIter.next(it: *EdgeIter) ?Seg`, `pub fn polyEdges(poly: Polygon) EdgeIter`
//! - `pub const FacingScratch = struct`, `FacingScratch.deinit(s: *FacingScratch, gpa: Allocator) void`
//! - `pub fn narrowestFacing(gpa: Allocator, poly: Polygon, gap: Gap, scratch: *FacingScratch) Allocator.Error!?Found`
//! - `pub fn narrowestWidth(gpa: Allocator, poly: Polygon, scratch: *FacingScratch) Allocator.Error!Dbu`
//! - `pub fn narrowestWidth2(gpa: Allocator, poly: Polygon, scratch: *FacingScratch) Allocator.Error!DbuArea`
//! - `pub fn narrowestNeck(gpa: Allocator, poly: Polygon, limit: Dbu) Allocator.Error!?Found`
//! - `pub fn narrowestPair2(gpa: Allocator, poly: Polygon, gap: Gap, limit: Dbu) Allocator.Error!?Found2`
//! - `pub fn narrowestPairAny(gpa: Allocator, poly: Polygon, gap: Gap, limit: Dbu) Allocator.Error!?FoundAny`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const DbuArea = dbu.DbuArea;
const ops = @import("ops.zig");
const Point = ops.Point;
const Seg = ops.Seg;
const Twice = ops.Twice;
const Polygon = @import("view.zig").Polygon;
const relation = @import("relation.zig");

/// Across the polygon's material (`width`), or across empty space between
/// its own edges (`notch`).
pub const Gap = enum { width, notch };

/// A gap in whole units and its midpoint.
pub const Found = struct { gap: Dbu, at: Point };

/// A gap as twice its square, exact, and the midpoint of its two nearest
/// points, floored.
pub const Found2 = struct { d2: i128, at: Point };

/// A gap at any angle as a `Twice`, and the midpoint of its nearest points.
pub const FoundAny = struct { d2: Twice, at: Point };

/// Every boundary edge of one polygon, outer ring first, then each hole,
/// the closing edge of each ring included.
pub const EdgeIter = struct {
    poly: Polygon,
    ring: u32 = 0,
    i: usize = 0,

    pub fn next(it: *EdgeIter) ?Seg {
        while (it.ring < it.poly.ringCount()) {
            const r = it.poly.ring(it.ring);
            if (it.i < r.xs.len) {
                defer it.i += 1;
                return ops.ringEdge(r.xs, r.ys, it.i);
            }
            it.ring += 1;
            it.i = 0;
        }
        return null;
    }
};

/// Buffers for one facing-pair sweep, refilled per polygon.
pub const FacingScratch = struct {
    edges: std.ArrayList(Edge) = .empty,
    /// Ascending `(coordinate, leave|enter, edge)`: spans are half-open.
    events: std.ArrayList(Event) = .empty,
    /// Edges crossing the scanline, sorted by `(pos, index)`.
    active: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *FacingScratch, gpa: Allocator) void {
        s.edges.deinit(gpa);
        s.events.deinit(gpa);
        s.active.deinit(gpa);
    }
};

/// One axis-aligned boundary edge: its coordinate across, its span along,
/// and whether its material lies on the greater-`pos` side (canonical
/// winding puts material left of travel on every ring, holes included).
const Edge = struct {
    pos: Dbu,
    lo: Dbu,
    hi: Dbu,
    material_above: bool,
    vertical: bool,
};

const Event = struct {
    at: Dbu,
    kind: enum(u1) { leave, enter },
    edge: u32,

    fn lessThan(_: void, a: Event, b: Event) bool {
        if (a.at != b.at) return a.at < b.at;
        if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
        return a.edge < b.edge;
    }
};

/// One concave corner and the diagonal its void quadrant points along.
const Corner = struct {
    x: i64,
    y: i64,
    vx: i64,
    vy: i64,

    fn lessThan(_: void, a: Corner, b: Corner) bool {
        inline for (.{ "x", "y", "vx", "vy" }) |f| {
            if (@field(a, f) != @field(b, f)) return @field(a, f) < @field(b, f);
        }
        return false;
    }
};

pub fn polyEdges(poly: Polygon) EdgeIter {
    return .{ .poly = poly };
}

/// The narrowest pair of facing rectilinear edges, across material (`.width`)
/// or empty space (`.notch`), and its midpoint; a tie keeps the vertical
/// sweep's. Only active-list neighbours can be narrowest, so each event
/// checks the pairs it disturbed.
pub fn narrowestFacing(gpa: Allocator, poly: Polygon, gap: Gap, scratch: *FacingScratch) Allocator.Error!?Found {
    scratch.edges.clearRetainingCapacity();
    var it = polyEdges(poly);
    while (it.next()) |s| {
        const e = edgeOf(s);
        // A zero-length edge has no material side.
        if (e.lo < e.hi) try scratch.edges.append(gpa, e);
    }
    const across = try sweepAxis(gpa, scratch, true, gap);
    const along = try sweepAxis(gpa, scratch, false, gap);
    if (across) |a| {
        if (along) |b| return if (b.gap < a.gap) b else a;
        return a;
    }
    return along;
}

/// The narrowest width, holes included, as the `width` rule measures it: the
/// least of the facing widths and the diagonal necks, a neck floored.
pub fn narrowestWidth(gpa: Allocator, poly: Polygon, scratch: *FacingScratch) Allocator.Error!Dbu {
    return ops.isqrt(try narrowestWidth2(gpa, poly, scratch));
}

/// `narrowestWidth` squared, exact: a diagonal neck of `√5000` is 5000.
pub fn narrowestWidth2(gpa: Allocator, poly: Polygon, scratch: *FacingScratch) Allocator.Error!DbuArea {
    // Every validated polygon has a facing pair across its own material.
    const facing_gap = (try narrowestFacing(gpa, poly, .width, scratch)).?.gap;
    if (try neck2(gpa, poly, facing_gap)) |n| return n.d2;
    return dbu.mulWide(facing_gap, facing_gap);
}

/// The narrowest diagonal neck under `limit`: the gap between two concave
/// corners facing each other across material, as at the inner corners of two
/// overlapping rectangles (KLayout's Euclidean width). Facing edges whose
/// projections overlap are `narrowestFacing`'s; this is the corner case it
/// cannot see. The gap is the floored root of the exact squared gap; the
/// comparison against `limit` is exact.
pub fn narrowestNeck(gpa: Allocator, poly: Polygon, limit: Dbu) Allocator.Error!?Found {
    const n = try neck2(gpa, poly, limit) orelse return null;
    return .{ .gap = ops.isqrt(n.d2), .at = n.at };
}

/// The narrowest width (`.width`) or notch of a polygon whose edges may lie
/// at 45 degrees, under `limit`, as twice its square, exact. The width is
/// the rectilinear one read at every octilinear angle (KLayout's Euclidean
/// `width` on antiparallel pairs), the least of: two antiparallel edges,
/// each strictly on the other's material side, at the distance between them
/// (IHP SG13G2 M1.g "45-degree bent width"; a neck past each other's ends);
/// antiparallel edges on one line that touch, or a corner on an edge, where
/// the figure meets itself: 0; an acute tip: 0; an axis edge and a 45-degree
/// one at 135 degrees, each with an end strictly on the other's material
/// side, between the parts of each on the other's material side (gf180mcu
/// `fd_pv` NW.1a). A notch is two antiparallel edges facing across empty
/// space over a stretch of positive length.
pub fn narrowestPair2(gpa: Allocator, poly: Polygon, gap: Gap, limit: Dbu) Allocator.Error!?Found2 {
    // ponytail: pairs within `limit` along x, O(n²) only when every edge sits
    // in one `limit`-wide column; a sweep by both axes if that gets slow.
    const edges = try edgesByX(gpa, poly);
    defer gpa.free(edges);
    var best: ?Found2 = null;
    const bound = 2 * dbu.mulWide(limit, limit);
    for (edges, 0..) |e, i| {
        const reach = @max(e.a.x, e.b.x) + limit;
        for (edges[i + 1 ..]) |f| {
            if (@min(f.a.x, f.b.x) > reach) break;
            const pair: ?[2]Seg = if (facing(e, f, gap)) .{ e, f } else if (gap == .width) slanted(e, f) else null;
            const p = pair orelse continue;
            const n = ops.segSegNear2(p[0], p[1]);
            keep2(&best, bound, n.d2, mid4(n.on_p2, n.on_q2));
        }
    }
    if (gap == .notch) return best;
    // An acute tip: a left turn by more than 90 degrees.
    for (0..poly.ringCount()) |k| {
        const r = poly.ring(@intCast(k));
        const n = r.xs.len;
        for (0..n) |c| {
            const p = (c + n - 1) % n;
            const q = (c + 1) % n;
            const back = [2]i128{ r.xs[p] - r.xs[c], r.ys[p] - r.ys[c] };
            const on = [2]i128{ r.xs[q] - r.xs[c], r.ys[q] - r.ys[c] };
            const turn = back[1] * on[0] - back[0] * on[1];
            const dot = back[0] * on[0] + back[1] * on[1];
            if (turn > 0 and dot > 0) keep2(&best, bound, 0, .{ .x = r.xs[c], .y = r.ys[c] });
        }
    }
    return best;
}

/// `narrowestPair2` at any angle, exact, as a `Twice`, and where it is (the
/// midpoint of its two nearest points, rounded). The width is KLayout's
/// Euclidean `width` at its default `angle_limit`: the least, over every
/// ordered pair of edges at more than 90 degrees, of the distance between the
/// parts of each on the other's material side (`relation.pairThresholdAny`
/// under `.width`). On octilinear figures it is `narrowestPair2`. A notch is
/// as `narrowestPair2` reads one.
pub fn narrowestPairAny(gpa: Allocator, poly: Polygon, gap: Gap, limit: Dbu) Allocator.Error!?FoundAny {
    const edges = try edgesByX(gpa, poly);
    defer gpa.free(edges);
    var best: ?FoundAny = null;
    const bound = 2 * dbu.mulWide(limit, limit);
    for (edges, 0..) |e, i| {
        const reach = @max(e.a.x, e.b.x) + limit;
        const ylo = @min(e.a.y, e.b.y);
        const yhi = @max(e.a.y, e.b.y);
        for (edges[i + 1 ..]) |f| {
            if (@min(f.a.x, f.b.x) > reach) break;
            if (@min(f.a.y, f.b.y) > yhi + limit or ylo > @max(f.a.y, f.b.y) + limit) continue;
            switch (gap) {
                .width => for ([2][2]Seg{ .{ e, f }, .{ f, e } }) |pq| {
                    const d2 = relation.pairThresholdAny(.width, .when_touching, reversed(pq[0]), reversed(pq[1])) orelse continue;
                    keepAny(&best, bound, d2, e, f);
                },
                .notch => if (facing(e, f, .notch)) keepAny(&best, bound, ops.segSegTwice2(e, f), e, f),
            }
        }
    }
    return best;
}

// ---- private ----

fn edgeOf(s: Seg) Edge {
    const vertical = s.a.x == s.b.x;
    const pos = if (vertical) s.a.x else s.a.y;
    const from = if (vertical) s.a.y else s.a.x;
    const to = if (vertical) s.b.y else s.b.x;
    // Travelling +y leaves material at -x; travelling +x leaves it at +y.
    return .{ .pos = pos, .lo = @min(from, to), .hi = @max(from, to), .material_above = (to > from) != vertical, .vertical = vertical };
}

/// Midpoint of two coordinates, floored on both sides of the origin.
fn mid(a: Dbu, b: Dbu) Dbu {
    return @divFloor(a + b, 2);
}

/// The gap between two facing edges and its midpoint, or null when they do
/// not face each other across material (`.width`) or a void (`.notch`).
fn facingPair(a: Edge, b: Edge, gap: Gap) ?Found {
    if (a.vertical != b.vertical) return null;
    const between = gap == .width;
    const near_e, const far_e = if (a.pos <= b.pos) .{ a, b } else .{ b, a };
    if (near_e.material_above != between or far_e.material_above == between) return null;
    const lo = @max(near_e.lo, far_e.lo);
    const hi = @min(near_e.hi, far_e.hi);
    if (hi <= lo) return null;
    const across = mid(near_e.pos, far_e.pos);
    const along = mid(lo, hi);
    const at: Point = if (a.vertical) .{ .x = across, .y = along } else .{ .x = along, .y = across };
    return .{ .gap = far_e.pos - near_e.pos, .at = at };
}

fn slotOf(edges: []const Edge, active: []const u32, edge: u32) usize {
    const want = edges[edge].pos;
    const Ctx = struct { edges: []const Edge, pos: Dbu, edge: u32 };
    return std.sort.partitionPoint(u32, active, Ctx{ .edges = edges, .pos = want, .edge = edge }, struct {
        fn before(c: Ctx, j: u32) bool {
            const p = c.edges[j].pos;
            return p < c.pos or (p == c.pos and j < c.edge);
        }
    }.before);
}

/// Folds the active pair `(right - 1, right)` into `best`; out of range is a
/// no-op.
fn consider(edges: []const Edge, active: []const u32, right: usize, gap: Gap, best: *?Found) void {
    if (right == 0 or right >= active.len) return;
    const found = facingPair(edges[active[right - 1]], edges[active[right]], gap) orelse return;
    if (best.* == null or found.gap < best.*.?.gap) best.* = found;
}

/// The narrowest facing pair among one axis's edges.
fn sweepAxis(gpa: Allocator, s: *FacingScratch, vertical: bool, gap: Gap) Allocator.Error!?Found {
    s.events.clearRetainingCapacity();
    s.active.clearRetainingCapacity();
    for (s.edges.items, 0..) |e, i| {
        if (e.vertical != vertical) continue;
        try s.events.append(gpa, .{ .at = e.lo, .kind = .enter, .edge = @intCast(i) });
        try s.events.append(gpa, .{ .at = e.hi, .kind = .leave, .edge = @intCast(i) });
    }
    std.mem.sortUnstable(Event, s.events.items, {}, Event.lessThan);
    const edges = s.edges.items;
    const events = s.events.items;
    var best: ?Found = null;
    var ev: usize = 0;
    while (ev < events.len) {
        const group = ev;
        while (ev < events.len and events[ev].at == events[group].at) : (ev += 1) {
            const slot = slotOf(edges, s.active.items, events[ev].edge);
            switch (events[ev].kind) {
                .enter => try s.active.insert(gpa, slot, events[ev].edge),
                .leave => _ = s.active.orderedRemove(slot),
            }
        }
        for (events[group..ev]) |e| {
            const slot = slotOf(edges, s.active.items, e.edge);
            consider(edges, s.active.items, slot, gap, &best);
            consider(edges, s.active.items, slot + 1, gap, &best);
        }
    }
    return best;
}

/// `narrowestNeck` with the gap squared, exact.
fn neck2(gpa: Allocator, poly: Polygon, limit: Dbu) Allocator.Error!?Found2 {
    // ponytail: pairs within `limit` along x, O(k²) only when every concave
    // corner sits in one `limit`-wide column.
    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(gpa);
    for (0..poly.ringCount()) |k| {
        const r = poly.ring(@intCast(k));
        const n = r.xs.len;
        for (0..n) |c| {
            const p = (c + n - 1) % n;
            const q = (c + 1) % n;
            const ix = r.xs[c] - r.xs[p];
            const iy = r.ys[c] - r.ys[p];
            const ox = r.xs[q] - r.xs[c];
            const oy = r.ys[q] - r.ys[c];
            // Material left of travel: a right turn is concave, and the void
            // lies back along the way in and on along the way out.
            if (@as(i128, ix) * oy - @as(i128, iy) * ox < 0) {
                try corners.append(gpa, .{ .x = r.xs[c], .y = r.ys[c], .vx = std.math.sign(ox - ix), .vy = std.math.sign(oy - iy) });
            }
        }
    }
    std.mem.sortUnstable(Corner, corners.items, {}, Corner.lessThan);
    var best: ?Found2 = null;
    const limit2 = dbu.mulWide(limit, limit);
    for (corners.items, 0..) |a, i| {
        for (corners.items[i + 1 ..]) |b| {
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            if (dx >= limit) break;
            // Opposite voids, and each corner on the other's material side.
            if (b.vx != -a.vx or b.vy != -a.vy or dx * a.vx > 0 or dy * a.vy > 0) continue;
            const gap2 = dbu.mulWide(dx, dx) + dbu.mulWide(dy, dy);
            if (gap2 < limit2 and (best == null or gap2 < best.?.d2)) {
                best = .{ .d2 = gap2, .at = .{ .x = @divFloor(a.x + b.x, 2), .y = @divFloor(a.y + b.y, 2) } };
            }
        }
    }
    return best;
}

/// Every edge of positive length, ascending by its least x: the order the
/// pair scans break on once an edge starts past the limit.
fn edgesByX(gpa: Allocator, poly: Polygon) Allocator.Error![]Seg {
    var list: std.ArrayList(Seg) = .empty;
    errdefer list.deinit(gpa);
    var it = polyEdges(poly);
    while (it.next()) |s| {
        if (!s.a.eql(s.b)) try list.append(gpa, s);
    }
    std.mem.sortUnstable(Seg, list.items, {}, struct {
        fn lessThan(_: void, a: Seg, b: Seg) bool {
            return @min(a.a.x, a.b.x) < @min(b.a.x, b.b.x);
        }
    }.lessThan);
    return list.toOwnedSlice(gpa);
}

/// The midpoint of two points given doubled, floored.
fn mid4(p: Point, q: Point) Point {
    return .{ .x = @divFloor(p.x + q.x, 4), .y = @divFloor(p.y + q.y, 4) };
}

/// A segment's direction, widened so products of two stay exact.
fn dir(s: Seg) [2]i128 {
    return .{ s.b.x - s.a.x, s.b.y - s.a.y };
}

fn reversed(s: Seg) Seg {
    return .{ .a = s.b, .b = s.a };
}

/// How far `of` is on `line`'s left, its material side, scaled.
fn sideOf(line: Seg, of: Point) i128 {
    const l = dir(line);
    return l[0] * (of.y - line.a.y) - l[1] * (of.x - line.a.x);
}

fn keep2(best: *?Found2, bound: i128, d2: i128, at: Point) void {
    if (d2 < bound and (best.* == null or d2 < best.*.?.d2)) best.* = .{ .d2 = d2, .at = at };
}

fn keepAny(best: *?FoundAny, bound: i128, d2: Twice, e: Seg, f: Seg) void {
    if (d2.floor >= bound) return;
    if (best.*) |b| if (!d2.lessThan(b.d2)) return;
    const n = ops.segSegNear2(e, f);
    best.* = .{ .d2 = d2, .at = mid4(n.on_p2, n.on_q2) };
}

/// The parts of `e` and `f` a width measures when they are at 135 degrees
/// to each other and each has an end strictly on the other's material side
/// (`euclidian_near_part_of_edge`): each cut to the other's material side,
/// line included. Null for any other pair.
fn slanted(e: Seg, f: Seg) ?[2]Seg {
    const u = dir(e);
    const v = dir(f);
    if (u[0] * v[1] == u[1] * v[0] or u[0] * v[0] + u[1] * v[1] >= 0) return null;
    // Two edges that touch and do not follow one another, as where a corner
    // lies on an edge: KLayout's zero distance when touching counts the line
    // as the material side, so the pair is at 0 unless one lies wholly off
    // the other's material side.
    if (ops.segmentsIntersect(e, f) and !e.b.eql(f.a) and !e.a.eql(f.b)) {
        if (off(e, f) or off(f, e)) return null;
        return .{ e, f };
    }
    return .{ cutTo(e, f) orelse return null, cutTo(f, e) orelse return null };
}

fn off(s: Seg, line: Seg) bool {
    return sideOf(line, s.a) < 0 and sideOf(line, s.b) < 0;
}

/// `s` cut to `line`'s material side, when it has an end strictly there. An
/// axis edge meets a 45-degree line, and a 45-degree edge an axis line, at a
/// lattice point.
fn cutTo(s: Seg, line: Seg) ?Seg {
    const a = sideOf(line, s.a);
    const b = sideOf(line, s.b);
    if (a <= 0 and b <= 0) return null;
    if (a >= 0 and b >= 0) return s;
    const d = dir(s);
    const at = struct {
        fn f(n: i128, of: i64, den: i128) i64 {
            assert(@rem(n, den) == 0);
            return of + @as(i64, @intCast(@divTrunc(n, den)));
        }
    }.f;
    const x: Point = .{ .x = at(d[0] * a, s.a.x, a - b), .y = at(d[1] * a, s.a.y, a - b) };
    return if (a > 0) .{ .a = s.a, .b = x } else .{ .a = x, .b = s.b };
}

/// Whether `(e, f)` face each other: antiparallel and each strictly on the
/// other's material side (`.width`), or each on the other's empty side over
/// a stretch of positive length (`.notch`).
fn facing(e: Seg, f: Seg, gap: Gap) bool {
    const u = dir(e);
    const v = dir(f);
    if (u[0] * v[1] != u[1] * v[0] or u[0] * v[0] + u[1] * v[1] >= 0) return false;
    const want: i128 = if (gap == .width) 1 else -1;
    const fe = std.math.sign(sideOf(e, f.a));
    const ef = std.math.sign(sideOf(f, e.a));
    // Antiparallel on one line and touching: where the figure meets itself
    // across a point (the connected corner model), a width of 0.
    if (gap == .width and fe == 0 and ef == 0) return ops.segmentsIntersect(e, f);
    if (fe != want or ef != want) return false;
    // A width pair need not overlap: past each other's ends the two edges
    // are as far apart as their nearest ends (a neck).
    if (gap == .width) return true;
    const e0 = u[0] * e.a.x + u[1] * e.a.y;
    const e1 = u[0] * e.b.x + u[1] * e.b.y;
    const f0 = u[0] * f.a.x + u[1] * f.a.y;
    const f1 = u[0] * f.b.x + u[1] * f.b.y;
    return @max(@min(e0, e1), @min(f0, f1)) < @min(@max(e0, e1), @max(f0, f1));
}
