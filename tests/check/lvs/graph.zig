//! The shared graph shape: its CSR accessors, the projection of a reference
//! netlist into it, and the two documented terminal orders meeting in a
//! comparison. Ported from crates/check/tests/lvs/graph.rs and
//! terminal_order.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const ingest = @import("ingest");
const Netlist = ingest.netlist.Netlist;
const RefNetId = ingest.netlist.RefNetId;
const SubcktId = ingest.netlist.SubcktId;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const TerminalRole = check.topology.TerminalRole;
const Rng = @import("testgen").Rng;
const common = @import("common.zig");
const id = common.id;
const gpa = testing.allocator;

// ---- private ----

fn expectRoles(want: []const TerminalRole, got: []const TerminalRole) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expect(lvs.graph.roleEql(w, g));
}

/// A resistor and a transistor in one subcircuit over five nets, written as
/// columns rather than parsed.
fn oneSubcircuit() !Netlist {
    var n: Netlist = .{};
    errdefer n.deinit(gpa);
    try n.subckt_name.append(gpa, id(30));
    try n.subckt_port_start.appendSlice(gpa, &.{ 0, 2 });
    try n.port_net.appendSlice(gpa, &.{ @fromBackingInt(@intCast(0)), @fromBackingInt(@intCast(1)) });
    try n.subckt_device_start.appendSlice(gpa, &.{ 0, 2 });
    try n.device_model.appendSlice(gpa, &.{ common.res, common.nch });
    try n.device_kind.appendSlice(gpa, &.{ .resistor, .mos });
    try n.device_terminal_start.appendSlice(gpa, &.{ 0, 2, 6 });
    for ([_]u32{ 0, 1, 1, 2, 3, 4 }) |t| try n.terminal_net.append(gpa, @fromBackingInt(@intCast(t)));
    try n.device_param_start.appendSlice(gpa, &.{ 0, 1, 1 });
    try n.param.append(gpa, .{ .name = common.width, .value = 2.5 });
    try n.net_name.appendSlice(gpa, &.{ common.vdd, common.vss, id(32), id(33), id(34) });
    try n.net_subckt.appendNTimes(gpa, @fromBackingInt(@intCast(0)), 5);
    return n;
}

fn oneDeviceVerdict(kind: ingest.deck.DeviceKind, nets: u32, layout: []const common.T, reference: []const common.T) !common.Result {
    var a = common.GraphBuilder.init(nets);
    defer a.deinit();
    _ = try a.device(kind, common.nch, layout);
    var ga = try a.finish();
    defer ga.deinit(gpa);
    var b = common.GraphBuilder.init(nets);
    defer b.deinit();
    _ = try b.device(kind, common.nch, reference);
    var gb = try b.finish();
    defer gb.deinit(gpa);
    return common.compare(&ga, &gb, .{});
}

test "each device gets back the terminals it was built with" {
    // Oracle: construct-from-answer. The fixture states each device's
    // terminals before the graph exists; devices of differing terminal counts
    // sit side by side, so an off-by-one in the CSR offsets shows.
    var g = try common.mosAndBjt();
    defer g.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), g.deviceCount());
    try testing.expectEqual(@as(u32, 7), g.netCount());
    const a = g.terminalsOf(0);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, a.nets);
    try expectRoles(&.{ .gate, .source, .drain, .bulk }, a.roles);
    const b = g.terminalsOf(1);
    try testing.expectEqualSlices(u32, &.{ 4, 5, 6 }, b.nets);
    try expectRoles(&.{ .base, .emitter, .collector }, b.roles);
}

