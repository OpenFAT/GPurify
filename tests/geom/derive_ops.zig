//! Derived-layer operations against hand-derived regions, areas and edges.
//! Ported from crates/geom/tests/core/derive_ops.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const derive = geom.derive;
const Seg = geom.Seg;
const ValidatedLayer = geom.ValidatedLayer;
const max_i128 = std.math.maxInt(i128);

const Ring = []const [2]i64;
const Box = [4]i64;

/// A diamond of radius 10.
const diamond: Ring = &.{ .{ 10, 0 }, .{ 0, 10 }, .{ -10, 0 }, .{ 0, -10 } };

// ---- private ----

/// A merged rectilinear layer from rings (CCW outers, CW holes).
fn layer(rings: []const Ring) !ValidatedLayer {
    return fx.layerOf(rings, .rectilinear, true);
}

/// A merged octilinear layer from rings.
fn octLayer(rings: []const Ring) !ValidatedLayer {
    return fx.layerOf(rings, .octilinear, true);
}

fn boxRing(b: Box) [4][2]i64 {
    return .{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[2], b[3] }, .{ b[0], b[3] } };
}

/// The rectangle as a CW ring, for a hole.
fn holeRing(b: Box) [4][2]i64 {
    return .{ .{ b[0], b[1] }, .{ b[0], b[3] }, .{ b[2], b[3] }, .{ b[2], b[1] } };
}

/// A merged layer of CCW rectangles.
fn rects(boxes: []const Box) !ValidatedLayer {
    var rings: [16][4][2]i64 = undefined;
    var refs: [16]Ring = undefined;
    for (boxes, 0..) |b, i| {
        rings[i] = boxRing(b);
        refs[i] = &rings[i];
    }
    return layer(refs[0..boxes.len]);
}

fn area(l: *const ValidatedLayer) i128 {
    return fx.totalArea(l);
}

/// Same region: neither side has area the other lacks.
fn same(got: *const ValidatedLayer, want: *const ValidatedLayer) !void {
    var d = try fx.run(.not, got, want);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(i128, 0), area(&d));
    var e = try fx.run(.not, want, got);
    defer e.deinit(gpa);
    try testing.expectEqual(@as(i128, 0), area(&e));
}

fn sized(a: *const ValidatedLayer, by: i64) !ValidatedLayer {
    var out: ValidatedLayer = .empty;
    errdefer out.deinit(gpa);
    try derive.sizedInto(gpa, a, by, by, &out);
    return out;
}

/// The polygons of a layer as their boxes, sorted.
fn expectBoxes(got: *const ValidatedLayer, want: []const Box) !void {
    var list: std.ArrayList(Box) = .empty;
    defer list.deinit(gpa);
    for (got.bboxes()) |b| try list.append(gpa, .{ b.xlo, b.ylo, b.xhi, b.yhi });
    std.mem.sort(Box, list.items, {}, boxLess);
    try testing.expectEqualSlices(Box, want, list.items);
}

fn boxLess(_: void, a: Box, b: Box) bool {
    return std.mem.order(i64, &a, &b) == .lt;
}

/// An L: a vertical arm `[0,4]x[0,10]` and a horizontal arm `[0,10]x[0,arm]`.
fn lShape(arm: i64) !ValidatedLayer {
    return layer(&.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, arm }, .{ 4, arm }, .{ 4, 10 }, .{ 0, 10 } }});
}

/// `B` is one 10x10 square at the origin; each `A` square probes one
/// relation, named in the order the tests index them.
fn probes() ![2]ValidatedLayer {
    var b = try rects(&.{.{ 0, 0, 10, 10 }});
    errdefer b.deinit(gpa);
    const a = try rects(&.{
        .{ 6, 6, 9, 9 }, // 0: strictly inside
        .{ 0, 0, 5, 5 }, // 1: inside, sharing B's corner and two edges
        .{ 8, 2, 12, 4 }, // 2: straddles B's right edge
        .{ 10, 5, 14, 8 }, // 3: touches B's right edge from outside
        .{ 12, 12, 14, 14 }, // 4: far away (gap 2 from B's corner)
        .{ -4, 10, 0, 14 }, // 5: touches B's top-left corner only
        .{ -5, -5, 15, -2 }, // 6: below, gap 2
    });
    return .{ a, b };
}

fn seg(ax: i64, ay: i64, bx: i64, by: i64) Seg {
    return .{ .a = .{ .x = ax, .y = ay }, .b = .{ .x = bx, .y = by } };
}

fn expectSegs(got: []const Seg, want: []const Box) !void {
    var list: std.ArrayList(Box) = .empty;
    defer list.deinit(gpa);
    for (got) |s| try list.append(gpa, .{ s.a.x, s.a.y, s.b.x, s.b.y });
    std.mem.sort(Box, list.items, {}, boxLess);
    try testing.expectEqualSlices(Box, want, list.items);
}

