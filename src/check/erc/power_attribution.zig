//! Which simulated terminal loads a grid edge or node most (catalog
//! ERC-E14): the adjoint of the DC solve. In: a grid carrying terminal
//! loads (`PowerGrid.term_*`) and one edge or node. Out: the terminal whose
//! current contributes most to that edge's current, or to that node's
//! voltage, or null on a budget grid. By reciprocity one solve of the
//! grid's own matrix gives every load's sensitivity at once: with every pad
//! held at 0 V, a unit current into the edge's ends (or the node) sets each
//! node to the edge current (or node voltage) one unit drawn there causes,
//! so a terminal's part is its load times its node's voltage.
//!
//! Contents:
//! - `pub const Probe = union(enum) { edge: u32, node: u32 }`
//! - `pub fn dominantLoad(gpa: Allocator, grid: *const PowerGrid, probe: Probe) Allocator.Error!?Load`

const std = @import("std");
const Allocator = std.mem.Allocator;
const report = @import("../report.zig");
const Load = report.Load;
const Millivolts = report.Millivolts;
const Microamps = report.Microamps;
const grid_ = @import("power_grid.zig");
const PowerGrid = grid_.PowerGrid;
const PowerSolution = grid_.PowerSolution;
const power_solve = @import("power_solve.zig");

/// What a finding sits on: an edge (its branch current) or a node (its drop).
pub const Probe = union(enum) { edge: u32, node: u32 };

/// The terminal row whose load moves `probe` most, by magnitude, the first
/// on a tie; null on a grid without terminal loads, or when the adjoint
/// does not solve (the grid did, so only a pathological one).
/// ponytail: one solve per finding; cache per edge, or trace each
/// terminal's flow once, if a badly failing design makes it slow.
pub fn dominantLoad(gpa: Allocator, grid: *const PowerGrid, probe: Probe) Allocator.Error!?Load {
    if (grid.term_node.items.len == 0) return null;
    const nodes = grid.nodeCount();
    // The adjoint grid: the same network, every pad at 0 mV, nothing drawn
    // but the unit probe (the solve's right-hand side is minus the load).
    const load = try gpa.alloc(Microamps, nodes);
    defer gpa.free(load);
    @memset(load, .{ .raw = 0.0 });
    switch (probe) {
        .edge => |e| {
            load[grid.edge_from.items[e]] = .{ .raw = -1.0 };
            load[grid.edge_to.items[e]] = .{ .raw = 1.0 };
        },
        .node => |n| load[n] = .{ .raw = -1.0 },
    }
    const zero_nodes = try gpa.alloc(Millivolts, nodes);
    defer gpa.free(zero_nodes);
    @memset(zero_nodes, .{ .raw = 0.0 });
    const zero_pads = try gpa.alloc(Millivolts, grid.source_node.items.len);
    defer gpa.free(zero_pads);
    @memset(zero_pads, .{ .raw = 0.0 });
    // A view: the grid's own columns but these three, never written.
    var adjoint = grid.*;
    adjoint.node_load = .fromOwnedSlice(load);
    adjoint.node_nominal = .fromOwnedSlice(zero_nodes);
    adjoint.source_voltage = .fromOwnedSlice(zero_pads);
    var scratch: power_solve.SolveScratch = .{};
    defer scratch.deinit(gpa);
    var solution: PowerSolution = .{};
    defer solution.deinit(gpa);
    var diag: grid_.PowerDiag = .{};
    power_solve.solveInto(gpa, &adjoint, &scratch, &solution, &diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    var best: ?usize = null;
    var most: f64 = 0.0;
    for (grid.term_node.items, grid.term_load.items, 0..) |node, l, t| {
        const part = @abs(l.raw * solution.node_voltage.items[node].raw);
        if (part > most) {
            most = part;
            best = t;
        }
    }
    return if (best) |t| grid.term_name.items[t] else null;
}

test "the load behind a segment of a chain is the one named" {
    // Oracle: closed form. A chain pad - a - b of 1 ohm segments, 3 uA drawn
    // at `a` and 1 uA at `b`: the segment a-b carries only b's current, so b
    // loads it most though a draws more; the segment pad-a carries both, a's
    // the larger; b's drop is 3 + 2 * 1 mV-units, a's part the larger.
    const gpa = std.testing.allocator;
    var g: PowerGrid = .{};
    defer g.deinit(gpa);
    for (0..3) |i| try g.pushNode(gpa, .{ .net = @fromBackingInt(0), .at = .{ .x = @intCast(i), .y = 0 }, .poly = @fromBackingInt(0), .layer = @fromBackingInt(0), .nominal = .{ .raw = 0.0 }, .load = .{ .raw = if (i == 1) 3.0 else if (i == 2) 1.0 else 0.0 } });
    try g.source_node.append(gpa, 0);
    try g.source_voltage.append(gpa, .{ .raw = 0.0 });
    for ([_][2]u32{ .{ 0, 1 }, .{ 1, 2 } }) |e| try g.pushEdge(gpa, .{ .from = e[0], .to = e[1], .ohms = 1.0, .width = 1, .length = 1, .layer = @fromBackingInt(0), .kind = .metal });
    const a: Load = .{ .instance = @fromBackingInt(10), .terminal = @fromBackingInt(20) };
    const b: Load = .{ .instance = @fromBackingInt(11), .terminal = @fromBackingInt(20) };
    for ([_]u32{ 1, 2 }, [_]f64{ 3.0, 1.0 }, [_]Load{ a, b }) |node, l, name| {
        try g.term_node.append(gpa, node);
        try g.term_load.append(gpa, .{ .raw = l });
        try g.term_name.append(gpa, name);
    }
    try std.testing.expectEqual(b, (try dominantLoad(gpa, &g, .{ .edge = 1 })).?);
    try std.testing.expectEqual(a, (try dominantLoad(gpa, &g, .{ .edge = 0 })).?);
    try std.testing.expectEqual(a, (try dominantLoad(gpa, &g, .{ .node = 2 })).?);
    g.term_node.clearRetainingCapacity();
    g.term_load.clearRetainingCapacity();
    g.term_name.clearRetainingCapacity();
    try std.testing.expectEqual(null, try dominantLoad(gpa, &g, .{ .node = 2 }));
}
