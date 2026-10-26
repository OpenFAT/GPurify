//! The deck's `lvs` statements, applied by `compareTraced` to graphs built
//! by hand: each changes the verdict exactly where its definition says.
//! Ported from crates/check/tests/lvs/controls.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
const LvsControls = ingest.deck.LvsControls;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const TerminalRole = check.topology.TerminalRole;
const common = @import("common.zig");
const id = common.id;
const nch = common.nch;
const pch = common.pch;
const width = common.width;
const length = common.length;
const P = common.P;
const T = common.T;
const gpa = testing.allocator;

/// A capacitor model and a multiplier name of this file's own.
const cap_model = id(40);

const mult = id(41);
const no_controls: LvsControls = .{};

/// One device as built by hand: its ends and its parameters.
const Card = struct { []const T, []const P };

// ---- private ----

fn oneMos(params: []const P) !Graph {
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, params);
    return b.finish();
}

fn matches(layout: *const Graph, reference: *const Graph, controls: *const LvsControls) !bool {
    return matchesWith(layout, reference, .{}, controls);
}

fn matchesWith(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions, controls: *const LvsControls) !bool {
    var r = try common.compareWith(layout, reference, options, controls);
    defer r.deinit(gpa);
    return r.verdict == .match;
}

fn parallelMos(each: []const []const P) !Graph {
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    for (each) |params| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, params);
    return b.finish();
}

/// An NCH on gate 0 and the given channel, bulk 3, beside a PCH gated by
/// net 1 whose other terminals sit on net 3.
fn anchoredMos(source: u32, drain: u32) !Graph {
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, source }, .{ .drain, drain }, .{ .bulk, 3 } });
    _ = try b.device(.mos, pch, &.{ .{ .gate, 1 }, .{ .source, 3 }, .{ .drain, 3 }, .{ .bulk, 3 } });
    return b.finish();
}

/// A device beside an NCH gated by net 0 whose other terminals sit on net 3.
fn anchored(kind: DeviceKind, model: StrId, terminals: []const T) !Graph {
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.device(kind, model, terminals);
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 3 }, .{ .drain, 3 }, .{ .bulk, 3 } });
    return b.finish();
}

fn build(kind: DeviceKind, model: StrId, nets: u32, ports: []const u32, devices: []const Card) !Graph {
    var b = common.GraphBuilder.init(nets);
    defer b.deinit();
    for (ports) |p| try b.port(p);
    for (devices) |d| _ = try b.deviceWithParams(kind, model, d[0], d[1]);
    return b.finish();
}

fn close(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-9 * @abs(b);
}

fn paramOf(g: *const Graph, device: u32, name: StrId) ?f64 {
    for (g.paramsOf(device)) |p| if (p.name == name) return p.value;
    return null;
}

test "a tolerance row bounds its parameter of its model only" {
    // Oracle: the definition, |a - b| <= absolute + relative·max(|a|, |b|)
    // (KLayout's `tolerance`: "absolute and relative tolerances add"), by
    // hand. 1.00 against 1.05 µm differ by 0.05 µm, 4.76 % of the larger:
    // past 2 %; within 5 % (0.0525) not 4 % (0.042); within 0.06 µm not
    // 0.04; within 3 % plus 0.03 µm (0.0615) though each part alone is not.
    // A row for another model or parameter leaves the default.
    var layout = try oneMos(&.{.{ width, 1.00e-6 }});
    defer layout.deinit(gpa);
    var reference = try oneMos(&.{.{ width, 1.05e-6 }});
    defer reference.deinit(gpa);
    try testing.expect(!try matches(&layout, &reference, &no_controls));
    for ([_]struct { f64, f64, bool }{
        .{ 0.05, 0.0, true },     .{ 0.04, 0.0, false }, .{ 0.0, 0.06e-6, true },  .{ 0.0, 0.04e-6, false },
        .{ 0.03, 0.03e-6, true }, .{ 0.03, 0.0, false }, .{ 0.0, 0.03e-6, false },
    }) |row| {
        const controls: LvsControls = .{ .tolerance = &.{.{ .model = nch, .param = width, .relative = row[0], .absolute = row[1], .stated = 0.0 }} };
        try testing.expectEqual(row[2], try matches(&layout, &reference, &controls));
    }
    for ([_][2]StrId{ .{ pch, width }, .{ nch, length } }) |mp| {
        const controls: LvsControls = .{ .tolerance = &.{.{ .model = mp[0], .param = mp[1], .relative = 0.05, .absolute = 0.0, .stated = 0.0 }} };
        try testing.expect(!try matches(&layout, &reference, &controls));
    }
}

