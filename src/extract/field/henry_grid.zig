//! A net's rectangles as inductance filaments and cells. In: one region's
//! disjoint rectangles. Out: each rectangle's centre `Line`, and for a region
//! of several rectangles, where the wire turns or changes width and the
//! current crowds, a `CellGrid`: a tensor grid through every rectangle edge,
//! each cell a node, each two neighbouring cells a filament through their
//! shared face (the five-point discretisation of the plane's current, as
//! `FastHenry`'s uniform planes are meshed; Kamon, Tsuk & White, 1994).
//! Ported from crates/extract/src/field/henry.rs.
//!
//! Contents:
//! - `pub const NodeKey = struct { x: i64, y: i64, layer: u16 }`, `NodeKey.lessThan`, `NodeKey.eql`, `NodeKey.order`
//! - `pub const Line = struct`, `Line.of(r: Bbox) Line`, `project(l, x: i64, y: i64) i64`, `key(l, along: i64, layer: u16) NodeKey`
//! - `pub const crowding_cells: u32`, `pub const cell_growth: f64`
//! - `pub fn cellLinesInto(gpa: Allocator, edges: []const i64, step: f64, out: *std.ArrayList(f64)) Allocator.Error!void`
//! - `pub const CellGrid = struct`, `deinit`, `build(gpa: Allocator, rects: []const Bbox, first: u32) Allocator.Error!CellGrid`,
//!   `cellAt(grid, x2: i64, y2: i64) ?u32`,
//!   `filamentsInto(grid, gpa, scale: f64, thickness: f64, sigma: f64, nodes: []const Vec3, set: *FilamentSet) Allocator.Error!void`,
//!   `terminalInto(grid, gpa, rect: Bbox, key: NodeKey, node: u32, scale: f64, thickness: f64, sigma: f64, nodes: []const Vec3, set: *FilamentSet) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Vec3 = @import("filament.zig").Vec3;
const FilamentSet = @import("henry_solve.zig").FilamentSet;

/// A filament node: coordinates in doubled database units, so every
/// rectangle's centre line lands on an integer, plus the layer. Sorted is
/// dedup order.
pub const NodeKey = struct {
    x: i64,
    y: i64,
    layer: u16,

    pub fn lessThan(_: void, a: NodeKey, b: NodeKey) bool {
        return order(a, b) == .lt;
    }

    pub fn eql(a: NodeKey, b: NodeKey) bool {
        return a.x == b.x and a.y == b.y and a.layer == b.layer;
    }

    pub fn order(a: NodeKey, b: NodeKey) std.math.Order {
        if (a.x != b.x) return std.math.order(a.x, b.x);
        if (a.y != b.y) return std.math.order(a.y, b.y);
        return std.math.order(a.layer, b.layer);
    }
};

/// A rectangle's filament: its centre line along the long side (a square
/// runs along x), in doubled database units.
pub const Line = struct {
    along_x: bool,
    /// The two ends, along the axis.
    lo: i64,
    hi: i64,
    /// The centre line's place across the axis.
    at: i64,
    /// The short side, in database units: the filament's width.
    width: i64,

    pub fn of(r: Bbox) Line {
        if (r.xhi - r.xlo >= r.yhi - r.ylo) return .{ .along_x = true, .lo = 2 * r.xlo, .hi = 2 * r.xhi, .at = r.ylo + r.yhi, .width = r.yhi - r.ylo };
        return .{ .along_x = false, .lo = 2 * r.ylo, .hi = 2 * r.yhi, .at = r.xlo + r.xhi, .width = r.xhi - r.xlo };
    }

    /// Where the point `(x, y)` (doubled units) projects onto the line,
    /// clamped to its ends, as a coordinate along the axis.
    pub fn project(l: Line, x: i64, y: i64) i64 {
        return std.math.clamp(if (l.along_x) x else y, l.lo, l.hi);
    }

    pub fn key(l: Line, along: i64, layer: u16) NodeKey {
        return if (l.along_x) .{ .x = along, .y = l.at, .layer = layer } else .{ .x = l.at, .y = along, .layer = layer };
    }
};

/// Cells across a gridded region's narrowest rectangle: the resolution of
/// the current's spread across a wire where it turns or changes width.
pub const crowding_cells: u32 = 4;

/// How much each cell grows over the last away from a region's edges and
/// corners, along a straight run where the current is uniform again.
pub const cell_growth: f64 = 1.5;

