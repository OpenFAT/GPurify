//! Black boxes: a parsed `Library` and the deck's `lvs blackbox` cell-name
//! globs → every placement of a matching cell in the root frame (its name,
//! the extent of everything under it, its own `TEXT`s placed as pins),
//! written into a `Provenance`'s box tables. The geometry is untouched:
//! flattening still draws every shape. Ported from
//! crates/ingest/src/layout.rs (`black_boxes`, `find_boxes`, `placed_box`,
//! `reach`, `transformed`).
//!
//! Contents:
//! - `pub fn blackBoxesInto(gpa: Allocator, lib: *const Library, patterns: []const []const u8, layers: *const LayerTable, strings: *const StrTable, out: *Provenance, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const StrTable = geom.StrTable;
const gds = @import("gds.zig");
const Error = gds.Error;
const Diagnostic = gds.Diagnostic;
const Library = gds.Library;
const Xform = gds.Xform;
const LayerTable = @import("deck/layers.zig").LayerTable;
const Provenance = @import("provenance.zig").Provenance;
const counting = @import("flat_count.zig");
const globMatches = @import("glob.zig").globMatches;

/// What the walk reads per cell, memoised: its extent in its own frame
/// (`xlo, ylo, xhi, yhi`; null for a cell holding no shape at any depth),
/// and whether a boxed cell is placed under it.
const Reach = struct { extent: ?[4]i64, holds_box: bool };

const Walk = struct {
    gpa: Allocator,
    lib: *const Library,
    boxed: []const bool,
    memo: []?Reach,
    layers: *const LayerTable,
    out: *Provenance,
    diag: *Diagnostic,

    /// Pushes every black box placed below `cell`, placed at `at`.
    fn find(w: Walk, cell: u32, at: Xform) Error!void {
        const entry = w.lib.cells.get(cell);
        for (entry.ref_start..entry.ref_end) |i| {
            const r = w.lib.refs.get(i);
            if (!w.boxed[r.child] and !w.reach(r.child).holds_box) continue;
            for (0..r.rows) |row| for (0..r.cols) |col| {
                const placed = at.compose(r.element(@intCast(row), @intCast(col))) orelse return error.UnsupportedTransform;
                if (w.boxed[r.child]) try w.placeBox(r.child, placed) else try w.find(r.child, placed);
            };
        }
    }

    /// One placement of the boxed `cell` at `at`, appended to the box tables.
    fn placeBox(w: Walk, cell: u32, at: Xform) Error!void {
        const p = w.out;
        const entry = w.lib.cells.get(cell);
        const extent: Bbox = if (w.reach(cell).extent) |own| blk: {
            const b = transformed(own, at) orelse return error.UnsupportedTransform;
            break :blk .{ .xlo = try inDomain(b[0], w.diag), .ylo = try inDomain(b[1], w.diag), .xhi = try inDomain(b[2], w.diag), .yhi = try inDomain(b[3], w.diag) };
        } else .empty;
        if (p.box_pin_start.items.len == 0) try p.box_pin_start.append(w.gpa, 0);
        for (entry.text_start..entry.text_end) |t| {
            const text = w.lib.texts.get(t);
            const layer = w.layers.ofStream(text.layer, text.texttype) orelse continue;
            const pt = at.apply(text.x, text.y) orelse return error.UnsupportedTransform;
            try p.box_pins_placed.append(w.gpa, .{ .x = try inDomain(pt[0], w.diag), .y = try inDomain(pt[1], w.diag), .layer = layer, .name = text.string });
        }
        try p.box_cell.append(w.gpa, entry.name);
        try p.box_extent.append(w.gpa, extent);
        try p.box_pin_start.append(w.gpa, @intCast(p.box_pins_placed.items.len));
    }

    /// `cell`'s `Reach`, memoised; the hierarchy is acyclic and depth-capped,
    /// so the recursion is bounded.
    fn reach(w: Walk, cell: u32) Reach {
        if (w.memo[cell]) |known| return known;
        const lib = w.lib;
        const entry = lib.cells.get(cell);
        var extent: ?[4]i64 = null;
        if (entry.elem_start != entry.elem_end) {
            const elems = lib.elems.slice();
            const base = elems.items(.vert_start)[entry.elem_start];
            const end = elems.items(.vert_start)[entry.elem_end - 1] + elems.items(.vert_len)[entry.elem_end - 1];
            const xs = lib.xs.items[base..end];
            const ys = lib.ys.items[base..end];
            extent = .{ std.mem.min(i64, xs), std.mem.min(i64, ys), std.mem.max(i64, xs), std.mem.max(i64, ys) };
        }
        var holds_box = false;
        for (entry.ref_start..entry.ref_end) |i| {
            const r = lib.refs.get(i);
            const child = w.reach(r.child);
            holds_box = holds_box or w.boxed[r.child] or child.holds_box;
            const own = child.extent orelse continue;
            // An array's extent is its corner elements': the steps are linear.
            const corners = [4][2]u32{ .{ 0, 0 }, .{ 0, r.cols - 1 }, .{ r.rows - 1, 0 }, .{ r.rows - 1, r.cols - 1 } };
            for (corners) |rc| {
                // An overflow cannot be placed; `placeBox` refuses it where a
                // box is placed under it.
                const b = transformed(own, r.element(rc[0], rc[1])) orelse continue;
                extent = if (extent) |e| .{ @min(e[0], b[0]), @min(e[1], b[1]), @max(e[2], b[2]), @max(e[3], b[3]) } else b;
            }
        }
        const known: Reach = .{ .extent = extent, .holds_box = holds_box };
        w.memo[cell] = known;
        return known;
    }
};

