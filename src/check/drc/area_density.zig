//! Windowed density: a square window swept over the die in steps, each
//! window's covered area inside the die over the whole window (a window
//! hanging past the die counts the outside as empty, KLayout's
//! `padding_zero`); the balance of two masks per window; a layer's density
//! held to the band its coverage by another falls in. In: the merged layers
//! clipped to the die, and the window areas from `density.zig`'s row kernel.
//! Out: one violation per offending window, at its centre. Ported from
//! crates/check/src/drc/rules/area.rs (`density`, `density_balance`,
//! `cover_density`, `Owners`).
//!
//! Contents:
//! - `pub fn density(c: *const Ctx, r: Density) Error!Verdict`
//! - `pub fn densityBalance(c: *const Ctx, r: DensityBalance) Error!Verdict`
//! - `pub fn coverDensity(c: *const Ctx, r: CoverDensity) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const rects = @import("../rects.zig");
const Verdict = report.Verdict;
const Measurement = report.Measurement;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const area = @import("area.zig");
const toF64 = area.toF64;
const density_kernel = @import("density.zig");
const Grid = density_kernel.Grid;

/// The boxes of a layer's outer rows, gathered on first use:
/// the owner of a density window.
const Owners = struct {
    store: *const GeometryStore,
    layer: *const ValidatedLayer,
    by_xlo: std.ArrayList(struct { box: Bbox, row: u32 }) = .empty,

    fn deinit(o: *Owners, gpa: Allocator) void {
        o.by_xlo.deinit(gpa);
    }

    /// The lowest outer row whose box `region` contains, else the lowest
    /// outer row, else no shape for an empty layer.
    fn owner(o: *Owners, gpa: Allocator, region: Bbox) Allocator.Error!PolyId {
        if (o.by_xlo.items.len == 0) {
            for (0..o.layer.len()) |p| {
                const row = o.layer.get(@intCast(p)).provenance();
                try o.by_xlo.append(gpa, .{ .box = o.store.polyBbox(row), .row = @backingInt(row) });
            }
        }
        // ponytail: a linear scan per offending window; sort by xlo and
        // bisect if a die with many violations makes this slow.
        var least: u32 = std.math.maxInt(u32);
        var any: u32 = std.math.maxInt(u32);
        for (o.by_xlo.items) |e| {
            any = @min(any, e.row);
            if (e.box.xlo >= region.xlo and e.box.xlo <= region.xhi and region.contains(e.box)) least = @min(least, e.row);
        }
        return @fromBackingInt(if (least != std.math.maxInt(u32)) least else any);
    }
};

/// A `window` square swept over the die in `step`s, each window's covered
/// area over the whole window, held to `limit` by `sense`; one violation
/// per offending window, at its centre, on the lowest outer row it holds.
/// `examined` counts windows; an empty die is skipped.
pub fn density(c: *const Ctx, r: rows.Density) Error!Verdict {
    const gpa = c.gpa;
    const die = area.dieOf(c.store, r.boundary, c.drawn);
    if (die.isEmpty()) return skipped();
    if (!try area.mergeWithin(c, r.layer, die)) return report.refused;
    const grid = Grid.over(die, r.window, r.step) orelse return report.refused;
    var areas: std.ArrayList(i64) = .empty;
    defer areas.deinit(gpa);
    try density_kernel.windowAreasInto(gpa, c.s.p.device, grid, c.s.rects.items, &areas);
    const denominator = toF64(geom.mulWide(grid.side, grid.side));
    var owners: Owners = .{ .store = c.store, .layer = (try c.s.p.validated.get(gpa, c.store, r.layer)).? };
    defer owners.deinit(gpa);
    for (areas.items, 0..) |covered, w| {
        const fraction = toF64(covered) / denominator;
        if (!Measurement.ratio(fraction).violates(.ratio(r.limit), r.sense)) continue;
        const window = grid.window(w);
        try c.finding(r.layer, rects.centre(window), .ratio(fraction), .ratio(r.limit), try owners.owner(gpa, window));
    }
    return scratch.ran(grid.count());
}

/// Two masks' balance per window: the lesser covered area over the
/// greater, windows as `density`'s. A window neither covers is not judged.
/// One violation per window below `limit`, on `a`, naming no shape.
/// `examined` counts windows; an empty die is skipped.
pub fn densityBalance(c: *const Ctx, r: rows.DensityBalance) Error!Verdict {
    const gpa = c.gpa;
    const die = area.dieOf(c.store, r.boundary, c.drawn);
    if (die.isEmpty()) return skipped();
    const grid = Grid.over(die, r.window, r.step) orelse return report.refused;
    var first: std.ArrayList(i64) = .empty;
    defer first.deinit(gpa);
    var second: std.ArrayList(i64) = .empty;
    defer second.deinit(gpa);
    if (!try area.mergeWithin(c, r.a, die)) return report.refused;
    try density_kernel.windowAreasInto(gpa, c.s.p.device, grid, c.s.rects.items, &first);
    if (!try area.mergeWithin(c, r.b, die)) return report.refused;
    try density_kernel.windowAreasInto(gpa, c.s.p.device, grid, c.s.rects.items, &second);
    for (first.items, second.items, 0..) |x, y, w| {
        const lo = @min(x, y);
        const hi = @max(x, y);
        if (hi == 0) continue;
        const balance = toF64(lo) / toF64(hi);
        if (balance < r.limit) try c.finding(r.a, rects.centre(grid.window(w)), .ratio(balance), .ratio(r.limit), report.no_shape);
    }
    return scratch.ran(grid.count());
}

/// A layer's density per window held to the band its coverage by `cover`
/// falls in, windows as `density`'s. One violation per window below its
/// band's density, on the layer, naming no shape. `examined` counts
/// windows; an empty die is skipped.
pub fn coverDensity(c: *const Ctx, r: rows.CoverDensity) Error!Verdict {
    const gpa = c.gpa;
    const die = area.dieOf(c.store, r.boundary, c.drawn);
    if (die.isEmpty()) return skipped();
    const grid = Grid.over(die, r.window, r.step) orelse return report.refused;
    const bands = c.rs.coverBands(r.bands);
    const whole = toF64(geom.mulWide(grid.side, grid.side));
    var covers: std.ArrayList(i64) = .empty;
    defer covers.deinit(gpa);
    var held: std.ArrayList(i64) = .empty;
    defer held.deinit(gpa);
    if (!try area.mergeWithin(c, r.cover, die)) return report.refused;
    try density_kernel.windowAreasInto(gpa, c.s.p.device, grid, c.s.rects.items, &covers);
    if (!try area.mergeWithin(c, r.layer, die)) return report.refused;
    try density_kernel.windowAreasInto(gpa, c.s.p.device, grid, c.s.rects.items, &held);
    for (covers.items, held.items, 0..) |cov, mine, w| {
        const need = bands.need(toF64(cov) / whole) orelse continue;
        const d = toF64(mine) / whole;
        if (d < need) try c.finding(r.layer, rects.centre(grid.window(w)), .ratio(d), .ratio(need), report.no_shape);
    }
    return scratch.ran(grid.count());
}

// ---- private ----

fn skipped() Verdict {
    return .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };
}
