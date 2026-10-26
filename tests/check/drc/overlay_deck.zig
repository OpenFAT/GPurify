//! The two-layer overlay kinds through deck text: the enclosure readings
//! (`opposite`, `noncoincident`, `adjacent`, by wire width), `full_width`,
//! `max_enclosure`, `extension`, `bend`/`covers_corner` and `projection`
//! spacing. Each case is the root `tests/exhaustive/drc_overlay.rs` fixture
//! of the same name, its oracle restated on the test, run through the deck
//! compiler and rule set. Ported from crates/check/tests/drc/overlay_deck.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const F = common.Finding;
const Opt = common.Opt;
const Layout = common.Layout;
const Claim = common.Claim;
const gpa = common.gpa;
const Arena = std.heap.ArenaAllocator;
const Measurement = check.report.Measurement;

/// One rectangle on a named layer.
const Box = struct { []const u8, [4]i64 };

/// An L-shaped host, `[0, 2000] x [0, 1000]` with `[0, 1000] x [0, 2000]`:
/// its concave corner is `(1000, 1000)`.
const l_host = [_][2]i64{ .{ 0, 0 }, .{ 2000, 0 }, .{ 2000, 1000 }, .{ 1000, 1000 }, .{ 1000, 2000 }, .{ 0, 2000 } };

/// A plus-shaped host, bars `[0, 1000] x [400, 600]` and `[400, 600] x [0,
/// 1000]`.
const plus_host = [_][2]i64{ .{ 400, 0 }, .{ 600, 0 }, .{ 600, 400 }, .{ 1000, 400 }, .{ 1000, 600 }, .{ 600, 600 }, .{ 600, 1000 }, .{ 400, 1000 }, .{ 400, 600 }, .{ 0, 600 }, .{ 0, 400 }, .{ 400, 400 } };

/// The L via: `[0, 200] x [0, 100]` with `[0, 100] x [100, 200]`.
const l_via = [_][2]i64{ .{ 0, 0 }, .{ 200, 0 }, .{ 200, 100 }, .{ 100, 100 }, .{ 100, 200 }, .{ 0, 200 } };

/// The limit swept one step either side, each with its label.
const sides = [3][]const u8{ "below", "at", "above" };

/// No finding.
const none = common.opt(false, F.any());

// ---- private ----

fn ln(v: i64) Opt {
    return common.opt(true, F.length(v));
}

fn layoutOf(boxes: []const Box) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    for (boxes) |b| try l.rect(b[0], b[1][0], b[1][1], b[1][2], b[1][3]);
    return l;
}

/// `checkEverywhere` of `text` over `l`, `ids[i]` claiming `claims[i]`;
/// `name` and `side` label it.
fn expect(name: []const u8, side: []const u8, text: []const u8, l: *const Layout, ids: []const []const u8, claims: []const Opt) !void {
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const rows = try al.alloc(Claim, ids.len);
    for (rows, ids, claims) |*r, id, *o| r.* = .{ .id = id, .findings = common.slice(o) };
    try common.checkEverywhere(try std.fmt.allocPrint(al, "{s}/{s}", .{ name, side }), text, l, rows);
}

fn deckOf(arena: *Arena, layers: []const []const u8, body: []const u8) ![]const u8 {
    return common.newDeck(arena.allocator(), layers, body);
}

