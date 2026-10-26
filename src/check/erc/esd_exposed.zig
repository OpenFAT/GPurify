//! What a pad exposes: junctions of a pad net close to another net's
//! (`esd_parasitic`, a parasitic bipolar; ESDA TR18.0-01 §5.6.1), and the
//! transistors a pad reaches unprotected (`esd_exposed`: exposed gates
//! without clamps to both rails, unrated output drivers, too little series
//! resistance; Khazhinsky 2012, White Paper 2 §2.3, TR18-01 Rule 6.1.11).
//! In: the design, the intent, the table. Out: violations and one `RuleRun`
//! per row. Ported from crates/check/src/erc/rules/esd.rs
//! (`check_esd_parasitic`, `check_esd_exposed`).
//!
//! Contents:
//! - `pub fn esdParasitic(r: Record, design: Design, t: *const EsdParasiticTable) Allocator.Error!void`
//! - `pub fn esdExposed(r: Record, design: Design, intent: *const IntentMap, t: *const EsdExposedTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const NetId = @import("../topology/net.zig").NetId;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const terminalNet = head_.terminalNet;
const IntentMap = @import("facts.zig").IntentMap;
const clamp_reach = @import("clamp_reach.zig");
const rings = @import("rings.zig");
const seriesResistanceInto = @import("esd_cross.zig").seriesResistanceInto;
const tables = @import("esd_tables.zig");
const EsdParasiticTable = tables.EsdParasiticTable;
const EsdExposedTable = tables.EsdExposedTable;

