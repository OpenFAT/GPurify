//! The deck language's `lvs` controls: what each lowers to and every
//! refusal. Ported from the `lvs_*` tests of crates/ingest/tests/deck_text.rs.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const deck = ingest.deck;
const fx = @import("deck_fixture.zig");
const ok = fx.ok;
const gpa = testing.allocator;

const nfet = "device mos poly model \"nfet\" terminals [poly, diff, diff]\n";

// ---- private ----

/// The lvs body after the `nfet` device line, refused with `needle`.
fn lvsError(devices: []const u8, body: []const u8, needle: []const u8) !void {
    const text = try std.mem.concat(gpa, u8, &.{ devices, body });
    defer gpa.free(text);
    try fx.oneError(text, needle);
}

/// The lvs body after `devices`, refused as malformed with `needle`.
fn lvsMalformed(devices: []const u8, body: []const u8, needle: []const u8) !void {
    const text = try std.mem.concat(gpa, u8, &.{ devices, body });
    defer gpa.free(text);
    try fx.malformed(text, needle);
}

fn okWith(devices: []const u8, body: []const u8) !fx.Outcome {
    const text = try std.mem.concat(gpa, u8, &.{ devices, body });
    defer gpa.free(text);
    return ok(text);
}

test "lvs tolerances lower to SI on a declared model" {
    // Oracle: the language spec (deck.md, "LVS controls"), values converted
    // by hand: 1 % is 0.01, 5 nm is 5e-9 m, 0.2 um² is 2e-13 m², 2 kohm is
    // 2000 ohm, 3 fF is 3e-15 F, a part left out is zero; the parameter is
    // lowercased. Each error class is refused.
    const devices = nfet ++ "device resistor met1 model \"rpoly\" terminals [met1, met1]\ndevice capacitor met2 model \"cmim\" terminals [met2, met1]\n";
    var o = try okWith(devices,
        \\lvs tolerance "nfet" W relative 1%
        \\lvs tolerance "nfet" l relative 0.5% absolute 5nm
        \\lvs tolerance "nfet" as absolute 0.2um2
        \\lvs tolerance "rpoly" r absolute 2kohm
        \\lvs tolerance "cmim" c relative 0.02 absolute 3fF
        \\lvs tolerance "nfet" m absolute 1
        \\
    );
    defer o.deinit();
    const want = [_]struct { []const u8, []const u8, f64, f64 }{
        .{ "nfet", "w", 0.01, 0.0 },
        .{ "nfet", "l", 0.005, 5e-9 },
        .{ "nfet", "as", 0.0, 2e-13 },
        .{ "rpoly", "r", 0.0, 2000.0 },
        .{ "cmim", "c", 0.02, 3e-15 },
        .{ "nfet", "m", 0.0, 1.0 },
    };
    const got = o.d().lvs.tolerance;
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(o.id(w[0]), g.model);
        try testing.expectEqual(o.id(w[1]), g.param);
        try testing.expect(@abs(g.relative - w[2]) <= 1e-12 * @abs(w[2]));
        try testing.expect(@abs(g.absolute - w[3]) <= 1e-12 * @abs(w[3]));
    }
    const cases = [_][2][]const u8{
        .{ "lvs widen \"nfet\" w relative 1%\n", "unknown lvs control `widen`" },
        .{ "lvs tolerance \"nfet\" w by 1%\n", "unknown tolerance part `by`" },
        .{ "lvs tolerance \"nfet\" w relative 1% relative 2%\n", "`relative` is given twice" },
        .{ "lvs tolerance \"nfet\" w relative 1%\nlvs tolerance \"nfet\" W absolute 1nm\n", "`w` of \"nfet\" already has a tolerance" },
        .{ "lvs tolerance \"nfet\" w\n", "needs relative, absolute or both" },
        .{ "lvs tolerance \"nfet\" w relative 150%\n", "0% to 100%" },
        .{ "lvs tolerance \"nfet\" w absolute 1ohm\n", "a length" },
        .{ "lvs tolerance \"nfet\" w absolute -1nm\n", "zero or more" },
        .{ "lvs tolerance \"nfet\" vth0 absolute 1mV\n", "takes a relative tolerance only" },
        .{ "lvs tolerance nfet w relative 1%\n", "a model name in quotes" },
    };
    for (cases) |c| try lvsError(devices, c[0], c[1]);
    try lvsMalformed(devices, "lvs tolerance \"nfet_typo\" w relative 1%\n", "nfet_typo");
}

