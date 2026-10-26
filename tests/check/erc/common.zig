//! Builders the ERC suites share. Nothing here states an answer: the
//! oracles live in the tests and in testgen; this file assembles the input
//! tables a test cannot reach through a constructor (`PowerGrid`,
//! `NetNetworks`, `IntentMap`, the rule tables) and reads run rows back.
//! Ported from crates/check/tests/erc/common/mod.rs.
//!
//! Contents:
//! - `pub const gpa`, `pub fn rule(id: u32) StrId`, `pub fn head(id: StrId) !RuleHead`
//! - `pub fn manufacturingGrid() Grid`, `pub const operating_temperature: Kelvin`
//! - `pub const Sink = struct`, `deinit`, `record(s) Record`
//! - `pub fn runOf(runs: []const RuleRun, id: StrId) !RuleRun`, `pub fn assertSkippedForIntent(runs: []const RuleRun, v: *const Violations, id: StrId) !void`,
//!   `pub fn assertAtIsOnANamedShape(store: *const GeometryStore, v: *const Violations, row: u32) !void`
//! - `pub const GridBuilder = struct`, `node`, `pad`, `edge`, `edgeOn`
//! - `pub fn seriesChain(resistors: u32, ohm: f64, nominal_mv: f64, load_ua: f64) !PowerGrid`, `parallelBundle`, `randomGrid`
//! - `pub fn solve(grid: *const PowerGrid) !PowerSolution`
//! - `pub fn oneRowNetwork(nodes: u32, terminals: []const u32, edges: []const [3]f64) !NetNetworks`
//! - `pub fn probeOf(probes: []const Probe, a: u32, b: u32) !f64`
//! - `pub fn declaredSupplies(power_net: NetId, ground_net: NetId, nominal_mv: f64) !IntentMap`, `pub fn limitNet(m: *IntentMap, net: NetId, limits: NetLimits) !void`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const StrId = geom.StrId;
const Grid = geom.Grid;
const GeometryStore = geom.GeometryStore;
const report = check.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const NetId = check.topology.NetId;
const erc = check.erc;
const RuleHead = erc.head.RuleHead;
const Record = erc.head.Record;
const IntentMap = erc.facts.IntentMap;
const PowerGrid = erc.power_grid.PowerGrid;
const PowerSolution = erc.power_grid.PowerSolution;
const NetNetworks = erc.power_grid.NetNetworks;
const Probe = erc.power_probe.Probe;
const Kelvin = erc.electrical_tables.Kelvin;
const NetLimits = ingest.intent.NetLimits;

pub const gpa = testing.allocator;

/// 85 °C, absolute: the operating point every derating is computed at.
pub const operating_temperature: Kelvin = .{ .raw = 358.15 };

/// Where a test's rules record.
pub const Sink = struct {
    out: Violations = .{},
    runs: std.ArrayList(RuleRun) = .empty,

    pub fn deinit(s: *Sink) void {
        s.out.deinit(gpa);
        s.runs.deinit(gpa);
    }

    pub fn record(s: *Sink) Record {
        return .{ .gpa = gpa, .out = &s.out, .runs = &s.runs };
    }
};

/// Accumulates nodes and edges into a `PowerGrid`, columns in step.
pub const GridBuilder = struct {
    grid: PowerGrid = .{},

    /// One node at `x` on the y axis, at `nominal_mv`, drawing `load_ua`.
    pub fn node(b: *GridBuilder, x: i64, nominal_mv: f64, load_ua: f64) !u32 {
        const index = b.grid.nodeCount();
        try b.grid.pushNode(gpa, .{ .net = @fromBackingInt(0), .at = .{ .x = x, .y = 0 }, .poly = @fromBackingInt(index), .layer = @fromBackingInt(0), .nominal = .{ .raw = nominal_mv }, .load = .{ .raw = load_ua } });
        return index;
    }

    /// Holds a node at a fixed voltage; pads go in ascending.
    pub fn pad(b: *GridBuilder, node_index: u32, millivolt: f64) !void {
        try b.grid.source_node.append(gpa, node_index);
        try b.grid.source_voltage.append(gpa, .{ .raw = millivolt });
    }

    /// A metal edge of `ohm` ohms, one micrometre wide and long, layer 0.
    pub fn edge(b: *GridBuilder, from: u32, to: u32, ohm: f64) !void {
        try b.edgeOn(@fromBackingInt(0), from, to, ohm);
    }

    pub fn edgeOn(b: *GridBuilder, layer: geom.LayerId, from: u32, to: u32, ohm: f64) !void {
        try b.grid.pushEdge(gpa, .{ .from = from, .to = to, .ohms = ohm, .width = 1_000, .length = 1_000, .layer = layer, .kind = .metal });
    }
};

