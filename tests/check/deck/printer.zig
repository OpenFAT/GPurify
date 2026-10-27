//! The printer is the parser's inverse: a deck shared as text is the deck
//! (deck-library plan §4.7, testing-plan L9b). Ported from
//! crates/check/tests/deck/printer.rs.
//!
//! Oracle: round trip. `compile(print(d))` in the same string table types
//! every rule as `d` does, rule by rule, and printing that again gives the
//! same text.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const deck = check.deck;
const gpa = testing.allocator;
const common = @import("common.zig");
const Compiled = common.Compiled;
const compileText = common.compileText;
const assertRoundTrip = common.assertRoundTrip;

// ---- private ----

fn roundTripText(what: []const u8, text: []const u8) !Compiled {
    var c = try compileText(text, 1000);
    errdefer c.deinit();
    try assertRoundTrip(what, &c);
    return c;
}

fn printOf(c: *Compiled) ![]const u8 {
    var why: []const u8 = "";
    return deck.source.print(c.arena.allocator(), &c.cd, &c.strings, &why);
}

fn expectContains(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |n| if (std.mem.indexOf(u8, haystack, n) == null) {
        std.debug.print("{s} not in\n{s}\n", .{ n, haystack });
        return error.TestExpectedContains;
    };
}

fn expectRefusals(text: []const u8, swaps: []const [2][]const u8) !void {
    for (swaps) |s| {
        const swapped = try std.mem.replaceOwned(u8, gpa, text, s[0], s[1]);
        defer gpa.free(swapped);
        if (!common.refused(swapped)) {
            std.debug.print("accepted: {s} -> {s}\n", .{ s[0], s[1] });
            return error.TestExpectedRefusal;
        }
    }
}

test "every shipped deck survives printing" {
    // Oracle: round trip, every rule of both domains typed the same.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (common.shipped) |name| {
        var c = try compileText(try common.shippedText(arena.allocator(), name), 1000);
        defer c.deinit();
        try assertRoundTrip(name, &c);
    }
}

// every_rust_twin_survives_printing: in twins.zig, beside the twins.

test "a length no decimal states is refused" {
    // Oracle: hand-derived: 1 nm is 3 units of the grid, and one unit is
    // 1/3 nm.
    var c = try compileText("grid 1nm\nlayer m = gds(1, 0)\nrule w width(m) >= 1nm\n", 3000);
    defer c.deinit();
    try testing.expectError(error.Unprintable, printOf(&c));
}

test "a deck with a temperature survives printing" {
    // Oracle: round trip.
    const text =
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\layer met2 = gds(69, 20)
        \\temperature 358.15K nominal 303.15K
        \\pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
        \\pex met2 thickness 360nm height 2006nm sheet 0.125ohm area_cap 17.5aF/um2 fringe_cap 37.6aF/um tc1 3.161e-3/K tc2 -7.272e-7/K2
        \\
    ;
    var c = try roundTripText("temperature", text);
    defer c.deinit();
    try testing.expect(c.cd.deck.temperature != null);
    try expectContains(try printOf(&c), &.{ "temperature 3.5815e2K nominal 3.0315e2K", "sheet 1.25e-1ohm", "tc1 3.179e-3/K tc2 3.094e-7/K2" });
}

test "a deck with lvs statements survives printing" {
    // Oracle: round trip.
    const text =
        \\grid 1nm
        \\layer diff = gds(65, 20)
        \\layer poly = gds(66, 20)
        \\layer res = gds(66, 13)
        \\layer cap = gds(75, 20)
        \\device mos poly model "nfet" terminals [poly, diff, diff, diff]
        \\device resistor res model "rpoly" terminals [poly, poly]
        \\device capacitor cap model "cmim" terminals [poly, diff]
        \\device inductor res model "spiral" terminals [poly, poly] inductance 2nH
        \\lvs tolerance "nfet" w relative 1%
        \\lvs tolerance "nfet" l relative 0.005 absolute 5nm
        \\lvs tolerance "nfet" as absolute 0.2um2
        \\lvs tolerance "rpoly" r absolute 2kohm
        \\lvs tolerance "cmim" c relative 0.02 absolute 3fF
        \\lvs tolerance "nfet" m absolute 1
        \\lvs ignore_parameter "rpoly" l
        \\lvs asymmetric "nfet"
        \\lvs permute "cmim" top bottom
        \\lvs ignore "cmim"
        \\lvs ignore_shorted "nfet"
        \\lvs ports_by_name
        \\lvs range "nfet" l >= 150nm <= 20um
        \\lvs range "nfet" ad >= 0.1um2
        \\lvs range "nfet" nf <= 8
        \\lvs topology relaxed
        \\lvs connect_implicit "VDD*"
        \\lvs connect_explicit "VSS" "GND"
        \\lvs max_res 1Mohm
        \\lvs min_caps 10fF
        \\lvs same_nets "OUT_PAD" "OUT"
        \\lvs count "nfet" >= 1 <= 4000
        \\lvs recognize_gates
        \\lvs lde "nfet" od diff max 5um well cap scref 950nm
        \\lvs blackbox "SRAM_*"
        \\lvs blackbox "esd_?"
        \\lvs filter_unused u ae c
        \\lvs supply "VDD" "VSS"
        \\
    ;
    var c = try roundTripText("lvs", text);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 6), c.cd.deck.lvs.tolerance.len);
    try expectContains(try printOf(&c), &.{
        "lvs tolerance \"nfet\" l relative 5e-3 absolute 5e0nm",
        "lvs tolerance \"rpoly\" r absolute 2e3ohm",
        "lvs permute \"cmim\" top bottom",
        "lvs range \"nfet\" l >= 150nm <= 20000nm",
        "lvs connect_explicit \"VSS\" \"GND\"",
        "lvs max_res 1e6ohm",
        "lvs min_caps 1e4aF",
        "lvs same_nets \"OUT_PAD\" \"OUT\"",
        "lvs count \"nfet\" >= 1 <= 4000",
        "lvs recognize_gates",
        "lvs blackbox \"SRAM_*\"\nlvs blackbox \"esd_?\"",
        "lvs filter_unused u ae c",
        "lvs supply \"VDD\" \"VSS\"",
        "lvs lde \"nfet\" od diff max 5000nm well cap scref 950nm",
        "device inductor res model \"spiral\" terminals [poly, poly] inductance 2e0nH",
    });
}

