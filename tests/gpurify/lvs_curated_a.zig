//! Curated LVS fixtures, first part: hierarchy, stacks, parallel devices,
//! polarity, the Spectre reader, multipliers and tolerance. Ported from
//! tests/exhaustive/lvs.rs (`curated`, up to the declared parameters).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const circuit = @import("lvs_circuit.zig");
const Model = circuit.Model;
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const oracle = @import("lvs_oracle.zig");
const fx = @import("lvs_fixture.zig");

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try hierarchyAndSeriesInto(arena, out);
    try parallelInto(arena, out);
    try polarityAndSpectreInto(arena, out);
    try multiplierAndToleranceInto(arena, out);
}

// ---- private ----

/// A fixture over `text` claiming the LVS verdict `matched`.
fn texted(arena: Allocator, name: []const u8, catalog: []const []const u8, layout: Layout, text: []const u8, matched: bool) !Fixture {
    var f = try fx.withText(arena, name, catalog, layout, text);
    try f.claim(arena, .{ .lvs = matched });
    return f;
}

fn hierarchyAndSeriesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // F1 (fixed in B2): a reference that places a block by `X` instance. Top: an nmos on
    // in = n0, out = n1, vss = n2; the block: a pmos `d g s`, placed on
    // (out, in, vss).
    const top = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 2, 1)});
    const block = try Circuit.init(arena, 3, &.{Dev.mos(.p, 1, 2, 0)});
    const on = [_]usize{ 1, 0, 2 };
    const flat = try circuit.flatten(arena, &top, &block, &on);
    const hier = try circuit.spiceHier(arena, &top, &block, &on);
    for ([_]struct { []const u8, *const Circuit }{ .{ "hier/block_missing", &top }, .{ "hier/block_drawn", &flat } }) |case| {
        try out.append(arena, try texted(arena, case[0], &.{ "LVS-010", "LVS-017", "LVS-072" }, try circuit.draw(arena, case[1]), hier, try oracle.equivalent(arena, case[1], &flat)));
    }
    try out.append(arena, try fx.compared(arena, "hier/flat_control", &.{ "LVS-019", "LVS-072" }, &flat, &flat));

    // F12 (fixed in B4), LVS-041: a stack through n3, its gates strapped on n0.
    const stack = try Circuit.init(arena, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) });
    const long = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300)});
    const inner = try stack.internal(arena, 3);
    const both: []const []const u8 = &.{ "LVS-041", "LVS-049" };
    try out.append(arena, try fx.compared(arena, "series/stack_vs_stack", both, &inner, &inner));
    try out.append(arena, try fx.compared(arena, "series/stack_vs_long", &.{"LVS-041"}, &inner, &long));
    try out.append(arena, try fx.compared(arena, "series/labelled_stack_vs_stack", &.{"LVS-041"}, &stack, &stack));
    try out.append(arena, try fx.compared(arena, "series/labelled_stack_vs_long", both, &stack, &long));
    var uneven = try inner.clone(arena);
    uneven.devs[1] = uneven.devs[1].sized(2000, 150);
    try out.append(arena, try fx.compared(arena, "series/widths_differ_vs_long", &.{"LVS-041"}, &uneven, &long));
    const apart = try (try Circuit.init(arena, 5, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 4, 3, 2) })).internal(arena, 3);
    try out.append(arena, try fx.compared(arena, "series/gates_apart_vs_long", &.{"LVS-041"}, &apart, &long));
    // F67 (fixed in B21): with no `l` written anywhere, the run measures none,
    // and a stack with no length to sum stays two transistors: it does not
    // match one unsized card, and does match its own two unsized cards.
    const one_unsized = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    for ([_]struct { []const u8, *const Circuit, bool }{ .{ "series/unsized_stack_vs_one", &one_unsized, false }, .{ "series/unsized_stack_vs_stack", &inner, true } }) |case| {
        const reference = try circuit.edited(arena, try circuit.spice(arena, case[1]), " w=1000n l=150n", "");
        try out.append(arena, try texted(arena, case[0], &.{"LVS-041"}, try circuit.draw(arena, &inner), reference, case[2]));
    }
    // F84 (fixed in B27): a series merge needs `l` and nothing else, so the
    // stack is one card writing `l` alone; one writing `w` alone has no
    // length to sum, and the stack stays two.
    for ([_]struct { []const u8, bool, bool }{ .{ "series/stack_vs_long_l_only", false, true }, .{ "series/stack_vs_long_w_only", true, false } }) |case| {
        const reference = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300).writes(case[1], case[2])});
        try out.append(arena, try fx.compared(arena, case[0], &.{"LVS-041"}, &inner, &reference));
    }
}