test "lvs ignored parameters lower and exclude a tolerance" {
    // Oracle: the language spec (deck.md, "LVS controls"): `lvs
    // ignore_parameter` lowers to `(model, parameter)`, the parameter
    // lowercased; `m` is refused, and so are a repeat, a tolerance on an
    // ignored parameter, and a model no device declares.
    var o = try okWith(nfet, "lvs ignore_parameter \"nfet\" AS\nlvs ignore_parameter \"nfet\" pd\n");
    defer o.deinit();
    try testing.expectEqualSlices(deck.ModelParam, &.{
        .{ .model = o.id("nfet"), .param = o.id("as") },
        .{ .model = o.id("nfet"), .param = o.id("pd") },
    }, o.d().lvs.ignore_parameter);
    try lvsError(nfet, "lvs ignore_parameter \"nfet\" m\n", "cannot be ignored");
    try lvsError(nfet, "lvs ignore_parameter \"nfet\" w\nlvs ignore_parameter \"nfet\" W\n", "already ignored");
    try lvsMalformed(nfet, "lvs ignore_parameter \"nfet\" w\nlvs tolerance \"nfet\" w relative 1%\n", "");
    try lvsMalformed(nfet, "lvs ignore_parameter \"pfet\" w\n", "");
}

test "lvs asymmetric names a declared transistor" {
    // Oracle: the language spec (deck.md, "LVS controls"): `lvs asymmetric`
    // lowers to the model; a model given twice, one that is no `mos` device,
    // and one no device declares are refused.
    const devices = "device mos poly model \"ldmos\" terminals [poly, diff, diff]\ndevice resistor met1 model \"rpoly\" terminals [met1, met1]\n";
    var o = try okWith(devices, "lvs asymmetric \"ldmos\"\n");
    defer o.deinit();
    try testing.expectEqualSlices(@import("geom").StrId, &.{o.id("ldmos")}, o.d().lvs.asymmetric);
    try lvsError(devices, "lvs asymmetric \"ldmos\"\nlvs asymmetric \"ldmos\"\n", "already asymmetric");
    try lvsMalformed(devices, "lvs asymmetric \"rpoly\"\n", "");
    try lvsMalformed(devices, "lvs asymmetric \"nfet\"\n", "");
}

test "lvs permute names pins by kind" {
    // Oracle: the language spec (deck.md, "LVS controls", Netgen's pin
    // names): a capacitor's `top` and `bottom` are 0 and 1, a bipolar's
    // `emitter` and `collector` 1 and 2, a transistor's `gate` and `bulk` 0
    // and 3. A pin the kind lacks, a pin with itself, an asymmetric
    // transistor's source and drain, and an undeclared model are refused.
    const devices = nfet ++ "device mos met2 model \"ldmos\" terminals [poly, diff, diff]\ndevice bjt met3 model \"npn\" terminals [met1, met2, met3]\ndevice capacitor met2 model \"cmim\" terminals [met2, met1]\n";
    var o = try okWith(devices, "lvs permute \"cmim\" bottom top\nlvs permute \"npn\" emitter collector\nlvs permute \"nfet\" gate bulk\n");
    defer o.deinit();
    try testing.expectEqualSlices(deck.Permute, &.{
        .{ .model = o.id("cmim"), .a = 1, .b = 0 },
        .{ .model = o.id("npn"), .a = 1, .b = 2 },
        .{ .model = o.id("nfet"), .a = 0, .b = 3 },
    }, o.d().lvs.permute);
    const diode = deck.pinNames(.diode);
    try testing.expectEqualStrings("anode", diode[0]);
    try testing.expectEqualStrings("cathode", diode[1]);
    for ([_][]const u8{
        "lvs permute \"cmim\" top gate\n",
        "lvs permute \"cmim\" top top\n",
        "lvs asymmetric \"ldmos\"\nlvs permute \"ldmos\" drain source\n",
        "lvs permute \"pnp\" emitter collector\n",
    }) |body| try lvsMalformed(devices, body, "");
    try lvsError(devices, "lvs permute \"cmim\" top\n", "a pin name");
}

