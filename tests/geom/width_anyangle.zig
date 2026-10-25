//! Widths, notches and the edge-pair relation at any angle
//! (`width.narrowestPairAny`, `relation.pairThresholdAny`), and the
//! booleans under an exact rotation. Ported from
//! crates/geom/tests/core/width_anyangle.rs.
//!
//! Oracle: a differential against the octilinear measures on octilinear
//! figures (where both are exact integers); the Pythagorean rotation law,
//! `(x, y) → (3x − 4y, 4x + 3y)` mapping the grid into itself and every
//! length times 5, so a rectilinear figure's width and notch, twice squared,
//! come back times 25 on its image, whose edges are at any angle, and a
//! boolean of images is the image of the boolean (no crossing falls between
//! grid points); and a hand-derived width that is a fraction.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const testgen = @import("testgen");
const prop = testgen.prop;
const Rng = testgen.Rng;
const fx = @import("fixture.zig");
const gpa = fx.gpa;
const width = geom.width;
const relation = geom.relation;
const Seg = geom.Seg;
const Twice = geom.ops.Twice;
const ValidatedLayer = geom.ValidatedLayer;

const Ring = []const [2]i64;
const far: i64 = 100_000;
/// A figure's width and notch, twice squared; the notch may be absent.
const Measure = struct { w: Twice, notch: ?Twice };

// ---- private ----

/// The Pythagorean rotation: the grid into itself, every length times 5.
fn turn(p: [2]i64) [2]i64 {
    return .{ 3 * p[0] - 4 * p[1], 4 * p[0] + 3 * p[1] };
}

fn turnSeg(s: Seg) Seg {
    const a = turn(.{ s.a.x, s.a.y });
    const b = turn(.{ s.b.x, s.b.y });
    return .{ .a = .{ .x = a[0], .y = a[1] }, .b = .{ .x = b[0], .y = b[1] } };
}

fn identity(p: [2]i64) [2]i64 {
    return p;
}

fn mapRings(arena: Allocator, rings: []const Ring, comptime f: fn ([2]i64) [2]i64) ![]const Ring {
    const out = try arena.alloc(Ring, rings.len);
    for (out, rings) |*o, r| {
        const pts = try arena.alloc([2]i64, r.len);
        for (pts, r) |*q, p| q.* = f(p);
        o.* = pts;
    }
    return out;
}

fn double(p: [2]i64) [2]i64 {
    return .{ 2 * p[0], 2 * p[1] };
}

fn shrinkNonEmpty(arena: Allocator, rings: []const Ring) Allocator.Error![]const []const Ring {
    return fx.dropOne(Ring, arena, rings, true);
}

fn octShapes(arena: Allocator, rng: *Rng) Allocator.Error![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    const n = rng.range(1, 5);
    for (0..@intCast(n)) |_| try out.append(arena, try fx.randomOctShape(arena, rng));
    return out.items;
}

fn twiceLess(_: void, a: [2]?Twice, b: [2]?Twice) bool {
    for (a, b) |x, y| {
        if (std.meta.eql(x, y)) continue;
        if (x == null) return true;
        if (y == null) return false;
        return x.?.lessThan(y.?);
    }
    return false;
}

/// Every figure's width and notch, any-angle or octilinear (scaled by
/// `scale`), sorted.
fn sortedPairs(l: *const ValidatedLayer, scale: i128, any: bool, out: *std.ArrayList([2]?Twice)) !void {
    out.clearRetainingCapacity();
    for (0..l.len()) |i| {
        const poly = l.get(@intCast(i));
        var row: [2]?Twice = undefined;
        for ([2]width.Gap{ .width, .notch }, &row) |gap, *r| {
            if (any) {
                r.* = if (try width.narrowestPairAny(gpa, poly, gap, far)) |f| f.d2 else null;
            } else {
                r.* = if (try width.narrowestPair2(gpa, poly, gap, far)) |f| Twice.whole(scale * f.d2) else null;
            }
        }
        try out.append(gpa, row);
    }
    std.mem.sort([2]?Twice, out.items, {}, twiceLess);
}

