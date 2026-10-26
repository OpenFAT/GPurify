//! Mirrored, rotated and magnified placements: every ring keeps the
//! orientation it was drawn with, and wrapping the root in one transformed
//! instance transforms the whole store and every label. Ported from
//! crates/ingest/src/layout.rs's in-file tests.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const fx = @import("layout_fixture.zig");
const fixture = ingest.gds_fixture;
const LayerId = geom.LayerId;
const gpa = testing.allocator;

/// `STRANS` bit 0: reflect about the X axis before rotating. From the spec,
/// not imported from the code under test.
const reflect: u16 = 0x8000;

/// The cell every mirroring test instantiates: a counter-clockwise right
/// triangle. A rectangle is its own mirror image, so a reader dropping the
/// reflection would reproduce one exactly.
const ccw_triangle: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 200, 0 }, .ys = &.{ 0, 0, 100 } };

/// One representable instance transform, `W(p) = mag · R_q · Fʳ · p + (dx,
/// dy)`. Deliberately not `gds.Xform`: an expected answer computed with the
/// function under test asserts nothing.
const Warp = struct {
    mag: i64,
    reflect: bool,
    quarters: u2,
    dx: i64,
    dy: i64,

    /// Applied as the specification spells it: the reflection about the X
    /// axis runs before the counter-clockwise `ANGLE` rotation.
    fn apply(w: Warp, x0: i64, y0: i64) [2]i64 {
        const y1 = if (w.reflect) -y0 else y0;
        const r: [2]i64 = switch (w.quarters) {
            0 => .{ x0, y1 },
            1 => .{ -y1, x0 },
            2 => .{ -x0, -y1 },
            3 => .{ y1, -x0 },
        };
        return .{ w.mag * r[0] + w.dx, w.mag * r[1] + w.dy };
    }

    /// The `SREF` that carries it.
    fn ref(w: Warp, cell: []const u8) fixture.Ref {
        return .{ .cell = cell, .strans = if (w.reflect) reflect else 0, .angle = @as(f64, @floatFromInt(w.quarters)) * 90.0, .x = @intCast(w.dx), .y = @intCast(w.dy), .mag = @intCast(w.mag) };
    }
};

// ---- private ----

/// Reads `cells` against the three-layer deck into a fresh `Read`.
fn read(cells: []const fixture.Cell) !fx.Read {
    var r: fx.Read = .{};
    errdefer r.deinit();
    try readInto(&r, cells);
    return r;
}

fn readInto(r: *fx.Read, cells: []const fixture.Cell) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const layers = try fx.threeLayers(arena.allocator(), &strings);
    const bytes = try fixture.library(gpa, cells, 1e-9);
    defer gpa.free(bytes);
    try r.run(bytes, &layers, .reject);
}

/// Row `row`'s vertices are exactly `xs, ys`, order included.
fn expectVerts(store: *const geom.GeometryStore, row: u32, xs: []const i64, ys: []const i64) !void {
    const v = store.polyVerts(@fromBackingInt(row));
    try testing.expectEqualSlices(i64, xs, v.xs);
    try testing.expectEqualSlices(i64, ys, v.ys);
}

fn expectCcw(store: *const geom.GeometryStore, row: u32) !void {
    const v = store.polyVerts(@fromBackingInt(row));
    try testing.expectEqual(geom.ops.Winding.ccw, geom.ops.windingOf(v.xs, v.ys).?);
}

/// Row `row`'s vertices relative to its vertex 0.
fn relative(a: std.mem.Allocator, store: *const geom.GeometryStore, row: u32) ![]const [2]i64 {
    const v = store.polyVerts(@fromBackingInt(row));
    const out = try a.alloc([2]i64, v.xs.len);
    for (out, v.xs, v.ys) |*o, x, y| o.* = .{ x - v.xs[0], y - v.ys[0] };
    return out;
}

/// The library the equivariance law is stated over, optionally wrapped.
/// `MID` places `LEAF` mirrored and `TOP` places `MID` under a quarter turn,
/// so the deepest ring arrives through a mirror composed with a rotation
/// across two levels; `TOP`'s ring at `x = 2·10⁶` makes one magnification
/// below genuinely unrepresentable. `WRAP`, when present, is the only root.
fn nestedMirror(r: *fx.Read, wrap: ?Warp) !void {
    const leaf = [_]fixture.Boundary{ ccw_triangle, .{ .layer = 67, .datatype = 44, .xs = &.{ 0, 120, 120, 0 }, .ys = &.{ 0, 0, 60, 60 } } };
    const top = [_]fixture.Boundary{.{ .layer = 66, .datatype = 20, .xs = &.{ 2_000_000, 2_000_400, 2_000_400, 2_000_000 }, .ys = &.{ 0, 0, 400, 400 } }};
    const cells = [_]fixture.Cell{
        .{ .name = "LEAF", .boundaries = &leaf, .texts = &.{.{ .layer = 67, .texttype = 44, .x = 60, .y = 20, .string = "N1" }} },
        .{ .name = "MID", .refs = &.{.{ .cell = "LEAF", .strans = reflect, .x = 300 }} },
        .{ .name = "TOP", .boundaries = &top, .refs = &.{ .{ .cell = "LEAF" }, .{ .cell = "MID", .angle = 90, .x = 1_000 } } },
        .{ .name = "WRAP", .refs = &.{if (wrap) |w| w.ref("TOP") else undefined} },
    };
    try readInto(r, if (wrap == null) cells[0..3] else &cells);
}

