//! The deck language's rules and layers: what each spelling lowers to.
//! Ported from crates/ingest/tests/deck_text.rs (the rule, layer, device and
//! reuse tests); the `lvs` tests are in deck_lvs.zig, the error classes and
//! the parasitic stack in deck_errors.zig.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const paths = @import("paths");
const fx = @import("deck_fixture.zig");
const ok = fx.ok;
const oneError = fx.oneError;
const expectRow = fx.expectRow;
const expectStrings = fx.expectStrings;

// ---- private ----

/// The fenced block of docs/src/reference/deck/README.md that opens with
/// `marker`, from the line after its fence.
fn example(gpa: std.mem.Allocator, marker: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/docs/src/reference/deck/README.md", .{paths.root});
    defer gpa.free(path);
    const spec = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .unlimited);
    defer gpa.free(spec);
    const fence = (std.mem.indexOfScalar(u8, marker, '\n') orelse return error.TestUnexpectedResult) + 1;
    const start = (std.mem.indexOf(u8, spec, marker) orelse return error.TestUnexpectedResult) + fence;
    const end = start + (std.mem.indexOf(u8, spec[start..], "```") orelse return error.TestUnexpectedResult);
    return gpa.dupe(u8, spec[start..end]);
}

test "a one-line rule lowers to the engine kind and grid units" {
    // Oracle: hand-derived. Each check's engine kind is the rule reference
    // table in src/check/root.zig (Deck, Kind), and the values are the deck's
    // units converted by hand on the 1 nm grid: 0.14 um is 140 dbu, 0.083
    // um2 is 83 000 dbu2, 80 % is 0.8.
    var o = try ok("rule m1.1 width(met1) >= 0.14um\n" ++
        "rule m1.2 width(met1) <= 10um\n" ++
        "rule m1.4 enclosure(mcon, met1) >= 30nm\n" ++
        "rule m1.5 enclosure(mcon, met1, opposite) >= 60nm\n" ++
        "rule m1.6 area(met1) >= 0.083um2\n" ++
        "rule d.1 density(met1; window: 100um, step: 50um) <= 80%\n" ++
        "rule a.1 angle(; allowed: [0deg, 90deg, 45deg])\n");
    defer o.deinit();
    try expectRow(try o.rule("m1.1"), "min_width", &.{"met1"}, &.{"limit=140dbu"});
    try expectRow(try o.rule("m1.2"), "max_width", &.{"met1"}, &.{"limit=10000dbu"});
    // The engine takes outer first.
    try expectRow(try o.rule("m1.4"), "min_enclosure", &.{ "met1", "mcon" }, &.{"limit=30dbu"});
    try expectRow(try o.rule("m1.5"), "asymmetric_enclosure", &.{ "met1", "mcon" }, &.{"min_one_side=60dbu"});
    try expectRow(try o.rule("m1.6"), "min_area", &.{"met1"}, &.{"limit=83000dbu2"});
    try expectRow(try o.rule("d.1"), "density", &.{"met1"}, &.{ "window=100000dbu", "step=50000dbu", "limit=0.8", "maximum=true" });
    try expectRow(try o.rule("a.1"), "angle", &.{}, &.{ "angle=#0", "angle=#90", "angle=#45" });
    var p = try ok("rule x.2 angle(poly; allowed: [0deg, 90deg])\n");
    defer p.deinit();
    const r = (try p.rules())[0];
    try testing.expectEqualStrings("x.2", r.id);
    try expectRow(r, "angle", &.{"poly"}, &.{ "angle=#0", "angle=#90" });
}

