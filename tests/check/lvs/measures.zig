//! `fromLayoutInto`'s measured parameters on devices drawn by hand: every
//! value a length or area read off the drawing, in SI, and the derived
//! `r`, `c` and `ind` following from the deck's coefficients by their laws;
//! and the deck's per-model ranges and device counts. Ported from
//! crates/check/tests/lvs/measures.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const Grid = geom.Grid;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const ingest = @import("ingest");
const deck = ingest.deck;
const DeviceKind = deck.DeviceKind;
const LvsLimit = deck.LvsLimit;
const LvsRange = deck.LvsRange;
const LvsCount = deck.LvsCount;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const report = check.report;
const Measurement = report.Measurement;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const topology = check.topology;
const LayoutBuilder = @import("testgen").shapes.LayoutBuilder;
const Ids = @import("testgen").shapes.Ids;
const gpa = testing.allocator;

const deck_text =
    \\grid 1nm
    \\layer gate = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer sd = gds(3, 0)
    \\layer pina = gds(4, 0)
    \\layer pinb = gds(5, 0)
    \\layer pinc = gds(6, 0)
    \\layer resm = gds(7, 0)
    \\layer capm = gds(8, 0)
    \\layer bjtm = gds(9, 0)
    \\layer indm = gds(10, 0)
    \\connect conductors [poly, sd, pina, pinb, pinc]
    \\connect touch_within_layer
    \\device mos gate model "nmos" terminals [poly, sd, sd]
    \\device resistor resm model "rpoly" terminals [pina, pina] sheet 100ohm
    \\device capacitor capm model "cmim" terminals [pina, pinb] area_cap 1fF/um2 fringe_cap 100aF/um
    \\device bjt bjtm model "npn" terminals [pina, pinb, pinc]
    \\device inductor indm model "spiral" terminals [pina, pina] inductance 2nH
    \\
;

/// Every name `fromLayoutInto` can write.
const all_names = [_][]const u8{ "w", "l", "area", "perim", "nf", "as", "ad", "ps", "pd", "ae", "pe", "r", "c", "ind" };
/// One expected parameter.
const Want = struct { []const u8, f64 };
/// A row a run wrote: measured, limit, shape, at, layer.
const Row = struct { Measurement, Measurement, PolyId, geom.Point, LayerId };

/// A bound row as written.
const RangeRow = struct { []const u8, []const u8, ?LvsLimit, ?LvsLimit };

/// The drawing, extracted and recognised under `deck_text`; `deinit` frees it.
const Extracted = struct {
    arena: std.heap.ArenaAllocator,
    strings: StrTable = .empty,
    store: GeometryStore = .empty,
    ids: Ids = .{},
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},

    fn deinit(e: *Extracted) void {
        e.strings.deinit(gpa);
        e.store.deinit(gpa);
        e.ids.deinit(gpa);
        e.nets.deinit(gpa);
        e.devices.deinit(gpa);
        e.arena.deinit();
    }

    fn design(e: *const Extracted) lvs.Design {
        return .{ .store = &e.store, .nets = &e.nets, .devices = &e.devices };
    }
};

// ---- private ----

/// Two nmos sharing their middle diffusion, and one each of resistor,
/// capacitor, bipolar and inductor, each marker over 400 nm pads 800 apart.
fn drawInto(lb: *LayoutBuilder, layers: *const deck.LayerTable, strings: *const StrTable) !void {
    const mos = [_]struct { []const u8, [4]i64 }{
        .{ "gate", .{ 500, 0, 650, 1000 } },    .{ "gate", .{ 1150, 0, 1300, 1000 } },
        .{ "poly", .{ 500, -200, 650, 1200 } }, .{ "poly", .{ 1150, -200, 1300, 1200 } },
        .{ "sd", .{ 0, 0, 500, 1000 } },        .{ "sd", .{ 650, 0, 1150, 1000 } },
        .{ "sd", .{ 1300, 0, 1800, 1000 } },
    };
    for (mos) |s| _ = try lb.rect(gpa, @backingInt(layers.id(strings, s[0]).?), s[1][0], s[1][1], s[1][2], s[1][3]);
    for ([_]struct { i64, []const u8, []const []const u8 }{
        .{ -2000, "resm", &.{ "pina", "pina" } },
        .{ -4000, "capm", &.{ "pina", "pinb" } },
        .{ -6000, "bjtm", &.{ "pina", "pinb", "pinc" } },
        .{ -8000, "indm", &.{ "pina", "pina" } },
    }) |row| {
        var right: i64 = 0;
        for (row[2], 0..) |pad, k| {
            const x = 800 * @as(i64, @intCast(k));
            _ = try lb.rect(gpa, @backingInt(layers.id(strings, pad).?), x, row[0], x + 400, row[0] + 400);
            right = x;
        }
        _ = try lb.rect(gpa, @backingInt(layers.id(strings, row[1]).?), 200, row[0], right + 200, row[0] + 400);
    }
}

