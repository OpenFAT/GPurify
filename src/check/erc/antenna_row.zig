//! One antenna row: each gate's ratio summed over the row's etch stages
//! (LEF/DEF 5.8 Appendix C: a PAR per stage, their sum the CAR), with
//! LEF's per-layer partial ratio and diode terms for an electrical row, and
//! the gates on one net at every stage judged once. In: the design, the
//! macro pins, the row's layers and measures, the etch stack, a judge.
//! Out: violations (with their fix hints) and the examined count, or null
//! (refused). Ported from crates/check/src/erc/rules/antenna.rs (`Par`,
//! `pwl`, `area_times`, `Credit`, `antenna_row`).
//!
//! Contents:
//! - `pub const Par = struct`, `pub const Judged = struct { value: f64, limit: f64, fix: ?DbuArea }`, `pub const Row = struct`
//! - `pub fn pwl(points: []const AreaPoint, area: i128) f64`, `pub fn areaTimes(per: DbuArea, ratio: f64) i128`
//! - `pub const Credit = struct`, `credited(c, area: i128) f64`, `limit(c, area: i128) f64`, `leastDiode(c, present: i128) ?i128`
//! - `pub fn antennaRow(r: Record, design: Design, pins: []const MacroPinAntenna, row: Row, stack: Stack, judge: anytype, scratch: *Scratch) Allocator.Error!?u64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const AntennaKind = @import("ingest").lefdef.AntennaKind;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const NetId = @import("../topology/net.zig").NetId;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const Scratch = @import("scratch.zig").Scratch;
const antenna = @import("antenna_tables.zig");
const Stack = antenna.Stack;
const MacroPinAntenna = antenna.MacroPinAntenna;
const AntennaMeasure = antenna.AntennaMeasure;
const AreaPoint = antenna.AreaPoint;
const stage_ = @import("antenna_stage.zig");
const Figures = stage_.Figures;

/// LEF's partial ratio of one collector layer on a gate's node:
/// `(factor * area * reduce(diode) - minus * diode) / (gate + plus * diode)`.
pub const Par = struct {
    /// `ANTENNAAREAFACTOR` of a cut layer.
    cut_factor: f64,
    /// `ANTENNAAREAMINUSDIFF`.
    minus: f64,
    /// `ANTENNAGATEPLUSDIFF`.
    plus: f64,
    /// `ANTENNAAREADIFFREDUCEPWL`; empty for a factor of 1.
    reduce: []const AreaPoint,
};

/// What a judge makes of a gate group's ratio: the value compared, the
/// limit, and the finding's fix hint (a diode area).
pub const Judged = struct { value: f64, limit: f64, fix: ?DbuArea };

/// One row's identity and layers.
pub const Row = struct {
    rule: geom.StrId,
    severity: report.Severity,
    gate: LayerId,
    collectors: []const LayerId,
    measures: []const AntennaMeasure,
    diode: ?LayerId,
    exempt: ?LayerId = null,
    /// Null for an `antenna` row.
    par: ?Par = null,
};

/// One gate's ratio under an electrical row whose ratio does not move with
/// the diode: the credited value and the limit as functions of the diode
/// area on the net, square database units.
pub const Credit = struct {
    ratio: f64,
    /// `diode_credit` per square database unit.
    per_dbu2: f64,
    bonus: f64,
    max_ratio: f64,
    table: []const AreaPoint,

    /// The credited ratio with `area` of diode; `area` is positive.
    pub fn credited(c: Credit, area: i128) f64 {
        return c.ratio - c.per_dbu2 * @as(f64, @floatFromInt(area)) - c.bonus;
    }

    /// The limit with `area` of diode; `area` is positive.
    pub fn limit(c: Credit, area: i128) f64 {
        return if (c.table.len == 0) c.max_ratio else pwl(c.table, area);
    }

    /// The least diode area above `present` (and above 0) within the limit,
    /// or null when none is: each linear piece of the excess between the
    /// table's points solved in turn (past the last only the credit falls),
    /// its root rounded up.
    pub fn leastDiode(c: Credit, present: i128) ?i128 {
        const start: i128 = @max(present, 0) + 1;
        var from: i128 = start;
        if (c.within(from)) return from;
        var last_end: ?i128 = null;
        for (c.table) |p| {
            const to = p.area;
            if (to <= start or (last_end != null and last_end.? == to)) continue;
            last_end = to;
            const a = c.excess(from);
            const b = c.excess(to);
            if (c.within(to)) return c.settle(start, @as(f64, @floatFromInt(from)) + a / (a - b) * @as(f64, @floatFromInt(to - from)));
            from = to;
        }
        // Past the last point the limit holds; only the credit falls.
        if (!(c.per_dbu2 > 0.0)) return null;
        return c.settle(start, @as(f64, @floatFromInt(from)) + c.excess(from) / c.per_dbu2);
    }

    fn excess(c: Credit, area: i128) f64 {
        return c.credited(area) - c.limit(area);
    }

    /// Within the limit, up to the rounding of a few f64 terms.
    fn within(c: Credit, area: i128) bool {
        return c.excess(area) <= 1e-9 * @max(@abs(c.limit(area)), 1.0);
    }

    /// From the unit below the piece's root, step up to the first area
    /// within the limit.
    fn settle(c: Credit, start: i128, root: f64) i128 {
        var area = @max(@as(i128, @intFromFloat(@round(root))) - 1, start);
        while (!c.within(area)) area += 1;
        return area;
    }
};

