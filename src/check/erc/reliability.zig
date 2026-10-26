//! The reliability kinds: voltage-stress lifetime on the supply grid
//! (`reliability`: `t = t_ref (V_ref/|V|)^n exp(Ea/k (1/T - 1/T_ref)) /
//! duty`, JEP122), the domain span across a device (`hv_domain`, sky130
//! hv.X), and pad clamping with pad guard rings (`esd_latchup`, ESDA
//! TR18.0-01 §4.5). In: the solved grid, propagated voltages, the intent,
//! geometry. Out: violations and one run per row; every row skipped
//! without usable intent. Ported from crates/check/src/erc/rules/
//! reliability.rs (the `check_*` functions, `domain_spread`,
//! `nearest_supply`, `separation`).
//!
//! Contents:
//! - `pub fn checkReliability(r: Record, power: Power, intent: *const IntentMap, temperature: Kelvin, t: *const ReliabilityTable) Allocator.Error!void`
//! - `pub fn checkHvDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvDomainTable) Allocator.Error!void`
//! - `pub fn checkEsdLatchup(r: Record, design: Design, intent: *const IntentMap, t: *const EsdLatchupTable, scratch: *Scratch) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Millivolts = report.Millivolts;
const NetId = @import("../topology/net.zig").NetId;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const Power = @import("power_grid.zig").Power;
const Scratch = @import("scratch.zig").Scratch;
const clamp_reach = @import("clamp_reach.zig");
const rings = @import("rings.zig");
const Kelvin = @import("electrical_tables.zig").Kelvin;
const boltzmann_ev_per_k = @import("electrical_tables.zig").boltzmann_ev_per_k;
const tables = @import("esd_tables.zig");
const EsdLatchupTable = tables.EsdLatchupTable;
const HvDomainTable = tables.HvDomainTable;
const ReliabilityTable = tables.ReliabilityTable;

/// Every row over the solved grid's node voltages. `examined` counts every
/// node. A violation sits at the node: `|V|` against `max_abs_voltage`, or
/// the predicted lifetime (hours, a ratio) against `required_lifetime`. A
/// row refuses when its model is unusable. A budget that reached no device
/// does not refuse: every node then sits at nominal, the largest stress.
pub fn checkReliability(r: Record, power: Power, intent: *const IntentMap, temperature: Kelvin, t: *const ReliabilityTable) Allocator.Error!void {
    const solved = switch (power) {
        .failed => return r.fillRows(&t.head, .refused),
        .no_supply => return r.skipRows(&t.head),
        .solved => |s| s,
    };
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const g = solved.grid;
    const volts = solved.solution.node_voltage.items;
    const applied_k = temperature.raw;
    const hour = try r.gpa.alloc(f64, volts.len);
    defer r.gpa.free(hour);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const duty = t.duty_cycle.items[row];
        const reference_k = t.reference_temperature.items[row].raw;
        const required = t.required_lifetime_hours.items[row];
        const cap = t.max_abs_voltage.items[row];
        const reference_stress = t.reference_stress.items[row].raw;
        const exponent = t.stress_exponent.items[row];
        const thermal = @exp(t.activation_energy_ev.items[row] / boltzmann_ev_per_k * (1.0 / applied_k - 1.0 / reference_k));
        // Hours a node at exactly `reference_stress` would last.
        const unit = t.reference_lifetime_hours.items[row] * thermal / duty;
        // Decided before anything is pushed.
        const usable = duty >= 0.0 and duty <= 1.0 and applied_k > 0.0 and reference_k > 0.0 and reference_stress > 0.0 and
            std.math.isFinite(exponent) and std.math.isFinite(required) and required > 0.0 and cap.isFinite() and
            std.math.isFinite(unit) and unit > 0.0;
        var sound = usable;
        if (usable) for (volts, hour) |stress, *h| {
            // A node at 0 V (a ground rail) is unstressed: infinite hours.
            h.* = unit * std.math.pow(f64, reference_stress / @abs(stress.raw), exponent);
            sound = sound and !std.math.isNan(h.*);
        };
        if (!sound) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        const cap_limit = Measurement.voltage(cap);
        const required_limit = Measurement.ratio(required);
        for (volts, hour, 0..) |v, h, node| {
            const applied = Measurement.voltage(.{ .raw = @abs(v.raw) });
            if (applied.violates(cap_limit, .maximum)) try nodeViolation(r, g, @intCast(node), rule, severity, applied, cap_limit);
            const hours = Measurement.ratio(h);
            if (std.math.isFinite(h) and hours.violates(required_limit, .minimum)) try nodeViolation(r, g, @intCast(node), rule, severity, hours, required_limit);
        }
        try r.run(rule, before, .ran, volts.len);
    }
}

