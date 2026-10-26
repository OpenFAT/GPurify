//! The root crate's `density_cmp` fixtures (ERC-B1, DRC-113's density-step
//! and CMP hotspots), run through fixture.zig against `densityOracle`, the
//! window density computed by clipping each metal rectangle to each window,
//! written from the rule's definition. Ported from
//! crates/check/tests/erc/ported.rs (`density` and its helpers).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const check = @import("check");
const fixture = @import("fixture.zig");
const pa = @import("ported_antenna.zig");
const Measurement = check.report.Measurement;
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const Rect = pa.Rect;
const Out = pa.Out;
const rect = pa.rect;
const side = pa.side;

/// The limits of one `density_cmp` row; null is unchecked.
const DensityRow = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    delta: ?f64 = null,
    /// `(target, sensitivity nm, max excursion nm)`.
    cmp: ?struct { f64, i64, i64 } = null,
    partial: bool = true,

    fn deck(row: DensityRow, a: Allocator, window: i64, step: i64) ![]const u8 {
        const cmp = if (row.cmp) |c| try std.fmt.allocPrint(a, "(target: {d}, sensitivity: {d}nm, max_delta: {d}nm)", .{ c[0], c[1], c[2] }) else "none";
        return std.fmt.allocPrint(a, "{s}rule den density_cmp(met1; window: {d}nm x {d}nm, step: {d}nm x {d}nm, min: {s}, max: {s}, max_delta: {s}, partial_windows: {}, cmp: {s})\n", .{ density_process, window, window, step, step, try opt(a, row.min), try opt(a, row.max), try opt(a, row.delta), row.partial, cmp });
    }
};

/// A die outline and one metal; no connectivity.
const density_process =
    \\grid 1nm
    \\layer die = gds(1, 0)
    \\layer met1 = gds(2, 0)
    \\boundary die
    \\
;

/// Disjoint metal rectangles on a 4 µm die: 0.25, 0.5, 0.75 and 0.125 of
/// the four 2 µm windows (lower-left, lower-right, upper-left, upper-right).
const density_metal = [4]Rect{ .{ 0, 0, 1000, 1000 }, .{ 2000, 0, 4000, 1000 }, .{ 0, 2000, 2000, 3500 }, .{ 2000, 2000, 3000, 2500 } };

// ---- private ----

fn opt(a: Allocator, v: ?f64) ![]const u8 {
    return if (v) |x| std.fmt.allocPrint(a, "{d}", .{x}) else "none";
}

/// The overlap area of two boxes.
fn clip(a: Rect, b: Rect) i64 {
    const w = @max(@min(a[2], b[2]) - @max(a[0], b[0]), 0);
    const h = @max(@min(a[3], b[3]) - @max(a[1], b[1]), 0);
    return w * h;
}

/// The density of window box `b` over `metal` (disjoint rectangles).
fn densityOf(metal: []const Rect, b: Rect) f64 {
    var area: i64 = 0;
    for (metal) |m| area += clip(m, b);
    return @as(f64, @floatFromInt(area)) / @as(f64, @floatFromInt((b[2] - b[0]) * (b[3] - b[1])));
}

