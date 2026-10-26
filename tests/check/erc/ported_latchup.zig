//! The named latch-up circuits against GF180MCU's rules: guard-ring bias,
//! tie area, guard rings (pad, double, native, clear), forward diodes,
//! conditional ties and latch-up victims (by distance, pad and voltage);
//! and `mixed_tag`. Each placed three ways. Ported from
//! crates/check/tests/erc/ported.rs (`ring_on`, `guard_ring_bias`,
//! `tie_area`, `ring_round`, `guard_ring`, `double_ring`, `native_ring`,
//! `native_clear`, `forward_diode`, `conditional_tie`, `latchup_victim`,
//! `voltage_aggressor`, `TAG_DECK`, `mixed_tag`; the latch-up part of
//! `esd_domains_and_latchup_rows_report_their_derived_findings` and the
//! `mixed_tag` part of `voltage_spacing_tags_and_fields_report_their_derived_findings`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const pc = @import("ported_circuit.zig");
const Rect = pc.Rect;
const count = pc.count;
const length = pc.length;
const ratio = pc.ratio;
const millivolts = pc.millivolts;
const rect = pc.rect;
const riser = pc.riser;
const gpa = std.testing.allocator;

const domain_nets = &pc.domain_nets;

/// The sky130 voltage-tag process: diffusion, poly and two metals, a
/// switch, a met1 resistor and the `hvi` tag layer.
const tag_deck =
    \\grid 1nm
    \\layer diff = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer mk = gds(3, 0)
    \\layer mks = gds(4, 0)
    \\layer cont = gds(5, 0)
    \\layer pcont = gds(6, 0)
    \\layer met1 = gds(7, 0)
    \\layer m1txt = gds(7, 1)
    \\layer met2 = gds(8, 0)
    \\layer v1 = gds(9, 0)
    \\layer res = gds(10, 0)
    \\layer hvi = gds(11, 0)
    \\connect conductors [diff, poly, met1, met2]
    \\connect touch_within_layer
    \\connect via cont [diff, met1]
    \\connect via pcont [poly, met1]
    \\connect via v1 [met1, met2]
    \\connect label m1txt names met1
    \\device mos mk model "n" terminals [poly, diff, diff]
    \\device mos mks model "sw" terminals [poly, diff, diff] on_gate_min 1V
    \\device resistor res model "r" terminals [met1, met1]
    \\rule hvt hv_tag(met1, hvi; voltage: 3V)
    \\rule mix mixed_tag(met1, hvi)
    \\
;

// ---- private ----

fn expect1(arena: Allocator, id: []const u8, findings: []const Finding) ![]const Expect {
    return arena.dupe(Expect, &.{.{ .id = id, .findings = findings }});
}

/// A guard ring drawn on `layer` as four bars, wired by a riser to the
/// track of `net`, beside the domain nets' tracks.
fn ringOn(arena: Allocator, layer: []const u8, net: usize) !Layout {
    var l = try pc.circuit(arena, domain_nets, &.{}, &.{});
    for ([_]Rect{ .{ -1000, 0, 1000, 400 }, .{ -1000, 1600, 1000, 2000 }, .{ -1000, 400, -600, 1600 }, .{ 600, 400, 1000, 1600 } }) |bar| try rect(&l, arena, layer, bar);
    try riser(&l, arena, -200, 1600, net);
    return l;
}