test "a tolerance row can be tighter than the default" {
    // Oracle: the definition. A row replaces the default: 1.000 against
    // 1.015 µm is within 2 % (0.0203) and not 1 % (0.01015).
    var layout = try oneMos(&.{.{ width, 1.000e-6 }});
    defer layout.deinit(gpa);
    var reference = try oneMos(&.{.{ width, 1.015e-6 }});
    defer reference.deinit(gpa);
    try testing.expect(try matches(&layout, &reference, &no_controls));
    const tight: LvsControls = .{ .tolerance = &.{.{ .model = nch, .param = width, .relative = 0.01, .absolute = 0.0, .stated = 0.0 }} };
    try testing.expect(!try matches(&layout, &reference, &tight));
}

test "an ignored parameter is neither compared nor merged on" {
    // Oracle: the definition (KLayout's `ignore_parameter`, Netgen's
    // `property ... remove`). W 1.0 against 1.5 µm matches once `w` is
    // ignored on NCH, not on PCH. Two in parallel of `l` 1.0 and 1.2 µm do
    // not merge; with `l` ignored they merge, and are one card of twice W.
    var layout = try oneMos(&.{.{ width, 1.0e-6 }});
    defer layout.deinit(gpa);
    var reference = try oneMos(&.{.{ width, 1.5e-6 }});
    defer reference.deinit(gpa);
    try testing.expect(!try matches(&layout, &reference, &no_controls));
    try testing.expect(try matches(&layout, &reference, &.{ .ignore_parameter = &.{.{ .model = nch, .param = width }} }));
    try testing.expect(!try matches(&layout, &reference, &.{ .ignore_parameter = &.{.{ .model = pch, .param = width }} }));
    const options: lvs.CompareOptions = .{ .params = .{ .width = width } };
    var two = try parallelMos(&.{ &.{ .{ width, 1.0e-6 }, .{ length, 1.0e-6 } }, &.{ .{ width, 1.0e-6 }, .{ length, 1.2e-6 } } });
    defer two.deinit(gpa);
    var wide = try parallelMos(&.{&.{ .{ width, 2.0e-6 }, .{ length, 1.1e-6 } }});
    defer wide.deinit(gpa);
    try testing.expect(!try matchesWith(&two, &wide, options, &no_controls));
    try testing.expect(try matchesWith(&two, &wide, options, &.{ .ignore_parameter = &.{.{ .model = nch, .param = length }} }));
}

test "an asymmetric transistor keeps its source and drain apart" {
    // Oracle: the definition (KLayout's DMOS: "source and drain are not
    // swappable"). Written source-for-drain it is the same circuit, and
    // another once asymmetric; another model's row changes nothing. Two in
    // parallel merge into one of twice W aligned, and, asymmetric, not
    // opposed.
    var drawn = try anchoredMos(1, 2);
    defer drawn.deinit(gpa);
    var written = try anchoredMos(2, 1);
    defer written.deinit(gpa);
    const asym_n: LvsControls = .{ .asymmetric = &.{nch} };
    const asym_p: LvsControls = .{ .asymmetric = &.{pch} };
    try testing.expect(try matches(&drawn, &written, &no_controls));
    try testing.expect(!try matches(&drawn, &written, &asym_n));
    try testing.expect(try matches(&drawn, &drawn, &asym_n));
    try testing.expect(try matches(&drawn, &written, &asym_p));
    const options: lvs.CompareOptions = .{ .params = .{ .width = width } };
    const pair = struct {
        fn f(second: [2]u32) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            for ([_][2]u32{ .{ 1, 2 }, second }) |sd| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 3 } }, &.{.{ width, 1.0e-6 }});
            return b.finish();
        }
    }.f;
    var wide = try parallelMos(&.{&.{.{ width, 2.0e-6 }}});
    defer wide.deinit(gpa);
    var opposed = try pair(.{ 2, 1 });
    defer opposed.deinit(gpa);
    var aligned = try pair(.{ 1, 2 });
    defer aligned.deinit(gpa);
    try testing.expect(try matchesWith(&opposed, &wide, options, &no_controls));
    try testing.expect(!try matchesWith(&opposed, &wide, options, &asym_n));
    try testing.expect(try matchesWith(&aligned, &wide, options, &asym_n));
}

