//! `esd_path`, `esd_clamp_resistance` and `esd_pin_pair` on the ESD strips
//! (ported_common.zig's `esdLayout`), every value hand-derived from the
//! strips' sheet resistances: path resistance, clamp sizing, the pulse
//! rating of wires and cuts, the layout rules, a pin pair, and the voltage
//! window with and without clamp turn-on. Ported from
//! crates/check/tests/erc/ported.rs (`esd_path_deck`, `esd_path`,
//! `esd_clamp_size`, `esd_interconnect`, `esd_layout_rules`,
//! `esd_pin_pair`, `esd_window`, `esd_turn_on`, and the test
//! `esd_paths_match_their_closed_forms`, less its `esd` and `esd_wiring`
//! parts: the board's lives in ported_board.zig, `esd_topological`'s with
//! that kind's family).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Finding = fixture.Finding;
const Layout = fixture.Layout;
const board = @import("board.zig");
const rect = board.rect;
const expect = @import("board_expect.zig");
const length = expect.length;
const millivolts = expect.millivolts;
const common = @import("ported_common.zig");
const Placed = common.Placed;
const at = common.at;
const ohms = common.ohms;
const microamps = common.microamps;
const side = common.side;
const sweep = common.sweep;
const esdLayout = common.esdLayout;
const gpa = testing.allocator;

/// The limits an `esd_path` row states, each `none` unless a fixture sets it.
const esd_limits = [_][]const u8{ "max_resistance", "clamp_it2", "max_density", "max_current_per_cut", "max_voltage", "min_width", "clamp_voltage" };

/// Every strip 1 µm wide.
const unit: [3]i64 = @splat(1000);

// ---- private ----

/// `esd_process` with one `esd_path` row `ep`, 1.33 A forced, each clamp
/// 1 Ω, the limits in `limits` as `(name, value)` and every other `none`.
fn pathDeck(arena: Allocator, limits: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}rule ep esd_path(pad; clamps: {s}, current: 1330mA, clamp_resistance: 1ohm", .{ common.esd_process, common.esd_clamps });
    for (esd_limits) |name| {
        const value = for (limits) |l| {
            if (std.mem.eql(u8, l[0], name)) break l[1];
        } else "none";
        try out.print(arena, ", {s}: {s}", .{ name, value });
    }
    try out.appendSlice(arena, ")\n");
    return out.items;
}

/// A fixture under `esdIntent` claiming rule `id` finds exactly `findings`.
fn esdFixture(arena: Allocator, name: []const u8, deck: []const u8, layout: Layout, id: []const u8, findings: []const Finding) !Fixture {
    return .{ .name = name, .deck = deck, .layout = layout, .intent = try common.esdIntent(arena), .expect = try common.expects(arena, &.{try common.rule(arena, id, findings)}) };
}

/// `f` renamed `<name>/placed` and claiming `findings` for `ep`, unpinned.
fn placedOf(arena: Allocator, f: Fixture, findings: []const Finding) !Fixture {
    var g = f;
    g.name = try std.fmt.allocPrint(arena, "{s}/placed", .{f.name});
    g.expect = try common.expects(arena, &.{try common.rule(arena, "ep", findings)});
    return g;
}

/// The strips with one down diode at 2 µm and VSS's own pin.
fn pinned(arena: Allocator) !Layout {
    var l = try esdLayout(arena, unit, &.{.{ .down, 2000 }});
    try common.pinVss(&l, arena);
    return l;
}