/// One row's buffers, freed together.
const Work = struct {
    gpa: Allocator,
    gates: Figures = .{},
    collected: std.ArrayList(Figures) = .empty,
    diodes: Figures = .{},
    exempts: Figures = .{},
    read_layer: std.ArrayList(LayerId) = .empty,
    read_measure: std.ArrayList(AntennaMeasure) = .empty,
    gate_pins: std.ArrayList(MacroPinAntenna) = .empty,
    etched: std.ArrayList(?usize) = .empty,
    stages: std.ArrayList(?usize) = .empty,
    ratio: std.ArrayList(f64) = .empty,
    key: std.ArrayList(NetId) = .empty,
    diode_area: std.ArrayList(i128) = .empty,
    exempted: std.ArrayList(bool) = .empty,
    net_of: std.ArrayList(NetId) = .empty,
    here: std.ArrayList(usize) = .empty,
    layers: std.ArrayList(LayerId) = .empty,
    gate_area: std.ArrayList(i128) = .empty,
    on_net: std.ArrayList(i128) = .empty,
    exempt_on: std.ArrayList(i128) = .empty,
    collect: std.ArrayList(i128) = .empty,
    mine: std.ArrayList(i128) = .empty,
    order: std.ArrayList(usize) = .empty,

    fn deinit(w: *Work) void {
        w.gates.deinit(w.gpa);
        for (w.collected.items) |*f| f.deinit(w.gpa);
        w.diodes.deinit(w.gpa);
        w.exempts.deinit(w.gpa);
        inline for (.{ "collected", "read_layer", "read_measure", "gate_pins", "etched", "stages", "ratio", "key", "diode_area", "exempted", "net_of", "here", "layers", "gate_area", "on_net", "exempt_on", "collect", "mine", "order" }) |f| @field(w, f).deinit(w.gpa);
    }

    fn run(w: *Work, r: Record, design: Design, pins: []const MacroPinAntenna, row: Row, stack: Stack, judge: anytype, scratch: *Scratch) Allocator.Error!?u64 {
        const gpa = w.gpa;
        const store = design.store;
        // With no gate there is nothing to measure, whatever the collectors
        // hold (a collector that cannot merge refuses only a row reading it).
        if (!try stage_.mergedInto(gpa, design, row.gate, scratch, &w.gates)) return null;
        for (pins) |pin| for (pin.values) |v| if (v.kind == .gate and v.value > 0.0) {
            try w.gate_pins.append(gpa, pin);
            break;
        };
        if (w.gates.len() == 0 and w.gate_pins.items.len == 0) return 0;
        // A collector named twice collects once, with its first measure.
        for (row.collectors, row.measures) |layer, measure| if (std.mem.indexOfScalar(LayerId, w.read_layer.items, layer) == null) {
            try w.read_layer.append(gpa, layer);
            try w.read_measure.append(gpa, measure);
        };
        const read = w.read_layer.items;
        for (read) |layer| {
            try w.collected.append(gpa, .{});
            if (!try stage_.mergedInto(gpa, design, layer, scratch, &w.collected.items[w.collected.items.len - 1])) return null;
        }
        if (row.diode) |l| if (!try stage_.mergedInto(gpa, design, l, scratch, &w.diodes)) return null;
        if (row.exempt) |l| if (!try stage_.mergedInto(gpa, design, l, scratch, &w.exempts)) return null;

        // Each collector's etch stage; the row's is the highest, and a layer
        // the stack does not place is etched with it. No conductors: every
        // stage is the finished nets.
        const row_stage: ?usize = if (stack.conductors.len == 0) null else blk: {
            var top: ?usize = null;
            for (read) |l| if (stage_.standing(stack, l)) |s| {
                top = @max(top orelse 0, s);
            };
            break :blk top orelse stack.conductors.len - 1;
        };
        for (read) |l| try w.etched.append(gpa, if (row_stage) |top| stage_.standing(stack, l) orelse top else null);
        try w.stages.appendSlice(gpa, w.etched.items);
        std.mem.sortUnstable(?usize, w.stages.items, {}, lessStage);
        w.stages.shrinkRetainingCapacity(dedupStages(w.stages.items));
        const stages = w.stages.items;

        // Per gate (the figures, then the pins' gates): the summed ratio, its
        // net at each stage (stage-major), the diode area at the row's stage.
        const n = w.gates.len();
        const total = n + w.gate_pins.items.len;
        const cumulative = read.len > 1;
        try w.ratio.appendNTimes(gpa, 0.0, total);
        try w.key.appendNTimes(gpa, .none, total * stages.len);
        try w.diode_area.appendNTimes(gpa, 0, total);
        try w.exempted.appendNTimes(gpa, false, total);
        try w.net_of.appendNTimes(gpa, .none, store.polyCount());
        const ratio = w.ratio.items;
        const net_of = w.net_of.items;
        for (stages, 0..) |stage, s| {
            const last = s + 1 == stages.len;
            w.here.clearRetainingCapacity();
            for (0..read.len) |c| if (w.etched.items[c] == stage) try w.here.append(gpa, c);
            // A cut is etched after the conductor it stands on (stable).
            std.mem.sort(usize, w.here.items, ConductorFirst{ .read = read, .conductors = stack.conductors }, ConductorFirst.less);
            w.layers.clearRetainingCapacity();
            for (w.here.items) |c| try w.layers.append(gpa, read[c]);
            try w.layers.append(gpa, row.gate);
            if (row.diode) |l| try w.layers.append(gpa, l);
            if (last) if (row.exempt) |l| try w.layers.append(gpa, l);
            for (pins) |pin| try w.layers.append(gpa, store.polyLayer(pin.poly));
            std.mem.sortUnstable(LayerId, w.layers.items, {}, lessLayer);
            w.layers.shrinkRetainingCapacity(dedupLayers(w.layers.items));
            const count = try stage_.stageNetsInto(gpa, design, stack, stage, w.layers.items, &scratch.staged_nets, net_of, scratch) orelse return null;

            w.gate_area.clearRetainingCapacity();
            try w.gate_area.appendNTimes(gpa, 0, count);
            const gate_area = w.gate_area.items;
            const gate_net = w.key.items[s * total ..][0..total];
            for (gate_net[0..n], 0..) |*net, g| {
                net.* = w.gates.net(g, net_of);
                if (net.* != .none) gate_area[@backingInt(net.*)] += w.gates.area2.items[g];
            }
            for (gate_net[n..], w.gate_pins.items) |*net, pin| {
                net.* = net_of[@backingInt(pin.poly)];
                if (net.* != .none) gate_area[@backingInt(net.*)] += stage_.joined(pin, .gate, stack, stage);
            }
            // The doubled diode area on each net as this stage stands.
            if (row.diode != null) try w.diodes.areaPerNetInto(gpa, net_of, count, &w.on_net) else try zeroed(gpa, &w.on_net, count);
            if (row.diode != null) for (pins) |pin| {
                const pn = net_of[@backingInt(pin.poly)];
                if (pn != .none) w.on_net.items[@backingInt(pn)] += stage_.joined(pin, .diff, stack, stage);
            };
            if (row.exempt != null and last) try w.exempts.areaPerNetInto(gpa, net_of, count, &w.exempt_on) else try zeroed(gpa, &w.exempt_on, count);
            try zeroed(gpa, &w.collect, count);
            const on_net = w.on_net.items;
            for (w.here.items) |c| {
                const figures = &w.collected.items[c];
                try zeroed(gpa, &w.mine, count);
                const mine = w.mine.items;
                for (0..figures.len()) |f| {
                    const net = figures.net(f, net_of);
                    if (net == .none) continue;
                    mine[@backingInt(net)] += switch (w.read_measure.items[c]) {
                        .area => figures.area2.items[f],
                        .sidewall => |thickness| figures.perimeter2.items[f] * thickness,
                    };
                }
                // The pins' partial areas on this layer, and the ratio a
                // pin's gate has gathered inside its macro.
                const cut = isCut(stack, read[c]);
                const partial: AntennaKind, const car: AntennaKind = if (cut) .{ .partial_cut, .max_cut_car } else switch (w.read_measure.items[c]) {
                    .area => .{ .partial_metal, .max_area_car },
                    .sidewall => .{ .partial_metal_side, .max_side_area_car },
                };
                for (pins) |pin| {
                    const pn = net_of[@backingInt(pin.poly)];
                    if (pn != .none) mine[@backingInt(pn)] += @as(i128, @intFromFloat(@round(2.0 * stage_.pinValue(pin, partial, read[c]))));
                }
                if (cumulative) for (w.gate_pins.items, 0..) |pin, i| {
                    if (gate_net[n + i] != .none) ratio[n + i] += stage_.pinValue(pin, car, read[c]);
                };
                const par = row.par orelse {
                    for (w.collect.items, mine) |*sum, a| sum.* += a;
                    continue;
                };
                const factor = if (cut) par.cut_factor else 1.0;
                for (gate_net, 0..) |net, g| {
                    // A layer with nothing on the gate's net is no node of it.
                    if (net == .none or mine[@backingInt(net)] == 0) continue;
                    const at = @backingInt(net);
                    const diff: f64 = @floatFromInt(on_net[at]);
                    const reduce = if (par.reduce.len == 0) 1.0 else pwl(par.reduce, @divTrunc(on_net[at], 2));
                    const numerator = factor * @as(f64, @floatFromInt(mine[at])) * reduce - par.minus * diff;
                    const denominator = @as(f64, @floatFromInt(gate_area[at])) + par.plus * diff;
                    ratio[g] = @max(ratio[g] + numerator / denominator, 0.0);
                }
            }
            for (gate_net, 0..) |net, g| {
                if (net == .none) continue;
                const at = @backingInt(net);
                if (row.par == null) ratio[g] += @as(f64, @floatFromInt(w.collect.items[at])) / @as(f64, @floatFromInt(gate_area[at]));
                if (last) {
                    w.diode_area.items[g] = on_net[at];
                    w.exempted.items[g] = w.exempt_on.items[at] > 0;
                }
            }
        }

        // Gates on a net at the row's stage, grouped by their net at every
        // stage, the row's stage first.
        const top = stages.len - 1;
        const keys: Keys = .{ .key = w.key.items, .total = total, .top = top };
        for (0..total) |g| if (keys.at(g, top) != .none) try w.order.append(gpa, g);
        std.mem.sort(usize, w.order.items, keys, Keys.less);
        var examined: u64 = 0;
        var i: usize = 0;
        while (i < w.order.items.len) {
            var j = i + 1;
            while (j < w.order.items.len and keys.cmp(w.order.items[i], w.order.items[j]) == .eq) j += 1;
            const group = w.order.items[i..j];
            i = j;
            const first = group[0];
            if (w.exempted.items[first]) continue;
            // A pin's gate brings its own inside ratio: the group's worst.
            var worst = -std.math.floatMax(f64);
            for (group) |g| worst = @max(worst, ratio[g]);
            const judged: Judged = judge.of(worst, @divTrunc(w.diode_area.items[first], 2)) orelse continue;
            const limit = Measurement.ratio(judged.limit);
            examined += 1;
            const measured = Measurement.ratio(judged.value);
            if (!measured.violates(limit, .maximum)) continue;
            var poly: PolyId = @fromBackingInt(std.math.maxInt(u32));
            for (group) |g| {
                const p = if (g < n) w.gates.rows(g)[0] else w.gate_pins.items[g - n].poly;
                if (@backingInt(p) < @backingInt(poly)) poly = p;
            }
            try r.out.push(gpa, .{ .rule = row.rule, .layer = store.polyLayer(poly), .severity = row.severity, .at = geom.ops.centre(store.polyBbox(poly)), .measured = measured, .limit = limit, .shape_a = poly, .shape_b = report.no_shape });
            if (judged.fix) |fix| try r.out.setFix(gpa, r.out.len() - 1, Measurement.area(fix));
        }
        return examined;
    }
};

