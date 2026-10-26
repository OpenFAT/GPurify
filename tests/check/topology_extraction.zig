//! Net extraction against layouts emitted from a known netlist
//! (`testgen.netlist.layoutFromNetlist`): construct-from-answer. Ported
//! from crates/check/tests/topology/extraction.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const topology = check.topology;
const NetId = topology.NetId;
const NetTable = topology.NetTable;
const DeviceTable = topology.DeviceTable;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const Connectivity = @import("ingest").deck.Connectivity;
const nl = testgen.netlist;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Ids = testgen.shapes.Ids;

const gpa = testing.allocator;

/// One four-terminal MOS and one resistor sharing two nets: nets 0 and 1
/// carry one terminal, nets 2 and 3 one from each device.
const mos_and_resistor: nl.NetlistSpec = .{ .nets = 4, .devices = &devices };

const devices = [_]nl.DeviceSpec{
    .{ .kind = .mos, .model = "nch", .terminals = &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 }, .{ .role = .drain, .net = 2 }, .{ .role = .bulk, .net = 3 } } },
    .{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 2 }, .{ .role = .{ .pin = 1 }, .net = 3 } } },
};

// ---- private ----

fn lid(l: u16) LayerId {
    return @fromBackingInt(l);
}

fn lessPoly(_: void, a: PolyId, b: PolyId) bool {
    return @backingInt(a) < @backingInt(b);
}

/// Every claim the answer makes: each spec net's polygons are exactly the
/// ones the table lists for it, ascending, and no two spec nets collapsed.
fn assertExtractsToItsNetlist(case: *const nl.NetlistCase, nets: *const NetTable) !void {
    for (case.expected_net_polys) |expected| {
        try testing.expect(expected.len > 0);
        const n = nets.netOf(expected[0]);
        try testing.expectEqualSlices(PolyId, expected, nets.polysOf(n));
        for (expected) |p| {
            try testing.expectEqual(n, nets.netOf(p));
            try testing.expect(nets.sameNet(expected[0], p));
        }
    }
    for (case.expected_net_polys, 0..) |first, a| for (case.expected_net_polys[a + 1 ..]) |second| {
        try testing.expect(nets.netOf(first[0]) != nets.netOf(second[0]));
        try testing.expect(!nets.sameNet(first[0], second[0]));
    };
}

/// The whole table rendered as one flat list, nets separated by a marker.
fn snapshot(nets: *const NetTable, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    for (0..nets.netCount()) |n| {
        for (nets.polysOf(@fromBackingInt(@intCast(n)))) |p| try out.append(gpa, @backingInt(p));
        try out.append(gpa, std.math.maxInt(u32));
    }
}

test "a layout emitted from a netlist extracts back to that netlist" {
    // Oracle: construct-from-answer. Nets and devices both: two marker
    // polygons, each recogniser firing only where all its terminal layers
    // have a shape under the marker, so two devices, in marker order.
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, mos_and_resistor, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    try assertExtractsToItsNetlist(&case, &nets);
    var table: DeviceTable = .{};
    defer table.deinit(gpa);
    try topology.recogniseInto(gpa, &case.store, &nets, &case.recognition, &table);
    const expected = try gpa.dupe(nl.ExpectedDevice, case.expected_devices);
    defer gpa.free(expected);
    std.mem.sortUnstable(nl.ExpectedDevice, expected, {}, struct {
        fn less(_: void, a: nl.ExpectedDevice, b: nl.ExpectedDevice) bool {
            return @backingInt(a.marker) < @backingInt(b.marker);
        }
    }.less);
    try testing.expectEqual(@as(u32, @intCast(expected.len)), table.len());
    for (expected, 0..) |want, row| {
        try testing.expectEqual(want.marker, table.marker.items[row]);
        try testing.expectEqual(want.kind, table.kind.items[row]);
        try testing.expectEqual(want.model, table.model.items[row]);
        const t = table.terminalsOf(@fromBackingInt(@intCast(row)));
        try testing.expectEqual(want.terminals.len, t.roles.len);
        for (want.terminals, t.roles, t.nets) |w, role, n| {
            try testing.expect(nl.roleEql(w.role, role));
            try testing.expectEqual(nets.netOf(case.expected_net_polys[w.net][0]), n);
        }
    }
}