fn length(v: []const Seg) i64 {
    var total: i64 = 0;
    for (v) |s| total += @as(i64, @intCast(@abs(s.b.x - s.a.x))) + @as(i64, @intCast(@abs(s.b.y - s.a.y)));
    return total;
}

fn edgesOf(l: *const ValidatedLayer, out: *std.ArrayList(Seg)) !void {
    try derive.edgesInto(gpa, l, out);
}

test "growing a square adds the distance on every side with square corners" {
    // Oracle: hand-derived. A 10 square grown by 2 with square corners is (-2,
    // -2)-(12, 12), area 14^2.
    var sq = try rects(&.{.{ 0, 0, 10, 10 }});
    defer sq.deinit(gpa);
    var grown = try sized(&sq, 2);
    defer grown.deinit(gpa);
    var want = try rects(&.{.{ -2, -2, 12, 12 }});
    defer want.deinit(gpa);
    try same(&grown, &want);
    try testing.expectEqual(@as(i128, 14 * 14), area(&grown));
}

test "sizing each axis by its own distance" {
    // Oracle: the Minkowski sum with, and erosion by, the box `[-dx, dx] x
    // [-dy, dy]` (`KLayout`'s `sized(dx, dy)`), worked by hand: a 10 x 6 box
    // grown by (2, 3) is 14 x 12; shrunk by (1, 2) it is 8 x 2; shrunk by (1, 3)
    // it is gone; and two boxes 4 apart across x merge when grown by (2, 0) but
    // not by (1, 0) or (0, 5).
    var box = try rects(&.{.{ 0, 0, 10, 6 }});
    defer box.deinit(gpa);
    var out: ValidatedLayer = .empty;
    defer out.deinit(gpa);
    try derive.sizedInto(gpa, &box, 2, 3, &out);
    var g = try rects(&.{.{ -2, -3, 12, 9 }});
    defer g.deinit(gpa);
    try same(&out, &g);
    try derive.sizedInto(gpa, &box, -1, -2, &out);
    var s = try rects(&.{.{ 1, 2, 9, 4 }});
    defer s.deinit(gpa);
    try same(&out, &s);
    try derive.sizedInto(gpa, &box, -1, -3, &out);
    try testing.expectEqual(@as(u32, 0), out.len());
    var pair = try rects(&.{ .{ 0, 0, 10, 6 }, .{ 14, 0, 24, 6 } });
    defer pair.deinit(gpa);
    try derive.sizedInto(gpa, &pair, 2, 0, &out);
    try testing.expectEqual(@as(u32, 1), out.len());
    try derive.sizedInto(gpa, &pair, 1, 0, &out);
    try testing.expectEqual(@as(u32, 2), out.len());
    try derive.sizedInto(gpa, &pair, 0, 5, &out);
    try testing.expectEqual(@as(u32, 2), out.len());
}

test "growing closes a gap no wider than twice the distance" {
    // Oracle: hand-derived. Growing each side by 2 closes a gap of 4 (the edges
    // meet) and leaves one of 5 open: one shape, then two.
    var four = try rects(&.{ .{ 0, 0, 10, 10 }, .{ 14, 0, 24, 10 } });
    defer four.deinit(gpa);
    var g4 = try sized(&four, 2);
    defer g4.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), g4.len());
    var five = try rects(&.{ .{ 0, 0, 10, 10 }, .{ 15, 0, 25, 10 } });
    defer five.deinit(gpa);
    var g5 = try sized(&five, 2);
    defer g5.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), g5.len());
}

test "shrinking deletes a shape no wider than twice the distance" {
    // Oracle: hand-derived. Shrinking by 2 from both sides empties a 4-wide bar
    // and leaves a 5-wide one its 1-wide core, (2, 2)-(3, 18).
    var bar4 = try rects(&.{.{ 0, 0, 4, 20 }});
    defer bar4.deinit(gpa);
    var s4 = try sized(&bar4, -2);
    defer s4.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), s4.len());
    var bar5 = try rects(&.{.{ 0, 0, 5, 20 }});
    defer bar5.deinit(gpa);
    var s5 = try sized(&bar5, -2);
    defer s5.deinit(gpa);
    var core = try rects(&.{.{ 2, 2, 3, 18 }});
    defer core.deinit(gpa);
    try same(&s5, &core);
}

test "shrinking a ring widens its hole" {
    // Oracle: hand-derived. A 20 ring with an 8..12 hole shrunk by 2 is the
    // 2..18 square less a 6..14 hole, area 16^2 - 8^2.
    const h = holeRing(.{ 8, 8, 12, 12 });
    var ring = try layer(&.{ &.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 20 }, .{ 0, 20 } }, &h });
    defer ring.deinit(gpa);
    var got = try sized(&ring, -2);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(i128, 16 * 16 - 8 * 8), area(&got));
    const wh = holeRing(.{ 6, 6, 14, 14 });
    var want = try layer(&.{ &.{ .{ 2, 2 }, .{ 18, 2 }, .{ 18, 18 }, .{ 2, 18 } }, &wh });
    defer want.deinit(gpa);
    try same(&got, &want);
}

