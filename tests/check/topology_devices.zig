//! Device recognition: one device per marker polygon, the reverse index,
//! terminal binding, measured parameters, and the conduction guard. Ported
//! from crates/check/tests/topology/devices.rs.
//!
//! Oracle throughout: construct-from-answer, over layouts stated first
//! (`layoutFromNetlist` or drawn by hand): one polygon on a recogniser's
//! marker layer is exactly one device.

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
const TerminalRole = topology.TerminalRole;
const DeviceMeasure = device.DeviceMeasure;
const DeviceParam = device.DeviceParam;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const Connectivity = ingest.deck.Connectivity;
const DeviceRecognition = ingest.deck.DeviceRecognition;
const nl = testgen.netlist;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const Ids = testgen.shapes.Ids;
const Handle = testgen.shapes.Handle;

const gpa = testing.allocator;

const mos_roles = [_]TerminalRole{ .gate, .source, .drain, .bulk };

/// Two MOS devices wired to the same four nets in the same order:
/// electrically indistinguishable, so a count is about markers.
const two_identical_mos: nl.NetlistSpec = .{ .nets = 4, .devices = &.{ mos_device, mos_device } };

const mos_device: nl.DeviceSpec = .{ .kind = .mos, .model = "nch", .terminals = &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 }, .{ .role = .drain, .net = 2 }, .{ .role = .bulk, .net = 3 } } };

/// A store and handle map, plus the nets and devices recognised on it.
const Run = struct {
    store: GeometryStore = .empty,
    ids: Ids = .{},
    nets: NetTable = .{},
    devices: DeviceTable = .{},
    strings: geom.StrTable = .empty,

    fn deinit(r: *Run) void {
        r.store.deinit(gpa);
        r.ids.deinit(gpa);
        r.nets.deinit(gpa);
        r.devices.deinit(gpa);
        r.strings.deinit(gpa);
    }

    fn of(r: *const Run, h: Handle) PolyId {
        return r.ids.of(h);
    }

    /// Finishes `lb`, extracts with `connectivity`, recognises with a
    /// one-row table of `kind` on `marker` over `terminals`.
    fn recognise(r: *Run, lb: *LayoutBuilder, connectivity: Connectivity, kind: ingest.deck.DeviceKind, marker: u16, terminals: []const LayerId, value: []const ingest.deck.DeviceValue) !void {
        try lb.finish(gpa, &r.store, &r.ids);
        try topology.extractNetsInto(gpa, &r.store, &connectivity, &r.nets);
        const model = [1]geom.StrId{try r.strings.intern(gpa, "dev")};
        const kinds = [1]ingest.deck.DeviceKind{kind};
        const markers = [1]LayerId{lid(marker)};
        const starts = [2]u32{ 0, @intCast(terminals.len) };
        const recognition: DeviceRecognition = .{
            .kind = &kinds,
            .marker = &markers,
            .terminal_start = &starts,
            .terminal = terminals,
            .model = &model,
            .value = value,
        };
        try topology.recogniseInto(gpa, &r.store, &r.nets, &recognition, &r.devices);
    }
};

/// Two fingers under one implant, the corpus cell `LVS_FINGERS`: diffusion
/// split by two gates at x 200 and 600, channels drawn per finger.
const Fingers = struct {
    const implant = 0;
    const channel = 1;
    const poly = 2;
    const active = 3;

    fn draw(lb: *LayoutBuilder) !struct { channel: [2]Handle, gate: [2]Handle, active: [3]Handle } {
        _ = try lb.rect(gpa, implant, -50, -50, 1050, 250);
        return .{
            .channel = .{ try lb.rect(gpa, channel, 200, 0, 250, 200), try lb.rect(gpa, channel, 600, 0, 650, 200) },
            .gate = .{ try lb.rect(gpa, poly, 200, -50, 250, 250), try lb.rect(gpa, poly, 600, -50, 650, 250) },
            .active = .{ try lb.rect(gpa, active, 0, 0, 200, 200), try lb.rect(gpa, active, 250, 0, 600, 200), try lb.rect(gpa, active, 650, 0, 1000, 200) },
        };
    }

    const connectivity: Connectivity = .{ .conductors = &.{ lid(poly), lid(active) }, .intra_layer_touch = true };
    const terminals = [_]LayerId{ lid(poly), lid(active), lid(active) };
};

