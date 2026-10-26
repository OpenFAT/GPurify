//! The cut-layer kinds through deck text, second half: `min_cuts`,
//! `via_stack`, `via_map`, `stack_space`, `via_redundancy` and
//! `cut_area_change`. Each case's oracle is restated on its test, run under
//! the eight symmetries of the square at two translations. Ported from
//! crates/check/tests/drc/via_deck.rs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const F = common.Finding;
const Layout = common.Layout;
const gpa = common.gpa;
const steps = common.steps;
const below = common.below;
const opt = common.opt;
const everywhere = common.everywhere;

/// A rectangle on a named layer.
const Box = struct { []const u8, [4]i64 };

const none: []const F = &.{};

// ---- private ----

/// `l` with `boxes` added.
fn add(l: Layout, boxes: []const Box) !Layout {
    var out = l;
    for (boxes) |b| try out.rect(b[0], b[1][0], b[1][1], b[1][2], b[1][3]);
    return out;
}

fn layout(boxes: []const Box) !Layout {
    return add(.{}, boxes);
}

/// Two rules' claims over `l`, everywhere; `l` is freed.
fn two(name: []const u8, d: []const u8, l: Layout, id1: []const u8, f1: []const F, id2: []const u8, f2: []const F) !void {
    var held = l;
    defer held.deinit();
    try common.checkEverywhere(name, d, &held, &.{ .{ .id = id1, .findings = f1 }, .{ .id = id2, .findings = f2 } });
}

fn counts(arena: Allocator, values: []const u32) ![]const F {
    const out = try arena.alloc(F, values.len);
    for (out, values) |*f, v| f.* = F.count(v);
    return out;
}

/// One finding of count 1 at `(x, y)`.
fn oneAt(x: i64, y: i64) common.Opt {
    return opt(true, F.count(1).atPoint(x, y));
}

/// A 3000 x `high` m1 bar `long` long with a 50 wide stub up from it and a
/// 30 cut `gap` above the bar on the stub.
fn stub(long: i64, high: i64, gap: i64) !Layout {
    return layout(&.{ .{ "m1", .{ 0, 0, long, high } }, .{ "m1", .{ 1000, high, 1050, high + 2000 } }, .{ "via", .{ 1010, high + gap, 1040, high + gap + 30 } } });
}

fn withFar(l: Layout) !Layout {
    return add(l, &.{.{ "m2", .{ 900, -500, 1200, 3000 } }});
}

fn cut(layer: []const u8, x: i64, y: i64) Box {
    return .{ layer, .{ x, y, x + 100, y + 100 } };
}

fn plate() !Layout {
    return layout(&.{.{ "m1", .{ 0, 0, 3000, 3000 } }});
}

/// One finding of `n` at (50, 50).
fn oneOf(n: u32) common.Opt {
    return opt(true, F.count(n).atPoint(50, 50));
}

/// Pads on every metal, single cuts on `cuts` and a second cut on `double`.
fn tower(cuts: []const []const u8, double: []const []const u8) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    for ([_][]const u8{ "m1", "m2", "m3", "m4", "m5" }) |m| try l.rect(m, -100, -100, 500, 200);
    for (cuts) |v| try l.rect(v, 0, 0, 100, 100);
    for (double) |v| try l.rect(v, 300, 0, 400, 100);
    return l;
}

fn pads(boxes: []const Box) !Layout {
    var l = try layout(boxes);
    for ([_][]const u8{ "m1", "m2", "m3" }) |m| try l.rect(m, -500, -500, 1000, 600);
    return l;
}

/// A pad on both metals over `[xlo, ylo, xhi, yhi]`.
fn padOf(l: Layout, b: [4]i64) !Layout {
    return add(l, &.{ .{ "m1", b }, .{ "m2", b } });
}

/// A cut on pads no larger than itself at `x`.
fn tight(l: Layout, x: i64) !Layout {
    return add(try padOf(l, .{ x, 0, x + 100, 100 }), &.{.{ "v", .{ x, 0, x + 100, 100 } }});
}

/// A cut on a 1000 square pad.
fn roomy(l: Layout) !Layout {
    return add(try padOf(l, .{ 0, 0, 1000, 1000 }), &.{.{ "v", .{ 100, 100, 200, 200 } }});
}

