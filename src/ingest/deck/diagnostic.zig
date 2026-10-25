//! Why a deck was refused, as data: located parse diagnostics or the first
//! contradiction between statements, and their `file:line:col` rendering.
//! In: byte spans into the deck text. Out: `Diagnostic` rows, rendered once
//! at the end. Ported from crates/ingest/src/deck/{mod.rs (`DeckError`),
//! parse.rs (`Diagnostic`, `locate`, `render`)}.
//!
//! Contents:
//! - `pub const Error`, `pub const Diag`, `pub const Diagnostic`
//! - `pub fn locate(d: *Diagnostic, source: []const u8) void`
//! - `pub fn render(w: *std.Io.Writer, file: []const u8, diagnostics: []const Diagnostic) std.Io.Writer.Error!void`

const std = @import("std");

/// Why a deck was rejected; `Diag` carries the detail.
pub const Error = error{
    /// The text did not parse: `Diag.diagnostics` holds every error found,
    /// at most 50, in source order of detection.
    Invalid,
    /// Statements that parse alone but contradict each other:
    /// `Diag.malformed` says which.
    Malformed,
    OutOfMemory,
};

/// The detail of a refusal, allocated in the caller's arena.
pub const Diag = struct {
    diagnostics: []const Diagnostic = &.{},
    malformed: []const u8 = "",
};

/// One error, located in the deck text.
pub const Diagnostic = struct {
    /// What is wrong, prefixed with the rule id when inside a rule.
    message: []const u8,
    /// 1-based line of `start`.
    line: u32 = 0,
    /// 1-based column of `start`, counted in code points, not bytes.
    col: u32 = 0,
    /// The source line, for the caret display.
    text: []const u8 = "",
    /// Byte offset of the offending text's start.
    start: u32,
    /// Byte offset just past its end.
    end: u32,
};

/// Fills line, column and line text from the span.
pub fn locate(d: *Diagnostic, source: []const u8) void {
    const start: usize = d.start;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |at| at + 1 else 0;
    const line_end = if (std.mem.indexOfScalarPos(u8, source, start, '\n')) |at| at else source.len;
    d.line = @intCast(std.mem.count(u8, source[0..line_start], "\n") + 1);
    d.col = @intCast(codePoints(source[line_start..start]) + 1);
    d.text = std.mem.trimEnd(u8, source[line_start..line_end], "\r");
}

/// `file:line:col: message`, the line, and a caret under the span, per
/// diagnostic, without a trailing newline.
pub fn render(w: *std.Io.Writer, file: []const u8, diagnostics: []const Diagnostic) std.Io.Writer.Error!void {
    for (diagnostics, 0..) |d, i| {
        const room = @max(d.text.len -| (d.col - 1), 1);
        const width = std.math.clamp(d.end -| d.start, 1, room);
        if (i > 0) try w.writeByte('\n');
        try w.print("{s}:{d}:{d}: {s}\n{s}\n", .{ file, d.line, d.col, d.message, d.text });
        try w.splatByteAll(' ', d.col - 1);
        try w.splatByteAll('^', width);
    }
}

// ---- private ----

fn codePoints(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| n += @intFromBool(b & 0xC0 != 0x80);
    return n;
}
