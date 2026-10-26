//! Custom rules: a rule kind GPurify does not ship, written as a function,
//! held to the guarantees every rule keeps (deck-library plan §4.4; catalog
//! FLOW-006). In: the custom rules, the layout, the run's nets and names.
//! Out: one `RuleRun` per rule and its findings, canonical. The function
//! reads the layout through `CustomCtx` and reports into `Findings`; the
//! runner owns the accounting: a rule whose inputs are all empty is skipped
//! (`empty_layer`) and never called; `examined` is the shapes and edges on
//! its inputs; findings are sorted canonically, repeats dropped; a finding
//! on an undeclared layer, naming an undeclared shape, outside the layout's
//! extent, not finite, or with a limit of another kind refuses the rule,
//! its findings discarded. A Zig panic aborts the run (no unwinding), so a
//! panicking check never passes. Ported from crates/check/src/deck/custom.rs.
//!
//! Contents:
//! - `pub const CustomCheck`, `pub const CustomRule = struct`, `pub const Finding = struct`
//! - `pub const Findings = struct`, `deinit`, `push(f: *Findings, row: Finding) Allocator.Error!void`,
//!   `flag(f: *Findings, ctx: *const CustomCtx, shape: PolyId, measured: Measurement) Allocator.Error!void`, `len(f: *const Findings) usize`
//! - `pub const CustomCtx = struct`, `input(ctx, k: usize) LayerId`, `shapes(ctx, layer: LayerId) Rows`,
//!   `area(ctx, shape: PolyId) i128`, `validated(ctx, k: usize) ?*const ValidatedLayer`,
//!   `pairsWithin(ctx, gpa: Allocator, a: usize, b: usize, distance: Dbu, out: *std.ArrayList(Pair)) Allocator.Error!void`
//! - `pub fn runCustom(gpa: Allocator, rules: []const CustomRule, store: *const GeometryStore, nets: ?*const NetTable, grid: Grid, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Point = geom.Point;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const Pair = geom.index.Pair;
const Rows = geom.store.Rows;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Severity = report.Severity;
const Violation = report.Violation;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const rects = @import("../rects.zig");
const NetTable = @import("../topology/net.zig").NetTable;

/// A custom rule's check: reads the layout through the context, reports
/// into the findings. A plain function pointer: one indirect call per rule,
/// and the loop over shapes stays in the function.
pub const CustomCheck = *const fn (ctx: *const CustomCtx, out: *Findings) Allocator.Error!void;

/// A rule kind written in code: what `DeckBuilder.custom` adds.
pub const CustomRule = struct {
    /// What its findings and its `RuleRun` row are reported under.
    id: StrId,
    /// The layers it reads, the only ones its findings may name. Owned by
    /// the deck holding the rule.
    inputs: []const LayerId,
    severity: Severity,
    check: CustomCheck,
};

/// One finding of a custom rule, as the report will carry it.
pub const Finding = struct {
    /// One of the rule's inputs.
    layer: LayerId,
    /// Where to look, inside the layout's extent.
    at: Point,
    /// Rows on the inputs; `report.no_shape` for none.
    shape_a: PolyId,
    shape_b: PolyId = report.no_shape,
    /// Finite, and of the same kind as `limit`.
    measured: Measurement,
    limit: Measurement,
};

/// What a custom rule found, in any order and with repeats.
pub const Findings = struct {
    gpa: Allocator,
    rows: std.ArrayList(Finding) = .empty,

    pub fn deinit(f: *Findings) void {
        f.rows.deinit(f.gpa);
    }

    pub fn push(f: *Findings, row: Finding) Allocator.Error!void {
        return f.rows.append(f.gpa, row);
    }

    /// Flags `shape` at its first vertex, on its layer, with `measured`
    /// against a limit of the same kind and zero: a shape that should not
    /// be there.
    pub fn flag(f: *Findings, ctx: *const CustomCtx, shape: PolyId, measured: Measurement) Allocator.Error!void {
        const ring = ctx.store.polyVerts(shape);
        return f.push(.{ .layer = ctx.store.polyLayer(shape), .at = .{ .x = ring.xs[0], .y = ring.ys[0] }, .shape_a = shape, .measured = measured, .limit = .{ .kind = measured.kind, .raw = 0 } });
    }

    /// Repeats included.
    pub fn len(f: *const Findings) usize {
        return f.rows.items.len;
    }
};

