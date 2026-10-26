//! The branch-current checks behind `em_current_density`,
//! `electromigration` and `em_rms`/`em_peak`: each grid edge on a limited
//! layer held to its allowed current (times a derating), Blech-immortal
//! lines exempt, and the AC tables interpolated at a wire's width and its
//! net's frequency. In: a solved supply grid, a row's per-layer limits.
//! Out: violations and each row's run. Ported from
//! crates/check/src/erc/rules/electrical.rs (`LayerLimits`,
//! `blech_products`, `check_branches`, `check_current_rows`,
//! `arrhenius_derating`, `interpolate`, `table_density`, `check_em_ac`,
//! `edge_violation`).
//!
//! Contents:
//! - `pub const LayerLimits = struct`, `pub const Head = struct { rule: StrId, severity: Severity }`
//! - `pub fn blechProductsInto(gpa: Allocator, power: *const PowerGrid, solution: *const PowerSolution, out: *std.ArrayList(f64)) Allocator.Error!void`
//! - `pub fn currentRows(r: Record, solved: Solved, grid: Grid, head: *const RuleHead, layer_start: []const u32, all: LayerLimits, derate: anytype) Allocator.Error!void`
//! - `pub fn emAcRows(r: Record, solved: Solved, intent: *const IntentMap, grid: Grid, t: *const EmAcTable) Allocator.Error!void`
//! - `pub fn arrheniusDerating(operating: Kelvin, reference: Kelvin, activation_energy_ev: f64, current_exponent: f64) ?f64`
//! - `pub fn interpolate(points: []const f64, values: []const f64, at: f64) f64`
//! - `pub fn tableDensity(gpa: Allocator, frequencies: []const f64, widths: []const f64, density: []const f64, f: f64, w: f64, by_frequency: *std.ArrayList(f64)) Allocator.Error!f64`
//! - `pub fn edgeViolation(r: Record, power: *const PowerGrid, edge: u32, head: Head, measured: Measurement, limit: Measurement) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const Severity = report.Severity;
const Microamps = report.Microamps;
const head_ = @import("head.zig");
const Record = head_.Record;
const RuleHead = head_.RuleHead;
const IntentMap = @import("facts.zig").IntentMap;
const grid_ = @import("power_grid.zig");
const PowerGrid = grid_.PowerGrid;
const PowerSolution = grid_.PowerSolution;
const Solved = grid_.Solved;
const electrical = @import("electrical_tables.zig");
const CurrentDensity = electrical.CurrentDensity;
const Kelvin = electrical.Kelvin;
const Narrow = electrical.Narrow;
const EmAcTable = electrical.EmAcTable;
const allowedCurrent = @import("em_allowed.zig").allowedCurrent;

/// One row's per-layer current limits; `blech` and `narrow` empty when the
/// kind states none.
pub const LayerLimits = struct {
    layer: []const LayerId,
    max_density: []const CurrentDensity,
    max_current_per_cut: []const Microamps,
    blech: []const Microamps = &.{},
    narrow: []const ?Narrow = &.{},
};

/// A row's id and severity.
pub const Head = struct { rule: StrId, severity: Severity };

