//! Anisotropic sizing, covering and overlapping, shape classes, feature
//! length and room for a rectangle, as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`sized_xy`, `covering_overlapping`,
//! `shape_class`, `feature_length`, `enclose_rect`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Symmetry = harness.Symmetry;
const c = @import("drc_common.zig");
const d = @import("lay_derived.zig");
const derived = d.derived;
const boxes = d.boxes;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try sizedXyInto(arena, out);
    try c.everyPlacementInto(arena, &.{try coveringOverlapping(arena)}, out);
    try c.everyPlacementInto(arena, &.{try shapeClass(arena)}, out);
    try c.everyPlacementInto(arena, &.{try featureLength(arena)}, out);
    try c.everyPlacementInto(arena, &.{try encloseRect(arena)}, out);
}

// ---- private ----

/// `sized(dx, dy)` (DRC-121), `KLayout`'s anisotropic sizing: each shape
/// grown by `dx` left and right and `dy` above and below, or shrunk when
/// both are negative. Each result is reported with its area, worked by hand.
///
/// A 1000 x 500 box grown by (100, 50) (1200 x 600), shrunk by (100, 50)
/// (800 x 400), grown in y only (1000 x 700), and grown then shrunk back;
/// two 1000 x 500 bars 100 apart across x, which (50, 0) joins and (49, 0)
/// leaves 2 apart, while (0, 50) leaves the gap; a 1000 x 200 bar that
/// (-50, -100) shrinks away and (-50, -99) leaves 2 tall. The rule names an
/// axis, so only the symmetries that keep each axis (no quarter turn) apply.
fn sizedXyInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const cat: []const []const u8 = &.{"DRC-121"};
    const only_a: []const []const u8 = &.{"a"};
    const cases = [_]Fixture{
        try derived(arena, "derived/sized_xy/box", cat, only_a, &.{
            .{ "a.sized(100nm, 50nm)", try c.areas(arena, &.{720_000}) },
            .{ "a.sized(-100nm, -50nm)", try c.areas(arena, &.{320_000}) },
            .{ "a.sized(0nm, 100nm)", try c.areas(arena, &.{700_000}) },
            .{ "a.sized(100nm, 50nm).sized(-100nm, -50nm)", try c.areas(arena, &.{500_000}) },
        }, try boxes(arena, "a", &.{.{ 0, 0, 1000, 500 }})),
        try derived(arena, "derived/sized_xy/gap", cat, only_a, &.{
            .{ "a.sized(50nm, 0nm)", try c.areas(arena, &.{1_100_000}) },
            .{ "a.sized(49nm, 0nm)", try c.areas(arena, &.{ 549_000, 549_000 }) },
            .{ "a.sized(0nm, 50nm)", try c.areas(arena, &.{ 600_000, 600_000 }) },
        }, try boxes(arena, "a", &.{ .{ 0, 0, 1000, 500 }, .{ 1100, 0, 2100, 500 } })),
        try derived(arena, "derived/sized_xy/vanish", cat, only_a, &.{
            .{ "a.sized(-50nm, -100nm)", &.{} },
            .{ "a.sized(-50nm, -99nm)", try c.areas(arena, &.{1800}) },
        }, try boxes(arena, "a", &.{.{ 0, 0, 1000, 200 }})),
    };
    for (&cases) |*f| for (Symmetry.all) |s| {
        if (s.turns % 2 != 0) continue;
        for (c.offsets) |o| try out.append(arena, try f.transformed(arena, s, o[0], o[1]));
    };
}

