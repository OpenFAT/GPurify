//! Layout-dependent effects of a transistor (catalog LVS-074): BSIM4's STI
//! stress distances `sa` and `sb` and well-proximity integrals `sca`,
//! `scb`, `scc`, measured from the drawn active area (OD) and well. In: the
//! layout graph, its design, the deck's `lvs lde` rows. Out: the graph with
//! those parameters on every transistor of a row's model the geometry lets
//! be measured, each only where its name is interned. Ported from
//! crates/check/src/lvs/lde.rs.
//!
//! BSIM4.6 ("Layout-Dependent Parasitics Model"): `SA`, `SB` are the
//! distances from the gate's two edges across the channel to the OD's
//! edges; for a ragged OD, `1/(SA + L/2) = Σ wᵢ/W · 1/(saᵢ + L/2)` over the
//! strips of the gate's width. The stress model reads them as a pair, so
//! the smaller is written `sa`. `SCA`..`SCC` are Silvaco's closed forms
//! ("Well Proximity and STI Stress Effect Parameters Extraction in
//! SmartDRC/LVS", 2022, `wpe`) from `SC1`..`SC4`, each the width-weighted
//! median distance from a gate edge to the first well edge outward, capped.
//! Limits: the gate (the marker) must be one axis-aligned rectangle inside
//! one stretch of OD; holes read as solid; `SD` is not written.
//!
//! Contents:
//! - `pub fn wpe(sc: [4]f64, w: f64, l: f64, scref: f64) [3]f64`
//! - `pub fn addLdeParams(gpa: Allocator, g: *Graph, design: Design, rows: []const LvsLde, layers: *const LayerTable, strings: *const StrTable, grid: Grid) Allocator.Error!void`
//! - private `AppendCtx`: its `rewrite` is `pub` only because `graph.rewriteParams` looks it up at comptime

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const GeometryStore = geom.GeometryStore;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const deck = @import("ingest").deck;
const LvsLde = deck.LvsLde;
const LayerTable = deck.LayerTable;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Param = graph.Param;
const Design = @import("project.zig").Design;

const Added = struct {
    device: u32,
    param: Param,

    fn less(_: void, a: Added, b: Added) bool {
        return a.device < b.device;
    }
};

const AppendCtx = struct {
    added: []const Added,

    pub fn rewrite(c: AppendCtx, gpa: Allocator, g: *const Graph, device: u32, out: *std.ArrayList(Param)) Allocator.Error!void {
        try out.appendSlice(gpa, g.paramsOf(device));
        var at = std.sort.lowerBound(Added, c.added, device, struct {
            fn order(want: u32, item: Added) std.math.Order {
                return std.math.order(want, item.device);
            }
        }.order);
        while (at < c.added.len and c.added[at].device == device) : (at += 1) try out.append(gpa, c.added[at].param);
    }
};

/// `addLdeParams`'s working lists, reused across devices.
const Scratch = struct {
    od: std.ArrayList(PolyId) = .empty,
    near: std.ArrayList(PolyId) = .empty,
    spans: std.ArrayList([2]f64) = .empty,
    crossings: std.ArrayList(f64) = .empty,
    merged: std.ArrayList([2]f64) = .empty,
    cuts: std.ArrayList(i64) = .empty,
    strips: std.ArrayList([2]f64) = .empty,
    seen: std.ArrayList([2]f64) = .empty,

    fn deinit(s: *Scratch, gpa: Allocator) void {
        inline for (@typeInfo(Scratch).@"struct".field_names) |f| @field(s, f).deinit(gpa);
    }
};

