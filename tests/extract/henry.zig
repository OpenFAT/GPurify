//! The inductance solve: drawn rectangles in, per-net L and R and the
//! mutual inductance between nets out. Ported from
//! crates/extract/tests/field/bridge.rs.
//!
//! A single bar has a closed-form self inductance (Grover/Rosa,
//! `filament.selfInductanceBar`), two parallel bars Grover's mutual one, and
//! a bend's corner Hall's conformal-map value, each reached through the
//! solver's independent path from geometry to port impedance.
//!
//! Contents: helpers `solveL`, `viaPair`, `viaRows`, `sideBySide`; then the tests.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const extract = @import("extract");
const fixture = @import("fixture.zig");
const Box = fixture.Box;
const Case = fixture.Case;
const Rows = fixture.Rows;
const henry = extract.henry;
const selfInductanceBar = extract.filament.selfInductanceBar;
const gpa = testing.allocator;

/// The cut layer joining `m1` (layer 0) to `m2` (layer 2).
const vias: extract.Vias = .{ .cut = &.{@fromBackingInt(1)}, .connects = &.{.{ @fromBackingInt(0), @fromBackingInt(2) }} };

/// One 10 x 1 um bar on layer 0, net 0.
const one_bar = [_]Box{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 10_000, 1_000 } }};

// ---- private ----

/// The inductance solve of `selected` over `boxes` and `polygons`.
fn solveL(boxes: []const Box, polygons: []const fixture.Shape, layers: u16, rows: *const Rows, joins: extract.Vias, selected: []const u32, out: *henry.InductMatrix, refusal: *henry.Refusal) henry.Error!void {
    var c = Case.init(boxes, polygons, layers) catch return error.OutOfMemory;
    defer c.deinit();
    const problem: henry.Problem = .{ .store = &c.store, .nets = &c.nets, .global = &.{}, .vias = joins, .stack = rows.stack(), .grid = fixture.grid };
    try henry.extractInductanceInto(gpa, 4, problem, selected, out, refusal);
}

/// An `m1` bar `[0, 5] x [0, 1]` um and an `m2` bar `[4, 9] x [0, 1]`, net
/// 0, and `cuts` on layer 1 (on no net, as check's extraction leaves cuts).
fn viaPair(cuts: []const [4]i64, out: []Box) []Box {
    out[0] = .{ .layer = 0, .net = 0, .r = .{ 0, 0, 5_000, 1_000 } };
    out[1] = .{ .layer = 2, .net = 0, .r = .{ 4_000, 0, 9_000, 1_000 } };
    for (cuts, out[2..][0..cuts.len]) |r, *b| b.* = .{ .layer = 1, .net = extract.none, .r = r };
    return out[0 .. 2 + cuts.len];
}

/// `m1` at 0.1 ohm/sq, cuts at 5 ohm each, `m2` at 0.08 ohm/sq, 100 nm
/// thick and 100 nm apart.
fn viaRows() Rows {
    var r = fixture.uniformRows(1.0, 0.25);
    r.height = .{ 300, 400, 500 };
    r.sheet = .{ 0.1, 5.0, 0.08 };
    return r;
}

/// Two 20 x 1 um bars along x, nets 0 and 1, their centre lines `pitch` nm
/// apart.
fn sideBySide(pitch: i64) [2]Box {
    return .{
        .{ .layer = 0, .net = 0, .r = .{ 0, 0, 20_000, 1_000 } },
        .{ .layer = 0, .net = 1, .r = .{ 0, pitch, 20_000, pitch + 1_000 } },
    };
}

fn solvePair(bars: [2]Box, out: *henry.InductMatrix) !void {
    var refusal: henry.Refusal = .{};
    try solveL(&bars, &.{}, 1, &fixture.uniformRows(1.0, 0.25), .{ .cut = &.{}, .connects = &.{} }, &.{ 0, 1 }, out, &refusal);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, out.net.items);
    try testing.expectEqual(4, out.m_henry.items.len);
}

