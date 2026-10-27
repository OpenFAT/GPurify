//! The resistive networks ERC extracts from layout and solves, as tables:
//! the supply grid (`PowerGrid`), its solution (`PowerSolution`), the
//! per-net networks (`NetNetworks`, CSR by net row), what one run's rules
//! read of the solve (`Power`), and a simulator's terminal currents placed
//! on layout devices (`TerminalCurrents`). In: nothing (types only; the builders
//! are power_extract.zig and power_nets.zig, the solvers power_solve.zig,
//! power_transient.zig and power_probe.zig). Ported from
//! crates/check/src/erc/power.rs (`PowerError`, `Process`, `EdgeKind`,
//! `PowerGrid`, `NetNetworks`, `PowerSolution`, `Solved`, `Power`).
//!
//! Units: mV, µA, Ω; a conductance is `1000 / R` µA per mV.
//!
//! Contents:
//! - `pub const PowerError`, `pub const PowerDiag = struct { at: u32 }`
//! - `pub const Process = struct { grid: Grid, stack: *const ProcessStack, connectivity: *const Connectivity }`
//! - `pub const EdgeKind = enum(u8) { metal, via, device }`
//! - `pub const PowerGrid = struct`, `deinit`, `nodeCount(g) u32`, `edgeCount(g) u32`, `isEmpty(g) bool`, `clear(g)`,
//!   `pushNode(g, gpa: Allocator, node: Node) Allocator.Error!void`, `pushEdge(g, gpa: Allocator, edge: Edge) Allocator.Error!void`,
//!   `pub const Node`, `pub const Edge`
//! - `pub const NetNetworks = struct`, `deinit`, `len(n) u32`, `clear(n)`, `nodesOf(n, row: u32) []const PolyId`,
//!   `atOf(n, row) []const Point`, `terminalsOf(n, row) []const u32`, `edgesOf(n, row) Edges`, `pub const Edges`
//! - `pub const PowerSolution = struct`, `deinit`, `isConsistentWith(s, g: *const PowerGrid) bool`
//! - `pub const Solved = struct { grid: *const PowerGrid, solution: *const PowerSolution }`
//! - `pub const Power = union(enum) { no_supply, solved: Solved, failed: PowerError }`
//! - `pub const TerminalCurrents = struct`, `len(c) u32`, `pub const Loads = struct`, `loads(c, pick: Pick) Loads`, `pub const Pick`
//! - `pub const ua_per_mv_ohm: f64`, `pub const not_a_node: u32`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ingest_deck = @import("ingest").deck;
const ProcessStack = ingest_deck.ProcessStack;
const Connectivity = ingest_deck.Connectivity;
const report = @import("../report.zig");
const Millivolts = report.Millivolts;
const Microamps = report.Microamps;
const Ohms = report.Ohms;
const NetId = @import("../topology/net.zig").NetId;
const DeviceId = @import("../topology/device.zig").DeviceId;
const Load = report.Load;

/// Microamps per millivolt per ohm: the grid is mV, µA and Ω, so a
/// conductance is `1000 / R`. Wrong here scales every drop and still passes
/// the law tests.
pub const ua_per_mv_ohm: f64 = 1_000.0;

/// End of a list, "not a terminal", "no shape".
pub const not_a_node: u32 = std.math.maxInt(u32);

/// Why a network could not be built or solved; every member fails closed.
/// The node, edge, layer or point is in `PowerDiag.at`.
pub const PowerError = error{
    /// A grid with nodes but no pad (only a grid built by hand).
    Unanchored,
    /// Node `at` is in a piece no pad reaches (a supply shape joined only
    /// through a global layer, which carries no modelled current).
    UnanchoredIsland,
    /// Edge `at` (within its row, for a per-net network) has a zero,
    /// negative or non-finite resistance.
    BadResistance,
    /// Layer `at` carries current but the deck's `pex` rows give it no
    /// positive finite sheet resistance: unknown, never zero.
    NoSheetResistance,
    /// CG did not reach `1e-10` of its starting residual in `at` iterations.
    NotConverged,
    /// Node `at` carries a NaN or infinite value.
    NotFinite,
    /// Point `at` lies on no conducting shape of its net.
    NotOnNet,
};

/// What a `PowerError` names.
pub const PowerDiag = struct { at: u32 = 0 };

/// The process data an extraction reads.
pub const Process = struct {
    /// Database units to metres.
    grid: Grid,
    /// Sheet resistance per layer (Ω/sq; Ω per cut on a cut layer) and the
    /// heights that pick each supply's feed point and set a via's length.
    stack: *const ProcessStack,
    /// Which layers conduct, which cuts join them, which are global.
    connectivity: *const Connectivity,
};

/// What an edge models: metal (limited per width), one via cut (per cut),
/// or a device conducting between two nets (an ESD clamp in a stress
/// network, rated by its own size). The supply grid has no device edge.
pub const EdgeKind = enum(u8) { metal, via, device };