/// One layer's polygons sorted by left edge, and the widest's width, so a
/// window's candidates are a scan from one point.
const Sorted = struct {
    left: std.ArrayList(i64) = .empty,
    poly: std.ArrayList(PolyId) = .empty,
    widest: i64 = 0,

    fn deinit(t: *Sorted, gpa: Allocator) void {
        t.left.deinit(gpa);
        t.poly.deinit(gpa);
    }

    fn fill(t: *Sorted, gpa: Allocator, store: *const GeometryStore, layer: LayerId) Allocator.Error!void {
        const rows = store.polysOnLayer(layer);
        var pairs: std.ArrayList([2]i64) = .empty;
        defer pairs.deinit(gpa);
        t.widest = 0;
        for (rows.start..rows.end) |p| {
            const b = store.polyBbox(@fromBackingInt(@intCast(p)));
            try pairs.append(gpa, .{ b.xlo, @intCast(p) });
            t.widest = @max(t.widest, b.xhi - b.xlo);
        }
        std.mem.sortUnstable([2]i64, pairs.items, {}, struct {
            fn less(_: void, a: [2]i64, b: [2]i64) bool {
                return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
            }
        }.less);
        t.left.clearRetainingCapacity();
        t.poly.clearRetainingCapacity();
        for (pairs.items) |pr| {
            try t.left.append(gpa, pr[0]);
            try t.poly.append(gpa, @fromBackingInt(@intCast(pr[1])));
        }
    }

    /// The polygons whose box meets `window`, into `out`.
    ///
    /// ponytail: a scan from the first left edge a polygon as wide as the
    /// widest could start at; a layer of a few very wide polygons scans
    /// more, and a bucket grid is the upgrade.
    fn meetingInto(t: *const Sorted, gpa: Allocator, store: *const GeometryStore, window: Bbox, out: *std.ArrayList(PolyId)) Allocator.Error!void {
        out.clearRetainingCapacity();
        var at: usize = 0;
        while (at < t.left.items.len and t.left.items[at] < window.xlo - t.widest) at += 1;
        while (at < t.left.items.len and t.left.items[at] <= window.xhi) : (at += 1) {
            const p = t.poly.items[at];
            const b = store.polyBbox(p);
            if (b.xhi >= window.xlo and b.ylo <= window.yhi and b.yhi >= window.ylo) try out.append(gpa, p);
        }
    }
};

/// A gate's box and whether the channel runs along x.
const Gate = struct {
    bbox: Bbox,
    along_x: bool,

    /// `(lo, hi)` of the box along the channel, then across it.
    fn spans(g: Gate) [2][2]i64 {
        const x: [2]i64 = .{ g.bbox.xlo, g.bbox.xhi };
        const y: [2]i64 = .{ g.bbox.ylo, g.bbox.yhi };
        return if (g.along_x) .{ x, y } else .{ y, x };
    }
};

/// `SCA`, `SCB`, `SCC` from `sc = [SC1, SC2, SC3, SC4]`, the gate's `w`,
/// `l` and the model's `scref`, all in one unit (Silvaco's worked example:
/// 8.28, 1.351, 2.72, 2 µm, `W` 3, `L` 1, `SCREF` 0.95 give 0.345, 32.26n,
/// 10.41f): `SCA = SCREF²/(W L)·Σ` of `W (1/SC − 1/(SC+L))` for `SC1`,
/// `SC3` and `L (1/SC − 1/(SC+W))` for `SC2`, `SC4`; `SCB` (k = 10) and
/// `SCC` (k = 20) the sum over the edges of `1/(E·SCREF)·(SCREF/k·s·e^(−k s/
/// SCREF) + SCREF²/k²·e^(−k s/SCREF) − the same at s+E)`, `E` = `W` for
/// `SC2`, `SC4` and `L` for `SC1`, `SC3`.
pub fn wpe(sc: [4]f64, w: f64, l: f64, scref: f64) [3]f64 {
    const inv = struct {
        fn f(s: f64, depth: f64) f64 {
            return 1.0 / s - 1.0 / (s + depth);
        }
    }.f;
    const sca = scref * scref / (w * l) * (w * inv(sc[0], l) + l * inv(sc[1], w) + w * inv(sc[2], l) + l * inv(sc[3], w));
    const Tail = struct {
        fn term(k: f64, x: f64, r: f64) f64 {
            const e = @exp(-k * x / r);
            return r / k * x * e + r * r / (k * k) * e;
        }
        fn of(k: f64, s: f64, depth: f64, r: f64) f64 {
            return (term(k, s, r) - term(k, s + depth, r)) / (depth * r);
        }
        fn sum(k: f64, c: [4]f64, wd: f64, ln: f64, r: f64) f64 {
            return of(k, c[1], wd, r) + of(k, c[3], wd, r) + of(k, c[0], ln, r) + of(k, c[2], ln, r);
        }
    };
    return .{ sca, Tail.sum(10.0, sc, w, l, scref), Tail.sum(20.0, sc, w, l, scref) };
}

