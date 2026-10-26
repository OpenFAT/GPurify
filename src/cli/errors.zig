//! An engine error → the lines the CLI prints on stderr: `error: ` and what
//! failed, then the fields of its `Diagnostic` that locate it. Ported from
//! src/cli/format.rs (`write_error`): a Zig error has no cause chain, so
//! the diagnostic's fields stand in for Rust's `caused by:` lines.
//!
//! Contents:
//! - `pub fn writeLoad(w: *std.Io.Writer, err: anyerror, d: *const gpurify.LoadDiagnostic) std.Io.Writer.Error!void`
//! - `pub fn writeRun(w: *std.Io.Writer, err: anyerror, d: *const gpurify.RunDiagnostic) std.Io.Writer.Error!void`
//! - `pub fn writeExtract(w: *std.Io.Writer, err: anyerror, d: *const gpurify.ExtractDiagnostic) std.Io.Writer.Error!void`

const std = @import("std");
const Writer = std.Io.Writer;
const gpurify = @import("gpurify");

/// A load failure: the input at fault, then its reader's detail.
pub fn writeLoad(w: *Writer, err: anyerror, d: *const gpurify.LoadDiagnostic) Writer.Error!void {
    if (err == error.OutOfMemory) return w.writeAll("error: out of memory\n");
    try w.print("error: {t} {s}: {t}\n", .{ d.stage, d.path, err });
    if (err == error.Unreadable) return;
    switch (d.stage) {
        .layout => try w.print("  gds: {any}\n", .{d.gds}),
        .deck => {
            for (d.deck.deck.diagnostics) |m| try w.print("  line {d}:{d}: {s}\n", .{ m.line, m.col, m.message });
            if (d.deck.deck.malformed.len > 0) try w.print("  {s}\n", .{d.deck.deck.malformed});
            if (d.deck.deck.diagnostics.len == 0 and d.deck.deck.malformed.len == 0) try w.print("  rule: {any}\n", .{d.deck.rule});
        },
        .reference => {
            try w.print("  line {d}: {s}\n", .{ d.netlist.line, d.netlist.token() });
            if (d.netlist.has().len > 0) try w.print("  the deck has: {s}\n", .{d.netlist.has()});
        },
        .intent => try w.print("  {s}\n", .{d.intent.text()}),
        .lefdef => try w.print("  {s} line {d}: {s}\n", .{ d.lefdef.file, d.lefdef.line, d.lefdef.message() }),
        .labels => try w.print("  label: {any}\n", .{d.label}),
    }
}

/// A run failure: loading, extracting, or the checks themselves.
pub fn writeRun(w: *Writer, err: anyerror, d: *const gpurify.RunDiagnostic) Writer.Error!void {
    if (err == error.OutOfMemory) return w.writeAll("error: out of memory\n");
    if (inSet(gpurify.LoadError, err)) return writeLoad(w, err, &d.load);
    if (inSet(gpurify.ExtractError, err)) return writeExtract(w, err, &d.extract);
    try w.print("error: checks: {t}\n", .{err});
}

/// An extraction failure and the channel or geometry at fault.
pub fn writeExtract(w: *Writer, err: anyerror, d: *const gpurify.ExtractDiagnostic) Writer.Error!void {
    try w.print("error: extract: {t}\n", .{err});
    if (d.* != .none) try w.print("  {any}\n", .{d.*});
}

// ---- private ----

fn inSet(comptime E: type, err: anyerror) bool {
    inline for (@typeInfo(E).error_set.error_names.?) |name| if (err == @field(anyerror, name)) return true;
    return false;
}

test "a load error names the input and the reader's detail" {
    // Oracle: construct-from-answer: a deck diagnostic at line 3, column 5
    // reads back as `line 3:5: <message>` under the deck's path.
    var buf: Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const Line = std.meta.Elem(@FieldType(@FieldType(@FieldType(gpurify.LoadDiagnostic, "deck"), "deck"), "diagnostics"));
    const lines = [_]Line{.{ .message = "unknown layer `m9`", .line = 3, .col = 5, .start = 0, .end = 0 }};
    var d: gpurify.LoadDiagnostic = .{ .stage = .deck, .path = "my.deck" };
    d.deck.deck.diagnostics = &lines;
    try writeRun(&buf.writer, error.Invalid, &.{ .load = d });
    try std.testing.expectEqualStrings("error: deck my.deck: Invalid\n  line 3:5: unknown layer `m9`\n", buf.written());
}
