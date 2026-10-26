//! The closed forms against tests/exhaustive/pex.rs's fixtures (PEX-001,
//! PEX-002): bars, bends, a conductor in pieces, via arrays and stack gaps,
//! each under the eight symmetries of the square at two offsets. The Rust
//! fixtures ran the engine on a deck; here the same `PARAMS` rows feed
//! `analytical.extractInto` directly, nets stated with the shapes
//! (construct-from-answer). A claim is the total over the elements whose
//! near node is on net 0 (`harness::parasitic_total`), held to `exact`, and
//! every network to passivity.
//!
//! Contents: `exact`, `Claim`; helpers `Shapes`, `wireOhm`, `groundFf`,
//! `outline`, `bend`, `run`, `holds`, `joint`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const fixture = @import("fixture.zig");
const Poly = fixture.Poly;
const Row = fixture.Row;
const Rows = fixture.Rows;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;

/// Closed form against closed form: round-off only.
const exact: f64 = 1e-9;

/// What net 0 must total: ohms and femtofarads to ground; null claims nothing.
const Claim = struct { ohm: ?f64 = null, ff: ?f64 = null };

const m1 = row(0);
const m2 = row(2);

/// The deck's conductors and its one via row: `v1` joins `m1` to `m2`.
const vias: extract.Vias = .{ .cut = &.{@fromBackingInt(1)}, .connects = &.{.{ @fromBackingInt(0), @fromBackingInt(2) }} };

/// A fixture's polygons, built in an arena.
const Shapes = struct {
    arena: std.heap.ArenaAllocator,
    polys: std.ArrayList(Poly) = .empty,

    fn init() Shapes {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(s: *Shapes) void {
        s.arena.deinit();
    }

    fn rect(s: *Shapes, layer: u16, net: u32, xlo: i64, ylo: i64, xhi: i64, yhi: i64) !void {
        try s.poly(layer, net, &.{ .{ xlo, ylo }, .{ xhi, ylo }, .{ xhi, yhi }, .{ xlo, yhi } });
    }

    fn poly(s: *Shapes, layer: u16, net: u32, pts: []const [2]i64) !void {
        const a = s.arena.allocator();
        try s.polys.append(a, .{ .layer = layer, .net = net, .pts = try a.dupe([2]i64, pts) });
    }
};

// ---- private ----

fn row(layer: usize) Row {
    const p = fixture.params;
    return .{ .thickness = p.thickness[layer], .height = p.height[layer], .sheet = p.sheet[layer], .k = p.k[layer], .area = p.area[layer], .fringe = p.fringe[layer] };
}

/// `Rs · L / W`.
fn wireOhm(r: Row, length: i64, width: i64) f64 {
    return r.sheet * @as(f64, @floatFromInt(length)) / @as(f64, @floatFromInt(width));
}

/// `Ca · A + Cf · P`, `A` in nm², `P` in nm.
fn groundFf(r: Row, area: f64, perimeter: f64) f64 {
    return (r.area * area / 1e6 + r.fringe * perimeter / 1e3) / 1e3;
}

/// A polygon's area (nm²) and perimeter (nm), by the shoelace formula.
fn outline(pts: []const [2]i64) [2]f64 {
    var twice: i128 = 0;
    var perimeter: f64 = 0.0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        twice += @as(i128, p[0]) * q[1] - @as(i128, q[0]) * p[1];
        perimeter += std.math.hypot(@as(f64, @floatFromInt(q[0] - p[0])), @as(f64, @floatFromInt(q[1] - p[1])));
    }
    return .{ @as(f64, @floatFromInt(@abs(twice))) / 2.0, perimeter };
}

