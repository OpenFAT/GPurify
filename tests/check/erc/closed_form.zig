//! `ir_drop`, `electromigration`, `reliability`, `p2p_resistance`, `em_rms`
//! and `em_peak` against numbers worked out by hand, through the engine's
//! own path (fixture.zig): deck text, drawn geometry, an intent file, then
//! `erc.check` at the 85 °C sign-off temperature (the intent's
//! `temperature_c`). Every layout is on a 1 nm grid; every resistance a power of two, so
//! the solve lands on exact binary values and a measurement can sit exactly
//! on its limit. Ported from crates/check/tests/erc/closed_form.rs (a
//! superset of the root tests/erc_closed_form.rs); its two tests on other
//! families' kinds are closed_form_others.zig.
//!
//! Contents:
//! - `pub const process`, `pub const Report = struct`, `run(r, rule) !Row`, `rows(r, rule) ![]const Found`
//! - `pub fn ercAt(arena, rules, intent, layout: Layout, signoff: bool) !Report`, `pub fn erc(arena, rules, intent, layout) !Report`
//! - `pub fn loadAt(arena, l: *Layout, x, y) !void`, `pub fn named(arena, l: *Layout, layer, xlo, ylo, xhi, yhi, net) !void`
//! - `pub fn intentOf(arena, domain_mv: f64, supplies: []const [2][]const u8, limits) ![]const u8`, `pub fn valueOf(m: ?Measurement, kind: Kind) !f64`

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const fixture = @import("fixture.zig");
const report = check.report;
const Measurement = report.Measurement;
const Outcome = report.Outcome;
const Layout = fixture.Layout;

/// met1 0.125 Ω/sq at 100 nm, via1 0.0625 Ω per cut, met2 0.0625 Ω/sq at
/// 300 nm. A `load` device is an `mk` marker over one rail shape and one
/// private poly stub. Text on `met1_text`/`met2_text` names the net under it.
pub const process =
    \\grid 1nm
    \\layer met1 = gds(1, 0)
    \\layer via1 = gds(2, 0)
    \\layer met2 = gds(3, 0)
    \\layer poly = gds(4, 0)
    \\layer mk   = gds(5, 0)
    \\layer met1_text = gds(11, 0)
    \\layer met2_text = gds(13, 0)
    \\connect conductors [met1, met2, poly]
    \\connect touch_within_layer
    \\connect via via1 [met1, met2]
    \\connect label met1_text names met1
    \\connect label met2_text names met2
    \\device resistor mk model "load" terminals [met1, poly]
    \\pex met1 thickness 100nm height 100nm sheet 0.125ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex via1 thickness 100nm height 200nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met2 thickness 100nm height 300nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex poly thickness 100nm height 50nm sheet 8ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\
;

/// What one ERC run reported.
pub const Report = struct {
    ran: fixture.Ran,
    arena: std.mem.Allocator,

    /// The run row of `rule`; fails unless exactly one.
    pub fn run(r: Report, rule: []const u8) !fixture.Row {
        var found: ?fixture.Row = null;
        for (r.ran.rows) |row| if (std.mem.eql(u8, row.id, rule)) {
            if (found != null) return error.TwoRunRows;
            found = row;
        };
        return found orelse error.NoRunRow;
    }

    /// The violations of `rule`, in report order.
    pub fn rows(r: Report, rule: []const u8) ![]const fixture.Found {
        var out: std.ArrayList(fixture.Found) = .empty;
        for (r.ran.findings) |f| if (std.mem.eql(u8, f.id, rule)) try out.append(r.arena, f);
        return out.items;
    }
};

/// Boltzmann's constant in eV/K (CODATA 2018).
const k_ev: f64 = 8.617_333_262e-5;

/// The sign-off temperature: 85 °C.
const t_signoff: f64 = 85.0 + 273.15;

