//! lvs: layout versus schematic, graph matching between an extracted and a
//! reference netlist (crates/check/src/lvs). Only re-exports. Every path
//! that could not complete is `Verdict.inconclusive`; no path leads from
//! "gave up" to "matched".
//!
//! The engine's LVS spine calls these transforms in this order (Rust
//! engine/run.rs `run_lvs`):
//!
//! 1. `fromLayoutInto` (project.zig): the extraction as a `Graph`;
//! 2. `addLdeParams` (lde.zig): BSIM4 `sa`..`scc` per `lvs lde` row;
//! 3. `checkLayout` (checks.zig), `checkParamRanges`, `checkDeviceCounts`
//!    (records.zig): the reference-free rows, after `internRuleIds`;
//! 4. `addBlackBoxes` (blackbox.zig): each `lvs blackbox` placement one
//!    `cell` device;
//! 5. `joinMustConnect` (retain.zig): must-connect nets one net;
//! 6. `fromReferenceInto` (project.zig): the reference's top subcircuit;
//! 7. `compareTraced` (compare.zig), itself a spine: `dropUnextractedBulk`,
//!    `dropIgnoredDevices`, `sortStressPair`, `protectLabelled`,
//!    `filterUnused`, `dropIgnoredDevices`, `keepDeclaredParams`,
//!    `dropIgnoredParams`, `assignRoles`, `joinSplitGates` both sides
//!    under `lvs split_gates`, `reduceWith` both sides,
//!    `stateCount`, `portSeedsInto`, `refineInto`, `interpretInto`, models
//!    aside, `reportRoles`;
//! 8. on a mismatch, `unpairedInstancesInto` and `recordUnpairedInstances`,
//!    then `recordDiscrepancies` (records.zig).
//!
//! Contents:
//! - graph.zig: `Graph`, `Param`, `no_net`, `transposeInto`, `roleCode`, `kindCode`, union-find
//! - project.zig: `Design`, `fromLayoutInto`, `fromReferenceInto`, `spiceParamName`
//! - verdict.zig: `Verdict`, `Inconclusive`, `Side`, `Discrepancy`
//! - split.zig: `joinSplitGates`
//! - reduce.zig: `reduceWith`, `ParamNames`, `MergeKind`, `Merges`; its passes `reduce_law`, `reduce_plan`, `reduce_emit`
//! - refine.zig: `refineInto`, `Partition`; `refine_partition`, `refine_trial`; `interpret` (`interpretInto`)
//! - compare.zig: `compareTraced`, `CompareOptions`, `Traced`
//! - checks.zig `checkNetSeedConflicts`; records.zig `rule_ids`, `UnpairedInstance`
//! - controls.zig, retain.zig, prepare.zig, lde.zig, blackbox.zig, checks.zig, records.zig, gates.zig
pub const graph = @import("graph.zig");
pub const project = @import("project.zig");
pub const verdict = @import("verdict.zig");
pub const reduce_law = @import("reduce_law.zig");
pub const reduce_plan = @import("reduce_plan.zig");
pub const reduce_emit = @import("reduce_emit.zig");
pub const split = @import("split.zig");
pub const reduce = @import("reduce.zig");
pub const gates = @import("gates.zig");
pub const controls = @import("controls.zig");
pub const retain = @import("retain.zig");
pub const prepare = @import("prepare.zig");
pub const refine_partition = @import("refine_partition.zig");
pub const refine_trial = @import("refine_trial.zig");
pub const refine = @import("refine.zig");
pub const interpret = @import("interpret.zig");
pub const compare = @import("compare.zig");
pub const lde = @import("lde.zig");
pub const blackbox = @import("blackbox.zig");
pub const checks = @import("checks.zig");
pub const records = @import("records.zig");

pub const Graph = graph.Graph;
pub const Param = graph.Param;
pub const Design = project.Design;
pub const Verdict = verdict.Verdict;
pub const Inconclusive = verdict.Inconclusive;
pub const Side = verdict.Side;
pub const Discrepancy = verdict.Discrepancy;
pub const ParamNames = reduce.ParamNames;
pub const MergeKind = reduce.MergeKind;
pub const Merges = reduce.Merges;
pub const CompareOptions = compare.CompareOptions;
pub const Traced = compare.Traced;
pub const fromLayoutInto = project.fromLayoutInto;
pub const fromReferenceInto = project.fromReferenceInto;
pub const addLdeParams = lde.addLdeParams;
pub const checkLayout = checks.checkLayout;
pub const checkNetSeedConflicts = checks.checkNetSeedConflicts;
pub const checkParamRanges = records.checkParamRanges;
pub const checkDeviceCounts = records.checkDeviceCounts;
pub const internRuleIds = records.internRuleIds;
pub const rule_ids = records.rule_ids;
pub const addBlackBoxes = blackbox.addBlackBoxes;
pub const joinMustConnect = retain.joinMustConnect;
pub const compareTraced = compare.compareTraced;
pub const reduceWith = reduce.reduceWith;
pub const recordDiscrepancies = records.recordDiscrepancies;
pub const unpairedInstancesInto = records.unpairedInstancesInto;
pub const recordUnpairedInstances = records.recordUnpairedInstances;
pub const UnpairedInstance = records.UnpairedInstance;
