//! Closed-form extraction, asked of the network the extractor emits. Ported
//! from crates/extract/tests/pex/analytical.rs and analytical.rs's
//! `node_rects` test. The scale corpus is fixture.zig's `scaleComb`; nets
//! are stated with their shapes (construct-from-answer: the Rust tests ran
//! check's net extraction, whose answer here is known by construction).
//!
//! Contents: helpers `Conn`, `extractInto`, `run`, `sumOf`, `totalCapacitance`,
//! `serialise`; then the tests.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const extract = @import("extract");
const fixture = @import("fixture.zig");
const Box = fixture.Box;
const Case = fixture.Case;
const Rows = fixture.Rows;
const analytical = extract.analytical;
const network = extract.network;
const NodeId = network.NodeId;
const ParasiticNetwork = network.ParasiticNetwork;
const gpa = testing.allocator;

/// The lateral coupling reach, in thicknesses: the shipped decks'
/// `coupling_halo`.
const halo: f64 = 10.0;

/// A deck's `connect` lines; `.{}` is Rust's `Connectivity::default()`.
const Conn = struct {
    conductors: []const geom.LayerId = &.{},
    global: []const geom.LayerId = &.{},
    vias: extract.Vias = .{ .cut = &.{}, .connects = &.{} },
};

const via_conn: Conn = .{
    .conductors = &.{ @fromBackingInt(0), @fromBackingInt(2) },
    .vias = .{ .cut = &.{@fromBackingInt(1)}, .connects = &.{.{ @fromBackingInt(0), @fromBackingInt(2) }} },
};

// ---- private ----

fn extractInto(c: *const Case, stack: extract.Stack, conn: Conn, out: *ParasiticNetwork, refusal: *analytical.Refusal) analytical.Error!void {
    const problem: analytical.Problem = .{ .store = &c.store, .nets = &c.nets, .conductors = conn.conductors, .global = conn.global, .vias = conn.vias, .stack = stack, .halo = halo, .grid = fixture.grid };
    return analytical.extractInto(gpa, problem, out, refusal);
}

fn run(c: *const Case, stack: extract.Stack, conn: Conn, out: *ParasiticNetwork) !void {
    var refusal: analytical.Refusal = .{};
    try extractInto(c, stack, conn, out, &refusal);
}

/// Every element of `kind`, summed in element order.
fn sumOf(n: *const ParasiticNetwork, kind: network.Kind) f64 {
    var total: f64 = 0.0;
    for (n.kind.items, n.value.items) |k, v| {
        if (k == kind) total += v;
    }
    return total;
}

fn totalCapacitance(n: *const ParasiticNetwork) f64 {
    return sumOf(n, .ground_cap) + sumOf(n, .coupling_cap);
}

fn serialise(n: *const ParasiticNetwork, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.node_net.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.node_layer.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.from.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.to.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.kind.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(n.value.items));
}

/// One-row stack: Rust's `uniform_stack(1, area, fringe)`.
fn oneRow(area: f64, fringe: f64) Rows {
    return fixture.uniformRows(area, fringe);
}

/// Plates on layers 0 and 2, one net, `cuts` cuts on layer 1 between them
/// on no net.
fn viaStack(cuts: i64) !Case {
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(gpa);
    try boxes.append(gpa, .{ .layer = 0, .net = 0, .r = .{ 0, 0, 1_000, 200 } });
    try boxes.append(gpa, .{ .layer = 2, .net = 0, .r = .{ 0, 0, 1_000, 200 } });
    for (0..@intCast(cuts)) |i| {
        const x: i64 = 100 + 200 * @as(i64, @intCast(i));
        try boxes.append(gpa, .{ .layer = 1, .net = extract.none, .r = .{ x, 50, x + 100, 150 } });
    }
    return Case.init(boxes.items, &.{}, 3);
}

/// 0.1 Ω/□ plates and 5 Ω cuts.
fn viaRows() Rows {
    var r = oneRow(0.0, 0.0);
    r.sheet = .{ 0.1, 5.0, 0.1 };
    return r;
}

/// One via stack's resistance less its two plates (each 1000 × 200 nm, five
/// squares at 0.1 Ω/□, half an ohm).
fn viaResistanceOf(cuts: i64) !f64 {
    var c = try viaStack(cuts);
    defer c.deinit();
    const rows = viaRows();
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try run(&c, rows.stack(), via_conn, &n);
    return sumOf(&n, .resistance) - 2.0 * 0.1 * 5.0;
}

