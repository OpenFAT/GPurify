//! Edge length: `min_edge_length` (DRC-020) and edge length on an edge
//! layer (DRC-021) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`short_edge_shapes`,
//! `merged_edge_shapes`, `min_edge_length`, `edge_length_of_edges`).
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

/// A named shape and the findings an edge-length limit of 101 gives it.
const Shape = struct { []const u8, Layout, []const Finding };

const limit: i64 = 101;

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try minEdgeLengthInto(arena, depth, out);
    try edgeLengthOfEdgesInto(arena, depth, out);
}

// ---- private ----

/// Each short edge at its doubled midpoint, when `s` is short.
fn at(arena: Allocator, s: i64, points: []const [2]i64) ![]const Finding {
    if (s >= limit) return &.{};
    const out = try arena.alloc(Finding, points.len);
    for (points, out) |p, *o| o.* = c.pin(.length(s), p[0], p[1]);
    return out;
}

/// The step, short-rectangle and hole shapes both edge-length checks share,
/// with the findings an edge-length limit of 101 gives them: each short
/// edge at its midpoint. `s` is the short edge.
fn shortEdgeShapes(arena: Allocator, s: i64) ![3]Shape {
    var step: Layout = .{};
    try step.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 1000 }, .{ 1000, 1000 }, .{ 1000, 1000 + s }, .{ 0, 1000 + s } });
    var hole: Layout = .{};
    try hole.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 2000, 2000 }, .{ 900, 900, 900 + s, 900 + s }));
    return .{
        .{ "step", step, try at(arena, s, &.{.{ 2000, 2000 + s }}) },
        .{ "thin_rect", try c.met1(arena, &.{.{ 0, 0, s, 2000 }}), try at(arena, s, &.{ .{ s, 0 }, .{ s, 4000 } }) },
        .{ "hole", hole, try at(arena, s, &.{ .{ 1800 + s, 1800 }, .{ 1800 + 2 * s, 1800 + s }, .{ 1800 + s, 1800 + 2 * s }, .{ 1800, 1800 + s } }) },
    };
}

/// The merged shapes both edge-length checks share: a square drawn as a
/// strip of height `s` on a block (its edges are the square's), and two
/// rectangles overlapping so their union has two jogs of length `s`.
fn mergedEdgeShapes(arena: Allocator, s: i64) ![2]Shape {
    const jogs: []const Finding = if (s < 101) try arena.dupe(Finding, &.{ c.pin(.length(s), 2000 + s, 800), c.pin(.length(s), s, 1000) }) else &.{};
    return .{
        .{ "strip_on_block", try c.met1(arena, &.{ .{ 0, 0, 2000, s }, .{ 0, s, 2000, 2000 } }), &.{} },
        .{ "overlap_jog", try c.met1(arena, &.{ .{ 0, 0, 1000, 500 }, .{ s, 400, 1000 + s, 900 } }), jogs },
    };
}

/// `edge_length(met1) >= 101nm` (`min_edge_length`, DRC-020): one finding
/// per edge shorter than the limit, at its midpoint, measuring its length.
/// At the limit is legal.
///
/// The layer is merged first, so the edges are the merged figure's: a
/// square drawn as a thin strip on a block has none of the strip's short
/// ends, and an overlap whose union has two short jogs has both (F18).
fn minEdgeLengthInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule el edge_length(met1) >= 101nm");
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |s| {
        const sd = try c.side(arena, s, limit);
        const short = try shortEdgeShapes(arena, s);
        const merged = try mergedEdgeShapes(arena, s);
        for (short ++ merged) |sh| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "min_edge_length/{s}/{s}", .{ sh[0], sd }), &.{"DRC-020"}, deck, sh[1], &.{.{ "el", sh[2] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "min_edge_length", &.{"DRC-020"}, "rule el edge_length(met1) >= 101nm", &.{"el"}));
}

/// `length(met1.edges()) >= 101nm` (`edge_min_length`) and
/// `forbidden(met1.edges().with_length(< 101nm))` (DRC-021): edge length on
/// an edge layer. `.edges()` is the boundary of the merged layer, so both
/// see what `min_edge_length` should: the jogs of an overlap, and none of
/// the strip's ends. Each short edge is one finding at its midpoint,
/// measuring its length, for both rules.
fn edgeLengthOfEdgesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const rules = "rule le length(met1.edges()) >= 101nm\nrule fe forbidden(met1.edges().with_length(< 101nm))";
    const deck = try c.oneLayerDeck(arena, rules);
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, limit)) |s| {
        const sd = try c.side(arena, s, limit);
        const short = try shortEdgeShapes(arena, s);
        const merged = try mergedEdgeShapes(arena, s);
        for (short ++ merged) |sh| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "edge_min_length/{s}/{s}", .{ sh[0], sd }), &.{"DRC-021"}, deck, sh[1], &.{ .{ "le", sh[2] }, .{ "fe", sh[2] } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "edge_min_length", &.{"DRC-021"}, rules, &.{ "le", "fe" }));
}

test "every edge length fixture holds" {
    // Oracle: each fixture's expected answer, derived from the edge-length
    // definitions (the doc comments above): the short edge swept one grid
    // step either side of 101, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
