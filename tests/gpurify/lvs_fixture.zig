//! The curated LVS fixtures' builders: a circuit drawn and compared with a
//! reference, the verdict the oracle's; a fixture over a reference text;
//! the polarity context; one circuit per model. Ported from
//! tests/exhaustive/lvs.rs (`LVS`, `compared`, `compared_under`,
//! `with_text`, `polar`, `every_model`, `step`).
//!
//! Contents:
//! - `pub const lvs: Checks`, `pub const Pair`
//! - `pub fn compared(arena, name, catalog, layout, reference) !Fixture`
//! - `pub fn comparedUnder(arena, name, catalog, layout, reference, controls) !Fixture`
//! - `pub fn withText(arena, name, catalog, layout, text) !Fixture`
//! - `pub fn polar(arena, dev) !Circuit`, `pub fn everyModel(arena) ![]const Pair`
//! - `pub fn step(k: u32) Finding`

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const Controls = @import("lvs_controls.zig").Controls;
const oracle = @import("lvs_oracle.zig");

/// LVS alone.
pub const lvs: gpurify.Checks = .{ .lvs = true };

/// A circuit as drawn, and the same with its last device's first two pins
/// swapped.
pub const Pair = struct { drawn: Circuit, swapped: Circuit };

/// `layout` drawn and compared with `reference`, the verdict the oracle's.
pub fn compared(arena: Allocator, name: []const u8, catalog: []const []const u8, layout: *const Circuit, reference: *const Circuit) !Fixture {
    return comparedUnder(arena, name, catalog, layout, reference, &.{});
}

/// `compared` with the deck's `controls` stated after the full deck, the
/// verdict the oracle's under them.
pub fn comparedUnder(arena: Allocator, name: []const u8, catalog: []const []const u8, layout: *const Circuit, reference: *const Circuit, controls: *const Controls) !Fixture {
    const deck = try std.mem.concat(arena, u8, &.{ circuit.full_deck, try controls.deck(arena) });
    var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/{s}", .{name}), try arena.dupe([]const u8, catalog), deck, lvs);
    f.layout = try circuit.draw(arena, layout);
    try f.claim(arena, .{ .lvs = try oracle.equivalentUnder(arena, layout, reference, controls) });
    f.reference = try circuit.spice(arena, reference);
    return f;
}

/// A fixture whose reference is `text`; the caller states its claims.
pub fn withText(arena: Allocator, name: []const u8, catalog: []const []const u8, layout: Layout, text: []const u8) !Fixture {
    var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/{s}", .{name}), try arena.dupe([]const u8, catalog), circuit.full_deck, lvs);
    f.layout = layout;
    f.reference = text;
    return f;
}

/// The asymmetric context every polarity case sits in: an `nmos` gated by
/// `n0` whose channel joins `n1` and `n2`, so `n0` and `n1` cannot trade
/// places.
pub fn polar(arena: Allocator, dev: Dev) !Circuit {
    return Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), dev });
}

/// One circuit per model past `nmos`, each with its last device's first
/// two pins swapped beside it.
pub fn everyModel(arena: Allocator) ![]const Pair {
    const drawn = [_]Circuit{
        try polar(arena, Dev.mos(.p, 1, 0, 2)),
        try polar(arena, Dev.mos(.h, 1, 0, 2)),
        try Circuit.init(arena, 4, &.{Dev.mos(.b, 0, 1, 2).sized(2000, 150).bulk(3)}),
        try polar(arena, Dev.onPins(.r, &.{ 0, 1 })),
        try polar(arena, Dev.onPins(.c, &.{ 0, 1 })),
        try polar(arena, Dev.onPins(.d, &.{ 0, 1 })),
        try polar(arena, Dev.onPins(.q, &.{ 0, 1, 2 })),
        try polar(arena, Dev.onPins(.l, &.{ 0, 1 })),
    };
    const out = try arena.alloc(Pair, drawn.len);
    for (drawn, out) |d, *o| {
        var moved = try d.clone(arena);
        const last = &moved.devs[moved.devs.len - 1];
        std.mem.swap(usize, &last.pins[0], &last.pins[1]);
        o.* = .{ .drawn = d, .swapped = moved };
    }
    return out;
}

/// A finding whose measured value is a count.
pub fn step(k: u32) Finding {
    return .{ .measured = .count(k), .at = null };
}

test "a circuit drawn and compared with itself matches" {
    // Oracle: construct-from-answer: each of `everyModel`'s circuits drawn
    // and compared with itself is the oracle's match, and the run's.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixtures: std.ArrayList(Fixture) = .empty;
    for (try everyModel(a)) |pair| try fixtures.append(a, try compared(a, try std.fmt.allocPrint(a, "self/{s}", .{try pair.drawn.code(a)}), &.{"LVS-019"}, &pair.drawn, &pair.drawn));
    try std.testing.expect(fixtures.items[0].expect.items[0].lvs);
    try harness.checkAll(fixtures.items);
}
