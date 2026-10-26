//! Current-density, AC, derated and self-heated electromigration on met1
//! rails: drawn rails and an intent in, each rule's findings against the
//! series ladder's edge currents, a hand-interpolated frequency-width
//! table, Black's equation with the Blech exemption and the GF180MCU
//! §14.2.2 derating table, and Banerjee's self-heating with a lognormal
//! wire out. Ported from tests/exhaustive/erc.rs (`em_current_density`,
//! `ihp_narrow_band`, `em_ac`, `GF180_TABLE_14_3`, `gf180_derating`,
//! `black_derating`, `the_gf180_derating_formula_reproduces_its_table`,
//! `electromigration`, `normal_cdf_by_simpson`, `em_thermal`), at merge
//! depth.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const testgen = @import("testgen");
const Rng = testgen.Rng;
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
const microamps = rails.microamps;
const claim = rails.claim;
const k_ev = rails.k_ev;
const t_signoff = rails.t_signoff;

/// One row of GF180MCU DRM Table 14.3: mA/µm at 85, 110 and 125 °C.
const Rated = struct { row: []const u8, at85: f64, at110: f64, at125: f64 };

/// GF180MCU DRM Table 14.3, maximum DC current per drawn width (mA/µm) at
/// 85, 110 and 125 °C: the rows the §14.2.2 formula reproduces. The two
/// `MetalTop` 11 kÅ rows (4.5/2.2/1.5 and 7/3/2.2) disagree with the formula by
/// 2-10 % and are not used.
const gf180_table_14_3 = [_]Rated{
    .{ .row = "m1_uni", .at85 = 2.09, .at110 = 1.0, .at125 = 0.67 },
    .{ .row = "m1_bi", .at85 = 3.14, .at110 = 1.5, .at125 = 1.0 },
    .{ .row = "mt6k_uni", .at85 = 3.3, .at110 = 1.6, .at125 = 1.07 },
    .{ .row = "mt6k_bi", .at85 = 5.03, .at110 = 2.4, .at125 = 1.6 },
    .{ .row = "mt9k_uni", .at85 = 3.77, .at110 = 1.8, .at125 = 1.21 },
    .{ .row = "mt9k_bi", .at85 = 5.66, .at110 = 2.7, .at125 = 1.82 },
    .{ .row = "mt30k_uni", .at85 = 16.52, .at110 = 8.01, .at125 = 5.37 },
    .{ .row = "mt30k_bi", .at85 = 24.78, .at110 = 12.02, .at125 = 8.06 },
};

/// A random series ladder on a 16 µm VDD rail: its layout, the total
/// current, each edge and each edge's current per µm of width.
const Random = struct { layout: Layout, current: f64, width: i64, edges: []const rails.Edge, per_um: []const f64 };

// ---- private ----