/// Groups by net at every stage, the row's stage first.
const Keys = struct {
    key: []const NetId,
    total: usize,
    top: usize,

    fn at(k: Keys, g: usize, s: usize) NetId {
        return k.key[s * k.total + g];
    }

    fn cmp(k: Keys, a: usize, b: usize) std.math.Order {
        var s = k.top + 1;
        while (s > 0) {
            s -= 1;
            const o = std.math.order(@backingInt(k.at(a, s)), @backingInt(k.at(b, s)));
            if (o != .eq) return o;
        }
        return .eq;
    }

    fn less(k: Keys, a: usize, b: usize) bool {
        return k.cmp(a, b) == .lt;
    }
};

/// Conductors before the cuts on them; otherwise in order.
const ConductorFirst = struct {
    read: []const LayerId,
    conductors: []const LayerId,

    fn less(c: ConductorFirst, a: usize, b: usize) bool {
        const ka = std.mem.indexOfScalar(LayerId, c.conductors, c.read[a]) == null;
        const kb = std.mem.indexOfScalar(LayerId, c.conductors, c.read[b]) == null;
        return !ka and kb;
    }
};

/// A piecewise-linear table at `area`: linear between the points either
/// side, a point's own value at it, the end value beyond either end.
/// Asserts a point.
pub fn pwl(points: []const AreaPoint, area: i128) f64 {
    std.debug.assert(points.len > 0);
    var after: usize = 0;
    while (after < points.len and points[after].area <= area) after += 1;
    if (after == 0) return points[0].value;
    const lo = points[after - 1];
    if (after == points.len) return lo.value;
    const hi = points[after];
    const t = @as(f64, @floatFromInt(area - lo.area)) / @as(f64, @floatFromInt(hi.area - lo.area));
    return lo.value + (hi.value - lo.value) * t;
}