/// `esd_path` (ERC-C6) on closed forms. Each strip is tapped at its centre
/// (10 µm, the entry on the pad and the feed point of a supply with no pin)
/// and under each diode marker's centre; a strip of width `w` costs
/// `sheet * Δx / w` between taps, a diode 1 Ω.
///
/// - One down diode at 2 µm: the pad's 8 squares (0.5 Ω), the diode (1 Ω)
///   and VSS's 8 squares (1 Ω) in series, 2.5 Ω from the pad to VSS. VDD
///   is not reached, so it is no pair.
/// - With an up diode drawn reversed beside it the answer is the same: a
///   forward-biased diode carries nothing.
/// - VSS given its own pin through one `padv` cut (0.25 Ω) at 18 µm: VSS's
///   run is 16 squares (2 Ω), 3.75 Ω in all. The pin is a pin of VSS too,
///   stressed against VSS itself: 0 Ω.
/// - A down diode at 2 µm, an up diode at 18 µm and a rail diode at 10 µm:
///   to VSS, 15/11 Ω; to VDD, 14/11 Ω. The network has a loop, so its
///   solve is iterative: the sweep (a part in a thousand) bounds the value.
///
/// The tree cases are exact in binary and swept below, at and above; a
/// finding sits at the pad's first vertex, and is placed under every
/// symmetry.
fn esdPathInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const Case = struct { []const u8, Layout, []const f64 };
    const cases = [_]Case{
        .{ "series", try esdLayout(arena, unit, &.{.{ .down, 2000 }}), &.{2.5} },
        .{ "reversed_up", try esdLayout(arena, unit, &.{ .{ .down, 2000 }, .{ .up_reversed, 6000 } }), &.{2.5} },
        .{ "pinned", try pinned(arena), &.{3.75} },
        .{ "parallel", try esdLayout(arena, unit, &.{ .{ .down, 2000 }, .{ .up, 18_000 }, .{ .rail, 10_000 } }), &.{ 15.0 / 11.0, 14.0 / 11.0 } },
    };
    var placed: std.ArrayList(Fixture) = .empty;
    for (cases) |case| {
        const name, const layout, const values = case;
        const exact = values.len == 1;
        for (values, 0..) |value, k| {
            const swept = sweep(value);
            const limits: []const f64 = if (exact) &swept else &.{ value * 0.999, value * 1.001 };
            for (limits) |limit| {
                var findings: std.ArrayList(Finding) = .empty;
                for (values) |v| if (v > limit) try findings.append(arena, at(if (exact) ohms(v) else .{}, 0, 0));
                const deck = try pathDeck(arena, &.{.{ "max_resistance", try std.fmt.allocPrint(arena, "{d}ohm", .{limit}) }});
                const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/{s}/{d}/{s}", .{ name, k, side(limit, value) }), deck, layout, "ep", findings.items);
                if (exact and findings.items.len > 0) try placed.append(arena, try placedOf(arena, f, &.{ohms(value)}));
                try out.append(arena, f);
            }
        }
    }
    try common.everyPlacementInto(arena, placed.items, out);
    // Without intent nothing names the rails.
    try out.append(arena, .{
        .name = "erc/esd_path/no_intent",
        .deck = try pathDeck(arena, &.{.{ "max_resistance", "1ohm" }}),
        .layout = try esdLayout(arena, unit, &.{.{ .down, 2000 }}),
        .expect = try common.expects(arena, &.{.{ .id = "ep", .outcome = .skipped }}),
    });
}

/// `esd_path`'s clamp sizing (ERC-C2): a clamp carries its share of the
/// 1.33 A and may carry `clamp_it2` times its size, a diode's perimeter.
/// Each diode marker here is 200 nm by 2.2 µm, 4.8 µm round.
///
/// - One down diode carries all of it: rated below 1.33 A / 4.8 µm it is
///   flagged, measuring 1.33 A at its marker's corner.
/// - Two down diodes placed symmetrically about the pad's centre and VSS's
///   feed point carry half each: flagged only below 0.665 A / 4.8 µm. Their
///   network is a loop, so only the sweep bounds the share.
fn esdClampSizeInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const perimeter_m = 4.8e-6;
    const Case = struct { []const u8, []const Placed, f64 };
    const cases = [_]Case{
        .{ "whole", &.{.{ .down, 2000 }}, 1.33 },
        .{ "shared", &.{ .{ .down, 6000 }, .{ .down, 14_000 } }, 0.665 },
    };
    var placed: std.ArrayList(Fixture) = .empty;
    for (cases) |case| {
        const name, const diodes, const share = case;
        const rated = share / perimeter_m;
        for ([_]f64{ rated * 0.999, rated * 1.001 }) |it2| {
            const flagged = it2 < rated;
            var findings: std.ArrayList(Finding) = .empty;
            if (flagged and diodes.len == 1) {
                try findings.append(arena, at(microamps(share * 1e6), 1900, -2100));
            } else if (flagged) for (diodes) |_| try findings.append(arena, .{});
            const deck = try pathDeck(arena, &.{.{ "clamp_it2", try std.fmt.allocPrint(arena, "{d}A/m", .{it2}) }});
            const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/clamp_it2/{s}/{s}", .{ name, side(it2, rated) }), deck, try esdLayout(arena, unit, diodes), "ep", findings.items);
            if (flagged and diodes.len == 1) try placed.append(arena, try placedOf(arena, f, &.{microamps(share * 1e6)}));
            try out.append(arena, f);
        }
    }
    try common.everyPlacementInto(arena, placed.items, out);
}