test "the overlay and cut checks lower to their engine kinds" {
    // Oracle: the spelling of each check in docs/src/reference/drc/cut.md and
    // overlay.md, and the engine kind and parameters each lowers to (the rule
    // reference in src/check/root.zig).
    var o = try ok("rule c2c space(mcon, center) >= 300nm\n" ++
        "rule adj adjacent_space(mcon; cuts: 3, within: 250nm) >= 220nm\n" ++
        "rule adjc adjacent_space(mcon, center; cuts: 3, within: 300nm) >= 300nm\n" ++
        "rule ccs cut_class_space(licon; short: [170nm, 190nm], long: [170nm, 2000nm],\n" ++
        "    space: [[170nm, 170nm, 510nm, 510nm], [170nm, 170nm, 510nm, 510nm],\n" ++
        "            [510nm, 510nm, 350nm, 510nm], [510nm, 510nm, 510nm, 510nm]])\n" ++
        "rule mc min_cuts(mcon, met1, li; width: 1um) >= 2\n" ++
        "rule mcw min_cuts(mcon, met1, li; width: 1um, within: 300nm) >= 2\n" ++
        "rule vs via_stack(licon, mcon) <= 1\n" ++
        "rule bend bend(poly, diff)\n" ++
        "rule cov covers_corner(poly, diff)\n" ++
        "rule maxe enclosure(licon, li) <= 95nm\n" ++
        "rule nce enclosure(licon, li, noncoincident) >= 380nm\n" ++
        "rule we enclosure(mcon, met1; width: 1um) >= 20nm\n" ++
        "rule wb enclosure(mcon, met1, opposite; below: 1um) >= 50nm\n" ++
        "rule wwb enclosure(mcon, met1; width: 1um, below: 2um) >= 20nm\n" ++
        "rule most contains(diff, licon) <= 1\n" ++
        "rule exact contains(diff, licon) == 2\n" ++
        "rule fw full_width(mcon, met1)\n" ++
        "rule ps space(licon, poly, projection) >= 235nm\n");
    defer o.deinit();
    try expectRow(try o.rule("c2c"), "cut_spacing", &.{"mcon"}, &.{ "limit=300dbu", "center=true" });
    try expectRow(try o.rule("adj"), "cut_spacing", &.{"mcon"}, &.{ "adjacent=#3", "within=250dbu", "limit=220dbu", "center=false" });
    try expectRow(try o.rule("adjc"), "cut_spacing", &.{"mcon"}, &.{ "adjacent=#3", "within=300dbu", "limit=300dbu", "center=true" });
    const ccs = try o.rule("ccs");
    try testing.expectEqualStrings("cut_class_spacing", ccs.kind);
    try expectStrings(&.{"licon"}, ccs.layers);
    try expectStrings(&.{ "class_short=170dbu", "class_short=190dbu", "class_long=170dbu", "class_long=2000dbu" }, ccs.params[0..4]);
    try testing.expectEqual(4 + 16, ccs.params.len);
    try expectRow(try o.rule("mc"), "minimum_cut", &.{ "mcon", "met1", "li" }, &.{ "width=1000dbu", "min_count=#2" });
    try expectRow(try o.rule("mcw"), "minimum_cut", &.{ "mcon", "met1", "li" }, &.{ "width=1000dbu", "within=300dbu", "min_count=#2" });
    try expectRow(try o.rule("vs"), "via_stack", &.{ "licon", "mcon" }, &.{ "max_height=#1", "single=false" });
    try expectRow(try o.rule("bend"), "gate_corner", &.{ "poly", "diff" }, &.{"of_reference=false"});
    try expectRow(try o.rule("cov"), "gate_corner", &.{ "poly", "diff" }, &.{"of_reference=true"});
    // Enclosures take the outer layer first.
    try expectRow(try o.rule("maxe"), "max_enclosure", &.{ "li", "licon" }, &.{"limit=95dbu"});
    try expectRow(try o.rule("nce"), "noncoincident_enclosure", &.{ "li", "licon" }, &.{"limit=380dbu"});
    try expectRow(try o.rule("we"), "min_enclosure", &.{ "met1", "mcon" }, &.{ "wire_width=1000dbu", "limit=20dbu" });
    try expectRow(try o.rule("wb"), "asymmetric_enclosure", &.{ "met1", "mcon" }, &.{ "wire_below=1000dbu", "min_one_side=50dbu" });
    try expectRow(try o.rule("wwb"), "min_enclosure", &.{ "met1", "mcon" }, &.{ "wire_width=1000dbu", "wire_below=2000dbu", "limit=20dbu" });
    try expectRow(try o.rule("most"), "must_contain", &.{ "diff", "licon" }, &.{"max_count=#1"});
    try expectRow(try o.rule("exact"), "must_contain", &.{ "diff", "licon" }, &.{"count=#2"});
    try expectRow(try o.rule("fw"), "full_width", &.{ "met1", "mcon" }, &.{});
    try expectRow(try o.rule("ps"), "projection_spacing", &.{ "licon", "poly" }, &.{"limit=235dbu"});
}

test "die density lowers with an optional boundary layer" {
    // Oracle: foundry example, gf180 M1.4 (30 % over the die), lowered by the
    // `global_density` and `density` rows of docs/src/reference/drc/density.md
    // (DRC-070, DRC-071); the fractions and the boundary layer's place are read
    // off the rule text.
    var o = try ok("rule M1.4 global_density(met1) >= 30%\n" ++
        "rule M1.k global_density(met1, met3) <= 60%\n" ++
        "rule M1.j density(met1, met3; window: 800um, step: 400um) >= 35%\n");
    defer o.deinit();
    const got = try o.rules();
    try expectRow(got[0], "global_density", &.{"met1"}, &.{ "limit=0.3", "maximum=false" });
    try expectStrings(&.{ "met1", "met3" }, got[1].layers);
    try expectStrings(&.{ "limit=0.6", "maximum=true" }, got[1].params);
    try testing.expectEqualStrings("density", got[2].kind);
    try expectStrings(&.{ "met1", "met3" }, got[2].layers);
}

test "an exact cut size lowers to both sides" {
    // Oracle: foundry example, sky130 licon.1 (0.17 um square), and
    // docs/src/reference/drc/dimension.md (DRC-013)'s `size(L) == len x len`:
    // 170 nm on the 1 nm grid is 170 dbu a side; `>=` is not the documented
    // comparator.
    var o = try ok("rule licon.1 size(licon) == 0.17um x 0.17um\nrule ct.slot size(licon) == 170nm x 510nm\n");
    defer o.deinit();
    const got = try o.rules();
    try testing.expectEqualStrings("licon.1", got[0].id);
    try expectRow(got[0], "cut_size", &.{"licon"}, &.{ "width=170dbu", "height=170dbu" });
    try expectStrings(&.{ "width=170dbu", "height=510dbu" }, got[1].params);
    try oneError("rule licon.1 size(licon) >= 170nm x 170nm\n", "==");
}

test "erc named arguments convert to engine units and none leaves a param out" {
    // Oracle: hand-derived unit conversions: 0.28 mA/um is 280 A/m, 15 mA is
    // 15 000 uA, 105 C is 378.15 K, 1.8 V is 1800 mV, 50 um is 50 000 dbu, 20 %
    // is 0.2; and docs/src/reference/deck/rules.md (Arguments): `none` states a
    // parameter absent, so it lowers to no row.
    var o = try ok(
        \\rule em.li warning electromigration(li, licon,
        \\    max_density: 0.28mA/um, max_current_per_cut: 80uA, blech_limit: 15mA,
        \\    reference_temperature: 105C, activation_energy: 0.9eV, current_exponent: 2)
        \\rule hv hv_domain(; max_delta: 1.8V, isolation: none)
        \\rule cmp density_cmp(met1; window: 50um x 40um, step: 25um x 20um, min: 20%, max: none,
        \\    max_delta: none, partial_windows: false, cmp: none)
        \\
    );
    defer o.deinit();
    const got = try o.rules();
    try expectStrings(&.{ "max_density=280", "max_current_per_cut=80", "blech_limit=15000", "reference_temperature=378.15", "activation_energy_ev=0.9", "current_exponent=2", "warning=true" }, got[0].params);
    try expectStrings(&.{ "li", "licon" }, got[0].layers);
    try expectStrings(&.{"max_domain_delta=1800"}, got[1].params);
    try expectStrings(&.{ "window_x=50000dbu", "window_y=40000dbu", "step_x=25000dbu", "step_y=20000dbu", "min_density=0.2", "include_partial_windows=false" }, got[2].params);
}

