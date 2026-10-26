//! The latchup kinds: `guard_ring_bias` (ERC-D3/D6, GF180MCU LU.9-LU.10,
//! IO.1, IO.3: a ring on the rail its type needs), `tie_area` (ERC-D1b,
//! LU.7, IO.2, IO.4: contact over channel area per region figure),
//! `forward_diode` (ERC-D8, §14.3.3: a forward-biasable diode under its
//! marker), `conditional_tie` (ERC-D1a, LU.1-LU.4: a tap distance banded by
//! a neighbour's space to the well) and `latchup_victim` (ERC-D5, IO.1 (b),
//! IO.3 (b), ESDA TR18.0-02: a region near an injecting junction held to a
//! tighter tap distance); `guard_ring` is latchup_ring.zig. In: the store,
//! nets, devices, the intent and propagated voltages. Out: violations and
//! one run per row. Ported from crates/check/src/erc/rules/latchup.rs.
//!
//! Contents:
//! - `pub fn checkGuardRingBias(r: Record, design: Design, intent: *const IntentMap, t: *const GuardRingBiasTable) Allocator.Error!void`
//! - `pub fn checkTieArea(r: Record, design: Design, t: *const TieAreaTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkGuardRing` (latchup_ring.zig)
//! - `pub fn checkForwardDiode(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ForwardDiodeTable) Allocator.Error!void`
//! - `pub fn checkConditionalTie(r: Record, design: Design, t: *const ConditionalTieTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkLatchupVictim(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const LatchupVictimTable, scratch: *Scratch) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const NetId = @import("../topology/net.zig").NetId;
const taps = @import("../topology/taps.zig");
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const rings = @import("rings.zig");
const ring = @import("latchup_ring.zig");
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("latchup_tables.zig");
const ConditionalTieTable = tables.ConditionalTieTable;
const ForwardDiodeTable = tables.ForwardDiodeTable;
const GuardRingBiasTable = tables.GuardRingBiasTable;
const LatchupVictimTable = tables.LatchupVictimTable;
const TieAreaTable = tables.TieAreaTable;

pub const checkGuardRing = ring.checkGuardRing;

