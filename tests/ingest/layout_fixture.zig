//! The flatten suites' fixture: GDSII bytes from `ingest.gds_fixture` → a
//! parsed, flattened and derived store with its labels, read the way a run
//! reads a layout. Ported from the helpers of crates/ingest/src/layout.rs's
//! tests (`read`, `three_layer_deck`, `labelling_deck`, `append_array`,
//! `find_first_endstr`, `verts`, `assert_same_store`, `bound_labels`).
//!
//! Contents: `rows`, `square`, `Read` (`deinit`, `run`, `runAt`, `bind`, `boundNames`),
//! `threeLayers`, `labelling`, `parseDeck`, `appendArray`, `firstEndstr`,
//! `verts`, `expectSameStore`

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const gds = ingest.gds;
const fixture = ingest.gds_fixture;
const layout = ingest.layout;
const LayerTable = ingest.deck.LayerTable;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const PolyId = geom.PolyId;
const gpa = testing.allocator;

/// The rows every layout test is written against: `LayerId(i)` is `rows[i]`.
pub const rows = [_]struct { []const u8, u16, u16 }{ .{ "met1", 68, 20 }, .{ "via1", 67, 44 }, .{ "poly", 66, 20 } };

/// A square boundary of side 400 on the deck's first layer.
pub const square: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 400, 400, 0 }, .ys = &.{ 0, 0, 400, 400 } };

/// One library parsed, flattened under `LabelDepth.all` (so the transform
/// tests can follow a label down the hierarchy) and derived.
pub const Read = struct {
    strings: StrTable = .empty,
    diag: gds.Diagnostic = .{},
    store: GeometryStore = .empty,
    provenance: ingest.Provenance = .{},
    tags: std.ArrayList(u64) = .empty,
    unplaced: ingest.provenance.PlacedLabel = undefined,

    pub fn deinit(r: *Read) void {
        r.strings.deinit(gpa);
        r.store.deinit(gpa);
        r.provenance.deinit(gpa);
        r.tags.deinit(gpa);
    }

    pub fn run(r: *Read, bytes: []const u8, layers: *const LayerTable, unknown: layout.UnknownLayers) gds.Error!void {
        return r.runAt(bytes, layers, unknown, .all);
    }

    pub fn runAt(r: *Read, bytes: []const u8, layers: *const LayerTable, unknown: layout.UnknownLayers, depth: layout.LabelDepth) gds.Error!void {
        var lib = try gds.Library.parse(gpa, bytes, &r.strings, &r.diag);
        defer lib.deinit(gpa);
        try layout.flattenInto(gpa, &lib, layers, &r.strings, unknown, depth, &r.store, &r.provenance, &r.tags, &r.diag);
        try layout.deriveLayersInto(gpa, &r.store, layers, &r.provenance, &r.strings, r.tags.items);
    }

    /// Binds the labels; `unplaced` names a refused one.
    pub fn bind(r: *Read, connectivity: *const ingest.deck.Connectivity) ingest.LabelError!void {
        return ingest.resolveLabels(gpa, &r.provenance, &r.store, connectivity, &r.unplaced);
    }

    /// Every bound label as `row name`, in `labels` order, in `arena`.
    pub fn boundNames(r: *const Read, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (r.provenance.labels()) |l| try out.append(arena, try std.fmt.allocPrint(arena, "{d} {s}", .{ @backingInt(l.poly), r.strings.resolve(l.name) }));
        return out.items;
    }
};

/// `rows` as a layer table, interned into `strings`, in `arena`.
pub fn threeLayers(arena: std.mem.Allocator, strings: *StrTable) !LayerTable {
    var entries: [rows.len]LayerTable.Entry = undefined;
    for (rows, &entries) |r, *e| e.* = .{ .name = try strings.intern(gpa, r[0]), .layer = r[1], .datatype = r[2] };
    return LayerTable.build(arena, &entries);
}

/// `met1` 68/20 and `met1_label` 68/5, the label layer naming `met1`: the
/// pairing that makes a `TEXT` a net label rather than documentation.
pub fn labelling(arena: std.mem.Allocator, strings: *StrTable) !ingest.deck.Deck {
    const entries = [_]LayerTable.Entry{
        .{ .name = try strings.intern(gpa, "met1"), .layer = 68, .datatype = 20 },
        .{ .name = try strings.intern(gpa, "met1_label"), .layer = 68, .datatype = 5 },
    };
    const layers = try LayerTable.build(arena, &entries);
    const met1 = layers.ofStream(68, 20).?;
    const text = layers.ofStream(68, 5).?;
    return .{ .layers = layers, .connectivity = .{
        .conductors = try arena.dupe(geom.LayerId, &.{met1}),
        .label_layer = try arena.dupe(geom.LayerId, &.{text}),
        .label_names = try arena.dupe(geom.LayerId, &.{met1}),
    } };
}

