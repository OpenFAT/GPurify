//! The bitmap reference DRC (X3): every small pattern, run through the
//! engine and through an oracle written from each DRC rule kind's doc
//! comment alone. Ported from tests/exhaustive/bitmap.rs (its fuzz entry
//! `case` aside: no fuzz target reads it here).
//!
//! A pattern is an n×n grid of cells of side `s`, each filled or empty, and
//! each filled cell is drawn as its own rectangle, so abutting cells merge
//! only if the tool merges them. The oracle works on the cells and is meant
//! to be read, not to be fast. Its semantics, as the doc comments state
//! them:
//!
//! - Figures, and the corner model. Shapes that touch or overlap are one
//!   figure, and touching at a corner is touching: the merge joins two
//!   cells that meet only at a corner into one polygon. So figures are the
//!   8-connected components of the filled cells, and empty space is
//!   4-connected: it does not pass a corner where material meets, so a ring
//!   closed only at a corner encloses a hole.
//! - `min_width` (DRC-010): per figure, the narrowest of (a) the gap
//!   between parallel edges facing across material with overlapping
//!   projections, on cells the shortest run of a row or column, and (b) the
//!   Euclidean gap between two concave corners facing across material:
//!   voids pointing away from each other, each corner on the other's
//!   material side. Where two cells of a figure meet only at a corner, the
//!   corner is two concave corners at one point with opposite voids: a neck
//!   of width 0. One finding per figure under the limit.
//! - `min_spacing` (DRC-023): every pair of drawn rows (cells) in different
//!   figures, Euclidean, boundary to boundary. Two figures never touch, so
//!   no pair measures 0.
//! - `notch` (DRC-024): per figure, the narrowest gap between two of its
//!   cells in one row or column with none of its cells between: parallel
//!   edges facing across empty space with overlapping projections, holes
//!   included, corner-to-corner gaps not measured. A gap between two parts
//!   of a figure joined only at corners is a notch (`.#.|#.#` has one of
//!   100).
//! - `min_area` (DRC-017): per figure, its cell count times `s²`.
//! - `min_enclosed_area` (DRC-019): per figure, each bounded 4-connected
//!   component of the cells not in it, times `s²`.
//! - `min_enclosure` (DRC-040): each inner cell, drawn inset by `inset`, is
//!   its own polygon; its host is the outer figure under it, and its
//!   enclosure the Euclidean distance to the nearest point outside the
//!   host; unhosted measures 0.
//! - `min_extension` (DRC-045) and `overlap` (DRC-046), on every pair of
//!   one rectangle per layer: see `extension` and `overlap`.
//!
//! Lengths are compared exactly (squared, in nm²), and `measured` is the
//! distance floored to a whole nm, as the rule doc comments state.
//!
//! The nightly depth enumerates every 4×4 single-layer pattern (65 536,
//! which hold every 3×3 pattern at the origin), every 3×3 two-layer
//! enclosure pattern (2^18), and every pair of rectangles on a 5×5 lattice.
//! The merge depth runs a fixed-seed sample of `sample_size` of each.
//! Pictures are rows top to bottom.
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Rng = @import("testgen").Rng;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const gpa = testing.allocator;

/// The side of a cell, in nm.
const s: i64 = 100;

/// How far an enclosed cell is drawn inside its cell on every side, in nm.
const inset: i64 = 30;

/// Patterns per kind at the merge depth.
const sample_size: usize = 300;

/// The merge sample's seed.
const seed: u64 = 0x0b17_3a9e;

/// A cell `(x, y)`: the square `[x s, (x+1) s] × [y s, (y+1) s]`.
const Cell = [2]i64;

/// A set of cells with `-1 <= x, y <= 6`, cell `(x, y)` as bit
/// `8 (y + 1) + x + 1`. Patterns are at most 4×4, so the set holds the
/// grid, the ring of cells around it that stands for everything outside,
/// and two empty columns that keep a shift by one bit from wrapping onto
/// real cells.
const Set = u64;

