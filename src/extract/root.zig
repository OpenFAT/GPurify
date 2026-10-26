//! extract: parasitic extraction's field solver and its network readout
//! (ARCHITECTURE.md). Only re-exports; extract's Gompute kernel root.
//!
//! The solver reads nets as check's per-polygon net column (`poly_net`, to
//! `NetPolys`) and the process as plain columns (`Stack`, `Vias`), so it
//! needs neither check's nor ingest's types.
//!
//! Contents:
//! - `Stack`, `Vias`, `none`, `isGlobal` (stack.zig)
//! - `NetPolys` (net_polys.zig)
//! - `conductor`: `Regions`
//! - `cholesky`: `factorInPlace`, `solveInPlace`
//! - `solve`: GMRES and refinement (field/solve.zig)
//! - `mesh`: `Mesh`, `MeshOptions`, `buildInto` (field/mesh.zig)
//! - `panel`: `Panel`, `Panels`, `Axis`, `Ref` (field/panel.zig)
//! - `capacitance`: `CapMatrix`, `Accuracy`, `extractInto`, ... (field/capacitance.zig)
//! - `matvec`, `dielectric`: the row kernels and their host operators; `NearPairs` (field/near.zig)
//! - `gpu`: `Gpu`, the row kernels' host GPU path (field/gpu.zig)
//! - `filament`: partial-inductance integrals (field/filament.zig)
//! - `henry`: `InductMatrix`, `extractInductanceInto` (field/henry.zig)
//! - `network`: `ParasiticNetwork`, `NodeId`, `Kind` (network.zig)
//! - `quasistatic`: `extractInto`, `extractInductanceInto`, `overlay` (quasistatic.zig)
//! - `compare`: `Comparison`, `Metric`, `Errors`, `errors`, `compareInto` (compare.zig)
//! - `reduce`: `reduce` (reduce.zig)
//! - `analytical`: `Problem`, `Error`, `Refusal`, `extractInto`, `nodeRectsInto` (analytical.zig)

const stack = @import("stack.zig");
pub const conductor = @import("conductor.zig");
pub const cholesky = @import("cholesky.zig");
pub const solve = @import("field/solve.zig");
pub const mesh = @import("field/mesh.zig");
pub const panel = @import("field/panel.zig");
pub const capacitance = @import("field/capacitance.zig");
pub const matvec = @import("field/matvec.zig");
pub const dielectric = @import("field/dielectric.zig");
pub const gpu = @import("field/gpu.zig");
pub const filament = @import("field/filament.zig");
pub const henry = @import("field/henry.zig");
pub const network = @import("network.zig");
pub const quasistatic = @import("quasistatic.zig");
pub const analytical = @import("analytical.zig");
pub const reduce = @import("reduce.zig");
pub const compare = @import("compare.zig");
pub const NetPolys = @import("net_polys.zig").NetPolys;
pub const NearPairs = @import("field/near.zig").NearPairs;

pub const Stack = stack.Stack;
pub const Vias = stack.Vias;
pub const none = stack.none;
pub const isGlobal = stack.isGlobal;

// The device compile reads only this root's comptime blocks: name every
// kernel-owning file here.
comptime {
    _ = matvec;
    _ = dielectric;
}

test {
    _ = stack;
    _ = conductor;
    _ = cholesky;
    _ = solve;
    _ = mesh;
    _ = capacitance;
    _ = matvec;
    _ = dielectric;
    _ = gpu;
    _ = filament;
    _ = henry;
    _ = network;
    _ = quasistatic;
    _ = analytical;
    _ = reduce;
    _ = compare;
    _ = @import("closed_form.zig");
    _ = @import("joins.zig");
    _ = @import("net_polys.zig");
    _ = @import("field/morton.zig");
    _ = @import("field/faces.zig");
    _ = @import("field/profile.zig");
    _ = @import("field/integrals.zig");
    _ = @import("field/near.zig");
    _ = @import("field/rows.zig");
    _ = @import("field/lanes.zig");
}