test "shrink then grow keeps only the parts wider than twice the distance" {
    // Oracle: hand-derived, sky130's huge-metal idiom at 1: shrinking then growing
    // by 1 removes the 2-wide arm and keeps the 4-wide one, (0, 0)-(4, 10), area
    // 40; an L whose arms are all wider than 2 comes back exactly.
    var l2 = try lShape(2);
    defer l2.deinit(gpa);
    var s2 = try sized(&l2, -1);
    defer s2.deinit(gpa);
    var o2 = try sized(&s2, 1);
    defer o2.deinit(gpa);
    var arm = try rects(&.{.{ 0, 0, 4, 10 }});
    defer arm.deinit(gpa);
    try same(&o2, &arm);
    try testing.expectEqual(@as(i128, 40), area(&o2));
    var l3 = try lShape(3);
    defer l3.deinit(gpa);
    var s3 = try sized(&l3, -1);
    defer s3.deinit(gpa);
    var o3 = try sized(&s3, 1);
    defer o3.deinit(gpa);
    try same(&o3, &l3);
}

test "sizing past the coordinate domain is refused" {
    // Oracle: construct-from-answer. A rectangle ending one unit inside
    // `MAX_ABS_DBU` grown by 5 would leave the coordinate domain, so the only
    // correct answer is `OutOfRange`.
    var r = try rects(&.{.{ 0, 0, geom.max_abs_dbu - 1, 10 }});
    defer r.deinit(gpa);
    var out: ValidatedLayer = .empty;
    defer out.deinit(gpa);
    try testing.expectError(error.OutOfRange, derive.sizedInto(gpa, &r, 5, 5, &out));
}

test "interacting takes touching and overlapping shapes and a shared corner" {
    // Oracle: hand-derived, from `probes`: `KLayout`'s `interacting` takes every `A`
    // square that overlaps or touches `B`, a shared corner included (probes 0, 1,
    // 2, 3, 5), and leaves the two with a gap; the two selections partition `A`'s
    // area.
    var ab = try probes();
    defer for (&ab) |*l| l.deinit(gpa);
    var yes: ValidatedLayer = .empty;
    defer yes.deinit(gpa);
    var no: ValidatedLayer = .empty;
    defer no.deinit(gpa);
    try derive.interactingInto(gpa, &ab[0], &ab[1], true, &yes);
    try derive.interactingInto(gpa, &ab[0], &ab[1], false, &no);
    try expectBoxes(&yes, &.{ .{ -4, 10, 0, 14 }, .{ 0, 0, 5, 5 }, .{ 6, 6, 9, 9 }, .{ 8, 2, 12, 4 }, .{ 10, 5, 14, 8 } });
    try expectBoxes(&no, &.{ .{ -5, -5, 15, -2 }, .{ 12, 12, 14, 14 } });
    try testing.expectEqual(area(&ab[0]), area(&yes) + area(&no));
}

test "a shape in a hole does not interact but one over the ring does" {
    // Oracle: construct-from-answer. The island lies in the ring's hole, apart
    // from its material; the other square overlaps the ring's corner.
    const h = holeRing(.{ 5, 5, 15, 15 });
    var ring = try layer(&.{ &.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 20 }, .{ 0, 20 } }, &h });
    defer ring.deinit(gpa);
    var a = try rects(&.{ .{ 8, 8, 12, 12 }, .{ 18, -2, 22, 2 } });
    defer a.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.interactingInto(gpa, &a, &ring, true, &got);
    try expectBoxes(&got, &.{.{ 18, -2, 22, 2 }});
}

test "inside is covered by b and outside shares no area with it" {
    // Oracle: hand-derived, from `probes`: probes 0 and 1 lie in `B`, 3, 4, 5 and
    // 6 share no area with it, and the straddler, 4 x 2 of it, is neither.
    var ab = try probes();
    defer for (&ab) |*l| l.deinit(gpa);
    var inside: ValidatedLayer = .empty;
    defer inside.deinit(gpa);
    var outside: ValidatedLayer = .empty;
    defer outside.deinit(gpa);
    try derive.insideInto(gpa, &ab[0], &ab[1], &inside);
    try derive.outsideInto(gpa, &ab[0], &ab[1], &outside);
    try expectBoxes(&inside, &.{ .{ 0, 0, 5, 5 }, .{ 6, 6, 9, 9 } });
    try expectBoxes(&outside, &.{ .{ -5, -5, 15, -2 }, .{ -4, 10, 0, 14 }, .{ 10, 5, 14, 8 }, .{ 12, 12, 14, 14 } });
    // Only the straddler is neither.
    try testing.expectEqual(@as(i128, 4 * 2), area(&ab[0]) - area(&inside) - area(&outside));
}

