//! The net-aware spacing kinds: same-net or different-net spacing, and
//! stacked-cut spacing, each row's net read from the extraction's net column
//! (`poly_net`). In: one or two layers and the column. Out: one violation per
//! pair closer than its limit; refused without nets or when a shape is left
//! on no net. Ported from crates/check/src/drc/rules/spacing.rs
//! (`net_spacing`, `row_nets`, `stack_spacing`).
//!
//! Contents:
//! - `pub fn netSpacing(c: *const Ctx, r: NetSpacing) Error!Verdict`
//! - `pub fn stackSpacing(c: *const Ctx, r: StackSpacing) Error!Verdict`
//! - a private `Need` with the `needOf` method `pairSpacingByNet` calls

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const LayerRects = rects.LayerRects;
const SortedRects = rects.SortedRects;
const proximity = @import("../proximity.zig");
const no_net = proximity.no_net;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

/// What a net rule requires of a pair: the limit for the asked relation.
const Need = struct {
    same_net: bool,
    limit: geom.Dbu,

    pub fn needOf(n: Need, a: u32, b: u32) proximity.Need {
        return if ((a == b) == n.same_net) .{ .limit = n.limit } else .unjudged;
    }
};

/// Same-net or different-net spacing (gf180 NW.2a/2b), on one layer or
/// between two; a derived layer's shape on no net takes the one net of the
/// drawn shapes it overlaps (`RuleSet.netSources`). Refused without nets, or
/// when a shape is left on no net. `examined` counts pairs of the relation.
pub fn netSpacing(c: *const Ctx, r: rows.NetSpacing) Error!Verdict {
    const poly_net = c.poly_net orelse return report.refused;
    var of_a: std.ArrayList(u32) = .empty;
    defer of_a.deinit(c.gpa);
    if (!try rowNetsInto(c, poly_net, r.layer, &of_a)) return report.refused;
    var of_b: std.ArrayList(u32) = .empty;
    defer of_b.deinit(c.gpa);
    if (r.other) |b| if (!try rowNetsInto(c, poly_net, b, &of_b)) return report.refused;
    const need: Need = .{ .same_net = r.same_net, .limit = r.limit };
    const net_b = if (r.other != null) of_b.items else of_a.items;
    return proximity.pairSpacingByNet(c.gpa, c.store, c.rule, r.layer, r.other, of_a.items, net_b, r.limit, &c.s.p, c.out, need);
}

/// LEF `SPACING cutSpacing [SAMENET] LAYER secondLayer STACK` (DRC-065):
/// every pair of a cut on `a` and one on `b` closer than `limit`, overlap
/// included, except a same-net pair one of whose boxes covers the other's;
/// with `same_only`, same-net pairs only. A cut takes the lowest net of the
/// `metal` shapes it overlaps, none when it overlaps none. `examined` counts
/// pairs judged, the stacked ones included.
pub fn stackSpacing(c: *const Ctx, r: rows.StackSpacing) Error!Verdict {
    const poly_net = c.poly_net orelse return report.refused;
    const s = &c.s.p;
    const gpa = c.gpa;
    if (try s.validated.get(gpa, c.store, r.a) == null or try s.validated.get(gpa, c.store, r.b) == null) return report.refused;
    const drawn = try s.validated.get(gpa, c.store, r.metal) orelse return report.refused;
    try s.rects_a.build(gpa, c.store, r.metal, drawn);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try s.rects_a.rowLabelsInto(gpa, &labels);
    var netted: std.ArrayList(geom.Bbox) = .empty;
    defer netted.deinit(gpa);
    var nets: std.ArrayList(u32) = .empty;
    defer nets.deinit(gpa);
    for (s.rects_a.rects.items, labels.items) |box, row| if (poly_net[row] != no_net) {
        try netted.append(gpa, box);
        try nets.append(gpa, poly_net[row]);
    };
    var on_metal: SortedRects = .{};
    defer on_metal.deinit(gpa);
    try on_metal.build(gpa, netted.items, nets.items);
    try proximity.crossPairs(gpa, c.store, r.a, r.b, r.limit, s);
    const limit2 = geom.mulWide(r.limit, r.limit);
    var examined: u64 = 0;
    for (s.pairs.items, s.dists.items) |p, d2| {
        const np = netOf(&on_metal, c.store, p.a);
        const nq = netOf(&on_metal, c.store, p.b);
        const same = np != no_net and np == nq;
        if (r.same_only and !same) continue;
        examined += 1;
        const bp = c.store.polyBbox(p.a);
        const bq = c.store.polyBbox(p.b);
        if (same and (bp.contains(bq) or bq.contains(bp))) continue;
        if (d2 >= limit2) continue;
        const at = try proximity.wholeAt(gpa, c.store, p.a, p.b, d2);
        try c.push(proximity.spacingViolation(c.rule, r.a, p.a, p.b, .{ .d2 = d2, .at = at }, r.limit));
    }
    return scratch.ran(examined);
}

