//! What an antenna row reads at one etch stage: the conductors standing and
//! the vias between them (`Stage`), the net of every store row of the
//! layers the row measures (`stageNetsInto`: a conductor's from the stage's
//! nets, any other layer attached to one conductor it overlaps), a layer
//! merged into figures with their doubled areas and perimeters (`Figures`),
//! and a macro pin's LEF values as a stage sees them. In: the store, the
//! etch stack, the finished nets. Out: per-row nets, figures. Ported from
//! crates/check/src/erc/rules/antenna.rs (`Stack::standing`,
//! `Stack::stage`, `MacroPinAntenna::joined`/`on`, `attach`, `Figures`,
//! `merged`, `stage_nets`).
//!
//! Contents:
//! - `pub fn standing(stack: Stack, layer: LayerId) ?usize`
//! - `pub const Stage = struct`, `deinit`, `fill(s, gpa: Allocator, stack: Stack, top: usize) Allocator.Error!void`, `connectivity(s) Connectivity`
//! - `pub fn joined(pin: MacroPinAntenna, kind: AntennaKind, stack: Stack, stage: ?usize) i128`, `pub fn pinValue(pin: MacroPinAntenna, kind: AntennaKind, layer: LayerId) f64`
//! - `pub const Figures = struct`, `deinit`, `len(f) usize`, `rows(f, figure: usize) []const PolyId`, `net(f, figure: usize, net_of: []const NetId) NetId`,
//!   `areaPerNetInto(f, gpa: Allocator, net_of: []const NetId, count: usize, out: *std.ArrayList(i128)) Allocator.Error!void`
//! - `pub fn mergedInto(gpa: Allocator, design: Design, layer: LayerId, scratch: *Scratch, out: *Figures) Allocator.Error!bool`
//! - `pub fn stageNetsInto(gpa: Allocator, design: Design, stack: Stack, stage: ?usize, layers: []const LayerId, staged: *NetTable, net_of: []NetId, scratch: *Scratch) Allocator.Error!?usize`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const Connectivity = @import("ingest").deck.Connectivity;
const AntennaKind = @import("ingest").lefdef.AntennaKind;
const rects = @import("../rects.zig");
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const Design = @import("head.zig").Design;
const Scratch = @import("scratch.zig").Scratch;
const antenna = @import("antenna_tables.zig");
const Stack = antenna.Stack;
const MacroPinAntenna = antenna.MacroPinAntenna;

/// The connectivity standing when conductor `top` (an index into
/// `Stack.conductors`) is etched: conductors up to it and the vias joining
/// two of them. Buffers reused stage after stage.
pub const Stage = struct {
    via_cut: std.ArrayList(LayerId) = .empty,
    via_connects: std.ArrayList([2]LayerId) = .empty,
    conductors: []const LayerId = &.{},
    intra_layer_touch: bool = false,

    pub fn deinit(s: *Stage, gpa: Allocator) void {
        s.via_cut.deinit(gpa);
        s.via_connects.deinit(gpa);
    }

    pub fn fill(s: *Stage, gpa: Allocator, stack: Stack, top: usize) Allocator.Error!void {
        s.conductors = stack.conductors[0 .. top + 1];
        s.intra_layer_touch = stack.intra_layer_touch;
        s.via_cut.clearRetainingCapacity();
        s.via_connects.clearRetainingCapacity();
        for (stack.via_cut, stack.via_connects) |cut, ends| {
            if (std.mem.indexOfScalar(LayerId, s.conductors, ends[0]) == null or std.mem.indexOfScalar(LayerId, s.conductors, ends[1]) == null) continue;
            try s.via_cut.append(gpa, cut);
            try s.via_connects.append(gpa, ends);
        }
    }

    pub fn connectivity(s: *const Stage) Connectivity {
        return .{ .conductors = s.conductors, .via_cut = s.via_cut.items, .via_connects = s.via_connects.items, .intra_layer_touch = s.intra_layer_touch };
    }
};

