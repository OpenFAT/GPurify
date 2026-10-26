//! `min_enclosure` (DRC-040) and `asymmetric_enclosure` (DRC-041, DRC-042)
//! as exhaustive fixtures. Ported from tests/exhaustive/drc_overlay.rs
//! (`MARGINS`, `L_HOST`, `PLUS_HOST`, `min_enclosure`, `margins4`,
//! `asymmetric_enclosure`).
//!
//! Contents:
//! - `pub const l_host`, `pub const plus_host`, `pub const Box`, `pub const Cases = struct`, `add`
//! - `pub fn drawn(arena: Allocator, boxes: []const Box) !Layout`
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");

/// An L-shaped host, `[0, 2000] x [0, 1000]` with `[0, 1000] x [0, 2000]`:
/// its concave corner is `(1000, 1000)`.
pub const l_host = [_][2]i64{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 1000 }, .{ 1000, 1000 }, .{ 1000, 2000 }, .{ 0, 2000 } };

/// A plus-shaped host, bars `[0, 1000] x [400, 600]` and `[400, 600] x [0,
/// 1000]`: its concave corners are 50 nm diagonally off `[450, 550]^2` on
/// both axes, Euclidean `floor(sqrt(5000)) = 70`, while every straight strip
/// from that square runs 450 nm.
pub const plus_host = [_][2]i64{ .{ 400, 0 }, .{ 600, 0 }, .{ 600, 400 }, .{ 1000, 400 }, .{ 1000, 600 }, .{ 600, 600 }, .{ 600, 1000 }, .{ 400, 1000 }, .{ 400, 600 }, .{ 0, 600 }, .{ 0, 400 }, .{ 400, 400 } };

/// One rectangle on a named layer.
pub const Box = struct { []const u8, c.Rect };

/// The cases of one generator: each a fixture named `prefix/name` on one
/// deck and catalog, its rules claimed in `ids` order.
pub const Cases = struct {
    arena: Allocator,
    prefix: []const u8,
    catalog: []const []const u8,
    deck: []const u8,
    ids: []const []const u8,
    list: std.ArrayList(Fixture) = .empty,

    /// Adds `prefix/name`, rule `ids[i]` finding exactly `found[i]`.
    pub fn add(cs: *Cases, case: []const u8, layout: Layout, found: []const []const Finding) !void {
        std.debug.assert(found.len == cs.ids.len);
        const rows = try cs.arena.alloc(c.Row, found.len);
        for (rows, cs.ids, found) |*r, id, f| r.* = .{ id, f };
        try cs.list.append(cs.arena, try c.fixture(cs.arena, try std.fmt.allocPrint(cs.arena, "{s}/{s}", .{ cs.prefix, case }), cs.catalog, cs.deck, layout, rows));
    }
};

/// The margins every enumeration sweeps: touching, one step below, at and
/// above a 100 nm limit, and far.
const margins = [_]i64{ 0, 99, 100, 101, 400 };

/// A layout of rectangles.
pub fn drawn(arena: Allocator, boxes: []const Box) !Layout {
    var l: Layout = .{};
    for (boxes) |b| try l.rect(arena, b[0], b[1][0], b[1][1], b[1][2], b[1][3]);
    return l;
}

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try minEnclosureInto(arena, depth, out);
    try asymmetricEnclosureInto(arena, depth, out);
}

// ---- private ----