test "a shape covered by two abutting shapes of b is inside" {
    // Oracle: construct-from-answer. The two halves of `B` abut to cover (0,
    // 0)-(10, 10), which holds `A` (2..8); `B` merged, `A` is inside.
    var b = try rects(&.{ .{ 0, 0, 5, 10 }, .{ 5, 0, 10, 10 } });
    defer b.deinit(gpa);
    var a = try rects(&.{.{ 2, 2, 8, 8 }});
    defer a.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.insideInto(gpa, &a, &b, &got);
    try testing.expectEqual(@as(u32, 1), got.len());
}

test "holes fill each hole and a hole holding an island covers it" {
    // Oracle: hand-derived. The outer ring's hole is 4..16, island included, so
    // `holes` is that square; a plain rectangle has none.
    const h1 = holeRing(.{ 4, 4, 16, 16 });
    const h2 = holeRing(.{ 9, 9, 11, 11 });
    var l = try layer(&.{ &.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 20 }, .{ 0, 20 } }, &h1, &.{ .{ 6, 6 }, .{ 14, 6 }, .{ 14, 14 }, .{ 6, 14 } }, &h2 });
    defer l.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.holesInto(gpa, &l, &got);
    var want = try rects(&.{.{ 4, 4, 16, 16 }});
    defer want.deinit(gpa);
    try same(&got, &want);
    var plain = try rects(&.{.{ 0, 0, 5, 5 }});
    defer plain.deinit(gpa);
    try derive.holesInto(gpa, &plain, &got);
    try testing.expectEqual(@as(u32, 0), got.len());
}

test "extents give each shape its own box" {
    // Oracle: hand-derived, with `KLayout`'s `extents` ("The boxes will not be
    // merged"): the L's box is 10 x 10, and the two Ls keep their own boxes, 100 +
    // 120 with the overlap counted twice.
    var l = try lShape(2);
    defer l.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.extentsInto(gpa, &l, &got);
    var want = try rects(&.{.{ 0, 0, 10, 10 }});
    defer want.deinit(gpa);
    try same(&got, &want);
    // Two disjoint Ls whose boxes overlap on [8, 10] x [4, 10].
    var two = try layer(&.{
        &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 2 }, .{ 2, 2 }, .{ 2, 10 }, .{ 0, 10 } },
        &.{ .{ 12, 4 }, .{ 20, 4 }, .{ 20, 14 }, .{ 8, 14 }, .{ 8, 12 }, .{ 18, 12 }, .{ 18, 6 }, .{ 12, 6 } },
    });
    defer two.deinit(gpa);
    try derive.extentsInto(gpa, &two, &got);
    try expectBoxes(&got, &.{ .{ 0, 0, 10, 10 }, .{ 8, 4, 20, 14 } });
    try testing.expectEqual(@as(i128, 100 + 120), area(&got));
}

test "with area selects on the area net of holes" {
    // Oracle: hand-derived areas in the comments: 4, 9, 16, and 16 - 4 = 12 for
    // the holed square, so `5..=9` keeps the 9 and the holed square is 12, not 16.
    var l = try rects(&.{ .{ 0, 0, 2, 2 }, .{ 10, 0, 13, 3 }, .{ 20, 0, 24, 4 }, .{ 30, 0, 34, 4 } });
    defer l.deinit(gpa);
    const h = holeRing(.{ 1, 1, 3, 3 });
    var holed = try layer(&.{ &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } }, &h });
    defer holed.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.withAreaInto(gpa, &l, 5, 9, &got);
    try expectBoxes(&got, &.{.{ 10, 0, 13, 3 }});
    try derive.withAreaInto(gpa, &holed, 12, 12, &got);
    try testing.expectEqual(@as(u32, 1), got.len());
    // The hole is not area.
    try derive.withAreaInto(gpa, &holed, 16, 16, &got);
    try testing.expectEqual(@as(u32, 0), got.len());
}

test "covering holds a whole shape and overlapping shares area" {
    // Oracle: `KLayout`'s `covering` and `overlapping` definitions, on four
    // 10 x 10 squares each drawn with one `b` shape: held inside, across the
    // edge, touching from outside, touching from inside. Covering takes the
    // first and the last; overlapping all but the one touched from outside,
    // which `outside` keeps.
    var a = try rects(&.{ .{ 0, 0, 10, 10 }, .{ 20, 0, 30, 10 }, .{ 40, 0, 50, 10 }, .{ 60, 0, 70, 10 } });
    defer a.deinit(gpa);
    var b = try rects(&.{ .{ 2, 2, 4, 4 }, .{ 28, 4, 32, 6 }, .{ 50, 4, 52, 6 }, .{ 60, 4, 62, 6 } });
    defer b.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.coveringInto(gpa, &a, &b, true, &got);
    try expectBoxes(&got, &.{ .{ 0, 0, 10, 10 }, .{ 60, 0, 70, 10 } });
    try derive.coveringInto(gpa, &a, &b, false, &got);
    try expectBoxes(&got, &.{ .{ 20, 0, 30, 10 }, .{ 40, 0, 50, 10 } });
    try derive.overlappingInto(gpa, &a, &b, true, &got);
    try expectBoxes(&got, &.{ .{ 0, 0, 10, 10 }, .{ 20, 0, 30, 10 }, .{ 60, 0, 70, 10 } });
    try derive.outsideInto(gpa, &a, &b, &got);
    try expectBoxes(&got, &.{.{ 40, 0, 50, 10 }});
}

