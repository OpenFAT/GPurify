//! Geometry builders: exact rectilinear shapes, each with a closed-form area
//! beside it, and the store they go into. In: integer parameters. Out:
//! vertex columns (`[2][n]i64`: xs, ys), a `GeometryStore` with the id every
//! push became, and seeded random layers that state their own coverage.
//! Outer boundaries wind counter-clockwise and holes clockwise. Ported from
//! crates/testgen/src/shapes.rs.
//!
//! Contents:
//! - `pub fn dbu(value: i64) Dbu`, `pub fn point(x: i64, y: i64) Point`
//! - `pub fn rect(xlo: i64, ylo: i64, xhi: i64, yhi: i64) [2][4]i64`, `pub fn hole(...) [2][4]i64`
//! - `pub fn lShape(x: i64, y: i64, arm: i64, thickness: i64) [2][6]i64`, `pub fn lShapeArea(arm: i64, thickness: i64) i128`
//! - `pub fn plusShape(cx: i64, cy: i64, arm: i64, thickness: i64) [2][12]i64`, `pub fn plusShapeArea(arm: i64, thickness: i64) i128`
//! - `pub fn uShape(x: i64, y: i64, arm: i64, thickness: i64, gap: i64) [2][8]i64`, `pub fn uShapeArea(arm: i64, thickness: i64, gap: i64) i128`
//! - `pub const Handle = enum(u32)`, `pub const LayoutBuilder = struct`, `LayoutBuilder.init(layer_count: u16) LayoutBuilder`,
//!   `deinit`, `push(lb: *LayoutBuilder, gpa: Allocator, layer: u16, xs: []const i64, ys: []const i64) Allocator.Error!Handle`,
//!   `shape(lb, gpa, layer: u16, s: anytype) Allocator.Error!Handle`, `rect(lb, gpa, layer: u16, xlo, ylo, xhi, yhi) Allocator.Error!Handle`,
//!   `finish(lb: *LayoutBuilder, gpa: Allocator, store: *GeometryStore, ids: *Ids) Allocator.Error!void`
//! - `pub const Ids = struct`, `Ids.deinit`, `Ids.of(ids: *const Ids, h: Handle) PolyId`
//! - `pub fn spacedPair(lb: *LayoutBuilder, gpa: Allocator, layer: u16, at: [2]i64, gap: i64, size: i64) Allocator.Error![2]Handle`
//! - `pub const RandomLayerSpec = struct`, `pub const RandomLayer = struct`,
//!   `pub fn randomRectilinearLayer(lb: *LayoutBuilder, gpa: Allocator, rng: *Rng, layer: u16, origin: [2]i64, spec: RandomLayerSpec) Allocator.Error!RandomLayer`
//! - `pub fn polygonArea(poly: Polygon) DbuArea`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Point = geom.Point;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const Polygon = geom.Polygon;
const Rng = @import("rng.zig").Rng;

/// A shape that was pushed but not yet identified: a pre-sort row, opaque
/// to anything but `Ids`.
pub const Handle = enum(u32) { _ };

/// Accumulates shapes and hands back a store plus the id each push became:
/// the store sorts its rows, so a shape's `PolyId` is not its push order.
pub const LayoutBuilder = struct {
    builder: geom.GeometryStoreBuilder = .empty,
    layer_count: u16,
    pushed: u32 = 0,

    /// A layout over `layer_count` layers; every pushed layer is below it.
    pub fn init(layer_count: u16) LayoutBuilder {
        return .{ .layer_count = layer_count };
    }

    pub fn deinit(lb: *LayoutBuilder, gpa: Allocator) void {
        lb.builder.deinit(gpa);
    }

    /// Pushes one open run as one polygon. Asserts parallel columns, at
    /// least three vertices, the layer in the table, and every coordinate
    /// in `dbu`'s domain.
    pub fn push(lb: *LayoutBuilder, gpa: Allocator, layer: u16, xs: []const i64, ys: []const i64) Allocator.Error!Handle {
        assert(xs.len == ys.len and xs.len >= 3 and layer < lb.layer_count);
        for (xs, ys) |x, y| _ = .{ dbu(x), dbu(y) };
        _ = try lb.builder.push(gpa, @fromBackingInt(layer), xs, ys);
        lb.pushed += 1;
        return @fromBackingInt(lb.pushed - 1);
    }

    /// Pushes a `[2][n]i64` shape from `rect`, `hole`, `lShape`,
    /// `plusShape` or `uShape`.
    pub fn shape(lb: *LayoutBuilder, gpa: Allocator, layer: u16, s: anytype) Allocator.Error!Handle {
        return lb.push(gpa, layer, &s[0], &s[1]);
    }

    pub fn rect(lb: *LayoutBuilder, gpa: Allocator, layer: u16, xlo: i64, ylo: i64, xhi: i64, yhi: i64) Allocator.Error!Handle {
        return lb.shape(gpa, layer, rectOf(xlo, ylo, xhi, yhi));
    }

    /// Sorts the shapes into `store` (cleared and refilled) and inverts the
    /// permutation into `ids`, so each push's `Handle` resolves to its row.
    pub fn finish(lb: *LayoutBuilder, gpa: Allocator, store: *GeometryStore, ids: *Ids) Allocator.Error!void {
        var permutation: std.ArrayList(u32) = .empty;
        defer permutation.deinit(gpa);
        try lb.builder.finish(gpa, lb.layer_count, store, &permutation);
        assert(permutation.items.len == lb.pushed);
        try ids.id.resize(gpa, lb.pushed);
        for (permutation.items, 0..) |old, new| ids.id.items[old] = @fromBackingInt(@intCast(new));
    }
};