/// A gridded region, coordinates in database units. Cell `(i, j)` is node
/// `cell[i * (ys.len - 1) + j]` when inside the region, `none` otherwise;
/// nodes number from `first` in `centres` order.
pub const CellGrid = struct {
    first: u32,
    xs: std.ArrayList(f64) = .empty,
    ys: std.ArrayList(f64) = .empty,
    cell: std.ArrayList(u32) = .empty,
    /// Each node's cell centre, in node order.
    centres: std.ArrayList([2]f64) = .empty,

    pub fn deinit(c: *CellGrid, gpa: Allocator) void {
        c.xs.deinit(gpa);
        c.ys.deinit(gpa);
        c.cell.deinit(gpa);
        c.centres.deinit(gpa);
    }

    /// The grid of the region of `rects` (disjoint, rectilinear), its nodes
    /// numbered from `first`. The cell size near every edge is the narrowest
    /// rectangle's short side over `crowding_cells`.
    pub fn build(gpa: Allocator, rects: []const Bbox, first: u32) Allocator.Error!CellGrid {
        var c: CellGrid = .{ .first = first };
        errdefer c.deinit(gpa);
        var narrowest: i64 = std.math.maxInt(i64);
        var ex: std.ArrayList(i64) = .empty;
        defer ex.deinit(gpa);
        var ey: std.ArrayList(i64) = .empty;
        defer ey.deinit(gpa);
        for (rects) |r| {
            narrowest = @min(narrowest, @min(r.xhi - r.xlo, r.yhi - r.ylo));
            try ex.appendSlice(gpa, &.{ r.xlo, r.xhi });
            try ey.appendSlice(gpa, &.{ r.ylo, r.yhi });
        }
        if (rects.len == 0) narrowest = 1;
        const step = @as(f64, @floatFromInt(@max(narrowest, 1))) / @as(f64, crowding_cells);
        try cellLinesInto(gpa, sortedDistinct(ex.items), step, &c.xs);
        try cellLinesInto(gpa, sortedDistinct(ey.items), step, &c.ys);
        const nx = c.xs.items.len - 1;
        const ny = c.ys.items.len - 1;
        try c.cell.appendNTimes(gpa, none, nx * ny);
        for (0..nx) |i| {
            for (0..ny) |j| {
                const cx = (c.xs.items[i] + c.xs.items[i + 1]) / 2.0;
                const cy = (c.ys.items[j] + c.ys.items[j + 1]) / 2.0;
                const inside = for (rects) |r| {
                    if (@as(f64, @floatFromInt(r.xlo)) < cx and cx < @as(f64, @floatFromInt(r.xhi)) and
                        @as(f64, @floatFromInt(r.ylo)) < cy and cy < @as(f64, @floatFromInt(r.yhi))) break true;
                } else false;
                if (!inside) continue;
                c.cell.items[i * ny + j] = first + @as(u32, @intCast(c.centres.items.len));
                try c.centres.append(gpa, .{ cx, cy });
            }
        }
        return c;
    }

    /// The node of the cell under the point `(x2, y2)` in doubled database
    /// units, null when no cell of the region is there.
    pub fn cellAt(c: *const CellGrid, x2: i64, y2: i64) ?u32 {
        const x = @as(f64, @floatFromInt(x2)) / 2.0;
        const y = @as(f64, @floatFromInt(y2)) / 2.0;
        const i = (partitionLe(c.xs.items, x) orelse return null);
        const j = (partitionLe(c.ys.items, y) orelse return null);
        const ny = c.ys.items.len - 1;
        if (i >= c.xs.items.len - 1 or j >= ny) return null;
        const node = c.cell.items[i * ny + j];
        return if (node == none) null else node;
    }

    /// A filament between every two neighbouring cells, centre to centre, as
    /// wide as their shared face.
    pub fn filamentsInto(c: *const CellGrid, gpa: Allocator, scale: f64, thickness: f64, sigma: f64, nodes: []const Vec3, set: *FilamentSet) Allocator.Error!void {
        const nx = c.xs.items.len - 1;
        const ny = c.ys.items.len - 1;
        for (0..nx) |i| {
            for (0..ny) |j| {
                const here = c.cell.items[i * ny + j];
                if (here == none) continue;
                if (i + 1 < nx and c.cell.items[(i + 1) * ny + j] != none) {
                    const right = c.cell.items[(i + 1) * ny + j];
                    const width = (c.ys.items[j + 1] - c.ys.items[j]) * scale;
                    try set.push(gpa, nodes[here], nodes[right], width, thickness, sigma, here, right);
                }
                if (j + 1 < ny and c.cell.items[i * ny + j + 1] != none) {
                    const up = c.cell.items[i * ny + j + 1];
                    const width = (c.xs.items[i + 1] - c.xs.items[i]) * scale;
                    try set.push(gpa, nodes[here], nodes[up], width, thickness, sigma, here, up);
                }
            }
        }
    }

    /// A port terminal: `node`, at the end `key` of rectangle `rect`'s centre
    /// line (doubled units), joined to every cell of the rectangle along that
    /// end's edge by a filament from the edge to the cell's centre, as wide
    /// as the cell: the edge is one equipotential contact, as a wire's end is.
    pub fn terminalInto(c: *const CellGrid, gpa: Allocator, rect: Bbox, key: NodeKey, node: u32, scale: f64, thickness: f64, sigma: f64, nodes: []const Vec3, set: *FilamentSet) Allocator.Error!void {
        const line = Line.of(rect);
        const z = nodes[node][2];
        const edge = @as(f64, @floatFromInt(if (line.along_x) key.x else key.y)) / 2.0;
        const xlo: f64 = @floatFromInt(rect.xlo);
        const xhi: f64 = @floatFromInt(rect.xhi);
        const ylo: f64 = @floatFromInt(rect.ylo);
        const yhi: f64 = @floatFromInt(rect.yhi);
        const xs = c.xs.items;
        const ys = c.ys.items;
        const ny = ys.len - 1;
        for (0..xs.len - 1) |i| {
            for (0..ny) |j| {
                const cell = c.cell.items[i * ny + j];
                if (cell == none) continue;
                const centre = c.centres.items[cell - c.first];
                const cx = centre[0];
                const cy = centre[1];
                const in_rect = xlo < cx and cx < xhi and ylo < cy and cy < yhi;
                // Grid lines and edges are whole units: a quarter is equality.
                const touches = if (line.along_x)
                    @abs(xs[i] - edge) < 0.25 or @abs(xs[i + 1] - edge) < 0.25
                else
                    @abs(ys[j] - edge) < 0.25 or @abs(ys[j + 1] - edge) < 0.25;
                if (!(in_rect and touches)) continue;
                const width = if (line.along_x) ys[j + 1] - ys[j] else xs[i + 1] - xs[i];
                const from: Vec3 = if (line.along_x) .{ edge * scale, cy * scale, z } else .{ cx * scale, edge * scale, z };
                try set.push(gpa, from, nodes[cell], width * scale, thickness, sigma, node, cell);
            }
        }
    }
};

