//! Boundary-element capacitance solve. In: selected nets' polygons and the
//! process stack. Out: the Maxwell `CapMatrix`, one GMRES solve per
//! conductor at unit potential giving one column. Ported from
//! crates/extract/src/field/mod.rs.
//!
//! The pipeline is `mesh.buildInto`, then one `solve.refine` per column.
//! The kernel images every panel in the substrate, a grounded plane at height
//! 0, so ground is the substrate. In a uniform stack every panel carries its
//! free charge in the stack's one dielectric. In a stratified one every
//! panel carries its total charge in vacuum and each interface between two
//! dielectrics is meshed too, its rows holding the continuity of the
//! displacement (`dielectric.zig`); those collocated rows make the operator
//! not symmetric, so the matrix is reciprocal to its discretisation
//! (`stratified_reciprocity`) and reported symmetrised. A shape on a layer
//! at height 0 (a well, a diffusion) is a junction in that plane: it is left
//! out of the mesh, and its closed-form capacitance `Ca·A + Cf·P` sits on its
//! conductor's diagonal. A shape on a global layer carries no parasitics: it
//! is left out too, and needs no `pex` row.
//!
//! Each GMRES iteration is a dense product over every pair of panels, O(P²)
//! for P panels, on the host threads or the GPU (`device`); the panel count
//! is capped at 2²⁰: `extractInto` coarsens the panels until an estimate of
//! the count fits, and the mesh is refused if the real count still exceeds
//! the cap.
//!
//! Contents:
//! - `pub const CapMatrix = struct`, `CapMatrix.empty`, `deinit`, `dim(m) usize`, `asymmetry(m) f64`
//! - `pub const Accuracy = struct { tolerance: f64, iterations: u32, asymmetry: f64, reciprocity: f64 }`
//! - `pub const stratified_reciprocity: f64`
//! - `pub const Error = mesh.Error || solve.Error`
//! - `pub const Diagnostic = struct { layer: LayerId, failure: solve.Failure }`
//! - `pub const Problem = struct { store, nets, global, stack, grid }`
//! - `pub fn extractInto(gpa: Allocator, device: Device, problem: Problem, selected: []const u32, matrix: *CapMatrix, diag: *Diagnostic) Error!Accuracy`
//! - `pub fn extractMeshedInto(gpa: Allocator, device: Device, problem: Problem, selected: []const u32, meshing: MeshOptions, matrix: *CapMatrix, diag: *Diagnostic) Error!Accuracy`
//! - `pub fn extractColumnsInto(gpa: Allocator, device: Device, problem: Problem, selected: []const u32, driven: []const []const u32, meshing: MeshOptions, options: solve.Options, matrix: *CapMatrix, diag: *Diagnostic) Error!u32`
//! - private `Operator.apply`: the operator interface `solve.zig` calls
//! - `pub fn meshOptions(gpa: Allocator, problem: Problem, selected: []const u32) Allocator.Error!MeshOptions`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Device = geom.Device;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const Stack = @import("../stack.zig").Stack;
const NetPolys = @import("../net_polys.zig").NetPolys;
const Regions = @import("../conductor.zig").Regions;
const mesh = @import("mesh.zig");
const MeshOptions = mesh.MeshOptions;
const solve = @import("solve.zig");
const Profile = @import("profile.zig").Profile;
const Potential = @import("matvec.zig").Potential;
const Field = @import("dielectric.zig").Field;
const gpu_mod = @import("gpu.zig");
const Gpu = gpu_mod.Gpu;

