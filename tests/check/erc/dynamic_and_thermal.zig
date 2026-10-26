//! The worst switching cycle (`dynamic_ir_drop`, ERC-E11) and the
//! self-heated, statistical EM limit (`em_thermal`, ERC-E13), against
//! closed forms and the laws an RC grid stepped by backward Euler obeys.
//! Ported from crates/check/tests/erc/dynamic_and_thermal.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const gpa = common.gpa;
const erc = check.erc;
const report = check.report;
const Measurement = report.Measurement;
const PowerGrid = erc.power_grid.PowerGrid;
const PowerSolution = erc.power_grid.PowerSolution;
const Stimulus = erc.power_transient.Stimulus;
const steps_per_rise = erc.power_transient.steps_per_rise;
const el = erc.electrical_tables;

/// Boltzmann's constant in eV/K (CODATA 2018).
const k_ev: f64 = 8.617_333_262e-5;

// ---- private ----

/// One switching event: `peak` µA per node, all `rise` ps wide, `cap` pF
/// per node, followed for `window` ps.
fn stimulus(peak: []const f64, rise: f64, cap: []const f64, window: f64) !Stimulus {
    var s: Stimulus = .{ .window_ps = window };
    for (peak) |p| try s.node_peak.append(gpa, .{ .raw = p });
    try s.node_rise_ps.appendNTimes(gpa, rise, peak.len);
    try s.node_cap_pf.appendSlice(gpa, cap);
    return s;
}

/// The engine's response, mV per node, into `out`.
fn respond(grid: *const PowerGrid, peak: []const f64, rise: f64, cap: []const f64, window: f64, out: []f64) !void {
    var s = try stimulus(peak, rise, cap, window);
    defer s.deinit(gpa);
    var scratch: erc.power_solve.SolveScratch = .{};
    defer scratch.deinit(gpa);
    var got: std.ArrayList(report.Millivolts) = .empty;
    defer got.deinit(gpa);
    var diag: erc.power_grid.PowerDiag = .{};
    try erc.power_transient.transientInto(gpa, grid, &s, &scratch, &got, &diag);
    for (out, got.items) |*o, g| o.* = g.raw;
}

/// The triangle at step `k` of a pulse `steps_per_rise` wide.
fn triangle(k: u32) f64 {
    const fraction = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps_per_rise));
    return if (fraction <= 1.0) 1.0 - @abs(2.0 * fraction - 1.0) else 0.0;
}

/// The largest value of one RC node's backward-Euler recurrence,
/// `r[k+1] = (c r[k] + i[k+1]) / (c + g)`, `c = 1000 C / h`, `g = 1000 / R`,
/// `h` the rise over `steps_per_rise`, over ten rises.
fn recurrencePeak(ohm: f64, cap_pf: f64, peak_ua: f64, rise_ps: f64) f64 {
    const h = rise_ps / @as(f64, @floatFromInt(steps_per_rise));
    const c = 1000.0 * cap_pf / h;
    const g = 1000.0 / ohm;
    var r: f64 = 0.0;
    var best: f64 = 0.0;
    for (1..10 * steps_per_rise + 1) |k| {
        r = (c * r + peak_ua * triangle(@intCast(k))) / (c + g);
        best = @max(best, r);
    }
    return best;
}