test "rectangles and squares select holeless boxes" {
    // Oracle: `KLayout`'s `rectangles` / `squares` definition, on shapes drawn
    // to be or not be a box: a square, a 3 x 2 box, two abutting squares that
    // merge into a 4 x 2 box, a box one unit off square, an L, and a square with
    // a hole (no box). The `non_` forms are the complement.
    const h = holeRing(.{ 41, 1, 43, 3 });
    var l = try layer(&.{
        &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } },
        &.{ .{ 10, 0 }, .{ 13, 0 }, .{ 13, 2 }, .{ 10, 2 } },
        &.{ .{ 20, 0 }, .{ 22, 0 }, .{ 22, 2 }, .{ 20, 2 } },
        &.{ .{ 22, 0 }, .{ 24, 0 }, .{ 24, 2 }, .{ 22, 2 } },
        &.{ .{ 30, 0 }, .{ 33, 0 }, .{ 33, 4 }, .{ 30, 4 } },
        &.{ .{ 30, 10 }, .{ 34, 10 }, .{ 34, 13 }, .{ 30, 13 } },
        &.{ .{ 50, 0 }, .{ 54, 0 }, .{ 54, 2 }, .{ 52, 2 }, .{ 52, 4 }, .{ 50, 4 } },
        &.{ .{ 40, 0 }, .{ 44, 0 }, .{ 44, 4 }, .{ 40, 4 } },
        &h,
    });
    defer l.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.rectanglesInto(gpa, &l, false, true, &got);
    try expectBoxes(&got, &.{ .{ 0, 0, 2, 2 }, .{ 10, 0, 13, 2 }, .{ 20, 0, 24, 2 }, .{ 30, 0, 33, 4 }, .{ 30, 10, 34, 13 } });
    try derive.rectanglesInto(gpa, &l, false, false, &got);
    try expectBoxes(&got, &.{ .{ 40, 0, 44, 4 }, .{ 50, 0, 54, 4 } });
    try derive.rectanglesInto(gpa, &l, true, true, &got);
    try expectBoxes(&got, &.{.{ 0, 0, 2, 2 }});
    // Every shape but the square.
    try derive.rectanglesInto(gpa, &l, true, false, &got);
    try testing.expectEqual(@as(u32, 6), got.len());
}

test "with rect selects the shapes a box fits either way round" {
    // Oracle: hand-derived. A 60 x 20 box, either way round and its boundary
    // allowed on the polygon's, fits the 100 x 50 box lying down, the 20 x 70
    // box only stood up (exactly, side to side), and the L in its 20-wide,
    // 100-long foot; it fits neither the 30 x 30 square nor the 19 x 70 box,
    // one unit too narrow. `keep` takes the first three, `!keep` the others.
    var l = try layer(&.{
        &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 50 }, .{ 0, 50 } },
        &.{ .{ 200, 0 }, .{ 230, 0 }, .{ 230, 30 }, .{ 200, 30 } },
        &.{ .{ 300, 0 }, .{ 320, 0 }, .{ 320, 70 }, .{ 300, 70 } },
        &.{ .{ 400, 0 }, .{ 419, 0 }, .{ 419, 70 }, .{ 400, 70 } },
        &.{ .{ 500, 0 }, .{ 600, 0 }, .{ 600, 20 }, .{ 520, 20 }, .{ 520, 100 }, .{ 500, 100 } },
    });
    defer l.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.withRectInto(gpa, &l, 60, 20, true, &got);
    try expectBoxes(&got, &.{ .{ 0, 0, 100, 50 }, .{ 300, 0, 320, 70 }, .{ 500, 0, 600, 100 } });
    try derive.withRectInto(gpa, &l, 60, 20, false, &got);
    try expectBoxes(&got, &.{ .{ 200, 0, 230, 30 }, .{ 400, 0, 419, 70 } });
}