test "a mirrored instance keeps the orientation the cell was drawn with" {
    // Oracle: hand-derived. STRANS 0x8000 reflects about x before rotation, so
    // the triangle (0, 0), (200, 0), (0, 100) under (x, -y) + (1000, 0) is
    // clockwise, and the store's counter-clockwise rings with vertex 0 fixed
    // give the listed vertices, reversed from vertex 1.
    var r = try read(&.{
        .{ .name = "LEAF", .boundaries = &.{ccw_triangle} },
        .{ .name = "TOP", .refs = &.{ .{ .cell = "LEAF" }, .{ .cell = "LEAF", .strans = reflect, .x = 1_000 } } },
    });
    defer r.deinit();
    try testing.expectEqual(2, r.store.polyCount());
    try expectVerts(&r.store, 0, &.{ 0, 200, 0 }, &.{ 0, 0, 100 });
    try expectVerts(&r.store, 1, &.{ 1_000, 1_000, 1_200 }, &.{ 0, -100, 0 });
    try expectCcw(&r.store, 0);
    try expectCcw(&r.store, 1);
}

test "a doubly mirrored instance is the cell as drawn" {
    // Oracle: law. Two reflections compose to the identity, so the nested copy
    // is the direct copy vertex for vertex, order included.
    var r = try read(&.{
        .{ .name = "LEAF", .boundaries = &.{ccw_triangle} },
        .{ .name = "MID", .refs = &.{.{ .cell = "LEAF", .strans = reflect }} },
        .{ .name = "TOP", .refs = &.{ .{ .cell = "LEAF" }, .{ .cell = "MID", .strans = reflect } } },
    });
    defer r.deinit();
    try testing.expectEqual(2, r.store.polyCount());
    try expectVerts(&r.store, 0, &.{ 0, 200, 0 }, &.{ 0, 0, 100 });
    try expectVerts(&r.store, 1, &.{ 0, 200, 0 }, &.{ 0, 0, 100 });
}

test "a mirror composed with each quarter turn still flattens counter-clockwise" {
    // Oracle: hand-derived. Each placement is the drawn triangle through
    // `R_q · diag(1, -1)` (GDSII reflects, then rotates) plus its offset,
    // worked out by hand, reversed from vertex 1 because the determinant is
    // -1; every ring winds counter-clockwise.
    var r = try read(&.{
        .{ .name = "LEAF", .boundaries = &.{ccw_triangle} },
        .{ .name = "TOP", .refs = &.{
            .{ .cell = "LEAF", .strans = reflect },
            .{ .cell = "LEAF", .strans = reflect, .angle = 90, .x = 2_000 },
            .{ .cell = "LEAF", .strans = reflect, .angle = 180, .x = 4_000 },
            .{ .cell = "LEAF", .strans = reflect, .angle = 270, .x = 6_000 },
        } },
    });
    defer r.deinit();
    try testing.expectEqual(4, r.store.polyCount());
    const want = [_][2][3]i64{
        .{ .{ 0, 0, 200 }, .{ 0, -100, 0 } },
        .{ .{ 2_000, 2_100, 2_000 }, .{ 0, 0, 200 } },
        .{ .{ 4_000, 4_000, 3_800 }, .{ 0, 100, 0 } },
        .{ .{ 6_000, 5_900, 6_000 }, .{ 0, 0, -200 } },
    };
    for (want, 0..) |w, row| {
        try expectVerts(&r.store, @intCast(row), &w[0], &w[1]);
        try expectCcw(&r.store, @intCast(row));
    }
}

