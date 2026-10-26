//! Logic-gate reduction (`lvs recognize_gates`, catalog LVS-047): plain
//! transistors in series or in parallel on different gates become one
//! device with interchangeable gates, Silvaco Guardian's "series reduction
//! ... with different gate terminals" and its parallel twin. Each expected
//! graph is written out by hand and compared whole. Ported from
//! crates/check/tests/lvs/gates.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const common = @import("common.zig");
const id = common.id;
const nch = common.nch;
const pch = common.pch;
const width = common.width;
const P = common.P;
const T = common.T;
const gpa = testing.allocator;

/// `as`, `sa`: a diffusion and a stress name, either making a transistor
/// not plain.
const as_name = id(40);
const sa_name = id(41);
const gates_on: lvs.ParamNames = .{ .diffusion = .{ as_name, null, null, null }, .stress = .{ sa_name, null }, .gates = true };
const size = [_]P{.{ width, 1e-6 }};

/// One MOS: model, gate, source, drain, bulk, parameters.
const Mos = struct { StrId, u32, u32, u32, u32, []const P };

// ---- private ----

fn mosTerminals(m: Mos) [4]T {
    return .{ .{ .gate, m[1] }, .{ .source, m[2] }, .{ .drain, m[3] }, .{ .bulk, m[4] } };
}

fn graphOf(nets: u32, devices: []const Mos, ports: []const u32) !Graph {
    var b = common.GraphBuilder.init(nets);
    defer b.deinit();
    for (devices) |m| _ = try b.deviceWithParams(.mos, m[0], &mosTerminals(m), m[5]);
    for (ports) |p| try b.port(p);
    return b.finish();
}

fn gated(src: *const Graph) !common.Reduced {
    return common.reduce(src, gates_on);
}

/// One merge as Rust's `Merge`: kind, model, rows.
fn expectMerge(merges: *const lvs.Merges, at: u32, kind: lvs.MergeKind, model: StrId, rows: []const u32) !void {
    try testing.expectEqual(kind, merges.kind.items[at]);
    try testing.expectEqual(model, merges.model.items[at]);
    try testing.expectEqualSlices(u32, rows, merges.devicesOf(at));
}

/// `src` reduces to itself with no merge.
fn expectUntouched(src: *const Graph) !void {
    var r = try gated(src);
    defer r.deinit();
    try common.expectGraphEql(src, &r.g);
    try testing.expectEqual(@as(u32, 0), r.merges.len());
}

fn wantGraph(nets: u32, devices: []const struct { StrId, []const T }, ports: []const u32) !Graph {
    var b = common.GraphBuilder.init(nets);
    defer b.deinit();
    for (devices) |d| _ = try b.deviceWithParams(.mos, d[0], d[1], &size);
    for (ports) |p| try b.port(p);
    return b.finish();
}

test "a series stack on two gates is one device with both gates" {
    // Oracle: the definition, NAND2's pull-down. nmos A (gate 0) from 2 to
    // the internal node 3, nmos B (gate 1) from 3 to 4, bulk 5: one device,
    // gates 0 and 1, ends 2 and 4, bulk 5; net 3 consumed and the nets
    // above shift down one. Without the control nothing merges.
    var src = try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 1, 3, 4, 5, &size } }, &.{2});
    defer src.deinit(gpa);
    var r = try gated(&src);
    defer r.deinit();
    var want = try wantGraph(5, &.{.{ nch, &.{ .{ .gate, 0 }, .{ .gate, 1 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } } }}, &.{2});
    defer want.deinit(gpa);
    try common.expectGraphEql(&want, &r.g);
    try testing.expectEqual(@as(u32, 1), r.merges.len());
    try expectMerge(&r.merges, 0, .series, nch, &.{ 0, 1 });
    var off = gates_on;
    off.gates = false;
    var plain = try common.reduce(&src, off);
    defer plain.deinit();
    try common.expectGraphEql(&src, &plain.g);
    try testing.expectEqual(@as(u32, 0), plain.merges.len());
}

