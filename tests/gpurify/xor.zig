//! `gpurify xor` (DRC-068): two layouts compared layer by layer, against
//! areas worked out by hand. Ported from tests/exhaustive/xor.rs; its
//! differential against KLayout's XOR on random pairs (tests/klayout/xor.rs)
//! is a live-tool test and not here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Layout = harness.Layout;
const gpa = testing.allocator;
const io = testing.io;

/// Three drawn layers and one derived from two of them, which `xor` leaves
/// out.
const deck =
    \\grid 1nm
    \\layer met1 = gds(68, 20)
    \\layer via1 = gds(68, 44)
    \\layer met2 = gds(69, 20)
    \\layer both = met1 and met2
    \\
;

/// The rows of a run in which no layer differs.
const clean = "xor.met1 ran\nxor.met2 ran\nxor.via1 ran\n";

/// A run as text, one line per rule row sorted by id: its outcome and the
/// areas it measured ascending, in nm²; and whether it passed.
const Report = struct { rows: []const u8, passed: bool };

// ---- private ----

/// `gpurify xor a b` through the real reader, as `Report`, in `arena`.
fn xor(arena: Allocator, a: *const Layout, b: *const Layout) !Report {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "xor.deck", .data = deck });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.gds", .data = try harness.written(arena, deck, a) });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.gds", .data = try harness.written(arena, deck, b) });
    var diag: gpurify.xor.Diagnostic = .{};
    const r = try gpurify.xor.run(gpa, arena, io, tmp.dir, .{ .layout = "a.gds", .deck = "xor.deck" }, "b.gds", &.{}, &diag);
    try testing.expect(r.summary.drc == .ran);
    try testing.expect(r.summary.erc == .not_selected);
    const strings = &r.loaded.strings;
    const runs = try arena.dupe(@TypeOf(r.outputs.runs.items[0]), r.outputs.runs.items);
    std.mem.sort(@TypeOf(runs[0]), runs, strings, struct {
        fn less(s: @TypeOf(strings), x: @TypeOf(runs[0]), y: @TypeOf(runs[0])) bool {
            return std.mem.lessThan(u8, s.resolve(x.rule), s.resolve(y.rule));
        }
    }.less);
    const v = &r.outputs.violations;
    for (v.kind.items) |k| try testing.expect(k == .area);
    var text: std.ArrayList(u8) = .empty;
    for (runs) |run| {
        try text.print(arena, "{s} {t}", .{ strings.resolve(run.rule), run.outcome });
        var areas: std.ArrayList(i128) = .empty;
        for (v.rule.items, v.measured.items) |rule, m| if (rule == run.rule) try areas.append(arena, m);
        std.mem.sort(i128, areas.items, {}, std.sort.asc(i128));
        for (areas.items, 0..) |m, i| try text.print(arena, "{s}{d}", .{ if (i == 0) " " else ",", m });
        try text.append(arena, '\n');
    }
    // Every finding belongs to a row.
    for (v.rule.items) |rule| try testing.expect(for (runs) |run| (if (run.rule == rule) break true) else false);
    return .{ .rows = text.items, .passed = r.summary.passed() };
}

/// A layout with a shape on every drawn layer.
fn sample(arena: Allocator) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 1000, 200);
    try l.rect(arena, "via1", 50, 50, 150, 150);
    try l.rect(arena, "met2", 0, 0, 200, 1000);
    return l;
}

/// The case sky130's IR-drop rules describe: four 150 nm cuts (`via.1a`'s
/// size) in `a`; in `b` the second is gone and the third slotted to 110
/// nm, centred.
fn cuts(arena: Allocator) ![2]Layout {
    var out: [2]Layout = .{ .{}, .{} };
    for (0..4) |i| try cut(arena, &out[0], @as(i64, @intCast(i)) * 320, 150);
    try cut(arena, &out[1], 0, 150);
    try cut(arena, &out[1], 640, 110);
    try cut(arena, &out[1], 960, 150);
    return out;
}

