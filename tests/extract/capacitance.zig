//! The field solve against closed forms and the laws a Maxwell capacitance
//! matrix obeys (PEX-003, PEX-005). Ported from the field-solver tests of
//! tests/exhaustive/pex.rs on its `COARSE` stack (fixture.zig): what those
//! tests read through a deck and the engine is solved here directly.
//!
//! Tolerances: `same_field`, `1e-8` relative, one field solved twice, moved
//! by a symmetry or scaled, two orders above the solve's own `1e-10`
//! residual; `exact`, `1e-9`, closed form against closed form. Thomson's
//! principle bounds (a flux tube's capacitance is a lower bound) and the
//! monotone laws are inequalities, held exactly.
//!
//! Contents: helpers `ff`, `lateralFf`, `interlayerFf`, `groundFf`, `pairFf`,
//! `relative`, `parallel`, `transformed`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const fixture = @import("fixture.zig");
const Box = fixture.Box;
const Case = fixture.Case;
const Rows = fixture.Rows;
const capacitance = extract.capacitance;
const gpa = testing.allocator;

const same_field = 1e-8;

const exact = 1e-9;

/// ε₀ in aF/µm (CODATA 2018), the unit of the deck's capacitance coefficients.
const epsilon0_af_per_um = 8.854_187_812_8;

/// The four conductors of the Maxwell-matrix law: two parallel `m1` bars,
/// an `m2` bar crossing both, and an `m1` square beside them.
const four_conductors = parallel(0, 3_000, 500, 500, 0) ++ [_]Box{
    .{ .layer = 2, .net = 2, .r = .{ 1_250, -500, 1_750, 2_000 } },
    .{ .layer = 0, .net = 3, .r = .{ 4_500, 0, 5_500, 1_000 } },
};

/// The three conductors the invariance laws solve: two parallel `m1` bars,
/// one slid along the other, and an `m2` bar crossing both.
const three_conductors = parallel(0, 3_000, 500, 500, 500) ++ [_]Box{
    .{ .layer = 2, .net = 2, .r = .{ 1_000, -500, 1_500, 2_000 } },
};

// ---- private ----

/// Two parallel bars on `layer`, `A` (net 0) below and `B` (net 1) above,
/// each `length` by `width`, a `gap` apart, `B` slid along x by `shift`.
fn parallel(layer: u16, length: i64, width: i64, gap: i64, shift: i64) [2]Box {
    return .{
        .{ .layer = layer, .net = 0, .r = .{ 0, 0, length, width } },
        .{ .layer = layer, .net = 1, .r = .{ shift, width + gap, shift + length, 2 * width + gap } },
    };
}

/// The field-solved Maxwell matrix of every net of `boxes`, in fF.
fn ff(boxes: []const Box, rows: *const Rows, out: []f64) !capacitance.Accuracy {
    var c = try Case.init(boxes, &.{}, 3);
    defer c.deinit();
    const n = std.math.sqrt(out.len);
    var selected: [8]u32 = undefined;
    for (selected[0..n], 0..) |*s, i| s.* = @intCast(i);
    return fixture.solveFf(&c, rows, selected[0..n], out);
}

/// `ε₀ εr t · L / S` for two facing sidewalls on one layer.
fn lateralFf(row: usize, run: f64, gap: f64) f64 {
    return epsilon0_af_per_um * fixture.coarse.k[row] * fixture.coarse.thickness[row] / 1e3 * run / gap / 1e3;
}

/// `ε₀ εr · A / d` for overlapping plates, `d` from the top of `m1` to the
/// bottom of `m2`.
fn interlayerFf(area_nm2: f64) f64 {
    const r = fixture.coarse;
    const gap_um = (r.height[2] - r.height[0] - r.thickness[0]) / 1e3;
    return epsilon0_af_per_um * r.k[0] * area_nm2 / 1e6 / gap_um / 1e3;
}

/// `Ca · A + Cf · P`, `A` in nm² and `P` in nm, from `rows`' row `row`.
fn groundFf(rows: *const Rows, row: usize, area: f64, perimeter: f64) f64 {
    return (rows.area[row] * area / 1e6 + rows.fringe[row] * perimeter / 1e3) / 1e3;
}

/// Two conductors' capacitance to each other alone, charged `±Q`, from their
/// 2 × 2 Maxwell block: what Thomson's principle bounds below by any flux
/// tube between them.
fn pairFf(c: [4]f64) f64 {
    return (c[0] * c[3] - c[1] * c[2]) / (c[0] + c[3] + c[1] + c[2]);
}

fn relative(a: f64, b: f64) f64 {
    return @abs(a - b) / @max(@max(@abs(a), @abs(b)), 1e-300);
}

