//! Flat counts: a parsed `Library`'s hierarchy → how many polygons and texts
//! each cell flattens to, counted without expanding anything, and its roots.
//! Refuses a reference cycle and a chain past the depth cap, so every later
//! walk of the hierarchy recurses a bounded number of levels. Ported from
//! crates/ingest/src/layout.rs (`flat_counts`, `flat_count`, `flat_polygons`,
//! `roots`, `MAX_HIERARCHY_DEPTH`, `MAX_FLAT_POLYGONS`).
//!
//! Contents:
//! - `pub const max_hierarchy_depth`, `pub const max_flat_polygons`
//! - `pub fn flatPolygons(gpa: Allocator, lib: *const Library, diag: *Diagnostic) Error!u64`
//! - `pub fn flatCountsInto(gpa: Allocator, lib: *const Library, counts: *std.ArrayList([2]u64), diag: *Diagnostic) Error![2]u64`
//! - `pub fn rootsInto(gpa: Allocator, lib: *const Library, out: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const gds = @import("gds.zig");
const Error = gds.Error;
const Diagnostic = gds.Diagnostic;
const Library = gds.Library;

/// The deepest placement chain a layout may have, root included. Every walk
/// recurses once per level; real layouts nest tens of levels.
pub const max_hierarchy_depth: u32 = 1024;

/// The most polygons (and, under `LabelDepth.all`, labels) a layout may
/// flatten to. A 32767 × 32767 array is 10⁹ polygons per shape in it, past
/// the `u32` polygon ids; 2²⁸ is about 20 GB of flat geometry.
// ponytail: a flat cap; checking hierarchically, without flattening, is the
// upgrade that lifts it.
pub const max_flat_polygons: u64 = 1 << 28;

/// A cell's flat counts and how many levels it spans, itself included;
/// `levels == 0` until counted.
const Counted = struct { count: [2]u64, levels: u32 };

const Walk = struct {
    lib: *const Library,
    memo: []Counted,
    on_chain: []bool,
    diag: *Diagnostic,

    /// `cell`'s counts, memoised with its levels, so a cell first met
    /// shallow and met again at `depth` is held to the depth cap as walking
    /// it again would be.
    fn count(w: Walk, cell: u32, depth: u32) Error!Counted {
        const known = w.memo[cell];
        if (known.levels != 0) {
            if (depth + known.levels - 1 > max_hierarchy_depth) return w.refuse(error.HierarchyTooDeep, cell);
            return known;
        }
        if (w.on_chain[cell]) return w.refuse(error.CyclicHierarchy, cell);
        if (depth > max_hierarchy_depth) return w.refuse(error.HierarchyTooDeep, cell);
        w.on_chain[cell] = true;
        const entry = w.lib.cells.get(cell);
        var c: Counted = .{ .count = .{ entry.elem_end - entry.elem_start, entry.text_end - entry.text_start }, .levels = 1 };
        const refs = w.lib.refs.slice();
        for (entry.ref_start..entry.ref_end) |r| {
            const below = try w.count(refs.items(.child)[r], depth + 1);
            const copies = @as(u64, refs.items(.rows)[r]) * refs.items(.cols)[r];
            for (&c.count, below.count) |*mine, theirs| mine.* +|= theirs *| copies;
            c.levels = @max(c.levels, below.levels + 1);
        }
        w.on_chain[cell] = false;
        w.memo[cell] = c;
        return c;
    }

    fn refuse(w: Walk, err: Error, cell: u32) Error {
        w.diag.cell = w.lib.cells.items(.name)[cell];
        return err;
    }
};

/// How many polygons flattening would produce, before derived layers and
/// keyhole splitting, counted from the hierarchy: each root's elements plus
/// each placed child's count times the placement's array size, saturating.
/// `CyclicHierarchy` for any structure that reaches itself, rooted or not,
/// and `HierarchyTooDeep`.
pub fn flatPolygons(gpa: Allocator, lib: *const Library, diag: *Diagnostic) Error!u64 {
    var counts: std.ArrayList([2]u64) = .empty;
    defer counts.deinit(gpa);
    return (try flatCountsInto(gpa, lib, &counts, diag))[0];
}

/// The roots' flat `[polygons, texts]` as `flatPolygons` counts them, and
/// each cell's into `counts` (cleared and refilled, one row per cell).
pub fn flatCountsInto(gpa: Allocator, lib: *const Library, counts: *std.ArrayList([2]u64), diag: *Diagnostic) Error![2]u64 {
    const n = lib.cells.len;
    const memo = try gpa.alloc(Counted, n);
    defer gpa.free(memo);
    @memset(memo, .{ .count = .{ 0, 0 }, .levels = 0 });
    const on_chain = try gpa.alloc(bool, n);
    defer gpa.free(on_chain);
    @memset(on_chain, false);
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);
    try rootsInto(gpa, lib, &roots);

    const w: Walk = .{ .lib = lib, .memo = memo, .on_chain = on_chain, .diag = diag };
    var total: [2]u64 = .{ 0, 0 };
    for (roots.items) |root| {
        const c = try w.count(root, 1);
        total = .{ total[0] +| c.count[0], total[1] +| c.count[1] };
    }
    // A cycle no root reaches is as malformed as one a root reaches:
    // counting what is left refuses it, and a library with no root too.
    for (memo, 0..) |m, cell| if (m.levels == 0) {
        _ = try w.count(@intCast(cell), 1);
    };
    try counts.resize(gpa, n);
    for (memo, counts.items) |m, *c| c.* = m.count;
    return total;
}

/// The cells no reference places, in file order, into `out` (cleared and
/// refilled).
pub fn rootsInto(gpa: Allocator, lib: *const Library, out: *std.ArrayList(u32)) Allocator.Error!void {
    const referenced = try gpa.alloc(bool, lib.cells.len);
    defer gpa.free(referenced);
    @memset(referenced, false);
    for (lib.refs.items(.child)) |child| referenced[child] = true;
    out.clearRetainingCapacity();
    for (referenced, 0..) |r, cell| if (!r) try out.append(gpa, @intCast(cell));
}
