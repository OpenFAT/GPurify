//! The derived-layer selections (`interacting`, `inside`, `outside`,
//! `holes`, `extents`, `with_area`, `with_width`, `with_text`) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_overlay.rs (`selections`).
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
const d = @import("lay_derived.zig");
const derived = d.derived;
const boxes = d.boxes;

const cat: []const []const u8 = &.{ "DRC-120", "DRC-121" };

const ab: []const []const u8 = &.{ "a", "b" };

const only_a: []const []const u8 = &.{"a"};

/// The selections (DRC-120, DRC-121): `interacting` and `not_interacting`
/// (corner-only contact counts, 1 nm apart does not, an `a` shape far from
/// `b` is selected through a shape it abuts, and a ring interacts with an
/// island of `b` in its hole only when they touch), and the straddle
/// `interacting not inside not outside`; `inside` and `outside` against a
/// `b` drawn as two halves (touching the boundary from inside is inside,
/// from outside is outside, straddling is neither) and against a `b` ring
/// (a shape in its hole is outside); `holes` (one, one with an island, two,
/// and a U with none); `extents` (an L, two touching shapes, two apart, a
/// ring, and two interlocking Ls whose boxes overlap, F54); `with_area` and
/// `with_width` across their bounds, holes excluded and touching pieces
/// merged, and a corner neck `width` measures Euclidean (F55); and
/// `with_text` / `without_text` with `*`, `?`, case, a text on the edge, one
/// off the shape and one in a ring's hole.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    var cases: std.ArrayList(Fixture) = .empty;
    try interactionsInto(arena, &cases);
    try shapesInto(arena, &cases);
    try measuresInto(arena, &cases);
    try c.everyPlacementInto(arena, cases.items, out);
}

// ---- private ----

/// `interacting`, `inside` and `outside`, against shapes, halves and rings.
fn interactionsInto(arena: Allocator, cases: *std.ArrayList(Fixture)) !void {
    var contact = try boxes(arena, "b", &.{.{ 0, 0, 1000, 1000 }});
    try c.rects(arena, &contact, "a", &.{ .{ 900, 100, 1200, 200 }, .{ 1200, 100, 1500, 200 }, .{ 1000, 300, 1300, 400 }, .{ 1000, 1000, 1100, 1100 }, .{ -101, 500, -1, 600 }, .{ -500, -500, -400, -400 } });
    try cases.append(arena, try derived(arena, "derived/interacting", cat, ab, &.{
        .{ "a.interacting(b)", try c.areas(arena, &.{ 60_000, 30_000, 10_000 }) },
        .{ "a.not_interacting(b)", try c.areas(arena, &.{ 10_000, 10_000 }) },
        .{ "a.interacting(b) not a.inside(b) not a.outside(b)", try c.areas(arena, &.{60_000}) },
    }, contact));
    var ringed = try boxes(arena, "a", &.{ .{ 100, 100, 200, 200 }, .{ 400, 450, 600, 550 }, .{ 250, 450, 350, 550 } });
    try c.ring(arena, &ringed, "b", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
    try cases.append(arena, try derived(arena, "derived/inside_outside_ring", cat, ab, &.{
        .{ "a.inside(b)", try c.areas(arena, &.{10_000}) },
        .{ "a.outside(b)", try c.areas(arena, &.{20_000}) },
    }, ringed));
    // A ring and an island of `b` in its hole: apart they do not interact,
    // touching the hole's edge they do.
    for ([_]struct { []const u8, c.Rect, []const i128, []const i128 }{
        .{ "island_apart", .{ 400, 400, 600, 600 }, &.{}, &.{840_000} },
        .{ "island_touching", .{ 300, 400, 400, 600 }, &.{840_000}, &.{} },
    }) |k| {
        var l = try boxes(arena, "b", &.{k[1]});
        try c.ring(arena, &l, "a", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/interacting_ring/{s}", .{k[0]}), cat, ab, &.{
            .{ "a.interacting(b)", try c.areas(arena, k[2]) },
            .{ "a.not_interacting(b)", try c.areas(arena, k[3]) },
        }, l));
    }
    var placed = try boxes(arena, "b", &.{ .{ 0, 0, 500, 1000 }, .{ 500, 0, 1000, 1000 } });
    try c.rects(arena, &placed, "a", &.{ .{ 100, 100, 200, 200 }, .{ 0, 400, 200, 500 }, .{ 400, 700, 700, 800 }, .{ 900, 100, 1100, 300 }, .{ 1000, 400, 1500, 500 }, .{ 1500, 0, 1800, 200 } });
    try cases.append(arena, try derived(arena, "derived/inside_outside", cat, ab, &.{
        .{ "a.inside(b)", try c.areas(arena, &.{ 10_000, 20_000, 30_000 }) },
        .{ "a.outside(b)", try c.areas(arena, &.{ 50_000, 60_000 }) },
    }, placed));
}