test "permuted pins are interchangeable" {
    // Oracle: the definition (Netgen's `permute`, KLayout's
    // `equivalent_pins`). A capacitor reversed, a bipolar with emitter and
    // collector exchanged, are other circuits by default (F15) and the same
    // once permuted; another model's row changes nothing. Two opposed
    // capacitors merge into m = 2 only when their plates permute.
    const capOf = struct {
        fn f(a: u32, b: u32) !Graph {
            return anchored(.capacitor, cap_model, &.{ .{ .{ .pin = 0 }, a }, .{ .{ .pin = 1 }, b } });
        }
    }.f;
    var drawn = try capOf(0, 1);
    defer drawn.deinit(gpa);
    var reversed = try capOf(1, 0);
    defer reversed.deinit(gpa);
    try testing.expect(!try matches(&drawn, &reversed, &no_controls));
    try testing.expect(try matches(&drawn, &reversed, &.{ .permute = &.{.{ .model = cap_model, .a = 0, .b = 1 }} }));
    try testing.expect(!try matches(&drawn, &reversed, &.{ .permute = &.{.{ .model = pch, .a = 0, .b = 1 }} }));
    const bjtOf = struct {
        fn f(e: u32, c: u32) !Graph {
            return anchored(.bjt, common.npn, &.{ .{ .base, 2 }, .{ .emitter, e }, .{ .collector, c } });
        }
    }.f;
    var bd = try bjtOf(0, 1);
    defer bd.deinit(gpa);
    var bf = try bjtOf(1, 0);
    defer bf.deinit(gpa);
    try testing.expect(!try matches(&bd, &bf, &no_controls));
    try testing.expect(try matches(&bd, &bf, &.{ .permute = &.{.{ .model = common.npn, .a = 1, .b = 2 }} }));
    try testing.expect(!try matches(&bd, &bf, &.{ .permute = &.{.{ .model = common.npn, .a = 0, .b = 1 }} }));
    const options: lvs.CompareOptions = .{ .params = .{ .multiplier = mult } };
    var ob = common.GraphBuilder.init(2);
    defer ob.deinit();
    for ([_][2]u32{ .{ 0, 1 }, .{ 1, 0 } }) |ab| _ = try ob.device(.capacitor, cap_model, &.{ .{ .{ .pin = 0 }, ab[0] }, .{ .{ .pin = 1 }, ab[1] } });
    var opposed = try ob.finish();
    defer opposed.deinit(gpa);
    var cb = common.GraphBuilder.init(2);
    defer cb.deinit();
    _ = try cb.deviceWithParams(.capacitor, cap_model, &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 1 }, 1 } }, &.{.{ mult, 2.0 }});
    var counted = try cb.finish();
    defer counted.deinit(gpa);
    try testing.expect(!try matchesWith(&opposed, &counted, options, &no_controls));
    try testing.expect(try matchesWith(&opposed, &counted, options, &.{ .permute = &.{.{ .model = cap_model, .a = 0, .b = 1 }} }));
}

test "an ignored model's devices and their private nets are left out" {
    // Oracle: the definition (Netgen's `ignore class`, KLayout's
    // `same_device_classes(nil, ...)`). A transistor beside a capacitor on
    // its gate and an internal net 4 matches the transistor alone once the
    // capacitor's model is ignored; ignoring the transistor's leaves the
    // capacitor unpaired; a reference port on net 4 must still pair. A
    // layout merge lists the rows given, past the dropped capacitor.
    const withCap = struct {
        fn f(port: bool) !Graph {
            var b = common.GraphBuilder.init(5);
            defer b.deinit();
            _ = try b.device(.capacitor, cap_model, &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 1 }, 4 } });
            _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
            for (0..4) |n| try b.port(@intCast(n));
            try b.nameNet(4, id(42));
            if (port) try b.port(4);
            return b.finish();
        }
    }.f;
    var ab = common.GraphBuilder.init(4);
    defer ab.deinit();
    _ = try ab.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    for (0..4) |n| try ab.port(@intCast(n));
    var alone = try ab.finish();
    defer alone.deinit(gpa);
    var wc = try withCap(false);
    defer wc.deinit(gpa);
    var wcp = try withCap(true);
    defer wcp.deinit(gpa);
    const ig_cap: LvsControls = .{ .ignore = &.{cap_model} };
    try testing.expect(!try matches(&alone, &wc, &no_controls));
    try testing.expect(try matches(&alone, &wc, &ig_cap));
    try testing.expect(try matches(&wc, &alone, &ig_cap));
    try testing.expect(!try matches(&alone, &wc, &.{ .ignore = &.{nch} }));
    try testing.expect(!try matches(&alone, &wcp, &ig_cap));
    var db = common.GraphBuilder.init(4);
    defer db.deinit();
    _ = try db.device(.capacitor, cap_model, &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 1 }, 3 } });
    for (0..2) |_| _ = try db.device(.resistor, common.res, &.{ .{ .{ .pin = 0 }, 1 }, .{ .{ .pin = 0 }, 2 } });
    var drawn = try db.finish();
    defer drawn.deinit(gpa);
    var r = try common.compareWith(&drawn, &drawn, .{ .params = .{ .multiplier = mult } }, &ig_cap);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), r.layout_merges.len());
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, r.layout_merges.devicesOf(0));
}