/// `covering`, `not_covering`, `overlapping` and `not_overlapping`
/// (DRC-121), `KLayout`'s operations of those names: an `a` shape covers
/// when it holds a whole `b` shape (touching its boundary from inside
/// allowed), and overlaps when it shares area with one (touching is not).
/// Each selected `a` shape is reported with its area, which names it.
///
/// `a` shapes: holding a `b` (1000000); with a `b` across its edge
/// (900000); touched by a `b` from outside (800000); with a `b` touching its
/// edge from inside (700000); holding a `b` drawn as two abutting halves
/// (600000); drawn as two abutting halves holding a `b` across the seam
/// (500000); a ring with a `b` island in its hole (840000); alone (400000);
/// and inside a larger `b` (90000).
fn coveringOverlapping(arena: Allocator) !Fixture {
    var layout = try boxes(arena, "a", &.{ .{ 0, 0, 1000, 1000 }, .{ 2000, 0, 2900, 1000 }, .{ 4000, 0, 4800, 1000 }, .{ 6000, 0, 6700, 1000 }, .{ 8000, 0, 8600, 1000 }, .{ 10_000, 0, 10_250, 1000 }, .{ 10_250, 0, 10_500, 1000 }, .{ 14_000, 0, 14_400, 1000 }, .{ 16_200, 200, 16_500, 500 } });
    try c.rects(arena, &layout, "b", &.{ .{ 200, 200, 400, 400 }, .{ 2800, 400, 3000, 600 }, .{ 4800, 400, 5000, 600 }, .{ 6000, 400, 6200, 600 }, .{ 8100, 100, 8200, 300 }, .{ 8200, 100, 8300, 300 }, .{ 10_200, 400, 10_300, 600 }, .{ 12_400, 400, 12_600, 600 }, .{ 16_000, 0, 17_000, 1000 } });
    try c.ring(arena, &layout, "a", .{ 12_000, 0, 13_000, 1000 }, .{ 12_300, 300, 12_700, 700 });
    return derived(arena, "derived/covering_overlapping", &.{"DRC-121"}, &.{ "a", "b" }, &.{
        .{ "a.covering(b)", try c.areas(arena, &.{ 1_000_000, 700_000, 600_000, 500_000 }) },
        .{ "a.not_covering(b)", try c.areas(arena, &.{ 900_000, 800_000, 840_000, 400_000, 90_000 }) },
        .{ "a.overlapping(b)", try c.areas(arena, &.{ 1_000_000, 900_000, 700_000, 600_000, 500_000, 90_000 }) },
        .{ "a.not_overlapping(b)", try c.areas(arena, &.{ 800_000, 840_000, 400_000 }) },
    }, layout);
}

/// Rectangle-only and square-only shapes (DRC-005: sky130 capm.7 "only
/// rectangular capacitors", LEF58 `RECTONLY`), as
/// `forbidden(L.non_rectangles())` and the other three selections, each
/// shape reported with its area.
///
/// Oracle: hand-derived areas of shapes whose class is fixed by
/// construction, read merged as `KLayout`'s `rectangles` and `squares` read
/// them. A square and a 100 x 200 bar; a square drawn as two abutting
/// halves, which only the merged layer sees as one square; a bar drawn
/// twice, and as two overlapping boxes (one box each); an L; two squares
/// meeting only at a corner (one shape under the corner model, no
/// rectangle); and a square ring, whose box is square but whose hole makes
/// it none. A check that reads drawn rows calls the halves two non-squares;
/// one blind to holes calls the ring a square.
fn shapeClass(arena: Allocator) !Fixture {
    var layout = try boxes(arena, "a", &.{ .{ 0, 0, 100, 100 }, .{ 300, 0, 400, 200 }, .{ 600, 0, 650, 100 }, .{ 650, 0, 700, 100 }, .{ 500, 500, 600, 600 }, .{ 600, 600, 700, 700 }, .{ 1500, 0, 1700, 100 }, .{ 1550, 0, 1650, 100 }, .{ 2000, 0, 2100, 100 }, .{ 2050, 0, 2150, 100 } });
    try layout.polygon(arena, "a", &.{ .{ 0, 500 }, .{ 300, 500 }, .{ 300, 600 }, .{ 100, 600 }, .{ 100, 800 }, .{ 0, 800 } });
    try c.ring(arena, &layout, "a", .{ 1000, 0, 1300, 300 }, .{ 1100, 100, 1200, 200 });
    return derived(arena, "derived/shape_class", &.{"DRC-005"}, &.{"a"}, &.{
        .{ "a.rectangles()", try c.areas(arena, &.{ 10_000, 20_000, 10_000, 20_000, 15_000 }) },
        .{ "a.non_rectangles()", try c.areas(arena, &.{ 50_000, 20_000, 80_000 }) },
        .{ "a.squares()", try c.areas(arena, &.{ 10_000, 10_000 }) },
        .{ "a.non_squares()", try c.areas(arena, &.{ 20_000, 20_000, 15_000, 50_000, 20_000, 80_000 }) },
    }, layout);
}

