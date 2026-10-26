//! Verdicts: what a comparison concluded, and whether it is entitled to.
//! "Mismatch" is not a result, so a perturbation made in one known place
//! must be reported there; and there is no path from "gave up" to
//! "matched". Ported from crates/check/tests/lvs/compare.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
const Netlist = ingest.netlist.Netlist;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const Discrepancy = lvs.Discrepancy;
const Rng = @import("testgen").Rng;
const common = @import("common.zig");
const id = common.id;
const nch = common.nch;
const npn = common.npn;
const width = common.width;
const length = common.length;
const gpa = testing.allocator;

// ---- private ----

fn verdictOf(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions) !common.Result {
    return common.compare(layout, reference, options);
}

fn expectMatchOf(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions) !void {
    var r = try verdictOf(layout, reference, options);
    defer r.deinit(gpa);
    try common.expectMatch(&r);
}

fn expectNotMatchOf(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions) !void {
    var r = try verdictOf(layout, reference, options);
    defer r.deinit(gpa);
    try common.expectNotMatch(&r);
}

fn expectSameOf(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions, expected: []const Discrepancy) !void {
    var r = try verdictOf(layout, reference, options);
    defer r.deinit(gpa);
    try common.assertSame(try common.discrepancies(&r), expected);
}

fn pm(layout_device: u32, ref_device: u32, param: StrId, layout_value: f64, ref_value: f64) Discrepancy {
    return .{ .parameter_mismatch = .{ .layout_device = layout_device, .ref_device = ref_device, .param = param, .layout_value = layout_value, .ref_value = ref_value } };
}

/// A two-terminal device of `kind` from net `first` to `second`, beside a
/// transistor whose gate sits on net 0, so exchanging the ends is no
/// relabelling.
fn anchoredTwoTerminal(kind: DeviceKind, first: u32, second: u32) !Netlist {
    var n: Netlist = .{};
    errdefer n.deinit(gpa);
    try n.subckt_name.append(gpa, id(30));
    try n.subckt_port_start.appendSlice(gpa, &.{ 0, 0 });
    try n.subckt_device_start.appendSlice(gpa, &.{ 0, 2 });
    try n.device_model.appendSlice(gpa, &.{ id(40), nch });
    try n.device_kind.appendSlice(gpa, &.{ kind, .mos });
    try n.device_terminal_start.appendSlice(gpa, &.{ 0, 2, 6 });
    for ([_]u32{ first, second, 0, 2, 3, 3 }) |t| try n.terminal_net.append(gpa, @fromBackingInt(@intCast(t)));
    try n.device_param_start.appendSlice(gpa, &.{ 0, 0, 0 });
    for (50..54) |k| try n.net_name.append(gpa, id(@intCast(k)));
    try n.net_subckt.appendNTimes(gpa, @fromBackingInt(@intCast(0)), 4);
    return n;
}

fn referenceVerdict(kind: DeviceKind, swapped: bool) !common.Result {
    var drawn_n = try anchoredTwoTerminal(kind, 0, 1);
    defer drawn_n.deinit(gpa);
    var written_n = if (swapped) try anchoredTwoTerminal(kind, 1, 0) else try anchoredTwoTerminal(kind, 0, 1);
    defer written_n.deinit(gpa);
    var drawn: Graph = .{};
    defer drawn.deinit(gpa);
    var written: Graph = .{};
    defer written.deinit(gpa);
    try lvs.fromReferenceInto(gpa, &drawn_n, @fromBackingInt(@intCast(0)), &drawn);
    try lvs.fromReferenceInto(gpa, &written_n, @fromBackingInt(@intCast(0)), &written);
    return common.compare(&drawn, &written, common.decisive());
}

/// Two NMOS in series from net 1 to 3 through 2, gates on 0, bulk on 4,
/// each stating `L`; nets 0, 1, 3, 4 named ports, `middle` names net 2 and
/// `middle_port` makes it a port too.
fn seriesStack(middle: ?StrId, middle_port: bool) !Graph {
    var b = common.GraphBuilder.init(5);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } }, &.{.{ length, 1.5e-7 }});
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } }, &.{.{ length, 1.5e-7 }});
    for ([_][2]u32{ .{ 0, 60 }, .{ 1, 61 }, .{ 3, 63 }, .{ 4, 64 } }) |row| {
        try b.nameNet(row[0], id(row[1]));
        try b.port(row[0]);
    }
    if (middle) |name| try b.nameNet(2, name);
    if (middle_port) try b.port(2);
    return b.finish();
}