/// `esd_path`'s pulse rating of the path's wires and cuts (ERC-C7): the
/// whole 1.33 A runs through the series path of one down diode, so each
/// segment carries it. The pad strip is 1 µm wide (1.33 A/µm), VSS 2 µm
/// (0.665 A/µm): a `max_density` swept around each flags the pad's segment
/// below 1.33 A/µm and VSS's too below 0.665 A/µm, each at its segment's
/// first tap (the diode's, at 2 µm, on the strip's centre line). VSS given
/// a pin through one `padv` cut: the cut carries all of it, flagged below
/// 1.33 A per cut.
fn esdInterconnectInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const layout = try esdLayout(arena, .{ 1000, 2000, 1000 }, &.{.{ .down, 2000 }});
    const pad = at(microamps(1.33e6), 2000, 500);
    const vss = at(microamps(1.33e6), 2000, -2000);
    const Case = struct { f64, []const Finding };
    const cases = [_]Case{ .{ 1.33e6, &.{pad} }, .{ 0.665e6, &.{ pad, vss } } };
    var placed: std.ArrayList(Fixture) = .empty;
    for (cases, 0..) |case, k| {
        const per_um, const flagged = case;
        for ([_]f64{ per_um * 0.999, per_um * 1.001 }) |density| {
            const findings = if (density < per_um) flagged else flagged[0..k];
            const deck = try pathDeck(arena, &.{.{ "max_density", try std.fmt.allocPrint(arena, "{d}A/m", .{density}) }});
            const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/max_density/{d}/{s}", .{ k, side(density, per_um) }), deck, layout, "ep", findings);
            const unpinned = try arena.alloc(Finding, findings.len);
            @memset(unpinned, microamps(1.33e6));
            try placed.append(arena, try placedOf(arena, f, unpinned));
            try out.append(arena, f);
        }
    }
    try common.everyPlacementInto(arena, placed.items, out);
    for ([_]f64{ 1.33e6 * 0.999, 1.33e6 * 1.001 }) |per_cut| {
        const deck = try pathDeck(arena, &.{.{ "max_current_per_cut", try std.fmt.allocPrint(arena, "{d}uA", .{per_cut}) }});
        const findings: []const Finding = if (per_cut < 1.33e6) &.{microamps(1.33e6)} else &.{};
        try out.append(arena, try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/per_cut/{s}", .{side(per_cut, 1.33e6)}), deck, try pinned(arena), "ep", findings));
    }
}

