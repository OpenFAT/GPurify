//! The ESD kinds across domains and pins, each on a circuit drawn by
//! `circuitPins` or as metal strips: which grounds an anti-parallel pair
//! couples, which crossings a domain's clamps protect and through what
//! resistance, junctions near a pad, exposed gates and drains and their
//! series resistance, and current injected into a guard ring. Ported from
//! crates/check/tests/erc/ported.rs (`ground_coupling`, `cross_domain`,
//! `strip_crossing`, `STRIP_PROCESS`, `cross_domain_resistance`,
//! `local_clamp`, `esd_parasitic`, `esd_exposed`, `esd_secondary`,
//! `ring_injection`, and the test
//! `esd_domains_and_latchup_rows_report_their_derived_findings`, less its
//! latch-up groups, which the latch-up family carries).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Finding = fixture.Finding;
const Layout = fixture.Layout;
const board = @import("board.zig");
const Dev = board.Dev;
const dev = board.dev;
const rect = board.rect;
const expect = @import("board_expect.zig");
const count = expect.count;
const length = expect.length;
const common = @import("ported_common.zig");
const Pin = common.Pin;
const at = common.at;
const ohms = common.ohms;
const microamps = common.microamps;
const side = common.side;
const sweep = common.sweep;
const circuitPins = common.circuitPins;
const gpa = testing.allocator;
const domain_nets = &common.domain_nets;

/// The domain nets by index.
const vdd1 = 0;
const vss1 = 1;
const vdd2 = 2;
const vss2 = 3;
const vss3 = 4;
const sig = 5;
const out_net = 6;

/// The strip crossing's process: met1 strips, poly gates contacted by `ct`.
const strip_process =
    \\grid 1nm
    \\layer m1 = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer ct = gds(3, 0)
    \\layer mkn = gds(4, 0)
    \\layer mkp = gds(5, 0)
    \\layer mkd = gds(6, 0)
    \\layer mkr = gds(7, 0)
    \\layer txt = gds(1, 1)
    \\connect conductors [m1, poly]
    \\connect touch_within_layer
    \\connect via ct [poly, m1]
    \\connect label txt names m1
    \\device mos mkn model "nfet" terminals [poly, m1, m1]
    \\device mos mkp model "pfet" terminals [poly, m1, m1]
    \\device diode mkd model "dio" terminals [m1, m1]
    \\device resistor mkr model "rs" terminals [m1, m1] sheet 100ohm
    \\pex m1 thickness 100nm height 100nm sheet 0.125ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex poly thickness 100nm height 50nm sheet 10ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex ct thickness 100nm height 75nm sheet 1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\
;

/// Hogan's crossing: an inverter in `d1` drives SIG from an input on VSS3
/// (a supply of its own domain, so only SIG and OUT cross), into an
/// inverter in `d2` whose output is OUT.
const crossing = [_]Dev{
    dev(.pfet, vss3, vdd1, sig),
    dev(.nfet, vss3, vss1, sig),
    dev(.pfet, sig, vdd2, out_net),
    dev(.nfet, sig, vss2, out_net),
};

// ---- private ----

/// `n` findings measuring 0, one per unprotected group or receiver.
fn zeros(arena: Allocator, n: usize) ![]const Finding {
    const out = try arena.alloc(Finding, n);
    @memset(out, count(0));
    return out;
}

/// `diodes` as `mkdi` columns `(anode, cathode)`.
fn dios(arena: Allocator, diodes: []const [2]usize) ![]const Pin {
    const out = try arena.alloc(Pin, diodes.len);
    for (out, diodes) |*p, d| p.* = .{ "mkdi", d[0], d[1] };
    return out;
}

fn domainFixture(arena: Allocator, name: []const u8, deck: []const u8, layout: Layout, id: []const u8, findings: []const Finding) !Fixture {
    return .{ .name = name, .deck = deck, .layout = layout, .intent = try common.domainIntent(arena), .expect = try common.expects(arena, &.{try common.rule(arena, id, findings)}) };
}

