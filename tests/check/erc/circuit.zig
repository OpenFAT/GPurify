//! A hand-drawn netlist laid out (testgen's rail-and-stub floorplan),
//! extracted and recognised, its devices given their spec's kinds and
//! models back: the input the voltage and ESD rule suites state their
//! circuits as. Ported from the `Circuit` and `build` helpers of
//! crates/check/tests/erc/{voltage_rules,esd_geometry}.rs.
//!
//! Contents:
//! - `pub const Circuit = struct`, `deinit`, `design(c) Design`, `net(c, n: usize) NetId`, `model(c, name) StrId`,
//!   `models(c, arena, names) ![]const StrId`, `intent(c, supplies: []const Supply) !IntentMap`,
//!   `voltage(c, intent: *const IntentMap) !NetVoltage`, `setSwitch(c, device: usize, min: ?f64, max: ?f64) !void`
//! - `pub const Supply = struct`, `pub fn build(nets: u32, devices: []const DeviceSpec) !Circuit`
//! - `pub fn mos(arena, model, gate, source, drain, bulk) !DeviceSpec`, `pub fn twoPin(arena, kind, model, a, b) !DeviceSpec`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const StrId = geom.StrId;
const LayerId = geom.LayerId;
const DeviceKind = ingest.deck.DeviceKind;
const SupplyRole = ingest.intent.SupplyRole;
const DomainId = ingest.intent.DomainId;
const topology = check.topology;
const NetId = topology.NetId;
const erc = check.erc;
const IntentMap = erc.facts.IntentMap;
const NetVoltage = erc.voltage.NetVoltage;
const nl = testgen.netlist;
const gpa = testing.allocator;

pub const DeviceSpec = nl.DeviceSpec;

/// A declared supply: netlist net, role, domain, the domain's nominal mV.
pub const Supply = struct { net: usize, role: SupplyRole, domain: u32, mv: f64 };

/// A laid-out netlist, extracted, with the models it names.
pub const Circuit = struct {
    case: nl.NetlistCase,
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},
    strings: geom.StrTable = .empty,

    pub fn deinit(c: *Circuit) void {
        c.case.deinit(gpa);
        c.nets.deinit(gpa);
        c.devices.deinit(gpa);
        c.strings.deinit(gpa);
    }

    pub fn design(c: *const Circuit) erc.Design {
        return .{ .store = &c.case.store, .nets = &c.nets, .devices = &c.devices };
    }

    /// The extracted id of netlist net `n`.
    pub fn net(c: *const Circuit, n: usize) NetId {
        return c.nets.netOf(c.case.expected_net_polys[n][0]);
    }

    pub fn model(c: *const Circuit, name: []const u8) StrId {
        return c.strings.get(name).?;
    }

    pub fn models(c: *const Circuit, arena: std.mem.Allocator, names: []const []const u8) ![]const StrId {
        const out = try arena.alloc(StrId, names.len);
        for (out, names) |*o, n| o.* = c.model(n);
        return out;
    }

    /// An intent map of these supplies, ascending by net. The caller deinits it.
    pub fn intent(c: *const Circuit, supplies: []const Supply) !IntentMap {
        var m: IntentMap = .{ .declared = true };
        errdefer m.deinit(gpa);
        const order = try gpa.alloc(usize, supplies.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        const Ctx = struct { c: *const Circuit, s: []const Supply };
        std.mem.sortUnstable(usize, order, Ctx{ .c = c, .s = supplies }, struct {
            fn less(x: Ctx, a: usize, b: usize) bool {
                return @backingInt(x.c.net(x.s[a].net)) < @backingInt(x.c.net(x.s[b].net));
            }
        }.less);
        for (order) |i| {
            const s = supplies[i];
            try m.supply_net.append(gpa, c.net(s.net));
            try m.supply_role.append(gpa, s.role);
            try m.supply_domain.append(gpa, @fromBackingInt(s.domain));
            try m.supply_voltage.append(gpa, .{ .raw = s.mv });
        }
        return m;
    }

    /// The propagated voltages. The caller deinits them.
    pub fn voltage(c: *const Circuit, m: *const IntentMap) !NetVoltage {
        var v: NetVoltage = .{};
        errdefer v.deinit(gpa);
        try erc.voltage.propagateInto(gpa, &c.nets, &c.devices, m, &v);
        return v;
    }

    /// Device `device`'s gate condition, as a deck row would set it.
    pub fn setSwitch(c: *Circuit, device: usize, min: ?f64, max: ?f64) !void {
        const count = c.devices.len();
        while (c.devices.value.items.len < count) try c.devices.value.append(gpa, .{});
        c.devices.value.items[device] = .{ .on_gate_min_mv = min, .on_gate_max_mv = max };
    }
};