/// Every pair of `diffusion` polygons, one on a pad net and one on any
/// other net, closer than `min_spacing` (exact Euclidean): the distance
/// rounded down against it, at the pad junction's first vertex (the lower
/// one when both are on pad nets). `examined` counts junctions on pad nets.
/// Needs no intent.
pub fn esdParasitic(r: Record, design: Design, t: *const EsdParasiticTable) Allocator.Error!void {
    const store = design.store;
    const nets = design.nets;
    var pads: std.ArrayList(NetId) = .empty;
    defer pads.deinit(r.gpa);
    var junctions: std.ArrayList(PolyId) = .empty;
    defer junctions.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const layer = t.diffusion.items[row];
        const min = t.min_spacing.items[row];
        const min2 = geom.mulWide(min, min);
        try rings.padNetsInto(r.gpa, design, t.pad.items[row], &pads);
        junctions.clearRetainingCapacity();
        const rows = store.polysOnLayer(layer);
        for (rows.start..rows.end) |p| {
            const poly: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            const ring = store.polyVerts(poly);
            if (geom.ops.windingOf(ring.xs, ring.ys) != .cw) try junctions.append(r.gpa, poly);
        }
        var examined: u64 = 0;
        // ponytail: every pad junction against every junction; a spatial
        // index if pads drive many.
        for (junctions.items, 0..) |a, i| {
            if (!onPad(design, pads.items, a)) continue;
            examined += 1;
            const ab = store.polyBbox(a);
            for (junctions.items, 0..) |b, j| {
                // A pair of pad junctions is reported once, from the lower.
                if (j == i or (j < i and onPad(design, pads.items, b)) or nets.netOf(a) == nets.netOf(b)) continue;
                if (!store.polyBbox(b).within(ab, min)) continue;
                const d2 = rings.regionDist2(store, a, b);
                if (d2 < min2) try r.out.push(r.gpa, .{ .rule = rule, .layer = layer, .severity = severity, .at = store.firstVertex(a), .measured = .length(geom.ops.isqrt(d2)), .limit = .length(min), .shape_a = a, .shape_b = b });
            }
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every transistor whose gate is exposed (on a pad net, or joined to one
/// only through `resistors` devices; never a supply) and whose gate net's
/// clamps reach fewer than both rails (the count against 2), or, with
/// `min_series`, too little series resistance from the pads; and every
/// output driver (a channel end on a pad net) of neither a `rated` nor a
/// `clamps` model (0 against 1). `examined` counts exposed gates plus
/// drivers. Refused when a series resistor states no value. The caller
/// checks the intent.
pub fn esdExposed(r: Record, design: Design, intent: *const IntentMap, t: *const EsdExposedTable) Allocator.Error!void {
    const gpa = r.gpa;
    const nets = design.nets;
    const devices = design.devices;
    var walk_state: clamp_reach.Walk = .{};
    defer walk_state.deinit(gpa);
    var pads: std.ArrayList(NetId) = .empty;
    defer pads.deinit(gpa);
    var exposed: std.ArrayList(bool) = .empty;
    defer exposed.deinit(gpa);
    var walk: std.ArrayList(NetId) = .empty;
    defer walk.deinit(gpa);
    var series: std.ArrayList(f64) = .empty;
    defer series.deinit(gpa);
    var rails: std.ArrayList(?u32) = .empty;
    defer rails.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const clamps = t.clamp.items[t.clamp_start.items[row]..t.clamp_start.items[row + 1]];
        const resistors = t.resistor.items[t.resistor_start.items[row]..t.resistor_start.items[row + 1]];
        const rated = t.rated.items[t.rated_start.items[row]..t.rated_start.items[row + 1]];
        try rings.padNetsInto(gpa, design, t.pad.items[row], &pads);
        // Exposed nets: the pads, then through series resistors, never a rail.
        exposed.clearRetainingCapacity();
        try exposed.appendNTimes(gpa, false, nets.netCount());
        walk.clearRetainingCapacity();
        for (pads.items) |n| if (intent.supply(n) == null) {
            exposed.items[@backingInt(n)] = true;
            try walk.append(gpa, n);
        };
        while (walk.pop()) |net| for (devices.devicesOn(net)) |d| {
            if (!has(resistors, devices.model.items[@backingInt(d)])) continue;
            for (devices.terminalsOf(d).nets) |next| {
                if (next == .none or exposed.items[@backingInt(next)] or intent.supply(next) != null) continue;
                exposed.items[@backingInt(next)] = true;
                try walk.append(gpa, next);
            }
        };
        const min_series = t.min_series.items[row];
        if (min_series != null and !try seriesResistanceInto(gpa, design, pads.items, exposed.items, resistors, &series)) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        rails.clearRetainingCapacity();
        try rails.appendNTimes(gpa, null, nets.netCount());
        var examined: u64 = 0;
        for (0..devices.len()) |index| {
            if (devices.kind.items[index] != .mos) continue;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(index))));
            const gate = terminalNet(term.nets, term.roles, .gate);
            if (gate != .none and exposed.items[@backingInt(gate)]) {
                examined += 1;
                const slot = &rails.items[@backingInt(gate)];
                if (slot.* == null) slot.* = try clamp_reach.clampRails(gpa, design, intent, clamps, gate, &walk_state);
                const reached = slot.*.?;
                if (reached < 2) try r.deviceViolation(design, @intCast(index), rule, severity, .count(reached), .count(2));
                if (min_series) |min| {
                    const measured = Measurement.resistance(.{ .raw = series.items[@backingInt(gate)] });
                    const limit = Measurement.resistance(min);
                    if (measured.violates(limit, .minimum)) try r.deviceViolation(design, @intCast(index), rule, severity, measured, limit);
                }
            }
            const source = terminalNet(term.nets, term.roles, .source);
            const drain = terminalNet(term.nets, term.roles, .drain);
            if (inSorted(pads.items, source) or inSorted(pads.items, drain)) {
                examined += 1;
                const model = devices.model.items[index];
                if (!(has(rated, model) or has(clamps, model))) try r.deviceViolation(design, @intCast(index), rule, severity, .count(0), .count(1));
            }
        }
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

/// `poly`'s net holds a pad (never on an unextracted design).
fn onPad(design: Design, pads: []const NetId, poly: PolyId) bool {
    return pads.len > 0 and inSorted(pads, design.nets.netOf(poly));
}

fn inSorted(items: []const NetId, net: NetId) bool {
    return std.sort.binarySearch(NetId, items, net, struct {
        fn order(a: NetId, b: NetId) std.math.Order {
            return std.math.order(@backingInt(a), @backingInt(b));
        }
    }.order) != null;
}

fn has(models: []const StrId, model: StrId) bool {
    return std.mem.indexOfScalar(StrId, models, model) != null;
}
