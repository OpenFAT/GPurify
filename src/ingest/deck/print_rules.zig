//! A `RuleSource` → one `rule` statement: its kind-table row found back from
//! the engine kind, layer count, required values and fixed flags, the deck
//! layer order restored, every parameter spelled in its deck unit. Ported
//! from crates/ingest/src/deck/print.rs (`rule`, `value`, `kind_of`,
//! `may_be_unstated`, `is_rule_id`).
//!
//! Contents:
//! - `pub fn rule(p: *const Printer, r: RuleSource) PrintError![]const u8`

const std = @import("std");
const kinds = @import("kinds.zig");
const Kind = kinds.Kind;
const Param = kinds.Param;
const Dim = kinds.Dim;
const source = @import("source.zig");
const RuleSource = source.RuleSource;
const ParamSource = source.ParamSource;
const print_layers = @import("print_layers.zig");
const Printer = print_layers.Printer;
const PrintError = print_layers.PrintError;

/// One rule statement.
pub fn rule(p: *const Printer, r: RuleSource) PrintError![]const u8 {
    if (!isRuleId(r.id)) return p.unprintable("rule id `{s}` holds a character no rule statement can write", .{r.id});
    const kind = try kindOf(p, r);
    const fixed = kind.layers.len;
    // Deck argument `slot` is the engine's layer `at` where `layers[at] == slot`.
    const deck = try p.arena.alloc([]const u8, r.layers.len);
    for (kind.layers, 0..) |slot, at| deck[slot] = r.layers[at];
    @memcpy(deck[fixed..], r.layers[fixed..]);
    var positional: std.ArrayList([]const u8) = .empty;
    for (deck) |layer| try positional.append(p.arena, if (print_layers.hidden(layer)) try p.expr(try p.row(layer)) else layer);
    if (kind.modifier) |m| try positional.append(p.arena, m);
    var named: std.ArrayList([]const u8) = .empty;
    for (kind.params) |prm| try named.append(p.arena, try std.fmt.allocPrint(p.arena, "{s}: {s}", .{ prm.name, try value(p, r, prm) }));
    const warning = for (r.params) |prm| {
        if (eql(prm.name, "warning") and prm.value == .value and prm.value.value == .flag and prm.value.value.flag) break true;
    } else false;
    var text: std.ArrayList(u8) = .empty;
    try text.print(p.arena, "rule {s}{s} {s}({s}", .{ r.id, if (warning) " warning" else "", kind.name, try std.mem.join(p.arena, ", ", positional.items) });
    if (named.items.len > 0) try text.print(p.arena, "; {s}", .{try std.mem.join(p.arena, ", ", named.items)});
    try text.append(p.arena, ')');
    if (kind.limit) |limit| {
        const cmp = switch (kind.cmp) {
            .ge => ">=",
            .le => "<=",
            .eq => "==",
            .absent => "",
        };
        var with_name = limit;
        with_name.name = kind.name;
        try text.print(p.arena, " {s} {s}", .{ cmp, try value(p, r, with_name) });
    }
    return text.items;
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether a `rule` statement can write `id`: letters, digits, `_` and `.`.
fn isRuleId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    return true;
}

/// Whether a parameter of kind `dim` may have no stated value: an empty
/// list, or a group whose parts are each checked on their own.
fn mayBeUnstated(dim: Dim) bool {
    return switch (dim) {
        .angle_list, .models, .names, .length_list, .length_rows, .group => true,
        else => false, // else: every other dimension states a value
    };
}

/// The values `rule` states under the engine name `engine`.
fn stated(p: *const Printer, r: RuleSource, engine: []const u8) PrintError![]const ParamSource {
    var out: std.ArrayList(ParamSource) = .empty;
    for (r.params) |prm| if (eql(prm.name, engine)) try out.append(p.arena, prm.value);
    return out.items;
}

fn isFlag(v: ParamSource, on: bool) bool {
    return v == .value and v.value == .flag and v.value.flag == on;
}

