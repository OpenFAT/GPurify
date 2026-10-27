//! Area family: `min_area`, `min_enclosed_area`, `cheesing`, `density`,
//! `global_density`, `density_balance`, `critical_area`. `min_area`
//! measures connected figures, not polygons; `density` sweeps in steps
//! smaller than the window. Ported from crates/check/tests/drc/area_rules.rs.

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
const LayerId = geom.LayerId;
const LimitSense = check.report.LimitSense;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const ViolationCase = testgen.violation.ViolationCase;
const L2: LayerId = @fromBackingInt(2);

// ---- private ----

/// A rectangle 100 wide whose area is exactly `measured`.
fn areaCase(measured: i128, limit: i128) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .area = .{ .layer = A, .width = 100 } } }, .{ 0, 0 }, .{ .area = measured }, .{ .area = limit });
}

fn enclosedCase(limit: i128) !ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .enclosed_area = .{ .layer = A, .margin = 50, .hole_width = 100 } } }, .{ 0, 0 }, .{ .area = 20_000 }, .{ .area = limit });
}

fn minArea(limit: i128) Rule {
    return .{ .min_area = .{ .layer = A, .limit = limit } };
}

fn cheese(limit: i128) Rule {
    return .{ .cheesing = .{ .layer = A, .max_unslotted = limit } };
}

fn density(window: i64, step: i64, limit: f64, sense: LimitSense) Rule {
    return .{ .density = .{ .layer = A, .boundary = null, .window = window, .step = step, .limit = limit, .sense = sense } };
}

fn run1(sink: *Sink, store: *const geom.GeometryStore, rule: Rule) !void {
    try common.runRules(sink, store, &common.single(rule));
}

/// Two ten-unit anchors fix the extent at [0, 2000]; a 500 block centred
/// on (1000, 1000) straddles the whole-window boundaries: the stepped
/// window at (500, 500) holds all of it (0.25), every whole window a
/// quarter (0.0625).
fn straddlingHotSpot() !common.Built {
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 10, 10);
    _ = try lb.rect(gpa, 0, 1_990, 1_990, 2_000, 2_000);
    _ = try lb.rect(gpa, 0, 750, 750, 1_250, 1_250);
    return common.finish(&lb);
}

/// The row of the violation measuring `measured`, its first shape.
fn ownerOf(sink: *const Sink, measured: i128) geom.PolyId {
    for (0..sink.out.len()) |k| if (sink.out.get(@intCast(k)).measured.eql(.area(measured))) return sink.out.get(@intCast(k)).shape_a;
    std.debug.panic("no violation measures {d}", .{measured});
}

fn at(sink: *const Sink, k: u32) [2]i64 {
    const p = sink.out.get(k).at;
    return .{ p.x, p.y };
}

