//! The cut-layer kinds through deck text, first half: `max_space`,
//! `keep_out_zone`, `cut_class_space`, cut spacing (edge, centre and
//! adjacent-cut forms) and `redundant_via`; the rest is
//! `via_deck_more.zig`. Each case's oracle is restated on its test, run
//! through the deck compiler and rule set under the eight symmetries of the
//! square at two translations. Ported from
//! crates/check/tests/drc/via_deck.rs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const check = @import("check");
const common = @import("common.zig");
const F = common.Finding;
const Layout = common.Layout;
const gpa = common.gpa;
const steps = common.steps;
const below = common.below;
const opt = common.opt;
const everywhere = common.everywhere;
const Measurement = check.report.Measurement;

/// A rectangle on a named layer.
const Box = struct { []const u8, [4]i64 };

const none: []const F = &.{};

/// A cut-class table whose square class has an END unlike its SIDE: a
/// 100 x 100 square and a 100 x 300 slot, rows and columns square END,
/// square SIDE, slot END, slot SIDE.
const square_and_slot =
    \\rule cs cut_class_space(cut;
    \\     short: [100nm, 100nm], long: [100nm, 300nm],
    \\     space: [[200nm, 300nm, 400nm, 400nm], [300nm, 300nm, 400nm, 400nm],
    \\     [400nm, 400nm, 350nm, 500nm], [400nm, 400nm, 500nm, 500nm]])
    \\
;

// ---- private ----

fn layout(boxes: []const Box) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    for (boxes) |b| try l.rect(b[0], b[1][0], b[1][1], b[1][2], b[1][3]);
    return l;
}

fn cut(x: i64, y: i64) [4]i64 {
    return .{ x, y, x + 100, y + 100 };
}

/// Rectangles all on `layer`.
fn on(layer: []const u8, boxes: []const [4]i64) !Layout {
    return common.layoutOf(layer, boxes);
}

/// Two rules' claims over `l`, everywhere; `l` is freed.
fn two(name: []const u8, d: []const u8, l: Layout, id1: []const u8, f1: []const F, id2: []const u8, f2: []const F) !void {
    var held = l;
    defer held.deinit();
    try common.checkEverywhere(name, d, &held, &.{ .{ .id = id1, .findings = f1 }, .{ .id = id2, .findings = f2 } });
}

/// One length finding per centre, each pinned there.
fn far(arena: Allocator, d: i64, at: []const [2]i64) ![]const F {
    const out = try arena.alloc(F, at.len);
    for (out, at) |*f, p| f.* = F.length(d).atPoint(p[0], p[1]);
    return out;
}

fn lengths(arena: Allocator, values: []const i64) ![]const F {
    const out = try arena.alloc(F, values.len);
    for (out, values) |*f, v| f.* = F.length(v);
    return out;
}

fn areas(arena: Allocator, values: []const i128) ![]const F {
    const out = try arena.alloc(F, values.len);
    for (out, values) |*f, v| f.* = F.area(v);
    return out;
}

fn repeat(arena: Allocator, f: F, n: usize) ![]const F {
    const out = try arena.alloc(F, n);
    @memset(out, f);
    return out;
}

fn label(arena: Allocator, base: []const u8, i: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, ([3][]const u8{ "below", "at", "above" })[i] });
}

/// A `cols` x `rows` array of 200 cuts with gaps `gx`, `gy`.
fn array(al: Allocator, cols: i64, rows: i64, gx: i64, gy: i64) ![]const [4]i64 {
    var out: std.ArrayList([4]i64) = .empty;
    var c: i64 = 0;
    while (c < cols) : (c += 1) {
        var r: i64 = 0;
        while (r < rows) : (r += 1) {
            const x = c * (200 + gx);
            const y = r * (200 + gy);
            try out.append(al, .{ x, y, x + 200, y + 200 });
        }
    }
    return out.items;
}

