//! The current one network edge may carry, the limit the EM and ESD-path
//! kinds share. In: the edge's kind and width, the grid, a row's limits.
//! Out: microamps. Ported from crates/check/src/erc/rules/electrical.rs
//! (`allowed_current`).
//!
//! Contents:
//! - `pub fn allowedCurrent(kind: EdgeKind, width: Dbu, grid: Grid, max_density: CurrentDensity, max_current_per_cut: Microamps, narrow: ?Narrow) Microamps`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const Microamps = @import("../report.zig").Microamps;
const EdgeKind = @import("power_grid.zig").EdgeKind;
const electrical = @import("electrical_tables.zig");
const CurrentDensity = electrical.CurrentDensity;
const Narrow = electrical.Narrow;

/// Density times width for metal, or the narrow band's current for metal
/// at most its width wide; the per-cut limit for a via (one cut per edge).
/// A zero width allows nothing unless a band covers it. A device edge is
/// rated by its own size, not here: it is allowed any current.
pub fn allowedCurrent(kind: EdgeKind, width: Dbu, grid: Grid, max_density: CurrentDensity, max_current_per_cut: Microamps, narrow: ?Narrow) Microamps {
    return switch (kind) {
        .metal => if (narrow) |n| (if (width <= n.width) n.current else perWidth(width, grid, max_density)) else perWidth(width, grid, max_density),
        .via => max_current_per_cut,
        .device => .{ .raw = std.math.inf(f64) },
    };
}

// ---- private ----

/// `A/m * m = A`, on base values, in µA.
fn perWidth(width: Dbu, grid: Grid, max_density: CurrentDensity) Microamps {
    const amps: geom.Qty(.current, .base) = .{ .raw = max_density.raw * grid.toLength(width).base() };
    return amps.to(.micro);
}
