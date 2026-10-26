//! The ERC spine (ARCHITECTURE.md, Spines: `erc`): classifyNets → intent →
//! netTypes → propagateVoltage (and per power state) → networks →
//! powerGrid → solveIrDrop (and the AC grids) → rules. In: a `RuleSet` and
//! the extracted design (`Inputs`). Out: violations and exactly one
//! `RuleRun` per rule row, appended. A network that could not be built (a
//! conductor with no stated sheet resistance) or a failed solve refuses
//! only the rows that read it; rows that need intent record themselves
//! skipped when the intent is absent or names nothing this layout has.
//! Nothing refuses the whole run. Ported from crates/check/src/erc/mod.rs
//! (`check`, `Inputs`).
//!
//! Contents:
//! - `pub const Inputs = struct`
//! - `pub fn check(gpa: Allocator, rs: *const RuleSet, in: Inputs, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`
//! - `pub const boltzmann_ev_per_k: f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const StrTable = geom.StrTable;
const DesignIntent = @import("ingest").intent.DesignIntent;
const report = @import("../report.zig");
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const NetId = @import("../topology/net.zig").NetId;
const PortTable = @import("../topology/port.zig").PortTable;
const Design = @import("head.zig").Design;
const facts = @import("facts.zig");
const IntentMap = facts.IntentMap;
const voltage = @import("voltage.zig");
const NetVoltage = voltage.NetVoltage;
const grid_ = @import("power_grid.zig");
const PowerGrid = grid_.PowerGrid;
const PowerSolution = grid_.PowerSolution;
const PowerDiag = grid_.PowerDiag;
const Power = grid_.Power;
const Process = grid_.Process;
const NetNetworks = grid_.NetNetworks;
const power_extract = @import("power_extract.zig");
const power_nets = @import("power_nets.zig");
const power_solve = @import("power_solve.zig");
const Kelvin = @import("electrical_tables.zig").Kelvin;
const MacroPinAntenna = @import("antenna_tables.zig").MacroPinAntenna;
const RuleSet = @import("rule_set.zig").RuleSet;
const Scratch = @import("scratch.zig").Scratch;
const run_ = @import("run.zig");

/// Boltzmann's constant in eV/K: activation energies are stated in eV.
pub const boltzmann_ev_per_k = @import("electrical_tables.zig").boltzmann_ev_per_k;

/// What one ERC run reads.
pub const Inputs = struct {
    design: Design,
    /// Net names from layout labels: they key the intent's supplies and
    /// limits, and `floating_gate` may read a labelled net as a port.
    ports: *const PortTable,
    /// Null skips the intent rules.
    intent: ?*const DesignIntent,
    /// The deck's grid, stack and connectivity.
    process: Process,
    /// The die boundary: the denominator of every density.
    die: Bbox,
    /// The applied sign-off temperature, absolute (the intent's or the
    /// deck's); null refuses the rows that derate to it.
    temperature: ?Kelvin,
    /// The placed macro pins' LEF antenna data; empty for a GDS layout.
    antenna_pins: []const MacroPinAntenna = &.{},
    /// Label text, which the intent's net types match by name.
    strings: *const StrTable,
};

