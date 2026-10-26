//! Layouts emitted from a netlist, so extraction has to give the netlist
//! back. In: a `NetlistSpec` (nets, devices with their terminals' roles and
//! nets) and a `Floorplan`. Out: a `NetlistCase`: the store, the deck
//! fragments that extract it, and the expected nets and devices. Ported
//! from crates/testgen/src/netlist.rs.
//!
//! A rail-and-stub floorplan: net `n` is a rail in its own y band, a device
//! a column of stubs, each stub reaching its rail only through a via cut.
//! Bands never touch and columns never share x, so every adjacency is
//! decided by construction. Every distinct role gets its own conductor and
//! cut layer (recognition identifies terminal `k` by layer): layer 0 holds
//! the rails, layer 1 the markers, then each role a conductor and a cut, in
//! order of first appearance.
//!
//! Contents:
//! - `pub const TerminalSpec = struct { role: TerminalRole, net: u32 }`
//! - `pub const DeviceSpec = struct`, `pub const NetlistSpec = struct`, `pub const Floorplan = struct`
//! - `pub const NetlistLayers = struct`, `NetlistLayers.layerOf(l: *const NetlistLayers, role: TerminalRole) LayerId`
//! - `pub const ExpectedDevice = struct`
//! - `pub const NetlistCase = struct`, `NetlistCase.deinit(c: *NetlistCase, gpa: Allocator) void`
//! - `pub fn layoutFromNetlist(gpa: Allocator, spec: NetlistSpec, plan: Floorplan, strings: *StrTable) Allocator.Error!NetlistCase`
//! - `pub fn roleEql(a: TerminalRole, b: TerminalRole) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const deck = @import("ingest").deck;
const Connectivity = deck.Connectivity;
const DeviceKind = deck.DeviceKind;
const DeviceRecognition = deck.DeviceRecognition;
const TerminalRole = @import("check").topology.TerminalRole;
const shapes = @import("shapes.zig");
const Handle = shapes.Handle;
const Ids = shapes.Ids;
const LayoutBuilder = shapes.LayoutBuilder;

pub const TerminalSpec = struct { role: TerminalRole, net: u32 };

/// One device to realise.
pub const DeviceSpec = struct {
    kind: DeviceKind,
    /// Interned into the caller's table.
    model: []const u8,
    /// In recogniser order; `net` indexes `NetlistSpec.nets`.
    terminals: []const TerminalSpec,
};

/// The structure the layout must extract back to.
pub const NetlistSpec = struct {
    /// Every net gets a rail, floating ones included.
    nets: u32,
    /// One column each, left to right.
    devices: []const DeviceSpec,
};

/// How far apart the floorplan's features sit.
pub const Floorplan = struct {
    rail_height: i64 = 200,
    /// Must exceed `rail_height`, or two nets touch.
    band_pitch: i64 = 1_000,
    column_width: i64 = 300,
    /// Must exceed `column_width`, or two devices' stubs touch.
    column_pitch: i64 = 1_000,
    /// Must fit inside a stub and inside the rail height.
    cut_size: i64 = 100,
};

/// Which layer is which; ids dense in `0..count`. `roles[i]`'s stubs are on
/// `role_layer[i]`, joined to the rails by cuts on `cut_layer[i]`.
pub const NetlistLayers = struct {
    rail: LayerId,
    marker: LayerId,
    roles: []const TerminalRole,
    role_layer: []const LayerId,
    cut_layer: []const LayerId,
    count: u16,

    /// The conductor layer of a role's stubs; asserts the role is present.
    pub fn layerOf(l: *const NetlistLayers, role: TerminalRole) LayerId {
        for (l.roles, l.role_layer) |r, layer| if (roleEql(r, role)) return layer;
        unreachable;
    }
};

/// The device the layout says is there.
pub const ExpectedDevice = struct {
    kind: DeviceKind,
    model: StrId,
    /// Also fixes the expected `DeviceId` order.
    marker: PolyId,
    /// In spec order, `net` indexing `NetlistCase.expected_net_polys`.
    terminals: []const TerminalSpec,
};

/// A layout, the deck fragments that extract it, and the answer. The deck
/// slices and expectations live in `arena`; `store` and `ids` in the `gpa`
/// given to `layoutFromNetlist`.
pub const NetlistCase = struct {
    arena: std.heap.ArenaAllocator,
    store: GeometryStore,
    ids: Ids,
    layers: NetlistLayers,
    /// Rails and role layers conduct, the cuts join each role layer to the
    /// rails, and touching does not connect, so a broken via splits a net.
    connectivity: Connectivity,
    /// One recogniser row per device, in spec order.
    recognition: DeviceRecognition,
    /// Every polygon on net `n`, ascending.
    expected_net_polys: []const []const PolyId,
    /// In spec order.
    expected_devices: []const ExpectedDevice,

    pub fn deinit(c: *NetlistCase, gpa: Allocator) void {
        c.store.deinit(gpa);
        c.ids.deinit(gpa);
        c.arena.deinit();
    }
};