test "a three stack drawn out of order is one device" {
    // Oracle: the definition, NAND3's pull-down out of order: rows 0, 1, 2
    // are top, bottom, middle, gates 2, 0, 1, from 7 through 3 and 4 to 5,
    // bulk 6. One device: gates 0, 1, 2, the unconsumed ends in member
    // order (row 0's 5, row 1's 7); nets 5, 6, 7 become 3, 4, 5.
    var src = try graphOf(8, &.{ .{ nch, 2, 4, 5, 6, &.{} }, .{ nch, 0, 7, 3, 6, &.{} }, .{ nch, 1, 3, 4, 6, &.{} } }, &.{});
    defer src.deinit(gpa);
    var r = try gated(&src);
    defer r.deinit();
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 0 }, .{ .gate, 1 }, .{ .gate, 2 }, .{ .source, 3 }, .{ .drain, 5 }, .{ .bulk, 4 } });
    var want = try b.finish();
    defer want.deinit(gpa);
    try common.expectGraphEql(&want, &r.g);
    try testing.expectEqual(@as(u32, 1), r.merges.len());
    try expectMerge(&r.merges, 0, .series, nch, &.{ 0, 1, 2 });
}

test "a parallel pair on two gates is one device and a shared gate is not" {
    // Oracle: the definition, NAND2's pull-up: pmos A (gate 0) and B (gate
    // 1) both from 2 to 3, B the other way round: one parallel device, the
    // head's ends. The same gate twice is a same-gate parallel pair this law
    // leaves apart.
    var src = try graphOf(5, &.{ .{ pch, 0, 2, 3, 4, &size }, .{ pch, 1, 3, 2, 4, &size } }, &.{});
    defer src.deinit(gpa);
    var r = try gated(&src);
    defer r.deinit();
    var want = try wantGraph(5, &.{.{ pch, &.{ .{ .gate, 0 }, .{ .gate, 1 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 4 } } }}, &.{});
    defer want.deinit(gpa);
    try common.expectGraphEql(&want, &r.g);
    try testing.expectEqual(@as(u32, 1), r.merges.len());
    try expectMerge(&r.merges, 0, .parallel, pch, &.{ 0, 1 });
    var shared = try graphOf(5, &.{ .{ pch, 0, 2, 3, 4, &size }, .{ pch, 0, 3, 2, 4, &size } }, &.{});
    defer shared.deinit(gpa);
    try expectUntouched(&shared);
}

