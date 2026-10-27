//! The text report, for a human. In: the rule records, the violation rows,
//! what LVS merged and concluded, and the run summary. Out: the lines the
//! CLI prints by default, in that order. Ported from src/cli/format.rs.
//!
//! Each section is its own call, so the engine (wave 5) calls them in
//! order: `writeRuns`, `writeViolations`, `writeMerges`, `writeVerdict`,
//! `writeSummary`, Rust's `write_violations` then `write_summary`. Numbers
//! are Rust's `{}` (geom.float). The LVS verdict is one plain sentence per
//! discrepancy, names resolved, where Rust printed its `{:?}`. `Summary` and `StageStatus` are the minimal shape the
//! summary prints; the engine fills them. Rust's `write_error` (an error's
//! cause chain) stays with the CLI: a Zig error has no chain.
//!
//! Contents:
//! - `pub const StageStatus = union(enum) { ran, not_selected, skipped: []const u8, refused: []const u8 }`
//! - `pub const Domain = enum { drc, erc, lvs, pex }`
//! - `pub const Summary = struct`, `Summary.passed(s: Summary) bool`
//! - `pub fn writeRuns(w: *std.Io.Writer, strings: *const StrTable, runs: []const RuleRun) std.Io.Writer.Error!void`
//! - `pub fn writeViolations(w: *std.Io.Writer, strings: *const StrTable, layers: *const LayerTable, grid: Grid, violations: *const Violations, waived: *const Violations) std.Io.Writer.Error!void`
//! - `pub fn writeMerges(w: *std.Io.Writer, strings: *const StrTable, placements: []const Placement, unpaired: []const UnpairedInstance, layout_merges: *const Merges, reference_merges: *const Merges) std.Io.Writer.Error!void`
//! - `pub fn writeVerdict(w: *std.Io.Writer, strings: *const StrTable, verdict: ?Verdict, found: []const Discrepancy) std.Io.Writer.Error!void`
//! - `pub fn writeSummary(w: *std.Io.Writer, summary: Summary) std.Io.Writer.Error!void`

const std = @import("std");
const Writer = std.Io.Writer;
const geom = @import("geom");
const Grid = geom.Grid;
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const Placement = ingest.netlist.Placement;
const LayerTable = ingest.deck.LayerTable;
const check = @import("check");
const report = check.report;
const Measurement = report.Measurement;
const RuleRun = report.RuleRun;
const Violations = report.Violations;
const lvs = check.lvs;
const Merges = lvs.Merges;
const UnpairedInstance = lvs.UnpairedInstance;
const Verdict = lvs.verdict.Verdict;
const Discrepancy = lvs.verdict.Discrepancy;
const float = geom.float;
const assert = std.debug.assert;

/// Whether a stage ran; a skip or refusal carries its reason.
pub const StageStatus = union(enum) {
    ran,
    not_selected,
    /// A required input was absent.
    skipped: []const u8,
    /// The input is outside what the tool represents exactly.
    refused: []const u8,
};

/// The stage a rule run belongs to, one per `Summary` stage.
pub const Domain = enum { drc, erc, lvs, pex };

/// The run at a glance; `0 violations` without `rules_skipped` is a false
/// clean, so both print.
pub const Summary = struct {
    drc: StageStatus,
    erc: StageStatus,
    lvs: StageStatus,
    pex: StageStatus,
    violations: u32,
    errors: u32,
    warnings: u32,
    rules_clean: u32,
    rules_skipped: u32,

    /// The pass criterion: no errors, no skipped rule, and no selected stage
    /// skipped or refused; warnings and stages not selected do not fail it.
    /// The CLI exits 0 only when this holds.
    pub fn passed(s: Summary) bool {
        for ([_]StageStatus{ s.drc, s.erc, s.lvs, s.pex }) |st| switch (st) {
            .ran, .not_selected => {},
            .skipped, .refused => return false,
        };
        return s.errors == 0 and s.rules_skipped == 0;
    }
};

/// The rule records, even when clean: they tell "ran, found nothing" from
/// "never ran".
pub fn writeRuns(w: *Writer, strings: *const StrTable, runs: []const RuleRun) Writer.Error!void {
    try w.writeAll("rules:\n");
    if (runs.len == 0) try w.writeAll("  none recorded — nothing was checked\n");
    for (runs) |run| {
        try w.print("  {s}: ", .{strings.resolve(run.rule)});
        switch (run.outcome) {
            .ran => try w.writeAll("ran"),
            .refused => try w.writeAll("refused"),
            .skipped => |why| try w.print("skipped, {s}", .{switch (why) {
                .no_design_intent => "no design intent was supplied",
                .not_in_deck => "the deck does not configure this rule",
                .empty_layer => "the layer it names holds no geometry",
                .earlier_stage => "an earlier stage of the deck found errors; fix those first",
            }}),
        }
        try w.print(", examined {d} shapes, found {d} violations\n", .{ run.examined, run.violations });
    }
}

