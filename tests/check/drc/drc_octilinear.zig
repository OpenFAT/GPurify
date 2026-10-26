//! The DRC kinds proved on 45-degree geometry (H12, DRC-038) on derived
//! layers, and on edges at any angle (DRC-116): deck text, polygons, derived
//! layers computed, the DRC rule set run. Ported from the root
//! tests/drc_octilinear.rs; the Rust file round-trips each layout through
//! GDSII first, which is ingest's to test, so here the store is drawn
//! directly and a GDSII keyhole ring is drawn as its outer and clockwise
//! hole rows (what the reader produces).
//!
//! Oracle throughout: construct-from-answer on a 1 nm grid, each measurement
//! read off the coordinates by hand, each rule passing exactly at its
//! measurement and failing one unit above it.
//!
//! Already ported in octilinear.zig (identical case on a base layer):
//! `a_diamond_hole_is_measured`.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const oct = @import("octilinear.zig");
const Measurement = check.report.Measurement;
const Outcome = check.report.Outcome;
const Ring = oct.Ring;
const len = oct.len;
const area = oct.area;
const expectFindings = oct.expectFindings;

/// A quadrilateral whose top edge runs from (25, 5) to (0, 0), along (5, 1).
const slanted_base = [_][2]i64{ .{ 0, -10 }, .{ 25, -5 }, .{ 25, 5 }, .{ 0, 0 } };

/// A triangle whose lowest vertex is (10, 7), `25/√26` above `slanted_base`.
const tip_above = [_][2]i64{ .{ 10, 7 }, .{ 20, 20 }, .{ 0, 20 } };

/// A rectangle along (5, 1), with a V notch cut from its top side down to
/// (10, 7) between (12, 18) and (7, 17): its narrowest width is from the V's
/// tip to the bottom side.
const notched_slab = [_][2]i64{ .{ 0, 0 }, .{ 25, 5 }, .{ 22, 20 }, .{ 12, 18 }, .{ 10, 7 }, .{ 7, 17 }, .{ -3, 15 } };

/// A host whose bottom edge runs along (5, 1) from (0, 0) to (25, 5).
const slanted_host: Ring = .{ .layer = "met2", .points = &.{ .{ 0, 0 }, .{ 25, 5 }, .{ 25, 30 }, .{ 0, 30 } } };

const met2_bar: Ring = .{ .layer = "met2", .points = &.{ .{ 500, 0 }, .{ 550, 0 }, .{ 550, 1000 }, .{ 500, 1000 } } };

// ---- private ----

fn empty(found: *oct.Found, rule: []const u8) !void {
    try testing.expectEqual(@as(usize, 0), (try found.of(rule)).len);
}

test "a 45 degree shape scopes its refusal to the rules that read it" {
    // N-f2-3: a 45-degree shape feeding derived layers no longer refuses the
    // whole layout. Two derived layers are computed from a right triangle on
    // met1 (`sized`, `with_width`): `width` and `forbidden` on them run, a
    // kind not yet proved on 45-degree edges (maximum width) refuses alone,
    // and a rule on met2 reports as it would without the triangle.
    // Oracle: hand-derived. The triangle grown by the 10 square has no acute
    // corner (its tips gain a vertical or horizontal side), and every width
    // is over 5; the triangle's acute tips make its width 0, so `with_width(<
    // 1nm)` holds it, area `100·100/2 = 5000`; the met2 bar is 50 wide
    // against 100.
    var found = try oct.runOn("layer fat = met1.sized(10nm)\nlayer slim = met1.with_width(< 1nm)\nrule wf width(fat) >= 5nm\nrule mf width(fat) <= 1000nm\nrule fs forbidden(slim)\nrule w2 width(met2) >= 100nm", &.{
        .{ .layer = "met1", .points = &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 0, 100 } } },
        met2_bar,
    });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("wf"));
    try empty(&found, "wf");
    try testing.expectEqual(Outcome.refused, found.outcome("mf"));
    try expectFindings(&.{.{ area(5000), area(0) }}, try found.of("fs"));
    try testing.expectEqual(Outcome.ran, found.outcome("w2"));
    try expectFindings(&.{.{ len(50), len(100) }}, try found.of("w2"));
}

