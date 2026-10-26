//! Exact and listed sizes: `cut_size` (DRC-013), `cut_class` (DRC-014) and
//! `allowed_width` (DRC-015, DRC-090), closed and open-ended, as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs (`cut_size`,
//! `cut_class`, `allowed_width`, `allowed_width_open_last`).
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
    try cutSizeInto(arena, depth, out);
    try cutClassInto(arena, depth, out);
    try allowedWidthInto(arena, depth, out);
    try allowedWidthOpenLastInto(arena, depth, out);
}

// ---- private ----

/// `via` rectangles.
fn via(arena: Allocator, boxes: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, "via", boxes);
    return l;
}

/// `findings` as a fresh slice, or none.
fn some(arena: Allocator, findings: []const Finding) ![]const Finding {
    return arena.dupe(Finding, findings);
}

/// `size(via) == 100nm x 150nm` (`cut_size`, DRC-013): every merged figure
/// is exactly that rectangle, either way round. A wrong short side reports
/// it, else a wrong long side, else (a non-rectangle with the right box)
/// the area; at the centre of the figure's bounding box.
///
/// Each side swept one step either side; a square cut; two 100 x 75 halves
/// that merge into a legal cut, and two legal cuts that merge into an
/// illegal slot; a corner bite and a hole (the right box, the wrong shape);
/// a cut drawn twice. Two rules of one size each flag each other's cuts:
/// several legal sizes are `cut_class`'s (DRC-014).
fn cutSizeInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = "grid 1nm\nlayer via = gds(68, 44)\nrule cs size(via) == 100nm x 150nm\n";
    const catalog: []const []const u8 = &.{"DRC-013"};
    var cases: std.ArrayList(Fixture) = .empty;
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (try c.sweep(arena, depth, 100)) |s| {
        const findings: []const Finding = if (s == 100) &.{} else try some(arena, &.{c.pin(.length(s), s, 150)});
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "short_side/{s}", .{try c.side(arena, s, 100)}), try via(arena, &.{.{ 0, 0, s, 150 }}), findings });
    }
    for (try c.sweep(arena, depth, 150)) |l| {
        const findings: []const Finding = if (l == 150) &.{} else try some(arena, &.{c.pin(.length(l), 100, l)});
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "long_side/{s}", .{try c.side(arena, l, 150)}), try via(arena, &.{.{ 0, 0, 100, l }}), findings });
    }
    try shapes.append(arena, .{ "square", try via(arena, &.{.{ 0, 0, 100, 100 }}), &.{Finding.length(100).pinned(50, 50)} });
    try shapes.append(arena, .{ "both_sides_off", try via(arena, &.{.{ 0, 0, 99, 149 }}), &.{Finding.any()} });
    try shapes.append(arena, .{ "halves_make_a_cut", try via(arena, &.{ .{ 0, 0, 100, 75 }, .{ 0, 75, 100, 150 } }), &.{} });
    try shapes.append(arena, .{ "two_cuts_make_a_slot", try via(arena, &.{ .{ 0, 0, 100, 150 }, .{ 100, 0, 200, 150 } }), &.{Finding.length(150).pinned(100, 75)} });
    var bite: Layout = .{};
    try bite.polygon(arena, "via", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 140 }, .{ 90, 140 }, .{ 90, 150 }, .{ 0, 150 } });
    try shapes.append(arena, .{ "corner_bite", bite, &.{Finding.area(14_900).pinned(50, 75)} });
    var holed: Layout = .{};
    try holed.polygon(arena, "via", try c.holed(arena, .{ 0, 0, 100, 150 }, .{ 40, 40, 60, 110 }));
    try shapes.append(arena, .{ "holed", holed, &.{Finding.area(13_600).pinned(50, 75)} });
    try shapes.append(arena, .{ "drawn_twice", try via(arena, &.{ .{ 0, 0, 100, 150 }, .{ 0, 0, 100, 150 } }), &.{} });
    try shapes.append(arena, .{ "drawn_twice_offset", try via(arena, &.{ .{ 0, 0, 100, 150 }, .{ 0, 10, 100, 160 } }), &.{Finding.length(160).pinned(50, 80)} });
    try shapes.append(arena, .{ "array_with_one_wrong", try via(arena, &.{ .{ 0, 0, 100, 150 }, .{ 300, 0, 400, 150 }, .{ 600, 0, 700, 150 }, .{ 900, 0, 1020, 150 } }), &.{Finding.length(120).pinned(960, 75)} });
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cut_size/{s}", .{s[0]}), catalog, deck, s[1], &.{.{ "cs", s[2] }}));
    // Two exact-size rules on one layer flag each other's cuts by the long
    // side; two legal classes are one `cut_class` rule (DRC-014).
    try cases.append(arena, try c.fixture(arena, "cut_size/two_classes", &.{ "DRC-013", "DRC-014" }, "grid 1nm\nlayer via = gds(68, 44)\nrule c1 size(via) == 100nm x 100nm\nrule c2 size(via) == 100nm x 200nm\n", try via(arena, &.{ .{ 0, 0, 100, 100 }, .{ 1000, 0, 1100, 200 } }), &.{
        .{ "c1", &.{Finding.length(200).pinned(1050, 100)} },
        .{ "c2", &.{Finding.length(100).pinned(50, 50)} },
    }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.fixture(arena, "cut_size/vacuous", catalog, "grid 1nm\nlayer via = gds(68, 44)\nlayer met1 = gds(68, 20)\nrule cs size(via) == 100nm x 150nm\n", try c.met1(arena, &.{.{ 0, 0, 1000, 1000 }}), &.{.{ "cs", &.{} }}));
}

