//! Device recognition and terminal binding: one polygon on a recogniser's
//! marker layer is exactly one device, its terminals bound to the nets of
//! the shapes under it. In: a `GeometryStore`, its `NetTable`, and the
//! deck's `DeviceRecognition`. Out: a `DeviceTable`, rows ascending by
//! marker polygon, with the markers no recogniser could bind. Ported from
//! crates/check/src/topology/device.rs (the conduction guard is
//! channel.zig).
//!
//! Contents:
//! - `pub const DeviceId = enum(u32)`, `pub const TerminalRole = union(enum)`, `pub fn roleAt(kind: DeviceKind, position: u8) TerminalRole`
//! - `pub const DeviceParam = enum(u8)`, `pub const DeviceMeasure = union(enum)`
//! - `pub const Terminals = struct { nets: []const NetId, roles: []const TerminalRole }`,
//!   `pub const Params = struct { names: []const DeviceParam, measures: []const DeviceMeasure }`
//! - `pub const DeviceTable = struct`, `deinit`, `len(t: *const DeviceTable) u32`,
//!   `terminalsOf(t: *const DeviceTable, device: DeviceId) Terminals`,
//!   `paramsOf(t: *const DeviceTable, device: DeviceId) Params`,
//!   `devicesOn(t: *const DeviceTable, net: NetId) []const DeviceId`
//! - `pub fn recogniseInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, recognition: *const DeviceRecognition, out: *DeviceTable) Allocator.Error!void`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const SpatialIndex = geom.index.SpatialIndex;
const Pair = geom.index.Pair;
const deck = @import("ingest").deck;
const DeviceKind = deck.DeviceKind;
const DeviceRecognition = deck.DeviceRecognition;
const DeviceValue = deck.DeviceValue;
const Holes = @import("../rects.zig").Holes;
const net = @import("net.zig");
const NetId = net.NetId;
const NetTable = net.NetTable;

/// One recognised device: its row, ascending by marker polygon.
pub const DeviceId = enum(u32) { _ };

/// Which terminal a net attaches to, by family and position (the deck's
/// `terminals [..]` order): MOS gate, source, drain, bulk; BJT base,
/// emitter, collector; every other position, and every passive's, `pin`.
/// LVS treats source and drain as one, and a resistor's or inductor's two
/// ends as one.
pub const TerminalRole = union(enum) {
    gate,
    source,
    drain,
    /// Dropped from the reference when the layout extracts none.
    bulk,
    base,
    /// Never interchangeable with `collector`.
    emitter,
    collector,
    /// A passive's terminal by position.
    pin: u8,
};

/// A measured parameter, and the SPICE name LVS compares it under.
pub const DeviceParam = enum(u8) {
    /// `w`: the marker box's extent across the channel or body.
    width,
    /// `l`: the extent along it, the axis the first source/drain (a
    /// resistor's first end) sits off the marker's centre on.
    length,
    /// `area`: the marker polygon's, holes out.
    area,
    /// `perim`: every ring's length, a diagonal edge rounded down.
    perimeter,
    /// `nf`: 1 per MOS; a parallel merge sums it.
    fingers,
    /// `as`: the source polygon's area shared evenly by every MOS it serves.
    source_area,
    /// `ad`.
    drain_area,
    /// `ps`.
    source_perimeter,
    /// `pd`.
    drain_perimeter,
    /// `ae`: a bipolar's emitter polygon's area.
    emitter_area,
    /// `pe`.
    emitter_perimeter,
};

/// A measurement, exact, in layout units; tolerance is the comparator's.
pub const DeviceMeasure = union(enum) {
    length: Dbu,
    area: DbuArea,
    count: u32,
    /// An area shared evenly by `ways` devices: each has that fraction.
    area_share: struct { area: DbuArea, ways: u32 },
    length_share: struct { length: Dbu, ways: u32 },
};

pub const Terminals = struct { nets: []const NetId, roles: []const TerminalRole };

pub const Params = struct { names: []const DeviceParam, measures: []const DeviceMeasure };

