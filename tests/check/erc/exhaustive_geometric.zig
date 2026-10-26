//! The geometric ERC kinds on shapes whose answer is known by
//! construction: tap boards for `supply_short` (judged by the board
//! oracle), met1 islands joined through a well, wells of 1 µm cells with
//! and without a tap, and regions at an exact distance from their taps.
//! Ported from tests/exhaustive/erc.rs (`supply_short`, `soft_connection`,
//! `floating_well`, `missing_tie`, `three_rails`, `sample`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const testgen = @import("testgen");
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const board = @import("board.zig");
const Board = board.Board;
const Tap = board.Tap;
const expect = @import("board_expect.zig");
const pc = @import("ported_circuit.zig");
const count = pc.count;
const length = pc.length;
const gpa = std.testing.allocator;

/// A well and tap deck: geometric containment and distance, no nets.
const geo_process =
    \\grid 1nm
    \\layer nwell = gds(1, 0)
    \\layer ntap = gds(2, 0)
    \\layer act = gds(3, 0)
    \\layer tap = gds(4, 0)
    \\
;

/// A tap position: the cells it lies over, and its box.
const TapAt = struct { under: []const usize, r: [4]i64 };

/// A floating-well case: a pattern of cells (bit c set for cell c) and a
/// tap position, if any.
const WellCase = struct { pattern: u32, tap: ?TapAt };

// ---- private ----

/// Nets 0-3 as VDD (1.8 V, domain a), VSS (ground, a), VDDH (3.3 V, domain
/// b) and an unlabelled signal.
// ponytail: copy of ported_board.zig's private `threeRails`; move both to
// board.zig once ported_board.zig is wired.
fn threeRails(with_intent: bool) Board {
    return .{
        .labels = .{ "VDD", "VSS", "VDDH", null },
        .supplies = &.{
            .{ .net = 0, .power = true, .domain = 0, .nominal = 1800.0 },
            .{ .net = 1, .power = false, .domain = 0, .nominal = 1800.0 },
            .{ .net = 2, .power = true, .domain = 1, .nominal = 3300.0 },
        },
        .domains = &.{ .{ .name = "a", .mv = 1800.0 }, .{ .name = "b", .mv = 3300.0 } },
        .with_intent = with_intent,
    };
}

/// A seeded sample of `merge` items (all of them when that many or fewer):
/// the merge depth of the Rust harness.
// ponytail: copy of ported_board.zig's private `sample`, as `threeRails`.
fn sample(arena: Allocator, comptime T: type, items: []const T, merge: usize, seed: u64) ![]const T {
    if (items.len <= merge) return items;
    var rng = testgen.Rng.init(seed);
    const index = try arena.alloc(usize, items.len);
    for (index, 0..) |*x, i| x.* = i;
    for (0..merge) |i| {
        const j = i + @as(usize, @intCast(rng.below(index.len - i)));
        std.mem.swap(usize, &index[i], &index[j]);
    }
    const out = try arena.alloc(T, merge);
    for (out, index[0..merge]) |*o, i| o.* = items[i];
    return out;
}

/// `supply_short` (ERC-G4): three tap stubs, each an n- or p-tap on any of
/// four nets (8^3 boards): a net holding both is one finding. With `within`,
/// named cases where an `nwpm` polygon covers some n-taps.
fn supplyShort(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var codes: [512]u32 = undefined;
    for (&codes, 0..) |*c, i| c.* = @intCast(i);
    for (try sample(arena, u32, &codes, 100, 0x55_0001)) |code| {
        const taps = try arena.alloc(Tap, 3);
        var name: std.ArrayList(u8) = .empty;
        try name.appendSlice(arena, "erc/supply_short/");
        for (taps, 0..) |*t, k| {
            const digit = (code >> @intCast(3 * k)) & 7;
            t.* = .{ .n = digit & 4 != 0, .net = digit & 3 };
            try name.print(arena, "{c}{d}", .{ @as(u8, if (t.n) 'n' else 'p'), t.net });
        }
        var b = threeRails(false);
        b.taps = taps;
        try out.append(arena, try supplyFixture(arena, &b, name.items));
    }
    const Within = struct { []const u8, []const usize };
    for ([_]Within{ .{ "covered", &.{0} }, .{ "uncovered", &.{2} }, .{ "both", &.{ 0, 2 } } }) |case| {
        var b = threeRails(false);
        b.taps = &.{ .{ .n = true, .net = 0 }, .{ .n = false, .net = 0 }, .{ .n = true, .net = 1 }, .{ .n = false, .net = 1 } };
        b.nwpm = case[1];
        try out.append(arena, try supplyFixture(arena, &b, try std.fmt.allocPrint(arena, "erc/supply_short/within/{s}", .{case[0]})));
    }
}

