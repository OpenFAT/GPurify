//! Ground domains coupled for ESD (`esd_ground_coupling`: anti-parallel
//! diode pairs join declared grounds, ESDA TR18.0-01 Fig. 5) and signals
//! crossing power domains (`esd_cross_domain`: the receiver's grounds
//! coupled, check 5.1.3; its local clamp, Khazhinsky 2012; its series
//! resistor, US12021077B2; the driver/receiver ground resistance,
//! Etherton), with the series resistance a resistor network puts between
//! source nets and a region. In: the design, the intent, the propagated
//! voltages, the process, the table. Out: violations and one `RuleRun` per
//! row. Ported from crates/check/src/erc/rules/esd.rs (`coupling_groups`,
//! `check_esd_ground_coupling`, `check_esd_cross_domain`,
//! `series_resistance`).
//!
//! Contents:
//! - `pub fn couplingGroupsInto(gpa: Allocator, design: Design, intent: *const IntentMap, diodes: []const StrId, labels: *std.ArrayList(u32)) Allocator.Error!void`
//! - `pub fn esdGroundCoupling(r: Record, design: Design, intent: *const IntentMap, t: *const EsdGroundCouplingTable) Allocator.Error!void`
//! - `pub fn esdCrossDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, process: Process, t: *const EsdCrossDomainTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn seriesResistanceInto(gpa: Allocator, design: Design, sources: []const NetId, region: []const bool, resistors: []const StrId, out: *std.ArrayList(f64)) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Outcome = report.Outcome;
const Microamps = report.Microamps;
const NetId = @import("../topology/net.zig").NetId;
const device_ = @import("../topology/device.zig");
const DeviceId = device_.DeviceId;
const TerminalRole = device_.TerminalRole;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const terminalNet = head_.terminalNet;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const grid_ = @import("power_grid.zig");
const Process = grid_.Process;
const PowerSolution = grid_.PowerSolution;
const PowerDiag = grid_.PowerDiag;
const power_extract = @import("power_extract.zig");
const StressGrid = power_extract.StressGrid;
const solveInto = @import("power_solve.zig").solveInto;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("esd_tables.zig");
const EsdGroundCouplingTable = tables.EsdGroundCouplingTable;
const EsdCrossDomainTable = tables.EsdCrossDomainTable;

/// Each declared supply row's coupling group, into `labels` (one per
/// supply row): ground rows joined by anti-parallel pairs of `diodes`
/// models (and chains of them) share a label; every other row is alone.
pub fn couplingGroupsInto(gpa: Allocator, design: Design, intent: *const IntentMap, diodes: []const StrId, labels: *std.ArrayList(u32)) Allocator.Error!void {
    const devices = design.devices;
    // Every diode between two ground rows, as `(anode row, cathode row)`.
    var directed: std.ArrayList([2]u32) = .empty;
    defer directed.deinit(gpa);
    for (0..devices.len()) |d| {
        if (devices.kind.items[d] != .diode or !has(diodes, devices.model.items[d])) continue;
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        const anode = groundRow(intent, pinNet(term.nets, term.roles, 0)) orelse continue;
        const cathode = groundRow(intent, pinNet(term.nets, term.roles, 1)) orelse continue;
        if (anode != cathode) try directed.append(gpa, .{ anode, cathode });
    }
    std.mem.sortUnstable([2]u32, directed.items, {}, lessPair);
    var kept: usize = 0;
    for (directed.items) |p| if (kept == 0 or !std.mem.eql(u32, &directed.items[kept - 1], &p)) {
        directed.items[kept] = p;
        kept += 1;
    };
    directed.shrinkRetainingCapacity(kept);
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    for (directed.items) |p| {
        const back = [2]u32{ p[1], p[0] };
        const found = for (directed.items) |q| {
            if (std.mem.eql(u32, &q, &back)) break true;
        } else false;
        if (found) try pairs.append(gpa, p);
    }
    try geom.connectivity.componentsInto(gpa, @intCast(intent.supply_net.items.len), pairs.items, labels);
}

