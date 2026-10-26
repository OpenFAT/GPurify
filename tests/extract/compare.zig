//! PEX-009: two extractions compared net by net, on networks whose every
//! metric is worked out by hand. Ported from
//! crates/extract/tests/pex/compare.rs.
//!
//! Contents: helpers `ladder`, `compared`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const compare = extract.compare;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;

// ---- private ----

/// Net 0: four 10 Ω resistors from its driver (node 0) to node 4, 2 fF to
/// ground at nodes 1 to 4. Net 1: 5 Ω from node 5 to 6, 3 fF at node 6, and
/// 1 fF of coupling from node 6 to net 0's node 2. Resistances scaled by
/// `r`, capacitances by `c`.
fn ladder(r: f64, c: f64) !ParasiticNetwork {
    var out: ParasiticNetwork = .empty;
    errdefer out.deinit(gpa);
    try out.node_net.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 1, 1 });
    try out.node_layer.appendNTimes(gpa, @fromBackingInt(0), 7);
    for (0..4) |k| {
        try out.push(gpa, .at(k), .at(k + 1), .resistance, 10.0 * r);
        try out.push(gpa, .at(k + 1), .ground, .ground_cap, 2.0 * c);
    }
    try out.push(gpa, .at(5), .at(6), .resistance, 5.0 * r);
    try out.push(gpa, .at(6), .ground, .ground_cap, 3.0 * c);
    try out.push(gpa, .at(2), .at(6), .coupling_cap, c);
    try out.sortCanonical(gpa);
    return out;
}

fn compared(reference: *const ParasiticNetwork, candidate: *const ParasiticNetwork) !compare.Comparison {
    var out: compare.Comparison = .empty;
    errdefer out.deinit(gpa);
    try compare.compareInto(gpa, reference, candidate, &out);
    return out;
}

fn errorsOf(m: anytype, tolerance: f64, floor: f64) compare.Errors {
    return compare.errors(m.reference.items, m.candidate.items, tolerance, floor);
}

test "a ladder's resistance and delay are elmore's" {
    // Oracle: closed form (Elmore 1948, a uniform RC ladder). Node j shares
    // `min(j, k)·R` with node k, so the far end's delay is `R·C·N(N+1)/2 =
    // 200` fs for N = 4, plus the coupling's 1 fF at node 2 through 20 Ω:
    // 220 fs; pin-to-pin `N·R = 40` Ω. Net 1: 5 Ω and `5·(3 + 1) = 20` fs.
    // Net 0 holds 8 + 1 fF, net 1 3 + 1.
    var n = try ladder(1.0, 1.0);
    defer n.deinit(gpa);
    var same = try compared(&n, &n);
    defer same.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, same.resistance.key.items);
    for ([_][2]f64{ .{ 40.0, 220.0 }, .{ 5.0, 20.0 } }, 0..) |want, net| {
        try testing.expectApproxEqAbs(want[0], same.resistance.reference.items[net], 1e-9);
        try testing.expectApproxEqAbs(want[1], same.delay.reference.items[net], 1e-9);
    }
    try testing.expectEqualSlices(f64, &.{ 9.0, 4.0 }, same.total_cap.reference.items);
    try testing.expectEqualSlices(f64, &.{ 8.0, 3.0 }, same.ground_cap.reference.items);
    try testing.expectEqualSlices([2]u32, &.{.{ 0, 1 }}, same.coupling.key.items);
    try testing.expectEqualSlices(f64, &.{1.0}, same.coupling.reference.items);
}

test "parallel resistors halve the resistance" {
    // Oracle: law. Two equal resistors in parallel are half of one: half the
    // pin-to-pin resistance and half the delay; net 0 is untouched.
    var reference = try ladder(1.0, 1.0);
    defer reference.deinit(gpa);
    var twice = try ladder(1.0, 1.0);
    defer twice.deinit(gpa);
    try twice.push(gpa, .at(5), .at(6), .resistance, 5.0);
    try twice.sortCanonical(gpa);
    var out = try compared(&reference, &twice);
    defer out.deinit(gpa);
    try testing.expectApproxEqAbs(2.5, out.resistance.candidate.items[1], 1e-9);
    try testing.expectApproxEqAbs(10.0, out.delay.candidate.items[1], 1e-9);
    try testing.expectEqual(@as(u64, @bitCast(out.resistance.reference.items[0])), @as(u64, @bitCast(out.resistance.candidate.items[0])));
}

