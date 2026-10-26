//! The deck's `lvs` statements (deck.md, "LVS controls") on parameters and
//! pins: tolerance rows, ignored parameters, asymmetric transistors,
//! permuted pins, ignored models and dummies, and ports by name, each
//! verdict the oracle's under the statements the fixture's deck adds.
//! Ported from tests/exhaustive/lvs.rs (`controlled`, its first half).
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
const Absolute = controls_.Absolute;
const fixture = @import("lvs_fixture.zig");

/// A case: a name, the layout and reference circuits, and the controls.
const Case = struct { []const u8, Circuit, Circuit, Controls };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try toleranceInto(arena, out);
    try ignoreParameterInto(arena, out);
    try asymmetricInto(arena, out);
    try permuteInto(arena, out);
    try ignoreInto(arena, out);
    try ignoreShortedInto(arena, out);
    try portsInto(arena, out);
}

// ---- private ----

/// One tolerance row as controls.
fn row(arena: Allocator, model: Model, param: []const u8, relative: f64, absolute: ?Absolute) !Controls {
    return .{ .tolerance = try arena.dupe(controls_.Tolerance, &.{.{ .model = model, .param = param, .relative = relative, .absolute = absolute }}) };
}

fn wOf(arena: Allocator, w: i64) !Circuit {
    return Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(w, 1000)});
}

fn casesInto(arena: Allocator, prefix: []const u8, catalog: []const []const u8, cases: []const Case, out: *std.ArrayList(Fixture)) !void {
    for (cases) |c| try out.append(arena, try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, c[0] }), catalog, &c[1], &c[2], &c[3]));
}

/// LVS-014: a row bounds one parameter of one model in place of the 2 %,
/// its relative and absolute parts adding. `w` 1000 against 1040 nm is
/// 3.85 % of the larger: past 2 %, within a 5 % row and not a 3 % one,
/// within 50 nm and not 30 nm, within 2 % plus 20 nm (40.8 nm). 1.5 %
/// matches by default and not under a 1 % row. A row on `l`, or on `pmos`,
/// leaves this `w` at 2 %.
fn toleranceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const base = try wOf(arena, 1000);
    const w1040 = try wOf(arena, 1040);
    const w1015 = try wOf(arena, 1015);
    const cases = [_]Case{
        .{ "w+3.85_default", base, w1040, .{} },
        .{ "w+3.85_relative_5pct", base, w1040, try row(arena, .n, "w", 0.05, null) },
        .{ "w+3.85_relative_3pct", base, w1040, try row(arena, .n, "w", 0.03, null) },
        .{ "w+3.85_absolute_50nm", base, w1040, try row(arena, .n, "w", 0.0, .{ .text = "50nm", .si = 50.0 * 1e-9 }) },
        .{ "w+3.85_absolute_30nm", base, w1040, try row(arena, .n, "w", 0.0, .{ .text = "30nm", .si = 30.0 * 1e-9 }) },
        .{ "w+3.85_2pct_plus_20nm", base, w1040, try row(arena, .n, "w", 0.02, .{ .text = "20nm", .si = 20.0 * 1e-9 }) },
        .{ "w+1.5_default", base, w1015, .{} },
        .{ "w+1.5_relative_1pct", base, w1015, try row(arena, .n, "w", 0.01, null) },
        .{ "w+3.85_row_on_l", base, w1040, try row(arena, .n, "l", 0.05, null) },
        .{ "w+3.85_row_on_pmos", base, w1040, try row(arena, .p, "w", 0.05, null) },
    };
    try casesInto(arena, "tolerance/deck", &.{ "LVS-014", "LVS-060" }, &cases, out);
}

/// An ignored parameter is neither compared nor merged on: `w` 1000
/// against 1500 nm matches once `nmos` `w` is ignored, and two transistors
/// of `l` 150 and 200 nm are one of twice the width once `l` is.
fn ignoreParameterInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const two = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 2, 1).sized(1000, 200) });
    const wide = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150)});
    const w1000 = try wOf(arena, 1000);
    const w1500 = try wOf(arena, 1500);
    const ignore_w: Controls = .{ .ignored = &.{.{ .n, "w" }} };
    const ignore_l: Controls = .{ .ignored = &.{.{ .n, "l" }} };
    const cases = [_]Case{
        .{ "w+50pct", w1000, w1500, .{} },
        .{ "w+50pct_w_ignored", w1000, w1500, ignore_w },
        .{ "w+50pct_l_ignored", w1000, w1500, ignore_l },
        .{ "lengths_differ_vs_wide", two, wide, .{} },
        .{ "lengths_differ_vs_wide_l_ignored", two, wide, ignore_l },
    };
    try casesInto(arena, "ignore_parameter", &.{ "LVS-014", "LVS-040" }, &cases, out);
}

