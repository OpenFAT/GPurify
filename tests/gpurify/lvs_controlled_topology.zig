//! The deck's `lvs` statements (deck.md, "LVS controls") on topology and
//! values: relaxed parallel and series merges, inductors, logic-gate
//! recognition, a diode's area, `max_res` and `min_caps`, `same_nets`, and
//! absolute tolerances on a passive's value, each verdict the oracle's
//! under the statements the fixture's deck adds. Ported from
//! tests/exhaustive/lvs.rs (`controlled`, its second half; the
//! `lde_fixtures` it extends with are ported beside `lde_fixtures`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const circuit = @import("lvs_circuit.zig");
const Model = circuit.Model;
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const controls_ = @import("lvs_controls.zig");
const Controls = controls_.Controls;
const fixture = @import("lvs_fixture.zig");

/// A case: a name, the layout and the reference circuit.
const Pair = struct { []const u8, Circuit, Circuit };

/// A case: a name, the layout and reference circuits, and the controls.
const Case = struct { []const u8, Circuit, Circuit, Controls };

const relaxed: Controls = .{ .relaxed = true };

/// A policy's label and controls.
const Policy = struct { []const u8, Controls };

const relaxed_or_strict = [_]Policy{ .{ "relaxed", relaxed }, .{ "strict", .{} } };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try topologyInto(arena, out);
    try seriesInto(arena, out);
    try inductorsInto(arena, out);
    try gatesInto(arena, out);
    try diodesInto(arena, out);
    try thresholdsInto(arena, out);
    try sameNetsInto(arena, out);
    try passiveToleranceInto(arena, out);
}

// ---- private ----

/// Each pair under `policies`, named `prefix/name/label`.
fn policiesInto(arena: Allocator, prefix: []const u8, catalog: []const []const u8, pairs: []const Pair, policies: []const Policy, out: *std.ArrayList(Fixture)) !void {
    for (pairs) |p| for (policies) |pol| {
        try out.append(arena, try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ prefix, p[0], pol[0] }), catalog, &p[1], &p[2], &pol[1]));
    };
}

fn card(arena: Allocator, dev: Dev) !Circuit {
    return Circuit.init(arena, 2, &.{dev});
}

fn parallel(arena: Allocator, model: Model, count: usize) !Circuit {
    const devs = try arena.alloc(Dev, count);
    @memset(devs, Dev.onPins(model, &.{ 0, 1 }));
    return Circuit.init(arena, 2, devs);
}

/// LVS-043, LVS-044, LVS-049: relaxed topology. Two resistors drawn in
/// parallel, 200 ohm each (`measured`), are one of 100 ohm, and two
/// capacitors of 0.56 fF one of 1.12 fF, three one of 1.68 fF; a card's
/// `m` folds in first, so `r=200 m=2` is 100 ohm. Strict, the default, they
/// are two that match only a count of two. A card with no value keeps the
/// count either way.
fn topologyInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const pairs = [_]Pair{
        .{ "R_two_vs_half", try parallel(arena, .r, 2), try card(arena, Dev.onPins(.r, &.{ 0, 1 }).valued(100.0)) },
        .{ "R_two_vs_m2", try parallel(arena, .r, 2), try card(arena, Dev.onPins(.r, &.{ 0, 1 }).valued(200.0).times(2)) },
        .{ "R_two_vs_one", try parallel(arena, .r, 2), try card(arena, Dev.onPins(.r, &.{ 0, 1 }).valued(200.0)) },
        .{ "R_two_vs_unvalued_one", try parallel(arena, .r, 2), try card(arena, Dev.onPins(.r, &.{ 0, 1 })) },
        .{ "C_two_vs_double", try parallel(arena, .c, 2), try card(arena, Dev.onPins(.c, &.{ 0, 1 }).valued(1.12e-15)) },
        .{ "C_two_vs_m2", try parallel(arena, .c, 2), try card(arena, Dev.onPins(.c, &.{ 0, 1 }).valued(5.6e-16).times(2)) },
        .{ "C_three_vs_triple", try parallel(arena, .c, 3), try card(arena, Dev.onPins(.c, &.{ 0, 1 }).valued(1.68e-15)) },
        .{ "C_two_vs_one", try parallel(arena, .c, 2), try card(arena, Dev.onPins(.c, &.{ 0, 1 }).valued(5.6e-16)) },
    };
    try policiesInto(arena, "topology", &.{ "LVS-049", "LVS-043", "LVS-044" }, &pairs, &relaxed_or_strict, out);
}