test "a single bar matches the grover closed form" {
    // Oracle: closed form. One bar is one filament, so its port inductance
    // is the Grover/Rosa self inductance of a 10 x 1 um x 100 nm bar, within
    // 5 %, and its resistance the sheet's `0.1 · 10 = 1` ohm at DC (one
    // filament, no skin subdivision), to 1e-6.
    var out: henry.InductMatrix = .empty;
    defer out.deinit(gpa);
    var refusal: henry.Refusal = .{};
    try solveL(&one_bar, &.{}, 1, &fixture.uniformRows(1.0, 0.25), .{ .cut = &.{}, .connects = &.{} }, &.{0}, &out, &refusal);
    try testing.expectEqualSlices(u32, &.{0}, out.net.items);
    const want = selfInductanceBar(10e-6, 1e-6, 0.1e-6);
    try testing.expect(@abs((out.l_henry.items[0] - want) / want) < 0.05);
    try testing.expect(@abs(out.r_ohm.items[0] - 1.0) < 1e-6);
}

test "an l reads its corner crowded however it is drawn" {
    // Oracle: closed form (Hall, Thin Solid Films 1(4), 1967: a right-angle
    // bend's corner square counts 0.559 squares). An L of legs 20 and 16 um,
    // 1 um wide, is 19 + 15 squares of leg and a corner, however it is drawn
    // (one polygon, two abutting rectangles, two bars overlapping at the
    // corner: one region, one grid, the same bits); the four-cell grid reads
    // the corner above Hall's value and below the centre line's one square.
    // `L` is Grover's for each leg along the centre line, 19.5 and 15.5 um,
    // to 1 %.
    const want_l = selfInductanceBar(19.5e-6, 1e-6, 0.1e-6) + selfInductanceBar(15.5e-6, 1e-6, 0.1e-6);
    const polygon = [_]fixture.Shape{.{ .layer = 0, .net = 0, .xs = &.{ 0, 20_000, 20_000, 19_000, 19_000, 0 }, .ys = &.{ 0, 0, 16_000, 16_000, 1_000, 1_000 } }};
    const abutting = [_]Box{ .{ .layer = 0, .net = 0, .r = .{ 0, 0, 20_000, 1_000 } }, .{ .layer = 0, .net = 0, .r = .{ 19_000, 1_000, 20_000, 16_000 } } };
    const overlapping = [_]Box{ .{ .layer = 0, .net = 0, .r = .{ 0, 0, 20_000, 1_000 } }, .{ .layer = 0, .net = 0, .r = .{ 19_000, 0, 20_000, 16_000 } } };
    const drawings = [_]struct { []const Box, []const fixture.Shape }{ .{ &.{}, &polygon }, .{ &abutting, &.{} }, .{ &overlapping, &.{} } };
    var first: ?f64 = null;
    for (drawings) |d| {
        var out: henry.InductMatrix = .empty;
        defer out.deinit(gpa);
        var refusal: henry.Refusal = .{};
        try solveL(d[0], d[1], 1, &fixture.uniformRows(1.0, 0.25), .{ .cut = &.{}, .connects = &.{} }, &.{0}, &out, &refusal);
        const r = out.r_ohm.items[0];
        const corner = r / 0.1 - 34.0;
        try testing.expect(corner > 0.559 and corner < 0.66);
        const same = first orelse r;
        first = same;
        try testing.expect(@abs((r - same) / same) < 1e-9);
        try testing.expect(@abs((out.l_henry.items[0] - want_l) / want_l) < 1e-2);
    }
}

