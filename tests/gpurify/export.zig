//! The writers, byte for byte, against one small world whose answer is
//! known: two disjoint rectangles on one conductor (two nets, labelled by
//! the test), two violation rows out of canonical order, three rule
//! records, and a parasitic network of exact binary fractions. Ported from
//! tests/export/main.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const extract = @import("extract");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const topology = check.topology;
const report = check.report;
const NetId = topology.NetId;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;
const ex = gpurify.@"export";

const conductor: geom.LayerId = @fromBackingInt(0);
const nan = std.math.nan(f64);
const inf = std.math.inf(f64);

/// The world, and one output buffer every writer call refills.
const World = struct {
    header: ex.Header = .{ .tool_version = "gpurify-test", .deck_path = "decks/test.json", .layout_path = "layouts/test.gds", .timestamp = "2020-01-01T00:00:00Z" },
    strings: geom.StrTable = .empty,
    store: geom.GeometryStore = .empty,
    ids: testgen.shapes.Ids = .{},
    nets: topology.NetTable = .{},
    provenance: ingest.Provenance = .{},
    ports: topology.PortTable = .{},
    violations: report.Violations = .{},
    runs: [3]report.RuleRun = undefined,
    parasitics: ParasiticNetwork = .empty,
    lower: geom.PolyId = undefined,
    upper: geom.PolyId = undefined,
    upper_net: NetId = undefined,
    out: std.Io.Writer.Allocating = undefined,
    diag: ex.Diagnostic = .{},

    /// `upper_name` null leaves the upper net anonymous.
    fn init(w: *World, upper_name: ?[]const u8) !void {
        w.* = .{ .out = .init(gpa) };
        var layout: testgen.shapes.LayoutBuilder = .init(1);
        defer layout.deinit(gpa);
        const a = try layout.rect(gpa, 0, 0, 0, 100, 100);
        const b = try layout.rect(gpa, 0, 400, 0, 500, 100);
        try layout.finish(gpa, &w.store, &w.ids);
        const ia = w.ids.of(a);
        const ib = w.ids.of(b);
        w.lower = if (@backingInt(ia) < @backingInt(ib)) ia else ib;
        w.upper = if (@backingInt(ia) < @backingInt(ib)) ib else ia;
        try topology.extractNetsInto(gpa, &w.store, &.{ .conductors = &.{conductor}, .intra_layer_touch = true }, &w.nets);
        const lower_net = w.nets.netOf(w.lower);
        w.upper_net = w.nets.netOf(w.upper);

        const width = try w.strings.intern(gpa, "m1.width");
        const density = try w.strings.intern(gpa, "m1.density");
        const antenna = try w.strings.intern(gpa, "m1.antenna");
        try w.provenance.label(gpa, w.lower, try w.strings.intern(gpa, "VDD"));
        if (upper_name) |name| try w.provenance.label(gpa, w.upper, try w.strings.intern(gpa, name));
        try topology.bindPortsInto(gpa, &w.nets, w.provenance.labels(), &w.ports);

        try w.violations.push(gpa, .{ .rule = density, .layer = conductor, .severity = .warning, .at = .{ .x = 40, .y = 60 }, .measured = .ratio(0.8125), .limit = .ratio(0.75), .shape_a = w.upper, .shape_b = report.no_shape });
        try w.violations.push(gpa, .{ .rule = width, .layer = conductor, .severity = .@"error", .at = .{ .x = 10, .y = 20 }, .measured = .length(80), .limit = .length(100), .shape_a = w.lower, .shape_b = w.upper });
        w.runs = .{
            .{ .rule = width, .outcome = .ran, .examined = 1234, .violations = 1 },
            .{ .rule = density, .outcome = .ran, .examined = 5678, .violations = 1 },
            .{ .rule = antenna, .outcome = .{ .skipped = .no_design_intent }, .examined = 0, .violations = 0 },
        };

        const p = &w.parasitics;
        try p.node_net.appendSlice(gpa, &.{ @backingInt(lower_net), @backingInt(lower_net), @backingInt(w.upper_net) });
        try p.node_layer.appendNTimes(gpa, conductor, 3);
        try p.push(gpa, .at(0), .ground, .ground_cap, 0.25);
        try p.push(gpa, .at(0), .at(1), .resistance, 12.5);
        try p.push(gpa, .at(1), .at(2), .coupling_cap, 0.125);
    }

    fn deinit(w: *World) void {
        w.strings.deinit(gpa);
        w.store.deinit(gpa);
        w.ids.deinit(gpa);
        w.nets.deinit(gpa);
        w.provenance.deinit(gpa);
        w.ports.deinit(gpa);
        w.violations.deinit(gpa);
        w.parasitics.deinit(gpa);
        w.out.deinit();
    }

    fn json(w: *World) ![]const u8 {
        w.out.clearRetainingCapacity();
        const none: report.Violations = .{};
        try ex.json.writeReport(&w.out.writer, &w.header, &w.strings, try .init(1000), &w.violations, &none, &w.runs);
        return w.out.written();
    }

    fn spef(w: *World) ![]const u8 {
        w.out.clearRetainingCapacity();
        try ex.spef.writeSpef(&w.out.writer, gpa, &w.parasitics, &w.ports, &w.strings, &w.header, &w.diag);
        return w.out.written();
    }

    fn dspf(w: *World) ![]const u8 {
        w.out.clearRetainingCapacity();
        try ex.dspf.writeDspf(&w.out.writer, gpa, &w.parasitics, &w.ports, &w.strings, &w.header, &w.diag);
        return w.out.written();
    }

    /// The world as a simulator's subcircuit `test` on pins `VDD VSS`, a
    /// third net `SUB` with no node, and one MOS `XM1`: drain on VDD's
    /// second node, gate on VSS's, source on VDD's first (its pin node),
    /// bulk on SUB; 100 by 50 nm with a shared 70000 nm² source, written in
    /// µm (1 nm database units).
    fn subckt(w: *World, s: *ex.subckt.Subckt) !void {
        const vdd = @backingInt(w.nets.netOf(w.lower));
        const vss = @backingInt(w.upper_net);
        try s.clear(gpa);
        s.name = "test";
        s.unit_nm = 1000;
        s.dbu_per_unit = 1000;
        try s.pin_net.appendSlice(gpa, &.{ vdd, vss });
        try s.net_name.appendNTimes(gpa, null, 3);
        s.net_name.items[vdd] = "VDD";
        s.net_name.items[vss] = "VSS";
        s.net_name.items[2] = "SUB";
        try s.pin_node.appendNTimes(gpa, .ground, 3);
        s.pin_node.items[vdd] = .at(0);
        s.pin_node.items[vss] = .at(2);
        try s.device_name.append(gpa, "XM1");
        try s.device_model.append(gpa, "nch");
        try s.device_kind.append(gpa, .mos);
        try s.terminal_net.appendSlice(gpa, &.{ vdd, vss, vdd, 2 });
        try s.terminal_node.appendSlice(gpa, &.{ .at(1), .at(2), .at(0), .ground });
        try s.terminal_start.append(gpa, 4);
        try s.param_name.appendSlice(gpa, &.{ "w", "l", "as", "nf" });
        try s.param_value.appendSlice(gpa, &.{ .{ .length = 100 }, .{ .length = 50 }, .{ .area = 35_000 }, .{ .count = 1 } });
        try s.param_start.append(gpa, 4);
    }

    fn spice(w: *World) ![]const u8 {
        var s: ex.subckt.Subckt = .{};
        defer s.deinit(gpa);
        try w.subckt(&s);
        w.out.clearRetainingCapacity();
        try ex.netlist.writeSpice(&w.out.writer, gpa, &w.parasitics, &s, "nominal", &w.header, &w.diag);
        return w.out.written();
    }

    fn dspfSubckt(w: *World) ![]const u8 {
        var s: ex.subckt.Subckt = .{};
        defer s.deinit(gpa);
        try w.subckt(&s);
        w.out.clearRetainingCapacity();
        try ex.dspf.writeDspfSubckt(&w.out.writer, gpa, &w.parasitics, &s, &w.header, &w.diag);
        return w.out.written();
    }
};