/// The board's fixture with only its `supply_short` claims (`ss`, `ssw`).
// ponytail: the board's other rows are ported_board.zig's to claim; its
// voltage rows refuse until the voltage family lands.
fn supplyFixture(arena: Allocator, b: *const Board, name: []const u8) !Fixture {
    var f = try expect.fixtureOf(b, arena, name);
    var kept: std.ArrayList(Expect) = .empty;
    for (f.expect) |e| if (std.mem.eql(u8, e.id, "ss") or std.mem.eql(u8, e.id, "ssw")) try kept.append(arena, e);
    f.expect = kept.items;
    return f;
}

/// `soft_connection` (ERC-G5): two met1 islands joined only through a well
/// (soft) by two contacts, one finding; with a met1 strap between them,
/// clean. A met2 strap contacted to one island only and passing over the
/// other joins nothing, so the islands are still held only by the well (F27:
/// any two touching shapes were once taken as joined).
fn softConnection(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var base: Layout = .{};
    try base.rect(arena, "well", 0, 0, 6000, 1000);
    try base.rect(arena, "cont", 200, 200, 400, 400);
    try base.rect(arena, "cont", 5600, 200, 5800, 400);
    try base.rect(arena, "met1", 0, 0, 1000, 1000);
    try base.rect(arena, "met1", 5000, 0, 6000, 1000);
    var strapped = try base.transformed(arena, .identity, 0, 0);
    try strapped.rect(arena, "met1", 1000, 400, 5000, 600);
    var over = try base.transformed(arena, .identity, 0, 0);
    try over.rect(arena, "met2", 500, 0, 5500, 1000);
    try over.rect(arena, "via1", 600, 400, 800, 600);
    const deck = try board.topoDeck(arena, .{});
    const Case = struct { []const u8, Layout, []const Finding };
    for ([_]Case{
        .{ "through_well", base, try arena.dupe(Finding, &.{count(2)}) },
        .{ "strapped", strapped, &.{} },
        .{ "f27/overlap_without_via", over, try arena.dupe(Finding, &.{count(2)}) },
    }) |case| try out.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "erc/soft_connection/{s}", .{case[0]}),
        .deck = deck,
        .layout = case[1],
        .expect = try arena.dupe(Expect, &.{.{ .id = "soft", .findings = case[2] }}),
    });
}

