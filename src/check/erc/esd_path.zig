//! ESD discharge paths under a forced current (`esd_path`): for each pin
//! and each declared supply its clamps reach, the stress network of every
//! net on the path solved for the pin's rise, the path resistance, and the
//! current each clamp, wire and cut carries; with `clamp_voltage` each
//! clamp also holds that voltage (Industry Council White Paper 2 §2.9.3).
//! In: the design, the intent, the process, the table. Out: violations and
//! one `RuleRun` per row. Catalog ERC-C2/C6/C7/C8/C14/D4 (ESDA TR18.0-01
//! §2.1, Fig. 58; TR22 §4; JS-001; Khazhinsky 2012; GF180MCU §14.5). Ported
//! from crates/check/src/erc/rules/esd.rs (`check_esd_path`, `turn_on`,
//! `clamp_capacity`, `interconnect_capacity`, `narrow_wires`).
//!
//! ponytail: pin pairs are solved one after another; each is an
//! independent small CG, so a row could farm them to a thread pool writing
//! per-pair violation tables merged in pair order, when a profile asks.
//!
//! Contents:
//! - `pub fn esdPath(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPathTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn solveStress(gpa: Allocator, design: Design, process: Process, stress: Stress, out: *StressGrid, solution: *PowerSolution, scratch: *Scratch, diag: *PowerDiag) !void`
//! - `pub fn clampDevicesInto(gpa: Allocator, design: Design, intent: *const IntentMap, clamps: []const StrId, path: []const NetId, out: *std.ArrayList(DeviceId)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const StrId = geom.StrId;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Severity = report.Severity;
const Outcome = report.Outcome;
const Millivolts = report.Millivolts;
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
const allowedCurrent = @import("em_allowed.zig").allowedCurrent;
const electrical = @import("electrical_tables.zig");
const CurrentDensity = electrical.CurrentDensity;
const Scratch = @import("scratch.zig").Scratch;
const EsdPathTable = @import("esd_tables.zig").EsdPathTable;

const Head = struct { rule: StrId, severity: Severity };

/// Every row over every pin of its source layer (the caller has checked
/// the intent is usable). `examined` counts pin pairs solved. A row is
/// refused at the first pair whose network cannot be built or solved (or
/// turned on), or with `clamp_it2`, whose clamps include one with no
/// measured size; violations found before stay.
pub fn esdPath(r: Record, design: Design, intent: *const IntentMap, process: Process, t: *const EsdPathTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    const nets = design.nets;
    var walk: clamp_reach.Walk = .{};
    defer walk.deinit(gpa);
    var path: std.ArrayList(NetId) = .empty;
    defer path.deinit(gpa);
    var clamp_devices: std.ArrayList(DeviceId) = .empty;
    defer clamp_devices.deinit(gpa);
    var pins: std.ArrayList(PolyId) = .empty;
    defer pins.deinit(gpa);
    var stress: StressGrid = .{};
    defer stress.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    var diag: PowerDiag = .{};
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const head: Head = .{ .rule = rule, .severity = severity };
        const clamps = t.clamp.items[t.clamp_start.items[row]..t.clamp_start.items[row + 1]];
        const pad_layer = t.pad.items[row];
        const current = t.current.items[row];
        var examined: u64 = 0;
        var outcome: Outcome = .ran;
        const source_layer = t.source.items[row];
        const rows = store.polysOnLayer(source_layer);
        pins: for (rows.start..rows.end) |p| {
            const source: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            const net = nets.netOf(source);
            if (net == .none or nets.holes.isHole(source)) continue;
            try clamp_reach.clampReachInto(gpa, design, intent, clamps, net, &walk);
            path.clearRetainingCapacity();
            try path.appendSlice(gpa, walk.reached.items);
            std.mem.sortUnstable(NetId, path.items, {}, lessNet);
            try clampDevicesInto(gpa, design, intent, clamps, path.items, &clamp_devices);
            for (path.items) |target| {
                if (intent.supply(target) == null) continue;
                pins.clearRetainingCapacity();
                for (nets.polysOf(target)) |q| if (store.polyLayer(q) == pad_layer and !nets.holes.isHole(q)) try pins.append(gpa, q);
                solveStress(gpa, design, process, .{
                    .nets = path.items,
                    .source = source,
                    .current = current,
                    .sink = target,
                    .pins = pins.items,
                    .devices = clamp_devices.items,
                    .device_resistance = t.clamp_resistance.items[row],
                }, &stress, &solution, scratch, &diag) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        outcome = .refused;
                        break :pins;
                    },
                };
                examined += 1;
                const g = &stress.grid;
                const held = g.node_poly.items[g.source_node.items[0]];
                // Ohm's law in the grid's units: mV * 1000 / µA is Ω.
                const resistive = solution.node_voltage.items[stress.entry];
                const ohms = Measurement.resistance(.{ .raw = resistive.raw * 1000.0 / current.raw });
                if (t.clamp_voltage.items[row]) |v| {
                    if (!try turnOn(gpa, &stress, &solution, v, current, scratch)) {
                        outcome = .refused;
                        break :pins;
                    }
                }
                const at = store.firstVertex(source);
                if (t.max_resistance.items[row]) |lim| {
                    const limit = Measurement.resistance(lim);
                    if (ohms.violates(limit, .maximum)) try push(r, head, source_layer, at, ohms, limit, source, held);
                }
                const rise = Measurement.voltage(solution.node_voltage.items[stress.entry]);
                if (t.max_voltage.items[row]) |lim| {
                    const limit = Measurement.voltage(lim);
                    if (rise.violates(limit, .maximum)) try push(r, head, source_layer, at, rise, limit, source, held);
                }
                if (t.clamp_it2.items[row]) |it2| {
                    if (!try clampCapacity(r, design, process.grid, source, &stress, &solution, it2, head)) {
                        outcome = .refused;
                        break :pins;
                    }
                }
                try interconnectCapacity(r, &stress, &solution, process, t.max_density.items[row], t.max_current_per_cut.items[row], head);
                if (t.min_width.items[row]) |w| try narrowWires(r, &stress, &solution, current, w, head);
            }
        }
        try r.run(rule, before, outcome, examined);
    }
}

