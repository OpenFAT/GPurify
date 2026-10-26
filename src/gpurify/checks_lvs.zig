//! The LVS stage: a loaded and extracted design and its reference → the
//! layout checks' rows, the comparison and its discrepancy rows in
//! `Outputs`. Ported from src/engine/run.rs (`run_lvs`, `param_names`).
//!
//! The layout-only checks run on the unreduced graph, then both sides are
//! compared flat, reduced, on the reference's unique top cell. A comparison
//! that did not conclude refuses the stage; a mismatch ran, its failure
//! carried by its error rows. Guessing which subcircuit was meant is the
//! one thing a comparison must never do, so no unique top is inconclusive.
//!
//! Contents:
//! - `pub fn runLvs(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, options: CompareOptions, out: *Outputs) Allocator.Error!StageStatus`
//! - `pub fn paramNames(strings: *const StrTable) ParamNames`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const check = @import("check");
const report = check.report;
const lvs = check.lvs;
const CompareOptions = lvs.CompareOptions;
const ParamNames = lvs.ParamNames;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const StageStatus = run_.StageStatus;

pub fn runLvs(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, options: CompareOptions, out: *Outputs) Allocator.Error!StageStatus {
    const reference = if (loaded.reference) |*r| r else return .{ .skipped = "no reference netlist was supplied, so no comparison was made" };
    const deck = &loaded.deck.deck;
    const strings = &loaded.strings;
    const design: lvs.Design = .{ .store = &loaded.store, .nets = &extracted.nets, .devices = &extracted.devices };

    // The layout graph, its layout-dependent effects, then the layout checks.
    var layout: lvs.Graph = .{};
    try lvs.fromLayoutInto(scratch, &extracted.nets, &extracted.devices, &extracted.ports, strings, loaded.grid, &layout);
    try lvs.addLdeParams(scratch, &layout, design, deck.lvs.lde, &deck.layers, strings, loaded.grid);
    var violations: report.Violations = .{};
    var runs: std.ArrayList(report.RuleRun) = .empty;
    try lvs.checkLayout(scratch, &layout, design, &extracted.ports, strings, &deck.lvs, &violations, &runs);
    try lvs.checkParamRanges(scratch, design, deck.lvs.range, strings, &violations, &runs);
    try lvs.checkDeviceCounts(scratch, design, deck.lvs.count, strings, &violations, &runs);
    try run_.appendStage(run_arena, out, &violations, runs.items);

    const top = try reference.top(scratch) orelse {
        out.lvs = .{ .verdict = .{ .inconclusive = .ambiguous_top } };
        return .{ .refused = "the comparison did not conclude: AmbiguousTop" };
    };
    // A parameter with no tolerance row of its own agrees within the
    // deck's default, which no foundry shares with another.
    const tolerance = deck.lvs.default_tolerance orelse return .{ .refused = "the deck states no `lvs tolerance default`, so no parameter tolerance is the deck's" };
    var compare = options;
    compare.params = paramNames(strings);
    compare.param_tolerance = tolerance;

    // Each black box is one device on its pins; what it holds is left out
    // (catalog LVS-033).
    const p = &loaded.provenance;
    const boxes: lvs.blackbox.Boxes = .{ .cell = p.box_cell.items, .extent = p.box_extent.items, .pins = p.box_pins.items };
    const ports: lvs.blackbox.BoxPorts = .{ .cell = reference.black_box_cell.items, .port_start = reference.black_box_port_start.items, .port = reference.black_box_port.items };
    var bad_cell: StrId = undefined;
    lvs.addBlackBoxes(scratch, &layout, design, boxes, ports, strings, &bad_cell) catch |err| switch (err) {
        error.TooManyPins => return .{ .refused = try std.fmt.allocPrint(run_arena, "black box {s} has more pins than a compared cell holds", .{strings.resolve(bad_cell)}) },
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Must-connect nets are one net to compare, though the layout keeps the
    // open, which `checkLayout` reported.
    try lvs.joinMustConnect(scratch, &layout, &deck.lvs, strings);
    var ref_graph: lvs.Graph = .{};
    try lvs.fromReferenceInto(scratch, reference, top, &ref_graph);
    var traced: lvs.Traced = .{};
    try lvs.compareTraced(run_arena, &layout, &ref_graph, compare, &deck.lvs, &traced);
    out.lvs = traced;
    return switch (traced.verdict) {
        .match => .ran,
        .mismatch => {
            // The instances a mismatch left whole and unpaired, named by the
            // flattening's placements (catalog LVS-017).
            try lvs.records.unpairedInstancesInto(run_arena, traced.found.items, traced.reference_row_start.items, traced.reference_row.items, reference.placements.items, &out.lvs_unpaired);
            try lvs.records.recordUnpairedInstances(run_arena, out.lvs_unpaired.items, strings, &out.violations);
            try lvs.records.recordDiscrepancies(run_arena, traced.found.items, strings, &out.violations);
            return .ran;
        },
        .inconclusive => |why| .{ .refused = switch (why) {
            .round_limit => "the comparison did not conclude: RoundLimit",
            .ambiguous_top => "the comparison did not conclude: AmbiguousTop",
        } },
    };
}

/// The SPICE names of width, length, fingers, multiplier, the diffusions,
/// the passive values, inductance and stress, as both netlists intern
/// them; null for a name no netlist interned.
pub fn paramNames(strings: *const StrTable) ParamNames {
    return .{
        .width = strings.get("w"),
        .length = strings.get("l"),
        .fingers = strings.get("nf"),
        .multiplier = strings.get("m"),
        .diffusion = .{ strings.get("as"), strings.get("ad"), strings.get("ps"), strings.get("pd") },
        .values = .{ strings.get("r"), strings.get("c"), strings.get("area"), strings.get("perim"), strings.get("ae"), strings.get("pe") },
        .inductance = strings.get("ind"),
        .stress = .{ strings.get("sa"), strings.get("sb") },
    };
}
