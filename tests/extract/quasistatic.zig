//! The field-solve readout: the matrix read out as a `ParasiticNetwork`,
//! and the overlay onto the analytical network. Ported from
//! crates/extract/tests/pex/quasistatic.rs; the scale corpus is replaced by
//! hand-drawn combs (mesh.zig's).
//!
//! Contents: helpers `combs`, `facingCombs`, `solve`, `serialise`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const fixture = @import("fixture.zig");
const Box = fixture.Box;
const Case = fixture.Case;
const capacitance = extract.capacitance;
const network = extract.network;
const NodeId = network.NodeId;
const ParasiticNetwork = network.ParasiticNetwork;
const quasistatic = extract.quasistatic;
const gpa = testing.allocator;

// ---- private ----

/// Two combs, one net each, on layers 0 and 1.
fn combs() [8]Box {
    var out: [8]Box = undefined;
    for (0..2) |k| {
        const y: i64 = @intCast(k * 4_000);
        out[4 * k] = .{ .layer = @intCast(k), .net = @intCast(k), .r = .{ 0, y, 6_000, y + 400 } };
        for (0..3) |f| {
            const x: i64 = @intCast(f * 2_000);
            out[4 * k + 1 + f] = .{ .layer = @intCast(k), .net = @intCast(k), .r = .{ x, y + 400, x + 400, y + 2_400 } };
        }
    }
    return out;
}

/// Two combs on layer 0 (`m1`), nets 0 and 1: comb 1's rail 400 nm above
/// comb 0's finger tips, so the closed forms couple them laterally.
fn facingCombs() [8]Box {
    var out: [8]Box = undefined;
    out[0] = .{ .layer = 0, .net = 0, .r = .{ 0, 0, 6_000, 400 } };
    out[4] = .{ .layer = 0, .net = 1, .r = .{ 0, 2_800, 6_000, 3_200 } };
    for (0..3) |f| {
        const x: i64 = @intCast(f * 2_000);
        out[1 + f] = .{ .layer = 0, .net = 0, .r = .{ x, 400, x + 400, 2_400 } };
        out[5 + f] = .{ .layer = 0, .net = 1, .r = .{ x + 1_000, 3_200, x + 1_400, 5_200 } };
    }
    return out;
}

fn solve(c: *const Case, matrix: *capacitance.CapMatrix, out: *ParasiticNetwork) !capacitance.Accuracy {
    // The coarse stack's 500 nm panel edge keeps the solve small in Debug.
    var diag: capacitance.Diagnostic = .{};
    return quasistatic.extractInto(gpa, fixture.device, c.problem(&fixture.coarse), &.{ 0, 1 }, matrix, out, &diag);
}

/// Every column of a network and a matrix as bytes, floats by their bits.
fn serialise(m: *const capacitance.CapMatrix, n: *const ParasiticNetwork, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, std.mem.sliceAsBytes(m.net.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(m.value.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.node_net.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.node_layer.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.from.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.to.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.kind.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.value.items));
}

test "a field solve obeys reciprocity and its network reads the matrix" {
    // Oracle: law. With no closed form for the geometry, what reciprocity
    // guarantees for any geometry is asserted: a square matrix at the net
    // count, symmetric (a transposed index is off by order one, four orders
    // above 1e-4), diagonally dominant with non-positive off-diagonals, and
    // non-negative in energy `½ VᵀCV`; the residual asked for travels with
    // it. And the network is the matrix's documented reading: row sums as
    // ground capacitance, `−C_ij` as coupling, read back to the matrix in fF.
    var c = try Case.init(&combs(), &.{}, 3);
    defer c.deinit();
    var matrix: capacitance.CapMatrix = .empty;
    defer matrix.deinit(gpa);
    var net: ParasiticNetwork = .empty;
    defer net.deinit(gpa);
    const accuracy = try solve(&c, &matrix, &net);
    const n = matrix.dim();
    try testing.expectEqual(2, n);
    try testing.expectEqual(extract.solve.Options.default.tolerance, accuracy.tolerance);
    try testing.expect(accuracy.iterations > 0);
    try testing.expect(matrix.asymmetry() < 1e-4);
    try testing.expectApproxEqAbs(matrix.asymmetry(), accuracy.asymmetry, 1e-12);
    const v = matrix.value.items;
    for (0..n) |i| {
        var off: f64 = 0.0;
        for (0..n) |j| {
            if (j == i) continue;
            try testing.expect(v[i * n + j] <= 0.0);
            off += @abs(v[i * n + j]);
        }
        try testing.expect(v[i * n + i] >= off);
    }
    var rng: Rng = .init(73);
    for (0..32) |_| {
        var volts: [2]f64 = undefined;
        for (&volts) |*x| x.* = rng.unit() * 4.0 - 2.0;
        var energy: f64 = 0.0;
        for (0..n) |i| {
            var flux: f64 = 0.0;
            for (0..n) |j| flux += v[i * n + j] * volts[j];
            energy += volts[i] * flux;
        }
        try testing.expect(energy >= 0.0);
    }
    var read: [4]f64 = @splat(0.0);
    for (net.from.items, net.to.items, net.kind.items, net.value.items) |from, to, kind, value| {
        const i = @backingInt(from);
        switch (kind) {
            .ground_cap => read[i * 2 + i] += value,
            .coupling_cap => {
                const j = @backingInt(to);
                read[i * 2 + j] -= value;
                read[j * 2 + i] -= value;
                read[i * 2 + i] += value;
                read[j * 2 + j] += value;
            },
            .resistance, .inductance, .mutual_inductance, .substrate_resistance => return error.UnexpectedElement,
        }
    }
    for (read, v) |got, farads| try testing.expectApproxEqRel(farads * 1e15, got, 1e-8);
}

