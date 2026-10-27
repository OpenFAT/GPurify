//! Layer names and stream pairs → dense `LayerId`s, and back; how each derived
//! layer is computed. In: drawn `(name, layer, datatype)` rows and derived rows
//! in declaration order. Out: the `LayerTable` the flattener maps stream pairs
//! through and every rule resolves names against. Semantics of each operation:
//! docs/src/reference/deck/layers.md (Derived layers). Ported from
//! crates/ingest/src/deck/mod.rs (`LayerTable`, `DerivedOp`).
//!
//! Contents:
//! - `pub const DerivedOp = union(enum)`, `DerivedOp.makesEdges(op: DerivedOp) ?bool`, `pub const Range`
//! - `pub const max_cell_selections`
//! - `pub const LayerTable`, `LayerTable.derived_stream`,
//!   `LayerTable.build(arena: Allocator, entries: []const Entry) Allocator.Error!LayerTable`, `pub const Entry`,
//!   `LayerTable.pushDerived(t: *LayerTable, arena: Allocator, name: StrId, op: DerivedOp, operands: []const LayerId) Allocator.Error!void`,
//!   `LayerTable.len(t: *const LayerTable) u32`,
//!   `LayerTable.id(t: *const LayerTable, strings: *const StrTable, name: []const u8) ?LayerId`,
//!   `LayerTable.ofStream(t: *const LayerTable, layer: u16, datatype: u16) ?LayerId`,
//!   `LayerTable.streamOf(t: *const LayerTable, layer: LayerId) [2]u16`,
//!   `LayerTable.isIgnored(t: *const LayerTable, layer: u16, datatype: u16) bool`,
//!   `LayerTable.isDerived(t: *const LayerTable, layer: LayerId) bool`,
//!   `LayerTable.isEdges(t: *const LayerTable, layer: LayerId) bool`,
//!   `LayerTable.name(t: *const LayerTable, layer: LayerId) StrId`,
//!   `LayerTable.op(t: *const LayerTable, layer: LayerId) ?DerivedOp`,
//!   `LayerTable.operands(t: *const LayerTable, layer: LayerId) []const LayerId`,
//!   `LayerTable.derivedCount(t: *const LayerTable) u32`,
//!   `LayerTable.text(t: *const LayerTable, index: u32) []const u8`,
//!   `LayerTable.cellSelection(t: *const LayerTable, op: DerivedOp) []const []const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const testing = std.testing;

/// An inclusive bound pair in grid units (square grid units for an area);
/// a strict `>` or `<` has already moved one unit, an absent side is the
/// `i128` extreme.
pub const Range = struct { lo: i128, hi: i128 };

