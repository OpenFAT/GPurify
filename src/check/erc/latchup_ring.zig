//! The guard-ring kind of the latchup family (`guard_ring`, ERC-D2/D6/D7/D8:
//! GF180MCU IO.1-IO.4, LU.5, §14.3.3-§14.3.4; IHP SG13G2 §7.2.1; ESDA
//! TR18.0-02 §3.1.2): every selected target lies in a hole of one merged
//! ring figure, with `max_space`, `min_width` and `clear` held, and the
//! region geometry the family shares (a layer's outer rows, whether a hole
//! surrounds a polygon). In: the store, nets, the ring, target, pad, near
//! and clear layers. Out: violations and one run per row. Ported from
//! crates/check/src/erc/rules/latchup.rs (`check_guard_ring`,
//! `ClearIndex`, `outers`, `surrounds`, `ring_box`).
//!
//! Contents:
//! - `pub fn checkGuardRing(r: Record, design: Design, t: *const GuardRingTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn outersInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, out: *std.ArrayList(PolyId)) Allocator.Error!void`
//! - `pub fn surrounds(hx: []const Dbu, hy: []const Dbu, tx: []const Dbu, ty: []const Dbu) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ops = geom.ops;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const NetId = @import("../topology/net.zig").NetId;
const pointInRegion = @import("../topology/taps.zig").pointInRegion;
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const rings = @import("rings.zig");
const Scratch = @import("scratch.zig").Scratch;
const GuardRingTable = @import("latchup_tables.zig").GuardRingTable;

/// What a `clear` row reads: the `clear` layer's merged rectangles labelled
/// by figure, every ring figure's rectangles, the target layer's drawn
/// rectangles.
const ClearIndex = struct {
    clear: rects.SortedRects = .{},
    ring_rects: std.ArrayList(Bbox) = .empty,
    ring_start: std.ArrayList(u32) = .empty,
    targets: rects.LayerRects = .{},
    first_target: u32,

    /// Null when the clear or target layer will not validate.
    fn build(gpa: Allocator, store: *const GeometryStore, clear_layer: LayerId, target: LayerId, figures: *const geom.ValidatedLayer) Allocator.Error!?ClearIndex {
        var drawn: geom.ValidatedLayer = .empty;
        defer drawn.deinit(gpa);
        var merged: geom.ValidatedLayer = .empty;
        defer merged.deinit(gpa);
        if (try geom.view.validateLayer(gpa, store, clear_layer, .rectilinear, &drawn) != null) return null;
        const nothing: geom.ValidatedLayer = .empty;
        try geom.boolean.unionInto(gpa, &drawn, &nothing, &merged);
        var c: ClearIndex = .{ .first_target = store.polysOnLayer(target).start };
        errdefer c.deinit(gpa);
        var boxes: std.ArrayList(Bbox) = .empty;
        defer boxes.deinit(gpa);
        var start: std.ArrayList(u32) = .empty;
        defer start.deinit(gpa);
        try geom.rects.decomposeInto(gpa, &merged, &boxes, &start);
        var labels: std.ArrayList(u32) = .empty;
        defer labels.deinit(gpa);
        for (0..merged.len()) |f| try labels.appendNTimes(gpa, @intCast(f), start.items[f + 1] - start.items[f]);
        try c.clear.build(gpa, boxes.items, labels.items);
        try geom.rects.decomposeInto(gpa, figures, &c.ring_rects, &c.ring_start);
        if (try geom.view.validateLayer(gpa, store, target, .rectilinear, &drawn) != null) {
            c.deinit(gpa);
            return null;
        }
        try c.targets.build(gpa, store, target, &drawn);
        return c;
    }

    fn deinit(c: *ClearIndex, gpa: Allocator) void {
        c.clear.deinit(gpa);
        c.ring_rects.deinit(gpa);
        c.ring_start.deinit(gpa);
        c.targets.deinit(gpa);
    }

    /// The `clear` figures with area in `hole` (a box of ring figure
    /// `figure`) off that figure and off `target`.
    fn between(c: *const ClearIndex, gpa: Allocator, hole: Bbox, figure: u32, target: PolyId) Allocator.Error!u32 {
        var area: std.ArrayList([2]i128) = .empty;
        defer area.deinit(gpa);
        try c.add(gpa, &area, hole, 1);
        for (c.ring_rects.items[c.ring_start.items[figure]..c.ring_start.items[figure + 1]]) |rr| {
            if (rr.intersection(hole)) |x| try c.add(gpa, &area, x, -1);
        }
        const poly = c.targets.poly_of_row.items[@backingInt(target) - c.first_target];
        for (c.targets.of(poly)) |tr| try c.add(gpa, &area, tr, -1);
        var n: u32 = 0;
        for (area.items) |e| n += @intFromBool(e[1] > 0);
        return n;
    }

    fn add(c: *const ClearIndex, gpa: Allocator, area: *std.ArrayList([2]i128), box: Bbox, sign: i128) Allocator.Error!void {
        var hits = c.clear.overlapping(box);
        while (hits.next()) |h| {
            const a = sign * h.clip.area();
            const found = for (area.items) |*e| {
                if (e[0] == h.label) break e;
            } else null;
            if (found) |e| e[1] += a else try area.append(gpa, .{ h.label, a });
        }
    }
};

