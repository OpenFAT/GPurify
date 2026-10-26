//! Via family, cuts as a population counted on geometry (not nets). In: one
//! cut layer (not validated) and its candidate pairs with exact boundary
//! distances (or box centres). Out: lonely or under-served cuts, too-close
//! pairs inside an array or around a crowded cut, cuts in another's keep-out
//! zone. Ported from crates/check/src/drc/rules/via.rs (`max_cut_spacing`,
//! `redundant_via`, `via_array_spacing`, `cut_spacing`, `cut_class_spacing`,
//! `keep_out_zone`, `measured_pairs`, `isqrt_up`, `centres_dist2_x4`,
//! `centres_mid`, `of_class`).
//!
//! Contents:
//! - `pub fn maxCutSpacing(c: *const Ctx, r: MaxCutSpacing) Error!Verdict`
//! - `pub fn redundantVia(c: *const Ctx, r: RedundantVia) Error!Verdict`
//! - `pub fn viaArraySpacing(c: *const Ctx, r: ViaArraySpacing) Error!Verdict`
//! - `pub fn cutSpacing(c: *const Ctx, r: CutSpacing) Error!Verdict`
//! - `pub fn cutClassSpacing(c: *const Ctx, r: LayerTable) Error!Verdict`
//! - `pub fn keepOutZone(c: *const Ctx, r: KeepOutZone) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const SortedRects = rects.SortedRects;
const proximity = @import("../proximity.zig");
const distance = @import("../proximity_distance.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const ran = scratch.ran;

/// A cut's box centre, doubled so a half-unit centre stays whole.
const Centre = struct { x: i64, y: i64, b: Bbox };

/// A cut seen inside a keep-out zone: the cut, the part of it inside, and
/// which zone.
const Hit = struct { other: u32, part: Bbox, in_side: bool };

/// `LEF58_MAXSPACING` as OpenROAD reads it (DRC-034): every cut needs
/// another (of `others`, or of `cut` when null, with a different box) whose
/// box centre is at most `limit` from its own. One violation per lonely
/// cut, at its centre. `examined` counts cuts.
pub fn maxCutSpacing(c: *const Ctx, r: rows.MaxCutSpacing) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const from_rows = store.polysOnLayer(r.others orelse r.cut);
    const near = try gpa.alloc(Centre, from_rows.len());
    defer gpa.free(near);
    for (near, from_rows.start..) |*n, row| n.* = doubled(store.polyBbox(@fromBackingInt(@as(u32, @intCast(row)))));
    std.mem.sortUnstable(Centre, near, {}, struct {
        fn less(_: void, p: Centre, q: Centre) bool {
            return p.x < q.x or (p.x == q.x and p.y < q.y);
        }
    }.less);
    const reach: i128 = 2 * @as(i128, r.limit);
    const cuts = store.polysOnLayer(r.cut);
    for (cuts.start..cuts.end) |row_| {
        const row: PolyId = @fromBackingInt(@as(u32, @intCast(row_)));
        const own = doubled(store.polyBbox(row));
        // ponytail: a scan of the centres within `limit` along x; quadratic
        // only where many cuts share one column.
        var lo: usize = 0;
        var hi: usize = near.len;
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (@as(i128, near[m].x) < @as(i128, own.x) - reach) lo = m + 1 else hi = m;
        }
        var close = false;
        for (near[lo..]) |n| {
            if (@as(i128, n.x) > @as(i128, own.x) + reach) break;
            if (!std.meta.eql(n.b, own.b) and dist2(n, own) <= reach * reach) {
                close = true;
                break;
            }
        }
        if (close) continue;
        var nearest: ?i128 = null;
        for (near) |n| if (!std.meta.eql(n.b, own.b)) {
            const d2 = dist2(n, own);
            nearest = if (nearest) |m| @min(m, d2) else d2;
        };
        // The doubled distance halved, rounded up.
        const measured: report.Measurement, const limit: report.Measurement = if (nearest) |d2|
            .{ .length(@intCast(@divTrunc(isqrtUp(d2) + 1, 2))), .length(r.limit) }
        else
            .{ .count(0), .count(1) };
        try c.push(.{ .rule = c.rule, .layer = r.cut, .severity = .@"error", .at = rects.centre(own.b), .measured = measured, .limit = limit, .shape_a = row, .shape_b = report.no_shape });
    }
    return ran(cuts.len());
}

