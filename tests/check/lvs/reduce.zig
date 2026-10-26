//! Series and parallel reduction: what merges, what must not, and what
//! comes through untouched. `LVS_SERIES` (two nmos in series, gates
//! strapped) and `LVS_FINGERS` (the same minus the strap) are `seriesPair`
//! with one `u32` changed. Ported from crates/check/tests/lvs/reduce.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
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

/// The names the sized tests merge by; `nf`, `m` and the diffusions are
/// spare ids.
const names: lvs.ParamNames = .{ .width = width, .length = length, .fingers = id(90), .multiplier = m_name, .diffusion = .{ as_name, ad_name, ps_name, pd_name } };

const as_name = id(93);

const ad_name = id(94);

const ps_name = id(95);

const pd_name = id(96);

/// A resistor's `r`, a spare id.
const r_value = id(92);

const m_name = id(91);

/// The length every stacked device states (testing-plan F67).
const short = [_]P{.{ length, 1.5e-7 }};

// ---- private ----

fn seriesPair(gate_b: u32) !Graph {
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &short);
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, gate_b }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &short);
    return b.finish();
}

fn seriesPairTight() !Graph {
    var b = common.GraphBuilder.init(5);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &short);
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &short);
    return b.finish();
}

fn parallelPair(model_b: StrId, source_b: u32, drain_b: u32) !Graph {
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    _ = try b.device(.mos, model_b, &.{ .{ .gate, 0 }, .{ .source, source_b }, .{ .drain, drain_b }, .{ .bulk, 3 } });
    return b.finish();
}

fn expectTerminals(g: *const Graph, device: u32, want: []const T) !void {
    const t = g.terminalsOf(device);
    try testing.expectEqual(want.len, t.nets.len);
    for (want, t.nets, t.roles) |w, n, r| {
        try testing.expectEqual(w[1], n);
        try testing.expect(lvs.graph.roleEql(w[0], r));
    }
}

fn reduceSized(src: *const Graph) !common.Reduced {
    return common.reduce(src, names);
}

fn reducePlain(src: *const Graph) !common.Reduced {
    return common.reduce(src, .{});
}

/// `src` reduces to itself under `n`.
fn expectUnchanged(src: *const Graph, n: lvs.ParamNames) !void {
    var r = try common.reduce(src, n);
    defer r.deinit();
    try common.expectGraphEql(src, &r.g);
}

fn sized() lvs.CompareOptions {
    return .{ .params = names };
}

fn expectMatchOf(a: *const Graph, b: *const Graph, o: lvs.CompareOptions) !void {
    var r = try common.compare(a, b, o);
    defer r.deinit(gpa);
    try common.expectMatch(&r);
}

fn expectNotMatchOf(a: *const Graph, b: *const Graph, o: lvs.CompareOptions) !void {
    var r = try common.compare(a, b, o);
    defer r.deinit(gpa);
    try common.expectNotMatch(&r);
}

fn sizedFingers(upper: []const P) !Graph {
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{ .{ width, 2e-6 }, .{ length, 1.5e-7 } });
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 1 }, .{ .bulk, 3 } }, upper);
    return b.finish();
}

/// Passives of `kind` across nets 0 and 1, one per entry of `params`.
fn passives(kind: DeviceKind, params: []const []const P) !Graph {
    var b = common.GraphBuilder.init(2);
    defer b.deinit();
    for (params) |stated| _ = try b.deviceWithParams(kind, common.res, &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 1 }, 1 } }, stated);
    return b.finish();
}

fn pmOnly(r: *const common.Result, layout_value: f64, ref_value: f64) !void {
    try common.assertSame(try common.discrepancies(r), &.{.{ .parameter_mismatch = .{ .layout_device = 0, .ref_device = 0, .param = m_name, .layout_value = layout_value, .ref_value = ref_value } }});
}