/// `holes` and `extents`.
fn shapesInto(arena: Allocator, cases: *std.ArrayList(Fixture)) !void {
    var ring_a: Layout = .{};
    try c.ring(arena, &ring_a, "a", .{ 0, 0, 1000, 1000 }, .{ 400, 300, 600, 700 });
    var ring_island: Layout = .{};
    try c.ring(arena, &ring_island, "a", .{ 0, 0, 1000, 1000 }, .{ 400, 300, 600, 700 });
    try ring_island.rect(arena, "a", 450, 450, 550, 550);
    const holes = [_]struct { []const u8, Layout, []const i128 }{
        .{ "ring", ring_a, &.{80_000} },
        .{ "ring_with_island", ring_island, &.{80_000} },
        .{ "two_holes", try boxes(arena, "a", &.{ .{ 0, 0, 1000, 100 }, .{ 0, 900, 1000, 1000 }, .{ 0, 100, 100, 900 }, .{ 900, 100, 1000, 900 }, .{ 450, 100, 550, 900 } }), &.{ 280_000, 280_000 } },
        .{ "u_shape", try boxes(arena, "a", &.{ .{ 0, 0, 1000, 100 }, .{ 0, 100, 100, 1000 }, .{ 900, 100, 1000, 1000 } }), &.{} },
    };
    for (holes) |k| try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/holes/{s}", .{k[0]}), cat, only_a, &.{.{ "a.holes()", try c.areas(arena, k[2]) }}, k[1]));

    var l_shape: Layout = .{};
    try l_shape.polygon(arena, "a", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 200 }, .{ 200, 200 }, .{ 200, 1000 }, .{ 0, 1000 } });
    var ring: Layout = .{};
    try c.ring(arena, &ring, "a", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
    var interlocking: Layout = .{};
    try interlocking.polygon(arena, "a", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 100, 100 }, .{ 100, 1000 }, .{ 0, 1000 } });
    try interlocking.polygon(arena, "a", &.{ .{ 1100, 200 }, .{ 1200, 200 }, .{ 1200, 1200 }, .{ 200, 1200 }, .{ 200, 1100 }, .{ 1100, 1100 } });
    const extents = [_]struct { []const u8, Layout, []const i128 }{
        .{ "l_shape", l_shape, &.{1_000_000} },
        .{ "touching", try boxes(arena, "a", &.{ .{ 0, 0, 500, 200 }, .{ 500, 0, 1000, 400 } }), &.{400_000} },
        .{ "apart", try boxes(arena, "a", &.{ .{ 0, 0, 500, 200 }, .{ 600, 0, 1000, 400 } }), &.{ 100_000, 160_000 } },
        .{ "ring", ring, &.{1_000_000} },
        .{ "interlocking", interlocking, &.{ 1_000_000, 1_000_000 } },
    };
    for (extents) |k| try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/extents/{s}", .{k[0]}), cat, only_a, &.{.{ "a.extents()", try c.areas(arena, k[2]) }}, k[1]));
}

