//! Panel meshing: conductor surfaces to boundary elements. Ported from
//! crates/extract/src/field/mesh.rs.
//!
//! In: selected nets' polygons, cut into the disjoint rectangles
//! `geom.rects.decomposeInto` gives and extruded through the stack. A
//! rectangle's side face is meshed only where no rectangle of the same
//! conductor on the same layer abuts it, so no panel sits inside metal.
//! Out: a `Mesh`, panels banded by conductor, Morton-ordered within each band
//! (`morton.zig`). That order is the matvec's summation order, so it fixes
//! output bits. In a stack whose dielectric changes with height, a last band
//! holds the panels of every interface between two dielectrics, and each
//! conductor panel carries the permittivity outside its face.
//!
//! Contents:
//! - `pub const Mesh = struct`, `Mesh.empty`, `deinit`, `clear`
//! - `pub const MeshOptions = struct { max_edge: Dbu, proximity_refine: Dbu, max_panels: u32 }`
//! - `pub const Error = error{ TooManyPanels, MissingThickness, EmptyConductor, InvalidGeometry, DielectricConflict } || Allocator.Error`
//! - `pub fn onSubstrate(stack: Stack, layer: LayerId) bool`
//! - `pub fn inField(stack: Stack, global: []const LayerId, layer: LayerId) bool`
//! - `pub fn buildInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetPolys, global: []const LayerId, selected: []const u32, stack: Stack, options: MeshOptions, grid: Grid, out: *Mesh, refused: *LayerId) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const stack_mod = @import("../stack.zig");
const Stack = stack_mod.Stack;
const NetPolys = @import("../net_polys.zig").NetPolys;
const panel = @import("panel.zig");
const Panel = panel.Panel;
const Panels = panel.Panels;
const Axis = panel.Axis;
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const morton = @import("morton.zig");
const faces = @import("faces.zig");

/// The meshed problem: panels in spatial order, banded by conductor.
/// Invariant: `conductor_start` is CSR over the conductor panels, one band
/// per entry of `conductor_net`; every conductor panel's `conductor` is its
/// band; the interface panels follow, one `interface` entry each.
pub const Mesh = struct {
    panel: Panels = .empty,
    conductor_start: std.ArrayList(u32) = .empty,
    /// The net of each conductor, in the order it was selected.
    conductor_net: std.ArrayList(u32) = .empty,
    /// Relative permittivity per panel: in a uniform stack each layer's own;
    /// in a stratified one the permittivity just outside the panel's face
    /// (above a top face, below a bottom face, beside a side face), and 1 on
    /// an interface panel.
    epsilon: std.ArrayList(f64) = .empty,
    /// `λ = (ε_below − ε_above)/(ε_below + ε_above)` of each interface panel,
    /// `panel[conductor_start[n]..]`. Empty in a uniform stack.
    interface: std.ArrayList(f64) = .empty,

    pub const empty: Mesh = .{};

    pub fn deinit(m: *Mesh, gpa: Allocator) void {
        m.panel.deinit(gpa);
        m.conductor_start.deinit(gpa);
        m.conductor_net.deinit(gpa);
        m.epsilon.deinit(gpa);
        m.interface.deinit(gpa);
    }

    pub fn clear(m: *Mesh) void {
        m.panel.clearRetainingCapacity();
        m.conductor_start.clearRetainingCapacity();
        m.conductor_net.clearRetainingCapacity();
        m.epsilon.clearRetainingCapacity();
        m.interface.clearRetainingCapacity();
    }
};

/// How finely to mesh, and when to refuse.
pub const MeshOptions = struct {
    /// Largest panel edge.
    max_edge: Dbu,
    /// Halve the edge on solids within this distance of another conductor
    /// (0 = off).
    proximity_refine: Dbu,
    /// Refuse rather than mesh beyond this many panels.
    max_panels: u32,
};

/// Why a selection could not be meshed. Each is a refusal; the mesh holds
/// nothing usable after one.
pub const Error = error{
    /// The panels would exceed `MeshOptions.max_panels`.
    TooManyPanels,
    /// A selected polygon is on a layer the mesh panels and the stack does not
    /// describe: no row, or a row whose thickness or permittivity is not
    /// positive or whose height is not finite. `refused` names the smallest
    /// such layer. A layer the mesh leaves out (a junction, a global layer)
    /// needs none of these, but `capacitance.extractInto` refuses a junction
    /// layer with no positive sheet resistance under this name too.
    MissingThickness,
    /// A selected net has no polygons.
    EmptyConductor,
    /// `refused`'s polygons fail validation as rectilinear geometry, so they
    /// cannot be cut into rectangles exactly.
    InvalidGeometry,
    /// `refused`'s `pex` row states a dielectric that differs from another
    /// row's at the same height, so the stack has no one permittivity there.
    DielectricConflict,
} || Allocator.Error;

