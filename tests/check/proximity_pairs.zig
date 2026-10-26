//! The shared pair pipeline from outside the module: validation cached per
//! layer, candidate pairs measured and judged, net-decided spacing,
//! containment of merged figures, and the CPU-vs-GPU pair-distance gate.
//! New tests: Rust exercised these only through the drc rule families
//! (wave 3); each states a hand-worked oracle.
//!
//! Contents (test contexts the generic pipeline calls):
//! - `Whole.measure(_: Whole, _: PolyId, _: PolyId, d2: geom.DbuArea) ?geom.DbuArea`,
//!   `Whole.at(w: Whole, alloc: std.mem.Allocator, a: PolyId, b: PolyId, d2: geom.DbuArea) std.mem.Allocator.Error!geom.Point`
//! - `SameFree.needOf(_: SameFree, a: u32, b: u32) proximity.Need`
//! - `Everyone.judge(_: Everyone, _: PolyId) bool`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const options = @import("check_options");
const proximity = check.proximity;
const report = check.report;
const Scratch = proximity.Scratch;
const Violations = report.Violations;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Ids = testgen.shapes.Ids;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;

const gpa = testing.allocator;
const rule: geom.StrId = @fromBackingInt(7);

/// Measures every pair whole and marks it where `wholeAt` does.
const Whole = struct {
    store: *const GeometryStore,

    pub fn measure(_: Whole, _: PolyId, _: PolyId, d2: geom.DbuArea) ?geom.DbuArea {
        return d2;
    }

    pub fn at(w: Whole, alloc: std.mem.Allocator, a: PolyId, b: PolyId, d2: geom.DbuArea) std.mem.Allocator.Error!geom.Point {
        return proximity.wholeAt(alloc, w.store, a, b, d2);
    }
};

/// Same net: nothing required; different nets: 60.
const SameFree = struct {
    pub fn needOf(_: SameFree, a: u32, b: u32) proximity.Need {
        return if (a == b) .free else .{ .limit = 60 };
    }
};

const Everyone = struct {
    pub fn judge(_: Everyone, _: PolyId) bool {
        return true;
    }
};

/// Two 100 x 200 rectangles on layer 0, 50 apart in x.
const Pair = struct {
    store: GeometryStore = .empty,
    ids: Ids = .{},

    fn init(extra: []const [5]i64) !Pair {
        var lb = LayoutBuilder.init(2);
        defer lb.deinit(gpa);
        _ = try lb.rect(gpa, 0, 0, 0, 100, 200);
        _ = try lb.rect(gpa, 0, 150, 0, 250, 200);
        for (extra) |r| _ = try lb.rect(gpa, @intCast(r[0]), r[1], r[2], r[3], r[4]);
        var p: Pair = .{};
        try lb.finish(gpa, &p.store, &p.ids);
        return p;
    }

    fn deinit(p: *Pair) void {
        p.store.deinit(gpa);
        p.ids.deinit(gpa);
    }

    fn row(p: *const Pair, k: u32) PolyId {
        return p.ids.of(@fromBackingInt(k));
    }
};

test "a pair closer than its limit is reported at the middle of its facing run" {
    // Oracle: hand-worked. The facing sides x = 100 and x = 150 run over
    // y = 0..200, so the gap is 50 and its middle (125, 100); a limit of 60
    // reports it, a limit of exactly 50 does not (strict).
    var p = try Pair.init(&.{});
    defer p.deinit();
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var out: Violations = .{};
    defer out.deinit(gpa);
    try testing.expect(try proximity.prepare(gpa, &p.store, @fromBackingInt(0), 60, &s));
    const examined = try proximity.judgedPairs(gpa, &p.store, rule, @fromBackingInt(0), 60, &s, &out, Whole{ .store = &p.store });
    try testing.expectEqual(@as(u64, 1), examined);
    try testgen.assertOnlyViolation(&out, .{
        .rule = rule,
        .layer = @fromBackingInt(0),
        .severity = .@"error",
        .at = .{ .x = 125, .y = 100 },
        .measured = .length(50),
        .limit = .length(60),
        .shape_a = p.row(0),
        .shape_b = p.row(1),
    });
    out.truncate(0);
    try testing.expect(try proximity.prepare(gpa, &p.store, @fromBackingInt(0), 50, &s));
    _ = try proximity.judgedPairs(gpa, &p.store, rule, @fromBackingInt(0), 50, &s, &out, Whole{ .store = &p.store });
    try testing.expectEqual(@as(u32, 0), out.len());
}

