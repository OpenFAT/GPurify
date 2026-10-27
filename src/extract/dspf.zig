//! A DSPF file (Cadence DSPF 1.x: `*|NET` sections and SPICE element cards)
//! read into a `foreign.Read`. In: the file's text. Out: its nets and
//! network, in fF, Ω and pH. Ported from crates/extract/src/foreign.rs
//! (`read_dspf`, `spice_number`).
//!
//! Read: `*|DELIMITER`, `*|GROUND_NET`, each `*|NET` with its `*|P`, `*|I`
//! and `*|S` node declarations, and the `R`, `C` and `L` cards, with SPICE
//! scale suffixes and `+` continuations. A `K` card (mutual inductance) and
//! an instance (`X`) card are skipped, as `compare` reads neither; so is
//! every other `*` or `.` line, and every card after a `* instance section`
//! comment (the devices, whose `R`, `C` and `L` are no parasitics). The driver is a net's first `*|P` of
//! direction `I`, else its first `*|I` of direction `O`. A card belongs to
//! the net of its first node's declaration, else the section it stands in.
//! Names are unescaped once, after splitting, so a `\(` or `\)` is part of
//! the name; Rust split on every parenthesis first.
//!
//! Contents:
//! - `pub fn readInto(gpa: Allocator, text: []const u8, out: *Read, diag: *Diagnostic) Error!void`
//! - `pub fn spiceNumber(text: []const u8) ?f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const foreign = @import("foreign.zig");
const Read = foreign.Read;
const Error = foreign.Error;
const Diagnostic = foreign.Diagnostic;
const Collect = foreign.Collect;

const max_tokens = 8;
const separators = " \t\r()";

/// Reads `text` into `out` (cleared). Errors: what foreign.zig's `Error`
/// lists, with the line and token in `diag`.
pub fn readInto(gpa: Allocator, text: []const u8, out: *Read, diag: *Diagnostic) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var c: Collect = .init(arena);
    var ground: []const u8 = "0";
    var net: ?u32 = null;
    // `+` continuations joined onto the card before them.
    var cards: std.ArrayList([]const u8) = .empty;
    var card_line: std.ArrayList(u32) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 0;
    while (lines.next()) |raw| {
        number += 1;
        const trimmed = std.mem.trimStart(u8, raw, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '+' and cards.items.len > 0) {
            const last = &cards.items[cards.items.len - 1];
            last.* = try std.mem.concat(arena, u8, &.{ last.*, " ", trimmed[1..] });
        } else {
            try cards.append(arena, raw);
            try card_line.append(arena, number);
        }
    }
    var devices = false;
    for (cards.items, card_line.items) |card, line| {
        diag.* = .{ .line = line };
        const words = std.mem.trim(u8, card, " \t\r*");
        if (card.len > 0 and card[0] == '*' and std.ascii.eqlIgnoreCase(words, "instance section")) devices = true;
        if (devices and !std.mem.startsWith(u8, card, "*|")) continue;
        // Split on blanks and parentheses; a `\`-escaped byte stays in its
        // token, for `foreign.unescape` to undo once.
        var tokens_buf: [max_tokens][]const u8 = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < card.len) {
            if (std.mem.findScalar(u8, separators, card[i]) != null) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < card.len and std.mem.findScalar(u8, separators, card[i]) == null) {
                i += if (card[i] == '\\') 2 else 1;
            }
            i = @min(i, card.len);
            if (count < max_tokens) tokens_buf[count] = card[start..i];
            count += 1;
        }
        if (count == 0) continue;
        const tokens = tokens_buf[0..@min(count, max_tokens)];
        const head = tokens[0];
        diag.token = head;
        if (eql(head, "*|DELIMITER")) {
            if (count < 2) return error.Malformed;
            c.delimiter = tokens[1][0];
        } else if (eql(head, "*|GROUND_NET")) {
            if (count < 2) return error.Malformed;
            ground = tokens[1];
        } else if (eql(head, "*|NET")) {
            if (count < 2) return error.Malformed;
            net = try c.net(try foreign.unescape(arena, tokens[1]));
        } else if (eql(head, "*|P") or eql(head, "*|I") or eql(head, "*|S")) {
            const on = net orelse return error.SectionBeforeNet;
            if (count < 2) return error.Malformed;
            // `*|P (name dir cap x y)`, `*|I (inst:pin inst pin dir cap x y)`.
            const drives = if (eql(head, "*|P")) count > 2 and eql(tokens[2], "I") else if (eql(head, "*|I")) count > 4 and eql(tokens[4], "O") else false;
            try c.declare(on, try foreign.unescape(arena, tokens[1]), drives);
        } else if (head[0] == '*' or head[0] == '.') {
            // Header and control lines.
        } else {
            const kind: foreign.Kind, const scale: f64 = switch (std.ascii.toUpper(head[0])) {
                'R' => .{ .res, 1.0 },
                'C' => .{ .cap, 1e15 },
                'L' => .{ .ind, 1e12 },
                // Mutual inductance and instances: not compared.
                'K', 'X' => continue,
                else => return error.Malformed,
            };
            if (count < 4) return error.Malformed;
            const b: ?[]const u8 = if (eql(tokens[2], ground)) null else try foreign.unescape(arena, tokens[2]);
            if (b == null and kind != .cap) return error.ElementToGround;
            const a = try foreign.unescape(arena, tokens[1]);
            diag.token = tokens[3];
            const value = spiceNumber(tokens[3]) orelse return error.BadNumber;
            const own = c.declared.get(a) orelse net orelse 0;
            try c.element(own, a, b, kind, value * scale, line);
        }
    }
    diag.* = .{};
    try c.build(gpa, out, diag);
}