/// A constant-width path of width `w` as one polygon, counter-clockwise
/// from the origin, into `out`; returns its centre line's length. Its
/// rectangle of equal area and perimeter is exactly `Lc × w`.
fn bend(shape: u8, a: i64, b: i64, w: i64, out: *std.ArrayList([2]i64)) !i64 {
    out.clearRetainingCapacity();
    switch (shape) {
        'l' => {
            try out.appendSlice(gpa, &.{ .{ 0, 0 }, .{ a, 0 }, .{ a, b }, .{ a - w, b }, .{ a - w, w }, .{ 0, w } });
            return a + b - w;
        },
        'u' => {
            try out.appendSlice(gpa, &.{ .{ 0, 0 }, .{ a, 0 }, .{ a, b }, .{ a - w, b }, .{ a - w, w }, .{ w, w }, .{ w, b }, .{ 0, b } });
            return a + 2 * b - 2 * w;
        },
        's' => {
            try out.appendSlice(gpa, &.{ .{ 0, 0 }, .{ a, 0 }, .{ a, b - w }, .{ 2 * a - w, b - w }, .{ 2 * a - w, b }, .{ a - w, b }, .{ a - w, w }, .{ 0, w } });
            return 2 * a + b - 2 * w;
        },
        else => unreachable,
    }
}

fn run(c: *const fixture.Case, rows: *const Rows, out: *ParasiticNetwork, refusal: *extract.analytical.Refusal) extract.analytical.Error!void {
    const problem: extract.analytical.Problem = .{ .store = &c.store, .nets = &c.nets, .conductors = &.{ @fromBackingInt(0), @fromBackingInt(2) }, .global = &.{}, .vias = vias, .stack = rows.stack(), .halo = 10.0, .grid = fixture.grid };
    return extract.analytical.extractInto(gpa, problem, out, refusal);
}

/// `claim` on net 0 under every symmetry at every offset, each network
/// passive (no negative R or C).
fn holds(polys: []const Poly, claim: Claim) !void {
    for (fixture.Symmetry.all) |s| {
        for (fixture.offsets) |d| {
            var c = try fixture.placed(polys, s, d);
            defer c.deinit();
            var n: ParasiticNetwork = .empty;
            defer n.deinit(gpa);
            var refusal: extract.analytical.Refusal = .{};
            try run(&c, &fixture.params, &n, &refusal);
            var ohm: f64 = 0.0;
            var ff: f64 = 0.0;
            for (n.from.items, n.kind.items, n.value.items) |from, kind, v| {
                try testing.expect(v >= 0.0);
                if (n.node_net.items[@backingInt(from)] != 0) continue;
                switch (kind) {
                    .resistance => ohm += v,
                    .ground_cap => ff += v,
                    .coupling_cap, .inductance, .mutual_inductance, .substrate_resistance => {},
                }
            }
            if (claim.ohm) |want| try testing.expectApproxEqRel(want, ohm, exact);
            if (claim.ff) |want| try testing.expectApproxEqRel(want, ff, exact);
        }
    }
}

/// `n` 200 nm cuts in the 1 × 1 µm square where an `m1` bar at `[x, x+5um]`
/// meets an `m2` bar at `[x+4um, x+9um]`, on a 300 nm pitch, on no net.
fn joint(s: *Shapes, x: i64, n: i64) !void {
    for (0..@intCast(n)) |i| {
        const ii: i64 = @intCast(i);
        const cx = x + 4_100 + 300 * @rem(ii, 3);
        const cy = 100 + 300 * @divTrunc(ii, 3);
        try s.rect(1, extract.none, cx, cy, cx + 200, cy + 200);
    }
}

test "a straight bar is its squares and its plate plus fringe" {
    // Oracle: closed form (PEX-001, PEX-002): `L/W` squares and `Ca·LW +
    // Cf·2(L+W)`, over width (100 nm is params.deck's met1 minimum) and
    // length (one square, ten, a thousand), on both metals so a row mix-up
    // shows.
    for ([_]u16{ 0, 2 }) |layer| {
        const r = row(layer);
        for ([_]i64{ 100, 1000 }) |w| {
            for ([_]i64{ 1, 10, 1000 }) |squares| {
                const l = w * squares;
                var s: Shapes = .init();
                defer s.deinit();
                try s.rect(layer, 0, 0, 0, l, w);
                try holds(s.polys.items, .{ .ohm = wireOhm(r, l, w), .ff = groundFf(r, @floatFromInt(l * w), @floatFromInt(2 * (l + w))) });
            }
        }
    }
}