test "an uncomputable derived layer refuses only its rules" {
    // N-H12-1: a derived layer that cannot be computed refuses only the rules
    // that read it. `with_rect` reads a layer as rectangles, so a triangle
    // with an edge of slope 1/2 on met1 makes `met1.with_rect(10nm x 10nm)`
    // and everything built on it uncomputable; the rule on that layer
    // records `Refused`, a rule on met2 reports as usual, and the load does
    // not fail.
    // Oracle: the scope the H12 brief states (refusal limited to the rules
    // that read the layer) and a hand-derived width: the met2 bar is 50 wide.
    var found = try oct.runOn("layer fat = met1.with_rect(10nm x 10nm)\nlayer fatter = fat.sized(10nm)\nrule wf width(fatter) >= 5nm\nrule ef length(fat.edges()) >= 5nm\nrule w2 width(met2) >= 100nm", &.{
        .{ .layer = "met1", .points = &.{ .{ 0, 0 }, .{ 200, 0 }, .{ 0, 100 } } },
        met2_bar,
    });
    defer found.deinit();
    try testing.expectEqual(Outcome.refused, found.outcome("wf"));
    try testing.expectEqual(Outcome.refused, found.outcome("ef"));
    try testing.expectEqual(Outcome.ran, found.outcome("w2"));
    try expectFindings(&.{.{ len(50), len(100) }}, try found.of("w2"));
}

test "a strict width bound is exact on a half unit square" {
    // N-H12-2: a strict `with_width` bound is exact on a 45-degree width
    // whose square is a half unit. The bar between `y = x` and `y = x + 99`
    // is `99/√2 ≈ 70.004` wide (squared 4900.5): `> 70nm` holds it and `<=
    // 70nm` does not. Stored as `>= 70² + 1` it would be missed.
    // Oracle: hand-derived, `99² = 9801 = 2·4900 + 1`.
    const p = oct.padded(0, 99);
    var found = try oct.run("rule over forbidden(met1.with_width(> 70nm))\nrule under forbidden(met1.with_width(<= 70nm))", &.{ &p[0], &p[1], &p[2] });
    defer found.deinit();
    try testing.expectEqual(@as(usize, 1), (try found.of("over")).len);
    try empty(&found, "under");
    try testing.expectEqual(Outcome.ran, found.outcome("under"));
}

// ---- Any angle (DRC-116) ----
//
// The point-to-line case a rounding-up implementation misses: the point
// (10, 7) lies `cross((5, 1), (10, 7)) / √26 = 25/√26` from the line through
// the origin along (5, 1), squared `625/26 ≈ 24.04`, so 4.90. A square
// rounded up to 25 reads 5 and passes a limit of 5.

test "space and width at any angle compare their fractions exactly" {
    // DRC-116: space and width at any angle are exact fractions.
    // Oracle: hand-derived (the section note): the tip (10, 7) is `√(625/26)
    // ≈ 4.90` from the edge along (5, 1), the nearest the two shapes come
    // (the base's corner (25, 5) is `215/√269 ≈ 13.1` from the triangle), so
    // `space >= 5nm` flags it at 4 and `>= 4nm` passes; across two layers the
    // same. In `notched_slab` every corner is at least 90 degrees and every
    // other edge pair is farther, so `width >= 5nm` flags it at 4 and `>=
    // 4nm` passes.
    var found = try oct.run("rule s5 space(met1) >= 5nm\nrule s4 space(met1) >= 4nm", &.{ &slanted_base, &tip_above });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("s5"));
    try expectFindings(&.{.{ len(4), len(5) }}, try found.of("s5"));
    try empty(&found, "s4");
    var cross = try oct.runOn("rule d5 space(met1, met2) >= 5nm\nrule d4 space(met1, met2) >= 4nm", &.{ .{ .layer = "met1", .points = &slanted_base }, .{ .layer = "met2", .points = &tip_above } });
    defer cross.deinit();
    try expectFindings(&.{.{ len(4), len(5) }}, try cross.of("d5"));
    try empty(&cross, "d4");
    var w = try oct.run("rule w5 width(met1) >= 5nm\nrule w4 width(met1) >= 4nm", &.{&notched_slab});
    defer w.deinit();
    try testing.expectEqual(Outcome.ran, w.outcome("w5"));
    try expectFindings(&.{.{ len(4), len(5) }}, try w.of("w5"));
    try empty(&w, "w4");
}