test "two transistors in series with tied gates become one" {
    // Oracle: construct-from-answer. Two channels meeting at one internal
    // node, gates strapped: one transistor of twice the length. Its
    // terminals are the shared gate and bulk and the two outer channel ends.
    var src = try seriesPair(0);
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    // Net 2 consumed; 0, 1, 3, 4, 5 rank down to 0..4.
    try testing.expectEqual(@as(u32, 5), out.g.netCount());
    try expectTerminals(&out.g, 0, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    try testing.expectEqualSlices(DeviceKind, &.{.mos}, out.g.device_kind.items);
    try testing.expectEqualSlices(StrId, &.{nch}, out.g.device_model.items);
    try common.expectParams(&out.g, 0, &.{.{ length, 3e-7 }});
}

test "the same pair with its gates on two nets stays two devices" {
    // Oracle: construct-from-answer. LVS_FINGERS: two gates on two nets are
    // two transistors however the diffusion is drawn; passed through.
    var src = try seriesPair(5);
    defer src.deinit(gpa);
    try expectUnchanged(&src, names);
}

test "two transistors in parallel become one" {
    // Oracle: construct-from-answer. Two unsized transistors between one
    // pair of nets are one counted twice, m = 2 (F83); no net consumed.
    var src = try parallelPair(nch, 1, 2);
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    try testing.expectEqual(@as(u32, 4), out.g.netCount());
    try expectTerminals(&out.g, 0, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    try common.expectParams(&out.g, 0, &.{.{ m_name, 2.0 }});
}

test "a parallel pair merges with its channel ends exchanged" {
    // Oracle: construct-from-answer. A MOS channel is symmetric, so the same
    // pair with the upper one's ends exchanged is still one device.
    var src = try parallelPair(nch, 2, 1);
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    try expectTerminals(&out.g, 0, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
}

test "unsized parallel transistors match a counted card and not a bare one" {
    // Oracle: construct-from-answer, F83. Two unsized transistors in
    // parallel are one card of m = 2, not a card stating no count (one
    // transistor). With no m name the count has nowhere to go: two stay two.
    const card = struct {
        fn f(params: []const P) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .drain, 2 }, .{ .gate, 0 }, .{ .source, 1 }, .{ .bulk, 3 } }, params);
            return b.finish();
        }
    }.f;
    var layout = try parallelPair(nch, 1, 2);
    defer layout.deinit(gpa);
    var counted = try card(&.{.{ m_name, 2.0 }});
    defer counted.deinit(gpa);
    try expectMatchOf(&layout, &counted, sized());
    var bare = try card(&.{});
    defer bare.deinit(gpa);
    var r = try common.compare(&layout, &bare, sized());
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), (try common.discrepancies(&r)).len);
    try pmOnly(&r, 2.0, 1.0);
    var uncounted = names;
    uncounted.multiplier = null;
    var out = try common.reduce(&layout, uncounted);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 2), out.g.deviceCount());
    try testing.expectEqual(@as(u32, 0), out.merges.len());
}

test "a different model on one side blocks the parallel merge" {
    // Oracle: construct-from-answer. An nfet and a pfet wired identically
    // are two devices; the model is the only difference.
    var src = try parallelPair(pch, 1, 2);
    defer src.deinit(gpa);
    try expectUnchanged(&src, .{});
}

test "a shared node that is a port blocks the series merge" {
    // Oracle: construct-from-answer. A port is where the design meets the
    // cell: something outside may reach it, so it is not collapsed.
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &short);
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &short);
    try b.port(2);
    var src = try b.finish();
    defer src.deinit(gpa);
    try expectUnchanged(&src, names);
}

test "a name alone does not block the series merge" {
    // Oracle: construct-from-answer. Every reference net is named, so a name
    // blocking the merge would leave the reference unreduced (F12).
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &short);
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &short);
    try b.nameNet(2, common.vss);
    var src = try b.finish();
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
}

test "a shared node with a third terminal blocks the series merge" {
    // Oracle: construct-from-answer. A third terminal means current can
    // leave the node; the capacitor is itself unmergeable, so three stay.
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &short);
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &short);
    _ = try b.device(.capacitor, nch, &.{ .{ .{ .pin = 0 }, 2 }, .{ .{ .pin = 1 }, 4 } });
    var src = try b.finish();
    defer src.deinit(gpa);
    try expectUnchanged(&src, names);
}

test "three in series reduce to one" {
    // Oracle: construct-from-answer. Three fingers over two internal nodes
    // are one transistor of three times the length, in one pass. Nets: 0
    // gate, 1 outer source, 2 and 3 internal, 4 outer drain, 5 bulk.
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 } }) |sd| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 5 } }, &short);
    var src = try b.finish();
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    try testing.expectEqual(@as(u32, 4), out.g.netCount());
    try expectTerminals(&out.g, 0, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
}

