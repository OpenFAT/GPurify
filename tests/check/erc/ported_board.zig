//! The topology and voltage kinds against the board oracle
//! (board_expect.zig): the enumerations over small circuits, the named
//! circuits (an inverter pair, a NAND2, drawing order, hv isolation, the
//! well-bias cases, power states), and the ESD clamp paths and guard ring.
//! Ported from crates/check/tests/erc/ported.rs (`three_rails`, `two_rails`,
//! `canonical_assignments`, `all_assignments`, `sample`,
//! `topology_enumerations`, `topology_cases`, `nand2_fixture`, `esd`, and
//! the tests `topology_boards_match_a_naive_judge_of_the_planted_circuit`,
//! `named_topology_circuits_report_their_derived_findings` (its
//! `topology_cases` part) and `esd_paths_match_their_closed_forms` (its
//! `esd` part)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const testgen = @import("testgen");
const Rng = testgen.Rng;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Finding = fixture.Finding;
const board = @import("board.zig");
const Board = board.Board;
const Dev = board.Dev;
const dev = board.dev;
const expect = @import("board_expect.zig");
const count = expect.count;
const length = expect.length;
const gpa = testing.allocator;

const nets = board.nets;

/// An assignment of terminals to nets.
const Assignment = []const usize;

// ---- private ----

/// Nets 0-3 as VDD (1.8 V, domain a), VSS (ground, a), VDDH (3.3 V, domain
/// b) and an unlabelled signal.
fn threeRails(with_intent: bool) Board {
    return .{
        .labels = .{ "VDD", "VSS", "VDDH", null },
        .supplies = &.{
            .{ .net = 0, .power = true, .domain = 0, .nominal = 1800.0 },
            .{ .net = 1, .power = false, .domain = 0, .nominal = 1800.0 },
            .{ .net = 2, .power = true, .domain = 1, .nominal = 3300.0 },
        },
        .domains = &.{ .{ .name = "a", .mv = 1800.0 }, .{ .name = "b", .mv = 3300.0 } },
        .with_intent = with_intent,
    };
}

/// Nets 0-3 as VDD (1.8 V, domain a), VSS (ground, a) and two unlabelled
/// signals.
fn twoRails() Board {
    var b = threeRails(true);
    b.labels = .{ "VDD", "VSS", null, null };
    b.supplies = b.supplies[0..2];
    b.domains = b.domains[0..1];
    return b;
}

/// Every assignment of `terminals` terminals to at most `nets` nets up to
/// renaming: restricted growth strings.
fn canonicalAssignments(arena: Allocator, terminals: usize) ![]Assignment {
    var out: std.ArrayList(Assignment) = .empty;
    var current: std.ArrayList(usize) = .empty;
    try grow(arena, terminals, &current, &out);
    return out.items;
}

fn grow(arena: Allocator, terminals: usize, current: *std.ArrayList(usize), out: *std.ArrayList(Assignment)) !void {
    if (current.items.len == terminals) {
        try out.append(arena, try arena.dupe(usize, current.items));
        return;
    }
    var next: usize = 0;
    for (current.items) |m| next = @max(next, m + 1);
    next = @min(next, nets - 1);
    for (0..next + 1) |net| {
        try current.append(arena, net);
        try grow(arena, terminals, current, out);
        _ = current.pop();
    }
}

/// Every assignment of `terminals` terminals to the `nets` nets, as base-4
/// digits.
fn allAssignments(arena: Allocator, terminals: u32) ![]Assignment {
    const total = std.math.pow(usize, nets, terminals);
    const out = try arena.alloc(Assignment, total);
    for (out, 0..) |*a, code0| {
        var code = code0;
        const nets_of = try arena.alloc(usize, terminals);
        for (nets_of) |*n| {
            n.* = code % nets;
            code /= nets;
        }
        a.* = nets_of;
    }
    return out;
}

/// A seeded sample of `merge` items (all of them when that many or fewer).
fn sample(arena: Allocator, comptime T: type, items: []const T, merge: usize, seed: u64) ![]const T {
    if (items.len <= merge) return items;
    var rng = Rng.init(seed);
    const index = try arena.alloc(usize, items.len);
    for (index, 0..) |*x, i| x.* = i;
    for (0..merge) |i| {
        const j = i + @as(usize, @intCast(rng.below(index.len - i)));
        std.mem.swap(usize, &index[i], &index[j]);
    }
    const out = try arena.alloc(T, merge);
    for (out, index[0..merge]) |*o, i| o.* = items[i];
    return out;
}

