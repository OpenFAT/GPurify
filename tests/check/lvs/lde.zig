//! `addLdeParams` (LVS-074) on one transistor drawn by hand: `SA`/`SB`
//! from BSIM4's effective-distance law and `SCA`/`SCB`/`SCC` from Silvaco's
//! closed forms, written out again here apart from `lde.wpe`. Ported from
//! crates/check/tests/lvs/lde.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const Grid = geom.Grid;
const ingest = @import("ingest");
const deck = ingest.deck;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const topology = check.topology;
const LayoutBuilder = @import("testgen").shapes.LayoutBuilder;
const Ids = @import("testgen").shapes.Ids;
const gpa = testing.allocator;

/// A rectangle on a named layer.
const Shape = struct { []const u8, [4]i64 };
/// One of four placements: identity, the transpose (channel along y), the
/// mirror in y, a quarter turn.
const Place = enum { identity, transpose, mirror, turn };
const all_places = [_]Place{ .identity, .transpose, .mirror, .turn };
const all_names = [_][]const u8{ "sa", "sb", "sca", "scb", "scc" };
/// One expected parameter.
const Want = struct { []const u8, f64 };

/// The transistor: OD x 0..1150 by y 0..1000 with an OD strip x -300..0 by
/// y 0..500 abutting its source side, the gate x 500..650 (L 150, W 1000),
/// poly across it, the two diffusions beside it.
const transistor = [_]Shape{
    .{ "diff", .{ 0, 0, 1150, 1000 } },  .{ "diff", .{ -300, 0, 0, 500 } },
    .{ "gate", .{ 500, 0, 650, 1000 } }, .{ "poly", .{ 500, -200, 650, 1200 } },
    .{ "sd", .{ 0, 0, 500, 1000 } },     .{ "sd", .{ 650, 0, 1150, 1000 } },
};

// ---- private ----

fn placeRect(p: Place, r: [4]i64) [4]i64 {
    const map = struct {
        fn f(q: Place, x: i64, y: i64) [2]i64 {
            return switch (q) {
                .identity => .{ x, y },
                .transpose => .{ y, x },
                .mirror => .{ -x, y },
                .turn => .{ -y, x },
            };
        }
    }.f;
    const a = map(p, r[0], r[1]);
    const b = map(p, r[2], r[3]);
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[0], b[0]), @max(a[1], b[1]) };
}

/// The added parameters of the first device, after the measured ones,
/// with `names` interned as a reference would; asserts the device's own
/// `w` and `l` come first.
fn ldeOf(shapes: []const Shape, place: Place, max: i64, well: bool, names: []const []const u8, out: *std.ArrayList(Want)) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    for ([_][]const u8{ "w", "l" }) |n| _ = try strings.intern(gpa, n);
    for (names) |n| _ = try strings.intern(gpa, n);
    const text = try std.fmt.allocPrint(gpa,
        \\grid 1nm
        \\layer diff = gds(1, 0)
        \\layer poly = gds(2, 0)
        \\layer gate = gds(3, 0)
        \\layer sd = gds(4, 0)
        \\layer wellm = gds(5, 0)
        \\layer pgate = gds(6, 0)
        \\connect conductors [sd, poly]
        \\connect touch_within_layer
        \\device mos gate model "nmos" terminals [poly, sd, sd]
        \\device mos pgate model "pmos" terminals [poly, sd, sd]
        \\lvs lde "nmos" od diff max {d}nm{s}
        \\
    , .{ max, if (well) " well wellm scref 1000nm" else "" });
    defer gpa.free(text);
    const grid = try Grid.init(1000);
    var diag: deck.Diag = .{};
    const dk = try deck.parseDeck(arena_state.allocator(), gpa, text, grid, &strings, &diag);
    var lb = LayoutBuilder.init(@intCast(dk.layers.len()));
    defer lb.deinit(gpa);
    for (shapes) |s| {
        const layer = dk.layers.id(&strings, s[0]).?;
        const r = placeRect(place, s[1]);
        _ = try lb.rect(gpa, @backingInt(layer), r[0], r[1], r[2], r[3]);
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var nets: topology.NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &store, &dk.connectivity, &nets);
    var devices: topology.DeviceTable = .{};
    defer devices.deinit(gpa);
    try topology.recogniseInto(gpa, &store, &nets, &dk.devices, &devices);
    const ports: topology.PortTable = .{};
    var g: Graph = .{};
    defer g.deinit(gpa);
    try lvs.fromLayoutInto(gpa, &nets, &devices, &ports, &strings, grid, &g);
    try testing.expectEqual(@as(u32, 1), g.deviceCount());
    const before = g.paramsOf(0).len;
    try testing.expectEqual(@as(usize, 2), before);
    try lvs.addLdeParams(gpa, &g, .{ .store = &store, .nets = &nets, .devices = &devices }, dk.lvs.lde, &dk.layers, &strings, grid);
    try testing.expectEqual(@as(usize, 2), g.device_param_start.items.len);
    const params = g.paramsOf(0);
    try testing.expectEqual(g.param.items.len, params.len);
    try expectNamed(&strings, params[0..before], &.{ .{ "w", 1e-6 }, .{ "l", 150e-9 } });
    out.clearRetainingCapacity();
    // Names resolve to static texts: `all_names` and "w"/"l" outlive this.
    for (params[before..]) |p| {
        const text_of = strings.resolve(p.name);
        const static = for (all_names) |n| (if (std.mem.eql(u8, n, text_of)) break n) else return error.TestUnexpectedName;
        try out.append(gpa, .{ static, p.value });
    }
}

