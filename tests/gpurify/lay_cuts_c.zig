//! Adjacent-cut spacing, protrusion width, keep-out zones and the cut-class
//! spacing table as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`adjacent_cut_spacing`,
//! `protrusion_width`, `keep_out_zone`, `cut_class_spacing`).
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

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try adjacentCutSpacingInto(arena, out);
    try protrusionWidthInto(arena, out);
    try keepOutZoneInto(arena, out);
    try cutClassSpacingInto(arena, out);
}

// ---- private ----

/// A layout of `rs` on `layer`.
fn boxes(arena: Allocator, layer: []const u8, rs: []const Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, rs);
    return l;
}

/// `n` findings each measuring `g`.
fn repeated(arena: Allocator, g: i64, n: usize) ![]const Finding {
    const found = try arena.alloc(Finding, n);
    for (found) |*f| f.* = .length(g);
    return found;
}

/// `cols` x `rows` cuts of 200 nm, `gx` apart along a row and `gy` apart
/// between rows.
fn array(arena: Allocator, cols: i64, rows: i64, gx: i64, gy: i64) ![]const Rect {
    var out: std.ArrayList(Rect) = .empty;
    var col: i64 = 0;
    while (col < cols) : (col += 1) {
        var r: i64 = 0;
        while (r < rows) : (r += 1) {
            const x = col * (200 + gx);
            const y = r * (200 + gy);
            try out.append(arena, .{ x, y, x + 200, y + 200 });
        }
    }
    return out.items;
}

