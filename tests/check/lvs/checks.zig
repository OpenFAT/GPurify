//! The layout-only checks and the `RuleRun` discipline: a clean result is
//! two claims (this rule ran and examined N things, and it found nothing),
//! both asserted every time. Ported from crates/check/tests/lvs/checks.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const PolyId = geom.PolyId;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const LvsControls = ingest.deck.LvsControls;
const Connectivity = ingest.deck.Connectivity;
const Label = ingest.provenance.Label;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const report = check.report;
const Violations = report.Violations;
const Violation = report.Violation;
const RuleRun = report.RuleRun;
const topology = check.topology;
const NetTable = topology.NetTable;
const DeviceTable = topology.DeviceTable;
const PortTable = topology.PortTable;
const LayoutBuilder = @import("testgen").shapes.LayoutBuilder;
const Ids = @import("testgen").shapes.Ids;
const common = @import("common.zig");
const id = common.id;
const gpa = testing.allocator;

const metal: u16 = 0;

/// The tables one hand-drawn layout gives the checks; `deinit` frees them.
const Drawn = struct {
    store: GeometryStore = .empty,
    ids: Ids = .{},
    nets: NetTable = .{},
    devices: DeviceTable = .{},
    ports: PortTable = .{},
    strings: StrTable = .empty,
    graph: Graph = .{},

    fn deinit(d: *Drawn) void {
        d.store.deinit(gpa);
        d.ids.deinit(gpa);
        d.nets.deinit(gpa);
        d.devices.deinit(gpa);
        d.ports.deinit(gpa);
        d.strings.deinit(gpa);
        d.graph.deinit(gpa);
    }

    fn design(d: *const Drawn) lvs.Design {
        return .{ .store = &d.store, .nets = &d.nets, .devices = &d.devices };
    }
};

// ---- private ----

/// The structural rows `checkLayout` writes for `graph` over empty tables.
fn checkTopology(graph: *const Graph, out: *Violations, runs: *std.ArrayList(RuleRun)) !void {
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    try lvs.internRuleIds(gpa, &strings);
    var all: std.ArrayList(RuleRun) = .empty;
    defer all.deinit(gpa);
    const store: GeometryStore = .empty;
    const nets: NetTable = .{};
    const devices: DeviceTable = .{};
    const ports: PortTable = .{};
    try lvs.checkLayout(gpa, graph, .{ .store = &store, .nets = &nets, .devices = &devices }, &ports, &strings, &.{}, out, &all);
    try testing.expectEqual(@as(usize, 5), all.items.len);
    const structural = [_]StrId{ strings.get("lvs.terminal_net").?, strings.get("lvs.terminal_count").? };
    for (all.items) |run| if (run.rule == structural[0] or run.rule == structural[1]) try runs.append(gpa, run);
}

/// A rule ran over a non-empty input, examined something, and its rows are
/// the rows it says it wrote.
fn assertRan(runs: []const RuleRun, out: *const Violations, expected: usize) !void {
    try testing.expect(runs.len > 0);
    var reported: u64 = 0;
    var examined = false;
    for (runs) |run| {
        try testing.expect(run.outcome == .ran);
        reported += run.violations;
        examined = examined or run.examined > 0;
    }
    try testing.expect(examined);
    try testing.expectEqual(@as(u64, out.len()), reported);
    try testing.expectEqual(expected, out.len());
}

