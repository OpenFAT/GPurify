//! The ten fuzz targets: every committed crasher and seed replayed through
//! its target's oracle at merge, and the same oracle under
//! `std.testing.fuzz` when built with `zig build test --fuzz=<N>` (nightly).
//! Ported from tests/fuzz_regressions.rs and fuzz/fuzz_targets/*.rs; the
//! oracles are fuzz_layout.zig's and fuzz_text.zig's (fuzz/oracles.rs).
//!
//! Every input is raw bytes, so a crasher replays identically here and
//! under the fuzzer: a fuzz input is one Smith slice, the oracle's bytes.
//! A crasher the fuzzer finds is minimised and committed as
//! `tests/fuzz/regressions/<target>/<name>`, where its target's test
//! replays it from then on. Under `--fuzz` every replayed input, prefixed
//! with its Smith slice length, seeds the fuzzer's corpus.
//!
//! Contents:
//! - `pub const Oracle`, `pub fn ensure(ok: bool, comptime fmt: []const u8, args: anytype) error{OracleBroken}!void`
//! - `pub const Bytes`, `Bytes.byte`, `Bytes.int`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const paths = @import("paths");
const layout = @import("fuzz_layout.zig");
const text = @import("fuzz_text.zig");
const gpa = testing.allocator;
const io = testing.io;

/// A fuzz target's oracle: any bytes in, an error (or a crash) only when
/// the code under test breaks the oracle's law.
pub const Oracle = *const fn (gpa: Allocator, data: []const u8) anyerror!void;

/// Raw fuzz bytes read front to back; past the end every read is zero, so
/// any input decodes. Integers are big-endian, as Rust's `Bytes`.
pub const Bytes = struct {
    rest: []const u8,

    /// The next byte, or 0.
    pub fn byte(b: *Bytes) u8 {
        if (b.rest.len == 0) return 0;
        defer b.rest = b.rest[1..];
        return b.rest[0];
    }

    /// The next `@sizeOf(T)` bytes, big-endian.
    pub fn int(b: *Bytes, comptime T: type) T {
        var raw: [@sizeOf(T)]u8 = undefined;
        for (&raw) |*r| r.* = b.byte();
        return std.mem.readInt(T, &raw, .big);
    }
};

/// The targets, as fuzz/Cargo.toml names them, with the directories of
/// seeds (under the repository root) each also replays.
const Target = struct { name: []const u8, oracle: Oracle, seeds: []const []const u8 };
const targets = [_]Target{
    .{ .name = "gds", .oracle = layout.gds, .seeds = &.{"tests/fixtures/_source"} },
    .{ .name = "gds_structured", .oracle = layout.gdsStructured, .seeds = &.{} },
    .{ .name = "deck", .oracle = text.deck, .seeds = &.{ "pdks", "tests/fuzz/seeds/deck" } },
    .{ .name = "netlist_spice", .oracle = text.netlistSpice, .seeds = &.{ "tests/fixtures/lvs_refs", "tests/fuzz/seeds/netlist_spice" } },
    .{ .name = "netlist_spectre", .oracle = text.netlistSpectre, .seeds = &.{"tests/fuzz/seeds/netlist_spectre"} },
    .{ .name = "intent", .oracle = text.intent, .seeds = &.{"tests/fuzz/seeds/intent"} },
    .{ .name = "liberty_spec", .oracle = text.libertySpec, .seeds = &.{"tests/fuzz/seeds/liberty_spec"} },
    .{ .name = "drc_e2e", .oracle = layout.drcE2e, .seeds = &.{} },
    .{ .name = "lefdef", .oracle = layout.lefdef, .seeds = &.{"tests/fuzz/seeds/lefdef"} },
    .{ .name = "spef", .oracle = text.spef, .seeds = &.{ "tests/fuzz/seeds/spef", "tests/golden/pex" } },
};

/// The largest input a fuzz run tries; every seed fits.
const max_input = 1 << 16;

const Input = struct {
    path: []const u8,
    bytes: []const u8,

    fn less(_: void, a: Input, b: Input) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// Fails the oracle, saying why, unless `ok`.
pub fn ensure(ok: bool, comptime fmt: []const u8, args: anytype) error{OracleBroken}!void {
    if (ok) return;
    std.debug.print("oracle: " ++ fmt ++ "\n", args);
    return error.OracleBroken;
}

// ---- private ----

/// Every file under `sub` (relative to the repository root), recursively,
/// sorted, as `path` and bytes in `arena`; none if it does not exist.
fn filesInto(arena: Allocator, sub: []const u8, out: *std.ArrayList(Input)) !void {
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    var dir = root.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    const first = out.items.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, entry.path });
        try out.append(arena, .{ .path = path, .bytes = try entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited) });
    }
    std.mem.sort(Input, out.items[first..], {}, Input.less);
}

