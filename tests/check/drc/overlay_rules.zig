//! Overlay family: `min_enclosure`, `asymmetric_enclosure`, `min_extension`,
//! `overlap`, `max_distance_to_tap`, `gate_corner`, `max_enclosure`,
//! `full_width`, `adjacent_enclosure`. Ported from
//! crates/check/tests/drc/overlay_rules.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const Sink = common.Sink;
const gpa = common.gpa;
const A = common.a;
const B = common.b;
const RULE = common.rule_id;
const Rule = check.drc.Rule;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const ViolationCase = testgen.violation.ViolationCase;
const no_shape = check.report.no_shape;

/// The eight symmetries of the square, as maps of the plane.
const Map = *const fn (i64, i64) [2]i64;

/// A cut whose li steps along its sides (sky130 `a2111oi_1`'s licon).
const stepped = [_]LayerBox{ .{ .layer = 0, .box = .{ 0, 0, 170, 170 } }, .{ .layer = 1, .box = .{ -75, -100, 255, 100 } }, .{ .layer = 1, .box = .{ -900, 100, 1000, 235 } } };

const LayerBox = struct { layer: u16, box: [4]i64 };

const maps = [8]Map{
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ x, y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -y, x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -x, -y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ y, -x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -x, y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ x, -y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ y, x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -y, -x };
        }
    }.f,
};

// ---- private ----

fn run1(sink: *Sink, store: *const geom.GeometryStore, rule: Rule) !void {
    try common.runRules(sink, store, &common.single(rule));
}

fn minEnc(limit: i64) Rule {
    return .{ .min_enclosure = .{ .outer = B, .inner = A, .limit = limit } };
}

fn asym(limit: i64) Rule {
    return .{ .asymmetric_enclosure = .{ .outer = B, .inner = A, .limit = limit } };
}

fn adjacent(limit: i64) Rule {
    return .{ .adjacent_enclosure = .{ .outer = B, .inner = A, .limit = limit } };
}

fn tap(limit: i64) Rule {
    return .{ .max_distance_to_tap = .{ .well = A, .tap = B, .limit = limit } };
}

fn enclosureCase(enclosure: i64, limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .enclosure = .{ .outer = B, .inner = A, .inner_size = 100 } } }, .{ 0, 0 }, .{ .length = enclosure }, .{ .length = limit });
}

fn extensionCase(extension: i64, limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .extension = .{ .line = A, .crossed = B, .width = 100 } } }, .{ 0, 0 }, .{ .length = extension }, .{ .length = limit });
}

fn overlapCase(overlap: i64, limit: i64) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .overlap = .{ .a = A, .b = B, .extent = 400 } } }, .{ 0, 0 }, .{ .length = overlap }, .{ .length = limit });
}

/// Margins 40 left, 60 right, 100 bottom and top; inner, then outer.
fn twoSided(lb: *LayoutBuilder) ![2]testgen.shapes.Handle {
    return .{ try lb.rect(gpa, 0, 100, 100, 200, 200), try lb.rect(gpa, 1, 60, 0, 260, 300) };
}

/// The L via: lower arm [0, 200] x [0, 100], upper arm [0, 100] x [100, 200].
fn lVia(lb: *LayoutBuilder) !testgen.shapes.Handle {
    return lb.push(gpa, 0, &.{ 0, 200, 200, 100, 100, 0 }, &.{ 0, 0, 100, 100, 200, 200 });
}

/// `boxes` under map `m`, run under `rule`: each finding's measured length.
fn runTransformed(m: Map, boxes: []const LayerBox, rule: Rule, out: *std.ArrayList(i128)) !void {
    var lb = LayoutBuilder.init(2);
    for (boxes) |lbx| {
        const p = m(lbx.box[0], lbx.box[1]);
        const q = m(lbx.box[2], lbx.box[3]);
        _ = try lb.rect(gpa, lbx.layer, @min(p[0], q[0]), @min(p[1], q[1]), @max(p[0], q[0]), @max(p[1], q[1]));
    }
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, rule);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    out.clearRetainingCapacity();
    for (0..sink.out.len()) |k| try out.append(gpa, sink.out.get(@intCast(k)).measured.exact());
}

