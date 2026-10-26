//! Containment of merged figures, which drc's presence family and erc's
//! region rules share. In: two layers of a `GeometryStore` and a `Scratch`.
//! Out: one violation per inner figure not inside the outer layer (its area
//! left outside), or per figure whether it shares area with a tag layer.
//! Ported from crates/check/src/drc/rules/presence.rs (`inside_where`,
//! `tagged_figures`, with `hosts`, `rects_of`, `octilinear_pair`) and
//! crates/check/src/drc/rules/mod.rs (`merged`).
//!
//! Contents:
//! - `pub fn insideWhere(gpa: Allocator, store: *const GeometryStore, rule: StrId, inner: LayerId, outer: LayerId, s: *Scratch, out: *Violations, judge: anytype) Allocator.Error!Verdict`
//! - `pub fn taggedFigures(gpa: Allocator, store: *const GeometryStore, layer: LayerId, tag: LayerId, s: *Scratch, owner: *std.ArrayList(PolyId), shares: *std.ArrayList(bool)) Allocator.Error!bool`
//! - `pub fn mergedInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, s: *Scratch, out: *ValidatedLayer) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("report.zig");
const Violations = report.Violations;
const Verdict = report.Verdict;
const rects = @import("rects.zig");
const SortedRects = rects.SortedRects;
const Scratch = @import("proximity.zig").Scratch;

/// Which path two layers take: refused (one will not validate), the
/// rectangle path (both rectilinear), or the octilinear one.
const Pairing = enum { refused, rectilinear, octilinear };

/// A merged layer's rectangles, CSR by figure.
const Cut = struct {
    rects: std.ArrayList(Bbox) = .empty,
    start: std.ArrayList(u32) = .empty,

    fn deinit(c: *Cut, gpa: Allocator) void {
        c.rects.deinit(gpa);
        c.start.deinit(gpa);
    }

    fn of(c: *Cut, gpa: Allocator, figures: *const ValidatedLayer) Allocator.Error!void {
        try geom.rects.decomposeInto(gpa, figures, &c.rects, &c.start);
    }

    fn figure(c: *const Cut, f: u32) []const Bbox {
        return c.rects.items[c.start.items[f]..c.start.items[f + 1]];
    }

    fn count(c: *const Cut) u32 {
        return @intCast(c.start.items.len - 1);
    }
};

/// Each merged `inner` figure that `judge` takes (`judge.judge(owner:
/// PolyId) bool`, by its lowest drawn row) must lie inside `outer`, touching
/// its edge from inside allowed; one violation per figure that does not, its
/// area left outside measured. Where either layer has a 45-degree edge the
/// area outside is exact and reported rounded up, so a half unit reads 1.
/// `examined` counts judged figures; refused when a layer will not validate.
pub fn insideWhere(gpa: Allocator, store: *const GeometryStore, rule: StrId, inner: LayerId, outer: LayerId, s: *Scratch, out: *Violations, judge: anytype) Allocator.Error!Verdict {
    var fi: ValidatedLayer = .empty;
    defer fi.deinit(gpa);
    var fo: ValidatedLayer = .empty;
    defer fo.deinit(gpa);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    switch (try octilinearPair(gpa, store, inner, outer, s, &fi, &fo, &owners)) {
        .refused => return report.refused,
        .octilinear => return insideOctilinear(gpa, rule, inner, &fi, &fo, owners.items, out, judge),
        .rectilinear => {},
    }
    if (!try mergedInto(gpa, store, inner, s, &fi) or !try mergedInto(gpa, store, outer, s, &fo)) return report.refused;
    var inner_rects: Cut = .{};
    defer inner_rects.deinit(gpa);
    try inner_rects.of(gpa, &fi);
    var outer_rects: Cut = .{};
    defer outer_rects.deinit(gpa);
    try outer_rects.of(gpa, &fo);
    var outer_all: SortedRects = .{};
    defer outer_all.deinit(gpa);
    const zeros = try gpa.alloc(u32, outer_rects.rects.items.len);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    try outer_all.build(gpa, outer_rects.rects.items, zeros);
    try s.rects_a.build(gpa, store, inner, (try s.validated.get(gpa, store, inner)).?);
    try rects.ownersOfInto(gpa, &fi, &s.rects_a, &owners);
    const home = try gpa.alloc(?u32, fi.len());
    defer gpa.free(home);
    try hosts(gpa, &inner_rects, &outer_rects, home);
    var examined: u64 = 0;
    for (home, owners.items, 0..) |host, owner, figure| {
        if (!judge.judge(owner)) continue;
        examined += 1;
        if (host != null) continue;
        const mine = inner_rects.figure(@intCast(figure));
        var covered: DbuArea = 0;
        for (mine) |r| {
            var hits = outer_all.overlapping(r);
            while (hits.next()) |h| covered += h.clip.area();
        }
        try out.push(gpa, .{
            .rule = rule,
            .layer = inner,
            .severity = .@"error",
            .at = rects.gapMidpoint(mine[0], mine[0]),
            .measured = .area(geom.rects.coveredArea(mine) - covered),
            .limit = .area(0),
            .shape_a = owner,
            .shape_b = report.no_shape,
        });
    }
    return .{ .outcome = .ran, .examined = examined };
}

