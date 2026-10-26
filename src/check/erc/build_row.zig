//! One deck row of an ERC kind, read by type: the lookups every ERC kind
//! builder calls, over drc's `Reader` (the same errors and diagnostic).
//! Physical parameters arrive as ratios already in their column's unit;
//! each lookup checks the value's type only, what values a row may hold is
//! `validate.zig`'s. In: the parsed rule table, one row. Out: typed values,
//! lists (in the reader's scratch), or the named error with the row and
//! parameter in the `Diagnostic`. Ported from crates/check/src/erc/
//! ruleset.rs (`Row`).
//!
//! Contents:
//! - `pub const Row = struct { r: Reader }`, `layers(row, expected: u32) Error![]const LayerId`,
//!   `layersFrom(row, least: u32) Error![]const LayerId`, `layersWhere(row, expected: u32, fits: bool) Error![]const LayerId`,
//!   `length`, `optLength`, `number`, `optNumber`, `optArea`, `count`, `optLayer`, `flagOr(row, param, absent: bool)`,
//!   `lengths`, `numbers`, `models`, `condition(row, param) Error![]Condition`, `areaTable(row, area, value) Error![]AreaPoint`,
//!   `antennaMeasure(row) Error!AntennaMeasure`, `voltageTable(row) Error!VoltageTable`, `pub const VoltageTable`,
//!   `head(row, gpa: Allocator, h: *RuleHead) Error!void`, `wrong(row, param) Error`, `missing(row, param) Error`, `badTable(row, why) Error`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const ParamValue = @import("ingest").deck.ParamValue;
const params = @import("../drc/params.zig");
const Error = params.Error;
const Reader = params.Reader;
const RuleHead = @import("head.zig").RuleHead;
const Condition = @import("topology_tables.zig").Condition;
const antenna = @import("antenna_tables.zig");
const AntennaMeasure = antenna.AntennaMeasure;
const AreaPoint = antenna.AreaPoint;

/// A voltage-dependent spacing table, one space per voltage, deck order.
pub const VoltageTable = struct { voltage: []const f64, space: []const Dbu };

