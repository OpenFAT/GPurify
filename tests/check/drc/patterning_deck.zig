//! `patterning` (plain and anchored) and `pattern` from deck text, under
//! the eight symmetries of the square. The cases are the root suite's
//! exhaustive fixtures (`tests/exhaustive/drc_overlay.rs`) at the crate
//! level, with the same oracles. Ported from
//! crates/check/tests/drc/patterning_deck.rs.

const std = @import("std");
const testing = std.testing;
const common = @import("common.zig");
const gpa = common.gpa;
const Layout = common.Layout;
const Finding = common.Finding;

const mp_rules = "rule mp1 patterning(met1; colors: 1) >= 100nm\n" ++
    "rule mp2 patterning(met1; colors: 2) >= 100nm\n" ++
    "rule mp3 patterning(met1; colors: 3) >= 100nm\n";

const ap_rules = "rule odd patterning(met1; colors: 2) >= 100nm\n" ++
    "rule ap patterning(met1, c1, c2; colors: 2) >= 100nm\n" ++
    "rule ap3 patterning(met1, c1, c2, c3; colors: 3) >= 100nm\n";

/// A claim `(rule, finding)`, as `common.byRule` takes it.
const Want = struct { []const u8, Finding };

// ---- private ----

/// A cycle of `n >= 4` bars around a 4000 square frame, each `gap` from the
/// next and far from every other: the bottom side split into `(n - 1) / 2`
/// bars, the top into the rest, and one bar up each side.
fn barCycle(n: i64, gap: i64) !Layout {
    const s = 4000;
    const t = 100;
    const bottom = @divTrunc(n - 1, 2);
    const top = n - 2 - bottom;
    var out: Layout = .{};
    errdefer out.deinit();
    try out.rect("met1", s - t, t + gap, s, s);
    try out.rect("met1", 0, t + gap, t, s - t - gap);
    try pieces(&out, s, bottom, gap, 0, t);
    try pieces(&out, s - t - gap, top, gap, s - t, s);
    return out;
}

/// `[0, to]` split into `k` bars `gap` apart, spanning `[ylo, yhi]`.
fn pieces(out: *Layout, to: i64, k: i64, gap: i64, ylo: i64, yhi: i64) !void {
    const len = @divTrunc(to - (k - 1) * gap, k);
    var i: i64 = 0;
    while (i < k) : (i += 1) {
        const lo = i * (len + gap);
        try out.rect("met1", lo, ylo, if (i == k - 1) to else lo + len, yhi);
    }
}

/// `chromatic` masks needed: each row of k masks finds one count of k + 1
/// when more are needed. Consumes `layout`.
fn needs(name: []const u8, layout: Layout, chromatic: u32) !void {
    var l = layout;
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    var want: std.ArrayList(Want) = .empty;
    for ([_]struct { []const u8, u32 }{ .{ "mp1", 1 }, .{ "mp2", 2 }, .{ "mp3", 3 } }) |r| {
        if (chromatic > r[1]) try want.append(al, .{ r[0], .count(r[1] + 1) });
    }
    const text = try common.newDeck(al, &.{ "met1", "other" }, mp_rules);
    try common.checkEverywhere(name, text, &l, try common.byRule(al, &.{ "mp1", "mp2", "mp3" }, want.items));
}

/// `n` bars 100 x 500, 150 apart in x (a 50 gap, a conflict), in a chain.
fn chain(n: i64) !Layout {
    var out: Layout = .{};
    errdefer out.deinit();
    var i: i64 = 0;
    while (i < n) : (i += 1) try out.rect("met1", 150 * i, 0, 150 * i + 100, 500);
    return out;
}

/// The triangle of the anchored cases: two squares 50 apart under a bar.
fn triangle() !Layout {
    return common.met1(&.{ .{ 0, 0, 500, 500 }, .{ 550, 0, 1050, 500 }, .{ 0, 550, 1050, 1050 } });
}