/// Every row over the declared grounds: each coupling group but the one
/// holding the lowest ground, flagged at its lowest ground's lowest
/// polygon, the anti-parallel paths 0 against 1. `examined` counts the
/// declared grounds. The caller checks the intent.
pub fn esdGroundCoupling(r: Record, design: Design, intent: *const IntentMap, t: *const EsdGroundCouplingTable) Allocator.Error!void {
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(r.gpa);
    var groups: std.ArrayList(u32) = .empty;
    defer groups.deinit(r.gpa);
    var flagged: std.ArrayList(u32) = .empty;
    defer flagged.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        try couplingGroupsInto(r.gpa, design, intent, t.diode.items[t.diode_start.items[row]..t.diode_start.items[row + 1]], &labels);
        groups.clearRetainingCapacity();
        flagged.clearRetainingCapacity();
        var grounds: u64 = 0;
        // Rows ascend by net, so a group's first row is its lowest ground.
        for (intent.supply_role.items, 0..) |role, s| {
            if (role != .ground) continue;
            grounds += 1;
            if (std.mem.indexOfScalar(u32, groups.items, labels.items[s]) != null) continue;
            if (groups.items.len > 0) try flagged.append(r.gpa, @backingInt(intent.supply_net.items[s]));
            try groups.append(r.gpa, labels.items[s]);
        }
        try r.netViolations(design, flagged.items, rule, severity, .count(0), .count(1));
        try r.run(rule, before, .ran, grounds);
    }
}

