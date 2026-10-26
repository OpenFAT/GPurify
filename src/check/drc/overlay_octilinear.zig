//! Enclosure where either layer has a slanted edge: hosts are the merged
//! outer figures, an inner polygon is hosted by the figure that covers it,
//! and each mode reads the edge pairs the foundries' KLayout decks check,
//! exactly (`geom.relation`). In: two layers validated at any angle. Out: one
//! violation per inner polygon enclosed less than the limit (unhosted: 0).
//! Full width and a wire band refuse (both cut layers into rectangles), as
//! do opposite and adjacent off a rectilinear inner layer in an octilinear
//! host. Ported from crates/check/src/drc/rules/overlay.rs
//! (`enclosure_octilinear`, `octilinear_reading`, `rev`, `nearest_mid`).
//!
//! Contents:
//! - `pub fn enclosureOctilinear(c: *const Ctx, outer: LayerId, inner_layer: LayerId, limit: Dbu, wire: WireBand, mode: Mode) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const Polygon = geom.Polygon;
const ValidatedLayer = geom.ValidatedLayer;
const relation = geom.relation;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const strips = @import("overlay_strips.zig");
const Mode = strips.Mode;

/// A reading as twice its square, and where to report it.
const Reading = struct { twice: i128, at: Point };

/// The least reading of an edge against a host edge, and that edge.
const Least = struct { r: i128, f: Seg };

/// See the file header. `examined` counts inner polygons.
pub fn enclosureOctilinear(c: *const Ctx, outer: LayerId, inner_layer: LayerId, limit: Dbu, wire: rows.WireBand, mode: Mode) Error!Verdict {
    const gpa = c.gpa;
    const s = &c.s.p;
    const hosts = try s.validated.getAny(gpa, c.store, outer) orelse return report.refused;
    const drawn = try s.validated.getAny(gpa, c.store, inner_layer) orelse return report.refused;
    const straight_out = mode == .opposite or mode == .adjacent;
    const octilinear = hosts.isOctilinear() and drawn.isOctilinear();
    const any_band = wire.from != 0 or wire.below != null or !wire.widthsOnly();
    if (mode == .full_width or any_band or (straight_out and !(drawn.isRectilinear() and octilinear))) return report.refused;
    const merged = &s.layer_out;
    try geom.derive.mergeInto(gpa, hosts, merged);
    const covered = try gpa.alloc(bool, drawn.len());
    defer gpa.free(covered);
    try geom.derive.insideFlags(gpa, drawn, merged, covered);
    const home = try gpa.alloc(?u32, drawn.len());
    defer gpa.free(home);
    try rects.figuresHolding(gpa, merged, drawn, home);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    try rects.ownersByPointInto(gpa, merged, hosts, &owners);
    const limit2 = 2 * geom.mulWide(limit, limit);
    var inner_edges: std.ArrayList(Seg) = .empty;
    defer inner_edges.deinit(gpa);
    var host_edges: std.ArrayList(Seg) = .empty;
    defer host_edges.deinit(gpa);
    for (0..drawn.len()) |poly| {
        const shape = drawn.get(@intCast(poly));
        const host = if (covered[poly]) home[poly] else null;
        var reading: Reading = .{ .twice = 0, .at = rects.centre(shape.bbox()) };
        var host_row: PolyId = report.no_shape;
        if (host) |figure| {
            try edgesInto(gpa, shape, &inner_edges);
            try edgesInto(gpa, merged.get(figure), &host_edges);
            reading = octilinearReading(inner_edges.items, host_edges.items, mode, octilinear) orelse continue;
            host_row = owners.items[figure];
        }
        if (reading.twice >= limit2) continue;
        try c.push(.{ .rule = c.rule, .layer = inner_layer, .severity = .@"error", .at = reading.at, .measured = .length(geom.ops.isqrt(strips.saturate(@divTrunc(reading.twice, 2)))), .limit = .length(limit), .shape_a = shape.provenance(), .shape_b = host_row });
    }
    return scratch.ran(drawn.len());
}

// ---- private ----

fn edgesInto(gpa: Allocator, poly: Polygon, out: *std.ArrayList(Seg)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var it = geom.width.polyEdges(poly);
    while (it.next()) |e| try out.append(gpa, e);
}

/// A segment reversed: a ring's edge in KLayout's orientation.
fn rev(s: Seg) Seg {
    return .{ .a = s.b, .b = s.a };
}

