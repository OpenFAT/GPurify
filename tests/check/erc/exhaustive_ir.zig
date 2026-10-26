//! Static and dynamic IR drop, floating supply pieces and point-to-point
//! resistance on met1 rails: drawn rails and an intent in, each rule's
//! findings against Ohm's law on the series ladder, a current divider, the
//! RC recurrence and the resistance between attach points out. Ported from
//! tests/exhaustive/erc.rs (`ir_drop`, `dynamic_ir_drop`, `dynamic_intent`,
//! `switching_peak`, `rc_recurrence_peak`, `floating_supply`, `p2p`), at
//! merge depth.

const std = @import("std");
const Allocator = std.mem.Allocator;
const check = @import("check");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const pc = @import("ported_circuit.zig");
const millivolts = pc.millivolts;
const side = pc.side;
const cf = @import("closed_form.zig");
const rails = @import("exhaustive_rails.zig");
const at = rails.at;
const ohms = rails.ohms;
const claim = rails.claim;
const steps_per_rise = check.erc.power_transient.steps_per_rise;

const Role = struct { net: []const u8, role: []const u8 };

const roles = [_]Role{ .{ .net = "VDD", .role = "power" }, .{ .net = "VSS", .role = "ground" } };

// ---- private ----

/// `ir_drop` (ERC-E8): the closed-form ladder of `tests/erc_closed_form.rs`
/// (20 µm × 1 µm, pad at 10 µm, loads at 12, 14 and 18 µm sharing 3 mA:
/// drops 0.75, 1.25 and 1.75 mV) swept across every node by `max_drop_mv`,
/// by `max_drop_fraction` of the 1.8 V domain, by both at once (a node breaks
/// both), on a ground rail (bounce, the rise above 0 V), and against
/// `max_overvoltage_mv`, which a resistive grid with only sinks can never
/// break (no node rises above its pad). A current divider through two vias.
/// Random ladders swept between every pair of adjacent node drops.
fn irDrop(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try rails.railDeck(arena, "rule ir ir_drop()");
    const loads = [_]i64{ 12_000, 14_000, 18_000 };
    const lad = try rails.ladder(arena, 20_000, 1000, &loads, 3000.0);
    var placed: std.ArrayList(Fixture) = .empty;
    for ([_]f64{ 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 1.8 }, 0..) |limit, k| {
        for (roles) |r| {
            // The worst node is exactly 1.75 mV, legal at a 1.75 mV limit, on
            // either rail (F61: the ground rail's solve once read it one ulp
            // high).
            const f: Fixture = .{
                .name = try std.fmt.allocPrint(arena, "erc/ir_drop/ladder/{s}/max_drop/{d}", .{ r.role, limit }),
                .deck = deck,
                .layout = try railLayout(arena, r.net, 20_000, 1000, &loads),
                .intent = try rails.intent(arena, &.{.{ r.net, r.role }}, try std.fmt.allocPrint(arena, "{{\"net\":\"{s}\",\"max_drop_mv\":{d},\"budget_current_ua\":3000}}", .{ r.net, limit })),
                .expect = try claim(arena, "ir", try flagged(arena, lad.nodes, 1.0, limit, 500)),
            };
            if (k == 2 and std.mem.eql(u8, r.role, "power")) try placed.append(arena, f);
            try out.append(arena, f);
        }
    }
    // A fraction of the domain: 1/1800 of 1.8 V is 1 mV, between the 0.75
    // and 1.25 mV nodes; with both limits stated those nodes break both.
    const once = try flagged(arena, lad.nodes, 1.0, 1.0, 500);
    const Case = struct { []const u8, []const u8, []const Finding };
    for ([_]Case{
        .{ "fraction", "\"max_drop_fraction\":0.000555555555555556", once },
        .{ "drop_and_fraction", "\"max_drop_mv\":1.0,\"max_drop_fraction\":0.000555555555555556", try std.mem.concat(arena, Finding, &.{ once, once }) },
        .{ "overvoltage", "\"max_overvoltage_mv\":0.001", &.{} },
    }) |case| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/ir_drop/ladder/power/{s}", .{case[0]}),
        .deck = deck,
        .layout = try railLayout(arena, "VDD", 20_000, 1000, &loads),
        .intent = try rails.intent(arena, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",{s},\"budget_current_ua\":3000}}", .{case[1]})),
        .expect = try claim(arena, "ir", case[2]),
    });
    for (placed.items) |f| {
        var g = f;
        g.name = try std.fmt.allocPrint(arena, "{s}/placed", .{f.name});
        try pc.everyPlacement(arena, out, g);
    }

    // The divider: met2 (pad, centre 6 µm) over met1, vias at 5 and 11 µm,
    // one load on met1 at 6 µm drawing 5 mA. Branch A is 1 square of met2, a
    // cut and 1 square of met1, 0.25 Ω; branch B 5 + 1 cut + 5 squares, 1 Ω.
    // A carries 4 mA, B 1 mA. Node drops: met2 at 5 µm 4 mA × 0.0625 Ω =
    // 0.25 mV, met2 at 11 µm 1 mA × 0.3125 Ω = 0.3125 mV, met1 at 5 µm 0.25 +
    // 4 × 0.0625 = 0.5 mV, met1 at 11 µm 0.3125 + 0.0625 = 0.375 mV, the load
    // node 1.0 mV.
    var divider: Layout = .{};
    try divider.rect(arena, "met1", 0, 0, 12_000, 1000);
    try divider.rect(arena, "met2", 0, 500, 12_000, 1500);
    try divider.rect(arena, "via1", 4900, 650, 5100, 850);
    try divider.rect(arena, "via1", 10_900, 650, 11_100, 850);
    try divider.label(arena, "met1_text", 2000, 200, "VDD");
    try divider.label(arena, "met2_text", 2000, 1200, "VDD");
    try cf.loadAt(arena, &divider, 6000, 0);
    const nodes = [_]Finding{
        at(millivolts(0.25), 5000, 1000),
        at(millivolts(0.3125), 11_000, 1000),
        at(millivolts(0.5), 5000, 500),
        at(millivolts(0.375), 11_000, 500),
        at(millivolts(1.0), 6000, 500),
    };
    for ([_]f64{ 0.2, 0.3, 0.4, 0.99, 1.01 }) |limit| {
        var findings: std.ArrayList(Finding) = .empty;
        for (nodes) |n| if (n.measured.?.float() > limit) try findings.append(arena, n);
        try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/ir_drop/divider/{d}", .{limit}),
            .deck = deck,
            .layout = divider,
            .intent = try rails.intent(arena, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"max_drop_mv\":{d},\"budget_current_ua\":5000}}", .{limit})),
            .expect = try claim(arena, "ir", findings.items),
        });
    }

    // Random ladders on a 16 µm rail.
    var rng = Rng.init(0x1d_0001);
    for (0..30) |case| {
        const random = try randomLoads(arena, &rng, 1 + rng.below(4), true);
        const budget: f64 = @floatFromInt(100 + rng.below(4900));
        const r = roles[@intFromBool(rng.below(2) == 1)];
        const drops = (try rails.ladder(arena, 16_000, 1000, random, budget)).nodes;
        var values: std.ArrayList(f64) = .empty;
        for (drops) |d| if (d.drop > 0.0) try values.append(arena, d.drop);
        const layout = try railLayout(arena, r.net, 16_000, 1000, random);
        for (try rails.between(arena, values.items)) |limit| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/ir_drop/random/{d}/{d}", .{ case, limit }),
            .deck = deck,
            .layout = layout,
            .intent = try rails.intent(arena, &.{.{ r.net, r.role }}, try std.fmt.allocPrint(arena, "{{\"net\":\"{s}\",\"max_drop_mv\":{d},\"budget_current_ua\":{d}}}", .{ r.net, limit, budget })),
            .expect = try claim(arena, "ir", try flagged(arena, drops, 1.0, limit, 500)),
        });
    }
}

