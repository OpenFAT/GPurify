//! The layout fuzz targets' oracles: raw bytes → the GDSII reader, a
//! hierarchy decoded from the bytes, a LEF/DEF pair, a bitmap DRC case →
//! each target's law, an error naming the input when broken. Ported from
//! fuzz/oracles.rs (`gds`, `gds_structured`, `lefdef`, `drc_e2e`).
//!
//! Contents:
//! - `pub fn gds(gpa: Allocator, data: []const u8) !void`
//! - `pub fn gdsStructured(gpa: Allocator, data: []const u8) !void`
//! - `pub fn lefdef(gpa: Allocator, data: []const u8) !void`
//! - `pub fn drcE2e(gpa: Allocator, data: []const u8) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const Library = ingest.gds.Library;
const LayerTable = ingest.deck.LayerTable;
const testgen = @import("testgen");
const fuzz = @import("fuzz.zig");
const ensure = fuzz.ensure;
const Bytes = fuzz.Bytes;
const harness = @import("harness.zig");
const bitmap = @import("bitmap.zig");
/// The deepest placement chain the reader accepts, root included.
const max_depth = ingest.layout.max_hierarchy_depth;

/// Layers 0/0 to 15/0, plus three derived layers so booleans and sizing
/// meet whatever geometry the fuzzer draws.
const gds_deck =
    \\grid 1nm
    \\layer l0 = gds(0, 0)
    \\layer l1 = gds(1, 0)
    \\layer l2 = gds(2, 0)
    \\layer l3 = gds(3, 0)
    \\layer l4 = gds(4, 0)
    \\layer l5 = gds(5, 0)
    \\layer l6 = gds(6, 0)
    \\layer l7 = gds(7, 0)
    \\layer l8 = gds(8, 0)
    \\layer l9 = gds(9, 0)
    \\layer l10 = gds(10, 0)
    \\layer l11 = gds(11, 0)
    \\layer l12 = gds(12, 0)
    \\layer l13 = gds(13, 0)
    \\layer l14 = gds(14, 0)
    \\layer l15 = gds(15, 0)
    \\layer joined = l1 or l2
    \\layer cut = l1 not l2
    \\layer grown = l3.sized(10nm)
    \\
;

/// The farthest a bitmap case is moved: its cells span at most 500 nm, so
/// every vertex stays inside a 32-bit GDSII coordinate.
const reach: i64 = std.math.maxInt(i32) - 1000;

/// A flattened, derived store with what flattening also fills; `gpa` owns it.
const Flat = struct {
    store: GeometryStore = .empty,
    provenance: ingest.Provenance = .{},
    tags: std.ArrayList(u64) = .empty,

    fn deinit(f: *Flat, gpa: Allocator) void {
        f.store.deinit(gpa);
        f.provenance.deinit(gpa);
        f.tags.deinit(gpa);
    }

    /// Flattens `lib` through `layers` as a run reads a layout, then derives.
    fn read(f: *Flat, gpa: Allocator, lib: *const Library, layers: *const LayerTable, strings: *const StrTable, unknown: ingest.layout.UnknownLayers) ingest.gds.Error!void {
        var diag: ingest.gds.Diagnostic = .{};
        try ingest.layout.flattenInto(gpa, lib, layers, strings, unknown, .top, &f.store, &f.provenance, &f.tags, &diag);
        try ingest.layout.deriveLayersInto(gpa, &f.store, layers, &f.provenance, strings, f.tags.items);
    }
};

/// A hierarchy decoded from the input, with what flattening it must give,
/// computed from the decoded structures alone.
const Hierarchy = struct {
    cells: std.ArrayList(testgen.gds.Structure) = .empty,
    /// Each cell's children, one entry per placement: child, copy count, magnification.
    children: std.ArrayList([]const Child) = .empty,
    /// Each cell's own rectangle count and area.
    own: std.ArrayList([2]u128) = .empty,
    /// The extra chain's length: cells that only place the next, the last
    /// placing cell 0.
    chain: usize = 0,
};

const Child = struct { cell: usize, copies: u128, mag: u128 };

/// What one cell of an acyclic `Hierarchy` flattens to.
const Total = struct {
    /// Levels from the cell down, itself included.
    depth: usize,
    /// Polygons.
    count: u128,
    /// Total area, in square database units.
    area: u128,
    /// Placements walked, the cell's own included, none into a subtree
    /// holding no polygon.
    visits: u128,
};