test "max space finds each lonely cut at its centre" {
    // `max_space(v1) <= 1000nm` and `max_space(big, v1) <= 1000nm` with `big
    // = v1.with_bbox_min(>= 150nm)` (DRC-034): `LEF58_MAXSPACING 1.0
    // [CUTCLASS]` as OpenROAD's `getLonelyVias` reads it, a cut (of the
    // class) with no other cut whose centre is within 1000 of its own is
    // lonely, one finding at its centre measuring the nearest centre
    // distance rounded up.
    // Oracle: centres placed by construction: two 100 cuts 999, 1000 and 1001
    // apart (both lonely only at 1001); a 600 x 800 diagonal (1000 by the
    // 3-4-5 triangle, legal) and a 600 x 801 one (1000.8, rounded up to 1001);
    // a lone cut (a count of 0 against 1); a chain 1000 then 1500 apart, whose
    // far cut alone is lonely (1500). With a class: a 200 cut 900 from a 100
    // cut is not lonely; 1200 apart it is; a 200 cut alone does not count its
    // own row on the whole layer.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{"v1"}, "layer big = v1.with_bbox_min(>= 150nm)\nrule lone max_space(v1) <= 1000nm\nrule cls max_space(big, v1) <= 1000nm\n");
    for (steps(1000), 0..) |dd, i| {
        const lonely = if (dd > 1000) try far(al, dd, &.{ .{ 50, 50 }, .{ dd + 50, 50 } }) else none;
        try two(try label(al, "pair", i), d, try on("v1", &.{ cut(0, 0), cut(dd, 0) }), "lone", lonely, "cls", none);
    }
    try two("diagonal/at", d, try on("v1", &.{ cut(0, 0), cut(600, 800) }), "lone", none, "cls", none);
    try two("diagonal/above", d, try on("v1", &.{ cut(0, 0), cut(600, 801) }), "lone", try far(al, 1001, &.{ .{ 50, 50 }, .{ 650, 851 } }), "cls", none);
    try two("alone", d, try on("v1", &.{cut(0, 0)}), "lone", &.{F.count(0).atPoint(50, 50)}, "cls", none);
    try two("chain", d, try on("v1", &.{ cut(0, 0), cut(1000, 0), cut(2500, 0) }), "lone", try far(al, 1500, &.{.{ 2550, 50 }}), "cls", none);
    const big = [4]i64{ 0, 0, 200, 200 };
    try two("class/near", d, try on("v1", &.{ big, .{ 950, 50, 1050, 150 } }), "lone", none, "cls", none);
    try two("class/far", d, try on("v1", &.{ big, .{ 1250, 50, 1350, 150 } }), "lone", try far(al, 1200, &.{ .{ 100, 100 }, .{ 1300, 100 } }), "cls", try far(al, 1200, &.{.{ 100, 100 }}));
    try two("class/alone", d, try on("v1", &.{big}), "lone", &.{F.count(0)}, "cls", &.{F.count(0)});
}

test "max space reports its limit and counts every cut" {
    // Oracle: `Rule::MaxCutSpacing`'s rustdoc: a lonely cut with a nearest
    // cut is held to the deck's 1000 nm; one with no other cut at all
    // measures a count of 0 against a count of 1; `examined` counts the
    // held layer's cuts, three here whatever their spacing.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{"v1"}, "rule lone max_space(v1) <= 1000nm\n");
    var l = try on("v1", &.{ .{ 0, 0, 100, 100 }, .{ 3000, 0, 3100, 100 }, .{ 3500, 0, 3600, 100 } });
    defer l.deinit();
    var r = try common.run(d, &l);
    defer r.deinit();
    const lone = r.row("lone");
    try testing.expectEqual(@as(u64, 3), lone.examined);
    try testing.expectEqual(@as(usize, 1), lone.findings.len);
    try testing.expectEqual(Measurement.length(3000), lone.findings[0].measured);
    try testing.expectEqual(Measurement.length(1000), lone.findings[0].limit);
    try testing.expectEqual([2]i64{ 50, 50 }, lone.findings[0].at);
    var l1 = try on("v1", &.{.{ 0, 0, 100, 100 }});
    defer l1.deinit();
    var r1 = try common.run(d, &l1);
    defer r1.deinit();
    const f = r1.row("lone").findings;
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqual(Measurement.count(0), f[0].measured);
    try testing.expectEqual(Measurement.count(1), f[0].limit);
    try testing.expectEqual([2]i64{ 50, 50 }, f[0].at);
}