/// `size(via; allowed: [100nm x 100nm, 100nm x 200nm])` (`cut_class`,
/// DRC-014: sky130 via.1b's three square via sizes, LEF58 `CUTCLASS`):
/// every merged figure is a rectangle of one listed size, either way round;
/// one finding per figure that is none, at its bounding box's centre,
/// measuring `Count(0)`.
///
/// Oracle: sizes fixed by construction. Each class exactly (clean), and
/// each side of each class one step either side (a finding); a 200 square,
/// whose side is only a slot's long side (a check comparing sides one at a
/// time passes it); two abutting squares that merge into the legal slot,
/// and two abutting slots that merge into an illegal 200 x 200 square (a
/// check reading drawn rows sees two legal cuts each time); a slot with a
/// corner bite and one with a hole (the right box, no rectangle); one wrong
/// cut in an array. The second rule writes the list in another order with a
/// repeat, and finds the same.
fn cutClassInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = "grid 1nm\nlayer via = gds(68, 44)\nrule cc size(via; allowed: [100nm x 100nm, 100nm x 200nm])\nrule cr size(via; allowed: [200nm x 100nm, 100nm x 100nm, 100nm x 100nm])\n";
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for ([_][2]i64{ .{ 100, 100 }, .{ 100, 200 } }) |wh| {
        const w = wh[0];
        const h = wh[1];
        for (try c.sweep(arena, depth, w)) |dw| {
            const findings: []const Finding = if (dw == w) &.{} else try some(arena, &.{c.pin(c.count(0), dw, h)});
            try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "{d}x{d}/width/{s}", .{ w, h, try c.side(arena, dw, w) }), try via(arena, &.{.{ 0, 0, dw, h }}), findings });
        }
        for (try c.sweep(arena, depth, h)) |dh| {
            const findings: []const Finding = if (dh == h) &.{} else try some(arena, &.{c.pin(c.count(0), w, dh)});
            try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "{d}x{d}/height/{s}", .{ w, h, try c.side(arena, dh, h) }), try via(arena, &.{.{ 0, 0, w, dh }}), findings });
        }
    }
    try shapes.append(arena, .{ "square_of_a_long_side", try via(arena, &.{.{ 0, 0, 200, 200 }}), &.{c.count(0).pinned(100, 100)} });
    try shapes.append(arena, .{ "two_squares_make_a_slot", try via(arena, &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } }), &.{} });
    try shapes.append(arena, .{ "two_slots_make_a_square", try via(arena, &.{ .{ 0, 0, 100, 200 }, .{ 100, 0, 200, 200 } }), &.{c.count(0).pinned(100, 100)} });
    var bite: Layout = .{};
    try bite.polygon(arena, "via", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 190 }, .{ 90, 190 }, .{ 90, 200 }, .{ 0, 200 } });
    try shapes.append(arena, .{ "corner_bite", bite, &.{c.count(0).pinned(50, 100)} });
    var holed: Layout = .{};
    try holed.polygon(arena, "via", try c.holed(arena, .{ 0, 0, 100, 200 }, .{ 40, 40, 60, 160 }));
    try shapes.append(arena, .{ "holed", holed, &.{c.count(0).pinned(50, 100)} });
    try shapes.append(arena, .{ "array_with_one_wrong", try via(arena, &.{ .{ 0, 0, 100, 100 }, .{ 300, 0, 400, 200 }, .{ 600, 0, 700, 100 }, .{ 900, 0, 1000, 150 } }), &.{c.count(0).pinned(950, 75)} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cut_class/{s}", .{s[0]}), &.{"DRC-014"}, deck, s[1], &.{ .{ "cc", s[2] }, .{ "cr", s[2] } }));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.fixture(arena, "cut_class/vacuous", &.{"DRC-014"}, "grid 1nm\nlayer via = gds(68, 44)\nlayer met1 = gds(68, 20)\nrule cc size(via; allowed: [100nm x 100nm])\n", try c.met1(arena, &.{.{ 0, 0, 1000, 1000 }}), &.{.{ "cc", &.{} }}));
}

/// `width(met1; allowed: [100nm, 200nm])` (`allowed_width`, DRC-015 and
/// DRC-090: sky130 rpm.1b-1f, a precision resistor's five legal widths):
/// one finding per merged figure whose narrowest width is not listed, at
/// the centre of its first rectangle, measuring that width.
///
/// Oracle: widths fixed by construction: bars at each listed width and one
/// step either side; a 150 square, between the two; a 100 bar drawn as two
/// abutting 50 halves (each 50 unmerged); an L of a 100 and a 200 arm,
/// judged by its narrower; two plates overlapping 100 x 100 at a corner, a
/// neck of √20000 (141 floored), which no facing pair sees.
fn allowedWidthInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule aw width(met1; allowed: [100nm, 200nm])");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for ([_]i64{ 100, 200 }) |listed| for (try c.sweep(arena, depth, listed)) |w| {
        const findings: []const Finding = if (w == listed) &.{} else try some(arena, &.{c.pin(.length(w), w, 1000)});
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "bar_{d}/{s}", .{ listed, try c.side(arena, w, listed) }), try c.met1(arena, &.{.{ 0, 0, w, 1000 }}), findings });
    };
    try shapes.append(arena, .{ "between", try c.met1(arena, &.{.{ 0, 0, 150, 150 }}), &.{Finding.length(150).pinned(75, 75)} });
    try shapes.append(arena, .{ "halves", try c.met1(arena, &.{ .{ 0, 0, 50, 1000 }, .{ 50, 0, 100, 1000 } }), &.{} });
    try shapes.append(arena, .{ "l_of_two_widths", try c.met1(arena, &.{ .{ 0, 0, 1000, 100 }, .{ 0, 100, 200, 1000 } }), &.{} });
    try shapes.append(arena, .{ "corner_neck", try c.met1(arena, &.{ .{ 0, 0, 1000, 1000 }, .{ 900, 900, 1900, 1900 } }), &.{Finding.length(141)} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "allowed_width/{s}", .{s[0]}), &.{ "DRC-015", "DRC-090" }, deck, s[1], &.{.{ "aw", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "allowed_width", &.{"DRC-015"}, "rule aw width(met1; allowed: [100nm])", &.{"aw"}));
}