/// Rated at 105 °C, operated at 85 °C, Ea 0.9 eV, n 2:
/// `exp(0.9 / (2 k) (1/358.15 - 1/378.15))`.
const derate_105c: f64 = 2.162_257_930_473_676;

/// Runs `process` plus `rules` over `layout` with `intent` (an object), at
/// 85 °C (the intent's `temperature_c`) or, `signoff` false, with no
/// sign-off temperature.
pub fn ercAt(arena: std.mem.Allocator, rules: []const u8, intent: []const u8, layout: Layout, signoff: bool) !Report {
    std.debug.assert(intent[0] == '{');
    const deck = try std.mem.concat(arena, u8, &.{ process, rules });
    const at = if (signoff) try std.mem.concat(arena, u8, &.{ "{\"temperature_c\":85,", intent[1..] }) else intent;
    const f: fixture.Fixture = .{ .name = "closed_form", .deck = deck, .layout = layout, .intent = at };
    return .{ .ran = try fixture.run(arena, &f), .arena = arena };
}

pub fn erc(arena: std.mem.Allocator, rules: []const u8, intent: []const u8, layout: Layout) !Report {
    return ercAt(arena, rules, intent, layout, true);
}

/// One `load` device whose marker is centred on `(x, y)`, the lower edge of
/// a rail bar: over the bar above and a private poly stub below.
pub fn loadAt(arena: std.mem.Allocator, l: *Layout, x: i64, y: i64) !void {
    try l.rect(arena, "mk", x - 100, y - 100, x + 100, y + 100);
    try l.rect(arena, "poly", x - 100, y - 400, x + 100, y - 50);
}

/// A rectangle on `layer` (met1 or met2) named `net` by a text inside it.
pub fn named(arena: std.mem.Allocator, l: *Layout, layer: []const u8, xlo: i64, ylo: i64, xhi: i64, yhi: i64, net: []const u8) !void {
    try l.rect(arena, layer, xlo, ylo, xhi, yhi);
    try l.label(arena, try std.mem.concat(arena, u8, &.{ layer, "_text" }), xlo + 100, ylo + 100, net);
}

/// An intent declaring `supplies` (net, role) in one domain at `domain_mv`,
/// `limits` the JSON inside the `limits` array.
pub fn intentOf(arena: std.mem.Allocator, domain_mv: f64, supplies: []const [2][]const u8, limits: []const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (supplies, 0..) |sp, i| {
        if (i > 0) try s.append(arena, ',');
        try s.print(arena, "{{\"net\":\"{s}\",\"domain\":\"core\",\"role\":\"{s}\"}}", .{ sp[0], sp[1] });
    }
    return std.fmt.allocPrint(arena, "{{\"domains\":{{\"core\":{{\"voltage_mv\":{d}}}}},\"supplies\":[{s}],\"limits\":[{s}]}}", .{ domain_mv, s.items, limits });
}

/// The value of `m`; fails unless it is of `kind`.
pub fn valueOf(m: ?Measurement, kind: report.Kind) !f64 {
    const v = m orelse return error.NoMeasurement;
    if (v.kind != kind) return error.WrongKind;
    return v.float();
}

// ---- private ----

fn close(got: f64, want: f64) !void {
    try testing.expect(@abs(got - want) <= 1e-9 * @max(@abs(want), 1.0));
}

/// A 20 µm × 1 µm met1 bar named `net`, pad at its centre x = 10000, loads
/// at x = 12000, 14000 and 18000.
fn ladderOn(arena: std.mem.Allocator, net: []const u8) !Layout {
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, 20_000, 1_000, net);
    for ([_]i64{ 12_000, 14_000, 18_000 }) |x| try loadAt(arena, &l, x, 0);
    return l;
}

/// One 20 µm × 1 µm met1 bar, pad at x = 10000, one load at x = 18000.
fn singleEdge(arena: std.mem.Allocator) !Layout {
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, 20_000, 1_000, "VDD");
    try loadAt(arena, &l, 18_000, 0);
    return l;
}

