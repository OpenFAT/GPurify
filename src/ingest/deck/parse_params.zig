//! A rule's named arguments → engine parameter rows: every parameter the
//! kind lists required (unless it takes `none`), none unknown or given
//! twice, each value converted by its `Dim` (a list is one row per element,
//! a pair two rows). Also the cross-argument checks of a spacing table and
//! an end-of-line extension table. Ported from crates/ingest/src/deck/parse.rs
//! (`named`, `param`, `lengths`, `list`, `spacing_table`, `eol_extension_rows`).
//!
//! Contents:
//! - `pub fn named(p: *Parser, given: []const Named, params: []const Param, owner: []const u8, owner_span: Span, out: *std.ArrayList(NamedSource)) PErr!void`
//! - `pub fn param(p: *Parser, v: Val, prm: Param, out: *std.ArrayList(NamedSource)) PErr!void`
//! - `pub fn spacingTable(p: *Parser, given: []const Named) PErr!void`
//! - `pub fn eolExtensionRows(p: *Parser, given: []const Named) PErr!void`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Span = parser.Span;
const Val = parser.Val;
const Named = parser.Named;
const kinds = @import("kinds.zig");
const Param = kinds.Param;
const NamedSource = @import("source.zig").NamedSource;
const ParamValue = @import("tables.zig").ParamValue;
const convert = @import("convert.zig");

/// Matches named arguments to `params` by name: every one required, none
/// unknown. Reports every problem before stopping.
pub fn named(p: *Parser, given: []const Named, params: []const Param, owner: []const u8, owner_span: Span, out: *std.ArrayList(NamedSource)) PErr!void {
    var failed = false;
    for (given, 0..) |arg, at| {
        const twice = for (given[0..at]) |prev| {
            if (std.mem.eql(u8, prev.name, arg.name)) break true;
        } else false;
        if (twice) {
            try noted(p.fail(arg.span, "`{s}` is given twice", .{arg.name}));
            failed = true;
        } else if (findParam(params, arg.name) == null) {
            const hint = if (params.len == 0) "it takes none" else blk: {
                var names: std.ArrayList([]const u8) = .empty;
                for (params) |prm| try names.append(p.scratch, prm.name);
                break :blk try std.fmt.allocPrint(p.scratch, "expected {s}", .{try std.mem.join(p.scratch, ", ", names.items)});
            };
            try noted(p.fail(arg.span, "unknown parameter `{s}` for {s}; {s}", .{ arg.name, owner, hint }));
            failed = true;
        }
    }
    for (params) |prm| {
        const arg = for (given) |a| {
            if (std.mem.eql(u8, a.name, prm.name)) break a;
        } else {
            try noted(p.fail(owner_span, "{s} is missing parameter `{s}`", .{ owner, prm.name }));
            failed = true;
            continue;
        };
        param(p, arg.value, prm, out) catch |err| {
            try noted(err);
            failed = true;
        };
    }
    if (failed) return error.Stop;
}