/// On octilinear figures the any-angle measures are the octilinear ones,
/// exact: width and notch, and every relation in every zero mode; turned,
/// every threshold is 25 times the octilinear one.
fn octilinearAgree(arena: Allocator, rings: []const Ring, why: *prop.Why) anyerror!void {
    var merged = try fx.layerOf(rings, .any, true);
    defer merged.deinit(gpa);
    // The turned figures' widths and notches are 25 times the octilinear
    // ones. Both at twice the scale, where every crossing of two 45-degree
    // edges is a grid point, so neither merge moves a vertex.
    const doubled_rings = try mapRings(arena, rings, double);
    var doubled = try fx.layerOf(doubled_rings, .any, true);
    defer doubled.deinit(gpa);
    var turned = try fx.layerOf(try mapRings(arena, doubled_rings, turn), .any, true);
    defer turned.deinit(gpa);
    var want: std.ArrayList([2]?Twice) = .empty;
    defer want.deinit(gpa);
    var got: std.ArrayList([2]?Twice) = .empty;
    defer got.deinit(gpa);
    try sortedPairs(&doubled, 25, false, &want);
    try sortedPairs(&turned, 1, true, &got);
    if (!std.meta.eql(want.items.len, got.items.len)) return why.fail("turned figure count", .{});
    for (want.items, got.items) |w, g| if (!std.meta.eql(w, g)) return why.fail("turned widths and notches: {any} vs 25 x {any}", .{ g, w });

    var edges: std.ArrayList(Seg) = .empty;
    defer edges.deinit(gpa);
    for (0..merged.len()) |idx| {
        const poly = merged.get(@intCast(idx));
        for ([2]width.Gap{ .width, .notch }) |gap| {
            const octo: ?Twice = if (try width.narrowestPair2(gpa, poly, gap, far)) |f| Twice.whole(f.d2) else null;
            const any: ?Twice = if (try width.narrowestPairAny(gpa, poly, gap, far)) |f| f.d2 else null;
            if (!std.meta.eql(octo, any)) return why.fail("figure {d} {s}: {any} vs {any}", .{ idx, @tagName(gap), octo, any });
        }
        edges.clearRetainingCapacity();
        var it = width.polyEdges(poly);
        while (it.next()) |s| try edges.append(gpa, .{ .a = s.b, .b = s.a });
        for (edges.items) |e| for (edges.items) |f| {
            for ([_]relation.Relation{ .width, .space, .overlap, .inside }) |rel| {
                for ([_]relation.Zero{ .never, .when_touching, .when_overlapping }) |zero| {
                    const octo: ?Twice = if (relation.pairThreshold2(rel, .euclidean, zero, e, f)) |d| Twice.whole(d) else null;
                    const any = relation.pairThresholdAny(rel, zero, e, f);
                    if (!std.meta.eql(octo, any)) return why.fail("{s} {s} {any} {any}: {any} vs {any}", .{ @tagName(rel), @tagName(zero), e, f, octo, any });
                    // Turned, every edge is at an angle other than a
                    // multiple of 45 degrees and every cut a rational point.
                    const t = relation.pairThresholdAny(rel, zero, turnSeg(e), turnSeg(f));
                    const want_t: ?Twice = if (octo) |o| Twice.whole(25 * o.floor) else null;
                    if (!std.meta.eql(t, want_t)) return why.fail("{s} {s} {any} {any} turned: {any} vs 25 x {any}", .{ @tagName(rel), @tagName(zero), e, f, t, octo });
                }
            }
        };
    }
}

fn rectangles(arena: Allocator, rng: *Rng) Allocator.Error![]const Ring {
    var out: std.ArrayList(Ring) = .empty;
    const n = rng.range(1, 6);
    for (0..@intCast(n)) |_| {
        const x = rng.range(-20, 16);
        const y = rng.range(-20, 16);
        const w = rng.range(1, 21 - x);
        const h = rng.range(1, 21 - y);
        try out.append(arena, try arena.dupe([2]i64, &.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } }));
    }
    return out.items;
}

fn measureLess(_: void, a: Measure, b: Measure) bool {
    return twiceLess({}, .{ a.w, a.notch }, .{ b.w, b.notch });
}

/// Every figure's width and notch, twice squared, sorted: measured at any
/// angle, or rectilinear and scaled by 25.
fn measures(l: *const ValidatedLayer, any: bool, out: *std.ArrayList(Measure)) !void {
    out.clearRetainingCapacity();
    var scratch: width.FacingScratch = .{};
    defer scratch.deinit(gpa);
    for (0..l.len()) |i| {
        const poly = l.get(@intCast(i));
        if (any) {
            const w = (try width.narrowestPairAny(gpa, poly, .width, far)).?.d2;
            const n: ?Twice = if (try width.narrowestPairAny(gpa, poly, .notch, far)) |f| f.d2 else null;
            try out.append(gpa, .{ .w = w, .notch = n });
        } else {
            const w = 2 * try width.narrowestWidth2(gpa, poly, &scratch);
            const n: ?Twice = if (try width.narrowestFacing(gpa, poly, .notch, &scratch)) |f| Twice.whole(25 * 2 * geom.mulWide(f.gap, f.gap)) else null;
            try out.append(gpa, .{ .w = .whole(25 * w), .notch = n });
        }
    }
    std.mem.sort(Measure, out.items, {}, measureLess);
}

