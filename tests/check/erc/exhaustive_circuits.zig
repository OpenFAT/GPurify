//! Named circuits for the bulk, hot-carrier and net-type kinds, each a
//! circuit of transistors and two-pin devices drawn on met2 tracks, its
//! findings hand-derived from the source the kind cites, placed three
//! ways. Ported from tests/exhaustive/erc.rs (`well_sharing_cases`,
//! `hot_carrier_cases`, `net_type_cases`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const pc = @import("ported_circuit.zig");
const Dev = pc.Dev;
const Pin = pc.Pin;
const dev = pc.dev;
const bulk = pc.bulk;
const count = pc.count;
const length = pc.length;
const gpa = std.testing.allocator;

// ---- private ----

/// `well_sharing` (ERC-D9), hand-derived from US 5,638,286's three
/// conditions on the patent's own situations. Nets VDD1, VDD2, VSS, A, X,
/// Y, Z, W; every pfet has its bulk (its well) on a stated net.
///
/// - `ok`: P1 (source VDD1, well VDD1) meets condition 1; P2, from X (P1's
///   drain) to Y in the same well, meets condition 3 through P1. Clean.
/// - `other_supply`: P1 and P2 as above, and P3 from VDD2 to Z in the VDD1
///   well, Z reaching only an nfet to VSS: the patent's Q5, fed from a supply
///   other than its well's. One finding (0 conditions against 1).
/// - `resistor`: as `other_supply` with a resistor from VDD2 to VDD1: clean
///   when resistors count (condition 2), one finding when they do not.
/// - `other_well`: P4 in the VDD1 well fed at W by P5, whose well is VDD2;
///   condition 3 needs the same well, so P4 is flagged, and so is P5 (its
///   ends, VDD1 and W, reach its VDD2 well only through P4). Two findings.
///
/// Breaks if the chain may cross another well's transistors (P4 clears), a
/// resistor counts when the deck says not (P3 clears), or a transistor's
/// own channel counts as its chain (P3 and P4 clear).
fn wellSharingCases(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const labels = [_][]const u8{ "VDD1", "VDD2", "VSS", "A", "X", "Y", "Z", "W" };
    const vdd1, const vdd2, const vss, const a, const x, const y, const z, const w = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const base = [_]Dev{ bulk(.pfet_b, a, vdd1, x, vdd1), bulk(.pfet_b, a, x, y, vdd1) };
    const other = base ++ [_]Dev{ bulk(.pfet_b, a, vdd2, z, vdd1), dev(.nfet, a, vss, z) };
    const other_well = [_]Dev{ bulk(.pfet_b, a, w, z, vdd1), bulk(.pfet_b, a, vdd1, w, vdd2) };
    const deck = pc.diode_process ++
        \\rule ws well_sharing(; models: ["pfet_b"], resistors: true)
        \\rule wsr well_sharing(; models: ["pfet_b"], resistors: false)
        \\
    ;
    const Case = struct { name: []const u8, devs: []const Dev, pins: []const Pin = &.{}, ws: usize, wsr: usize };
    const cases = [_]Case{
        .{ .name = "ok", .devs = &base, .ws = 0, .wsr = 0 },
        .{ .name = "other_supply", .devs = &other, .ws = 1, .wsr = 1 },
        .{ .name = "resistor", .devs = &other, .pins = &.{.{ .marker = "mkres", .a = vdd2, .b = vdd1 }}, .ws = 0, .wsr = 1 },
        .{ .name = "other_well", .devs = &other_well, .ws = 2, .wsr = 2 },
    };
    for (cases) |cs| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/well_sharing/{s}", .{cs.name}),
        .deck = deck,
        .layout = try pc.circuitPins(arena, &labels, cs.devs, cs.pins),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "ws", .findings = try pc.repeat(arena, count(0), cs.ws) },
            .{ .id = "wsr", .findings = try pc.repeat(arena, count(0), cs.wsr) },
        }),
    });
}