/// The slices of a one-row MOS recogniser.
const MosRow = struct { marker: [1]LayerId = undefined, terminal: [4]LayerId = undefined, model: [1]geom.StrId = undefined };

// ---- private ----

fn lid(l: u16) LayerId {
    return @fromBackingInt(l);
}

fn did(d: u32) topology.DeviceId {
    return @fromBackingInt(d);
}

fn rolesEql(a: []const TerminalRole, b: []const TerminalRole) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!nl.roleEql(x, y)) return false;
    return true;
}

fn expectParams(want: []const struct { DeviceParam, DeviceMeasure }, got: device.Params) !void {
    try testing.expectEqual(want.len, got.names.len);
    for (want, got.names, got.measures) |w, n, m| {
        try testing.expectEqual(w[0], n);
        try testing.expect(std.meta.eql(w[1], m));
    }
}

/// A one-row MOS recogniser over a netlist case's layers.
/// `store` holds the slices: the marker, four terminals, the model.
fn oneMosRecogniser(case: *const nl.NetlistCase, store: *MosRow, strings: *geom.StrTable) !DeviceRecognition {
    for (&store.terminal, mos_roles) |*t, r| t.* = case.layers.layerOf(r);
    store.marker = .{case.layers.marker};
    store.model = .{try strings.intern(gpa, "nch")};
    return .{ .kind = &.{.mos}, .marker = &store.marker, .terminal_start = &.{ 0, 4 }, .terminal = &store.terminal, .model = &store.model };
}

/// One channel, its gate, and diffusion rectangles `active` (`xlo`, `xhi`),
/// recognised as a three-terminal MOS.
fn oneChannel(r: *Run, active: []const [2]i64, drawn: []Handle) !Handle {
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, 0, 200, 0, 250, 200);
    const gate = try lb.rect(gpa, 1, 200, -50, 250, 250);
    for (active, drawn) |a, *h| h.* = try lb.rect(gpa, 2, a[0], 0, a[1], 200);
    try r.recognise(&lb, .{ .conductors = &.{ lid(1), lid(2) }, .intra_layer_touch = true }, .mos, 0, &.{ lid(1), lid(2), lid(2) }, &.{});
    return gate;
}

/// A channel guard's run over one MOS row: `channel` and poly boxes and one
/// diffusion polygon.
fn channelGuard(diff_x: []const i64, diff_y: []const i64, diag: *topology.channel.ChannelDiagnostic, channel: *PolyId, diff: *PolyId) !void {
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const ch = try lb.push(gpa, 0, &.{ 200, 250, 250, 200 }, &.{ 0, 0, 200, 200 });
    _ = try lb.rect(gpa, 1, 200, -50, 250, 250);
    const df = try lb.push(gpa, 2, diff_x, diff_y);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    channel.* = ids.of(ch);
    diff.* = ids.of(df);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const model = [1]geom.StrId{try strings.intern(gpa, "nch")};
    const recognition: DeviceRecognition = .{ .kind = &.{.mos}, .marker = &.{lid(0)}, .terminal_start = &.{ 0, 3 }, .terminal = &.{ lid(1), lid(2), lid(2) }, .model = &model };
    try topology.refuseConductingChannels(gpa, &store, &.{ .conductors = &.{ lid(1), lid(2) }, .intra_layer_touch = true }, &recognition, diag);
}

test "two identical devices on two marker polygons are two devices, not one" {
    // Oracle: construct-from-answer. Two MOS on the same four nets, same
    // model and order: two devices, because two marker polygons.
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, two_identical_mos, .{}, &strings);
    defer case.deinit(gpa);
    var row: MosRow = .{};
    const recognition = try oneMosRecogniser(&case, &row, &strings);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    var table: DeviceTable = .{};
    defer table.deinit(gpa);
    try topology.recogniseInto(gpa, &case.store, &nets, &recognition, &table);
    try testing.expectEqual(@as(u32, 2), table.len());
    var markers = [2]PolyId{ case.expected_devices[0].marker, case.expected_devices[1].marker };
    if (@backingInt(markers[0]) > @backingInt(markers[1])) std.mem.swap(PolyId, &markers[0], &markers[1]);
    try testing.expectEqualSlices(PolyId, &markers, table.marker.items);
    const first = table.terminalsOf(did(0));
    const second = table.terminalsOf(did(1));
    try testing.expectEqualSlices(NetId, first.nets, second.nets);
    try testing.expect(rolesEql(first.roles, &mos_roles));
    try testing.expect(rolesEql(second.roles, &mos_roles));
    for (first.nets, 0..) |n, k| try testing.expectEqual(nets.netOf(case.expected_net_polys[k][0]), n);
}

