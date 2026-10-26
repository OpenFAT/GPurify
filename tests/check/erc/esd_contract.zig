//! `esd_exposed`'s and `esd_path`'s contracts where the ported fixtures
//! leave them open: which resistors make up the exposed series network;
//! a clamp's on-resistance other than 1 Ω under `clamp_voltage`, a
//! turned-on network that drives a clamp backwards, a source polygon on no
//! net, a reverse-biased diode of an unlisted model, pins that are not the
//! supply's feed point, and a transistor clamp on three path nets. Ported
//! from crates/check/tests/erc/esd_exposed_contract.rs and
//! crates/check/tests/erc/esd_path_contract.rs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Finding = fixture.Finding;
const Layout = fixture.Layout;
const board = @import("board.zig");
const dev = board.dev;
const rect = board.rect;
const millivolts = @import("board_expect.zig").millivolts;
const common = @import("ported_common.zig");
const Pin = common.Pin;
const at = common.at;
const ohms = common.ohms;
const microamps = common.microamps;
const esdLayout = common.esdLayout;
const gpa = testing.allocator;

/// Every strip 1 µm wide.
const unit: [3]i64 = @splat(1000);

/// Every `esd_path` limit but `max_resistance`, `none`.
const resistance_only = "clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none";

// ---- private ----

/// The gate on OUT behind one listed resistor from SIG, its own local
/// clamps, the pad on SIG with `dio` clamps to VDD1 and VSS1, plus `extra`
/// columns; one `esd_exposed` row over `dio` and `rs`, valued, with a
/// second resistor model `rs2` (`mkres2`) the row does not list.
fn exposed(arena: Allocator, name: []const u8, extra: []const Pin, min: f64, claim: Expect) !Fixture {
    const labels = [_][]const u8{ "VDD1", "VSS1", "VDD2", "VSS2", "VSS3", "SIG", "OUT", "MID" };
    const vdd1 = 0;
    const vss1 = 1;
    const vss3 = 4;
    const sig = 5;
    const out = 6;
    var pins: std.ArrayList(Pin) = .empty;
    try pins.appendSlice(arena, &.{ .{ "mkdi", vss1, sig }, .{ "mkdi", sig, vdd1 }, .{ "mkres", sig, out }, .{ "mkdi", vss1, out }, .{ "mkdi", out, vdd1 } });
    try pins.appendSlice(arena, extra);
    var l = try common.circuitPins(arena, &labels, &.{dev(.nfet, out, vss1, vss3)}, pins.items);
    try common.padOn(&l, arena, sig);
    return .{
        .name = name,
        .deck = try std.fmt.allocPrint(arena, "{s}layer mkres2 = gds(29, 0)\ndevice resistor mkres2 model \"rs2\" terminals [diff, diff] sheet 100ohm\nrule exp esd_exposed(pad; clamps: [\"dio\"], resistors: [\"rs\"], rated: none, min_series: {d}ohm)\n", .{ common.valued_process, min }),
        .layout = l,
        .intent = try common.domainIntent(arena),
        .expect = try common.expects(arena, &.{claim}),
    };
}

/// One `esd_path` row `ep` forcing 1.33 A with every limit written out,
/// under the ESD intent.
fn path(arena: Allocator, name: []const u8, process: []const u8, clamps: []const u8, ohm: f64, limits: []const u8, layout: Layout, claim: Expect) !Fixture {
    return .{
        .name = name,
        .deck = try std.fmt.allocPrint(arena, "{s}rule ep esd_path(pad; clamps: {s}, current: 1330mA, clamp_resistance: {d}ohm, {s})\n", .{ process, clamps, ohm, limits }),
        .layout = layout,
        .intent = try common.esdIntent(arena),
        .expect = try common.expects(arena, &.{claim}),
    };
}

/// Runs `fixtures` in a fresh arena `build` fills.
fn checkBuilt(build: fn (Allocator, *std.ArrayList(Fixture)) anyerror!void) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var all: std.ArrayList(Fixture) = .empty;
    try build(arena_state.allocator(), &all);
    try fixture.checkAll(all.items);
}

