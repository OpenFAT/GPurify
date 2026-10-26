//! Incremental DRC (FLOW-008): `incremental.recheck` against a full
//! `check` of the same edited layout. Ported from tests/engine/incremental.rs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const incremental = @import("gpurify").incremental;
const gpa = testing.allocator;

/// Local kinds of every family, derived layers grown and shrunk (`m2big`
/// reaching 1.1 um between two m2 shapes, past every rule's own lengths),
/// and two whole-layout kinds (density, count).
const deck_text =
    \\grid 1nm
    \\layer m1 = gds(1, 0)
    \\layer v1 = gds(2, 0)
    \\layer m2 = gds(3, 0)
    \\layer fat = m1.sized(-200nm).sized(200nm)
    \\layer halo = v1.sized(60nm)
    \\layer m2big = m2.sized(500nm)
    \\rule m1.w width(m1) >= 100nm
    \\rule m1.s space(m1) >= 120nm
    \\rule m1.a area(m1) >= 0.05um2
    \\rule m1.n notch(m1) >= 120nm
    \\rule m1.c corner_space(m1) >= 150nm
    \\rule fat.s space(fat) >= 300nm
    \\rule v.e enclosure(v1, m1) >= 20nm
    \\rule v.s space(v1) >= 100nm
    \\rule h.s space(halo, m2) >= 40nm
    \\rule m12.s space(m1, m2) >= 50nm
    \\rule m2.w width(m2) >= 150nm
    \\rule big.s space(m2big) >= 100nm
    \\rule m1.d density(m1; window: 2um, step: 1um) >= 0.1
    \\rule m2.c count(m2) <= 12
    \\
;

/// A rectangle: layer index (0 m1, 1 v1, 2 m2) and its corners in nm.
const Rect = [5]i64;

const World = struct {
    arena: std.heap.ArenaAllocator,
    strings: geom.StrTable,
    deck: check.deck.CompiledDeck,

    fn init() !World {
        var w: World = .{ .arena = .init(gpa), .strings = .empty, .deck = undefined };
        const a = w.arena.allocator();
        var diag: check.deck.compile.Diag = .{};
        w.deck = try check.deck.compile.compile(a, a, deck_text, try .init(1000), &w.strings, &diag);
        return w;
    }

    fn deinit(w: *World) void {
        w.arena.deinit();
    }

    /// `rects` as a store with the deck's derived layers (FLOW-005).
    fn store(w: *World, rects: []const Rect) !geom.GeometryStore {
        const a = w.arena.allocator();
        var builder: geom.GeometryStoreBuilder = .{};
        for (rects) |r| {
            const names = [_][]const u8{ "m1", "v1", "m2" };
            const name = names[@intCast(r[0])];
            _ = try builder.push(a, w.deck.deck.layers.id(&w.strings, name).?, &.{ r[1], r[3], r[3], r[1] }, &.{ r[2], r[2], r[4], r[4] });
        }
        var out: geom.GeometryStore = .empty;
        var order: std.ArrayList(u32) = .empty;
        try builder.finish(a, @intCast(w.deck.deck.layers.len()), &out, &order);
        try ingest.layout.deriveLayersInto(a, &out, &w.deck.deck.layers, &.{}, &w.strings, &.{});
        return out;
    }

    fn row(w: *const World, s: *const incremental.DrcState, rule: []const u8) check.report.RuleRun {
        for (s.runs.items) |r| if (std.mem.eql(u8, w.strings.resolve(r.rule), rule)) return r;
        unreachable;
    }
};

// ---- private ----

/// A run's findings and rule rows as sorted text, `examined` left out (an
/// incremental run counts what it looked at again).
fn report(arena: Allocator, w: *const World, s: *const incremental.DrcState) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (0..s.violations.len()) |r| {
        const v = s.violations.get(@intCast(r));
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s} {d} {t} {d},{d} {f} {f} {d} {d}", .{ w.strings.resolve(v.rule), @backingInt(v.layer), v.severity, v.at.x, v.at.y, v.measured, v.limit, @backingInt(v.shape_a), @backingInt(v.shape_b) }));
    }
    for (s.runs.items) |r| try lines.append(arena, try std.fmt.allocPrint(arena, "{s} {any} {d}", .{ w.strings.resolve(r.rule), r.outcome, r.violations }));
    std.mem.sort([]const u8, lines.items, {}, lessString);
    return lines.items;
}