/// One met1 rail from 0 to `len`, `width` wide, named `net`, loaded at `loads`.
fn railLayout(arena: Allocator, net: []const u8, len: i64, width: i64, loads: []const i64) !Layout {
    var l: Layout = .{};
    try rails.rail(&l, arena, net, len, 0, width, loads);
    return l;
}

/// Every node whose drop times `scale` is over `limit`, measured at it.
fn flagged(arena: Allocator, nodes: []const rails.Node, scale: f64, limit: f64, y: i64) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (nodes) |n| if (n.drop * scale > limit) try out.append(arena, at(millivolts(n.drop * scale), n.x, y));
    return out.items;
}

/// `n` distinct load positions on the 500 nm pitch up to 15.5 µm, skipping
/// the 8 µm feed point when `skip_pad`.
fn randomLoads(arena: Allocator, rng: *Rng, n: u64, skip_pad: bool) ![]const i64 {
    var loads: std.ArrayList(i64) = .empty;
    while (loads.items.len < n) {
        const x: i64 = @intCast(500 * (1 + rng.below(31)));
        if ((!skip_pad or x != 8000) and std.mem.indexOfScalar(i64, loads.items, x) == null) try loads.append(arena, x);
    }
    return loads.items;
}

/// One rail's `dynamic` intent: `budget` µA switching a quarter of 1000 ps
/// cycles as 100 ps pulses, `decap` pF, limited to `limit` mV.
fn dynamicIntent(arena: Allocator, r: Role, budget: f64, decap: f64, limit: f64) ![]const u8 {
    return rails.intent(arena, &.{.{ r.net, r.role }}, try std.fmt.allocPrint(arena, "{{\"net\":\"{s}\",\"budget_current_ua\":{d},\"dynamic\":{{\"max_drop_mv\":{d},\"toggle_rate\":0.25,\"clock_period_ps\":1000,\"rise_time_ps\":100,\"decap_pf\":{d}}}}}", .{ r.net, budget, limit, decap }));
}