/// The rate's finding when it is below the 0.5 sign-off.
fn rate(dead: u32, vias: u32) common.Opt {
    const r = 1.0 - @as(f64, @floatFromInt(dead)) / @as(f64, @floatFromInt(vias));
    return opt(r < 0.5, F.ratio(r));
}

/// A 1000 pad on both metals at `x`.
fn pad(l: Layout, x: i64) !Layout {
    return padOf(l, .{ x, 0, x + 1000, 1000 });
}

/// `n` pre cuts in a row from `x`.
fn pre(l: Layout, x: i64, n: i64) !Layout {
    var out = l;
    var i: i64 = 0;
    while (i < n) : (i += 1) try out.rect("v", x + 50 + 150 * i, 50, x + 150 + 150 * i, 150);
    return out;
}

fn area(a: i128) common.Opt {
    return opt(true, F.area(a));
}

test "min cuts with a distance holds thin wires near wide ones" {
    // LEF `MINIMUMCUT 2 WIDTH 0.11 LENGTH 2.0 WITHIN 0.5` on `m1` (Minimum
    // Cut Rule Example 4 scaled by a tenth): `min_cuts(via, m1, m2; width:
    // 110nm, length: 2000nm, distance: 500nm) >= 2` (DRC-066). A one-cut via
    // held is one finding, its count 1, at the cut's centre.
    // Oracle: the LEF text and Figure 1-11, wires drawn to a width, a length
    // and a distance, each swept one step either side: a 50 wide stub up from
    // a 200 x 3000 bar with a 30 cut 499, 500 and 501 above the bar (held
    // below 500); the bar 1999, 2000 and 2001 long (held above 2000); the bar
    // 110 and 111 high (wide only above 110). Not held: a cut on the bar
    // itself, a two-cut via on the stub, a thin wire 100 off the bar.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "via", "m1", "m2" }, "rule mct min_cuts(via, m1, m2; width: 110nm, length: 2000nm, distance: 500nm) >= 2\n");
    for (steps(500)) |gap| try everywhere("distance", d, try withFar(try stub(3000, 200, gap)), "mct", opt(gap < 500, F.count(1).atPoint(1025, 215 + gap)));
    for (steps(2000)) |long| try everywhere("length", d, try withFar(try stub(long, 200, 100)), "mct", opt(long > 2000, F.count(1).atPoint(1025, 315)));
    try everywhere("width/110", d, try withFar(try stub(3000, 110, 100)), "mct", none);
    try everywhere("width/111", d, try withFar(try stub(3000, 111, 100)), "mct", oneAt(1025, 226));
    try everywhere("on_the_wide_wire", d, try withFar(try layout(&.{ .{ "m1", .{ 0, 0, 3000, 200 } }, .{ "via", .{ 1010, 100, 1040, 130 } } })), "mct", none);
    try everywhere("two_cuts", d, try withFar(try add(try stub(3000, 200, 100), &.{.{ "via", .{ 1010, 360, 1040, 390 } }})), "mct", none);
    try everywhere("not_joined", d, try withFar(try layout(&.{ .{ "m1", .{ 0, 0, 3000, 200 } }, .{ "m1", .{ 1000, 300, 1050, 2300 } }, .{ "via", .{ 1010, 400, 1040, 430 } } })), "mct", none);
}

