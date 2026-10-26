//! Rules `pdks/sky130.deck` states from the SKY130 periphery manual (and a
//! few from the gf180mcu and IHP SG13G2 decks), each drawn by hand at the
//! manual's limit and one grid step (5 nm) inside it. Ported from the root
//! tests/sky130_rules.rs. The deck's DRC rows are typed by
//! `drc.fromDeck`, which leaves its ERC rows to wave 4, exactly as Rust's
//! `RuleSet::from_deck` does; the store is drawn directly (Rust round-trips
//! it through GDSII, which is ingest's to test) and the derived layers
//! computed.
//!
//! Oracle: the manual's own number. Each pass layout sits exactly on the
//! limit the manual states, so a rule that measured one step wrong, or read
//! the wrong derived layer, flips one of the two cases. The pass case also
//! asserts the rule ran over at least one shape.
//!
//! Deferred (GDSII hierarchy: cell-name scoping happens in ingest's
//! flatten): `m1_4a_holds_named_cells_to_5nm_and_m1_4_exempts_them`,
//! `li_1a_holds_vpp_cells_to_140nm`,
//! `x_25_keeps_pnp_to_its_cells_and_poly_12_exempts_its_cell`.
//! Deferred (device recognition, topology's, not DRC):
//! `a_plain_nfet_extracts_as_nfet_01v8_with_four_nets`,
//! `a_poly_resistor_has_two_distinct_heads`.
//! The ERC antenna rows (`the_sky130_antenna_rows_are_table_ig`,
//! `the_ihp_antenna_rows_switch_on_a_protection_diode`,
//! `the_gf180_antenna_rows_credit_comp_by_oxide`) are in
//! tests/check/erc/sky130_antenna.zig.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const paths = @import("paths");
const common = @import("common.zig");
const gpa = common.gpa;
const Outcome = check.report.Outcome;

/// A rectangle on a named layer: `(layer, xlo, ylo, xhi, yhi)`.
const R = struct { []const u8, i64, i64, i64, i64 };

/// What one rule did over a layout: its violations and run rows.
const Ran = struct { count: u32, all_ran: bool, examined: u64 };

// ---- private ----

/// Runs every DRC rule of `pdks/<deck>.deck` over `rects`: rule `id`'s
/// violations and whether each of its rows ran.
fn run(deck: []const u8, id: []const u8, rects: []const R) !Ran {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/pdks/{s}.deck", .{ paths.root, deck });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.deck.Diag = .{};
    const parsed = try ingest.deck.parseDeck(a, gpa, text, try geom.Grid.init(1000), &strings, &diag);
    var lb = testgen.shapes.LayoutBuilder.init(@intCast(parsed.layers.len()));
    defer lb.deinit(gpa);
    for (rects) |r| {
        const layer = parsed.layers.id(&strings, r[0]) orelse std.debug.panic("the deck declares no layer {s}", .{r[0]});
        _ = try lb.rect(gpa, @backingInt(layer), r[1], r[2], r[3], r[4]);
    }
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    try ingest.layout.deriveLayersInto(gpa, &store, &parsed.layers, &provenance, &strings, &.{});
    var rdiag: check.drc.params.Diagnostic = .{};
    var rs = try check.drc.fromDeck(gpa, &parsed, &strings, &rdiag);
    defer rs.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try check.drc.run(gpa, .cpu, &rs, &store, null, &sink.out, &sink.runs);
    var out: Ran = .{ .count = 0, .all_ran = true, .examined = 0 };
    var found = false;
    for (sink.runs.items) |r| {
        if (!std.mem.eql(u8, strings.resolve(r.rule), id)) continue;
        found = true;
        out.count += r.violations;
        out.all_ran = out.all_ran and r.outcome == .ran;
        out.examined += r.examined;
    }
    if (!found) std.debug.panic("the deck has no rule {s}", .{id});
    return out;
}

/// `passing` passes rule `id` of `deck` and the rule examined something;
/// `failing` does not.
fn atLimitIn(deck: []const u8, id: []const u8, passing: []const R, failing: []const R) !void {
    const pass = try run(deck, id, passing);
    try testing.expect(pass.all_ran and pass.examined > 0);
    try testing.expectEqual(@as(u32, 0), pass.count);
    try testing.expect((try run(deck, id, failing)).count > 0);
}

