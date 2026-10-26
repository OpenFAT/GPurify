//! The field solve's large cases: plates of hundreds to thousands of panels
//! and the cube refined to 32 panels a side. Ported from
//! tests/exhaustive/pex.rs. Each takes minutes in Debug, so `-Dslow-tests`
//! (on by default outside Debug) compiles this file in.
//!
//! Contents: helpers `plateFf`, `relative`; then the tests.

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

/// ε₀ in aF/µm (CODATA 2018).
const epsilon0_af_per_um = 8.854_187_812_8;

// ---- private ----

/// One square plate `side` nm on `layer`, solved alone, in fF.
fn plateFf(layer: u16, side: i64, rows: *const Rows) !struct { f64, capacitance.Accuracy } {
    var c = try Case.init(&.{.{ .layer = layer, .net = 0, .r = .{ 0, 0, side, side } }}, &.{}, 3);
    defer c.deinit();
    var out: [1]f64 = undefined;
    const accuracy = try fixture.solveFf(&c, rows, &.{0}, &out);
    return .{ out[0], accuracy };
}

fn relative(a: f64, b: f64) f64 {
    return @abs(a - b) / @max(@max(@abs(a), @abs(b)), 1e-300);
}

test "a field solved plate sees the substrate" {
    // Oracle: law. Thomson's principle bounds an 8 um plate's capacitance
    // below by the column `ε₀εr·A/h` under it; it falls strictly as the
    // plate rises 250, 500, 1000 nm (a grounded conductor brought closer
    // only draws more charge), and the fringe share `C·h/(ε₀εr·A)` grows as
    // `W/h` falls. With no plane the field is the same at every height,
    // which breaks all three (F24).
    var previous: ?[2]f64 = null;
    for ([_]f64{ 250, 500, 1_000 }) |h| {
        var rows = fixture.coarse;
        rows.height[0] = h;
        const c = (try plateFf(0, 8_000, &rows))[0];
        const column = epsilon0_af_per_um * rows.k[0] * 64.0 / (h / 1e3) / 1e3;
        try testing.expect(c >= column);
        const share = c / column;
        if (previous) |p| {
            try testing.expect(c < p[0]);
            try testing.expect(share > p[1]);
        }
        previous = .{ c, share };
    }
}

test "a stratified plate lies between its two uniform stacks" {
    // Oracle: laws. An 8 um `m1` plate 250 nm up in a stack 7 to its top and
    // 3.9 over it lies strictly between the stack all 3.9 and the stack all
    // 7 (capacitance grows with any permittivity), at least the column
    // `ε₀·7·A/h` under it; its reciprocity is the interfaces' bound, not the
    // tolerance; and with every permittivity doubled it doubles, to the
    // solve's tolerance (free charge is permittivity times total charge).
    // Fails if the interface's polarisation has the wrong sign, if a face
    // reads the wrong side's permittivity, or if the free charge is not
    // scaled.
    const low = (try plateFf(0, 8_000, &fixture.coarse.uniform(3.9)))[0];
    const high = (try plateFf(0, 8_000, &fixture.coarse.uniform(7.0)))[0];
    var stratified = fixture.coarse.uniform(3.9);
    stratified.k[0] = 7.0;
    const middle, const accuracy = try plateFf(0, 8_000, &stratified);
    const column = epsilon0_af_per_um * 7.0 * 64.0 / (fixture.coarse.height[0] / 1e3) / 1e3;
    try testing.expect(low < middle and middle < high and middle >= column);
    try testing.expect(accuracy.reciprocity > accuracy.tolerance);
    var doubled = fixture.coarse.uniform(7.8);
    doubled.k[0] = 14.0;
    const twice = (try plateFf(0, 8_000, &doubled))[0];
    try testing.expect(relative(twice, 2.0 * middle) < same_field);
}

