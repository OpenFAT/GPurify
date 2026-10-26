//! The voltage-domain kinds: device stress against model ratings
//! (`gate_oxide`, `drain_source`), well bias, missing level shifters,
//! domain crossings, gates left floating by a power state (`undriven_gate`,
//! `missing_isolation`), and the geometric ones (`voltage_spacing`,
//! `hv_tag`, `dielectric_field`, in domain_spacing.zig). In: the design, the
//! intent, the propagated voltages (and each power state's), a kind's
//! table. Out: violations and one `RuleRun` per row; every row skips
//! without usable intent. Ported from crates/check/src/erc/rules/domain.rs.
//!
//! Contents:
//! - `pub fn checkGateOxide(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void`
//! - `pub fn checkDrainSource(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void`
//! - `pub fn checkWellBias(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const WellBiasTable) Allocator.Error!void`
//! - `pub fn checkMissingLevelShifter(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const MissingLevelShifterTable) Allocator.Error!void`
//! - `pub fn checkDomainCrossing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const DomainCrossingTable) Allocator.Error!void`
//! - `pub fn checkVoltageSpacing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const VoltageSpacingTable) Allocator.Error!void`
//! - `pub fn checkHvTag(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvTagTable) Allocator.Error!void`
//! - `pub fn checkDielectricField(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, grid: Grid, t: *const DielectricFieldTable) Allocator.Error!void`
//! - `pub fn checkUndrivenGate(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const UndrivenGateTable) Allocator.Error!void`
//! - `pub fn checkMissingIsolation(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const MissingIsolationTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const StrId = geom.StrId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const NetId = @import("../topology/net.zig").NetId;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const terminalNet = head_.terminalNet;
const IntentMap = @import("facts.zig").IntentMap;
const voltage_ = @import("voltage.zig");
const NetVoltage = voltage_.NetVoltage;
const spacing = @import("domain_spacing.zig");
const tables = @import("domain_tables.zig");
const DielectricFieldTable = tables.DielectricFieldTable;
const DomainCrossingTable = tables.DomainCrossingTable;
const HvTagTable = tables.HvTagTable;
const MissingIsolationTable = tables.MissingIsolationTable;
const MissingLevelShifterTable = tables.MissingLevelShifterTable;
const ModelLimitTable = tables.ModelLimitTable;
const UndrivenGateTable = tables.UndrivenGateTable;
const VoltageSpacingTable = tables.VoltageSpacingTable;
const WellBiasTable = tables.WellBiasTable;

/// One device's stress, mV, or null for a device not examined.
const Stress = *const fn (voltage: *const NetVoltage, nets: []const NetId, roles: []const TerminalRole) ?f64;