/// Each edge's Blech product `|I| * L / W`, `L` the length of the line the
/// edge lies in: the metal between diffusion barriers (a via landing, a
/// pad, a loaded tap). A line's product is its largest edge's; a branched
/// line's `L` is every branch, which errs mortal. A via is its own line, `L`
/// the stack height. A zero width is infinite (mortal).
pub fn blechProductsInto(gpa: Allocator, power: *const PowerGrid, solution: *const PowerSolution, out: *std.ArrayList(f64)) Allocator.Error!void {
    const nodes = power.nodeCount();
    const edges = power.edgeCount();
    const kind = power.edge_kind.items;
    const barrier = try gpa.alloc(bool, nodes);
    defer gpa.free(barrier);
    @memset(barrier, false);
    for (power.source_node.items) |pad| barrier[pad] = true;
    for (barrier, power.node_load.items) |*b, load| b.* = b.* or load.raw != 0.0;
    for (0..edges) |e| if (kind[e] != .metal) {
        barrier[power.edge_from.items[e]] = true;
        barrier[power.edge_to.items[e]] = true;
    };
    // Metal edges meeting at a node that is no barrier are one line.
    const first = try gpa.alloc(u32, nodes);
    defer gpa.free(first);
    @memset(first, std.math.maxInt(u32));
    var joins: std.ArrayList([2]u32) = .empty;
    defer joins.deinit(gpa);
    for (0..edges) |e| if (kind[e] == .metal) {
        for ([2]u32{ power.edge_from.items[e], power.edge_to.items[e] }) |node| {
            if (barrier[node]) continue;
            if (first[node] == std.math.maxInt(u32)) first[node] = @intCast(e) else try joins.append(gpa, .{ first[node], @intCast(e) });
        }
    };
    var line: std.ArrayList(u32) = .empty;
    defer line.deinit(gpa);
    try geom.connectivity.componentsInto(gpa, edges, joins.items, &line);
    const length = try gpa.alloc(i64, edges);
    defer gpa.free(length);
    @memset(length, 0);
    for (0..edges) |e| if (kind[e] == .metal) {
        length[line.items[e]] += power.edge_length.items[e];
    };
    const worst = try gpa.alloc(f64, edges);
    defer gpa.free(worst);
    @memset(worst, 0.0);
    for (0..edges) |e| if (kind[e] == .metal) {
        const at = line.items[e];
        worst[at] = @max(worst[at], product(power, solution, e, length[at]));
    };
    out.clearRetainingCapacity();
    for (0..edges) |e| try out.append(gpa, if (kind[e] == .metal) worst[line.items[e]] else product(power, solution, e, power.edge_length.items[e]));
}

/// The row loop of both DC current kinds: each row's edges on its layers
/// against their allowed current times `derate.of(row)`; null refuses the
/// row. `derate` has `fn of(self, row: u32) ?f64`.
pub fn currentRows(r: Record, solved: Solved, grid: Grid, head: *const RuleHead, layer_start: []const u32, all: LayerLimits, derate: anytype) Allocator.Error!void {
    // The products depend on the solved grid alone, not on the row.
    var blech: std.ArrayList(f64) = .empty;
    defer blech.deinit(r.gpa);
    if (all.blech.len > 0) try blechProductsInto(r.gpa, solved.grid, solved.solution, &blech);
    for (head.rule.items, head.severity.items, 0..) |id, severity, row| {
        const before = r.out.len();
        const factor = derate.of(@intCast(row)) orelse {
            try r.run(id, before, .refused, 0);
            continue;
        };
        const from = layer_start[row];
        const to = layer_start[row + 1];
        const limits: LayerLimits = .{
            .layer = all.layer[from..to],
            .max_density = all.max_density[from..to],
            .max_current_per_cut = all.max_current_per_cut[from..to],
            .blech = if (all.blech.len == 0) &.{} else all.blech[from..to],
            .narrow = if (all.narrow.len == 0) &.{} else all.narrow[from..to],
        };
        const examined = try branches(r, solved, grid, .{ .rule = id, .severity = severity }, limits, blech.items, factor);
        try r.run(id, before, .ran, examined);
    }
}

