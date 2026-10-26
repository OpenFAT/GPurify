//! Curated LVS fixtures, third part: shared diffusions, fingers and
//! unmeasurable parameters, flavours, bulks, symmetry, ports and verdict
//! classes. Ported from tests/exhaustive/lvs.rs (`curated`, from the shared
//! diffusion to its end).
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
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const fx = @import("lvs_fixture.zig");

/// A MOS's source and drain diffusion area and perimeter, in card order.
const diffusions = [4][]const u8{ "as", "ad", "ps", "pd" };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try sharedDiffusionInto(arena, out);
    try namesFlavoursBulksInto(arena, out);
    try symmetryPortsVerdictInto(arena, out);
}

// ---- private ----

/// A fixture over `text` claiming the LVS verdict `matched`.
fn texted(arena: Allocator, name: []const u8, catalog: []const []const u8, layout: Layout, text: []const u8, matched: bool) !Fixture {
    var f = try fx.withText(arena, name, catalog, layout, text);
    try f.claim(arena, .{ .lvs = matched });
    return f;
}

/// A 2000 / 150 nmos card stating `ends` as its `diffusions`.
fn card(ends: [4]f64) Dev {
    var dev = Dev.mos(.n, 0, 1, 2).sized(2000, 150);
    for (diffusions, ends) |name, v| dev = dev.param(name, v);
    return dev;
}

/// Two fingers sharing their middle diffusion, both gated by n0, the outer
/// diffusions on n1 and the middle on n2.
fn fingersInto(arena: Allocator, layout: *Layout) !void {
    try layout.rect(arena, "diff", 0, 0, 1800, 1000);
    try layout.rect(arena, "poly", 500, -200, 650, 1500);
    try layout.rect(arena, "poly", 1150, -200, 1300, 1500);
    try layout.rect(arena, "nsdm", -200, -300, 2000, 1200);
    for ([_][2]i64{ .{ 100, 1 }, .{ 750, 2 }, .{ 1400, 1 } }) |xn| {
        try layout.rect(arena, "cont", xn[0], 100, xn[0] + 300, 400);
        try stub(arena, layout, xn[0], xn[0] + 300, 100, @intCast(xn[1]));
    }
    for ([_]i64{ 500, 1150 }) |x| {
        try layout.rect(arena, "cont", x, 1250, x + 150, 1400);
        try stub(arena, layout, x, x + 150, 1250, 0);
    }
}

/// Tracks for nets 0..3 up to `right`, each labelled `n<k>`.
fn tracksInto(arena: Allocator, layout: *Layout, right: i64) !void {
    for (0..3) |net| {
        const t = circuit.track(net);
        try layout.rect(arena, "met2", -1000, t, right, t + 200);
        try layout.label(arena, "met2_label", -900, t + 100, try std.fmt.allocPrint(arena, "n{d}", .{net}));
    }
}

fn sharedDiffusionInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // Two fingers sharing their middle diffusion, both gated by n0, the outer
    // diffusions on n1 and the middle on n2, and an nmos gated by n1 that
    // tells n1 from n2. Derived by hand: each diffusion is 500 by 1000 nm,
    // the middle one shared two ways, so merged the fingers have 1 um² and
    // 6 um on n1 and 0.5 um² and 3 um on n2. A card with those at its source
    // (n1) and drain (n2) matches; one with them the other way round does
    // not. F98 (fixed in B31): without the sensor nothing tells n1 from n2,
    // so the card the other way round is the same circuit with n1 and n2
    // renamed, and names do not take part: both cards match.
    //
    // LVS-032: the fingers alone, their nets labelled. Labels break a tie
    // only after the diffusions (KLayout's `consider_net_names`): the
    // channel nets pair the way the diffusions agree (testing-plan F98), so
    // the card that puts 1 um² at its source n1 matches, and so does the
    // one that puts it at n2, the same transistor the other way round.
    for ([_]struct { []const u8, [4]f64, bool }{ .{ "as_labelled", .{ 1e-12, 5e-13, 6e-6, 3e-6 }, true }, .{ "against_the_labels", .{ 5e-13, 1e-12, 3e-6, 6e-6 }, true } }) |case| {
        var fingers: Layout = .{};
        try fingersInto(arena, &fingers);
        try tracksInto(arena, &fingers, column(1));
        try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "names/shared_diffusion_{s}", .{case[0]}), &.{ "LVS-032", "LVS-060" }, fingers, try circuit.spice(arena, &try Circuit.init(arena, 3, &.{card(case[1])})), case[2]));
    }
    const sensor = Dev.mos(.n, 1, 0, 0);
    for ([_]struct { []const u8, [4]f64, bool }{ .{ "source_and_drain", .{ 1e-12, 5e-13, 6e-6, 3e-6 }, true }, .{ "the_other_way_round", .{ 5e-13, 1e-12, 3e-6, 6e-6 }, false } }) |case| {
        // With the sensor.
        var sensed: Layout = .{};
        try fingersInto(arena, &sensed);
        try drawMos(arena, &sensed, column(1), &sensor);
        try tracksInto(arena, &sensed, column(2));
        try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "parallel/shared_diffusion_{s}", .{case[0]}), &.{ "LVS-060", "LVS-040" }, sensed, try circuit.spice(arena, &try Circuit.init(arena, 3, &.{ card(case[1]), sensor })), case[2]));
        // Without it.
        var symmetric: Layout = .{};
        try fingersInto(arena, &symmetric);
        try tracksInto(arena, &symmetric, column(2));
        try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "parallel/shared_diffusion_symmetric_{s}", .{case[0]}), &.{ "LVS-060", "LVS-040" }, symmetric, try circuit.spice(arena, &try Circuit.init(arena, 3, &.{card(case[1])})), true));
    }
}