/// One switching event's charge as a peak: `2 (I T / α) / t_r` for this
/// file's 1000 ps period, toggle rate 0.25 and 100 ps rise.
fn switchingPeak(share: f64) f64 {
    return 2.0 * share * 1000.0 / 0.25 / 100.0;
}

/// The peak of one RC node's backward-Euler recurrence at the engine's
/// documented `steps_per_rise`, mV: `r[k+1] = (c r[k] + i[k+1]) / (c + g)`,
/// `c = 1000 C / h` and `g = 1000 / R` in µA per mV.
// ponytail: copy of dynamic_and_thermal.zig's private `recurrencePeak`.
fn rcRecurrencePeak(ohm: f64, cap_pf: f64, peak_ua: f64, rise_ps: f64) f64 {
    const steps: f64 = @floatFromInt(steps_per_rise);
    const h = rise_ps / steps;
    const c = 1000.0 * cap_pf / h;
    const g = 1000.0 / ohm;
    var r: f64 = 0.0;
    var best: f64 = 0.0;
    for (1..10 * steps_per_rise + 1) |k| {
        const fraction = @as(f64, @floatFromInt(k)) / steps;
        const shape = if (fraction <= 1.0) 1.0 - @abs(2.0 * fraction - 1.0) else 0.0;
        r = (c * r + peak_ua * shape) / (c + g);
        best = @max(best, r);
    }
    return best;
}

