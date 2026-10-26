//! Where taps go: the shape of a net a device draws from (`TapIndex`, exact
//! nearest-centre queries over a uniform grid) and tap requests resolved to
//! network nodes (`TapTable`, one node per distinct `(shape, along)`,
//! ascending along each chain). In: shape boxes and tap requests. Out: shape
//! indices and node numbering. Ported from crates/check/src/erc/power.rs
//! (`TapIndex`, `TapTable`).
//!
//! Contents:
//! - `pub const TapIndex = struct`, `deinit`, `buildInto(t, gpa: Allocator, store: *const GeometryStore, candidate: []const PolyId) Allocator.Error!void`,
//!   `grid(t, gpa: Allocator) Allocator.Error!void`, `host(t, marker: Bbox) u32`, `nearest(t, marker: Point) u32`
//! - `pub const TapTable = struct`, `deinit`, `clear(t)`, `push(t, gpa: Allocator, shape: u32, along: Dbu) Allocator.Error!u32`,
//!   `pushLinks(t, gpa: Allocator, store: *const GeometryStore, links: []const Link, shape_of: []const u32) Allocator.Error!u32`,
//!   `finish(t, gpa: Allocator, shapes: u32) Allocator.Error!void`, `chainOf(t, shape: u32) [2]u32`
//! - `pub const Link = struct { a: u32, b: u32, layer: LayerId, cut: u32 }`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const centre = geom.ops.centre;
const not_a_node = @import("power_grid.zig").not_a_node;
const tapOn = @import("power_chain.zig").tapOn;
const testing = std.testing;

/// Two connected polygons, the layer joining them, and the cut polygon
/// both ends are tapped under (`not_a_node` for a metal touch).
pub const Link = struct { a: u32, b: u32, layer: LayerId, cut: u32 };

