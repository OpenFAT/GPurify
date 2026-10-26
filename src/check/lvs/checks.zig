//! The layout-only LVS checks, which need no reference: floating nets,
//! label conflicts, named shorts and their paths, unbindable markers and
//! terminal counts. In: the unreduced layout graph, the extracted design and
//! its ports. Out: five `RuleRun`s (a sixth, `lvs.short_path`, after
//! `lvs.net_seed_conflict` when a net carries two names) and their error
//! rows appended to `Violations`. A row on a shape is located at its first
//! vertex on its layer. Ported from crates/check/src/lvs/checks.rs
//! (`check_layout`, `check_floating_nets`, `check_label_conflicts`,
//! `check_net_seed_conflicts`, `check_topology`).
//!
//! Contents:
//! - `pub fn checkLayout(gpa: Allocator, layout: *const Graph, design: Design, ports: *const PortTable, strings: *const StrTable, controls: *const LvsControls, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`
//! - `pub fn checkNetSeedConflicts(gpa: Allocator, design: Design, ports: *const PortTable, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const PolyId = geom.PolyId;
const LvsControls = @import("ingest").deck.LvsControls;
const report = @import("../report.zig");
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const NetId = @import("../topology/net.zig").NetId;
const PortTable = @import("../topology/port.zig").PortTable;
const Graph = @import("graph.zig").Graph;
const Design = @import("project.zig").Design;
const mustConnect = @import("retain.zig").mustConnect;
const records = @import("records.zig");
const graphViolation = records.graphViolation;
const onFirstShape = records.onFirstShape;

/// Legal terminal counts per device kind as a bitmask indexed by count;
/// rows past the inductor (a black box) admit nothing.
const legal_widths = [8]u32{ (1 << 3) | (1 << 4), 1 << 3, 1 << 2, 1 << 2, 1 << 2, 1 << 2, 0, 0 };

/// The full terminal count each kind is reported against.
const full_widths = [8]u32{ 4, 3, 2, 2, 2, 2, 0, 0 };

/// Runs the layout-only checks; `layout` must be `fromLayoutInto` of the
/// same design and ports. Rows, in order:
/// - `lvs.floating_net` (LVS-006): a net no terminal lands on, other than a
///   labelled one or one of global-layer shapes alone; on its lowest
///   polygon, measured 0 against 1; examines every net.
/// - `lvs.label_conflict` (LVS-001, LVS-002): one label on several nets, a
///   row per consecutive pair, on the lowest polygon carrying it on each,
///   measured 2 against 1; a warning when the label is must-connect.
/// - `lvs.net_seed_conflict` (LVS-001, LVS-005) and its `lvs.short_path`:
///   `checkNetSeedConflicts`.
/// - `lvs.terminal_net` (LVS-004): a marker no recogniser could bind,
///   measured terminals bound against listed; or a graph terminal on no net
///   or past the table, measured the net count against what it needs.
/// - `lvs.terminal_count` (LVS-004): a terminal count the kind does not
///   allow (MOS 3 or 4, BJT 3, two-pin kinds 2), measured against the full
///   count; refused when the terminal CSR is not one run per device.
pub fn checkLayout(gpa: Allocator, layout: *const Graph, design: Design, ports: *const PortTable, strings: *const StrTable, controls: *const LvsControls, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    try checkFloatingNets(gpa, design, ports, report.ruleId(strings, "lvs.floating_net"), out, runs);
    try checkLabelConflicts(gpa, design, ports, strings, controls, out, runs);
    try checkNetSeedConflicts(gpa, design, ports, strings, out, runs);
    try checkTopology(gpa, layout, design, strings, out, runs);
}

/// The `lvs.net_seed_conflict` row alone: several labels on one net, a short
/// between named nets, a row per consecutive pair of names in `StrId`
/// order on the lowest polygon carrying each, measured 2 against 1. Where
/// any, `lvs.short_path` follows: per pair, the fewest polygons joining the
/// two labelled shapes (`NetTable.pathInto`), one row per step, measured the
/// step against the step count; two labels on one polygon are one row
/// measured 1 against 1 (Calibre's `LVS ISOLATE SHORTS`, ICV's
/// `ShortFinder`; catalog LVS-005). Refused when a path cannot be traced.
/// The engine calls it alone when `checkLayout` does not run.
pub fn checkNetSeedConflicts(gpa: Allocator, design: Design, ports: *const PortTable, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const rule = report.ruleId(strings, "lvs.net_seed_conflict");
    const before = out.len();
    const nets = ports.net.items;
    const polys = ports.poly.items;
    var shorts: std.ArrayList([2]PolyId) = .empty;
    defer shorts.deinit(gpa);
    for (1..@max(nets.len, 1)) |at| {
        if (nets[at] != nets[at - 1]) continue;
        try out.push(gpa, onFirstShape(design.store, graphViolation(rule, polys[at - 1], polys[at], 2, 1)));
        try shorts.append(gpa, .{ polys[at - 1], polys[at] });
    }
    try report.recordRun(gpa, runs, out, before, rule, .ran, ports.len());
    if (shorts.items.len == 0) return;
    const path_rule = report.ruleId(strings, "lvs.short_path");
    const path_before = out.len();
    var outcome: report.Outcome = .ran;
    var path: std.ArrayList(PolyId) = .empty;
    defer path.deinit(gpa);
    for (shorts.items) |s| {
        if (!try design.nets.pathInto(gpa, s[0], s[1], &path)) {
            outcome = .refused;
            continue;
        }
        const steps: u32 = @intCast(path.items.len - 1);
        if (steps == 0) try out.push(gpa, onFirstShape(design.store, graphViolation(path_rule, s[0], report.no_shape, 1, 1)));
        for (0..steps) |step| {
            const row = graphViolation(path_rule, path.items[step], path.items[step + 1], @intCast(step + 1), steps);
            try out.push(gpa, onFirstShape(design.store, row));
        }
    }
    try report.recordRun(gpa, runs, out, path_before, path_rule, outcome, shorts.items.len);
}