/// Every cut needs `min_count` cuts (itself included) within `within`,
/// nearest point to nearest point. One violation per under-served cut, at
/// its centre. `examined` counts cuts.
pub fn redundantVia(c: *const Ctx, r: rows.RedundantVia) Error!Verdict {
    const s = c.s;
    const cuts = c.store.polysOnLayer(r.layer);
    try measuredPairs(c, r.layer, r.within);
    const within2 = geom.mulWide(r.within, r.within);
    const neighbours = try counters(c, cuts.len());
    for (s.p.pairs.items, s.p.dists.items) |p, d2| if (d2 <= within2) {
        neighbours[@backingInt(p.a) - cuts.start] += 1;
        neighbours[@backingInt(p.b) - cuts.start] += 1;
    };
    for (neighbours, cuts.start..) |n, row_| {
        const count = n + 1;
        if (count >= r.min_count) continue;
        const row: PolyId = @fromBackingInt(@as(u32, @intCast(row_)));
        try c.finding(r.layer, rects.centre(c.store.polyBbox(row)), .count(count), .count(r.min_count), row);
    }
    return ran(cuts.len());
}

/// Clusters (components of "within `limit`") larger than the threshold are
/// arrays; every pair inside one is held to `limit`. One violation per
/// offending pair, marked as the spacing family marks. `examined` counts
/// pairs inside a qualifying cluster.
pub fn viaArraySpacing(c: *const Ctx, r: rows.ViaArraySpacing) Error!Verdict {
    const gpa = c.gpa;
    const p = &c.s.p;
    const cuts = c.store.polysOnLayer(r.layer);
    try measuredPairs(c, r.layer, r.limit);
    const limit2 = geom.mulWide(r.limit, r.limit);
    try proximity.labelPairsInto(gpa, cuts.start, cuts.len(), p.pairs.items, p.dists.items, limit2 + 1, &p.edges, &p.labels);
    // Cluster populations, keyed by the label (the least member offset).
    const population = try counters(c, cuts.len());
    for (p.labels.items) |l| population[l] += 1;
    var examined: u64 = 0;
    for (p.pairs.items, p.dists.items) |pair, d2| {
        const la = p.labels.items[@backingInt(pair.a) - cuts.start];
        const lb = p.labels.items[@backingInt(pair.b) - cuts.start];
        // Strictly larger: at the threshold is not yet an array.
        if (la != lb or population[la] <= r.array_threshold) continue;
        examined += 1;
        if (d2 >= limit2) continue;
        try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = try proximity.wholeAt(gpa, c.store, pair.a, pair.b, d2), .measured = .length(geom.ops.isqrt(d2)), .limit = .length(r.limit), .shape_a = pair.a, .shape_b = pair.b });
    }
    return ran(examined);
}

/// LEF cut spacing (`CENTERTOCENTER`, `ADJACENTCUTS n WITHIN w`): every
/// pair closer than `limit` where either cut has at least `adjacent` other
/// cuts strictly closer than `within` (every cut when `adjacent` is 0).
/// Distances are centre to centre with `center`, else boundary to boundary
/// with nested cuts at 0. One violation per offending pair. `examined`
/// counts the cuts held.
pub fn cutSpacing(c: *const Ctx, r: rows.CutSpacing) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const p = &c.s.p;
    const cuts = store.polysOnLayer(r.layer);
    // A centre lies in its box, so two boxes are never further apart than
    // their centres: pruning boxes at the reach keeps every pair.
    try measuredPairs(c, r.layer, if (r.adjacent == 0) r.limit else @max(r.limit, r.within));
    // Squared distances; at 2x for centres, so each compares as `scale d²`.
    const scale: i128 = if (r.center) 4 else 1;
    if (r.center) {
        for (p.pairs.items, p.dists.items) |pair, *d2| d2.* = centresDist2x4(store.polyBbox(pair.a), store.polyBbox(pair.b));
    } else {
        try p.holes.build(gpa, store, &.{r.layer});
        proximity.joinNested(store, &p.holes, p.pairs.items, p.dists.items);
    }
    const neighbours = try counters(c, cuts.len());
    const within2 = geom.mulWide(r.within, r.within) * scale;
    if (r.adjacent > 0) for (p.pairs.items, p.dists.items) |pair, d2| if (d2 < within2) {
        neighbours[@backingInt(pair.a) - cuts.start] += 1;
        neighbours[@backingInt(pair.b) - cuts.start] += 1;
    };
    const limit2 = geom.mulWide(r.limit, r.limit) * scale;
    for (p.pairs.items, p.dists.items) |pair, d2| {
        const held = neighbours[@backingInt(pair.a) - cuts.start] >= r.adjacent or neighbours[@backingInt(pair.b) - cuts.start] >= r.adjacent;
        if (d2 >= limit2 or !held) continue;
        // floor(sqrt(4 d² / 4)) is floor(d): an integer k has k² ≤ x exactly
        // when k² ≤ floor(x).
        const measured = if (r.center) geom.ops.isqrt(@divTrunc(d2, 4)) else geom.ops.isqrt(d2);
        const at = if (r.center) centresMid(store.polyBbox(pair.a), store.polyBbox(pair.b)) else try proximity.wholeAt(gpa, store, pair.a, pair.b, d2);
        try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = at, .measured = .length(measured), .limit = .length(r.limit), .shape_a = pair.a, .shape_b = pair.b });
    }
    var examined: u64 = 0;
    for (neighbours) |n| examined += @intFromBool(n >= r.adjacent);
    return ran(examined);
}