/// Emits a layout realising `spec`, interning every model into `strings`.
/// Deterministic. Asserts at least one net, every device has terminals on
/// nets below `spec.nets`, and `plan` keeps its own rules.
pub fn layoutFromNetlist(gpa: Allocator, spec: NetlistSpec, plan: Floorplan, strings: *StrTable) Allocator.Error!NetlistCase {
    assert(spec.nets > 0);
    assert(plan.band_pitch > plan.rail_height and plan.column_pitch > plan.column_width);
    assert(plan.cut_size < plan.rail_height and plan.cut_size < plan.column_width);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const layers = try assignLayers(a, spec);
    var lb = LayoutBuilder.init(layers.count);
    defer lb.deinit(gpa);
    // Rails first, one per net, each in its own band.
    const width = plan.column_pitch * (@as(i64, @intCast(spec.devices.len)) + 1);
    const net_handles = try a.alloc(std.ArrayList(Handle), spec.nets);
    for (net_handles, 0..) |*h, n| {
        const y = @as(i64, @intCast(n)) * plan.band_pitch;
        h.* = .empty;
        try h.append(a, try lb.rect(gpa, @backingInt(layers.rail), 0, y, width, y + plan.rail_height));
    }
    // Then one column per device: a stub per terminal over its net's rail,
    // a cut centred in it, and a marker spanning every band.
    const markers = try a.alloc(Handle, spec.devices.len);
    for (spec.devices, markers, 0..) |device, *marker, column| {
        assert(device.terminals.len > 0);
        const x = plan.column_pitch * @as(i64, @intCast(column)) + @divTrunc(plan.column_pitch, 2);
        for (device.terminals) |t| {
            assert(t.net < spec.nets);
            const slot = for (layers.roles, 0..) |r, i| {
                if (roleEql(r, t.role)) break i;
            } else unreachable;
            const y = @as(i64, t.net) * plan.band_pitch;
            try net_handles[t.net].append(a, try lb.rect(gpa, @backingInt(layers.role_layer[slot]), x, y, x + plan.column_width, y + plan.rail_height));
            const cx = x + @divTrunc(plan.column_width, 2) - @divTrunc(plan.cut_size, 2);
            const cy = y + @divTrunc(plan.rail_height, 2) - @divTrunc(plan.cut_size, 2);
            _ = try lb.rect(gpa, @backingInt(layers.cut_layer[slot]), cx, cy, cx + plan.cut_size, cy + plan.cut_size);
        }
        const top = @as(i64, spec.nets) * plan.band_pitch;
        marker.* = try lb.rect(gpa, @backingInt(layers.marker), x, 0, x + plan.column_width, top);
    }
    var case: NetlistCase = .{
        .arena = undefined,
        .store = .empty,
        .ids = .{},
        .layers = layers,
        .connectivity = undefined,
        .recognition = undefined,
        .expected_net_polys = undefined,
        .expected_devices = undefined,
    };
    errdefer case.store.deinit(gpa);
    errdefer case.ids.deinit(gpa);
    try lb.finish(gpa, &case.store, &case.ids);
    const expected = try a.alloc([]const PolyId, spec.nets);
    for (expected, net_handles) |*e, h| e.* = try sortedIds(a, &case.ids, h.items);
    case.expected_net_polys = expected;
    const devices = try a.alloc(ExpectedDevice, spec.devices.len);
    for (devices, spec.devices, markers) |*d, s, m| d.* = .{ .kind = s.kind, .model = try strings.intern(gpa, s.model), .marker = case.ids.of(m), .terminals = s.terminals };
    case.expected_devices = devices;
    const conductors = try a.alloc(LayerId, layers.role_layer.len + 1);
    conductors[0] = layers.rail;
    @memcpy(conductors[1..], layers.role_layer);
    const connects = try a.alloc([2]LayerId, layers.role_layer.len);
    for (connects, layers.role_layer) |*c, role| c.* = .{ layers.rail, role };
    // Touching off deliberately: every join here goes through a via.
    case.connectivity = .{ .conductors = conductors, .via_cut = layers.cut_layer, .via_connects = connects, .intra_layer_touch = false };
    case.recognition = try recognitionOf(gpa, a, spec, &case.layers, strings);
    case.arena = arena;
    return case;
}

