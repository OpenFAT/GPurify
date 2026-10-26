//! The substrate network solve (catalog PEX-013) against closed forms and
//! the laws of a linear resistive network. Ported from
//! crates/extract/tests/pex/substrate.rs; its release-tier test (level 3)
//! is in substrate_slow.zig.
//!
//! Contents: `Rect`, `ohm_cm`, `squareOnSlab`, `errorsTo`; helpers `solve`,
//! `threePorts`, `epi`; then the tests.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const extract = @import("extract");
const substrate = extract.substrate;
const gpa = testing.allocator;

/// A rectangle `[x0, y0, x1, y1]`, µm.
pub const Rect = [4]f64;

/// ρ of 1 Ω·cm, in Ω·µm.
pub const ohm_cm: f64 = 1e4;

/// Read's capacitance of the unit square, in units of 4πε₀ (J. Comput.
/// Phys. 133, 1997: 0.3667874 ± 1e-7).
const square: f64 = 0.3667874;

/// The die of `threePorts`.
const die: Rect = .{ -10.0, -4.0, 12.0, 9.0 };

/// A 1 µm square contact on a 20 µm slab of 1 Ω·cm over a grounded
/// backside, the die 80 µm across: its resistance at `level`.
pub fn squareOnSlab(level: u32) !f64 {
    var y: substrate.Admittance = .empty;
    defer y.deinit(gpa);
    try solve(.{ .layers = &.{.{ 20.0, ohm_cm }}, .backside = .grounded }, .{ -40.0, -40.0, 40.0, 40.0 }, &.{&.{.{ -0.5, -0.5, 0.5, 0.5 }}}, level, &y);
    return 1.0 / y.at(0, 0);
}

/// The relative error of each level from 0 to `top` into `out`, and of the
/// Richardson extrapolation of the last two (the error falls fourfold a level).
pub fn errorsTo(top: u32, out: []f64) !f64 {
    const exact = squareOnSlabClosedForm();
    var last: [2]f64 = undefined;
    for (0..top + 1) |level| {
        const r = try squareOnSlab(@intCast(level));
        out[level] = @abs(r - exact) / exact;
        last = .{ last[1], r };
    }
    const extrapolated = last[1] + (last[1] - last[0]) / 3.0;
    return @abs(extrapolated - exact) / exact;
}

// ---- private ----

/// The closed form for `squareOnSlab`: the half-space spreading of a
/// square, `ρ / (2π · 0.3667874 · s)` (an isolated plate's capacitance `C`
/// gives the half-space `G = σC / 2ε`), less the grounded backside's image
/// series for a source on a slab of depth `D`, `ρ ln 2 / (2πD)`.
fn squareOnSlabClosedForm() f64 {
    return ohm_cm / (2.0 * std.math.pi * square * 1.0) - ohm_cm * std.math.ln2 / (2.0 * std.math.pi * 20.0);
}

/// Solves `ports` (each a list of rectangles) under `domain` at `level`.
fn solve(profile: substrate.Profile, domain: Rect, ports: []const []const Rect, level: u32, out: *substrate.Admittance) !void {
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(gpa);
    for (ports) |rects| for (rects) |r| {
        try xs.appendSlice(gpa, &.{ r[0], r[2] });
        try ys.appendSlice(gpa, &.{ r[1], r[3] });
    };
    var lines: substrate.Lines = .empty;
    defer lines.deinit(gpa);
    var refusal: substrate.Refusal = .{};
    try substrate.linesInto(gpa, profile, domain, xs.items, ys.items, level, &lines, &refusal);
    const ny = lines.y.items.len;
    const held = try gpa.alloc(u32, lines.x.items.len * ny);
    defer gpa.free(held);
    for (lines.x.items, 0..) |x, i| {
        for (lines.y.items, 0..) |y, j| {
            held[i * ny + j] = for (ports, 0..) |rects, p| {
                const hit = for (rects) |r| {
                    if (r[0] <= x and x <= r[2] and r[1] <= y and y <= r[3]) break true;
                } else false;
                if (hit) break @intCast(p);
            } else substrate.no_port;
        }
    }
    try substrate.admittanceInto(gpa, 8, profile, &lines, held, @intCast(ports.len), out);
}