/// The supply grid, SoA. Invariant: every node column has `nodeCount()`
/// rows, every edge column `edgeCount()`; `source_node` ascends and pairs
/// with `source_voltage`; the `term_*` columns are parallel. Nodes are taps
/// on the declared supplies' conducting shapes (and, loaded with simulated
/// currents, on every net those reach); edges are resistors between them.
pub const PowerGrid = struct {
    node_net: std.ArrayList(NetId) = .empty,
    /// Where a violation at this node is reported.
    node_at: std.ArrayList(Point) = .empty,
    node_poly: std.ArrayList(PolyId) = .empty,
    node_layer: std.ArrayList(LayerId) = .empty,
    /// The domain nominal every drop is measured from.
    node_nominal: std.ArrayList(Millivolts) = .empty,
    /// Current drawn here; negative injects (a ground rail's load).
    node_load: std.ArrayList(Microamps) = .empty,
    /// Pad nodes held at a fixed voltage, ascending.
    source_node: std.ArrayList(u32) = .empty,
    source_voltage: std.ArrayList(Millivolts) = .empty,
    /// A branch current is positive from `edge_from` toward `edge_to`.
    edge_from: std.ArrayList(u32) = .empty,
    edge_to: std.ArrayList(u32) = .empty,
    edge_resistance: std.ArrayList(Ohms) = .empty,
    /// Conductor width: the current-density denominator.
    edge_width: std.ArrayList(Dbu) = .empty,
    /// The run between the nodes, at least 1 (the Blech `L`); for a via, the
    /// stack height between its conductors.
    edge_length: std.ArrayList(Dbu) = .empty,
    /// The conductor's layer, or the cut layer for a via.
    edge_layer: std.ArrayList(LayerId) = .empty,
    edge_kind: std.ArrayList(EdgeKind) = .empty,
    /// One row per simulated terminal load (empty on a budget grid): its
    /// node, its share of that node's load, and whose it is, for reports.
    term_node: std.ArrayList(u32) = .empty,
    term_load: std.ArrayList(Microamps) = .empty,
    term_name: std.ArrayList(Load) = .empty,

    /// One node's row.
    pub const Node = struct { net: NetId, at: Point, poly: PolyId, layer: LayerId, nominal: Millivolts, load: Microamps };

    /// One resistor's row.
    pub const Edge = struct { from: u32, to: u32, ohms: f64, width: Dbu, length: Dbu, layer: LayerId, kind: EdgeKind };

    pub fn deinit(g: *PowerGrid, gpa: Allocator) void {
        inline for (@typeInfo(PowerGrid).@"struct".field_names) |f| @field(g, f).deinit(gpa);
    }

    pub fn clear(g: *PowerGrid) void {
        inline for (@typeInfo(PowerGrid).@"struct".field_names) |f| @field(g, f).clearRetainingCapacity();
    }

    pub fn nodeCount(g: *const PowerGrid) u32 {
        return @intCast(g.node_net.items.len);
    }

    pub fn edgeCount(g: *const PowerGrid) u32 {
        return @intCast(g.edge_from.items.len);
    }

    /// No declared supply has a conducting shape: nothing to solve.
    pub fn isEmpty(g: *const PowerGrid) bool {
        return g.nodeCount() == 0;
    }

    pub fn pushNode(g: *PowerGrid, gpa: Allocator, n: Node) Allocator.Error!void {
        std.debug.assert(g.node_net.items.len < not_a_node);
        try g.node_net.append(gpa, n.net);
        try g.node_at.append(gpa, n.at);
        try g.node_poly.append(gpa, n.poly);
        try g.node_layer.append(gpa, n.layer);
        try g.node_nominal.append(gpa, n.nominal);
        try g.node_load.append(gpa, n.load);
    }

    pub fn pushEdge(g: *PowerGrid, gpa: Allocator, e: Edge) Allocator.Error!void {
        try g.edge_from.append(gpa, e.from);
        try g.edge_to.append(gpa, e.to);
        try g.edge_resistance.append(gpa, .{ .raw = e.ohms });
        try g.edge_width.append(gpa, e.width);
        try g.edge_length.append(gpa, e.length);
        try g.edge_layer.append(gpa, e.layer);
        try g.edge_kind.append(gpa, e.kind);
    }
};

