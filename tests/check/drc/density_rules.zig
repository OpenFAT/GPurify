//! Area-family kinds read from deck text: `aspect_ratio`, `region_density`,
//! `cover_density`, `density_balance`, `critical_area` and its weighted
//! mean. Ported from crates/check/tests/drc/density_rules.rs.

const std = @import("std");
const common = @import("common.zig");
const F = common.Finding;
const Layout = common.Layout;
const Claim = common.Claim;
const gpa = common.gpa;
const Arena = std.heap.ArenaAllocator;

/// `region_density(met3, cap)` against 25% (maximum) and 10% (minimum).
const region_rules = "rule dmax region_density(met3, cap) <= 25%\nrule dmin region_density(met3, cap) >= 10%";

const Pair = struct { []const u8, F };

// ---- private ----

/// Windows anchor on the die's corner: translations only.
fn identity(s: common.Symmetry) bool {
    return s.turns == 0 and !s.mirror;
}

fn ratioOf(n: i64, d: f64) f64 {
    return @as(f64, @floatFromInt(n)) / d;
}

fn layoutOf(shapes: []const struct { []const u8, [4]i64 }) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    for (shapes) |s| try l.rect(s[0], s[1][0], s[1][1], s[1][2], s[1][3]);
    return l;
}

/// Lines 1000 long and 100 tall at each `y`.
fn lines(ys: []const i64) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    for (ys) |y| try l.rect("met1", 0, y, 1000, y + 100);
    return l;
}

fn expect(name: []const u8, text: []const u8, layout: Layout, ids: []const []const u8, claims: []const Pair, comptime keep: fn (common.Symmetry) bool) !void {
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    var l = layout;
    defer l.deinit();
    try common.checkUnder(name, text, &l, try byRule(arena.allocator(), ids, claims), keep);
}

fn every(_: common.Symmetry) bool {
    return true;
}

fn byRule(arena: std.mem.Allocator, ids: []const []const u8, claims: []const Pair) ![]const Claim {
    const out = try arena.alloc(Claim, ids.len);
    for (out, ids) |*o, id| {
        var fs: std.ArrayList(F) = .empty;
        for (claims) |c| if (std.mem.eql(u8, c[0], id)) try fs.append(arena, c[1]);
        o.* = .{ .id = id, .findings = fs.items };
    }
    return out;
}

test "aspect ratio holds the long side over the short one to the limit" {
    // Oracle: ratios fixed by construction, the limit swept one grid step
    // either side (a 100 wide bar 299, 300 and 301 long under 3; 249, 250
    // and 251 under 2.5): at the limit is legal, above it is one finding of
    // long / short at the bar's centre.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    for ([_]struct { i64, []const u8, [3]i64 }{ .{ 300, "3", .{ 299, 300, 301 } }, .{ 250, "2.5", .{ 249, 250, 251 } } }) |cs| {
        const d = try common.deck(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "rule ar aspect_ratio(met1) <= {s}", .{cs[1]}));
        for (cs[2]) |l| {
            const want = [_]Pair{.{ "ar", F.ratio(ratioOf(l, 100.0)).atHalf(100, l) }};
            try expect("bar", d, try layoutOf(&.{.{ "met1", .{ 0, 0, 100, l } }}), &.{"ar"}, want[0..@intFromBool(l > cs[0])], every);
        }
    }
}

test "aspect ratio judges merged figures by their box" {
    // Oracle: the merged figure's bounding box, by construction. A 301 bar
    // drawn as two halves is one figure at 3.01; an L of two 400 x 100 arms
    // has a square box (1, legal); a 1000 x 200 ring drawn as four
    // rectangles is 5; an empty layer is legal.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.deck(arena.allocator(), "rule ar aspect_ratio(met1) <= 3");
    try expect("halves", d, try layoutOf(&.{ .{ "met1", .{ 0, 0, 100, 150 } }, .{ "met1", .{ 0, 150, 100, 301 } } }), &.{"ar"}, &.{.{ "ar", F.ratio(3.01) }}, every);
    try expect("l_of_two_long_arms", d, try layoutOf(&.{ .{ "met1", .{ 0, 0, 400, 100 } }, .{ "met1", .{ 0, 100, 100, 400 } } }), &.{"ar"}, &.{}, every);
    try expect("ring", d, try layoutOf(&.{ .{ "met1", .{ 0, 0, 1000, 50 } }, .{ "met1", .{ 0, 150, 1000, 200 } }, .{ "met1", .{ 0, 50, 100, 150 } }, .{ "met1", .{ 900, 50, 1000, 150 } } }), &.{"ar"}, &.{.{ "ar", F.ratio(5.0) }}, every);
    try expect("empty", d, try layoutOf(&.{.{ "met2", .{ 0, 0, 1000, 100 } }}), &.{"ar"}, &.{}, every);
}