test "a stack breaking any precondition stays as drawn" {
    // Oracle: the module's refusals, each a NAND2 pull-down but for one
    // thing: another model; another size; a diffusion or stress stated;
    // bulks apart; the internal node a port; the same gate; a third terminal
    // on the internal node; a fifth role; two gates on one; a resistor; a
    // gate on no net.
    const other = [_]P{.{ width, 2e-6 }};
    const stated = [_]P{ .{ width, 1e-6 }, .{ as_name, 1e-12 } };
    const stress = [_]P{ .{ width, 1e-6 }, .{ sa_name, 1e-7 } };
    var cases: std.ArrayList(Graph) = .empty;
    defer {
        for (cases.items) |*g| g.deinit(gpa);
        cases.deinit(gpa);
    }
    try cases.append(gpa, try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ pch, 1, 3, 4, 5, &size } }, &.{}));
    try cases.append(gpa, try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 1, 3, 4, 5, &other } }, &.{}));
    try cases.append(gpa, try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &stated }, .{ nch, 1, 3, 4, 5, &stated } }, &.{}));
    try cases.append(gpa, try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &stress }, .{ nch, 1, 3, 4, 5, &stress } }, &.{}));
    try cases.append(gpa, try graphOf(7, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 1, 3, 4, 6, &size } }, &.{}));
    try cases.append(gpa, try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 1, 3, 4, 5, &size } }, &.{3}));
    try cases.append(gpa, try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 0, 3, 4, 5, &size } }, &.{}));
    {
        var b = common.GraphBuilder.init(6);
        defer b.deinit();
        for ([_]Mos{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 1, 3, 4, 5, &size } }) |m| _ = try b.deviceWithParams(.mos, m[0], &mosTerminals(m), m[5]);
        _ = try b.device(.resistor, common.res, &.{ .{ .{ .pin = 0 }, 3 }, .{ .{ .pin = 1 }, 5 } });
        try cases.append(gpa, try b.finish());
    }
    {
        var b = common.GraphBuilder.init(7);
        defer b.deinit();
        _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 5 }, .{ .{ .pin = 0 }, 6 } }, &size);
        _ = try b.deviceWithParams(.mos, nch, &mosTerminals(.{ nch, 1, 3, 4, 5, &size }), &size);
        try cases.append(gpa, try b.finish());
    }
    {
        var b = common.GraphBuilder.init(7);
        defer b.deinit();
        _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .gate, 6 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 5 } }, &size);
        _ = try b.deviceWithParams(.mos, nch, &mosTerminals(.{ nch, 1, 3, 4, 5, &size }), &size);
        try cases.append(gpa, try b.finish());
    }
    {
        var b = common.GraphBuilder.init(6);
        defer b.deinit();
        _ = try b.device(.resistor, nch, &.{ .{ .gate, 0 }, .{ .source, 2 }, .{ .drain, 3 }, .{ .bulk, 5 } });
        _ = try b.device(.resistor, nch, &.{ .{ .gate, 1 }, .{ .source, 3 }, .{ .drain, 4 }, .{ .bulk, 5 } });
        try cases.append(gpa, try b.finish());
    }
    for (cases.items) |*src| {
        var r = try gated(src);
        defer r.deinit();
        try testing.expectEqual(@as(u32, 0), r.merges.len());
        try testing.expectEqual(src.deviceCount(), r.g.deviceCount());
    }
    // A gate on no net: detached by hand, net 0 losing its only terminal,
    // the first of the transpose.
    var floating = try graphOf(6, &.{ .{ nch, 0, 2, 3, 5, &size }, .{ nch, 1, 3, 4, 5, &size } }, &.{});
    defer floating.deinit(gpa);
    floating.terminal_net.items[0] = lvs.graph.no_net;
    _ = floating.net_terminal_device.orderedRemove(0);
    _ = floating.net_terminal_role.orderedRemove(0);
    for (floating.net_terminal_start.items[1..]) |*s| s.* -= 1;
    var r = try gated(&floating);
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.merges.len());
}

test "a ring of transistors stays as drawn" {
    // Oracle: the soundness rule. Three transistors chained in a ring through
    // nets 3, 4, 5: every net joins, nothing is left as an end, so the group
    // is no single transistor and stays, its nets kept.
    var src = try graphOf(7, &.{ .{ nch, 0, 3, 4, 6, &size }, .{ nch, 1, 4, 5, 6, &size }, .{ nch, 2, 5, 3, 6, &size } }, &.{});
    defer src.deinit(gpa);
    try expectUntouched(&src);
}

test "a three way parallel group is one device" {
    // Oracle: the definition, NAND3's pull-up: three pmos on gates 0, 1, 2,
    // all from 3 to 4, bulk 5: one device, the gates ascending, the head's
    // ends.
    var src = try graphOf(6, &.{ .{ pch, 0, 3, 4, 5, &size }, .{ pch, 1, 4, 3, 5, &size }, .{ pch, 2, 3, 4, 5, &size } }, &.{});
    defer src.deinit(gpa);
    var r = try gated(&src);
    defer r.deinit();
    var want = try wantGraph(6, &.{.{ pch, &.{ .{ .gate, 0 }, .{ .gate, 1 }, .{ .gate, 2 }, .{ .source, 3 }, .{ .drain, 4 }, .{ .bulk, 5 } } }}, &.{});
    defer want.deinit(gpa);
    try common.expectGraphEql(&want, &r.g);
    try testing.expectEqual(@as(u32, 1), r.merges.len());
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, r.merges.devicesOf(0));
}