/// `em_current_density` (ERC-E1, E2, E3, E10, C7, D4): the limit is
/// `max_density × width` on metal and `max_current_per_cut` on a cut, no
/// derating. One 8 µm edge of width 0.2, 0.5, 1 and 2 µm carrying 1 mA,
/// swept by a density one part in a thousand either side of `1 mA / width`
/// (the narrowest without a narrow band, ERC-E3's `ihpNarrowBand`). A
/// cut carrying 1 mA swept exactly across 1000 µA. Random ladders swept
/// between every edge's `current / width`.
fn emCurrentDensity(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    try ihpNarrowBand(arena, out);
    const vdd = try rails.vddIntent(arena, 1000.0);
    for ([_]i64{ 200, 500, 1000, 2000 }) |width| {
        const per_um = 1000.0 / (@as(f64, @floatFromInt(width)) / 1000.0);
        const layout = try railLayout(arena, 20_000, width, &.{18_000});
        for ([_]f64{ per_um * 0.999, per_um * 1.001 }) |density| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_current_density/width_{d}/{s}", .{ width, side(density, per_um) }),
            .deck = try rails.rules(arena, "rule em em_current_density(met1; max_density: {d}uA/um, max_current_per_cut: 1000uA, narrow: none)", .{density}),
            .layout = layout,
            .intent = vdd,
            .expect = try claim(arena, "em", if (density < per_um) &.{at(microamps(1000.0), 10_000, @divTrunc(width, 2))} else &.{}),
        });
    }

    // A met2 pad bar over met1, one cut at 6 µm, one load on met1 at 2 µm:
    // the cut and every metal edge carry the whole 1 mA (met1 is tapped at its
    // centre, 4 µm, so it has two edges).
    var stack: Layout = .{};
    try stack.rect(arena, "met1", 0, 0, 8000, 1000);
    try stack.rect(arena, "met2", 0, 500, 8000, 1500);
    try stack.rect(arena, "via1", 5900, 650, 6100, 850);
    try stack.label(arena, "met1_text", 1000, 200, "VDD");
    try stack.label(arena, "met2_text", 1000, 1200, "VDD");
    try cf.loadAt(arena, &stack, 2000, 0);
    for ([_]f64{ 999.0, 1000.0, 1001.0 }) |per_cut| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/em_current_density/per_cut/{s}", .{side(per_cut, 1000.0)}),
        .deck = try rails.rules(arena, "rule em em_current_density(via1; max_density: 1000mA/um, max_current_per_cut: {d}uA, narrow: none)", .{per_cut}),
        .layout = stack,
        .intent = vdd,
        .expect = try claim(arena, "em", if (per_cut < 1000.0) &.{microamps(1000.0)} else &.{}),
    });
    // One row over met1 and the cut: per width on metal (999 µA/µm × 1 µm,
    // both met1 edges fail), per cut on the cut (2 mA, clean); met2 is not
    // listed and not checked.
    try out.append(arena, .{
        .name = "erc/em_current_density/metal_and_cut",
        .deck = try rails.railDeck(arena, "rule em em_current_density(met1, via1; max_density: 999uA/um, max_current_per_cut: 2000uA, narrow: none)"),
        .layout = stack,
        .intent = vdd,
        .expect = try claim(arena, "em", &.{ at(microamps(1000.0), 2000, 500), at(microamps(1000.0), 4000, 500) }),
    });

    var rng = Rng.init(0xe_0001);
    for (0..20) |case| {
        const r = try randomLadder(arena, &rng, 4900);
        for (try rails.between(arena, r.per_um)) |density| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_current_density/random/{d}/{d}", .{ case, density }),
            .deck = try rails.rules(arena, "rule em em_current_density(met1; max_density: {d}uA/um, max_current_per_cut: 1000uA, narrow: none)", .{density}),
            .layout = r.layout,
            .intent = try rails.vddIntent(arena, r.current),
            .expect = try claim(arena, "em", try over(arena, r, density)),
        });
    }
}

/// One to four loads off the feed point, a total of 100 µA plus up to
/// `spread` µA, a width of 0.5 to 2 µm: Ohm's law along the series ladder.
fn randomLadder(arena: Allocator, rng: *Rng, spread: u64) !Random {
    const n = 1 + rng.below(4);
    var loads: std.ArrayList(i64) = .empty;
    while (loads.items.len < n) {
        const x: i64 = @intCast(500 * (1 + rng.below(31)));
        if (x != 8000 and std.mem.indexOfScalar(i64, loads.items, x) == null) try loads.append(arena, x);
    }
    const current: f64 = @floatFromInt(100 + rng.below(spread));
    const width: i64 = @intCast(500 * (1 + rng.below(4)));
    const edges = (try rails.ladder(arena, 16_000, width, loads.items, current)).edges;
    const per_um = try arena.alloc(f64, edges.len);
    for (per_um, edges) |*p, e| p.* = e.current / (@as(f64, @floatFromInt(width)) / 1000.0);
    return .{ .layout = try railLayout(arena, 16_000, width, loads.items), .current = current, .width = width, .edges = edges, .per_um = per_um };
}

/// Every edge of `r` over `density` µA/µm, at its lower node.
fn over(arena: Allocator, r: Random, density: f64) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (r.edges, r.per_um) |e, p| if (p > density) try out.append(arena, at(microamps(e.current), e.a, @divTrunc(r.width, 2)));
    return out.items;
}