/// An n×n pattern: bit `y n + x` fills cell `(x, y)`.
const Pattern = struct {
    n: i64,
    bits: u32,

    fn set(p: Pattern) Set {
        var out: Set = 0;
        for (0..@intCast(p.n * p.n)) |i| if (p.bits >> @intCast(i) & 1 == 1) {
            out |= bit(.{ @mod(@as(i64, @intCast(i)), p.n), @divTrunc(@as(i64, @intCast(i)), p.n) });
        };
        return out;
    }

    /// The merged figures: material joins across a corner.
    fn figures(p: Pattern, arena: Allocator) ![]const Set {
        return components(arena, p.set(), true);
    }

    /// The cells as rectangles on `layer`, each inset by `by`.
    fn draw(p: Pattern, arena: Allocator, layout: *Layout, layer: []const u8, by: i64) !void {
        var it: Cells = .{ .left = p.set() };
        while (it.next()) |c| try layout.rect(arena, layer, c[0] * s + by, c[1] * s + by, c[0] * s + s - by, c[1] * s + s - by);
    }
};

/// The members of a set, ascending by bit.
const Cells = struct {
    left: Set,

    fn next(c: *Cells) ?Cell {
        if (c.left == 0) return null;
        const i: i64 = @ctz(c.left);
        c.left &= c.left - 1;
        return .{ @mod(i, 8) - 1, @divTrunc(i, 8) - 1 };
    }
};

/// What each finding-to-be measures before the limit, from the figures of
/// an n×n pattern: a squared length or an area, both in nm².
const Measure = *const fn (arena: Allocator, figs: []const Set, n: i64) Allocator.Error![]const i64;

/// One single-layer kind: its deck check, catalog row, limits and oracle.
const Kind = struct {
    name: []const u8,
    catalog: []const u8,
    /// The deck check, before `>= <limit><unit>`.
    check: []const u8,
    /// `nm` for a length, `nm2` for an area.
    unit: []const u8,
    /// Chosen between and on the values a 4×4 pattern can measure.
    limits: []const i64,
    measure: Measure,
};

/// Widths on cells: 0 (a corner contact), 100, 141 (√2·s), 200, 223
/// (√5·s), 282, 300, 400. Notches are 100 or 200. Areas and holes are
/// multiples of 10 000 nm².
const kinds = [_]Kind{
    .{ .name = "min_width", .catalog = "DRC-010", .check = "width(met1)", .unit = "nm", .limits = &.{ 120, 150, 200, 250 }, .measure = minWidth },
    .{ .name = "min_spacing", .catalog = "DRC-023", .check = "space(met1)", .unit = "nm", .limits = &.{ 50, 120, 150, 200, 250 }, .measure = minSpacing },
    .{ .name = "notch", .catalog = "DRC-024", .check = "notch(met1)", .unit = "nm", .limits = &.{ 150, 200, 250 }, .measure = notch },
    .{ .name = "min_area", .catalog = "DRC-017", .check = "area(met1)", .unit = "nm2", .limits = &.{ 15_000, 20_000, 35_000, 50_000 }, .measure = minArea },
    .{ .name = "min_enclosed_area", .catalog = "DRC-019", .check = "hole_area(met1)", .unit = "nm2", .limits = &.{ 15_000, 20_000, 25_000 }, .measure = minEnclosedArea },
};

/// Enclosure on inset cells: 0 unhosted, 30 beside the host's edge, 42
/// (√2·30) off its corner, 130 one cell in, 133 beside that.
const enclosure_limits = [_]i64{ 30, 40, 50, 131 };

/// What one outer 3×3 pattern does to an inner cell at each of the nine
/// places: its squared enclosure. Inner cells never touch, so each is
/// measured alone and this is all there is.
const Hosting = [9]i64;

/// A rectangle `[x0, x1] × [y0, y1]` in units of `s`.
const Rect = [4]i64;

/// Both limits of the pair kinds; measurements are multiples of `s`.
const pair_limits = [_]i64{ 150, 200 };

/// How A's span relates to B's along one axis: inside it, ends flush
/// included; past it at both ends or past one and flush at the other; past
/// one end and short of the other.
const Rel = enum { within, spans, partial };

/// What a pair measures by the rule: null is no finding at any limit.
const Measures = struct { rule: ?i64 };

/// One kind measured on pairs of rectangles; `measure` returns null for a
/// pair the rule's words do not decide: it gets no fixture.
const PairKind = struct {
    name: []const u8,
    catalog: []const u8,
    check: []const u8,
    measure: *const fn (a: Rect, b: Rect) ?Measures,
};

const pairs = [_]PairKind{
    .{ .name = "min_extension", .catalog = "DRC-045", .check = "extension(poly, diff)", .measure = extension },
    .{ .name = "overlap", .catalog = "DRC-046", .check = "overlap(poly, diff)", .measure = overlapMeasures },
};

