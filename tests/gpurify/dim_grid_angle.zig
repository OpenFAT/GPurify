//! `off_grid` (DRC-001), `angle` (DRC-002, DRC-003, DRC-037),
//! `interior_angle` (DRC-003) and `valid` (DRC-004) as exhaustive
//! fixtures. Ported from tests/exhaustive/drc_dimension.rs (`off_grid`,
//! `angle`, `interior_angle`, `polygon_validity`).
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
    try offGridInto(arena, depth, out);
    try angleInto(arena, out);
    try interiorAngleInto(arena, out);
    try polygonValidityInto(arena, out);
}

// ---- private ----

/// One finding per corner of `r`, each measuring `off`, at the corner.
fn vertices(arena: Allocator, r: c.Rect, off: i64) ![]const Finding {
    return arena.dupe(Finding, &.{
        Finding.length(off).pinned(r[0], r[1]),
        Finding.length(off).pinned(r[2], r[1]),
        Finding.length(off).pinned(r[2], r[3]),
        Finding.length(off).pinned(r[0], r[3]),
    });
}

/// `off_grid(; pitch: 10nm)` (`off_grid`, DRC-001): one finding per vertex
/// of any row on any drawn layer off the 10 nm lattice, at the vertex,
/// measuring its Chebyshev distance to the nearest lattice point.
///
/// The lattice is fixed to the origin, so the translations here are whole
/// multiples of the pitch; every symmetry of the square maps it to itself.
/// A rectangle shifted by `k` on x (every vertex off by `min(k, 10 − k)`);
/// one off on both axes (the larger offset); one off at two vertices only;
/// a hole with two vertices off; a shape on another layer; an empty
/// layout. And a deck deriving `met1.sized(5nm)` and a copy `met1 not
/// met2` (F50): derived layers are not checked, so on-grid met1 is clean
/// though its halo is 5 off, and off-grid met1 is reported once, not again
/// on the copy.
fn offGridInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const offsets_on_grid = [_][2]i64{ .{ 0, 0 }, .{ -1_234_560, 987_650 } };
    const deck = "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nrule g off_grid(; pitch: 10nm)\n";
    var shifts: std.ArrayList(i64) = .empty;
    switch (depth) {
        .merge => try shifts.appendSlice(arena, &.{ 0, 1, 4, 5, 6, 9 }),
        .nightly => for (0..11) |k| try shifts.append(arena, @intCast(k)),
    }
    var cases: std.ArrayList(Fixture) = .empty;
    for (shifts.items) |k| {
        const off = @min(k, 10 - k);
        const r: c.Rect = .{ k, 0, 100 + k, 100 };
        const findings: []const Finding = if (off == 0) &.{} else try vertices(arena, r, off);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "off_grid/shifted/k{d}", .{k}), &.{"DRC-001"}, deck, try c.met1(arena, &.{r}), &.{.{ "g", findings }}));
    }
    try cases.append(arena, try c.fixture(arena, "off_grid/both_axes", &.{"DRC-001"}, deck, try c.met1(arena, &.{.{ 2, 6, 102, 206 }}), &.{.{ "g", try vertices(arena, .{ 2, 6, 102, 206 }, 4) }}));
    try cases.append(arena, try c.fixture(arena, "off_grid/two_vertices", &.{"DRC-001"}, deck, try c.met1(arena, &.{.{ 0, 0, 105, 100 }}), &.{.{ "g", &.{ Finding.length(5).pinned(105, 0), Finding.length(5).pinned(105, 100) } }}));
    var hole: Layout = .{};
    try hole.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 500, 503, 700, 700 }));
    try cases.append(arena, try c.fixture(arena, "off_grid/hole", &.{"DRC-001"}, deck, hole, &.{.{ "g", &.{ Finding.length(3).pinned(500, 503), Finding.length(3).pinned(700, 503) } }}));
    var other: Layout = .{};
    try c.rects(arena, &other, "met2", &.{.{ 3, 0, 103, 100 }});
    try cases.append(arena, try c.fixture(arena, "off_grid/other_layer", &.{"DRC-001"}, deck, other, &.{.{ "g", try vertices(arena, .{ 3, 0, 103, 100 }, 3) }}));
    const derived_deck = "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nlayer halo = met1.sized(5nm)\nlayer copy = met1 not met2\nrule g off_grid(; pitch: 10nm)\n";
    try cases.append(arena, try c.fixture(arena, "off_grid/derived/on_grid", &.{"DRC-001"}, derived_deck, try c.met1(arena, &.{.{ 0, 0, 100, 100 }}), &.{.{ "g", &.{} }}));
    try cases.append(arena, try c.fixture(arena, "off_grid/derived/off_grid", &.{"DRC-001"}, derived_deck, try c.met1(arena, &.{.{ 3, 0, 103, 100 }}), &.{.{ "g", try vertices(arena, .{ 3, 0, 103, 100 }, 3) }}));
    try c.everyPlacementAtInto(arena, cases.items, &offsets_on_grid, out);
    try out.append(arena, try c.fixture(arena, "off_grid/empty_layout", &.{"DRC-001"}, deck, .{}, &.{.{ "g", &.{} }}));
}

