//! The helpers every exhaustive DRC generator shares: decks, the limit
//! sweep, placements under the square's symmetries and two translations,
//! pinned findings, and layouts of rectangles. Ported from the helper
//! sections of tests/exhaustive/drc_dimension.rs and drc_overlay.rs.
//!
//! Conventions every generator keeps (drc_dimension.rs):
//! - A minimum passes at its limit and a maximum passes at its limit; only
//!   a strict excess is a finding.
//! - A marker is pinned only where the doc comment names the point exactly
//!   (a midpoint, a vertex, a box centre) and that point is a lattice point,
//!   so every symmetry maps it exactly (`pin`). Elsewhere only `measured` is.
//! - The vacuous case is the rule on an empty layer: the definition's
//!   outcome is `ran` with nothing found.
//! - A fixture that disagrees with a carefully derived expectation carries
//!   the finding it is waiting on (`F<n>`). None are carried today.
//!
//! Contents:
//! - `pub const offsets`, `pub const nightly_reach`, `pub const Rect`, `pub const Row`
//! - `pub fn oneLayerDeck(arena, rules) ![]const u8`, `threeLayerDeck`, `newDeck(arena, layers, body)`
//! - `pub fn everyPlacementInto(arena, fixtures, out) !void`, `everyAxisPlacementInto`, `everyPlacementAtInto`, `everyOffsetInto`
//! - `pub fn sweep(arena, depth, limit) ![]const i64`, `sweep3(limit) [3]Swept`, `side(arena, value, limit)`
//! - `pub fn pin(f, x2, y2) Finding`, `count(n) Finding`, `ratio(fraction, at) Finding`, `floorSqrt(n) i64`
//! - `pub fn below(arena, measured, limit) ![]const Finding`, `lengths(arena, values)`, `areas(arena, values)`
//! - `pub fn holed(arena, outer, hole) ![]const [2]i64`
//! - `pub fn rects(arena, layout, layer, boxes) !void`, `ring(arena, layout, layer, outer, hole)`, `met1(arena, boxes) !Layout`
//! - `pub fn fixture(arena, name, catalog, deck, layout, rows) !Fixture`, `counted(...)`, `vacuous(...)`
//! - `pub fn checkGenerated(generate) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Measurement = @import("check").report.Measurement;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Symmetry = harness.Symmetry;

/// The translations every case is repeated at: the origin, and far off it
/// in the negative quadrant, so nothing depends on coordinates being small
/// or positive.
pub const offsets = [_][2]i64{ .{ 0, 0 }, .{ -1_234_567, 987_654 } };

/// How far either side of a limit the nightly sweep reaches, in grid steps.
pub const nightly_reach: i64 = 24;

/// An axis-aligned rectangle, `[xlo, ylo, xhi, yhi]` in nanometres.
pub const Rect = [4]i64;

/// One rule claimed to run and to find exactly its findings.
pub const Row = struct { []const u8, []const Finding };

/// A swept value and its side's name: `below`, `at`, `above`.
pub const Swept = struct { value: i64, side: []const u8 };

/// A one-layer deck with `rules` appended, on a 1 nm manufacturing grid.
pub fn oneLayerDeck(arena: Allocator, rules: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\n{s}\n", .{rules});
}

/// A deck with `met1`, `met2` and a `region` layer, `rules` appended.
pub fn threeLayerDeck(arena: Allocator, rules: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nlayer region = gds(81, 1)\n{s}\n", .{rules});
}

/// A deck on a 1 nm grid with each of `layers` drawn on its own GDS layer
/// (1, 2, ...), then `body`.
pub fn newDeck(arena: Allocator, layers: []const []const u8, body: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "grid 1nm\n");
    for (layers, 1..) |name, gds| try out.print(arena, "layer {s} = gds({d}, 0)\n", .{ name, gds });
    try out.appendSlice(arena, body);
    return out.items;
}

/// Repeats each fixture under every symmetry at every offset.
pub fn everyPlacementInto(arena: Allocator, fixtures: []const Fixture, out: *std.ArrayList(Fixture)) !void {
    try everyPlacementAtInto(arena, fixtures, &offsets, out);
}

