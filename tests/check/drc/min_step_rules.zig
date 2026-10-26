//! `min_step` (LEF `MINSTEP`) and its `LEF58_MINSTEP` qualifiers (DRC-020),
//! from deck text, under the eight symmetries of the square. Ported from
//! crates/check/tests/drc/min_step_rules.rs.

const std = @import("std");
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;
const Finding = common.Finding;
const Layout = common.Layout;
const Measurement = check.report.Measurement;

/// One `(rule, finding)` claim, as `common.byRule` takes them.
const Claim = std.meta.Child(@typeInfo(@TypeOf(common.byRule)).@"fn".param_types[2].?);

const step_rules =
    \\rule out min_step(met1; corner: outside, length_sum: none) >= 50nm
    \\rule sum min_step(met1; corner: outside, length_sum: 80nm) >= 50nm
    \\rule in min_step(met1; corner: inside, length_sum: none) >= 50nm
    \\rule st min_step(met1; corner: step, length_sum: none) >= 50nm
    \\rule e1 min_step(met1; max_edges: 1) >= 50nm
    \\rule e2 min_step(met1; max_edges: 2) >= 50nm
;

const step_ids = [_][]const u8{ "out", "sum", "in", "st", "e1", "e2" };

const adj_rules =
    \\rule adj min_step(met1; adjacent: 60nm, except_rectangle: false) >= 50nm
    \\rule adj.rect min_step(met1; adjacent: 60nm, except_rectangle: true) >= 50nm
    \\rule eol min_step(met1; adjacent: 30nm, adjacent_eol: 120nm, except_rectangle: false) >= 50nm
    \\rule between min_step(met1; between_eol: 120nm) >= 50nm
;

const adj_ids = [_][]const u8{ "adj", "adj.rect", "eol", "between" };

/// A bump on a bar, and its left and right x.
const Bump = struct { shape: Layout, l: i64, r: i64 };

// ---- private ----

/// A count limit.
fn most(n: u32) Measurement {
    return .count(n);
}

/// One polygon on `met1`.
fn met1(points: []const [2]i64) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    try l.polygon("met1", points);
    return l;
}

/// `checkEverywhere` of `rules` over `layout` (freed), each id in `ids`
/// claiming exactly its `claims`.
fn expect(name: []const u8, rules: []const u8, layout: Layout, ids: []const []const u8, claims: []const Claim) !void {
    var l = layout;
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    try common.checkEverywhere(name, try common.deck(al, rules), &l, try common.byRule(al, ids, claims));
}

/// A bump `w` wide and `h` high on a 1000 x 200 bar.
fn bump(w: i64, h: i64) !Bump {
    const l = 500 - @divTrunc(w, 2);
    const r = l + w;
    return .{ .shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 200 }, .{ r, 200 }, .{ r, 200 + h }, .{ l, 200 + h }, .{ l, 200 }, .{ 0, 200 } }), .l = l, .r = r };
}

test "an outside staircase is one run judged by count and by length sum" {
    // Oracle: LEF 5.8 Figure 1-14 a and Example 1-16, swept one unit either
    // side of the 50 nm minStepLength. Two edges `s` under 50 at an outside
    // corner are one run of two short edges: `corner: outside` rejects it
    // (measuring 2 edges), `LENGTHSUM 0.08` only when `2s > 80`, `MAXEDGES 1`
    // (two is more than one) but not `MAXEDGES 2`; no inside corner or step.
    // The marker is the centre of the run's vertices, `(1000 - s/2, 1000 -
    // s/2)`. At and above 50 both edges are long and nothing is reported.
    var label: [32]u8 = undefined;
    for ([_]i64{ 39, 40, 41, 49, 50, 51 }) |s| {
        var want: std.ArrayList(Claim) = .empty;
        defer want.deinit(gpa);
        if (s < 50) {
            try want.append(gpa, .{ "out", Finding.count(2).limitOf(most(1)).atHalf(2000 - s, 2000 - s) });
            try want.append(gpa, .{ "e1", Finding.count(2).limitOf(most(1)).atHalf(2000 - s, 2000 - s) });
            if (2 * s > 80) try want.append(gpa, .{ "sum", Finding.length(2 * s).limitOf(.length(80)).atHalf(2000 - s, 2000 - s) });
        }
        const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 1000 - s }, .{ 1000 - s, 1000 - s }, .{ 1000 - s, 1000 }, .{ 0, 1000 } });
        try expect(try std.fmt.bufPrint(&label, "outside_two/{d}", .{s}), step_rules, shape, &step_ids, want.items);
    }
}

