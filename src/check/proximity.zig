//! The pair pipeline drc and erc share: validate a layer once per run,
//! index and prune it at a rule's limit, measure every candidate pair
//! exactly, merge touching shapes into figures, and judge and report the
//! pairs closer than their limit. In: a `GeometryStore`, a rule row's layers
//! and limit, and a `Scratch` the rules refill. Out: violations appended to
//! a `Violations`, and the row's `Verdict`. Ported from
//! crates/check/src/drc/mod.rs (`Validated`, `Scratch`) and
//! crates/check/src/drc/rules/{mod,spacing}.rs (`join_nested`,
//! `label_pairs_into`, `prepare*`, `cross_pairs`, `judged_pairs`,
//! `pair_spacing_by_net`, `net_pair_spacing`, `nearest`, `whole_at`,
//! `spacing_violation`).
//!
//! Nets reach this file as a column, `poly_net` (one `u32` net per store
//! row, `no_net` for none), not as topology's `NetTable`: proximity sits
//! above topology, and the net rules read nothing else of it.
//!
//! Contents:
//! - `pub const no_net: u32`
//! - `pub const Validated = struct`, `deinit`, `getAny(v: *Validated, gpa: Allocator, store: *const GeometryStore, layer: LayerId) Allocator.Error!?*const ValidatedLayer`,
//!   `get(...)` (rectilinear only), `forget(v: *Validated, gpa: Allocator, layer: LayerId) void`
//! - `pub const Scratch = struct`, `deinit`
//! - `pub const Found = struct { d2: DbuArea, at: Point }`
//! - `pub const Nearest = struct`, `deinit`, `add(n: *Nearest, gpa: Allocator, p: Seg, q: Seg) Allocator.Error!void`, `result(n: *Nearest) ?Found`
//! - `pub const Need = union(enum) { unjudged, free, limit: Dbu }`
//! - `pub fn joinNested(store: *const GeometryStore, holes: *const Holes, pairs: []const Pair, dists: []DbuArea) void`
//! - `pub fn labelPairsInto(gpa: Allocator, first_row: u32, node_count: u32, pairs: []const Pair, dists: []const DbuArea, join_below: DbuArea, edges: *std.ArrayList([2]u32), labels: *std.ArrayList(u32)) Allocator.Error!void`
//! - `pub fn prepare(gpa: Allocator, store: *const GeometryStore, layer: LayerId, limit: Dbu, s: *Scratch) Error!bool`, `prepareAny`, `prepareMerged`
//! - `pub fn crossPairs(gpa: Allocator, store: *const GeometryStore, a: LayerId, b: LayerId, limit: Dbu, s: *Scratch) Error!void`
//! - `pub fn judgedPairs(gpa: Allocator, store: *const GeometryStore, rule: StrId, layer: LayerId, limit: Dbu, s: *const Scratch, out: *Violations, judge: anytype) Error!u64`
//! - `pub fn netPairSpacing(gpa: Allocator, store: *const GeometryStore, poly_net: []const u32, rule: StrId, a: LayerId, b: ?LayerId, widest: Dbu, s: *Scratch, out: *Violations, need: anytype) Error!Verdict`
//! - `pub fn pairSpacingByNet(gpa: Allocator, store: *const GeometryStore, rule: StrId, a: LayerId, b: ?LayerId, net_a: []const u32, net_b: []const u32, widest: Dbu, s: *Scratch, out: *Violations, need: anytype) Error!Verdict`
//! - `pub fn wholeAt(gpa: Allocator, store: *const GeometryStore, a: PolyId, b: PolyId, d2: DbuArea) Allocator.Error!Point`
//! - `pub fn spacingViolation(rule: StrId, layer: LayerId, a: PolyId, b: PolyId, found: Found, limit: Dbu) Violation`
//! - `pub const Error`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const SpatialIndex = geom.index.SpatialIndex;
const Pair = geom.index.Pair;
const ops = geom.ops;
const report = @import("report.zig");
const Violation = report.Violation;
const Violations = report.Violations;
const Verdict = report.Verdict;
const rects = @import("rects.zig");
const Holes = rects.Holes;
const LayerRects = rects.LayerRects;
const distance = @import("proximity_distance.zig");