fn atLimit(id: []const u8, passing: []const R, failing: []const R) !void {
    return atLimitIn("sky130", id, passing, failing);
}

/// `atLimit` for a width between chosen edges, which examines only the
/// pairs closer than its limit, so a layout on the limit examines none.
fn atEdgeLimit(id: []const u8, passing: []const R, failing: []const R) !void {
    const pass = try run("sky130", id, passing);
    try testing.expect(pass.all_ran);
    try testing.expectEqual(@as(u32, 0), pass.count);
    try testing.expect((try run("sky130", id, failing)).count > 0);
}

test "licon 5a diff encloses licon by 40nm" {
    // Oracle: foundry example, sky130 licon.5a 0.040 um (SkyWater SKY130
    // periphery rules): licon drawn 40 then 35 nm inside diff, so the pass
    // layout sits on the limit and the fail layout 5 nm inside it.
    const base = [_]R{ .{ "diff", 0, 0, 1000, 500 }, .{ "nsdm", -200, -200, 1200, 700 } };
    try atLimit("licon.5a", &(base ++ [_]R{.{ "licon", 40, 165, 210, 335 }}), &(base ++ [_]R{.{ "licon", 35, 165, 205, 335 }}));
}

test "licon 14 poly licon to diff 190nm" {
    // Oracle: foundry example, sky130 licon.14 0.190 um (SkyWater SKY130
    // periphery rules): diff drawn 190 then 185 nm from the poly licon, so the
    // pass layout sits on the limit and the fail layout 5 nm inside it.
    const base = [_]R{ .{ "poly", 0, 0, 500, 500 }, .{ "licon", 165, 165, 335, 335 } };
    try atLimit("licon.14", &(base ++ [_]R{.{ "diff", 525, 0, 1000, 500 }}), &(base ++ [_]R{.{ "diff", 520, 0, 1000, 500 }}));
}

test "npc 4 npc to gate 90nm" {
    // Oracle: foundry example, sky130 npc.4 0.090 um (SkyWater SKY130
    // periphery rules): npc drawn 90 then 85 nm from the gate, so the pass
    // layout sits on the limit and the fail layout 5 nm inside it.
    const base = [_]R{ .{ "diff", 0, 0, 1000, 420 }, .{ "poly", 400, -200, 550, 620 } };
    try atLimit("npc.4", &(base ++ [_]R{.{ "npc", 640, 0, 1000, 420 }}), &(base ++ [_]R{.{ "npc", 635, 0, 1000, 420 }}));
}

test "difftap 10 nwell encloses ntap by 180nm" {
    // Oracle: foundry example, sky130 difftap.10 0.180 um (SkyWater SKY130
    // periphery rules): nwell drawn 180 then 175 nm round the n+ tap, so the
    // pass layout sits on the limit and the fail layout 5 nm inside it.
    const base = [_]R{ .{ "tap", 0, 0, 500, 500 }, .{ "nsdm", -130, -130, 630, 630 } };
    try atLimit("difftap.10", &(base ++ [_]R{.{ "nwell", -180, -180, 680, 680 }}), &(base ++ [_]R{.{ "nwell", -175, -180, 680, 680 }}));
}

test "rpm 6 rpm to nsdm 200nm" {
    // Oracle: foundry example, sky130 rpm.6 0.200 um (SkyWater SKY130
    // periphery rules): nsdm drawn 200 then 195 nm from rpm, so the pass
    // layout sits on the limit and the fail layout 5 nm inside it.
    try atLimit("rpm.6", &.{ .{ "rpm", 0, 0, 2000, 2000 }, .{ "nsdm", 2200, 0, 3000, 1000 } }, &.{ .{ "rpm", 0, 0, 2000, 2000 }, .{ "nsdm", 2195, 0, 3000, 1000 } });
}

