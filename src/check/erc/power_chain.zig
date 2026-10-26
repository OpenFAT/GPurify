//! The one-dimensional resistor model of one conducting polygon: a chain
//! along its long box axis, tapped where something lands. In: a shape's box
//! and ring, tap positions, the process stack. Out: where a tap sits on the
//! chain (`tapOn`, `tapPoint`), a segment's squares `∫ ds / w(s)` over the
//! width a cut actually finds and its narrowest width (`ChainProfile`), and
//! the link and via dimensions. Transverse resistance within a cut is not
//! modelled. Ported from crates/check/src/erc/power.rs (`ChainProfile`,
//! `tap_on`, `tap_point`, `conductor_width`, `run_length`, `via_length`,
//! `squares`).
//!
//! Contents:
//! - `pub fn chainIsHorizontal(host: Bbox) bool`
//! - `pub fn tapOn(host: Bbox, other: Bbox) Dbu`, `pub fn tapPoint(host: Bbox, along: Dbu) Point`
//! - `pub const ChainProfile = struct`, `deinit`, `build(p, gpa: Allocator, store: *const GeometryStore, poly: PolyId) Allocator.Error!void`,
//!   `segment(p, from: Dbu, to: Dbu) Segment`, `pub const Segment = struct { squares: f64, narrow: Dbu }`
//! - `pub fn conductorWidth(a: Bbox, b: Bbox) Dbu`, `pub fn runLength(from: Point, to: Point) Dbu`,
//!   `pub fn viaLength(process: Process, lower: LayerId, upper: LayerId) Dbu`, `pub fn squares(length: Dbu, width: Dbu) f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const centre = geom.ops.centre;
const Process = @import("power_grid.zig").Process;
const testing = std.testing;

/// A shape's exact cross-section along its chain: piecewise-constant
/// widths between slab cuts (an L of ten-wide arms is 9.1 squares, not its
/// box's 1). Scratch reused shape after shape.
pub const ChainProfile = struct {
    /// Slab boundaries on the chain axis, ascending, distinct.
    cut: std.ArrayList(Dbu) = .empty,
    /// Covered cross-section per slab, floored at one unit.
    width: std.ArrayList(Dbu) = .empty,
    /// Ring edges `(lo, hi, across)` on the chain axis, sorted.
    edge: std.ArrayList([3]Dbu) = .empty,
    active: std.ArrayList([3]Dbu) = .empty,
    crossing: std.ArrayList(Dbu) = .empty,

    /// A run's squares (a left fold over slabs) and the narrowest width
    /// it touches, where current density peaks.
    pub const Segment = struct { squares: f64, narrow: Dbu };

    pub fn deinit(p: *ChainProfile, gpa: Allocator) void {
        inline for (.{ "cut", "width", "edge", "active", "crossing" }) |f| @field(p, f).deinit(gpa);
    }

    /// Profiles one shape by a slab sweep over an active-edge list.
    pub fn build(p: *ChainProfile, gpa: Allocator, store: *const GeometryStore, poly: PolyId) Allocator.Error!void {
        const ring = store.polyVerts(poly);
        const along, const across = if (chainIsHorizontal(store.polyBbox(poly))) .{ ring.xs, ring.ys } else .{ ring.ys, ring.xs };
        const n = along.len;
        p.cut.clearRetainingCapacity();
        try p.cut.appendSlice(gpa, along);
        std.mem.sortUnstable(Dbu, p.cut.items, {}, std.sort.asc(Dbu));
        p.cut.shrinkRetainingCapacity(dedup(Dbu, p.cut.items));

        p.edge.clearRetainingCapacity();
        try p.edge.ensureTotalCapacity(gpa, n);
        for (0..n) |k| {
            const a = along[k];
            const b = along[(k + 1) % n];
            p.edge.appendAssumeCapacity(.{ @min(a, b), @max(a, b), across[k] });
        }
        std.mem.sortUnstable([3]Dbu, p.edge.items, {}, lessTriple);

        p.width.clearRetainingCapacity();
        p.active.clearRetainingCapacity();
        var admitted: usize = 0;
        for (0..p.cut.items.len -| 1) |k| {
            const t0 = p.cut.items[k];
            const t1 = p.cut.items[k + 1];
            // Admit edges started by this slab; retire those ended before it.
            while (admitted < p.edge.items.len and p.edge.items[admitted][0] <= t0) : (admitted += 1) {
                try p.active.append(gpa, p.edge.items[admitted]);
            }
            var kept: usize = 0;
            for (p.active.items) |e| if (e[1] >= t1) {
                p.active.items[kept] = e;
                kept += 1;
            };
            p.active.shrinkRetainingCapacity(kept);
            p.crossing.clearRetainingCapacity();
            for (p.active.items) |e| try p.crossing.append(gpa, e[2]);
            std.mem.sortUnstable(Dbu, p.crossing.items, {}, std.sort.asc(Dbu));
            // Crossings pair up; the metal lies between each pair.
            var covered: Dbu = 0;
            var i: usize = 0;
            while (i + 1 < p.crossing.items.len) : (i += 2) covered += p.crossing.items[i + 1] - p.crossing.items[i];
            try p.width.append(gpa, @max(covered, 1));
        }
    }

    pub fn segment(p: *const ChainProfile, from: Dbu, to: Dbu) Segment {
        var total: f64 = 0.0;
        var narrow: Dbu = std.math.maxInt(Dbu);
        for (p.width.items, 0..) |w, k| {
            const lo = @max(p.cut.items[k], from);
            const hi = @min(p.cut.items[k + 1], to);
            const overlap = @max(hi - lo, 0);
            // |Dbu| <= 2^40: exact in f64.
            total += @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(w));
            // An untouched slab blends in as maxInt.
            narrow = @min(narrow, if (overlap > 0) w else std.math.maxInt(Dbu));
        }
        return .{ .squares = total, .narrow = narrow };
    }
};

