//! Validation: one layer of a `GeometryStore` → a `ValidatedLayer`, one
//! outer-plus-holes polygon per counter-clockwise ring. Rings are checked
//! rectilinear (or, on request, octilinear or any-angle) and simple but where
//! a figure meets itself at a vertex; holes are bound to their containing
//! outer. Every algorithm downstream takes a validated layer, so none
//! re-checks its input. Ported from crates/geom/src/view.rs.
//!
//! Contents:
//! - `pub const Angles = enum { rectilinear, octilinear, any }`
//! - `pub const Defect = union(enum)`
//! - `pub const ValidatedLayer = struct`, `ValidatedLayer.empty`, `deinit`, `clear`,
//!   `len(l: *const ValidatedLayer) u32`, `get(l: *const ValidatedLayer, idx: u32) Polygon`,
//!   `bboxes(l: *const ValidatedLayer) []const Bbox`, `isRectilinear(l) bool`, `isOctilinear(l) bool`,
//!   `selectInto(l: *const ValidatedLayer, gpa: Allocator, keep: []const bool, out: *ValidatedLayer) Allocator.Error!void`,
//!   `copyPolygonInto(l: *const ValidatedLayer, gpa: Allocator, idx: u32, out: *ValidatedLayer) Allocator.Error!void`
//! - `pub const Polygon = struct`, `Polygon.outer(p) Ring`, `ringCount(p) u32`, `ring(p, k: u32) Ring`,
//!   `bbox(p) Bbox`, `row(p, k: u32) PolyId`, `provenance(p) PolyId`
//! - `pub fn validateLayer(gpa: Allocator, store: *const GeometryStore, layer: LayerId, angles: Angles, out: *ValidatedLayer) Allocator.Error!?Defect`
//! - `pub fn ringDefect(gpa: Allocator, xs: []const Dbu, ys: []const Dbu, poly: PolyId) Allocator.Error!?Defect`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const DbuArea = dbu.DbuArea;
const Bbox = @import("bbox.zig").Bbox;
const ids = @import("ids.zig");
const LayerId = ids.LayerId;
const PolyId = ids.PolyId;
const ops = @import("ops.zig");
const Ring = ops.Ring;
const selfIntersects = @import("simple.zig").selfIntersects;
const GeometryStore = @import("store.zig").GeometryStore;
const index = @import("index.zig");

/// Which edge directions `validateLayer` accepts. A consumer asks for the
/// widest class it measures exactly: the booleans and derived layers take
/// `.any`; what cuts a layer into rectangles asserts `isRectilinear`.
pub const Angles = enum {
    /// Horizontal and vertical edges only.
    rectilinear,
    /// Also edges at 45 degrees (`|dx| == |dy|`).
    octilinear,
    /// Every angle, as GDSII draws a curve.
    any,
};

/// Why a layer could not be validated, naming the store row (or the layer);
/// never a silently skipped row.
pub const Defect = union(enum) {
    /// Fewer than three vertices, two equal consecutive vertices, or zero
    /// signed area (a run doubling back on itself).
    degenerate: PolyId,
    /// Two non-adjacent edges share a point other than at a pinch (see
    /// `simple.selfIntersects`). Checked before the edge directions, so a
    /// skew bowtie reports this.
    self_intersecting: PolyId,
    /// A clockwise ring no counter-clockwise ring on the layer contains.
    orphan_hole: PolyId,
    /// Under `.rectilinear`, an edge neither horizontal nor vertical.
    not_rectilinear: PolyId,
    /// Under `.octilinear`, an edge at an angle other than a multiple of 45
    /// degrees.
    not_octilinear: PolyId,
    /// A derived layer that could not be computed
    /// (`GeometryStore.markUncomputed`).
    uncomputed: LayerId,
};