test "extraction does not depend on the order the devices were emitted in" {
    // Oracle: construct-from-answer. The same netlist with its devices in
    // another order is another layout of the same structure.
    var shuffled = devices;
    std.mem.swap(nl.DeviceSpec, &shuffled[0], &shuffled[1]);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, .{ .nets = 4, .devices = &shuffled }, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    try assertExtractsToItsNetlist(&case, &nets);
}

test "net ids ascend with the smallest polygon on each net" {
    // Oracle: law. A net id is the rank of its least polygon, so ids ascend
    // with each net's first polygon and each net's polygons ascend.
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, mos_and_resistor, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    try testing.expect(nets.netCount() > 0);
    var previous: ?u32 = null;
    for (0..nets.netCount()) |n| {
        const polys = nets.polysOf(@fromBackingInt(@intCast(n)));
        try testing.expect(polys.len > 0);
        for (polys[0 .. polys.len - 1], polys[1..]) |a, b| try testing.expect(@backingInt(a) < @backingInt(b));
        if (previous) |p| try testing.expect(p < @backingInt(polys[0]));
        previous = @backingInt(polys[0]);
    }
}

test "extraction is identical across runs, reused tables and threads" {
    // Oracle: determinism. The same store extracted twice into one table, into
    // a fresh table, and from two threads at once gives one answer.
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, mos_and_resistor, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    var first: std.ArrayList(u32) = .empty;
    defer first.deinit(gpa);
    try snapshot(&nets, &first);
    var again: std.ArrayList(u32) = .empty;
    defer again.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    try snapshot(&nets, &again);
    try testing.expectEqualSlices(u32, first.items, again.items);
    var fresh: NetTable = .{};
    defer fresh.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &fresh);
    try snapshot(&fresh, &again);
    try testing.expectEqualSlices(u32, first.items, again.items);
    const Worker = struct {
        fn run(c: *const nl.NetlistCase, out: *std.ArrayList(u32), err: *?anyerror) void {
            var t: NetTable = .{};
            defer t.deinit(std.heap.page_allocator);
            topology.extractNetsInto(std.heap.page_allocator, &c.store, &c.connectivity, &t) catch |e| {
                err.* = e;
                return;
            };
            out.clearRetainingCapacity();
            for (0..t.netCount()) |n| {
                for (t.polysOf(@fromBackingInt(@intCast(n)))) |p| out.append(std.heap.page_allocator, @backingInt(p)) catch |e| {
                    err.* = e;
                };
                out.append(std.heap.page_allocator, std.math.maxInt(u32)) catch |e| {
                    err.* = e;
                };
            }
        }
    };
    var outs: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&outs) |*o| o.deinit(std.heap.page_allocator);
    var errs: [2]?anyerror = .{ null, null };
    var threads: [2]std.Thread = undefined;
    for (&threads, &outs, &errs) |*t, *o, *e| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &case, o, e });
    for (threads) |t| t.join();
    for (outs, errs) |o, e| {
        try testing.expectEqual(null, e);
        try testing.expectEqualSlices(u32, first.items, o.items);
    }
}

test "intra-layer touch decides whether two abutting shapes are one net" {
    // Oracle: construct-from-answer. Two rectangles abutting at x = 1000
    // are one net with `intra_layer_touch` on and two with it off.
    var lb = LayoutBuilder.init(1);
    defer lb.deinit(gpa);
    const lh = try lb.rect(gpa, 0, 0, 0, 1_000, 200);
    const rh = try lb.rect(gpa, 0, 1_000, 0, 2_000, 200);
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    const left = ids.of(lh);
    const right = ids.of(rh);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &store, &.{ .conductors = &.{lid(0)}, .intra_layer_touch = true }, &nets);
    try testing.expectEqual(@as(u32, 1), nets.netCount());
    try testing.expectEqualSlices(PolyId, &.{ left, right }, nets.polysOf(nets.netOf(left)));
    try testing.expect(nets.sameNet(left, right));
    try topology.extractNetsInto(gpa, &store, &.{ .conductors = &.{lid(0)}, .intra_layer_touch = false }, &nets);
    try testing.expectEqual(@as(u32, 2), nets.netCount());
    try testing.expect(!nets.sameNet(left, right));
    try testing.expectEqualSlices(PolyId, &.{left}, nets.polysOf(nets.netOf(left)));
    try testing.expectEqualSlices(PolyId, &.{right}, nets.polysOf(nets.netOf(right)));
}

