//! A deck's DRC rules, stored: one SoA table per kind, the deck order as
//! `(kind, row)` slots, and the CSR side tables rows name by index. In: rules
//! pushed one at a time (`push`, by a deck compiler or a test). Out: the
//! tables the spine reads, and `get`, which gathers one slot back into a
//! `Rule`. Ported from crates/check/src/drc/ruleset.rs (`RuleSet`'s fields).
//!
//! Contents:
//! - `pub const Slot = struct { kind: Kind, row: u32 }`
//! - `pub fn Csr(comptime T: type) type`, `Csr.deinit`, `Csr.len(c) u32`, `Csr.get(c, i: u32) []const T`,
//!   `Csr.push(c, gpa: Allocator, items: []const T) Allocator.Error!u32`
//! - `pub const Tables`, `pub const RuleSet = struct`, `RuleSet.deinit`, `RuleSet.len(rs) u32`,
//!   `RuleSet.push(rs, gpa: Allocator, id: StrId, rule: Rule, severity: Severity) Allocator.Error!void`,
//!   `RuleSet.get(rs, at: u32) Rule`, `RuleSet.table(rs, comptime k: Kind) *const std.MultiArrayList(Row(k))`,
//!   `RuleSet.spacingTable(rs, i: u32) SpacingTable`, `cutClassTable`, `classTable`, `spanTable`,
//!   `coverBands`, `cutAreaBands`, `defectSizes`, `addSpacingTable`, `addCutClassTable`,
//!   `addClassTable`, `addSpanTable`, `addCoverBands`, `addCutAreaBands`, `addDefectSizes`,
//!   `netSources(rs, layer: LayerId) []const LayerId`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const Bbox = geom.Bbox;
const Severity = @import("../report.zig").Severity;
const Kind = @import("kinds.zig").Kind;
const rows = @import("rows.zig");
const Rule = rows.Rule;
const Row = rows.Row;
const tables = @import("tables.zig");

/// One rule in deck order: its kind and its row of that kind's table.
pub const Slot = struct { kind: Kind, row: u32 };

/// One `MultiArrayList` per kind, each field named for its kind.
pub const Tables = blk: {
    const names = @typeInfo(Kind).@"enum".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (names, 0..) |n, i| {
        types[i] = std.MultiArrayList(@FieldType(Rule, n));
        attrs[i] = .{ .default_value_ptr = &types[i].empty };
    }
    break :blk @Struct(.auto, null, names, &types, &attrs);
};

