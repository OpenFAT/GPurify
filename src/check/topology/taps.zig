//! How far each region polygon reaches from its taps: the furthest point of
//! every polygon on a region layer (every point, not only its vertices) from
//! the nearest edge of a tap layer, for the latch-up and missing-tie rules
//! (drc `max_distance_to_tap`, erc missing tie). In: a `GeometryStore`, the
//! region and tap layers, and a limit per region row. Out: the rows past
//! their limit, each with its furthest point. Ported from
//! crates/check/src/erc/rules/supply.rs (`untied_points*`, `TapGrid`,
//! `Cell`, `furthest_from_taps`, `point_in_region`, `push_ring_edges`,
//! `undirected`).
//!
//! Contents:
//! - `pub const no_tap_in_range: DbuArea`
//! - `pub const Untied = struct`, `deinit`
//! - `pub fn untiedPoints(gpa: Allocator, store: *const GeometryStore, region: LayerId, tap: LayerId, limit: Dbu, tap_layer: *ValidatedLayer, out: *Untied) Allocator.Error!?u64`
//! - `pub fn untiedPointsBy(gpa: Allocator, store: *const GeometryStore, region: LayerId, tap: LayerId, limit_of: []const ?Dbu, tap_layer: *ValidatedLayer, out: *Untied) Allocator.Error!?u64`
//! - `pub fn pointInRegion(xs: []const Dbu, ys: []const Dbu, p: Point) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const ops = geom.ops;

/// "No tap in range": the largest area `ops.isqrt` accepts, so an untapped
/// region measures `max_abs_dbu` and is reported.
pub const no_tap_in_range: DbuArea = 1 << 80;

/// The region rows past their limit, SoA, in row order: each polygon's
/// furthest point from the taps, that distance squared, and its limit.
pub const Untied = struct {
    poly: std.ArrayList(PolyId) = .empty,
    at: std.ArrayList(Point) = .empty,
    worst2: std.ArrayList(DbuArea) = .empty,
    limit: std.ArrayList(Dbu) = .empty,

    pub fn deinit(u: *Untied, gpa: Allocator) void {
        u.poly.deinit(gpa);
        u.at.deinit(gpa);
        u.worst2.deinit(gpa);
        u.limit.deinit(gpa);
    }
};

/// Target segments per `TapGrid` bucket; tuned by measurement in Rust.
const bucket_target: i64 = 16;

/// A closed block of integer points in `furthestFromTaps`'s search.
const Cell = struct {
    xlo: i64,
    ylo: i64,
    xhi: i64,
    yhi: i64,
    /// Index into `TapGrid.segs` of the tap nearest the parent's probe.
    hint: u32,
};

/// The nearest tap to some point: how far, and which (`maxInt(u32)` when
/// nothing was scanned).
const Nearest = struct {
    dist2: DbuArea,
    tap: u32,

    const none: Nearest = .{ .dist2 = no_tap_in_range, .tap = std.math.maxInt(u32) };

    /// Keeps whichever is nearer; the earlier wins a tie.
    fn keep(n: *Nearest, other: Nearest) void {
        if (other.dist2 < n.dist2) n.* = other;
    }
};

const Found = struct { at: Point, worst: DbuArea };

