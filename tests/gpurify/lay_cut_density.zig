//! A connector's cut area between two databases, density held to a cover
//! layer's band, and two masks' density balance, as exhaustive fixtures.
//! Ported from tests/exhaustive/drc_overlay.rs (`cut_area_change`,
//! `cover_density`, `density_balance`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try cutAreaChangeInto(arena, out);
    try coverDensityInto(arena, out);
    try densityBalanceInto(arena, out);
}

// ---- private ----

/// An `m1` and `m2` 1000 square pad at `x`.
fn pad(arena: Allocator, l: *Layout, x: i64) !void {
    try l.rect(arena, "m1", x, 0, x + 1000, 1000);
    try l.rect(arena, "m2", x, 0, x + 1000, 1000);
}

/// `n` 100 nm pre cuts on `v` along the pad at `x`, 150 apart.
fn pre(arena: Allocator, l: *Layout, x: i64, n: i64) !void {
    var i: i64 = 0;
    while (i < n) : (i += 1) try l.rect(arena, "v", x + 50 + 150 * i, 50, x + 150 + 150 * i, 150);
}

/// A connector's cut area between two databases (`cut_area_change`,
/// DRC-068, sky130 ct.irdrop in shape with deck-supplied values): pre cuts
/// on `v`, post cuts on `vc`, connectors `m1` x `m2`; bands from 1 cut allow
/// 10000 nm², from 4 cuts 40000 nm².
///
/// Oracle: areas by hand: three 100 nm pre cuts (30000) on one connector
/// against post 19999, 20000, 20001 (a change of 10001, 10000, 9999: one
/// finding of 10001); four pre cuts against none (40000, allowed) and five
/// (50000, a finding); two connectors on one m1 bar of two pre cuts each,
/// only the one whose cuts went missing found (20000); two pre cuts on m1
/// off m2 count for nothing (counted, they would be a 20000 change); a
/// connector with post cuts and no pre cut is not judged; a post cut half
/// off the footprint counts its inside half (a change of 10000, allowed;
/// the whole cut would be 30000).
fn cutAreaChangeInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "v", "vc", "m1", "m2" }, "rule ir cut_area_change(v, vc, m1, m2; cuts: [1, 4], change: [10000nm2, 40000nm2])\n");
    var cases: std.ArrayList(Fixture) = .empty;
    var post_19999 = try three(arena);
    try post_19999.rect(arena, "vc", 0, 500, 100, 699);
    try post_19999.rect(arena, "vc", 0, 699, 99, 700);
    try cases.append(arena, try cutCase(arena, deck, "post_19999", post_19999, try c.areas(arena, &.{10_001})));
    var post_20000 = try three(arena);
    try post_20000.rect(arena, "vc", 0, 500, 100, 700);
    try cases.append(arena, try cutCase(arena, deck, "post_20000", post_20000, &.{}));
    var post_20001 = try three(arena);
    try post_20001.rect(arena, "vc", 0, 500, 100, 700);
    try post_20001.rect(arena, "vc", 500, 500, 501, 501);
    try cases.append(arena, try cutCase(arena, deck, "post_20001", post_20001, &.{}));
    var four_lost: Layout = .{};
    try pad(arena, &four_lost, 0);
    try pre(arena, &four_lost, 0, 4);
    try cases.append(arena, try cutCase(arena, deck, "four_lost", four_lost, &.{}));
    var five_lost: Layout = .{};
    try pad(arena, &five_lost, 0);
    try pre(arena, &five_lost, 0, 5);
    try cases.append(arena, try cutCase(arena, deck, "five_lost", five_lost, try c.areas(arena, &.{50_000})));
    var one_lost: Layout = .{};
    try one_lost.rect(arena, "m1", 0, 0, 3000, 1000);
    try one_lost.rect(arena, "m2", 0, 0, 1000, 1000);
    try one_lost.rect(arena, "m2", 2000, 0, 3000, 1000);
    try pre(arena, &one_lost, 0, 2);
    try pre(arena, &one_lost, 2000, 2);
    try one_lost.rect(arena, "vc", 2050, 50, 2150, 150);
    try one_lost.rect(arena, "vc", 2200, 50, 2300, 150);
    try cases.append(arena, try cutCase(arena, deck, "one_lost_of_two", one_lost, try c.areas(arena, &.{20_000})));
    var off_upper: Layout = .{};
    try pad(arena, &off_upper, 0);
    try off_upper.rect(arena, "m1", 1000, 0, 2000, 1000);
    try off_upper.rect(arena, "v", 1200, 200, 1300, 300);
    try off_upper.rect(arena, "v", 1400, 200, 1500, 300);
    try cases.append(arena, try cutCase(arena, deck, "off_the_upper", off_upper, &.{}));
    var post_only: Layout = .{};
    try pad(arena, &post_only, 0);
    try post_only.rect(arena, "vc", 100, 100, 600, 600);
    try cases.append(arena, try cutCase(arena, deck, "post_only", post_only, &.{}));
    var half_off: Layout = .{};
    try pad(arena, &half_off, 0);
    try pre(arena, &half_off, 0, 1);
    try half_off.rect(arena, "vc", 800, 400, 1200, 500);
    try cases.append(arena, try cutCase(arena, deck, "post_half_off", half_off, &.{}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Three pre cuts on one connector.
fn three(arena: Allocator) !Layout {
    var l: Layout = .{};
    try pad(arena, &l, 0);
    try pre(arena, &l, 0, 3);
    return l;
}

fn cutCase(arena: Allocator, deck: []const u8, name: []const u8, layout: Layout, found: []const Finding) !Fixture {
    return c.fixture(arena, try std.fmt.allocPrint(arena, "cut_area_change/{s}", .{name}), &.{"DRC-068"}, deck, layout, &.{.{ "ir", found }});
}

/// Density held to the band a cover layer picks (`cover_density`, DRC-076,
/// sky130's waffle-drop rule shape with deck-supplied values): one 1000 nm
/// window over a die `[0, 1000]²`, bands starting at cover 25%, 50% and 100%
/// asking density 25%, 50% and 75%, read `inclusive` and not.
///
/// Oracle: coverage and density by hand from the drawn areas (window area
/// 10^6): a cover of exactly 50% is the 50% band inclusive (need 0.5) and
/// the 25% band exclusive (need 0.25); a full cover is the 100% band
/// inclusive (0.75) and the 50% band exclusive (0.5); 49.9% and 50.1% fall
/// either side alike; 20% is below every band (not judged, even with
/// nothing drawn on the held layer). The held layer's area is swept a step
/// either side of each need (499 000, 500 000, 501 000 for 0.5), one
/// finding below it.
fn coverDensityInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // (cover area, need inclusive, need exclusive), areas of 10^6.
    const Band = struct { i64, ?i64, ?i64 };
    const bands = [_]Band{
        .{ 500_000, 500_000, 250_000 },
        .{ 1_000_000, 750_000, 500_000 },
        .{ 499_000, 250_000, 250_000 },
        .{ 501_000, 500_000, 500_000 },
        .{ 200_000, null, null },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (bands) |b| {
        const cover = b[0];
        for ([_]bool{ true, false }) |inclusive| {
            const need = if (inclusive) b[1] else b[2];
            const deck = try c.newDeck(arena, &.{ "m", "c", "die" }, try std.fmt.allocPrint(arena, "rule cd cover_density(m, c, die; window: 1000nm, step: 1000nm, " ++
                "cover: [25%, 50%, 100%], density: [25%, 50%, 75%], inclusive: {})\n", .{inclusive}));
            const held: []const i64 = if (need) |n| try arena.dupe(i64, &.{ n - 1000, n, n + 1000 }) else &.{ 0, 100_000 };
            for (held) |area| {
                var layout: Layout = .{};
                try layout.rect(arena, "die", 0, 0, 1000, 1000);
                try layout.rect(arena, "c", 0, 0, 1000, @divTrunc(cover, 1000));
                if (area > 0) try layout.rect(arena, "m", 0, 0, @divTrunc(area, 1000), 1000);
                const found: []const Finding = if (need != null and area < need.?)
                    try arena.dupe(Finding, &.{.{ .measured = .ratio(@as(f64, @floatFromInt(area)) / 1e6), .at = null }})
                else
                    &.{};
                try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cover_density/{d}/{}/{d}", .{ cover, inclusive, area }), &.{"DRC-076"}, deck, layout, &.{.{ "cd", found }}));
            }
        }
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `density_balance(c1, c2, die; window: 1000nm, step: 1000nm) >= 0.5`
/// (`density_balance`, DRC-104): in each window, the lesser of the two
/// masks' coverage over the greater, and a window below 0.5 is one finding
/// at its centre, measuring that balance.
///
/// The die is 3000 x 1000, three windows. The first holds 500 x 1000 of
/// `c1` and `c2` 1000 tall and 249/250/251 wide (balance 0.498, 0.5, 0.502:
/// one step either side of the limit); the second only `c1` (balance 0);
/// the third neither (not judged). Windows anchor on the die's corner, so
/// translations only.
fn densityBalanceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "die", "c1", "c2" }, "rule bal density_balance(c1, c2, die; window: 1000nm, step: 1000nm) >= 0.5\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(250)) |sw| {
        const w = sw.value;
        var findings: std.ArrayList(Finding) = .empty;
        try findings.append(arena, c.ratio(0.0, .{ 1500, 500 }));
        // 249 x 1000 over 500 x 1000.
        if (w < 250) try findings.append(arena, c.ratio(0.498, .{ 500, 500 }));
        var layout: Layout = .{};
        try layout.rect(arena, "die", 0, 0, 3000, 1000);
        try layout.rect(arena, "c1", 0, 0, 500, 1000);
        try layout.rect(arena, "c2", 600, 0, 600 + w, 1000);
        try layout.rect(arena, "c1", 1000, 0, 1400, 1000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "density_balance/{s}", .{sw.side}), &.{"DRC-104"}, deck, layout, &.{.{ "bal", findings.items }}));
    }
    try c.everyOffsetInto(arena, cases.items, out);
}

test "every cut-area and cover-density fixture holds" {
    // Oracle: each fixture's expected answer, areas, coverage and balance
    // computed by hand from the drawn shapes (the doc comments above), under
    // every symmetry at two translations (density_balance: translations
    // only, its windows anchor on the die's corner).
    try c.checkGenerated(fixturesInto);
}
