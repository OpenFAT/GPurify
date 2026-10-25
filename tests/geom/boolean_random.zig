//! The exact booleans over random operands, against a bitmap. Ported from
//! crates/geom/tests/core/boolean_random.rs.
//!
//! Each operand is a few random rectangles on a 32 × 32 integer grid, so every
//! cell lies wholly inside or outside every result. The oracle rasterises the
//! rectangles and applies the set operation cell by cell, without touching
//! the code under test; the engine's result is sampled at every cell centre
//! and must be the oracle's bitmap exactly. Exact equality of point sets
//! implies every algebraic law (commutativity, distributivity, de Morgan,
//! inclusion-exclusion), so the laws are checked through it.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const testgen = @import("testgen");
const prop = testgen.prop;
const Rng = testgen.Rng;
const LayerRect = prop.LayerRect;
const fx = @import("fixture.zig");
const ValidatedLayer = geom.ValidatedLayer;

/// Operands live in `[0, side)²`.
const side = 32;
const Bitmap = [side * side]bool;

// ---- private ----

/// One to five rectangles on each of three layers, any size, overlapping,
/// abutting or apart as the seed falls.
fn generate(arena: Allocator, rng: *Rng) Allocator.Error![]const LayerRect {
    var rects: std.ArrayList(LayerRect) = .empty;
    for (0..3) |layer| {
        const count = rng.range(1, 6);
        for (0..@intCast(count)) |_| {
            const x = rng.range(0, side - 1);
            const y = rng.range(0, side - 1);
            const w = rng.range(1, side - x + 1);
            const h = rng.range(1, side - y + 1);
            try rects.append(arena, .{ .layer = @intCast(layer), .box = .{ x, y, x + w, y + h } });
        }
    }
    return rects.items;
}

/// The cells a layer's rectangles cover.
fn raster(rects: []const LayerRect, layer: u16) Bitmap {
    var cells: Bitmap = @splat(false);
    for (rects) |r| {
        if (r.layer != layer) continue;
        for (@intCast(r.box[1])..@intCast(r.box[3])) |y| for (@intCast(r.box[0])..@intCast(r.box[2])) |x| {
            cells[y * side + x] = true;
        };
    }
    return cells;
}

/// Even-odd: is the doubled point `(px, py)` inside the ring? Exact; the
/// point is a cell centre, on no edge.
fn insideRing(r: geom.Ring, px: i64, py: i64) bool {
    var inside = false;
    for (0..r.xs.len) |i| {
        const j = (i + 1) % r.xs.len;
        const x0 = 2 * r.xs[i];
        const y0 = 2 * r.ys[i];
        const x1 = 2 * r.xs[j];
        const y1 = 2 * r.ys[j];
        if ((y0 > py) != (y1 > py)) {
            const s = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0);
            if ((s > 0) == (y1 > y0)) inside = !inside;
        }
    }
    return inside;
}

/// The cells a validated layer covers, sampled at each cell's centre.
fn sampled(l: *const ValidatedLayer) Bitmap {
    var cells: Bitmap = @splat(false);
    for (0..side) |y| for (0..side) |x| {
        const px: i64 = @intCast(2 * x + 1);
        const py: i64 = @intCast(2 * y + 1);
        for (0..l.len()) |i| {
            const p = l.get(@intCast(i));
            if (!insideRing(p.outer(), px, py)) continue;
            var in_hole = false;
            for (1..p.ringCount()) |k| in_hole = in_hole or insideRing(p.ring(@intCast(k)), px, py);
            if (!in_hole) cells[y * side + x] = true;
        }
    };
    return cells;
}

fn cellwise(a: Bitmap, b: Bitmap, kind: fx.Kind) Bitmap {
    var out: Bitmap = undefined;
    for (&out, a, b) |*o, p, q| o.* = switch (kind) {
        .@"or" => p or q,
        .@"and" => p and q,
        .not => p and !q,
    };
    return out;
}