/// The shapes of one net a device can draw current from: their boxes, for
/// "which holds this point", and a uniform grid over their centres for
/// exact nearest-point queries by expanding rings.
pub const TapIndex = struct {
    boxes: std.ArrayList(Bbox) = .empty,
    /// Candidate indices by ascending box `xlo`.
    by_xlo: std.ArrayList(u32) = .empty,
    /// The widest box: how far left of a point a box holding it can start.
    reach: Dbu = 0,
    at: std.ArrayList(Point) = .empty,
    origin_x: Dbu = 0,
    origin_y: Dbu = 0,
    cell: Dbu = 1,
    nx: u32 = 1,
    ny: u32 = 1,
    /// `bucket_start[b] .. bucket_start[b + 1]` indexes `rows`.
    bucket_start: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(u32) = .empty,
    cursor: std.ArrayList(u32) = .empty,

    pub fn deinit(t: *TapIndex, gpa: Allocator) void {
        inline for (.{ "boxes", "by_xlo", "at", "bucket_start", "rows", "cursor" }) |f| @field(t, f).deinit(gpa);
    }

    /// Builds over one net's conducting shapes.
    pub fn buildInto(t: *TapIndex, gpa: Allocator, store: *const GeometryStore, candidate: []const PolyId) Allocator.Error!void {
        t.boxes.clearRetainingCapacity();
        t.at.clearRetainingCapacity();
        for (candidate) |p| {
            const b = store.polyBbox(p);
            try t.boxes.append(gpa, b);
            try t.at.append(gpa, centre(b));
        }
        try t.grid(gpa);
    }

    /// Buckets the points already in `at`, the boxes in `boxes` (split out
    /// so tests need no store).
    pub fn grid(t: *TapIndex, gpa: Allocator) Allocator.Error!void {
        t.by_xlo.clearRetainingCapacity();
        for (0..t.boxes.items.len) |i| try t.by_xlo.append(gpa, @intCast(i));
        std.mem.sortUnstable(u32, t.by_xlo.items, t.boxes.items, struct {
            fn less(boxes: []const Bbox, a: u32, b: u32) bool {
                return boxes[a].xlo < boxes[b].xlo;
            }
        }.less);
        t.reach = 0;
        for (t.boxes.items) |b| t.reach = @max(t.reach, b.xhi - b.xlo);
        t.bucket_start.clearRetainingCapacity();
        t.rows.clearRetainingCapacity();
        t.cell = 1;
        t.nx = 1;
        t.ny = 1;
        if (t.at.items.len == 0) {
            try t.bucket_start.append(gpa, 0);
            return;
        }
        var bounds = Bbox.empty;
        for (t.at.items) |p| bounds = bounds.include(p.x, p.y);
        const span_x = bounds.xhi - bounds.xlo + 1;
        const span_y = bounds.yhi - bounds.ylo + 1;
        // About one bucket per point, whatever the aspect ratio.
        const side: Dbu = @max(std.math.sqrt(@as(u64, t.at.items.len)), 1);
        const cell = @max(@divTrunc(span_x + side - 1, side), @divTrunc(span_y + side - 1, side), 1);
        t.origin_x = bounds.xlo;
        t.origin_y = bounds.ylo;
        t.cell = cell;
        t.nx = @intCast(@divTrunc(span_x + cell - 1, cell));
        t.ny = @intCast(@divTrunc(span_y + cell - 1, cell));
        const buckets = @as(usize, t.nx) * t.ny;
        try t.bucket_start.appendNTimes(gpa, 0, buckets + 1);
        for (t.at.items) |p| t.bucket_start.items[t.bucketOf(p) + 1] += 1;
        for (0..buckets) |b| t.bucket_start.items[b + 1] += t.bucket_start.items[b];
        try t.rows.resize(gpa, t.at.items.len);
        t.cursor.clearRetainingCapacity();
        try t.cursor.appendSlice(gpa, t.bucket_start.items);
        for (t.at.items, 0..) |p, i| {
            const b = t.bucketOf(p);
            t.rows.items[t.cursor.items[b]] = @intCast(i);
            t.cursor.items[b] += 1;
        }
    }

    /// The candidate a device draws its current from: of those whose box
    /// touches the marker's box, the one whose centre is nearest the
    /// marker's centre, the lower index on a tie; with none touching,
    /// `nearest` over all. Asserts a non-empty index.
    pub fn host(t: *const TapIndex, marker: Bbox) u32 {
        const at = centre(marker);
        const boxes = t.boxes.items;
        var lo: usize = 0;
        var hi: usize = t.by_xlo.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (boxes[t.by_xlo.items[mid]].xlo < marker.xlo - t.reach) lo = mid + 1 else hi = mid;
        }
        var best: ?struct { d2: i128, i: u32 } = null;
        for (t.by_xlo.items[lo..]) |i| {
            const b = boxes[i];
            if (b.xlo > marker.xhi) break;
            if (!(marker.xlo <= b.xhi and b.ylo <= marker.yhi and marker.ylo <= b.yhi)) continue;
            const c = t.at.items[i];
            const d2 = dist2(c, at);
            if (best == null or d2 < best.?.d2 or (d2 == best.?.d2 and i < best.?.i)) best = .{ .d2 = d2, .i = i };
        }
        return if (best) |b| b.i else t.nearest(at);
    }

    /// The candidate whose centre is nearest `marker` (exact in i128; the
    /// lowest index wins a tie). Asserts a non-empty index.
    pub fn nearest(t: *const TapIndex, marker: Point) u32 {
        assert(t.at.items.len > 0);
        const last_col: Dbu = t.nx - 1;
        const last_row: Dbu = t.ny - 1;
        const cx = @min(@divTrunc(@max(marker.x - t.origin_x, 0), t.cell), last_col);
        const cy = @min(@divTrunc(@max(marker.y - t.origin_y, 0), t.cell), last_row);
        var best_d: i128 = std.math.maxInt(i128);
        var best_i: u32 = std.math.maxInt(u32);
        var radius: Dbu = 0;
        while (true) : (radius += 1) {
            const lo_x = cx - radius;
            const hi_x = cx + radius;
            const lo_y = cy - radius;
            const hi_y = cy + radius;
            // The cells at Chebyshev distance `radius`: border rows whole,
            // the rows between only their two ends.
            var row = @max(lo_y, 0);
            while (row <= @min(hi_y, last_row)) : (row += 1) {
                if (row == lo_y or row == hi_y) {
                    var col = @max(lo_x, 0);
                    while (col <= @min(hi_x, last_col)) : (col += 1) t.scan(row, col, marker, &best_d, &best_i);
                } else for ([2]Dbu{ lo_x, hi_x }) |col| if (col >= 0 and col <= last_col) t.scan(row, col, marker, &best_d, &best_i);
            }
            // Stop when nothing unscanned (at least `slack` away) can be closer.
            const blo_x = t.origin_x + lo_x * t.cell;
            const bhi_x = t.origin_x + (hi_x + 1) * t.cell - 1;
            const blo_y = t.origin_y + lo_y * t.cell;
            const bhi_y = t.origin_y + (hi_y + 1) * t.cell - 1;
            const slack = @min(marker.x - blo_x, bhi_x - marker.x, marker.y - blo_y, bhi_y - marker.y);
            const covered = lo_x <= 0 and lo_y <= 0 and hi_x >= last_col and hi_y >= last_row;
            if (covered or (slack >= 0 and best_d <= @as(i128, slack) * slack)) break;
        }
        return best_i;
    }

    fn bucketOf(t: *const TapIndex, p: Point) usize {
        const col: u32 = @intCast(@divTrunc(p.x - t.origin_x, t.cell));
        const row: u32 = @intCast(@divTrunc(p.y - t.origin_y, t.cell));
        return @as(usize, row) * t.nx + col;
    }

    fn scan(t: *const TapIndex, row: Dbu, col: Dbu, marker: Point, best_d: *i128, best_i: *u32) void {
        const b = @as(usize, @intCast(row)) * t.nx + @as(usize, @intCast(col));
        for (t.rows.items[t.bucket_start.items[b]..t.bucket_start.items[b + 1]]) |index| {
            const d = dist2(t.at.items[index], marker);
            // Compared as a pair: the lower index breaks a tie.
            const closer = d < best_d.* or (d == best_d.* and index < best_i.*);
            best_d.* = @min(d, best_d.*);
            best_i.* = if (closer) index else best_i.*;
        }
    }
};