/// A uniform grid over one tap column. A segment is filed under every cell
/// its box overlaps, which makes the ring search's stop sound. Invariant:
/// `start` is CSR over `segs`, `nx * ny + 1` long once built non-empty.
const TapGrid = struct {
    origin: Point = .{ .x = 0, .y = 0 },
    cell: i64 = 1,
    nx: i64 = 0,
    ny: i64 = 0,
    start: std.ArrayList(u32) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    /// Build scratch.
    extents: std.ArrayList(i64) = .empty,
    cursor: std.ArrayList(u32) = .empty,

    fn deinit(g: *TapGrid, gpa: Allocator) void {
        g.start.deinit(gpa);
        g.segs.deinit(gpa);
        g.extents.deinit(gpa);
        g.cursor.deinit(gpa);
    }

    /// Rebuilds over `taps`; an empty column leaves an empty grid that must
    /// not be probed.
    fn build(g: *TapGrid, gpa: Allocator, taps: []const Seg) Allocator.Error!void {
        g.start.clearRetainingCapacity();
        g.segs.clearRetainingCapacity();
        g.cursor.clearRetainingCapacity();
        g.cell = 1;
        g.nx = 0;
        g.ny = 0;
        g.origin = .{ .x = 0, .y = 0 };
        if (taps.len == 0) return;
        var extent = Bbox.empty;
        for (taps) |s| extent = extent.include(s.a.x, s.a.y).include(s.b.x, s.b.y);
        const span_x = extent.xhi - extent.xlo + 1;
        const span_y = extent.yhi - extent.ylo + 1;
        // The median segment extent, widened until there are about
        // `taps.len / bucket_target` buckets.
        try g.extents.resize(gpa, taps.len);
        for (g.extents.items, taps) |*e, s| e.* = @intCast(@max(@abs(s.b.x - s.a.x), @abs(s.b.y - s.a.y)));
        // ponytail: a full sort for the median, O(n log n); a select if a
        // profile shows grid builds.
        std.mem.sortUnstable(i64, g.extents.items, {}, std.sort.asc(i64));
        const side: i64 = @max(std.math.sqrt(@as(u64, @intCast(@divTrunc(@as(i64, @intCast(taps.len)), bucket_target)))), 1);
        g.cell = @max(g.extents.items[taps.len / 2], 1, @divTrunc(span_x + side - 1, side), @divTrunc(span_y + side - 1, side));
        g.origin = .{ .x = extent.xlo, .y = extent.ylo };
        g.nx = @divTrunc(span_x + g.cell - 1, g.cell);
        g.ny = @divTrunc(span_y + g.cell - 1, g.cell);
        const buckets: usize = @intCast(g.nx * g.ny);
        try g.start.resize(gpa, buckets + 1);
        @memset(g.start.items, 0);
        // A counting sort: scatter-accumulate, prefix sum, scatter.
        for (taps) |s| {
            const c = g.cellsOf(s);
            var cy = c[1];
            while (cy <= c[3]) : (cy += 1) {
                var cx = c[0];
                while (cx <= c[2]) : (cx += 1) g.start.items[g.bucket(cx, cy) + 1] += 1;
            }
        }
        for (0..buckets) |b| g.start.items[b + 1] += g.start.items[b];
        try g.segs.resize(gpa, g.start.items[buckets]);
        try g.cursor.appendSlice(gpa, g.start.items[0..buckets]);
        for (taps) |s| {
            const c = g.cellsOf(s);
            var cy = c[1];
            while (cy <= c[3]) : (cy += 1) {
                var cx = c[0];
                while (cx <= c[2]) : (cx += 1) {
                    const b = g.bucket(cx, cy);
                    g.segs.items[g.cursor.items[b]] = s;
                    g.cursor.items[b] += 1;
                }
            }
        }
    }

    fn bucket(g: *const TapGrid, cx: i64, cy: i64) usize {
        return @intCast(cy * g.nx + cx);
    }

    /// The inclusive cell range `(x0, y0, x1, y1)` a segment's box covers,
    /// clamped to the grid.
    fn cellsOf(g: *const TapGrid, s: Seg) [4]i64 {
        return .{
            std.math.clamp(g.axisX(@min(s.a.x, s.b.x)), 0, g.nx - 1),
            std.math.clamp(g.axisY(@min(s.a.y, s.b.y)), 0, g.ny - 1),
            std.math.clamp(g.axisX(@max(s.a.x, s.b.x)), 0, g.nx - 1),
            std.math.clamp(g.axisY(@max(s.a.y, s.b.y)), 0, g.ny - 1),
        };
    }

    fn axisX(g: *const TapGrid, x: i64) i64 {
        return @divFloor(x - g.origin.x, g.cell);
    }

    fn axisY(g: *const TapGrid, y: i64) i64 {
        return @divFloor(y - g.origin.y, g.cell);
    }

    fn tap(g: *const TapGrid, at: u32) Seg {
        return g.segs.items[at];
    }

    /// The nearest tap in one cell, or `Nearest.none` when it is empty.
    fn nearestInBucket(g: *const TapGrid, cx: i64, cy: i64, p: Point) Nearest {
        const b = g.bucket(cx, cy);
        var best = Nearest.none;
        for (g.start.items[b]..g.start.items[b + 1]) |t| best.keep(.{ .dist2 = ops.pointSegDist2(p, g.segs.items[t]), .tap = @intCast(t) });
        return best;
    }

    /// The nearest tap edge to `p`, exactly: rings of cells outward from
    /// `p`'s cell until nothing unscanned (at least `r * cell` away) can be
    /// nearer.
    fn nearest2(g: *const TapGrid, p: Point) Nearest {
        const px = g.axisX(p.x);
        const py = g.axisY(p.y);
        const rmax = @max(@abs(px), @abs(px - (g.nx - 1)), @abs(py), @abs(py - (g.ny - 1)));
        var best = Nearest.none;
        var r: i64 = 0;
        while (r <= rmax) : (r += 1) {
            const x0 = px - r;
            const x1 = px + r;
            const y0 = py - r;
            const y1 = py + r;
            var cy = @max(y0, 0);
            while (cy <= @min(y1, g.ny - 1)) : (cy += 1) {
                // Top and bottom rows whole; the rows between, their two ends.
                if (cy == y0 or cy == y1) {
                    var cx = @max(x0, 0);
                    while (cx <= @min(x1, g.nx - 1)) : (cx += 1) best.keep(g.nearestInBucket(cx, cy, p));
                } else {
                    if (x0 >= 0 and x0 < g.nx) best.keep(g.nearestInBucket(x0, cy, p));
                    if (x1 >= 0 and x1 < g.nx and x1 != x0) best.keep(g.nearestInBucket(x1, cy, p));
                }
            }
            const gap = @as(i128, r) * g.cell;
            if (best.dist2 <= gap * gap) break;
        }
        return best;
    }
};