// ---- private ----

fn checkFloatingNets(gpa: Allocator, design: Design, ports: *const PortTable, rule: StrId, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const before = out.len();
    const count = design.nets.netCount();
    // A net's lowest polygon while still a candidate, `no_shape` once out.
    const lowest = try gpa.alloc(PolyId, count);
    defer gpa.free(lowest);
    for (lowest, 0..) |*slot, n| {
        const net: NetId = @fromBackingInt(@intCast(n));
        const polys = design.nets.polysOf(net);
        const named = ports.nameOf(net) != null or design.nets.isGlobalOnly(net);
        slot.* = if (named or polys.len == 0) report.no_shape else polys[0];
    }
    for (design.devices.terminal_net.items) |n| lowest[@backingInt(n)] = report.no_shape;
    for (lowest) |poly| {
        if (poly != report.no_shape) try out.push(gpa, onFirstShape(design.store, graphViolation(rule, poly, report.no_shape, 0, 1)));
    }
    try report.recordRun(gpa, runs, out, before, rule, .ran, count);
}

/// One label on two nets: reported, never resolved.
fn checkLabelConflicts(gpa: Allocator, design: Design, ports: *const PortTable, strings: *const StrTable, controls: *const LvsControls, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const rule = report.ruleId(strings, "lvs.label_conflict");
    const before = out.len();
    // Every binding, so a name a short hides behind another is still seen.
    const names = ports.by_name.items;
    const named = ports.by_name_net.items;
    for (1..@max(names.len, 1)) |at| {
        if (names[at] != names[at - 1]) continue;
        var row = graphViolation(rule, labelled(ports, named[at - 1], names[at]), labelled(ports, named[at], names[at]), 2, 1);
        if (mustConnect(names[at], strings, controls)) row.severity = .warning;
        try out.push(gpa, onFirstShape(design.store, row));
    }
    try report.recordRun(gpa, runs, out, before, rule, .ran, design.nets.netCount());
}

/// A terminal on no net, a refused marker, a terminal count its kind does
/// not allow; a graph with devices but no terminal CSR is refused.
fn checkTopology(gpa: Allocator, g: *const Graph, design: Design, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const terminal_net = report.ruleId(strings, "lvs.terminal_net");
    const terminal_count = report.ruleId(strings, "lvs.terminal_count");
    const devices = g.device_kind.items.len;
    const net_count = g.netCount();
    var before = out.len();
    // No net is `maxInt(u32)`, so "no net" and "past the table" are one test;
    // the limit saturates.
    for (g.terminal_net.items) |n| {
        if (n >= net_count) try out.push(gpa, graphViolation(terminal_net, report.no_shape, report.no_shape, net_count, n +| 1));
    }
    const refused = design.devices;
    for (refused.refused_marker.items, refused.refused_bound.items, refused.refused_listed.items) |marker, bound, listed| {
        try out.push(gpa, onFirstShape(design.store, graphViolation(terminal_net, marker, report.no_shape, bound, listed)));
    }
    try report.recordRun(gpa, runs, out, before, terminal_net, .ran, g.terminal_net.items.len + refused.refused_marker.items.len);

    before = out.len();
    const starts = g.device_terminal_start.items;
    if (starts.len -| 1 != devices or (starts.len == 0 and devices != 0)) {
        try report.recordRun(gpa, runs, out, before, terminal_count, .refused, 0);
        return;
    }
    for (g.device_kind.items, 0..) |kind, d| {
        const count = starts[d + 1] - starts[d];
        const k = @backingInt(kind) & 7;
        // A count past 31 clamps onto bit 31, which no kind sets.
        if ((legal_widths[k] >> @intCast(@min(count, 31))) & 1 == 0) {
            try out.push(gpa, graphViolation(terminal_count, report.no_shape, report.no_shape, count, full_widths[k]));
        }
    }
    try report.recordRun(gpa, runs, out, before, terminal_count, .ran, devices);
}

/// The lowest polygon carrying label `name` on `net`, which `ports` binds.
fn labelled(ports: *const PortTable, net: NetId, name: StrId) PolyId {
    const nets = ports.net.items;
    var from: usize = 0;
    while (from < nets.len and @backingInt(nets[from]) < @backingInt(net)) from += 1;
    var at = from;
    while (at < nets.len and nets[at] == net and @backingInt(ports.name.items[at]) < @backingInt(name)) at += 1;
    return ports.poly.items[at];
}