test "a series merge that creates a parallel pair reduces again" {
    // Oracle: construct-from-answer. Two series pairs sharing both outer
    // nodes (ports) are parallel only after the series merge: the fixed
    // point, not one pass.
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 3 }, .{ 1, 4 }, .{ 4, 3 } }) |sd| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 5 } }, &short);
    try b.port(1);
    try b.port(3);
    var src = try b.finish();
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    try testing.expectEqual(@as(u32, 4), out.g.netCount());
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, out.g.port_net.items);
}

test "reducing an already reduced graph changes nothing" {
    // Oracle: law. Reduction is idempotent, asserted on the shapes that do
    // reduce: the way to break it is a second pass that keeps going.
    var g1 = try seriesPair(0);
    defer g1.deinit(gpa);
    var g2 = try parallelPair(nch, 1, 2);
    defer g2.deinit(gpa);
    var g3 = try seriesPairTight();
    defer g3.deinit(gpa);
    for ([_]*const Graph{ &g1, &g2, &g3 }) |src| {
        var once = try reduceSized(src);
        defer once.deinit();
        try expectUnchanged(&once.g, names);
    }
}

test "an unreducible graph comes through byte identical" {
    // Oracle: law. A graph holding no merge passes through in every column,
    // the empty graph (whose CSR columns are absent) included.
    var empty: Graph = .{};
    try expectUnchanged(&empty, .{});
    var a = try common.mosAndBjt();
    defer a.deinit(gpa);
    try expectUnchanged(&a, .{});
    var b = try seriesPair(5);
    defer b.deinit(gpa);
    try expectUnchanged(&b, .{});
}

test "a declared parameter blocks the merge rather than being invented" {
    // Oracle: construct-from-answer. Told no names, nothing tells W from L,
    // so a device declaring a parameter does not merge: fail-closed.
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    for (0..2) |_| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{ .{ width, 1.0 }, .{ length, 0.15 } });
    var src = try b.finish();
    defer src.deinit(gpa);
    try expectUnchanged(&src, .{});
}

test "exchanging two devices of one group does not move the result" {
    // Oracle: law. The two devices of a merge group are exchangeable;
    // reduction reads device order for emission order only.
    var g1 = try seriesPair(0);
    defer g1.deinit(gpa);
    var g2 = try seriesPairTight();
    defer g2.deinit(gpa);
    for ([_]*const Graph{ &g1, &g2 }) |src| {
        const nets = try gpa.alloc(u32, src.netCount());
        defer gpa.free(nets);
        for (nets, 0..) |*n, i| n.* = @intCast(i);
        var swapped = try common.permute(src, &.{ 1, 0 }, nets);
        defer swapped.deinit(gpa);
        try testing.expect(!common.graphEql(&swapped, src));
        var x = try reduceSized(&swapped);
        defer x.deinit();
        var y = try reduceSized(src);
        defer y.deinit();
        try common.expectGraphEql(&y.g, &x.g);
    }
}

test "a reduced layout matches an already reduced reference" {
    // Oracle: construct-from-answer. Two drawn fingers and one written card
    // are one circuit; the reference on its own numbering in M-card order.
    var layout = try seriesPairTight();
    defer layout.deinit(gpa);
    var out = try reduceSized(&layout);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .drain, 3 }, .{ .gate, 1 }, .{ .source, 0 }, .{ .bulk, 2 } }, &.{.{ length, 3e-7 }});
    var reference = try b.finish();
    defer reference.deinit(gpa);
    try expectMatchOf(&layout, &reference, sized());
}

test "an unsized stack stays two and does not match one unsized card" {
    // Oracle: the decision on F67. A series merge sums L; with no L (or L on
    // one device only) there is nothing to sum and the stack stays two; it
    // does not match one unsized card, and does match two.
    const stack = struct {
        fn f(lower: []const P) !Graph {
            var b = common.GraphBuilder.init(5);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, lower);
            _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } });
            return b.finish();
        }
    }.f;
    for ([_][]const P{ &.{}, &short }) |lower| {
        var src = try stack(lower);
        defer src.deinit(gpa);
        try expectUnchanged(&src, .{});
        try expectUnchanged(&src, names);
    }
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .drain, 3 }, .{ .gate, 1 }, .{ .source, 0 }, .{ .bulk, 2 } });
    var one = try b.finish();
    defer one.deinit(gpa);
    var bare = try stack(&.{});
    defer bare.deinit(gpa);
    try expectNotMatchOf(&bare, &one, sized());
    try expectMatchOf(&bare, &bare, sized());
}