/// Two bars, met2 (pad) over met1, `length` long, joined by vias at each x
/// of `vias`; one load on met1 at `load`.
fn twoLevels(arena: std.mem.Allocator, length: i64, vias: []const i64, load: i64) !Layout {
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, length, 1_000, "VDD");
    try named(arena, &l, "met2", 0, 500, length, 1_500, "VDD");
    for (vias) |x| try l.rect(arena, "via1", x - 100, 650, x + 100, 850);
    try loadAt(arena, &l, load, 0);
    return l;
}

fn oneMa(arena: std.mem.Allocator, net: []const u8) ![]const u8 {
    return intentOf(arena, 1800.0, &.{.{ net, "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"{s}\",\"budget_current_ua\":1000}}", .{net}));
}

fn emRow(arena: std.mem.Allocator, density: []const u8, blech: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\rule em electromigration(met1, max_density: {s}, max_current_per_cut: 1mA,
        \\    blech_limit: {s}, reference_temperature: 105C, activation_energy: 0.9eV, current_exponent: 2)
        \\
    , .{ density, blech });
}

/// A VDD bar and a VSS bar, no loads: every node sits at its pad.
fn twoRails(arena: std.mem.Allocator) !Layout {
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, 4_000, 1_000, "VDD");
    try named(arena, &l, "met1", 0, 3_000, 4_000, 4_000, "VSS");
    return l;
}

fn relRow(arena: std.mem.Allocator, required: []const u8, reference_temperature: []const u8, duty: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\rule rel reliability(required_lifetime: {s}, reference_lifetime: 1000h,
        \\    reference_stress: 1800mV, stress_exponent: 4, reference_temperature: {s},
        \\    activation_energy: 0.7eV, max_abs_voltage: 10V, duty_cycle: {s})
        \\
    , .{ required, reference_temperature, duty });
}

fn expectAt(f: fixture.Found, x: i64, y: i64) !void {
    try testing.expectEqual([2]i64{ x, y }, f.at);
}

test "ir drop on a series ladder is ohms law and strict at the limit" {
    // Oracle: Ohm's law on a series ladder. 3000 µA splits 1000 µA per load;
    // segments of 2, 2 and 4 squares of 0.125 Ω carry 3000, 2000 and 1000
    // µA: drops 0.75, 1.25 and 1.75 mV, the last at (18000, 500). A limit of
    // 1.75 mV sits exactly on the worst node (legal, strict); 1.7 and 1.25 mV
    // catch only the far node; 100 mV nothing. The same on a ground rail,
    // the far node 1.75 mV above 0 V.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{ .{ "VDD", "power" }, .{ "VSS", "ground" } }) |sp| {
        for ([_]struct { f64, usize }{ .{ 1.75, 0 }, .{ 1.7, 1 }, .{ 1.25, 1 }, .{ 100.0, 0 } }) |c| {
            const limits = try std.fmt.allocPrint(arena, "{{\"net\":\"{s}\",\"max_drop_mv\":{d},\"budget_current_ua\":3000}}", .{ sp[0], c[0] });
            const r = try erc(arena, "rule ir ir_drop()\n", try intentOf(arena, 1800.0, &.{sp}, limits), try ladderOn(arena, sp[0]));
            const run = try r.run("ir");
            try testing.expectEqual(Outcome.ran, run.outcome);
            try testing.expectEqual(@as(u64, 4), run.examined);
            const rows = try r.rows("ir");
            try testing.expectEqual(c[1], rows.len);
            for (rows) |f| {
                try expectAt(f, 18_000, 500);
                try testing.expectEqual(@as(f64, 1.75), try valueOf(f.measured, .voltage));
                try testing.expectEqual(c[0], try valueOf(f.limit, .voltage));
            }
        }
    }
}