/// Two heights closer than this, in metres, are one plane.
const same_plane: f64 = 1e-12;

/// One rectangle of a conductor polygon as a solid: grid-unit footprint, z
/// extent in metres.
const Solid = struct {
    box: Bbox,
    z0: f64,
    z1: f64,
    epsilon: f64,
    conductor: u32,
    layer: LayerId,
};

/// One layer's z extent in metres and the permittivity above it.
const Extrusion = struct { z0: f64, z1: f64, epsilon: f64 };

/// Each layer's polygons cut into rectangles, decomposed on first use: an
/// outer row maps to its polygon's rectangles, a hole row to none (its outer
/// carries it).
const RectCache = struct {
    first: []u32,
    count: []u32,
    done: []bool,
    rects: std.ArrayList(Bbox) = .empty,
    valid: geom.ValidatedLayer = .empty,
    cut: std.ArrayList(Bbox) = .empty,
    cut_start: std.ArrayList(u32) = .empty,

    fn init(gpa: Allocator, store: *const GeometryStore) Allocator.Error!RectCache {
        const first = try gpa.alloc(u32, store.polyCount());
        errdefer gpa.free(first);
        const count = try gpa.alloc(u32, store.polyCount());
        errdefer gpa.free(count);
        const done = try gpa.alloc(bool, store.layerCount());
        @memset(count, 0);
        @memset(done, false);
        return .{ .first = first, .count = count, .done = done };
    }

    fn deinit(c: *RectCache, gpa: Allocator) void {
        gpa.free(c.first);
        gpa.free(c.count);
        gpa.free(c.done);
        c.rects.deinit(gpa);
        c.valid.deinit(gpa);
        c.cut.deinit(gpa);
        c.cut_start.deinit(gpa);
    }

    /// `poly`'s rectangles, or null when its layer does not validate.
    fn of(c: *RectCache, gpa: Allocator, store: *const GeometryStore, layer: LayerId, poly: PolyId) Allocator.Error!?[]const Bbox {
        const l = @backingInt(layer);
        if (!c.done[l]) {
            if (try geom.view.validateLayer(gpa, store, layer, .rectilinear, &c.valid) != null) return null;
            c.done[l] = true;
            try geom.rects.decomposeInto(gpa, &c.valid, &c.cut, &c.cut_start);
            for (0..c.valid.len()) |i| {
                const outer = @backingInt(c.valid.get(@intCast(i)).row(0));
                const from = c.cut_start.items[i];
                const to = c.cut_start.items[i + 1];
                c.first[outer] = @intCast(c.rects.items.len);
                c.count[outer] = to - from;
                try c.rects.appendSlice(gpa, c.cut.items[from..to]);
            }
        }
        const p = @backingInt(poly);
        return c.rects.items[c.first[p]..][0..c.count[p]];
    }
};

/// Whether the stack puts `layer` on the substrate, at height 0 or below: a
/// well or a diffusion. Such a shape is a junction in the substrate, whose
/// capacitance to it is a depletion capacitance, so the mesh leaves it out
/// and the solve adds its closed form.
pub fn onSubstrate(stack: Stack, layer: LayerId) bool {
    const l = @backingInt(layer);
    return l < stack.height_nm.len and !(stack.height_nm[l] > 0.0);
}

/// Whether `layer`'s shapes are conductors in the field: neither a junction
/// nor a global layer (the substrate as a net, which carries no modelled
/// parasitics and needs no `pex` row).
pub fn inField(stack: Stack, global: []const LayerId, layer: LayerId) bool {
    return !onSubstrate(stack, layer) and !stack_mod.isGlobal(global, layer);
}

