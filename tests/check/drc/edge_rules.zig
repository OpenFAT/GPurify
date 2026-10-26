//! Edge-layer kinds: `edge_min_length`, `edge_spacing`, `edge_width`,
//! `edge_facing_space` and `edge_enclosure`, over segments written by hand
//! with their shape on the left. Each case states every finding and the
//! rule's `examined`. Ported from crates/check/tests/drc/edge_rules.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const gpa = common.gpa;
const RULE = common.rule_id;
const Rule = check.drc.Rule;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;

const E: LayerId = @fromBackingInt(0);
const F: LayerId = @fromBackingInt(1);
const outer_layer: LayerId = @fromBackingInt(2);

/// One finding: its measured length and marker.
const Found = struct { m: i64, x: i64, y: i64 };

/// Every finding, sorted, and the rule's row.
const Result = struct {
    found: std.ArrayList(Found) = .empty,
    row: check.report.RuleRun = undefined,

    fn deinit(r: *Result) void {
        r.found.deinit(gpa);
    }
};

// ---- private ----

fn seg(ax: i64, ay: i64, bx: i64, by: i64) Seg {
    return .{ .a = .{ .x = ax, .y = ay }, .b = .{ .x = bx, .y = by } };
}

/// A store with edge layers E and F and rectangles on the outer layer.
fn makeStore(e: []const Seg, f: []const Seg, outer: []const [4]i64) !GeometryStore {
    var lb = testgen.shapes.LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    for (outer) |r| _ = try lb.rect(gpa, 2, r[0], r[1], r[2], r[3]);
    var store: GeometryStore = .empty;
    errdefer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    try store.appendEdges(gpa, E, e);
    try store.appendEdges(gpa, F, f);
    return store;
}

fn runOne(e: []const Seg, f: []const Seg, outer: []const [4]i64, rule: Rule) !Result {
    var store = try makeStore(e, f, outer);
    defer store.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &store, &common.single(rule));
    var r: Result = .{ .row = sink.runs.items[0] };
    errdefer r.deinit();
    for (0..sink.out.len()) |k| {
        const v = sink.out.get(@intCast(k));
        try testing.expectEqual(check.report.Kind.length, v.measured.kind);
        try r.found.append(gpa, .{ .m = @intCast(v.measured.exact()), .x = v.at.x, .y = v.at.y });
    }
    std.mem.sortUnstable(Found, r.found.items, {}, lessFound);
    return r;
}

fn lessFound(_: void, a: Found, b: Found) bool {
    return std.mem.order(i64, &.{ a.m, a.x, a.y }, &.{ b.m, b.x, b.y }) == .lt;
}

/// The segments under `k` quarter turns `(x, y) -> (-y, x)`.
fn turned(out: []Seg, segs: []const Seg, k: u2) []Seg {
    for (out[0..segs.len], segs) |*o, s| {
        o.* = .{ .a = turnPoint(s.a, k), .b = turnPoint(s.b, k) };
    }
    return out[0..segs.len];
}

fn turnPoint(p: geom.Point, k: u2) geom.Point {
    var x = p.x;
    var y = p.y;
    for (0..k) |_| {
        const t = x;
        x = -y;
        y = t;
    }
    return .{ .x = x, .y = y };
}

fn values(r: *const Result, buf: []i64) []i64 {
    for (r.found.items, 0..) |f, i| buf[i] = f.m;
    std.mem.sortUnstable(i64, buf[0..r.found.items.len], {}, std.sort.asc(i64));
    return buf[0..r.found.items.len];
}

/// The edge_spacing cases at limit 100 (see the test's oracle).
const spacing_edges = [_]Seg{
    seg(0, 0, 200, 0),         seg(200, 99, 0, 99),
    seg(1000, 0, 1200, 0),     seg(1200, 100, 1000, 100),
    seg(2000, 0, 2100, 0),     seg(2150, 0, 2250, 0),
    seg(3000, 0, 3100, 0),     seg(3160, 80, 3260, 80),
    seg(4000, 0, 4100, 0),     seg(4160, 79, 4260, 79),
    seg(5000, 0, 5100, 0),     seg(5150, 10, 5150, 110),
    seg(6000, 0, 6100, 0),     seg(6100, 0, 6200, 0),
    seg(500, 7050, 600, 7050), seg(0, 7000, 1000, 7000),
};
const spacing_found = [_]Found{ .{ .m = 50, .x = 550, .y = 7025 }, .{ .m = 50, .x = 2125, .y = 0 }, .{ .m = 99, .x = 100, .y = 49 }, .{ .m = 99, .x = 4130, .y = 39 } };

/// The two sides of a rectangle `w` wide from x = `x0`, 1000 high, as a
/// counter-clockwise ring runs them: left down, right up.
fn sides(x0: i64, w: i64) [2]Seg {
    return .{ seg(x0, 1000, x0, 0), seg(x0 + w, 0, x0 + w, 1000) };
}

