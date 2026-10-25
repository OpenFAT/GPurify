//! The two LEF58 properties the LEF reader keeps, read out of their quoted
//! values: a library's `LEF58_CELLEDGESPACINGTABLE` and a macro's
//! `LEF58_EDGETYPE` (the forms OpenROAD's parser reads). In: the property's
//! value token. Out: rows appended to the library or the macro. Ported from
//! crates/ingest/src/lefdef/lef.rs (`library_property`, `edge_types`).
//!
//! Contents:
//! - `pub fn libraryProperty(arena: Allocator, lx: *const Lexer, dbu: i64, lef: *Lef, name: []const u8, value: []const u8) Error!void`
//! - `pub fn edgeTypes(arena: Allocator, lx: *const Lexer, dbu: i64, value: []const u8, out: *std.ArrayList(EdgeType)) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lefdef_lex.zig");
const Lexer = lex.Lexer;
const Error = lex.Error;
const lef_file = @import("lef.zig");
const Lef = lef_file.Lef;
const EdgeType = lef_file.EdgeType;
const EdgeSide = lef_file.EdgeSide;
const EdgeSpan = lef_file.EdgeSpan;

/// Reads `LEF58_CELLEDGESPACINGTABLE`, `CELLEDGESPACINGTABLE [NODEFAULT]
/// { EDGETYPE type type [options] spacing }… ;`; any other property is
/// skipped.
pub fn libraryProperty(arena: Allocator, lx: *const Lexer, dbu: i64, lef: *Lef, name: []const u8, value: []const u8) Error!void {
    if (!std.mem.eql(u8, name, "LEF58_CELLEDGESPACINGTABLE")) return;
    var words = std.mem.tokenizeAny(u8, unquote(value), " \t\r\n\x0b\x0c;");
    if (!eql(words.next(), "CELLEDGESPACINGTABLE")) return lx.fail("LEF58_CELLEDGESPACINGTABLE does not start CELLEDGESPACINGTABLE", .{});
    if (eql(words.peek(), "NODEFAULT")) _ = words.next();
    while (words.next()) |word| {
        if (!std.mem.eql(u8, word, "EDGETYPE")) return lx.fail("LEF58_CELLEDGESPACINGTABLE: {s} where EDGETYPE belongs", .{word});
        const first = words.next() orelse return early(lx);
        const second = words.next() orelse return early(lx);
        var undefined_options: std.ArrayList([]const u8) = .empty;
        var entry: lef_file.CellEdgeSpacing = .{ .first = first, .second = second };
        while (true) {
            const option = words.next() orelse return early(lx);
            if (std.mem.eql(u8, option, "EXCEPTABUTTED")) {
                entry.except_abutted = true;
            } else if (for ([_][]const u8{ "EXCEPTNONFILLERINBETWEEN", "OPTIONAL", "SOFT", "EXACT" }) |u| {
                if (std.mem.eql(u8, option, u)) break true;
            } else false) {
                try undefined_options.append(arena, option);
            } else {
                entry.spacing = lex.exactUnits(option, dbu) orelse return lx.fail("LEF58_CELLEDGESPACINGTABLE: spacing {s} is not a whole number of database units", .{option});
                break;
            }
        }
        entry.undefined = undefined_options.items;
        try lef.cell_edge_spacing.append(arena, entry);
    }
}

/// Reads a macro's `LEF58_EDGETYPE` value: `EDGETYPE {RIGHT | LEFT | TOP |
/// BOTTOM} type [CELLROW n | HALFROW n | RANGE b e] ;`, one or more.
pub fn edgeTypes(arena: Allocator, lx: *const Lexer, dbu: i64, value: []const u8, out: *std.ArrayList(EdgeType)) Error!void {
    var statements = std.mem.splitScalar(u8, unquote(value), ';');
    while (statements.next()) |statement| {
        var words: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, statement, " \t\r\n\x0b\x0c");
        while (it.next()) |w| : (n += 1) {
            if (n == words.len) return bad(lx, statement);
            words[n] = w;
        }
        if (n == 0) continue;
        if (n < 3 or !std.mem.eql(u8, words[0], "EDGETYPE")) return bad(lx, statement);
        const side: EdgeSide = if (eql(words[1], "LEFT")) .left else if (eql(words[1], "RIGHT")) .right else if (eql(words[1], "TOP")) .top else if (eql(words[1], "BOTTOM")) .bottom else return bad(lx, statement);
        const rest = words[3..n];
        const span: EdgeSpan = if (rest.len == 0)
            .whole
        else if (rest.len == 2 and std.mem.eql(u8, rest[0], "CELLROW"))
            .{ .cell_row = row(rest[1]) orelse return bad(lx, statement) }
        else if (rest.len == 2 and std.mem.eql(u8, rest[0], "HALFROW"))
            .{ .half_row = row(rest[1]) orelse return bad(lx, statement) }
        else if (rest.len == 3 and std.mem.eql(u8, rest[0], "RANGE"))
            .{ .range = .{ lex.exactUnits(rest[1], dbu) orelse return bad(lx, statement), lex.exactUnits(rest[2], dbu) orelse return bad(lx, statement) } }
        else
            return bad(lx, statement);
        try out.append(arena, .{ .side = side, .name = words[2], .span = span });
    }
}

// ---- private ----

/// The text of a quoted LEF string, quotes removed.
fn unquote(token: []const u8) []const u8 {
    return std.mem.trim(u8, token, "\"");
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return if (a) |text| std.mem.eql(u8, text, b) else false;
}

fn early(lx: *const Lexer) Error {
    return lx.fail("LEF58_CELLEDGESPACINGTABLE: an EDGETYPE entry ends early", .{});
}

fn bad(lx: *const Lexer, statement: []const u8) Error {
    return lx.fail("LEF58_EDGETYPE: cannot read `{s}`", .{std.mem.trim(u8, statement, " \t\r\n")});
}

/// A row number: a positive `u32`, as Rust's `str::parse` reads it.
fn row(text: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, text, '_') != null) return null;
    const n = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (n > 0) n else null;
}