/// The continuous peak of one RC node's response to the triangle: `R k`
/// times `ρ(t) - 2 ρ(t - t_r/2) + ρ(t - t_r)`, `ρ(s) = s - τ (1 - e^{-s/τ})`.
/// Unimodal: a scan, then a ternary search around its best.
fn closedFormPeak(ohm: f64, peak_ua: f64, rise_ps: f64, tau_ps: f64) f64 {
    const P = struct {
        ohm: f64,
        slope: f64,
        rise: f64,
        tau: f64,
        fn ramp(p: @This(), s: f64) f64 {
            return if (s > 0.0) s - p.tau * (1.0 - @exp(-s / p.tau)) else 0.0;
        }
        fn drop(p: @This(), t: f64) f64 {
            return p.ohm / 1000.0 * p.slope * (p.ramp(t) - 2.0 * p.ramp(t - p.rise / 2.0) + p.ramp(t - p.rise));
        }
    };
    const p: P = .{ .ohm = ohm, .slope = 2.0 * peak_ua / rise_ps, .rise = rise_ps, .tau = tau_ps };
    const end = rise_ps + 10.0 * tau_ps;
    const samples: u32 = 20_000;
    var best: u32 = 0;
    for (0..samples + 1) |i| {
        const at = end * @as(f64, @floatFromInt(i)) / samples;
        if (p.drop(at) > p.drop(end * @as(f64, @floatFromInt(best)) / samples)) best = @intCast(i);
    }
    var lo = end * @as(f64, @floatFromInt(best -| 1)) / samples;
    var hi = end * @as(f64, @floatFromInt(@min(best + 1, samples))) / samples;
    for (0..200) |_| {
        const a = lo + (hi - lo) / 3.0;
        const b = hi - (hi - lo) / 3.0;
        if (p.drop(a) < p.drop(b)) lo = a else hi = b;
    }
    return p.drop(0.5 * (lo + hi));
}

/// A net switching a quarter of its 1000 ps cycles with 100 ps rises, its
/// budget, decap and dynamic limit.
fn switchingIntent(power: u32, ground: u32, budget: f64, decap: f64, limit: f64) !erc.facts.IntentMap {
    var m = try common.declaredSupplies(@fromBackingInt(power), @fromBackingInt(ground), 1_800.0);
    try common.limitNet(&m, @fromBackingInt(0), .{ .budget_current_ua = budget, .dynamic = .{ .max_drop = .{ .raw = limit }, .toggle_rate = 0.25, .clock_period_ps = 1000.0, .rise_time_ps = 100.0, .decap_pf = decap } });
    return m;
}

/// An `em_thermal` row on `layers` at 105 °C, Ea 0.9 eV, n 2, a Blech
/// limit too small to exempt anything.
fn thermalTable(id: geom.StrId, layers: []const geom.LayerId, density_am: f64, per_cut: f64) !el.EmThermalTable {
    var t: el.EmThermalTable = .{ .head = try common.head(id) };
    try t.layer_start.appendSlice(gpa, &.{ 0, @intCast(layers.len) });
    try t.layer.appendSlice(gpa, layers);
    try t.max_density.appendNTimes(gpa, .{ .raw = density_am }, layers.len);
    try t.max_current_per_cut.appendNTimes(gpa, .{ .raw = per_cut }, layers.len);
    try t.blech_limit.appendNTimes(gpa, .{ .raw = 1e-6 }, layers.len);
    try t.reference_temperature.append(gpa, .{ .raw = 378.15 });
    try t.activation_energy_ev.append(gpa, 0.9);
    try t.current_exponent.append(gpa, 2.0);
    try t.thermal_conductivity.append(gpa, 1.0);
    try t.heat_spreading.append(gpa, 0.88);
    try t.sigma.append(gpa, 0.5);
    try t.limit_failure.append(gpa, 0.001);
    try t.max_failure.append(gpa, 1.0);
    return t;
}

/// Black's derating from 105 °C to `t`.
fn black(t: f64) f64 {
    return @exp(0.9 / (2.0 * k_ev) * (1.0 / t - 1.0 / 378.15));
}

/// One `em_thermal` table over a solved grid at `t` K.
fn runThermal(sink: *common.Sink, grid: *const PowerGrid, t: *const el.EmThermalTable, kelvin: f64, height_nm: []const f64) !void {
    var solution = try common.solve(grid);
    defer solution.deinit(gpa);
    var intent = try common.declaredSupplies(@fromBackingInt(0), @fromBackingInt(1), 1_800.0);
    defer intent.deinit(gpa);
    try erc.electrical.checkEmThermal(sink.record(), .{ .solved = .{ .grid = grid, .solution = &solution } }, &intent, common.manufacturingGrid(), .{ .raw = kelvin }, t, height_nm);
}