/// Checks the anchored deck's rows on `layout` plus the `anchors`
/// rectangles `(layer, box)`. Consumes `layout`.
fn anchored(name: []const u8, layout: Layout, anchors: []const struct { []const u8, [4]i64 }, want: []const Want) !void {
    var l = layout;
    defer l.deinit();
    for (anchors) |a| try l.rect(a[0], a[1][0], a[1][1], a[1][2], a[1][3]);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const text = try common.newDeck(al, &.{ "met1", "c1", "c2", "c3" }, ap_rules);
    try common.checkEverywhere(name, text, &l, try common.byRule(al, &.{ "odd", "ap", "ap3" }, want));
}

/// An L on layer `m` whose horizontal arm is `arm` tall and both arms `run`
/// long, from x = `x`, into `out`.
fn ell(out: *Layout, x: i64, arm: i64, run: i64) !void {
    try out.rect("m", x, 0, x + run, arm);
    try out.rect("m", x, arm, x + 100, run);
}

/// Checks the pattern deck on `layout`: `p` findings of rule `p` and `pd`
/// of rule `pd`, each measuring the pattern's area. Consumes `layout`.
fn patternCase(name: []const u8, layout: Layout, p: usize, pd: usize) !void {
    var l = layout;
    defer l.deinit();
    const shapes = "shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm, 100nm x 300nm]";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const text = try common.newDeck(al, &.{"m"}, "rule p pattern(m; window: 300nm x 300nm, " ++ shapes ++ ", ignore: none)\n" ++
        "rule pd pattern(m; window: 300nm x 300nm, " ++ shapes ++ ", ignore: [150nm x 150nm, 300nm x 300nm])\n");
    var want: std.ArrayList(Want) = .empty;
    for (0..p) |_| try want.append(al, .{ "p", .area(50_000) });
    for (0..pd) |_| try want.append(al, .{ "pd", .area(50_000) });
    try common.checkEverywhere(name, text, &l, try common.byRule(al, &.{ "p", "pd" }, want.items));
}

fn label(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
}

test "multi patterning counts masks either side of the colour spacing" {
    // Oracle: each layout's chromatic number by construction, figures closer
    // than 100 conflicting, swept one unit either side of the limit: a
    // triangle of mutual gaps 99/100/101 needs 3 masks, or 1 when no gap
    // conflicts; a pair 2 or 1; a U whose arms are 99/100/101 apart, and a
    // ring whose slot hole is, conflict with themselves below 100 (Calibre's
    // self-conflict: no palette colours them) and need 1 at 100 and above.
    var buf: [64]u8 = undefined;
    for ([_]i64{ 99, 100, 101 }) |g| {
        const conflicts = g < 100;
        try needs(label(&buf, "triangle/{d}", .{g}), try common.met1(&.{ .{ 0, 0, 500, 500 }, .{ 500 + g, 0, 1000 + g, 500 }, .{ 0, 500 + g, 1000 + g, 1000 + g } }), if (conflicts) 3 else 1);
        const notched: u32 = if (conflicts) std.math.maxInt(u32) else 1;
        var u: Layout = .{};
        try u.polygon("met1", &.{ .{ 0, 0 }, .{ 1000 + g, 0 }, .{ 1000 + g, 2000 }, .{ 500 + g, 2000 }, .{ 500 + g, 500 }, .{ 500, 500 }, .{ 500, 2000 }, .{ 0, 2000 } });
        try needs(label(&buf, "u_notch/{d}", .{g}), u, notched);
        var slot: Layout = .{};
        try common.ring(&slot, "met1", .{ 0, 0, 2000, 2000 }, .{ 900, 500, 900 + g, 1500 });
        try needs(label(&buf, "slot_hole/{d}", .{g}), slot, notched);
        try needs(label(&buf, "pair/{d}", .{g}), try common.met1(&.{ .{ 0, 0, 500, 500 }, .{ 500 + g, 0, 1000 + g, 500 } }), if (conflicts) 2 else 1);
    }
}