test "the json report is exactly these bytes" {
    // Oracle: golden, written by hand from the known world (module doc): the
    // violation rows in the table's order, floats at six decimals, the skipped
    // rule beside the ones that ran; and determinism, two worlds built apart give
    // the same bytes.
    const expected =
        \\{"header":{"tool_version":"gpurify-test","deck_path":"decks/test.json","layout_path":"layouts/test.gds","timestamp":"2020-01-01T00:00:00Z"},
    ++
        \\"violations":[{"rule":"m1.density","layer":0,"severity":"warning","at":{"unit":"nm","x":40.000000,"y":60.000000},"measured":{"kind":"ratio","unit":"","value":0.812500},"limit":{"kind":"ratio","unit":"","value":0.750000},"shapes":[1,null]},
    ++
        \\{"rule":"m1.width","layer":0,"severity":"error","at":{"unit":"nm","x":10.000000,"y":20.000000},"measured":{"kind":"length","unit":"nm","value":80.000000},"limit":{"kind":"length","unit":"nm","value":100.000000},"shapes":[0,1]}],
    ++
        \\"runs":[{"rule":"m1.width","outcome":"ran","examined":1234,"violations":1},{"rule":"m1.density","outcome":"ran","examined":5678,"violations":1},{"rule":"m1.antenna","outcome":"skipped:no_design_intent","examined":0,"violations":0}]}
    ;
    var a: World = undefined;
    try a.init("VSS");
    defer a.deinit();
    try testing.expectEqualStrings(expected, try a.json());
    // Two independently built worlds give the same bytes.
    var b: World = undefined;
    try b.init("VSS");
    defer b.deinit();
    try testing.expectEqualStrings(expected, try b.json());
}

