//! `min_extension` (DRC-045), `gate_corner` (DRC-052) and `overlap`
//! (DRC-046) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_overlay.rs (`min_extension`, `gate_corner`,
//! `overlap`).
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
    try minExtensionInto(arena, depth, out);
    try gateCornerInto(arena, out);
    try overlapInto(arena, depth, out);
}

// ---- private ----

/// `extension(poly, diff) >= 100nm` (`min_extension`, DRC-045): a poly that
/// crosses diffusion must run past each diffusion edge it crosses by the
/// limit; one finding per offending pair, measuring the shortest such run, 0
/// where the poly stops inside the diffusion or at its edge.
///
/// Diffusion is `[0, 1000] x [0, 400]`. Shapes: a gate with both ends at the
/// swept length, one end swept with the other far, a poly covering the
/// diffusion; a U-shaped poly whose far arm makes its bounding box reach
/// past on every side while the gate end is swept, and a gate ending inside
/// the diffusion at one end (both F19); a gate over a step in the
/// diffusion's edge, its near end swept; a legal gate over a diffusion drawn
/// as two pieces abutting under it (F56); a poly abutting the diffusion
/// without crossing it, one with a far end that is short (no gate, clean;
/// F41); an empty poly layer. Nightly: both ends across {inside, flush, 99,
/// 100, 101, far}.
fn minExtensionInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    var cs: Cases = .{ .arena = arena, .prefix = "min_extension", .catalog = &.{"DRC-045"}, .deck = try c.newDeck(arena, &.{ "diff", "poly" }, "rule poly.8 extension(poly, diff) >= 100nm\n"), .ids = &.{"poly.8"} };
    const diff: Box = .{ "diff", .{ 0, 0, 1000, 400 } };
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        try gate(&cs, try std.fmt.allocPrint(arena, "crossing/{s}", .{sw.side}), m, m);
        try gate(&cs, try std.fmt.allocPrint(arena, "one_end/{s}", .{sw.side}), 500, m);
        try cs.add(try std.fmt.allocPrint(arena, "covering/{s}", .{sw.side}), try drawn(arena, &.{ diff, .{ "poly", .{ -m, -m, 1000 + m, 400 + m } } }), &.{try c.below(arena, m, limit)});
        var u = try drawn(arena, &.{diff});
        try u.polygon(arena, "poly", &.{ .{ 400, -200 }, .{ 1300, -200 }, .{ 1300, 1000 }, .{ 1200, 1000 }, .{ 1200, -100 }, .{ 500, -100 }, .{ 500, 400 + m }, .{ 400, 400 + m } });
        try cs.add(try std.fmt.allocPrint(arena, "u_shape/{s}", .{sw.side}), u, &.{try c.below(arena, m, limit)});
        // The diffusion steps down from 400 to 300 under the gate. Every gate
        // edge facing up or down is still on the diffusion's edge, so the
        // runs are m below, 200 and 300 above; the step's own 50 nm edge
        // faces sideways, a side of the gate.
        try cs.add(try std.fmt.allocPrint(arena, "diffusion_jog/{s}", .{sw.side}), try drawn(arena, &.{ .{ "diff", .{ 0, 0, 450, 400 } }, .{ "diff", .{ 450, 0, 1000, 300 } }, .{ "poly", .{ 400, -m, 500, 600 } } }), &.{try c.below(arena, m, limit)});
    }
    try gate(&cs, "ends_inside", 500, -100);
    try cs.add("abutting", try drawn(arena, &.{ diff, .{ "poly", .{ 400, 400, 500, 900 } } }), &.{&.{}});
    // F41: no gate, so its far end, 50 past the diffusion, is not measured.
    try cs.add("abutting_short", try drawn(arena, &.{ diff, .{ "poly", .{ 400, 400, 500, 450 } } }), &.{&.{}});
    try cs.add("empty_poly", try drawn(arena, &.{diff}), &.{&.{}});
    // The diffusion drawn as two pieces abutting under the gate: one
    // diffusion, which the gate crosses with 200 nm to spare at both ends
    // (F56: each drawn piece was paired on its own).
    try cs.add("split_diffusion", try drawn(arena, &.{ .{ "diff", .{ 0, 0, 450, 400 } }, .{ "diff", .{ 450, 0, 1000, 400 } }, .{ "poly", .{ 400, -200, 500, 600 } } }), &.{&.{}});
    if (depth == .nightly) {
        const ends = [_]i64{ -100, 0, 99, 100, 101, 500 };
        for (ends) |bottom| for (ends) |top| {
            try gate(&cs, try std.fmt.allocPrint(arena, "ends/b{d}_t{d}", .{ bottom, top }), bottom, top);
        };
    }
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// The gate's two ends past the diffusion, bottom then top; at or below
/// zero it stops inside, measuring 0.
fn gate(cs: *Cases, case: []const u8, bottom: i64, top: i64) !void {
    const layout = try drawn(cs.arena, &.{ .{ "diff", .{ 0, 0, 1000, 400 } }, .{ "poly", .{ 400, -bottom, 500, 400 + top } } });
    try cs.add(case, layout, &.{try c.below(cs.arena, @max(@min(bottom, top), 0), 100)});
}