/// A shape's chain runs along x: its long box axis (x on a tie).
pub fn chainIsHorizontal(host: Bbox) bool {
    return host.width() >= host.height();
}

/// Where `other` lands on `host`'s chain axis: the centre of their overlap
/// (or of `other`, for a corner touch or a miss), clamped into `host`.
pub fn tapOn(host: Bbox, other: Bbox) Dbu {
    const landed = centre(host.intersection(other) orelse other);
    return if (chainIsHorizontal(host)) std.math.clamp(landed.x, host.xlo, host.xhi) else std.math.clamp(landed.y, host.ylo, host.yhi);
}

/// The node position of a tap at `along`, on `host`'s centre line.
pub fn tapPoint(host: Bbox, along: Dbu) Point {
    const middle = centre(host);
    return if (chainIsHorizontal(host)) .{ .x = along, .y = middle.y } else .{ .x = middle.x, .y = along };
}

/// The narrower shape's narrow dimension, floored at one unit.
pub fn conductorWidth(a: Bbox, b: Bbox) Dbu {
    return @max(@min(narrowSide(a), narrowSide(b)), 1);
}

/// Manhattan length between two taps, floored at one unit (a zero length
/// would be Blech-immortal).
pub fn runLength(from: Point, to: Point) Dbu {
    const span: Dbu = @intCast(@abs(from.x - to.x) + @abs(from.y - to.y));
    return @max(span, 1);
}

/// A via's length: the stack height between its conductors, in database
/// units rounded half away from zero, within `[1, max_abs_dbu]`. A layer
/// with no height row sits at 0.
pub fn viaLength(process: Process, lower: LayerId, upper: LayerId) Dbu {
    const per_um: f64 = @floatFromInt(process.grid.dbu_per_um);
    const span = @round(@abs(heightOf(process, upper) - heightOf(process, lower)) * 1e-3 * per_um);
    if (!(span >= 1.0)) return 1;
    return @intFromFloat(@min(span, @as(f64, @floatFromInt(geom.max_abs_dbu))));
}

/// Squares of conductor: a ratio of two exact `Dbu`.
pub fn squares(length: Dbu, width: Dbu) f64 {
    return @as(f64, @floatFromInt(length)) / @as(f64, @floatFromInt(width));
}

// ---- private ----

fn narrowSide(b: Bbox) Dbu {
    return @min(b.width(), b.height());
}

fn heightOf(process: Process, layer: LayerId) f64 {
    const i = @backingInt(layer);
    const h = process.stack.height_nm;
    return if (i < h.len) h[i] else 0.0;
}

fn lessTriple(_: void, a: [3]Dbu, b: [3]Dbu) bool {
    inline for (0..3) |i| if (a[i] != b[i]) return a[i] < b[i];
    return false;
}

/// Drops adjacent repeats of a sorted run in place; returns the new length.
fn dedup(comptime T: type, items: []T) usize {
    if (items.len == 0) return 0;
    var kept: usize = 1;
    for (items[1..]) |v| if (v != items[kept - 1]) {
        items[kept] = v;
        kept += 1;
    };
    return kept;
}

/// One polygon on layer zero.
fn shape(xs: []const Dbu, ys: []const Dbu) !GeometryStore {
    var b: geom.GeometryStoreBuilder = .{};
    defer b.deinit(testing.allocator);
    _ = try b.push(testing.allocator, @fromBackingInt(0), xs, ys);
    var store: GeometryStore = .empty;
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(testing.allocator);
    try b.finish(testing.allocator, 1, &store, &perm);
    return store;
}

test "a rectangle profiles to its own length over its own width" {
    // Oracle: closed form. A 400 x 10 bar is 400 / 10 = 40 squares, and its
    // narrowest place is its width, 10.
    var store = try shape(&.{ 0, 400, 400, 0 }, &.{ 0, 0, 10, 10 });
    defer store.deinit(testing.allocator);
    var p: ChainProfile = .{};
    defer p.deinit(testing.allocator);
    try p.build(testing.allocator, &store, @fromBackingInt(0));
    try testing.expectEqual(@as(usize, 1), p.width.items.len);
    const s = p.segment(0, 400);
    try testing.expectApproxEqAbs(@as(f64, 40.0), s.squares, 1e-12);
    try testing.expectEqual(@as(Dbu, 10), s.narrow);
}

