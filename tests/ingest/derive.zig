//! Deck-declared derived layers, materialised into the store the reader
//! hands back: every operation through the deck text and the flattener,
//! `with_text`, `in_cells`, a store built in memory, and base layouts
//! written out as GDSII and read back. Ported from crates/ingest/src/layout.rs's
//! in-file tests and tests/derived_layers.rs; the GDS writer's round trip
//! from crates/testgen/src/gds.rs.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const testgen = @import("testgen");
const paths = @import("paths");
const fx = @import("layout_fixture.zig");
const fixture = ingest.gds_fixture;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const gpa = testing.allocator;

/// `STRANS` bit 0, from the spec.
const reflect: u16 = 0x8000;

/// A deck declaring `diff_active = diff NOT poly` over two base layers.
const subtraction_deck =
    \\grid 1nm
    \\layer diff = gds(2, 0)
    \\layer poly = gds(3, 0)
    \\layer diff_active = diff not poly
    \\
;

/// A parsed deck, its strings and its arena.
const Deck = struct {
    state: *std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    deck: ingest.deck.Deck,

    fn init(text: []const u8) !Deck {
        const state = try gpa.create(std.heap.ArenaAllocator);
        state.* = .init(gpa);
        var d: Deck = .{ .state = state, .deck = undefined };
        d.deck = try fx.parseDeck(state.allocator(), text, &d.strings);
        return d;
    }

    fn deinit(d: *Deck) void {
        d.strings.deinit(gpa);
        d.state.deinit();
        gpa.destroy(d.state);
    }

    fn id(d: *const Deck, name: []const u8) LayerId {
        return d.deck.layers.id(&d.strings, name).?;
    }

    /// Reads `cells` against this deck into `r`.
    fn read(d: *const Deck, r: *fx.Read, cells: []const fixture.Cell) !void {
        const bytes = try fixture.library(gpa, cells, 1e-9);
        defer gpa.free(bytes);
        try r.run(bytes, &d.deck.layers, .reject);
    }

    /// Writes a base-layer store out as GDSII and reads it back into `r`.
    fn roundTrip(d: *const Deck, r: *fx.Read, store: *const GeometryStore) !void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try testgen.gds.writeStore(gpa, store, &d.deck.layers, "TOP", &bytes);
        try r.run(bytes.items, &d.deck.layers, .reject);
    }
};

/// A store of `rects` (`layer, xlo, ylo, xhi, yhi`) over `layer_count` layers.
const Base = struct {
    store: GeometryStore = .empty,

    fn init(layer_count: u32, rects: []const struct { LayerId, i64, i64, i64, i64 }) !Base {
        var lb: testgen.shapes.LayoutBuilder = .init(@intCast(layer_count));
        defer lb.deinit(gpa);
        for (rects) |r| _ = try lb.rect(gpa, @backingInt(r[0]), r[1], r[2], r[3], r[4]);
        var b: Base = .{};
        var ids: testgen.shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &b.store, &ids);
        return b;
    }

    fn deinit(b: *Base) void {
        b.store.deinit(gpa);
    }
};

// ---- private ----

fn lid(i: u16) LayerId {
    return @fromBackingInt(i);
}

/// Twice-area sum over a layer's rows, halved: the layer's area, holes
/// (clockwise rows) subtracted.
fn area(store: *const GeometryStore, layer: LayerId) i128 {
    var twice: i128 = 0;
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |row| {
        const v = store.polyVerts(@fromBackingInt(@intCast(row)));
        twice += geom.ops.area2(v.xs, v.ys);
    }
    return @divExact(twice, 2);
}

/// Every row's box on one layer as `xlo ylo xhi yhi`, ascending by row (or
/// sorted), in `a`.
fn boxes(a: std.mem.Allocator, store: *const GeometryStore, layer: LayerId, sorted: bool) ![]const [4]i64 {
    const rows = store.polysOnLayer(layer);
    const out = try a.alloc([4]i64, rows.len());
    for (out, rows.start..) |*o, row| {
        const b = store.polyBbox(@fromBackingInt(@intCast(row)));
        o.* = .{ b.xlo, b.ylo, b.xhi, b.yhi };
    }
    if (sorted) std.mem.sortUnstable([4]i64, out, {}, struct {
        fn less(_: void, p: [4]i64, q: [4]i64) bool {
            return std.mem.lessThan(i64, &p, &q);
        }
    }.less);
    return out;
}