test "lef figure d four short edges break every outside row" {
    // Oracle: LEF 5.8 Figure 1-14 d: four 40 nm edges (160 in all) at an
    // outside corner. Every outside row rejects the run of four, `LENGTHSUM
    // 0.08` too (160 > 80, measuring 160), and both `MAXEDGES` rows (four is
    // more than one and than two); the marker is the centre of the
    // staircase's vertices, (960, 960).
    const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 920 }, .{ 960, 920 }, .{ 960, 960 }, .{ 920, 960 }, .{ 920, 1000 }, .{ 0, 1000 } });
    try expect("lef_figure_d", step_rules, shape, &step_ids, &.{
        .{ "out", Finding.count(4).atPoint(960, 960).limitOf(most(1)) },
        .{ "sum", Finding.length(160).atPoint(960, 960).limitOf(.length(80)) },
        .{ "e1", Finding.count(4).atPoint(960, 960).limitOf(most(1)) },
        .{ "e2", Finding.count(4).atPoint(960, 960).limitOf(most(2)) },
    });
}

test "an inside staircase breaks only the inside row" {
    // Oracle: by construction. Two 40 nm edges where the long edges either
    // side turn right (an inside corner, the notch of an L): only `corner:
    // inside` and `MAXEDGES 1` reject the run of two, at (520, 520).
    const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 500 }, .{ 540, 500 }, .{ 540, 540 }, .{ 500, 540 }, .{ 500, 1000 }, .{ 0, 1000 } });
    try expect("inside_two", step_rules, shape, &step_ids, &.{
        .{ "in", Finding.count(2).atPoint(520, 520).limitOf(most(1)) },
        .{ "e1", Finding.count(2).atPoint(520, 520).limitOf(most(1)) },
    });
}

test "a single jog is a step and nothing else" {
    // The limits stated with each finding are the rule's: the most short
    // edges a corner kind allows in a row is 1, a step's 0, `MAXEDGES n`'s n,
    // and `LENGTHSUM`'s length.
    //
    // Oracle: by construction. One 40 nm jog between two long edges running
    // the same way is a step: only `corner: step` rejects it, a run of one
    // edge, at the jog's middle (500, 520). One short edge is not more than
    // one, so neither `MAXEDGES` row fires.
    const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 500 }, .{ 500, 500 }, .{ 500, 540 }, .{ 0, 540 } });
    try expect("step", step_rules, shape, &step_ids, &.{.{ "st", Finding.count(1).atPoint(500, 520).limitOf(most(0)) }});
}

test "a narrow line end is no corner and no step" {
    // Oracle: by construction. A 40 nm wide line's two short ends each sit
    // between long edges running opposite ways: no corner and no step, and
    // one short edge is within either `MAXEDGES`.
    try expect("line_end", step_rules, try common.met1(&.{.{ 0, 0, 1000, 40 }}), &step_ids, &.{});
}