test "region density is the layer's share of each region figure" {
    // Oracle: coverages fixed by construction. Rows 249, 250 and 251 tall in
    // a 1000 square capacitor are 24.9%, 25% and 25.1%: only the last breaks
    // the maximum, at the capacitor's centre (500, 500).
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "met3", "cap" }, region_rules);
    for ([_]i64{ 249, 250, 251 }) |h| {
        const want = [_]Pair{.{ "dmax", F.ratio(ratioOf(h, 1000.0)).atPoint(500, 500) }};
        try expect("coverage", d, try layoutOf(&.{ .{ "cap", .{ 0, 0, 1000, 1000 } }, .{ "met3", .{ 0, 0, 1000, h } } }), &.{ "dmax", "dmin" }, want[0..@intFromBool(h > 250)], every);
    }
}

test "region density counts only inside each region figure" {
    // Oracle: coverages fixed by construction: two capacitors at 30% and 5%
    // are a finding each at their own centres; met3 reaching outside its
    // capacitor counts only inside (25%, legal); met3 filling only the hole
    // of a ring-shaped capacitor is 0 of the ring; met3 with no capacitor is
    // no finding.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "met3", "cap" }, region_rules);
    const ids = [_][]const u8{ "dmax", "dmin" };
    try expect("two_regions", d, try layoutOf(&.{ .{ "cap", .{ 0, 0, 1000, 1000 } }, .{ "met3", .{ 0, 0, 1000, 300 } }, .{ "cap", .{ 3000, 0, 4000, 1000 } }, .{ "met3", .{ 3000, 0, 4000, 50 } } }), &ids, &.{ .{ "dmax", F.ratio(0.3).atPoint(500, 500) }, .{ "dmin", F.ratio(0.05).atPoint(3500, 500) } }, every);
    try expect("outside_not_counted", d, try layoutOf(&.{ .{ "cap", .{ 0, 0, 1000, 1000 } }, .{ "met3", .{ -500, 0, 1000, 250 } } }), &ids, &.{}, every);
    try expect("holed_region", d, try layoutOf(&.{ .{ "cap", .{ 0, 0, 1000, 250 } }, .{ "cap", .{ 0, 750, 1000, 1000 } }, .{ "cap", .{ 0, 250, 250, 750 } }, .{ "cap", .{ 750, 250, 1000, 750 } }, .{ "met3", .{ 250, 250, 750, 750 } } }), &ids, &.{.{ "dmin", F.ratio(0.0) }}, every);
    try expect("no_region", d, try layoutOf(&.{.{ "met3", .{ 0, 0, 1000, 1000 } }}), &ids, &.{}, every);
}

test "cover density holds each window to the band its cover picks" {
    // Oracle: coverage and density by hand, one 1000 window over a die
    // [0, 1000]², bands from cover 25%, 50%, 100% asking 25%, 50%, 75%. A
    // cover of exactly 50% is the 50% band inclusive (0.5) and the 25% band
    // exclusive (0.25); a full cover the 100% band inclusive (0.75) and the
    // 50% band exclusive (0.5); 49.9% and 50.1% fall either side alike; 20%
    // is below every band. The held area is swept a step either side of
    // each need, one finding below it, at (500, 500), measuring the density.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const cases = [_]struct { i64, ?i64, ?i64 }{ .{ 500_000, 500_000, 250_000 }, .{ 1_000_000, 750_000, 500_000 }, .{ 499_000, 250_000, 250_000 }, .{ 501_000, 500_000, 500_000 }, .{ 200_000, null, null } };
    for (cases) |cs| for ([2]bool{ true, false }) |inclusive| {
        const need = if (inclusive) cs[1] else cs[2];
        const d = try common.newDeck(al, &.{ "m", "c", "die" }, try std.fmt.allocPrint(al, "rule cd cover_density(m, c, die; window: 1000nm, step: 1000nm, cover: [25%, 50%, 100%], density: [25%, 50%, 75%], inclusive: {})", .{inclusive}));
        const helds: []const i64 = if (need) |n| &.{ n - 1000, n, n + 1000 } else &.{ 0, 100_000 };
        for (helds) |held| {
            var l = try layoutOf(&.{ .{ "die", .{ 0, 0, 1000, 1000 } }, .{ "c", .{ 0, 0, 1000, @divExact(cs[0], 1000) } } });
            if (held > 0) try l.rect("m", 0, 0, @divExact(held, 1000), 1000);
            const want = [_]Pair{.{ "cd", F.ratio(ratioOf(held, 1e6)).atPoint(500, 500) }};
            const hit = if (need) |n| held < n else false;
            try expect("cover_density", d, l, &.{"cd"}, want[0..@intFromBool(hit)], identity);
        }
    };
}