test "with width selects on the narrowest width" {
    // Oracle: hand-derived. The L's narrowest width is its 2-wide arm and the bar
    // is 3 wide; the ranges are on twice the square (`>= 3` is `18..`, `<= 2`
    // `..=8`).
    var l = try layer(&.{ &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 2 }, .{ 4, 2 }, .{ 4, 10 }, .{ 0, 10 } }, &.{ .{ 20, 0 }, .{ 23, 0 }, .{ 23, 10 }, .{ 20, 10 } } });
    defer l.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.withWidthInto(gpa, &l, 18, max_i128, &got);
    try expectBoxes(&got, &.{.{ 20, 0, 23, 10 }});
    try derive.withWidthInto(gpa, &l, 0, 8, &got);
    try expectBoxes(&got, &.{.{ 0, 0, 10, 10 }});
}

test "with width counts the diagonal neck width measures" {
    // Oracle: hand-derived. The concave corners (10, 8) and (8, 10) are sqrt(8)
    // apart, 8 squared exactly (16 twice), so the neck is in `10..` and `..=18`
    // and in neither `..=8` nor `18..` (F65; the ranges are on twice the square).
    // Every facing pair is 10 apart; a floor to 2 would put the neck in `<= 2`.
    var plates = try rects(&.{ .{ 0, 0, 10, 10 }, .{ 8, 8, 18, 18 } });
    defer plates.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.withWidthInto(gpa, &plates, 10, max_i128, &got);
    try expectBoxes(&got, &.{.{ 0, 0, 18, 18 }});
    try derive.withWidthInto(gpa, &plates, 0, 18, &got);
    try expectBoxes(&got, &.{.{ 0, 0, 18, 18 }});
    try derive.withWidthInto(gpa, &plates, 0, 8, &got);
    try testing.expectEqual(@as(u32, 0), got.len());
    try derive.withWidthInto(gpa, &plates, 18, max_i128, &got);
    try testing.expectEqual(@as(u32, 0), got.len());
}

test "a neck past two to the 53 is floored exactly" {
    // Oracle: closed form, worked in the comment: the neck squared is n^2 - 1 for
    // n = 98 000 001, whose integer root is n - 1, at the midpoint of the two
    // corners. Plates overlapping 98_000_000 x 14_000 at a corner: the concave
    // corners (198_000_000, 200_000_000) and (100_000_000, 200_014_000) are
    // sqrt(98e6² + 14e3²) apart, squared n² - 1, past 2^53; an f64 root rounds
    // it to n.
    var plates = try rects(&.{ .{ 0, 0, 198_000_000, 200_014_000 }, .{ 100_000_000, 200_000_000, 400_000_000, 400_000_000 } });
    defer plates.deinit(gpa);
    const n = (try geom.width.narrowestNeck(gpa, plates.get(0), 98_000_001)).?;
    try testing.expectEqual(@as(i64, 98_000_000), n.gap);
    try testing.expectEqual(geom.Point{ .x = 149_000_000, .y = 200_007_000 }, n.at);
}

test "edges run counter clockwise round an outer with material on the left" {
    // Oracle: hand-derived. The 10 square's four edges, counter-clockwise from the
    // origin, each with the material on its left.
    var sq = try rects(&.{.{ 0, 0, 10, 10 }});
    defer sq.deinit(gpa);
    var e: std.ArrayList(Seg) = .empty;
    defer e.deinit(gpa);
    try edgesOf(&sq, &e);
    try expectSegs(e.items, &.{ .{ 0, 0, 10, 0 }, .{ 0, 10, 0, 0 }, .{ 10, 0, 10, 10 }, .{ 10, 10, 0, 10 } });
}

test "butting edges are the coincident parts and booleans split length" {
    // Oracle: hand-derived. `B` butts `A`'s right edge along y 5..10: `and` is
    // that 5, `not` the other 35 of `A`'s 40, `or` 80 - 5.
    var la = try rects(&.{.{ 0, 0, 10, 10 }});
    defer la.deinit(gpa);
    var lb = try rects(&.{.{ 10, 5, 20, 15 }});
    defer lb.deinit(gpa);
    var a: std.ArrayList(Seg) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(Seg) = .empty;
    defer b.deinit(gpa);
    try edgesOf(&la, &a);
    try edgesOf(&lb, &b);
    var out: std.ArrayList(Seg) = .empty;
    defer out.deinit(gpa);
    try derive.edgeBooleanInto(gpa, a.items, b.items, .@"and", &out);
    // A's direction, up.
    try expectSegs(out.items, &.{.{ 10, 5, 10, 10 }});
    try derive.edgeBooleanInto(gpa, a.items, b.items, .not, &out);
    try testing.expectEqual(@as(i64, 40 - 5), length(out.items));
    // The shared part counted once.
    try derive.edgeBooleanInto(gpa, a.items, b.items, .@"or", &out);
    try testing.expectEqual(@as(i64, 40 + 40 - 5), length(out.items));
}

