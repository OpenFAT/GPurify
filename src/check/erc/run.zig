//! The rule dispatch: every table of a `RuleSet` run once, in Rust's family
//! order, each recording exactly one `RuleRun` per row (none for an empty
//! table). In: the rule set and everything one run reads (`RunInputs`).
//! Out: violations and runs appended. The rows that derate to the sign-off
//! temperature are refused (or skipped without intent) when the run has
//! none. Ported from crates/check/src/erc/ruleset.rs (`RuleSet::run`,
//! `RunInputs`).
//!
//! Contents:
//! - `pub const RunInputs = struct`
//! - `pub fn run(gpa: Allocator, rs: *const RuleSet, in: RunInputs, scratch: *Scratch, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const report = @import("../report.zig");
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const NetId = @import("../topology/net.zig").NetId;
const PortTable = @import("../topology/port.zig").PortTable;
const head_ = @import("head.zig");
const Design = head_.Design;
const Record = head_.Record;
const facts_ = @import("facts.zig");
const NetFacts = facts_.NetFacts;
const IntentMap = facts_.IntentMap;
const NetTypes = facts_.NetTypes;
const NetVoltage = @import("voltage.zig").NetVoltage;
const grid_ = @import("power_grid.zig");
const NetNetworks = grid_.NetNetworks;
const Power = grid_.Power;
const Process = grid_.Process;
const Kelvin = @import("electrical_tables.zig").Kelvin;
const MacroPinAntenna = @import("antenna_tables.zig").MacroPinAntenna;
const RuleSet = @import("rule_set.zig").RuleSet;
const Scratch = @import("scratch.zig").Scratch;
const topology = @import("topology.zig");
const matching = @import("matching.zig");
const domain = @import("domain.zig");
const supply = @import("supply.zig");
const antenna = @import("antenna.zig");
const electrical = @import("electrical.zig");
const reliability = @import("reliability.zig");
const esd = @import("esd.zig");
const latchup = @import("latchup.zig");

/// Everything one run reads.
pub const RunInputs = struct {
    design: Design,
    /// Terminal roles per net, over the same nets.
    facts: *const NetFacts,
    /// Labelled nets: driven from outside the cell.
    ports: *const PortTable,
    /// The intent keyed by net; `isUsable` decides which rows skip.
    intent: *const IntentMap,
    net_types: *const NetTypes,
    /// What each net can reach from the declared supplies.
    voltage: *const NetVoltage,
    /// Each declared power state's reach, in the intent's order.
    states: []const NetVoltage = &.{},
    /// The declared supplies some state switches off, ascending.
    switched: []const NetId = &.{},
    /// The per-net networks, or null when they could not be built.
    networks: ?*const NetNetworks,
    /// The solved supply grid.
    power: Power,
    /// The supply grid loaded with each net's RMS current and the intent
    /// whose budgets are those currents; `.no_supply` when no `em_rms` row
    /// or no net states one.
    rms_intent: *const IntentMap,
    rms: Power = .no_supply,
    /// As `rms`, for the peak current and the `em_peak` rows.
    peak_intent: *const IntentMap,
    peak: Power = .no_supply,
    /// The die: the denominator of every density.
    die: Bbox,
    process: Process,
    /// The applied sign-off temperature; null refuses the rows that derate.
    temperature: ?Kelvin,
    /// The placed macro pins' LEF antenna data; empty for a GDS layout.
    antenna_pins: []const MacroPinAntenna = &.{},
};