test "lvs ignore names any model once" {
    // Oracle: the language spec (deck.md, "LVS controls"): `lvs ignore` and
    // `lvs ignore_shorted` lower to the model, which no device statement need
    // declare; a model given twice is refused.
    var o = try okWith(nfet, "lvs ignore \"nfet\"\nlvs ignore \"decap\"\n");
    defer o.deinit();
    try testing.expectEqualSlices(@import("geom").StrId, &.{ o.id("nfet"), o.id("decap") }, o.d().lvs.ignore);
    try lvsError(nfet, "lvs ignore \"decap\"\nlvs ignore \"decap\"\n", "already ignored");
    var s = try okWith(nfet, "lvs ignore_shorted \"nfet\"\n");
    defer s.deinit();
    try testing.expectEqualSlices(@import("geom").StrId, &.{s.id("nfet")}, s.d().lvs.ignore_shorted);
    try lvsError(nfet, "lvs ignore_shorted \"nfet\"\nlvs ignore_shorted \"nfet\"\n", "already ignored");
}

test "lvs blackbox and filter_unused lower as stated" {
    // Oracle: the language spec (deck.md, "LVS controls"): `lvs blackbox`
    // keeps its globs in deck order, each once, refusing an empty one,
    // KLayout's class and escape characters, and one matching a device
    // model; `lvs filter_unused` keeps its options in deck order, refusing an
    // unknown letter, a repeat, none, a second statement, and `c` with no
    // `lvs supply`; `lvs supply` keeps its names across statements.
    var o = try okWith(nfet, "lvs blackbox \"SRAM_*\"\nlvs blackbox \"pad\"\nlvs filter_unused ag c u\nlvs supply \"VDD\" \"VSS\"\nlvs supply \"GND\"\n");
    defer o.deinit();
    try fx.expectStrings(&.{ "SRAM_*", "pad" }, o.d().lvs.blackbox);
    try testing.expectEqualSlices(deck.UnusedFilter, &.{ .ag, .c, .u }, o.d().lvs.filter_unused);
    const supply = o.d().lvs.supply;
    try testing.expectEqual(3, supply.len);
    for ([_][]const u8{ "VDD", "VSS", "GND" }, supply) |w, g| try testing.expectEqualStrings(w, o.strings.resolve(g));
    const cases = [_][2][]const u8{
        .{ "lvs blackbox \"\"\n", "matches no cell" },
        .{ "lvs blackbox \"a[bc]\"\n", "`*` and `?` only" },
        .{ "lvs blackbox \"pad\"\nlvs blackbox \"pad\"\n", "already a black box" },
        .{ "lvs filter_unused\n", "one or more" },
        .{ "lvs filter_unused ae x\n", "unknown filter option" },
        .{ "lvs filter_unused ae ae\n", "given twice" },
        .{ "lvs filter_unused ae\nlvs filter_unused u\n", "already stated" },
        .{ "lvs supply\n", "one net or more" },
        .{ "lvs supply \"VDD\" \"VDD\"\n", "already a supply" },
    };
    for (cases) |c| try lvsError(nfet, c[0], c[1]);
    try lvsMalformed(nfet, "lvs filter_unused c\n", "no lvs supply");
    try lvsMalformed(nfet, "lvs blackbox \"n*\"\n", "matches the device model \"nfet\"");
}