test "scaling an extraction scales its errors" {
    // Oracle: metamorphic. Against itself every error is 0; with every C
    // 10 % larger every C metric is 10 % off and R not at all; with every R
    // 20 % larger too, the delay is `1.2 · 1.1 − 1 = 32 %` off.
    var reference = try ladder(1.0, 1.0);
    defer reference.deinit(gpa);
    var same = try compared(&reference, &reference);
    defer same.deinit(gpa);
    for ([_]compare.Errors{ errorsOf(same.total_cap, 0.0, 1e-9), errorsOf(same.resistance, 0.0, 1e-9), errorsOf(same.delay, 0.0, 1e-9), errorsOf(same.coupling, 0.0, 1e-9) }) |e| {
        try testing.expectEqual(0.0, e.worst);
        try testing.expectEqual(e.count, e.within);
    }
    var bigger = try ladder(1.2, 1.1);
    defer bigger.deinit(gpa);
    var scaled = try compared(&reference, &bigger);
    defer scaled.deinit(gpa);
    const cases = [_]struct { compare.Errors, f64 }{
        .{ errorsOf(scaled.total_cap, 0.5, 1e-9), 0.1 },
        .{ errorsOf(scaled.ground_cap, 0.5, 1e-9), 0.1 },
        .{ errorsOf(scaled.coupling, 0.5, 1e-9), 0.1 },
        .{ errorsOf(scaled.resistance, 0.5, 1e-9), 0.2 },
        .{ errorsOf(scaled.delay, 0.5, 1e-9), 0.32 },
    };
    for (cases) |c| {
        try testing.expectApproxEqAbs(c[1], c[0].worst, 1e-12);
        try testing.expectApproxEqAbs(c[1], c[0].mean, 1e-12);
        try testing.expectApproxEqAbs(c[1], c[0].rms, 1e-12);
    }
}

test "errors count only rows above the floor" {
    // Oracle: hand-derived. Rows 0 and 1 are 5 % and −10 % off; row 2 is
    // below the 0.01 floor on both sides and row 3 zero on both, so neither
    // counts. At 6 % one of two is within; worst row 1's −10 %, mean 7.5 %,
    // RMS `√((0.05² + 0.1²)/2)`.
    const e = compare.errors(&.{ 1.0, 2.0, 0.001, 0.0 }, &.{ 1.05, 1.8, 0.002, 0.0 }, 0.06, 0.01);
    try testing.expectEqual(2, e.count);
    try testing.expectEqual(1, e.within);
    try testing.expectEqual(1, e.worst_row.?);
    try testing.expectApproxEqAbs(-0.1, e.worst, 1e-12);
    try testing.expectApproxEqAbs(0.075, e.mean, 1e-12);
    try testing.expectApproxEqAbs(@sqrt((0.05 * 0.05 + 0.1 * 0.1) / 2.0), e.rms, 1e-12);
}

test "a net in one extraction only is named" {
    // Oracle: construct-from-answer. A net only one extraction holds is
    // named as such and compared in no metric.
    var reference = try ladder(1.0, 1.0);
    defer reference.deinit(gpa);
    var fewer = try ladder(1.0, 1.0);
    defer fewer.deinit(gpa);
    fewer.node_net.shrinkRetainingCapacity(5);
    fewer.node_layer.shrinkRetainingCapacity(5);
    var kept: usize = 0;
    for (0..fewer.elementCount()) |row| {
        const to = fewer.to.items[row];
        if (@backingInt(fewer.from.items[row]) >= 5 or (to != .ground and @backingInt(to) >= 5)) continue;
        inline for (.{ "from", "to", "kind", "value" }) |f| @field(fewer, f).items[kept] = @field(fewer, f).items[row];
        kept += 1;
    }
    inline for (.{ "from", "to", "kind", "value" }) |f| @field(fewer, f).shrinkRetainingCapacity(kept);
    var out = try compared(&reference, &fewer);
    defer out.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{1}, out.only_reference.items);
    try testing.expectEqual(0, out.only_candidate.items.len);
    try testing.expectEqual(0, out.coupling.key.items.len);
    try testing.expectEqualSlices(u32, &.{0}, out.total_cap.key.items);
}