/// One layer merged: per figure twice its area (holes out) and twice its
/// perimeter (holes in), and the drawn store rows it covers, CSR.
pub const Figures = struct {
    area2: std.ArrayList(i128) = .empty,
    perimeter2: std.ArrayList(i128) = .empty,
    start: std.ArrayList(u32) = .empty,
    row: std.ArrayList(PolyId) = .empty,

    pub fn deinit(f: *Figures, gpa: Allocator) void {
        f.area2.deinit(gpa);
        f.perimeter2.deinit(gpa);
        f.start.deinit(gpa);
        f.row.deinit(gpa);
    }

    pub fn len(f: *const Figures) usize {
        return f.area2.items.len;
    }

    pub fn rows(f: *const Figures, figure: usize) []const PolyId {
        return f.row.items[f.start.items[figure]..f.start.items[figure + 1]];
    }

    /// The figure's net: the lowest net among the drawn rows it covers.
    pub fn net(f: *const Figures, figure: usize, net_of: []const NetId) NetId {
        var best: NetId = .none;
        for (f.rows(figure)) |r| best = @fromBackingInt(@min(@backingInt(best), @backingInt(net_of[@backingInt(r)])));
        return best;
    }

    /// The doubled area of the figures on each of `count` nets.
    pub fn areaPerNetInto(f: *const Figures, gpa: Allocator, net_of: []const NetId, count: usize, out: *std.ArrayList(i128)) Allocator.Error!void {
        out.clearRetainingCapacity();
        try out.appendNTimes(gpa, 0, count);
        for (0..f.len()) |k| {
            const n = f.net(k, net_of);
            if (n != .none) out.items[@backingInt(n)] += f.area2.items[k];
        }
    }
};

/// Which overlapped conductor a non-conductor row is on.
const Pick = struct {
    width: usize,
    over: []const bool,
    conductors: []const LayerId,
    named: []const LayerId,
    gates: []const LayerId,

    fn lies(p: Pick, hit: []const NetId, c: usize, gate_only: bool) bool {
        const joins = p.named.len == 0 or std.mem.indexOfScalar(LayerId, p.named, p.conductors[c]) != null;
        const gate = std.mem.indexOfScalar(LayerId, p.gates, p.conductors[c]) != null;
        return hit[c] != .none and joins and (!gate_only or gate);
    }

    /// The topmost candidate that is over no other candidate.
    fn top(p: Pick, hit: []const NetId, gate_only: bool) ?usize {
        var c = p.width;
        while (c > 0) {
            c -= 1;
            if (!p.lies(hit, c, gate_only)) continue;
            const routed = for (0..p.width) |d| {
                if (p.lies(hit, d, gate_only) and p.over[d * p.width + c]) break true;
            } else false;
            if (!routed) return c;
        }
        return null;
    }
};

/// The stage at which `layer` is etched, an index into `stack.conductors`:
/// a conductor's own place, a cut's lower conductor; null for any other.
pub fn standing(stack: Stack, layer: LayerId) ?usize {
    if (std.mem.indexOfScalar(LayerId, stack.conductors, layer)) |at| return at;
    var best: ?usize = null;
    for (stack.via_cut, stack.via_connects) |cut, ends| {
        if (cut != layer) continue;
        const a = std.mem.indexOfScalar(LayerId, stack.conductors, ends[0]) orelse continue;
        const b = std.mem.indexOfScalar(LayerId, stack.conductors, ends[1]) orelse continue;
        best = @max(best orelse 0, @min(a, b));
    }
    return best;
}

