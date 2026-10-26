//! Through-silicon vias on an extracted network. Ported from
//! tests/engine/def.rs's `a_through_silicon_via_adds_its_liner_capacitance`
//! at the extract level: the DEF's shapes are drawn here, their one net
//! stated (construct-from-answer).
//!
//! Contents: the test.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const fixture = @import("fixture.zig");
const Box = fixture.Box;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;

test "a through silicon via adds its liner capacitance" {
    // Oracle: closed form (Katti et al., IEEE TED 57(1), 2010, eq. 2): a 5 ×
    // 5 µm cut is a cylinder of radius `5/√π` µm; 50 µm long in a 0.2 µm
    // liner of k = 3.9 it is `2π ε₀ k L / ln((r + t)/r)` to ground, and two
    // of them twice that. The plates carry no capacitance of their own and
    // one net couples to nothing, so the net's capacitance is the liners'.
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(gpa);
    try boxes.append(gpa, .{ .layer = 0, .net = 0, .r = .{ 7_000, 7_000, 33_000, 13_000 } });
    for ([_]i64{ 10_000, 30_000 }) |x| {
        try boxes.append(gpa, .{ .layer = 0, .net = 0, .r = .{ x - 3_000, 7_000, x + 3_000, 13_000 } });
        try boxes.append(gpa, .{ .layer = 1, .net = extract.none, .r = .{ x - 2_500, 7_500, x + 2_500, 12_500 } });
        try boxes.append(gpa, .{ .layer = 2, .net = 0, .r = .{ x - 3_000, 7_000, x + 3_000, 13_000 } });
    }
    var c = try fixture.Case.init(boxes.items, &.{}, 3);
    defer c.deinit();
    const rows: fixture.Rows = .of(
        .{ .thickness = 100, .height = 1000, .sheet = 0.1, .k = 3.9, .area = 0, .fringe = 0 },
        .{ .thickness = 100, .height = 1100, .sheet = 0.05, .k = 3.9, .area = 0, .fringe = 0 },
        .{ .thickness = 100, .height = 1200, .sheet = 0.1, .k = 3.9, .area = 0, .fringe = 0 },
    );
    const vias: extract.Vias = .{ .cut = &.{@fromBackingInt(1)}, .connects = &.{.{ @fromBackingInt(0), @fromBackingInt(2) }} };
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    var refusal: extract.analytical.Refusal = .{};
    try extract.analytical.extractInto(gpa, .{ .store = &c.store, .nets = &c.nets, .conductors = &.{ @fromBackingInt(0), @fromBackingInt(2) }, .global = &.{}, .vias = vias, .stack = rows.stack(), .halo = 10.0, .grid = fixture.grid }, &n, &refusal);
    const tsv: extract.tsv.Tsv = .{ .layer = @fromBackingInt(1), .length_nm = 50_000, .liner_nm = 200, .liner_k = 3.9 };
    try extract.tsv.addInto(gpa, &n, &c.store, c.poly_net, vias, &.{tsv}, fixture.grid);
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try n.capacitancePerNetInto(gpa, &totals);
    const r = 5.0 / @sqrt(std.math.pi);
    const one = 2.0 * std.math.pi * 8.8541878128e-3 * 3.9 * 50.0 / @log((r + 0.2) / r);
    try testing.expectApproxEqRel(2.0 * one, totals.items[0], 1e-12);
}