/// `boxes` under symmetry `s` of the square (bit 0 mirrors x, bit 1 mirrors
/// y, bit 2 swaps the axes), then moved by `(dx, dy)`.
fn transformed(boxes: []const Box, s: u3, dx: i64, dy: i64, out: []Box) void {
    for (boxes, out) |b, *o| {
        var lo = [2]i64{ b.r[0], b.r[1] };
        var hi = [2]i64{ b.r[2], b.r[3] };
        if (s & 1 != 0) {
            const t = lo[0];
            lo[0] = -hi[0];
            hi[0] = -t;
        }
        if (s & 2 != 0) {
            const t = lo[1];
            lo[1] = -hi[1];
            hi[1] = -t;
        }
        if (s & 4 != 0) {
            std.mem.swap(i64, &lo[0], &lo[1]);
            std.mem.swap(i64, &hi[0], &hi[1]);
        }
        o.* = .{ .layer = b.layer, .net = b.net, .r = .{ lo[0] + dx, lo[1] + dy, hi[0] + dx, hi[1] + dy } };
    }
}

test "a field solved capacitance matrix is a maxwell matrix" {
    // Oracle: law. A Maxwell capacitance matrix is symmetric (to the solve,
    // `same_field`), has a positive diagonal and negative off-diagonals, and
    // is strictly diagonally dominant: every row sums to a positive ground
    // capacitance.
    var c: [16]f64 = undefined;
    _ = try ff(&four_conductors, &fixture.coarse, &c);
    for (0..4) |i| {
        try testing.expect(c[i * 4 + i] > 0.0);
        var sum: f64 = 0.0;
        for (0..4) |j| {
            sum += c[i * 4 + j];
            if (j == i) continue;
            try testing.expect(c[i * 4 + j] < 0.0);
            try testing.expect(relative(c[i * 4 + j], c[j * 4 + i]) <= same_field);
        }
        try testing.expect(sum > 0.0);
    }
}

test "field solved coupling falls as the gap grows" {
    // Oracle: law. Coupling falls strictly as the gap grows, and the pair
    // capacitance is bounded below by the sidewall flux tube `ε₀εr·t·L/S`.
    var previous = std.math.inf(f64);
    for ([_]i64{ 250, 500, 1_000, 2_000, 4_000 }) |gap| {
        var c: [4]f64 = undefined;
        _ = try ff(&parallel(0, 6_000, 1_000, gap, 0), &fixture.coarse, &c);
        const coupling = -c[1];
        try testing.expect(coupling < previous);
        try testing.expect(pairFf(c) >= lateralFf(0, 6_000, @floatFromInt(gap)));
        previous = coupling;
    }
}

test "field solved coupling grows with the overlap" {
    // Oracle: law. Coupling grows strictly with the overlap, and the pair
    // capacitance is bounded below by the parallel plate `ε₀εr·A/d` over it.
    var previous: f64 = 0.0;
    for ([_]i64{ 1_000, 2_000, 4_000, 8_000 }) |overlap| {
        const boxes = [_]Box{
            .{ .layer = 0, .net = 0, .r = .{ 0, 0, 8_000, 1_000 } },
            .{ .layer = 2, .net = 1, .r = .{ 8_000 - overlap, 0, 16_000 - overlap, 1_000 } },
        };
        var c: [4]f64 = undefined;
        _ = try ff(&boxes, &fixture.coarse, &c);
        const coupling = -c[1];
        try testing.expect(coupling > previous);
        try testing.expect(pairFf(c) >= interlayerFf(@floatFromInt(overlap * 1_000)));
        previous = coupling;
    }
}

test "a field solve is invariant under symmetry and covariant under scale" {
    // Oracle: metamorphic relations. Every symmetry of the square gives the
    // same matrix, and doubling every length (layout and stack) doubles
    // every capacitance in a homogeneous dielectric, to `same_field`.
    var reference: [9]f64 = undefined;
    _ = try ff(&three_conductors, &fixture.coarse, &reference);
    var moved: [3]Box = undefined;
    for (1..8) |s| {
        transformed(&three_conductors, @intCast(s), 0, 0, &moved);
        var c: [9]f64 = undefined;
        _ = try ff(&moved, &fixture.coarse, &c);
        for (c, reference) |got, want| try testing.expect(relative(got, want) <= same_field);
    }
    var doubled: [3]Box = three_conductors;
    for (&doubled) |*b| {
        for (&b.r) |*v| v.* *= 2;
    }
    const scaled = fixture.coarse.scaled(2.0);
    var c: [9]f64 = undefined;
    _ = try ff(&doubled, &scaled, &c);
    for (c, reference) |got, want| try testing.expect(relative(got, 2.0 * want) <= same_field);
}

test "a field solve is invariant under translation" {
    // Oracle: metamorphic relation. Translating the layout by 1 mm, or far
    // into the negative quadrant, leaves the matrix unchanged: a face's
    // panel count once took round-off from absolute coordinates (F46).
    var reference: [9]f64 = undefined;
    _ = try ff(&three_conductors, &fixture.coarse, &reference);
    var moved: [3]Box = undefined;
    for ([_][2]i64{ .{ 1_000_000, 0 }, .{ -1_234_567, 987_654 } }) |d| {
        transformed(&three_conductors, 0, d[0], d[1], &moved);
        var c: [9]f64 = undefined;
        _ = try ff(&moved, &fixture.coarse, &c);
        for (c, reference) |got, want| try testing.expect(relative(got, want) <= same_field);
    }
}