/// A gate or diffusion area joined to the pin when `stage` is etched,
/// doubled: the value of the highest stated layer standing, else the value
/// stated for every layer, else 0. With no stages, the value for every
/// layer, else the largest stated.
pub fn joined(pin: MacroPinAntenna, kind: AntennaKind, stack: Stack, stage: ?usize) i128 {
    var layered: ?struct { at: usize, v: f64 } = null;
    var every: ?f64 = null;
    for (pin.values) |pv| {
        if (pv.kind != kind) continue;
        const layer = pv.layer orelse {
            every = pv.value;
            continue;
        };
        const at = standing(stack, layer) orelse std.math.maxInt(usize);
        const fits = if (stage) |top| at <= top else true;
        const higher = if (layered) |l| (if (stage != null) at >= l.at else pv.value > l.v) else true;
        if (fits and higher) layered = .{ .at = at, .v = pv.value };
    }
    const value = if (layered) |l| l.v else every orelse 0.0;
    return @intFromFloat(@round(2.0 * value));
}

/// A value stated for `layer`, else for every layer, else 0.
pub fn pinValue(pin: MacroPinAntenna, kind: AntennaKind, layer: LayerId) f64 {
    for (pin.values) |pv| if (pv.kind == kind and pv.layer != null and pv.layer.? == layer) return pv.value;
    for (pin.values) |pv| if (pv.kind == kind and pv.layer == null) return pv.value;
    return 0.0;
}

/// `layer` merged into `out`; false when it will not validate rectilinear.
pub fn mergedInto(gpa: Allocator, design: Design, layer: LayerId, scratch: *Scratch, out: *Figures) Allocator.Error!bool {
    out.area2.clearRetainingCapacity();
    out.perimeter2.clearRetainingCapacity();
    out.row.clearRetainingCapacity();
    out.start.clearRetainingCapacity();
    try out.start.append(gpa, 0);
    if (try geom.view.validateLayer(gpa, design.store, layer, .rectilinear, &scratch.layer_a) != null) return false;
    var drawn: rects.LayerRects = .{};
    defer drawn.deinit(gpa);
    try drawn.build(gpa, design.store, layer, &scratch.layer_a);
    const nothing: geom.ValidatedLayer = .empty;
    try geom.boolean.unionInto(gpa, &scratch.layer_a, &nothing, &scratch.layer_b);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try drawn.rowLabelsInto(gpa, &labels);
    var under: rects.SortedRects = .{};
    defer under.deinit(gpa);
    try under.build(gpa, drawn.rects.items, labels.items);
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    try geom.rects.decomposeInto(gpa, &scratch.layer_b, &boxes, &start);
    var covered: std.ArrayList(u32) = .empty;
    defer covered.deinit(gpa);
    for (start.items[0 .. start.items.len - 1], start.items[1..], 0..) |from, to, idx| {
        const mine = boxes.items[from..to];
        var area: i128 = 0;
        for (mine) |b| area += 2 * b.area();
        try out.area2.append(gpa, area);
        const poly = scratch.layer_b.get(@intCast(idx));
        var perimeter: i128 = 0;
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            for (0..ring.xs.len) |i| {
                const j = (i + 1) % ring.xs.len;
                perimeter += @abs(ring.xs[j] - ring.xs[i]) + @abs(ring.ys[j] - ring.ys[i]);
            }
        }
        try out.perimeter2.append(gpa, 2 * perimeter);
        covered.clearRetainingCapacity();
        for (mine) |b| {
            var it = under.overlapping(b);
            while (it.next()) |hit| try covered.append(gpa, hit.label);
        }
        std.mem.sortUnstable(u32, covered.items, {}, std.sort.asc(u32));
        var last: ?u32 = null;
        for (covered.items) |c| if (last == null or last.? != c) {
            try out.row.append(gpa, @fromBackingInt(c));
            last = c;
        };
        try out.start.append(gpa, @intCast(out.row.items.len));
    }
    return true;
}