test "keep out zone measures the area inside the zones" {
    // `keep_out_zone` (DRC-126): a 100 x 300 class bar (`k`) and its turn
    // (`kt`, held only against 100 x 100 cuts) with end zones 10 to the side
    // and 80 forward, side zones 50 to the side and 20 forward; one finding
    // per held cut and other cut in its zones, measuring that cut's area
    // inside them.
    // Oracle: areas by hand from the zones: a square past the bar's end 19,
    // 20, 21 from it (in the side zone below 20: 100 at 19; touching is
    // outside), a square above it 79, 80, 81 off (in the end zone below 80); a
    // square 20 above it, in both zones (6000, their union: summing the two
    // gives 9000); a square off the corner (125, in the end zone only); a
    // second bar 79 above (300 each way for `k`, two findings, none for `kt`);
    // two squares 10 apart (no class owns a zone).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const zones = "end_side: 10nm, end_forward: 80nm, side_side: 50nm, side_forward: 20nm";
    const d = try common.newDeck(al, &.{"v"}, try std.fmt.allocPrint(al, "rule k keep_out_zone(v; class: 100nm x 300nm, to: none, {s})\nrule kt keep_out_zone(v; class: 300nm x 100nm, to: 100nm x 100nm, {s})\n", .{ zones, zones }));
    const bar = [4]i64{ 0, 0, 300, 100 };
    for (steps(20), 0..) |g, i| {
        const found = if (g < 20) try areas(al, &.{100}) else none;
        try two(try label(al, "past_the_end", i), d, try on("v", &.{ bar, cut(300 + g, 0) }), "k", found, "kt", found);
    }
    for (steps(80), 0..) |g, i| {
        const found = if (g < 80) try areas(al, &.{100}) else none;
        try two(try label(al, "above", i), d, try on("v", &.{ bar, cut(100, 100 + g) }), "k", found, "kt", found);
    }
    try two("in_both_zones", d, try on("v", &.{ bar, cut(100, 120) }), "k", try areas(al, &.{6000}), "kt", try areas(al, &.{6000}));
    try two("off_the_corner", d, try on("v", &.{ bar, cut(305, 155) }), "k", try areas(al, &.{125}), "kt", try areas(al, &.{125}));
    try two("two_bars", d, try on("v", &.{ bar, .{ 0, 179, 300, 279 } }), "k", try areas(al, &.{ 300, 300 }), "kt", none);
    try two("two_squares", d, try on("v", &.{ .{ 0, 0, 100, 100 }, .{ 110, 0, 210, 100 } }), "k", none, "kt", none);
    var l = try on("v", &.{.{ 0, 0, 100, 100 }});
    defer l.deinit();
    var r = try common.run(d, &l);
    defer r.deinit();
    try testing.expectEqual(check.report.Outcome.ran, r.row("k").outcome);
    try testing.expectEqual(@as(u64, 0), r.row("k").examined);
}

