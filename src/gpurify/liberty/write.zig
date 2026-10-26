//! The Liberty model of one macro at one corner → its two texts: the `.lib`
//! and the Verilog blackbox. Ported from src/liberty/write.rs.
//!
//! Units throughout: ns, pF, V, mA, nW, and pJ for internal energy. The
//! output is a function of the model alone. The tables are NLDM, each
//! restating its indices: `cell_*` and `*_transition` (input transition ns ×
//! load pF → ns), `*_power` (→ pJ), `*_constraint` (clock transition ns ×
//! data transition ns → ns). At `statistical` each timing table has an
//! `ocv_sigma_*` twin, written once `early` and once `late`.
//!
//! Contents:
//! - `pub const Library`, `Cell`, `Pin`, `Timing`, `InternalPower`, `NamedTable`, `Table`
//! - `pub fn writeLiberty(gpa: Allocator, lib: *const Library, w: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!void`
//! - `pub fn direction(pin: PinSpec) Direction`
//! - `pub fn writeBlackbox(cell: []const u8, pins: []const PinSpec, tool_version: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const spec = @import("spec.zig");
const Accuracy = spec.Accuracy;
const ArcKind = spec.ArcKind;
const Characterization = spec.Characterization;
const CornerSpec = spec.CornerSpec;
const Direction = spec.Direction;
const PinSpec = spec.PinSpec;
const numbers = @import("numbers.zig");

/// One `.lib` file's content.
pub const Library = struct {
    /// `<cell>__<corner>`, `__min` appended for the best-case copy.
    name: []const u8,
    /// Supplies become `voltage_map`s; the highest `power` supply is `nom_voltage`.
    corner: *const CornerSpec,
    /// Only the four threshold percentages are written from it.
    thresholds: *const Characterization,
    accuracy: Accuracy,
    tool_version: []const u8,
    cell: Cell,
};

/// The macro as a Liberty `cell`, marked `is_macro_cell`, `dont_touch`, `dont_use`.
pub const Cell = struct {
    name: []const u8,
    area_um2: f64 = 0,
    /// Mean of the per-state leakage, nW.
    leakage_nw: ?f64 = null,
    /// `(when, nW)`; `when` empty for a state with no digital pins.
    leakage_when: []const []const u8 = &.{},
    leakage_value: []const f64 = &.{},
    /// In spec order, supplies included.
    pins: []Pin,
};

/// One pin: a `pg_pin` for a supply role, a `pin` otherwise.
pub const Pin = struct {
    spec: PinSpec,
    /// `(rise, fall)`, pF; `capacitance` is their mean.
    capacitance: ?[2]f64 = null,
    max_transition_ns: ?f64 = null,
    max_capacitance_pf: ?f64 = null,
    timing: []const Timing = &.{},
    power: []const InternalPower = &.{},
};

/// One `timing ()` group.
pub const Timing = struct {
    related: []const u8,
    kind: ArcKind,
    /// `timing_sense` of a combinational arc; null for a clocked one.
    sense: ?[]const u8,
    tables: []const NamedTable,
};

/// One `internal_power ()` group on an output.
pub const InternalPower = struct {
    related: []const u8,
    rise: ?Table = null,
    fall: ?Table = null,
};

/// A table under its Liberty group name; `sigma` is an LVF table's `sigma_type`.
pub const NamedTable = struct {
    group: []const u8,
    sigma: ?[]const u8 = null,
    table: Table,
};

/// One NLDM table, row-major over `index_1` × `index_2`; `index_2` empty
/// for a 1-D table. `values.len == index_1.len * max(index_2.len, 1)`.
pub const Table = struct {
    index_1: []const f64,
    index_2: []const f64,
    values: []const f64,
};

/// What a template's axes mean; the order templates are written in.
const Axes = enum(u8) { delay, constraint, power };

const Template = struct { axes: Axes, n1: usize, n2: usize };