test "a supply ring with a hole solves" {
    // Oracle: construct-from-answer. The ring is one conductor with a hole,
    // so the grid is the pad and the one load tap: the stage runs and
    // examines 2, the hole's row no node.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, 4_000, 4_000, "VDD");
    try l.polygon(arena, "met1", &.{ .{ 1_000, 3_000 }, .{ 3_000, 3_000 }, .{ 3_000, 1_000 }, .{ 1_000, 1_000 } });
    try loadAt(arena, &l, 3_000, 0);
    const r = try erc(arena, "rule ir ir_drop()\n", try intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "{\"net\":\"VDD\",\"max_drop_mv\":100,\"budget_current_ua\":1000}"), l);
    const run = try r.run("ir");
    try testing.expectEqual(Outcome.ran, run.outcome);
    try testing.expectEqual(@as(u64, 2), run.examined);
}

test "a via into a global layer is no grid link" {
    // Oracle: docs/deck.md, Connectivity: a global layer is "net-only, not a
    // conductor: it carries no modelled current", so a tie into it adds no
    // grid link and `ir_drop` runs.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, 4_000, 1_000, "VDD");
    try l.rect(arena, "sub", 0, 0, 4_000, 1_000);
    try l.rect(arena, "tie", 200, 200, 400, 400);
    try loadAt(arena, &l, 3_000, 0);
    const rules = "layer sub = gds(6, 0)\nlayer tie = gds(7, 0)\nconnect global sub\nconnect via tie [met1, sub]\nrule ir ir_drop()\n";
    const r = try erc(arena, rules, try intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "{\"net\":\"VDD\",\"max_drop_mv\":100,\"budget_current_ua\":1000}"), l);
    try testing.expectEqual(Outcome.ran, (try r.run("ir")).outcome);
}

test "ir drop through two parallel vias divides the current inversely to resistance" {
    // Oracle: a current divider. Branch A (x = 5000): 1 square of met2, a cut
    // and 1 square of met1, 0.25 Ω; branch B (x = 11000): 5 squares each and
    // a cut, 1.0 Ω. 5000 µA divides 4:1 and both give the load node 1.0 mV.
    // An electromigration row with a 2000 µA per-cut limit at the sign-off
    // temperature (derate 1) reads via A alone over it, at 4000 µA.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rules =
        \\rule ir ir_drop()
        \\rule em electromigration(via1, met1, max_density: 1000mA/um, max_current_per_cut: 2000uA,
        \\    blech_limit: 1nA, reference_temperature: 85C, activation_energy: 0.9eV, current_exponent: 2)
        \\
    ;
    for ([_]struct { f64, usize }{ .{ 1.1, 0 }, .{ 0.99, 1 } }) |c| {
        const limits = try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"max_drop_mv\":{d},\"budget_current_ua\":5000}}", .{c[0]});
        const r = try erc(arena, rules, try intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, limits), try twoLevels(arena, 12_000, &.{ 5_000, 11_000 }, 6_000));
        const rows = try r.rows("ir");
        try testing.expectEqual(c[1], rows.len);
        for (rows) |f| {
            try testing.expectEqualStrings("met1", f.layer);
            try expectAt(f, 6_000, 500);
            try close(try valueOf(f.measured, .voltage), 1.0);
        }
        const em = try r.rows("em");
        try testing.expectEqual(@as(usize, 1), em.len);
        try testing.expectEqual(@as(i64, 5_000), em[0].at[0]);
        try close(try valueOf(em[0].measured, .current), 4_000.0);
        try testing.expectEqual(@as(f64, 2_000.0), try valueOf(em[0].limit, .current));
        try testing.expectEqual(@as(u64, 2 + 2), (try r.run("em")).examined);
    }
}