/// `per` times `ratio`, rounded up to a whole square database unit.
pub fn areaTimes(per: DbuArea, ratio: f64) i128 {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(per)) * ratio));
}

/// One row. Each gate figure's ratio is summed over the row's etch stages:
/// with no `par` a stage adds the collecting area of its collectors on the
/// gate's net over the gate area on that net; with one, each collector
/// layer adds its own partial ratio, conductors before the cuts on them,
/// the running sum truncated at zero after each. `judge.of(ratio,
/// diode_area)` returns a `Judged`, or null for a gate the row does not
/// hold. Gates on one net at every stage are judged once, at their lowest
/// gate polygon's box centre. Returns the groups judged, or null (refused)
/// for a layer that will not validate.
pub fn antennaRow(r: Record, design: Design, pins: []const MacroPinAntenna, row: Row, stack: Stack, judge: anytype, scratch: *Scratch) Allocator.Error!?u64 {
    var w: Work = .{ .gpa = r.gpa };
    defer w.deinit();
    return w.run(r, design, pins, row, stack, judge, scratch);
}

// ---- private ----

fn isCut(stack: Stack, layer: LayerId) bool {
    return std.mem.indexOfScalar(LayerId, stack.via_cut, layer) != null;
}

fn zeroed(gpa: Allocator, list: *std.ArrayList(i128), count: usize) Allocator.Error!void {
    list.clearRetainingCapacity();
    try list.appendNTimes(gpa, 0, count);
}

/// Null sorts first, as Rust's `None < Some`.
fn lessStage(_: void, a: ?usize, b: ?usize) bool {
    if (a == null) return b != null;
    if (b == null) return false;
    return a.? < b.?;
}

fn dedupStages(items: []?usize) usize {
    var kept: usize = 0;
    for (items) |v| if (kept == 0 or !std.meta.eql(items[kept - 1], v)) {
        items[kept] = v;
        kept += 1;
    };
    return kept;
}

fn lessLayer(_: void, a: LayerId, b: LayerId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn dedupLayers(items: []LayerId) usize {
    var kept: usize = 0;
    for (items) |v| if (kept == 0 or items[kept - 1] != v) {
        items[kept] = v;
        kept += 1;
    };
    return kept;
}