test "min cuts counts the cuts of each via on a wide wire" {
    // LEF `MINIMUMCUT 2 WIDTH 1.0` on `m1`, vias from `m2`: `min_cuts(via,
    // m1, m2; width: 1000nm) >= 2` (`mc`) and with `within: 300nm` (`mcw`)
    // (DRC-066): a via is the cuts joining one `m1` figure to one `m2`
    // figure, split by `within` into groups of cuts closer than 300 nm; one
    // held by the part of `m1` wider than 1000 nm needs two cuts, and each of
    // its cuts is reported with its count.
    // Oracle: LEF/DEF 5.8 "the number of cuts a via must have when it is on a
    // wide wire or pin whose width is greater than width", on vias and wires
    // drawn to a count and a width: one cut under an `m2` pad; two under one
    // pad 200 apart (one via, one group) and 400 apart (two groups under
    // `within`); two cuts under two pads (two vias); a cut with no `m2` over
    // it; a wire 999, 1000, 1001 wide with one cut (held only when strictly
    // wider); a cut on a 500 tab off the plate; a cut on no `m1`.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{ "via", "m1", "m2" }, "rule mc min_cuts(via, m1, m2; width: 1000nm) >= 2\nrule mcw min_cuts(via, m1, m2; width: 1000nm, within: 300nm) >= 2\n");
    const c1 = try counts(al, &.{1});
    const c11 = try counts(al, &.{ 1, 1 });
    try two("single", d, try add(try plate(), &.{ .{ "via", .{ 1000, 1000, 1100, 1100 } }, .{ "m2", .{ 900, 900, 1200, 1200 } } }), "mc", c1, "mcw", c1);
    for ([_]i64{ 200, 400 }) |gap| {
        const x = 1100 + gap;
        try two(if (gap == 200) "pair_close" else "pair_far", d, try add(try plate(), &.{ .{ "via", .{ 1000, 1000, 1100, 1100 } }, .{ "via", .{ x, 1000, x + 100, 1100 } }, .{ "m2", .{ 900, 900, x + 200, 1200 } } }), "mc", none, "mcw", if (gap == 400) c11 else none);
    }
    try two("two_pads", d, try add(try plate(), &.{ .{ "via", .{ 1000, 1000, 1100, 1100 } }, .{ "via", .{ 1300, 1000, 1400, 1100 } }, .{ "m2", .{ 900, 900, 1150, 1200 } }, .{ "m2", .{ 1250, 900, 1500, 1200 } } }), "mc", c11, "mcw", c11);
    try two("no_far_metal", d, try add(try plate(), &.{.{ "via", .{ 1000, 1000, 1100, 1100 } }}), "mc", c1, "mcw", c1);
    for ([_]i64{ 999, 1000, 1001 }) |w| {
        const held = if (w > 1000) c1 else none;
        try two("wire", d, try layout(&.{ .{ "m1", .{ 0, 0, 5000, w } }, .{ "via", .{ 2000, 100, 2100, 200 } }, .{ "m2", .{ 1900, 0, 2200, 300 } } }), "mc", held, "mcw", held);
    }
    try two("narrow_tab", d, try add(try plate(), &.{ .{ "m1", .{ 3000, 1000, 4000, 1500 } }, .{ "via", .{ 3500, 1200, 3600, 1300 } }, .{ "m2", .{ 3400, 1100, 3700, 1400 } } }), "mc", none, "mcw", none);
    try two("off_metal", d, try add(try plate(), &.{ .{ "via", .{ 5000, 5000, 5100, 5100 } }, .{ "m2", .{ 4900, 4900, 5200, 5200 } } }), "mc", none, "mcw", none);
}

test "via stack reports each stack taller than the limit" {
    // `via_stack(v1, v2, v3, v4) <= 2` (DRC-065, LEF `MAXVIASTACK 2`): a cut
    // stacks on a cut of the layer below that it overlaps; the cut third
    // from the bottom of each stack taller than two is one finding,
    // measuring the stack's height.
    // Oracle: LEF/DEF 5.8 "a via is considered to be in a stack with another
    // via if the cut of the first via overlaps any part of the cut of the
    // second via", on 100 nm cuts stacked to a height: towers of two, three
    // and four (the four-high one reported once, measuring 4, at its third
    // cut's centre); three cuts overlapping by half; a v3 cut beside the v2
    // cut (two stacks of two); a v2 cut abutting the v1 cut (touching is not
    // stacking); a v1 bar under two v2 cuts each carrying a v3 (two stacks of
    // three).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "v1", "v2", "v3", "v4" }, "rule stack via_stack(v1, v2, v3, v4) <= 2\n");
    const all = [4]Box{ cut("v1", 0, 0), cut("v2", 0, 0), cut("v3", 0, 0), cut("v4", 0, 0) };
    try everywhere("tower/2", d, try layout(all[0..2]), "stack", none);
    try everywhere("tower/3", d, try layout(all[0..3]), "stack", oneOf(3));
    try everywhere("tower/4", d, try layout(all[0..4]), "stack", opt(true, F.count(4).atPoint(50, 50)));
    try everywhere("half_overlap", d, try layout(&.{ cut("v1", 0, 0), cut("v2", 50, 0), cut("v3", 100, 0) }), "stack", opt(true, F.count(3)));
    try everywhere("broken", d, try layout(&.{ cut("v1", 0, 0), cut("v2", 0, 0), cut("v3", 300, 0), cut("v4", 300, 0) }), "stack", none);
    try everywhere("abutting", d, try layout(&.{ cut("v1", 0, 0), cut("v2", 100, 0), cut("v3", 100, 0) }), "stack", none);
    try everywhere("branching", d, try layout(&.{ .{ "v1", .{ 0, 0, 300, 100 } }, .{ "v2", .{ 0, 0, 100, 100 } }, .{ "v2", .{ 200, 0, 300, 100 } }, .{ "v3", .{ 0, 0, 100, 100 } }, .{ "v3", .{ 200, 0, 300, 100 } } }), "stack", &[_]F{ F.count(3), F.count(3) });
}

