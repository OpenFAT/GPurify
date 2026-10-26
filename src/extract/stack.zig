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
//! - `pub fn value(column: []const f64, layer: usize) f64`
//! - `pub fn described(stack: Stack, layer: LayerId) bool`

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

/// `column`'s value for `layer`, 0 (not stated) past its end.
pub fn value(column: []const f64, layer: usize) f64 {
    return if (layer < column.len) column[layer] else 0.0;
}

/// Whether the stack gives `layer` a positive, finite sheet resistance (Ω
/// per cut on a via layer): the one value every stated row has.
pub fn described(stack: Stack, layer: LayerId) bool {
    const ohm = value(stack.sheet_res_ohm_sq, @backingInt(layer));
    return ohm > 0.0 and std.math.isFinite(ohm);
}

test "a stack describes the layers its sheet column states and nothing past it" {
    // Oracle: construct-from-answer (the Rust `stack_row` test). A four-row
    // stack answers for layers 0 to 3 and nothing above; an empty stack
    // describes no layer, and a zero or NaN sheet is no description.
    const sheet = [_]f64{ 0.1, 0.1, 0.0, std.math.nan(f64) };
    const s: Stack = .{ .thickness_nm = &.{}, .height_nm = &.{}, .sheet_res_ohm_sq = &sheet, .area_cap_af_um2 = &.{}, .fringe_cap_af_um = &.{}, .dielectric_k = &.{} };
    for ([_]u16{ 0, 1 }) |l| try std.testing.expect(described(s, @fromBackingInt(l)));
    for ([_]u16{ 2, 3, 4, 63, std.math.maxInt(u16) }) |l| try std.testing.expect(!described(s, @fromBackingInt(l)));
    try std.testing.expectEqual(0.0, value(&sheet, 9));
    var empty = s;
    empty.sheet_res_ohm_sq = &.{};
    try std.testing.expect(!described(empty, @fromBackingInt(0)));
}
