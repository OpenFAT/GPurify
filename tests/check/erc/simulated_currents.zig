//! ERC-E14 at the check level: simulated terminal currents loading the
//! supply grid in place of the intent's budgets. Drawn met1/met2 rails and
//! resistor loads in, each terminal's current placed on its device as LVS
//! would place it (fixture.zig `placed`); the rules' findings and the solved
//! grid out, against closed forms, a dense nodal solve, Kirchhoff's law and
//! the budget model. The LVS placement and its refusals are
//! tests/gpurify/erc_currents.zig's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const check = @import("check");
const erc = check.erc;
const PowerGrid = erc.power_grid.PowerGrid;
const PowerSolution = erc.power_grid.PowerSolution;
const testgen = @import("testgen");
const assertClose = testgen.assertClose;
const assertCloseRelative = testgen.assertCloseRelative;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const SimLoad = fixture.SimLoad;
const cf = @import("closed_form.zig");
const rails = @import("exhaustive_rails.zig");
const pc = @import("ported_circuit.zig");
const at = rails.at;
const microamps = rails.microamps;
const common = @import("common.zig");
const gpa = common.gpa;

// ---- private ----

/// A 20 µm × 1 µm VDD rail fed at its centre (10 µm), loads at 12, 14 and
/// 18 µm (rails.zig's ladder).
fn ladder(arena: Allocator) !Layout {
    var l: Layout = .{};
    try rails.rail(&l, arena, "VDD", 20_000, 0, 1000, &.{ 12_000, 14_000, 18_000 });
    return l;
}

/// One load per position, `ua` each, terminal 0 (the rail), named `x<µm>`.
fn loadsAt(arena: Allocator, xs: []const i64, ua: []const f64) ![]const SimLoad {
    const out = try arena.alloc(SimLoad, xs.len);
    for (out, xs, ua) |*o, x, u| o.* = .{ .at = .{ x, 0 }, .ua = u, .instance = try std.fmt.allocPrint(arena, "x{d}", .{@divTrunc(x, 1000)}) };
    return out;
}

/// The VDD intent: a 1.8 V supply, its budget `budget` µA, a drop limit.
fn vdd(arena: Allocator, budget: f64, max_drop_mv: f64) ![]const u8 {
    return rails.intent(arena, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"budget_current_ua\":{d},\"max_drop_mv\":{d}}}", .{ budget, max_drop_mv }));
}

/// A fixture's supply grid built with its loads (or the budgets alone),
/// solved; the caller deinits both.
fn solvedGrid(arena: Allocator, f: *const Fixture, with_loads: bool, grid: *PowerGrid, solution: *PowerSolution) !void {
    var b: fixture.Built = .{};
    defer b.deinit();
    try fixture.build(arena, f, &b);
    var intent: erc.facts.IntentMap = .{};
    defer intent.deinit(gpa);
    try erc.facts.resolveIntentInto(gpa, if (b.intent) |*i| i else null, &b.ports, &b.nets, &intent);
    const placed = try fixture.placed(arena, &b, f.currents);
    const loads: erc.power_grid.Loads = if (with_loads) placed.loads(.avg) else .{};
    var diag: erc.power_grid.PowerDiag = .{};
    try erc.power_extract.extractInto(gpa, &b.store, &b.nets, &b.devices, &intent, loads, b.process(), grid, &diag);
    solution.* = try common.solve(grid);
}

/// Each node's load is its terminals' sum, and at every node but a pad the
/// branch currents in less those out equal it (Kirchhoff's current law).
fn assertKirchhoff(grid: *const PowerGrid, s: *const PowerSolution) !void {
    const drawn = try gpa.alloc(f64, grid.nodeCount());
    defer gpa.free(drawn);
    @memset(drawn, 0.0);
    for (grid.term_node.items, grid.term_load.items) |n, l| drawn[n] += l.raw;
    const into = try gpa.alloc(f64, grid.nodeCount());
    defer gpa.free(into);
    @memset(into, 0.0);
    for (grid.edge_from.items, grid.edge_to.items, s.branch_current.items) |from, to, c| {
        into[from] -= c.raw;
        into[to] += c.raw;
    }
    for (0..grid.nodeCount()) |n| {
        try assertClose("a node's load is its terminals' currents", grid.node_load.items[n].raw, drawn[n], 1e-9);
        if (std.mem.indexOfScalar(u32, grid.source_node.items, @intCast(n)) != null) continue;
        try assertClose("Kirchhoff's current law", into[n], drawn[n], 1e-6);
    }
}