/// `gds.Library.parse` on arbitrary bytes.
///
/// Oracle: a typed error, never a crash or a leak; flattening within
/// `flatBudget`; and a layout that flattens and can be written back (every
/// coordinate in 32 bits, every ring, holes slit in, in one record) reads
/// back to the same store, holes and derived layers included.
pub fn gds(gpa: Allocator, data: []const u8) !void {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.gds.Diagnostic = .{};
    var lib = Library.parse(gpa, data, &strings, &diag) catch return;
    defer lib.deinit(gpa);
    _ = lib.grid(&diag) catch {};
    const deck = try parseDeck(arena, gpa, gds_deck, 1000, &strings);
    const polygons = ingest.layout.flatPolygons(gpa, &lib, &diag) catch return;
    if (polygons > flatBudget(data.len)) return;
    var flat: Flat = .{};
    defer flat.deinit(gpa);
    flat.read(gpa, &lib, &deck.layers, &strings, .drop) catch return;

    var bytes: std.ArrayList(u8) = .empty;
    testgen.gds.writeStore(arena, &flat.store, &deck.layers, "TOP", &bytes) catch return;
    var again: StrTable = .empty;
    const reread = Library.parse(arena, bytes.items, &again, &diag) catch |err| return ensure(false, "a written store does not parse: {t}", .{err});
    const deck2 = try parseDeck(arena, arena, gds_deck, 1000, &again);
    var round: Flat = .{};
    round.read(arena, &reread, &deck2.layers, &again, .reject) catch |err| return ensure(false, "a written store does not flatten: {t}", .{err});
    try ensure(sameStore(&flat.store, &round.store), "parse -> write -> parse changed the store", .{});
}

/// An arbitrary hierarchy written with the test GDS writer and read back.
///
/// Oracle: no stack overflow; any cycle, reached from a root or not, is
/// `CyclicHierarchy` (`HierarchyTooDeep` only where a chain past the cap
/// precedes it); a chain past the cap is `HierarchyTooDeep`; more than
/// `max_flat_polygons` is `TooManyPolygons` with the count; otherwise the
/// flat count is Σ instances × shapes and the flat area Σ instances × mag²
/// × area, both computed from the decoded structures, and every flat ring
/// is counter-clockwise. An array of a cell holding nothing costs nothing
/// to flatten: the walk is bounded by the placements that reach a polygon.
pub fn gdsStructured(gpa: Allocator, data: []const u8) !void {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    var b: Bytes = .{ .rest = data };
    const h = try hierarchy(arena, &b);
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeLibrary(arena, h.cells.items, &bytes);
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.gds.Diagnostic = .{};
    var lib = try Library.parse(gpa, bytes.items, &strings, &diag);
    defer lib.deinit(gpa);
    const deck = try parseDeck(arena, gpa, "grid 1nm\nlayer a = gds(1, 0)\nlayer b = gds(2, 0)\nlayer c = gds(3, 0)\n", 1000, &strings);
    const counted = ingest.layout.flatPolygons(gpa, &lib, &diag);

    if (try hasCycle(arena, &h)) {
        const deep = h.chain + h.cells.items.len > max_depth;
        const ok = if (counted) |_| false else |err| err == error.CyclicHierarchy or (deep and err == error.HierarchyTooDeep);
        return ensure(ok, "a cycle read as {any}", .{counted});
    }
    const totals = try totalsOf(arena, &h);
    const placed = try arena.alloc(bool, h.cells.items.len);
    @memset(placed, false);
    for (h.children.items) |children| for (children) |c| {
        placed[c.cell] = true;
    };
    var depth: usize = 0;
    var count: u128 = 0;
    var visits: u128 = 0;
    var area: u128 = 0;
    for (totals, placed) |t, p| if (!p) {
        depth = @max(depth, t.depth);
        count +|= t.count;
        visits +|= t.visits;
        area +|= t.area;
    };
    if (depth > max_depth) {
        const ok = if (counted) |_| false else |err| err == error.HierarchyTooDeep;
        return ensure(ok, "a chain {d} deep read as {any}", .{ depth, counted });
    }
    const saturated: u64 = std.math.cast(u64, count) orelse std.math.maxInt(u64);
    const got = counted catch |err| return ensure(false, "the flat count: {t}, want {d}", .{ err, saturated });
    try ensure(got == saturated, "the flat count: {d}, want {d}", .{ got, saturated });
    if (count > ingest.layout.max_flat_polygons) {
        var refused: Flat = .{};
        defer refused.deinit(gpa);
        var d2: ingest.gds.Diagnostic = .{};
        const result = ingest.layout.flattenInto(gpa, &lib, &deck.layers, &strings, .reject, .top, &refused.store, &refused.provenance, &refused.tags, &d2);
        const refusal = if (result) |_| false else |err| err == error.TooManyPolygons;
        return ensure(refusal and d2.count == saturated, "{d} polygons read as {any} (count {d})", .{ count, result, d2.count });
    }
    // Legal, but more than a fuzz run should expand: the polygons, or the
    // placements walked to reach them (depth times polygons at most).
    if (count > 1 << 16 or visits > 1 << 20) return;
    var flat: Flat = .{};
    defer flat.deinit(gpa);
    flat.read(gpa, &lib, &deck.layers, &strings, .reject) catch |err| return ensure(false, "an acyclic hierarchy in range does not flatten: {t}", .{err});
    try ensure(flat.store.polyCount() == count, "{d} flat polygons, want {d}", .{ flat.store.polyCount(), count });
    var twice: i128 = 0;
    for (0..flat.store.polyCount()) |row| {
        const v = flat.store.polyVerts(@fromBackingInt(@as(u32, @intCast(row))));
        const a2 = geom.ops.area2(v.xs, v.ys);
        try ensure(a2 > 0, "row {d} is not counter-clockwise", .{row});
        twice += a2;
    }
    try ensure(twice == 2 * area, "the flat area: twice {d}, want twice {d}", .{ twice, area });
}

