//! Flatten: a parsed `Library` and the deck's `LayerTable` → one flat,
//! layer-sorted `GeometryStore` of the drawn layers, the placed `TEXT`s, and
//! each stored row's `in_cells` tag. A depth-first walk from each root in
//! file order, each cell's own shapes before its references', an array row
//! by row: that order fixes every `PolyId`, and so the report bytes. Every
//! transform is exact or refused. Derived layers come next
//! (`derive_layers.zig`), then label binding (`label_bind.zig`). Ported from
//! crates/ingest/src/layout.rs (`Library::flatten`, `flatten_labels`,
//! `Flatten::{visit, layer, place, emit_placed, emit, push}`, `shift`, `block`).
//!
//! Contents:
//! - `pub const UnknownLayers = enum { reject, drop }`, `pub const LabelDepth = enum { top, all }`
//! - `pub fn flattenInto(gpa: Allocator, lib: *const Library, layers: *const LayerTable, strings: *const StrTable, unknown: UnknownLayers, depth: LabelDepth, store: *GeometryStore, provenance: *Provenance, cell_tags: *std.ArrayList(u64), diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const gds = @import("gds.zig");
const Error = gds.Error;
const Diagnostic = gds.Diagnostic;
const Library = gds.Library;
const Xform = gds.Xform;
const LayerTable = @import("deck/layers.zig").LayerTable;
const Provenance = @import("provenance.zig").Provenance;
const counting = @import("flat_count.zig");
const globMatches = @import("glob.zig").globMatches;

/// What to do with geometry on a stream pair the deck neither declares nor
/// ignores. A pair listed with `ignore gds(L, D)` is dropped either way.
pub const UnknownLayers = enum {
    /// Refuse the layout. What a signoff run uses.
    reject,
    /// Drop the shape or label, uncounted. Not for signoff.
    drop,
};

/// Which cells' `TEXT`s are placed as labels.
pub const LabelDepth = enum {
    /// Root cells only: a sub-cell's text names a net of that sub-cell, not
    /// of the design. Calibre's `TEXT DEPTH PRIMARY` default.
    top,
    /// Every cell, transformed into the root frame; counted with the
    /// polygons and held to the same cap.
    all,
};

