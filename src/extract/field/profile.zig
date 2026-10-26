//! The dielectric as a function of height, and the panels of each interface
//! between two dielectrics. In: the stack's heights and permittivities, and
//! the conductors' footprints. Out: `Profile` (bands of permittivity) and the
//! interface panels with their `λ`. Ported from
//! crates/extract/src/field/dielectric.rs (the profile and the window).
//!
//! The dielectric is horizontally stratified: each `pex` row that states a
//! dielectric fills the stack from its height up to the next row's height,
//! the lowest row's reaching down to the substrate and the highest row's up
//! without end. Two rows at one height must agree. An interface is each
//! height above the substrate where the permittivity changes.
//!
//! An interface is meshed over a window: the selection's footprint grown by
//! `margin` times the height of the interface or of the highest conductor,
//! whichever is more; its polarisation charge falls with the cube of the
//! distance from the conductors, so what lies beyond reaches a conductor's
//! potential with the window's inverse square. The window is cut on a tensor
//! grid through every conductor edge, at the mesh's panel edge over the
//! conductors and growing by `growth` beyond them; a conductor touching or
//! crossing the interface cuts its footprint out.
//!
//! Contents:
//! - `pub const margin: f64`, `pub const growth: f64`
//! - `pub const Profile = struct`, `Profile.empty`, `deinit`,
//!   `ofInto(p: *Profile, gpa: Allocator, stack: Stack, conflict: *u16) (error{DielectricConflict} || Allocator.Error)!void`,
//!   `isLayered(p) bool`, `above(p, z: f64) f64`, `below(p, z: f64) f64`, `interfaceCount(p) u32`,
//!   `interface(p, k: u32) Interface`
//! - `pub const Interface = struct { z: f64, below: f64, above: f64 }`
//! - `pub const Footprint = struct { lo: [2]f64, hi: [2]f64, z: [2]f64 }`
//! - `pub fn gridLinesInto(gpa: Allocator, edges: []const f64, lo: f64, hi: f64, step: f64, out: *std.ArrayList(f64)) Allocator.Error!void`
//! - `pub fn interfacePanelsInto(gpa: Allocator, profile: *const Profile, boxes: []const Footprint, step: f64, conductor: u32, remaining: *u32, panels: *Panels, lambda: *std.ArrayList(f64)) (error{TooManyPanels} || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Stack = @import("../stack.zig").Stack;
const panel = @import("panel.zig");
const Panels = panel.Panels;

/// How far an interface's window reaches past the selection's footprint, in
/// multiples of the interface's height or of the highest conductor's top,
/// whichever is more.
pub const margin: f64 = 8.0;

/// How much each grid step beyond the conductors grows over the last.
pub const growth: f64 = 1.5;