/// Every ring polygon (holes aside) on the rail its type needs: an n-type
/// ring (`power`) on the most positive declared power supply, a p-type on a
/// ground. A wrong supply measures its voltage against the one needed; no
/// supply measures 0 against 1. Skipped without usable intent.
pub fn checkGuardRingBias(r: Record, design: Design, intent: *const IntentMap, t: *const GuardRingBiasTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const store = design.store;
    const nets = design.nets;
    var highest = -std.math.inf(f64);
    for (intent.supply_role.items, 0..) |role, row| if (role == .power) {
        highest = @max(highest, intent.heldAt(row).raw);
    };
    for (t.head.rule.items, t.head.severity.items, t.ring.items, t.power.items) |rule, severity, ring_layer, power| {
        const before = r.out.len();
        var examined: u64 = 0;
        const rows = store.polysOnLayer(ring_layer);
        for (rows.start..rows.end) |p| {
            const poly: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            if (nets.holes.isHole(poly)) continue;
            examined += 1;
            const net = nets.netOf(poly);
            const supply = intent.supply(net);
            const held = if (intent.nominalVoltage(net)) |v| v.raw else 0.0;
            const Finding = struct { measured: Measurement, limit: Measurement, sense: report.LimitSense };
            const none_found: Finding = .{ .measured = .count(0), .limit = .count(1), .sense = .minimum };
            // With no power supply declared, an n-type ring has none to sit at.
            const finding: ?Finding = if (supply) |s|
                (if (power)
                    (if (std.math.isFinite(highest)) Finding{ .measured = mv(held), .limit = mv(highest), .sense = .minimum } else none_found)
                else switch (s.role) {
                    .ground => null,
                    .power => Finding{ .measured = mv(held), .limit = mv(0.0), .sense = .maximum },
                })
            else
                none_found;
            const f = finding orelse continue;
            if (f.measured.violates(f.limit, f.sense)) try push(r, rule, severity, ring_layer, store.firstVertex(poly), poly, f.measured, f.limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Per merged `region` figure with channel area, its `contact` area over
/// its `channel` area (each merged, clipped to the figure) against
/// `min_ratio`, at the figure's lowest drawn polygon. `examined` counts
/// figures with channel area; refused when a layer will not validate.
pub fn checkTieArea(r: Record, design: Design, t: *const TieAreaTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    var contact: rects.SortedRects = .{};
    defer contact.deinit(gpa);
    var channel: rects.SortedRects = .{};
    defer channel.deinit(gpa);
    var drawn: rects.LayerRects = .{};
    defer drawn.deinit(gpa);
    var owners: std.ArrayList(PolyId) = .empty;
    defer owners.deinit(gpa);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.region.items, t.contact.items, t.channel.items, t.min_ratio.items) |rule, severity, region, contact_layer, channel_layer, min_ratio| {
        const before = r.out.len();
        const ok = try areaIndex(gpa, store, contact_layer, &contact) and try areaIndex(gpa, store, channel_layer, &channel) and
            try mergedInto(gpa, store, region, &scratch.layer_a, &scratch.layer_b);
        if (!ok) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        try drawn.build(gpa, store, region, &scratch.layer_a);
        try rects.ownersOfInto(gpa, &scratch.layer_b, &drawn, &owners);
        try geom.rects.decomposeInto(gpa, &scratch.layer_b, &boxes, &start);
        const limit: Measurement = .ratio(min_ratio);
        var examined: u64 = 0;
        for (owners.items, start.items[0 .. start.items.len - 1], start.items[1..]) |owner, from, to| {
            const pieces = boxes.items[from..to];
            const injecting = areaWithin(&channel, pieces);
            if (injecting == 0) continue;
            examined += 1;
            const tied = areaWithin(&contact, pieces);
            const measured: Measurement = .ratio(@as(f64, @floatFromInt(tied)) / @as(f64, @floatFromInt(injecting)));
            if (owner != report.no_shape and measured.violates(limit, .minimum)) try push(r, rule, severity, region, store.firstVertex(owner), owner, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every diode of a row's models whose anode can rise above its cathode
/// (both reached by a supply) and whose marker no polygon of `marker`
/// covers: a finding at its marker measuring the largest forward bias, mV,
/// against 0. `examined` counts diodes with both ends reached. Skipped
/// without usable intent; refused when the marker layer will not validate.
pub fn checkForwardDiode(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const ForwardDiodeTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const store = design.store;
    const devices = design.devices;
    var layer: geom.ValidatedLayer = .empty;
    defer layer.deinit(gpa);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.marker.items, 0..) |rule, severity, marker, row| {
        const before = r.out.len();
        const models = t.model.items[t.model_start.items[row]..t.model_start.items[row + 1]];
        if (try geom.view.validateLayer(gpa, store, marker, .rectilinear, &layer) != null) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        try geom.rects.decomposeInto(gpa, &layer, &boxes, &start);
        const limit: Measurement = mv(0.0);
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            if (devices.kind.items[d] != .diode or std.mem.indexOfScalar(StrId, models, devices.model.items[d]) == null) continue;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const anode = head.terminalNet(term.nets, term.roles, .{ .pin = 0 });
            const cathode = head.terminalNet(term.nets, term.roles, .{ .pin = 1 });
            if (!(voltage.known(anode) and voltage.known(cathode))) continue;
            examined += 1;
            const measured = mv(voltage.hi.items[@backingInt(anode)] - voltage.lo.items[@backingInt(cathode)]);
            const marked = rings.encloses(boxes.items, start.items, store.polyBbox(devices.marker.items[d]));
            if (!marked and measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every `region` polygon held to its band's tap distance: the band of the
/// least distance from an `other` polygon within `within` of it to any
/// `well` polygon (the loosest limit with none). A finding at its furthest
/// point from a tap measures that distance against its band's limit.
/// `examined` counts region polygons; refused when the tap layer will not
/// validate.
pub fn checkConditionalTie(r: Record, design: Design, t: *const ConditionalTieTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    var others: std.ArrayList(PolyId) = .empty;
    defer others.deinit(gpa);
    var wells: std.ArrayList(PolyId) = .empty;
    defer wells.deinit(gpa);
    var limits: std.ArrayList(?Dbu) = .empty;
    defer limits.deinit(gpa);
    var untied: taps.Untied = .{};
    defer untied.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const spacing = t.spacing.items[t.spacing_start.items[row]..t.spacing_start.items[row + 1]];
        const band_limit = t.max_distance.items[t.max_distance_start.items[row]..t.max_distance_start.items[row + 1]];
        const within = t.within.items[row];
        const within2 = geom.mulWide(within, within);
        try ring.outersInto(gpa, store, t.other.items[row], &others);
        try ring.outersInto(gpa, store, t.well.items[row], &wells);
        // ponytail: every neighbour against every well per region; a spatial
        // index if layouts grow large.
        const region_rows = store.polysOnLayer(t.region.items[row]);
        limits.clearRetainingCapacity();
        for (region_rows.start..region_rows.end) |p| {
            const region: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            if (!isOuter(store, region)) {
                try limits.append(gpa, null);
                continue;
            }
            const rb = store.polyBbox(region);
            var nearest: ?DbuArea = null;
            for (others.items) |o| {
                if (!(store.polyBbox(o).within(rb, within) and rings.regionDist2(store, region, o) <= within2)) continue;
                for (wells.items) |w| {
                    const d = rings.regionDist2(store, o, w);
                    nearest = @min(nearest orelse d, d);
                }
            }
            const band = if (nearest) |x| blk: {
                var n: usize = 0;
                for (spacing) |th| n += @intFromBool(geom.mulWide(th, th) <= x);
                break :blk n;
            } else spacing.len;
            try limits.append(gpa, band_limit[band]);
        }
        const examined = try taps.untiedPointsBy(gpa, store, t.region.items[row], t.tap.items[row], limits.items, &scratch.layer_b, &untied) orelse {
            try r.run(rule, before, .refused, 0);
            continue;
        };
        try pushUntied(r, design, rule, severity, &untied);
        try r.run(rule, before, .ran, examined);
    }
}

/// Every `region` polygon within `within` of an aggressor (an `aggressor`
/// polygon, on a `pad` net when stated, and with `bias` one its voltages can
/// forward-bias against the bias polygon it lies in) held to
/// `max_distance` from a tap. `examined` counts victims. A row with `bias`
/// is skipped without usable intent; refused when the tap layer will not
/// validate.
pub fn checkLatchupVictim(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const LatchupVictimTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const store = design.store;
    const nets = design.nets;
    var pads: std.ArrayList(NetId) = .empty;
    defer pads.deinit(gpa);
    var candidates: std.ArrayList(PolyId) = .empty;
    defer candidates.deinit(gpa);
    var biases: std.ArrayList(PolyId) = .empty;
    defer biases.deinit(gpa);
    var aggressors: std.ArrayList(PolyId) = .empty;
    defer aggressors.deinit(gpa);
    var limits: std.ArrayList(?Dbu) = .empty;
    defer limits.deinit(gpa);
    var untied: taps.Untied = .{};
    defer untied.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const bias = t.bias.items[row];
        if (bias != null and !intent.isUsable()) {
            try r.run(rule, before, .{ .skipped = .no_design_intent }, 0);
            continue;
        }
        const pad = t.pad.items[row];
        if (pad) |p| try rings.padNetsInto(gpa, design, p, &pads);
        if (bias) |b| try ring.outersInto(gpa, store, b.layer, &biases);
        try ring.outersInto(gpa, store, t.aggressor.items[row], &candidates);
        aggressors.clearRetainingCapacity();
        for (candidates.items) |poly| {
            if (pad != null and (pads.items.len == 0 or !containsNet(pads.items, nets.netOf(poly)))) continue;
            if (bias) |b| if (!injects(design, voltage, biases.items, b.above, poly)) continue;
            try aggressors.append(gpa, poly);
        }
        const within = t.within.items[row];
        const within2 = geom.mulWide(within, within);
        const limit = t.max_distance.items[row];
        const region_rows = store.polysOnLayer(t.region.items[row]);
        limits.clearRetainingCapacity();
        for (region_rows.start..region_rows.end) |p| {
            const region: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            const rb = store.polyBbox(region);
            const near = isOuter(store, region) and for (aggressors.items) |a| {
                if (store.polyBbox(a).within(rb, within) and rings.regionDist2(store, region, a) <= within2) break true;
            } else false;
            try limits.append(gpa, if (near) limit else null);
        }
        const examined = try taps.untiedPointsBy(gpa, store, t.region.items[row], t.tap.items[row], limits.items, &scratch.layer_b, &untied) orelse {
            try r.run(rule, before, .refused, 0);
            continue;
        };
        try pushUntied(r, design, rule, severity, &untied);
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

fn mv(v: f64) Measurement {
    return .voltage(.{ .raw = v });
}

fn isOuter(store: *const GeometryStore, poly: PolyId) bool {
    const v = store.polyVerts(poly);
    return geom.ops.windingOf(v.xs, v.ys) != .cw;
}

fn containsNet(sorted: []const NetId, net: NetId) bool {
    return std.sort.binarySearch(NetId, sorted, net, struct {
        fn order(a: NetId, b: NetId) std.math.Order {
            return std.math.order(@backingInt(a), @backingInt(b));
        }
    }.order) != null;
}

/// The aggressor's net can forward-bias it against a bias polygon that
/// holds it: rise above that polygon net's lowest (`above`), or fall below
/// its highest.
fn injects(design: Design, voltage: *const NetVoltage, biases: []const PolyId, above: bool, poly: PolyId) bool {
    const store = design.store;
    const net = design.nets.netOf(poly);
    if (!voltage.known(net)) return false;
    const pv = store.polyVerts(poly);
    const pb = store.polyBbox(poly);
    for (biases) |b| {
        const bv = store.polyVerts(b);
        const well = design.nets.netOf(b);
        if (!(store.polyBbox(b).contains(pb) and ring.surrounds(bv.xs, bv.ys, pv.xs, pv.ys) and voltage.known(well))) continue;
        const n = @backingInt(net);
        const w = @backingInt(well);
        if (if (above) voltage.hi.items[n] > voltage.lo.items[w] else voltage.lo.items[n] < voltage.hi.items[w]) return true;
    }
    return false;
}

/// `layer` validated (into `drawn`) and merged (into `out`); false when it
/// will not validate.
fn mergedInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, drawn: *geom.ValidatedLayer, out: *geom.ValidatedLayer) Allocator.Error!bool {
    if (try geom.view.validateLayer(gpa, store, layer, .rectilinear, drawn) != null) return false;
    const nothing: geom.ValidatedLayer = .empty;
    try geom.boolean.unionInto(gpa, drawn, &nothing, out);
    return true;
}

/// Every rectangle of `layer` merged, disjoint, into `out`; false when it
/// will not validate.
fn areaIndex(gpa: Allocator, store: *const GeometryStore, layer: LayerId, out: *rects.SortedRects) Allocator.Error!bool {
    var drawn: geom.ValidatedLayer = .empty;
    defer drawn.deinit(gpa);
    var figures: geom.ValidatedLayer = .empty;
    defer figures.deinit(gpa);
    if (!try mergedInto(gpa, store, layer, &drawn, &figures)) return false;
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, &figures, &boxes, &start);
    const labels = try gpa.alloc(u32, boxes.items.len);
    defer gpa.free(labels);
    @memset(labels, 0);
    try out.build(gpa, boxes.items, labels);
    return true;
}

/// The area of `index` inside the disjoint rectangles `figure`, exactly.
fn areaWithin(index: *const rects.SortedRects, figure: []const Bbox) i128 {
    var total: i128 = 0;
    for (figure) |f| {
        var hits = index.overlapping(f);
        while (hits.next()) |h| total += h.clip.area();
    }
    return total;
}

fn pushUntied(r: Record, design: Design, rule: StrId, severity: report.Severity, untied: *const taps.Untied) Allocator.Error!void {
    for (untied.poly.items, untied.at.items, untied.worst2.items, untied.limit.items) |poly, at, worst, limit| {
        try push(r, rule, severity, design.store.polyLayer(poly), at, poly, .length(geom.ops.isqrt(worst)), .length(limit));
    }
}

fn push(r: Record, rule: StrId, severity: report.Severity, layer: LayerId, at: geom.Point, shape: PolyId, measured: Measurement, limit: Measurement) Allocator.Error!void {
    try r.out.push(r.gpa, .{ .rule = rule, .layer = layer, .severity = severity, .at = at, .measured = measured, .limit = limit, .shape_a = shape, .shape_b = report.no_shape });
}
