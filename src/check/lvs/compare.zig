//! The comparison spine: one line per transform, from the two projected
//! graphs to a verdict. In: the layout graph (black boxes added, must-
//! connect nets joined) and one reference subcircuit's graph, the options,
//! the deck's `lvs` controls. Out: a `Traced` (verdict, discrepancies,
//! merges per side, the given rows each reduced device stands for, each
//! reduced net's given row, and the pairing: the correspondence a
//! simulator's terminal currents are placed through, catalog ERC-E14).
//! Neither input is modified; the verdict is deterministic.
//! Ported from crates/check/src/lvs/compare.rs (`compare_traced`, `origin`,
//! `models_aside`, `CompareOptions`, `Traced`).
//!
//! Contents:
//! - `pub const CompareOptions = struct`
//! - `pub const Traced = struct`, `deinit(t: *Traced, gpa: Allocator) void`, `referenceRowsOf(t: *const Traced, device: u32) []const u32`,
//!   `layoutRowsOf(t: *const Traced, device: u32) []const u32`, `pub const unpaired: u32`
//! - `pub fn compareTraced(gpa: Allocator, layout: *const Graph, reference: *const Graph, options: CompareOptions, controls: *const LvsControls, out: *Traced) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const StrId = @import("geom").StrId;
const LvsControls = @import("ingest").deck.LvsControls;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const verdict = @import("verdict.zig");
const Verdict = verdict.Verdict;
const Discrepancy = verdict.Discrepancy;
const prepare = @import("prepare.zig");
const retain = @import("retain.zig");
const controls_mod = @import("controls.zig");
const split = @import("split.zig");
const reduce = @import("reduce.zig");
const ParamNames = reduce.ParamNames;
const Merges = reduce.Merges;
const refine = @import("refine.zig");
const Partition = refine.Partition;
const interpretInto = @import("interpret.zig").interpretInto;

/// How to run a comparison. The default is 1000 rounds, a 2 % tolerance and
/// no parameter names; the engine takes the tolerance from the deck's `lvs
/// tolerance default` and names every `ParamNames` field by its SPICE name.
pub const CompareOptions = struct {
    /// The most refinement passes in a row that may split a class without
    /// settling; one more is `round_limit`. Restarts at each tie-break.
    max_rounds: u32 = 1000,
    /// Relative tolerance: `|a - b| <= tol·max(|a|, |b|)`; a count (`m`,
    /// `nf`) agrees only exactly (F99); a deck's `lvs tolerance` row
    /// replaces it for one parameter of one model. Netgen measures against
    /// the mean, so its `2 tol / (2 - tol)` is this `tol`.
    param_tolerance: f64 = 0.02,
    /// Which parameters are `W`, `L`, `nf`, `m`, the diffusions...
    params: ParamNames = .{},
};

/// A reduced node `Traced.reference_mate` pairs with nothing.
pub const unpaired: u32 = std.math.maxInt(u32);

/// What `compareTraced` concluded.
pub const Traced = struct {
    verdict: Verdict = .match,
    /// A mismatch's discrepancies, in the verdict's order; empty otherwise.
    found: std.ArrayList(Discrepancy) = .empty,
    /// Every merge each side's reduction made; rows of the graphs given.
    layout_merges: Merges = .{},
    reference_merges: Merges = .{},
    /// CSR: the rows of the reference graph given that reduced reference
    /// device `d`, the row a `Discrepancy` names, stands for, ascending. A
    /// row the deck's `lvs ignore` left out is in none.
    reference_row_start: std.ArrayList(u32) = .empty,
    reference_row: std.ArrayList(u32) = .empty,
    /// The same for each reduced layout device: rows of the layout graph
    /// given, a row `lvs filter_unused` or `lvs ignore` left out in none.
    layout_row_start: std.ArrayList(u32) = .empty,
    layout_row: std.ArrayList(u32) = .empty,
    /// Each reduced net's row in the graph given, per side.
    reference_net_origin: std.ArrayList(u32) = .empty,
    layout_net_origin: std.ArrayList(u32) = .empty,
    /// The pairing the verdict read: reduced reference node `n` (devices,
    /// then nets at `deviceCount() + net`) pairs with reduced layout node
    /// `reference_mate[n]` (numbered alike), or `unpaired`. Empty when the
    /// comparison did not conclude.
    reference_mate: std.ArrayList(u32) = .empty,

    pub fn deinit(t: *Traced, gpa: Allocator) void {
        inline for (@typeInfo(Traced).@"struct".field_names) |f| if (comptime !std.mem.eql(u8, f, "verdict")) @field(t, f).deinit(gpa);
    }

    pub fn referenceRowsOf(t: *const Traced, device: u32) []const u32 {
        return t.reference_row.items[t.reference_row_start.items[device]..t.reference_row_start.items[device + 1]];
    }

    pub fn layoutRowsOf(t: *const Traced, device: u32) []const u32 {
        return t.layout_row.items[t.layout_row_start.items[device]..t.layout_row_start.items[device + 1]];
    }
};

