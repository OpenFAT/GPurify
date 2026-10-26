//! The named topology circuits: supply paths that stop at a port and pass a
//! resistor but not a diode, combinational loops of inverters, matched
//! units and power switches, each placed three ways. Ported from
//! crates/check/tests/erc/ported.rs (`path_stops_at_port`,
//! `path_through_resistor`, `combinational_loop`, `matched_unit`,
//! `matching`, `power_switch`; `named_topology_circuits_report_their_derived_findings`
//! less `topology_cases`, the lead's board enumeration).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const pc = @import("ported_circuit.zig");
const Dev = pc.Dev;
const dev = pc.dev;
const count = pc.count;
const length = pc.length;
const rect = pc.rect;
const riser = pc.riser;
const gpa = std.testing.allocator;

const Unit = struct { nets: [3]usize, rotated: bool = false, w: i64 = 1000 };

// ---- private ----

/// One 1.8 V domain `d` of VDD (power) and VSS (ground).
fn railIntent(arena: Allocator) ![]const u8 {
    return pc.intentText(arena, &.{.{ .name = "d", .mv = 1800 }}, &.{ .{ "VDD", "d", "power" }, .{ "VSS", "d", "ground" } });
}

/// `supply_path` (ERC-G9) stopping at a top-cell port, hand-derived from
/// the PERC patent's "a path continues until it reaches an unqualified
/// device or a port in the top cell" (US20100306720A1 [0262]). Nets VDD,
/// VSS, A, Y, an unlabelled net Z and G: an inverter from A to Y, and an
/// nfet passing Y to Z under gate G. Labels as names: Y and Z are one path
/// reaching both rails, A and G are flagged. Labels as ports: the path
/// stops at Y, so Z reaches no rail and is flagged too.
fn pathStopsAtPort(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vdd, const vss, const a, const y, const z, const g = .{ 0, 1, 2, 3, 4, 5 };
    const devs = [_]Dev{ dev(.pfet, a, vdd, y), dev(.nfet, a, vss, y), dev(.nfet, g, y, z) };
    const deck = pc.topo_process ++
        \\rule names1 supply_path(; both: false, labels_are_ports: false)
        \\rule names2 supply_path(; both: true, labels_are_ports: false)
        \\rule ports1 supply_path(; both: false, labels_are_ports: true)
        \\rule ports2 supply_path(; both: true, labels_are_ports: true)
        \\
    ;
    const two = try pc.repeat(arena, count(0), 2);
    const three = try pc.repeat(arena, count(0), 3);
    try pc.everyPlacement(arena, out, .{
        .name = "erc/supply_path/stops_at_port",
        .deck = deck,
        .layout = try pc.circuit(arena, &.{ "VDD", "VSS", "A", "Y", "", "G" }, &devs, &.{}),
        .intent = try railIntent(arena),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "names1", .findings = two },
            .{ .id = "names2", .findings = two },
            .{ .id = "ports1", .findings = three },
            .{ .id = "ports2", .findings = three },
        }),
    });
}

/// `supply_path` (ERC-G9) and `gate_path` (ERC-H3) through a resistor and
/// not through a diode, hand-derived. An nfet pulls A to VSS (gate G), a
/// resistor joins A to B, a diode joins B to C, and a second nfet has its
/// gate on B and both channel ends on VSS. A and B reach ground only (B
/// through two devices), C nothing, G is a gate alone.
fn pathThroughResistor(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vss, const a, const b, const g, const c = .{ 1, 2, 3, 4, 5 };
    const devs = [_]Dev{ dev(.nfet, g, vss, a), dev(.nfet, b, vss, vss) };
    const deck = pc.diode_process ++
        \\rule sp1 supply_path(; both: false, labels_are_ports: false)
        \\rule sp2 supply_path(; both: true, labels_are_ports: false)
        \\rule gp1 gate_path(; ground: true, max_devices: 1)
        \\rule gp2 gate_path(; ground: true, max_devices: 2)
        \\
    ;
    try pc.everyPlacement(arena, out, .{
        .name = "erc/supply_path/through_resistor",
        .deck = deck,
        .layout = try pc.circuitPins(arena, &.{ "VDD", "VSS", "A", "B", "G", "C" }, &devs, &.{ .{ .marker = "mkres", .a = a, .b = b }, .{ .marker = "mkdi", .a = b, .b = c } }),
        .intent = try railIntent(arena),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "sp1", .findings = &.{ count(0), count(0) } },
            .{ .id = "sp2", .findings = &.{ count(1), count(1), count(0), count(0) } },
            .{ .id = "gp1", .findings = &.{ count(2), count(0) } },
            .{ .id = "gp2", .findings = &.{count(0)} },
        }),
    });
}