/// Every fixture this file generates at `depth`.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    for (&kinds) |*kind| try singleLayerInto(arena, kind, depth, out);
    try enclosuresInto(arena, depth, out);
    for (&pairs) |*kind| try rectPairsInto(arena, kind, depth, out);
}

// ---- private ----

/// Every index below `domain` at nightly; a fixed-seed sample of
/// `sample_size` at merge, drawn per kind so the kinds see different
/// patterns.
fn sample(arena: Allocator, depth: Depth, domain: u32, kind: []const u8) ![]const u32 {
    const all = try arena.alloc(u32, domain);
    for (all, 0..) |*v, i| v.* = @intCast(i);
    if (depth == .nightly) return all;
    var salt = seed;
    for (kind) |b| salt = std.math.rotl(u64, salt, 5) ^ b;
    var rng: Rng = .init(salt);
    rng.shuffle(u32, all);
    return all[0..sample_size];
}

fn bit(c: Cell) Set {
    return @as(Set, 1) << @intCast(8 * (c[1] + 1) + c[0] + 1);
}

fn has(set_: Set, c: Cell) bool {
    return c[0] >= -1 and c[0] <= 6 and c[1] >= -1 and c[1] <= 6 and set_ & bit(c) != 0;
}

/// The n×n grid and its ring.
fn padded(n: i64) Set {
    var out: Set = 0;
    var x: i64 = -1;
    while (x <= n) : (x += 1) {
        var y: i64 = -1;
        while (y <= n) : (y += 1) out |= bit(.{ x, y });
    }
    return out;
}

/// The components of `set`, 4-connected or 8-connected.
fn components(arena: Allocator, set_: Set, eight: bool) ![]const Set {
    var left = set_;
    var out: std.ArrayList(Set) = .empty;
    while (left != 0) {
        var part = left & (~left +% 1);
        while (true) {
            var grown = part | part << 1 | part >> 1 | part << 8 | part >> 8;
            if (eight) grown |= part << 7 | part >> 7 | part << 9 | part >> 9;
            grown &= left;
            if (grown == part) break;
            part = grown;
        }
        left &= ~part;
        try out.append(arena, part);
    }
    return out.items;
}

/// The gap along one axis between two cells `d` apart, the first drawn
/// `by` inside its cell: 0 where they share the axis' span.
fn gap(d: i64, by: i64) i64 {
    return if (d == 0) 0 else by + (@as(i64, @intCast(@abs(d))) - 1) * s;
}

/// Squared Euclidean distance between cell `a` (inset by `by`) and cell `b`.
fn dist2(a: Cell, b: Cell, by: i64) i64 {
    const gx = gap(a[0] - b[0], by);
    const gy = gap(a[1] - b[1], by);
    return gx * gx + gy * gy;
}

fn area(set_: Set) i64 {
    return @as(i64, @popCount(set_)) * s * s;
}

/// Squared narrowest width of a figure, in nm².
fn width2(fig: Set) i64 {
    var best: i64 = std.math.maxInt(i64);
    // Parallel edges across material: every maximal run of a row or column.
    var it: Cells = .{ .left = fig };
    while (it.next()) |c| {
        if (!has(fig, .{ c[0] - 1, c[1] })) {
            var run: i64 = 1;
            while (has(fig, .{ c[0] + run, c[1] })) run += 1;
            best = @min(best, run * s * run * s);
        }
        if (!has(fig, .{ c[0], c[1] - 1 })) {
            var run: i64 = 1;
            while (has(fig, .{ c[0], c[1] + run })) run += 1;
            best = @min(best, run * s * run * s);
        }
    }
    // Concave corners: lattice points with exactly three of the four cells
    // around them in the figure; the void points at the fourth. Lattice
    // point `(x, y)` is the bottom-left corner of cell `(x, y)` and takes its
    // bit, so shifting the figure by 1, 8 or 9 bits lines up the cell to its
    // west, south or south-west with it. A lattice point with only two
    // diagonal cells in the figure joins them, and is a concave corner of
    // each with the voids on the other diagonal: two corners at one point,
    // width 0.
    const ne = fig;
    const nw = fig << 1;
    const se = fig << 8;
    const sw = fig << 9;
    const rising = ne & ~nw & ~se & sw;
    const falling = ~ne & nw & se & ~sw;
    const corners = [4]struct { [2]i64, Set }{
        .{ .{ 1, 1 }, (~ne & nw & se & sw) | falling },
        .{ .{ -1, 1 }, (ne & ~nw & se & sw) | rising },
        .{ .{ 1, -1 }, (ne & nw & ~se & sw) | rising },
        .{ .{ -1, -1 }, (ne & nw & se & ~sw) | falling },
    };
    for (corners) |cv| for (corners) |cw| {
        const v = cv[0];
        if (cw[0][0] != -v[0] or cw[0][1] != -v[1]) continue;
        var ps: Cells = .{ .left = cv[1] };
        while (ps.next()) |p| {
            var qs: Cells = .{ .left = cw[1] };
            while (qs.next()) |q| if ((q[0] - p[0]) * v[0] <= 0 and (q[1] - p[1]) * v[1] <= 0) {
                const dx = (q[0] - p[0]) * s;
                const dy = (q[1] - p[1]) * s;
                best = @min(best, dx * dx + dy * dy);
            };
        }
    };
    return best;
}