/// Puts every store row of `layers` on its net as the stack stands at
/// `stage` (null: the finished nets), cutting the stage's nets into
/// `staged`: a conductor's rows read the stage's nets, any other layer is
/// attached. The stage's net count, or null when a layer will not validate.
pub fn stageNetsInto(gpa: Allocator, design: Design, stack: Stack, stage: ?usize, layers: []const LayerId, staged: *NetTable, net_of: []NetId, scratch: *Scratch) Allocator.Error!?usize {
    const store = design.store;
    var st: Stage = .{};
    defer st.deinit(gpa);
    const nets: *const NetTable = if (stage) |top| blk: {
        try st.fill(gpa, stack, top);
        const c = st.connectivity();
        try net_.extractNetsInto(gpa, store, &c, staged);
        break :blk staged;
    } else design.nets;
    if (nets.netCount() == 0) {
        for (layers) |layer| {
            const r = store.polysOnLayer(layer);
            @memset(net_of[r.start..r.end], .none);
        }
        return 0;
    }
    // Conductors: the stage's, or (finished nets) every layer carrying a net.
    var found: std.ArrayList(LayerId) = .empty;
    defer found.deinit(gpa);
    const conductors: []const LayerId = if (stage != null) st.conductors else blk: {
        for (0..store.layerCount()) |l| {
            const r = store.polysOnLayer(@fromBackingInt(@as(u16, @intCast(l))));
            for (r.start..r.end) |row| if (nets.netOf(@fromBackingInt(@as(u32, @intCast(row)))) != .none) {
                try found.append(gpa, @fromBackingInt(@as(u16, @intCast(l))));
                break;
            };
        }
        break :blk found.items;
    };
    for (layers) |layer| {
        if (std.mem.indexOfScalar(LayerId, conductors, layer) != null) {
            const r = store.polysOnLayer(layer);
            for (r.start..r.end) |row| net_of[row] = nets.netOf(@fromBackingInt(@as(u32, @intCast(row))));
        } else if (!try attach(gpa, design, layer, stack, conductors, nets, net_of, scratch)) return null;
    }
    return nets.netCount();
}

// ---- private ----

