//! Vias as connectors: a merged `lower` figure and a merged `upper` figure
//! that overlap, the connector's footprint their overlap, its cuts the
//! merged cut figures on that footprint. In: the cut layer(s) and both
//! metals, merged. Out: one violation per connector whose cut area changes
//! too much (`cut_area_change`), or one for a design whose redundant-via
//! rate is too low (`via_redundancy`). Ported from
//! crates/check/src/drc/rules/via.rs (`Connectors`, `first_label`,
//! `cut_area_change`, `Vias`, `neighbours`, `covers`, `clear`,
//! `via_redundancy`, `redundant_cuts`, `Insertion`, `second_cut`,
//! `neighbours`, `grown`, `margin`).
//!
//! Contents:
//! - `pub fn cutAreaChange(c: *const Ctx, r: CutAreaChange) Error!Verdict`
//! - `pub fn viaRedundancy(c: *const Ctx, r: ViaRedundancy) Error!Verdict`
//! - `pub const Insertion = struct { cut, lower, upper }`
//! - `pub fn redundantCutsInto(gpa: Allocator, store: *const GeometryStore, layers: [3]LayerId, pitch: Dbu, space: Dbu, out: *std.ArrayList(Insertion)) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const SortedRects = rects.SortedRects;
const proximity_inside = @import("../proximity_inside.zig");
const proximity = @import("../proximity.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const ran = scratch.ran;

/// A second cut beside a single-cut via, and the patch of each metal
/// that does not already hold it.
pub const Insertion = struct { cut: Bbox, lower: ?Bbox, upper: ?Bbox };

/// A connector's `(lower, upper)` figures.
const Figures = [2]u32;

/// The connectors of two merged layers. Invariant: `figures` ascends with
/// no repeats, parallel to `bounds`; `of_piece` has one entry per figure of
/// `feet`.
const Connectors = struct {
    /// The footprint, merged.
    feet: ValidatedLayer = .empty,
    /// The footprint's rectangles, each labelled with its piece.
    pieces: SortedRects = .{},
    /// Per footprint piece, its connector.
    of_piece: std.ArrayList(u32) = .empty,
    /// Per connector, the box of its footprint.
    bounds: std.ArrayList(Bbox) = .empty,
    figures: std.ArrayList(Figures) = .empty,

    fn deinit(k: *Connectors, gpa: Allocator) void {
        k.feet.deinit(gpa);
        k.pieces.deinit(gpa);
        k.of_piece.deinit(gpa);
        k.bounds.deinit(gpa);
        k.figures.deinit(gpa);
    }

    fn build(k: *Connectors, gpa: Allocator, under: *const ValidatedLayer, over: *const ValidatedLayer) Allocator.Error!void {
        try geom.boolean.intersectionInto(gpa, under, over, &k.feet);
        var on_under: SortedRects = .{};
        defer on_under.deinit(gpa);
        var on_over: SortedRects = .{};
        defer on_over.deinit(gpa);
        try rects.figureRectsInto(gpa, under, &on_under);
        try rects.figureRectsInto(gpa, over, &on_over);
        var parts: std.ArrayList(Bbox) = .empty;
        defer parts.deinit(gpa);
        var start: std.ArrayList(u32) = .empty;
        defer start.deinit(gpa);
        try geom.rects.decomposeInto(gpa, &k.feet, &parts, &start);
        const piece_count = start.items.len - 1;
        const pair = try gpa.alloc(Figures, piece_count);
        defer gpa.free(pair);
        for (pair, start.items[0..piece_count]) |*p, from| {
            const r = parts.items[from];
            p.* = .{ firstLabel(&on_under, r), firstLabel(&on_over, r) };
        }
        try k.figures.resize(gpa, 0);
        try k.figures.appendSlice(gpa, pair);
        std.mem.sortUnstable(Figures, k.figures.items, {}, lessFigures);
        var kept: usize = 0;
        for (k.figures.items) |f| {
            if (kept > 0 and std.mem.eql(u32, &k.figures.items[kept - 1], &f)) continue;
            k.figures.items[kept] = f;
            kept += 1;
        }
        k.figures.shrinkRetainingCapacity(kept);
        try k.of_piece.resize(gpa, piece_count);
        try k.bounds.resize(gpa, kept);
        @memset(k.bounds.items, Bbox.empty);
        for (pair, k.of_piece.items, 0..) |p, *at, piece| {
            at.* = @intCast(std.sort.lowerBound(Figures, k.figures.items, p, orderFigures));
            k.bounds.items[at.*] = k.bounds.items[at.*].merge(k.feet.get(@intCast(piece)).bbox());
        }
        try rects.figureRectsInto(gpa, &k.feet, &k.pieces);
    }

    /// Per connector, the merged figures of `cuts` overlapping its
    /// footprint, in figure order, CSR into `held`/`start`; a cut over two
    /// connectors is in each.
    fn cutsInto(k: *const Connectors, gpa: Allocator, cuts: *const ValidatedLayer, held: *std.ArrayList(u32), start: *std.ArrayList(u32)) Allocator.Error!void {
        var parts: std.ArrayList(Bbox) = .empty;
        defer parts.deinit(gpa);
        var cut_start: std.ArrayList(u32) = .empty;
        defer cut_start.deinit(gpa);
        try geom.rects.decomposeInto(gpa, cuts, &parts, &cut_start);
        var links: std.ArrayList([2]u32) = .empty;
        defer links.deinit(gpa);
        var hit: std.ArrayList(u32) = .empty;
        defer hit.deinit(gpa);
        for (cut_start.items[0 .. cut_start.items.len - 1], cut_start.items[1..], 0..) |from, to, cut| {
            hit.clearRetainingCapacity();
            for (parts.items[from..to]) |r| {
                var it = k.pieces.overlapping(r);
                while (it.next()) |h| try hit.append(gpa, k.of_piece.items[h.label]);
            }
            std.mem.sortUnstable(u32, hit.items, {}, std.sort.asc(u32));
            for (hit.items, 0..) |at, i| {
                if (i > 0 and hit.items[i - 1] == at) continue;
                try links.append(gpa, .{ at, @intCast(cut) });
            }
        }
        std.mem.sortUnstable([2]u32, links.items, {}, lessFigures);
        held.clearRetainingCapacity();
        try start.resize(gpa, k.figures.items.len + 1);
        @memset(start.items, 0);
        for (links.items) |l| {
            start.items[l[0] + 1] += 1;
            try held.append(gpa, l[1]);
        }
        for (1..start.items.len) |i| start.items[i] += start.items[i - 1];
    }

    /// Per connector, the area of `layer` inside its footprint, into `sums`.
    fn areaIn(k: *const Connectors, gpa: Allocator, layer: *const ValidatedLayer, sums: []DbuArea) Allocator.Error!void {
        var inside: ValidatedLayer = .empty;
        defer inside.deinit(gpa);
        try geom.boolean.intersectionInto(gpa, layer, &k.feet, &inside);
        var parts: std.ArrayList(Bbox) = .empty;
        defer parts.deinit(gpa);
        var start: std.ArrayList(u32) = .empty;
        defer start.deinit(gpa);
        try geom.rects.decomposeInto(gpa, &inside, &parts, &start);
        @memset(sums, 0);
        for (parts.items) |r| sums[k.of_piece.items[firstLabel(&k.pieces, r)]] += r.area();
    }
};

/// sky130 ct.irdrop and via.irdrop as a deck states them: each connector
/// is held, by the number of merged `pre` cuts on its footprint, to the
/// band's limit on the change, either way, between the `pre` and the `post`
/// area inside the footprint. One violation per failing connector, on
/// `pre`, at the centre of its footprint's box. `examined` counts
/// connectors.
pub fn cutAreaChange(c: *const Ctx, r: rows.CutAreaChange) Error!Verdict {
    const gpa = c.gpa;
    var layers: [4]ValidatedLayer = @splat(.empty);
    defer for (&layers) |*l| l.deinit(gpa);
    for (&layers, [4]LayerId{ r.lower, r.upper, r.pre, r.post }) |*out, l| {
        if (!try proximity_inside.mergedInto(gpa, c.store, l, &c.s.p, out)) return report.refused;
    }
    var k: Connectors = .{};
    defer k.deinit(gpa);
    try k.build(gpa, &layers[0], &layers[1]);
    const n = k.figures.items.len;
    const was = try gpa.alloc(DbuArea, n);
    defer gpa.free(was);
    const is = try gpa.alloc(DbuArea, n);
    defer gpa.free(is);
    try k.areaIn(gpa, &layers[2], was);
    try k.areaIn(gpa, &layers[3], is);
    var held: std.ArrayList(u32) = .empty;
    defer held.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try k.cutsInto(gpa, &layers[2], &held, &start);
    const bands = c.rs.cutAreaBands(r.bands);
    for (0..n) |at| {
        const limit = bands.limit(start.items[at + 1] - start.items[at]) orelse continue;
        const change: DbuArea = @intCast(@abs(was[at] - is[at]));
        if (change <= limit) continue;
        try c.finding(r.pre, rects.centre(k.bounds.items[at]), .area(change), .area(limit), report.no_shape);
    }
    return ran(n);
}

/// The redundant-via rate of Xu et al. (ASP-DAC 2005), `1 - dead / vias`:
/// a via is a connector's cuts; a single-cut via is dead when none of its
/// cut's four neighbours (its box moved `pitch` right, left, up, down) lies
/// wholly on both of its figures at least `space` from every cut. One
/// violation when the rate is below `limit`, on `cut`, at the centre of the
/// first dead via's cut, measuring the rate. `examined` counts vias.
pub fn viaRedundancy(c: *const Ctx, r: rows.ViaRedundancy) Error!Verdict {
    const gpa = c.gpa;
    var layers: [3]ValidatedLayer = @splat(.empty);
    defer for (&layers) |*l| l.deinit(gpa);
    for (&layers, [3]LayerId{ r.lower, r.upper, r.cut }) |*out, l| {
        if (!try proximity_inside.mergedInto(gpa, c.store, l, &c.s.p, out)) return report.refused;
    }
    var k: Connectors = .{};
    defer k.deinit(gpa);
    try k.build(gpa, &layers[0], &layers[1]);
    var under: SortedRects = .{};
    defer under.deinit(gpa);
    var over: SortedRects = .{};
    defer over.deinit(gpa);
    try rects.figureRectsInto(gpa, &layers[0], &under);
    try rects.figureRectsInto(gpa, &layers[1], &over);
    var held: std.ArrayList(u32) = .empty;
    defer held.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try k.cutsInto(gpa, &layers[2], &held, &start);
    // Every cut's box, by merged cut figure.
    const boxes = layers[2].bboxes();
    var vias: u32 = 0;
    var dead: u32 = 0;
    var first_dead: ?Bbox = null;
    for (0..k.figures.items.len) |at| {
        const cuts = held.items[start.items[at]..start.items[at + 1]];
        if (cuts.len == 0) continue;
        vias += 1;
        if (cuts.len != 1) continue;
        const b = boxes[cuts[0]];
        const lo, const hi = k.figures.items[at];
        const p = r.pitch;
        const room = for ([4][2]i64{ .{ p, 0 }, .{ -p, 0 }, .{ 0, p }, .{ 0, -p } }) |d| {
            const moved: Bbox = .{ .xlo = b.xlo + d[0], .ylo = b.ylo + d[1], .xhi = b.xhi + d[0], .yhi = b.yhi + d[1] };
            if (covers(&under, lo, moved) and covers(&over, hi, moved) and clear(moved, boxes, r.space)) break true;
        } else false;
        if (room) continue;
        dead += 1;
        if (first_dead == null) first_dead = b;
    }
    const rate: f64 = if (vias == 0) 1.0 else 1.0 - @as(f64, @floatFromInt(dead)) / @as(f64, @floatFromInt(vias));
    if (rate < r.limit) if (first_dead) |b| {
        try c.finding(r.cut, rects.centre(b), .ratio(rate), .ratio(r.limit), report.no_shape);
    };
    return ran(vias);
}

/// Where a second cut goes beside each single-cut via, as `gpurify
/// enhance` adds them (catalog FLOW-009), in connector order: where
/// `viaRedundancy` finds room, the first neighbour it finds; for a dead
/// via, the first neighbour at least `space` from every cut, with a patch
/// of each metal that does not hold it: the box round both cuts, grown by
/// the margin the metal already leaves round the via's cut. Each cut is
/// also `space` from every cut placed before it. `layers` is `(cut, lower,
/// upper)`; false when a layer does not validate (the rule's refusal).
pub fn redundantCutsInto(gpa: Allocator, store: *const GeometryStore, layers: [3]LayerId, pitch: Dbu, space: Dbu, out: *std.ArrayList(Insertion)) Allocator.Error!bool {
    out.clearRetainingCapacity();
    var s: proximity.Scratch = .{};
    defer s.deinit(gpa);
    var merged: [3]ValidatedLayer = @splat(.empty);
    defer for (&merged) |*l| l.deinit(gpa);
    for (&merged, [3]LayerId{ layers[1], layers[2], layers[0] }) |*m, l| {
        if (!try proximity_inside.mergedInto(gpa, store, l, &s, m)) return false;
    }
    var k: Connectors = .{};
    defer k.deinit(gpa);
    try k.build(gpa, &merged[0], &merged[1]);
    var under: SortedRects = .{};
    defer under.deinit(gpa);
    var over: SortedRects = .{};
    defer over.deinit(gpa);
    try rects.figureRectsInto(gpa, &merged[0], &under);
    try rects.figureRectsInto(gpa, &merged[1], &over);
    var held: std.ArrayList(u32) = .empty;
    defer held.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try k.cutsInto(gpa, &merged[2], &held, &start);
    var cuts: std.ArrayList(Bbox) = .empty;
    defer cuts.deinit(gpa);
    try cuts.appendSlice(gpa, merged[2].bboxes());
    for (0..k.figures.items.len) |at| {
        const on = held.items[start.items[at]..start.items[at + 1]];
        if (on.len != 1) continue;
        const b = merged[2].bboxes()[on[0]];
        const lo, const hi = k.figures.items[at];
        const second = for (neighbours(b, pitch)) |c| {
            if (covers(&under, lo, c) and covers(&over, hi, c) and clear(c, cuts.items, space)) break c;
        } else null;
        const insertion: Insertion = if (second) |c| .{ .cut = c, .lower = null, .upper = null } else blk: {
            const below = margin(&under, lo, b, pitch) orelse continue;
            const above = margin(&over, hi, b, pitch) orelse continue;
            const c = for (neighbours(b, pitch)) |n| (if (clear(n, cuts.items, space)) break n) else continue;
            const both = b.merge(c);
            break :blk .{ .cut = c, .lower = if (covers(&under, lo, c)) null else grown(both, below), .upper = if (covers(&over, hi, c)) null else grown(both, above) };
        };
        try cuts.append(gpa, insertion.cut);
        try out.append(gpa, insertion);
    }
    return true;
}

// ---- private ----

fn lessFigures(_: void, p: Figures, q: Figures) bool {
    return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
}

fn orderFigures(key: Figures, item: Figures) std.math.Order {
    const first = std.math.order(key[0], item[0]);
    return if (first != .eq) first else std.math.order(key[1], item[1]);
}

/// The label of the first rectangle of `sorted` overlapping `r`, which one
/// must.
fn firstLabel(sorted: *const SortedRects, r: Bbox) u32 {
    var it = sorted.overlapping(r);
    return it.next().?.label;
}

/// Whether figure `figure` of `sorted` covers all of `b`.
fn covers(sorted: *const SortedRects, figure: u32, b: Bbox) bool {
    var it = sorted.overlapping(b);
    var sum: DbuArea = 0;
    while (it.next()) |h| if (h.label == figure) {
        sum += h.clip.area();
    };
    return sum == b.area();
}

/// Whether `c` is at least `space` from every box of `cuts`.
fn clear(c: Bbox, cuts: []const Bbox, space: Dbu) bool {
    const space2 = geom.mulWide(space, space);
    for (cuts) |other| if (rects.bboxGap2(c, other) < space2) return false;
    return true;
}

/// A cut's four neighbours: its box moved `pitch` right, left, up, down.
fn neighbours(b: Bbox, pitch: Dbu) [4]Bbox {
    var out: [4]Bbox = undefined;
    for (&out, [4][2]i64{ .{ pitch, 0 }, .{ -pitch, 0 }, .{ 0, pitch }, .{ 0, -pitch } }) |*o, d| o.* = .{ .xlo = b.xlo + d[0], .ylo = b.ylo + d[1], .xhi = b.xhi + d[0], .yhi = b.yhi + d[1] };
    return out;
}

fn grown(b: Bbox, by: i64) Bbox {
    return .{ .xlo = b.xlo - by, .ylo = b.ylo - by, .xhi = b.xhi + by, .yhi = b.yhi + by };
}

/// The most `figure` extends round `b` on every side, up to `cap`; null
/// when it does not hold `b`.
fn margin(sorted: *const SortedRects, figure: u32, b: Bbox, cap: i64) ?i64 {
    if (!covers(sorted, figure, b)) return null;
    var lo: i64 = 0;
    var hi = cap;
    while (lo < hi) {
        const mid = lo + @divTrunc(hi - lo + 1, 2);
        if (covers(sorted, figure, grown(b, mid))) lo = mid else hi = mid - 1;
    }
    return lo;
}