/// Rust's xorshift draw in `lo..=hi`.
const Draws = struct {
    state: u64,

    fn draw(d: *Draws, lo: i64, hi: i64) i64 {
        d.state ^= d.state << 13;
        d.state ^= d.state >> 7;
        d.state ^= d.state << 17;
        const span: u64 = @intCast(hi - lo + 1);
        return lo + @as(i64, @intCast(d.state % span));
    }
};

/// `untiedPointsBy` with one limit for every region row.
pub fn untiedPoints(gpa: Allocator, store: *const GeometryStore, region: LayerId, tap: LayerId, limit: Dbu, tap_layer: *ValidatedLayer, out: *Untied) Allocator.Error!?u64 {
    const limits = try gpa.alloc(?Dbu, store.polysOnLayer(region).len());
    defer gpa.free(limits);
    @memset(limits, limit);
    return untiedPointsBy(gpa, store, region, tap, limits, tap_layer, out);
}

/// Every outer row on `region` whose furthest point from the `tap` layer's
/// edges (holes included: a ring tap ties along its inner boundary) is more
/// than its limit `limit_of[row - first]` (null leaves the row out, not
/// counted), into `out` (cleared and refilled). A hole row is not a region of
/// its own; its polygon is measured as if filled. A region with no tap at all
/// measures `no_tap_in_range` at its first vertex. Returns the outer rows
/// counted, or null when the tap layer will not validate (rectilinear) into
/// `tap_layer`.
pub fn untiedPointsBy(gpa: Allocator, store: *const GeometryStore, region: LayerId, tap: LayerId, limit_of: []const ?Dbu, tap_layer: *ValidatedLayer, out: *Untied) Allocator.Error!?u64 {
    const rows = store.polysOnLayer(region);
    assert(limit_of.len == rows.len());
    out.poly.clearRetainingCapacity();
    out.at.clearRetainingCapacity();
    out.worst2.clearRetainingCapacity();
    out.limit.clearRetainingCapacity();
    if (try geom.view.validateLayer(gpa, store, tap, .rectilinear, tap_layer) != null) return null;
    var taps: std.ArrayList(Seg) = .empty;
    defer taps.deinit(gpa);
    for (0..tap_layer.len()) |idx| {
        const poly = tap_layer.get(@intCast(idx));
        for (0..poly.ringCount()) |k| {
            const r = poly.ring(@intCast(k));
            for (0..r.xs.len) |i| try taps.append(gpa, ops.ringEdge(r.xs, r.ys, i));
        }
    }
    // Coincident edges measure alike; keyed undirected, as abutting taps run
    // a shared edge in opposite directions.
    std.mem.sortUnstable(Seg, taps.items, {}, undirectedLess);
    var kept: usize = 0;
    for (taps.items) |s| {
        if (kept > 0 and std.mem.eql(i64, &undirected(taps.items[kept - 1]), &undirected(s))) continue;
        taps.items[kept] = s;
        kept += 1;
    }
    taps.shrinkRetainingCapacity(kept);
    var grid: TapGrid = .{};
    defer grid.deinit(gpa);
    try grid.build(gpa, taps.items);
    var stack: std.ArrayList(Cell) = .empty;
    defer stack.deinit(gpa);
    var examined: u64 = 0;
    for (rows.start..rows.end, limit_of) |row, maybe| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        const r = store.polyVerts(poly);
        if (ops.windingOf(r.xs, r.ys) == .cw) continue;
        const limit = maybe orelse continue;
        const limit2 = geom.mulWide(limit, limit);
        examined += 1;
        if (r.xs.len == 0) continue;
        // `limit2` is the search's floor: a region under it prunes at once.
        const found: Found = if (taps.items.len == 0)
            .{ .at = .{ .x = r.xs[0], .y = r.ys[0] }, .worst = no_tap_in_range }
        else
            try furthestFromTaps(gpa, r.xs, r.ys, store.polyBbox(poly), limit2, &grid, &stack);
        if (found.worst <= limit2) continue;
        try out.poly.append(gpa, poly);
        try out.at.append(gpa, found.at);
        try out.worst2.append(gpa, found.worst);
        try out.limit.append(gpa, limit);
    }
    return examined;
}

