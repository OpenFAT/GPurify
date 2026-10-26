//! The numbers the docs state, recomputed from the code, the catalog, the
//! shipped decks and the corpus. A count written in prose is an output like
//! any other and goes stale, so each test builds the exact sentence or table
//! row the doc must hold. Ported from tests/doc_counts.rs; its README
//! accuracy section (`the_readme_accuracy_section_is_the_corpus`) is not
//! ported: the rewrite's README is short and states no corpus bars.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const paths = @import("paths");
const deck_common = @import("deck/common.zig");
const Allocator = std.mem.Allocator;

const domains = [_][]const u8{ "drc", "erc", "lvs", "pex" };

/// The `corroboration` values, in the fixtures README's column order.
const corroboration = [_][]const u8{ "manifest_agrees", "manifest_count_only", "manifest_disagrees", "manifest_partial", "manifest_uncheckable", "none" };

/// The cases of one domain, and of all.
const Corpus = struct { by_domain: [domains.len][]const std.json.Value, all: []const std.json.Value };

// ---- private ----

fn read(arena: Allocator, rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.root, rel });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
}

/// Every unsigned integer written in `text`, in order.
fn numbers(arena: Allocator, text: []const u8) ![]const u64 {
    var out: std.ArrayList(u64) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        while (at < text.len and !std.ascii.isDigit(text[at])) at += 1;
        const start = at;
        while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        if (at > start) try out.append(arena, try std.fmt.parseInt(u64, text[start..at], 10));
    }
    return out.items;
}

/// The one line of `doc` starting with `prefix`.
fn line(doc: []const u8, name: []const u8, prefix: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, prefix)) {
        if (found != null) {
            std.debug.print("{s}: more than one line starts with \"{s}\"\n", .{ name, prefix });
            return error.TestUnexpectedResult;
        }
        found = l;
    };
    return found orelse {
        std.debug.print("{s}: no line starts with \"{s}\"\n", .{ name, prefix });
        return error.TestUnexpectedResult;
    };
}

fn lastNumber(arena: Allocator, doc: []const u8, name: []const u8, prefix: []const u8) !u64 {
    const n = try numbers(arena, try line(doc, name, prefix));
    if (n.len == 0) return error.TestUnexpectedResult;
    return n[n.len - 1];
}

fn expectSays(doc: []const u8, name: []const u8, sentence: []const u8) !void {
    if (std.mem.indexOf(u8, doc, sentence) != null) return;
    std.debug.print("{s} should say: \"{s}\"\n", .{ name, sentence });
    return error.TestExpectedEqual;
}

/// How many `cases` have `field` equal to `value`.
fn count(cases: []const std.json.Value, field: []const u8, value: []const u8) u64 {
    var n: u64 = 0;
    for (cases) |c| if (c.object.get(field)) |v| {
        n += @intFromBool(v == .string and std.mem.eql(u8, v.string, value));
    };
    return n;
}

