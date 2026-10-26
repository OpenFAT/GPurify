//! The geometric voltage-domain kinds on hand-drawn bars: `voltage_space`
//! against its voltage table, `hv_tag` against its tag, and
//! `dielectric_field` against the closed-form field limit. Ported from
//! crates/check/tests/erc/ported.rs (`VS_DECK`, `vs_need`, `vs_intent`,
//! `voltage_spacing`, `TAG_DECK`, `tagged_transistor`, `hv_tag`,
//! `FIELD_DECK`, `dielectric_field`, and the test
//! `voltage_spacing_tags_and_fields_report_their_derived_findings`, less
//! its `mixed_tag` group, the supply family's).

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
const intentText = board.intentText;
const length = @import("board_expect.zig").length;
const common = @import("ported_common.zig");
const area = common.area;
const side = common.side;
const gpa = testing.allocator;

/// Two labelled metals with a via between them, and two voltage tables:
/// met1 to met1 needs 200 nm from 0 V, 400 nm from 1.5 V and 800 nm from
/// 3 V; met1 to met2 needs 500 nm from 1 V.
const vs_deck =
    \\grid 1nm
    \\layer met1 = gds(1, 0)
    \\layer m1txt = gds(1, 1)
    \\layer met2 = gds(2, 0)
    \\layer m2txt = gds(2, 1)
    \\layer v1 = gds(3, 0)
    \\connect conductors [met1, met2]
    \\connect touch_within_layer
    \\connect via v1 [met1, met2]
    \\connect label m1txt names met1
    \\connect label m2txt names met2
    \\rule vs voltage_space(met1; voltage: [0V, 1.5V, 3V], space: [200nm, 400nm, 800nm])
    \\rule vs2 voltage_space(met1, met2; voltage: [1V], space: [500nm])
    \\
;

/// A transistor whose source and drain diffusions reach met1 through
/// contacts, its poly through a poly contact; `hvi` tags; `sw` conducts
/// only while its gate can reach 1 V.
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

/// Two labelled metals in a stack: met1 from 1000 to 1300 nm, met2 from
/// 1700 nm, so 400 nm of dielectric between them; met3 states no stack
/// row. Each table allows 10 V/µm (10 mV per nm).
const field_deck =
    \\grid 1nm
    \\layer met1 = gds(1, 0)
    \\layer m1txt = gds(1, 1)
    \\layer met2 = gds(2, 0)
    \\layer m2txt = gds(2, 1)
    \\layer met3 = gds(3, 0)
    \\connect conductors [met1, met2, met3]
    \\connect touch_within_layer
    \\connect label m1txt names met1
    \\connect label m2txt names met2
    \\pex met1 thickness 300nm height 1000nm sheet 0.1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met2 thickness 300nm height 1700nm sheet 0.1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\rule df dielectric_field(met1; max_field: 10V/um)
    \\rule df2 dielectric_field(met1, met2; max_field: 10V/um)
    \\rule df3 dielectric_field(met1, met3; max_field: 10V/um)
    \\
;

// ---- private ----

/// The space `vs` needs between two nets `delta` mV apart, read off the
/// table in its definition: the last step whose voltage `delta` reaches.
fn vsNeed(delta: i64) i64 {
    if (delta >= 3000) return 800;
    if (delta >= 1500) return 400;
    return 200;
}

/// Intent putting net A at `1000 + delta` mV (domain `hi`) and net B at
/// 1000 mV (domain `lo`), both power: `delta` apart at worst.
fn vsIntent(arena: Allocator, delta: i64) ![]const u8 {
    return intentText(arena, &.{ .{ .name = "hi", .mv = @floatFromInt(1000 + delta) }, .{ .name = "lo", .mv = 1000.0 } }, &.{ .{ "A", "hi", "power" }, .{ "B", "lo", "power" } }, &.{});
}

/// A met1 bar on A at the origin and a bar of `layer_b` on B `gap` to its
/// right, each 1000 × 500.
fn bars(arena: Allocator, layer_b: []const u8, text_b: []const u8, gap: i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 1000, 500);
    try l.rect(arena, layer_b, 1000 + gap, 0, 2000 + gap, 500);
    try l.label(arena, "m1txt", 500, 250, "A");
    try l.label(arena, text_b, 1500 + gap, 250, "B");
    return l;
}

/// Claims for each `(id, findings)`: every rule ran and found exactly those.
fn claims(arena: Allocator, rules: []const struct { []const u8, []const Finding }) ![]const Expect {
    const out = try arena.alloc(Expect, rules.len);
    for (out, rules) |*e, r| e.* = try common.rule(arena, r[0], r[1]);
    return out;
}