test "a group with a repeated gate or one end stays as drawn" {
    // Oracle: the soundness rule ("every gate its own net", "two distinct
    // nets"): a stack of three whose top and bottom share gate 0, and two
    // transistors with source and drain both on net 2, stay as drawn.
    var repeated = try graphOf(7, &.{ .{ nch, 0, 2, 3, 6, &size }, .{ nch, 1, 3, 4, 6, &size }, .{ nch, 0, 4, 5, 6, &size } }, &.{});
    defer repeated.deinit(gpa);
    try expectUntouched(&repeated);
    var shorted = try graphOf(4, &.{ .{ pch, 0, 2, 2, 3, &size }, .{ pch, 1, 2, 2, 3, &size } }, &.{});
    defer shorted.deinit(gpa);
    try expectUntouched(&shorted);
}

test "the deck's recognize gates lets a stack's inputs swap" {
    // Oracle: the definition, through the comparison. A two-high stack whose
    // lower gate also drives a resistor, against the same stack with its two
    // inputs the other way up: no renaming maps one onto the other, until
    // `lvs recognize_gates` makes each stack one device whose gates swap.
    const stack = struct {
        fn f(lower: u32, upper: u32) !Graph {
            var b = common.GraphBuilder.init(6);
            defer b.deinit();
            _ = try b.device(.mos, nch, &mosTerminals(.{ nch, lower, 4, 3, 4, &.{} }));
            _ = try b.device(.mos, nch, &mosTerminals(.{ nch, upper, 3, 2, 4, &.{} }));
            _ = try b.device(.resistor, common.res, &.{ .{ .{ .pin = 0 }, 0 }, .{ .{ .pin = 0 }, 5 } });
            return b.finish();
        }
    }.f;
    var layout = try stack(0, 1);
    defer layout.deinit(gpa);
    var reference = try stack(1, 0);
    defer reference.deinit(gpa);
    var plain = try common.compare(&layout, &reference, .{});
    defer plain.deinit(gpa);
    try common.expectNotMatch(&plain);
    var r = try common.compareWith(&layout, &reference, .{}, &.{ .recognize_gates = true });
    defer r.deinit(gpa);
    try common.expectMatch(&r);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, r.reference_row_start.items);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, r.reference_row.items);
}

test "a nand2 reduces to one stack and one parallel pair" {
    // Oracle: the definition, a NAND2 whole: parallel first, the pull-up
    // (rows 2, 3), then the pull-down (rows 0, 1); output devices ascending
    // by lowest row, the stack first.
    var src = try graphOf(6, &.{ .{ nch, 0, 4, 3, 4, &size }, .{ nch, 1, 3, 2, 4, &size }, .{ pch, 0, 5, 2, 5, &size }, .{ pch, 1, 2, 5, 5, &size } }, &.{ 0, 1, 2, 4, 5 });
    defer src.deinit(gpa);
    var r = try gated(&src);
    defer r.deinit();
    try testing.expectEqual(@as(u32, 2), r.merges.len());
    try expectMerge(&r.merges, 0, .parallel, pch, &.{ 2, 3 });
    try expectMerge(&r.merges, 1, .series, nch, &.{ 0, 1 });
    var want = try wantGraph(5, &.{
        .{ nch, &.{ .{ .gate, 0 }, .{ .gate, 1 }, .{ .source, 3 }, .{ .drain, 2 }, .{ .bulk, 3 } } },
        .{ pch, &.{ .{ .gate, 0 }, .{ .gate, 1 }, .{ .source, 4 }, .{ .drain, 2 }, .{ .bulk, 4 } } },
    }, &.{ 0, 1, 2, 3, 4 });
    defer want.deinit(gpa);
    try common.expectGraphEql(&want, &r.g);
}