/// `esd_ground_coupling` (ERC-C5) over the three grounds VSS1, VSS2, VSS3:
/// the groups an anti-parallel pair of `dio` diodes (one each way) joins,
/// and one finding per group but one. A single diode couples nothing, a
/// chain of pairs couples all three, and a pair between a ground and a
/// power supply couples no ground.
fn groundCouplingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = common.diode_process ++ "rule gc esd_ground_coupling(; diodes: [\"dio\"])\n";
    const Case = struct { []const u8, []const [2]usize, usize };
    const cases = [_]Case{
        .{ "none", &.{}, 2 },
        .{ "one_way", &.{.{ vss1, vss2 }}, 2 },
        .{ "pair", &.{ .{ vss1, vss2 }, .{ vss2, vss1 } }, 1 },
        .{ "chain", &.{ .{ vss1, vss2 }, .{ vss2, vss1 }, .{ vss3, vss2 }, .{ vss2, vss3 } }, 0 },
        .{ "pair_to_power", &.{ .{ vss1, vss2 }, .{ vss2, vss1 }, .{ vss3, vdd2 }, .{ vdd2, vss3 } }, 1 },
    };
    for (cases) |case| {
        const name, const diodes, const findings = case;
        const f = try domainFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_ground_coupling/{s}", .{name}), deck, try circuitPins(arena, domain_nets, &.{}, try dios(arena, diodes)), "gc", try zeros(arena, findings));
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

/// `esd_cross_domain` (ERC-C4), the pseudocode of Hogan 2012 §II: both
/// receiver transistors of `crossing` see `d1` at the gate and `d2` on the
/// channel: "IF different power domains THEN check for anti-parallel
/// diodes", between VSS1 and VSS2. Unprotected, both are flagged; with the
/// pair, neither; with one diode, both. An inverter whose gate SIG is
/// reached by its own domain is no receiver.
fn crossDomainInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = common.diode_process ++ "rule xd esd_cross_domain(; diodes: [\"dio\"], local: none, resistors: none, min_series: none, max_ground_resistance: none, coupling_resistance: none)\n";
    const Case = struct { []const u8, []const [2]usize, usize };
    const cases = [_]Case{
        .{ "unprotected", &.{}, 2 },
        .{ "one_diode", &.{.{ vss1, vss2 }}, 2 },
        .{ "pair", &.{ .{ vss1, vss2 }, .{ vss2, vss1 } }, 0 },
        .{ "pair_through_vss3", &.{ .{ vss1, vss3 }, .{ vss3, vss1 }, .{ vss3, vss2 }, .{ vss2, vss3 } }, 0 },
    };
    for (cases) |case| {
        const name, const diodes, const findings = case;
        const f = try domainFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_cross_domain/{s}", .{name}), deck, try circuitPins(arena, domain_nets, &crossing, try dios(arena, diodes)), "xd", try zeros(arena, findings));
        try common.everyPlacementInto(arena, &.{f}, out);
    }
    // Both inverters in one domain: no receiver crosses.
    const same = [_]Dev{ dev(.pfet, vss3, vdd1, sig), dev(.nfet, vss3, vss1, sig), dev(.pfet, sig, vdd1, out_net), dev(.nfet, sig, vss1, out_net) };
    try out.append(arena, try domainFixture(arena, "erc/esd_cross_domain/one_domain", deck, try circuitPins(arena, domain_nets, &same, &.{}), "xd", &.{}));
    try localClampInto(arena, out);
    try crossDomainResistanceInto(arena, out);
}