fn expectSameReport(arena: Allocator, w: *const World, a: *const incremental.DrcState, b: *const incremental.DrcState) !void {
    const ra = try report(arena, w, a);
    const rb = try report(arena, w, b);
    try testing.expectEqual(rb.len, ra.len);
    for (ra, rb) |x, y| try testing.expectEqualStrings(y, x);
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn randomRect(rng: *testgen.Rng) Rect {
    const layer: i64 = @intCast(rng.below(3));
    const w = rng.range(5, 60) * 10;
    const h = rng.range(5, 60) * 10;
    const x = rng.range(0, 2000) * 10;
    const y = rng.range(0, 2000) * 10;
    return .{ layer, x, y, x + w, y + h };
}

/// One seed: a random layout, then three rounds of random edits, each
/// rechecked from the last.
fn agree(seed: u64) !void {
    var w: World = try .init();
    defer w.deinit();
    const a = w.arena.allocator();
    var rng: testgen.Rng = .init(seed);
    var rects: std.ArrayList(Rect) = .empty;
    for (0..@intCast(rng.range(10, 120))) |_| try rects.append(a, randomRect(&rng));
    var state = try incremental.check(a, &w.deck, try w.store(rects.items));
    for (0..3) |_| {
        for (0..@intCast(rng.range(0, 3))) |_| if (rects.items.len != 0) {
            _ = rects.orderedRemove(@intCast(rng.below(rects.items.len)));
        };
        for (0..@intCast(rng.range(0, 3))) |_| try rects.insert(a, @intCast(rng.below(rects.items.len + 1)), randomRect(&rng));
        if (rects.items.len != 0 and rng.below(2) == 0) {
            const at: usize = @intCast(rng.below(rects.items.len));
            const dx = rng.range(-30, 30) * 10;
            const dy = rng.range(-30, 30) * 10;
            const r = &rects.items[at];
            r.* = .{ r[0], r[1] + dx, r[2] + dy, r[3] + dx, r[4] + dy };
        }
        const full = try incremental.check(a, &w.deck, try w.store(rects.items));
        const edited = try incremental.recheck(a, a, &w.deck, &w.strings, &state, try w.store(rects.items));
        expectSameReport(a, &w, &edited, &full) catch |err| {
            std.debug.print("seed {d}\n", .{seed});
            return err;
        };
        state = edited;
    }
}

test "a recheck finds what a full check finds" {
    // Oracle: metamorphic relation (catalog FLOW-008). Rechecking an edited
    // layout from the previous run gives exactly the findings, each naming
    // the same rows, and the rule outcomes a full check of the edited layout
    // gives, over 60 random layouts and three rounds of random removals,
    // additions and moves each.
    for (0..60) |seed| try agree(seed);
}

test "a recheck examines only the edited part" {
    // Oracle: hand-derived. Two m1 squares 50 um apart, far beyond the
    // deck's reach: narrowing one to 80 nm makes one `m1.w` finding, and the
    // recheck's `m1.w` row examined one figure where the full check examines
    // two. With nothing changed, the recheck keeps every finding and
    // examines nothing.
    var w: World = try .init();
    defer w.deinit();
    const a = w.arena.allocator();
    const state = try incremental.check(a, &w.deck, try w.store(&.{ .{ 0, 0, 0, 500, 500 }, .{ 0, 50_000, 0, 50_500, 500 } }));
    const after = [_]Rect{ .{ 0, 0, 0, 80, 500 }, .{ 0, 50_000, 0, 50_500, 500 } };
    const edited = try incremental.recheck(a, a, &w.deck, &w.strings, &state, try w.store(&after));
    const full = try incremental.check(a, &w.deck, try w.store(&after));
    const ew = w.row(&edited, "m1.w");
    const fw = w.row(&full, "m1.w");
    try testing.expectEqual(1, ew.violations);
    try testing.expectEqual(1, ew.examined);
    try testing.expectEqual(1, fw.violations);
    try testing.expectEqual(2, fw.examined);
    try expectSameReport(a, &w, &edited, &full);
    const same = try incremental.recheck(a, a, &w.deck, &w.strings, &edited, try w.store(&after));
    try expectSameReport(a, &w, &same, &full);
    try testing.expectEqual(0, w.row(&same, "m1.w").examined);
}
