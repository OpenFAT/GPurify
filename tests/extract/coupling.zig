//! Coupling and extraction types against tests/exhaustive/pex.rs (PEX-003,
//! PEX-008, PEX-009): the analytical lateral and interlayer coupling closed
//! forms under every symmetry, the `extraction` fixtures, and `rc`
//! qualified against `rcc`. The Rust tests ran the engine on a deck; here
//! the same `PARAMS` rows feed `analytical.extractInto` then `reduce`
//! directly, nets stated with the shapes (construct-from-answer).
//!
//! Contents: `exact`; helpers `parallel`, `extracted`, `totalOn`,
//! `couplingFf`, `relative`, `lateralFf`, `interlayerFf`; then the tests.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const extract = @import("extract");
const fixture = @import("fixture.zig");
const Poly = fixture.Poly;
const p = fixture.params;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;

/// Closed form against closed form: round-off only.
const exact: f64 = 1e-9;

const vias: extract.Vias = .{ .cut = &.{@fromBackingInt(1)}, .connects = &.{.{ @fromBackingInt(0), @fromBackingInt(2) }} };

// ---- private ----

/// Two parallel bars' rings, the lower one's first, each `length ×
/// width`, `gap` apart, the upper slid along x by `shift`.
fn parallel(length: i64, width: i64, gap: i64, shift: i64) [2][4][2]i64 {
    const y = width + gap;
    return .{
        .{ .{ 0, 0 }, .{ length, 0 }, .{ length, width }, .{ 0, width } },
        .{ .{ shift, y }, .{ shift + length, y }, .{ shift + length, y + width }, .{ shift, y + width } },
    };
}

/// The network of `polys` placed by `s` and `d`, reduced to `extraction`.
fn extracted(polys: []const Poly, s: fixture.Symmetry, d: [2]i64, extraction: ingest.deck.Extraction, out: *ParasiticNetwork) !void {
    var c = try fixture.placed(polys, s, d);
    defer c.deinit();
    var refusal: extract.analytical.Refusal = .{};
    const problem: extract.analytical.Problem = .{ .store = &c.store, .nets = &c.nets, .conductors = &.{ @fromBackingInt(0), @fromBackingInt(2) }, .global = &.{}, .vias = vias, .stack = p.stack(), .halo = 10.0, .grid = fixture.grid };
    try extract.analytical.extractInto(gpa, problem, out, &refusal);
    try extract.reduce.reduce(gpa, out, extraction);
}

/// The total of `kind` over the elements whose near node is on `net`.
fn totalOn(n: *const ParasiticNetwork, net: u32, kind: extract.network.Kind) f64 {
    var total: f64 = 0.0;
    for (n.from.items, n.kind.items, n.value.items) |from, k, v| {
        if (k == kind and n.node_net.items[@backingInt(from)] == net) total += v;
    }
    return total;
}

/// Every coupling element, summed, fF.
fn couplingFf(n: *const ParasiticNetwork) f64 {
    var total: f64 = 0.0;
    for (n.kind.items, n.value.items) |k, v| {
        if (k == .coupling_cap) total += v;
    }
    return total;
}

fn relative(a: f64, b: f64) f64 {
    return @abs(a - b) / @max(@abs(a), @abs(b), 1e-300);
}

/// `ε₀ εr t · L / S` for two facing sidewalls on layer `l`.
fn lateralFf(l: usize, run: i64, gap: i64) f64 {
    return 8.8541878128 * p.k[l] * p.thickness[l] / 1e3 * @as(f64, @floatFromInt(run)) / @as(f64, @floatFromInt(gap)) / 1e3;
}

/// `ε₀ εr · A / d` for overlapping `m1` and `m2` plates, `A` in nm².
fn interlayerFf(area: f64) f64 {
    const gap_um = (p.height[2] - p.height[0] - p.thickness[0]) / 1e3;
    return 8.8541878128 * p.k[0] * area / 1e6 / gap_um / 1e3;
}