fn expectBoxes(want: []const [4]i64, got: []const [4]i64) !void {
    try testing.expectEqualSlices([4]i64, want, got);
}

fn square(comptime half: i32) fixture.Boundary {
    return .{ .layer = 1, .datatype = 0, .xs = &.{ -half, half, half, -half }, .ys = &.{ -half, -half, half, half } };
}

test "every derived operation reads through the deck into the store" {
    // Oracle: hand-derived. `met1` is an L: a 4 um arm [0,4]x[0,10] and a 2 um
    // arm [0,10]x[0,2] (um); `met2` holds s1 inside the L, s2 touching its 4 um
    // arm from outside, s3 far away, and s4 straddling the 2 um arm's end. Each
    // derived layer's areas and lengths are worked out from those coordinates
    // under the operation's definition in docs/src/reference/deck/layers.md
    // (Operations on polygon layers).
    var d: Deck = try .init(
        \\grid 1nm
        \\layer met1 = gds(68, 20)
        \\layer met2 = gds(69, 20)
        \\layer huge = met1.sized(-1um).sized(1um)
        \\layer near = met2.interacting(met1)
        \\layer apart = met2.not_interacting(met1)
        \\layer inner = met2.inside(met1)
        \\layer out = met2.outside(met1)
        \\layer big = met2.with_area(>= 4um2)
        \\layer small = met2.with_area(< 4um2)
        \\layer narrow = met1.with_width(< 3um)
        \\layer box = met1.extents()
        \\layer gaps = met1.holes()
        \\layer e = met1.edges()
        \\layer e_in = e.inside_part(met2)
        \\layer long = e.with_length(>= 10um)
        \\rule huge.w width(huge) >= 1um
        \\
    );
    defer d.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try d.read(&r, &.{.{ .name = "TOP", .boundaries = &.{
        .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 10000, 10000, 4000, 4000, 0 }, .ys = &.{ 0, 0, 2000, 2000, 10000, 10000 } },
        .{ .layer = 69, .datatype = 20, .xs = &.{ 1000, 3000, 3000, 1000 }, .ys = &.{ 5000, 5000, 7000, 7000 } },
        .{ .layer = 69, .datatype = 20, .xs = &.{ 4000, 6000, 6000, 4000 }, .ys = &.{ 3000, 3000, 5000, 5000 } },
        .{ .layer = 69, .datatype = 20, .xs = &.{ 20000, 21000, 21000, 20000 }, .ys = &.{ 0, 0, 1000, 1000 } },
        .{ .layer = 69, .datatype = 20, .xs = &.{ 8000, 12000, 12000, 8000 }, .ys = &.{ -1000, -1000, 1000, 1000 } },
    } }});
    const s = &r.store;
    const um2: i128 = 1_000_000;
    const count = struct {
        fn of(st: *const GeometryStore, l: LayerId) u32 {
            return st.polysOnLayer(l).len();
        }
    }.of;
    try testing.expectEqual(40 * um2, area(s, d.id("huge")));
    try testing.expectEqual(3, count(s, d.id("near")));
    try testing.expectEqual(16 * um2, area(s, d.id("near")));
    try testing.expectEqual(1, count(s, d.id("apart")));
    try testing.expectEqual(um2, area(s, d.id("apart")));
    try testing.expectEqual(1, count(s, d.id("inner")));
    try testing.expectEqual(4 * um2, area(s, d.id("inner")));
    try testing.expectEqual(2, count(s, d.id("out")));
    try testing.expectEqual(5 * um2, area(s, d.id("out")));
    try testing.expectEqual(3, count(s, d.id("big")));
    try testing.expectEqual(1, count(s, d.id("small")));
    try testing.expectEqual(52 * um2, area(s, d.id("narrow")));
    try testing.expectEqual(100 * um2, area(s, d.id("box")));
    try testing.expectEqual(0, count(s, d.id("gaps")));

    const length = struct {
        fn of(st: *const GeometryStore, l: LayerId) i64 {
            var total: i64 = 0;
            for (st.edgesOnLayer(l)) |e| total += @intCast(@abs(e.b.x - e.a.x) + @abs(e.b.y - e.a.y));
            return total;
        }
    }.of;
    try testing.expect(d.deck.layers.isEdges(d.id("e")) and d.deck.layers.isEdges(d.id("long")));
    try testing.expect(!d.deck.layers.isEdges(d.id("huge")));
    try testing.expectEqual(6, s.edgesOnLayer(d.id("e")).len);
    try testing.expectEqual(40_000, length(s, d.id("e")));
    try testing.expectEqual(2000 + 1000, length(s, d.id("e_in")));
    try testing.expectEqual(2, s.edgesOnLayer(d.id("long")).len);
    try testing.expectEqual(0, count(s, d.id("e")));
    const rule = d.deck.rules.spec[0];
    try testing.expectEqualSlices(LayerId, &.{d.id("huge")}, d.deck.rules.layersOf(rule));
}