/// `decisive`, told which parameters are `L` and `W`, so a stack can merge.
fn sized() lvs.CompareOptions {
    var o = common.decisive();
    o.params = .{ .length = length, .width = width };
    return o;
}

/// Three-terminal MOS `(gate, source, drain, width)` on `nets` nets.
fn mosCircuit(nets: u32, devices: []const struct { u32, u32, u32, f64 }) !Graph {
    var b = common.GraphBuilder.init(nets);
    defer b.deinit();
    for (devices) |d| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, d[0] }, .{ .source, d[1] }, .{ .drain, d[2] } }, &.{.{ width, d[3] }});
    return b.finish();
}

/// Gate 0, source 1, drain 2; then a `second` of gate 2, source 3, drain 4;
/// one bulk on 3; `extra` adds a third, gate 0, source 1, drain 4.
fn chainOfTwo(second: StrId, extra: bool) !Graph {
    var b = common.GraphBuilder.init(5);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    _ = try b.device(.mos, second, &.{ .{ .gate, 2 }, .{ .source, 3 }, .{ .drain, 4 }, .{ .bulk, 3 } });
    if (extra) _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 4 }, .{ .bulk, 3 } });
    return b.finish();
}

fn reversed(comptime n: usize, rows: [n]struct { u32, u32, u32, f64 }) [n]struct { u32, u32, u32, f64 } {
    var out = rows;
    std.mem.reverse(struct { u32, u32, u32, f64 }, &out);
    return out;
}

test "a netlist compared against itself matches" {
    // Oracle: law. A netlist compared against itself matches; every other
    // test here is a perturbation away from it.
    var g = try common.stackedPair();
    defer g.deinit(gpa);
    try expectMatchOf(&g, &g, common.decisive());
}

test "reflexivity holds over generated graphs" {
    // Oracle: law. The same reflexivity over graphs nobody designed:
    // repeated wiring, floating nets, a net of four terminals.
    for (0..16) |seed| {
        const devices: u32 = 3 + @as(u32, @intCast(seed));
        var r1 = Rng.init(seed);
        var r2 = Rng.init(seed);
        var a = try common.randomGraph(&r1, devices, devices + 2);
        defer a.deinit(gpa);
        var b = try common.randomGraph(&r2, devices, devices + 2);
        defer b.deinit(gpa);
        try expectMatchOf(&a, &b, common.decisive());
    }
}

test "relabelling the rows of a netlist does not change the verdict" {
    // Oracle: law. A relabelling is not a difference: an extractor hands
    // over the same circuit with its rows in another order.
    var g = try common.stackedPair();
    defer g.deinit(gpa);
    var p = try common.permute(&g, &.{ 1, 0 }, &.{ 3, 5, 0, 4, 2, 1 });
    defer p.deinit(gpa);
    try expectMatchOf(&p, &g, common.decisive());
}

test "swapping the two sides reverses every side in the report" {
    // Oracle: law. A to B and B to A are each other's image under exchanging
    // the sides.
    var a = try common.mosAndBjt();
    defer a.deinit(gpa);
    var b = try common.mosAndBjtWithoutTheBjt();
    defer b.deinit(gpa);
    var forward = try verdictOf(&a, &b, common.decisive());
    defer forward.deinit(gpa);
    var backward = try verdictOf(&b, &a, common.decisive());
    defer backward.deinit(gpa);
    var flipped: std.ArrayList(Discrepancy) = .empty;
    defer flipped.deinit(gpa);
    for (try common.discrepancies(&forward)) |d| try flipped.append(gpa, common.flip(d));
    try common.assertSame(try common.discrepancies(&backward), flipped.items);
}

