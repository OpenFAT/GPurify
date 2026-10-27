//! Metamorphic laws over the whole of extraction: each test transforms one
//! hand-placed layout at the store level and asserts the extraction changes
//! only as the transform licenses. Ported from
//! crates/check/tests/topology/laws.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const ingest = @import("ingest");
const topology = check.topology;
const device = topology.device;
const NetId = topology.NetId;
const NetTable = topology.NetTable;
const DeviceTable = topology.DeviceTable;
const DeviceMeasure = device.DeviceMeasure;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const DeviceRecognition = ingest.deck.DeviceRecognition;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Ids = testgen.shapes.Ids;

const gpa = testing.allocator;

// The layer table: five conductors, one cut, one marker (not a conductor,
// which makes `NetId.none` reachable).
const m1 = 0;

const m2 = 1;

const cut = 2;

const gate = 3;

const src = 4;

const drn = 5;

const mark = 6;

const layer_count = 7;

/// One rectangle of the fixture; rectilinear, so no claim here is about the
/// ring sweep (its own differential test lives in net.zig).
const Rect = struct { layer: u16, xlo: i64, ylo: i64, xhi: i64, yhi: i64 };

// Indices into `fixture`, by name: the push order is the base order.
const m1_a = 0;

const m2_a = 1;

const cut_a = 2;

const m2_b = 3;

const m2_b_inner = 4;

const m1_c1 = 5;

const m1_c2 = 6;

const gate_d = 7;

const src_d = 8;

const drn_d = 9;

const mark_d = 10;

const gate_e = 11;

const src_e = 12;

const mark_e = 13;

/// The layout every law is stated over: a cut strictly inside both
/// conductors it joins, a same-layer shape strictly inside a plate, and a
/// marker that fires beside one that does not (no drain under it). Exactly
/// one shape on each terminal layer meets each marker, so terminal binding
/// does not depend on row order.
const fixture = [_]Rect{
    .{ .layer = m1, .xlo = 0, .ylo = 0, .xhi = 200, .yhi = 100 },
    .{ .layer = m2, .xlo = 50, .ylo = 20, .xhi = 150, .yhi = 80 },
    .{ .layer = cut, .xlo = 60, .ylo = 30, .xhi = 90, .yhi = 60 },
    .{ .layer = m2, .xlo = 400, .ylo = 0, .xhi = 700, .yhi = 300 },
    .{ .layer = m2, .xlo = 500, .ylo = 100, .xhi = 600, .yhi = 200 },
    // Abutting along x = -300, across the origin under a mirror.
    .{ .layer = m1, .xlo = -500, .ylo = -300, .xhi = -300, .yhi = -100 },
    .{ .layer = m1, .xlo = -300, .ylo = -300, .xhi = -100, .yhi = -100 },
    // The device that fires.
    .{ .layer = gate, .xlo = 1_000, .ylo = 0, .xhi = 1_100, .yhi = 400 },
    .{ .layer = src, .xlo = 900, .ylo = 150, .xhi = 1_010, .yhi = 250 },
    .{ .layer = drn, .xlo = 1_090, .ylo = 150, .xhi = 1_200, .yhi = 250 },
    .{ .layer = mark, .xlo = 950, .ylo = 150, .xhi = 1_150, .yhi = 250 },
    // The device that does not: no drain reaches it.
    .{ .layer = gate, .xlo = 1_550, .ylo = 0, .xhi = 1_650, .yhi = 400 },
    .{ .layer = src, .xlo = 1_500, .ylo = 150, .xhi = 1_560, .yhi = 250 },
    .{ .layer = mark, .xlo = 1_500, .ylo = 150, .xhi = 1_700, .yhi = 250 },
};

const connectivity: ingest.deck.Connectivity = .{
    .conductors = &.{ lid(m1), lid(m2), lid(gate), lid(src), lid(drn) },
    .via_cut = &.{lid(cut)},
    .via_connects = &.{.{ lid(m1), lid(m2) }},
    .intra_layer_touch = true,
};

/// A three-terminal MOS, one terminal layer per role.
const recognition: DeviceRecognition = .{
    .kind = &.{.mos},
    .marker = &.{lid(mark)},
    .terminal_start = &.{ 0, 3 },
    .terminal = &.{ lid(gate), lid(src), lid(drn) },
    .model = &.{@fromBackingInt(0)},
};

const Motion = *const fn (i64, i64) [2]i64;

/// The eight symmetries of the square, a mirror-and-shift, and a
/// translation: mirrors move the index grid's ragged cell, so the candidate
/// superset really differs while the answer may not.
const motions = [_]Motion{
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -x, y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ x, -y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -y, x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -x, -y };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ y, -x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ y, x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -y, -x };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ -x + 777, y - 333 };
        }
    }.f,
    struct {
        fn f(x: i64, y: i64) [2]i64 {
            return .{ x + 7_777, y - 3_333 };
        }
    }.f,
};