/// `voltage_space` (DRC-082, ERC-F11) on two met1 bars `gap` apart, nets A
/// and B `delta` mV apart, swept against both: every step's voltage a
/// millivolt either side, every step's space and one nanometre under it.
/// A pair is flagged, measuring its gap, exactly when the gap is below the
/// space the voltage needs. The boundary of each delta's own step is
/// placed under every symmetry and offset. Then: a net no supply reaches
/// and two shapes of one net are not judged however close; a met1 shape on
/// A and a met2 shape on B, 1 V apart or a millivolt less, overlapping or
/// `499`/`500` nm apart (`vs2`); a ground at 0 V against 3 V; and no
/// intent, Skipped.
fn voltageSpacingInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    for ([_]i64{ 0, 1499, 1500, 1501, 2999, 3000, 3001, 5000 }) |delta| {
        const need = vsNeed(delta);
        for ([_]i64{ 199, 200, 399, 400, 799, 800 }) |gap| {
            const found: []const Finding = if (gap < need) &.{length(gap)} else &.{};
            const f: Fixture = .{
                .name = try std.fmt.allocPrint(arena, "erc/voltage_spacing/{d}mV/{d}nm", .{ delta, gap }),
                .deck = vs_deck,
                .layout = try bars(arena, "met1", "m1txt", gap),
                .intent = try vsIntent(arena, delta),
                .expect = try claims(arena, &.{ .{ "vs", found }, .{ "vs2", &.{} } }),
            };
            if (gap == need or gap == need - 1) try common.everyPlacementInto(arena, &.{f}, out) else try out.append(arena, f);
        }
    }
    // A, then 100 nm off it an unlabelled bar no supply reaches; B far away.
    var unreached: Layout = .{};
    try unreached.rect(arena, "met1", 0, 0, 1000, 500);
    try unreached.rect(arena, "met1", 1100, 0, 2100, 500);
    try unreached.rect(arena, "met1", 20_000, 0, 21_000, 500);
    try unreached.label(arena, "m1txt", 500, 250, "A");
    try unreached.label(arena, "m1txt", 20_500, 250, "B");
    const clean = try claims(arena, &.{ .{ "vs", &.{} }, .{ "vs2", &.{} } });
    try common.everyPlacementInto(arena, &.{.{ .name = "erc/voltage_spacing/unreached", .deck = vs_deck, .layout = unreached, .intent = try vsIntent(arena, 5000), .expect = clean }}, out);
    // Two met1 bars of A 100 nm apart, bridged on met2 through vias: one
    // net, at one voltage, so neither table judges them.
    var same: Layout = .{};
    try same.rect(arena, "met1", 0, 0, 1000, 500);
    try same.rect(arena, "met1", 1100, 0, 2100, 500);
    try same.rect(arena, "met2", 0, 0, 2100, 500);
    try same.rect(arena, "v1", 400, 200, 500, 300);
    try same.rect(arena, "v1", 1600, 200, 1700, 300);
    try same.rect(arena, "met1", 20_000, 0, 21_000, 500);
    try same.label(arena, "m1txt", 200, 250, "A");
    try same.label(arena, "m1txt", 20_500, 250, "B");
    try common.everyPlacementInto(arena, &.{.{ .name = "erc/voltage_spacing/same_net", .deck = vs_deck, .layout = same, .intent = try vsIntent(arena, 5000), .expect = clean }}, out);
    // met1 on A against met2 on B: a cross (overlap, distance 0), or a met2
    // bar 499 or 500 nm off the met1 bar's end.
    const Cross = struct { []const u8, board.Rect, i64 };
    for ([_]i64{ 999, 1000 }) |delta| for ([_]Cross{
        .{ "overlap", .{ 400, -1000, 600, 1500 }, 0 },
        .{ "499nm", .{ 1499, 0, 2499, 500 }, 499 },
        .{ "500nm", .{ 1500, 0, 2500, 500 }, 500 },
    }) |case| {
        const name, const met2, const gap = case;
        var l: Layout = .{};
        try l.rect(arena, "met1", 0, 0, 1000, 500);
        try l.label(arena, "m1txt", 200, 250, "A");
        try rect(&l, arena, "met2", met2);
        try l.label(arena, "m2txt", met2[2] - 50, 250, "B");
        const found: []const Finding = if (delta >= 1000 and gap < 500) &.{length(gap)} else &.{};
        try common.everyPlacementInto(arena, &.{.{
            .name = try std.fmt.allocPrint(arena, "erc/voltage_spacing/two_layers/{d}mV/{s}", .{ delta, name }),
            .deck = vs_deck,
            .layout = l,
            .intent = try vsIntent(arena, delta),
            .expect = try claims(arena, &.{ .{ "vs", &.{} }, .{ "vs2", found } }),
        }}, out);
    };
    // A ground at 0 V against a 3 V power net: 3 V apart, 800 nm needed.
    for ([_]i64{ 799, 800 }) |gap| {
        const found: []const Finding = if (gap < 800) &.{length(gap)} else &.{};
        try out.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/voltage_spacing/ground/{d}nm", .{gap}),
            .deck = vs_deck,
            .layout = try bars(arena, "met1", "m1txt", gap),
            .intent = try intentText(arena, &.{ .{ .name = "hi", .mv = 3000.0 }, .{ .name = "lo", .mv = 1800.0 } }, &.{ .{ "A", "hi", "power" }, .{ "B", "lo", "ground" } }, &.{}),
            .expect = try claims(arena, &.{.{ "vs", found }}),
        });
    }
    var bare: Layout = .{};
    try bare.rect(arena, "met1", 0, 0, 1000, 500);
    try bare.rect(arena, "met1", 1100, 0, 2100, 500);
    try out.append(arena, .{ .name = "erc/voltage_spacing/no_intent", .deck = vs_deck, .layout = bare, .expect = try common.expects(arena, &.{ .{ .id = "vs", .outcome = .skipped }, .{ .id = "vs2", .outcome = .skipped } }) });
}

