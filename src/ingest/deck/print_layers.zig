//! The deck printer's state and its value spellings: numbers as the
//! shortest decimal that reads back to them, lengths and areas in nm from
//! grid units exactly, quoted strings, and a derived layer back to the
//! expression that made it (a hidden layer inline, in parentheses).
//! Ported from crates/ingest/src/deck/print.rs (`Printer`, `decimal`,
//! `number`, `quoted`, `signed_root`, `length`, `area`, `operand`, `expr`,
//! `bounds`, `hidden`).
//!
//! Contents:
//! - `pub const PrintError`, `pub const Printer`,
//!   `Printer.unprintable(p: *const Printer, comptime fmt: []const u8, args: anytype) PrintError`,
//!   `Printer.length(p: *const Printer, raw: i128) PrintError![]const u8`,
//!   `Printer.dbu(p: *const Printer, len: Dbu) PrintError![]const u8`,
//!   `Printer.area(p: *const Printer, a: DbuArea) PrintError![]const u8`,
//!   `Printer.number(p: *const Printer, value: f64) PrintError![]const u8`,
//!   `Printer.quoted(p: *const Printer, text: []const u8) PrintError![]const u8`,
//!   `Printer.quotedAll(p: *const Printer, texts: []const []const u8, sep: []const u8) PrintError![]const u8`,
//!   `Printer.row(p: *const Printer, name: []const u8) PrintError!DerivedSource`,
//!   `Printer.expr(p: *const Printer, r: DerivedSource) PrintError![]const u8`
//! - `pub fn hidden(name: []const u8) bool`
//! - `pub fn decimal(arena: Allocator, numerator: i128, denominator: i128) Allocator.Error!?[]const u8`
//! - `pub fn signedRoot(squared: i128) ?i64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Grid = geom.Grid;
const source = @import("source.zig");
const DeckSource = source.DeckSource;
const DerivedSource = source.DerivedSource;

/// The deck language cannot state a value exactly; `Printer.why` says which.
pub const PrintError = error{ Unprintable, OutOfMemory };