/// The violation count and one line per row, then the waived rows only
/// when there are any. A row's layer prints as `layers` names it, the
/// deck's name for a drawn or derived layer and the hidden name of an
/// inner one (`x#1`, `<rule id>@k`). A row on no layer (`report.no_layer`,
/// an LVS or system finding) has no `layer` clause, and a row on no shape
/// (`report.no_shape`) no `on shape` clause. A short's row names its two
/// labels (`labels VDD and VSS`). `layers` is the run's deck's
/// table; a run with no one deck (a system) passes an empty one. Asserts
/// that every row's layer is in `layers` or is `report.no_layer`.
pub fn writeViolations(w: *Writer, strings: *const StrTable, layers: *const LayerTable, grid: Grid, violations: *const Violations, waived: *const Violations) Writer.Error!void {
    try w.print("violations: {d}\n", .{violations.len()});
    try writeRows(w, strings, layers, grid, violations);
    if (waived.len() > 0) {
        try w.print("waived: {d}\n", .{waived.len()});
        try writeRows(w, strings, layers, grid, waived);
    }
}

/// The reference instances a mismatch left unpaired, then every merge LVS
/// made, layout's first, so a paired device traces back to its rows.
pub fn writeMerges(w: *Writer, strings: *const StrTable, placements: []const Placement, unpaired: []const UnpairedInstance, layout_merges: *const Merges, reference_merges: *const Merges) Writer.Error!void {
    if (unpaired.len > 0) try w.writeAll("lvs unpaired instances:\n");
    for (unpaired) |u| {
        const p = placements[u.placement];
        try w.print("  {s} ({s}): none of its {d} devices has a partner in the layout\n", .{ strings.resolve(p.path), strings.resolve(p.cell), u.devices });
    }
    if (layout_merges.len() + reference_merges.len() > 0) try w.writeAll("lvs merges:\n");
    for ([_]*const Merges{ layout_merges, reference_merges }, [_][]const u8{ "layout", "reference" }) |merges, side| {
        for (0..merges.len()) |i| {
            const merge: u32 = @intCast(i);
            const rows = merges.devicesOf(merge);
            try w.print("  {s} {t}: {d} devices of {s} (", .{ side, merges.kind.items[merge], rows.len, strings.resolve(merges.model.items[merge]) });
            for (rows, 0..) |row, k| try w.print("{s}{d}", .{ if (k > 0) ", " else "", row });
            try w.writeAll(") are one\n");
        }
    }
}

/// `lvs: ` and the verdict, when LVS compared: `match`, `inconclusive, <why>`,
/// or `mismatch, <n> discrepancies:` then one indented sentence per entry
/// of `found` (already error rows above). Devices and nets are their
/// netlist's indices; every name prints bare as `strings` resolves it, and
/// a net with no name as `unnamed`.
pub fn writeVerdict(w: *Writer, strings: *const StrTable, verdict: ?Verdict, found: []const Discrepancy) Writer.Error!void {
    const v = verdict orelse return;
    try w.writeAll("lvs: ");
    switch (v) {
        .match => try w.writeAll("match\n"),
        .inconclusive => |why| try w.print("inconclusive, {s}\n", .{switch (why) {
            .round_limit => "refinement kept splitting a class past its round limit",
            .ambiguous_top => "the reference has no unique top subcircuit",
        }}),
        .mismatch => {
            // A mismatch always names what differs (verdict.zig's `Verdict`).
            assert(found.len > 0);
            try w.print("mismatch, {d} discrepancies:\n", .{found.len});
            for (found) |d| try writeDiscrepancy(w, strings, d);
        },
    }
}

/// The stage lines, then skipped before clean before the count.
pub fn writeSummary(w: *Writer, summary: Summary) Writer.Error!void {
    try w.writeAll("summary:\n");
    const stages = [_]struct { []const u8, StageStatus }{ .{ "drc", summary.drc }, .{ "erc", summary.erc }, .{ "lvs", summary.lvs }, .{ "pex", summary.pex } };
    for (stages) |stage| {
        try w.print("  {s}: ", .{stage[0]});
        switch (stage[1]) {
            .ran => try w.writeAll("ran\n"),
            .not_selected => try w.writeAll("not selected\n"),
            .skipped => |why| try w.print("skipped, {s}\n", .{why}),
            .refused => |why| try w.print("refused, {s}\n", .{why}),
        }
    }
    try w.print("  {d} rules skipped\n  {d} rules clean\n", .{ summary.rules_skipped, summary.rules_clean });
    try w.print("  {d} violations: {d} errors, {d} warnings\n", .{ summary.violations, summary.errors, summary.warnings });
}