test "the reverse index lists exactly the devices each net carries" {
    // Oracle: construct-from-answer. Nets 0 and 1 carry the MOS alone, nets
    // 2 and 3 both devices ascending, net 4 nothing (a floating net), all
    // from one table.
    const spec: nl.NetlistSpec = .{ .nets = 5, .devices = &.{
        mos_device,
        .{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 2 }, .{ .role = .{ .pin = 1 }, .net = 3 } } },
    } };
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, spec, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    var table: DeviceTable = .{};
    defer table.deinit(gpa);
    try topology.recogniseInto(gpa, &case.store, &nets, &case.recognition, &table);
    try testing.expectEqual(@as(u32, 2), table.len());
    const deviceOf = struct {
        fn of(t: *const DeviceTable, marker: PolyId) topology.DeviceId {
            return @fromBackingInt(@intCast(std.mem.indexOfScalar(PolyId, t.marker.items, marker).?));
        }
    }.of;
    const mos = deviceOf(&table, case.expected_devices[0].marker);
    const res = deviceOf(&table, case.expected_devices[1].marker);
    var shared = [2]topology.DeviceId{ mos, res };
    if (@backingInt(shared[0]) > @backingInt(shared[1])) std.mem.swap(topology.DeviceId, &shared[0], &shared[1]);
    const netOfSpec = struct {
        fn of(n: *const NetTable, c: *const nl.NetlistCase, k: usize) NetId {
            return n.netOf(c.expected_net_polys[k][0]);
        }
    }.of;
    try testing.expectEqualSlices(topology.DeviceId, &.{mos}, table.devicesOn(netOfSpec(&nets, &case, 0)));
    try testing.expectEqualSlices(topology.DeviceId, &.{mos}, table.devicesOn(netOfSpec(&nets, &case, 1)));
    try testing.expectEqualSlices(topology.DeviceId, &shared, table.devicesOn(netOfSpec(&nets, &case, 2)));
    try testing.expectEqualSlices(topology.DeviceId, &shared, table.devicesOn(netOfSpec(&nets, &case, 3)));
    try testing.expectEqual(@as(usize, 0), table.devicesOn(netOfSpec(&nets, &case, 4)).len);
}

test "a reused device table is refilled and an empty deck recognises nothing" {
    // Oracle: construct-from-answer. A table handed in twice is refilled,
    // not appended to; a deck with no recognisers leaves it empty.
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, two_identical_mos, .{}, &strings);
    defer case.deinit(gpa);
    var row: MosRow = .{};
    const recognition = try oneMosRecogniser(&case, &row, &strings);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    var table: DeviceTable = .{};
    defer table.deinit(gpa);
    try topology.recogniseInto(gpa, &case.store, &nets, &recognition, &table);
    var markers: [2]PolyId = undefined;
    try testing.expectEqual(@as(usize, 2), table.marker.items.len);
    @memcpy(&markers, table.marker.items);
    try topology.recogniseInto(gpa, &case.store, &nets, &recognition, &table);
    try testing.expectEqualSlices(PolyId, &markers, table.marker.items);
    try topology.recogniseInto(gpa, &case.store, &nets, &.{}, &table);
    try testing.expectEqual(@as(u32, 0), table.len());
    try testing.expectEqual(@as(usize, 0), table.marker.items.len);
}

test "two terminal positions on one layer bind to two different polygons" {
    // Oracle: construct-from-answer. `[gate, sd, sd]` over two disjoint
    // source/drain rectangles either side of the gate: source and drain are
    // two nets, taken in ascending row order.
    var r: Run = .{};
    defer r.deinit();
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const marker = try lb.rect(gpa, 0, -50, -50, 550, 250);
    const gate = try lb.rect(gpa, 1, 200, -50, 250, 750);
    const source = try lb.rect(gpa, 2, 0, 0, 200, 200);
    const drain = try lb.rect(gpa, 2, 250, 0, 500, 200);
    try r.recognise(&lb, .{ .conductors = &.{ lid(1), lid(2) }, .intra_layer_touch = true }, .mos, 0, &.{ lid(1), lid(2), lid(2) }, &.{});
    try testing.expect(r.nets.netOf(r.of(source)) != r.nets.netOf(r.of(drain)));
    try testing.expectEqual(@as(u32, 1), r.devices.len());
    try testing.expectEqualSlices(PolyId, &.{r.of(marker)}, r.devices.marker.items);
    const t = r.devices.terminalsOf(did(0));
    try testing.expect(rolesEql(t.roles, &.{ .gate, .source, .drain }));
    try testing.expectEqualSlices(NetId, &.{ r.nets.netOf(r.of(gate)), r.nets.netOf(r.of(source)), r.nets.netOf(r.of(drain)) }, t.nets);
}