/// The operators a deck may spell over layers. `and`, `or` and `not` fold
/// left over every operand; every other operation takes its receiver as
/// operand 0 and its layer argument, if any, as operand 1. Touching and
/// overlapping shapes count as one shape before an operation reads them.
pub const DerivedOp = union(enum) {
    /// The area every operand covers; on edges, the parts of operand 0 on every other.
    @"and",
    /// The area any operand covers; on edges, every operand's edges, shared parts once.
    @"or",
    /// Operand 0's area minus every other's; on edges, the parts on no other.
    not,
    /// Grown by `dx` left and right and `dy` above and below, corners square
    /// (KLayout `sized(dx, dy)`); shrunk when both are negative. Never mixed sign.
    sized: struct { dx: Dbu, dy: Dbu },
    /// `interacting` (`true`): the shapes or edges of operand 0 touching or
    /// overlapping operand 1, a shared corner counting; `false` the rest.
    interacting: bool,
    /// The shapes of operand 0 entirely covered by operand 1.
    inside,
    /// The shapes of operand 0 sharing no area with operand 1.
    outside,
    /// KLayout `overlapping`: shapes of operand 0 sharing area with operand 1.
    overlapping,
    /// KLayout `covering` (`true`): shapes of operand 0 holding a whole shape
    /// of operand 1; `false` is `not_covering`.
    covering: bool,
    /// Each hole of each shape, filled.
    holes,
    /// The bounding box of each shape, one shape per box, unmerged.
    extents,
    /// The shapes whose area, holes excluded, lies in the range.
    with_area: Range,
    /// The shapes whose narrowest width has twice its square in the range.
    with_width: Range,
    /// `with_bbox_max` (`longer`) or `with_bbox_min`.
    with_bbox: struct { longer: bool, lo: i128, hi: i128 },
    /// `with_rect` (`keep`) or `without_rect`: shapes that can hold a `w` x `h` box.
    with_rect: struct { keep: bool, w: Dbu, h: Dbu },
    /// `rectangles`, `squares`, `non_rectangles`, `non_squares`.
    rectangles: struct { square: bool, keep: bool },
    /// Polygons to their boundary edges, material on the left: an edge layer.
    edges,
    /// `inside_part` (`true`) or `outside_part`, strictly.
    part: bool,
    /// The edges whose length lies in the range.
    with_length: Range,
    /// `vertical` (`true`) or `horizontal` edges.
    oriented: bool,
    /// `with_text` (`keep`) or `without_text`: shapes of operand 0 holding a
    /// `TEXT` drawn on operand 1 matching pattern `text`.
    with_text: struct { keep: bool, text: u32 },
    /// Each `TEXT` on operand 0 lying on no shape of operand 1, as a one-unit box.
    texts_outside,
    /// KLayout `extended` on an edge layer: one box per edge.
    extended: struct { begin: Dbu, end: Dbu, outside: Dbu, inside: Dbu },
    /// `in_cells` (`keep`) or `not_in_cells`: drawn shapes of operand 0 placed
    /// under a cell matching one of patterns `first..first + count`.
    in_cells: struct { keep: bool, first: u32, count: u32 },

    /// Whether the result is edges: set when the op decides, null when it
    /// keeps its receiver's kind.
    pub fn makesEdges(op: DerivedOp) ?bool {
        return switch (op) {
            .edges => true,
            .sized, .inside, .outside, .overlapping, .covering, .holes, .extents, .with_area, .with_width, .rectangles, .with_bbox, .with_rect, .with_text, .texts_outside, .extended, .in_cells => false,
            .@"and", .@"or", .not, .interacting, .part, .with_length, .oriented => null,
        };
    }
};

/// The most `in_cells` and `not_in_cells` selections a deck may hold: each
/// is one bit of the 64-bit tag a flattened shape carries.
pub const max_cell_selections = 64;