/// One VDD rail from 0 to `len`, `width` wide, loaded at `loads`.
fn railLayout(arena: Allocator, len: i64, width: i64, loads: []const i64) !Layout {
    var l: Layout = .{};
    try rails.rail(&l, arena, "VDD", len, 0, width, loads);
    return l;
}

/// IHP SG13G2 process specification §2.15, Metal1: IMAXM1 = 0.36 mA for "w
/// = 0.16 ... 0.36 µm" and JMAXM1 = 1 mA/µm for "w > 0.36 µm", written
/// `narrow: (width: 360nm, current: 0.36mA)` beside `max_density: 1mA/um`.
/// One rail edge carries the budget: at 0.2 µm, 300 µA is within IMAX
/// (JMAX alone would allow 200) and 400 µA is not; at the band's 0.36 µm
/// edge, 360 µA passes and 361 µA fails; at 0.4 µm the band no longer
/// applies and JMAX's 400 µA holds (390 passes, 410 fails). Without the
/// band, 300 µA on 0.2 µm fails, the over-report the band removes.
fn ihpNarrowBand(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const band = "narrow: (width: 360nm, current: 0.36mA)";
    const Case = struct { i64, f64, []const u8, bool };
    for ([_]Case{
        .{ 200, 300.0, band, false },
        .{ 200, 400.0, band, true },
        .{ 360, 360.0, band, false },
        .{ 360, 361.0, band, true },
        .{ 400, 390.0, band, false },
        .{ 400, 410.0, band, true },
        .{ 200, 300.0, "narrow: none", true },
    }) |c| {
        const width, const current, const narrow, const fails = c;
        try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_current_density/ihp_narrow/{s}/w{d}/{d}uA", .{ if (narrow.ptr == band.ptr) "band" else "no_band", width, current }),
            .deck = try rails.rules(arena, "rule em em_current_density(met1; max_density: 1mA/um, max_current_per_cut: 1000uA, {s})", .{narrow}),
            .layout = try railLayout(arena, 20_000, width, &.{18_000}),
            .intent = try rails.vddIntent(arena, current),
            .expect = try claim(arena, "em", if (fails) &.{at(microamps(current), 10_000, @divTrunc(width, 2))} else &.{}),
        });
    }
}

