//! Flattening a library into a store: shapes as written, keyholes, unknown
//! layers, the hierarchy caps and budgets, and the layout input exceptions.
//! Ported from crates/ingest/src/layout.rs's in-file tests. Input is
//! assembled byte by byte from the Calma stream format, so nothing here
//! reads a value out of the code under test.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const testgen = @import("testgen");
const fx = @import("layout_fixture.zig");
const gds = ingest.gds;
const fixture = ingest.gds_fixture;
const layout = ingest.layout;
const StrTable = geom.StrTable;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const Bbox = geom.Bbox;
const gpa = testing.allocator;

const first_square_bbox: Bbox = .{ .xlo = 0, .ylo = 0, .xhi = 400, .yhi = 400 };

/// The three-layer deck, its strings and an arena for the test's bytes.
const Setup = struct {
    state: *std.heap.ArenaAllocator,
    strings: StrTable = .empty,
    layers: ingest.deck.LayerTable,
    last_diag: gds.Diagnostic = .{},

    fn init() !Setup {
        const state = try gpa.create(std.heap.ArenaAllocator);
        state.* = .init(gpa);
        var s: Setup = .{ .state = state, .layers = undefined };
        s.layers = try fx.threeLayers(state.allocator(), &s.strings);
        return s;
    }

    fn deinit(s: *Setup) void {
        s.strings.deinit(gpa);
        s.state.deinit();
        gpa.destroy(s.state);
    }

    fn arena(s: *Setup) std.mem.Allocator {
        return s.state.allocator();
    }

    fn read(s: *Setup, cells: []const fixture.Cell, unknown: layout.UnknownLayers) !fx.Read {
        var r: fx.Read = .{};
        errdefer r.deinit();
        try s.readInto(&r, cells, unknown);
        return r;
    }

    fn readInto(s: *Setup, r: *fx.Read, cells: []const fixture.Cell, unknown: layout.UnknownLayers) !void {
        const bytes = try fixture.library(gpa, cells, 1e-9);
        defer gpa.free(bytes);
        try r.run(bytes, &s.layers, unknown);
    }

    /// `unit`, then `TOP` holding one `cols` × `rows` array of it.
    fn readArray(s: *Setup, unit: *const fixture.Cell, cols: i16, n_rows: i16) !fx.Read {
        var bytes = try cutLibrary(&.{unit.*});
        defer bytes.deinit(gpa);
        try fx.appendArray(&bytes, "TOP", unit.name, cols, n_rows);
        try fixture.record(&bytes, gpa, 0x0400, &.{});
        var r: fx.Read = .{};
        errdefer r.deinit();
        r.run(bytes.items, &s.layers, .reject) catch |err| {
            s.last_diag = r.diag;
            return err;
        };
        return r;
    }
};

// ---- private ----

fn pid(row: u32) PolyId {
    return @fromBackingInt(row);
}

fn lid(layer: u16) LayerId {
    return @fromBackingInt(layer);
}

fn be(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .big);
    return out;
}

/// The library of `cells` without its `ENDLIB`, to append structures to.
fn cutLibrary(cells: []const fixture.Cell) !std.ArrayList(u8) {
    const bytes = try fixture.library(gpa, cells, 1e-9);
    var list: std.ArrayList(u8) = .fromOwnedSlice(bytes);
    list.shrinkRetainingCapacity(list.items.len - 4);
    return list;
}

/// A chain of `levels` nested cells, each placing the next, the last
/// holding one square.
fn chain(a: std.mem.Allocator, levels: u32) ![]const fixture.Cell {
    const cells = try a.alloc(fixture.Cell, levels);
    for (cells, 0..) |*c, level| {
        const last = level + 1 == levels;
        c.* = .{ .name = try std.fmt.allocPrint(a, "C{d}", .{level}) };
        if (last) c.boundaries = &.{fx.square} else c.refs = try a.dupe(fixture.Ref, &.{.{ .cell = try std.fmt.allocPrint(a, "C{d}", .{level + 1}) }});
    }
    return cells;
}

/// Layer `layer` validated rectilinear; fails on a defect.
fn validated(r: *const fx.Read, layer: u16) !geom.ValidatedLayer {
    var valid: geom.ValidatedLayer = .empty;
    errdefer valid.deinit(gpa);
    try testing.expectEqual(null, try geom.view.validateLayer(gpa, &r.store, lid(layer), .rectilinear, &valid));
    return valid;
}