/// Appends the `.lib` text: the header with units, voltages, the operating
/// condition and thresholds, one template per axes and shape in use, then
/// the cell. `gpa` holds only the template list.
pub fn writeLiberty(gpa: Allocator, lib: *const Library, w: *Writer) (Allocator.Error || Writer.Error)!void {
    const corner = lib.corner;
    const th = lib.thresholds;
    try w.print("/* {s} written by gpurify {s}: accuracy {s} ({s}). */\n", .{ lib.cell.name, lib.tool_version, lib.accuracy.name(), lib.accuracy.describe() });
    try w.print("library (\"{s}\") {{\n", .{lib.name});
    try w.writeAll("    technology (\"cmos\");\n");
    for ([_][2][]const u8{ .{ "delay_model", "table_lookup" }, .{ "time_unit", "\"1ns\"" }, .{ "voltage_unit", "\"1V\"" }, .{ "current_unit", "\"1mA\"" }, .{ "leakage_power_unit", "\"1nW\"" }, .{ "pulling_resistance_unit", "\"1kohm\"" } }) |kv|
        try attr(w, 4, kv[0], kv[1]);
    try w.writeAll("    capacitive_load_unit(1, \"pf\");\n");
    var nominal: f64 = 0.0;
    for (lib.cell.pins) |pin| if (pin.spec.role == .power) {
        if (corner.supplies.get(pin.spec.name)) |v| nominal = @max(nominal, v);
    };
    try attrNum(w, 4, "nom_process", corner.process);
    try attrNum(w, 4, "nom_temperature", corner.temperature);
    try attrNum(w, 4, "nom_voltage", nominal);
    for (corner.supplies.names, corner.supplies.values) |name, volts| {
        try w.print("    voltage_map(\"{s}\", ", .{name});
        try num(w, volts);
        try w.writeAll(");\n");
    }
    try w.print("    operating_conditions (\"{s}\") {{\n", .{corner.name});
    try attrNum(w, 8, "process", corner.process);
    try attrNum(w, 8, "temperature", corner.temperature);
    try attrNum(w, 8, "voltage", nominal);
    try w.writeAll("    }\n");
    try w.print("    default_operating_conditions : \"{s}\";\n", .{corner.name});
    for ([_][]const u8{ "rise", "fall" }) |edge| {
        try w.print("    input_threshold_pct_{s} : ", .{edge});
        try numLine(w, th.input_threshold_pct);
        try w.print("    output_threshold_pct_{s} : ", .{edge});
        try numLine(w, th.output_threshold_pct);
        try w.print("    slew_lower_threshold_pct_{s} : ", .{edge});
        try numLine(w, th.slew_lower_pct);
        try w.print("    slew_upper_threshold_pct_{s} : ", .{edge});
        try numLine(w, th.slew_upper_pct);
    }
    try attrNum(w, 4, "slew_derate_from_library", 1.0);
    try attrNum(w, 4, "default_cell_leakage_power", 0.0);
    try attrNum(w, 4, "default_inout_pin_cap", 0.0);
    try attrNum(w, 4, "default_input_pin_cap", 0.0);
    try attrNum(w, 4, "default_output_pin_cap", 0.0);
    try attrNum(w, 4, "default_fanout_load", 1.0);

    var templates: std.ArrayList(Template) = .empty;
    defer templates.deinit(gpa);
    for (lib.cell.pins) |pin| {
        for (pin.timing) |timing| for (timing.tables) |named|
            try templates.append(gpa, .{ .axes = timingAxes(timing.kind), .n1 = named.table.index_1.len, .n2 = named.table.index_2.len });
        for (pin.power) |power| for ([_]?Table{ power.rise, power.fall }) |t| if (t) |tb|
            try templates.append(gpa, .{ .axes = .power, .n1 = tb.index_1.len, .n2 = tb.index_2.len });
    }
    std.mem.sortUnstable(Template, templates.items, {}, templateLess);
    for (templates.items, 0..) |t, i| {
        if (i > 0 and std.meta.eql(templates.items[i - 1], t)) continue;
        const v1, const v2 = switch (t.axes) {
            .delay, .power => .{ "input_net_transition", "total_output_net_capacitance" },
            .constraint => .{ "related_pin_transition", "constrained_pin_transition" },
        };
        const keyword = switch (t.axes) {
            .power => "power_lut_template",
            .delay, .constraint => "lu_table_template",
        };
        try w.print("    {s} (\"", .{keyword});
        try templateName(w, t.axes, t.n1, t.n2);
        try w.writeAll("\") {\n");
        try attr(w, 8, "variable_1", v1);
        if (t.n2 > 0) try attr(w, 8, "variable_2", v2);
        try w.writeAll("        index_1(\"");
        try dummy(w, t.n1);
        try w.writeAll("\");\n");
        if (t.n2 > 0) {
            try w.writeAll("        index_2(\"");
            try dummy(w, t.n2);
            try w.writeAll("\");\n");
        }
        try w.writeAll("    }\n");
    }
    try writeCell(&lib.cell, w);
    try w.writeAll("}\n");
}

