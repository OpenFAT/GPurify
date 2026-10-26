//! Flow features of the deck (FLOW-*): a staged run, and waivers, as
//! exhaustive fixtures, and a waiver drawn in a cell. Ported from
//! tests/exhaustive/flow.rs.
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const gpa = testing.allocator;
const io = testing.io;

/// The translations a fixture here is repeated at, beside every symmetry.
const offsets = [_][2]i64{ .{ 0, 0 }, .{ -1_234_567, 987_654 } };

/// One case: a name under `flow/`, its deck and layout, and its claims.
const Case = struct { name: []const u8, deck: []const u8, layout: Layout, expects: []const Expect };

/// Per rule `w`: its rows in `violations` and `waived`, its run row's
/// count, and whether the run passed, with or without the `waive` line.
const Counts = struct { violations: usize, waived: usize, reported: ?u32, passed: bool };

/// FLOW-002: a staged deck checks its stages in order and, once a stage
/// finds an error, reports every later stage's rules skipped with nothing
/// found (the early, dirty-design run of Calibre `nmDRC-Recon` and IC
/// Validator Explorer). Oracle: hand-derived (one 50 nm width finding, one
/// 150 nm gap finding), and laws: the same deck unstaged reports both, and a
/// clean first stage lets the second run as it would unstaged; every case
/// under every symmetry and an offset. Fails if a later stage runs after a
/// dirty one, is reported clean or ran, or a clean stage holds the next back.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try stagedInto(arena, out);
    try waiversInto(arena, out);
}

// ---- private ----

/// A `met1` deck with a 100 nm minimum width `w` and a 200 nm minimum
/// spacing `s`; staged, `w` is the stage `gross` and `s` the stage `fine`.
fn deck(staged: bool) []const u8 {
    return if (staged)
        "grid 1nm\nlayer met1 = gds(68, 20)\nstage gross\nrule w width(met1) >= 100nm\nstage fine\nrule s space(met1) >= 200nm\n"
    else
        "grid 1nm\nlayer met1 = gds(68, 20)\nrule w width(met1) >= 100nm\nrule s space(met1) >= 200nm\n";
}

/// A 50 nm wide bar, too narrow for `w`, when `narrow`; and two 1 um bars
/// 150 nm apart, too close for `s`, far from it.
fn layout(arena: Allocator, narrow: bool) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 5_000, 2_000, 6_000);
    try l.rect(arena, "met1", 0, 6_150, 2_000, 7_150);
    if (narrow) try l.rect(arena, "met1", 0, 0, 2_000, 50);
    return l;
}

fn stagedInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const width = Expect.rule("w", &.{.length(50)});
    const space = Expect.rule("s", &.{.length(150)});
    const cases = [_]Case{
        .{ .name = "staged/dirty_first_stage", .deck = deck(true), .layout = try layout(arena, true), .expects = &.{ width, .outcome("s", .skipped) } },
        .{ .name = "staged/clean_first_stage", .deck = deck(true), .layout = try layout(arena, false), .expects = &.{ .clean("w"), space } },
        .{ .name = "unstaged/both", .deck = deck(false), .layout = try layout(arena, true), .expects = &.{ width, space } },
    };
    for (cases) |c| {
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "flow/{s}", .{c.name}), &.{"FLOW-002"}, c.deck, harness.drc);
        f.layout = c.layout;
        try f.claim(arena, .{ .passes = false });
        for (c.expects) |e| try f.claim(arena, e);
        for (offsets) |o| try f.everySymmetryInto(arena, o[0], o[1], out);
    }
}

/// A `met1` deck with a 100 nm minimum width `w`, a 200 nm minimum spacing
/// `s`, and a `waiver` layer that waives `rule`.
fn waiverDeck(comptime rule: []const u8) []const u8 {
    return "grid 1nm\nlayer met1 = gds(68, 20)\nlayer waiver = gds(255, 0)\nrule w width(met1) >= 100nm\nrule s space(met1) >= 200nm\nwaive " ++ rule ++ " waiver\n";
}

/// A 50 nm bar at `y`, with a waiver over `y = over` when `over` is set.
fn bar(arena: Allocator, y: i64, over: i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, y, 2_000, y + 50);
    try l.rect(arena, "waiver", -100, over - 100, 2_100, over + 150);
    return l;
}

