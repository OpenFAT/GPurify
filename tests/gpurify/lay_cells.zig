//! Cell-name selections (`in_cells`, `not_in_cells`) as exhaustive
//! fixtures over a GDSII hierarchy, a placed cell's round trip through the
//! writer and reader, and renaming a cell. Ported from
//! tests/exhaustive/drc_overlay.rs (`cell_tree`, `cell_selections`,
//! `a_placed_cell_lands_where_its_symmetry_maps_it`,
//! `renaming_a_cell_changes_only_what_its_name_selects`, and the
//! derived-layer section's `derived`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Symmetry = harness.Symmetry;
const c = @import("drc_common.zig");

/// A derived layer and the shapes `forbidden` must report on it.
const Derived = struct { []const u8, []const Finding };

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try cellSelectionsInto(arena, out);
}

// ---- private ----

/// A layout of one rectangle on `layer`.
fn box(arena: Allocator, layer: []const u8, r: c.Rect) !Layout {
    var l: Layout = .{};
    try l.rect(arena, layer, r[0], r[1], r[2], r[3]);
    return l;
}

/// A hierarchy for the cell-name selections: `TOP` holds a 100 × 50 bar and
/// places `PAD_1` (turned 90°), `core` (mirrored) and `INNER` (turned 180°);
/// `PAD_1` holds a 300 × 100 bar and places `INNER`, a 100 × 100 square;
/// `core` holds a 200 × 200 square. No two placed shapes touch.
fn cellTree(arena: Allocator, core: []const u8) !Layout {
    var l = try box(arena, "a", .{ -5000, -5000, -4900, -4950 });
    try l.place(arena, "PAD_1", .{ .turns = 1, .mirror = false }, 0, 0);
    try l.place(arena, core, .{ .turns = 0, .mirror = true }, 0, 5000);
    try l.place(arena, "INNER", .{ .turns = 2, .mirror = false }, 5000, 0);
    var pad = try box(arena, "a", .{ 0, 0, 300, 100 });
    try pad.place(arena, "INNER", .identity, 1000, 0);
    try l.cell(arena, "PAD_1", pad);
    try l.cell(arena, core, try box(arena, "a", .{ 0, 0, 200, 200 }));
    try l.cell(arena, "INNER", try box(arena, "a", .{ 0, 0, 100, 100 }));
    return l;
}

/// One fixture per derived layer: each expression `d<i>` checked by
/// `forbidden`, rule `f<i>`, which reports each resulting shape with its
/// area (holes excluded).
fn derived(arena: Allocator, name: []const u8, catalog: []const []const u8, layers: []const []const u8, exprs: []const Derived, layout: Layout) !Fixture {
    const ids = [_][]const u8{ "f0", "f1", "f2", "f3" };
    var body: std.ArrayList(u8) = .empty;
    const rows = try arena.alloc(c.Row, exprs.len);
    for (exprs, rows, 0..) |e, *r, i| {
        try body.print(arena, "layer d{d} = {s}\nrule f{d} forbidden(d{d})\n", .{ i, e[0], i, i });
        r.* = .{ ids[i], e[1] };
    }
    return c.fixture(arena, name, catalog, try c.newDeck(arena, layers, body.items), layout, rows);
}