fn parallelInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // LVS-040 and F57 (fixed in B17): parallel MOS, source and drain shorted too.
    const two = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 2, 1) });
    const wide = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150)});
    try out.append(arena, try fx.compared(arena, "parallel/mos_two_vs_wide", &.{"LVS-040"}, &two, &wide));
    var lengths = try two.clone(arena);
    lengths.devs[1] = lengths.devs[1].sized(1000, 200);
    try out.append(arena, try fx.compared(arena, "parallel/mos_lengths_differ_vs_wide", &.{"LVS-040"}, &lengths, &wide));
    const shorted = try Circuit.init(arena, 2, &.{ Dev.mos(.n, 0, 1, 1), Dev.mos(.n, 0, 1, 1) });
    const shorted_wide = try Circuit.init(arena, 2, &.{Dev.mos(.n, 0, 1, 1).sized(2000, 150)});
    try out.append(arena, try fx.compared(arena, "parallel/mos_shorted_two_vs_wide", &.{"LVS-040"}, &shorted, &shorted_wide));
    // F83 (fixed in B27): with no `w` written anywhere, two transistors in
    // parallel keep their count, as passives do: they are one card of
    // `m = 2`, and not one bare card.
    for ([_]struct { []const u8, Dev }{ .{ "parallel/mos_unsized_two_vs_one", Dev.mos(.n, 0, 1, 2) }, .{ "parallel/mos_unsized_two_vs_m2", Dev.mos(.n, 0, 1, 2).times(2) } }) |case| {
        const reference = try Circuit.init(arena, 3, &.{case[1].writes(false, false)});
        try out.append(arena, try fx.compared(arena, case[0], &.{ "LVS-040", "LVS-046" }, &two, &reference));
    }
    // F84 (fixed in B27): a parallel merge needs `w` and nothing else, so the
    // pair is one card writing `w` alone; one writing `l` alone has no width
    // to sum, so the pair is counted, two against its one.
    for ([_]struct { []const u8, bool, bool }{ .{ "parallel/mos_two_vs_wide_w_only", true, false }, .{ "parallel/mos_two_vs_wide_l_only", false, true } }) |case| {
        const reference = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150).writes(case[1], case[2])});
        try out.append(arena, try fx.compared(arena, case[0], &.{"LVS-040"}, &two, &reference));
    }

    // F20 (fixed in B9), LVS-043, LVS-044: parallel passives keep their count.
    for ([_]struct { Model, []const u8 }{ .{ .r, "LVS-043" }, .{ .c, "LVS-044" }, .{ .d, "LVS-044" } }) |case| {
        const one = try fx.polar(arena, Dev.onPins(case[0], &.{ 0, 1 }));
        const pair = try Circuit.init(arena, 3, &.{ one.devs[0], one.devs[1], Dev.onPins(case[0], &.{ 0, 1 }) });
        const letter = case[0].letter();
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "parallel/{c}_two_vs_one", .{letter}), &.{case[1]}, &one, &pair));
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "parallel/{c}_two_vs_two", .{letter}), &.{case[1]}, &pair, &pair));
    }
    const forward = try fx.polar(arena, Dev.onPins(.d, &.{ 0, 1 }));
    const opposed = try Circuit.init(arena, 3, &.{ forward.devs[0], forward.devs[1], Dev.onPins(.d, &.{ 1, 0 }) });
    const rows: []const []const u8 = &.{ "LVS-044", "LVS-030" };
    // Opposed diodes stay two since F15 was fixed.
    try out.append(arena, try fx.compared(arena, "parallel/D_opposed_vs_one", rows, &forward, &opposed));
    try out.append(arena, try fx.compared(arena, "parallel/D_opposed_vs_opposed", rows, &opposed, &opposed));
}