test "a json string escapes quotes, backslashes and controls only" {
    // Oracle: RFC 8259 §7: a JSON string escapes the quote, the backslash and the
    // controls below U+0020, and nothing else (DEL and non-ASCII pass through).
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    w.header.deck_path = "a\"b\\c\n\t\r\x08\x0c\x01\x1f\x7f\u{e9}/";
    w.header.timestamp = null;
    const text = try w.json();
    try testing.expect(std.mem.startsWith(u8, text, "{\"header\":{\"tool_version\":\"gpurify-test\",\"deck_path\":\"a\\\"b\\\\c\\n\\t\\r\\b\\f\\u0001\\u001f\x7f\u{e9}/\",\"layout_path\":\"layouts/test.gds\",\"timestamp\":null}"));
}

test "a non-finite measurement is refused before a byte is written" {
    // Oracle: RFC 8259 §6 ("Numeric values that cannot be represented ... such as
    // Infinity and NaN are not permitted") and `format_f64`'s doc: `write_report`
    // refuses one.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    w.violations.measured.items[0] = @as(u64, @bitCast(nan));
    try testing.expectError(error.Unrepresentable, w.json());
    try testing.expectEqual(0, w.out.written().len);
}

test "the spef and dspf files are exactly these bytes" {
    // Oracle: golden, written by hand from the known network in the layouts IEEE
    // 1481-1998 (SPEF) and DSPF 1.4 define: ground C 0.25 fF, coupling 0.125 fF, R
    // 12.5 ohm, totals 0.375 and 0.125.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    try testing.expectEqualStrings("*SPEF \"IEEE 1481-1998\"\n*DESIGN \"layouts/test.gds\"\n*DATE \"2020-01-01T00:00:00Z\"\n" ++
        "*VENDOR \"gpurify\"\n*PROGRAM \"gpurify\"\n*VERSION \"gpurify-test\"\n// deck decks/test.json\n" ++
        "*DESIGN_FLOW \"EXTRACTED\"\n*DIVIDER /\n*DELIMITER :\n*BUS_DELIMITER [ ]\n*T_UNIT 1 NS\n" ++
        "*C_UNIT 1 FF\n*R_UNIT 1 OHM\n*L_UNIT 0.000001 UH\n\n" ++
        "*D_NET VDD 0.375000\n*CONN\n*P VDD B\n*CAP\n1 VDD:0 0.250000\n2 VDD:1 VSS:0 0.125000\n" ++
        "*RES\n1 VDD:0 VDD:1 12.500000\n*INDUC\n*END\n\n" ++
        "*D_NET VSS 0.125000\n*CONN\n*P VSS B\n*CAP\n1 VSS:0 VDD:1 0.125000\n*RES\n*INDUC\n*END\n\n", try w.spef());
    try testing.expectEqualStrings("*|DSPF \"1.4\"\n*|DESIGN \"layouts/test.gds\"\n*|DATE \"2020-01-01T00:00:00Z\"\n" ++
        "*|VENDOR \"gpurify\"\n*|PROGRAM \"gpurify\"\n*|VERSION \"gpurify-test\"\n* deck decks/test.json\n" ++
        "*|DIVIDER /\n*|DELIMITER :\n*|GROUND_NET 0\n\n" ++
        "*|NET VDD 0.375000f\n*|S (VDD:0 L0)\n*|S (VDD:1 L0)\n\n" ++
        "*|NET VSS 0.125000f\n*|S (VSS:0 L0)\n\n" ++
        "C1 VDD:0 0 0.250000f\nR1 VDD:0 VDD:1 12.500000\nC2 VDD:1 VSS:0 0.125000f\n", try w.dspf());
}