/// Layer names and stream pairs to ids. Drawn layers come first, ascending
/// by name bytes; derived layers follow in declaration order, each computed
/// only from lower ids. A nested expression's inner operations add hidden
/// layers (`x#1`), and a layer expression inside a rule one named
/// `<rule id>@k`. Every list lives in the deck's arena.
pub const LayerTable = struct {
    /// `LayerId(i)` is named `names[i]`.
    names: std.ArrayList(StrId) = .empty,
    /// GDS layer/datatype per id; `derived_stream` for a derived layer.
    streams: std.ArrayList([2]u16) = .empty,
    /// Drawn ids sorted by `(stream pair, id)`: a shared pair answers the lowest id.
    by_stream: std.ArrayList(LayerId) = .empty,
    /// The first derived id, and so the number of drawn layers.
    derived_start: u16 = 0,
    /// How each derived layer is computed, in id order.
    derived_ops: std.ArrayList(DerivedOp) = .empty,
    /// Derived row `k`'s operands are `operand_ids[operand_start[k]..operand_start[k + 1]]`.
    operand_start: std.ArrayList(u32) = .empty,
    operand_ids: std.ArrayList(LayerId) = .empty,
    /// The text and cell-name patterns `with_text` and `in_cells` name.
    texts: std.ArrayList([]const u8) = .empty,
    /// Stream pairs the deck drops (`ignore gds(L, D)`), sorted; never declared.
    ignored: std.ArrayList([2]u16) = .empty,

    /// The placeholder stream pair of a derived layer.
    pub const derived_stream: [2]u16 = .{ std.math.maxInt(u16), std.math.maxInt(u16) };

    /// A drawn layer row: its name and GDS layer/datatype.
    pub const Entry = struct { name: StrId, layer: u16, datatype: u16 };

    /// A table of drawn layers; `LayerId(i)` is `entries[i]`.
    pub fn build(arena: Allocator, entries: []const Entry) Allocator.Error!LayerTable {
        var t: LayerTable = .{ .derived_start = @intCast(entries.len) };
        for (entries, 0..) |e, i| {
            try t.names.append(arena, e.name);
            try t.streams.append(arena, .{ e.layer, e.datatype });
            try t.by_stream.append(arena, @fromBackingInt(@as(u16, @intCast(i))));
        }
        std.mem.sortUnstable(LayerId, t.by_stream.items, t.streams.items, lessByStream);
        return t;
    }

    /// Adds a derived layer above every existing id. Asserts at least one
    /// operand, each a lower id.
    pub fn pushDerived(t: *LayerTable, arena: Allocator, name_id: StrId, derived: DerivedOp, ops: []const LayerId) Allocator.Error!void {
        const next = t.len();
        assert(ops.len > 0);
        for (ops) |o| assert(@backingInt(o) < next);
        if (t.operand_start.items.len == 0) try t.operand_start.append(arena, 0);
        try t.names.append(arena, name_id);
        try t.streams.append(arena, derived_stream);
        try t.derived_ops.append(arena, derived);
        try t.operand_ids.appendSlice(arena, ops);
        try t.operand_start.append(arena, @intCast(t.operand_ids.items.len));
    }

    /// The number of layers, drawn, derived and hidden: the layer count a
    /// geometry store for this deck is built with.
    pub fn len(t: *const LayerTable) u32 {
        return @intCast(t.names.items.len);
    }

    /// Null for a name the deck does not define. Never interns.
    pub fn id(t: *const LayerTable, strings: *const StrTable, wanted: []const u8) ?LayerId {
        const s = strings.get(wanted) orelse return null;
        for (t.names.items, 0..) |n, i| if (n == s) return @fromBackingInt(@as(u16, @intCast(i)));
        return null;
    }

    /// The drawn layer a GDS pair maps to; the lowest id when two share it.
    /// Null for a pair the deck does not declare, ignored or not. O(log n).
    pub fn ofStream(t: *const LayerTable, layer: u16, datatype: u16) ?LayerId {
        const want = [2]u16{ layer, datatype };
        var lo: usize = 0;
        var hi: usize = t.by_stream.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lessPair(t.streams.items[@backingInt(t.by_stream.items[mid])], want)) lo = mid + 1 else hi = mid;
        }
        if (lo == t.by_stream.items.len) return null;
        const found = t.by_stream.items[lo];
        const s = t.streams.items[@backingInt(found)];
        return if (s[0] == layer and s[1] == datatype) found else null;
    }

    /// The GDS pair a layer writes to; a derived layer answers `derived_stream`.
    pub fn streamOf(t: *const LayerTable, layer: LayerId) [2]u16 {
        return t.streams.items[@backingInt(layer)];
    }

    /// Whether the deck drops geometry on this pair (`ignore gds(L, D)`).
    pub fn isIgnored(t: *const LayerTable, layer: u16, datatype: u16) bool {
        for (t.ignored.items) |pair| if (pair[0] == layer and pair[1] == datatype) return true;
        return false;
    }

    /// Whether the table derives this layer; an id past the table is drawn.
    pub fn isDerived(t: *const LayerTable, layer: LayerId) bool {
        const i = @backingInt(layer);
        return i >= t.derived_start and i - t.derived_start < t.derived_ops.items.len;
    }

    /// Whether this is an edge layer. Asserts the id is in the table.
    pub fn isEdges(t: *const LayerTable, layer: LayerId) bool {
        var at = layer;
        while (true) {
            const derived = t.op(at) orelse return false;
            if (derived.makesEdges()) |edges| return edges;
            at = t.operands(at)[0];
        }
    }

    /// The layer's name as the deck wrote it, or its hidden name.
    pub fn name(t: *const LayerTable, layer: LayerId) StrId {
        return t.names.items[@backingInt(layer)];
    }

    /// How a derived layer is computed; null for a drawn layer.
    pub fn op(t: *const LayerTable, layer: LayerId) ?DerivedOp {
        const i = @backingInt(layer);
        if (i < t.derived_start) return null;
        return t.derived_ops.items[i - t.derived_start];
    }

    /// The layers a derived layer is computed from, each a lower id; empty
    /// for a drawn layer.
    pub fn operands(t: *const LayerTable, layer: LayerId) []const LayerId {
        const i = @backingInt(layer);
        if (i < t.derived_start) return &.{};
        const row = i - t.derived_start;
        return t.operand_ids.items[t.operand_start.items[row]..t.operand_start.items[row + 1]];
    }

    /// How many derived layers follow the drawn ones.
    pub fn derivedCount(t: *const LayerTable) u32 {
        return @intCast(t.derived_ops.items.len);
    }

    /// Text pattern `index` of a `with_text`, or one of an `in_cells`'s.
    pub fn text(t: *const LayerTable, index: u32) []const u8 {
        return t.texts.items[index];
    }

    /// An `in_cells` op's patterns.
    pub fn cellSelection(t: *const LayerTable, derived: DerivedOp) []const []const u8 {
        const sel = derived.in_cells;
        return t.texts.items[sel.first..][0..sel.count];
    }
};

