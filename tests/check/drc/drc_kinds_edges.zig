//! Spacing tables read on one stretch, huge-metal spacing, edge checks and
//! nested figures, end to end. Ported from the root tests/drc_kinds.rs
//! (second half; the fixtures are drc_kinds.zig's).
//!
//! Oracle throughout: construct-from-answer on a 1 nm grid, the rules in the
//! foundry's own wording.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const kinds = @import("drc_kinds.zig");
const gpa = common.gpa;
const Measurement = check.report.Measurement;
const Rect = kinds.Rect;
const len = kinds.len;
const pairs = kinds.pairs;

/// A map of the plane.
const Symmetry = *const fn (i64, i64) [2]i64;

/// The eight symmetries of the square.
const symmetries = [8]Symmetry{
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

/// `M1.bef` on met1 `boxes` under symmetry `s`: the findings, all of
/// which must be `want` (and at least one), or none when `want` is null.
fn expectMovedM1(s: Symmetry, boxes: []const [4]i64, want: ?[2]Measurement) !void {
    var rects: [8]Rect = undefined;
    for (boxes, rects[0..boxes.len]) |b, *r| {
        const p = s(b[0], b[1]);
        const q = s(b[2], b[3]);
        r.* = .{ "met1", .{ @min(p[0], q[0]), @min(p[1], q[1]), @max(p[0], q[0]), @max(p[1], q[1]) } };
    }
    var r = try kinds.runRects(kinds.ihp_m1, rects[0..boxes.len]);
    defer r.deinit();
    const got = try pairs(&r, "M1.bef");
    if (want) |w| {
        try testing.expect(got.len > 0);
        for (got) |g| try testing.expectEqual(w, g);
    } else try testing.expectEqual(@as(usize, 0), got.len);
}

/// A 200 nm line 1.2 um long carrying a tab that makes it 330 nm wide for
/// `tab` nm, and a 200 nm line `gap` beside it.
fn tabbed(tab: i64, gap: i64) [3][4]i64 {
    return .{ .{ 0, 0, 200, 1_200 }, .{ -130, 0, 200, tab }, .{ 200 + gap, 0, 400 + gap, 1_200 } };
}

fn withSky130(arena: std.mem.Allocator, rules: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ kinds.sky130, rules, "\n" });
}

fn expectFindings(want: []const [2]Measurement, r: *common.Run, rule: []const u8) !void {
    try testing.expectEqualSlices([2]Measurement, want, try pairs(r, rule));
}

test "m1 e reads the run of the wide part not of the whole line" {
    // IHP M1.e "Min. space of Metal1 lines if, at least one line is wider
    // than 0.3 um and the parallel run is more than 1.0 um: 0.22" (SG13G2
    // layout rules 5.16). The run is the wide line's: a 200 nm line with a
    // 330 x 305 nm tab (`sg13g2_buf_2`'s Metal1) runs 1.2 um beside its
    // neighbour, but its wide part only 305 nm, so the 0.18 um of M1.b holds.
    // A tab 1001 nm long runs past 1 um and asks 0.22.
    // Oracle: foundry example, IHP M1.e on `sg13g2_buf_2` (clean under IHP's
    // deck, finding N-f2-6), the cells by hand; under all eight symmetries,
    // the gap swept one unit either side of each limit: a 305 nm tab flags
    // 179 and not 180 or 181, a 1001 nm tab flags 219 and not 220 or 221, and
    // a 1000 nm tab, whose run is not more than 1 um, does not flag 219.
    for (symmetries) |s| {
        try expectMovedM1(s, &tabbed(305, 179), .{ len(179), len(180) });
        for ([_]i64{ 180, 181 }) |gap| try expectMovedM1(s, &tabbed(305, gap), null);
        try expectMovedM1(s, &tabbed(1_001, 219), .{ len(219), len(220) });
        for ([_]i64{ 220, 221 }) |gap| try expectMovedM1(s, &tabbed(1_001, gap), null);
        try expectMovedM1(s, &tabbed(1_000, 219), null);
    }
}