test "a deleted device is reported as unpaired on the side that still has it" {
    // Oracle: construct-from-answer. One device deleted from the reference:
    // the layout holds exactly one device the reference does not, the
    // bipolar; side, index and model are named, the transistor is not.
    var a = try common.mosAndBjt();
    defer a.deinit(gpa);
    var b = try common.mosAndBjtWithoutTheBjt();
    defer b.deinit(gpa);
    var r = try verdictOf(&a, &b, common.decisive());
    defer r.deinit(gpa);
    const found = try common.discrepancies(&r);
    try testing.expect(common.contains(found, .{ .unpaired_device = .{ .side = .layout, .device = 1, .model = npn } }));
    for (found) |d| {
        try testing.expect(!common.blamesDevice(d, .layout, 0));
        try testing.expect(!common.blamesDevice(d, .reference, 0));
    }
}

test "the nets orphaned by a deleted device are reported by index" {
    // Oracle: construct-from-answer. The bipolar's nets 4, 5, 6 carry a
    // terminal on the layout and nothing on the reference: exactly those.
    var a = try common.mosAndBjt();
    defer a.deinit(gpa);
    var b = try common.mosAndBjtWithoutTheBjt();
    defer b.deinit(gpa);
    var r = try verdictOf(&a, &b, common.decisive());
    defer r.deinit(gpa);
    const found = try common.discrepancies(&r);
    var unpaired: std.ArrayList(u32) = .empty;
    defer unpaired.deinit(gpa);
    for (0..7) |net| {
        for (found) |d| if (common.blamesNet(d, .layout, @intCast(net))) {
            try unpaired.append(gpa, @intCast(net));
            break;
        };
    }
    try testing.expectEqualSlices(u32, &.{ 4, 5, 6 }, unpaired.items);
}

test "a swapped terminal is blamed on the device whose terminal moved" {
    // Oracle: construct-from-answer. The upper transistor's gate and source
    // exchanged: the gate-net degrees differ ({1, 2} against {1, 1}), so no
    // renaming makes the graphs one; the moved device is named, and no
    // parameter (neither fixture has one) is.
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    _ = try b.device(.mos, nch, &.{ .{ .gate, 4 }, .{ .source, 2 }, .{ .drain, 5 }, .{ .bulk, 3 } });
    var swapped = try b.finish();
    defer swapped.deinit(gpa);
    var g = try common.stackedPair();
    defer g.deinit(gpa);
    var r = try verdictOf(&g, &swapped, common.decisive());
    defer r.deinit(gpa);
    const found = try common.discrepancies(&r);
    try testing.expect(found.len > 0);
    var named = false;
    for (found) |d| {
        named = named or common.blamesDevice(d, .layout, 1) or common.blamesDevice(d, .reference, 1);
        try testing.expect(d != .parameter_mismatch);
    }
    try testing.expect(named);
}

test "a parameter beyond tolerance is reported with both values" {
    // Oracle: construct-from-answer. Widths half apart under a one percent
    // tolerance, outside under either reading of "relative".
    var o = common.decisive();
    o.param_tolerance = 0.01;
    var a = try common.stackedPairWithParams(&.{.{ width, 1.0 }}, &.{});
    defer a.deinit(gpa);
    var b = try common.stackedPairWithParams(&.{.{ width, 1.5 }}, &.{});
    defer b.deinit(gpa);
    try expectSameOf(&a, &b, o, &.{pm(0, 0, width, 1.0, 1.5)});
}

test "a mos written source for drain is the same transistor" {
    // Oracle: physics, finding F4. A MOS channel is symmetric (bias decides
    // the source). Net 2 carries the bipolar's base as well, so the channel
    // nets have different degrees and only a comparison reading the two
    // roles as one can match.
    const anchored = struct {
        fn f(source: u32, drain: u32) !Graph {
            var b = common.GraphBuilder.init(6);
            defer b.deinit();
            _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, source }, .{ .drain, drain }, .{ .bulk, 3 } });
            _ = try b.device(.bjt, npn, &.{ .{ .base, 2 }, .{ .emitter, 4 }, .{ .collector, 5 } });
            return b.finish();
        }
    }.f;
    var a = try anchored(1, 2);
    defer a.deinit(gpa);
    var b = try anchored(2, 1);
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, common.decisive());
}