/// One layer's geometry, validated and grouped. Owns its coordinates: a
/// boolean produces vertices no store row holds. Ring `r` is
/// `verts_*[ring_vert_start[r]..][0..ring_vert_len[r]]`, from store row
/// `ring_poly[r]` (for a boolean result, a row of its own scratch store);
/// polygon `i` is rings `poly_ring_start[i]..][0..poly_ring_len[i]]`, the
/// outer (CCW) first, then its holes (CW) ascending by store row.
///
/// Rings are simple but at pinches, where parts of a figure meet at a vertex;
/// a hole may touch its outer, or another hole, there. A layer straight from
/// a store is not merged: overlapping shapes stay separate polygons until a
/// boolean merges them.
pub const ValidatedLayer = struct {
    verts_x: std.ArrayList(Dbu) = .empty,
    verts_y: std.ArrayList(Dbu) = .empty,
    ring_vert_start: std.ArrayList(u32) = .empty,
    ring_vert_len: std.ArrayList(u32) = .empty,
    ring_poly: std.ArrayList(PolyId) = .empty,
    poly_ring_start: std.ArrayList(u32) = .empty,
    poly_ring_len: std.ArrayList(u32) = .empty,
    poly_bbox: std.ArrayList(Bbox) = .empty,
    /// Some ring has an edge that is not horizontal or vertical.
    diagonal: bool = false,
    /// Some ring has an edge at an angle other than a multiple of 45 degrees.
    skew: bool = false,

    pub const empty: ValidatedLayer = .{};

    pub fn deinit(l: *ValidatedLayer, gpa: Allocator) void {
        inline for (@typeInfo(ValidatedLayer).@"struct".field_names) |name| {
            if (@FieldType(ValidatedLayer, name) != bool) @field(l, name).deinit(gpa);
        }
    }

    /// Empties the layer for reuse, keeping capacity.
    pub fn clear(l: *ValidatedLayer) void {
        inline for (@typeInfo(ValidatedLayer).@"struct".field_names) |name| {
            if (@FieldType(ValidatedLayer, name) != bool) @field(l, name).clearRetainingCapacity();
        }
        l.diagonal = false;
        l.skew = false;
    }

    /// Polygons (outer rings); holes are not counted.
    pub fn len(l: *const ValidatedLayer) u32 {
        return @intCast(l.poly_ring_start.items.len);
    }

    /// Polygon `idx`, for `idx < len()`.
    pub fn get(l: *const ValidatedLayer, idx: u32) Polygon {
        assert(idx < l.len());
        return .{ .layer = l, .idx = idx };
    }

    /// One box per polygon, in `get` order.
    pub fn bboxes(l: *const ValidatedLayer) []const Bbox {
        return l.poly_bbox.items;
    }

    /// Every edge horizontal or vertical: always so under `.rectilinear` and
    /// for a boolean of such layers.
    pub fn isRectilinear(l: *const ValidatedLayer) bool {
        return !l.diagonal;
    }

    /// Every edge horizontal, vertical or at 45 degrees.
    pub fn isOctilinear(l: *const ValidatedLayer) bool {
        return !l.skew;
    }

    /// The polygons whose `keep` flag is set, in order, into `out` (cleared
    /// and refilled), with their store rows. Asserts one flag per polygon.
    pub fn selectInto(l: *const ValidatedLayer, gpa: Allocator, keep: []const bool, out: *ValidatedLayer) Allocator.Error!void {
        assert(keep.len == l.len());
        assert(out != l);
        out.clear();
        for (keep, 0..) |k, idx| {
            if (k) try out.appendPolygon(gpa, l, @intCast(idx));
        }
    }

    /// Polygon `idx` alone into `out` (cleared and refilled): `selectInto` of
    /// one polygon at the cost of that polygon.
    pub fn copyPolygonInto(l: *const ValidatedLayer, gpa: Allocator, idx: u32, out: *ValidatedLayer) Allocator.Error!void {
        assert(out != l);
        out.clear();
        try out.appendPolygon(gpa, l, idx);
    }

    // ---- private ----

    /// Appends polygon `idx` of `from`, recomputing the angle flags from the
    /// rings it brings.
    fn appendPolygon(l: *ValidatedLayer, gpa: Allocator, from: *const ValidatedLayer, idx: u32) Allocator.Error!void {
        const span_start: u32 = @intCast(l.ring_vert_start.items.len);
        const p = from.get(idx);
        for (0..p.ringCount()) |k| {
            const r = p.ring(@intCast(k));
            const flags = edgeFlags(r.xs, r.ys);
            l.diagonal = l.diagonal or !flags.rectilinear;
            l.skew = l.skew or !flags.octilinear;
            try l.pushRing(gpa, r, p.row(@intCast(k)));
        }
        try l.pushPolygon(gpa, span_start, p.bbox());
    }

    /// Copies one ring's coordinates in and appends its ring row.
    fn pushRing(l: *ValidatedLayer, gpa: Allocator, r: Ring, poly: PolyId) Allocator.Error!void {
        assert(l.verts_x.items.len + r.xs.len <= std.math.maxInt(u32));
        try l.ring_vert_start.append(gpa, @intCast(l.verts_x.items.len));
        try l.ring_vert_len.append(gpa, @intCast(r.xs.len));
        try l.ring_poly.append(gpa, poly);
        try l.verts_x.appendSlice(gpa, r.xs);
        try l.verts_y.appendSlice(gpa, r.ys);
    }

    /// Closes the polygon whose rings were pushed since ring `span_start`.
    fn pushPolygon(l: *ValidatedLayer, gpa: Allocator, span_start: u32, box: Bbox) Allocator.Error!void {
        try l.poly_ring_start.append(gpa, span_start);
        try l.poly_ring_len.append(gpa, @as(u32, @intCast(l.ring_vert_start.items.len)) - span_start);
        try l.poly_bbox.append(gpa, box);
    }
};

