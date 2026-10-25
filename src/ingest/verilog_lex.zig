//! Structural Verilog text → tokens and their lines: comments and
//! attributes dropped, escaped identifiers read without their `\`, a
//! compiler directive refused. Ported from crates/ingest/src/netlist/
//! verilog.rs (`tokens`, `skip_block`).
//!
//! Contents:
//! - `pub const Tok`, `pub fn tokens(arena: Allocator, source: []const u8, diag: *Diagnostic) Error![]const Tok`

const std = @import("std");
const Allocator = std.mem.Allocator;
const netlist = @import("netlist.zig");
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;

/// One token: an identifier, a plain decimal number, any other literal
/// (never accepted), or one punctuation character; and its line.
pub const Tok = struct { kind: enum { ident, number, constant, punct }, text: []const u8, number: u32 = 0, line: u32 };

/// Splits Verilog text into tokens.
pub fn tokens(arena: Allocator, source: []const u8, diag: *Diagnostic) Error![]const Tok {
    var out: std.ArrayList(Tok) = .empty;
    var at: usize = 0;
    var line: u32 = 1;
    while (at < source.len) {
        const c = source[at];
        const next: u8 = if (at + 1 < source.len) source[at + 1] else 0;
        if (c == '\n') {
            line += 1;
            at += 1;
        } else if (std.ascii.isWhitespace(c)) {
            at += 1;
        } else if (c == '/' and next == '/') {
            while (at < source.len and source[at] != '\n') at += 1;
        } else if (c == '/' and next == '*') {
            try skipBlock(source, &at, &line, '/', "an unclosed /* comment", diag);
        } else if (c == '(' and next == '*' and !(at + 2 < source.len and source[at + 2] == ')')) {
            // An attribute, `(* keep *)`, says nothing about connectivity.
            try skipBlock(source, &at, &line, ')', "an unclosed (* attribute", diag);
        } else if (c == '`') {
            diag.set(line, "the compiler directive {s}", .{source[at..wordEnd(source, at)]});
            return error.Unsupported;
        } else if (c == '\\') {
            const end = wordEnd(source, at);
            try out.append(arena, .{ .kind = .ident, .text = source[at + 1 .. end], .line = line });
            at = end;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = at;
            while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_' or source[end] == '$')) end += 1;
            try out.append(arena, .{ .kind = .ident, .text = source[at..end], .line = line });
            at = end;
        } else if (std.ascii.isDigit(c) or c == '\'') {
            var end = at;
            while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_' or source[end] == '\'' or source[end] == '.')) end += 1;
            const text = source[at..end];
            if (std.fmt.parseInt(u32, text, 10)) |n| {
                try out.append(arena, .{ .kind = .number, .text = text, .number = n, .line = line });
            } else |_| try out.append(arena, .{ .kind = .constant, .text = text, .line = line });
            at = end;
        } else if (std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c)) {
            // Punctuation outside the subset is a token too, so the construct
            // it belongs to is named when refused.
            try out.append(arena, .{ .kind = .punct, .text = source[at .. at + 1], .line = line });
            at += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            diag.set(line, "{s}", .{source[at..@min(source.len, at + len)]});
            return error.Unexpected;
        }
    }
    return out.items;
}

// ---- private ----

fn wordEnd(source: []const u8, at: usize) usize {
    var end = at;
    while (end < source.len and !std.ascii.isWhitespace(source[end])) end += 1;
    return end;
}

/// Skips the `/* */` or `(* *)` opening at `at`, through its `*` and
/// `close`, counting the lines it spans.
fn skipBlock(source: []const u8, at: *usize, line: *u32, close: u8, what: []const u8, diag: *Diagnostic) Error!void {
    const start = line.*;
    at.* += 2;
    while (true) {
        if (at.* >= source.len) {
            diag.set(start, "{s}", .{what});
            return error.Unexpected;
        }
        if (source[at.*] == '*' and at.* + 1 < source.len and source[at.* + 1] == close) {
            at.* += 2;
            return;
        }
        line.* += @intFromBool(source[at.*] == '\n');
        at.* += 1;
    }
}