/// Tap requests on shapes, resolved to nodes: one per distinct
/// `(shape, along)`, ascending along each shape's chain.
pub const TapTable = struct {
    req_shape: std.ArrayList(u32) = .empty,
    req_along: std.ArrayList(Dbu) = .empty,
    /// The node each request resolved to (`finish`).
    req_node: std.ArrayList(u32) = .empty,
    node_shape: std.ArrayList(u32) = .empty,
    node_along: std.ArrayList(Dbu) = .empty,
    /// `chain_start[s] .. chain_start[s + 1]` is shape `s`'s nodes.
    chain_start: std.ArrayList(u32) = .empty,
    order: std.ArrayList(u32) = .empty,

    const fields = .{ "req_shape", "req_along", "req_node", "node_shape", "node_along", "chain_start", "order" };

    pub fn deinit(t: *TapTable, gpa: Allocator) void {
        inline for (fields) |f| @field(t, f).deinit(gpa);
    }

    pub fn clear(t: *TapTable) void {
        inline for (fields) |f| @field(t, f).clearRetainingCapacity();
    }

    /// Asks for a tap on `shape` at `along`; returns the request index.
    pub fn push(t: *TapTable, gpa: Allocator, shape: u32, along: Dbu) Allocator.Error!u32 {
        assert(t.req_shape.items.len < std.math.maxInt(u32));
        try t.req_shape.append(gpa, shape);
        try t.req_along.append(gpa, along);
        return @intCast(t.req_shape.items.len - 1);
    }

    /// Requests both ends of every link, `a` then `b`: under the cut for a
    /// via, else where the other shape lands. `shape_of` maps a polygon to
    /// its shape index. Returns the first request index.
    pub fn pushLinks(t: *TapTable, gpa: Allocator, store: *const GeometryStore, links: []const Link, shape_of: []const u32) Allocator.Error!u32 {
        const first: u32 = @intCast(t.req_shape.items.len);
        for (links) |l| {
            const host_a = store.polyBbox(@fromBackingInt(l.a));
            const host_b = store.polyBbox(@fromBackingInt(l.b));
            const at_a, const at_b = if (l.cut == not_a_node) .{ host_b, host_a } else blk: {
                const under = store.polyBbox(@fromBackingInt(l.cut));
                break :blk .{ under, under };
            };
            _ = try t.push(gpa, shape_of[l.a], tapOn(host_a, at_a));
            _ = try t.push(gpa, shape_of[l.b], tapOn(host_b, at_b));
        }
        return first;
    }

    /// Resolves every request to a node, sorting by `(shape, along, request)`.
    pub fn finish(t: *TapTable, gpa: Allocator, shapes: u32) Allocator.Error!void {
        const n = t.req_shape.items.len;
        t.order.clearRetainingCapacity();
        for (0..n) |i| try t.order.append(gpa, @intCast(i));
        std.mem.sortUnstable(u32, t.order.items, t, struct {
            fn less(tt: *const TapTable, a: u32, b: u32) bool {
                const sa = tt.req_shape.items[a];
                const sb = tt.req_shape.items[b];
                if (sa != sb) return sa < sb;
                const aa = tt.req_along.items[a];
                const ab = tt.req_along.items[b];
                if (aa != ab) return aa < ab;
                return a < b;
            }
        }.less);
        try t.req_node.resize(gpa, n);
        t.node_shape.clearRetainingCapacity();
        t.node_along.clearRetainingCapacity();
        for (t.order.items) |r| {
            const s = t.req_shape.items[r];
            const a = t.req_along.items[r];
            const last = t.node_shape.items.len;
            if (last == 0 or t.node_shape.items[last - 1] != s or t.node_along.items[last - 1] != a) {
                try t.node_shape.append(gpa, s);
                try t.node_along.append(gpa, a);
            }
            t.req_node.items[r] = @intCast(t.node_shape.items.len - 1);
        }
        t.chain_start.clearRetainingCapacity();
        try t.chain_start.appendNTimes(gpa, 0, shapes + 1);
        for (t.node_shape.items) |s| t.chain_start.items[s + 1] += 1;
        for (0..shapes) |s| t.chain_start.items[s + 1] += t.chain_start.items[s];
    }

    /// One shape's run of nodes, `[from, to)`.
    pub fn chainOf(t: *const TapTable, shape: u32) [2]u32 {
        return .{ t.chain_start.items[shape], t.chain_start.items[shape + 1] };
    }
};

