//! Vias as the cuts joining two metal figures: LEF `MINIMUMCUT` (enough
//! cuts in a via on a wide wire) and `MAXVIASTACK` (no chain of stacked
//! cuts too tall). In: the cut layers and their metals, merged. Out: one
//! violation per cut of a short via, or per cut topping a too-tall chain.
//! Ported from crates/check/src/drc/rules/via.rs (`minimum_cut`,
//! `via_stack`).
//!
//! Contents:
//! - `pub fn minimumCut(c: *const Ctx, r: MinimumCut) Error!Verdict`
//! - `pub fn viaStack(c: *const Ctx, r: ViaStack) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const SortedRects = rects.SortedRects;
const proximity_inside = @import("../proximity_inside.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const ran = scratch.ran;

/// A cut keyed by the figures it joins (`other` 0 for none, else figure +
/// 1, so a cut on no figure sorts first).
const Keyed = struct {
    wide: u32,
    other: u32,
    row: u32,

    fn less(_: void, p: Keyed, q: Keyed) bool {
        if (p.wide != q.wide) return p.wide < q.wide;
        if (p.other != q.other) return p.other < q.other;
        return p.row < q.row;
    }

    fn sameVia(p: Keyed, q: Keyed) bool {
        return p.wide == q.wide and p.other == q.other;
    }
};

/// A long wide region's rectangle and its `wide` figure.
const Long = struct { r: Bbox, figure: u32 };

/// LEF `MINIMUMCUT`: every via held by the wide part of `wide` (where a
/// `width + 1` square fits) needs `min_count` cuts, a via being the cuts
/// that join one `wide` figure to one `other` figure, split by `within`
/// when given. With `thin` (`LENGTH length WITHIN distance`), the vias held
/// are instead those on no wide part, on a wide wire's own figure, closer
/// than `distance` to that wire, whose wide region's longer box side
/// exceeds `length`. One violation per cut of a short via. `examined`
/// counts held vias.
pub fn minimumCut(c: *const Ctx, r: rows.MinimumCut) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    var wide_figures: ValidatedLayer = .empty;
    defer wide_figures.deinit(gpa);
    var other_figures: ValidatedLayer = .empty;
    defer other_figures.deinit(gpa);
    if (!try proximity_inside.mergedInto(gpa, store, r.wide, &c.s.p, &wide_figures)) return report.refused;
    if (!try proximity_inside.mergedInto(gpa, store, r.other, &c.s.p, &other_figures)) return report.refused;
    const drawn = (try c.s.p.validated.get(gpa, store, r.wide)).?;
    var part: std.ArrayList(Bbox) = .empty;
    defer part.deinit(gpa);
    try scratch.wideRectsInto(gpa, drawn, r.width + 1, &part);
    var on_wide: SortedRects = .{};
    defer on_wide.deinit(gpa);
    var on_other: SortedRects = .{};
    defer on_other.deinit(gpa);
    try rects.figureRectsInto(gpa, &wide_figures, &on_wide);
    try rects.figureRectsInto(gpa, &other_figures, &on_other);
    var long: std.ArrayList(Long) = .empty;
    defer long.deinit(gpa);
    if (r.thin) |thin| try longRegionsInto(gpa, part.items, &on_wide, thin[0], &long);
    var on_part: SortedRects = .{};
    defer on_part.deinit(gpa);
    {
        const zeros = try gpa.alloc(u32, part.items.len);
        defer gpa.free(zeros);
        @memset(zeros, 0);
        try on_part.build(gpa, part.items, zeros);
    }
    // Each cut on a wide figure, keyed by the figures it joins.
    var keyed: std.ArrayList(Keyed) = .empty;
    defer keyed.deinit(gpa);
    const cuts = store.polysOnLayer(r.cut);
    for (cuts.start..cuts.end) |row| {
        const b = store.polyBbox(@fromBackingInt(@as(u32, @intCast(row))));
        const w = leastLabel(&on_wide, b) orelse continue;
        const o = if (leastLabel(&on_other, b)) |f| f + 1 else 0;
        try keyed.append(gpa, .{ .wide = w, .other = o, .row = @intCast(row) });
    }
    std.mem.sortUnstable(Keyed, keyed.items, {}, Keyed.less);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var groups: std.ArrayList([2]u32) = .empty;
    defer groups.deinit(gpa);
    var examined: u64 = 0;
    var at: usize = 0;
    while (at < keyed.items.len) {
        var end = at + 1;
        while (end < keyed.items.len and keyed.items[at].sameVia(keyed.items[end])) end += 1;
        const via = keyed.items[at..end];
        at = end;
        // Groups of the via's cuts, by `within`.
        edges.clearRetainingCapacity();
        for (0..via.len) |i| for (i + 1..via.len) |j| {
            const joined = if (r.within) |d| rects.bboxGap2(box(c, via[i].row), box(c, via[j].row)) < geom.mulWide(d, d) else i == 0;
            if (joined) try edges.append(gpa, .{ @intCast(i), @intCast(j) });
        };
        try geom.connectivity.componentsInto(gpa, @intCast(via.len), edges.items, &labels);
        groups.clearRetainingCapacity();
        for (labels.items, via) |l, k| try groups.append(gpa, .{ l, k.row });
        std.mem.sortUnstable([2]u32, groups.items, {}, struct {
            fn less(_: void, p: [2]u32, q: [2]u32) bool {
                return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
            }
        }.less);
        var g: usize = 0;
        while (g < groups.items.len) {
            var g_end = g + 1;
            while (g_end < groups.items.len and groups.items[g_end][0] == groups.items[g][0]) g_end += 1;
            const group = groups.items[g..g_end];
            g = g_end;
            var any_on_part = false;
            for (group) |m| any_on_part = any_on_part or leastLabel(&on_part, box(c, m[1])) != null;
            const held = if (r.thin) |thin| blk: {
                // A thin wire's via: on no wide part, near a long wide wire
                // of its own figure.
                if (any_on_part) break :blk false;
                const reach = geom.mulWide(thin[1], thin[1]);
                for (group) |m| for (long.items) |l| {
                    if (l.figure == via[0].wide and rects.bboxGap2(box(c, m[1]), l.r) < reach) break :blk true;
                };
                break :blk false;
            } else any_on_part;
            if (!held) continue;
            examined += 1;
            const count: u32 = @intCast(group.len);
            if (count >= r.min_count) continue;
            for (group) |m| try c.finding(r.cut, rects.centre(box(c, m[1])), .count(count), .count(r.min_count), @fromBackingInt(m[1]));
        }
    }
    return ran(examined);
}