/// Every device recognised. Row `k` is `DeviceId` `k`; every terminal is on
/// a real net (a marker that cannot bind every terminal is no device, and
/// is listed in `refused_*`). Invariant: `terminal_start` and `param_start`
/// are CSR, one longer than `kind`; `net_start` CSR over `net_device`.
pub const DeviceTable = struct {
    kind: std.ArrayList(DeviceKind) = .empty,
    marker: std.ArrayList(PolyId) = .empty,
    model: std.ArrayList(StrId) = .empty,
    terminal_start: std.ArrayList(u32) = .empty,
    terminal_net: std.ArrayList(NetId) = .empty,
    terminal_role: std.ArrayList(TerminalRole) = .empty,
    param_start: std.ArrayList(u32) = .empty,
    param_name: std.ArrayList(DeviceParam) = .empty,
    param_measure: std.ArrayList(DeviceMeasure) = .empty,
    /// The recogniser's stated coefficients, from which LVS computes `r` and
    /// `c`; the default where the deck's table is short.
    value: std.ArrayList(DeviceValue) = .empty,
    /// Markers that are no device, ascending: each with the terminals the
    /// first recogniser naming its layer bound, of how many it lists.
    refused_marker: std.ArrayList(PolyId) = .empty,
    refused_bound: std.ArrayList(u32) = .empty,
    refused_listed: std.ArrayList(u32) = .empty,
    net_start: std.ArrayList(u32) = .empty,
    net_device: std.ArrayList(DeviceId) = .empty,

    pub fn deinit(t: *DeviceTable, gpa: Allocator) void {
        inline for (@typeInfo(DeviceTable).@"struct".field_names) |name| @field(t, name).deinit(gpa);
    }

    pub fn len(t: *const DeviceTable) u32 {
        return @intCast(t.kind.items.len);
    }

    /// One device's terminals in the recogniser's layer order.
    pub fn terminalsOf(t: *const DeviceTable, device: DeviceId) Terminals {
        const d = @backingInt(device);
        const from = t.terminal_start.items[d];
        const to = t.terminal_start.items[d + 1];
        return .{ .nets = t.terminal_net.items[from..to], .roles = t.terminal_role.items[from..to] };
    }

    pub fn paramsOf(t: *const DeviceTable, device: DeviceId) Params {
        const d = @backingInt(device);
        const from = t.param_start.items[d];
        const to = t.param_start.items[d + 1];
        return .{ .names = t.param_name.items[from..to], .measures = t.param_measure.items[from..to] };
    }

    /// The devices attached to a net, ascending, each once; empty for none.
    pub fn devicesOn(t: *const DeviceTable, n: NetId) []const DeviceId {
        if (n == .none) return &.{};
        const i = @backingInt(n);
        return t.net_device.items[t.net_start.items[i]..t.net_start.items[i + 1]];
    }

    // ---- private ----

    fn clear(t: *DeviceTable, gpa: Allocator) Allocator.Error!void {
        inline for (@typeInfo(DeviceTable).@"struct".field_names) |name| @field(t, name).clearRetainingCapacity();
        try t.terminal_start.append(gpa, 0);
        try t.param_start.append(gpa, 0);
    }
};

/// No polygon: a terminal drawn in pieces, or not measured.
const no_poly: PolyId = @fromBackingInt(std.math.maxInt(u32));

/// Which axis a MOS channel's or a resistor body's current flows along.
const Axis = enum(u8) { unknown, x, y };

/// A bound marker: its polygon, recogniser row, offset into `bound`, axis.
const Match = struct {
    marker: PolyId,
    row: u32,
    at: u32,
    axis: Axis,

    fn lessThan(_: void, a: Match, b: Match) bool {
        return @backingInt(a.marker) < @backingInt(b.marker);
    }
};

/// One terminal layer's index, shared by every recogniser naming it, and
/// that layer's polygons touching another of it (null until a recogniser
/// measures a terminal there).
const TerminalIndex = struct { layer: LayerId, index: SpatialIndex, pieced: ?std.ArrayList(PolyId) };