/// Resolves `LayoutBuilder` handles to the rows the store gave them:
/// `id[handle] == PolyId`, the inverse of the builder's permutation.
pub const Ids = struct {
    id: std.ArrayList(PolyId) = .empty,

    pub fn deinit(ids: *Ids, gpa: Allocator) void {
        ids.id.deinit(gpa);
    }

    /// The row a handle became; a handle from another builder resolves
    /// silently to the wrong shape.
    pub fn of(ids: *const Ids, h: Handle) PolyId {
        return ids.id.items[@backingInt(h)];
    }
};

/// The shape of a `randomRectilinearLayer`.
pub const RandomLayerSpec = struct {
    /// Cells along each axis; the region is `cells * cell` square.
    cells: u32,
    /// Side of one cell, in database units.
    cell: i64,
    /// In `[0, 1]`: the expected covered fraction. Its square root is both
    /// the chance a cell is filled and the fraction its square covers.
    density: f64,
};

/// What `randomRectilinearLayer` produced, with the answer.
pub const RandomLayer = struct {
    /// Shapes emitted; each stays one polygon, since none touch.
    shapes: u32,
    /// Side of every shape.
    side: i64,
    /// Total covered area, exact: the shapes are disjoint.
    covered: i128,
    /// Side of the square region the shapes lie in.
    extent: i64,
};

/// Wraps an `i64` as a coordinate, asserting it lies within ±`max_abs_dbu`,
/// the bound that keeps every area product from overflowing.
pub fn dbu(value: i64) Dbu {
    assert(geom.inDomain(value));
    return value;
}

/// A report point, asserted as `dbu`.
pub fn point(x: i64, y: i64) Point {
    return .{ .x = dbu(x), .y = dbu(y) };
}

/// A rectangle, counter-clockwise from its lower-left corner. Asserts an
/// interior: empty is legal as a derived result but a bug in a generator.
pub fn rect(xlo: i64, ylo: i64, xhi: i64, yhi: i64) [2][4]i64 {
    return rectOf(xlo, ylo, xhi, yhi);
}

/// The same rectangle wound clockwise: a hole, pushed as its own polygon on
/// the layer of the shape it cuts.
pub fn hole(xlo: i64, ylo: i64, xhi: i64, yhi: i64) [2][4]i64 {
    var s = rectOf(xlo, ylo, xhi, yhi);
    std.mem.reverse(i64, &s[0]);
    std.mem.reverse(i64, &s[1]);
    return s;
}

/// An L with both arms `arm` long and `thickness` wide, its outer corner at
/// `(x, y)`, arms along +x and +y. Asserts `0 < thickness < arm`.
pub fn lShape(x: i64, y: i64, arm: i64, thickness: i64) [2][6]i64 {
    assert(thickness > 0 and thickness < arm);
    return .{
        .{ x, x + arm, x + arm, x + thickness, x + thickness, x },
        .{ y, y, y + thickness, y + thickness, y + arm, y + arm },
    };
}

/// `thickness * (2 * arm - thickness)`, under the `arm²` of its box.
pub fn lShapeArea(arm: i64, thickness: i64) i128 {
    return @as(i128, thickness) * (2 * @as(i128, arm) - thickness);
}

/// A plus centred on `(cx, cy)`: two bars `thickness` wide and `2 * arm`
/// long. Asserts `0 < thickness < 2 * arm`, `thickness` even.
pub fn plusShape(cx: i64, cy: i64, arm: i64, thickness: i64) [2][12]i64 {
    assert(thickness > 0 and thickness < 2 * arm and @mod(thickness, 2) == 0);
    const h = @divExact(thickness, 2);
    return .{
        .{ cx - h, cx + h, cx + h, cx + arm, cx + arm, cx + h, cx + h, cx - h, cx - h, cx - arm, cx - arm, cx - h },
        .{ cy - arm, cy - arm, cy - h, cy - h, cy + h, cy + h, cy + arm, cy + arm, cy + h, cy + h, cy - h, cy - h },
    };
}