/// Layer 0 validates to one polygon with one hole of area `area`.
fn expectOneHoledPolygon(r: *const fx.Read, area: i128) !void {
    var valid = try validated(r, 0);
    defer valid.deinit(gpa);
    try testing.expectEqual(1, valid.len());
    try testing.expectEqual(2, valid.get(0).ringCount());
    try testing.expectEqual(area, testgen.shapes.polygonArea(valid.get(0)));
}

/// Row 0's vertices sorted: the same ring wherever it starts.
fn corners(a: std.mem.Allocator, store: *const geom.GeometryStore) ![]const [2]i64 {
    const v = store.polyVerts(pid(0));
    const out = try a.alloc([2]i64, v.xs.len);
    for (out, v.xs, v.ys) |*c, x, y| c.* = .{ x, y };
    std.mem.sortUnstable([2]i64, out, {}, struct {
        fn less(_: void, p: [2]i64, q: [2]i64) bool {
            return std.mem.lessThan(i64, &p, &q);
        }
    }.less);
    return out;
}

/// One layout stated twice: as a builder-made store, and as the GDSII
/// library holding it, non-convex and ungrouped by layer so the sort has
/// work; `tagged` adds a property to every element.
fn expectCorpus(tagged: bool) !void {
    var t: Setup = try .init();
    defer t.deinit();
    const shapes = testgen.shapes;
    const r0 = shapes.rect(0, 0, 400, 400);
    const l2 = shapes.lShape(1_000, 0, 600, 200);
    const r1 = shapes.rect(2_000, 100, 2_180, 280);
    const p0 = shapes.plusShape(4_000, 4_000, 500, 120);
    var lb: shapes.LayoutBuilder = .init(fx.rows.len);
    defer lb.deinit(gpa);
    _ = try lb.shape(gpa, 0, r0);
    _ = try lb.shape(gpa, 2, l2);
    _ = try lb.shape(gpa, 1, r1);
    _ = try lb.shape(gpa, 0, p0);
    var expected: geom.GeometryStore = .empty;
    defer expected.deinit(gpa);
    var ids: shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &expected, &ids);

    const a = t.arena();
    const layer_of = [_]u16{ 0, 2, 1, 0 };
    const cols = [_][2][]const i64{ .{ &r0[0], &r0[1] }, .{ &l2[0], &l2[1] }, .{ &r1[0], &r1[1] }, .{ &p0[0], &p0[1] } };
    var elements: [4]fixture.Boundary = undefined;
    for (&elements, layer_of, cols, 0..) |*e, l, c, i| {
        const xs = try a.alloc(i32, c[0].len);
        const ys = try a.alloc(i32, c[1].len);
        for (xs, c[0]) |*o, v| o.* = @intCast(v);
        for (ys, c[1]) |*o, v| o.* = @intCast(v);
        e.* = .{ .layer = fx.rows[l][1], .datatype = fx.rows[l][2], .xs = xs, .ys = ys };
        if (tagged) e.props = try a.dupe(fixture.Prop, &.{.{ @intCast(i + 1), try std.fmt.allocPrint(a, "element_{d}", .{i}) }});
    }
    var r = try t.read(&.{.{ .name = "TOP", .boundaries = &elements }}, .reject);
    defer r.deinit();
    try testing.expectEqual(4, r.store.polyCount());
    try fx.expectSameStore(&expected, &r.store);
}

test "a boundary reads back on the layer and at the coordinates it was written at" {
    // Oracle: construct-from-answer. The square was written at (0, 0) to
    // (400, 400) on the deck's first layer, so the store holds those four
    // vertices, without the closing point a GDSII BOUNDARY repeats, and one
    // layer range per deck layer.
    var t: Setup = try .init();
    defer t.deinit();
    var r = try t.read(&.{.{ .name = "TOP", .boundaries = &.{fx.square} }}, .reject);
    defer r.deinit();
    try testing.expectEqual(1, r.store.polyCount());
    try testing.expectEqual(fx.rows.len, r.store.layerCount());
    try testing.expectEqual(lid(0), r.store.polyLayer(pid(0)));
    try testing.expectEqualSlices(i64, &.{ 0, 400, 400, 0 }, r.store.polyVerts(pid(0)).xs);
    try testing.expectEqualSlices(i64, &.{ 0, 0, 400, 400 }, r.store.polyVerts(pid(0)).ys);
    try testing.expectEqual(first_square_bbox, r.store.polyBbox(pid(0)));
}