test "cut class space holds each pair to its cell" {
    // sky130 licon.2 to licon.2d as one cut-class table (DRC-063, DRC-064):
    // square 170 nm licons 170 apart (licon.2), slotted 190 x 2000 licons
    // 350 apart end to end (licon.2b) and 510 otherwise (licon.2c), and 510
    // from a square (licon.2d). One finding per pair closer than its cell,
    // measuring the gap.
    // Oracle: the sky130 manual's values, gaps drawn to them; a pair apart
    // along both axes needs the larger of its two readings (`OpenROAD`'s
    // `checkLef58CutSpacingTbl_helper` checks both directions): slots offset
    // diagonally by (110, 400) are floor(sqrt(110² + 400²)) = 414 apart and
    // held to 510. A 200 nm cut has no class; overlapping squares and a slot
    // abutting a square measure 0.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{"licon"},
        \\rule licon.2 cut_class_space(licon;
        \\short: [170nm, 190nm], long: [170nm, 2000nm],
        \\space: [[170nm, 170nm, 510nm, 510nm], [170nm, 170nm, 510nm, 510nm],
        \\[510nm, 510nm, 350nm, 510nm], [510nm, 510nm, 510nm, 510nm]])
        \\
    );
    const slot = [4]i64{ 0, 0, 190, 2000 };
    for (steps(170)) |g| try everywhere("squares", d, try on("licon", &.{ .{ 0, 0, 170, 170 }, .{ 170 + g, 0, 340 + g, 170 } }), "licon.2", below(g, 170));
    for (steps(350)) |g| try everywhere("end_to_end", d, try on("licon", &.{ slot, .{ 0, 2000 + g, 190, 4000 + g } }), "licon.2", below(g, 350));
    for (steps(510)) |g| {
        try everywhere("side_by_side", d, try on("licon", &.{ slot, .{ 190 + g, 0, 380 + g, 2000 } }), "licon.2", below(g, 510));
        try everywhere("slot_beside_square", d, try on("licon", &.{ slot, .{ 190 + g, 900, 360 + g, 1070 } }), "licon.2", below(g, 510));
        try everywhere("square_past_slot_end", d, try on("licon", &.{ slot, .{ 10, 2000 + g, 180, 2170 + g } }), "licon.2", below(g, 510));
    }
    try everywhere("end_to_end_400", d, try on("licon", &.{ slot, .{ 0, 2400, 190, 4400 } }), "licon.2", none);
    try everywhere("diagonal", d, try on("licon", &.{ slot, .{ 300, 2400, 490, 4400 } }), "licon.2", try lengths(al, &.{414}));
    try everywhere("unclassed", d, try on("licon", &.{ .{ 0, 0, 170, 170 }, .{ 180, 0, 380, 200 } }), "licon.2", none);
    try everywhere("overlapping_squares", d, try on("licon", &.{ .{ 0, 0, 170, 170 }, .{ 100, 0, 270, 170 } }), "licon.2", try lengths(al, &.{0}));
    try everywhere("slot_abutting_square", d, try on("licon", &.{ slot, .{ 190, 0, 360, 170 } }), "licon.2", try lengths(al, &.{0}));
}

test "cut class space reads squares as ends and touching pairs at the largest cell" {
    // Oracle: `Rule::CutClassSpacing`'s rustdoc: "A square cut always faces
    // with its END", and "A pair that touches or overlaps is held to the
    // largest cell of its two classes", the finding's `limit` the cell. Two
    // squares 250 apart face END to END, 200: clean (SIDE to SIDE would need
    // 300). Two slots touching end to end are not apart along either axis:
    // held to the largest slot-slot cell, 500, not the END-END 350 an apart
    // pair would take; the finding measures 0.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{"cut"}, square_and_slot);
    try everywhere("squares", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 0, 350, 100, 450 } }), "cs", none);
    try everywhere("squares_closer", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 0, 299, 100, 399 } }), "cs", &[_]F{F.length(199).limitOf(.length(200))});
    try everywhere("touching_slots", d, try on("cut", &.{ .{ 0, 0, 100, 300 }, .{ 0, 300, 100, 600 } }), "cs", &[_]F{F.length(0).limitOf(.length(500))});
}