/// A pin's Liberty and Verilog direction: `input` for an input or clock,
/// `output` for an output, else the spec's, `inout` when it gives none.
pub fn direction(pin: PinSpec) Direction {
    return switch (pin.role) {
        .input, .clock => .input,
        .output => .output,
        .power, .ground, .nwell, .pwell, .analog => pin.direction orelse .inout,
    };
}

/// The `(* blackbox *)` Verilog module, ports in spec order, supplies behind
/// `USE_POWER_PINS` as the OpenLane/LibreLane flow expects.
pub fn writeBlackbox(cell: []const u8, pins: []const PinSpec, tool_version: []const u8, w: *Writer) Writer.Error!void {
    try w.print("// {s} blackbox, written by gpurify {s}.\n", .{ cell, tool_version });
    try w.writeAll("(* blackbox *)\n");
    try w.print("module {s} (\n", .{cell});
    var supplies: usize = 0;
    for (pins) |p| supplies += @intFromBool(p.role.isSupply());
    const signals = pins.len - supplies;
    if (supplies > 0) {
        try w.writeAll("`ifdef USE_POWER_PINS\n");
        var i: usize = 0;
        for (pins) |p| if (p.role.isSupply()) {
            i += 1;
            // The last supply takes a comma only if a signal follows it.
            const comma = if (i < supplies or signals > 0) "," else "";
            try w.print("    inout {s}{s}\n", .{ p.name, comma });
        };
        try w.writeAll("`endif\n");
    }
    var i: usize = 0;
    for (pins) |p| if (!p.role.isSupply()) {
        i += 1;
        try w.print("    {s} {s}{s}\n", .{ @tagName(direction(p)), p.name, if (i < signals) "," else "" });
    };
    try w.writeAll(");\nendmodule\n");
}

// ---- private ----

fn timingAxes(kind: ArcKind) Axes {
    return if (kind.isConstraint()) .constraint else .delay;
}

/// Rust's `BTreeSet<(Axes, name, n1, n2)>` order: the name compares as text.
fn templateLess(_: void, a: Template, b: Template) bool {
    if (a.axes != b.axes) return @backingInt(a.axes) < @backingInt(b.axes);
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    var wa: Writer = .fixed(&buf_a);
    var wb: Writer = .fixed(&buf_b);
    templateName(&wa, a.axes, a.n1, a.n2) catch unreachable;
    templateName(&wb, b.axes, b.n1, b.n2) catch unreachable;
    switch (std.mem.order(u8, wa.buffered(), wb.buffered())) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.n1 != b.n1) return a.n1 < b.n1;
    return a.n2 < b.n2;
}

/// A template is named by its axes and shape (`delay_7x7`).
fn templateName(w: *Writer, axes: Axes, n1: usize, n2: usize) Writer.Error!void {
    const prefix = switch (axes) {
        .delay => "delay",
        .constraint => "constraint",
        .power => "energy",
    };
    try w.print("{s}_{d}x{d}", .{ prefix, n1, @max(n2, 1) });
}

fn dummy(w: *Writer, n: usize) Writer.Error!void {
    for (1..n + 1) |i| try w.print("{s}{d}", .{ if (i > 1) ", " else "", i });
}