/// Every placement of a cell whose name matches one of `patterns` (whole-name
/// globs, catalog LVS-033), in walk order, into `out`'s black boxes
/// (replacing any before; its bound pins cleared): roots in file order, each
/// cell's references in order, an array row by row. A placement under
/// another such placement is part of it and not listed, and a root is never
/// a black box. Pins are the cell's own `TEXT`s on layers the deck declares.
/// From the count: `CyclicHierarchy`, `HierarchyTooDeep`; then
/// `UnsupportedTransform` or `CoordinateOutOfRange` for a placement out of
/// the domain.
pub fn blackBoxesInto(gpa: Allocator, lib: *const Library, patterns: []const []const u8, layers: *const LayerTable, strings: *const StrTable, out: *Provenance, diag: *Diagnostic) Error!void {
    try out.setBlackBoxes(gpa, &.{});
    if (patterns.len == 0) return;
    // Refuses a cycle and a chain past the cap, so the walks below recurse a
    // bounded number of levels.
    _ = try counting.flatPolygons(gpa, lib, diag);
    const boxed = try gpa.alloc(bool, lib.cells.len);
    defer gpa.free(boxed);
    for (lib.cells.items(.name), boxed) |name, *b| {
        b.* = for (patterns) |pat| {
            if (globMatches(pat, strings.resolve(name))) break true;
        } else false;
    }
    const memo = try gpa.alloc(?Reach, lib.cells.len);
    defer gpa.free(memo);
    @memset(memo, null);
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);
    try counting.rootsInto(gpa, lib, &roots);
    const w: Walk = .{ .gpa = gpa, .lib = lib, .boxed = boxed, .memo = memo, .layers = layers, .out = out, .diag = diag };
    for (roots.items) |root| try w.find(root, .identity);
}

// ---- private ----

/// `xlo, ylo, xhi, yhi` under `at`: the box of its four corners; null on overflow.
fn transformed(b: [4]i64, at: Xform) ?[4]i64 {
    var out: [4]i64 = .{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
    for ([4][2]i64{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[0], b[3] }, .{ b[2], b[3] } }) |c| {
        const p = at.apply(c[0], c[1]) orelse return null;
        out = .{ @min(out[0], p[0]), @min(out[1], p[1]), @max(out[2], p[0]), @max(out[3], p[1]) };
    }
    return out;
}

fn inDomain(v: i64, diag: *Diagnostic) Error!i64 {
    if (geom.inDomain(v)) return v;
    diag.coordinate = v;
    return error.CoordinateOutOfRange;
}