/// Band `i` holds `epsilon[i]` from `start[i]` (metres) up to `start[i + 1]`.
/// Invariant: `start[0]` is `-inf`, `start` ascends, neighbouring bands
/// differ; established by `ofInto`.
pub const Profile = struct {
    start: std.ArrayList(f64) = .empty,
    epsilon: std.ArrayList(f64) = .empty,

    pub const empty: Profile = .{};

    pub fn deinit(p: *Profile, gpa: Allocator) void {
        p.start.deinit(gpa);
        p.epsilon.deinit(gpa);
    }

    /// The stack's profile, from every row that states a dielectric (a
    /// positive one at a finite height). `DielectricConflict` when two rows at
    /// one height state different dielectrics, `conflict` naming the higher
    /// layer id of the two.
    pub fn ofInto(p: *Profile, gpa: Allocator, stack: Stack, conflict: *u16) (error{DielectricConflict} || Allocator.Error)!void {
        p.start.clearRetainingCapacity();
        p.epsilon.clearRetainingCapacity();
        const rows = @min(stack.height_nm.len, stack.dielectric_k.len);
        assert(rows <= std.math.maxInt(u16) + 1);
        var stated: std.ArrayList(Stated) = .empty;
        defer stated.deinit(gpa);
        for (0..rows) |row| {
            const k = stack.dielectric_k[row];
            const h = stack.height_nm[row];
            if (k > 0.0 and std.math.isFinite(h)) try stated.append(gpa, .{ .z = h * 1e-9, .epsilon = k, .layer = @intCast(row) });
        }
        std.mem.sort(Stated, stated.items, {}, Stated.lessThan);
        for (stated.items, 0..) |s, i| {
            if (i > 0) {
                const last = stated.items[i - 1];
                if (@abs(s.z - last.z) <= same_height and !sameBits(s.epsilon, last.epsilon)) {
                    conflict.* = s.layer;
                    return error.DielectricConflict;
                }
            }
            // The substrate is ground; a band starting on or under it starts
            // the profile.
            const from = if (p.start.items.len == 0 or s.z <= 0.0) -std.math.inf(f64) else s.z;
            if (p.epsilon.items.len > 0 and sameBits(p.epsilon.items[p.epsilon.items.len - 1], s.epsilon)) continue;
            if (p.epsilon.items.len > 0 and std.math.isInf(from)) {
                // A later row on the substrate: its band replaces the first.
                p.epsilon.items[p.epsilon.items.len - 1] = s.epsilon;
                continue;
            }
            try p.start.append(gpa, from);
            try p.epsilon.append(gpa, s.epsilon);
        }
    }

    /// Whether the permittivity changes with height: some interface exists.
    pub fn isLayered(p: *const Profile) bool {
        return p.epsilon.items.len > 1;
    }

    /// The permittivity just above height `z`: at an interface, the upper
    /// band's.
    pub fn above(p: *const Profile, z: f64) f64 {
        var band: usize = 0;
        while (band < p.start.items.len and p.start.items[band] <= z + same_height) band += 1;
        return p.epsilon.items[band -| 1];
    }

    /// The permittivity just below height `z`: at an interface, the lower
    /// band's.
    pub fn below(p: *const Profile, z: f64) f64 {
        var band: usize = 0;
        while (band < p.start.items.len and p.start.items[band] < z - same_height) band += 1;
        return p.epsilon.items[band -| 1];
    }

    pub fn interfaceCount(p: *const Profile) u32 {
        return @intCast(p.start.items.len -| 1);
    }

    /// Interface `k`, ascending by height.
    pub fn interface(p: *const Profile, k: u32) Interface {
        return .{ .z = p.start.items[k + 1], .below = p.epsilon.items[k], .above = p.epsilon.items[k + 1] };
    }
};

/// An interface: its height in metres, the permittivity below and above it.
pub const Interface = struct { z: f64, below: f64, above: f64 };

/// One conductor box the interfaces see: its footprint and height, metres.
pub const Footprint = struct {
    /// `[xlo, ylo]`.
    lo: [2]f64,
    /// `[xhi, yhi]`.
    hi: [2]f64,
    /// `[bottom, top]`.
    z: [2]f64,
};

/// Two heights closer than this, in metres (a picometre), are one: a layer
/// whose top lands on the next layer's height reads the interface there.
const same_height: f64 = 1e-12;

/// A row that states a dielectric: height in metres, permittivity, layer.
const Stated = struct {
    z: f64,
    epsilon: f64,
    layer: u16,

    fn lessThan(_: void, a: Stated, b: Stated) bool {
        const o = std.math.order(a.z, b.z);
        if (o != .eq) return o == .lt;
        return a.layer < b.layer;
    }
};

/// Grid lines across `[lo, hi]` into `out` (cleared): every edge in `edges`,
/// at most `step` apart between the first and last of them, and growing by
/// `growth` from them out to `lo` and `hi`. Ascending, distinct.
pub fn gridLinesInto(gpa: Allocator, edges: []const f64, lo: f64, hi: f64, step: f64, out: *std.ArrayList(f64)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const sorted = try gpa.dupe(f64, edges);
    defer gpa.free(sorted);
    std.mem.sort(f64, sorted, {}, totalLess);
    const distinct = dedupNear(sorted);
    if (distinct.len == 0) {
        try out.appendSlice(gpa, &.{ lo, hi });
        return;
    }
    const first = distinct[0];
    const last = distinct[distinct.len - 1];
    // Outward from the first edge, down to `lo`, pushed descending then
    // reversed.
    var at = first;
    var gap = step;
    while (at - gap > lo + same_height) {
        at -= gap;
        try out.append(gpa, at);
        gap *= growth;
    }
    try out.append(gpa, lo);
    std.mem.reverse(f64, out.items);
    // Across the conductors, each span cut into equal steps of at most `step`.
    for (distinct[0 .. distinct.len - 1], distinct[1..]) |a, b| {
        const pieces: u32 = @intFromFloat(@max(@ceil((b - a) / step - 1e-6), 1.0));
        for (0..pieces) |k| try out.append(gpa, a + (b - a) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(pieces)));
    }
    try out.append(gpa, last);
    // Outward from the last edge, up to `hi`.
    at = last;
    gap = step;
    while (at + gap < hi - same_height) {
        at += gap;
        try out.append(gpa, at);
        gap *= growth;
    }
    try out.append(gpa, hi);
    out.shrinkRetainingCapacity(dedupNear(out.items).len);
}