/// Adds `sa`, `sb` and, with a well, `sca`, `scb`, `scc` to every transistor
/// of `g` whose model a row names, each where its name is interned, in
/// metres or dimensionless. `g` must be `fromLayoutInto` of `design`. A
/// device whose gate is no rectangle inside one stretch of OD, or whose
/// layer was not computed, gets nothing.
pub fn addLdeParams(gpa: Allocator, g: *Graph, design: Design, rows: []const LvsLde, layers: *const LayerTable, strings: *const StrTable, grid: Grid) Allocator.Error!void {
    var names: [5]?StrId = undefined;
    for (&names, [_][]const u8{ "sa", "sb", "sca", "scb", "scc" }) |*n, text| n.* = strings.get(text);
    const any = for (names) |n| (if (n != null) break true) else false;
    if (rows.len == 0 or !any) return;
    const store = design.store;
    const metre = 1e-6 / @as(f64, @floatFromInt(grid.dbu_per_um));
    // Per device, the parameters to add, CSR built in row order below.
    var added: std.ArrayList(Added) = .empty;
    defer added.deinit(gpa);
    var od_sorted: Sorted = .{};
    defer od_sorted.deinit(gpa);
    var well_sorted: Sorted = .{};
    defer well_sorted.deinit(gpa);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    for (rows) |row| {
        const od_layer = layerOf(layers, strings, store, row.od) orelse continue;
        try od_sorted.fill(gpa, store, od_layer);
        const well_layer: ?LayerId = if (row.well) |w| layerOf(layers, strings, store, w.layer) else null;
        if (well_layer) |wl| try well_sorted.fill(gpa, store, wl);
        const max: f64 = @floatFromInt(row.max);
        for (0..g.deviceCount()) |d| {
            if (g.device_kind.items[d] != .mos or g.device_model.items[d] != row.model) continue;
            const bbox = rectangle(store, design.devices.marker.items[d]) orelse continue;
            const window: Bbox = .{ .xlo = bbox.xlo - row.max, .ylo = bbox.ylo - row.max, .xhi = bbox.xhi + row.max, .yhi = bbox.yhi + row.max };
            try od_sorted.meetingInto(gpa, store, window, &s.od);
            const along_x = try channel(gpa, store, s.od.items, bbox, &s) orelse continue;
            const gate: Gate = .{ .bbox = bbox, .along_x = along_x };
            const pair = try stress(gpa, store, s.od.items, gate, max, &s) orelse continue;
            for ([_]?StrId{ names[0], names[1] }, pair) |name, v| if (name) |n| try added.append(gpa, .{ .device = @intCast(d), .param = .{ .name = n, .value = v * metre } });
            if (well_layer == null) continue;
            const scref: f64 = @floatFromInt(row.well.?.scref);
            try well_sorted.meetingInto(gpa, store, window, &s.near);
            const spans = gate.spans();
            const lo: f64 = @floatFromInt(spans[0][0]);
            const hi: f64 = @floatFromInt(spans[0][1]);
            const alo: f64 = @floatFromInt(spans[1][0]);
            const ahi: f64 = @floatFromInt(spans[1][1]);
            // SC1, SC3: the edges of length W across the channel's ends;
            // SC2, SC4: the edges of length L beside it.
            const h = along_x;
            const sc = [4]f64{
                try wellDistance(gpa, store, s.near.items, h, lo, -1.0, spans[1], max, &s),
                try wellDistance(gpa, store, s.near.items, !h, alo, -1.0, spans[0], max, &s),
                try wellDistance(gpa, store, s.near.items, h, hi, 1.0, spans[1], max, &s),
                try wellDistance(gpa, store, s.near.items, !h, ahi, 1.0, spans[0], max, &s),
            };
            const w = ahi - alo;
            const l = hi - lo;
            const integrals = wpe(.{ sc[0] * metre, sc[1] * metre, sc[2] * metre, sc[3] * metre }, w * metre, l * metre, scref * metre);
            for (names[2..], integrals) |name, v| if (name) |n| try added.append(gpa, .{ .device = @intCast(d), .param = .{ .name = n, .value = v } });
        }
    }
    if (added.items.len == 0) return;
    // Stable by device: each device's additions in the order made.
    std.mem.sort(Added, added.items, {}, Added.less);
    try graph.rewriteParams(gpa, g, AppendCtx{ .added = added.items });
}

// ---- private ----

fn layerOf(layers: *const LayerTable, strings: *const StrTable, store: *const GeometryStore, name: StrId) ?LayerId {
    const layer = layers.id(strings, strings.resolve(name)) orelse return null;
    return if (store.isUncomputed(layer)) null else layer;
}