test "the spef and dspf files read back as written" {
    // Oracle: round trip through `gpurify_extract::foreign`: VDD totals
    // 0.375 fF (0.25 ground and 0.125 coupling) with 12.5 Ω from its first
    // node, VSS 0.125 fF, in both SPEF and DSPF, and the two reads compare
    // with no error.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    var spef: extract.foreign.Read = .empty;
    defer spef.deinit(gpa);
    var dspf: extract.foreign.Read = .empty;
    defer dspf.deinit(gpa);
    var diag: extract.foreign.Diagnostic = .{};
    try extract.spef.readInto(gpa, try w.spef(), &spef, &diag);
    try extract.dspf.readInto(gpa, try w.dspf(), &dspf, &diag);
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    for ([_]*const extract.foreign.Read{ &spef, &dspf }) |read| {
        try testing.expectEqual(2, read.nameCount());
        try testing.expectEqualStrings("VDD", read.name(0));
        try testing.expectEqualStrings("VSS", read.name(1));
        try read.network.capacitancePerNetInto(gpa, &totals);
        try testing.expectEqualSlices(f64, &.{ 0.375, 0.125 }, totals.items);
    }
    var both: extract.compare.Comparison = .empty;
    defer both.deinit(gpa);
    try extract.compare.compareInto(gpa, &spef.network, &dspf.network, &both);
    try testing.expectEqualSlices(f64, &.{ 12.5, 0.0 }, both.resistance.reference.items);
    inline for (.{ "total_cap", "ground_cap", "resistance", "delay", "coupling" }) |metric| {
        try testing.expectEqualSlices(f64, @field(both, metric).reference.items, @field(both, metric).candidate.items);
    }
    try testing.expectEqualSlices(f64, &.{0.125}, both.coupling.reference.items);
}

test "a label with special characters is escaped once and reads back as itself" {
    // Oracle: round trip through extract's readers, which unescape once
    // (IEEE 1481-1998 §B.2: `\` before a special character). The label
    // `a.b:c\d` goes out as `a\.b\:c\\d` and reads back as `a.b:c\d`;
    // Rust wrote it raw, which the reader read as `a.b:cd`.
    var w: World = undefined;
    try w.init("a.b:c\\d");
    defer w.deinit();
    const spef_text = try gpa.dupe(u8, try w.spef());
    defer gpa.free(spef_text);
    try testing.expect(std.mem.indexOf(u8, spef_text, "*D_NET a\\.b\\:c\\\\d 0.125000\n") != null);
    var read: extract.foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: extract.foreign.Diagnostic = .{};
    try extract.spef.readInto(gpa, spef_text, &read, &diag);
    try testing.expectEqualStrings("a.b:c\\d", read.name(1));
    try extract.dspf.readInto(gpa, try w.dspf(), &read, &diag);
    try testing.expectEqualStrings("a.b:c\\d", read.name(1));
    // No escape survives a reader that splits on blanks: refused.
    w.deinit();
    try w.init("a b");
    try testing.expectError(error.Unrepresentable, w.spef());
    try testing.expectEqualStrings("a net name holding whitespace or a control character", w.diag.what);
}