/// Repeats each fixture under the four symmetries of the square that keep
/// the axes (no quarter turn) at every offset, for a rule tied to an axis:
/// a quarter turn makes a vertical pitch a horizontal one.
pub fn everyAxisPlacementInto(arena: Allocator, fixtures: []const Fixture, out: *std.ArrayList(Fixture)) !void {
    for (fixtures) |*f| for (offsets) |o| for (Symmetry.all) |s| {
        if (s.turns % 2 == 0) try out.append(arena, try f.transformed(arena, s, o[0], o[1]));
    };
}

/// Repeats each fixture under every symmetry at each of `at`.
pub fn everyPlacementAtInto(arena: Allocator, fixtures: []const Fixture, at: []const [2]i64, out: *std.ArrayList(Fixture)) !void {
    for (fixtures) |*f| for (at) |o| try f.everySymmetryInto(arena, o[0], o[1], out);
}

/// Each fixture at every offset, unturned: for rules anchored on the die's
/// lower-left corner, which a turn or mirror moves.
pub fn everyOffsetInto(arena: Allocator, fixtures: []const Fixture, out: *std.ArrayList(Fixture)) !void {
    for (fixtures) |*f| for (offsets) |o| try out.append(arena, try f.transformed(arena, .identity, o[0], o[1]));
}

/// The values a limit is swept over: one grid step either side at merge
/// depth, `nightly_reach` steps at nightly.
pub fn sweep(arena: Allocator, depth: Depth, limit: i64) ![]const i64 {
    const reach: i64 = switch (depth) {
        .merge => 1,
        .nightly => nightly_reach,
    };
    const out = try arena.alloc(i64, @intCast(2 * reach + 1));
    for (out, 0..) |*v, i| v.* = limit - reach + @as(i64, @intCast(i));
    return out;
}

/// The limit swept one grid step either side, each value with its side's
/// name (drc_overlay.rs's `sweep`).
pub fn sweep3(limit: i64) [3]Swept {
    return .{ .{ .value = limit - 1, .side = "below" }, .{ .value = limit, .side = "at" }, .{ .value = limit + 1, .side = "above" } };
}

/// `below99`, `at100`, `above101`: where `value` sits against `limit`.
pub fn side(arena: Allocator, value: i64, limit: i64) ![]const u8 {
    const word = switch (std.math.order(value, limit)) {
        .lt => "below",
        .eq => "at",
        .gt => "above",
    };
    return std.fmt.allocPrint(arena, "{s}{d}", .{ word, value });
}

/// Pins `f` at `(x2 / 2, y2 / 2)`, the doubled coordinates of a midpoint,
/// when both halves are whole. A midpoint off the lattice is floored, and
/// a floor does not commute with a mirror, so it stays unpinned.
pub fn pin(f: Finding, x2: i64, y2: i64) Finding {
    return if (@mod(x2, 2) == 0 and @mod(y2, 2) == 0) f.pinned(@divExact(x2, 2), @divExact(y2, 2)) else f;
}

/// A finding whose measured value is a count.
pub fn count(n: u32) Finding {
    return .{ .measured = .count(n), .at = null };
}

/// A finding with a measured fraction, at `at`.
pub fn ratio(fraction: f64, at: [2]i64) Finding {
    return .{ .measured = .ratio(fraction), .at = at };
}

/// The largest `r` with `r * r <= n`: a Euclidean gap as the report floors it.
pub fn floorSqrt(n: i64) i64 {
    if (n <= 0) return 0;
    return @intCast(std.math.sqrt(@as(u64, @intCast(n))));
}

/// A `>=` rule's verdict on one measurement: a finding measuring it when
/// it is below `limit`, nothing at or above.
pub fn below(arena: Allocator, measured: i64, limit: i64) ![]const Finding {
    return if (measured < limit) arena.dupe(Finding, &.{.length(measured)}) else &.{};
}

/// One finding per length.
pub fn lengths(arena: Allocator, values: []const i64) ![]const Finding {
    const out = try arena.alloc(Finding, values.len);
    for (values, out) |v, *o| o.* = .length(v);
    return out;
}

/// One finding per area, in square nanometres.
pub fn areas(arena: Allocator, values: []const i128) ![]const Finding {
    const out = try arena.alloc(Finding, values.len);
    for (values, out) |v, *o| o.* = .area(v);
    return out;
}

