//! The check halves of two derived-layer tests whose layer halves are in
//! tests/ingest/derive.zig: nets and devices extracted from a store read
//! back through the deck. Ported from tests/derived_layers.rs
//! (`a_ring_on_a_derived_layer_keeps_its_hole_for_net_extraction`,
//! `a_sky130_pw2nd_diode_has_its_anode_on_the_substrate`).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const check = @import("check");
const topology = check.topology;
const testgen = @import("testgen");
const paths = @import("paths");
const fx = @import("../ingest/layout_fixture.zig");
const gpa = testing.allocator;

/// A parsed deck, its strings and its arena.
const Deck = struct {
    state: *std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    deck: ingest.deck.Deck,

    fn init(text: []const u8) !Deck {
        const state = try gpa.create(std.heap.ArenaAllocator);
        state.* = .init(gpa);
        var d: Deck = .{ .state = state, .deck = undefined };
        d.deck = try fx.parseDeck(state.allocator(), text, &d.strings);
        return d;
    }

    fn deinit(d: *Deck) void {
        d.strings.deinit(gpa);
        d.state.deinit();
        gpa.destroy(d.state);
    }

    fn id(d: *const Deck, name: []const u8) LayerId {
        return d.deck.layers.id(&d.strings, name).?;
    }

    /// `rects` (`layer, xlo, ylo, xhi, yhi`) written as GDSII and read back
    /// through this deck into `r`, derived layers computed.
    fn roundTrip(d: *const Deck, r: *fx.Read, rects: []const struct { LayerId, i64, i64, i64, i64 }) !void {
        var lb: testgen.shapes.LayoutBuilder = .init(@intCast(d.deck.layers.len()));
        defer lb.deinit(gpa);
        for (rects) |rc| _ = try lb.rect(gpa, @backingInt(rc[0]), rc[1], rc[2], rc[3], rc[4]);
        var base: GeometryStore = .empty;
        defer base.deinit(gpa);
        var ids: testgen.shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &base, &ids);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try testgen.gds.writeStore(gpa, &base, &d.deck.layers, "TOP", &bytes);
        try r.run(bytes.items, &d.deck.layers, .reject);
    }
};

// ---- private ----

/// The row on `layer` whose box starts at `xlo` (or ends at `xhi`).
fn rowAt(store: *const GeometryStore, layer: LayerId, xlo: ?i64, xhi: ?i64) PolyId {
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |row| {
        const b = store.polyBbox(@fromBackingInt(@intCast(row)));
        if ((xlo == null or b.xlo == xlo.?) and (xhi == null or b.xhi == xhi.?)) return @fromBackingInt(@intCast(row));
    }
    unreachable; // the fixture draws it
}

test "a ring on a derived layer keeps its hole for net extraction" {
    // Oracle: construct-from-answer. Four diffusion bands closing into a
    // guard ring become one derived polygon with a hole; two islands drawn
    // inside the hole touch nothing, so the layer is three nets (the Philis
    // session's report: the hole extracted as solid merged every inner net).
    var d: Deck = try .init(
        \\grid 1nm
        \\layer diff = gds(2, 0)
        \\layer poly = gds(3, 0)
        \\layer sd = diff not poly
        \\connect conductors [sd]
        \\connect touch_within_layer
        \\
    );
    defer d.deinit();
    const diff = d.id("diff");
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &.{
        .{ diff, 0, 0, 2000, 200 },    .{ diff, 0, 1800, 2000, 2000 },
        .{ diff, 0, 200, 200, 1800 },  .{ diff, 1800, 200, 2000, 1800 },
        .{ diff, 500, 500, 700, 700 }, .{ diff, 1200, 1200, 1400, 1400 },
    });
    var nets: topology.NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &r.store, &d.deck.connectivity, &nets);
    const sd = d.id("sd");
    const a = nets.netOf(rowAt(&r.store, sd, 500, null));
    const b = nets.netOf(rowAt(&r.store, sd, 1200, null));
    const ring = nets.netOf(rowAt(&r.store, sd, null, 2000));
    try testing.expect(a != b);
    try testing.expect(a != ring);
    try testing.expect(b != ring);
}

test "a sky130 pw2nd diode has its anode on the substrate" {
    // Oracle: construct-from-answer, on the shipped sky130 deck. A 1 µm × 1 µm
    // n+ diffusion under `areaid.diode` is a `pw2nd_05v5` diode: its anode is
    // the substrate, which the p-tap beside it joins through `psub_tie`, and
    // its area and perimeter are the junction's, 1 µm² and 4 µm. A p-tap in
    // deep n-well sits in an isolated p-well, off the substrate net.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/pdks/sky130.deck", .{paths.root});
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena.allocator(), .unlimited);
    var d: Deck = try .init(text);
    defer d.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try d.roundTrip(&r, &.{
        .{ d.id("diff"), 0, 0, 1_000, 1_000 },          .{ d.id("nsdm"), -200, -200, 1_200, 1_200 },
        .{ d.id("areaid_diode"), 0, 0, 1_000, 1_000 },  .{ d.id("tap"), 2_000, 0, 2_500, 1_000 },
        .{ d.id("psdm"), 1_900, -100, 2_600, 1_100 },   .{ d.id("dnwell"), 10_000, 0, 16_000, 6_000 },
        .{ d.id("tap"), 12_000, 2_000, 12_500, 3_000 }, .{ d.id("psdm"), 11_900, 1_900, 12_600, 3_100 },
    });
    var nets: topology.NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &r.store, &d.deck.connectivity, &nets);
    var devices: topology.DeviceTable = .{};
    defer devices.deinit(gpa);
    try topology.recogniseInto(gpa, &r.store, &nets, &d.deck.devices, &devices);
    try testing.expectEqual(@as(u32, 1), devices.len());
    try testing.expectEqual(d.strings.get("sky130_fd_pr__diode_pw2nd_05v5"), devices.model.items[0]);
    const t = devices.terminalsOf(@fromBackingInt(@intCast(0))).nets;
    const substrate = nets.netOf(rowAt(&r.store, d.id("ptap"), 2_000, null));
    try testing.expectEqual(substrate, t[0]);
    try testing.expectEqual(nets.netOf(rowAt(&r.store, d.id("nsd"), 0, null)), t[1]);
    try testing.expect(t[0] != t[1]);
    try testing.expect(nets.netOf(rowAt(&r.store, d.id("ptap"), 12_000, null)) != t[0]);
    const params = devices.paramsOf(@fromBackingInt(@intCast(0)));
    try testing.expectEqual(@as(usize, 2), params.names.len);
    try testing.expect(params.names[0] == .area and params.measures[0].area == 1_000_000);
    try testing.expect(params.names[1] == .perimeter and params.measures[1].length == 4_000);
}