test "opposite enclosure reads each edge straight out" {
    // Oracle: every margin drawn, so each straight-out reading is a number the
    // layout was built to have: the limit on one axis with the other touching;
    // one side short with the other axis far; both axes short; a host with
    // notches down to the via on two sides; the plus host (straight strips
    // 450); an L via swept; an L via with the limit only along x (clean); an L
    // via whose concave top edge decides the y axis while a notch 50 right of
    // its upper arm spoils x only while it reaches below y = 200; an unhosted
    // via (0).
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "via", "met1" }, "rule m1.5 enclosure(via, met1, opposite) >= 100nm\n");
    const ids = [_][]const u8{"m1.5"};
    for (common.steps(100), sides) |m, side| {
        const margins = [_]struct { []const u8, [4]i64 }{
            .{ "x_axis", .{ m, m, 0, 0 } },
            .{ "y_axis", .{ 0, 0, m, m } },
            .{ "one_side_short", .{ m, 400, 0, 400 } },
            .{ "both_axes_short", .{ m, 400, 400, 99 } },
        };
        for (margins) |cs| {
            const g = cs[1];
            var l = try layoutOf(&.{ .{ "via", .{ 0, 0, 100, 100 } }, .{ "met1", .{ -g[0], -g[2], 100 + g[1], 100 + g[3] } } });
            defer l.deinit();
            try expect(cs[0], side, d, &l, &ids, &.{common.below(@max(@min(g[0], g[1]), @min(g[2], g[3])), 100)});
        }
        {
            var l = try layoutOf(&.{.{ "via", .{ 0, 0, 100, 100 } }});
            defer l.deinit();
            try l.polygon("met1", &.{ .{ -400, -400 }, .{ 500, -400 }, .{ 500, 0 }, .{ 100 + m, 0 }, .{ 100 + m, 100 }, .{ 500, 100 }, .{ 500, 500 }, .{ 100, 500 }, .{ 100, 100 + m }, .{ 0, 100 + m }, .{ 0, 500 }, .{ -400, 500 } });
            try expect("notched_host", side, d, &l, &ids, &.{common.below(m, 100)});
        }
        {
            var l = try layoutOf(&.{.{ "met1", .{ -m, -m, 200 + m, 200 + m } }});
            defer l.deinit();
            try l.polygon("via", &l_via);
            try expect("l_via", side, d, &l, &ids, &.{common.below(m, 100)});
        }
    }
    {
        var l = try layoutOf(&.{ .{ "via", .{ 0, 0, 100, 100 } }, .{ "met1", .{ 0, 0, 100, 100 } } });
        defer l.deinit();
        try expect("every_side_zero", "", d, &l, &ids, &.{ln(0)});
    }
    {
        var l = try layoutOf(&.{.{ "via", .{ 450, 450, 550, 550 } }});
        defer l.deinit();
        try l.polygon("met1", &plus_host);
        try expect("plus_host", "", d, &l, &ids, &.{none});
    }
    {
        var l = try layoutOf(&.{.{ "met1", .{ -100, 0, 300, 200 } }});
        defer l.deinit();
        try l.polygon("via", &l_via);
        try expect("l_via_one_axis", "", d, &l, &ids, &.{none});
    }
    for (common.steps(100), sides) |k, side| {
        var l: Layout = .{};
        defer l.deinit();
        try l.polygon("via", &l_via);
        try l.polygon("met1", &.{ .{ -100, -100 }, .{ 300, -100 }, .{ 300, 300 }, .{ 250, 300 }, .{ 250, 100 + k }, .{ 150, 100 + k }, .{ 150, 300 }, .{ -100, 300 } });
        const x: i64 = if (100 + k < 200) 50 else 100;
        try expect("l_via_concave_edge", side, d, &l, &ids, &.{common.below(@max(x, @min(k, 100)), 100)});
    }
    {
        var l = try layoutOf(&.{ .{ "via", .{ 0, 0, 100, 100 } }, .{ "met1", .{ 50, -400, 600, 500 } } });
        defer l.deinit();
        try expect("unhosted", "", d, &l, &ids, &.{ln(0)});
    }
}

test "enclosure by wire width holds each via to its band" {
    // Oracle: wires drawn to a width, margins 15 left and 30 below: `narrow`
    // reads `max(min(15, far), min(30, far)) = 30`, the others 15. Widths 999,
    // 1000, 1001, 1999, 2000, 2001 (inclusive below, exclusive above); a via on
    // a 500 tab off a 3000 plate (the tab's width: `narrow`, 20); a via 40 into
    // the plate's corner (`wide`, 40); an unhosted via (`narrow`, 0).
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "via", "met2" }, "rule narrow enclosure(via, met2, opposite; below: 1000nm) >= 50nm\n" ++
        "rule mid enclosure(via, met2; width: 1000nm, below: 2000nm) >= 20nm\n" ++
        "rule wide enclosure(via, met2; width: 2000nm) >= 50nm\n");
    const ids = [_][]const u8{ "narrow", "mid", "wide" };
    for ([_]i64{ 999, 1000, 1001, 1999, 2000, 2001 }) |w| {
        var l = try layoutOf(&.{ .{ "via", .{ 0, 0, 200, 200 } }, .{ "met2", .{ -15, -30, 3000, w - 30 } } });
        defer l.deinit();
        const rows: [3]Opt = if (w < 1000) .{ ln(30), none, none } else if (w < 2000) .{ none, ln(15), none } else .{ none, none, ln(15) };
        try expect("wire", try std.fmt.allocPrint(arena.allocator(), "{d}", .{w}), d, &l, &ids, &rows);
    }
    const cases = [_]struct { []const u8, []const Box, [3]Opt }{
        .{ "tab", &.{ .{ "met2", .{ 0, 0, 3000, 3000 } }, .{ "met2", .{ 3000, 1000, 3800, 1500 } }, .{ "via", .{ 3580, 1150, 3780, 1490 } } }, .{ ln(20), none, none } },
        .{ "plate", &.{ .{ "met2", .{ 0, 0, 3000, 3000 } }, .{ "via", .{ 40, 40, 240, 240 } } }, .{ none, none, ln(40) } },
        .{ "unhosted", &.{ .{ "via", .{ 0, 0, 200, 200 } }, .{ "met2", .{ 5000, 5000, 6000, 6000 } } }, .{ ln(0), none, none } },
    };
    for (cases) |cs| {
        var l = try layoutOf(cs[1]);
        defer l.deinit();
        try expect(cs[0], "", d, &l, &ids, &cs[2]);
    }
}