test "sized fingers merge summing width when told which parameter is width" {
    // Oracle: Netgen's parallel law: two fingers of one length are one
    // device of their summed width; told no names, sized devices stay apart.
    var fingers = try sizedFingers(&.{ .{ width, 3e-6 }, .{ length, 1.5e-7 } });
    defer fingers.deinit(gpa);
    var plain = try reducePlain(&fingers);
    defer plain.deinit();
    try testing.expectEqual(@as(u32, 2), plain.g.deviceCount());
    var out = try reduceSized(&fingers);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    const p = out.g.paramsOf(0);
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expect(p[0].name == width and @abs(p[0].value - 5e-6) < 1e-12);
    try testing.expect(p[1].name == length and @abs(p[1].value - 1.5e-7) < 1e-15);
    try testing.expectEqual(@as(u32, 1), out.merges.len());
    try testing.expectEqual(lvs.MergeKind.parallel, out.merges.kind.items[0]);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, out.merges.devicesOf(0));
}

test "each merge needs only the name of what it sums" {
    // Oracle: construct-from-answer, F84. Told only L, two 150 nm channels
    // stacked are one of 300 nm; told only W, two 2 µm fingers are one of
    // 4 µm.
    var tight = try seriesPairTight();
    defer tight.deinit(gpa);
    var s = try common.reduce(&tight, .{ .length = length });
    defer s.deinit();
    try testing.expectEqual(@as(u32, 1), s.g.deviceCount());
    try common.expectParams(&s.g, 0, &.{.{ length, 3e-7 }});
    try testing.expectEqual(lvs.MergeKind.series, s.merges.kind.items[0]);
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 1 } }) |sd| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 3 } }, &.{.{ width, 2e-6 }});
    var fingers = try b.finish();
    defer fingers.deinit(gpa);
    var p = try common.reduce(&fingers, .{ .width = width });
    defer p.deinit();
    try testing.expectEqual(@as(u32, 1), p.g.deviceCount());
    try common.expectParams(&p.g, 0, &.{.{ width, 4e-6 }});
    try testing.expectEqual(lvs.MergeKind.parallel, p.merges.kind.items[0]);
}

test "fingers of different length do not merge" {
    // Oracle: Netgen's parallel law merges only devices of one length: 0.15
    // against 0.3 µm, two devices.
    var fingers = try sizedFingers(&.{ .{ width, 2e-6 }, .{ length, 3e-7 } });
    defer fingers.deinit(gpa);
    var out = try reduceSized(&fingers);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 2), out.g.deviceCount());
    try testing.expectEqual(@as(u32, 0), out.merges.len());
}

test "a sized stack merges summing length" {
    // Oracle: the series law: two equal-width devices stacked, gates
    // strapped, are one of their summed length.
    var b = common.GraphBuilder.init(5);
    defer b.deinit();
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 3 } }) |sd| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 4 } }, &.{ .{ width, 1e-6 }, .{ length, 1.5e-7 } });
    var src = try b.finish();
    defer src.deinit(gpa);
    var out = try reduceSized(&src);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    const p = out.g.paramsOf(0);
    try testing.expect(p[0].name == width and @abs(p[0].value - 1e-6) < 1e-15);
    try testing.expect(p[1].name == length and @abs(p[1].value - 3e-7) < 1e-15);
    try testing.expectEqual(lvs.MergeKind.series, out.merges.kind.items[0]);
}

test "a multiplier card matches the fingers it stands for" {
    // Oracle: Netgen's parallel law and SPICE's m: a card of m = 2 at 2 µm
    // is two 2 µm fingers in parallel, which the layout drew.
    var layout = try sizedFingers(&.{ .{ width, 2e-6 }, .{ length, 1.5e-7 } });
    defer layout.deinit(gpa);
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .drain, 2 }, .{ .gate, 0 }, .{ .source, 1 }, .{ .bulk, 3 } }, &.{ .{ width, 2e-6 }, .{ length, 1.5e-7 }, .{ m_name, 2.0 } });
    var card = try b.finish();
    defer card.deinit(gpa);
    try expectMatchOf(&layout, &card, sized());
}

