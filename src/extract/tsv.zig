//! Through-silicon vias (catalog PEX-015, the TSV part of 3D-IC
//! extraction). In: the network, the layout, its per-polygon net column, the
//! deck's via rows and its `pex_tsv` lines. Out: every TSV cut's liner
//! capacitance to ground on its net's first node. Ported from
//! crates/extract/src/tsv.rs.
//!
//! A cut on a `pex_tsv` layer is a copper cylinder through the silicon
//! inside an oxide liner, a coaxial capacitor to the grounded silicon:
//! `C = 2π ε₀ k L / ln((r + t) / r)` (Katti, Stucchi, De Meyer and Dehaene,
//! IEEE Trans. Electron Devices 57(1), 2010, eq. 2), `r = √(A/π)` the radius
//! of the circle of the cut's drawn area. Not modelled: the depletion
//! capacitance in series with the liner, TSV-to-TSV coupling, micro-bumps
//! and interposer wiring.
//!
//! Contents:
//! - `pub const Tsv = struct { layer: LayerId, length_nm: f64, liner_nm: f64, liner_k: f64 }`
//! - `pub fn linerCapacitanceFf(tsv: Tsv, area_um2: f64) f64`
//! - `pub fn addInto(gpa: Allocator, network: *ParasiticNetwork, store: *const GeometryStore, poly_net: []const u32, vias: Vias, tsvs: []const Tsv, grid: Grid) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const stack_mod = @import("stack.zig");
const Vias = stack_mod.Vias;
const ParasiticNetwork = @import("network.zig").ParasiticNetwork;

/// One `pex_tsv` line, its layer resolved.
pub const Tsv = struct { layer: LayerId, length_nm: f64, liner_nm: f64, liner_k: f64 };

/// ε₀ in fF/µm.
const epsilon0_ff_per_um: f64 = 8.8541878128e-3;

/// The liner capacitance, fF, of one TSV whose cut covers `area_um2` µm²; a
/// liner of zero thickness reads infinite.
pub fn linerCapacitanceFf(tsv: Tsv, area_um2: f64) f64 {
    const r = @sqrt(area_um2 / std.math.pi);
    const length = tsv.length_nm / 1000.0;
    const liner = tsv.liner_nm / 1000.0;
    return 2.0 * std.math.pi * epsilon0_ff_per_um * tsv.liner_k * length / @log((r + liner) / r);
}

/// Adds every TSV cut's liner capacitance to ground on the first node of
/// the net of the conductor shape its centre lands on (the plates its layer
/// joins, in deck order, each layer's first shape holding the point), then
/// restores canonical order. A cut on no net's shape, or on a net with no
/// node, adds nothing.
pub fn addInto(gpa: Allocator, network: *ParasiticNetwork, store: *const GeometryStore, poly_net: []const u32, vias: Vias, tsvs: []const Tsv, grid: Grid) Allocator.Error!void {
    if (tsvs.len == 0) return;
    assert(poly_net.len == store.polyCount());
    const per_um: f64 = @floatFromInt(grid.dbu_per_um);
    for (tsvs) |tsv| {
        const cuts = store.polysOnLayer(tsv.layer);
        for (cuts.start..cuts.end) |row| {
            const cut: geom.PolyId = @fromBackingInt(@intCast(row));
            const centre = geom.ops.centre(store.polyBbox(cut));
            const net = landing: for (vias.cut, vias.connects) |via_cut, plates| {
                if (via_cut != tsv.layer) continue;
                for (plates) |on| {
                    const rows = store.polysOnLayer(on);
                    const hit = for (rows.start..rows.end) |p| {
                        if (store.polyContainsPoint(@fromBackingInt(@intCast(p)), centre)) break p;
                    } else continue;
                    if (poly_net[hit] != stack_mod.none) break :landing poly_net[hit];
                }
            } else continue;
            const node = network.firstNode(net) orelse continue;
            const ring = store.polyVerts(cut);
            const area: f64 = @floatFromInt(@abs(geom.ops.area2(ring.xs, ring.ys)) / 2);
            try network.push(gpa, node, .ground, .ground_cap, linerCapacitanceFf(tsv, area / (per_um * per_um)));
        }
    }
    try network.sortCanonical(gpa);
}

test "a tsv liner is the coaxial closed form" {
    // Oracle: closed form (Katti et al. 2010, eq. 2), written out: a 5 × 5
    // µm cut is a cylinder of radius `5/√π`; 50 µm long in a 0.2 µm liner of
    // k = 3.9 it is `2π ε₀ k L / ln((r + t)/r)`.
    const r = 5.0 / @sqrt(std.math.pi);
    const want = 2.0 * std.math.pi * 8.8541878128e-3 * 3.9 * 50.0 / @log((r + 0.2) / r);
    try std.testing.expectApproxEqRel(want, linerCapacitanceFf(.{ .layer = @fromBackingInt(0), .length_nm = 50_000, .liner_nm = 200, .liner_k = 3.9 }, 25.0), 1e-12);
}
