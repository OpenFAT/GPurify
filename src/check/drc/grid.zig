//! Grid family: off-grid vertices and disallowed edge angles over every
//! drawn polygon (or one layer's), interior angles, polygon validity, and
//! the origin. In: the store's coordinate columns, raw rows never
//! validated. Out: one violation per offending vertex, edge or row. Plain
//! per-vertex loops (CPU; not a GPU kernel now). Ported from
//! crates/check/src/drc/rules/grid.rs.
//!
//! Contents:
//! - `pub fn offGrid(c: *const Ctx, r: OffGrid) Error!Verdict`
//! - `pub fn angle(c: *const Ctx, r: Angle) Error!Verdict`
//! - `pub fn minInteriorAngle(c: *const Ctx, r: MinInteriorAngle) Error!Verdict`
//! - `pub fn polygonValidity(c: *const Ctx, r: AnyLayer) Error!Verdict`
//! - `pub fn origin(c: *const Ctx, r: LayerOnly) Error!Verdict`
//! - `pub fn latticeOffset(x: Dbu, y: Dbu, pitch: i64) i64`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;

/// The store rows a rule reads: one layer's, or every drawn layer's.
const Rows = struct { start: u32, end: u32 };

/// Every vertex on the drawn layers must sit on the `pitch` lattice; a
/// derived layer repeats its operands' vertices. `examined` counts vertices.
pub fn offGrid(c: *const Ctx, r: rows.OffGrid) Error!Verdict {
    const read = rowsOf(c, null);
    var examined: u64 = 0;
    for (read.start..read.end) |row| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        const ring = c.store.polyVerts(poly);
        examined += ring.xs.len;
        for (ring.xs, ring.ys) |x, y| {
            const offset = latticeOffset(x, y, r.pitch);
            if (offset != 0) try c.finding(c.store.polyLayer(poly), .{ .x = x, .y = y }, .length(offset), .length(0), poly);
        }
    }
    return scratch.ran(examined);
}

/// Every non-zero edge on the layer, or on every drawn layer, must lie
/// along an allowed line; measured as the allowed lines matched (0)
/// against 1, at the vertex it leaves. `examined` counts non-zero edges.
pub fn angle(c: *const Ctx, r: rows.Angle) Error!Verdict {
    const read = rowsOf(c, r.layer);
    var examined: u64 = 0;
    for (read.start..read.end) |row| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        const ring = c.store.polyVerts(poly);
        for (0..ring.xs.len) |i| {
            const e = geom.ops.ringEdge(ring.xs, ring.ys, i);
            const dx = e.b.x - e.a.x;
            const dy = e.b.y - e.a.y;
            if (dx == 0 and dy == 0) continue;
            examined += 1;
            if (lineBit(dx, dy) & r.allowed == 0) try c.finding(c.store.polyLayer(poly), e.a, .count(0), .count(1), poly);
        }
    }
    return scratch.ran(examined);
}

/// Every corner whose angle inside its shape is below the limit in degrees
/// (IHP 3.1 "acute angles < 87 degree"), at the vertex, measuring it. A
/// zero-length edge is skipped. `examined` counts corners measured.
pub fn minInteriorAngle(c: *const Ctx, r: rows.MinInteriorAngle) Error!Verdict {
    const read = rowsOf(c, r.layer);
    var examined: u64 = 0;
    for (read.start..read.end) |row| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        const ring = c.store.polyVerts(poly);
        const n = ring.xs.len;
        for (0..n) |at| {
            const before = (at + n - 1) % n;
            const after = (at + 1) % n;
            const arriving = [2]i64{ ring.xs[at] - ring.xs[before], ring.ys[at] - ring.ys[before] };
            const leaving = [2]i64{ ring.xs[after] - ring.xs[at], ring.ys[after] - ring.ys[at] };
            if ((arriving[0] == 0 and arriving[1] == 0) or (leaving[0] == 0 and leaving[1] == 0)) continue;
            examined += 1;
            const degrees = interiorDegrees(arriving, leaving);
            if (degrees < r.limit) try c.finding(c.store.polyLayer(poly), .{ .x = ring.xs[at], .y = ring.ys[at] }, .ratio(degrees), .ratio(r.limit), poly);
        }
    }
    return scratch.ran(examined);
}

