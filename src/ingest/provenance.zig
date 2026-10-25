//! Net labels: `TEXT` points as the layout placed them, the polygons they
//! bind to, and the black boxes LVS compares by their pins.
//! In: placed labels in the root frame, `(PolyId, StrId)` attachments, black
//! boxes. Out: `(PolyId, StrId)` rows ascending by `PolyId`, arrival order
//! kept among equal ids. Ported from crates/ingest/src/provenance.rs (data
//! types and the label / place / box APIs; `resolve_labels`, which reads a
//! finished `GeometryStore`, is wave 2's).
//!
//! Contents:
//! - `pub const PlacedLabel`, `pub const Label`, `pub const BlackBox`, `pub const BoxPin`
//! - `pub const Provenance`, `Provenance.deinit(p: *Provenance, gpa: Allocator) void`,
//!   `Provenance.label(p: *Provenance, gpa: Allocator, poly: PolyId, name: StrId) Allocator.Error!void`,
//!   `Provenance.labels(p: *const Provenance) []const Label`,
//!   `Provenance.placeLabel(p: *Provenance, gpa: Allocator, label: PlacedLabel) Allocator.Error!void`,
//!   `Provenance.setBlackBoxes(p: *Provenance, gpa: Allocator, boxes: []const BlackBox) Allocator.Error!void`,
//!   `Provenance.blackBoxCount(p: *const Provenance) u32`,
//!   `Provenance.blackBox(p: *const Provenance, row: u32) BlackBox`,
//!   `Provenance.blackBoxPins(p: *const Provenance) []const BoxPin`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;

/// One `TEXT` as the layout stated it, its anchor already in the root frame.
pub const PlacedLabel = struct {
    /// Where the anchor lands in the root cell, in database units.
    x: Dbu,
    y: Dbu,
    /// The layer the `TEXT` was drawn on, mapped through the deck.
    layer: LayerId,
    /// The text, interned: a net name when the layer is a label layer.
    name: StrId,
};

/// A polygon and the net name a label gives it.
pub const Label = struct { poly: PolyId, name: StrId };

/// One placement of a cell the deck's `lvs blackbox` names, in the root
/// frame: LVS compares it by its pins alone (catalog LVS-033).
pub const BlackBox = struct {
    /// The placed cell's name.
    cell: StrId,
    /// The extent of every shape placed under it, on any layer.
    extent: Bbox,
    /// The cell's own `TEXT`s, placed: its pins.
    pins: []const PlacedLabel,
};

/// A black-box pin bound to a polygon: the box (a row of the black boxes),
/// the polygon, and the pin's name.
pub const BoxPin = struct { box: u32, poly: PolyId, name: StrId };