/// A polygon known valid, borrowed from its layer: ring 0 the outer (CCW),
/// rings `1..ringCount()` its holes (CW) ascending by store row.
pub const Polygon = struct {
    layer: *const ValidatedLayer,
    idx: u32,

    pub fn outer(p: Polygon) Ring {
        return p.ring(0);
    }

    pub fn ringCount(p: Polygon) u32 {
        return p.layer.poly_ring_len.items[p.idx];
    }

    pub fn ring(p: Polygon, k: u32) Ring {
        assert(k < p.ringCount());
        const r = p.layer.poly_ring_start.items[p.idx] + k;
        const start = p.layer.ring_vert_start.items[r];
        const n = p.layer.ring_vert_len.items[r];
        return .{ .xs = p.layer.verts_x.items[start..][0..n], .ys = p.layer.verts_y.items[start..][0..n] };
    }

    /// The outer's box, which holds every hole too.
    pub fn bbox(p: Polygon) Bbox {
        return p.layer.poly_bbox.items[p.idx];
    }

    /// The store row of ring `k`. Meaningful only for a layer validated
    /// straight from a store, not for a boolean result.
    pub fn row(p: Polygon, k: u32) PolyId {
        assert(k < p.ringCount());
        return p.layer.ring_poly.items[p.layer.poly_ring_start.items[p.idx] + k];
    }

    /// The store row of the outer ring; a boolean result's rows are its
    /// scratch store's, so find its owner in the layout instead.
    pub fn provenance(p: Polygon) PolyId {
        return p.row(0);
    }
};

/// `outer_slot` marker for a hole row.
const not_outer = std.math.maxInt(u32);

const Owned = struct {
    slot: u32,
    hole: PolyId,

    fn lessThan(_: void, a: Owned, b: Owned) bool {
        if (a.slot != b.slot) return a.slot < b.slot;
        return @backingInt(a.hole) < @backingInt(b.hole);
    }
};

const Classified = union(enum) {
    ring: struct { winding: ops.Winding, diagonal: bool, skew: bool },
    defect: Defect,
};

/// `(distinct, rectilinear, octilinear)` over every edge of a closed run.
const EdgeFlags = struct { distinct: bool, rectilinear: bool, octilinear: bool };

