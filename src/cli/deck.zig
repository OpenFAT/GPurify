//! `gpurify deck <deck file | shipped deck name> [--format json]`: one deck
//! compiled with no layout and written as the deck dump
//! (gpurify/export/deck.zig) on stdout. In: the arguments after `deck`.
//! Out: the dump and exit 0, or on stderr the refusal `drc` gives for the
//! same deck and exit 1, stdout empty.
//!
//! The deck compiles on a 1 nm grid, as against a layout whose database
//! unit is 1 nm, so every length in the dump is a whole nm; a deck whose
//! own grid is finer than 1 nm is refused, as that layout's run refuses it.
//!
//! Contents:
//! - `pub fn run(arena: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) std.Io.Writer.Error!u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const gpurify = @import("gpurify");
const errors = @import("errors.zig");

const usage_line = "deck <deck file | shipped deck name> [--format json]";

/// Compiles the deck `argv` names and writes its dump to `out`, or the
/// refusal to `err`; returns the exit code. Nothing reaches `out` unless
/// the whole dump was written.
pub fn run(arena: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    var deck: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i == argv.len) return fail(err, "--format wants a value", .{});
            if (!std.mem.eql(u8, argv[i], "json")) return fail(err, "unknown --format {s}; deck writes json", .{argv[i]});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fail(err, "unknown option {s}", .{arg});
        } else if (deck != null or arg.len == 0) {
            return fail(err, "deck takes one deck: " ++ usage_line, .{});
        } else deck = arg;
    }
    const name = deck orelse return fail(err, "deck takes one deck: " ++ usage_line, .{});
    var strings: @FieldType(gpurify.Loaded, "strings") = .empty;
    var diag: gpurify.LoadDiagnostic = .{};
    const cd = gpurify.loadDeck(arena, io, dir, name, .{ .dbu_per_um = 1000 }, &gpurify.pdks.decks, &strings, &diag) catch |e| {
        try errors.writeLoad(err, e, &diag);
        return 1;
    };
    var text: Writer.Allocating = .init(arena);
    gpurify.@"export".deck.writeDeck(&text.writer, arena, &cd, &strings, name) catch |e| switch (e) {
        error.Unrepresentable => return fail(err, "deck {s}: a value the dump cannot represent (non-finite, or a parameter of no stated unit)", .{name}),
        error.OutOfMemory => return fail(err, "out of memory", .{}),
        error.WriteFailed => return fail(err, "out of memory", .{}),
    };
    try out.writeAll(text.written());
    return 0;
}

// ---- private ----

fn fail(err: *Writer, comptime fmt: []const u8, a: anytype) Writer.Error!u8 {
    try err.print("error: " ++ fmt ++ "\n", a);
    return 1;
}