test "two gates under one implant are refused rather than reported as one device" {
    // Oracle: construct-from-answer. Two gate nets for one gate position and
    // three diffusion nets for two positions bind none of the three
    // terminals: no device, the implant listed as refused (F32).
    var r: Run = .{};
    defer r.deinit();
    var lb = LayoutBuilder.init(4);
    defer lb.deinit(gpa);
    const f = try Fingers.draw(&lb);
    try r.recognise(&lb, Fingers.connectivity, .mos, Fingers.implant, &Fingers.terminals, &.{});
    const a = [3]NetId{ r.nets.netOf(r.of(f.active[0])), r.nets.netOf(r.of(f.active[1])), r.nets.netOf(r.of(f.active[2])) };
    try testing.expect(a[0] != a[1] and a[1] != a[2] and a[0] != a[2]);
    try testing.expect(r.nets.netOf(r.of(f.gate[0])) != r.nets.netOf(r.of(f.gate[1])));
    try testing.expectEqual(@as(u32, 0), r.devices.len());
    const implant: PolyId = @fromBackingInt(r.store.polysOnLayer(lid(Fingers.implant)).start);
    try testing.expectEqualSlices(PolyId, &.{implant}, r.devices.refused_marker.items);
    try testing.expectEqualSlices(u32, &.{0}, r.devices.refused_bound.items);
    try testing.expectEqualSlices(u32, &.{3}, r.devices.refused_listed.items);
}

test "a source or drain drawn twice binds wherever its copy is numbered" {
    // Oracle: construct-from-answer, F33. A source or drain drawn twice is
    // one terminal, whichever is doubled and wherever its copy is numbered.
    const source = [2]i64{ 0, 200 };
    const drain = [2]i64{ 250, 450 };
    for ([_][3][2]i64{ .{ source, source, drain }, .{ source, drain, source }, .{ drain, source, drain }, .{ source, drain, drain } }) |active| {
        var r: Run = .{};
        defer r.deinit();
        var drawn: [3]Handle = undefined;
        const gate = try oneChannel(&r, &active, &drawn);
        const s = r.nets.netOf(r.of(drawn[for (active, 0..) |a, i| (if (std.mem.eql(i64, &a, &source)) break i) else unreachable]));
        const d = r.nets.netOf(r.of(drawn[for (active, 0..) |a, i| (if (std.mem.eql(i64, &a, &drain)) break i) else unreachable]));
        try testing.expect(s != d);
        try testing.expectEqual(@as(u32, 1), r.devices.len());
        const t = r.devices.terminalsOf(did(0));
        try testing.expectEqual(r.nets.netOf(r.of(gate)), t.nets[0]);
        var got = [2]u32{ @backingInt(t.nets[1]), @backingInt(t.nets[2]) };
        var want = [2]u32{ @backingInt(s), @backingInt(d) };
        std.mem.sortUnstable(u32, &got, {}, std.sort.asc(u32));
        std.mem.sortUnstable(u32, &want, {}, std.sort.asc(u32));
        try testing.expectEqualSlices(u32, &want, &got);
        try testing.expectEqual(@as(usize, 0), r.devices.refused_marker.items.len);
    }
}

test "a channel missing its drain is listed as refused" {
    // Oracle: construct-from-answer, F32. One diffusion polygon for two
    // positions: no device, refused with gate and source bound of three.
    var r: Run = .{};
    defer r.deinit();
    var drawn: [1]Handle = undefined;
    _ = try oneChannel(&r, &.{.{ 0, 200 }}, &drawn);
    try testing.expectEqual(@as(u32, 0), r.devices.len());
    try testing.expectEqualSlices(PolyId, &.{@fromBackingInt(0)}, r.devices.refused_marker.items);
    try testing.expectEqualSlices(u32, &.{2}, r.devices.refused_bound.items);
    try testing.expectEqualSlices(u32, &.{3}, r.devices.refused_listed.items);
}