// ---- private ----

fn writeRows(w: *Writer, strings: *const StrTable, layers: *const LayerTable, grid: Grid, v: *const Violations) Writer.Error!void {
    // The sentinel sits past every table, so it never reads as a name.
    assert(layers.len() <= @backingInt(report.no_layer));
    for (0..v.len()) |i| {
        const row: u32 = @intCast(i);
        const r = v.get(row);
        if (r.layer != report.no_layer) assert(@backingInt(r.layer) < layers.len());
        // A second shape is only ever the partner of a first.
        if (r.shape_a == report.no_shape) assert(r.shape_b == report.no_shape);
        try w.print("  {s} {s}", .{ strings.resolve(r.rule), @tagName(r.severity) });
        if (r.layer != report.no_layer) try w.print(" layer {s}", .{strings.resolve(layers.name(r.layer))});
        try w.writeAll(" at (");
        try float.display(w, grid.toLength(r.at.x).raw);
        try w.writeAll(" nm, ");
        try float.display(w, grid.toLength(r.at.y).raw);
        try w.writeAll(" nm) measured ");
        try writeMeasurement(w, grid, r.measured);
        try w.writeAll(" against limit ");
        try writeMeasurement(w, grid, r.limit);
        if (r.shape_a != report.no_shape) try w.print(" on shape {d}", .{@backingInt(r.shape_a)});
        if (r.shape_b != report.no_shape) try w.print(" and shape {d}", .{@backingInt(r.shape_b)});
        if (v.labelsOf(row)) |names| try w.print(" labels {s} and {s}", .{ strings.resolve(names[0]), strings.resolve(names[1]) });
        if (v.loadOf(row)) |load| try w.print(" loaded most by {s} {s}", .{ strings.resolve(load.instance), strings.resolve(load.terminal) });
        if (v.fixOf(row)) |fix| {
            try w.writeAll(" fix ");
            try writeMeasurement(w, grid, fix);
        }
        try w.writeByte('\n');
    }
}

/// Lengths in `nm` and areas in `nm^2` through the grid; the rest as Rust's
/// `Measurement` Display: a ratio or count bare, `mV`, `uA`, `ohm`.
fn writeMeasurement(w: *Writer, grid: Grid, m: Measurement) Writer.Error!void {
    switch (m.kind) {
        .length => {
            try float.display(w, grid.toLength(@intCast(m.raw)).raw);
            try w.writeAll(" nm");
        },
        .area => {
            const per_dbu = grid.toLength(1).raw;
            try float.display(w, @as(f64, @floatFromInt(m.raw)) * per_dbu * per_dbu);
            try w.writeAll(" nm^2");
        },
        .count => try w.print("{d}", .{m.raw}),
        .ratio => try float.display(w, m.float()),
        .voltage, .current, .resistance => {
            try float.display(w, m.float());
            try w.writeAll(switch (m.kind) {
                .voltage => " mV",
                .current => " uA",
                else => " ohm",
            });
        },
    }
}

/// One discrepancy as an indented sentence, as `writeVerdict` documents.
fn writeDiscrepancy(w: *Writer, strings: *const StrTable, d: Discrepancy) Writer.Error!void {
    try w.writeAll("  ");
    switch (d) {
        .unpaired_device => |u| try w.print("{t} device {d} ({s}) has no partner", .{ u.side, u.device, strings.resolve(u.model) }),
        .unpaired_net => |u| try w.print("{t} net {d} ({s}) has no partner", .{ u.side, u.net, if (u.name) |n| strings.resolve(n) else "unnamed" }),
        .terminal_mismatch => |t| {
            try w.print("layout device {d} and reference device {d} disagree on the net at ", .{ t.layout_device, t.ref_device });
            switch (t.role) {
                .pin => |k| try w.print("pin {d}", .{k}),
                else => try w.writeAll(@tagName(t.role)),
            }
        },
        .parameter_mismatch => |p| {
            try w.print("layout device {d} and reference device {d} differ in {s}: ", .{ p.layout_device, p.ref_device, strings.resolve(p.param) });
            try float.display(w, p.layout_value);
            try w.writeAll(" against ");
            try float.display(w, p.ref_value);
        },
        .undeclared_param => |u| {
            // Only the reference states a parameter the layout lacks (verdict.zig).
            assert(u.side == .reference);
            try w.print("reference device {d} states {s}, which layout device {d} does not measure", .{ u.ref_device, strings.resolve(u.param), u.layout_device });
        },
        .model_mismatch => |m| try w.print("layout device {d} and reference device {d} differ in model: {s} against {s}", .{ m.layout_device, m.ref_device, strings.resolve(m.layout_model), strings.resolve(m.ref_model) }),
        .class_imbalance => |c| try w.print("a class holds {d} layout nodes against {d} reference nodes", .{ c.layout_nodes, c.ref_nodes }),
    }
    try w.writeByte('\n');
}