test "a reference bulk the deck cannot extract is dropped and the swap still pairs" {
    // Oracle: construct-from-answer, F4's second half. A parsed reference
    // always carries a bulk; a three-terminal recogniser never extracts one,
    // and then the reference's goes. Written source-for-drain with the same
    // W/L, anchored by the bipolar's base on net 2. A layout that extracts
    // bulk keeps the reference's, so a bulk on the wrong net still reports.
    const sized_params = [_]common.P{ .{ width, 2e-6 }, .{ length, 5e-7 } };
    const build = struct {
        fn f(terminals: []const common.T) !Graph {
            var b = common.GraphBuilder.init(6);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, terminals, &sized_params);
            _ = try b.device(.bjt, npn, &.{ .{ .base, 2 }, .{ .emitter, 4 }, .{ .collector, 5 } });
            return b.finish();
        }
    }.f;
    var layout = try build(&.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 } });
    defer layout.deinit(gpa);
    var reference = try build(&.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 1 }, .{ .bulk, 3 } });
    defer reference.deinit(gpa);
    try expectMatchOf(&layout, &reference, common.decisive());
    var b3 = try build(&.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    defer b3.deinit(gpa);
    var b4 = try build(&.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 4 } });
    defer b4.deinit(gpa);
    try expectMatchOf(&b3, &b3, common.decisive());
    try expectNotMatchOf(&b3, &b4, common.decisive());
}

test "a bipolar's emitter and collector are not interchangeable" {
    // Oracle: physics. Emitter and collector keep distinct codes; the MOS on
    // net 2 gives that net a degree the emitter's net lacks, so the swap is
    // no relabelling.
    const anchored = struct {
        fn f(emitter: u32, collector: u32) !Graph {
            var b = common.GraphBuilder.init(6);
            defer b.deinit();
            _ = try b.device(.bjt, npn, &.{ .{ .base, 0 }, .{ .emitter, emitter }, .{ .collector, collector } });
            _ = try b.device(.mos, nch, &.{ .{ .gate, 4 }, .{ .source, 2 }, .{ .drain, 5 }, .{ .bulk, 3 } });
            return b.finish();
        }
    }.f;
    var a = try anchored(1, 2);
    defer a.deinit(gpa);
    var b = try anchored(2, 1);
    defer b.deinit(gpa);
    try expectNotMatchOf(&a, &b, common.decisive());
}

test "a parameter only one side declares is not evidence of agreement" {
    // Oracle: the crate's own prohibition of a false match (finding F8's
    // fail-open half). A reference W against a layout stating nothing is a
    // parameter never checked: the report names the side that declared it.
    var a = try common.stackedPairWithParams(&.{}, &.{});
    defer a.deinit(gpa);
    var b = try common.stackedPairWithParams(&.{.{ width, 1.0 }}, &.{});
    defer b.deinit(gpa);
    try expectSameOf(&a, &b, common.decisive(), &.{.{ .undeclared_param = .{ .side = .reference, .layout_device = 0, .ref_device = 0, .param = width } }});
}

test "a measure the paired card omits is not compared" {
    // Oracle: the decision on testing-plan F68. Presence is per device: the
    // lower card states no W, so the lower pair compares none; the upper
    // card's W must still agree; a reference sizing NCH by nothing says
    // nothing against the layout's Ws.
    var layout = try common.stackedPairWithParams(&.{.{ width, 1.0 }}, &.{.{ width, 1.0 }});
    defer layout.deinit(gpa);
    var a = try common.stackedPairWithParams(&.{}, &.{.{ width, 1.0 }});
    defer a.deinit(gpa);
    try expectMatchOf(&layout, &a, common.decisive());
    var b = try common.stackedPairWithParams(&.{}, &.{.{ width, 2.0 }});
    defer b.deinit(gpa);
    try expectSameOf(&layout, &b, common.decisive(), &.{pm(1, 1, width, 1.0, 2.0)});
    var c = try common.stackedPair();
    defer c.deinit(gpa);
    try expectMatchOf(&layout, &c, common.decisive());
}