/// The Maxwell capacitance matrix, full square so symmetry is checkable.
/// `value[i][i]` is positive, `value[i][j]` for `i ≠ j` is minus the coupling
/// between nets `i` and `j`, and a row sums to net `i`'s capacitance to the
/// substrate. The diagonal also holds the closed-form junction capacitance
/// of net `i`'s shapes on the substrate. A converged solve is symmetric to
/// about its tolerance (reciprocity), which `asymmetry` measures.
pub const CapMatrix = struct {
    /// Each row's net, ascending.
    net: std.ArrayList(u32) = .empty,
    /// Row-major, farads: `n × n` from `extractInto`; `n` rows by one column
    /// per driven set from `extractColumnsInto`.
    value: std.ArrayList(f64) = .empty,

    pub const empty: CapMatrix = .{};

    pub fn deinit(m: *CapMatrix, gpa: Allocator) void {
        m.net.deinit(gpa);
        m.value.deinit(gpa);
    }

    pub fn dim(m: *const CapMatrix) usize {
        return m.net.items.len;
    }

    /// Largest `|C[i][j] − C[j][i]| / √(C[i][i]·C[j][j])`, relative to the
    /// pair's self-capacitances; NaN if any entry is non-finite, so a
    /// poisoned matrix fails every tolerance. The scale is the diagonal, not
    /// the entry: a weakly coupled pair's tiny off-diagonal would otherwise
    /// read the solve's error as a large relative asymmetry (testing-plan
    /// F47). Asserts the matrix square.
    pub fn asymmetry(m: *const CapMatrix) f64 {
        const n = m.dim();
        const v = m.value.items;
        assert(v.len >= n * n);
        var worst: f64 = 0.0;
        // `@max` drops NaN (folding away 0/0 from a zero diagonal), so poison
        // is carried separately: `x * 0` is NaN only for non-finite `x`.
        var poison: f64 = 0.0;
        for (0..n) |i| {
            for (0..n) |j| {
                const entry = v[i * n + j];
                const mirror = v[j * n + i];
                const scale = @sqrt(@abs(v[i * n + i] * v[j * n + j]));
                const gap = @abs(entry - mirror) / scale;
                if (gap > worst) worst = gap;
                poison += entry * 0.0 + mirror * 0.0;
            }
        }
        return worst + poison;
    }
};

/// What a solve achieved, measured in `f64`.
pub const Accuracy = struct {
    /// Relative residual every column was solved to.
    tolerance: f64,
    /// GMRES iterations summed over every column, saturating.
    iterations: u32,
    /// `CapMatrix.asymmetry` before symmetrising; 0 for a matrix that is not
    /// square, where it is undefined.
    asymmetry: f64,
    /// The asymmetry a reciprocal result may show: the tolerance when the
    /// operator is symmetric (a uniform dielectric), `stratified_reciprocity`
    /// when dielectric interfaces make it not.
    reciprocity: f64,
};

/// The asymmetry a capacitance matrix solved with dielectric interfaces may
/// show and still be reciprocal: the interfaces' rows are collocated at
/// panel centroids, so the discrete operator is not symmetric and the matrix
/// is reciprocal only to its discretisation, as `FastCap`'s multi-dielectric
/// matrices are. The matrix reported is the mean of it and its transpose.
pub const stratified_reciprocity: f64 = 5e-2;

pub const Error = mesh.Error || solve.Error;

/// Where a refusal points: the layer a mesh error names, and what a solve
/// reached.
pub const Diagnostic = struct {
    layer: LayerId = @fromBackingInt(0),
    failure: solve.Failure = .{},
};

/// The geometry and process a solve reads: the store, its nets
/// (`NetPolys` from check's per-polygon net column), the deck's global
/// layers, its stack and the grid.
pub const Problem = struct {
    store: *const GeometryStore,
    nets: *const NetPolys,
    global: []const LayerId,
    stack: Stack,
    grid: Grid,
};

/// Refuse rather than mesh beyond this many panels: the matvec is dense.
const max_panels: u32 = 1 << 20;

/// `nmToDbu` for a length the stack does not state; folds away under `@min`.
const unstated: i64 = std.math.maxInt(i64);

/// The field operator one solve applies: the potential rows, the interface
/// rows when stratified, on the GPU when one was set up. A device error
/// drops to the host threads for good, mid-solve: the bodies are one, so the
/// iterate's bits do not change.
const Operator = struct {
    potential: *const Potential,
    field: ?*const Field,
    gpu: ?*Gpu,

    pub fn apply(op: *Operator, x: []const f64, y: []f64) void {
        if (op.gpu) |gpu| {
            if (gpu.apply(x, y)) return else |_| op.gpu = null;
        }
        op.potential.apply(x, y);
        if (op.field) |f| f.apply(x, y);
    }
};