test "extracted capacitance is linear in the deck's capacitive coefficients" {
    // Oracle: law. Tripling both coefficients triples the total, on a
    // single-net corpus (no second net to couple to); the total is first
    // asserted positive, so an extractor emitting nothing cannot pass.
    var c = try fixture.scaleComb(1, 3);
    defer c.deinit();
    var single: ParasiticNetwork = .empty;
    defer single.deinit(gpa);
    var tripled: ParasiticNetwork = .empty;
    defer tripled.deinit(gpa);
    const one = oneRow(1.0, 0.25);
    const three = oneRow(3.0, 0.75);
    try run(&c, one.stack(), .{}, &single);
    try run(&c, three.stack(), .{}, &tripled);
    const base = totalCapacitance(&single);
    try testing.expect(base > 0.0);
    try testing.expectApproxEqRel(3.0 * base, totalCapacitance(&tripled), 1e-12);
}

test "a net of one polygon still carries that polygon's resistance" {
    // Oracle: closed form (F10). A 2000 × 200 nm rectangle at 0.1 Ω/□ is
    // ten squares, one ohm, through the network.
    var c = try Case.init(&.{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 2_000, 200 } }}, &.{}, 1);
    defer c.deinit();
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    const rows = oneRow(0.0, 0.0);
    try run(&c, rows.stack(), .{}, &n);
    try testing.expectApproxEqAbs(1.0, sumOf(&n, .resistance), 1e-12);
}

test "the resistance a network emits is the sum of its conductors' resistances" {
    // Oracle: law (conservation) against the formula: three rectangles of
    // different aspect ratios, apart, each `0.1 × long/short`.
    const sides = [_][2]i64{ .{ 2_000, 200 }, .{ 5_000, 100 }, .{ 300, 300 } };
    var boxes: [3]Box = undefined;
    var want: f64 = 0.0;
    for (sides, 0..) |s, i| {
        const x: i64 = 10_000 * @as(i64, @intCast(i));
        boxes[i] = .{ .layer = 0, .net = @intCast(i), .r = .{ x, 0, x + s[0], s[1] } };
        want += 0.1 * @as(f64, @floatFromInt(@max(s[0], s[1]))) / @as(f64, @floatFromInt(@min(s[0], s[1])));
    }
    var c = try Case.init(&boxes, &.{}, 1);
    defer c.deinit();
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    const rows = oneRow(0.0, 0.0);
    try run(&c, rows.stack(), .{}, &n);
    try testing.expectApproxEqAbs(want, sumOf(&n, .resistance), 1e-12);
}

test "a conductor drawn as several polygons is its merged outline" {
    // Oracle: closed form (F44). An L of a 2000 × 200 and a 200 × 1000 bar
    // overlapping at the corner: A = 560 000, P = 6000, the 2800 × 200
    // rectangle, 1.4 Ω; a 3000 × 1000 bar in four 750 nm pieces: 0.3 Ω. At
    // 1 aF/µm² and 1 aF/µm the ground C is the outline's `A + P`: 0.56 + 6
    // and 3 + 8 aF.
    const l = [_]Box{ .{ .layer = 0, .net = 0, .r = .{ 0, 0, 2_000, 200 } }, .{ .layer = 0, .net = 0, .r = .{ 1_800, 0, 2_000, 1_000 } } };
    var bar: [4]Box = undefined;
    for (&bar, 0..) |*b, i| {
        const x: i64 = 750 * @as(i64, @intCast(i));
        b.* = .{ .layer = 0, .net = 0, .r = .{ x, 0, x + 750, 1_000 } };
    }
    const cases = [_]struct { boxes: []const Box, ohm: f64, af: f64 }{
        .{ .boxes = &l, .ohm = 1.4, .af = 0.56 + 6.0 },
        .{ .boxes = &bar, .ohm = 0.3, .af = 3.0 + 8.0 },
    };
    const rows = oneRow(1.0, 1.0);
    for (cases) |case| {
        var c = try Case.init(case.boxes, &.{}, 1);
        defer c.deinit();
        var n: ParasiticNetwork = .empty;
        defer n.deinit(gpa);
        try run(&c, rows.stack(), .{}, &n);
        try testing.expectApproxEqAbs(case.ohm, sumOf(&n, .resistance), 1e-12);
        try testing.expectApproxEqAbs(case.af / 1e3, totalCapacitance(&n), 1e-15);
    }
}

test "a conductor with a diagonal edge is refused" {
    // Oracle: definition. A 45-degree edge cannot be cut into rectangles
    // exactly, so the layer is refused, not approximated.
    var c = try Case.init(&.{}, &.{.{ .layer = 0, .net = 0, .xs = &.{ 0, 200, 300, 100 }, .ys = &.{ 0, 0, 100, 100 } }}, 1);
    defer c.deinit();
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    const rows = oneRow(1.0, 1.0);
    var refusal: analytical.Refusal = .{};
    try testing.expectError(error.InvalidGeometry, extractInto(&c, rows.stack(), .{}, &n, &refusal));
    try testing.expectEqual(0, @backingInt(refusal.layer));
}

