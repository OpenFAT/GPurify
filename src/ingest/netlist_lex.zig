//! Netlist text → tokens grouped into cards: comments dropped, `+` (SPICE)
//! and trailing `\` (Spectre) continuations folded into the card they
//! continue, Spectre's parentheses read as separators. Also the token-level
//! readers every card shares: SPICE numbers with scale suffixes, the split
//! of a card into positional and `k=v` tokens, and terminal counts per
//! device family. Ported from crates/ingest/src/netlist.rs (`lex`,
//! `strip_comment`, `spice_number`, `split_params`, `split_terminals`,
//! `spectre_primitive`).
//!
//! Contents:
//! - `pub const Dialect`, `pub const Tok`, `pub const Cards`
//! - `pub fn lex(gpa: Allocator, source: []const u8, dialect: Dialect) Allocator.Error!Cards`, `Cards.deinit(c: *Cards, gpa: Allocator) void`,
//!   `Cards.card(c: *const Cards, k: usize) []const Tok`
//! - `pub fn spiceNumber(text: []const u8) ?f64`
//! - `pub const Split`, `pub fn splitParams(card: []const Tok, diag: *Diagnostic) Error!Split`
//! - `pub fn splitTerminals(kind: DeviceKind, positional: []const Tok, head: Tok, diag: *Diagnostic) Error!Split`
//! - `pub fn spectrePrimitive(master: []const u8) ?DeviceKind`

const std = @import("std");
const Allocator = std.mem.Allocator;
const DeviceKind = @import("deck/tables.zig").DeviceKind;
const netlist = @import("netlist.zig");
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;

/// Which surface syntax a card is written in.
pub const Dialect = enum { spice, spectre };

/// One token and its 1-based line.
pub const Tok = struct { text: []const u8, line: u32 };

/// Tokens and a CSR column of card starts.
pub const Cards = struct {
    toks: std.ArrayList(Tok) = .empty,
    start: std.ArrayList(u32) = .empty,

    pub fn deinit(c: *Cards, gpa: Allocator) void {
        c.toks.deinit(gpa);
        c.start.deinit(gpa);
    }

    pub fn card(c: *const Cards, k: usize) []const Tok {
        return c.toks.items[c.start.items[k]..c.start.items[k + 1]];
    }
};

/// A card's tokens split in two: positional then `k=v` (`splitParams`), or
/// terminals then the model (`splitTerminals`, `rest` one token).
pub const Split = struct { head: []const Tok, rest: []const Tok };

/// Lexes `source` into cards; tokens slice into `source`.
pub fn lex(gpa: Allocator, source: []const u8, dialect: Dialect) Allocator.Error!Cards {
    var c: Cards = .{};
    errdefer c.deinit(gpa);
    var fold_next = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line: u32 = 0;
    while (lines.next()) |raw_line| {
        line += 1;
        // `str::lines` drops a final empty line and a trailing `\r`.
        if (lines.index == null and raw_line.len == 0) break;
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        var rest = stripComment(raw, dialect);
        var continues = fold_next;
        fold_next = false;
        switch (dialect) {
            .spice => {
                const lead = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
                if (lead.len > 0 and lead[0] == '+') {
                    rest = lead[1..];
                    continues = true;
                }
            },
            .spectre => {
                const trimmed = std.mem.trimEnd(u8, rest, &std.ascii.whitespace);
                if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\\') {
                    fold_next = true;
                    rest = trimmed[0 .. trimmed.len - 1];
                } else rest = trimmed;
            },
        }
        var first = true;
        var at: usize = 0;
        while (at < rest.len) {
            while (at < rest.len and isSeparator(rest[at], dialect)) at += 1;
            const begin = at;
            while (at < rest.len and !isSeparator(rest[at], dialect)) at += 1;
            if (at == begin) continue;
            if (first and (!continues or c.start.items.len == 0)) try c.start.append(gpa, @intCast(c.toks.items.len));
            first = false;
            try c.toks.append(gpa, .{ .text = rest[begin..at], .line = line });
        }
    }
    try c.start.append(gpa, @intCast(c.toks.items.len));
    return c;
}

/// A SPICE numeric literal in SI base units, its scale suffix expanded;
/// letters after the suffix are ignored (`1uF` is 1e-6). An unrecognised
/// suffix is null, never a silent factor of one.
pub fn spiceNumber(text: []const u8) ?f64 {
    var at: usize = @intFromBool(text.len > 0 and (text[0] == '+' or text[0] == '-'));
    const digits = at;
    at = digitsEnd(text, at);
    if (at < text.len and text[at] == '.') at = digitsEnd(text, at + 1);
    if (at == digits) return null;
    // An `e` is an exponent only when a digit follows, with or without a sign.
    if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
        var exponent = at + 1;
        exponent += @intFromBool(exponent < text.len and (text[exponent] == '+' or text[exponent] == '-'));
        if (exponent < text.len and std.ascii.isDigit(text[exponent])) at = digitsEnd(text, exponent);
    }
    const suffix = text[at..];
    const head = suffix[0..@min(suffix.len, 3)];
    // `meg` and `mil` before `m`: a megohm read as a milliohm is out by 1e9.
    const scale: f64 = if (std.ascii.eqlIgnoreCase(head, "meg")) 1e6 else if (std.ascii.eqlIgnoreCase(head, "mil")) 25.4e-6 else if (suffix.len == 0) 1.0 else switch (std.ascii.toLower(suffix[0])) {
        't' => 1e12,
        'g' => 1e9,
        'x' => 1e6,
        'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        'a' => 1e-18,
        else => return null,
    };
    const value = (std.fmt.parseFloat(f64, text[0..at]) catch return null) * scale;
    return if (std.math.isFinite(value)) value else null;
}