fn extract(e: *Extracted, names: []const []const u8) !void {
    e.* = .{ .arena = .init(gpa) };
    for (names) |n| _ = try e.strings.intern(gpa, n);
    var diag: deck.Diag = .{};
    const dk = try deck.parseDeck(e.arena.allocator(), gpa, deck_text, try Grid.init(1000), &e.strings, &diag);
    var lb = LayoutBuilder.init(@intCast(dk.layers.len()));
    defer lb.deinit(gpa);
    try drawInto(&lb, &dk.layers, &e.strings);
    try lb.finish(gpa, &e.store, &e.ids);
    try topology.extractNetsInto(gpa, &e.store, &dk.connectivity, &e.nets);
    try topology.recogniseInto(gpa, &e.store, &e.nets, &dk.devices, &e.devices);
}

/// One device's parameters, sorted by name then value, against `want`.
fn expectClose(e: *const Extracted, g: *const Graph, device: u32, want_in: []const Want) !void {
    const got = try gpa.alloc(Want, g.paramsOf(device).len);
    defer gpa.free(got);
    for (g.paramsOf(device), got) |p, *w| w.* = .{ e.strings.resolve(p.name), p.value };
    const want = try gpa.dupe(Want, want_in);
    defer gpa.free(want);
    const less = struct {
        fn f(_: void, a: Want, b: Want) bool {
            const o = std.mem.order(u8, a[0], b[0]);
            return if (o != .eq) o == .lt else a[1] < b[1];
        }
    }.f;
    std.mem.sort(Want, got, {}, less);
    std.mem.sort(Want, want, {}, less);
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g_, w| {
        try testing.expectEqualStrings(w[0], g_[0]);
        if (!(@abs(g_[1] - w[1]) <= 1e-9 * @abs(w[1]))) {
            std.debug.print("{s} = {e}, want {e}\n", .{ g_[0], g_[1], w[1] });
            return error.TestParamDiffers;
        }
    }
}

fn rowList(out: *const Violations, rows: *std.ArrayList(Row)) !void {
    rows.clearRetainingCapacity();
    for (0..out.len()) |i| {
        const v = out.get(@intCast(i));
        try rows.append(gpa, .{ v.measured, v.limit, v.shape_a, v.at, v.layer });
    }
}

fn rowEql(a: Row, b: Row) bool {
    return a[0].eql(b[0]) and a[1].eql(b[1]) and a[2] == b[2] and a[3].eql(b[3]) and a[4] == b[4];
}

/// `checkParamRanges` over the drawing into `rows`; its run, if any.
fn ranges(e: *Extracted, rows_in: []const RangeRow, rows: *std.ArrayList(Row)) !?RuleRun {
    try extract(e, &.{});
    try lvs.internRuleIds(gpa, &e.strings);
    var bounds: std.ArrayList(LvsRange) = .empty;
    defer bounds.deinit(gpa);
    for (rows_in) |r| try bounds.append(gpa, .{ .model = try e.strings.intern(gpa, r[0]), .param = try e.strings.intern(gpa, r[1]), .min = r[2], .max = r[3] });
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try lvs.checkParamRanges(gpa, e.design(), bounds.items, &e.strings, &out, &runs);
    try testing.expect(runs.items.len <= 1);
    try rowList(&out, rows);
    return if (runs.items.len == 1) runs.items[0] else null;
}

fn on(store: *const GeometryStore, marker: PolyId) struct { geom.Point, LayerId } {
    return .{ store.firstVertex(marker), store.polyLayer(marker) };
}

fn length(v: i64) LvsLimit {
    return .{ .length = v };
}

