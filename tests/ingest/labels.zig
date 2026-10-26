//! Labels read through the flattener and bound to the shapes they sit on:
//! inside, on an edge or corner, under a mirror, on an unpaired layer, on no
//! shape, and below the root. Ported from crates/ingest/src/layout.rs's
//! in-file tests.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const fx = @import("layout_fixture.zig");
const fixture = ingest.gds_fixture;
const gpa = testing.allocator;

/// `STRANS` bit 0, from the spec.
const reflect: u16 = 0x8000;

/// The labelling deck, its strings and its arena.
const Labelling = struct {
    state: *std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    deck: ingest.deck.Deck,

    fn init() !Labelling {
        const state = try gpa.create(std.heap.ArenaAllocator);
        state.* = .init(gpa);
        var l: Labelling = .{ .state = state, .deck = undefined };
        l.deck = try fx.labelling(state.allocator(), &l.strings);
        return l;
    }

    fn deinit(l: *Labelling) void {
        l.strings.deinit(gpa);
        l.state.deinit();
        gpa.destroy(l.state);
    }

    /// Reads `cells` and binds their labels into `r`.
    fn bound(l: *Labelling, r: *fx.Read, cells: []const fixture.Cell) !void {
        const bytes = try fixture.library(gpa, cells, 1e-9);
        defer gpa.free(bytes);
        try r.run(bytes, &l.deck.layers, .reject);
        try r.bind(&l.deck.connectivity);
    }

    /// The bound labels of a one-cell `TOP` holding the square and `texts`.
    fn boundTop(l: *Labelling, texts: []const fixture.Text) ![]const []const u8 {
        var r: fx.Read = .{};
        defer r.deinit();
        try l.bound(&r, &.{.{ .name = "TOP", .boundaries = &.{fx.square}, .texts = texts }});
        return r.boundNames(l.state.allocator());
    }
};

// ---- private ----

fn vdd(layer: u16, texttype: u16, x: i32, y: i32) fixture.Text {
    return .{ .layer = layer, .texttype = texttype, .x = x, .y = y, .string = "VDD" };
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a text inside a shape names the net that shape is on" {
    // Oracle: construct-from-answer. The one label is drawn at (200, 200),
    // inside the one 400 square, so it names that polygon.
    var l: Labelling = try .init();
    defer l.deinit();
    try expectNames(&.{"0 VDD"}, try l.boundTop(&.{vdd(68, 5, 200, 200)}));
}

test "a text on a shape's edge or corner still names it" {
    // Oracle: the label binding's documented contract (`label_bind.zig`: "The
    // boundary counts as inside"): each label sits on the square's boundary,
    // so each names polygon 0.
    var l: Labelling = try .init();
    defer l.deinit();
    for ([_][2]i32{ .{ 200, 0 }, .{ 0, 200 }, .{ 400, 200 }, .{ 0, 0 }, .{ 400, 400 } }) |p| {
        try expectNames(&.{"0 VDD"}, try l.boundTop(&.{vdd(68, 5, p[0], p[1])}));
    }
}

test "a text on an unpaired layer is documentation and binds nothing" {
    // Oracle: the label binding's documented contract ("A text on a layer no
    // pairing row names binds nothing"): 68/20 is paired with nothing.
    var l: Labelling = try .init();
    defer l.deinit();
    const note: fixture.Text = .{ .layer = 68, .texttype = 20, .x = 200, .y = 200, .string = "a note" };
    try expectNames(&.{}, try l.boundTop(&.{note}));
}

test "a claimed label on no shape is refused rather than dropped" {
    // Oracle: the label binding's documented contract (`Unplaced` "for a
    // claimed label on no shape"): (9000, 9000) is far from the only square
    // (0..400), so the refusal names that point.
    var l: Labelling = try .init();
    defer l.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try testing.expectError(error.Unplaced, l.bound(&r, &.{.{ .name = "TOP", .boundaries = &.{fx.square}, .texts = &.{vdd(68, 5, 9_000, 9_000)} }}));
    try testing.expectEqual([2]i64{ 9_000, 9_000 }, [2]i64{ r.unplaced.x, r.unplaced.y });
}

test "a label under a mirrored instance moves with the shape it names" {
    // Oracle: hand-derived. The reflection with offset (0, 1000) maps y to
    // 1000 - y: the square to y 600..1000 and the label to (200, 800), inside
    // it, so the label binds polygon 0. A shift of 400 would prove nothing:
    // (200, 200) is a fixed point of y ↦ 400 - y.
    var l: Labelling = try .init();
    defer l.deinit();
    var r: fx.Read = .{};
    defer r.deinit();
    try l.bound(&r, &.{
        .{ .name = "CHILD", .boundaries = &.{fx.square}, .texts = &.{vdd(68, 5, 200, 200)} },
        .{ .name = "TOP", .refs = &.{.{ .cell = "CHILD", .strans = reflect, .y = 1000 }} },
    });
    try expectNames(&.{"0 VDD"}, try r.boundNames(l.state.allocator()));
}

test "a sub-cell label is not placed by default" {
    // Oracle: the documented `LabelDepth`: `top` (root cells only, Calibre's
    // `TEXT DEPTH PRIMARY` default) places no `CHILD` text, and `all` places
    // the one there is.
    var l: Labelling = try .init();
    defer l.deinit();
    const bytes = try fixture.library(gpa, &.{
        .{ .name = "CHILD", .boundaries = &.{fx.square}, .texts = &.{vdd(68, 5, 200, 200)} },
        .{ .name = "TOP", .refs = &.{.{ .cell = "CHILD" }} },
    }, 1e-9);
    defer gpa.free(bytes);
    var top: fx.Read = .{};
    defer top.deinit();
    try top.runAt(bytes, &l.deck.layers, .reject, .top);
    try testing.expectEqual(0, top.provenance.placed.len);
    var all: fx.Read = .{};
    defer all.deinit();
    try all.runAt(bytes, &l.deck.layers, .reject, .all);
    try testing.expectEqual(1, all.provenance.placed.len);
}

test "a label in a keyhole's hole is on no shape, and one on the hole's edge names the outer" {
    // Oracle: the label binding's documented contract ("holes counting as no
    // shape"; "A point on a hole's edge is material"): the keyhole is 0..1000
    // square less 300..700, so (500, 500) is in the hole and refused, and
    // (300, 500) on the hole's edge binds the counter-clockwise outer row.
    var l: Labelling = try .init();
    defer l.deinit();
    const keyhole: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 0, 300, 300, 700, 700, 0, 0, 1000, 1000 }, .ys = &.{ 0, 700, 700, 300, 300, 700, 700, 1000, 1000, 0 } };
    var inside: fx.Read = .{};
    defer inside.deinit();
    try testing.expectError(error.Unplaced, l.bound(&inside, &.{.{ .name = "TOP", .boundaries = &.{keyhole}, .texts = &.{vdd(68, 5, 500, 500)} }}));
    var edge: fx.Read = .{};
    defer edge.deinit();
    try l.bound(&edge, &.{.{ .name = "TOP", .boundaries = &.{keyhole}, .texts = &.{vdd(68, 5, 300, 500)} }});
    try testing.expectEqual(1, edge.provenance.labels().len);
    const ring = edge.store.polyVerts(edge.provenance.labels()[0].poly);
    try testing.expectEqual(geom.ops.Winding.ccw, geom.ops.windingOf(ring.xs, ring.ys).?);
}
