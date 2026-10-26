//! The ESD and latch-up kinds in the deck library survive the printer.
//! Ported from crates/check/tests/deck/esd_kinds.rs; its constructor test
//! (`every_esd_and_latchup_kind_has_a_constructor_equal_to_its_text`)
//! waits for the per-kind row constructors (`deck::rules`), as builder.zig
//! notes.

const common = @import("common.zig");

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

test "every esd and latchup kind survives printing" {
    // Oracle: round trip: every ESD and latch-up kind, each optional limit
    // stated and left out, prints, compiles back typed the same, and
    // prints again to the same text.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    try common.assertRoundTrip("esd and latch-up kinds", &c);
}
