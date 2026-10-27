//! The run spine: inputs → load → extract → checks → `Outputs` and a
//! `Summary`, reporting honestly which checks ran. Ported from
//! src/engine/run.rs (`Checks`, `RunOptions`, `Outputs`, `run`, `run_with`,
//! `run_checks`, `summarize`, `append_stage`, `EngineError`).
//!
//! The checks run once each, DRC, ERC, LVS, PEX. A check that cannot run is
//! a `StageStatus`, never an empty result. A layout whose net carries two
//! labels, a short between named nets, gets the `lvs.net_seed_conflict`
//! row whatever was selected, so it fails every run. Each domain computes
//! in its own scratch arena over `gpa`, freed before the next domain; what
//! it reports is copied into `Outputs`, in the caller's `run_arena`.
//!
//! Contents:
//! - `pub const Checks = struct { drc, erc, lvs, pex }`, `Checks.all`
//! - `pub const RunOptions = struct`, `pub const Outputs = struct`, `pub const Corner = struct`
//! - `pub const Summary`, `pub const StageStatus` (export/text.zig's)
//! - `pub const Error`, `pub const RunError`, `pub const Diagnostic`, `pub const Run = struct`
//! - `pub fn run(gpa: Allocator, run_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, options: RunOptions, decks: []const NamedDeck, diag: *Diagnostic) RunError!Run`
//! - `pub fn runChecks(gpa: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, options: RunOptions, out: *Outputs) Error!Summary`
//! - `pub fn summarize(run_arena: Allocator, out: *Outputs, stages: [4]StageStatus) Allocator.Error!Summary`
//! - `pub fn appendStage(run_arena: Allocator, out: *Outputs, violations: *const Violations, runs: []const RuleRun) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const check = @import("check");
const report = check.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const lvs = check.lvs;
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const load_ = @import("load.zig");
const Inputs = load_.Inputs;
const Loaded = load_.Loaded;
const NamedDeck = load_.NamedDeck;
const extracted_ = @import("extracted.zig");
const Extracted = extracted_.Extracted;
const text = @import("export/text.zig");
const checks_drc = @import("checks_drc.zig");
const checks_erc = @import("checks_erc.zig");
const checks_lvs = @import("checks_lvs.zig");
const checks_pex = @import("checks_pex.zig");
const checks_after = @import("checks_after.zig");

/// Which checks to run; the default selects none, which passes having
/// checked nothing.
pub const Checks = struct {
    /// Every DRC row of the deck, then its custom rules.
    drc: bool = false,
    /// Every ERC row of the deck.
    erc: bool = false,
    /// The layout-only LVS checks and, given a reference, the comparison.
    lvs: bool = false,
    /// Parasitic extraction.
    pex: bool = false,

    /// All four, as `gpurify all` runs them.
    pub const all: Checks = .{ .drc = true, .erc = true, .lvs = true, .pex = true };
};

/// How to run.
pub const RunOptions = struct {
    checks: Checks = .{},
    /// LVS settings; only `max_rounds` is read: the tolerance is the deck's
    /// `lvs tolerance default`, the parameter names always `w`, `l`, ....
    lvs: lvs.CompareOptions = .{},
    /// Label texts of nets to field-solve for capacitance and inductance
    /// over the closed forms. A name on no net, or on several (an open),
    /// refuses PEX; a name given twice is solved once.
    quasistatic_nets: []const []const u8 = &.{},
    /// The backend DRC's pair distances and PEX's field solve run on.
    device: geom.Device = .cpu,
};

/// One process corner's network, under the corner's name.
pub const Corner = struct { name: geom.StrId, network: ParasiticNetwork };

/// Everything a run produced, in the run arena.
pub const Outputs = struct {
    /// DRC, ERC and LVS findings, canonical order.
    violations: Violations = .{},
    /// One row per rule, run or not, by rule id.
    runs: std.ArrayList(RuleRun) = .empty,
    /// The comparison: non-null whenever LVS ran with a reference,
    /// an inconclusive one included.
    lvs: ?lvs.Traced = null,
    /// The reference instances a mismatch left wholly unpaired (rows of
    /// `Loaded.reference.placements`), each also an `lvs.unpaired_instance` row.
    lvs_unpaired: std.ArrayList(lvs.UnpairedInstance) = .empty,
    /// Analytical with any field-solved nets laid over it, reduced to the
    /// deck's extraction type; non-null only when PEX ran.
    parasitics: ?ParasiticNetwork = null,
    /// What the deck's waivers cover, moved out of `violations`, canonical.
    waived: Violations = .{},
    /// The same extraction at each process corner, in deck order.
    corners: std.ArrayList(Corner) = .empty,
    /// The nets PEX field-solved, ascending: each is one node and its far
    /// end, not a node per region.
    field_solved: []const u32 = &.{},
};

/// What happened at a glance; `passed` is the criterion.
pub const Summary = text.Summary;
pub const StageStatus = text.StageStatus;

