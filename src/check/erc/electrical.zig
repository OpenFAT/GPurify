//! The electrical kinds: rules over a solved resistive network. In: the
//! per-net networks (`p2p_resistance`, which needs no intent) and the
//! solved supply grid with the intent's limits (the rest, skipped without
//! usable intent). Out: violations and exactly one run per row. A kind is
//! refused when its network could not be built or solved, or when a stated
//! current budget never reached the solve (zero current passes every
//! limit). Ported from crates/check/src/erc/rules/electrical.rs (the
//! `check_*` functions, `solved_or_fill`, `report_node`, `worst_cycle`);
//! the branch-current rows are electrical_current.zig, `em_thermal`'s
//! electrical_thermal.zig.
//!
//! Contents:
//! - `pub fn checkP2pResistance(r: Record, design: Design, networks: ?*const NetNetworks, t: *const P2pResistanceTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const IrDropTable) Allocator.Error!void`
//! - `pub fn checkEmCurrentDensity(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmCurrentDensityTable) Allocator.Error!void`
//! - `pub fn checkEmAc(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmAcTable) Allocator.Error!void`
//! - `pub fn checkElectromigration(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const ElectromigrationTable) Allocator.Error!void`
//! - `pub fn checkDynamicIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const DynamicIrDropTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkEmThermal(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const EmThermalTable, height_nm: []const f64) Allocator.Error!void`
//! - `Unit.of`, `Black.of`: the deratings (pub for electrical_current.zig's generic call)

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Millivolts = report.Millivolts;
const head_ = @import("head.zig");
const Record = head_.Record;
const RuleHead = head_.RuleHead;
const Design = head_.Design;
const IntentMap = @import("facts.zig").IntentMap;
const grid_ = @import("power_grid.zig");
const NetNetworks = grid_.NetNetworks;
const PowerGrid = grid_.PowerGrid;
const Power = grid_.Power;
const Solved = grid_.Solved;
const Scratch = @import("scratch.zig").Scratch;
const discardedBudget = @import("power_extract.zig").discardedBudget;
const probe = @import("power_probe.zig");
const transient = @import("power_transient.zig");
const tables = @import("electrical_tables.zig");
const Kelvin = tables.Kelvin;
const DynamicIrDropTable = tables.DynamicIrDropTable;
const ElectromigrationTable = tables.ElectromigrationTable;
const EmAcTable = tables.EmAcTable;
const EmCurrentDensityTable = tables.EmCurrentDensityTable;
const EmThermalTable = tables.EmThermalTable;
const IrDropTable = tables.IrDropTable;
const P2pResistanceTable = tables.P2pResistanceTable;
const current = @import("electrical_current.zig");
const Head = current.Head;
const thermal = @import("electrical_thermal.zig");

/// No derating.
const Unit = struct {
    pub fn of(_: Unit, _: u32) ?f64 {
        return 1.0;
    }
};

/// Black's derating of an `electromigration` row.
const Black = struct {
    t: *const ElectromigrationTable,
    operating: Kelvin,

    pub fn of(b: Black, row: u32) ?f64 {
        return current.arrheniusDerating(b.operating, b.t.reference_temperature.items[row], b.t.activation_energy_ev.items[row], b.t.current_exponent.items[row]);
    }
};

/// Every row over the per-net networks. `examined` counts networks probed;
/// a violation sits at the first attach point of the worst pair (the
/// earliest on a tie), names both shapes, and measures its resistance.
/// Every row refuses when the networks could not be built, and a row at
/// the first network that cannot be probed (its findings before that kept).
/// ponytail: rows probe serially; each network row is independent, so a
/// thread pool writing per-row probe lists is the upgrade if p2p dominates.
pub fn checkP2pResistance(r: Record, design: Design, networks: ?*const NetNetworks, t: *const P2pResistanceTable, scratch: *Scratch) Allocator.Error!void {
    const nets = networks orelse return r.fillRows(&t.head, .refused);
    var diag: grid_.PowerDiag = .{};
    for (t.head.rule.items, t.head.severity.items, t.max_resistance.items) |id, severity, max| {
        const before = r.out.len();
        const limit = Measurement.resistance(max);
        var examined: u64 = 0;
        var outcome: report.Outcome = .ran;
        for (0..nets.len()) |row| {
            probe.effectiveResistanceInto(r.gpa, nets, @intCast(row), &scratch.probe, &scratch.probes, &diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    outcome = .refused;
                    break;
                },
            };
            examined += 1;
            // A pair split across components is absent from the probe list.
            const probes = scratch.probes.items;
            if (probes.len == 0) continue;
            // Left fold in probe order: the earliest wins a tie.
            var worst = probes[0];
            for (probes[1..]) |p| if (p.ohms.raw > worst.ohms.raw) {
                worst = p;
            };
            const measured = Measurement.resistance(worst.ohms);
            if (!measured.violates(limit, .maximum)) continue;
            const polys = nets.nodesOf(@intCast(row));
            const points = nets.atOf(@intCast(row));
            try r.out.push(r.gpa, .{
                .rule = id,
                .layer = design.store.polyLayer(polys[worst.a]),
                .severity = severity,
                .at = points[worst.a],
                .measured = measured,
                .limit = limit,
                .shape_a = polys[worst.a],
                .shape_b = polys[worst.b],
            });
        }
        try r.run(id, before, outcome, examined);
    }
}

