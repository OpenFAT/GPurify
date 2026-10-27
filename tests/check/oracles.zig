//! Every test states its oracle. A test is only as good as the independent
//! thing that says its expected value is right (AGENTS.md, Testing: "The oracle
//! is named before the code"), so every `test` block in src/ and tests/ names
//! it on a comment line starting `Oracle:`, either among the comments just
//! above it or inside its body. The scan reads the `.zig` files as text, so a
//! test added without one fails here, naming it. Ported from tests/oracles.rs
//! (which read the doc comment of each `#[test]`).

const std = @import("std");
const testing = std.testing;
const paths = @import("paths");
const Allocator = std.mem.Allocator;

// ---- private ----

/// The tests in `source` with no `Oracle:` comment line above them or in
/// their body, by name. A test is a line `test "name" {` or `test name {`
/// (an unnamed `test {` only references other files); its body runs to the
/// `}` at its own indent.
fn testsWithoutAnOracle(arena: Allocator, source: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    var missing: std.ArrayList([]const u8) = .empty;
    for (lines.items, 0..) |line, at| {
        const name = testName(line) orelse continue;
        const indent = line[0 .. line.len - std.mem.trimStart(u8, line, " ").len];
        var stated = false;
        var above = at;
        while (above > 0 and std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[above - 1], " "), "//")) {
            above -= 1;
            stated = stated or isOracle(lines.items[above]);
        }
        if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), "}")) {
            for (lines.items[at + 1 ..]) |body| {
                if (std.mem.startsWith(u8, body, indent) and std.mem.eql(u8, body[indent.len..], "}")) break;
                stated = stated or isOracle(body);
            }
        }
        if (!stated) try missing.append(arena, name);
    }
    return missing.items;
}

/// The name of the test `line` opens, or null.
fn testName(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, t, "test ")) return null;
    const rest = std.mem.trimStart(u8, t["test ".len..], " ");
    if (rest.len == 0 or rest[0] == '{') return null;
    if (rest[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        return rest[1..close];
    }
    const stop = std.mem.indexOfAny(u8, rest, " {") orelse return null;
    return rest[0..stop];
}

fn isOracle(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    const comment = if (std.mem.startsWith(u8, t, "///")) t[3..] else if (std.mem.startsWith(u8, t, "//")) t[2..] else return false;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, comment, " "), "Oracle:");
}

test "every test in the repository states its oracle" {
    // Oracle: the methodology's rule itself (AGENTS.md "give each new test
    // one"), read from the sources. Each failure names the file and the test to
    // give an `Oracle:` line.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tests: usize = 0;
    var missing: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "src", "tests" }) |top| {
        const root = try std.fmt.allocPrint(a, "{s}/{s}", .{ paths.root, top });
        var dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
        defer dir.close(testing.io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const text = try entry.dir.readFileAlloc(testing.io, entry.basename, a, .unlimited);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| tests += @intFromBool(testName(line) != null);
            for (try testsWithoutAnOracle(a, text)) |name| try missing.append(a, try std.fmt.allocPrint(a, "{s}/{s}: {s}", .{ top, entry.path, name }));
        }
    }
    // The scan reached the suites: there are over a thousand, so a handful
    // means it read the wrong directory.
    try testing.expect(tests > 1000);
    if (missing.items.len > 0) {
        std.debug.print("{d} tests state no `Oracle:` line:\n{s}\n", .{ missing.items.len, try std.mem.join(a, "\n", missing.items) });
        return error.TestExpectedEqual;
    }
}

test "the scan names each test without an oracle line" {
    // Oracle: construct-from-answer. A source with one test stating its
    // oracle above it, one inside its body, one in a doc comment, one
    // whose comment says "oracle" mid-sentence, one with none, and an
    // unnamed `test {`: the scan names exactly the middle two.
    const source =
        \\// Oracle: closed form.
        \\test "stated above" {
        \\    try f();
        \\}
        \\
        \\test "stated inside" {
        \\    // Oracle: law.
        \\}
        \\
        \\/// Oracle: a doc comment counts.
        \\test documented {}
        \\
        \\// Its oracle is mentioned, not stated.
        \\test "mentioned mid sentence" {}
        \\
        \\test "undocumented" {
        \\    try g();
        \\}
        \\
        \\test {
        \\    _ = @import("x.zig");
        \\}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try testsWithoutAnOracle(arena.allocator(), source);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("mentioned mid sentence", got[0]);
    try testing.expectEqualStrings("undocumented", got[1]);
}