/// `bend(poly, diff)` (sky130 poly.11, "No 90 deg turns of poly on diff")
/// and `covers_corner(poly, diff)` (poly.10, "Poly can't overlap inner
/// corners of diff") (`gate_corner`, DRC-052): one finding per concave
/// corner of the shared area that is a concave corner of poly, or of diff,
/// at the corner.
///
/// Oracle: every corner is drawn where it is; a concave corner of an
/// intersection of rectilinear shapes is a concave corner of one of them.
///
/// Diffusion is `[0, 1000]^2` unless said. Shapes: a straight gate (clean);
/// an L poly bent inside the diffusion (a bend at (500, 500)), above it
/// (clean), and with its bend on the diffusion's top edge (the gate is a
/// rectangle: clean); a gate with a stub inside the diffusion (two bends);
/// a gate over a jog in the diffusion's edge (an inner corner at (450,
/// 300)); a poly square over an L diffusion's inner corner (500, 500), with
/// no gate bend; an empty poly layer.
fn gateCornerInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cs: Cases = .{ .arena = arena, .prefix = "gate_corner", .catalog = &.{"DRC-052"}, .deck = try c.newDeck(arena, &.{ "diff", "poly" }, "rule poly.11 bend(poly, diff)\nrule poly.10 covers_corner(poly, diff)\n"), .ids = &.{ "poly.11", "poly.10" } };
    const diff: Box = .{ "diff", .{ 0, 0, 1000, 1000 } };
    const none: []const Finding = &.{};
    try cs.add("straight", try drawn(arena, &.{ diff, .{ "poly", .{ 400, -200, 500, 1200 } } }), &.{ none, none });
    try cs.add("bent_inside", try lPoly(arena, 500), &.{ &.{corner(500, 500)}, none });
    try cs.add("bent_outside", try lPoly(arena, 1100), &.{ none, none });
    try cs.add("bent_on_edge", try lPoly(arena, 1000), &.{ none, none });
    try cs.add("stub", try drawn(arena, &.{ diff, .{ "poly", .{ 400, -200, 500, 1200 } }, .{ "poly", .{ 500, 400, 700, 500 } } }), &.{ &.{ corner(500, 400), corner(500, 500) }, none });
    try cs.add("diffusion_jog", try drawn(arena, &.{ .{ "diff", .{ 0, 0, 450, 400 } }, .{ "diff", .{ 450, 0, 1000, 300 } }, .{ "poly", .{ 400, -200, 500, 600 } } }), &.{ none, &.{corner(450, 300)} });
    try cs.add("inner_corner_covered", try drawn(arena, &.{ .{ "diff", .{ 0, 0, 1000, 500 } }, .{ "diff", .{ 0, 500, 500, 1000 } }, .{ "poly", .{ 300, 300, 700, 700 } } }), &.{ none, &.{corner(500, 500)} });
    try cs.add("empty_poly", try drawn(arena, &.{diff}), &.{ none, none });
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// A count of 1 at a corner.
fn corner(x: i64, y: i64) Finding {
    return c.count(1).pinned(x, y);
}