/// One run's current findings (`(at.x, shape_b)`, sorted) and the chip's
/// probability.
fn findingsInto(v: *const report.Violations, wires: *std.ArrayList([2]i64)) !f64 {
    wires.clearRetainingCapacity();
    var chip: f64 = 0.0;
    for (0..v.len()) |row| {
        const f = v.get(@intCast(row));
        switch (f.measured.kind) {
            .current => try wires.append(gpa, .{ f.at.x, if (f.shape_b == report.no_shape) 0 else @backingInt(f.shape_b) }),
            .ratio => chip = f.measured.float(),
            else => return error.UnexpectedKind,
        }
    }
    std.mem.sortUnstable([2]i64, wires.items, {}, struct {
        fn less(_: void, a: [2]i64, b: [2]i64) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }
    }.less);
    return chip;
}

test "one rc node follows its backward euler recurrence" {
    // Oracle: closed form of the documented discretization: one node behind
    // R with decap C, stepped by backward Euler at `steps_per_rise` steps
    // per rise, is the scalar recurrence `recurrencePeak` works by hand; the
    // pad's response is zero.
    for ([_][4]f64{ .{ 1.0, 10.0, 1000.0, 100.0 }, .{ 2.5, 0.3, 400.0, 50.0 }, .{ 0.1, 200.0, 20_000.0, 20.0 } }) |c| {
        var grid = try common.seriesChain(1, c[0], 1_800.0, 0.0);
        defer grid.deinit(gpa);
        var got: [2]f64 = undefined;
        try respond(&grid, &.{ 0.0, c[2] }, c[3], &.{ 0.0, c[1] }, 10.0 * c[3], &got);
        try testgen.assertClose("the pad's response", got[0], 0.0, 0.0);
        try testgen.assertCloseRelative("the node's peak", got[1], recurrencePeak(c[0], c[1], c[2], c[3]), 1e-12);
    }
}

test "an rc node's peak is its closed form within backward euler's error" {
    // Oracle: closed form. A ramp into R with decap C gives
    // `R k (t - τ (1 - e^{-t/τ}))`, and the triangle is three ramps.
    // Backward Euler damps, so the engine's peak is never above the
    // continuous one, and at 128 steps per rise at most 0.61 % below it.
    const ohm = 1.0;
    const peak = 1000.0;
    const rise = 100.0;
    for ([_]f64{ 0.001, 0.01, 0.03, 0.11, 0.3, 1.0, 3.0, 30.0 }) |ratio| {
        const tau = ratio * rise;
        var grid = try common.seriesChain(1, ohm, 1_800.0, 0.0);
        defer grid.deinit(gpa);
        var got: [2]f64 = undefined;
        try respond(&grid, &.{ 0.0, peak }, rise, &.{ 0.0, tau / ohm }, 10.0 * rise, &got);
        const exact = closedFormPeak(ohm, peak, rise, tau);
        try testing.expect(got[1] <= exact * (1.0 + 1e-9));
        try testing.expect(got[1] >= exact * (1.0 - 0.0061));
    }
}

test "without decap a grid responds with the static drop of its peaks" {
    // Oracle: closed form. Without decap a backward-Euler step is the static
    // solve of that step's loads, and every pulse peaks on step
    // `steps_per_rise / 2`: each node's response is `solveInto`'s drop with
    // every load at its peak.
    var got: [30]f64 = undefined;
    var peaks: [30]f64 = undefined;
    const zeros: [30]f64 = @splat(0.0);
    for (1..7) |seed| {
        var grid = try common.randomGrid(seed, 30, 20);
        defer grid.deinit(gpa);
        for (&peaks, grid.node_load.items) |*p, l| p.* = 3.0 * l.raw;
        try respond(&grid, &peaks, 50.0, &zeros, 50.0, &got);
        for (grid.node_load.items, peaks) |*l, p| l.* = .{ .raw = p };
        var reference = try common.solve(&grid);
        defer reference.deinit(gpa);
        var scale: f64 = 0.0;
        for (reference.node_drop.items) |d| scale = @max(scale, @abs(d.raw));
        for (got, reference.node_drop.items) |have, want| try testgen.assertClose("node", have, want.raw, 1e-8 * scale);
    }
}

