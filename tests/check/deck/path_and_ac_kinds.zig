//! The path, loop, supply-piece, matching, power-switch, clamp-resistance
//! and AC current-density kinds in the deck library survive the printer.
//! Each constructor states what its deck spelling does. Ported from
//! crates/check/tests/deck/path_and_ac_kinds.rs.

const check = @import("check");
const common = @import("common.zig");
const DeckBuilder = check.deck.DeckBuilder;
const row = check.deck.rules.row;
const l = check.deck.expr.layer;

const text =
    \\grid 1nm
    \\layer pad = gds(1, 0)
    \\layer met1 = gds(2, 0)
    \\layer via1 = gds(3, 0)
    \\layer mk = gds(4, 0)
    \\connect conductors [pad, met1]
    \\device diode mk model "dio" terminals [met1, pad]
    \\rule sp supply_path(; both: true, labels_are_ports: true)
    \\rule gp gate_path(; ground: false, max_devices: 3)
    \\rule cl combinational_loop()
    \\rule fs floating_supply()
    \\rule mt matching(mk; tolerance: 50nm)
    \\rule ps power_switch(; models: ["dio"])
    \\rule cr esd_clamp_resistance(pad; clamps: ["dio"], max_resistance: 1ohm)
    \\rule pp esd_pin_pair(pad; clamps: ["dio"], current: 1330mA, clamp_resistance: 1ohm, max_resistance: 5ohm)
    \\rule rms em_rms(met1, via1; frequency: [100MHz, 300MHz], width: [500nm, 1500nm], density: [[1mA/um, 2mA/um], [3mA/um, 4mA/um]], max_current_per_cut: 1mA)
    \\rule pk em_peak(met1; frequency: [1GHz], width: [0nm], density: [[6.1mA/um]], max_current_per_cut: 100uA)
    \\
;

// ---- private ----

/// `text` built in code, statement by statement.
fn build(b: *DeckBuilder) anyerror!void {
    @setEvalBranchQuota(100_000);
    const a = b.arena;
    for ([_][]const u8{ "pad", "met1", "via1", "mk" }, 1..) |name, gds| try b.layer(name, .{ @intCast(gds), 0 });
    try b.doc.connectivity.conductors.appendSlice(a, &.{ "pad", "met1" });
    try b.doc.devices.append(a, .{ .kind = .diode, .marker = "mk", .model = "dio", .terminals = &.{ "met1", "pad" } });
    try b.rule("sp", row(.supply_path, .{}, .{ .both = true, .labels_are_ports = true }));
    try b.rule("gp", row(.gate_path, .{}, .{ .ground = false, .max_devices = 3 }));
    try b.rule("cl", row(.combinational_loop, .{}, .{}));
    try b.rule("fs", row(.floating_supply, .{}, .{}));
    try b.rule("mt", row(.matching, .{ .group = l("mk") }, .{ .tolerance = 50 }));
    try b.rule("ps", row(.power_switch, .{}, .{ .model = &.{"dio"} }));
    try b.rule("cr", row(.esd_clamp_resistance, .{ .pad = l("pad") }, .{ .clamp = &.{"dio"}, .max_resistance = 1.0 }));
    try b.rule("pp", row(.esd_pin_pair, .{ .pad = l("pad") }, .{ .clamp = &.{"dio"}, .current = 1_330_000.0, .clamp_resistance = 1.0, .max_resistance = 5.0 }));
    try b.rule("rms", row(.em_rms, .{ .layers = &.{ "met1", "via1" } }, .{ .frequency = &.{ 100.0, 300.0 }, .width = &.{ 500, 1500 }, .density = &.{ 1000.0, 2000.0, 3000.0, 4000.0 }, .max_current_per_cut = 1000.0 }));
    try b.rule("pk", row(.em_peak, .{ .layers = &.{"met1"} }, .{ .frequency = &.{1000.0}, .width = &.{0}, .density = &.{6100.0}, .max_current_per_cut = 100.0 }));
}

test "every path and ac kind has a constructor equal to its text" {
    // Oracle: differential against the parser, the same deck written as text.
    try common.assertBuildEqualsText("path and AC kinds", text, build);
}

test "every path and ac kind survives printing" {
    // Oracle: round trip: every kind, an AC table of two frequencies by two
    // widths and one of a single entry, prints, compiles back typed the
    // same, and prints again to the same text.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    try common.assertRoundTrip("path and AC kinds", &c);
}