/// The hierarchy walk and the tables it fills.
const Walk = struct {
    gpa: Allocator,
    lib: *const Library,
    layers: *const LayerTable,
    unknown: UnknownLayers,
    depth: LabelDepth,
    provenance: *Provenance,
    diag: *Diagnostic,
    /// Each cell's flat `[polygons, texts]`.
    counts: []const [2]u64,
    builder: geom.GeometryStoreBuilder = .empty,
    /// Each cell's own tag; empty when the deck makes no `in_cells`
    /// selection, and then nothing is tagged.
    own: std.ArrayList(u64) = .empty,
    /// The tag of the current placement path: its cells' own tags, or-ed.
    tag: u64 = 0,
    /// One tag per pushed ring, in arrival order, while `own` is not empty.
    tags: std.ArrayList(u64) = .empty,
    /// Each cell's largest |coordinate| over its own elements, 0 for none.
    max_coord: std.ArrayList(u64) = .empty,
    /// `emit`'s placed vertices, before the domain check.
    rx: std.ArrayList(i64) = .empty,
    ry: std.ArrayList(i64) = .empty,
    /// The placed vertices `push` reads.
    tx: std.ArrayList(Dbu) = .empty,
    ty: std.ArrayList(Dbu) = .empty,

    fn deinit(w: *Walk) void {
        inline for (.{ &w.builder, &w.own, &w.tags, &w.max_coord, &w.rx, &w.ry, &w.tx, &w.ty }) |list| list.deinit(w.gpa);
    }

    /// Emits one cell's geometry under `at`, then recurses into its
    /// references. Labels are placed when `root`, or under `.all`. The count
    /// refused cycles and chains past the cap, so recursion is bounded.
    fn visit(w: *Walk, cell: u32, at: Xform, root: bool, level: u32) Error!void {
        assert(level <= counting.max_hierarchy_depth);
        const parent = w.tag;
        if (w.own.items.len != 0) w.tag |= w.own.items[cell];
        const entry = w.lib.cells.get(cell);
        if (!try w.emitPlaced(entry.elem_start, entry.elem_end, w.max_coord.items[cell], at)) {
            for (entry.elem_start..entry.elem_end) |e| try w.emit(@intCast(e), at);
        }
        if (root or w.depth == .all) {
            for (entry.text_start..entry.text_end) |t| try w.place(@intCast(t), at);
        }
        const refs = w.lib.refs.slice();
        for (entry.ref_start..entry.ref_end) |i| {
            const r = refs.get(i);
            // Below the root only polygons are placed, and texts under
            // `.all`: a cell holding neither, at any depth, is not walked,
            // since an array of an empty cell is up to 32767² placements.
            const c = w.counts[r.child];
            if (c[0] == 0 and (w.depth == .top or c[1] == 0)) continue;
            for (0..r.rows) |row| for (0..r.cols) |col| {
                const placed = at.compose(r.element(@intCast(row), @intCast(col))) orelse return error.UnsupportedTransform;
                try w.visit(r.child, placed, false, level + 1);
            };
        }
        w.tag = parent;
    }

    /// The deck layer for a stream pair; null drops it. A pair the deck
    /// ignores is dropped whatever `unknown` says.
    fn layer(w: *const Walk, stream: u16, datatype: u16) Error!?LayerId {
        if (w.layers.ofStream(stream, datatype)) |id| return id;
        if (w.layers.isIgnored(stream, datatype)) return null;
        switch (w.unknown) {
            .reject => {
                w.diag.stream = .{ stream, datatype };
                return error.UnknownLayer;
            },
            .drop => return null,
        }
    }

    /// Transforms text `t`'s point into the root frame and records it.
    fn place(w: *Walk, t: u32, at: Xform) Error!void {
        const text = w.lib.texts.get(t);
        const id = try w.layer(text.layer, text.texttype) orelse return;
        const p = at.apply(text.x, text.y) orelse return error.UnsupportedTransform;
        try w.provenance.placeLabel(w.gpa, .{ .x = try inDomain(p[0], w.diag), .y = try inDomain(p[1], w.diag), .layer = id, .name = text.string });
    }

    /// One placement's elements `first..past` at once: their vertex runs are
    /// one contiguous block of `lib.xs`, whose largest |coordinate| is
    /// `max_coord`. False leaves it to per-element `emit` (magnified, or a
    /// bound this cannot prove), which reports any error exactly.
    // ponytail: a CPU loop per placement. GPU path when a profile asks: per-cell
    // vertex counts → exclusive scan of placements → one vertex-map kernel.
    fn emitPlaced(w: *Walk, first: u32, past: u32, max_coord: u64, at: Xform) Error!bool {
        if (first == past) return true;
        if (at.mag != 1) return false;
        // With mag 1 every output is ±one input + d, so |out| <= max|in| + |d|.
        const reach = @addWithOverflow(max_coord, @max(@abs(at.dx), @abs(at.dy)));
        if (reach[1] != 0 or reach[0] > geom.max_abs_dbu) return false;
        const elems = w.lib.elems.slice();
        const base = elems.items(.vert_start)[first];
        const end = elems.items(.vert_start)[past - 1] + elems.items(.vert_len)[past - 1];
        const xs = w.lib.xs.items[base..end];
        const ys = w.lib.ys.items[base..end];
        // A quarter turn swaps the axes.
        const l = at.linear();
        if (l[0] == 0) {
            try shiftInto(w.gpa, ys, l[1] < 0, at.dx, &w.tx);
            try shiftInto(w.gpa, xs, l[2] < 0, at.dy, &w.ty);
        } else {
            try shiftInto(w.gpa, xs, l[0] < 0, at.dx, &w.tx);
            try shiftInto(w.gpa, ys, l[3] < 0, at.dy, &w.ty);
        }
        for (first..past) |e| {
            const id = try w.layer(elems.items(.layer)[e], elems.items(.datatype)[e]) orelse continue;
            const start = elems.items(.vert_start)[e] - base;
            try w.push(id, start, start + elems.items(.vert_len)[e], at.flip);
        }
        return true;
    }

    /// Transforms element `e` into the root frame and pushes it.
    fn emit(w: *Walk, e: u32, at: Xform) Error!void {
        const elem = w.lib.elems.get(e);
        const id = try w.layer(elem.layer, elem.datatype) orelse return;
        const xs = w.lib.xs.items[elem.vert_start..][0..elem.vert_len];
        const ys = w.lib.ys.items[elem.vert_start..][0..elem.vert_len];
        w.rx.clearRetainingCapacity();
        w.ry.clearRetainingCapacity();
        var worst: u64 = 0;
        for (xs, ys) |x, y| {
            const p = at.apply(x, y) orelse return error.UnsupportedTransform;
            worst = @max(worst, @abs(p[0]), @abs(p[1]));
            try w.rx.append(w.gpa, p[0]);
            try w.ry.append(w.gpa, p[1]);
        }
        // The ±max_abs_dbu bound every downstream i128 product rests on.
        if (worst > geom.max_abs_dbu) {
            for (w.rx.items) |v| _ = try inDomain(v, w.diag);
            for (w.ry.items) |v| _ = try inDomain(v, w.diag);
            unreachable; // `worst` is one of the columns' values
        }
        try w.tx.resize(w.gpa, w.rx.items.len);
        try w.ty.resize(w.gpa, w.ry.items.len);
        @memcpy(w.tx.items, w.rx.items);
        @memcpy(w.ty.items, w.ry.items);
        try w.push(id, 0, @intCast(w.tx.items.len), at.flip);
    }

    /// Pushes `tx/ty[from..to]` as one ring. A mirror turns a
    /// counter-clockwise ring clockwise, which validation reads as a hole:
    /// reverse `[1..]` in place, so vertex 0, the report point, stays put.
    fn push(w: *Walk, id: LayerId, from: u32, to: u32, flip: bool) Error!void {
        const xs = w.tx.items[from..to];
        const ys = w.ty.items[from..to];
        if (flip) {
            std.mem.reverse(Dbu, xs[1..]);
            std.mem.reverse(Dbu, ys[1..]);
        }
        _ = try w.builder.push(w.gpa, id, xs, ys);
        if (w.own.items.len != 0) try w.tags.append(w.gpa, w.tag);
    }
};

