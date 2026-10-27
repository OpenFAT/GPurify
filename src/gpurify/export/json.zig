//! The JSON check report, the machine-readable form. In: the header, the
//! violations (and waived ones), the rule records, the strings and grid
//! they need. Out: one JSON object, lengths in nm. Ported from
//! src/export/json.rs.
//!
//! Keys in this order: `header` (`tool_version`, `deck_path`,
//! `layout_path`, `timestamp` or `null`); `violations`, one object per row
//! (`rule`, `layer`, `layer_name`, `severity`, `at`, `measured`, `limit`,
//! `shapes`, `fix` where the row has a hint, and `load`, the simulated
//! `instance` and `terminal` loading it most, where the row has one);
//! `waived`, only when non-empty; `runs`
//! (`rule`, `outcome`, `examined`, `violations`). Units: `nm`, `nm^2`,
//! `mV`, `uA`, `ohm`; a ratio or count has none. Floats are `{:.6}`
//! (geom.float). Keys are fixed, never a map's, so the bytes are
//! deterministic. A string escapes as serde_json does (RFC 8259 §7).
//!
//! Contents:
//! - `pub const Error = error{Unrepresentable} || std.Io.Writer.Error`
//! - `pub fn writeReport(w: *std.Io.Writer, header: *const Header, strings: *const StrTable, layers: *const LayerTable, grid: Grid, violations: *const Violations, waived: *const Violations, runs: []const RuleRun) Error!void`
//! - `pub fn writeString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void`

const std = @import("std");
const Writer = std.Io.Writer;
const geom = @import("geom");
const Grid = geom.Grid;
const PolyId = geom.PolyId;
const StrTable = geom.StrTable;
const LayerTable = @import("ingest").deck.LayerTable;
const report = @import("check").report;
const Measurement = report.Measurement;
const RuleRun = report.RuleRun;
const Violations = report.Violations;
const float = geom.float;
const Header = @import("header.zig").Header;
const assert = std.debug.assert;

/// `Unrepresentable`: a measured value, limit or fix is NaN or infinite,
/// which JSON cannot carry (RFC 8259 §6), refused before the first byte.
pub const Error = error{Unrepresentable} || Writer.Error;

/// The report, rows in their tables' own order: sort them canonically first.
/// `strings` resolves every rule id; `grid` turns dbu into nm. `layer` is
/// the row's layer id, kept for older readers; `layer_name` is the name
/// `layers` (the run's deck's table) gives it, a hidden inner layer's
/// included (`x#1`, `<rule id>@k`), and `null` on `report.no_layer` (an
/// LVS or system finding). A run with no one deck (a system) passes an
/// empty table. A `shapes` entry is `null` for `report.no_shape`. Asserts
/// that every row's layer is in `layers` or is `report.no_layer`.
pub fn writeReport(w: *Writer, header: *const Header, strings: *const StrTable, layers: *const LayerTable, grid: Grid, violations: *const Violations, waived: *const Violations, runs: []const RuleRun) Error!void {
    if (!allFinite(violations) or !allFinite(waived)) return error.Unrepresentable;
    try w.writeAll("{\"header\":{\"tool_version\":");
    try writeString(w, header.tool_version);
    try w.writeAll(",\"deck_path\":");
    try writeString(w, header.deck_path);
    try w.writeAll(",\"layout_path\":");
    try writeString(w, header.layout_path);
    try w.writeAll(",\"timestamp\":");
    if (header.timestamp) |stamp| try writeString(w, stamp) else try w.writeAll("null");
    try w.writeAll("},\"violations\":[");
    try writeRows(w, strings, layers, grid, violations);
    // Only a deck with waivers has any; a report without them reads as before.
    if (waived.len() > 0) {
        try w.writeAll("],\"waived\":[");
        try writeRows(w, strings, layers, grid, waived);
    }
    try w.writeAll("],\"runs\":[");
    for (runs, 0..) |run, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"rule\":");
        try writeString(w, strings.resolve(run.rule));
        try w.writeAll(",\"outcome\":\"");
        try w.writeAll(switch (run.outcome) {
            .ran => "ran",
            .refused => "refused",
            .skipped => |why| switch (why) {
                .no_design_intent => "skipped:no_design_intent",
                .not_in_deck => "skipped:not_in_deck",
                .empty_layer => "skipped:empty_layer",
                .earlier_stage => "skipped:earlier_stage",
            },
        });
        try w.print("\",\"examined\":{d},\"violations\":{d}}}", .{ run.examined, run.violations });
    }
    try w.writeAll("]}");
}