test "with_text keeps the shapes holding a matching text" {
    // Oracle: construct-from-answer, under `with_text` as
    // docs/src/reference/deck/layers.md (Operations on polygon layers) defines
    // it (`*` any run, `?` one character, a text on the edge counts, `T` a
    // drawn layer): the squares at 0 and 200 hold a match, the others do not;
    // an L's notch is inside its box but off the shape, and a matching string
    // on another text layer is not read.
    var d: Deck = try .init(
        \\grid 5nm
        \\layer activ = gds(1, 0)
        \\layer text = gds(63, 0)
        \\layer other = gds(63, 25)
        \\layer npn = activ.with_text(text, "npn13G2*")
        \\layer rest = activ.without_text(text, "npn13G2*")
        \\
    );
    defer d.deinit();
    const sq = struct {
        fn at(comptime x: i32) fixture.Boundary {
            return .{ .layer = 1, .datatype = 0, .xs = &.{ x, x + 100, x + 100, x }, .ys = &.{ 0, 0, 100, 100 } };
        }
    };
    const l_shape: fixture.Boundary = .{ .layer = 1, .datatype = 0, .xs = &.{ 600, 900, 900, 700, 700, 600 }, .ys = &.{ 0, 0, 100, 100, 400, 400 } };
    var r: fx.Read = .{};
    defer r.deinit();
    try d.read(&r, &.{.{ .name = "TOP", .boundaries = &.{ sq.at(0), sq.at(200), sq.at(400), l_shape, sq.at(1_000) }, .texts = &.{
        .{ .layer = 63, .texttype = 0, .x = 50, .y = 50, .string = "npn13G2" },
        .{ .layer = 63, .texttype = 0, .x = 300, .y = 50, .string = "npn13G2L" },
        .{ .layer = 63, .texttype = 0, .x = 450, .y = 50, .string = "pnpMPA" },
        .{ .layer = 63, .texttype = 0, .x = 800, .y = 300, .string = "npn13G2" },
        .{ .layer = 63, .texttype = 25, .x = 1_050, .y = 50, .string = "npn13G2" },
    } }});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectBoxes(&.{ .{ 0, 0, 100, 100 }, .{ 200, 0, 300, 100 } }, try boxes(a, &r.store, d.id("npn"), false));
    try expectBoxes(&.{ .{ 400, 0, 500, 100 }, .{ 600, 0, 900, 400 }, .{ 1_000, 0, 1_100, 100 } }, try boxes(a, &r.store, d.id("rest"), false));
}