/// Liberty number: `0`, ten decimals from 1e-3 up, a nine-digit mantissa below.
fn num(w: *Writer, value: f64) Writer.Error!void {
    std.debug.assert(std.math.isFinite(value));
    if (value == 0.0) return w.writeByte('0');
    if (@abs(value) >= 1e-3) return numbers.fixed(w, value, 10);
    return numbers.sci(w, value, 9);
}

fn numLine(w: *Writer, value: f64) Writer.Error!void {
    try num(w, value);
    try w.writeAll(";\n");
}

fn list(w: *Writer, values: []const f64) Writer.Error!void {
    try w.writeByte('"');
    for (values, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try num(w, v);
    }
    try w.writeByte('"');
}

fn attr(w: *Writer, indent: usize, key: []const u8, value: []const u8) Writer.Error!void {
    try w.splatByteAll(' ', indent);
    try w.print("{s} : {s};\n", .{ key, value });
}

fn attrQuoted(w: *Writer, indent: usize, key: []const u8, value: []const u8) Writer.Error!void {
    try w.splatByteAll(' ', indent);
    try w.print("{s} : \"{s}\";\n", .{ key, value });
}

fn attrNum(w: *Writer, indent: usize, key: []const u8, value: f64) Writer.Error!void {
    try w.splatByteAll(' ', indent);
    try w.print("{s} : ", .{key});
    try numLine(w, value);
}

fn table(w: *Writer, indent: usize, group: []const u8, axes: Axes, sigma: ?[]const u8, t: Table) Writer.Error!void {
    const pad = indent + 4;
    try w.splatByteAll(' ', indent);
    try w.print("{s} (\"", .{group});
    try templateName(w, axes, t.index_1.len, t.index_2.len);
    try w.writeAll("\") {\n");
    if (sigma) |s| try attrQuoted(w, pad, "sigma_type", s);
    try w.splatByteAll(' ', pad);
    try w.writeAll("index_1(");
    try list(w, t.index_1);
    try w.writeAll(");\n");
    if (t.index_2.len > 0) {
        try w.splatByteAll(' ', pad);
        try w.writeAll("index_2(");
        try list(w, t.index_2);
        try w.writeAll(");\n");
    }
    const row = @max(t.index_2.len, 1);
    try w.splatByteAll(' ', pad);
    try w.writeAll("values(");
    var i: usize = 0;
    while (i * row < t.values.len) : (i += 1) {
        if (i > 0) {
            try w.writeAll(", \\\n");
            try w.splatByteAll(' ', pad + 7);
        }
        try list(w, t.values[i * row .. @min((i + 1) * row, t.values.len)]);
    }
    try w.writeAll(");\n");
    try w.splatByteAll(' ', indent);
    try w.writeAll("}\n");
}

fn writeCell(cell: *const Cell, w: *Writer) Writer.Error!void {
    try w.print("    cell (\"{s}\") {{\n", .{cell.name});
    try attrNum(w, 8, "area", cell.area_um2);
    try attr(w, 8, "is_macro_cell", "true");
    try attr(w, 8, "dont_touch", "true");
    try attr(w, 8, "dont_use", "true");
    if (cell.leakage_nw) |leakage| try attrNum(w, 8, "cell_leakage_power", leakage);
    for (cell.leakage_when, cell.leakage_value) |when, nw| {
        try w.writeAll("        leakage_power () {\n");
        try attrNum(w, 12, "value", nw);
        if (when.len > 0) try attrQuoted(w, 12, "when", when);
        try w.writeAll("        }\n");
    }
    for (cell.pins) |pin| {
        const pg_type = switch (pin.spec.role) {
            .power => "primary_power",
            .ground => "primary_ground",
            .nwell => "nwell",
            .pwell => "pwell",
            .input, .clock, .output, .analog => continue,
        };
        try w.print("        pg_pin (\"{s}\") {{\n", .{pin.spec.name});
        try attr(w, 12, "pg_type", pg_type);
        try attrQuoted(w, 12, "voltage_name", pin.spec.name);
        if (pin.spec.role == .nwell or pin.spec.role == .pwell) try attr(w, 12, "physical_connection", "\"device_layer\"");
        try w.writeAll("        }\n");
    }
    for (cell.pins) |pin| if (!pin.spec.role.isSupply()) try writePin(&pin, w);
    try w.writeAll("    }\n");
}