/// Field-solves `selected` into `matrix` (cleared), rows in ascending net
/// order. Duplicates are kept: two conductors on one net is a singular
/// system the solver refuses, rather than a silently smaller matrix. The
/// panel edge is the smallest length the stack states, coarsened until the
/// estimated mesh fits 2²⁰ panels (`meshOptions`); every column is solved
/// to `solve.Options.default`. Errors: every `mesh.Error` (with
/// `diag.layer`), and a column that does not converge, breaks down or goes
/// non-finite (with `diag.failure`).
pub fn extractInto(gpa: Allocator, device: Device, problem: Problem, selected: []const u32, matrix: *CapMatrix, diag: *Diagnostic) Error!Accuracy {
    return extractMeshedInto(gpa, device, problem, selected, try meshOptions(gpa, problem, selected), matrix, diag);
}

/// `extractInto` at a caller's panel size rather than the stack-derived one;
/// `meshing.max_panels` is the cap `error.TooManyPanels` enforces.
pub fn extractMeshedInto(gpa: Allocator, device: Device, problem: Problem, selected: []const u32, meshing: MeshOptions, matrix: *CapMatrix, diag: *Diagnostic) Error!Accuracy {
    const order = try sortedCopy(gpa, selected);
    defer gpa.free(order);
    const columns = try gpa.alloc([]const u32, order.len);
    defer gpa.free(columns);
    const ones = try gpa.alloc(u32, order.len);
    defer gpa.free(ones);
    for (columns, ones, 0..) |*c, *one, i| {
        one.* = @intCast(i);
        c.* = one[0..1];
    }
    return columnsMeshedInto(gpa, device, problem, order, columns, meshing, .default, matrix, diag);
}

/// Columns of the Maxwell matrix with every selected conductor meshed: one
/// solve per entry of `driven`, each entry's nets at one volt together and
/// the rest at ground. `matrix` is `selected.len` rows (ascending net order,
/// `matrix.net`) by `driven.len` columns, row-major. An entry driving several
/// nets is the column of those conductors shorted, in one solve; a row is the
/// charge induced on that conductor, which is what a windowed extraction
/// wants: a net's row is its column, by reciprocity. A driven net not in
/// `selected` is ignored. Returns the GMRES iterations summed over every
/// column. Errors as `extractInto`, with `options` for the tolerance and
/// budgets.
pub fn extractColumnsInto(gpa: Allocator, device: Device, problem: Problem, selected: []const u32, driven: []const []const u32, meshing: MeshOptions, options: solve.Options, matrix: *CapMatrix, diag: *Diagnostic) Error!u32 {
    const order = try sortedCopy(gpa, selected);
    defer gpa.free(order);
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(gpa);
    var start: std.ArrayList(usize) = .empty;
    defer start.deinit(gpa);
    try start.append(gpa, 0);
    for (driven) |set| {
        for (set) |net| {
            if (std.sort.binarySearch(u32, order, net, orderU32)) |row| try rows.append(gpa, @intCast(row));
        }
        try start.append(gpa, rows.items.len);
    }
    const columns = try gpa.alloc([]const u32, driven.len);
    defer gpa.free(columns);
    for (columns, start.items[0..driven.len], start.items[1..]) |*c, from, to| c.* = rows.items[from..to];
    const accuracy = try columnsMeshedInto(gpa, device, problem, order, columns, meshing, options, matrix, diag);
    return accuracy.iterations;
}