test "a via joins the layers it connects" {
    // Oracle: definition (F23). An `m1` bar and an `m2` bar joined by one
    // cut at x = 4.2 um are one circuit from x = 0 to x = 9 um: 4.2 squares
    // of `m1`, the cut, 4.8 squares of `m2`, `0.42 + 5 + 0.384` ohm; two cuts
    // across the bar conduct in parallel, `0.42 + 2.5 + 0.384`; to 1e-9.
    const cases = [_]struct { []const [4]i64, f64 }{
        .{ &.{.{ 4_100, 100, 4_300, 300 }}, 0.42 + 5.0 + 0.384 },
        .{ &.{ .{ 4_100, 100, 4_300, 300 }, .{ 4_100, 600, 4_300, 800 } }, 0.42 + 2.5 + 0.384 },
    };
    for (cases) |case| {
        var buffer: [4]Box = undefined;
        var out: henry.InductMatrix = .empty;
        defer out.deinit(gpa);
        var refusal: henry.Refusal = .{};
        try solveL(viaPair(case[0], &buffer), &.{}, 3, &viaRows(), vias, &.{0}, &out, &refusal);
        try testing.expect(@abs((out.r_ohm.items[0] - case[1]) / case[1]) < 1e-9);
        try testing.expect(out.l_henry.items[0] > 0.0);
    }
}

test "a net that is not one circuit is refused" {
    // Oracle: definition (F23). Two bars meeting only at a corner are one
    // net, but no current crosses a point: refused as `Disconnected`, not
    // read as 0 H and 0 ohm. A via layer with no resistance per cut is
    // refused by name.
    const corner = [_]Box{ .{ .layer = 0, .net = 0, .r = .{ 0, 0, 5_000, 1_000 } }, .{ .layer = 0, .net = 0, .r = .{ 5_000, 1_000, 10_000, 2_000 } } };
    var out: henry.InductMatrix = .empty;
    defer out.deinit(gpa);
    var refusal: henry.Refusal = .{};
    try testing.expectError(error.Disconnected, solveL(&corner, &.{}, 1, &fixture.uniformRows(1.0, 0.25), .{ .cut = &.{}, .connects = &.{} }, &.{0}, &out, &refusal));
    try testing.expectEqual(0, refusal.net);
    var buffer: [3]Box = undefined;
    var rows = viaRows();
    rows.sheet[1] = 0.0;
    try testing.expectError(error.NoSheetResistance, solveL(viaPair(&.{.{ 4_100, 100, 4_300, 300 }}, &buffer), &.{}, 3, &rows, vias, &.{0}, &out, &refusal));
    try testing.expectEqual(1, refusal.layer);
}

test "two extractions are bit identical" {
    // Oracle: law. Two runs over the same geometry are the same bits.
    var first: henry.InductMatrix = .empty;
    defer first.deinit(gpa);
    var second: henry.InductMatrix = .empty;
    defer second.deinit(gpa);
    var refusal: henry.Refusal = .{};
    for ([_]*henry.InductMatrix{ &first, &second }) |out| try solveL(&one_bar, &.{}, 1, &fixture.uniformRows(1.0, 0.25), .{ .cut = &.{}, .connects = &.{} }, &.{0}, out, &refusal);
    try testing.expectEqualSlices(u64, @ptrCast(first.l_henry.items), @ptrCast(second.l_henry.items));
    try testing.expectEqualSlices(u64, @ptrCast(first.r_ohm.items), @ptrCast(second.r_ohm.items));
}

test "a layer with no sheet resistance is refused by name" {
    // Oracle: construct-from-answer, on the refusal. A layer with no sheet
    // resistance has no conductivity: a net on it is refused naming it, not
    // skipped.
    var rows = fixture.uniformRows(1.0, 0.25);
    rows.sheet[0] = 0.0;
    var out: henry.InductMatrix = .empty;
    defer out.deinit(gpa);
    var refusal: henry.Refusal = .{ .layer = 9 };
    try testing.expectError(error.NoSheetResistance, solveL(&one_bar, &.{}, 1, &rows, .{ .cut = &.{}, .connects = &.{} }, &.{0}, &out, &refusal));
    try testing.expectEqual(0, refusal.layer);
}