/// The two bars less their double-counted crossing.
pub fn plusShapeArea(arm: i64, thickness: i64) i128 {
    return 4 * @as(i128, arm) * thickness - @as(i128, thickness) * thickness;
}

/// A U opening upward, lower-left at `(x, y)`, `2 * thickness + gap` wide and
/// `arm` tall; the notch is `gap` wide from `y + thickness` up. Asserts
/// `gap > 0` and `0 < thickness < arm`.
pub fn uShape(x: i64, y: i64, arm: i64, thickness: i64, gap: i64) [2][8]i64 {
    assert(gap > 0 and thickness > 0 and thickness < arm);
    const w = 2 * thickness + gap;
    return .{
        .{ x, x + w, x + w, x + thickness + gap, x + thickness + gap, x + thickness, x + thickness, x },
        .{ y, y, y + arm, y + arm, y + thickness, y + thickness, y + arm, y + arm },
    };
}

/// `thickness * (2 * arm + gap)`.
pub fn uShapeArea(arm: i64, thickness: i64, gap: i64) i128 {
    return @as(i128, thickness) * (2 * @as(i128, arm) + gap);
}

/// Two rectangles facing each other across an exact `gap` in x, centred on
/// `at`, each `size` wide and `2 * size` tall. Returns (left, right).
/// Asserts `gap` positive and even and `size` positive.
pub fn spacedPair(lb: *LayoutBuilder, gpa: Allocator, layer: u16, at: [2]i64, gap: i64, size: i64) Allocator.Error![2]Handle {
    assert(gap > 0 and @mod(gap, 2) == 0 and size > 0);
    const half = @divExact(gap, 2);
    const a = try lb.rect(gpa, layer, at[0] - half - size, at[1] - size, at[0] - half, at[1] + size);
    const b = try lb.rect(gpa, layer, at[0] + half, at[1] - size, at[0] + half + size, at[1] + size);
    return .{ a, b };
}

/// One layer of seeded rectilinear geometry at a known coverage: at most one
/// square per cell, a cell filled with probability `sqrt(density)`, every
/// square `floor(cell * density^(1/4))` on a side (clamped to `1..=cell-2`),
/// jittered with a unit of clearance on each side, so no two touch. The same
/// `rng` state gives the same layer. Asserts `density` in `[0, 1]`,
/// `cells > 0` and `cell >= 3`.
pub fn randomRectilinearLayer(lb: *LayoutBuilder, gpa: Allocator, rng: *Rng, layer: u16, origin: [2]i64, spec: RandomLayerSpec) Allocator.Error!RandomLayer {
    assert(spec.density >= 0 and spec.density <= 1 and spec.cells > 0 and spec.cell >= 3);
    const ideal = @as(f64, @floatFromInt(spec.cell)) * @sqrt(@sqrt(spec.density));
    // One unit of clearance each side: neighbours keep a gap of two.
    const side = std.math.clamp(@as(i64, @intFromFloat(ideal)), 1, spec.cell - 2);
    const slack = spec.cell - side - 2;
    var shapes: u32 = 0;
    for (0..spec.cells) |row| for (0..spec.cells) |col| {
        if (rng.unit() >= @sqrt(spec.density)) continue;
        // x draws before y: the order is part of the seed stream.
        const jx = if (slack > 0) rng.range(0, slack + 1) else 0;
        const jy = if (slack > 0) rng.range(0, slack + 1) else 0;
        const x = origin[0] + @as(i64, @intCast(col)) * spec.cell + 1 + jx;
        const y = origin[1] + @as(i64, @intCast(row)) * spec.cell + 1 + jy;
        _ = try lb.rect(gpa, layer, x, y, x + side, y + side);
        shapes += 1;
    };
    return .{ .shapes = shapes, .side = side, .covered = @as(i128, shapes) * side * side, .extent = @as(i64, spec.cells) * spec.cell };
}

/// A validated polygon's area: the outer ring less its holes (which wind
/// clockwise, so their doubled areas are already negative).
pub fn polygonArea(poly: Polygon) DbuArea {
    var doubled: DbuArea = 0;
    for (0..poly.ringCount()) |k| {
        const r = poly.ring(@intCast(k));
        doubled += geom.ops.area2(r.xs, r.ys);
    }
    return @divExact(doubled, 2);
}