test "an ignored dummy is one with every terminal on one net" {
    // Oracle: the definition (Netgen's `ignore shorted`: "instances ...
    // which have all pins shorted"). A dummy with every terminal on net 3 is
    // left out on either side once its model ignores shorted devices; one
    // with its gate on net 0 is no dummy and stays.
    const shorted: LvsControls = .{ .ignore_shorted = &.{nch} };
    const with = struct {
        fn f(gate: u32) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
            _ = try b.device(.mos, nch, &.{ .{ .gate, gate }, .{ .source, 3 }, .{ .drain, 3 }, .{ .bulk, 3 } });
            return b.finish();
        }
    }.f;
    var alone = try oneMos(&.{});
    defer alone.deinit(gpa);
    var w3 = try with(3);
    defer w3.deinit(gpa);
    var w0 = try with(0);
    defer w0.deinit(gpa);
    try testing.expect(!try matches(&w3, &alone, &no_controls));
    try testing.expect(try matches(&w3, &alone, &shorted));
    try testing.expect(try matches(&alone, &w3, &shorted));
    try testing.expect(!try matches(&w0, &alone, &shorted));
}

test "ports by name hold each port to its label" {
    // Oracle: the definition (KLayout's `flag_missing_ports`, which
    // "prevents swapping of port labels or pads"), by hand. The reference
    // wiring gate in1 to drain out2 is the same circuit up to renaming: a
    // match by structure, a mismatch by name. An unlabelled layout's ports
    // pair with nothing by name.
    const in1 = id(70);
    const in2 = id(71);
    const out1 = id(72);
    const out2 = id(73);
    const vss = id(74);
    const pair = struct {
        fn f(gates: [2]StrId, drains: [2]StrId, s: StrId, labelled: bool) !Graph {
            var b = common.GraphBuilder.init(5);
            defer b.deinit();
            for ([_]StrId{ gates[0], gates[1], drains[0], drains[1], s }, 0..) |name, net| {
                if (!labelled) continue;
                try b.nameNet(@intCast(net), name);
                try b.port(@intCast(net));
            }
            for (0..2) |k| {
                const kk: u32 = @intCast(k);
                _ = try b.device(.mos, nch, &.{ .{ .gate, kk }, .{ .source, 4 }, .{ .drain, 2 + kk }, .{ .bulk, 4 } });
            }
            return b.finish();
        }
    }.f;
    const by_name: LvsControls = .{ .ports_by_name = true };
    var layout = try pair(.{ in1, in2 }, .{ out1, out2 }, vss, true);
    defer layout.deinit(gpa);
    var crossed = try pair(.{ in1, in2 }, .{ out2, out1 }, vss, true);
    defer crossed.deinit(gpa);
    try testing.expect(try matches(&layout, &crossed, &no_controls));
    try testing.expect(!try matches(&layout, &crossed, &by_name));
    try testing.expect(try matches(&layout, &layout, &by_name));
    var unlabelled = try pair(.{ in1, in2 }, .{ out1, out2 }, vss, false);
    defer unlabelled.deinit(gpa);
    try testing.expect(try matches(&unlabelled, &layout, &no_controls));
    try testing.expect(!try matches(&unlabelled, &layout, &by_name));
}