test "edge parts split at the other layers boundary and the boundary is neither" {
    // Oracle: hand-derived. `over` covers x 5..15, so the inside part is the right
    // halves of the bottom and top and the whole right edge; the outside part is
    // 5 + 5 + 10. A butting square takes the right edge from both, leaving
    // 30 outside.
    var la = try rects(&.{.{ 0, 0, 10, 10 }});
    defer la.deinit(gpa);
    var a: std.ArrayList(Seg) = .empty;
    defer a.deinit(gpa);
    try edgesOf(&la, &a);
    var over = try rects(&.{.{ 5, -5, 15, 15 }});
    defer over.deinit(gpa);
    var inside: std.ArrayList(Seg) = .empty;
    defer inside.deinit(gpa);
    var outside: std.ArrayList(Seg) = .empty;
    defer outside.deinit(gpa);
    try derive.edgePartInto(gpa, a.items, &over, true, &inside);
    try derive.edgePartInto(gpa, a.items, &over, false, &outside);
    try expectSegs(inside.items, &.{ .{ 5, 0, 10, 0 }, .{ 10, 0, 10, 10 }, .{ 10, 10, 5, 10 } });
    try testing.expectEqual(@as(i64, 5 + 5 + 10), length(outside.items));
    // Butting: A's right edge lies on B's boundary, so it is in neither part.
    var butt = try rects(&.{.{ 10, 0, 20, 10 }});
    defer butt.deinit(gpa);
    try derive.edgePartInto(gpa, a.items, &butt, true, &inside);
    try derive.edgePartInto(gpa, a.items, &butt, false, &outside);
    try testing.expectEqual(@as(usize, 0), inside.items.len);
    try testing.expectEqual(@as(i64, 30), length(outside.items));
}

test "extended edges grow a box before their start and away from their shape" {
    // Oracle: `KLayout`'s `extended(begin, end, out, in)`, worked by hand on a
    // 10 x 4 rectangle's counter-clockwise edges: each lengthened by 1 before
    // the corner it leaves and widened by 2 away from the rectangle, one box per
    // edge, unmerged.
    var r = try rects(&.{.{ 0, 0, 10, 4 }});
    defer r.deinit(gpa);
    var e: std.ArrayList(Seg) = .empty;
    defer e.deinit(gpa);
    try edgesOf(&r, &e);
    var out: ValidatedLayer = .empty;
    defer out.deinit(gpa);
    try derive.extendedInto(gpa, e.items, .{ .begin = 1, .end = 0, .outside = 2, .inside = 0 }, &out);
    try expectBoxes(&out, &.{ .{ -2, 0, 0, 5 }, .{ -1, -2, 10, 0 }, .{ 0, 4, 11, 6 }, .{ 10, -1, 12, 4 } });
}

test "edge interacting takes whole edges that touch and with length filters" {
    // Oracle: hand-derived. Each segment's relation to `B` is in its comment:
    // crossing, along the edge and inside interact, the far one does not; only the
    // 5-long segment is in `5..=9`.
    const a = [_]Seg{
        seg(0, 0, 10, 0), // crosses B
        seg(20, 0, 20, 5), // runs along B's right edge
        seg(12, 1, 12, 3), // inside B
        seg(30, 0, 30, 10), // far away
    };
    var b = try rects(&.{.{ 5, -2, 20, 4 }});
    defer b.deinit(gpa);
    var yes: std.ArrayList(Seg) = .empty;
    defer yes.deinit(gpa);
    var no: std.ArrayList(Seg) = .empty;
    defer no.deinit(gpa);
    try derive.edgeInteractingInto(gpa, &a, &b, true, &yes);
    try derive.edgeInteractingInto(gpa, &a, &b, false, &no);
    try expectSegs(yes.items, &.{ .{ 0, 0, 10, 0 }, .{ 12, 1, 12, 3 }, .{ 20, 0, 20, 5 } });
    try expectSegs(no.items, &.{.{ 30, 0, 30, 10 }});
    var kept: std.ArrayList(Seg) = .empty;
    defer kept.deinit(gpa);
    try derive.withLengthInto(gpa, &a, 5, 9, &kept);
    try expectSegs(kept.items, &.{.{ 20, 0, 20, 5 }});
}

test "intersection and difference split area" {
    // Oracle: law. `area(A and B) + area(A not B) = area(A)`, on the `probes`
    // operands.
    var ab = try probes();
    defer for (&ab) |*l| l.deinit(gpa);
    var meet = try fx.run(.@"and", &ab[0], &ab[1]);
    defer meet.deinit(gpa);
    var diff = try fx.run(.not, &ab[0], &ab[1]);
    defer diff.deinit(gpa);
    try testing.expectEqual(area(&ab[0]), area(&meet) + area(&diff));
}