/// `poly_net` of a row on no net.
pub const no_net: u32 = std.math.maxInt(u32);

pub const Error = distance.Error;

/// Each layer validated at most once per run, kept until the last rule that
/// reads it (the spine `forget`s it then). Invariant: `layers` and `state`
/// are sized once, to the store's layer count, so a returned pointer stays
/// valid until that layer is forgotten.
pub const Validated = struct {
    layers: std.ArrayList(ValidatedLayer) = .empty,
    state: std.ArrayList(State) = .empty,

    pub fn deinit(v: *Validated, gpa: Allocator) void {
        for (v.layers.items) |*l| l.deinit(gpa);
        v.layers.deinit(gpa);
        v.state.deinit(gpa);
    }

    /// `layer` validated with edges at any angle, or null when it does not
    /// validate (the rule is refused): for a rule proved at any angle.
    pub fn getAny(v: *Validated, gpa: Allocator, store: *const GeometryStore, layer: LayerId) Allocator.Error!?*const ValidatedLayer {
        const n = store.layerCount();
        if (v.state.items.len == 0) {
            try v.layers.ensureTotalCapacityPrecise(gpa, n);
            try v.state.ensureTotalCapacityPrecise(gpa, n);
            v.layers.appendNTimesAssumeCapacity(.empty, n);
            v.state.appendNTimesAssumeCapacity(.unknown, n);
        }
        assert(v.state.items.len == n);
        const l = @backingInt(layer);
        const slot = &v.layers.items[l];
        switch (v.state.items[l]) {
            .valid => return slot,
            .invalid => return null,
            .unknown => {
                const defect = try geom.view.validateLayer(gpa, store, layer, .any, slot);
                v.state.items[l] = if (defect == null) .valid else .invalid;
                return if (defect == null) slot else null;
            },
        }
    }

    /// `getAny`, also null when the layer has a non-axis edge: for a rule
    /// not yet proved on 45-degree geometry.
    pub fn get(v: *Validated, gpa: Allocator, store: *const GeometryStore, layer: LayerId) Allocator.Error!?*const ValidatedLayer {
        const l = try v.getAny(gpa, store, layer) orelse return null;
        return if (l.isRectilinear()) l else null;
    }

    /// Frees one layer's validation; asking again revalidates.
    pub fn forget(v: *Validated, gpa: Allocator, layer: LayerId) void {
        const l = @backingInt(layer);
        if (l >= v.state.items.len) return;
        v.layers.items[l].deinit(gpa);
        v.layers.items[l] = .empty;
        v.state.items[l] = .unknown;
    }

    // ---- private ----

    const State = enum(u8) { unknown, valid, invalid };
};

/// The buffers every pair rule refills; one `*Scratch` means rules run
/// sequentially. `device` picks the backend of the pair-distance kernel,
/// and `resident` is the run's device copy of the store it reads (borrowed
/// from the spine for the scratch's life; null uploads per call).
pub const Scratch = struct {
    device: geom.Device = .cpu,
    resident: ?*geom.ResidentStore = null,
    validated: Validated = .{},
    /// A boolean result: a merged layer.
    layer_out: ValidatedLayer = .empty,
    index_a: SpatialIndex = .empty,
    index_b: SpatialIndex = .empty,
    /// Candidate pairs from the prune: a superset, measured exactly.
    pairs: std.ArrayList(Pair) = .empty,
    /// The squared distance of each candidate pair.
    dists: std.ArrayList(DbuArea) = .empty,
    /// Hole rows bound to their outers, for the current rule's layers.
    holes: Holes = .{},
    edges: std.ArrayList([2]u32) = .empty,
    /// Per row of the prepared layer, its merged figure (least row offset).
    labels: std.ArrayList(u32) = .empty,
    rects_a: LayerRects = .{},

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.validated.deinit(gpa);
        s.layer_out.deinit(gpa);
        s.index_a.deinit(gpa);
        s.index_b.deinit(gpa);
        s.pairs.deinit(gpa);
        s.dists.deinit(gpa);
        s.holes.deinit(gpa);
        s.edges.deinit(gpa);
        s.labels.deinit(gpa);
        s.rects_a.deinit(gpa);
    }
};