test "net incidence is the transpose of device incidence" {
    // Oracle: law. Every (device, role) on a net is a terminal of that device
    // landing there, and every terminal appears on exactly one net, for any
    // graph; asserted over generated graphs.
    var rng = Rng.init(19);
    for (0..12) |round| {
        var g = try common.randomGraph(&rng, 6 + @as(u32, @intCast(round)), 9);
        defer g.deinit(gpa);
        var from_devices: std.ArrayList([3]u32) = .empty;
        defer from_devices.deinit(gpa);
        var from_nets: std.ArrayList([3]u32) = .empty;
        defer from_nets.deinit(gpa);
        for (0..g.deviceCount()) |d| {
            const t = g.terminalsOf(@intCast(d));
            try testing.expectEqual(t.nets.len, t.roles.len);
            for (t.nets, t.roles) |n, r| try from_devices.append(gpa, .{ @intCast(d), n, @intCast(lvs.graph.roleCode(r)) });
        }
        for (0..g.netCount()) |n| {
            const t = g.terminalsOn(@intCast(n));
            for (t.devices, t.roles) |d, r| try from_nets.append(gpa, .{ d, @intCast(n), @intCast(lvs.graph.roleCode(r)) });
        }
        try testing.expectEqual(from_devices.items.len, from_nets.items.len);
        for (from_devices.items) |want| {
            const at = for (from_nets.items, 0..) |have, i| (if (std.mem.eql(u32, &have, &want)) break i) else return error.TestTerminalOnNoNet;
            _ = from_nets.swapRemove(at);
        }
        try testing.expectEqual(@as(usize, 0), from_nets.items.len);
    }
}

test "parameters are partitioned across the devices that declared them" {
    // Oracle: construct-from-answer. The lower transistor states two
    // parameters and the upper none, so the empty run sits after a
    // non-empty one; values are stored, never computed, so exact.
    var g = try common.stackedPairWithParams(&.{ .{ common.width, 0.5 }, .{ common.length, 0.03 } }, &.{});
    defer g.deinit(gpa);
    const p = g.paramsOf(0);
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expect(p[0].name == common.width and p[0].value == 0.5);
    try testing.expect(p[1].name == common.length and p[1].value == 0.03);
    try testing.expectEqual(@as(usize, 0), g.paramsOf(1).len);
    try testing.expectEqual(g.param.items.len, g.paramsOf(0).len + g.paramsOf(1).len);
}

test "terminal ranges tile the terminal columns without gap or overlap" {
    // Oracle: law, what CSR means: contiguous ranges from zero to the
    // column length, no terminal in two devices.
    var rng = Rng.init(101);
    var g = try common.randomGraph(&rng, 11, 7);
    defer g.deinit(gpa);
    var covered: usize = 0;
    for (0..g.deviceCount()) |d| covered += g.terminalsOf(@intCast(d)).nets.len;
    try testing.expectEqual(g.terminal_net.items.len, covered);
    try testing.expectEqual(g.terminal_net.items.len, g.terminal_role.items.len);
}

test "a reference subcircuit projects to the graph it describes" {
    // Oracle: construct-from-answer. One subcircuit holds every net, so the
    // reference numbering and the graph's are one space. The MOS roles are
    // asserted as a set and the resistor's as pins: what the projection may
    // not do is invent a role the family lacks, or use one twice.
    var netlist = try oneSubcircuit();
    defer netlist.deinit(gpa);
    var g: Graph = .{};
    defer g.deinit(gpa);
    try lvs.fromReferenceInto(gpa, &netlist, @fromBackingInt(@intCast(0)), &g);
    try testing.expectEqual(@as(u32, 2), g.deviceCount());
    try testing.expectEqual(@as(u32, 5), g.netCount());
    try testing.expectEqualSlices(ingest.deck.DeviceKind, &.{ .resistor, .mos }, g.device_kind.items);
    try testing.expectEqualSlices(StrId, &.{ common.res, common.nch }, g.device_model.items);
    const r = g.terminalsOf(0);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, r.nets);
    for (r.roles) |role| try testing.expect(role == .pin);
    const m = g.terminalsOf(1);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, m.nets);
    var expected = [_]?TerminalRole{ .gate, .source, .drain, .bulk };
    for (m.roles) |role| {
        const at = for (expected, 0..) |e, i| (if (e != null and lvs.graph.roleEql(e.?, role)) break i) else return error.TestRoleNotOfTheFamily;
        expected[at] = null;
    }
    const p = g.paramsOf(0);
    try testing.expect(p.len == 1 and p[0].name == common.width and p[0].value == 2.5);
    try testing.expectEqual(@as(usize, 0), g.paramsOf(1).len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, g.port_net.items);
    try testing.expectEqualSlices(?StrId, &.{ common.vdd, common.vss, id(32), id(33), id(34) }, g.net_name.items);
}