/// What every spelling allocates in and reports through.
pub const Printer = struct {
    arena: Allocator,
    source: *const DeckSource,
    grid: Grid,
    why: *[]const u8,

    /// `Unprintable`, the reason formatted into `why`.
    pub fn unprintable(p: *const Printer, comptime fmt: []const u8, args: anytype) PrintError {
        p.why.* = try std.fmt.allocPrint(p.arena, fmt, args);
        return error.Unprintable;
    }

    /// A length in grid units, in nanometres.
    pub fn length(p: *const Printer, raw: i128) PrintError![]const u8 {
        const nm = try decimal(p.arena, raw * 1000, p.grid.dbu_per_um) orelse return p.unprintable("{d} grid units is no terminating decimal of a nanometre", .{raw});
        return std.fmt.allocPrint(p.arena, "{s}nm", .{nm});
    }

    pub fn dbu(p: *const Printer, len: Dbu) PrintError![]const u8 {
        return p.length(len);
    }

    /// An area in square grid units, in square nanometres.
    pub fn area(p: *const Printer, a: DbuArea) PrintError![]const u8 {
        const per_um: i128 = p.grid.dbu_per_um;
        const nm2 = try decimal(p.arena, a * 1_000_000, per_um * per_um) orelse return p.unprintable("{d} square grid units is no terminating decimal of a square nanometre", .{a});
        return std.fmt.allocPrint(p.arena, "{s}nm2", .{nm2});
    }

    /// A finite number as the shortest decimal that reads back to it.
    pub fn number(p: *const Printer, value: f64) PrintError![]const u8 {
        if (!std.math.isFinite(value)) return p.unprintable("{d} is not a number a deck can state", .{value});
        return std.fmt.allocPrint(p.arena, "{e}", .{value});
    }

    /// A string in quotes, `"` and `\` escaped.
    pub fn quoted(p: *const Printer, text: []const u8) PrintError![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '\n') != null) return p.unprintable("\"{f}\" holds a line break", .{std.zig.fmtString(text)});
        var out: std.ArrayList(u8) = .empty;
        try out.append(p.arena, '"');
        for (text) |c| {
            if (c == '\\' or c == '"') try out.append(p.arena, '\\');
            try out.append(p.arena, c);
        }
        try out.append(p.arena, '"');
        return out.items;
    }

    /// Each of `texts` quoted, joined by `sep`.
    pub fn quotedAll(p: *const Printer, texts: []const []const u8, sep: []const u8) PrintError![]const u8 {
        const each = try p.arena.alloc([]const u8, texts.len);
        for (texts, each) |t, *e| e.* = try p.quoted(t);
        return std.mem.join(p.arena, sep, each);
    }

    /// The derived row named `name`.
    pub fn row(p: *const Printer, name: []const u8) PrintError!DerivedSource {
        for (p.source.derived.items) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return p.unprintable("layer {s} is not declared", .{name});
    }

    /// The expression a derived row computes.
    pub fn expr(p: *const Printer, r: DerivedSource) PrintError![]const u8 {
        const arg = struct {
            fn at(q: *const Printer, rr: DerivedSource, i: usize) PrintError![]const u8 {
                if (i >= rr.layers.len) return q.unprintable("layer {s} misses an operand", .{rr.name});
                return rr.layers[i];
            }
        }.at;
        return switch (r.op) {
            .@"and" => p.fold(r, "and"),
            .@"or" => p.fold(r, "or"),
            .not => p.fold(r, "not"),
            .sized => |s| p.call(r, "sized", if (s.dx == s.dy) try p.dbu(s.dx) else try std.fmt.allocPrint(p.arena, "{s}, {s}", .{ try p.dbu(s.dx), try p.dbu(s.dy) })),
            .overlapping => p.call(r, "overlapping", try p.operand(try arg(p, r, 1))),
            .covering => |keep| p.call(r, if (keep) "covering" else "not_covering", try p.operand(try arg(p, r, 1))),
            .extended => |e| p.call(r, "extended", try std.fmt.allocPrint(p.arena, "begin: {s}, end: {s}, out: {s}, in: {s}", .{ try p.dbu(e.begin), try p.dbu(e.end), try p.dbu(e.outside), try p.dbu(e.inside) })),
            .interacting => |keep| p.call(r, if (keep) "interacting" else "not_interacting", try p.operand(try arg(p, r, 1))),
            .inside => p.call(r, "inside", try p.operand(try arg(p, r, 1))),
            .outside => p.call(r, "outside", try p.operand(try arg(p, r, 1))),
            .part => |inside| p.call(r, if (inside) "inside_part" else "outside_part", try p.operand(try arg(p, r, 1))),
            .holes => p.call(r, "holes", ""),
            .rectangles => |x| p.call(r, if (x.keep) (if (x.square) "squares" else "rectangles") else (if (x.square) "non_squares" else "non_rectangles"), ""),
            .oriented => |vertical| p.call(r, if (vertical) "vertical" else "horizontal", ""),
            .with_bbox => |b| p.call(r, if (b.longer) "with_bbox_max" else "with_bbox_min", try p.bounds(r.name, b.lo, b.hi, .length)),
            .with_rect => |w| p.call(r, if (w.keep) "with_rect" else "without_rect", try std.fmt.allocPrint(p.arena, "{s} x {s}", .{ try p.dbu(w.w), try p.dbu(w.h) })),
            .extents => p.call(r, "extents", ""),
            .edges => p.call(r, "edges", ""),
            .with_area => |b| p.call(r, "with_area", try p.bounds(r.name, b.lo, b.hi, .area)),
            .with_length => |b| p.call(r, "with_length", try p.bounds(r.name, b.lo, b.hi, .length)),
            .with_width => |b| p.call(r, "with_width", try p.widthBounds(r.name, b.lo, b.hi)),
            .texts_outside => p.call(r, "texts_outside", try arg(p, r, 1)),
            .with_text => |w| blk: {
                if (w.text >= p.source.texts.items.len) return p.unprintable("layer {s}: no text pattern", .{r.name});
                const pattern = p.source.texts.items[w.text];
                break :blk p.call(r, if (w.keep) "with_text" else "without_text", try std.fmt.allocPrint(p.arena, "{s}, {s}", .{ try arg(p, r, 1), try p.quoted(pattern) }));
            },
            .in_cells => |c| blk: {
                const end = @addWithOverflow(c.first, c.count);
                if (end[1] != 0 or end[0] > p.source.texts.items.len) return p.unprintable("layer {s}: no cell-name pattern", .{r.name});
                break :blk p.call(r, if (c.keep) "in_cells" else "not_in_cells", try p.quotedAll(p.source.texts.items[c.first..end[0]], ", "));
            },
        };
    }

    // ---- private ----

    /// A layer as an operand: its name, or a hidden layer's expression in
    /// parentheses.
    fn operand(p: *const Printer, name: []const u8) PrintError![]const u8 {
        if (!hidden(name)) return name;
        return std.fmt.allocPrint(p.arena, "({s})", .{try p.expr(try p.row(name))});
    }

    fn fold(p: *const Printer, r: DerivedSource, word: []const u8) PrintError![]const u8 {
        const each = try p.arena.alloc([]const u8, r.layers.len);
        for (r.layers, each) |l, *e| e.* = try p.operand(l);
        return std.mem.join(p.arena, try std.fmt.allocPrint(p.arena, " {s} ", .{word}), each);
    }

    fn call(p: *const Printer, r: DerivedSource, method: []const u8, argument: []const u8) PrintError![]const u8 {
        if (r.layers.len == 0) return p.unprintable("layer {s} misses an operand", .{r.name});
        return std.fmt.allocPrint(p.arena, "{s}.{s}({s})", .{ try p.operand(r.layers[0]), method, argument });
    }

    /// Inclusive bounds as comparisons; an absent side is the `i128` extreme.
    fn bounds(p: *const Printer, layer: []const u8, lo: i128, hi: i128, kind: enum { length, area }) PrintError![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        for ([2]i128{ lo, hi }, [2]i128{ std.math.minInt(i128), std.math.maxInt(i128) }, [2][]const u8{ ">=", "<=" }) |v, absent, cmp| {
            if (v == absent) continue;
            const text = if (kind == .length) try p.length(v) else try p.area(v);
            try parts.append(p.arena, try std.fmt.allocPrint(p.arena, "{s} {s}", .{ cmp, text }));
        }
        if (parts.items.len == 0) return p.unprintable("layer {s}: a range open on both sides", .{layer});
        return std.mem.join(p.arena, ", ", parts.items);
    }

    /// `with_width` bounds, stored as twice their signed square; a strict
    /// bound moved the stored value one past the bound's.
    fn widthBounds(p: *const Printer, layer: []const u8, lo: i128, hi: i128) PrintError![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        if (lo != std.math.minInt(i128)) try parts.append(p.arena, if (halfRoot(lo)) |root|
            try std.fmt.allocPrint(p.arena, ">= {s}", .{try p.length(root)})
        else
            try std.fmt.allocPrint(p.arena, "> {s}", .{try p.length(halfRoot(lo - 1) orelse return p.unprintable("layer {s}: a width bound", .{layer}))}));
        if (hi != std.math.maxInt(i128)) try parts.append(p.arena, if (halfRoot(hi)) |root|
            try std.fmt.allocPrint(p.arena, "<= {s}", .{try p.length(root)})
        else
            try std.fmt.allocPrint(p.arena, "< {s}", .{try p.length(halfRoot(hi + 1) orelse return p.unprintable("layer {s}: a width bound", .{layer}))}));
        if (parts.items.len == 0) return p.unprintable("layer {s}: a range open on both sides", .{layer});
        return std.mem.join(p.arena, ", ", parts.items);
    }
};