/// The clamp devices joining the path nets: every device of a `clamps`
/// model on a path net that `reverseBiased` takes as wired, ascending,
/// once each.
pub fn clampDevicesInto(gpa: Allocator, design: Design, intent: *const IntentMap, clamps: []const StrId, path: []const NetId, out: *std.ArrayList(DeviceId)) Allocator.Error!void {
    const devices = design.devices;
    out.clearRetainingCapacity();
    for (path) |on| for (devices.devicesOn(on)) |d| {
        if (std.mem.indexOfScalar(StrId, clamps, devices.model.items[@backingInt(d)]) == null) continue;
        if (!clamp_reach.reverseBiased(design, intent, d)) continue;
        try out.append(gpa, d);
    };
    std.mem.sortUnstable(DeviceId, out.items, {}, struct {
        fn less(_: void, a: DeviceId, b: DeviceId) bool {
            return @backingInt(a) < @backingInt(b);
        }
    }.less);
    var kept: usize = 0;
    for (out.items) |d| if (kept == 0 or out.items[kept - 1] != d) {
        out.items[kept] = d;
        kept += 1;
    };
    out.shrinkRetainingCapacity(kept);
}

/// Builds and solves one stress network.
pub fn solveStress(gpa: Allocator, design: Design, process: Process, stress: power_extract.Stress, out: *StressGrid, solution: *PowerSolution, scratch: *Scratch, diag: *PowerDiag) !void {
    try power_extract.extractStressInto(gpa, design.store, design.nets, design.devices, process, stress, out, diag);
    try solveInto(gpa, &out.grid, &scratch.solve, solution, diag);
}

// ---- private ----

fn push(r: Record, head: Head, layer: geom.LayerId, at: geom.Point, measured: Measurement, limit: Measurement, a: PolyId, b: PolyId) Allocator.Error!void {
    try r.out.push(r.gpa, .{ .rule = head.rule, .layer = layer, .severity = head.severity, .at = at, .measured = measured, .limit = limit, .shape_a = a, .shape_b = b });
}