/// `compareTraced`'s working tables, dead on return.
const Work = struct {
    ports: std.ArrayList(StrId) = .empty,
    declared: Graph = .{},
    measured: Graph = .{},
    layout: Graph = .{},
    reference: Graph = .{},
    ref_kept: std.ArrayList(u32) = .empty,
    filter_kept: std.ArrayList(u32) = .empty,
    ignore_kept: std.ArrayList(u32) = .empty,
    seeds: std.ArrayList(u32) = .empty,
    partition: Partition = .{},

    fn deinit(w: *Work, gpa: Allocator) void {
        inline for (@typeInfo(Work).@"struct".field_names) |f| @field(w, f).deinit(gpa);
    }
};

/// Compares the extracted `layout` against one `reference` subcircuit, as
/// the lvs module header describes, into `out` (cleared and refilled).
pub fn compareTraced(gpa: Allocator, layout: *const Graph, reference: *const Graph, options_in: CompareOptions, controls: *const LvsControls, out: *Traced) Allocator.Error!void {
    layout.assertValid();
    reference.assertValid();
    var options = options_in;
    options.params.relaxed = options.params.relaxed or controls.relaxed;
    options.params.gates = options.params.gates or controls.recognize_gates;
    out.verdict = .match;
    out.found.clearRetainingCapacity();
    out.reference_mate.clearRetainingCapacity();
    const names = options.params;
    const values: [2]?StrId = .{ names.values[0], names.values[1] };
    var w: Work = .{};
    defer w.deinit(gpa);

    // The reference's own ports, before a label makes another net a port.
    if (controls.ports_by_name) try controls_mod.portNamesInto(gpa, reference, &w.ports);
    w.declared = try reference.clone(gpa);
    try identityInto(gpa, reference.netCount(), &w.declared.net_origin);
    try prepare.dropUnextractedBulk(gpa, layout, &w.declared);
    const ref_dropped = try retain.dropIgnoredDevices(gpa, &w.declared, controls, values, &w.ref_kept);
    prepare.sortStressPair(&w.declared, names.stress);
    try prepare.protectLabelled(gpa, layout, &w.declared);
    w.measured = try layout.clone(gpa);
    try identityInto(gpa, layout.netCount(), &w.measured.net_origin);
    // Unused transistors are judged as drawn, before anything else leaves;
    // a threshold reads the layout's own value, so devices go before measures.
    const filtered = try retain.filterUnused(gpa, &w.measured, controls, &w.filter_kept);
    const ignored = try retain.dropIgnoredDevices(gpa, &w.measured, controls, values, &w.ignore_kept);
    try prepare.keepDeclaredParams(gpa, reference, &w.measured);
    try retain.dropIgnoredParams(gpa, &w.measured, controls);
    try retain.dropIgnoredParams(gpa, &w.declared, controls);
    try controls_mod.assignRoles(gpa, &w.measured, controls);
    try controls_mod.assignRoles(gpa, &w.declared, controls);
    if (controls.split_gates) {
        try split.joinSplitGates(gpa, &w.measured, names.length);
        try split.joinSplitGates(gpa, &w.declared, names.length);
    }
    try reduce.reduceWith(gpa, &w.measured, names, &w.layout, &out.layout_merges);
    try reduce.reduceWith(gpa, &w.declared, names, &w.reference, &out.reference_merges);
    // Merge rows back to the rows given: through the ignore drop, then the filter.
    if (ignored) retain.restoreRows(out.layout_merges.device.items, w.ignore_kept.items);
    if (filtered) retain.restoreRows(out.layout_merges.device.items, w.filter_kept.items);
    if (ref_dropped) retain.restoreRows(out.reference_merges.device.items, w.ref_kept.items);
    try originInto(gpa, reference.deviceCount(), if (ref_dropped) w.ref_kept.items else null, &out.reference_merges, &out.reference_row_start, &out.reference_row);
    assert(out.reference_row_start.items.len == @as(usize, w.reference.deviceCount()) + 1);
    // The layout's kept rows through both drops: the ignore drop's rows are
    // rows of the filter's output.
    if (ignored and filtered) retain.restoreRows(w.ignore_kept.items, w.filter_kept.items);
    const layout_kept: ?[]const u32 = if (ignored) w.ignore_kept.items else if (filtered) w.filter_kept.items else null;
    try originInto(gpa, layout.deviceCount(), layout_kept, &out.layout_merges, &out.layout_row_start, &out.layout_row);
    assert(out.layout_row_start.items.len == @as(usize, w.layout.deviceCount()) + 1);
    for ([_]*std.ArrayList(u32){ &out.reference_net_origin, &out.layout_net_origin }, [_]*const Graph{ &w.reference, &w.layout }) |origin, g| {
        origin.clearRetainingCapacity();
        try origin.appendSlice(gpa, g.net_origin.items);
    }
    // Reduction returns graphs that keep the invariants refinement reads.
    w.layout.assertValid();
    w.reference.assertValid();
    if (names.multiplier) |m| {
        try prepare.stateCount(gpa, &w.layout, m);
        try prepare.stateCount(gpa, &w.reference, m);
    }
    if (controls.ports_by_name or controls.same_nets.len != 0) {
        try controls_mod.portSeedsInto(gpa, &w.layout, &w.reference, w.ports.items, controls.same_nets, &w.seeds);
    }
    if (!try refine.refineInto(gpa, &w.layout, &w.reference, options.max_rounds, options.param_tolerance, names, controls, w.seeds.items, false, &w.partition)) {
        out.verdict = .{ .inconclusive = .round_limit };
        return;
    }
    out.verdict = try interpretInto(gpa, &w.layout, &w.reference, &w.partition, options.param_tolerance, names, controls, &out.found, &out.reference_mate);
    if (out.verdict == .mismatch and unpairedOnBothSides(out.found.items)) {
        try modelsAside(gpa, &w, options, controls, out);
    }
    if (out.verdict == .mismatch) controls_mod.reportRoles(out.found.items, &w.reference, controls);
}