test "noncoincident enclosure exempts touching edges" {
    // Oracle: drawn margins, the touching pairs drawn to coincide; lvtn is
    // `[0, 1000]²`: concentric at 379/380/381 (both alike); the left edge on
    // the nwell's, the other margins swept; the corner on two edges; the left
    // edge on the nwell's for its lower half only, the nwell stepping 400 out
    // above it (exempt, then 400); lvtn in an L nwell's concave corner,
    // touching it only there (exempt; 600 elsewhere); an unhosted lvtn (0).
    // The finding sits in the middle of the gap of the pair that measured it:
    // with the left side 100 off and the rest 600, at `(-50, 500)`.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "lvtn", "nwell" }, "rule lvtn.10 enclosure(lvtn, nwell, noncoincident) >= 380nm\n" ++
        "rule plain enclosure(lvtn, nwell) >= 380nm\n");
    const ids = [_][]const u8{ "lvtn.10", "plain" };
    const lvtn: Box = .{ "lvtn", .{ 0, 0, 1000, 1000 } };
    for (common.steps(380), sides) |m, side| {
        const cases = [_]struct { []const u8, [4]i64, Opt }{
            .{ "concentric", .{ -m, -m, 1000 + m, 1000 + m }, common.below(m, 380) },
            .{ "left_on_edge", .{ 0, -m, 1000 + m, 1000 + m }, ln(0) },
            .{ "corner_on_edges", .{ 0, 0, 1000 + m, 1000 + m }, ln(0) },
        };
        for (cases) |cs| {
            var l = try layoutOf(&.{ lvtn, .{ "nwell", cs[1] } });
            defer l.deinit();
            try expect(cs[0], side, d, &l, &ids, &.{ common.below(m, 380), cs[2] });
        }
    }
    {
        var l = try layoutOf(&.{lvtn});
        defer l.deinit();
        try l.polygon("nwell", &.{ .{ 0, -400 }, .{ 1400, -400 }, .{ 1400, 1400 }, .{ -400, 1400 }, .{ -400, 500 }, .{ 0, 500 } });
        try expect("partly_on_edge", "", d, &l, &ids, &.{ none, ln(0) });
    }
    {
        var l = try layoutOf(&.{.{ "lvtn", .{ 600, 600, 1000, 1000 } }});
        defer l.deinit();
        try l.polygon("nwell", &l_host);
        try expect("kissing_corner", "", d, &l, &ids, &.{ none, ln(0) });
    }
    {
        var l = try layoutOf(&.{ lvtn, .{ "nwell", .{ 2000, 2000, 3000, 3000 } } });
        defer l.deinit();
        try expect("unhosted", "", d, &l, &ids, &.{ ln(0), ln(0) });
    }
    // One short side, the rest far: the finding is in that gap's middle.
    var l = try layoutOf(&.{ lvtn, .{ "nwell", .{ -100, -600, 1600, 1600 } } });
    defer l.deinit();
    var r = try common.run(d, &l);
    defer r.deinit();
    const found = r.row("lvtn.10").findings;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expect(found[0].measured.eql(.length(100)) and found[0].limit.eql(.length(380)));
    try testing.expectEqual([2]i64{ -50, 500 }, found[0].at);
}