pub fn roleEql(a: TerminalRole, b: TerminalRole) bool {
    return std.meta.eql(a, b);
}

// ---- private ----

/// A conductor and a cut layer for every distinct role in the spec: rail
/// 0, marker 1, then each role's conductor and cut interleaved.
fn assignLayers(arena: Allocator, spec: NetlistSpec) Allocator.Error!NetlistLayers {
    var roles: std.ArrayList(TerminalRole) = .empty;
    for (spec.devices) |d| for (d.terminals) |t| {
        const seen = for (roles.items) |r| {
            if (roleEql(r, t.role)) break true;
        } else false;
        if (!seen) try roles.append(arena, t.role);
    };
    const role_layer = try arena.alloc(LayerId, roles.items.len);
    const cut_layer = try arena.alloc(LayerId, roles.items.len);
    for (role_layer, cut_layer, 0..) |*r, *c, i| {
        r.* = @fromBackingInt(@intCast(2 + 2 * i));
        c.* = @fromBackingInt(@intCast(3 + 2 * i));
    }
    return .{
        .rail = @fromBackingInt(0),
        .marker = @fromBackingInt(1),
        .roles = roles.items,
        .role_layer = role_layer,
        .cut_layer = cut_layer,
        .count = @intCast(2 + 2 * roles.items.len),
    };
}

/// Handles resolved to rows, ascending.
fn sortedIds(arena: Allocator, ids: *const Ids, handles: []const Handle) Allocator.Error![]const PolyId {
    const out = try arena.alloc(PolyId, handles.len);
    for (out, handles) |*o, h| o.* = ids.of(h);
    std.mem.sortUnstable(PolyId, out, {}, struct {
        fn less(_: void, x: PolyId, y: PolyId) bool {
            return @backingInt(x) < @backingInt(y);
        }
    }.less);
    return out;
}

/// The recogniser table for the emitted layout: one row per device.
fn recognitionOf(gpa: Allocator, arena: Allocator, spec: NetlistSpec, layers: *const NetlistLayers, strings: *StrTable) Allocator.Error!DeviceRecognition {
    const kind = try arena.alloc(DeviceKind, spec.devices.len);
    const marker = try arena.alloc(LayerId, spec.devices.len);
    const model = try arena.alloc(StrId, spec.devices.len);
    const start = try arena.alloc(u32, spec.devices.len + 1);
    var terminal: std.ArrayList(LayerId) = .empty;
    start[0] = 0;
    for (spec.devices, 0..) |d, i| {
        kind[i] = d.kind;
        marker[i] = layers.marker;
        model[i] = try strings.intern(gpa, d.model);
        for (d.terminals) |t| try terminal.append(arena, layers.layerOf(t.role));
        start[i + 1] = @intCast(terminal.items.len);
    }
    return .{ .kind = kind, .marker = marker, .terminal_start = start, .terminal = terminal.items, .model = model };
}

test "assigned layer ids are dense" {
    // Oracle: law. The rail, the marker and a conductor and a cut for each
    // of the six roles (four MOS terminals, two resistor pins) are a
    // permutation of `0..count`: sorted, exactly that range.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec: NetlistSpec = .{ .nets = 4, .devices = &.{
        .{ .kind = .mos, .model = "nch", .terminals = &.{ .{ .role = .gate, .net = 0 }, .{ .role = .source, .net = 1 }, .{ .role = .drain, .net = 2 }, .{ .role = .bulk, .net = 3 } } },
        .{ .kind = .resistor, .model = "res", .terminals = &.{ .{ .role = .{ .pin = 0 }, .net = 2 }, .{ .role = .{ .pin = 1 }, .net = 3 } } },
    } };
    const layers = try assignLayers(arena.allocator(), spec);
    try std.testing.expectEqual(@as(usize, 6), layers.roles.len);
    var all: std.ArrayList(u16) = .empty;
    try all.appendSlice(arena.allocator(), &.{ @backingInt(layers.rail), @backingInt(layers.marker) });
    for (layers.role_layer, layers.cut_layer) |r, c| try all.appendSlice(arena.allocator(), &.{ @backingInt(r), @backingInt(c) });
    std.mem.sortUnstable(u16, all.items, {}, std.sort.asc(u16));
    for (all.items, 0..) |v, i| try std.testing.expectEqual(@as(u16, @intCast(i)), v);
    try std.testing.expectEqual(layers.count, @as(u16, @intCast(all.items.len)));
}