fn namesFlavoursBulksInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const one = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    const nf = try circuit.edited(arena, try circuit.spice(arena, &one), "l=150n", "l=150n nf=1");
    try out.append(arena, try texted(arena, "params/nf_1_is_one_finger", &.{ "LVS-020", "LVS-060" }, try circuit.draw(arena, &one), nf, true));
    const unknown = try circuit.edited(arena, try circuit.spice(arena, &one), "l=150n", "l=150n foo=1");
    try out.append(arena, try texted(arena, "params/unmeasurable_param", &.{"LVS-020"}, try circuit.draw(arena, &one), unknown, false));

    // LVS-066: a flavour is its own model.
    const hvt = try Circuit.init(arena, 3, &.{Dev.mos(.h, 0, 1, 2)});
    const rows: []const []const u8 = &.{ "LVS-066", "LVS-013" };
    try out.append(arena, try fx.compared(arena, "flavour/hvt_vs_hvt", &.{"LVS-066"}, &hvt, &hvt));
    try out.append(arena, try fx.compared(arena, "flavour/hvt_vs_plain", rows, &hvt, &one));
    try out.append(arena, try fx.compared(arena, "flavour/plain_vs_hvt", rows, &one, &hvt));

    // LVS-045: bulks must agree for a merge.
    const wide_b = try Circuit.init(arena, 4, &.{Dev.mos(.b, 0, 1, 2).sized(2000, 150).bulk(3)});
    const parallel_rows: []const []const u8 = &.{ "LVS-045", "LVS-040" };
    const one_bulk = try bulked(arena, 3, 3, 4);
    try out.append(arena, try fx.compared(arena, "bulk/parallel_one_bulk_vs_wide", parallel_rows, &one_bulk, &wide_b));
    const split = try bulked(arena, 3, 4, 5);
    const joined = try bulked(arena, 3, 3, 4);
    try out.append(arena, try fx.compared(arena, "bulk/parallel_two_bulks_vs_two", parallel_rows, &split, &split));
    try out.append(arena, try fx.compared(arena, "bulk/parallel_two_bulks_vs_one_bulk", parallel_rows, &split, &joined));
    const blong = try (try Circuit.init(arena, 5, &.{Dev.mos(.b, 0, 1, 2).sized(1000, 300).bulk(4)})).compact(arena);
    const series_rows: []const []const u8 = &.{ "LVS-045", "LVS-041" };
    try out.append(arena, try fx.compared(arena, "bulk/stack_one_bulk_vs_long", series_rows, &try bstack(arena, 4), &blong));
    try out.append(arena, try fx.compared(arena, "bulk/stack_two_bulks_vs_long", series_rows, &try bstack(arena, 5), &blong));
}

/// Two parallel `nmosb` on bulks `b0` and `b1`, over `nets` nets.
fn bulked(arena: Allocator, b0: usize, b1: usize, nets: usize) !Circuit {
    return Circuit.init(arena, nets, &.{ Dev.mos(.b, 0, 1, 2).bulk(b0), Dev.mos(.b, 0, 2, 1).bulk(b1) });
}

/// A stack of `nmosb` through internal net 3, bulks 4 and `b1`, compacted.
fn bstack(arena: Allocator, b1: usize) !Circuit {
    const c = try Circuit.init(arena, 6, &.{ Dev.mos(.b, 0, 1, 3).bulk(4), Dev.mos(.b, 0, 3, 2).bulk(b1) });
    return (try c.internal(arena, 3)).compact(arena);
}

/// Two nmos that trade places under n1 <-> n2, n3 <-> n4, `w0` and `w1`
/// wide.
fn sym(arena: Allocator, w0: i64, w1: i64) !Circuit {
    return Circuit.init(arena, 5, &.{ Dev.mos(.n, 1, 0, 3).sized(w0, 150), Dev.mos(.n, 2, 0, 4).sized(w1, 150) });
}