test "electromigration without a sign off temperature is refused" {
    // Oracle: construct-from-answer. With no sign-off temperature from the
    // intent or the deck the row has nothing to derate to and is refused;
    // at one the same row runs.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rules = try emRow(arena, "10mA/um", "1nA");
    const at = try ercAt(arena, rules, try oneMa(arena, "VDD"), try singleEdge(arena), true);
    try testing.expectEqual(Outcome.ran, (try at.run("em")).outcome);
    const none = try ercAt(arena, rules, try oneMa(arena, "VDD"), try singleEdge(arena), false);
    try testing.expectEqual(Outcome.refused, (try none.run("em")).outcome);
    try testing.expectEqual(@as(usize, 0), (try none.rows("em")).len);
}

test "electromigration derates a celsius rating by black and arrhenius" {
    // Oracle: Black with Arrhenius derating, the reference in Celsius. The
    // edge carries 1000 µA over 1 µm: at 0.462 mA/µm the derated limit is
    // 462 A/m × 1e-6 m × 2.16226 = 998.96 µA, one violation; at 0.463 mA/µm
    // 1001.12 µA, clean; at 10 mA/µm far above.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const derate = @exp(0.9 / (2.0 * k_ev) * (1.0 / t_signoff - 1.0 / (105.0 + 273.15)));
    try close(derate, derate_105c);
    for ([_]struct { []const u8, f64, usize }{ .{ "0.462mA/um", 462.0, 1 }, .{ "0.463mA/um", 463.0, 0 }, .{ "10mA/um", 10_000.0, 0 } }) |c| {
        const r = try erc(arena, try emRow(arena, c[0], "1nA"), try oneMa(arena, "VDD"), try singleEdge(arena));
        const run = try r.run("em");
        try testing.expectEqual(Outcome.ran, run.outcome);
        try testing.expectEqual(@as(u64, 1), run.examined);
        const rows = try r.rows("em");
        try testing.expectEqual(c[2], rows.len);
        for (rows) |f| {
            try testing.expectEqualStrings("met1", f.layer);
            try expectAt(f, 10_000, 500);
            try close(try valueOf(f.measured, .current), 1_000.0);
            try close(try valueOf(f.limit, .current), c[1] * 1e-6 * 1e6 * derate_105c);
        }
    }
}

test "a blech immortal segment is exempt exactly up to its product" {
    // Oracle: the Blech product `J L = I L / W`: 1000 µA × 8000 / 1000 =
    // 8 mA. At a limit of exactly 8 mA the segment is immortal (inclusive):
    // not examined, not reported, against a density it exceeds a
    // thousandfold. At 7.999 mA it is mortal and reported.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { []const u8, u64 }{ .{ "8mA", 0 }, .{ "7.999mA", 1 } }) |c| {
        const r = try erc(arena, try emRow(arena, "0.001mA/um", c[0]), try oneMa(arena, "VDD"), try singleEdge(arena));
        const run = try r.run("em");
        try testing.expectEqual(Outcome.ran, run.outcome);
        try testing.expectEqual(c[1], run.examined);
        try testing.expectEqual(@as(usize, @intCast(c[1])), (try r.rows("em")).len);
    }
}