/// Three contacts of unequal size at unequal spacing, one an L of two
/// rectangles; `mirrored` reflects them left to right.
fn threePorts(mirrored: bool) [3][2]Rect {
    var ports: [3][2]Rect = .{
        .{ .{ 0.0, 0.0, 2.0, 1.0 }, .{ 0.0, 0.0, 2.0, 1.0 } },
        .{ .{ 5.0, 0.0, 6.0, 3.0 }, .{ 6.0, 2.0, 8.0, 3.0 } },
        .{ .{ -6.0, 4.0, -5.0, 5.0 }, .{ -6.0, 4.0, -5.0, 5.0 } },
    };
    if (mirrored) for (&ports) |*rects| for (rects) |*r| {
        const o = r.*;
        r.* = .{ -o[2], o[1], -o[0], o[3] };
    };
    return ports;
}

fn portSlices(ports: *const [3][2]Rect, out: *[3][]const Rect) []const []const Rect {
    for (out, ports) |*o, *p| o.* = p;
    return out;
}

/// An epitaxial layer of 10 Ω·cm over a 0.01 Ω·cm bulk.
fn epi(backside: substrate.Backside) substrate.Profile {
    return .{ .layers = &.{ .{ 3.0, 10.0 * ohm_cm }, .{ 30.0, 0.01 * ohm_cm } }, .backside = backside };
}

test "a square contact spreads as the closed form under refinement" {
    // Oracle: closed form (Read's square-plate capacitance and the slab's
    // image series) and mesh-refinement convergence: each level more than
    // three times closer (21 %, 6.2 %, 1.4 %), the two finest extrapolating
    // within 0.5 %. Breaks if the grading, the depth elimination or the
    // modal transform is wrong.
    var errors: [3]f64 = undefined;
    const extrapolated = try errorsTo(2, &errors);
    for (errors[0..2], errors[1..]) |coarse, fine| try testing.expect(fine < coarse / 3.0);
    try testing.expect(errors[2] < 0.02);
    try testing.expect(extrapolated < 0.005);
}

test "a full contact over layers is their series resistance" {
    // Oracle: closed form (Ohm's law, `Σ ρᵢtᵢ / A`): `(2 µm · 100 + 5 µm ·
    // 1000) Ω·µm / 100 µm² = 52 Ω`, at every level.
    const profile: substrate.Profile = .{ .layers = &.{ .{ 2.0, 100.0 }, .{ 5.0, 1000.0 } }, .backside = .grounded };
    for (0..3) |level| {
        var y: substrate.Admittance = .empty;
        defer y.deinit(gpa);
        try solve(profile, .{ 0.0, 0.0, 10.0, 10.0 }, &.{&.{.{ 0.0, 0.0, 10.0, 10.0 }}}, @intCast(level), &y);
        try testing.expectApproxEqRel(52.0, 1.0 / y.at(0, 0), 1e-9);
        try testing.expectApproxEqRel(52.0, 1.0 / y.toBackside(0), 1e-9);
    }
}

test "the port admittance is reciprocal and conserves current" {
    // Oracle: reciprocity (a passive resistive network's admittance matrix
    // is symmetric) and Kirchhoff's current law: with a floating backside
    // every row sums to zero; every pair couples through a positive
    // conductance.
    const ports = threePorts(false);
    var slices: [3][]const Rect = undefined;
    for ([_]substrate.Backside{ .grounded, .floating }) |backside| {
        var y: substrate.Admittance = .empty;
        defer y.deinit(gpa);
        try solve(epi(backside), die, portSlices(&ports, &slices), 1, &y);
        const scale = y.at(0, 0);
        for (0..3) |p| {
            for (0..3) |q| {
                try testing.expect(@abs(y.at(p, q) - y.at(q, p)) < 1e-8 * scale);
                if (p != q) try testing.expect(y.between(p, q) > 0.0);
            }
            switch (backside) {
                .grounded => try testing.expect(y.toBackside(p) > 0.0),
                .floating => try testing.expect(@abs(y.toBackside(p)) < 1e-6 * scale),
            }
        }
    }
}