test "adjacent enclosure reads a side from just inside its end" {
    // Oracle: readings by construction. The via is `[0, 100]²`; the host is
    // `[-50, 200] x [0, 200]` over `[-10, 200] x [-20, 0]`, its left side
    // stepping in from 50 to 10 exactly at the via's bottom. At (0, 0) the
    // left edge reads 50 (the step's lower edge ends at y = 0 and covers none
    // of the side) and the bottom edge 20: better 50. The other corners' better
    // edges read 100. So `>= 51nm` finds 50 and `>= 50nm` nothing.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "via", "met1" }, "rule a51 enclosure(via, met1, adjacent) >= 51nm\n" ++
        "rule a50 enclosure(via, met1, adjacent) >= 50nm\n");
    var l = try layoutOf(&.{ .{ "via", .{ 0, 0, 100, 100 } }, .{ "met1", .{ -50, 0, 200, 200 } }, .{ "met1", .{ -10, -20, 200, 0 } } });
    defer l.deinit();
    try expect("step_at_the_corner", "", d, &l, &.{ "a51", "a50" }, &.{ ln(50), none });
}

test "full width wants the via as wide as its wire" {
    // Oracle: drawn gaps, a 100 nm via: spanning a 100 wide horizontal wire
    // (clean); 0 or 1 short of its top edge; 10 short of both; in a vertical
    // wire (clean); on a 300 pad (100 every side); on an equal pad (clean); off
    // the wire (not measured).
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "v1", "m2" }, "rule V1.M2.AUX.2 full_width(v1, m2)\n");
    const ids = [_][]const u8{"V1.M2.AUX.2"};
    const wire: Box = .{ "m2", .{ -500, 0, 1000, 100 } };
    const cases = [_]struct { []const u8, []const Box, Opt }{
        .{ "top_short/0", &.{ wire, .{ "v1", .{ 0, 0, 100, 100 } } }, none },
        .{ "top_short/1", &.{ wire, .{ "v1", .{ 0, 0, 100, 99 } } }, ln(1) },
        .{ "narrower", &.{ wire, .{ "v1", .{ 0, 10, 100, 90 } } }, ln(10) },
        .{ "vertical_wire", &.{ .{ "m2", .{ 0, -200, 100, 1000 } }, .{ "v1", .{ 0, 0, 100, 100 } } }, none },
        .{ "pad", &.{ .{ "m2", .{ -100, -100, 200, 200 } }, .{ "v1", .{ 0, 0, 100, 100 } } }, ln(100) },
        .{ "equal_pad", &.{ .{ "m2", .{ 0, 0, 100, 100 } }, .{ "v1", .{ 0, 0, 100, 100 } } }, none },
        .{ "off_wire", &.{ wire, .{ "v1", .{ 3000, 0, 3100, 100 } } }, none },
    };
    for (cases) |cs| {
        var l = try layoutOf(cs[1]);
        defer l.deinit();
        try expect(cs[0], "", d, &l, &ids, &.{cs[2]});
    }
}

test "projection space measures only facing edges" {
    // Oracle: drawn gaps, lvtn `[0, 500]²`: sd beside it at 234/235/236; sd
    // diagonally (100, 100) off its corner (clean, Euclid floor(100√2) = 141);
    // sd overlapping lvtn's side by 1 of projection, 100 away; sd whose
    // projection meets lvtn's at a point, 50 away (clean, Euclid 50); sd
    // touching and overlapping (0 for both).
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "lvtn", "sd" }, "rule lvtn.3b space(lvtn, sd, projection) >= 235nm\n" ++
        "rule euclid space(lvtn, sd) >= 235nm\n");
    const ids = [_][]const u8{ "lvtn.3b", "euclid" };
    const Case = struct { []const u8, []const u8, [4]i64, Opt, Opt };
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(gpa);
    for (common.steps(235), sides) |g, side| try cases.append(gpa, .{ "beside", side, .{ 500 + g, 100, 900 + g, 400 }, common.below(g, 235), common.below(g, 235) });
    try cases.appendSlice(gpa, &.{
        .{ "diagonal", "", .{ 600, 600, 900, 900 }, none, ln(141) },
        .{ "one_unit_of_projection", "", .{ 600, 499, 900, 900 }, ln(100), ln(100) },
        .{ "projection_meets_at_a_point", "", .{ 550, 500, 900, 900 }, none, ln(50) },
        .{ "touching", "", .{ 500, 100, 900, 400 }, ln(0), ln(0) },
        .{ "overlapping", "", .{ 400, 100, 900, 400 }, ln(0), ln(0) },
    });
    for (cases.items) |cs| {
        var l = try layoutOf(&.{ .{ "lvtn", .{ 0, 0, 500, 500 } }, .{ "sd", cs[2] } });
        defer l.deinit();
        try expect(cs[0], cs[1], d, &l, &ids, &.{ cs[3], cs[4] });
    }
}