/// Every row over every transistor whose gate a power domain reaches that
/// reaches neither channel end (a receiver). `examined` counts receivers
/// whose gate and channel some ground reaches; each may be flagged for
/// uncoupled grounds, a missing local clamp, too little series resistance
/// and each driver whose ground path is too resistive. The caller checks
/// the intent.
pub fn esdCrossDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, process: Process, t: *const EsdCrossDomainTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const devices = design.devices;
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var coupling: std.ArrayList(DeviceId) = .empty;
    defer coupling.deinit(gpa);
    var region: std.ArrayList(bool) = .empty;
    defer region.deinit(gpa);
    var walk: std.ArrayList(NetId) = .empty;
    defer walk.deinit(gpa);
    var driving: std.ArrayList(NetId) = .empty;
    defer driving.deinit(gpa);
    const Driver = struct { device: u32, ground: NetId };
    var drivers: std.ArrayList(Driver) = .empty;
    defer drivers.deinit(gpa);
    var series: std.ArrayList(f64) = .empty;
    defer series.deinit(gpa);
    var stress: StressGrid = .{};
    defer stress.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    var diag: PowerDiag = .{};
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        var outcome: Outcome = .ran;
        const diodes = t.diode.items[t.diode_start.items[row]..t.diode_start.items[row + 1]];
        const local = t.local.items[t.local_start.items[row]..t.local_start.items[row + 1]];
        const resistors = t.resistor.items[t.resistor_start.items[row]..t.resistor_start.items[row + 1]];
        coupling.clearRetainingCapacity();
        for (0..devices.len()) |d| if (has(diodes, devices.model.items[d])) try coupling.append(gpa, @fromBackingInt(@as(u32, @intCast(d))));
        try couplingGroupsInto(gpa, design, intent, diodes, &labels);
        var examined: u64 = 0;
        devices: for (0..devices.len()) |index| {
            if (devices.kind.items[index] != .mos) continue;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(index))));
            const gate = terminalNet(term.nets, term.roles, .gate);
            const ends = [2]NetId{ terminalNet(term.nets, term.roles, .source), terminalNet(term.nets, term.roles, .drain) };
            const gate_power = voltage.powerOf(gate);
            const channel_power = voltage.powerOf(ends[0]) | voltage.powerOf(ends[1]);
            if (gate_power == 0 or channel_power == 0 or gate_power & ~channel_power == 0) continue;
            const driver = voltage.groundOf(gate);
            const receiver = voltage.groundOf(ends[0]) | voltage.groundOf(ends[1]);
            if (driver == 0 or receiver == 0) continue;
            examined += 1;
            const flag_count: [2]Measurement = .{ .count(0), .count(1) };
            if (!protected(intent, labels.items, driver, receiver)) try r.deviceViolation(design, @intCast(index), rule, severity, flag_count[0], flag_count[1]);
            // A local clamp: a `local` device on the gate's net with a
            // terminal on a ground of the receiver's own domain.
            const clamped = local.len == 0 or for (devices.devicesOn(gate)) |d| {
                if (!has(local, devices.model.items[@backingInt(d)])) continue;
                const own = for (devices.terminalsOf(d).nets) |n| {
                    if (ownGround(intent, receiver, n)) break true;
                } else false;
                if (own) break true;
            } else false;
            if (!clamped) try r.deviceViolation(design, @intCast(index), rule, severity, flag_count[0], flag_count[1]);
            if (t.min_series.items[row] == null and t.max_ground_resistance.items[row] == null) continue;
            // The receiver's input: its gate's net and every net the series
            // resistors join to it, never a supply.
            region.clearRetainingCapacity();
            try region.appendNTimes(gpa, false, design.nets.netCount());
            walk.clearRetainingCapacity();
            try walk.append(gpa, gate);
            region.items[@backingInt(gate)] = true;
            while (walk.pop()) |net| for (devices.devicesOn(net)) |d| {
                const di = @backingInt(d);
                if (devices.kind.items[di] != .resistor or !has(resistors, devices.model.items[di])) continue;
                for (devices.terminalsOf(d).nets) |next| {
                    if (next == .none or region.items[@backingInt(next)] or intent.supply(next) != null) continue;
                    region.items[@backingInt(next)] = true;
                    try walk.append(gpa, next);
                }
            };
            // Its drivers: a channel end on an input net.
            driving.clearRetainingCapacity();
            drivers.clearRetainingCapacity();
            for (0..devices.len()) |other| {
                if (other == index or devices.kind.items[other] != .mos) continue;
                const ot = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(other))));
                const oe = [2]NetId{ terminalNet(ot.nets, ot.roles, .source), terminalNet(ot.nets, ot.roles, .drain) };
                for (oe, 0..) |end, k| {
                    if (end == .none or !region.items[@backingInt(end)]) continue;
                    try driving.append(gpa, end);
                    if (isGround(intent, oe[1 - k])) try drivers.append(gpa, .{ .device = @intCast(other), .ground = oe[1 - k] });
                }
            }
            std.mem.sortUnstable(NetId, driving.items, {}, lessNet);
            driving.shrinkRetainingCapacity(dedupNets(driving.items));
            if (t.min_series.items[row]) |min| if (driving.items.len > 0) {
                if (!try seriesResistanceInto(gpa, design, driving.items, region.items, resistors, &series)) {
                    outcome = .refused;
                    break :devices;
                }
                const measured = Measurement.resistance(.{ .raw = series.items[@backingInt(gate)] });
                const limit = Measurement.resistance(min);
                if (measured.violates(limit, .minimum)) try r.deviceViolation(design, @intCast(index), rule, severity, measured, limit);
            };
            const max = t.max_ground_resistance.items[row] orelse continue;
            const coupling_ohms = t.coupling_resistance.items[row] orelse continue;
            const own = for (ends) |n| {
                if (isGround(intent, n)) break n;
            } else continue;
            const receiver_marker = devices.marker.items[index];
            // A unit current: the resistance is the rise over it.
            const unit: Microamps = .{ .raw = 1e6 };
            for (drivers.items) |dv| {
                var path_buf = [2]NetId{ dv.ground, own };
                std.mem.sortUnstable(NetId, &path_buf, {}, lessNet);
                const path: []const NetId = if (path_buf[0] == path_buf[1]) path_buf[0..1] else &path_buf;
                const pins = [1]PolyId{receiver_marker};
                power_extract.extractStressInto(gpa, design.store, design.nets, devices, process, .{
                    .nets = path,
                    .source = devices.marker.items[dv.device],
                    .source_net = dv.ground,
                    .current = unit,
                    .sink = own,
                    .pins = &pins,
                    .devices = coupling.items,
                    .device_resistance = coupling_ohms,
                }, &stress, &diag) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        outcome = .refused;
                        break :devices;
                    },
                };
                // Grounds no coupling joins: 5.1.3's finding, not this one.
                solveInto(gpa, &stress.grid, &scratch.solve, &solution, &diag) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                const measured = Measurement.resistance(.{ .raw = solution.node_voltage.items[stress.entry].raw * 1000.0 / unit.raw });
                const limit = Measurement.resistance(max);
                if (!measured.violates(limit, .maximum)) continue;
                try r.out.push(gpa, .{ .rule = rule, .layer = design.store.polyLayer(receiver_marker), .severity = severity, .at = design.store.firstVertex(receiver_marker), .measured = measured, .limit = limit, .shape_a = receiver_marker, .shape_b = devices.marker.items[dv.device] });
            }
        }
        try r.run(rule, before, outcome, examined);
    }
}