fn expectOnly(case: *const ViolationCase, rule: Rule) !Sink {
    var sink: Sink = .{};
    errdefer sink.deinit();
    try run1(&sink, &case.store, rule);
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    return sink;
}

fn length(sink: *const Sink, k: u32) i128 {
    return sink.out.get(k).measured.exact();
}

test "an enclosure one unit under the limit is reported on the deficient margin" {
    // Oracle: construct-from-answer. The host clears the inner square by 40
    // on its left and a full width elsewhere: 41 fails it by one, at the
    // deficient margin's midpoint, on the inner layer.
    var case = try enclosureCase(40, 41);
    defer case.deinit(gpa);
    var sink = try expectOnly(&case, minEnc(41));
    defer sink.deinit();
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 1), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "an inner shape in a concave host's notch is not enclosed by it" {
    // Oracle: construct-from-answer, and the `bbox_only_enclosure` defect: a
    // square in an L's notch is inside its box and outside the L: enclosure
    // 0, at its own centre (290, 290), no host.
    var lb = LayoutBuilder.init(2);
    _ = try lb.shape(gpa, 1, testgen.shapes.lShape(0, 0, 400, 200));
    const stranded = try lb.rect(gpa, 0, 250, 250, 330, 330);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(10));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 290, .y = 290 }, .measured = .length(0), .limit = .length(10), .shape_a = built.of(stranded), .shape_b = no_shape });
}

test "an inner shape inside a concave host's arm is enclosed by it" {
    // Oracle: construct-from-answer. The square clears the arm by 50 above
    // and below and more from either end: 50 is met.
    var lb = LayoutBuilder.init(2);
    _ = try lb.shape(gpa, 1, testgen.shapes.lShape(0, 0, 400, 200));
    _ = try lb.rect(gpa, 0, 250, 50, 330, 150);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(50));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a bar bridging a host's opening is not enclosed though its corners are" {
    // Oracle: construct-from-answer. The bar's middle lies over the U's
    // opening, outside the host: one violation, measuring 0.
    var lb = LayoutBuilder.init(2);
    _ = try lb.push(gpa, 1, &.{ 0, 400, 400, 300, 300, 100, 100, 0 }, &.{ 0, 0, 500, 500, 100, 100, 500, 500 });
    _ = try lb.rect(gpa, 0, 50, 200, 350, 300);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(10));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 0), length(&sink, 0));
}

test "an enclosure exactly at the limit is clean" {
    // Oracle: construct-from-answer. Drawn at exactly the 40 limit.
    var case = try enclosureCase(40, 40);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, minEnc(40));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an inner shape with no host has an enclosure of zero not no enclosure" {
    // Oracle: construct-from-answer. A via with no metal under it has an
    // enclosure of zero and fails.
    var lb = LayoutBuilder.init(2);
    const orphan = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 1, 5_000, 5_000, 6_000, 6_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(40));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 0), length(&sink, 0));
    try testing.expectEqual(A, sink.out.get(0).layer);
    try testing.expectEqual(built.of(orphan), sink.out.get(0).shape_a);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an inner shape inside two hosts is judged by the better of them" {
    // Oracle: construct-from-answer. After the outer layer is merged there
    // is one host, the union, enclosing the square by 100.
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 1_000, 1_000, 1_100, 1_100);
    _ = try lb.rect(gpa, 1, 1_010, 1_010, 1_090, 1_090);
    _ = try lb.rect(gpa, 1, 900, 900, 1_200, 1_200);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(100));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an asymmetric enclosure one unit under the requirement is reported on the better axis" {
    // Oracle: construct-from-answer. max(min(40, 60), min(100, 100)) is 100:
    // 101 fails by one, on the worse side of the better axis, the bottom
    // strip, at (150, 50).
    var lb = LayoutBuilder.init(2);
    const h = try twoSided(&lb);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, asym(101));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 150, .y = 50 }, .measured = .length(100), .limit = .length(101), .shape_a = built.of(h[0]), .shape_b = built.of(h[1]) });
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "sky130 m1.5 an mcon pushed into a pad corner fails two opposite sides" {
    // Oracle: foundry example, sky130 m1.5 ("enclosed by Met1 on two
    // opposite sides by 0.060 um"), by hand: 85 and 55 on each axis, so
    // neither has 60 on both sides; the worse side of the first axis, 55, at
    // (282, 170).
    var lb = LayoutBuilder.init(2);
    const mcon = try lb.rect(gpa, 0, 85, 85, 255, 255);
    const met1 = try lb.rect(gpa, 1, 0, 0, 310, 310);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, asym(60));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 282, .y = 170 }, .measured = .length(55), .limit = .length(60), .shape_a = built.of(mcon), .shape_b = built.of(met1) });
}