/// Panel edge = the smallest length the stack states, coarsened until the
/// estimated panel count fits `max_panels`, floored at one database unit.
/// The scan covers the whole stack, so one thin layer over-meshes a coarse
/// selection: slow and bounded, never under-meshed.
pub fn meshOptions(gpa: Allocator, problem: Problem, selected: []const u32) Allocator.Error!MeshOptions {
    const feature = finestFeature(problem.stack, problem.grid);
    const t: i128 = thickestLayer(problem.stack, problem.grid);
    var surface: i128 = 0;
    var reach: Bbox = .empty;
    for (selected) |net| {
        for (problem.nets.polysOf(net)) |poly| {
            if (!mesh.inField(problem.stack, problem.global, problem.store.polyLayer(poly))) continue;
            const box = problem.store.polyBbox(poly);
            reach = reach.merge(box);
            const w: i128 = @max(box.xhi - box.xlo, 0);
            const h: i128 = @max(box.yhi - box.ylo, 0);
            surface += 2 * (w * h + (w + h) * t);
        }
    }
    // Each dielectric interface is meshed across the selection's footprint.
    const interfaces = try interfaceCount(gpa, problem.stack);
    if (interfaces > 0) {
        const w: i128 = @max(reach.xhi - reach.xlo, 0);
        const h: i128 = @max(reach.yhi - reach.ylo, 0);
        surface += w * h * interfaces;
    }
    const edge = std.math.clamp(@max(feature, budgetEdge(surface)), 1, geom.max_abs_dbu);
    return .{ .max_edge = edge, .proximity_refine = edge, .max_panels = max_panels };
}

// ---- private ----

fn columnsMeshedInto(gpa: Allocator, device: Device, problem: Problem, order: []const u32, columns: []const []const u32, meshing: MeshOptions, options: solve.Options, matrix: *CapMatrix, diag: *Diagnostic) Error!Accuracy {
    matrix.net.clearRetainingCapacity();
    matrix.value.clearRetainingCapacity();
    var m: mesh.Mesh = .empty;
    defer m.deinit(gpa);
    try mesh.buildInto(gpa, problem.store, problem.nets, problem.global, order, problem.stack, meshing, problem.grid, &m, &diag.layer);
    const junction = try gpa.alloc(f64, order.len);
    defer gpa.free(junction);
    try junctionsFarad(gpa, problem, order, junction, &diag.layer);

    const n = order.len;
    const width = columns.len;
    try matrix.net.appendSlice(gpa, order);
    try matrix.value.appendNTimes(gpa, 0.0, n * width);

    const panels = m.panel.slice();
    const stratified = m.interface.items.len > 0;
    const first = m.conductor_start.items[n];
    // Stratified, every charge sits in vacuum: the conductors' rows are
    // potentials, the interfaces' rows hold the dielectrics.
    const vacuum = try gpa.alloc(f64, if (stratified) panels.len else 0);
    defer gpa.free(vacuum);
    @memset(vacuum, 1.0);
    var potential = try Potential.init(gpa, device.threads, panels, if (stratified) vacuum else m.epsilon.items, if (stratified) first else @intCast(panels.len));
    defer potential.deinit(gpa);
    var field: ?Field = if (stratified) try Field.init(gpa, device.threads, panels, first, m.interface.items) else null;
    defer if (field) |*f| f.deinit(gpa);
    var gpu: ?Gpu = if (gpu_mod.wanted(device, panels.len)) Gpu.init(gpa, device, &potential, if (field) |*f| f else null) else null;
    defer if (gpu) |*e| e.deinit();
    var op: Operator = .{ .potential = &potential, .field = if (field) |*f| f else null, .gpu = if (gpu) |*e| e else null };

    const iterations = try columnsInto(gpa, &op, &m, options, columns, matrix, diag);
    // A junction is a capacitor from its conductor to the substrate, in
    // parallel with the field: at one volt it adds its own charge.
    for (columns, 0..) |column, slot| {
        for (junction, 0..) |farads, row| {
            if (std.mem.findScalar(u32, column, @intCast(row)) != null) matrix.value.items[row * width + slot] += farads;
        }
    }
    const square = width == n;
    const asymmetry = if (square) matrix.asymmetry() else 0.0;
    // Reciprocal only to the discretisation: report the symmetric part.
    if (stratified and square) {
        const v = matrix.value.items;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                const mean = midpoint(v[i * n + j], v[j * n + i]);
                v[i * n + j] = mean;
                v[j * n + i] = mean;
            }
        }
    }
    return .{
        .tolerance = options.tolerance,
        .iterations = iterations,
        .asymmetry = asymmetry,
        .reciprocity = if (stratified) stratified_reciprocity else options.tolerance,
    };
}