/// A nearest approach: its squared distance and report point.
pub const Found = struct { d2: DbuArea, at: Point };

/// The nearest approach among pairs of axis-parallel segments fed by `add`:
/// its squared distance and the midpoint of the nearest points (floored).
/// Where the two nearest segments run alongside each other at that
/// distance, the point is that stretch's middle; collinear touching
/// stretches merge first, so a side split by a vertex is marked at the
/// middle of the whole run. The longest merged stretch wins; ties keep the
/// middle of the box bounding their midpoints, so the point does not depend
/// on ring order and maps with the layout under every symmetry of the
/// square.
pub const Nearest = struct {
    best: ?DbuArea = null,
    /// Each nearest pair's stretch, doubled.
    stretches: std.ArrayList(Stretch) = .empty,

    pub fn deinit(n: *Nearest, gpa: Allocator) void {
        n.stretches.deinit(gpa);
    }

    pub fn add(n: *Nearest, gpa: Allocator, p: Seg, q: Seg) Allocator.Error!void {
        const d2 = ops.segSegDist2(p, q);
        if (n.best) |b| {
            if (d2 > b) return;
            if (d2 < b) n.stretches.clearRetainingCapacity();
        }
        n.best = d2;
        // The boxes' overlap on each axis: a positive one is the run they
        // face over; either one's ends sum to twice the gap's middle.
        const pb = rects.segBbox(p);
        const qb = rects.segBbox(q);
        const xlo = @max(pb.xlo, qb.xlo);
        const xhi = @min(pb.xhi, qb.xhi);
        const ylo = @max(pb.ylo, qb.ylo);
        const yhi = @min(pb.yhi, qb.yhi);
        try n.stretches.append(gpa, if (xhi > xlo)
            .{ .vertical = false, .across = ylo + yhi, .lo = 2 * xlo, .hi = 2 * xhi }
        else if (yhi > ylo)
            .{ .vertical = true, .across = xlo + xhi, .lo = 2 * ylo, .hi = 2 * yhi }
        else
            .{ .vertical = false, .across = ylo + yhi, .lo = xlo + xhi, .hi = xlo + xhi });
    }

    /// The nearest approach of every pair added, null for none. Sorts the
    /// stretches in place.
    pub fn result(n: *Nearest) ?Found {
        const d2 = n.best orelse return null;
        const s = n.stretches.items;
        std.mem.sortUnstable(Stretch, s, {}, Stretch.lessThan);
        var longest: i64 = -1;
        var tied: [4]i64 = .{ 0, 0, 0, 0 };
        var at: usize = 0;
        while (at < s.len) {
            const first = s[at];
            var hi = first.hi;
            at += 1;
            while (at < s.len and s[at].vertical == first.vertical and s[at].across == first.across and s[at].lo <= hi) : (at += 1) {
                hi = @max(hi, s[at].hi);
            }
            // Exact: a stretch's ends are both even, a point's equal.
            const along = @divTrunc(first.lo + hi, 2);
            const x = if (first.vertical) first.across else along;
            const y = if (first.vertical) along else first.across;
            const run = hi - first.lo;
            if (run > longest) {
                longest = run;
                tied = .{ x, x, y, y };
            } else if (run == longest) {
                tied = .{ @min(tied[0], x), @max(tied[1], x), @min(tied[2], y), @max(tied[3], y) };
            }
        }
        return .{ .d2 = d2, .at = .{ .x = @divFloor(tied[0] + tied[1], 4), .y = @divFloor(tied[2] + tied[3], 4) } };
    }

    // ---- private ----

    /// `(vertical, across, lo, hi)`: the line's doubled middle across it and
    /// its extent along it, all doubled.
    const Stretch = struct {
        vertical: bool,
        across: i64,
        lo: i64,
        hi: i64,

        fn lessThan(_: void, a: Stretch, b: Stretch) bool {
            if (a.vertical != b.vertical) return !a.vertical;
            if (a.across != b.across) return a.across < b.across;
            if (a.lo != b.lo) return a.lo < b.lo;
            return a.hi < b.hi;
        }
    };
};