fn rotated(arena: Allocator, rings: []const Ring, why: *prop.Why) anyerror!void {
    const image = try mapRings(arena, rings, turn);
    var here = try fx.layerOf(rings, .any, true);
    defer here.deinit(gpa);
    var there = try fx.layerOf(image, .any, true);
    defer there.deinit(gpa);
    var want: std.ArrayList(Measure) = .empty;
    defer want.deinit(gpa);
    var got: std.ArrayList(Measure) = .empty;
    defer got.deinit(gpa);
    try measures(&here, false, &want);
    try measures(&there, true, &got);
    if (want.items.len != got.items.len) return why.fail("figure counts differ", .{});
    for (want.items, got.items) |w, g| if (!std.meta.eql(w, g)) return why.fail("widths: {any} turned, {any} measured", .{ w, g });
    // Booleans of images: the first rectangle against the rest.
    var a = try fx.layerOf(rings[0..1], .any, false);
    defer a.deinit(gpa);
    var b = try fx.layerOf(rings[1..], .any, false);
    defer b.deinit(gpa);
    var ta = try fx.layerOf(image[0..1], .any, false);
    defer ta.deinit(gpa);
    var tb = try fx.layerOf(image[1..], .any, false);
    defer tb.deinit(gpa);
    for ([_]fx.Kind{ .@"or", .@"and", .not }) |kind| {
        var w_l = try fx.run(kind, &a, &b);
        defer w_l.deinit(gpa);
        var g_l = try fx.run(kind, &ta, &tb);
        defer g_l.deinit(gpa);
        var we = try fx.edgeSet(&w_l, turn, false);
        defer we.deinit(gpa);
        var ge = try fx.edgeSet(&g_l, identity, false);
        defer ge.deinit(gpa);
        if (!std.mem.eql(i64, @ptrCast(we.items), @ptrCast(ge.items))) return why.fail("boolean {s} does not commute with the turn", .{@tagName(kind)});
    }
}

test "the any angle measures are the octilinear ones on octilinear figures" {
    // Oracle: differential against `narrowest_pair2` and `pair_threshold2` on
    // random merged octilinear shapes, over 200 named seeds; and the
    // Pythagorean rotation law on the same shapes, whose 45-degree edges turn
    // to directions such as (−1, 7) and (7, 1), so every cut of a 135-degree
    // pair is a rational point the any-angle relation computes: every
    // threshold, width and notch, twice squared, is 25 times the octilinear
    // one.
    try prop.check(gpa, []const Ring, "width_anyangle_octilinear", 200, &.{}, octShapes, shrinkNonEmpty, octilinearAgree);
}

test "a pythagorean turn scales widths and commutes with booleans" {
    // Oracle: the Pythagorean rotation law in the module doc, on random
    // rectangles (overlaps, necks, notches, holes, corner touches), over 200
    // named seeds: widths and notches times 25, booleans commuting.
    try prop.check(gpa, []const Ring, "width_anyangle_turn", 200, &.{}, rectangles, shrinkNonEmpty, rotated);
}

test "a width at any angle is a fraction compared exactly" {
    // Oracle: hand-derived. A rectangle turned to run along (5, 1), (0,0),
    // (25,5),(22,20),(-3,15), with a V notch cut from its top side down to
    // (10, 9) between (12, 18) and (7, 17): no corner is under 90 degrees, no
    // short edge joins two edges facing across it, and the narrowest width is
    // from the V's tip square to the bottom side: `cross((5,1), (10,9)) = 35`,
    // so twice the squared width is `2·35²/26 = 94.23…`, floored 94, a
    // fraction. Every other pair is wider (the V's sides against the left side,
    // `52/√26`; the top side against the bottom, `3·√26`). The bounds then read
    // the fraction exactly: `> √47` (`95..`) holds it, `>= √48` (`96..`) does
    // not, `<= √47` (`..=94`) does not, `< √48` (`..=95`) does.
    var merged = try fx.layerOf(&.{&.{ .{ 0, 0 }, .{ 25, 5 }, .{ 22, 20 }, .{ 12, 18 }, .{ 10, 9 }, .{ 7, 17 }, .{ -3, 15 } }}, .any, true);
    defer merged.deinit(gpa);
    const w = (try width.narrowestPairAny(gpa, merged.get(0), .width, far)).?;
    try testing.expectEqual(Twice{ .floor = 94, .inexact = true }, w.d2);
    var out: ValidatedLayer = .empty;
    defer out.deinit(gpa);
    const cases = [_]struct { lo: i128, hi: i128, kept: u32 }{
        .{ .lo = 95, .hi = std.math.maxInt(i128), .kept = 1 }, // > √47
        .{ .lo = 96, .hi = std.math.maxInt(i128), .kept = 0 }, // >= √48
        .{ .lo = 0, .hi = 94, .kept = 0 }, // <= √47
        .{ .lo = 0, .hi = 95, .kept = 1 }, // < √48
    };
    for (cases) |c| {
        try geom.derive.withWidthInto(gpa, &merged, c.lo, c.hi, &out);
        try testing.expectEqual(c.kept, out.len());
    }
}