test "max space rounds a half unit distance up" {
    // Oracle: `Rule::MaxCutSpacing`'s rustdoc: the nearest centre distance
    // rounded up. A 100 cut and a 100 x 101 cut 1000 along: centres (50, 50)
    // and (1050, 50.5), `√(1000² + 0.5²) ≈ 1000.0001` apart: lonely, measuring
    // 1001. A 100 cut and a 101 x 100 cut 1001 along: centres 1101.5 apart,
    // rounded up to 1102.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{"v1"}, "rule lone max_space(v1) <= 1000nm\n");
    try everywhere("half_unit_off_axis", d, try on("v1", &.{ .{ 0, 0, 100, 100 }, .{ 1000, 0, 1100, 101 } }), "lone", try repeat(al, F.length(1001), 2));
    try everywhere("half_unit_along", d, try on("v1", &.{ .{ 0, 0, 100, 100 }, .{ 1101, 0, 1202, 100 } }), "lone", try repeat(al, F.length(1102), 2));
}

test "cut space measures the euclidean gap" {
    // Cut-to-cut spacing `space(cut) >= 100nm` (DRC-060) and cross-layer
    // `space(via1, via2) >= 100nm` (DRC-065): one finding per pair closer
    // than the limit, measuring the Euclidean gap floored.
    // Oracle: gaps by construction: side by side, swept; diagonal at (60,
    // 79/80/81) beyond the first cut's corner, so the gap is exactly 99.2, 100
    // and 100.8 (a 60-80-100 triangle); two cuts on one layer abutting, and
    // touching only at a corner (one figure, no gap); a via2 stacked on a via1
    // (0).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const one = try common.newDeck(al, &.{"cut"}, "rule via.2 space(cut) >= 100nm\n");
    const pair = try common.newDeck(al, &.{ "via1", "via2" }, "rule v12 space(via1, via2) >= 100nm\n");
    const Both = struct {
        fn f(o: []const u8, p: []const u8, name: []const u8, a: [4]i64, b: [4]i64, findings: []const F) !void {
            try everywhere(name, o, try on("cut", &.{ a, b }), "via.2", findings);
            try everywhere(name, p, try layout(&.{ .{ "via1", a }, .{ "via2", b } }), "v12", findings);
        }
    };
    for (steps(100)) |g| {
        const held = below(g, 100);
        try Both.f(one, pair, "side", .{ 0, 0, 100, 100 }, .{ 100 + g, 0, 200 + g, 100 }, common.slice(&held));
    }
    for ([_]i64{ 79, 80, 81 }) |dy| {
        try Both.f(one, pair, "diagonal", .{ 0, 0, 100, 100 }, .{ 160, 100 + dy, 260, 200 + dy }, if (dy == 79) try lengths(al, &.{99}) else none);
    }
    try everywhere("abutting", one, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } }), "via.2", none);
    try everywhere("stacked", pair, try layout(&.{ .{ "via1", .{ 0, 0, 100, 100 } }, .{ "via2", .{ 0, 0, 100, 100 } } }), "v12", try lengths(al, &.{0}));
    try everywhere("corner_touch", one, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 100, 100, 200, 200 } }), "via.2", none);
}