test "more current never lowers a node's response" {
    // Oracle: law. `(G + C/h)⁻¹` of an RC grid is nonnegative and so is
    // `C/h`, so every step's response is a nonnegative combination of the
    // loads: doubling one load's peak lowers no node's peak.
    var base: [30]f64 = undefined;
    var raised: [30]f64 = undefined;
    var peaks: [30]f64 = undefined;
    var caps: [30]f64 = undefined;
    for (1..7) |seed| {
        var grid = try common.randomGrid(seed, 30, 20);
        defer grid.deinit(gpa);
        var rng = testgen.Rng.init(seed);
        for (&caps) |*c| c.* = 5.0 * rng.unit();
        for (&peaks, grid.node_load.items) |*p, l| p.* = l.raw;
        try respond(&grid, &peaks, 40.0, &caps, 400.0, &base);
        var scale: f64 = 0.0;
        for (base) |b| scale = @max(scale, @abs(b));
        peaks[15] *= 2.0;
        try respond(&grid, &peaks, 40.0, &caps, 400.0, &raised);
        for (raised, base) |r, b| try testing.expect(r >= b - 1e-9 * scale);
    }
}

test "decap never raises a drop and more of it lowers an rc node's peak" {
    // Oracle: law. With every load at most its peak no drop exceeds the
    // decap-free `D = G⁻¹ I_peak` (by induction on the step), so decap never
    // raises a node above its decap-free response; on one RC node more decap
    // strictly lowers the peak.
    var free: [30]f64 = undefined;
    var held: [30]f64 = undefined;
    var peaks: [30]f64 = undefined;
    var caps: [30]f64 = undefined;
    const zeros: [30]f64 = @splat(0.0);
    for (1..7) |seed| {
        var grid = try common.randomGrid(seed, 30, 20);
        defer grid.deinit(gpa);
        var rng = testgen.Rng.init(seed ^ 0xdec);
        for (&caps) |*c| c.* = 5.0 * rng.unit();
        for (&peaks, grid.node_load.items) |*p, l| p.* = l.raw;
        try respond(&grid, &peaks, 40.0, &zeros, 400.0, &free);
        var scale: f64 = 0.0;
        for (free) |f| scale = @max(scale, @abs(f));
        try respond(&grid, &peaks, 40.0, &caps, 400.0, &held);
        for (held, free) |h, f| try testing.expect(h <= f + 1e-9 * scale);
    }
    var grid = try common.seriesChain(1, 1.0, 1_800.0, 0.0);
    defer grid.deinit(gpa);
    var last = std.math.inf(f64);
    for ([_]f64{ 0.0, 1.0, 10.0, 100.0, 1000.0 }) |cap| {
        var got: [2]f64 = undefined;
        try respond(&grid, &.{ 0.0, 1000.0 }, 100.0, &.{ 0.0, cap }, 1000.0, &got);
        try testing.expect(got[1] < last);
        last = got[1];
    }
}

