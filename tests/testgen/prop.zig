//! Property runs: seeds derived from a name, committed regression seeds
//! replayed, and a failing input shrunk before it is reported. In: a
//! generator, a shrinker and a property. Out: nothing, or
//! `error.PropertyFailed` with the seed, the smallest failing input and its
//! failure printed. Ported from crates/testgen/src/prop.rs.
//!
//! The count is the caller's argument and a seed to replay is a line in a
//! file (`@embedFile`d by the suite): there are no environment knobs.
//!
//! Contents:
//! - `pub const Why = struct`, `Why.fail(why: *Why, comptime fmt: []const u8, args: anytype) error{PropertyFailed}`
//! - `pub const LayerRect = struct { layer: u16, box: [4]i64 }`
//! - `pub fn seeds(name: []const u8, out: []u64) void`
//! - `pub fn parseSeeds(gpa: Allocator, text: []const u8) Allocator.Error![]u64`
//! - `pub fn check(gpa: Allocator, comptime T: type, name: []const u8, count: u32, regressions: []const u64, comptime generate: anytype, comptime shrink: anytype, comptime property: anytype) error{ PropertyFailed, OutOfMemory }!void`
//! - `pub fn shrinkRects(arena: Allocator, rects: []const LayerRect) Allocator.Error![]const []const LayerRect`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rng = @import("rng.zig").Rng;

/// Where a property writes why it failed; `fail` returns the error to
/// propagate, so a property says `return why.fail("...", .{...});`.
pub const Why = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    pub fn fail(why: *Why, comptime fmt: []const u8, args: anytype) error{PropertyFailed} {
        why.len = if (std.fmt.bufPrint(&why.buf, fmt, args)) |text| text.len else |_| why.buf.len;
        return error.PropertyFailed;
    }
};

/// One rectangle `[xlo, ylo, xhi, yhi]` on a layer, the unit `shrinkRects`
/// shrinks.
pub const LayerRect = struct { layer: u16, box: [4]i64 };

/// `out.len` seeds for the property `name`: the same seeds on every run,
/// and different properties get different seeds.
pub fn seeds(name: []const u8, out: []u64) void {
    const base = fnv1a(name);
    for (out, 0..) |*s, i| s.* = base +% i;
}

/// The seeds in a regression file's text: one decimal seed per line, `#`
/// comments and blank lines ignored. Panics on a line that is not a `u64`:
/// a regression that silently stops replaying is worse than a failing test.
pub fn parseSeeds(gpa: Allocator, text: []const u8) Allocator.Error![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const body = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        if (body.len == 0) continue;
        const seed = std.fmt.parseInt(u64, body, 10) catch std.debug.panic("\"{s}\" is not a seed", .{body});
        try out.append(gpa, seed);
    }
    return out.toOwnedSlice(gpa);
}

/// Runs `property` on `generate`'s input from each of `count` named seeds,
/// then each regression seed. On the first failure the input is shrunk:
/// any candidate `shrink` proposes that still fails replaces it, until none
/// does. Each seed's inputs, candidates and property work live in one arena
/// over `gpa`.
///
/// - `generate: fn (arena: Allocator, rng: *Rng) Allocator.Error!T`
/// - `shrink: fn (arena: Allocator, input: T) Allocator.Error![]const T`,
///   every candidate strictly smaller, so shrinking ends
/// - `property: fn (arena: Allocator, input: T, why: *Why) anyerror!void`;
///   any error fails it, `why` saying why for `error.PropertyFailed`
pub fn check(
    gpa: Allocator,
    comptime T: type,
    name: []const u8,
    count: u32,
    regressions: []const u64,
    comptime generate: anytype,
    comptime shrink: anytype,
    comptime property: anytype,
) error{ PropertyFailed, OutOfMemory }!void {
    const base = fnv1a(name);
    for (0..count + regressions.len) |k| {
        const seed = if (k < count) base +% k else regressions[k - count];
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const failure = try runSeed(arena_state.allocator(), T, seed, generate, shrink, property) orelse continue;
        std.debug.print(
            "{s}: seed {d} fails: {s}\n  shrunk to {any}\n  which fails: {s}\n" ++
                "  add {d} to the property's regression seeds to replay it on every run\n",
            .{ name, seed, failure.first, failure.smallest, failure.last, seed },
        );
        return error.PropertyFailed;
    }
}