test "a mirrored layout has the same network" {
    // Oracle: symmetry (a mirror maps the boundary problem onto itself).
    const plain = threePorts(false);
    const mirror = threePorts(true);
    var s1: [3][]const Rect = undefined;
    var s2: [3][]const Rect = undefined;
    var a: substrate.Admittance = .empty;
    defer a.deinit(gpa);
    var b: substrate.Admittance = .empty;
    defer b.deinit(gpa);
    try solve(epi(.grounded), die, portSlices(&plain, &s1), 1, &a);
    try solve(epi(.grounded), .{ -die[2], die[1], -die[0], die[3] }, portSlices(&mirror, &s2), 1, &b);
    for (a.y.items, b.y.items) |p, q| try testing.expect(@abs(p - q) < 1e-8 * a.at(0, 0));
}

test "two ports driven together superpose" {
    // Oracle: superposition (the network is linear): the merged port's
    // self-admittance is `Y00 + Y01 + Y10 + Y11`, its coupling to the third
    // `Y20 + Y21`.
    const ports = threePorts(false);
    var slices: [3][]const Rect = undefined;
    var y: substrate.Admittance = .empty;
    defer y.deinit(gpa);
    try solve(epi(.grounded), die, portSlices(&ports, &slices), 1, &y);
    const both_rects = [_]Rect{ ports[0][0], ports[0][1], ports[1][0], ports[1][1] };
    var m: substrate.Admittance = .empty;
    defer m.deinit(gpa);
    try solve(epi(.grounded), die, &.{ &both_rects, &ports[2] }, 1, &m);
    const scale = y.at(0, 0);
    try testing.expect(@abs(m.at(0, 0) - (y.at(0, 0) + y.at(0, 1) + y.at(1, 0) + y.at(1, 1))) < 1e-8 * scale);
    try testing.expect(@abs(m.at(1, 0) - (y.at(2, 0) + y.at(2, 1))) < 1e-8 * scale);
}

test "a net's port shapes become its substrate resistance to ground" {
    // Oracle: closed form through `addInto`: one net's 10 × 10 µm tap over
    // the two layers of the series test, drawn as two abutting halves (one
    // port), is 52 Ω to the grounded backside; a shape on no net adds
    // nothing.
    var b: geom.GeometryStoreBuilder = .empty;
    defer b.deinit(gpa);
    _ = try b.push(gpa, @fromBackingInt(0), &.{ 0, 5_000, 5_000, 0 }, &.{ 0, 0, 10_000, 10_000 });
    _ = try b.push(gpa, @fromBackingInt(0), &.{ 5_000, 10_000, 10_000, 5_000 }, &.{ 0, 0, 10_000, 10_000 });
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var perm: std.ArrayList(u32) = .empty;
    defer perm.deinit(gpa);
    try b.finish(gpa, 1, &store, &perm);
    var n: extract.network.ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try n.node_net.append(gpa, 0);
    try n.node_layer.append(gpa, @fromBackingInt(0));
    var refusal: substrate.Refusal = .{};
    const profile: substrate.Profile = .{ .layers = &.{ .{ 2.0, 100.0 }, .{ 5.0, 1000.0 } }, .backside = .grounded };
    try substrate.addInto(gpa, 8, &n, &store, &.{ 0, 0 }, profile, &.{@fromBackingInt(0)}, .{ .xlo = 0, .ylo = 0, .xhi = 10_000, .yhi = 10_000 }, .{ .dbu_per_um = 1000 }, &refusal);
    try testing.expectEqual(1, n.elementCount());
    try testing.expectEqual(extract.network.Kind.substrate_resistance, n.kind.items[0]);
    try testing.expectEqual(extract.network.NodeId.ground, n.to.items[0]);
    try testing.expectApproxEqRel(52.0, n.value.items[0], 1e-9);
}
