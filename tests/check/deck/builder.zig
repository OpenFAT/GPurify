//! The builder states a deck in code: what it builds compiles as the same
//! text does, overrides keep their places and say where each rule came
//! from, and what it refuses is reported, never dropped, in the parser's
//! words. Ported in part from crates/check/tests/deck/builder.rs (the PDK
//! twins are twins.zig; the refusals of statements the builder writes
//! straight into its `DeckSource`, and the call-site lines Rust's
//! `#[track_caller]` reports, have no builder twin here).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const common = @import("common.zig");
const deck = check.deck;
const DeckBuilder = deck.DeckBuilder;
const row = deck.rules.row;
const l = deck.expr.layer;
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
    try b.layer("met1", .{ 68, 20 });
    try b.layer("via1", .{ 68, 44 });
    try b.derived("big", l("met1").sized(100));
    try b.rule("m1.1", row(.min_width, .{ .layer = l("met1") }, .{ .limit = 140 }));
    try b.rule("m1.2", row(.min_spacing, .{ .layer = l("met1") }, .{ .limit = 140 }));
    try b.rule("v.1", row(.min_enclosure, .{ .inner = l("via1"), .outer = l("met1") }, .{ .limit = 55 }));
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
    var b = try DeckBuilder.fromDeck(c.arena.allocator(), &c.cd, &c.strings);
    try b.replace("m1.2", row(.min_spacing, .{ .layer = l("met1") }, .{ .limit = 200 }));
    try b.remove("v.1");
    try b.add("m1.9", row(.max_width, .{ .layer = l("met1") }, .{ .limit = 5000 }));
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
    var b = try DeckBuilder.fromDeck(c.arena.allocator(), &c.cd, &c.strings);
    try b.add("m1.1", row(.min_width, .{ .layer = l("met1") }, .{ .limit = 1 }));
    try b.replace("nope", row(.min_width, .{ .layer = l("met1") }, .{ .limit = 1 }));
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

test "the h4 layer operations build as their text" {
    // Oracle: construct-from-answer, the parser's reading of the text twin:
    // `.covering()`, `.not_covering()`, `.overlapping()`, per-axis `.sized(dx,
    // dy)` and an edge layer's `.extended(..)`, each as a derived layer and
    // inline in a rule.
    const h4 =
        \\grid 1nm
        \\layer m = gds(1, 0)
        \\layer n = gds(2, 0)
        \\layer holders = m.covering(n)
        \\layer empty = m.not_covering(n)
        \\layer crossing = m.overlapping(n)
        \\layer wide = m.sized(20nm, 0nm)
        \\layer thin = m.sized(-10nm, -5nm)
        \\layer boxes = m.edges().extended(begin: 5nm, end: 0nm, out: 10nm, in: 0nm)
        \\rule a forbidden(holders)
        \\rule b forbidden(n.overlapping(m.sized(30nm, 10nm)))
        \\rule c forbidden(n.edges().extended(begin: 0nm, end: 0nm, out: 0nm, in: 15nm) and m)
        \\
    ;
    try common.assertBuildEqualsText("h4 layer operations", h4, struct {
        fn build(b: *DeckBuilder) anyerror!void {
            try b.layer("m", .{ 1, 0 });
            try b.layer("n", .{ 2, 0 });
            try b.derived("holders", l("m").covering(l("n")));
            try b.derived("empty", l("m").notCovering(l("n")));
            try b.derived("crossing", l("m").overlapping(l("n")));
            try b.derived("wide", l("m").sizedXy(20, 0));
            try b.derived("thin", l("m").sizedXy(-10, -5));
            try b.derived("boxes", l("m").edges().extended(5, 0, 10, 0));
            try b.rule("a", row(.forbidden, .{ .layer = l("holders") }, .{}));
            try b.rule("b", row(.forbidden, .{ .layer = l("n").overlapping(l("m").sizedXy(30, 10)) }, .{}));
            try b.rule("c", row(.forbidden, .{ .layer = l("n").edges().extended(0, 0, 0, 15).@"and"(l("m")) }, .{}));
        }
    }.build);
}

test "every builder refusal has the parser's words" {
    // Oracle: differential, the parser's message for the text twin of each
    // refusal: a rule id used twice, a layer name bound twice, bounds nothing
    // satisfies, a derived layer that is only a layer, and the h4 operations'
    // `sized` growing one axis and shrinking the other, `extended` below 0
    // and `extended` with no width.
    const header = "grid 1nm\nlayer m = gds(1, 0)\nlayer n = gds(2, 0)\n";
    const Case = struct { []const u8, *const fn (*DeckBuilder) anyerror!void };
    const cases = [_]Case{
        .{ "rule a width(m) >= 10nm\nrule a width(m) >= 20nm\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.rule("a", row(.min_width, .{ .layer = l("m") }, .{ .limit = 10 }));
                try b.rule("a", row(.min_width, .{ .layer = l("m") }, .{ .limit = 20 }));
            }
        }.f },
        .{ "layer m = gds(3, 0)\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.layer("m", .{ 3, 0 });
            }
        }.f },
        .{ "layer x = m.with_area(>= 2nm2, <= 1nm2)\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.derived("x", l("m").withArea(&.{ .{ .at_least = 2 }, .{ .at_most = 1 } }));
            }
        }.f },
        .{ "layer x = m\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.derived("x", l("m"));
            }
        }.f },
        .{ "layer x = m.sized(10nm, -10nm)\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.derived("x", l("m").sizedXy(10, -10));
            }
        }.f },
        .{ "layer x = m.edges().extended(begin: 0nm, end: -5nm, out: 10nm, in: 0nm)\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.derived("x", l("m").edges().extended(0, -5, 10, 0));
            }
        }.f },
        .{ "layer x = m.edges().extended(begin: 5nm, end: 5nm, out: 0nm, in: 0nm)\n", struct {
            fn f(b: *DeckBuilder) anyerror!void {
                try b.derived("x", l("m").edges().extended(5, 5, 0, 0));
            }
        }.f },
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (cases) |case| {
        // The parser's refusal.
        var strings: geom.StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: deck.compile.Diag = .{};
        const twin = try std.mem.concat(a, u8, &.{ header, case[0] });
        try testing.expectError(error.Invalid, deck.compile.compile(gpa, a, twin, try geom.Grid.init(1000), &strings, &diag));
        const parsed = diag.deck.diagnostics[0].message;
        // The builder's.
        var b = DeckBuilder.init(a, try geom.Grid.init(1000), &strings);
        try b.layer("m", .{ 1, 0 });
        try b.layer("n", .{ 2, 0 });
        try case[1](&b);
        var built_diag: deck.compile.Diag = .{};
        try testing.expectError(error.Invalid, b.finish(gpa, &built_diag));
        const built = built_diag.deck.diagnostics[0].message;
        if (std.mem.indexOf(u8, parsed, built) == null and std.mem.indexOf(u8, built, parsed) == null) {
            std.debug.print("the builder refuses \"{s}\" where the parser refuses \"{s}\"\n", .{ built, parsed });
            return error.TestExpectedEqual;
        }
    }
}