test "a field solve is byte identical across runs" {
    // Oracle: determinism. The matrix is assembled in ascending net order
    // from geometry alone, so two solves give the same bits, in the matrix
    // and in the network both, and the same accuracy.
    var c = try Case.init(&combs(), &.{}, 3);
    defer c.deinit();
    var bytes: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&bytes) |*b| b.deinit(gpa);
    var accuracy: [2]capacitance.Accuracy = undefined;
    for (&bytes, &accuracy) |*b, *a| {
        var matrix: capacitance.CapMatrix = .empty;
        defer matrix.deinit(gpa);
        var net: ParasiticNetwork = .empty;
        defer net.deinit(gpa);
        a.* = try solve(&c, &matrix, &net);
        try serialise(&matrix, &net, b);
    }
    try testing.expectEqualSlices(u8, bytes[0].items, bytes[1].items);
    try testing.expectEqual(accuracy[0], accuracy[1]);
}

test "an overlay keeps analytical coupling to unsolved neighbours on either side" {
    // Oracle: construct-from-answer. Net 0 has two analytical nodes, net 1
    // one, net 2 one. Net 1 is solved into two nodes: its analytical
    // couplings to nets 0 (lower id) and 2 (higher id) both survive on its
    // solved anchor, its own ground row goes, and the solved rows come in:
    // totals 1.5, 2.75 and 3.25 fF over seven elements, canonically sorted.
    var analytical: ParasiticNetwork = .empty;
    defer analytical.deinit(gpa);
    try analytical.node_net.appendSlice(gpa, &.{ 0, 0, 1, 2 });
    try analytical.node_layer.appendNTimes(gpa, @fromBackingInt(0), 4);
    try analytical.push(gpa, .at(0), .ground, .ground_cap, 1.0);
    try analytical.push(gpa, .at(0), .at(1), .resistance, 10.0);
    try analytical.push(gpa, .at(1), .at(2), .coupling_cap, 0.5);
    try analytical.push(gpa, .at(2), .ground, .ground_cap, 7.0);
    try analytical.push(gpa, .at(2), .at(3), .coupling_cap, 0.25);
    try analytical.push(gpa, .at(3), .ground, .ground_cap, 3.0);
    var solved: ParasiticNetwork = .empty;
    defer solved.deinit(gpa);
    try solved.node_net.appendSlice(gpa, &.{ 1, 1 });
    try solved.node_layer.appendNTimes(gpa, @fromBackingInt(0), 2);
    try solved.push(gpa, .at(0), .ground, .ground_cap, 2.0);
    try solved.push(gpa, .at(0), .at(1), .inductance, 4.0);

    try quasistatic.overlay(gpa, &analytical, &solved);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 2 }, analytical.node_net.items);
    for (analytical.from.items, analytical.to.items) |from, to| {
        try testing.expect(@backingInt(from) < 5);
        try testing.expect(to == .ground or @backingInt(to) < 5);
    }
    try testing.expectEqual(7, analytical.elementCount());
    for (analytical.from.items[0 .. analytical.from.items.len - 1], analytical.from.items[1..]) |a, b| try testing.expect(@backingInt(a) <= @backingInt(b));
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try analytical.capacitancePerNetInto(gpa, &totals);
    try testing.expectApproxEqAbs(@as(f64, 1.5), totals.items[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.75), totals.items[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3.25), totals.items[2], 1e-12);
    var couplings: std.ArrayList([2]NodeId) = .empty;
    defer couplings.deinit(gpa);
    for (analytical.from.items, analytical.to.items, analytical.kind.items) |from, to, kind| {
        if (kind == .coupling_cap) try couplings.append(gpa, .{ from, to });
    }
    try testing.expectEqualSlices([2]NodeId, &.{ .{ .at(1), .at(2) }, .{ .at(2), .at(4) } }, couplings.items);
}