test "a source drawn twice with no drain is refused, not shorted" {
    // Oracle: construct-from-answer, F69. Overlapping copies are one shape,
    // so the drain position has none: refused with two of three bound,
    // whether the copy coincides or only overlaps.
    for ([_][2][2]i64{ .{ .{ 0, 200 }, .{ 0, 200 } }, .{ .{ 0, 200 }, .{ 100, 200 } } }) |active| {
        var r: Run = .{};
        defer r.deinit();
        var drawn: [2]Handle = undefined;
        _ = try oneChannel(&r, &active, &drawn);
        try testing.expectEqual(@as(u32, 0), r.devices.len());
        try testing.expectEqualSlices(PolyId, &.{@fromBackingInt(0)}, r.devices.refused_marker.items);
        try testing.expectEqualSlices(u32, &.{2}, r.devices.refused_bound.items);
    }
}

test "a terminal drawn twice on one net still binds" {
    // Oracle: construct-from-answer. Two overlapping wells are one net, so
    // the bulk is one terminal: one device.
    var r: Run = .{};
    defer r.deinit();
    var lb = LayoutBuilder.init(4);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, 0, 200, 0, 250, 200);
    _ = try lb.rect(gpa, 1, 200, -50, 250, 250);
    _ = try lb.rect(gpa, 2, 0, 0, 200, 200);
    _ = try lb.rect(gpa, 2, 250, 0, 450, 200);
    _ = try lb.rect(gpa, 3, -100, -100, 550, 300);
    _ = try lb.rect(gpa, 3, -200, -200, 650, 400);
    try r.recognise(&lb, .{ .conductors = &.{ lid(1), lid(2), lid(3) }, .intra_layer_touch = true }, .mos, 0, &.{ lid(1), lid(2), lid(2), lid(3) }, &.{});
    try testing.expectEqual(@as(u32, 1), r.devices.len());
}

test "a marker drawn per channel recognises one device per finger" {
    // Oracle: construct-from-answer. Two channel regions are two
    // transistors in series (the middle diffusion is the first's drain and
    // the second's source). The left finger: W 200 across the channel, L 50
    // along, one finger, area 50 x 200, perimeter 2 (50 + 200); its source
    // 200 x 200 its own (40 000, 800), its drain 350 x 200 shared two ways
    // (70 000, 1100) (F16, as KLayout shares a diffusion).
    var r: Run = .{};
    defer r.deinit();
    var lb = LayoutBuilder.init(4);
    defer lb.deinit(gpa);
    const f = try Fingers.draw(&lb);
    try r.recognise(&lb, Fingers.connectivity, .mos, Fingers.channel, &Fingers.terminals, &.{});
    try testing.expectEqual(@as(u32, 2), r.devices.len());
    try testing.expectEqualSlices(PolyId, &.{ r.of(f.channel[0]), r.of(f.channel[1]) }, r.devices.marker.items);
    const first = r.devices.terminalsOf(did(0));
    const second = r.devices.terminalsOf(did(1));
    try testing.expect(rolesEql(first.roles, &.{ .gate, .source, .drain }));
    const n = struct {
        fn of(run: *const Run, h: Handle) NetId {
            return run.nets.netOf(run.of(h));
        }
    }.of;
    try testing.expectEqualSlices(NetId, &.{ n(&r, f.gate[0]), n(&r, f.active[0]), n(&r, f.active[1]) }, first.nets);
    try testing.expectEqualSlices(NetId, &.{ n(&r, f.gate[1]), n(&r, f.active[1]), n(&r, f.active[2]) }, second.nets);
    try testing.expectEqual(first.nets[2], second.nets[1]);
    try expectParams(&.{
        .{ .width, .{ .length = 200 } },
        .{ .length, .{ .length = 50 } },
        .{ .fingers, .{ .count = 1 } },
        .{ .area, .{ .area = 50 * 200 } },
        .{ .perimeter, .{ .length = 2 * (50 + 200) } },
        .{ .source_area, .{ .area_share = .{ .area = 40_000, .ways = 1 } } },
        .{ .source_perimeter, .{ .length_share = .{ .length = 800, .ways = 1 } } },
        .{ .drain_area, .{ .area_share = .{ .area = 70_000, .ways = 2 } } },
        .{ .drain_perimeter, .{ .length_share = .{ .length = 1100, .ways = 2 } } },
    }, r.devices.paramsOf(did(0)));
}