fn groundFf(l: usize, area: f64, perimeter: f64) f64 {
    return (p.area[l] * area / 1e6 + p.fringe[l] * perimeter / 1e3) / 1e3;
}

test "analytical lateral coupling is the facing sidewall closed form" {
    // Oracle: closed form, `ε₀εr·t·L/S` over the facing run from the deck's
    // row, zero past ten thicknesses (4 µm on params.deck's metals); and the
    // metamorphic relation that every symmetry and translation leaves it
    // unchanged.
    for ([_]u16{ 0, 2 }) |layer| {
        for ([_]i64{ 100, 250, 1_000, 3_900, 4_100 }) |gap| {
            for ([_]i64{ 0, 1_500, -2_000, 6_500 }) |shift| {
                const run = @max(6_000 - @as(i64, @intCast(@abs(shift))), 0);
                const want = if (@as(f64, @floatFromInt(gap)) < 10.0 * p.thickness[layer] and run > 0) lateralFf(layer, run, gap) else 0.0;
                const bars = parallel(6_000, 1_000, gap, shift);
                const polys = [_]Poly{ .{ .layer = layer, .net = 0, .pts = &bars[0] }, .{ .layer = layer, .net = 1, .pts = &bars[1] } };
                for (fixture.Symmetry.all) |s| {
                    for (fixture.offsets) |d| {
                        var n: ParasiticNetwork = .empty;
                        defer n.deinit(gpa);
                        try extracted(&polys, s, d, .{}, &n);
                        const got = couplingFf(&n);
                        try testing.expect(relative(got, want) <= exact or @abs(got - want) <= 1e-15);
                    }
                }
            }
        }
    }
}

test "analytical interlayer coupling is the parallel plate closed form" {
    // Oracle: closed form, `ε₀εr·A/d` over the overlap worked out from the
    // coordinates, under every symmetry.
    const lower = [_][2]i64{ .{ 0, 0 }, .{ 3_000, 0 }, .{ 3_000, 2_000 }, .{ 0, 2_000 } };
    for ([_][2]i64{ .{ 1_000, 500 }, .{ 0, 0 }, .{ -500, 1_500 }, .{ 3_000, 2_000 } }) |at| {
        const x = at[0];
        const y = at[1];
        const wide = @max(@min(3_000, x + 4_000) - @max(x, 0), 0);
        const tall = @max(@min(2_000, y + 3_000) - @max(y, 0), 0);
        const want = interlayerFf(@floatFromInt(wide * tall));
        const upper = [_][2]i64{ .{ x, y }, .{ x + 4_000, y }, .{ x + 4_000, y + 3_000 }, .{ x, y + 3_000 } };
        const polys = [_]Poly{ .{ .layer = 0, .net = 0, .pts = &lower }, .{ .layer = 2, .net = 1, .pts = &upper } };
        for (fixture.Symmetry.all) |s| {
            var n: ParasiticNetwork = .empty;
            defer n.deinit(gpa);
            try extracted(&polys, s, .{ 0, 0 }, .{}, &n);
            const got = couplingFf(&n);
            try testing.expect(relative(got, want) <= exact or @abs(got - want) <= 1e-15);
        }
    }
}