/// Two devices of `model`, `[0, 1]` and `second`, through internal net 1.
fn chain(arena: Allocator, model: Model, second: [2]usize) !Circuit {
    return (try Circuit.init(arena, 3, &.{ Dev.onPins(model, &.{ 0, 1 }), Dev.onPins(model, &second) })).internal(arena, 1);
}

/// LVS-043, LVS-044, LVS-049: relaxed series. Two resistors drawn in
/// series through an internal net, 200 ohm each, are one of 400 ohm, and
/// two capacitors of 0.56 fF chained plate to plate one of 0.28 fF; two
/// written resistors of 100 ohm in series are the 200 ohm drawn. Strict,
/// nothing merges in series. A net that is a port stops the chain, and
/// capacitors meeting tail to tail do not chain.
fn seriesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // Not `n1`, which the layout labels: a labelled node stops a merge on
    // both sides (`lvs::compare`).
    const written_chain = try (try Circuit.init(arena, 3, &.{ Dev.onPins(.r, &.{ 0, 2 }).valued(100.0), Dev.onPins(.r, &.{ 2, 1 }).valued(100.0) })).internal(arena, 2);
    const pairs = [_]Pair{
        .{ "R_chain_vs_sum", try chain(arena, .r, .{ 1, 2 }), try card(arena, Dev.onPins(.r, &.{ 0, 1 }).valued(400.0)) },
        .{ "R_chain_through_port_vs_sum", try Circuit.init(arena, 3, &.{ Dev.onPins(.r, &.{ 0, 1 }), Dev.onPins(.r, &.{ 1, 2 }) }), try card(arena, Dev.onPins(.r, &.{ 0, 1 }).valued(400.0)) },
        .{ "R_one_vs_written_chain", try card(arena, Dev.onPins(.r, &.{ 0, 1 })), written_chain },
        .{ "C_chain_vs_series", try chain(arena, .c, .{ 1, 2 }), try card(arena, Dev.onPins(.c, &.{ 0, 1 }).valued(2.8e-16)) },
        .{ "C_tail_to_tail_vs_series", try chain(arena, .c, .{ 2, 1 }), try card(arena, Dev.onPins(.c, &.{ 0, 1 }).valued(2.8e-16)) },
        .{ "D_chain_vs_one", try chain(arena, .d, .{ 1, 2 }), try card(arena, Dev.onPins(.d, &.{ 0, 1 })) },
    };
    try policiesInto(arena, "topology/series", &.{ "LVS-049", "LVS-043", "LVS-044" }, &pairs, &relaxed_or_strict, out);
}

/// LVS-065: an inductor, its deck's 2 nH on every one drawn. One drawn
/// matches a card of 2 nH, either way round, and not 2.1 nH (4.8 %, past
/// 2 %); relaxed, two drawn in series are one of 4 nH and two in parallel
/// one of 1 nH, by Kirchhoff's laws (`KLayout`'s `InductorDeviceCombiner`),
/// and strict they match only the count.
fn inductorsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const l_chain = try (try Circuit.init(arena, 3, &.{ Dev.onPins(.l, &.{ 0, 1 }), Dev.onPins(.l, &.{ 1, 2 }) })).internal(arena, 1);
    const l_pair = try Circuit.init(arena, 2, &.{ Dev.onPins(.l, &.{ 0, 1 }), Dev.onPins(.l, &.{ 1, 0 }) });
    const one = try card(arena, Dev.onPins(.l, &.{ 0, 1 }));
    const pairs = [_]Pair{
        .{ "one_vs_2nH", one, try card(arena, Dev.onPins(.l, &.{ 0, 1 }).valued(2e-9)) },
        .{ "one_vs_2nH_reversed", one, try card(arena, Dev.onPins(.l, &.{ 1, 0 }).valued(2e-9)) },
        .{ "one_vs_2.1nH", one, try card(arena, Dev.onPins(.l, &.{ 0, 1 }).valued(2.1e-9)) },
        .{ "series_vs_4nH", l_chain, try card(arena, Dev.onPins(.l, &.{ 0, 1 }).valued(4e-9)) },
        .{ "parallel_vs_1nH", l_pair, try card(arena, Dev.onPins(.l, &.{ 0, 1 }).valued(1e-9)) },
        .{ "parallel_vs_m2", l_pair, try card(arena, Dev.onPins(.l, &.{ 0, 1 }).valued(2e-9).times(2)) },
    };
    try policiesInto(arena, "inductor", &.{ "LVS-065", "LVS-049" }, &pairs, &relaxed_or_strict, out);
}