test "a measure is compared only on the models the reference declares it for" {
    // Oracle: construct-from-answer, testing-plan F22. A reference sizing its
    // capacitor by area says nothing about its transistor's area: compared
    // on the capacitor alone.
    const area = id(93);
    const build = struct {
        fn f(mos: []const common.P, cap: []const common.P) !Graph {
            var b = common.GraphBuilder.init(4);
            defer b.deinit();
            _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, mos);
            _ = try b.deviceWithParams(.capacitor, common.res, &.{ .{ .{ .pin = 0 }, 2 }, .{ .{ .pin = 1 }, 3 } }, cap);
            return b.finish();
        }
    }.f;
    var layout = try build(&.{.{ area, 4.0 }}, &.{.{ area, 2.0 }});
    defer layout.deinit(gpa);
    var a = try build(&.{}, &.{.{ area, 2.0 }});
    defer a.deinit(gpa);
    try expectMatchOf(&layout, &a, common.decisive());
    var b = try build(&.{}, &.{.{ area, 3.0 }});
    defer b.deinit(gpa);
    try expectSameOf(&layout, &b, common.decisive(), &.{pm(1, 1, area, 2.0, 3.0)});
}

test "a parameter inside tolerance is not a difference" {
    // Oracle: construct-from-answer, the other side of the boundary: half a
    // percent apart under one percent matches.
    var o = common.decisive();
    o.param_tolerance = 0.01;
    var a = try common.stackedPairWithParams(&.{.{ width, 1.0 }}, &.{});
    defer a.deinit(gpa);
    var b = try common.stackedPairWithParams(&.{.{ width, 1.005 }}, &.{});
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, o);
}

test "net names do not have to agree" {
    // Oracle: construct-from-answer. Names are never compared: the two
    // graphs differ only in what net 0 is called.
    var a = try common.stackedPair();
    defer a.deinit(gpa);
    a.net_name.items[0] = common.vdd;
    var b = try common.stackedPair();
    defer b.deinit(gpa);
    b.net_name.items[0] = common.vss;
    try expectMatchOf(&a, &b, .{});
}

test "a round limit reached is inconclusive and never a mismatch" {
    // Oracle: construct-from-answer. A chain of twenty-four needs about a
    // dozen rounds and is given one: the round limit, said out loud.
    var o = common.decisive();
    o.max_rounds = 1;
    var c = try common.chain(24);
    defer c.deinit(gpa);
    var r = try verdictOf(&c, &c, o);
    defer r.deinit(gpa);
    try testing.expectEqual(lvs.Verdict{ .inconclusive = .round_limit }, r.verdict);
}

test "the same chain matches once the round limit is generous" {
    // Oracle: construct-from-answer. With room to finish the same graphs
    // match, so the previous verdict came from the budget.
    var c = try common.chain(24);
    defer c.deinit(gpa);
    try expectMatchOf(&c, &c, common.decisive());
}

test "no round budget makes a netlist differ from itself" {
    // Oracle: law. Whatever the budget, a netlist against itself is either
    // unfinished or matched.
    var c = try common.chain(24);
    defer c.deinit(gpa);
    for (1..21) |budget| {
        var o = common.decisive();
        o.max_rounds = @intCast(budget);
        var r = try verdictOf(&c, &c, o);
        defer r.deinit(gpa);
        try testing.expect(r.verdict == .match or std.meta.eql(r.verdict, lvs.Verdict{ .inconclusive = .round_limit }));
    }
}

test "the same symmetric structure matches when the tie break may fire" {
    // Oracle: law. A genuinely symmetric netlist against itself: only the
    // tie-break reaches the match.
    var g = try common.differentialPair();
    defer g.deinit(gpa);
    try expectMatchOf(&g, &g, common.decisive());
}