/// Converts one value to its engine param row(s).
pub fn param(p: *Parser, v: Val, prm: Param, out: *std.ArrayList(NamedSource)) PErr!void {
    const label = prm.name;
    if (v == .word and std.mem.eql(u8, v.word.name, "none")) {
        if (prm.none) return;
        return p.fail(v.span(), "`{s}` cannot be none", .{label});
    }
    const engine = prm.engine;
    const one: ParamValue = switch (prm.dim) {
        .length => .{ .length = try convert.length(p, v, label) },
        .area => .{ .area = try convert.area(p, v, label) },
        .count => .{ .count = try convert.count(p, v, label) },
        .bool => if (v == .word and (eql(v.word.name, "true") or eql(v.word.name, "false"))) .{ .flag = eql(v.word.name, "true") } else return p.wrong(v, "true or false", label),
        .layer => return push(p, out, engine, .{ .layer = try p.layerName(v) }),
        .length_pair => |second| {
            if (v != .pair) return p.wrong(v, "a pair `a x b` of lengths", label);
            const a = try convert.length(p, v.pair.a.*, label);
            const b = try convert.length(p, v.pair.b.*, label);
            try pushValue(p, out, engine, .{ .length = a });
            return pushValue(p, out, second, .{ .length = b });
        },
        .angle_list => {
            for (try list(p, v, "a list of angles", "angle", label)) |item| {
                const degrees = try convert.quantity(p, item, .angle, label);
                const whole = if (degrees.integer()) |d| std.math.cast(u32, d) else null;
                try pushValue(p, out, engine, .{ .count = whole orelse return p.fail(item.span(), "an angle is a whole, non-negative number of degrees", .{}) });
            }
            return;
        },
        .models, .names => {
            const what = if (prm.dim == .models) "model" else "name";
            const one_text = if (prm.dim == .models) "a model name in quotes" else "a name in quotes";
            const none = try std.fmt.allocPrint(p.scratch, "{s}; write none for no {s}s", .{ what, what });
            for (try list(p, v, kinds.dimName(prm.dim), none, label)) |item| {
                if (item != .str) return p.wrong(item, one_text, label);
                try push(p, out, engine, .{ .model = item.str.text });
            }
            return;
        },
        .word => |words| blk: {
            if (v == .word) for (words, 0..) |w, at| if (eql(w, v.word.name)) break :blk .{ .count = @intCast(at) };
            return p.wrong(v, try std.mem.join(p.scratch, " or ", words), label);
        },
        .nets => if (v == .word and (eql(v.word.name, "same") or eql(v.word.name, "different"))) .{ .flag = eql(v.word.name, "same") } else return p.wrong(v, "same or different", label),
        .length_list => {
            for (try lengths(p, v, label)) |item| try pushValue(p, out, engine, .{ .length = item });
            return;
        },
        .length_pair_list => |second| {
            for (try list(p, v, "a list of pairs `a x b` of lengths", "pair", label)) |item| {
                if (item != .pair) return p.wrong(item, "a pair `a x b` of lengths", label);
                const a = try convert.length(p, item.pair.a.*, label);
                const b = try convert.length(p, item.pair.b.*, label);
                try pushValue(p, out, engine, .{ .length = a });
                try pushValue(p, out, second, .{ .length = b });
            }
            return;
        },
        .voltage_list, .frequency_list => {
            const voltage = prm.dim == .voltage_list;
            const want: []const u8 = if (voltage) "a list of voltages" else "a list of frequencies";
            const one_text: []const u8 = if (voltage) "voltage" else "frequency";
            const dim: kinds.Dim = if (voltage) .voltage else .frequency;
            for (try list(p, v, want, one_text, label)) |item| try pushValue(p, out, engine, .{ .ratio = (try convert.quantity(p, item, dim, label)).toF64() });
            return;
        },
        .current_per_width_rows => {
            const want = "a list of rows of currents per width";
            for (try list(p, v, want, "row", label)) |row| {
                if (row != .list) return p.wrong(row, want, label);
                for (row.list.items) |item| try pushValue(p, out, engine, .{ .ratio = (try convert.quantity(p, item, .current_per_width, label)).toF64() });
            }
            return;
        },
        .count_list, .area_list => {
            for (try list(p, v, kinds.dimName(prm.dim), "value", label)) |item| {
                const stated: ParamValue = if (prm.dim == .count_list) .{ .count = try convert.count(p, item, label) } else .{ .area = try convert.area(p, item, label) };
                try pushValue(p, out, engine, stated);
            }
            return;
        },
        .fraction_list => {
            for (try list(p, v, "a list of fractions", "fraction", label)) |item| {
                const f = (try convert.quantity(p, item, .fraction, label)).toF64();
                if (!(f >= 0.0 and f <= 1.0)) return p.fail(item.span(), "`{s}` holds fractions: 0 to 1, or 0% to 100%", .{label});
                try pushValue(p, out, engine, .{ .ratio = f });
            }
            return;
        },
        .opt_length_list => {
            for (try list(p, v, "a list of lengths or none", "entry", label)) |item| {
                const stated: ParamValue = if (item == .word and eql(item.word.name, "none")) .{ .flag = false } else .{ .length = try convert.length(p, item, label) };
                try pushValue(p, out, engine, stated);
            }
            return;
        },
        .length_rows => {
            if (v != .list) return p.wrong(v, "a list of rows of lengths", label);
            for (v.list.items) |row| for (try lengths(p, row, label)) |item| try pushValue(p, out, engine, .{ .length = item });
            return;
        },
        .area_table => |second| return areaTable(p, v, label, engine, second, out),
        .group => |inner| {
            if (v != .group) return p.wrong(v, "named arguments `(name: value, ..)`", label);
            const owner = try std.fmt.allocPrint(p.scratch, "`{s}`", .{label});
            return named(p, v.group.named, inner, owner, v.group.span, out);
        },
        .fraction => blk: {
            const f = (try convert.quantity(p, v, .fraction, label)).toF64();
            if (!(f >= 0.0 and f <= 1.0)) return p.fail(v.span(), "`{s}` is a fraction: 0 to 1, or 0% to 100%", .{label});
            break :blk .{ .ratio = f };
        },
        .voltage, .current, .current_per_width, .resistance, .temperature, .energy, .thermal_conductivity, .time, .field, .cap_per_area, .cap_per_length, .per_kelvin, .per_kelvin2, .capacitance, .inductance, .angle, .scalar, .frequency => .{ .ratio = try convert.physical(p, v, prm.dim, label) },
    };
    return pushValue(p, out, engine, one);
}