/// `combinational_loop` (ERC-G8) on CMOS inverters, hand-derived: each
/// inverter's output is a channel-connected component driven by the one
/// holding its input. A chain is clean; a ring of three is one loop of 3,
/// a latch one of 2, a diode-connected nfet one of 1.
fn combinationalLoop(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vss, const a, const b, const c = .{ 1, 2, 3, 4 };
    // An inverter between VDD (net 0) and VSS (net 1).
    const inv = struct {
        fn of(input: usize, output: usize) [2]Dev {
            return .{ dev(.pfet, input, 0, output), dev(.nfet, input, 1, output) };
        }
    }.of;
    const Case = struct { name: []const u8, devs: []const Dev, findings: []const Finding };
    const cases = [_]Case{
        .{ .name = "chain", .devs = comptime &(inv(a, b) ++ inv(b, c)), .findings = &.{} },
        .{ .name = "ring3", .devs = comptime &(inv(a, b) ++ inv(b, c) ++ inv(c, a)), .findings = &.{count(3)} },
        .{ .name = "latch", .devs = comptime &(inv(a, b) ++ inv(b, a)), .findings = &.{count(2)} },
        .{ .name = "diode", .devs = &.{dev(.nfet, a, vss, a)}, .findings = &.{count(1)} },
    };
    for (cases) |cs| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/combinational_loop/{s}", .{cs.name}),
        .deck = pc.topo_process ++ "rule cl combinational_loop()\n",
        .layout = try pc.circuit(arena, &.{ "VDD", "VSS", "A", "B", "C" }, cs.devs, &.{}),
        .intent = try railIntent(arena),
        .expect = try arena.dupe(Expect, &.{.{ .id = "cl", .findings = cs.findings }}),
    });
}

/// One matched unit at column `x0`, `w` wide, its channel along x or,
/// `rotated`, along y, wired by risers to the tracks of `g`, `s`, `d`.
fn matchedUnit(l: *Layout, arena: Allocator, x0: i64, rotated: bool, w: i64, gsd: [3]usize) !void {
    const g, const s, const d = gsd;
    if (rotated) {
        try rect(l, arena, "diff", .{ x0, 0, x0 + w, 1000 });
        try rect(l, arena, "diff", .{ x0, 1200, x0 + w, 2200 });
        try rect(l, arena, "poly", .{ x0 - 700, 1000, x0 + w, 1200 });
        try rect(l, arena, "mkn", .{ x0, 1000, x0 + w, 1200 });
        try riser(l, arena, x0 - 700, 1000, g);
        try riser(l, arena, x0 + 100, 400, s);
        try riser(l, arena, x0 + w - 300, 1600, d);
    } else {
        try rect(l, arena, "diff", .{ x0, 0, x0 + 1000, w });
        try rect(l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, w });
        try rect(l, arena, "poly", .{ x0 + 1000, 0, x0 + 1200, w + 600 });
        try rect(l, arena, "mkn", .{ x0 + 1000, 0, x0 + 1200, w });
        try riser(l, arena, x0 + 400, 400, s);
        try riser(l, arena, x0 + 1600, 400, d);
        try riser(l, arena, x0 + 1000, w + 400, g);
    }
}

/// Units 4 µm apart in a row, the first `inside` of them in one `grp`.
fn matchBoard(arena: Allocator, units: []const Unit, inside: i64) !Layout {
    var l: Layout = .{};
    for (units, 0..) |u, k| try matchedUnit(&l, arena, @as(i64, @intCast(k)) * pc.pitch, u.rotated, u.w, u.nets);
    const right = @as(i64, @intCast(units.len)) * pc.pitch + 1000;
    for (0..pc.nets) |net| {
        const ty = pc.trackY(net);
        try rect(&l, arena, "met2", .{ -2000, ty, right, ty + pc.track_h });
    }
    try rect(&l, arena, "grp", .{ -1000, -500, inside * pc.pitch - 500, 2500 });
    return l;
}