/// Every `em_rms` or `em_peak` row over the grid loaded with those currents
/// (`intent` its loads and frequencies). `examined` counts segments and
/// cuts on the row's layers; a row whose table has several frequencies
/// refuses when a net it examines states no `frequency_mhz`.
pub fn emAcRows(r: Record, solved: Solved, intent: *const IntentMap, grid: Grid, t: *const EmAcTable) Allocator.Error!void {
    const net = solved.grid;
    const gpa = r.gpa;
    var widths: std.ArrayList(f64) = .empty;
    defer widths.deinit(gpa);
    var density: std.ArrayList(f64) = .empty;
    defer density.deinit(gpa);
    var by_frequency: std.ArrayList(f64) = .empty;
    defer by_frequency.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const layers = t.layer.items[t.layer_start.items[row]..t.layer_start.items[row + 1]];
        const frequencies = t.frequency.items[t.frequency_start.items[row]..t.frequency_start.items[row + 1]];
        widths.clearRetainingCapacity();
        for (t.width.items[t.width_start.items[row]..t.width_start.items[row + 1]]) |w| try widths.append(gpa, @floatFromInt(w));
        density.clearRetainingCapacity();
        for (t.density.items[t.density_start.items[row]..t.density_start.items[row + 1]]) |d| try density.append(gpa, d.raw);
        var examined: u64 = 0;
        var outcome: report.Outcome = .ran;
        for (0..net.edgeCount()) |e| {
            if (std.mem.indexOfScalar(LayerId, layers, net.edge_layer.items[e]) == null) continue;
            const width = net.edge_width.items[e];
            const allowed: Microamps = switch (net.edge_kind.items[e]) {
                .via => t.max_current_per_cut.items[row],
                .metal => blk: {
                    const frequency = if (frequencies.len == 1) frequencies[0] else intent.limitsOf(net.node_net.items[net.edge_from.items[e]]).frequency_mhz orelse {
                        outcome = .refused;
                        break;
                    };
                    const per_width = try tableDensity(gpa, frequencies, widths.items, density.items, frequency, @floatFromInt(width), &by_frequency);
                    break :blk allowedCurrent(.metal, width, grid, .{ .raw = per_width }, .{ .raw = 0.0 }, null);
                },
                .device => continue,
            };
            examined += 1;
            const measured = Measurement.current(.{ .raw = @abs(solved.solution.branch_current.items[e].raw) });
            const limit = Measurement.current(allowed);
            if (!measured.violates(limit, .maximum)) continue;
            try edgeViolation(r, net, @intCast(e), .{ .rule = rule, .severity = severity }, measured, limit);
        }
        try r.run(rule, before, outcome, examined);
    }
}

/// Black's derating of a limit characterised at `reference` to `operating`,
/// `exp(Ea / (n k) * (1/T - 1/T_ref))`, below one when hotter; null for an
/// unusable parameter set or an infinite factor.
pub fn arrheniusDerating(operating: Kelvin, reference: Kelvin, activation_energy_ev: f64, current_exponent: f64) ?f64 {
    const t = operating.raw;
    const t_ref = reference.raw;
    const usable = std.math.isFinite(t) and t > 0.0 and std.math.isFinite(t_ref) and t_ref > 0.0 and
        std.math.isFinite(activation_energy_ev) and activation_energy_ev >= 0.0 and
        std.math.isFinite(current_exponent) and current_exponent > 0.0;
    if (!usable) return null;
    const s = activation_energy_ev / (current_exponent * electrical.boltzmann_ev_per_k);
    const derate = @exp(s * (1.0 / t - 1.0 / t_ref));
    return if (std.math.isFinite(derate)) derate else null;
}

/// Linear interpolation of `values` over the rising `points` at `at`, held
/// at the end values beyond them.
pub fn interpolate(points: []const f64, values: []const f64, at: f64) f64 {
    var after: usize = 0;
    while (after < points.len and points[after] <= at) after += 1;
    if (after == 0) return values[0];
    const lo = after - 1;
    if (after == points.len) return values[lo];
    const t = (at - points[lo]) / (points[after] - points[lo]);
    return values[lo] + (values[after] - values[lo]) * t;
}

