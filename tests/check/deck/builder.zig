//! The builder states a deck in code: what it builds compiles as the same
//! text does, overrides keep their places and say where each rule came
//! from, and what it refuses is reported, never dropped. Ported in part
//! from crates/check/tests/deck/builder.rs; the Rust tests written against
//! the per-kind row constructors (`deck::rules`) and the PDK twins wait for
//! those constructors (deferred: `each_twin_builds_the_deck_its_text_does`,
//! the per-kind cases of `kinds.rs`, `esd_kinds.rs`, `path_and_ac_kinds.rs`).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const common = @import("common.zig");
const deck = check.deck;
const NamedSource = @import("ingest").deck.NamedSource;
const DeckBuilder = deck.DeckBuilder;
const gpa = testing.allocator;

const text =
    \\grid 1nm
    \\layer met1 = gds(68, 20)
    \\layer via1 = gds(68, 44)
    \\layer big = met1.sized(100nm)
    \\rule m1.1 width(met1) >= 140nm
    \\rule m1.2 space(met1) >= 140nm
    \\rule v.1 enclosure(via1, met1) >= 55nm
    \\
;

// ---- private ----

/// The text deck, stated in code.
fn build(b: *DeckBuilder) !void {
    const a = b.arena;
    try b.layer("met1", .{ 68, 20 });
    try b.layer("via1", .{ 68, 44 });
    try b.derived("big", .{ .sized = .{ .dx = 100, .dy = 100 } }, try a.dupe([]const u8, &.{"met1"}), &.{});
    try b.rule("m1.1", .{ .kind = "min_width", .layers = try a.dupe([]const u8, &.{"met1"}), .params = try limit(a, 140) });
    try b.rule("m1.2", .{ .kind = "min_spacing", .layers = try a.dupe([]const u8, &.{"met1"}), .params = try limit(a, 140) });
    try b.rule("v.1", .{ .kind = "min_enclosure", .layers = try a.dupe([]const u8, &.{ "met1", "via1" }), .params = try limit(a, 55) });
}

fn limit(a: std.mem.Allocator, v: i64) ![]const NamedSource {
    return a.dupe(NamedSource, &.{.{ .name = "limit", .value = .{ .value = .{ .length = v } } }});
}

fn nothing(_: *const deck.custom.CustomCtx, _: *deck.custom.Findings) std.mem.Allocator.Error!void {}

test "a built deck types every rule as its text does" {
    // Oracle: differential: the same statements as text and as calls give
    // the same typed rules, ids and layers.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    var b = DeckBuilder.init(c.arena.allocator(), c.cd.grid, &c.strings);
    try build(&b);
    var diag: deck.compile.Diag = .{};
    var built = try b.finish(gpa, &diag);
    defer built.deinit(gpa);
    try common.assertSame(&c.cd, &built);
    for (built.provenance.items) |p| try testing.expectEqual(deck.compile.Origin.base, p.origin);
}

test "overrides keep their places and say where each rule came from" {
    // Oracle: construct-from-answer (deck-library plan §4.3): replacing
    // m1.2 keeps it second, removing v.1 drops it, adding m1.9 puts it last;
    // provenance reads base, replaced, added.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    const a = c.arena.allocator();
    var b = try DeckBuilder.fromDeck(a, &c.cd, &c.strings);
    try b.replace("m1.2", .{ .kind = "min_spacing", .layers = try a.dupe([]const u8, &.{"met1"}), .params = try limit(a, 200) });
    try b.remove("v.1");
    try b.add("m1.9", .{ .kind = "max_width", .layers = try a.dupe([]const u8, &.{"met1"}), .params = try limit(a, 5000) });
    var diag: deck.compile.Diag = .{};
    var cd = try b.finish(gpa, &diag);
    defer cd.deinit(gpa);
    const want = [_]struct { []const u8, deck.compile.Origin }{ .{ "m1.1", .base }, .{ "m1.2", .replaced }, .{ "m1.9", .added } };
    try testing.expectEqual(want.len, cd.provenance.items.len);
    for (want, cd.provenance.items) |w, p| {
        try testing.expectEqualStrings(w[0], c.strings.resolve(p.id));
        try testing.expectEqual(w[1], p.origin);
    }
    try testing.expectEqual(@as(i64, 200), cd.drc.get(1).min_spacing.limit);
}

test "what the builder refuses is reported not dropped" {
    // Oracle: construct-from-answer: a duplicate id, an override of a rule
    // the deck lacks, a name no deck can write and a length off the grid are
    // four refusals, each one diagnostic.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    const a = c.arena.allocator();
    var b = try DeckBuilder.fromDeck(a, &c.cd, &c.strings);
    try b.add("m1.1", .{ .kind = "min_width", .layers = try a.dupe([]const u8, &.{"met1"}), .params = try limit(a, 1) });
    try b.replace("nope", .{ .kind = "min_width", .layers = try a.dupe([]const u8, &.{"met1"}), .params = try limit(a, 1) });
    try b.layer("2bad", .{ 1, 1 });
    _ = try b.length(0.5);
    var diag: deck.compile.Diag = .{};
    try testing.expectError(error.Invalid, b.finish(gpa, &diag));
    try testing.expectEqual(@as(usize, 4), diag.deck.diagnostics.len);
}

test "a built deck survives printing and a custom rule refuses it" {
    // Oracle: round trip; and the printer's contract: a custom rule is a
    // function no deck text states, so printing names it and refuses.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    var b = DeckBuilder.init(c.arena.allocator(), c.cd.grid, &c.strings);
    try build(&b);
    var diag: deck.compile.Diag = .{};
    var built = try b.finish(gpa, &diag);
    defer built.deinit(gpa);
    var why: []const u8 = "";
    const printed = try deck.source.print(c.arena.allocator(), &built, &c.strings, &why);
    var again = try common.compileText(printed, 1000);
    defer again.deinit();
    try testing.expectEqual(built.drc.len(), again.cd.drc.len());
    var b2 = DeckBuilder.init(c.arena.allocator(), c.cd.grid, &c.strings);
    try build(&b2);
    try b2.custom("m1.small", &.{"met1"}, .@"error", nothing);
    var cd2 = try b2.finish(gpa, &diag);
    defer cd2.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), cd2.ruleCount());
    try testing.expectError(error.Unprintable, deck.source.print(c.arena.allocator(), &cd2, &c.strings, &why));
    try testing.expect(std.mem.indexOf(u8, why, "m1.small") != null);
}