test "model lists lower to one param per model and must name a device" {
    // Oracle: docs/src/reference/erc/voltage.md (ERC-F2, Options) and
    // docs/src/reference/deck/README.md (Names): `models` is a list of quoted
    // names, each declared by a `device` line, and `none` leaves the parameter
    // out; 1.98 V is 1980 mV.
    var o = try ok(
        \\device mos poly model "nfet" terminals [poly, diff, diff]
        \\device mos met3 model "pfet" terminals [poly, diff, diff]
        \\rule ox gate_oxide(; models: ["nfet", "pfet"], max: 1.98V)
        \\rule wb well_bias(; pmos: ["pfet"], nmos: none)
        \\rule ls missing_level_shifter(; shifters: none)
        \\rule esd esd_topological(met1; clamps: ["nfet"])
        \\let both = ["nfet", "pfet"]
        \\rule ds drain_source(; models: both, max: 3.3V)
        \\
    );
    defer o.deinit();
    const got = try o.rules();
    try expectStrings(&.{ "model=\"nfet\"", "model=\"pfet\"", "max_voltage=1980" }, got[0].params);
    try expectStrings(&.{"pmos=\"pfet\""}, got[1].params);
    try expectStrings(&.{}, got[2].params);
    try expectStrings(&.{"clamp=\"nfet\""}, got[3].params);
    try expectStrings(&.{ "model=\"nfet\"", "model=\"pfet\"", "max_voltage=3300" }, got[4].params);
    try oneError("rule ox gate_oxide(; models: [nfet], max: 1.98V)", "a model name in quotes");
    try oneError("rule ox gate_oxide(; models: [], max: 1.98V)", "needs at least one model");
    try fx.malformed(
        \\device mos poly model "nfet" terminals [poly, diff, diff]
        \\rule ox gate_oxide(; models: ["nfet_typo"], max: 1.98V)
        \\
    , "nfet_typo");
}

test "if reads a block by a switch" {
    // Oracle: the definition in docs/src/reference/deck/reuse.md (if), expanded
    // by hand: with `floating = false` only the `not` block's rule is read,
    // once per metal of the loop, and the `true` block's rule is not.
    var o = try ok(
        \\let floating = false
        \\if floating {
        \\    rule x.22 width(met1) >= 140nm
        \\}
        \\for m in [met1, met2] {
        \\    if not floating {
        \\        rule {m}.w width(m) >= 140nm
        \\    }
        \\}
        \\
    );
    defer o.deinit();
    const got = try o.rules();
    try testing.expectEqual(2, got.len);
    try testing.expectEqualStrings("met1.w", got[0].id);
    try testing.expectEqualStrings("met2.w", got[1].id);
    try oneError("if floating {\n}\n", "`floating` is not bound");
    try oneError("let w = 140nm\nif w {\n}\n", "`if` takes a name bound to true or false");
    try oneError("let on = true\nif on {\nrule a width(met1) >= 140nm\n", "unclosed `{`");
}

test "let and for expand with interpolated ids" {
    // Oracle: the definition in docs/src/reference/deck/reuse.md (let, for),
    // expanded by hand: a width and a space rule per metal in list order, then
    // a `max` rule per metal of the second loop; met3's limit is 300 nm and
    // `wide` 1 um, 300 and 1000 dbu.
    var o = try ok(
        \\let metals = [(met1, 140nm), (met2, 140nm), (met3, 300nm)]
        \\for (m, w) in metals {
        \\    rule {m}.width width(m) >= w
        \\    rule {m}.space space(m) >= w
        \\}
        \\let wide = 1um
        \\for m in [met1, met2] {
        \\    rule {m}.max width(m) <= wide
        \\}
        \\
    );
    defer o.deinit();
    const got = try o.rules();
    const ids = [_][]const u8{ "met1.width", "met1.space", "met2.width", "met2.space", "met3.width", "met3.space", "met1.max", "met2.max" };
    try testing.expectEqual(ids.len, got.len);
    for (ids, got) |want, row| try testing.expectEqualStrings(want, row.id);
    try expectStrings(&.{"met3"}, got[4].layers);
    try expectStrings(&.{"limit=300dbu"}, got[4].params);
    try expectStrings(&.{"limit=1000dbu"}, got[7].params);
}

test "derived layers fold one operator and nest the rest" {
    // Oracle: hand count. `gate = poly and diff` is one operator, one row;
    // `x = gate or li not met1` is two, folded left to right, so `x` plus one
    // hidden intermediate `x#1`: the eight drawn layers and three more.
    var o = try ok("layer gate = poly and diff\nlayer x = gate or li not met1\n");
    defer o.deinit();
    try testing.expectEqual(8 + 3, o.d().layers.len());
    try testing.expect(o.d().layers.isDerived(o.layer("x")));
    try testing.expect(o.d().layers.id(&o.strings, "x#1") != null);
}

