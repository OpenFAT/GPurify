//! Enclosure by wire width, extra cut and overhang length (DRC-043) as
//! exhaustive fixtures. Ported from tests/exhaustive/drc_overlay.rs
//! (`wire_enclosure`, `extra_cut_enclosure`, `length_enclosure`).
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
const enc = @import("lay_enclosure.zig");
const Cases = enc.Cases;
const Box = enc.Box;
const drawn = enc.drawn;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try wireEnclosureInto(arena, out);
    try extraCutEnclosureInto(arena, out);
    try lengthEnclosureInto(arena, out);
}

// ---- private ----

/// Enclosure by wire width, LEF/DEF 5.8 Example 1-3's `via23` in nm:
/// `enclosure(via, met2, opposite; below: 1000nm) >= 50nm` (`narrow`),
/// `enclosure(via, met2; width: 1000nm, below: 2000nm) >= 20nm` (`mid`) and
/// `enclosure(via, met2; width: 2000nm) >= 50nm` (`wide`) (`min_enclosure`
/// and `asymmetric_enclosure` with a wire band, DRC-043): each 200 nm via
/// is held by exactly one row, the one whose band holds the width of the
/// wire it lies on (where a square that wide fits around all of it), and an
/// unhosted via by the lowest.
///
/// Oracle: the wires are drawn to a width, and the via's margins to the
/// wire's edges are drawn: 15 to the left, 30 below. So `narrow` reads
/// `max(min(15, far), min(30, far)) = 30` and the others 15.
///
/// Shapes: a wire 999, 1000, 1001, 1999, 2000 and 2001 wide (the bands'
/// edges, inclusive below, exclusive above); a via on a 500 nm tab off a
/// 3000 nm plate (the tab's width, not the plate's, so `narrow` reads 20);
/// a via 40 into a corner of the plate (`wide` only); an unhosted via
/// (`narrow`, 0).
fn wireEnclosureInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cs: Cases = .{ .arena = arena, .prefix = "wire_enclosure", .catalog = &.{ "DRC-043", "DRC-040", "DRC-041" }, .deck = try c.newDeck(arena, &.{ "via", "met2" }, "rule narrow enclosure(via, met2, opposite; below: 1000nm) >= 50nm\n" ++
        "rule mid enclosure(via, met2; width: 1000nm, below: 2000nm) >= 20nm\n" ++
        "rule wide enclosure(via, met2; width: 2000nm) >= 50nm\n"), .ids = &.{ "narrow", "mid", "wide" } };
    const via: Box = .{ "via", .{ 0, 0, 200, 200 } };
    const none: []const Finding = &.{};
    for ([_]i64{ 999, 1000, 1001, 1999, 2000, 2001 }) |w| {
        const rows: [3][]const Finding = if (w < 1000)
            .{ try c.lengths(arena, &.{30}), none, none }
        else if (w < 2000)
            .{ none, try c.lengths(arena, &.{15}), none }
        else
            .{ none, none, try c.lengths(arena, &.{15}) };
        try cs.add(try std.fmt.allocPrint(arena, "wire/{d}", .{w}), try drawn(arena, &.{ via, .{ "met2", .{ -15, -30, 3000, w - 30 } } }), &rows);
    }
    try cs.add("tab", try drawn(arena, &.{ .{ "met2", .{ 0, 0, 3000, 3000 } }, .{ "met2", .{ 3000, 1000, 3800, 1500 } }, .{ "via", .{ 3580, 1150, 3780, 1490 } } }), &.{ try c.lengths(arena, &.{20}), none, none });
    try cs.add("plate", try drawn(arena, &.{ .{ "met2", .{ 0, 0, 3000, 3000 } }, .{ "via", .{ 40, 40, 240, 240 } } }), &.{ none, none, try c.lengths(arena, &.{40}) });
    try cs.add("unhosted", try drawn(arena, &.{ via, .{ "met2", .{ 5000, 5000, 6000, 6000 } } }), &.{ try c.lengths(arena, &.{0}), none, none });
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// LEF/DEF 5.8 Example 1-4's `via34` in nm, `ENCLOSURE 0.03 0.03 WIDTH 0.3
/// EXCEPTEXTRACUT 0.2` beside the minimum-width `ENCLOSURE 0.0 0.05`
/// (`min_enclosure` and `asymmetric_enclosure` with an extra-cut band,
/// DRC-043): `narrow` is `enclosure(v, m, opposite; below: 300nm) >= 50nm`,
/// `taken` the same minimum-width rule over the excepted band
/// (`width: 300nm, extra_cut: 200nm, other: m2`), and `wide`
/// `enclosure(v, m; width: 300nm, except_extra_cut: 200nm, other: m2) >=
/// 30nm`. LEF: "if there is another via cut having same metal shapes on
/// both metal layers less than or equal to cutWithin distance away, this
/// ENCLOSURE with WIDTH rule is ignored and the ENCLOSURE rules for minimum
/// width wires ... are applied to the via cuts instead".
///
/// Oracle: the LEF text, margins and gaps by construction. 100 nm cuts on
/// a 400 wide `m` wire `[0, 3000] x [0, 400]` under one `m2` pad.
///
/// Shapes: one cut, its bottom margin swept around 30 (`wide` only); cut A
/// 10 from the wire's end and 20 from its bottom with cut B beside it, the
/// gap swept around 200 (at or under 200 both are `taken`: A's better axis
/// reads 20, B's x axis 300 or more; over 200 `wide` reads A 10 and B 20);
/// the same pair 100 apart with the `m2` pad split between them (`wide`, 10
/// and 20), and on two 400 wide `m` wires, A's reaching 310 left of it and
/// B's starting 40 left of it, under one pad (no shared metal, so `wide`,
/// 20 each); two cuts 100 apart on a 180 wide wire (`narrow` alone, A
/// reading 40, whatever the extra cut).
fn extraCutEnclosureInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cs: Cases = .{ .arena = arena, .prefix = "extra_cut_enclosure", .catalog = &.{"DRC-043"}, .deck = try c.newDeck(arena, &.{ "v", "m", "m2" }, "rule narrow enclosure(v, m, opposite; below: 300nm) >= 50nm\n" ++
        "rule taken enclosure(v, m, opposite; width: 300nm, extra_cut: 200nm, other: m2) >= 50nm\n" ++
        "rule wide enclosure(v, m; width: 300nm, except_extra_cut: 200nm, other: m2) >= 30nm\n"), .ids = &.{ "narrow", "taken", "wide" } };
    const none: []const Finding = &.{};
    const wire = [_]Box{ .{ "m", .{ 0, 0, 3000, 400 } }, .{ "m2", .{ -500, -500, 3500, 900 } } };
    for (c.sweep3(30)) |sw| {
        const m = sw.value;
        var single = try drawn(arena, &wire);
        try single.rect(arena, "v", 1000, m, 1100, m + 100);
        try cs.add(try std.fmt.allocPrint(arena, "single/{s}", .{sw.side}), single, &.{ none, none, try c.below(arena, m, 30) });
    }
    for (c.sweep3(200)) |sw| {
        const rows: [3][]const Finding = if (sw.value <= 200) .{ none, try c.lengths(arena, &.{20}), none } else .{ none, none, try c.lengths(arena, &.{ 10, 20 }) };
        try cs.add(try std.fmt.allocPrint(arena, "pair/{s}", .{sw.side}), try pair(arena, &wire, sw.value), &rows);
    }
    try cs.add("pad_split", try pair(arena, &.{ .{ "m", .{ 0, 0, 3000, 400 } }, .{ "m2", .{ -500, -500, 160, 900 } }, .{ "m2", .{ 170, -500, 3500, 900 } } }, 100), &.{ none, none, try c.lengths(arena, &.{ 10, 20 }) });
    try cs.add("two_wires", try pair(arena, &.{ .{ "m", .{ -300, 0, 160, 400 } }, .{ "m", .{ 170, 0, 3000, 400 } }, .{ "m2", .{ -500, -500, 3500, 900 } } }, 100), &.{ none, none, try c.lengths(arena, &.{ 20, 20 }) });
    try cs.add("narrow_wire", try drawn(arena, &.{ .{ "m", .{ 0, 0, 3000, 180 } }, .{ "m2", .{ -500, -500, 3500, 900 } }, .{ "v", .{ 10, 40, 110, 140 } }, .{ "v", .{ 210, 40, 310, 140 } } }), &.{ try c.lengths(arena, &.{40}), none, none });
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `boxes` and two cuts, A at (10, 20) and B `gap` right of it.
fn pair(arena: Allocator, boxes: []const Box, gap: i64) !Layout {
    var l = try drawn(arena, boxes);
    try l.rect(arena, "v", 10, 20, 110, 120);
    try l.rect(arena, "v", 110 + gap, 20, 210 + gap, 120);
    return l;
}