/// `dynamic_ir_drop` (ERC-E11): the static drop plus the worst cycle's.
///
/// - One load 8 µm from the feed of a 1 µm met1 rail (1 Ω) drawing 1 mA: its
///   event is `1 mA × 1000 ps / 0.25` of charge over 100 ps, an 80 mA peak.
///   Without decap the cycle adds 80 mV (81 mV in all); with 10 pF it adds
///   the RC recurrence's peak. On a power and a ground rail, the limit a part
///   in a million either side, under every placement.
/// - The three-load ladder of `ir_drop` (3 mA): without decap each node's
///   response is the static drop of every load at its 80 mA peak, so its
///   drop is 81 times the ladder's; swept between every pair of nodes.
fn dynamicIrDrop(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try rails.railDeck(arena, "rule dir dynamic_ir_drop()");
    var placed: std.ArrayList(Fixture) = .empty;
    for ([_][2]f64{ .{ 0.0, 80.0 }, .{ 10.0, rcRecurrencePeak(1.0, 10.0, switchingPeak(1000.0), 100.0) } }) |c| {
        const decap = c[0];
        const total = 1.0 + c[1];
        for (roles) |r| {
            const layout = try railLayout(arena, r.net, 20_000, 1000, &.{18_000});
            for ([_]f64{ 1.0 - 1e-6, 1.0 + 1e-6 }) |factor| {
                const limit = total * factor;
                const f: Fixture = .{
                    .name = try std.fmt.allocPrint(arena, "erc/dynamic_ir_drop/one_load/{s}/decap_{d}/{s}", .{ r.role, decap, side(limit, total) }),
                    .deck = deck,
                    .layout = layout,
                    .intent = try dynamicIntent(arena, r, 1000.0, decap, limit),
                    .expect = try claim(arena, "dir", if (limit < total) &.{at(millivolts(total), 18_000, 500)} else &.{}),
                };
                if (std.mem.eql(u8, r.role, "power") and limit < total) try placed.append(arena, f);
                try out.append(arena, f);
            }
        }
    }
    for (placed.items) |f| {
        var g = f;
        g.name = try std.fmt.allocPrint(arena, "{s}/placed", .{f.name});
        try pc.everyPlacement(arena, out, g);
    }

    const loads = [_]i64{ 12_000, 14_000, 18_000 };
    const drops = (try rails.ladder(arena, 20_000, 1000, &loads, 3000.0)).nodes;
    const scale = 1.0 + switchingPeak(1000.0) / 1000.0;
    var values: std.ArrayList(f64) = .empty;
    for (drops) |d| if (d.drop * scale > 0.0) try values.append(arena, d.drop * scale);
    const layout = try railLayout(arena, "VDD", 20_000, 1000, &loads);
    for (try rails.between(arena, values.items)) |limit| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/dynamic_ir_drop/ladder/{d}", .{limit}),
        .deck = deck,
        .layout = layout,
        .intent = try dynamicIntent(arena, roles[0], 3000.0, 0.0, limit),
        .expect = try claim(arena, "dir", try flagged(arena, drops, scale, limit, 500)),
    });
}

