//! Point-to-point ESD resistances: a pad to each clamp on its net
//! (`esd_clamp_resistance`, a unit current from the pad to the clamp's
//! attach point; Bakhali 2020, US11714117B2 "Rpath = VIO / IESD") and pin
//! to pin through every net either pin's clamps reach (`esd_pin_pair`;
//! Khazhinsky 2012 Fig. 4, ESDA TR18.0-01 Rule 6.3.5). In: the design, the
//! intent, the process, the table. Out: violations and one `RuleRun` per
//! row. Ported from crates/check/src/erc/rules/esd.rs
//! (`check_esd_clamp_resistance`, `check_esd_pin_pair`).
//!
//! Contents:
//! - `pub fn esdClampResistance(r: Record, design: Design, process: Process, t: *const EsdClampResistanceTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn esdPinPair(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPinPairTable, scratch: *Scratch) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Outcome = report.Outcome;
const Microamps = report.Microamps;
const NetId = @import("../topology/net.zig").NetId;
const DeviceId = @import("../topology/device.zig").DeviceId;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const IntentMap = @import("facts.zig").IntentMap;
const grid_ = @import("power_grid.zig");
const Process = grid_.Process;
const PowerSolution = grid_.PowerSolution;
const PowerDiag = grid_.PowerDiag;
const power_extract = @import("power_extract.zig");
const StressGrid = power_extract.StressGrid;
const solveInto = @import("power_solve.zig").solveInto;
const clamp_reach = @import("clamp_reach.zig");
const padNetsInto = @import("rings.zig").padNetsInto;
const esd_path = @import("esd_path.zig");
const clampDevicesInto = esd_path.clampDevicesInto;
const solve = esd_path.solveStress;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("esd_tables.zig");
const EsdClampResistanceTable = tables.EsdClampResistanceTable;
const EsdPinPairTable = tables.EsdPinPairTable;

/// Every pin of the pad layer against every clamp on its net. `examined`
/// counts pairs solved; a violation sits at the pin's first vertex, names
/// it and the clamp's marker. A row is refused at the first pair whose
/// network cannot be built or solved. Needs no intent.
pub fn esdClampResistance(r: Record, design: Design, process: Process, t: *const EsdClampResistanceTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    const nets = design.nets;
    const devices = design.devices;
    // A unit current: the resistance is the rise over it.
    const unit: Microamps = .{ .raw = 1e6 };
    var stress: StressGrid = .{};
    defer stress.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    var diag: PowerDiag = .{};
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const clamps = t.clamp.items[t.clamp_start.items[row]..t.clamp_start.items[row + 1]];
        const pad_layer = t.pad.items[row];
        const limit = Measurement.resistance(t.max_resistance.items[row]);
        var examined: u64 = 0;
        var outcome: Outcome = .ran;
        // With no extracted nets no pin is on one.
        const rows = store.polysOnLayer(pad_layer);
        const last = if (nets.netCount() == 0) rows.start else rows.end;
        pins: for (rows.start..last) |p| {
            const pin: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            const net = nets.netOf(pin);
            if (net == .none or nets.holes.isHole(pin)) continue;
            for (devices.devicesOn(net)) |clamp| {
                if (std.mem.indexOfScalar(StrId, clamps, devices.model.items[@backingInt(clamp)]) == null) continue;
                const marker = devices.marker.items[@backingInt(clamp)];
                const nets_one = [1]NetId{net};
                const pins_one = [1]PolyId{marker};
                solve(gpa, design, process, .{ .nets = &nets_one, .source = pin, .current = unit, .sink = net, .pins = &pins_one, .devices = &.{}, .device_resistance = .{ .raw = 1.0 } }, &stress, &solution, scratch, &diag) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        outcome = .refused;
                        break :pins;
                    },
                };
                examined += 1;
                // mV * 1000 / µA is Ω.
                const measured = Measurement.resistance(.{ .raw = solution.node_voltage.items[stress.entry].raw * 1000.0 / unit.raw });
                if (measured.violates(limit, .maximum)) try r.out.push(gpa, .{ .rule = rule, .layer = pad_layer, .severity = severity, .at = store.firstVertex(pin), .measured = measured, .limit = limit, .shape_a = pin, .shape_b = marker });
            }
        }
        try r.run(rule, before, outcome, examined);
    }
}