test "inductance readout doubles each net's node and joins them by its series l and r" {
    // Oracle: construct-from-answer, from the readout's definition: after
    // the capacitance readout of two bars, each net's anchor `i` becomes
    // node `2i` with a far node `2i + 1`, joined by its L and R, and the pair
    // gains one mutual inductance anchor to anchor, the mean of `M01` and
    // `M10`: the solved matrix's values at the network's units (pH, ohm).
    const bars = [_]Box{ .{ .layer = 0, .net = 0, .r = .{ 0, 0, 20_000, 1_000 } }, .{ .layer = 0, .net = 1, .r = .{ 0, 3_000, 20_000, 4_000 } } };
    var c = try Case.init(&bars, &.{}, 3);
    defer c.deinit();
    var matrix: capacitance.CapMatrix = .empty;
    defer matrix.deinit(gpa);
    var net: ParasiticNetwork = .empty;
    defer net.deinit(gpa);
    _ = try solve(&c, &matrix, &net);
    const couplings_before = net.elementCount();
    var induct: extract.henry.InductMatrix = .empty;
    defer induct.deinit(gpa);
    var refusal: extract.henry.Refusal = .{};
    const rows = fixture.uniformRows(1.0, 0.25);
    const problem: extract.henry.Problem = .{ .store = &c.store, .nets = &c.nets, .global = &.{}, .vias = .{ .cut = &.{}, .connects = &.{} }, .stack = rows.stack(), .grid = fixture.grid };
    try quasistatic.extractInductanceInto(gpa, 4, problem, &.{ 0, 1 }, &induct, &net, &refusal);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1 }, net.node_net.items);
    try testing.expectEqual(couplings_before + 5, net.elementCount());
    const tail = couplings_before;
    for (0..2) |row| {
        try testing.expectEqual(network.Kind.inductance, net.kind.items[tail + 2 * row]);
        try testing.expectEqual(NodeId.at(2 * row), net.from.items[tail + 2 * row]);
        try testing.expectEqual(NodeId.at(2 * row + 1), net.to.items[tail + 2 * row]);
        try testing.expectEqual(induct.l_henry.items[row] * 1e12, net.value.items[tail + 2 * row]);
        try testing.expectEqual(induct.r_ohm.items[row], net.value.items[tail + 2 * row + 1]);
    }
    const m = induct.m_henry.items;
    try testing.expectEqual(network.Kind.mutual_inductance, net.kind.items[tail + 4]);
    try testing.expectEqual(NodeId.at(2), net.to.items[tail + 4]);
    try testing.expectEqual(0.0 + (m[1] + m[2]) / 2.0 * 1e12, net.value.items[tail + 4]);
}

test "field solving one of two coupled nets keeps their coupling" {
    // Oracle: law. Field-solving either one of two analytically coupled
    // nets keeps every node in range and keeps the closed forms' coupling to
    // the other: the solve never sees the unsolved net, so the overlay keeps
    // the analytical estimate (Rust's test, on two combs facing across a
    // 400 nm gap in place of the scale corpus).
    var c = try Case.init(&facingCombs(), &.{}, 3);
    defer c.deinit();
    const vias: extract.Vias = .{ .cut = &.{@fromBackingInt(1)}, .connects = &.{.{ @fromBackingInt(0), @fromBackingInt(2) }} };
    const problem: extract.analytical.Problem = .{ .store = &c.store, .nets = &c.nets, .conductors = &.{ @fromBackingInt(0), @fromBackingInt(2) }, .global = &.{}, .vias = vias, .stack = fixture.coarse.stack(), .halo = 10.0, .grid = fixture.grid };
    var refusal: extract.analytical.Refusal = .{};
    var coarse: ParasiticNetwork = .empty;
    defer coarse.deinit(gpa);
    try extract.analytical.extractInto(gpa, problem, &coarse, &refusal);
    var coupled: f64 = 0.0;
    for (coarse.kind.items, coarse.value.items) |k, v| {
        if (k == .coupling_cap) coupled += v;
    }
    try testing.expect(coupled > 0.0);
    for ([_]u32{ 0, 1 }) |net| {
        var matrix: capacitance.CapMatrix = .empty;
        defer matrix.deinit(gpa);
        var solved: ParasiticNetwork = .empty;
        defer solved.deinit(gpa);
        var diag: capacitance.Diagnostic = .{};
        _ = try quasistatic.extractInto(gpa, fixture.device, c.problem(&fixture.coarse), &.{net}, &matrix, &solved, &diag);
        var n: ParasiticNetwork = .empty;
        defer n.deinit(gpa);
        try extract.analytical.extractInto(gpa, problem, &n, &refusal);
        try quasistatic.overlay(gpa, &n, &solved);
        const nodes = n.nodeCount();
        var kept: f64 = 0.0;
        for (n.from.items, n.to.items, n.kind.items, n.value.items) |from, to, k, v| {
            try testing.expect(@backingInt(from) < nodes);
            if (to != .ground) try testing.expect(@backingInt(to) < nodes);
            if (k == .coupling_cap) kept += v;
        }
        try testing.expectApproxEqAbs(coupled, kept, 1e-12);
    }
}