fn polarityAndSpectreInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // F15 (fixed in B3), LVS-030: which ends are interchangeable.
    for ([_]struct { Model, []const u8 }{ .{ .r, "LVS-030" }, .{ .c, "LVS-062" }, .{ .d, "LVS-063" } }) |case| {
        const drawn = try fx.polar(arena, Dev.onPins(case[0], &.{ 0, 1 }));
        const reversed = try fx.polar(arena, Dev.onPins(case[0], &.{ 1, 0 }));
        const letter = case[0].letter();
        const rows = try arena.dupe([]const u8, &.{ "LVS-030", case[1] });
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "polarity/{c}_same", .{letter}), rows, &drawn, &drawn));
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "polarity/{c}_reversed", .{letter}), rows, &drawn, &reversed));
    }
    const bjt = try fx.polar(arena, Dev.onPins(.q, &.{ 0, 1, 2 }));
    const flipped = try fx.polar(arena, Dev.onPins(.q, &.{ 0, 2, 1 }));
    const rows: []const []const u8 = &.{ "LVS-030", "LVS-064" };
    try out.append(arena, try fx.compared(arena, "polarity/Q_same", rows, &bjt, &bjt));
    try out.append(arena, try fx.compared(arena, "polarity/Q_emitter_collector_swapped", rows, &bjt, &flipped));

    // LVS-071: every model through the Spectre reader, as drawn and with a
    // fault, so the reader is held to the SPICE reader's verdicts.
    for (try fx.everyModel(arena), 0..) |pair, index| {
        for ([_]struct { []const u8, *const Circuit }{ .{ "same", &pair.drawn }, .{ "swapped", &pair.swapped } }) |case| {
            try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "spectre/{d}_{s}", .{ index, case[0] }), &.{"LVS-071"}, try circuit.draw(arena, &pair.drawn), try circuit.spectre(arena, case[1]), try oracle.equivalent(arena, &pair.drawn, case[1])));
        }
    }
    // F97 (fixed in B31): a Spectre primitive with no `model` card names no
    // model, so it is the deck's one recogniser of its kind. The deck has
    // one resistor, capacitor, diode and bipolar, so each card, its model
    // card dropped and its master the primitive, is the device drawn.
    for ([_]struct { Dev, []const u8, []const u8 }{
        .{ Dev.onPins(.r, &.{ 0, 1 }), "rpoly", "resistor" },
        .{ Dev.onPins(.c, &.{ 0, 1 }), "cmim", "capacitor" },
        .{ Dev.onPins(.d, &.{ 0, 1 }), "dpn", "diode" },
        .{ Dev.onPins(.q, &.{ 0, 1, 2 }), "npn", "npn" },
        .{ Dev.onPins(.l, &.{ 0, 1 }), "spiral", "inductor" },
    }) |case| {
        const c = try fx.polar(arena, case[0]);
        const card = try circuit.edited(arena, try circuit.spectre(arena, &c), try std.fmt.allocPrint(arena, "\nmodel {s} ", .{case[1]}), "\n// ");
        const text = try circuit.edited(arena, card, try std.fmt.allocPrint(arena, ") {s}", .{case[1]}), try std.fmt.allocPrint(arena, ") {s}", .{case[2]}));
        try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "spectre/{s}_primitive_is_the_decks_one", .{case[2]}), &.{"LVS-071"}, try circuit.draw(arena, &c), text, true));
    }
}

fn multiplierAndToleranceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // F21 (fixed in B9), LVS-046: the multiplier.
    const cap = try fx.polar(arena, Dev.onPins(.c, &.{ 0, 1 }));
    const cap_m2 = try fx.polar(arena, Dev.onPins(.c, &.{ 0, 1 }).times(2));
    const caps = try Circuit.init(arena, 3, &.{ cap.devs[0], cap.devs[1], Dev.onPins(.c, &.{ 0, 1 }) });
    try out.append(arena, try fx.compared(arena, "multiplier/C_m2_vs_one", &.{"LVS-046"}, &cap, &cap_m2));
    try out.append(arena, try fx.compared(arena, "multiplier/C_m2_vs_two", &.{ "LVS-046", "LVS-044" }, &caps, &cap_m2));
    // A card without `m` is one device, whatever another card states (found
    // in B27): two parallel pairs against one bare card and one of `m = 2`.
    const pairs = try Circuit.init(arena, 4, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 2, 3 }), Dev.onPins(.c, &.{ 2, 3 }) });
    const bare_and_m2 = try Circuit.init(arena, 4, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 2, 3 }).times(2) });
    try out.append(arena, try fx.compared(arena, "multiplier/C_two_pairs_vs_bare_and_m2", &.{ "LVS-046", "LVS-044" }, &pairs, &bare_and_m2));
    const two = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 2, 1) });
    const wide = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150)});
    const m2 = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).times(2)});
    const one = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    try out.append(arena, try fx.compared(arena, "multiplier/mos_m2_vs_two", &.{ "LVS-046", "LVS-040" }, &two, &m2));
    try out.append(arena, try fx.compared(arena, "multiplier/mos_m2_vs_wide", &.{"LVS-046"}, &wide, &m2));
    try out.append(arena, try fx.compared(arena, "multiplier/mos_m2_vs_one", &.{ "LVS-046", "LVS-014" }, &one, &m2));

    // LVS-014, LVS-060: either side of 2 %, on W and on L, both signs.
    const square = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 1000)});
    for ([_]struct { []const u8, i64, i64 }{
        .{ "w-1.9", 981, 1000 },
        .{ "w-2.1", 979, 1000 },
        .{ "l+1.9", 1000, 1019 },
        .{ "l+2.1", 1000, 1021 },
        .{ "l-1.9", 1000, 981 },
        .{ "l-2.1", 1000, 979 },
    }) |case| {
        const r = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2).sized(case[1], case[2])});
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "tolerance/{s}", .{case[0]}), &.{ "LVS-014", "LVS-060" }, &square, &r));
    }
}

test "every curated LVS fixture of the first part holds" {
    // Oracle: each verdict the brute-force oracle's (`lvs_oracle.zig`),
    // decided from the documented reductions alone, or hand-derived where
    // the reference is edited text.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