/// A LEF and a DEF, split at the input's first `END LIBRARY` (the LEF's
/// last statement; the DEF is the whole input when there is none), read
/// at the DEF's units, flattened, written as GDSII on a deck that declares
/// every LEF layer, and read back.
///
/// Oracle: a typed error, never a crash, at each step; a stream `toGds`
/// writes is one the GDS reader parses, on the DEF's grid, and its
/// flattening holds every rectangle the design drew (round trip).
pub fn lefdef(gpa: Allocator, data: []const u8) !void {
    const lefdef_ = ingest.lefdef;
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const split = std.mem.indexOf(u8, data, "END LIBRARY");
    const lef_text = if (split) |at| data[0..at] else "";
    const def_text = if (split) |at| data[at + "END LIBRARY".len ..] else data;
    var diag: lefdef_.Diagnostic = .{};
    const dbu = lefdef_.defUnits(arena, def_text, &diag) catch return;
    var lef: lefdef_.Lef = .{};
    lefdef_.readLefInto(arena, lef_text, dbu, &lef, &diag) catch return;
    const def = lefdef_.readDef(arena, def_text, &lef, &diag) catch return;
    const flat = lefdef_.flatten(arena, &def, &lef, &diag) catch return;
    // A deck of every layer name the design draws on, when each is a deck name.
    var names: std.ArrayList([]const u8) = .empty;
    for (flat) |s| {
        for (names.items) |n| (if (std.mem.eql(u8, n, s.shape.layer)) break) else try names.append(arena, s.shape.layer);
    }
    if (names.items.len == 0 or names.items.len > 1000) return;
    var source: std.ArrayList(u8) = .empty;
    for (names.items, 1..) |n, i| {
        if (!deckName(n)) return;
        try source.print(arena, "layer {s} = gds({d}, 0)\n", .{ n, i });
    }
    _ = geom.Grid.init(dbu) catch return;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const deck = parseDeck(arena, gpa, source.items, dbu, &strings) catch return;
    const bytes = lefdef_.toGds(gpa, flat, dbu, def.design, &deck.layers, &deck.connectivity, &strings, &diag) catch return;
    defer gpa.free(bytes);
    var gdiag: ingest.gds.Diagnostic = .{};
    var lib = Library.parse(gpa, bytes, &strings, &gdiag) catch |err| return ensure(false, "toGds writes a stream the reader refuses: {t}", .{err});
    defer lib.deinit(gpa);
    const grid = lib.grid(&gdiag) catch |err| return ensure(false, "toGds writes no grid: {t}", .{err});
    try ensure(grid.dbu_per_um == dbu, "the stream's grid is {d} per um, the DEF's {d}", .{ grid.dbu_per_um, dbu });
    var read: Flat = .{};
    defer read.deinit(gpa);
    read.read(gpa, &lib, &deck.layers, &strings, .reject) catch return;
    var rects: u32 = 0;
    for (flat) |s| {
        const b = s.shape.bbox();
        if (s.shape.ring.len != 4 or b[0] >= b[2] or b[1] >= b[3]) continue;
        rects += for (s.shape.ring) |p| (if ((p[0] != b[0] and p[0] != b[2]) or (p[1] != b[1] and p[1] != b[3])) break 0) else 1;
    }
    try ensure(read.store.polyCount() >= rects, "{d} rectangles drawn, {d} polygons read back", .{ rects, read.store.polyCount() });
}