test "connectivity devices and pex lower" {
    // Oracle: construct-from-answer. Each statement's values are read back as
    // written: three conductors, one via, one label layer, the escaped model
    // name unescaped, and the `pex` row's 360 nm, 1.376 um (1376 nm) and
    // 25.8 aF/um2, bit for bit.
    var o = try ok(
        \\layer gate = poly and diff
        \\connect conductors [poly, li, met1]
        \\connect touch_within_layer
        \\connect via mcon [li, met1]
        \\connect label met2 names met1
        \\device mos gate model "nfet \"01v8\"" terminals [poly, diff, diff]
        \\pex met1 thickness 360nm height 1.376um sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um
        \\
    );
    defer o.deinit();
    const c = o.d().connectivity;
    try testing.expectEqual(3, c.conductors.len);
    try testing.expect(c.intra_layer_touch);
    try testing.expectEqual(1, c.via_cut.len);
    try testing.expectEqual(1, c.label_layer.len);
    try testing.expectEqualStrings("nfet \"01v8\"", o.strings.resolve(o.d().devices.model[0]));
    const met1 = o.at("met1");
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 360.0))), @as(u64, @bitCast(o.d().stack.thickness_nm[met1])));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1376.0))), @as(u64, @bitCast(o.d().stack.height_nm[met1])));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 25.8))), @as(u64, @bitCast(o.d().stack.area_cap_af_um2[met1])));
}

test "device values lower per recogniser and belong to their kind" {
    // Oracle: hand-derived conversions (0.3 kohm is 300 ohm, 2 fF/um2 is
    // 2000 aF/um2, a value left out is null), and
    // docs/src/reference/deck/devices.md (Values a device states): `sheet` is a
    // resistor's, `area_cap` and `fringe_cap` a capacitor's, each optional and
    // given once.
    var o = try ok(
        \\device resistor poly model "rpoly" terminals [li, li] sheet 0.3kohm
        \\device capacitor met2 model "cmim" terminals [met2, met1] area_cap 2fF/um2 fringe_cap 190aF/um
        \\device capacitor met3 model "cvar" terminals [met3, met2] area_cap 1fF/um2
        \\device mos diff model "nfet" terminals [poly, diff, diff]
        \\
    );
    defer o.deinit();
    try testing.expectEqualSlices(ingest.deck.DeviceValue, &.{
        .{ .sheet_ohm_sq = 300.0 },
        .{ .area_cap_af_um2 = 2000.0, .fringe_cap_af_um = 190.0 },
        .{ .area_cap_af_um2 = 1000.0 },
        .{},
    }, o.d().devices.value);
    const wrong = [_][2][]const u8{
        .{ "device capacitor met2 model \"c\" terminals [met2, met1] sheet 1ohm\n", "`sheet` is a resistor's value, not a capacitor's" },
        .{ "device resistor poly model \"r\" terminals [li, li] area_cap 1fF/um2\n", "`area_cap` is a capacitor's value, not a resistor's" },
        .{ "device resistor poly model \"r\" terminals [li, li] sheet 1ohm sheet 2ohm\n", "`sheet` is given twice" },
        .{ "device resistor poly model \"r\" terminals [li, li] rho 1ohm\n", "unknown device value `rho`" },
        .{ "device resistor poly model \"r\" terminals [li, li] sheet 1fF/um2\n", "a resistance" },
        // Past f64's range a decimal reads as infinite, which no device has.
        .{ "device resistor poly model \"r\" terminals [li, li] sheet 1e999ohm\n", "`sheet` is too large a number" },
    };
    for (wrong) |w| try oneError(w[0], w[1]);
}

test "an inductor states its inductance" {
    // Oracle: the language spec (docs/src/reference/deck/devices.md, Values a
    // device states): an `inductor` states its inductance in pH, nH or uH, kept
    // in nH (1.5 uH is 1500 nH); `inductance` on any other kind, or in another
    // unit, is refused.
    var o = try ok("device inductor met2 model \"spiral\" terminals [met2, met2] inductance 1.5uH\n");
    defer o.deinit();
    try testing.expectEqualSlices(ingest.deck.DeviceKind, &.{.inductor}, o.d().devices.kind);
    try testing.expectEqual(1500.0, o.d().devices.value[0].inductance_nh.?);
    try oneError("device resistor met2 model \"r\" terminals [met2, met2] inductance 1nH\n", "an inductor's value");
    try oneError("device inductor met2 model \"l\" terminals [met2, met2] inductance 1fF\n", "inductance");
}

test "a mos gate condition lowers in millivolts and takes one polarity" {
    // Oracle: the device grammar of docs/src/reference/deck/devices.md (Values
    // a device states) and the units by hand: 1 V is 1000 mV, -0.5 V is
    // -500 mV.
    var o = try ok(
        \\device mos diff model "nfet" terminals [poly, diff, diff] on_gate_min 1V
        \\device mos li model "pfet" terminals [poly, li, li] on_gate_max -0.5V
        \\
    );
    defer o.deinit();
    try testing.expectEqualSlices(ingest.deck.DeviceValue, &.{ .{ .on_gate_min_mv = 1000.0 }, .{ .on_gate_max_mv = -500.0 } }, o.d().devices.value);
    const wrong = [_][2][]const u8{
        .{ "device mos diff model \"n\" terminals [poly, diff, diff] on_gate_min 1V on_gate_max 0V\n", "not both" },
        .{ "device resistor poly model \"r\" terminals [li, li] on_gate_min 1V\n", "`on_gate_min` is a mos's value, not a resistor's" },
        .{ "device mos diff model \"n\" terminals [poly, diff, diff] on_gate_max 1nm\n", "a voltage" },
        .{ "device mos diff model \"n\" terminals [poly, diff, diff] on_gate_min 1V on_gate_min 2V\n", "`on_gate_min` is given twice" },
    };
    for (wrong) |w| try oneError(w[0], w[1]);
}

test "the example in the language spec parses" {
    // Oracle: spec example. The complete deck in
    // docs/src/reference/deck/README.md is the deck users copy; it holds six
    // rules, counted in the document.
    const text = try example(testing.allocator, "```text\n# A two-metal process");
    defer testing.allocator.free(text);
    var o = try fx.runText(text);
    defer o.deinit();
    try testing.expectEqual(null, o.err);
    try testing.expectEqual(6, o.d().rules.spec.len);
}