test "lvs thresholds and same_nets lower as stated" {
    // Oracle: the language spec (deck.md, "LVS controls"): `lvs max_res` in
    // ohms (2 kohm is 2000) and `lvs min_caps` in aF (1.5 fF is 1500), each
    // once and positive, each interning the value name LVS computes it under;
    // `lvs same_nets` keeps its names in order; `lvs count` its whole-number
    // bounds; `lvs recognize_gates` a flag once; `lvs lde` its layers and
    // lengths (10 um is 10 000 dbu), needing `od` and `max`.
    var o = try okWith(nfet, "lvs max_res 2kohm\nlvs min_caps 1.5fF\nlvs same_nets \"A\" \"a\"\nlvs same_nets \"B\" \"b\"\n");
    defer o.deinit();
    try testing.expectEqual(2000.0, o.d().lvs.max_res.?);
    try testing.expectEqual(1500.0, o.d().lvs.min_caps.?);
    try testing.expect(o.strings.get("r") != null and o.strings.get("c") != null);
    try testing.expectEqualSlices(deck.SameNets, &.{ .{ .layout = o.id("A"), .reference = o.id("a") }, .{ .layout = o.id("B"), .reference = o.id("b") } }, o.d().lvs.same_nets);
    try lvsError(nfet, "lvs max_res 1kohm\nlvs max_res 2kohm\n", "already stated");
    try lvsError(nfet, "lvs min_caps 0aF\n", "must be positive");
    var l = try okWith(nfet, "lvs lde \"nfet\" max 10um od diff well met3 scref 950nm\n");
    defer l.deinit();
    const row = l.d().lvs.lde[0];
    try testing.expectEqual(l.id("nfet"), row.model);
    try testing.expectEqual(l.id("diff"), row.od);
    try testing.expectEqual(10_000, row.max);
    try testing.expectEqual(l.id("met3"), row.well.?.layer);
    try testing.expectEqual(950, row.well.?.scref);
    const lde_cases = [_][2][]const u8{
        .{ "lvs lde \"nfet\" od diff\n", "needs od and max" },
        .{ "lvs lde \"nfet\" od diff max 1um well met3\n", "go together" },
        .{ "lvs lde \"nfet\" od diff max 0um\n", "must be positive" },
        .{ "lvs lde \"nfet\" od diff max 1um od diff\n", "given twice" },
    };
    for (lde_cases) |c| try lvsError(nfet, c[0], c[1]);
    var g = try okWith(nfet, "lvs recognize_gates\n");
    defer g.deinit();
    try testing.expect(g.d().lvs.recognize_gates);
    try lvsError(nfet, "lvs recognize_gates\nlvs recognize_gates\n", "already recognised");
    var c = try okWith(nfet, "lvs count \"nfet\" >= 2 <= 4000\n");
    defer c.deinit();
    try testing.expectEqualSlices(deck.LvsCount, &.{.{ .model = c.id("nfet"), .min = 2, .max = 4000 }}, c.d().lvs.count);
    try lvsError(nfet, "lvs count \"nfet\" <= 1 >= 2\n", "admits no value");
    try lvsError(nfet, "lvs count \"nfet\"\n", "needs >=, <= or both");
    try lvsError(nfet, "lvs count \"nfet\" <= 1.5\n", "whole number");
    try lvsError(nfet, "lvs count \"nfet\" <= 1\nlvs count \"nfet\" >= 1\n", "already has a count");
    try lvsError(nfet, "lvs max_res 1fF\n", "resistance");
    try lvsError(nfet, "lvs same_nets \"A\" \"a\"\nlvs same_nets \"A\" \"b\"\n", "one same_nets statement");
}