/// `guard_ring_bias` (ERC-D3, GF180MCU LU.9, LU.10, IO.1 (a2), IO.3 (a2)):
/// an n-tap ring must sit on the most positive supply, a p-tap ring on a
/// ground. Each ring is four polygons, so a ring on the wrong net is four
/// findings: on a supply, its voltage against the one it needs; off every
/// supply, a count of 0. With domain `d2` at 3.3 V, VDD1 (1.8 V) is no
/// longer the most positive supply.
fn guardRingBias(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vdd1, const vss1, const vdd2, const vss2, const sig = .{ 0, 1, 2, 3, 5 };
    const deck = pc.diode_process ++
        \\rule gn guard_ring_bias(ntap; power: true)
        \\rule gp guard_ring_bias(ptap; power: false)
        \\
    ;
    const domains = try pc.domainIntent(arena);
    const high = try pc.intentText(arena, &.{ .{ .name = "d1", .mv = 1800 }, .{ .name = "d2", .mv = 3300 }, .{ .name = "d3", .mv = 1800 } }, &.{
        .{ "VDD1", "d1", "power" },
        .{ "VSS1", "d1", "ground" },
        .{ "VDD2", "d2", "power" },
        .{ "VSS2", "d2", "ground" },
        .{ "VSS3", "d3", "ground" },
    });
    const Case = struct { name: []const u8, layer: []const u8, net: usize, intent: []const u8, n: bool, four: ?Finding };
    const cases = [_]Case{
        .{ .name = "n_on_vdd1", .layer = "ntap", .net = vdd1, .intent = domains, .n = true, .four = null },
        .{ .name = "n_on_vss1", .layer = "ntap", .net = vss1, .intent = domains, .n = true, .four = millivolts(0) },
        .{ .name = "n_on_sig", .layer = "ntap", .net = sig, .intent = domains, .n = true, .four = count(0) },
        .{ .name = "n_on_vdd1_low", .layer = "ntap", .net = vdd1, .intent = high, .n = true, .four = millivolts(1800) },
        .{ .name = "n_on_vdd2_high", .layer = "ntap", .net = vdd2, .intent = high, .n = true, .four = null },
        .{ .name = "p_on_vss2", .layer = "ptap", .net = vss2, .intent = domains, .n = false, .four = null },
        .{ .name = "p_on_vdd2", .layer = "ptap", .net = vdd2, .intent = domains, .n = false, .four = millivolts(1800) },
        .{ .name = "p_on_sig", .layer = "ptap", .net = sig, .intent = domains, .n = false, .four = count(0) },
    };
    for (cases) |cs| {
        const findings: []const Finding = if (cs.four) |f| try pc.repeat(arena, f, 4) else &.{};
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/guard_ring_bias/{s}", .{cs.name}),
            .deck = deck,
            .layout = try ringOn(arena, cs.layer, cs.net),
            .intent = cs.intent,
            .expect = try arena.dupe(Expect, &.{
                .{ .id = if (cs.n) "gn" else "gp", .findings = findings },
                .{ .id = if (cs.n) "gp" else "gn" },
            }),
        });
    }
}

/// `tie_area` (ERC-D1b, GF180MCU LU.7 and IO.2/IO.4) on marker layers: a
/// 10 µm well holds two 1 × 2 µm gates (4 µm² of channel) and three 200 nm
/// contacts (0.12 µm²); a fourth contact half outside the well adds only
/// its inside half (0.02 µm²), and two overlapping contacts their union
/// (0.06 µm²): 0.2 µm², a ratio of 5% exactly, swept below, at and above.
/// A second well holds a gate and no contact (ratio 0), a third a contact
/// and no gate (not examined). A guard ring 1 µm wide round a 4 µm hole
/// (20 µm² of ring) with ten 200 nm contacts on it: 2%, against IO.2's 5%.
fn tieArea(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var l: Layout = .{};
    try rect(&l, arena, "well", .{ 0, 0, 10_000, 10_000 });
    try rect(&l, arena, "gate", .{ 1000, 1000, 2000, 3000 });
    try rect(&l, arena, "gate", .{ 4000, 1000, 5000, 3000 });
    for ([_]i64{ 6000, 7000, 8000 }) |x| try rect(&l, arena, "cont", .{ x, 6000, x + 200, 6200 });
    // Half outside the well, and an overlapping pair whose union is 300 x 200.
    try rect(&l, arena, "cont", .{ 9900, 8000, 10_100, 8200 });
    try rect(&l, arena, "cont", .{ 2000, 8000, 2200, 8200 });
    try rect(&l, arena, "cont", .{ 2100, 8000, 2300, 8200 });
    // 0.12 + 0.02 + 0.06 = 0.2 µm² against 4 µm²: 5%.
    const value = 0.05;
    try rect(&l, arena, "well", .{ 20_000, 0, 30_000, 10_000 });
    try rect(&l, arena, "gate", .{ 21_000, 1000, 22_000, 3000 });
    try rect(&l, arena, "well", .{ 40_000, 0, 50_000, 10_000 });
    try rect(&l, arena, "cont", .{ 41_000, 1000, 41_200, 1200 });
    for ([_]Rect{ .{ 60_000, 0, 66_000, 1000 }, .{ 60_000, 5000, 66_000, 6000 }, .{ 60_000, 1000, 61_000, 5000 }, .{ 65_000, 1000, 66_000, 5000 } }) |bar| try rect(&l, arena, "ring", bar);
    for (0..10) |k| {
        const x = 60_100 + 500 * @as(i64, @intCast(k));
        try rect(&l, arena, "cont", .{ x, 200, x + 200, 400 });
    }
    for (pc.sweep(value)) |min_ratio| {
        const findings: []const Finding = if (min_ratio > value) &.{ ratio(0), ratio(value) } else &.{ratio(0)};
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/tie_area/{s}", .{pc.side(min_ratio, value)}),
            .deck = try std.fmt.allocPrint(arena,
                \\grid 1nm
                \\layer well = gds(1, 0)
                \\layer cont = gds(2, 0)
                \\layer gate = gds(3, 0)
                \\layer ring = gds(4, 0)
                \\rule ta tie_area(well, cont, gate; min_ratio: {d})
                \\rule tr tie_area(ring, cont, ring; min_ratio: 5%)
                \\
            , .{min_ratio}),
            .layout = l,
            .expect = try arena.dupe(Expect, &.{
                .{ .id = "ta", .findings = findings },
                .{ .id = "tr", .findings = &.{ratio(0.02)} },
            }),
        });
    }
}