/// `matching` (ERC-H2), hand-derived. Device A has its gate on net 1, B on
/// net 2, both from net 0 to net 3, every unit 1 µm wide and 200 nm long,
/// markers equal so a centroid is the mean. ABBA: centroids coincide.
/// ABAB: A at 4 µm, B at 8 µm, 4000 nm apart (flagged against 3999 nm,
/// clean at 4000 nm). A 1.2 µm B beside a 1 µm A: 200 nm. A unit turned
/// 90°: one crossing unit. ABAB with the last B outside: A and B both at
/// 4 µm.
fn matching(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const a: [3]usize = .{ 1, 0, 3 };
    const b: [3]usize = .{ 2, 0, 3 };
    const abab = [_]Unit{ .{ .nets = a }, .{ .nets = b }, .{ .nets = a }, .{ .nets = b } };
    const Case = struct { name: []const u8, units: []const Unit, inside: i64, tolerance: i64, findings: []const Finding };
    const cases = [_]Case{
        .{ .name = "abba", .units = &.{ .{ .nets = a }, .{ .nets = b }, .{ .nets = b }, .{ .nets = a } }, .inside = 4, .tolerance = 0, .findings = &.{} },
        .{ .name = "abab/below", .units = &abab, .inside = 4, .tolerance = 3999, .findings = &.{length(4000)} },
        .{ .name = "abab/at", .units = &abab, .inside = 4, .tolerance = 4000, .findings = &.{} },
        .{ .name = "width", .units = &.{ .{ .nets = a }, .{ .nets = b, .w = 1200 } }, .inside = 2, .tolerance = 100_000, .findings = &.{length(200)} },
        .{ .name = "crossing", .units = &.{ .{ .nets = a }, .{ .nets = a, .rotated = true } }, .inside = 2, .tolerance = 100_000, .findings = &.{count(1)} },
        .{ .name = "outside", .units = &abab, .inside = 3, .tolerance = 0, .findings = &.{} },
    };
    for (cases) |cs| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/matching/{s}", .{cs.name}),
        .deck = try std.fmt.allocPrint(arena, "{s}layer grp = gds(40, 0)\nrule mt matching(grp; tolerance: {d}nm)\n", .{ pc.topo_process, cs.tolerance }),
        .layout = try matchBoard(arena, cs.units, cs.inside),
        .expect = try arena.dupe(Expect, &.{.{ .id = "mt", .findings = cs.findings }}),
    });
}

/// `power_switch` (ERC-F14), hand-derived. VDD, VDDV, VSS and VDD2 are
/// supplies of one 1.8 V domain; `sleep` turns VDDV and VDD2 off. The
/// switch is a `clamp` gated by EN, which a pfet drives from a supply.
/// VDD to VDDV driven from VDD: clean. VDD to OUT, or to VSS: wiring, 0
/// against 1. Driven only from VDD2: EN floats in 1 state. Without power
/// states the row is skipped.
fn powerSwitch(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vdd, const vddv, const vss, const vdd2, const en, const out_net, const input = .{ 0, 1, 2, 3, 4, 5, 6 };
    const deck = pc.topo_process ++ "rule ps power_switch(; models: [\"clamp\"])\n";
    const supplies = try pc.intentText(arena, &.{.{ .name = "d", .mv = 1800 }}, &.{
        .{ "VDD", "d", "power" },
        .{ "VDDV", "d", "power" },
        .{ "VSS", "d", "ground" },
        .{ "VDD2", "d", "power" },
    });
    const with_sleep = try std.fmt.allocPrint(arena, "{s},\"states\":[{{\"name\":\"sleep\",\"off\":[\"VDDV\",\"VDD2\"],\"inputs\":[]}}]}}", .{supplies[0 .. supplies.len - 1]});
    const Case = struct { name: []const u8, output: usize, control: usize, findings: []const Finding };
    const cases = [_]Case{
        .{ .name = "good", .output = vddv, .control = vdd, .findings = &.{} },
        .{ .name = "to_signal", .output = out_net, .control = vdd, .findings = &.{count(0)} },
        .{ .name = "across_roles", .output = vss, .control = vdd, .findings = &.{count(0)} },
        .{ .name = "switched_control", .output = vddv, .control = vdd2, .findings = &.{count(1)} },
    };
    for (cases) |cs| {
        const devs = [_]Dev{ dev(.clamp, en, vdd, cs.output), dev(.pfet, input, cs.control, en) };
        const layout = try pc.circuit(arena, &.{ "VDD", "VDDV", "VSS", "VDD2", "EN", "OUT", "IN" }, &devs, &.{});
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/power_switch/{s}", .{cs.name}),
            .deck = deck,
            .layout = layout,
            .intent = with_sleep,
            .expect = try arena.dupe(Expect, &.{.{ .id = "ps", .findings = cs.findings }}),
        });
        if (std.mem.eql(u8, cs.name, "good")) try out.append(arena, .{
            .name = "erc/power_switch/no_states",
            .deck = deck,
            .layout = layout,
            .intent = supplies,
            .expect = try arena.dupe(Expect, &.{.{ .id = "ps", .outcome = .skipped }}),
        });
    }
}

// Oracle: the named circuits' hand-derived findings (the gate paths, loops,
// matched pairs and switches each group's doc comment derives).
test "named topology circuits report their derived findings" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try pathThroughResistor(arena, &all);
    try pathStopsAtPort(arena, &all);
    try combinationalLoop(arena, &all);
    try matching(arena, &all);
    try powerSwitch(arena, &all);
    try fixture.checkAll(all.items);
}