/// Resolves the hierarchy into `store` (replaced; `layers.len()` layers,
/// derived ones empty), placing labels into `provenance.placed` (cleared and
/// refilled) and each stored row's cell tag into `cell_tags` (cleared and
/// refilled): bit `k` when a cell on its placement path matches the deck's
/// `k`th `in_cells` selection, empty when the deck makes none. A root is a
/// structure no reference names; several roots all flatten, each at the
/// origin. A placement of a cell holding nothing the walk would emit is
/// skipped, never expanded. `strings` is read for `in_cells` names, never
/// written.
///
/// From the count, before anything is expanded: `CyclicHierarchy`,
/// `HierarchyTooDeep`, `TooManyPolygons`, then (under `.all`)
/// `TooManyLabels`. While placing: `UnknownLayer` (under `.reject`),
/// `UnsupportedTransform`, `CoordinateOutOfRange`.
pub fn flattenInto(
    gpa: Allocator,
    lib: *const Library,
    layers: *const LayerTable,
    strings: *const StrTable,
    unknown: UnknownLayers,
    depth: LabelDepth,
    store: *GeometryStore,
    provenance: *Provenance,
    cell_tags: *std.ArrayList(u64),
    diag: *Diagnostic,
) Error!void {
    var counts: std.ArrayList([2]u64) = .empty;
    defer counts.deinit(gpa);
    const total = try counting.flatCountsInto(gpa, lib, &counts, diag);
    if (total[0] > counting.max_flat_polygons) {
        diag.count = total[0];
        return error.TooManyPolygons;
    }
    if (depth == .all and total[1] > counting.max_flat_polygons) {
        diag.count = total[1];
        return error.TooManyLabels;
    }

    var w: Walk = .{ .gpa = gpa, .lib = lib, .layers = layers, .unknown = unknown, .depth = depth, .provenance = provenance, .counts = counts.items, .diag = diag };
    defer w.deinit();
    try ownTags(gpa, lib, layers, strings, &w.own);
    try maxCoords(gpa, lib, &w.max_coord);
    try w.builder.ensureUnusedCapacity(gpa, lib.elems.len, lib.xs.items.len);
    provenance.placed.clearRetainingCapacity();

    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);
    try counting.rootsInto(gpa, lib, &roots);
    for (roots.items) |root| try w.visit(root, .identity, true, 1);

    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try w.builder.finish(gpa, @intCast(layers.len()), store, &order);
    cell_tags.clearRetainingCapacity();
    if (w.tags.items.len == 0) return;
    try cell_tags.resize(gpa, order.items.len);
    for (order.items, cell_tags.items) |old, *tag| tag.* = w.tags.items[old];
}