/// Whether a point lies in a ring, boundary included (the missing-tie
/// maximum often sits on an edge): an even-odd ray cast toward +x, exact in
/// `i128`. Fewer than three vertices is no region.
pub fn pointInRegion(xs: []const Dbu, ys: []const Dbu, p: Point) bool {
    if (xs.len < 3) return false;
    var inside = false;
    for (0..xs.len) |i| {
        const e = ops.ringEdge(xs, ys, i);
        if (ops.pointSegDist2(p, e) == 0) return true;
        // Half-open crossing rule, then the side test.
        const dy: i128 = e.b.y - e.a.y;
        const dx: i128 = e.b.x - e.a.x;
        const lhs = @as(i128, p.x - e.a.x) * dy;
        const rhs = @as(i128, p.y - e.a.y) * dx;
        const straddles = (e.a.y > p.y) != (e.b.y > p.y);
        inside = inside != (straddles and (lhs - rhs) * std.math.sign(dy) < 0);
    }
    return inside;
}

// ---- private ----

/// One segment's endpoints in ascending order: its identity whichever way
/// round it was drawn.
fn undirected(s: Seg) [4]i64 {
    const p = [2]i64{ s.a.x, s.a.y };
    const q = [2]i64{ s.b.x, s.b.y };
    const lo, const hi = if (std.mem.order(i64, &p, &q) != .gt) .{ p, q } else .{ q, p };
    return .{ lo[0], lo[1], hi[0], hi[1] };
}

fn undirectedLess(_: void, a: Seg, b: Seg) bool {
    return std.mem.order(i64, &undirected(a), &undirected(b)) == .lt;
}

/// The square root of a non-negative area, rounded up: an upper bound
/// rounded down would prune away the maximum.
fn isqrtCeil(area: i128) i64 {
    const root: i128 = std.math.sqrt(@as(u128, @intCast(area)));
    return @intCast(root + @intFromBool(root * root != area));
}