/// The midpoint of the two nearest points of `e` and `f`, floored.
fn nearestMid(e: Seg, f: Seg) Point {
    const n = geom.ops.segSegNear2(e, f);
    return .{ .x = @divFloor(n.on_p2.x + n.on_q2.x, 4), .y = @divFloor(n.on_p2.y + n.on_q2.y, 4) };
}

/// A hosted inner polygon's enclosure under `mode` as twice its square, and
/// where to report it; null when nothing measures it.
fn octilinearReading(inner: []const Seg, host: []const Seg, mode: Mode, octilinear: bool) ?Reading {
    switch (mode) {
        .every_side => {
            var best: ?Reading = null;
            for (inner) |e| for (host) |f| {
                const twice = if (octilinear) geom.ops.segSegNear2(e, f).d2 else geom.ops.segSegTwice2(e, f).floor;
                if (best == null or twice < best.?.twice) best = .{ .twice = twice, .at = nearestMid(e, f) };
            };
            return best;
        },
        .non_coincident => {
            var best: ?Reading = null;
            for (inner) |e| {
                const f_best = least(host, e, .non_coincident, octilinear) orelse continue;
                if (best == null or f_best.r < best.?.twice) best = .{ .twice = f_best.r, .at = nearestMid(e, f_best.f) };
            }
            return best;
        },
        .opposite => {
            // Per axis, the least reading of the edges facing along it.
            var axis: [2]?Reading = .{ null, null };
            for (inner) |e| {
                const found = least(host, e, .opposite, octilinear) orelse continue;
                const slot = &axis[@intFromBool(e.a.y == e.b.y)];
                if (slot.* == null or found.r < slot.*.?.twice) slot.* = .{ .twice = found.r, .at = nearestMid(e, found.f) };
            }
            const x = axis[0] orelse return null;
            const y = axis[1] orelse return null;
            return if (x.twice >= y.twice) x else y;
        },
        .adjacent => {
            var best: ?Reading = null;
            const n = inner.len;
            for (0..n) |i| {
                const into = inner[i];
                const from = inner[(i + 1) % n];
                const v = into.b;
                // Convex: a left turn (material on the left).
                const turn = (into.b.x - into.a.x) * (from.b.y - from.a.y) - (into.b.y - into.a.y) * (from.b.x - from.a.x);
                if (turn <= 0 or !from.a.eql(v)) continue;
                const r1 = atEnd(host, into, v) orelse continue;
                const r2 = atEnd(host, from, v) orelse continue;
                const r = @max(r1, r2);
                if (best == null or r < best.?.twice) best = .{ .twice = r, .at = v };
            }
            return best;
        },
        .full_width => return null,
    }
}

/// The least reading of inner edge `e` against any host edge, and that edge.
fn least(host: []const Seg, e: Seg, mode: Mode, octilinear: bool) ?Least {
    var best: ?Least = null;
    for (host) |f| {
        const r = pairOf(e, f, mode, octilinear) orelse continue;
        if (best == null or r < best.?.r) best = .{ .r = r, .f = f };
    }
    return best;
}

fn pairOf(e: Seg, f: Seg, mode: Mode, octilinear: bool) ?i128 {
    return switch (mode) {
        .non_coincident => if (octilinear)
            relation.pairThreshold2(.overlap, .euclidean, .never, rev(f), rev(e))
        else if (relation.pairThresholdAny(.overlap, .never, rev(f), rev(e))) |t| t.floor else null,
        .opposite => relation.pairThreshold2(.inside, .projection, .when_touching, rev(e), rev(f)),
        .adjacent => relation.pairThreshold2(.overlap, .projection, .when_touching, rev(f), rev(e)),
        .every_side, .full_width => null,
    };
}

/// An edge's adjacent reading at its end `v`: paired, and its reported part
/// reaching `v`.
fn atEnd(host: []const Seg, e: Seg, v: Point) ?i128 {
    var best: ?i128 = null;
    for (host) |f| {
        const reach = relation.projectedReach2(.overlap, .when_touching, rev(f), rev(e), v) orelse continue;
        const pair = pairOf(e, f, .adjacent, true) orelse continue;
        const r = @max(pair, reach);
        best = if (best) |b| @min(b, r) else r;
    }
    return best;
}