test "edge min length reports each edge under the limit at its midpoint" {
    // Oracle: the definition, lengths by construction. A 40 and a 39 edge
    // are under 41, at their midpoints floored ((261 + 300) / 2 = 280); a 41
    // edge is legal; examined counts every edge. A diagonal is refused.
    const rule: Rule = .{ .edge_min_length = .{ .layer = E, .limit = 41 } };
    var r = try runOne(&.{ seg(0, 0, 40, 0), seg(100, 0, 100, 41), seg(300, 10, 261, 10), seg(500, 141, 500, 100) }, &.{}, &.{}, rule);
    defer r.deinit();
    try testing.expectEqualSlices(Found, &.{ .{ .m = 39, .x = 280, .y = 10 }, .{ .m = 40, .x = 20, .y = 0 } }, r.found.items);
    try testing.expectEqual(check.report.Outcome.ran, r.row.outcome);
    try testing.expectEqual(@as(u64, 4), r.row.examined);
    try testing.expectEqual(@as(u32, 2), r.row.violations);
    var d = try runOne(&.{seg(0, 0, 30, 30)}, &.{}, &.{}, rule);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.found.items.len);
    try testing.expectEqual(check.report.Outcome.refused, d.row.outcome);
}

test "edge spacing measures parallel pairs end to end and across" {
    // Oracle: the definition (`edge_spacing`), every distance by
    // construction: parallel edges 99 apart (99 at (100, 49)); exactly 100
    // apart (legal, out of reach); collinear 50 apart end to end (50 at
    // (2125, 0)); 60 along and 80 across (100, legal, measured); 60 along
    // and 79 across (99.2 read 99 at (4130, 39)); a perpendicular edge (not
    // measured); touching collinear edges (no spacing); a long edge and a
    // short one 50 above its middle (50 at (550, 7025)). Six pairs examined.
    var r = try runOne(&spacing_edges, &.{}, &.{}, .{ .edge_spacing = .{ .a = E, .b = null, .limit = 100 } });
    defer r.deinit();
    try testing.expectEqualSlices(Found, &spacing_found, r.found.items);
    try testing.expectEqual(@as(u64, 6), r.row.examined);
}

test "edge spacing is the same under every quarter turn" {
    // Oracle: rotation invariance of a Euclidean spacing: under each quarter
    // turn the measured values and pairs examined are the same.
    var buf: [spacing_edges.len]Seg = undefined;
    for (1..4) |k| {
        var r = try runOne(turned(&buf, &spacing_edges, @intCast(k)), &.{}, &.{}, .{ .edge_spacing = .{ .a = E, .b = null, .limit = 100 } });
        defer r.deinit();
        var got: [8]i64 = undefined;
        try testing.expectEqualSlices(i64, &.{ 50, 50, 99, 99 }, values(&r, &got));
        try testing.expectEqual(@as(u64, 6), r.row.examined);
    }
}

test "edge spacing between two layers pairs only across" {
    // Oracle: the definition with a second layer: E pairs only with F; the
    // two E edges 10 apart are no finding; F's first is 99 above E's first
    // (at (100, 49)) and 89 above its second (at (100, 54)); the other 60
    // past the third's end (at (1030, 0)). Three pairs examined.
    var r = try runOne(&.{ seg(0, 0, 200, 0), seg(200, 10, 0, 10), seg(800, 0, 1000, 0) }, &.{ seg(0, 99, 200, 99), seg(1060, 0, 1100, 0) }, &.{}, .{ .edge_spacing = .{ .a = E, .b = F, .limit = 100 } });
    defer r.deinit();
    try testing.expectEqualSlices(Found, &.{ .{ .m = 60, .x = 1030, .y = 0 }, .{ .m = 89, .x = 100, .y = 54 }, .{ .m = 99, .x = 100, .y = 49 } }, r.found.items);
    try testing.expectEqual(@as(u64, 3), r.row.examined);
}

test "edge width and facing space tell the sides apart" {
    // Oracle: the definition (`edge_width` back to back, `edge_facing_space`
    // face to face), by construction: a 149 wide rectangle's sides are a
    // width finding at (74, 500); 150 wide is legal; two 200 wide
    // rectangles 100 apart face to face, a spacing finding of 100 at (2450,
    // 500); both rules examine the 149 and the 100 pair; a quarter turn
    // gives the same values.
    const edges = sides(0, 149) ++ sides(1000, 150) ++ sides(2200, 200) ++ sides(2500, 200);
    var buf: [edges.len]Seg = undefined;
    for (0..4) |k| {
        const t = turned(&buf, &edges, @intCast(k));
        var w = try runOne(t, &.{}, &.{}, .{ .edge_width = .{ .layer = E, .limit = 150 } });
        defer w.deinit();
        var s = try runOne(t, &.{}, &.{}, .{ .edge_facing_space = .{ .layer = E, .limit = 150, .prl = 0 } });
        defer s.deinit();
        var vb: [4]i64 = undefined;
        try testing.expectEqualSlices(i64, &.{149}, values(&w, &vb));
        try testing.expectEqualSlices(i64, &.{100}, values(&s, &vb));
        try testing.expectEqual(@as(u64, 2), w.row.examined);
        try testing.expectEqual(@as(u64, 2), s.row.examined);
        if (k == 0) {
            try testing.expectEqualSlices(Found, &.{.{ .m = 149, .x = 74, .y = 500 }}, w.found.items);
            try testing.expectEqualSlices(Found, &.{.{ .m = 100, .x = 2450, .y = 500 }}, s.found.items);
        }
    }
}

