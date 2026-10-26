//! The ESD kinds that measure geometry, each on a cell drawn by hand with a
//! closed-form or by-construction answer: `esd_path`'s forced current and
//! `esd_parasitic`. Ported from crates/check/tests/erc/esd_geometry.rs (the
//! tie_area, guard_ring and latchup_victim tests are the latchup suite's).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const report = check.report;
const NetId = check.topology.NetId;
const erc = check.erc;
const IntentMap = erc.facts.IntentMap;
const deinitTable = erc.rule_set.deinitTable;
const Handle = testgen.shapes.Handle;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const gpa = common.gpa;

const pad_layer: u16 = 0;
const met1: u16 = 1;
const padv: u16 = 2;
const mkd: u16 = 3;
const diff: u16 = 4;
const dcut: u16 = 5;
const layers: u16 = 10;

/// The diode clamp model, recognised under `mkd` with its anode on met1
/// and its cathode on the pad.
const dio: StrId = @fromBackingInt(500);

/// A drawn cell, extracted: `pad`, `met1` and `diff` conduct and join
/// within a layer by touching; `padv` joins met1 to the pad and `dcut`
/// diffusion to the pad.
const Cell = struct {
    store: geom.GeometryStore = .empty,
    ids: testgen.shapes.Ids = .{},
    nets: check.topology.NetTable = .{},
    devices: check.topology.DeviceTable = .{},
    sheet: [layers]f64 = @splat(1.0),
    height: [layers]f64 = @splat(0.0),
    stack: ingest.deck.ProcessStack = .{},
    connectivity: ingest.deck.Connectivity = .{
        .conductors = &.{ l(pad_layer), l(met1), l(diff), l(6) },
        .via_cut = &.{ l(padv), l(dcut) },
        .via_connects = &.{ .{ l(met1), l(pad_layer) }, .{ l(diff), l(pad_layer) } },
        .intra_layer_touch = true,
    },

    fn init(c: *Cell, lb: *LayoutBuilder) !void {
        try lb.finish(gpa, &c.store, &c.ids);
        try check.topology.extractNetsInto(gpa, &c.store, &c.connectivity, &c.nets);
        const recognition: ingest.deck.DeviceRecognition = .{ .kind = &.{.diode}, .marker = &.{l(mkd)}, .terminal_start = &.{ 0, 2 }, .terminal = &.{ l(met1), l(pad_layer) }, .model = &.{dio}, .value = &.{.{}} };
        try check.topology.recogniseInto(gpa, &c.store, &c.nets, &recognition, &c.devices);
        c.sheet[pad_layer] = 0.0625;
        c.sheet[met1] = 0.125;
        c.sheet[padv] = 0.25;
        c.stack = .{ .sheet_res_ohm_sq = &c.sheet, .height_nm = &c.height };
    }

    fn deinit(c: *Cell) void {
        c.store.deinit(gpa);
        c.ids.deinit(gpa);
        c.nets.deinit(gpa);
        c.devices.deinit(gpa);
    }

    fn design(c: *const Cell) erc.Design {
        return .{ .store = &c.store, .nets = &c.nets, .devices = &c.devices };
    }

    fn process(c: *const Cell) erc.power_grid.Process {
        return .{ .grid = common.manufacturingGrid(), .stack = &c.stack, .connectivity = &c.connectivity };
    }

    fn net(c: *const Cell, h: Handle) NetId {
        return c.nets.netOf(c.ids.of(h));
    }

    /// Intent declaring the net of `ground` a ground of a 1.8 V domain.
    fn ground(c: *const Cell, h: Handle) !IntentMap {
        var m: IntentMap = .{ .declared = true };
        try m.supply_net.append(gpa, c.net(h));
        try m.supply_role.append(gpa, .ground);
        try m.supply_domain.append(gpa, @fromBackingInt(0));
        try m.supply_voltage.append(gpa, .{ .raw = 1800 });
        return m;
    }
};

// ---- private ----

/// The pad strip, the VSS strip 3 µm below it, and a 200 nm diode marker
/// spanning the two at each x of `diodes`; returns (pad, vss).
fn strips(lb: *LayoutBuilder, diodes: []const i64) ![2]Handle {
    const pad = try lb.rect(gpa, pad_layer, 0, 0, 20_000, 1000);
    const vss = try lb.rect(gpa, met1, 0, -3000, 20_000, -2000);
    for (diodes) |x| _ = try lb.rect(gpa, mkd, x - 100, -2100, x + 100, 100);
    return .{ pad, vss };
}

/// One `esd_path` row forcing 1.33 A, each clamp 1 Ω, holding clamps to
/// `it2` A/m.
fn pathTable(it2: f64) !erc.esd_tables.EsdPathTable {
    var t: erc.esd_tables.EsdPathTable = .{};
    try t.head.push(gpa, common.rule(1), .@"error");
    try t.pad.append(gpa, l(pad_layer));
    try t.source.append(gpa, l(pad_layer));
    try t.clamp_start.appendSlice(gpa, &.{ 0, 1 });
    try t.clamp.append(gpa, dio);
    try t.current.append(gpa, .{ .raw = 1.33e6 });
    try t.clamp_resistance.append(gpa, .{ .raw = 1.0 });
    try t.max_resistance.append(gpa, null);
    try t.clamp_it2.append(gpa, .{ .raw = it2 });
    try t.max_density.append(gpa, null);
    try t.max_current_per_cut.append(gpa, null);
    try t.max_voltage.append(gpa, null);
    try t.min_width.append(gpa, null);
    try t.clamp_voltage.append(gpa, null);
    return t;
}