/// Rust's in-file xorshift.
const Xorshift = struct {
    state: u64,
    fn next(x: *Xorshift) u64 {
        x.state ^= x.state << 13;
        x.state ^= x.state >> 7;
        x.state ^= x.state << 17;
        return x.state;
    }
    /// A draw in `lo ..= hi`.
    fn draw(x: *Xorshift, lo: i64, hi: i64) i64 {
        return lo + @as(i64, @intCast(x.next() % @as(u64, @intCast(hi - lo + 1))));
    }
};

// ---- private ----

fn dist2(a: Point, b: Point) i128 {
    const dx: i128 = a.x - b.x;
    const dy: i128 = a.y - b.y;
    return dx * dx + dy * dy;
}

/// The answer `nearest` has to agree with: every tap, compared exactly,
/// ties broken by the lower index.
fn bruteForce(at: []const Point, marker: Point) u32 {
    var best_d: i128 = std.math.maxInt(i128);
    var best_i: u32 = std.math.maxInt(u32);
    for (at, 0..) |p, i| {
        const d = dist2(p, marker);
        if (d < best_d) {
            best_d = d;
            best_i = @intCast(i);
        }
    }
    return best_i;
}

fn indexOf(at: []const Point) !TapIndex {
    var t: TapIndex = .{};
    try t.at.appendSlice(testing.allocator, at);
    try t.grid(testing.allocator);
    return t;
}

test "the ring search agrees with an exhaustive scan" {
    // Oracle: differential against `bruteForce`, the nearest tap by an
    // exhaustive scan, over random taps, degenerate aspect ratios and
    // markers outside the extent.
    var x: Xorshift = .{ .state = 0x2545_F491_4F6C_DD1D };
    var at_buf: [200]Point = undefined;
    for ([_]usize{ 1, 2, 3, 7, 40, 200 }) |taps| {
        for ([_][2]i64{ .{ 1, 1 }, .{ 1, 5000 }, .{ 5000, 1 }, .{ 900, 900 } }) |span| {
            const at = at_buf[0..taps];
            for (at) |*p| p.* = .{
                .x = @as(i64, @intCast(x.next() % @as(u64, @intCast(span[0])))) - @divTrunc(span[0], 2),
                .y = @as(i64, @intCast(x.next() % @as(u64, @intCast(span[1])))) - @divTrunc(span[1], 2),
            };
            var t = try indexOf(at);
            defer t.deinit(testing.allocator);
            for (0..64) |_| {
                const marker: Point = .{
                    .x = @as(i64, @intCast(x.next() % @as(u64, @intCast(3 * span[0])))) - @divTrunc(3 * span[0], 2),
                    .y = @as(i64, @intCast(x.next() % @as(u64, @intCast(3 * span[1])))) - @divTrunc(3 * span[1], 2),
                };
                try testing.expectEqual(bruteForce(at, marker), t.nearest(marker));
            }
        }
    }
}