/// `with_area`, `with_width` (and its Euclidean necks) and `with_text`.
fn measuresInto(arena: Allocator, cases: *std.ArrayList(Fixture)) !void {
    var sized = try boxes(arena, "a", &.{ .{ 0, 0, 100, 99 }, .{ 200, 0, 300, 100 }, .{ 400, 0, 500, 101 }, .{ 600, 0, 650, 100 }, .{ 650, 0, 700, 100 } });
    try c.ring(arena, &sized, "a", .{ 0, 1000, 200, 1200 }, .{ 50, 1050, 150, 1150 });
    try cases.append(arena, try derived(arena, "derived/with_area", cat, only_a, &.{
        .{ "a.with_area(>= 10000nm2)", try c.areas(arena, &.{ 10_000, 10_100, 10_000, 30_000 }) },
        .{ "a.with_area(== 30000nm2)", try c.areas(arena, &.{30_000}) },
        .{ "a.with_area(> 9999nm2, < 10001nm2)", try c.areas(arena, &.{ 10_000, 10_000 }) },
    }, sized));

    var bars: Layout = .{};
    try bars.polygon(arena, "a", &.{ .{ 0, 2000 }, .{ 1000, 2000 }, .{ 1000, 2500 }, .{ 99, 2500 }, .{ 99, 3500 }, .{ 0, 3500 } });
    try c.rects(arena, &bars, "a", &.{ .{ 0, 0, 99, 1000 }, .{ 200, 0, 300, 1000 }, .{ 400, 0, 501, 1000 }, .{ 600, 0, 650, 1000 }, .{ 650, 0, 700, 1000 } });
    try cases.append(arena, try derived(arena, "derived/with_width", cat, only_a, &.{
        .{ "a.with_width(< 100nm)", try c.areas(arena, &.{ 99_000, 599_000 }) },
        .{ "a.with_width(>= 100nm)", try c.areas(arena, &.{ 100_000, 101_000, 100_000 }) },
    }, bars));
    // Two plates overlapping 50 x 50 at a corner: the Euclidean neck between
    // their concave corners is sqrt(5000), 70.7 nm, which `width` measures.
    // It is more than 70 nm and less than 71 (F65: not floored to 70).
    const plates = try boxes(arena, "a", &.{ .{ 0, 0, 1000, 1000 }, .{ 950, 950, 1950, 1950 } });
    try cases.append(arena, try derived(arena, "derived/with_width_neck", cat, only_a, &.{
        .{ "a.with_width(< 100nm)", try c.areas(arena, &.{1_997_500}) },
        .{ "a.with_width(>= 100nm)", &.{} },
    }, plates));
    try cases.append(arena, try derived(arena, "derived/with_width_neck_strict", cat, only_a, &.{
        .{ "a.with_width(> 70nm)", try c.areas(arena, &.{1_997_500}) },
        .{ "a.with_width(<= 70nm)", &.{} },
        .{ "a.with_width(== 70nm)", &.{} },
        .{ "a.with_width(> 70nm, < 71nm)", try c.areas(arena, &.{1_997_500}) },
    }, plates));
    // Plates overlapping 70 x 1: a neck of sqrt(70² + 1²) = sqrt(4901),
    // within half a unit of 70, where a whole-unit `width` limit at x2
    // cannot tell it from 70 (the KLayout mirror measures it exactly).
    try cases.append(arena, try derived(arena, "derived/with_width_neck_band", cat, only_a, &.{
        .{ "a.with_width(<= 70nm)", &.{} },
        .{ "a.with_width(> 70nm)", try c.areas(arena, &.{1_999_930}) },
    }, try boxes(arena, "a", &.{ .{ 0, 0, 1000, 1000 }, .{ 930, 999, 1930, 1999 } })));

    var texts: Layout = .{};
    try c.ring(arena, &texts, "a", .{ 3000, 0, 3600, 600 }, .{ 3100, 100, 3500, 500 });
    try texts.label(arena, "t", 3300, 300, "VDD");
    try c.rects(arena, &texts, "a", &.{ .{ 0, 0, 100, 100 }, .{ 200, 0, 400, 100 }, .{ 500, 0, 800, 100 }, .{ 900, 0, 1300, 100 }, .{ 1400, 0, 1900, 100 }, .{ 2000, 0, 2600, 100 } });
    try texts.label(arena, "t", 50, 50, "VDD");
    try texts.label(arena, "t", 200, 50, "VDDA");
    try texts.label(arena, "t", 650, 50, "vdd");
    try texts.label(arena, "t", 1100, 50, "VSD");
    try texts.label(arena, "t", 1650, 200, "VDD");
    try cases.append(arena, try derived(arena, "derived/with_text", cat, &.{ "a", "t" }, &.{
        .{ "a.with_text(t, \"VDD*\")", try c.areas(arena, &.{ 10_000, 20_000 }) },
        .{ "a.without_text(t, \"VDD*\")", try c.areas(arena, &.{ 30_000, 40_000, 50_000, 60_000, 200_000 }) },
        .{ "a.with_text(t, \"V?D\")", try c.areas(arena, &.{ 10_000, 40_000 }) },
    }, texts));
}

test "every selection fixture holds" {
    // Oracle: hand-derived areas of the shapes each selection keeps (the doc
    // comment above), reported through `forbidden`, under every symmetry at
    // two translations.
    try c.checkGenerated(fixturesInto);
}