test "a clockwise boundary is stored as an outer, not an orphan hole" {
    // Oracle: law — a BOUNDARY's point order does not change what it denotes.
    // The same square listed clockwise and counter-clockwise validates as one
    // outer with no holes, counter-clockwise, of the same area.
    var t: Setup = try .init();
    defer t.deinit();
    const ccw: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 400, 400, 0 }, .ys = &.{ 0, 0, 400, 400 } };
    const cw: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 0, 400, 400 }, .ys = &.{ 0, 400, 400, 0 } };
    var areas: [2]i128 = undefined;
    for ([_]fixture.Boundary{ ccw, cw }, &areas) |b, *area| {
        var r = try t.read(&.{.{ .name = "TOP", .boundaries = &.{b} }}, .reject);
        defer r.deinit();
        const v = r.store.polyVerts(pid(0));
        try testing.expectEqual(geom.ops.Winding.ccw, geom.ops.windingOf(v.xs, v.ys).?);
        var valid = try validated(&r, 0);
        defer valid.deinit(gpa);
        try testing.expectEqual(1, valid.len());
        try testing.expectEqual(1, valid.get(0).ringCount());
        area.* = testgen.shapes.polygonArea(valid.get(0));
    }
    try testing.expectEqual(areas[0], areas[1]);
}

test "a keyhole boundary reads back as one polygon with its hole" {
    // Oracle: closed form — a keyhole BOUNDARY is a polygon with a hole:
    // 1000 x 1000 less 400 x 400, entered and left along y = 700. A
    // decomposition that lost the hole would still validate; only the area
    // tells the two apart.
    var t: Setup = try .init();
    defer t.deinit();
    const keyhole: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 0, 300, 300, 700, 700, 0, 0, 1000, 1000 }, .ys = &.{ 0, 700, 700, 300, 300, 700, 700, 1000, 1000, 0 } };
    var r = try t.read(&.{.{ .name = "TOP", .boundaries = &.{keyhole} }}, .reject);
    defer r.deinit();
    try testing.expectEqual(2, r.store.polyCount());
    try expectOneHoledPolygon(&r, 1000 * 1000 - 400 * 400);
}

test "a path running back over itself reads as the region it sweeps" {
    // Oracle: hand-derived. The centreline (0,0) (4000,0) (4000,3000)
    // (0,3000) (0,0), width 2000 with half-width end caps (`PATHTYPE` 2),
    // sweeps the box -1000..5000 x -1000..4000 less the hole 1000..3000 x
    // 1000..2000 the loop encloses: one polygon with one hole, area
    // 6000 x 5000 - 2000 x 1000.
    var t: Setup = try .init();
    defer t.deinit();
    const head = try fixture.library(gpa, &.{}, 1e-9);
    defer gpa.free(head);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, head[0 .. head.len - 4]);
    try fixture.record(&bytes, gpa, 0x0502, &@as([24]u8, @splat(0)));
    try fixture.record(&bytes, gpa, 0x0606, "TOP\x00");
    try fixture.record(&bytes, gpa, 0x0900, &.{});
    try fixture.record(&bytes, gpa, 0x0D02, &.{ 0, 68 });
    try fixture.record(&bytes, gpa, 0x0E02, &.{ 0, 20 });
    try fixture.record(&bytes, gpa, 0x2102, &.{ 0, 2 });
    try fixture.record(&bytes, gpa, 0x0F03, &be(i32, 2000));
    var xy: std.ArrayList(u8) = .empty;
    defer xy.deinit(gpa);
    for ([_][2]i32{ .{ 0, 0 }, .{ 4000, 0 }, .{ 4000, 3000 }, .{ 0, 3000 }, .{ 0, 0 } }) |p| try xy.appendSlice(gpa, &(be(i32, p[0]) ++ be(i32, p[1])));
    try fixture.record(&bytes, gpa, 0x1003, xy.items);
    try fixture.record(&bytes, gpa, 0x1100, &.{});
    try fixture.record(&bytes, gpa, 0x0700, &.{});
    try fixture.record(&bytes, gpa, 0x0400, &.{});
    var r: fx.Read = .{};
    defer r.deinit();
    try r.run(bytes.items, &t.layers, .reject);
    try expectOneHoledPolygon(&r, 6000 * 5000 - 2000 * 1000);
}

