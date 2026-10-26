//! Curated LVS fixtures, second part: declared areas and parameters, what
//! the deck lets the layout measure on a passive, aliases, a ring marker,
//! and a MOS's diffusions. Ported from tests/exhaustive/lvs.rs (`curated`,
//! the declared parameters through the bipolar emitter).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const circuit = @import("lvs_circuit.zig");
const Model = circuit.Model;
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const fx = @import("lvs_fixture.zig");

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try areasInto(arena, out);
    try passivesInto(arena, out);
    try aliasesAndRingInto(arena, out);
    try diffusionsInto(arena, out);
}

// ---- private ----

/// A fixture over `text` claiming the LVS verdict `matched`.
fn texted(arena: Allocator, name: []const u8, catalog: []const []const u8, layout: Layout, text: []const u8, matched: bool) !Fixture {
    var f = try fx.withText(arena, name, catalog, layout, text);
    try f.claim(arena, .{ .lvs = matched });
    return f;
}

/// One two-pin `model` on nets 0 and 1, as `dev` builds it.
fn sized(arena: Allocator, dev: Dev) !Circuit {
    return Circuit.init(arena, 2, &.{dev});
}

fn areasInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // F22, F16, LVS-020, LVS-062..064: declared areas and undeclared names.
    for ([_]struct { Model, i64, []const u8 }{ .{ .c, circuit.pin2_area, "LVS-062" }, .{ .d, circuit.pin2_area, "LVS-063" }, .{ .q, circuit.bjt_area, "LVS-064" } }) |case| {
        const model = case[0];
        const pins: []const usize = if (model == .q) &.{ 0, 1, 2 } else &.{ 0, 1 };
        const alone = try Circuit.init(arena, pins.len, &.{Dev.onPins(model, pins)});
        for ([_]struct { []const u8, i64 }{ .{ "exact", case[1] }, .{ "5pct_over", @divTrunc(case[1] * 105, 100) } }) |area| {
            const r = try Circuit.init(arena, pins.len, &.{Dev.onPins(model, pins).withArea(area[1])});
            try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "params/{c}_area_{s}", .{ model.letter(), area[0] }), &.{ case[2], "LVS-014" }, &alone, &r));
        }
    }
    const diode = try fx.polar(arena, Dev.onPins(.d, &.{ 0, 1 }));
    const declared = try fx.polar(arena, Dev.onPins(.d, &.{ 0, 1 }).withArea(circuit.pin2_area));
    try out.append(arena, try fx.compared(arena, "params/D_area_beside_mos", &.{ "LVS-020", "LVS-063" }, &diode, &declared));
    // F68 (fixed in B21): presence is per device. Two `dpn` cards, one with
    // `area=` and one without, against two drawn diodes: the card without
    // states nothing about its diode's area, so only the other's is compared.
    const diodes = try Circuit.init(arena, 4, &.{ Dev.onPins(.d, &.{ 0, 1 }), Dev.onPins(.d, &.{ 2, 3 }) });
    for ([_]struct { []const u8, i64 }{ .{ "exact", circuit.pin2_area }, .{ "5pct_over", @divTrunc(circuit.pin2_area * 105, 100) } }) |case| {
        var r = try diodes.clone(arena);
        r.devs[0] = r.devs[0].withArea(case[1]);
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "params/D_area_on_one_card_{s}", .{case[0]}), &.{ "LVS-020", "LVS-063" }, &diodes, &r));
    }
}

