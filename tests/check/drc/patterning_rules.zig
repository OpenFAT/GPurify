//! Multi-patterning: `colorInto` and the rule built on it. Complete,
//! Infeasible and Exhausted are three different claims and must stay
//! distinct. Ported from crates/check/tests/drc/patterning_rules.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const Sink = common.Sink;
const gpa = common.gpa;
const A = common.a;
const RULE = common.rule_id;
const Rule = check.drc.Rule;
const color = check.drc.patterning_color;
const Coloring = color.Coloring;
const Rng = testgen.Rng;
const LayoutBuilder = testgen.shapes.LayoutBuilder;

/// A graph that is `colours`-colourable by construction: every node is
/// dealt a colour and an edge drawn only between nodes of different colours,
/// a random seeded subset, so the dealt assignment is a proper colouring.
const Graph = struct {
    edges: std.ArrayList([2]u32) = .empty,

    fn deinit(g: *Graph) void {
        g.edges.deinit(gpa);
    }
};

// ---- private ----

fn colourableGraph(seed: u64, node_count: u32, colours: u8) !Graph {
    var rng = Rng.init(seed);
    var g: Graph = .{};
    errdefer g.deinit();
    for (0..node_count) |a| for (a + 1..node_count) |b| {
        if (a % colours != b % colours and rng.unit() < 0.2) try g.edges.append(gpa, .{ @intCast(a), @intCast(b) });
    };
    rng.shuffle([2]u32, g.edges.items);
    return g;
}

/// A colouring is proper and within its palette.
fn expectProper(colours: []const u8, edges: []const [2]u32, palette: u8) !void {
    for (colours) |c| try testing.expect(c < palette);
    for (edges) |e| try testing.expect(colours[e[0]] != colours[e[1]]);
}

fn colorOf(n: u32, edges: []const [2]u32, palette: u8, out: *std.ArrayList(u8)) !Coloring {
    return color.colorInto(gpa, n, edges, palette, out);
}

fn patterning(colors: u8, spacing: i64) Rule {
    return .{ .multi_patterning = .{ .layer = A, .colors = colors, .color_spacing = spacing } };
}

/// Three squares, pairwise in conflict at a colour spacing of 71: the two
/// axis-aligned pairs 50 apart, the diagonal pair √5000 apart (under 71,
/// over 70).
fn oddCycleCase() !testgen.violation.ViolationCase {
    return testgen.violation.layoutWithViolation(gpa, .{ .rule = RULE, .severity = .@"error", .kind = .{ .odd_cycle = .{ .layer = A, .size = 100, .gap = 50 } } }, .{ 0, 0 }, .{ .count = 3 }, .{ .count = 2 });
}

/// Whether some colouring of `0 .. n` with `k` colours is proper and, with
/// `honour`, gives every anchored node its anchor's colour: every one of
/// the `k^n` assignments tried.
fn bruteForce(n: u32, edges: []const [2]u32, anchors: []const u8, k: u8, honour: bool) bool {
    const k64: u64 = k;
    const total = std.math.pow(u64, k64, n);
    var code: u64 = 0;
    outer: while (code < total) : (code += 1) {
        for (edges) |e| if (colourAt(code, k64, e[0]) == colourAt(code, k64, e[1])) continue :outer;
        if (honour) for (0..n) |i| {
            if (anchors[i] != 0 and anchors[i] != @as(u8, 1) << @intCast(colourAt(code, k64, @intCast(i)))) continue :outer;
        };
        return true;
    }
    return false;
}

fn colourAt(code: u64, k: u64, i: u32) u64 {
    return code / std.math.pow(u64, k, i) % k;
}

