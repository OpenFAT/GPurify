//! extract: parasitic extraction, the resistance, capacitance and
//! inductance a layout adds to the circuit it draws (ARCHITECTURE.md). Only
//! re-exports; extract's Gompute kernel root. Ported from
//! crates/extract/src/lib.rs.
//!
//! Nets come as check's per-polygon net column (`poly_net`, to `NetPolys`),
//! devices as plain columns (`device_region.Mos`), the process as plain
//! columns (`Stack`, `Vias`), so nothing here imports check. Two methods
//! write one `ParasiticNetwork` (Ω, fF, pH): `analytical`, closed forms
//! over every net (Weste & Harris ch. 6: `Rs·L/W` per region, `Rcut/n` per
//! via array, `Ca·A + Cf·P` to ground, lateral `ε₀εr·t·L/S`, interlayer
//! `ε₀εr·A/d`); and `quasistatic`, a field solve of named nets laid over it.
//! The pex spine then adds device-region, TSV, substrate and fill effects
//! and `reduce`s to the deck's extraction type; `compare` qualifies one
//! extraction against another, `spef`/`dspf` read another tool's.
//!
//! Known gaps, so a number reads for what it is: analytical R chains a
//! net's regions in layer order, not along the current path, and a region
//! reads as the rectangle of its area and perimeter; analytical coupling is
//! parallel-plate between rectangles, no fringe and no shielding (a lower
//! bound); dielectric interfaces in the field solve are windowed and
//! horizontal only; a junction (height 0) is closed form; only selected
//! nets are in the field; inductance resolves crowding to a four-cell grid
//! and one frequency (1 MHz, no skin effect). An undescribed layer is
//! refused by both methods, never read as a perfect wire.
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
//! - `foreign`: `Read`, `Error`, `Diagnostic` (foreign.zig); `spef.readInto`, `dspf.readInto`
//! - `fill`: `Treatment`, `Fill`, `treat` (fill.zig)
//! - `tsv`: `Tsv`, `linerCapacitanceFf`, `addInto` (tsv.zig)
//! - `device_region`: `Mos`, `addInto` (device_region.zig)
//! - `substrate`: `Profile`, `Admittance`, `linesInto`, `admittanceInto`, `addInto` (substrate*.zig)
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
pub const foreign = @import("foreign.zig");
pub const spef = @import("spef.zig");
pub const dspf = @import("dspf.zig");
pub const fill = @import("fill.zig");
pub const tsv = @import("tsv.zig");
pub const device_region = @import("device_region.zig");
pub const substrate = @import("substrate.zig");
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
    _ = foreign;
    _ = spef;
    _ = dspf;
    _ = fill;
    _ = tsv;
    _ = device_region;
    _ = substrate;
    _ = @import("substrate_solve.zig");
    _ = @import("substrate_modes.zig");
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