test "a figure one square unit under the limit is reported at its centre" {
    // Oracle: construct-from-answer. A 100 x 400 rectangle has an area of
    // 40 000 exactly; 40 001 is the smallest limit it fails.
    var case = try areaCase(40_000, 40_001);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, minArea(40_001));
    try testgen.assertOnlyViolation(&sink.out, case.expected);
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 1), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "a figure exactly at the area limit is clean" {
    // Oracle: construct-from-answer. Drawn exactly at 40 000.
    var case = try areaCase(40_000, 40_000);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, minArea(40_000));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "two overlapping fragments are one figure whose area is their union" {
    // Oracle: construct-from-answer. Two 10 000 rectangles sharing 5 000
    // merge into one 15 000 figure, passing 12 001; one figure examined.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 0, 50, 0, 150, 100);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minArea(12_001));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a merged figure below the limit is reported once with its merged area" {
    // Oracle: construct-from-answer. The union is 15 000, failing 15 001
    // once, marked inside the figure's [0, 150] x [0, 100].
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 0, 50, 0, 150, 100);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minArea(15_001));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    const v = sink.out.get(0);
    try testing.expect(v.measured.eql(.area(15_000)) and v.limit.eql(.area(15_001)));
    try testing.expectEqual(A, v.layer);
    try testing.expect(v.at.x >= 0 and v.at.x <= 150 and v.at.y >= 0 and v.at.y <= 100);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a hole one square unit under the limit is reported at the hole" {
    // Oracle: construct-from-answer. The ring's hole is 100 x 200 = 20 000,
    // failing 20 001, marked at the hole's box centre, the origin.
    var case = try enclosedCase(20_001);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .min_enclosed_area = .{ .layer = A, .limit = 20_001 } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual([2]i64{ 0, 0 }, at(&sink, 0));
    _ = try testgen.assertHasViolation(&sink.out, case.expected);
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 1), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "a hole exactly at the enclosed area limit is clean" {
    // Oracle: construct-from-answer. The hole is drawn at exactly 20 000.
    var case = try enclosedCase(20_000);
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &case.store, .{ .min_enclosed_area = .{ .layer = A, .limit = 20_000 } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "an unslotted plate one square unit over the limit is reported at its centre" {
    // Oracle: construct-from-answer. A solid 500 x 400 plate is 200 000,
    // failing 199 999 at its centre (250, 200).
    var lb = LayoutBuilder.init(1);
    const plate = try lb.rect(gpa, 0, 0, 0, 500, 400);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, cheese(199_999));
    try testgen.assertOnlyViolation(&sink.out, .{ .rule = RULE, .layer = A, .severity = .@"error", .at = .{ .x = 250, .y = 200 }, .measured = .area(200_000), .limit = .area(199_999), .shape_a = built.of(plate), .shape_b = check.report.no_shape });
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a plate exactly at the unslotted limit is clean" {
    // Oracle: hand-derived. 500 x 400 = 200 000, exactly the limit.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 500, 400);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, cheese(200_000));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a slotted plate passes a limit its area alone would fail" {
    // Oracle: construct-from-answer. The plate with a hole (190 000) is
    // perforated: it passes 100 000.
    var lb = LayoutBuilder.init(1);
    _ = try lb.shape(gpa, 0, testgen.shapes.rect(0, 0, 500, 400));
    _ = try lb.shape(gpa, 0, testgen.shapes.hole(200, 150, 300, 250));
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, cheese(100_000));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 1), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a hot spot straddling two windows is caught by the stepped sweep" {
    // Oracle: construct-from-answer. The one window over 0.2 spans [500,
    // 1500]: reported at (1000, 1000), 0.25; nine windows examined.
    var built = try straddlingHotSpot();
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, density(1_000, 500, 0.2, .maximum));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual([2]i64{ 1_000, 1_000 }, at(&sink, 0));
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.25)) and sink.out.get(0).limit.eql(.ratio(0.2)));
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, 9), run.examined);
}

test "the same hot spot is missed when the window advances a whole window" {
    // Oracle: construct-from-answer. Whole-window steps see four windows
    // each a quarter of the block (0.0625): clean over four.
    var built = try straddlingHotSpot();
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, density(1_000, 1_000, 0.2, .maximum));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 4), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a window exactly at the density limit is clean and just over it is not" {
    // Oracle: construct-from-answer. The densest window is 0.25: a maximum
    // of 0.25 is met; 0.2499 is exceeded.
    var built = try straddlingHotSpot();
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, density(1_000, 500, 0.25, .maximum));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 9), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try run1(&sink, &built.store, density(1_000, 500, 0.2499, .maximum));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual([2]i64{ 1_000, 1_000 }, at(&sink, 0));
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.25)));
}

test "the minimum sense flags the sparse windows the maximum sense ignores" {
    // Oracle: construct-from-answer. Eight of nine windows fall below 0.2;
    // the centred one reaches 0.25 and is not flagged.
    var built = try straddlingHotSpot();
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, density(1_000, 500, 0.2, .minimum));
    try testing.expectEqual(@as(u64, 9), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try testing.expectEqual(@as(u32, 8), sink.out.len());
    for (0..8) |k| try testing.expect(!std.meta.eql(at(&sink, @intCast(k)), .{ 1_000, 1_000 }));
}