/// Appends every interface's panels to `panels`, interface by interface,
/// each `λ = (ε_below − ε_above)/(ε_below + ε_above)` to `lambda`; their
/// conductor is `conductor`, the one past the last real one. A cell inside
/// the footprint of a box that touches or crosses the interface is metal,
/// not an interface, and is left out. `TooManyPanels` when the cells would
/// exceed `remaining`, which is charged per interface before any is emitted.
pub fn interfacePanelsInto(gpa: Allocator, profile: *const Profile, boxes: []const Footprint, step: f64, conductor: u32, remaining: *u32, panels: *Panels, lambda: *std.ArrayList(f64)) (error{TooManyPanels} || Allocator.Error)!void {
    if (boxes.len == 0) return;
    var reach_lo: [2]f64 = @splat(std.math.inf(f64));
    var reach_hi: [2]f64 = @splat(-std.math.inf(f64));
    var top: f64 = 0.0;
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(gpa);
    for (boxes) |b| {
        for (0..2) |axis| {
            reach_lo[axis] = @min(reach_lo[axis], b.lo[axis]);
            reach_hi[axis] = @max(reach_hi[axis], b.hi[axis]);
        }
        top = @max(top, b.z[1]);
        try xs.appendSlice(gpa, &.{ b.lo[0], b.hi[0] });
        try ys.appendSlice(gpa, &.{ b.lo[1], b.hi[1] });
    }
    var gx: std.ArrayList(f64) = .empty;
    defer gx.deinit(gpa);
    var gy: std.ArrayList(f64) = .empty;
    defer gy.deinit(gpa);
    var metal: std.ArrayList(Footprint) = .empty;
    defer metal.deinit(gpa);
    for (0..profile.interfaceCount()) |k| {
        const face = profile.interface(@intCast(k));
        const grow = margin * @max(face.z, top);
        try gridLinesInto(gpa, xs.items, reach_lo[0] - grow, reach_hi[0] + grow, step, &gx);
        try gridLinesInto(gpa, ys.items, reach_lo[1] - grow, reach_hi[1] + grow, step, &gy);
        metal.clearRetainingCapacity();
        for (boxes) |b| {
            if (b.z[0] <= face.z + same_height and b.z[1] >= face.z - same_height) try metal.append(gpa, b);
        }
        const l = (face.below - face.above) / (face.below + face.above);
        const cells = (gx.items.len - 1) * (gy.items.len - 1);
        if (cells > remaining.*) return error.TooManyPanels;
        remaining.* -= @intCast(cells);
        for (gx.items[0 .. gx.items.len - 1], gx.items[1..]) |x0, x1| {
            for (gy.items[0 .. gy.items.len - 1], gy.items[1..]) |y0, y1| {
                const c = [2]f64{ (x0 + x1) / 2.0, (y0 + y1) / 2.0 };
                const inside = for (metal.items) |b| {
                    if (b.lo[0] < c[0] and c[0] < b.hi[0] and b.lo[1] < c[1] and c[1] < b.hi[1]) break true;
                } else false;
                if (inside) continue;
                const half = [2]f64{ (x1 - x0) / 2.0, (y1 - y0) / 2.0 };
                try panels.append(gpa, .{
                    .cx = c[0],
                    .cy = c[1],
                    .cz = face.z,
                    .area = 4.0 * half[0] * half[1],
                    .half_u = half[0],
                    .half_v = half[1],
                    .conductor = conductor,
                    .normal = .z,
                });
                try lambda.append(gpa, l);
            }
        }
    }
}

