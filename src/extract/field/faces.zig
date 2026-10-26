//! A solid's faces to panels. In: rectangles as solids and a face's extent.
//! Out: the uncovered pieces of each side face (where no rectangle of the
//! same conductor and layer abuts it) and the panels of a face cut at the
//! edge limit. Ported from crates/extract/src/field/mesh.rs.
//!
//! Contents:
//! - `pub const Side = struct { normal: Axis, low: bool, at: Dbu, span: [2]Dbu }`
//! - `pub fn sideFaces(b: Bbox) [4]Side`
//! - `pub const SideFaces = struct`, `SideFaces.empty`, `deinit`,
//!   `buildInto(f: *SideFaces, gpa: Allocator, boxes: []const Bbox, conductor: []const u32, layer: []const LayerId) Allocator.Error!void`,
//!   `uncoveredInto(f: *const SideFaces, gpa: Allocator, side: Side, conductor: u32, layer: LayerId, out: *std.ArrayList([2]Dbu)) Allocator.Error!void`
//! - `pub fn uncoveredOf(gpa: Allocator, span: [2]Dbu, covering: []const [2]Dbu, out: *std.ArrayList([2]Dbu)) Allocator.Error!void`
//! - `pub const Emit = struct`, `Emit.face(e: *Emit, gpa: Allocator, axis: Axis, plane: f64, lo: [3]f64, hi: [3]f64) (error{TooManyPanels} || Allocator.Error)!void`
//! - `pub fn cuts(width: f64, edge: f64) u32`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const panel = @import("panel.zig");
const Axis = panel.Axis;
const Panels = panel.Panels;

/// A rectangle's side face, in grid units: normal to x or y, on its low or
/// high side, in the plane `at`, spanning `span` along the other planar axis.
pub const Side = struct { normal: Axis, low: bool, at: Dbu, span: [2]Dbu };

/// Every side face, sorted by plane (conductor, layer, normal, side,
/// coordinate), so the faces in one plane are one run.
pub const SideFaces = struct {
    entry: std.ArrayList(Entry) = .empty,

    pub const empty: SideFaces = .{};

    pub fn deinit(f: *SideFaces, gpa: Allocator) void {
        f.entry.deinit(gpa);
    }

    pub fn buildInto(f: *SideFaces, gpa: Allocator, boxes: []const Bbox, conductor: []const u32, layer: []const LayerId) Allocator.Error!void {
        assert(boxes.len == conductor.len and boxes.len == layer.len);
        f.entry.clearRetainingCapacity();
        for (boxes, conductor, layer) |b, c, l| {
            for (sideFaces(b)) |side| try f.entry.append(gpa, .{ .key = .{ .conductor = c, .layer = @backingInt(l), .normal = @backingInt(side.normal), .low = side.low, .at = side.at }, .span = side.span });
        }
        std.mem.sort(Entry, f.entry.items, {}, Entry.lessThan);
    }

    /// What of `side` no facing side of the same conductor and layer in its
    /// plane covers, ascending, into `out` (cleared).
    pub fn uncoveredInto(f: *const SideFaces, gpa: Allocator, side: Side, conductor: u32, layer: LayerId, out: *std.ArrayList([2]Dbu)) Allocator.Error!void {
        const key: Key = .{ .conductor = conductor, .layer = @backingInt(layer), .normal = @backingInt(side.normal), .low = !side.low, .at = side.at };
        const items = f.entry.items;
        const from = std.sort.lowerBound(Entry, items, key, Entry.orderKey);
        var to = from;
        while (to < items.len and Key.order(items[to].key, key) == .eq) to += 1;
        var covering: std.ArrayList([2]Dbu) = .empty;
        defer covering.deinit(gpa);
        for (items[from..to]) |e| try covering.append(gpa, e.span);
        try uncoveredOf(gpa, side.span, covering.items, out);
    }
};

/// Where a face's panels go, and the state they are cut with.
pub const Emit = struct {
    panels: *Panels,
    epsilon: *std.ArrayList(f64),
    /// The panel budget left; charged per face before emitting, so an
    /// over-limit mesh is refused, never half-built.
    remaining: u32,
    conductor: u32 = 0,
    edge: f64 = 0,
    epsilon_of_face: f64 = 0,

    /// Panels one box face normal to `axis` in the plane `plane`, spanning
    /// `lo..hi` on the other two axes. A degenerate (or NaN) face carries no
    /// charge and gets none.
    pub fn face(e: *Emit, gpa: Allocator, axis: Axis, plane: f64, lo: [3]f64, hi: [3]f64) (error{TooManyPanels} || Allocator.Error)!void {
        const a = @backingInt(axis);
        const u = (a + 1) % 3;
        const v = (a + 2) % 3;
        const wu = hi[u] - lo[u];
        const wv = hi[v] - lo[v];
        if (!(wu > 0.0 and wv > 0.0)) return;
        const nu = cuts(wu, e.edge);
        const nv = cuts(wv, e.edge);
        const count = std.math.mul(u32, nu, nv) catch return error.TooManyPanels;
        if (count > e.remaining) return error.TooManyPanels;
        e.remaining -= count;
        const du = wu / @as(f64, @floatFromInt(nu));
        const dv = wv / @as(f64, @floatFromInt(nv));
        const area = du * dv;
        for (0..nu) |iu| {
            for (0..nv) |iv| {
                var centre: [3]f64 = undefined;
                centre[a] = plane;
                // `mul_add` in Rust: one rounding, as `@mulAdd`.
                centre[u] = @mulAdd(f64, @as(f64, @floatFromInt(iu)) + 0.5, du, lo[u]);
                centre[v] = @mulAdd(f64, @as(f64, @floatFromInt(iv)) + 0.5, dv, lo[v]);
                try e.panels.append(gpa, .{ .cx = centre[0], .cy = centre[1], .cz = centre[2], .area = area, .half_u = du / 2.0, .half_v = dv / 2.0, .conductor = e.conductor, .normal = axis });
                try e.epsilon.append(gpa, e.epsilon_of_face);
            }
        }
    }
};