/// What a net rule requires of a pair, given its two nets.
pub const Need = union(enum) {
    /// The rule does not judge this pair.
    unjudged,
    /// Judged, and nothing required of it.
    free,
    /// Judged, held to this spacing (at most the rule's widest).
    limit: Dbu,
};

/// Zeroes the distance of every pair that overlaps without its boundaries
/// meeting: a shape nested in another's material, or an outer and its own
/// hole (boundary distance alone reads either as a gap). A shape inside a
/// hole keeps its distance to that hole, a real gap.
pub fn joinNested(store: *const GeometryStore, holes: *const Holes, pairs: []const Pair, dists: []DbuArea) void {
    assert(pairs.len == dists.len);
    for (pairs, dists) |p, *d2| {
        if (d2.* == 0) continue;
        const own_hole = contains(holes.holesOf(p.a), p.b) or contains(holes.holesOf(p.b), p.a);
        const nested = !holes.isHole(p.a) and !holes.isHole(p.b) and
            (rects.inMaterial(store, holes, p.a, store.firstVertex(p.b)) or rects.inMaterial(store, holes, p.b, store.firstVertex(p.a)));
        if (own_hole or nested) d2.* = 0;
    }
}

/// Labels rows `first_row..` of one layer by the components of the pairs
/// whose distance is below `join_below` (1 joins touching pairs), into
/// `labels`; a label is its component's least row offset.
pub fn labelPairsInto(gpa: Allocator, first_row: u32, node_count: u32, pairs: []const Pair, dists: []const DbuArea, join_below: DbuArea, edges: *std.ArrayList([2]u32), labels: *std.ArrayList(u32)) Allocator.Error!void {
    assert(pairs.len == dists.len);
    edges.clearRetainingCapacity();
    for (pairs, dists) |p, d2| {
        if (d2 < join_below) try edges.append(gpa, .{ @backingInt(p.a) - first_row, @backingInt(p.b) - first_row });
    }
    try geom.connectivity.componentsInto(gpa, node_count, edges.items, labels);
}

/// Validate (rectilinear), index, prune at `limit`, measure every candidate
/// pair, and label the layer's merged figures (pairs at distance zero).
/// False is refused, as is a layer with 45-degree edges.
pub fn prepare(gpa: Allocator, store: *const GeometryStore, layer: LayerId, limit: Dbu, s: *Scratch) Error!bool {
    if (try s.validated.get(gpa, store, layer) == null) return false;
    return prepareAny(gpa, store, layer, limit, s);
}

/// `prepare` for a rule proved on edges at any angle.
pub fn prepareAny(gpa: Allocator, store: *const GeometryStore, layer: LayerId, limit: Dbu, s: *Scratch) Error!bool {
    if (try s.validated.getAny(gpa, store, layer) == null) return false;
    const rows = store.polysOnLayer(layer);
    try s.index_a.build(gpa, store, layer);
    try geom.index.candidatePairsInto(gpa, store, &s.index_a, limit, &s.pairs);
    try distance.pairDistancesInto(gpa, s.device, s.resident, store, s.pairs.items, limit, &s.dists);
    try s.holes.build(gpa, store, &.{layer});
    joinNested(store, &s.holes, s.pairs.items, s.dists.items);
    try labelPairsInto(gpa, rows.start, rows.len(), s.pairs.items, s.dists.items, 1, &s.edges, &s.labels);
    return true;
}

/// `prepare`, then the layer merged into `s.layer_out`. False is refused.
pub fn prepareMerged(gpa: Allocator, store: *const GeometryStore, layer: LayerId, limit: Dbu, s: *Scratch) Error!bool {
    if (!try prepare(gpa, store, layer, limit, s)) return false;
    const drawn = (try s.validated.get(gpa, store, layer)).?;
    try geom.derive.mergeInto(gpa, drawn, &s.layer_out);
    return true;
}