test "two parallel bars have grover's mutual inductance" {
    // Oracle: closed form (Grover, Inductance Calculations, 1946, ch. 6: two
    // equal parallel filaments `l` long, `d` apart,
    // `M = (µ₀/2π) l [asinh(l/d) − √(1 + d²/l²) + d/l]`). Bars 20 um long,
    // 1 um wide, 12 um apart: their geometric-mean distance moves `M` by
    // 5e-4, inside the 1e-3 allowed, on both off-diagonal entries.
    var out: henry.InductMatrix = .empty;
    defer out.deinit(gpa);
    try solvePair(sideBySide(12_000), &out);
    const l: f64 = 20e-6;
    const d: f64 = 12e-6;
    const want = 2e-7 * l * (std.math.asinh(l / d) - @sqrt(1.0 + (d / l) * (d / l)) + d / l);
    for ([_]f64{ out.m_henry.items[1], out.m_henry.items[2] }) |got| try testing.expect(@abs((got - want) / want) < 1e-3);
}

test "the inductance matrix is reciprocal and an open neighbour changes nothing" {
    // Oracle: laws. The port impedance matrix of a reciprocal network is
    // symmetric, its diagonal each net's own `L`; an open neighbour carries
    // no current, so each bar's `L` and `R` are what it reads alone, to
    // round-off; and the pair's matrix is positive definite, `M² < L₀L₁`.
    var pair: henry.InductMatrix = .empty;
    defer pair.deinit(gpa);
    try solvePair(sideBySide(2_000), &pair);
    const m = pair.m_henry.items;
    const l = pair.l_henry.items;
    try testing.expect(@abs(m[1] - m[2]) <= 1e-9 * @sqrt(l[0] * l[1]));
    try testing.expect(m[1] * m[1] < l[0] * l[1]);
    try testing.expectEqual(@as(u64, @bitCast(l[0])), @as(u64, @bitCast(m[0])));
    try testing.expectEqual(@as(u64, @bitCast(l[1])), @as(u64, @bitCast(m[3])));
    const bars = sideBySide(2_000);
    for (0..2) |net| {
        var alone: henry.InductMatrix = .empty;
        defer alone.deinit(gpa);
        var refusal: henry.Refusal = .{};
        try solveL(&bars, &.{}, 1, &fixture.uniformRows(1.0, 0.25), .{ .cut = &.{}, .connects = &.{} }, &.{@intCast(net)}, &alone, &refusal);
        try testing.expect(@abs((l[net] - alone.l_henry.items[0]) / alone.l_henry.items[0]) < 1e-9);
        try testing.expect(@abs((pair.r_ohm.items[net] - alone.r_ohm.items[0]) / alone.r_ohm.items[0]) < 1e-9);
    }
}

test "mutual inductance falls with distance and vanishes across" {
    // Oracle: laws. Parallel bars' mutual inductance is positive (both ports
    // run the same way along x) and falls as they move apart; perpendicular
    // bars have none, the Neumann integrand carrying `û₁ · û₂ = 0`.
    var last = std.math.inf(f64);
    for ([_]i64{ 2_000, 3_000, 4_000, 8_000, 12_000, 16_000 }) |pitch| {
        var out: henry.InductMatrix = .empty;
        defer out.deinit(gpa);
        try solvePair(sideBySide(pitch), &out);
        const m = out.m_henry.items[1];
        try testing.expect(m > 0.0 and m < last);
        last = m;
    }
    var across: henry.InductMatrix = .empty;
    defer across.deinit(gpa);
    try solvePair(.{ .{ .layer = 0, .net = 0, .r = .{ 0, 0, 20_000, 1_000 } }, .{ .layer = 0, .net = 1, .r = .{ 25_000, -10_000, 26_000, 10_000 } } }, &across);
    try testing.expect(@abs(across.m_henry.items[1]) <= 1e-12 * @sqrt(across.l_henry.items[0] * across.l_henry.items[1]));
}
