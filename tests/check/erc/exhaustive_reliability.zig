//! Lifetime and absolute-voltage stress (`reliability`) on met1 rails, and
//! the outcomes the grid alone decides: drawn rails and an intent in, the
//! inverse power law times Arrhenius against each node's voltage, and the
//! refusals of a budget that reaches no device and a conductor with no
//! sheet resistance out. Ported from tests/exhaustive/erc.rs
//! (`reliability`, the refused half of `grid_outcomes`, `INTENT_ROWS`,
//! `rule_lines`); the skipped half is exhaustive_skipped.zig.
//!
//! Contents:
//! - `pub const Row`, `pub const current_rows: [4]Row`, `pub fn ruleLines(arena, rows: []const Row) ![]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const pc = @import("ported_circuit.zig");
const side = pc.side;
const cf = @import("closed_form.zig");
const rails = @import("exhaustive_rails.zig");
const at = rails.at;
const claim = rails.claim;

/// A rule id and the deck spelling of its row.
pub const Row = struct { []const u8, []const u8 };

/// The intent-gated kinds that read the solved grid's currents or
/// voltages, with the deck spelling of one row: the first four of Rust's
/// `INTENT_ROWS`.
pub const current_rows = [_]Row{
    .{ "s.ir", "ir_drop()" },
    .{ "s.emcd", "em_current_density(met1; max_density: 1mA/um, max_current_per_cut: 1mA, narrow: none)" },
    .{ "s.em", "electromigration(met1; max_density: 1mA/um, max_current_per_cut: 1mA, blech_limit: 1nA, reference_temperature: 85C, activation_energy: 0.9eV, current_exponent: 2)" },
    .{ "s.rel", "reliability(; required_lifetime: 1h, reference_lifetime: 1000h, reference_stress: 1800mV, stress_exponent: 2, reference_temperature: 85C, activation_energy: 0.7eV, max_abs_voltage: 10V, duty_cycle: 1)" },
};

/// `rule <id> <row>` lines.
pub fn ruleLines(arena: Allocator, rows: []const Row) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (rows) |r| try out.print(arena, "rule {s} {s}\n", .{ r[0], r[1] });
    return out.items;
}

// ---- private ----

/// `reliability` (ERC-E5, F5): `t = t_ref (V_ref / V)^n exp(Ea / k (1/T -
/// 1/T_ref)) / duty`, rated 1000 h at 1.8 V, against every combination of a
/// 1.8 or 3.3 V domain, n of 2 or 4, rating at 85 or 125 °C, and full or half
/// duty, the required lifetime a part in a million either side. The VSS rail
/// sits at 0 V, unstressed. `max_abs_voltage` swept at the VDD voltage. A
/// loaded rail stresses its pad (1.8 V) harder than its far node (1.799 V):
/// a requirement between the two lifetimes flags the pad only.
fn reliability(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var two: Layout = .{};
    try rails.rail(&two, arena, "VDD", 4000, 0, 1000, &.{});
    try rails.rail(&two, arena, "VSS", 4000, 3000, 1000, &.{});
    for ([_]f64{ 1800.0, 3300.0 }) |v| {
        const supplies = try rails.intentAt(arena, v, &.{ .{ "VDD", "power" }, .{ "VSS", "ground" } }, "");
        for ([_]f64{ 2.0, 4.0 }) |n| {
            for ([_]struct { []const u8, f64 }{ .{ "85C", 358.15 }, .{ "125C", 398.15 } }) |r| {
                for ([_]f64{ 1.0, 0.5 }) |duty| {
                    const t = lifetime(v, n, r[1], duty);
                    for ([_]f64{ 1.0 - 1e-6, 1.0 + 1e-6 }) |factor| try out.append(arena, .{
                        .name = try std.fmt.allocPrint(arena, "erc/reliability/lifetime/{d}mV/n{d}/{s}/duty{d}/{s}", .{ v, n, r[0], duty, side(factor, 1.0) }),
                        .deck = try relRow(arena, t * factor, r[0], n, duty, "10V"),
                        .layout = two,
                        .intent = supplies,
                        .expect = try claim(arena, "rel", if (factor > 1.0) &.{at(pc.ratio(t), 2000, 500)} else &.{}),
                    });
                }
            }
        }
        for ([_]f64{ v - 0.5, v, v + 0.5 }) |cap| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/reliability/max_abs_voltage/{d}mV/{s}", .{ v, side(cap, v) }),
            .deck = try relRow(arena, 1.0, "85C", 2.0, 1.0, try std.fmt.allocPrint(arena, "{d}mV", .{cap})),
            .layout = two,
            .intent = supplies,
            .expect = try claim(arena, "rel", if (cap < v) &.{at(pc.millivolts(v), 2000, 500)} else &.{}),
        });
    }
    // A 20 µm rail with 1 mA at 18 µm: 8 squares, 1 Ω, so the far node sits
    // at 1799 mV.
    var loaded: Layout = .{};
    try rails.rail(&loaded, arena, "VDD", 20_000, 0, 1000, &.{18_000});
    const pad = lifetime(1800.0, 4.0, 358.15, 1.0);
    const far = lifetime(1799.0, 4.0, 358.15, 1.0);
    try out.append(arena, .{
        .name = "erc/reliability/loaded_rail",
        .deck = try relRow(arena, (pad + far) / 2.0, "85C", 4.0, 1.0, "10V"),
        .layout = loaded,
        .intent = try rails.vddIntent(arena, 1000.0),
        .expect = try claim(arena, "rel", &.{at(pc.ratio(pad), 10_000, 500)}),
    });
}