test "a run renders to this exact text" {
    // Oracle: golden, written by hand in the format
    // docs/src/reference/report.md (Text report) shows, with the units
    // converted by hand: on a 2000 dbu/um grid (4200, 8600) is (2100 nm, 4300
    // nm), 4 dbu is 2 nm and 48 dbu^2 is 12 nm^2. Rust's row measured a length
    // against an area, which a Zig row (one kind per row) cannot hold, so the
    // area moved to a waived row with a fix hint, the two paths Rust's test
    // left out. Layer names: id 3 is the fourth entry the table was built from,
    // `met1`; the waived row is on `report.no_layer` and `report.no_shape`, so
    // the doc says its line has neither a layer nor a shape clause; its labels,
    // as a short's row carries them, print by name.
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var entries: [4]LayerTable.Entry = undefined;
    for (&entries, [_][]const u8{ "diff", "poly", "li1", "met1" }, 0..) |*e, name, k| e.* = .{ .name = try strings.intern(gpa, name), .layer = @intCast(k), .datatype = 0 };
    const layers = try LayerTable.build(arena.allocator(), &entries);
    const width = try strings.intern(gpa, "m1_min_width");
    const antenna = try strings.intern(gpa, "antenna_ratio");
    const runs = [_]RuleRun{
        .{ .rule = width, .outcome = .ran, .examined = 4_231, .violations = 1 },
        .{ .rule = antenna, .outcome = .{ .skipped = .no_design_intent }, .examined = 0, .violations = 0 },
    };
    var violations: Violations = .{};
    defer violations.deinit(gpa);
    try violations.push(gpa, .{ .rule = width, .layer = @fromBackingInt(3), .severity = .@"error", .at = .{ .x = 4_200, .y = 8_600 }, .measured = .length(4), .limit = .length(200), .shape_a = @fromBackingInt(7), .shape_b = @fromBackingInt(9) });
    var waived: Violations = .{};
    defer waived.deinit(gpa);
    try waived.push(gpa, .{ .rule = antenna, .layer = report.no_layer, .severity = .warning, .at = .{ .x = 1, .y = -3 }, .measured = .area(48), .limit = .area(40), .shape_a = report.no_shape, .shape_b = report.no_shape });
    try waived.setFix(gpa, 0, .area(8));
    try waived.setLabels(gpa, 0, .{ try strings.intern(gpa, "VDD"), try strings.intern(gpa, "VSS") });
    const summary: Summary = .{
        .drc = .ran,
        .erc = .{ .refused = "bad grid" },
        .lvs = .{ .skipped = "no reference netlist was supplied" },
        .pex = .not_selected,
        .violations = 1,
        .errors = 1,
        .warnings = 0,
        .rules_clean = 0,
        .rules_skipped = 1,
    };
    const grid = try Grid.init(2_000);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const no_merges: Merges = .{};
    try writeRuns(&out.writer, &strings, &runs);
    try writeViolations(&out.writer, &strings, &layers, grid, &violations, &waived);
    try writeMerges(&out.writer, &strings, &.{}, &.{}, &no_merges, &no_merges);
    try writeVerdict(&out.writer, &strings, null, &.{});
    try writeSummary(&out.writer, summary);
    try std.testing.expectEqualStrings(
        \\rules:
        \\  m1_min_width: ran, examined 4231 shapes, found 1 violations
        \\  antenna_ratio: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
        \\violations: 1
        \\  m1_min_width error layer met1 at (2100 nm, 4300 nm) measured 2 nm against limit 100 nm on shape 7 and shape 9
        \\waived: 1
        \\  antenna_ratio warning at (0.5 nm, -1.5 nm) measured 12 nm^2 against limit 10 nm^2 labels VDD and VSS fix 2 nm^2
        \\summary:
        \\  drc: ran
        \\  erc: refused, bad grid
        \\  lvs: skipped, no reference netlist was supplied
        \\  pex: not selected
        \\  1 rules skipped
        \\  0 rules clean
        \\  1 violations: 1 errors, 0 warnings
        \\
    , out.written());
}