test "via stack single counts only single cut vias" {
    // `via_stack(m1, v1, …, m5, single) <= 2` (DRC-065): LEF `MAXVIASTACK
    // 2` over single-cut vias only, "A double-cut or larger via interrupts
    // the stack".
    // Oracle: the LEF text's own example, "a via stack consisting of single
    // via12, single via23, double-cut via34, and single via45 has a single-cut
    // stack of height 2 for via12 and via23, and a single-cut stack of height
    // 1 for via45" (legal at 2); three single cuts stacked (height 3, at its
    // top cut's centre); the same with the middle via doubled (no stack over
    // 1); a tower of four single cuts where a second v2 cut sits on another
    // m3 figure (each via still single: height 4).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "m1", "v1", "m2", "v2", "m3", "v3", "m4", "v4", "m5" }, "rule stack via_stack(m1, v1, m2, v2, m3, v3, m4, v4, m5, single) <= 2\n");
    try everywhere("lef_example", d, try tower(&.{ "v1", "v2", "v3", "v4" }, &.{"v3"}), "stack", none);
    try everywhere("three_single", d, try tower(&.{ "v1", "v2", "v3" }, &.{}), "stack", oneOf(3));
    try everywhere("middle_double", d, try tower(&.{ "v1", "v2", "v3" }, &.{"v2"}), "stack", none);
    try everywhere("split_pads", d, try add(try tower(&.{ "v1", "v2", "v3", "v4" }, &.{}), &.{ .{ "m3", .{ 1000, -100, 1500, 200 } }, .{ "v2", .{ 1100, 0, 1200, 100 } } }), "stack", oneOf(4));
}

test "via map flags a wrong cut between mapped widths" {
    // `LEF58_METALWIDTHVIAMAP` (`via_map`, DRC-067), as OpenROAD parses it
    // (`VIA cutLayer w1 w2 viaName`): `vm`, exact widths 50 and 80 with a 30
    // x 30 cut; `vr`, ranges 40..60 and 70..90 with a 30 x 40 cut, either
    // way round. A cut where the widths fall in the row's bands but whose
    // size is not the mapped cut is one finding measuring a count of 0.
    // Oracle: the parser's grammar, wires drawn to a width: an `m1` bar `w1`
    // high crossing an `m2` bar `w2` wide, a cut where they cross. The mapped
    // cut passes, a 40 x 40 cut fails both rows while both widths are in
    // their bands: `w1` swept around 50 (only 50 is `vm`'s) and `w2` around 80
    // (only 80); a 40 x 30 cut is `vr`'s 30 x 40 turned; a cut off the bars is
    // held by neither.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "v1", "m1", "m2" }, "rule vm via_map(v1, m1, m2; below_min: 50nm, below_max: 50nm, above_min: 80nm, above_max: 80nm, cut: 30nm x 30nm)\nrule vr via_map(v1, m1, m2; below_min: 40nm, below_max: 60nm, above_min: 70nm, above_max: 90nm, cut: 30nm x 40nm)\n");
    const Case = struct {
        fn f(dk: []const u8, name: []const u8, w1: i64, w2: i64, c: [2]i64, vm: bool, vr: bool) !void {
            const wrong = [1]F{F.count(0)};
            try two(name, dk, try layout(&.{ .{ "m1", .{ 0, 0, 1000, w1 } }, .{ "m2", .{ 460, -500, 460 + w2, 500 } }, .{ "v1", .{ 480, 5, 480 + c[0], 5 + c[1] } } }), "vm", if (vm) &wrong else none, "vr", if (vr) &wrong else none);
        }
    };
    try Case.f(d, "mapped", 50, 80, .{ 30, 30 }, false, true);
    try Case.f(d, "range_mapped", 50, 80, .{ 30, 40 }, true, false);
    try Case.f(d, "range_turned", 50, 80, .{ 40, 30 }, true, false);
    for (steps(50)) |w1| try Case.f(d, "below", w1, 80, .{ 40, 40 }, w1 == 50, true);
    for (steps(80)) |w2| try Case.f(d, "above", 50, w2, .{ 40, 40 }, w2 == 80, true);
    try two("off_the_wires", d, try layout(&.{ .{ "m1", .{ 0, 0, 1000, 50 } }, .{ "m2", .{ 460, -500, 540, 500 } }, .{ "v1", .{ 2000, 2000, 2040, 2040 } } }), "vm", none, "vr", none);
}

