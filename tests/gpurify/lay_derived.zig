//! Derived layers proved through `forbidden`, and the booleans and sizing
//! they are built from, as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`derived`, `booleans`, `sizing`).
//!
//! Contents:
//! - `pub const Expr`
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`
//! - `pub fn derived(arena: Allocator, name: []const u8, catalog: []const []const u8, layers: []const []const u8, exprs: []const Expr, layout: Layout) !Fixture`
//! - `pub fn boxes(arena: Allocator, layer: []const u8, rs: []const c.Rect) !Layout`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");

/// A derived-layer expression and exactly what `forbidden` of it reports.
pub const Expr = struct { []const u8, []const Finding };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try booleansInto(arena, out);
    try sizingInto(arena, out);
}

/// One fixture per layout proving derived layers through `forbidden`: rule
/// `f{i}` forbids `exprs[i].0`, declared as layer `d{i}`, and must report
/// exactly `exprs[i].1`.
pub fn derived(arena: Allocator, name: []const u8, catalog: []const []const u8, layers: []const []const u8, exprs: []const Expr, layout: Layout) !Fixture {
    const ids = [_][]const u8{ "f0", "f1", "f2", "f3" };
    std.debug.assert(exprs.len <= ids.len);
    var body: std.ArrayList(u8) = .empty;
    const rows = try arena.alloc(c.Row, exprs.len);
    for (exprs, rows, 0..) |e, *r, i| {
        try body.print(arena, "layer d{d} = {s}\nrule f{d} forbidden(d{d})\n", .{ i, e[0], i, i });
        r.* = .{ ids[i], e[1] };
    }
    return c.fixture(arena, name, catalog, try c.newDeck(arena, layers, body.items), layout, rows);
}

/// A layout of rectangles on one layer.
pub fn boxes(arena: Allocator, layer: []const u8, rs: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, rs);
    return l;
}

// ---- private ----

/// `and`, `or` and `not` (DRC-120, and DRC-050 for a forbidden overlap):
/// each resulting merged shape reported with its area, holes excluded.
///
/// `a` is `[0, 1000]^2` unless stated. `and`: a partial overlap, edge and
/// corner contact (empty), `b` splitting the overlap in two, `a` drawn as
/// two overlapping pieces (one result), and sky130 licon.17 written inline,
/// `forbidden(licon and poly and (diff or tap))`. `or`: overlapping,
/// abutting (one shape) and apart. `not`: a bite, a split, a hole (one shape
/// with its hole excluded), an abutting `b` (no change), a covering `b`
/// (empty), and three operands folded left.
fn booleansInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const cat: []const []const u8 = &.{"DRC-120"};
    const ab: []const []const u8 = &.{ "a", "b" };
    const Case = struct { []const u8, []const []const u8, []const u8, []const i128, []const c.Rect };
    const list = [_]Case{
        .{ "derived/and/overlap", &.{ "DRC-120", "DRC-050" }, "a and b", &.{160_000}, &.{.{ 600, 300, 1600, 700 }} },
        .{ "derived/and/edge_contact", cat, "a and b", &.{}, &.{.{ 1000, 300, 1600, 700 }} },
        .{ "derived/and/corner_contact", cat, "a and b", &.{}, &.{.{ 1000, 1000, 1600, 1600 }} },
        .{ "derived/and/split", cat, "a and b", &.{ 200_000, 200_000 }, &.{ .{ -100, -100, 200, 1100 }, .{ 800, -100, 1100, 1100 } } },
        .{ "derived/or/overlap", cat, "a or b", &.{1_240_000}, &.{.{ 600, 300, 1600, 700 }} },
        .{ "derived/or/abutting", cat, "a or b", &.{2_000_000}, &.{.{ 1000, 0, 2000, 1000 }} },
        .{ "derived/or/apart", cat, "a or b", &.{ 1_000_000, 1_000_000 }, &.{.{ 1001, 0, 2001, 1000 }} },
        .{ "derived/not/bite", cat, "a not b", &.{800_000}, &.{.{ 800, -100, 1200, 1100 }} },
        .{ "derived/not/split", cat, "a not b", &.{ 400_000, 400_000 }, &.{.{ 400, -100, 600, 1100 }} },
        .{ "derived/not/hole", cat, "a not b", &.{960_000}, &.{.{ 400, 400, 600, 600 }} },
        .{ "derived/not/abutting", cat, "a not b", &.{1_000_000}, &.{.{ 1000, 0, 2000, 1000 }} },
        .{ "derived/not/covered", cat, "a not b", &.{}, &.{.{ -100, -100, 1100, 1100 }} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (list, 0..) |k, i| {
        var l = try boxes(arena, "a", &.{.{ 0, 0, 1000, 1000 }});
        try c.rects(arena, &l, "b", k[4]);
        try cases.append(arena, try derived(arena, k[0], k[1], ab, &.{.{ k[2], try c.areas(arena, k[3]) }}, l));
        // The overlapping operand sits after `and/split`, as the Rust lists it.
        if (i == 3) {
            var o = try boxes(arena, "a", &.{ .{ 0, 0, 600, 1000 }, .{ 400, 0, 1000, 1000 } });
            try o.rect(arena, "b", 300, 300, 700, 700);
            try cases.append(arena, try derived(arena, "derived/and/overlapping_operand", cat, ab, &.{.{ "a and b", try c.areas(arena, &.{160_000}) }}, o));
        }
    }
    var three = try boxes(arena, "a", &.{.{ 0, 0, 1000, 1000 }});
    try three.rect(arena, "b", 0, 0, 300, 1000);
    try three.rect(arena, "c", 700, 0, 1000, 1000);
    try cases.append(arena, try derived(arena, "derived/not/three_operands", cat, &.{ "a", "b", "c" }, &.{.{ "a not b not c", try c.areas(arena, &.{400_000}) }}, three));
    var licon = try boxes(arena, "poly", &.{.{ 0, 0, 1000, 200 }});
    try licon.rect(arena, "diff", 0, -500, 400, 500);
    try licon.rect(arena, "tap", 600, -500, 1000, 500);
    try c.rects(arena, &licon, "licon", &.{ .{ 100, 50, 200, 150 }, .{ 700, 50, 850, 150 }, .{ 450, 50, 550, 150 }, .{ 100, 300, 200, 400 } });
    try cases.append(arena, try c.fixture(
        arena,
        "derived/and/licon_17_inline",
        &.{ "DRC-050", "DRC-120" },
        try c.newDeck(arena, &.{ "licon", "poly", "diff", "tap" }, "rule licon.17 forbidden(licon and poly and (diff or tap))\n"),
        licon,
        &.{.{ "licon.17", try c.areas(arena, &.{ 10_000, 15_000 }) }},
    ));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `.sized` (DRC-120): growth by `a` on every side with square corners;
/// shrinking, where a part no wider than twice the shrink disappears; and
/// the opening `.sized(-a).sized(a)`, which keeps the parts wider than `2a`.
///
/// Shapes: a bar grown by 50; an L grown and shrunk by 50 (its concave
/// corner stays); two squares 99 and 101 apart grown by 50 (one shape, or
/// two); bars 99/100/101 wide shrunk by 50 (gone, gone, 1 x 900); a ring
/// with a 200 nm hole grown by 99/100/101 (the hole 2 x 2, then closed) and
/// shrunk by 100; a plate with a 100-wide tab (two abutting pieces) opened
/// by 49/50/51 (tab kept, then gone); a dumbbell opened by 60, which splits
/// it into its two plates.
fn sizingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const cat: []const []const u8 = &.{"DRC-120"};
    const only_a: []const []const u8 = &.{"a"};
    var cases: std.ArrayList(Fixture) = .empty;
    try cases.append(arena, try derived(arena, "derived/sized/grow", cat, only_a, &.{.{ "a.sized(50nm)", try c.areas(arena, &.{80_000}) }}, try boxes(arena, "a", &.{.{ 0, 0, 100, 300 }})));
    // An L keeps its concave corner: grown by 50 it is two 1100 x 300 arms
    // sharing 300 x 300, shrunk by 50 two 900 x 100 arms sharing 100 x 100.
    const l_shape = [_][2]i64{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 200 }, .{ 200, 200 }, .{ 200, 1000 }, .{ 0, 1000 } };
    for ([_][2]i64{ .{ 50, 570_000 }, .{ -50, 170_000 } }) |ba| {
        var l: Layout = .{};
        try l.polygon(arena, "a", &l_shape);
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/sized/l_shape{d}", .{ba[0]}), cat, only_a, &.{.{ try std.fmt.allocPrint(arena, "a.sized({d}nm)", .{ba[0]}), try c.areas(arena, &.{ba[1]}) }}, l));
    }
    for ([_]struct { i64, []const i128 }{ .{ 99, &.{79_800} }, .{ 101, &.{ 40_000, 40_000 } } }) |gg| {
        const g = gg[0];
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/sized/grow_gap{d}", .{g}), cat, only_a, &.{.{ "a.sized(50nm)", try c.areas(arena, gg[1]) }}, try boxes(arena, "a", &.{ .{ 0, 0, 100, 100 }, .{ 100 + g, 0, 200 + g, 100 } })));
    }
    for (c.sweep3(100)) |sw| {
        const w = sw.value;
        const found: []const Finding = if (w > 100) try c.areas(arena, &.{900}) else &.{};
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/sized/shrink/{s}", .{sw.side}), cat, only_a, &.{.{ "a.sized(-50nm)", found }}, try boxes(arena, "a", &.{.{ 0, 0, w, 1000 }})));
    }
    for (c.sweep3(50)) |sw| {
        const by = sw.value;
        const area: i128 = if (by < 50) 1_100_000 else 1_000_000;
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/sized/opening/{s}", .{sw.side}), cat, only_a, &.{.{ try std.fmt.allocPrint(arena, "a.sized(-{d}nm).sized({d}nm)", .{ by, by }), try c.areas(arena, &.{area}) }}, try boxes(arena, "a", &.{ .{ 0, 0, 1000, 1000 }, .{ 1000, 450, 2000, 550 } })));
    }
    // A ring with a 200 nm hole: grown by 99 the hole is 2 x 2, by 100 it
    // closes; shrunk by 100 the hole widens to 400.
    var ringed: Layout = .{};
    try c.ring(arena, &ringed, "a", .{ 0, 0, 1000, 1000 }, .{ 400, 400, 600, 600 });
    for ([_]struct { i64, []const u8, i128 }{ .{ 99, "below", 1_198 * 1_198 - 4 }, .{ 100, "at", 1_200 * 1_200 }, .{ 101, "above", 1_202 * 1_202 } }) |r| {
        try cases.append(arena, try derived(arena, try std.fmt.allocPrint(arena, "derived/sized/ring_closes/{s}", .{r[1]}), cat, only_a, &.{.{ try std.fmt.allocPrint(arena, "a.sized({d}nm)", .{r[0]}), try c.areas(arena, &.{r[2]}) }}, ringed));
    }
    try cases.append(arena, try derived(arena, "derived/sized/ring_shrinks", cat, only_a, &.{.{ "a.sized(-100nm)", try c.areas(arena, &.{640_000 - 160_000}) }}, ringed));
    try cases.append(arena, try derived(arena, "derived/sized/opening_splits", cat, only_a, &.{.{ "a.sized(-60nm).sized(60nm)", try c.areas(arena, &.{ 1_000_000, 1_000_000 }) }}, try boxes(arena, "a", &.{ .{ 0, 0, 1000, 1000 }, .{ 1000, 450, 1500, 550 }, .{ 1500, 0, 2500, 1000 } })));
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every boolean and sizing fixture holds" {
    // Oracle: hand-derived areas of each derived shape (the doc comments
    // above), reported through `forbidden`, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