/// One case of the bitmap reference DRC under any of the eight symmetries
/// and any translation in the GDSII range, through the real reader and
/// engine.
///
/// Oracle: the bitmap reference (bitmap.zig), written from each rule's doc
/// comment; a case marked with an open finding is skipped.
pub fn drcE2e(gpa: Allocator, data: []const u8) !void {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    var b: Bytes = .{ .rest = data };
    const fixture = try bitmap.case(arena, b.int(u32)) orelse return;
    if (fixture.known != null) return;
    const symmetry = harness.Symmetry.all[b.byte() % 8];
    const dx = std.math.clamp(@as(i64, b.int(i32)), -reach, reach);
    const dy = std.math.clamp(@as(i64, b.int(i32)), -reach, reach);
    const moved = try fixture.transformed(arena, symmetry, dx, dy);
    var broken: std.ArrayList([]const u8) = .empty;
    try harness.brokenInto(arena, &moved, harness.run(arena, &moved), &broken);
    try ensure(broken.items.len == 0, "{s}: {s}", .{ moved.name, try std.mem.join(arena, "; ", broken.items) });
}

// ---- private ----

/// Deck text on a `dbu_per_um` grid.
fn parseDeck(arena: Allocator, gpa: Allocator, source: []const u8, dbu_per_um: i64, strings: *StrTable) !ingest.deck.Deck {
    var diag: ingest.deck.Diag = .{};
    return ingest.deck.parseDeck(arena, gpa, source, try .init(dbu_per_um), strings, &diag);
}

/// The most polygons a fuzz input may flatten to: 64 per input byte. A
/// small file can legally place 2^28 polygons, which no fuzz run has
/// memory for; the count is taken before expanding.
fn flatBudget(input: usize) u64 {
    return 64 * @as(u64, input) + 4096;
}

/// Whether two stores hold the same rows, in the same order, on the same layers.
fn sameStore(a: *const GeometryStore, b: *const GeometryStore) bool {
    if (a.layerCount() != b.layerCount() or a.polyCount() != b.polyCount()) return false;
    for (0..a.layerCount()) |l| {
        const layer: geom.LayerId = @fromBackingInt(@as(u16, @intCast(l)));
        if (!std.meta.eql(a.polysOnLayer(layer), b.polysOnLayer(layer))) return false;
    }
    for (0..a.polyCount()) |p| {
        const row: geom.PolyId = @fromBackingInt(@as(u32, @intCast(p)));
        if (!std.mem.eql(i64, a.polyVerts(row).xs, b.polyVerts(row).xs) or !std.mem.eql(i64, a.polyVerts(row).ys, b.polyVerts(row).ys)) return false;
    }
    return true;
}

