//! The decks in `pdks/` are inputs this repository ships: every one parses,
//! types its DRC rows, and files every rule under a kind one domain spells.
//! Ported from the root tests/pdk_decks.rs, its DRC and deck parts.
//!
//! The oracle: construct-from-answer, with the answer stated as a property
//! rather than a number: whatever a deck says, if DRC cannot build a rule
//! from it, or a rule names a layer the deck never declared, then the tool's
//! verdict on that PDK is decided by what is missing from the file. The
//! decks are discovered by reading the directory: an empty `pdks/` would
//! make every loop below pass vacuously.
//!
//! Deferred (ERC rule set, wave 4): the ERC half of
//! `every_deck_in_pdks_parses_and_builds_both_rule_sets` (here every ERC row
//! is filed by kind name, and `deck.compile` is shown refusing it by name).
//! Deferred (the `gpurify::pdks` constants, a front-end crate's):
//! `every_deck_file_is_a_shipped_constant_byte_for_byte`,
//! `every_shipped_constant_compiles`.
//! Deferred (pex, connectivity and device tables, ingest's, ERC's and
//! topology's): `every_current_carrying_layer_has_a_sheet_resistance`,
//! `a_pex_stack_that_exists_has_one_row_per_declared_layer`,
//! `every_via_joins_two_declared_conductors`,
//! `every_deck_pairs_a_text_layer_with_a_conductor`,
//! `every_mos_terminal_names_a_conductor`.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const paths = @import("paths");
const common = @import("common.zig");
const gpa = common.gpa;

/// One loaded deck: its text and parse, owned by `arena`.
const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    text: []const u8,
    deck: ingest.deck.Deck,

    fn deinit(l: *Loaded) void {
        l.strings.deinit(gpa);
        l.arena.deinit();
    }
};

// ---- private ----

/// Every `*.deck` under `pdks/`, sorted, discovered by reading the
/// directory; the names in `arena`.
fn deckFiles(arena: std.mem.Allocator) ![]const []const u8 {
    const root = try std.fmt.allocPrint(arena, "{s}/pdks", .{paths.root});
    var dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next(testing.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".deck")) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    // An empty pdks/ makes every assertion below pass without examining
    // anything: the failure these tests exist to close.
    try testing.expect(names.items.len > 0);
    return names.items;
}

fn load(name: []const u8) !Loaded {
    var l: Loaded = .{ .arena = .init(gpa), .text = "", .deck = undefined };
    errdefer l.deinit();
    const a = l.arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/pdks/{s}", .{ paths.root, name });
    l.text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
    var diag: ingest.deck.Diag = .{};
    l.deck = ingest.deck.parseDeck(a, gpa, l.text, try geom.Grid.init(1000), &l.strings, &diag) catch |e| {
        std.debug.print("{s} does not parse: {t} {s}\n", .{ name, e, diag.malformed });
        return e;
    };
    return l;
}

test "every deck in pdks parses and builds its drc rule set" {
    // Oracle: construct-from-answer. Every shipped deck is a deck: it parses,
    // and DRC builds a rule set from it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (try deckFiles(arena.allocator())) |name| {
        var l = try load(name);
        defer l.deinit();
        var diag: check.drc.params.Diagnostic = .{};
        var rs = check.drc.fromDeck(gpa, &l.deck, &l.strings, &diag) catch |e| {
            std.debug.print("{s}: the DRC rule set does not build: {t}\n", .{ name, e });
            return e;
        };
        rs.deinit(gpa);
    }
}

test "every deck configures rules and every rule belongs to a domain" {
    // Oracle: construct-from-answer. A deck configures at least one rule, and
    // every rule it configures is filed by exactly one domain.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (try deckFiles(arena.allocator())) |name| {
        var l = try load(name);
        defer l.deinit();
        var diag: check.drc.params.Diagnostic = .{};
        var rs = try check.drc.fromDeck(gpa, &l.deck, &l.strings, &diag);
        defer rs.deinit(gpa);
        var erc: u32 = 0;
        for (l.deck.rules.spec) |spec| {
            const kind = l.strings.resolve(spec.kind);
            const is_erc = check.erc.kinds.isKind(kind);
            // Exactly one domain spells each kind.
            try testing.expect(is_erc != (check.drc.kinds.byName(kind) != null));
            erc += @intFromBool(is_erc);
        }
        const filed = rs.len() + erc;
        try testing.expect(filed > 0);
        try testing.expectEqual(@as(u32, @intCast(l.deck.rules.spec.len)), filed);
    }
}

test "every shipped deck's erc rows are refused by name until wave 4" {
    // Oracle: the wave-3 contract: deck compile refuses an ERC row with a
    // named error carrying its id, never drops it. Every shipped deck states
    // ERC rows, so each is refused, naming a row whose kind is ERC.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (try deckFiles(arena.allocator())) |name| {
        var l = try load(name);
        defer l.deinit();
        var strings: geom.StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: check.deck.compile.Diag = .{};
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const got = check.deck.compile.compile(gpa, scratch.allocator(), l.text, try geom.Grid.init(1000), &strings, &diag);
        if (got) |cd| {
            var owned = cd;
            owned.deinit(gpa);
            return error.ErcRowsAccepted;
        } else |e| try testing.expectEqual(error.ErcRulesNotPorted, e);
        try testing.expect(check.erc.kinds.isKind(strings.resolve(diag.rule.kind)));
    }
}

test "every layer a rule names resolves in the layer table" {
    // Oracle: construct-from-answer. Every layer a rule names resolves back
    // to the same id through the layer table.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (try deckFiles(arena.allocator())) |name| {
        var l = try load(name);
        defer l.deinit();
        const layers = &l.deck.layers;
        for (l.deck.rules.spec) |spec| {
            var named: std.ArrayList(geom.LayerId) = .empty;
            defer named.deinit(gpa);
            try named.appendSlice(gpa, l.deck.rules.layersOf(spec));
            for (l.deck.rules.paramsOf(spec)) |p| switch (p.value) {
                .layer => |id| try named.append(gpa, id),
                else => {},
            };
            for (named.items) |layer| {
                try testing.expect(@backingInt(layer) < layers.len());
                const layer_name = l.strings.resolve(layers.names.items[@backingInt(layer)]);
                try testing.expectEqual(@as(?geom.LayerId, layer), layers.id(&l.strings, layer_name));
            }
        }
    }
}