test "a graph built from a colouring is coloured completely and properly" {
    // Oracle: construct-from-answer. The graph was built from a colouring,
    // so one exists and the search must return `complete` with a full
    // assignment that is proper and within the palette.
    for ([_]struct { u64, u32, u8 }{ .{ 1, 30, 3 }, .{ 2, 48, 2 }, .{ 3, 60, 4 } }) |c| {
        var g = try colourableGraph(c[0], c[1], c[2]);
        defer g.deinit();
        var colours: std.ArrayList(u8) = .empty;
        defer colours.deinit(gpa);
        try testing.expectEqual(Coloring.complete, try colorOf(c[1], g.edges.items, c[2], &colours));
        try testing.expectEqual(@as(usize, c[1]), colours.items.len);
        try expectProper(colours.items, g.edges.items, c[2]);
    }
}

test "an odd cycle is proved infeasible and leaves no partial colouring behind" {
    // Oracle: construct-from-answer. A triangle needs three masks and cannot
    // be split across two, whatever search order is used, so this is proved
    // uncolourable rather than merely unsolved, and the buffer is left
    // empty because a partial colouring is not a result anyone can use.
    const triangle = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    var colours: std.ArrayList(u8) = .empty;
    defer colours.deinit(gpa);
    try colours.appendSlice(gpa, &.{ 7, 7, 7 });
    const result = try colorOf(3, &triangle, 2, &colours);
    try testing.expect(result == .infeasible);
    try testing.expectEqual(@as(usize, 0), colours.items.len);
    try testing.expectEqual(Coloring.complete, try colorOf(3, &triangle, 3, &colours));
    try expectProper(colours.items, &triangle, 3);
}

test "a node conflicting with itself is infeasible under every palette" {
    // Oracle: law (F34). A node that conflicts with itself shares a mask
    // with itself under every colouring, so no palette colours it. Three
    // nodes, node 1 looped and joined to node 2: three, four and one colours
    // prove it infeasible at node 1, the lowest looped node, and two colours
    // at the root of its odd-cycle component, node 1; none leaves a
    // colouring behind.
    const looped = [_][2]u32{ .{ 1, 1 }, .{ 1, 2 } };
    for ([_]u8{ 3, 4, 2, 1 }) |palette| {
        var colours: std.ArrayList(u8) = .empty;
        defer colours.deinit(gpa);
        try colours.appendNTimes(gpa, 7, 3);
        try testing.expectEqual(Coloring{ .infeasible = 1 }, try colorOf(3, &looped, palette, &colours));
        try testing.expectEqual(@as(usize, 0), colours.items.len);
    }
}

test "an infeasible graph names the lowest node of its odd cycle component" {
    // Oracle: the documented node, hand-derived. `infeasible` names, for two
    // colours, the lowest root of an odd-cycle component. Here nodes 0 and 1
    // form a bipartite pair and nodes 2 to 6 a five-cycle, so the answer is
    // node 2. The edges are listed from the cycle's highest node and then
    // reversed: a search reporting wherever it stopped, or the first edge it
    // read, names 6 or another cycle node.
    var edges = [_][2]u32{ .{ 5, 6 }, .{ 4, 5 }, .{ 0, 1 }, .{ 3, 4 }, .{ 2, 3 }, .{ 6, 2 } };
    for (0..2) |_| {
        var colours: std.ArrayList(u8) = .empty;
        defer colours.deinit(gpa);
        try colours.appendNTimes(gpa, 7, 7);
        try testing.expectEqual(Coloring{ .infeasible = 2 }, try colorOf(7, &edges, 2, &colours));
        try testing.expectEqual(@as(usize, 0), colours.items.len);
        std.mem.reverse([2]u32, &edges);
    }
}

test "a graph with a four clique is never reported three colourable" {
    // Oracle: law. A graph containing a four-clique cannot be split across
    // three masks, so whatever the search does with the three hundred nodes
    // around it, the one answer it may never give is `complete`; the buffer
    // comes back empty in both other cases.
    var g = try colourableGraph(11, 300, 3);
    defer g.deinit();
    try g.edges.appendSlice(gpa, &.{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 }, .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 } });
    var rng = Rng.init(12);
    rng.shuffle([2]u32, g.edges.items);
    var colours: std.ArrayList(u8) = .empty;
    defer colours.deinit(gpa);
    try colours.appendNTimes(gpa, 9, 300);
    try testing.expect(try colorOf(300, g.edges.items, 3, &colours) != .complete);
    try testing.expectEqual(@as(usize, 0), colours.items.len);
}