/// Rows of `out` under `rule`.
fn rowsOf(out: *const Violations, rule: StrId, buf: []Violation) []Violation {
    var n: usize = 0;
    for (0..out.len()) |row| {
        const v = out.get(@intCast(row));
        if (v.rule == rule) {
            buf[n] = v;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Rectangles on `layers` layers, nets extracted with `metal` a conductor
/// and `global` (if any) a global layer, rule ids interned.
fn draw(d: *Drawn, layers: u16, rects: []const [5]i64, global: ?u16) ![8]PolyId {
    var lb = LayoutBuilder.init(layers);
    defer lb.deinit(gpa);
    var handles: [8]@import("testgen").shapes.Handle = undefined;
    for (rects, 0..) |r, i| handles[i] = try lb.rect(gpa, @intCast(r[0]), r[1], r[2], r[3], r[4]);
    try lb.finish(gpa, &d.store, &d.ids);
    var polys: [8]PolyId = undefined;
    for (rects, 0..) |_, i| polys[i] = d.ids.of(handles[i]);
    const conductors = [_]LayerId{@fromBackingInt(metal)};
    const globals: []const LayerId = if (global) |g| &.{@fromBackingInt(g)} else &.{};
    const connectivity: Connectivity = .{ .conductors = &conductors, .intra_layer_touch = true, .global = globals };
    try topology.extractNetsInto(gpa, &d.store, &connectivity, &d.nets);
    try lvs.internRuleIds(gpa, &d.strings);
    return polys;
}

fn bindAndProject(d: *Drawn, labels: []const Label) !void {
    try topology.bindPortsInto(gpa, &d.nets, labels, &d.ports);
    try lvs.fromLayoutInto(gpa, &d.nets, &d.devices, &d.ports, &d.strings, null, &d.graph);
}

fn expectAt(v: Violation, x: i64, y: i64, layer: u16) !void {
    try testing.expectEqual(x, v.at.x);
    try testing.expectEqual(y, v.at.y);
    try testing.expectEqual(@as(LayerId, @fromBackingInt(layer)), v.layer);
}

fn expectCounts(v: Violation, measured: u32, limit: u32) !void {
    try testing.expect(v.measured.eql(.count(measured)));
    try testing.expect(v.limit.eql(.count(limit)));
}

test "a well formed graph is structurally clean and the check says it looked" {
    // Oracle: construct-from-answer. Every device of the stacked pair and of
    // the MOS and bipolar has its family's full terminal set on nets that
    // exist: nothing to find, and the run says so while saying it looked.
    var a = try common.stackedPair();
    defer a.deinit(gpa);
    var b = try common.mosAndBjt();
    defer b.deinit(gpa);
    for ([_]*const Graph{ &a, &b }) |g| {
        var out: Violations = .{};
        defer out.deinit(gpa);
        var runs: std.ArrayList(RuleRun) = .empty;
        defer runs.deinit(gpa);
        try checkTopology(g, &out, &runs);
        try assertRan(runs.items, &out, 0);
    }
}

test "a terminal naming a net that does not exist is found" {
    // Oracle: construct-from-answer. One terminal repointed at net 6 of a
    // six-net graph: nothing can be on the other end of it.
    var g = try common.stackedPair();
    defer g.deinit(gpa);
    g.terminal_net.items[g.device_terminal_start.items[1]] = g.netCount();
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try checkTopology(&g, &out, &runs);
    try assertRan(runs.items, &out, 1);
}

test "a graph with devices but no terminal csr refuses rather than reporting clean" {
    // Oracle: construct-from-answer, on the reporting: the column the
    // terminal-count question is about does not exist, so the check is
    // refused, examining nothing, in every build profile.
    var g = try common.stackedPair();
    defer g.deinit(gpa);
    try testing.expect(g.deviceCount() > 0);
    g.device_terminal_start.clearRetainingCapacity();
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try checkTopology(&g, &out, &runs);
    const refused = for (runs.items) |run| (if (run.outcome != .ran) break run) else return error.TestNoRefusal;
    try testing.expect(refused.outcome == .refused);
    try testing.expectEqual(@as(u64, 0), refused.examined);
}

test "two names on one net are one seed conflict row at the first label" {
    // Oracle: construct-from-answer, F13, F14. Two touching rectangles are
    // one net; labelled VDD (right) and VSS (left) they are a short: one
    // `lvs.net_seed_conflict` row naming VDD's shape then VSS's, at (90, 0)
    // on metal, measured 2 against 1, and one `lvs.short_path` row (the
    // shapes touch), each carrying the labels VDD and VSS in `StrId` order
    // (`Violations.labelsOf`); no other row carries labels. With one label,
    // no conflict.
    var d: Drawn = .{};
    defer d.deinit();
    const polys = try draw(&d, 1, &.{ .{ metal, 0, 0, 100, 100 }, .{ metal, 90, 0, 200, 100 } }, null);
    const left = polys[0];
    const right = polys[1];
    try testing.expect(d.nets.sameNet(left, right));
    const vdd = try d.strings.intern(gpa, "VDD");
    const vss = try d.strings.intern(gpa, "VSS");
    const rule = d.strings.get("lvs.net_seed_conflict").?;
    for ([_]struct { []const Label, usize }{ .{ &.{ .{ .poly = right, .name = vdd }, .{ .poly = left, .name = vss } }, 1 }, .{ &.{.{ .poly = right, .name = vdd }}, 0 } }) |case| {
        try bindAndProject(&d, case[0]);
        var out: Violations = .{};
        defer out.deinit(gpa);
        var runs: std.ArrayList(RuleRun) = .empty;
        defer runs.deinit(gpa);
        try lvs.checkLayout(gpa, &d.graph, d.design(), &d.ports, &d.strings, &.{}, &out, &runs);
        const run = for (runs.items) |r| (if (r.rule == rule) break r) else return error.TestNoRow;
        try testing.expect(run.outcome == .ran);
        try testing.expectEqual(@as(u64, case[0].len), run.examined);
        var buf: [8]Violation = undefined;
        const found = rowsOf(&out, rule, &buf);
        try testing.expectEqual(case[1], found.len);
        if (found.len > 0) {
            try testing.expectEqual(right, found[0].shape_a);
            try testing.expectEqual(left, found[0].shape_b);
            try expectAt(found[0], 90, 0, metal);
            try expectCounts(found[0], 2, 1);
        }
        const path_rule = d.strings.get("lvs.short_path").?;
        var labelled: usize = 0;
        for (0..out.len()) |row| {
            const r = out.get(@intCast(row));
            const short = r.rule == rule or r.rule == path_rule;
            if (out.labelsOf(@intCast(row))) |names| {
                try testing.expect(short);
                try testing.expectEqual([2]StrId{ vdd, vss }, names);
                labelled += 1;
            } else try testing.expect(!short);
        }
        try testing.expectEqual(2 * case[1], labelled);
    }
}

test "a floating net and a split label are located on their shapes" {
    // Oracle: construct-from-answer, F70. Three rectangles apart: the first
    // unlabelled on no device, a floating net at (600, 0); the other two
    // both VDD, an open at (200, 0) naming both. The split label is an
    // error, a warning when the deck's must-connect names it.
    var d: Drawn = .{};
    defer d.deinit();
    const polys = try draw(&d, 1, &.{ .{ metal, 600, 0, 700, 100 }, .{ metal, 200, 0, 300, 100 }, .{ metal, 400, 0, 500, 100 } }, null);
    const lone = polys[0];
    const left = polys[1];
    const right = polys[2];
    const vdd = try d.strings.intern(gpa, "VDD");
    try bindAndProject(&d, &.{ .{ .poly = left, .name = vdd }, .{ .poly = right, .name = vdd } });
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try lvs.checkLayout(gpa, &d.graph, d.design(), &d.ports, &d.strings, &.{}, &out, &runs);
    for ([_]struct { []const u8, PolyId, PolyId, i64, u32, u32 }{
        .{ "lvs.floating_net", lone, report.no_shape, 600, 0, 1 },
        .{ "lvs.label_conflict", left, right, 200, 2, 1 },
    }) |case| {
        var buf: [8]Violation = undefined;
        const found = rowsOf(&out, d.strings.get(case[0]).?, &buf);
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqual(case[1], found[0].shape_a);
        try testing.expectEqual(case[2], found[0].shape_b);
        try expectAt(found[0], case[3], 0, metal);
        try expectCounts(found[0], case[4], case[5]);
    }
    const gnd = try d.strings.intern(gpa, "GND");
    const conflict = d.strings.get("lvs.label_conflict").?;
    for ([_]struct { LvsControls, report.Severity }{
        .{ .{}, .@"error" },
        .{ .{ .connect_implicit = &.{"VD*"} }, .warning },
        .{ .{ .connect_implicit = &.{"VSS*"} }, .@"error" },
        .{ .{ .connect_explicit = &.{&.{ gnd, vdd }} }, .warning },
        .{ .{ .connect_explicit = &.{&.{gnd}} }, .@"error" },
    }) |case| {
        var o: Violations = .{};
        defer o.deinit(gpa);
        var rs: std.ArrayList(RuleRun) = .empty;
        defer rs.deinit(gpa);
        try lvs.checkLayout(gpa, &d.graph, d.design(), &d.ports, &d.strings, &case[0], &o, &rs);
        var buf: [8]Violation = undefined;
        const found = rowsOf(&o, conflict, &buf);
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqual(case[1], found[0].severity);
    }
}

test "the substrate alone is not a floating net" {
    // Oracle: construct-from-answer, checkLayout's doc: a net of only
    // global-layer shapes does not float, a bare conductor does.
    var d: Drawn = .{};
    defer d.deinit();
    const polys = try draw(&d, 2, &.{ .{ metal, 0, 0, 100, 100 }, .{ 1, 500, 0, 600, 100 } }, 1);
    const wire = polys[0];
    const body = polys[1];
    try testing.expect(!d.nets.isGlobalOnly(d.nets.netOf(wire)));
    try testing.expect(d.nets.isGlobalOnly(d.nets.netOf(body)));
    try bindAndProject(&d, &.{});
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try lvs.checkLayout(gpa, &d.graph, d.design(), &d.ports, &d.strings, &.{}, &out, &runs);
    var buf: [8]Violation = undefined;
    const found = rowsOf(&out, d.strings.get("lvs.floating_net").?, &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(wire, found[0].shape_a);
    try testing.expectEqual(report.no_shape, found[0].shape_b);
}

test "a refused marker is one terminal net row on the marker" {
    // Oracle: construct-from-answer, F32. A marker recognition refused with
    // 2 of 3 terminals bound never reaches the graph: one row on the marker
    // at (200, 0), measured 2 against 3; the refused marker is examined.
    var d: Drawn = .{};
    defer d.deinit();
    const polys = try draw(&d, 1, &.{.{ metal, 200, 0, 250, 200 }}, null);
    const marker = polys[0];
    try d.devices.refused_marker.append(gpa, marker);
    try d.devices.refused_bound.append(gpa, 2);
    try d.devices.refused_listed.append(gpa, 3);
    const nets: NetTable = .{};
    const empty: Graph = .{};
    const ports: PortTable = .{};
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try lvs.checkLayout(gpa, &empty, .{ .store = &d.store, .nets = &nets, .devices = &d.devices }, &ports, &d.strings, &.{}, &out, &runs);
    const rule = d.strings.get("lvs.terminal_net").?;
    const run = for (runs.items) |r| (if (r.rule == rule) break r) else return error.TestNoRow;
    try testing.expect(run.outcome == .ran);
    try testing.expectEqual(@as(u64, 1), run.examined);
    try testing.expectEqual(@as(u32, 1), run.violations);
    const row = out.get(0);
    try testing.expectEqual(rule, row.rule);
    try testing.expectEqual(marker, row.shape_a);
    try testing.expectEqual(report.no_shape, row.shape_b);
    try expectAt(row, 200, 0, metal);
    try expectCounts(row, 2, 3);
}

test "an instance is named when every device it placed is unpaired" {
    // Oracle: the definition (unpairedInstancesInto's doc), by hand. X0 over
    // rows 1..3, X1 over 3..5 with X1.X2 inside over 4..5, X3 over 5..6
    // (its row left out). Reduced device 1 stands for rows 1 and 2. Rows 3,
    // 4 unpaired name X1 alone (2); row 4 alone names X1.X2; device 1 names
    // X0 with both rows; row 0 names nothing; nor does a layout device.
    const P = ingest.netlist.Placement;
    const placements = [_]P{
        .{ .path = id(0), .cell = id(0), .devices = .{ 1, 3 } },
        .{ .path = id(0), .cell = id(0), .devices = .{ 3, 5 } },
        .{ .path = id(0), .cell = id(0), .devices = .{ 4, 5 } },
        .{ .path = id(0), .cell = id(0), .devices = .{ 5, 6 } },
    };
    const row_start = [_]u32{ 0, 1, 3, 4, 5 };
    const rows = [_]u32{ 0, 1, 2, 3, 4 };
    const Case = struct { []const u32, []const lvs.UnpairedInstance };
    for ([_]Case{
        .{ &.{ 2, 3 }, &.{.{ .placement = 1, .devices = 2 }} },
        .{ &.{3}, &.{.{ .placement = 2, .devices = 1 }} },
        .{ &.{1}, &.{.{ .placement = 0, .devices = 2 }} },
        .{ &.{0}, &.{} },
    }) |case| {
        var found: std.ArrayList(lvs.Discrepancy) = .empty;
        defer found.deinit(gpa);
        for (case[0]) |device| try found.append(gpa, .{ .unpaired_device = .{ .side = .reference, .device = device, .model = id(0) } });
        var out: std.ArrayList(lvs.UnpairedInstance) = .empty;
        defer out.deinit(gpa);
        try lvs.unpairedInstancesInto(gpa, found.items, &row_start, &rows, &placements, &out);
        try testing.expectEqualSlices(lvs.UnpairedInstance, case[1], out.items);
    }
    var out: std.ArrayList(lvs.UnpairedInstance) = .empty;
    defer out.deinit(gpa);
    try lvs.unpairedInstancesInto(gpa, &.{.{ .unpaired_device = .{ .side = .layout, .device = 3, .model = id(0) } }}, &row_start, &rows, &placements, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