test "a deck with corners stages and waivers survives printing" {
    // Oracle: round trip.
    const text =
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\layer met2 = gds(69, 20)
        \\layer waiver = gds(200, 0)
        \\stage gross
        \\rule m1.w width(met1) >= 140nm
        \\stage fine
        \\rule m1.s space(met1) >= 140nm
        \\rule m2.w width(met2) >= 140nm
        \\stage last
        \\temperature 358.15K nominal 303.15K
        \\pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
        \\pex met2 thickness 360nm height 2006nm sheet 0.125ohm area_cap 17.5aF/um2 fringe_cap 37.6aF/um tc1 3.161e-3/K tc2 -7.272e-7/K2
        \\corner cmax met1 thickness 396nm sheet 0.11ohm
        \\corner cmax met2 sheet 0.2ohm tc1 0/K tc2 0/K2
        \\corner cmin met1 fringe_cap 36aF/um
        \\waive m1.s waiver
        \\waive m2.w waiver
        \\extraction rcc coupling_threshold 0.1fF
        \\
    ;
    var c = try roundTripText("corners, stages and waivers", text);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.cd.deck.corners.len);
    try testing.expectEqual(@as(usize, 3), c.cd.deck.stages.name.len);
    try testing.expectEqual(@as(usize, 2), c.cd.deck.waivers.len);
    try expectContains(try printOf(&c), &.{
        "stage gross\nrule m1.w",
        "stage fine\nrule m1.s",
        "stage last\n",
        "corner cmax met1 thickness 3.96e2nm sheet 1.1e-1ohm",
        "corner cmax met2 sheet 2e-1ohm tc1 0e0/K tc2 0e0/K2",
        "waive m1.s waiver",
        "extraction rcc coupling_threshold 1e2aF",
    });
}

test "a deck with pex models survives printing" {
    // Oracle: round trip; and the refusals `docs/deck.md` states (a fill
    // layer that carries no net, a model no `device mos` declares, a key
    // missing, a substrate port that holds no net or a layer of no
    // thickness).
    const text =
        \\grid 1nm
        \\layer poly = gds(66, 20)
        \\layer diff = gds(65, 20)
        \\layer met1 = gds(68, 20)
        \\layer fill1 = gds(68, 28)
        \\layer via1 = gds(68, 44)
        \\layer gate = poly and diff
        \\connect conductors [poly, diff, met1, fill1]
        \\connect via via1 [met1, fill1]
        \\device mos gate model "nfet" terminals [poly, diff, diff]
        \\pex_tsv via1 length 50um liner 200nm liner_k 3.9
        \\pex fill1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um
        \\pex_fill fill1 floating
        \\pex_device "nfet" gate_contact_cap 0.3aF/um gate_diffusion_cap 0.25aF/um
        \\pex_substrate ports [diff] backside grounded profile [(3um, 10), (300um, 0.01)]
        \\
    ;
    var c = try roundTripText("pex models", text);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.cd.deck.pex_models.fill.items.len);
    const swaps = [_][2][]const u8{
        .{ "pex_fill fill1", "pex_fill gate" },
        .{ "pex_device \"nfet\"", "pex_device \"pfet\"" },
        .{ " gate_diffusion_cap 0.25aF/um", "" },
        .{ "floating", "sometimes" },
        .{ "pex_tsv via1", "pex_tsv met1" },
        .{ " liner_k 3.9", "" },
        .{ "ports [diff]", "ports [gate]" },
        .{ "(3um, 10)", "(0um, 10)" },
        .{ " backside grounded", "" },
        .{ "backside grounded", "backside wet" },
    };
    try expectRefusals(text, &swaps);
}