/// The effective resistance from the `sources` nets (ascending), joined as
/// one node, to every net of `region` through the resistor devices of the
/// `resistors` models with both ends in it, Ω, into `out` (one per net): 0
/// on a source net and off the region. False when such a resistor states
/// no value (`sheet`, or a measured width or length) or the network is
/// singular. Dense Gauss-Jordan: a region is a pad's input stages or one
/// receiver's input.
pub fn seriesResistanceInto(gpa: Allocator, design: Design, sources: []const NetId, region: []const bool, resistors: []const StrId, out: *std.ArrayList(f64)) Allocator.Error!bool {
    const nets = design.nets;
    const devices = design.devices;
    const net_count = nets.netCount();
    // Node 0 is the sources; then every region net that is not one.
    const node = try gpa.alloc(usize, net_count);
    defer gpa.free(node);
    @memset(node, std.math.maxInt(usize));
    var count: usize = 1;
    for (0..net_count) |n| if (region[n]) {
        const id: NetId = @fromBackingInt(@as(u32, @intCast(n)));
        if (std.sort.binarySearch(NetId, sources, id, orderNet) != null) {
            node[n] = 0;
        } else {
            node[n] = count;
            count += 1;
        }
    };
    const lap = try gpa.alloc(f64, count * count);
    defer gpa.free(lap);
    @memset(lap, 0.0);
    for (0..devices.len()) |d| {
        if (devices.kind.items[d] != .resistor or !has(resistors, devices.model.items[d])) continue;
        const id: DeviceId = @fromBackingInt(@as(u32, @intCast(d)));
        var ends: [3]usize = undefined;
        var n_ends: usize = 0;
        for (devices.terminalsOf(id).nets) |net| {
            if (net == .none or !region[@backingInt(net)]) continue;
            if (n_ends < ends.len) ends[n_ends] = node[@backingInt(net)];
            n_ends += 1;
        }
        if (n_ends != 2) continue;
        const a = ends[0];
        const b = ends[1];
        if (a == b) continue;
        const sheet = (if (d < devices.value.items.len) devices.value.items[d].sheet_ohm_sq else null) orelse return false;
        const length = lengthOf(design, id, .length) orelse return false;
        const width = lengthOf(design, id, .width) orelse return false;
        const ohms = sheet * length / width;
        if (!(ohms > 0.0)) return false;
        const g = 1.0 / ohms;
        lap[a * count + a] += g;
        lap[b * count + b] += g;
        lap[a * count + b] -= g;
        lap[b * count + a] -= g;
    }
    // Ground the sources and invert the rest by Gauss-Jordan elimination,
    // partial pivoting, on the augmented `[A | I]`.
    const n = count - 1;
    const width = 2 * n;
    const m = try gpa.alloc(f64, n * width);
    defer gpa.free(m);
    for (0..n) |row| for (0..width) |col| {
        m[row * width + col] = if (col < n) lap[(row + 1) * count + col + 1] else @floatFromInt(@intFromBool(col - n == row));
    };
    const scratch_row = try gpa.alloc(f64, width);
    defer gpa.free(scratch_row);
    for (0..n) |col| {
        // The largest magnitude, the last on a tie (as Rust's `max_by`).
        var pivot = col;
        for (col..n) |row| if (@abs(m[row * width + col]) >= @abs(m[pivot * width + col])) {
            pivot = row;
        };
        if (@abs(m[pivot * width + col]) < std.math.floatMin(f64)) return false;
        if (pivot != col) {
            @memcpy(scratch_row, m[col * width ..][0..width]);
            @memcpy(m[col * width ..][0..width], m[pivot * width ..][0..width]);
            @memcpy(m[pivot * width ..][0..width], scratch_row);
        }
        const scale = m[col * width + col];
        for (m[col * width ..][0..width]) |*v| v.* /= scale;
        for (0..n) |row| {
            if (row == col) continue;
            const factor = m[row * width + col];
            if (factor == 0.0) continue;
            for (0..width) |c| m[row * width + c] -= factor * m[col * width + c];
        }
    }
    out.clearRetainingCapacity();
    for (node) |k| try out.append(gpa, if (k == std.math.maxInt(usize) or k == 0) 0.0 else m[(k - 1) * width + n + k - 1]);
    return true;
}