test "center space measures centre to centre" {
    // `space(cut, center) >= 300nm` (DRC-061): one finding per pair whose
    // box centres are closer than the limit, measuring that distance
    // floored, at the midpoint of the two centres.
    // Oracle: centres placed a chosen distance apart: two 100 squares, swept
    // (centres d apart, midpoint ((d + 100) / 2, 50)); a 100 and a 200 cut
    // whose centres are d apart while their edges are 150 closer; a 101 and a
    // 100 cut whose centres are d - 0.5 apart (floored to d - 1, so 300.5
    // passes); centre offsets (180, 239/240/241), 299.2, 300 and 300.8 apart
    // (a 180-240-300 triangle); overlapping cuts (50) and a cut nested in
    // another (0); a row of three at a 250 pitch (the outer pair, 500 apart,
    // passes).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{"cut"}, "rule c2c space(cut, center) >= 300nm\n");
    for (steps(300)) |dd| {
        const f = F.length(dd);
        try everywhere("squares", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ dd, 0, dd + 100, 100 } }), "c2c", opt(dd < 300, if (@mod(dd, 2) == 0) f.atPoint(@divExact(dd + 100, 2), 50) else f));
        try everywhere("unequal", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ dd - 50, 0, dd + 150, 100 } }), "c2c", below(dd, 300));
        try everywhere("half_unit", d, try on("cut", &.{ .{ 0, 0, 101, 100 }, .{ dd, 0, dd + 100, 100 } }), "c2c", below(dd - 1, 300));
    }
    for ([_]i64{ 239, 240, 241 }) |dy| {
        try everywhere("diagonal", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 180, dy, 280, dy + 100 } }), "c2c", if (dy == 239) try lengths(al, &.{299}) else none);
    }
    try everywhere("overlapping", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 50, 0, 150, 100 } }), "c2c", try lengths(al, &.{50}));
    try everywhere("nested", d, try on("cut", &.{ .{ 0, 0, 300, 300 }, .{ 100, 100, 200, 200 } }), "c2c", try lengths(al, &.{0}));
    try everywhere("row_of_three", d, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 250, 0, 350, 100 }, .{ 500, 0, 600, 100 } }), "c2c", try lengths(al, &.{ 250, 250 }));
}

test "adjacent space holds only cuts with enough neighbours" {
    // `adjacent_space(cut; cuts: 3, within: 250nm) >= 220nm` (DRC-062, LEF
    // Spacing Rule Example 2) on 200 nm cuts, and `adjacent_space(cut,
    // center; cuts: 3, within: 300nm) >= 300nm` (Example 4) on 100 nm cuts:
    // a pair closer than the limit fails when either cut has at least three
    // other cuts strictly closer than `within`.
    // Oracle: the manual's Figure 1-6. With the diagonal beyond `within`, a
    // cut of a 1 x n row or a 2 x 2 array has two adjacent cuts, a middle cut
    // of a 3 x 2 array three, and the centre of a 3 x 3 four; so at a 219 gap
    // a row and a 2 x 2 pass, a 3 x 2 fails on the five pairs that touch its
    // middle cuts, a 3 x 3 on all twelve side pairs. A 3 x 2 array 219 apart
    // along its rows with its rows 249, 250, 251 apart holds its middle cuts
    // only at 249 (`within` is strict). For the centre form, a T of four at a
    // 299/300/301 pitch (its middle has three neighbours) and a 2 x 2 at 299
    // (two each, clean). `examined` counts the cuts held: the two middle
    // cuts of a 3 x 2 at 219.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{"cut"}, "rule adj adjacent_space(cut; cuts: 3, within: 250nm) >= 220nm\n");
    for (steps(220)) |g| {
        const close = struct {
            fn f(a: Allocator, gap: i64, n: usize) ![]const F {
                return if (gap < 220) repeat(a, F.length(gap), n) else none;
            }
        }.f;
        try everywhere("row4", d, try on("cut", try array(al, 4, 1, g, g)), "adj", none);
        try everywhere("array2x2", d, try on("cut", try array(al, 2, 2, g, g)), "adj", none);
        try everywhere("array3x2", d, try on("cut", try array(al, 3, 2, g, g)), "adj", try close(al, g, 5));
        try everywhere("array3x3", d, try on("cut", try array(al, 3, 3, g, g)), "adj", try close(al, g, 12));
    }
    for ([_]i64{ 249, 250, 251 }) |gy| {
        try everywhere("rows_apart", d, try on("cut", try array(al, 3, 2, 219, gy)), "adj", if (gy == 249) try repeat(al, F.length(219), 4) else none);
    }
    var l = try on("cut", try array(al, 3, 2, 219, 219));
    defer l.deinit();
    var r = try common.run(d, &l);
    defer r.deinit();
    try testing.expectEqual(@as(u64, 2), r.row("adj").examined);
    const centred = try common.newDeck(al, &.{"cut"}, "rule adjc adjacent_space(cut, center; cuts: 3, within: 300nm) >= 300nm\n");
    for (steps(300)) |p| {
        try everywhere("tee", centred, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ -p, 0, 100 - p, 100 }, .{ p, 0, 100 + p, 100 }, .{ 0, p, 100, 100 + p } }), "adjc", if (p < 300) try repeat(al, F.length(p), 3) else none);
    }
    try everywhere("array2x2", centred, try on("cut", &.{ .{ 0, 0, 100, 100 }, .{ 299, 0, 399, 100 }, .{ 0, 299, 100, 399 }, .{ 299, 299, 399, 399 } }), "adjc", none);
}