/// A cut-class spacing table (`LEF58_SPACINGTABLE` with `CUTCLASS` SIDE/END
/// entries): every pair of classed cuts closer than its cell. Apart along
/// one axis, the cells of the sides facing across it (the larger when
/// apart along both); overlapping in both projections, the largest of the
/// pair's four cells. `examined` counts pairs of classed cuts within the
/// largest cell.
pub fn cutClassSpacing(c: *const Ctx, r: rows.LayerTable) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const p = &c.s.p;
    const table = c.rs.cutClassTable(r.table);
    try measuredPairs(c, r.layer, std.mem.max(Dbu, table.space));
    try p.holes.build(gpa, store, &.{r.layer});
    proximity.joinNested(store, &p.holes, p.pairs.items, p.dists.items);
    var examined: u64 = 0;
    for (p.pairs.items, p.dists.items) |pair, d2| {
        const ba = store.polyBbox(pair.a);
        const bb = store.polyBbox(pair.b);
        const ca = table.classOf(ba.width(), ba.height()) orelse continue;
        const cb = table.classOf(bb.width(), bb.height()) orelse continue;
        examined += 1;
        // Row and column 2c are class c's END, 2c + 1 its SIDE.
        const cell = struct {
            fn f(t: @TypeOf(table), i: usize, j: usize, side_a: bool, side_b: bool) Dbu {
                return t.at(2 * i + @intFromBool(side_a), 2 * j + @intFromBool(side_b));
            }
        }.f;
        const apart_x = bb.xlo > ba.xhi or ba.xlo > bb.xhi;
        const apart_y = bb.ylo > ba.yhi or ba.ylo > bb.yhi;
        var need: Dbu = 0;
        if (apart_y) need = @max(need, cell(table, ca, cb, ba.width() > ba.height(), bb.width() > bb.height()));
        if (apart_x) need = @max(need, cell(table, ca, cb, ba.height() > ba.width(), bb.height() > bb.width()));
        if (!apart_x and !apart_y) for ([_][2]bool{ .{ false, false }, .{ false, true }, .{ true, false }, .{ true, true } }) |q| {
            need = @max(need, cell(table, ca, cb, q[0], q[1]));
        };
        if (d2 >= geom.mulWide(need, need)) continue;
        try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = try proximity.wholeAt(gpa, store, pair.a, pair.b, d2), .measured = .length(geom.ops.isqrt(d2)), .limit = .length(need), .shape_a = pair.a, .shape_b = pair.b });
    }
    return ran(examined);
}