test "poly 3 poly resistor width 330nm" {
    // Oracle: foundry example, sky130 poly.3 0.330 um (SkyWater SKY130
    // periphery rules): the resistor poly drawn 330 then 325 nm wide, so the
    // pass layout sits on the limit and the fail layout 5 nm inside it.
    try atLimit("poly.3", &.{ .{ "poly", 0, 0, 330, 2000 }, .{ "poly_rs", -100, 500, 430, 1500 } }, &.{ .{ "poly", 0, 0, 325, 2000 }, .{ "poly_rs", -100, 500, 430, 1500 } });
}

test "difftap 4 butting edge 290nm" {
    // Oracle: foundry example, sky130 difftap.4 0.290 um (SkyWater SKY130
    // periphery rules): the butting edge drawn 290 then 285 nm long, so the
    // pass layout sits on the limit and the fail layout 5 nm inside it.
    try atLimit("difftap.4", &.{ .{ "diff", 0, 0, 1000, 500 }, .{ "tap", 1000, 0, 1500, 290 } }, &.{ .{ "diff", 0, 0, 1000, 500 }, .{ "tap", 1000, 0, 1500, 285 } });
}

test "nsd 5a butted diff enclosed by 125nm" {
    // Oracle: foundry example, sky130 nsd.5a 0.125 um (SkyWater SKY130
    // periphery rules): nsdm drawn 125 then 120 nm round every edge but the
    // butting one, so the pass layout sits on the limit and the fail layout
    // 5 nm inside it.
    const base = [_]R{ .{ "diff", 0, 0, 1000, 500 }, .{ "tap", 1000, 0, 1300, 500 } };
    try atLimit("nsd.5a.butted", &(base ++ [_]R{.{ "nsdm", -125, -125, 1000, 625 }}), &(base ++ [_]R{.{ "nsdm", -120, -125, 1000, 625 }}));
}

test "m1 3a attached to huge metal 280nm" {
    // Oracle: foundry example, sky130 m1.3a 0.280 um (SkyWater SKY130
    // periphery rules): the line drawn 280 then 275 nm from the finger
    // attached to huge met1, so the pass layout sits on the limit and the
    // fail layout 5 nm inside it.
    const base = [_]R{ .{ "met1", 0, 0, 4000, 4000 }, .{ "met1", 1000, 4000, 1140, 5000 } };
    try atLimit("m1.3a", &(base ++ [_]R{.{ "met1", 1420, 4280, 1560, 4600 }}), &(base ++ [_]R{.{ "met1", 1415, 4280, 1560, 4600 }}));
}

test "licon 16 tap encloses a licon" {
    // Oracle: foundry example, sky130 licon.16 (every tap encloses a licon,
    // SkyWater SKY130 periphery rules): a licon touching the tap's edge from
    // inside is enclosed, one 5 nm across it is not.
    try atLimit("licon.16", &.{ .{ "tap", 0, 0, 500, 500 }, .{ "licon", 330, 165, 500, 335 } }, &.{ .{ "tap", 0, 0, 500, 500 }, .{ "licon", 335, 165, 505, 335 } });
}

test "gf180 df 11 butting comp edge 300nm" {
    // Oracle: foundry example, gf180 DF.11 0.3 um (GlobalFoundries GF180MCU
    // design rules): the butting COMP edge drawn 300 then 295 nm long, so the
    // pass layout sits on the limit and the fail layout 5 nm inside it.
    const implants = [_]R{ .{ "nplus", -100, -100, 1000, 400 }, .{ "pplus", 1000, -100, 2100, 400 } };
    try atLimitIn("gf180mcu", "DF.11", &(implants ++ [_]R{.{ "comp", 0, 0, 2000, 300 }}), &(implants ++ [_]R{.{ "comp", 0, 0, 2000, 295 }}));
}

test "ihp m1 e wide line long run 220nm" {
    // Oracle: foundry example, IHP M1.e 0.22 um (IHP SG13G2 layout rules): a
    // 305 nm wide line with a 1005 nm run, its neighbour 220 then 215 nm away,
    // so the pass layout sits on the limit and the fail layout 5 nm inside it.
    const wide: R = .{ "metal1", 0, 0, 305, 1005 };
    try atLimitIn("ihp_sg13g2", "M1.e", &.{ wide, .{ "metal1", 525, 0, 725, 1005 } }, &.{ wide, .{ "metal1", 520, 0, 720, 1005 } });
}

