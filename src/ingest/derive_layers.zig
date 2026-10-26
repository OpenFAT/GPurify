//! Derived layers: a store holding drawn layers only, the deck's
//! `LayerTable`, the placed labels and the rows' cell tags → every derived
//! layer computed through geom's derive operations and appended to the
//! store, one forward pass in id order (operands only name lower ids). A
//! layer that cannot be computed is left empty and marked, so only the rules
//! that read it refuse. Ported from crates/ingest/src/layout.rs
//! (`derive_layers`, `derive_layers_into`, `on_material`).
//!
//! Contents:
//! - `pub fn deriveLayersInto(gpa: Allocator, store: *GeometryStore, layers: *const LayerTable, provenance: *const Provenance, strings: *const StrTable, cell_tags: []const u64) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const Polygon = geom.Polygon;
const derive = geom.derive;
const boolean = geom.boolean;
const layers_mod = @import("deck/layers.zig");
const LayerTable = layers_mod.LayerTable;
const DerivedOp = layers_mod.DerivedOp;
const Provenance = @import("provenance.zig").Provenance;
const globMatches = @import("glob.zig").globMatches;

const Fail = error{Uncomputed} || derive.Error;

/// One pass's operands, results and reused buffers.
const Pass = struct {
    gpa: Allocator,
    store: *GeometryStore,
    layers: *const LayerTable,
    placed: std.MultiArrayList(@import("provenance.zig").PlacedLabel).Slice,
    strings: *const StrTable,
    folded: ValidatedLayer = .empty,
    operand: ValidatedLayer = .empty,
    combined: ValidatedLayer = .empty,
    raw: ValidatedLayer = .empty,
    edges: std.ArrayList(Seg) = .empty,
    edges_out: std.ArrayList(Seg) = .empty,
    /// The rings appended for the current layer, as CSR.
    xs: std.ArrayList(Dbu) = .empty,
    ys: std.ArrayList(Dbu) = .empty,
    start: std.ArrayList(u32) = .empty,
    len: std.ArrayList(u32) = .empty,

    fn deinit(d: *Pass) void {
        inline for (.{ &d.folded, &d.operand, &d.combined, &d.raw, &d.edges, &d.edges_out, &d.xs, &d.ys, &d.start, &d.len }) |t| t.deinit(d.gpa);
    }

    fn clearRings(d: *Pass) void {
        inline for (.{ &d.xs, &d.ys, &d.start, &d.len }) |t| t.clearRetainingCapacity();
    }

    fn pushRing(d: *Pass, ring: geom.Ring) Allocator.Error!void {
        try d.start.append(d.gpa, @intCast(d.xs.items.len));
        try d.len.append(d.gpa, @intCast(ring.xs.len));
        try d.xs.appendSlice(d.gpa, ring.xs);
        try d.ys.appendSlice(d.gpa, ring.ys);
    }

    /// Layer `id` validated at any angle into `out`; a defect (an
    /// uncomputed layer among them) makes the derived layer uncomputed.
    fn validated(d: *Pass, id: LayerId, out: *ValidatedLayer) Fail!void {
        if (try geom.view.validateLayer(d.gpa, d.store, id, .any, out) != null) return error.Uncomputed;
    }

    /// An operand's polygons, merged: selections and sizing read whole shapes.
    fn merged(d: *Pass, id: LayerId, out: *ValidatedLayer) Fail!void {
        try d.validated(id, &d.raw);
        try derive.mergeInto(d.gpa, &d.raw, out);
    }

    /// An edge layer's result into `edges`.
    fn edgeLayer(d: *Pass, op: DerivedOp, operands: []const LayerId) Fail!void {
        // An edge operand is read straight from the store, so its own mark
        // is checked here; a polygon operand's is checked by validation.
        for (operands) |id| if (d.store.isUncomputed(id)) return error.Uncomputed;
        const gpa = d.gpa;
        const receiver = d.store.edgesOnLayer(operands[0]);
        switch (op) {
            .edges => {
                try d.merged(operands[0], &d.folded);
                try derive.edgesInto(gpa, &d.folded, &d.edges);
            },
            .@"and", .@"or", .not => {
                const how: derive.EdgeOp = switch (op) {
                    .@"and" => .@"and",
                    .@"or" => .@"or",
                    else => .not, // the enclosing prong is these three
                };
                d.edges.clearRetainingCapacity();
                try d.edges.appendSlice(gpa, receiver);
                for (operands[1..]) |next| {
                    try derive.edgeBooleanInto(gpa, d.edges.items, d.store.edgesOnLayer(next), how, &d.edges_out);
                    std.mem.swap(std.ArrayList(Seg), &d.edges, &d.edges_out);
                }
            },
            .interacting => |keep| {
                try d.merged(operands[1], &d.operand);
                try derive.edgeInteractingInto(gpa, receiver, &d.operand, keep, &d.edges);
            },
            .part => |inside| {
                try d.merged(operands[1], &d.operand);
                try derive.edgePartInto(gpa, receiver, &d.operand, inside, &d.edges);
            },
            .with_length => |r| try derive.withLengthInto(gpa, receiver, r.lo, r.hi, &d.edges),
            .oriented => |vertical| {
                d.edges.clearRetainingCapacity();
                for (receiver) |e| {
                    if (if (vertical) e.a.x == e.b.x else e.a.y == e.b.y) try d.edges.append(gpa, e);
                }
            },
            // The parser gives an edge result only to the edge operations above.
            .sized, .inside, .outside, .overlapping, .covering, .holes, .extents, .with_area, .with_width, .with_bbox, .with_rect, .rectangles, .with_text, .texts_outside, .extended, .in_cells => unreachable,
        }
    }

    /// A polygon layer's result into `folded`.
    fn polygonLayer(d: *Pass, op: DerivedOp, operands: []const LayerId) Fail!void {
        for (operands) |id| if (d.store.isUncomputed(id)) return error.Uncomputed;
        const gpa = d.gpa;
        switch (op) {
            .@"and", .@"or", .not => {
                try d.validated(operands[0], &d.folded);
                for (operands[1..]) |next| {
                    try d.validated(next, &d.operand);
                    switch (op) {
                        .@"and" => try boolean.intersectionInto(gpa, &d.folded, &d.operand, &d.combined),
                        .@"or" => try boolean.unionInto(gpa, &d.folded, &d.operand, &d.combined),
                        else => try boolean.subtractionInto(gpa, &d.folded, &d.operand, &d.combined), // `.not`: the enclosing prong is these three
                    }
                    std.mem.swap(ValidatedLayer, &d.folded, &d.combined);
                }
            },
            .extended => |e| {
                const by: derive.Extension = .{ .begin = e.begin, .end = e.end, .outside = e.outside, .inside = e.inside };
                try derive.extendedInto(gpa, d.store.edgesOnLayer(operands[0]), by, &d.folded);
            },
            .sized, .interacting, .inside, .outside, .overlapping, .covering, .holes, .extents, .with_area, .with_width, .rectangles, .with_bbox, .with_rect, .texts_outside, .with_text => try d.selection(op, operands),
            // Edge operations: the parser never gives them a polygon result.
            .edges, .part, .with_length, .oriented, .in_cells => unreachable,
        }
    }

    /// An operation over its operands merged, into `folded`.
    fn selection(d: *Pass, op: DerivedOp, operands: []const LayerId) Fail!void {
        const gpa = d.gpa;
        try d.merged(operands[0], &d.operand);
        // `with_text` reads the texts on its layer argument, not its shapes.
        if (operands.len > 1 and op != .with_text) try d.merged(operands[1], &d.combined);
        const a = &d.operand;
        const b = &d.combined;
        const out = &d.folded;
        switch (op) {
            .sized => |s| try derive.sizedInto(gpa, a, s.dx, s.dy, out),
            .interacting => |keep| try derive.interactingInto(gpa, a, b, keep, out),
            .inside => try derive.insideInto(gpa, a, b, out),
            .outside => try derive.outsideInto(gpa, a, b, out),
            .overlapping => try derive.overlappingInto(gpa, a, b, true, out),
            .covering => |keep| try derive.coveringInto(gpa, a, b, keep, out),
            .holes => try derive.holesInto(gpa, a, out),
            .extents => try derive.extentsInto(gpa, a, out),
            .with_area => |r| try derive.withAreaInto(gpa, a, r.lo, r.hi, out),
            .with_width => |r| try derive.withWidthInto(gpa, a, r.lo, r.hi, out),
            .rectangles => |r| try derive.rectanglesInto(gpa, a, r.square, r.keep, out),
            .with_bbox => |r| try derive.withBboxInto(gpa, a, if (r.longer) .longer else .shorter, r.lo, r.hi, out),
            .with_rect => |r| try derive.withRectInto(gpa, a, r.w, r.h, r.keep, out),
            .texts_outside => try d.textsOutside(operands[0], b),
            .with_text => |t| try d.withText(operands[1], t.keep, d.layers.text(t.text)),
            // `polygonLayer` handles these, or never routes them here.
            .@"and", .@"or", .not, .extended, .edges, .part, .with_length, .oriented, .in_cells => unreachable,
        }
    }

    /// Each text on `text_layer` lying on no polygon of `b`, as a one-unit box.
    // ponytail: every text against every shape; index the points by x if a
    // layer carries thousands of texts.
    fn textsOutside(d: *Pass, text_layer: LayerId, b: *const ValidatedLayer) Fail!void {
        var boxes: std.ArrayList(Bbox) = .empty;
        defer boxes.deinit(d.gpa);
        for (d.placed.items(.x), d.placed.items(.y), d.placed.items(.layer)) |x, y, layer| {
            if (layer != text_layer) continue;
            const p: Point = .{ .x = x, .y = y };
            const on_any = for (0..b.len()) |i| {
                if (onMaterial(b.get(@intCast(i)), p)) break true;
            } else false;
            if (!on_any) try boxes.append(d.gpa, .{ .xlo = x, .ylo = y, .xhi = x + 1, .yhi = y + 1 });
        }
        try derive.boxesInto(d.gpa, boxes.items, &d.folded);
    }

    /// The polygons of `operand` holding (`keep`) or not holding a text on
    /// `text_layer` matching `pattern`.
    // ponytail: every matching text against every shape; index the points by
    // x if a layer carries thousands of texts.
    fn withText(d: *Pass, text_layer: LayerId, keep: bool, pattern: []const u8) Fail!void {
        var matching: std.ArrayList(Point) = .empty;
        defer matching.deinit(d.gpa);
        const p = d.placed;
        for (p.items(.x), p.items(.y), p.items(.layer), p.items(.name)) |x, y, layer, name| {
            if (layer == text_layer and globMatches(pattern, d.strings.resolve(name))) try matching.append(d.gpa, .{ .x = x, .y = y });
        }
        const a = &d.operand;
        const flags = try d.gpa.alloc(bool, a.len());
        defer d.gpa.free(flags);
        for (flags, 0..) |*f, i| {
            const poly = a.get(@intCast(i));
            const holds = for (matching.items) |pt| {
                if (onMaterial(poly, pt)) break true;
            } else false;
            f.* = holds == keep;
        }
        try a.selectInto(d.gpa, flags, &d.folded);
    }
};