/// A crossing drawn as metal strips, for `esd_cross_domain`'s series and
/// ground resistances: every net a 1 µm met1 strip (0.125 Ω per µm), each
/// transistor a 200 nm marker in the gap between the two strips it joins,
/// its gate a poly bar contacted to SIG. Domain 1 (VDD1 at y 4 µm, VSS1 at
/// 0) drives SIG (2 µm) at x 2 µm; domain 2 (VSS2 at -2 µm, OUT at -4 µm,
/// VDD2 at -6 µm) receives it, the nfet at x 18 µm and the pfet at 16 µm.
/// `dio` diodes join VSS1 to VSS2 at the given x. With `resistor`, SIG is
/// cut at 5 µm and a `rs` resistor (100 Ω/sq, 400 x 200 nm: 200 Ω) joins
/// the drivers' piece to the receivers'.
fn stripCrossing(arena: Allocator, diodes: []const i64, resistor: bool) !Layout {
    var l: Layout = .{};
    const Strip = struct { []const u8, i64, i64, i64 };
    var strips: std.ArrayList(Strip) = .empty;
    try strips.appendSlice(arena, &.{ .{ "VDD1", 4000, 0, 20_000 }, .{ "VSS1", 0, 0, 20_000 }, .{ "VSS2", -2000, 0, 20_000 }, .{ "OUT", -4000, 0, 20_000 }, .{ "VDD2", -6000, 0, 20_000 } });
    if (resistor) {
        try strips.appendSlice(arena, &.{ .{ "SIGD", 2000, 0, 5000 }, .{ "SIG", 2000, 5400, 20_000 } });
    } else try strips.append(arena, .{ "SIG", 2000, 0, 20_000 });
    for (strips.items) |s| {
        try rect(&l, arena, "m1", .{ s[2], s[1], s[3], s[1] + 1000 });
        try l.label(arena, "txt", s[2] + 100, s[1] + 500, s[0]);
    }
    if (resistor) try rect(&l, arena, "mkr", .{ 5000, 2400, 5400, 2600 });
    // Drivers: the nfet from VSS1 to SIG, the pfet from SIG to VDD1.
    for ([_]struct { []const u8, i64 }{ .{ "mkn", 1000 }, .{ "mkp", 3000 } }) |d| {
        try rect(&l, arena, d[0], .{ 2000, d[1], 2200, d[1] + 1000 });
        try rect(&l, arena, "poly", .{ 2000, d[1], 2200, d[1] + 1000 });
    }
    // Receivers, gated by SIG through a contacted poly bar.
    for ([_]struct { []const u8, i64, i64 }{ .{ "mkn", 18_000, -3000 }, .{ "mkp", 16_000, -5000 } }) |r| {
        try rect(&l, arena, r[0], .{ r[1], r[2], r[1] + 200, r[2] + 1000 });
        try rect(&l, arena, "poly", .{ r[1], r[2], r[1] + 200, 2700 });
        try rect(&l, arena, "ct", .{ r[1] + 50, 2400, r[1] + 150, 2600 });
    }
    for (diodes) |x| try rect(&l, arena, "mkd", .{ x - 100, -1000, x + 100, 0 });
    return l;
}