/// FLOW-001: a waiver is a shape on the deck's waiver layer for a rule; a
/// violation of that rule whose marker lies on it is waived, reported
/// apart and not counted against the run (Calibre Auto-Waivers keeps its
/// waivers on "a specific geometry layer"). Oracle: hand-derived, a 50 nm
/// bar's one width finding at its middle; under every symmetry and an
/// offset. A waiver over it clears the rule and the run passes; one beside
/// it waives nothing; one for another rule waives nothing; with two narrow
/// bars, one waived, one finding stays. Fails if a waiver is ignored, waives
/// past its shape, or waives another rule's finding.
fn waiversInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const width = Expect.rule("w", &.{.length(50)});
    var two = try bar(arena, 0, 0);
    try two.rect(arena, "met1", 0, 3_000, 2_000, 3_050);
    const cases = [_]Case{
        .{ .name = "waiver/covered", .deck = waiverDeck("w"), .layout = try bar(arena, 0, 0), .expects = &.{ .clean("w"), .{ .passes = true } } },
        .{ .name = "waiver/beside", .deck = waiverDeck("w"), .layout = try bar(arena, 0, 1_000), .expects = &.{ width, .{ .passes = false } } },
        .{ .name = "waiver/another_rule", .deck = waiverDeck("s"), .layout = try bar(arena, 0, 0), .expects = &.{ width, .{ .passes = false } } },
        .{ .name = "waiver/one_of_two", .deck = waiverDeck("w"), .layout = two, .expects = &.{ width, .{ .passes = false } } },
    };
    for (cases) |c| {
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "flow/{s}", .{c.name}), &.{"FLOW-001"}, c.deck, harness.drc);
        f.layout = c.layout;
        for (c.expects) |e| try f.claim(arena, e);
        for (offsets) |o| try f.everySymmetryInto(arena, o[0], o[1], out);
    }
}

fn counts(arena: Allocator, dir: std.Io.Dir, waive: bool) !Counts {
    const text = if (waive) waiverDeck("w") else "grid 1nm\nlayer met1 = gds(68, 20)\nlayer waiver = gds(255, 0)\nrule w width(met1) >= 100nm\nrule s space(met1) >= 200nm\n";
    try dir.writeFile(io, .{ .sub_path = "waive.deck", .data = text });
    var diag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, arena, io, dir, .{ .layout = "waived.gds", .deck = "waive.deck" }, .{ .checks = harness.drc }, &.{}, &diag);
    const w = r.loaded.strings.get("w").?;
    var reported: ?u32 = null;
    for (r.outputs.runs.items) |row| if (row.rule == w) {
        reported = row.violations;
        break;
    };
    return .{
        .violations = std.mem.count(@TypeOf(w), r.outputs.violations.rule.items, &.{w}),
        .waived = std.mem.count(@TypeOf(w), r.outputs.waived.rule.items, &.{w}),
        .reported = reported,
        .passed = r.summary.passed(),
    };
}

test "every flow fixture holds" {
    // Oracle: each fixture's expected answer, hand-derived from the rule's
    // definition (FLOW-001, FLOW-002 above), under every symmetry and an
    // offset.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}

test "a waiver drawn in a cell waives at every placement" {
    // FLOW-001: a waiver drawn in a cell waives at every placement of it,
    // the hierarchy-invariant waiver of Calibre Auto-Waivers. A cell `IP`
    // holds a 50 nm `met1` bar and a waiver over it; `TOP` places it plainly
    // and mirrored and turned a quarter, and has a narrow bar of its own
    // with no waiver.
    // Oracle: hand-derived through the real reader and engine: of three
    // width findings, the two inside `IP` are waived (each placement's
    // waiver moved with it) and `TOP`'s stays, so the run fails on one; and
    // a law: without the `waive` line all three are reported and none waived.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cells = [_]testgen.gds.Structure{
        .{ .name = "IP", .rects = &.{ .{ 68, 20, .{ 0, 0, 2_000, 50 } }, .{ 255, 0, .{ -100, -100, 2_100, 150 } } } },
        .{ .name = "TOP", .rects = &.{.{ 68, 20, .{ 0, 10_000, 2_000, 10_050 } }}, .refs = &.{ .{ .cell = "IP" }, .{ .cell = "IP", .reflect = true, .quarter_turns = 1, .at = .{ 20_000, 0 } } } },
    };
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeLibrary(a, &cells, &bytes);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "waived.gds", .data = bytes.items });
    try testing.expectEqual(Counts{ .violations = 1, .waived = 2, .reported = 1, .passed = false }, try counts(a, tmp.dir, true));
    try testing.expectEqual(Counts{ .violations = 3, .waived = 0, .reported = 3, .passed = false }, try counts(a, tmp.dir, false));
}