test "a bjt recogniser names its three terminals base emitter collector" {
    // Oracle: construct-from-answer. A bipolar's terminals follow the
    // recogniser's order and are named, not numbered.
    const spec: nl.NetlistSpec = .{ .nets = 3, .devices = &.{.{ .kind = .bjt, .model = "npn", .terminals = &.{ .{ .role = .base, .net = 0 }, .{ .role = .emitter, .net = 1 }, .{ .role = .collector, .net = 2 } } }} };
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, spec, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    var table: DeviceTable = .{};
    defer table.deinit(gpa);
    try topology.recogniseInto(gpa, &case.store, &nets, &case.recognition, &table);
    try testing.expectEqual(@as(u32, 1), table.len());
    const t = table.terminalsOf(did(0));
    try testing.expect(rolesEql(t.roles, &.{ .base, .emitter, .collector }));
    for (t.nets, 0..) |n, k| try testing.expectEqual(nets.netOf(case.expected_net_polys[k][0]), n);
}

test "a resistor recogniser gives its two terminals interchangeable pins" {
    // Oracle: construct-from-answer. Both terminals are pins (the variant is
    // the claim, not the index), on the two nets the spec wired.
    const spec: nl.NetlistSpec = .{ .nets = 2, .devices = &.{.{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 0 }, .{ .role = .{ .pin = 1 }, .net = 1 } } }} };
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var case = try nl.layoutFromNetlist(gpa, spec, .{}, &strings);
    defer case.deinit(gpa);
    var nets: NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &case.store, &case.connectivity, &nets);
    var table: DeviceTable = .{};
    defer table.deinit(gpa);
    try topology.recogniseInto(gpa, &case.store, &nets, &case.recognition, &table);
    try testing.expectEqual(@as(u32, 1), table.len());
    const t = table.terminalsOf(did(0));
    try testing.expectEqual(@as(usize, 2), t.roles.len);
    for (t.roles) |role| try testing.expect(role == .pin);
    for (t.nets, 0..) |n, k| try testing.expectEqual(nets.netOf(case.expected_net_polys[k][0]), n);
    try testing.expect(t.nets[0] != t.nets[1]);
}

test "a resistor body measures its length between its ends" {
    // Oracle: construct-from-answer, F16. A body 1000 by 200 with an end
    // abutting each short side: L 1000 along it and W 200 across, either way
    // round; area 200 000, perimeter 2400; the recogniser's sheet carried.
    const along_x = [_][4]i64{ .{ 0, 0, 1000, 200 }, .{ -300, 0, 0, 200 }, .{ 1000, 0, 1300, 200 } };
    var along_y: [3][4]i64 = undefined;
    for (&along_y, along_x) |*s, a| s.* = .{ a[1], a[0], a[3], a[2] };
    const value: ingest.deck.DeviceValue = .{ .sheet_ohm_sq = 100.0 };
    for ([_][3][4]i64{ along_x, along_y }) |rs| {
        var r: Run = .{};
        defer r.deinit();
        var lb = LayoutBuilder.init(2);
        defer lb.deinit(gpa);
        _ = try lb.rect(gpa, 0, rs[0][0], rs[0][1], rs[0][2], rs[0][3]);
        for (rs[1..]) |q| _ = try lb.rect(gpa, 1, q[0], q[1], q[2], q[3]);
        try r.recognise(&lb, .{ .conductors = &.{lid(1)}, .intra_layer_touch = true }, .resistor, 0, &.{ lid(1), lid(1) }, &.{value});
        try testing.expectEqual(@as(u32, 1), r.devices.len());
        try expectParams(&.{
            .{ .width, .{ .length = 200 } },
            .{ .length, .{ .length = 1000 } },
            .{ .area, .{ .area = 200_000 } },
            .{ .perimeter, .{ .length = 2400 } },
        }, r.devices.paramsOf(did(0)));
        try testing.expectEqual(@as(?f64, 100.0), r.devices.value.items[0].sheet_ohm_sq);
    }
}

