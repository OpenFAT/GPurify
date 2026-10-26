//! The ERC stage: a loaded and extracted design → its ERC findings and rule
//! records appended to `Outputs`. Ported from src/engine/run.rs (`run_erc`,
//! `antenna_pins`, `design_extent`, `sign_off_temperature`).
//!
//! Intent finds nets by label, and a net with two labels is two named nets
//! shorted: design intent on it refuses the stage. A layout with no
//! geometry has no die to divide a density by, so ERC skips. Otherwise ERC
//! refuses row by row (a supply grid that cannot be built or solved refuses
//! the rows that read it).
//!
//! Contents:
//! - `pub fn runErc(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, out: *Outputs) Allocator.Error!StageStatus`
//! - `pub fn designExtent(loaded: *const Loaded) Bbox`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ingest = @import("ingest");
const lefdef = ingest.lefdef;
const check = @import("check");
const erc = check.erc;
const report = check.report;
const MacroPinAntenna = erc.antenna_tables.MacroPinAntenna;
const PinValue = erc.antenna_tables.PinValue;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const StageStatus = run_.StageStatus;

/// One placed macro pin wanting its polygon: its conductor, its shape's
/// bbox and its values.
const Wanted = struct { layer: LayerId, bbox: [4]i64, values: []const PinValue };

const Key = struct {
    wanted: []const Wanted,
    key: [4]i64,
    fn below(k: Key, w: u32) bool {
        return std.mem.order(i64, &k.wanted[w].bbox, &k.key) == .lt;
    }
};