/// Runs the target's oracle on every crasher and seed, failing with the
/// list of inputs that broke it; then hands the oracle to the fuzzer, the
/// same inputs as its corpus.
fn replayAndFuzz(comptime name: []const u8) !void {
    const t = comptime for (targets) |t| (if (std.mem.eql(u8, t.name, name)) break t) else unreachable;
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    var inputs: std.ArrayList(Input) = .empty;
    try filesInto(arena, "tests/fuzz/regressions/" ++ name, &inputs);
    for (t.seeds) |dir| {
        const before = inputs.items.len;
        try filesInto(arena, dir, &inputs);
        try ensure(inputs.items.len > before, "{s}: seed directory {s} is empty", .{ name, dir });
    }
    var broken: std.ArrayList([]const u8) = .empty;
    for (inputs.items) |in| t.oracle(gpa, in.bytes) catch |err| {
        try broken.append(arena, try std.fmt.allocPrint(arena, "{s}: {t}", .{ in.path, err }));
    };
    if (broken.items.len > 0) {
        std.debug.print("{s} fails on:\n{s}\n", .{ name, try std.mem.join(arena, "\n", broken.items) });
        return error.TestFuzzRegression;
    }
    // Replayed above; outside a fuzz build the fuzzer runs only the empty input.
    const corpus = try arena.alloc([]const u8, if (builtin.fuzz) inputs.items.len else 0);
    for (corpus, inputs.items[0..corpus.len]) |*c, in| {
        const bytes = try arena.alloc(u8, 4 + in.bytes.len);
        std.mem.writeInt(u32, bytes[0..4], @intCast(in.bytes.len), .little);
        @memcpy(bytes[4..], in.bytes);
        c.* = bytes;
    }
    try testing.fuzz(t.oracle, fuzzOne, .{ .corpus = corpus });
}

fn fuzzOne(oracle: Oracle, s: *testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    try oracle(testing.allocator, buf[0..s.slice(&buf)]);
}

test "every regression directory names a fuzz target" {
    // Oracle: fuzz/Cargo.toml's target names, copied into `targets`; a
    // directory naming none would be replayed by nothing.
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "tests/fuzz/regressions", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const known = for (targets) |t| (if (std.mem.eql(u8, t.name, entry.name)) break true) else false;
        try ensure(known, "tests/fuzz/regressions/{s} is not a fuzz target", .{entry.name});
    }
}

test "fuzz gds" {
    // Oracle: `layout.gds`: a typed error, never a crash; flattening within
    // budget; a layout that can be written back reads back to the same
    // store, holes and derived layers included (round trip).
    try replayAndFuzz("gds");
}

test "fuzz gds_structured" {
    // Oracle: `layout.gdsStructured`: the flat count and area computed from
    // the decoded structures, and the hierarchy errors the limits define.
    try replayAndFuzz("gds_structured");
}

test "fuzz deck" {
    // Oracle: `text.deck`: every diagnostic's span lies inside the input on
    // character boundaries; an accepted deck prints and compiles back to
    // itself, and every rule of it gets a run row.
    try replayAndFuzz("deck");
}

test "fuzz netlist_spice" {
    // Oracle: `text.netlistSpice`: a typed error, never a crash; device and
    // instance counts counted from the card text; the flattening counted
    // from the subcircuit tables.
    try replayAndFuzz("netlist_spice");
}

test "fuzz netlist_spectre" {
    // Oracle: `text.netlistSpectre`: a typed error, never a crash; device
    // and instance counts counted from the statements; the flattening
    // counted from the subcircuit tables.
    try replayAndFuzz("netlist_spectre");
}

test "fuzz intent" {
    // Oracle: `text.intent`: a typed error, never a crash or a leak.
    try replayAndFuzz("intent");
}

test "fuzz liberty_spec" {
    // Oracle: `text.libertySpec`: a typed error, never a crash or a leak.
    try replayAndFuzz("liberty_spec");
}

test "fuzz drc_e2e" {
    // Oracle: `layout.drcE2e`: the bitmap reference, written from each
    // rule's doc comment. The target has no seed directory, so its
    // regressions directory is the replay hook and must hold an input: a
    // `min_spacing` case (index 0x0001_0005) under symmetry 3, moved by
    // (0x1234_5678, -0x1000_0000).
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    var hook: std.ArrayList(Input) = .empty;
    try filesInto(state.allocator(), "tests/fuzz/regressions/drc_e2e", &hook);
    try ensure(hook.items.len > 0, "tests/fuzz/regressions/drc_e2e holds no input to replay", .{});
    try replayAndFuzz("drc_e2e");
}

test "fuzz lefdef" {
    // Oracle: `layout.lefdef`: a typed error, never a crash, and the GDSII
    // the reader writes round-trips through the GDS reader on the DEF's grid.
    try replayAndFuzz("lefdef");
}

test "fuzz spef" {
    // Oracle: `text.spef`: a typed error, never a crash; an accepted file is
    // a well-formed canonical network; seeded with every SPEF and DSPF
    // golden the writers produce.
    try replayAndFuzz("spef");
}

test "Bytes decodes big-endian and reads zero past the end" {
    // Oracle: hand-worked bytes: 0x01 0x02 is 258 big-endian; a read past
    // the end is zero, as Rust's `Bytes`.
    var b: Bytes = .{ .rest = &.{ 1, 2, 0xff } };
    try testing.expectEqual(@as(u16, 258), b.int(u16));
    try testing.expectEqual(@as(i16, -256), b.int(i16));
    try testing.expectEqual(@as(u8, 0), b.byte());
}