/// The ESD layout rules on recognised devices (ERC-C14), hand-derived on
/// the strips, limits deck-supplied:
///
/// - `esd_clamp_resistance`: a unit current from the pad, tapped at its
///   strip's centre (10 µm), to each `down` clamp's attach point on the pad
///   strip: `0.0625 Ω/sq × |x − 10 µm| / 1 µm`, 0.5 Ω for a clamp at 2 µm
///   and 0.25 Ω at 14 µm, swept either side; a clamp of an unlisted model
///   is not measured.
/// - `esd_path`'s `min_width`: 1.33 A from the pad through the clamp at
///   2 µm to VSS's feed point at its centre crosses the pad strip and the
///   VSS strip between 2 and 10 µm; with both 1 µm wide a limit of 1001 nm
///   flags both, 1000 nm (strict) and 999 nm neither, and with the pad
///   strip 2 µm wide a 1500 nm limit flags only VSS. The strips' dead ends
///   past the taps carry no current and are never flagged.
fn esdLayoutRulesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const Case = struct { []const u8, []const Placed, []const f64 };
    const cases = [_]Case{
        .{ "one", &.{.{ .down, 2000 }}, &.{0.5} },
        .{ "two", &.{ .{ .down, 2000 }, .{ .down, 14_000 } }, &.{ 0.5, 0.25 } },
        .{ "unlisted", &.{ .{ .down, 14_000 }, .{ .up, 2000 } }, &.{0.25} },
    };
    for (cases) |case| {
        const name, const diodes, const values = case;
        const layout = try esdLayout(arena, unit, diodes);
        for (values) |v| for (sweep(v)) |limit| {
            var findings: std.ArrayList(Finding) = .empty;
            for (values) |x| if (x > limit) try findings.append(arena, ohms(x));
            const f: Fixture = .{
                .name = try std.fmt.allocPrint(arena, "erc/esd_clamp_resistance/{s}/{d}", .{ name, limit }),
                .deck = try std.fmt.allocPrint(arena, "{s}rule cr esd_clamp_resistance(pad; clamps: [\"down\"], max_resistance: {d}ohm)\n", .{ common.esd_process, limit }),
                .layout = layout,
                .expect = try common.expects(arena, &.{try common.rule(arena, "cr", findings.items)}),
            };
            try common.everyPlacementInto(arena, &.{f}, out);
        };
    }
    const Width = struct { []const u8, [3]i64, i64, usize };
    const widths = [_]Width{
        .{ "below", unit, 999, 0 },
        .{ "at", unit, 1000, 0 },
        .{ "above", unit, 1001, 2 },
        .{ "wide_pad", .{ 2000, 1000, 1000 }, 1500, 1 },
    };
    for (widths) |case| {
        const name, const w, const min_width, const flagged = case;
        const findings = try arena.alloc(Finding, flagged);
        @memset(findings, length(1000));
        const deck = try pathDeck(arena, &.{.{ "min_width", try std.fmt.allocPrint(arena, "{d}nm", .{min_width}) }});
        const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/min_width/{s}", .{name}), deck, try esdLayout(arena, w, &.{.{ .down, 2000 }}), "ep", findings);
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

/// `esd_pin_pair` (ERC-C6), hand-derived on `esd_process`: pad strips PADA
/// at y 0 and PADB at 6 µm, VSS (met1) at -3 µm and VDD (met2) at 3 µm,
/// every strip 20 µm long and 1 µm wide. A `down` diode joins PADA to VSS
/// at x 2 µm, a `rail` VSS to VDD at 10 µm and an `up` PADB to VDD at
/// 18 µm, each 1 Ω. 1.33 A from PADA (tapped at its centre) to PADB (held
/// at its centre) crosses 8 µm of PADA (0.5 Ω), the down diode, 8 µm of VSS
/// (1 Ω), the rail clamp, 8 µm of VDD (0.5 Ω), the up diode and 8 µm of
/// PADB (0.5 Ω): 5.5 Ω, swept a part in a thousand either side. Without
/// the rail clamp the two pins share no supply and the pair is not
/// examined.
fn esdPinPairInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const value = 5.5;
    for ([_]f64{ value * 0.999, value * 1.001 }) |limit| {
        const findings: []const Finding = if (value > limit) &.{ohms(value)} else &.{};
        const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_pin_pair/{s}", .{side(limit, value)}), try pinPairDeck(arena, limit), try pinPairBoard(arena, true), "pp", findings);
        try common.everyPlacementInto(arena, &.{f}, out);
    }
    var f = try esdFixture(arena, "erc/esd_pin_pair/no_rail", try pinPairDeck(arena, 1.0), try pinPairBoard(arena, false), "pp", &.{});
    f.expect = try common.expects(arena, &.{.{ .id = "pp", .examined = 0 }});
    try out.append(arena, f);
}

fn pinPairBoard(arena: Allocator, rail: bool) !Layout {
    var l: Layout = .{};
    const strips = [_]struct { []const u8, []const u8, []const u8, i64 }{
        .{ "pad", "padtxt", "PADA", 0 },
        .{ "met1", "m1txt", "VSS", -3000 },
        .{ "met2", "m2txt", "VDD", 3000 },
        .{ "pad", "padtxt", "PADB", 6000 },
    };
    for (strips) |s| {
        try rect(&l, arena, s[0], .{ 0, s[3], common.strip, s[3] + 1000 });
        try l.label(arena, s[1], 100, s[3] + 500, s[2]);
    }
    try rect(&l, arena, "mkd", .{ 1900, -2100, 2100, 100 });
    if (rail) try rect(&l, arena, "mkr", .{ 9900, -2100, 10_100, 3100 });
    try rect(&l, arena, "mku", .{ 17_900, 3900, 18_100, 6100 });
    return l;
}

fn pinPairDeck(arena: Allocator, limit: f64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}rule pp esd_pin_pair(pad; clamps: {s}, current: 1330mA, clamp_resistance: 1ohm, max_resistance: {d}ohm)\n", .{ common.esd_process, common.esd_clamps, limit });
}