test "a comparison gives the same verdict on every run" {
    // Oracle: law, the determinism gate: the same comparison twice, with an
    // unrelated one between, gives equal reports.
    var a = try common.mosAndBjt();
    defer a.deinit(gpa);
    var b = try common.mosAndBjtWithoutTheBjt();
    defer b.deinit(gpa);
    var first = try verdictOf(&a, &b, common.decisive());
    defer first.deinit(gpa);
    var c9 = try common.chain(9);
    defer c9.deinit(gpa);
    var dp = try common.differentialPair();
    defer dp.deinit(gpa);
    var between = try verdictOf(&c9, &dp, common.decisive());
    between.deinit(gpa);
    var second = try verdictOf(&a, &b, common.decisive());
    defer second.deinit(gpa);
    try testing.expect(std.meta.eql(first.verdict, second.verdict));
    try testing.expectEqual(first.found.items.len, second.found.items.len);
    for (first.found.items, second.found.items) |x, y| try testing.expect(common.eql(x, y));
}

test "more symmetries than the round budget still match" {
    // Oracle: construct-from-answer. Twelve hundred floating nets beside one
    // device, each its own tie-break, against a thousand rounds: equal
    // graphs, so a match; a budget spent per tie-break says round limit.
    var b = common.GraphBuilder.init(1203);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 } });
    var g = try b.finish();
    defer g.deinit(gpa);
    var o = common.decisive();
    o.max_rounds = 1000;
    try expectMatchOf(&g, &g, o);
}

test "symmetric devices pair by parameters not by row order" {
    // Oracle: Netgen's "resolving symmetries by property value", on the
    // field report's strongarm dummies: two MOS on `tail vss vss vss`, one
    // 0.42/0.15 and one 5.45/0.6, written in opposite orders, pair by size.
    // A wrong size still mismatches.
    const small = [_]common.P{ .{ width, 0.42e-6 }, .{ length, 0.15e-6 } };
    const large = [_]common.P{ .{ width, 5.45e-6 }, .{ length, 0.6e-6 } };
    const dummies = struct {
        fn f(sizes: [2][]const common.P) !Graph {
            var b = common.GraphBuilder.init(2);
            defer b.deinit();
            for (sizes) |s| _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 0 }, .{ .drain, 1 }, .{ .bulk, 0 } }, s);
            return b.finish();
        }
    }.f;
    var a = try dummies(.{ &small, &large });
    defer a.deinit(gpa);
    var b = try dummies(.{ &large, &small });
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, common.decisive());
    var c = try dummies(.{ &large, &large });
    defer c.deinit(gpa);
    try expectNotMatchOf(&a, &c, common.decisive());
}

test "more symmetric devices than tries pair by parameters" {
    // Oracle: the bounded symmetry search: ten interchangeable dummies of ten
    // widths in opposite orders; each twin is the closest, so all pair.
    const dummies = struct {
        fn f(rev: bool) !Graph {
            var b = common.GraphBuilder.init(2);
            defer b.deinit();
            for (0..10) |i| {
                const k: u32 = if (rev) 9 - @as(u32, @intCast(i)) else @intCast(i);
                _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 0 }, .{ .drain, 1 }, .{ .bulk, 0 } }, &.{.{ width, @as(f64, @floatFromInt(k + 1)) * 1e-6 }});
            }
            return b.finish();
        }
    }.f;
    var a = try dummies(false);
    defer a.deinit(gpa);
    var b = try dummies(true);
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, common.decisive());
}

test "a reversed diode or capacitor is a different circuit" {
    // Oracle: the device's definition. A diode conducts one way, and a
    // capacitor's plates are not permuted (Netgen's default): testing-plan
    // F15.
    for ([_]DeviceKind{ .diode, .capacitor }) |kind| {
        var a = try referenceVerdict(kind, false);
        defer a.deinit(gpa);
        try common.expectMatch(&a);
        var b = try referenceVerdict(kind, true);
        defer b.deinit(gpa);
        try common.expectNotMatch(&b);
    }
}

test "a resistor written either way round is the same resistor" {
    // Oracle: the device's definition: a resistor has no direction.
    var r = try referenceVerdict(.resistor, true);
    defer r.deinit(gpa);
    try common.expectMatch(&r);
}