test "edge facing space judges only runs longer than prl" {
    // Oracle: the definition of prl: facing edges 40 apart overlapping by 50
    // are exempt at prl 50 (not examined) and judged at 51; at prl 0 a pair
    // meeting only at a point is examined but has no gap straight across.
    for ([_]struct { i64, bool }{ .{ 50, false }, .{ 51, true } }) |cs| {
        const overlap = cs[0];
        var r = try runOne(&.{ seg(0, 0, 0, 1000), seg(40, 2000 - overlap, 40, 1000 - overlap) }, &.{}, &.{}, .{ .edge_facing_space = .{ .layer = E, .limit = 100, .prl = 50 } });
        defer r.deinit();
        const mid = @divTrunc(2000 - overlap, 2);
        const want = [_]Found{.{ .m = 40, .x = 20, .y = mid }};
        try testing.expectEqualSlices(Found, want[0..@intFromBool(cs[1])], r.found.items);
        try testing.expectEqual(@as(u64, @intFromBool(cs[1])), r.row.examined);
    }
    var r = try runOne(&.{ seg(0, 0, 0, 1000), seg(40, 2000, 40, 1000) }, &.{}, &.{}, .{ .edge_facing_space = .{ .layer = E, .limit = 100, .prl = 0 } });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.found.items.len);
    try testing.expectEqual(@as(u64, 1), r.row.examined);
}

test "edge enclosure measures how deep each side is covered" {
    // Oracle: the definition, depths by construction: a 1000 square's sides
    // inside an outer rectangle 200 out left, 124 below, 125 right, 60
    // above, at limit 125: the bottom (124) and top (60) are reported at
    // their midpoints, the right (exactly 125) and left (200) are legal;
    // the margins turn around the square. Four edges examined.
    const square = [_]Seg{ seg(0, 0, 1000, 0), seg(1000, 0, 1000, 1000), seg(1000, 1000, 0, 1000), seg(0, 1000, 0, 0) };
    const margins = [4]i64{ 124, 125, 60, 200 };
    const ats = [4][2]i64{ .{ 500, 0 }, .{ 1000, 500 }, .{ 500, 1000 }, .{ 0, 500 } };
    for (0..4) |k| {
        const m = struct {
            fn f(ms: [4]i64, kk: usize, side: usize) i64 {
                return ms[(side + 4 - kk) % 4];
            }
        }.f;
        const outer = [4]i64{ -m(margins, k, 3), -m(margins, k, 0), 1000 + m(margins, k, 1), 1000 + m(margins, k, 2) };
        var r = try runOne(&square, &.{}, &.{outer}, .{ .edge_enclosure = .{ .edges = E, .outer = outer_layer, .limit = 125 } });
        defer r.deinit();
        var want: std.ArrayList(Found) = .empty;
        defer want.deinit(gpa);
        for (0..4) |side| if (m(margins, k, side) < 125) try want.append(gpa, .{ .m = m(margins, k, side), .x = ats[side][0], .y = ats[side][1] });
        std.mem.sortUnstable(Found, want.items, {}, lessFound);
        try testing.expectEqualSlices(Found, want.items, r.found.items);
        try testing.expectEqual(@as(u64, 4), r.row.examined);
    }
}

test "edge enclosure stops at the first gap across the whole edge" {
    // Oracle: the definition, covered without a gap: a band 0 to 30 deep and
    // another 50 to 200 deep cover to 30; full depth under x 0..400 and
    // 600..1000 but 60 under 400..600 cover to 60; full depth under half the
    // edge covers to 0.
    const cases = [_]struct { []const [4]i64, i64 }{
        .{ &.{ .{ -10, -30, 1010, 0 }, .{ -10, -200, 1010, -50 } }, 30 },
        .{ &.{ .{ -10, -200, 400, 0 }, .{ 600, -200, 1010, 0 }, .{ 400, -60, 600, 0 } }, 60 },
        .{ &.{.{ -10, -200, 500, 0 }}, 0 },
    };
    for (cases) |cs| {
        var r = try runOne(&.{seg(0, 0, 1000, 0)}, &.{}, cs[0], .{ .edge_enclosure = .{ .edges = E, .outer = outer_layer, .limit = 125 } });
        defer r.deinit();
        try testing.expectEqualSlices(Found, &.{.{ .m = cs[1], .x = 500, .y = 0 }}, r.found.items);
    }
}