/// `width(met1; allowed: [100nm, 200nm], open_last: true)`
/// (`allowed_width`, DRC-015): LEF58 `WIDTHTABLE 0.10 0.20`, "all the given
/// widths are exact width values, except for the last one, which is equal
/// to or greater than the value".
///
/// Oracle: the LEF text, widths fixed by construction. Bars swept one step
/// around 100 (exact: 99 and 101 fail) and 200 (open: 199 fails against
/// 200, 200 and 201 pass); a 1000 square passes, as LEF's 0.42 under a last
/// 0.40 does (Figure 1-32 b); a 150 square, between the two, fails; an L of
/// a 100 and a 1000 arm is judged by its narrower, and passes.
fn allowedWidthOpenLastInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule aw width(met1; allowed: [100nm, 200nm], open_last: true)");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for ([_]i64{ 100, 200 }) |listed| for (try c.sweep(arena, depth, listed)) |w| {
        const legal = w == 100 or w >= 200;
        const findings: []const Finding = if (legal) &.{} else try some(arena, &.{c.pin(.length(w), w, 1000)});
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "bar_{d}/{s}", .{ listed, try c.side(arena, w, listed) }), try c.met1(arena, &.{.{ 0, 0, w, 1000 }}), findings });
    };
    try shapes.append(arena, .{ "wide", try c.met1(arena, &.{.{ 0, 0, 1000, 1000 }}), &.{} });
    try shapes.append(arena, .{ "between", try c.met1(arena, &.{.{ 0, 0, 150, 150 }}), &.{Finding.length(150).pinned(75, 75)} });
    try shapes.append(arena, .{ "l_of_exact_and_wide", try c.met1(arena, &.{ .{ 0, 0, 3000, 100 }, .{ 0, 100, 1000, 1100 } }), &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |s| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "allowed_width_open_last/{s}", .{s[0]}), &.{"DRC-015"}, deck, s[1], &.{.{ "aw", s[2] }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every cut_size, cut_class and allowed_width fixture holds" {
    // Oracle: each fixture's expected answer, derived from each kind's
    // definition (the doc comments above): sizes fixed by construction and
    // swept one grid step either side, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