/// Deck text on a 1 nm layout grid, in `arena`.
pub fn parseDeck(arena: std.mem.Allocator, text: []const u8, strings: *StrTable) !ingest.deck.Deck {
    var diag: ingest.deck.Diag = .{};
    return ingest.deck.parseDeck(arena, gpa, text, try .init(1000), strings, &diag);
}

/// Appends structure `cell` holding one `AREF` of `cols` × `rows` copies of
/// `child`, 1000 apart, to `out` (a library cut before its `ENDLIB`).
pub fn appendArray(out: *std.ArrayList(u8), cell: []const u8, child: []const u8, cols: i16, n_rows: i16) !void {
    try fixture.record(out, gpa, 0x0502, &@as([24]u8, @splat(0)));
    try asciiRecord(out, 0x0606, cell);
    try fixture.record(out, gpa, 0x0B00, &.{});
    try asciiRecord(out, 0x1206, child);
    try fixture.record(out, gpa, 0x1302, &(be(i16, cols) ++ be(i16, n_rows)));
    const pitch: i32 = 1000;
    try fixture.record(out, gpa, 0x1003, &(be(i32, 0) ++ be(i32, 0) ++ be(i32, pitch * cols) ++ be(i32, 0) ++ be(i32, 0) ++ be(i32, pitch * n_rows)));
    try fixture.record(out, gpa, 0x1100, &.{});
    try fixture.record(out, gpa, 0x0700, &.{});
}

/// The byte offset of the first `ENDSTR`, where a label belonging to the
/// first cell is spliced.
pub fn firstEndstr(bytes: []const u8) usize {
    var at: usize = 0;
    while (at + 4 <= bytes.len) {
        const len = std.mem.readInt(u16, bytes[at..][0..2], .big);
        std.debug.assert(len >= 4);
        if (std.mem.readInt(u16, bytes[at + 2 ..][0..2], .big) == 0x0700) return at;
        at += len;
    }
    unreachable; // every fixture library has a structure
}

/// Row `row`'s vertices as `x0 y0 x1 y1 ...` text, in `arena`.
pub fn verts(arena: std.mem.Allocator, store: *const GeometryStore, row: u32) ![]const u8 {
    const r = store.polyVerts(@fromBackingInt(row));
    var out: std.ArrayList(u8) = .empty;
    for (r.xs, r.ys, 0..) |x, y, i| try out.print(arena, "{s}{d} {d}", .{ if (i == 0) "" else ", ", x, y });
    return out.items;
}

/// Compares two stores row by row: counts, layer ranges, layers, boxes, vertices.
pub fn expectSameStore(left: *const GeometryStore, right: *const GeometryStore) !void {
    try testing.expectEqual(left.polyCount(), right.polyCount());
    try testing.expectEqual(left.layerCount(), right.layerCount());
    for (0..left.layerCount()) |l| {
        const layer: geom.LayerId = @fromBackingInt(@as(u16, @intCast(l)));
        try testing.expectEqual(left.polysOnLayer(layer), right.polysOnLayer(layer));
    }
    for (0..left.polyCount()) |row| {
        const poly: PolyId = @fromBackingInt(@intCast(row));
        try testing.expectEqual(left.polyLayer(poly), right.polyLayer(poly));
        try testing.expectEqual(left.polyBbox(poly), right.polyBbox(poly));
        try testing.expectEqualSlices(i64, left.polyVerts(poly).xs, right.polyVerts(poly).xs);
        try testing.expectEqualSlices(i64, left.polyVerts(poly).ys, right.polyVerts(poly).ys);
    }
}

// ---- private ----

fn be(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .big);
    return out;
}

fn asciiRecord(out: *std.ArrayList(u8), tag: u16, text: []const u8) !void {
    var padded: [64]u8 = @splat(0);
    @memcpy(padded[0..text.len], text);
    try fixture.record(out, gpa, tag, padded[0 .. text.len + text.len % 2]);
}