fn expectNamed(strings: *const StrTable, got: []const lvs.Param, want: []const Want) !void {
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| {
        try testing.expectEqualStrings(w[0], strings.resolve(g.name));
        try testing.expect(@abs(g.value - w[1]) <= 1e-9 * @abs(w[1]));
    }
}

fn expectParams(got: []const Want, want: []const Want) !void {
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| {
        try testing.expectEqualStrings(w[0], g[0]);
        if (!(@abs(g[1] - w[1]) <= 1e-9 * @abs(w[1]))) {
            std.debug.print("{s} = {e}, want {e}\n", .{ g[0], g[1], w[1] });
            return error.TestParamDiffers;
        }
    }
}

/// Silvaco's SCA, SCB, SCC from [SC1..SC4], w, l, scref, in metres.
fn silvacoWpe(sc: [4]f64, w: f64, l: f64, scref: f64) [3]f64 {
    const sca = scref * scref / (w * l) * (w * (1.0 / sc[0] - 1.0 / (sc[0] + l)) + l * (1.0 / sc[1] - 1.0 / (sc[1] + w)) + w * (1.0 / sc[2] - 1.0 / (sc[2] + l)) + l * (1.0 / sc[3] - 1.0 / (sc[3] + w)));
    const One = struct {
        fn f(n: f64, s: f64, e: f64, r: f64) f64 {
            return 1.0 / (e * r) * (r / n * s * @exp(-n * s / r) + r * r / (n * n) * @exp(-n * s / r) - r / n * (s + e) * @exp(-n * (s + e) / r) - r * r / (n * n) * @exp(-n * (s + e) / r));
        }
        fn integral(n: f64, c: [4]f64, wd: f64, ln: f64, r: f64) f64 {
            return f(n, c[1], wd, r) + f(n, c[3], wd, r) + f(n, c[0], ln, r) + f(n, c[2], ln, r);
        }
    };
    return .{ sca, One.integral(10.0, sc, w, l, scref), One.integral(20.0, sc, w, l, scref) };
}

/// sa, sb with `max`: the drain side sees 500 nm over the whole width; the
/// source side 800 nm over the lower half and 500 over the upper, each
/// capped, and BSIM4's effective distance `1/Σ (wᵢ/W)/(dᵢ + L/2) − L/2`.
fn stressPair(max: f64) [2]f64 {
    const half = 75.0;
    const source = 1.0 / (0.5 / (@min(800.0, max) + half) + 0.5 / (@min(500.0, max) + half)) - half;
    const drain = @min(500.0, max);
    return .{ @min(source, drain) * 1e-9, @max(source, drain) * 1e-9 };
}

fn withWell(extra: []const Shape) ![]Shape {
    const out = try gpa.alloc(Shape, transistor.len + extra.len);
    @memcpy(out[0..transistor.len], &transistor);
    @memcpy(out[transistor.len..], extra);
    return out;
}

test "sa and sb are bsim4's effective distances in every placement" {
    // Oracle: BSIM4's law, hand-evaluated: sa 500 nm and sb
    // 1/(0.5/875 + 0.5/575) − 75 = 619.0 nm, smaller first, in metres, after
    // the device's own w and l; the same under transpose, mirror and turn.
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    const s = stressPair(std.math.inf(f64));
    for (all_places) |place| {
        try ldeOf(&transistor, place, 5000, false, &all_names, &got);
        try expectParams(got.items, &.{ .{ "sa", s[0] }, .{ "sb", s[1] } });
    }
}

test "every distance is capped at the row's max" {
    // Oracle: the cap, hand-evaluated: max 700 nm reads the 800 nm strip as
    // 700; max 400 reads every distance as 400.
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    for ([_]i64{ 700, 400 }) |max| {
        const s = stressPair(@floatFromInt(max));
        try ldeOf(&transistor, .identity, max, false, &all_names, &got);
        try expectParams(got.items, &.{ .{ "sa", s[0] }, .{ "sb", s[1] } });
    }
}