/// A transistor of marker `marker` at the origin: source diffusion on met1
/// pad S (0..1000), drain on met1 pad D (1200..2200), the gate's poly out
/// to a met1 pad G above, each pad 1000 × 500.
fn taggedTransistor(arena: Allocator, marker: []const u8) !Layout {
    var l: Layout = .{};
    try rect(&l, arena, "diff", .{ 0, 0, 1000, 1000 });
    try rect(&l, arena, "diff", .{ 1200, 0, 2200, 1000 });
    try rect(&l, arena, "poly", .{ 1000, 0, 1200, 2000 });
    try rect(&l, arena, marker, .{ 1000, 0, 1200, 1000 });
    try rect(&l, arena, "cont", .{ 400, 400, 600, 600 });
    try rect(&l, arena, "cont", .{ 1600, 400, 1800, 600 });
    try rect(&l, arena, "pcont", .{ 1050, 1700, 1150, 1800 });
    try rect(&l, arena, "met1", .{ 0, 250, 1000, 750 });
    try rect(&l, arena, "met1", .{ 1200, 250, 2200, 750 });
    try rect(&l, arena, "met1", .{ 900, 1600, 1300, 2100 });
    return l;
}

/// `hv_tag(met1, hvi; voltage: 3V)` (DRC-083): a met1 figure whose net can
/// reach 3 V or more lies inside `hvi`, or is reported with the area it
/// leaves outside. A pad on a supply swept a millivolt either side of 3 V,
/// uncovered and half covered; a pad joined to the 3.3 V supply through a
/// transistor channel is high-voltage too (sky130 hv.X.4), unless the
/// transistor is a switch whose gate, tied to ground, never turns it on
/// (ERC-F1); a 1.8 V pad is never judged; no intent, Skipped. Every case
/// under every symmetry and offset.
fn hvTagInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    const Cover = struct { []const u8, ?board.Rect, i128 };
    for ([_]f64{ 2999.0, 3000.0, 3001.0 }) |mv| for ([_]Cover{
        .{ "bare", null, 500_000 },
        .{ "half", .{ 500, -100, 1100, 600 }, 250_000 },
        .{ "covered", .{ -100, -100, 1100, 600 }, 0 },
    }) |case| {
        const name, const hvi, const outside = case;
        var l = try hvPad(arena);
        if (hvi) |r| try rect(&l, arena, "hvi", r);
        const found: []const Finding = if (mv >= 3000.0 and outside > 0) &.{area(outside)} else &.{};
        try cases.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/hv_tag/pad/{s}/{s}", .{ side(3000.0, mv), name }),
            .deck = tag_deck,
            .layout = l,
            .intent = try intentText(arena, &.{.{ .name = "hv", .mv = mv }}, &.{.{ "HV", "hv", "power" }}, &.{}),
            .expect = try claims(arena, &.{.{ "hvt", found }}),
        });
    };
    // HV on S, the 1.8 V core supply on G, VSS on nothing: D reaches 3.3 V
    // through the channel. `hvi` covers S only, so D (500 000 nm²) is
    // reported; with the switch and G on VSS the channel never conducts.
    const Channel = struct { []const u8, []const u8, []const u8, []const Finding };
    for ([_]Channel{
        .{ "through_channel", "mk", "VDD", &.{area(500_000)} },
        .{ "switch_on", "mks", "VDD", &.{area(500_000)} },
        .{ "switch_off", "mks", "VSS", &.{} },
    }) |case| {
        const name, const marker, const gate_net, const found = case;
        var l = try taggedTransistor(arena, marker);
        try l.label(arena, "m1txt", 100, 500, "HV");
        try l.label(arena, "m1txt", 1000, 2000, gate_net);
        try rect(&l, arena, "hvi", .{ -100, 150, 1100, 850 });
        try cases.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/hv_tag/propagated/{s}", .{name}),
            .deck = tag_deck,
            .layout = l,
            .intent = try intentText(arena, &.{ .{ .name = "core", .mv = 1800.0 }, .{ .name = "hv", .mv = 3300.0 } }, &.{ .{ "HV", "hv", "power" }, .{ "VDD", "core", "power" }, .{ "VSS", "core", "ground" } }, &.{}),
            .expect = try claims(arena, &.{.{ "hvt", found }}),
        });
    }
    var low: Layout = .{};
    try low.rect(arena, "met1", 0, 0, 1000, 500);
    try low.label(arena, "m1txt", 100, 250, "VDD");
    try cases.append(arena, .{
        .name = "erc/hv_tag/low_voltage",
        .deck = tag_deck,
        .layout = low,
        .intent = try intentText(arena, &.{.{ .name = "core", .mv = 1800.0 }}, &.{.{ "VDD", "core", "power" }}, &.{}),
        .expect = try claims(arena, &.{.{ "hvt", &.{} }}),
    });
    try common.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, .{ .name = "erc/hv_tag/no_intent", .deck = tag_deck, .layout = try hvPad(arena), .expect = try common.expects(arena, &.{.{ .id = "hvt", .outcome = .skipped }}) });
}

