//! Role masks, and the one pass that builds them: `NetFacts` is read by six
//! rules and built once, so an error here is six wrong verdicts with one
//! cause. Checked construct-from-answer: a layout emitted from a netlist
//! must classify back to that netlist's terminals. Ported from
//! crates/check/tests/erc/net_facts.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const topology = check.topology;
const NetId = topology.NetId;
const TerminalRole = topology.TerminalRole;
const facts = check.erc.facts;
const RoleMask = facts.RoleMask;
const nl = testgen.netlist;
const gpa = testing.allocator;

/// A layout emitted from a spec, extracted and classified.
const Classified = struct {
    strings: geom.StrTable = .empty,
    case: nl.NetlistCase,
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},
    facts: facts.NetFacts = .{},

    fn deinit(c: *Classified) void {
        c.facts.deinit(gpa);
        c.devices.deinit(gpa);
        c.nets.deinit(gpa);
        c.case.deinit(gpa);
        c.strings.deinit(gpa);
    }

    fn net(c: *const Classified, n: usize) NetId {
        return c.nets.netOf(c.case.expected_net_polys[n][0]);
    }
};

/// A MOS and a resistor sharing two nets, plus a net nothing attaches to.
const mixed: nl.NetlistSpec = .{ .nets = 5, .devices = &.{
    .{ .kind = .mos, .model = "nch", .terminals = &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 }, .{ .role = .drain, .net = 2 }, .{ .role = .bulk, .net = 3 } } },
    .{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 2 }, .{ .role = .{ .pin = 1 }, .net = 3 } } },
} };

// ---- private ----

fn classify(spec: nl.NetlistSpec) !Classified {
    var c: Classified = .{ .case = undefined };
    c.case = try nl.layoutFromNetlist(gpa, spec, .{}, &c.strings);
    try topology.extractNetsInto(gpa, &c.case.store, &c.case.connectivity, &c.nets);
    try topology.recogniseInto(gpa, &c.case.store, &c.nets, &c.case.recognition, &c.devices);
    try facts.classifyNetsInto(gpa, &c.nets, &c.devices, &c.facts);
    return c;
}

fn bits(m: RoleMask) u8 {
    return @bitCast(m);
}

test "each named terminal role maps to its own single bit" {
    // Oracle: construct-from-answer. `RoleMask.of` is the single place the
    // role-to-bit mapping is written down: the seven named roles land on
    // seven distinct single bits, and with `pin` the eight cover all eight.
    const named = [_]struct { TerminalRole, RoleMask }{
        .{ .gate, .{ .gate = true } },           .{ .source, .{ .source = true } },
        .{ .drain, .{ .drain = true } },         .{ .bulk, .{ .bulk = true } },
        .{ .base, .{ .base = true } },           .{ .emitter, .{ .emitter = true } },
        .{ .collector, .{ .collector = true } },
    };
    var all: u8 = 0;
    for (named) |pair| {
        const got = RoleMask.of(pair[0]);
        try testing.expectEqual(bits(pair[1]), bits(got));
        try testing.expectEqual(@as(u4, 1), @popCount(bits(got)));
        try testing.expect(all & bits(got) == 0);
        all |= bits(got);
    }
    const pin = bits(RoleMask.of(.{ .pin = 0 }));
    try testing.expect(all & pin == 0);
    try testing.expectEqual(@as(u8, 0xFF), all | pin);
}

test "every pin index collapses to the one pin bit" {
    // Oracle: construct-from-answer. A symmetric device's pin index carries
    // no meaning, so every index is the one pin bit; shifting by the index
    // would put pin 3 on the drain bit.
    for ([_]u8{ 0, 1, 2, 7, 255 }) |index| try testing.expectEqual(bits(.{ .pin = true }), bits(RoleMask.of(.{ .pin = index })));
}

test "role masks reproduce the netlist the layout was built from" {
    // Oracle: construct-from-answer. The netlist decided which role sits on
    // which net before a polygon was drawn: the resistor's two pins land on
    // one bit and the fifth net, which nothing touches, comes back empty.
    var c = try classify(mixed);
    defer c.deinit();
    const want = [_]RoleMask{ .{ .gate = true }, .{ .source = true }, .{ .drain = true, .pin = true }, .{ .bulk = true, .pin = true }, .{} };
    for (want, 0..) |w, n| try testing.expectEqual(bits(w), bits(c.facts.role.items[@backingInt(c.net(n))]));
}

test "there is one row of facts per extracted net" {
    // Oracle: construct-from-answer. One row of facts per extracted net.
    var c = try classify(mixed);
    defer c.deinit();
    try testing.expectEqual(c.nets.netCount(), @as(u32, @intCast(c.facts.role.items.len)));
    try testing.expect(c.facts.role.items.len > 0);
}

test "a net reached only by a passive device is still device connected" {
    // Oracle: construct-from-answer, on the regression the mask names: a
    // block of passives only has no MOS, and scanning the MOS list reported
    // every net unconnected. Both of the resistor's nets are connected.
    var c = try classify(.{ .nets = 3, .devices = &.{
        .{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 0 }, .{ .role = .{ .pin = 1 }, .net = 1 } } },
    } });
    defer c.deinit();
    try testing.expect(c.facts.isDeviceConnected(c.net(0)));
    try testing.expect(c.facts.isDeviceConnected(c.net(1)));
    try testing.expect(!c.facts.isDeviceConnected(c.net(2)));
}

test "a terminal on no net or past the extraction is dropped" {
    // Oracle: the documented contract of `classifyNetsInto`: over the mixed
    // netlist's nets, a table whose only terminals are a gate on net 0, a
    // drain on no net and a source past the extraction gives net 0 the gate
    // bit alone and every other net none.
    var c = try classify(mixed);
    defer c.deinit();
    var devices: topology.DeviceTable = .{};
    defer devices.deinit(gpa);
    try devices.terminal_net.appendSlice(gpa, &.{ @fromBackingInt(0), .none, @fromBackingInt(1_000) });
    try devices.terminal_role.appendSlice(gpa, &.{ .gate, .drain, .source });
    var f: facts.NetFacts = .{};
    defer f.deinit(gpa);
    try facts.classifyNetsInto(gpa, &c.nets, &devices, &f);
    try testing.expectEqual(c.nets.netCount(), @as(u32, @intCast(f.role.items.len)));
    try testing.expectEqual(bits(.{ .gate = true }), bits(f.role.items[0]));
    for (f.role.items[1..]) |m| try testing.expect(m.isEmpty());
}