/// The `density_cmp` definition over `metal` on a square die `[0, die]²`:
/// windows from the lower-left corner every `step` while their origin is
/// inside the die, density over the die-clipped window, a partial window
/// held to min, max and CMP only with `partial_windows`, and every right
/// and upper neighbour pair compared for the delta, reported at the
/// lower-left window of the pair. Findings at the clipped window's centre.
fn densityOracle(a: Allocator, metal: []const Rect, die: i64, window: i64, step: i64, row: DensityRow) ![]const Finding {
    const n: usize = @intCast(@divTrunc(die - 1, step) + 1);
    const Box = struct { Rect, bool };
    const boxes = try a.alloc(Box, n * n);
    for (0..n) |j| for (0..n) |i| {
        const x = @as(i64, @intCast(i)) * step;
        const y = @as(i64, @intCast(j)) * step;
        const full: Rect = .{ x, y, x + window, y + window };
        const clipped: Rect = .{ x, y, @min(x + window, die), @min(y + window, die) };
        boxes[j * n + i] = .{ clipped, std.mem.eql(i64, &full, &clipped) };
    };
    var out: std.ArrayList(Finding) = .empty;
    for (0..n) |j| for (0..n) |i| {
        const b, const whole = boxes[j * n + i];
        const d = densityOf(metal, b);
        const at = [2]i64{ @divFloor(b[0] + b[2], 2), @divFloor(b[1] + b[3], 2) };
        const counted = row.partial or whole;
        if (counted) if (row.min) |m| if (d < m) try out.append(a, pa.ratioAt(d, at));
        if (counted) if (row.max) |m| if (d > m) try out.append(a, pa.ratioAt(d, at));
        if (row.cmp) |c| {
            const excursion: i64 = @intFromFloat(@abs(@as(f64, @floatFromInt(c[1])) * (d - c[0])));
            if (counted and excursion > c[2]) try out.append(a, .{ .measured = Measurement.length(excursion), .at = at });
        }
        if (row.delta) |delta| for ([_][2]usize{ .{ i + 1, j }, .{ i, j + 1 } }) |nb| {
            if (nb[0] < n and nb[1] < n) {
                const gap = @abs(d - densityOf(metal, boxes[nb[1] * n + nb[0]][0]));
                if (gap > delta) try out.append(a, pa.ratioAt(gap, at));
            }
        };
    };
    return out.items;
}

fn densityLayout(a: Allocator, metal: []const Rect) !Layout {
    var l: Layout = .{};
    try rect(a, &l, "die", .{ 0, 0, 4000, 4000 });
    for (metal) |m| try rect(a, &l, "met1", m);
    return l;
}

/// One fixture of `row` on the four windows' layout, against the oracle.
fn case(o: *Out, placed: *std.ArrayList(Fixture), name: []const u8, row: DensityRow, window: i64, step: i64, place: bool) !void {
    const a = o.arena;
    const f: Fixture = .{
        .name = name,
        .deck = try row.deck(a, window, step),
        .layout = try densityLayout(a, &density_metal),
        .expect = try pa.rule(a, "den", try densityOracle(a, &density_metal, 4000, window, step, row)),
    };
    if (place) try placed.append(a, f);
    try o.add(f);
}