/// A closed ring of band `band` on `layer` round the box `hole`: four bars
/// that merge into one figure with that hole.
fn ringRound(l: *Layout, arena: Allocator, layer: []const u8, hole: Rect, band: i64) !void {
    const x0, const y0, const x1, const y1 = hole;
    for ([_]Rect{ .{ x0 - band, y0 - band, x1 + band, y0 }, .{ x0 - band, y1, x1 + band, y1 + band }, .{ x0 - band, y0, x0, y1 }, .{ x1, y0, x1 + band, y1 } }) |bar| try rect(l, arena, layer, bar);
}

/// A diffusion on `net` (riser-wired), a pad on SIG, and a ring `gap` round
/// the diffusion, `band` wide, closed or open on its right.
fn padRingBoard(arena: Allocator, net: usize, gap: i64, band: i64, closed: bool) !Layout {
    const pad_net = 5;
    const target: Rect = .{ 0, -6000, 2000, -5000 };
    var l = try pc.circuit(arena, domain_nets, &.{}, &.{});
    try rect(&l, arena, "diff", target);
    try riser(&l, arena, 900, -5900, net);
    const ty = pc.trackY(pad_net);
    try rect(&l, arena, "pad", .{ -1000, ty, -400, ty + pc.track_h });
    try rect(&l, arena, "padv", .{ -800, ty + 150, -600, ty + 250 });
    const hole: Rect = .{ target[0] - gap, target[1] - gap, target[2] + gap, target[3] + gap };
    if (closed) {
        try ringRound(&l, arena, "ring", hole, band);
    } else {
        // The right bar left out: a C open on one side.
        const hx0, const hy0, const hx1, const hy1 = hole;
        try rect(&l, arena, "ring", .{ hx0 - band, hy0 - band, hx1 + band, hy0 });
        try rect(&l, arena, "ring", .{ hx0 - band, hy1, hx1 + band, hy1 + band });
        try rect(&l, arena, "ring", .{ hx0 - band, hy0, hx0, hy1 });
    }
    return l;
}

/// `guard_ring` (ERC-D2, GF180MCU IO.1 (a2) and IO.2): a 2 × 1 µm
/// diffusion on a net carrying a pad must sit in a closed `ring` no more
/// than 15 µm from it and at least 2 µm wide; space and width swept a
/// nanometre either side. A C-shaped ring surrounds nothing; a diffusion on
/// a net with no pad is not selected.
fn guardRing(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const pad_net, const other = .{ 5, 6 };
    const deck = pc.diode_process ++
        \\rule gr guard_ring(diff, ring; max_space: 15um, min_width: 2um, pad: pad, near: none, within: none, clear: none)
        \\
    ;
    const Case = struct { name: []const u8, layout: Layout, findings: []const Finding };
    var cases: std.ArrayList(Case) = .empty;
    for ([_]i64{ 14_999, 15_000, 15_001 }) |gap| try cases.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "space/{s}", .{pc.side(15_000, @floatFromInt(gap))}),
        .layout = try padRingBoard(arena, pad_net, gap, 2000, true),
        .findings = if (gap > 15_000) try arena.dupe(Finding, &.{length(gap)}) else &.{},
    });
    for ([_]i64{ 1999, 2000, 2001 }) |band| try cases.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "width/{s}", .{pc.side(2000, @floatFromInt(band))}),
        .layout = try padRingBoard(arena, pad_net, 10_000, band, true),
        .findings = if (band < 2000) try arena.dupe(Finding, &.{length(band)}) else &.{},
    });
    try cases.append(arena, .{ .name = "open_ring", .layout = try padRingBoard(arena, pad_net, 10_000, 2000, false), .findings = &.{count(0)} });
    try cases.append(arena, .{ .name = "no_pad", .layout = try padRingBoard(arena, other, 10_000, 2000, false), .findings = &.{} });
    for (cases.items) |cs| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/guard_ring/{s}", .{cs.name}),
        .deck = deck,
        .layout = cs.layout,
        .expect = try expect1(arena, "gr", cs.findings),
    });
    try nativeRing(arena, out);
    try nativeClear(arena, out);
    try doubleRing(arena, out);
}