/// Compares a result with its bitmap; a difference names the first cell.
fn expect(why: *prop.Why, name: []const u8, got: *const ValidatedLayer, want: Bitmap) !void {
    const have = sampled(got);
    for (have, want, 0..) |h, w, i| {
        if (h != w) return why.fail("{s}: cell ({d}, {d}) is {s} in the result, {s} in the bitmap", .{ name, i % side, i / side, if (h) "in" else "out", if (w) "in" else "out" });
    }
}

/// Every operation, and the expressions the laws combine them into, against
/// the bitmap.
fn property(_: Allocator, rects: []const LayerRect, why: *prop.Why) anyerror!void {
    var lb: testgen.shapes.LayoutBuilder = .init(3);
    defer lb.deinit(fx.gpa);
    for (rects) |r| _ = try lb.rect(fx.gpa, r.layer, r.box[0], r.box[1], r.box[2], r.box[3]);
    var store: geom.GeometryStore = .empty;
    defer store.deinit(fx.gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(fx.gpa);
    try lb.finish(fx.gpa, &store, &ids);
    var a = try fx.validated(&store, 0, .rectilinear);
    defer a.deinit(fx.gpa);
    var b = try fx.validated(&store, 1, .rectilinear);
    defer b.deinit(fx.gpa);
    var c = try fx.validated(&store, 2, .rectilinear);
    defer c.deinit(fx.gpa);
    const ra = raster(rects, 0);
    const rb = raster(rects, 1);
    const rc = raster(rects, 2);

    // The three operations, each way round.
    const cases = [_]struct { name: []const u8, kind: fx.Kind, x: *const ValidatedLayer, y: *const ValidatedLayer, want: Bitmap }{
        .{ .name = "A or B", .kind = .@"or", .x = &a, .y = &b, .want = cellwise(ra, rb, .@"or") },
        .{ .name = "B or A", .kind = .@"or", .x = &b, .y = &a, .want = cellwise(ra, rb, .@"or") },
        .{ .name = "A and B", .kind = .@"and", .x = &a, .y = &b, .want = cellwise(ra, rb, .@"and") },
        .{ .name = "A not B", .kind = .not, .x = &a, .y = &b, .want = cellwise(ra, rb, .not) },
        .{ .name = "B not A", .kind = .not, .x = &b, .y = &a, .want = cellwise(rb, ra, .not) },
        .{ .name = "A or A", .kind = .@"or", .x = &a, .y = &a, .want = ra },
        .{ .name = "A and A", .kind = .@"and", .x = &a, .y = &a, .want = ra },
    };
    for (cases) |cs| {
        var got = try fx.run(cs.kind, cs.x, cs.y);
        defer got.deinit(fx.gpa);
        try expect(why, cs.name, &got, cs.want);
    }
    // Composed: the distributive and de Morgan forms.
    var b_or_c = try fx.run(.@"or", &b, &c);
    defer b_or_c.deinit(fx.gpa);
    const rbc = cellwise(rb, rc, .@"or");
    var x1 = try fx.run(.@"and", &a, &b_or_c);
    defer x1.deinit(fx.gpa);
    try expect(why, "A and (B or C)", &x1, cellwise(ra, rbc, .@"and"));
    var x2 = try fx.run(.not, &a, &b_or_c);
    defer x2.deinit(fx.gpa);
    try expect(why, "A not (B or C)", &x2, cellwise(ra, rbc, .not));
    var a_not_b = try fx.run(.not, &a, &b);
    defer a_not_b.deinit(fx.gpa);
    var x3 = try fx.run(.not, &a_not_b, &c);
    defer x3.deinit(fx.gpa);
    try expect(why, "(A not B) not C", &x3, cellwise(cellwise(ra, rb, .not), rc, .not));
}

test "every boolean is its bitmap over random operands" {
    // Oracle: differential against the bitmap reference in the module doc: each
    // operand rasterised on the 32 x 32 grid and combined cell by cell, over
    // 300 named seeds and the committed regressions.
    const regressions = try prop.parseSeeds(fx.gpa, @embedFile("regressions/boolean_random.seeds"));
    defer fx.gpa.free(regressions);
    try testing.expect(regressions.len > 0);
    try prop.check(fx.gpa, []const LayerRect, "boolean_random", 300, regressions, generate, prop.shrinkRects, property);
}