test "a diamond sizes by the square both ways" {
    // Oracle: hand-derived Minkowski sums with the square `[-1, 1]²`. The
    // radius-10 diamond (area 200) grows to the octagon inside the 22-square
    // less four corner triangles of legs 10 (`484 - 4·50 = 284`), and erodes to
    // the radius-8 diamond (`2·8² = 128`): the square moves each diagonal edge
    // 1 in x and 1 in y.
    var d = try octLayer(&.{diamond});
    defer d.deinit(gpa);
    var got: ValidatedLayer = .empty;
    defer got.deinit(gpa);
    try derive.sizedInto(gpa, &d, 1, 1, &got);
    try testing.expectEqual(@as(i128, 284), area(&got));
    try expectBoxes(&got, &.{.{ -11, -11, 11, 11 }});
    try derive.sizedInto(gpa, &d, -1, -1, &got);
    try testing.expectEqual(@as(i128, 128), area(&got));
    try expectBoxes(&got, &.{.{ -8, -8, 8, 8 }});
}

test "diagonal edges measure and split exactly" {
    // Oracle: hand-derived. A diamond's edges are its four diagonals, material
    // on the left, each `10·√2 ≈ 14.14` long, so `14..=15` keeps all four and
    // `15..` and `..=14` none. A box over `x ≥ 2` holds the parts of the right
    // two edges from `x = 2`.
    var d = try octLayer(&.{diamond});
    defer d.deinit(gpa);
    var all: std.ArrayList(Seg) = .empty;
    defer all.deinit(gpa);
    try edgesOf(&d, &all);
    try expectSegs(all.items, &.{ .{ -10, 0, 0, -10 }, .{ 0, -10, 10, 0 }, .{ 0, 10, -10, 0 }, .{ 10, 0, 0, 10 } });
    var kept: std.ArrayList(Seg) = .empty;
    defer kept.deinit(gpa);
    try derive.withLengthInto(gpa, all.items, 14, 15, &kept);
    try testing.expectEqual(@as(usize, 4), kept.items.len);
    try derive.withLengthInto(gpa, all.items, 15, max_i128, &kept);
    try testing.expectEqual(@as(usize, 0), kept.items.len);
    try derive.withLengthInto(gpa, all.items, 0, 14, &kept);
    try testing.expectEqual(@as(usize, 0), kept.items.len);
    var right = try rects(&.{.{ 2, -20, 20, 20 }});
    defer right.deinit(gpa);
    var inside: std.ArrayList(Seg) = .empty;
    defer inside.deinit(gpa);
    try derive.edgePartInto(gpa, all.items, &right, true, &inside);
    try expectSegs(inside.items, &.{ .{ 2, -8, 10, 0 }, .{ 10, 0, 2, 8 } });
}

test "an edge cut between grid points ends on the grid inside its part" {
    // Oracle: hand-derived, and the snapping rule of `boolean::union_into`
    // applied to an edge. The rising edge (0, 0)-(10, 10) meets the falling
    // boundary `x + y = 7` of the other layer at (3.5, 3.5), between grid
    // points; each part ends at the last grid point inside it.
    const a = [_]Seg{seg(0, 0, 10, 10)};
    var b = try octLayer(&.{&.{ .{ 7, 0 }, .{ 30, 0 }, .{ 30, 30 }, .{ 0, 30 }, .{ 0, 7 } }});
    defer b.deinit(gpa);
    var inside: std.ArrayList(Seg) = .empty;
    defer inside.deinit(gpa);
    var outside: std.ArrayList(Seg) = .empty;
    defer outside.deinit(gpa);
    try derive.edgePartInto(gpa, &a, &b, true, &inside);
    try derive.edgePartInto(gpa, &a, &b, false, &outside);
    try expectSegs(inside.items, &.{.{ 4, 4, 10, 10 }});
    try expectSegs(outside.items, &.{.{ 0, 0, 3, 3 }});
}

test "octilinear selections read whole shapes" {
    // Oracle: hand-derived selections. A diamond under a covering square is
    // `inside` it and not `outside`; a square far off is the reverse; and
    // `interacting` finds the diamond, whose right vertex a small square's
    // corner touches.
    var a = try octLayer(&.{ diamond, &.{ .{ 40, 0 }, .{ 50, 0 }, .{ 50, 10 }, .{ 40, 10 } } });
    defer a.deinit(gpa);
    var cover = try rects(&.{.{ -10, -10, 10, 10 }});
    defer cover.deinit(gpa);
    var inside: ValidatedLayer = .empty;
    defer inside.deinit(gpa);
    var outside: ValidatedLayer = .empty;
    defer outside.deinit(gpa);
    try derive.insideInto(gpa, &a, &cover, &inside);
    try derive.outsideInto(gpa, &a, &cover, &outside);
    try expectBoxes(&inside, &.{.{ -10, -10, 10, 10 }});
    try expectBoxes(&outside, &.{.{ 40, 0, 50, 10 }});
    var corner = try rects(&.{.{ 10, 0, 12, 2 }});
    defer corner.deinit(gpa);
    var touching: ValidatedLayer = .empty;
    defer touching.deinit(gpa);
    try derive.interactingInto(gpa, &a, &corner, true, &touching);
    try expectBoxes(&touching, &.{.{ -10, -10, 10, 10 }});
}