test "a marker with a hole is one device measured without the hole" {
    // Oracle: construct-from-answer, F85. A ring 0..2000 with a 200 wall:
    // area 2000² - 1600² = 1 440 000, edge 4 · 2000 + 4 · 1600 = 14 400; the
    // hole row is part of the ring and no second marker.
    var r: Run = .{};
    defer r.deinit();
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, 0, 0, 0, 2000, 2000);
    _ = try lb.shape(gpa, 0, testgen.shapes.hole(200, 200, 1800, 1800));
    _ = try lb.rect(gpa, 1, 0, 900, 200, 1100);
    _ = try lb.rect(gpa, 2, 1800, 900, 2000, 1100);
    try r.recognise(&lb, .{ .conductors = &.{ lid(1), lid(2) } }, .diode, 0, &.{ lid(1), lid(2) }, &.{});
    try testing.expectEqual(@as(usize, 0), r.devices.refused_marker.items.len);
    try testing.expectEqual(@as(u32, 1), r.devices.len());
    try expectParams(&.{ .{ .area, .{ .area = 1_440_000 } }, .{ .perimeter, .{ .length = 14_400 } } }, r.devices.paramsOf(did(0)));
}

test "a bipolar measures its emitter and a split source is not measured" {
    // Oracle: construct-from-answer, F16. Three 400 pads 800 apart as base,
    // emitter, collector: the emitter is 160 000 and 1600. A source drawn in
    // two touching halves is one terminal but no one polygon: unmeasured.
    {
        var r: Run = .{};
        defer r.deinit();
        var lb = LayoutBuilder.init(4);
        defer lb.deinit(gpa);
        _ = try lb.rect(gpa, 0, 200, 0, 1800, 400);
        for (0..3) |k| {
            const x: i64 = 800 * @as(i64, @intCast(k));
            _ = try lb.rect(gpa, @intCast(k + 1), x, 0, x + 400, 400);
        }
        try r.recognise(&lb, .{ .conductors = &.{ lid(1), lid(2), lid(3) } }, .bjt, 0, &.{ lid(1), lid(2), lid(3) }, &.{});
        try testing.expectEqual(@as(u32, 1), r.devices.len());
        const p = r.devices.paramsOf(did(0));
        try expectParams(&.{ .{ .emitter_area, .{ .area = 160_000 } }, .{ .emitter_perimeter, .{ .length = 1600 } } }, .{ .names = p.names[2..], .measures = p.measures[2..] });
    }
    var r: Run = .{};
    defer r.deinit();
    var lb = LayoutBuilder.init(4);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, Fingers.channel, 200, 0, 250, 200);
    _ = try lb.rect(gpa, Fingers.poly, 200, -50, 250, 250);
    _ = try lb.rect(gpa, Fingers.active, 0, 0, 100, 200);
    _ = try lb.rect(gpa, Fingers.active, 100, 0, 200, 200);
    _ = try lb.rect(gpa, Fingers.active, 250, 0, 600, 200);
    try r.recognise(&lb, Fingers.connectivity, .mos, Fingers.channel, &Fingers.terminals, &.{});
    try testing.expectEqual(@as(u32, 1), r.devices.len());
    const names = r.devices.paramsOf(did(0)).names;
    try testing.expect(std.mem.indexOfScalar(DeviceParam, names, .source_area) == null);
    try testing.expect(std.mem.indexOfScalar(DeviceParam, names, .drain_area) != null);
}

test "a channel abutting its split diffusion passes the conduction guard" {
    // Oracle: construct-from-answer. Each channel only abuts its flanking
    // diffusion along an edge and overlaps no conductor area on the
    // source/drain layer; its overlap with the gate is legal.
    var lb = LayoutBuilder.init(4);
    defer lb.deinit(gpa);
    _ = try Fingers.draw(&lb);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const model = [1]geom.StrId{try strings.intern(gpa, "nch")};
    const recognition: DeviceRecognition = .{ .kind = &.{.mos}, .marker = &.{lid(Fingers.channel)}, .terminal_start = &.{ 0, 3 }, .terminal = &Fingers.terminals, .model = &model };
    var diag: topology.channel.ChannelDiagnostic = .none;
    try topology.refuseConductingChannels(gpa, &store, &Fingers.connectivity, &recognition, &diag);
}