test "areas and edge lengths at any angle are exact" {
    // DRC-116: area, hole area and edge length at any angle.
    // Oracle: hand-derived. The triangle (0,0),(3,1),(1,2) has area `|3·2 −
    // 1·1|/2 = 2.5`: `area >= 3nm2` flags it at 2 (floored), `>= 2nm2`
    // passes. A triangle of the same area as a hole in a 40-square (one
    // keyhole ring): `hole_area >= 3nm2` flags it at 2. The triangle
    // (0,0),(4,1),(1,3) has edges `√17 ≈ 4.12`, `√13 ≈ 3.61` and `√10 ≈
    // 3.16`: `edge_length >= 4nm` flags two at 3, `>= 5nm` all three, at 4,
    // 3, 3.
    var a = try oct.run("rule a3 area(met1) >= 3nm2\nrule a2 area(met1) >= 2nm2", &.{&.{ .{ 0, 0 }, .{ 3, 1 }, .{ 1, 2 } }});
    defer a.deinit();
    try expectFindings(&.{.{ area(2), area(3) }}, try a.of("a3"));
    try empty(&a, "a2");
    // The keyhole as its outer and its clockwise hole row.
    var h = try oct.run("rule h3 hole_area(met1) >= 3nm2\nrule h2 hole_area(met1) >= 2nm2", &.{ &.{ .{ 0, 0 }, .{ 40, 0 }, .{ 40, 40 }, .{ 0, 40 } }, &.{ .{ 20, 20 }, .{ 21, 22 }, .{ 23, 21 } } });
    defer h.deinit();
    try expectFindings(&.{.{ area(2), area(3) }}, try h.of("h3"));
    try empty(&h, "h2");
    var e = try oct.run("rule e4 edge_length(met1) >= 4nm\nrule e5 edge_length(met1) >= 5nm", &.{&.{ .{ 0, 0 }, .{ 4, 1 }, .{ 1, 3 } }});
    defer e.deinit();
    try expectFindings(&.{ .{ len(3), len(4) }, .{ len(3), len(4) } }, try e.of("e4"));
    const e5 = try e.run.arena.allocator().dupe([2]Measurement, try e.of("e5"));
    std.mem.sort([2]Measurement, e5, {}, struct {
        fn less(_: void, p: [2]Measurement, q: [2]Measurement) bool {
            return p[0].raw < q[0].raw;
        }
    }.less);
    try expectFindings(&.{ .{ len(3), len(5) }, .{ len(3), len(5) }, .{ len(4), len(5) } }, e5);
}

test "enclosure at any angle is exact" {
    // DRC-116: enclosure at any angle, every side and non-coincident.
    // Oracle: hand-derived. The square (5..10, 7..12) in `slanted_host` has
    // its corner (10, 7) `25/√26 ≈ 4.90` from the slanted bottom (its corner
    // (5, 7) is `30/√26` from it, its left side 5 from the host's, its right
    // side 15, its top 18): `enclosure >= 5nm` flags it at 4, `>= 4nm`
    // passes, and so does the non-coincident reading, the square's bottom
    // pairing with the slanted bottom. Opposite measures by projection and
    // refuses an edge at such an angle.
    const square: Ring = .{ .layer = "met1", .points = &.{ .{ 5, 7 }, .{ 10, 7 }, .{ 10, 12 }, .{ 5, 12 } } };
    const rules = "rule e5 enclosure(met1, met2) >= 5nm\nrule e4 enclosure(met1, met2) >= 4nm\nrule n5 enclosure(met1, met2, noncoincident) >= 5nm\nrule o5 enclosure(met1, met2, opposite) >= 5nm";
    const layout = [_]Ring{ slanted_host, square };
    var found = try oct.runOn(rules, &layout);
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("e5"));
    try expectFindings(&.{.{ len(4), len(5) }}, try found.of("e5"));
    try empty(&found, "e4");
    try expectFindings(&.{.{ len(4), len(5) }}, try found.of("n5"));
    try testing.expectEqual(Outcome.refused, found.outcome("o5"));
    try oct.holdsUnderSymmetries(rules, &layout);
}