test "a conductor with no pex row is refused not read as a perfect wire" {
    // Oracle: definition (F30). No row, or a row with no sheet resistance,
    // is unknown R and C, refused by layer.
    var c = try Case.init(&.{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 2_000, 200 } }}, &.{}, 1);
    defer c.deinit();
    var zero = oneRow(1.0, 1.0);
    zero.sheet = @splat(0.0);
    const empty: extract.Stack = .{ .thickness_nm = &.{}, .height_nm = &.{}, .sheet_res_ohm_sq = &.{}, .area_cap_af_um2 = &.{}, .fringe_cap_af_um = &.{}, .dielectric_k = &.{} };
    for ([_]extract.Stack{ empty, zero.stack() }) |stack| {
        var n: ParasiticNetwork = .empty;
        defer n.deinit(gpa);
        var refusal: analytical.Refusal = .{ .layer = @fromBackingInt(9) };
        try testing.expectError(error.Undescribed, extractInto(&c, stack, .{}, &n, &refusal));
        try testing.expectEqual(0, @backingInt(refusal.layer));
    }
}

test "a via layer with no pex row is refused and a global layer needs none" {
    // Oracle: definition (F30). A via layer joining two plates with no
    // resistance per cut is refused, not a short; with the upper plate a
    // global layer and no row for it, only the lower plate's five squares
    // remain, 0.5 Ω.
    var c = try viaStack(2);
    defer c.deinit();
    var rows = viaRows();
    rows.sheet[1] = 0.0;
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    var refusal: analytical.Refusal = .{};
    try testing.expectError(error.UndescribedVia, extractInto(&c, rows.stack(), via_conn, &n, &refusal));
    try testing.expectEqual(1, @backingInt(refusal.layer));
    rows.sheet[2] = 0.0;
    const global: Conn = .{ .conductors = &.{@fromBackingInt(0)}, .global = &.{@fromBackingInt(2)}, .vias = via_conn.vias };
    try run(&c, rows.stack(), global, &n);
    try testing.expectApproxEqAbs(0.5, sumOf(&n, .resistance), 1e-12);
}

test "one cut between two plates contributes its own resistance" {
    // Oracle: closed form (F11): one 5 Ω cut is 5 Ω.
    try testing.expectApproxEqAbs(5.0, try viaResistanceOf(1), 1e-12);
}

test "a via array extracts its cuts in parallel not in series" {
    // Oracle: law. `n` cuts of one array are `1/n` of one, over a range.
    const one = try viaResistanceOf(1);
    try testing.expect(one > 0.0);
    for (2..6) |cuts| try testing.expectApproxEqRel(one, try viaResistanceOf(@intCast(cuts)) * @as(f64, @floatFromInt(cuts)), 1e-12);
}

test "every extracted resistance is positive and at least one exists" {
    // Oracle: law. A comb on a resistive layer has resistance, and none is
    // zero, negative or non-finite: that would be a short.
    var c = try fixture.scaleComb(2, 9);
    defer c.deinit();
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    const rows = oneRow(1.0, 0.25);
    try run(&c, rows.stack(), .{}, &n);
    var count: usize = 0;
    for (n.kind.items, n.value.items) |k, v| {
        if (k != .resistance) continue;
        count += 1;
        try testing.expect(v > 0.0 and std.math.isFinite(v));
    }
    try testing.expect(count > 0);
}

test "extracted elements name real nodes and order every coupling by net" {
    // Oracle: law. Every element's nodes exist, none joins a node to itself,
    // and every coupling runs from the lower net to the higher. Run on the
    // corpus's own connectivity too, so couplings exist to check.
    var c = try fixture.scaleComb(2, 24);
    defer c.deinit();
    const rows = oneRow(1.0, 0.25);
    const corpus: Conn = .{ .conductors = &fixture.comb_conductors, .vias = fixture.comb_vias };
    var couplings: usize = 0;
    for ([_]Conn{ .{}, corpus }) |conn| {
        var n: ParasiticNetwork = .empty;
        defer n.deinit(gpa);
        try run(&c, rows.stack(), conn, &n);
        const nodes = n.nodeCount();
        try testing.expect(nodes > 0 and n.elementCount() > 0);
        for (n.from.items, n.to.items, n.kind.items) |from, to, kind| {
            try testing.expect(@backingInt(from) < nodes);
            if (to == .ground) continue;
            try testing.expect(@backingInt(to) < nodes and from != to);
            if (kind != .coupling_cap) continue;
            couplings += 1;
            try testing.expect(n.node_net.items[@backingInt(from)] < n.node_net.items[@backingInt(to)]);
        }
    }
    try testing.expect(couplings > 0);
}

