//! Min edge length: every straight run of a merged figure's boundary
//! shorter than the limit. In: one layer (edges at any angle). Out: one
//! violation per short run, at its midpoint, on the lowest drawn row under
//! its figure. Ported from crates/check/src/drc/rules/width.rs
//! (`min_edge_length`, `straight_runs`, `heading`).
//!
//! Contents:
//! - `pub fn minEdgeLength(c: *const Ctx, r: LayerLimit) Error!Verdict`
//! - `pub fn heading(a: Point, b: Point) [2]i64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Point = geom.Point;
const Polygon = geom.Polygon;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

const Key = struct { p: Point, way: [2]i64 };

/// One violation per edge of the merged layer shorter than `limit`, at its
/// midpoint. `examined` counts the merged figures' edges. A 45-degree edge
/// `k` steps long is `k·√2` long, one at any other angle `√(dx² + dy²)`,
/// compared exactly and reported floored.
pub fn minEdgeLength(c: *const Ctx, r: rows.LayerLimit) Error!Verdict {
    const s = c.s;
    const drawn = try s.p.validated.getAny(c.gpa, c.store, r.layer) orelse return report.refused;
    const figures = &s.p.layer_out;
    try geom.derive.mergeInto(c.gpa, drawn, figures);
    if (drawn.isRectilinear()) {
        try s.p.rects_a.build(c.gpa, c.store, r.layer, drawn);
        try rects.ownersOfInto(c.gpa, figures, &s.p.rects_a, &s.owners);
    } else try rects.ownersByPointInto(c.gpa, figures, drawn, &s.owners);
    const limit2 = geom.mulWide(r.limit, r.limit);
    var examined: u64 = 0;
    var runs: std.ArrayList([2]Point) = .empty;
    defer runs.deinit(c.gpa);
    for (s.owners.items, 0..) |owner, idx| {
        try straightRunsInto(c.gpa, figures.get(@intCast(idx)), &runs);
        for (runs.items) |run| {
            examined += 1;
            const dx = @abs(run[1].x - run[0].x);
            const dy = @abs(run[1].y - run[0].y);
            const length2 = geom.mulWide(@intCast(dx), @intCast(dx)) + geom.mulWide(@intCast(dy), @intCast(dy));
            if (length2 >= limit2) continue;
            const at: Point = .{ .x = rects.mid(run[0].x, run[1].x), .y = rects.mid(run[0].y, run[1].y) };
            try c.finding(r.layer, at, .length(geom.ops.isqrt(length2)), .length(r.limit), owner);
        }
    }
    return scratch.ran(examined);
}

/// The direction an edge runs, as its primitive step: signs along x and y
/// for an axis or 45-degree edge, the difference over its gcd at any angle.
pub fn heading(a: Point, b: Point) [2]i64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const g: i64 = @intCast(@max(std.math.gcd(@abs(dx), @abs(dy)), 1));
    return .{ @divTrunc(dx, g), @divTrunc(dy, g) };
}

// ---- private ----

/// Every straight run of a polygon's boundary, holes included, into `out`:
/// consecutive edges of a ring running one way are one run, and a ring that
/// leaves a straight edge at a point it also touches (a tip on the edge)
/// and comes back continues that edge, as KLayout reads it.
fn straightRunsInto(gpa: Allocator, poly: Polygon, out: *std.ArrayList([2]Point)) Allocator.Error!void {
    var pieces: std.ArrayList([2]Point) = .empty;
    defer pieces.deinit(gpa);
    for (0..poly.ringCount()) |k| {
        const ring = poly.ring(@intCast(k));
        const n = ring.xs.len;
        const at = struct {
            fn f(rg: geom.Ring, i: usize) Point {
                return .{ .x = rg.xs[i % rg.xs.len], .y = rg.ys[i % rg.xs.len] };
            }
        }.f;
        // Start at a vertex where the ring turns; every ring turns somewhere.
        const first = for (0..n) |i| {
            if (!std.meta.eql(heading(at(ring, i + n - 1), at(ring, i)), heading(at(ring, i), at(ring, i + 1)))) break i;
        } else continue;
        var from = first;
        for (1..n + 1) |step| {
            const i = first + step;
            if (step == n or !std.meta.eql(heading(at(ring, i - 1), at(ring, i)), heading(at(ring, i), at(ring, i + 1)))) {
                try pieces.append(gpa, .{ at(ring, from), at(ring, i) });
                from = i;
            }
        }
    }
    var by_start: std.AutoHashMapUnmanaged(Key, usize) = .empty;
    defer by_start.deinit(gpa);
    var continues: std.AutoHashMapUnmanaged(Key, void) = .empty;
    defer continues.deinit(gpa);
    for (pieces.items, 0..) |p, k| {
        try by_start.put(gpa, .{ .p = p[0], .way = heading(p[0], p[1]) }, k);
        try continues.put(gpa, .{ .p = p[1], .way = heading(p[0], p[1]) }, {});
    }
    const taken = try gpa.alloc(bool, pieces.items.len);
    defer gpa.free(taken);
    @memset(taken, false);
    out.clearRetainingCapacity();
    for (pieces.items, 0..) |p, k| {
        const way = heading(p[0], p[1]);
        // A piece some other piece ends at is reached from that one.
        if (taken[k] or continues.contains(.{ .p = p[0], .way = way })) continue;
        taken[k] = true;
        var end = p[1];
        while (by_start.get(.{ .p = end, .way = way })) |next| {
            if (taken[next]) break;
            taken[next] = true;
            _ = by_start.remove(.{ .p = end, .way = way });
            end = pieces.items[next][1];
        }
        try out.append(gpa, .{ p[0], end });
    }
    // Pieces on a closed straight loop (impossible) or not reached stay.
    for (pieces.items, taken) |p, t| if (!t) try out.append(gpa, p);
}