test "a keyhole leaving along the hole's side reads back with its hole" {
    // Oracle: `KLayout` 0.30.8 — merging this ring gives one polygon with one
    // hole of area 1 199 825 (testing-plan F2, finding N-f2-1). The poly ring
    // of `sky130_fd_sc_hd__lpflow_lsbuf_lh_isowell_tap_1` leaves its hole
    // along the hole's right side, so no vertex is revisited.
    var t: Setup = try .init();
    defer t.deinit();
    const ring: fixture.Boundary = .{
        .layer = 68,
        .datatype = 20,
        .xs = &.{ 5140, 5140, 5155, 5155, 5700, 5700, 5305, 5305, 5700, 5700, 5710, 5710, 6055, 6055, 5850, 5850, 5290, 5290 },
        .ys = &.{ 160, 1220, 1220, 2655, 2655, 2505, 2505, 1485, 1485, 4355, 4355, 4375, 4375, 4015, 4015, 1015, 1015, 160 },
    };
    var r = try t.read(&.{.{ .name = "TOP", .boundaries = &.{ring} }}, .reject);
    defer r.deinit();
    try expectOneHoledPolygon(&r, 1_199_825);
}

test "a vertex repeated at once is dropped" {
    // Oracle: closed form — a ring that repeats a vertex at once draws the
    // ring without the repeat (testing-plan F2, finding N-f2-4): gf180mcu's
    // 27 x 8 um bar with a 6 x 6 um notch, its notch corner twice in a row.
    var t: Setup = try .init();
    defer t.deinit();
    const u: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 0, 6_000, 6_000, 6_000, 8_849, 8_849, -18_151, -18_151 }, .ys = &.{ 0, 6_000, 6_000, 0, 0, 0, 8_000, 8_000, 0 } };
    var r = try t.read(&.{.{ .name = "TOP", .boundaries = &.{u} }}, .reject);
    defer r.deinit();
    try testing.expectEqual(8, r.store.polyVerts(pid(0)).xs.len);
    var valid = try validated(&r, 0);
    defer valid.deinit(gpa);
    try testing.expectEqual(27_000 * 8_000 - 6_000 * 6_000, testgen.shapes.polygonArea(valid.get(0)));
}

test "an undeclared layer is refused under reject and dropped under drop" {
    // Oracle: construct-from-answer, against the documented `UnknownLayers`:
    // the shape on 99/7, which the deck does not declare, refuses the read
    // under `Reject` naming 99/7 and is removed under `Drop`, which keeps the
    // declared square as written.
    var t: Setup = try .init();
    defer t.deinit();
    const stray: fixture.Boundary = .{ .layer = 99, .datatype = 7, .xs = &.{ 900, 1_300, 1_300, 900 }, .ys = &.{ 0, 0, 400, 400 } };
    const cells = [_]fixture.Cell{.{ .name = "TOP", .boundaries = &.{ fx.square, stray } }};
    var refused: fx.Read = .{};
    defer refused.deinit();
    try testing.expectError(error.UnknownLayer, t.readInto(&refused, &cells, .reject));
    try testing.expectEqual([2]u16{ 99, 7 }, refused.diag.stream);
    var dropped = try t.read(&cells, .drop);
    defer dropped.deinit();
    try testing.expectEqual(1, dropped.store.polyCount());
    try testing.expectEqual(lid(0), dropped.store.polyLayer(pid(0)));
    try testing.expectEqual(first_square_bbox, dropped.store.polyBbox(pid(0)));
}

test "a hierarchy deeper than the cap is refused, not overflowed" {
    // Oracle: the stated cap. A chain exactly `max_hierarchy_depth` deep
    // flattens to its one square; one level deeper is refused with an
    // error, not a stack overflow.
    var t: Setup = try .init();
    defer t.deinit();
    const cap = layout.max_hierarchy_depth;
    var r = try t.read(try chain(t.arena(), cap), .reject);
    defer r.deinit();
    try testing.expectEqual(1, r.store.polyCount());
    var deep: fx.Read = .{};
    defer deep.deinit();
    try testing.expectError(error.HierarchyTooDeep, t.readInto(&deep, try chain(t.arena(), cap + 1), .reject));
}