/// `guard_ring` for GF180MCU §14.3.4 (ERC-D6): a high-voltage device `hv`
/// inside an n-well ring inside a p-substrate ring, two rows. Both rings
/// drawn: clean; the outer one left out: the p-ring row finds the device
/// unsurrounded.
fn doubleRing(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer hv = gds(1, 0)
        \\layer nring = gds(2, 0)
        \\layer pring = gds(3, 0)
        \\rule dn guard_ring(hv, nring; max_space: none, min_width: none, pad: none, near: none, within: none, clear: none)
        \\rule dp guard_ring(hv, pring; max_space: none, min_width: none, pad: none, near: none, within: none, clear: none)
        \\
    ;
    for ([_]bool{ true, false }) |outer| {
        var l: Layout = .{};
        try rect(&l, arena, "hv", .{ 0, 0, 4000, 4000 });
        try ringRound(&l, arena, "nring", .{ -1000, -1000, 5000, 5000 }, 1000);
        if (outer) try ringRound(&l, arena, "pring", .{ -3000, -3000, 7000, 7000 }, 1000);
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/guard_ring/double/{}", .{outer}),
            .deck = deck,
            .layout = l,
            .expect = try arena.dupe(Expect, &.{
                .{ .id = "dn" },
                .{ .id = "dp", .findings = if (outer) &.{} else &.{count(0)} },
            }),
        });
    }
}

/// `guard_ring` for GF180MCU LU.5 (ERC-D7): a native device (`nat`) with an
/// n-well within 50 µm must sit in a closed p-substrate ring. The well is
/// `gap` to the right of the device, swept about 50 µm; with a ring the
/// device is clean whatever the well.
fn nativeRing(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer nat = gds(1, 0)
        \\layer well = gds(2, 0)
        \\layer ring = gds(3, 0)
        \\rule lu5 guard_ring(nat, ring; max_space: none, min_width: none, pad: none, near: well, within: 50um, clear: none)
        \\
    ;
    const Case = struct { gap: i64, ringed: bool };
    for ([_]Case{ .{ .gap = 49_999, .ringed = false }, .{ .gap = 50_000, .ringed = false }, .{ .gap = 50_001, .ringed = false }, .{ .gap = 1000, .ringed = true } }) |cs| {
        var l: Layout = .{};
        try rect(&l, arena, "nat", .{ 0, 0, 2000, 2000 });
        try rect(&l, arena, "well", .{ 2000 + cs.gap, 0, 6000 + cs.gap, 4000 });
        if (cs.ringed) try ringRound(&l, arena, "ring", .{ -200, -200, 2200, 2200 }, 300);
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/guard_ring/native/{d}_{}", .{ cs.gap, cs.ringed }),
            .deck = deck,
            .layout = l,
            .expect = try expect1(arena, "lu5", if (cs.gap <= 50_000 and !cs.ringed) &.{count(0)} else &.{}),
        });
    }
}

