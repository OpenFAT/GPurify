//! Region density, cheesing and the fill rules as exhaustive fixtures.
//! Ported from tests/exhaustive/drc_overlay.rs (`region_density`,
//! `cheesing`, `fill`).
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
const Rect = c.Rect;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try regionDensityInto(arena, out);
    try cheesingInto(arena, out);
    try fillInto(arena, out);
}

// ---- private ----

/// A layout of `rs` on `layer`.
fn boxes(arena: Allocator, layer: []const u8, rs: []const Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, rs);
    return l;
}

/// The 1000 nm capacitor with `met3` rectangles on it.
fn cap(arena: Allocator, met3: []const Rect) !Layout {
    var l = try boxes(arena, "cap", &.{.{ 0, 0, 1000, 1000 }});
    try c.rects(arena, &l, "met3", met3);
    return l;
}

/// Pattern density inside each shape of a region layer (`region_density`,
/// DRC-072: sky130 vpp.5a "max pattern density of met3.dg over
/// capacitor.dg", vpp.11 the minimum): `region_density(met3, cap) <= 25%`
/// and `>= 10%`, one finding per capacitor outside a limit, at the centre of
/// its first rectangle, measuring the fraction.
///
/// Oracle: coverages fixed by construction: the met3 inside a 1000 square
/// swept 249/250/251 rows tall against 25%; two capacitors at 30% and 5%,
/// each a finding of its own (one extent for the whole layer, as `density`
/// takes a boundary, reads 17.5% and passes both); met3 reaching outside its
/// capacitor counted only inside (37.5% if counted whole); met3 filling only
/// the hole of a ring-shaped capacitor, 0 (a check that fills the hole reads
/// 25% and passes); met3 with no capacitor, nothing.
fn regionDensityInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met3", "cap" }, "rule dmax region_density(met3, cap) <= 25%\nrule dmin region_density(met3, cap) >= 10%\n");
    const Case = struct { []const u8, Layout, []const Finding, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(250)) |sw| {
        const h = sw.value;
        const max: []const Finding = if (h > 250) try arena.dupe(Finding, &.{c.ratio(@as(f64, @floatFromInt(h)) / 1000.0, .{ 500, 500 })}) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "coverage/{s}", .{sw.side}), try cap(arena, &.{.{ 0, 0, 1000, h }}), max, &.{} });
    }
    var two = try cap(arena, &.{.{ 0, 0, 1000, 300 }});
    try two.rect(arena, "cap", 3000, 0, 4000, 1000);
    try two.rect(arena, "met3", 3000, 0, 4000, 50);
    try list.append(arena, .{ "two_regions", two, try arena.dupe(Finding, &.{c.ratio(0.3, .{ 500, 500 })}), try arena.dupe(Finding, &.{c.ratio(0.05, .{ 3500, 500 })}) });
    try list.append(arena, .{ "outside_not_counted", try cap(arena, &.{.{ -500, 0, 1000, 250 }}), &.{}, &.{} });
    var holed: Layout = .{};
    try c.ring(arena, &holed, "cap", .{ 0, 0, 1000, 1000 }, .{ 250, 250, 750, 750 });
    try holed.rect(arena, "met3", 250, 250, 750, 750);
    try list.append(arena, .{ "holed_region", holed, &.{}, try arena.dupe(Finding, &.{.{ .measured = .ratio(0.0), .at = null }}) });
    try list.append(arena, .{ "no_region", try boxes(arena, "met3", &.{.{ 0, 0, 1000, 1000 }}), &.{}, &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "region_density/{s}", .{cs[0]}), &.{"DRC-072"}, deck, cs[1], &.{ .{ "dmax", cs[2] }, .{ "dmin", cs[3] } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// A plate slotted by a 200 nm hole, drawn as a ring of bands.
fn slotted(arena: Allocator) !Layout {
    var l: Layout = .{};
    try c.ring(arena, &l, "met1", .{ 0, 0, 2000, 2000 }, .{ 900, 900, 1100, 1100 });
    return l;
}

/// `cheesing(met1) <= 1um2` (`cheesing`, DRC-075): one finding per merged
/// figure strictly larger than 1 µm² with no hole, measuring its area.
///
/// Shapes: a plate of 0.999/1/1.001 µm²; a large slotted plate (a ring of
/// bands, clean); the 1.001 µm² plate as two abutting halves each under the
/// limit; a U whose notch is not a slot; a slotted and an unslotted plate
/// side by side; an empty layer.
fn cheesingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "met1", "other" }, "rule slot cheesing(met1) <= 1um2\n");
    const Case = struct { []const u8, Layout, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(1000)) |sw| {
        const h = sw.value;
        const area = @as(i128, h) * 1000;
        const findings: []const Finding = if (area > 1_000_000) try c.areas(arena, &.{area}) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "plate/{s}", .{sw.side}), try boxes(arena, "met1", &.{.{ 0, 0, 1000, h }}), findings });
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "halves/{s}", .{sw.side}), try boxes(arena, "met1", &.{ .{ 0, 0, 500, h }, .{ 500, 0, 1000, h } }), findings });
    }
    try list.append(arena, .{ "slotted", try slotted(arena), &.{} });
    var u: Layout = .{};
    try u.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1100, 2000 }, .{ 1100, 1000 }, .{ 900, 1000 }, .{ 900, 2000 }, .{ 0, 2000 } });
    try list.append(arena, .{ "notched_u", u, try c.areas(arena, &.{3_800_000}) });
    var beside = try slotted(arena);
    try beside.rect(arena, "met1", 3000, 0, 5000, 2000);
    try list.append(arena, .{ "slotted_beside_unslotted", beside, try c.areas(arena, &.{4_000_000}) });
    try list.append(arena, .{ "empty", .{}, &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| {
        var l = cs[1];
        try l.rect(arena, "other", -1000, -1000, -900, -900);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cheesing/{s}", .{cs[0]}), &.{"DRC-075"}, deck, l, &.{.{ "slot", cs[2] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Fill rules: fill width and fill-to-drawn spacing (`min_width`,
/// `min_spacing_diff`, DRC-073), and no fill in an exclusion region
/// (`forbidden(fill and nofill)`, DRC-074), each measured as its kind
/// defines.
fn fillInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck_fill = try c.newDeck(arena, &.{ "met1", "fill" }, "rule fill.w width(fill) >= 100nm\nrule fill.s space(fill, met1) >= 200nm\n");
    const deck_nofill = try c.newDeck(arena, &.{ "fill", "nofill" }, "rule dcf.8 forbidden(fill and nofill)\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(200)) |sw| {
        const g = sw.value;
        var l = try boxes(arena, "met1", &.{.{ 0, 0, 1000, 1000 }});
        try l.rect(arena, "fill", 1000 + g, 0, 1500 + g, 500);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "fill/spacing/{s}", .{sw.side}), &.{"DRC-073"}, deck_fill, l, &.{ .{ "fill.w", &.{} }, .{ "fill.s", try c.below(arena, g, 200) } }));
    }
    for (c.sweep3(100)) |sw| {
        const w = sw.value;
        var l = try boxes(arena, "met1", &.{.{ 0, 0, 1000, 1000 }});
        try l.rect(arena, "fill", 2000, 0, 2000 + w, 1000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "fill/width/{s}", .{sw.side}), &.{"DRC-073"}, deck_fill, l, &.{ .{ "fill.w", try c.below(arena, w, 100) }, .{ "fill.s", &.{} } }));
    }
    const nofills = [_]struct { []const u8, Rect, []const i128 }{
        .{ "inside_exclusion", .{ 800, 200, 1500, 700 }, &.{100_000} },
        .{ "touching_exclusion", .{ 1000, 200, 1500, 700 }, &.{} },
        .{ "apart", .{ 1100, 200, 1500, 700 }, &.{} },
    };
    for (nofills) |n| {
        var l = try boxes(arena, "fill", &.{.{ 0, 0, 1000, 1000 }});
        try c.rects(arena, &l, "nofill", &.{n[1]});
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "fill/nofill/{s}", .{n[0]}), &.{ "DRC-074", "DRC-050" }, deck_nofill, l, &.{.{ "dcf.8", try c.areas(arena, n[2]) }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every region density, cheesing and fill fixture holds" {
    // Oracle: coverages, areas and gaps fixed by construction against each
    // rule's definition (sky130 vpp.5a and vpp.11 for the region density;
    // the doc comments above), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