fn passivesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // F16 (fixed in B6), LVS-061..063: what the deck lets the layout
    // measure on a passive, each value either side of the 2 % tolerance.
    // The resistor's body is 800 by 400 nm along its pads, at 100 ohm/sq;
    // the capacitor's marker 0.32 um² and 2.4 um round, at 1 fF/um² and
    // 0.1 fF/um (`measured`). `r` and `c` are written positionally.
    const r0 = Dev.onPins(.r, &.{ 0, 1 });
    const c0 = Dev.onPins(.c, &.{ 0, 1 });
    const d0 = Dev.onPins(.d, &.{ 0, 1 });
    const res = try sized(arena, r0);
    const cap = try sized(arena, c0);
    const dio = try sized(arena, d0);
    const passives = [_]struct { []const u8, []const u8, *const Circuit, Dev }{
        .{ "R_wl_exact", "LVS-061", &res, r0.param("w", 400e-9).param("l", 800e-9) },
        .{ "R_l_10pct_over", "LVS-061", &res, r0.param("l", 880e-9) },
        .{ "R_r_exact", "LVS-061", &res, r0.valued(200.0) },
        .{ "R_r_5pct_over", "LVS-061", &res, r0.valued(210.0) },
        .{ "C_c_exact", "LVS-062", &cap, c0.valued(5.6e-16) },
        .{ "C_c_area_term_only", "LVS-062", &cap, c0.valued(3.2e-16) },
        .{ "C_perim_exact", "LVS-062", &cap, c0.param("perim", 2.4e-6) },
        .{ "D_area_perim_exact", "LVS-063", &dio, d0.param("area", 3.2e-13).param("perim", 2.4e-6) },
        .{ "D_perim_10pct_over", "LVS-063", &dio, d0.param("perim", 2.64e-6) },
        .{ "D_r_unmeasurable", "LVS-020", &dio, d0.param("r", 200.0) },
    };
    for (passives) |case| {
        const written = try sized(arena, case[3]);
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "params/{s}", .{case[0]}), &.{ case[1], "LVS-014" }, case[2], &written));
    }
    // F86 (fixed in B27): a two-pin card with no model is the deck's one
    // recogniser of its kind, here `rpoly`, `cmim` and `dpn`, so each card
    // above with its model cut out matches what it matched: 200 ohm, 0.56 fF
    // and a bare diode.
    for ([_]struct { []const u8, []const u8, *const Circuit, Dev, []const u8 }{
        .{ "R_r_no_model", "LVS-061", &res, r0.valued(200.0), " rpoly" },
        .{ "C_c_no_model", "LVS-062", &cap, c0.valued(5.6e-16), " cmim" },
        .{ "D_no_model", "LVS-063", &dio, d0, " dpn" },
    }) |case| {
        const written = try sized(arena, case[3]);
        try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "params/{s}", .{case[0]}), &.{case[1]}, try circuit.draw(arena, case[2]), try circuit.edited(arena, try circuit.spice(arena, &written), case[4], ""), true));
    }
}

/// The SPICE of one diode as `dev` builds it, each `names` pair replaced.
fn aliased(arena: Allocator, dev: Dev, names: []const [2][]const u8) ![]const u8 {
    var text = try circuit.spice(arena, &try sized(arena, dev));
    for (names) |n| text = try circuit.edited(arena, text, n[0], n[1]);
    return text;
}

fn aliasesAndRingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const d0 = Dev.onPins(.d, &.{ 0, 1 });
    const dio = try sized(arena, d0);
    const r0 = Dev.onPins(.r, &.{ 0, 1 });
    const res = try sized(arena, r0);
    // F87 (fixed in B27): KLayout's `A`/`P` and ngspice's diode `pj` are the
    // `area` and `perim` above: 0.32 um² and 2.4 um match, 2.64 um does not.
    for ([_]struct { []const u8, []const u8, bool }{
        .{ "D_A_P_exact", try aliased(arena, d0.param("area", 3.2e-13).param("perim", 2.4e-6), &.{ .{ " area=", " A=" }, .{ " perim=", " P=" } }), true },
        .{ "D_pj_exact", try aliased(arena, d0.param("perim", 2.4e-6), &.{.{ " perim=", " pj=" }}), true },
        .{ "D_pj_10pct_over", try aliased(arena, d0.param("perim", 2.64e-6), &.{.{ " perim=", " pj=" }}), false },
    }) |case| {
        try out.append(arena, try texted(arena, try std.fmt.allocPrint(arena, "params/{s}", .{case[0]}), &.{"LVS-063"}, try circuit.draw(arena, &dio), case[1], case[2]));
    }
    // A deck that gives no sheet resistance computes no `r`, and a card
    // stating one is never taken as agreement.
    const deck = try std.mem.replaceOwned(u8, arena, circuit.full_deck, " sheet 100ohm", "");
    var f: Fixture = .init("lvs/params/R_r_without_sheet", &.{ "LVS-061", "LVS-020" }, deck, fx.lvs);
    f.layout = try circuit.draw(arena, &res);
    try f.claim(arena, .{ .lvs = false });
    f.reference = try circuit.spice(arena, &try sized(arena, r0.valued(200.0)));
    try out.append(arena, f);

    // F85 (fixed in B27): a diode marker drawn as a ring, 0..2000 square with
    // a 200 wall (its hole a clockwise polygon of its own), a pad on each
    // side wall. Derived by hand: area 2000² − 1600² nm² = 1.44 µm², edge
    // both rings, 8000 + 6400 nm = 14.4 µm. The hole is no second marker, so
    // `lvs.terminal_net` is clean.
    var ring: Layout = .{};
    try ring.rect(arena, "diom", 0, 0, 2000, 2000);
    try ring.polygon(arena, "diom", &.{ .{ 200, 200 }, .{ 200, 1800 }, .{ 1800, 1800 }, .{ 1800, 200 } });
    try ring.rect(arena, "pina", 0, 900, 200, 1100);
    try ring.rect(arena, "cont", 50, 950, 150, 1050);
    try ring.rect(arena, "pinb", 1800, 900, 2000, 1100);
    try ring.rect(arena, "cont", 1850, 950, 1950, 1050);
    try circuit.stub(arena, &ring, 50, 150, 950, 0);
    try circuit.stub(arena, &ring, 1850, 1950, 950, 1);
    for ([_][]const u8{ "n0", "n1" }, 0..) |name, net| {
        const t = circuit.track(net);
        try ring.rect(arena, "met2", -1000, t, 3000, t + 200);
        try ring.label(arena, "met2_label", -900, t + 100, name);
    }
    const ring_card = try sized(arena, d0.param("area", 1.44e-12).param("perim", 1.44e-5));
    var rf = try texted(arena, "params/D_ring_area_perim", &.{ "LVS-063", "LVS-004" }, ring, try circuit.spice(arena, &ring_card), true);
    try rf.claim(arena, .clean("lvs.terminal_net"));
    try out.append(arena, rf);
}