/// `recogniseInto`'s working tables, dead on return.
const Work = struct {
    role: std.ArrayList(TerminalRole) = .empty,
    indexes: std.ArrayList(TerminalIndex) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    exact: std.ArrayList(Pair) = .empty,
    bind: std.ArrayList(NetId) = .empty,
    bind_poly: std.ArrayList(PolyId) = .empty,
    sd_axis: std.ArrayList(Axis) = .empty,
    positions: std.ArrayList(usize) = .empty,
    group: std.ArrayList(usize) = .empty,
    shapes: std.ArrayList(PolyId) = .empty,
    alone: std.ArrayList(bool) = .empty,
    distinct: std.ArrayList(NetId) = .empty,
    matched: std.ArrayList(Match) = .empty,
    bound: std.ArrayList(NetId) = .empty,
    bound_poly: std.ArrayList(PolyId) = .empty,
    served: std.ArrayList(PolyId) = .empty,
    /// `(net, device)` per terminal, deduplicated before the index.
    attach: std.ArrayList([2]u32) = .empty,

    fn deinit(w: *Work, gpa: Allocator) void {
        for (w.indexes.items) |*t| {
            t.index.deinit(gpa);
            if (t.pieced) |*p| p.deinit(gpa);
        }
        inline for (@typeInfo(Work).@"struct".field_names) |name| @field(w, name).deinit(gpa);
    }
};

/// The role of terminal `position` in family `kind`.
pub fn roleAt(kind: DeviceKind, position: u8) TerminalRole {
    const named: []const TerminalRole = switch (kind) {
        .mos => &.{ .gate, .source, .drain, .bulk },
        .bjt => &.{ .base, .emitter, .collector },
        .resistor, .capacitor, .diode, .inductor, .cell => &.{},
    };
    return if (position < named.len) named[position] else .{ .pin = position };
}

/// Recognises every device the deck describes into `out` (cleared and
/// refilled). Each polygon on a marker layer is a candidate (a hole row is
/// part of its polygon, never a marker). A terminal polygon is under the
/// marker when they share a point. Polygons under it that touch are one
/// shape; each position needs a shape of its own, positions naming one
/// layer taking its shapes in ascending row order. More shapes than
/// positions are terminals drawn apart when their nets are exactly as many
/// as the positions (one net each, in order of each net's lowest shape) or
/// all one net; any other surplus refuses the marker. Of two recognisers
/// binding one marker the earlier row wins; a marker none binds is listed
/// as refused. `nets` must come from `store`. Asserts fewer than 256
/// terminals a recogniser.
pub fn recogniseInto(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, recognition: *const DeviceRecognition, out: *DeviceTable) Allocator.Error!void {
    try out.clear(gpa);
    var w: Work = .{};
    defer w.deinit(gpa);
    // Roles, indexed by the recogniser's terminal offsets.
    for (0..recognition.kind.len) |row| {
        const width = terminalsOfRow(recognition, row).len;
        assert(width < 256);
        for (0..width) |position| try w.role.append(gpa, roleAt(recognition.kind[row], @intCast(position)));
    }
    for (0..recognition.kind.len) |row| try bindRow(gpa, store, nets, recognition, row, &w, out);

    // Stable, so of two recognisers matching one marker the earlier wins.
    std.mem.sort(Match, w.matched.items, {}, Match.lessThan);
    dedupMatches(&w.matched);
    try settleRefused(gpa, out, w.matched.items);

    // Every source or drain polygon once per MOS it serves, sorted, so a
    // shared diffusion's count is the length of its run.
    for (w.matched.items) |m| {
        if (recognition.kind[m.row] != .mos) continue;
        const from = recognition.terminal_start[m.row];
        for (from..recognition.terminal_start[m.row + 1]) |slot| switch (w.role.items[slot]) {
            .source, .drain => {
                const poly = w.bound_poly.items[m.at + slot - from];
                if (poly != no_poly) try w.served.append(gpa, poly);
            },
            .gate, .bulk, .base, .emitter, .collector, .pin => {},
        };
    }
    std.mem.sortUnstable(PolyId, w.served.items, {}, lessPoly);
    for (w.matched.items, 0..) |m, device| try emitDevice(gpa, store, nets, recognition, &w, m, @intCast(device), out);
    try buildReverseIndex(gpa, nets, w.attach.items, out);
}

// ---- private ----

fn terminalsOfRow(recognition: *const DeviceRecognition, row: usize) []const LayerId {
    return recognition.terminal[recognition.terminal_start[row]..recognition.terminal_start[row + 1]];
}