/// The kind-table row a rule is written with: its engine kind, its layer
/// count, its required values stated and its fixed flags set; the row
/// knowing the most stated values, the first on a tie.
fn kindOf(p: *const Printer, r: RuleSource) PrintError!*const Kind {
    const layers = r.layers.len;
    var best: ?*const Kind = null;
    var best_known: usize = 0;
    for (kinds.kinds) |*k| {
        if (!eql(k.engine, r.kind)) continue;
        if (!(layers == k.layers.len or (k.more and layers > k.layers.len))) continue;
        const required = for (0..paramCount(k)) |i| {
            const prm = paramAt(k, i);
            if (prm.none or mayBeUnstated(prm.dim)) continue;
            const given = for (r.params) |s| {
                if (eql(s.name, prm.engine)) break true;
            } else false;
            if (!given) break false;
        } else true;
        if (!required) continue;
        const flags = for (k.fixed) |f| {
            const set = for (r.params) |s| {
                if (eql(s.name, f[0]) and isFlag(s.value, f[1])) break true;
            } else false;
            if (!set) break false;
        } else true;
        if (!flags) continue;
        var known: usize = 0;
        for (r.params) |s| {
            for (0..paramCount(k)) |i| if (eql(paramAt(k, i).engine, s.name)) {
                known += 1;
                break;
            };
        }
        if (best == null or known > best_known) {
            best = k;
            best_known = known;
        }
    }
    return best orelse p.unprintable("rule {s}: no deck spelling of {s} with {d} layers", .{ r.id, r.kind, layers });
}

/// How many params a kind chains: its limit (if any), then its params.
fn paramCount(k: *const Kind) usize {
    return k.params.len + @intFromBool(k.limit != null);
}

/// Param `i` of the chain `paramCount` counts.
fn paramAt(k: *const Kind, i: usize) Param {
    if (k.limit) |l| return if (i == 0) l else k.params[i - 1];
    return k.params[i];
}

/// One parameter's value as the deck writes it, `none` when an optional
/// one is absent.
fn value(p: *const Printer, r: RuleSource, prm: Param) PrintError![]const u8 {
    const values = try stated(p, r, prm.engine);
    if (values.len == 0 and prm.dim != .group) {
        if (prm.none) return "none";
        if (!mayBeUnstated(prm.dim)) return p.unprintable("rule {s}: {s} has no {s}", .{ r.id, r.kind, prm.engine });
    }
    switch (prm.dim) {
        .layer => return if (values[0] == .layer) values[0].layer else wrong(p, r, prm),
        .models, .names => {
            if (values.len == 0) return if (prm.none) "none" else "[]";
            const names = try p.arena.alloc([]const u8, values.len);
            for (values, names) |v, *n| n.* = if (v == .model) try p.quoted(v.model) else return wrong(p, r, prm);
            return std.fmt.allocPrint(p.arena, "[{s}]", .{try std.mem.join(p.arena, ", ", names)});
        },
        .length_pair => |second| {
            const other = try stated(p, r, second);
            if (other.len == 0) return p.unprintable("rule {s}: {s} has no {s}", .{ r.id, r.kind, prm.engine });
            return std.fmt.allocPrint(p.arena, "{s} x {s}", .{ try one(p, r, prm, values[0]), try one(p, r, prm, other[0]) });
        },
        .angle_list, .length_list, .voltage_list, .fraction_list, .opt_length_list, .frequency_list, .count_list, .area_list => return listOf(p, r, prm, values),
        .length_pair_list, .area_table => |second| {
            const others = try stated(p, r, second);
            if (values.len != others.len) return p.unprintable("rule {s}: {s} has no {s}", .{ r.id, r.kind, prm.engine });
            const pairs = try p.arena.alloc([]const u8, values.len);
            for (values, others, pairs) |a, b, *out| out.* = if (prm.dim == .length_pair_list)
                try std.fmt.allocPrint(p.arena, "{s} x {s}", .{ try one(p, r, prm, a), try one(p, r, prm, b) })
            else if (a == .value and a.value == .area and b == .value and b.value == .ratio)
                try std.fmt.allocPrint(p.arena, "({s}, {s})", .{ try p.area(a.value.area), try p.number(b.value.ratio) })
            else
                return wrong(p, r, prm);
            return std.fmt.allocPrint(p.arena, "[{s}]", .{try std.mem.join(p.arena, ", ", pairs)});
        },
        .current_per_width_rows, .length_rows => {
            // A current table has one row per frequency and one cell per
            // width; a spacing table a column per run, and one without runs
            // (a tip table) is square.
            const runs = (try stated(p, r, "prl")).len;
            const columns: usize = if (prm.dim == .current_per_width_rows) @max((try stated(p, r, "width")).len, 1) else if (runs == 0) blk: {
                var side: usize = 1;
                while (side * side < values.len) side += 1;
                break :blk side;
            } else runs;
            var rows: std.ArrayList([]const u8) = .empty;
            var at: usize = 0;
            while (at < values.len) : (at += columns) {
                try rows.append(p.arena, try listOf(p, r, prm, values[at..@min(at + columns, values.len)]));
            }
            return std.fmt.allocPrint(p.arena, "[{s}]", .{try std.mem.join(p.arena, ", ", rows.items)});
        },
        .group => |inner| {
            if (inner.len == 0) return wrong(p, r, prm);
            if ((try stated(p, r, inner[0].engine)).len == 0) {
                if (prm.none) return "none";
                return p.unprintable("rule {s}: {s} has no {s}", .{ r.id, r.kind, prm.engine });
            }
            const parts = try p.arena.alloc([]const u8, inner.len);
            for (inner, parts) |in, *out| out.* = try std.fmt.allocPrint(p.arena, "{s}: {s}", .{ in.name, try value(p, r, in) });
            return std.fmt.allocPrint(p.arena, "({s})", .{try std.mem.join(p.arena, ", ", parts)});
        },
        else => return one(p, r, prm, values[0]), // else: every other dimension is one value
    }
}