test "the ring search agrees with an exhaustive scan inside the extent" {
    // Oracle: differential against `bruteForce`, the exhaustive scan.
    var x: Xorshift = .{ .state = 0x5851_F42D_4C95_7F2D };
    var at_buf: [150]Point = undefined;
    for ([_]usize{ 2, 4, 9, 30, 150 }) |taps| {
        for ([_][2]i64{ .{ 40, 40 }, .{ 3000, 200 }, .{ 200, 3000 }, .{ 5000, 5000 } }) |span| {
            const at = at_buf[0..taps];
            for (at) |*p| p.* = .{ .x = x.draw(-span[0], span[0]), .y = x.draw(-span[1], span[1]) };
            var t = try indexOf(at);
            defer t.deinit(testing.allocator);
            for (0..200) |_| {
                const marker: Point = .{ .x = x.draw(-span[0], span[0]), .y = x.draw(-span[1], span[1]) };
                try testing.expectEqual(bruteForce(at, marker), t.nearest(marker));
            }
        }
    }
}

test "a device draws from a shape its marker touches" {
    // Oracle: hand-derived from the boxes. Marker (2.4..2.6, 2.9..3.1) µm
    // touches the rail (1..41 by 2.8..3.2) and not the strap (4.8..5.2 by
    // 1.4..9.0); marker (4.9..5.1, 2.9..3.1) touches both, the strap's
    // centre (5.0, 5.2) 2.2 µm away and the rail's (21, 3) 16 µm; marker
    // (0.4..0.6, 8.9..9.1) touches neither.
    const b = struct {
        fn box(xlo: Dbu, ylo: Dbu, xhi: Dbu, yhi: Dbu) Bbox {
            return .{ .xlo = xlo, .ylo = ylo, .xhi = xhi, .yhi = yhi };
        }
    }.box;
    var t: TapIndex = .{};
    defer t.deinit(testing.allocator);
    try t.boxes.appendSlice(testing.allocator, &.{ b(4800, 1400, 5200, 9000), b(1000, 2800, 41_000, 3200) });
    for (t.boxes.items) |x| try t.at.append(testing.allocator, centre(x));
    try t.grid(testing.allocator);
    const marker = b(2400, 2900, 2600, 3100);
    try testing.expectEqual(@as(u32, 0), t.nearest(centre(marker)));
    try testing.expectEqual(@as(u32, 1), t.host(marker));
    try testing.expectEqual(@as(u32, 0), t.host(b(4900, 2900, 5100, 3100)));
    try testing.expectEqual(@as(u32, 0), t.host(b(400, 8900, 600, 9100)));
}

test "host agrees with an exhaustive scan of the touching boxes" {
    // Oracle: differential against the definition evaluated over every
    // box: of the boxes touching the marker's box (edges and corners
    // count), the nearest centre, the lower index on a tie; touching none,
    // the nearest centre of all. Markers of every size, some touching nothing.
    var x: Xorshift = .{ .state = 0x9E6C_63D0_676A_9A99 };
    var t: TapIndex = .{};
    defer t.deinit(testing.allocator);
    for ([_]usize{ 1, 2, 5, 12, 60 }) |count| {
        for (0..20) |_| {
            t.boxes.clearRetainingCapacity();
            t.at.clearRetainingCapacity();
            for (0..count) |_| {
                const bx = x.draw(-500, 500);
                const by = x.draw(-500, 500);
                const box: Bbox = .{ .xlo = bx, .ylo = by, .xhi = bx + x.draw(0, 300), .yhi = by + x.draw(0, 300) };
                try t.boxes.append(testing.allocator, box);
                try t.at.append(testing.allocator, centre(box));
            }
            try t.grid(testing.allocator);
            for (0..40) |_| {
                const mx = x.draw(-700, 700);
                const my = x.draw(-700, 700);
                const marker: Bbox = .{ .xlo = mx, .ylo = my, .xhi = mx + x.draw(0, 120), .yhi = my + x.draw(0, 120) };
                const c = centre(marker);
                var want: ?u32 = null;
                var want_d: i128 = 0;
                for (t.boxes.items, 0..) |box, i| {
                    if (!(box.xlo <= marker.xhi and marker.xlo <= box.xhi and box.ylo <= marker.yhi and marker.ylo <= box.yhi)) continue;
                    const d = dist2(centre(box), c);
                    if (want == null or d < want_d) {
                        want = @intCast(i);
                        want_d = d;
                    }
                }
                try testing.expectEqual(want orelse bruteForce(t.at.items, c), t.host(marker));
            }
        }
    }
}