test "m1 e reads the gap and the run on the same stretch" {
    // IHP M1.e reads the gap and the run on one stretch. The Metal1 of
    // `sg13g2_dlhr_1`: a VSS rail 440 nm tall with a 330 nm finger, and a net
    // 215 nm from the finger along 590 nm, and `low` nm above the rail along
    // 1085 nm. The 215 gap runs only 590 nm, so 0.18 holds there; the 1085 nm
    // stretch runs past 1 um, so 0.22 holds there, and 220 is clean.
    // Oracle: foundry example, IHP M1.e on `sg13g2_dlhr_1` (clean under IHP's
    // `5_16_metal1.drc`, which projects each edge pair), the stretches by
    // hand; under all eight symmetries, the long stretch's gap swept: 220 and
    // 221 clean, 219 flagged against 0.22.
    const net = struct {
        fn f(low: i64) [6][4]i64 {
            return .{ .{ 0, -220, 8_640, 220 }, .{ 910, 220, 1_240, 1_250 }, .{ 1_455, 660, 1_930, 1_250 }, .{ 1_930, 720, 3_275, 890 }, .{ 3_105, 220 + low, 4_190, 630 }, .{ 3_105, 630, 3_275, 720 } };
        }
    }.f;
    for (symmetries) |s| {
        for ([_]i64{ 220, 221 }) |low| try expectMovedM1(s, &net(low), null);
        try expectMovedM1(s, &net(219), .{ len(219), len(220) });
    }
}

test "m1 3a measures from what is attached to huge metal" {
    // sky130 m1.3a "Min. spacing of features attached to or extending from
    // `huge_met1` for a distance of up to 0.28 µm to metal1 0.28". A 4 µm
    // plate (huge: a 3 µm square fits) has a 140-wide finger going up. A line
    // 200 to the finger's side, starting 300 above the plate, is 300 from the
    // plate but only about 201 from the finger's first 280: m1.3a flags it,
    // and spacing measured from the plate alone does not.
    // Oracle: foundry example, sky130 m1.3a, by hand: the line is 200 beside
    // and 20 above the finger's first 280, sqrt(200^2 + 20^2) = 200.99,
    // floored to 200; it is 300 from the plate, so m1.3b is clean.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try kinds.runRects(try withSky130(arena.allocator(), "rule m1.3a wide_space(met1; width: 3um, attached: 280nm) >= 280nm\nrule m1.3b wide_space(met1; width: 3um) >= 280nm"), &.{
        .{ "met1", .{ 0, 0, 4_000, 4_000 } },         .{ "met1", .{ 1_000, 4_000, 1_140, 5_000 } },
        .{ "met1", .{ 1_340, 4_300, 1_480, 4_600 } }, .{ "met1", .{ 1_340, 4_700, 1_480, 5_000 } },
    });
    defer r.deinit();
    try expectFindings(&.{.{ len(200), len(280) }}, &r, "m1.3a");
    try expectFindings(&.{}, &r, "m1.3b");
}

test "difftap 4 and 5 measure the butting edges" {
    // sky130 difftap.4 "Min tap bound by one diffusion 0.29" and difftap.5
    // "Min tap bound by two diffusions 0.40". One tap butts one diff along
    // 250; another sits 350 wide between two diffs; a third is exactly 400
    // wide, which is legal.
    // Oracle: foundry example, sky130 difftap.4 (0.29) and difftap.5 (0.40),
    // by hand: one butting edge 250 long, one pair of butting edges 350
    // apart, and a 400 pair at the limit.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try kinds.runRects(try withSky130(arena.allocator(), "layer butt = tap.edges() and diff.edges()\nrule difftap.4 length(butt) >= 290nm\nrule difftap.5 space(butt) >= 400nm"), &.{
        .{ "diff", .{ 0, 0, 1_000, 500 } },           .{ "tap", .{ 1_000, 0, 1_500, 250 } },
        .{ "diff", .{ 0, 2_000, 1_000, 2_500 } },     .{ "tap", .{ 1_000, 2_000, 1_350, 2_500 } },
        .{ "diff", .{ 1_350, 2_000, 2_350, 2_500 } }, .{ "diff", .{ 0, 4_000, 1_000, 4_500 } },
        .{ "tap", .{ 1_000, 4_000, 1_400, 4_500 } },  .{ "diff", .{ 1_400, 4_000, 2_400, 4_500 } },
    });
    defer r.deinit();
    try expectFindings(&.{.{ len(250), len(290) }}, &r, "difftap.4");
    try expectFindings(&.{.{ len(350), len(400) }}, &r, "difftap.5");
}