test "density balance is the lesser coverage over the greater per window" {
    // Oracle: the balance by hand. A 3000 x 1000 die, three 1000 windows.
    // The first holds 500 x 1000 of c1 and c2 1000 tall and 249, 250 or 251
    // wide (balance 0.498, 0.5, 0.502 against 0.5); the second only c1
    // (balance 0, a finding at (1500, 500)); the third neither.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "die", "c1", "c2" }, "rule bal density_balance(c1, c2, die; window: 1000nm, step: 1000nm) >= 0.5");
    for ([_]i64{ 249, 250, 251 }) |w| {
        const want = [_]Pair{ .{ "bal", F.ratio(0.0).atPoint(1500, 500) }, .{ "bal", F.ratio(ratioOf(w, 500.0)).atPoint(500, 500) } };
        try expect("density_balance", d, try layoutOf(&.{ .{ "die", .{ 0, 0, 3000, 1000 } }, .{ "c1", .{ 0, 0, 500, 1000 } }, .{ "c2", .{ 600, 0, 600 + w, 1000 } }, .{ "c1", .{ 1000, 0, 1400, 1000 } } }), &.{"bal"}, want[0 .. 1 + @as(usize, @intFromBool(w < 250))], identity);
    }
}

test "critical area is the closed form of parallel lines" {
    // Oracle: the closed form (Papadopoulou and Lee, 1999): two parallel
    // lines of length 1000 and a gap 200 under a square defect of half-side
    // 150 have (1000 + 300)(300 - 200) = 130000, against limits one square
    // unit either side and at it, at the region's centre (500, 200). Three
    // such lines under half-side 350 cover 1700 x 800 = 1360000, not their
    // sum, and the 150 defect sees 2 x 130000. Lines 400 apart are out of
    // reach of a 300 defect; one L-shaped figure has no pair.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.deck(arena.allocator(), "rule below critical_area(met1; radius: 150nm) <= 129999nm2\nrule at critical_area(met1; radius: 150nm) <= 130000nm2\nrule above critical_area(met1; radius: 150nm) <= 130001nm2\nrule wide critical_area(met1; radius: 350nm) <= 1um2");
    const ids = [_][]const u8{ "below", "at", "above", "wide" };
    try expect("two_lines", d, try lines(&.{ 0, 300 }), &ids, &.{.{ "below", F.area(130_000).atPoint(500, 200) }}, every);
    try expect("three_lines", d, try lines(&.{ 0, 300, 600 }), &ids, &.{ .{ "below", F.area(260_000).atPoint(500, 350) }, .{ "at", F.area(260_000).atPoint(500, 350) }, .{ "above", F.area(260_000).atPoint(500, 350) }, .{ "wide", F.area(1_360_000).atPoint(500, 350) } }, every);
    try expect("apart", d, try lines(&.{ 0, 500 }), &ids, &.{}, every);
    try expect("one_figure", d, try layoutOf(&.{ .{ "met1", .{ 0, 0, 1000, 100 } }, .{ "met1", .{ 0, 100, 100, 1000 } } }), &ids, &.{}, every);
}

test "mean critical area weights each radius" {
    // Oracle: the closed form per radius for two lines 1000 long, 200
    // apart, (1000 + 2r)(2r - 200) and 0 below r = 100: 0, 130000 and 450000
    // at radii 50, 150, 250; weighted 1/2, 1/4, 1/4 the mean is 145000,
    // found only against 144999, at (500, 200). Lines 600 apart are out of
    // reach of every radius.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.deck(arena.allocator(), "rule below critical_area(met1; radii: [50nm, 150nm, 250nm], weights: [0.5, 0.25, 0.25]) <= 144999nm2\nrule at critical_area(met1; radii: [50nm, 150nm, 250nm], weights: [0.5, 0.25, 0.25]) <= 145000nm2\nrule above critical_area(met1; radii: [50nm, 150nm, 250nm], weights: [0.5, 0.25, 0.25]) <= 145001nm2");
    const ids = [_][]const u8{ "below", "at", "above" };
    try expect("two_lines", d, try lines(&.{ 0, 300 }), &ids, &.{.{ "below", F.area(145_000).atPoint(500, 200) }}, every);
    try expect("out_of_reach", d, try lines(&.{ 0, 700 }), &ids, &.{}, every);
}