fn minWidth(arena: Allocator, figs: []const Set, n: i64) Allocator.Error![]const i64 {
    _ = n;
    const out = try arena.alloc(i64, figs.len);
    for (figs, out) |f, *o| o.* = width2(f);
    return out;
}

fn minSpacing(arena: Allocator, figs: []const Set, n: i64) Allocator.Error![]const i64 {
    _ = n;
    var out: std.ArrayList(i64) = .empty;
    for (figs, 0..) |a, i| for (figs[i + 1 ..]) |b| {
        var cs: Cells = .{ .left = a };
        while (cs.next()) |c| {
            var ds: Cells = .{ .left = b };
            while (ds.next()) |d| try out.append(arena, dist2(c, d, 0));
        }
    };
    return out.items;
}

/// Squared narrowest gap between two cells of `fig` in one row or column
/// with none of its cells between.
fn notch2(fig: Set) ?i64 {
    var best: ?i64 = null;
    var it: Cells = .{ .left = fig };
    while (it.next()) |c| for ([_][2]i64{ .{ 1, 0 }, .{ 0, 1 } }) |d| {
        var k: i64 = 1;
        while (k < 6 and !has(fig, .{ c[0] + k * d[0], c[1] + k * d[1] })) k += 1;
        if (k < 6 and k > 1) best = @min(best orelse std.math.maxInt(i64), (k - 1) * s * (k - 1) * s);
    };
    return best;
}

fn notch(arena: Allocator, figs: []const Set, n: i64) Allocator.Error![]const i64 {
    _ = n;
    var out: std.ArrayList(i64) = .empty;
    for (figs) |f| if (notch2(f)) |v| try out.append(arena, v);
    return out.items;
}

fn minArea(arena: Allocator, figs: []const Set, n: i64) Allocator.Error![]const i64 {
    _ = n;
    const out = try arena.alloc(i64, figs.len);
    for (figs, out) |f, *o| o.* = area(f);
    return out;
}

fn minEnclosedArea(arena: Allocator, figs: []const Set, n: i64) Allocator.Error![]const i64 {
    const ring = padded(n) & ~(padded(n - 2) << 9);
    var out: std.ArrayList(i64) = .empty;
    for (figs) |f| for (try components(arena, padded(n) & ~f, false)) |hole| {
        if (hole & ring == 0) try out.append(arena, area(hole));
    };
    return out.items;
}

/// The rule id for one limit of a kind.
fn ruleId(arena: Allocator, kind: []const u8, limit: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.{d}", .{ kind, limit });
}

/// A deck on a 1 nm grid declaring `layers` from gds 68 up, with `check >=
/// <limit><unit>` once per limit.
fn deck(arena: Allocator, layers: []const []const u8, kind: []const u8, check: []const u8, unit: []const u8, limits: []const i64) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "grid 1nm\n");
    for (layers, 68..) |layer, number| try text.print(arena, "layer {s} = gds({d}, 0)\n", .{ layer, number });
    for (limits) |limit| try text.print(arena, "rule {s} {s} >= {d}{s}\n", .{ try ruleId(arena, kind, limit), check, limit, unit });
    return text.items;
}

/// A finding for a squared length under `limit`, measured floored to a nm.
fn short(d2: i64, limit: i64) ?Finding {
    return if (d2 < limit * limit) .length(std.math.sqrt(@as(u64, @intCast(d2)))) else null;
}