/// Every DRC rule a deck configures. Invariant: `order`, `id` and
/// `severity` are parallel, one per rule in deck order; every `Slot` names
/// an existing row of its kind's table; every side-table index a row holds
/// names an existing row of that side table.
pub const RuleSet = struct {
    order: std.ArrayList(Slot) = .empty,
    /// Each rule's deck id; unique.
    id: std.ArrayList(StrId) = .empty,
    /// `.warning` for a row the deck writes `warning` (catalog DRC-110):
    /// every finding of it is a warning; its outcome is unchanged.
    severity: std.ArrayList(Severity) = .empty,
    tables: Tables = .{},
    /// The deck's first derived layer: it and every higher id are computed.
    /// Null when every layer is drawn (a set built in code).
    first_derived: ?LayerId = null,
    // Side tables, CSR by table index.
    spacing_prl: Csr(Dbu) = .{},
    spacing_width: Csr(Dbu) = .{},
    spacing_space: Csr(Dbu) = .{},
    cut_short: Csr(Dbu) = .{},
    cut_long: Csr(Dbu) = .{},
    cut_space: Csr(Dbu) = .{},
    class_class: Csr(Dbu) = .{},
    class_prl: Csr(?Dbu) = .{},
    class_space: Csr(Dbu) = .{},
    span_x: Csr(Dbu) = .{},
    span_y: Csr(Dbu) = .{},
    span_except: std.ArrayList([2]?Dbu) = .empty,
    cover_cover: Csr(f64) = .{},
    cover_density: Csr(f64) = .{},
    cover_inclusive: std.ArrayList(bool) = .empty,
    cut_area_cuts: Csr(u32) = .{},
    cut_area_change: Csr(DbuArea) = .{},
    defect_radius: Csr(Dbu) = .{},
    defect_weight: Csr(f64) = .{},
    /// Each `cut_class` row's `(short, long)` sides: sorted, no repeats.
    classes: Csr([2]Dbu) = .{},
    /// Each `allowed_width` row's widths: sorted, no repeats.
    widths: Csr(Dbu) = .{},
    /// Each `via_stack` row's layers, bottom to top.
    stacks: Csr(LayerId) = .{},
    /// Each `pattern_match` row's window, shapes and don't-care boxes.
    pattern_window: std.ArrayList([2]Dbu) = .empty,
    pattern_shapes: Csr(Bbox) = .{},
    pattern_ignore: Csr(Bbox) = .{},
    /// Per derived layer a `net_spacing` reads, the drawn layers it is
    /// computed from, sorted.
    net_source_layer: std.ArrayList(LayerId) = .empty,
    net_source_drawn: Csr(LayerId) = .{},

    pub fn deinit(rs: *RuleSet, gpa: Allocator) void {
        inline for (@typeInfo(RuleSet).@"struct".field_names) |name| {
            const T = @FieldType(RuleSet, name);
            if (T == Tables) {
                inline for (@typeInfo(Tables).@"struct".field_names) |k| @field(rs.tables, k).deinit(gpa);
            } else if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) @field(rs, name).deinit(gpa);
        }
    }

    pub fn len(rs: *const RuleSet) u32 {
        return @intCast(rs.order.items.len);
    }

    /// Appends one rule at the end of the deck order. On error the set is
    /// unchanged.
    pub fn push(rs: *RuleSet, gpa: Allocator, id: StrId, rule: Rule, severity: Severity) Allocator.Error!void {
        assert(rs.order.items.len < std.math.maxInt(u32));
        try rs.order.ensureUnusedCapacity(gpa, 1);
        try rs.id.ensureUnusedCapacity(gpa, 1);
        try rs.severity.ensureUnusedCapacity(gpa, 1);
        const row: u32 = switch (rule) {
            inline else => |r, k| blk: {
                const t = &@field(rs.tables, @tagName(k));
                try t.append(gpa, r);
                break :blk @intCast(t.len - 1);
            },
        };
        rs.order.appendAssumeCapacity(.{ .kind = rule, .row = row });
        rs.id.appendAssumeCapacity(id);
        rs.severity.appendAssumeCapacity(severity);
    }

    /// Rule `at` in deck order, gathered from its kind's table.
    pub fn get(rs: *const RuleSet, at: u32) Rule {
        const slot = rs.order.items[at];
        return switch (slot.kind) {
            inline else => |k| @unionInit(Rule, @tagName(k), @field(rs.tables, @tagName(k)).get(slot.row)),
        };
    }

    /// Kind `k`'s table.
    pub fn table(rs: *const RuleSet, comptime k: Kind) *const std.MultiArrayList(Row(k)) {
        return &@field(rs.tables, @tagName(k));
    }

    pub fn spacingTable(rs: *const RuleSet, i: u32) tables.SpacingTable {
        return .{ .prl = rs.spacing_prl.get(i), .width = rs.spacing_width.get(i), .space = rs.spacing_space.get(i) };
    }

    pub fn addSpacingTable(rs: *RuleSet, gpa: Allocator, t: tables.SpacingTable) Allocator.Error!u32 {
        _ = try rs.spacing_prl.push(gpa, t.prl);
        _ = try rs.spacing_width.push(gpa, t.width);
        return rs.spacing_space.push(gpa, t.space);
    }

    pub fn cutClassTable(rs: *const RuleSet, i: u32) tables.CutClassTable {
        return .{ .short = rs.cut_short.get(i), .long = rs.cut_long.get(i), .space = rs.cut_space.get(i) };
    }

    pub fn addCutClassTable(rs: *RuleSet, gpa: Allocator, t: tables.CutClassTable) Allocator.Error!u32 {
        _ = try rs.cut_short.push(gpa, t.short);
        _ = try rs.cut_long.push(gpa, t.long);
        return rs.cut_space.push(gpa, t.space);
    }

    pub fn classTable(rs: *const RuleSet, i: u32) tables.ClassTable {
        return .{ .class = rs.class_class.get(i), .prl = rs.class_prl.get(i), .space = rs.class_space.get(i) };
    }

    pub fn addClassTable(rs: *RuleSet, gpa: Allocator, t: tables.ClassTable) Allocator.Error!u32 {
        _ = try rs.class_class.push(gpa, t.class);
        _ = try rs.class_prl.push(gpa, t.prl);
        return rs.class_space.push(gpa, t.space);
    }

    pub fn spanTable(rs: *const RuleSet, i: u32) tables.SpanTable {
        const e = rs.span_except.items[i];
        return .{ .x = rs.span_x.get(i), .y = rs.span_y.get(i), .x_except = e[0], .y_except = e[1] };
    }

    pub fn addSpanTable(rs: *RuleSet, gpa: Allocator, t: tables.SpanTable) Allocator.Error!u32 {
        try rs.span_except.append(gpa, .{ t.x_except, t.y_except });
        _ = try rs.span_x.push(gpa, t.x);
        return rs.span_y.push(gpa, t.y);
    }

    pub fn coverBands(rs: *const RuleSet, i: u32) tables.CoverBands {
        return .{ .cover = rs.cover_cover.get(i), .density = rs.cover_density.get(i), .inclusive = rs.cover_inclusive.items[i] };
    }

    pub fn addCoverBands(rs: *RuleSet, gpa: Allocator, b: tables.CoverBands) Allocator.Error!u32 {
        try rs.cover_inclusive.append(gpa, b.inclusive);
        _ = try rs.cover_cover.push(gpa, b.cover);
        return rs.cover_density.push(gpa, b.density);
    }

    pub fn cutAreaBands(rs: *const RuleSet, i: u32) tables.CutAreaBands {
        return .{ .cuts = rs.cut_area_cuts.get(i), .change = rs.cut_area_change.get(i) };
    }

    pub fn addCutAreaBands(rs: *RuleSet, gpa: Allocator, b: tables.CutAreaBands) Allocator.Error!u32 {
        _ = try rs.cut_area_cuts.push(gpa, b.cuts);
        return rs.cut_area_change.push(gpa, b.change);
    }

    pub fn defectSizes(rs: *const RuleSet, i: u32) tables.DefectSizes {
        return .{ .radius = rs.defect_radius.get(i), .weight = rs.defect_weight.get(i) };
    }

    pub fn addDefectSizes(rs: *RuleSet, gpa: Allocator, d: tables.DefectSizes) Allocator.Error!u32 {
        _ = try rs.defect_radius.push(gpa, d.radius);
        return rs.defect_weight.push(gpa, d.weight);
    }

    /// The drawn layers derived `layer` is computed from, for `net_spacing`;
    /// empty for a drawn layer.
    pub fn netSources(rs: *const RuleSet, layer: LayerId) []const LayerId {
        for (rs.net_source_layer.items, 0..) |l, i| if (l == layer) return rs.net_source_drawn.get(@intCast(i));
        return &.{};
    }
};