/// Meshes the selected nets into `out` (cleared), one conductor per entry of
/// `selected`, in that order. Each polygon is cut into disjoint rectangles,
/// extruded from its layer's height through its thickness, and each face is
/// cut into panels no longer than `options.max_edge` on a side (half that
/// near another conductor). A polygon on the substrate or on a global layer
/// gets no panels; a conductor of only such polygons has an empty band.
/// Every refusal is checked net by net in selection order, and the panel
/// budget face by face, so an over-limit mesh is refused, never truncated.
/// O(P log P) in the panels, plus a check of every rectangle against every
/// other for proximity refinement.
pub fn buildInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetPolys, global: []const LayerId, selected: []const u32, stack: Stack, options: MeshOptions, grid: Grid, out: *Mesh, refused: *LayerId) Error!void {
    out.clear();
    assert(selected.len < std.math.maxInt(u32));
    var profile: Profile = .empty;
    defer profile.deinit(gpa);
    var conflict: u16 = 0;
    profile.ofInto(gpa, stack, &conflict) catch |err| {
        if (err == error.DielectricConflict) refused.* = @fromBackingInt(conflict);
        return err;
    };
    const layered = profile.isLayered();
    // One database unit, in metres.
    const metre = 1e-6 / @as(f64, @floatFromInt(grid.dbu_per_um));
    const edge = @as(f64, @floatFromInt(options.max_edge)) * metre;

    // Pass one: every selected polygon's rectangles as solids, so proximity
    // refinement can see every other conductor.
    var solids: std.MultiArrayList(Solid) = .empty;
    defer solids.deinit(gpa);
    var cut: RectCache = try .init(gpa, store);
    defer cut.deinit(gpa);
    for (selected, 0..) |net, conductor| {
        const polys = nets.polysOf(net);
        if (polys.len == 0) return error.EmptyConductor;
        // Refuse by the smallest layer id the stack does not describe; only
        // a layer in the field needs a thickness and a permittivity.
        var undescribed: ?u16 = null;
        for (polys) |poly| {
            const layer = store.polyLayer(poly);
            if (!inField(stack, global, layer)) continue;
            if (extrusion(stack, layer) == null) undescribed = @min(undescribed orelse std.math.maxInt(u16), @backingInt(layer));
        }
        if (undescribed) |l| {
            refused.* = @fromBackingInt(l);
            return error.MissingThickness;
        }
        for (polys) |poly| {
            const layer = store.polyLayer(poly);
            if (!inField(stack, global, layer)) continue;
            const row = extrusion(stack, layer).?;
            const rects = (try cut.of(gpa, store, layer, poly)) orelse {
                refused.* = layer;
                return error.InvalidGeometry;
            };
            for (rects) |box| try solids.append(gpa, .{ .box = box, .z0 = row.z0, .z1 = row.z1, .epsilon = row.epsilon, .conductor = @intCast(conductor), .layer = layer });
        }
    }

    // Every side face, by the plane it lies in, so an abutting rectangle of
    // the same conductor and layer can be cut out of its neighbour's face.
    var plane_faces: faces.SideFaces = .empty;
    defer plane_faces.deinit(gpa);
    try plane_faces.buildInto(gpa, solids.items(.box), solids.items(.conductor), solids.items(.layer));

    // Pass two: each solid's six faces, cut at the edge limit.
    var scratch: Panels = .empty;
    defer scratch.deinit(gpa);
    var scratch_epsilon: std.ArrayList(f64) = .empty;
    defer scratch_epsilon.deinit(gpa);
    var pieces: std.ArrayList([2]Dbu) = .empty;
    defer pieces.deinit(gpa);
    var cuts: std.ArrayList(f64) = .empty;
    defer cuts.deinit(gpa);
    var emit: faces.Emit = .{ .panels = &scratch, .epsilon = &scratch_epsilon, .remaining = options.max_panels };
    try out.conductor_start.append(gpa, 0);
    try out.conductor_net.appendSlice(gpa, selected);
    const s = solids.slice();
    // Solids were pushed in conductor order, so each band is one run.
    var band_start: usize = 0;
    for (0..selected.len) |conductor| {
        var band_end = band_start;
        while (band_end < s.len and s.items(.conductor)[band_end] == conductor) band_end += 1;
        for (band_start..band_end) |i| {
            const here = s.get(i);
            const lo = [3]f64{ @as(f64, @floatFromInt(here.box.xlo)) * metre, @as(f64, @floatFromInt(here.box.ylo)) * metre, here.z0 };
            const hi = [3]f64{ @as(f64, @floatFromInt(here.box.xhi)) * metre, @as(f64, @floatFromInt(here.box.yhi)) * metre, here.z1 };
            const near = nearAnotherConductor(s.items(.box), s.items(.conductor), here.box, here.conductor, options.proximity_refine);
            const edge_here = edge / @as(f64, if (near) 2.0 else 1.0);
            emit.conductor = here.conductor;
            emit.edge = edge_here;
            // Bottom, then top; stratified, a face sees the dielectric outside it.
            emit.epsilon_of_face = if (layered) profile.below(lo[2]) else here.epsilon;
            try emit.face(gpa, .z, lo[2], lo, hi);
            emit.epsilon_of_face = if (layered) profile.above(hi[2]) else here.epsilon;
            try emit.face(gpa, .z, hi[2], lo, hi);
            for (faces.sideFaces(here.box)) |side| {
                try plane_faces.uncoveredInto(gpa, side, here.conductor, here.layer, &pieces);
                // The face runs along the other planar axis.
                const axis = @backingInt(side.normal);
                const along = 1 - axis;
                const plane = if (side.low) lo[axis] else hi[axis];
                for (pieces.items) |piece| {
                    var piece_lo = lo;
                    var piece_hi = hi;
                    piece_lo[along] = @as(f64, @floatFromInt(piece[0])) * metre;
                    piece_hi[along] = @as(f64, @floatFromInt(piece[1])) * metre;
                    if (!layered) {
                        emit.epsilon_of_face = here.epsilon;
                        try emit.face(gpa, side.normal, plane, piece_lo, piece_hi);
                        continue;
                    }
                    // Stratified, the face is cut at every interface it
                    // crosses, each slab seeing its own dielectric.
                    cuts.clearRetainingCapacity();
                    try cuts.append(gpa, lo[2]);
                    for (0..profile.interfaceCount()) |k| {
                        const z = profile.interface(@intCast(k)).z;
                        if (z > lo[2] + same_plane and z < hi[2] - same_plane) try cuts.append(gpa, z);
                    }
                    try cuts.append(gpa, hi[2]);
                    for (cuts.items[0 .. cuts.items.len - 1], cuts.items[1..]) |z0, z1| {
                        piece_lo[2] = z0;
                        piece_hi[2] = z1;
                        emit.epsilon_of_face = profile.above(z0);
                        try emit.face(gpa, side.normal, plane, piece_lo, piece_hi);
                    }
                }
            }
        }
        band_start = band_end;
        try out.conductor_start.append(gpa, @intCast(scratch.len));
    }

    // Morton order within each band (not across: bands stay contiguous).
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    const sc = scratch.slice();
    try morton.bandOrderInto(gpa, sc.items(.cx), sc.items(.cy), sc.items(.cz), out.conductor_start.items, &order);
    try out.panel.ensureTotalCapacity(gpa, scratch.len);
    try out.epsilon.ensureTotalCapacity(gpa, scratch.len);
    for (order.items) |row| {
        out.panel.appendAssumeCapacity(sc.get(row));
        out.epsilon.appendAssumeCapacity(scratch_epsilon.items[row]);
    }
    // A zero-area panel would divide by zero in its self-term.
    for (out.panel.items(.area), out.epsilon.items) |area, eps| assert(area > 0.0 and eps > 0.0);

    if (layered) {
        const footprints = try gpa.alloc(profile_mod.Footprint, s.len);
        defer gpa.free(footprints);
        for (footprints, s.items(.box), s.items(.z0), s.items(.z1)) |*f, box, z0, z1| {
            f.* = .{
                .lo = .{ @as(f64, @floatFromInt(box.xlo)) * metre, @as(f64, @floatFromInt(box.ylo)) * metre },
                .hi = .{ @as(f64, @floatFromInt(box.xhi)) * metre, @as(f64, @floatFromInt(box.yhi)) * metre },
                .z = .{ z0, z1 },
            };
        }
        const before = out.panel.len;
        try profile_mod.interfacePanelsInto(gpa, &profile, footprints, edge, @intCast(selected.len), &emit.remaining, &out.panel, &out.interface);
        try out.epsilon.appendNTimes(gpa, 1.0, out.panel.len - before);
    }
}

// ---- private ----

/// `layer`'s extrusion, or null when the stack does not describe it: no
/// row, or a thickness or permittivity that is not positive, or a height
/// that is not finite.
fn extrusion(stack: Stack, layer: LayerId) ?Extrusion {
    const row = @backingInt(layer);
    if (row >= @min(stack.thickness_nm.len, stack.height_nm.len, stack.dielectric_k.len)) return null;
    const thickness = stack.thickness_nm[row];
    const height = stack.height_nm[row];
    const epsilon = stack.dielectric_k[row];
    if (!(thickness > 0.0) or !std.math.isFinite(height) or !(epsilon > 0.0)) return null;
    return .{ .z0 = height * 1e-9, .z1 = (height + thickness) * 1e-9, .epsilon = epsilon };
}

/// Whether a solid sits within `distance` of a conductor other than its own.
// ponytail: O(n²) over the selection's rectangles; a spatial index if selections grow large.
fn nearAnotherConductor(boxes: []const Bbox, conductor: []const u32, box: Bbox, of: u32, distance: Dbu) bool {
    if (distance == 0) return false;
    for (boxes, conductor) |other, c| {
        if (c != of and box.within(other, distance)) return true;
    }
    return false;
}
