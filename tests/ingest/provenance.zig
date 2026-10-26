//! Net labels: their ordering contract and their binding to polygons.
//! Ported from crates/ingest/tests/provenance.rs.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const testgen = @import("testgen");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const Label = ingest.provenance.Label;

test "labels come back ascending by polygon whatever order they were attached in" {
    // Oracle: law. `labels` is documented as ascending by `PolyId`, which is
    // what lets `topology` bind labels deterministically without sorting.
    // That ordering must be a property of the table rather than of the order
    // labels happened to be attached in, so they go on in scrambled order.
    const gpa = testing.allocator;
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    var attached = [_]ingest.provenance.Label{
        .{ .poly = @fromBackingInt(5), .name = try strings.intern(gpa, "vdd") },
        .{ .poly = @fromBackingInt(1), .name = try strings.intern(gpa, "clk") },
        .{ .poly = @fromBackingInt(7), .name = try strings.intern(gpa, "vss") },
        .{ .poly = @fromBackingInt(2), .name = try strings.intern(gpa, "dout") },
    };
    for (attached) |l| try provenance.label(gpa, l.poly, l.name);
    std.mem.sortUnstable(ingest.provenance.Label, &attached, {}, struct {
        fn less(_: void, a: ingest.provenance.Label, b: ingest.provenance.Label) bool {
            return @backingInt(a.poly) < @backingInt(b.poly);
        }
    }.less);
    try testing.expectEqualSlices(ingest.provenance.Label, &attached, provenance.labels());
}

test "a label binds to its split flank and one on the channel refuses the load" {
    // Oracle: construct-from-answer. The conductor arrives as the split
    // source/drain layer, two rectangles flanking a channel gap at
    // `(200,0)-(250,200)`, so where each label lands decides its polygon
    // before anything runs. The pin on the channel is a refusal, not a
    // binding: the channel carries no extracted net.
    const gpa = testing.allocator;
    const active: LayerId = @fromBackingInt(0);
    const text: LayerId = @fromBackingInt(1);
    const connectivity: ingest.deck.Connectivity = .{ .conductors = &.{active}, .intra_layer_touch = true, .label_layer = &.{text}, .label_names = &.{active} };
    var lb: testgen.shapes.LayoutBuilder = .init(2);
    defer lb.deinit(gpa);
    const source = try lb.rect(gpa, 0, 0, 0, 200, 200);
    const drain = try lb.rect(gpa, 0, 250, 0, 500, 200);
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const s_name = try strings.intern(gpa, "VSS");
    const d_name = try strings.intern(gpa, "Y");
    var unplaced: ingest.provenance.PlacedLabel = undefined;

    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    try provenance.placeLabel(gpa, .{ .x = 100, .y = 100, .layer = text, .name = s_name });
    try provenance.placeLabel(gpa, .{ .x = 300, .y = 100, .layer = text, .name = d_name });
    const want = [_]Label{ .{ .poly = ids.of(source), .name = s_name }, .{ .poly = ids.of(drain), .name = d_name } };
    try ingest.resolveLabels(gpa, &provenance, &store, &connectivity, &unplaced);
    try testing.expectEqualSlices(Label, &want, provenance.labels());
    // F35: binding again rebinds; it does not bind every label a second time.
    try ingest.resolveLabels(gpa, &provenance, &store, &connectivity, &unplaced);
    try testing.expectEqualSlices(Label, &want, provenance.labels());

    var channel: ingest.Provenance = .{};
    defer channel.deinit(gpa);
    try channel.placeLabel(gpa, .{ .x = 225, .y = 100, .layer = text, .name = try strings.intern(gpa, "pin_on_channel") });
    try testing.expectError(error.Unplaced, ingest.resolveLabels(gpa, &channel, &store, &connectivity, &unplaced));
    try testing.expectEqual(text, unplaced.layer);
    try testing.expectEqual([2]i64{ 225, 100 }, [2]i64{ unplaced.x, unplaced.y });
}

test "label binding matches a brute-force scan" {
    // Oracle: brute force. Random overlapping rectangles on two conductors
    // paired with one text layer, in row order; each label binds where a scan
    // of rows, then polygons by id, first finds it inside (edge inclusive).
    const gpa = testing.allocator;
    const text: LayerId = @fromBackingInt(2);
    const conductors = [_]LayerId{ @fromBackingInt(0), @fromBackingInt(1) };
    const connectivity: ingest.deck.Connectivity = .{ .conductors = &conductors, .label_layer = &.{ text, text }, .label_names = &conductors };
    var rng: testgen.Rng = .init(11);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var names: [60]geom.StrId = undefined;
    for (&names, 0..) |*n, i| {
        var buf: [4]u8 = undefined;
        n.* = try strings.intern(gpa, try std.fmt.bufPrint(&buf, "{d}", .{i}));
    }
    var unplaced: ingest.provenance.PlacedLabel = undefined;
    for (0..30) |_| {
        var lb: testgen.shapes.LayoutBuilder = .init(3);
        defer lb.deinit(gpa);
        const shapes = rng.range(0, 40);
        for (0..@intCast(shapes)) |_| {
            const layer: u16 = @intFromBool(rng.below(2) == 1);
            const x = rng.range(0, 1000);
            const y = rng.range(0, 1000);
            _ = try lb.rect(gpa, layer, x, y, x + rng.range(1, 300), y + rng.range(1, 300));
        }
        var store: geom.GeometryStore = .empty;
        defer store.deinit(gpa);
        var ids: testgen.shapes.Ids = .{};
        defer ids.deinit(gpa);
        try lb.finish(gpa, &store, &ids);

        var bound: ingest.Provenance = .{};
        defer bound.deinit(gpa);
        var want: std.ArrayList(Label) = .empty;
        defer want.deinit(gpa);
        for (names) |name| {
            const p: geom.Point = .{ .x = rng.range(0, 1300), .y = rng.range(0, 1300) };
            const hit: ?PolyId = scan: for (conductors) |layer| {
                const rows = store.polysOnLayer(layer);
                for (rows.start..rows.end) |row| {
                    const poly: PolyId = @fromBackingInt(@intCast(row));
                    if (store.polyContainsPoint(poly, p)) break :scan poly;
                }
            } else null;
            const placed: ingest.provenance.PlacedLabel = .{ .x = p.x, .y = p.y, .layer = text, .name = name };
            if (hit) |poly| {
                try bound.placeLabel(gpa, placed);
                try want.append(gpa, .{ .poly = poly, .name = name });
            } else {
                var alone: ingest.Provenance = .{};
                defer alone.deinit(gpa);
                try alone.placeLabel(gpa, placed);
                try testing.expectError(error.Unplaced, ingest.resolveLabels(gpa, &alone, &store, &connectivity, &unplaced));
            }
        }
        try ingest.resolveLabels(gpa, &bound, &store, &connectivity, &unplaced);
        std.mem.sort(Label, want.items, {}, struct {
            fn less(_: void, a: Label, b: Label) bool {
                return @backingInt(a.poly) < @backingInt(b.poly);
            }
        }.less);
        try testing.expectEqualSlices(Label, want.items, bound.labels());
    }
}
