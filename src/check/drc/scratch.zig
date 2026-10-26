//! What every DRC kind reads besides its row: the run's context (`Ctx`: the
//! store, the rule's id, the output, the scratch) and the buffers kinds
//! refill (`Scratch`, proximity's plus DRC's own), with the merges several
//! families share. In: a store and a layer. Out: merged figures, their
//! owners, and wide parts. Ported from crates/check/src/drc/mod.rs
//! (`Scratch`) and crates/check/src/drc/rules/{facing,width}.rs
//! (`merged_owners`, `wide_rects_into`, `rects_layer`).
//!
//! Contents:
//! - `pub const Scratch = struct`, `Scratch.deinit`
//! - `pub const Ctx = struct`, `Ctx.push(c: *const Ctx, row: Violation) Allocator.Error!void`,
//!   `Ctx.finding(c, layer: LayerId, at: Point, measured: Measurement, limit: Measurement, shape: PolyId) Allocator.Error!void`
//! - `pub const Error`, `pub const ran`
//! - `pub fn mergedOwners(c: *const Ctx, layer: LayerId) Error!bool`
//! - `pub fn wideRectsInto(gpa: Allocator, drawn: *const ValidatedLayer, w: Dbu, out: *std.ArrayList(Bbox)) Error!void`
//! - `pub fn boxesLayer(gpa: Allocator, boxes: []const Bbox, out: *ValidatedLayer) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Violation = report.Violation;
const Violations = report.Violations;
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const LayerRects = rects.LayerRects;
const proximity = @import("../proximity.zig");
const RuleSet = @import("rule_set.zig").RuleSet;

/// What a DRC kind can fail on: allocation, a worker thread of the
/// pair-distance kernel, and a derived box leaving the coordinate domain.
pub const Error = proximity.Error || geom.derive.Error;

/// The buffers every kind refills; one `*Scratch` means rules run
/// sequentially.
pub const Scratch = struct {
    p: proximity.Scratch = .{},
    /// A rectilinear decomposition, CSR by figure.
    rects: std.ArrayList(Bbox) = .empty,
    rect_start: std.ArrayList(u32) = .empty,
    /// Per figure, the lowest drawn row under it.
    owners: std.ArrayList(PolyId) = .empty,
    facing: geom.width.FacingScratch = .{},
    rects_b: LayerRects = .{},

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.p.deinit(gpa);
        s.rects.deinit(gpa);
        s.rect_start.deinit(gpa);
        s.owners.deinit(gpa);
        s.facing.deinit(gpa);
        s.rects_b.deinit(gpa);
    }
};

/// One rule's run: what every kind reads besides its row.
pub const Ctx = struct {
    gpa: Allocator,
    store: *const GeometryStore,
    /// The rule's deck id.
    rule: StrId,
    s: *Scratch,
    out: *Violations,
    /// Layers below this are drawn; the rest the deck's derived ones.
    drawn: u32,
    /// The set, for the side tables a row names.
    rs: *const RuleSet,
    /// One net per store row (`proximity.no_net` for none); null without
    /// extraction, which a net rule refuses.
    poly_net: ?[]const u32,

    pub fn push(c: *const Ctx, row: Violation) Allocator.Error!void {
        return c.out.push(c.gpa, row);
    }

    /// One error finding of this rule naming one shape.
    pub fn finding(c: *const Ctx, layer: LayerId, at: Point, measured: Measurement, limit: Measurement, shape: PolyId) Allocator.Error!void {
        return c.push(.{ .rule = c.rule, .layer = layer, .severity = .@"error", .at = at, .measured = measured, .limit = limit, .shape_a = shape, .shape_b = report.no_shape });
    }
};

/// A run that examined `examined` items.
pub fn ran(examined: u64) report.Verdict {
    return .{ .outcome = .ran, .examined = examined };
}

/// `layer` validated (rectilinear) and merged into `s.p.layer_out`, with the
/// lowest drawn row under each figure in `s.owners`; false (refused) when
/// it does not validate.
pub fn mergedOwners(c: *const Ctx, layer: LayerId) Error!bool {
    const s = c.s;
    const drawn = try s.p.validated.get(c.gpa, c.store, layer) orelse return false;
    try geom.derive.mergeInto(c.gpa, drawn, &s.p.layer_out);
    try s.p.rects_a.build(c.gpa, c.store, layer, drawn);
    try rects.ownersOfInto(c.gpa, &s.p.layer_out, &s.p.rects_a, &s.owners);
    return true;
}

/// The parts of a rectilinear layer at least `w` wide, as disjoint
/// rectangles: the union of every axis-aligned `w` square inside the merged
/// layer (KLayout `sized(-w/2).sized(w/2)`). Eroding by a `w - 1` square
/// leaves a positive-area anchor exactly where a `w` square fits on the
/// grid, so a shape exactly `w` wide counts as wide.
pub fn wideRectsInto(gpa: Allocator, drawn: *const ValidatedLayer, w: Dbu, out: *std.ArrayList(Bbox)) Error!void {
    out.clearRetainingCapacity();
    var extent = Bbox.empty;
    for (drawn.bboxes()) |b| extent = extent.merge(b);
    if (extent.isEmpty()) return;
    const k = w - 1;
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    var scratch: ValidatedLayer = .empty;
    defer scratch.deinit(gpa);
    if (k == 0) {
        try geom.derive.mergeInto(gpa, drawn, &scratch);
        return geom.rects.decomposeInto(gpa, &scratch, out, &start);
    }
    // ponytail: a frame clamped at the coordinate domain's edge erodes shapes
    // touching it; layouts never reach 2^40.
    var frame: ValidatedLayer = .empty;
    defer frame.deinit(gpa);
    try boxesLayer(gpa, &.{.{ .xlo = clamped(extent.xlo - k), .ylo = clamped(extent.ylo - k), .xhi = clamped(extent.xhi + k), .yhi = clamped(extent.yhi + k) }}, &frame);
    var layer: ValidatedLayer = .empty;
    defer layer.deinit(gpa);
    // Anchors p where p + [0, k]² leaves the layer: the complement dragged
    // left and down by k.
    try geom.boolean.subtractionInto(gpa, &frame, drawn, &scratch);
    try geom.rects.decomposeInto(gpa, &scratch, out, &start);
    for (out.items) |*r| {
        r.xlo = clamped(r.xlo - k);
        r.ylo = clamped(r.ylo - k);
    }
    try boxesLayer(gpa, out.items, &layer);
    try geom.boolean.subtractionInto(gpa, &frame, &layer, &scratch);
    try geom.rects.decomposeInto(gpa, &scratch, out, &start);
    for (out.items) |*r| {
        r.xhi = clamped(r.xhi + k);
        r.yhi = clamped(r.yhi + k);
    }
    try boxesLayer(gpa, out.items, &layer);
    try geom.derive.mergeInto(gpa, &layer, &scratch);
    try geom.rects.decomposeInto(gpa, &scratch, out, &start);
}

/// Boxes, possibly overlapping, as one validated layer; no boxes, an empty
/// layer.
pub fn boxesLayer(gpa: Allocator, boxes: []const Bbox, out: *ValidatedLayer) Error!void {
    if (boxes.len == 0) {
        out.clear();
        return;
    }
    return geom.derive.boxesInto(gpa, boxes, out);
}

// ---- private ----

fn clamped(v: i64) Dbu {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
