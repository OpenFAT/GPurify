//! `esd_path` against a dense nodal solve of the strip network its
//! definition describes, sharing no code with `erc.esd_path`. Ported from
//! tests/exhaustive/erc_reference.rs (`ESD_SHEET`, `ESD_CURRENT`,
//! `esd_reference`, `esd_paths_solve_as_a_dense_nodal_solve_does`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const testgen = @import("testgen");
const Rng = testgen.Rng;
const check = @import("check");
const PowerGrid = check.erc.power_grid.PowerGrid;
const fixture = @import("fixture.zig");
const ported = @import("ported_common.zig");
const Diode = ported.Diode;
const Placed = ported.Placed;
const strip = ported.strip;
const solve = @import("reference_solve.zig");
const common = @import("common.zig");
const gpa = common.gpa;

/// Sheet resistance of the ESD process's strips, Ω per square (pad, VSS,
/// VDD), as `esd_process` states them.
const esd_sheet = [3]f64{ 0.0625, 0.125, 0.0625 };

/// The stress current the deck forces, µA.
const esd_current: f64 = 1_330_000.0;

/// A path resistance and the tolerance the engine is held to, Ω.
const Ohms = struct { ohms: f64, tolerance: f64 };

// ---- private ----

/// The pad's path resistance to supply strip `target`, and its tolerance,
/// from the definition of `esd_path`: each reached strip a chain of
/// resistors between its taps (its centre and every diode marker's centre on
/// it), `sheet * Δx / w`; each diode 1 Ω between its two strips' taps; the
/// current forced in at the pad's centre and out at the target's centre,
/// held at 0 mV. The resistance is the pad's voltage over the current, from
/// `denseNodalSolve`, whose tolerance follows the engine's stopping rule.
fn esdReference(arena: Allocator, w: [3]i64, diodes: []const Placed, reached: [3]bool, target: usize) !Ohms {
    var taps: [3]std.ArrayList(i64) = @splat(.empty);
    for (&taps) |*t| try t.append(arena, @divExact(strip, 2));
    for (diodes) |p| {
        const m = p[0].marker();
        try taps[m.a].append(arena, p[1]);
        try taps[m.b].append(arena, p[1]);
    }
    for (&taps) |*t| {
        std.mem.sort(i64, t.items, {}, std.sort.asc(i64));
        var kept: usize = 0;
        for (t.items, 0..) |x, i| if (i == 0 or x != t.items[i - 1]) {
            t.items[kept] = x;
            kept += 1;
        };
        t.shrinkRetainingCapacity(kept);
    }
    var grid: PowerGrid = .{};
    defer grid.deinit(gpa);
    var first: [3]u32 = @splat(0);
    for (0..3) |k| {
        if (!reached[k]) continue;
        first[k] = grid.nodeCount();
        for (taps[k].items) |x| try grid.pushNode(gpa, .{ .net = @fromBackingInt(@as(u32, @intCast(k))), .at = .{ .x = x, .y = 0 }, .poly = @fromBackingInt(0), .layer = @fromBackingInt(0), .nominal = .{ .raw = 0.0 }, .load = .{ .raw = 0.0 } });
        for (taps[k].items[0 .. taps[k].items.len - 1], taps[k].items[1..], 0..) |x0, x1, i| {
            const squares = @as(f64, @floatFromInt(x1 - x0)) / @as(f64, @floatFromInt(w[k]));
            try edge(&grid, first[k] + @as(u32, @intCast(i)), first[k] + @as(u32, @intCast(i)) + 1, esd_sheet[k] * squares);
        }
    }
    for (diodes) |p| {
        const m = p[0].marker();
        if (reached[m.a] and reached[m.b]) try edge(&grid, node(&taps, first, m.a, p[1]), node(&taps, first, m.b, p[1]), 1.0);
    }
    const entry = node(&taps, first, 0, @divExact(strip, 2));
    grid.node_load.items[entry] = .{ .raw = -esd_current };
    try grid.source_node.append(gpa, node(&taps, first, target, @divExact(strip, 2)));
    try grid.source_voltage.append(gpa, .{ .raw = 0.0 });
    const v = try arena.alloc(f64, grid.nodeCount());
    const tolerance = try solve.denseNodalSolve(&grid, v);
    const ohms = v[entry] * 1000.0 / esd_current;
    return .{ .ohms = ohms, .tolerance = tolerance * 1000.0 / esd_current + 4.0 * std.math.floatEps(f64) * ohms };
}