/// `adjacent_space(cut; cuts: 3, within: 250nm) >= 220nm` (`cut_spacing`,
/// DRC-062, LEF Spacing Rule Example 2 "SPACING 0.22 ADJACENTCUTS 3 WITHIN
/// 0.25") on 200 nm cuts, and `adjacent_space(cut, center; cuts: 3, within:
/// 300nm) >= 300nm` (DRC-061 and DRC-062, Example 4 "a cut can have only two
/// other cuts with center-to-center spacing that is less than 0.30 um") on
/// 100 nm cuts: a pair closer than the limit fails when either cut has at
/// least three other cuts strictly closer than `within`.
///
/// Oracle: the manual's own Figure 1-6. With the diagonal beyond `within`, a
/// cut of a 1 x n row or a 2 x 2 array has two adjacent cuts, a middle cut
/// of a 2 x 3 array three, and the centre of a 3 x 3 four; so at a 219 nm
/// gap a row and a 2 x 2 pass, a 2 x 3 fails on the five pairs that touch
/// its middle cuts, and a 3 x 3 on all twelve side pairs.
///
/// Shapes: those arrays at gaps 219/220/221; a 2 x 3 array 219 apart along
/// its rows with its rows 249, 250 and 251 apart (its middle cuts are held
/// only at 249: `within` is strict); for the centre form, a T of four cuts
/// at a 299/300/301 pitch (its middle has three neighbours) and a 2 x 2 at
/// 299 (two each, clean).
fn adjacentCutSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 220;
    const deck = try c.newDeck(arena, &.{"cut"}, "rule adj adjacent_space(cut; cuts: 3, within: 250nm) >= 220nm\n");
    const Case = struct { []const u8, []const Rect, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(limit)) |sw| {
        const g = sw.value;
        const close5: []const Finding = if (g < limit) try repeated(arena, g, 5) else &.{};
        const close12: []const Finding = if (g < limit) try repeated(arena, g, 12) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "row4/{s}", .{sw.side}), try array(arena, 4, 1, g, g), &.{} });
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "array2x2/{s}", .{sw.side}), try array(arena, 2, 2, g, g), &.{} });
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "array3x2/{s}", .{sw.side}), try array(arena, 3, 2, g, g), close5 });
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "array3x3/{s}", .{sw.side}), try array(arena, 3, 3, g, g), close12 });
    }
    const apart = [_]struct { i64, []const u8, usize }{ .{ 249, "below", 4 }, .{ 250, "at", 0 }, .{ 251, "above", 0 } };
    for (apart) |a| try list.append(arena, .{ try std.fmt.allocPrint(arena, "rows_apart/{s}", .{a[1]}), try array(arena, 3, 2, 219, a[0]), try repeated(arena, 219, a[2]) });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "adjacent_cut_spacing/{s}", .{cs[0]}), &.{"DRC-062"}, deck, try boxes(arena, "cut", cs[1]), &.{.{ "adj", cs[2] }}));
    const deck_center = try c.newDeck(arena, &.{"cut"}, "rule adjc adjacent_space(cut, center; cuts: 3, within: 300nm) >= 300nm\n");
    for (c.sweep3(300)) |sw| {
        const p = sw.value;
        const tee = [_]Rect{ .{ 0, 0, 100, 100 }, .{ -p, 0, 100 - p, 100 }, .{ p, 0, 100 + p, 100 }, .{ 0, p, 100, 100 + p } };
        const found: []const Finding = if (p < 300) try repeated(arena, p, 3) else &.{};
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "adjacent_cut_spacing/center/tee/{s}", .{sw.side}), &.{ "DRC-061", "DRC-062" }, deck_center, try boxes(arena, "cut", &tee), &.{.{ "adjc", found }}));
    }
    try cases.append(arena, try c.fixture(arena, "adjacent_cut_spacing/center/array2x2", &.{ "DRC-061", "DRC-062" }, deck_center, try boxes(arena, "cut", &.{ .{ 0, 0, 100, 100 }, .{ 299, 0, 399, 100 }, .{ 0, 299, 100, 399 }, .{ 299, 299, 399, 399 } }), &.{.{ "adjc", &.{} }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// The 2000 nm plate every protrusion case but two stands on, with `extra`.
fn plate(arena: Allocator, extra: []const Rect) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "m", 0, 0, 2000, 2000);
    try c.rects(arena, &l, "m", extra);
    return l;
}

/// LEF 5.8 `PROTRUSIONWIDTH 0.28 LENGTH 0 WIDTH 1.20` (`protrusion_width`,
/// DRC-125): `protrusion_width(m; wide: 1200nm) >= 280nm`, one finding per
/// narrow part attached to a wide part, measuring its width.
///
/// Oracle: widths drawn by construction against LEF's statement: a stub
/// 279, 280, 281 wide on a 2000 plate (one finding of 279); a 200 stub on a
/// plate 1199, 1200, 1201 wide (a plate exactly 1200 wide is wide); the stub
/// drawn as two abutting 100 halves (one finding of 200: an unmerged reading
/// gives two of 100); a 200 neck joining two plates (one); a lone 200 wire
/// and a 200 tip on a 500 stub on the plate (none: neither touches a wide
/// part).
fn protrusionWidthInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{"m"}, "rule pw protrusion_width(m; wide: 1200nm) >= 280nm\n");
    const Case = struct { []const u8, Layout, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(280)) |sw| {
        const w = sw.value;
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "stub/{s}", .{sw.side}), try plate(arena, &.{.{ 500, 2000, 500 + w, 2600 }}), try c.below(arena, w, 280) });
    }
    for (c.sweep3(1200)) |sw| {
        const p = sw.value;
        const found: []const Finding = if (p >= 1200) try c.lengths(arena, &.{200}) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "plate/{s}", .{sw.side}), try boxes(arena, "m", &.{ .{ 0, 0, p, 3000 }, .{ p, 1000, p + 600, 1200 } }), found });
    }
    try list.append(arena, .{ "stub_halves", try plate(arena, &.{ .{ 500, 2000, 600, 2600 }, .{ 600, 2000, 700, 2600 } }), try c.lengths(arena, &.{200}) });
    try list.append(arena, .{ "neck", try plate(arena, &.{ .{ 2600, 0, 4600, 2000 }, .{ 2000, 900, 2600, 1100 } }), try c.lengths(arena, &.{200}) });
    try list.append(arena, .{ "lone_wire", try boxes(arena, "m", &.{.{ 0, 0, 200, 3000 }}), &.{} });
    try list.append(arena, .{ "tip_on_a_stub", try plate(arena, &.{ .{ 800, 2000, 1300, 2600 }, .{ 950, 2600, 1150, 3000 } }), &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "protrusion_width/{s}", .{cs[0]}), &.{"DRC-125"}, deck, cs[1], &.{.{ "pw", cs[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// The bar `[0, 300] x [0, 100]` and a 100 nm square at `(x, y)`.
fn square(arena: Allocator, x: i64, y: i64) !Layout {
    return boxes(arena, "v", &.{ .{ 0, 0, 300, 100 }, .{ x, y, x + 100, y + 100 } });
}

/// `LEF58_KEEPOUTZONE CUTCLASS c1 [TO c2] ENDEXTENSION 0.010 0.080
/// SIDEEXTENSION 0.050 0.020` (`keep_out_zone`, DRC-126) on a 100 x 300
/// class: `k` holds out every cut, `kt` (its class written 300 x 100) only
/// 100 nm squares. Round a bar `[0, 300] x [0, 100]` the side zone is `[-20,
/// 320] x [-50, 150]` and the end zone `[-10, 310] x [-80, 180]`, as
/// `OpenROAD`'s `checKeepOutZone_main` bloats a horizontal via. One finding
/// per cut of the class and cut in its zones, measuring that cut's area
/// inside them.
///
/// Oracle: areas by hand from the zones: a square past the bar's end 19,
/// 20, 21 from it (in the side zone below 20: 100 at 19; touching is
/// outside), a square above it 79, 80, 81 off (in the end zone below 80); a
/// square 20 above it, in both zones (6000, their union: summing the two
/// gives 9000); a square off the corner (125, in the end zone only); a
/// second bar 79 above (300 each way for `k`, two findings, none for `kt`);
/// two squares 10 apart (no class owns a zone: a check holding squares
/// breaks it).
fn keepOutZoneInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const zones = "end_side: 10nm, end_forward: 80nm, side_side: 50nm, side_forward: 20nm";
    const deck = try c.newDeck(arena, &.{"v"}, "rule k keep_out_zone(v; class: 100nm x 300nm, to: none, " ++ zones ++ ")\nrule kt keep_out_zone(v; class: 300nm x 100nm, to: 100nm x 100nm, " ++ zones ++ ")\n");
    const Case = struct { []const u8, Layout, []const Finding, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(20)) |sw| {
        const found: []const Finding = if (sw.value < 20) try c.areas(arena, &.{100}) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "past_the_end/{s}", .{sw.side}), try square(arena, 300 + sw.value, 0), found, found });
    }
    for (c.sweep3(80)) |sw| {
        const found: []const Finding = if (sw.value < 80) try c.areas(arena, &.{100}) else &.{};
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "above/{s}", .{sw.side}), try square(arena, 100, 100 + sw.value), found, found });
    }
    try list.append(arena, .{ "in_both_zones", try square(arena, 100, 120), try c.areas(arena, &.{6000}), try c.areas(arena, &.{6000}) });
    try list.append(arena, .{ "off_the_corner", try square(arena, 305, 155), try c.areas(arena, &.{125}), try c.areas(arena, &.{125}) });
    try list.append(arena, .{ "two_bars", try boxes(arena, "v", &.{ .{ 0, 0, 300, 100 }, .{ 0, 179, 300, 279 } }), try c.areas(arena, &.{ 300, 300 }), &.{} });
    try list.append(arena, .{ "two_squares", try boxes(arena, "v", &.{ .{ 0, 0, 100, 100 }, .{ 110, 0, 210, 100 } }), &.{}, &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "keep_out_zone/{s}", .{cs[0]}), &.{"DRC-126"}, deck, cs[1], &.{ .{ "k", cs[2] }, .{ "kt", cs[3] } }));
    try c.everyPlacementInto(arena, cases.items, out);
    var vacuous: Fixture = .init("keep_out_zone/vacuous", &.{"DRC-126"}, deck, harness.drc);
    try vacuous.layout.rect(arena, "v", 0, 0, 100, 100);
    try vacuous.claim(arena, Expect.rule("k", &.{}).examined(0));
    try out.append(arena, vacuous);
}