test "sky130 m1.5 sixty on two opposite sides passes with thirty on the others" {
    // Oracle: foundry example, sky130 m1.4 and m1.5 at their minimums: 60
    // on the left and right meets m1.5 whatever the other two are.
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 60, 30, 230, 200);
    _ = try lb.rect(gpa, 1, 0, 0, 290, 230);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, asym(60));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "an l shaped inner with the limit along one axis passes" {
    // Oracle: construct-from-answer (DRC-041). An L via 100 clear left and
    // right of every vertical edge, flush above and below, passes.
    var lb = LayoutBuilder.init(2);
    _ = try lVia(&lb);
    _ = try lb.rect(gpa, 1, -100, 0, 300, 200);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, asym(100));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "an l shaped inner is measured edge by edge on its better axis" {
    // Oracle: construct-from-answer (DRC-041). A notch from the host's top
    // over x 150..250 down to y 199: the via's concave top edge reads 99, its
    // upper arm's right edge 50, so x measures 50 and y 99: 99 under 100, in
    // the strip above the concave edge, at (150, 149).
    var lb = LayoutBuilder.init(2);
    const via = try lVia(&lb);
    const host = try lb.push(gpa, 1, &.{ -100, 300, 300, 250, 250, 150, 150, -100 }, &.{ -100, -100, 300, 300, 199, 199, 300, 300 });
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, asym(100));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 150, .y = 149 }, .measured = .length(99), .limit = .length(100), .shape_a = built.of(via), .shape_b = built.of(host) });
}

test "a wire band holds only the inner shapes on wires of its widths" {
    // Oracle: construct-from-answer (DRC-043, LEF ENCLOSURE ... WIDTH). A
    // 3000 plate with a 500 tab; a via 40 into the plate's corner, one 10
    // from the tab's top: a band from 2000 holds only the first (40), one
    // below 1000 only the second (10); no band, both.
    var lb = LayoutBuilder.init(2);
    const corner = try lb.rect(gpa, 0, 40, 40, 240, 240);
    const tab_via = try lb.rect(gpa, 0, 3_400, 1_150, 3_600, 1_490);
    _ = try lb.rect(gpa, 1, 0, 0, 3_000, 3_000);
    _ = try lb.rect(gpa, 1, 3_000, 1_000, 3_800, 1_500);
    var built = try common.finish(&lb);
    defer built.deinit();
    const cases = [_]struct { i64, ?i64, testgen.shapes.Handle, i128 }{ .{ 2_000, null, corner, 40 }, .{ 0, 1_000, tab_via, 10 } };
    var sink: Sink = .{};
    defer sink.deinit();
    for (cases) |cs| {
        try run1(&sink, &built.store, .{ .min_enclosure = .{ .outer = B, .inner = A, .limit = 50, .wire = .{ .from = cs[0], .below = cs[1] } } });
        try testing.expectEqual(@as(u32, 1), sink.out.len());
        try testing.expectEqual(built.of(cs[2]), sink.out.get(0).shape_a);
        try testing.expectEqual(cs[3], length(&sink, 0));
        try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    }
    try run1(&sink, &built.store, minEnc(50));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
}