test "touching shapes are one figure and are never judged against each other" {
    // Oracle: hand-worked. A third rectangle abutting the first at x = 100
    // merges with it into one figure, so the bar and the first rectangle are
    // never judged against each other; both are judged against the right
    // rectangle (30 and 50 apart), so two rows, each naming it.
    var p = try Pair.init(&.{.{ 0, 100, 0, 120, 50 }});
    defer p.deinit();
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var out: Violations = .{};
    defer out.deinit(gpa);
    try testing.expect(try proximity.prepare(gpa, &p.store, @fromBackingInt(0), 60, &s));
    _ = try proximity.judgedPairs(gpa, &p.store, rule, @fromBackingInt(0), 60, &s, &out, Whole{ .store = &p.store });
    try testing.expectEqual(@as(u32, 2), out.len());
    for (0..out.len()) |i| {
        const v = out.get(@intCast(i));
        try testing.expect(v.shape_a == p.row(1) or v.shape_b == p.row(1));
        try testing.expect(v.shape_a != v.shape_b);
    }
}

test "net spacing judges by the pair's nets and refuses a row on no net" {
    // Oracle: hand-worked. On different nets the pair is held to 60 and its
    // gap of 50 fails; on one net nothing is required (judged, clean); a
    // row on no net refuses the rule.
    var p = try Pair.init(&.{});
    defer p.deinit();
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var out: Violations = .{};
    defer out.deinit(gpa);
    const verdict = try proximity.netPairSpacing(gpa, &p.store, &.{ 0, 1 }, rule, @fromBackingInt(0), null, 60, &s, &out, SameFree{});
    try testing.expectEqual(report.Verdict{ .outcome = .ran, .examined = 1 }, verdict);
    try testing.expectEqual(@as(u32, 1), out.len());
    try testing.expectEqual(@as(i128, 50), out.get(0).measured.exact());
    out.truncate(0);
    const same = try proximity.netPairSpacing(gpa, &p.store, &.{ 3, 3 }, rule, @fromBackingInt(0), null, 60, &s, &out, SameFree{});
    try testing.expectEqual(report.Verdict{ .outcome = .ran, .examined = 1 }, same);
    try testing.expectEqual(@as(u32, 0), out.len());
    const refused = try proximity.netPairSpacing(gpa, &p.store, &.{ 3, proximity.no_net }, rule, @fromBackingInt(0), null, 60, &s, &out, SameFree{});
    try testing.expectEqual(report.refused, refused);
}

test "a figure half outside its host reports the area left outside" {
    // Oracle: hand-worked. Inner square 0..100 against an outer 50..200 over
    // y 0..100 leaves 50 x 100 = 5000 outside, marked at the square's centre
    // (50, 50); the second inner square, 300..340, lies inside an outer
    // 280..400 and is clean.
    var lb = LayoutBuilder.init(2);
    defer lb.deinit(gpa);
    const half = try lb.rect(gpa, 0, 0, 0, 100, 100);
    _ = try lb.rect(gpa, 0, 300, 0, 340, 40);
    _ = try lb.rect(gpa, 1, 50, 0, 200, 100);
    _ = try lb.rect(gpa, 1, 280, -10, 400, 100);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var out: Violations = .{};
    defer out.deinit(gpa);
    const verdict = try check.proximity_inside.insideWhere(gpa, &store, rule, @fromBackingInt(0), @fromBackingInt(1), &s, &out, Everyone{});
    try testing.expectEqual(report.Verdict{ .outcome = .ran, .examined = 2 }, verdict);
    try testgen.assertOnlyViolation(&out, .{
        .rule = rule,
        .layer = @fromBackingInt(0),
        .severity = .@"error",
        .at = .{ .x = 50, .y = 50 },
        .measured = .area(5000),
        .limit = .area(0),
        .shape_a = ids.of(half),
        .shape_b = report.no_shape,
    });
}