fn edge(grid: *PowerGrid, a: u32, b: u32, ohms: f64) !void {
    try grid.pushEdge(gpa, .{ .from = a, .to = b, .ohms = ohms, .width = 1, .length = 1, .layer = @fromBackingInt(0), .kind = .metal });
}

fn node(taps: *const [3]std.ArrayList(i64), first: [3]u32, k: usize, x: i64) u32 {
    const i = std.mem.indexOfScalar(i64, taps[k].items, x) orelse unreachable;
    return first[k] + @as(u32, @intCast(i));
}

fn lessOhms(_: void, a: Ohms, b: Ohms) bool {
    return a.ohms < b.ohms;
}

test "esd paths solve as a dense nodal solve does" {
    // Oracle: a dense nodal solve. On forty generated layouts of the ESD
    // strip process (strips 0.5 to 2 µm wide, one to five down, up and rail
    // diodes at distinct places), `esd_path` reports one finding per supply
    // the pad reaches through the diodes, and their resistances are those
    // `esdReference` derives, within its tolerance. The run is the real one:
    // the layout extracted and checked.
    var rng = Rng.init(0xc6_0003);
    var pairs: usize = 0;
    var parallel: usize = 0;
    const deck = ported.esd_process ++ "rule ep esd_path(pad; clamps: " ++ ported.esd_clamps ++
        ", current: 1330mA, clamp_resistance: 1ohm, max_resistance: 0.001ohm, clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none)\n";
    for (0..40) |case| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var w: [3]i64 = undefined;
        for (&w) |*x| x.* = ([_]i64{ 500, 1000, 2000 })[rng.below(3)];
        var slots: std.ArrayList(i64) = .empty;
        for (1..20) |k| try slots.append(a, @as(i64, @intCast(k)) * 1000);
        var diodes: std.ArrayList(Placed) = .empty;
        for (0..rng.below(5) + 1) |_| {
            const at = slots.swapRemove(rng.below(slots.items.len));
            const kind = ([_]Diode{ .down, .up, .rail })[rng.below(3)];
            try diodes.append(a, .{ kind, at });
        }
        // The pad, then every strip a diode joins to one already reached.
        var reached = [3]bool{ true, false, false };
        var grew = true;
        while (grew) {
            grew = false;
            for (diodes.items) |p| {
                const m = p[0].marker();
                if (reached[m.a] != reached[m.b]) {
                    reached[m.a] = true;
                    reached[m.b] = true;
                    grew = true;
                }
            }
        }
        var want: std.ArrayList(Ohms) = .empty;
        for (1..3) |k| if (reached[k]) try want.append(a, try esdReference(a, w, diodes.items, reached, k));
        std.mem.sort(Ohms, want.items, {}, lessOhms);
        parallel += @intFromBool(diodes.items.len > 2 and want.items.len == 2);

        const f: fixture.Fixture = .{
            .name = try std.fmt.allocPrint(a, "esd_path/{d}", .{case}),
            .deck = deck,
            .layout = try ported.esdLayout(a, w, diodes.items),
            .intent = try ported.esdIntent(a),
        };
        const ran = try fixture.run(a, &f);
        var got: std.ArrayList(f64) = .empty;
        for (ran.findings) |found| {
            if (!std.mem.eql(u8, found.id, "ep")) continue;
            try testing.expectEqual(check.report.Kind.resistance, found.measured.kind);
            try got.append(a, found.measured.float());
        }
        std.mem.sort(f64, got.items, {}, std.sort.asc(f64));
        try testing.expectEqual(want.items.len, got.items.len);
        for (got.items, want.items) |engine, ref| try testing.expect(@abs(engine - ref.ohms) <= ref.tolerance);
        pairs += want.items.len;
    }
    try testing.expect(pairs >= 40 and parallel >= 5);
}
