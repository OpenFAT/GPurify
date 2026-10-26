//! erc: electrical rule checking (ARCHITECTURE.md, Spines: `erc`). Only
//! re-exports.
//!
//! Data decision. Rust's ERC already keeps one table per kind; here each
//! is a struct of `ArrayList` columns (`RuleHead` first, CSR `*_start`
//! columns for list parameters) in its family's file, `RuleSet` holds one
//! per kind plus `order` (`{ kind, row }`) in deck order, and the spine runs
//! the tables in Rust's family order, one `RuleRun` per row. The run's
//! shared tables (net facts, intent, voltages, the supply grid and its
//! solve, the per-net networks) are computed once by `check`.
//!
//! Contents:
//! - `kinds`: `Kind`, `names`, `isKind`, `byName`, `count`
//! - `head`: `Design`, `RuleHead`, `Record`
//! - `facts`: `RoleMask`, `NetFacts`, `IntentMap`, `StateMap`, `NetTypes`, `classifyNetsInto`, `resolveIntentInto`, `resolveStatesInto`, `resolveNetTypesInto`
//! - `voltage`: `NetVoltage`, `isChannel`, `propagateInto`
//! - `power_grid`: `PowerGrid`, `NetNetworks`, `PowerSolution`, `Solved`, `Power`, `PowerError`, `PowerDiag`, `Process`, `EdgeKind`
//! - `power_chain`, `power_taps`, `power_links`: the chain model, taps, conductors and edges
//! - `power_extract`: `extractInto`, `Stress`, `StressGrid`, `extractStressInto`, `discardedBudget`
//! - `power_nets`: `extractNetsInto`, `extractPointsInto`
//! - `power_solve`: `SolveScratch`, `solveInto`; `power_transient`: `Stimulus`, `transientInto`; `power_probe`: `Probe`, `ProbeScratch`, `effectiveResistanceInto`
//! - the kind tables: `topology_tables`, `supply_tables`, `antenna_tables`, `electrical_tables`, `esd_tables`, `latchup_tables`, `domain_tables`
//! - `rule_set`: `RuleSet`, `Tables`, `TableOf`, `Slot`, `deinitTable`; `scratch`: `Scratch`
//! - the helpers families share: `clamp_reach` (`clampRails`, `clampReachInto`, `reverseBiased`), `rings`
//!   (`narrowRingsInto`, `encloses`, `regionDist2`, `padNetsInto`), `em_allowed` (`allowedCurrent`)
//! - `compile`: `fromDeck`; `build_row`, `build_stage`, `build_esd`, `build_layout`, `build_domain`: the kind builders; `validate`, `validate_more`
//! - the families: `topology`, `matching`, `domain`, `domain_devices`, `supply`, `antenna`, `electrical`, `reliability`, `esd`, `latchup`
//! - `run_` (run.zig): `RunInputs`, `run`; `check_` (check.zig): `Inputs`, `check`
//! - the electrical and antenna families' parts: `electrical_current` (branch-current rows), `electrical_thermal`
//!   (`em_thermal`), `antenna_stage` (stage nets, figures), `antenna_row` (the row model), `antenna_density` (windows)
//! - aliases: `Kind`, `RuleSet`, `Design`, `Inputs`, `check`, `fromDeck`

pub const kinds = @import("kinds.zig");
pub const head = @import("head.zig");
pub const facts = @import("facts.zig");
pub const voltage = @import("voltage.zig");
pub const power_grid = @import("power_grid.zig");
pub const power_chain = @import("power_chain.zig");
pub const power_taps = @import("power_taps.zig");
pub const power_links = @import("power_links.zig");
pub const power_extract = @import("power_extract.zig");
pub const power_nets = @import("power_nets.zig");
pub const power_solve = @import("power_solve.zig");
pub const power_transient = @import("power_transient.zig");
pub const power_probe = @import("power_probe.zig");
pub const topology_tables = @import("topology_tables.zig");
pub const supply_tables = @import("supply_tables.zig");
pub const antenna_tables = @import("antenna_tables.zig");
pub const electrical_tables = @import("electrical_tables.zig");
pub const esd_tables = @import("esd_tables.zig");
pub const latchup_tables = @import("latchup_tables.zig");
pub const domain_tables = @import("domain_tables.zig");
pub const rule_set = @import("rule_set.zig");
pub const scratch = @import("scratch.zig");
pub const clamp_reach = @import("clamp_reach.zig");
pub const rings = @import("rings.zig");
pub const em_allowed = @import("em_allowed.zig");
pub const build_row = @import("build_row.zig");
pub const build_stage = @import("build_stage.zig");
pub const build_esd = @import("build_esd.zig");
pub const build_layout = @import("build_layout.zig");
pub const build_domain = @import("build_domain.zig");
pub const validate = @import("validate.zig");
pub const validate_more = @import("validate_more.zig");
pub const compile = @import("compile.zig");
pub const topology = @import("topology.zig");
pub const matching = @import("matching.zig");
pub const domain = @import("domain.zig");
pub const domain_devices = @import("domain_devices.zig");
pub const supply = @import("supply.zig");
pub const antenna = @import("antenna.zig");
pub const electrical = @import("electrical.zig");
pub const reliability = @import("reliability.zig");
pub const esd = @import("esd.zig");
pub const latchup = @import("latchup.zig");
pub const run_ = @import("run.zig");
pub const check_ = @import("check.zig");
pub const electrical_current = @import("electrical_current.zig");
pub const electrical_thermal = @import("electrical_thermal.zig");
pub const antenna_stage = @import("antenna_stage.zig");
pub const antenna_row = @import("antenna_row.zig");
pub const antenna_density = @import("antenna_density.zig");

pub const Kind = kinds.Kind;
pub const RuleSet = rule_set.RuleSet;
pub const Design = head.Design;
pub const Inputs = check_.Inputs;
pub const check = check_.check;
pub const fromDeck = compile.fromDeck;

test {
    _ = kinds;
    _ = head;
    _ = facts;
    _ = voltage;
    _ = power_grid;
    _ = power_chain;
    _ = power_taps;
    _ = power_links;
    _ = power_extract;
    _ = power_nets;
    _ = power_solve;
    _ = power_transient;
    _ = power_probe;
    _ = rule_set;
    _ = build_domain;
    _ = compile;
    _ = run_;
    _ = check_;
    _ = electrical_current;
    _ = electrical_thermal;
    _ = antenna_stage;
    _ = antenna_row;
    _ = antenna_density;
    _ = reliability;
}