/// Lays out and extracts `devices`. Every column shares one marker layer,
/// so recognisers with the same terminal layers would each claim every
/// marker: one recogniser per terminal-layer list, then each device takes
/// its spec's kind and model back.
pub fn build(nets: u32, devices: []const DeviceSpec) !Circuit {
    var c: Circuit = .{ .case = undefined };
    c.case = try nl.layoutFromNetlist(gpa, .{ .nets = nets, .devices = devices }, .{}, &c.strings);
    errdefer c.deinit();
    try topology.extractNetsInto(gpa, &c.case.store, &c.case.connectivity, &c.nets);
    const full = c.case.recognition;
    const arena = c.case.arena.allocator();
    var kind: std.ArrayList(DeviceKind) = .empty;
    var marker: std.ArrayList(LayerId) = .empty;
    var model: std.ArrayList(StrId) = .empty;
    var terminal: std.ArrayList(LayerId) = .empty;
    var start: std.ArrayList(u32) = .empty;
    try start.append(arena, 0);
    for (0..full.kind.len) |row| {
        const terms = full.terminal[full.terminal_start[row]..full.terminal_start[row + 1]];
        const seen = for (0..kind.items.len) |kept| {
            if (std.mem.eql(LayerId, terminal.items[start.items[kept]..start.items[kept + 1]], terms)) break true;
        } else false;
        if (seen) continue;
        try kind.append(arena, full.kind[row]);
        try marker.append(arena, full.marker[row]);
        try model.append(arena, full.model[row]);
        try terminal.appendSlice(arena, terms);
        try start.append(arena, @intCast(terminal.items.len));
    }
    const recognition: ingest.deck.DeviceRecognition = .{ .kind = kind.items, .marker = marker.items, .terminal_start = start.items, .terminal = terminal.items, .model = model.items };
    try topology.recogniseInto(gpa, &c.case.store, &c.nets, &recognition, &c.devices);
    try testing.expectEqual(c.case.expected_devices.len, c.devices.len());
    for (c.case.expected_devices, 0..) |e, i| {
        // Device order is spec order.
        try testing.expectEqual(e.marker, c.devices.marker.items[i]);
        c.devices.kind.items[i] = e.kind;
        c.devices.model.items[i] = e.model;
    }
    return c;
}

pub fn mos(arena: std.mem.Allocator, model: []const u8, gate: u32, source: u32, drain: u32, bulk: u32) !DeviceSpec {
    return .{ .kind = .mos, .model = model, .terminals = try arena.dupe(nl.TerminalSpec, &.{ .{ .role = .gate, .net = gate }, .{ .role = .source, .net = source }, .{ .role = .drain, .net = drain }, .{ .role = .bulk, .net = bulk } }) };
}

pub fn twoPin(arena: std.mem.Allocator, kind: DeviceKind, model: []const u8, a: u32, b: u32) !DeviceSpec {
    return .{ .kind = kind, .model = model, .terminals = try arena.dupe(nl.TerminalSpec, &.{ .{ .role = .{ .pin = 0 }, .net = a }, .{ .role = .{ .pin = 1 }, .net = b } }) };
}
