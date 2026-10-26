//! The topological kinds: what is connected to what, and the well-tap
//! containment test. In: nets, devices, `NetFacts`, the well and tap
//! geometry, the intent's rails. Out: violations and one run per row.
//! `floating_gate` (ERC-G1), `fanout` (ERC-H4), `floating_well` (ERC-G2),
//! `multiple_drivers` (ERC-G3) and `unconnected_pin` (ERC-G6) here; the
//! path kinds (`supply_path`, `gate_path`, `net_type`,
//! `combinational_loop`) in topology_paths.zig. Ported from
//! crates/check/src/erc/rules/topology.rs.
//!
//! Contents:
//! - `pub fn checkFloatingGate(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, t: *const FloatingGateTable) Allocator.Error!void`
//! - `pub fn checkFloatingWell(r: Record, design: Design, t: *const FloatingWellTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkMultipleDrivers(r: Record, design: Design, intent: *const IntentMap, t: *const MultipleDriversTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkUnconnectedPin(r: Record, design: Design, facts: *const NetFacts, t: *const UnconnectedPinTable) Allocator.Error!void`
//! - `pub fn checkFanout(r: Record, design: Design, t: *const FanoutTable) Allocator.Error!void`
//! - `pub fn checkSupplyPath`, `checkGatePath`, `checkNetType`, `checkCombinationalLoop` (re-exported from topology_paths.zig)

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const DbuArea = geom.DbuArea;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const NetId = @import("../topology/net.zig").NetId;
const PortTable = @import("../topology/port.zig").PortTable;
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const facts_ = @import("facts.zig");
const NetFacts = facts_.NetFacts;
const IntentMap = facts_.IntentMap;
const Scratch = @import("scratch.zig").Scratch;
const paths = @import("topology_paths.zig");
const tables = @import("topology_tables.zig");
const FanoutTable = tables.FanoutTable;
const FloatingGateTable = tables.FloatingGateTable;
const FloatingWellTable = tables.FloatingWellTable;
const MultipleDriversTable = tables.MultipleDriversTable;
const UnconnectedPinTable = tables.UnconnectedPinTable;

pub const checkSupplyPath = paths.checkSupplyPath;
pub const checkGatePath = paths.checkGatePath;
pub const checkNetType = paths.checkNetType;
pub const checkCombinationalLoop = paths.checkCombinationalLoop;

/// A gate net with nothing driving it (its role mask exactly gate);
/// `labels_are_ports` spares a labelled net. `examined` counts nets with a
/// gate; a finding measures 0 non-gate terminals against 1.
pub fn checkFloatingGate(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, t: *const FloatingGateTable) Allocator.Error!void {
    var examined: u64 = 0;
    var flagged: std.ArrayList(u32) = .empty;
    defer flagged.deinit(r.gpa);
    var unlabelled: std.ArrayList(u32) = .empty;
    defer unlabelled.deinit(r.gpa);
    for (facts.role.items, 0..) |role, n| {
        examined += @intFromBool(role.gate);
        if (@as(u8, @bitCast(role)) != @as(u8, @bitCast(facts_.RoleMask{ .gate = true }))) continue;
        try flagged.append(r.gpa, @intCast(n));
        if (ports.nameOf(@fromBackingInt(@as(u32, @intCast(n)))) == null) try unlabelled.append(r.gpa, @intCast(n));
    }
    for (t.head.rule.items, t.head.severity.items, t.labels_are_ports.items) |rule, severity, labels| {
        const before = r.out.len();
        try r.netViolations(design, if (labels) unlabelled.items else flagged.items, rule, severity, .count(0), .count(1));
        try r.run(rule, before, .ran, examined);
    }
}

