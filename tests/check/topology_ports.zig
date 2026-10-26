//! Port binding: the names a layout declares, and the contradictions it
//! can. Ported from crates/check/tests/topology/ports.rs.
//!
//! Oracle throughout: construct-from-answer. The layout comes from
//! `layoutFromNetlist`, so which polygons share a net is known before a
//! label is placed.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const ingest = @import("ingest");
const topology = check.topology;
const NetId = topology.NetId;
const NetTable = topology.NetTable;
const PortTable = topology.PortTable;
const Provenance = ingest.Provenance;
const nl = testgen.netlist;

const gpa = testing.allocator;

/// Three nets; net 0 carries a rail and a stub joined through a via, which
/// is what makes a conflict constructible.
const two_pin_resistor: nl.NetlistSpec = .{ .nets = 3, .devices = &.{.{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 0 }, .{ .role = .{ .pin = 1 }, .net = 1 } } }} };

/// A case, its nets, names, labels and ports, freed together.
const Fixture = struct {
    strings: geom.StrTable = .empty,
    case: nl.NetlistCase = undefined,
    nets: NetTable = .{},
    provenance: Provenance = .{},
    ports: PortTable = .{},

    fn init(f: *Fixture) !void {
        f.* = .{};
        f.case = try nl.layoutFromNetlist(gpa, two_pin_resistor, .{}, &f.strings);
        try topology.extractNetsInto(gpa, &f.case.store, &f.case.connectivity, &f.nets);
    }

    fn deinit(f: *Fixture) void {
        f.strings.deinit(gpa);
        f.case.deinit(gpa);
        f.nets.deinit(gpa);
        f.provenance.deinit(gpa);
        f.ports.deinit(gpa);
    }

    fn label(f: *Fixture, net: usize, at: usize, name: []const u8) !geom.StrId {
        const id = try f.strings.intern(gpa, name);
        try f.provenance.label(gpa, f.case.expected_net_polys[net][at], id);
        return id;
    }

    fn netOf(f: *const Fixture, net: usize) NetId {
        return f.nets.netOf(f.case.expected_net_polys[net][0]);
    }

    fn bind(f: *Fixture) !void {
        try topology.bindPortsInto(gpa, &f.nets, f.provenance.labels(), &f.ports);
    }
};

// ---- private ----

test "a label names the net of the shape it sits on and nothing else" {
    // Oracle: construct-from-answer. Each label names its shape's net both
    // ways; net 2, unlabelled, has no name, asserted beside the two named.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.label(0, 0, "VIN");
    const second = try f.label(1, 0, "VOUT");
    try f.bind();
    try testing.expectEqual(@as(u32, 2), f.ports.len());
    try testing.expectEqual(@as(?geom.StrId, first), f.ports.nameOf(f.netOf(0)));
    try testing.expectEqual(@as(?geom.StrId, second), f.ports.nameOf(f.netOf(1)));
    try testing.expectEqual(@as(?geom.StrId, null), f.ports.nameOf(f.netOf(2)));
    try testing.expectEqual(@as(?NetId, f.netOf(0)), f.ports.netOf(first));
    try testing.expectEqual(@as(?NetId, f.netOf(1)), f.ports.netOf(second));
}

test "two different labels on one net are both kept, not a silently chosen winner" {
    // Oracle: construct-from-answer. A rail and the stub joined to it by a
    // via are one conductor; labelled VIN and VOUT it is a short, bound as
    // drawn: both names on the one net, each finding it (F14).
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rail_and_stub = f.case.expected_net_polys[0];
    try testing.expect(rail_and_stub.len >= 2);
    try testing.expect(f.nets.sameNet(rail_and_stub[0], rail_and_stub[1]));
    const first = try f.label(0, 0, "VIN");
    const second = try f.label(0, 1, "VOUT");
    try f.bind();
    const net = f.netOf(0);
    try testing.expectEqual(@as(u32, 2), f.ports.len());
    try testing.expectEqualSlices(geom.StrId, &.{ first, second }, f.ports.namesOf(net));
    try testing.expectEqual(@as(?geom.StrId, first), f.ports.nameOf(net));
    try testing.expectEqual(@as(?NetId, net), f.ports.netOf(first));
    try testing.expectEqual(@as(?NetId, net), f.ports.netOf(second));
    try testing.expectEqual(@as(?NetId, net), f.ports.shortedNet());
    try testing.expectEqual(@as(?geom.StrId, null), f.ports.splitName());
}

test "one name on two nets finds both pieces and no single net" {
    // Oracle: construct-from-answer. One name on two nets is an open: the
    // name finds both pieces ascending, and no single one is the net (F14).
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const name = try f.label(0, 0, "VIN");
    _ = try f.label(1, 0, "VIN");
    try f.bind();
    var pieces = [2]NetId{ f.netOf(0), f.netOf(1) };
    if (@backingInt(pieces[0]) > @backingInt(pieces[1])) std.mem.swap(NetId, &pieces[0], &pieces[1]);
    try testing.expect(pieces[0] != pieces[1]);
    try testing.expectEqualSlices(NetId, &pieces, f.ports.netsOf(name));
    try testing.expectEqual(@as(?NetId, null), f.ports.netOf(name));
    try testing.expectEqual(@as(?geom.StrId, name), f.ports.splitName());
    try testing.expectEqual(@as(?NetId, null), f.ports.shortedNet());
    try testing.expectEqual(@as(?geom.StrId, name), f.ports.nameOf(pieces[1]));
}

test "one name repeated across a net's shapes binds once and is no conflict" {
    // Oracle: construct-from-answer. Both ends of a wire labelled alike are
    // one name for one net: one port.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const name = try f.label(0, 0, "VIN");
    _ = try f.label(0, 1, "VIN");
    try f.bind();
    try testing.expectEqual(@as(u32, 1), f.ports.len());
    try testing.expectEqual(@as(?geom.StrId, name), f.ports.nameOf(f.netOf(0)));
    try testing.expectEqual(@as(?NetId, f.netOf(0)), f.ports.netOf(name));
}

test "binding twice into one table gives the same table" {
    // Oracle: determinism. A reused table is refilled, not appended to.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.label(0, 0, "VIN");
    const second = try f.label(1, 0, "VOUT");
    try f.bind();
    const once = .{ f.ports.len(), f.ports.netOf(first), f.ports.netOf(second) };
    try f.bind();
    try testing.expectEqual(once, .{ f.ports.len(), f.ports.netOf(first), f.ports.netOf(second) });
}

test "a label on a shape on no net is an orphan and leaves the table empty" {
    // Oracle: construct-from-answer. A marker is on no net, so a label on it
    // is refused, and the table holds nothing.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.provenance.label(gpa, f.case.expected_devices[0].marker, try f.strings.intern(gpa, "X"));
    try testing.expectError(error.OrphanLabel, f.bind());
    try testing.expectEqual(@as(u32, 0), f.ports.len());
}