/// The intervals along x (`horizontal`) or y where the line at `at` on the
/// other axis lies inside some polygon, merged and ascending, into
/// `s.merged`. `at` is never a vertex coordinate (a strip's middle).
fn lineIntervals(gpa: Allocator, store: *const GeometryStore, polys: []const PolyId, horizontal: bool, at: f64, s: *Scratch) Allocator.Error!void {
    s.spans.clearRetainingCapacity();
    for (polys) |poly| {
        const r = store.polyVerts(poly);
        const along = if (horizontal) r.xs else r.ys;
        const across = if (horizontal) r.ys else r.xs;
        s.crossings.clearRetainingCapacity();
        for (0..along.len) |i| {
            const j = (i + 1) % along.len;
            const a0: f64 = @floatFromInt(along[i]);
            const c0: f64 = @floatFromInt(across[i]);
            const a1: f64 = @floatFromInt(along[j]);
            const c1: f64 = @floatFromInt(across[j]);
            if ((c0 < at) != (c1 < at)) try s.crossings.append(gpa, a0 + (at - c0) * (a1 - a0) / (c1 - c0));
        }
        std.mem.sortUnstable(f64, s.crossings.items, {}, lessF64);
        var k: usize = 0;
        while (k + 1 < s.crossings.items.len) : (k += 2) try s.spans.append(gpa, .{ s.crossings.items[k], s.crossings.items[k + 1] });
    }
    std.mem.sortUnstable([2]f64, s.spans.items, {}, lessFirst);
    s.merged.clearRetainingCapacity();
    for (s.spans.items) |sp| {
        if (s.merged.items.len > 0 and sp[0] <= s.merged.items[s.merged.items.len - 1][1]) {
            const last = &s.merged.items[s.merged.items.len - 1];
            last[1] = @max(last[1], sp[1]);
        } else try s.merged.append(gpa, sp);
    }
}

/// The strips the span `lo..hi` falls into at every vertex coordinate of
/// `polys` inside it: `(middle, width)` each, into `s.strips`.
fn strips(gpa: Allocator, store: *const GeometryStore, polys: []const PolyId, horizontal: bool, span: [2]i64, s: *Scratch) Allocator.Error!void {
    s.cuts.clearRetainingCapacity();
    try s.cuts.appendSlice(gpa, &span);
    for (polys) |poly| {
        const r = store.polyVerts(poly);
        for (if (horizontal) r.ys else r.xs) |c| if (c > span[0] and c < span[1]) try s.cuts.append(gpa, c);
    }
    std.mem.sortUnstable(i64, s.cuts.items, {}, std.sort.asc(i64));
    s.strips.clearRetainingCapacity();
    for (s.cuts.items[0 .. s.cuts.items.len - 1], s.cuts.items[1..]) |a, b| {
        if (a == b) continue;
        try s.strips.append(gpa, .{ @as(f64, @floatFromInt(a + b)) / 2.0, @floatFromInt(b - a) });
    }
}

/// `marker` as one axis-aligned rectangle, or null.
fn rectangle(store: *const GeometryStore, marker: PolyId) ?Bbox {
    const r = store.polyVerts(marker);
    const b = store.polyBbox(marker);
    for (r.xs, r.ys) |x, y| if ((x != b.xlo and x != b.xhi) or (y != b.ylo and y != b.yhi)) return null;
    return if (r.xs.len == 4 and b.xlo < b.xhi and b.ylo < b.yhi) b else null;
}

/// The channel's direction: the axis along which the OD runs on past the
/// gate on both sides, and not the other; null when not one axis.
fn channel(gpa: Allocator, store: *const GeometryStore, od: []const PolyId, bbox: Bbox, s: *Scratch) Allocator.Error!?bool {
    const cx = @as(f64, @floatFromInt(bbox.xlo + bbox.xhi)) / 2.0;
    const cy = @as(f64, @floatFromInt(bbox.ylo + bbox.yhi)) / 2.0;
    var beyond: [2]bool = undefined;
    for ([_]bool{ true, false }, &beyond) |horizontal, *out| {
        const centre = if (horizontal) cy else cx;
        const along = if (horizontal) cx else cy;
        const lo: f64 = @floatFromInt(if (horizontal) bbox.xlo else bbox.ylo);
        const hi: f64 = @floatFromInt(if (horizontal) bbox.xhi else bbox.yhi);
        try lineIntervals(gpa, store, od, horizontal, centre, s);
        out.* = for (s.merged.items) |m| (if (m[0] <= along and along <= m[1] and m[0] < lo and m[1] > hi) break true) else false;
    }
    if (beyond[0] and !beyond[1]) return true;
    if (!beyond[0] and beyond[1]) return false;
    return null;
}