/// A table at `(f, w)`: each frequency row interpolated at the width, then
/// those across the frequency. `by_frequency` is scratch.
pub fn tableDensity(gpa: Allocator, frequencies: []const f64, widths: []const f64, density: []const f64, f: f64, w: f64, by_frequency: *std.ArrayList(f64)) Allocator.Error!f64 {
    by_frequency.clearRetainingCapacity();
    var i: usize = 0;
    while (i < density.len) : (i += widths.len) try by_frequency.append(gpa, interpolate(widths, density[i..][0..widths.len], w));
    return interpolate(frequencies, by_frequency.items, f);
}

/// A finding on one edge: at its first node, on its layer, naming the
/// shapes at both ends.
pub fn edgeViolation(r: Record, power: *const PowerGrid, edge: u32, head: Head, measured: Measurement, limit: Measurement) Allocator.Error!void {
    const from = power.edge_from.items[edge];
    const to = power.edge_to.items[edge];
    try r.out.push(r.gpa, .{
        .rule = head.rule,
        .layer = power.edge_layer.items[edge],
        .severity = head.severity,
        .at = power.node_at.items[from],
        .measured = measured,
        .limit = limit,
        .shape_a = power.node_poly.items[from],
        .shape_b = power.node_poly.items[to],
    });
}

// ---- private ----

fn product(power: *const PowerGrid, solution: *const PowerSolution, edge: usize, length: i64) f64 {
    const width = power.edge_width.items[edge];
    if (width == 0) return std.math.inf(f64);
    return @abs(solution.branch_current.items[edge].raw) * (@as(f64, @floatFromInt(length)) / @as(f64, @floatFromInt(width)));
}

/// Every edge on a limited layer against its allowed current times
/// `derate`; returns the in-scope edges the Blech exemption did not remove.
fn branches(r: Record, solved: Solved, grid: Grid, head: Head, limits: LayerLimits, blech: []const f64, derate: f64) Allocator.Error!u64 {
    const power = solved.grid;
    var examined: u64 = 0;
    for (0..power.edgeCount()) |e| {
        // First mention of a repeated layer wins; other layers are out of scope.
        const at = std.mem.indexOfScalar(LayerId, limits.layer, power.edge_layer.items[e]) orelse continue;
        const current = @abs(solved.solution.branch_current.items[e].raw);
        const immortal = at < limits.blech.len and e < blech.len and blech[e] <= limits.blech[at].raw;
        examined += @intFromBool(!immortal);
        const narrow: ?Narrow = if (at < limits.narrow.len) limits.narrow[at] else null;
        const allowed = allowedCurrent(power.edge_kind.items[e], power.edge_width.items[e], grid, limits.max_density[at], limits.max_current_per_cut[at], narrow).scale(derate);
        const measured = Measurement.current(.{ .raw = current });
        const limit = Measurement.current(allowed);
        if (immortal or !measured.violates(limit, .maximum)) continue;
        try edgeViolation(r, power, @intCast(e), head, measured, limit);
    }
    return examined;
}

test "interpolate is piecewise linear and held at the ends" {
    // Oracle: closed form: over points 10, 20, 40 with values 1, 3, -5,
    // the line through (10, 1) and (20, 3) gives 2 at 15 and 1.4 at 12;
    // through (20, 3) and (40, -5) gives -1 at 30; the ends hold 1 below
    // 10 and -5 above 40; each point gives its own value.
    const points = [_]f64{ 10.0, 20.0, 40.0 };
    const values = [_]f64{ 1.0, 3.0, -5.0 };
    for ([_][2]f64{ .{ 15, 2 }, .{ 12, 1.4 }, .{ 30, -1 }, .{ 35, -3 }, .{ 10, 1 }, .{ 20, 3 }, .{ 40, -5 }, .{ 0, 1 }, .{ -7, 1 }, .{ 41, -5 }, .{ 1e9, -5 } }) |c| {
        try std.testing.expectApproxEqAbs(c[1], interpolate(&points, &values, c[0]), 1e-12);
    }
    try std.testing.expectEqual(@as(f64, 7.0), interpolate(&.{5.0}, &.{7.0}, 99.0));
    try std.testing.expectEqual(@as(f64, 7.0), interpolate(&.{5.0}, &.{7.0}, -1.0));
}