/// `guard_ring` with `clear` for GF180MCU LU.5's "No other NCOMP, NWELL in
/// between the NAT and PCOMP guard ring" (ERC-D7): `clear` is the derived
/// `ncomp or well`. The ring's hole is (-200, -200)-(2200, 2200) round a
/// NAT at (0, 0)-(2000, 2000), its band 300 wide; the near well sits 1 µm
/// right of the ring. Hand-derived: a clear figure counts when it has area
/// in the hole outside the NAT, so an NCOMP inside the NAT, or one lying
/// on the ring's band, is clean, and one in the gap, one straddling the
/// NAT's edge into the gap, or a well island in the gap each count once.
fn nativeClear(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer nat = gds(1, 0)
        \\layer well = gds(2, 0)
        \\layer ring = gds(3, 0)
        \\layer ncomp = gds(4, 0)
        \\layer between = ncomp or well
        \\rule lu5 guard_ring(nat, ring; max_space: none, min_width: none, pad: none, near: well, within: 50um, clear: between)
        \\
    ;
    const Extra = struct { layer: []const u8, r: Rect };
    const Case = struct { name: []const u8, extra: []const Extra, between: u32 };
    const cases = [_]Case{
        .{ .name = "empty", .extra = &.{}, .between = 0 },
        .{ .name = "ncomp_in_nat", .extra = &.{.{ .layer = "ncomp", .r = .{ 500, 500, 1500, 1500 } }}, .between = 0 },
        .{ .name = "ncomp_on_ring", .extra = &.{.{ .layer = "ncomp", .r = .{ -450, 0, -250, 200 } }}, .between = 0 },
        .{ .name = "ncomp_in_gap", .extra = &.{.{ .layer = "ncomp", .r = .{ 2050, 0, 2150, 100 } }}, .between = 1 },
        .{ .name = "ncomp_straddles_nat", .extra = &.{.{ .layer = "ncomp", .r = .{ 1900, 500, 2100, 600 } }}, .between = 1 },
        .{ .name = "well_in_gap", .extra = &.{.{ .layer = "well", .r = .{ 0, 2050, 100, 2150 } }}, .between = 1 },
        .{ .name = "two_in_gap", .extra = &.{ .{ .layer = "ncomp", .r = .{ 2050, 0, 2150, 100 } }, .{ .layer = "ncomp", .r = .{ -150, 0, -50, 100 } } }, .between = 2 },
    };
    for (cases) |cs| {
        var l: Layout = .{};
        try rect(&l, arena, "nat", .{ 0, 0, 2000, 2000 });
        try rect(&l, arena, "well", .{ 3500, 0, 7500, 4000 });
        try ringRound(&l, arena, "ring", .{ -200, -200, 2200, 2200 }, 300);
        for (cs.extra) |e| try rect(&l, arena, e.layer, e.r);
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/guard_ring/native_clear/{s}", .{cs.name}),
            .deck = deck,
            .layout = l,
            .expect = try expect1(arena, "lu5", if (cs.between > 0) try arena.dupe(Finding, &.{count(cs.between)}) else &.{}),
        });
    }
}

/// `forward_diode` (ERC-D8, GF180MCU §14.3.3) with the `iso` layer as
/// `Latchup_MK`: a `dio` diode is forward-biased when its anode can sit
/// above its cathode. Anode on VDD1, cathode on VSS1: 1800 mV forward,
/// flagged unless `iso` covers it; the other way round, clean. Anode on
/// SIG, which a PMOS joins to VDD1 (0 to 1.8 V): 1800 mV. An anode on OUT,
/// which only its own cathode's ground reaches, is never forward-biased.
fn forwardDiode(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const vdd1, const vss1, const vss3, const sig, const out_net = .{ 0, 1, 4, 5, 6 };
    const deck = pc.diode_process ++ "rule fd forward_diode(iso; models: [\"dio\"])\n";
    const pmos = [_]pc.Dev{pc.dev(.pfet, vss3, vdd1, sig)};
    const Case = struct { name: []const u8, diode: [2]usize, marked: bool, findings: []const Finding };
    const cases = [_]Case{
        .{ .name = "vdd_to_vss", .diode = .{ vdd1, vss1 }, .marked = false, .findings = &.{millivolts(1800)} },
        .{ .name = "vdd_to_vss_marked", .diode = .{ vdd1, vss1 }, .marked = true, .findings = &.{} },
        .{ .name = "vss_to_vdd", .diode = .{ vss1, vdd1 }, .marked = false, .findings = &.{} },
        .{ .name = "signal_to_vss", .diode = .{ sig, vss1 }, .marked = false, .findings = &.{millivolts(1800)} },
        .{ .name = "grounded_anode", .diode = .{ out_net, vss1 }, .marked = false, .findings = &.{} },
    };
    for (cases) |cs| {
        var l = try pc.circuit(arena, domain_nets, &pmos, &.{cs.diode});
        // The diode column follows the one transistor's.
        if (cs.marked) try rect(&l, arena, "iso", .{ pc.pitch + 800, 300, pc.pitch + 1400, 700 });
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/forward_diode/{s}", .{cs.name}),
            .deck = deck,
            .layout = l,
            .intent = try pc.domainIntent(arena),
            .expect = try expect1(arena, "fd", cs.findings),
        });
    }
}

