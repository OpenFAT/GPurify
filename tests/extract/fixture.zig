//! Layouts and stacks for the field-solver suites. A case's nets are stated
//! with its shapes (construct-from-answer: the Rust suites ran check's net
//! extraction, whose answer on these layouts is known by construction), and
//! a stack is three rows, `m1`, `v1` and `m2` as layers 0, 1 and 2, as
//! tests/exhaustive/pex.rs writes its decks.
//!
//! Contents:
//! - `pub const grid: geom.Grid` (1 nm)
//! - `pub const Shape = struct { layer: u16, net: u32, xs: []const i64, ys: []const i64 }`, `pub const Box = struct { layer: u16, net: u32, r: [4]i64 }`
//! - `pub const Case = struct`, `Case.init(boxes: []const Box, polygons: []const Shape, layer_count: u16) !Case`, `deinit`, `problem(c, rows: *const Rows) capacitance.Problem`
//! - `pub const Row = struct { thickness, height, sheet, k, area, fringe: f64 }`, `pub const Rows = struct`, `Rows.of(m1, v1, m2) Rows`, `Rows.stack(r: *const Rows) Stack`,
//!   `Rows.scaled(r: Rows, f: f64) Rows`, `Rows.uniform(k: f64) Rows`
//! - `pub const coarse: Rows`, `pub const junction: Rows`, `pub fn uniformRows(n, area, fringe) Rows`
//! - `pub const device: geom.Device`
//! - `pub fn solveFf(c: *const Case, rows: *const Rows, selected: []const u32, out: []f64) !capacitance.Accuracy`

const std = @import("std");
const geom = @import("geom");
const extract = @import("extract");
const testgen = @import("testgen");
const capacitance = extract.capacitance;
const gpa = std.testing.allocator;

pub const grid: geom.Grid = .{ .dbu_per_um = 1000 };

/// The device every solve here runs on: the host, eight threads.
pub const device: geom.Device = .{ .backend = .cpu, .min_gpu_work = std.math.maxInt(u64), .threads = 8 };

/// One drawn ring and the net it is on (`extract.none` for none).
pub const Shape = struct { layer: u16, net: u32, xs: []const i64, ys: []const i64 };

/// One drawn rectangle `[xlo, ylo, xhi, yhi]` and the net it is on.
pub const Box = struct { layer: u16, net: u32, r: [4]i64 };

/// A store, its per-polygon net column and its nets.
pub const Case = struct {
    store: geom.GeometryStore = .empty,
    poly_net: []u32 = &.{},
    nets: extract.NetPolys = .empty,

    /// The boxes, then the polygons, over `layer_count` layers.
    pub fn init(boxes: []const Box, polygons: []const Shape, layer_count: u16) !Case {
        var c: Case = .{};
        errdefer c.deinit();
        var lb: testgen.shapes.LayoutBuilder = .init(layer_count);
        defer lb.deinit(gpa);
        var net: std.ArrayList(u32) = .empty;
        defer net.deinit(gpa);
        for (boxes) |b| {
            _ = try lb.rect(gpa, b.layer, b.r[0], b.r[1], b.r[2], b.r[3]);
            try net.append(gpa, b.net);
        }
        for (polygons) |s| {
            _ = try lb.push(gpa, s.layer, s.xs, s.ys);
            try net.append(gpa, s.net);
        }
        var net_count: u32 = 0;
        for (net.items) |n| {
            if (n != extract.none) net_count = @max(net_count, n + 1);
        }
        var ids: testgen.shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &c.store, &ids);
        c.poly_net = try gpa.alloc(u32, net.items.len);
        for (net.items, 0..) |n, i| c.poly_net[@backingInt(ids.of(@fromBackingInt(@intCast(i))))] = n;
        try c.nets.buildInto(gpa, c.poly_net, net_count);
        return c;
    }

    pub fn deinit(c: *Case) void {
        c.store.deinit(gpa);
        gpa.free(c.poly_net);
        c.nets.deinit(gpa);
    }

    pub fn problem(c: *const Case, rows: *const Rows) capacitance.Problem {
        return .{ .store = &c.store, .nets = &c.nets, .global = &.{}, .stack = rows.stack(), .grid = grid };
    }
};

