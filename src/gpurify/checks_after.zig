//! What the run spine does between and after the domains, over `Outputs`:
//! a staged deck's later stages held back, the net-seed short row, and the
//! deck's waivers. Ported from src/engine/run.rs (`hold_back_later_stages`,
//! `apply_waivers`, and the `check_net_seed_conflicts` call of
//! `run_checks`).
//!
//! Contents:
//! - `pub fn holdBackLaterStages(run_arena: Allocator, loaded: *const Loaded, out: *Outputs) Allocator.Error!void`
//! - `pub fn netSeedShorts(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, out: *Outputs) Allocator.Error!void`
//! - `pub fn applyWaivers(run_arena: Allocator, loaded: *const Loaded, out: *Outputs) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const Point = geom.Point;
const StrId = geom.StrId;
const check = @import("check");
const report = check.report;
const Violations = report.Violations;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;

/// A staged deck: the first stage (deck order) whose DRC or ERC rules
/// report an error is the last one reported. Every rule of a later stage
/// becomes `skipped: earlier_stage`, its findings withdrawn. DRC already
/// stopped at its own first dirty stage; this carries an ERC error to the
/// DRC and ERC rules of later stages.
///
/// ponytail: ERC runs whole and its later stages are withdrawn, so they cost
/// their runtime; split the ERC tables by stage if that runtime matters.
pub fn holdBackLaterStages(run_arena: Allocator, loaded: *const Loaded, out: *Outputs) Allocator.Error!void {
    const stages = loaded.deck.deck.stages;
    var dirty: ?u16 = null;
    for (out.violations.severity.items, out.violations.rule.items) |s, rule| {
        if (s != .@"error") continue;
        const stage = stages.of(rule) orelse continue;
        dirty = if (dirty) |d| @min(d, stage) else stage;
    }
    const first = dirty orelse return;
    var kept: Violations = .{};
    for (out.violations.rule.items, 0..) |rule, row| {
        if (!held(loaded, rule, first)) try kept.pushRow(run_arena, &out.violations, @intCast(row));
    }
    out.violations = kept;
    for (out.runs.items) |*r| if (held(loaded, r.rule, first)) {
        r.outcome = .{ .skipped = .earlier_stage };
        r.examined = 0;
        r.violations = 0;
    };
}

/// The `lvs.net_seed_conflict` row for a net carrying two labels.
pub fn netSeedShorts(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, out: *Outputs) Allocator.Error!void {
    var violations: Violations = .{};
    var runs: std.ArrayList(report.RuleRun) = .empty;
    const design: check.lvs.Design = .{ .store = &loaded.store, .nets = &extracted.nets, .devices = &extracted.devices };
    try check.lvs.checkNetSeedConflicts(scratch, design, &extracted.ports, &loaded.strings, &violations, &runs);
    try run_.appendStage(run_arena, out, &violations, runs.items);
}

/// The deck's waivers (`waive <rule> <layer>`): a violation whose marker
/// lies on a shape of a layer that waives its rule, the boundary counting
/// as on it, moves to `out.waived`, and its rule's `RuleRun.violations`
/// drops by one. Waivers are geometry in the layout, as Calibre
/// Auto-Waivers keeps them on "a specific geometry layer", so a waiver
/// drawn in a cell waives at every placement of it.
///
/// ponytail: every waived rule's violation tests every shape of its waiver
/// layers; a spatial index if waiver layers grow to thousands of shapes.
pub fn applyWaivers(run_arena: Allocator, loaded: *const Loaded, out: *Outputs) Allocator.Error!void {
    const waivers = loaded.deck.deck.waivers;
    if (waivers.len == 0) return;
    var kept: Violations = .{};
    for (out.violations.rule.items, out.violations.at.items, 0..) |rule, at, row| {
        const waived = for (waivers) |w| {
            if (w.rule == rule and covers(loaded, w.layer, at)) break true;
        } else false;
        if (!waived) {
            try kept.pushRow(run_arena, &out.violations, @intCast(row));
            continue;
        }
        for (out.runs.items) |*r| if (r.rule == rule) {
            r.violations -|= 1;
            break;
        };
        try out.waived.pushRow(run_arena, &out.violations, @intCast(row));
    }
    out.violations = kept;
}

// ---- private ----

fn held(loaded: *const Loaded, rule: StrId, dirty: u16) bool {
    const stage = loaded.deck.deck.stages.of(rule) orelse return false;
    return stage > dirty;
}

fn covers(loaded: *const Loaded, layer: LayerId, at: Point) bool {
    const store = &loaded.store;
    if (@backingInt(layer) >= store.layerCount()) return false;
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |r| {
        const poly: geom.PolyId = @fromBackingInt(@as(u32, @intCast(r)));
        const b = store.polyBbox(poly);
        if (b.xlo <= at.x and at.x <= b.xhi and b.ylo <= at.y and at.y <= b.yhi and store.polyContainsPoint(poly, at)) return true;
    }
    return false;
}