/// A PCOMP strip from x 0 to `reach` tapped at its left end, an n-well
/// round it with its top edge at y 3 µm, and an NCOMP `y` above that edge
/// (60 µm past the strip when `far`).
fn tieBoard(arena: Allocator, reach: i64, y: i64, far: bool) !Layout {
    var l: Layout = .{};
    try rect(&l, arena, "tap", .{ -1000, 0, 0, 1000 });
    try rect(&l, arena, "pc", .{ 0, 0, reach, 1000 });
    try rect(&l, arena, "nw", .{ -2000, -2000, reach + 2000, 3000 });
    const x0: i64 = if (far) reach + 60_000 else 0;
    try rect(&l, arena, "nc", .{ x0, 3000 + y, x0 + 1000, 4000 + y });
    return l;
}

/// `conditional_tie` (ERC-D1a) as GF180MCU LU.4 for LV devices: the
/// strip's furthest point is exactly `reach` from the tap; the NCOMP is
/// 2 µm + `y` from the strip, within 50 µm. `y` below 1 µm allows 15 µm,
/// from 1 µm to below 2 µm 30 µm, from 2 µm 50 µm. Each limit swept a
/// nanometre either side, the thresholds tested on the band edge, and an
/// NCOMP beyond 50 µm leaves the loosest band.
fn conditionalTie(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer pc = gds(1, 0)
        \\layer tap = gds(2, 0)
        \\layer nw = gds(3, 0)
        \\layer nc = gds(4, 0)
        \\rule lu4 conditional_tie(pc, tap, nw, nc; within: 50um, spacing: [1um, 2um], max_distance: [15um, 30um, 50um])
        \\
    ;
    const Case = struct { name: []const u8, layout: Layout, reach: i64, limit: i64 };
    var cases: std.ArrayList(Case) = .empty;
    for ([_][2]i64{ .{ 500, 15_000 }, .{ 1500, 30_000 }, .{ 2500, 50_000 } }) |band| {
        const y, const limit = band;
        for ([_]i64{ limit - 1, limit, limit + 1 }) |reach| try cases.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "y{d}/{d}", .{ y, reach }),
            .layout = try tieBoard(arena, reach, y, false),
            .reach = reach,
            .limit = limit,
        });
    }
    try cases.append(arena, .{ .name = "edge_1um", .layout = try tieBoard(arena, 30_001, 1000, false), .reach = 30_001, .limit = 30_000 });
    try cases.append(arena, .{ .name = "edge_2um", .layout = try tieBoard(arena, 30_001, 2000, false), .reach = 30_001, .limit = 50_000 });
    try cases.append(arena, .{ .name = "far", .layout = try tieBoard(arena, 30_001, 500, true), .reach = 30_001, .limit = 50_000 });
    for (cases.items) |cs| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/conditional_tie/{s}", .{cs.name}),
        .deck = deck,
        .layout = cs.layout,
        .expect = try expect1(arena, "lu4", if (cs.reach > cs.limit) try arena.dupe(Finding, &.{length(cs.reach)}) else &.{}),
    });
}

/// `latchup_victim` (ERC-D5) as GF180MCU IO.1 (b): a PCOMP strip `pv` of
/// length `reach`, tapped only at its far end, `gap` from an aggressor
/// NCOMP `agg`. Within 15 µm (inclusive) it is a victim held to 2 µm, swept
/// a nanometre either side; 15 µm + 1 nm away it is not examined. With
/// `pad`, the same diffusion is an aggressor only on a net that carries a
/// pad.
fn latchupVictim(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck =
        \\grid 1nm
        \\layer agg = gds(1, 0)
        \\layer pv = gds(2, 0)
        \\layer tap = gds(3, 0)
        \\rule io1 latchup_victim(agg, pv, tap; within: 15um, max_distance: 2um, pad: none, bias: none, forward: none)
        \\
    ;
    const Case = struct { gap: i64, reach: i64, flagged: bool };
    for ([_]Case{ .{ .gap = 15_000, .reach = 1999, .flagged = false }, .{ .gap = 15_000, .reach = 2000, .flagged = false }, .{ .gap = 15_000, .reach = 2001, .flagged = true }, .{ .gap = 15_001, .reach = 2001, .flagged = false } }) |cs| {
        var l: Layout = .{};
        try rect(&l, arena, "agg", .{ 0, 0, 1000, 1000 });
        const x0 = 1000 + cs.gap;
        try rect(&l, arena, "pv", .{ x0, 0, x0 + cs.reach, 1000 });
        try rect(&l, arena, "tap", .{ x0 + cs.reach, 0, x0 + cs.reach + 500, 1000 });
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/latchup_victim/{d}/{d}", .{ cs.gap, cs.reach }),
            .deck = deck,
            .layout = l,
            .expect = try expect1(arena, "io1", if (cs.flagged) try arena.dupe(Finding, &.{length(cs.reach)}) else &.{}),
        });
    }
    // With pad selection, on the domain fixtures' tracks: a diffusion on a
    // net with a pad is an aggressor, the same on another net is not.
    const pad_deck = pc.diode_process ++
        \\rule io1 latchup_victim(diff, nwpm, ntap; within: 15um, max_distance: 2um, pad: pad, bias: none, forward: none)
        \\
    ;
    const pad_net, const other = .{ 5, 6 };
    const Pad = struct { name: []const u8, net: usize, flagged: bool };
    for ([_]Pad{ .{ .name = "pad", .net = pad_net, .flagged = true }, .{ .name = "no_pad", .net = other, .flagged = false } }) |cs| {
        var l = try pc.circuit(arena, domain_nets, &.{}, &.{});
        try rect(&l, arena, "diff", .{ 0, -6000, 2000, -5000 });
        try riser(&l, arena, 900, -5900, cs.net);
        const ty = pc.trackY(pad_net);
        try rect(&l, arena, "pad", .{ -1000, ty, -400, ty + pc.track_h });
        try rect(&l, arena, "padv", .{ -800, ty + 150, -600, ty + 250 });
        try rect(&l, arena, "nwpm", .{ 7000, -6000, 10_000, -5000 });
        try rect(&l, arena, "ntap", .{ 10_000, -6000, 10_500, -5000 });
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/latchup_victim/{s}", .{cs.name}),
            .deck = pad_deck,
            .layout = l,
            .expect = try expect1(arena, "io1", if (cs.flagged) &.{length(3000)} else &.{}),
        });
    }
}