/// `SA` and `SB`, smaller first, in database units, each strip's distance
/// capped at `max`; null where a strip of the gate is not inside the OD.
fn stress(gpa: Allocator, store: *const GeometryStore, od: []const PolyId, gate: Gate, max: f64, s: *Scratch) Allocator.Error!?[2]f64 {
    const sp = gate.spans();
    const lo: f64 = @floatFromInt(sp[0][0]);
    const hi: f64 = @floatFromInt(sp[0][1]);
    const length: f64 = @floatFromInt(sp[0][1] - sp[0][0]);
    const width: f64 = @floatFromInt(sp[1][1] - sp[1][0]);
    var inverse_low: f64 = 0.0;
    var inverse_high: f64 = 0.0;
    try strips(gpa, store, od, gate.along_x, sp[1], s);
    const owned = try gpa.dupe([2]f64, s.strips.items);
    defer gpa.free(owned);
    for (owned) |st| {
        try lineIntervals(gpa, store, od, gate.along_x, st[0], s);
        const iv = for (s.merged.items) |m| (if (m[0] <= lo and hi <= m[1]) break m) else return null;
        const low = @min(lo - iv[0], max);
        const high = @min(iv[1] - hi, max);
        inverse_low += st[1] / width / (low + length / 2.0);
        inverse_high += st[1] / width / (high + length / 2.0);
    }
    const low = 1.0 / inverse_low - length / 2.0;
    const high = 1.0 / inverse_high - length / 2.0;
    return .{ @min(low, high), @max(low, high) };
}

/// The distance from the gate edge at `edge` outward (`toward` ±1 along
/// `horizontal`'s axis) to the first well edge: the width-weighted median
/// over the edge's strips, each capped at `max`.
fn wellDistance(gpa: Allocator, store: *const GeometryStore, well: []const PolyId, horizontal: bool, edge: f64, toward: f64, span: [2]i64, max: f64, s: *Scratch) Allocator.Error!f64 {
    try strips(gpa, store, well, horizontal, span, s);
    const owned = try gpa.dupe([2]f64, s.strips.items);
    defer gpa.free(owned);
    s.seen.clearRetainingCapacity();
    for (owned) |st| {
        try lineIntervals(gpa, store, well, horizontal, st[0], s);
        var first = std.math.inf(f64);
        for (s.merged.items) |m| for (m) |end| {
            const d = (end - edge) * toward;
            if (d > 0.0) first = @min(first, d);
        };
        try s.seen.append(gpa, .{ @min(first, max), st[1] });
    }
    std.mem.sortUnstable([2]f64, s.seen.items, {}, lessFirst);
    var total: f64 = -0.0;
    for (s.seen.items) |x| total += x[1];
    var covered: f64 = 0.0;
    for (s.seen.items) |x| {
        covered += x[1];
        if (covered * 2.0 >= total) return x[0];
    }
    return max;
}

fn lessF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn lessFirst(_: void, a: [2]f64, b: [2]f64) bool {
    return a[0] < b[0];
}

test "the integrals reproduce the note's worked example" {
    // Oracle: the standard's worked example, Silvaco's application note
    // "Well Proximity and STI Stress Effect Parameters Extraction in
    // SmartDRC/LVS": SC1 to SC4 of 8.28, 1.351, 2.72 and 2 µm, W 3 µm,
    // L 1 µm and SCREF 0.95 µm print SCA=0.345, SCB=32.260n and
    // SCC=10.410f. SCA agrees to three figures; SCB and SCC fall off as
    // e^(-10 SC2/SCREF) and e^(-20 SC2/SCREF), so the note's SC2, printed to
    // the nanometre, carries ±0.53 % and ±1.05 % into them: held to 0.6 %
    // and 1.1 %. Breaks if an edge pairs with the wrong side length, or a
    // coefficient of the exponentials is off.
    for ([_]f64{ 1e-6, 1.0 }) |unit| {
        const r = wpe(.{ 8.28 * unit, 1.351 * unit, 2.72 * unit, 2.0 * unit }, 3.0 * unit, 1.0 * unit, 0.95 * unit);
        try std.testing.expect(@abs(r[0] - 0.345) <= 0.0015 * 0.345);
        try std.testing.expect(@abs(r[1] - 32.26e-9) <= 0.006 * 32.26e-9);
        try std.testing.expect(@abs(r[2] - 10.41e-15) <= 0.011 * 10.41e-15);
    }
}