/// One `pex` row: lengths in nm, sheet in Ω/□ (Ω per cut on a via layer),
/// area capacitance in aF/µm², fringe in aF/µm. A `k` of zero states no
/// dielectric.
pub const Row = struct { thickness: f64, height: f64, sheet: f64, k: f64, area: f64, fringe: f64 };

/// The stack's rows as columns, by layer.
pub const Rows = struct {
    thickness: [3]f64,
    height: [3]f64,
    sheet: [3]f64,
    k: [3]f64,
    area: [3]f64,
    fringe: [3]f64,

    pub fn of(m1: Row, v1: Row, m2: Row) Rows {
        var r: Rows = undefined;
        inline for (.{ "thickness", "height", "sheet", "k", "area", "fringe" }) |f| @field(r, f) = .{ @field(m1, f), @field(v1, f), @field(m2, f) };
        return r;
    }

    pub fn stack(r: *const Rows) extract.Stack {
        return .{ .thickness_nm = &r.thickness, .height_nm = &r.height, .sheet_res_ohm_sq = &r.sheet, .area_cap_af_um2 = &r.area, .fringe_cap_af_um = &r.fringe, .dielectric_k = &r.k };
    }

    /// Every length times `f`; the coefficients per area and length stay.
    pub fn scaled(r: Rows, f: f64) Rows {
        var out = r;
        for (&out.thickness, &out.height) |*t, *h| {
            t.* *= f;
            h.* *= f;
        }
        return out;
    }

    /// Every row's dielectric `k`.
    pub fn uniform(r: Rows, k: f64) Rows {
        var out = r;
        out.k = @splat(k);
        return out;
    }
};

/// Thick layers 500 nm apart, `m1` 250 nm over the substrate: the finest
/// stated length is 500 nm, the field solve's panel edge.
pub const coarse: Rows = .of(
    .{ .thickness = 500, .height = 250, .sheet = 0.1, .k = 3.9, .area = 25, .fringe = 40 },
    .{ .thickness = 500, .height = 750, .sheet = 5.0, .k = 3.9, .area = 0, .fringe = 0 },
    .{ .thickness = 500, .height = 1250, .sheet = 0.08, .k = 3.9, .area = 15, .fringe = 30 },
);

/// `coarse` with `m1` a junction, as a diffusion is: on the substrate
/// (height 0) and up to `v1`, so the field solve reads it in closed form.
pub const junction: Rows = blk: {
    var r = coarse;
    r.thickness[0] = 750;
    r.height[0] = 0;
    break :blk r;
};

/// `crates/extract/tests/field/common`'s `uniform_stack`: three identical
/// rows, 100 nm thick at 300 nm, 0.1 Ω/□, k 3.9.
pub fn uniformRows(area: f64, fringe: f64) Rows {
    const row: Row = .{ .thickness = 100, .height = 300, .sheet = 0.1, .k = 3.9, .area = area, .fringe = fringe };
    return .of(row, row, row);
}

/// The Maxwell matrix of `selected` in fF into `out` (row-major, rows in
/// ascending net order, as `capacitance.extractInto` gives them).
pub fn solveFf(c: *const Case, rows: *const Rows, selected: []const u32, out: []f64) !capacitance.Accuracy {
    var matrix: capacitance.CapMatrix = .empty;
    defer matrix.deinit(gpa);
    var diag: capacitance.Diagnostic = .{};
    const accuracy = try capacitance.extractInto(gpa, device, c.problem(rows), selected, &matrix, &diag);
    for (out, matrix.value.items) |*o, v| o.* = v * 1e15;
    return accuracy;
}
