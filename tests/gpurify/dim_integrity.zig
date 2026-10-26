//! Layer validity (DRC-004, DRC-002, DRC-038), floating labels, pin
//! centres and pins (DRC-007) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`validity`, `floating_labels`,
//! `pins`).
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
    try validityInto(arena, out);
    try floatingLabelsInto(arena, depth, out);
    try pinsInto(arena, out);
}

// ---- private ----

/// A met1 square at `[5000, 6000]²` and `points` on met1.
fn withSquare(arena: Allocator, points: []const [2]i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 5000, 5000, 6000, 6000);
    try l.polygon(arena, "met1", points);
    return l;
}

/// `w` and `f` refused, `g` clean, `an` finding `angles`, and the run
/// failing.
fn refused(arena: Allocator, deck: []const u8, name: []const u8, catalog: []const []const u8, points: []const [2]i64, angles: []const Finding) !Fixture {
    var f: Fixture = .init(try std.fmt.allocPrint(arena, "validity/{s}", .{name}), catalog, deck, harness.drc);
    f.layout = try withSquare(arena, points);
    try f.claim(arena, .outcome("w", .refused));
    try f.claim(arena, .outcome("f", .refused));
    try f.claim(arena, .clean("g"));
    try f.claim(arena, .rule("an", angles));
    try f.claim(arena, .{ .passes = false });
    return f;
}

/// Layer validity (DRC-004, DRC-002): a rule that reads a layer holding a
/// self-crossing or zero-area ring records `Refused`, and the run does not
/// pass. A 45-degree ring is valid: `width` measures it (DRC-038, H12) and
/// `forbidden` reports it with its area. `off_grid` and `angle` read raw
/// rows and never refuse: they run, and `angle` flags the diagonal.
fn validityInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule w width(met1) >= 100nm\nrule f forbidden(met1)\nrule g off_grid(; pitch: 1nm)\nrule an angle(met1; allowed: [0deg, 90deg])");
    var cases: std.ArrayList(Fixture) = .empty;
    try cases.append(arena, try refused(arena, deck, "self_crossing", &.{"DRC-004"}, &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, -1000 }, .{ 0, -1000 } }, &.{}));
    try cases.append(arena, try refused(arena, deck, "zero_area", &.{"DRC-004"}, &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 500, 0 } }, &.{}));
    // One acute (45-degree) tip, at (2000, 0): width 0 there; the other
    // corners are 90 and 135 degrees.
    var diagonal: Fixture = .init("validity/diagonal", &.{ "DRC-002", "DRC-038" }, deck, harness.drc);
    diagonal.layout = try withSquare(arena, &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 1000, 1000 }, .{ 0, 1000 } });
    try diagonal.claim(arena, .rule("w", &.{Finding.length(0).pinned(2000, 0)}));
    // The square 1000 x 1000, the trapezoid (2000 + 1000) / 2 x 1000.
    try diagonal.claim(arena, .rule("f", &.{ .area(1_000_000), .area(1_500_000) }));
    try diagonal.claim(arena, .clean("g"));
    try diagonal.claim(arena, .rule("an", &.{c.count(0)}));
    try diagonal.claim(arena, .{ .passes = false });
    try cases.append(arena, diagonal);
    try c.everyPlacementInto(arena, cases.items, out);
}

/// The 1000 plate every floating-label case draws on.
fn plate(arena: Allocator) !Layout {
    return c.met1(arena, &.{.{ 0, 0, 1000, 1000 }});
}

/// One floating box of area 1 at each point.
fn floating(arena: Allocator, points: []const [2]i64) ![]const Finding {
    const out = try arena.alloc(Finding, points.len);
    for (points, out) |p, *o| o.* = Finding.area(1).pinned(p[0], p[1]);
    return out;
}