test "an ac table is bilinear between its corners" {
    // Oracle: closed form: frequencies 100 and 300, widths 500 and 1500,
    // densities 1 and 2 at 100, 3 and 4 at 300: at (200, 1000) the four
    // average to 2.5; at (100, 1000) 1.5; at (300, 750) 3.25; beyond the
    // table each axis holds its end.
    const gpa = std.testing.allocator;
    var scratch: std.ArrayList(f64) = .empty;
    defer scratch.deinit(gpa);
    for ([_][3]f64{ .{ 200, 1000, 2.5 }, .{ 100, 1000, 1.5 }, .{ 300, 750, 3.25 }, .{ 150, 500, 1.5 }, .{ 50, 2000, 2.0 }, .{ 900, 0, 3.0 } }) |c| {
        const got = try tableDensity(gpa, &.{ 100, 300 }, &.{ 500, 1500 }, &.{ 1, 2, 3, 4 }, c[0], c[1], &scratch);
        try std.testing.expectApproxEqAbs(c[2], got, 1e-12);
    }
}

test "blech products are current times line length over width" {
    // Oracle: closed form, by hand. Metal 0-1-2-3 (lengths 100, 200, 300,
    // widths 10, 20, 10) is one line, 600 long, between the pad at 0 and
    // the loaded tap at 3: products 2·600/10 = 120, 3·600/20 = 90 and
    // 1·600/10 = 60, so 120 for all three. The via 3-4 (height 50, width
    // 5) is 4·50/5 = 40. Metal 4-5 (400 by 40) is its own line from the via
    // landing, 0.5·400/40 = 5; metal 5-6 beside it, width 0, makes that
    // line infinite.
    const gpa = std.testing.allocator;
    var grid: PowerGrid = .{};
    defer grid.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    for (0..6) |node| {
        try grid.node_net.append(gpa, @fromBackingInt(0));
        try grid.node_load.append(gpa, .{ .raw = if (node == 3) 5.0 else 0.0 });
    }
    try grid.source_node.append(gpa, 0);
    const Row = struct { u32, u32, Dbu, Dbu, grid_.EdgeKind, f64 };
    const edges = [_]Row{ .{ 0, 1, 100, 10, .metal, 2.0 }, .{ 1, 2, 200, 20, .metal, -3.0 }, .{ 2, 3, 300, 10, .metal, 1.0 }, .{ 3, 4, 50, 5, .via, 4.0 }, .{ 4, 5, 400, 40, .metal, 0.5 } };
    for (edges) |e| {
        try grid.edge_from.append(gpa, e[0]);
        try grid.edge_to.append(gpa, e[1]);
        try grid.edge_length.append(gpa, e[2]);
        try grid.edge_width.append(gpa, e[3]);
        try grid.edge_kind.append(gpa, e[4]);
        try solution.branch_current.append(gpa, .{ .raw = e[5] });
    }
    var out: std.ArrayList(f64) = .empty;
    defer out.deinit(gpa);
    try blechProductsInto(gpa, &grid, &solution, &out);
    try std.testing.expectEqualSlices(f64, &.{ 120, 120, 120, 40, 5 }, out.items);
    try grid.node_net.append(gpa, @fromBackingInt(0));
    try grid.node_load.append(gpa, .{ .raw = 0.0 });
    try grid.edge_from.append(gpa, 5);
    try grid.edge_to.append(gpa, 6);
    try grid.edge_length.append(gpa, 10);
    try grid.edge_width.append(gpa, 0);
    try grid.edge_kind.append(gpa, .metal);
    try solution.branch_current.append(gpa, .{ .raw = 1.0 });
    try blechProductsInto(gpa, &grid, &solution, &out);
    const inf = std.math.inf(f64);
    try std.testing.expectEqualSlices(f64, &.{ 120, 120, 120, 40, inf, inf }, out.items);
}
