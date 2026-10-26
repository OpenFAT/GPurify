//! A SPEF file (IEEE 1481-2009, the `*D_NET` detailed form) read into a
//! `foreign.Read`. In: the file's text. Out: its nets and network, in fF, Ω
//! and pH. Ported from crates/extract/src/foreign.rs (`read_spef`).
//!
//! Read: `*C_UNIT`, `*R_UNIT`, `*L_UNIT`, `*DELIMITER`, `*NAME_MAP`, and
//! every `*D_NET` with its `*CONN`, `*CAP`, `*RES` and `*INDUC` sections; a
//! `min:typ:max` triplet reads as its typical value. The driver is a net's
//! first `*P` port of direction `I`, else its first `*I` pin of direction
//! `O`. Everything else in the header is skipped. Names are unescaped once
//! (`\x` reads `x`), after a `*NAME_MAP` index is replaced by its name.
//!
//! Contents:
//! - `pub fn readInto(gpa: Allocator, text: []const u8, out: *Read, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const foreign = @import("foreign.zig");
const Read = foreign.Read;
const Error = foreign.Error;
const Diagnostic = foreign.Diagnostic;
const Collect = foreign.Collect;

const At = enum { header, name_map, conn, cap, res, ind };

const max_tokens = 8;

/// Reads `text` into `out` (cleared). Errors: what foreign.zig's `Error`
/// lists, with the line and token in `diag`.
pub fn readInto(gpa: Allocator, text: []const u8, out: *Read, diag: *Diagnostic) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var c: Collect = .init(arena);
    var cap_unit: f64 = 1e3;
    var res_unit: f64 = 1.0;
    var ind_unit: f64 = 1e12;
    var name_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var at: At = .header;
    var net: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (lines.next()) |raw| {
        line += 1;
        diag.* = .{ .line = line };
        const body = if (std.mem.find(u8, raw, "//")) |cut| raw[0..cut] else raw;
        var tokens_buf: [max_tokens][]const u8 = undefined;
        var it = std.mem.tokenizeAny(u8, body, " \t\r");
        var count: usize = 0;
        while (it.next()) |t| : (count += 1) {
            if (count < max_tokens) tokens_buf[count] = t;
        }
        if (count == 0) continue;
        const tokens = tokens_buf[0..@min(count, max_tokens)];
        const head = tokens[0];
        diag.token = head;
        // A keyword ends the name map, whose entries are `*<digits> name`.
        if (at == .name_map and head.len > 1 and head[0] == '*' and std.ascii.isAlphabetic(head[1])) at = .header;
        if (eql(head, "*C_UNIT")) {
            cap_unit = try unit(tokens, count, &.{ .{ "PF", 1e3 }, .{ "FF", 1.0 } }, diag);
        } else if (eql(head, "*R_UNIT")) {
            res_unit = try unit(tokens, count, &.{ .{ "OHM", 1.0 }, .{ "KOHM", 1e3 } }, diag);
        } else if (eql(head, "*L_UNIT")) {
            ind_unit = try unit(tokens, count, &.{ .{ "HENRY", 1e12 }, .{ "MH", 1e9 }, .{ "UH", 1e6 } }, diag);
        } else if (eql(head, "*DELIMITER")) {
            if (count < 2) return error.Malformed;
            c.delimiter = tokens[1][0];
        } else if (eql(head, "*NAME_MAP")) {
            at = .name_map;
        } else if (eql(head, "*R_NET") or eql(head, "*D_PNET") or eql(head, "*R_PNET") or eql(head, "*DEFINE") or eql(head, "*PDEFINE")) {
            return error.Unsupported;
        } else if (eql(head, "*D_NET")) {
            if (count < 2) return error.Malformed;
            net = try c.net(try resolve(arena, tokens[1], &name_map, c.delimiter));
            at = .header;
        } else if (eql(head, "*CONN") or eql(head, "*CAP") or eql(head, "*RES") or eql(head, "*INDUC")) {
            // A section belongs to the `*D_NET` above it.
            if (c.nets.items.len == 0) return error.SectionBeforeNet;
            at = if (eql(head, "*CONN")) .conn else if (eql(head, "*CAP")) .cap else if (eql(head, "*RES")) .res else .ind;
        } else if (eql(head, "*END")) {
            at = .header;
        } else switch (at) {
            .header => {},
            .name_map => if (head[0] == '*' and count == 2) try name_map.put(arena, head[1..], tokens[1]),
            .conn => if (eql(head, "*P") or eql(head, "*I")) {
                if (count < 3) return error.Malformed;
                const drives = (eql(head, "*P") and eql(tokens[2], "I")) or (eql(head, "*I") and eql(tokens[2], "O"));
                try c.declare(net, try resolve(arena, tokens[1], &name_map, c.delimiter), drives);
            } else if (eql(head, "*N")) {
                if (count < 2) return error.Malformed;
                try c.declare(net, try resolve(arena, tokens[1], &name_map, c.delimiter), false);
            } else return error.Malformed,
            .cap, .res, .ind => {
                const kind: foreign.Kind, const scale = switch (at) {
                    .cap => .{ .cap, cap_unit },
                    .res => .{ .res, res_unit },
                    .ind => .{ .ind, ind_unit },
                    .header, .name_map, .conn => unreachable,
                };
                if (!(count == 4 or (count == 3 and kind == .cap))) return error.Malformed;
                const b: ?[]const u8 = if (count == 4) try resolve(arena, tokens[2], &name_map, c.delimiter) else null;
                const value_text = tokens[count - 1];
                diag.token = value_text;
                const value = foreign.number(value_text) orelse return error.BadNumber;
                try c.element(net, try resolve(arena, tokens[1], &name_map, c.delimiter), b, kind, value * scale, line);
            },
        }
    }
    diag.* = .{};
    try c.build(gpa, out, diag);
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A `*X_UNIT <number> <name>` line's scale to fF, Ω or pH.
fn unit(tokens: []const []const u8, count: usize, scales: []const struct { []const u8, f64 }, diag: *Diagnostic) Error!f64 {
    if (count != 3) return error.Malformed;
    diag.token = tokens[2];
    const scale = for (scales) |s| {
        if (std.ascii.eqlIgnoreCase(s[0], tokens[2])) break s[1];
    } else return error.UnknownUnit;
    diag.token = tokens[1];
    return (foreign.number(tokens[1]) orelse return error.BadNumber) * scale;
}

/// A name with a `*NAME_MAP` index replaced, `*12:3` with `*12` mapped to
/// `n` reading `n:3`, then unescaped.
fn resolve(arena: Allocator, name: []const u8, map: *const std.StringHashMapUnmanaged([]const u8), delimiter: u8) Allocator.Error![]const u8 {
    if (name.len > 0 and name[0] == '*') {
        const rest = name[1..];
        const cut = std.mem.findScalar(u8, rest, delimiter) orelse rest.len;
        if (map.get(rest[0..cut])) |full| return foreign.unescape(arena, try std.mem.concat(arena, u8, &.{ full, rest[cut..] }));
    }
    return foreign.unescape(arena, name);
}