test "relaxed parallel passives combine their value by its law" {
    // Oracle: closed form, Kirchhoff's laws for parallel elements (Netgen's
    // `property topology relaxed`). Two 1 fF capacitors are one of 2 fF, two
    // 100 Ω resistors one of 50 Ω, no count left; 1 fF with m = 2 is 2 fF;
    // capacitors stating no value keep a count of two. Strict: 1 fF, m = 2.
    const r = id(42);
    const c = id(43);
    const parallel = struct {
        fn f(kind: DeviceKind, model: StrId, params: []const []const P) !Graph {
            var b = common.GraphBuilder.init(2);
            defer b.deinit();
            for (params) |stated| {
                const ends: []const T = if (kind == .resistor) &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 0 }, 1 } } else &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 1 }, 1 } };
                _ = try b.deviceWithParams(kind, model, ends, stated);
            }
            return b.finish();
        }
    }.f;
    const relaxed: lvs.ParamNames = .{ .multiplier = mult, .values = .{ r, c, null, null, null, null }, .relaxed = true };
    var strict = relaxed;
    strict.relaxed = false;
    var caps = try parallel(.capacitor, cap_model, &.{ &.{.{ c, 1e-15 }}, &.{.{ c, 1e-15 }} });
    defer caps.deinit(gpa);
    var rc = try common.reduce(&caps, relaxed);
    defer rc.deinit();
    try testing.expectEqual(@as(u32, 1), rc.g.deviceCount());
    try common.expectParams(&rc.g, 0, &.{.{ c, 2e-15 }});
    var sc = try common.reduce(&caps, strict);
    defer sc.deinit();
    try testing.expectEqual(@as(u32, 1), sc.g.deviceCount());
    try common.expectParams(&sc.g, 0, &.{ .{ mult, 2.0 }, .{ c, 1e-15 } });
    var res = try parallel(.resistor, common.res, &.{ &.{.{ r, 100.0 }}, &.{.{ r, 100.0 }} });
    defer res.deinit(gpa);
    var rr = try common.reduce(&res, relaxed);
    defer rr.deinit();
    try testing.expectEqual(@as(u32, 1), rr.g.deviceCount());
    try common.expectParams(&rr.g, 0, &.{.{ r, 50.0 }});
    var counted = try parallel(.capacitor, cap_model, &.{&.{ .{ c, 1e-15 }, .{ mult, 2.0 } }});
    defer counted.deinit(gpa);
    var rcount = try common.reduce(&counted, relaxed);
    defer rcount.deinit();
    try common.expectParams(&rcount.g, 0, &.{.{ c, 2e-15 }});
    var bare = try parallel(.capacitor, cap_model, &.{ &.{}, &.{} });
    defer bare.deinit(gpa);
    var rb = try common.reduce(&bare, relaxed);
    defer rb.deinit();
    try testing.expectEqual(@as(u32, 1), rb.g.deviceCount());
    try common.expectParams(&rb.g, 0, &.{.{ mult, 2.0 }});
}

test "must connect nets are one net to compare" {
    // Oracle: KLayout's `connect_implicit` ("the subnets are connected")
    // and `connect_explicit`, by hand. Two sources on two nets both labelled
    // VDD do not match a reference tying both to one VDD; once `VDD*` is
    // must-connect, or VDD and VCC are joined explicitly, they do. A
    // pattern matching nothing changes nothing.
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const vdd = try strings.intern(gpa, "VDD");
    const vcc = try strings.intern(gpa, "VCC");
    const out1 = try strings.intern(gpa, "OUT1");
    const out2 = try strings.intern(gpa, "OUT2");
    const gate = try strings.intern(gpa, "G");
    const Split = struct {
        fn f(names: [5]StrId) !Graph {
            var b = common.GraphBuilder.init(6);
            defer b.deinit();
            for (names, 0..) |name, net| {
                try b.nameNet(@intCast(net), name);
                try b.port(@intCast(net));
            }
            for ([_][2]u32{ .{ 1, 3 }, .{ 2, 4 } }) |sd| _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 5 } });
            return b.finish();
        }
    };
    var tb = common.GraphBuilder.init(5);
    defer tb.deinit();
    for ([_]StrId{ gate, vdd, out1, out2 }, 0..) |name, net| {
        try tb.nameNet(@intCast(net), name);
        try tb.port(@intCast(net));
    }
    for ([_]u32{ 2, 3 }) |d| _ = try tb.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, d }, .{ .bulk, 4 } });
    var tied = try tb.finish();
    defer tied.deinit(gpa);
    const joined = struct {
        fn f(layout: *const Graph, reference: *const Graph, controls: *const LvsControls, s: *const StrTable) !bool {
            var g = try layout.clone(gpa);
            defer g.deinit(gpa);
            try lvs.joinMustConnect(gpa, &g, controls, s);
            return matches(&g, reference, &no_controls);
        }
    }.f;
    var same = try Split.f(.{ gate, vdd, vdd, out1, out2 });
    defer same.deinit(gpa);
    try testing.expect(!try joined(&same, &tied, &no_controls, &strings));
    try testing.expect(try joined(&same, &tied, &.{ .connect_implicit = &.{"VDD*"} }, &strings));
    try testing.expect(!try joined(&same, &tied, &.{ .connect_implicit = &.{"GND*"} }, &strings));
    var renamed = try Split.f(.{ gate, vdd, vcc, out1, out2 });
    defer renamed.deinit(gpa);
    try testing.expect(!try joined(&renamed, &tied, &.{ .connect_implicit = &.{"VDD*"} }, &strings));
    try testing.expect(try joined(&renamed, &tied, &.{ .connect_explicit = &.{&.{ vdd, vcc }} }, &strings));
}