fn name(arena: Allocator, prefix: []const u8, a: Assignment) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, prefix);
    for (a) |n| try out.append(arena, '0' + @as(u8, @intCast(n)));
    return out.items;
}

/// Thirty distinct random 9-terminal assignments from `seed`.
fn drawn(arena: Allocator, seed: u64) ![]Assignment {
    var rng = Rng.init(seed);
    var out: std.ArrayList(Assignment) = .empty;
    while (out.items.len < 30) {
        const a = try arena.alloc(usize, 9);
        for (a) |*n| n.* = @intCast(rng.below(nets));
        const fresh = for (out.items) |o| {
            if (std.mem.eql(usize, o, a)) break false;
        } else true;
        if (fresh) try out.append(arena, a);
    }
    return out.items;
}

fn three(arena: Allocator, models: [3]board.Model, a: Assignment) ![]const Dev {
    return arena.dupe(Dev, &.{ dev(models[0], a[0], a[1], a[2]), dev(models[1], a[3], a[4], a[5]), dev(models[2], a[6], a[7], a[8]) });
}

/// The enumerations over small circuits, each checked by the board oracle.
fn topologyEnumerations(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // Three nfets on four nets, up to renaming, without intent.
    for (try sample(arena, Assignment, try canonicalAssignments(arena, 9), 60, 0x7_0001)) |a| {
        var b = threeRails(false);
        b.devs = try three(arena, .{ .nfet, .nfet, .nfet }, a);
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/no_intent/", a)));
    }
    // An nfet and a pfet, every 4^6 assignment, against three rails.
    for (try sample(arena, Assignment, try allAssignments(arena, 6), 60, 0x7_0002)) |a| {
        var b = threeRails(true);
        b.devs = try arena.dupe(Dev, &.{ dev(.nfet, a[0], a[1], a[2]), dev(.pfet, a[3], a[4], a[5]) });
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/intent2/", a)));
    }
    for (try drawn(arena, 0x7_0003)) |a| {
        var b = threeRails(true);
        b.devs = try three(arena, .{ .nfet, .pfet, .nfet }, a);
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/intent3/", a)));
    }
    for (try drawn(arena, 0x7_0005)) |a| {
        var b = twoRails();
        b.devs = try three(arena, .{ .nfet, .pfet, .nfet }, a);
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/rails2/", a)));
    }
    // Net 2 labelled: a top-cell port under `labels_are_ports`.
    for (try drawn(arena, 0x7_000a)) |a| {
        var b = twoRails();
        b.labels[2] = "P";
        b.devs = try three(arena, .{ .nfet, .pfet, .nfet }, a);
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/port/", a)));
    }
    // Gate-conditioned switches (ERC-F1).
    for (try sample(arena, Assignment, try allAssignments(arena, 6), 60, 0x7_0006)) |a| {
        var b = threeRails(true);
        b.devs = try arena.dupe(Dev, &.{ dev(.nfet_c, a[0], a[1], a[2]), dev(.pfet_c, a[3], a[4], a[5]) });
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/conditional2/", a)));
    }
    for ([_]struct { u64, u32 }{ .{ 0x7_0007, 3 }, .{ 0x7_0008, 2 } }) |case| {
        for (try drawn(arena, case[0])) |a| {
            var b = if (case[1] == 3) threeRails(true) else twoRails();
            b.devs = try three(arena, .{ .nfet_c, .pfet_c, .nfet }, a);
            const prefix = try std.fmt.allocPrint(arena, "erc/topology/conditional3/rails{d}/", .{case[1]});
            try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, prefix, a)));
        }
    }
    // Power states: net 3 is the labelled input IN; VDDH off, IN at 0 V,
    // IN at 1.8 V.
    for (try drawn(arena, 0x7_0009)) |a| {
        var b = threeRails(true);
        b.labels[3] = "IN";
        b.states = &.{
            .{ .name = "sleep", .off = &.{2} },
            .{ .name = "in_low", .inputs = &.{.{ .net = 3, .mv = 0.0 }} },
            .{ .name = "in_high", .inputs = &.{.{ .net = 3, .mv = 1800.0 }} },
        };
        b.devs = try three(arena, .{ .nfet_c, .pfet_c, .nfet }, a);
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/topology/states/", a)));
    }
    // One four-terminal transistor of each polarity, every 4^4 assignment.
    const Bulk = struct { model: board.Model, a: Assignment };
    var bulk: std.ArrayList(Bulk) = .empty;
    for ([_]board.Model{ .nfet_b, .pfet_b }) |m| for (try allAssignments(arena, 4)) |a| try bulk.append(arena, .{ .model = m, .a = a });
    for (try sample(arena, Bulk, bulk.items, 32, 0x7_0004)) |x| {
        var b = threeRails(true);
        b.devs = try arena.dupe(Dev, &.{.{ .model = x.model, .g = x.a[0], .s = x.a[1], .d = x.a[2], .b = x.a[3] }});
        const prefix = try std.fmt.allocPrint(arena, "erc/topology/bulk/{t}/", .{x.model});
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, prefix, x.a)));
    }
}