/// `floating_supply` (ERC-E9), hand-derived from OpenROAD
/// `check_power_grid`'s definition: the supply is fed at its highest, then
/// widest, shape, and every piece of it not joined to that one is floating.
/// VDD is a 2 µm met2 bar, strapped by a cut to a met1 rail below it in the
/// joined cases; pieces are met1 rails labelled VDD that nothing joins.
///
/// - one piece (the bar strapped to its rail): clean;
/// - the rail unstrapped: the rail, a lower layer, floats (1);
/// - two unstrapped rails: both float (2);
/// - a 0.5 µm met2 stub against a 20 µm met1 rail: the stub is higher, so
///   it is fed and the larger rail floats (1);
/// - without intent the row is skipped.
fn floatingSupply(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try rails.railDeck(arena, "rule fs floating_supply()");
    var unstrapped: Layout = .{};
    try unstrapped.rect(arena, "met2", 0, 3000, 20_000, 5000);
    try unstrapped.label(arena, "met2_text", 1000, 4000, "VDD");
    try rails.rail(&unstrapped, arena, "VDD", 20_000, 0, 1000, &.{18_000});
    var one = try unstrapped.transformed(arena, .identity, 0, 0);
    try one.rect(arena, "met1", 900, 0, 1100, 3500);
    try one.rect(arena, "via1", 950, 3100, 1050, 3200);
    var two = try unstrapped.transformed(arena, .identity, 0, 0);
    try rails.rail(&two, arena, "VDD", 20_000, -3000, 1000, &.{2000});
    var stub: Layout = .{};
    try stub.rect(arena, "met2", 0, 3000, 500, 3500);
    try stub.label(arena, "met2_text", 250, 3250, "VDD");
    try rails.rail(&stub, arena, "VDD", 20_000, 0, 1000, &.{18_000});
    const supplies = try rails.intent(arena, &.{.{ "VDD", "power" }}, "");
    const Case = struct { []const u8, Layout, usize };
    for ([_]Case{ .{ "one_piece", one, 0 }, .{ "unstrapped", unstrapped, 1 }, .{ "two_rails", two, 2 }, .{ "higher_stub", stub, 1 } }) |case| {
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/floating_supply/{s}", .{case[0]}),
            .deck = deck,
            .layout = case[1],
            .intent = supplies,
            .expect = try claim(arena, "fs", try pc.repeat(arena, pc.count(0), case[2])),
        });
    }
    try out.append(arena, .{
        .name = "erc/floating_supply/no_intent",
        .deck = deck,
        .layout = one,
        .expect = try arena.dupe(Expect, &.{.{ .id = "fs", .outcome = .skipped }}),
    });
}

/// `p2p_resistance` (ERC-C6, D4): the largest effective resistance between
/// two device attach points of one net. On a 1 µm met1 rail the extreme loads
/// are `0.125 Ω × Δx / 1 µm` apart (2.0 Ω for 2 and 18 µm, exact). A met2
/// strap through two cuts in parallel: 0.75 Ω of met1 against 0.375 Ω of
/// met2 plus two 0.0625 Ω cuts, 0.75 ‖ 0.5 = 0.3 Ω; without it 0.75 Ω. Two
/// nets each over the limit report once each. Random rails swept around
/// their extreme pair.
fn p2p(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const two = try railLayout(arena, "VDD", 20_000, 1000, &.{ 2000, 18_000 });
    for (pc.sweep(2.0)) |limit| {
        const f: Fixture = .{
            .name = try std.fmt.allocPrint(arena, "erc/p2p/rail/{s}", .{side(limit, 2.0)}),
            .deck = try p2pDeck(arena, limit),
            .layout = two,
            .expect = try claim(arena, "p2p", if (limit < 2.0) &.{at(ohms(2.0), 2000, 500)} else &.{}),
        };
        try out.append(arena, f);
        // The finding sits at the worst pair's first attach point in chain
        // order, which a mirror or half turn reverses: placed, only the value
        // is pinned.
        if (limit < 2.0) try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "{s}/placed", .{f.name}),
            .deck = f.deck,
            .layout = two,
            .expect = try claim(arena, "p2p", &.{ohms(2.0)}),
        });
    }
    for ([_]bool{ true, false }) |with| {
        const value: f64 = if (with) 0.3 else 0.75;
        var l: Layout = .{};
        try l.rect(arena, "met1", 0, 0, 8000, 1000);
        try l.label(arena, "met1_text", 3000, 200, "VDD");
        if (with) {
            try l.rect(arena, "met2", 0, 500, 8000, 1500);
            try l.rect(arena, "via1", 900, 650, 1100, 850);
            try l.rect(arena, "via1", 6900, 650, 7100, 850);
        }
        try cf.loadAt(arena, &l, 1000, 0);
        try cf.loadAt(arena, &l, 7000, 0);
        for ([_]f64{ value * 0.999, value * 1.001 }) |limit| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/p2p/strap_{}/{s}", .{ with, side(limit, value) }),
            .deck = try p2pDeck(arena, limit),
            .layout = l,
            .expect = try claim(arena, "p2p", if (limit < value) &.{at(ohms(value), 1000, 500)} else &.{}),
        });
    }
    var pair = try railLayout(arena, "VDD", 20_000, 1000, &.{ 2000, 18_000 });
    try rails.rail(&pair, arena, "VSS", 20_000, 3000, 1000, &.{ 6000, 10_000 });
    try out.append(arena, .{
        .name = "erc/p2p/two_nets",
        .deck = try p2pDeck(arena, 0.4),
        .layout = pair,
        .expect = try claim(arena, "p2p", &.{ at(ohms(2.0), 2000, 500), at(ohms(0.5), 6000, 3500) }),
    });
    var rng = Rng.init(0x22_0001);
    for (0..20) |case| {
        const loads = try randomLoads(arena, &rng, 2 + rng.below(3), false);
        const width: i64 = @intCast(500 * (1 + rng.below(4)));
        const lo = std.mem.min(i64, loads);
        const hi = std.mem.max(i64, loads);
        const value = rails.met1_sheet * @as(f64, @floatFromInt(hi - lo)) / @as(f64, @floatFromInt(width));
        const layout = try railLayout(arena, "VDD", 16_000, width, loads);
        for ([_]f64{ value * 0.999, value * 1.001 }) |limit| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/p2p/random/{d}/{s}", .{ case, side(limit, value) }),
            .deck = try p2pDeck(arena, limit),
            .layout = layout,
            .expect = try claim(arena, "p2p", if (limit < value) &.{at(ohms(value), lo, @divTrunc(width, 2))} else &.{}),
        });
    }
}

