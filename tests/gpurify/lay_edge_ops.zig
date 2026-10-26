//! Edge layers, `extended` edge boxes, and the foundry rules the deck
//! writes with existing kinds, as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`edge_extended`, `foundry_expressions`,
//! `edge_operations`).
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
const Symmetry = harness.Symmetry;
const c = @import("drc_common.zig");
const d = @import("lay_derived.zig");
const derived = d.derived;
const boxes = d.boxes;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try edgeExtendedInto(arena, out);
    try foundryExpressionsInto(arena, out);
    try edgeOperationsInto(arena, out);
}

// ---- private ----

/// `extended` on edge layers (DRC-122), `KLayout`'s `extended(begin, end,
/// out, in)`: a box round each edge, lengthened before its start and past
/// its end, widened away from its shape (`out`) and into it (`in`), one box
/// per edge, reported with its area.
///
/// On a 1000 x 500 rectangle's four edges: 100 out (two 1000 x 100 and two
/// 500 x 100 boxes), 50 in, and 100 at both ends with 10 either side (two
/// 1200 x 20, two 700 x 20); and the edge `a` butts `b` with, 100 out,
/// which lies in `b` (100 x 500). All eight symmetries. Which end is the
/// start depends on the edges' turning sense, which a mirror reverses, so
/// the `begin`/`end` cases run under rotations only: lengthened 100 at its
/// start, 10 out, the bottom edge reaches a 200 x 5 probe below the
/// rectangle's lower-left corner (100 x 5 inside it); lengthened at its end
/// instead, only the left edge does (10 x 5).
fn edgeExtendedInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const cat: []const []const u8 = &.{"DRC-122"};
    var sides_layout = try boxes(arena, "a", &.{.{ 0, 0, 1000, 500 }});
    try sides_layout.rect(arena, "b", 1000, 0, 1500, 500);
    const sides = try derived(arena, "derived/extended/sides", cat, &.{ "a", "b" }, &.{
        .{ "a.edges().extended(begin: 0nm, end: 0nm, out: 100nm, in: 0nm)", try c.areas(arena, &.{ 100_000, 100_000, 50_000, 50_000 }) },
        .{ "a.edges().extended(begin: 0nm, end: 0nm, out: 0nm, in: 50nm)", try c.areas(arena, &.{ 50_000, 50_000, 25_000, 25_000 }) },
        .{ "a.edges().extended(begin: 100nm, end: 100nm, out: 10nm, in: 10nm)", try c.areas(arena, &.{ 24_000, 24_000, 14_000, 14_000 }) },
        .{ "(a.edges() and b.edges()).extended(begin: 0nm, end: 0nm, out: 100nm, in: 0nm) and b", try c.areas(arena, &.{50_000}) },
    }, sides_layout);
    var ends_layout = try boxes(arena, "a", &.{.{ 0, 0, 1000, 500 }});
    try ends_layout.rect(arena, "b", -200, -5, 0, 0);
    const ends = try derived(arena, "derived/extended/ends", cat, &.{ "a", "b" }, &.{
        .{ "a.edges().extended(begin: 100nm, end: 0nm, out: 10nm, in: 0nm) and b", try c.areas(arena, &.{500}) },
        .{ "a.edges().extended(begin: 0nm, end: 100nm, out: 10nm, in: 0nm) and b", try c.areas(arena, &.{50}) },
    }, ends_layout);
    try c.everyPlacementInto(arena, &.{sides}, out);
    for (Symmetry.all) |s| {
        if (s.mirror) continue;
        for (c.offsets) |o| try out.append(arena, try ends.transformed(arena, s, o[0], o[1]));
    }
}