test "the multi-patterning example in the language spec parses" {
    // Oracle: the multi-patterning example of docs/deck.md (in git history),
    // copied here. It parses after the three layers it names are declared, and
    // each row lowers to the kind its comment says checks it
    // (docs/src/reference/drc/multi-patterning.md, DRC-101 to DRC-104).
    const text =
        \\grid 1nm
        \\layer m1 = gds(1, 0)
        \\layer m1_c1 = gds(1, 1)
        \\layer m1_c2 = gds(1, 2)
        \\rule M1.DP.opp  space(m1) >= 40nm                          # closer than any two masks allow
        \\rule M1.DP.self notch(m1) >= 80nm                          # a shape too close to itself for one mask
        \\rule M1.DP.odd  patterning(m1; colors: 2) >= 80nm          # no split exists (an odd cycle)
        \\rule M1.DP.anc  patterning(m1, m1_c1, m1_c2; colors: 2) >= 80nm   # the pre-coloured shapes cannot be honoured
        \\rule M1.S.same  space(m1 and m1_c1) >= 80nm                # same-mask spacing of coloured shapes
        \\rule M1.S.diff  space(m1 and m1_c1, m1 and m1_c2) >= 40nm  # different-mask spacing
        \\rule M1.ST.ov   overlap(m1_c1, m1_c2) >= 10nm              # a stitch overlaps at least this far
        \\rule M1.ST.sp   space(m1_c1 and m1_c2, m1.not_interacting(m1_c1 and m1_c2)) >= 80nm   # and not near other shapes
        \\rule M1.D.bal   density_balance(m1_c1, m1_c2; window: 10um, step: 5um) >= 0.8   # the masks' coverage in balance
        \\
    ;
    var o = try fx.runText(text);
    defer o.deinit();
    try testing.expectEqual(null, o.err);
    const want = [_][]const u8{ "min_spacing", "notch", "multi_patterning", "anchored_patterning", "min_spacing", "min_spacing_diff", "overlap", "min_spacing_diff", "density_balance" };
    const got = try o.rules();
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g.kind);
}

test "layer operations chain and a rule can name the result" {
    // Oracle: hand count. Each operator or operation is one layer row, the
    // last named and the others hidden (`huge`, `huge#1`; `x` and three;
    // `gate`, `gate#1`; `active`, `active#1`), so ten past the eight drawn
    // layers, and the rule reads `huge` itself.
    var o = try ok("layer huge = met1.sized(-1500nm).sized(1500nm)\n" ++
        "layer x = (met1 and met2).holes() or met3.extents()\n" ++
        "layer gate = poly.interacting(diff).not_interacting(licon)\n" ++
        "layer active = diff.with_area(>= 1um2, < 4um2).with_width(== 150nm)\n" ++
        "rule m1.3 width(huge) >= 3um\n");
    defer o.deinit();
    const huge = o.layer("huge");
    try testing.expect(o.d().layers.isDerived(huge) and !o.d().layers.isEdges(huge));
    try testing.expectEqual(8 + 10, o.d().layers.len());
    try testing.expectEqualSlices(@TypeOf(huge), &.{huge}, o.d().rules.layersOf(o.d().rules.spec[0]));
}

test "edge layers are typed and only edge operations take them" {
    // Oracle: the Edge layers section of docs/src/reference/deck/layers.md:
    // edge layers come from `.edges()` and edge operations, and only a check or
    // operation that takes edges accepts one; each refusal is a documented type
    // rule.
    var o = try ok("layer e = diff.edges()\n" ++
        "layer butt = e and poly.edges()\n" ++
        "layer e_in = e.inside_part(met1).with_length(<= 1um)\n" ++
        "layer touch = e.interacting(met1)\n");
    defer o.deinit();
    for ([_][]const u8{ "e", "butt", "e_in", "touch" }) |name| try testing.expect(o.d().layers.isEdges(o.layer(name)));
    try oneError("layer e = diff.edges()\nrule n notch(e) >= 100nm\n", "`e` is an edge layer; only a check that takes edges can use it");
    // `width` takes edges as the edge twin of its polygon check.
    var w = try ok("layer e = diff.edges()\nrule w width(e) >= 100nm\n");
    defer w.deinit();
    try testing.expectEqualStrings("edge_width", w.strings.resolve(w.d().rules.spec[0].kind));
    try oneError("layer e = diff.edges()\nconnect conductors [e]\n", "`e` is an edge layer");
    try oneError("layer e = diff.edges()\nlayer x = e and met1\n", "cannot combine an edge layer with a polygon layer");
    try oneError("layer e = diff.edges()\nlayer x = e.sized(10nm)\n", "`.sized` needs a polygon layer, not edges");
    try oneError("layer x = met1.with_length(>= 10nm)\n", "`.with_length` needs an edge layer, not polygons");
    try oneError("layer e = diff.edges()\nlayer x = met1.inside(e)\n", "`.inside` takes a polygon layer");
}

test "a layer operation checks its arguments" {
    // Oracle: the operations of docs/src/reference/deck/layers.md (Derived
    // layers): sizes on the grid, a documented operation name, a non-empty
    // range with one bound a side, a bound written with a comparator, an area
    // for `with_area`.
    const cases = [_][2][]const u8{
        .{ "layer x = met1.sized(3nm)\n", "is not a multiple of the grid" },
        .{ "layer x = met1.grow(10nm)\n", "unknown layer operation `.grow`" },
        .{ "layer x = met1.with_area(> 4um2, < 1um2)\n", "the range is empty" },
        .{ "layer x = met1.with_area(>= 1um2, > 2um2)\n", "takes one bound on each side" },
        .{ "layer x = met1.with_width(150nm)\n", "expected a bound such as `>= 1um`" },
        .{ "layer x = met1.with_area(>= 1um)\n", "needs an area" },
        .{ "layer x = met1\n", "a derived layer needs an operator" },
        .{ "layer x = met1.sized(10nm, -10nm)\n", "grows or shrinks both axes" },
        .{ "layer x = met1.edges().extended(begin: 0nm, end: 0nm, out: 0nm, in: 0nm)\n", "a box needs a width" },
        .{ "layer x = met1.edges().extended(begin: 0nm, end: 0nm, in: 5nm, out: 5nm)\n", "in that order" },
    };
    for (cases) |c| try oneError(c[0], c[1]);
}