test "the lvs merges and verdict render as plain sentences, names bare" {
    // Oracle: spec example, written by hand from each `Discrepancy` field's
    // doc (check/lvs/verdict.zig): every name id is the text it interns,
    // bare; a net with no name says `unnamed`; a role is its own word, a
    // passive's terminal `pin <k>`; no Debug form (`Some(`, `None`, quotes,
    // `Variant { .. }`) appears. The merge and instance lines are
    // format.rs's `writeln!` formats.
    const gpa = std.testing.allocator;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const nch = try strings.intern(gpa, "nch");
    const path = try strings.intern(gpa, "X1.X2");
    const cell = try strings.intern(gpa, "inv");
    const vdd = try strings.intern(gpa, "VDD");
    const w_param = try strings.intern(gpa, "w");
    const l_param = try strings.intern(gpa, "l");
    const pch = try strings.intern(gpa, "pch");
    var layout_merges: Merges = .{};
    defer layout_merges.deinit(gpa);
    try layout_merges.kind.append(gpa, .parallel);
    try layout_merges.model.append(gpa, nch);
    try layout_merges.device_start.appendSlice(gpa, &.{ 0, 3 });
    try layout_merges.device.appendSlice(gpa, &.{ 0, 4, 7 });
    var reference_merges: Merges = .{};
    defer reference_merges.deinit(gpa);
    try reference_merges.kind.append(gpa, .series);
    try reference_merges.model.append(gpa, nch);
    try reference_merges.device_start.appendSlice(gpa, &.{ 0, 2 });
    try reference_merges.device.appendSlice(gpa, &.{ 1, 2 });
    const placements = [_]Placement{.{ .path = path, .cell = cell, .devices = .{ 0, 2 } }};
    const unpaired = [_]UnpairedInstance{.{ .placement = 0, .devices = 2 }};
    const found = [_]Discrepancy{
        .{ .unpaired_device = .{ .side = .layout, .device = 3, .model = nch } },
        .{ .unpaired_net = .{ .side = .reference, .net = 2, .name = null } },
        .{ .unpaired_net = .{ .side = .layout, .net = 0, .name = vdd } },
        .{ .terminal_mismatch = .{ .layout_device = 1, .ref_device = 2, .role = .{ .pin = 1 } } },
        .{ .terminal_mismatch = .{ .layout_device = 1, .ref_device = 2, .role = .drain } },
        .{ .parameter_mismatch = .{ .layout_device = 0, .ref_device = 1, .param = w_param, .layout_value = 1e-6, .ref_value = 1.5 } },
        .{ .undeclared_param = .{ .side = .reference, .layout_device = 0, .ref_device = 1, .param = l_param } },
        .{ .model_mismatch = .{ .layout_device = 4, .ref_device = 5, .layout_model = nch, .ref_model = pch } },
        .{ .class_imbalance = .{ .layout_nodes = 2, .ref_nodes = 3 } },
    };
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeMerges(&out.writer, &strings, &placements, &unpaired, &layout_merges, &reference_merges);
    try writeVerdict(&out.writer, &strings, .mismatch, &found);
    try writeVerdict(&out.writer, &strings, .{ .inconclusive = .round_limit }, &.{});
    try writeVerdict(&out.writer, &strings, .match, &.{});
    try std.testing.expectEqualStrings(
        \\lvs unpaired instances:
        \\  X1.X2 (inv): none of its 2 devices has a partner in the layout
        \\lvs merges:
        \\  layout parallel: 3 devices of nch (0, 4, 7) are one
        \\  reference series: 2 devices of nch (1, 2) are one
        \\lvs: mismatch, 9 discrepancies:
        \\  layout device 3 (nch) has no partner
        \\  reference net 2 (unnamed) has no partner
        \\  layout net 0 (VDD) has no partner
        \\  layout device 1 and reference device 2 disagree on the net at pin 1
        \\  layout device 1 and reference device 2 disagree on the net at drain
        \\  layout device 0 and reference device 1 differ in w: 0.000001 against 1.5
        \\  reference device 1 states l, which layout device 0 does not measure
        \\  layout device 4 and reference device 5 differ in model: nch against pch
        \\  a class holds 2 layout nodes against 3 reference nodes
        \\lvs: inconclusive, refinement kept splitting a class past its round limit
        \\lvs: match
        \\
    , out.written());
}