/// Every row over every device. `examined` counts devices whose every
/// terminal some supply reaches. A violation sits at the marker's first
/// vertex and measures the domain span against `max_delta`; a device whose
/// marker box one `isolation` polygon wholly covers is exempt. A row
/// refuses when its isolation layer will not validate.
pub fn checkHvDomain(r: Record, design: Design, intent: *const IntentMap, voltage: *const NetVoltage, t: *const HvDomainTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const store = design.store;
    const devices = design.devices;
    var isolation: geom.ValidatedLayer = .empty;
    defer isolation.deinit(gpa);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.max_domain_delta.items, t.isolation.items) |rule, severity, max, layer| {
        const before = r.out.len();
        const limit = Measurement.voltage(max);
        // No exemption is an empty layer, so containment answers false.
        isolation.clear();
        if (layer) |l| if (try geom.view.validateLayer(gpa, store, l, .rectilinear, &isolation) != null) {
            try r.run(rule, before, .refused, 0);
            continue;
        };
        try geom.rects.decomposeInto(gpa, &isolation, &boxes, &start);
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            const spread = domainSpread(voltage, devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d)))).nets) orelse continue;
            examined += 1;
            const marker = devices.marker.items[d];
            const measured = Measurement.voltage(spread);
            const exempt = rings.encloses(boxes.items, start.items, store.polyBbox(marker));
            if (!exempt and measured.violates(limit, .maximum)) try r.deviceViolation(design, @intCast(d), rule, severity, measured, limit);
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every row: its pad nets, then its guard rings. `examined` counts
/// distinct pad nets plus ring polygons. A pad violation measures the rail
/// kinds its clamps reach (0 or 1) against 2; a ring's measures its width
/// or tap gap against the limit, or 0 against 1 with no supply shape at
/// all. A row refuses when its ring layer will not validate.
pub fn checkEsdLatchup(r: Record, design: Design, intent: *const IntentMap, t: *const EsdLatchupTable, scratch: *Scratch) Allocator.Error!void {
    // With no declared supply there is no discharge target.
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const store = design.store;
    const nets = design.nets;
    // Row generation that last saw each net: dedups pad nets per row.
    scratch.net_marks.clearRetainingCapacity();
    try scratch.net_marks.appendNTimes(gpa, 0, nets.netCount());
    // The declared supplies' boxes, once.
    scratch.boxes.clearRetainingCapacity();
    for (intent.supply_net.items) |net| for (nets.polysOf(net)) |p| try scratch.boxes.append(gpa, store.polyBbox(p));
    var walk: clamp_reach.Walk = .{};
    defer walk.deinit(gpa);
    var narrow: std.ArrayList(rings.Narrow) = .empty;
    defer narrow.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const generation: u32 = @intCast(row + 1);
        var examined: u64 = 0;
        const ring_layer = t.guard_ring.items[row];
        const min_width = t.min_guard_ring_width.items[row];
        if (!try rings.narrowRingsInto(gpa, design, ring_layer, min_width, scratch, &narrow)) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        const pad_layer = t.pad.items[row];
        const clamps = t.clamp.items[t.clamp_start.items[row]..t.clamp_start.items[row + 1]];
        const pads = store.polysOnLayer(pad_layer);
        for (pads.start..pads.end) |p| {
            const pad: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            const net = nets.netOf(pad);
            if (net == .none or scratch.net_marks.items[@backingInt(net)] == generation) continue;
            scratch.net_marks.items[@backingInt(net)] = generation;
            examined += 1;
            const rails = try clamp_reach.clampRails(gpa, design, intent, clamps, net, &walk);
            if (rails < 2) try push(r, store, pad, pad_layer, rule, severity, Measurement.count(rails), Measurement.count(2));
        }
        const width_limit = Measurement.length(min_width);
        const max_tap = t.max_tap_distance.items[row];
        const rows = store.polysOnLayer(ring_layer);
        for (rows.start..rows.end) |p| {
            const ring: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
            examined += 1;
            for (narrow.items) |n| if (n.poly == ring) {
                try push(r, store, ring, ring_layer, rule, severity, Measurement.length(n.band), width_limit);
                break;
            };
            // No supply at all is an absent tap, not a saturated distance.
            if (nearestSupply(scratch.boxes.items, store.polyBbox(ring))) |gap| {
                const measured = Measurement.length(gap);
                const limit = Measurement.length(max_tap);
                if (measured.violates(limit, .maximum)) try push(r, store, ring, ring_layer, rule, severity, measured, limit);
            } else try push(r, store, ring, ring_layer, rule, severity, Measurement.count(0), Measurement.count(1));
        }
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

fn nodeViolation(r: Record, g: *const @import("power_grid.zig").PowerGrid, node: u32, rule: geom.StrId, severity: report.Severity, measured: Measurement, limit: Measurement) Allocator.Error!void {
    try r.out.push(r.gpa, .{ .rule = rule, .layer = g.node_layer.items[node], .severity = severity, .at = g.node_at.items[node], .measured = measured, .limit = limit, .shape_a = g.node_poly.items[node], .shape_b = report.no_shape });
}

fn push(r: Record, store: *const geom.GeometryStore, poly: PolyId, layer: geom.LayerId, rule: geom.StrId, severity: report.Severity, measured: Measurement, limit: Measurement) Allocator.Error!void {
    try r.out.push(r.gpa, .{ .rule = rule, .layer = layer, .severity = severity, .at = store.firstVertex(poly), .measured = measured, .limit = limit, .shape_a = poly, .shape_b = report.no_shape });
}

/// The widest nominal spread across a device's terminals; null when no
/// supply reaches some terminal (or there is none).
fn domainSpread(voltage: *const NetVoltage, nets: []const NetId) ?Millivolts {
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (nets) |net| {
        if (!voltage.known(net)) return null;
        lo = @min(lo, voltage.nominal_lo.items[@backingInt(net)]);
        hi = @max(hi, voltage.nominal_hi.items[@backingInt(net)]);
    }
    return if (hi >= lo) .{ .raw = hi - lo } else null;
}

/// The gap from a ring to the nearest supply box; null with none.
fn nearestSupply(supply: []const Bbox, ring: Bbox) ?Dbu {
    var best: ?Dbu = null;
    for (supply) |b| {
        const gap = separation(ring, b);
        best = if (best) |x| @min(x, gap) else gap;
    }
    return best;
}

/// The larger of two boxes' x and y gaps; zero when they touch or overlap.
fn separation(a: Bbox, b: Bbox) Dbu {
    const dx = @max(b.xlo - a.xhi, a.xlo - b.xhi, 0);
    const dy = @max(b.ylo - a.yhi, a.ylo - b.yhi, 0);
    return @max(dx, dy);
}

fn box(xlo: Dbu, ylo: Dbu, xhi: Dbu, yhi: Dbu) Bbox {
    return .{ .xlo = xlo, .ylo = ylo, .xhi = xhi, .yhi = yhi };
}

test "separation is the larger axis gap and zero on contact" {
    // Oracle: closed form, by hand: [0,10]² against [13,20]×[0,10] is 3
    // apart along x, against [0,10]×[-9,-4] 4 along y, against
    // [15,20]×[17,30] max(5, 7) = 7, against a box touching its edge or
    // inside it 0.
    const a = box(0, 0, 10, 10);
    const cases = [_]struct { Bbox, Dbu }{
        .{ box(13, 0, 20, 10), 3 }, .{ box(-8, 2, -5, 3), 5 },   .{ box(0, -9, 10, -4), 4 },
        .{ box(2, 16, 3, 20), 6 },  .{ box(15, 17, 20, 30), 7 }, .{ box(-20, -30, -18, -2), 18 },
        .{ box(10, 3, 12, 4), 0 },  .{ box(2, 2, 3, 3), 0 },     .{ box(-5, -5, 20, 20), 0 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c[1], separation(a, c[0]));
        try std.testing.expectEqual(c[1], separation(c[0], a));
    }
}

test "domain spread is the widest nominal gap over the terminals" {
    // Oracle: closed form: nets at 1.8 V, 3.3 V and a 1.2..5 V net give
    // 3300 - 1800 = 1500 mV and 5000 - 1200 = 3800 mV; one net alone, 0.
    const gpa = std.testing.allocator;
    var v: NetVoltage = .{};
    defer v.deinit(gpa);
    const inf = std.math.inf(f64);
    try v.lo.appendSlice(gpa, &.{ 1_800, 3_300, 1_200, inf });
    try v.hi.appendSlice(gpa, &.{ 1_800, 3_300, 5_000, -inf });
    try v.nominal_lo.appendSlice(gpa, &.{ 1_800, 3_300, 1_200, inf });
    try v.nominal_hi.appendSlice(gpa, &.{ 1_800, 3_300, 5_000, -inf });
    try v.power.appendNTimes(gpa, 0, 4);
    try v.ground.appendNTimes(gpa, 0, 4);
    const n = struct {
        fn id(i: u32) NetId {
            return @fromBackingInt(i);
        }
    }.id;
    try std.testing.expectEqual(@as(f64, 1_500), domainSpread(&v, &.{ n(0), n(1) }).?.raw);
    try std.testing.expectEqual(@as(f64, 1_500), domainSpread(&v, &.{ n(1), n(0), n(0) }).?.raw);
    try std.testing.expectEqual(@as(f64, 3_800), domainSpread(&v, &.{ n(0), n(2), n(1) }).?.raw);
    try std.testing.expectEqual(@as(f64, 0), domainSpread(&v, &.{n(1)}).?.raw);
    try std.testing.expect(domainSpread(&v, &.{ n(0), n(3) }) == null);
    try std.testing.expect(domainSpread(&v, &.{}) == null);
}

test "encloses needs one polygon to cover the whole box" {
    // Oracle: closed form: polygon 0 is [0,10]², polygon 1 the two halves
    // [20,25]×[0,10] and [25,30]×[0,10]; [2,8]² lies in polygon 0,
    // [21,29]×[1,9] in polygon 1's halves, [8,22]×[1,9] straddles both,
    // [0,10]² is polygon 0 itself.
    const boxes = [_]Bbox{ box(0, 0, 10, 10), box(20, 0, 25, 10), box(25, 0, 30, 10) };
    const start = [_]u32{ 0, 1, 3 };
    try std.testing.expect(rings.encloses(&boxes, &start, box(2, 2, 8, 8)));
    try std.testing.expect(rings.encloses(&boxes, &start, box(0, 0, 10, 10)));
    try std.testing.expect(rings.encloses(&boxes, &start, box(21, 1, 29, 9)));
    try std.testing.expect(!rings.encloses(&boxes, &start, box(8, 1, 22, 9)));
    try std.testing.expect(!rings.encloses(&boxes, &start, box(5, 5, 11, 9)));
    try std.testing.expect(!rings.encloses(&boxes, &.{0}, box(2, 2, 8, 8)));
}