fn wrong(p: *const Printer, r: RuleSource, prm: Param) PrintError {
    return p.unprintable("rule {s}: {s} is not a value of its kind", .{ r.id, prm.engine });
}

fn listOf(p: *const Printer, r: RuleSource, prm: Param, values: []const ParamSource) PrintError![]const u8 {
    const each = try p.arena.alloc([]const u8, values.len);
    for (values, each) |v, *e| e.* = try one(p, r, prm, v);
    return std.fmt.allocPrint(p.arena, "[{s}]", .{try std.mem.join(p.arena, ", ", each)});
}

/// One value of `prm`'s kind, in its deck unit.
fn one(p: *const Printer, r: RuleSource, prm: Param, v: ParamSource) PrintError![]const u8 {
    if (v != .value) return wrong(p, r, prm);
    const val = v.value;
    switch (prm.dim) {
        .length, .length_pair, .length_pair_list, .length_list, .opt_length_list, .length_rows => switch (val) {
            .length => |len| return p.dbu(len),
            .flag => |f| if (prm.dim == .opt_length_list and !f) return "none",
            else => {}, // else: any other value is not a length's
        },
        .area, .area_list => if (val == .area) return p.area(val.area),
        .count, .count_list => if (val == .count) return std.fmt.allocPrint(p.arena, "{d}", .{val.count}),
        .word => |words| if (val == .count and val.count < words.len) return words[val.count],
        .angle_list => if (val == .count) return std.fmt.allocPrint(p.arena, "{d}deg", .{val.count}),
        .bool => if (val == .flag) return if (val.flag) "true" else "false",
        .nets => if (val == .flag) return if (val.flag) "same" else "different",
        else => {}, // else: the rest are numbers, below
    }
    if (val != .ratio) return wrong(p, r, prm);
    const unit: []const u8 = switch (prm.dim) {
        .voltage, .voltage_list => "mV",
        .frequency, .frequency_list => "MHz",
        .field => "V/um",
        .current => "uA",
        .current_per_width, .current_per_width_rows => "A/m",
        .resistance => "ohm",
        .temperature => "K",
        .energy => "eV",
        .thermal_conductivity => "W/mK",
        .time => "h",
        .cap_per_area => "aF/um2",
        .cap_per_length => "aF/um",
        .angle => "deg",
        .fraction, .fraction_list, .scalar => "",
        else => return wrong(p, r, prm), // else: no other dimension holds a ratio
    };
    return std.fmt.allocPrint(p.arena, "{s}{s}", .{ try p.number(val.ratio), unit });
}
