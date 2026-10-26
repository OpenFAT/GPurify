//! Dielectric interfaces' operator rows: a stratified stack in the field
//! solve. In: every panel's centroid and the interface panels' `λ`. Out:
//! the interface rows of `y`, each zero exactly when the interface's
//! displacement is continuous. Ported from
//! crates/extract/src/field/dielectric.rs (`FieldRows`). A kernel-owning
//! file: the row body `fieldRow` runs on host threads (`Field.apply`) and as
//! the device kernel `extract_field_rows`, so the two agree bit for bit.
//!
//! `FastCap`'s formulation for several dielectrics (Nabors & White,
//! "Multipole-accelerated capacitance extraction algorithms for 3-D
//! structures with multiple dielectrics", *IEEE Trans. Circuits Syst. I*
//! 39(11), 1992): every surface carries its total charge (free and
//! polarisation) in vacuum, still over the grounded substrate by images. An
//! interface panel's row holds the continuity of the normal displacement,
//! `ε_a E⁻ = ε_b E⁺` with `ε_a` below and `ε_b` above, which with the
//! panel's own sheet field `±σ/2ε₀` is `σ = 2ε₀ λ E_z`,
//! `λ = (ε_a − ε_b)/(ε_a + ε_b)`, `E_z` the field at the panel's centroid
//! from every other charge and every image.
//!
//! Contents:
//! - `pub const near_factor: f64`
//! - `pub const Field = struct`, `deinit`,
//!   `init(gpa: Allocator, threads: u16, panels: Panels.Slice, first: u32, lambda: []const f64) Allocator.Error!Field`,
//!   `apply(f: *const Field, x: []const f64, y: []f64) void`, `cols(f: *const Field) Cols`
//! - `pub const Cols = struct { n, first, cx, cy, cz, weight, scale, inverse_area, near_start, near_col, near_val }`
//! - `pub fn fieldRow(c: anytype, row: usize, x: anytype) f64`
//! - private `Rule.count`, `Rule.fill`: the near-pair rule interface `near.zig` calls

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const g = @import("gompute");
const panel = @import("panel.zig");
const Ref = panel.Ref;
const Panels = panel.Panels;
const integrals = @import("integrals.zig");
const near_mod = @import("near.zig");
const NearPairs = near_mod.NearPairs;
const row_threads = @import("rows.zig");
const matvec = @import("matvec.zig");
const P = g.GlobalPtr;

/// A pair is near, and integrated exactly, when its centroids are closer
/// than this many times the sum of the two panels' half-diagonals. Twice the
/// potential kernel's: a field falls one power of distance faster than a
/// potential, and its centroid approximation errs more at one distance.
pub const near_factor: f64 = 6.0;

/// The rows of the interface panels: for row `r`, panel `first + r`,
/// `y = (√A/ε₀) (x_r/A − (λ / 2π) Σ_p x_p h_p)`, `h_p` the vertical field at
/// its centroid per unit charge on panel `p`, image included. The scale
/// makes the rows volts, as the conductors' potential rows are. Owns its
/// columns.
pub const Field = struct {
    /// The first interface panel; the rows are `first..` of the system.
    first: u32,
    /// Every panel's centroid, metres.
    cx: []f64,
    cy: []f64,
    cz: []f64,
    /// `λ / 2π` per row.
    weight: []f64,
    /// `√A / ε₀` per row.
    scale: []f64,
    /// `1 / A` per row.
    inverse_area: []f64,
    /// Near pairs by row, each the exact entry less the far kernel's (all of
    /// the exact entry on the diagonal, where the far kernel is not summed).
    near: NearPairs,
    threads: u16,

    /// The rows of `panels[first..]`, the interface panels, whose `λ` is
    /// `lambda` in order. O(I · P) distance tests for I interface panels
    /// among P, and a closed form per near pair.
    pub fn init(gpa: Allocator, threads: u16, panels: Panels.Slice, first: u32, lambda: []const f64) Allocator.Error!Field {
        const n = panels.len;
        assert(first + lambda.len == n and n < std.math.maxInt(u32));
        var f: Field = .{ .first = first, .cx = &.{}, .cy = &.{}, .cz = &.{}, .weight = &.{}, .scale = &.{}, .inverse_area = &.{}, .near = .empty, .threads = threads };
        errdefer f.deinit(gpa);
        f.cx = try gpa.dupe(f64, panels.items(.cx));
        f.cy = try gpa.dupe(f64, panels.items(.cy));
        f.cz = try gpa.dupe(f64, panels.items(.cz));
        f.weight = try gpa.alloc(f64, lambda.len);
        f.scale = try gpa.alloc(f64, lambda.len);
        f.inverse_area = try gpa.alloc(f64, lambda.len);
        for (lambda, panels.items(.area)[first..], f.weight, f.scale, f.inverse_area) |l, area, *w, *s, *inv| {
            w.* = l / (2.0 * std.math.pi);
            s.* = @sqrt(area) / matvec.vacuum_permittivity;
            inv.* = 1.0 / area;
        }
        try f.near.buildInto(gpa, threads, @intCast(lambda.len), @intCast(n), Rule{ .panels = panels, .first = first });
        return f;
    }

    pub fn deinit(f: *Field, gpa: Allocator) void {
        gpa.free(f.cx);
        gpa.free(f.cy);
        gpa.free(f.cz);
        gpa.free(f.weight);
        gpa.free(f.scale);
        gpa.free(f.inverse_area);
        f.near.deinit(gpa);
    }

    /// The columns the row body reads.
    pub fn cols(f: *const Field) Cols {
        return .{
            .n = f.cx.len,
            .first = f.first,
            .cx = f.cx.ptr,
            .cy = f.cy.ptr,
            .cz = f.cz.ptr,
            .weight = f.weight.ptr,
            .scale = f.scale.ptr,
            .inverse_area = f.inverse_area.ptr,
            .near_start = f.near.start.items.ptr,
            .near_col = f.near.column.items.ptr,
            .near_val = f.near.value.items.ptr,
        };
    }

    /// Overwrites `y[first..]` with the interface rows of `x`, on the host
    /// threads. Asserts `x` and `y` as long as the panels.
    pub fn apply(f: *const Field, x: []const f64, y: []f64) void {
        const n = f.cx.len;
        assert(x.len >= n and y.len >= n);
        const rows = f.near.rows();
        const Body = struct {
            c: Cols,
            x: [*]const f64,
            y: [*]f64,
            fn run(b: @This(), lo: u32, hi: u32) void {
                for (lo..hi) |r| b.y[b.c.first + r] = fieldRow(b.c, r, b.x);
            }
        };
        row_threads.forBlocks(f.threads, rows, @as(u64, rows) * n, Body{ .c = f.cols(), .x = x.ptr, .y = y.ptr }, Body.run);
    }
};