test "a plate on an interface reads its two layers in series" {
    // Oracle: closed form, the parallel plate over a two-layer stack, the two
    // layers in series: per area `ε₀ / (0.75 µm / 7 + 0.5 µm / 3.9)` for an
    // `m2` plate 1250 nm up, its bottom on the interface between the 3.9
    // under it and the 5 around it, over 7 up to `m1`'s top at 750 nm. The
    // second difference over sides L, 2L, 3L, `(C(3L) − 2C(2L) + C(L))/2L²`,
    // is the area term but for the edge fringe that does not grow linearly,
    // of order `(h/L)/π`, 10 % at L = 4 µm; the same residual stands in the
    // all-3.9 stack, so the ratio of the two area terms is held to the
    // closed forms' ratio, 1.362, to 2 %. Fails if the plate's bottom face
    // reads the permittivity above the interface (a ratio of 1.547), or the
    // polarisation of either interface is lost.
    const side = 4_000;
    const eps0_ff_per_um = epsilon0_af_per_um / 1e3;
    const height = fixture.coarse.height[2] / 1e3;
    const interface = fixture.coarse.height[1] / 1e3;
    var layered = fixture.coarse;
    layered.k = .{ 7.0, 3.9, 5.0 };
    const cases = [_]struct { Rows, f64 }{
        .{ fixture.coarse.uniform(3.9), eps0_ff_per_um * 3.9 / height },
        .{ layered, eps0_ff_per_um / (interface / 7.0 + (height - interface) / 3.9) },
    };
    var terms: [2][2]f64 = undefined;
    for (cases, &terms) |case, *term| {
        var c: [3]f64 = undefined;
        for (&c, 1..) |*v, n| v.* = (try plateFf(2, @intCast(n * side), &case[0]))[0];
        const l = @as(f64, side) / 1e3;
        const got = (c[2] - 2.0 * c[1] + c[0]) / (2.0 * l * l);
        try testing.expect(relative(got, case[1]) < 1e-1);
        term.* = .{ got, case[1] };
    }
    try testing.expect(relative(terms[1][0] / terms[0][0], terms[1][1] / terms[0][1]) < 2e-2);
}

test "a field solved capacitance converges as the mesh is refined" {
    // Oracle: published value and a convergence law: the unit cube's
    // free-space capacitance, 0.66068 · 4πε₀a (Read 1997; Hwang, Mascagni
    // and Given 2004), raised by its image in the plane 50 um below its
    // centre, `C = C₀ / (1 − C₀/(8πε₀H))`, approached monotonically (F77:
    // each refinement raises C) inside the `h^(2/3)` envelope the coarsest
    // mesh's error sets (a cube edge's charge grows as `d^(−1/3)`).
    const side = 1_000.0;
    const centre = 50_000.0;
    var cube = fixture.coarse.uniform(1.0);
    cube.thickness[0] = side;
    cube.height[0] = centre - side / 2.0;
    var case = try Case.init(&.{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 1_000, 1_000 } }}, &.{}, 3);
    defer case.deinit();
    var c: [5]f64 = undefined;
    // 1000 nm over these edges is 2, 4, 8, 16 and 32 panels a side.
    for (&c, [_]i64{ 500, 250, 125, 63, 32 }) |*v, edge| {
        var matrix: capacitance.CapMatrix = .empty;
        defer matrix.deinit(gpa);
        var diag: capacitance.Diagnostic = .{};
        _ = try capacitance.extractMeshedInto(gpa, fixture.device, case.problem(&cube), &.{0}, .{ .max_edge = edge, .proximity_refine = 0, .max_panels = 1 << 20 }, &matrix, &diag);
        v.* = matrix.value.items[0] * 1e15;
    }
    const four_pi_eps0_ff_per_um = 4.0 * std.math.pi * epsilon0_af_per_um / 1e3;
    const free = 0.660_68 * four_pi_eps0_ff_per_um * side / 1e3;
    const limit = free / (1.0 - free / (2.0 * four_pi_eps0_ff_per_um * centre / 1e3));
    const e0 = @abs(c[0] - limit);
    for (1..c.len) |k| {
        const finer: f64 = @floatFromInt(@as(u32, 1) << @intCast(k));
        try testing.expect(@abs(c[k] - limit) <= e0 / std.math.pow(f64, finer, 2.0 / 3.0));
        try testing.expect(c[k] > c[k - 1]);
    }
}