test "stack space exempts only aligned same net stacks" {
    // `stack_space(v2, v1, m2; same_net: true) >= 200nm` (`ss`, LEF Spacing
    // Rule Example 7's `SPACING 0.20 SAMENET LAYER cut12 STACK`) and
    // `stack_space(v2, v1, m2) >= 200nm` (`all`) (DRC-065): "same-net cuts on
    // two different layers can be stacked if they are aligned. If the cuts
    // are not the same size, the smaller cut must be completely covered by
    // the larger cut ... If both cuts are the same size, the centers of the
    // cuts must be aligned ... otherwise, the cuts must have cutSpacing
    // between them".
    // Oracle: the LEF text, cuts by construction, one net through pads on
    // every metal unless stated: aligned equal cuts and a cut covered by a
    // larger one (stacked, legal); equal cuts offset by half (overlapping, not
    // aligned: a gap of 0); a `v1` cut beside the `v2` cut 199, 200 and 201
    // away; two cuts 150 apart on different nets, which only `all` holds.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "m1", "v1", "m2", "v2", "m3" },
        \\connect conductors [m1, m2, m3]
        \\connect touch_within_layer
        \\connect via v1 [m1, m2]
        \\connect via v2 [m2, m3]
        \\rule ss stack_space(v2, v1, m2; same_net: true) >= 200nm
        \\rule all stack_space(v2, v1, m2) >= 200nm
        \\
    );
    const zero = [1]F{F.length(0)};
    try two("aligned", d, try pads(&.{ .{ "v1", .{ 0, 0, 100, 100 } }, .{ "v2", .{ 0, 0, 100, 100 } } }), "ss", none, "all", none);
    try two("covered", d, try pads(&.{ .{ "v1", .{ -20, -20, 120, 120 } }, .{ "v2", .{ 0, 0, 100, 100 } } }), "ss", none, "all", none);
    try two("offset", d, try pads(&.{ .{ "v1", .{ 50, 0, 150, 100 } }, .{ "v2", .{ 0, 0, 100, 100 } } }), "ss", &zero, "all", &zero);
    for (steps(200)) |g| {
        const near = below(g, 200);
        try two("apart", d, try pads(&.{ .{ "v1", .{ 100 + g, 0, 200 + g, 100 } }, .{ "v2", .{ 0, 0, 100, 100 } } }), "ss", common.slice(&near), "all", common.slice(&near));
    }
    var nets: Layout = .{};
    for ([_][]const u8{ "m1", "m2", "m3" }) |m| {
        try nets.rect(m, -100, -100, 200, 200);
        try nets.rect(m, 250, -100, 550, 200);
    }
    try two("different_nets", d, try add(nets, &.{ .{ "v1", .{ 250, 0, 350, 100 } }, .{ "v2", .{ 0, 0, 100, 100 } } }), "ss", none, "all", &[_]F{F.length(150)});
}