/// Every pair of an `a` and a `b` polygon within `limit` into `s.pairs`,
/// its squared distance into `s.dists` (zero for a hole and its outer or a
/// nested pair). The caller has validated both layers.
pub fn crossPairs(gpa: Allocator, store: *const GeometryStore, a: LayerId, b: LayerId, limit: Dbu, s: *Scratch) Error!void {
    try s.index_b.build(gpa, store, b);
    try geom.index.crossLayerPairsInto(gpa, store, a, &s.index_b, limit, &s.pairs);
    try distance.pairDistancesInto(gpa, s.device, s.resident, store, s.pairs.items, limit, &s.dists);
    try s.holes.build(gpa, store, &.{ a, b });
    joinNested(store, &s.holes, s.pairs.items, s.dists.items);
}

/// The one same-layer kernel, after `prepare*`: every candidate pair in two
/// different figures that `judge` measures is examined, and reported when
/// closer than `limit`. `judge` provides `measure(a: PolyId, b: PolyId, d2:
/// DbuArea) ?DbuArea` (the distance to judge, null for a pair the rule does
/// not judge) and `at(gpa, a, b, d2) Allocator.Error!Point`. Returns the
/// examined count.
pub fn judgedPairs(gpa: Allocator, store: *const GeometryStore, rule: StrId, layer: LayerId, limit: Dbu, s: *const Scratch, out: *Violations, judge: anytype) Error!u64 {
    const first_row = store.polysOnLayer(layer).start;
    const limit2 = geom.mulWide(limit, limit);
    var examined: u64 = 0;
    for (s.pairs.items, s.dists.items) |p, whole| {
        if (s.labels.items[@backingInt(p.a) - first_row] == s.labels.items[@backingInt(p.b) - first_row]) continue;
        const d2 = judge.measure(p.a, p.b, whole) orelse continue;
        examined += 1;
        if (d2 >= limit2) continue;
        const at = try judge.at(gpa, p.a, p.b, d2);
        try out.push(gpa, spacingViolation(rule, layer, p.a, p.b, .{ .d2 = d2, .at = at }, limit));
    }
    return examined;
}

/// Spacing between shapes that their two nets decide, each row's net from
/// `poly_net`. Refused when a layer holds a shape on no net (or does not
/// validate). See `pairSpacingByNet`.
pub fn netPairSpacing(gpa: Allocator, store: *const GeometryStore, poly_net: []const u32, rule: StrId, a: LayerId, b: ?LayerId, widest: Dbu, s: *Scratch, out: *Violations, need: anytype) Error!Verdict {
    for ([2]?LayerId{ a, b }) |maybe| {
        const layer = maybe orelse continue;
        const rows = store.polysOnLayer(layer);
        for (poly_net[rows.start..rows.end]) |net| if (net == no_net) return report.refused;
    }
    const ra = store.polysOnLayer(a);
    const net_a = poly_net[ra.start..ra.end];
    const net_b = if (b) |other| poly_net[store.polysOnLayer(other).start..store.polysOnLayer(other).end] else net_a;
    return pairSpacingByNet(gpa, store, rule, a, b, net_a, net_b, widest, s, out, need);
}