test "a dspf label with parentheses reads back as itself" {
    // Oracle: round trip. The DSPF writer escapes `(` and `)` (IEEE
    // 1481-1998 §B.2), so `*|S (n\(1\):0 L0)` declares node `n(1):0` of net
    // `n(1)`: an escaped parenthesis is part of the name, an unescaped one
    // brackets the declaration. Rust's reader split on both before
    // unescaping.
    var w: World = undefined;
    try w.init("n(1)");
    defer w.deinit();
    const text = try w.dspf();
    try testing.expect(std.mem.indexOf(u8, text, "*|NET n\\(1\\) 0.125000f\n*|S (n\\(1\\):0 L0)\n") != null);
    var read: extract.foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: extract.foreign.Diagnostic = .{};
    try extract.dspf.readInto(gpa, text, &read, &diag);
    try testing.expectEqual(2, read.nameCount());
    try testing.expectEqualStrings("n(1)", read.name(1));
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try read.network.capacitancePerNetInto(gpa, &totals);
    try testing.expectEqualSlices(f64, &.{ 0.375, 0.125 }, totals.items);
}

test "the spice netlist is exactly these bytes" {
    // Oracle: golden, written by hand from the known world (World.subckt):
    // the `.subckt` on its pins in order, the device on its nodes in drain,
    // gate, source, bulk order, a pin node bare and every other `net#index`
    // as DSPF counts it, a net with no node bare; sizes in µm (100 nm is
    // 0.1, 35000 nm² is 0.035 µm²); the elements as DSPF cards them.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    w.header.reference_path = "ref/test.spice";
    try testing.expectEqualStrings("* gpurify-test pex: layouts/test.gds, deck decks/test.json, reference ref/test.spice, corner nominal\n" ++
        "* written: 2020-01-01T00:00:00Z\n* sizes in units of 1e-6 m: a bench's .option scale must say the same\n" ++
        ".subckt test VDD VSS\nXM1 VDD#1 VSS VDD SUB nch w=0.1 l=0.05 as=0.035 nf=1\n" ++
        "C1 VDD 0 0.250000f\nR1 VDD VDD#1 12.500000\nC2 VDD#1 VSS 0.125000f\n.ends test\n", try w.spice());
    w.header.reference_path = null;
    try testing.expect(std.mem.indexOf(u8, try w.spice(), "no reference, so devices are named by layout index and cannot be back-annotated, corner nominal\n") != null);
}

test "dspf's instance section declares each terminal's node and carries the card" {
    // Oracle: golden, written by hand (DSPF 1.4's `*|I (pin inst pin_name
    // type cap)` per device terminal in place of the node's `*|S`, then the
    // instance section): VDD:0 holds the source, VDD:1 the drain, VSS:0 the
    // gate; the bulk's net SUB has no node. Read back, the instance
    // section changes nothing: the same totals as the labels' DSPF.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    const text = try w.dspfSubckt();
    try testing.expectEqualStrings("*|NET VDD 0.375000f\n*|I (VDD:0 XM1 s B 0 L0)\n*|I (VDD:1 XM1 d B 0 L0)\n\n" ++
        "*|NET VSS 0.125000f\n*|I (VSS:0 XM1 g B 0 L0)\n\n" ++
        "C1 VDD:0 0 0.250000f\nR1 VDD:0 VDD:1 12.500000\nC2 VDD:1 VSS:0 0.125000f\n\n* instance section\n" ++
        "XM1 VDD:1 VSS:0 VDD:0 SUB nch w=0.1 l=0.05 as=0.035 nf=1\n", text[std.mem.indexOf(u8, text, "*|NET").?..]);
    var read: extract.foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: extract.foreign.Diagnostic = .{};
    try extract.dspf.readInto(gpa, text, &read, &diag);
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);
    try read.network.capacitancePerNetInto(gpa, &totals);
    try testing.expectEqualSlices(f64, &.{ 0.375, 0.125 }, totals.items);
}