test "a resistor of an unlisted model is not in the series network" {
    // Oracle: the rustdoc: the series network is the `resistors` models'
    // alone, so the gate stays 200 Ω behind the pad, clean against 150 Ω;
    // counted, the two in parallel would be 100 Ω and flagged.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            try out.append(arena, try exposed(arena, "esd_exposed/unlisted_parallel", &.{.{ "mkres2", 5, 6 }}, 150.0, .{ .id = "exp" }));
        }
    }.build);
}

test "a resistor to a rail is not in the series network" {
    // Oracle: the rustdoc: only resistors with both ends among the exposed
    // nets (the pads and what listed resistors reach, never a rail) are in
    // the network, so the pull-down is left out and the gate is 200 Ω
    // behind the pad, flagged against 300 Ω.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            try out.append(arena, try exposed(arena, "esd_exposed/pull_down", &.{.{ "mkres", 6, 1 }}, 300.0, try common.rule(arena, "exp", &.{ohms(200.0)})));
        }
    }.build);
}

test "a two ohm clamp holding 700 mV raises the pin by the white paper sum" {
    // Oracle: the closed form: one down diode at 2 µm, its clamp 2 Ω and
    // holding 700 mV once on; the path is the pad's 8 squares (0.5 Ω), the
    // clamp (2 Ω) and VSS's 8 squares (1 Ω): the pin rises 1.33 A × 3.5 Ω
    // + 700 mV = 5355 mV (White Paper 2's sum), and the clamp, alone in
    // series, carries all 1.33 A, rated `it2` times its 4.8 µm perimeter;
    // each limit a part in a thousand either side.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            const rise = 1330.0 * 3.5 + 700.0;
            const rated = 1.33 / 4.8e-6;
            for ([_]f64{ 0.999, 1.001 }) |scale| {
                const limits = try std.fmt.allocPrint(arena, "max_resistance: none, clamp_it2: {d}A/m, max_density: none, max_current_per_cut: none, max_voltage: {d}mV, min_width: none, clamp_voltage: 700mV", .{ rated * scale, rise * scale });
                const findings: []const Finding = if (scale < 1.0) &.{ at(millivolts(rise), 0, 0), at(microamps(1.33e6), 1900, -2100) } else &.{};
                try out.append(arena, try path(arena, try std.fmt.allocPrint(arena, "esd_path/two_ohm_turn_on/{s}", .{common.side(scale, 1.0)}), common.esd_process, common.esd_clamps, 2.0, limits, try esdLayout(arena, unit, &.{.{ .down, 2000 }}), try common.rule(arena, "ep", findings)));
            }
        }
    }.build);
}

test "a turn on that drives a parallel clamp backwards refuses the row" {
    // Oracle: the solve: a down diode at 2 µm, an up diode at 18 µm and a
    // rail diode at 10 µm, each 1 Ω and holding 5 V once on. To VSS,
    // `P = 2.5 (1.33 A − I) + 5 V = 3 I + 10 V`, so the up-rail path
    // carries `I = −304.5 mA`; to VDD, `2 (1.33 A − I) + 5 V = 3.5 I +
    // 10 V`, `I = −425.8 mA`: the turned-on network drives its clamps
    // backwards, which is not modelled, so the row is refused.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            const limits = "max_resistance: none, clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: 100000mV, min_width: none, clamp_voltage: 5000mV";
            try out.append(arena, try path(arena, "esd_path/backwards", common.esd_process, common.esd_clamps, 1.0, limits, try esdLayout(arena, unit, &.{ .{ .down, 2000 }, .{ .up, 18_000 }, .{ .rail, 10_000 } }), .{ .id = "ep", .outcome = .refused }));
        }
    }.build);
}

