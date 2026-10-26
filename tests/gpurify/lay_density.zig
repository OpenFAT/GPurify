//! Global and windowed density as exhaustive fixtures, with the window
//! oracle written from the definition. Ported from
//! tests/exhaustive/drc_overlay.rs (`shared`, `windows`,
//! `density_findings`, `global_density`, `density`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");
const Rect = c.Rect;

/// A density window's centre and the fraction of it covered.
const Window = struct { at: [2]i64, fraction: f64 };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try globalDensityInto(arena, out);
    try densityInto(arena, depth, out);
}

// ---- private ----

/// A layout of `rs` on `layer`.
fn boxes(arena: Allocator, layer: []const u8, rs: []const Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, rs);
    return l;
}

/// One finding measuring `fraction` at `at`, in the arena.
fn ratioAt(arena: Allocator, fraction: f64, at: [2]i64) ![]const Finding {
    return arena.dupe(Finding, &.{c.ratio(fraction, at)});
}

/// The area two rectangles share.
fn shared(a: Rect, b: Rect) i64 {
    const w = @min(a[2], b[2]) - @max(a[0], b[0]);
    const h = @min(a[3], b[3]) - @max(a[1], b[1]);
    return if (w > 0 and h > 0) w * h else 0;
}

/// Window origins along a span: from 0 every `step`, as many as cover the
/// span's far edge.
fn along(arena: Allocator, span: i64, side: i64, step: i64) ![]const i64 {
    var origins: std.ArrayList(i64) = .empty;
    try origins.append(arena, 0);
    while (origins.items[origins.items.len - 1] + side < span) try origins.append(arena, origins.items[origins.items.len - 1] + step);
    return origins.items;
}

/// Every density window by the definition: `side`-square windows from the
/// die's lower-left corner every `step`, as many as cover the die's far
/// edges; each covers the area of `covered` (disjoint rectangles inside the
/// die) inside it over its whole area.
fn windows(arena: Allocator, die: Rect, side: i64, step: i64, covered: []const Rect) ![]const Window {
    var out: std.ArrayList(Window) = .empty;
    for (try along(arena, die[2] - die[0], side, step)) |ox| for (try along(arena, die[3] - die[1], side, step)) |oy| {
        const x = die[0] + ox;
        const y = die[1] + oy;
        const window: Rect = .{ x, y, x + side, y + side };
        var area: i64 = 0;
        for (covered) |r| area += shared(r, window);
        const fraction = @as(f64, @floatFromInt(area)) / @as(f64, @floatFromInt(side * side));
        try out.append(arena, .{ .at = .{ x + @divTrunc(side, 2), y + @divTrunc(side, 2) }, .fraction = fraction });
    };
    return out.items;
}

/// The windows a `>= limit` rule (`minimum`) or a `<= limit` rule flags.
fn densityFindings(arena: Allocator, ws: []const Window, limit: f64, minimum: bool) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (ws) |w| if (if (minimum) w.fraction < limit else w.fraction > limit) try out.append(arena, c.ratio(w.fraction, w.at));
    return out.items;
}

fn share(area: i64, die: i64) f64 {
    return @as(f64, @floatFromInt(area)) / @as(f64, @floatFromInt(die));
}