/// Every two signal nets holding a polygon of the pad layer whose clamps
/// reach a supply in common: each pin of the lower net stressed against
/// the higher net's pins, through every net either reaches. `examined`
/// counts pairs solved; a violation sits at the source pin's first vertex,
/// names it and the other net's first pin. Refused at the first pair whose
/// network cannot be built or solved. The caller checks the intent.
pub fn esdPinPair(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPinPairTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    var walk: clamp_reach.Walk = .{};
    defer walk.deinit(gpa);
    var reach_a: std.ArrayList(NetId) = .empty;
    defer reach_a.deinit(gpa);
    var path: std.ArrayList(NetId) = .empty;
    defer path.deinit(gpa);
    var signals: std.ArrayList(NetId) = .empty;
    defer signals.deinit(gpa);
    var clamp_devices: std.ArrayList(DeviceId) = .empty;
    defer clamp_devices.deinit(gpa);
    var source_pins: std.ArrayList(PolyId) = .empty;
    defer source_pins.deinit(gpa);
    var held: std.ArrayList(PolyId) = .empty;
    defer held.deinit(gpa);
    var stress: StressGrid = .{};
    defer stress.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    var diag: PowerDiag = .{};
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const clamps = t.clamp.items[t.clamp_start.items[row]..t.clamp_start.items[row + 1]];
        const pad_layer = t.pad.items[row];
        const current = t.current.items[row];
        const limit = Measurement.resistance(t.max_resistance.items[row]);
        try padNetsInto(gpa, design, pad_layer, &signals);
        var kept: usize = 0;
        for (signals.items) |n| if (intent.supply(n) == null) {
            signals.items[kept] = n;
            kept += 1;
        };
        signals.shrinkRetainingCapacity(kept);
        var examined: u64 = 0;
        var outcome: Outcome = .ran;
        pairs: for (signals.items, 0..) |a, k| {
            try clamp_reach.clampReachInto(gpa, design, intent, clamps, a, &walk);
            reach_a.clearRetainingCapacity();
            try reach_a.appendSlice(gpa, walk.reached.items);
            for (signals.items[k + 1 ..]) |b| {
                try clamp_reach.clampReachInto(gpa, design, intent, clamps, b, &walk);
                const shared = for (reach_a.items) |n| {
                    if (intent.supply(n) != null and std.mem.indexOfScalar(NetId, walk.reached.items, n) != null) break true;
                } else false;
                if (!shared) continue;
                path.clearRetainingCapacity();
                try path.appendSlice(gpa, reach_a.items);
                try path.appendSlice(gpa, walk.reached.items);
                std.mem.sortUnstable(NetId, path.items, {}, lessNet);
                var n_path: usize = 0;
                for (path.items) |n| if (n_path == 0 or path.items[n_path - 1] != n) {
                    path.items[n_path] = n;
                    n_path += 1;
                };
                path.shrinkRetainingCapacity(n_path);
                try clampDevicesInto(gpa, design, intent, clamps, path.items, &clamp_devices);
                try pinsInto(gpa, design, b, pad_layer, &held);
                try pinsInto(gpa, design, a, pad_layer, &source_pins);
                for (source_pins.items) |source| {
                    solve(gpa, design, process, .{ .nets = path.items, .source = source, .current = current, .sink = b, .pins = held.items, .devices = clamp_devices.items, .device_resistance = t.clamp_resistance.items[row] }, &stress, &solution, scratch, &diag) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            outcome = .refused;
                            break :pairs;
                        },
                    };
                    examined += 1;
                    // mV * 1000 / µA is Ω.
                    const measured = Measurement.resistance(.{ .raw = solution.node_voltage.items[stress.entry].raw * 1000.0 / current.raw });
                    if (!measured.violates(limit, .maximum)) continue;
                    try r.out.push(gpa, .{ .rule = rule, .layer = pad_layer, .severity = severity, .at = store.firstVertex(source), .measured = measured, .limit = limit, .shape_a = source, .shape_b = if (held.items.len > 0) held.items[0] else report.no_shape });
                }
            }
        }
        try r.run(rule, before, outcome, examined);
    }
}

// ---- private ----

/// A net's pins: its polygons on the pad layer, holes out.
fn pinsInto(gpa: Allocator, design: Design, net: NetId, pad: LayerId, out: *std.ArrayList(PolyId)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (design.nets.polysOf(net)) |p| {
        if (design.store.polyLayer(p) == pad and !design.nets.holes.isHole(p)) try out.append(gpa, p);
    }
}

fn lessNet(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}