// ---- private ----

/// The given rows each reduced device of one side stands for, CSR into
/// `start` and `rows`: the `kept` rows (every one of `devices` when null)
/// grouped by the merges that joined them, in the order `reduceWith` emits
/// its groups.
fn originInto(gpa: Allocator, devices: u32, kept: ?[]const u32, merges: *const Merges, start: *std.ArrayList(u32), out: *std.ArrayList(u32)) Allocator.Error!void {
    const root = try gpa.alloc(u32, devices);
    defer gpa.free(root);
    for (root, 0..) |*r, d| r.* = @intCast(d);
    for (0..merges.len()) |m| {
        const rows = merges.devicesOf(@intCast(m));
        if (rows.len == 0) continue;
        for (rows[1..]) |row| graph.join(root, rows[0], row);
    }
    const rows = kept orelse root_rows: {
        const all = try gpa.alloc(u32, devices);
        for (all, 0..) |*r, d| r.* = @intCast(d);
        break :root_rows all;
    };
    defer if (kept == null) gpa.free(rows);
    try graph.groupsByRootInto(gpa, root, rows, start, out);
}

/// `0, 1, .., n - 1` into `out`.
fn identityInto(gpa: Allocator, n: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (0..n) |i| try out.append(gpa, @intCast(i));
}

/// An unpaired device on each side: what a device whose model alone
/// differs leaves, since refinement starts different models apart.
fn unpairedOnBothSides(found: []const Discrepancy) bool {
    var sides: [2]bool = .{ false, false };
    for (found) |d| switch (d) {
        .unpaired_device => |u| sides[@backingInt(u.side)] = true,
        .unpaired_net, .terminal_mismatch, .parameter_mismatch, .undeclared_param, .model_mismatch, .class_imbalance => {},
    };
    return sides[0] and sides[1];
}

/// The comparison again with devices of one kind in one class, models
/// aside. When that pairs every node and the only differences are pairs of
/// different models, those pairs replace the report, each a
/// `model_mismatch` (catalog LVS-013, KLayout's "identified but have
/// different device classes"). Either way the verdict is a mismatch.
fn modelsAside(gpa: Allocator, w: *Work, options: CompareOptions, controls: *const LvsControls, out: *Traced) Allocator.Error!void {
    var partition: Partition = .{};
    defer partition.deinit(gpa);
    if (!try refine.refineInto(gpa, &w.layout, &w.reference, options.max_rounds, options.param_tolerance, options.params, controls, w.seeds.items, true, &partition)) return;
    var found: std.ArrayList(Discrepancy) = .empty;
    defer found.deinit(gpa);
    const v = try interpretInto(gpa, &w.layout, &w.reference, &partition, options.param_tolerance, options.params, controls, &found, null);
    if (v != .mismatch) return;
    for (found.items) |d| if (d != .model_mismatch) return;
    std.mem.swap(std.ArrayList(Discrepancy), &out.found, &found);
}