test "an empty layer has density zero over the die" {
    // Oracle: hand-derived. The die is A's 2000 x 1000 extent: two windows
    // of density 0 on the empty B, a maximum passes both, a minimum flags
    // both; no die at all is skipped (empty layer).
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 0, 0, 2_000, 1_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    const onB = struct {
        fn f(sense: LimitSense) Rule {
            return .{ .density = .{ .layer = B, .boundary = null, .window = 1_000, .step = 1_000, .limit = 0.2, .sense = sense } };
        }
    }.f;
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, onB(.maximum));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, 2), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try run1(&sink, &built.store, onB(.minimum));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.0)));
    var empty_lb = LayoutBuilder.init(2);
    var empty = try common.finish(&empty_lb);
    defer empty.deinit();
    try run1(&sink, &empty.store, onB(.minimum));
    try testing.expectEqual(check.report.Outcome{ .skipped = .empty_layer }, sink.runs.items[0].outcome);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "ihp m1.j density windows tile the die not the layer" {
    // Oracle: foundry example, IHP M1.j and gf180 M1.4 tile the chip
    // boundary; by hand two 2000 windows over the 4 x 2 um die, the left
    // full, the right empty: one violation at (3000, 1000), measuring 0.
    var lb = LayoutBuilder.init(2);
    _ = try lb.rect(gpa, 0, 0, 0, 2_000, 2_000);
    _ = try lb.rect(gpa, 1, 0, 0, 4_000, 2_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, .{ .density = .{ .layer = A, .boundary = B, .window = 2_000, .step = 2_000, .limit = 0.3, .sense = .minimum } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual([2]i64{ 3_000, 1_000 }, at(&sink, 0));
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.0)));
    try testing.expectEqual(@as(u64, 2), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "gf180 m1.4 whole die density" {
    // Oracle: foundry example, gf180 M1.4 (30 % over the die), by hand:
    // 2000 of 10 000 is 0.2 and fails at the die's centre; 2000 of 5000 is
    // 0.4 and passes.
    var lb = LayoutBuilder.init(3);
    _ = try lb.rect(gpa, 0, 0, 0, 2_000, 1_000);
    _ = try lb.rect(gpa, 1, 0, 0, 10_000, 1_000);
    _ = try lb.rect(gpa, 2, 0, 0, 5_000, 1_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, .{ .global_density = .{ .layer = A, .boundary = B, .limit = 0.3, .sense = .minimum } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.2)));
    try testing.expectEqual([2]i64{ 5_000, 500 }, at(&sink, 0));
    try run1(&sink, &built.store, .{ .global_density = .{ .layer = A, .boundary = L2, .limit = 0.3, .sense = .minimum } });
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "a derived layer does not widen the boundary less die" {
    // Oracle: hand-derived, with docs/src/reference/drc/density.md (DRC-070):
    // with no boundary layer the die is the bounding box of every drawn layer,
    // so a derived layer does not widen it: 700 x 1000 of the 1000 square
    // marker is 0.7, over a 60 % maximum, at the die's centre.
    var lb = LayoutBuilder.init(3);
    _ = try lb.rect(gpa, 0, 0, 0, 700, 1_000);
    _ = try lb.rect(gpa, 1, 0, 0, 1_000, 1_000);
    _ = try lb.rect(gpa, 2, -500, -500, 1_200, 1_500);
    var built = try common.finish(&lb);
    defer built.deinit();
    var set: check.drc.RuleSet = .{ .first_derived = L2 };
    defer set.deinit(gpa);
    try set.push(gpa, RULE, .{ .global_density = .{ .layer = A, .boundary = null, .limit = 0.6, .sense = .maximum } }, .@"error");
    var sink: Sink = .{};
    defer sink.deinit();
    try check.drc.run(gpa, .cpu, null, &set, &built.store, null, &sink.out, &sink.runs);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.7)));
    try testing.expectEqual([2]i64{ 500, 500 }, at(&sink, 0));
}