/// `em_rms` and `em_peak` (ERC-E7): the supply grid loaded with each net's
/// `rms_current_ua` or `peak_current_ua` in place of its budget, checked as
/// `em_current_density` checks the budget. The net's budget is 1 µA
/// throughout, so a check that read it would flag nothing.
///
/// - sky130's tech LEF RMS limit for met1, 6.1 mA/µm, on a 1 µm rail whose
///   one load draws the whole RMS current through the edge from the feed
///   point: 6093.9, 6100 and 6106.1 µA, flagged only above 6100 µA. The
///   `em_peak` row beside it is skipped: no net states a peak current.
/// - random ladders (as `em_current_density`'s), each load drawing its
///   share of a peak current, every edge's current Ohm's law along the
///   series ladder (closed form), swept between edges; `em_rms` skipped.
/// - a two-by-two table (LEF `FREQUENCY 100 300 ; WIDTH 0.5 1.5 ;
///   TABLEENTRIES 1 2 3 4` in mA/µm, values made up: no public deck has
///   one), interpolated by hand: a 1 µm rail at 200 MHz sits midway on
///   both axes, 2.5 mA/µm, so 2500 µA; a 2 µm rail at 50 MHz is past the
///   widest width and below the lowest frequency, held at 2 mA/µm, so
///   4000 µA; each swept a part in a thousand either side. With no
///   `frequency_mhz` on the net a two-frequency table cannot pick its row
///   and the row is refused.
fn emAc(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const layout = try railLayout(arena, 20_000, 1000, &.{18_000});
    for ([_]f64{ 6093.9, 6100.0, 6106.1 }) |current| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/em_rms/sky130_met1/{s}", .{side(6100.0, current)}),
        .deck = try acRows(arena, 6100.0, 1.0),
        .layout = layout,
        .intent = try acIntent(arena, "rms_current_ua", current, ""),
        .expect = try arena.dupe(Expect, &.{
            .{ .id = "rms", .findings = if (current > 6100.0) try arena.dupe(Finding, &.{at(microamps(current), 10_000, 500)}) else &.{} },
            .{ .id = "pk", .outcome = .skipped },
        }),
    });
    const table = try rails.railDeck(arena, "rule rms em_rms(met1; frequency: [100MHz, 300MHz], width: [500nm, 1500nm], density: [[1mA/um, 2mA/um], [3mA/um, 4mA/um]], max_current_per_cut: 1000uA)");
    const Case = struct { []const u8, i64, f64, f64 };
    for ([_]Case{ .{ "midway", 1000, 200.0, 2500.0 }, .{ "held", 2000, 50.0, 4000.0 } }) |c| {
        const name, const width, const frequency, const allowed = c;
        const rail = try railLayout(arena, 20_000, width, &.{18_000});
        for ([_]f64{ allowed * 0.999, allowed * 1.001 }) |current| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_rms/table/{s}/{s}", .{ name, side(allowed, current) }),
            .deck = table,
            .layout = rail,
            .intent = try acIntent(arena, "rms_current_ua", current, try std.fmt.allocPrint(arena, ",\"frequency_mhz\":{d}", .{frequency})),
            .expect = try claim(arena, "rms", if (current > allowed) &.{at(microamps(current), 10_000, @divTrunc(width, 2))} else &.{}),
        });
    }
    try out.append(arena, .{
        .name = "erc/em_rms/table/no_frequency",
        .deck = table,
        .layout = layout,
        .intent = try acIntent(arena, "rms_current_ua", 1000.0, ""),
        .expect = try arena.dupe(Expect, &.{.{ .id = "rms", .outcome = .refused }}),
    });
    var rng = Rng.init(0xe_0007);
    for (0..10) |case| {
        const r = try randomLadder(arena, &rng, 9900);
        for (try rails.between(arena, r.per_um)) |density| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_peak/random/{d}/{d}", .{ case, density }),
            .deck = try acRows(arena, 1.0, density),
            .layout = r.layout,
            .intent = try acIntent(arena, "peak_current_ua", r.current, ""),
            .expect = try arena.dupe(Expect, &.{
                .{ .id = "pk", .findings = try over(arena, r, density) },
                .{ .id = "rms", .outcome = .skipped },
            }),
        });
    }
}

/// A one-cell `em_rms` row at `rms` µA/µm and an `em_peak` row at `peak`.
fn acRows(arena: Allocator, rms: f64, peak: f64) ![]const u8 {
    return rails.rules(arena, "rule rms em_rms(met1; frequency: [100MHz], width: [0um], density: [[{d}uA/um]], max_current_per_cut: 1000uA)\nrule pk em_peak(met1; frequency: [100MHz], width: [0um], density: [[{d}uA/um]], max_current_per_cut: 1000uA)", .{ rms, peak });
}

/// VDD with a 1 µA budget and `key` (an RMS or peak current) at `current`,
/// then `extra` JSON.
fn acIntent(arena: Allocator, key: []const u8, current: f64, extra: []const u8) ![]const u8 {
    return rails.intent(arena, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"budget_current_ua\":1,\"{s}\":{d}{s}}}", .{ key, current, extra }));
}

/// GF180MCU §14.2.2: `I = I0 [exp(Ea/k (1/T - 1/T0))]^(1/n)`, with the
/// manual's own Ea = 0.7 eV, n = 2 and k = 8.62e-5 eV/K.
fn gf180Derating(t: f64, t0: f64) f64 {
    return std.math.pow(f64, @exp(0.7 / 8.62e-5 * (1.0 / t - 1.0 / t0)), 0.5);
}

/// Black's equation held at equal lifetime: the factor a limit rated at
/// `t_ref` is multiplied by at the sign-off temperature.
fn blackDerating(t_ref: f64, ea: f64, n: f64) f64 {
    return @exp(ea / (n * k_ev) * (1.0 / t_signoff - 1.0 / t_ref));
}