// ---- private ----

/// Every ground domain reaching the gate coupled to every one reaching the
/// channel: equal, or a ground row of each in one coupling group.
fn protected(intent: *const IntentMap, labels: []const u32, driver: u64, receiver: u64) bool {
    for (0..64) |a| {
        if ((driver >> @intCast(a)) & 1 == 0) continue;
        for (0..64) |b| {
            if ((receiver >> @intCast(b)) & 1 == 0) continue;
            if (!coupled(intent, labels, @intCast(a), @intCast(b))) return false;
        }
    }
    return true;
}

fn coupled(intent: *const IntentMap, labels: []const u32, a: u32, b: u32) bool {
    if (a == b) return true;
    for (intent.supply_role.items, intent.supply_domain.items, 0..) |ra_role, ra_dom, ra| {
        if (ra_role != .ground or @backingInt(ra_dom) != a) continue;
        for (intent.supply_role.items, intent.supply_domain.items, 0..) |rb_role, rb_dom, rb| {
            if (rb_role == .ground and @backingInt(rb_dom) == b and labels[ra] == labels[rb]) return true;
        }
    }
    return false;
}

/// A ground of the receiver's own domains: a local clamp's far end.
fn ownGround(intent: *const IntentMap, receiver: u64, net: NetId) bool {
    const row = supplyRow(intent, net) orelse return false;
    return intent.supply_role.items[row] == .ground and (receiver >> @intCast(@backingInt(intent.supply_domain.items[row]))) & 1 == 1;
}

fn isGround(intent: *const IntentMap, net: NetId) bool {
    return if (intent.supply(net)) |s| s.role == .ground else false;
}

fn supplyRow(intent: *const IntentMap, net: NetId) ?usize {
    return std.sort.binarySearch(NetId, intent.supply_net.items, net, orderNet);
}

/// The supply row of a declared ground on `net`.
fn groundRow(intent: *const IntentMap, net: ?NetId) ?u32 {
    const row = supplyRow(intent, net orelse return null) orelse return null;
    return if (intent.supply_role.items[row] == .ground) @intCast(row) else null;
}

/// The net on pin `k`, or null without one.
fn pinNet(nets: []const NetId, roles: []const TerminalRole, k: u8) ?NetId {
    for (nets, roles) |net, role| switch (role) {
        .pin => |p| if (p == k) return net,
        else => {},
    };
    return null;
}

/// A device's measured length parameter `want`, as f64.
fn lengthOf(design: Design, device: DeviceId, want: device_.DeviceParam) ?f64 {
    const p = design.devices.paramsOf(device);
    for (p.names, p.measures) |name, m| if (name == want and m == .length) return @floatFromInt(m.length);
    return null;
}

fn has(models: []const StrId, model: StrId) bool {
    return std.mem.indexOfScalar(StrId, models, model) != null;
}

fn orderNet(a: NetId, b: NetId) std.math.Order {
    return std.math.order(@backingInt(a), @backingInt(b));
}

fn lessNet(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

fn dedupNets(items: []NetId) usize {
    var kept: usize = 0;
    for (items) |n| if (kept == 0 or items[kept - 1] != n) {
        items[kept] = n;
        kept += 1;
    };
    return kept;
}
