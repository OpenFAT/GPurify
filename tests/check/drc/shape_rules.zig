//! Per-shape kinds of the grid family read from deck text:
//! `min_interior_angle`, `polygon_validity`, `origin`, and `forbidden`.
//! Ported from crates/check/tests/drc/shape_rules.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;
const Finding = common.Finding;
const Layout = common.Layout;
const Measurement = check.report.Measurement;

const angle_rules = "rule r interior_angle(met1) >= 90deg\nrule ihp interior_angle() >= 87deg";

// ---- private ----

fn check2(name: []const u8, text: []const u8, layout: Layout, ids: []const []const u8, claims: []const struct { []const u8, Finding }) !void {
    var l = layout;
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try common.checkEverywhere(name, text, &l, try common.byRule(arena.allocator(), ids, claims));
}

fn poly(layer: []const u8, points: []const [2]i64) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    try l.polygon(layer, points);
    return l;
}

test "right and reflex corners are legal" {
    // Oracle: angles fixed by construction. A rectangle (90 at a limit of 90:
    // legal), an L (its inner corner 270), a ring (its hole, a clockwise row,
    // has corners of 270 on the shape's side; one reading the hole's own
    // inside would see 90, legal too, but one taking the smaller angle of a
    // corner flags the L), an octagon (135): nothing under either rule.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.newDeck(arena.allocator(), &.{ "met1", "met2" }, angle_rules);
    const none = &.{ "r", "ihp" };
    try check2("rectangle", text, try common.met1(&.{.{ 0, 0, 1000, 500 }}), none, &.{});
    try check2("l_shape", text, try common.met1(&.{ .{ 0, 0, 1000, 100 }, .{ 0, 100, 100, 1000 } }), none, &.{});
    var ring = try common.met1(&.{.{ 0, 0, 1000, 1000 }});
    try ring.polygon("met1", &.{ .{ 300, 300 }, .{ 300, 700 }, .{ 700, 700 }, .{ 700, 300 } });
    try check2("ring", text, ring, none, &.{});
    try check2("octagon", text, try poly("met1", &.{ .{ 100, 0 }, .{ 900, 0 }, .{ 1000, 100 }, .{ 1000, 900 }, .{ 900, 1000 }, .{ 100, 1000 }, .{ 0, 900 }, .{ 0, 100 } }), none, &.{});
}

test "acute corners are reported at their vertices" {
    // Oracle: angles fixed by construction. A right isosceles triangle has
    // two 45-degree corners (exactly 45 once rounded), under both limits,
    // each at its vertex; a 30-60-90 triangle's two acute corners (30 and
    // 60) are under both too. On `met2` the triangle is read only by the
    // every-layer rule.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.newDeck(arena.allocator(), &.{ "met1", "met2" }, angle_rules);
    const triangle = [_][2]i64{ .{ 0, 0 }, .{ 1000, 0 }, .{ 0, 1000 } };
    const f45a = Finding.ratio(45.0).atPoint(1000, 0);
    const f45b = Finding.ratio(45.0).atPoint(0, 1000);
    try check2("right_triangle", text, try poly("met1", &triangle), &.{ "r", "ihp" }, &.{ .{ "r", f45a }, .{ "r", f45b }, .{ "ihp", f45a }, .{ "ihp", f45b } });
    const t1 = Finding.any().atPoint(1732, 0);
    const t2 = Finding.any().atPoint(0, 1000);
    try check2("thirty_sixty", text, try poly("met1", &.{ .{ 0, 0 }, .{ 1732, 0 }, .{ 0, 1000 } }), &.{ "r", "ihp" }, &.{ .{ "r", t1 }, .{ "r", t2 }, .{ "ihp", t1 }, .{ "ihp", t2 } });
    try check2("other_layer", text, try poly("met2", &triangle), &.{ "r", "ihp" }, &.{ .{ "ihp", f45a }, .{ "ihp", f45b } });
}