/// One resistor network per net with at least two terminals, CSR by row.
/// Row `r` is net `net[r]` (ascending); its nodes, terminals and edges are
/// the runs of the `*_start` columns, each `len() + 1` long once a row
/// exists and empty before. Node indices in `terminal` and `edge_*` are
/// local to the row.
pub const NetNetworks = struct {
    net: std.ArrayList(NetId) = .empty,
    node_start: std.ArrayList(u32) = .empty,
    /// Each node on its shape's centre line, at the tap.
    node_at: std.ArrayList(Point) = .empty,
    node_poly: std.ArrayList(PolyId) = .empty,
    terminal_start: std.ArrayList(u32) = .empty,
    /// Attach-point nodes, row-local, ascending, at least two per row.
    terminal: std.ArrayList(u32) = .empty,
    edge_start: std.ArrayList(u32) = .empty,
    edge_from: std.ArrayList(u32) = .empty,
    edge_to: std.ArrayList(u32) = .empty,
    edge_resistance: std.ArrayList(Ohms) = .empty,

    /// One row's edges.
    pub const Edges = struct { from: []const u32, to: []const u32, resistance: []const Ohms };

    pub fn deinit(n: *NetNetworks, gpa: Allocator) void {
        inline for (@typeInfo(NetNetworks).@"struct".field_names) |f| @field(n, f).deinit(gpa);
    }

    pub fn clear(n: *NetNetworks) void {
        inline for (@typeInfo(NetNetworks).@"struct".field_names) |f| @field(n, f).clearRetainingCapacity();
    }

    /// Nets with at least two attach points.
    pub fn len(n: *const NetNetworks) u32 {
        return @intCast(n.net.items.len);
    }

    /// One row's nodes' tapped polygons.
    pub fn nodesOf(n: *const NetNetworks, row: u32) []const PolyId {
        return n.node_poly.items[n.node_start.items[row]..n.node_start.items[row + 1]];
    }

    /// One row's nodes' positions.
    pub fn atOf(n: *const NetNetworks, row: u32) []const Point {
        return n.node_at.items[n.node_start.items[row]..n.node_start.items[row + 1]];
    }

    /// One row's terminal nodes, ascending.
    pub fn terminalsOf(n: *const NetNetworks, row: u32) []const u32 {
        return n.terminal.items[n.terminal_start.items[row]..n.terminal_start.items[row + 1]];
    }

    pub fn edgesOf(n: *const NetNetworks, row: u32) Edges {
        const from = n.edge_start.items[row];
        const to = n.edge_start.items[row + 1];
        return .{ .from = n.edge_from.items[from..to], .to = n.edge_to.items[from..to], .resistance = n.edge_resistance.items[from..to] };
    }
};

/// A solved `PowerGrid`: row `i` is node `i` (voltages) or edge `i`.
pub const PowerSolution = struct {
    /// mV; a pad sits exactly at its fixed voltage.
    node_voltage: std.ArrayList(Millivolts) = .empty,
    /// Nominal minus solved: positive is a loss.
    node_drop: std.ArrayList(Millivolts) = .empty,
    /// Positive from `edge_from` toward `edge_to`.
    branch_current: std.ArrayList(Microamps) = .empty,

    pub fn deinit(s: *PowerSolution, gpa: Allocator) void {
        s.node_voltage.deinit(gpa);
        s.node_drop.deinit(gpa);
        s.branch_current.deinit(gpa);
    }

    /// Every value finite and the columns the grid's lengths.
    pub fn isConsistentWith(s: *const PowerSolution, g: *const PowerGrid) bool {
        if (s.node_voltage.items.len != g.nodeCount() or s.node_drop.items.len != g.nodeCount() or s.branch_current.items.len != g.edgeCount()) return false;
        for (s.node_voltage.items, s.node_drop.items) |v, d| if (!v.isFinite() or !d.isFinite()) return false;
        for (s.branch_current.items) |c| if (!c.isFinite()) return false;
        return true;
    }
};

/// A grid and its solution, together.
pub const Solved = struct { grid: *const PowerGrid, solution: *const PowerSolution };

/// What the grid rules read: no declared supply, the solve, or why it
/// failed (those rows refuse; every other rule still runs).
pub const Power = union(enum) {
    no_supply,
    solved: Solved,
    failed: PowerError,
};

/// A simulator's per-terminal currents placed on layout devices (catalog
/// ERC-E14): one row per device terminal that carries current, ascending by
/// net, then device. Units µA, positive drawn from the net (into the
/// device). `em`, `rms` and `peak` are magnitudes signed as `avg` (zero
/// reads as drawn), so a net's loads add in phase. Every net carries
/// current on a conductor, and either has a port (a supply or a label) or
/// its `avg` loads balance.
pub const TerminalCurrents = struct {
    net: []const NetId = &.{},
    device: []const DeviceId = &.{},
    avg: []const f64 = &.{},
    em: []const f64 = &.{},
    rms: []const f64 = &.{},
    peak: []const f64 = &.{},
    /// The simulator's instance and terminal each row came from.
    name: []const Load = &.{},

    pub fn len(c: *const TerminalCurrents) u32 {
        return @intCast(c.net.len);
    }

    /// One quantity's loads, for one grid.
    pub fn loads(c: *const TerminalCurrents, pick: Pick) Loads {
        const value = switch (pick) {
            .avg => c.avg,
            .em => c.em,
            .rms => c.rms,
            .peak => c.peak,
        };
        return .{ .net = c.net, .device = c.device, .value = value, .name = c.name };
    }
};

/// Which current a grid carries: the average (IR drop), the
/// electromigration average (the DC EM rules), the RMS or the peak.
pub const Pick = enum { avg, em, rms, peak };

/// The loads one grid carries in place of the intent's budgets, rows as
/// `TerminalCurrents`'; empty for a budget grid.
pub const Loads = struct {
    net: []const NetId = &.{},
    device: []const DeviceId = &.{},
    value: []const f64 = &.{},
    name: []const Load = &.{},
};