fn area(v: i128) ?LvsLimit {
    return .{ .area = v };
}

test "measured parameters are the drawing in si and the values follow their laws" {
    // Oracle: hand-derived from fromLayoutInto's doc and the drawing, at
    // 1e-9 m per unit: each nmos w 1000 nm, l 150, nf 1, gate area 1.5e-13
    // m² and perim 2.3e-6 m, its outer diffusion whole (5e-13, 3e-6) and the
    // shared middle halved (2.5e-13, 1.5e-6); the resistor l 800, w 400,
    // area 3.2e-13, perim 2.4e-6, r = 100 Ω/□ × 800/400 = 200 Ω; the
    // capacitor c = 1 fF/µm² × 0.32 µm² + 0.1 fF/µm × 2.4 µm = 0.56 fF; the
    // bipolar's marker 6.4e-13, 4e-6, its emitter the middle pad, ae
    // 1.6e-13, pe 1.6e-6; the inductor ind 2 nH.
    var e: Extracted = undefined;
    try extract(&e, &all_names);
    defer e.deinit();
    const ports: topology.PortTable = .{};
    var g: Graph = .{};
    defer g.deinit(gpa);
    try lvs.fromLayoutInto(gpa, &e.nets, &e.devices, &ports, &e.strings, try Grid.init(1000), &g);
    var mos_count: usize = 0;
    for (g.device_kind.items, 0..) |kind, di| {
        const d: u32 = @intCast(di);
        switch (kind) {
            .mos => {
                mos_count += 1;
                const as_value = for (g.paramsOf(d)) |p| (if (std.mem.eql(u8, e.strings.resolve(p.name), "as")) break p.value) else 0.0;
                const whole = [2]f64{ 5e-13, 3e-6 };
                const half = [2]f64{ 2.5e-13, 1.5e-6 };
                const s = if (@abs(as_value - whole[0]) < 1e-20) whole else half;
                const dr = if (@abs(as_value - whole[0]) < 1e-20) half else whole;
                try expectClose(&e, &g, d, &.{ .{ "w", 1e-6 }, .{ "l", 150e-9 }, .{ "nf", 1.0 }, .{ "area", 1.5e-13 }, .{ "perim", 2.3e-6 }, .{ "as", s[0] }, .{ "ps", s[1] }, .{ "ad", dr[0] }, .{ "pd", dr[1] } });
            },
            .resistor => try expectClose(&e, &g, d, &.{ .{ "w", 400e-9 }, .{ "l", 800e-9 }, .{ "area", 3.2e-13 }, .{ "perim", 2.4e-6 }, .{ "r", 200.0 } }),
            .capacitor => try expectClose(&e, &g, d, &.{ .{ "area", 3.2e-13 }, .{ "perim", 2.4e-6 }, .{ "c", 5.6e-16 } }),
            .bjt => try expectClose(&e, &g, d, &.{ .{ "area", 6.4e-13 }, .{ "perim", 4e-6 }, .{ "ae", 1.6e-13 }, .{ "pe", 1.6e-6 } }),
            .inductor => try expectClose(&e, &g, d, &.{ .{ "area", 3.2e-13 }, .{ "perim", 2.4e-6 }, .{ "ind", 2e-9 } }),
            .diode, .cell => return error.TestUnexpectedKind,
        }
    }
    try testing.expectEqual(@as(usize, 2), mos_count);
}

test "without a grid only counts and stated values are written" {
    // Oracle: fromLayoutInto's doc: with no grid a length or area has no
    // unit and is omitted, and so are r and c; a count (nf) and the
    // inductance stay. With no name interned nothing is written.
    var e: Extracted = undefined;
    try extract(&e, &all_names);
    defer e.deinit();
    const ports: topology.PortTable = .{};
    var g: Graph = .{};
    defer g.deinit(gpa);
    try lvs.fromLayoutInto(gpa, &e.nets, &e.devices, &ports, &e.strings, null, &g);
    for (g.device_kind.items, 0..) |kind, d| {
        const want: []const Want = switch (kind) {
            .mos => &.{.{ "nf", 1.0 }},
            .inductor => &.{.{ "ind", 2e-9 }},
            .bjt, .resistor, .capacitor, .diode, .cell => &.{},
        };
        try expectClose(&e, &g, @intCast(d), want);
    }
    var bare: Extracted = undefined;
    try extract(&bare, &.{});
    defer bare.deinit();
    var g2: Graph = .{};
    defer g2.deinit(gpa);
    try lvs.fromLayoutInto(gpa, &bare.nets, &bare.devices, &ports, &bare.strings, try Grid.init(1000), &g2);
    try testing.expectEqual(@as(u32, 6), g2.deviceCount());
    try testing.expectEqual(@as(usize, 0), g2.param.items.len);
}