/// Runs every table once, appending to `out` and `runs`. Asserts each
/// table keeps its row invariants (one assembled by hand can break them).
pub fn run(gpa: Allocator, rs: *const RuleSet, in: RunInputs, scratch: *Scratch, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const r: Record = .{ .gpa = gpa, .out = out, .runs = runs };
    const t = &rs.tables;
    const d = in.design;
    const grid = in.process.grid;
    try topology.checkFloatingGate(r, d, in.facts, in.ports, &t.floating_gate);
    try topology.checkFloatingWell(r, d, &t.floating_well, scratch);
    try topology.checkMultipleDrivers(r, d, in.intent, &t.multiple_drivers, scratch);
    try topology.checkUnconnectedPin(r, d, in.facts, &t.unconnected_pin);
    try topology.checkFanout(r, d, &t.fanout);
    try topology.checkSupplyPath(r, d, in.facts, in.ports, in.intent, &t.supply_path);
    try topology.checkGatePath(r, d, in.intent, &t.gate_path);
    try topology.checkNetType(r, d, in.facts, in.net_types, &t.net_type);
    try topology.checkCombinationalLoop(r, d, in.intent, &t.combinational_loop);
    try matching.checkMatching(r, d, &t.matching);
    try domain.checkPowerSwitch(r, d, in.intent, in.switched, in.states, &t.power_switch);
    try domain.checkHotCarrier(r, d, in.intent, &t.hot_carrier);
    try domain.checkWellSharing(r, d, &t.well_sharing);

    try supply.checkSupplyShort(r, d, &t.supply_short, scratch);
    try supply.checkSoftConnection(r, d, &t.soft_connection, &rs.connectivity, scratch);
    try supply.checkMissingTie(r, d, &t.missing_tie, scratch);
    try supply.checkTieHighLow(r, d, in.facts, in.intent, &t.tie_high_low);
    try supply.checkEsdTopological(r, d, in.intent, &t.esd_topological);
    try supply.checkFloatingSupply(r, d, in.ports, in.intent, in.process, &t.floating_supply);
    try supply.checkMixedTag(r, d, &t.mixed_tag);

    try antenna.checkAntenna(r, d, in.antenna_pins, &t.antenna, rs.stack(), scratch);
    try antenna.checkAntennaElectrical(r, d, in.antenna_pins, grid, &t.antenna_electrical, rs.stack(), scratch);
    try antenna.checkDensityCmp(r, d, in.die, &t.density_cmp, scratch);

    try electrical.checkP2pResistance(r, d, in.networks, &t.p2p_resistance, scratch);
    try electrical.checkIrDrop(r, in.power, in.intent, &t.ir_drop);
    try electrical.checkEmCurrentDensity(r, in.power, in.intent, grid, &t.em_current_density);
    try electrical.checkEmAc(r, in.rms, in.rms_intent, grid, &t.em_rms);
    try electrical.checkEmAc(r, in.peak, in.peak_intent, grid, &t.em_peak);
    const usable = in.intent.isUsable();
    if (in.temperature) |temp| {
        try electrical.checkElectromigration(r, in.power, in.intent, grid, temp, &t.electromigration);
    } else try r.noTemperature(usable, &t.electromigration.head);
    try electrical.checkDynamicIrDrop(r, in.power, in.intent, &t.dynamic_ir_drop, scratch);
    if (in.temperature) |temp| {
        try electrical.checkEmThermal(r, in.power, in.intent, grid, temp, &t.em_thermal, rs.height_nm);
        try reliability.checkReliability(r, in.power, in.intent, temp, &t.reliability);
    } else {
        try r.noTemperature(usable, &t.em_thermal.head);
        try r.noTemperature(usable, &t.reliability.head);
    }
    try reliability.checkHvDomain(r, d, in.intent, in.voltage, &t.hv_domain);
    try reliability.checkEsdLatchup(r, d, in.intent, &t.esd_latchup, scratch);

    try esd.checkEsdPath(r, d, in.intent, in.process, &t.esd_path, scratch);
    try esd.checkEsdPinPair(r, d, in.intent, in.process, &t.esd_pin_pair, scratch);
    try esd.checkEsdClampResistance(r, d, in.process, &t.esd_clamp_resistance, scratch);
    try esd.checkEsdGroundCoupling(r, d, in.intent, &t.esd_ground_coupling);
    try esd.checkEsdCrossDomain(r, d, in.intent, in.voltage, in.process, &t.esd_cross_domain, scratch);
    try esd.checkEsdParasitic(r, d, &t.esd_parasitic);
    try esd.checkEsdExposed(r, d, in.intent, &t.esd_exposed);

    try latchup.checkGuardRingBias(r, d, in.intent, &t.guard_ring_bias);
    try latchup.checkTieArea(r, d, &t.tie_area, scratch);
    try latchup.checkGuardRing(r, d, &t.guard_ring, scratch);
    try latchup.checkForwardDiode(r, d, in.intent, in.voltage, &t.forward_diode);
    try latchup.checkConditionalTie(r, d, &t.conditional_tie, scratch);
    try latchup.checkLatchupVictim(r, d, in.intent, in.voltage, &t.latchup_victim, scratch);

    try domain.checkGateOxide(r, d, in.intent, in.voltage, &t.gate_oxide);
    try domain.checkDrainSource(r, d, in.intent, in.voltage, &t.drain_source);
    try domain.checkWellBias(r, d, in.intent, in.voltage, &t.well_bias);
    try domain.checkMissingLevelShifter(r, d, in.intent, in.voltage, &t.missing_level_shifter);
    try domain.checkDomainCrossing(r, d, in.intent, in.voltage, &t.domain_crossing);
    try domain.checkVoltageSpacing(r, d, in.intent, in.voltage, &t.voltage_spacing);
    try domain.checkHvTag(r, d, in.intent, in.voltage, &t.hv_tag);
    try domain.checkDielectricField(r, d, in.intent, in.voltage, grid, &t.dielectric_field);
    try domain.checkUndrivenGate(r, d, in.intent, in.voltage, in.states, &t.undriven_gate);
    try domain.checkMissingIsolation(r, d, in.intent, in.voltage, in.states, &t.missing_isolation);
}
