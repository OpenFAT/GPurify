//! The ESD and latch-up kinds in the deck library: each constructor states
//! what its deck spelling does, and every kind survives the printer.
//! Ported from crates/check/tests/deck/esd_kinds.rs.

const check = @import("check");
const common = @import("common.zig");
const DeckBuilder = check.deck.DeckBuilder;
const row = check.deck.rules.row;
const l = check.deck.expr.layer;

const text =
    \\grid 1nm
    \\layer pad = gds(1, 0)
    \\layer diff = gds(2, 0)
    \\layer ring = gds(3, 0)
    \\layer well = gds(4, 0)
    \\layer cont = gds(5, 0)
    \\layer mk = gds(6, 0)
    \\layer gate = gds(7, 0)
    \\connect conductors [pad, diff, ring]
    \\device diode mk model "dio" terminals [diff, pad]
    \\rule ep esd_path(pad; clamps: ["dio"], current: 1330mA, clamp_resistance: 1ohm, max_resistance: 2ohm, clamp_it2: 9.25mA/um, max_density: none, max_current_per_cut: 10mA, max_voltage: 5V, min_width: none, clamp_voltage: 700mV)
    \\rule ep.ring esd_path(pad, ring; clamps: none, current: 100mA, clamp_resistance: 1ohm, max_resistance: 1ohm, clamp_it2: none, max_density: 1mA/um, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none)
    \\rule gc esd_ground_coupling(; diodes: ["dio"])
    \\rule xd esd_cross_domain(; diodes: ["dio"], local: none, resistors: none, min_series: none, max_ground_resistance: none, coupling_resistance: none)
    \\rule xd.local esd_cross_domain(; diodes: ["dio"], local: ["dio"], resistors: ["dio"], min_series: 100ohm, max_ground_resistance: 2ohm, coupling_resistance: 1ohm)
    \\rule par esd_parasitic(pad, diff; min_spacing: 5um)
    \\rule exp esd_exposed(pad; clamps: ["dio"], resistors: none, rated: ["dio"], min_series: none)
    \\rule grb guard_ring_bias(ring; power: false)
    \\rule ta tie_area(well, cont, gate; min_ratio: 3%)
    \\rule gr guard_ring(diff, ring; max_space: 15um, min_width: 2um, pad: pad, near: none, within: none, clear: none)
    \\rule gr.near guard_ring(mk, ring; max_space: none, min_width: none, pad: none, near: well, within: 50um, clear: none)
    \\rule fd forward_diode(mk; models: ["dio"])
    \\rule ct conditional_tie(diff, cont, well, gate; within: 50um, spacing: [1um, 2um], max_distance: [15um, 30um, 50um])
    \\rule lv latchup_victim(pad, diff, cont; within: 15um, max_distance: 2um, pad: pad, bias: none, forward: none)
    \\rule lv.bias latchup_victim(pad, diff, cont; within: 15um, max_distance: 2um, pad: none, bias: well, forward: below)
    \\
;

// ---- private ----

/// `text` built in code, statement by statement.
fn build(b: *DeckBuilder) anyerror!void {
    @setEvalBranchQuota(100_000);
    const a = b.arena;
    for ([_][]const u8{ "pad", "diff", "ring", "well", "cont", "mk", "gate" }, 1..) |name, gds| try b.layer(name, .{ @intCast(gds), 0 });
    try b.doc.connectivity.conductors.appendSlice(a, &.{ "pad", "diff", "ring" });
    try b.doc.devices.append(a, .{ .kind = .diode, .marker = "mk", .model = "dio", .terminals = &.{ "diff", "pad" } });
    try b.rule("ep", row(.esd_path, .{ .pad = l("pad") }, .{ .clamp = &.{"dio"}, .current = 1_330_000.0, .clamp_resistance = 1.0, .max_resistance = 2.0, .clamp_it2 = 9250.0, .max_current_per_cut = 10_000.0, .max_voltage = 5000.0, .clamp_voltage = 700.0 }));
    try b.rule("ep.ring", row(.esd_path, .{ .pad = l("pad"), .source = l("ring") }, .{ .clamp = &.{}, .current = 100_000.0, .clamp_resistance = 1.0, .max_resistance = 1.0, .max_density = 1000.0 }));
    try b.rule("gc", row(.esd_ground_coupling, .{}, .{ .diode = &.{"dio"} }));
    try b.rule("xd", row(.esd_cross_domain, .{}, .{ .diode = &.{"dio"}, .local = &.{}, .resistor = &.{} }));
    try b.rule("xd.local", row(.esd_cross_domain, .{}, .{ .diode = &.{"dio"}, .local = &.{"dio"}, .resistor = &.{"dio"}, .min_series = 100.0, .max_ground_resistance = 2.0, .coupling_resistance = 1.0 }));
    try b.rule("par", row(.esd_parasitic, .{ .pad = l("pad"), .diffusion = l("diff") }, .{ .min_spacing = 5000 }));
    try b.rule("exp", row(.esd_exposed, .{ .pad = l("pad") }, .{ .clamp = &.{"dio"}, .resistor = &.{}, .rated = &.{"dio"} }));
    try b.rule("grb", row(.guard_ring_bias, .{ .ring = l("ring") }, .{ .power = false }));
    try b.rule("ta", row(.tie_area, .{ .region = l("well"), .contact = l("cont"), .channel = l("gate") }, .{ .min_ratio = 0.03 }));
    try b.rule("gr", row(.guard_ring, .{ .target = l("diff"), .ring = l("ring") }, .{ .max_space = 15_000, .min_width = 2000, .pad = "pad" }));
    try b.rule("gr.near", row(.guard_ring, .{ .target = l("mk"), .ring = l("ring") }, .{ .near = "well", .within = 50_000 }));
    try b.rule("fd", row(.forward_diode, .{ .marker = l("mk") }, .{ .model = &.{"dio"} }));
    try b.rule("ct", row(.conditional_tie, .{ .region = l("diff"), .tap = l("cont"), .well = l("well"), .other = l("gate") }, .{ .within = 50_000, .spacing = &.{ 1000, 2000 }, .max_distance = &.{ 15_000, 30_000, 50_000 } }));
    try b.rule("lv", row(.latchup_victim, .{ .aggressor = l("pad"), .region = l("diff"), .tap = l("cont") }, .{ .within = 15_000, .max_distance = 2000, .pad = "pad" }));
    try b.rule("lv.bias", row(.latchup_victim, .{ .aggressor = l("pad"), .region = l("diff"), .tap = l("cont") }, .{ .within = 15_000, .max_distance = 2000, .bias = "well", .forward = 1 }));
}

test "every esd and latchup kind has a constructor equal to its text" {
    // Oracle: differential against the parser, the same deck written as text.
    try common.assertBuildEqualsText("esd and latch-up kinds", text, build);
}

test "every esd and latchup kind survives printing" {
    // Oracle: round trip: every ESD and latch-up kind, each optional limit
    // stated and left out, prints, compiles back typed the same, and
    // prints again to the same text.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    try common.assertRoundTrip("esd and latch-up kinds", &c);
}