test "a deck with matching statements survives printing" {
    // Oracle: round trip, each value written in its key's unit (3.9e-9 V·m
    // is 3.9e0mV·um, 5e-9 m is 5e-1%·um, by hand); and the refusals
    // `docs/deck.md` states (a model no device declares, a key of another
    // kind's or unit, a basis other than pair or single, a value that is
    // not positive, a statement of nothing).
    const text =
        \\grid 1nm
        \\layer poly = gds(66, 20)
        \\layer diff = gds(65, 20)
        \\layer gate = poly and diff
        \\device mos gate model "nfet" terminals [poly, diff, diff]
        \\device resistor poly model "rpoly" terminals [poly, poly]
        \\matching "nfet" single avt 3.9mV·um abeta 0.5%·um svt 1.63uV/um
        \\matching "rpoly" pair ar 1.5%.um
        \\
    ;
    var c = try roundTripText("matching", text);
    defer c.deinit();
    try expectContains(try printOf(&c), &.{ "matching \"nfet\" single avt 3.9e0mV·um abeta 5e-1%·um svt 1.63e0uV/um\n", "matching \"rpoly\" pair ar 1.5e0%·um\n" });
    const swaps = [_][2][]const u8{
        .{ "matching \"rpoly\"", "matching \"cpoly\"" },
        .{ "pair ar", "pair avt" },
        .{ "\"rpoly\" pair ar", "\"rpoly\" pair ka" },
        .{ "single", "double" },
        .{ "3.9mV·um", "-3.9mV·um" },
        .{ " ar 1.5%.um", "" },
    };
    try expectRefusals(text, &swaps);
}

test "a deck with report lines survives printing" {
    // Oracle: round trip; and the refusals `docs/deck.md` states (two or
    // more points, each `(x, y)`; a named net; a reach of zero or more,
    // stated once; on the deck's grid).
    const text =
        \\grid 5nm
        \\layer met1 = gds(68, 20)
        \\report p2p "VDD" at [(10um, 20um), (150um, -20um), (0.5um, 90um)]
        \\report p2p "a" at [(0um, 0um), (1um, 0um)]
        \\report p2p "VDD" at [(1um, 2um), (3.5um, -4um)]
        \\report coupling "a" "b"
        \\report cluster 2.5um
        \\
    ;
    var c = try roundTripText("report lines", text);
    defer c.deinit();
    const r = c.cd.deck.reports;
    try testing.expectEqualStrings("VDD", r.p2p.items[0].net);
    try testing.expectEqualSlices([2]i64, &.{ .{ 10_000, 20_000 }, .{ 150_000, -20_000 }, .{ 500, 90_000 } }, r.p2p.items[0].points);
    try testing.expectEqualSlices([2]i64, &.{ .{ 1000, 2000 }, .{ 3500, -4000 } }, r.p2p.items[2].points);
    try testing.expectEqual(@as(?i64, 2500), r.cluster);
    const swaps = [_][2][]const u8{
        .{ ", (1um, 0um)]", "]" },
        .{ "(1um, 0um)", "(1um)" },
        .{ "(1um, 0um)", "1um" },
        .{ "\"a\" \"b\"", "\"a\"" },
        .{ "\"a\" \"b\"", "\"a\" \"\"" },
        .{ "cluster 2.5um", "cluster -1um" },
        .{ "cluster 2.5um", "cluster 2.5um\nreport cluster 1um" },
        .{ "(0um, 0um)", "(2nm, 0um)" },
        .{ "report coupling", "report cuopling" },
        .{ " at [(0um", " [(0um" },
        .{ "(3.5um, -4um)", "(x, -4um)" },
    };
    try expectRefusals(text, &swaps);
}

test "a deck with layout edits survives printing" {
    // Oracle: round trip; and the refusals `docs/deck.md` states (an edit
    // draws on a drawn layer, `fill` states every key, `size` is positive).
    const text =
        \\grid 5nm
        \\layer met1 = gds(68, 20)
        \\layer fill1 = gds(68, 28)
        \\layer nofill = gds(68, 99)
        \\layer all1 = met1 or fill1
        \\fill fill1 for all1 size 1um space 0.5um keep 2um avoid [met1, nofill]
        \\widen met1 net "VP*" by 100nm
        \\
    ;
    var c = try roundTripText("layout edits", text);
    defer c.deinit();
    try testing.expectEqual(@as(i64, 500), c.cd.deck.edits.fill.items[0].space);
    try testing.expectEqualStrings("VP*", c.cd.deck.edits.widen.items[0].net);
    const swaps = [_][2][]const u8{
        .{ "fill fill1 for", "fill all1 for" },
        .{ "widen met1", "widen all1" },
        .{ " keep 2um", "" },
        .{ "size 1um", "size 0um" },
        .{ "avoid [met1, nofill]", "avoid [met1, nowhere]" },
    };
    try expectRefusals(text, &swaps);
}