test "value thresholds leave out parasitic passives as opens" {
    // Oracle: KLayout's `max_res` and `min_caps` ("ignore resistor devices
    // with a resistance value above the given threshold", "capacitance ...
    // below"), by hand. A 10 MΩ resistor and a 5 aF capacitor across a
    // transistor match the transistor alone once max_res is 1 MΩ and
    // min_caps 10 aF, not with one alone, nor past the values; a resistor
    // stating no value is never above the threshold.
    const r = id(42);
    const c = id(43);
    const options: lvs.CompareOptions = .{ .params = .{ .values = .{ r, c, null, null, null, null } } };
    const circuit = struct {
        fn f(passives: []const struct { DeviceKind, StrId, f64 }) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.device(.mos, nch, &.{ .{ .gate, 2 }, .{ .source, 0 }, .{ .drain, 1 }, .{ .bulk, 3 } });
            for (passives) |p| {
                const model = if (p[0] == .resistor) common.res else cap_model;
                const params: []const P = if (p[2] > 0.0) &.{.{ p[1], p[2] }} else &.{};
                _ = try b.deviceWithParams(p[0], model, &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 1 }, 1 } }, params);
            }
            return b.finish();
        }
    }.f;
    var layout = try circuit(&.{ .{ .resistor, r, 10e6 }, .{ .capacitor, c, 5e-18 } });
    defer layout.deinit(gpa);
    var reference = try circuit(&.{});
    defer reference.deinit(gpa);
    for ([_]struct { ?f64, ?f64, bool }{
        .{ null, null, false }, .{ 1e6, 10.0, true },   .{ 1e6, null, false },
        .{ null, 10.0, false }, .{ 20e6, 10.0, false }, .{ 1e6, 1.0, false },
    }) |row| {
        try testing.expectEqual(row[2], try matchesWith(&layout, &reference, options, &.{ .max_res = row[0], .min_caps = row[1] }));
    }
    var unvalued = try circuit(&.{.{ .resistor, r, 0.0 }});
    defer unvalued.deinit(gpa);
    try testing.expect(!try matchesWith(&unvalued, &reference, options, &.{ .max_res = 1.0 }));
}

test "same nets hold two named nets together" {
    // Oracle: KLayout's `same_nets!` ("if the specified nets do not match,
    // an error is reported"), by hand. Two symmetric transistors; a
    // reference crossing their labels matches by structure. Pairing A with
    // A and X with X breaks the symmetry the wrong way; A with A and X with
    // Y matches; a row naming a net neither side has changes nothing.
    const a = id(70);
    const b_name = id(71);
    const x = id(72);
    const y = id(73);
    const vss = id(74);
    const nowhere = id(75);
    const pair = struct {
        fn f(names: [5]StrId) !Graph {
            var b = common.GraphBuilder.init(5);
            defer b.deinit();
            for (names, 0..) |name, net| {
                try b.nameNet(@intCast(net), name);
                try b.port(@intCast(net));
            }
            for (0..2) |k| {
                const kk: u32 = @intCast(k);
                _ = try b.device(.mos, nch, &.{ .{ .gate, kk }, .{ .source, 4 }, .{ .drain, 2 + kk }, .{ .bulk, 4 } });
            }
            return b.finish();
        }
    }.f;
    var layout = try pair(.{ a, b_name, x, y, vss });
    defer layout.deinit(gpa);
    var crossed = try pair(.{ a, b_name, y, x, vss });
    defer crossed.deinit(gpa);
    try testing.expect(try matches(&layout, &crossed, &no_controls));
    try testing.expect(!try matches(&layout, &crossed, &.{ .same_nets = &.{ .{ .layout = a, .reference = a }, .{ .layout = x, .reference = x } } }));
    try testing.expect(try matches(&layout, &crossed, &.{ .same_nets = &.{ .{ .layout = a, .reference = a }, .{ .layout = x, .reference = y } } }));
    try testing.expect(try matches(&layout, &crossed, &.{ .same_nets = &.{.{ .layout = nowhere, .reference = nowhere }} }));
}