/// The anisotropic scale: unequal factors reassign boxes between index
/// levels.
const sx = 3;

const sy = 5;

/// A built store with the extraction under test, and where each fixture
/// shape landed.
const Run = struct {
    store: GeometryStore = .empty,
    ids: [fixture.len]PolyId = undefined,
    nets: NetTable = .{},
    devices: DeviceTable = .{},

    fn deinit(r: *Run) void {
        r.store.deinit(gpa);
        r.nets.deinit(gpa);
        r.devices.deinit(gpa);
    }

    /// The fixture mapped through `t`, pushed in `order`, extracted.
    fn build(r: *Run, order: []const usize, t: Motion) !void {
        var lb = LayoutBuilder.init(layer_count);
        defer lb.deinit(gpa);
        var handles: [fixture.len]testgen.shapes.Handle = undefined;
        for (order) |s| {
            const q = fixture[s];
            var xs: [4]i64 = undefined;
            var ys: [4]i64 = undefined;
            for ([4][2]i64{ .{ q.xlo, q.ylo }, .{ q.xhi, q.ylo }, .{ q.xhi, q.yhi }, .{ q.xlo, q.yhi } }, 0..) |c, k| {
                const m = t(c[0], c[1]);
                xs[k] = m[0];
                ys[k] = m[1];
            }
            handles[s] = try lb.push(gpa, q.layer, &xs, &ys);
        }
        var ids: Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &r.store, &ids);
        for (&r.ids, handles) |*id, h| id.* = ids.of(h);
        try topology.extractNetsInto(gpa, &r.store, &connectivity, &r.nets);
        try topology.recogniseInto(gpa, &r.store, &r.nets, &recognition, &r.devices);
    }
};

// ---- private ----

fn lid(l: u16) LayerId {
    return @fromBackingInt(l);
}

fn identity(x: i64, y: i64) [2]i64 {
    return .{ x, y };
}

fn scale(x: i64, y: i64) [2]i64 {
    return .{ x * sx, y * sy };
}

fn netId(k: usize) NetId {
    return @fromBackingInt(@intCast(k));
}

/// Two partitions equal net by net.
fn expectSamePartition(a: *const NetTable, b: *const NetTable) !void {
    try testing.expectEqual(a.netCount(), b.netCount());
    for (0..a.netCount()) |k| try testing.expectEqualSlices(PolyId, a.polysOf(netId(k)), b.polysOf(netId(k)));
}

/// The guards that stop a law being satisfied by an extractor reporting
/// nothing, asserted on the base run.
fn assertTheBaseRunCanFailALaw(r: *const Run) !void {
    const ids = r.ids;
    const nets = &r.nets;
    try testing.expect(nets.netCount() > 1);
    var multi: usize = 0;
    for (0..nets.netCount()) |k| multi += @intFromBool(nets.polysOf(netId(k)).len > 1);
    try testing.expect(multi >= 3);
    try testing.expect(nets.sameNet(ids[m1_a], ids[m2_a]));
    try testing.expectEqual(NetId.none, nets.netOf(ids[cut_a]));
    try testing.expectEqual(NetId.none, nets.netOf(ids[mark_d]));
    for ([_][2]usize{ .{ cut_a, m1_a }, .{ cut_a, m2_a }, .{ m2_b_inner, m2_b } }) |io| {
        const small = r.store.polyBbox(ids[io[0]]);
        const large = r.store.polyBbox(ids[io[1]]);
        try testing.expect(small.xlo > large.xlo and small.ylo > large.ylo and small.xhi < large.xhi and small.yhi < large.yhi);
    }
    try testing.expect(nets.sameNet(ids[m2_b], ids[m2_b_inner]));
    try testing.expect(nets.sameNet(ids[m1_c1], ids[m1_c2]));
    try testing.expectEqual(@as(u32, 1), r.devices.len());
    try testing.expectEqual(@as(u32, 2), r.store.polysOnLayer(lid(mark)).len());
    try testing.expectEqualSlices(PolyId, &.{ids[mark_d]}, r.devices.marker.items);
    const t = r.devices.terminalsOf(@fromBackingInt(0));
    try testing.expect(t.roles[0] == .gate and t.roles[1] == .source and t.roles[2] == .drain);
    try testing.expectEqualSlices(NetId, &.{ nets.netOf(ids[gate_d]), nets.netOf(ids[src_d]), nets.netOf(ids[drn_d]) }, t.nets);
    try testing.expect(t.nets[0] != t.nets[1] and t.nets[1] != t.nets[2] and t.nets[0] != t.nets[2]);
    try testing.expectEqual(NetId.none, nets.netOf(ids[mark_e]));
    try testing.expect(nets.netOf(ids[gate_e]) != .none and nets.netOf(ids[src_e]) != .none);
}