test "in_cells keeps the shapes under a matching cell in every orientation" {
    // Oracle: construct-from-answer under `in_cells`'s definition: the
    // `INNER` under a `PAD_A` is in `PAD_*`, the one `TOP` places is not;
    // `TOP` matching makes every shape in; the glob is case-sensitive, so
    // `pad_*` holds nothing. `PAD_A` is placed in all eight orientations and
    // once magnified (the per-element path rather than the per-placement
    // one); every square is centred on its cell's origin.
    var d: Deck = try .init(
        \\grid 1nm
        \\layer m = gds(1, 0)
        \\layer pad = m.in_cells("PAD_*")
        \\layer rest = m.not_in_cells("PAD_*")
        \\layer every = m.in_cells("core", "T?P")
        \\layer nothing = m.in_cells("pad_*")
        \\
    );
    defer d.deinit();
    var refs: [11]fixture.Ref = undefined;
    for (0..8) |i| refs[i] = .{ .cell = "PAD_A", .strans = if (i < 4) 0 else reflect, .angle = @floatFromInt((i % 4) * 90), .x = @intCast(1_000 * (i + 1)) };
    refs[8] = .{ .cell = "PAD_A", .x = 9_000, .mag = 2 };
    refs[9] = .{ .cell = "core", .y = 3_000 };
    refs[10] = .{ .cell = "INNER", .y = 6_000 };
    const top_square: fixture.Boundary = .{ .layer = 1, .datatype = 0, .xs = &.{ 4_990, 5_010, 5_010, 4_990 }, .ys = &.{ 4_990, 4_990, 5_010, 5_010 } };
    var r: fx.Read = .{};
    defer r.deinit();
    try d.read(&r, &.{
        .{ .name = "TOP", .boundaries = &.{top_square}, .refs = &refs },
        .{ .name = "PAD_A", .boundaries = &.{square(50)}, .refs = &.{.{ .cell = "INNER" }} },
        .{ .name = "core", .boundaries = &.{square(30)} },
        .{ .name = "INNER", .boundaries = &.{square(20)} },
    });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const at = struct {
        fn box(x: i64, y: i64, half: i64) [4]i64 {
            return .{ x - half, y - half, x + half, y + half };
        }
    }.box;
    var pad: std.ArrayList([4]i64) = .empty;
    for (1..9) |i| try pad.appendSlice(a, &.{ at(@intCast(1_000 * i), 0, 50), at(@intCast(1_000 * i), 0, 20) });
    try pad.appendSlice(a, &.{ at(9_000, 0, 100), at(9_000, 0, 40) });
    const rest = [_][4]i64{ at(5_000, 5_000, 10), at(0, 3_000, 30), at(0, 6_000, 20) };
    var all: std.ArrayList([4]i64) = .empty;
    try all.appendSlice(a, pad.items);
    try all.appendSlice(a, &rest);
    const lessBox = struct {
        fn less(_: void, p: [4]i64, q: [4]i64) bool {
            return std.mem.lessThan(i64, &p, &q);
        }
    }.less;
    std.mem.sortUnstable([4]i64, pad.items, {}, lessBox);
    var rest_sorted = rest;
    std.mem.sortUnstable([4]i64, &rest_sorted, {}, lessBox);
    std.mem.sortUnstable([4]i64, all.items, {}, lessBox);
    try expectBoxes(pad.items, try boxes(a, &r.store, d.id("pad"), true));
    try expectBoxes(&rest_sorted, try boxes(a, &r.store, d.id("rest"), true));
    try expectBoxes(all.items, try boxes(a, &r.store, d.id("every"), true));
    try expectBoxes(&.{}, try boxes(a, &r.store, d.id("nothing"), true));
}

test "a store built in memory is in no cell" {
    // Oracle: `DerivedOp.in_cells`'s doc and `deriveLayersInto`'s, which
    // state this case: a row past the tags is in no cell, so `in_cells`
    // selects nothing and `not_in_cells` the whole layer.
    var d: Deck = try .init("grid 1nm\nlayer m = gds(1, 0)\nlayer sel = m.in_cells(\"*\")\nlayer unsel = m.not_in_cells(\"*\")\n");
    defer d.deinit();
    var base: Base = try .init(d.deck.layers.len(), &.{.{ lid(0), 0, 0, 100, 100 }});
    defer base.deinit();
    const nothing: ingest.Provenance = .{};
    try ingest.layout.deriveLayersInto(gpa, &base.store, &d.deck.layers, &nothing, &d.strings, &.{});
    try testing.expectEqual(0, base.store.polysOnLayer(d.id("sel")).len());
    try testing.expectEqual(1, base.store.polysOnLayer(d.id("unsel")).len());
}