test "spice refuses a name a card would read as syntax" {
    // Oracle: construct-from-answer. `#` is the node suffix, a blank splits
    // the card, `=` makes a parameter: each would wire another circuit.
    for ([_][]const u8{ "V#1", "V DD", "a=b", "" }) |bad| {
        var w: World = undefined;
        try w.init("VSS");
        defer w.deinit();
        var s: ex.subckt.Subckt = .{};
        defer s.deinit(gpa);
        try w.subckt(&s);
        s.net_name.items[s.pin_net.items[1]] = bad;
        w.out.clearRetainingCapacity();
        try testing.expectError(error.Unrepresentable, ex.netlist.writeSpice(&w.out.writer, gpa, &w.parasitics, &s, "nominal", &w.header, &w.diag));
    }
}

test "inductances, a mutual one and a substrate resistance go out as comments and K cards" {
    // Oracle: hand-worked from parasitic.rs's documented layouts. VDD has
    // R 2 Ω and L 4 pH between its nodes, a substrate resistance of 100 Ω
    // to the backside, and M 1 pH to VSS's L 1 pH, so k = 1/√(4·1) = 0.5;
    // VSS has 0.5 fF to ground. DSPF numbers R, L, K and C apart.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    const p = &w.parasitics;
    const vdd = p.node_net.items[0];
    const vss = p.node_net.items[2];
    p.clear();
    try p.node_net.appendSlice(gpa, &.{ vdd, vdd, vss, vss });
    try p.node_layer.appendNTimes(gpa, conductor, 4);
    try p.push(gpa, .at(0), .at(1), .resistance, 2.0);
    try p.push(gpa, .at(0), .at(1), .inductance, 4.0);
    try p.push(gpa, .at(0), .at(2), .mutual_inductance, 1.0);
    try p.push(gpa, .at(1), .ground, .substrate_resistance, 100.0);
    try p.push(gpa, .at(2), .ground, .ground_cap, 0.5);
    try p.push(gpa, .at(2), .at(3), .inductance, 1.0);
    const spef = try w.spef();
    try testing.expectEqualStrings("*D_NET VDD 0.000000\n*CONN\n*P VDD B\n*CAP\n*RES\n1 VDD:0 VDD:1 2.000000\n" ++
        "*INDUC\n1 VDD:0 VDD:1 4.000000\n// mutual VDD:0 VSS:0 1.000000\n// substrate VDD:1 0 100.000000\n*END\n\n" ++
        "*D_NET VSS 0.500000\n*CONN\n*P VSS B\n*CAP\n1 VSS:0 0.500000\n*RES\n*INDUC\n1 VSS:0 VSS:1 1.000000\n*END\n\n", spef[std.mem.indexOf(u8, spef, "*D_NET").?..]);
    const dspf = try w.dspf();
    try testing.expectEqualStrings("*|NET VDD 0.000000f\n*|S (VDD:0 L0)\n*|S (VDD:1 L0)\n\n*|NET VSS 0.500000f\n*|S (VSS:0 L0)\n*|S (VSS:1 L0)\n\n" ++
        "R1 VDD:0 VDD:1 2.000000\nL1 VDD:0 VDD:1 4.000000p\nK1 L1 L2 0.500000\nR2 VDD:1 0 100.000000\n" ++
        "C1 VSS:0 0 0.500000f\nL2 VSS:0 VSS:1 1.000000p\n", dspf[std.mem.indexOf(u8, dspf, "*|NET").?..]);
    // A mutual inductance larger than its two allow (k = 4/√4 = 2) is refused.
    p.value.items[2] = 4.0;
    try testing.expectError(error.Unrepresentable, w.dspf());
    try testing.expectEqualStrings("a mutual inductance larger than the two inductances it couples allow", w.diag.what);
}

