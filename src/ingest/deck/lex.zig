//! Deck text → tokens. A newline is a token except inside `(` and `[`, one
//! per run of blank lines; every character the lexer cannot read is a
//! diagnostic, and lexing goes on. The language: docs/deck.md, Basics.
//! Ported from crates/ingest/src/deck/lex.rs.
//!
//! Contents:
//! - `pub const Tok`, `pub const Token`
//! - `pub fn lex(arena: Allocator, source: []const u8, errors: *std.ArrayList(Diagnostic)) Allocator.Error![]Token`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const Tok = enum(u8) {
    ident,
    /// The word after `rule` or `waive`, `{name}` interpolation left in.
    rule_id,
    /// A number and its unit; the unit starts at `Token.unit_at`.
    num,
    str,
    /// One of `( ) [ ] { } , ; : = - . > < >= <= ==`.
    punct,
    newline,
    eof,
};

/// One token: its kind and byte span; `unit_at` is meaningful on `.num` only.
pub const Token = struct { tok: Tok, start: u32, end: u32, unit_at: u32 = 0 };

/// Tokenises `source`, appending a diagnostic per character it cannot read.
/// The last two tokens are always a newline and `eof`. Asserts the source is
/// under 4 GiB.
pub fn lex(arena: Allocator, source: []const u8, errors: *std.ArrayList(Diagnostic)) Allocator.Error![]Token {
    std.debug.assert(source.len < std.math.maxInt(u32));
    var out: std.ArrayList(Token) = .empty;
    var depth: u32 = 0;
    var at: usize = 0;
    while (at < source.len) {
        const c = source[at];
        const start = at;
        switch (c) {
            '#' => while (at < source.len and source[at] != '\n') {
                at += 1;
            },
            '\n' => {
                at += 1;
                // One newline token per run: blank lines end nothing new.
                if (depth == 0 and out.items.len > 0 and out.items[out.items.len - 1].tok != .newline) try push(arena, &out, .newline, start, at);
            },
            ' ', '\t', '\r' => at += 1,
            '"' => {
                at += 1;
                while (at < source.len and source[at] != '"' and source[at] != '\n') at += if (source[at] == '\\') 2 else 1;
                if (at < source.len and source[at] == '"') {
                    at += 1;
                    try push(arena, &out, .str, start, at);
                } else {
                    at = @min(at, source.len);
                    try errors.append(arena, .{ .message = "unterminated string", .start = @intCast(start), .end = @intCast(at) });
                }
            },
            '0'...'9' => {
                at = numberEnd(source, at);
                const unit_at = at;
                // A unit is a word, `%`, or a per-unit such as `/K`.
                if (at < source.len and (std.ascii.isAlphabetic(source[at]) or source[at] == '%' or source[at] == '/')) {
                    at += 1;
                    while (at < source.len and (std.ascii.isAlphanumeric(source[at]) or source[at] == '/')) at += 1;
                }
                try out.append(arena, .{ .tok = .num, .start = @intCast(start), .end = @intCast(at), .unit_at = @intCast(unit_at) });
            },
            'a'...'z', 'A'...'Z', '_' => {
                while (at < source.len and isIdent(source[at])) at += 1;
                try push(arena, &out, .ident, start, at);
                const word = source[start..at];
                if (std.mem.eql(u8, word, "rule") or std.mem.eql(u8, word, "waive")) {
                    // The id: everything up to the next blank.
                    while (at < source.len and (source[at] == ' ' or source[at] == '\t')) at += 1;
                    const id = at;
                    while (at < source.len and (isIdent(source[at]) or source[at] == '{' or source[at] == '}')) at += 1;
                    if (at > id) try push(arena, &out, .rule_id, id, at);
                }
            },
            '>', '<', '=', '(', ')', '[', ']', '{', '}', ',', ';', ':', '-', '.' => {
                if ((c == '>' or c == '<' or c == '=') and at + 1 < source.len and source[at + 1] == '=') {
                    at += 2;
                } else {
                    switch (c) {
                        '(', '[' => depth += 1,
                        ')', ']' => depth -|= 1,
                        else => {}, // else: only brackets change the depth
                    }
                    at += 1;
                }
                try push(arena, &out, .punct, start, at);
            },
            else => {
                at += std.unicode.utf8ByteSequenceLength(c) catch 1;
                at = @min(at, source.len);
                try errors.append(arena, .{ .message = "unexpected character", .start = @intCast(start), .end = @intCast(at) });
            },
        }
    }
    try push(arena, &out, .newline, source.len, source.len);
    try push(arena, &out, .eof, source.len, source.len);
    return out.items;
}

// ---- private ----

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn push(arena: Allocator, out: *std.ArrayList(Token), tok: Tok, start: usize, end: usize) Allocator.Error!void {
    try out.append(arena, .{ .tok = tok, .start = @intCast(start), .end = @intCast(end) });
}

/// Digits, an optional fraction, and an exponent only when digits follow
/// the `e` (so `2eV` is two electron-volts).
fn numberEnd(s: []const u8, start: usize) usize {
    var at = digits(s, start);
    if (at + 1 < s.len and s[at] == '.' and std.ascii.isDigit(s[at + 1])) at = digits(s, at + 1);
    if (at < s.len and (s[at] == 'e' or s[at] == 'E')) {
        const sign: usize = @intFromBool(at + 1 < s.len and (s[at + 1] == '+' or s[at + 1] == '-'));
        if (at + 1 + sign < s.len and std.ascii.isDigit(s[at + 1 + sign])) at = digits(s, at + 1 + sign);
    }
    return at;
}

fn digits(s: []const u8, start: usize) usize {
    var at = start;
    while (at < s.len and std.ascii.isDigit(s[at])) at += 1;
    return at;
}

test "a number keeps its unit and an exponent needs digits" {
    // Oracle: docs/deck.md, Basics, by hand: `2eV` is two electron-volts,
    // `1e-3um` the number `1e-3` in `um`; a blank-line run is one newline
    // token, and none is made inside `(`.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(Diagnostic) = .empty;
    const src = "2eV 1e-3um\n\n(a\nb)";
    const toks = try lex(arena.allocator(), src, &errors);
    try std.testing.expectEqual(0, errors.items.len);
    try std.testing.expectEqualStrings("2", src[toks[0].start..toks[0].unit_at]);
    try std.testing.expectEqualStrings("eV", src[toks[0].unit_at..toks[0].end]);
    try std.testing.expectEqualStrings("1e-3", src[toks[1].start..toks[1].unit_at]);
    try std.testing.expectEqual(Tok.newline, toks[2].tok);
    try std.testing.expectEqual(Tok.punct, toks[3].tok);
    try std.testing.expectEqual(Tok.ident, toks[5].tok); // no newline inside `(`
}