test "a reference cycle no root reaches is refused" {
    // Oracle: construct-from-answer. `A` and `B` place each other and no root
    // reaches them, so the hierarchy is cyclic by construction, and the
    // count's documented start after the roots is `A`.
    var t: Setup = try .init();
    defer t.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    const cells = [_]fixture.Cell{
        .{ .name = "TOP", .boundaries = &.{fx.square} },
        .{ .name = "A", .refs = &.{.{ .cell = "B" }} },
        .{ .name = "B", .refs = &.{.{ .cell = "A" }} },
    };
    try testing.expectError(error.CyclicHierarchy, t.readInto(&r, &cells, .reject));
    try testing.expectEqualStrings("A", r.strings.resolve(r.diag.cell.?));
}

test "a cell counted shallow is still held to the depth cap when reached deep" {
    // Oracle: construct-from-answer. The chain is built one level past
    // `max_hierarchy_depth` (1024), so `LEAF` reached from `C0` is past the
    // cap whatever the walk memoised from `A`; both the flat count and the
    // read must say `HierarchyTooDeep`.
    var t: Setup = try .init();
    defer t.deinit();
    const a = t.arena();
    const n = layout.max_hierarchy_depth;
    var cells: std.ArrayList(fixture.Cell) = .empty;
    try cells.append(a, .{ .name = "A", .refs = &.{.{ .cell = "LEAF" }} });
    for (0..n) |level| {
        const next = if (level + 1 == n) "LEAF" else try std.fmt.allocPrint(a, "C{d}", .{level + 1});
        try cells.append(a, .{ .name = try std.fmt.allocPrint(a, "C{d}", .{level}), .refs = try a.dupe(fixture.Ref, &.{.{ .cell = next }}) });
    }
    try cells.append(a, .{ .name = "LEAF", .boundaries = &.{fx.square} });
    const bytes = try fixture.library(a, cells.items, 1e-9);
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: gds.Diagnostic = .{};
    var lib = try gds.Library.parse(gpa, bytes, &strings, &diag);
    defer lib.deinit(gpa);
    try testing.expectError(error.HierarchyTooDeep, layout.flatPolygons(gpa, &lib, &diag));
    var r: fx.Read = .{};
    defer r.deinit();
    try testing.expectError(error.HierarchyTooDeep, r.run(bytes, &t.layers, .reject));
}

test "arrays of an empty cell are not walked" {
    // Oracle: construct-from-answer. The arrays place only the empty cell, so
    // the flat store is the one square of `SQUARE`; the test finishing at all
    // is the other half, since the placements number about 10^18.
    var t: Setup = try .init();
    defer t.deinit();
    var bytes = try cutLibrary(&.{ .{ .name = "SQUARE", .boundaries = &.{fx.square} }, .{ .name = "EMPTY" } });
    defer bytes.deinit(gpa);
    try fx.appendArray(&bytes, "MID", "EMPTY", std.math.maxInt(i16), std.math.maxInt(i16));
    try fx.appendArray(&bytes, "TOP", "MID", std.math.maxInt(i16), std.math.maxInt(i16));
    try fixture.record(&bytes, gpa, 0x0400, &.{});
    var r: fx.Read = .{};
    defer r.deinit();
    try r.runAt(bytes.items, &t.layers, .reject, .top);
    try testing.expectEqual(1, r.store.polyCount());
}

test "an array over the flat budget is refused before it is expanded" {
    // Oracle: the count, `cols × rows` squares, against `max_flat_polygons`.
    // A small array flattens to its count; the largest array GDSII can state
    // is refused before anything is expanded.
    var t: Setup = try .init();
    defer t.deinit();
    var small = try t.readArray(&.{ .name = "UNIT", .boundaries = &.{fx.square} }, 3, 2);
    defer small.deinit();
    try testing.expectEqual(6, small.store.polyCount());
    try testing.expectError(error.TooManyPolygons, t.readArray(&.{ .name = "UNIT", .boundaries = &.{fx.square} }, std.math.maxInt(i16), std.math.maxInt(i16)));
    try testing.expectEqual(32_767 * 32_767, t.last_diag.count);
}

