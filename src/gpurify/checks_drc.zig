//! The DRC stage: a loaded and extracted design → its DRC findings and rule
//! records appended to `Outputs`. Ported from src/engine/run.rs (`run_drc`,
//! and the integration call `run_checks` makes before it).
//!
//! On a DEF layout the integration checks run first. Then every DRC rule,
//! the deck's custom rules after them; in a staged deck, stage by stage (a
//! custom rule in the last), and once a stage finds an error the later
//! stages' rules are not run but recorded `skipped: earlier_stage`. The
//! pair-distance kernel reads the store from the run's `resident` copy.
//!
//! Contents:
//! - `pub fn runDrc(scratch: Allocator, run_arena: Allocator, device: Device, resident: *ResidentStore, loaded: *const Loaded, extracted: *const Extracted, out: *Outputs) Error!StageStatus`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Device = geom.Device;
const ResidentStore = geom.ResidentStore;
const StrId = geom.StrId;
const check = @import("check");
const report = check.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const RuleSet = check.drc.RuleSet;
const CustomRule = check.deck.custom.CustomRule;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const StageStatus = run_.StageStatus;
const Error = run_.Error;
const integration = @import("integration.zig");

pub fn runDrc(scratch: Allocator, run_arena: Allocator, device: Device, resident: *ResidentStore, loaded: *const Loaded, extracted: *const Extracted, out: *Outputs) Error!StageStatus {
    const deck = &loaded.deck;
    var violations: Violations = .{};
    var runs: std.ArrayList(RuleRun) = .empty;
    if (loaded.design) |*design| {
        try integration.check(scratch, design, &loaded.strings, &violations, &runs);
        try run_.appendStage(run_arena, out, &violations, runs.items);
    }
    const stages = deck.deck.stages.name.len;
    if (stages == 0) {
        try rulesInto(scratch, device, resident, loaded, extracted, &deck.drc, deck.custom.items, &violations, &runs);
        try run_.appendStage(run_arena, out, &violations, runs.items);
        return .ran;
    }
    var staged = deck.drc;
    var customs: std.ArrayList(CustomRule) = .empty;
    var dirty = false;
    for (0..stages) |s| {
        const stage: u16 = @intCast(s);
        staged.order = .empty;
        staged.id = .empty;
        staged.severity = .empty;
        for (deck.drc.order.items, deck.drc.id.items, deck.drc.severity.items) |slot, id, severity| {
            if (stageOf(loaded, id) != stage) continue;
            try staged.order.append(scratch, slot);
            try staged.id.append(scratch, id);
            try staged.severity.append(scratch, severity);
        }
        customs.clearRetainingCapacity();
        for (deck.custom.items) |rule| if (stageOf(loaded, rule.id) == stage) try customs.append(scratch, rule);
        if (dirty) {
            for (staged.id.items) |id| try out.runs.append(run_arena, held(id));
            for (customs.items) |rule| try out.runs.append(run_arena, held(rule.id));
            continue;
        }
        try rulesInto(scratch, device, resident, loaded, extracted, &staged, customs.items, &violations, &runs);
        dirty = std.mem.findScalar(report.Severity, violations.severity.items, .@"error") != null;
        try run_.appendStage(run_arena, out, &violations, runs.items);
    }
    return .ran;
}

// ---- private ----

/// `rules`, then `customs`, into `violations` and `runs` (cleared first).
fn rulesInto(scratch: Allocator, device: Device, resident: *ResidentStore, loaded: *const Loaded, extracted: *const Extracted, rules: *const RuleSet, customs: []const CustomRule, violations: *Violations, runs: *std.ArrayList(RuleRun)) Error!void {
    try check.drc.run(scratch, device, resident, rules, &loaded.store, extracted.nets.netColumn(), violations, runs);
    try check.deck.custom.runCustom(scratch, customs, &loaded.store, &extracted.nets, loaded.grid, &loaded.strings, violations, runs);
}

fn stageOf(loaded: *const Loaded, rule: StrId) ?u16 {
    return loaded.deck.deck.stages.of(rule);
}

fn held(rule: StrId) RuleRun {
    return .{ .rule = rule, .outcome = .{ .skipped = .earlier_stage }, .examined = 0, .violations = 0 };
}