/// Up to 8 cells of up to 3 rectangles and 3 placements each (any cell,
/// itself included; up to 256 × 256 arrays; mirror, quarter turns, mag 1
/// or 2), plus a chain of up to 1199 cells above cell 0, read in Rust's
/// byte order so a crasher replays the same hierarchy. Offsets and steps
/// are 16-bit, so every coordinate stays far inside the reader's range.
fn hierarchy(arena: Allocator, b: *Bytes) !Hierarchy {
    const n: usize = 1 + b.byte() % 8;
    var h: Hierarchy = .{ .chain = b.int(u16) % 1200 };
    for (0..n) |i| {
        var rects: std.ArrayList(@typeInfo(@FieldType(testgen.gds.Structure, "rects")).pointer.child) = .empty;
        var area: u128 = 0;
        for (0..b.byte() % 4) |_| {
            const layer: u16 = 1 + b.byte() % 3;
            const x: i32 = b.int(i16);
            const y: i32 = b.int(i16);
            const w: i32 = 1 + @as(i32, b.byte());
            const tall: i32 = 1 + @as(i32, b.byte());
            area += @intCast(w * tall);
            try rects.append(arena, .{ layer, 0, .{ x, y, x + w, y + tall } });
        }
        var refs: std.ArrayList(testgen.gds.Placement) = .empty;
        var children: std.ArrayList(Child) = .empty;
        for (0..b.byte() % 4) |_| {
            const child = b.byte() % n;
            const flags = b.byte();
            const mag: u32 = 1 + (flags >> 2 & 1);
            const at: [2]i32 = .{ b.int(i16), b.int(i16) };
            const array: ?testgen.gds.Array = if (flags & 8 != 0) .{
                .cols = 1 + @as(u16, b.byte()),
                .rows = 1 + @as(u16, b.byte()),
                .col_step = .{ b.int(i16), b.int(i16) },
                .row_step = .{ b.int(i16), b.int(i16) },
            } else null;
            const copies: u128 = if (array) |a| @as(u128, a.cols) * a.rows else 1;
            try children.append(arena, .{ .cell = child, .copies = copies, .mag = mag });
            try refs.append(arena, .{ .cell = try std.fmt.allocPrint(arena, "C{d}", .{child}), .reflect = flags & 1 != 0, .quarter_turns = @intCast(flags >> 4 & 3), .mag = mag, .at = at, .array = array });
        }
        try h.own.append(arena, .{ rects.items.len, area });
        try h.cells.append(arena, .{ .name = try std.fmt.allocPrint(arena, "C{d}", .{i}), .rects = rects.items, .refs = refs.items });
        try h.children.append(arena, children.items);
    }
    for (0..h.chain) |j| {
        const last = j + 1 == h.chain;
        const next = if (last) "C0" else try std.fmt.allocPrint(arena, "D{d}", .{j + 1});
        const refs = try arena.dupe(testgen.gds.Placement, &.{.{ .cell = next }});
        try h.cells.append(arena, .{ .name = try std.fmt.allocPrint(arena, "D{d}", .{j}), .refs = refs });
        try h.children.append(arena, try arena.dupe(Child, &.{.{ .cell = if (last) 0 else n + j + 1, .copies = 1, .mag = 1 }}));
        try h.own.append(arena, .{ 0, 0 });
    }
    return h;
}

/// Whether any cell reaches itself; iterative, so a deep chain cannot
/// overflow the oracle's own stack.
fn hasCycle(arena: Allocator, h: *const Hierarchy) !bool {
    const State = enum { unvisited, on_path, done };
    const state = try arena.alloc(State, h.cells.items.len);
    @memset(state, .unvisited);
    var stack: std.ArrayList([2]usize) = .empty;
    for (0..state.len) |start| {
        if (state[start] != .unvisited) continue;
        try stack.append(arena, .{ start, 0 });
        state[start] = .on_path;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const children = h.children.items[top[0]];
            if (top[1] < children.len) {
                const child = children[top[1]].cell;
                top[1] += 1;
                switch (state[child]) {
                    .on_path => return true,
                    .unvisited => {
                        state[child] = .on_path;
                        try stack.append(arena, .{ child, 0 });
                    },
                    .done => {},
                }
            } else {
                state[top[0]] = .done;
                _ = stack.pop();
            }
        }
    }
    return false;
}

/// For an acyclic hierarchy, what each cell flattens to: a post-order over
/// every cell, saturating.
fn totalsOf(arena: Allocator, h: *const Hierarchy) ![]const Total {
    const len = h.cells.items.len;
    const out = try arena.alloc(Total, len);
    const seen = try arena.alloc(bool, len);
    @memset(seen, false);
    var order: std.ArrayList(usize) = .empty;
    var stack: std.ArrayList(struct { usize, bool }) = .empty;
    for (0..len) |start| {
        try stack.append(arena, .{ start, false });
        while (stack.pop()) |top| {
            if (top[1]) {
                try order.append(arena, top[0]);
            } else if (!seen[top[0]]) {
                seen[top[0]] = true;
                try stack.append(arena, .{ top[0], true });
                for (h.children.items[top[0]]) |c| try stack.append(arena, .{ c.cell, false });
            }
        }
    }
    for (order.items) |cell| {
        var t: Total = .{ .depth = 1, .count = h.own.items[cell][0], .area = h.own.items[cell][1], .visits = 1 };
        for (h.children.items[cell]) |c| {
            const below = out[c.cell];
            t.depth = @max(t.depth, below.depth + 1);
            t.count +|= c.copies *| below.count;
            t.area +|= c.copies *| (c.mag * c.mag) *| below.area;
            // Flattening does not walk a subtree with no polygon in it.
            if (below.count > 0) t.visits +|= c.copies *| below.visits;
        }
        out[cell] = t;
    }
    return out;
}

/// Whether `n` is a deck layer name: a letter, then letters, digits and `_`.
fn deckName(n: []const u8) bool {
    if (n.len == 0 or !std.ascii.isAlphabetic(n[0])) return false;
    for (n) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