test "max enclosure measures the furthest reach" {
    // Oracle: the reach is drawn. A licon `[0, 100]²` in npc 50 past it on
    // three sides and `m` on the fourth reaches `max(50, m)`, swept 94/95/96;
    // a corner square to (195, 195) and (196, 196) reaches its Chebyshev 95
    // and 96 though every straight strip reads 50; two licons 190, 191, 192
    // apart under one npc reach 95, 95.5 (up to 96) and 96 midway; an npc
    // holding no licon and one only straddled by a licon are not measured.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "licon", "npc" }, "rule npc.5 enclosure(licon, npc) <= 95nm\n");
    const ids = [_][]const u8{"npc.5"};
    const licon: Box = .{ "licon", .{ 0, 0, 100, 100 } };
    const above = struct {
        fn f(reach: i64) Opt {
            return common.opt(reach > 95, F.length(reach));
        }
    }.f;
    for (common.steps(95), sides) |m, side| {
        var l = try layoutOf(&.{ licon, .{ "npc", .{ -50, -50, 100 + m, 150 } } });
        defer l.deinit();
        try expect("side", side, d, &l, &ids, &.{above(m)});
    }
    for ([_]i64{ 195, 196 }) |c| {
        var l = try layoutOf(&.{ licon, .{ "npc", .{ -50, -50, 150, 150 } }, .{ "npc", .{ 100, 100, c, c } } });
        defer l.deinit();
        try expect("corner", if (c == 195) "195" else "196", d, &l, &ids, &.{above(c - 100)});
    }
    for ([_][2]i64{ .{ 190, 95 }, .{ 191, 96 }, .{ 192, 96 } }) |cs| {
        const g = cs[0];
        var l = try layoutOf(&.{ licon, .{ "licon", .{ 100 + g, 0, 200 + g, 100 } }, .{ "npc", .{ -50, -50, 250 + g, 150 } } });
        defer l.deinit();
        try expect("two_licons", "", d, &l, &ids, &.{above(cs[1])});
    }
    {
        var l = try layoutOf(&.{ licon, .{ "npc", .{ -50, -50, 150, 150 } }, .{ "npc", .{ 1000, 1000, 2000, 2000 } } });
        defer l.deinit();
        try expect("holding_nothing", "", d, &l, &ids, &.{none});
    }
    {
        var l = try layoutOf(&.{ licon, .{ "npc", .{ 50, -500, 1000, 500 } } });
        defer l.deinit();
        try expect("straddled", "", d, &l, &ids, &.{none});
    }
}

test "extension measures the shortest run past the diffusion" {
    // Oracle: drawn runs, diffusion `[0, 1000] x [0, 400]`: a gate with both
    // ends at the swept length; one end swept with the other far; a poly
    // covering the diffusion; a U poly whose far arm makes its box reach past
    // every side while the gate end is swept; a gate over a step in the
    // diffusion's edge (the step's edge faces sideways); a gate ending inside
    // (0); a poly abutting without crossing, also with a short far end (no
    // gate: clean); a split diffusion crossed with 200 to spare.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "diff", "poly" }, "rule poly.8 extension(poly, diff) >= 100nm\n");
    const ids = [_][]const u8{"poly.8"};
    const diff: Box = .{ "diff", .{ 0, 0, 1000, 400 } };
    const gate = struct {
        fn f(name: []const u8, side: []const u8, text: []const u8, bottom: i64, top: i64) !void {
            var l = try layoutOf(&.{ .{ "diff", .{ 0, 0, 1000, 400 } }, .{ "poly", .{ 400, -bottom, 500, 400 + top } } });
            defer l.deinit();
            try expect(name, side, text, &l, &.{"poly.8"}, &.{common.below(@max(@min(bottom, top), 0), 100)});
        }
    }.f;
    for (common.steps(100), sides) |m, side| {
        try gate("crossing", side, d, m, m);
        try gate("one_end", side, d, 500, m);
        {
            var l = try layoutOf(&.{ diff, .{ "poly", .{ -m, -m, 1000 + m, 400 + m } } });
            defer l.deinit();
            try expect("covering", side, d, &l, &ids, &.{common.below(m, 100)});
        }
        {
            var l = try layoutOf(&.{diff});
            defer l.deinit();
            try l.polygon("poly", &.{ .{ 400, -200 }, .{ 1300, -200 }, .{ 1300, 1000 }, .{ 1200, 1000 }, .{ 1200, -100 }, .{ 500, -100 }, .{ 500, 400 + m }, .{ 400, 400 + m } });
            try expect("u_shape", side, d, &l, &ids, &.{common.below(m, 100)});
        }
        {
            var l = try layoutOf(&.{ .{ "diff", .{ 0, 0, 450, 400 } }, .{ "diff", .{ 450, 0, 1000, 300 } }, .{ "poly", .{ 400, -m, 500, 600 } } });
            defer l.deinit();
            try expect("diffusion_jog", side, d, &l, &ids, &.{common.below(m, 100)});
        }
    }
    try gate("ends_inside", "", d, 500, -100);
    const clean = [_]struct { []const u8, []const Box }{
        .{ "abutting", &.{ diff, .{ "poly", .{ 400, 400, 500, 900 } } } },
        .{ "abutting_short", &.{ diff, .{ "poly", .{ 400, 400, 500, 450 } } } },
        .{ "split_diffusion", &.{ .{ "diff", .{ 0, 0, 450, 400 } }, .{ "diff", .{ 450, 0, 1000, 400 } }, .{ "poly", .{ 400, -200, 500, 600 } } } },
    };
    for (clean) |cs| {
        var l = try layoutOf(cs[1]);
        defer l.deinit();
        try expect(cs[0], "", d, &l, &ids, &.{none});
    }
    const ends = [_]i64{ -100, 0, 99, 100, 101, 500 };
    for (ends) |bottom| for (ends) |top| try gate("ends", "", d, bottom, top);
}