/// One row and its typed lookups.
pub const Row = struct {
    r: Reader,

    pub fn wrong(row: Row, param: []const u8) Error {
        return row.r.fail(error.WrongParamType, param);
    }

    pub fn missing(row: Row, param: []const u8) Error {
        return row.r.fail(error.MissingParam, param);
    }

    /// The row's layers, refused unless `fits`; `expected` is what the
    /// error reports.
    pub fn layersWhere(row: Row, expected: u32, fits: bool) Error![]const LayerId {
        if (!fits) {
            row.r.diag.* = .{ .rule = row.r.spec.id, .kind = row.r.spec.kind, .expected = expected, .found = row.r.spec.layer_len };
            return error.WrongLayerCount;
        }
        return row.r.table.layersOf(row.r.spec);
    }

    /// Exactly `expected` layers.
    pub fn layers(row: Row, expected: u32) Error![]const LayerId {
        return row.layersWhere(expected, row.r.spec.layer_len == expected);
    }

    /// At least `least` layers.
    pub fn layersFrom(row: Row, least: u32) Error![]const LayerId {
        return row.layersWhere(least, row.r.spec.layer_len >= least);
    }

    pub fn length(row: Row, param: []const u8) Error!Dbu {
        return row.r.typed(.length, param);
    }

    pub fn optLength(row: Row, param: []const u8) Error!?Dbu {
        return row.optTyped(.length, param);
    }

    /// A number in its column's unit (any value; `validate` checks it).
    pub fn number(row: Row, param: []const u8) Error!f64 {
        return row.r.typed(.ratio, param);
    }

    pub fn optNumber(row: Row, param: []const u8) Error!?f64 {
        return row.optTyped(.ratio, param);
    }

    pub fn optArea(row: Row, param: []const u8) Error!?DbuArea {
        return row.optTyped(.area, param);
    }

    pub fn count(row: Row, param: []const u8) Error!u32 {
        return row.r.typed(.count, param);
    }

    pub fn optLayer(row: Row, param: []const u8) Error!?LayerId {
        return row.optTyped(.layer, param);
    }

    /// A flag, `absent` when the row leaves it out.
    pub fn flagOr(row: Row, param: []const u8, absent: bool) Error!bool {
        return try row.optTyped(.flag, param) orelse absent;
    }

    /// Every length of a repeated `param`, deck order; empty when absent.
    pub fn lengths(row: Row, param: []const u8) Error![]Dbu {
        return row.r.list(.length, param);
    }

    /// Every finite number of a repeated `param`.
    pub fn numbers(row: Row, param: []const u8) Error![]f64 {
        const out = try row.r.list(.ratio, param);
        for (out) |v| if (!std.math.isFinite(v)) return row.wrong(param);
        return out;
    }

    /// Every model of a repeated `param`.
    pub fn models(row: Row, param: []const u8) Error![]StrId {
        return row.r.list(.model, param);
    }

    /// A net-type condition: the names before a `"!"` present, those after
    /// it absent (US20100306720A1 [0262]); empty when absent.
    pub fn condition(row: Row, param: []const u8) Error![]Condition {
        const bang = row.r.strings.get("!");
        var out: std.ArrayList(Condition) = .empty;
        var negated = false;
        for (try row.models(param)) |name| {
            if (bang != null and name == bang.? and !negated) {
                negated = true;
            } else try out.append(row.r.scratch, .{ .name = name, .negated = negated });
        }
        return out.items;
    }

    /// A piecewise-linear table, `(area, value)` points in deck order;
    /// empty when absent. A mistyped point or a count mismatch is
    /// `WrongParamType` naming `value`.
    pub fn areaTable(row: Row, area_param: []const u8, value_param: []const u8) Error![]AreaPoint {
        var areas: std.ArrayList(DbuArea) = .empty;
        var values: std.ArrayList(f64) = .empty;
        const area_key = row.r.strings.get(area_param) orelse return &.{};
        const value_key = row.r.strings.get(value_param) orelse return &.{};
        for (row.r.table.paramsOf(row.r.spec)) |p| {
            if (p.name == area_key and p.value == .area) {
                try areas.append(row.r.scratch, p.value.area);
            } else if (p.name == value_key and p.value == .ratio) {
                try values.append(row.r.scratch, p.value.ratio);
            } else if (p.name == area_key or p.name == value_key) return row.wrong(value_param);
        }
        if (areas.items.len != values.items.len) return row.wrong(value_param);
        const out = try row.r.scratch.alloc(AreaPoint, areas.items.len);
        for (out, areas.items, values.items) |*o, a, v| o.* = .{ .area = a, .value = v };
        return out;
    }

    /// An antenna row's one collecting measure: a `sidewall_thickness`, or
    /// none for the drawn area.
    pub fn antennaMeasure(row: Row) Error!AntennaMeasure {
        return if (try row.optLength("sidewall_thickness")) |t| .{ .sidewall = t } else .area;
    }

    /// The repeated `voltage` (mV) and `space` steps, deck order: each
    /// voltage a finite number, each space a length, both lists stated, one
    /// space per voltage (`BadTable` otherwise).
    pub fn voltageTable(row: Row) Error!VoltageTable {
        var voltage: std.ArrayList(f64) = .empty;
        var space: std.ArrayList(Dbu) = .empty;
        const voltage_key = row.r.strings.get("voltage");
        const space_key = row.r.strings.get("space");
        for (row.r.table.paramsOf(row.r.spec)) |p| {
            if (voltage_key != null and p.name == voltage_key.?) {
                if (p.value != .ratio or !std.math.isFinite(p.value.ratio)) return row.wrong("voltage");
                try voltage.append(row.r.scratch, p.value.ratio);
            } else if (space_key != null and p.name == space_key.?) {
                if (p.value != .length) return row.wrong("space");
                try space.append(row.r.scratch, p.value.length);
            }
        }
        if (voltage.items.len == 0) return row.missing("voltage");
        if (space.items.len == 0) return row.missing("space");
        if (voltage.items.len != space.items.len) return row.badTable("a voltage table needs one space per voltage");
        return .{ .voltage = voltage.items, .space = space.items };
    }

    /// `BadTable` naming what is out of order.
    pub fn badTable(row: Row, why: []const u8) Error {
        row.r.diag.* = .{ .rule = row.r.spec.id, .kind = row.r.spec.kind, .why = why };
        return error.BadTable;
    }

    /// Pushes the row's head: `warning: true` demotes it from `.error`.
    pub fn head(row: Row, gpa: Allocator, h: *RuleHead) Error!void {
        const warning = try row.flagOr("warning", false);
        try h.push(gpa, row.r.spec.id, if (warning) .warning else .@"error");
    }

    fn optTyped(row: Row, comptime tag: std.meta.Tag(ParamValue), param: []const u8) Error!?@FieldType(ParamValue, @tagName(tag)) {
        const v = row.r.optional(param) orelse return null;
        return if (v == tag) @field(v, @tagName(tag)) else row.wrong(param);
    }
};