/// Replaces rule `id`'s claim in `f` with `claim`.
fn reclaim(arena: Allocator, f: *Fixture, claim: Expect) !void {
    var kept: std.ArrayList(Expect) = .empty;
    for (f.expect) |e| if (!std.mem.eql(u8, e.id, claim.id)) try kept.append(arena, e);
    try kept.append(arena, claim);
    f.expect = kept.items;
}

fn side(limit: f64, value: f64) []const u8 {
    return if (limit < value) "below" else if (limit == value) "at" else "above";
}

/// Named circuits: hv isolation and the limit sweeps, the well-bias cases,
/// an inverter pair, a NAND2 (F28), drawing order (F28), power states, and
/// a layer listed twice.
fn topologyCases(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vdd = 0;
    const vss = 1;
    const vddh = 2;
    const sig = 3;
    // An nfet straddling both domains.
    var b = threeRails(true);
    b.devs = &.{dev(.nfet, vddh, vss, vdd)};
    try out.append(arena, try expect.fixtureOf(&b, arena, "erc/topology/hv/bare"));
    // Its gate oxide sees 3.3 V, its channel 1.8 V, its domains a 1.5 V
    // span: each limit swept a microvolt either side.
    for ([_]struct { []const u8, f64 }{ .{ "gox", 3300.0 }, .{ "vds", 1800.0 }, .{ "hv", 1500.0 } }) |case| {
        for ([_]f64{ case[1] - 0.001, case[1], case[1] + 0.001 }) |limit| {
            var swept = b;
            if (std.mem.eql(u8, case[0], "gox")) swept.limits.gox = limit else if (std.mem.eql(u8, case[0], "vds")) swept.limits.vds = limit else swept.limits.hv = limit;
            const n = try std.fmt.allocPrint(arena, "erc/topology/limit/{s}/{s}", .{ case[0], side(limit, case[1]) });
            try out.append(arena, try expect.fixtureOf(&swept, arena, n));
        }
    }
    // Isolation covering half the marker exempts nothing; one drawn exactly
    // on the marker covers all of it and exempts the device (F62).
    for ([_]struct { []const u8, board.Rect, bool }{ .{ "half_isolated", .{ 1100, -100, 1300, 1100 }, false }, .{ "isolation_on_marker", .{ 1000, 0, 1200, 1000 }, true } }) |case| {
        var f = try expect.fixtureOf(&b, arena, try std.fmt.allocPrint(arena, "erc/topology/hv/{s}", .{case[0]}));
        try board.rect(&f.layout, arena, "iso", case[1]);
        if (case[2]) try reclaim(arena, &f, .{ .id = "hv" });
        try out.append(arena, f);
    }
    b.iso = &.{0};
    try out.append(arena, try expect.fixtureOf(&b, arena, "erc/topology/hv/isolated"));
    // Well bias, one case at a time.
    const wells = [_]struct { []const u8, Dev }{
        .{ "pmos_ok", .{ .model = .pfet_b, .g = sig, .s = vdd, .d = sig, .b = vdd } },
        .{ "pmos_source_high", .{ .model = .pfet_b, .g = sig, .s = vddh, .d = sig, .b = vdd } },
        .{ "pmos_well_low", .{ .model = .pfet_b, .g = sig, .s = vdd, .d = sig, .b = vss } },
        .{ "nmos_ok", .{ .model = .nfet_b, .g = sig, .s = vss, .d = sig, .b = vss } },
        .{ "nmos_substrate_high", .{ .model = .nfet_b, .g = sig, .s = vss, .d = sig, .b = vdd } },
    };
    for (wells) |case| {
        var w = threeRails(true);
        w.devs = try arena.dupe(Dev, &.{case[1]});
        try out.append(arena, try expect.fixtureOf(&w, arena, try std.fmt.allocPrint(arena, "erc/topology/well_bias/{s}", .{case[0]})));
    }
    // Two inverters with their own inputs.
    var inv = threeRails(true);
    inv.labels = .{ "VDD", "VSS", "A", null };
    inv.supplies = inv.supplies[0..2];
    inv.domains = inv.domains[0..1];
    inv.devs = &.{ dev(.pfet, 2, vdd, 3), dev(.nfet, 2, vss, 3) };
    try out.append(arena, try expect.fixtureOf(&inv, arena, "erc/topology/inverter"));
    try out.append(arena, try nand2(arena, false));
    try out.append(arena, try nand2(arena, true));
    // F28: a pmos drawn output-first is extracted source on OUT, drain on
    // VDD; VDD is a rail and each output has one driver.
    var swapped = twoRails();
    swapped.devs = &.{ dev(.pfet, 2, 3, vdd), dev(.pfet, 3, 2, vdd) };
    try out.append(arena, try expect.fixtureOf(&swapped, arena, "erc/topology/f28/drawing_order"));
    // F28 on tie_high_low: an inverter loop drawn output-first.
    var ring = twoRails();
    ring.devs = &.{ dev(.pfet, 3, 2, vdd), dev(.nfet, 3, 2, vss), dev(.pfet, 2, vdd, 3), dev(.nfet, 2, vss, 3) };
    try out.append(arena, try expect.fixtureOf(&ring, arena, "erc/topology/f28/tie_drawing_order"));
    // Power states, hand-derived: the white paper's tristate (Siemens
    // 81822, figure 3) and VDDH switched off under a signal it drives.
    var tristate = twoRails();
    tristate.labels = .{ "VDD", "VSS", "EN", "Y" };
    tristate.devs = &.{ dev(.nfet_c, 2, vdd, 3), dev(.nfet, 3, vss, vdd) };
    tristate.states = &.{ .{ .name = "en_low", .inputs = &.{.{ .net = 2, .mv = 0.0 }} }, .{ .name = "en_high", .inputs = &.{.{ .net = 2, .mv = 1800.0 }} } };
    var sleep = threeRails(true);
    sleep.devs = &.{ dev(.nfet, vss, vddh, sig), dev(.pfet, sig, vdd, vss), dev(.nfet, sig, vss, vdd) };
    sleep.states = &.{.{ .name = "sleep", .off = &.{vddh} }};
    for ([_]struct { []const u8, Board }{ .{ "tristate", tristate }, .{ "sleep", sleep } }) |case| {
        var f = try expect.fixtureOf(&case[1], arena, try std.fmt.allocPrint(arena, "erc/topology/states/{s}", .{case[0]}));
        try reclaim(arena, &f, .{ .id = "ug", .findings = try arena.dupe(Finding, &.{count(1)}) });
        try reclaim(arena, &f, .{ .id = "iso", .findings = try arena.dupe(Finding, &.{count(1)}) });
        try out.append(arena, f);
    }
    // A layer listed twice is checked, and reported, twice.
    var twice: Fixture = .{
        .name = "erc/topology/unconnected_listed_twice",
        .deck = "grid 1nm\nlayer met1 = gds(1, 0)\nconnect conductors [met1]\nrule up unconnected_pin(met1, met1)\n",
        .expect = try arena.dupe(Expect, &.{.{ .id = "up", .findings = try arena.dupe(Finding, &.{ count(0), count(0) }) }}),
    };
    try twice.layout.rect(arena, "met1", 0, 0, 1000, 1000);
    try out.append(arena, twice);
}