/// LEF `MAXVIASTACK`: the tallest chain of overlapping cuts, one per layer
/// of the stack (bottom to top), through each cut; each cut at height
/// `max_height + 1` of a taller chain is reported once. With `single`, the
/// stack alternates metal and cut layers, and a cut of a via of two or more
/// cuts (joining the same two metal figures) stacks with nothing.
/// `examined` counts cuts.
pub fn viaStack(c: *const Ctx, r: rows.ViaStack) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const layers = c.rs.stacks.get(r.stack);
    // The stack's cut layers and their cuts, CSR by layer.
    var stack: std.ArrayList(LayerId) = .empty;
    defer stack.deinit(gpa);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var cut_rows: std.ArrayList(u32) = .empty;
    defer cut_rows.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try start.append(gpa, 0);
    var examined: u64 = 0;
    if (r.single) {
        const metal_count = (layers.len + 1) / 2;
        const metals = try gpa.alloc(SortedRects, metal_count);
        defer gpa.free(metals);
        @memset(metals, .{});
        defer for (metals) |*m| m.deinit(gpa);
        var figures: ValidatedLayer = .empty;
        defer figures.deinit(gpa);
        for (metals, 0..) |*m, k| {
            if (!try proximity_inside.mergedInto(gpa, store, layers[2 * k], &c.s.p, &figures)) return report.refused;
            try rects.figureRectsInto(gpa, &figures, m);
        }
        var keyed: std.ArrayList(Keyed) = .empty;
        defer keyed.deinit(gpa);
        var i: usize = 1;
        while (i < layers.len) : (i += 2) {
            const k = i / 2;
            const rows_ = store.polysOnLayer(layers[i]);
            examined += rows_.len();
            keyed.clearRetainingCapacity();
            for (rows_.start..rows_.end) |row| {
                const b = store.polyBbox(@fromBackingInt(@as(u32, @intCast(row))));
                const below = if (leastLabel(&metals[k], b)) |f| f + 1 else 0;
                const above = if (k + 1 < metals.len) if (leastLabel(&metals[k + 1], b)) |f| f + 1 else 0 else 0;
                try keyed.append(gpa, .{ .wide = below, .other = above, .row = @intCast(row) });
            }
            std.mem.sortUnstable(Keyed, keyed.items, {}, Keyed.less);
            var at: usize = 0;
            while (at < keyed.items.len) {
                var end = at + 1;
                while (end < keyed.items.len and keyed.items[at].sameVia(keyed.items[end])) end += 1;
                if (end == at + 1) try addCut(c, keyed.items[at].row, &boxes, &cut_rows);
                at = end;
            }
            try stack.append(gpa, layers[i]);
            try start.append(gpa, @intCast(boxes.items.len));
        }
    } else {
        for (layers) |l| {
            const rows_ = store.polysOnLayer(l);
            examined += rows_.len();
            for (rows_.start..rows_.end) |row| try addCut(c, @intCast(row), &boxes, &cut_rows);
            try stack.append(gpa, l);
            try start.append(gpa, @intCast(boxes.items.len));
        }
    }
    // Per cut: the tallest chain ending at it from below (`down`) and
    // starting at it upward (`up`).
    const down = try gpa.alloc(u32, boxes.items.len);
    defer gpa.free(down);
    const up = try gpa.alloc(u32, boxes.items.len);
    defer gpa.free(up);
    try chainInto(gpa, boxes.items, start.items, .down, down);
    try chainInto(gpa, boxes.items, start.items, .up, up);
    const over: u32 = @as(u32, r.max_height) + 1;
    for (stack.items, start.items[0..stack.items.len], start.items[1..]) |layer, from, to| {
        for (from..to) |k| {
            if (down[k] != over) continue;
            try c.finding(layer, rects.centre(boxes.items[k]), .count(down[k] + up[k] - 1), .count(r.max_height), @fromBackingInt(cut_rows.items[k]));
        }
    }
    return ran(examined);
}