fn p2pDeck(arena: Allocator, max: f64) ![]const u8 {
    return rails.rules(arena, "rule p2p p2p_resistance(; max: {d}ohm)", .{max});
}

// Oracle: Ohm's law on the series ladder (20 µm × 1 µm, pad at 10 µm, loads
// at 12, 14 and 18 µm sharing 3 mA: drops 0.75, 1.25 and 1.75 mV) swept by
// `max_drop_mv`, `max_drop_fraction` (1/1800 of 1.8 V is 1 mV) and both, on
// power and ground rails; `max_overvoltage_mv` never broken by sinks; the
// two-via current divider's node drops 0.25, 0.3125, 0.5, 0.375 and 1.0 mV;
// random ladders swept between adjacent node drops.
test "ir drop sweeps ohms law on ladders and a divider" {
    try rails.checkGroup(irDrop);
}

// Oracle: the static drop plus one RC node's backward-Euler response to its
// switching pulse: one load's 80 mA peak adds 80 mV without decap (81 mV in
// all), the recurrence's peak with 10 pF; the three-load ladder's drops times
// 81 without decap, swept between every pair of nodes.
test "dynamic ir drop is the static drop plus the worst cycle" {
    try rails.checkGroup(dynamicIrDrop);
}

// Oracle: OpenROAD `check_power_grid`'s definition, hand-derived: the supply
// is fed at its highest, then widest, shape, and every piece not joined to it
// floats: one piece clean, an unstrapped rail 1, two rails 2, a higher stub
// fed so the larger rail floats 1; skipped without intent.
test "floating supply flags every piece the fed shape does not reach" {
    try rails.checkGroup(floatingSupply);
}

// Oracle: the effective resistance between the extreme attach points:
// `0.125 Ω × Δx / width` on a met1 rail (2.0 Ω for 2 and 18 µm), a met2 strap
// in parallel 0.75 ‖ 0.5 = 0.3 Ω (0.75 Ω without), two nets once each.
test "p2p resistance is the largest attach-point resistance of each net" {
    try rails.checkGroup(p2p);
}
