//! Spacing family: how close two shapes may come. In: one layer (two for
//! the cross-layer kinds), pruned at the rule's own limit, never narrower.
//! Out: one violation per offending pair, at the midpoint of the points it
//! measured. Pairs within one merged figure have no gap and are skipped.
//! Ported from crates/check/src/drc/rules/spacing.rs (`min_spacing`,
//! `min_spacing_diff`, `projection_spacing`, `facing_gap`, `prl_spacing`,
//! `wide_dependent`); the end-of-line and corner kinds are in
//! `spacing_ends.zig`, the table kinds in `spacing_table.zig`.
//!
//! Contents:
//! - `pub fn minSpacing(c: *const Ctx, r: LayerLimit) Error!Verdict`
//! - `pub fn minSpacingDiff(c: *const Ctx, r: TwoLayers) Error!Verdict`
//! - `pub fn projectionSpacing(c: *const Ctx, r: TwoLayers) Error!Verdict`
//! - `pub fn prlSpacing(c: *const Ctx, r: PrlSpacing) Error!Verdict`
//! - `pub fn wideDependent(c: *const Ctx, layer: LayerId, threshold: Dbu, attached: Dbu, limit: Dbu) Error!Verdict`
//! - `pub const Whole = struct`, `Whole.measure`, `Whole.at`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const proximity = @import("../proximity.zig");
const rows = @import("rows.zig");
const tables = @import("tables.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const runs_ = @import("runs.zig");
const parts = @import("parts.zig");

/// Judges every pair at its whole-shape distance, marked where
/// `proximity.wholeAt` marks it.
pub const Whole = struct {
    store: *const GeometryStore,

    pub fn measure(_: Whole, _: PolyId, _: PolyId, d2: DbuArea) ?DbuArea {
        return d2;
    }

    pub fn at(w: Whole, gpa: Allocator, a: PolyId, b: PolyId, d2: DbuArea) Allocator.Error!Point {
        return proximity.wholeAt(gpa, w.store, a, b, d2);
    }
};

const Gap = struct { gap: Dbu, at: Point };

/// Judges a pair when its figures' run within the limit reaches the
/// threshold; marks it whole.
const PrlJudge = struct {
    whole: Whole,
    runs: []const runs_.Facing,
    labels: []const u32,
    first_row: u32,
    limit: Dbu,
    threshold: Dbu,

    pub fn measure(j: PrlJudge, a: PolyId, b: PolyId, d2: DbuArea) ?DbuArea {
        const run = runs_.runWithin(j.runs, j.labels[@backingInt(a) - j.first_row], j.labels[@backingInt(b) - j.first_row], j.limit);
        return if (tables.prlHolds(run, j.threshold)) d2 else null;
    }

    pub fn at(j: PrlJudge, gpa: Allocator, a: PolyId, b: PolyId, d2: DbuArea) Allocator.Error!Point {
        return j.whole.at(gpa, a, b, d2);
    }
};

const Across = struct { pos: i64, out: i64, lo: i64, hi: i64 };

/// Same-layer minimum spacing, Euclidean between the two boundaries at any
/// angle (a fraction compared exactly, reported floored). `examined` counts
/// every candidate pair.
pub fn minSpacing(c: *const Ctx, r: rows.LayerLimit) Error!Verdict {
    const s = &c.s.p;
    if (!try proximity.prepareAny(c.gpa, c.store, r.layer, r.limit, s)) return report.refused;
    _ = try proximity.judgedPairs(c.gpa, c.store, c.rule, r.layer, r.limit, s, c.out, Whole{ .store = c.store });
    return scratch.ran(s.pairs.items.len);
}

/// Cross-layer minimum spacing, reported on `a`. No merged-figure
/// exemption: overlap is the violation. `examined` counts candidate pairs.
pub fn minSpacingDiff(c: *const Ctx, r: rows.TwoLayers) Error!Verdict {
    const s = &c.s.p;
    if (try s.validated.getAny(c.gpa, c.store, r.a) == null or try s.validated.getAny(c.gpa, c.store, r.b) == null) return report.refused;
    try proximity.crossPairs(c.gpa, c.store, r.a, r.b, r.limit, s);
    const limit2 = geom.mulWide(r.limit, r.limit);
    for (s.pairs.items, s.dists.items) |p, d2| {
        if (d2 >= limit2) continue;
        const at = try proximity.wholeAt(c.gpa, c.store, p.a, p.b, d2);
        try c.push(proximity.spacingViolation(c.rule, r.a, p.a, p.b, .{ .d2 = d2, .at = at }, r.limit));
    }
    return scratch.ran(s.pairs.items.len);
}

/// Two-layer spacing in KLayout's projection metric (sky130 lvtn.3b): each
/// pair within `limit` measures its least facing gap, 0 when the shapes
/// touch, overlap or nest. `examined` counts the pairs within `limit`.
pub fn projectionSpacing(c: *const Ctx, r: rows.TwoLayers) Error!Verdict {
    const s = &c.s.p;
    if (try s.validated.get(c.gpa, c.store, r.a) == null or try s.validated.get(c.gpa, c.store, r.b) == null) return report.refused;
    try proximity.crossPairs(c.gpa, c.store, r.a, r.b, r.limit, s);
    for (s.pairs.items, s.dists.items) |p, d2| {
        const found: ?Gap = if (d2 == 0)
            .{ .gap = 0, .at = try proximity.wholeAt(c.gpa, c.store, p.a, p.b, d2) }
        else
            facingGap(c.store, p.a, p.b);
        const g = found orelse continue;
        if (g.gap >= r.limit) continue;
        try c.push(proximity.spacingViolation(c.rule, r.a, p.a, p.b, .{ .d2 = geom.mulWide(g.gap, g.gap), .at = g.at }, r.limit));
    }
    return scratch.ran(s.pairs.items.len);
}

/// Parallel-run-length spacing: the run that of the merged figures' facing
/// edges at most `limit` apart. `examined` counts separate pairs whose run
/// reaches the threshold.
pub fn prlSpacing(c: *const Ctx, r: rows.PrlSpacing) Error!Verdict {
    const s = &c.s.p;
    if (!try proximity.prepareMerged(c.gpa, c.store, r.layer, r.limit, s)) return report.refused;
    const drawn = (try s.validated.get(c.gpa, c.store, r.layer)).?;
    try s.rects_a.build(c.gpa, c.store, r.layer, drawn);
    try rects.ownersOfInto(c.gpa, &s.layer_out, &s.rects_a, &c.s.owners);
    var runs: std.ArrayList(runs_.Facing) = .empty;
    defer runs.deinit(c.gpa);
    try runs_.facingRunsInto(c.gpa, c.store, r.layer, r.limit, &s.layer_out, c.s.owners.items, s.labels.items, &runs);
    const judge: PrlJudge = .{ .whole = .{ .store = c.store }, .runs = runs.items, .labels = s.labels.items, .first_row = c.store.polysOnLayer(r.layer).start, .limit = r.limit, .threshold = r.prl_threshold };
    return scratch.ran(try proximity.judgedPairs(c.gpa, c.store, c.rule, r.layer, r.limit, s, c.out, judge));
}

/// Wide-metal spacing, measured from the wide part of a shape (where a
/// `threshold` square fits in the merged layer) grown by `attached` within
/// the shape's own figure. `examined` counts separate pairs where either
/// polygon has a wide part.
pub fn wideDependent(c: *const Ctx, layer: LayerId, threshold: Dbu, attached: Dbu, limit: Dbu) Error!Verdict {
    const s = &c.s.p;
    const gpa = c.gpa;
    if (!try proximity.prepare(gpa, c.store, layer, limit, s)) return report.refused;
    const drawn = (try s.validated.get(gpa, c.store, layer)).?;
    var wide: std.ArrayList(Bbox) = .empty;
    defer wide.deinit(gpa);
    try scratch.wideRectsInto(gpa, drawn, threshold, &wide);
    try s.rects_a.build(gpa, c.store, layer, drawn);
    const first_row = c.store.polysOnLayer(layer).start;
    var wide_parts: parts.Parts = .{};
    defer wide_parts.deinit(gpa);
    try parts.widePartsInto(gpa, &s.rects_a, s.labels.items, first_row, wide.items, attached, &wide_parts);
    const poly_of = s.rects_a.poly_of_row.items;
    const limit2 = geom.mulWide(limit, limit);
    var examined: u64 = 0;
    for (s.pairs.items) |p| {
        const ia = @backingInt(p.a) - first_row;
        const ib = @backingInt(p.b) - first_row;
        // A hole row and its own outer are one polygon, never a spacing pair.
        if (s.labels.items[ia] == s.labels.items[ib] or poly_of[ia] == poly_of[ib]) continue;
        const wide_a = wide_parts.of(poly_of[ia]);
        const wide_b = wide_parts.of(poly_of[ib]);
        if (wide_a.len == 0 and wide_b.len == 0) continue;
        examined += 1;
        const d2 = @min(parts.rectsRingDist2(wide_a, c.store.polyVerts(p.b)), parts.rectsRingDist2(wide_b, c.store.polyVerts(p.a)));
        if (d2 >= limit2) continue;
        const at = try parts.wideAt(gpa, c.store, p.a, p.b, wide_a, wide_b, d2);
        try c.push(proximity.spacingViolation(c.rule, layer, p.a, p.b, .{ .d2 = d2, .at = at }, limit));
    }
    return scratch.ran(examined);
}

// ---- private ----

/// The least gap between an edge of `a` and an edge of `b` that are
/// parallel, face each other across it (each on the other's outward side)
/// and overlap in projection by a positive length, marked midway at the
/// middle of that overlap; null when no edges face.
fn facingGap(store: *const GeometryStore, a: PolyId, b: PolyId) ?Gap {
    const ra = store.polyVerts(a);
    const rb = store.polyVerts(b);
    var best: ?Gap = null;
    for (0..ra.xs.len) |i| for (0..rb.xs.len) |j| {
        const ea = geom.ops.ringEdge(ra.xs, ra.ys, i);
        const eb = geom.ops.ringEdge(rb.xs, rb.ys, j);
        const vertical = ea.a.x == ea.b.x;
        if (vertical != (eb.a.x == eb.b.x)) continue;
        const pa = across(ea, vertical);
        const pb = across(eb, vertical);
        const lo = @max(pa.lo, pb.lo);
        const hi = @min(pa.hi, pb.hi);
        if (hi <= lo or std.math.sign(pb.pos - pa.pos) != pa.out or std.math.sign(pa.pos - pb.pos) != pb.out) continue;
        const gap: Dbu = @intCast(@abs(pb.pos - pa.pos));
        if (best) |g| if (g.gap <= gap) continue;
        const x = rects.mid(pa.pos, pb.pos);
        const y = rects.mid(lo, hi);
        best = .{ .gap = gap, .at = if (vertical) .{ .x = x, .y = y } else .{ .x = y, .y = x } };
    };
    return best;
}

/// An axis edge's position across it, its outward sign, and its span.
fn across(e: Seg, vertical: bool) Across {
    return if (vertical)
        .{ .pos = e.a.x, .out = std.math.sign(e.b.y - e.a.y), .lo = @min(e.a.y, e.b.y), .hi = @max(e.a.y, e.b.y) }
    else
        .{ .pos = e.a.y, .out = -std.math.sign(e.b.x - e.a.x), .lo = @min(e.a.x, e.b.x), .hi = @max(e.a.x, e.b.x) };
}
