//! The two edge builders, on geometry small enough to state the answer
//! for. Ported from crates/check/tests/topology/edges.rs.
//!
//! Oracle: construct-from-answer; each test holds a pair that must produce
//! an edge and a pair that must not.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const net = check.topology.net;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Ids = testgen.shapes.Ids;
const Handle = testgen.shapes.Handle;

const gpa = testing.allocator;

/// A built layout and its handle map.
const Built = struct {
    store: geom.GeometryStore = .empty,
    ids: Ids = .{},

    fn deinit(b: *Built) void {
        b.store.deinit(gpa);
        b.ids.deinit(gpa);
    }

    /// One expected edge, unordered pair as `(low, high)`.
    fn pair(b: *const Built, x: Handle, y: Handle) [2]u32 {
        const p = @backingInt(b.ids.of(x));
        const q = @backingInt(b.ids.of(y));
        return .{ @min(p, q), @max(p, q) };
    }
};

// ---- private ----

fn finish(lb: *LayoutBuilder) !Built {
    var b: Built = .{};
    try lb.finish(gpa, &b.store, &b.ids);
    return b;
}

/// The edge set as unordered pairs, sorted and deduplicated: a union-find
/// ignores orientation and repetition, so the claim is about the set.
fn edgeSet(edges: [][2]u32) [][2]u32 {
    for (edges) |*e| e.* = .{ @min(e[0], e[1]), @max(e[0], e[1]) };
    std.mem.sortUnstable([2]u32, edges, {}, struct {
        fn less(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }
    }.less);
    var kept: usize = 0;
    for (edges) |e| {
        if (kept > 0 and std.mem.eql(u32, &edges[kept - 1], &e)) continue;
        edges[kept] = e;
        kept += 1;
    }
    return edges[0..kept];
}

fn lid(l: u16) geom.LayerId {
    return @fromBackingInt(l);
}

test "shapes that overlap or abut are one edge and an isolated shape is none" {
    // Oracle: construct-from-answer. An overlapping pair and an abutting
    // pair are each one edge, and an isolated square is none: shapes sharing
    // an edge and no area are one conductor.
    var lb = LayoutBuilder.init(1);
    defer lb.deinit(gpa);
    const oa = try lb.rect(gpa, 0, 0, 0, 100, 100);
    const ob = try lb.rect(gpa, 0, 50, 0, 150, 100);
    const aa = try lb.rect(gpa, 0, 300, 0, 400, 100);
    const ab = try lb.rect(gpa, 0, 400, 0, 500, 100);
    const isolated = try lb.rect(gpa, 0, 700, 0, 800, 100);
    var b = try finish(&lb);
    defer b.deinit();
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try net.intraLayerEdgesInto(gpa, &b.store, lid(0), &edges);
    var want = [_][2]u32{ b.pair(oa, ob), b.pair(aa, ab) };
    _ = edgeSet(&want);
    const got = edgeSet(edges.items);
    try testing.expectEqualSlices([2]u32, &want, got);
    const iso = @backingInt(b.ids.of(isolated));
    for (got) |e| try testing.expect(e[0] != iso and e[1] != iso);
}

test "a cut over both layers joins them and a cut over one is no edge and no error" {
    // Oracle: construct-from-answer. A cut in the overlap of the two layers
    // contributes exactly the pair it sits on; a second cut over the lower
    // layer only contributes nothing, in the same call.
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const lower = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
    const upper = try lb.rect(gpa, 1, 500, 500, 1_500, 1_500);
    _ = try lb.rect(gpa, 2, 600, 600, 700, 700);
    _ = try lb.rect(gpa, 2, 100, 100, 200, 200);
    var b = try finish(&lb);
    defer b.deinit();
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try net.viaEdgesInto(gpa, &b.store, lid(2), .{ lid(0), lid(1) }, &edges);
    try testing.expectEqualSlices([2]u32, &.{b.pair(lower, upper)}, edgeSet(edges.items));
}

test "a cut reports only pairs spanning the two layers it was asked about" {
    // Oracle: construct-from-answer. A cut over two lower shapes and no
    // upper one, and a cut over nothing, join nothing; the one legal via is
    // checked in the same call.
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const lower_left = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
    _ = try lb.rect(gpa, 0, 1_000, 0, 2_000, 1_000);
    const upper = try lb.rect(gpa, 1, 0, 0, 500, 500);
    _ = try lb.rect(gpa, 2, 900, 700, 1_100, 800);
    _ = try lb.rect(gpa, 2, 100, 100, 200, 200);
    _ = try lb.rect(gpa, 2, 5_000, 5_000, 5_100, 5_100);
    var b = try finish(&lb);
    defer b.deinit();
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try net.viaEdgesInto(gpa, &b.store, lid(2), .{ lid(0), lid(1) }, &edges);
    try testing.expectEqualSlices([2]u32, &.{b.pair(lower_left, upper)}, edgeSet(edges.items));
}

test "every cut of a stack is its own row" {
    // Oracle: construct-from-answer, `viaCutsInto`'s doc. Two cuts over one
    // lower and one upper shape are a row each, `(cut, lower, upper)`
    // ascending by cut, where `viaEdgesInto` merges them into one edge; a
    // third cut over the lower shape alone is no row.
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const low = try lb.rect(gpa, 0, 0, 0, 1_000, 1_000);
    const high = try lb.rect(gpa, 1, 0, 0, 1_000, 500);
    const first = try lb.rect(gpa, 2, 100, 100, 200, 200);
    const second = try lb.rect(gpa, 2, 300, 100, 400, 200);
    _ = try lb.rect(gpa, 2, 600, 700, 700, 800);
    var b = try finish(&lb);
    defer b.deinit();
    var cuts: std.ArrayList([3]u32) = .empty;
    defer cuts.deinit(gpa);
    try cuts.append(gpa, .{ 9, 9, 9 });
    try net.viaCutsInto(gpa, &b.store, lid(2), .{ lid(0), lid(1) }, &cuts);
    var want = [2][3]u32{
        .{ @backingInt(b.ids.of(first)), @backingInt(b.ids.of(low)), @backingInt(b.ids.of(high)) },
        .{ @backingInt(b.ids.of(second)), @backingInt(b.ids.of(low)), @backingInt(b.ids.of(high)) },
    };
    if (want[0][0] > want[1][0]) std.mem.swap([3]u32, &want[0], &want[1]);
    try testing.expectEqualSlices([3]u32, &want, cuts.items);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try net.viaEdgesInto(gpa, &b.store, lid(2), .{ lid(0), lid(1) }, &edges);
    try testing.expectEqualSlices([2]u32, &.{b.pair(low, high)}, edgeSet(edges.items));
}