test "an angle at the limit is legal" {
    // Oracle: an angle just under and at the limit. A triangle with a corner
    // of exactly 90 at (0, 0) and the other two at 45 is reported only at the
    // two 45s under `>= 46deg`; under `>= 45deg` nothing (45 is at the
    // limit).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.newDeck(arena.allocator(), &.{ "met1", "met2" }, "rule a interior_angle(met1) >= 45deg\nrule b interior_angle(met1) >= 46deg");
    try check2("limit", text, try poly("met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 0, 1000 } }), &.{ "a", "b" }, &.{ .{ "b", Finding.ratio(45.0).atPoint(1000, 0) }, .{ "b", Finding.ratio(45.0).atPoint(0, 1000) } });
}

test "polygon validity reports crossing and degenerate rings" {
    // Oracle: polygons drawn with the defect by construction: a ring
    // crossing itself and a ring doubling back on itself (zero area) are one
    // finding each (measured 0 against 1); a rectangle and a 45-degree
    // triangle are valid. `valid(met1)` reads met1 only, `valid()` every
    // drawn layer.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.newDeck(arena.allocator(), &.{ "met1", "met2" }, "rule v valid(met1)\nrule all valid()");
    const crossing = [_][2]i64{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 2000 }, .{ 1000, 2000 }, .{ 1000, -1000 }, .{ 0, -1000 } };
    const ids = &.{ "v", "all" };
    const both = &.{ .{ "v", Finding.count(0) }, .{ "all", Finding.count(0) } };
    const extra = [4]i64{ 5000, 5000, 6000, 6000 };
    var l1 = try poly("met1", &crossing);
    try l1.rects("met1", &.{extra});
    try check2("self_crossing", text, l1, ids, both);
    var l2 = try poly("met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 500, 0 } });
    try l2.rects("met1", &.{extra});
    try check2("zero_area", text, l2, ids, both);
    var l3 = try common.met1(&.{.{ 0, 0, 1000, 500 }});
    try l3.polygon("met1", &.{ .{ 2000, 0 }, .{ 3000, 0 }, .{ 2000, 1000 } });
    try l3.rects("met1", &.{extra});
    try check2("valid_shapes", text, l3, ids, &.{});
    var l4 = try poly("met2", &crossing);
    try l4.rects("met1", &.{extra});
    try check2("other_layer", text, l4, ids, &.{.{ "all", Finding.count(0) }});
}

test "origin measures the lower left corner s distance from the origin" {
    // Oracle: the image of the seal ring's box under each symmetry about the
    // origin: its lower-left corner and that corner's distance from the
    // origin (3, 4 is 5; 1, 0 is 1), one finding there unless it is
    // `(0, 0)`. The rule is anchored on the origin, so each placement's
    // expectation is computed, not mapped: only the unturned ring drawn from
    // the origin passes, and a rule reading any corner other than the box's
    // lower left breaks a turned case. `examined` counts the ring's four
    // rows.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.newDeck(arena.allocator(), &.{ "seal", "met1" }, "rule x.19 origin(seal)");
    for ([_][2]i64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 3, 4 } }) |d| {
        const dx = d[0];
        const dy = d[1];
        var drawn: Layout = .{};
        defer drawn.deinit();
        try drawn.rect("met1", dx + 500, dy + 500, dx + 600, dy + 600);
        try drawn.rects("seal", &.{ .{ dx, dy, dx + 4000, dy + 100 }, .{ dx, dy + 3900, dx + 4000, dy + 4000 }, .{ dx, dy + 100, dx + 100, dy + 3900 }, .{ dx + 3900, dy + 100, dx + 4000, dy + 3900 } });
        for (common.symmetries) |s| {
            var x: i64 = std.math.maxInt(i64);
            var y: i64 = std.math.maxInt(i64);
            for ([_][2]i64{ .{ dx, dy }, .{ dx + 4000, dy }, .{ dx, dy + 4000 }, .{ dx + 4000, dy + 4000 } }) |p| {
                const q = common.apply(s, p);
                x = @min(x, q[0]);
                y = @min(y, q[1]);
            }
            var moved = try drawn.transformed(s, 0, 0);
            defer moved.deinit();
            var r = try common.run(text, &moved);
            defer r.deinit();
            try testing.expectEqual(@as(usize, 1), r.rows.len);
            const row = r.rows[0];
            try testing.expectEqualStrings("x.19", row.id);
            try testing.expectEqual(check.report.Outcome.ran, row.outcome);
            try testing.expectEqual(@as(u64, 4), row.examined);
            if (x == 0 and y == 0) {
                try testing.expectEqual(@as(usize, 0), row.findings.len);
            } else {
                try testing.expectEqual(@as(usize, 1), row.findings.len);
                try testing.expectEqual(Measurement.length(common.floorSqrt(x * x + y * y)), row.findings[0].measured);
                try testing.expectEqual([2]i64{ x, y }, row.findings[0].at);
            }
        }
    }
    // An empty seal layer is skipped, not passed.
    var empty = try common.met1(&.{.{ 0, 0, 10, 10 }});
    defer empty.deinit();
    var r = try common.run(text, &empty);
    defer r.deinit();
    try testing.expect(r.rows[0].outcome == .skipped);
}

test "forbidden reports each drawn shape with its area" {
    // Oracle: `Rule::Forbidden`'s definition (shapes as the store holds
    // them, not merged; area with holes excluded), areas by hand: two
    // overlapping 100 squares are two findings of 10000, and so are two
    // abutting ones; a 1000 square with a 200 square hole (a clockwise row)
    // is one of 1000000 - 40000 = 960000; a shape on another layer is none.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.newDeck(arena.allocator(), &.{ "met1", "met2" }, "rule f forbidden(met2)");
    const ten = &.{ .{ "f", Finding.area(10_000) }, .{ "f", Finding.area(10_000) } };
    try check2("overlapping_drawn", text, try common.layoutOf("met2", &.{ .{ 0, 0, 100, 100 }, .{ 50, 0, 150, 100 } }), &.{"f"}, ten);
    try check2("abutting_drawn", text, try common.layoutOf("met2", &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } }), &.{"f"}, ten);
    var holed = try common.layoutOf("met2", &.{.{ 0, 0, 1000, 1000 }});
    try holed.polygon("met2", &.{ .{ 400, 400 }, .{ 400, 600 }, .{ 600, 600 }, .{ 600, 400 } });
    try check2("holed", text, holed, &.{"f"}, &.{.{ "f", Finding.area(960_000) }});
    try check2("other_layer_only", text, try common.met1(&.{.{ 0, 0, 100, 100 }}), &.{"f"}, &.{});
}