/// Smaller layouts of labelled rectangles: each with one rectangle dropped,
/// then each with one halved toward its lower-left corner, then each with
/// one moved halfway toward the origin. Every candidate is strictly smaller
/// in count, area or coordinate magnitude.
pub fn shrinkRects(arena: Allocator, rects: []const LayerRect) Allocator.Error![]const []const LayerRect {
    var out: std.ArrayList([]const LayerRect) = .empty;
    for (0..rects.len) |skip| {
        const fewer = try arena.alloc(LayerRect, rects.len - 1);
        @memcpy(fewer[0..skip], rects[0..skip]);
        @memcpy(fewer[skip..], rects[skip + 1 ..]);
        try out.append(arena, fewer);
    }
    for (rects, 0..) |r, i| {
        const xlo, const ylo, const xhi, const yhi = r.box;
        const w, const h = .{ xhi - xlo, yhi - ylo };
        if (w > 1 or h > 1) {
            const halved = try arena.dupe(LayerRect, rects);
            halved[i].box = .{ xlo, ylo, xlo + @max(@divTrunc(w, 2), 1), ylo + @max(@divTrunc(h, 2), 1) };
            try out.append(arena, halved);
        }
        const dx, const dy = .{ @divTrunc(xlo, 2), @divTrunc(ylo, 2) };
        if (dx != 0 or dy != 0) {
            const moved = try arena.dupe(LayerRect, rects);
            moved[i].box = .{ xlo - dx, ylo - dy, xhi - dx, yhi - dy };
            try out.append(arena, moved);
        }
    }
    return out.items;
}

// ---- private ----

fn Failure(comptime T: type) type {
    return struct { first: []const u8, smallest: T, last: []const u8 };
}

/// FNV-1a of the name, so seeds depend on the property and nothing else.
fn fnv1a(name: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (name) |byte| hash = (hash ^ byte) *% 0x0000_0100_0000_01b3;
    return hash;
}

/// One seed: null when the property holds, else the shrunk failure.
/// Bounded: every accepted candidate is strictly smaller by the shrinker's
/// contract, and the round count is capped for one that breaks it.
fn runSeed(arena: Allocator, comptime T: type, seed: u64, comptime generate: anytype, comptime shrink: anytype, comptime property: anytype) Allocator.Error!?Failure(T) {
    var rng = Rng.init(seed);
    var input: T = try generate(arena, &rng);
    const first = try failureOf(arena, T, input, property) orelse return null;
    var last = first;
    rounds: for (0..10_000) |_| {
        for (try shrink(arena, input)) |candidate| {
            if (try failureOf(arena, T, candidate, property)) |why| {
                input = candidate;
                last = why;
                continue :rounds;
            }
        }
        break;
    }
    return .{ .first = first, .smallest = input, .last = last };
}

/// Why `property` fails on `input`, copied into the arena; null if it holds.
fn failureOf(arena: Allocator, comptime T: type, input: T, comptime property: anytype) Allocator.Error!?[]const u8 {
    var why: Why = .{};
    property(arena, input, &why) catch |err| {
        if (err == error.PropertyFailed) return try arena.dupe(u8, why.buf[0..why.len]);
        return @errorName(err);
    };
    return null;
}

fn wideFixture(_: Allocator, _: *Rng) Allocator.Error![]const LayerRect {
    return &.{ .{ .layer = 0, .box = .{ 0, 0, 5, 5 } }, .{ .layer = 1, .box = .{ 100, 100, 180, 140 } } };
}

fn noWiderThanTen(_: Allocator, rects: []const LayerRect, why: *Why) anyerror!void {
    for (rects) |r| if (r.box[2] - r.box[0] > 10) return why.fail("too wide", .{});
}

test "a failure shrinks to its smallest cause" {
    // Oracle: a property that fails for any layout with a rectangle wider
    // than 10 shrinks to one rectangle, of the smallest failing width.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const failure = (try runSeed(arena_state.allocator(), []const LayerRect, 7, wideFixture, shrinkRects, noWiderThanTen)).?;
    try std.testing.expectEqualStrings("too wide", failure.first);
    // One rectangle left, the wide one: halving and moving reach a width in
    // 11..=20 and the shrinker stops there.
    try std.testing.expectEqual(@as(usize, 1), failure.smallest.len);
    try std.testing.expectEqual(@as(u16, 1), failure.smallest[0].layer);
    const w = failure.smallest[0].box[2] - failure.smallest[0].box[0];
    try std.testing.expect(w >= 11 and w <= 20);
}

test "seeds depend on the name alone" {
    // Oracle: law. `seeds` is documented as a function of the name: one name
    // gives one stream, two names two, of the length asked for.
    var a: [3]u64 = undefined;
    var again: [3]u64 = undefined;
    var b: [3]u64 = undefined;
    seeds("a", &a);
    seeds("a", &again);
    seeds("b", &b);
    try std.testing.expectEqualSlices(u64, &a, &again);
    try std.testing.expect(!std.mem.eql(u64, &a, &b));
}

test "regression seeds parse past comments and blank lines" {
    // Oracle: construct-from-answer: the file format in `parseSeeds`'s doc,
    // two seeds written around a comment line, a trailing comment and a
    // blank line.
    const got = try parseSeeds(std.testing.allocator, "# header\n\n12 # why\n18446744073709551615\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u64, &.{ 12, std.math.maxInt(u64) }, got);
}