/// Whether no point of a cell can be further from a tap than the best
/// found: `sqrt(d2) + reach <= worst_root`, squared. `worst_root` is
/// floored, so this prunes slightly too rarely, never too often.
fn prunes(worst_root: i64, reach: i64, d2: DbuArea) bool {
    const slack: i128 = worst_root - reach;
    return slack >= 0 and d2 <= slack * slack;
}

/// The point of a region furthest from any tap and that distance squared:
/// exact whenever it exceeds `floor`, else `floor` itself. Branch and bound
/// over the region's integer points (vertices alone miss the maximum),
/// seeded from the vertices; a cell is pruned when its probe's distance plus
/// its reach cannot beat the best, each cell inheriting its parent's nearest
/// tap as a cheap upper bound.
fn furthestFromTaps(gpa: Allocator, xs: []const Dbu, ys: []const Dbu, bbox: Bbox, floor: DbuArea, grid: *const TapGrid, stack: *std.ArrayList(Cell)) Allocator.Error!Found {
    // Vertices are in the region: no containment test.
    var best: Nearest = .{ .dist2 = -1, .tap = 0 };
    var at: Point = .{ .x = xs[0], .y = ys[0] };
    for (xs, ys) |x, y| {
        const here: Point = .{ .x = x, .y = y };
        const found = grid.nearest2(here);
        if (found.dist2 > best.dist2) {
            best = found;
            at = here;
        }
    }
    var worst = @max(best.dist2, floor);
    var worst_root = ops.isqrt(worst);
    stack.clearRetainingCapacity();
    try stack.append(gpa, .{ .xlo = bbox.xlo, .ylo = bbox.ylo, .xhi = bbox.xhi, .yhi = bbox.yhi, .hint = best.tap });
    while (stack.pop()) |cell| {
        const cx = cell.xlo + @divTrunc(cell.xhi - cell.xlo, 2);
        const cy = cell.ylo + @divTrunc(cell.yhi - cell.ylo, 2);
        const here: Point = .{ .x = cx, .y = cy };
        // The inherited tap is a real tap: an upper bound.
        var probe: Nearest = .{ .dist2 = ops.pointSegDist2(here, grid.tap(cell.hint)), .tap = cell.hint };
        const rx: i128 = @max(cell.xhi - cx, cx - cell.xlo);
        const ry: i128 = @max(cell.yhi - cy, cy - cell.ylo);
        const reach = isqrtCeil(rx * rx + ry * ry);
        if (!prunes(worst_root, reach, probe.dist2)) {
            probe = grid.nearest2(here);
            if (probe.dist2 > worst and pointInRegion(xs, ys, here)) {
                worst = probe.dist2;
                worst_root = ops.isqrt(worst);
                at = here;
            }
        }
        // Exact whenever the first test failed, so survival ignores the hint.
        if (prunes(worst_root, reach, probe.dist2)) continue;
        const splits_x = cx < cell.xhi;
        const splits_y = cy < cell.yhi;
        // A single point was just probed and cannot split.
        if (!splits_x and !splits_y) continue;
        try stack.append(gpa, .{ .xlo = cell.xlo, .ylo = cell.ylo, .xhi = cx, .yhi = cy, .hint = probe.tap });
        if (splits_x) try stack.append(gpa, .{ .xlo = cx + 1, .ylo = cell.ylo, .xhi = cell.xhi, .yhi = cy, .hint = probe.tap });
        if (splits_y) try stack.append(gpa, .{ .xlo = cell.xlo, .ylo = cy + 1, .xhi = cx, .yhi = cell.yhi, .hint = probe.tap });
        if (splits_x and splits_y) try stack.append(gpa, .{ .xlo = cx + 1, .ylo = cy + 1, .xhi = cell.xhi, .yhi = cell.yhi, .hint = probe.tap });
    }
    return .{ .at = at, .worst = worst };
}

fn pt(x: i64, y: i64) Point {
    return .{ .x = x, .y = y };
}