/// Two device tables agree in every column, areas scaled by `area_scale`
/// and W, L by `wl` = (width, length) factors; perimeters follow: a marker
/// is a W by L rectangle, each source/drain 110 along the channel and 100
/// across.
fn expectDeviceColumnsAgree(base: *const DeviceTable, other: *const DeviceTable, area_scale: i128, wl: [2]i64) !void {
    try testing.expectEqualSlices(ingest.deck.DeviceKind, base.kind.items, other.kind.items);
    try testing.expectEqualSlices(PolyId, base.marker.items, other.marker.items);
    try testing.expectEqualSlices(geom.StrId, base.model.items, other.model.items);
    try testing.expectEqualSlices(u32, base.terminal_start.items, other.terminal_start.items);
    try testing.expectEqualSlices(NetId, base.terminal_net.items, other.terminal_net.items);
    for (base.terminal_role.items, other.terminal_role.items) |a, b| try testing.expect(std.meta.eql(a, b));
    try testing.expectEqualSlices(u32, base.param_start.items, other.param_start.items);
    try testing.expectEqualSlices(device.DeviceParam, base.param_name.items, other.param_name.items);
    var extents = [2]i64{ 0, 0 };
    for (base.param_name.items, base.param_measure.items, other.param_measure.items) |name, m, got| {
        const want: DeviceMeasure = switch (m) {
            .area => |a| .{ .area = a * area_scale },
            .length => |l| switch (name) {
                .width => blk: {
                    extents[0] = l * wl[0];
                    break :blk .{ .length = extents[0] };
                },
                .length => blk: {
                    extents[1] = l * wl[1];
                    break :blk .{ .length = extents[1] };
                },
                .perimeter => .{ .length = 2 * (extents[0] + extents[1]) },
                .area, .fins, .fingers, .source_area, .drain_area, .source_perimeter, .drain_perimeter, .emitter_area, .emitter_perimeter => m,
            },
            .area_share => |s| .{ .area_share = .{ .area = s.area * area_scale, .ways = s.ways } },
            .length_share => |s| .{ .length_share = .{ .length = 2 * (110 * wl[1] + 100 * wl[0]), .ways = s.ways } },
            .count => m,
        };
        try testing.expect(std.meta.eql(want, got));
    }
}

/// The reverse index, net by net; only valid where both runs share a net
/// numbering. Three nets (gate, source, drain) carry the one device.
fn expectReverseIndexAgrees(nets: *const NetTable, base: *const DeviceTable, other: *const DeviceTable) !void {
    var carried: usize = 0;
    for (0..nets.netCount()) |k| {
        try testing.expectEqualSlices(topology.DeviceId, base.devicesOn(netId(k)), other.devicesOn(netId(k)));
        carried += @intFromBool(base.devicesOn(netId(k)).len > 0);
    }
    try testing.expectEqual(@as(usize, 3), carried);
}