fn singleLayerInto(arena: Allocator, kind: *const Kind, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const text = try deck(arena, &.{"met1"}, kind.name, kind.check, kind.unit, kind.limits);
    for (try sample(arena, depth, 1 << 16, kind.name)) |bits| {
        const p: Pattern = .{ .n = 4, .bits = bits };
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "bitmap/{s}/4x4/{x:0>4}", .{ kind.name, bits }), try arena.dupe([]const u8, &.{kind.catalog}), text, harness.drc);
        try p.draw(arena, &f.layout, "met1", 0);
        const values = try kind.measure(arena, try p.figures(arena), p.n);
        const lengths = std.mem.eql(u8, kind.unit, "nm");
        for (kind.limits) |limit| {
            var found: std.ArrayList(Finding) = .empty;
            for (values) |v| {
                if (lengths) {
                    if (short(v, limit)) |fd| try found.append(arena, fd);
                } else if (v < limit) try found.append(arena, .area(v));
            }
            try f.claim(arena, .rule(try ruleId(arena, kind.name, limit), found.items));
        }
        try out.append(arena, f);
    }
}

fn hosting(arena: Allocator, outer: Pattern) !Hosting {
    const figs = try outer.figures(arena);
    var e2: Hosting = @splat(0);
    for (&e2, 0..) |*e, i| {
        const c: Cell = .{ @intCast(i % 3), @intCast(i / 3) };
        const host = for (figs) |f| (if (has(f, c)) break f) else continue;
        var best: i64 = std.math.maxInt(i64);
        var qs: Cells = .{ .left = padded(3) & ~host };
        while (qs.next()) |q| best = @min(best, dist2(c, q, inset));
        e.* = best; // the ring is outside every host
    }
    return e2;
}

fn enclosuresInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const text = try deck(arena, &.{ "met1", "via1" }, "min_enclosure", "enclosure(via1, met1)", "nm", &enclosure_limits);
    var hostings: [1 << 9]Hosting = undefined;
    for (&hostings, 0..) |*h, bits| h.* = try hosting(arena, .{ .n = 3, .bits = @intCast(bits) });
    for (try sample(arena, depth, 1 << 18, "min_enclosure")) |bits| {
        // The outer pattern is the low nine bits, the inner the high nine.
        const outer: Pattern = .{ .n = 3, .bits = bits & 0x1ff };
        const inner: Pattern = .{ .n = 3, .bits = bits >> 9 };
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "bitmap/min_enclosure/3x3/{x:0>3}_in_{x:0>3}", .{ inner.bits, outer.bits }), &.{"DRC-040"}, text, harness.drc);
        try outer.draw(arena, &f.layout, "met1", 0);
        try inner.draw(arena, &f.layout, "via1", inset);
        for (enclosure_limits) |limit| {
            var found: std.ArrayList(Finding) = .empty;
            for (0..9) |i| if (inner.bits >> @intCast(i) & 1 == 1) {
                if (short(hostings[bits & 0x1ff][i], limit)) |fd| try found.append(arena, fd);
            };
            try f.claim(arena, .rule(try ruleId(arena, "min_enclosure", limit), found.items));
        }
        try out.append(arena, f);
    }
}

/// Every rectangle with corners on the lattice `0..=4`: 100.
fn rects() [100]Rect {
    var spans: [10][2]i64 = undefined;
    var k: usize = 0;
    for (0..5) |lo| for (lo + 1..5) |hi| {
        spans[k] = .{ @intCast(lo), @intCast(hi) };
        k += 1;
    };
    var out: [100]Rect = undefined;
    for (spans, 0..) |x, i| for (spans, 0..) |y, j| {
        out[i * 10 + j] = .{ x[0], y[0], x[1], y[1] };
    };
    return out;
}

fn rel(a0: i64, a1: i64, b0: i64, b1: i64) Rel {
    if (a0 >= b0 and a1 <= b1) return .within;
    if (a0 <= b0 and a1 >= b1) return .spans;
    return .partial;
}