test "parallel passives keep their value and count the devices" {
    // Oracle: the law of the device, F20. Two 1 kΩ resistors in parallel
    // are r = 1k, m = 2; a missing m counts 1, so a third with m = 2 makes
    // m = 4. Every kind but MOS keeps its count this way.
    for ([_]DeviceKind{ .resistor, .capacitor, .diode }) |kind| {
        const k = [_]P{.{ r_value, 1e3 }};
        var two = try passives(kind, &.{ &k, &k });
        defer two.deinit(gpa);
        var out = try reduceSized(&two);
        defer out.deinit();
        try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
        try common.expectParams(&out.g, 0, &.{ .{ m_name, 2.0 }, .{ r_value, 1e3 } });
        try testing.expectEqualSlices(u32, &.{ 0, 1 }, out.merges.devicesOf(0));
        const k2 = [_]P{ .{ r_value, 1e3 }, .{ m_name, 2.0 } };
        var three = try passives(kind, &.{ &k, &k, &k2 });
        defer three.deinit(gpa);
        var out3 = try reduceSized(&three);
        defer out3.deinit();
        try common.expectParams(&out3.g, 0, &.{ .{ m_name, 4.0 }, .{ r_value, 1e3 } });
    }
}

test "counts are compared exactly and values within the tolerance" {
    // Oracle: the definition of a count, F99. m and nf are whole numbers:
    // 50 against 51 (1.96 %, inside 2 %) mismatches on a resistor's m and a
    // transistor's nf; r 1000 against 1019 (1.86 %) agrees.
    const fingers = names.fingers.?;
    const resistor = struct {
        fn f(m: f64) !Graph {
            return passives(.resistor, &.{&.{ .{ r_value, 1e3 }, .{ m_name, m } }});
        }
    }.f;
    const transistor = struct {
        fn f(nf_name: StrId, nf: f64) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{.{ nf_name, nf }});
            return b.finish();
        }
    }.f;
    var r50 = try resistor(50.0);
    defer r50.deinit(gpa);
    var r51 = try resistor(51.0);
    defer r51.deinit(gpa);
    var t50 = try transistor(fingers, 50.0);
    defer t50.deinit(gpa);
    var t51 = try transistor(fingers, 51.0);
    defer t51.deinit(gpa);
    for ([_][2]*const Graph{ .{ &r50, &r51 }, .{ &t50, &t51 } }) |pair| {
        try expectMatchOf(pair[0], pair[0], sized());
        try expectNotMatchOf(pair[0], pair[1], sized());
    }
    var v1 = try passives(.resistor, &.{&.{.{ r_value, 1e3 }}});
    defer v1.deinit(gpa);
    var v2 = try passives(.resistor, &.{&.{.{ r_value, 1019.0 }}});
    defer v2.deinit(gpa);
    try expectMatchOf(&v1, &v2, sized());
}

test "parallel passives stay apart when their values differ or there is no count" {
    // Oracle: construct-from-answer. Values that differ are not one device;
    // with no m name the count has nowhere to go: under-reduction.
    var differ = try passives(.capacitor, &.{ &.{.{ r_value, 1e3 }}, &.{.{ r_value, 2e3 }} });
    defer differ.deinit(gpa);
    var out = try reduceSized(&differ);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 2), out.g.deviceCount());
    var pair = try passives(.capacitor, &.{ &.{}, &.{} });
    defer pair.deinit(gpa);
    try expectUnchanged(&pair, .{});
}

test "a multiplier with no width is kept as the count" {
    // Oracle: the multiplier's definition, F21. m = 2 with no W is two
    // devices in parallel and stays; an m of 1 is every card's and is
    // dropped; a MOS with no W keeps its m too.
    var c2 = try passives(.capacitor, &.{&.{.{ m_name, 2.0 }}});
    defer c2.deinit(gpa);
    var o2 = try reduceSized(&c2);
    defer o2.deinit();
    try common.expectParams(&o2.g, 0, &.{.{ m_name, 2.0 }});
    var c1 = try passives(.capacitor, &.{&.{.{ m_name, 1.0 }}});
    defer c1.deinit(gpa);
    var o1 = try reduceSized(&c1);
    defer o1.deinit();
    try testing.expectEqual(@as(usize, 0), o1.g.paramsOf(0).len);
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{.{ m_name, 2.0 }});
    var mos = try b.finish();
    defer mos.deinit(gpa);
    var om = try reduceSized(&mos);
    defer om.deinit();
    try common.expectParams(&om.g, 0, &.{.{ m_name, 2.0 }});
}