/// `esd_path`'s voltage window (ERC-C8): the pin's rise under the forced
/// current, its path resistance times the current. One down diode in
/// series, 2.5 Ω, so 1.33 A raises the pad to 3325 mV exactly, swept below,
/// at and above, at the pad's first vertex and placed. With the up diode,
/// rail diode and a second supply the pin rises to 1.33 A times 15/11 Ω
/// toward VSS and 14/11 Ω toward VDD: a limit between the two flags only
/// the VSS pair.
fn esdWindowInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const rise = 3325.0;
    var placed: std.ArrayList(Fixture) = .empty;
    for (sweep(rise)) |limit| {
        const deck = try pathDeck(arena, &.{.{ "max_voltage", try std.fmt.allocPrint(arena, "{d}mV", .{limit}) }});
        const findings: []const Finding = if (limit < rise) &.{at(millivolts(rise), 0, 0)} else &.{};
        const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/max_voltage/series/{s}", .{side(limit, rise)}), deck, try esdLayout(arena, unit, &.{.{ .down, 2000 }}), "ep", findings);
        if (limit < rise) try placed.append(arena, try placedOf(arena, f, &.{millivolts(rise)}));
        try out.append(arena, f);
    }
    try common.everyPlacementInto(arena, placed.items, out);
    const to_vss = 1330.0 * 15.0 / 11.0;
    const to_vdd = 1330.0 * 14.0 / 11.0;
    const deck = try pathDeck(arena, &.{.{ "max_voltage", try std.fmt.allocPrint(arena, "{d}mV", .{(to_vss + to_vdd) / 2.0}) }});
    try out.append(arena, try esdFixture(arena, "erc/esd_path/max_voltage/parallel", deck, try esdLayout(arena, unit, &.{ .{ .down, 2000 }, .{ .up, 18_000 }, .{ .rail, 10_000 } }), "ep", &.{at(.{}, 0, 0)}));
    try esdTurnOnInto(arena, out);
}

/// `esd_path`'s `clamp_voltage` (ERC-C8): each conducting clamp holds
/// 700 mV besides its 1 Ω, White Paper 2's `Vpad = Vdiode_on + Rdiode_on
/// I + Rbus I + Vclamp_on + Rclamp_on I`:
///
/// - the down diode alone: 1.33 A over 2.5 Ω plus one turn-on, 4025 mV;
/// - an up diode at 18 µm and a rail clamp at 10 µm, no down diode: to VDD
///   the pad strip 0.5 Ω, the up diode, VDD back to its centre 0.5 Ω and
///   one turn-on, 3360 mV; to VSS also the rail clamp and a second
///   turn-on, 3 Ω and 1400 mV, 5390 mV.
///
/// Each limit is a part in a thousand either side of a value.
fn esdTurnOnInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const series = 1330.0 * 2.5 + 700.0;
    for ([_]f64{ series * 0.999, series * 1.001 }) |limit| {
        const findings: []const Finding = if (limit < series) &.{millivolts(series)} else &.{};
        const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/clamp_voltage/series/{s}", .{side(limit, series)}), try turnOnDeck(arena, limit), try esdLayout(arena, unit, &.{.{ .down, 2000 }}), "ep", findings);
        try common.everyPlacementInto(arena, &.{f}, out);
    }
    const to_vdd = 1330.0 * 2.0 + 700.0;
    const to_vss = 1330.0 * 3.0 + 1400.0;
    for ([_]f64{ to_vdd * 0.999, to_vdd * 1.001, to_vss * 1.001 }) |limit| {
        var findings: std.ArrayList(Finding) = .empty;
        for ([_]f64{ to_vdd, to_vss }) |v| if (v > limit) try findings.append(arena, millivolts(v));
        const f = try esdFixture(arena, try std.fmt.allocPrint(arena, "erc/esd_path/clamp_voltage/rail/{d}", .{limit}), try turnOnDeck(arena, limit), try esdLayout(arena, unit, &.{ .{ .up, 18_000 }, .{ .rail, 10_000 } }), "ep", findings.items);
        try common.everyPlacementInto(arena, &.{f}, out);
    }
}

fn turnOnDeck(arena: Allocator, limit: f64) ![]const u8 {
    return pathDeck(arena, &.{ .{ "max_voltage", try std.fmt.allocPrint(arena, "{d}mV", .{limit}) }, .{ "clamp_voltage", "700mV" } });
}

test "esd paths match their closed forms" {
    // Oracle: the closed forms in each group's doc comment: series and
    // parallel resistances of strips of known sheet resistance, Kirchhoff's
    // current law for clamp shares, White Paper 2's turn-on sum, each limit
    // swept a part in a thousand either side, placed under the symmetries
    // of the square.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try esdPathInto(arena, &all);
    try esdClampSizeInto(arena, &all);
    try esdInterconnectInto(arena, &all);
    try esdLayoutRulesInto(arena, &all);
    try esdPinPairInto(arena, &all);
    try esdWindowInto(arena, &all);
    try fixture.checkAll(all.items);
}