/// A feature's length, the longer side of its bounding box (DRC-021: sky130
/// mf.2 "length of fuse", IHP Rsil.f "min. RES length"), and its shorter
/// side: `with_bbox_max` and `with_bbox_min`, each shape reported with its
/// area.
///
/// Oracle: boxes fixed by construction: bars 499, 500 and 501 long against
/// bounds at 500 (strict and `==`); a 500 bar drawn as two abutting halves
/// (250 each unmerged); an L of two 100-wide arms in a 500 square box (its
/// arms are not its box); a 50 x 500 bar under `with_bbox_min(< 100nm)`.
fn featureLength(arena: Allocator) !Fixture {
    const layout = try boxes(arena, "a", &.{ .{ 0, 0, 100, 499 }, .{ 300, 0, 400, 500 }, .{ 600, 0, 700, 501 }, .{ 900, 0, 1000, 250 }, .{ 900, 250, 1000, 500 }, .{ 1200, 0, 1700, 100 }, .{ 1200, 100, 1300, 500 }, .{ 2000, 0, 2050, 500 } });
    return derived(arena, "derived/feature_length", &.{"DRC-021"}, &.{"a"}, &.{
        .{ "a.with_bbox_max(< 500nm)", try c.areas(arena, &.{49_900}) },
        .{ "a.with_bbox_max(> 500nm)", try c.areas(arena, &.{50_100}) },
        .{ "a.with_bbox_max(== 500nm)", try c.areas(arena, &.{ 50_000, 50_000, 90_000, 25_000 }) },
        .{ "a.with_bbox_min(< 100nm)", try c.areas(arena, &.{25_000}) },
    }, layout);
}

/// Room for a rectangle (DRC-130, Calibre `ENCLOSE RECTANGLE`):
/// `with_rect(300nm x 100nm)`, `without_rect(300nm x 100nm)` and
/// `without_rect(100nm x 100nm)`, each shape reported with its area.
///
/// Oracle: boxes fixed by construction, the box's sides swept a grid step:
/// a 300 x 100 bar (holds it, at the limit), 299 x 100 and 300 x 99 (do
/// not), a 100 x 300 bar (holds it turned); an L of 50-wide arms in a 300
/// square box (a bounding-box reading says it holds); the bar drawn as two
/// abutting 150 halves (holds, merged); a 400 square ring with 100 walls
/// (its band holds); two 200 x 60 bars overlapping in a stagger whose box
/// is 300 x 100 (holds no 300 x 100 box, but a 100 square across the
/// overlap).
fn encloseRect(arena: Allocator) !Fixture {
    var layout = try boxes(arena, "a", &.{ .{ 0, 0, 300, 100 }, .{ 1000, 0, 1299, 100 }, .{ 2000, 0, 2300, 99 }, .{ 3000, 0, 3100, 300 }, .{ 4000, 0, 4300, 50 }, .{ 4000, 50, 4050, 300 }, .{ 5000, 0, 5150, 100 }, .{ 5150, 0, 5300, 100 }, .{ 7000, 0, 7200, 60 }, .{ 7100, 40, 7300, 100 } });
    try c.ring(arena, &layout, "a", .{ 6000, 0, 6400, 400 }, .{ 6100, 100, 6300, 300 });
    return derived(arena, "derived/enclose_rect", &.{"DRC-130"}, &.{"a"}, &.{
        .{ "a.with_rect(300nm x 100nm)", try c.areas(arena, &.{ 30_000, 30_000, 30_000, 120_000 }) },
        .{ "a.without_rect(300nm x 100nm)", try c.areas(arena, &.{ 29_900, 29_700, 27_500, 22_000 }) },
        .{ "a.without_rect(100nm x 100nm)", try c.areas(arena, &.{ 29_700, 27_500 }) },
    }, layout);
}

test "every sizing, covering and class fixture holds" {
    // Oracle: hand-derived areas of each selected or sized shape (the doc
    // comments above), under the symmetries each rule keeps at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