/// LEF58 `KEEPOUTZONE` as OpenROAD's detailed router checks it
/// (`checKeepOutZone_main`): round each cut of `class` (never square), a
/// side zone (the cut lengthened by `side[1]` at each end, widened by
/// `side[0]` each side) and an end zone (lengthened by `end[0]`, widened by
/// `end[1]`); every other cut, of class `to` when given, overlapping either
/// with a positive area is a finding measuring its area inside the two, at
/// the centre of that area's box. `examined` counts the class's cuts.
pub fn keepOutZone(c: *const Ctx, r: rows.KeepOutZone) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const cuts = store.polysOnLayer(r.layer);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    for (cuts.start..cuts.end) |row| {
        const b = store.polyBbox(@fromBackingInt(@as(u32, @intCast(row))));
        if (r.to) |to| if (!ofClass(b, to)) continue;
        try boxes.append(gpa, b);
        try labels.append(gpa, @intCast(row));
    }
    var others: SortedRects = .{};
    defer others.deinit(gpa);
    try others.build(gpa, boxes.items, labels.items);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    var examined: u64 = 0;
    for (cuts.start..cuts.end) |row| {
        const cut: PolyId = @fromBackingInt(@as(u32, @intCast(row)));
        const b = store.polyBbox(cut);
        if (!ofClass(b, r.class)) continue;
        examined += 1;
        hits.clearRetainingCapacity();
        const zones = [2]Bbox{ zone(b, r.side[1], r.side[0]), zone(b, r.end[0], r.end[1]) };
        for (zones, [2]bool{ true, false }) |z, in_side| {
            var it = others.overlapping(z);
            while (it.next()) |h| if (h.label != row) try hits.append(gpa, .{ .other = h.label, .part = h.clip, .in_side = in_side });
        }
        std.mem.sortUnstable(Hit, hits.items, {}, struct {
            fn less(_: void, p: Hit, q: Hit) bool {
                return p.other < q.other or (p.other == q.other and p.in_side and !q.in_side);
            }
        }.less);
        var at: usize = 0;
        while (at < hits.items.len) {
            var end = at + 1;
            while (end < hits.items.len and hits.items[end].other == hits.items[at].other) end += 1;
            const group = hits.items[at..end];
            at = end;
            // Inside one zone, or inside both less what the two share.
            var sum: DbuArea = 0;
            var bounds = Bbox.empty;
            for (group) |h| {
                sum += h.part.area();
                bounds = bounds.merge(h.part);
            }
            if (group.len == 2) if (group[0].part.intersection(group[1].part)) |shared| {
                sum -= shared.area();
            };
            try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = rects.centre(bounds), .measured = .area(sum), .limit = .area(0), .shape_a = cut, .shape_b = @fromBackingInt(group[0].other) });
        }
    }
    return ran(examined);
}

// ---- private ----

fn doubled(b: Bbox) Centre {
    return .{ .x = b.xlo + b.xhi, .y = b.ylo + b.yhi, .b = b };
}

fn dist2(p: Centre, q: Centre) i128 {
    const dx: i128 = p.x - q.x;
    const dy: i128 = p.y - q.y;
    return dx * dx + dy * dy;
}

/// The least integer whose square is at least `n`, for `n >= 0`.
fn isqrtUp(n: i128) i128 {
    const root: i128 = geom.ops.isqrt(n);
    return if (root * root == n) root else root + 1;
}

/// Index, prune at `radius`, and measure every candidate pair of `layer`
/// into `s.p.pairs` and `s.p.dists`.
fn measuredPairs(c: *const Ctx, layer: LayerId, radius: Dbu) Error!void {
    const p = &c.s.p;
    try p.index_a.build(c.gpa, c.store, layer);
    try geom.index.candidatePairsInto(c.gpa, c.store, &p.index_a, radius, &p.pairs);
    try distance.pairDistancesInto(c.gpa, p.device, p.resident, c.store, p.pairs.items, radius, &p.dists);
}

/// `n` zeroed counters in `s.rect_start`.
fn counters(c: *const Ctx, n: u32) Allocator.Error![]u32 {
    const list = &c.s.rect_start;
    try list.resize(c.gpa, n);
    @memset(list.items, 0);
    return list.items;
}

/// Squared distance between two boxes' centres at twice the scale, so a
/// centre on a half unit is whole: `4 d²`.
fn centresDist2x4(a: Bbox, b: Bbox) DbuArea {
    const dx: i128 = (a.xlo + a.xhi) - (b.xlo + b.xhi);
    const dy: i128 = (a.ylo + a.yhi) - (b.ylo + b.yhi);
    return dx * dx + dy * dy;
}

/// The midpoint of two boxes' centres, floored.
fn centresMid(a: Bbox, b: Bbox) Point {
    return .{ .x = @divFloor(a.xlo + a.xhi + b.xlo + b.xhi, 4), .y = @divFloor(a.ylo + a.yhi + b.ylo + b.yhi, 4) };
}

/// Whether `b` is a cut of the class `(short, long)`, either way round.
fn ofClass(b: Bbox, class: rows.Pair) bool {
    return @min(b.width(), b.height()) == class[0] and @max(b.width(), b.height()) == class[1];
}

/// `b` grown by `along` on its long axis and `across` on its short one.
fn zone(b: Bbox, along: Dbu, across: Dbu) Bbox {
    const along_x = b.width() > b.height();
    const dx = if (along_x) along else across;
    const dy = if (along_x) across else along;
    return .{ .xlo = clamped(b.xlo - dx), .ylo = clamped(b.ylo - dy), .xhi = clamped(b.xhi + dx), .yhi = clamped(b.yhi + dy) };
}

fn clamped(v: i64) Dbu {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