fn cut(arena: Allocator, l: *Layout, x: i64, size: i64) !void {
    const o = @divExact(150 - size, 2);
    try l.rect(arena, "via1", x + o, o, x + o + size, o + size);
}

test "a layout against itself differs nowhere" {
    // Oracle: law (`A xor A` is empty): a layout against itself differs
    // nowhere; every drawn layer has a row, the derived one none, and the
    // run passes.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const l = try sample(a);
    const r = try xor(a, &l, &l);
    try testing.expectEqualStrings(clean, r.rows);
    try testing.expect(r.passed);
}

test "moved and missing shapes differ by their area" {
    // Oracle: hand-derived areas. met1 [0, 1000] × [0, 1000] against
    // [500, 1500] × [0, 1000]: the strips [0, 500] and [1000, 1500] differ,
    // 500 × 1000 = 500000 nm² each. met2, drawn only in `a` as two
    // overlapping 1000 nm squares offset by 500, differs over their union,
    // one region of 1500 × 1000 = 1500000 nm², not 2000000.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    var la: Layout = .{};
    try la.rect(a, "met1", 0, 0, 1000, 1000);
    try la.rect(a, "met2", 0, 0, 1000, 1000);
    try la.rect(a, "met2", 500, 0, 1500, 1000);
    var lb: Layout = .{};
    try lb.rect(a, "met1", 500, 0, 1500, 1000);
    const r = try xor(a, &la, &lb);
    try testing.expectEqualStrings("xor.met1 ran 500000,500000\nxor.met2 ran 1500000\nxor.via1 ran\n", r.rows);
    try testing.expect(!r.passed);
}

test "a lost and a slotted cut add up to the cut area lost" {
    // Oracle: construct-from-answer (DRC-068, cut-area conservation). The
    // lost cut differs by its 22500 nm²; the slotted one by the ring around
    // its slot, 22500 − 12100 = 10400 nm², one region with a hole. Together
    // they are the cut area `b` lost, 4 × 22500 − (3 × 22500 − 10400) =
    // 32900 nm².
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const c = try cuts(a);
    const r = try xor(a, &c[0], &c[1]);
    try testing.expectEqualStrings("xor.met1 ran\nxor.met2 ran\nxor.via1 ran 10400,22500\n", r.rows);
    try testing.expectEqual(4 * 22_500 - (3 * 22_500 - 10_400), 10_400 + 22_500);
    try testing.expect(!r.passed);
}

test "swapping the layouts changes no row" {
    // Oracle: metamorphic relation (`A xor B = B xor A`): swapping the two
    // layouts of the cases above changes no row.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    var ma: Layout = .{};
    try ma.rect(a, "met1", 0, 0, 1000, 1000);
    var mb: Layout = .{};
    try mb.rect(a, "met1", 500, 0, 1500, 1000);
    try mb.rect(a, "met2", 0, 0, 1000, 1000);
    const c = try cuts(a);
    for ([_][2]Layout{ .{ ma, mb }, c }) |pair| {
        const forward = try xor(a, &pair[0], &pair[1]);
        const back = try xor(a, &pair[1], &pair[0]);
        try testing.expectEqualStrings(forward.rows, back.rows);
        try testing.expectEqual(forward.passed, back.passed);
        try testing.expect(!std.mem.eql(u8, forward.rows, clean));
    }
}

test "a layer with a 45 degree edge is refused, not compared" {
    // Oracle: the module's definition: a layer `xor` cannot compare
    // exactly, a 45° edge on via1 here, is refused, which fails the run,
    // and the other layers still compare.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    var l = try sample(a);
    try l.polygon(a, "via1", &.{ .{ 400, 400 }, .{ 600, 400 }, .{ 400, 600 } });
    const r = try xor(a, &l, &l);
    try testing.expectEqualStrings("xor.met1 ran\nxor.met2 ran\nxor.via1 refused\n", r.rows);
    try testing.expect(!r.passed);
}