/// A card's tail as positional tokens then `k=v` tokens; a positional
/// token after a parameter is refused, never read as a terminal.
pub fn splitParams(card: []const Tok, diag: *Diagnostic) Error!Split {
    const tail = card[1..];
    var at: usize = 0;
    while (at < tail.len and std.mem.indexOfScalar(u8, tail[at].text, '=') == null) at += 1;
    for (tail[at..]) |t| if (std.mem.indexOfScalar(u8, t.text, '=') == null) {
        diag.set(t.line, "{s}", .{t.text});
        return error.Unexpected;
    };
    return .{ .head = tail[0..at], .rest = tail[at..] };
}

/// A device card's positional tokens as its terminals and its model,
/// refusing a terminal count its family does not have.
pub fn splitTerminals(kind: DeviceKind, positional: []const Tok, head: Tok, diag: *Diagnostic) Error!Split {
    const want: u32 = switch (kind) {
        .mos => 4,
        .bjt => 3,
        .resistor, .capacitor, .diode, .inductor => 2,
        // Never a card's kind: a black box's arity is its subcircuit's.
        .cell => std.math.maxInt(u32),
    };
    const got: u32 = @intCast(positional.len -| 1);
    // A `Q` card's substrate terminal is optional; nothing else is.
    if (!(got == want or (kind == .bjt and got == 4))) {
        diag.set(head.line, "{s}", .{head.text});
        diag.got = got;
        diag.want = want;
        return error.TerminalCount;
    }
    return .{ .head = positional[0 .. positional.len - 1], .rest = positional[positional.len - 1 ..] };
}

/// The Spectre primitive masters this subset reads, case-sensitive.
pub fn spectrePrimitive(master: []const u8) ?DeviceKind {
    const table = [_]struct { DeviceKind, []const []const u8 }{
        .{ .resistor, &.{ "resistor", "res" } },
        .{ .capacitor, &.{ "capacitor", "cap" } },
        .{ .diode, &.{"diode"} },
        .{ .inductor, &.{"inductor"} },
        .{ .bjt, &.{ "bjt", "npn", "pnp", "vbic", "hicum", "mextram" } },
        .{ .mos, &.{ "mos", "nmos", "pmos", "mos0", "mos1", "mos2", "mos3", "mos9", "bsim1", "bsim2", "bsim3", "bsim3v3", "bsim4", "bsim4v5", "bsimsoi", "bsimcmg", "hisim", "hisim2", "hisimhv", "psp", "ekv" } },
    };
    for (table) |row| for (row[1]) |name| if (std.mem.eql(u8, name, master)) return row[0];
    return null;
}

// ---- private ----

fn digitsEnd(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
    return at;
}

/// A card's comment dropped; the text left to lex, maybe empty.
fn stripComment(raw: []const u8, dialect: Dialect) []const u8 {
    const lead = std.mem.trimStart(u8, raw, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, lead, "*") or (dialect == .spectre and std.mem.startsWith(u8, lead, "//"))) return "";
    const cut = switch (dialect) {
        .spice => std.mem.indexOfAny(u8, raw, "$;"),
        .spectre => std.mem.indexOf(u8, raw, "//"),
    };
    return if (cut) |at| raw[0..at] else raw;
}

/// Spectre's parentheses carry no information past the lexer.
fn isSeparator(c: u8, dialect: Dialect) bool {
    return std.ascii.isWhitespace(c) or (dialect == .spectre and (c == '(' or c == ')'));
}

test "a SPICE number scales by its suffix, longest match first" {
    // Oracle: the ngspice manual's scale factors: meg 1e6, mil 25.4e-6, m
    // 1e-3; letters after a suffix are ignored; an unknown suffix and a
    // bare `e` are refused.
    try std.testing.expectEqual(1e6 * 2, spiceNumber("2meg").?);
    try std.testing.expectEqual(2e-3, spiceNumber("2m").?);
    try std.testing.expectEqual(1e-6, spiceNumber("1uF").?);
    try std.testing.expectEqual(25.4e-6, spiceNumber("1mil").?);
    try std.testing.expectEqual(1.5e3, spiceNumber("1.5e3").?);
    try std.testing.expectEqual(null, spiceNumber("1z"));
    try std.testing.expectEqual(null, spiceNumber("abc"));
}