/// Placed labels, and the ones bound to a polygon. Invariant: `labelled` is
/// ascending by `PolyId`, equal ids in arrival order; `box_pin_start` is one
/// longer than `box_cell` once any box is set.
pub const Provenance = struct {
    labelled: std.ArrayList(Label) = .empty,
    /// What `label` attached, in arrival order: kept when labels are rebound.
    attached: std.ArrayList(Label) = .empty,
    /// Every `TEXT` as placed, in arrival order, bound or not.
    placed: std.MultiArrayList(PlacedLabel) = .empty,
    /// The black boxes as CSR: box `i`'s pins are
    /// `box_pins_placed[box_pin_start[i]..box_pin_start[i + 1]]`.
    box_cell: std.ArrayList(StrId) = .empty,
    box_extent: std.ArrayList(Bbox) = .empty,
    box_pin_start: std.ArrayList(u32) = .empty,
    box_pins_placed: std.ArrayList(PlacedLabel) = .empty,
    /// The pins label resolution bound, ascending by box.
    box_pins: std.ArrayList(BoxPin) = .empty,

    pub fn deinit(p: *Provenance, gpa: Allocator) void {
        p.labelled.deinit(gpa);
        p.attached.deinit(gpa);
        p.placed.deinit(gpa);
        p.box_cell.deinit(gpa);
        p.box_extent.deinit(gpa);
        p.box_pin_start.deinit(gpa);
        p.box_pins_placed.deinit(gpa);
        p.box_pins.deinit(gpa);
    }

    /// Attaches a net label to a polygon, after any existing labels of the
    /// same polygon, keeping `labels` ascending. O(n) per call.
    pub fn label(p: *Provenance, gpa: Allocator, poly: PolyId, name: StrId) Allocator.Error!void {
        try p.attached.ensureUnusedCapacity(gpa, 1);
        var at: usize = p.labelled.items.len;
        while (at > 0 and @backingInt(p.labelled.items[at - 1].poly) > @backingInt(poly)) at -= 1;
        try p.labelled.insert(gpa, at, .{ .poly = poly, .name = name });
        p.attached.appendAssumeCapacity(.{ .poly = poly, .name = name });
    }

    /// Every labelled polygon, ascending by `PolyId`: `topology` binds
    /// against it without sorting.
    pub fn labels(p: *const Provenance) []const Label {
        return p.labelled.items;
    }

    /// Records a `TEXT` where the layout drew it, bound to nothing yet.
    pub fn placeLabel(p: *Provenance, gpa: Allocator, placed: PlacedLabel) Allocator.Error!void {
        try p.placed.append(gpa, placed);
    }

    /// Records the layout's black boxes, replacing any before, whose pins the
    /// next label resolution binds. Their pins never name a net.
    pub fn setBlackBoxes(p: *Provenance, gpa: Allocator, boxes: []const BlackBox) Allocator.Error!void {
        p.box_cell.clearRetainingCapacity();
        p.box_extent.clearRetainingCapacity();
        p.box_pin_start.clearRetainingCapacity();
        p.box_pins_placed.clearRetainingCapacity();
        p.box_pins.clearRetainingCapacity();
        if (boxes.len == 0) return;
        try p.box_pin_start.append(gpa, 0);
        for (boxes) |b| {
            try p.box_cell.append(gpa, b.cell);
            try p.box_extent.append(gpa, b.extent);
            try p.box_pins_placed.appendSlice(gpa, b.pins);
            try p.box_pin_start.append(gpa, @intCast(p.box_pins_placed.items.len));
        }
    }

    /// How many black boxes are recorded.
    pub fn blackBoxCount(p: *const Provenance) u32 {
        return @intCast(p.box_cell.items.len);
    }

    /// Black box `row`, its pins a view into the provenance.
    pub fn blackBox(p: *const Provenance, row: u32) BlackBox {
        assert(row < p.box_cell.items.len);
        const pins = p.box_pins_placed.items[p.box_pin_start.items[row]..p.box_pin_start.items[row + 1]];
        return .{ .cell = p.box_cell.items[row], .extent = p.box_extent.items[row], .pins = pins };
    }

    /// Every black-box pin label resolution bound, ascending by box. A pin on
    /// a layer no label row names is documentation and binds nothing.
    pub fn blackBoxPins(p: *const Provenance) []const BoxPin {
        return p.box_pins.items;
    }
};

test "black boxes read back as set, pins and all" {
    // Oracle: construct-from-answer. Two boxes set with stated pins read back
    // box for box; a second set replaces the first.
    const gpa = std.testing.allocator;
    var p: Provenance = .{};
    defer p.deinit(gpa);
    const a: StrId = @fromBackingInt(1);
    const pin: PlacedLabel = .{ .x = 5, .y = 6, .layer = @fromBackingInt(2), .name = a };
    try p.setBlackBoxes(gpa, &.{
        .{ .cell = a, .extent = .point(0, 0), .pins = &.{ pin, pin } },
        .{ .cell = a, .extent = .point(1, 1), .pins = &.{} },
    });
    try std.testing.expectEqual(2, p.blackBoxCount());
    try std.testing.expectEqual(2, p.blackBox(0).pins.len);
    try std.testing.expectEqual(0, p.blackBox(1).pins.len);
    try std.testing.expectEqual(Bbox.point(1, 1), p.blackBox(1).extent);
    try p.setBlackBoxes(gpa, &.{});
    try std.testing.expectEqual(0, p.blackBoxCount());
}