pub fn runErc(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, out: *Outputs) Allocator.Error!StageStatus {
    if (loaded.intent != null) if (extracted.ports.shortedNet()) |net| {
        var names: std.ArrayList(u8) = .empty;
        for (extracted.ports.namesOf(net), 0..) |name, i| {
            if (i != 0) try names.appendSlice(run_arena, ", ");
            try names.appendSlice(run_arena, loaded.strings.resolve(name));
        }
        return .{ .refused = try std.fmt.allocPrint(run_arena, "one net carries the labels {s}, a short between named nets, so design intent cannot say which of them it is", .{names.items}) };
    };
    const die = designExtent(loaded);
    if (die.isEmpty()) return .{ .skipped = "the layout holds no geometry, so no die boundary bounds a density" };

    var why: []const u8 = "";
    const pins = antennaPins(scratch, run_arena, loaded, &why) catch |err| switch (err) {
        error.UndefinedLayer => return .{ .refused = why },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const deck = &loaded.deck.deck;
    const inputs: erc.Inputs = .{
        .design = .{ .store = &loaded.store, .nets = &extracted.nets, .devices = &extracted.devices },
        .ports = &extracted.ports,
        .intent = if (loaded.intent) |*i| i else null,
        .process = .{ .grid = loaded.grid, .stack = &deck.stack, .connectivity = &deck.connectivity },
        .die = die,
        // The intent's junction temperature, else the deck's statement.
        .temperature = if (loaded.intent) |i| i.temperature orelse deck.temperature else deck.temperature,
        .antenna_pins = pins,
        .strings = &loaded.strings,
    };
    var violations: report.Violations = .{};
    var runs: std.ArrayList(report.RuleRun) = .empty;
    try erc.check(scratch, &loaded.deck.erc, inputs, &violations, &runs);
    try run_.appendStage(run_arena, out, &violations, runs.items);
    return .ran;
}

/// The die every density divides by: the deck's `boundary` layer if it is
/// drawn, else the union of every drawn (not derived) polygon's bbox;
/// `Bbox.empty` for an empty store.
pub fn designExtent(loaded: *const Loaded) Bbox {
    const store = &loaded.store;
    if (loaded.deck.deck.boundary) |layer| if (@backingInt(layer) < store.layerCount()) {
        const outline = unionOf(store.layerBboxes(layer));
        if (!outline.isEmpty()) return outline;
    };
    var die = Bbox.empty;
    for (0..store.layerCount()) |l| {
        const layer: LayerId = @fromBackingInt(@as(u16, @intCast(l)));
        if (!loaded.deck.deck.layers.isDerived(layer)) die = die.merge(unionOf(store.layerBboxes(layer)));
    }
    return die;
}

// ---- private ----

fn unionOf(boxes: []const Bbox) Bbox {
    var out = Bbox.empty;
    for (boxes) |b| out = out.merge(b);
    return out;
}

/// Every placed macro pin's LEF antenna data on the deck's layers
/// (ERC-A14): per component pin on a DEF net whose `PIN` states any, the
/// store polygon its first shape on a deck conductor was drawn as (the one
/// on that layer with the shape's bbox), areas in square database units.
/// Empty for a GDS layout. `UndefinedLayer` (with `why` in `run_arena`): a
/// statement on a layer the deck does not define, which would be dropped
/// unseen.
fn antennaPins(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, why: *[]const u8) error{ UndefinedLayer, OutOfMemory }![]const MacroPinAntenna {
    const design = loaded.design orelse return &.{};
    var diag: lefdef.Diagnostic = .{};
    const flat = lefdef.flatten(scratch, &design.def, &design.lef, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `load` drew this design through the same flatten.
        error.Invalid => unreachable,
    };
    const dbu: f64 = @floatFromInt(loaded.grid.dbu_per_um);
    const deck = &loaded.deck.deck;
    var taken: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    var wanted: std.ArrayList(Wanted) = .empty;
    for (flat) |f| {
        const cp = switch (f.origin) {
            .macro_pin => |cp| cp,
            .route, .pin, .obstruction, .fill => continue,
        };
        if (f.net == null or taken.contains(cp)) continue;
        const model = design.def.components[cp[0]].model;
        const cell = for (design.lef.macros.items) |*m| (if (std.mem.eql(u8, m.name, model)) break m) else continue;
        const pin = cell.pins[cp[1]];
        const layer = deck.layers.id(&loaded.strings, f.shape.layer) orelse continue;
        if (std.mem.findScalar(LayerId, deck.connectivity.conductors, layer) == null) continue;
        if (pin.antenna.len == 0) continue;
        const values = try run_arena.alloc(PinValue, pin.antenna.len);
        for (pin.antenna, values) |s, *v| {
            const on: ?LayerId = if (s.layer) |name| deck.layers.id(&loaded.strings, name) orelse {
                why.* = try std.fmt.allocPrint(run_arena, "LEF macro {s} pin {s} states antenna data on layer {s}, which the deck does not define", .{ model, pin.name, name });
                return error.UndefinedLayer;
            } else null;
            const ratio = switch (s.kind) {
                .max_area_car, .max_side_area_car, .max_cut_car => true,
                .partial_metal, .partial_metal_side, .partial_cut, .diff, .gate => false,
            };
            v.* = .{ .kind = s.kind, .layer = on, .value = if (ratio) s.value else s.value * (dbu * dbu) };
        }
        try taken.put(scratch, cp, {});
        try wanted.append(scratch, .{ .layer = layer, .bbox = f.shape.bbox(), .values = values });
    }
    // Each pin's polygon: sweep each layer's polygons over the pins sorted
    // by (layer, bbox).
    const poly = try scratch.alloc(?PolyId, wanted.items.len);
    @memset(poly, null);
    const sorted = try scratch.alloc(u32, wanted.items.len);
    for (sorted, 0..) |*s, i| s.* = @intCast(i);
    std.mem.sort(u32, sorted, wanted.items, byLayerBbox);
    var start: usize = 0;
    while (start < sorted.len) {
        const layer = wanted.items[sorted[start]].layer;
        var end = start;
        while (end < sorted.len and wanted.items[sorted[end]].layer == layer) end += 1;
        const run = sorted[start..end];
        const rows = loaded.store.polysOnLayer(layer);
        for (rows.start..rows.end) |r| {
            const row: PolyId = @fromBackingInt(@as(u32, @intCast(r)));
            const b = loaded.store.polyBbox(row);
            const key: [4]i64 = .{ b.xlo, b.ylo, b.xhi, b.yhi };
            var k = std.sort.partitionPoint(u32, run, Key{ .wanted = wanted.items, .key = key }, Key.below);
            while (k < run.len and std.mem.eql(i64, &wanted.items[run[k]].bbox, &key)) : (k += 1) {
                if (poly[run[k]] == null) poly[run[k]] = row;
            }
        }
        start = end;
    }
    var out: std.ArrayList(MacroPinAntenna) = .empty;
    for (wanted.items, poly) |w, p| if (p) |row| try out.append(run_arena, .{ .poly = row, .values = w.values });
    return out.items;
}

fn byLayerBbox(wanted: []const Wanted, a: u32, b: u32) bool {
    const x = wanted[a];
    const y = wanted[b];
    if (x.layer != y.layer) return @backingInt(x.layer) < @backingInt(y.layer);
    return std.mem.order(i64, &x.bbox, &y.bbox) == .lt;
}