/// A net driving more than `max_gates` MOS gates. `examined` counts nets
/// with a gate; a finding measures the gate count against `max`.
pub fn checkFanout(r: Record, design: Design, t: *const FanoutTable) Allocator.Error!void {
    const devices = design.devices;
    const gates = try r.gpa.alloc(u32, design.nets.netCount());
    defer r.gpa.free(gates);
    @memset(gates, 0);
    for (0..devices.len()) |d| {
        if (devices.kind.items[d] != .mos) continue;
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        for (term.nets, term.roles) |net, role| {
            if (role == .gate and net != .none and @backingInt(net) < gates.len) gates[@backingInt(net)] += 1;
        }
    }
    var examined: u64 = 0;
    for (gates) |count| examined += @intFromBool(count > 0);
    for (t.head.rule.items, t.head.severity.items, t.max_gates.items) |rule, severity, limit| {
        const before = r.out.len();
        for (gates, 0..) |count, n| {
            if (count <= limit) continue;
            try r.netViolations(design, &.{@intCast(n)}, rule, severity, .count(count), .count(limit));
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// A figure of the merged `well` layer that no tap ties: a tap ties the
/// well covering all its area. `examined` counts wells; a finding sits at
/// the well's lowest drawn polygon. Refused when a layer will not validate.
pub fn checkFloatingWell(r: Record, design: Design, t: *const FloatingWellTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    var merged: geom.ValidatedLayer = .empty;
    defer merged.deinit(gpa);
    var well_rects: std.ArrayList(Bbox) = .empty;
    defer well_rects.deinit(gpa);
    var well_start: std.ArrayList(u32) = .empty;
    defer well_start.deinit(gpa);
    var tap_rects: std.ArrayList(Bbox) = .empty;
    defer tap_rects.deinit(gpa);
    var tap_start: std.ArrayList(u32) = .empty;
    defer tap_start.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var by_well: rects.SortedRects = .{};
    defer by_well.deinit(gpa);
    var drawn: rects.LayerRects = .{};
    defer drawn.deinit(gpa);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    var tied: std.ArrayList(bool) = .empty;
    defer tied.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.well.items, t.tap.items) |rule, severity, well_layer, tap_layer| {
        const before = r.out.len();
        if (try geom.view.validateLayer(gpa, store, well_layer, .rectilinear, &scratch.layer_a) != null or
            try geom.view.validateLayer(gpa, store, tap_layer, .rectilinear, &scratch.layer_b) != null)
        {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        const nothing: geom.ValidatedLayer = .empty;
        try geom.boolean.unionInto(gpa, &scratch.layer_a, &nothing, &merged);
        try geom.rects.decomposeInto(gpa, &merged, &well_rects, &well_start);
        try geom.rects.decomposeInto(gpa, &scratch.layer_b, &tap_rects, &tap_start);
        const wells = merged.len();
        labels.clearRetainingCapacity();
        for (0..wells) |w| try labels.appendNTimes(gpa, @intCast(w), well_start.items[w + 1] - well_start.items[w]);
        try by_well.build(gpa, well_rects.items, labels.items);
        tied.clearRetainingCapacity();
        try tied.appendNTimes(gpa, false, wells);
        for (0..scratch.layer_b.len()) |tap| {
            const mine = tap_rects.items[tap_start.items[tap]..tap_start.items[tap + 1]];
            if (mine.len == 0) continue;
            const area = geom.rects.coveredArea(mine);
            var hits = by_well.overlapping(mine[0]);
            while (hits.next()) |h| {
                const theirs = well_rects.items[well_start.items[h.label]..well_start.items[h.label + 1]];
                var covered: DbuArea = 0;
                for (mine) |m| covered += geom.rects.clippedArea(theirs, m);
                tied.items[h.label] = tied.items[h.label] or covered == area;
            }
        }
        try drawn.build(gpa, store, well_layer, &scratch.layer_a);
        try rects.ownersOfInto(gpa, &merged, &drawn, &owners);
        for (owners.items, tied.items) |well, is_tied| {
            if (is_tied) continue;
            try r.out.push(gpa, .{ .rule = rule, .layer = well_layer, .severity = severity, .at = store.firstVertex(well), .measured = .count(0), .limit = .count(1), .shape_a = well, .shape_b = report.no_shape });
        }
        try r.run(rule, before, .ran, wells);
    }
}

/// A net driven by more than `max_drivers` distinct pull networks (a
/// channel path to a rail; networks sharing a gate net are one driver).
/// `examined` counts the non-rail nets with a channel end. Skipped without
/// a declared supply.
pub fn checkMultipleDrivers(r: Record, design: Design, intent: *const IntentMap, t: *const MultipleDriversTable, scratch: *Scratch) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    try paths.driversInto(r.gpa, design, intent, &scratch.edges);
    const examined: u64 = scratch.edges.items.len;
    for (t.head.rule.items, t.head.severity.items, t.max_drivers.items) |rule, severity, max| {
        const before = r.out.len();
        for (scratch.edges.items) |e| {
            if (e[1] <= max) continue;
            try r.netViolations(design, &.{e[0]}, rule, severity, .count(e[1]), .count(max));
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every polygon on a listed layer whose net reaches no device terminal
/// (or on no net). `examined` counts the polygons on the row's layers.
pub fn checkUnconnectedPin(r: Record, design: Design, facts: *const NetFacts, t: *const UnconnectedPinTable) Allocator.Error!void {
    // With no classified nets, `netOf` has no column to read.
    const extracted = facts.role.items.len > 0;
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        var examined: u64 = 0;
        for (t.layer.items[t.layer_start.items[row]..t.layer_start.items[row + 1]]) |layer| {
            const polys = design.store.polysOnLayer(layer);
            examined += polys.len();
            for (polys.start..polys.end) |p| {
                const poly: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
                const net: NetId = if (extracted) design.nets.netOf(poly) else .none;
                if (net != .none and @backingInt(net) < facts.role.items.len and facts.isDeviceConnected(net)) continue;
                try r.out.push(r.gpa, .{ .rule = rule, .layer = layer, .severity = severity, .at = design.store.firstVertex(poly), .measured = .count(0), .limit = .count(1), .shape_a = poly, .shape_b = report.no_shape });
            }
        }
        try r.run(rule, before, .ran, examined);
    }
}