test "a ring of only short edges is one run with no corner" {
    // Oracle: by construction. A 40 x 30 rectangle has no edge of 50 or
    // more, so the whole ring is one run of four short edges with no long
    // edge on either side: no corner kind applies, and `MAXEDGES 1` and `2`
    // both see four, at the rectangle's centre.
    try expect("all_short", step_rules, try common.met1(&.{.{ 0, 0, 40, 30 }}), &step_ids, &.{
        .{ "e1", Finding.count(4).atPoint(20, 15).limitOf(most(1)) },
        .{ "e2", Finding.count(4).atPoint(20, 15).limitOf(most(2)) },
    });
}

test "a bump s short sides offend adjacent by its top s length" {
    // Oracle: `TritonRoute`'s `checkMetalShape_lef58MinStep_minAdjLength`
    // and `_noBetweenEol`, swept one unit either side of 60. A bump 40 high:
    // each 40 side offends `adj` while the top beside it is under 60, and
    // `eol` always (the top is an end of line under 120); side, top and side
    // are one `between` finding. Each side's box runs from the bar's corner
    // to the top's far end, 200 to 240 high.
    var label: [32]u8 = undefined;
    for ([_]i64{ 59, 60, 61 }) |t| {
        const b = try bump(t, 40);
        const sides = [2]Finding{ Finding.length(40).atHalf(b.l + 1000, 440), Finding.length(40).atHalf(b.r, 440) };
        var want: std.ArrayList(Claim) = .empty;
        defer want.deinit(gpa);
        for ([_][]const u8{ "eol", "adj", "adj.rect" }) |rule| {
            if (!std.mem.eql(u8, rule, "eol") and t >= 60) continue;
            for (sides) |f| try want.append(gpa, .{ rule, f });
        }
        try want.append(gpa, .{ "between", Finding.length(40).atHalf(b.l + b.r, 440) });
        try expect(try std.fmt.bufPrint(&label, "bump_top/{d}", .{t}), adj_rules, b.shape, &adj_ids, want.items);
    }
}

test "a bump s top offends adjacent and its sides join below the limit" {
    // Oracle: the same checker, a bump 40 wide with its height swept around
    // 50. Its 40 top offends `adj` beside sides under 60; below 50 the sides
    // are short too and offend `adj`, `eol` (beside the top's end of line)
    // and make one `between` row.
    var label: [32]u8 = undefined;
    for ([_]i64{ 49, 50, 51 }) |h| {
        const b = try bump(40, h);
        var want: std.ArrayList(Claim) = .empty;
        defer want.deinit(gpa);
        for ([_][]const u8{ "adj", "adj.rect" }) |rule| {
            try want.append(gpa, .{ rule, Finding.length(40).atHalf(b.l + b.r, 400 + h) });
            if (h < 50) {
                try want.append(gpa, .{ rule, Finding.length(h).atHalf(b.l + 1000, 400 + h) });
                try want.append(gpa, .{ rule, Finding.length(h).atHalf(b.r, 400 + h) });
            }
        }
        if (h < 50) {
            try want.append(gpa, .{ "eol", Finding.length(h).atHalf(b.l + 1000, 400 + h) });
            try want.append(gpa, .{ "eol", Finding.length(h).atHalf(b.r, 400 + h) });
            try want.append(gpa, .{ "between", Finding.length(h).atHalf(b.l + b.r, 400 + h) });
        }
        try expect(try std.fmt.bufPrint(&label, "bump_height/{d}", .{h}), adj_rules, b.shape, &adj_ids, want.items);
    }
}

test "a small rectangle offends unless rectangles are excepted" {
    // Oracle: the same checker and LEF's `EXCEPTRECTANGLE`. A 40 x 56
    // rectangle: its 40 ends offend `adj` beside 56 sides and `eol` beside
    // the sides' ends of line, `EXCEPTRECTANGLE` exempts it, and each end
    // starts a `between` row; every box is the whole rectangle, centred at
    // (20, 28).
    const f = Finding.length(40).atPoint(20, 28);
    try expect("rectangle", adj_rules, try common.met1(&.{.{ 0, 0, 40, 56 }}), &adj_ids, &.{
        .{ "adj", f }, .{ "adj", f }, .{ "eol", f }, .{ "eol", f }, .{ "between", f }, .{ "between", f },
    });
}