/// F28: a NAND2 on six tracks (VDD, VSS, OUT, A, B, X), OUT driven once;
/// with `output_first` every transistor is drawn output side first.
fn nand2(arena: Allocator, output_first: bool) !Fixture {
    const six = 6;
    const ty = board.trackY;
    const vdd = 0;
    const vss = 1;
    const out_ = 2;
    const a = 3;
    const b_ = 4;
    const x = 5;
    const devs = [_]Dev{ dev(.pfet, a, vdd, out_), dev(.pfet, b_, vdd, out_), dev(.nfet, a, x, out_), dev(.nfet, b_, vss, x) };
    var l: fixture.Layout = .{};
    for (devs, 0..) |d0, i| {
        const d = if (output_first) dev(d0.model, d0.g, d0.d, d0.s) else d0;
        const x0 = @as(i64, @intCast(i)) * board.pitch;
        try board.rect(&l, arena, "diff", .{ x0, 0, x0 + 1000, 1000 });
        try board.rect(&l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, 1000 });
        try board.rect(&l, arena, "poly", .{ x0 + 1000, 0, x0 + 1200, 1600 });
        try board.rect(&l, arena, d.model.marker(), .{ x0 + 1000, 0, x0 + 1200, 1000 });
        for ([_]struct { i64, i64, usize }{ .{ x0 + 400, 400, d.s }, .{ x0 + 1600, 400, d.d }, .{ x0 + 1000, 1400, d.g } }) |r| {
            try board.rect(&l, arena, "cont", .{ r[0] + 50, r[1] + 50, r[0] + 150, r[1] + 150 });
            try board.rect(&l, arena, "met1", .{ r[0], r[1], r[0] + 200, ty(r[2]) + board.track_h });
            try board.rect(&l, arena, "via1", .{ r[0] + 50, ty(r[2]) + 150, r[0] + 150, ty(r[2]) + 250 });
        }
    }
    for (0..six) |net| try board.rect(&l, arena, "met2", .{ -1000, ty(net), 4 * board.pitch + 1000, ty(net) + board.track_h });
    try l.label(arena, "m2txt", -900, ty(vdd) + 200, "VDD");
    try l.label(arena, "m2txt", -900, ty(vss) + 200, "VSS");
    return .{
        .name = if (output_first) "erc/topology/f28/nand2_output_first" else "erc/topology/f28/nand2",
        .deck = try board.topoDeck(arena, .{}),
        .layout = l,
        .intent = try board.intentText(arena, &.{.{ .name = "a", .mv = 1800.0 }}, &.{ .{ "VDD", "a", "power" }, .{ "VSS", "a", "ground" } }, &.{}),
        .expect = try arena.dupe(Expect, &.{.{ .id = "md1" }}),
    };
}