/// Runs every row of `rs` over one extracted design, appending to `out`
/// and exactly one `RuleRun` per row to `runs`. Every shared table is built
/// once, in `gpa` scratch freed on return.
pub fn check(gpa: Allocator, rs: *const RuleSet, in: Inputs, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const d = in.design;
    var net_facts: facts.NetFacts = .{};
    defer net_facts.deinit(gpa);
    try facts.classifyNetsInto(gpa, d.nets, d.devices, &net_facts);
    var intent: IntentMap = .{};
    defer intent.deinit(gpa);
    try facts.resolveIntentInto(gpa, in.intent, in.ports, d.nets, &intent);
    var net_types: facts.NetTypes = .{};
    defer net_types.deinit(gpa);
    try facts.resolveNetTypesInto(gpa, in.intent, in.ports, d.nets, d.devices, &intent, in.strings, &net_types);
    var reach: NetVoltage = .{};
    defer reach.deinit(gpa);
    try voltage.propagateInto(gpa, d.nets, d.devices, &intent, &reach);

    // One propagation per declared power state, its supplies off and its
    // inputs held.
    var states: std.ArrayList(facts.StateMap) = .empty;
    defer {
        for (states.items) |*s| s.deinit(gpa);
        states.deinit(gpa);
    }
    try facts.resolveStatesInto(gpa, in.intent, in.ports, d.nets, &states);
    var switched: std.ArrayList(NetId) = .empty;
    defer switched.deinit(gpa);
    for (states.items) |s| try switched.appendSlice(gpa, s.off.items);
    std.mem.sortUnstable(NetId, switched.items, {}, lessNet);
    switched.shrinkRetainingCapacity(dedup(switched.items));
    const state_reach = try gpa.alloc(NetVoltage, states.items.len);
    @memset(state_reach, .{});
    defer {
        for (state_reach) |*v| v.deinit(gpa);
        gpa.free(state_reach);
    }
    for (states.items, state_reach) |*s, *v| {
        var supplies = try intent.inState(gpa, s);
        defer supplies.deinit(gpa);
        try voltage.propagateInto(gpa, d.nets, d.devices, &supplies, v);
    }

    var diag: PowerDiag = .{};
    var networks: NetNetworks = .{};
    defer networks.deinit(gpa);
    const built = if (power_nets.extractNetsInto(gpa, d.store, d.nets, d.devices, in.process, &networks, &diag)) true else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    var grid: PowerGrid = .{};
    defer grid.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    // No declared supply: no grid, and the electrical rules skip.
    const power = try buildAndSolve(gpa, d, &intent, in.process, &scratch, &grid, &solution);

    // The AC current rules' grids: the supply grid again, each net loaded
    // with its RMS, then its peak, current in place of its budget; built
    // only for rows that read them, and only when some net states one.
    var rms_intent = try intent.withBudget(gpa, .rms_current_ua);
    defer rms_intent.deinit(gpa);
    var peak_intent = try intent.withBudget(gpa, .peak_current_ua);
    defer peak_intent.deinit(gpa);
    var ac_grid: [2]PowerGrid = .{ .{}, .{} };
    var ac_solution: [2]PowerSolution = .{ .{}, .{} };
    defer for (&ac_grid, &ac_solution) |*g, *s| {
        g.deinit(gpa);
        s.deinit(gpa);
    };
    const ac_intent = [2]*const IntentMap{ &rms_intent, &peak_intent };
    const wanted = [2]bool{ rs.tables.em_rms.head.len() > 0, rs.tables.em_peak.head.len() > 0 };
    var ac: [2]Power = .{ .no_supply, .no_supply };
    for (0..2) |k| if (wanted[k] and ac_intent[k].limit_net.items.len > 0) {
        ac[k] = try buildAndSolve(gpa, d, ac_intent[k], in.process, &scratch, &ac_grid[k], &ac_solution[k]);
    };

    try run_.run(gpa, rs, .{
        .design = d,
        .facts = &net_facts,
        .ports = in.ports,
        .intent = &intent,
        .net_types = &net_types,
        .voltage = &reach,
        .states = state_reach,
        .switched = switched.items,
        .networks = if (built) &networks else null,
        .power = power,
        .rms_intent = &rms_intent,
        .rms = ac[0],
        .peak_intent = &peak_intent,
        .peak = ac[1],
        .die = in.die,
        .process = in.process,
        .temperature = in.temperature,
        .antenna_pins = in.antenna_pins,
    }, &scratch, out, runs);
}

// ---- private ----

/// One supply grid built from `intent` and solved: what its rules read.
fn buildAndSolve(gpa: Allocator, d: Design, intent: *const IntentMap, process: Process, scratch: *Scratch, grid: *PowerGrid, solution: *PowerSolution) Allocator.Error!Power {
    var diag: PowerDiag = .{};
    power_extract.extractInto(gpa, d.store, d.nets, d.devices, intent, process, grid, &diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => |pe| .{ .failed = pe },
    };
    if (grid.isEmpty()) return .no_supply;
    power_solve.solveInto(gpa, grid, &scratch.solve, solution, &diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => |pe| .{ .failed = pe },
    };
    return .{ .solved = .{ .grid = grid, .solution = solution } };
}

fn lessNet(_: void, a: NetId, b: NetId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn dedup(items: []NetId) usize {
    var kept: usize = 0;
    for (items) |n| if (kept == 0 or items[kept - 1] != n) {
        items[kept] = n;
        kept += 1;
    };
    return kept;
}
