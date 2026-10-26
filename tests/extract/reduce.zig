//! PEX-008: the deck's extraction type applied to a network whose every
//! reduction is worked out by hand. Ported from
//! crates/extract/tests/pex/reduce.rs.
//!
//! Contents: helpers `Element`, `network`, `reduced`, `ofKind`, `holdsEveryTotal`; then the tests.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const extract = @import("extract");
const net_mod = extract.network;
const NodeId = net_mod.NodeId;
const ParasiticNetwork = net_mod.ParasiticNetwork;
const gpa = testing.allocator;

const Element = struct { from: u32, to: ?u32, value: f64 };

/// Each net's total capacitance, worked out in `network`.
const totals = [_]f64{ 4.05, 3.925, 4.875 };

const series = [_]net_mod.Kind{ .resistance, .inductance, .mutual_inductance };

// ---- private ----

/// Three nets: net 0 on nodes 0 and 1, net 1 on 2 and 3, net 2 on 4.
/// Ground 1, 2, 3, 0.5 and 4 fF on nodes 0 to 4; coupling 0.25 fF 0–2,
/// 0.05 1–3, 0.75 1–4, 0.125 3–4; 10 and 20 Ω along nets 0 and 1, 5 pH on
/// net 0 and a 1 pH mutual to net 1. Per net: 1 + 2 + 0.25 + 0.05 + 0.75 =
/// 4.05 fF, 3 + 0.5 + 0.25 + 0.05 + 0.125 = 3.925, 4 + 0.75 + 0.125 = 4.875.
fn network() !ParasiticNetwork {
    var out: ParasiticNetwork = .empty;
    errdefer out.deinit(gpa);
    try out.node_net.appendSlice(gpa, &.{ 0, 0, 1, 1, 2 });
    try out.node_layer.appendNTimes(gpa, @fromBackingInt(0), 5);
    for ([_]f64{ 1.0, 2.0, 3.0, 0.5, 4.0 }, 0..) |ff, node| try out.push(gpa, .at(node), .ground, .ground_cap, ff);
    for ([_]struct { u32, u32, f64 }{ .{ 0, 2, 0.25 }, .{ 1, 3, 0.05 }, .{ 1, 4, 0.75 }, .{ 3, 4, 0.125 } }) |c| try out.push(gpa, .at(c[0]), .at(c[1]), .coupling_cap, c[2]);
    try out.push(gpa, .at(0), .at(1), .resistance, 10.0);
    try out.push(gpa, .at(2), .at(3), .resistance, 20.0);
    try out.push(gpa, .at(0), .at(1), .inductance, 5.0);
    try out.push(gpa, .at(0), .at(2), .mutual_inductance, 1.0);
    try out.sortCanonical(gpa);
    return out;
}

fn reduced(kind: ingest.deck.ExtractionKind, threshold_ff: f64) !ParasiticNetwork {
    var out = try network();
    errdefer out.deinit(gpa);
    try extract.reduce.reduce(gpa, &out, .{ .kind = kind, .coupling_threshold_af = threshold_ff * 1e3 });
    return out;
}

/// Every element whose kind is in `kinds`, in element order.
fn ofKind(n: *const ParasiticNetwork, kinds: []const net_mod.Kind, out: *std.ArrayList(Element)) !void {
    out.clearRetainingCapacity();
    for (n.from.items, n.to.items, n.kind.items, n.value.items) |from, to, kind, value| {
        if (std.mem.findScalar(net_mod.Kind, kinds, kind) == null) continue;
        try out.append(gpa, .{ .from = @backingInt(from), .to = if (to == .ground) null else @backingInt(to), .value = value });
    }
}

fn expectSeriesKept(n: *const ParasiticNetwork) !void {
    var want = try network();
    defer want.deinit(gpa);
    var a: std.ArrayList(Element) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(Element) = .empty;
    defer b.deinit(gpa);
    try ofKind(n, &series, &a);
    try ofKind(&want, &series, &b);
    try testing.expectEqualSlices(Element, b.items, a.items);
}

/// Every net's total against `totals`: grounding moves a coupling to ground
/// on both its nets, and lumping only adds.
fn holdsEveryTotal(n: *const ParasiticNetwork) !void {
    var got: std.ArrayList(f64) = .empty;
    defer got.deinit(gpa);
    try n.capacitancePerNetInto(gpa, &got);
    for (totals, got.items) |want, g| try testing.expectApproxEqAbs(want, g, 1e-12);
}

fn count(n: *const ParasiticNetwork, kind: net_mod.Kind) usize {
    return std.mem.count(net_mod.Kind, n.kind.items, &.{kind});
}