test "a length at its bound passes and one unit past fails" {
    // Oracle: checkParamRanges' doc ("a value at a bound is legal") against
    // the drawing: each nmos is 1000 wide, so [1000, 1000] passes both and
    // one unit inside either end fails both, measured 1000 against the
    // bound, on each gate's first vertex; two rows over two transistors
    // examine four pairs; a range with no bound finds nothing.
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    {
        var e: Extracted = undefined;
        const run = (try ranges(&e, &.{.{ "nmos", "w", length(1000), length(1000) }}, &rows)).?;
        defer e.deinit();
        try testing.expect(run.outcome == .ran);
        try testing.expectEqual(@as(u64, 2), run.examined);
        try testing.expectEqual(@as(u32, 0), run.violations);
        try testing.expectEqual(@as(usize, 0), rows.items.len);
    }
    for ([_][3]i64{ .{ 1001, 2000, 1001 }, .{ 0, 999, 999 } }) |case| {
        var e: Extracted = undefined;
        const run = (try ranges(&e, &.{ .{ "nmos", "w", length(case[0]), length(case[1]) }, .{ "nmos", "l", null, null } }, &rows)).?;
        defer e.deinit();
        try testing.expect(run.outcome == .ran);
        try testing.expectEqual(@as(u64, 4), run.examined);
        try testing.expectEqual(@as(u32, 2), run.violations);
        var at: usize = 0;
        for (e.devices.kind.items, e.devices.marker.items) |kind, marker| {
            if (kind != .mos) continue;
            const where = on(&e.store, marker);
            try testing.expect(rowEql(rows.items[at], .{ .length(1000), .length(case[2]), marker, where[0], where[1] }));
            at += 1;
        }
        try testing.expectEqual(rows.items.len, at);
    }
}

test "a shared diffusion is held to its bound by its share" {
    // Oracle: the doc's share rule, hand-derived: each nmos has one end to
    // itself (500000 nm²) and shares the middle (a share of 250000). A max
    // of 250000 on as and ad fails each whole end, the ratio 500000 against
    // 250000; at 249999 the shared ends fail too, as the ratio 250000.
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    for ([_]struct { i128, []const f64 }{ .{ 250_000, &.{ 500_000.0, 500_000.0 } }, .{ 249_999, &.{ 250_000.0, 250_000.0, 500_000.0, 500_000.0 } } }) |case| {
        var e: Extracted = undefined;
        const run = (try ranges(&e, &.{ .{ "nmos", "as", null, area(case[0]) }, .{ "nmos", "ad", null, area(case[0]) } }, &rows)).?;
        defer e.deinit();
        try testing.expect(run.outcome == .ran);
        try testing.expectEqual(@as(u64, 4), run.examined);
        const got = try gpa.alloc(f64, rows.items.len);
        defer gpa.free(got);
        for (rows.items, got) |r, *g_| {
            try testing.expect(r[0].kind == .ratio and r[1].kind == .ratio);
            try testing.expect(@abs(r[1].float() - @as(f64, @floatFromInt(case[0]))) < 1e-9);
            g_.* = r[0].float();
        }
        std.mem.sort(f64, got, {}, std.sort.asc(f64));
        try testing.expectEqualSlices(f64, case[1], got);
    }
}