/// LVS-031: an asymmetric `nmos`, whose source pairs only with a source. A
/// `pmos` gated by n1 tells n1 from n2, so a card with source and drain
/// swapped is another circuit once `nmos` is asymmetric, and the same one
/// otherwise. Two in parallel merge source on source and not opposed; a
/// stack of them stays two.
fn asymmetricInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const same = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.p, 1, 0, 0) });
    const swapped = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 2, 1), Dev.mos(.p, 1, 0, 0) });
    const wide = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150)});
    const aligned = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 1, 2) });
    const opposed = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 2, 1) });
    const stack = try (try Circuit.init(arena, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) })).internal(arena, 3);
    const long = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300)});
    const pairs = [_]struct { []const u8, Circuit, Circuit }{
        .{ "sd_same", same, same },
        .{ "sd_swapped", same, swapped },
        .{ "parallel_aligned_vs_wide", aligned, wide },
        .{ "parallel_opposed_vs_wide", opposed, wide },
        .{ "stack_vs_long", stack, long },
        .{ "stack_vs_stack", stack, stack },
    };
    const labels = [_]struct { []const u8, Controls }{ .{ "symmetric", .{} }, .{ "asymmetric", .{ .asymmetric = &.{.n} } } };
    for (pairs) |p| for (labels) |l| {
        try out.append(arena, try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "asymmetric/{s}/{s}", .{ p[0], l[0] }), &.{ "LVS-031", "LVS-030" }, &p[1], &p[2], &l[1]));
    };
}

/// LVS-030: pins the deck permutes. A capacitor or diode reversed, and a
/// bipolar with emitter and collector exchanged, are other circuits by
/// default (F15) and the same once those pins permute; base with emitter
/// is not emitter with collector. The bipolar's base is on n1 and its
/// emitter on n0, which the `nmos` gate fixes, since the `nmos` channel
/// alone would let n1 and n2 trade places. Two capacitors in opposite
/// directions merge into one of m = 2 once the plates permute. A `pmos`
/// with gate and source exchanged is the same once gate permutes with
/// source, which chains with source-drain; a stack of such `nmos` no
/// longer merges in series.
fn permuteInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const polar = fixture.polar;
    const caps_opposed = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 1, 0 }) });
    const cap_m2 = try polar(arena, Dev.onPins(.c, &.{ 0, 1 }).times(2));
    const stack = try (try Circuit.init(arena, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) })).internal(arena, 3);
    const long = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300)});
    const cases = [_]Case{
        .{ "C_reversed", try polar(arena, Dev.onPins(.c, &.{ 0, 1 })), try polar(arena, Dev.onPins(.c, &.{ 1, 0 })), .{ .permuted = &.{.{ .model = .c, .a = 0, .b = 1 }} } },
        .{ "D_reversed", try polar(arena, Dev.onPins(.d, &.{ 0, 1 })), try polar(arena, Dev.onPins(.d, &.{ 1, 0 })), .{ .permuted = &.{.{ .model = .d, .a = 0, .b = 1 }} } },
        .{ "Q_emitter_collector_swapped", try polar(arena, Dev.onPins(.q, &.{ 1, 0, 2 })), try polar(arena, Dev.onPins(.q, &.{ 1, 2, 0 })), .{ .permuted = &.{.{ .model = .q, .a = 1, .b = 2 }} } },
        .{ "Q_emitter_collector_swapped_base_permuted", try polar(arena, Dev.onPins(.q, &.{ 1, 0, 2 })), try polar(arena, Dev.onPins(.q, &.{ 1, 2, 0 })), .{ .permuted = &.{.{ .model = .q, .a = 0, .b = 1 }} } },
        .{ "C_opposed_vs_m2", caps_opposed, cap_m2, .{ .permuted = &.{.{ .model = .c, .a = 0, .b = 1 }} } },
        .{ "C_opposed_vs_m2_unpermuted", caps_opposed, cap_m2, .{} },
        .{ "P_gate_source_swapped", try polar(arena, Dev.mos(.p, 0, 1, 2)), try polar(arena, Dev.mos(.p, 1, 0, 2)), .{ .permuted = &.{.{ .model = .p, .a = 0, .b = 1 }} } },
        .{ "P_gate_source_swapped_unpermuted", try polar(arena, Dev.mos(.p, 0, 1, 2)), try polar(arena, Dev.mos(.p, 1, 0, 2)), .{} },
        .{ "stack_vs_long_gate_permuted", stack, long, .{ .permuted = &.{.{ .model = .n, .a = 0, .b = 1 }} } },
        .{ "C_same", try polar(arena, Dev.onPins(.c, &.{ 0, 1 })), try polar(arena, Dev.onPins(.c, &.{ 0, 1 })), .{ .permuted = &.{.{ .model = .c, .a = 0, .b = 1 }} } },
    };
    try casesInto(arena, "permute", &.{"LVS-030"}, &cases, out);
}

/// `c` with one more net, `n3`, a port or not.
fn withNet(arena: Allocator, c: *const Circuit, port: bool) !Circuit {
    var out = c.*;
    out.devs = try arena.dupe(Dev, c.devs);
    out.names = try std.mem.concat(arena, []const u8, &.{ c.names, &.{"n3"} });
    out.ports = try std.mem.concat(arena, bool, &.{ c.ports, &.{port} });
    return out;
}