/// What a custom rule may read: the layout, read-only, with its declared
/// inputs validated before it is called. Fields are read directly.
pub const CustomCtx = struct {
    store: *const GeometryStore,
    inputs: []const LayerId,
    /// Per input, the layer validated (rectilinear), null when it does not
    /// validate.
    layers: []const ?ValidatedLayer,
    /// The extracted nets, when the run has them.
    nets: ?*const NetTable,
    grid: Grid,
    strings: *const StrTable,

    /// The rule's `k`th input layer; asserts `k` is one.
    pub fn input(ctx: *const CustomCtx, k: usize) LayerId {
        return ctx.inputs[k];
    }

    /// The rows on `layer`, in store order; none for an undeclared layer.
    pub fn shapes(ctx: *const CustomCtx, layer: LayerId) Rows {
        if (std.mem.indexOfScalar(LayerId, ctx.inputs, layer) == null) return .{ .start = 0, .end = 0 };
        return ctx.store.polysOnLayer(layer);
    }

    /// A row's area in square grid units, a hole (clockwise) negative.
    pub fn area(ctx: *const CustomCtx, shape: PolyId) i128 {
        const ring = ctx.store.polyVerts(shape);
        return @divTrunc(geom.ops.area2(ring.xs, ring.ys), 2);
    }

    /// The `k`th input validated as the DRC rules read a layer; null when
    /// it does not validate.
    pub fn validated(ctx: *const CustomCtx, k: usize) ?*const ValidatedLayer {
        if (k >= ctx.layers.len) return null;
        return if (ctx.layers[k]) |*l| l else null;
    }

    /// Every pair of rows, one on input `a` and one on input `b` (each pair
    /// once when they are the same input), whose boundaries come within
    /// `distance`, exactly; ascending, into `out`.
    pub fn pairsWithin(ctx: *const CustomCtx, gpa: Allocator, a: usize, b: usize, distance: Dbu, out: *std.ArrayList(Pair)) Allocator.Error!void {
        const la = ctx.inputs[a];
        const lb = ctx.inputs[b];
        var index: geom.index.SpatialIndex = .empty;
        defer index.deinit(gpa);
        try index.build(gpa, ctx.store, lb);
        if (la == lb) {
            try geom.index.candidatePairsInto(gpa, ctx.store, &index, distance, out);
        } else {
            try geom.index.crossLayerPairsInto(gpa, ctx.store, la, &index, distance, out);
        }
        const limit = geom.mulWide(distance, distance);
        var kept: usize = 0;
        for (out.items) |p| {
            if (rects.polyDist2(ctx.store, p.a, p.b) > limit) continue;
            out.items[kept] = p;
            kept += 1;
        }
        out.shrinkRetainingCapacity(kept);
    }
};

/// Runs every custom rule over one layout, appending exactly one `RuleRun`
/// per rule to `runs` and its findings, canonical, to `out`. `nets` is what
/// `CustomCtx.nets` answers.
pub fn runCustom(gpa: Allocator, rules: []const CustomRule, store: *const GeometryStore, nets: ?*const NetTable, grid: Grid, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    var extent = Bbox.empty;
    for (0..store.layerCount()) |l| for (store.layerBboxes(@fromBackingInt(@as(u16, @intCast(l))))) |b| {
        extent = extent.merge(b);
    };
    for (rules) |rule| {
        const before = out.len();
        const declared = for (rule.inputs) |l| {
            if (@backingInt(l) >= store.layerCount()) break false;
        } else true;
        if (!declared) {
            try report.recordRun(gpa, runs, out, before, rule.id, .refused, 0);
            continue;
        }
        var examined: u64 = 0;
        for (rule.inputs) |l| examined += store.polysOnLayer(l).len() + store.edgesOnLayer(l).len;
        if (examined == 0) {
            try report.recordRun(gpa, runs, out, before, rule.id, .{ .skipped = .empty_layer }, 0);
            continue;
        }
        const layers = try gpa.alloc(?ValidatedLayer, rule.inputs.len);
        defer gpa.free(layers);
        @memset(layers, null);
        defer for (layers) |*l| if (l.*) |*v| v.deinit(gpa);
        for (layers, rule.inputs) |*slot, l| {
            var v: ValidatedLayer = .empty;
            if (try geom.view.validateLayer(gpa, store, l, .rectilinear, &v) == null) slot.* = v else v.deinit(gpa);
        }
        const ctx: CustomCtx = .{ .store = store, .inputs = rule.inputs, .layers = layers, .nets = nets, .grid = grid, .strings = strings };
        var findings: Findings = .{ .gpa = gpa };
        defer findings.deinit();
        try rule.check(&ctx, &findings);
        const sound = for (findings.rows.items) |f| {
            if (!sane(f, rule, store, extent)) break false;
        } else true;
        if (!sound) {
            try report.recordRun(gpa, runs, out, before, rule.id, .refused, examined);
            continue;
        }
        var table: Violations = .{};
        defer table.deinit(gpa);
        for (findings.rows.items) |f| try table.push(gpa, .{ .rule = rule.id, .layer = f.layer, .severity = rule.severity, .at = f.at, .measured = f.measured, .limit = f.limit, .shape_a = f.shape_a, .shape_b = f.shape_b });
        try table.sortCanonical(gpa);
        var last: ?Violation = null;
        for (0..table.len()) |row| {
            const v = table.get(@intCast(row));
            if (last) |l| if (same(l, v)) continue;
            try out.push(gpa, v);
            last = v;
        }
        try report.recordRun(gpa, runs, out, before, rule.id, .ran, examined);
    }
}

// ---- private ----

/// Whether a finding is one the report can carry for this rule.
fn sane(f: Finding, rule: CustomRule, store: *const GeometryStore, extent: Bbox) bool {
    const on_input = std.mem.indexOfScalar(LayerId, rule.inputs, f.layer) != null;
    const inside = f.at.x >= extent.xlo and f.at.x <= extent.xhi and f.at.y >= extent.ylo and f.at.y <= extent.yhi;
    return on_input and declaredShape(f.shape_a, rule, store) and declaredShape(f.shape_b, rule, store) and inside and
        f.measured.isFinite() and f.limit.isFinite() and f.measured.kind == f.limit.kind;
}

fn declaredShape(shape: PolyId, rule: CustomRule, store: *const GeometryStore) bool {
    if (shape == report.no_shape) return true;
    if (@backingInt(shape) >= store.polyCount()) return false;
    return std.mem.indexOfScalar(LayerId, rule.inputs, store.polyLayer(shape)) != null;
}

/// Row equality, as Rust's derived `PartialEq` on `Violation`.
fn same(a: Violation, b: Violation) bool {
    return a.rule == b.rule and a.layer == b.layer and a.severity == b.severity and a.at.eql(b.at) and
        a.measured.eql(b.measured) and a.limit.eql(b.limit) and a.shape_a == b.shape_a and a.shape_b == b.shape_b;
}