fn bruteNearest(taps: []const Seg, p: Point) DbuArea {
    var best: DbuArea = std.math.maxInt(DbuArea);
    for (taps) |s| best = @min(best, ops.pointSegDist2(p, s));
    return best;
}

/// Random horizontal, vertical and sloped tap edges over a `span` square.
fn randomTaps(d: *Draws, out: []Seg, span: i64) void {
    for (out, 0..) |*s, k| {
        const x = d.draw(-span, span);
        const y = d.draw(-span, span);
        const len = d.draw(0, @divTrunc(span, 4) + 1);
        const b = switch (k % 3) {
            0 => pt(x + len, y),
            1 => pt(x, y - len),
            else => pt(x + len, y + d.draw(-len, len)),
        };
        s.* = .{ .a = pt(x, y), .b = b };
    }
}

test "the tap grid ring search agrees with an exhaustive scan" {
    // Oracle: differential against an exhaustive scan of every tap edge,
    // from inside the grid and far outside it, over grids of one bucket and
    // of many; each edge filed once per cell its box covers.
    const gpa = std.testing.allocator;
    var d: Draws = .{ .state = 0x9E37_79B9_7F4A_7C15 };
    var buf: [400]Seg = undefined;
    for ([_]usize{ 1, 2, 5, 17, 60, 400 }) |count| for ([_]i64{ 3, 50, 2000 }) |span| {
        const taps = buf[0..count];
        randomTaps(&d, taps, span);
        var grid: TapGrid = .{};
        defer grid.deinit(gpa);
        try grid.build(gpa, taps);
        var filed: usize = 0;
        for (taps) |s| {
            const c = grid.cellsOf(s);
            filed += @intCast((c[2] - c[0] + 1) * (c[3] - c[1] + 1));
        }
        try std.testing.expectEqual(filed, grid.segs.items.len);
        for (0..80) |_| {
            const p = pt(d.draw(-3 * span, 3 * span), d.draw(-3 * span, 3 * span));
            const found = grid.nearest2(p);
            try std.testing.expectEqual(bruteNearest(taps, p), found.dist2);
            try std.testing.expectEqual(found.dist2, ops.pointSegDist2(p, grid.tap(found.tap)));
        }
    };
}

test "a rebuilt tap grid answers for its new column only" {
    // Oracle: law. A build is a function of its column alone: built over `a`
    // then `b` it answers as one built over `b`; the nearest point of
    // `(500,500)-(500,900)` to the origin is its end, 500² + 500² away.
    const gpa = std.testing.allocator;
    var grid: TapGrid = .{};
    defer grid.deinit(gpa);
    try grid.build(gpa, &.{.{ .a = pt(0, 0), .b = pt(10, 0) }});
    try grid.build(gpa, &.{.{ .a = pt(500, 500), .b = pt(500, 900) }});
    try std.testing.expectEqual(@as(DbuArea, 500 * 500 * 2), grid.nearest2(pt(0, 0)).dist2);
    try std.testing.expectEqual(@as(usize, 1), grid.segs.items.len);
}