/// `electromigration` (ERC-E4, E5, E6): Black's derating, the Blech
/// exemption and the GF180MCU table.
///
/// - GF180MCU Table 14.3: each row rated at its 110 °C (T0) value and at its
///   125 °C value, Ea 0.7 eV, n 2, run at 85 °C on a 1 µm line: the manual's
///   85 °C column within its 1.64 % rounding, so 2 % under it passes and 2 %
///   over fails.
/// - Black: `allowed = J × W × exp(Ea / (n k) (1/T - 1/T_ref))` from this
///   file's formula, swept a part in a thousand either side, over rated
///   temperatures cooler and hotter than sign-off.
/// - Blech: `|I| L / W` at or below the limit is immortal, whatever the
///   density limit says; one µA under it is mortal.
/// - F25: the Blech length is via to line end, not tap to tap.
fn electromigration(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const line = try railLayout(arena, 20_000, 1000, &.{18_000});
    for (gf180_table_14_3) |g| {
        for ([_]struct { []const u8, f64 }{ .{ "110C", g.at110 }, .{ "125C", g.at125 } }) |r| {
            for ([_]struct { []const u8, f64 }{ .{ "below", 0.98 }, .{ "above", 1.02 } }) |s| {
                const budget = g.at85 * 1000.0 * s[1];
                try out.append(arena, try lineCase(arena, line, try std.fmt.allocPrint(arena, "erc/electromigration/gf180_table_14_3/{s}/{s}/{s}", .{ g.row, r[0], s[0] }), try emRow(arena, try std.fmt.allocPrint(arena, "{d}mA/um", .{r[1]}), "1nA", r[0], 0.7, 2.0), budget, s[1] > 1.0));
            }
        }
    }
    const Black = struct { []const u8, f64, f64, f64 };
    for ([_]Black{
        .{ "25C", 298.15, 0.7, 2.0 },
        .{ "85C", 358.15, 0.9, 2.0 },
        .{ "105C", 378.15, 0.9, 2.0 },
        .{ "125C", 398.15, 0.7, 1.0 },
        .{ "423.15K", 423.15, 0.85, 1.5 },
    }) |b| {
        const t_ref, const kelvin, const ea, const n = b;
        // 1 mA/µm over 1 µm, derated.
        const allowed = 1000.0 * blackDerating(kelvin, ea, n);
        for ([_]f64{ 0.999, 1.001 }) |factor| try out.append(arena, try lineCase(arena, line, try std.fmt.allocPrint(arena, "erc/electromigration/black/{s}_{d}eV_n{d}/{s}", .{ t_ref, ea, n, side(factor, 1.0) }), try emRow(arena, "1mA/um", "1nA", t_ref, ea, n), allowed * factor, factor > 1.0));
    }
    // With no intent temperature, the deck's `temperature` is the one Black's
    // derating reads: rated at 105 °C, run at 125 °C (398.15 K). The
    // coefficients are zero, so the rail's resistance does not move.
    const hot = try std.mem.concat(arena, u8, &.{
        "temperature 125C nominal 25C\n",
        try std.mem.replaceOwned(u8, arena, try rails.railDeck(arena, try emRow(arena, "1mA/um", "1nA", "105C", 0.9, 2.0)), " fringe_cap 1aF/um\n", " fringe_cap 1aF/um tc1 0/K tc2 0/K2\n"),
    });
    const allowed = 1000.0 * @exp(0.9 / (2.0 * k_ev) * (1.0 / 398.15 - 1.0 / 378.15));
    for ([_]f64{ 0.999, 1.001 }) |factor| {
        const budget = allowed * factor;
        try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/electromigration/deck_temperature/{s}", .{side(factor, 1.0)}),
            .deck = hot,
            .layout = line,
            .intent = try cf.intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"budget_current_ua\":{d}}}", .{budget})),
            .expect = try claim(arena, "em", if (factor > 1.0) &.{at(microamps(budget), 10_000, 500)} else &.{}),
        });
    }
    // Blech: 1 mA over an 8 µm edge 1 µm wide is 8000 µA; a 4 µm edge (load
    // at 14 µm) 4000 µA; a 2 µm-wide line 4000 µA.
    const vdd = try rails.vddIntent(arena, 1000.0);
    const Blech = struct { []const u8, i64, i64, f64 };
    for ([_]Blech{ .{ "8um", 18_000, 1000, 8000.0 }, .{ "4um", 14_000, 1000, 4000.0 }, .{ "8um_wide", 18_000, 2000, 4000.0 } }) |b| {
        const name, const load, const width, const product = b;
        const layout = try railLayout(arena, 20_000, width, &.{load});
        for ([_]f64{ product - 1.0, product, product + 1.0 }) |blech| try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/electromigration/blech/{s}/{s}", .{ name, side(blech, product) }),
            .deck = try rails.railDeck(arena, try emRow(arena, "1uA/um", try std.fmt.allocPrint(arena, "{d}uA", .{blech}), "85C", 0.9, 2.0)),
            .layout = layout,
            .intent = vdd,
            .expect = try claim(arena, "em", if (blech < product) &.{at(microamps(1000.0), 10_000, @divTrunc(width, 2))} else &.{}),
        });
    }
    // F25: a met1 line from a via at 0.5 µm (under the met2 pad) to its end
    // at 18 µm, loaded at 17.5 µm. The line between its diffusion barriers
    // carries 1 mA over 17 µm: a Blech product of at least 17 000 µA, mortal
    // against a 10 000 µA limit, and far over a 1 µA/µm density. Tapped at
    // its centre the line once read two 8.5 µm segments of 8500 µA, each
    // called immortal, and nothing was reported.
    var f25: Layout = .{};
    try f25.rect(arena, "met1", 0, 0, 18_000, 1000);
    try f25.rect(arena, "met2", 0, 0, 1000, 1000);
    try f25.rect(arena, "via1", 400, 400, 600, 600);
    try f25.label(arena, "met1_text", 9000, 500, "VDD");
    try cf.loadAt(arena, &f25, 17_500, 0);
    // Both segments (via to centre tap, centre tap to the load) are mortal
    // and over 1 µA, reported at their first nodes.
    const mortal = [_]Finding{ at(microamps(1000.0), 500, 500), at(microamps(1000.0), 9000, 500) };
    // The Rust fixture claims only that the run fails; the findings are the
    // ones `line_product` derives below its 17 000 µA product.
    try out.append(arena, .{
        .name = "erc/electromigration/f25/via_to_line_end",
        .deck = try rails.railDeck(arena, try emRow(arena, "1uA/um", "10000uA", "85C", 0.9, 2.0)),
        .layout = f25,
        .intent = vdd,
        .expect = try claim(arena, "em", &mortal),
    });
    // The same line swept across its Blech product, 1000 µA × 17 µm / 1 µm =
    // 17 000 µA: below it both segments (via to centre tap, centre tap to the
    // load) are mortal and over 1 µA, reported at their first nodes; at or
    // above it the whole line is immortal.
    for ([_]f64{ 16_999.0, 17_000.0, 17_001.0 }) |blech| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/electromigration/f25/line_product/{s}", .{side(blech, 17_000.0)}),
        .deck = try rails.railDeck(arena, try emRow(arena, "1uA/um", try std.fmt.allocPrint(arena, "{d}uA", .{blech}), "85C", 0.9, 2.0)),
        .layout = f25,
        .intent = vdd,
        .expect = try claim(arena, "em", if (blech < 17_000.0) &mortal else &.{}),
    });
}

