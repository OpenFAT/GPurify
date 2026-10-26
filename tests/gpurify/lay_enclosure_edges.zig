//! Noncoincident enclosure (DRC-054), full width (DRC-053), projection
//! spacing (DRC-055) and maximum enclosure (DRC-044) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_overlay.rs
//! (`noncoincident_enclosure`, `full_width`, `projection_spacing`,
//! `max_enclosure`).
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
    try noncoincidentEnclosureInto(arena, out);
    try fullWidthInto(arena, out);
    try projectionSpacingInto(arena, out);
    try maxEnclosureInto(arena, out);
}

// ---- private ----

/// `enclosure(lvtn, nwell, noncoincident) >= 380nm`
/// (`noncoincident_enclosure`, DRC-054, sky130 lvtn.10 "(exclude coincident
/// edges)") beside the plain `enclosure(lvtn, nwell) >= 380nm`: an lvtn edge
/// lying on the nwell's edge, or an lvtn corner touching it, is exempt from
/// the first and measures 0 under the second.
///
/// Oracle: drawn margins; the touching pairs are drawn to coincide.
///
/// lvtn is `[0, 1000]^2`. Shapes: concentric at 379/380/381 (both rules
/// alike); the left edge on the nwell's left edge with the other margins
/// swept, and also the bottom edge; the left edge on the nwell's edge for
/// its lower half only, the nwell stepping 400 out above it (exempt, then
/// 400); lvtn in an L nwell's concave corner, touching it only at that
/// corner (exempt; 600 elsewhere); an unhosted lvtn (0 for both).
fn noncoincidentEnclosureInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 380;
    var cs: Cases = .{ .arena = arena, .prefix = "noncoincident_enclosure", .catalog = &.{"DRC-054"}, .deck = try c.newDeck(arena, &.{ "lvtn", "nwell" }, "rule lvtn.10 enclosure(lvtn, nwell, noncoincident) >= 380nm\n" ++
        "rule plain enclosure(lvtn, nwell) >= 380nm\n"), .ids = &.{ "lvtn.10", "plain" } };
    const lvtn: Box = .{ "lvtn", .{ 0, 0, 1000, 1000 } };
    const zero = try c.lengths(arena, &.{0});
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        const short = try c.below(arena, m, limit);
        try cs.add(try std.fmt.allocPrint(arena, "concentric/{s}", .{sw.side}), try drawn(arena, &.{ lvtn, .{ "nwell", .{ -m, -m, 1000 + m, 1000 + m } } }), &.{ short, short });
        try cs.add(try std.fmt.allocPrint(arena, "left_on_edge/{s}", .{sw.side}), try drawn(arena, &.{ lvtn, .{ "nwell", .{ 0, -m, 1000 + m, 1000 + m } } }), &.{ short, zero });
        try cs.add(try std.fmt.allocPrint(arena, "corner_on_edges/{s}", .{sw.side}), try drawn(arena, &.{ lvtn, .{ "nwell", .{ 0, 0, 1000 + m, 1000 + m } } }), &.{ short, zero });
    }
    var partly = try drawn(arena, &.{lvtn});
    try partly.polygon(arena, "nwell", &.{ .{ 0, -400 }, .{ 1400, -400 }, .{ 1400, 1400 }, .{ -400, 1400 }, .{ -400, 500 }, .{ 0, 500 } });
    try cs.add("partly_on_edge", partly, &.{ &.{}, zero });
    var kissing = try drawn(arena, &.{.{ "lvtn", .{ 600, 600, 1000, 1000 } }});
    try kissing.polygon(arena, "nwell", &enc.l_host);
    try cs.add("kissing_corner", kissing, &.{ &.{}, zero });
    try cs.add("unhosted", try drawn(arena, &.{ lvtn, .{ "nwell", .{ 2000, 2000, 3000, 3000 } } }), &.{ zero, zero });
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `full_width(v1, m2)` (`full_width`, DRC-053, ASAP7 V1.M2.AUX.2 "V1 must
/// exactly be the same width as M2 along the direction perpendicular to the
/// M2 length"): one finding per via that meets the wire's edges on neither
/// axis, measuring the widest straight-out gap on its better axis.
///
/// Oracle: drawn gaps between the via's edges and the wire's.
///
/// Shapes, a 100 nm via: in a horizontal wire 100 wide, spanning it
/// (clean); 0 or 1 short of its top edge, and 10 short of both; in a
/// vertical wire 100 wide (spanning it along x: clean); on a 300 nm pad (100
/// on every side); alone on a 100 nm pad (both axes span: clean); a via on
/// no wire (not measured: `inside` is that rule).
fn fullWidthInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cs: Cases = .{ .arena = arena, .prefix = "full_width", .catalog = &.{"DRC-053"}, .deck = try c.newDeck(arena, &.{ "v1", "m2" }, "rule V1.M2.AUX.2 full_width(v1, m2)\n"), .ids = &.{"V1.M2.AUX.2"} };
    const wire: Box = .{ "m2", .{ -500, 0, 1000, 100 } };
    for ([_]i64{ 0, 1 }) |short| {
        const found: []const Finding = if (short > 0) try c.lengths(arena, &.{short}) else &.{};
        try cs.add(try std.fmt.allocPrint(arena, "top_short/{d}", .{short}), try drawn(arena, &.{ wire, .{ "v1", .{ 0, 0, 100, 100 - short } } }), &.{found});
    }
    try cs.add("narrower", try drawn(arena, &.{ wire, .{ "v1", .{ 0, 10, 100, 90 } } }), &.{try c.lengths(arena, &.{10})});
    try cs.add("vertical_wire", try drawn(arena, &.{ .{ "m2", .{ 0, -200, 100, 1000 } }, .{ "v1", .{ 0, 0, 100, 100 } } }), &.{&.{}});
    try cs.add("pad", try drawn(arena, &.{ .{ "m2", .{ -100, -100, 200, 200 } }, .{ "v1", .{ 0, 0, 100, 100 } } }), &.{try c.lengths(arena, &.{100})});
    try cs.add("equal_pad", try drawn(arena, &.{ .{ "m2", .{ 0, 0, 100, 100 } }, .{ "v1", .{ 0, 0, 100, 100 } } }), &.{&.{}});
    try cs.add("off_wire", try drawn(arena, &.{ wire, .{ "v1", .{ 3000, 0, 3100, 100 } } }), &.{&.{}});
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `space(lvtn, sd, projection) >= 235nm` (`projection_spacing`, DRC-055,
/// sky130 lvtn.3b as its `KLayout` deck writes it) beside the Euclidean
/// `space(lvtn, sd) >= 235nm`: a pair is measured across facing edges that
/// overlap in projection, so a pair offset diagonally passes the first.
///
/// Oracle: drawn gaps; a diagonal pair at offsets (100, 100) is 141 apart by
/// Euclid and has no facing edges.
///
/// lvtn is `[0, 500]^2`. Shapes: sd beside it at 234/235/236; sd diagonally
/// off its corner (100, 100) away (clean here, 141 there); sd overlapping
/// lvtn's side by 1 nm of projection, 100 away (100); sd whose projection
/// only meets lvtn's at a point, 50 away (clean here, 50 there); sd touching
/// (0 for both) and overlapping lvtn (0 for both).
fn projectionSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 235;
    var cs: Cases = .{ .arena = arena, .prefix = "projection_spacing", .catalog = &.{"DRC-055"}, .deck = try c.newDeck(arena, &.{ "lvtn", "sd" }, "rule lvtn.3b space(lvtn, sd, projection) >= 235nm\n" ++
        "rule euclid space(lvtn, sd) >= 235nm\n"), .ids = &.{ "lvtn.3b", "euclid" } };
    const lvtn: Box = .{ "lvtn", .{ 0, 0, 500, 500 } };
    for (c.sweep3(limit)) |sw| {
        const g = sw.value;
        const short = try c.below(arena, g, limit);
        try cs.add(try std.fmt.allocPrint(arena, "beside/{s}", .{sw.side}), try drawn(arena, &.{ lvtn, .{ "sd", .{ 500 + g, 100, 900 + g, 400 } } }), &.{ short, short });
    }
    const zero = try c.lengths(arena, &.{0});
    const hundred = try c.lengths(arena, &.{100});
    const fixed = [_]struct { []const u8, c.Rect, []const Finding, []const Finding }{
        .{ "diagonal", .{ 600, 600, 900, 900 }, &.{}, try c.lengths(arena, &.{141}) },
        .{ "one_unit_of_projection", .{ 600, 499, 900, 900 }, hundred, hundred },
        .{ "projection_meets_at_a_point", .{ 550, 500, 900, 900 }, &.{}, try c.lengths(arena, &.{50}) },
        .{ "touching", .{ 500, 100, 900, 400 }, zero, zero },
        .{ "overlapping", .{ 400, 100, 900, 400 }, zero, zero },
    };
    for (fixed) |f| try cs.add(f[0], try drawn(arena, &.{ lvtn, .{ "sd", f[1] } }), &.{ f[2], f[3] });
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `enclosure(licon, npc) <= 95nm` (`max_enclosure`, DRC-044, sky130
/// npc.5): each npc figure holding licons must lie inside their union grown
/// by 95 nm with square corners; one finding per npc figure that reaches
/// further, measuring its furthest reach rounded up.
///
/// Oracle: the reach is drawn. A licon `[0, 100]^2` in npc 50 past it on
/// three sides and `m` on the fourth reaches `max(50, m)`; a corner square
/// added off the npc's corner reaches its diagonal point's Chebyshev
/// distance; between two licons `g` apart under one npc the furthest point
/// is midway, `g / 2` from both.
///
/// Shapes: one side swept 94/95/96; a corner square to (195, 195) and to
/// (196, 196), which every straight strip from the licon reads as 50; two
/// licons 190, 191 and 192 apart under one npc (reach 95, 95.5 and 96); an
/// npc holding no licon, and one only straddled by a licon (neither is
/// measured).
fn maxEnclosureInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 95;
    var cs: Cases = .{ .arena = arena, .prefix = "max_enclosure", .catalog = &.{"DRC-044"}, .deck = try c.newDeck(arena, &.{ "licon", "npc" }, "rule npc.5 enclosure(licon, npc) <= 95nm\n"), .ids = &.{"npc.5"} };
    const licon: Box = .{ "licon", .{ 0, 0, 100, 100 } };
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        try cs.add(try std.fmt.allocPrint(arena, "side/{s}", .{sw.side}), try drawn(arena, &.{ licon, .{ "npc", .{ -50, -50, 100 + m, 150 } } }), &.{try above(arena, m, limit)});
    }
    for ([_]i64{ 195, 196 }) |k| {
        try cs.add(try std.fmt.allocPrint(arena, "corner/{d}", .{k}), try drawn(arena, &.{ licon, .{ "npc", .{ -50, -50, 150, 150 } }, .{ "npc", .{ 100, 100, k, k } } }), &.{try above(arena, k - 100, limit)});
    }
    for ([_][2]i64{ .{ 190, 95 }, .{ 191, 96 }, .{ 192, 96 } }) |gr| {
        const g = gr[0];
        try cs.add(try std.fmt.allocPrint(arena, "two_licons/{d}", .{g}), try drawn(arena, &.{ licon, .{ "licon", .{ 100 + g, 0, 200 + g, 100 } }, .{ "npc", .{ -50, -50, 250 + g, 150 } } }), &.{try above(arena, gr[1], limit)});
    }
    try cs.add("holding_nothing", try drawn(arena, &.{ licon, .{ "npc", .{ -50, -50, 150, 150 } }, .{ "npc", .{ 1000, 1000, 2000, 2000 } } }), &.{&.{}});
    try cs.add("straddled", try drawn(arena, &.{ licon, .{ "npc", .{ 50, -500, 1000, 500 } } }), &.{&.{}});
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// A `<=` rule's verdict: a finding measuring `reach` past `limit`.
fn above(arena: Allocator, reach: i64, limit: i64) ![]const Finding {
    return if (reach > limit) c.lengths(arena, &.{reach}) else &.{};
}

test "every edge-qualified enclosure fixture holds" {
    // Oracle: drawn margins, gaps and reaches (the doc comments above), under
    // every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