test "per net capacitance sums to the total plus the coupling counted twice" {
    // Oracle: law. Per-net capacitance counts a coupling on both its nets,
    // the network total once; the nets summed are read from the network's
    // own node column.
    var c = try fixture.scaleComb(3, 24);
    defer c.deinit();
    const rows = oneRow(1.0, 0.25);
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try run(&c, rows.stack(), .{ .conductors = &fixture.comb_conductors, .vias = fixture.comb_vias }, &n);
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try n.capacitancePerNetInto(gpa, &totals);
    var per_net: f64 = 0.0;
    for (n.node_net.items, 0..) |net, i| {
        if (i == 0 or n.node_net.items[i - 1] != net) per_net += totals.items[net];
    }
    const total = totalCapacitance(&n);
    try testing.expect(total > 0.0 and sumOf(&n, .coupling_cap) > 0.0);
    try testing.expectApproxEqRel(total + sumOf(&n, .coupling_cap), per_net, 1e-9);
}

test "extraction emits the order sort canonical would have produced" {
    // Oracle: law. Sorting an extraction moves no byte.
    var c = try fixture.scaleComb(2, 24);
    defer c.deinit();
    const rows = oneRow(1.0, 0.25);
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try run(&c, rows.stack(), .{ .conductors = &fixture.comb_conductors, .vias = fixture.comb_vias }, &n);
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(gpa);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(gpa);
    try serialise(&n, &before);
    try n.sortCanonical(gpa);
    try serialise(&n, &after);
    try testing.expectEqualSlices(u8, before.items, after.items);
}

test "extraction is byte identical across runs and across a reused buffer" {
    // Oracle: determinism. Twice into fresh buffers, then again into a used
    // one: an append shows up only in the last.
    var c = try fixture.scaleComb(2, 24);
    defer c.deinit();
    const rows = oneRow(1.4, 0.35);
    const conn: Conn = .{ .conductors = &fixture.comb_conductors, .vias = fixture.comb_vias };
    var fresh: ParasiticNetwork = .empty;
    defer fresh.deinit(gpa);
    try run(&c, rows.stack(), conn, &fresh);
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(gpa);
    try serialise(&fresh, &first);
    var again: ParasiticNetwork = .empty;
    defer again.deinit(gpa);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (0..2) |_| {
        try run(&c, rows.stack(), conn, &again);
        try serialise(&again, &bytes);
        try testing.expectEqualSlices(u8, first.items, bytes.items);
    }
}

test "node rects names the nodes extract into allocates" {
    // Oracle: definition (F93). Net X is a bar of two abutting pieces (one
    // region) and a piece meeting it only at a corner (a second region), so
    // X has nodes 0 and 1 and closes on 2; Y, one bar, is node 3 and closes
    // on 4. One node per drawn polygon would have put Y's bar on node 4.
    const boxes = [_]Box{
        .{ .layer = 0, .net = 0, .r = .{ 0, 0, 4, 1 } },
        .{ .layer = 0, .net = 0, .r = .{ 4, 0, 8, 1 } },
        .{ .layer = 0, .net = 0, .r = .{ 8, 1, 12, 2 } },
        .{ .layer = 0, .net = 1, .r = .{ 0, 3, 4, 4 } },
    };
    var c = try Case.init(&boxes, &.{}, 1);
    defer c.deinit();
    var rows = oneRow(1.0, 1.0);
    rows.thickness = @splat(1.0);
    rows.height = @splat(1.0);
    rows.k = @splat(0.0);
    rows.sheet = @splat(1.0);
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    try run(&c, rows.stack(), .{ .conductors = &.{@fromBackingInt(0)} }, &n);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 1 }, n.node_net.items);
    var node: std.ArrayList(NodeId) = .empty;
    defer node.deinit(gpa);
    var rect: std.ArrayList(geom.Bbox) = .empty;
    defer rect.deinit(gpa);
    var refusal: analytical.Refusal = .{};
    const problem: analytical.Problem = .{ .store = &c.store, .nets = &c.nets, .conductors = &.{}, .global = &.{}, .vias = .{ .cut = &.{}, .connects = &.{} }, .stack = rows.stack(), .halo = halo, .grid = fixture.grid };
    try analytical.nodeRectsInto(gpa, problem, &node, &rect, &refusal);
    try testing.expectEqualSlices(NodeId, &.{ .at(0), .at(1), .at(3) }, node.items);
    try testing.expectEqualSlices(geom.Bbox, &.{
        .{ .xlo = 0, .ylo = 0, .xhi = 8, .yhi = 1 },
        .{ .xlo = 8, .ylo = 1, .xhi = 12, .yhi = 2 },
        .{ .xlo = 0, .ylo = 3, .xhi = 4, .yhi = 4 },
    }, rect.items);
}