test "a stimulus the grid cannot take is refused" {
    // Oracle: construct-from-answer, against `transientInto`'s documented
    // errors: a negative or non-finite decap, a non-finite peak, a switching
    // node with no rise are refused naming the node; nothing switching
    // responds with zeros.
    var grid = try common.seriesChain(2, 1.0, 1_800.0, 0.0);
    defer grid.deinit(gpa);
    var scratch: erc.power_solve.SolveScratch = .{};
    defer scratch.deinit(gpa);
    var out: std.ArrayList(report.Millivolts) = .empty;
    defer out.deinit(gpa);
    var diag: erc.power_grid.PowerDiag = .{};
    const inf = std.math.inf(f64);
    const Case = struct { peak: [3]f64, rise: f64, cap: [3]f64 };
    for ([_]Case{
        .{ .peak = .{ 0, 1, 0 }, .rise = 10, .cap = .{ 0, -1, 0 } },
        .{ .peak = .{ 0, 1, 0 }, .rise = 10, .cap = .{ 0, std.math.nan(f64), 0 } },
        .{ .peak = .{ 0, inf, 0 }, .rise = 10, .cap = .{ 0, 0, 0 } },
        .{ .peak = .{ 0, 1, 0 }, .rise = 0, .cap = .{ 0, 0, 0 } },
    }) |c| {
        var s = try stimulus(&c.peak, c.rise, &c.cap, 100.0);
        defer s.deinit(gpa);
        try testing.expectError(error.NotFinite, erc.power_transient.transientInto(gpa, &grid, &s, &scratch, &out, &diag));
        try testing.expectEqual(@as(u32, 1), diag.at);
    }
    var quiet = try stimulus(&.{ 0, 0, 0 }, 10.0, &.{ 1, 1, 1 }, 100.0);
    defer quiet.deinit(gpa);
    try erc.power_transient.transientInto(gpa, &grid, &quiet, &scratch, &out, &diag);
    for (out.items) |v| try testing.expectEqual(@as(f64, 0.0), v.raw);
}

test "dynamic ir drop is the static drop plus the worst cycle" {
    // Oracle: closed form. One load of 1 mA behind 1 Ω: static drop 1 mV;
    // one event carries `Q = 1000 µA × 4000 ps` as a 100 ps triangle
    // peaking at `2 Q / 100 ps = 80 mA`: 80 mV without decap, 81 mV in all;
    // with 10 pF the recurrence's peak plus 1 mV. On a ground rail the same
    // numbers are a rise. A limit a part in a million under flags the
    // load's node with that drop; one over passes.
    const id = common.rule(40);
    var t: el.DynamicIrDropTable = .{ .head = try common.head(id) };
    defer erc.rule_set.deinitTable(gpa, &t);
    for ([_][2]f64{ .{ 0.0, 80.0 }, .{ 10.0, recurrencePeak(1.0, 10.0, 80_000.0, 100.0) } }) |c| {
        const total = 1.0 + c[1];
        for ([_]bool{ false, true }) |ground| {
            var grid = try common.seriesChain(1, 1.0, if (ground) 0.0 else 1_800.0, if (ground) -1000.0 else 1000.0);
            defer grid.deinit(gpa);
            var solution = try common.solve(&grid);
            defer solution.deinit(gpa);
            for ([_]struct { f64, bool }{ .{ 1.0 - 1e-6, true }, .{ 1.0 + 1e-6, false } }) |f| {
                var intent = try switchingIntent(if (ground) 1 else 0, if (ground) 0 else 1, 1000.0, c[0], total * f[0]);
                defer intent.deinit(gpa);
                var scratch: erc.scratch.Scratch = .{};
                defer scratch.deinit(gpa);
                var sink: common.Sink = .{};
                defer sink.deinit();
                try erc.electrical.checkDynamicIrDrop(sink.record(), .{ .solved = .{ .grid = &grid, .solution = &solution } }, &intent, &t, &scratch);
                const r = try common.runOf(sink.runs.items, id);
                try testing.expectEqual(report.Outcome.ran, r.outcome);
                try testing.expectEqual(@as(u64, 2), r.examined);
                try testing.expectEqual(@as(u32, @intFromBool(f[1])), sink.out.len());
                if (f[1]) {
                    try testgen.assertCloseRelative("the dynamic drop", sink.out.get(0).measured.float(), total, 1e-9);
                    try testing.expectEqual(grid.node_poly.items[1], sink.out.shape_a.items[0]);
                }
            }
        }
    }
}