/// Gate-oxide overstress (catalog ERC-F2): a device of the row's models
/// whose gate can differ from its source, drain or bulk by more than `max`,
/// the largest such worst-case difference whose two nets some supply
/// reaches. `examined` counts devices with at least one such pair; a
/// violation sits at the first vertex of the device's marker.
pub fn checkGateOxide(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void {
    try modelLimit(r, design, intent, voltage, t, gateStress);
}

/// Junction and channel overstress (ERC-F3): a device whose drain can
/// differ from its source by more than `max`. Reports as `checkGateOxide`.
pub fn checkDrainSource(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable) Allocator.Error!void {
    try modelLimit(r, design, intent, voltage, t, drainSourceStress);
}

/// A PMOS whose source or drain can rise above its bulk, or an NMOS whose
/// can fall below it: the excess in mV against 0 V. `examined` counts
/// devices of the row's models whose bulk and a channel end some supply
/// reaches.
pub fn checkWellBias(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const WellBiasTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const devices = design.devices;
    const limit = Measurement.voltage(.{ .raw = 0.0 });
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const pmos = span(t.pmos.items, t.pmos_start.items, row);
        const nmos = span(t.nmos.items, t.nmos_start.items, row);
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            const model = devices.model.items[d];
            const high = has(pmos, model);
            if (!high and !has(nmos, model)) continue;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const bulk = terminalNet(term.nets, term.roles, .bulk);
            var extreme: ?f64 = null;
            for ([_]TerminalRole{ .source, .drain }) |role| {
                const net = terminalNet(term.nets, term.roles, role);
                if (!voltage.known(net)) continue;
                const v = if (high) voltage.hi.items[@backingInt(net)] else voltage.lo.items[@backingInt(net)];
                extreme = if (extreme) |e| (if (high) @max(e, v) else @min(e, v)) else v;
            }
            const e = extreme orelse continue;
            if (!voltage.known(bulk)) continue;
            const b = @backingInt(bulk);
            const excess = if (high) e - voltage.lo.items[b] else voltage.hi.items[b] - e;
            examined += 1;
            const measured = Measurement.voltage(.{ .raw = excess });
            if (measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// A transistor, not of a shifter model, whose gate a power domain reaches
/// that reaches neither channel end: the count of such domains against 0.
/// `examined` counts transistors whose gate and channel some power reaches.
pub fn checkMissingLevelShifter(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const MissingLevelShifterTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const devices = design.devices;
    const limit = Measurement.count(0);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const shifters = span(t.shifter.items, t.shifter_start.items, row);
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            if (devices.kind.items[d] != .mos or has(shifters, devices.model.items[d])) continue;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const gate = voltage.powerOf(terminalNet(term.nets, term.roles, .gate));
            const channel = voltage.powerOf(terminalNet(term.nets, term.roles, .source)) | voltage.powerOf(terminalNet(term.nets, term.roles, .drain));
            if (gate == 0 or channel == 0) continue;
            examined += 1;
            const measured = Measurement.count(@popCount(gate & ~channel));
            if (measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// A device whose channel more than one power domain reaches: the count of
/// domains against 1. `examined` counts devices whose channel some power
/// reaches.
pub fn checkDomainCrossing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const DomainCrossingTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const devices = design.devices;
    const limit = Measurement.count(1);
    for (t.head.rule.items, t.head.severity.items) |rule, severity| {
        const before = r.out.len();
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const kind = devices.kind.items[d];
            var mask: u64 = 0;
            for (term.nets, term.roles) |net, role| if (voltage_.isChannel(kind, role)) {
                mask |= voltage.powerOf(net);
            };
            if (mask == 0) continue;
            examined += 1;
            const measured = Measurement.count(@popCount(mask));
            if (measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Shapes on two nets closer than the voltage table's step for the largest
/// voltage the two can reach apart. See domain_spacing.zig.
pub fn checkVoltageSpacing(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const VoltageSpacingTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try spacing.voltageSpacing(r, design, voltage, t);
}

/// A high-voltage figure not covered by its tag layer. See
/// domain_spacing.zig.
pub fn checkHvTag(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvTagTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try spacing.hvTag(r, design, voltage, t);
}

/// Shapes on two nets closer laterally than the field limit allows. See
/// domain_spacing.zig.
pub fn checkDielectricField(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, grid: Grid, t: *const DielectricFieldTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    try spacing.dielectricField(r, design, voltage, grid, t);
}

/// A gate net some supply reaches with every supply on that floats (no
/// supply reaches it) in a declared power state: the count of such states
/// against 0, at its lowest polygon. `examined` counts the reached gate
/// nets. Skips also when the intent declares no power state.
pub fn checkUndrivenGate(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const UndrivenGateTable) Allocator.Error!void {
    if (!intent.isUsable() or states.len == 0) return r.skipRows(&t.head);
    var gates: std.ArrayList(NetId) = .empty;
    defer gates.deinit(r.gpa);
    try gateNetsInto(r.gpa, design, &gates);
    var kept: usize = 0;
    for (gates.items) |net| if (voltage.known(net)) {
        gates.items[kept] = net;
        kept += 1;
    };
    gates.shrinkRetainingCapacity(kept);
    std.mem.sortUnstable(NetId, gates.items, {}, lessNet);
    gates.shrinkRetainingCapacity(dedupNets(gates.items));
    for (t.head.rule.items, t.head.severity.items) |rule, severity| {
        const before = r.out.len();
        for (gates.items) |net| {
            var off: u32 = 0;
            for (states) |*s| off += @intFromBool(!s.known(net));
            if (off == 0) continue;
            try r.netViolations(design, &.{@backingInt(net)}, rule, severity, .count(off), .count(0));
        }
        try r.run(rule, before, .ran, gates.items.len);
    }
}

/// A transistor, not of an isolation model, whose gate floats in a power
/// state while its channel is powered: the count of such states against 0.
/// `examined` counts the transistors whose gate some supply reaches with
/// every supply on. Skips also when the intent declares no power state.
pub fn checkMissingIsolation(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, states: []const NetVoltage, t: *const MissingIsolationTable) Allocator.Error!void {
    if (!intent.isUsable() or states.len == 0) return r.skipRows(&t.head);
    const devices = design.devices;
    var gates: std.ArrayList(NetId) = .empty;
    defer gates.deinit(r.gpa);
    try gateNetsInto(r.gpa, design, &gates);
    const limit = Measurement.count(0);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const exempt = span(t.isolation.items, t.isolation_start.items, row);
        var examined: u64 = 0;
        for (gates.items, 0..) |gate, d| {
            if (!voltage.known(gate) or has(exempt, devices.model.items[d])) continue;
            examined += 1;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const channel = [2]NetId{ terminalNet(term.nets, term.roles, .source), terminalNet(term.nets, term.roles, .drain) };
            var leaking: u32 = 0;
            for (states) |*s| leaking += @intFromBool(!s.known(gate) and (s.powerOf(channel[0]) != 0 or s.powerOf(channel[1]) != 0));
            const measured = Measurement.count(leaking);
            if (measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

/// Every device of the row's models measured by `measure`; one above the
/// row's `max_voltage` is flagged.
fn modelLimit(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ModelLimitTable, measure: Stress) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const devices = design.devices;
    for (t.head.rule.items, t.head.severity.items, t.max_voltage.items, 0..) |rule, severity, max, row| {
        const before = r.out.len();
        const limit = Measurement.voltage(max);
        const models = span(t.model.items, t.model_start.items, row);
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            if (!has(models, devices.model.items[d])) continue;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const delta = measure(voltage, term.nets, term.roles) orelse continue;
            examined += 1;
            const measured = Measurement.voltage(.{ .raw = delta });
            if (measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// The largest gate-to-source, -drain or -bulk voltage a device can see.
fn gateStress(voltage: *const NetVoltage, nets: []const NetId, roles: []const TerminalRole) ?f64 {
    const gate = terminalNet(nets, roles, .gate);
    var best: ?f64 = null;
    for ([_]TerminalRole{ .source, .drain, .bulk }) |role| {
        const d = voltage.worstDelta(gate, terminalNet(nets, roles, role)) orelse continue;
        best = if (best) |b| @max(b, d) else d;
    }
    return best;
}

/// The largest drain-to-source voltage a device can see.
fn drainSourceStress(voltage: *const NetVoltage, nets: []const NetId, roles: []const TerminalRole) ?f64 {
    return voltage.worstDelta(terminalNet(nets, roles, .source), terminalNet(nets, roles, .drain));
}

/// The gate net of every device, `.none` for a non-MOS or a gate on no net.
fn gateNetsInto(gpa: Allocator, design: Design, out: *std.ArrayList(NetId)) Allocator.Error!void {
    const devices = design.devices;
    out.clearRetainingCapacity();
    for (0..devices.len()) |d| {
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        try out.append(gpa, if (devices.kind.items[d] == .mos) terminalNet(term.nets, term.roles, .gate) else .none);
    }
}

/// Row `row` of a CSR column; an empty column (no rows) answers empty.
fn span(column: []const StrId, start: []const u32, row: usize) []const StrId {
    if (row + 1 >= start.len) return &.{};
    return column[start[row]..start[row + 1]];
}

fn has(models: []const StrId, model: StrId) bool {
    return std.mem.indexOfScalar(StrId, models, model) != null;
}

fn lessNet(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn dedupNets(items: []NetId) usize {
    var kept: usize = 0;
    for (items) |n| if (kept == 0 or items[kept - 1] != n) {
        items[kept] = n;
        kept += 1;
    };
    return kept;
}