test "process corners write min:typ:max triplets" {
    // Oracle: hand-worked envelope. The corner has 0.5 fF to ground, two
    // 25 Ω resistors in parallel (12.5 Ω) and no coupling (0 there); per
    // slot the triplet is the smallest, the nominal's and the largest:
    // ground 0.25:0.25:0.5, R 12.5 thrice, coupling 0:0.125:0.125, totals
    // VDD 0.25:0.375:0.625 and VSS 0:0.125:0.125. No corners is plain SPEF.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    const plain = try gpa.dupe(u8, try w.spef());
    defer gpa.free(plain);
    w.out.clearRetainingCapacity();
    try ex.spef.writeSpefCorners(&w.out.writer, gpa, &w.parasitics, &.{}, &w.ports, &w.strings, &w.header, &w.diag);
    try testing.expectEqualStrings(plain, w.out.written());

    var corner: ParasiticNetwork = .empty;
    defer corner.deinit(gpa);
    try corner.node_net.appendSlice(gpa, w.parasitics.node_net.items);
    try corner.node_layer.appendSlice(gpa, w.parasitics.node_layer.items);
    try corner.push(gpa, .at(0), .ground, .ground_cap, 0.5);
    try corner.push(gpa, .at(0), .at(1), .resistance, 25.0);
    try corner.push(gpa, .at(0), .at(1), .resistance, 25.0);
    w.out.clearRetainingCapacity();
    try ex.spef.writeSpefCorners(&w.out.writer, gpa, &w.parasitics, &.{&corner}, &w.ports, &w.strings, &w.header, &w.diag);
    const text = w.out.written();
    try testing.expectEqualStrings("*D_NET VDD 0.250000:0.375000:0.625000\n*CONN\n*P VDD B\n*CAP\n1 VDD:0 0.250000:0.250000:0.500000\n" ++
        "2 VDD:1 VSS:0 0.000000:0.125000:0.125000\n*RES\n1 VDD:0 VDD:1 12.500000:12.500000:12.500000\n*INDUC\n*END\n\n" ++
        "*D_NET VSS 0.000000:0.125000:0.125000\n*CONN\n*P VSS B\n*CAP\n1 VSS:0 VDD:1 0.000000:0.125000:0.125000\n*RES\n*INDUC\n*END\n\n", text[std.mem.indexOf(u8, text, "*D_NET").?..]);

    // A resistance at one corner and not another is refused.
    corner.clear();
    try corner.node_net.appendSlice(gpa, w.parasitics.node_net.items);
    try corner.node_layer.appendSlice(gpa, w.parasitics.node_layer.items);
    try corner.push(gpa, .at(0), .ground, .ground_cap, 0.5);
    try testing.expectError(error.Unrepresentable, ex.spef.writeSpefCorners(&w.out.writer, gpa, &w.parasitics, &.{&corner}, &w.ports, &w.strings, &w.header, &w.diag));
    try testing.expectEqualStrings("a resistance or inductance at one process corner and not another", w.diag.what);
}

test "both parasitic formats refuse an anonymous net" {
    // Oracle: construct-from-answer. The upper net has no label, and a placeholder
    // name would change between runs, so both formats refuse it by number.
    var w: World = undefined;
    try w.init(null);
    defer w.deinit();
    try testing.expectError(error.UnnamedNet, w.spef());
    try testing.expectEqual(@backingInt(w.upper_net), w.diag.net);
    w.diag = .{};
    try testing.expectError(error.UnnamedNet, w.dspf());
    try testing.expectEqual(@backingInt(w.upper_net), w.diag.net);
}

test "both parasitic formats refuse a resistor with no far node" {
    // Oracle: construct-from-answer. The resistor's far node is removed, and
    // SPEF's `*RES` and DSPF's `R` cards need two nodes.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    w.parasitics.to.items[1] = .ground;
    try testing.expectError(error.Unrepresentable, w.spef());
    try testing.expectEqualStrings("a resistance or inductance with no far node", w.diag.what);
    try testing.expectError(error.Unrepresentable, w.dspf());
    try testing.expectEqualStrings("a resistance or inductance with no far node", w.diag.what);
}

test "every writer refuses a label on two nets" {
    // Oracle: construct-from-answer (F31). `VDD` labels both rectangles, two nets,
    // so every writer that names nets by label refuses it.
    var w: World = undefined;
    try w.init("VDD");
    defer w.deinit();
    const vdd = w.strings.get("VDD").?;
    try testing.expectError(error.SplitLabel, w.spef());
    try testing.expectEqualSlices(geom.StrId, &.{vdd}, w.diag.labels);
    try testing.expectError(error.SplitLabel, w.dspf());
    try testing.expectEqualSlices(geom.StrId, &.{vdd}, w.diag.labels);
}