/// `c` with `dev` added.
fn withDev(arena: Allocator, c: *const Circuit, dev: Dev) !Circuit {
    var out = try c.clone(arena);
    out.devs = try std.mem.concat(arena, Dev, &.{ c.devs, &.{dev} });
    return out;
}

/// LVS-034: an ignored model's devices are left out on both sides. A
/// capacitor from n0 to n1 beside the `nmos`, drawn and not written or
/// written and not drawn, matches once `cmim` is ignored; ignoring `nmos`
/// instead leaves it unpaired. A capacitor to an internal net n3 takes that
/// net with it; one to a port n3 leaves the port, which must still pair.
fn ignoreInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const bare = try fixture.polar(arena, Dev.mos(.p, 1, 0, 2));
    const capped = try withDev(arena, &bare, Dev.onPins(.c, &.{ 0, 1 }));
    const to_internal = try withDev(arena, &try withNet(arena, &bare, false), Dev.onPins(.c, &.{ 1, 3 }));
    var to_port = try to_internal.clone(arena);
    to_port.ports[3] = true;
    const ignore_c: Controls = .{ .left_out = &.{.c} };
    const cases = [_]Case{
        .{ "drawn_only", capped, bare, ignore_c },
        .{ "written_only", bare, capped, ignore_c },
        .{ "drawn_only_default", capped, bare, .{} },
        .{ "drawn_only_nmos_ignored", capped, bare, .{ .left_out = &.{.n} } },
        .{ "internal_net_written_only", bare, to_internal, ignore_c },
        .{ "port_written_only", bare, to_port, ignore_c },
        .{ "both", capped, capped, ignore_c },
    };
    try casesInto(arena, "ignore", &.{"LVS-034"}, &cases, out);
}

/// LVS-035: dummies, every pin on one net, are left out once their model
/// ignores shorted devices: an `nmos` with gate, source and drain on n0
/// (its bulk, which the deck does not extract, written on its source), and
/// an `nmosb` with all four on n3. One with its gate elsewhere is no dummy.
fn ignoreShortedInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const real = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    const dummy0 = try withDev(arena, &real, Dev.mos(.n, 0, 0, 0));
    const dummy1 = try withDev(arena, &real, Dev.mos(.n, 1, 0, 0));
    const real_b = try Circuit.init(arena, 4, &.{Dev.mos(.b, 0, 1, 2).bulk(3)});
    const dummy_b = try withDev(arena, &real_b, Dev.mos(.b, 3, 3, 3).bulk(3));
    const skip_n: Controls = .{ .dummies_out = &.{.n} };
    const skip_b: Controls = .{ .dummies_out = &.{.b} };
    const cases = [_]Case{
        .{ "N_drawn", dummy0, real, skip_n },
        .{ "N_written", real, dummy0, skip_n },
        .{ "N_drawn_default", dummy0, real, .{} },
        .{ "N_gate_elsewhere", dummy1, real, skip_n },
        .{ "B_drawn", dummy_b, real_b, skip_b },
        .{ "B_written", real_b, dummy_b, skip_b },
        .{ "B_drawn_default", dummy_b, real_b, .{} },
    };
    try casesInto(arena, "ignore_shorted", &.{"LVS-035"}, &cases, out);
}

/// LVS-016, LVS-001: ports by name. Two transistors, each its own gate and
/// drain port, against a reference that wires gate n0 to the drain it
/// names n3: the same circuit up to renaming, a mismatch once ports go by
/// name. The same names match either way, and a layout with no labels
/// matches only by structure.
fn portsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const pair = try Circuit.init(arena, 5, &.{ Dev.mos(.n, 0, 4, 2), Dev.mos(.n, 1, 4, 3) });
    var crossed = try pair.clone(arena);
    std.mem.swap([]const u8, &crossed.names[2], &crossed.names[3]);
    const unlabelled = try pair.clone(arena);
    @memset(unlabelled.ports, false);
    const by_name: Controls = .{ .ports_by_name = true };
    const cases = [_]Case{
        .{ "crossed", pair, crossed, .{} },
        .{ "crossed_by_name", pair, crossed, by_name },
        .{ "same_by_name", pair, pair, by_name },
        .{ "reordered_by_name", pair, pair, by_name },
        .{ "unlabelled", unlabelled, pair, .{} },
        .{ "unlabelled_by_name", unlabelled, pair, by_name },
    };
    for (cases) |c| {
        var f = try fixture.comparedUnder(arena, try std.fmt.allocPrint(arena, "ports/{s}", .{c[0]}), &.{ "LVS-016", "LVS-001" }, &c[1], &c[2], &c[3]);
        if (std.mem.startsWith(u8, c[0], "reordered")) f.reference = try circuit.edited(arena, f.reference.?, ".subckt TOP n0 n1 n2 n3 n4", ".subckt TOP n4 n3 n2 n1 n0");
        try out.append(arena, f);
    }
}

test "every LVS control fixture on parameters and pins holds" {
    // Oracle: the brute-force oracle (lvs_oracle.zig) under the controls
    // each fixture's deck states, read from deck.md ("LVS controls"), never
    // from the tool.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