// ---- private ----

/// `out = ±src + d`, negated when `neg`; the caller has proven every result
/// in the domain. The sign is chosen outside the loop, so each arm is a
/// branch-free pass the vectorizer takes.
fn shiftInto(gpa: Allocator, src: []const i64, neg: bool, d: i64, out: *std.ArrayList(Dbu)) Allocator.Error!void {
    try out.resize(gpa, src.len);
    if (neg) {
        for (src, out.items) |v, *o| o.* = d - v;
    } else {
        for (src, out.items) |v, *o| o.* = v + d;
    }
}

/// `v` as a coordinate, refused outside ±`max_abs_dbu`.
fn inDomain(v: i64, diag: *Diagnostic) Error!Dbu {
    if (geom.inDomain(v)) return v;
    diag.coordinate = v;
    return error.CoordinateOutOfRange;
}

/// Each cell's tag into `own`: bit `k` when its name matches one of the
/// deck's `k`th `in_cells` selection's patterns. Empty without a selection.
fn ownTags(gpa: Allocator, lib: *const Library, layers: *const LayerTable, strings: *const StrTable, own: *std.ArrayList(u64)) Allocator.Error!void {
    own.clearRetainingCapacity();
    var any = false;
    for (layers.derived_ops.items) |op| any = any or op == .in_cells;
    if (!any) return;
    for (lib.cells.items(.name)) |name_id| {
        const name = strings.resolve(name_id);
        var tag: u64 = 0;
        var k: u6 = 0;
        for (layers.derived_ops.items) |op| {
            if (op != .in_cells) continue;
            for (layers.cellSelection(op)) |pattern| {
                if (globMatches(pattern, name)) tag |= @as(u64, 1) << k;
            }
            k +%= 1;
        }
        try own.append(gpa, tag);
    }
}

/// Each cell's largest |coordinate| over its own elements into `out`, 0 for
/// none: placed unmagnified, no vertex moves further than that plus the
/// translation.
fn maxCoords(gpa: Allocator, lib: *const Library, out: *std.ArrayList(u64)) Allocator.Error!void {
    const elems = lib.elems.slice();
    try out.resize(gpa, lib.cells.len);
    for (lib.cells.items(.elem_start), lib.cells.items(.elem_end), out.items) |first, past, *m| {
        m.* = 0;
        if (first == past) continue;
        const base = elems.items(.vert_start)[first];
        const end = elems.items(.vert_start)[past - 1] + elems.items(.vert_len)[past - 1];
        for (lib.xs.items[base..end], lib.ys.items[base..end]) |x, y| m.* = @max(m.*, @abs(x), @abs(y));
    }
}
