//! A flat rectangular boundary element, the row of the mesh's panel table.
//! In: nothing. Out: the `Panel` row type the mesh stores as a
//! `std.MultiArrayList` (SoA: the matvec reads its centroid columns alone),
//! and `Ref`, one panel read back as a value for the closed-form integrals.
//!
//! Contents:
//! - `pub const Axis = enum(u8) { x, y, z }`
//! - `pub const Panel = struct { cx, cy, cz, area, half_u, half_v: f64, conductor: u32, normal: Axis }`
//! - `pub const Panels = std.MultiArrayList(Panel)`
//! - `pub const Ref = struct { centre: [3]f64, half: [2]f64, area: f64, normal: u2 }`, `Ref.of(p: Panel) Ref`

const std = @import("std");

/// The axis a face is normal to.
pub const Axis = enum(u8) { x, y, z };

/// Its face is axis-aligned: a top or bottom face of a layer's extrusion, or
/// a side face where no rectangle of the same conductor and layer abuts it.
/// Lengths in metres.
pub const Panel = struct {
    /// Centroid.
    cx: f64,
    cy: f64,
    cz: f64,
    /// `4 · half_u · half_v`.
    area: f64,
    /// Half the panel's sides along the axes `normal + 1` and `normal + 2`
    /// (mod 3).
    half_u: f64,
    half_v: f64,
    /// The conductor it belongs to; one past the last for an interface panel.
    conductor: u32,
    normal: Axis,
};

pub const Panels = std.MultiArrayList(Panel);

/// One panel's geometry as the integrals index it: by axis.
pub const Ref = struct {
    centre: [3]f64,
    half: [2]f64,
    area: f64,
    normal: u2,

    pub fn of(p: Panel) Ref {
        return .{ .centre = .{ p.cx, p.cy, p.cz }, .half = .{ p.half_u, p.half_v }, .area = p.area, .normal = @intCast(@backingInt(p.normal)) };
    }
};