// ---- private ----

/// The lowest net of the metal rectangles a cut's box overlaps, `no_net`
/// for none.
fn netOf(on_metal: *const SortedRects, store: *const GeometryStore, cut: PolyId) u32 {
    var least: u32 = no_net;
    var hits = on_metal.overlapping(store.polyBbox(cut));
    while (hits.next()) |h| least = @min(least, h.label);
    return least;
}

/// Per store row of `layer`, its net, into `out`: its own, or, for a row on
/// no net, the one net of the rows of the layer's net sources its polygon
/// overlaps with positive area (every row of a polygon taking its
/// polygon's). False when a row is left on no net, or a layer does not
/// validate.
fn rowNetsInto(c: *const Ctx, poly_net: []const u32, layer: LayerId, out: *std.ArrayList(u32)) Error!bool {
    const gpa = c.gpa;
    const rows_on = c.store.polysOnLayer(layer);
    try out.resize(gpa, rows_on.len());
    @memcpy(out.items, poly_net[rows_on.start..rows_on.end]);
    if (std.mem.indexOfScalar(u32, out.items, no_net) == null) return true;
    const s = &c.s.p;
    var own: LayerRects = .{};
    defer own.deinit(gpa);
    try own.build(gpa, c.store, layer, try s.validated.get(gpa, c.store, layer) orelse return false);
    const sources = c.rs.netSources(layer);
    var under: std.ArrayList(SortedRects) = .empty;
    defer {
        for (under.items) |*u| u.deinit(gpa);
        under.deinit(gpa);
    }
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    for (sources) |source| {
        var lr: LayerRects = .{};
        defer lr.deinit(gpa);
        try lr.build(gpa, c.store, source, try s.validated.get(gpa, c.store, source) orelse return false);
        try lr.rowLabelsInto(gpa, &labels);
        var sorted: SortedRects = .{};
        try sorted.build(gpa, lr.rects.items, labels.items);
        try under.append(gpa, sorted);
    }
    var found: std.ArrayList(u32) = .empty;
    defer found.deinit(gpa);
    for (0..own.len()) |poly| {
        found.clearRetainingCapacity();
        for (own.of(@intCast(poly))) |box| for (under.items) |*sorted| {
            var hits = sorted.overlapping(box);
            while (hits.next()) |h| if (poly_net[h.label] != no_net) try found.append(gpa, poly_net[h.label]);
        };
        std.mem.sortUnstable(u32, found.items, {}, std.sort.asc(u32));
        if (found.items.len == 0 or found.items[0] != found.items[found.items.len - 1]) continue;
        for (own.poly_of_row.items, out.items) |holder, *net| {
            if (holder == poly and net.* == no_net) net.* = found.items[0];
        }
    }
    return std.mem.indexOfScalar(u32, out.items, no_net) == null;
}