/// Foundry rules the deck language writes with existing kinds, each the
/// reading its foundry's public deck codes, with the limit swept one step
/// either side:
///
/// - sky130 difftap.6, "Diff and tap are not allowed to extend beyond their
///   abutting edge" (DRC-051): the butting edge, tap's edges and diff's,
///   lengthened 1 past each end (`open_pdks`'s `sky130.lydrc` extends it
///   0.01 past both ends and asks whether diff or tap lies there); a tap the
///   height of its diff is clean, a taller one leaves a 1 x 1 square in the
///   cap, and a shifted one two.
/// - IHP Rppd.c's maximum, "Min. and max. `SalBlock` space to Cont 0.20"
///   (DRC-044): a contact not touching the band 200 either side of a
///   `SalBlock` edge (IHP `sg13g2_maximal.drc` takes the contacts not
///   interacting with the block's edges extended 0.2 out and 0.2 in); a
///   100 contact 199, 200 and 201 off the block's side, and one 400 inside
///   the block.
/// - ASAP7 M4.S.3, "Minimum tip-to-tip spacing between two M4 layer
///   polygons that do not share a parallel run length on adjacent tracks"
///   40 (DRC-031): lines on adjacent tracks are 24 apart (M4.W.1 24 on a 48
///   track pitch, M4.AUX.2), so the larger axis gap of their facing corners
///   is the tip-to-tip gap: `corner_space` by the larger gap at 40; tips 39,
///   40 and 41 apart, and two lines sharing a run (no facing corners).
/// - IHP CntB.b, CntB.b1 and CntB.b2 on bar contacts (DRC-064): "Any Cont
///   shape not being a square shape is considered a `ContBar`" (IHP layout
///   rules §5.15; its deck: `cont.non_squares`), so `cont.non_squares()`
///   holds bars of any length; two 160 x 1000 bars 279/280 apart (b, 280),
///   two 160 x 6000 bars 359/360 apart running 6000 (b1, 360 beyond a 5 µm
///   run), and a bar 219/220 from a square contact (b2, 220).
fn foundryExpressionsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    const caps = "(tap.edges() and diff.edges()).extended(begin: 1nm, end: 1nm, out: 1nm, in: 1nm) not (tap.edges() and diff.edges()).extended(begin: 0nm, end: 0nm, out: 1nm, in: 1nm)";
    const butt = "(" ++ caps ++ ") and (diff or tap)";
    for ([_]struct { []const u8, c.Rect, []const i128 }{
        .{ "flush", .{ 0, 0, 500, 500 }, &.{} },
        .{ "taller", .{ 0, 0, 500, 600 }, &.{1} },
        .{ "shifted", .{ 0, 100, 500, 600 }, &.{ 1, 1 } },
    }) |k| {
        var l = try boxes(arena, "diff", &.{.{ 500, 0, 1000, 500 }});
        try l.rect(arena, "tap", k[1][0], k[1][1], k[1][2], k[1][3]);
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "difftap.6/{s}", .{k[0]}), &.{"DRC-051"}, &.{ "diff", "tap" }, &.{.{ butt, try c.areas(arena, k[2]) }}, l));
    }
    const far_from_edge = "cont.not_interacting(salblock.edges().extended(begin: 0nm, end: 0nm, out: 200nm, in: 200nm))";
    for (c.sweep3(200)) |sw| {
        const g = sw.value;
        var l = try boxes(arena, "salblock", &.{.{ 0, 0, 1000, 1000 }});
        try l.rect(arena, "cont", 1000 + g, 450, 1100 + g, 550);
        const found: []const Finding = if (g > 200) try c.areas(arena, &.{10_000}) else &.{};
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "rppd.c/{s}", .{sw.side}), &.{"DRC-044"}, &.{ "cont", "salblock" }, &.{.{ far_from_edge, found }}, l));
    }
    var inside = try boxes(arena, "salblock", &.{.{ 0, 0, 1000, 1000 }});
    try inside.rect(arena, "cont", 450, 450, 550, 550);
    try cases.append(arena, try derived(arena, "rppd.c/inside", &.{"DRC-044"}, &.{ "cont", "salblock" }, &.{.{ far_from_edge, try c.areas(arena, &.{10_000}) }}, inside));
    const s3 = try c.newDeck(arena, &.{"met4"}, "rule M4.S.3 corner_space(met4; corner_to_corner: false, except_eol: none) >= 40nm\n");
    for (c.sweep3(40)) |sw| {
        const dx = sw.value;
        const found: []const Finding = if (dx < 40) try arena.dupe(Finding, &.{.length(dx)}) else &.{};
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "m4.s.3/{s}", .{sw.side}), &.{"DRC-031"}, s3, try boxes(arena, "met4", &.{ .{ 0, 0, 500, 24 }, .{ 500 + dx, 48, 1000 + dx, 72 } }), &.{.{ "M4.S.3", found }}));
    }
    try cases.append(arena, try c.fixture(arena, "m4.s.3/shared_run", &.{"DRC-031"}, s3, try boxes(arena, "met4", &.{ .{ 0, 0, 500, 24 }, .{ 400, 48, 900, 72 } }), &.{.{ "M4.S.3", &.{} }}));
    const cntb = try c.newDeck(arena, &.{"cont"}, "layer bar = cont.non_squares()\nlayer sq = cont.squares()\nrule CntB.b space(bar) >= 280nm\nrule CntB.b1 prl_space(bar; prl: 5001nm) >= 360nm\nrule CntB.b2 space(bar, sq) >= 220nm\n");
    for (c.sweep3(280)) |sw| {
        const gap = sw.value;
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cntb.b/{s}", .{sw.side}), &.{"DRC-064"}, cntb, try bars(arena, gap, 1000), &.{
            .{ "CntB.b", try c.below(arena, gap, 280) },
            .{ "CntB.b1", &.{} },
            .{ "CntB.b2", &.{} },
        }));
    }
    for (c.sweep3(360)) |sw| {
        const gap = sw.value;
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cntb.b1/{s}", .{sw.side}), &.{"DRC-064"}, cntb, try bars(arena, gap, 6000), &.{
            .{ "CntB.b", &.{} },
            .{ "CntB.b1", try c.below(arena, gap, 360) },
            .{ "CntB.b2", &.{} },
        }));
    }
    for (c.sweep3(220)) |sw| {
        const gap = sw.value;
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cntb.b2/{s}", .{sw.side}), &.{"DRC-064"}, cntb, try boxes(arena, "cont", &.{ .{ 0, 0, 160, 1000 }, .{ 160 + gap, 0, 320 + gap, 160 } }), &.{
            .{ "CntB.b", &.{} },
            .{ "CntB.b1", &.{} },
            .{ "CntB.b2", try c.below(arena, gap, 220) },
        }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Two 160-wide contact bars `long` tall, `gap` apart.