fn symmetryPortsVerdictInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // LVS-018: a symmetry resolved by parameter. Two nmos that trade places
    // under n1 <-> n2, n3 <-> n4, drawn 1000 and 2000 wide; the reference
    // writes the widths the other way round, which is the same circuit.
    const rows: []const []const u8 = &.{ "LVS-018", "LVS-014" };
    try out.append(arena, try fx.compared(arena, "symmetry/widths_swapped", &.{"LVS-018"}, &try sym(arena, 1000, 2000), &try sym(arena, 2000, 1000)));
    try out.append(arena, try fx.compared(arena, "symmetry/widths_differ", rows, &try sym(arena, 1000, 2000), &try sym(arena, 1000, 1000)));
    // F58 (fixed in B17), its smallest cases: a class refinement cannot
    // split, which the closest-parameter pairing alone broke the wrong way.
    // The layout's own circuit with its cards reversed; and a circuit whose
    // one device is written 1.9 % wide.
    const lone = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 0, 0), Dev.mos(.n, 1, 1, 2), Dev.mos(.n, 2, 1, 2) });
    const text = try circuit.spiceOrdered(arena, &lone, &.{ 2, 1, 0 });
    try out.append(arena, try texted(arena, "symmetry/refinement_stall_reversed", &.{ "LVS-018", "LVS-019" }, try circuit.draw(arena, &lone), text, true));
    const cycle = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 0, 1), Dev.mos(.n, 1, 0, 2), Dev.mos(.n, 2, 1, 2) });
    var cycle_wide = try cycle.clone(arena);
    cycle_wide.devs[0].w = 1019;
    try out.append(arena, try fx.compared(arena, "symmetry/refinement_stall_by_parameter", rows, &cycle, &cycle_wide));

    // LVS-016: the port order of the reference does not matter.
    const inv = try Circuit.init(arena, 4, &.{ Dev.mos(.n, 0, 2, 1), Dev.mos(.p, 0, 3, 1) });
    const reordered = try circuit.edited(arena, try circuit.spice(arena, &inv), ".subckt TOP n0 n1 n2 n3", ".subckt TOP n3 n1 n0 n2");
    try out.append(arena, try texted(arena, "ports/reordered", &.{"LVS-016"}, try circuit.draw(arena, &inv), reordered, true));

    // LVS-019: two cells nothing instantiates is no top to compare, and the
    // comparison refuses rather than guesses.
    const spice_inv = try circuit.spice(arena, &inv);
    const two_tops = try std.mem.concat(arena, u8, &.{ spice_inv, try circuit.edited(arena, spice_inv, "TOP", "OTHER") });
    var f = try texted(arena, "verdict/ambiguous_top", &.{"LVS-019"}, try circuit.draw(arena, &inv), two_tops, false);
    try f.claim(arena, .{ .passes = false });
    try out.append(arena, f);
}

/// Device column `i`'s x (lvs_circuit.zig's pitch, private there).
fn column(i: usize) i64 {
    return 3000 * @as(i64, @intCast(i));
}

/// A met1 stub from `y0` up to `net`'s track over `x0..x1`, with the via
/// there (lvs_circuit.zig's, private there).
fn stub(arena: Allocator, layout: *Layout, x0: i64, x1: i64, y0: i64, net: usize) !void {
    const t = circuit.track(net);
    try layout.rect(arena, "met1", x0, y0, x1, t + 200);
    try layout.rect(arena, "via1", x0, t, x1, t + 200);
}

/// lvs_circuit.zig's MOS drawer, for an `nmos` in its own column (private
/// there): poly across diffusion, source left, drain right, gate contacted
/// above the diffusion.
fn drawMos(arena: Allocator, layout: *Layout, x0: i64, dev: *const Dev) !void {
    std.debug.assert(dev.model == .n);
    const w = dev.w;
    const xd = x0 + circuit.sd + dev.l;
    try layout.rect(arena, "diff", x0, 0, xd + circuit.sd, w);
    try layout.rect(arena, "poly", x0 + circuit.sd, -200, xd, w + 500);
    try layout.rect(arena, "nsdm", x0 - 200, -300, xd + circuit.sd + 200, w + 200);
    try layout.rect(arena, "cont", x0 + 100, 100, x0 + 400, 400);
    try layout.rect(arena, "cont", xd + 100, 100, xd + 400, 400);
    try layout.rect(arena, "cont", x0 + circuit.sd, w + 250, xd, w + 400);
    try stub(arena, layout, x0 + 100, x0 + 400, 100, dev.pins[1]);
    try stub(arena, layout, xd + 100, xd + 400, 100, dev.pins[2]);
    try stub(arena, layout, x0 + circuit.sd, xd, w + 250, dev.pins[0]);
}

test "every curated LVS fixture of the third part holds" {
    // Oracle: each verdict the brute-force oracle's (`lvs_oracle.zig`), or
    // hand-derived where the reference is edited text: the shared
    // diffusion's 1 um² and 6 um on n1, 0.5 um² and 3 um on n2.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