test "warning marks a design rule as it does an electrical one" {
    // Oracle: docs/src/reference/deck/rules.md (Severity):
    // `rule <id> warning <check>` marks any rule, and the mark is the `warning`
    // flag after the rule's own parameters; a row written without it carries no
    // flag.
    var o = try ok("rule M1.bR warning space(met1) >= 220nm\nrule M1.b space(met1) >= 180nm\n");
    defer o.deinit();
    const got = try o.rules();
    try testing.expectEqualStrings("min_spacing", got[0].kind);
    try expectStrings(&.{ "limit=220dbu", "warning=true" }, got[0].params);
    try expectStrings(&.{"limit=180dbu"}, got[1].params);
}

test "presence net table and attached rows lower" {
    // Oracle: the rule reference table in src/check/root.zig (Deck, Kind) for
    // each row's kind, and the deck's values on the 1 nm grid by hand (280 nm
    // is 280 dbu, 3 um 3000, 1 um 1000; the table's cells in row order).
    var o = try ok("rule f forbidden(met3)\n" ++
        "rule c contains(diff, licon) >= 2\n" ++
        "rule i inside(licon, diff)\n" ++
        "connect conductors [met1]\n" ++
        "rule s space(met1) >= 140nm\n" ++
        "rule n space(met1; nets: same) >= 200nm\n" ++
        "rule w wide_space(met1; width: 3um) >= 280nm\n" ++
        "rule a wide_space(met1; width: 3um, attached: 280nm) >= 280nm\n" ++
        "rule t space_table(met1; prl: [0um, 1um], width: [0um, 300nm], space: [[180nm, 180nm], [180nm, 220nm]])\n");
    defer o.deinit();
    try testing.expectEqualStrings("forbidden", (try o.rule("f")).kind);
    try expectRow(try o.rule("c"), "must_contain", &.{ "diff", "licon" }, &.{"min_count=#2"});
    const i = try o.rule("i");
    try testing.expectEqualStrings("must_be_inside", i.kind);
    try expectStrings(&.{ "licon", "diff" }, i.layers);
    try testing.expectEqualStrings("min_spacing", (try o.rule("s")).kind);
    const n = try o.rule("n");
    try testing.expectEqualStrings("net_spacing", n.kind);
    try expectStrings(&.{ "same_net=true", "limit=200dbu" }, n.params);
    try testing.expectEqualStrings("wide_dependent_spacing", (try o.rule("w")).kind);
    const a = try o.rule("a");
    try testing.expectEqualStrings("attached_wide_spacing", a.kind);
    try expectStrings(&.{ "width_threshold=3000dbu", "attached=280dbu", "limit=280dbu" }, a.params);
    const t = try o.rule("t");
    try testing.expectEqualStrings("spacing_table", t.kind);
    try expectStrings(&.{ "prl=0dbu", "prl=1000dbu", "width=0dbu", "width=300dbu", "space=180dbu", "space=180dbu", "space=180dbu", "space=220dbu" }, t.params);
    try oneError("rule n space(met1; nets: some) >= 1um\n", "needs same or different");
}

test "a spacing table is complete and monotone" {
    // Oracle: the spacing table rules of docs/src/reference/drc/spacing.md
    // (DRC-026): `prl` and `width` start at 0 and rise, one row per width and
    // one cell per run length, and no cell smaller than the one before it in
    // its row or column.
    const gpa = testing.allocator;
    const rows = "[[180nm, 180nm], [180nm, 220nm]]";
    const cases = [_][4][]const u8{
        .{ "[100nm, 1um]", "[0um, 300nm]", rows, "`prl` starts at 0" },
        .{ "[0um, 1um]", "[0um, 0um]", rows, "`width` must rise strictly" },
        .{ "[0um, 1um]", "[0um, 300nm]", "[[180nm, 180nm]]", "one row per width: 2, got 1" },
        .{ "[0um, 1um]", "[0um, 300nm]", "[[180nm, 180nm], [180nm]]", "one cell per run length: 2, got 1" },
        .{ "[0um, 1um]", "[0um, 300nm]", "[[180nm, 170nm], [180nm, 220nm]]", "cannot fall along a row or down a column" },
        .{ "[0um, 1um]", "[0um, 300nm]", "[[180nm, 220nm], [180nm, 200nm]]", "cannot fall along a row or down a column" },
        .{ "[0um, 1um]", "[0um, 300nm]", "[[180, 180nm], [180nm, 220nm]]", "needs a length" },
    };
    for (cases) |c| {
        const body = try std.fmt.allocPrint(gpa, "rule t space_table(met1; prl: {s}, width: {s}, space: {s})\n", .{ c[0], c[1], c[2] });
        defer gpa.free(body);
        try oneError(body, c[3]);
    }
}

test "a rule argument may be a layer expression" {
    // Oracle: docs/src/reference/deck/layers.md (Derived layers): the
    // `forbidden(licon and poly)` form: an expression argument becomes a
    // derived layer, and a named layer stays itself.
    var o = try ok("rule x.1 forbidden(licon and poly and (diff or met1))\n" ++
        "rule x.2 space(met1.sized(10nm), met2) >= 100nm\n" ++
        "rule x.3 width(met1) >= 100nm\n");
    defer o.deinit();
    const got = try o.rules();
    for (o.d().rules.spec[0..2]) |spec| try testing.expect(o.d().layers.isDerived(o.d().rules.layersOf(spec)[0]));
    try testing.expectEqualStrings("met2", got[1].layers[1]);
    try expectStrings(&.{"met1"}, got[2].layers);
    try oneError("rule x.1 forbidden(licon and nothing)\n", "unknown layer `nothing`");
}