test "relaxed series passives combine their value by its law" {
    // Oracle: closed form, Kirchhoff's laws in series as KLayout's serial
    // combiners state them (R = R1 + R2, L adding; C = C1 C2/(C1 + C2);
    // area adding), and Netgen's relaxed topology. Three 100 Ω resistors
    // through two internal nets are one of 300 Ω, l 3 µm, area 3 µm²; two
    // 2 fF capacitors plate to plate are one of 1 fF keeping their plates.
    // None merges strict, through a port, with w differing, in a ring, tail
    // to tail for ordered plates (it does once permuted), or without a value.
    const r = id(42);
    const c = id(43);
    const area = id(44);
    const relaxed: lvs.ParamNames = .{ .length = length, .width = width, .multiplier = mult, .values = .{ r, c, area, null, null, null }, .relaxed = true };
    var strict = relaxed;
    strict.relaxed = false;
    const resistor = [_]P{ .{ r, 100.0 }, .{ length, 1e-6 }, .{ width, 2e-7 }, .{ area, 1e-12 } };
    const p0: TerminalRole = .{ .pin = 0 };
    const p1: TerminalRole = .{ .pin = 1 };
    const three = [_]Card{ .{ &.{ .{ p0, 0 }, .{ p0, 1 } }, &resistor }, .{ &.{ .{ p0, 1 }, .{ p0, 2 } }, &resistor }, .{ &.{ .{ p0, 2 }, .{ p0, 3 } }, &resistor } };
    var chain = try build(.resistor, common.res, 4, &.{ 0, 3 }, &three);
    defer chain.deinit(gpa);
    var out = try common.reduce(&chain, relaxed);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    try testing.expectEqual(@as(u32, 2), out.g.netCount());
    for ([_]P{ .{ r, 300.0 }, .{ length, 3e-6 }, .{ width, 2e-7 }, .{ area, 3e-12 } }) |want| {
        try testing.expect(close(paramOf(&out.g, 0, want[0]).?, want[1]));
    }
    var so = try common.reduce(&chain, strict);
    defer so.deinit();
    try testing.expectEqual(@as(u32, 3), so.g.deviceCount());
    var through_port = try build(.resistor, common.res, 4, &.{ 0, 1, 3 }, &three);
    defer through_port.deinit(gpa);
    var tp = try common.reduce(&through_port, relaxed);
    defer tp.deinit();
    try testing.expectEqual(@as(u32, 2), tp.g.deviceCount());
    const narrow = [_]P{ .{ r, 100.0 }, .{ length, 1e-6 }, .{ width, 1e-7 }, .{ area, 1e-12 } };
    var mixed = try build(.resistor, common.res, 3, &.{ 0, 2 }, &.{ .{ &.{ .{ p0, 0 }, .{ p0, 1 } }, &resistor }, .{ &.{ .{ p0, 1 }, .{ p0, 2 } }, &narrow } });
    defer mixed.deinit(gpa);
    var mo = try common.reduce(&mixed, relaxed);
    defer mo.deinit();
    try testing.expectEqual(@as(u32, 2), mo.g.deviceCount());
    var ring = try build(.resistor, common.res, 3, &.{}, &.{ .{ &.{ .{ p0, 0 }, .{ p0, 1 } }, &resistor }, .{ &.{ .{ p0, 1 }, .{ p0, 2 } }, &resistor }, .{ &.{ .{ p0, 2 }, .{ p0, 0 } }, &resistor } });
    defer ring.deinit(gpa);
    var ro = try common.reduce(&ring, relaxed);
    defer ro.deinit();
    try testing.expectEqual(@as(u32, 3), ro.g.deviceCount());
    var bare = try build(.resistor, common.res, 3, &.{ 0, 2 }, &.{ .{ &.{ .{ p0, 0 }, .{ p0, 1 } }, &.{} }, .{ &.{ .{ p0, 1 }, .{ p0, 2 } }, &.{} } });
    defer bare.deinit(gpa);
    var bo = try common.reduce(&bare, relaxed);
    defer bo.deinit();
    try testing.expectEqual(@as(u32, 2), bo.g.deviceCount());

    const cap = [_]P{.{ c, 2e-15 }};
    var caps = try build(.capacitor, cap_model, 3, &.{ 0, 2 }, &.{ .{ &.{ .{ p0, 0 }, .{ p1, 1 } }, &cap }, .{ &.{ .{ p0, 1 }, .{ p1, 2 } }, &cap } });
    defer caps.deinit(gpa);
    var co = try common.reduce(&caps, relaxed);
    defer co.deinit();
    try testing.expectEqual(@as(u32, 1), co.g.deviceCount());
    try testing.expect(close(co.g.paramsOf(0)[0].value, 1e-15));
    const t = co.g.terminalsOf(0);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, t.nets);
    try testing.expect(lvs.graph.roleEql(t.roles[0], p0) and lvs.graph.roleEql(t.roles[1], p1));
    var tail = try build(.capacitor, cap_model, 3, &.{ 0, 2 }, &.{ .{ &.{ .{ p0, 0 }, .{ p1, 1 } }, &cap }, .{ &.{ .{ p0, 2 }, .{ p1, 1 } }, &cap } });
    defer tail.deinit(gpa);
    var to = try common.reduce(&tail, relaxed);
    defer to.deinit();
    try testing.expectEqual(@as(u32, 2), to.g.deviceCount());
    const p8: TerminalRole = .{ .pin = 8 };
    var permuted = try build(.capacitor, cap_model, 3, &.{ 0, 2 }, &.{ .{ &.{ .{ p8, 0 }, .{ p8, 1 } }, &cap }, .{ &.{ .{ p8, 2 }, .{ p8, 1 } }, &cap } });
    defer permuted.deinit(gpa);
    var po = try common.reduce(&permuted, relaxed);
    defer po.deinit();
    try testing.expectEqual(@as(u32, 1), po.g.deviceCount());
}