test "multi patterning counts masks of known graphs" {
    // Oracle: chromatic numbers by construction: cycles of 4 to 7 bars need 2
    // masks when even and 3 when odd; a 2 x 2 block at 50 whose diagonals are
    // 70.7 apart is K4 (4); a triangle whose two lower shapes abut is two
    // figures (2); two squares touching only at a corner are one figure (1);
    // one shape (1); an island 50 inside a ring's hole is a real gap (2); a
    // shape drawn inside another 50 from its boundary is one figure (1), and
    // that pair beside a third 50 away needs 2. An empty layer is skipped.
    var buf: [64]u8 = undefined;
    var n: i64 = 4;
    while (n <= 7) : (n += 1) try needs(label(&buf, "cycle/{d}", .{n}), try barCycle(n, 50), if (@mod(n, 2) == 0) 2 else 3);
    try needs("k4", try common.met1(&.{ .{ 0, 0, 500, 500 }, .{ 550, 0, 1050, 500 }, .{ 0, 550, 500, 1050 }, .{ 550, 550, 1050, 1050 } }), 4);
    try needs("merged_triangle", try common.met1(&.{ .{ 0, 0, 500, 500 }, .{ 500, 0, 1000, 500 }, .{ 0, 550, 1000, 1050 } }), 2);
    try needs("single", try common.met1(&.{.{ 0, 0, 500, 500 }}), 1);
    var island: Layout = .{};
    try common.ring(&island, "met1", .{ 0, 0, 2000, 2000 }, .{ 500, 500, 1500, 1500 });
    try island.rect("met1", 550, 550, 1450, 1450);
    try needs("island_in_hole", island, 2);
    const inside = [_][4]i64{ .{ 0, 0, 2000, 2000 }, .{ 50, 50, 1950, 1950 } };
    try needs("drawn_inside", try common.met1(&inside), 1);
    try needs("corner_touch", try common.met1(&.{ .{ 0, 0, 500, 500 }, .{ 500, 500, 1000, 1000 } }), 1);
    try needs("drawn_inside_beside_one", try common.met1(&(inside ++ [_][4]i64{.{ 2050, 0, 2550, 2000 }})), 2);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var other = try common.layoutOf("other", &.{.{ 0, 0, 100, 100 }});
    defer other.deinit();
    var r = try common.run(try common.newDeck(arena.allocator(), &.{ "met1", "other" }, mp_rules), &other);
    defer r.deinit();
    for (r.rows) |row| {
        try testing.expectEqual(@as(usize, 0), row.findings.len);
        try testing.expect(row.outcome == .skipped);
    }
}