test "an opposite sides enclosure counts the host's holes" {
    // Oracle: hand-derived. The slots sit 20 right of and 20 above the via:
    // one violation measuring 20, naming the via and the pad.
    var lb = LayoutBuilder.init(2);
    const via = try lb.rect(gpa, 0, 100, 100, 270, 270);
    const pad = try lb.rect(gpa, 1, 0, 0, 1_000, 1_000);
    _ = try lb.shape(gpa, 1, testgen.shapes.hole(290, 100, 500, 270));
    _ = try lb.shape(gpa, 1, testgen.shapes.hole(100, 290, 270, 500));
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, asym(60));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 20), length(&sink, 0));
    try testing.expectEqual(built.of(via), sink.out.get(0).shape_a);
    try testing.expectEqual(built.of(pad), sink.out.get(0).shape_b);
}

test "an inner shape inside a host's hole is not enclosed" {
    // Oracle: construct-from-answer. The via lies in the pad's hole, on no
    // metal: enclosure 0, no host named.
    var lb = LayoutBuilder.init(2);
    const via = try lb.rect(gpa, 0, 400, 400, 600, 600);
    _ = try lb.rect(gpa, 1, 0, 0, 1_000, 1_000);
    _ = try lb.shape(gpa, 1, testgen.shapes.hole(300, 300, 700, 700));
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(40));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 0), length(&sink, 0));
    try testing.expectEqual(built.of(via), sink.out.get(0).shape_a);
    try testing.expectEqual(no_shape, sink.out.get(0).shape_b);
}

test "a min enclosure in an l measures to the inner corner" {
    // Oracle: hand-derived. The via's corner (170, 170) is 30 by 30 from the
    // notch corner, √1800 = 42.4, floored 42: clean at 42, 42 at 43.
    var lb = LayoutBuilder.init(2);
    _ = try lb.shape(gpa, 1, testgen.shapes.lShape(0, 0, 1_000, 200));
    _ = try lb.rect(gpa, 0, 60, 60, 170, 170);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(42));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try run1(&sink, &built.store, minEnc(43));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 42), length(&sink, 0));
}

test "the relaxed rule passes a shape the symmetric rule fails" {
    // Oracle: construct-from-answer. The same geometry fails the symmetric
    // rule at 41 (40) and passes the asymmetric one at 60.
    var lb = LayoutBuilder.init(2);
    _ = try twoSided(&lb);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minEnc(41));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 40), length(&sink, 0));
    try run1(&sink, &built.store, asym(60));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an extension one unit under the limit is reported at the overhang" {
    // Oracle: construct-from-answer. The stripe runs 60 past the bar: 61
    // fails by one at the stub's midpoint; one gate examined.
    var case = try extensionCase(60, 61);
    defer case.deinit(gpa);
    var sink = try expectOnly(&case, .{ .min_extension = .{ .layer = A, .reference = B, .limit = 61 } });
    defer sink.deinit();
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an extension exactly at the limit is clean" {
    // Oracle: construct-from-answer. Drawn at exactly 60.
    var case = try extensionCase(60, 60);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .min_extension = .{ .layer = A, .reference = B, .limit = 60 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a shape that does not meet the reference is not failing to extend past it" {
    // Oracle: construct-from-answer. A shape away from the reference makes
    // no gate: nothing judged.
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 1, 5_000, 5_000, 6_000, 6_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, .{ .min_extension = .{ .layer = A, .reference = B, .limit = 1_000 } });
    try testing.expectEqual(check.report.Outcome.ran, sink.runs.items[0].outcome);
    try testing.expectEqual(@as(u64, 0), sink.runs.items[0].examined);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "an overlap one unit under the limit is reported inside the intersection" {
    // Oracle: construct-from-answer. The intersection is 80 by 400: 81
    // fails it by one; one figure examined.
    var case = try overlapCase(80, 81);
    defer case.deinit(gpa);
    var sink = try expectOnly(&case, .{ .overlap = .{ .a = A, .b = B, .limit = 81 } });
    defer sink.deinit();
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an overlap exactly at the limit is clean" {
    // Oracle: construct-from-answer. Drawn at exactly 80.
    var case = try overlapCase(80, 80);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .overlap = .{ .a = A, .b = B, .limit = 80 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a well corner one unit beyond reach of a tap is reported at that corner" {
    // Oracle: construct-from-answer on a 3-4-5 triangle: the well's corner
    // at the origin is exactly 500 from the tap's nearest point: 499 fails
    // by one, at that corner.
    var lb = LayoutBuilder.init(2);
    const well = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 1, 400, 300, 500, 400);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, tap(499));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 0, .y = 0 }, .measured = .length(500), .limit = .length(499), .shape_a = built.of(well), .shape_b = no_shape });
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try run1(&sink, &built.store, tap(500));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a well layer with no taps at all violates on every well shape" {
    // Oracle: construct-from-answer, fail closed. With no tap, every well is
    // untied: two violations, each at one of its own corners.
    var lb = LayoutBuilder.init(2);
    const near = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 0, 900, 900, 1_000, 1_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, tap(500));
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 2), run.examined);
    try testing.expectEqual(@as(u32, 2), run.violations);
    for (0..2) |k| {
        const v = sink.out.get(@intCast(k));
        const base: i64 = if (v.shape_a == built.of(near)) 0 else 900;
        const ok = (v.at.x == base or v.at.x == base + 100) and (v.at.y == base or v.at.y == base + 100);
        try testing.expect(ok);
    }
}