fn bars(arena: Allocator, gap: i64, long: i64) !Layout {
    return boxes(arena, "cont", &.{ .{ 0, 0, 160, long }, .{ 160 + gap, 0, 320 + gap, long } });
}

/// Edge layers (DRC-122): `.edges()` (a rectangle, the same drawn as two
/// abutting halves, an L, a ring's outer and inner edges, an outline with a
/// redundant collinear vertex); edge `and`, `not` and `or` on two butting
/// rectangles and on two whose shapes share edges on the same side;
/// `inside_part` and `outside_part`, with the part on the other layer's
/// boundary in neither; edge `interacting`, touching and lying wholly
/// inside; and `with_length` across its bounds. Each edge is reported with
/// its length.
fn edgeOperationsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const cat: []const []const u8 = &.{"DRC-122"};
    const ab: []const []const u8 = &.{ "a", "b" };
    var cases: std.ArrayList(Fixture) = .empty;
    var l_shape: Layout = .{};
    try l_shape.polygon(arena, "a", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 200 }, .{ 200, 200 }, .{ 200, 1000 }, .{ 0, 1000 } });
    var ring: Layout = .{};
    try c.ring(arena, &ring, "a", .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 });
    var collinear: Layout = .{};
    try collinear.polygon(arena, "a", &.{ .{ 0, 0 }, .{ 400, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 0, 100 } });
    const edges = [_]struct { []const u8, Layout, []const i64 }{
        .{ "rect", try boxes(arena, "a", &.{.{ 0, 0, 300, 100 }}), &.{ 300, 100, 300, 100 } },
        .{ "abutting_halves", try boxes(arena, "a", &.{ .{ 0, 0, 150, 100 }, .{ 150, 0, 300, 100 } }), &.{ 300, 100, 300, 100 } },
        .{ "l_shape", l_shape, &.{ 1000, 200, 800, 800, 200, 1000 } },
        .{ "ring", ring, &.{ 1000, 1000, 1000, 1000, 400, 400, 400, 400 } },
        .{ "collinear_vertex", collinear, &.{ 1000, 100, 1000, 100 } },
    };
    for (edges) |k| try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/edges/{s}", .{k[0]}), cat, &.{"a"}, &.{.{ "a.edges()", try c.lengths(arena, k[2]) }}, k[1]));
    var butting = try boxes(arena, "a", &.{.{ 0, 0, 500, 300 }});
    try butting.rect(arena, "b", 500, -100, 1000, 200);
    try cases.append(arena, try derived(arena, "derived/edge_booleans", cat, ab, &.{
        .{ "a.edges() and b.edges()", try c.lengths(arena, &.{200}) },
        .{ "a.edges() not b.edges()", try c.lengths(arena, &.{ 500, 100, 500, 300 }) },
        .{ "a.edges() or b.edges()", try c.lengths(arena, &.{ 500, 300, 500, 300, 500, 300, 500, 100 }) },
    }, butting));
    // `b` inside `a` along its left side: edges that coincide with their
    // shapes on the same side.
    var same_side = try boxes(arena, "a", &.{.{ 0, 0, 1000, 1000 }});
    try same_side.rect(arena, "b", 0, 0, 500, 1000);
    try cases.append(arena, try derived(arena, "derived/edge_booleans_same_side", cat, ab, &.{
        .{ "a.edges() and b.edges()", try c.lengths(arena, &.{ 1000, 500, 500 }) },
        .{ "a.edges() not b.edges()", try c.lengths(arena, &.{ 500, 500, 1000 }) },
        .{ "a.edges() or b.edges()", try c.lengths(arena, &.{ 1000, 1000, 1000, 1000, 1000 }) },
    }, same_side));
    var within = try boxes(arena, "a", &.{.{ 400, 400, 600, 600 }});
    try within.rect(arena, "b", 0, 0, 1000, 1000);
    try cases.append(arena, try derived(arena, "derived/edge_interacting_within", cat, ab, &.{
        .{ "a.edges().interacting(b)", try c.lengths(arena, &.{ 200, 200, 200, 200 }) },
        .{ "a.edges().not_interacting(b)", &.{} },
    }, within));
    for ([_]struct { []const u8, c.Rect, []const i64 }{
        .{ "crossing", .{ 300, -100, 600, 200 }, &.{ 300, 300 } },
        .{ "on_boundary", .{ 300, 0, 600, 100 }, &.{} },
    }) |k| {
        var l = try boxes(arena, "a", &.{.{ 0, 0, 1000, 100 }});
        try l.rect(arena, "b", k[1][0], k[1][1], k[1][2], k[1][3]);
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/edge_parts/{s}", .{k[0]}), cat, ab, &.{
            .{ "a.edges().inside_part(b)", try c.lengths(arena, k[2]) },
            .{ "a.edges().outside_part(b)", try c.lengths(arena, &.{ 300, 400, 300, 400, 100, 100 }) },
        }, l));
    }
    var touching = try boxes(arena, "a", &.{.{ 0, 0, 1000, 100 }});
    try touching.rect(arena, "b", 400, 100, 600, 300);
    try cases.append(arena, try derived(arena, "derived/edge_interacting", cat, ab, &.{
        .{ "a.edges().interacting(b)", try c.lengths(arena, &.{1000}) },
        .{ "a.edges().not_interacting(b)", try c.lengths(arena, &.{ 1000, 100, 100 }) },
    }, touching));
    try cases.append(arena, try derived(arena, "derived/with_length", cat, &.{"a"}, &.{
        .{ "a.edges().with_length(== 100nm)", try c.lengths(arena, &.{ 100, 100 }) },
        .{ "a.edges().with_length(> 100nm, <= 300nm)", try c.lengths(arena, &.{ 300, 300 }) },
        .{ "a.edges().with_length(< 100nm)", &.{} },
    }, try boxes(arena, "a", &.{.{ 0, 0, 300, 100 }})));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every edge and foundry-expression fixture holds" {
    // Oracle: hand-derived edge lengths, box areas and gaps (the doc
    // comments above), under every symmetry each rule keeps at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