/// A NAND2: nets a, b, out, gnd, vdd, and x between its stack's
/// transistors; a narrow transistor on `a` alone tells `a` from `b`.
fn nand(arena: Allocator, top: usize, bottom: usize, wide: i64) !Circuit {
    return (try Circuit.init(arena, 6, &.{ Dev.mos(.n, top, 4, 2), Dev.mos(.n, bottom, 3, 4).sized(wide, 150), Dev.mos(.p, 0, 5, 2), Dev.mos(.p, 1, 5, 2), Dev.mos(.n, 0, 3, 5).sized(500, 150) })).internal(arena, 4);
}

/// A NOR2's p-channel stack, nets as `nand`'s.
fn nor(arena: Allocator, top: usize, bottom: usize) !Circuit {
    return (try Circuit.init(arena, 6, &.{ Dev.mos(.p, top, 4, 2), Dev.mos(.p, bottom, 5, 4), Dev.mos(.n, 0, 3, 2), Dev.mos(.n, 1, 3, 2), Dev.mos(.n, 0, 3, 5).sized(500, 150) })).internal(arena, 4);
}

/// LVS-047: logic-gate recognition. A NAND2 drawn with `a` on top matches
/// a schematic with `b` on top once gates are recognised, and not
/// otherwise; so does a NOR2's p-channel stack. Stacked transistors of
/// different widths do not merge, so the swap still mismatches; nor does a
/// stack through a labelled node; nor an analog cascode the control does
/// not name, which is the same structure and stays a mismatch by default.
fn gatesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const labelled_x = try Circuit.init(arena, 6, &.{ Dev.mos(.n, 0, 4, 2), Dev.mos(.n, 1, 3, 4), Dev.mos(.p, 0, 5, 2), Dev.mos(.p, 1, 5, 2), Dev.mos(.n, 0, 3, 5).sized(500, 150) });
    var labelled_swapped = try labelled_x.clone(arena);
    labelled_swapped.devs[0].pins[0] = 1;
    labelled_swapped.devs[1].pins[0] = 0;
    const pairs = [_]Pair{
        .{ "nand2_same", try nand(arena, 0, 1, 1000), try nand(arena, 0, 1, 1000) },
        .{ "nand2_inputs_swapped", try nand(arena, 0, 1, 1000), try nand(arena, 1, 0, 1000) },
        .{ "nand2_sizes_differ_swapped", try nand(arena, 0, 1, 2000), try nand(arena, 1, 0, 2000) },
        .{ "nor2_inputs_swapped", try nor(arena, 0, 1), try nor(arena, 1, 0) },
        .{ "labelled_node_swapped", labelled_x, labelled_swapped },
    };
    try policiesInto(arena, "gates", &.{"LVS-047"}, &pairs, &[_]Policy{ .{ "gates", .{ .gates = true } }, .{ "default", .{} } }, out);
}

/// A diode's value is its area: two drawn in parallel, 0.32 um² each, are
/// one of 0.64 um² relaxed, and two strict (derived by hand from the
/// drawer's pads).
fn diodesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const diodes = try Circuit.init(arena, 2, &.{ Dev.onPins(.d, &.{ 0, 1 }), Dev.onPins(.d, &.{ 0, 1 }) });
    const written = try circuit.spice(arena, &try Circuit.init(arena, 2, &.{Dev.onPins(.d, &.{ 0, 1 }).withArea(640_000)}));
    for ([_]struct { []const u8, bool }{ .{ "relaxed", true }, .{ "strict", false } }) |p| {
        const deck = try std.fmt.allocPrint(arena, "{s}lvs topology {s}\n", .{ circuit.full_deck, p[0] });
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/topology/D_two_vs_double_area/{s}", .{p[0]}), &.{ "LVS-049", "LVS-044" }, deck, fixture.lvs);
        f.layout = try circuit.draw(arena, &diodes);
        try f.claim(arena, .{ .lvs = p[1] });
        f.reference = written;
        try out.append(arena, f);
    }
}