test "a large sparse graph is coloured completely and properly" {
    // Oracle: construct-from-answer, at a size the search's bucketed queue
    // spreads over many words. 5000 nodes, each joined to three random nodes
    // of the other parity (so the parity is a 2-colouring) plus 300 disjoint
    // triangles on 900 more nodes, each triangle needing all three masks.
    // 3-colourable by construction, and DSATUR colours it without
    // backtracking. More than 4096 nodes puts the queue's buckets past one
    // summary word, the layout a wrong bucket offset scrambles.
    var rng = Rng.init(21);
    const n: u32 = 5000;
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    for (0..n) |a_| {
        const a: u32 = @intCast(a_);
        for (0..3) |_| {
            var b: u32 = @intCast(rng.below(n));
            if (b % 2 == a % 2) b = (b + 1) % n;
            try edges.append(gpa, .{ @min(a, b), @max(a, b) });
        }
    }
    for (0..300) |t_| {
        const t: u32 = @intCast(t_);
        const x = n + 3 * t;
        try edges.appendSlice(gpa, &.{ .{ x, x + 1 }, .{ x + 1, x + 2 }, .{ x, x + 2 } });
    }
    const total = n + 900;
    rng.shuffle([2]u32, edges.items);
    var colours: std.ArrayList(u8) = .empty;
    defer colours.deinit(gpa);
    try testing.expectEqual(Coloring.complete, try colorOf(total, edges.items, 3, &colours));
    try testing.expectEqual(@as(usize, total), colours.items.len);
    try expectProper(colours.items, edges.items, 3);
}

test "an uncolourable layer is one violation naming the shape that could not be placed" {
    // Oracle: construct-from-answer. Three mutually conflicting shapes need
    // three masks and the process has two, so the layer cannot be
    // manufactured. One violation, not three: the defect is the cycle. The
    // measurement and point within the shape are not asserted (the rule
    // states neither); one row naming one shape of the three is.
    var case = try oddCycleCase();
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &common.single(patterning(2, 71)));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    const v = sink.out.get(0);
    try testing.expectEqual(RULE, v.rule);
    try testing.expectEqual(A, v.layer);
    try testing.expectEqual(check.report.Severity.@"error", v.severity);
    try testing.expectEqual(check.report.no_shape, v.shape_b);
    const squares = [_][4]i64{ .{ -50, -50, 50, 50 }, .{ 100, -50, 200, 50 }, .{ -50, 100, 50, 200 } };
    var on_one = false;
    for (squares) |q| on_one = on_one or (v.at.x >= q[0] and v.at.x <= q[2] and v.at.y >= q[1] and v.at.y <= q[3]);
    try testing.expect(on_one);
    const run = try testgen.assertRuleRan(sink.runs.items, RULE);
    try testing.expectEqual(@as(u64, case.shapes), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
}

test "the same layer with a third mask available is clean" {
    // Oracle: construct-from-answer. The same three shapes with a third mask
    // available are colourable, and the rule says so having looked at all
    // three.
    var case = try oddCycleCase();
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &common.single(patterning(3, 71)));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, case.shapes), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "one unit of colour spacing separates a path from an odd cycle" {
    // Oracle: construct-from-answer, and the boundary that decides the
    // verdict. At a colour spacing of 70 the diagonal pair is out of
    // conflict (5000 against 4900), so the graph is a path and two masks
    // suffice; at 71 it is a triangle and they do not.
    var case = try oddCycleCase();
    defer case.deinit(gpa);
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &case.store, &common.single(patterning(2, 71)));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try common.runRules(&sink, &case.store, &common.single(patterning(2, 70)));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
    try testing.expectEqual(@as(u64, case.shapes), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
}