test "an empty well layer is skipped rather than reported clean" {
    // Oracle: construct-from-answer. An empty well layer is skipped.
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 1, 0, 0, 100, 100);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, tap(500));
    try testing.expectEqual(check.report.Outcome{ .skipped = .empty_layer }, sink.runs.items[0].outcome);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "ihp lu.a the middle of a well tied at both ends is too far" {
    // Oracle: foundry example, IHP LU.a (20 um to the nearest tie), by hand:
    // the 46 um strip's middle, x 23 um, is 21 um from either 2 um tie.
    var lb = LayoutBuilder.init(2);
    const well = try lb.rect(gpa, 0, 0, 0, 46_000, 2_000);
    _ = try lb.rect(gpa, 1, 0, 0, 2_000, 2_000);
    _ = try lb.rect(gpa, 1, 44_000, 0, 46_000, 2_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, tap(20_000));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(i128, 21_000), length(&sink, 0));
    try testing.expectEqual(@as(i64, 23_000), sink.out.get(0).at.x);
    try testing.expectEqual(built.of(well), sink.out.get(0).shape_a);
}

test "a bend is a concave corner of a inside b" {
    // Oracle: construct-from-answer (sky130 poly.11, poly.10). An L-shaped A
    // whose concave corner (500, 500) lies inside B: one bend there; the
    // reference form finds nothing; bent above B, neither does.
    const l = struct {
        fn f(lb: *LayoutBuilder, y: i64) !testgen.shapes.Handle {
            return lb.push(gpa, 0, &.{ 400, 500, 500, 1_200, 1_200, 400 }, &.{ -200, -200, y, y, y + 100, y + 100 });
        }
    }.f;
    var lb = LayoutBuilder.init(2);
    const poly = try l(&lb, 500);
    const diff = try lb.rect(gpa, 1, 0, 0, 1_000, 1_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, .{ .gate_corner = .{ .layer = A, .reference = B, .of_reference = false } });
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 500, .y = 500 }, .measured = .count(1), .limit = .count(0), .shape_a = built.of(poly), .shape_b = built.of(diff) });
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try run1(&sink, &built.store, .{ .gate_corner = .{ .layer = A, .reference = B, .of_reference = true } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    var lb2 = LayoutBuilder.init(2);
    _ = try l(&lb2, 1_100);
    _ = try lb2.rect(gpa, 1, 0, 0, 1_000, 1_000);
    var built2 = try common.finish(&lb2);
    defer built2.deinit();
    for ([2]bool{ false, true }) |of_reference| {
        try run1(&sink, &built2.store, .{ .gate_corner = .{ .layer = A, .reference = B, .of_reference = of_reference } });
        try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    }
}

test "a maximum enclosure measures the furthest reach of the host" {
    // Oracle: construct-from-answer (sky130 npc.5, 95 nm). A cut in a host
    // 50 past it but 96 on the right reaches 96, at the centre of the 1 nm
    // strip past 95, x 195..196. Two cuts 191 apart reach 95.5 midway,
    // reported 96; 190 apart, 95, clean.
    const rule: Rule = .{ .max_enclosure = .{ .outer = B, .inner = A, .limit = 95 } };
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
    const host = try lb.rect(gpa, 1, -50, -50, 196, 150);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, rule);
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = B, .severity = .@"error", .at = .{ .x = 195, .y = 50 }, .measured = .length(96), .limit = .length(95), .shape_a = built.of(host), .shape_b = no_shape });
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    for ([_]struct { i64, ?i128 }{ .{ 190, null }, .{ 191, 96 } }) |cs| {
        var lb2 = LayoutBuilder.init(2);
        _ = try lb2.rect(gpa, 0, 0, 0, 100, 100);
        _ = try lb2.rect(gpa, 0, 100 + cs[0], 0, 200 + cs[0], 100);
        _ = try lb2.rect(gpa, 1, -50, -50, 250 + cs[0], 150);
        var b2 = try common.finish(&lb2);
        defer b2.deinit();
        try run1(&sink, &b2.store, rule);
        if (cs[1]) |reach| {
            try testing.expectEqual(@as(u32, 1), sink.out.len());
            try testing.expectEqual(reach, length(&sink, 0));
        } else try testing.expectEqual(@as(u32, 0), sink.out.len());
    }
}