test "a net with no terminals is still a net with an empty terminal list" {
    // Oracle: construct-from-answer. Dropping a floating net is the bug that
    // makes it invisible to LVS, and an empty range at the end of the column
    // is where an off-by-one hides.
    var b = common.GraphBuilder.init(3);
    defer b.deinit();
    _ = try b.device(.mos, common.nch, &.{ .{ .source, 0 }, .{ .drain, 1 } });
    var g = try b.finish();
    defer g.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), g.netCount());
    try testing.expectEqual(@as(usize, 0), g.terminalsOn(2).devices.len);
    try testing.expectEqual(@as(usize, 1), g.terminalsOn(0).devices.len);
}

test "a shared net lists every terminal that lands on it" {
    // Oracle: construct-from-answer. Net 2 carries the lower drain and the
    // upper gate, net 3 both bulks; a transpose keeping only the last writer
    // passes a total count and fails this.
    var g = try common.stackedPair();
    defer g.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, g.terminalsOn(2).devices);
    try expectRoles(&.{ .drain, .gate }, g.terminalsOn(2).roles);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, g.terminalsOn(3).devices);
    try expectRoles(&.{ .bulk, .bulk }, g.terminalsOn(3).roles);
    try expectRoles(&.{.gate}, g.terminalsOn(0).roles);
    try testing.expectEqualSlices(u32, &.{1}, g.terminalsOn(4).devices);
    try expectRoles(&.{.source}, g.terminalsOn(4).roles);
}

test "a mos in the two documented terminal orders is one device" {
    // Oracle: construct-from-answer. Both orders put every role on the same
    // net (the recogniser's gate, source, drain, bulk; the SPICE M card's
    // drain, gate, source, bulk), so it is one device.
    var r = try oneDeviceVerdict(.mos, 4, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, &.{ .{ .drain, 2 }, .{ .gate, 0 }, .{ .source, 1 }, .{ .bulk, 3 } });
    defer r.deinit(gpa);
    try common.expectMatch(&r);
}

test "a bjt in the two documented terminal orders is one device" {
    // Oracle: construct-from-answer. Both orders put every role on the same
    // net (the recogniser's base, emitter, collector; the SPICE Q card's
    // collector, base, emitter), so it is one device.
    var r = try oneDeviceVerdict(.bjt, 3, &.{ .{ .base, 0 }, .{ .emitter, 1 }, .{ .collector, 2 } }, &.{ .{ .collector, 2 }, .{ .base, 0 }, .{ .emitter, 1 } });
    defer r.deinit(gpa);
    try common.expectMatch(&r);
}

test "reordering the slots does not excuse a terminal on the wrong net" {
    // Oracle: construct-from-answer. The reference's lower gate sits on the
    // shared net 2, which in the layout holds no gate, so no relabelling
    // makes the two equal: anything but a match.
    var a = common.GraphBuilder.init(6);
    defer a.deinit();
    _ = try a.device(.mos, common.nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } });
    _ = try a.device(.mos, common.nch, &.{ .{ .gate, 4 }, .{ .source, 2 }, .{ .drain, 5 }, .{ .bulk, 3 } });
    var ga = try a.finish();
    defer ga.deinit(gpa);
    var b = common.GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.device(.mos, common.nch, &.{ .{ .drain, 0 }, .{ .gate, 2 }, .{ .source, 1 }, .{ .bulk, 3 } });
    _ = try b.device(.mos, common.nch, &.{ .{ .drain, 5 }, .{ .gate, 4 }, .{ .source, 2 }, .{ .bulk, 3 } });
    var gb = try b.finish();
    defer gb.deinit(gpa);
    var r = try common.compare(&ga, &gb, .{});
    defer r.deinit(gpa);
    try common.expectNotMatch(&r);
}