test "a figure whose own notch is below the colour spacing has no colouring" {
    // Oracle: Calibre's self-conflict, worked by hand. A U drawn as three
    // abutting rectangles is one figure whose arms face each other 100 apart
    // across empty space: on one mask they are closer than a colour spacing
    // of 101, so no number of masks splits it, while at 100 they are legal
    // and the lone figure takes one mask.
    var lb = LayoutBuilder.init(1);
    _ = try lb.rect(gpa, 0, 0, 0, 300, 100);
    _ = try lb.rect(gpa, 0, 0, 100, 100, 300);
    _ = try lb.rect(gpa, 0, 200, 100, 300, 300);
    var built = try common.finish(&lb);
    defer built.deinit();
    var sink: Sink = .{};
    defer sink.deinit();
    try common.runRules(&sink, &built.store, &common.single(patterning(3, 101)));
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expectEqual(@as(u64, 3), (try testgen.assertRuleRan(sink.runs.items, RULE)).examined);
    try common.runRules(&sink, &built.store, &common.single(patterning(1, 100)));
    try testgen.assertClean(sink.runs.items, &sink.out, RULE);
}

test "anchor conflicts agree with every colouring tried" {
    // Oracle: brute-force colouring (NV). On 4000 random connected graphs of
    // 1 to 6 nodes, 1 to 3 colours, and random anchors (a fifth of them on
    // two colours at once), `anchorConflict` says unsplittable exactly when
    // no colouring exists, honoured exactly when one honours the anchors,
    // and conflict otherwise; and the conflict it names is one: with two
    // colours the pair it names cannot both be honoured, or the node it
    // names holds two anchors, and with more the node it names is the
    // lowest anchored.
    var rng = Rng.init(0x00a1_1c40);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    var anchors: [6]u8 = undefined;
    for (0..4000) |_| {
        const n: u32 = @intCast(rng.below(6) + 1);
        const k: u8 = @intCast(rng.below(3) + 1);
        edges.clearRetainingCapacity();
        for (1..n) |i| try edges.append(gpa, .{ @intCast(rng.below(i)), @intCast(i) });
        for (0..n) |a| for (a + 1..n) |b| {
            if (rng.unit() < 0.3) try edges.append(gpa, .{ @intCast(a), @intCast(b) });
        };
        for (anchors[0..n]) |*an| {
            if (rng.unit() < 0.5) {
                an.* = 0;
                continue;
            }
            const one = @as(u8, 1) << @intCast(rng.below(k));
            an.* = if (k > 1 and rng.unit() < 0.2) one | @as(u8, 1) << @intCast((@ctz(one) + 1) % k) else one;
        }
        const held = anchors[0..n];
        const got = try color.anchorConflict(gpa, n, edges.items, held, k, &out);
        const splittable = bruteForce(n, edges.items, held, k, false);
        const honoured = bruteForce(n, edges.items, held, k, true);
        switch (got) {
            .unsplittable => try testing.expect(!splittable),
            .honoured => try testing.expect(splittable and honoured),
            .exhausted => return error.TestUnexpectedResult,
            .conflict => |cf| {
                try testing.expect(splittable and !honoured);
                try testing.expect(held[cf.node] != 0);
                if (cf.other) |v| {
                    try testing.expectEqual(@as(u8, 2), k);
                    var pair: [6]u8 = @splat(0);
                    pair[cf.node] = held[cf.node];
                    pair[v] = held[v];
                    try testing.expect(!bruteForce(n, edges.items, pair[0..n], k, true));
                } else if (@popCount(held[cf.node]) <= 1) {
                    try testing.expect(k != 2);
                    try testing.expectEqual(@as(?usize, cf.node), std.mem.indexOfNone(u8, held, &.{0}));
                }
            },
        }
    }
}