/// A `pdiff` square on `net` in an `nw` well labelled VDD (or, not
/// `well_round`, the well drawn away), and a victim 1.2 µm right of it
/// with its tap on its far edge: its worst point 1 µm from a tap.
fn aggressorBoard(arena: Allocator, net: []const u8, well_round: bool) !Layout {
    var l: Layout = .{};
    const well: Rect = if (well_round) .{ 0, 0, 2000, 2000 } else .{ -5000, 0, -3000, 2000 };
    try rect(&l, arena, "nw", well);
    try l.label(arena, "nwtxt", well[0] + 100, 100, "VDD");
    try rect(&l, arena, "pdiff", .{ 500, 500, 1000, 1000 });
    try l.label(arena, "pdtxt", 600, 600, net);
    try rect(&l, arena, "victim", .{ 2200, 0, 3200, 1000 });
    try rect(&l, arena, "tap", .{ 3200, 0, 3300, 1000 });
    return l;
}

fn aggressorDeck(arena: Allocator, forward: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\grid 1nm
        \\layer pdiff = gds(1, 0)
        \\layer nw = gds(2, 0)
        \\layer victim = gds(3, 0)
        \\layer tap = gds(4, 0)
        \\layer pdtxt = gds(1, 1)
        \\layer nwtxt = gds(2, 1)
        \\connect conductors [pdiff, nw]
        \\connect label pdtxt names pdiff
        \\connect label nwtxt names nw
        \\rule lv latchup_victim(pdiff, victim, tap; within: 2um, max_distance: 500nm, pad: none, bias: nw, forward: {s})
        \\
    , .{forward});
}

/// `latchup_victim` with `bias` and `forward` (ERC-D5): an aggressor is a
/// diffusion the intent's voltages can forward-bias against the well it
/// lies in, hand-derived; the victim is flagged at 1 µm against 500 nm
/// whenever the diffusion is an aggressor. `forward: above` on VDDH
/// (3.3 V > 1.8 V): flagged; on VDD itself: clean; on VDDH with the well
/// drawn away: clean. `forward: below` on VSS (0 < 1.8 V): flagged.
/// Without intent the row is skipped.
fn voltageAggressor(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const supplies = try pc.intentText(arena, &.{ .{ .name = "a", .mv = 1800 }, .{ .name = "b", .mv = 3300 } }, &.{
        .{ "VDD", "a", "power" },
        .{ "VSS", "a", "ground" },
        .{ "VDDH", "b", "power" },
    });
    const Case = struct { name: []const u8, forward: []const u8, net: []const u8, round: bool, flagged: bool };
    const cases = [_]Case{
        .{ .name = "above", .forward = "above", .net = "VDDH", .round = true, .flagged = true },
        .{ .name = "same", .forward = "above", .net = "VDD", .round = true, .flagged = false },
        .{ .name = "no_well", .forward = "above", .net = "VDDH", .round = false, .flagged = false },
        .{ .name = "below", .forward = "below", .net = "VSS", .round = true, .flagged = true },
    };
    for (cases) |cs| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/latchup_victim/voltage/{s}", .{cs.name}),
        .deck = try aggressorDeck(arena, cs.forward),
        .layout = try aggressorBoard(arena, cs.net, cs.round),
        .intent = supplies,
        .expect = try expect1(arena, "lv", if (cs.flagged) &.{length(1000)} else &.{}),
    });
    try out.append(arena, .{
        .name = "erc/latchup_victim/voltage/no_intent",
        .deck = try aggressorDeck(arena, "above"),
        .layout = try aggressorBoard(arena, "VDDH", true),
        .expect = try arena.dupe(Expect, &.{.{ .id = "lv", .outcome = .skipped }}),
    });
}