// ---- private ----

fn rectOf(xlo: i64, ylo: i64, xhi: i64, yhi: i64) [2][4]i64 {
    assert(xhi > xlo and yhi > ylo);
    return .{ .{ xlo, xhi, xhi, xlo }, .{ ylo, ylo, yhi, yhi } };
}

/// Twice the signed area of a run; positive is counter-clockwise.
fn shoelace(xs: []const i64, ys: []const i64) i128 {
    var twice: i128 = 0;
    for (0..xs.len) |i| {
        const j = (i + 1) % xs.len;
        twice += @as(i128, xs[i]) * ys[j] - @as(i128, xs[j]) * ys[i];
    }
    return twice;
}

test "density is the expected coverage and one fills every cell" {
    // Oracle: hand-derived, as above: at density 1.0 all 16 cells hold a
    // 98 square; at 0.25 about half the cells hold a 707 square, 707^2 /
    // 1000^2 = 0.4998 each, 0.2499 expected coverage.
    const gpa = std.testing.allocator;
    var lb: LayoutBuilder = .init(1);
    defer lb.deinit(gpa);
    var rng = Rng.init(5);
    const full = try randomRectilinearLayer(&lb, gpa, &rng, 0, .{ 0, 0 }, .{ .cells = 4, .cell = 100, .density = 1.0 });
    try std.testing.expectEqual(@as(u32, 16), full.shapes);
    try std.testing.expectEqual(@as(i64, 98), full.side);
    try std.testing.expectEqual(@as(i128, 16 * 98 * 98), full.covered);
    var lb2: LayoutBuilder = .init(1);
    defer lb2.deinit(gpa);
    rng = Rng.init(5);
    const quarter = try randomRectilinearLayer(&lb2, gpa, &rng, 0, .{ 0, 0 }, .{ .cells = 100, .cell = 1000, .density = 0.25 });
    try std.testing.expectEqual(@as(i64, 707), quarter.side);
    const fraction = @as(f64, @floatFromInt(quarter.covered)) / 1e10;
    try std.testing.expect(@abs(fraction - 0.25) < 0.01);
}

test "l shape area matches its closed form and winds counter clockwise" {
    // Oracle: closed form, `thickness * (2 * arm - thickness)`, against the
    // shoelace of the drawn vertices, whose positive sign is
    // counter-clockwise.
    for ([_][2]i64{ .{ 100, 30 }, .{ 7, 1 }, .{ 1_000_000, 999_999 } }) |c| {
        const s = lShape(-5, 11, c[0], c[1]);
        const twice = shoelace(&s[0], &s[1]);
        try std.testing.expect(twice > 0);
        try std.testing.expectEqual(2 * lShapeArea(c[0], c[1]), twice);
    }
}

test "plus shape area matches its closed form and winds counter clockwise" {
    // Oracle: closed form, `4 * arm * thickness - thickness^2` (two bars less
    // their double-counted crossing), against the shoelace of the drawn
    // vertices, whose positive sign is counter-clockwise.
    for ([_][2]i64{ .{ 100, 30 }, .{ 50, 2 }, .{ 1_000, 998 } }) |c| {
        const s = plusShape(3, -9, c[0], c[1]);
        const twice = shoelace(&s[0], &s[1]);
        try std.testing.expect(twice > 0);
        try std.testing.expectEqual(2 * plusShapeArea(c[0], c[1]), twice);
    }
}

test "u shape area matches its closed form and winds counter clockwise" {
    // Oracle: closed form, `thickness * (2 * arm + gap)` (the bounding box
    // less the notch), against the shoelace of the drawn vertices, whose
    // positive sign is counter-clockwise.
    for ([_][3]i64{ .{ 100, 20, 40 }, .{ 9, 1, 3 }, .{ 500, 499, 2 } }) |c| {
        const s = uShape(0, 0, c[0], c[1], c[2]);
        const twice = shoelace(&s[0], &s[1]);
        try std.testing.expect(twice > 0);
        try std.testing.expectEqual(2 * uShapeArea(c[0], c[1], c[2]), twice);
    }
}

test "non convex shapes are smaller than their bounding box" {
    // Oracle: hand-derived. The L is 30 * 170 = 5100 against 100^2, the
    // plus 4 * 100 * 30 - 900 = 11 100 against 200^2, the U 20 * 240 = 4800
    // against 80 * 100.
    try std.testing.expect(lShapeArea(100, 30) < 100 * 100);
    try std.testing.expect(plusShapeArea(100, 30) < 200 * 200);
    try std.testing.expect(uShapeArea(100, 20, 40) < (2 * 20 + 40) * 100);
}