test "rcc keeps the whole network" {
    // Oracle: law. `rcc` without a threshold is the identity on a canonical network.
    var got = try reduced(.rcc, 0.0);
    defer got.deinit(gpa);
    var want = try network();
    defer want.deinit(gpa);
    inline for (.{ "node_net", "node_layer", "from", "to", "kind", "value" }) |f| try testing.expectEqualSlices(@TypeOf(@field(want, f).items[0]), @field(want, f).items, @field(got, f).items);
}

test "a coupling below the threshold is grounded on both ends" {
    // Oracle: hand-derived (OpenRCX: "coupling below this threshold is
    // grounded", strictly below). At 0.125 fF the 0.05 fF coupling 1–3
    // becomes 0.05 fF to ground on each, the 0.125 fF one stays, and every
    // total holds.
    var out = try reduced(.rcc, 0.125);
    defer out.deinit(gpa);
    var got: std.ArrayList(Element) = .empty;
    defer got.deinit(gpa);
    try ofKind(&out, &.{.coupling_cap}, &got);
    try testing.expectEqualSlices(Element, &.{ .{ .from = 0, .to = 2, .value = 0.25 }, .{ .from = 1, .to = 4, .value = 0.75 }, .{ .from = 3, .to = 4, .value = 0.125 } }, got.items);
    try ofKind(&out, &.{.ground_cap}, &got);
    try testing.expectEqual(7, got.items.len);
    for ([_]u32{ 1, 3 }) |node| {
        var found = false;
        for (got.items) |e| found = found or (e.from == node and e.to == null and e.value == 0.05);
        try testing.expect(found);
    }
    try expectSeriesKept(&out);
    try holdsEveryTotal(&out);
}

test "rc grounds every coupling and keeps the series elements" {
    // Oracle: hand-derived (Calibre's RC). Every coupling grounded at both
    // ends, totals held, R and L kept, nodes unchanged.
    var out = try reduced(.rc, 0.0);
    defer out.deinit(gpa);
    try testing.expectEqual(0, count(&out, .coupling_cap));
    try testing.expectEqual(5 + 2 * 4, count(&out, .ground_cap));
    try expectSeriesKept(&out);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 2 }, out.node_net.items);
    try holdsEveryTotal(&out);
}

test "r keeps resistance and inductance alone" {
    // Oracle: hand-derived (Calibre's R). No capacitance is left.
    var out = try reduced(.r, 0.0);
    defer out.deinit(gpa);
    try testing.expectEqual(0, count(&out, .ground_cap) + count(&out, .coupling_cap));
    try expectSeriesKept(&out);
    var got: std.ArrayList(f64) = .empty;
    defer got.deinit(gpa);
    try out.capacitancePerNetInto(gpa, &got);
    for (got.items) |c| try testing.expectEqual(0.0, c);
}

test "cc lumps each net and sums its couplings per pair" {
    // Oracle: hand-derived (Calibre's C+CC). One node per net; grounds 3,
    // 3.5 and 4 fF; couplings 0.25 + 0.05 between nets 0 and 1, 0.75 and
    // 0.125; no R or L.
    var out = try reduced(.cc, 0.0);
    defer out.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, out.node_net.items);
    var got: std.ArrayList(Element) = .empty;
    defer got.deinit(gpa);
    try ofKind(&out, &.{.ground_cap}, &got);
    try testing.expectEqualSlices(Element, &.{ .{ .from = 0, .to = null, .value = 3.0 }, .{ .from = 1, .to = null, .value = 3.5 }, .{ .from = 2, .to = null, .value = 4.0 } }, got.items);
    try ofKind(&out, &.{.coupling_cap}, &got);
    try testing.expectEqual(3, got.items.len);
    for (got.items, [_]Element{ .{ .from = 0, .to = 1, .value = 0.3 }, .{ .from = 0, .to = 2, .value = 0.75 }, .{ .from = 1, .to = 2, .value = 0.125 } }) |g, w| {
        try testing.expectEqual(w.from, g.from);
        try testing.expectEqual(w.to, g.to);
        try testing.expectApproxEqAbs(w.value, g.value, 1e-12);
    }
    try testing.expectEqual(0, count(&out, .resistance) + count(&out, .inductance) + count(&out, .mutual_inductance));
    try holdsEveryTotal(&out);
}

test "c is one capacitance to ground per net" {
    // Oracle: hand-derived (lumped C). One node and one element per net,
    // its total; a threshold changes nothing, no coupling being kept.
    for ([_]f64{ 0.0, 0.1 }) |threshold| {
        var out = try reduced(.c, threshold);
        defer out.deinit(gpa);
        try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, out.node_net.items);
        try testing.expectEqual(3, out.elementCount());
        for (out.from.items, out.to.items, out.value.items, 0..) |from, to, value, net| {
            try testing.expectEqual(NodeId.at(net), from);
            try testing.expectEqual(NodeId.ground, to);
            try testing.expectApproxEqAbs(totals[net], value, 1e-12);
        }
    }
}