test "an L route costs the squares its arms have and not its bounding box" {
    // Oracle: closed form: 10/100 + 90/10 = 9.1 squares along the L, its
    // narrowest place the 10-wide arm.
    var store = try shape(&.{ 0, 100, 100, 10, 10, 0 }, &.{ 0, 0, 10, 10, 100, 100 });
    defer store.deinit(testing.allocator);
    var p: ChainProfile = .{};
    defer p.deinit(testing.allocator);
    try p.build(testing.allocator, &store, @fromBackingInt(0));
    const s = p.segment(0, 100);
    try testing.expectApproxEqAbs(@as(f64, 9.1), s.squares, 1e-12);
    try testing.expectEqual(@as(Dbu, 10), s.narrow);
    try testing.expect(s.squares > 9.0);
}

test "widening a shape can only lower the squares a segment costs" {
    // Oracle: law, Rayleigh monotonicity: resistance cannot rise when
    // conductor is added, so the wider L costs no more squares on any segment.
    var narrow = try shape(&.{ 0, 100, 100, 10, 10, 0 }, &.{ 0, 0, 10, 10, 100, 100 });
    defer narrow.deinit(testing.allocator);
    var wide = try shape(&.{ 0, 100, 100, 10, 10, 0 }, &.{ 0, 0, 20, 20, 100, 100 });
    defer wide.deinit(testing.allocator);
    var thin: ChainProfile = .{};
    defer thin.deinit(testing.allocator);
    var fat: ChainProfile = .{};
    defer fat.deinit(testing.allocator);
    try thin.build(testing.allocator, &narrow, @fromBackingInt(0));
    try fat.build(testing.allocator, &wide, @fromBackingInt(0));
    for ([_]Dbu{ 0, 10, 40 }) |from| for ([_]Dbu{ 50, 80, 100 }) |to| {
        try testing.expect(fat.segment(from, to).squares <= thin.segment(from, to).squares);
    };
}

test "run and via lengths, squares and widths are their closed forms" {
    // Oracle: closed form, by hand: (0,0) to (30,-40) is 70; a point to
    // itself floors at 1; layers at 100 nm and 450 nm are 350 apart, 350
    // units on a 1 nm grid and 70 on a 5 nm one, either way round; a layer
    // with no height row sits at 0 (450 apart); two at one height floor at
    // 1; 30 / 4 is 7.5 squares; boxes 10 x 50 and 30 x 6 are 6 wide.
    const p = struct {
        fn at(x: Dbu, y: Dbu) Point {
            return .{ .x = x, .y = y };
        }
    }.at;
    try testing.expectEqual(@as(Dbu, 70), runLength(p(0, 0), p(30, -40)));
    try testing.expectEqual(@as(Dbu, 70), runLength(p(30, -40), p(0, 0)));
    try testing.expectEqual(@as(Dbu, 1), runLength(p(5, 5), p(5, 5)));
    var heights = [_]f64{ 100.0, 450.0, 100.0 };
    const stack: @import("ingest").deck.ProcessStack = .{ .height_nm = &heights };
    const connectivity: @import("ingest").deck.Connectivity = .{};
    const proc = struct {
        fn of(s: *const @import("ingest").deck.ProcessStack, c: *const @import("ingest").deck.Connectivity, nm: i64) Process {
            return .{ .grid = geom.Grid.init(@divExact(1000, nm)) catch unreachable, .stack = s, .connectivity = c };
        }
    }.of;
    const l0: LayerId = @fromBackingInt(0);
    const l1: LayerId = @fromBackingInt(1);
    const l2: LayerId = @fromBackingInt(2);
    const l7: LayerId = @fromBackingInt(7);
    try testing.expectEqual(@as(Dbu, 350), viaLength(proc(&stack, &connectivity, 1), l0, l1));
    try testing.expectEqual(@as(Dbu, 350), viaLength(proc(&stack, &connectivity, 1), l1, l0));
    try testing.expectEqual(@as(Dbu, 70), viaLength(proc(&stack, &connectivity, 5), l0, l1));
    try testing.expectEqual(@as(Dbu, 450), viaLength(proc(&stack, &connectivity, 1), l7, l1));
    try testing.expectEqual(@as(Dbu, 1), viaLength(proc(&stack, &connectivity, 1), l0, l2));
    try testing.expectApproxEqAbs(@as(f64, 7.5), squares(30, 4), 1e-15);
    const b = struct {
        fn box(xlo: Dbu, ylo: Dbu, xhi: Dbu, yhi: Dbu) Bbox {
            return .{ .xlo = xlo, .ylo = ylo, .xhi = xhi, .yhi = yhi };
        }
    }.box;
    try testing.expectEqual(@as(Dbu, 6), conductorWidth(b(0, 0, 10, 50), b(0, 0, 30, 6)));
    try testing.expectEqual(@as(Dbu, 6), conductorWidth(b(0, 0, 30, 6), b(0, 0, 10, 50)));
    try testing.expectEqual(@as(Dbu, 1), conductorWidth(b(0, 0, 0, 50), b(0, 0, 30, 6)));
}