/// Every distinct string `field` takes, sorted.
fn valuesOf(arena: Allocator, cases: []const std.json.Value, field: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cases) |c| if (c.object.get(field)) |v| if (v == .string) {
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, v.string)) break;
        } else try out.append(arena, v.string);
    };
    std.mem.sortUnstable([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.items;
}

fn corpus(arena: Allocator) !Corpus {
    const json = try std.json.parseFromSliceLeaky(std.json.Value, arena, try read(arena, "tests/fixtures/expectations.json"), .{});
    var c: Corpus = undefined;
    var all: std.ArrayList(std.json.Value) = .empty;
    for (domains, &c.by_domain) |d, *cases| {
        cases.* = json.object.get(d).?.object.get("cases").?.array.items;
        try all.appendSlice(arena, cases.*);
    }
    c.all = all.items;
    return c;
}

/// The fixtures README's row for `cases`: the count, then one per
/// corroboration value.
fn corroborationRow(arena: Allocator, cases: []const std.json.Value) ![]const u64 {
    var out: std.ArrayList(u64) = .empty;
    try out.append(arena, cases.len);
    for (corroboration) |v| try out.append(arena, count(cases, "corroboration", v));
    return out.items;
}

test "the readme status table is the catalog" {
    // Oracle: docs/check-catalog.tsv itself: each domain's rows counted by
    // status, which README's status table must state.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const readme = try read(a, "README.md");
    const catalog = try read(a, "docs/check-catalog.tsv");
    for ([_][2][]const u8{ .{ "DRC", "DRC-" }, .{ "LVS", "LVS-" }, .{ "ERC", "ERC-" }, .{ "PEX", "PEX-" }, .{ "Flow", "FLOW-" } }) |d| {
        var want: [4]u64 = @splat(0);
        var rows = std.mem.splitScalar(u8, catalog, '\n');
        _ = rows.next();
        while (rows.next()) |r| {
            if (!std.mem.startsWith(u8, r, d[1])) continue;
            var cells = std.mem.splitScalar(u8, r, '\t');
            for (0..6) |_| _ = cells.next();
            const status = cells.next() orelse continue;
            for ([_][]const u8{ "implemented", "expressible", "partial", "missing" }, &want) |s, *n| n.* += @intFromBool(std.mem.eql(u8, status, s));
        }
        const prefix = try std.fmt.allocPrint(a, "| {s} |", .{d[0]});
        try testing.expectEqualSlices(u64, &want, try numbers(a, try line(readme, "README.md", prefix)));
    }
}

test "the readme counts the rule kinds the code has" {
    // Oracle: the code's own kind tables, drc.Kind and erc.kinds, counted
    // into the sentence README must hold.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sentence = try std.fmt.allocPrint(a, "There are {d} design-rule kinds and {d} electrical-rule kinds.", .{ check.drc.kinds.count, check.erc.kinds.count });
    try expectSays(try read(a, "README.md"), "README.md", sentence);
}

test "the readme deck table is the shipped decks" {
    // Oracle: the decks as the parser reads them: how many ship, and per
    // deck its drawn layers, rules (each `for` iteration a rule) and device
    // recognisers.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const readme = try read(a, "README.md");
    const words = [_][]const u8{ "No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" };
    try expectSays(readme, "README.md", try std.fmt.allocPrint(a, "{s} decks ship in `pdks/`", .{words[deck_common.shipped.len]}));
    for (deck_common.shipped) |name| {
        var c = try deck_common.compileText(try deck_common.shippedText(a, name), 1000);
        defer c.deinit();
        const layers = &c.cd.deck.layers;
        var drawn: u64 = 0;
        for (0..layers.len()) |id| drawn += @intFromBool(!layers.isDerived(@as(geom.LayerId, @fromBackingInt(@intCast(id)))));
        const want = [3]u64{ drawn, c.cd.deck.rules.spec.len, c.cd.deck.devices.kind.len };
        const row = try numbers(a, try line(readme, "README.md", try std.fmt.allocPrint(a, "| `{s}`", .{name})));
        try testing.expectEqualSlices(u64, &want, row[row.len - 3 ..]);
    }
}

test "the fixtures readme is the corpus" {
    // Oracle: the cases in tests/fixtures/expectations.json, counted per
    // domain, strength, corroboration, dispute and the outcome and examined
    // guard, against the fixtures README's table and sentences.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = "tests/fixtures/README.md";
    const doc = try read(a, name);
    const c = try corpus(a);
    var sizes: [domains.len][]const u8 = undefined;
    for (&sizes, c.by_domain) |*s, cases| s.* = try std.fmt.allocPrint(a, "{d}", .{cases.len});
    try expectSays(doc, name, try std.fmt.allocPrint(a, "{s} single-case extracts", .{try std.mem.join(a, " + ", &sizes)}));
    for (try valuesOf(a, c.all, "strength")) |s| {
        try testing.expectEqual(count(c.all, "strength", s), try lastNumber(a, doc, name, try std.fmt.allocPrint(a, "| `{s}` |", .{s})));
    }
    // A new corroboration value needs a new column before it can be counted.
    for (try valuesOf(a, c.all, "corroboration")) |v| {
        for (corroboration) |known| {
            if (std.mem.eql(u8, known, v)) break;
        } else return error.TestUnexpectedResult;
    }
    for (domains, c.by_domain) |d, cases| {
        const text = try line(doc, name, try std.fmt.allocPrint(a, "| {s} |", .{d}));
        try testing.expectEqualSlices(u64, try corroborationRow(a, cases), try numbers(a, text));
    }
    try testing.expectEqualSlices(u64, try corroborationRow(a, c.all), try numbers(a, try line(doc, name, "| **total** | **")));
    for (try valuesOf(a, c.all, "dispute")) |d| {
        try testing.expectEqual(count(c.all, "dispute", d), try lastNumber(a, doc, name, try std.fmt.allocPrint(a, "| `{s}` |", .{d})));
    }
    // The no-vacuous-pass guard: a case without both can pass on a check
    // that ran over nothing.
    var guarded: usize = 0;
    var disputed: u64 = 0;
    for (c.all) |case| {
        const o = case.object;
        const outcome = o.get("expect_outcome") orelse std.json.Value.null;
        const examined = o.get("examined_min") orelse std.json.Value.null;
        guarded += @intFromBool(outcome != .null and examined != .null);
        if (o.get("dispute")) |v| disputed += @intFromBool(v == .string);
    }
    try expectSays(doc, name, try std.fmt.allocPrint(a, "{d} of {d} cases carry `expect_outcome` and `examined_min`", .{ guarded, c.all.len }));
    try testing.expectEqual(disputed, try lastNumber(a, doc, name, "| **total** | |"));
}