/// An `electromigration` row on met1.
fn emRow(arena: Allocator, density: []const u8, blech: []const u8, t_ref: []const u8, ea: f64, n: f64) ![]const u8 {
    return std.fmt.allocPrint(arena, "rule em electromigration(met1; max_density: {s}, max_current_per_cut: 1000uA, blech_limit: {s}, reference_temperature: {s}, activation_energy: {d}eV, current_exponent: {d})", .{ density, blech, t_ref, ea, n });
}

/// The 1 µm line carrying `budget`, flagged at its feed edge when `flagged`.
fn lineCase(arena: Allocator, line: Layout, name: []const u8, row: []const u8, budget: f64, flagged: bool) !Fixture {
    return .{
        .name = name,
        .deck = try rails.railDeck(arena, row),
        .layout = line,
        .intent = try rails.vddIntent(arena, budget),
        .expect = try claim(arena, "em", if (flagged) &.{at(microamps(budget), 10_000, 500)} else &.{}),
    };
}

/// `Φ(z)` for `z < 0` by composite Simpson's rule on the normal density over
/// `[z - 12, z]`, 20 000 panels: the definition, integrated, independent of
/// the engine's series and continued fraction.
fn normalCdfBySimpson(z: f64) f64 {
    const a = z - 12.0;
    const n: u32 = 20_000;
    const h = (z - a) / @as(f64, @floatFromInt(n));
    var sum = normalDensity(a) + normalDensity(z);
    for (1..n) |i| {
        const weight: f64 = if (i % 2 == 1) 4.0 else 2.0;
        sum += weight * normalDensity(a + h * @as(f64, @floatFromInt(i)));
    }
    return sum * h / 3.0;
}