/// Two met1 pads, joined on met2 through vias (`strapped`), through a
/// resistor, or `apart`.
fn tagPads(arena: Allocator, joined: []const u8) !Layout {
    var l: Layout = .{};
    try rect(&l, arena, "met1", .{ 0, 0, 1000, 500 });
    try rect(&l, arena, "met1", .{ 3000, 0, 4000, 500 });
    if (std.mem.eql(u8, joined, "strapped")) {
        try rect(&l, arena, "met2", .{ 0, 0, 4000, 500 });
        try rect(&l, arena, "v1", .{ 400, 200, 500, 300 });
        try rect(&l, arena, "v1", .{ 3400, 200, 3500, 300 });
    } else if (std.mem.eql(u8, joined, "resistor")) {
        try rect(&l, arena, "met1", .{ 1000, 0, 1500, 500 });
        try rect(&l, arena, "res", .{ 1500, 0, 2500, 500 });
        try rect(&l, arena, "met1", .{ 2500, 0, 3000, 500 });
    }
    return l;
}

/// `mixed_tag(met1, hvi)` (ERC-F10, sky130 hvnwell.10): a met1 figure
/// sharing no area with `hvi`, on a net (nets joined through a resistor
/// counted as one) that holds a figure sharing area with it, is reported
/// with the count of such figures. Two pads, one under `hvi`, joined on
/// met2, through a resistor, or apart; a pad that only abuts `hvi` is
/// untagged; two tagged pads on one net; no `hvi` at all.
fn mixedTag(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const Case = struct { joined: []const u8, hvi: ?Rect, findings: []const Finding };
    const cases = [_]Case{
        .{ .joined = "strapped", .hvi = .{ -100, -100, 1100, 600 }, .findings = &.{count(1)} },
        .{ .joined = "resistor", .hvi = .{ -100, -100, 1100, 600 }, .findings = &.{count(1)} },
        .{ .joined = "apart", .hvi = .{ -100, -100, 1100, 600 }, .findings = &.{} },
        .{ .joined = "strapped", .hvi = null, .findings = &.{} },
        .{ .joined = "strapped", .hvi = .{ -1000, -100, 0, 600 }, .findings = &.{} },
        .{ .joined = "strapped", .hvi = .{ -100, -100, 4100, 600 }, .findings = &.{} },
    };
    for (cases) |cs| {
        var l = try tagPads(arena, cs.joined);
        var tag: []const u8 = "untagged";
        if (cs.hvi) |hvi| {
            try rect(&l, arena, "hvi", hvi);
            tag = try std.fmt.allocPrint(arena, "{d}_{d}", .{ hvi[0], hvi[2] });
        }
        try pc.everyPlacement(arena, out, .{
            .name = try std.fmt.allocPrint(arena, "erc/mixed_tag/{s}/{s}", .{ cs.joined, tag }),
            .deck = tag_deck,
            .layout = l,
            .expect = try expect1(arena, "mix", cs.findings),
        });
    }
}

// Oracle: the constructions in each group's doc comment: ring widths and
// tap distances against GF180MCU's latch-up rules, ring bias voltages,
// tie-area ratios and forward-biased diodes.
test "latchup rows report their derived findings" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try guardRingBias(arena, &all);
    try tieArea(arena, &all);
    try guardRing(arena, &all);
    try forwardDiode(arena, &all);
    try conditionalTie(arena, &all);
    try latchupVictim(arena, &all);
    try voltageAggressor(arena, &all);
    try fixture.checkAll(all.items);
}

// Oracle: the definition by hand: a met1 figure off `hvi` on a net holding
// a figure on it, counted per such figure (mixed_tag's doc comment).
test "mixed tag reports untagged figures on tagged nets" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try mixedTag(arena, &all);
    try fixture.checkAll(all.items);
}