test "an island inside a figure is not named for it" {
    // Oracle: hand-derived areas (a 500 x 400 ring with a 100 x 100 hole,
    // 190 000, holding a 60 x 60 island, 3 600; the hole 10 000; a 300
    // square U with a 100 x 200 gap, 70 000, around a 60 x 100 island,
    // 6 000) and construct-from-answer for the owner: each island is drawn
    // as the lowest row under itself, so each violation names its shape.
    var lb = LayoutBuilder.init(1);
    const island = try lb.rect(gpa, 0, 220, 170, 280, 230);
    const ring = try lb.shape(gpa, 0, testgen.shapes.rect(0, 0, 500, 400));
    _ = try lb.shape(gpa, 0, testgen.shapes.hole(200, 150, 300, 250));
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, minArea(200_000));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    try testing.expectEqual(built.of(ring), ownerOf(&sink, 190_000));
    try testing.expectEqual(built.of(island), ownerOf(&sink, 3_600));
    try run1(&sink, &built.store, .{ .min_enclosed_area = .{ .layer = A, .limit = 20_000 } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(built.of(ring), ownerOf(&sink, 10_000));
    var lb2 = LayoutBuilder.init(1);
    const island2 = try lb2.rect(gpa, 0, 120, 150, 180, 250);
    const u = try lb2.push(gpa, 0, &.{ 0, 300, 300, 200, 200, 100, 100, 0 }, &.{ 0, 0, 300, 300, 100, 100, 300, 300 });
    var built2 = try common.finish(&lb2);
    defer built2.deinit();
    try run1(&sink, &built2.store, cheese(5_000));
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    try testing.expectEqual(built2.of(u), ownerOf(&sink, 70_000));
    try testing.expectEqual(built2.of(island2), ownerOf(&sink, 6_000));
}

test "a density window over a hole names the ring not the hole" {
    // Oracle: hand-derived: nine 1000 windows over the 3000 ring, the centre
    // one over the hole at density 0, at (1500, 1500), naming the ring.
    var lb = LayoutBuilder.init(1);
    const ring = try lb.shape(gpa, 0, testgen.shapes.rect(0, 0, 3_000, 3_000));
    _ = try lb.shape(gpa, 0, testgen.shapes.hole(1_000, 1_000, 2_000, 2_000));
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, density(1_000, 1_000, 0.5, .minimum));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual([2]i64{ 1_500, 1_500 }, at(&sink, 0));
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.0)));
    try testing.expectEqual(built.of(ring), sink.out.get(0).shape_a);
}

test "density balance is the lesser coverage over the greater" {
    // Oracle: the balance worked by hand. A covers 500 x 1000 and B 250 x
    // 1000 of a window: 0.5. A limit of 0.6 reports it at its centre; 0.5
    // is met; a window neither covers is not judged.
    var lb = LayoutBuilder.init(3);
    _ = try lb.rect(gpa, 0, 0, 0, 500, 1_000);
    _ = try lb.rect(gpa, 1, 500, 0, 750, 1_000);
    _ = try lb.rect(gpa, 2, 0, 0, 2_000, 1_000);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    const balance = struct {
        fn f(limit: f64) Rule {
            return .{ .density_balance = .{ .a = A, .b = B, .boundary = L2, .window = 1_000, .step = 1_000, .limit = limit } };
        }
    }.f;
    try run1(&sink, &built.store, balance(0.6));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.ratio(0.5)));
    try testing.expectEqual([2]i64{ 500, 500 }, at(&sink, 0));
    try testing.expectEqual(@as(u64, 2), sink.runs.items[0].examined);
    try run1(&sink, &built.store, balance(0.5));
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "critical area of two parallel lines is the closed form" {
    // Oracle: the closed form for two parallel lines (Koren and Koren,
    // 1998): lines of length 500 a gap 100 apart under a square defect of
    // half-side 100 have a critical area of (500 + 200)(200 - 100) = 70 000.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 500, 50);
    _ = try lb.rect(gpa, 0, 0, 150, 500, 200);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try run1(&sink, &built.store, .{ .critical_area = .{ .layer = A, .radius = 100, .limit = 69_999 } });
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.area(70_000)));
    try testing.expectEqual(@as(u64, 2), sink.runs.items[0].examined);
    try run1(&sink, &built.store, .{ .critical_area = .{ .layer = A, .radius = 100, .limit = 70_000 } });
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}