test "a figure is tagged when it shares area with the tag layer, not an edge" {
    // Oracle: hand-worked. The tag overlaps the left rectangle and only
    // abuts the right one along x = 150.
    var p = try Pair.init(&.{.{ 1, 50, 50, 150, 100 }});
    defer p.deinit();
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var owner: std.ArrayList(PolyId) = .empty;
    defer owner.deinit(gpa);
    var shares: std.ArrayList(bool) = .empty;
    defer shares.deinit(gpa);
    try testing.expect(try check.proximity_inside.taggedFigures(gpa, &p.store, @fromBackingInt(0), @fromBackingInt(1), &s, &owner, &shares));
    try testing.expectEqualSlices(PolyId, &.{ p.row(0), p.row(1) }, owner.items);
    try testing.expectEqualSlices(bool, &.{ true, false }, shares.items);
}

test "a layer is validated once and forgotten on request" {
    // Oracle: law. Two asks give the same table; after `forget` the layer
    // revalidates to an equal one; a bowtie never validates.
    var lb = LayoutBuilder.init(2);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, 0, 0, 0, 10, 10);
    _ = try lb.push(gpa, 1, &.{ 0, 10, 10, 0 }, &.{ 0, 10, 0, 10 });
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var v: proximity.Validated = .{};
    defer v.deinit(gpa);
    const first = (try v.getAny(gpa, &store, @fromBackingInt(0))).?;
    try testing.expectEqual(first, (try v.get(gpa, &store, @fromBackingInt(0))).?);
    v.forget(gpa, @fromBackingInt(0));
    try testing.expectEqual(@as(u32, 1), (try v.getAny(gpa, &store, @fromBackingInt(0))).?.len());
    try testing.expectEqual(null, try v.getAny(gpa, &store, @fromBackingInt(1)));
}

test "the GPU pair-distance kernel gives the CPU's bits (-Dcheck-gpu-test)" {
    // Oracle: differential, CPU body against GPU body, bit-equal, at 0, 1,
    // block - 1, block and 3 * block + 1 pairs (block = 256 lanes). Off by
    // default; with the gate on it fails without a driver, never skips.
    if (!options.gpu_test) return;
    var lb = LayoutBuilder.init(1);
    defer lb.deinit(gpa);
    var rng = testgen.Rng.init(9);
    for (0..40) |_| {
        const x = rng.range(-5000, 5000);
        const y = rng.range(-5000, 5000);
        _ = try lb.shape(gpa, 0, testgen.shapes.lShape(x, y, 300, 80));
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var pairs: [3 * 256 + 1]geom.index.Pair = undefined;
    for (&pairs, 0..) |*q, i| q.* = .{ .a = @fromBackingInt(@intCast(i % 40)), .b = @fromBackingInt(@intCast((i * 13 + 5) % 40)) };
    var cpu: [pairs.len]i64 = undefined;
    var gpu: [pairs.len]i64 = undefined;
    const dist = check.proximity_distance;
    for ([_]usize{ 0, 1, 255, 256, 3 * 256 + 1 }) |n| {
        try dist.cappedDistancesCpu(&store, pairs[0..n], 1, cpu[0..n]);
        dist.cappedDistancesGpu(gpa, .cuda, &store, pairs[0..n], gpu[0..n]) catch |err| switch (err) {
            error.NotBuilt => try dist.cappedDistancesGpu(gpa, .hip, &store, pairs[0..n], gpu[0..n]),
            else => return err,
        };
        try testing.expectEqualSlices(i64, cpu[0..n], gpu[0..n]);
    }
}
