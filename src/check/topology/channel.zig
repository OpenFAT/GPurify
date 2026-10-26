//! The conduction guard run before net extraction: a MOS channel marker
//! must not overlap conductor area on its own source/drain layer, or
//! extraction fuses source and drain into one net and the short compares as
//! clean. In: a `GeometryStore`, the deck's `Connectivity` and
//! `DeviceRecognition`. Out: nothing, or the first offending pair with the
//! polygon it names. Ported from crates/check/src/topology/device.rs
//! (`refuse_conducting_channels`, `ChannelError`).
//!
//! Contents:
//! - `pub const ChannelError = error{ ConductingChannel, Geometry }`
//! - `pub const ChannelDiagnostic = union(enum)`
//! - `pub fn refuseConductingChannels(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, recognition: *const DeviceRecognition, diag: *ChannelDiagnostic) (ChannelError || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const deck = @import("ingest").deck;
const Connectivity = deck.Connectivity;
const DeviceRecognition = deck.DeviceRecognition;
const rects = @import("../rects.zig");
const roleAt = @import("device.zig").roleAt;

pub const ChannelError = error{
    /// A MOS channel marker overlaps conductor area on its source/drain
    /// layer: source and drain would extract as one net. Derive the
    /// conductor with the channel taken out (`diff NOT poly`).
    ConductingChannel,
    /// The marker or source/drain layer does not validate octilinear.
    Geometry,
};

/// What `refuseConductingChannels` found, set alongside its error.
pub const ChannelDiagnostic = union(enum) {
    none,
    conducting: struct {
        /// The recogniser's marker layer.
        marker: LayerId,
        /// The source/drain layer it overlaps.
        conductor: LayerId,
        /// The lowest store row contributing to the first overlap region.
        poly: PolyId,
    },
    geometry: geom.view.Defect,
};

/// Refuses any MOS recogniser whose channel marker overlaps conductor area
/// on its source/drain layer, checked in deck order and positions in
/// terminal order, per layer pair over the whole layout. Only area counts,
/// not abutment, and only on a source/drain layer that is a conductor; the
/// gate and bulk conduct through the marker on purpose.
pub fn refuseConductingChannels(gpa: Allocator, store: *const GeometryStore, connectivity: *const Connectivity, recognition: *const DeviceRecognition, diag: *ChannelDiagnostic) (ChannelError || Allocator.Error)!void {
    diag.* = .none;
    var checked: std.ArrayList([2]LayerId) = .empty;
    defer checked.deinit(gpa);
    var marker_area: ValidatedLayer = .empty;
    defer marker_area.deinit(gpa);
    var conductor_area: ValidatedLayer = .empty;
    defer conductor_area.deinit(gpa);
    var overlap: ValidatedLayer = .empty;
    defer overlap.deinit(gpa);
    for (recognition.kind, 0..) |kind, row| {
        if (kind != .mos) continue;
        const marker = recognition.marker[row];
        const terminals = recognition.terminal[recognition.terminal_start[row]..recognition.terminal_start[row + 1]];
        for (terminals, 0..) |layer, position| {
            switch (roleAt(.mos, @intCast(position))) {
                .source, .drain => {},
                .gate, .bulk, .base, .emitter, .collector, .pin => continue,
            }
            if (std.mem.indexOfScalar(LayerId, connectivity.conductors, layer) == null) continue;
            const pair = [2]LayerId{ marker, layer };
            const seen = for (checked.items) |c| {
                if (c[0] == pair[0] and c[1] == pair[1]) break true;
            } else false;
            if (seen) continue;
            try checked.append(gpa, pair);
            if (store.polysOnLayer(marker).len() == 0 or store.polysOnLayer(layer).len() == 0) continue;
            // Exact area intersection: abutment intersects to nothing.
            for ([2]LayerId{ marker, layer }, [2]*ValidatedLayer{ &marker_area, &conductor_area }) |l, area| {
                if (try geom.view.validateLayer(gpa, store, l, .octilinear, area)) |defect| {
                    diag.* = .{ .geometry = defect };
                    return error.Geometry;
                }
            }
            try geom.boolean.intersectionInto(gpa, &marker_area, &conductor_area, &overlap);
            if (overlap.len() == 0) continue;
            diag.* = .{ .conducting = .{ .marker = marker, .conductor = layer, .poly = try overlapOwner(gpa, store, &overlap, .{ marker, layer }, .{ &marker_area, &conductor_area }) } };
            return error.ConductingChannel;
        }
    }
}

// ---- private ----

/// The lowest drawn row under the overlap's first figure, over both layers
/// (the overlap's own rows are the boolean's scratch store's). A layer or an
/// overlap with a 45-degree edge names that layer's lowest row instead:
/// Rust cut the overlap into rectangles whenever the layer was rectilinear
/// and panicked on a 45-degree overlap of a rectilinear marker.
/// ponytail: the lowest row, not the one under the overlap, at 45 degrees;
/// cut by point if it matters.
fn overlapOwner(gpa: Allocator, store: *const GeometryStore, overlap: *const ValidatedLayer, layers: [2]LayerId, areas: [2]*const ValidatedLayer) Allocator.Error!PolyId {
    var drawn: rects.LayerRects = .{};
    defer drawn.deinit(gpa);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    var owner: u32 = std.math.maxInt(u32);
    for (layers, areas) |layer, area| {
        if (area.isRectilinear() and overlap.isRectilinear()) {
            try drawn.build(gpa, store, layer, area);
            try rects.ownersOfInto(gpa, overlap, &drawn, &owners);
            owner = @min(owner, @backingInt(owners.items[0]));
        } else {
            for (0..area.len()) |p| owner = @min(owner, @backingInt(area.get(@intCast(p)).provenance()));
        }
    }
    return @fromBackingInt(owner);
}