/// Floating labels and pin centres (DRC-007):
/// - sky130 x.17, "All labels must be within the drawing polygons of the
///   layer": `forbidden(met1_label.texts_outside(met1))`, each text drawn
///   on the label layer on no metal, neither on its material nor on its
///   boundary, as a one-unit box at its anchor (area 1, marked at the
///   anchor);
/// - sky130 x.20, "Min spacing between pins on the same layer (center to
///   center)": `space(met1_pin, center) >= 500nm`, the value deck-supplied
///   (the public manual states none; no public deck codes it).
///
/// Oracle: the rule text, points by construction: a label inside the
/// metal, on its edge and on its corner (clean), one unit past the edge
/// (floating), inside a hole of a ringed metal (floating) and on the hole's
/// edge (on metal), two labels at one floating point (two boxes); two 100
/// pins with centres 499, 500 and 501 apart (the closer than 500 one
/// flagged).
fn floatingLabelsInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\layer met1_pin = gds(68, 16)
        \\layer met1_label = gds(68, 5)
        \\layer floating = met1_label.texts_outside(met1)
        \\rule x.17 forbidden(floating)
        \\rule x.20 space(met1_pin, center) >= 500nm
        \\
    ;
    var cases: std.ArrayList(Fixture) = .empty;
    const Point = struct { []const u8, [2]i64, bool };
    for ([_]Point{ .{ "inside", .{ 500, 500 }, false }, .{ "on_edge", .{ 1000, 500 }, false }, .{ "on_corner", .{ 1000, 1000 }, false }, .{ "past_edge", .{ 1001, 500 }, true } }) |p| {
        var layout = try plate(arena);
        try layout.label(arena, "met1_label", p[1][0], p[1][1], "A");
        const found: []const Finding = if (p[2]) try floating(arena, &.{p[1]}) else &.{};
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "floating_labels/{s}", .{p[0]}), &.{"DRC-007"}, deck, layout, &.{ .{ "x.17", found }, .{ "x.20", &.{} } }));
    }
    var ring: Layout = .{};
    try ring.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 400, 400, 600, 600 }));
    try ring.label(arena, "met1_label", 500, 500, "A");
    try ring.label(arena, "met1_label", 400, 500, "B");
    try cases.append(arena, try c.fixture(arena, "floating_labels/in_hole", &.{"DRC-007"}, deck, ring, &.{ .{ "x.17", try floating(arena, &.{.{ 500, 500 }}) }, .{ "x.20", &.{} } }));
    var two = try plate(arena);
    try two.label(arena, "met1_label", 2000, 2000, "A");
    try two.label(arena, "met1_label", 2000, 2000, "B");
    try cases.append(arena, try c.fixture(arena, "floating_labels/two_at_one_point", &.{"DRC-007"}, deck, two, &.{ .{ "x.17", try floating(arena, &.{ .{ 2000, 2000 }, .{ 2000, 2000 } }) }, .{ "x.20", &.{} } }));
    for (try c.sweep(arena, depth, 500)) |d| {
        var pins = try plate(arena);
        try c.rects(arena, &pins, "met1_pin", &.{ .{ 100, 100, 200, 200 }, .{ 100 + d, 100, 200 + d, 200 } });
        const findings: []const Finding = if (d < 500) try arena.dupe(Finding, &.{.length(d)}) else &.{};
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "pin_centres/{s}", .{try c.side(arena, d, 500)}), &.{"DRC-007"}, deck, pins, &.{ .{ "x.17", &.{} }, .{ "x.20", findings } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// A 1000 met1 plate with `pin` drawn on `met1_pin`.
fn drawn(arena: Allocator, pin: c.Rect) !Layout {
    var l = try c.met1(arena, &.{.{ 0, 0, 1000, 1000 }});
    try c.rects(arena, &l, "met1_pin", &.{pin});
    return l;
}

/// Pins and labels (DRC-007): `inside(met1_pin, met1)` reports the area of
/// a pin left outside its metal (touching the edge from inside is inside),
/// and a label over no net aborts extraction, so the run does not pass.
fn pinsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\layer met1_pin = gds(68, 16)
        \\layer met1_label = gds(68, 5)
        \\connect conductors [met1]
        \\connect touch_within_layer
        \\connect label met1_label names met1
        \\rule pin inside(met1_pin, met1)
        \\
    ;
    var inside = try drawn(arena, .{ 400, 400, 600, 600 });
    try inside.label(arena, "met1_label", 500, 500, "A");
    const cases = [_]Fixture{
        try c.fixture(arena, "pins/inside", &.{"DRC-007"}, deck, inside, &.{.{ "pin", &.{} }}),
        try c.fixture(arena, "pins/touching_from_inside", &.{"DRC-007"}, deck, try drawn(arena, .{ 800, 400, 1000, 600 }), &.{.{ "pin", &.{} }}),
        try c.fixture(arena, "pins/straddling", &.{"DRC-007"}, deck, try drawn(arena, .{ 900, 400, 1100, 600 }), &.{.{ "pin", &.{.area(20_000)} }}),
    };
    try c.everyPlacementInto(arena, &cases, out);
    var no_net: Fixture = .init("pins/label_on_no_net", &.{"DRC-007"}, deck, harness.drc);
    no_net.layout = try drawn(arena, .{ 400, 400, 600, 600 });
    try no_net.layout.label(arena, "met1_label", 5000, 5000, "A");
    try no_net.claim(arena, .{ .passes = false });
    try out.append(arena, no_net);
}

test "every validity, label and pin fixture holds" {
    // Oracle: each fixture's expected answer, derived from the rule's
    // definition and the rule text (the doc comments above): defective
    // rings drawn with their defect, label and pin points by construction,
    // under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