/// Validates every ring on one layer of `store` into `out` (cleared and
/// refilled), binding each clockwise ring to its containing
/// counter-clockwise ring. An edge outside `angles` is refused, never
/// approximated. Polygons follow the store order of their outers, so
/// `out.get(i)` comes from the `i`-th counter-clockwise row on the layer.
///
/// Returns the first defect in row order (else the first hole no outer
/// contains), with `out` left empty; null when the layer is valid.
pub fn validateLayer(gpa: Allocator, store: *const GeometryStore, layer: LayerId, angles: Angles, out: *ValidatedLayer) Allocator.Error!?Defect {
    const rows = store.polysOnLayer(layer);
    out.clear();
    if (store.isUncomputed(layer)) return .{ .uncomputed = layer };

    // Pass one: shape validation, splitting the rows by winding. Per row,
    // its slot among the outers, or `not_outer`.
    var outers: std.ArrayList(PolyId) = .empty;
    defer outers.deinit(gpa);
    var holes: std.ArrayList(PolyId) = .empty;
    defer holes.deinit(gpa);
    const outer_slot = try gpa.alloc(u32, rows.len());
    defer gpa.free(outer_slot);
    for (outer_slot, rows.start..) |*slot, r| {
        const poly: PolyId = @fromBackingInt(@intCast(r));
        const v = store.polyVerts(poly);
        const ring = switch (try classifyRing(gpa, v.xs, v.ys, poly, angles)) {
            .ring => |c| c,
            .defect => |d| {
                out.clear();
                return d;
            },
        };
        out.diagonal = out.diagonal or ring.diagonal;
        out.skew = out.skew or ring.skew;
        switch (ring.winding) {
            .ccw => {
                slot.* = @intCast(outers.items.len);
                try outers.append(gpa, poly);
            },
            .cw => {
                slot.* = not_outer;
                try holes.append(gpa, poly);
            },
        }
    }

    // Pass two: bind each hole to its outer, as (slot, hole) ascending.
    const owned = try gpa.alloc(Owned, holes.items.len);
    defer gpa.free(owned);
    if (holes.items.len > 0) {
        if (try bindHoles(gpa, store, layer, outers.items, holes.items, outer_slot, owned)) |orphan| {
            out.clear();
            return .{ .orphan_hole = orphan };
        }
    }
    std.mem.sortUnstable(Owned, owned, {}, Owned.lessThan);

    // Pass three: emit one contiguous ring span per polygon, outer first.
    var cursor: usize = 0;
    for (outers.items, 0..) |outer, slot| {
        const span_start: u32 = @intCast(out.ring_vert_start.items.len);
        try out.pushRing(gpa, store.polyVerts(outer), outer);
        while (cursor < owned.len and owned[cursor].slot == slot) : (cursor += 1) {
            const hole = owned[cursor].hole;
            assert(store.polyBbox(outer).contains(store.polyBbox(hole)));
            try out.pushRing(gpa, store.polyVerts(hole), hole);
        }
        try out.pushPolygon(gpa, span_start, store.polyBbox(outer));
    }
    assert(cursor == owned.len);
    return null;
}

/// Why one ring, a store row, is no valid polygon whatever its angles, as
/// `validateLayer` checks it: `degenerate` or `self_intersecting`; null for
/// a valid ring. A hole with no outer is a property of the layer, not of
/// the ring.
pub fn ringDefect(gpa: Allocator, xs: []const Dbu, ys: []const Dbu, poly: PolyId) Allocator.Error!?Defect {
    return switch (try classifyRing(gpa, xs, ys, poly, .any)) {
        .ring => null,
        .defect => |d| d,
    };
}

// ---- private ----

/// Validates one run and reports its winding and angle flags. The check
/// order is part of the answer: a bowtie is self-intersecting, not an edge
/// outside `angles`.
fn classifyRing(gpa: Allocator, xs: []const Dbu, ys: []const Dbu, poly: PolyId, angles: Angles) Allocator.Error!Classified {
    if (xs.len < 3) return .{ .defect = .{ .degenerate = poly } };
    const flags = edgeFlags(xs, ys);
    if (!flags.distinct) return .{ .defect = .{ .degenerate = poly } };
    if (!isRectangle(xs, ys) and try selfIntersects(gpa, xs, ys, .allowed)) return .{ .defect = .{ .self_intersecting = poly } };
    switch (angles) {
        .rectilinear => if (!flags.rectilinear) return .{ .defect = .{ .not_rectilinear = poly } },
        .octilinear => if (!flags.octilinear) return .{ .defect = .{ .not_octilinear = poly } },
        .any => {},
    }
    // A run doubling back on itself has zero area: degenerate.
    const winding = ops.windingOf(xs, ys) orelse return .{ .defect = .{ .degenerate = poly } };
    return .{ .ring = .{ .winding = winding, .diagonal = !flags.rectilinear, .skew = !flags.octilinear } };
}