/// Every row over the solved supply grid. `examined` counts nodes whose
/// net states a drop, fractional drop or overvoltage limit; a violation sits
/// at the node and measures the drop (or overvoltage) against the broken
/// limit, a node possibly breaking several.
pub fn checkIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const IrDropTable) Allocator.Error!void {
    const solved = try solvedOrFill(r, power, intent, &t.head) orelse return;
    const g = solved.grid;
    for (t.head.rule.items, t.head.severity.items) |id, severity| {
        const before = r.out.len();
        const head: Head = .{ .rule = id, .severity = severity };
        var examined: u64 = 0;
        for (0..g.nodeCount()) |node| {
            const net = g.node_net.items[node];
            const limits = intent.limitsOf(net);
            examined += @intFromBool(limits.max_drop != null or limits.max_drop_fraction != null or limits.max_overvoltage != null);
            // Every grid node is on a declared supply.
            const supply = intent.supply(net).?;
            // A loss moves toward the other rail: down for power, up for ground.
            const drop = signedDrop(supply.role, solved.solution.node_drop.items[node]);
            if (limits.max_drop) |limit| try reportNode(r, g, @intCast(node), head, drop, limit);
            // A fraction of the domain, for a ground rail as for its power rail.
            if (limits.max_drop_fraction) |fraction| try reportNode(r, g, @intCast(node), head, drop, .{ .raw = @abs(supply.nominal.raw) * fraction });
            // Overvoltage is a negative drop.
            if (limits.max_overvoltage) |limit| try reportNode(r, g, @intCast(node), head, drop.neg(), limit);
        }
        try r.run(id, before, .ran, examined);
    }
}

/// Every row over the grid's branch currents: a segment or cut on a listed
/// layer against its allowed current, no derating.
pub fn checkEmCurrentDensity(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmCurrentDensityTable) Allocator.Error!void {
    const solved = try solvedOrFill(r, power, intent, &t.head) orelse return;
    try current.currentRows(r, solved, grid, &t.head, t.layer_start.items, .{
        .layer = t.layer.items,
        .max_density = t.max_density.items,
        .max_current_per_cut = t.max_current_per_cut.items,
        .narrow = t.narrow.items,
    }, Unit{});
}

/// Every `em_rms` or `em_peak` row over the grid loaded with those
/// currents (`power`, and `intent` its loads and frequencies).
pub fn checkEmAc(r: Record, power: Power, intent: *const IntentMap, grid: Grid, t: *const EmAcTable) Allocator.Error!void {
    const solved = try solvedOrFill(r, power, intent, &t.head) orelse return;
    try current.emAcRows(r, solved, intent, grid, t);
}

/// Every row over the grid's branch currents, each limit derated by
/// Black's equation to `temperature`; Blech-immortal lines exempt. A row
/// refuses when its derating is unusable.
pub fn checkElectromigration(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const ElectromigrationTable) Allocator.Error!void {
    // ponytail: one temperature for the whole run, no self-heating, which
    // errs open for a hot wire; upgrade is a per-edge temperature column.
    const solved = try solvedOrFill(r, power, intent, &t.head) orelse return;
    try current.currentRows(r, solved, grid, &t.head, t.layer_start.items, .{
        .layer = t.layer.items,
        .max_density = t.max_density.items,
        .max_current_per_cut = t.max_current_per_cut.items,
        .blech = t.blech_limit.items,
    }, Black{ .t = t, .operating = temperature });
}