/// What can stop the checks: memory, a worker thread, or DRC geometry a
/// derived operation cannot represent.
pub const Error = check.drc.scratch.Error || Allocator.Error;

/// Why a run produced no report: an input could not be loaded or
/// extracted, or the checks failed (`Error`).
pub const RunError = load_.Error || extracted_.Error || Error;

pub const Diagnostic = struct {
    load: load_.Diagnostic = .{},
    extract: extracted_.Diagnostic = .none,
};

/// Everything one run produced, in the run arena.
pub const Run = struct { loaded: Loaded, extracted: Extracted, outputs: Outputs, summary: Summary };

/// Load, extract and check in one call. `inputs.deck` naming one of
/// `decks` builds it instead of reading a file.
pub fn run(gpa: Allocator, run_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, options: RunOptions, decks: []const NamedDeck, diag: *Diagnostic) RunError!Run {
    var out: Run = undefined;
    out.loaded = try load_.load(gpa, run_arena, io, dir, inputs, decks, &diag.load);
    out.extracted = try extracted_.extract(run_arena, &out.loaded, &diag.extract);
    out.outputs = .{};
    out.summary = try runChecks(gpa, run_arena, &out.loaded, &out.extracted, options, &out.outputs);
    return out;
}

/// Runs the selected checks into `out` (empty on entry). `loaded` comes
/// from `load` and `extracted` from `extract` over it.
pub fn runChecks(gpa: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, options: RunOptions, out: *Outputs) Error!Summary {
    const staged = loaded.deck.deck.stages.name.len != 0;
    // The store's device copy for every DRC kernel call; uploaded by the
    // first call that goes to the GPU, so an all-CPU run uploads nothing.
    // Load derived every layer already, so the copy covers what DRC reads.
    var resident: geom.ResidentStore = .empty;
    defer resident.deinit();
    const drc: StageStatus = if (options.checks.drc) try domain(gpa, checks_drc.runDrc, .{ run_arena, options.device, &resident, loaded, extracted, out }) else .not_selected;
    const erc: StageStatus = if (options.checks.erc) try domain(gpa, checks_erc.runErc, .{ run_arena, loaded, extracted, out }) else .not_selected;
    if (staged) try checks_after.holdBackLaterStages(run_arena, loaded, out);
    const lvs_status: StageStatus = if (options.checks.lvs) try domain(gpa, checks_lvs.runLvs, .{ run_arena, loaded, extracted, options.lvs, out }) else .not_selected;
    const pex: StageStatus = if (options.checks.pex) try domain(gpa, checks_pex.runPex, .{ run_arena, options.device, loaded, extracted, options.quasistatic_nets, out }) else .not_selected;
    // A short between labelled nets fails every run, with its row: LVS's
    // layout checks record it when they run, and this does when they do not.
    const layout_checked = options.checks.lvs and loaded.reference != null;
    if (!layout_checked and extracted.ports.shortedNet() != null) try domain(gpa, checks_after.netSeedShorts, .{ run_arena, loaded, extracted, out });
    try checks_after.applyWaivers(run_arena, loaded, out);
    return summarize(run_arena, out, .{ drc, erc, lvs_status, pex });
}

/// Puts `out` in canonical order and counts it, stages in DRC, ERC, LVS,
/// PEX order.
pub fn summarize(run_arena: Allocator, out: *Outputs, stages: [4]StageStatus) Allocator.Error!Summary {
    try out.violations.sortCanonical(run_arena);
    try out.waived.sortCanonical(run_arena);
    std.mem.sort(RuleRun, out.runs.items, {}, byRule);
    const violations = out.violations.len();
    var errors: u32 = 0;
    for (out.violations.severity.items) |s| errors += @intFromBool(s == .@"error");
    var clean: u32 = 0;
    var skipped: u32 = 0;
    for (out.runs.items) |r| {
        const ran = r.outcome == .ran;
        clean += @intFromBool(ran and r.violations == 0);
        skipped += @intFromBool(!ran);
    }
    return .{ .drc = stages[0], .erc = stages[1], .lvs = stages[2], .pex = stages[3], .violations = violations, .errors = errors, .warnings = violations - errors, .rules_clean = clean, .rules_skipped = skipped };
}

/// Appends one rule set's fresh findings and runs to `out`.
pub fn appendStage(run_arena: Allocator, out: *Outputs, violations: *const Violations, runs: []const RuleRun) Allocator.Error!void {
    try out.violations.extend(run_arena, violations);
    try out.runs.appendSlice(run_arena, runs);
}

// ---- private ----

/// Runs one domain with a scratch arena over `gpa`, freed on return.
fn domain(gpa: Allocator, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    return @call(.auto, f, .{scratch.allocator()} ++ args);
}

/// Rust sorts by the rule's `StrId` (a stable sort, so equal ids keep order).
fn byRule(_: void, a: RuleRun, b: RuleRun) bool {
    return @backingInt(a.rule) < @backingInt(b.rule);
}