test "a rigid motion of every vertex leaves the extraction bit-identical" {
    // Oracle: law. An isometry of the grid preserves set intersection, so
    // the joins, the partition, the numbering and every terminal are
    // unchanged; its determinant is ±1, so areas too. Only the index's cell
    // partition moves.
    var order: [fixture.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    var base: Run = .{};
    defer base.deinit();
    try base.build(&order, identity);
    try assertTheBaseRunCanFailALaw(&base);
    for (motions) |motion| {
        var moved: Run = .{};
        defer moved.deinit();
        try moved.build(&order, motion);
        try testing.expectEqualSlices(PolyId, &base.ids, &moved.ids);
        try expectSamePartition(&base.nets, &moved.nets);
        try expectDeviceColumnsAgree(&base.devices, &moved.devices, 1, .{ 1, 1 });
        try expectReverseIndexAgrees(&base.nets, &base.devices, &moved.devices);
    }
}

test "permuting arrival order gives the same partition and the same net ids" {
    // Oracle: law. Relabelling vertices cannot change which are connected:
    // under the induced row permutation π, `sameNet` maps through π, the
    // net sizes are unchanged, and, since a net id is the rank of its least
    // row, the ids are pinned to the π-image. Device rows reorder by marker
    // and are compared through π.
    var identity_order: [fixture.len]usize = undefined;
    var order: [fixture.len]usize = undefined;
    for (&identity_order, &order, 0..) |*o, *p, i| {
        o.* = i;
        p.* = (5 * i + 3) % fixture.len;
    }
    var sorted = order;
    std.mem.sortUnstable(usize, &sorted, {}, std.sort.asc(usize));
    try testing.expectEqualSlices(usize, &identity_order, &sorted);
    try testing.expect(!std.mem.eql(usize, &order, &identity_order));
    var base: Run = .{};
    defer base.deinit();
    try base.build(&identity_order, identity);
    try assertTheBaseRunCanFailALaw(&base);
    var other: Run = .{};
    defer other.deinit();
    try other.build(&order, identity);
    // π, indexed by the base row.
    var pi: [fixture.len]PolyId = undefined;
    for (base.ids, other.ids) |b, o| pi[@backingInt(b)] = o;
    var moved = false;
    for (pi, 0..) |p, i| moved = moved or @backingInt(p) != i;
    try testing.expect(moved);
    // (a) the partition maps through π, and being on no net is kept.
    for (0..fixture.len) |p| {
        const pp: PolyId = @fromBackingInt(@intCast(p));
        try testing.expectEqual(base.nets.netOf(pp) == .none, other.nets.netOf(pi[p]) == .none);
        for (0..fixture.len) |q| {
            const qq: PolyId = @fromBackingInt(@intCast(q));
            try testing.expectEqual(base.nets.sameNet(pp, qq), other.nets.sameNet(pi[p], pi[q]));
        }
    }
    // (b, c) the count, and the ids pinned to the π-image ranked by least row.
    try testing.expectEqual(base.nets.netCount(), other.nets.netCount());
    var images: [fixture.len][fixture.len]u32 = undefined;
    var image_len: [fixture.len]usize = undefined;
    var rank: [fixture.len]usize = undefined;
    for (0..base.nets.netCount()) |k| {
        const polys = base.nets.polysOf(netId(k));
        for (polys, 0..) |p, i| images[k][i] = @backingInt(pi[@backingInt(p)]);
        image_len[k] = polys.len;
        std.mem.sortUnstable(u32, images[k][0..polys.len], {}, std.sort.asc(u32));
        rank[k] = k;
    }
    const n = base.nets.netCount();
    std.mem.sortUnstable(usize, rank[0..n], &images, struct {
        fn less(im: *const [fixture.len][fixture.len]u32, a: usize, b: usize) bool {
            return im[a][0] < im[b][0];
        }
    }.less);
    for (rank[0..n], 0..) |k, r| {
        const got = other.nets.polysOf(netId(r));
        try testing.expectEqual(image_len[k], got.len);
        for (images[k][0..image_len[k]], got) |w, g| try testing.expectEqual(w, @backingInt(g));
    }
    // Devices through π of the marker, terminals through the net map.
    try testing.expectEqual(base.devices.len(), other.devices.len());
    for (0..base.devices.len()) |d| {
        const want_marker = pi[@backingInt(base.devices.marker.items[d])];
        const row = std.mem.indexOfScalar(PolyId, other.devices.marker.items, want_marker).?;
        try testing.expectEqual(base.devices.kind.items[d], other.devices.kind.items[row]);
        const bt = base.devices.terminalsOf(@fromBackingInt(@intCast(d)));
        const ot = other.devices.terminalsOf(@fromBackingInt(@intCast(row)));
        for (bt.nets, ot.nets) |bn, on| {
            const mapped = other.nets.netOf(pi[@backingInt(base.nets.polysOf(bn)[0])]);
            try testing.expectEqual(mapped, on);
        }
        const bp = base.devices.paramsOf(@fromBackingInt(@intCast(d)));
        const op = other.devices.paramsOf(@fromBackingInt(@intCast(row)));
        try testing.expectEqualSlices(device.DeviceParam, bp.names, op.names);
        for (bp.measures, op.measures) |a, b| try testing.expect(std.meta.eql(a, b));
    }
}

test "an anisotropic integer scale moves only the measured area" {
    // Oracle: law. A positive diagonal integer map preserves set
    // intersection, so the netlist is unchanged; areas scale by `sx·sy`
    // exactly, and the channel runs along x, so L picks up `sx` and W `sy`.
    var order: [fixture.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    var base: Run = .{};
    defer base.deinit();
    try base.build(&order, identity);
    try assertTheBaseRunCanFailALaw(&base);
    var positive = false;
    for (base.devices.param_measure.items) |m| positive = positive or (m == .area and m.area > 0);
    try testing.expect(positive);
    var scaled: Run = .{};
    defer scaled.deinit();
    try scaled.build(&order, scale);
    try testing.expectEqualSlices(PolyId, &base.ids, &scaled.ids);
    try expectSamePartition(&base.nets, &scaled.nets);
    try expectDeviceColumnsAgree(&base.devices, &scaled.devices, sx * sy, .{ sy, sx });
    try expectReverseIndexAgrees(&base.nets, &base.devices, &scaled.devices);
}