test "every writer refuses a net with two labels" {
    // Oracle: construct-from-answer (F71). `VDD` and `AVDD` label one net, and
    // neither SPEF, DSPF nor a SPICE node has an alias, so every writer refuses
    // it, naming both.
    var w: World = undefined;
    try w.init("VSS");
    defer w.deinit();
    w.provenance.deinit(gpa);
    w.provenance = .{};
    try w.provenance.label(gpa, w.lower, try w.strings.intern(gpa, "VDD"));
    try w.provenance.label(gpa, w.lower, try w.strings.intern(gpa, "AVDD"));
    try w.provenance.label(gpa, w.upper, try w.strings.intern(gpa, "VSS"));
    try topology.bindPortsInto(gpa, &w.nets, w.provenance.labels(), &w.ports);
    // In the port table's order: `VDD` was interned first.
    const both = [_]geom.StrId{ w.strings.get("VDD").?, w.strings.get("AVDD").? };
    try testing.expectError(error.ShortedLabels, w.spef());
    try testing.expectEqualSlices(geom.StrId, &both, w.diag.labels);
    try testing.expectError(error.ShortedLabels, w.dspf());
    try testing.expectEqualSlices(geom.StrId, &both, w.diag.labels);
}

test "every parasitic writer refuses a value that is not finite" {
    // Oracle: construct-from-answer (F30). Each row in turn is made NaN or
    // infinite, which no SPEF or DSPF reader parses, so every parasitic writer
    // refuses it; the schematic netlist carries none.
    for ([_]f64{ nan, inf, -inf }) |bad| for (0..3) |row| {
        var w: World = undefined;
        try w.init("VSS");
        defer w.deinit();
        w.parasitics.value.items[row] = bad;
        try testing.expectError(error.Unrepresentable, w.spef());
        try testing.expectEqualStrings("a non-finite parasitic value", w.diag.what);
        try testing.expectError(error.Unrepresentable, w.dspf());
        try testing.expectError(error.Unrepresentable, w.spice());
    };
}

test "an empty store writes a library the reader reads back empty" {
    // Oracle: round trip, and the GDSII Stream Format rule that every record has
    // an even length.
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    var layout: testgen.shapes.LayoutBuilder = .init(0);
    defer layout.deinit(gpa);
    try layout.finish(gpa, &store, &ids);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const layers: ingest.deck.LayerTable = .{};
    try testgen.gds.writeStore(gpa, &store, &layers, "TOP", &bytes);
    try testing.expectEqual(0, bytes.items.len % 2);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.gds.Diagnostic = .{};
    var lib = try ingest.gds.Library.parse(gpa, bytes.items, &strings, &diag);
    defer lib.deinit(gpa);
    var read: geom.GeometryStore = .empty;
    defer read.deinit(gpa);
    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    var tags: std.ArrayList(u64) = .empty;
    defer tags.deinit(gpa);
    try ingest.layout.flattenInto(gpa, &lib, &layers, &strings, .reject, .top, &read, &provenance, &tags, &diag);
    try testing.expectEqual(0, read.polyCount());
}

test "format_f64 writes six decimal places and no exponent" {
    // Oracle: `format_f64`'s doc ("`{:.6}`, six decimal places, never an
    // exponent"), worked by hand: 4e-7 is below 5e-7 and prints 0, and 1e30 is the
    // nearest double's digits.
    const cases = [_]struct { f64, []const u8 }{
        .{ 0.0, "0.000000" },
        .{ -0.0, "-0.000000" },
        .{ 12.5, "12.500000" },
        .{ 98_765.432_1, "98765.432100" },
        .{ 4e-7, "0.000000" },
        .{ 1e30, "1000000000000000019884624838656.000000" },
    };
    var buf: [64]u8 = undefined;
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try geom.float.fixed6(&w, c[0]);
        try testing.expectEqualStrings(c[1], w.buffered());
    }
}