/// Runs the path table over a cell with clamps at `diodes`, into `sink`.
fn runPath(diodes: []const i64, it2: f64, sink: *common.Sink) !void {
    var lb = LayoutBuilder.init(layers);
    defer lb.deinit(gpa);
    const drawn = try strips(&lb, diodes);
    var cell: Cell = .{};
    defer cell.deinit();
    try cell.init(&lb);
    try testing.expectEqual(@as(u32, @intCast(diodes.len)), cell.devices.len());
    var intent = try cell.ground(drawn[1]);
    defer intent.deinit(gpa);
    var t = try pathTable(it2);
    defer deinitTable(gpa, &t);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.esd.checkEsdPath(sink.record(), cell.design(), &intent, cell.process(), &t, &scratch);
}

fn l(i: u16) LayerId {
    return @fromBackingInt(i);
}

test "parallel clamps share the forced current" {
    // Oracle: Kirchhoff's current law: the shares sum to the 1.33 A forced
    // in, and with the clamps at different distances from the entry the
    // shares differ. One pin pair is solved.
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runPath(&.{ 2000, 8000, 14_000 }, 1.0, &sink);
    try testing.expectEqual(@as(u32, 3), sink.out.len());
    var total: f64 = 0;
    for (0..3) |i| total += sink.out.get(@intCast(i)).measured.float();
    try testing.expect(@abs(total - 1.33e6) <= 1e-6 * 1.33e6);
    try testing.expect(@abs(sink.out.get(0).measured.float() - sink.out.get(2).measured.float()) > 1.0);
    try testing.expectEqual(@as(u64, 1), (try common.runOf(sink.runs.items, common.rule(1))).examined);
}

test "a clamp is rated its it2 times its perimeter" {
    // Oracle: closed form: one down diode carries all 1.33 A; its marker is
    // 200 nm by 2.2 µm, 4.8 µm round; rated just below 1.33 A / 4.8 µm it is
    // flagged with all 1.33 A, just above it is clean.
    const rated = 1.33 / 4.8e-6;
    for ([_]struct { f64, bool }{ .{ rated * 0.999, true }, .{ rated * 1.001, false } }) |case| {
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runPath(&.{2000}, case[0], &sink);
        if (case[1]) {
            try testing.expectEqual(@as(u32, 1), sink.out.len());
            try testing.expect(@abs(sink.out.get(0).measured.float() - 1.33e6) <= 1e-6 * 1.33e6);
        } else try testing.expectEqual(@as(u32, 0), sink.out.len());
    }
}

test "a supply with no pin is held at its widest shape" {
    // Oracle: the rule `extractStressInto`'s doc states: both shapes are on
    // met1, so the widest, the strip, carries the held node.
    var lb = LayoutBuilder.init(layers);
    defer lb.deinit(gpa);
    const stub = try lb.rect(gpa, met1, 19_000, -2000, 20_000, -1500);
    const drawn = try strips(&lb, &.{2000});
    var cell: Cell = .{};
    defer cell.deinit();
    try cell.init(&lb);
    try testing.expectEqual(cell.net(drawn[1]), cell.net(stub));
    var nets = [2]NetId{ cell.net(drawn[0]), cell.net(drawn[1]) };
    std.mem.sortUnstable(NetId, &nets, {}, struct {
        fn less(_: void, a: NetId, b: NetId) bool {
            return @backingInt(a) < @backingInt(b);
        }
    }.less);
    var grid: erc.power_extract.StressGrid = .{};
    defer grid.deinit(gpa);
    var diag: erc.power_grid.PowerDiag = .{};
    try erc.power_extract.extractStressInto(gpa, &cell.store, &cell.nets, &cell.devices, cell.process(), .{ .nets = &nets, .source = cell.ids.of(drawn[0]), .current = .{ .raw = 1.33e6 }, .sink = cell.net(drawn[1]), .pins = &.{}, .devices = &.{}, .device_resistance = .{ .raw = 1.0 } }, &grid, &diag);
    try testing.expectEqual(@as(usize, 1), grid.grid.source_node.items.len);
    try testing.expectEqual(cell.ids.of(drawn[1]), grid.grid.node_poly.items[grid.grid.source_node.items[0]]);
}

test "a pad junction is flagged only closer than the spacing" {
    // Oracle: by construction against 5 µm: a pad's diffusion `d1` with
    // another net's `d0` 4999 nm to its left (drawn first, the lower row),
    // and a third diagonally off its corner 4 µm on each axis (5657 nm
    // away): only the 4999 nm pair is closer.
    var lb = LayoutBuilder.init(layers);
    defer lb.deinit(gpa);
    const d0 = try lb.rect(gpa, diff, 0, 5000, 1000, 6000);
    const d1 = try lb.rect(gpa, diff, 5999, 5000, 6999, 6000);
    _ = try lb.rect(gpa, pad_layer, 5999, 5000, 6999, 6000);
    _ = try lb.rect(gpa, dcut, 6400, 5400, 6600, 5600);
    _ = try lb.rect(gpa, diff, 10_999, 10_000, 11_999, 11_000);
    var cell: Cell = .{};
    defer cell.deinit();
    try cell.init(&lb);
    try testing.expect(@backingInt(cell.ids.of(d0)) < @backingInt(cell.ids.of(d1)));
    var t: erc.esd_tables.EsdParasiticTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, common.rule(2), .@"error");
    try t.pad.append(gpa, l(pad_layer));
    try t.diffusion.append(gpa, l(diff));
    try t.min_spacing.append(gpa, 5000);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.esd.checkEsdParasitic(sink.record(), cell.design(), &t);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(.length(4999)));
    try testing.expectEqual(cell.ids.of(d1), sink.out.shape_a.items[0]);
}