test "the any angle kinds are invariant under the symmetries of the grid" {
    // DRC-116: every kind measured at any angle gives the same findings under
    // the eight symmetries of the grid.
    // Oracle: metamorphic, the symmetry law: a mirror or a quarter turn about
    // the origin maps the grid onto itself and keeps every distance and area,
    // and rounding a half away from zero commutes with it.
    var shifted: [notched_slab.len][2]i64 = undefined;
    for (&shifted, notched_slab) |*s, p| s.* = .{ p[0] + 100, p[1] };
    const rules = "rule s5 space(met1) >= 5nm\nrule w5 width(met1) >= 5nm\nrule n5 notch(met1) >= 50nm\nrule a3 area(met1) >= 3nm2\nrule e4 edge_length(met1) >= 4nm\nrule i inside(met1, met2)\nrule c contains(met2, met1) >= 2";
    try oct.holdsUnderSymmetries(rules, &.{
        .{ .layer = "met1", .points = &slanted_base },
        .{ .layer = "met1", .points = &tip_above },
        .{ .layer = "met1", .points = &shifted },
        .{ .layer = "met1", .points = &.{ .{ 200, 0 }, .{ 203, 1 }, .{ 201, 2 } } },
        .{ .layer = "met1", .points = &.{ .{ 300, 0 }, .{ 304, 1 }, .{ 301, 3 } } },
        .{ .layer = "met2", .points = &.{ .{ 395, -5 }, .{ 420, 0 }, .{ 420, 30 }, .{ 395, 30 } } },
        .{ .layer = "met1", .points = &.{ .{ 400, 7 }, .{ 405, 7 }, .{ 405, 12 }, .{ 400, 12 } } },
    });
}

test "a pythagorean turn scales every measure by five" {
    // DRC-116: the Pythagorean rotation law, end to end. `(x, y) → (3x − 4y,
    // 4x + 3y)` maps the grid into itself and every length times 5, so the U
    // (width 50, notch 100, area 45000, three 100-long edges) turned so has
    // width 250, notch 500, area `25·45000` and three 500-long edges, every
    // edge now along (3, 4) or (−4, 3).
    // Oracle: construct-from-answer by the rotation law; each rule flags at
    // the turned value one unit above it and passes at it.
    const u = [8][2]i64{ .{ 0, 0 }, .{ 300, 0 }, .{ 300, 200 }, .{ 200, 200 }, .{ 200, 50 }, .{ 100, 50 }, .{ 100, 200 }, .{ 0, 200 } };
    var turned: [8][2]i64 = undefined;
    for (&turned, u) |*t, p| t.* = .{ 3 * p[0] - 4 * p[1], 4 * p[0] + 3 * p[1] };
    var found = try oct.run("rule w251 width(met1) >= 251nm\nrule w250 width(met1) >= 250nm\nrule n501 notch(met1) >= 501nm\nrule n500 notch(met1) >= 500nm\nrule e501 edge_length(met1) >= 501nm\nrule e500 edge_length(met1) >= 500nm\nrule a area(met1) >= 1125001nm2", &.{&turned});
    defer found.deinit();
    try expectFindings(&.{.{ len(250), len(251) }}, try found.of("w251"));
    try empty(&found, "w250");
    try expectFindings(&.{.{ len(500), len(501) }}, try found.of("n501"));
    try empty(&found, "n500");
    const e = [2]Measurement{ len(500), len(501) };
    try expectFindings(&.{ e, e, e }, try found.of("e501"));
    try empty(&found, "e500");
    try expectFindings(&.{.{ area(1_125_000), area(1_125_001) }}, try found.of("a"));
}

test "derived layers compute at any angle" {
    // DRC-116: derived layers compute at any angle. `sized` grows a slanted
    // triangle by the box, and a boolean of two slanted shapes rounds its
    // crossings to the grid; rules on both run.
    // Oracle: hand-derived. The triangle (0,0),(30,10),(0,20) grown by the
    // 10-square is convex with no corner under 90 degrees and at least 20
    // across, so `width >= 5nm` passes; the triangle with its tip at (110, 0)
    // pokes below the slanted top of the quadrilateral (at x = 110 that top
    // is at y = 2), so `met1 and met2` holds one figure, which `forbidden`
    // reports.
    var found = try oct.runOn("layer fat = met1.sized(10nm)\nlayer both = met1 and met2\nrule wf width(fat) >= 5nm\nrule fb forbidden(both)", &.{
        .{ .layer = "met1", .points = &.{ .{ 0, 0 }, .{ 30, 10 }, .{ 0, 20 } } },
        .{ .layer = "met1", .points = &.{ .{ 100, -10 }, .{ 125, -5 }, .{ 125, 5 }, .{ 100, 0 } } },
        .{ .layer = "met2", .points = &.{ .{ 110, 0 }, .{ 120, 17 }, .{ 100, 17 } } },
    });
    defer found.deinit();
    try testing.expectEqual(Outcome.ran, found.outcome("wf"));
    try empty(&found, "wf");
    try testing.expectEqual(Outcome.ran, found.outcome("fb"));
    try testing.expectEqual(@as(usize, 1), (try found.of("fb")).len);
}