// ---- private ----

fn sameBits(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn totalLess(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// Drops each value within `same_height` of the one kept before it, in
/// place; returns the kept prefix.
fn dedupNear(values: []f64) []f64 {
    if (values.len == 0) return values;
    var kept: usize = 1;
    for (values[1..]) |v| {
        if (@abs(v - values[kept - 1]) <= same_height) continue;
        values[kept] = v;
        kept += 1;
    }
    return values[0..kept];
}

fn stackOf(rows: []const [2]f64, heights: []f64, ks: []f64) Stack {
    for (rows, heights, ks) |r, *h, *k| {
        h.* = r[0];
        k.* = r[1];
    }
    return .{ .thickness_nm = &.{}, .height_nm = heights, .sheet_res_ohm_sq = &.{}, .area_cap_af_um2 = &.{}, .fringe_cap_af_um = &.{}, .dielectric_k = ks };
}

test "the profile fills each band from its row up" {
    // Oracle: hand-derived from the definition. Rows at 0, 1 and 3 um
    // stating 3.9, 3.9 and 7 make one interface at 3 um, 3.9 below and 7
    // above; a row with no dielectric changes nothing; two rows at one
    // height that disagree are a conflict naming the higher layer.
    const gpa = std.testing.allocator;
    var h: [4]f64 = undefined;
    var k: [4]f64 = undefined;
    var p: Profile = .empty;
    defer p.deinit(gpa);
    var conflict: u16 = 0;
    try p.ofInto(gpa, stackOf(&.{ .{ 0, 3.9 }, .{ 1000, 3.9 }, .{ 2000, 0 }, .{ 3000, 7 } }, &h, &k), &conflict);
    try std.testing.expect(p.isLayered());
    try std.testing.expectEqual(1, p.interfaceCount());
    const face = p.interface(0);
    try std.testing.expect(@abs(face.z - 3e-6) < 1e-15 and face.below == 3.9 and face.above == 7.0);
    try std.testing.expectEqual(7.0, p.above(3e-6));
    try std.testing.expectEqual(3.9, p.below(3e-6));
    try std.testing.expectEqual(3.9, p.above(2.5e-6));
    try std.testing.expectEqual(7.0, p.below(9e-6));
    try p.ofInto(gpa, stackOf(&.{ .{ 0, 3.9 }, .{ 500, 3.9 } }, h[0..2], k[0..2]), &conflict);
    try std.testing.expect(!p.isLayered());
    try std.testing.expectError(error.DielectricConflict, p.ofInto(gpa, stackOf(&.{ .{ 500, 3.9 }, .{ 500, 4.2 } }, h[0..2], k[0..2]), &conflict));
    try std.testing.expectEqual(1, conflict);
}

test "grid lines pass through every edge and grow outside" {
    // Oracle: construct-from-answer. The lines pass through every edge,
    // are at most a step apart between the edges, grow by `growth` outside
    // them, and end on the window.
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(f64) = .empty;
    defer lines.deinit(gpa);
    try gridLinesInto(gpa, &.{ 0.0, 1.0, 0.25 }, -10.0, 11.0, 0.3, &lines);
    const l = lines.items;
    for ([_]f64{ 0.0, 1.0, 0.25 }) |edge| {
        const hit = for (l) |v| (if (@abs(v - edge) < 1e-12) break true) else false;
        try std.testing.expect(hit);
    }
    try std.testing.expectEqual(-10.0, l[0]);
    try std.testing.expectEqual(11.0, l[l.len - 1]);
    for (l[0 .. l.len - 1], l[1..]) |a, b| {
        try std.testing.expect(b > a);
        if (a >= 0.0 and b <= 1.0) try std.testing.expect(b - a <= 0.3 + 1e-12);
    }
    var gaps: std.ArrayList(f64) = .empty;
    defer gaps.deinit(gpa);
    for (l[0 .. l.len - 1], l[1..]) |a, b| {
        if (a >= 1.0 and b < 11.0) try gaps.append(gpa, b - a);
    }
    for (gaps.items[0 .. gaps.items.len - 1], gaps.items[1..]) |g0, g1| try std.testing.expect(@abs(g1 / g0 - growth) < 1e-9);
}
