//! The `matching` statement (docs/deck.md, Matching): each mismatch unit
//! read into SI, the refusals with their lines, and the shipped decks'
//! citations. New in the rewrite (UW-ASIC/GPurify#84); no Rust original.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const paths = @import("paths");
const deck = ingest.deck;
const fx = @import("deck_fixture.zig");
const gpa = testing.allocator;

/// A MOS, a resistor and a bipolar model on the fixture's layers.
const devices =
    \\layer gate = poly and diff
    \\device mos gate model "nfet" terminals [poly, diff, diff]
    \\device resistor li model "rpoly" terminals [li, li]
    \\device bjt met3 model "pnp" terminals [met1, met2, met3]
    \\
;

const shipped = [_][]const u8{ "generic_finfet", "gf180mcu", "ihp_sg13g2", "sky130" };

// ---- private ----

fn withDevices(body: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ devices, body });
}

fn refused(body: []const u8, needle: []const u8) !void {
    const text = try withDevices(body);
    defer gpa.free(text);
    try fx.oneError(text, needle);
}

fn malformed(body: []const u8, needle: []const u8) !void {
    const text = try withDevices(body);
    defer gpa.free(text);
    try fx.malformed(text, needle);
}

/// The source tags a deck's header defines: `[S1]`, `[PS]`, each the
/// first word of a comment line before the first statement.
fn headerTags(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] != '#') break;
        const body = std.mem.trimStart(u8, std.mem.trimStart(u8, line, "#"), " ");
        if (body.len > 0 and body[0] == '[') if (std.mem.indexOfScalar(u8, body, ']')) |close| try tags.append(arena, body[0 .. close + 1]);
    }
    return tags.items;
}

test "each mismatch unit reads into SI, 5 mV·um as 5e-9 V·m" {
    // Oracle: the units' definitions, by hand: 1 mV·µm = 1e-3 V · 1e-6 m =
    // 1e-9 V·m, 1 %·µm = 1e-2 · 1e-6 m = 1e-8 m, 1 µV/µm = 1 V/m; `.` is
    // `·`. Each read is the f64 nearest the decimal, as the literal is.
    var o = try fx.ok(devices ++
        \\device mos gate model "pfet" terminals [poly, diff, diff]
        \\matching "nfet" pair avt 5mV·um abeta 1.5%·um svt 0.3uV/um
        \\matching "pfet" single avt 2.2mV.um
        \\matching "rpoly" pair ar 1.2%.um
        \\matching "pnp" pair ka 0.4%·um
        \\
    );
    defer o.deinit();
    const rows = o.d().matching;
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual(o.id("nfet"), rows[0].model);
    try testing.expectEqual(deck.MatchingBasis.pair, rows[0].basis);
    try testing.expectEqual(deck.Matching{ .avt = 5e-9, .abeta = 1.5e-8, .svt = 0.3 }, rows[0].stated);
    try testing.expectEqual(deck.MatchingBasis.single, rows[1].basis);
    try testing.expectEqual(deck.Matching{ .avt = 2.2e-9 }, rows[1].stated);
    try testing.expectEqual(deck.Matching{ .ar = 1.2e-8 }, rows[2].stated);
    try testing.expectEqual(deck.Matching{ .ka = 4e-9 }, rows[3].stated);
    try testing.expectEqual(o.id("pnp"), rows[3].model);
}

test "a second statement for one device is refused, naming both lines" {
    // Oracle: docs/deck.md, Matching: one statement per model. The lines are
    // counted by hand: the first statement is line 6, the second line 7.
    const text =
        \\grid 5nm
        \\layer poly = gds(66, 20)
        \\layer diff = gds(65, 20)
        \\layer gate = poly and diff
        \\device mos gate model "nfet" terminals [poly, diff, diff]
        \\matching "nfet" pair avt 5mV·um
        \\matching "nfet" pair abeta 1%·um
        \\
    ;
    var o = try fx.runText(text);
    defer o.deinit();
    const found = try fx.errors(&o);
    try testing.expectEqual(@as(usize, 1), found.len);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try deck.render(&out.writer, "d.deck", found);
    try testing.expectEqualStrings(
        \\d.deck:7:10: matching "nfet" is already stated on line 6
        \\matching "nfet" pair abeta 1%·um
        \\         ^^^^^^
    , out.written());
}