test "difftap 7 measures edge to edge on the diagonal too" {
    // sky130 difftap.7 "Spacing of diff/tap abutting edge to a non-coinciding
    // diff or tap edge 0.13", the tap side. A tap 100 above a diff is flagged
    // twice: its bottom over the diff's top, and its left edge in line with
    // the diff's, end to end. So is a tap whose corner sits 60 right and 80
    // above the diff's corner, 100 on the diagonal.
    // Oracle: foundry example, sky130 difftap.7 (0.13), by hand: the first
    // tap is 100 above its diff, twice; the second's corner is 60 by 80 from
    // the diff's, 100 on the diagonal, twice; the locations are the midpoints
    // worked out from the coordinates.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try kinds.runRects(try withSky130(arena.allocator(), "rule difftap.7 space((tap.edges() not diff.edges()).not_interacting(diff), diff.edges()) >= 130nm"), &.{
        .{ "diff", .{ 0, 0, 1_000, 500 } },     .{ "tap", .{ 0, 600, 500, 900 } },
        .{ "diff", .{ 3_000, 0, 4_000, 500 } }, .{ "tap", .{ 4_060, 580, 4_400, 900 } },
    });
    defer r.deinit();
    const f = [2]Measurement{ len(100), len(130) };
    try expectFindings(&.{ f, f, f, f }, &r, "difftap.7");
    var at: [4][2]i64 = undefined;
    for (&at, r.row("difftap.7").findings) |*a, x| a.* = x.at;
    std.mem.sort([2]i64, &at, {}, struct {
        fn less(_: void, p: [2]i64, q: [2]i64) bool {
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    }.less);
    try testing.expectEqualSlices([2]i64, &.{ .{ 0, 550 }, .{ 250, 550 }, .{ 4_030, 540 }, .{ 4_030, 540 } }, &at);
}

test "nsd 5a is measured on every edge but the butting one" {
    // sky130 n/psd.5a "Enclosure of diff by nsdm(psdm), except for butting
    // edge 0.125". The diff's butting edge is taken out, so the nsdm may stop
    // at it. A second diff whose nsdm reaches only 100 below it is flagged at
    // 100.
    // Oracle: foundry example, sky130 n/psd.5a (0.125, except the butting
    // edge), by hand: the first diff is covered 125 everywhere it is
    // measured; the second's nsdm reaches 100 below it, at the bottom edge's
    // midpoint (500, 2000).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r = try kinds.runRects(try withSky130(arena.allocator(), "rule nsd.5a enclosure(diff.edges() not tap.edges(), nsdm) >= 125nm"), &.{
        .{ "diff", .{ 0, 0, 1_000, 500 } },          .{ "tap", .{ 1_000, 0, 1_300, 500 } },
        .{ "nsdm", .{ -125, -125, 1_000, 625 } },    .{ "diff", .{ 0, 2_000, 1_000, 2_500 } },
        .{ "nsdm", .{ -125, 1_900, 1_125, 2_625 } },
    });
    defer r.deinit();
    try expectFindings(&.{.{ len(100), len(125) }}, &r, "nsd.5a");
    try testing.expectEqual([2]i64{ 500, 2_000 }, r.row("nsd.5a").findings[0].at);
}

test "a shape nested in another is not a spacing gap" {
    // A pad dropped inside a wider shape of the same layer is one figure with
    // it: boundary distance alone reads the pad's inset as a 100 nm gap.
    // Oracle: construct-from-answer. The pad lies wholly inside the rail, so
    // the two merge into one figure and there is no gap to space.
    var r = try kinds.runRects("grid 1nm\nlayer m1 = gds(8, 0)\nrule M1.b space(m1) >= 180nm\n", &.{ .{ "m1", .{ 0, 0, 5900, 500 } }, .{ "m1", .{ 2800, 100, 3100, 400 } } });
    defer r.deinit();
    try expectFindings(&.{}, &r, "M1.b");
}