/// A rectangle with a rectangular hole, as GDSII writes one: a single ring
/// that runs in to the hole along a slit and back out along it.
pub fn holed(arena: Allocator, outer: Rect, hole: Rect) ![]const [2]i64 {
    const xa, const ya, const xb, const yb = outer;
    const xl, const yl, const xh, const yh = hole;
    return arena.dupe([2]i64, &.{ .{ xl, ya }, .{ xb, ya }, .{ xb, yb }, .{ xa, yb }, .{ xa, ya }, .{ xl, ya }, .{ xl, yl }, .{ xl, yh }, .{ xh, yh }, .{ xh, yl }, .{ xl, yl } });
}

/// Adds axis-aligned rectangles on `layer`.
pub fn rects(arena: Allocator, layout: *Layout, layer: []const u8, boxes: []const Rect) !void {
    for (boxes) |b| try layout.rect(arena, layer, b[0], b[1], b[2], b[3]);
}

/// `outer` with `hole` cut out, drawn as four abutting bands that only
/// merge into a ring: a shape with a hole, which one drawn outline cannot be.
pub fn ring(arena: Allocator, layout: *Layout, layer: []const u8, outer: Rect, hole: Rect) !void {
    try rects(arena, layout, layer, &.{
        .{ outer[0], outer[1], outer[2], hole[1] },
        .{ outer[0], hole[3], outer[2], outer[3] },
        .{ outer[0], hole[1], hole[0], hole[3] },
        .{ hole[2], hole[1], outer[2], hole[3] },
    });
}

/// `met1` rectangles.
pub fn met1(arena: Allocator, boxes: []const Rect) !Layout {
    var l: Layout = .{};
    try rects(arena, &l, "met1", boxes);
    return l;
}

/// A DRC fixture expecting each row's rule to run and find exactly its
/// findings.
pub fn fixture(arena: Allocator, name: []const u8, catalog: []const []const u8, deck: []const u8, layout: Layout, rows: []const Row) !Fixture {
    var f: Fixture = .init(try arena.dupe(u8, name), try arena.dupe([]const u8, catalog), deck, harness.drc);
    f.layout = layout;
    for (rows) |r| try f.claim(arena, .rule(r[0], r[1]));
    return f;
}

/// A fixture expecting rule `id` to run, find exactly `findings`, and
/// examine every shape of `layout`: for the kinds whose `examined` counts
/// drawn polygons (`min_width`, `max_width`), when every shape is one
/// polygon on the measured layer. A rule that skips the layer, or counts
/// merged figures, fails it.
pub fn counted(arena: Allocator, name: []const u8, catalog: []const []const u8, deck: []const u8, layout: Layout, id: []const u8, findings: []const Finding) !Fixture {
    var f: Fixture = .init(try arena.dupe(u8, name), try arena.dupe([]const u8, catalog), deck, harness.drc);
    f.layout = layout;
    try f.claim(arena, harness.Expect.rule(id, findings).examined(layout.shapes.items.len));
    return f;
}

/// `rules` on an empty `met1`, with a `met2` shape so the layout is not
/// empty: each rule runs and finds nothing.
pub fn vacuous(arena: Allocator, kind: []const u8, catalog: []const []const u8, rules: []const u8, ids: []const []const u8) !Fixture {
    const deck = try std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\n{s}\n", .{rules});
    var layout: Layout = .{};
    try layout.rect(arena, "met2", 0, 0, 1000, 1000);
    const rows = try arena.alloc(Row, ids.len);
    for (ids, rows) |id, *r| r.* = .{ id, &.{} };
    return fixture(arena, try std.fmt.allocPrint(arena, "{s}/vacuous", .{kind}), catalog, deck, layout, rows);
}

/// Generates the merge-depth fixtures of one generator and checks them all.
pub fn checkGenerated(generate: *const fn (arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) anyerror!void) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try generate(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}

test "the helpers state their own examples" {
    // Oracle: the doc comments above: a doubled midpoint pins only when
    // both halves are whole; the floor square root of 99 is 9 and of 100 is
    // 10; the merge sweep is the limit one step either side.
    try testing.expectEqual(@as(?[2]i64, .{ 5, 7 }), pin(.length(3), 10, 14).at);
    try testing.expectEqual(@as(?[2]i64, null), pin(.length(3), 11, 14).at);
    try testing.expectEqual(9, floorSqrt(99));
    try testing.expectEqual(10, floorSqrt(100));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualSlices(i64, &.{ 99, 100, 101 }, try sweep(arena.allocator(), .merge, 100));
    try testing.expectEqualStrings("below99", try side(arena.allocator(), 99, 100));
}