test "a counted card matches two drawn capacitors and not one" {
    // Oracle: construct-from-answer, through the comparison. A card of m = 2
    // is two capacitors in parallel, not one.
    var card = try passives(.capacitor, &.{&.{.{ m_name, 2.0 }}});
    defer card.deinit(gpa);
    var two = try passives(.capacitor, &.{ &.{}, &.{} });
    defer two.deinit(gpa);
    try expectMatchOf(&two, &card, sized());
    var one = try passives(.capacitor, &.{&.{}});
    defer one.deinit(gpa);
    var r = try common.compare(&one, &card, sized());
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), (try common.discrepancies(&r)).len);
    try pmOnly(&r, 1.0, 2.0);
}

test "a card without a count is one device whatever another card states" {
    // Oracle: construct-from-answer. Four capacitors as two parallel pairs
    // against a bare card and an m = 2 card: three devices against four.
    const caps = struct {
        fn f(counts: []const ?f64) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            for (counts, 0..) |count, pair| {
                const at: u32 = 2 * @as(u32, @intCast(pair));
                const stated: []const P = if (count) |m| &.{.{ m_name, m }} else &.{};
                _ = try b.deviceWithParams(.capacitor, common.res, &.{ .{ .{ .pin = 0 }, at }, .{ .{ .pin = 1 }, at + 1 } }, stated);
            }
            return b.finish();
        }
    }.f;
    var b = common.GraphBuilder.init(4);
    defer b.deinit();
    for ([_]u32{ 0, 0, 2, 2 }) |at| _ = try b.device(.capacitor, common.res, &.{ .{ .{ .pin = 0 }, at }, .{ .{ .pin = 1 }, at + 1 } });
    var drawn = try b.finish();
    defer drawn.deinit(gpa);
    var three = try caps(&.{ null, 2.0 });
    defer three.deinit(gpa);
    try expectNotMatchOf(&drawn, &three, sized());
    var four = try caps(&.{ 2.0, 2.0 });
    defer four.deinit(gpa);
    try expectMatchOf(&drawn, &four, sized());
}

test "parallel transistors with source and drain shorted merge" {
    // Oracle: the parallel law, F57. Two transistors with sources and drains
    // all on net 1 are on the same nets role for role: one of their summed
    // width, the head's terminals.
    const shorted = struct {
        fn f(widths: []const f64) !Graph {
            var b = common.GraphBuilder.init(3);
            defer b.deinit();
            for (widths) |w| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 1 }, .{ .bulk, 2 } }, &.{ .{ width, w }, .{ length, 1.5e-7 } });
            return b.finish();
        }
    }.f;
    var two = try shorted(&.{ 1e-6, 1e-6 });
    defer two.deinit(gpa);
    var out = try reduceSized(&two);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
    try expectTerminals(&out.g, 0, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 1 }, .{ .bulk, 2 } });
    try common.expectParams(&out.g, 0, &.{ .{ width, 2e-6 }, .{ length, 1.5e-7 } });
    var one = try shorted(&.{2e-6});
    defer one.deinit(gpa);
    try expectMatchOf(&two, &one, sized());
}