fn lessPoly(_: void, a: PolyId, b: PolyId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn containsPoly(sorted: []const PolyId, p: PolyId) bool {
    return std.sort.binarySearch(PolyId, sorted, p, struct {
        fn order(want: PolyId, item: PolyId) std.math.Order {
            return std.math.order(@backingInt(want), @backingInt(item));
        }
    }.order) != null;
}

/// The axis along which a source/drain polygon's box centre sits off the
/// marker's; x wins a diagonal tie. Doubled centres, so nothing rounds.
fn channelAxis(store: *const GeometryStore, marker: PolyId, terminal: PolyId) Axis {
    const m = store.polyBbox(marker);
    const t = store.polyBbox(terminal);
    const dx = @abs((t.xlo + t.xhi) - (m.xlo + m.xhi));
    const dy = @abs((t.ylo + t.yhi) - (m.ylo + m.yhi));
    return if (dx >= dy) .x else .y;
}

/// Binds every marker of one recogniser row, appending the bound ones to
/// `w.matched` and the rest to `out`'s refused columns.
fn bindRow(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, recognition: *const DeviceRecognition, row: usize, w: *Work, out: *DeviceTable) Allocator.Error!void {
    const terminals = terminalsOfRow(recognition, row);
    const width = terminals.len;
    const kind = recognition.kind[row];
    const markers = store.polysOnLayer(recognition.marker[row]);
    if (markers.len() == 0) return;
    try w.bind.resize(gpa, markers.len() * width);
    @memset(w.bind.items, .none);
    try w.bind_poly.resize(gpa, markers.len() * width);
    @memset(w.bind_poly.items, no_poly);
    try w.sd_axis.resize(gpa, markers.len());
    @memset(w.sd_axis.items, .unknown);
    for (terminals, 0..) |layer, k| {
        // The first position naming a layer fills them all.
        if (std.mem.indexOfScalar(LayerId, terminals[0..k], layer) != null) continue;
        w.positions.clearRetainingCapacity();
        for (terminals, 0..) |named, position| if (named == layer) try w.positions.append(gpa, position);
        var votes_axis = false;
        var measured = false;
        for (w.positions.items) |position| switch (roleAt(kind, @intCast(position))) {
            .source, .drain => {
                votes_axis = votes_axis or kind == .mos;
                measured = measured or kind == .mos;
            },
            .emitter => measured = measured or kind == .bjt,
            .gate, .bulk, .base, .collector, .pin => {},
        };
        votes_axis = votes_axis or kind == .resistor;
        const ti = try terminalIndex(gpa, store, nets, layer, measured, w);
        try geom.index.crossLayerPairsInto(gpa, store, recognition.marker[row], &ti.index, 0, &w.pairs);
        // Box-only hits must not bind: a spurious low-id pair would win.
        try net.retainIntersectingInto(gpa, store, &nets.holes, w.pairs.items, &w.exact);
        const pieced: []const PolyId = if (ti.pieced) |p| p.items else &.{};
        // `exact` ascends by `(marker, terminal)`: one run per marker.
        var from: usize = 0;
        while (from < w.exact.items.len) {
            const marker = w.exact.items[from].a;
            var to = from;
            while (to < w.exact.items.len and w.exact.items[to].a == marker) to += 1;
            const run = w.exact.items[from..to];
            from = to;
            const offset = @backingInt(marker) - markers.start;
            if (votes_axis and w.sd_axis.items[offset] == .unknown) w.sd_axis.items[offset] = channelAxis(store, marker, run[0].b);
            try groupShapes(gpa, store, nets, run, w);
            try fillPositions(gpa, nets, pieced, w, w.bind.items[offset * width ..][0..width], w.bind_poly.items[offset * width ..][0..width]);
        }
    }
    for (0..markers.len()) |offset| {
        const marker: PolyId = @fromBackingInt(@intCast(markers.start + offset));
        const slots = w.bind.items[offset * width ..][0..width];
        // A hole binds nothing, being no material, and is its outer's.
        if (nets.holes.isHole(marker)) continue;
        if (std.mem.indexOfScalar(NetId, slots, .none) != null) {
            var filled: u32 = 0;
            for (slots) |s| filled += @intFromBool(s != .none);
            try out.refused_marker.append(gpa, marker);
            try out.refused_bound.append(gpa, filled);
            try out.refused_listed.append(gpa, @intCast(width));
            continue;
        }
        try w.matched.append(gpa, .{ .marker = marker, .row = @intCast(row), .at = @intCast(w.bound.items.len), .axis = w.sd_axis.items[offset] });
        try w.bound.appendSlice(gpa, slots);
        try w.bound_poly.appendSlice(gpa, w.bind_poly.items[offset * width ..][0..width]);
    }
}

/// `layer`'s shared index, built on first use, with its touching polygons
/// once a recogniser measures a terminal there.
fn terminalIndex(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, layer: LayerId, measured: bool, w: *Work) Allocator.Error!*TerminalIndex {
    const ti = for (w.indexes.items) |*t| {
        if (t.layer == layer) break t;
    } else blk: {
        try w.indexes.append(gpa, .{ .layer = layer, .index = .empty, .pieced = null });
        const t = &w.indexes.items[w.indexes.items.len - 1];
        try t.index.build(gpa, store, layer);
        break :blk t;
    };
    if (measured and ti.pieced == null) {
        // A piece is not the terminal (testing-plan F16).
        try geom.index.candidatePairsInto(gpa, store, &ti.index, 0, &w.pairs);
        try net.retainIntersectingInto(gpa, store, &nets.holes, w.pairs.items, &w.exact);
        var touched: std.ArrayList(PolyId) = .empty;
        errdefer touched.deinit(gpa);
        for (w.exact.items) |p| try touched.appendSlice(gpa, &.{ p.a, p.b });
        std.mem.sortUnstable(PolyId, touched.items, {}, lessPoly);
        var kept: usize = 0;
        for (touched.items) |p| {
            if (kept > 0 and touched.items[kept - 1] == p) continue;
            touched.items[kept] = p;
            kept += 1;
        }
        touched.shrinkRetainingCapacity(kept);
        ti.pieced = touched;
    }
    return ti;
}

/// One marker's polygons on one layer grouped into shapes (touching or
/// overlapping polygons are one, named by the lowest), into `w.shapes`, with
/// whether each is a lone polygon into `w.alone`.
/// ponytail: pairwise over one marker's polygons on one layer, a handful in
/// practice; sweep them if a marker covers hundreds.
fn groupShapes(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, run: []const Pair, w: *Work) Allocator.Error!void {
    try w.group.resize(gpa, run.len);
    for (w.group.items, 0..) |*g, i| g.* = i;
    for (0..run.len) |i| for (0..i) |j| {
        if (!try net.polysIntersect(gpa, store, &nets.holes, run[i].b, run[j].b)) continue;
        const a = root(w.group.items, i);
        const b = root(w.group.items, j);
        w.group.items[@max(a, b)] = @min(a, b);
    };
    w.shapes.clearRetainingCapacity();
    w.alone.clearRetainingCapacity();
    for (0..run.len) |i| {
        if (root(w.group.items, i) != i) continue;
        try w.shapes.append(gpa, run[i].b);
        var lone = true;
        for (0..run.len) |j| lone = lone and (j == i or root(w.group.items, j) != i);
        try w.alone.append(gpa, lone);
    }
}

/// Fills one marker's positions on one layer from `w.shapes`.
fn fillPositions(gpa: Allocator, nets: *const NetTable, pieced: []const PolyId, w: *Work, slots: []NetId, polys: []PolyId) Allocator.Error!void {
    const positions = w.positions.items;
    if (w.shapes.items.len <= positions.len) {
        // The r-th shape fills the r-th position; too few leave one with no
        // shape of its own, which refuses the marker.
        for (positions[0..w.shapes.items.len], w.shapes.items, w.alone.items) |position, terminal, lone| {
            slots[position] = nets.netOf(terminal);
            polys[position] = if (lone and !containsPoly(pieced, terminal)) terminal else no_poly;
        }
        return;
    }
    // More shapes than positions: their nets, each at its lowest shape,
    // decide whether the surplus is terminals drawn apart on one net.
    w.distinct.clearRetainingCapacity();
    for (w.shapes.items) |terminal| {
        const n = nets.netOf(terminal);
        if (std.mem.indexOfScalar(NetId, w.distinct.items, n) == null) try w.distinct.append(gpa, n);
    }
    const unique = w.distinct.items.len;
    for (positions, 0..) |position, k| {
        // Two gates under one implant: refused.
        slots[position] = if (unique == positions.len) w.distinct.items[k] else if (unique == 1) w.distinct.items[0] else .none;
    }
}

/// The group of entry `at` in a parent forest whose roots are the lowest.
fn root(group: []const usize, at: usize) usize {
    var i = at;
    while (group[i] != i) i = group[i];
    return i;
}

fn dedupMatches(matched: *std.ArrayList(Match)) void {
    var kept: usize = 0;
    for (matched.items) |m| {
        if (kept > 0 and matched.items[kept - 1].marker == m.marker) continue;
        matched.items[kept] = m;
        kept += 1;
    }
    matched.shrinkRetainingCapacity(kept);
}

/// Refused markers ascending, each once as its earliest recogniser refused
/// it, and none another recogniser bound.
fn settleRefused(gpa: Allocator, out: *DeviceTable, matched: []const Match) Allocator.Error!void {
    const n = out.refused_marker.items.len;
    const perm = try gpa.alloc(u32, n);
    defer gpa.free(perm);
    for (perm, 0..) |*p, i| p.* = @intCast(i);
    std.mem.sort(u32, perm, out.refused_marker.items, struct {
        fn less(m: []const PolyId, a: u32, b: u32) bool {
            return @backingInt(m[a]) < @backingInt(m[b]);
        }
    }.less);
    const marker = try gpa.dupe(PolyId, out.refused_marker.items);
    defer gpa.free(marker);
    const bound = try gpa.dupe(u32, out.refused_bound.items);
    defer gpa.free(bound);
    const listed = try gpa.dupe(u32, out.refused_listed.items);
    defer gpa.free(listed);
    out.refused_marker.clearRetainingCapacity();
    out.refused_bound.clearRetainingCapacity();
    out.refused_listed.clearRetainingCapacity();
    for (perm) |p| {
        const m = marker[p];
        const last = out.refused_marker.items;
        if (last.len > 0 and last[last.len - 1] == m) continue;
        const taken = for (matched) |x| {
            if (x.marker == m) break true;
        } else false;
        if (taken) continue;
        out.refused_marker.appendAssumeCapacity(m);
        out.refused_bound.appendAssumeCapacity(bound[p]);
        out.refused_listed.appendAssumeCapacity(listed[p]);
    }
}

/// Appends one matched device's row: kind, marker, model, terminals, and
/// its measured parameters.
fn emitDevice(gpa: Allocator, store: *const GeometryStore, nets: *const NetTable, recognition: *const DeviceRecognition, w: *Work, m: Match, device: u32, out: *DeviceTable) Allocator.Error!void {
    const span_from = recognition.terminal_start[m.row];
    const span_len = recognition.terminal_start[m.row + 1] - span_from;
    const nets_of = w.bound.items[m.at..][0..span_len];
    const kind = recognition.kind[m.row];
    try out.kind.append(gpa, kind);
    try out.marker.append(gpa, m.marker);
    try out.model.append(gpa, recognition.model[m.row]);
    try out.terminal_net.appendSlice(gpa, nets_of);
    try out.terminal_role.appendSlice(gpa, w.role.items[span_from..][0..span_len]);
    try out.terminal_start.append(gpa, @intCast(out.terminal_net.items.len));
    // W and L from the marker's box: L along the channel or body, W across.
    // ponytail: a bent resistor reads its bounding box; KLayout's W from the
    // edges shared with its terminals, L = area / W, would fit it.
    if ((kind == .mos or kind == .resistor) and m.axis != .unknown) {
        const b = store.polyBbox(m.marker);
        const ex = b.xhi - b.xlo;
        const ey = b.yhi - b.ylo;
        const along_x = m.axis == .x;
        try pushParam(gpa, out, .width, .{ .length = if (along_x) ey else ex });
        try pushParam(gpa, out, .length, .{ .length = if (along_x) ex else ey });
    }
    if (kind == .mos) try pushParam(gpa, out, .fingers, .{ .count = 1 });
    const own = areaAndPerimeter(store, &nets.holes, m.marker);
    try pushParam(gpa, out, .area, .{ .area = own.area });
    try pushParam(gpa, out, .perimeter, .{ .length = own.perimeter });
    // A terminal's own area and perimeter, where it is one polygon (F16).
    for (w.role.items[span_from..][0..span_len], 0..) |role, slot| {
        const names: [2]DeviceParam = switch (role) {
            .source => if (kind == .mos) .{ .source_area, .source_perimeter } else continue,
            .drain => if (kind == .mos) .{ .drain_area, .drain_perimeter } else continue,
            .emitter => if (kind == .bjt) .{ .emitter_area, .emitter_perimeter } else continue,
            .gate, .bulk, .base, .collector, .pin => continue,
        };
        const poly = w.bound_poly.items[m.at + slot];
        if (poly == no_poly) continue;
        const t = areaAndPerimeter(store, &nets.holes, poly);
        if (kind == .mos) {
            const lo = std.sort.lowerBound(PolyId, w.served.items, poly, orderPoly);
            const hi = std.sort.upperBound(PolyId, w.served.items, poly, orderPoly);
            const ways: u32 = @intCast(hi - lo);
            try pushParam(gpa, out, names[0], .{ .area_share = .{ .area = t.area, .ways = ways } });
            try pushParam(gpa, out, names[1], .{ .length_share = .{ .length = t.perimeter, .ways = ways } });
        } else {
            try pushParam(gpa, out, names[0], .{ .area = t.area });
            try pushParam(gpa, out, names[1], .{ .length = t.perimeter });
        }
    }
    try out.param_start.append(gpa, @intCast(out.param_name.items.len));
    try out.value.append(gpa, if (m.row < recognition.value.len) recognition.value[m.row] else .{});
    for (nets_of) |n| try w.attach.append(gpa, .{ @backingInt(n), device });
}

fn orderPoly(want: PolyId, item: PolyId) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(item));
}

