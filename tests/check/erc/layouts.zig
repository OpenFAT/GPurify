//! Extracted designs the layout-family suites build: a layout emitted from a
//! netlist and extracted (`Extracted`), or a hand-drawn store extracted
//! under a stated connectivity (`Drawn`). Nothing here states an answer.
//! Ported from the `Extracted`/`Drawn` builders of
//! crates/check/tests/erc/{topological_rules,supply_rules}.rs.
//!
//! Contents:
//! - `pub const Extracted = struct`, `init(spec: NetlistSpec) !Extracted`, `deinit`, `design`, `lowestPoly(e, n: usize) PolyId`,
//!   `netOf(e, n: usize) NetId`, `rails(e, power: usize, ground: usize) !IntentMap`
//! - `pub const Drawn = struct`, `init(lb: *LayoutBuilder, connectivity: Connectivity) !Drawn`, `deinit`, `design`
//! - `pub fn mos(model: []const u8, terminals: []const TerminalSpec) DeviceSpec`
//! - `pub fn viaConnectivity(comptime cut: u16, comptime joined: []const u16) Connectivity`

const std = @import("std");
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const Connectivity = ingest.deck.Connectivity;
const topology = check.topology;
const NetId = topology.NetId;
const erc = check.erc;
const nl = testgen.netlist;
const common = @import("common.zig");
const gpa = common.gpa;

/// A layout emitted from a netlist, extracted and classified.
pub const Extracted = struct {
    strings: geom.StrTable = .empty,
    case: nl.NetlistCase,
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},
    facts: erc.facts.NetFacts = .{},

    pub fn init(spec: nl.NetlistSpec) !Extracted {
        var e: Extracted = .{ .case = undefined };
        e.case = try nl.layoutFromNetlist(gpa, spec, .{}, &e.strings);
        errdefer e.deinit();
        try topology.extractNetsInto(gpa, &e.case.store, &e.case.connectivity, &e.nets);
        try topology.recogniseInto(gpa, &e.case.store, &e.nets, &e.case.recognition, &e.devices);
        try erc.facts.classifyNetsInto(gpa, &e.nets, &e.devices, &e.facts);
        return e;
    }

    pub fn deinit(e: *Extracted) void {
        e.facts.deinit(gpa);
        e.devices.deinit(gpa);
        e.nets.deinit(gpa);
        e.case.deinit(gpa);
        e.strings.deinit(gpa);
    }

    pub fn design(e: *const Extracted) erc.Design {
        return .{ .store = &e.case.store, .nets = &e.nets, .devices = &e.devices };
    }

    /// Netlist net `n`'s lowest polygon: where a per-net rule reports.
    pub fn lowestPoly(e: *const Extracted, n: usize) PolyId {
        return e.case.expected_net_polys[n][0];
    }

    pub fn netOf(e: *const Extracted, n: usize) NetId {
        return e.nets.netOf(e.lowestPoly(n));
    }

    /// Intent declaring netlist nets `power` and `ground` the supplies.
    pub fn rails(e: *const Extracted, power: usize, ground: usize) !erc.facts.IntentMap {
        return common.declaredSupplies(e.netOf(power), e.netOf(ground), 1_800.0);
    }
};

/// A hand-drawn store extracted under a stated connectivity; no devices.
pub const Drawn = struct {
    store: GeometryStore = .empty,
    ids: testgen.shapes.Ids = .{},
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},

    /// Finishes `lb` (and deinits it).
    pub fn init(lb: *testgen.shapes.LayoutBuilder, connectivity: Connectivity) !Drawn {
        defer lb.deinit(gpa);
        var d: Drawn = .{};
        errdefer d.deinit();
        try lb.finish(gpa, &d.store, &d.ids);
        try topology.extractNetsInto(gpa, &d.store, &connectivity, &d.nets);
        return d;
    }

    pub fn deinit(d: *Drawn) void {
        d.store.deinit(gpa);
        d.ids.deinit(gpa);
        d.nets.deinit(gpa);
        d.devices.deinit(gpa);
    }

    pub fn design(d: *const Drawn) erc.Design {
        return .{ .store = &d.store, .nets = &d.nets, .devices = &d.devices };
    }
};

pub fn mos(model: []const u8, terminals: []const nl.TerminalSpec) nl.DeviceSpec {
    return .{ .kind = .mos, .model = model, .terminals = terminals };
}

/// Every listed layer conducts, cut `cut` joins each to layer 0, touching
/// within a layer does not connect. The slices are static per call site.
pub fn viaConnectivity(comptime cut: u16, comptime joined: []const u16) Connectivity {
    const c = comptime blk: {
        var conductors: [joined.len + 1]LayerId = undefined;
        var cuts: [joined.len]LayerId = undefined;
        var connects: [joined.len][2]LayerId = undefined;
        conductors[0] = @fromBackingInt(0);
        for (joined, 0..) |j, i| {
            conductors[i + 1] = @fromBackingInt(j);
            cuts[i] = @fromBackingInt(cut);
            connects[i] = .{ @fromBackingInt(0), @fromBackingInt(j) };
        }
        const fc = conductors;
        const fcut = cuts;
        const fcon = connects;
        break :blk .{ &fc, &fcut, &fcon };
    };
    return .{ .conductors = c[0], .via_cut = c[1], .via_connects = c[2] };
}