/// Hours to failure at `v` mV: rated 1000 h at 1.8 V and `t_ref`, Ea 0.7 eV,
/// run at the sign-off temperature.
fn lifetime(v: f64, n: f64, t_ref: f64, duty: f64) f64 {
    return 1000.0 * std.math.pow(f64, 1800.0 / v, n) * @exp(0.7 / rails.k_ev * (1.0 / rails.t_signoff - 1.0 / t_ref)) / duty;
}

fn relRow(arena: Allocator, required: f64, t_ref: []const u8, n: f64, duty: f64, cap: []const u8) ![]const u8 {
    return rails.rules(arena, "rule rel reliability(required_lifetime: {d}h, reference_lifetime: 1000h, reference_stress: 1800mV, stress_exponent: {d}, reference_temperature: {s}, activation_energy: 0.7eV, max_abs_voltage: {s}, duty_cycle: {d})", .{ required, n, t_ref, cap, duty });
}

/// Outcomes the grid and intent decide (the refused half of
/// `grid_outcomes`): a budget that reaches no device refuses the current
/// rules but not `reliability` (no current is the fail-closed stress); a
/// conductor with no sheet resistance refuses every kind that reads a
/// resistance, and nothing else.
fn gridRefusals(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const lines = try ruleLines(arena, &current_rows);
    // A budget on a rail with no device.
    var bare: Layout = .{};
    try rails.rail(&bare, arena, "VDD", 20_000, 0, 1000, &.{});
    try out.append(arena, .{
        .name = "erc/refused/budget_reaches_no_device",
        .deck = try rails.railDeck(arena, lines),
        .layout = bare,
        .intent = try rails.vddIntent(arena, 1000.0),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "s.ir", .outcome = .refused },
            .{ .id = "s.emcd", .outcome = .refused },
            .{ .id = "s.em", .outcome = .refused },
            .{ .id = "s.rel" },
        }),
    });
    // No sheet resistance for poly, a conductor the loads touch.
    const poly_pex = "pex poly thickness 100nm height 50nm sheet 8ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um\n";
    std.debug.assert(std.mem.indexOf(u8, cf.process, poly_pex) != null);
    var layout: Layout = .{};
    try rails.rail(&layout, arena, "VDD", 20_000, 0, 1000, &.{18_000});
    try out.append(arena, .{
        .name = "erc/refused/no_sheet_resistance",
        .deck = try std.mem.concat(arena, u8, &.{ try std.mem.replaceOwned(u8, arena, cf.process, poly_pex, ""), lines, "rule p2p p2p_resistance(; max: 1ohm)\nrule fg floating_gate(; labels_are_ports: false)\n" }),
        .layout = layout,
        .intent = try rails.vddIntent(arena, 1000.0),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "s.ir", .outcome = .refused },
            .{ .id = "s.emcd", .outcome = .refused },
            .{ .id = "s.em", .outcome = .refused },
            .{ .id = "s.rel", .outcome = .refused },
            .{ .id = "p2p", .outcome = .refused },
            .{ .id = "fg" },
        }),
    });
}

// Oracle: the inverse power law times Arrhenius, `t = t_ref (V_ref / V)^n
// exp(Ea / k (1/T - 1/T_ref)) / duty`, rated 1000 h at 1.8 V, the required
// lifetime a part in a million either side over every domain, exponent,
// rating temperature and duty; `max_abs_voltage` swept at the VDD voltage; a
// loaded rail's pad (1.8 V) flagged and its far node (1.799 V) not.
test "reliability predicts each node's lifetime and caps its voltage" {
    try rails.checkGroup(reliability);
}

// Oracle: construct-from-answer. A budget on a rail with no device refuses
// `ir_drop`, `em_current_density` and `electromigration` and leaves
// `reliability` clean; a conductor (poly) with no sheet resistance refuses
// every kind that reads a resistance and leaves `floating_gate` clean.
test "the grid refuses the rows it cannot answer" {
    try rails.checkGroup(gridRefusals);
}