/// The net of every store row on `layer`, a non-conductor: that of the one
/// conductor among `conductors` (bottom-up) it overlaps with positive area
/// (touching alone does not join), the lowest net among that conductor's
/// shapes there. A cut joins only conductors its `connect via` rows name; a
/// MOS gate terminal layer is taken first; one another overlapped conductor
/// reaches upward through cuts is routed over it and passed over; of the
/// rest the topmost wins. False when a layer will not validate.
fn attach(gpa: Allocator, design: Design, layer: LayerId, stack: Stack, conductors: []const LayerId, nets: *const NetTable, net_of: []NetId, scratch: *Scratch) Allocator.Error!bool {
    const store = design.store;
    const rows = store.polysOnLayer(layer);
    if (rows.len() == 0) return true;
    if (try geom.view.validateLayer(gpa, store, layer, .rectilinear, &scratch.layer_a) != null) return false;
    var mine: rects.LayerRects = .{};
    defer mine.deinit(gpa);
    try mine.build(gpa, store, layer, &scratch.layer_a);
    // `hit[poly * width + c]`: the lowest net of `conductors[c]` under `poly`.
    const width = conductors.len;
    const hit = try gpa.alloc(NetId, mine.len() * width);
    defer gpa.free(hit);
    @memset(hit, .none);
    var theirs: rects.LayerRects = .{};
    defer theirs.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var under: rects.SortedRects = .{};
    defer under.deinit(gpa);
    for (conductors, 0..) |conductor, c| {
        if (try geom.view.validateLayer(gpa, store, conductor, .rectilinear, &scratch.layer_b) != null) return false;
        try theirs.build(gpa, store, conductor, &scratch.layer_b);
        try theirs.rowLabelsInto(gpa, &labels);
        try under.build(gpa, theirs.rects.items, labels.items);
        for (0..mine.len()) |poly| {
            const slot = &hit[poly * width + c];
            for (mine.of(@intCast(poly))) |r| {
                var it = under.overlapping(r);
                while (it.next()) |h| slot.* = @fromBackingInt(@min(@backingInt(slot.*), @backingInt(nets.netOf(@fromBackingInt(h.label)))));
            }
        }
    }
    // `over[a * width + b]`: `conductors[b]` is above `conductors[a]`,
    // reached from it through cuts taken bottom-up.
    const over = try gpa.alloc(bool, width * width);
    defer gpa.free(over);
    @memset(over, false);
    for (stack.via_connects) |ends| {
        const a = std.mem.indexOfScalar(LayerId, conductors, ends[0]) orelse continue;
        const b = std.mem.indexOfScalar(LayerId, conductors, ends[1]) orelse continue;
        const pa = std.mem.indexOfScalar(LayerId, stack.conductors, conductors[a]) orelse continue;
        const pb = std.mem.indexOfScalar(LayerId, stack.conductors, conductors[b]) orelse continue;
        const lo, const hi = if (pa < pb) .{ a, b } else .{ b, a };
        over[lo * width + hi] = over[lo * width + hi] or pa != pb;
    }
    for (0..width) |via| for (0..width) |a| if (over[a * width + via]) {
        for (0..width) |b| over[a * width + b] = over[a * width + b] or over[via * width + b];
    };
    var named: std.ArrayList(LayerId) = .empty;
    defer named.deinit(gpa);
    for (stack.via_cut, stack.via_connects) |cut, ends| if (cut == layer) try named.appendSlice(gpa, &ends);
    const pick: Pick = .{ .width = width, .over = over, .conductors = conductors, .named = named.items, .gates = stack.gates };
    for (mine.poly_of_row.items, 0..) |poly, offset| {
        const row_hit = hit[poly * width ..][0..width];
        const on = pick.top(row_hit, true) orelse pick.top(row_hit, false);
        net_of[rows.start + offset] = if (on) |c| row_hit[c] else .none;
    }
    return true;
}

test "a stage holds the conductors up to its etch and the vias between them" {
    // Oracle: the etch-step model docs/src/reference/erc/antenna.md (ERC-A1)
    // states for `antenna` (each term counts what is connected when that layer
    // is etched), by hand: at met1 the conductors through met1 and the licon
    // and mcon rows exist, via1 does not, and a cut stands on its lower
    // conductor.
    const gpa = std.testing.allocator;
    const l = struct {
        fn id(i: u16) LayerId {
            return @fromBackingInt(i);
        }
    }.id;
    const diff = l(0);
    const poly = l(1);
    const li = l(2);
    const met1 = l(3);
    const met2 = l(4);
    const licon = l(5);
    const mcon = l(6);
    const via1 = l(7);
    const stack: Stack = .{
        .conductors = &.{ diff, poly, li, met1, met2 },
        .via_cut = &.{ licon, licon, mcon, via1 },
        .via_connects = &.{ .{ diff, li }, .{ poly, li }, .{ li, met1 }, .{ met1, met2 } },
        .intra_layer_touch = true,
    };
    var s: Stage = .{};
    defer s.deinit(gpa);
    try s.fill(gpa, stack, standing(stack, met1).?);
    try std.testing.expectEqualSlices(LayerId, &.{ diff, poly, li, met1 }, s.conductors);
    try std.testing.expectEqualSlices(LayerId, &.{ licon, licon, mcon }, s.via_cut.items);
    try std.testing.expectEqual(standing(stack, met1), standing(stack, via1));
    try std.testing.expectEqual(standing(stack, poly), standing(stack, licon));
    try s.fill(gpa, stack, standing(stack, poly).?);
    try std.testing.expectEqualSlices(LayerId, &.{ diff, poly }, s.conductors);
    try std.testing.expectEqual(@as(usize, 0), s.via_cut.items.len);
    try std.testing.expectEqual(@as(?usize, null), standing(.{}, met1));
}