fn writePin(pin: *const Pin, w: *Writer) Writer.Error!void {
    const s = pin.spec;
    try w.print("        pin (\"{s}\") {{\n", .{s.name});
    try attr(w, 12, "direction", @tagName(direction(s)));
    if (s.power) |p| try attrQuoted(w, 12, "related_power_pin", p);
    if (s.ground) |g| try attrQuoted(w, 12, "related_ground_pin", g);
    switch (s.role) {
        .clock => try attr(w, 12, "clock", "true"),
        .input => try attr(w, 12, "clock", "false"),
        // Not read by OpenSTA; read by tools that implement the attribute.
        .analog => try attr(w, 12, "is_analog", "true"),
        .power, .ground, .nwell, .pwell, .output => {},
    }
    if (pin.capacitance) |c| {
        try attrNum(w, 12, "capacitance", 0.5 * (c[0] + c[1]));
        try attrNum(w, 12, "rise_capacitance", c[0]);
        try attrNum(w, 12, "fall_capacitance", c[1]);
    }
    if (s.function) |f| try attrQuoted(w, 12, "function", f);
    if (pin.max_transition_ns) |t| try attrNum(w, 12, "max_transition", t);
    if (pin.max_capacitance_pf) |c| try attrNum(w, 12, "max_capacitance", c);
    for (pin.timing) |timing| {
        try w.writeAll("            timing () {\n");
        try attrQuoted(w, 16, "related_pin", timing.related);
        try attr(w, 16, "timing_type", @tagName(timing.kind));
        if (timing.sense) |sense| try attr(w, 16, "timing_sense", sense);
        for (timing.tables) |named| try table(w, 16, named.group, timingAxes(timing.kind), named.sigma, named.table);
        try w.writeAll("            }\n");
    }
    for (pin.power) |power| {
        try w.writeAll("            internal_power () {\n");
        try attrQuoted(w, 16, "related_pin", power.related);
        if (power.rise) |t| try table(w, 16, "rise_power", .power, null, t);
        if (power.fall) |t| try table(w, 16, "fall_power", .power, null, t);
        try w.writeAll("            }\n");
    }
    try w.writeAll("        }\n");
}

test "numbers keep their digits at every scale" {
    // Oracle: hand-derived from `num`'s format: zero bare, ten decimals in
    // fixed point from 1e-3 up (1.5 is 1.5000000000), and a nine-digit
    // mantissa below (1.25e-5 is 1.250000000e-5).
    const cases = [_]struct { f64, []const u8 }{
        .{ 0.0, "0" }, .{ 1.5, "1.5000000000" }, .{ 0.002302, "0.0023020000" }, .{ 1.25e-5, "1.250000000e-5" }, .{ -0.002, "-0.0020000000" },
    };
    var buf: [64]u8 = undefined;
    for (cases) |c| {
        var w: Writer = .fixed(&buf);
        try num(&w, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
}

test "the blackbox has no trailing comma" {
    // Oracle: the Verilog grammar (IEEE 1364-2005): a port list is
    // comma-separated with no comma after the last port, so the expected
    // text is written by hand, for signals after supplies and for supplies
    // alone (F35: the last supply ends the list).
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeBlackbox("m", &.{ .{ .name = "vdd", .role = .power }, .{ .name = "a", .role = .input }, .{ .name = "y", .role = .output } }, "t", &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "    inout vdd,\n`endif\n    input a,\n    output y\n);") != null);
    w = .fixed(&buf);
    try writeBlackbox("m", &.{ .{ .name = "vdd", .role = .power }, .{ .name = "vss", .role = .ground } }, "t", &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "`ifdef USE_POWER_PINS\n    inout vdd,\n    inout vss\n`endif\n);") != null);
}