/// A rule id; tests never need the text.
pub fn rule(id: u32) StrId {
    return @fromBackingInt(id);
}

/// A one-row head at `.error` severity. The caller deinits it.
pub fn head(id: StrId) !RuleHead {
    var h: RuleHead = .{};
    try h.push(gpa, id, .@"error");
    return h;
}

/// The 1 nm manufacturing grid conductor widths are stated against.
pub fn manufacturingGrid() Grid {
    return Grid.init(1_000) catch unreachable;
}

/// The run row a rule recorded, whatever its outcome; fails unless exactly
/// one.
pub fn runOf(runs: []const RuleRun, id: StrId) !RuleRun {
    var found: ?RuleRun = null;
    for (runs) |r| if (r.rule == id) {
        if (found != null) return error.TwoRunRows;
        found = r;
    };
    return found orelse error.NoRunRow;
}

/// The rule recorded itself skipped for want of design intent, examined
/// nothing and pushed nothing.
pub fn assertSkippedForIntent(runs: []const RuleRun, v: *const Violations, id: StrId) !void {
    const r = try runOf(runs, id);
    try testing.expectEqual(report.Outcome{ .skipped = .no_design_intent }, r.outcome);
    try testing.expectEqual(@as(u64, 0), r.examined);
    try testing.expectEqual(@as(u32, 0), r.violations);
    try testing.expect(std.mem.indexOfScalar(StrId, v.rule.items, id) == null);
}

/// Violation `row`'s marker lies on a shape it names.
pub fn assertAtIsOnANamedShape(store: *const GeometryStore, v: *const Violations, row: u32) !void {
    const at = v.at.items[row];
    const here = geom.Bbox.point(at.x, at.y);
    const a = store.polyBbox(v.shape_a.items[row]).contains(here);
    const b_shape = v.shape_b.items[row];
    const b = b_shape != report.no_shape and store.polyBbox(b_shape).contains(here);
    try testing.expect(a or b);
}

/// A pad at node 0 and `resistors` equal resistors in series, the whole
/// load at the far end: Ohm's law over a chain is the oracle.
pub fn seriesChain(resistors: u32, ohm: f64, nominal_mv: f64, load_ua: f64) !PowerGrid {
    var b: GridBuilder = .{};
    errdefer b.grid.deinit(gpa);
    for (0..resistors + 1) |n| _ = try b.node(@as(i64, @intCast(n)) * 1_000, nominal_mv, if (n == resistors) load_ua else 0.0);
    try b.pad(0, nominal_mv);
    for (0..resistors) |n| try b.edge(@intCast(n), @intCast(n + 1), ohm);
    return b.grid;
}

/// A pad and a load joined by `strands` equal resistors in parallel:
/// conductances add, so the closed form is `ohm / strands`.
pub fn parallelBundle(strands: u32, ohm: f64, nominal_mv: f64, load_ua: f64) !PowerGrid {
    std.debug.assert(strands > 0);
    var b: GridBuilder = .{};
    errdefer b.grid.deinit(gpa);
    _ = try b.node(0, nominal_mv, 0.0);
    _ = try b.node(1_000, nominal_mv, load_ua);
    try b.pad(0, nominal_mv);
    for (0..strands) |_| try b.edge(0, 1, ohm);
    return b.grid;
}

