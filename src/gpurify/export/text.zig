//! The text report, for a human. In: the rule records, the violation rows,
//! what LVS merged and concluded, and the run summary. Out: the lines the
//! CLI prints by default, in that order. Ported from src/cli/format.rs.
//!
//! Each section is its own call, so the engine (wave 5) calls them in
//! order: `writeRuns`, `writeViolations`, `writeMerges`, `writeVerdict`,
//! `writeSummary`, Rust's `write_violations` then `write_summary`. Numbers
//! are Rust's `{}` (geom.float); the LVS verdict is Rust's `{:?}` of it,
//! raw ids included. `Summary` and `StageStatus` are the minimal shape the
//! summary prints; the engine fills them. Rust's `write_error` (an error's
//! cause chain) stays with the CLI: a Zig error has no chain.
//!
//! Contents:
//! - `pub const StageStatus = union(enum) { ran, not_selected, skipped: []const u8, refused: []const u8 }`
//! - `pub const Summary = struct`, `Summary.passed(s: Summary) bool`
//! - `pub fn writeRuns(w: *std.Io.Writer, strings: *const StrTable, runs: []const RuleRun) std.Io.Writer.Error!void`
//! - `pub fn writeViolations(w: *std.Io.Writer, strings: *const StrTable, grid: Grid, violations: *const Violations, waived: *const Violations) std.Io.Writer.Error!void`
//! - `pub fn writeMerges(w: *std.Io.Writer, strings: *const StrTable, placements: []const Placement, unpaired: []const UnpairedInstance, layout_merges: *const Merges, reference_merges: *const Merges) std.Io.Writer.Error!void`
//! - `pub fn writeVerdict(w: *std.Io.Writer, verdict: ?Verdict, found: []const Discrepancy) std.Io.Writer.Error!void`
//! - `pub fn writeSummary(w: *std.Io.Writer, summary: Summary) std.Io.Writer.Error!void`

const std = @import("std");
const Writer = std.Io.Writer;
const geom = @import("geom");
const Grid = geom.Grid;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const Placement = @import("ingest").netlist.Placement;
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