/// What `fieldRow` reads: host many-pointers here, the same fields as device
/// pointers in the kernel.
pub const Cols = struct {
    n: usize,
    first: usize,
    cx: [*]const f64,
    cy: [*]const f64,
    cz: [*]const f64,
    weight: [*]const f64,
    scale: [*]const f64,
    inverse_area: [*]const f64,
    near_start: [*]const u32,
    near_col: [*]const u32,
    near_val: [*]const f64,
};

/// The field operator's near pairs: column `p` of row `r` is near when it is
/// the diagonal or within `near_factor`; its value is the exact entry less
/// the far kernel's.
const Rule = struct {
    panels: Panels.Slice,
    first: u32,

    pub fn count(rule: Rule, r: u32) u32 {
        const row = rule.first + r;
        const a = rule.ref(row);
        var n: u32 = 0;
        for (0..rule.panels.len) |p| n += @intFromBool(p == row or near_mod.near(a, rule.ref(p), near_factor));
        return n;
    }

    pub fn fill(rule: Rule, r: u32, column: []u32, value: []f64) void {
        const row = rule.first + r;
        const a = rule.ref(row);
        var slot: usize = 0;
        for (0..rule.panels.len) |p| {
            const b = rule.ref(p);
            if (p != row and !near_mod.near(a, b, near_factor)) continue;
            column[slot] = @intCast(p);
            value[slot] = if (p == row) integrals.fieldExact(a, b, true) else integrals.fieldExact(a, b, false) - far(a.centre, b.centre);
            slot += 1;
        }
        assert(slot == column.len);
    }

    fn ref(rule: Rule, j: usize) Ref {
        return .of(rule.panels.get(j));
    }
};

/// Interface row `r` (panel `first + r`) of the system: a strict ascending
/// fold of the far kernel over every other panel, `field += x_p · far`, then
/// its near corrections in column order, then the row's scale. The output
/// bits depend on that order. `c` is a `Cols` or the kernel's device
/// columns.
pub inline fn fieldRow(c: anytype, r: usize, x: anytype) f64 {
    const row = c.first + r;
    const tx = c.cx[row];
    const ty = c.cy[row];
    const tz = c.cz[row];
    var field: f64 = 0.0;
    var p: usize = 0;
    while (p < c.n) : (p += 1) {
        if (p == row) continue;
        const dx = tx - c.cx[p];
        const dy = ty - c.cy[p];
        const dz = tz - c.cz[p];
        const image = tz + c.cz[p];
        const plane = dx * dx + dy * dy;
        const r2 = plane + dz * dz;
        const r2_image = plane + image * image;
        field += x[p] * (dz / (r2 * @sqrt(r2)) - image / (r2_image * @sqrt(r2_image)));
    }
    field = near_mod.foldRow(c.near_start, c.near_col, c.near_val, r, x, field);
    return c.scale[r] * (x[row] * c.inverse_area[r] - c.weight[r] * field);
}

// ---- private ----

/// The far kernel: a unit point charge at `source` and its image, as
/// `fieldRow` forms it.
fn far(target: [3]f64, source: [3]f64) f64 {
    const dx = target[0] - source[0];
    const dy = target[1] - source[1];
    const dz = target[2] - source[2];
    const image = target[2] + source[2];
    const plane = dx * dx + dy * dy;
    const r2 = plane + dz * dz;
    const r2_image = plane + image * image;
    return dz / (r2 * @sqrt(r2)) - image / (r2_image * @sqrt(r2_image));
}

fn fieldKernel(n: u64, first: u64, rows: u64, cx: P(f64), cy: P(f64), cz: P(f64), weight: P(f64), scale: P(f64), inverse_area: P(f64), near_start: P(u32), near_col: P(u32), near_val: P(f64), x: P(f64), y: P(f64)) callconv(g.kernel_callconv) void {
    const r = g.globalIdX(matvec.gpu_block);
    if (r >= rows) return;
    const c = .{ .n = n, .first = first, .cx = cx, .cy = cy, .cz = cz, .weight = weight, .scale = scale, .inverse_area = inverse_area, .near_start = near_start, .near_col = near_col, .near_val = near_val };
    y[first + r] = fieldRow(c, r, x);
}

comptime {
    if (g.is_device) g.exportRaw("extract_field_rows", &fieldKernel);
}