/// `angle` (DRC-002, DRC-003, DRC-037): one finding per edge not along an
/// allowed line, at its first vertex, measuring `Count(0)`.
///
/// Three rules whose allowed sets every symmetry of the square maps to
/// themselves, so the transforms keep the expectation: `[0, 90]` on
/// `met1`, all four lines on every layer, and `[45, 135]` on every layer.
/// A rectangle (every vertex starts one flagged edge under `[45, 135]`, so
/// the markers are its vertices in any order), the same on `met2`, and a
/// right triangle whose hypotenuse is at 45 or 135 degrees. The rule's
/// Limits say a non-rectilinear layout is refused at load; its body says
/// the rule checks the lines, and with no rule validating the layer
/// nothing refuses it. A deck deriving `met1.sized(5nm)` and a copy `met1
/// not met2` (F63): with no layer only drawn layers are checked, so the
/// rectangle's corners are reported once, not again on the copy and the
/// halo.
fn angleInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nrule a angle(met1; allowed: [0deg, 90deg])\nrule all angle(; allowed: [0deg, 45deg, 90deg, 135deg])\nrule d angle(; allowed: [45deg, 135deg])\n";
    const corners = [_]Finding{ c.count(0).pinned(0, 0), c.count(0).pinned(1000, 0), c.count(0).pinned(1000, 500), c.count(0).pinned(0, 500) };
    var cases: std.ArrayList(Fixture) = .empty;
    try cases.append(arena, try c.fixture(arena, "angle/rect", &.{"DRC-002"}, deck, try c.met1(arena, &.{.{ 0, 0, 1000, 500 }}), &.{ .{ "a", &.{} }, .{ "all", &.{} }, .{ "d", &corners } }));
    var other: Layout = .{};
    try c.rects(arena, &other, "met2", &.{.{ 0, 0, 1000, 500 }});
    try cases.append(arena, try c.fixture(arena, "angle/rect_other_layer", &.{"DRC-002"}, deck, other, &.{ .{ "a", &.{} }, .{ "all", &.{} }, .{ "d", &corners } }));
    var triangle: Layout = .{};
    try triangle.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 0, 1000 } });
    try cases.append(arena, try c.fixture(arena, "angle/triangle", &.{ "DRC-002", "DRC-003", "DRC-037" }, deck, triangle, &.{ .{ "a", &.{c.count(0)} }, .{ "all", &.{} }, .{ "d", &.{ c.count(0), c.count(0) } } }));
    try cases.append(arena, try c.fixture(arena, "angle/derived", &.{"DRC-002"}, "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nlayer halo = met1.sized(5nm)\nlayer copy = met1 not met2\nrule d angle(; allowed: [45deg, 135deg])\n", try c.met1(arena, &.{.{ 0, 0, 1000, 500 }}), &.{.{ "d", &corners }}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.fixture(arena, "angle/empty_layout", &.{"DRC-002"}, deck, .{}, &.{ .{ "a", &.{} }, .{ "all", &.{} }, .{ "d", &.{} } }));
}

/// A finding measuring an angle in degrees (a ratio), at `(x, y)`.
fn degrees(value: f64, x: i64, y: i64) Finding {
    return .{ .measured = .ratio(value), .at = .{ x, y } };
}