/// Every row that is no valid polygon whatever its angles (IHP 3.1):
/// degenerate or self-intersecting as validation decides. One violation per
/// row at its first vertex. `examined` counts rows.
pub fn polygonValidity(c: *const Ctx, r: rows.AnyLayer) Error!Verdict {
    const read = rowsOf(c, r.layer);
    for (read.start..read.end) |row| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        const ring = c.store.polyVerts(poly);
        if (try geom.view.ringDefect(c.gpa, ring.xs, ring.ys, poly) == null) continue;
        // A row with no vertex at all is reported at the origin.
        const at: geom.Point = if (ring.xs.len > 0) .{ .x = ring.xs[0], .y = ring.ys[0] } else .{ .x = 0, .y = 0 };
        try c.finding(c.store.polyLayer(poly), at, .count(0), .count(1), poly);
    }
    return scratch.ran(read.end - read.start);
}

/// sky130 x.19: the lower-left corner of the box of every row on the layer
/// is the origin, or one violation there measuring its distance from it.
/// `examined` counts rows; an empty layer is skipped.
pub fn origin(c: *const Ctx, r: rows.LayerOnly) Error!Verdict {
    const read = c.store.polysOnLayer(r.layer);
    if (read.len() == 0) return .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };
    var b = Bbox.empty;
    for (read.start..read.end) |row| b = b.merge(c.store.polyBbox(@fromBackingInt(@intCast(row))));
    if (b.xlo != 0 or b.ylo != 0) {
        const d = geom.ops.isqrt(geom.mulWide(b.xlo, b.xlo) + geom.mulWide(b.ylo, b.ylo));
        try c.finding(r.layer, .{ .x = b.xlo, .y = b.ylo }, .length(d), .length(0), @fromBackingInt(read.start));
    }
    return scratch.ran(read.len());
}

/// Chebyshev distance from `(x, y)` to the nearest `pitch` lattice point;
/// zero exactly on it. A power-of-two pitch is a mask (two's complement
/// makes it exact for negatives too).
pub fn latticeOffset(x: Dbu, y: Dbu, pitch: i64) i64 {
    const pow2 = pitch & (pitch - 1) == 0;
    const rx = if (pow2) x & (pitch - 1) else @mod(x, pitch);
    const ry = if (pow2) y & (pitch - 1) else @mod(y, pitch);
    return @max(@min(rx, pitch - rx), @min(ry, pitch - ry));
}

// ---- private ----

/// `layer`'s rows, or every drawn layer's (`0..drawn`, contiguous in the
/// store) when null.
fn rowsOf(c: *const Ctx, layer: ?LayerId) Rows {
    if (layer) |l| {
        const r = c.store.polysOnLayer(l);
        return .{ .start = r.start, .end = r.end };
    }
    if (c.drawn == 0) return .{ .start = 0, .end = 0 };
    const last = c.store.polysOnLayer(@fromBackingInt(@as(u16, @intCast(c.drawn - 1))));
    return .{ .start = 0, .end = last.end };
}

/// The bit of the line (0, 45, 90, 135 degrees) edge `(dx, dy)` lies
/// along, or 0.
fn lineBit(dx: i64, dy: i64) u8 {
    return @as(u8, @intFromBool(dy == 0)) | @as(u8, @intFromBool(dx == dy)) << 1 | @as(u8, @intFromBool(dx == 0)) << 2 | @as(u8, @intFromBool(dx == -dy)) << 3;
}

/// The angle at a corner on its shape's side, 0 to 360 degrees, from the
/// edge arriving and the edge leaving: 180 less the signed turn, rounded to
/// 1e-9 degree so a right angle reads exactly 90.
fn interiorDegrees(a: [2]i64, b: [2]i64) f64 {
    const cross: f64 = @floatFromInt(geom.mulWide(a[0], b[1]) - geom.mulWide(a[1], b[0]));
    const dot: f64 = @floatFromInt(geom.mulWide(a[0], b[0]) + geom.mulWide(a[1], b[1]));
    const turn = std.math.radiansToDegrees(std.math.atan2(cross, dot));
    return @round((180.0 - turn) * 1e9) / 1e9;
}

test "the power of two mask is rem euclid" {
    // Oracle: differential against the offset written with `@mod`, at every
    // listed pitch (powers of two and not) and coordinate, signs and domain
    // edges included. Ported from crates/check/src/drc/rules/grid.rs
    // `the_power_of_two_mask_is_rem_euclid`.
    const m = geom.max_abs_dbu;
    const values = [_]i64{ -m, -1025, -1024, -7, -1, 0, 1, 3, 1023, m };
    for ([_]i64{ 1, 2, 3, 5, 8, 1024, 1 << 30, m }) |pitch| for (values) |x| for (values) |y| {
        const rx = @mod(x, pitch);
        const ry = @mod(y, pitch);
        try std.testing.expectEqual(@max(@min(rx, pitch - rx), @min(ry, pitch - ry)), latticeOffset(x, y, pitch));
    };
}