/// Four distinct vertices alternating vertical and horizontal edges: an axis
/// box, whose opposite sides never meet, so the self-intersection sweep is moot.
fn isRectangle(xs: []const Dbu, ys: []const Dbu) bool {
    if (xs.len != 4) return false;
    return (xs[0] == xs[1] and ys[1] == ys[2] and xs[2] == xs[3] and ys[3] == ys[0]) or
        (ys[0] == ys[1] and xs[1] == xs[2] and ys[2] == ys[3] and xs[3] == xs[0]);
}

/// `EdgeFlags` over a closed run of `n >= 1` vertices: no edge has both ends
/// equal, every edge keeps x or y, every edge keeps x or y or moves as far
/// in x as in y. A plain branchless loop over the open edges, OR-folded,
/// then the closing edge (simple-loops: the 0.18 vectorizer takes this form).
fn edgeFlags(xs: []const Dbu, ys: []const Dbu) EdgeFlags {
    assert(xs.len == ys.len and xs.len >= 1);
    const n = xs.len;
    var dup: u8 = 0;
    var skew: u8 = 0;
    var steep: u8 = 0;
    for (xs[0 .. n - 1], xs[1..], ys[0 .. n - 1], ys[1..]) |ax, bx, ay, by| {
        const same_x = ax == bx;
        const same_y = ay == by;
        // |coordinate| <= 2^40, so neither delta overflows.
        const diagonal = @abs(bx - ax) == @abs(by - ay);
        dup |= @intFromBool(same_x and same_y);
        skew |= @intFromBool(!(same_x or same_y));
        steep |= @intFromBool(!(same_x or same_y or diagonal));
    }
    const same_x = xs[n - 1] == xs[0];
    const same_y = ys[n - 1] == ys[0];
    const diagonal = @abs(xs[0] - xs[n - 1]) == @abs(ys[0] - ys[n - 1]);
    dup |= @intFromBool(same_x and same_y);
    skew |= @intFromBool(!(same_x or same_y));
    steep |= @intFromBool(!(same_x or same_y or diagonal));
    return .{ .distinct = dup == 0, .rectilinear = skew == 0, .octilinear = steep == 0 };
}

/// Binds every hole to an outer into `owned`, one row per hole of `holes`.
/// A reader stores a polygon's holes right after its outer (a GDSII keyhole,
/// a boolean's result), so the nearest outer row before a hole is its own
/// when it contains it; where shapes overlap another outer may contain it
/// too, and a smaller one would steal it. Failing that, the innermost
/// (smallest-box) outer containing it, a tie keeping the lower row.
/// Returns the first orphan hole, or null.
fn bindHoles(gpa: Allocator, store: *const GeometryStore, layer: LayerId, outers: []const PolyId, holes: []const PolyId, outer_slot: []const u32, owned: []Owned) Allocator.Error!?PolyId {
    const first = store.polysOnLayer(layer).start;
    const n = outer_slot.len;
    // Per row: the slot of the nearest outer row before a hole holding it.
    const own_slot = try gpa.alloc(u32, n);
    defer gpa.free(own_slot);
    @memset(own_slot, not_outer);
    var before: u32 = not_outer;
    for (outer_slot, 0..) |slot, r| {
        if (slot != not_outer) {
            before = slot;
        } else if (before != not_outer and contains(store, outers[before], @fromBackingInt(@intCast(first + r)))) {
            own_slot[r] = before;
        }
    }

    // Distance-zero candidates are every touching pair, and containment
    // implies touching.
    var idx: index.SpatialIndex = .empty;
    defer idx.deinit(gpa);
    try idx.build(gpa, store, layer);
    var pairs: std.ArrayList(index.Pair) = .empty;
    defer pairs.deinit(gpa);
    try index.candidatePairsInto(gpa, store, &idx, 0, &pairs);

    // Above any real box area (at most 2^82).
    const best_area = try gpa.alloc(DbuArea, n);
    defer gpa.free(best_area);
    @memset(best_area, std.math.maxInt(DbuArea));
    const best_slot = try gpa.alloc(u32, n);
    defer gpa.free(best_slot);
    @memset(best_slot, not_outer);
    for (pairs.items) |pair| {
        const ra = @backingInt(pair.a) - first;
        const rb = @backingInt(pair.b) - first;
        const a_outer = outer_slot[ra] != not_outer;
        const b_outer = outer_slot[rb] != not_outer;
        if (a_outer == b_outer) continue;
        const outer, const hole, const slot = if (a_outer) .{ pair.a, pair.b, outer_slot[ra] } else .{ pair.b, pair.a, outer_slot[rb] };
        const hr = @backingInt(hole) - first;
        if (own_slot[hr] != not_outer or !contains(store, outer, hole)) continue;
        // Strict `<` over ascending pairs: a tie keeps the lower row.
        const area = store.polyBbox(outer).area();
        if (area < best_area[hr]) {
            best_area[hr] = area;
            best_slot[hr] = slot;
        }
    }

    for (holes, owned) |hole, *o| {
        const hr = @backingInt(hole) - first;
        const slot = if (own_slot[hr] != not_outer) own_slot[hr] else best_slot[hr];
        if (slot == not_outer) return hole;
        o.* = .{ .slot = slot, .hole = hole };
    }
    return null;
}