test "a multi layer electromigration row limits metal per width and cuts per cut" {
    // Oracle: one row over three layers applies the per-width limit to metal
    // and the per-cut limit to the via, each derated by 2.16226. Metal: 400
    // µA derated 864.90 µA, under the 1000 µA every edge carries: three
    // violations (met2 once, met1 twice). Via: 500 µA derated 1081.13 µA,
    // clean. Every Blech product is above 100 µA, so four are examined. At
    // an 85 °C reference the derating is 1: a 1000 µA per-cut limit sits on
    // the via's current, clean; 999 µA reports it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rules =
        \\rule em electromigration(met1, met2, via1, max_density: 0.4mA/um,
        \\    max_current_per_cut: 500uA, blech_limit: 100uA, reference_temperature: 105C,
        \\    activation_energy: 0.9eV, current_exponent: 2)
        \\
    ;
    const r = try erc(arena, rules, try oneMa(arena, "VDD"), try twoLevels(arena, 8_000, &.{6_000}, 2_000));
    const run = try r.run("em");
    try testing.expectEqual(Outcome.ran, run.outcome);
    try testing.expectEqual(@as(u64, 4), run.examined);
    var met1: u32 = 0;
    var met2: u32 = 0;
    for (try r.rows("em")) |f| {
        if (std.mem.eql(u8, f.layer, "met1")) met1 += 1 else if (std.mem.eql(u8, f.layer, "met2")) met2 += 1 else return error.UnexpectedLayer;
        try close(try valueOf(f.measured, .current), 1_000.0);
        try close(try valueOf(f.limit, .current), 400.0 * derate_105c);
    }
    try testing.expectEqual(@as(u32, 2), met1);
    try testing.expectEqual(@as(u32, 1), met2);

    for ([_]struct { []const u8, usize }{ .{ "1000uA", 0 }, .{ "999uA", 1 } }) |c| {
        const via_rules = try std.fmt.allocPrint(arena,
            \\rule em electromigration(via1, max_density: 1000mA/um, max_current_per_cut: {s},
            \\    blech_limit: 100uA, reference_temperature: 85C, activation_energy: 0.9eV, current_exponent: 2)
            \\
        , .{c[0]});
        const v = try erc(arena, via_rules, try oneMa(arena, "VDD"), try twoLevels(arena, 8_000, &.{6_000}, 2_000));
        const rows = try v.rows("em");
        try testing.expectEqual(c[1], rows.len);
        for (rows) |f| {
            try testing.expectEqualStrings("via1", f.layer);
            try testing.expectEqual(@as(f64, 1_000.0), try valueOf(f.measured, .current));
        }
    }
}

test "reliability at its reference point is strict at the required lifetime" {
    // Oracle: the model at its own reference point. Characterised at 1800 mV
    // and 85 °C for 1000 h at full duty, a node there lasts exactly 1000 h:
    // a 1000 h requirement is met (strict), 1001 h is not. VSS sits at 0 V,
    // no stress, never reported.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const supplies = [_][2][]const u8{ .{ "VDD", "power" }, .{ "VSS", "ground" } };
    for ([_]struct { []const u8, usize }{ .{ "1000h", 0 }, .{ "1001h", 1 } }) |c| {
        const r = try erc(arena, try relRow(arena, c[0], "85C", "1"), try intentOf(arena, 1800.0, &supplies, ""), try twoRails(arena));
        const run = try r.run("rel");
        try testing.expectEqual(Outcome.ran, run.outcome);
        try testing.expectEqual(@as(u64, 2), run.examined);
        const rows = try r.rows("rel");
        try testing.expectEqual(c[1], rows.len);
        for (rows) |f| {
            try expectAt(f, 2_000, 500);
            try testing.expectEqual(@as(f64, 1_000.0), try valueOf(f.measured, .ratio));
        }
    }
}

test "reliability scales by stress power law arrhenius and duty" {
    // Oracle: inverse power law times Arrhenius, the reference in Celsius,
    // with a duty cycle. Rated 1000 h at 1800 mV and 125 °C, Ea 0.7 eV, n 4,
    // stressed half the time: Arrhenius 9.76327790, stress (1800/3300)^4,
    // duty 2, so at 85 °C and 3300 mV it lasts 1728.4623 h: 1730 h is
    // missed, 1728 h met; at 1800 mV it lasts 19526.56 h.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const thermal = @exp(0.7 / k_ev * (1.0 / t_signoff - 1.0 / (125.0 + 273.15)));
    try close(thermal, 9.763_277_903_048_08);
    const at_3v3 = 1_000.0 * thermal / 0.5 * std.math.pow(f64, 1_800.0 / 3_300.0, 4);
    try close(at_3v3, 1_728.462_285_684_08);
    const supplies = [_][2][]const u8{ .{ "VDD", "power" }, .{ "VSS", "ground" } };
    for ([_]struct { f64, []const u8, usize }{ .{ 3300.0, "1730h", 1 }, .{ 3300.0, "1728h", 0 }, .{ 1800.0, "1730h", 0 } }) |c| {
        const r = try erc(arena, try relRow(arena, c[1], "125C", "50%"), try intentOf(arena, c[0], &supplies, ""), try twoRails(arena));
        try testing.expectEqual(Outcome.ran, (try r.run("rel")).outcome);
        const rows = try r.rows("rel");
        try testing.expectEqual(c[2], rows.len);
        for (rows) |f| {
            try expectAt(f, 2_000, 500);
            try close(try valueOf(f.measured, .ratio), at_3v3);
        }
    }
}