test "a tab s top offends adjacent eol by the end of line beside it" {
    // Oracle: the same checker, a tab 40 wide on a bar's end, its end of
    // line swept around 120: the tab's 40 top offends `eol` only while the
    // end of line beside it is under 120, at the centre of the two edges'
    // box.
    var label: [32]u8 = undefined;
    for ([_]i64{ 119, 120, 121 }) |e| {
        const shape = try met1(&.{ .{ 0, 0 }, .{ 1040, 0 }, .{ 1040, e }, .{ 1000, e }, .{ 1000, 200 }, .{ 0, 200 } });
        const one = [_]Claim{.{ "eol", Finding.length(40).atPoint(1020, 100) }};
        try expect(try std.fmt.bufPrint(&label, "tab_end/{d}", .{e}), adj_rules, shape, &adj_ids, if (e < 120) &one else &.{});
    }
}

test "a tip s sides offend by its end of line" {
    // Oracle: the same checker, a tip 40 long on a bar's end, its end swept
    // around 120: under 120 its two 40 sides offend `eol` and make one
    // `between` row (side, end of line, side).
    var label: [32]u8 = undefined;
    for ([_]i64{ 119, 120, 121 }) |e| {
        const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 1040, 100 }, .{ 1040, 100 + e }, .{ 1000, 100 + e }, .{ 1000, 400 }, .{ 0, 400 } });
        const three = [_]Claim{
            .{ "eol", Finding.length(40).atHalf(2040, 100 + e) },
            .{ "eol", Finding.length(40).atHalf(2040, 500) },
            .{ "between", Finding.length(40).atHalf(2040, 200 + e) },
        };
        try expect(try std.fmt.bufPrint(&label, "tip/{d}", .{e}), adj_rules, shape, &adj_ids, if (e < 120) &three else &.{});
    }
}

test "between eol needs the edge after the end of line to be short" {
    // Oracle: the same checker's `_noBetweenEol`, its third edge swept
    // around the limit. A tip 40 long on a bar's end, its end of line 60,
    // its top running back 50 or 49 to a bar narrowed by 10 or 9 above it:
    // the 40 side, the end of line and the top in a row. At 50 the top is
    // not short and nothing is reported; at 49 there is one finding (its
    // marker, x (991 + 1040) / 2, is off the lattice and not pinned). The
    // checker walks the ring one way, so the finding names whichever short
    // edge comes first: the 40 side, or under a mirror the 49 top; the value
    // is left unstated.
    var label: [32]u8 = undefined;
    for ([_]i64{ 50, 49 }) |top| {
        const x = 1040 - top;
        const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 1040, 100 }, .{ 1040, 160 }, .{ x, 160 }, .{ x, 400 }, .{ 0, 400 } });
        const one = [_]Claim{.{ "between", Finding.any().atHalf(x + 1040, 260) }};
        try expect(try std.fmt.bufPrint(&label, "asymmetric_tip/{d}", .{top}), adj_rules, shape, &.{"between"}, if (top < 50) &one else &.{});
    }
}

test "between eol s marker spans all three edges" {
    // Oracle: the same checker. The tip of the case above with its top 46
    // long (the bar above narrowed by 6): the between row's box takes all
    // three edges, x 994 to 1040 and y 100 to 160, so the marker is at
    // ((994 + 1040) / 2, 130) = (1017, 130), not the 40 side's and end's
    // (1020, 130). The box is the same whichever way the ring is walked.
    const shape = try met1(&.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 100 }, .{ 1040, 100 }, .{ 1040, 160 }, .{ 994, 160 }, .{ 994, 400 }, .{ 0, 400 } });
    try expect("marker", adj_rules, shape, &.{"between"}, &.{.{ "between", Finding.any().atPoint(1017, 130) }});
}