test "a bent wire drawn as one polygon is its centre line's squares" {
    // Oracle: closed form: for a constant-width path the rectangle of equal
    // area and perimeter is `Lc × w`, so R is `Rs·Lc/w` (every corner one
    // square) and C is `Ca·A + Cf·P` of the outline.
    var pts: std.ArrayList([2]i64) = .empty;
    defer pts.deinit(gpa);
    const legs = [_]struct { u8, i64, i64 }{ .{ 'l', 20, 12 }, .{ 'u', 10, 15 }, .{ 's', 9, 14 } };
    for ([_]u16{ 0, 2 }) |layer| {
        const r = row(layer);
        for ([_]i64{ 100, 1000 }) |w| {
            for (legs) |leg| {
                const centre = try bend(leg[0], leg[1] * w, leg[2] * w, w, &pts);
                var s: Shapes = .init();
                defer s.deinit();
                try s.poly(layer, 0, pts.items);
                const o = outline(pts.items);
                try holds(s.polys.items, .{ .ohm = wireOhm(r, centre, w), .ff = groundFf(r, o[0], o[1]) });
            }
        }
    }
}

test "a conductor drawn as several polygons is that conductor" {
    // Oracle: closed form (F44): a 12 × 1 µm bar in 2, 3 or 4 abutting
    // pieces is 12 squares and `Ca·12 + Cf·26`; an L of legs 20 and 12 µm as
    // two abutting or two overlapping bars is the one-polygon L's `Lc/w` and
    // outline; a 3 × 1 µm bar in four 750 nm pieces is three squares. F76:
    // two 4 × 1 µm bars meeting only at a corner are two conductors of four
    // squares each, C both bars'.
    const r = m1;
    for ([_]i64{ 2, 3, 4 }) |k| {
        var s: Shapes = .init();
        defer s.deinit();
        for (0..@intCast(k)) |i| {
            const ii: i64 = @intCast(i);
            try s.rect(0, 0, @divTrunc(ii * 12_000, k), 0, @divTrunc((ii + 1) * 12_000, k), 1_000);
        }
        try holds(s.polys.items, .{ .ohm = wireOhm(r, 12_000, 1_000), .ff = groundFf(r, 12e6, 26_000.0) });
    }
    var pts: std.ArrayList([2]i64) = .empty;
    defer pts.deinit(gpa);
    const centre = try bend('l', 20_000, 12_000, 1_000, &pts);
    const o = outline(pts.items);
    const l: Claim = .{ .ohm = wireOhm(r, centre, 1_000), .ff = groundFf(r, o[0], o[1]) };
    for ([_]i64{ 1_000, 0 }) |second_ylo| {
        var s: Shapes = .init();
        defer s.deinit();
        try s.rect(0, 0, 0, 0, 20_000, 1_000);
        try s.rect(0, 0, 19_000, second_ylo, 20_000, 12_000);
        try holds(s.polys.items, l);
    }
    {
        var s: Shapes = .init();
        defer s.deinit();
        for (0..4) |i| {
            const x: i64 = 750 * @as(i64, @intCast(i));
            try s.rect(0, 0, x, 0, x + 750, 1_000);
        }
        try holds(s.polys.items, .{ .ohm = wireOhm(r, 3_000, 1_000) });
    }
    var s: Shapes = .init();
    defer s.deinit();
    try s.rect(0, 0, 0, 0, 4_000, 1_000);
    try s.rect(0, 0, 4_000, 1_000, 8_000, 2_000);
    try holds(s.polys.items, .{ .ohm = 2.0 * wireOhm(r, 4_000, 1_000), .ff = 2.0 * groundFf(r, 4e6, 10_000.0) });
}

