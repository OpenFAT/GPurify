//! Label binding: placed `TEXT`s, a finished `GeometryStore` and the deck's
//! label pairing → each label bound to the polygon it sits on, written into
//! the `Provenance`'s `(PolyId, StrId)` rows (ascending by `PolyId`) and its
//! black-box pins. One sweep in x per label row: each text tests only the
//! shapes whose box spans its x. Ported from crates/ingest/src/provenance.rs
//! (`resolve_labels`, `bind_all`, `claimed`, `bind_on_layer`, `in_hole_of`,
//! `on_ring`).
//!
//! Contents:
//! - `pub const Error = error{Unplaced} || Allocator.Error`
//! - `pub fn resolveLabels(gpa: Allocator, p: *Provenance, store: *const GeometryStore, connectivity: *const Connectivity, unplaced: *PlacedLabel) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ops = geom.ops;
const provenance = @import("provenance.zig");
const Provenance = provenance.Provenance;
const PlacedLabel = provenance.PlacedLabel;
const Connectivity = @import("deck/tables.zig").Connectivity;

/// `Unplaced`: a `TEXT` on a deck label layer, or a black-box pin on one,
/// lies on no shape of any conductor its label rows name, holes counting as
/// no shape; `unplaced` is that label. A dropped label would leave its net
/// without its name.
pub const Error = error{Unplaced} || Allocator.Error;

/// The label columns binding reads.
const Points = struct { xs: []const Dbu, ys: []const Dbu, layers: []const LayerId };

/// Binds each placed label, and each black-box pin, to the polygon it sits
/// on. Run after the store is finished and its derived layers appended.
/// Rebinds from scratch: what an earlier call bound is replaced, what
/// `Provenance.label` attached is kept. The boundary counts as inside; the
/// first pairing row, then the lowest `PolyId`, wins. A text on a layer no
/// pairing row names binds nothing.
pub fn resolveLabels(gpa: Allocator, p: *Provenance, store: *const GeometryStore, connectivity: *const Connectivity, unplaced: *PlacedLabel) Error!void {
    assert(connectivity.label_layer.len == connectivity.label_names.len);
    const placed = p.placed.slice();
    const bound = try gpa.alloc(?PolyId, placed.len);
    defer gpa.free(bound);
    try bindAll(gpa, store, connectivity, .{ .xs = placed.items(.x), .ys = placed.items(.y), .layers = placed.items(.layer) }, bound);
    p.labelled.clearRetainingCapacity();
    try p.labelled.appendSlice(gpa, p.attached.items);
    for (bound, 0..) |poly, i| {
        if (try claimed(placed.get(i), poly, connectivity, unplaced)) |hit| try p.labelled.append(gpa, .{ .poly = hit, .name = placed.items(.name)[i] });
    }
    // Stable: equal ids keep arrival order, as `label` would have.
    std.mem.sort(provenance.Label, p.labelled.items, {}, lessPoly);

    // Black-box pins, bound the same way, apart.
    const pins = p.box_pins_placed.items;
    var columns: std.MultiArrayList(PlacedLabel) = .empty;
    defer columns.deinit(gpa);
    try columns.ensureTotalCapacity(gpa, pins.len);
    for (pins) |pin| columns.appendAssumeCapacity(pin);
    const pin_bound = try gpa.alloc(?PolyId, pins.len);
    defer gpa.free(pin_bound);
    try bindAll(gpa, store, connectivity, .{ .xs = columns.items(.x), .ys = columns.items(.y), .layers = columns.items(.layer) }, pin_bound);
    p.box_pins.clearRetainingCapacity();
    for (0..p.box_cell.items.len) |box| {
        const span = p.box_pin_start.items[box..][0..2];
        for (span[0]..span[1]) |i| {
            if (try claimed(pins[i], pin_bound[i], connectivity, unplaced)) |hit| try p.box_pins.append(gpa, .{ .box = @intCast(box), .poly = hit, .name = pins[i].name });
        }
    }
}

// ---- private ----

fn lessPoly(_: void, a: provenance.Label, b: provenance.Label) bool {
    return @backingInt(a.poly) < @backingInt(b.poly);
}

/// The polygon each label binds to, by the first label row naming its layer
/// that finds a shape under it, or null, into `bound`.
fn bindAll(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, labels: Points, bound: []?PolyId) Allocator.Error!void {
    @memset(bound, null);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(gpa);
    for (connectivity.label_layer, connectivity.label_names) |text, conductor| {
        // An earlier row's binding stands.
        pending.clearRetainingCapacity();
        for (bound, labels.layers, 0..) |b, layer, i| {
            if (b == null and layer == text) try pending.append(gpa, @intCast(i));
        }
        try bindOnLayer(gpa, store, conductor, labels, pending.items, bound);
    }
}