test "ihp cnt h metal1 covers cont" {
    // Oracle: foundry example, IHP Cnt.h (Metal1 covers Cont, enclosure 0;
    // IHP SG13G2 layout rules): metal1 exactly over the contact passes,
    // shifted 5 nm it leaves an edge uncovered.
    try atLimitIn("ihp_sg13g2", "Cnt.h", &.{ .{ "cont", 0, 0, 160, 160 }, .{ "metal1", 0, 0, 160, 160 } }, &.{ .{ "cont", 0, 0, 160, 160 }, .{ "metal1", 5, 0, 165, 160 } });
}

test "capm 4 capm encloses via3 on the plate by 140nm" {
    // Oracle: foundry example, sky130 capm.4 0.140 um (SkyWater SKY130
    // periphery rules): via3 drawn 140 then 135 nm inside capm, so the pass
    // layout sits on the limit and the fail layout 5 nm inside it. A via3
    // with no capm over it is not the rule's.
    const plain: R = .{ "via3", 5000, 0, 5200, 200 };
    try atLimit("capm.4", &.{ .{ "capm", 0, 0, 2000, 2000 }, .{ "via3", 140, 140, 340, 340 }, plain }, &.{ .{ "capm", 0, 0, 2000, 2000 }, .{ "via3", 135, 140, 335, 340 }, plain });
    try testing.expectEqual(@as(u32, 0), (try run("sky130", "capm.4", &.{plain})).count);
}

test "cap2m 4 cap2m encloses via4 on the plate by 200nm" {
    // Oracle: foundry example, sky130 cap2m.4 0.200 um (SkyWater SKY130
    // periphery rules): via4 drawn 200 then 195 nm inside cap2m, so the pass
    // layout sits on the limit and the fail layout 5 nm inside it. A via4
    // with no cap2m over it is not the rule's.
    const plain: R = .{ "via4", 5000, 0, 5800, 800 };
    try atLimit("cap2m.4", &.{ .{ "cap2m", 0, 0, 2000, 2000 }, .{ "via4", 200, 200, 1000, 1000 }, plain }, &.{ .{ "cap2m", 0, 0, 2000, 2000 }, .{ "via4", 195, 200, 995, 1000 }, plain });
    try testing.expectEqual(@as(u32, 0), (try run("sky130", "cap2m.4", &.{plain})).count);
}

test "m1 1 diagonal neck at overlapping rectangles" {
    // m1.1 on the field report's repro (`neck.gds`): two 300 nm met1 squares
    // overlapping at a corner leave a 134.5 nm diagonal neck, one violation on
    // the one merged figure.
    // Oracle: foundry example, sky130 m1.1 (0.14 um), by hand: the concave
    // corners are 90 by 100 apart, a neck of sqrt(18 100) = 134.5 nm, one
    // violation; moved 10 nm, 100 by 100, 141.4 nm, clean.
    const first: R = .{ "met1", 17020, 9950, 17320, 10250 };
    try testing.expectEqual(@as(u32, 1), (try run("sky130", "m1.1", &.{ first, .{ "met1", 17230, 9750, 17530, 10050 } })).count);
    try testing.expectEqual(@as(u32, 0), (try run("sky130", "m1.1", &.{ first, .{ "met1", 17220, 9750, 17520, 10050 } })).count);
}

test "npc 5 npc reaches at most 95nm past slotted poly" {
    // Oracle: foundry example, sky130 npc.5 0.095 um (SkyWater SKY130
    // periphery rules; a slotted licon is 0.19 x 2.0 um, table C3): npc drawn
    // 95 then 100 nm past the resistor poly, so the pass layout sits on the
    // limit and the fail layout 5 nm past it.
    const base = [_]R{ .{ "poly", 0, 0, 350, 3000 }, .{ "licon", 80, 500, 270, 2500 } };
    try atLimit("npc.5", &(base ++ [_]R{.{ "npc", -95, -95, 445, 3095 }}), &(base ++ [_]R{.{ "npc", -100, -95, 445, 3095 }}));
}