/// `dev` stating `as` and `ad` of `area`, `ps` and `pd` of `perim`.
fn diffused(dev: Dev, area: f64, perim: f64) Dev {
    return dev.param("as", area).param("ad", area).param("ps", perim).param("pd", perim);
}

fn diffusionsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    // F16 (fixed in B27): a MOS's diffusions, each drawn 500 by 1000 nm:
    // `as` = `ad` = 0.5 um² and `ps` = `pd` = 3 um. Two in parallel sum them,
    // a card's `m` multiplies them, a stack stating them does not merge (the
    // diffusion between would be lost), and 10 % over is a mismatch. A
    // bipolar's emitter, its middle pad 400 nm square: `ae` 0.16 um², `pe`
    // 1.6 um.
    const one = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    const two = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 2, 1) });
    const inner = try (try Circuit.init(arena, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) })).internal(arena, 3);
    const cases = [_]struct { []const u8, *const Circuit, Dev }{
        .{ "params/mos_diffusion_exact", &one, diffused(Dev.mos(.n, 0, 1, 2), 5e-13, 3e-6) },
        .{ "params/mos_diffusion_10pct_over", &one, diffused(Dev.mos(.n, 0, 1, 2), 5.5e-13, 3e-6) },
        .{ "parallel/mos_two_diffused_vs_wide", &two, diffused(Dev.mos(.n, 0, 1, 2).sized(2000, 150), 1e-12, 6e-6) },
        .{ "multiplier/mos_m2_diffused_vs_two", &two, diffused(Dev.mos(.n, 0, 1, 2).times(2), 5e-13, 3e-6) },
        .{ "series/stack_diffused_vs_long", &inner, diffused(Dev.mos(.n, 0, 1, 2).sized(1000, 300), 5e-13, 3e-6) },
    };
    for (cases) |case| {
        const written = try Circuit.init(arena, 3, &.{case[2]});
        try out.append(arena, try fx.compared(arena, case[0], &.{"LVS-060"}, case[1], &written));
    }
    const bjt_alone = try Circuit.init(arena, 3, &.{Dev.onPins(.q, &.{ 0, 1, 2 })});
    for ([_]struct { []const u8, f64 }{ .{ "exact", 1.6e-13 }, .{ "10pct_over", 1.76e-13 } }) |case| {
        const written = try Circuit.init(arena, 3, &.{Dev.onPins(.q, &.{ 0, 1, 2 }).param("ae", case[1]).param("pe", 1.6e-6)});
        try out.append(arena, try fx.compared(arena, try std.fmt.allocPrint(arena, "params/Q_ae_pe_{s}", .{case[0]}), &.{"LVS-064"}, &bjt_alone, &written));
    }
}

test "every curated LVS fixture of the second part holds" {
    // Oracle: each verdict the brute-force oracle's (`lvs_oracle.zig`) over
    // what `measured` says the drawing measures, or hand-derived where the
    // reference is edited text (the ring's 1.44 µm² and 14.4 µm above).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