/// A SPICE number with an optional scale suffix (`f`, `p`, `n`, `u`, `m`,
/// `k`, `meg`, `g`, `t`, any case, then any unit letters); null when the
/// digits are not a finite number. SPICE reads `F` as femto, not farads.
pub fn spiceNumber(text: []const u8) ?f64 {
    var end: usize = 0;
    while (end < text.len and !(std.ascii.isAlphabetic(text[end]) and text[end] != 'e' and text[end] != 'E')) end += 1;
    const v = std.fmt.parseFloat(f64, text[0..end]) catch return null;
    if (!std.math.isFinite(v)) return null;
    const suffix = text[end..];
    if (suffix.len >= 3 and std.ascii.eqlIgnoreCase(suffix[0..3], "meg")) return v * 1e6;
    if (suffix.len == 0) return v;
    const scale: f64 = switch (std.ascii.toLower(suffix[0])) {
        'f' => 1e-15,
        'p' => 1e-12,
        'n' => 1e-9,
        'u' => 1e-6,
        'm' => 1e-3,
        'k' => 1e3,
        'g' => 1e9,
        't' => 1e12,
        // A unit with no scale (`ohm`, `H`).
        else => 1.0,
    };
    return v * scale;
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "spice numbers read their scale suffixes" {
    // Oracle: the SPICE suffix table (ngspice manual §2.3.4): `f` 1e-15, `p`
    // 1e-12, `k` 1e3, `meg` 1e6, case-insensitive, unit letters after
    // ignored; an exponent `e` is part of the number.
    const cases = [_]struct { []const u8, f64 }{ .{ "1.5k", 1500.0 }, .{ "200f", 200e-15 }, .{ "0.1P", 0.1e-12 }, .{ "2Meg", 2e6 }, .{ "3ohm", 3.0 }, .{ "1e-3", 1e-3 }, .{ "4mA", 4e-3 } };
    for (cases) |c| try std.testing.expectApproxEqRel(c[1], spiceNumber(c[0]).?, 1e-15);
    try std.testing.expectEqual(null, spiceNumber("k"));
    try std.testing.expectEqual(null, spiceNumber("inf"));
}