fn pushParam(gpa: Allocator, out: *DeviceTable, name: DeviceParam, measure: DeviceMeasure) Allocator.Error!void {
    try out.param_name.append(gpa, name);
    try out.param_measure.append(gpa, measure);
}

/// A polygon's area with its holes taken out, and the length of every ring
/// (an edge of the material), a diagonal edge rounded down.
fn areaAndPerimeter(store: *const GeometryStore, holes: *const Holes, poly: PolyId) struct { area: DbuArea, perimeter: Dbu } {
    var doubled: DbuArea = 0;
    var perimeter: Dbu = 0;
    const own = [1]PolyId{poly};
    for ([2][]const PolyId{ &own, holes.holesOf(poly) }, [2]i8{ 1, -1 }) |rows, sign| {
        for (rows) |r| {
            const ring = store.polyVerts(r);
            // `@abs`: a store polygon carries no winding guarantee.
            doubled += sign * @as(DbuArea, @intCast(@abs(geom.ops.area2(ring.xs, ring.ys))));
            for (0..ring.xs.len) |i| {
                const e = geom.ops.ringEdge(ring.xs, ring.ys, i);
                const dx: DbuArea = e.b.x - e.a.x;
                const dy: DbuArea = e.b.y - e.a.y;
                perimeter += geom.ops.isqrt(dx * dx + dy * dy);
            }
        }
    }
    // Bound holes lie inside their outer and apart from one another.
    assert(doubled >= 0);
    return .{ .area = @divTrunc(doubled, 2), .perimeter = perimeter };
}

/// The devices attached to each net, CSR, each device once per net.
fn buildReverseIndex(gpa: Allocator, nets: *const NetTable, attach: [][2]u32, out: *DeviceTable) Allocator.Error!void {
    std.mem.sortUnstable([2]u32, attach, {}, struct {
        fn less(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }
    }.less);
    const count = nets.netCount();
    try out.net_start.resize(gpa, @as(usize, count) + 1);
    @memset(out.net_start.items, 0);
    var prev: ?[2]u32 = null;
    for (attach) |a| {
        assert(a[0] < count);
        if (prev != null and std.mem.eql(u32, &prev.?, &a)) continue;
        prev = a;
        out.net_start.items[a[0] + 1] += 1;
        try out.net_device.append(gpa, @fromBackingInt(a[1]));
    }
    for (1..out.net_start.items.len) |i| out.net_start.items[i] += out.net_start.items[i - 1];
    assert(out.net_start.items[count] == out.net_device.items.len);
}
