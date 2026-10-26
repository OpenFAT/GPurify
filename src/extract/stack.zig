//! The process values the field solver reads, as plain columns: what a deck's
//! `pex` rows and `connect` lines state, without `ingest`'s types, so the
//! engine fills them from its deck and a test from literals. One row per
//! layer id; a layer past a column is undescribed by it.
//!
//! Contents:
//! - `pub const Stack = struct { thickness_nm, height_nm, sheet_res_ohm_sq, area_cap_af_um2, fringe_cap_af_um, dielectric_k: []const f64 }`
//! - `pub const Vias = struct { cut: []const LayerId, connects: []const [2]LayerId }`
//! - `pub const none: u32` (the net of a polygon on no net)
//! - `pub fn isGlobal(global: []const LayerId, layer: LayerId) bool`

const std = @import("std");
const geom = @import("geom");
const LayerId = geom.LayerId;

/// A deck's `pex` rows, by layer id: the stack `ingest.Deck.stack` holds.
/// A non-positive or NaN value is a value the row does not state.
pub const Stack = struct {
    thickness_nm: []const f64,
    /// The layer's bottom above the substrate; 0 puts it on the substrate.
    height_nm: []const f64,
    sheet_res_ohm_sq: []const f64,
    area_cap_af_um2: []const f64,
    fringe_cap_af_um: []const f64,
    /// The dielectric around the layer, filling the stack from its height up.
    dielectric_k: []const f64,
};

/// A deck's `connect via` lines: cut layer `cut[i]` joins `connects[i][0]`
/// below to `connects[i][1]` above.
pub const Vias = struct {
    cut: []const LayerId,
    connects: []const [2]LayerId,
};

/// The net of a polygon on no net (a via cut, a label layer), in a
/// `poly_net` column.
pub const none: u32 = std.math.maxInt(u32);

/// Whether `layer` is one of the deck's `connect global` layers: the
/// substrate as a net, which carries no parasitics and needs no `pex` row.
pub fn isGlobal(global: []const LayerId, layer: LayerId) bool {
    return std.mem.findScalar(LayerId, global, layer) != null;
}
