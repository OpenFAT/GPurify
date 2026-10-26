//! Two layouts compared layer by layer, `gpurify xor <layout> <other>
//! --deck <deck>` (catalog DRC-068). Ported from src/engine/xor.rs.
//!
//! For every drawn layer the deck declares, the region where exactly one
//! layout has material, `A xor B` of the merged shapes, as KLayout's `xor`
//! computes it (its DRC `^`, `Region#^`). Each connected piece is one
//! violation measured by its area (holes excluded), at its outer ring's
//! first vertex, so a layer's total measured area is the area the two
//! disagree on; on a cut layer whose cuts in B lie within A's, the cut area
//! A lost, which the sky130 IR-drop rules (`ct.irdrop`, `via.irdrop`)
//! compare between two GDS files. One `RuleRun` per drawn layer, `xor.<layer>`,
//! refused when either side does not validate rectilinear; reported as the
//! DRC stage. Derived layers and labels are not compared, nor is a cut-area
//! change held to a tolerance (the rules leave its unit unsettled).
//!
//! Contents:
//! - `pub const Xor = struct { loaded, outputs, summary }`, `pub const Error`, `pub const Diagnostic`
//! - `pub fn run(gpa: Allocator, run_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, other: []const u8, decks: []const NamedDeck, diag: *Diagnostic) Error!Xor`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const GeometryStore = geom.GeometryStore;
const LayerId = geom.LayerId;
const ValidatedLayer = geom.ValidatedLayer;
const ingest = @import("ingest");
const report = @import("check").report;
const load_ = @import("load.zig");
const Inputs = load_.Inputs;
const Loaded = load_.Loaded;
const NamedDeck = load_.NamedDeck;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const Summary = run_.Summary;

/// The first layout as loaded, and the comparison as a DRC stage.
pub const Xor = struct { loaded: Loaded, outputs: Outputs, summary: Summary };

/// Either layout or the deck could not be read (`load.Error`, the second
/// layout held to the deck's layers as the first is), or the two layouts'
/// `UNITS` differ (`GridMismatch`, `Diagnostic.grids`).
pub const Error = load_.Error || error{GridMismatch};

pub const Diagnostic = struct {
    load: load_.Diagnostic = .{},
    /// Database units per µm of the first and the second layout.
    grids: [2]i64 = .{ 0, 0 },
};

/// Loads `inputs` and the layout at `other` (under `dir`) against one
/// deck, and compares them layer by layer.
pub fn run(gpa: Allocator, run_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, other: []const u8, decks: []const NamedDeck, diag: *Diagnostic) Error!Xor {
    var out: Xor = .{ .loaded = try load_.load(gpa, run_arena, io, dir, inputs, decks, &diag.load), .outputs = .{}, .summary = undefined };
    const loaded = &out.loaded;
    diag.load = .{ .stage = .layout, .path = other };
    const bytes = try ingest.gds.readGdsBytes(gpa, io, dir, other);
    defer gpa.free(bytes);
    const lib = try ingest.gds.Library.parse(run_arena, bytes, &loaded.strings, &diag.load.gds);
    const grid = try lib.grid(&diag.load.gds);
    if (grid.dbu_per_um != loaded.grid.dbu_per_um) {
        diag.grids = .{ loaded.grid.dbu_per_um, grid.dbu_per_um };
        return error.GridMismatch;
    }
    var store: GeometryStore = .empty;
    var provenance: ingest.Provenance = .{};
    var tags: std.ArrayList(u64) = .empty;
    defer tags.deinit(gpa);
    try ingest.layout.flattenInto(run_arena, &lib, &loaded.deck.deck.layers, &loaded.strings, .reject, .top, &store, &provenance, &tags, &diag.load.gds);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    try compareInto(scratch.allocator(), run_arena, loaded, &store, &out.outputs);
    out.summary = try run_.summarize(run_arena, &out.outputs, .{ .ran, .not_selected, .not_selected, .not_selected });
    return out;
}

// ---- private ----

/// One row per drawn layer: `ran` with a violation per piece of A xor B,
/// or `refused` when either side does not validate. `examined` counts both
/// sides' polygons.
fn compareInto(scratch: Allocator, run_arena: Allocator, loaded: *Loaded, other: *const GeometryStore, out: *Outputs) Allocator.Error!void {
    var a: ValidatedLayer = .empty;
    var b: ValidatedLayer = .empty;
    var a_only: ValidatedLayer = .empty;
    var b_only: ValidatedLayer = .empty;
    var differ: ValidatedLayer = .empty;
    const layers = &loaded.deck.deck.layers;
    for (0..layers.len()) |index| {
        const layer: LayerId = @fromBackingInt(@as(u16, @intCast(index)));
        if (layers.isDerived(layer)) continue;
        const name = try std.fmt.allocPrint(scratch, "xor.{s}", .{loaded.strings.resolve(layers.name(layer))});
        const rule = try loaded.strings.intern(run_arena, name);
        const examined: u64 = polygons(&loaded.store, layer) + polygons(other, layer);
        const compared = try validates(scratch, &loaded.store, layer, &a) and try validates(scratch, other, layer, &b);
        const before = out.violations.len();
        if (compared) {
            try geom.boolean.subtractionInto(scratch, &a, &b, &a_only);
            try geom.boolean.subtractionInto(scratch, &b, &a, &b_only);
            try geom.boolean.unionInto(scratch, &a_only, &b_only, &differ);
            for (0..differ.len()) |piece| {
                const polygon = differ.get(@intCast(piece));
                var area2: i128 = 0;
                for (0..polygon.ringCount()) |k| {
                    const ring = polygon.ring(@intCast(k));
                    area2 += geom.ops.area2(ring.xs, ring.ys);
                }
                const outer = polygon.outer();
                try out.violations.push(run_arena, .{ .rule = rule, .layer = layer, .severity = .@"error", .at = .{ .x = outer.xs[0], .y = outer.ys[0] }, .measured = .area(@divTrunc(area2, 2)), .limit = .area(0), .shape_a = report.no_shape, .shape_b = report.no_shape });
            }
        }
        try out.runs.append(run_arena, .{ .rule = rule, .outcome = if (compared) .ran else .refused, .examined = examined, .violations = std.math.lossyCast(u32, out.violations.len() - before) });
    }
}

fn polygons(store: *const GeometryStore, layer: LayerId) u64 {
    if (@backingInt(layer) >= store.layerCount()) return 0;
    return store.polysOnLayer(layer).len();
}

fn validates(scratch: Allocator, store: *const GeometryStore, layer: LayerId, out: *ValidatedLayer) Allocator.Error!bool {
    if (@backingInt(layer) >= store.layerCount()) {
        out.clear();
        return true;
    }
    return try geom.view.validateLayer(scratch, store, layer, .rectilinear, out) == null;
}