fn normalDensity(t: f64) f64 {
    return @exp(-0.5 * t * t) / @sqrt(2.0 * std.math.pi);
}

/// `em_thermal` (ERC-E13) on the one-load rail: the 8 µm × 1 µm met1 segment
/// (1 Ω) 100 nm above the substrate, `K` 0.05 W/(m·K), spreading 0.88, rated
/// 10 mA/µm at 125 °C (Ea 0.9 eV, n 2), the run at the intent's 105 °C.
///
/// - Self-heating (Banerjee 1999): `ΔT = I² R t / (K L (W + φ t))`, so the
///   segment fails above the current `I*` that solves
///   `I = 10 mA × exp(Ea / (n k) (1/(T + ΔT(I)) - 1/T_ref))`, found here by
///   bisection: a budget a part in a thousand under it passes, one over is
///   flagged at that current, under every placement.
/// - Statistics: at 90 % of `I*` the wire carries `u` of its self-heated limit
///   and fails with probability `Φ(z_0.1% + (n / σ) ln u)`, the normal
///   distribution integrated here by Simpson's rule; a chip budget a part in
///   a million under that is flagged once, measured at it; one over passes.
fn emThermal(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const n = 2.0;
    const threshold = blk: {
        var lo: f64 = 0.0;
        var hi: f64 = 1e6;
        for (0..200) |_| {
            const mid = 0.5 * (lo + hi);
            if (mid > thermalAllowed(mid)) hi = mid else lo = mid;
        }
        break :blk 0.5 * (lo + hi);
    };
    const layout = try railLayout(arena, 20_000, 1000, &.{18_000});
    for ([_]f64{ 0.999, 1.001 }) |factor| {
        const budget = threshold * factor;
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_thermal/self_heating/{s}", .{side(factor, 1.0)}),
            .deck = try thermalRow(arena, 1.0),
            .layout = layout,
            .intent = try warm(arena, budget),
            // The segment's first node is whichever end the chain orders
            // first, so the marker moves between its ends with the
            // placement; the chip case below pins it unrotated.
            .expect = try claim(arena, "hot", if (factor > 1.0) &.{microamps(budget)} else &.{}),
        });
    }
    const budget = 0.9 * threshold;
    const usage = budget / thermalAllowed(budget);
    const failed = normalCdfBySimpson(-3.090_232_306_167_813 + n / 0.5 * @log(usage));
    for ([_]f64{ 1.0 - 1e-6, 1.0 + 1e-6 }) |factor| {
        const chip_budget = failed * factor;
        try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/em_thermal/chip/{s}", .{side(chip_budget, failed)}),
            .deck = try thermalRow(arena, chip_budget),
            .layout = layout,
            .intent = try warm(arena, budget),
            .expect = try claim(arena, "hot", if (chip_budget < failed) &.{at(pc.ratio(failed), 10_000, 500)} else &.{}),
        });
    }
}