/// One solve per column into a sized `CapMatrix`; returns the total
/// iteration count. A conductor's charge is its panels' total charge each
/// times the permittivity outside it in a stratified stack, where the
/// unknown is total charge; their plain sum otherwise (an area weight would
/// break reciprocity). Interface panels are held to zero, the continuity
/// their rows state. Zero initial guess, never a warm start: columns stay
/// independent.
fn columnsInto(gpa: Allocator, op: *Operator, m: *const mesh.Mesh, options: solve.Options, columns: []const []const u32, matrix: *CapMatrix, diag: *Diagnostic) Error!u32 {
    const n = m.conductor_net.items.len;
    const width = columns.len;
    const panels = m.panel.len;
    const stratified = m.interface.items.len > 0;
    const conductor = m.panel.items(.conductor);
    var ws: solve.Workspace = .empty;
    defer ws.deinit(gpa);
    const potential = try gpa.alloc(f64, panels);
    defer gpa.free(potential);
    const charge = try gpa.alloc(f64, panels);
    defer gpa.free(charge);
    const driven = try gpa.alloc(bool, n);
    defer gpa.free(driven);
    const conductors_end = m.conductor_start.items[n];
    var iterations: u32 = 0;
    for (columns, 0..) |column, slot| {
        @memset(driven, false);
        for (column) |c| driven[c] = true;
        // One volt on the driven conductors, ground on the rest, and zero on
        // every interface panel's continuity row.
        @memset(potential, 0.0);
        for (potential[0..conductors_end], conductor[0..conductors_end]) |*p, c| p.* = if (driven[c]) 1.0 else 0.0;
        @memset(charge, 0.0);
        const converged = try solve.refine(gpa, op, potential, options, charge, &ws, &diag.failure);
        assert(converged.residual <= options.tolerance);
        iterations +|= converged.iterations;
        for (0..n) |row| {
            const from = m.conductor_start.items[row];
            const to = m.conductor_start.items[row + 1];
            var total: f64 = 0.0;
            if (stratified) {
                for (charge[from..to], m.epsilon.items[from..to]) |q, eps| total += eps * q;
            } else {
                for (charge[from..to]) |q| total += q;
            }
            if (!std.math.isFinite(total)) {
                diag.failure = .{ .iterations = iterations };
                return error.NonFinite;
            }
            matrix.value.items[row * width + slot] = total;
        }
    }
    return iterations;
}

/// Each conductor's junction capacitance in farads into `out`: the closed
/// form `Ca·A + Cf·P` of its regions on layers the stack puts on the
/// substrate, which the mesh leaves out. A global layer carries no
/// parasitics, so none of its shapes is a junction.
fn junctionsFarad(gpa: Allocator, problem: Problem, order: []const u32, out: []f64, refused: *LayerId) Error!void {
    const layers = problem.store.layerCount();
    const keep = try gpa.alloc(bool, layers);
    defer gpa.free(keep);
    for (keep, 0..) |*k, l| {
        const layer: LayerId = @fromBackingInt(@intCast(l));
        k.* = mesh.onSubstrate(problem.stack, layer) and !@import("../stack.zig").isGlobal(problem.global, layer);
    }
    var regions: Regions = .empty;
    defer regions.deinit(gpa);
    const per_um: f64 = @floatFromInt(problem.grid.dbu_per_um);
    for (order, out) |net, *farads| {
        const first = regions.len();
        if (try regions.pushNet(gpa, problem.store, problem.nets.polysOf(net), net, keep)) |bad| {
            refused.* = bad;
            return error.InvalidGeometry;
        }
        var femtofarads: f64 = 0.0;
        for (first..regions.len()) |region| {
            // A junction layer no row describes has unknown parasitics, not
            // none: an unstated row reads height 0, so lands here (F30).
            if (!@import("../stack.zig").described(problem.stack, regions.layer.items[region])) {
                refused.* = regions.layer.items[region];
                return error.MissingThickness;
            }
            const row = @backingInt(regions.layer.items[region]);
            const area_af_um2 = if (row < problem.stack.area_cap_af_um2.len) problem.stack.area_cap_af_um2[row] else 0.0;
            const fringe_af_um = if (row < problem.stack.fringe_cap_af_um.len) problem.stack.fringe_cap_af_um[row] else 0.0;
            const area_um2 = @as(f64, @floatFromInt(regions.area.items[region])) / (per_um * per_um);
            const perimeter_um = @as(f64, @floatFromInt(regions.perimeter.items[region])) / per_um;
            // Two separate products, so the area and fringe terms superpose exactly.
            femtofarads += (area_af_um2 * area_um2 + fringe_af_um * perimeter_um) / 1_000.0;
        }
        farads.* = femtofarads * 1e-15;
    }
}