test "a channel over live conductor area is refused naming the polygon" {
    // Oracle: construct-from-answer. One diffusion rectangle spanning the
    // channel is the silent source/drain short: refused naming the marker
    // layer, the diffusion layer, and the lowest row under the overlap
    // (not the stray marker, row 0 of its layer, over nothing).
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const stray = try lb.rect(gpa, 0, 5_000, 0, 5_050, 200);
    const ch = try lb.rect(gpa, 0, 200, 0, 250, 200);
    _ = try lb.rect(gpa, 1, 200, -50, 250, 250);
    const df = try lb.rect(gpa, 2, 0, 0, 500, 200);
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const model = [1]geom.StrId{try strings.intern(gpa, "nch")};
    const recognition: DeviceRecognition = .{ .kind = &.{.mos}, .marker = &.{lid(0)}, .terminal_start = &.{ 0, 3 }, .terminal = &.{ lid(1), lid(2), lid(2) }, .model = &model };
    var diag: topology.channel.ChannelDiagnostic = .none;
    try testing.expectError(error.ConductingChannel, topology.refuseConductingChannels(gpa, &store, &.{ .conductors = &.{ lid(1), lid(2) }, .intra_layer_touch = true }, &recognition, &diag));
    const c = diag.conducting;
    try testing.expectEqual(lid(0), c.marker);
    try testing.expectEqual(lid(2), c.conductor);
    try testing.expect(c.poly != ids.of(stray));
    try testing.expectEqual(@min(@backingInt(ids.of(ch)), @backingInt(ids.of(df))), @backingInt(c.poly));
}

test "a non-octilinear source/drain layer is refused, not split" {
    // Oracle: construct-from-answer. A triangle whose sides rise 200 over
    // 250 cannot be intersected exactly: refused naming the polygon.
    var diag: topology.channel.ChannelDiagnostic = .none;
    var channel: PolyId = undefined;
    var diff: PolyId = undefined;
    try testing.expectError(error.Geometry, channelGuard(&.{ 0, 500, 250 }, &.{ 0, 0, 200 }, &diag, &channel, &diff));
    try testing.expect(std.meta.eql(diag, .{ .geometry = .{ .not_octilinear = diff } }));
}

test "a 45-degree source/drain layer is intersected" {
    // Oracle: hand-derived overlap (H12). A 45-degree triangle reaching
    // under the channel (apex (250, 250)) is a conducting channel; one whose
    // apex stops at x 150 is clean.
    var diag: topology.channel.ChannelDiagnostic = .none;
    var channel: PolyId = undefined;
    var diff: PolyId = undefined;
    try testing.expectError(error.ConductingChannel, channelGuard(&.{ 0, 500, 250 }, &.{ 0, 0, 250 }, &diag, &channel, &diff));
    try testing.expectEqual(lid(2), diag.conducting.conductor);
    try testing.expectEqual(@min(@backingInt(channel), @backingInt(diff)), @backingInt(diag.conducting.poly));
    try channelGuard(&.{ 0, 150, 0 }, &.{ 0, 150, 150 }, &diag, &channel, &diff);
}

test "a channel whose overlap with a 45-degree diffusion is slanted is refused, not a panic" {
    // Oracle: hand-derived overlap. The channel 200..300 x 0..250 under the
    // triangle (0,0) (500,0) (250,250) overlaps it in a region bounded by
    // the slope y = 500 - x for x in 250..300: a 45-degree overlap. Rust cut
    // that overlap into rectangles because the marker layer is rectilinear,
    // and panicked; it is a conducting channel naming the lower of the two
    // rows.
    var lb = LayoutBuilder.init(3);
    defer lb.deinit(gpa);
    const ch = try lb.rect(gpa, 0, 200, 0, 300, 250);
    _ = try lb.rect(gpa, 1, 200, -50, 300, 300);
    const df = try lb.push(gpa, 2, &.{ 0, 500, 250 }, &.{ 0, 0, 250 });
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const model = [1]geom.StrId{try strings.intern(gpa, "nch")};
    const recognition: DeviceRecognition = .{ .kind = &.{.mos}, .marker = &.{lid(0)}, .terminal_start = &.{ 0, 3 }, .terminal = &.{ lid(1), lid(2), lid(2) }, .model = &model };
    var diag: topology.channel.ChannelDiagnostic = .none;
    try testing.expectError(error.ConductingChannel, topology.refuseConductingChannels(gpa, &store, &.{ .conductors = &.{ lid(1), lid(2) }, .intra_layer_touch = true }, &recognition, &diag));
    try testing.expectEqual(@min(@backingInt(ids.of(ch)), @backingInt(ids.of(df))), @backingInt(diag.conducting.poly));
}