/// `poly`, the binding of `label`; `Unplaced` when `label` is on a label
/// layer and bound nothing, null when it is on no label layer.
fn claimed(label: PlacedLabel, poly: ?PolyId, connectivity: *const Connectivity, unplaced: *PlacedLabel) error{Unplaced}!?PolyId {
    if (poly) |hit| return hit;
    if (std.mem.indexOfScalar(LayerId, connectivity.label_layer, label.layer) == null) return null;
    unplaced.* = label;
    return error.Unplaced;
}

/// For each label in `pending`, the lowest-id polygon on `layer` holding it
/// on material, or null. A sweep in x: labels in x order, polygons entering
/// by `xlo` and leaving past `xhi`, so each label tests only the boxes
/// spanning its x.
fn bindOnLayer(gpa: Allocator, store: *const GeometryStore, layer: LayerId, labels: Points, pending: []u32, bound: []?PolyId) Allocator.Error!void {
    const first = store.polysOnLayer(layer).start;
    const boxes = store.layerBboxes(layer);
    const by_xlo = try gpa.alloc(u32, boxes.len);
    defer gpa.free(by_xlo);
    for (by_xlo, 0..) |*b, i| b.* = @intCast(i);
    std.mem.sortUnstable(u32, by_xlo, boxes, struct {
        fn less(bx: []const geom.Bbox, a: u32, b: u32) bool {
            return bx[a].xlo < bx[b].xlo;
        }
    }.less);
    std.mem.sortUnstable(u32, pending, labels.xs, struct {
        fn less(xs: []const Dbu, a: u32, b: u32) bool {
            return xs[a] < xs[b];
        }
    }.less);

    var entered: usize = 0;
    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(gpa);
    var hits: std.ArrayList(PolyId) = .empty;
    defer hits.deinit(gpa);
    for (pending) |label| {
        const p: Point = .{ .x = labels.xs[label], .y = labels.ys[label] };
        while (entered < by_xlo.len and boxes[by_xlo[entered]].xlo <= p.x) : (entered += 1) try active.append(gpa, by_xlo[entered]);
        var kept: usize = 0;
        for (active.items) |i| {
            if (boxes[i].xhi < p.x) continue;
            active.items[kept] = i;
            kept += 1;
        }
        active.shrinkRetainingCapacity(kept);

        hits.clearRetainingCapacity();
        for (active.items) |i| {
            const b = boxes[i];
            const poly: PolyId = @fromBackingInt(first + i);
            if (b.ylo <= p.y and p.y <= b.yhi and store.polyContainsPoint(poly, p)) try hits.append(gpa, poly);
        }
        std.mem.sortUnstable(PolyId, hits.items, {}, struct {
            fn less(_: void, a: PolyId, b: PolyId) bool {
                return @backingInt(a) < @backingInt(b);
            }
        }.less);
        bound[label] = for (hits.items) |poly| {
            if (!inHoleOf(store, poly, p, hits.items)) break poly;
        } else null;
    }
}

/// Whether `p` sits in a hole of `poly` rather than on its material: a hole
/// row is never a label target, and neither is an outer holding a smaller
/// hole row that holds `p` strictly. `hits` is every row on the layer
/// containing `p`, so every candidate hole. A point on a hole's edge is
/// material.
fn inHoleOf(store: *const GeometryStore, poly: PolyId, p: Point, hits: []const PolyId) bool {
    const r = store.polyVerts(poly);
    if (ops.windingOf(r.xs, r.ys) == .cw) return true;
    const outer_area = @abs(ops.area2(r.xs, r.ys));
    for (hits) |hole| {
        const h = store.polyVerts(hole);
        if (ops.windingOf(h.xs, h.ys) == .cw and @abs(ops.area2(h.xs, h.ys)) < outer_area and
            store.polyContainsPoint(poly, .{ .x = h.xs[0], .y = h.ys[0] }) and !onRing(h, p)) return true;
    }
    return false;
}

/// Whether `p` lies on an edge of the ring.
fn onRing(r: geom.Ring, p: Point) bool {
    for (0..r.xs.len) |i| {
        const j = if (i + 1 == r.xs.len) 0 else i + 1;
        const ax = r.xs[i];
        const ay = r.ys[i];
        const bx = r.xs[j];
        const by = r.ys[j];
        const cross = @as(i128, bx - ax) * (p.y - ay) - @as(i128, by - ay) * (p.x - ax);
        if (cross == 0 and p.x >= @min(ax, bx) and p.x <= @max(ax, bx) and p.y >= @min(ay, by) and p.y <= @max(ay, by)) return true;
    }
    return false;
}