/// Spacing between shapes that their two nets decide. On one layer (`b`
/// null) the pairs are shapes in different merged figures; across two, every
/// pair, overlap included, reported on `a`. `net_a[k]` is the net of `a`'s
/// row `k` (offset from its first row), `net_b` the same of `b`'s layer
/// (`net_a` again on one layer), every row with one; `need.needOf(net_a:
/// u32, net_b: u32) Need` gives the limit, at most `widest`. One violation
/// per pair closer than its limit; `examined` counts judged pairs.
pub fn pairSpacingByNet(gpa: Allocator, store: *const GeometryStore, rule: StrId, a: LayerId, b: ?LayerId, net_a: []const u32, net_b: []const u32, widest: Dbu, s: *Scratch, out: *Violations, need: anytype) Error!Verdict {
    if (b) |other| {
        if (try s.validated.get(gpa, store, a) == null or try s.validated.get(gpa, store, other) == null) return report.refused;
        try crossPairs(gpa, store, a, other, widest, s);
    } else if (!try prepare(gpa, store, a, widest, s)) return report.refused;
    const one_layer = b == null;
    const first_row = store.polysOnLayer(a).start;
    const first_b = if (b) |other| store.polysOnLayer(other).start else first_row;
    var examined: u64 = 0;
    for (s.pairs.items, s.dists.items) |p, d2| {
        if (one_layer and s.labels.items[@backingInt(p.a) - first_row] == s.labels.items[@backingInt(p.b) - first_row]) continue;
        const nb = if (one_layer) net_a[@backingInt(p.b) - first_row] else net_b[@backingInt(p.b) - first_b];
        const limit = switch (need.needOf(net_a[@backingInt(p.a) - first_row], nb)) {
            .unjudged => continue,
            .free => {
                examined += 1;
                continue;
            },
            .limit => |l| l,
        };
        examined += 1;
        if (d2 >= geom.mulWide(limit, limit)) continue;
        const at = try wholeAt(gpa, store, p.a, p.b, d2);
        try out.push(gpa, spacingViolation(rule, a, p.a, p.b, .{ .d2 = d2, .at = at }, limit));
    }
    return .{ .outcome = .ran, .examined = examined };
}

/// Where a pair measured boundary to boundary, `d2` apart, is reported: the
/// midpoint of its nearest approach (`Nearest`) when that measures `d2`;
/// else (a pair nested one in the other, 0 with its boundaries apart) the
/// middle of the overlap of the two rows' boxes. A pair with a non-axis
/// edge is marked at the midpoint of the first nearest pair of points in
/// ring order (floored). Quadratic in the ring sizes; only a violation pays.
pub fn wholeAt(gpa: Allocator, store: *const GeometryStore, a: PolyId, b: PolyId, d2: DbuArea) Allocator.Error!Point {
    const ra = store.polyVerts(a);
    const rb = store.polyVerts(b);
    const fallback = rects.gapMidpoint(store.polyBbox(a), store.polyBbox(b));
    if (hasDiagonal(ra) or hasDiagonal(rb)) {
        var best: ?ops.SegNear = null;
        for (0..ra.xs.len) |i| for (0..rb.xs.len) |j| {
            const near = ops.segSegNear2(ops.ringEdge(ra.xs, ra.ys, i), ops.ringEdge(rb.xs, rb.ys, j));
            if (best == null or near.d2 < best.?.d2) best = near;
        };
        // Touching boundaries mark the touch; a nested pair falls back.
        const n = best orelse return fallback;
        if ((n.d2 == 0) != (d2 == 0)) return fallback;
        return .{ .x = @divFloor(n.on_p2.x + n.on_q2.x, 4), .y = @divFloor(n.on_p2.y + n.on_q2.y, 4) };
    }
    var nearest: Nearest = .{};
    defer nearest.deinit(gpa);
    for (0..ra.xs.len) |i| for (0..rb.xs.len) |j| {
        try nearest.add(gpa, ops.ringEdge(ra.xs, ra.ys, i), ops.ringEdge(rb.xs, rb.ys, j));
    };
    const found = nearest.result() orelse return fallback;
    return if (found.d2 == d2) found.at else fallback;
}

/// The violation of a pair closer than `limit`: measured `isqrt(d2)`,
/// rounded toward zero, so a report never overstates the gap.
pub fn spacingViolation(rule: StrId, layer: LayerId, a: PolyId, b: PolyId, found: Found, limit: Dbu) Violation {
    return .{
        .rule = rule,
        .layer = layer,
        .severity = .@"error",
        .at = found.at,
        .measured = .length(ops.isqrt(found.d2)),
        .limit = .length(limit),
        .shape_a = a,
        .shape_b = b,
    };
}

// ---- private ----

fn contains(rows: []const PolyId, row: PolyId) bool {
    return std.mem.indexOfScalar(PolyId, rows, row) != null;
}

fn hasDiagonal(r: geom.Ring) bool {
    for (0..r.xs.len) |i| {
        const e = ops.ringEdge(r.xs, r.ys, i);
        if (e.a.x != e.b.x and e.a.y != e.b.y) return true;
    }
    return false;
}