test "a via array is its cuts in parallel in series with both plates" {
    // Oracle: closed form (PEX-001): `n` cuts joining one pair of plates are
    // `Rcut / n`, in series with both plates; cuts carry no capacitance; a
    // cut that misses a plate is left out; a chain of joints is their series
    // sum.
    const r1 = wireOhm(m1, 5_000, 1_000);
    const r2 = wireOhm(m2, 5_000, 1_000);
    const c1 = groundFf(m1, 5e6, 12_000.0);
    const c2 = groundFf(m2, 5e6, 12_000.0);
    const per_cut = fixture.params.sheet[1];
    for ([_]i64{ 1, 2, 4, 9 }) |n| {
        var s: Shapes = .init();
        defer s.deinit();
        try s.rect(0, 0, 0, 0, 5_000, 1_000);
        try s.rect(2, 0, 4_000, 0, 9_000, 1_000);
        try joint(&s, 0, n);
        try holds(s.polys.items, .{ .ohm = r1 + r2 + per_cut / @as(f64, @floatFromInt(n)), .ff = c1 + c2 });
    }
    {
        var s: Shapes = .init();
        defer s.deinit();
        try s.rect(0, 0, 0, 0, 5_000, 1_000);
        try s.rect(2, 0, 4_000, 0, 9_000, 1_000);
        try joint(&s, 0, 2);
        try s.rect(1, extract.none, 1_000, 400, 1_200, 600);
        try holds(s.polys.items, .{ .ohm = r1 + r2 + per_cut / 2.0, .ff = c1 + c2 });
    }
    // m1, m2, m1, m2 end to end, joined by one, two and three cuts.
    var s: Shapes = .init();
    defer s.deinit();
    for ([_][2]i64{ .{ 0, 1 }, .{ 4_000, 2 }, .{ 8_000, 3 } }) |j| try joint(&s, j[0], j[1]);
    for (0..4) |i| {
        const x: i64 = 4_000 * @as(i64, @intCast(i));
        try s.rect(if (i % 2 == 0) 0 else 2, 0, x, 0, x + 5_000, 1_000);
    }
    try holds(s.polys.items, .{ .ohm = 2.0 * (r1 + r2) + per_cut * (1.0 + 1.0 / 2.0 + 1.0 / 3.0), .ff = 2.0 * (c1 + c2) });
}

test "a layer the stack does not describe is refused by both methods" {
    // Oracle: definition (F30): a deck with no `m1` row refuses a bar on
    // `m1`, closed forms and field solve alike, naming `m1`; one with no
    // `v1` row refuses a via array joining two plates, naming `v1`.
    var no_m1 = fixture.params;
    inline for (.{ "thickness", "height", "sheet", "k", "area", "fringe" }) |f| @field(no_m1, f)[0] = 0.0;
    var bar = try fixture.Case.init(&.{.{ .layer = 0, .net = 0, .r = .{ 0, 0, 10_000, 1_000 } }}, &.{}, 3);
    defer bar.deinit();
    var n: ParasiticNetwork = .empty;
    defer n.deinit(gpa);
    var refusal: extract.analytical.Refusal = .{ .layer = @fromBackingInt(9) };
    try testing.expectError(error.Undescribed, run(&bar, &no_m1, &n, &refusal));
    try testing.expectEqual(0, @backingInt(refusal.layer));
    var coarse_no_m1 = fixture.coarse;
    inline for (.{ "thickness", "height", "sheet", "k", "area", "fringe" }) |f| @field(coarse_no_m1, f)[0] = 0.0;
    var matrix: extract.capacitance.CapMatrix = .empty;
    defer matrix.deinit(gpa);
    var diag: extract.capacitance.Diagnostic = .{ .layer = @fromBackingInt(9) };
    try testing.expectError(error.MissingThickness, extract.quasistatic.extractInto(gpa, fixture.device, bar.problem(&coarse_no_m1), &.{0}, &matrix, &n, &diag));
    try testing.expectEqual(0, @backingInt(diag.layer));

    var no_v1 = fixture.params;
    inline for (.{ "thickness", "height", "sheet", "k", "area", "fringe" }) |f| @field(no_v1, f)[1] = 0.0;
    var s: Shapes = .init();
    defer s.deinit();
    try s.rect(0, 0, 0, 0, 5_000, 1_000);
    try s.rect(2, 0, 4_000, 0, 9_000, 1_000);
    try joint(&s, 0, 2);
    var pair = try fixture.placed(s.polys.items, fixture.Symmetry.all[0], .{ 0, 0 });
    defer pair.deinit();
    try testing.expectError(error.UndescribedVia, run(&pair, &no_v1, &n, &refusal));
    try testing.expectEqual(1, @backingInt(refusal.layer));
}