test "an unknown unit or a unit of another kind is refused" {
    // Oracle: docs/deck.md, Basics: avt takes mV·um, abeta, ar and ka %·um,
    // svt uV/um; any other unit, or none, is an error at the value.
    try refused("matching \"nfet\" pair avt 5mV·nm\n", "unknown unit `mV·nm`");
    try refused("matching \"nfet\" pair avt 5%·um\n", "avt needs a voltage times a length, got 5%·um (a fraction times a length)");
    try refused("matching \"rpoly\" pair ar 2uV/um\n", "ar needs a fraction times a length, got 2uV/um (a voltage per length)");
    try refused("matching \"nfet\" pair svt 2mV·um\n", "svt needs a voltage per length");
    try refused("matching \"nfet\" pair avt 5\n", "avt needs a voltage times a length, got 5 (no unit)");
}

test "a value no process has, an unknown key or basis, or no value is refused" {
    // Oracle: docs/deck.md, Matching: each key at most once, every value
    // positive, `pair` or `single`, the model in quotes, at least one key.
    try refused("matching \"nfet\" pair avt 0mV·um\n", "avt must be positive");
    try refused("matching \"nfet\" pair avt -5mV·um\n", "avt must be positive");
    try refused("matching \"nfet\" pair avt2 5mV·um\n", "unknown matching key `avt2`; expected avt, abeta, ar, svt or ka");
    try refused("matching \"nfet\" pair avt 5mV·um avt 6mV·um\n", "`avt` is given twice");
    try refused("matching \"nfet\" pair\n", "matching \"nfet\" states nothing; expected avt, abeta, ar, svt or ka");
    try refused("matching \"nfet\" both avt 5mV·um\n", "unknown basis `both`; expected pair or single");
    try refused("matching nfet pair avt 5mV·um\n", "expected a model name in quotes, found `nfet`");
}

test "a model no device of the coefficient's kind declares is refused" {
    // Oracle: docs/deck.md, Matching: avt, abeta and svt are a mos model's,
    // ar a resistor's, ka a bipolar's, and the model is a `device`'s.
    try malformed("matching \"pfet\" pair avt 5mV·um\n", "matching \"pfet\": avt needs a `device mos` statement with that model");
    try malformed("matching \"nfet\" pair ar 1%·um\n", "matching \"nfet\": ar needs a `device resistor` statement with that model");
    try malformed("matching \"rpoly\" pair ka 1%·um\n", "matching \"rpoly\": ka needs a `device bjt` statement with that model");
}

test "every shipped matching line cites a source its deck names" {
    // Oracle: docs/deck.md, Matching: a shipped value states its source on
    // its own line, as a tag the deck's header defines ([PS], [S12]).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (shipped) |name| {
        const path = try std.fmt.allocPrint(a, "{s}/pdks/{s}.deck", .{ paths.root, name });
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
        const tags = try headerTags(a, text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var at: usize = 0;
        while (lines.next()) |line| {
            at += 1;
            if (!std.mem.startsWith(u8, line, "matching ")) continue;
            const comment = line[(std.mem.indexOfScalar(u8, line, '#') orelse line.len)..];
            var cited: usize = 0;
            var rest = comment;
            while (std.mem.indexOfScalar(u8, rest, '[')) |open| {
                const close = std.mem.indexOfScalarPos(u8, rest, open, ']') orelse break;
                const tag = rest[open .. close + 1];
                rest = rest[close + 1 ..];
                for (tags) |t| {
                    if (std.mem.eql(u8, t, tag)) break;
                } else continue;
                cited += 1;
            }
            if (cited == 0) {
                std.debug.print("{s}.deck:{d}: no source its header names: {s}\n", .{ name, at, line });
                return error.TestUnexpectedResult;
            }
        }
    }
}