/// The smallest length the stack states, in database units: every layer's
/// thickness and every positive interlayer gap. `unstated` if none.
fn finestFeature(stack: Stack, grid: Grid) i64 {
    const rows = @min(stack.thickness_nm.len, stack.height_nm.len);
    var finest = unstated;
    for (0..rows) |a| {
        finest = @min(finest, nmToDbu(stack.thickness_nm[a], grid));
        const ceiling = stack.height_nm[a] + stack.thickness_nm[a];
        // Both orders: the reversed pair's negative gap is dropped by `nmToDbu`.
        for (0..rows) |b| finest = @min(finest, nmToDbu(stack.height_nm[b] - ceiling, grid));
    }
    return finest;
}

/// The largest stated layer thickness, in database units, or zero.
fn thickestLayer(stack: Stack, grid: Grid) i64 {
    var thickest: i64 = 0;
    for (stack.thickness_nm) |nm| {
        const stated = nmToDbu(nm, grid);
        if (stated != unstated) thickest = @max(thickest, stated);
    }
    return thickest;
}

/// The finest edge whose estimated panel count fits `max_panels`:
/// `2 √(S / max_panels)` rounded up (proximity refinement may quarter a
/// panel).
fn budgetEdge(surface: i128) i64 {
    const area: f64 = @floatFromInt(surface);
    const edge = @ceil(2.0 * @sqrt(area / @as(f64, max_panels)));
    return std.math.clamp(saturate(edge), 1, geom.max_abs_dbu);
}

/// A stated length in nm as database units, rounded down (a mesh target, not
/// a deck limit), floored at one; `unstated` for a non-positive or NaN length.
fn nmToDbu(nm: f64, grid: Grid) i64 {
    if (!(nm > 0.0)) return unstated;
    const per_um: f64 = @floatFromInt(grid.dbu_per_um);
    return std.math.clamp(saturate(@floor(nm * per_um / 1_000.0)), 1, geom.max_abs_dbu);
}

/// Rust's saturating `f64 as i64`: NaN to 0, out of range to the ends.
fn saturate(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    if (v >= 0x1p63) return std.math.maxInt(i64);
    if (v <= -0x1p63) return std.math.minInt(i64);
    return @intFromFloat(v);
}

/// The interfaces the stack's profile has; 0 for a stack with a conflict
/// (the mesh refuses it).
fn interfaceCount(gpa: Allocator, stack: Stack) Allocator.Error!u32 {
    var profile: Profile = .empty;
    defer profile.deinit(gpa);
    var conflict: u16 = 0;
    profile.ofInto(gpa, stack, &conflict) catch |err| switch (err) {
        error.DielectricConflict => return 0,
        error.OutOfMemory => |e| return e,
    };
    return profile.interfaceCount();
}

fn sortedCopy(gpa: Allocator, selected: []const u32) Allocator.Error![]u32 {
    const order = try gpa.dupe(u32, selected);
    std.mem.sortUnstable(u32, order, {}, std.sort.asc(u32));
    return order;
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Rust's `f64::midpoint` for values far from overflow, as capacitances are.
fn midpoint(a: f64, b: f64) f64 {
    return (a + b) / 2.0;
}
