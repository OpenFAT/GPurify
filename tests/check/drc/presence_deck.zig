//! `contains` (`must_contain`, DRC-048, DRC-049, DRC-085) from deck text on
//! rectilinear figures, under the eight symmetries of the square. The cases
//! are the root suite's exhaustive fixture (`tests/exhaustive/drc_overlay.rs`)
//! at the crate level, with the same oracle; each finding also states the
//! bound it broke. Ported from crates/check/tests/drc/presence_deck.rs.

const std = @import("std");
const common = @import("common.zig");
const F = common.Finding;
const Layout = common.Layout;
const Claim = common.Claim;
const gpa = common.gpa;
const Arena = std.heap.ArenaAllocator;

const tap_rules = "rule one contains(tap, licon) >= 1\nrule two contains(tap, licon) >= 2\n" ++
    "rule most contains(tap, licon) <= 1\nrule exact contains(tap, licon) == 2";

/// A rule's id, which held counts break it, and its bound.
const Bound = struct { id: []const u8, bad: *const fn (u32) bool, bound: u32 };

const bounds = [_]Bound{
    .{ .id = "one", .bad = struct {
        fn f(h: u32) bool {
            return h < 1;
        }
    }.f, .bound = 1 },
    .{ .id = "two", .bad = struct {
        fn f(h: u32) bool {
            return h < 2;
        }
    }.f, .bound = 2 },
    .{ .id = "most", .bad = struct {
        fn f(h: u32) bool {
            return h > 1;
        }
    }.f, .bound = 1 },
    .{ .id = "exact", .bad = struct {
        fn f(h: u32) bool {
            return h != 2;
        }
    }.f, .bound = 2 },
};

// ---- private ----

/// `held` is what each tap figure holds; each rule's findings follow from
/// the count and its bound.
fn case(name: []const u8, layout: *Layout, held: []const u32) !void {
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const claims = try al.alloc(Claim, bounds.len);
    for (claims, bounds) |*c, b| {
        var fs: std.ArrayList(F) = .empty;
        for (held) |h| if (b.bad(h)) try fs.append(al, F.count(h).limitOf(.count(b.bound)));
        c.* = .{ .id = b.id, .findings = fs.items };
    }
    try common.checkEverywhere(name, try common.newDeck(al, &.{ "tap", "licon" }, tap_rules), layout, claims);
}

fn licons(boxes: []const [4]i64) !Layout {
    var l = try common.layoutOf("tap", &.{.{ 0, 0, 1000, 500 }});
    errdefer l.deinit();
    try l.rects("licon", boxes);
    return l;
}

test "contains counts the figures each outer figure holds entirely" {
    // Oracle: each case states how many licons each tap holds, by
    // construction: none, one, two and three held; one touching the tap's
    // edge from inside (held); one straddling the edge and one touching it
    // from outside (not held); two touching or overlapping licons (one
    // figure); a tap of two abutting halves holding a licon across the seam;
    // two taps holding 1 and 0; a licon in a tap ring's hole (not held); an
    // empty tap layer (nothing judged).
    const cases = [_]struct { []const u8, []const [4]i64, u32 }{
        .{ "none", &.{}, 0 },
        .{ "one", &.{.{ 100, 100, 200, 200 }}, 1 },
        .{ "two", &.{ .{ 100, 100, 200, 200 }, .{ 400, 100, 500, 200 } }, 2 },
        .{ "three", &.{ .{ 100, 100, 200, 200 }, .{ 400, 100, 500, 200 }, .{ 700, 100, 800, 200 } }, 3 },
        .{ "edge_inside", &.{.{ 0, 0, 100, 100 }}, 1 },
        .{ "straddling", &.{.{ 950, 100, 1050, 200 }}, 0 },
        .{ "touching_outside", &.{.{ 1000, 100, 1100, 200 }}, 0 },
        .{ "touching_pair", &.{ .{ 100, 100, 200, 200 }, .{ 200, 100, 300, 200 } }, 1 },
        .{ "overlapping_pair", &.{ .{ 100, 100, 250, 200 }, .{ 200, 100, 300, 200 } }, 1 },
    };
    for (cases) |cs| {
        var l = try licons(cs[1]);
        defer l.deinit();
        try case(cs[0], &l, &.{cs[2]});
    }
    {
        var l = try common.layoutOf("tap", &.{ .{ 0, 0, 500, 500 }, .{ 500, 0, 1000, 500 } });
        defer l.deinit();
        try l.rect("licon", 450, 100, 550, 200);
        try case("tap_halves", &l, &.{1});
    }
    {
        var l = try licons(&.{.{ 100, 100, 200, 200 }});
        defer l.deinit();
        try l.rect("tap", 2000, 0, 3000, 500);
        try case("two_taps", &l, &.{ 1, 0 });
    }
    {
        var l = try common.layoutOf("licon", &.{.{ 100, 100, 200, 200 }});
        defer l.deinit();
        try case("empty_tap", &l, &.{});
    }
    {
        var l = try common.layoutOf("tap", &.{ .{ 0, 0, 1000, 100 }, .{ 0, 400, 1000, 500 }, .{ 0, 100, 300, 400 }, .{ 700, 100, 1000, 400 } });
        defer l.deinit();
        try l.rect("licon", 450, 200, 550, 300);
        try case("in_hole", &l, &.{0});
    }
}

test "a well must hold a whole tap" {
    // Oracle: the same definition for a well (sky130 nwell.4 "all n-wells
    // must contain a tap"): a well with a tap inside holds 1; one without,
    // or with its tap across the well's edge, holds 0 against 1.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "nwell", "ntap" }, "rule nwell.4 contains(nwell, ntap) >= 1");
    const zero = [_]F{F.count(0).limitOf(.count(1))};
    const cases = [_]struct { []const u8, ?[4]i64, []const F }{
        .{ "tapped", .{ 100, 100, 300, 300 }, &.{} },
        .{ "untapped", null, &zero },
        .{ "tap_across_edge", .{ 1900, 100, 2100, 300 }, &zero },
    };
    for (cases) |cs| {
        var l = try common.layoutOf("nwell", &.{.{ 0, 0, 2000, 1000 }});
        defer l.deinit();
        if (cs[1]) |t| try l.rect("ntap", t[0], t[1], t[2], t[3]);
        try common.checkEverywhere(cs[0], d, &l, &.{.{ .id = "nwell.4", .findings = cs[2] }});
    }
}