/// `text` as a JSON string: `"` and `\` escaped, `\b \f \n \r \t`, any
/// other byte below 0x20 as `\u00xx`; everything else as is.
pub fn writeString(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ---- private ----

fn allFinite(v: *const Violations) bool {
    for (v.kind.items, v.measured.items, v.limit.items) |kind, measured, limit| {
        const m: Measurement = .{ .kind = kind, .raw = measured };
        const l: Measurement = .{ .kind = kind, .raw = limit };
        if (!m.isFinite() or !l.isFinite()) return false;
    }
    for (v.fix_value.items) |fix| if (!fix.isFinite()) return false;
    return true;
}

/// Each row of `v` as a JSON object, comma-separated.
fn writeRows(w: *Writer, strings: *const StrTable, layers: *const LayerTable, grid: Grid, v: *const Violations) Writer.Error!void {
    // The sentinel sits past every table, so it never reads as a name.
    assert(layers.len() <= @backingInt(report.no_layer));
    for (0..v.len()) |i| {
        const row: u32 = @intCast(i);
        const r = v.get(row);
        if (r.layer != report.no_layer) assert(@backingInt(r.layer) < layers.len());
        if (row > 0) try w.writeByte(',');
        try w.writeAll("{\"rule\":");
        try writeString(w, strings.resolve(r.rule));
        try w.print(",\"layer\":{d},\"layer_name\":", .{@backingInt(r.layer)});
        if (r.layer == report.no_layer) try w.writeAll("null") else try writeString(w, strings.resolve(layers.name(r.layer)));
        try w.print(",\"severity\":\"{s}\",\"at\":{{\"unit\":\"nm\",\"x\":", .{@tagName(r.severity)});
        try float.fixed6(w, grid.toLength(r.at.x).raw);
        try w.writeAll(",\"y\":");
        try float.fixed6(w, grid.toLength(r.at.y).raw);
        try w.writeAll("},\"measured\":");
        try writeMeasurement(w, grid, r.measured);
        try w.writeAll(",\"limit\":");
        try writeMeasurement(w, grid, r.limit);
        try w.writeAll(",\"shapes\":[");
        try writeShape(w, r.shape_a);
        try w.writeByte(',');
        try writeShape(w, r.shape_b);
        try w.writeByte(']');
        if (v.fixOf(row)) |fix| {
            try w.writeAll(",\"fix\":");
            try writeMeasurement(w, grid, fix);
        }
        if (v.loadOf(row)) |load| {
            try w.writeAll(",\"load\":{\"instance\":");
            try writeString(w, strings.resolve(load.instance));
            try w.writeAll(",\"terminal\":");
            try writeString(w, strings.resolve(load.terminal));
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
}

/// A shape id, or `null` for `report.no_shape`.
fn writeShape(w: *Writer, shape: PolyId) Writer.Error!void {
    if (shape == report.no_shape) return w.writeAll("null");
    try w.print("{d}", .{@backingInt(shape)});
}

/// One measurement tagged with its kind and unit; lengths in nm, areas nm^2.
fn writeMeasurement(w: *Writer, grid: Grid, m: Measurement) Writer.Error!void {
    const unit = switch (m.kind) {
        .length => "nm",
        .area => "nm^2",
        .ratio, .count => "",
        .voltage => "mV",
        .current => "uA",
        .resistance => "ohm",
    };
    try w.print("{{\"kind\":\"{s}\",\"unit\":\"{s}\",\"value\":", .{ @tagName(m.kind), unit });
    switch (m.kind) {
        .length => try float.fixed6(w, grid.toLength(@intCast(m.raw)).raw),
        .area => {
            const per_dbu = 1000.0 / @as(f64, @floatFromInt(grid.dbu_per_um));
            try float.fixed6(w, @as(f64, @floatFromInt(m.raw)) * per_dbu * per_dbu);
        },
        .count => try w.print("{d}", .{m.raw}),
        .ratio, .voltage, .current, .resistance => try float.fixed6(w, m.float()),
    }
    try w.writeByte('}');
}