/// `density_cmp` (ERC-B1) on four 2 µm windows of densities 0.25, 0.5,
/// 0.75 and 0.125: `min` and `max` swept across each density, `max_delta`
/// across each neighbour gap (0.25, 0.5, 0.375, 0.625), the CMP excursion
/// `|400 nm × (d - 0.5)|` (100, 0, 100, 150 nm) across each value; window
/// placement on 3 µm windows stepped by 2 µm: three of four are die-clipped
/// and count only with `partial_windows`. Overlapping metal counts once.
fn density(o: *Out) !void {
    const a = o.arena;
    var placed: std.ArrayList(Fixture) = .empty;
    // Placed: min just above 0.25 (two windows) and max just below 0.5 (two).
    for ([_]f64{ 0.125, 0.25, 0.5, 0.75 }, 0..) |d, k| for ([_]f64{ d - 0.001, d, d + 0.001 }) |limit| {
        const s = side(limit, d);
        try case(o, &placed, try std.fmt.allocPrint(a, "erc/density/min/{d}/{s}", .{ d, s }), .{ .min = limit }, 2000, 2000, k == 1 and std.mem.eql(u8, s, "above"));
        try case(o, &placed, try std.fmt.allocPrint(a, "erc/density/max/{d}/{s}", .{ d, s }), .{ .max = limit }, 2000, 2000, k == 2 and std.mem.eql(u8, s, "below"));
    };
    for ([_]f64{ 0.25, 0.375, 0.5, 0.625 }) |gap| for ([_]f64{ gap - 0.001, gap, gap + 0.001 }) |limit| {
        try case(o, &placed, try std.fmt.allocPrint(a, "erc/density/delta/{d}/{s}", .{ gap, side(limit, gap) }), .{ .delta = limit }, 2000, 2000, false);
    };
    for ([_]i64{ 100, 150 }) |excursion| for ([_]i64{ excursion - 1, excursion, excursion + 1 }) |limit| {
        const name = try std.fmt.allocPrint(a, "erc/density/cmp/{d}/{s}", .{ excursion, side(@floatFromInt(limit), @floatFromInt(excursion)) });
        try case(o, &placed, name, .{ .cmp = .{ 0.5, 400, limit } }, 2000, 2000, excursion == 100 and limit == 99);
    };
    for ([_]bool{ true, false }) |partial| {
        try case(o, &placed, try std.fmt.allocPrint(a, "erc/density/partial/{}/min_max", .{partial}), .{ .min = 0.45, .max = 0.55, .partial = partial }, 3000, 2000, false);
    }
    try case(o, &placed, "erc/density/partial/true/delta", .{ .delta = 0.05 }, 3000, 2000, false);
    for (placed.items) |f| {
        var p = f;
        p.name = try std.fmt.allocPrint(a, "{s}/placed", .{f.name});
        try o.placed(p);
    }

    // F35: without partial windows a die-clipped window is not evaluated, so
    // no neighbour difference involving one is either.
    const no_partial: DensityRow = .{ .delta = 0.05, .partial = false };
    try o.offset(.{ .name = "erc/density/partial/false/delta", .deck = try no_partial.deck(a, 3000, 2000), .layout = try densityLayout(a, &density_metal), .expect = try pa.rule(a, "den", &.{}) });
    // Two overlapping pieces in the lower-left window cover their union.
    var overlap = try densityLayout(a, density_metal[1..]);
    try rect(a, &overlap, "met1", .{ 0, 0, 1000, 1000 });
    try rect(a, &overlap, "met1", .{ 500, 0, 1500, 1000 });
    const union_metal = [4]Rect{ .{ 0, 0, 1500, 1000 }, density_metal[1], density_metal[2], density_metal[3] };
    const min_row: DensityRow = .{ .min = 0.4 };
    try o.offset(.{ .name = "erc/density/overlapping_metal", .deck = try min_row.deck(a, 2000, 2000), .layout = overlap, .expect = try pa.rule(a, "den", try densityOracle(a, &union_metal, 4000, 2000, 2000, min_row)) });
    // No die layer: the die is the drawn layout's extent, `[0, 4000]²` from a
    // marker, so the same four windows. A derived layer grown 500 nm past
    // the metal is not layout and must not widen it to `[-500, 4500]²` (F40).
    const halo_row: DensityRow = .{ .min = 0.2 };
    var halo: Layout = .{};
    try rect(a, &halo, "marker", .{ 0, 0, 4000, 4000 });
    for (density_metal) |m| try rect(a, &halo, "met1", m);
    var deck = try halo_row.deck(a, 2000, 2000);
    deck = try std.mem.replaceOwned(u8, a, deck, "layer die =", "layer marker =");
    deck = try std.mem.replaceOwned(u8, a, deck, "boundary die\n", "");
    deck = try std.mem.replaceOwned(u8, a, deck, "rule den", "layer halo = met1.sized(500nm)\nrule den");
    try o.offset(.{ .name = "erc/density/derived_halo", .deck = deck, .layout = halo, .expect = try pa.rule(a, "den", try densityOracle(a, &density_metal, 4000, 2000, 2000, halo_row)) });
}

test "density rows match a window by window clip" {
    // Oracle: `densityOracle`, the window density computed by clipping each
    // metal rectangle to each window, written from the rule's definition.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var o: Out = .{ .arena = arena_state.allocator() };
    try density(&o);
    try fixture.checkAll(o.list.items);
}