test "edge checks take edge layers in their edge slots" {
    // Oracle: the edge rows of the rule reference table in src/check/root.zig
    // (Deck, Kind): `length(E)` is `edge_min_length`, `space(E[, F])`
    // `edge_spacing`, `enclosure(E, L)` `edge_enclosure`, and the same names on
    // polygon layers keep their polygon kinds.
    var o = try ok("layer e = diff.edges() not poly.edges()\n" ++
        "rule l length(e) >= 290nm\n" ++
        "rule s1 space(e) >= 400nm\n" ++
        "rule s2 space(e, poly.edges()) >= 130nm\n" ++
        "rule en enclosure(e, met1) >= 125nm\n" ++
        "rule f forbidden(e.outside_part(met1))\n" ++
        "rule p space(diff, poly) >= 100nm\n" ++
        "rule q enclosure(licon, diff) >= 40nm\n");
    defer o.deinit();
    const want = [_][]const u8{ "edge_min_length", "edge_spacing", "edge_spacing", "edge_enclosure", "forbidden", "min_spacing_diff", "min_enclosure" };
    const got = try o.rules();
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g.kind);
    try oneError("rule l length(met1) >= 1um\n", "takes an edge layer; `met1` is polygons");
    try oneError("layer e = diff.edges()\nrule s space(e, met1) >= 1um\n", "takes an edge layer; `met1` is polygons");
    try oneError("layer e = diff.edges()\nrule en enclosure(e, e) >= 1um\n", "`e` is an edge layer");
}

test "a text selection needs a drawn layer and a pattern" {
    // Oracle: the `with_text` operation of docs/src/reference/deck/layers.md:
    // text is drawn on a GDS layer, and the pattern is a non-empty quoted
    // string.
    var o = try ok("layer label = gds(68, 5)\n" ++
        "layer vdd = met1.with_text(label, \"VDD*\")\n" ++
        "layer other = met1.without_text(label, \"VDD?\")\n");
    defer o.deinit();
    const vdd = o.layer("vdd");
    try testing.expect(o.d().layers.isDerived(vdd) and !o.d().layers.isEdges(vdd));
    try oneError("layer x = met1 and met2\nlayer y = met1.with_text(x, \"A\")\n", "`x` is derived; text is drawn on a GDS layer");
    try oneError("layer y = met1.with_text(met2, VDD)\n", "expected a text pattern in quotes");
    try oneError("layer y = met1.with_text(met2, \"\")\n", "an empty pattern matches no text");
}

test "a cell selection built in code is held to the parser's rules" {
    // Oracle: `lower`'s contract, "a source built by anyone lowers to a deck
    // the engines can trust as one parsed from text", against the parser's
    // rules (DRC-092): a derived receiver, a pattern range past the table, no
    // pattern, a refused glob character; the well-formed one lowers.
    const Case = struct { []const u8, u32, u32, []const u8, bool };
    const cases = [_]Case{
        .{ "met1", 0, 1, "PAD*", true },
        .{ "big", 0, 1, "PAD*", false },
        .{ "met1", 0, 2, "PAD*", false },
        .{ "met1", 0, 0, "PAD*", false },
        .{ "met1", 0, 1, "PAD[12]", false },
    };
    const gpa = testing.allocator;
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var src: ingest.deck.DeckSource = .{};
        try src.layers.append(a, .{ .name = "met1", .stream = .{ 68, 20 } });
        try src.derived.append(a, .{ .name = "big", .op = .{ .sized = .{ .dx = 10, .dy = 10 } }, .layers = &.{"met1"} });
        const receiver = try a.dupe([]const u8, &.{c[0]});
        try src.derived.append(a, .{ .name = "pad", .op = .{ .in_cells = .{ .keep = true, .first = c[1], .count = c[2] } }, .layers = receiver });
        try src.texts.append(a, c[3]);
        var strings: @import("geom").StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: ingest.deck.Diag = .{};
        const lowered = ingest.deck.lower(a, gpa, &src, &strings, &diag);
        try testing.expectEqual(c[4], if (lowered) |_| true else |_| false);
    }
}

test "a cell selection takes a drawn layer and glob patterns" {
    // Oracle: the `in_cells` operation of docs/src/reference/deck/layers.md: a
    // drawn receiver, a non-empty pattern list, KLayout's other glob characters
    // refused rather than read differently, and `max_cell_selections` (one tag
    // bit each).
    var o = try ok("layer pad = met1.in_cells(\"PAD_*\", \"pad?\")\nlayer rest = met1.not_in_cells(\"PAD_*\")\n");
    defer o.deinit();
    const pad = o.layer("pad");
    try testing.expect(o.d().layers.isDerived(pad) and !o.d().layers.isEdges(pad));
    const op = o.d().layers.op(pad).?;
    try testing.expect(op == .in_cells and op.in_cells.keep and op.in_cells.count == 2);
    try oneError("layer x = met1 and met2\nlayer y = x.in_cells(\"A\")\n", "apply it to a `gds(..)` layer");
    try oneError("layer y = (met1 and met2).not_in_cells(\"A\")\n", "apply it to a `gds(..)` layer");
    try oneError("layer y = met1.in_cells(PAD)\n", "expected a cell-name pattern in quotes");
    try oneError("layer y = met1.in_cells(\"\")\n", "an empty pattern matches no cell");
    const gpa = testing.allocator;
    for ([_][]const u8{ "[AB]*", "{A,B}", "A\\\\*" }) |refused| {
        const body = try std.fmt.allocPrint(gpa, "layer y = met1.in_cells(\"{s}\")\n", .{refused});
        defer gpa.free(body);
        try oneError(body, "takes `*` and `?` only");
    }
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(gpa);
    for (0..ingest.deck.max_cell_selections + 1) |i| try many.print(gpa, "layer s{d} = met1.in_cells(\"C{d}\")\n", .{ i, i });
    try oneError(many.items, "at most 64");
}