/// Cell-name selections (DRC-092): `in_cells` keeps the shapes placed under
/// a matching cell, nested ones included (`INNER` under `PAD_1`), and
/// `not_in_cells` the rest (`INNER` placed by `TOP`); several patterns are
/// a union, the root's own name counts, and the glob is case-sensitive.
/// Then the rules the selections state: a width exempted inside `PAD*`
/// cells, swept, and sky130 x.25's "pnp.dg must be only within cell name
/// `s8rf_pnp`, `s8rf_pnp5x`, `s8tesd_iref_pnp`, `stk14ecx_*`" (DRC-097),
/// where a longer name does not match a whole-name pattern; and a maximum
/// cell-name length (DRC-097, Calibre's DRC MAXIMUM CELL NAME LENGTH) as
/// `forbidden(a.in_cells("?????*"))`. Every case is placed under all eight
/// symmetries, which turn each placement with the design.
fn cellSelectionsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var cases: std.ArrayList(Fixture) = .empty;
    try cases.append(arena, try derived(arena, "derived/in_cells/tree", &.{ "DRC-092", "DRC-120" }, &.{"a"}, &.{
        .{ "a.in_cells(\"PAD_*\")", try c.areas(arena, &.{ 30_000, 10_000 }) },
        .{ "a.not_in_cells(\"PAD_*\")", try c.areas(arena, &.{ 5_000, 40_000, 10_000 }) },
        .{ "a.in_cells(\"core\", \"T?P\")", try c.areas(arena, &.{ 5_000, 30_000, 10_000, 40_000, 10_000 }) },
        .{ "a.in_cells(\"pad_*\")", &.{} },
    }, try cellTree(arena, "core")));

    const deck = try c.newDeck(arena, &.{"met1"}, "rule m1.w width(met1.not_in_cells(\"PAD*\")) >= 100nm\nrule m1.wa width(met1.in_cells(\"PAD*\")) >= 40nm\n");
    for (c.sweep3(100)) |sw| {
        const w = sw.value;
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cell_exemption/top/{s}", .{sw.side}), &.{"DRC-092"}, deck, try box(arena, "met1", .{ 0, 0, w, 1000 }), &.{ .{ "m1.w", try c.below(arena, w, 100) }, .{ "m1.wa", &.{} } }));
        var in_pad: Layout = .{};
        try in_pad.place(arena, "PADX", .identity, 0, 0);
        try in_pad.cell(arena, "PADX", try box(arena, "met1", .{ 0, 0, w, 1000 }));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cell_exemption/in_pad/{s}", .{sw.side}), &.{"DRC-092"}, deck, in_pad, &.{ .{ "m1.w", &.{} }, .{ "m1.wa", &.{} } }));
    }
    for (c.sweep3(40)) |sw| {
        var l: Layout = .{};
        try l.place(arena, "PAD", .identity, 0, 0);
        try l.cell(arena, "PAD", try box(arena, "met1", .{ 0, 0, sw.value, 1000 }));
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "cell_exemption/in_pad_narrow/{s}", .{sw.side}), &.{"DRC-092"}, deck, l, &.{ .{ "m1.w", &.{} }, .{ "m1.wa", try c.below(arena, sw.value, 40) } }));
    }

    const x25 = try c.newDeck(arena, &.{"pnp"}, "rule x.25 forbidden(pnp.not_in_cells(\"s8rf_pnp\", \"s8rf_pnp5x\", \"s8tesd_iref_pnp\", \"stk14ecx_*\"))\n");
    const square: c.Rect = .{ 0, 0, 100, 100 };
    var pnp = try box(arena, "pnp", .{ -1000, -1000, -900, -800 });
    for ([_][]const u8{ "s8rf_pnp", "stk14ecx_12", "wrapper", "s8rf_pnp_big", "my_pnp" }, 0..) |name, i| try pnp.place(arena, name, .identity, @as(i64, @intCast(i)) * 1000, 0);
    try pnp.cell(arena, "s8rf_pnp", try box(arena, "pnp", square));
    try pnp.cell(arena, "stk14ecx_12", try box(arena, "pnp", square));
    var wrapper: Layout = .{};
    try wrapper.place(arena, "s8tesd_iref_pnp", .identity, 0, 0);
    try pnp.cell(arena, "wrapper", wrapper);
    try pnp.cell(arena, "s8tesd_iref_pnp", try box(arena, "pnp", square));
    try pnp.cell(arena, "s8rf_pnp_big", try box(arena, "pnp", square));
    try pnp.cell(arena, "my_pnp", try box(arena, "pnp", .{ 0, 0, 200, 100 }));
    try cases.append(arena, try c.fixture(arena, "cell_exemption/x25", &.{ "DRC-097", "DRC-092" }, x25, pnp, &.{.{ "x.25", try c.areas(arena, &.{ 20_000, 10_000, 20_000 }) }}));
    // A maximum cell-name length of 4 (Calibre's DRC MAXIMUM CELL NAME
    // LENGTH, as a forbidden selection): five `?` and a `*` match a name of
    // five or more characters. A short cell under a long one is flagged with
    // it; `TOP` and `ABCD` are not.
    const length = try c.newDeck(arena, &.{"a"}, "rule name.max forbidden(a.in_cells(\"?????*\"))\n");
    var names = try box(arena, "a", .{ -1000, 0, -900, 100 });
    try names.place(arena, "ABCD", .identity, 0, 0);
    try names.place(arena, "ABCDE", .identity, 1000, 0);
    try names.place(arena, "LONGNAME", .identity, 2000, 0);
    try names.cell(arena, "ABCD", try box(arena, "a", .{ 0, 0, 100, 100 }));
    try names.cell(arena, "ABCDE", try box(arena, "a", .{ 0, 0, 200, 100 }));
    var long: Layout = .{};
    try long.place(arena, "AB", .identity, 0, 0);
    try names.cell(arena, "LONGNAME", long);
    try names.cell(arena, "AB", try box(arena, "a", .{ 0, 0, 300, 100 }));
    try cases.append(arena, try c.fixture(arena, "cell_exemption/name_length", &.{"DRC-097"}, length, names, &.{.{ "name.max", try c.areas(arena, &.{ 20_000, 30_000 }) }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Every finding of a run as `rule measured x,y`, sorted.
fn findingLines(arena: Allocator, f: *const Fixture) ![]const []const u8 {
    const r = try harness.run(arena, f);
    const v = &r.outputs.violations;
    const lines = try arena.alloc([]const u8, v.len());
    for (lines, 0..) |*line, i| {
        const row = v.get(@intCast(i));
        line.* = try std.fmt.allocPrint(arena, "{s} {f} {d},{d}", .{ r.loaded.strings.resolve(row.rule), row.measured, row.at.x, row.at.y });
    }
    std.mem.sort([]const u8, lines, {}, lessString);
    return lines;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn expectSameLines(a: []const []const u8, b: []const []const u8) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqualStrings(x, y);
}

test "every cell-selection fixture holds" {
    // Oracle: each fixture's expected answer, the areas of the shapes each
    // selection keeps counted by hand from the drawn hierarchy (the doc
    // comments above), under every symmetry at two translations.
    try c.checkGenerated(fixturesInto);
}

test "a placed cell lands where its symmetry maps it" {
    // The harness writes a placement as GDS `STRANS` and quarter turns
    // (`Symmetry.gds`); the reader must land an off-centre rectangle where
    // the harness's own symmetry puts its corners.
    // Oracle: round trip through the GDS writer (`writeLibrary`) and reader,
    // against `Symmetry.apply` on the corners, the map every flat fixture is
    // transformed by.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (Symmetry.all) |s| {
        var f: Fixture = .init("placement", &.{"DRC-092"}, try c.newDeck(arena, &.{"a"}, ""), harness.drc);
        try f.layout.place(arena, "C", s, 7, 11);
        try f.layout.cell(arena, "C", try box(arena, "a", .{ 100, 200, 400, 300 }));
        const r = try harness.run(arena, &f);
        const layer = r.loaded.deck.deck.layers.id(&r.loaded.strings, "a").?;
        const rows = r.loaded.store.polysOnLayer(layer);
        try testing.expectEqual(1, rows.len());
        const b = r.loaded.store.polyBbox(@fromBackingInt(rows.start));
        const p = s.apply(.{ 100, 200 });
        const q = s.apply(.{ 400, 300 });
        try testing.expectEqual([4]i64{ @min(p[0], q[0]) + 7, @min(p[1], q[1]) + 11, @max(p[0], q[0]) + 7, @max(p[1], q[1]) + 11 }, [4]i64{ b.xlo, b.ylo, b.xhi, b.yhi });
    }
}

test "renaming a cell changes only what its name selects" {
    // Renaming a cell the patterns do not match changes no finding, and
    // renaming it into a pattern moves its shape from `not_in_cells` to
    // `in_cells` and nothing else (DRC-092).
    // Oracle: metamorphic: a cell's name is read only by the selections; the
    // predicted report is the original one with `core`'s finding (the only
    // 200 × 200 square) moved from rule `f1` to rule `f0`.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deck = try c.newDeck(arena, &.{"a"}, "layer d0 = a.in_cells(\"PAD_*\")\nrule f0 forbidden(d0)\nlayer d1 = a.not_in_cells(\"PAD_*\")\nrule f1 forbidden(d1)\n");
    var named: [3]Fixture = undefined;
    for (&named, [_][]const u8{ "core", "other_core", "PAD_core" }) |*f, core| {
        f.* = .init("rename", &.{"DRC-092"}, deck, harness.drc);
        f.layout = try cellTree(arena, core);
    }
    const before = try findingLines(arena, &named[0]);
    try expectSameLines(before, try findingLines(arena, &named[1]));
    const core_prefix = try std.fmt.allocPrint(arena, "f1 {f} ", .{@import("check").report.Measurement.area(40_000)});
    const predicted = try arena.alloc([]const u8, before.len);
    var moved = false;
    for (before, predicted) |line, *p| {
        if (std.mem.startsWith(u8, line, core_prefix)) {
            p.* = try std.fmt.allocPrint(arena, "f0{s}", .{line[2..]});
            moved = true;
        } else p.* = line;
    }
    // core's finding is in f1 before the rename.
    try testing.expect(moved);
    std.mem.sort([]const u8, predicted, {}, lessString);
    try expectSameLines(predicted, try findingLines(arena, &named[2]));
}