/// Each merged figure of `layer`, by its lowest drawn row, into `owner`, and
/// whether it shares area with `tag` (an edge or a corner is no share), into
/// `shares`; both cleared and refilled. False when either layer will not
/// validate (rectilinear).
pub fn taggedFigures(gpa: Allocator, store: *const GeometryStore, layer: LayerId, tag: LayerId, s: *Scratch, owner: *std.ArrayList(PolyId), shares: *std.ArrayList(bool)) Allocator.Error!bool {
    var figures: ValidatedLayer = .empty;
    defer figures.deinit(gpa);
    var tags: ValidatedLayer = .empty;
    defer tags.deinit(gpa);
    if (!try mergedInto(gpa, store, layer, s, &figures) or !try mergedInto(gpa, store, tag, s, &tags)) return false;
    var cut: Cut = .{};
    defer cut.deinit(gpa);
    try cut.of(gpa, &figures);
    var tag_cut: Cut = .{};
    defer tag_cut.deinit(gpa);
    try tag_cut.of(gpa, &tags);
    var tagged: SortedRects = .{};
    defer tagged.deinit(gpa);
    const zeros = try gpa.alloc(u32, tag_cut.rects.items.len);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    try tagged.build(gpa, tag_cut.rects.items, zeros);
    try s.rects_a.build(gpa, store, layer, (try s.validated.get(gpa, store, layer)).?);
    try rects.ownersOfInto(gpa, &figures, &s.rects_a, owner);
    try shares.resize(gpa, figures.len());
    for (shares.items, 0..) |*share, figure| {
        share.* = for (cut.figure(@intCast(figure))) |r| {
            var hits = tagged.overlapping(r);
            if (hits.next() != null) break true;
        } else false;
    }
    return true;
}

/// `layer` validated (rectilinear) and merged into `out`; false when it does
/// not validate.
pub fn mergedInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, s: *Scratch, out: *ValidatedLayer) Allocator.Error!bool {
    const drawn = try s.validated.get(gpa, store, layer) orelse return false;
    try geom.boolean.unionInto(gpa, drawn, &ValidatedLayer.empty, out);
    return true;
}

// ---- private ----

/// Where either layer has a slanted edge: both merged into `fa`, `fb`, with
/// the lowest drawn row inside each figure of the first into `owners`.
fn octilinearPair(gpa: Allocator, store: *const GeometryStore, first: LayerId, second: LayerId, s: *Scratch, fa: *ValidatedLayer, fb: *ValidatedLayer, owners: *std.ArrayList(PolyId)) Allocator.Error!Pairing {
    const a = try s.validated.getAny(gpa, store, first) orelse return .refused;
    const b = try s.validated.getAny(gpa, store, second) orelse return .refused;
    if (a.isRectilinear() and b.isRectilinear()) return .rectilinear;
    try geom.boolean.unionInto(gpa, a, &ValidatedLayer.empty, fa);
    try geom.boolean.unionInto(gpa, b, &ValidatedLayer.empty, fb);
    try rects.ownersByPointInto(gpa, fa, a, owners);
    return .octilinear;
}

/// `insideWhere` where a layer has a 45-degree edge: the parts of `fi`
/// outside `fo`, each inside exactly one inner figure, summed per figure.
fn insideOctilinear(gpa: Allocator, rule: StrId, inner: LayerId, fi: *const ValidatedLayer, fo: *const ValidatedLayer, owners: []const PolyId, out: *Violations, judge: anytype) Allocator.Error!Verdict {
    var rest: ValidatedLayer = .empty;
    defer rest.deinit(gpa);
    try geom.boolean.subtractionInto(gpa, fi, fo, &rest);
    const outside2 = try gpa.alloc(i128, fi.len());
    defer gpa.free(outside2);
    @memset(outside2, 0);
    const home = try gpa.alloc(?u32, rest.len());
    defer gpa.free(home);
    try rects.figuresHolding(gpa, fi, &rest, home);
    for (home, 0..) |h, part| {
        // At any angle a sliver rounding left outside every figure holds no
        // area of one.
        const figure = h orelse continue;
        const p = rest.get(@intCast(part));
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            outside2[figure] += geom.ops.area2(r.xs, r.ys);
        }
    }
    var examined: u64 = 0;
    for (outside2, owners, 0..) |twice, owner, figure| {
        if (!judge.judge(owner)) continue;
        examined += 1;
        if (twice == 0) continue;
        try out.push(gpa, .{
            .rule = rule,
            .layer = inner,
            .severity = .@"error",
            .at = rects.figurePoint(fi.get(@intCast(figure))),
            .measured = .area(@divTrunc(twice + 1, 2)),
            .limit = .area(0),
            .shape_a = owner,
            .shape_b = report.no_shape,
        });
    }
    return .{ .outcome = .ran, .examined = examined };
}

/// Per inner figure, into `home`: the outer figure covering all of it, or
/// null. Outer figures share no area, so a covered inner figure lies in
/// exactly one.
fn hosts(gpa: Allocator, inner: *const Cut, outer: *const Cut, home: []?u32) Allocator.Error!void {
    assert(home.len == inner.count());
    const labels = try gpa.alloc(u32, outer.rects.items.len);
    defer gpa.free(labels);
    for (0..outer.count()) |f| @memset(labels[outer.start.items[f]..outer.start.items[f + 1]], @intCast(f));
    var sorted: SortedRects = .{};
    defer sorted.deinit(gpa);
    try sorted.build(gpa, outer.rects.items, labels);
    for (home, 0..) |*slot, f| {
        const mine = inner.figure(@intCast(f));
        var covered: DbuArea = 0;
        var host: ?u32 = null;
        for (mine) |r| {
            var hits = sorted.overlapping(r);
            while (hits.next()) |h| {
                covered += h.clip.area();
                host = h.label;
            }
        }
        slot.* = if (covered == geom.rects.coveredArea(mine)) host else null;
    }
}