test "licon 2b slotted licons end to end 350nm" {
    // Oracle: foundry example, sky130 licon.2b 0.350 um "when both the edges
    // are 0.19um in length" (SkyWater SKY130 periphery rules): two 0.19 x 2.0
    // um bars drawn 350 then 345 nm apart along their length.
    try atLimit("licon.2b", &.{ .{ "licon", 0, 0, 190, 2000 }, .{ "licon", 0, 2350, 190, 4350 } }, &.{ .{ "licon", 0, 0, 190, 2000 }, .{ "licon", 0, 2345, 190, 4345 } });
}

test "rpm 1g one licon in a 0p35 terminal" {
    // Oracle: foundry example, sky130 rpm.1g "Only 1 licon is allowed in
    // `xhrpoly_0p35` `prec_resistor_terminal`" (SkyWater SKY130 periphery
    // rules; the terminal is `prec_resistor` AND li, table C3): a 0.35 um
    // resistor's head holds its slotted licon, then that and a square licon.
    const base = [_]R{
        .{ "poly", 0, 0, 350, 10_000 },      .{ "poly_rs", -100, 3000, 450, 7000 },
        .{ "rpm", -300, -300, 650, 10_300 }, .{ "psdm", -300, -300, 650, 10_300 },
        .{ "li", 0, 0, 350, 2900 },          .{ "licon", 80, 300, 270, 2300 },
    };
    try atLimit("rpm.1g", &base, &(base ++ [_]R{.{ "licon", 90, 2500, 260, 2670 }}));
}

test "varac 2 varactor channel width 1um" {
    // Oracle: foundry example, sky130 varac.2 1.000 um (SkyWater SKY130
    // periphery rules): the tap under the varactor poly drawn 1000 then 995
    // nm across the channel.
    const base = [_]R{ .{ "nwell", -1000, -1000, 2000, 2000 }, .{ "poly", 400, -300, 580, 1300 } };
    try atEdgeLimit("varac.2", &(base ++ [_]R{.{ "tap", 0, 0, 1000, 1000 }}), &(base ++ [_]R{.{ "tap", 0, 0, 1000, 995 }}));
}

test "poly 13 hv channel length 500nm" {
    // Oracle: foundry example, sky130 poly.13 0.500 um "Min width of poly
    // over diff inside Hvi" (SkyWater SKY130 periphery rules): the gate drawn
    // 500 then 495 nm long.
    const base = [_]R{ .{ "diff", 0, 0, 2000, 1000 }, .{ "hvi", -1000, -1000, 3000, 2000 } };
    try atEdgeLimit("poly.13", &(base ++ [_]R{.{ "poly", 500, -300, 1000, 1300 }}), &(base ++ [_]R{.{ "poly", 500, -300, 995, 1300 }}));
}

test "poly 10 and 11 gate shapes" {
    // Oracle: foundry example, sky130 poly.11 "No 90 deg turns of poly on
    // diff" and poly.10 "Poly can't overlap inner corners of diff" (SkyWater
    // SKY130 periphery rules), each drawn as the rule's text describes.
    const diff: R = .{ "diff", 0, 0, 2000, 1000 };
    const straight = [_]R{ diff, .{ "poly", 500, -300, 650, 1300 } };
    try atLimit("poly.11", &straight, &(straight ++ [_]R{.{ "poly", 500, 400, 1500, 550 }}));
    const l_diff = [_]R{ diff, .{ "diff", 0, 1000, 1000, 2000 } };
    try atLimit("poly.10", &(l_diff ++ [_]R{.{ "poly", 300, -300, 450, 2300 }}), &(l_diff ++ [_]R{.{ "poly", 900, -300, 1050, 2300 }}));
}

test "lvtn 10 nwell encloses lvtn by 380nm" {
    // Oracle: foundry example, sky130 lvtn.10 0.380 um (SkyWater SKY130
    // periphery rules): lvtn drawn 380 then 375 nm inside the n-well.
    const well: R = .{ "nwell", 0, 0, 2000, 2000 };
    try atLimit("lvtn.10", &.{ well, .{ "lvtn", 380, 380, 1620, 1620 } }, &.{ well, .{ "lvtn", 375, 380, 1620, 1620 } });
}