/// `global_density(met1, die) >= 50%` and `<= 50%`, and
/// `global_density(met1) >= 50%` (`global_density`, DRC-070): at most one
/// finding, at the die's centre, measuring the merged met1 area inside the
/// die over the die's area. The die is the boundary layer's extent, or the
/// whole layout's.
///
/// The die is `[0, 1000]^2`. Shapes: a stripe covering 49.9/50/50.1%; the
/// same with more met1 outside the die (clipped by the boundary rule,
/// widening the die of the other); the stripe drawn as two overlapping
/// halves (counted once); the die drawn as two corner markers (its extent
/// counts); no met1 (0); no die (the boundary rules skip, the other measures
/// met1 alone); and a grown derived layer beside a boundary-less rule (F40).
fn globalDensityInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck_gd = try c.newDeck(arena, &.{ "met1", "die" }, "rule gd.min global_density(met1, die) >= 50%\nrule gd.max global_density(met1, die) <= 50%\nrule gd.all global_density(met1) >= 50%\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(500)) |sw| {
        const w = sw.value;
        const f = share(w * 1000, 1_000_000);
        const min: []const Finding = if (w < 500) try ratioAt(arena, f, .{ 500, 500 }) else &.{};
        const max: []const Finding = if (w > 500) try ratioAt(arena, f, .{ 500, 500 }) else &.{};
        const wide = share(w * 1000 + 1_000_000, 3_000_000);
        const wide_min: []const Finding = if (wide < 0.5) try ratioAt(arena, wide, .{ 1500, 500 }) else &.{};
        const shapes = [_]struct { []const u8, []const Rect, []const Finding }{
            .{ "stripe", &.{.{ 0, 0, w, 1000 }}, min },
            .{ "outside_die", &.{ .{ 0, 0, w, 1000 }, .{ 2000, 0, 3000, 1000 } }, wide_min },
            .{ "overlapping_drawn", &.{ .{ 0, 0, w, 600 }, .{ 0, 400, w, 1000 } }, min },
        };
        for (shapes) |s| {
            var l = try boxes(arena, "die", &.{.{ 0, 0, 1000, 1000 }});
            try c.rects(arena, &l, "met1", s[1]);
            try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "global_density/{s}/{s}", .{ s[0], sw.side }), &.{"DRC-070"}, deck_gd, l, &.{ .{ "gd.min", min }, .{ "gd.max", max }, .{ "gd.all", s[2] } }));
        }
    }
    const below_half = try ratioAt(arena, 0.499, .{ 500, 500 });
    var markers = try boxes(arena, "die", &.{ .{ 0, 0, 100, 100 }, .{ 900, 900, 1000, 1000 } });
    try markers.rect(arena, "met1", 0, 0, 499, 1000);
    try cases.append(arena, try c.fixture(arena, "global_density/die_two_markers", &.{"DRC-070"}, deck_gd, markers, &.{ .{ "gd.min", below_half }, .{ "gd.max", &.{} }, .{ "gd.all", below_half } }));
    const zero = try ratioAt(arena, 0.0, .{ 500, 500 });
    try cases.append(arena, try c.fixture(arena, "global_density/empty_met1", &.{"DRC-070"}, deck_gd, try boxes(arena, "die", &.{.{ 0, 0, 1000, 1000 }}), &.{ .{ "gd.min", zero }, .{ "gd.max", &.{} }, .{ "gd.all", zero } }));
    var empty_die: Fixture = .init("global_density/empty_die", &.{"DRC-070"}, deck_gd, harness.drc);
    try empty_die.layout.rect(arena, "met1", 0, 0, 400, 1000);
    try empty_die.claim(arena, .outcome("gd.min", .skipped));
    try empty_die.claim(arena, .outcome("gd.max", .skipped));
    try empty_die.claim(arena, .clean("gd.all"));
    try cases.append(arena, empty_die);
    // Without a boundary the die is the whole layout, `[0, 1000]^2` here, so
    // met1 covers 70%. A derived layer grown past the drawing is not layout:
    // it must not widen the die (F40), which would hide the maximum's
    // violation and invent the minimum's.
    var halo = try boxes(arena, "other", &.{.{ 0, 0, 1000, 1000 }});
    try halo.rect(arena, "met1", 0, 0, 700, 1000);
    const halo_deck = try c.newDeck(arena, &.{ "met1", "other" }, "layer halo = met1.sized(500nm)\nrule gd.min global_density(met1) >= 50%\nrule gd.max global_density(met1) <= 60%\n");
    try cases.append(arena, try c.fixture(arena, "global_density/derived_halo", &.{"DRC-070"}, halo_deck, halo, &.{ .{ "gd.min", &.{} }, .{ "gd.max", try ratioAt(arena, 0.7, .{ 500, 500 }) } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// One `density` fixture over the `[0, 2000]^2` die: `layout` with the die
/// drawn, claimed against the windows of `covered`.
fn densityCase(arena: Allocator, deck: []const u8, name: []const u8, layout_in: Layout, covered: []const Rect) !Fixture {
    const die: Rect = .{ 0, 0, 2000, 2000 };
    const ws = try windows(arena, die, 1000, 500, covered);
    var layout = layout_in;
    try layout.rect(arena, "die", die[0], die[1], die[2], die[3]);
    return c.fixture(arena, try std.fmt.allocPrint(arena, "density/{s}", .{name}), &.{"DRC-071"}, deck, layout, &.{ .{ "pd.min", try densityFindings(arena, ws, 0.5, true) }, .{ "pd.max", try densityFindings(arena, ws, 0.5, false) } });
}

fn stripe(d: i64) Rect {
    return .{ 0, 0, 1000 + d, 2000 };
}

/// `density(met1, die; window: 1000nm, step: 500nm) >= 50%` and `<= 50%`
/// (`density`, DRC-071): one finding per window, at its centre, whose
/// merged met1 area inside the die over the whole window is outside the
/// limit.
///
/// The die is `[0, 2000]^2`, tiled by 3 x 3 windows exactly, so every
/// symmetry maps the windows onto themselves. Shapes: met1 covering `[0,
/// 1000 + d]` for d of -1, 0, 1, which sweeps the middle column through 50%;
/// the same drawn as two overlapping pieces; with met1 outside the die
/// (clipped); the die drawn as two corner markers; no met1 (every window 0);
/// no die (skipped); a boundary-less rule beside a grown derived layer,
/// which must not move the die (F40). Then, without a boundary, windows that
/// hang past the die's far edge or exceed the die (counted empty outside
/// it), under translations only since the windows anchor on the lower-left
/// corner. Nightly: d from -20 to 20.
fn densityInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck_pd = try c.newDeck(arena, &.{ "met1", "die" }, "rule pd.min density(met1, die; window: 1000nm, step: 500nm) >= 50%\nrule pd.max density(met1, die; window: 1000nm, step: 500nm) <= 50%\n");
    const die: Rect = .{ 0, 0, 2000, 2000 };
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(0)) |sw| {
        const s = stripe(sw.value);
        try cases.append(arena, try densityCase(arena, deck_pd, try std.fmt.allocPrint(arena, "stripe/{s}", .{sw.side}), try boxes(arena, "met1", &.{s}), &.{s}));
        try cases.append(arena, try densityCase(arena, deck_pd, try std.fmt.allocPrint(arena, "overlapping_drawn/{s}", .{sw.side}), try boxes(arena, "met1", &.{ .{ 0, 0, 700, 2000 }, .{ 300, 0, s[2], 2000 } }), &.{s}));
        try cases.append(arena, try densityCase(arena, deck_pd, try std.fmt.allocPrint(arena, "outside_die/{s}", .{sw.side}), try boxes(arena, "met1", &.{ s, .{ 3000, 0, 4000, 2000 } }), &.{s}));
    }
    try cases.append(arena, try densityCase(arena, deck_pd, "empty_met1", .{}, &.{}));
    // The die drawn as two corner markers: its extent, not its area, counts.
    const markers = try windows(arena, die, 1000, 500, &.{stripe(-1)});
    var two = try boxes(arena, "die", &.{ .{ 0, 0, 100, 100 }, .{ 1900, 1900, 2000, 2000 } });
    try two.rect(arena, "met1", 0, 0, 999, 2000);
    try cases.append(arena, try c.fixture(arena, "density/die_two_markers", &.{"DRC-071"}, deck_pd, two, &.{ .{ "pd.min", try densityFindings(arena, markers, 0.5, true) }, .{ "pd.max", try densityFindings(arena, markers, 0.5, false) } }));
    // Without a boundary, the same windows over the drawn layout; a derived
    // layer grown past it must not move the die (F40).
    const halo_deck = try c.newDeck(arena, &.{ "met1", "other" }, "layer halo = met1.sized(500nm)\nrule pd.min density(met1; window: 1000nm, step: 500nm) >= 50%\nrule pd.max density(met1; window: 1000nm, step: 500nm) <= 50%\n");
    var halo = try boxes(arena, "other", &.{.{ 0, 0, 2000, 2000 }});
    try halo.rect(arena, "met1", 0, 0, 999, 2000);
    try cases.append(arena, try c.fixture(arena, "density/derived_halo", &.{"DRC-071"}, halo_deck, halo, &.{ .{ "pd.min", try densityFindings(arena, markers, 0.5, true) }, .{ "pd.max", try densityFindings(arena, markers, 0.5, false) } }));
    var empty_die: Fixture = .init("density/empty_die", &.{"DRC-071"}, deck_pd, harness.drc);
    try empty_die.layout.rect(arena, "met1", 0, 0, 1000, 2000);
    try empty_die.claim(arena, .outcome("pd.min", .skipped));
    try empty_die.claim(arena, .outcome("pd.max", .skipped));
    try cases.append(arena, empty_die);
    if (depth == .nightly) {
        var d: i64 = -20;
        while (d <= 20) : (d += 1) {
            const s = stripe(d);
            try cases.append(arena, try densityCase(arena, deck_pd, try std.fmt.allocPrint(arena, "stripe_sweep/{d}", .{d}), try boxes(arena, "met1", &.{s}), &.{s}));
        }
    }
    try c.everyPlacementInto(arena, cases.items, out);

    const deck_die = try c.newDeck(arena, &.{"met1"}, "rule pd density(met1; window: 1000nm, step: 1000nm) >= 60%\n");
    const anchored_cases = [_]struct { []const u8, Rect, f64, [2]i64 }{
        .{ "hanging", .{ 0, 0, 1500, 1000 }, 0.5, .{ 1500, 500 } },
        .{ "die_smaller_than_window", .{ 0, 0, 500, 500 }, 0.25, .{ 500, 500 } },
    };
    var anchored: std.ArrayList(Fixture) = .empty;
    for (anchored_cases) |a| try anchored.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "density/{s}", .{a[0]}), &.{"DRC-071"}, deck_die, try boxes(arena, "met1", &.{a[1]}), &.{.{ "pd", try ratioAt(arena, a[2], a[3]) }}));
    try c.everyOffsetInto(arena, anchored.items, out);
}

test "every global and windowed density fixture holds" {
    // Oracle: the window oracle above, written from the definition (windows
    // from the die's lower-left corner, merged coverage over the whole
    // window), under every symmetry at two translations, or translations
    // alone where the windows anchor on the corner.
    try c.checkGenerated(fixturesInto);
}
