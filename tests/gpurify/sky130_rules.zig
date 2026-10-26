//! The sky130 rules whose answer depends on the load stage: cell-name
//! scoping (a GDSII hierarchy flattened with its cell tags) and device
//! recognition on the shipped deck. Ported from the root
//! tests/sky130_rules.rs, the tests tests/check/drc/sky130_rules.zig
//! deferred to the engine.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;

const Rect = struct { []const u8, i64, i64, i64, i64 };

/// What one rule did over a layout: its findings, whether every row ran,
/// and what it examined.
const Ran = struct { violations: u32, ran: bool, examined: u64 };

const Found = struct { model: []const u8, nets: []const u32 };

// ---- private ----

/// mcon enclosed by met1 by `e` on every side.
fn enclosed(e: i64) [2]Rect {
    return .{ .{ "mcon", 0, 0, 170, 170 }, .{ "met1", -e, -e, 170 + e, 170 + e } };
}

fn bar(w: i64) [1]Rect {
    return .{.{ "li", 0, 0, w, 2000 }};
}

/// `rects` drawn in a cell named `cell` that `TOP` places at the origin
/// (or in `TOP` itself when `cell` is null), DRC-checked on sky130 through
/// the engine; rule `id`'s rows.
fn run(a: Allocator, id: []const u8, cell: ?[]const u8, rects: []const Rect) !Ran {
    var strings: geom.StrTable = .empty;
    var diag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(a, a, gpurify.pdks.sky130, try .init(1000), &strings, &diag);
    const boxes = try a.alloc(struct { u16, u16, [4]i32 }, rects.len);
    for (rects, boxes) |r, *b| {
        const pair = d.layers.streamOf(d.layers.id(&strings, r[0]).?);
        b.* = .{ pair[0], pair[1], .{ @intCast(r[1]), @intCast(r[2]), @intCast(r[3]), @intCast(r[4]) } };
    }
    const cells: []const testgen.gds.Structure = if (cell) |name|
        &.{ .{ .name = "TOP", .refs = &.{.{ .cell = name }} }, .{ .name = name, .rects = boxes } }
    else
        &.{.{ .name = "TOP", .rects = boxes }};
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeLibrary(a, cells, &bytes);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "top.gds", .data = bytes.items });
    var rdiag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, a, io, tmp.dir, .{ .layout = "top.gds", .deck = "sky130" }, .{ .checks = .{ .drc = true } }, &gpurify.pdks.decks, &rdiag);
    var out: Ran = .{ .violations = 0, .ran = true, .examined = 0 };
    var seen = false;
    for (r.outputs.runs.items) |rr| if (std.mem.eql(u8, r.loaded.strings.resolve(rr.rule), id)) {
        seen = true;
        out.violations += rr.violations;
        out.ran = out.ran and rr.outcome == .ran;
        out.examined += rr.examined;
    };
    try testing.expect(seen);
    return out;
}

fn runInCell(a: Allocator, id: []const u8, cell: []const u8, rects: []const Rect) !Ran {
    return run(a, id, cell, rects);
}

/// `passing` passes rule `id` and the rule examined something; `failing`
/// does not.
fn atLimit(a: Allocator, id: []const u8, passing: []const Rect, failing: []const Rect) !void {
    const p = try run(a, id, null, passing);
    try testing.expect(p.ran and p.examined > 0);
    try testing.expectEqual(0, p.violations);
    try testing.expect((try run(a, id, null, failing)).violations > 0);
}

/// The models recognised in `rects` on sky130, each with its terminal nets.
fn devices(a: Allocator, rects: []const Rect) ![]const Found {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var strings: geom.StrTable = .empty;
    var diag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(a, a, gpurify.pdks.sky130, try .init(1000), &strings, &diag);
    var lb: testgen.shapes.LayoutBuilder = .init(@intCast(d.layers.len()));
    for (rects) |r| _ = try lb.rect(a, @backingInt(d.layers.id(&strings, r[0]).?), r[1], r[2], r[3], r[4]);
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(a, &store, &ids);
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStore(a, &store, &d.layers, "TOP", &bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "top.gds", .data = bytes.items });
    var rdiag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, a, io, tmp.dir, .{ .layout = "top.gds", .deck = "sky130" }, .{}, &gpurify.pdks.decks, &rdiag);
    const t = &r.extracted.devices;
    const out = try a.alloc(Found, t.len());
    for (out, 0..) |*f, row| {
        const nets = t.terminalsOf(@fromBackingInt(@as(u32, @intCast(row)))).nets;
        const raw = try a.alloc(u32, nets.len);
        for (nets, raw) |n, *o| o.* = @backingInt(n);
        f.* = .{ .model = r.loaded.strings.resolve(t.model.items[row]), .nets = raw };
    }
    return out;
}