/// LVS-034: `max_res` and `min_caps` leave out a resistor above and a
/// capacitor below the threshold, on either side, as opens. A drawn
/// resistor of 200 ohm (`measured`) across a transistor's channel, against
/// the transistor alone, matches under `max_res 100ohm` and not `300ohm`; a
/// written 1 Mohm the layout does not draw matches under `100kohm` and not
/// `2Mohm`; a drawn capacitor of 0.56 fF matches under `min_caps 1fF` and
/// not `100aF`.
fn thresholdsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const alone = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    const drawn_r = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.onPins(.r, &.{ 1, 2 }) });
    const written_r = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.onPins(.r, &.{ 1, 2 }).valued(1e6) });
    const drawn_c = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.onPins(.c, &.{ 1, 2 }) });
    const cases = [_]Case{
        .{ "drawn_R_default", drawn_r, alone, .{} },
        .{ "drawn_R_max_100ohm", drawn_r, alone, .{ .max_res = .{ .text = "100ohm", .si = 100.0 } } },
        .{ "drawn_R_max_300ohm", drawn_r, alone, .{ .max_res = .{ .text = "300ohm", .si = 300.0 } } },
        .{ "written_R_max_100kohm", alone, written_r, .{ .max_res = .{ .text = "100kohm", .si = 1e5 } } },
        .{ "written_R_max_2Mohm", alone, written_r, .{ .max_res = .{ .text = "2Mohm", .si = 2e6 } } },
        .{ "drawn_C_min_1fF", drawn_c, alone, .{ .min_caps = .{ .text = "1fF", .si = 1e-15 } } },
        .{ "drawn_C_min_100aF", drawn_c, alone, .{ .min_caps = .{ .text = "100aF", .si = 1e-16 } } },
    };
    for (cases) |c| try out.append(arena, try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "thresholds/{s}", .{c[0]}), &.{"LVS-034"}, &c[1], &c[2], &c[3]));
}

/// LVS-032: `same_nets`. Two transistors, each its own gate and drain,
/// against a reference naming the drains the other way round: one circuit
/// up to renaming. Holding layout `n0` to reference `n0` and `n2` to `n2`
/// contradicts that reference's wiring, a mismatch; `n2` to `n3` follows
/// it, a match; a row naming no net changes nothing, and a row with a
/// layout label and no reference net is unpaired.
fn sameNetsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const pair = try Circuit.init(arena, 5, &.{ Dev.mos(.n, 0, 4, 2), Dev.mos(.n, 1, 4, 3) });
    var crossed = try pair.clone(arena);
    std.mem.swap([]const u8, &crossed.names[2], &crossed.names[3]);
    const rows = [_]struct { []const u8, Controls }{
        .{ "none", .{} },
        .{ "against_wiring", .{ .same_nets = &.{ .{ .layout = "n0", .reference = "n0" }, .{ .layout = "n2", .reference = "n2" } } } },
        .{ "with_wiring", .{ .same_nets = &.{ .{ .layout = "n0", .reference = "n0" }, .{ .layout = "n2", .reference = "n3" } } } },
        .{ "no_such_nets", .{ .same_nets = &.{.{ .layout = "q", .reference = "q" }} } },
        .{ "no_reference_net", .{ .same_nets = &.{.{ .layout = "n0", .reference = "q" }} } },
    };
    for (rows) |r| try out.append(arena, try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "same_nets/{s}", .{r[0]}), &.{"LVS-032"}, &pair, &crossed, &r[1]));
}

/// A passive's value, drawn 200 ohm and 0.56 fF (`measured`), against 210
/// ohm and 0.6 fF: 10 ohm and 40 aF apart, so within 15 ohm and 50 aF and
/// not 5 ohm or 30 aF.
fn passiveToleranceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const rows = [_]struct { []const u8, Model, f64, controls_.Absolute, []const u8 }{
        .{ "R_r_absolute_15ohm", .r, 210.0, .{ .text = "15ohm", .si = 15.0 }, "LVS-061" },
        .{ "R_r_absolute_5ohm", .r, 210.0, .{ .text = "5ohm", .si = 5.0 }, "LVS-061" },
        .{ "C_c_absolute_50aF", .c, 6e-16, .{ .text = "50aF", .si = 5e-17 }, "LVS-062" },
        .{ "C_c_absolute_30aF", .c, 6e-16, .{ .text = "30aF", .si = 3e-17 }, "LVS-062" },
    };
    for (rows) |r| {
        const param: []const u8 = if (r[1] == .r) "r" else "c";
        const controls: Controls = .{ .tolerance = try arena.dupe(controls_.Tolerance, &.{.{ .model = r[1], .param = param, .relative = 0.0, .absolute = r[3] }}) };
        const layout = try card(arena, Dev.onPins(r[1], &.{ 0, 1 }));
        const reference = try card(arena, Dev.onPins(r[1], &.{ 0, 1 }).valued(r[2]));
        try out.append(arena, try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "tolerance/deck/{s}", .{r[0]}), &.{ "LVS-014", r[4] }, &layout, &reference, &controls));
    }
}

test "every LVS control fixture on topology and values holds" {
    // Oracle: the brute-force oracle (lvs_oracle.zig) under the controls
    // each fixture's deck states, read from deck.md ("LVS controls"), and
    // the diode areas derived by hand from the drawer's pads.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