test "a holed polygon is spaced from its hole edge only" {
    // A derived guard ring is one polygon with a hole. Its ring width is not
    // a gap, and an island in the hole is spaced from the hole's edge only.
    // Oracle: construct-from-answer. The ring's 150 width is not a gap; an
    // island at the centre is 750 from the hole's edge, one at x 200 is 50
    // from it.
    const deck = "grid 1nm\nlayer m1 = gds(8, 0)\nlayer cut = gds(9, 0)\nlayer d = m1 not cut\nrule S space(d) >= 180nm\n";
    const ring = [4]Rect{ .{ "m1", .{ 0, 0, 2000, 150 } }, .{ "m1", .{ 0, 1850, 2000, 2000 } }, .{ "m1", .{ 0, 150, 150, 1850 } }, .{ "m1", .{ 1850, 150, 2000, 1850 } } };
    var bare = try kinds.runRects(deck, &ring);
    defer bare.deinit();
    try expectFindings(&.{}, &bare, "S");
    var centred = try kinds.runRects(deck, &(ring ++ [1]Rect{.{ "m1", .{ 900, 900, 1100, 1100 } }}));
    defer centred.deinit();
    try expectFindings(&.{}, &centred, "S");
    // Wrong implementation: joining everything inside the outer ring hides this.
    var near = try kinds.runRects(deck, &(ring ++ [1]Rect{.{ "m1", .{ 200, 900, 400, 1100 } }}));
    defer near.deinit();
    try expectFindings(&.{.{ len(50), len(180) }}, &near, "S");
}

test "a ring is enclosed by a ring drawn as bands" {
    // A derived guard ring is one polygon with a hole; its implant is drawn
    // as four abutting bands. The host is the merged implant, not any one
    // band, or no single band covers the ring and it reads as unhosted (0).
    // Oracle: construct-from-answer. The implant bands merge into one ring
    // reaching 125 past every edge of the tap ring, hole edges included; with
    // 100 past the hole edges it is one violation of 100.
    const deck = "grid 1nm\nlayer tap = gds(65, 44)\nlayer poly = gds(66, 20)\nlayer nsdm = gds(93, 44)\nlayer body = tap not poly\nrule E enclosure(body, nsdm) >= 125nm\n";
    const bands = struct {
        fn f(layer: []const u8, out: i64, inside: i64) [4]Rect {
            return .{
                .{ layer, .{ -out, -out, 5000 + out, 500 + inside } },
                .{ layer, .{ -out, 4500 - inside, 5000 + out, 5000 + out } },
                .{ layer, .{ -out, -out, 500 + inside, 5000 + out } },
                .{ layer, .{ 4500 - inside, -out, 5000 + out, 5000 + out } },
            };
        }
    }.f;
    var met = try kinds.runRects(deck, &(bands("tap", 0, 0) ++ bands("nsdm", 125, 125)));
    defer met.deinit();
    try expectFindings(&.{}, &met, "E");
    // Wrong implementation: one that skips the hole edges passes this.
    var short = try kinds.runRects(deck, &(bands("tap", 0, 0) ++ bands("nsdm", 125, 100)));
    defer short.deinit();
    try expectFindings(&.{.{ len(100), len(125) }}, &short, "E");
}

test "a narrow shape drawn inside a wide one is not a width violation" {
    // Width is the merged figure's: a 170 nm strip drawn inside a 1 um square
    // adds no width of its own, while the same strip alone is too narrow.
    // Oracle: construct-from-answer. The 170 strip inside the 1 um square adds
    // no width to the merged figure; alone it is 170 against 380.
    const deck = "grid 1nm\nlayer psdm = gds(94, 20)\nrule psd.1 width(psdm) >= 380nm\n";
    var nested = try kinds.runRects(deck, &.{ .{ "psdm", .{ 0, 0, 1_000, 1_000 } }, .{ "psdm", .{ 200, 0, 370, 1_000 } } });
    defer nested.deinit();
    try expectFindings(&.{}, &nested, "psd.1");
    var alone = try kinds.runRects(deck, &.{.{ "psdm", .{ 200, 0, 370, 1_000 } }});
    defer alone.deinit();
    try expectFindings(&.{.{ len(170), len(380) }}, &alone, "psd.1");
}