test "m1.4a holds named cells to 5nm and m1.4 exempts them" {
    // Oracle: foundry example, sky130 m1.4 0.030 um and m1.4a 0.005 um for
    // the cell names it lists (s8fpls_pl8, s8fs_cmux4_fm, ...; SkyWater
    // SKY130 periphery rules, m1.4 "Rule exempted for cell names documented
    // in rule m1.4a"): 5 nm passes m1.4a and is outside m1.4 in s8fpls_pl8;
    // 2 nm fails m1.4a in s8fs_cmux4_fm; 5 nm in s8fpls_pl8x, a name m1.4a
    // does not list, fails m1.4; at the top m1.4 holds at 30 nm, fails at 25.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const m14a = try runInCell(a, "m1.4a", "s8fpls_pl8", &enclosed(5));
    try testing.expectEqual(0, m14a.violations);
    try testing.expect(m14a.ran and m14a.examined > 0);
    try testing.expectEqual(0, (try runInCell(a, "m1.4", "s8fpls_pl8", &enclosed(5))).violations);
    try testing.expect((try runInCell(a, "m1.4a", "s8fs_cmux4_fm", &enclosed(2))).violations > 0);
    try testing.expect((try runInCell(a, "m1.4", "s8fpls_pl8x", &enclosed(5))).violations > 0);
    try testing.expectEqual(0, (try runInCell(a, "m1.4a", "s8fpls_pl8x", &enclosed(5))).violations);
    try atLimit(a, "m1.4", &enclosed(30), &enclosed(25));
}

test "li.1a holds vpp cells to 140nm" {
    // Oracle: foundry example, sky130 li.1 0.170 um and li.1a 0.140 um
    // "inside of cells with name s8rf2_xcmvpp_hd5_*" (SkyWater SKY130
    // periphery rules): 140 then 135 nm inside such a cell, 140 outside one.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try runInCell(a, "li.1a", "s8rf2_xcmvpp_hd5_atlas", &bar(140));
    try testing.expect(r.ran and r.examined > 0);
    try testing.expectEqual(0, r.violations);
    try testing.expectEqual(0, (try runInCell(a, "li.1", "s8rf2_xcmvpp_hd5_atlas", &bar(140))).violations);
    try testing.expect((try runInCell(a, "li.1a", "s8rf2_xcmvpp_hd5_atlas", &bar(135))).violations > 0);
    try testing.expect((try runInCell(a, "li.1", "s8rf2_xcmvpp_hd4", &bar(140))).violations > 0);
    try atLimit(a, "li.1", &bar(170), &bar(165));
}

test "x.25 keeps pnp to its cells and poly.12 exempts its cell" {
    // Oracle: foundry example, sky130 x.25 and poly.12 (SkyWater SKY130
    // periphery rules): pnp in stk14ecx_9 passes and in my_pnp fails; poly
    // over tap outside nwell fails in any cell but s8fgvr_n_fg2.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pnp = [_]Rect{.{ "pnp", 0, 0, 1000, 1000 }};
    try testing.expectEqual(0, (try runInCell(a, "x.25", "stk14ecx_9", &pnp)).violations);
    try testing.expectEqual(0, (try runInCell(a, "x.25", "s8rf_pnp5x", &pnp)).violations);
    try testing.expect((try runInCell(a, "x.25", "my_pnp", &pnp)).violations > 0);
    try testing.expect((try runInCell(a, "x.25", "s8rf_pnp5", &pnp)).violations > 0);
    const overlap = [_]Rect{ .{ "tap", 0, 0, 500, 500 }, .{ "poly", 200, -200, 350, 700 } };
    try testing.expectEqual(0, (try runInCell(a, "poly.12", "s8fgvr_n_fg2", &overlap)).violations);
    try testing.expect((try runInCell(a, "poly.12", "s8fgvr_n_fg3", &overlap)).violations > 0);
}

test "a plain nfet extracts as nfet_01v8 with four nets" {
    // Oracle: construct-from-answer against pdks/sky130.deck's device rows:
    // poly over n+ diffusion is one sky130_fd_pr__nfet_01v8, and its gate,
    // source, drain and bulk are four different nets.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const found = try devices(arena.allocator(), &.{ .{ "diff", 0, 0, 1000, 420 }, .{ "nsdm", -125, -125, 1125, 545 }, .{ "poly", 425, -130, 575, 550 } });
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings("sky130_fd_pr__nfet_01v8", found[0].model);
    try testing.expectEqual(4, found[0].nets.len);
    for (found[0].nets, 0..) |x, i| for (found[0].nets[i + 1 ..]) |y| try testing.expect(x != y);
}

test "a poly resistor has two distinct heads" {
    // Oracle: construct-from-answer against pdks/sky130.deck's
    // sky130_fd_pr__res_generic_po row: the body under poly_rs is cut out of
    // the poly, so the two heads are two nets.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const found = try devices(arena.allocator(), &.{ .{ "poly", 0, 0, 330, 3000 }, .{ "poly_rs", -100, 1000, 430, 2000 } });
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings("sky130_fd_pr__res_generic_po", found[0].model);
    try testing.expectEqual(2, found[0].nets.len);
    try testing.expect(found[0].nets[0] != found[0].nets[1]);
}