test "a deck-declared subtraction lands in the store as real polygons" {
    // Oracle: construct-from-answer. One diffusion rectangle crossed by one
    // gate is two source/drain regions: `(0,0)-(500,200)` minus
    // `(200,-50)-(250,750)` is `(0,0)-(200,200)` and `(250,0)-(500,200)`.
    var d: Deck = try .init(subtraction_deck);
    defer d.deinit();
    try testing.expectEqual(3, d.deck.layers.len());
    try testing.expect(d.deck.layers.isDerived(lid(2)));
    try testing.expect(!d.deck.layers.isDerived(lid(0)) and !d.deck.layers.isDerived(lid(1)));
    var base: Base = try .init(3, &.{ .{ lid(0), 0, 0, 500, 200 }, .{ lid(1), 200, -50, 250, 750 } });
    defer base.deinit();
    try testing.expectEqual(0, base.store.polysOnLayer(lid(2)).len());
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &base.store);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectBoxes(&.{.{ 0, 0, 500, 200 }}, try boxes(a, &r.store, lid(0), false));
    try expectBoxes(&.{.{ 200, -50, 250, 750 }}, try boxes(a, &r.store, lid(1), false));
    try expectBoxes(&.{ .{ 0, 0, 200, 200 }, .{ 250, 0, 500, 200 } }, try boxes(a, &r.store, lid(2), false));
}

test "a derived layer may be built on an earlier derived layer" {
    // Oracle: construct-from-answer. Base layers ascending by name: diff 0,
    // poly 1, window 2; derived after them: diff_active 3, sd_in_window 4,
    // which reads diff_active, not the base layer it was built from.
    var d: Deck = try .init(
        \\grid 1nm
        \\layer diff = gds(2, 0)
        \\layer poly = gds(3, 0)
        \\layer window = gds(4, 0)
        \\layer diff_active = diff not poly
        \\layer sd_in_window = diff_active and window
        \\
    );
    defer d.deinit();
    var base: Base = try .init(d.deck.layers.len(), &.{ .{ lid(0), 0, 0, 500, 200 }, .{ lid(1), 200, -50, 250, 750 }, .{ lid(2), 100, 0, 400, 200 } });
    defer base.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &base.store);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try expectBoxes(&.{ .{ 0, 0, 200, 200 }, .{ 250, 0, 500, 200 } }, try boxes(arena.allocator(), &r.store, lid(3), false));
    try expectBoxes(&.{ .{ 100, 0, 200, 200 }, .{ 250, 0, 400, 200 } }, try boxes(arena.allocator(), &r.store, lid(4), false));
}

test "a derived layer with nothing under it is empty rather than absent" {
    // Oracle: construct-from-answer. A derived layer over a layer the layout
    // does not draw is a layer with no polygons, never a missing layer.
    var d: Deck = try .init(subtraction_deck);
    defer d.deinit();
    var base: Base = try .init(3, &.{.{ lid(1), 200, -50, 250, 750 }});
    defer base.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &base.store);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try expectBoxes(&.{.{ 200, -50, 250, 750 }}, try boxes(arena.allocator(), &r.store, lid(1), false));
    try testing.expectEqual(0, r.store.polysOnLayer(lid(0)).len());
    try testing.expectEqual(0, r.store.polysOnLayer(lid(2)).len());
}

test "no gds stream pair maps onto a derived layer" {
    // Oracle: construct-from-answer. A derived layer has no GDS stream pair,
    // so no record in a layout file may map onto one, not even its
    // placeholder pair.
    var d: Deck = try .init(subtraction_deck);
    defer d.deinit();
    const layers = &d.deck.layers;
    try testing.expectEqual(lid(0), layers.ofStream(2, 0).?);
    try testing.expectEqual(lid(1), layers.ofStream(3, 0).?);
    for (0..9) |l| for (0..9) |dt| {
        try testing.expect(layers.ofStream(@intCast(l), @intCast(dt)) != lid(2));
    };
    try testing.expectEqual(null, layers.ofStream(std.math.maxInt(u16), std.math.maxInt(u16)));
}