/// sky130 licon.2 to licon.2d as one cut-class table (`cut_class_spacing`,
/// DRC-063 and DRC-064): square 170 nm licons 170 apart (licon.2), slotted
/// 190 x 2000 licons 350 apart end to end (licon.2b, "when both the edges
/// are 0.19um in length") and 510 otherwise (licon.2c), and 510 from a
/// square (licon.2d). One finding per pair closer than its cell, measuring
/// the gap.
///
/// Oracle: the sky130 manual's values, and gaps drawn to them; a pair apart
/// along both axes needs the larger of its two readings (`OpenROAD`'s
/// `checkLef58CutSpacingTbl_helper` checks both directions).
///
/// Shapes: squares, slots end to end, slots side by side, a slot beside a
/// square and a square past a slot's end, each swept around its cell; slots
/// end to end 400 apart (only an END-to-END reading passes them); slots
/// offset diagonally 414.8 apart (END to END along y, SIDE to SIDE along x:
/// 510); a 200 nm cut of no class 10 from a square (not checked);
/// overlapping squares, and a slot abutting a square (0, held to the
/// largest cell).
fn cutClassSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{"licon"}, "rule licon.2 cut_class_space(licon;\nshort: [170nm, 190nm], long: [170nm, 2000nm],\nspace: [[170nm, 170nm, 510nm, 510nm], [170nm, 170nm, 510nm, 510nm],\n[510nm, 510nm, 350nm, 510nm], [510nm, 510nm, 510nm, 510nm]])\n");
    const slot: Rect = .{ 0, 0, 190, 2000 };
    const Case = struct { []const u8, []const Rect, []const Finding };
    var list: std.ArrayList(Case) = .empty;
    for (c.sweep3(170)) |sw| {
        const g = sw.value;
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "squares/{s}", .{sw.side}), try arena.dupe(Rect, &.{ .{ 0, 0, 170, 170 }, .{ 170 + g, 0, 340 + g, 170 } }), try c.below(arena, g, 170) });
    }
    for (c.sweep3(350)) |sw| {
        const g = sw.value;
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "end_to_end/{s}", .{sw.side}), try arena.dupe(Rect, &.{ slot, .{ 0, 2000 + g, 190, 4000 + g } }), try c.below(arena, g, 350) });
    }
    for (c.sweep3(510)) |sw| {
        const g = sw.value;
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "side_by_side/{s}", .{sw.side}), try arena.dupe(Rect, &.{ slot, .{ 190 + g, 0, 380 + g, 2000 } }), try c.below(arena, g, 510) });
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "slot_beside_square/{s}", .{sw.side}), try arena.dupe(Rect, &.{ slot, .{ 190 + g, 900, 360 + g, 1070 } }), try c.below(arena, g, 510) });
        try list.append(arena, .{ try std.fmt.allocPrint(arena, "square_past_slot_end/{s}", .{sw.side}), try arena.dupe(Rect, &.{ slot, .{ 10, 2000 + g, 180, 2170 + g } }), try c.below(arena, g, 510) });
    }
    try list.append(arena, .{ "end_to_end_400", &.{ slot, .{ 0, 2400, 190, 4400 } }, &.{} });
    try list.append(arena, .{ "diagonal", &.{ slot, .{ 300, 2400, 490, 4400 } }, try c.lengths(arena, &.{414}) });
    try list.append(arena, .{ "unclassed", &.{ .{ 0, 0, 170, 170 }, .{ 180, 0, 380, 200 } }, &.{} });
    try list.append(arena, .{ "overlapping_squares", &.{ .{ 0, 0, 170, 170 }, .{ 100, 0, 270, 170 } }, try c.lengths(arena, &.{0}) });
    try list.append(arena, .{ "slot_abutting_square", &.{ slot, .{ 190, 0, 360, 170 } }, try c.lengths(arena, &.{0}) });
    var cases: std.ArrayList(Fixture) = .empty;
    for (list.items) |cs| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cut_class_spacing/{s}", .{cs[0]}), &.{ "DRC-063", "DRC-064" }, deck, try boxes(arena, "licon", cs[1]), &.{.{ "licon.2", cs[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every adjacent-cut, protrusion, keep-out and cut-class fixture holds" {
    // Oracle: each fixture's expected answer, derived by construction from
    // the LEF manual's examples and the sky130 manual's values (the doc
    // comments above), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