/// `esd_cross_domain`'s series resistor (ERC-C4) and driver/receiver
/// ground resistance (ERC-C9), limits deck-supplied, on `stripCrossing`.
/// Every case's two `dio` diodes face the same way, so TR18-01 5.1.3 flags
/// both receivers (0 against 1) whatever else is checked.
///
/// - Ground: the driver nfet attaches to VSS1 at 2.1 µm and the receiver
///   nfet to VSS2 at 18.1 µm; diodes at 10 and 10.4 µm, 1 Ω each. VSS1 to
///   10 µm is 0.9875 Ω, VSS2 from 10.4 µm 0.9625 Ω, and between them two
///   paths of 1 + 0.05 Ω in parallel, 0.525 Ω: 2.475 Ω, swept a part in a
///   thousand either side. The receiver pfet has no ground end and the
///   driver pfet's other end is a power: no other pair.
/// - Series: SIG driven straight reads 0 Ω for both receivers (flagged at
///   150 Ω); through the 200 Ω resistor both read 200 (flagged at 300,
///   clean at 150).
fn crossDomainResistanceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const intent = try board.intentText(arena, &.{ .{ .name = "d1", .mv = 1800.0 }, .{ .name = "d2", .mv = 1800.0 } }, &.{ .{ "VDD1", "d1", "power" }, .{ "VSS1", "d1", "ground" }, .{ "VDD2", "d2", "power" }, .{ "VSS2", "d2", "ground" } }, &.{});
    const ground = 2.475;
    for ([_]f64{ ground * 0.999, ground * 1.001 }) |limit| {
        var findings: std.ArrayList(Finding) = .empty;
        try findings.appendSlice(arena, &.{ count(0), count(0) });
        if (ground > limit) try findings.append(arena, ohms(ground));
        const f: Fixture = .{
            .name = try std.fmt.allocPrint(arena, "erc/esd_cross_domain/ground/{s}", .{side(limit, ground)}),
            .deck = try resistanceDeck(arena, "none", "none", try std.fmt.allocPrint(arena, "{d}ohm", .{limit}), "1ohm"),
            .layout = try stripCrossing(arena, &.{ 10_000, 10_400 }, false),
            .intent = intent,
            .expect = try common.expects(arena, &.{try common.rule(arena, "xd", findings.items)}),
        };
        try common.everyPlacementInto(arena, &.{f}, out);
    }
    const Case = struct { []const u8, bool, f64, ?f64 };
    for ([_]Case{ .{ "direct", false, 150.0, 0.0 }, .{ "through/below", true, 300.0, 200.0 }, .{ "through/above", true, 150.0, null } }) |case| {
        const name, const resistor, const min, const series = case;
        var findings: std.ArrayList(Finding) = .empty;
        try findings.appendSlice(arena, &.{ count(0), count(0) });
        if (series) |v| try findings.appendSlice(arena, &.{ ohms(v), ohms(v) });
        const f: Fixture = .{
            .name = try std.fmt.allocPrint(arena, "erc/esd_cross_domain/series/{s}", .{name}),
            .deck = try resistanceDeck(arena, "[\"rs\"]", try std.fmt.allocPrint(arena, "{d}ohm", .{min}), "none", "none"),
            .layout = try stripCrossing(arena, &.{ 10_000, 10_400 }, resistor),
            .intent = intent,
            .expect = try common.expects(arena, &.{try common.rule(arena, "xd", findings.items)}),
        };
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

fn resistanceDeck(arena: Allocator, resistors: []const u8, series: []const u8, ground: []const u8, coupling: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}rule xd esd_cross_domain(; diodes: [\"dio\"], local: none, resistors: {s}, min_series: {s}, max_ground_resistance: {s}, coupling_resistance: {s})\n", .{ strip_process, resistors, series, ground, coupling });
}

/// `esd_cross_domain`'s local clamp (ERC-C9): Hogan's crossing with its
/// grounds coupled, and `local: ["dio"]`. With no diode at SIG, both
/// receiver transistors lack one; a `dio` from VSS2 (the receivers' own
/// ground) to SIG clamps both; one from VSS1 (the driver's ground) clamps
/// neither.
fn localClampInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = common.diode_process ++ "rule xd esd_cross_domain(; diodes: [\"dio\"], local: [\"dio\"], resistors: none, min_series: none, max_ground_resistance: none, coupling_resistance: none)\n";
    const Case = struct { []const u8, []const [2]usize, usize };
    const cases = [_]Case{
        .{ "none", &.{ .{ vss1, vss2 }, .{ vss2, vss1 } }, 2 },
        .{ "own_ground", &.{ .{ vss1, vss2 }, .{ vss2, vss1 }, .{ vss2, sig } }, 0 },
        .{ "driver_ground", &.{ .{ vss1, vss2 }, .{ vss2, vss1 }, .{ vss1, sig } }, 2 },
    };
    for (cases) |case| {
        const name, const diodes, const findings = case;
        const f = try domainFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_cross_domain/local/{s}", .{name}), deck, try circuitPins(arena, domain_nets, &crossing, try dios(arena, diodes)), "xd", try zeros(arena, findings));
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

/// `esd_parasitic` (ERC-C10) on the domain fixtures' tracks with a pad on
/// SIG: a 1 µm diffusion riser-wired to `first` and another `gap` to its
/// right wired to `net`. Against a 5 µm spacing the pair is flagged when
/// the gap is below it and the nets differ: on OUT at 4 999 nm, not at
/// 5 000; on SIG itself never; two diffusions on OUT and VSS1, no pad
/// between them, never.
fn esdParasiticInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = common.diode_process ++ "rule par esd_parasitic(pad, diff; min_spacing: 5um)\n";
    const Case = struct { []const u8, usize, i64, usize, []const Finding };
    const cases = [_]Case{
        .{ "other_net/4999", sig, 4999, out_net, &.{length(4999)} },
        .{ "other_net/5000", sig, 5000, out_net, &.{} },
        .{ "same_net", sig, 1000, sig, &.{} },
        .{ "no_pad", vss1, 1000, out_net, &.{} },
    };
    for (cases) |case| {
        const name, const first, const gap, const net, const findings = case;
        var l = try circuitPins(arena, domain_nets, &.{}, &.{});
        try rect(&l, arena, "diff", .{ 0, -6000, 1000, -5000 });
        try board.riser(&l, arena, 400, -5900, first);
        const x0 = 1000 + gap;
        try rect(&l, arena, "diff", .{ x0, -6000, x0 + 1000, -5000 });
        try board.riser(&l, arena, x0 + 400, -5900, net);
        try common.padOn(&l, arena, sig);
        const f: Fixture = .{ .name = try std.fmt.allocPrint(arena, "erc/esd_parasitic/{s}", .{name}), .deck = deck, .layout = l, .expect = try common.expects(arena, &.{try common.rule(arena, "par", findings)}) };
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

/// `esd_exposed` (ERC-C3, Khazhinsky 2012's "input buffer gates and output
/// buffer drains") with a pad on SIG, `dio` clamps and an `rs` series
/// resistor from SIG to OUT. An input gate on SIG is protected by the
/// primary diodes (VSS1 to SIG, SIG to VDD1) and flagged without them
/// (rails 0) or with only the down one (rails 1); a gate on OUT behind the
/// resistor needs local diodes on OUT. An NMOS with its drain on SIG is an
/// output driver: flagged as `nfet`, protected as the ESD-rated `clamp`.
fn esdExposedInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = common.diode_process ++ "rule exp esd_exposed(pad; clamps: [\"dio\"], resistors: [\"rs\"], rated: [\"clamp\"], min_series: none)\n";
    const down: Pin = .{ "mkdi", vss1, sig };
    const up: Pin = .{ "mkdi", sig, vdd1 };
    const series: Pin = .{ "mkres", sig, out_net };
    const input = dev(.nfet, sig, vss1, vss3);
    const behind = dev(.nfet, out_net, vss1, vss3);
    const Case = struct { []const u8, Dev, []const Pin, []const Finding };
    const cases = [_]Case{
        .{ "input_primary", input, &.{ down, up }, &.{} },
        .{ "input_bare", input, &.{}, &.{count(0)} },
        .{ "input_down_only", input, &.{down}, &.{count(1)} },
        .{ "behind_bare", behind, &.{ down, up, series }, &.{count(0)} },
        .{ "output_unrated", dev(.nfet, vss3, vss1, sig), &.{ down, up }, &.{count(0)} },
        .{ "output_rated", dev(.clamp, vss3, vss1, sig), &.{ down, up }, &.{} },
        .{ "behind_local", behind, &.{ down, up, series, .{ "mkdi", vss1, out_net }, .{ "mkdi", out_net, vdd1 } }, &.{} },
    };
    for (cases) |case| {
        const name, const device, const pins, const findings = case;
        var l = try circuitPins(arena, domain_nets, &.{device}, pins);
        try common.padOn(&l, arena, sig);
        const f = try domainFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_exposed/{s}", .{name}), deck, l, "exp", findings);
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

/// `esd_exposed`'s `min_series` (ERC-C3), the secondary stage. The `rs`
/// resistor states `sheet 100ohm`; `circuitPins` draws its marker 400 nm
/// along its ends and 200 nm across, so each is 200 Ω. The pad is on SIG;
/// every gate behind a resistor has local clamps on its net.
///
/// - a gate on the pad net: 0 Ω, flagged against 150 Ω;
/// - behind one resistor: 200 Ω, flagged against 300 Ω, clean at 150 Ω;
/// - behind two in parallel: 100 Ω (effective), flagged against 150 Ω;
/// - behind two in series through MID: 400 Ω, clean against 300 Ω;
/// - a resistor with no `sheet` cannot be valued: the row is refused.
fn esdSecondaryInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const labels = [_][]const u8{ "VDD1", "VSS1", "VDD2", "VSS2", "VSS3", "SIG", "OUT", "MID" };
    const mid = 7;
    const input = dev(.nfet, sig, vss1, vss3);
    const behind = dev(.nfet, out_net, vss1, vss3);
    const primary = [_]Pin{ .{ "mkdi", vss1, sig }, .{ "mkdi", sig, vdd1 } };
    const local = [_]Pin{ .{ "mkdi", vss1, out_net }, .{ "mkdi", out_net, vdd1 } };
    const one = primary ++ [_]Pin{.{ "mkres", sig, out_net }} ++ local;
    const parallel = primary ++ [_]Pin{ .{ "mkres", sig, out_net }, .{ "mkres", sig, out_net } } ++ local;
    const chain = primary ++ [_]Pin{ .{ "mkres", sig, mid }, .{ "mkres", mid, out_net } } ++ local;
    const Case = struct { []const u8, Dev, []const Pin, f64, []const Finding };
    const cases = [_]Case{
        .{ "on_pad", input, &primary, 150.0, &.{ohms(0.0)} },
        .{ "one/below", behind, &one, 300.0, &.{ohms(200.0)} },
        .{ "one/above", behind, &one, 150.0, &.{} },
        .{ "parallel", behind, &parallel, 150.0, &.{ohms(100.0)} },
        .{ "series", behind, &chain, 300.0, &.{} },
    };
    for (cases) |case| {
        const name, const device, const pins, const min, const findings = case;
        var l = try circuitPins(arena, &labels, &.{device}, pins);
        try common.padOn(&l, arena, sig);
        const f = try domainFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_exposed/secondary/{s}", .{name}), try secondaryDeck(arena, common.valued_process, min), l, "exp", findings);
        try common.everyPlacementInto(arena, &.{f}, out);
        if (!std.mem.eql(u8, name, "one/below")) continue;
        var g = try domainFixture(arena, "erc/esd_exposed/secondary/unvalued", try secondaryDeck(arena, common.diode_process, min), l, "exp", &.{});
        g.expect = try common.expects(arena, &.{.{ .id = "exp", .outcome = .refused }});
        try out.append(arena, g);
    }
}

fn secondaryDeck(arena: Allocator, process: []const u8, min: f64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}rule exp esd_exposed(pad; clamps: [\"dio\"], resistors: [\"rs\"], rated: none, min_series: {d}ohm)\n", .{ process, min });
}

/// `esd_path` with a source layer (ERC-D4, JESD78's injection into a guard
/// ring): `met1` as the ring layer, so VSS's strip is the ring; 100 mA
/// forced in at its centre and out at VSS's own pin, a `pad` square at
/// 18 µm joined by one 0.25 Ω cut, with no clamps. Its path is 8 squares of
/// met1 (1 Ω) and the cut: 1.25 Ω exactly, swept below, at and above; the
/// 1 µm strip carries the whole 100 mA, flagged below 0.1 A/µm. With no pin
/// VSS is fed at the strip's centre, where the current enters: 0 Ω.
fn ringInjectionInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const unit: [3]i64 = @splat(1000);
    var pinned = try common.esdLayout(arena, unit, &.{});
    try common.pinVss(&pinned, arena);
    const intent = try common.esdIntent(arena);
    for (sweep(1.25)) |limit| {
        const findings: []const Finding = if (limit < 1.25) &.{at(ohms(1.25), 0, -3000)} else &.{};
        try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/esd_path/ring/{s}", .{side(limit, 1.25)}),
            .deck = try ringDeck(arena, try std.fmt.allocPrint(arena, "max_resistance: {d}ohm, max_density: none", .{limit})),
            .layout = pinned,
            .intent = intent,
            .expect = try common.expects(arena, &.{try common.rule(arena, "ring", findings)}),
        });
    }
    for ([_]f64{ 1e5 * 0.999, 1e5 * 1.001 }) |density| {
        const findings: []const Finding = if (density < 1e5) &.{microamps(1e5)} else &.{};
        const f: Fixture = .{
            .name = try std.fmt.allocPrint(arena, "erc/esd_path/ring/density/{s}", .{side(density, 1e5)}),
            .deck = try ringDeck(arena, try std.fmt.allocPrint(arena, "max_resistance: none, max_density: {d}A/m", .{density})),
            .layout = pinned,
            .intent = intent,
            .expect = try common.expects(arena, &.{try common.rule(arena, "ring", findings)}),
        };
        try common.everyPlacementInto(arena, &.{f}, out);
    }
    try out.append(arena, .{
        .name = "erc/esd_path/ring/unpinned",
        .deck = try ringDeck(arena, "max_resistance: 0.001ohm, max_density: none"),
        .layout = try common.esdLayout(arena, unit, &.{}),
        .intent = intent,
        .expect = try common.expects(arena, &.{.{ .id = "ring" }}),
    });
}

fn ringDeck(arena: Allocator, limits: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}rule ring esd_path(pad, met1; clamps: none, current: 100mA, clamp_resistance: 1ohm, {s}, clamp_it2: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none)\n", .{ common.esd_process, limits });
}

test "esd domains and pins report their derived findings" {
    // Oracle: the constructions in each group's doc comment: which grounds
    // an anti-parallel pair couples, which crossings a domain's clamps
    // protect, junction spacings, exposed gates and their series
    // resistance, the injected current's closed-form path.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try ringInjectionInto(arena, &all);
    try groundCouplingInto(arena, &all);
    try crossDomainInto(arena, &all);
    try esdParasiticInto(arena, &all);
    try esdExposedInto(arena, &all);
    try esdSecondaryInto(arena, &all);
    try fixture.checkAll(all.items);
}