const Key = struct {
    conductor: u32,
    layer: u16,
    normal: u8,
    low: bool,
    at: Dbu,

    fn order(a: Key, b: Key) std.math.Order {
        if (a.conductor != b.conductor) return std.math.order(a.conductor, b.conductor);
        if (a.layer != b.layer) return std.math.order(a.layer, b.layer);
        if (a.normal != b.normal) return std.math.order(a.normal, b.normal);
        if (a.low != b.low) return std.math.order(@intFromBool(a.low), @intFromBool(b.low));
        return std.math.order(a.at, b.at);
    }
};

const Entry = struct {
    key: Key,
    span: [2]Dbu,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return Key.order(a.key, b.key) == .lt;
    }

    fn orderKey(key: Key, e: Entry) std.math.Order {
        return Key.order(key, e.key);
    }
};

/// A rectangle's four side faces: low x, high x, low y, high y.
pub fn sideFaces(b: Bbox) [4]Side {
    return .{
        .{ .normal = .x, .low = true, .at = b.xlo, .span = .{ b.ylo, b.yhi } },
        .{ .normal = .x, .low = false, .at = b.xhi, .span = .{ b.ylo, b.yhi } },
        .{ .normal = .y, .low = true, .at = b.ylo, .span = .{ b.xlo, b.xhi } },
        .{ .normal = .y, .low = false, .at = b.yhi, .span = .{ b.xlo, b.xhi } },
    };
}

/// What of `span` no interval of `covering` covers, ascending, into `out`
/// (cleared).
pub fn uncoveredOf(gpa: Allocator, span: [2]Dbu, covering: []const [2]Dbu, out: *std.ArrayList([2]Dbu)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var clipped: std.ArrayList([2]Dbu) = .empty;
    defer clipped.deinit(gpa);
    for (covering) |c| {
        const a = @max(c[0], span[0]);
        const b = @min(c[1], span[1]);
        if (a < b) try clipped.append(gpa, .{ a, b });
    }
    std.mem.sort([2]Dbu, clipped.items, {}, lessPair);
    var at = span[0];
    for (clipped.items) |c| {
        if (c[0] > at) try out.append(gpa, .{ at, c[0] });
        at = @max(at, c[1]);
    }
    if (at < span[1]) try out.append(gpa, .{ at, span[1] });
}

/// Panels along one face edge of `width` at a limit of `edge`; at least one.
/// A width within a millionth of an edge above a whole number of edges takes
/// that number: `width` is a difference of absolute coordinates in metres,
/// so an exact multiple can come out a few ulps over and gain a panel at one
/// position but not another (testing-plan F46). Saturates; a saturated count
/// is refused as `TooManyPanels`.
pub fn cuts(width: f64, edge: f64) u32 {
    const n = @ceil(width / edge - 1e-6);
    if (!(n >= 1.0)) return 1;
    if (n >= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(n);
}

// ---- private ----

fn lessPair(_: void, a: [2]Dbu, b: [2]Dbu) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] < b[1];
}

test "uncovered is the span less every cover" {
    // Oracle: hand-derived. 0..10 less 2..4, 3..6 and 9..20 leaves 0..2 and
    // 6..9; an empty cover leaves the span, a cover past both ends leaves
    // nothing.
    const gpa = std.testing.allocator;
    var out: std.ArrayList([2]Dbu) = .empty;
    defer out.deinit(gpa);
    try uncoveredOf(gpa, .{ 0, 10 }, &.{}, &out);
    try std.testing.expectEqualSlices([2]Dbu, &.{.{ 0, 10 }}, out.items);
    try uncoveredOf(gpa, .{ 0, 10 }, &.{ .{ 2, 4 }, .{ 3, 6 }, .{ 9, 20 } }, &out);
    try std.testing.expectEqualSlices([2]Dbu, &.{ .{ 0, 2 }, .{ 6, 9 } }, out.items);
    try uncoveredOf(gpa, .{ 0, 10 }, &.{.{ -5, 15 }}, &out);
    try std.testing.expectEqual(0, out.items.len);
}
