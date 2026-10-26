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
//! - `erc` (erc/root.zig): facts, voltage, the power grid and its solves, the kind tables, `RuleSet`, `check`
//! - `deck`: `compile` (`CompiledDeck`, `compile`, `fromDeck`), `source` (`sourceOf`, `print`), `builder`
//!   (`DeckBuilder`, `RuleRow`), `query` (`minWidth`, `requiredSpacing`, `enclosure`, ...), `custom`
//!   (`CustomRule`, `CustomCtx`, `Findings`, `runCustom`), `rules` (`row`, `specs`, `RuleRow`), `expr`
//!   (`Expr`, `layer`, `Bound`); aliases `CompiledDeck`, `DeckBuilder`, `RuleRow`
//! - `lvs`: layout versus schematic (lvs/root.zig: `Graph`, `compareTraced`, `checkLayout`, ...)
//! - `rects`: `LayerRects`, `SortedRects`, owners, `polyDist2`, `segDist2`, `Holes`, `inMaterial`, ...
pub const report = @import("report.zig");
pub const rects = @import("rects.zig");
pub const proximity = @import("proximity.zig");
pub const proximity_distance = @import("proximity_distance.zig");
pub const proximity_inside = @import("proximity_inside.zig");
pub const drc = @import("drc/root.zig");
/// Layout versus schematic: graphs, reduction, refinement, verdicts.
pub const lvs = @import("lvs/root.zig");
pub const erc = @import("erc/root.zig");
/// The deck compiled for the engine.
pub const deck = struct {
    pub const compile = @import("deck/compile.zig");
    pub const source = @import("deck/source.zig");
    pub const builder = @import("deck/builder.zig");
    pub const query = @import("deck/query.zig");
    pub const custom = @import("deck/custom.zig");
    pub const rules = @import("deck/rules.zig");
    pub const expr = @import("deck/expr.zig");
    pub const CompiledDeck = compile.CompiledDeck;
    pub const DeckBuilder = builder.DeckBuilder;
    pub const RuleRow = rules.RuleRow;
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
    _ = drc.density;
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
    _ = erc;
    _ = deck.compile;
    _ = deck.source;
    _ = deck.builder;
    _ = deck.query;
    _ = deck.custom;
    _ = deck.rules;
    _ = deck.expr;
    _ = lvs;
}