/// The DC solve of `grid` by dense Gaussian elimination: every pad held at
/// its voltage, `G v = -load` over the rest. Returns each edge's current.
fn denseBranchCurrents(arena: Allocator, grid: *const PowerGrid) ![]const f64 {
    const n = grid.nodeCount();
    const pad = try arena.alloc(?f64, n);
    @memset(pad, null);
    for (grid.source_node.items, grid.source_voltage.items) |node, v| pad[node] = v.raw;
    // The augmented system [G | b], one row per node; a pad's row is `v = V`.
    const a = try arena.alloc(f64, n * (n + 1));
    @memset(a, 0.0);
    for (0..n) |i| a[i * (n + 1) + n] = -grid.node_load.items[i].raw;
    for (grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |f, t, r| {
        const g = erc.power_grid.ua_per_mv_ohm / r.raw;
        for ([2][2]u32{ .{ f, t }, .{ t, f } }) |e| {
            a[e[0] * (n + 1) + e[0]] += g;
            a[e[0] * (n + 1) + e[1]] -= g;
        }
    }
    for (pad, 0..) |p, i| if (p) |v| {
        @memset(a[i * (n + 1) .. (i + 1) * (n + 1)], 0.0);
        a[i * (n + 1) + i] = 1.0;
        a[i * (n + 1) + n] = v;
    };
    // Gauss-Jordan with partial pivoting.
    for (0..n) |c| {
        var best = c;
        for (c..n) |r| if (@abs(a[r * (n + 1) + c]) > @abs(a[best * (n + 1) + c])) {
            best = r;
        };
        for (0..n + 1) |k| std.mem.swap(f64, &a[c * (n + 1) + k], &a[best * (n + 1) + k]);
        const p = a[c * (n + 1) + c];
        for (0..n + 1) |k| a[c * (n + 1) + k] /= p;
        for (0..n) |r| if (r != c) {
            const m = a[r * (n + 1) + c];
            for (0..n + 1) |k| a[r * (n + 1) + k] -= m * a[c * (n + 1) + k];
        };
    }
    const out = try arena.alloc(f64, grid.edgeCount());
    for (out, grid.edge_from.items, grid.edge_to.items, grid.edge_resistance.items) |*o, f, t, r| {
        o.* = (a[f * (n + 1) + n] - a[t * (n + 1) + n]) * erc.power_grid.ua_per_mv_ohm / r.raw;
    }
    return out;
}

test "each segment of a tapped wire carries the currents beyond it" {
    // Oracle: closed form. A wire fed at 10 µm with taps at 12, 14 and
    // 18 µm drawing 1000, 1500 and 500 µA: by Kirchhoff each segment carries
    // the sum of the taps beyond it, 3000, 2000 and 500 µA, and each tap's
    // drop is the sum of `I · R` over the segments to the pad (met1
    // 0.125 Ω/sq, 1 µm wide: 0.25, 0.25 and 0.5 Ω): 0.75, 1.25 and 1.5 mV.
    // The segment and tap rows name the terminal whose current moves each
    // most (the adjoint): 12-14 µm carries x14's 1500 over x18's 500.
    // A model that spreads the 3 mA evenly gives 3000, 2000, 1000 µA.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f: Fixture = .{
        .name = "erc/currents/ladder",
        .deck = try rails.railDeck(arena, "rule em em_current_density(met1; max_density: 1uA/um, max_current_per_cut: 1000uA, narrow: none)\nrule ir ir_drop()"),
        .layout = try ladder(arena),
        .intent = try vdd(arena, 3000.0, 0.5),
        .currents = try loadsAt(arena, &.{ 12_000, 14_000, 18_000 }, &.{ 1000.0, 1500.0, 500.0 }),
        .expect = &.{
            .{ .id = "em", .findings = &.{ at(microamps(3000.0), 10_000, 500), at(microamps(2000.0), 12_000, 500), at(microamps(500.0), 14_000, 500) } },
            .{ .id = "ir", .findings = &.{ at(pc.millivolts(0.75), 12_000, 500), at(pc.millivolts(1.25), 14_000, 500), at(pc.millivolts(1.5), 18_000, 500) } },
            // The budget the currents replaced, reported unused.
            .{ .id = "erc.budget_unused", .findings = &.{.{ .measured = .current(.{ .raw = 3000.0 }) }} },
        },
    };
    try fixture.checkAll(&.{f});
    const ran = try fixture.run(arena, &f);
    var names: [3][]const u8 = undefined;
    var k: usize = 0;
    for (ran.findings) |found| if (std.mem.eql(u8, found.id, "em")) {
        names[
            switch (found.at[0]) {
                10_000 => 0,
                12_000 => 1,
                else => 2,
            }
        ] = found.load;
        k += 1;
    };
    try testing.expectEqual(3, k);
    for ([_][]const u8{ "x14", "x14", "x18" }, names) |want, got| try testing.expectEqualStrings(want, got);
}