/// The diffusion and an L poly: a bar x 400..500 from y -200 up to
/// `y + 100`, turning right along y..y + 100 to x 1200; its concave corner
/// is (500, y).
fn lPoly(arena: Allocator, y: i64) !Layout {
    var l = try drawn(arena, &.{.{ "diff", .{ 0, 0, 1000, 1000 } }});
    try l.polygon(arena, "poly", &.{ .{ 400, -200 }, .{ 500, -200 }, .{ 500, y }, .{ 1200, y }, .{ 1200, y + 100 }, .{ 400, y + 100 } });
    return l;
}

/// `overlap(a, b) >= 100nm` (`overlap`, DRC-046): one finding per pair
/// whose shared area is narrower than the limit, measuring the narrower side
/// of that area; shapes that share no area do not overlap.
///
/// `b` is `[0, 1000]^2`. Shapes: an edge overlap and a contained bar, swept;
/// boxes that only touch, an L whose material overlaps 500 x 50 inside a
/// 500 x 500 box intersection, and a notched square whose box overlaps `b`
/// while its material keeps 50 nm away (all F19); an `a` drawn as two
/// abutting pieces that together overlap by 100 (F56); an empty `a`.
/// Nightly: the edge overlap from 90 to 110.
fn overlapInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const limit: i64 = 100;
    var cs: Cases = .{ .arena = arena, .prefix = "overlap", .catalog = &.{"DRC-046"}, .deck = try c.newDeck(arena, &.{ "a", "b" }, "rule ov overlap(a, b) >= 100nm\n"), .ids = &.{"ov"} };
    const b: Box = .{ "b", .{ 0, 0, 1000, 1000 } };
    for (c.sweep3(limit)) |sw| {
        const m = sw.value;
        try cs.add(try std.fmt.allocPrint(arena, "edge/{s}", .{sw.side}), try edge(arena, m), &.{try c.below(arena, m, limit)});
        try cs.add(try std.fmt.allocPrint(arena, "contained/{s}", .{sw.side}), try drawn(arena, &.{ .{ "a", .{ 300, 300, 300 + m, 700 } }, b }), &.{try c.below(arena, m, limit)});
    }
    try cs.add("touching", try edge(arena, 0), &.{&.{}});
    var l_shape = try drawn(arena, &.{b});
    try l_shape.polygon(arena, "a", &.{ .{ 500, 950 }, .{ 1900, 950 }, .{ 1900, 500 }, .{ 2000, 500 }, .{ 2000, 1000 }, .{ 500, 1000 } });
    try cs.add("l_shape", l_shape, &.{try c.lengths(arena, &.{50})});
    var notched = try drawn(arena, &.{b});
    try notched.polygon(arena, "a", &.{ .{ 950, 1050 }, .{ 1050, 1050 }, .{ 1050, 950 }, .{ 2000, 950 }, .{ 2000, 2000 }, .{ 950, 2000 } });
    try cs.add("notched_square", notched, &.{&.{}});
    try cs.add("empty_a", try drawn(arena, &.{b}), &.{&.{}});
    // `a` drawn as two abutting pieces: together they overlap `b` by 100
    // (F56: each drawn piece was paired on its own).
    try cs.add("split_a", try drawn(arena, &.{ .{ "a", .{ 900, 200, 950, 800 } }, .{ "a", .{ 950, 200, 2000, 800 } }, b }), &.{&.{}});
    if (depth == .nightly) {
        var m: i64 = 90;
        while (m <= 110) : (m += 1) try cs.add(try std.fmt.allocPrint(arena, "edge_sweep/{d}", .{m}), try edge(arena, m), &.{try c.below(arena, m, limit)});
    }
    try c.everyPlacementInto(arena, cs.list.items, out);
}

/// `a` overlapping `b`'s right edge by `m`.
fn edge(arena: Allocator, m: i64) !Layout {
    return drawn(arena, &.{ .{ "a", .{ 1000 - m, 200, 2000, 800 } }, .{ "b", .{ 0, 0, 1000, 1000 } } });
}

test "every extension, gate corner and overlap fixture holds" {
    // Oracle: drawn runs, corners and shared areas (the doc comments above),
    // the limit swept one grid step either side, under every symmetry at two
    // translations.
    try c.checkGenerated(fixturesInto);
}
