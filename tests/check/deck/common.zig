//! Fixtures the deck suites share: a deck compiled from text with its
//! arena and strings, a shipped deck's text, and the printer round trip. Ported from crates/check/tests/deck/{main,
//! printer, builder}.rs (`grid`, `DECKS`, `assert_round_trip`,
//! `assert_same`).
//!
//! Contents:
//! - `pub const Compiled = struct`, `Compiled.deinit`, `pub const shipped`
//! - `pub fn compileText(text: []const u8, dbu_per_um: i64) !Compiled`, `pub fn refused(text: []const u8) bool`
//! - `pub fn shippedText(arena: Allocator, name: []const u8) ![]const u8`
//! - `pub fn assertRoundTrip(what: []const u8, c: *Compiled) !void`, `pub fn assertSame(a: *const CompiledDeck, b: *const CompiledDeck) !void`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const paths = @import("paths");
const deck = check.deck;
const gpa = testing.allocator;

/// A compiled deck and the arena and strings it lives in.
pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    cd: deck.CompiledDeck,

    pub fn deinit(c: *Compiled) void {
        c.cd.deinit(gpa);
        c.strings.deinit(gpa);
        c.arena.deinit();
    }
};

pub const shipped = [_][]const u8{ "generic_finfet", "gf180mcu", "ihp_sg13g2", "sky130" };

/// Compiles `text` on a 1 nm grid (or `grid`), printing the refusal.
pub fn compileText(text: []const u8, dbu_per_um: i64) !Compiled {
    var c: Compiled = .{ .arena = .init(gpa), .cd = undefined };
    errdefer {
        c.strings.deinit(gpa);
        c.arena.deinit();
    }
    var diag: deck.compile.Diag = .{};
    c.cd = deck.compile.compile(gpa, c.arena.allocator(), text, try geom.Grid.init(dbu_per_um), &c.strings, &diag) catch |e| {
        for (diag.deck.diagnostics) |d| std.debug.print("deck: line {d}: {s}\n", .{ d.line, d.message });
        if (diag.deck.malformed.len > 0) std.debug.print("deck: {s}\n", .{diag.deck.malformed});
        return e;
    };
    return c;
}

/// Whether `text` fails to compile.
pub fn refused(text: []const u8) bool {
    var c = compileText(text, 1000) catch return true;
    c.deinit();
    return false;
}

/// A shipped deck's whole text, in `arena`.
pub fn shippedText(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/pdks/{s}.deck", .{ paths.root, name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
}

/// `c` printed, compiled back into its strings with every rule typed the
/// same, and printed again to the same text.
pub fn assertRoundTrip(what: []const u8, c: *Compiled) !void {
    const arena = c.arena.allocator();
    var why: []const u8 = "";
    const printed = deck.source.print(arena, &c.cd, &c.strings, &why) catch |e| {
        std.debug.print("{s}: {s}\n", .{ what, why });
        return e;
    };
    var diag: deck.compile.Diag = .{};
    var again = deck.compile.compile(gpa, arena, printed, c.cd.grid, &c.strings, &diag) catch |e| {
        std.debug.print("{s}: the printed deck does not compile\n{s}\n", .{ what, printed });
        return e;
    };
    defer again.deinit(gpa);
    try assertSame(&c.cd, &again);
    const reprinted = try deck.source.print(arena, &again, &c.strings, &why);
    try testing.expectEqualStrings(printed, reprinted);
}

/// Two decks with the same rules: ids, severities and typed rows, in order.
pub fn assertSame(a: *const deck.CompiledDeck, b: *const deck.CompiledDeck) !void {
    try testing.expectEqual(a.drc.len(), b.drc.len());
    try testing.expectEqualSlices(geom.StrId, a.drc.id.items, b.drc.id.items);
    for (0..a.drc.len()) |i| {
        try testing.expect(std.meta.eql(a.drc.get(@intCast(i)), b.drc.get(@intCast(i))));
        try testing.expectEqual(a.drc.severity.items[i], b.drc.severity.items[i]);
    }
    try testing.expectEqual(a.deck.layers.len(), b.deck.layers.len());
    try testing.expectEqualSlices(check.erc.rule_set.Slot, a.erc.order.items, b.erc.order.items);
    inline for (@typeInfo(check.erc.rule_set.Tables).@"struct".field_names) |kind| {
        const ta = &@field(a.erc.tables, kind);
        const tb = &@field(b.erc.tables, kind);
        inline for (@typeInfo(@TypeOf(ta.*)).@"struct".field_names) |column| try sameColumn(@field(ta, column), @field(tb, column));
    }
}

// ---- private ----

/// One rule-table column (or head) element by element.
fn sameColumn(a: anytype, b: @TypeOf(a)) !void {
    if (@hasField(@TypeOf(a), "rule")) {
        try testing.expectEqualSlices(geom.StrId, a.rule.items, b.rule.items);
        try testing.expectEqualSlices(check.report.Severity, a.severity.items, b.severity.items);
        return;
    }
    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| try testing.expect(std.meta.eql(x, y));
}