/// Turns every clamp of a solved stress network on: a source of `held` in
/// series with each clamp's resistance, pointing the way `solution` sends
/// current through it, solved again into `solution`, whose clamp branch
/// currents are then each clamp's own. False when the solve fails or a
/// clamp would carry current backwards (beyond a billionth of `forced`).
fn turnOn(gpa: Allocator, stress: *StressGrid, solution: *PowerSolution, held: Millivolts, forced: Microamps, scratch: *Scratch) Allocator.Error!bool {
    // mV / Ω is mA: 1000 µA.
    const ua_per_mv_ohm: f64 = 1_000.0;
    const g = &stress.grid;
    const first = g.edgeCount() - @as(u32, @intCast(stress.device.items.len));
    const Shift = struct { edge: u32, sign: f64, source: f64 };
    var shift: std.ArrayList(Shift) = .empty;
    defer shift.deinit(gpa);
    for (first..g.edgeCount()) |edge| {
        const sign: f64 = if (solution.branch_current.items[edge].raw >= 0.0) 1.0 else -1.0;
        const source = ua_per_mv_ohm * held.raw / g.edge_resistance.items[edge].raw;
        const from = g.edge_from.items[edge];
        const to = g.edge_to.items[edge];
        const up, const down = if (sign > 0.0) .{ from, to } else .{ to, from };
        g.node_load.items[up].raw -= source;
        g.node_load.items[down].raw += source;
        try shift.append(gpa, .{ .edge = @intCast(edge), .sign = sign, .source = source });
    }
    var diag: PowerDiag = .{};
    solveInto(gpa, g, &scratch.solve, solution, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const floor = @abs(forced.raw) * 1e-9;
    for (shift.items) |s| {
        const along = s.sign * solution.branch_current.items[s.edge].raw - s.source;
        if (along < -floor) return false;
        solution.branch_current.items[s.edge] = .{ .raw = s.sign * @max(along, 0.0) };
    }
    return true;
}

/// Holds every clamp of a solved pair to `it2` times its size (a
/// transistor's width, any other device's perimeter), one violation per
/// clamp over it, at its marker. False, pushing nothing, when a clamp has
/// no measured size.
fn clampCapacity(r: Record, design: Design, grid: Grid, source: PolyId, stress: *const StressGrid, solution: *const PowerSolution, it2: CurrentDensity, head: Head) Allocator.Error!bool {
    const devices = design.devices;
    // Device edges come last, each clamp's pairs together.
    const first = stress.grid.edgeCount() - @as(u32, @intCast(stress.device.items.len));
    const Carried = struct { device: DeviceId, amps: f64, allowed: Microamps = .{ .raw = 0 } };
    var carried: std.ArrayList(Carried) = .empty;
    defer carried.deinit(r.gpa);
    for (stress.device.items, 0..) |d, k| {
        const amps = @abs(solution.branch_current.items[first + k].raw);
        if (carried.items.len > 0 and carried.items[carried.items.len - 1].device == d) {
            const last = &carried.items[carried.items.len - 1];
            last.amps = @max(last.amps, amps);
        } else try carried.append(r.gpa, .{ .device = d, .amps = amps });
    }
    // Every rating before anything is pushed.
    for (carried.items) |*c| {
        const size: @import("../topology/device.zig").DeviceParam = if (devices.kind.items[@backingInt(c.device)] == .mos) .width else .perimeter;
        const params = devices.paramsOf(c.device);
        const length: Dbu = for (params.names, params.measures) |name, m| {
            if (name == size and m == .length) break m.length;
        } else return false;
        // `A/m * m = A`, on base values.
        const amps: geom.Qty(.current, .base) = .{ .raw = it2.raw * grid.toLength(length).base() };
        c.allowed = amps.to(.micro);
    }
    for (carried.items) |c| {
        const measured = Measurement.current(.{ .raw = c.amps });
        const limit = Measurement.current(c.allowed);
        if (!measured.violates(limit, .maximum)) continue;
        const marker = devices.marker.items[@backingInt(c.device)];
        try push(r, head, design.store.polyLayer(marker), design.store.firstVertex(marker), measured, limit, marker, source);
    }
    return true;
}

/// Holds every wire segment and via cut of a solved pair to its pulse
/// rating: `density` times the segment's width, `per_cut` per cut. One
/// violation per segment or cut over it, at its first node.
fn interconnectCapacity(r: Record, stress: *const StressGrid, solution: *const PowerSolution, process: Process, density: ?CurrentDensity, per_cut: ?Microamps, head: Head) Allocator.Error!void {
    const g = &stress.grid;
    for (0..g.edgeCount()) |edge| {
        const kind = g.edge_kind.items[edge];
        const allowed: Microamps = switch (kind) {
            // The per-cut limit is not read for metal.
            .metal => if (density) |d| allowedCurrent(kind, g.edge_width.items[edge], process.grid, d, .{ .raw = 0.0 }, null) else continue,
            .via => per_cut orelse continue,
            .device => continue,
        };
        const measured = Measurement.current(.{ .raw = @abs(solution.branch_current.items[edge].raw) });
        const limit = Measurement.current(allowed);
        if (!measured.violates(limit, .maximum)) continue;
        const from = g.edge_from.items[edge];
        const to = g.edge_to.items[edge];
        try push(r, head, g.edge_layer.items[edge], g.node_at.items[from], measured, limit, g.node_poly.items[from], g.node_poly.items[to]);
    }
}

/// Holds every wire segment of a solved pair that carries the stress
/// current (more than a millionth of `forced`: a dead-end stub carries only
/// the solve's rounding) to `min_width`: one violation per narrower one.
fn narrowWires(r: Record, stress: *const StressGrid, solution: *const PowerSolution, forced: Microamps, min_width: Dbu, head: Head) Allocator.Error!void {
    const g = &stress.grid;
    const floor = @abs(forced.raw) * 1e-6;
    for (0..g.edgeCount()) |edge| {
        if (g.edge_kind.items[edge] != .metal or @abs(solution.branch_current.items[edge].raw) <= floor) continue;
        const measured = Measurement.length(g.edge_width.items[edge]);
        const limit = Measurement.length(min_width);
        if (!measured.violates(limit, .minimum)) continue;
        const from = g.edge_from.items[edge];
        const to = g.edge_to.items[edge];
        try push(r, head, g.edge_layer.items[edge], g.node_at.items[from], measured, limit, g.node_poly.items[from], g.node_poly.items[to]);
    }
}

fn lessNet(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}