test "redundant via counts the cuts within reach" {
    // `redundant_via(cut; within: 100nm) >= 2`, and `>= 3` (DRC-066,
    // DRC-117): one finding per drawn cut with fewer cuts, itself included,
    // within 100 nm (inclusive, Euclidean), measuring the count, at the
    // cut's centre.
    // Oracle: counts by construction: a pair side by side at 99/100/101; a
    // pair diagonal at Euclidean 99.2/100/100.8; one cut alone; two abutting
    // and two overlapping cuts (each counts the other); a row of three 100
    // apart, where the ends see two and the middle three.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{ "cut", "other" }, "rule two redundant_via(cut; within: 100nm) >= 2\nrule three redundant_via(cut; within: 100nm) >= 3\n");
    const Case = struct {
        fn f(dk: []const u8, name: []const u8, cuts: []const [4]i64, t2: []const F, t3: []const F) !void {
            var l = try on("cut", cuts);
            try l.rect("other", -1000, -1000, -900, -900);
            try two(name, dk, l, "two", t2, "three", t3);
        }
        fn at(a: Allocator, n: u32, centres: []const [2]i64) ![]const F {
            const out = try a.alloc(F, centres.len);
            for (out, centres) |*o, p| o.* = F.count(n).atPoint(p[0], p[1]);
            return out;
        }
    };
    for (steps(100)) |g| {
        const centres = [_][2]i64{ .{ 50, 50 }, .{ 150 + g, 50 } };
        const n: u32 = if (g > 100) 1 else 2;
        try Case.f(d, "pair", &.{ .{ 0, 0, 100, 100 }, .{ 100 + g, 0, 200 + g, 100 } }, if (g > 100) try Case.at(al, 1, &centres) else none, try Case.at(al, n, &centres));
    }
    for ([_]i64{ 79, 80, 81 }) |dy| {
        const near = dy != 81;
        try Case.f(d, "diagonal", &.{ .{ 0, 0, 100, 100 }, .{ 160, 100 + dy, 260, 200 + dy } }, if (near) none else try repeat(al, F.count(1), 2), try repeat(al, F.count(if (near) 2 else 1), 2));
    }
    try Case.f(d, "single", &.{.{ 0, 0, 100, 100 }}, try Case.at(al, 1, &.{.{ 50, 50 }}), try Case.at(al, 1, &.{.{ 50, 50 }}));
    try Case.f(d, "abutting", &.{ .{ 0, 0, 100, 100 }, .{ 100, 0, 200, 100 } }, none, try repeat(al, F.count(2), 2));
    try Case.f(d, "overlapping", &.{ .{ 0, 0, 100, 100 }, .{ 50, 0, 150, 100 } }, none, try repeat(al, F.count(2), 2));
    try Case.f(d, "row_of_three", &.{ .{ 0, 0, 100, 100 }, .{ 200, 0, 300, 100 }, .{ 400, 0, 500, 100 } }, none, try Case.at(al, 2, &.{ .{ 50, 50 }, .{ 450, 50 } }));
    try Case.f(d, "empty", &.{}, none, none);
}