/// `enclosure(via, met1) >= 100nm` (`min_enclosure`, DRC-040): one finding
/// per drawn via whose Euclidean distance to its host's boundary, holes and
/// concave corners included, is below the limit, measuring that distance
/// floored. A via no merged host figure covers measures 0.
///
/// Shapes, each margin swept 99/100/101:
/// - concentric, and one side short (the symmetries visit the other three);
/// - the host drawn as two abutting halves meeting under the via, which only
///   the merged host covers;
/// - a host ring (four bands) with the via beside its hole, so the hole's
///   edge counts;
/// - the via drawn as two abutting halves, each measured on its own;
/// - an L host with the via off its concave corner at Pythagorean offsets
///   (60, 79/80/81), so the Euclidean distance is exact and a projection
///   measure, which sees only the far edges, is caught; drawn as one outline
///   and as two overlapping rectangles.
///
/// And: a plus-shaped host (Euclidean 70 at its concave corners); a via
/// straddling the host's edge, outside it, or touching it from inside or
/// outside (all 0); a via with a hole (`cut not hole`), one polygon, swept;
/// each layer empty. Nightly: every combination of four rectangular margins.
fn minEnclosureInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    var cs: Cases = .{ .arena = arena, .prefix = "min_enclosure", .catalog = &.{"DRC-040"}, .deck = try c.newDeck(arena, &.{ "via", "met1" }, "rule enc enclosure(via, met1) >= 100nm\n"), .ids = &.{"enc"} };
    const via: Box = .{ "via", .{ 0, 0, 100, 100 } };
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        const short = try c.below(arena, m, limit);
        try cs.add(try name(arena, "concentric", sw.side), try drawn(arena, &.{ via, .{ "met1", .{ -m, -m, 100 + m, 100 + m } } }), &.{short});
        try cs.add(try name(arena, "one_side", sw.side), try drawn(arena, &.{ via, .{ "met1", .{ -400, -400, 100 + m, 500 } } }), &.{short});
        try cs.add(try name(arena, "seam", sw.side), try drawn(arena, &.{ via, .{ "met1", .{ -400, -400, 50, 500 } }, .{ "met1", .{ 50, -400, 100 + m, 500 } } }), &.{short});
        var beside = try drawn(arena, &.{.{ "via", .{ 1000 - m, 950, 1100 - m, 1050 } }});
        try c.ring(arena, &beside, "met1", .{ 0, 0, 2000, 2000 }, .{ 1100, 700, 1500, 1300 });
        try cs.add(try name(arena, "beside_hole", sw.side), beside, &.{short});
        const twice = try std.mem.concat(arena, Finding, &.{ short, short });
        try cs.add(try name(arena, "via_halves", sw.side), try drawn(arena, &.{ .{ "via", .{ 0, 0, 50, 100 } }, .{ "via", .{ 50, 0, 100, 100 } }, .{ "met1", .{ -m, -m, 100 + m, 100 + m } } }), &.{twice});
    }
    const corners = [_]struct { i64, []const u8, []const Finding }{
        .{ 79, "below", try c.lengths(arena, &.{99}) },
        .{ 80, "at", &.{} },
        .{ 81, "above", &.{} },
    };
    for (corners) |k| {
        const dy = k[0];
        var outline = try drawn(arena, &.{.{ "via", .{ 840, 900 - dy, 940, 1000 - dy } }});
        try outline.polygon(arena, "met1", &l_host);
        try cs.add(try name(arena, "concave_corner", k[1]), outline, &.{k[2]});
        try cs.add(try name(arena, "concave_corner_two_rects", k[1]), try drawn(arena, &.{ .{ "via", .{ 840, 900 - dy, 940, 1000 - dy } }, .{ "met1", .{ 0, 0, 2000, 1000 } }, .{ "met1", .{ 0, 0, 1000, 2000 } } }), &.{k[2]});
    }
    var plus = try drawn(arena, &.{.{ "via", .{ 450, 450, 550, 550 } }});
    try plus.polygon(arena, "met1", &plus_host);
    try cs.add("plus_host", plus, &.{try c.lengths(arena, &.{70})});
    const hosts = [_]struct { []const u8, c.Rect }{
        .{ "straddling", .{ 50, -400, 600, 500 } },
        .{ "outside", .{ 200, -400, 800, 500 } },
        .{ "touching_inside", .{ 0, -400, 600, 500 } },
        .{ "touching_outside", .{ 100, -400, 600, 500 } },
    };
    for (hosts) |h| try cs.add(h[0], try drawn(arena, &.{ via, .{ "met1", h[1] } }), &.{try c.lengths(arena, &.{0})});
    try cs.add("empty_via", try drawn(arena, &.{.{ "met1", .{ 0, 0, 1000, 1000 } }}), &.{&.{}});
    try cs.add("empty_met1", try drawn(arena, &.{via}), &.{try c.lengths(arena, &.{0})});
    // A via with a hole, derived as `cut not hole`, is one polygon: its
    // material is `m` from the host's edge on every side.
    const deck_ring = try c.newDeck(arena, &.{ "cut", "hole", "met1" }, "layer via = cut not hole\nrule enc enclosure(via, met1) >= 100nm\n");
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        try cs.list.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_enclosure/ring_via/{s}", .{sw.side}), &.{ "DRC-040", "DRC-120" }, deck_ring, try drawn(arena, &.{ .{ "cut", .{ 0, 0, 300, 300 } }, .{ "hole", .{ 100, 100, 200, 200 } }, .{ "met1", .{ -m, -m, 300 + m, 300 + m } } }), &.{.{ "enc", try c.below(arena, m, limit) }}));
    }
    if (depth == .nightly) for (margins) |l| for (margins) |r| for (margins) |b| for (margins) |t| {
        try cs.add(try std.fmt.allocPrint(arena, "margins/l{d}_r{d}_b{d}_t{d}", .{ l, r, b, t }), try drawn(arena, &.{ via, .{ "met1", .{ -l, -b, 100 + r, 100 + t } } }), &.{try c.below(arena, @min(l, r, b, t), limit)});
    };
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `enclosure(via, met1, opposite) >= 100nm` (`asymmetric_enclosure`,
/// DRC-041 and DRC-042): each edge of a via is read straight out to the
/// nearest host edge facing it; the via measures `max(min over its vertical
/// edges, min over its horizontal edges)`, which for a rectangle is
/// `max(min(left, right), min(bottom, top))`.
///
/// Oracle: every margin is drawn, so each edge's straight-out reading is a
/// number the layout was built to have.
///
/// Shapes: the limit on one axis with the other axis touching; one side
/// short with the other axis far; both axes short; every side touching; a
/// host with notches down to the via on two sides (a bounding-box measure
/// sees the far edges); the plus host, clean here because its straight
/// strips run 450 nm although its concave corners are 70 nm off; an
/// L-shaped via, swept; an L via with the limit only along x (clean: the old
/// every-side fallback read 0); an L via whose concave top edge decides the
/// y axis, swept, while a host notch 50 nm right of its upper arm spoils the
/// x axis (an every-side or bounding-box measure reads 50 or the box's 100
/// at every step); an unhosted via; an empty via layer. Nightly: every
/// combination of four margins.
fn asymmetricEnclosureInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    var cs: Cases = .{ .arena = arena, .prefix = "asymmetric_enclosure", .catalog = &.{ "DRC-041", "DRC-042" }, .deck = try c.newDeck(arena, &.{ "via", "met1" }, "rule m1.5 enclosure(via, met1, opposite) >= 100nm\n"), .ids = &.{"m1.5"} };
    const l_via = [_][2]i64{ .{ 0, 0 }, .{ 200, 0 }, .{ 200, 100 }, .{ 100, 100 }, .{ 100, 200 }, .{ 0, 200 } };
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        const named = [_]struct { []const u8, [4]i64 }{
            .{ "x_axis", .{ m, m, 0, 0 } },
            .{ "y_axis", .{ 0, 0, m, m } },
            .{ "one_side_short", .{ m, 400, 0, 400 } },
            .{ "both_axes_short", .{ m, 400, 400, 99 } },
        };
        for (named) |n| try cs.add(try name(arena, n[0], sw.side), try hosted(arena, n[1]), &.{try measure(arena, n[1], limit)});
        // Notches come down to `m` above and right of the via; the host's
        // box is 400 nm out on every side.
        var notched = try drawn(arena, &.{.{ "via", .{ 0, 0, 100, 100 } }});
        try notched.polygon(arena, "met1", &.{ .{ -400, -400 }, .{ 500, -400 }, .{ 500, 0 }, .{ 100 + m, 0 }, .{ 100 + m, 100 }, .{ 500, 100 }, .{ 500, 500 }, .{ 100, 500 }, .{ 100, 100 + m }, .{ 0, 100 + m }, .{ 0, 500 }, .{ -400, 500 } });
        try cs.add(try name(arena, "notched_host", sw.side), notched, &.{try c.below(arena, m, limit)});
        var lv = try drawn(arena, &.{.{ "met1", .{ -m, -m, 200 + m, 200 + m } }});
        try lv.polygon(arena, "via", &l_via);
        try cs.add(try name(arena, "l_via", sw.side), lv, &.{try c.below(arena, m, limit)});
    }
    try cs.add("every_side_zero", try hosted(arena, .{ 0, 0, 0, 0 }), &.{try c.lengths(arena, &.{0})});
    var plus = try drawn(arena, &.{.{ "via", .{ 450, 450, 550, 550 } }});
    try plus.polygon(arena, "met1", &plus_host);
    try cs.add("plus_host", plus, &.{&.{}});
    var one_axis = try drawn(arena, &.{.{ "met1", .{ -100, 0, 300, 200 } }});
    try one_axis.polygon(arena, "via", &l_via);
    try cs.add("l_via_one_axis", one_axis, &.{&.{}});
    // A notch comes down from the host's top over x in [150, 250] to
    // 100 + k: the via's concave top edge (y = 100, x in [100, 200]) reads k,
    // its other horizontal edges 100, so y measures min(k, 100). The upper
    // arm's right edge (x = 100) reads 50 to the notch while the notch
    // reaches below y = 200, so x measures 50 then, else 100.
    for (c.sweep3(limit)) |sw| {
        const k = sw.value;
        var l: Layout = .{};
        try l.polygon(arena, "via", &l_via);
        try l.polygon(arena, "met1", &.{ .{ -100, -100 }, .{ 300, -100 }, .{ 300, 300 }, .{ 250, 300 }, .{ 250, 100 + k }, .{ 150, 100 + k }, .{ 150, 300 }, .{ -100, 300 } });
        const x: i64 = if (100 + k < 200) 50 else 100;
        try cs.add(try name(arena, "l_via_concave_edge", sw.side), l, &.{try c.below(arena, @max(x, @min(k, 100)), limit)});
    }
    try cs.add("unhosted", try drawn(arena, &.{ .{ "via", .{ 0, 0, 100, 100 } }, .{ "met1", .{ 50, -400, 600, 500 } } }), &.{try c.lengths(arena, &.{0})});
    try cs.add("empty_via", try drawn(arena, &.{.{ "met1", .{ 0, 0, 1000, 1000 } }}), &.{&.{}});
    if (depth == .nightly) for (margins) |l| for (margins) |r| for (margins) |b| for (margins) |t| {
        const lrbt = [4]i64{ l, r, b, t };
        try cs.add(try std.fmt.allocPrint(arena, "margins/l{d}_r{d}_b{d}_t{d}", .{ l, r, b, t }), try hosted(arena, lrbt), &.{try measure(arena, lrbt, limit)});
    };
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `shape/side`.
fn name(arena: Allocator, shape: []const u8, side: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ shape, side });
}

/// A 100 nm via in met1 `left, right, bottom, top` past it.
fn hosted(arena: Allocator, m: [4]i64) !Layout {
    return drawn(arena, &.{ .{ "via", .{ 0, 0, 100, 100 } }, .{ "met1", .{ -m[0], -m[2], 100 + m[1], 100 + m[3] } } });
}

/// `max(min(left, right), min(bottom, top))` against the limit.
fn measure(arena: Allocator, m: [4]i64, limit: i64) ![]const Finding {
    return c.below(arena, @max(@min(m[0], m[1]), @min(m[2], m[3])), limit);
}

test "every enclosure fixture holds" {
    // Oracle: each fixture's expected answer, derived from the enclosure
    // definitions above: drawn margins, hosts and Pythagorean offsets, the
    // limit swept one grid step either side, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
