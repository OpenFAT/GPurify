//! The skipped half of `grid_outcomes`: every intent-gated kind on a loaded
//! rail with no intent file, and with an intent naming no net of the layout,
//! must record Skipped while the intent-free kinds run clean. Ported from
//! tests/exhaustive/erc.rs (`grid_outcomes`, `INTENT_ROWS`). Not wired into
//! tests/check.zig until the domain family is ported: its stubs refuse
//! every `gate_oxide`, `drain_source`, `well_bias`,
//! `missing_level_shifter` and `domain_crossing` row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const rails = @import("exhaustive_rails.zig");
const rel = @import("exhaustive_reliability.zig");
const Row = rel.Row;

/// Every kind that needs design intent, with the deck spelling of one row.
const intent_rows = rel.current_rows ++ [_]Row{
    .{ "s.hv", "hv_domain(; max_delta: 1V, isolation: none)" },
    .{ "s.esdl", "esd_latchup(met2, mk; min_guard_ring_width: 1nm, max_tap_distance: 1nm, clamps: [\"load\"])" },
    .{ "s.esd", "esd_topological(met2; clamps: [\"load\"])" },
    .{ "s.gox", "gate_oxide(; models: [\"load\"], max: 1V)" },
    .{ "s.vds", "drain_source(; models: [\"load\"], max: 1V)" },
    .{ "s.wb", "well_bias(; pmos: [\"load\"], nmos: none)" },
    .{ "s.ls", "missing_level_shifter(; shifters: none)" },
    .{ "s.xing", "domain_crossing()" },
    .{ "s.dir", "dynamic_ir_drop()" },
    .{ "s.emt", "em_thermal(met1; max_density: 1mA/um, max_current_per_cut: 1mA, blech_limit: 1nA, reference_temperature: 85C, activation_energy: 0.9eV, current_exponent: 2, thermal_conductivity: 1.4W/mK, spreading: 0.88, sigma: 0.5, limit_failure: 0.1%, max_failure: 0.1%)" },
};

// ---- private ----

/// Outcomes the grid and intent decide: every intent-gated kind records
/// Skipped with no intent file, and with an intent naming no net of the
/// layout, while the kinds that need none run.
fn gridSkips(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try rails.railDeck(arena, try std.mem.concat(arena, u8, &.{ try rel.ruleLines(arena, &intent_rows), "rule p2p p2p_resistance(; max: 1ohm)\nrule fg floating_gate(; labels_are_ports: false)" }));
    var layout: Layout = .{};
    try rails.rail(&layout, arena, "VDD", 20_000, 0, 1000, &.{18_000});
    var expect: std.ArrayList(Expect) = .empty;
    try expect.appendSlice(arena, &.{ .{ .id = "p2p" }, .{ .id = "fg" } });
    for (intent_rows) |r| try expect.append(arena, .{ .id = r[0], .outcome = .skipped });
    const Case = struct { []const u8, ?[]const u8 };
    for ([_]Case{
        .{ "no_intent", null },
        .{ "intent_names_no_layout_net", try rails.intent(arena, &.{.{ "NOPE", "power" }}, "") },
    }) |case| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/skipped/{s}", .{case[0]}),
        .deck = deck,
        .layout = layout,
        .intent = case[1],
        .expect = expect.items,
    });
}

// Oracle: construct-from-answer. Every intent-gated kind records Skipped with
// no intent file and with an intent naming no layout net; `p2p_resistance`
// and `floating_gate`, which need none, run clean.
test "intent-gated rows skip without an intent that names the layout" {
    try rails.checkGroup(gridSkips);
}