test "an array of text over the flat budget is refused before it is expanded" {
    // Oracle: the count, `cols × rows` labels, against `max_flat_polygons`
    // (testing-plan F90): under `LabelDepth.all` an array of a cell holding
    // one `TEXT` and no polygon is walked to place its labels.
    var t: Setup = try .init();
    defer t.deinit();
    const unit: fixture.Cell = .{ .name = "UNIT", .texts = &.{.{ .layer = 68, .texttype = 20, .x = 100, .y = 100, .string = "A" }} };
    var small = try t.readArray(&unit, 3, 2);
    defer small.deinit();
    try testing.expectEqual(6, small.provenance.placed.len);
    try testing.expectError(error.TooManyLabels, t.readArray(&unit, std.math.maxInt(i16), std.math.maxInt(i16)));
    try testing.expectEqual(32_767 * 32_767, t.last_diag.count);
}

test "an ignored pair is dropped even under reject" {
    // Oracle: the deck's documented `ignore`
    // (docs/src/reference/deck/layers.md, Ignored GDS layers: an ignored pair's
    // shapes are dropped, an undeclared one refuses the layout): the
    // met1 square survives, 99/7 is dropped, 99/8 is refused.
    var t: Setup = try .init();
    defer t.deinit();
    const deck = try fx.parseDeck(t.arena(), "layer met1 = gds(68, 20)\nignore gds(99, 7)\n", &t.strings);
    const on = struct {
        fn square(dt: u16) fixture.Boundary {
            return .{ .layer = 99, .datatype = dt, .xs = &.{ 0, 400, 400, 0 }, .ys = &.{ 0, 0, 400, 400 } };
        }
    };
    const ignored = try fixture.library(t.arena(), &.{.{ .name = "TOP", .boundaries = &.{ fx.square, on.square(7) } }}, 1e-9);
    var r: fx.Read = .{};
    defer r.deinit();
    try r.run(ignored, &deck.layers, .reject);
    try testing.expectEqual(1, r.store.polyCount());
    const stray = try fixture.library(t.arena(), &.{.{ .name = "TOP", .boundaries = &.{ fx.square, on.square(8) } }}, 1e-9);
    var refused: fx.Read = .{};
    defer refused.deinit();
    try testing.expectError(error.UnknownLayer, refused.run(stray, &deck.layers, .reject));
    try testing.expectEqual([2]u16{ 99, 8 }, refused.diag.stream);
}

test "the two unknown-layer settings agree when every layer is declared" {
    // Oracle: law, as a differential between the two settings. `UnknownLayers`
    // decides only what happens to an undeclared pair, so with all three
    // layers declared `Reject` and `Drop` give the same store.
    var t: Setup = try .init();
    defer t.deinit();
    const cells = [_]fixture.Cell{.{ .name = "TOP", .boundaries = &.{
        fx.square,
        .{ .layer = 67, .datatype = 44, .xs = &.{ 900, 1_300, 1_300, 900 }, .ys = &.{ 0, 0, 400, 400 } },
        .{ .layer = 66, .datatype = 20, .xs = &.{ 0, 200, 200, 0 }, .ys = &.{ 900, 900, 1_100, 1_100 } },
    } }};
    var rejecting = try t.read(&cells, .reject);
    defer rejecting.deinit();
    var dropping = try t.read(&cells, .drop);
    defer dropping.deinit();
    try testing.expectEqual(3, rejecting.store.polyCount());
    try fx.expectSameStore(&rejecting.store, &dropping.store);
}

test "a library holding a known layout reads back as that exact store" {
    // Oracle: construct-from-answer. `corpus` states one layout twice, as a
    // store built with `LayoutBuilder` and as the GDSII library the Stream
    // Format specification says holds it; reading the second must give the
    // first, row for row.
    try expectCorpus(false);
}

test "stream properties are accepted and change no geometry" {
    // Oracle: metamorphic relation. Tagging every element of `corpus` with
    // PROPATTR/PROPVALUE records leaves the geometry alone, so the store is
    // still the builder-made store of the untagged layout.
    try expectCorpus(true);
}

