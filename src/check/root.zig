//! check: everything that reads a design and reports on it (ARCHITECTURE.md).
//! Only re-exports; check's Gompute kernel root.
//!
//! Files import only files above them in this order (a test in
//! tests/check.zig greps for back edges): report → rects → proximity →
//! topology/ → drc/ → erc/ → lvs/ → deck/.
//!
//! Contents:
//! - `report`: `Violations`, `Violation`, `Measurement`, `RuleRun`, `recordRun`, ...
//! - `proximity`: `Validated`, `Scratch`, `prepare*`, `crossPairs`, `judgedPairs`, net spacing, `wholeAt`, ...
//! - `proximity_distance`: `pairDistancesInto`, the `cappedDist2` row kernel
//! - `proximity_inside`: `insideWhere`, `taggedFigures`, `mergedInto`
//! - `topology`: `net` (`NetTable`, `extractNetsInto`, edge builders), `device` (`DeviceTable`,
//!   `recogniseInto`), `channel` (`refuseConductingChannels`), `port` (`PortTable`, `bindPortsInto`),
//!   `taps` (`untiedPoints*`); aliases `NetId`, `NetTable`, `extractNetsInto`, `DeviceId`,
//!   `DeviceTable`, `TerminalRole`, `recogniseInto`, `refuseConductingChannels`, `PortTable`, `bindPortsInto`
//! - `drc` (drc/root.zig): `Kind`, `Rule`, `RuleSet`, `fromDeck`, `run`, the kind tables and families
//! - `erc`: `kinds` (the ERC kind names, until wave 4)
//! - `deck`: `compile` (`CompiledDeck`, `compile`, `fromDeck`), alias `CompiledDeck`
//! - `rects`: `LayerRects`, `SortedRects`, owners, `polyDist2`, `segDist2`, `Holes`, `inMaterial`, ...
pub const report = @import("report.zig");
pub const rects = @import("rects.zig");
pub const proximity = @import("proximity.zig");
pub const proximity_distance = @import("proximity_distance.zig");
pub const proximity_inside = @import("proximity_inside.zig");
pub const drc = @import("drc/root.zig");
pub const erc = struct {
    pub const kinds = @import("erc/kinds.zig");
};
/// The deck compiled for the engine.
pub const deck = struct {
    pub const compile = @import("deck/compile.zig");
    pub const CompiledDeck = compile.CompiledDeck;
};

/// Electrical structure from geometry: nets, devices, ports, tap reach.
pub const topology = struct {
    pub const net = @import("topology/net.zig");
    pub const device = @import("topology/device.zig");
    pub const channel = @import("topology/channel.zig");
    pub const port = @import("topology/port.zig");
    pub const taps = @import("topology/taps.zig");
    pub const NetId = net.NetId;
    pub const NetTable = net.NetTable;
    pub const extractNetsInto = net.extractNetsInto;
    pub const DeviceId = device.DeviceId;
    pub const DeviceTable = device.DeviceTable;
    pub const TerminalRole = device.TerminalRole;
    pub const recogniseInto = device.recogniseInto;
    pub const refuseConductingChannels = channel.refuseConductingChannels;
    pub const PortTable = port.PortTable;
    pub const bindPortsInto = port.bindPortsInto;
};

// The device compile reads only this root's comptime blocks: name every
// kernel-owning file here.
comptime {
    _ = proximity_distance;
}

// ---- private ----

/// `std.testing.refAllDecls`, recursing into the namespaces and types this
/// module declares, so a pub function no test calls yet is still compiled.
fn refAll(comptime T: type) void {
    const std = @import("std");
    inline for (comptime std.meta.declarations(T)) |name| {
        const decl = @field(T, name);
        if (@TypeOf(decl) == type) switch (@typeInfo(decl)) {
            .@"struct", .@"union", .@"enum" => refAll(decl),
            else => {},
        } else _ = &@field(T, name);
    }
}

test {
    // Every pub body analyzed, called by a test yet or not.
    refAll(@This());
    _ = report;
    _ = rects;
    _ = proximity;
    _ = proximity_distance;
    _ = proximity_inside;
    _ = topology.net;
    _ = topology.device;
    _ = topology.channel;
    _ = topology.port;
    _ = topology.taps;
    _ = drc;
    _ = erc.kinds;
    _ = deck.compile;
}