// ---- private ----

fn box(c: *const Ctx, row: u32) Bbox {
    return c.store.polyBbox(@fromBackingInt(row));
}

/// The least label of the rectangles of `sorted` overlapping `b`.
fn leastLabel(sorted: *const SortedRects, b: Bbox) ?u32 {
    var it = sorted.overlapping(b);
    var least: ?u32 = null;
    while (it.next()) |h| least = if (least) |l| @min(l, h.label) else h.label;
    return least;
}

/// The wide part's merged regions whose longer box side exceeds `length`,
/// each rectangle labelled with its `wide` figure.
fn longRegionsInto(gpa: Allocator, part: []const Bbox, on_wide: *const SortedRects, length: Dbu, out: *std.ArrayList(Long)) Error!void {
    var raw: ValidatedLayer = .empty;
    defer raw.deinit(gpa);
    var regions: ValidatedLayer = .empty;
    defer regions.deinit(gpa);
    try scratch.boxesLayer(gpa, part, &raw);
    try geom.boolean.unionInto(gpa, &raw, &ValidatedLayer.empty, &regions);
    var pieces: std.ArrayList(Bbox) = .empty;
    defer pieces.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, &regions, &pieces, &start);
    for (start.items[0 .. start.items.len - 1], start.items[1..], 0..) |from, to, idx| {
        const b = regions.get(@intCast(idx)).bbox();
        if (@max(b.width(), b.height()) <= length or from == to) continue;
        var it = on_wide.overlapping(pieces.items[from]);
        const figure = (it.next() orelse continue).label;
        for (pieces.items[from..to]) |p| try out.append(gpa, .{ .r = p, .figure = figure });
    }
}

fn addCut(c: *const Ctx, row: u32, boxes: *std.ArrayList(Bbox), cut_rows: *std.ArrayList(u32)) Allocator.Error!void {
    try boxes.append(c.gpa, box(c, row));
    try cut_rows.append(c.gpa, row);
}

/// Per cut, the tallest chain of overlapping cuts reaching it from the
/// layer below (`down`) or above (`up`), itself included.
fn chainInto(gpa: Allocator, boxes: []const Bbox, start: []const u32, comptime dir: enum { down, up }, heights: []u32) Allocator.Error!void {
    @memset(heights, 1);
    const n = start.len - 1;
    var under: SortedRects = .{};
    defer under.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    for (0..n) |step| {
        const i = if (dir == .down) step else n - 1 - step;
        if ((dir == .down and i == 0) or (dir == .up and i == n - 1)) continue;
        const prev = if (dir == .down) i - 1 else i + 1;
        labels.clearRetainingCapacity();
        for (start[prev]..start[prev + 1]) |k| try labels.append(gpa, @intCast(k));
        try under.build(gpa, boxes[start[prev]..start[prev + 1]], labels.items);
        for (start[i]..start[i + 1]) |k| {
            var it = under.overlapping(boxes[k]);
            var best: ?u32 = null;
            while (it.next()) |h| best = @max(best orelse 0, heights[h.label]);
            if (best) |b| heights[k] = b + 1;
        }
    }
}