test "a stack matches its schematic whether or not the middle is named" {
    // Oracle: the stack is the same circuit on both sides: the layout's
    // middle node unlabelled, the reference's named; both reduce (F12).
    var layout = try seriesStack(null, false);
    defer layout.deinit(gpa);
    var reference = try seriesStack(id(62), false);
    defer reference.deinit(gpa);
    var r = try verdictOf(&layout, &reference, sized());
    defer r.deinit(gpa);
    try common.expectMatch(&r);
    try testing.expectEqual(@as(u32, 2), r.layout_merges.len() + r.reference_merges.len());
}

test "a labelled middle node is kept on both sides" {
    // Oracle: a label is a port, so the layout keeps a labelled middle node,
    // and the reference net of that name must be kept too. A schematic not
    // naming it so still reduces: the mismatch a misnamed label deserves.
    var layout = try seriesStack(id(62), true);
    defer layout.deinit(gpa);
    var same = try seriesStack(id(62), false);
    defer same.deinit(gpa);
    var r = try verdictOf(&layout, &same, sized());
    defer r.deinit(gpa);
    try common.expectMatch(&r);
    try testing.expectEqual(@as(u32, 0), r.layout_merges.len() + r.reference_merges.len());
    var other = try seriesStack(id(65), false);
    defer other.deinit(gpa);
    try expectNotMatchOf(&layout, &other, sized());
}

test "a netlist matches itself reversed when refinement cannot split its devices" {
    // Oracle: law, testing-plan F58: device 0 has all three terminals on net
    // 0 while devices 1 and 2 swap under exchanging nets 1 and 2; refinement
    // sees one class. Hand-derived from the circuit.
    const devices = [_]struct { u32, u32, u32, f64 }{ .{ 0, 0, 0, 1e-6 }, .{ 1, 1, 2, 1e-6 }, .{ 2, 1, 2, 1e-6 } };
    var a = try mosCircuit(3, &devices);
    defer a.deinit(gpa);
    var b = try mosCircuit(3, &reversed(3, devices));
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, .{});
}

test "a cycle with one device inside tolerance matches" {
    // Oracle: construct-from-answer, testing-plan F58: a three-device cycle
    // whose reference states device 0 1.9 % wide, inside 2 %; closest
    // parameters alone send layout device 0 to reference device 1, which no
    // relabelling allows.
    const layout_rows = [_]struct { u32, u32, u32, f64 }{ .{ 0, 0, 1, 1e-6 }, .{ 1, 0, 2, 1e-6 }, .{ 2, 1, 2, 1e-6 } };
    var reference_rows = layout_rows;
    reference_rows[0][3] = 1.019e-6;
    var a = try mosCircuit(3, &layout_rows);
    defer a.deinit(gpa);
    var b = try mosCircuit(3, &reference_rows);
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, .{});
}

test "two buffers sized apart match themselves reversed" {
    // Oracle: law, testing-plan F58: two two-stage buffers fed by net 0,
    // second stages 1 µm and 2 µm; paired the wrong way round the second
    // stages disagree. Nets: 0 input, 1 ground, 2, 3 inner, 4, 5 outputs.
    const devices = [_]struct { u32, u32, u32, f64 }{ .{ 0, 1, 2, 1e-6 }, .{ 2, 1, 4, 1e-6 }, .{ 0, 1, 3, 1e-6 }, .{ 3, 1, 5, 2e-6 } };
    var a = try mosCircuit(6, &devices);
    defer a.deinit(gpa);
    var b = try mosCircuit(6, &reversed(4, devices));
    defer b.deinit(gpa);
    try expectMatchOf(&a, &b, .{});
}