const rows = [_]struct { []const u8, u16, u16 }{ .{ "met1", 68, 20 }, .{ "via1", 67, 44 }, .{ "poly", 66, 20 } };

// ---- private ----

fn lessPair(a: [2]u16, b: [2]u16) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

fn lessByStream(streams: [][2]u16, a: LayerId, b: LayerId) bool {
    const sa = streams[@backingInt(a)];
    const sb = streams[@backingInt(b)];
    if (lessPair(sa, sb)) return true;
    if (lessPair(sb, sa)) return false;
    return @backingInt(a) < @backingInt(b);
}

fn rowsTable(arena: Allocator, strings: *StrTable) !LayerTable {
    var entries: [rows.len]LayerTable.Entry = undefined;
    for (rows, &entries) |r, *e| e.* = .{ .name = try strings.intern(testing.allocator, r[0]), .layer = r[1], .datatype = r[2] };
    return LayerTable.build(arena, &entries);
}

test "a name the deck does not declare resolves to no layer at all" {
    // Oracle: construct-from-answer. The table is built from `rows`, so each
    // name resolves to its row index, and `met9`, interned but never
    // declared, and a name never interned resolve to nothing.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(testing.allocator);
    const layers = try rowsTable(arena.allocator(), &strings);
    try testing.expectEqual(rows.len, layers.len());
    for (rows, 0..) |r, i| try testing.expectEqual(@as(LayerId, @fromBackingInt(@as(u16, @intCast(i)))), layers.id(&strings, r[0]).?);
    const stray = try strings.intern(testing.allocator, "met9");
    try testing.expectEqual(null, layers.id(&strings, "met9"));
    try testing.expectEqual(null, layers.id(&strings, "a name nothing ever interned"));
    try testing.expectEqualStrings("met9", strings.resolve(stray));
}

test "stream pairs map only where the deck declares them" {
    // Oracle: construct-from-answer. Each `rows` pair maps to its row index;
    // 69/20 is undeclared, 68/21 shares only the layer number, and 66/44
    // mixes two rows' halves, so none maps.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(testing.allocator);
    const layers = try rowsTable(arena.allocator(), &strings);
    for (rows, 0..) |r, i| try testing.expectEqual(@as(LayerId, @fromBackingInt(@as(u16, @intCast(i)))), layers.ofStream(r[1], r[2]).?);
    try testing.expectEqual(null, layers.ofStream(69, 20));
    try testing.expectEqual(null, layers.ofStream(68, 21));
    try testing.expectEqual(null, layers.ofStream(66, 44));
}