/// Every selected outer target of a row. `examined` counts them. A target
/// no ring surrounds measures 0 rings against 1; one too far from its ring
/// the largest box gap against `max_space`; one whose hole holds `clear`
/// area the count of such `clear` figures against 0 (all at the target's
/// first vertex, on the target layer). A surrounding ring narrower than
/// `min_width` is one finding at its lowest drawn polygon, on the ring
/// layer. Refused when the ring, `clear` or target layer will not validate.
pub fn checkGuardRing(r: Record, design: Design, t: *const GuardRingTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    var narrow: std.ArrayList(rings.Narrow) = .empty;
    defer narrow.deinit(gpa);
    var drawn: rects.LayerRects = .{};
    defer drawn.deinit(gpa);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    var pads: std.ArrayList(NetId) = .empty;
    defer pads.deinit(gpa);
    var near_polys: std.ArrayList(PolyId) = .empty;
    defer near_polys.deinit(gpa);
    var targets: std.ArrayList(PolyId) = .empty;
    defer targets.deinit(gpa);
    var reported: std.ArrayList(u32) = .empty;
    defer reported.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const target_layer = t.target.items[row];
        const ring_layer = t.ring.items[row];
        // Below one unit no band is narrower: nothing is reported.
        const floor = t.min_width.items[row] orelse 1;
        if (!try rings.narrowRingsInto(gpa, design, ring_layer, floor, scratch, &narrow)) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        try drawn.build(gpa, store, ring_layer, &scratch.layer_a);
        try rects.ownersOfInto(gpa, &scratch.layer_b, &drawn, &owners);
        const figures = &scratch.layer_b;
        const pad = t.pad.items[row];
        if (pad) |p| try rings.padNetsInto(gpa, design, p, &pads);
        const near = t.near.items[row];
        if (near) |n| try outersInto(gpa, store, n.layer, &near_polys);
        var clear: ?ClearIndex = null;
        defer if (clear) |*c| c.deinit(gpa);
        if (t.clear.items[row]) |layer| {
            clear = try ClearIndex.build(gpa, store, layer, target_layer, figures);
            if (clear == null) {
                try r.run(rule, before, .refused, 0);
                continue;
            }
        }
        reported.clearRetainingCapacity();
        var examined: u64 = 0;
        try outersInto(gpa, store, target_layer, &targets);
        for (targets.items) |target| {
            if (pad != null) {
                if (pads.items.len == 0 or !containsNet(pads.items, design.nets.netOf(target))) continue;
            }
            const tb = store.polyBbox(target);
            if (near) |n| {
                const reach = geom.mulWide(n.within, n.within);
                const close = for (near_polys.items) |p| {
                    if (store.polyBbox(p).within(tb, n.within) and rings.regionDist2(store, target, p) <= reach) break true;
                } else false;
                if (!close) continue;
            }
            examined += 1;
            const tr = store.polyVerts(target);
            // The innermost hole round the target.
            var best_figure: ?u32 = null;
            var best_hole: Bbox = undefined;
            for (0..figures.len()) |f| {
                const figure = figures.get(@intCast(f));
                if (!figure.bbox().contains(tb)) continue;
                for (1..figure.ringCount()) |k| {
                    const hole = figure.ring(@intCast(k));
                    const hb = Bbox.ofPoints(hole.xs, hole.ys);
                    const inner = best_figure == null or hb.area() < best_hole.area();
                    if (inner and hb.contains(tb) and surrounds(hole.xs, hole.ys, tr.xs, tr.ys)) {
                        best_figure = @intCast(f);
                        best_hole = hb;
                    }
                }
            }
            const at = store.firstVertex(target);
            const figure = best_figure orelse {
                try push(r, rule, severity, target_layer, at, target, .count(0), .count(1));
                continue;
            };
            const hole = best_hole;
            if (clear) |*c| {
                const between = try c.between(gpa, hole, figure, target);
                if (between > 0) try push(r, rule, severity, target_layer, at, target, .count(between), .count(0));
            }
            if (t.max_space.items[row]) |max_space| {
                const gap = @max(tb.xlo - hole.xlo, hole.xhi - tb.xhi, tb.ylo - hole.ylo, hole.yhi - tb.yhi);
                const measured: Measurement = .length(gap);
                const limit: Measurement = .length(max_space);
                if (measured.violates(limit, .maximum)) try push(r, rule, severity, target_layer, at, target, measured, limit);
            }
            const owner = owners.items[figure];
            if (t.min_width.items[row]) |min_width| if (std.mem.indexOfScalar(u32, reported.items, figure) == null) {
                if (bandOf(narrow.items, owner)) |band| {
                    try reported.append(gpa, figure);
                    try push(r, rule, severity, ring_layer, store.firstVertex(owner), owner, .length(band), .length(min_width));
                }
            };
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// The counter-clockwise rows of `layer` (its polygons, not their holes),
/// into `out`.
pub fn outersInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, out: *std.ArrayList(PolyId)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |p| {
        const poly: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
        const ring = store.polyVerts(poly);
        if (ops.windingOf(ring.xs, ring.ys) != .cw) try out.append(gpa, poly);
    }
}

/// The hole `(hx, hy)` surrounds the polygon `(tx, ty)`: every vertex of the
/// polygon in or on the hole, and no vertex of the hole strictly inside the
/// polygon (a rectilinear hole's corner poking in).
pub fn surrounds(hx: []const Dbu, hy: []const Dbu, tx: []const Dbu, ty: []const Dbu) bool {
    for (tx, ty) |x, y| if (!pointInRegion(hx, hy, .{ .x = x, .y = y })) return false;
    for (hx, hy) |x, y| {
        const p: geom.Point = .{ .x = x, .y = y };
        if (!pointInRegion(tx, ty, p)) continue;
        const on_target = for (0..tx.len) |i| {
            if (ops.pointSegDist2(p, ops.ringEdge(tx, ty, i)) == 0) break true;
        } else false;
        if (!on_target) return false;
    }
    return true;
}

// ---- private ----

fn containsNet(sorted: []const NetId, net: NetId) bool {
    return std.sort.binarySearch(NetId, sorted, net, struct {
        fn order(a: NetId, b: NetId) std.math.Order {
            return std.math.order(@backingInt(a), @backingInt(b));
        }
    }.order) != null;
}

/// The narrowest band of the figure whose owner is `owner`, from a list
/// sorted by owner.
fn bandOf(narrow: []const rings.Narrow, owner: PolyId) ?Dbu {
    for (narrow) |n| if (n.poly == owner) return n.band;
    return null;
}

fn push(r: Record, rule: geom.StrId, severity: report.Severity, layer: LayerId, at: geom.Point, shape: PolyId, measured: Measurement, limit: Measurement) Allocator.Error!void {
    try r.out.push(r.gpa, .{ .rule = rule, .layer = layer, .severity = severity, .at = at, .measured = measured, .limit = limit, .shape_a = shape, .shape_b = report.no_shape });
}
