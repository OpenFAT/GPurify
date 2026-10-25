//! The token stream LEF and DEF share: words split at white space, `(`, `)`
//! and `;` standing alone, `"…"` one token, `#` to the end of the line a
//! comment, as both files are written (LEF/DEF 5.8 Language Reference). In:
//! file text. Out: a cursor over `{text, line}` tokens, and the exact
//! micrometre-to-database-unit conversion. Ported from
//! crates/ingest/src/lefdef/lex.rs.
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic`, `Diagnostic.message(d: *const Diagnostic) []const u8`,
//!   `Diagnostic.set(d: *Diagnostic, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void`
//! - `pub const Pt`, `pub const max_coord`, `pub const Tok`
//! - `pub const Lexer`, `Lexer.init(arena: Allocator, text: []const u8, file: []const u8, diag: *Diagnostic) Allocator.Error!Lexer`,
//!   `Lexer.line(lx: *const Lexer) u32`, `Lexer.fail(lx: *const Lexer, comptime fmt: []const u8, args: anytype) Error`,
//!   `Lexer.failAt(lx: *const Lexer, at: u32, comptime fmt: []const u8, args: anytype) Error`,
//!   `Lexer.peek(lx: *const Lexer) ?[]const u8`, `Lexer.next(lx: *Lexer) Error![]const u8`,
//!   `Lexer.eat(lx: *Lexer, word: []const u8) bool`, `Lexer.expect(lx: *Lexer, word: []const u8) Error!void`,
//!   `Lexer.skipStatement(lx: *Lexer) Error!void`, `Lexer.skipToEnd(lx: *Lexer, name: []const u8) Error!void`,
//!   `Lexer.int(lx: *Lexer) Error!i64`, `Lexer.microns(lx: *Lexer, dbu: i64) Error!i64`,
//!   `Lexer.point(lx: *Lexer, prev: ?Pt) Error!Pt`, `Lexer.coord(lx: *Lexer, prev: ?i64) Error!i64`
//! - `pub fn exactUnits(text: []const u8, dbu: i64) ?i64`

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Why a LEF or DEF could not be read, or its design not flattened or
/// written; `Diagnostic` says where and what.
pub const Error = error{ Invalid, OutOfMemory };

/// Where and why a LEF or DEF was refused: `{file} line {line}: {message}`.
pub const Diagnostic = struct {
    /// `"LEF"` or `"DEF"`, or `"design"` for a fault found flattening.
    file: []const u8 = "",
    /// The 1-based line of the token at fault; 0 when no line applies.
    line: u32 = 0,
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    pub fn set(d: *Diagnostic, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
        d.file = file;
        d.line = line;
        d.len = if (std.fmt.bufPrint(&d.buf, fmt, args)) |t| t.len else |_| d.buf.len;
    }
};

/// A point in database units.
pub const Pt = [2]i64;

/// The largest coordinate magnitude: a GDSII `XY` is a 32-bit integer.
pub const max_coord: i64 = std.math.maxInt(i32);

/// One token and the line it starts on.
pub const Tok = struct { text: []const u8, line: u32 };

/// A cursor over one file's tokens.
pub const Lexer = struct {
    toks: []const Tok,
    at: usize = 0,
    file: []const u8,
    diag: *Diagnostic,

    pub fn init(arena: Allocator, text: []const u8, file: []const u8, diag: *Diagnostic) Allocator.Error!Lexer {
        var toks: std.ArrayList(Tok) = .empty;
        var i: usize = 0;
        var at_line: u32 = 1;
        while (i < text.len) {
            const b = text[i];
            if (b == '\n') {
                at_line += 1;
                i += 1;
            } else if (std.ascii.isWhitespace(b)) {
                i += 1;
            } else if (b == '#') {
                while (i < text.len and text[i] != '\n') i += 1;
            } else if (b == '"') {
                const start = i;
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) at_line += @intFromBool(text[i] == '\n');
                i = @min(i + 1, text.len);
                try toks.append(arena, .{ .text = text[start..i], .line = at_line });
            } else if (b == '(' or b == ')' or b == ';') {
                try toks.append(arena, .{ .text = text[i .. i + 1], .line = at_line });
                i += 1;
            } else {
                const start = i;
                while (i < text.len and !std.ascii.isWhitespace(text[i]) and std.mem.indexOfScalar(u8, "();\"", text[i]) == null) i += 1;
                try toks.append(arena, .{ .text = text[start..i], .line = at_line });
            }
        }
        return .{ .toks = toks.items, .file = file, .diag = diag };
    }

    pub fn line(lx: *const Lexer) u32 {
        if (lx.at < lx.toks.len) return lx.toks[lx.at].line;
        return if (lx.toks.len > 0) lx.toks[lx.toks.len - 1].line else 0;
    }

    /// Refuses at the current token's line.
    pub fn fail(lx: *const Lexer, comptime fmt: []const u8, args: anytype) Error {
        return lx.failAt(lx.line(), fmt, args);
    }

    pub fn failAt(lx: *const Lexer, at: u32, comptime fmt: []const u8, args: anytype) Error {
        lx.diag.set(lx.file, at, fmt, args);
        return error.Invalid;
    }

    pub fn peek(lx: *const Lexer) ?[]const u8 {
        return if (lx.at < lx.toks.len) lx.toks[lx.at].text else null;
    }

    pub fn next(lx: *Lexer) Error![]const u8 {
        if (lx.at >= lx.toks.len) return lx.fail("the file ends inside a statement", .{});
        lx.at += 1;
        return lx.toks[lx.at - 1].text;
    }

    /// Consumes `word` if it is next.
    pub fn eat(lx: *Lexer, word: []const u8) bool {
        const here = if (lx.peek()) |p| std.mem.eql(u8, p, word) else false;
        lx.at += @intFromBool(here);
        return here;
    }

    pub fn expect(lx: *Lexer, word: []const u8) Error!void {
        const at = lx.line();
        const got = try lx.next();
        if (!std.mem.eql(u8, got, word)) return lx.failAt(at, "expected {s}, found {s}", .{ word, got });
    }

    /// Skips to just past the next `;`.
    pub fn skipStatement(lx: *Lexer) Error!void {
        while (!std.mem.eql(u8, try lx.next(), ";")) {}
    }

    /// Skips to just past `END name`.
    pub fn skipToEnd(lx: *Lexer, name: []const u8) Error!void {
        while (!(std.mem.eql(u8, try lx.next(), "END") and lx.eat(name))) {}
    }

    /// An integer, as DEF writes its database units.
    pub fn int(lx: *Lexer) Error!i64 {
        const at = lx.line();
        const text = try lx.next();
        // Rust's `str::parse` takes no `_` digit separators; Zig's would.
        const v = if (std.mem.indexOfScalar(u8, text, '_') == null) std.fmt.parseInt(i64, text, 10) catch null else null;
        if (v) |value| if (@abs(value) <= max_coord) return value;
        return lx.failAt(at, "expected an integer within ±2^31, found {s}", .{text});
    }

    /// A decimal in micrometres, converted exactly to `dbu` units per
    /// micrometre; a value between two units is refused.
    pub fn microns(lx: *Lexer, dbu: i64) Error!i64 {
        const at = lx.line();
        const text = try lx.next();
        return exactUnits(text, dbu) orelse lx.failAt(at, "{s} µm is not a whole number of database units at {d} per µm, or is past ±2^31 of them", .{ text, dbu });
    }

    /// `( x y )`, with `*` taking the previous point's coordinate.
    pub fn point(lx: *Lexer, prev: ?Pt) Error!Pt {
        try lx.expect("(");
        const x = try lx.coord(if (prev) |p| p[0] else null);
        const y = try lx.coord(if (prev) |p| p[1] else null);
        try lx.expect(")");
        return .{ x, y };
    }

    pub fn coord(lx: *Lexer, prev: ?i64) Error!i64 {
        if (lx.eat("*")) return prev orelse lx.fail("* with no previous point", .{});
        return lx.int();
    }
};

/// `text`, a decimal number of micrometres, in units of `1/dbu` µm, or null
/// when it is not a whole number of them, not a plain decimal, or past
/// `max_coord`.
pub fn exactUnits(text: []const u8, dbu: i64) ?i64 {
    const negative = text.len > 0 and text[0] == '-';
    const digits = if (negative or (text.len > 0 and text[0] == '+')) text[1..] else text;
    const dot = std.mem.indexOfScalar(u8, digits, '.');
    const whole = if (dot) |d| digits[0..d] else digits;
    const frac = if (dot) |d| digits[d + 1 ..] else "";
    if (whole.len + frac.len == 0 or whole.len + frac.len > 30) return null;
    var mantissa: i128 = 0;
    for ([_][]const u8{ whole, frac }) |part| for (part) |b| {
        if (!std.ascii.isDigit(b)) return null;
        mantissa = mantissa * 10 + (b - '0');
    };
    const scale = std.math.powi(i128, 10, @intCast(frac.len)) catch return null;
    const scaled = std.math.mul(i128, mantissa, dbu) catch return null;
    if (@rem(scaled, scale) != 0) return null;
    const value = std.math.cast(i64, @divTrunc(scaled, scale)) orelse return null;
    if (@abs(value) > max_coord) return null;
    return if (negative) -value else value;
}