/// Computes every derived layer of `layers` into `store`, in id order.
/// `store` was finished with `layers.len()` layers and holds shapes on drawn
/// layers only. `provenance.placed` are the texts `with_text` and
/// `texts_outside` read, named in `strings`. `cell_tags[row]` is a stored
/// row's `in_cells` tag (`flatten.flattenInto`); a row past its end, as in a
/// store built in memory, is in no cell. A layer that cannot be computed (an
/// operand that was not, `sized` past the domain, an invalid operand) is
/// marked (`GeometryStore.markUncomputed`), never an error.
pub fn deriveLayersInto(gpa: Allocator, store: *GeometryStore, layers: *const LayerTable, provenance: *const Provenance, strings: *const StrTable, cell_tags: []const u64) Allocator.Error!void {
    assert(store.layerCount() == layers.len());
    var d: Pass = .{ .gpa = gpa, .store = store, .layers = layers, .placed = provenance.placed.slice(), .strings = strings };
    defer d.deinit();
    var selection: u6 = 0;
    for (layers.derived_start..layers.len()) |i| {
        const layer: LayerId = @fromBackingInt(@as(u16, @intCast(i)));
        const op = layers.op(layer).?;
        const operands = layers.operands(layer);
        d.clearRings();
        // The receiver's rows as drawn, unmerged: a tag belongs to a drawn ring.
        if (op == .in_cells) {
            const bit = @as(u64, 1) << selection;
            selection +%= 1;
            const rows = store.polysOnLayer(operands[0]);
            for (rows.start..rows.end) |row| {
                const tagged = row < cell_tags.len and cell_tags[row] & bit != 0;
                if (tagged == op.in_cells.keep) try d.pushRing(store.polyVerts(@fromBackingInt(@intCast(row))));
            }
            try store.appendLayer(gpa, layer, d.xs.items, d.ys.items, d.start.items, d.len.items);
            continue;
        }
        const edge_layer = layers.isEdges(layer);
        const computed = if (edge_layer) d.edgeLayer(op, operands) else d.polygonLayer(op, operands);
        computed catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Uncomputed, error.NotRectilinear, error.OutOfRange, error.Invalid => {
                try store.markUncomputed(gpa, layer);
                d.folded.clear();
                d.edges.clearRetainingCapacity();
            },
        };
        if (edge_layer) {
            try store.appendEdges(gpa, layer, d.edges.items);
            continue;
        }
        // Outer first, then its holes: validation's ring order.
        for (0..d.folded.len()) |p| {
            const polygon = d.folded.get(@intCast(p));
            for (0..polygon.ringCount()) |k| try d.pushRing(polygon.ring(@intCast(k)));
        }
        try store.appendLayer(gpa, layer, d.xs.items, d.ys.items, d.start.items, d.len.items);
    }
}

// ---- private ----

/// Whether `p` lies on the polygon's material, its boundary included.
fn onMaterial(poly: Polygon, p: Point) bool {
    if (!poly.bbox().contains(.point(p.x, p.y))) return false;
    const outer = poly.outer();
    if (!geom.ops.pointInRing(outer.xs, outer.ys, p)) return false;
    for (1..poly.ringCount()) |k| {
        const hole = poly.ring(@intCast(k));
        if (geom.ops.pointInRing(hole.xs, hole.ys, p) and !onRing(hole, p)) return false;
    }
    return true;
}

fn onRing(ring: geom.Ring, p: Point) bool {
    for (0..ring.xs.len) |i| {
        if (geom.ops.pointSegDist2(p, geom.ops.ringEdge(ring.xs, ring.ys, i)) == 0) return true;
    }
    return false;
}