/// `floating_well` (ERC-G2): wells as unions of 1 µm cells on a 3 × 2 grid
/// (every pattern), a 200 nm tap at a cell's centre or across the edge
/// between two side-by-side cells, or none. A well is an 8-connected group of
/// cells: cells meeting only at a corner are one well, the corner model of
/// the merge. A tap ties a well only when the well covers all of it. Named: a
/// tap in a well's hole, in a notch, across its outer edge.
fn floatingWell(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = geo_process ++ "rule fw floating_well(nwell, ntap)\n";
    // Tap positions: six centres, then the four horizontal cell edges.
    var taps: [10]TapAt = undefined;
    for (0..6) |c| {
        const x, const y = cell(c);
        taps[c] = .{ .under = try arena.dupe(usize, &.{c}), .r = .{ x + 400, y + 400, x + 600, y + 600 } };
    }
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 3, 4 }, .{ 4, 5 } }, 6..) |e, k| {
        const x, const y = cell(e[1]);
        taps[k] = .{ .under = try arena.dupe(usize, &e), .r = .{ x - 100, y + 400, x + 100, y + 600 } };
    }
    var cases: std.ArrayList(WellCase) = .empty;
    for (1..64) |pattern| {
        for (taps) |t| try cases.append(arena, .{ .pattern = @intCast(pattern), .tap = t });
        try cases.append(arena, .{ .pattern = @intCast(pattern), .tap = null });
    }
    for (try sample(arena, WellCase, cases.items, 100, 0xf3_0001)) |cs| {
        // Components by edge or corner adjacency.
        var group: [6]usize = .{ 0, 1, 2, 3, 4, 5 };
        for (0..6) |a| for (0..6) |b| {
            if (!has(cs.pattern, a) or !has(cs.pattern, b) or !touching(a, b)) continue;
            const ga, const gb = .{ group[a], group[b] };
            for (&group) |*g| if (g.* == gb) {
                g.* = ga;
            };
        };
        // The well a tap ties: the one covering every cell under it.
        const tied: ?usize = blk: {
            const t = cs.tap orelse break :blk null;
            for (t.under) |c| if (!has(cs.pattern, c)) break :blk null;
            break :blk group[t.under[0]];
        };
        // One finding per distinct well but the tied one.
        var findings: std.ArrayList(Finding) = .empty;
        var seen: [6]bool = @splat(false);
        var layout: Layout = .{};
        var name: std.ArrayList(u8) = .empty;
        try name.appendSlice(arena, "erc/floating_well/");
        for (0..6) |c| if (has(cs.pattern, c)) {
            const x, const y = cell(c);
            try layout.rect(arena, "nwell", x, y, x + 1000, y + 1000);
            try name.append(arena, '0' + @as(u8, @intCast(c)));
            if (seen[group[c]]) continue;
            seen[group[c]] = true;
            if (tied != group[c]) try findings.append(arena, count(0));
        };
        if (cs.tap) |t| {
            try layout.rect(arena, "ntap", t.r[0], t.r[1], t.r[2], t.r[3]);
            try name.appendSlice(arena, "/tap_");
            for (t.under) |c| try name.append(arena, '0' + @as(u8, @intCast(c)));
        }
        try out.append(arena, .{
            .name = name.items,
            .deck = deck,
            .layout = layout,
            .expect = try arena.dupe(Expect, &.{.{ .id = "fw", .findings = findings.items }}),
        });
    }
    // A ring of four bars around a tap: the tap sits in the hole.
    var ring: Layout = .{};
    try ring.rect(arena, "nwell", 0, 0, 3000, 500);
    try ring.rect(arena, "nwell", 0, 2500, 3000, 3000);
    try ring.rect(arena, "nwell", 0, 500, 500, 2500);
    try ring.rect(arena, "nwell", 2500, 500, 3000, 2500);
    try ring.rect(arena, "ntap", 1400, 1400, 1600, 1600);
    // A U whose notch holds the tap.
    var notch: Layout = .{};
    try notch.polygon(arena, "nwell", &.{ .{ 0, 0 }, .{ 3000, 0 }, .{ 3000, 3000 }, .{ 2000, 3000 }, .{ 2000, 1000 }, .{ 1000, 1000 }, .{ 1000, 3000 }, .{ 0, 3000 } });
    try notch.rect(arena, "ntap", 1400, 2000, 1600, 2200);
    var edge: Layout = .{};
    try edge.rect(arena, "nwell", 0, 0, 2000, 2000);
    try edge.rect(arena, "ntap", 1900, 900, 2100, 1100);
    var inside: Layout = .{};
    try inside.rect(arena, "nwell", 0, 0, 2000, 2000);
    try inside.rect(arena, "ntap", 1800, 900, 2000, 1100);
    const Named = struct { []const u8, Layout, []const Finding };
    for ([_]Named{
        .{ "hole", ring, try arena.dupe(Finding, &.{count(0)}) },
        .{ "notch", notch, try arena.dupe(Finding, &.{count(0)}) },
        .{ "across_edge", edge, try arena.dupe(Finding, &.{count(0)}) },
        .{ "inside_touching_edge", inside, &.{} },
    }) |case| try pc.everyPlacement(arena, out, .{
        .name = try std.fmt.allocPrint(arena, "erc/floating_well/named/{s}", .{case[0]}),
        .deck = deck,
        .layout = case[1],
        .expect = try arena.dupe(Expect, &.{.{ .id = "fw", .findings = case[2] }}),
    });
}

/// Cell `c` is drawn in `pattern`.
fn has(pattern: u32, c: usize) bool {
    return pattern >> @intCast(c) & 1 == 1;
}

/// Cell `c`'s lower-left corner on the 3 × 2 grid of 1 µm cells.
fn cell(c: usize) [2]i64 {
    return .{ @as(i64, @intCast(c % 3)) * 1000, @as(i64, @intCast(c / 3)) * 1000 };
}