test "areas and counts compare exactly and what cannot be compared refuses" {
    // Oracle: the doc, hand-derived: the resistor's marker is 320000 nm²,
    // an area compared exactly; each nmos one finger, a count; a bound of
    // another kind (a w against an area) or a parameter not measured on the
    // model (ae on a transistor) refuses the run, keeping its other rows.
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    {
        var e: Extracted = undefined;
        const run = (try ranges(&e, &.{.{ "rpoly", "area", null, area(320_000) }}, &rows)).?;
        defer e.deinit();
        try testing.expect(run.outcome == .ran and run.violations == 0 and rows.items.len == 0);
    }
    {
        var e: Extracted = undefined;
        _ = try ranges(&e, &.{.{ "rpoly", "area", null, area(319_999) }}, &rows);
        defer e.deinit();
        try testing.expectEqual(@as(usize, 1), rows.items.len);
        try testing.expect(rows.items[0][0].eql(.area(320_000)) and rows.items[0][1].eql(.area(319_999)));
    }
    {
        var e: Extracted = undefined;
        _ = try ranges(&e, &.{.{ "nmos", "nf", .{ .count = 2 }, null }}, &rows);
        defer e.deinit();
        try testing.expectEqual(@as(usize, 2), rows.items.len);
        for (rows.items) |r| try testing.expect(r[0].eql(.count(1)) and r[1].eql(.count(2)));
    }
    {
        var e: Extracted = undefined;
        _ = try ranges(&e, &.{.{ "nmos", "nf", .{ .count = 1 }, .{ .count = 1 } }}, &rows);
        defer e.deinit();
        try testing.expectEqual(@as(usize, 0), rows.items.len);
    }
    for ([_][]const u8{ "w", "ae" }) |param| {
        var e: Extracted = undefined;
        const run = (try ranges(&e, &.{ .{ "nmos", param, null, area(1) }, .{ "nmos", "w", null, length(999) } }, &rows)).?;
        defer e.deinit();
        try testing.expect(run.outcome == .refused);
        try testing.expectEqual(@as(u32, 2), run.violations);
        try testing.expectEqual(@as(usize, 2), rows.items.len);
    }
    var e: Extracted = undefined;
    const run = try ranges(&e, &.{}, &rows);
    defer e.deinit();
    try testing.expect(run == null and rows.items.len == 0);
}

test "device counts are held to their bounds" {
    // Oracle: checkDeviceCounts' doc, hand-derived: two nmos against a max
    // of 1 is one row on the second, 2 against 1; against a min of 3 one row
    // on the first, 2 against 3; a model with no device under a min of 1 a
    // row with no shape at the origin, 0 against 1; at the bounds nothing.
    var e: Extracted = undefined;
    try extract(&e, &.{});
    defer e.deinit();
    try lvs.internRuleIds(gpa, &e.strings);
    const nmos = try e.strings.intern(gpa, "nmos");
    const pmos = try e.strings.intern(gpa, "pmos");
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try lvs.checkDeviceCounts(gpa, e.design(), &.{.{ .model = nmos, .min = 2, .max = 2 }}, &e.strings, &out, &runs);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(@as(u64, 1), runs.items[0].examined);
    try testing.expectEqual(@as(u32, 0), out.len());
    var mos: [2]PolyId = undefined;
    var n: usize = 0;
    for (e.devices.model.items, e.devices.marker.items) |m, marker| if (m == nmos) {
        mos[n] = marker;
        n += 1;
    };
    var out2: Violations = .{};
    defer out2.deinit(gpa);
    runs.clearRetainingCapacity();
    try lvs.checkDeviceCounts(gpa, e.design(), &.{ .{ .model = nmos, .min = 3, .max = 1 }, .{ .model = pmos, .min = 1, .max = null } }, &e.strings, &out2, &runs);
    try testing.expectEqual(@as(u64, 2), runs.items[0].examined);
    try testing.expectEqual(@as(u32, 3), runs.items[0].violations);
    try rowList(&out2, &rows);
    const second = on(&e.store, mos[1]);
    const first = on(&e.store, mos[0]);
    const want = [_]Row{
        .{ .count(2), .count(1), mos[1], second[0], second[1] },
        .{ .count(2), .count(3), mos[0], first[0], first[1] },
        .{ .count(0), .count(1), report.no_shape, report.nowhere, report.no_layer },
    };
    try testing.expectEqual(want.len, rows.items.len);
    for (want, rows.items) |w, r| try testing.expect(rowEql(w, r));
    var out3: Violations = .{};
    defer out3.deinit(gpa);
    runs.clearRetainingCapacity();
    try lvs.checkDeviceCounts(gpa, e.design(), &.{}, &e.strings, &out3, &runs);
    try testing.expectEqual(@as(usize, 0), runs.items.len);
}