/// The self-heated allowed current at `current` µA: 10 mA/µm rated at
/// 125 °C, run at 105 °C plus `R θ I²` (1 Ω, t = 100 nm, L = 8 µm, W = 1 µm).
fn thermalAllowed(current: f64) f64 {
    const run = 105.0 + 273.15;
    const t_ref = 125.0 + 273.15;
    const t = 100e-9;
    const heat = 1.0 * t / (0.05 * 8e-6 * (1e-6 + 0.88 * t)) * 1e-12;
    return 10_000.0 * @exp(0.9 / (2.0 * k_ev) * (1.0 / (run + heat * current * current) - 1.0 / t_ref));
}

fn thermalRow(arena: Allocator, max_failure: f64) ![]const u8 {
    return rails.rules(arena, "rule hot em_thermal(met1; max_density: 10mA/um, max_current_per_cut: 1mA, blech_limit: 1nA, reference_temperature: 125C, activation_energy: 0.9eV, current_exponent: 2, thermal_conductivity: 0.05W/mK, spreading: 0.88, sigma: 0.5, limit_failure: 0.1%, max_failure: {d})", .{max_failure});
}

/// `vddIntent(budget)` at 105 °C.
fn warm(arena: Allocator, budget: f64) ![]const u8 {
    const text = try cf.intentOf(arena, 1800.0, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"budget_current_ua\":{d}}}", .{budget}));
    return std.mem.concat(arena, u8, &.{ "{\"temperature_c\":105,", text[1..] });
}

// Oracle: the limit `max_density × width` on metal and `max_current_per_cut`
// on a cut: 1 mA on widths 0.2 to 2 µm swept a part in a thousand around
// `1 mA / width`; IHP SG13G2 §2.15's IMAXM1 narrow band against JMAXM1; a
// cut swept across 1000 µA; random ladders' edge currents by Ohm's law,
// swept between every edge's `current / width`.
test "em current density holds each edge to its width and each cut to its count" {
    try rails.checkGroup(emCurrentDensity);
}

// Oracle: `em_current_density`'s closed form on the RMS or peak current in
// place of the budget: sky130's 6.1 mA/µm met1 limit swept at 6100 µA;
// random ladders' edge currents; a two-by-two frequency-width table
// interpolated by hand (2500 µA midway, 4000 µA held past both edges), and
// refused without a frequency.
test "em rms and peak load the grid with their own current" {
    try rails.checkGroup(emAc);
}

// Oracle: foundry example. GF180MCU's own Table 14.3: the §14.2.2 formula must
// reproduce its 85 C column from the 110 C and 125 C columns within the
// table's rounding.
test "the gf180 derating formula reproduces its table" {
    const t85 = 358.15;
    const t110 = 383.15;
    const t125 = 398.15;
    for (gf180_table_14_3) |g| {
        // 85 °C from 110 °C (T0) and from 125 °C, and 125 °C from T0.
        for ([_][2]f64{
            .{ g.at110 * gf180Derating(t85, t110), g.at85 },
            .{ g.at125 * gf180Derating(t85, t125), g.at85 },
            .{ g.at110 * gf180Derating(t125, t110), g.at125 },
        }) |pair| try testing.expect(@abs(pair[0] / pair[1] - 1.0) < 0.0165);
    }
}

// Oracle: Black's equation `J × W × exp(Ea / (n k) (1/T - 1/T_ref))` swept a
// part in a thousand either side; GF180MCU Table 14.3's 85 °C column, 2 %
// either side, from its 110 °C and 125 °C ratings; the Blech product
// `|I| L / W` immortal at or below its limit; F25's via-to-line-end length.
test "electromigration derates by black and exempts by blech" {
    try rails.checkGroup(electromigration);
}

// Oracle: Banerjee's self-heating `ΔT = I² R t / (K L (W + φ t))` solved for
// the failing current by bisection, swept a part in a thousand; the chip's
// failure `Φ(z_0.1% + (n / σ) ln u)` at 90 % of it, integrated by Simpson's
// rule, swept a part in a million.
test "em thermal fails a self-heated wire and a lognormal chip" {
    try rails.checkGroup(emThermal);
}