/// Whether a stage ran; a skip or refusal carries its reason.
pub const StageStatus = union(enum) {
    ran,
    not_selected,
    /// A required input was absent.
    skipped: []const u8,
    /// The input is outside what the tool represents exactly.
    refused: []const u8,
};

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
/// when there are any.
pub fn writeViolations(w: *Writer, strings: *const StrTable, grid: Grid, violations: *const Violations, waived: *const Violations) Writer.Error!void {
    try w.print("violations: {d}\n", .{violations.len()});
    try writeRows(w, strings, grid, violations);
    if (waived.len() > 0) {
        try w.print("waived: {d}\n", .{waived.len()});
        try writeRows(w, strings, grid, waived);
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

/// `lvs: ` and Rust's `{:?}` of the verdict, when LVS compared; a
/// mismatch's `found` are already error rows above.
pub fn writeVerdict(w: *Writer, verdict: ?Verdict, found: []const Discrepancy) Writer.Error!void {
    const v = verdict orelse return;
    try w.writeAll("lvs: ");
    switch (v) {
        .match => try w.writeAll("Match"),
        .inconclusive => |why| try w.print("Inconclusive({s})", .{pascal(why)}),
        .mismatch => {
            try w.writeAll("Mismatch([");
            for (found, 0..) |d, i| {
                if (i > 0) try w.writeAll(", ");
                try writeDiscrepancy(w, d);
            }
            try w.writeAll("])");
        },
    }
    try w.writeByte('\n');
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

fn writeRows(w: *Writer, strings: *const StrTable, grid: Grid, v: *const Violations) Writer.Error!void {
    for (0..v.len()) |i| {
        const row: u32 = @intCast(i);
        const r = v.get(row);
        try w.print("  {s} {s} layer {d} at (", .{ strings.resolve(r.rule), @tagName(r.severity), @backingInt(r.layer) });
        try float.display(w, grid.toLength(r.at.x).raw);
        try w.writeAll(" nm, ");
        try float.display(w, grid.toLength(r.at.y).raw);
        try w.writeAll(" nm) measured ");
        try writeMeasurement(w, grid, r.measured);
        try w.writeAll(" against limit ");
        try writeMeasurement(w, grid, r.limit);
        try w.print(" on shape {d}", .{@backingInt(r.shape_a)});
        if (r.shape_b != report.no_shape) try w.print(" and shape {d}", .{@backingInt(r.shape_b)});
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

/// One discrepancy as Rust's derived `Debug`: `Variant { field: value, … }`.
fn writeDiscrepancy(w: *Writer, d: Discrepancy) Writer.Error!void {
    switch (d) {
        inline else => |payload, tag| {
            try w.print("{s} {{ ", .{comptime pascal(tag)});
            inline for (@typeInfo(@TypeOf(payload)).@"struct".field_names, 0..) |name, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}: ", .{name});
                try writeDebugValue(w, @field(payload, name));
            }
            try w.writeAll(" }");
        },
    }
}

fn writeDebugValue(w: *Writer, value: anytype) Writer.Error!void {
    switch (@TypeOf(value)) {
        u32 => try w.print("{d}", .{value}),
        f64 => try float.debug(w, value),
        StrId => try w.print("StrId({d})", .{@backingInt(value)}),
        ?StrId => if (value) |id| try w.print("Some(StrId({d}))", .{@backingInt(id)}) else try w.writeAll("None"),
        lvs.verdict.Side => try w.writeAll(pascal(value)),
        check.topology.TerminalRole => switch (value) {
            .pin => |position| try w.print("Pin({d})", .{position}),
            inline else => |_, tag| try w.writeAll(comptime pascal(tag)),
        },
        else => @compileError("no Debug form for " ++ @typeName(@TypeOf(value))),
    }
}

/// An enum tag as its Rust variant: `round_limit` is `RoundLimit`.
fn pascal(tag: anytype) []const u8 {
    switch (tag) {
        inline else => |t| return comptime blk: {
            const name = @tagName(t);
            var out: []const u8 = "";
            var up = true;
            for (name) |c| {
                if (c == '_') {
                    up = true;
                    continue;
                }
                out = out ++ .{if (up) std.ascii.toUpper(c) else c};
                up = false;
            }
            break :blk out;
        },
    }
}

test "a run renders to this exact text" {
    // Oracle: golden, written by hand in the format docs/usage.md shows,
    // with the units converted by hand: on a 2000 dbu/um grid (4200, 8600)
    // is (2100 nm, 4300 nm), 4 dbu is 2 nm and 48 dbu^2 is 12 nm^2.
    // Rust's row measured a length against an area, which a Zig row (one
    // kind per row) cannot hold, so the area moved to a waived row with a
    // fix hint, the two paths Rust's test left out.
    const gpa = std.testing.allocator;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
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
    try waived.push(gpa, .{ .rule = antenna, .layer = @fromBackingInt(1), .severity = .warning, .at = .{ .x = 1, .y = -3 }, .measured = .area(48), .limit = .area(40), .shape_a = @fromBackingInt(2), .shape_b = report.no_shape });
    try waived.setFix(gpa, 0, .area(8));
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
    try writeViolations(&out.writer, &strings, grid, &violations, &waived);
    try writeMerges(&out.writer, &strings, &.{}, &.{}, &no_merges, &no_merges);
    try writeVerdict(&out.writer, null, &.{});
    try writeSummary(&out.writer, summary);
    try std.testing.expectEqualStrings(
        \\rules:
        \\  m1_min_width: ran, examined 4231 shapes, found 1 violations
        \\  antenna_ratio: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
        \\violations: 1
        \\  m1_min_width error layer 3 at (2100 nm, 4300 nm) measured 2 nm against limit 100 nm on shape 7 and shape 9
        \\waived: 1
        \\  antenna_ratio warning layer 1 at (0.5 nm, -1.5 nm) measured 12 nm^2 against limit 10 nm^2 on shape 2 fix 2 nm^2
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

test "the lvs merges and verdict render as Rust's lines and Debug" {
    // Oracle: rustc 1.95's `{:?}` of a mirror of Rust's `Verdict` (the
    // same variants, fields and derives), copied from its output; the
    // merge and instance lines from format.rs's `writeln!` formats.
    const gpa = std.testing.allocator;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const nch = try strings.intern(gpa, "nch");
    const path = try strings.intern(gpa, "X1.X2");
    const cell = try strings.intern(gpa, "inv");
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
        .{ .unpaired_device = .{ .side = .layout, .device = 3, .model = @fromBackingInt(5) } },
        .{ .unpaired_net = .{ .side = .reference, .net = 2, .name = null } },
        .{ .unpaired_net = .{ .side = .layout, .net = 0, .name = @fromBackingInt(1) } },
        .{ .terminal_mismatch = .{ .layout_device = 1, .ref_device = 2, .role = .{ .pin = 1 } } },
        .{ .terminal_mismatch = .{ .layout_device = 1, .ref_device = 2, .role = .drain } },
        .{ .parameter_mismatch = .{ .layout_device = 0, .ref_device = 1, .param = @fromBackingInt(4), .layout_value = 1e-6, .ref_value = 1.5 } },
        .{ .undeclared_param = .{ .side = .reference, .layout_device = 0, .ref_device = 1, .param = @fromBackingInt(6) } },
        .{ .model_mismatch = .{ .layout_device = 4, .ref_device = 5, .layout_model = @fromBackingInt(7), .ref_model = @fromBackingInt(8) } },
        .{ .class_imbalance = .{ .layout_nodes = 2, .ref_nodes = 3 } },
    };
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeMerges(&out.writer, &strings, &placements, &unpaired, &layout_merges, &reference_merges);
    try writeVerdict(&out.writer, .mismatch, &found);
    try writeVerdict(&out.writer, .{ .inconclusive = .round_limit }, &.{});
    try writeVerdict(&out.writer, .match, &.{});
    try std.testing.expectEqualStrings(
        \\lvs unpaired instances:
        \\  X1.X2 (inv): none of its 2 devices has a partner in the layout
        \\lvs merges:
        \\  layout parallel: 3 devices of nch (0, 4, 7) are one
        \\  reference series: 2 devices of nch (1, 2) are one
        \\lvs: Mismatch([UnpairedDevice { side: Layout, device: 3, model: StrId(5) }, UnpairedNet { side: Reference, net: 2, name: None }, UnpairedNet { side: Layout, net: 0, name: Some(StrId(1)) }, TerminalMismatch { layout_device: 1, ref_device: 2, role: Pin(1) }, TerminalMismatch { layout_device: 1, ref_device: 2, role: Drain }, ParameterMismatch { layout_device: 0, ref_device: 1, param: StrId(4), layout_value: 1e-6, ref_value: 1.5 }, UndeclaredParam { side: Reference, layout_device: 0, ref_device: 1, param: StrId(6) }, ModelMismatch { layout_device: 4, ref_device: 5, layout_model: StrId(7), ref_model: StrId(8) }, ClassImbalance { layout_nodes: 2, ref_nodes: 3 }])
        \\lvs: Inconclusive(RoundLimit)
        \\lvs: Match
        \\
    , out.written());
}