test "only an asymmetric transistor's ends are fixed and reported as drawn" {
    // Oracle: the definition (controls.rs in-file test). Only the asymmetric
    // model's source and drain take the fixed roles, in both directions of
    // the incidence, and a terminal mismatch on it is named by its drawn
    // role again; the other model's is left alone.
    const dmos = id(1);
    const nmos = id(2);
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    for ([_]StrId{ dmos, nmos }) |m| _ = try b.device(.mos, m, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    var g = try b.finish();
    defer g.deinit(gpa);
    const controls: LvsControls = .{ .asymmetric = &.{dmos} };
    try lvs.controls.assignRoles(gpa, &g, &controls);
    const fixed_source = lvs.controls.fixed_source;
    const fixed_drain = lvs.controls.fixed_drain;
    const r0 = g.terminalsOf(0).roles;
    try testing.expect(lvs.graph.roleEql(r0[1], fixed_source) and lvs.graph.roleEql(r0[2], fixed_drain) and r0[0] == .gate and r0[3] == .bulk);
    const r1 = g.terminalsOf(1).roles;
    try testing.expect(r1[1] == .source and r1[2] == .drain);
    const on1 = g.terminalsOn(1);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, on1.devices);
    try testing.expect(lvs.graph.roleEql(on1.roles[0], fixed_source) and on1.roles[1] == .source);
    var found = [_]lvs.Discrepancy{
        .{ .terminal_mismatch = .{ .layout_device = 0, .ref_device = 0, .role = fixed_drain } },
        .{ .terminal_mismatch = .{ .layout_device = 1, .ref_device = 1, .role = fixed_drain } },
    };
    lvs.controls.reportRoles(&found, &g, &controls);
    try testing.expect(found[0].terminal_mismatch.role == .drain);
    try testing.expect(lvs.graph.roleEql(found[1].terminal_mismatch.role, fixed_drain));
}

test "permutations chain with the default classes" {
    // Oracle: the definition (deck.md: "permutations chain"; controls.rs
    // in-file test). Permuting a transistor's gate with its source joins the
    // default source-drain class: gate, source, drain one class under pin 8,
    // bulk alone; asymmetric, only gate and source join and the drain stays
    // fixed. A capacitor's permuted plates are pin 8 and report as pin 0.
    const dmos = id(1);
    const Classes = lvs.controls.Classes;
    const gate_source: LvsControls = .{ .permute = &.{.{ .model = dmos, .a = 0, .b = 1 }} };
    const c1 = Classes.of(.mos, dmos, &gate_source).?;
    for ([_]TerminalRole{ .{ .pin = 8 }, .{ .pin = 8 }, .{ .pin = 8 }, .bulk }, 0..) |want, p| try testing.expect(lvs.graph.roleEql(want, c1.role(@intCast(p))));
    const asymmetric: LvsControls = .{ .permute = gate_source.permute, .asymmetric = &.{dmos} };
    const c2 = Classes.of(.mos, dmos, &asymmetric).?;
    for ([_]TerminalRole{ .{ .pin = 8 }, .{ .pin = 8 }, lvs.controls.fixed_drain, .bulk }, 0..) |want, p| try testing.expect(lvs.graph.roleEql(want, c2.role(@intCast(p))));
    const plates: LvsControls = .{ .permute = &.{.{ .model = dmos, .a = 1, .b = 0 }} };
    const c3 = Classes.of(.capacitor, dmos, &plates).?;
    try testing.expect(lvs.graph.roleEql(c3.role(0), .{ .pin = 8 }) and lvs.graph.roleEql(c3.role(1), .{ .pin = 8 }));
    try testing.expect(lvs.graph.roleEql(c3.reported(.{ .pin = 8 }), .{ .pin = 0 }));
    try testing.expect(Classes.of(.mos, id(2), &plates) == null);
}