/// `extension(A, B)`: "A not extending past B by the limit, as poly past
/// diffusion", on one rectangle each. Along each axis A's span is within
/// B's (equal included), strictly spans it, or is partly past one end.
/// - Apart or touching only (no shared area): nothing; there is no gate to
///   extend past (F41).
/// - A within B on both axes: 0, it extends past nothing.
/// - A spans one axis and lies within the other, not equal to it (a gate):
///   the smaller protrusion along the spanned axis, a flush end measuring
///   0. With the other axis equal it is undecided which way A runs.
/// - A partly past B on one axis and within it on the other: 0, A ends
///   inside B.
/// - A spans both, protruding on all four sides: the smallest protrusion.
/// - Everything else (a corner overlap, partly past one axis and spanning
///   the other, spanning both with a flush side): undecided.
fn extension(a: Rect, b: Rect) ?Measures {
    const protrusions = [4]i64{ b[0] - a[0], b[1] - a[1], a[2] - b[2], a[3] - b[3] };
    const overlaps = a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3];
    if (!overlaps) return .{ .rule = null };
    const rx = rel(a[0], a[2], b[0], b[2]);
    const ry = rel(a[1], a[3], b[1], b[3]);
    const equal_x = a[0] == b[0] and a[2] == b[2];
    const equal_y = a[1] == b[1] and a[3] == b[3];
    const units: i64 = if ((rx != .spans and ry == .within) or (rx == .within and ry == .partial))
        0
    else if (rx == .spans and ry == .within and !equal_y)
        @min(protrusions[0], protrusions[2])
    else if (rx == .within and ry == .spans and !equal_x)
        @min(protrusions[1], protrusions[3])
    else if (rx == .spans and ry == .spans and std.mem.allEqual(bool, &.{ protrusions[0] > 0, protrusions[1] > 0, protrusions[2] > 0, protrusions[3] > 0 }, true))
        std.mem.min(i64, &protrusions)
    else
        return null;
    return .{ .rule = units * s };
}

/// `overlap(A, B)`: "A and B overlapping by less than the limit", on one
/// rectangle each: the shorter side of their shared area; shapes sharing
/// no area, touching included, do not overlap and are not measured.
fn overlapMeasures(a: Rect, b: Rect) ?Measures {
    const ix = @min(a[2], b[2]) - @max(a[0], b[0]);
    const iy = @min(a[3], b[3]) - @max(a[1], b[1]);
    return .{ .rule = if (ix > 0 and iy > 0) @min(ix, iy) * s else null };
}

/// Every pair of rectangles the rule decides, or a sample of them.
fn rectPairsInto(arena: Allocator, kind: *const PairKind, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const text = try deck(arena, &.{ "poly", "diff" }, kind.name, kind.check, "nm", &pair_limits);
    const all = rects();
    for (try sample(arena, depth, all.len * all.len, kind.name)) |i| {
        const a = all[i / all.len];
        const b = all[i % all.len];
        const m = kind.measure(a, b) orelse continue;
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "bitmap/{s}/a{d}{d}{d}{d}_b{d}{d}{d}{d}", .{ kind.name, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3] }), try arena.dupe([]const u8, &.{kind.catalog}), text, harness.drc);
        try f.layout.rect(arena, "poly", a[0] * s, a[1] * s, a[2] * s, a[3] * s);
        try f.layout.rect(arena, "diff", b[0] * s, b[1] * s, b[2] * s, b[3] * s);
        for (pair_limits) |limit| {
            const found: ?Finding = if (m.rule) |v| short(v * v, limit) else null;
            try f.claim(arena, .rule(try ruleId(arena, kind.name, limit), if (found) |fd| &.{fd} else &.{}));
        }
        try out.append(arena, f);
    }
}

test "every bitmap fixture agrees with the cell oracle" {
    // Oracle: the bitmap reference DRC above, written from each rule kind's
    // doc comment alone over a fixed-seed sample of every pattern domain.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}

test "the cell oracle measures the stated examples" {
    // Oracle: the module doc's own examples: `.#.|#.#` (one figure joined at
    // corners) has a notch of 100 and a width of 0 at its corner contacts;
    // a 3×3 ring closed only at its corners encloses a hole of one cell.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Rows bottom up: `#.#` at y = 0, `.#.` at y = 1.
    const vee: Pattern = .{ .n = 3, .bits = 0b000_010_101 };
    const figs = try vee.figures(a);
    try testing.expectEqual(1, figs.len);
    try testing.expectEqual(@as(?i64, 100 * 100), notch2(figs[0]));
    try testing.expectEqual(0, width2(figs[0]));
    // A diamond ring of four cells around the centre, joined at corners.
    const ring: Pattern = .{ .n = 3, .bits = 0b010_101_010 };
    try testing.expectEqualSlices(i64, &.{s * s}, try minEnclosedArea(a, try ring.figures(a), 3));
}