test "via redundancy rates the vias with room for a second cut" {
    // The redundant-via rate (`via_redundancy`, DRC-117, Xu et al. ASP-DAC
    // 2005 with deck-supplied values): cuts `v` 100 square between `m1` and
    // `m2`, a second cut 200 along an axis, 100 from every cut, a rate of 0.5
    // signing off.
    // Oracle: the rate `1 - dead / vias` by hand: a cut on a 1000 square pad
    // (room: rate 1), on pads no larger than itself (dead: 0, found), two cuts
    // on such a pad (doubled already: 1); a cut whose only free neighbour
    // lies 99, 100, 101 from a stray cut (dead at 99: found); one dead of two
    // vias (0.5, at the sign-off) and two of three (1/3, found).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "v", "m1", "m2" }, "rule vr via_redundancy(v, m1, m2; pitch: 200nm, space: 100nm) >= 0.5\n");
    try everywhere("room", d, try roomy(.{}), "vr", rate(0, 1));
    try everywhere("no_room", d, try tight(.{}, 0), "vr", rate(1, 1));
    try everywhere("doubled", d, try add(try padOf(.{}, .{ 0, 0, 100, 300 }), &.{ .{ "v", .{ 0, 0, 100, 100 } }, .{ "v", .{ 0, 200, 100, 300 } } }), "vr", rate(0, 1));
    try everywhere("one_of_two", d, try tight(try roomy(.{}), 3000), "vr", rate(1, 2));
    try everywhere("two_of_three", d, try tight(try tight(try roomy(.{}), 3000), 5000), "vr", rate(2, 3));
    for (steps(100)) |gap| {
        try everywhere("stray", d, try layout(&.{ .{ "m1", .{ 0, 0, 2000, 300 } }, .{ "m2", .{ 100, 0, 400, 300 } }, .{ "v", .{ 100, 100, 200, 200 } }, .{ "v", .{ 400 + gap, 100, 500 + gap, 200 } } }), "vr", rate(@intFromBool(gap < 100), 1));
    }
}

test "cut area change holds each connector to its band" {
    // A connector's cut area between two databases (`cut_area_change`,
    // DRC-068, sky130 ct.irdrop in shape with deck-supplied values): pre cuts
    // on `v`, post cuts on `vc`, connectors `m1` x `m2`; bands from 1 cut
    // allow 10000 nm², from 4 cuts 40000 nm².
    // Oracle: areas by hand: three 100 nm pre cuts (30000) on one connector
    // against post 19999, 20000, 20001 (a change of 10001, 10000, 9999: one
    // finding of 10001); four pre cuts against none (40000, allowed) and five
    // (50000, found); two connectors on one m1 bar of two pre cuts each, only
    // the one whose cuts went missing found (20000); two pre cuts on m1 off m2
    // count for nothing; a connector with post cuts and no pre cut is not
    // judged; a post cut half off the footprint counts its inside half (a
    // change of 10000, allowed; the whole cut would be 30000).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "v", "vc", "m1", "m2" }, "rule ir cut_area_change(v, vc, m1, m2; cuts: [1, 4], change: [10000nm2, 40000nm2])\n");
    try everywhere("post_19999", d, try add(try pre(try pad(.{}, 0), 0, 3), &.{ .{ "vc", .{ 0, 500, 100, 699 } }, .{ "vc", .{ 0, 699, 99, 700 } } }), "ir", area(10_001));
    try everywhere("post_20000", d, try add(try pre(try pad(.{}, 0), 0, 3), &.{.{ "vc", .{ 0, 500, 100, 700 } }}), "ir", none);
    try everywhere("post_20001", d, try add(try pre(try pad(.{}, 0), 0, 3), &.{ .{ "vc", .{ 0, 500, 100, 700 } }, .{ "vc", .{ 500, 500, 501, 501 } } }), "ir", none);
    try everywhere("four_lost", d, try pre(try pad(.{}, 0), 0, 4), "ir", none);
    try everywhere("five_lost", d, try pre(try pad(.{}, 0), 0, 5), "ir", area(50_000));
    const bar = try layout(&.{ .{ "m1", .{ 0, 0, 3000, 1000 } }, .{ "m2", .{ 0, 0, 1000, 1000 } }, .{ "m2", .{ 2000, 0, 3000, 1000 } } });
    try everywhere("one_lost_of_two", d, try add(try pre(try pre(bar, 0, 2), 2000, 2), &.{ .{ "vc", .{ 2050, 50, 2150, 150 } }, .{ "vc", .{ 2200, 50, 2300, 150 } } }), "ir", area(20_000));
    try everywhere("off_the_upper", d, try add(try pad(.{}, 0), &.{ .{ "m1", .{ 1000, 0, 2000, 1000 } }, .{ "v", .{ 1200, 200, 1300, 300 } }, .{ "v", .{ 1400, 200, 1500, 300 } } }), "ir", none);
    try everywhere("post_only", d, try add(try pad(.{}, 0), &.{.{ "vc", .{ 100, 100, 600, 600 } }}), "ir", none);
    try everywhere("post_half_off", d, try add(try pre(try pad(.{}, 0), 0, 1), &.{.{ "vc", .{ 800, 400, 1200, 500 } }}), "ir", none);
}