test "lvs ports_by_name is a flag" {
    // Oracle: the language spec (deck.md, "LVS controls"): `lvs
    // ports_by_name` sets the flag, off without it, refused twice; `lvs
    // topology` is strict unless it says relaxed, takes one of the two words,
    // once; `lvs connect_implicit` keeps its pattern and `lvs
    // connect_explicit` its labels, two or more.
    inline for (.{ .{ "", false, false }, .{ "lvs ports_by_name\n", true, false }, .{ "lvs topology relaxed\n", false, true }, .{ "lvs topology strict\n", false, false } }) |c| {
        var o = try ok(c[0]);
        defer o.deinit();
        try testing.expectEqual(c[1], o.d().lvs.ports_by_name);
        try testing.expectEqual(c[2], o.d().lvs.relaxed);
    }
    try fx.oneError("lvs topology loose\n", "unknown topology `loose`");
    var o = try ok("lvs connect_implicit \"VDD*\"\nlvs connect_explicit \"VSS\" \"GND\"\n");
    defer o.deinit();
    try fx.expectStrings(&.{"VDD*"}, o.d().lvs.connect_implicit);
    try testing.expectEqual(1, o.d().lvs.connect_explicit.len);
    try testing.expectEqualSlices(@import("geom").StrId, &.{ o.id("VSS"), o.id("GND") }, o.d().lvs.connect_explicit[0]);
    try fx.oneError("lvs connect_explicit \"VSS\"\n", "joins two labels or more");
    try fx.oneError("lvs connect_implicit VDD\n", "a label pattern in quotes");
    try fx.oneError("lvs topology strict\nlvs topology relaxed\n", "the topology is already stated");
    try fx.oneError("lvs ports_by_name\nlvs ports_by_name\n", "already compared by name");
}

test "lvs ranges lower to layout units" {
    // Oracle: the language spec (deck.md, "LVS controls"), converted by hand
    // on the 5 nm deck grid and 1 nm layout grid: 420 nm and 100 um as
    // lengths, 0.2 um² as 200 000 square units, an `nf` as a count. Each
    // misuse is refused.
    var o = try okWith(nfet, "lvs range \"nfet\" W >= 420nm <= 100um\nlvs range \"nfet\" as >= 0.2um2\nlvs range \"nfet\" nf <= 4\n");
    defer o.deinit();
    try testing.expectEqualSlices(deck.LvsRange, &.{
        .{ .model = o.id("nfet"), .param = o.id("w"), .min = .{ .length = 420 }, .max = .{ .length = 100_000 } },
        .{ .model = o.id("nfet"), .param = o.id("as"), .min = .{ .area = 200_000 }, .max = null },
        .{ .model = o.id("nfet"), .param = o.id("nf"), .min = null, .max = .{ .count = 4 } },
    }, o.d().lvs.range);
    const cases = [_][2][]const u8{
        .{ "lvs range \"nfet\" r >= 1ohm\n", "not measured on a device" },
        .{ "lvs range \"nfet\" w >= 422nm\n", "not a multiple of the grid" },
        .{ "lvs range \"nfet\" w >= 420nm >= 500nm\n", "already given" },
        .{ "lvs range \"nfet\" w >= 1um <= 500nm\n", "admits no value" },
        .{ "lvs range \"nfet\" w\n", "needs >=, <= or both" },
        .{ "lvs range \"nfet\" w > 1um\n", "expected >= or <=" },
        .{ "lvs range \"nfet\" w >= 1um\nlvs range \"nfet\" w <= 2um\n", "already has a range" },
    };
    for (cases) |c| try lvsError(nfet, c[0], c[1]);
    try fx.malformed("lvs range \"pfet\" w >= 1um\n", "");
}

test "an lvs default tolerance is one fraction" {
    // Oracle: hand-derived: 2% is 0.02, and each misuse's message.
    var o = try ok("lvs tolerance default relative 2%\n");
    defer o.deinit();
    try testing.expectEqual(0.02, o.d().lvs.default_tolerance.?);
    var none = try ok("");
    defer none.deinit();
    try testing.expectEqual(null, none.d().lvs.default_tolerance);
    try fx.oneError("lvs tolerance default relative 2%\nlvs tolerance default relative 1%\n", "the default tolerance is already stated");
    try fx.oneError("lvs tolerance default relative 150%\n", "a fraction: 0 to 1");
    try fx.oneError("lvs tolerance default absolute 5nm\n", "expected `relative`");
}