/// Every row over the grid's static drop plus its response to the worst
/// cycle. `examined` counts nodes whose net states `dynamic`; a violation
/// measures the drop, static plus dynamic, against `max_drop_mv`. The
/// response is simulated once; every row refuses when that fails.
pub fn checkDynamicIrDrop(r: Record, power: Power, intent: *const IntentMap, t: *const DynamicIrDropTable, scratch: *Scratch) Allocator.Error!void {
    if (t.head.len() == 0) return;
    const solved = try solvedOrFill(r, power, intent, &t.head) orelse return;
    const g = solved.grid;
    const gpa = r.gpa;
    var stimulus: transient.Stimulus = .{};
    defer stimulus.deinit(gpa);
    try worstCycle(gpa, g, intent, &stimulus);
    var response: std.ArrayList(Millivolts) = .empty;
    defer response.deinit(gpa);
    var diag: grid_.PowerDiag = .{};
    transient.transientInto(gpa, g, &stimulus, &scratch.solve, &response, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return r.fillRows(&t.head, .refused),
    };
    for (t.head.rule.items, t.head.severity.items) |id, severity| {
        const before = r.out.len();
        var examined: u64 = 0;
        for (g.node_net.items, response.items, 0..) |net, dynamic, node| {
            const switching = intent.limitsOf(net).dynamic orelse continue;
            examined += 1;
            const supply = intent.supply(net).?;
            // Superposition: the static drop, then the cycle's response.
            const drop = signedDrop(supply.role, solved.solution.node_drop.items[node].add(dynamic));
            try reportNode(r, g, @intCast(node), .{ .rule = id, .severity = severity }, drop, switching.max_drop);
        }
        try r.run(id, before, .ran, examined);
    }
}

/// Every row over the grid's branch currents, each edge at its own
/// temperature above `temperature` (electrical_thermal.zig).
pub fn checkEmThermal(r: Record, power: Power, intent: *const IntentMap, grid: Grid, temperature: Kelvin, t: *const EmThermalTable, height_nm: []const f64) Allocator.Error!void {
    if (t.head.len() == 0) return;
    const solved = try solvedOrFill(r, power, intent, &t.head) orelse return;
    try thermal.thermalRows(r, solved, grid, temperature, t, height_nm);
}

// ---- private ----

/// The solve every grid rule reads, or null after recording every row:
/// refused when the solve failed or a stated budget never reached it,
/// skipped without a solve or usable intent.
fn solvedOrFill(r: Record, power: Power, intent: *const IntentMap, head: *const RuleHead) Allocator.Error!?Solved {
    const solved = switch (power) {
        .failed => {
            try r.fillRows(head, .refused);
            return null;
        },
        .no_supply => {
            try r.skipRows(head);
            return null;
        },
        .solved => |s| s,
    };
    if (!intent.isUsable()) {
        try r.skipRows(head);
        return null;
    }
    if (try discardedBudget(r.gpa, solved.grid, intent)) {
        try r.fillRows(head, .refused);
        return null;
    }
    return solved;
}

/// The loss toward the other rail.
fn signedDrop(role: @import("ingest").intent.SupplyRole, drop: Millivolts) Millivolts {
    return switch (role) {
        .power => drop,
        .ground => drop.neg(),
    };
}

/// One node's voltage finding when it is over `limit`.
fn reportNode(r: Record, g: *const PowerGrid, node: u32, head: Head, measured: Millivolts, limit: Millivolts) Allocator.Error!void {
    const m = Measurement.voltage(measured);
    const l = Measurement.voltage(limit);
    if (!m.violates(l, .maximum)) return;
    try r.out.push(r.gpa, .{
        .rule = head.rule,
        .layer = g.node_layer.items[node],
        .severity = head.severity,
        .at = g.node_at.items[node],
        .measured = m,
        .limit = l,
        .shape_a = g.node_poly.items[node],
        .shape_b = report.no_shape,
    });
}

/// The switching event of every node whose net states `dynamic`: the
/// charge of its share of the budget over the cycles it switches in, a
/// triangle of base the rise time, and the decap in proportion to its share.
fn worstCycle(gpa: Allocator, g: *const PowerGrid, intent: *const IntentMap, out: *transient.Stimulus) Allocator.Error!void {
    for (g.node_net.items, g.node_load.items) |net, load| {
        const limits = intent.limitsOf(net);
        var peak: f64 = 0.0;
        var rise: f64 = 0.0;
        var cap: f64 = 0.0;
        if (limits.dynamic) |s| if (limits.budget_current_ua) |budget| {
            // µA · ps: attocoulombs, signed as the load.
            const charge = load.raw * s.clock_period_ps / s.toggle_rate;
            peak = 2.0 * charge / s.rise_time_ps;
            rise = s.rise_time_ps;
            cap = s.decap_pf * @abs(load.raw) / budget;
            out.window_ps = @max(out.window_ps, s.clock_period_ps);
        };
        try out.node_peak.append(gpa, .{ .raw = peak });
        try out.node_rise_ps.append(gpa, rise);
        try out.node_cap_pf.append(gpa, cap);
    }
}