test "a magnification chain past i64 is refused rather than wrapped" {
    // Oracle: hand-derived. Four levels of magnification 1e6 compose to 1e24,
    // and three put a 400 dbu vertex at 4e20 dbu; both are past i64's 9.2e18,
    // so the only correct answer is `UnsupportedTransform`.
    var t: Setup = try .init();
    defer t.deinit();
    const mag = struct {
        fn of(comptime cell: []const u8) []const fixture.Ref {
            return &.{.{ .cell = cell, .mag = 1_000_000 }};
        }
    };
    const four = [_]fixture.Cell{
        .{ .name = "TOP", .refs = mag.of("A") },       .{ .name = "A", .refs = mag.of("B") },
        .{ .name = "B", .refs = mag.of("C") },         .{ .name = "C", .refs = mag.of("D") },
        .{ .name = "D", .boundaries = &.{fx.square} },
    };
    const three = [_]fixture.Cell{ four[0], four[1], .{ .name = "B", .refs = mag.of("D") }, four[4] };
    for ([_][]const fixture.Cell{ &three, &four }) |cells| {
        var r: fx.Read = .{};
        defer r.deinit();
        try testing.expectError(error.UnsupportedTransform, t.readInto(&r, cells, .reject));
    }
}

test "each layout input exception is refused by name or read as stated" {
    // Oracle: the GDSII format (`STRNAME` once per structure; a `PATH`
    // outline at half its width from the centreline) and the documented
    // refusals; the magnified square's box by hand (3 x 100); a spike
    // encloses no area, so the region is the square. Metamorphic: adding the
    // spike leaves the square's store unchanged. The flatten half of
    // Rust's test (catalog DRC-124); the parse-level refusals are in gds.zig.
    var t: Setup = try .init();
    defer t.deinit();
    var tripled = try t.read(&.{ .{ .name = "TOP", .refs = &.{.{ .cell = "LEAF", .mag = 3 }} }, .{ .name = "LEAF", .boundaries = &.{fx.square} } }, .reject);
    defer tripled.deinit();
    try testing.expectEqual(Bbox{ .xlo = 0, .ylo = 0, .xhi = 1200, .yhi = 1200 }, tripled.store.polyBbox(pid(0)));

    // A spike out of the square's top edge and straight back encloses no
    // area: the ring is read as the region it encloses, the square.
    const spiked: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 100, 100, 50, 50, 50, 0 }, .ys = &.{ 0, 0, 100, 100, 200, 100, 100 } };
    const plain: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 100, 100, 0 }, .ys = &.{ 0, 0, 100, 100 } };
    var spike = try t.read(&.{.{ .name = "TOP", .boundaries = &.{spiked} }}, .reject);
    defer spike.deinit();
    var unspiked = try t.read(&.{.{ .name = "TOP", .boundaries = &.{plain} }}, .reject);
    defer unspiked.deinit();
    try testing.expectEqual(1, spike.store.polyCount());
    try testing.expectEqualSlices([2]i64, try corners(t.arena(), &unspiked.store), try corners(t.arena(), &spike.store));
    try testing.expectEqual(Bbox{ .xlo = 0, .ylo = 0, .xhi = 100, .yhi = 100 }, spike.store.polyBbox(pid(0)));

    // 8000 vertices, a staircase of 3999 steps closing back along the axes.
    var xs: std.ArrayList(i32) = .empty;
    var ys: std.ArrayList(i32) = .empty;
    try xs.append(t.arena(), 0);
    try ys.append(t.arena(), 0);
    for (0..3999) |s| {
        const step: i32 = @intCast(s);
        try xs.appendSlice(t.arena(), &.{ step * 10 + 10, step * 10 + 10 });
        try ys.appendSlice(t.arena(), &.{ step * 10, step * 10 + 10 });
    }
    try xs.append(t.arena(), 0);
    try ys.append(t.arena(), 3999 * 10);
    var stairs = try t.read(&.{.{ .name = "TOP", .boundaries = &.{.{ .layer = 68, .datatype = 20, .xs = xs.items, .ys = ys.items }} }}, .reject);
    defer stairs.deinit();
    try testing.expectEqual(8000, stairs.store.polyVerts(pid(0)).xs.len);
}