test "self heating raises a wire by its power times its thermal resistance" {
    // Oracle: closed form, Banerjee et al. (DAC 1999) eqs. 8 and 10 with
    // eq. 14's spreading. A 1 µm × 1 µm segment of 1 Ω, 1 µm above the
    // substrate, carries 10 mA: `P = I² R = 1e-4 W`,
    // `θ = 1e-6 / (1 × 1e-6 × 1.88e-6)` K/W, `ΔT = P θ = 53.19 K` above the
    // 85 °C run; its limit 100 A/m × 1 µm derated by Black's equation to
    // that temperature; the cut beyond it takes the same rise.
    var b: common.GridBuilder = .{};
    defer b.grid.deinit(gpa);
    _ = try b.node(0, 1_800.0, 0.0);
    _ = try b.node(1_000, 1_800.0, 0.0);
    _ = try b.node(2_000, 1_800.0, 10_000.0);
    try b.pad(0, 1_800.0);
    try b.edge(0, 1, 1.0);
    try b.edgeOn(@fromBackingInt(1), 1, 2, 0.5);
    b.grid.edge_kind.items[1] = .via;
    const id = common.rule(41);
    var t = try thermalTable(id, &.{ @fromBackingInt(0), @fromBackingInt(1) }, 100.0, 50.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runThermal(&sink, &b.grid, &t, 358.15, &.{1_000.0});
    const rise = 1e-4 * 1e-6 / (1.0 * 1e-6 * (1e-6 + 0.88 * 1e-6));
    const hot = black(358.15 + rise);
    try testing.expectEqual(@as(u64, 2), (try common.runOf(sink.runs.items, id)).examined);
    try testing.expectEqual(@as(u32, 2), sink.out.len());
    try testgen.assertCloseRelative("the segment's limit", sink.out.get(0).limit.float(), 100.0 * hot, 1e-12);
    try testgen.assertCloseRelative("the cut's limit", sink.out.get(1).limit.float(), 50.0 * hot, 1e-12);
    try testgen.assertCloseRelative("the current", sink.out.get(0).measured.float(), 10_000.0, 1e-9);
}

test "black's equation holds between two temperatures" {
    // Oracle: closed form, Black's equation held at equal lifetime: with no
    // self-heating the limit at T is `J W exp(Ea / (n k) (1/T - 1/T_ref))`;
    // the limits at 85 and 125 °C stand in that ratio, and each is
    // `electromigration`'s limit for the same row, bit for bit. A row with
    // sigma 0 is refused.
    var grid = try common.seriesChain(1, 1.0, 1_800.0, 5_000.0);
    defer grid.deinit(gpa);
    const id = common.rule(42);
    var t = try thermalTable(id, &.{@fromBackingInt(0)}, 100.0, 50.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    var limits: [2]f64 = undefined;
    for ([_]f64{ 358.15, 398.15 }, 0..) |kelvin, k| {
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runThermal(&sink, &grid, &t, kelvin, &.{});
        const limit = sink.out.get(0).limit.float();
        try testgen.assertCloseRelative("the derated limit", limit, 100.0 * black(kelvin), 1e-12);
        var em: el.ElectromigrationTable = .{ .head = try common.head(id) };
        defer erc.rule_set.deinitTable(gpa, &em);
        try em.layer_start.appendSlice(gpa, &.{ 0, 1 });
        try em.layer.append(gpa, @fromBackingInt(0));
        try em.max_density.append(gpa, .{ .raw = 100.0 });
        try em.max_current_per_cut.append(gpa, .{ .raw = 50.0 });
        try em.blech_limit.append(gpa, .{ .raw = 1e-6 });
        try em.reference_temperature.append(gpa, .{ .raw = 378.15 });
        try em.activation_energy_ev.append(gpa, 0.9);
        try em.current_exponent.append(gpa, 2.0);
        var solution = try common.solve(&grid);
        defer solution.deinit(gpa);
        var intent = try common.declaredSupplies(@fromBackingInt(0), @fromBackingInt(1), 1_800.0);
        defer intent.deinit(gpa);
        var s2: common.Sink = .{};
        defer s2.deinit();
        try erc.electrical.checkElectromigration(s2.record(), .{ .solved = .{ .grid = &grid, .solution = &solution } }, &intent, common.manufacturingGrid(), .{ .raw = kelvin }, &em);
        try testing.expectEqual(@as(u64, @bitCast(limit)), @as(u64, @bitCast(s2.out.get(0).limit.float())));
        limits[k] = limit;
    }
    try testgen.assertCloseRelative("the ratio of the limits", limits[0] / limits[1], @exp(0.9 / (2.0 * k_ev) * (1.0 / 358.15 - 1.0 / 398.15)), 1e-12);
    t.sigma.items[0] = 0.0;
    var sink: common.Sink = .{};
    defer sink.deinit();
    try runThermal(&sink, &grid, &t, 358.15, &.{});
    try testing.expectEqual(report.Outcome.refused, (try common.runOf(sink.runs.items, id)).outcome);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
}

test "the chip fails when any lognormal wire does" {
    // Oracle: standard tables and the weakest link. With the limit at 2.5 %
    // failed (z = -1.959963984540054) and σ = 2 ln 0.5 / (z_0.1% - z_2.5%), a
    // wire at half its limit sits at z_0.1% = -3.090232306167813: it fails
    // with probability 0.1 %. Three in parallel fail together with
    // 1 - 0.999³ = 0.002997001 (Kitchin): a budget a part in a million under
    // flags the chip once at that probability; one over passes.
    const z_limit = -1.959_963_984_540_054;
    const z_wire = -3.090_232_306_167_813;
    var grid = try common.parallelBundle(3, 1.0, 1_800.0, 3_000.0);
    defer grid.deinit(gpa);
    const id = common.rule(43);
    var t = try thermalTable(id, &.{@fromBackingInt(0)}, 2_000.0, 50.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    t.sigma.items[0] = 2.0 * @log(0.5) / (z_wire - z_limit);
    t.limit_failure.items[0] = 0.025;
    const chip = 1.0 - std.math.pow(f64, 0.999, 3);
    for ([_]struct { f64, bool }{ .{ 1.0 - 1e-6, true }, .{ 1.0 + 1e-6, false } }) |c| {
        t.max_failure.items[0] = chip * c[0];
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runThermal(&sink, &grid, &t, 378.15, &.{});
        try testing.expectEqual(@as(u64, 3), (try common.runOf(sink.runs.items, id)).examined);
        try testing.expectEqual(@as(u32, @intFromBool(c[1])), sink.out.len());
        if (c[1]) try testgen.assertCloseRelative("the chip's failure probability", sink.out.get(0).measured.float(), chip, 1e-9);
    }
}

test "a hotter run or more current never clears a wire" {
    // Oracle: law. A wire is flagged when `I > J W derate(T_run + a I²)`:
    // the left side grows with the current, the right falls with the current
    // and the run temperature, and a wire's failure probability rises with
    // `I / allowed`; so a hotter run, or every load half again, flags every
    // wire flagged before and leaves the chip no less likely to fail.
    const id = common.rule(44);
    var t = try thermalTable(id, &.{@fromBackingInt(0)}, 300.0, 50.0);
    defer erc.rule_set.deinitTable(gpa, &t);
    t.max_failure.items[0] = 1e-300;
    var base: std.ArrayList([2]i64) = .empty;
    defer base.deinit(gpa);
    var hot: std.ArrayList([2]i64) = .empty;
    defer hot.deinit(gpa);
    var more: std.ArrayList([2]i64) = .empty;
    defer more.deinit(gpa);
    for (1..7) |seed| {
        var grid = try common.randomGrid(seed, 20, 10);
        defer grid.deinit(gpa);
        var s1: common.Sink = .{};
        defer s1.deinit();
        try runThermal(&s1, &grid, &t, 358.15, &.{500.0});
        const base_chip = try findingsInto(&s1.out, &base);
        var s2: common.Sink = .{};
        defer s2.deinit();
        try runThermal(&s2, &grid, &t, 398.15, &.{500.0});
        const hot_chip = try findingsInto(&s2.out, &hot);
        for (grid.node_load.items) |*l| l.* = .{ .raw = 1.5 * l.raw };
        var s3: common.Sink = .{};
        defer s3.deinit();
        try runThermal(&s3, &grid, &t, 358.15, &.{500.0});
        const more_chip = try findingsInto(&s3.out, &more);
        for (base.items) |w| {
            var in_hot = false;
            for (hot.items) |h| in_hot = in_hot or std.mem.eql(i64, &h, &w);
            var in_more = false;
            for (more.items) |m| in_more = in_more or std.mem.eql(i64, &m, &w);
            try testing.expect(in_hot and in_more);
        }
        try testing.expect(hot_chip >= base_chip and more_chip >= base_chip);
    }
}

test "em thermal runs exactly on the documented domain of each parameter" {
    // Oracle: the documented domains, construct-from-answer: each row
    // differs from the legal table in one value, one step either side of
    // its bound (sigma and conductivity finite positive, spreading finite
    // and zero or more, limit_failure in (0, 1), max_failure in (0, 1], a
    // reference above 0 K, activation zero or more, a finite positive
    // exponent).
    var grid = try common.seriesChain(2, 1.0, 1_800.0, 500.0);
    defer grid.deinit(gpa);
    const id = common.rule(44);
    const inf = std.math.inf(f64);
    const Field = enum { none, sigma, conductivity, spreading, limit_failure, max_failure, reference, exponent, activation };
    const Case = struct { field: Field, value: f64, want: report.Outcome };
    const cases = [_]Case{
        .{ .field = .none, .value = 0, .want = .ran },
        .{ .field = .sigma, .value = 0.0, .want = .refused },
        .{ .field = .sigma, .value = std.math.nan(f64), .want = .refused },
        .{ .field = .sigma, .value = inf, .want = .refused },
        .{ .field = .conductivity, .value = 0.0, .want = .refused },
        .{ .field = .conductivity, .value = inf, .want = .refused },
        .{ .field = .spreading, .value = 0.0, .want = .ran },
        .{ .field = .spreading, .value = -0.01, .want = .refused },
        .{ .field = .spreading, .value = inf, .want = .refused },
        .{ .field = .limit_failure, .value = 0.0, .want = .refused },
        .{ .field = .limit_failure, .value = 1.0, .want = .refused },
        .{ .field = .max_failure, .value = 0.0, .want = .refused },
        .{ .field = .max_failure, .value = 1.0, .want = .ran },
        .{ .field = .max_failure, .value = 1.01, .want = .refused },
        .{ .field = .reference, .value = 0.0, .want = .refused },
        .{ .field = .exponent, .value = 0.0, .want = .refused },
        .{ .field = .exponent, .value = inf, .want = .refused },
        .{ .field = .activation, .value = 0.0, .want = .ran },
        .{ .field = .activation, .value = -0.01, .want = .refused },
    };
    for (cases) |c| {
        var t = try thermalTable(id, &.{@fromBackingInt(0)}, 1e9, 1e9);
        defer erc.rule_set.deinitTable(gpa, &t);
        t.max_failure.items[0] = 0.5;
        switch (c.field) {
            .none => {},
            .sigma => t.sigma.items[0] = c.value,
            .conductivity => t.thermal_conductivity.items[0] = c.value,
            .spreading => t.heat_spreading.items[0] = c.value,
            .limit_failure => t.limit_failure.items[0] = c.value,
            .max_failure => t.max_failure.items[0] = c.value,
            .reference => t.reference_temperature.items[0] = .{ .raw = c.value },
            .exponent => t.current_exponent.items[0] = c.value,
            .activation => t.activation_energy_ev.items[0] = c.value,
        }
        var sink: common.Sink = .{};
        defer sink.deinit();
        try runThermal(&sink, &grid, &t, 358.15, &.{});
        try testing.expectEqual(c.want, (try common.runOf(sink.runs.items, id)).outcome);
        if (c.want == .refused) try testing.expectEqual(@as(u32, 0), sink.out.len());
    }
}