/// `hot_carrier` (ERC-F4), hand-derived from GF180MCU §14.1.4.1 (e) as the
/// kind reads "bi-directional". Every transistor is 200 nm long. Nets VDD,
/// VSS, A, B, X, Y, G, N1, OUT, Z, GB: inverters A->X and B->Y; an nfet and
/// a pfet (a transmission gate, gates G and GB) between X and Y; a NAND of A
/// and B onto OUT (its upper nfet between N1 and OUT); a second
/// transmission gate passing OUT to Z, which nothing else reaches.
///
/// - The first transmission gate's nfet: X and Y each reach VDD and VSS
///   through their own inverter, its pfet partner set aside: used both ways.
/// - The NAND's upper nfet: N1 reaches VSS alone. The second transmission
///   gate: Z reaches nothing once its partner is set aside. The inverters
///   and the NAND's other devices: a supply end. None is flagged.
/// - `hcn` (nfet, 200 nm): 1 finding, 200 nm. `hcnp` (nfet and pfet): the
///   first gate's pfet too, 2. `short` (199 nm): no device is minimum, 0.
///
/// Breaks if a partner carries the walk (the second gate's devices are
/// flagged, Z reaching OUT through each other), if a stack's inner node
/// counts as driven both ways (the NAND's upper nfet is flagged), or if the
/// length limit is not inclusive (`hcn` clears).
fn hotCarrierCases(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const labels = [_][]const u8{ "VDD", "VSS", "A", "B", "X", "Y", "G", "N1", "OUT", "Z", "GB" };
    const vdd, const vss, const a, const b, const x, const y, const g, const n1, const out_net, const z, const gb = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const devs = [_]Dev{
        dev(.pfet, a, vdd, x),       dev(.nfet, a, vss, x),
        dev(.pfet, b, vdd, y),       dev(.nfet, b, vss, y),
        dev(.nfet, g, x, y),         dev(.pfet, gb, x, y),
        dev(.nfet, a, vss, n1),      dev(.nfet, b, n1, out_net),
        dev(.pfet, a, vdd, out_net), dev(.pfet, b, vdd, out_net),
        dev(.nfet, g, out_net, z),   dev(.pfet, gb, out_net, z),
    };
    const deck = pc.topo_process ++
        \\rule hcn warning hot_carrier(; models: ["nfet"], max_length: 200nm)
        \\rule hcnp warning hot_carrier(; models: ["nfet", "pfet"], max_length: 200nm)
        \\rule short warning hot_carrier(; models: ["nfet", "pfet"], max_length: 199nm)
        \\
    ;
    try pc.everyPlacement(arena, out, .{
        .name = "erc/hot_carrier/pass_gates",
        .deck = deck,
        .layout = try pc.circuit(arena, &labels, &devs, &.{}),
        .intent = try pc.intentText(arena, &.{.{ .name = "d", .mv = 1800 }}, &.{ .{ "VDD", "d", "power" }, .{ "VSS", "d", "ground" } }),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "hcn", .findings = try arena.dupe(Finding, &.{length(200)}) },
            .{ .id = "hcnp", .findings = try pc.repeat(arena, length(200), 2) },
            .{ .id = "short" },
        }),
    });
}