test "anchored patterning finds anchor paths by parity" {
    // Oracle: US8473873B2's FIG. 1, 5 and 6 and the parity of a chain: four
    // bars (three conflicts, odd) anchored alike at both ends is an anchor
    // path, one finding of 3 masks against 2 at the middle of the gap between
    // the lowest anchored bar and the first of the wrong parity, (275, 250);
    // anchored apart it is honoured. Five bars (four conflicts, even) alike
    // are honoured, apart a path at (350, 250). Four unanchored bars,
    // nothing. Any overlap anchors (a 50 square on the end bar); an anchor
    // that only touches its bar does not.
    try anchored("chain4/alike", try chain(4), &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c1", .{ 450, 0, 550, 500 } } }, &.{.{ "ap", Finding.count(3).atPoint(275, 250) }});
    try anchored("chain4/apart", try chain(4), &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c2", .{ 450, 0, 550, 500 } } }, &.{});
    try anchored("chain5/alike", try chain(5), &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c1", .{ 600, 0, 700, 500 } } }, &.{});
    try anchored("chain5/apart", try chain(5), &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c2", .{ 600, 0, 700, 500 } } }, &.{.{ "ap", Finding.count(3).atPoint(350, 250) }});
    try anchored("chain4/unanchored", try chain(4), &.{}, &.{});
    try anchored("chain4/partial_anchor", try chain(4), &.{ .{ "c1", .{ 0, 0, 50, 50 } }, .{ "c1", .{ 450, 0, 550, 500 } } }, &.{.{ "ap", Finding.count(3).atPoint(275, 250) }});
    try anchored("chain4/touching_anchor", try chain(4), &.{ .{ "c1", .{ -100, 0, 0, 500 } }, .{ "c1", .{ 450, 0, 550, 500 } } }, &.{});
}

test "anchored patterning self conflicts and three masks" {
    // Oracle: the same definition. One bar under both anchor layers
    // conflicts with its own anchors: 3 masks against 2 and 4 against 3, at
    // its centre (50, 250). A triangle has no 2-mask split (the plain row's
    // 3); with two corners anchored to mask 1 the 3-mask row finds the
    // lowest anchored figure's conflict, 4 against 3 at (250, 250); one
    // anchor per mask is honoured. An empty layer is skipped.
    try anchored("self_conflict", try chain(1), &.{ .{ "c1", .{ 0, 0, 100, 500 } }, .{ "c2", .{ 0, 0, 100, 500 } } }, &.{ .{ "ap", Finding.count(3).atPoint(50, 250) }, .{ "ap3", Finding.count(4).atPoint(50, 250) } });
    try anchored("odd_cycle", try triangle(), &.{.{ "c1", .{ 0, 0, 500, 500 } }}, &.{.{ "odd", Finding.count(3) }});
    try anchored("triangle/alike", try triangle(), &.{ .{ "c1", .{ 0, 0, 500, 500 } }, .{ "c1", .{ 550, 0, 1050, 500 } } }, &.{ .{ "odd", Finding.count(3) }, .{ "ap3", Finding.count(4).atPoint(250, 250) } });
    try anchored("triangle/each", try triangle(), &.{ .{ "c1", .{ 0, 0, 500, 500 } }, .{ "c2", .{ 550, 0, 1050, 500 } }, .{ "c3", .{ 0, 550, 1050, 1050 } } }, &.{.{ "odd", Finding.count(3) }});

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var only_anchor = try common.layoutOf("c1", &.{.{ 0, 0, 100, 100 }});
    defer only_anchor.deinit();
    var r = try common.run(try common.newDeck(arena.allocator(), &.{ "met1", "c1", "c2", "c3" }, ap_rules), &only_anchor);
    defer r.deinit();
    for (r.rows) |row| {
        try testing.expectEqual(@as(usize, 0), row.findings.len);
        if (!std.mem.eql(u8, row.id, "odd")) try testing.expect(row.outcome == .skipped);
    }
}

test "pattern matches the shapes exactly outside the dont care boxes" {
    // Oracle: the pattern's definition, by construction. The pattern is an L
    // of two 100-wide arms in a 300 window (area 300 * 100 + 100 * 200 =
    // 50000), with and without a don't-care box over the window's upper
    // right quarter. An L with its arm 99, 100 or 101 tall matches only at
    // 100; arms 600 long still match inside the window (one placement); a
    // small square in the don't-care quarter matches only the row with the
    // don't-care box; one by the L's corner, outside it, matches neither;
    // two Ls are two; a solid square matches nothing. Each finding measures
    // the pattern's area.
    var buf: [64]u8 = undefined;
    for ([_]i64{ 99, 100, 101 }) |arm| {
        var l: Layout = .{};
        try ell(&l, 0, arm, 300);
        const n: usize = @intFromBool(arm == 100);
        try patternCase(label(&buf, "arm/{d}", .{arm}), l, n, n);
    }
    var long: Layout = .{};
    try ell(&long, 0, 100, 600);
    try patternCase("long_arms", long, 1, 1);
    var dont_care: Layout = .{};
    try ell(&dont_care, 0, 100, 300);
    try dont_care.rect("m", 200, 200, 250, 250);
    try patternCase("square_in_the_dont_care", dont_care, 0, 1);
    var corner: Layout = .{};
    try ell(&corner, 0, 100, 300);
    try corner.rect("m", 120, 120, 140, 140);
    try patternCase("square_by_the_corner", corner, 0, 0);
    var two: Layout = .{};
    try ell(&two, 0, 100, 300);
    try ell(&two, 2000, 100, 300);
    try patternCase("two", two, 2, 2);
    try patternCase("solid", try common.layoutOf("m", &.{.{ 0, 0, 300, 300 }}), 0, 0);
}