test "ir drop on a ground rail is its bounce above zero" {
    // Oracle: Ohm's law on the ground rail. VSS returns 1000 µA through 8
    // squares of 0.125 Ω: the far node rises 1.0 mV above 0 V, and a 0.5 mV
    // limit reports it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var l: Layout = .{};
    try named(arena, &l, "met1", 0, 0, 20_000, 1_000, "VSS");
    try loadAt(arena, &l, 18_000, 0);
    const r = try erc(arena, "rule ir ir_drop()\n", try intentOf(arena, 1800.0, &.{.{ "VSS", "ground" }}, "{\"net\":\"VSS\",\"max_drop_mv\":0.5,\"budget_current_ua\":1000}"), l);
    const rows = try r.rows("ir");
    try testing.expectEqual(@as(usize, 1), rows.len);
    try expectAt(rows[0], 18_000, 500);
    try testing.expectEqual(@as(f64, 1.0), try valueOf(rows[0].measured, .voltage));
}

test "p2p resistance is the worst attach pair by ohms law" {
    // Oracle: Ohm's law on the per-net network. Three loads on one 20 µm bar
    // at x = 2000, 6000, 18000: the worst pair is the outer two, 16 squares
    // of 0.125 Ω = 2.0 Ω. Two met1 bars joined through met2 by a via each:
    // 0.25 + 0.0625 + 0.375 + 0.0625 + 0.25 = 1.0 Ω. The probe is a dense
    // solve, exact to rounding, so the limits sit 0.01 Ω either side.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A supply no labelled net carries: p2p reads no intent.
    const no_supply = try intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "");
    var bar: Layout = .{};
    try bar.rect(arena, "met1", 0, 0, 20_000, 1_000);
    for ([_]i64{ 2_000, 6_000, 18_000 }) |x| try loadAt(arena, &bar, x, 0);
    var bridged: Layout = .{};
    try bridged.rect(arena, "met1", 0, 0, 4_000, 1_000);
    try bridged.rect(arena, "met1", 8_000, 0, 12_000, 1_000);
    try bridged.rect(arena, "met2", 0, 500, 12_000, 1_500);
    try bridged.rect(arena, "via1", 2_900, 650, 3_100, 850);
    try bridged.rect(arena, "via1", 8_900, 650, 9_100, 850);
    try loadAt(arena, &bridged, 1_000, 0);
    try loadAt(arena, &bridged, 11_000, 0);
    const Case = struct { max: []const u8, flagged: usize, layout: *const Layout, ohms: f64, ends: [2]i64 };
    for ([_]Case{
        .{ .max = "2.01ohm", .flagged = 0, .layout = &bar, .ohms = 2.0, .ends = .{ 2_000, 18_000 } },
        .{ .max = "1.99ohm", .flagged = 1, .layout = &bar, .ohms = 2.0, .ends = .{ 2_000, 18_000 } },
        .{ .max = "1.01ohm", .flagged = 0, .layout = &bridged, .ohms = 1.0, .ends = .{ 1_000, 11_000 } },
        .{ .max = "0.99ohm", .flagged = 1, .layout = &bridged, .ohms = 1.0, .ends = .{ 1_000, 11_000 } },
    }) |c| {
        const r = try erc(arena, try std.fmt.allocPrint(arena, "rule p2p p2p_resistance(; max: {s})\n", .{c.max}), no_supply, c.layout.*);
        const run = try r.run("p2p");
        try testing.expectEqual(Outcome.ran, run.outcome);
        try testing.expectEqual(@as(u64, 1), run.examined);
        const rows = try r.rows("p2p");
        try testing.expectEqual(c.flagged, rows.len);
        for (rows) |f| {
            try testing.expectEqualStrings("met1", f.layer);
            try testing.expect(f.at[1] == 500 and (f.at[0] == c.ends[0] or f.at[0] == c.ends[1]));
            try close(try valueOf(f.measured, .resistance), c.ohms);
        }
    }
}