test "a ring on a derived layer keeps its hole" {
    // Oracle: construct-from-answer. Four diffusion bands closing into a guard
    // ring become one derived polygon with a hole; the two islands drawn
    // inside the hole touch nothing, so the layer is three polygons, the
    // ring's hole a clockwise row, and no island on the ring's material.
    // The net half of Rust's test (three nets) is tests/check/derived_layers.zig.
    var d: Deck = try .init(
        \\grid 1nm
        \\layer diff = gds(2, 0)
        \\layer poly = gds(3, 0)
        \\layer sd = diff not poly
        \\connect conductors [sd]
        \\connect touch_within_layer
        \\
    );
    defer d.deinit();
    var base: Base = try .init(d.deck.layers.len(), &.{
        .{ lid(0), 0, 0, 2000, 200 },    .{ lid(0), 0, 1800, 2000, 2000 },
        .{ lid(0), 0, 200, 200, 1800 },  .{ lid(0), 1800, 200, 2000, 1800 },
        .{ lid(0), 500, 500, 700, 700 }, .{ lid(0), 1200, 1200, 1400, 1400 },
    });
    defer base.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &base.store);
    var valid: geom.ValidatedLayer = .empty;
    defer valid.deinit(gpa);
    try testing.expectEqual(null, try geom.view.validateLayer(gpa, &r.store, lid(2), .rectilinear, &valid));
    try testing.expectEqual(3, valid.len());
    var holed: u32 = 0;
    for (0..valid.len()) |i| {
        const p = valid.get(@intCast(i));
        if (p.ringCount() == 1) continue;
        holed += 1;
        try testing.expectEqual(2, p.ringCount());
        try testing.expectEqual(2000 * 2000 - 1600 * 1600, testgen.shapes.polygonArea(p));
    }
    try testing.expectEqual(1, holed);
}

test "a sky130 diode's layers derive as the shipped deck states" {
    // Oracle: construct-from-answer, on the shipped sky130 deck: a 1 um x 1 um
    // n+ diffusion is `nsd`, the p-tap beside it is `ptap` and `psub_tie`
    // (joining the substrate), and the p-tap inside deep n-well is `ptap`
    // and `pwell_iso_tie` but not `psub_tie`: an isolated p-well. The device
    // half of Rust's `a_sky130_pw2nd_diode_has_its_anode_on_the_substrate`
    // (the diode's terminals, area and perimeter) is
    // tests/check/derived_layers.zig.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/pdks/sky130.deck", .{paths.root});
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena.allocator(), .unlimited);
    var d: Deck = try .init(text);
    defer d.deinit();
    var base: Base = try .init(d.deck.layers.len(), &.{
        .{ d.id("diff"), 0, 0, 1_000, 1_000 },          .{ d.id("nsdm"), -200, -200, 1_200, 1_200 },
        .{ d.id("areaid_diode"), 0, 0, 1_000, 1_000 },  .{ d.id("tap"), 2_000, 0, 2_500, 1_000 },
        .{ d.id("psdm"), 1_900, -100, 2_600, 1_100 },   .{ d.id("dnwell"), 10_000, 0, 16_000, 6_000 },
        .{ d.id("tap"), 12_000, 2_000, 12_500, 3_000 }, .{ d.id("psdm"), 11_900, 1_900, 12_600, 3_100 },
    });
    defer base.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &base.store);
    const a = arena.allocator();
    try expectBoxes(&.{.{ 0, 0, 1_000, 1_000 }}, try boxes(a, &r.store, d.id("nsd"), true));
    try expectBoxes(&.{ .{ 2_000, 0, 2_500, 1_000 }, .{ 12_000, 2_000, 12_500, 3_000 } }, try boxes(a, &r.store, d.id("ptap"), true));
    try expectBoxes(&.{.{ 2_000, 0, 2_500, 1_000 }}, try boxes(a, &r.store, d.id("psub_tie"), true));
    try expectBoxes(&.{.{ 12_000, 2_000, 12_500, 3_000 }}, try boxes(a, &r.store, d.id("pwell_iso_tie"), true));
}
