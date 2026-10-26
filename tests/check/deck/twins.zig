//! Every shipped deck equals its twin built in code, and every twin survives
//! the printer. Ported from crates/check/tests/deck/builder.rs
//! (`every_shipped_deck_equals_its_rust_twin`) and printer.rs
//! (`every_rust_twin_survives_printing`); the twins are twins/<deck>_<n>.zig.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const DeckBuilder = check.deck.DeckBuilder;
const gpa = testing.allocator;

const Part = fn (*DeckBuilder) std.mem.Allocator.Error!void;

/// Each shipped deck's twin, its parts in statement order.
const twins = .{
    .{ "generic_finfet", .{@import("twins/generic_finfet_1.zig").build} },
    .{ "gf180mcu", .{ @import("twins/gf180mcu_1.zig").build, @import("twins/gf180mcu_2.zig").build } },
    .{ "ihp_sg13g2", .{ @import("twins/ihp_sg13g2_1.zig").build, @import("twins/ihp_sg13g2_2.zig").build } },
    .{ "sky130", .{ @import("twins/sky130_1.zig").build, @import("twins/sky130_2.zig").build } },
};

// ---- private ----

/// The twin `parts` built into `c`'s strings, on `c`'s grid.
fn buildTwin(c: *common.Compiled, parts: anytype) !check.deck.CompiledDeck {
    var b = DeckBuilder.init(c.arena.allocator(), c.cd.grid, &c.strings);
    inline for (parts) |part| try @as(Part, part)(&b);
    var diag: check.deck.compile.Diag = .{};
    return b.finish(gpa, &diag) catch |e| {
        for (diag.deck.diagnostics) |d| std.debug.print("twin: {s}\n", .{d.message});
        if (diag.deck.malformed.len > 0) std.debug.print("twin: {s}\n", .{diag.deck.malformed});
        return e;
    };
}

test "every shipped deck equals its twin" {
    // Oracle: differential against the parser, of a twin translated from the
    // deck text by a reader of docs/deck.md independent of the parser (the
    // Rust twin, translated mechanically here). Both compile into one string
    // table, so their ids compare.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    inline for (twins) |twin| {
        var c = try common.compileText(try common.shippedText(arena.allocator(), twin[0]), 1000);
        defer c.deinit();
        var built = try buildTwin(&c, twin[1]);
        defer built.deinit(gpa);
        try common.assertSameSource(twin[0], c.arena.allocator(), &c.cd, &built, &c.strings);
    }
}

test "every twin survives printing" {
    // Oracle: round trip: a deck built in code prints, compiles back typed
    // the same, and prints again to the same text.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    inline for (twins) |twin| {
        var c = try common.compileText(try common.shippedText(arena.allocator(), twin[0]), 1000);
        defer c.deinit();
        const built = try buildTwin(&c, twin[1]);
        c.cd.deinit(gpa);
        c.cd = built;
        try common.assertRoundTrip(twin[0], &c);
    }
}
