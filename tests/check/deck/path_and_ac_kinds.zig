//! The path, loop, supply-piece, matching, power-switch, clamp-resistance
//! and AC current-density kinds in the deck library survive the printer.
//! Ported from crates/check/tests/deck/path_and_ac_kinds.rs; its
//! constructor test (`every_path_and_ac_kind_has_a_constructor_equal_to_its_text`)
//! waits for the per-kind row constructors (`deck::rules`), as builder.zig
//! notes.

const common = @import("common.zig");

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

test "every path and ac kind survives printing" {
    // Oracle: round trip: every kind, an AC table of two frequencies by two
    // widths and one of a single entry, prints, compiles back typed the
    // same, and prints again to the same text.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    try common.assertRoundTrip("path and AC kinds", &c);
}