/// LEF/DEF 5.8 Example 1-5's `via34` in nm (`min_enclosure` and
/// `asymmetric_enclosure` with a length band, DRC-043): `ENCLOSURE 0.05 0.0
/// LENGTH 0.7` is `long`, `enclosure(v, m, opposite; length: 700nm, below:
/// 1000nm) >= 50nm`; the vias it leaves to `ENCLOSURE 0.05 0.05` are
/// `short`, `enclosure(v, m; length_below: 700nm, below: 1000nm) >= 50nm`
/// (the second rule implies the first, so one of the two holds each via);
/// `ENCLOSURE 0.10 0.10 WIDTH 1.0` is `wide`. LEF: "the enclosure rule only
/// applies if the total length of the longest opposite-side overhangs is
/// greater than or equal to minLength. The total length of the overhang is
/// measured at the via cut center".
///
/// Oracle: Figure 1-5's illustrations, drawn as stated, each verdict the
/// figure's: a) 0.05 + 0.20 + 0.40 = 0.65, a violation of `short` (0 above
/// and below); b) 0.05 + 0.20 + 0.45 = 0.70, legal under `long`, with the
/// right overhang swept around 450 (449 falls to `short`, 0); c) 0.04 +
/// 0.20 + 0.50, `long` reads 40; d) b) upright; e) 0.05 on every side,
/// legal under `short`; f) an L whose arm crosses the line through the
/// cut's centre (run 750, `long`, the arm's step 50 past the cut) and one
/// whose arm stops 10 short of it (run 300, `short`, 0); g) a 1.0 wide
/// plate, `wide` reads 50. An unhosted cut runs 0, `short` reading 0.
fn lengthEnclosureInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cs: Cases = .{ .arena = arena, .prefix = "length_enclosure", .catalog = &.{"DRC-043"}, .deck = try c.newDeck(arena, &.{ "v", "m" }, "rule long enclosure(v, m, opposite; length: 700nm, below: 1000nm) >= 50nm\n" ++
        "rule short enclosure(v, m; length_below: 700nm, below: 1000nm) >= 50nm\n" ++
        "rule wide enclosure(v, m; width: 1000nm) >= 100nm\n"), .ids = &.{ "long", "short", "wide" } };
    const none: []const Finding = &.{};
    const zero = try c.lengths(arena, &.{0});
    const cut: Box = .{ "v", .{ 0, 0, 200, 200 } };
    try cs.add("a", try drawn(arena, &.{ cut, .{ "m", .{ -50, 0, 600, 200 } } }), &.{ none, zero, none });
    for (c.sweep3(450)) |sw| {
        const r = sw.value;
        const rows: [3][]const Finding = if (r < 450) .{ none, zero, none } else .{ none, none, none };
        try cs.add(try std.fmt.allocPrint(arena, "b/{s}", .{sw.side}), try drawn(arena, &.{ cut, .{ "m", .{ -50, 0, 200 + r, 200 } } }), &rows);
    }
    try cs.add("c", try drawn(arena, &.{ cut, .{ "m", .{ -40, 0, 700, 200 } } }), &.{ try c.lengths(arena, &.{40}), none, none });
    try cs.add("d", try drawn(arena, &.{ cut, .{ "m", .{ 0, -50, 200, 650 } } }), &.{ none, none, none });
    try cs.add("e", try drawn(arena, &.{ cut, .{ "m", .{ -50, -50, 250, 250 } } }), &.{ none, none, none });
    try cs.add("f/crossing", try drawn(arena, &.{ cut, .{ "m", .{ -50, 0, 250, 200 } }, .{ "m", .{ 250, 0, 700, 110 } } }), &.{ none, none, none });
    try cs.add("f/short_of_the_centre", try drawn(arena, &.{ cut, .{ "m", .{ -50, 0, 250, 200 } }, .{ "m", .{ 250, 0, 700, 90 } } }), &.{ none, zero, none });
    try cs.add("g", try drawn(arena, &.{ .{ "v", .{ 400, 50, 600, 250 } }, .{ "m", .{ 0, 0, 1000, 1000 } } }), &.{ none, none, try c.lengths(arena, &.{50}) });
    try cs.add("unhosted", try drawn(arena, &.{ cut, .{ "m", .{ 1000, 1000, 1500, 1500 } } }), &.{ none, zero, none });
    try c.everyPlacementInto(arena, cs.list.items, out);
}

test "every banded enclosure fixture holds" {
    // Oracle: the LEF/DEF 5.8 examples 1-3, 1-4 and 1-5 as their doc
    // comments above restate them: wire widths, cut gaps and overhang runs
    // by construction, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