test "the furthest point from the taps agrees with an exhaustive scan" {
    // Oracle: differential against an exhaustive scan of every integer point
    // of the region (rectangles, an L and a U), with taps inside, beside and
    // far from it; the floor is answered when nothing beats it.
    const gpa = std.testing.allocator;
    var d: Draws = .{ .state = 0x2545_F491_4F6C_DD1D };
    const regions = [_][]const [2]i64{
        &.{ .{ 0, 0 }, .{ 40, 0 }, .{ 40, 30 }, .{ 0, 30 } },
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 57 }, .{ 0, 57 } },
        &.{ .{ 0, 0 }, .{ 50, 0 }, .{ 50, 10 }, .{ 10, 10 }, .{ 10, 45 }, .{ 0, 45 } },
        &.{ .{ 0, 0 }, .{ 60, 0 }, .{ 60, 40 }, .{ 45, 40 }, .{ 45, 12 }, .{ 15, 12 }, .{ 15, 40 }, .{ 0, 40 } },
    };
    var stack: std.ArrayList(Cell) = .empty;
    defer stack.deinit(gpa);
    var buf: [90]Seg = undefined;
    for (regions) |region| {
        var xs: [8]i64 = undefined;
        var ys: [8]i64 = undefined;
        var bbox = Bbox.empty;
        for (region, 0..) |v, i| {
            xs[i] = v[0];
            ys[i] = v[1];
            bbox = bbox.include(v[0], v[1]);
        }
        const rx = xs[0..region.len];
        const ry = ys[0..region.len];
        for ([_]usize{ 1, 3, 20, 90 }) |count| {
            const taps = buf[0..count];
            randomTaps(&d, taps, 80);
            var grid: TapGrid = .{};
            defer grid.deinit(gpa);
            try grid.build(gpa, taps);
            var want: DbuArea = -1;
            var x = bbox.xlo;
            while (x <= bbox.xhi) : (x += 1) {
                var y = bbox.ylo;
                while (y <= bbox.yhi) : (y += 1) {
                    if (pointInRegion(rx, ry, pt(x, y))) want = @max(want, bruteNearest(taps, pt(x, y)));
                }
            }
            for ([_]DbuArea{ 0, want, want + 1 }) |floor| {
                const found = try furthestFromTaps(gpa, rx, ry, bbox, floor, &grid, &stack);
                try std.testing.expectEqual(@max(want, floor), found.worst);
                if (want > floor) {
                    try std.testing.expect(pointInRegion(rx, ry, found.at));
                    try std.testing.expectEqual(want, bruteNearest(taps, found.at));
                }
            }
        }
    }
}

test "pointInRegion is the closed set of each shape" {
    // Oracle: closed form. The rectangle is `0 <= x <= 20, 0 <= y <= 10`;
    // the L is that rectangle with `x > 8, y > 4` cut away; the triangle
    // `(0,0) (12,0) (0,12)` is `x >= 0, y >= 0, x + y <= 12`, either way
    // round. Fewer than three vertices is no region.
    const rect = [2][4]i64{ .{ 0, 20, 20, 0 }, .{ 0, 0, 10, 10 } };
    const l = [2][6]i64{ .{ 0, 20, 20, 8, 8, 0 }, .{ 0, 0, 4, 4, 10, 10 } };
    const tri = [2][3]i64{ .{ 0, 12, 0 }, .{ 0, 0, 12 } };
    const tri_cw = [2][3]i64{ .{ 0, 0, 12 }, .{ 0, 12, 0 } };
    var x: i64 = -3;
    while (x <= 23) : (x += 1) {
        var y: i64 = -3;
        while (y <= 14) : (y += 1) {
            const p = pt(x, y);
            const in_rect = x >= 0 and x <= 20 and y >= 0 and y <= 10;
            try std.testing.expectEqual(in_rect, pointInRegion(&rect[0], &rect[1], p));
            try std.testing.expectEqual(in_rect and !(x > 8 and y > 4), pointInRegion(&l[0], &l[1], p));
            const in_tri = x >= 0 and y >= 0 and x + y <= 12;
            try std.testing.expectEqual(in_tri, pointInRegion(&tri[0], &tri[1], p));
            try std.testing.expectEqual(in_tri, pointInRegion(&tri_cw[0], &tri_cw[1], p));
        }
    }
    try std.testing.expect(!pointInRegion(&.{ 0, 5 }, &.{ 0, 5 }, pt(0, 0)));
}

test "isqrtCeil is the least root whose square covers the area" {
    // Oracle: the definition, `(r - 1)² < a <= r²`, over every area to
    // 10 000 and at a large perfect square and its neighbours.
    try std.testing.expectEqual(@as(i64, 0), isqrtCeil(0));
    var a: i128 = 1;
    while (a <= 10_000) : (a += 1) {
        const r: i128 = isqrtCeil(a);
        try std.testing.expect((r - 1) * (r - 1) < a and a <= r * r);
    }
    for ([_]i128{ (1 << 60) - 1, 1 << 60, (1 << 60) + 1 }) |big| {
        const r: i128 = isqrtCeil(big);
        try std.testing.expect((r - 1) * (r - 1) < big and big <= r * r);
    }
}