/// A connected grid of arbitrary shape: a spanning path, `chords` extra
/// edges, one pad, a load at every other node. Kirchhoff's laws and
/// linearity hold on any such grid.
pub fn randomGrid(seed: u64, nodes: u32, chords: u32) !PowerGrid {
    std.debug.assert(nodes >= 2);
    var rng = testgen.Rng.init(seed);
    var b: GridBuilder = .{};
    errdefer b.grid.deinit(gpa);
    _ = try b.node(0, 1_800.0, 0.0);
    for (1..nodes) |n| _ = try b.node(@as(i64, @intCast(n)) * 1_000, 1_800.0, @floatFromInt(rng.below(500) + 1));
    try b.pad(0, 1_800.0);
    // The path first, so every node reaches the pad and no island forms.
    for (0..nodes - 1) |n| try b.edge(@intCast(n), @intCast(n + 1), 0.5 + 4.0 * rng.unit());
    for (0..chords) |_| {
        const from: u32 = @intCast(rng.below(nodes));
        const to: u32 = @intCast(rng.below(nodes));
        if (from != to) try b.edge(from, to, 0.5 + 4.0 * rng.unit());
    }
    return b.grid;
}

/// The grid solved at the default tolerance; fails when the solve does.
pub fn solve(grid: *const PowerGrid) !PowerSolution {
    var scratch: erc.power_solve.SolveScratch = .{};
    defer scratch.deinit(gpa);
    var solution: PowerSolution = .{};
    errdefer solution.deinit(gpa);
    var diag: erc.power_grid.PowerDiag = .{};
    try erc.power_solve.solveInto(gpa, grid, &scratch, &solution, &diag);
    return solution;
}

/// One net's network as one row: nodes along a line at unit pitch, node
/// `n` tapping polygon `n`; `edges` are `(from, to, ohms)`.
pub fn oneRowNetwork(nodes: u32, terminals: []const u32, edges: []const [3]f64) !NetNetworks {
    var n: NetNetworks = .{};
    errdefer n.deinit(gpa);
    try n.net.append(gpa, @fromBackingInt(0));
    try n.node_start.appendSlice(gpa, &.{ 0, nodes });
    for (0..nodes) |k| {
        try n.node_at.append(gpa, .{ .x = @as(i64, @intCast(k)) * 1_000, .y = 0 });
        try n.node_poly.append(gpa, @fromBackingInt(@as(u32, @intCast(k))));
    }
    try n.terminal_start.appendSlice(gpa, &.{ 0, @intCast(terminals.len) });
    try n.terminal.appendSlice(gpa, terminals);
    try n.edge_start.appendSlice(gpa, &.{ 0, @intCast(edges.len) });
    for (edges) |e| {
        try n.edge_from.append(gpa, @intFromFloat(e[0]));
        try n.edge_to.append(gpa, @intFromFloat(e[1]));
        try n.edge_resistance.append(gpa, .{ .raw = e[2] });
    }
    return n;
}

/// A probe's resistance by terminal pair, either order; fails when absent.
pub fn probeOf(probes: []const Probe, a: u32, b: u32) !f64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    for (probes) |p| if (p.a == lo and p.b == hi) return p.ohms.raw;
    return error.NoProbe;
}

/// An intent map declaring one power and one ground net in domain 0.
pub fn declaredSupplies(power_net: NetId, ground_net: NetId, nominal_mv: f64) !IntentMap {
    var m: IntentMap = .{ .declared = true };
    errdefer m.deinit(gpa);
    const first, const second = if (@backingInt(power_net) <= @backingInt(ground_net)) .{ power_net, ground_net } else .{ ground_net, power_net };
    for ([2]NetId{ first, second }) |net| {
        const power = net == power_net;
        try m.supply_net.append(gpa, net);
        try m.supply_role.append(gpa, if (power) .power else .ground);
        try m.supply_domain.append(gpa, @fromBackingInt(0));
        try m.supply_voltage.append(gpa, .{ .raw = if (power) nominal_mv else 0.0 });
    }
    return m;
}

/// Declares limits on a net, keeping `limit_net` ascending.
pub fn limitNet(m: *IntentMap, net: NetId, limits: NetLimits) !void {
    var at: usize = 0;
    while (at < m.limit_net.items.len and @backingInt(m.limit_net.items[at]) < @backingInt(net)) at += 1;
    try m.limit_net.insert(gpa, at, net);
    try m.limit.insert(gpa, at, limits);
}
