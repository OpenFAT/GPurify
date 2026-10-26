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
//! - `pub fn assertBuildEqualsText(what: []const u8, text: []const u8, build: fn (*DeckBuilder) anyerror!void) !void`
//! - `pub fn assertSameSource(what: []const u8, arena: Allocator, a: *const CompiledDeck, b: *const CompiledDeck, strings: *const StrTable) !void`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const paths = @import("paths");
const deck = check.deck;
const Allocator = std.mem.Allocator;
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

/// A drawn layer row (the ingest module does not export the type).
const DrawnLayer = @typeInfo(@FieldType(@FieldType(ingest.deck.DeckSource, "layers"), "items")).pointer.child;

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

/// Two decks with the same rules: ids, severities and typed rows, in order,
/// with every side table a row reads.
pub fn assertSame(a: *const deck.CompiledDeck, b: *const deck.CompiledDeck) !void {
    try testing.expectEqual(a.drc.len(), b.drc.len());
    try testing.expectEqualSlices(geom.StrId, a.drc.id.items, b.drc.id.items);
    for (0..a.drc.len()) |i| {
        try same(a.drc.get(@intCast(i)), b.drc.get(@intCast(i)));
        try testing.expectEqual(a.drc.severity.items[i], b.drc.severity.items[i]);
    }
    // The side tables rows name by index: spacing tables, widths, stacks, ..
    inline for (@typeInfo(check.drc.RuleSet).@"struct".field_names) |f| {
        if (comptime !std.mem.eql(u8, f, "tables")) try same(@field(a.drc, f), @field(b.drc, f));
    }
    try testing.expectEqual(a.deck.layers.len(), b.deck.layers.len());
    try testing.expectEqualSlices(check.erc.rule_set.Slot, a.erc.order.items, b.erc.order.items);
    inline for (@typeInfo(check.erc.rule_set.Tables).@"struct".field_names) |kind| {
        const ta = &@field(a.erc.tables, kind);
        const tb = &@field(b.erc.tables, kind);
        inline for (@typeInfo(@TypeOf(ta.*)).@"struct".field_names) |column| try sameColumn(@field(ta, column), @field(tb, column));
    }
}

/// `build`, run on an empty builder, makes the deck `text` compiles to.
pub fn assertBuildEqualsText(what: []const u8, text: []const u8, build: fn (*deck.DeckBuilder) anyerror!void) !void {
    var c = try compileText(text, 1000);
    defer c.deinit();
    var b = deck.DeckBuilder.init(c.arena.allocator(), c.cd.grid, &c.strings);
    try build(&b);
    var diag: deck.compile.Diag = .{};
    var built = b.finish(gpa, &diag) catch |e| {
        for (diag.deck.diagnostics) |d| std.debug.print("{s}: {s}\n", .{ what, d.message });
        return e;
    };
    defer built.deinit(gpa);
    try assertSameSource(what, c.arena.allocator(), &c.cd, &built, &c.strings);
}

/// `b` is `a` named the same, statement by statement (Rust's
/// `assert_same`): the drawn layers as a set, derived layers, texts, rules
/// by id, kind and layers, connectivity, devices, pex rows and every other
/// statement, then the typed decks, which compare the rules' parameters.
/// Rust's `source` decompiles each typed rule; `sourceOf` keeps the rule
/// table as written, where one typed rule has more than one spelling
/// (`stack_space(a, b, m)` states no `same_net`, a built row `same_net:
/// false`), so the parameters are compared typed.
pub fn assertSameSource(what: []const u8, arena: Allocator, a: *const deck.CompiledDeck, b: *const deck.CompiledDeck, strings: *const geom.StrTable) !void {
    var want = try deck.source.sourceOf(arena, a, strings);
    var have = try deck.source.sourceOf(arena, b, strings);
    errdefer std.debug.print("{s}: the twins differ\n", .{what});
    for ([_]*ingest.deck.DeckSource{ &want, &have }) |d| {
        std.mem.sortUnstable(DrawnLayer, d.layers.items, {}, struct {
            fn less(_: void, x: DrawnLayer, y: DrawnLayer) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.less);
        for (d.rules.items) |*r| r.params = &.{};
    }
    for (want.derived.items, 0..) |row, i| {
        if (i >= have.derived.items.len) break;
        same(row, have.derived.items[i]) catch |e| {
            std.debug.print("{s}: derived layer {d} ({s} vs {s})\n", .{ what, i, row.name, have.derived.items[i].name });
            return e;
        };
    }
    for (want.rules.items, 0..) |r, i| {
        if (i >= have.rules.items.len) break;
        same(r, have.rules.items[i]) catch |e| {
            std.debug.print("{s}: rule {s} (vs {s})\n", .{ what, r.id, have.rules.items[i].id });
            return e;
        };
    }
    try same(want, have);
    try assertSame(a, b);
}

// ---- private ----

/// Deep equality; a list compares its items, never its capacity.
fn same(a: anytype, b: @TypeOf(a)) !void {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (@hasField(T, "items") and @hasField(T, "capacity")) return same(a.items, b.items);
            inline for (info.field_names) |f| try same(@field(a, f), @field(b, f));
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                try testing.expectEqual(a.len, b.len);
                for (a, b) |x, y| try same(x, y);
            },
            else => try testing.expectEqual(a, b),
        },
        .array => for (a, b) |x, y| try same(x, y),
        .optional => {
            try testing.expectEqual(a == null, b == null);
            if (a) |x| try same(x, b.?);
        },
        .@"union" => {
            try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
            switch (a) {
                inline else => |x, tag| try same(x, @field(b, @tagName(tag))),
            }
        },
        else => try testing.expectEqual(a, b),
    }
}

/// One rule-table column (or head) element by element.
fn sameColumn(a: anytype, b: @TypeOf(a)) !void {
    if (@hasField(@TypeOf(a), "rule")) {
        try testing.expectEqualSlices(geom.StrId, a.rule.items, b.rule.items);
        try testing.expectEqualSlices(check.report.Severity, a.severity.items, b.severity.items);
        return;
    }
    try same(a.items, b.items);
}
