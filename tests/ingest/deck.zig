//! `RuleTable`'s CSR accessors, the deck module's documented examples, and
//! every shipped deck through parse, print and parse again. Ported from
//! crates/ingest/tests/deck.rs and the doctests of
//! crates/ingest/src/deck/{mod.rs, source.rs, print.rs}.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const paths = @import("paths");
const deck = ingest.deck;
const ParamValue = deck.ParamValue;
const StrTable = geom.StrTable;
const same = @import("deep.zig").same;

// ---- private ----

fn sameParam(a: ParamValue, b: ParamValue) bool {
    // `Ratio` is compared to a stated tolerance of 1e-12, far below any
    // limit a deck states and far above the error of parsing one.
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .ratio => |x| @abs(x - b.ratio) <= 1e-12,
        else => same(a, b),
    };
}

test "each rule reads back exactly its own slice of the side arrays" {
    // Oracle: construct-from-answer. The side arrays are built holding rules
    // whose ranges are known before anything is read back. The case that
    // matters is the second rule: a table whose ranges are off by one
    // returns the first rule's tail, a well-formed list of another rule's.
    const gpa = testing.allocator;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const spacing = try strings.intern(gpa, "M1.S.1");
    const width = try strings.intern(gpa, "M1.W.1");
    const kind_spacing = try strings.intern(gpa, "min_spacing");
    const kind_width = try strings.intern(gpa, "min_width");
    const value = try strings.intern(gpa, "value");
    const count = try strings.intern(gpa, "count");
    const absent = try strings.intern(gpa, "a parameter no rule declares");
    const l0: geom.LayerId = @fromBackingInt(0);
    const l1: geom.LayerId = @fromBackingInt(1);
    const table: deck.RuleTable = .{
        .spec = &.{
            .{ .id = spacing, .kind = kind_spacing, .layer_start = 0, .layer_len = 2, .param_start = 0, .param_len = 2 },
            .{ .id = width, .kind = kind_width, .layer_start = 2, .layer_len = 1, .param_start = 2, .param_len = 1 },
        },
        .layer_ref = &.{ l0, l1, l0 },
        .param = &.{
            .{ .name = value, .value = .{ .length = 140 } },
            .{ .name = count, .value = .{ .count = 2 } },
            .{ .name = value, .value = .{ .length = 90 } },
        },
    };
    try testing.expectEqualSlices(geom.LayerId, &.{ l0, l1 }, table.layersOf(table.spec[0]));
    try testing.expectEqualSlices(geom.LayerId, &.{l0}, table.layersOf(table.spec[1]));
    const first = table.paramsOf(table.spec[0]);
    try testing.expectEqual(2, first.len);
    try testing.expect(first[0].name == value and sameParam(first[0].value, .{ .length = 140 }));
    try testing.expect(first[1].name == count and sameParam(first[1].value, .{ .count = 2 }));
    const second = table.paramsOf(table.spec[1]);
    try testing.expectEqual(1, second.len);
    try testing.expect(sameParam(table.findParam(table.spec[1], value).?, .{ .length = 90 }));
    try testing.expectEqual(null, table.findParam(table.spec[1], count));
    try testing.expectEqual(null, table.findParam(table.spec[0], absent));
}

test "the deck module's example parses and refuses an off-grid limit" {
    // Oracle: spec example (crates/ingest/src/deck/mod.rs doctest): `width >=`
    // is `min_width`, 140 nm on a 1 nm grid is 140 dbu, and 142 nm is off the
    // deck's 5 nm grid.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const text = "grid 5nm\nlayer met1 = gds(68, 20)\nrule m1.1 width(met1) >= 140nm\n";
    var diag: deck.Diag = .{};
    const d = try deck.parseDeck(arena.allocator(), gpa, text, try .init(1000), &strings, &diag);
    const rule = d.rules.spec[0];
    try testing.expectEqualStrings("min_width", strings.resolve(rule.kind));
    try testing.expect(sameParam(d.rules.findParam(rule, strings.get("limit").?).?, .{ .length = 140 }));
    const off = "grid 5nm\nlayer met1 = gds(68, 20)\nrule m1.1 width(met1) >= 142nm\n";
    var fresh: StrTable = .empty;
    defer fresh.deinit(gpa);
    try testing.expectError(error.Invalid, deck.parseDeck(arena.allocator(), gpa, off, try .init(1000), &fresh, &diag));
}

test "lowering refuses a derived layer of an undeclared layer" {
    // Oracle: spec example (crates/ingest/src/deck/source.rs `lower` doctest):
    // `met2` is not declared; with `met1` the deck holds two layers.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var src: deck.DeckSource = .{};
    try src.layers.append(a, .{ .name = "met1", .stream = .{ 68, 20 } });
    try src.derived.append(a, .{ .name = "fat", .op = .holes, .layers = &.{"met2"} });
    var diag: deck.Diag = .{};
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    try testing.expectError(error.Malformed, deck.lower(a, gpa, &src, &strings, &diag));
    src.derived.items[0].layers = &.{"met1"};
    var fresh: StrTable = .empty;
    defer fresh.deinit(gpa);
    const d = try deck.lower(a, gpa, &src, &fresh, &diag);
    try testing.expectEqual(2, d.layers.len());
}

test "a printed deck reads back to the same source" {
    // Oracle: law (round trip), from crates/ingest/src/deck/print.rs's
    // doctest: printing writes `140nm` for 0.14 um, and parsing the printed
    // text gives back the source it was printed from.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "grid 5nm\nlayer met1 = gds(68, 20)\nlayer fat = met1.sized(-1.5um).sized(1.5um)\nrule m1.1 width(met1) >= 0.14um\n";
    var diag: deck.Diag = .{};
    const src = try deck.parseSource(a, gpa, text, try .init(1000), &diag);
    var why: []const u8 = "";
    const printed = try deck.print(a, &src, try .init(1000), &why);
    try testing.expect(std.mem.indexOf(u8, printed, "rule m1.1 width(met1) >= 140nm") != null);
    const again = try deck.parseSource(a, gpa, printed, try .init(1000), &diag);
    try testing.expect(same(src, again));
}

test "every shipped deck parses, prints, and reads back to the same deck" {
    // Oracle: law (round trip) over the shipped decks: `print` is the
    // parser's inverse, so the printed text parses to an equal source, which
    // lowers to the same deck in a fresh table.
    const gpa = testing.allocator;
    const decks = [_][]const u8{ "sky130", "gf180mcu", "ihp_sg13g2", "asap7" };
    for (decks) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/pdks/{s}.deck", .{ paths.root, name });
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
        var diag: deck.Diag = .{};
        const src = deck.parseSource(a, gpa, text, try .init(1000), &diag) catch |err| {
            for (diag.diagnostics) |d| std.debug.print("{s}:{d}:{d}: {s}\n", .{ name, d.line, d.col, d.message });
            return err;
        };
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        _ = deck.lower(a, gpa, &src, &strings, &diag) catch |err| {
            std.debug.print("{s}: {s}\n", .{ name, diag.malformed });
            return err;
        };
        var why: []const u8 = "";
        const printed = deck.print(a, &src, try .init(1000), &why) catch |err| {
            std.debug.print("{s}: {s}\n", .{ name, why });
            return err;
        };
        const again = try deck.parseSource(a, gpa, printed, try .init(1000), &diag);
        try testing.expect(same(src, again));
    }
}