test "diffusions are summed at their channel end and stop a series merge" {
    // Oracle: construct-from-answer, F16. A diffusion belongs to its channel
    // end: merged with the lower's terminals, net 1 holds 1 + 4 = 5 and
    // 10 + 40 = 50, net 2 holds 2 + 30 = 32 and 20 + 300 = 320. A card's
    // m = 2 multiplies its diffusions as its W; a stack stating diffusions
    // does not merge in series.
    const finger = struct {
        fn add(b: *common.GraphBuilder, sd_nets: [2]u32, sd: [4]f64) !void {
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd_nets[0] }, .{ .drain, sd_nets[1] }, .{ .bulk, 3 } }, &.{ .{ width, 1e-6 }, .{ as_name, sd[0] }, .{ ad_name, sd[1] }, .{ ps_name, sd[2] }, .{ pd_name, sd[3] } });
        }
    }.add;
    var pb = common.GraphBuilder.init(4);
    defer pb.deinit();
    try finger(&pb, .{ 1, 2 }, .{ 1.0, 2.0, 10.0, 20.0 });
    try finger(&pb, .{ 2, 1 }, .{ 30.0, 4.0, 300.0, 40.0 });
    var pair = try pb.finish();
    defer pair.deinit(gpa);
    var out = try reduceSized(&pair);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.merges.len());
    try common.expectParams(&out.g, 0, &.{ .{ width, 2e-6 }, .{ as_name, 5.0 }, .{ ad_name, 32.0 }, .{ ps_name, 50.0 }, .{ pd_name, 320.0 } });
    var cb = common.GraphBuilder.init(4);
    defer cb.deinit();
    _ = try cb.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{ .{ width, 1e-6 }, .{ as_name, 1.0 }, .{ pd_name, 20.0 }, .{ m_name, 2.0 } });
    var card = try cb.finish();
    defer card.deinit(gpa);
    var oc = try reduceSized(&card);
    defer oc.deinit();
    try common.expectParams(&oc.g, 0, &.{ .{ width, 2e-6 }, .{ as_name, 2.0 }, .{ pd_name, 40.0 } });
    var sb = common.GraphBuilder.init(5);
    defer sb.deinit();
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 3 } }) |sd| _ = try sb.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, sd[0] }, .{ .drain, sd[1] }, .{ .bulk, 4 } }, &.{ .{ length, 1.5e-7 }, .{ as_name, 1.0 }, .{ ad_name, 1.0 }, .{ ps_name, 1.0 }, .{ pd_name, 1.0 } });
    var stack = try sb.finish();
    defer stack.deinit(gpa);
    try expectUnchanged(&stack, names);
}

test "a diffusion is compared at its channel end" {
    // Oracle: construct-from-answer, F16. A resistor from net 1 to net 0
    // tells net 1 from net 2: a card drain first with `as` 2 on its source
    // (net 2) and `ad` 1 is the same transistor; one with `as` 1 on net 2 is
    // not.
    const circuit = struct {
        fn f(source: u32, drain: u32, sd: [2]f64) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, source }, .{ .drain, drain }, .{ .bulk, 3 } }, &.{ .{ as_name, sd[0] }, .{ ad_name, sd[1] } });
            _ = try b.device(.resistor, common.res, &.{ .{ .{ .pin = 0 }, 1 }, .{ .{ .pin = 0 }, 0 } });
            return b.finish();
        }
    }.f;
    var layout = try circuit(1, 2, .{ 1e-12, 2e-12 });
    defer layout.deinit(gpa);
    var same = try circuit(2, 1, .{ 2e-12, 1e-12 });
    defer same.deinit(gpa);
    try expectMatchOf(&layout, &same, sized());
    var wrong = try circuit(2, 1, .{ 1e-12, 2e-12 });
    defer wrong.deinit(gpa);
    try expectNotMatchOf(&layout, &wrong, sized());
}

test "diffusions on symmetric channel nets pair the way they agree" {
    // Oracle: construct-from-answer, F98. Nothing tells net 1 from net 2;
    // the mirrored card is the same transistor once the nets trade names; a
    // card mirroring areas but not perimeters agrees under neither
    // orientation, nor one stating 2 at both ends.
    const circuit = struct {
        fn f(sd: [4]f64) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{ .{ as_name, sd[0] }, .{ ad_name, sd[1] }, .{ ps_name, sd[2] }, .{ pd_name, sd[3] } });
            return b.finish();
        }
    }.f;
    var layout = try circuit(.{ 1.0, 2.0, 10.0, 20.0 });
    defer layout.deinit(gpa);
    var mirrored = try circuit(.{ 2.0, 1.0, 20.0, 10.0 });
    defer mirrored.deinit(gpa);
    try expectMatchOf(&layout, &mirrored, sized());
    for ([_][4]f64{ .{ 2.0, 1.0, 10.0, 20.0 }, .{ 2.0, 2.0, 10.0, 20.0 } }) |sd| {
        var card = try circuit(sd);
        defer card.deinit(gpa);
        try expectNotMatchOf(&layout, &card, sized());
    }
}

test "a stack of two models stays two devices" {
    // Oracle: the series law's precondition: one kind and one model. The
    // tight bracket with the upper device pch stays two; one model is one.
    var b = common.GraphBuilder.init(5);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &short);
    _ = try b.deviceWithParams(.mos, pch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &short);
    var mixed = try b.finish();
    defer mixed.deinit(gpa);
    try expectUnchanged(&mixed, names);
    var tight = try seriesPairTight();
    defer tight.deinit(gpa);
    var out = try reduceSized(&tight);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 1), out.g.deviceCount());
}