test "a source polygon on no net is never stressed" {
    // Oracle: the rustdoc: each source polygon's net reaches supplies; a
    // diode marker is on no net, so nothing enters there and no pair is
    // solved, under a limit every real pair (2.5 Ω) would break.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            var f = try path(arena, "esd_path/source_on_no_net", common.esd_process, common.esd_clamps, 1.0, "max_resistance: 1ohm, " ++ resistance_only, try esdLayout(arena, unit, &.{.{ .down, 2000 }}), .{ .id = "ep", .examined = 0 });
            f.deck = try std.mem.replaceOwned(u8, arena, f.deck, "esd_path(pad;", "esd_path(pad, mkd;");
            try out.append(arena, f);
        }
    }.build);
}

test "a reverse biased diode of an unlisted model is no clamp" {
    // Oracle: the rustdoc: only devices of the listed models are clamps, so
    // the unlisted `down2` diode at 18 µm carries nothing and the pair
    // stays 2.5 Ω, flagged against 2.4975 Ω; counted as a clamp it would
    // open a parallel path and lower the resistance below that limit.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            const process = common.esd_process ++ "layer mkd2 = gds(15, 0)\ndevice diode mkd2 model \"down2\" terminals [met1, pad]\n";
            var l = try esdLayout(arena, unit, &.{.{ .down, 2000 }});
            try rect(&l, arena, "mkd2", .{ 17_900, -2100, 18_100, 100 });
            const limits = try std.fmt.allocPrint(arena, "max_resistance: {d}ohm, {s}", .{ 2.5 * 0.999, resistance_only });
            try out.append(arena, try path(arena, "esd_path/unlisted_diode", process, "[\"down\"]", 1.0, limits, l, try common.rule(arena, "ep", &.{at(ohms(2.5), 0, 0)})));
        }
    }.build);
}

test "a supply with pins is held at its pins not its feed point" {
    // Oracle: the rustdoc: a supply with pins is held at its pins, never
    // its feed point: with the pad layer drawn below met1, VSS's highest
    // shape is the strip, yet the path is the pad's 0.5 Ω, the 1 Ω diode,
    // VSS's 16 squares (2 Ω) and the cut, 3.75 Ω, flagged against 3.746 Ω.
    // The pin is a pin of VSS too, stressed against VSS itself: two pairs.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            const low_pad = try std.mem.replaceOwned(u8, arena, common.esd_process, "height 500nm", "height 50nm");
            try testing.expect(!std.mem.eql(u8, low_pad, common.esd_process));
            var l = try esdLayout(arena, unit, &.{.{ .down, 2000 }});
            try common.pinVss(&l, arena);
            const limits = try std.fmt.allocPrint(arena, "max_resistance: {d}ohm, {s}", .{ 3.75 * 0.999, resistance_only });
            var claim = try common.rule(arena, "ep", &.{at(ohms(3.75), 0, 0)});
            claim.examined = 2;
            try out.append(arena, try path(arena, "esd_path/pinned_below_the_feed_point", low_pad, common.esd_clamps, 1.0, limits, l, claim));
        }
    }.build);
}

test "a clamp on three path nets is flagged once per pin pair" {
    // Oracle: the rustdoc: a clamp joining three or more path nets carries
    // the largest current of its pairs, one violation per clamp, so each
    // of the two pin pairs (to VDD, to VSS) flags the MOS clamp once,
    // rated a token 1 A/m: two findings, at its marker.
    try checkBuilt(struct {
        fn build(arena: Allocator, out: *std.ArrayList(Fixture)) anyerror!void {
            const pad = 0;
            const vdd = 1;
            const vss = 2;
            var l = try common.circuitPins(arena, &.{ "PAD", "VDD", "VSS" }, &.{dev(.clamp, vdd, pad, vss)}, &.{});
            try common.padOn(&l, arena, pad);
            const limits = "max_resistance: none, clamp_it2: 1A/m, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none";
            const marker = at(.{}, 1000, 0);
            var claim = try common.rule(arena, "ep", &.{ marker, marker });
            claim.examined = 2;
            try out.append(arena, try path(arena, "esd_path/three_net_clamp", common.diode_process, "[\"clamp\"]", 1.0, limits, l, claim));
        }
    }.build);
}