/// Ragged rows: row `i` is `items[start[i]..start[i + 1]]`. Invariant:
/// `start` is empty or one longer than the row count and ascends.
pub fn Csr(comptime T: type) type {
    return struct {
        const Self = @This();

        start: std.ArrayList(u32) = .empty,
        items: std.ArrayList(T) = .empty,

        pub fn deinit(c: *Self, gpa: Allocator) void {
            c.start.deinit(gpa);
            c.items.deinit(gpa);
        }

        pub fn len(c: *const Self) u32 {
            return @intCast(c.start.items.len -| 1);
        }

        pub fn get(c: *const Self, i: u32) []const T {
            return c.items.items[c.start.items[i]..c.start.items[i + 1]];
        }

        /// Appends one row; returns its index.
        pub fn push(c: *Self, gpa: Allocator, items: []const T) Allocator.Error!u32 {
            assert(c.items.items.len + items.len <= std.math.maxInt(u32));
            if (c.start.items.len == 0) try c.start.append(gpa, 0);
            try c.items.appendSlice(gpa, items);
            try c.start.append(gpa, @intCast(c.items.items.len));
            return c.len() - 1;
        }
    };
}

test "a pushed rule reads back from its kind's table in deck order" {
    // Oracle: round trip. Two kinds interleaved keep their deck order and
    // each row lands in its own kind's table.
    const gpa = std.testing.allocator;
    var rs: RuleSet = .{};
    defer rs.deinit(gpa);
    const a: LayerId = @fromBackingInt(0);
    try rs.push(gpa, @fromBackingInt(1), .{ .min_width = .{ .layer = a, .limit = 140 } }, .@"error");
    try rs.push(gpa, @fromBackingInt(2), .{ .min_area = .{ .layer = a, .limit = 900 } }, .warning);
    try rs.push(gpa, @fromBackingInt(3), .{ .min_width = .{ .layer = a, .limit = 200 } }, .@"error");
    try std.testing.expectEqual(@as(u32, 3), rs.len());
    try std.testing.expectEqual(@as(usize, 2), rs.table(.min_width).len);
    try std.testing.expectEqual(@as(Dbu, 200), rs.get(2).min_width.limit);
    try std.testing.expectEqual(@as(DbuArea, 900), rs.get(1).min_area.limit);
    const t = try rs.addSpacingTable(gpa, .{ .prl = &.{0}, .width = &.{0}, .space = &.{5} });
    try std.testing.expectEqual(@as(Dbu, 5), rs.spacingTable(t).at(0, 0));
}