test "equal loads give the budget model's grid" {
    // Oracle: the budget model on the same net. A 3 mA budget spread over
    // three loads is 1000 µA each; simulated currents of 1000 µA at each
    // load must solve to the same branch currents and node drops, edge for
    // edge. A placement that drops one load fails it.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f: Fixture = .{
        .name = "erc/currents/equivalence",
        .deck = try rails.railDeck(arena, ""),
        .layout = try ladder(arena),
        .intent = try vdd(arena, 3000.0, 1.0),
        .currents = try loadsAt(arena, &.{ 12_000, 14_000, 18_000 }, &.{ 1000.0, 1000.0, 1000.0 }),
    };
    var budget: PowerGrid = .{};
    defer budget.deinit(gpa);
    var budget_s: PowerSolution = .{};
    defer budget_s.deinit(gpa);
    try solvedGrid(arena, &f, false, &budget, &budget_s);
    var simulated: PowerGrid = .{};
    defer simulated.deinit(gpa);
    var simulated_s: PowerSolution = .{};
    defer simulated_s.deinit(gpa);
    try solvedGrid(arena, &f, true, &simulated, &simulated_s);
    try testing.expectEqual(budget.edgeCount(), simulated.edgeCount());
    try testing.expect(budget.edgeCount() > 0);
    for (budget_s.branch_current.items, simulated_s.branch_current.items) |a, b| try assertClose("a branch current", b.raw, a.raw, 1e-9);
    for (budget_s.node_drop.items, simulated_s.node_drop.items) |a, b| try assertClose("a node drop", b.raw, a.raw, 1e-9);
}

test "a via array's cuts carry what the dense nodal solve gives them" {
    // Oracle: a dense nodal solve. A met2 pad bar over the left of a met1
    // strip, three cuts at 0.5, 1.5 and 2.5 µm, one 1 mA load at 7 µm: the
    // cuts nearer the load carry more. Each cut's current from the grid's
    // sparse solve equals Gauss-Jordan elimination of the same network
    // (independent of the sparse factorisation), and the cuts together
    // carry the whole 1 mA (Kirchhoff, across the cut layer).
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 8000, 1000);
    try cf.named(arena, &l, "met2", 0, 0, 3000, 1000, "VDD");
    for ([_]i64{ 500, 1500, 2500 }) |x| try l.rect(arena, "via1", x - 100, 400, x + 100, 600);
    try cf.loadAt(arena, &l, 7000, 0);
    const f: Fixture = .{
        .name = "erc/currents/via_array",
        .deck = try rails.railDeck(arena, ""),
        .layout = l,
        .intent = try vdd(arena, 1000.0, 1.0),
        .currents = &.{.{ .at = .{ 7000, 0 }, .ua = 1000.0 }},
    };
    var grid: PowerGrid = .{};
    defer grid.deinit(gpa);
    var s: PowerSolution = .{};
    defer s.deinit(gpa);
    try solvedGrid(arena, &f, true, &grid, &s);
    const dense = try denseBranchCurrents(arena, &grid);
    var cuts: u32 = 0;
    var through: f64 = 0.0;
    var least: f64 = std.math.inf(f64);
    var most: f64 = 0.0;
    for (grid.edge_kind.items, s.branch_current.items, dense) |kind, sparse, d| {
        try assertClose("a branch current against the dense solve", sparse.raw, d, 1e-6);
        if (kind != .via) continue;
        cuts += 1;
        through += @abs(d);
        least = @min(least, @abs(d));
        most = @max(most, @abs(d));
    }
    try testing.expectEqual(3, cuts);
    try assertCloseRelative("the cuts carry the whole load", through, 1000.0, 1e-9);
    try testing.expect(most > least * 1.01);
    try assertKirchhoff(&grid, &s);
}

test "kirchhoff's law holds at every node of every net the currents load" {
    // Oracle: law. Each resistor load draws I from VDD into its rail
    // terminal and returns it out of its poly terminal (a net of its own,
    // no supply, held at its pad): every node of every solved net balances,
    // its load the sum of its terminals'. Either sign inverted, or a
    // terminal placed on another node, fails at that node.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var loads: std.ArrayList(SimLoad) = .empty;
    for ([_]i64{ 12_000, 14_000, 18_000 }, [_]f64{ 700.0, 1100.0, 300.0 }) |x, ua| {
        try loads.append(arena, .{ .at = .{ x, 0 }, .ua = ua });
        try loads.append(arena, .{ .at = .{ x, 0 }, .terminal = 1, .ua = -ua });
    }
    const f: Fixture = .{
        .name = "erc/currents/kirchhoff",
        .deck = try rails.railDeck(arena, ""),
        .layout = try ladder(arena),
        .intent = try vdd(arena, 1.0, 1.0),
        .currents = loads.items,
    };
    var grid: PowerGrid = .{};
    defer grid.deinit(gpa);
    var s: PowerSolution = .{};
    defer s.deinit(gpa);
    try solvedGrid(arena, &f, true, &grid, &s);
    // VDD and the three poly stubs.
    try testing.expectEqual(4, grid.source_node.items.len);
    try testing.expectEqual(6, grid.term_node.items.len);
    try assertKirchhoff(&grid, &s);
}