test "each extraction type keeps what calibre's does of two coupled bars" {
    // Oracle: closed form and the types' definitions (PEX-008), on two m1
    // bars 6 × 1 µm, 1 µm apart: R = `Rs·6`, ground `Ca·6 + Cf·14`, the
    // coupling `ε₀εr·t·6` (between 0.05 and 0.1 fF). `rcc` keeps it; a
    // threshold above it (0.1 fF) or `rc` or `c` grounds it onto each bar;
    // one below (50 aF) keeps it; `r` drops all C; `cc` and `c` drop R.
    const r = p.sheet[0] * 6.0;
    const g = groundFf(0, 6e6, 14_000.0);
    const lateral = lateralFf(0, 6_000, 1_000);
    try testing.expect(lateral > 0.05 and lateral < 0.1);
    const cases = [_]struct { ingest.deck.Extraction, f64, f64 }{
        .{ .{ .kind = .rcc }, r, g },
        .{ .{ .kind = .rcc, .coupling_threshold_af = 100.0 }, r, g + lateral },
        .{ .{ .kind = .rcc, .coupling_threshold_af = 50.0 }, r, g },
        .{ .{ .kind = .rc }, r, g + lateral },
        .{ .{ .kind = .r }, r, 0.0 },
        .{ .{ .kind = .cc }, 0.0, g },
        .{ .{ .kind = .c }, 0.0, g + lateral },
    };
    const bars = parallel(6_000, 1_000, 1_000, 0);
    const polys = [_]Poly{ .{ .layer = 0, .net = 0, .pts = &bars[0] }, .{ .layer = 0, .net = 1, .pts = &bars[1] } };
    for (cases) |case| {
        for (fixture.Symmetry.all) |s| {
            for (fixture.offsets) |d| {
                var n: ParasiticNetwork = .empty;
                defer n.deinit(gpa);
                try extracted(&polys, s, d, case[0], &n);
                try testing.expect(relative(totalOn(&n, 0, .resistance), case[1]) <= exact);
                for ([_]u32{ 0, 1 }) |net| try testing.expect(relative(totalOn(&n, net, .ground_cap), case[2]) <= exact);
            }
        }
    }
}

test "a qualification of rc against rcc finds every net's totals unchanged" {
    // Oracle: law, through `compare` (PEX-009): grounding a coupling
    // conserves each net's total capacitance and every node's, so each
    // net's total C and pin-to-pin resistance agree to round-off; the one
    // coupling reads 0 in the candidate, −100 %; each bar's ground C grows
    // by `ε₀εr·t·L/S` over `Ca·A + Cf·P`. Each bar's capacitance sits on its
    // driver and no capacitance lies past a resistance, so every Elmore
    // delay is exactly 0.
    const bars = parallel(6_000, 1_000, 1_000, 0);
    const polys = [_]Poly{ .{ .layer = 0, .net = 0, .pts = &bars[0] }, .{ .layer = 0, .net = 1, .pts = &bars[1] } };
    var rcc: ParasiticNetwork = .empty;
    defer rcc.deinit(gpa);
    try extracted(&polys, fixture.Symmetry.all[0], .{ 0, 0 }, .{ .kind = .rcc }, &rcc);
    var rc: ParasiticNetwork = .empty;
    defer rc.deinit(gpa);
    try extracted(&polys, fixture.Symmetry.all[0], .{ 0, 0 }, .{ .kind = .rc }, &rc);
    var out: extract.compare.Comparison = .empty;
    defer out.deinit(gpa);
    try extract.compare.compareInto(gpa, &rcc, &rc, &out);
    try testing.expectEqual(0, out.only_reference.items.len + out.only_candidate.items.len);
    for ([_]extract.compare.Errors{ extract.compare.errors(out.total_cap.reference.items, out.total_cap.candidate.items, 1e-12, 1e-9), extract.compare.errors(out.resistance.reference.items, out.resistance.candidate.items, 1e-12, 1e-9) }) |e| {
        try testing.expectEqual(2, e.count);
        try testing.expectEqual(2, e.within);
    }
    try testing.expectEqual(2, out.delay.key.items.len);
    try testing.expectEqual(0, extract.compare.errors(out.delay.reference.items, out.delay.candidate.items, 0.0, std.math.floatMin(f64)).count);
    const coupling = extract.compare.errors(out.coupling.reference.items, out.coupling.candidate.items, 1e-12, 1e-9);
    try testing.expectEqual(1, coupling.count);
    try testing.expectEqual(0, coupling.within);
    try testing.expectApproxEqAbs(-1.0, coupling.worst, 1e-12);
    const grown = lateralFf(0, 6_000, 1_000) / groundFf(0, 6e6, 14_000.0);
    const ground = extract.compare.errors(out.ground_cap.reference.items, out.ground_cap.candidate.items, 1.0, 1e-9);
    try testing.expectEqual(2, ground.count);
    try testing.expect(relative(ground.worst, grown) < exact and relative(ground.mean, grown) < exact);
}