test "a junction is its closed form beside the field solved metal" {
    // Oracle: closed form (F73). A net of an `m2` bar and an `m1` junction
    // (on the substrate) field-solves its metal and adds the junction's
    // `Ca·A + Cf·P`: its ground capacitance is the metal's solved alone plus
    // that, to round-off.
    const metal = [_]Box{.{ .layer = 2, .net = 0, .r = .{ 4_000, 0, 9_000, 1_000 } }};
    const joined = metal ++ [_]Box{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 5_000, 1_000 } }};
    var alone: [1]f64 = undefined;
    _ = try ff(&metal, &fixture.junction, &alone);
    var both: [1]f64 = undefined;
    _ = try ff(&joined, &fixture.junction, &both);
    const want = groundFf(&fixture.junction, 0, 5e6, 12_000.0);
    try testing.expect(relative(both[0] - alone[0], want) <= exact);
}

test "a junction only net couples by exactly zero" {
    // Oracle: construct-from-answer (F80). A net of junctions only has no
    // panels, so it shares no field with another net: their coupling is
    // exactly zero, a positive zero.
    const boxes = [_]Box{
        .{ .layer = 0, .net = 0, .r = .{ 0, 0, 5_000, 1_000 } },
        .{ .layer = 2, .net = 1, .r = .{ 0, 3_000, 5_000, 4_000 } },
    };
    var c: [4]f64 = undefined;
    _ = try ff(&boxes, &fixture.junction, &c);
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(c[1])));
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(c[2])));
    try testing.expect(c[0] > 0.0 and c[3] > 0.0);
}

test "an unmeshable net is refused by its layer" {
    // Oracle: docs/deck.md, Parasitic stack: a row with no dielectric gives
    // a layer above the substrate the field solve refuses, naming that layer.
    var rows = fixture.coarse;
    rows.k[0] = 0.0;
    var c = try Case.init(&.{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 4_000, 1_000 } }}, &.{}, 3);
    defer c.deinit();
    var matrix: capacitance.CapMatrix = .empty;
    defer matrix.deinit(gpa);
    var diag: capacitance.Diagnostic = .{ .layer = @fromBackingInt(7) };
    try testing.expectError(error.MissingThickness, capacitance.extractInto(gpa, fixture.device, c.problem(&rows), &.{0}, &matrix, &diag));
    try testing.expectEqual(0, @backingInt(diag.layer));
}

test "a global layer carries nothing of the field" {
    // Oracle: differential (F79): docs/deck.md says a global layer carries no
    // parasitics and needs no `pex` row, so a net with a shape on one (layer
    // 3, past the stack) solves to the bits of the same net without it.
    const metal = [_]Box{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 3_000, 1_000 } }};
    const tied = metal ++ [_]Box{.{ .layer = 3, .net = 0, .r = .{ -500, -500, 3_500, 1_500 } }};
    var plain = try Case.init(&metal, &.{}, 4);
    defer plain.deinit();
    var with = try Case.init(&tied, &.{}, 4);
    defer with.deinit();
    var want: capacitance.CapMatrix = .empty;
    defer want.deinit(gpa);
    var got: capacitance.CapMatrix = .empty;
    defer got.deinit(gpa);
    var diag: capacitance.Diagnostic = .{};
    var problem = plain.problem(&fixture.coarse);
    problem.global = &.{@fromBackingInt(3)};
    _ = try capacitance.extractInto(gpa, fixture.device, problem, &.{0}, &want, &diag);
    problem = with.problem(&fixture.coarse);
    problem.global = &.{@fromBackingInt(3)};
    _ = try capacitance.extractInto(gpa, fixture.device, problem, &.{0}, &got, &diag);
    try testing.expectEqualSlices(u64, @ptrCast(want.value.items), @ptrCast(got.value.items));
}

test "stratified coupling lies between its two uniform stacks" {
    // Oracle: laws. Capacitance grows with any permittivity (Thomson's
    // principle), so two `m1` bars' coupling in a stack 7 up to `m1`'s top
    // and 3.9 over it lies strictly between the all-3.9 and all-7 stacks';
    // the solve is reciprocal within what its interfaces allow, and the
    // matrix reported is symmetric.
    const pair = parallel(0, 3_000, 500, 500, 0);
    var c: [4]f64 = undefined;
    _ = try ff(&pair, &fixture.coarse.uniform(3.9), &c);
    const low = -c[1];
    _ = try ff(&pair, &fixture.coarse.uniform(7.0), &c);
    const high = -c[1];
    var stratified = fixture.coarse.uniform(3.9);
    stratified.k[0] = 7.0;
    const accuracy = try ff(&pair, &stratified, &c);
    try testing.expect(low < -c[1] and -c[1] < high);
    try testing.expect(accuracy.asymmetry < capacitance.stratified_reciprocity);
    try testing.expectEqual(@as(u64, @bitCast(c[1])), @as(u64, @bitCast(c[2])));
}