/// Whether `outer`'s box holds `hole`'s and its ring holds the hole's first
/// vertex.
fn contains(store: *const GeometryStore, outer: PolyId, hole: PolyId) bool {
    if (!store.polyBbox(outer).contains(store.polyBbox(hole))) return false;
    return store.polyContainsPoint(outer, store.firstVertex(hole));
}

/// The per-edge loop the kernel replaced: the oracle of `edgeFlags`.
fn edgeFlagsScalar(xs: []const Dbu, ys: []const Dbu) EdgeFlags {
    var f: EdgeFlags = .{ .distinct = true, .rectilinear = true, .octilinear = true };
    for (0..xs.len) |i| {
        const j = (i + 1) % xs.len;
        const same_x = xs[i] == xs[j];
        const same_y = ys[i] == ys[j];
        const diagonal = @abs(xs[j] - xs[i]) == @abs(ys[j] - ys[i]);
        f.distinct = f.distinct and !(same_x and same_y);
        f.rectilinear = f.rectilinear and (same_x or same_y);
        f.octilinear = f.octilinear and (same_x or same_y or diagonal);
    }
    return f;
}

test "a rectangle never self intersects" {
    // Oracle: differential against the self-intersection sweep, exhaustive
    // over every 4-ring on a 3 x 3 grid: no ring the shortcut calls a
    // rectangle is one the sweep rejects.
    var rects: u32 = 0;
    for (0..9 * 9 * 9 * 9) |code| {
        var xs: [4]Dbu = undefined;
        var ys: [4]Dbu = undefined;
        var c = code;
        for (&xs, &ys) |*x, *y| {
            x.* = @intCast(c % 9 % 3);
            y.* = @intCast(c % 9 / 3);
            c /= 9;
        }
        if (edgeFlagsScalar(&xs, &ys).distinct and isRectangle(&xs, &ys)) {
            rects += 1;
            try std.testing.expect(!try selfIntersects(std.testing.allocator, &xs, &ys, .cross));
        }
    }
    try std.testing.expect(rects > 0);
}

test "edge flags match the scalar loop" {
    // Oracle: differential against `edge_flags_scalar`, at every length 1 to
    // 13, over rings drawn from three values so that duplicates, axis edges
    // and skew edges all occur.
    var xs: [13]Dbu = undefined;
    var ys: [13]Dbu = undefined;
    const values = [3]Dbu{ 0, dbu.max_abs_dbu, -dbu.max_abs_dbu };
    for (1..14) |n| {
        for (0..512) |seed| {
            for (0..n) |i| {
                xs[i] = values[(((seed * 31 + i * 7) *% 0x9E37_79B9_7F4A_7C15) >> 40) % 3];
                ys[i] = values[(((seed * 31 + i * 7 + 1) *% 0x9E37_79B9_7F4A_7C15) >> 40) % 3];
            }
            try std.testing.expectEqual(edgeFlagsScalar(xs[0..n], ys[0..n]), edgeFlags(xs[0..n], ys[0..n]));
        }
    }
}