test "a via must span its wire along one axis" {
    // Oracle: construct-from-answer (ASAP7 V1.M2.AUX.2). A 100 via in a 100
    // wide wire, 1 short of its top edge: along y 0 below and 1 above, along
    // x 500 and 900: the better axis reads 1, in the strip above the via at
    // (50, 99). Spanning the wire, it passes.
    const rule: Rule = .{ .full_width = .{ .outer = B, .inner = A } };
    var lb = LayoutBuilder.init(2);
    const via = try lb.rect(gpa, 0, 0, 0, 100, 99);
    const wire = try lb.rect(gpa, 1, -500, 0, 1_000, 100);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, rule);
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 50, .y = 99 }, .measured = .length(1), .limit = .length(0), .shape_a = built.of(via), .shape_b = built.of(wire) });
    var lb2 = LayoutBuilder.init(2);
    _ = try lb2.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb2.rect(gpa, 1, -500, 0, 1_000, 100);
    var b2 = try common.finish(&lb2);
    defer b2.deinit();
    try run1(&sink, &b2.store, rule);
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "sky130 li.5 reads each corner of a cut whose li steps along its sides" {
    // Oracle: foundry example, sky130 li.5 on `sky130_fd_sc_hd__a2111oi_1`,
    // clean under the foundry's `sky130A_mr.drc`; corner values by hand: the
    // least corner is 100. Under all eight symmetries, 80, 99 and 100 pass,
    // 101 fails measuring 100; two opposite sides read 75.
    var got: std.ArrayList(i128) = .empty;
    defer got.deinit(gpa);
    for (maps) |m| {
        for ([_]i64{ 80, 99, 100 }) |limit| {
            try runTransformed(m, &stepped, adjacent(limit), &got);
            try testing.expectEqual(@as(usize, 0), got.items.len);
        }
        try runTransformed(m, &stepped, adjacent(101), &got);
        try testing.expectEqualSlices(i128, &.{100}, got.items);
        try runTransformed(m, &stepped, asym(80), &got);
        try testing.expectEqualSlices(i128, &.{75}, got.items);
    }
}

test "adjacent and opposite sides agree when no side steps" {
    // Oracle: the distributive law of min and max, over every margin of {0,
    // 20, 59, 60, 61, 100} on each side of a 100 cut in one rectangle, at 60.
    const margins = [_]i64{ 0, 20, 59, 60, 61, 100 };
    var p: std.ArrayList(i128) = .empty;
    defer p.deinit(gpa);
    var q: std.ArrayList(i128) = .empty;
    defer q.deinit(gpa);
    for (margins) |l| for (margins) |r| for (margins) |b| for (margins) |t| {
        const boxes = [_]LayerBox{ .{ .layer = 0, .box = .{ 0, 0, 100, 100 } }, .{ .layer = 1, .box = .{ -l, -b, 100 + r, 100 + t } } };
        try runTransformed(maps[0], &boxes, adjacent(60), &p);
        try runTransformed(maps[0], &boxes, asym(60), &q);
        try testing.expectEqualSlices(i128, q.items, p.items);
    };
}