/// Whether a layer name is one the parser made for a nested or inline
/// expression, which no deck text can name.
pub fn hidden(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "#@") != null;
}

/// Exactly `numerator / denominator` as a decimal, or null when it does
/// not terminate within 30 places.
pub fn decimal(arena: Allocator, numerator: i128, denominator: i128) Allocator.Error!?[]const u8 {
    if (denominator <= 0) return null;
    var whole: u128 = @abs(numerator);
    const den: u128 = @intCast(denominator);
    var places: usize = 0;
    while (whole % den != 0) : (places += 1) {
        if (places == 30) return null;
        const m = @mulWithOverflow(whole, 10);
        if (m[1] != 0) return null;
        whole = m[0];
    }
    const sign = if (numerator < 0) "-" else "";
    const digits = try std.fmt.allocPrint(arena, "{d}", .{whole / den});
    if (places == 0) return try std.fmt.allocPrint(arena, "{s}{s}", .{ sign, digits });
    const padded = try arena.alloc(u8, @max(digits.len, places + 1));
    @memset(padded, '0');
    @memcpy(padded[padded.len - digits.len ..], digits);
    return try std.fmt.allocPrint(arena, "{s}{s}.{s}", .{ sign, padded[0 .. padded.len - places], padded[padded.len - places ..] });
}

/// `m` such that `m * |m|` is `squared`: a `with_width` bound is twice that.
pub fn signedRoot(squared: i128) ?i64 {
    const magnitude: u128 = @abs(squared);
    const root = std.math.sqrt(magnitude);
    if (@as(u128, root) * root != magnitude) return null;
    const r = std.math.cast(i64, root) orelse return null;
    return if (squared < 0) -r else r;
}

// ---- private ----

fn halfRoot(doubled: i128) ?i64 {
    if (@rem(doubled, 2) != 0) return null;
    return signedRoot(@divTrunc(doubled, 2));
}

test "decimals and roots are exact" {
    // Oracle: hand-derived decimals and roots.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("140", (try decimal(a, 140_000, 1000)).?);
    try std.testing.expectEqualStrings("0.5", (try decimal(a, 1000, 2000)).?);
    try std.testing.expectEqualStrings("-0.3", (try decimal(a, -3000, 10_000)).?);
    try std.testing.expectEqualStrings("0.007", (try decimal(a, 7, 1000)).?);
    try std.testing.expectEqual(null, try decimal(a, 1000, 3000));
    try std.testing.expectEqual(70, signedRoot(4900).?);
    try std.testing.expectEqual(-70, signedRoot(-4900).?);
    try std.testing.expectEqual(null, signedRoot(4901));
    try std.testing.expectEqual(0, signedRoot(0).?);
    try std.testing.expectEqual(1, signedRoot(1).?);
}