/// `net_type` (ERC-H3), hand-derived from the PERC patent's own examples
/// (US20100306720A1). Nets VDD, VSS, A, OUT, N1, N2: an inverter from A to
/// OUT and a resistor (model `rs`) from N1 to N2. The intent types `VDD?`
/// as `power`, `VSS?` as `ground` (a `?` matching no character), the set
/// `supply` as either, `label_a` on the resistor's nets ([0239]), `gated`
/// on nfet gates, and `pw` on `lvsPower`.
///
/// - `init5` ([0267]: break on `{power ground}`, which is AND, so nothing
///   breaks; exclude power): one path VDD-OUT-VSS typed power and ground.
///   `net: ! power ground, path: ! power ground` (`check_1`, [0460]) flags
///   the nets with no path to either: A and the resistor's N1 and N2.
/// - `init6` (break on the set `supply`, exclude power and ground): VDD and
///   VSS break, so OUT is a path of its own with no type; `check_1` now
///   reports OUT too: A, OUT, N1, N2.
/// - `label`: `net: label_a` flags N1 and N2; `gate`: `net: gated`, A;
///   `power`: `net: pw`, VDD.
///
/// Each measures 1 against 0. Breaks if an AND break splits paths
/// (`init5` gains OUT), break nets lend excluded types (`init6` loses OUT),
/// or a pattern, pin list or reserved name assigns the wrong nets.
fn netTypeCases(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vdd, const vss, const a, const out_net, const n1, const n2 = .{ 0, 1, 2, 3, 4, 5 };
    const devs = [_]Dev{ dev(.pfet, a, vdd, out_net), dev(.nfet, a, vss, out_net) };
    const deck = pc.diode_process ++
        \\rule init5 net_type(; net: ["!", "power", "ground"], path: ["!", "power", "ground"], break: ["power", "ground"], exclude: ["power"])
        \\rule init6 net_type(; net: ["!", "power", "ground"], path: ["!", "power", "ground"], break: ["supply"], exclude: ["power", "ground"])
        \\rule label net_type(; net: ["label_a"], path: none, break: none, exclude: none)
        \\rule gate net_type(; net: ["gated"], path: none, break: none, exclude: none)
        \\rule power net_type(; net: ["pw"], path: none, break: none, exclude: none)
        \\
    ;
    try pc.everyPlacement(arena, out, .{
        .name = "erc/net_type/perc_examples",
        .deck = deck,
        .layout = try pc.circuitPins(arena, &.{ "VDD", "VSS", "A", "OUT", "N1", "N2" }, &devs, &.{.{ .marker = "mkres", .a = n1, .b = n2 }}),
        .intent =
        \\{"domains":{"d":{"voltage_mv":1800}},
        \\ "supplies":[{"net":"VDD","domain":"d","role":"power"},
        \\             {"net":"VSS","domain":"d","role":"ground"}],
        \\ "net_types":[{"type":"power","nets":["VDD?"]},
        \\              {"type":"ground","nets":["VSS?"]},
        \\              {"type":"label_a","models":["rs"]},
        \\              {"type":"gated","models":["nfet"],"pins":["g"]},
        \\              {"type":"pw","nets":["lvsPower"]}],
        \\ "type_sets":[{"set":"supply","types":["power","ground"]}]}
        ,
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "init5", .findings = try pc.repeat(arena, count(1), 3) },
            .{ .id = "init6", .findings = try pc.repeat(arena, count(1), 4) },
            .{ .id = "label", .findings = try pc.repeat(arena, count(1), 2) },
            .{ .id = "gate", .findings = try arena.dupe(Finding, &.{count(1)}) },
            .{ .id = "power", .findings = try arena.dupe(Finding, &.{count(1)}) },
        }),
    });
}

// Oracle: US 5,638,286's three well-sharing conditions on the patent's own
// situations (ok clean; other_supply 1; resistor 0 with resistors, 1
// without; other_well 2), GF180MCU §14.1.4.1 (e) read bi-directional (hcn
// 1 at 200 nm, hcnp 2, short 0), and the PERC patent's net_type examples
// US20100306720A1 [0239], [0267], [0460] (init5 A, N1, N2; init6 adds OUT;
// label N1, N2; gate A; power VDD), each placed three ways.
test "bulk, hot-carrier and net-type circuits report their derived findings" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try wellSharingCases(arena, &all);
    try hotCarrierCases(arena, &all);
    try netTypeCases(arena, &all);
    try fixture.checkAll(all.items);
}