test "ac current rows load the grid with their own current" {
    // Oracle: Ohm's law and the table, by hand. The whole stated current
    // flows through the 1 µm edge: against a one-cell table of D µA/µm the
    // limit is D µA. RMS 500 µA and peak 2000 µA: 999 µA/µm passes RMS and
    // fails peak; 2000 passes both (at the limit); 499 fails both.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const currents = try intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "{\"net\":\"VDD\",\"budget_current_ua\":7,\"rms_current_ua\":500,\"peak_current_ua\":2000,\"frequency_mhz\":100}");
    for ([_]struct { u32, ?f64, ?f64 }{ .{ 999, null, 2_000.0 }, .{ 2_000, null, null }, .{ 499, 500.0, 2_000.0 } }) |c| {
        const rules = try std.fmt.allocPrint(arena, "rule rms em_rms(met1; frequency: [100MHz], width: [0um], density: [[{d}uA/um]], max_current_per_cut: 1000uA)\n" ++
            "rule pk em_peak(met1; frequency: [100MHz], width: [0um], density: [[{d}uA/um]], max_current_per_cut: 1000uA)\n", .{ c[0], c[0] });
        const r = try erc(arena, rules, currents, try singleEdge(arena));
        for ([_]struct { []const u8, ?f64 }{ .{ "rms", c[1] }, .{ "pk", c[2] } }) |rw| {
            const run = try r.run(rw[0]);
            try testing.expectEqual(Outcome.ran, run.outcome);
            try testing.expectEqual(@as(u64, 1), run.examined);
            const rows = try r.rows(rw[0]);
            try testing.expectEqual(@as(usize, @intFromBool(rw[1] != null)), rows.len);
            for (rows) |f| {
                try testing.expectEqualStrings("met1", f.layer);
                try close(try valueOf(f.measured, .current), rw[1] orelse 0.0);
                try close(try valueOf(f.limit, .current), @floatFromInt(c[0]));
            }
        }
    }
}

test "ir drop examines every node whose net states any limit" {
    // Oracle: Ohm's law on the series ladder (worst 1.75 mV of 1800 mV):
    // with an absolute limit, a fraction and an overvoltage stated, the pad
    // and three load taps are examined; a 0.0009 fraction (1.62 mV) catches
    // the far node alone, the absolute 100 mV nothing.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try erc(arena, "rule ir ir_drop()\n", try intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, "{\"net\":\"VDD\",\"max_drop_mv\":100,\"max_drop_fraction\":0.0009,\"max_overvoltage_mv\":100,\"budget_current_ua\":3000}"), try ladderOn(arena, "VDD"));
    const run = try r.run("ir");
    try testing.expectEqual(Outcome.ran, run.outcome);
    try testing.expectEqual(@as(u64, 4), run.examined);
    const rows = try r.rows("ir");
    try testing.expectEqual(@as(usize, 1), rows.len);
    try expectAt(rows[0], 18_000, 500);
    try testing.expectEqual(@as(f64, 1.75), try valueOf(rows[0].measured, .voltage));
}