test "shapes that touch nothing each form their own net" {
    // Oracle: construct-from-answer over arbitrary geometry, plus the
    // partition law. Squares that never touch are one net each; every
    // polygon is on exactly one net, `netOf` and `polysOf` inverses.
    var lb = LayoutBuilder.init(1);
    defer lb.deinit(gpa);
    var rng = testgen.Rng.init(19);
    const placed = try testgen.shapes.randomRectilinearLayer(&lb, gpa, &rng, 0, .{ 0, 0 }, .{ .cells = 24, .cell = 400, .density = 0.5 });
    try testing.expect(placed.shapes > 0);
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &store, &.{ .conductors = &.{lid(0)}, .intra_layer_touch = true }, &nets);
    try testing.expectEqual(placed.shapes, nets.netCount());
    const seen = try gpa.alloc(bool, store.polyCount());
    defer gpa.free(seen);
    @memset(seen, false);
    for (0..nets.netCount()) |n| {
        const id: NetId = @fromBackingInt(@intCast(n));
        const polys = nets.polysOf(id);
        try testing.expectEqual(@as(usize, 1), polys.len);
        try testing.expectEqual(id, nets.netOf(polys[0]));
        try testing.expect(!seen[@backingInt(polys[0])]);
        seen[@backingInt(polys[0])] = true;
    }
    for (seen) |s| try testing.expect(s);
    for (0..store.polyCount()) |p| {
        const a: PolyId = @fromBackingInt(@intCast(p));
        try testing.expect(nets.sameNet(a, a));
        if (p + 1 < store.polyCount()) {
            const b: PolyId = @fromBackingInt(@intCast(p + 1));
            try testing.expect(!nets.sameNet(a, b) and !nets.sameNet(b, a));
        }
    }
}

test "a path is the fewest polygons between two on one net" {
    // Oracle: construct-from-answer. `a`, `b`, `c` in a row, each touching
    // the next, and a three-rectangle detour from `a` to `c`; one apart. The
    // fewest from `a` to `c` are the row; a polygon is its own path; one on
    // another net has none, nor does a table that extracted nothing.
    var lb = LayoutBuilder.init(1);
    defer lb.deinit(gpa);
    const ha = try lb.rect(gpa, 0, 0, 0, 1_000, 200);
    const hb = try lb.rect(gpa, 0, 1_000, 0, 2_000, 200);
    const hc = try lb.rect(gpa, 0, 2_000, 0, 3_000, 200);
    _ = try lb.rect(gpa, 0, 0, 200, 200, 1_200);
    _ = try lb.rect(gpa, 0, 0, 1_200, 3_000, 1_400);
    _ = try lb.rect(gpa, 0, 2_800, 200, 3_000, 1_200);
    const happ = try lb.rect(gpa, 0, 5_000, 0, 6_000, 200);
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    const a = ids.of(ha);
    const b = ids.of(hb);
    const c = ids.of(hc);
    const apart = ids.of(happ);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    var path: std.ArrayList(PolyId) = .empty;
    defer path.deinit(gpa);
    try testing.expect(!try nets.pathInto(gpa, a, c, &path));
    try topology.extractNetsInto(gpa, &store, &.{ .conductors = &.{lid(0)}, .intra_layer_touch = true }, &nets);
    try testing.expect(try nets.pathInto(gpa, a, c, &path));
    try testing.expectEqualSlices(PolyId, &.{ a, b, c }, path.items);
    try testing.expect(try nets.pathInto(gpa, c, a, &path));
    try testing.expectEqualSlices(PolyId, &.{ c, b, a }, path.items);
    try testing.expect(try nets.pathInto(gpa, a, a, &path));
    try testing.expectEqualSlices(PolyId, &.{a}, path.items);
    try testing.expect(!try nets.pathInto(gpa, a, apart, &path));
}