test "an enclosing well gives silvaco's integrals in every placement" {
    // Oracle: Silvaco's closed forms over distances read off the drawing: a
    // well x -1500..2650 by y -2000..4000 gives SC1 2000, SC2 2000, SC3 2000,
    // SC4 3000 nm; W 1000, L 150, SCREF 1000 nm; SCA is symmetric, so every
    // placement agrees.
    const s = stressPair(std.math.inf(f64));
    const w = silvacoWpe(.{ 2000e-9, 2000e-9, 2000e-9, 3000e-9 }, 1000e-9, 150e-9, 1000e-9);
    const shapes = try withWell(&.{.{ "wellm", .{ -1500, -2000, 2650, 4000 } }});
    defer gpa.free(shapes);
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    for (all_places) |place| {
        try ldeOf(shapes, place, 5000, true, &all_names, &got);
        try expectParams(got.items, &.{ .{ "sa", s[0] }, .{ "sb", s[1] }, .{ "sca", w[0] }, .{ "scb", w[1] }, .{ "scc", w[2] } });
    }
}

test "a stepped well edge reads the width weighted median" {
    // Oracle: the median rule, hand-evaluated. A well to the right only, its
    // left edge at x 1000 below y 300 and 1500 above: the drain end sees
    // 350 nm over 300 of the width and 850 over 700, median 850; the other
    // edges read max, 5000.
    const s = stressPair(std.math.inf(f64));
    const w = silvacoWpe(.{ 5000e-9, 5000e-9, 850e-9, 5000e-9 }, 1000e-9, 150e-9, 1000e-9);
    const shapes = try withWell(&.{ .{ "wellm", .{ 1000, -3000, 3000, 300 } }, .{ "wellm", .{ 1500, 300, 3000, 4000 } } });
    defer gpa.free(shapes);
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    for (all_places) |place| {
        try ldeOf(shapes, place, 5000, true, &all_names, &got);
        try expectParams(got.items, &.{ .{ "sa", s[0] }, .{ "sb", s[1] }, .{ "sca", w[0] }, .{ "scb", w[1] }, .{ "scc", w[2] } });
    }
}

test "a well edge near over most of the width reads the near distance" {
    // Oracle: the median rule's other side: the step at y 700 gives 350 nm
    // over 700 of the width and 850 over 300, median 350.
    const w = silvacoWpe(.{ 5000e-9, 5000e-9, 350e-9, 5000e-9 }, 1000e-9, 150e-9, 1000e-9);
    const shapes = try withWell(&.{ .{ "wellm", .{ 1000, -3000, 3000, 700 } }, .{ "wellm", .{ 1500, 700, 3000, 4000 } } });
    defer gpa.free(shapes);
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    try ldeOf(shapes, .identity, 5000, true, &all_names, &got);
    try expectParams(got.items[2..], &.{ .{ "sca", w[0] }, .{ "scb", w[1] }, .{ "scc", w[2] } });
}

test "the median takes the lower half and an edge on the gate is not outward" {
    // Oracle: the median at its boundary and the "outward" rule: a step at
    // y 500 splits the width in halves, the lower median 350; a well edge on
    // the drain edge (x 650) is not outward, so the far edge, 2350, is read.
    const halves = try withWell(&.{ .{ "wellm", .{ 1000, -3000, 3000, 500 } }, .{ "wellm", .{ 1500, 500, 3000, 4000 } } });
    defer gpa.free(halves);
    const flush = try withWell(&.{.{ "wellm", .{ 650, -3000, 3000, 4000 } }});
    defer gpa.free(flush);
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    for ([_]struct { []const Shape, f64 }{ .{ halves, 350e-9 }, .{ flush, 2350e-9 } }) |case| {
        const w = silvacoWpe(.{ 5000e-9, 5000e-9, case[1], 5000e-9 }, 1000e-9, 150e-9, 1000e-9);
        try ldeOf(case[0], .identity, 5000, true, &all_names, &got);
        try expectParams(got.items[2..], &.{ .{ "sca", w[0] }, .{ "scb", w[1] }, .{ "scc", w[2] } });
    }
}

test "only measurable gates and interned names get parameters" {
    // Oracle: the module's contract: only interned names are written, none
    // when none is interned, nothing for a gate not one rectangle inside one
    // stretch of OD (OD on one side only; a cross on both axes).
    const s = stressPair(std.math.inf(f64));
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    try ldeOf(&transistor, .identity, 5000, false, &.{"sa"}, &got);
    try expectParams(got.items, &.{.{ "sa", s[0] }});
    try ldeOf(&transistor, .identity, 5000, false, &.{}, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);
    var short = transistor;
    short[0] = .{ "diff", .{ 0, 0, 650, 1000 } };
    try ldeOf(&short, .identity, 5000, false, &all_names, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);
    const cross = try withWell(&.{.{ "diff", .{ 500, -500, 650, 1500 } }});
    defer gpa.free(cross);
    try ldeOf(cross, .identity, 5000, false, &all_names, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}

test "a transistor of another model gets nothing" {
    // Oracle: the row names its model: a pmos drawn the same way gets
    // nothing.
    var shapes = transistor;
    shapes[2] = .{ "pgate", .{ 500, 0, 650, 1000 } };
    var got: std.ArrayList(Want) = .empty;
    defer got.deinit(gpa);
    try ldeOf(&shapes, .identity, 5000, true, &all_names, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}