test "a mirror and a rotation split across two levels do not commute" {
    // Oracle: hand-derived. `F · R90` maps a point to (-y, -x) and `R90 · F`
    // to (y, x); the triangle through each, offset and reversed from vertex 1,
    // is worked out by hand, and the two must differ.
    var r = try read(&.{
        .{ .name = "LEAF", .boundaries = &.{ccw_triangle} },
        .{ .name = "ROTATED", .refs = &.{.{ .cell = "LEAF", .angle = 90 }} },
        .{ .name = "MIRRORED", .refs = &.{.{ .cell = "LEAF", .strans = reflect }} },
        .{ .name = "TOP", .refs = &.{ .{ .cell = "ROTATED", .strans = reflect }, .{ .cell = "MIRRORED", .angle = 90, .x = 5_000 } } },
    });
    defer r.deinit();
    try testing.expectEqual(2, r.store.polyCount());
    // Through (-y, -x): (0,0), (0,-200), (-100,0), clockwise, so reversed.
    try expectVerts(&r.store, 0, &.{ 0, -100, 0 }, &.{ 0, 0, -200 });
    // Through (y, x), offset (5000, 0): (5000,0), (5000,200), (5100,0), reversed.
    try expectVerts(&r.store, 1, &.{ 5_000, 5_100, 5_000 }, &.{ 0, 0, 200 });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = try relative(arena.allocator(), &r.store, 0);
    const b = try relative(arena.allocator(), &r.store, 1);
    try testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b)));
    try expectCcw(&r.store, 0);
    try expectCcw(&r.store, 1);
}

test "wrapping the root in one transformed instance transforms the whole store" {
    // Oracle: metamorphic relation, transform equivariance: (a) row count,
    // layer ranges and each row's layer are untouched; (b) row `i`'s
    // vertices are `W(v_j)` in order, or `[W(v0), W(v_n-1), …, W(v1)]` when
    // `W` reflects; (c) every placed label becomes `W(p)`, same order, layer
    // and name. `CoordinateOutOfRange` is the one escape, and is real.
    var base: fx.Read = .{};
    defer base.deinit();
    try nestedMirror(&base, null);
    // Anti-vacuity: rows on every layer, two labels to move, and the two
    // LEAF triangles not congruent by translation (the mirror is there).
    try testing.expectEqual(5, base.store.polyCount());
    for (0..3) |l| try testing.expect(base.store.polysOnLayer(@fromBackingInt(@as(u16, @intCast(l)))).len() > 0);
    try testing.expectEqual(2, base.provenance.placed.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(try relative(arena.allocator(), &base.store, 0)), std.mem.sliceAsBytes(try relative(arena.allocator(), &base.store, 1))));

    const warps = [_]Warp{
        .{ .mag = 1, .reflect = false, .quarters = 0, .dx = 0, .dy = 0 },
        .{ .mag = 1, .reflect = false, .quarters = 0, .dx = -7_000, .dy = 3_000 },
        .{ .mag = 1, .reflect = true, .quarters = 0, .dx = 0, .dy = 0 },
        .{ .mag = 1, .reflect = false, .quarters = 1, .dx = 0, .dy = 0 },
        .{ .mag = 1, .reflect = true, .quarters = 3, .dx = 1_234, .dy = -5_678 },
        .{ .mag = 3, .reflect = true, .quarters = 1, .dx = -1_000, .dy = 2_000 },
        .{ .mag = 3, .reflect = false, .quarters = 2, .dx = 500, .dy = -500 },
    };
    for (warps) |w| {
        var wrapped: fx.Read = .{};
        defer wrapped.deinit();
        try nestedMirror(&wrapped, w);
        // (a)
        try testing.expectEqual(base.store.polyCount(), wrapped.store.polyCount());
        for (0..3) |l| {
            const layer: LayerId = @fromBackingInt(@as(u16, @intCast(l)));
            try testing.expectEqual(base.store.polysOnLayer(layer), wrapped.store.polysOnLayer(layer));
        }
        for (0..5) |row| {
            const poly: geom.PolyId = @fromBackingInt(@intCast(row));
            try testing.expectEqual(base.store.polyLayer(poly), wrapped.store.polyLayer(poly));
            // (b)
            const b = base.store.polyVerts(poly);
            const got = wrapped.store.polyVerts(poly);
            try testing.expectEqual(b.xs.len, got.xs.len);
            for (0..b.xs.len) |k| {
                const j = if (w.reflect and k > 0) b.xs.len - k else k;
                try testing.expectEqual(w.apply(b.xs[j], b.ys[j]), [2]i64{ got.xs[k], got.ys[k] });
            }
        }
        // (c)
        const before = base.provenance.placed.slice();
        const after = wrapped.provenance.placed.slice();
        try testing.expectEqual(before.len, after.len);
        for (0..before.len) |k| {
            const pb = before.get(k);
            const pa = after.get(k);
            try testing.expectEqual(w.apply(pb.x, pb.y), [2]i64{ pa.x, pa.y });
            try testing.expectEqual(pb.layer, pa.layer);
            try testing.expectEqualStrings(base.strings.resolve(pb.name), wrapped.strings.resolve(pa.name));
        }
    }

    // A magnification of 10⁶ lands TOP's ring at 2·10¹², past max_abs_dbu.
    const overflow: Warp = .{ .mag = 1_000_000, .reflect = false, .quarters = 0, .dx = 0, .dy = 0 };
    var refused: fx.Read = .{};
    defer refused.deinit();
    try testing.expectError(error.CoordinateOutOfRange, nestedMirror(&refused, overflow));
    try testing.expect(!geom.inDomain(refused.diag.coordinate));
}
