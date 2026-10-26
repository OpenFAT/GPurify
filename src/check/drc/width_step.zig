//! LEF `MINSTEP` and `LEF58_MINSTEP` (DRC-020): runs of short edges along
//! each ring of the merged layer, judged by the long edges around them, and
//! single short edges judged by their neighbours. In: one rectilinear
//! layer. Out: one violation per offending run (or edge), at the centre of
//! the box of the vertices that make it offend. Ported from
//! crates/check/src/drc/rules/width.rs (`min_step`, `min_step_adjacent`).
//!
//! Contents:
//! - `pub fn minStep(c: *const Ctx, r: MinStep) Error!Verdict`
//! - `pub fn minStepAdjacent(c: *const Ctx, r: MinStepAdjacent) Error!Verdict`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Ring = geom.Ring;
const report = @import("../report.zig");
const rects = @import("../rects.zig");
const Verdict = report.Verdict;
const Measurement = report.Measurement;
const rows = @import("rows.zig");
const StepKind = rows.StepKind;
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const heading = @import("width_edges.zig").heading;

/// Runs of consecutive edges shorter than `limit`, classified by the long
/// edges on either side, rejected by `kind` and `length_sum`. `examined`
/// counts runs.
pub fn minStep(c: *const Ctx, r: rows.MinStep) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const figures = &c.s.p.layer_out;
    var examined: u64 = 0;
    var short: std.ArrayList(bool) = .empty;
    defer short.deinit(c.gpa);
    for (c.s.owners.items, 0..) |owner, idx| {
        const poly = figures.get(@intCast(idx));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            const n = ring.xs.len;
            try short.resize(c.gpa, n);
            for (short.items, 0..) |*sh, i| sh.* = length(ring, i) < r.limit;
            // Each run starts after a long edge; a ring with none is one run.
            const first_long = std.mem.indexOfScalar(bool, short.items, false);
            const start = if (first_long) |i| i + 1 else 0;
            var i: usize = 0;
            while (i < n) {
                const at = (start + i) % n;
                if (!short.items[at]) {
                    i += 1;
                    continue;
                }
                var run: u32 = 0;
                var sum: Dbu = 0;
                var box = Bbox.point(ring.xs[at], ring.ys[at]);
                while (i < n and short.items[(start + i) % n]) : (i += 1) {
                    const edge = (start + i) % n;
                    const end = vertex(ring, edge + 1);
                    box = box.include(end.x, end.y);
                    sum += length(ring, edge);
                    run += 1;
                }
                examined += 1;
                // The long edges on either side, when the ring has one.
                const corner: ?StepKind = if (first_long != null) blk: {
                    const before = (at + n - 1) % n;
                    const after = (at + run) % n;
                    const d1 = heading(vertex(ring, before), vertex(ring, before + 1));
                    const d2 = heading(vertex(ring, after), vertex(ring, after + 1));
                    const cross = d1[0] * d2[1] - d1[1] * d2[0];
                    const dot = d1[0] * d2[0] + d1[1] * d2[1];
                    break :blk if (cross > 0) .outside_corner else if (cross < 0) .inside_corner else if (dot > 0) .step else null;
                } else null;
                const found: [2]Measurement = switch (r.kind) {
                    .max_edges => |most| if (run > most) .{ .count(run), .count(most) } else continue,
                    .outside_corner, .inside_corner, .step => blk: {
                        if (corner == null or std.meta.activeTag(corner.?) != std.meta.activeTag(r.kind)) continue;
                        const fewest: u32 = if (r.kind == .step) 1 else 2;
                        if (run < fewest) continue;
                        if (r.length_sum) |allowed| {
                            if (sum <= allowed) continue;
                            break :blk .{ .length(sum), .length(allowed) };
                        }
                        break :blk .{ .count(run), .count(fewest - 1) };
                    },
                };
                try c.finding(r.layer, rects.centre(box), found[0], found[1], owner);
            }
        }
    }
    return scratch.ran(examined);
}

/// Each edge of the merged layer shorter than `limit` whose neighbours
/// offend as `neighbour` states. `examined` counts short edges.
pub fn minStepAdjacent(c: *const Ctx, r: rows.MinStepAdjacent) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const figures = &c.s.p.layer_out;
    var examined: u64 = 0;
    for (c.s.owners.items, 0..) |owner, idx| {
        const poly = figures.get(@intCast(idx));
        const exempt = switch (r.neighbour) {
            .adjacent => |a| a.except_rectangle and poly.outer().xs.len == 4,
            .between_eol => false,
        };
        if (exempt) continue;
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            const n = ring.xs.len;
            for (0..n) |e| {
                if (length(ring, e) >= r.limit) continue;
                examined += 1;
                const prev = e + n - 1;
                const next = e + 1;
                // The edges, besides `e`, that make it offend.
                const blamed: [2]usize = switch (r.neighbour) {
                    .adjacent => |a| blk: {
                        const offends = struct {
                            fn f(rg: Ring, i: usize, adj: Dbu, eol: ?Dbu) bool {
                                return length(rg, i) < adj or (if (eol) |w| eolUnder(rg, i, w) else false);
                            }
                        }.f;
                        if (!offends(ring, prev, a.length, a.eol) and !offends(ring, next, a.length, a.eol)) continue;
                        break :blk .{ prev, next };
                    },
                    .between_eol => |width| blk: {
                        if (!(eolUnder(ring, next, width) and length(ring, next + 1) < r.limit)) continue;
                        break :blk .{ next, next + 1 };
                    },
                };
                var box = Bbox.point(vertex(ring, e).x, vertex(ring, e).y);
                for ([3]usize{ e, blamed[0], blamed[1] }) |i| for ([2]Point{ vertex(ring, i), vertex(ring, i + 1) }) |p| {
                    box = box.include(p.x, p.y);
                };
                try c.finding(r.layer, rects.centre(box), .length(length(ring, e)), .length(r.limit), owner);
            }
        }
    }
    return scratch.ran(examined);
}

// ---- private ----

fn vertex(ring: Ring, i: usize) Point {
    const n = ring.xs.len;
    return .{ .x = ring.xs[i % n], .y = ring.ys[i % n] };
}

/// Edge `i` (vertex `i` to `i + 1`), Manhattan: exact for the axis edges a
/// rectilinear ring has.
fn length(ring: Ring, i: usize) Dbu {
    const a = vertex(ring, i);
    const b = vertex(ring, i + 1);
    return @intCast(@abs(b.x - a.x) + @abs(b.y - a.y));
}

/// A left turn at vertex `i` is a convex corner: the material is on the
/// left of travel, outer rings and holes alike.
fn convex(ring: Ring, i: usize) bool {
    const n = ring.xs.len;
    const d1 = heading(vertex(ring, i + n - 1), vertex(ring, i));
    const d2 = heading(vertex(ring, i), vertex(ring, i + 1));
    return d1[0] * d2[1] - d1[1] * d2[0] > 0;
}

/// Edge `i` is an end of line shorter than `width`: convex at both ends.
fn eolUnder(ring: Ring, i: usize, width: Dbu) bool {
    return convex(ring, i) and convex(ring, i + 1) and length(ring, i) < width;
}