const none = std.math.maxInt(u32);

/// Grid lines through every edge in `edges` (ascending, distinct) into `out`
/// (cleared): between two neighbours `ceil(gap / step)` equal cells when
/// that is at most twice `crowding_cells`, else cells growing by
/// `cell_growth` from both ends toward the middle.
pub fn cellLinesInto(gpa: Allocator, edges: []const i64, step: f64, out: *std.ArrayList(f64)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var upper: std.ArrayList(f64) = .empty;
    defer upper.deinit(gpa);
    if (edges.len == 0) return;
    for (edges[0 .. edges.len - 1], edges[1..]) |ea, eb| {
        const a: f64 = @floatFromInt(ea);
        const b: f64 = @floatFromInt(eb);
        try out.append(gpa, a);
        const gap = b - a;
        const pieces = @max(@ceil(gap / step - 1e-9), 1.0);
        if (pieces <= 2.0 * @as(f64, crowding_cells)) {
            const count: u32 = @intFromFloat(pieces);
            for (1..count) |k| try out.append(gpa, a + gap * @as(f64, @floatFromInt(k)) / pieces);
        } else {
            var low = a;
            var high = b;
            var size = step;
            upper.clearRetainingCapacity();
            while (high - low > 3.0 * size) {
                low += size;
                high -= size;
                try out.append(gpa, low);
                try upper.append(gpa, high);
                size *= cell_growth;
            }
            std.mem.reverse(f64, upper.items);
            try out.appendSlice(gpa, upper.items);
        }
    }
    try out.append(gpa, @floatFromInt(edges[edges.len - 1]));
}

// ---- private ----

/// Sorts and dedups `values` in place; returns the distinct prefix.
fn sortedDistinct(values: []i64) []const i64 {
    std.mem.sortUnstable(i64, values, {}, std.sort.asc(i64));
    if (values.len == 0) return values;
    var kept: usize = 1;
    for (values[1..]) |v| {
        if (v == values[kept - 1]) continue;
        values[kept] = v;
        kept += 1;
    }
    return values[0..kept];
}

/// The last index whose line is at or below `v`: Rust's
/// `partition_point(|&l| l <= v).checked_sub(1)`.
fn partitionLe(lines: []const f64, v: f64) ?usize {
    var n: usize = 0;
    while (n < lines.len and lines[n] <= v) n += 1;
    return if (n == 0) null else n - 1;
}
