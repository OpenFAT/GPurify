//! Generated circuits for the naive references: a netlist laid out by
//! testgen, extracted, and recognised so each device takes its spec's kind
//! and model back, with the supplies its intent declares. Ported from
//! tests/exhaustive/erc_reference.rs (`Circuit`, `random_circuit`,
//! `built`).
//!
//! Contents:
//! - `pub const Circuit = struct`, `deinit`, `net(c, n: u32) NetId`, `design(c) Design`
//! - `pub const SupplySpec = struct { net: u32, role: SupplyRole }`
//! - `pub fn randomCircuit(rng: *Rng, strings: *StrTable) !Circuit`
//! - `pub fn built(nets: u32, devices: []const DeviceSpec, supplies: []const SupplySpec, strings: *StrTable) !Circuit`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const StrTable = geom.StrTable;
const Rng = testgen.Rng;
const nl = testgen.netlist;
const DeviceSpec = nl.DeviceSpec;
const topology = check.topology;
const NetId = topology.NetId;
const SupplyRole = ingest.intent.SupplyRole;
const gpa = testing.allocator;

/// A netlist supply: its netlist net and role.
pub const SupplySpec = struct { net: u32, role: SupplyRole };

/// A generated circuit, laid out and extracted.
pub const Circuit = struct {
    case: nl.NetlistCase,
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},
    supplies: std.ArrayList(SupplySpec) = .empty,

    pub fn deinit(c: *Circuit) void {
        c.supplies.deinit(gpa);
        c.devices.deinit(gpa);
        c.nets.deinit(gpa);
        c.case.deinit(gpa);
    }

    /// Netlist net `n` as extraction numbered it.
    pub fn net(c: *const Circuit, n: u32) NetId {
        return c.nets.netOf(c.case.expected_net_polys[n][0]);
    }

    pub fn design(c: *const Circuit) check.erc.Design {
        return .{ .store = &c.case.store, .nets = &c.nets, .devices = &c.devices };
    }
};

/// Six to twelve nets, one to four of them supplies of either role, and
/// three to twelve devices: a clamp diode (model `clamp`) one time in four,
/// otherwise a transistor with every terminal on any net.
pub fn randomCircuit(rng: *Rng, strings: *StrTable) !Circuit {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nets: u32 = 6 + @as(u32, @intCast(rng.below(7)));
    var supplies: std.ArrayList(SupplySpec) = .empty;
    for (0..2 + rng.below(3)) |_| {
        const net: u32 = @intCast(rng.below(nets));
        const fresh = for (supplies.items) |s| {
            if (s.net == net) break false;
        } else true;
        if (fresh) try supplies.append(a, .{ .net = net, .role = if (rng.below(2) == 0) .power else .ground });
    }
    const count = 3 + rng.below(10);
    const devices = try a.alloc(DeviceSpec, count);
    for (devices) |*d| {
        if (rng.below(4) == 0) {
            const t = try a.alloc(nl.TerminalSpec, 2);
            t[0] = .{ .role = .{ .pin = 0 }, .net = @intCast(rng.below(nets)) };
            t[1] = .{ .role = .{ .pin = 1 }, .net = @intCast(rng.below(nets)) };
            d.* = .{ .kind = .diode, .model = "clamp", .terminals = t };
        } else {
            const t = try a.alloc(nl.TerminalSpec, 4);
            for (t, [_]topology.TerminalRole{ .gate, .source, .drain, .bulk }) |*x, role| x.* = .{ .role = role, .net = @intCast(rng.below(nets)) };
            d.* = .{ .kind = .mos, .model = "mos", .terminals = t };
        }
    }
    return built(nets, devices, supplies.items, strings);
}

/// A netlist laid out, extracted and recognised: every column shares one
/// marker layer, so one recogniser per terminal-layer list, and each device
/// then takes its spec's kind and model back.
pub fn built(nets: u32, devices: []const DeviceSpec, supplies: []const SupplySpec, strings: *StrTable) !Circuit {
    var c: Circuit = .{ .case = try nl.layoutFromNetlist(gpa, .{ .nets = nets, .devices = devices }, .{}, strings) };
    errdefer c.deinit();
    try c.supplies.appendSlice(gpa, supplies);
    try topology.extractNetsInto(gpa, &c.case.store, &c.case.connectivity, &c.nets);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const full = c.case.recognition;
    var kind: std.ArrayList(ingest.deck.DeviceKind) = .empty;
    var marker: std.ArrayList(geom.LayerId) = .empty;
    var model: std.ArrayList(geom.StrId) = .empty;
    var start: std.ArrayList(u32) = .empty;
    var terminal: std.ArrayList(geom.LayerId) = .empty;
    try start.append(a, 0);
    for (0..full.kind.len) |row| {
        const terms = full.terminal[full.terminal_start[row]..full.terminal_start[row + 1]];
        const seen = for (0..kind.items.len) |kept| {
            if (std.mem.eql(geom.LayerId, terminal.items[start.items[kept]..start.items[kept + 1]], terms)) break true;
        } else false;
        if (seen) continue;
        try kind.append(a, full.kind[row]);
        try marker.append(a, full.marker[row]);
        try model.append(a, full.model[row]);
        try terminal.appendSlice(a, terms);
        try start.append(a, @intCast(terminal.items.len));
    }
    const recognition: ingest.deck.DeviceRecognition = .{ .kind = kind.items, .marker = marker.items, .terminal_start = start.items, .terminal = terminal.items, .model = model.items };
    try topology.recogniseInto(gpa, &c.case.store, &c.nets, &recognition, &c.devices);
    try testing.expectEqual(@as(u32, @intCast(c.case.expected_devices.len)), c.devices.len());
    for (c.case.expected_devices, 0..) |want, i| {
        try testing.expectEqual(want.marker, c.devices.marker.items[i]);
        c.devices.kind.items[i] = want.kind;
        c.devices.model.items[i] = want.model;
    }
    return c;
}