/// A spacing table is complete and monotone: `prl` and `width` start at
/// zero and rise, `space` has one row per width and one cell per run
/// length, and no cell is below the one before it in its row or column.
pub fn spacingTable(p: *Parser, given: []const Named) PErr!void {
    var counts: [2]usize = undefined;
    for ([_][]const u8{ "prl", "width" }, &counts) |key, *count| {
        const v = argValue(given, key);
        const steps = try lengths(p, v, key);
        if (steps[0] != 0) return p.fail(v.span(), "`{s}` starts at 0, so every pair has a row and a column", .{key});
        for (steps[0 .. steps.len - 1], steps[1..]) |a, b| if (a >= b) return p.fail(v.span(), "`{s}` must rise strictly", .{key});
        count.* = steps.len;
    }
    const columns = counts[0];
    const rows = counts[1];
    const space = argValue(given, "space");
    if (space != .list) return p.wrong(space, "a list of rows of lengths", "space");
    if (space.list.items.len != rows) return p.fail(space.list.span, "`space` needs one row per width: {d}, got {d}", .{ rows, space.list.items.len });
    var above: []const Dbu = &.{};
    for (space.list.items) |line| {
        const cells = try lengths(p, line, "space");
        if (cells.len != columns) return p.fail(line.span(), "a `space` row needs one cell per run length: {d}, got {d}", .{ columns, cells.len });
        if (cells[0] <= 0) return p.fail(line.span(), "a spacing must be positive", .{});
        var falls = false;
        for (cells[0 .. cells.len - 1], cells[1..]) |a, b| falls = falls or b < a;
        for (above, cells[0..above.len]) |up, cell| falls = falls or cell < up;
        if (falls) return p.fail(line.span(), "`space` cannot fall along a row or down a column", .{});
        above = cells;
    }
}

/// `LEF58_EOLEXTENSIONSPACING`'s rows: at most three, `eol_width` rising
/// strictly, one `extension` and one `end_to_end` entry per width.
pub fn eolExtensionRows(p: *Parser, given: []const Named) PErr!void {
    const width = argValue(given, "eol_width");
    const widths = try lengths(p, width, "eol_width");
    if (widths.len > 3) return p.fail(width.span(), "`eol_width` holds at most three rows", .{});
    for (widths[0 .. widths.len - 1], widths[1..]) |a, b| if (a >= b) return p.fail(width.span(), "`eol_width` must rise strictly", .{});
    for ([_][]const u8{ "extension", "end_to_end" }) |key| {
        const v = argValue(given, key);
        if (v == .list and v.list.items.len != widths.len) {
            return p.fail(v.list.span, "`{s}` needs one entry per `eol_width`: {d}, got {d}", .{ key, widths.len, v.list.items.len });
        }
    }
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Keeps going past a recorded error; anything else (out of memory) stops.
fn noted(err: PErr) PErr!void {
    if (err != error.Stop) return err;
}

fn findParam(params: []const Param, name: []const u8) ?Param {
    for (params) |prm| if (eql(prm.name, name)) return prm;
    return null;
}

/// The value of an argument `named` already checked is given.
fn argValue(given: []const Named, key: []const u8) Val {
    for (given) |a| if (eql(a.name, key)) return a.value;
    unreachable;
}

fn push(p: *Parser, out: *std.ArrayList(NamedSource), engine: []const u8, value: @import("source.zig").ParamSource) PErr!void {
    try out.append(p.arena, .{ .name = engine, .value = value });
}

fn pushValue(p: *Parser, out: *std.ArrayList(NamedSource), engine: []const u8, value: ParamValue) PErr!void {
    try push(p, out, engine, .{ .value = value });
}

/// `[a, b, ..]`, a non-empty list of lengths.
fn lengths(p: *Parser, v: Val, label: []const u8) PErr![]const Dbu {
    const items = try list(p, v, "a list of lengths", "length", label);
    const out = try p.scratch.alloc(Dbu, items.len);
    for (items, out) |item, *o| o.* = try convert.length(p, item, label);
    return out;
}

/// `v` as a non-empty list: `want` names a list in an error, `one` an item.
fn list(p: *Parser, v: Val, want: []const u8, one: []const u8, label: []const u8) PErr![]const Val {
    if (v != .list) return p.wrong(v, want, label);
    if (v.list.items.len == 0) return p.fail(v.list.span, "`{s}` needs at least one {s}", .{ label, one });
    return v.list.items;
}

/// `[(area, n), ..]`, areas from 0 rising strictly; per point the area to
/// `engine` and the number to `second`.
fn areaTable(p: *Parser, v: Val, label: []const u8, engine: []const u8, second: []const u8, out: *std.ArrayList(NamedSource)) PErr!void {
    const want = "a list of (area, number) points";
    var previous: ?DbuArea = null;
    for (try list(p, v, want, "point", label)) |item| {
        if (item != .tuple or item.tuple.items.len != 2) return p.wrong(item, want, label);
        const a = try convert.area(p, item.tuple.items[0], label);
        if (a < 0 or (previous != null and a <= previous.?)) return p.fail(item.span(), "`{s}`'s areas start at 0 or more and rise strictly", .{label});
        previous = a;
        const number = try convert.physical(p, item.tuple.items[1], .scalar, label);
        try pushValue(p, out, engine, .{ .area = a });
        try pushValue(p, out, second, .{ .ratio = number });
    }
}