/// `interior_angle` (`min_interior_angle`, DRC-003: IHP 3.1 "shapes with
/// acute angles <87 degree are not allowed on any layer", GF180 SH.2
/// "angles <90 deg"): one finding per drawn corner whose angle inside its
/// shape is under the limit, at the vertex, measuring the angle.
///
/// Oracle: angles fixed by construction. A rectangle (90 at a limit of 90:
/// legal), an L (its inner corner 270), a ring (its hole's corners 270 on
/// the shape's side, 90 inside the hole: a check that reads a hole's own
/// inside flags nothing either way, but one that takes the smaller angle of
/// a corner flags an L's inner corner), an octagon (135); a right isosceles
/// triangle (two 45-degree corners, exactly 45 once rounded) under both
/// limits; a 30-60-90 triangle whose two acute corners are under both; and
/// the triangle on another layer, which only the every-layer rule reads.
fn interiorAngleInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nrule r interior_angle(met1) >= 90deg\nrule ihp interior_angle() >= 87deg\n";
    const triangle = [_][2]i64{ .{ 0, 0 }, .{ 1000, 0 }, .{ 0, 1000 } };
    const acute = [_]Finding{ degrees(45.0, 1000, 0), degrees(45.0, 0, 1000) };
    const Case = struct { []const u8, Layout, []const Finding };
    var ring: Layout = .{};
    try ring.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 300, 300, 700, 700 }));
    var octagon: Layout = .{};
    try octagon.polygon(arena, "met1", &.{ .{ 100, 0 }, .{ 900, 0 }, .{ 1000, 100 }, .{ 1000, 900 }, .{ 900, 1000 }, .{ 100, 1000 }, .{ 0, 900 }, .{ 0, 100 } });
    var right: Layout = .{};
    try right.polygon(arena, "met1", &triangle);
    var thirty: Layout = .{};
    try thirty.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1732, 0 }, .{ 0, 1000 } });
    const both = [_]Case{
        .{ "rectangle", try c.met1(arena, &.{.{ 0, 0, 1000, 500 }}), &.{} },
        .{ "l_shape", try c.met1(arena, &.{ .{ 0, 0, 1000, 100 }, .{ 0, 100, 100, 1000 } }), &.{} },
        .{ "ring", ring, &.{} },
        .{ "octagon", octagon, &.{} },
        .{ "right_triangle", right, &acute },
        .{ "thirty_sixty", thirty, &.{ Finding.any().pinned(1732, 0), Finding.any().pinned(0, 1000) } },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (both) |b| try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "interior_angle/{s}", .{b[0]}), &.{"DRC-003"}, deck, b[1], &.{ .{ "r", b[2] }, .{ "ihp", b[2] } }));
    var other: Layout = .{};
    try other.polygon(arena, "met2", &triangle);
    try cases.append(arena, try c.fixture(arena, "interior_angle/other_layer", &.{"DRC-003"}, deck, other, &.{ .{ "r", &.{} }, .{ "ihp", &acute } }));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// `valid` (`polygon_validity`, DRC-004: IHP 3.1 "self-intersecting
/// polygons must be avoided"): one finding per drawn polygon that crosses
/// itself or encloses no area, where every other rule reading its layer
/// records `Refused`.
///
/// Oracle: polygons drawn with the defect by construction: a ring crossing
/// itself, a ring doubling back on itself (zero area), and beside them a
/// rectangle and a 45-degree triangle, both valid (a check that also
/// refuses diagonal edges flags the triangle). `valid(met1)` reads met1
/// only, and `valid()` every drawn layer, so a crossing ring on met2 is the
/// second's.
fn polygonValidityInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nrule v valid(met1)\nrule all valid()\n";
    const crossing = [_][2]i64{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, -1000 }, .{ 0, -1000 } };
    const Case = struct { []const u8, []const u8, []const []const [2]i64, []const Finding, []const Finding };
    const cases_in = [_]Case{
        .{ "self_crossing", "met1", &.{&crossing}, &.{c.count(0)}, &.{c.count(0)} },
        .{ "zero_area", "met1", &.{&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 500, 0 } }}, &.{c.count(0)}, &.{c.count(0)} },
        .{ "valid_shapes", "met1", &.{ &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 500 }, .{ 0, 500 } }, &.{ .{ 2000, 0 }, .{ 3000, 0 }, .{ 2000, 1000 } } }, &.{}, &.{} },
        .{ "other_layer", "met2", &.{&crossing}, &.{}, &.{c.count(0)} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (cases_in) |k| {
        var layout: Layout = .{};
        for (k[2]) |points| try layout.polygon(arena, k[1], points);
        try layout.rect(arena, "met1", 5000, 5000, 6000, 6000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "polygon_validity/{s}", .{k[0]}), &.{"DRC-004"}, deck, layout, &.{ .{ "v", k[3] }, .{ "all", k[4] } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every off_grid, angle and validity fixture holds" {
    // Oracle: each fixture's expected answer, derived from the rule's
    // definition (the doc comments above): vertices off the lattice by
    // construction, angles fixed by construction, defective polygons drawn
    // with their defect, under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}