/// Two distinct cells share an edge or a corner.
fn touching(a: usize, b: usize) bool {
    const ax, const ay = cell(a);
    const bx, const by = cell(b);
    const dx = @abs(ax - bx);
    const dy = @abs(ay - by);
    return dx + dy == 1000 or (dx == 1000 and dy == 1000);
}

/// `missing_tie` (ERC-D1): the furthest point of each region polygon from
/// the nearest tap edge, exact.
///
/// - A 1 µm square region whose far corner (0, 0) is a 3-4-5 triangle from
///   the tap's corner: 5000 nm, swept a nanometre either side, every
///   placement.
/// - A 10 µm bar between two taps 1 µm off each end: the furthest point is
///   the bar's middle, 6000 nm from both, on no vertex (a vertex check reads
///   1000).
/// - A region inside a ring of four tap bars: the furthest point is its
///   centre, 1500 nm from every inner edge.
/// - No tap at all: the region is flagged at the coordinate domain's bound.
fn missingTie(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    var corner: Layout = .{};
    try corner.rect(arena, "act", 0, 0, 1000, 1000);
    try corner.rect(arena, "tap", 3000, 4000, 3500, 4500);
    var bar: Layout = .{};
    try bar.rect(arena, "act", 0, 0, 10_000, 100);
    try bar.rect(arena, "tap", -2000, 0, -1000, 100);
    try bar.rect(arena, "tap", 11_000, 0, 12_000, 100);
    var ring: Layout = .{};
    try ring.rect(arena, "act", 0, 0, 1000, 1000);
    try ring.rect(arena, "tap", -1500, -1500, -1000, 2500);
    try ring.rect(arena, "tap", 2000, -1500, 2500, 2500);
    try ring.rect(arena, "tap", -1000, -1500, 2000, -1000);
    try ring.rect(arena, "tap", -1000, 2000, 2000, 2500);
    const Case = struct { []const u8, Layout, i64, ?[2]i64 };
    for ([_]Case{
        .{ "pythagorean", corner, 5000, .{ 0, 0 } },
        .{ "mid_edge", bar, 6000, null },
        .{ "inside_ring", ring, 1500, .{ 500, 500 } },
    }) |case| {
        const value = case[2];
        for ([_]i64{ value - 1, value, value + 1 }) |limit| {
            const flagged = limit < value;
            var finding = length(value);
            finding.at = case[3];
            const f: Fixture = .{
                .name = try std.fmt.allocPrint(arena, "erc/missing_tie/{s}/{s}", .{ case[0], pc.side(@floatFromInt(limit), @floatFromInt(value)) }),
                .deck = try tieDeck(arena, limit),
                .layout = case[1],
                .expect = try arena.dupe(Expect, &.{.{ .id = "mt", .findings = if (flagged) try arena.dupe(Finding, &.{finding}) else &.{} }}),
            };
            if (flagged and case[3] != null) try pc.everyPlacement(arena, out, f) else try out.append(arena, f);
        }
    }
    var lone: Layout = .{};
    try lone.rect(arena, "act", 0, 0, 1000, 1000);
    try out.append(arena, .{
        .name = "erc/missing_tie/no_tap",
        .deck = try tieDeck(arena, 1000),
        .layout = lone,
        .expect = try arena.dupe(Expect, &.{.{ .id = "mt", .findings = try arena.dupe(Finding, &.{length(geom.max_abs_dbu)}) }}),
    });
}

fn tieDeck(arena: Allocator, limit: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}rule mt missing_tie(act, tap; max_distance: {d}nm)\n", .{ geo_process, limit });
}

// Oracle: the board oracle's supply_short (a net holding both an n-tap and
// a p-tap, `within` counting only n-taps an nwpm covers); soft_connection
// by construction (islands joined only through the well: one finding of 2
// contacts; a met1 strap clears; a met2 strap with one via does not, F27);
// floating_well by an 8-connected union-find over the drawn cells, a tap
// tying a well only when the well covers all of it; missing_tie at exact
// distances (a 3-4-5 corner 5000 nm, a bar's middle 6000 nm, a ring's
// centre 1500 nm, no tap at the domain bound), swept a nanometre either
// side of each.
test "geometric rows report findings known by construction" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try supplyShort(arena, &all);
    try softConnection(arena, &all);
    try floatingWell(arena, &all);
    try missingTie(arena, &all);
    try fixture.checkAll(all.items);
}