test "an ignored pair is listed and may not repeat or be declared" {
    // Oracle: docs/src/reference/deck/layers.md (Ignored GDS layers): "A pair
    // is ignored once, and a pair cannot be both ignored and declared", in
    // either statement order.
    var o = try ok("ignore gds(81, 4)\nignore gds(12, 0)\n");
    defer o.deinit();
    const l = o.d().layers;
    try testing.expect(l.isIgnored(81, 4) and l.isIgnored(12, 0));
    try testing.expect(!l.isIgnored(68, 20));
    try testing.expect(!l.isIgnored(81, 5));
    try oneError("ignore gds(81, 4)\nignore gds(81, 4)\n", "gds(81, 4) is already ignored");
    try oneError("ignore gds(68, 20)\n", "gds(68, 20) is ignored, but layer `met1` is declared on it");
    try oneError("ignore gds(90, 0)\nlayer late = gds(90, 0)\n", "gds(90, 0) is ignored, but layer `late` is declared on it");
    try oneError("ignore met1\n", "expected `gds(layer, datatype)`, found `met1`");
}

test "stage lines put every rule in a stage" {
    // Oracle: hand-derived (FLOW-002): the stage of each of four rules as
    // the deck writes them, and each misuse's message.
    var o = try ok("stage gross\n" ++
        "rule a width(met1) >= 140nm\n" ++
        "stage fine\n" ++
        "for m in [met2, met3] {\n    rule {m}.w width(m) >= 140nm\n}\n" ++
        "rule b space(met1) >= 140nm\n");
    defer o.deinit();
    const st = o.d().stages;
    try testing.expectEqual(2, st.name.len);
    try testing.expectEqualStrings("gross", o.strings.resolve(st.name[0]));
    try testing.expectEqualStrings("fine", o.strings.resolve(st.name[1]));
    const want = [_]struct { []const u8, u16 }{ .{ "a", 0 }, .{ "met2.w", 1 }, .{ "met3.w", 1 }, .{ "b", 1 } };
    try testing.expectEqual(want.len, st.of_rule.len);
    for (want, st.of_rule) |w, g| {
        try testing.expectEqualStrings(w[0], o.strings.resolve(g.rule));
        try testing.expectEqual(w[1], g.stage);
    }
    for (o.d().rules.spec) |spec| try testing.expect(st.of(spec.id) != null);
    var plain = try ok("rule a width(met1) >= 140nm\n");
    defer plain.deinit();
    try testing.expectEqual(0, plain.d().stages.name.len);
    try testing.expectEqual(0, plain.d().stages.of_rule.len);
    try oneError("rule a width(met1) >= 140nm\nstage late\n", "1 rules come before the first `stage` line");
    try oneError("stage one\nrule a width(met1) >= 140nm\nstage two\nstage one\n", "stage `one` is already stated");
}

test "a waive line names a rule of the deck and a layer" {
    // Oracle: hand-derived (FLOW-001): the pairs as the deck writes them, a
    // loop's id interpolated, and each misuse's message.
    var o = try ok("rule m1.1 width(met1) >= 140nm\n" ++
        "for m in [met2] {\n    rule {m}.w width(m) >= 140nm\n    waive {m}.w met3\n}\n" ++
        "waive m1.1 met3\nwaive m1.1 li\n");
    defer o.deinit();
    const want = [_][2][]const u8{ .{ "met2.w", "met3" }, .{ "m1.1", "met3" }, .{ "m1.1", "li" } };
    try testing.expectEqual(want.len, o.d().waivers.len);
    for (want, o.d().waivers) |w, g| {
        try testing.expectEqualStrings(w[0], o.strings.resolve(g.rule));
        try testing.expectEqualStrings(w[1], fx.layerName(&o, g.layer));
    }
    try oneError("rule m1.1 width(met1) >= 140nm\nwaive m1.1 met3\nwaive m1.1 met3\n", "`m1.1` is already waived by `met3`");
    try oneError("waive m1.1 nolayer\n", "nolayer");
    try fx.malformed("rule m1.1 width(met1) >= 140nm\nwaive m1.2 met3\n", "waive m1.2: no rule of the deck");
}

test "a boundary line names one drawn layer" {
    // Oracle: hand-derived: the layer as the deck writes it, and each
    // misuse's message.
    var o = try ok("boundary met3\n");
    defer o.deinit();
    try testing.expectEqualStrings("met3", fx.layerName(&o, o.d().boundary.?));
    var none = try ok("");
    defer none.deinit();
    try testing.expectEqual(null, none.d().boundary);
    try oneError("boundary met3\nboundary met2\n", "the boundary is already stated");
    try oneError("boundary nolayer\n", "nolayer");
    try fx.malformed("layer both = met1 and met2\nboundary both\n", "boundary both: a derived layer");
}

test "a netlist scale is one positive length" {
    // Oracle: hand-derived: 1um is 1000 nm, and each misuse's message.
    var o = try ok("netlist_scale 1um\n");
    defer o.deinit();
    try testing.expectEqual(1000.0, o.d().devices.netlist_scale_nm.?);
    var none = try ok("");
    defer none.deinit();
    try testing.expectEqual(null, none.d().devices.netlist_scale_nm);
    try oneError("netlist_scale 1um\nnetlist_scale 1nm\n", "the netlist scale is already stated");
    try oneError("netlist_scale 0nm\n", "netlist_scale must be positive");
    try oneError("netlist_scale 1\n", "netlist_scale");
}