/// A pad on net 0, VDD and VSS supplies, a labelled signal; a guard ring
/// 1 µm square, 1 µm left of the VDD track.
fn esdBase(with_intent: bool) Board {
    return .{
        .labels = .{ "PAD", "VDD", "VSS", "SIG" },
        .supplies = &.{ .{ .net = 1, .power = true, .domain = 0, .nominal = 1800.0 }, .{ .net = 2, .power = false, .domain = 0, .nominal = 1800.0 } },
        .domains = &.{.{ .name = "a", .mv = 1800.0 }},
        .pad = 0,
        .ring = .{ -3000, board.trackY(1), -2000, board.trackY(1) + 1000 },
        .with_intent = with_intent,
    };
}

/// ESD clamp paths (ERC-C1) and the guard ring (ERC-D2).
fn esdBoards(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const pad = 0;
    const vdd = 1;
    const vss = 2;
    const sig = 3;
    for (try sample(arena, Assignment, try allAssignments(arena, 6), 50, 0xe5d_0001)) |a| {
        var b = esdBase(true);
        b.devs = try arena.dupe(Dev, &.{ dev(.clamp, a[0], a[1], a[2]), dev(.clamp, a[3], a[4], a[5]) });
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/esd/two_clamps/", a)));
    }
    for (try sample(arena, Assignment, try allAssignments(arena, 6), 25, 0xe5d_0002)) |a| {
        var b = esdBase(true);
        b.devs = try arena.dupe(Dev, &.{ dev(.clamp, a[0], a[1], a[2]), dev(.nfet, a[3], a[4], a[5]) });
        try out.append(arena, try expect.fixtureOf(&b, arena, try name(arena, "erc/esd/clamp_and_nfet/", a)));
    }
    const named = [_]struct { []const u8, []const Dev }{
        .{ "diode_pair", &.{ dev(.clamp, vdd, pad, vdd), dev(.clamp, vss, vss, pad) } },
        .{ "rail_clamp", &.{ dev(.clamp, vdd, pad, vdd), dev(.clamp, vss, vdd, vss) } },
        .{ "through_signal", &.{ dev(.clamp, sig, pad, sig), dev(.clamp, vss, sig, vss), dev(.clamp, vdd, pad, vdd) } },
        .{ "none", &.{dev(.nfet, vdd, pad, vss)} },
    };
    for (named) |case| {
        var b = esdBase(true);
        b.devs = case[1];
        try out.append(arena, try expect.fixtureOf(&b, arena, try std.fmt.allocPrint(arena, "erc/esd/{s}", .{case[0]})));
    }
    const pair: []const Dev = &.{ dev(.clamp, vdd, pad, vdd), dev(.clamp, vss, vss, pad) };
    // The guard ring's two limits, each swept by a nanometre.
    for ([_]i64{ 499, 500, 501 }) |width| {
        var b = esdBase(true);
        b.devs = pair;
        b.ring = .{ -2000 - width, board.trackY(vdd), -2000, board.trackY(vdd) + 1000 };
        try out.append(arena, try expect.fixtureOf(&b, arena, try std.fmt.allocPrint(arena, "erc/esd/ring_width/{d}", .{width})));
    }
    for ([_]i64{ 1999, 2000, 2001 }) |gap| {
        var b = esdBase(true);
        b.devs = pair;
        b.ring = .{ -1000 - gap - 1000, board.trackY(vdd), -1000 - gap, board.trackY(vdd) + 1000 };
        try out.append(arena, try expect.fixtureOf(&b, arena, try std.fmt.allocPrint(arena, "erc/esd/ring_gap/{d}", .{gap})));
    }
    // F26: a C-shaped guard ring 3 µm across with a 100 nm band: its width
    // is the band, not its box.
    var b = esdBase(true);
    b.devs = pair;
    b.ring = null;
    const x = -5000;
    const y = board.trackY(vdd);
    var c_ring = try b.layout(arena);
    try c_ring.polygon(arena, "ring", &.{ .{ x, y }, .{ x + 3000, y }, .{ x + 3000, y + 100 }, .{ x + 100, y + 100 }, .{ x + 100, y + 2900 }, .{ x + 3000, y + 2900 }, .{ x + 3000, y + 3000 }, .{ x, y + 3000 } });
    try out.append(arena, .{ .name = "erc/esd/f26/c_shaped_ring", .deck = try board.topoDeck(arena, .{}), .layout = c_ring, .intent = try b.intentJson(arena), .expect = try arena.dupe(Expect, &.{.{ .id = "esdl", .findings = try arena.dupe(Finding, &.{length(100)}) }}) });
    // The band is the material: two abutting 250 nm bars are 500 nm wide.
    var bars = try b.layout(arena);
    try bars.rect(arena, "ring", -2500, y, -2250, y + 1000);
    try bars.rect(arena, "ring", -2250, y, -2000, y + 1000);
    try out.append(arena, .{ .name = "erc/esd/f26/abutting_bars", .deck = try board.topoDeck(arena, .{}), .layout = bars, .intent = try b.intentJson(arena), .expect = try arena.dupe(Expect, &.{.{ .id = "esdl" }}) });
    // No supply declared (only a limit on the signal).
    var none = esdBase(true);
    none.devs = &.{dev(.clamp, sig, pad, sig)};
    none.supplies = &.{};
    try out.append(arena, .{
        .name = "erc/esd/no_supply",
        .deck = try board.topoDeck(arena, .{}),
        .layout = try none.layout(arena),
        .intent = try board.intentText(arena, &.{}, &.{}, &.{"{\"net\":\"SIG\",\"max_drop_mv\":1}"}),
        .expect = try arena.dupe(Expect, &.{ .{ .id = "esd", .findings = try arena.dupe(Finding, &.{count(0)}) }, .{ .id = "esdl", .findings = try arena.dupe(Finding, &.{ count(0), count(0) }) } }),
    });
}

test "topology boards match a naive judge of the planted circuit" {
    // Oracle: the board's naive judge of every topology rule on a small
    // circuit as planted (a graph search over the nets it wired), on every
    // sampled assignment of devices to nets.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var all: std.ArrayList(Fixture) = .empty;
    try topologyEnumerations(arena.allocator(), &all);
    try fixture.checkAll(all.items);
}

test "named topology circuits report their derived findings" {
    // Oracle: the named circuits' hand-derived findings (each case's
    // comment derives them), and the board's judge for the rest.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var all: std.ArrayList(Fixture) = .empty;
    try topologyCases(arena.allocator(), &all);
    try fixture.checkAll(all.items);
}

test "esd boards match their clamp-path and ring judge" {
    // Oracle: the board's naive judge for esd_topological and esd_latchup
    // (a clamp walk from the pad; the ring's narrow side and its gap to the
    // nearest supply track), each ring limit swept a nanometre either side.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var all: std.ArrayList(Fixture) = .empty;
    try esdBoards(arena.allocator(), &all);
    try fixture.checkAll(all.items);
}