/// A met1 pad on HV.
fn hvPad(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 1000, 500);
    try l.label(arena, "m1txt", 100, 250, "HV");
    return l;
}

/// `dielectric_field` (ERC-F13): the closed form, field = ΔV over the
/// separation: on met1, nets 3 V apart need 3000 mV / (10 mV/nm) = 300 nm,
/// and 3.01 V apart 301 nm; between met1 and met2, 400 nm of dielectric
/// under nets 5 V apart needs a 500 nm separation, a lateral 300 nm (the
/// 3-4-5 triangle), and 4 V is exactly held by the 400 nm alone, 4.001 V
/// not (a lateral 9 nm: sqrt(400.1² - 400²) = 8.94, rounded up). A pair is
/// flagged, measuring its lateral gap, below its limit. met3 has no stack
/// row: refused. Every case under every symmetry and offset.
fn dielectricFieldInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    const Case = struct { i64, i64, bool };
    for ([_]Case{ .{ 3000, 299, true }, .{ 3000, 300, false }, .{ 3010, 300, true }, .{ 2990, 299, false } }) |case| {
        const delta, const gap, const flagged = case;
        const found: []const Finding = if (flagged) &.{length(gap)} else &.{};
        var e: std.ArrayList(Expect) = .empty;
        try e.appendSlice(arena, try claims(arena, &.{ .{ "df", found }, .{ "df2", &.{} } }));
        try e.append(arena, .{ .id = "df3", .outcome = .refused });
        try cases.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/dielectric_field/one_layer/{d}mV/{d}nm", .{ delta, gap }),
            .deck = field_deck,
            .layout = try bars(arena, "met1", "m1txt", gap),
            .intent = try vsIntent(arena, delta),
            .expect = e.items,
        });
    }
    for ([_]Case{ .{ 5000, 299, true }, .{ 5000, 300, false } }) |case| {
        const delta, const gap, const flagged = case;
        const found: []const Finding = if (flagged) &.{length(gap)} else &.{};
        try cases.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/dielectric_field/two_layers/{d}mV/{d}nm", .{ delta, gap }),
            .deck = field_deck,
            .layout = try bars(arena, "met2", "m2txt", gap),
            .intent = try vsIntent(arena, delta),
            .expect = try claims(arena, &.{ .{ "df", &.{} }, .{ "df2", found } }),
        });
    }
    for ([_]struct { i64, bool }{ .{ 4000, false }, .{ 4001, true } }) |case| {
        const delta, const flagged = case;
        var l: Layout = .{};
        try l.rect(arena, "met1", 0, 0, 1000, 500);
        try l.rect(arena, "met2", 400, -1000, 600, 1500);
        try l.label(arena, "m1txt", 100, 250, "A");
        try l.label(arena, "m2txt", 500, 1400, "B");
        const found: []const Finding = if (flagged) &.{length(0)} else &.{};
        try cases.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "erc/dielectric_field/crossing/{d}mV", .{delta}),
            .deck = field_deck,
            .layout = l,
            .intent = try vsIntent(arena, delta),
            .expect = try claims(arena, &.{.{ "df2", found }}),
        });
    }
    try common.everyPlacementInto(arena, cases.items, out);
}

test "voltage spacing, tags and fields report their derived findings" {
    // Oracle: the voltage tables, tags and field limits each group's doc
    // comment derives from LEF58_VOLTAGESPACING and the dielectric's rating.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try voltageSpacingInto(arena, &all);
    try hvTagInto(arena, &all);
    try dielectricFieldInto(arena, &all);
    try fixture.checkAll(all.items);
}