test "gate corner finds bends and covered inner corners" {
    // Oracle: every corner drawn where it is; a concave corner of an
    // intersection of rectilinear shapes is a concave corner of one of them.
    // Diffusion `[0, 1000]²` unless said: a straight gate (clean); an L poly
    // bent inside (a bend at (500, 500)), above it (clean), with its bend on
    // the diffusion's top edge (clean); a gate with a stub inside (two bends);
    // a gate over a jog in the diffusion's edge (an inner corner at (450,
    // 300)); a poly square over an L diffusion's inner corner (500, 500).
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try deckOf(&arena, &.{ "diff", "poly" }, "rule poly.11 bend(poly, diff)\nrule poly.10 covers_corner(poly, diff)\n");
    const diff: Box = .{ "diff", .{ 0, 0, 1000, 1000 } };
    const Case = struct { []const u8, []const Box, ?i64, []const F, []const F };
    const corner = struct {
        fn f(x: i64, y: i64) F {
            return F.count(1).atPoint(x, y);
        }
    }.f;
    const cases = [_]Case{
        .{ "straight", &.{ diff, .{ "poly", .{ 400, -200, 500, 1200 } } }, null, &.{}, &.{} },
        .{ "bent_inside", &.{diff}, 500, &.{corner(500, 500)}, &.{} },
        .{ "bent_outside", &.{diff}, 1100, &.{}, &.{} },
        .{ "bent_on_edge", &.{diff}, 1000, &.{}, &.{} },
        .{ "stub", &.{ diff, .{ "poly", .{ 400, -200, 500, 1200 } }, .{ "poly", .{ 500, 400, 700, 500 } } }, null, &.{ corner(500, 400), corner(500, 500) }, &.{} },
        .{ "diffusion_jog", &.{ .{ "diff", .{ 0, 0, 450, 400 } }, .{ "diff", .{ 450, 0, 1000, 300 } }, .{ "poly", .{ 400, -200, 500, 600 } } }, null, &.{}, &.{corner(450, 300)} },
        .{ "inner_corner_covered", &.{ .{ "diff", .{ 0, 0, 1000, 500 } }, .{ "diff", .{ 0, 500, 500, 1000 } }, .{ "poly", .{ 300, 300, 700, 700 } } }, null, &.{}, &.{corner(500, 500)} },
        .{ "empty_poly", &.{diff}, null, &.{}, &.{} },
    };
    for (cases) |cs| {
        var l = try layoutOf(cs[1]);
        defer l.deinit();
        // An L poly bent at height `y`.
        if (cs[2]) |y| try l.polygon("poly", &.{ .{ 400, -200 }, .{ 500, -200 }, .{ 500, y }, .{ 1200, y }, .{ 1200, y + 100 }, .{ 400, y + 100 } });
        try common.checkEverywhere(cs[0], d, &l, &.{ .{ .id = "poly.11", .findings = cs[3] }, .{ .id = "poly.10", .findings = cs[4] } });
    }
}