test "nets nothing else tells apart pair by name" {
    // Oracle: KLayout's `consider_net_names`, by hand. Source net `a` 1 pm²,
    // drain net `b` 2 pm², against a card of 3 pm² at both ends: either
    // pairing is equally far (F98 decides nothing), only names tell a from
    // b. Paired by name, the card's `as` reads against the source, 1 pm².
    const area_s = id(50);
    const area_d = id(51);
    const a = id(60);
    const b = id(61);
    const g = id(62);
    const bulk = id(63);
    var o = common.decisive();
    o.params = .{ .diffusion = .{ area_s, area_d, id(52), id(53) } };
    const mos = struct {
        fn f(names: [4]StrId, d: [2]f64, as: StrId, ad: StrId, ga: StrId, sa: StrId, sb: StrId, bk: StrId) !Graph {
            const at = struct {
                fn of(ns: [4]StrId, name: StrId) u32 {
                    for (ns, 0..) |n, i| if (n == name) return @intCast(i);
                    unreachable;
                }
            }.of;
            var builder = common.GraphBuilder.init(4);
            defer builder.deinit();
            for (names, 0..) |n, net| try builder.nameNet(@intCast(net), n);
            _ = try builder.deviceWithParams(.mos, nch, &.{ .{ .gate, at(names, ga) }, .{ .source, at(names, sa) }, .{ .drain, at(names, sb) }, .{ .bulk, at(names, bk) } }, &.{ .{ as, d[0] }, .{ ad, d[1] } });
            return builder.finish();
        }
    }.f;
    var layout = try mos(.{ a, b, g, bulk }, .{ 1e-12, 2e-12 }, area_s, area_d, g, a, b, bulk);
    defer layout.deinit(gpa);
    var reference = try mos(.{ b, a, g, bulk }, .{ 1e-12, 2e-12 }, area_s, area_d, g, a, b, bulk);
    defer reference.deinit(gpa);
    try expectMatchOf(&layout, &reference, o);
    var exchanged = try mos(.{ b, a, g, bulk }, .{ 2e-12, 1e-12 }, area_s, area_d, g, a, b, bulk);
    defer exchanged.deinit(gpa);
    try expectMatchOf(&layout, &exchanged, o);
    var level = try mos(.{ b, a, g, bulk }, .{ 3e-12, 3e-12 }, area_s, area_d, g, a, b, bulk);
    defer level.deinit(gpa);
    var r = try verdictOf(&layout, &level, o);
    defer r.deinit(gpa);
    const source = for (try common.discrepancies(&r)) |d| switch (d) {
        .parameter_mismatch => |p| if (p.param == area_s) break p.layout_value,
        else => {}, // else: only parameter rows name a diffusion
    } else null;
    try testing.expectEqual(@as(?f64, 1e-12), source);
}

test "a device whose model alone differs is one model mismatch" {
    // Oracle: construct-from-answer, and KLayout's report of "two devices
    // that are identified but have different device classes": the second
    // transistor drawn NCH and written PCH is that one pair, the mirror image
    // backwards; with a device added too, the comparison by model stands.
    var a = try chainOfTwo(nch, false);
    defer a.deinit(gpa);
    var b = try chainOfTwo(common.pch, false);
    defer b.deinit(gpa);
    const expected = [_]Discrepancy{.{ .model_mismatch = .{ .layout_device = 1, .ref_device = 1, .layout_model = nch, .ref_model = common.pch } }};
    try expectSameOf(&a, &b, common.decisive(), &expected);
    try expectSameOf(&b, &a, common.decisive(), &.{common.flip(expected[0])});
    var c = try chainOfTwo(common.pch, true);
    defer c.deinit(gpa);
    var r = try verdictOf(&a, &c, common.decisive());
    defer r.deinit(gpa);
    const found = try common.discrepancies(&r);
    var unpaired = false;
    for (found) |d| {
        try testing.expect(d != .model_mismatch);
        unpaired = unpaired or d == .unpaired_device;
    }
    try testing.expect(unpaired);
}

test "a measure sorting before the card's parameter is passed over" {
    // Oracle: construct-from-answer, the parameter contract. The layout
    // measures W and L, the reference states L: W is passed over on the way
    // to L, and L is compared.
    const measured = [_]common.P{ .{ width, 1.0 }, .{ length, 0.5 } };
    var layout = try common.stackedPairWithParams(&measured, &measured);
    defer layout.deinit(gpa);
    const card = [_]common.P{.{ length, 0.5 }};
    var a = try common.stackedPairWithParams(&card, &card);
    defer a.deinit(gpa);
    try expectMatchOf(&layout, &a, common.decisive());
    var b = try common.stackedPairWithParams(&card, &.{.{ length, 1.0 }});
    defer b.deinit(gpa);
    try expectSameOf(&layout, &b, common.decisive(), &.{pm(1, 1, length, 0.5, 1.0)});
}
