//! Characterization, the delay half: one corner's bench → the pin waveforms
//! a case's vectors make, the commands that drive them, and one slew row of
//! a delay case's delay, transition and energy tables. Ported from
//! src/liberty/measure.rs (`Effort`, `Bench`, `rails`, `prepare`, `drive`,
//! `tran`, `merged`, `set`, `ramp_to`, `unmeasured_leakage`, `input_edge`,
//! `energy_supplies`, `delay_row`); pin capacitance and leakage are
//! measure_static.zig, setup and hold measure_constraint.zig.
//!
//! Conventions are `sky130_fd_sc_hd`'s: delay from the related pin's
//! `input_threshold_pct` crossing to the output's `output_threshold_pct`
//! crossing; transition `slew_lower_pct` to `slew_upper_pct`, not derated;
//! an input transition `s` a linear ramp whose full swing takes
//! `s / (upper − lower)`; internal energy the supply energy over the edge and
//! its settling, less the static power over that window, less `½·C·V²`. A
//! measurement the simulator could not make is an error naming the arc, case
//! and point, never a zero.
//!
//! Contents:
//! - `pub const Effort = struct { max_step, resolution }`
//! - `pub const Pwl = std.ArrayList([2]f64)`
//! - `pub const Bench = struct`, `rails`, `volts`, `threshold`, `ramp`, `prepare`, `drive`, `tran`, `fail`, `energySupplies`
//! - `pub const Row = struct { delay, transition, energy: []f64 }`
//! - `pub fn delayRow(bench: *const Bench, session: *Session, scratch: Allocator, arc: ArcSpec, case: CaseSpec, row: usize, label: []const u8, out: Row, diag: *Diagnostic) Error!void`
//! - `pub fn merged(scratch: Allocator, sequence: []const Vector) Allocator.Error!Vector`
//! - `pub fn set(scratch: Allocator, wave: *Pwl, t: f64, v: f64) Allocator.Error!void`
//! - `pub fn rampTo(scratch: Allocator, wave: *Pwl, t: f64, ramp: f64, v: f64) Allocator.Error!void`
//! - `pub fn value(wave: Pwl) f64`
//! - `pub fn unmeasuredLeakage(scratch: Allocator, k: usize, state: []const Vector) Allocator.Error![]const u8`
//! - `pub fn inputEdge(arc: ArcSpec, case: CaseSpec) Edge`
//! - `pub const prep_ramp: f64`
//! - `pub const Supply = struct { pin, volts }`, `format`: the message formatter's hook

const std = @import("std");
const Allocator = std.mem.Allocator;
const float = @import("geom").float;
const spec = @import("spec.zig");
const MacroSpec = spec.MacroSpec;
const CornerSpec = spec.CornerSpec;
const ArcSpec = spec.ArcSpec;
const CaseSpec = spec.CaseSpec;
const Edge = spec.Edge;
const Level = spec.Level;
const Vector = spec.Vector;
const Diagnostic = spec.Diagnostic;
const fmtSi = @import("spice.zig").fmtSi;
const session_ = @import("session.zig");
const Session = session_.Session;
const Error = session_.Error;
const need = session_.need;

/// How hard each transient works.
pub const Effort = struct {
    /// The largest step, s; within it the step follows the truncation error.
    max_step: f64,
    /// Bisection stops below this, s.
    resolution: f64,
};

/// A pin's drive over time: `(t, v)` points.
pub const Pwl = std.ArrayList([2]f64);

/// Time a preparation vector's ramp takes, s.
pub const prep_ramp: f64 = 50e-12;

/// One corner's measurement context. Every measurement runs on a session
/// with this corner's deck loaded from the same spec, so pin `i` is node
/// `p<i>`, driven by `vp<i>`, loaded by `cp<i>`.
pub const Bench = struct {
    /// As `spec.parse` validated it: names and case shapes are trusted.
    macro: *const MacroSpec,
    corner: *const CornerSpec,
    effort: Effort,
    /// The deck's `reltol`, restored after a relaxed retry.
    reltol: f64,

    /// Pin `i`'s low and high rail voltages.
    pub fn rails(bench: *const Bench, i: usize) [2]f64 {
        const pin = bench.macro.pins[i];
        return .{ bench.supply(pin.ground), bench.supply(pin.power) };
    }

    pub fn volts(bench: *const Bench, i: usize, level: Level) f64 {
        return switch (level) {
            .low => bench.rails(i)[0],
            .high => bench.rails(i)[1],
            .volts => |v| v,
        };
    }

    /// `pct` percent of the way up pin `i`'s swing.
    pub fn threshold(bench: *const Bench, i: usize, pct: f64) f64 {
        const r = bench.rails(i);
        return r[0] + pct / 100.0 * (r[1] - r[0]);
    }

    /// The full-swing ramp time of a `slew_ns` transition, s.
    pub fn ramp(bench: *const Bench, slew_ns: f64) f64 {
        const c = bench.macro.characterization;
        return slew_ns * 1e-9 / ((c.slew_upper_pct - c.slew_lower_pct) / 100.0);
    }

    /// Every driven pin's waveform through `vectors` (null for an undriven
    /// pin; an analog pin sits at its bias), and the time they end.
    pub fn prepare(bench: *const Bench, scratch: Allocator, vectors: []const Vector) Allocator.Error!struct { []?Pwl, f64 } {
        const pins = bench.macro.pins;
        const period = bench.macro.characterization.vector_ns * 1e-9;
        const waves = try scratch.alloc(?Pwl, pins.len);
        for (pins, waves) |pin, *wave| wave.* = switch (pin.role) {
            .input, .clock => .empty,
            .analog => blk: {
                var w: Pwl = .empty;
                try w.append(scratch, .{ 0.0, pin.bias orelse 0.0 });
                break :blk w;
            },
            .power, .ground, .nwell, .pwell, .output => null,
        };
        for (vectors, 0..) |vector, k| {
            const t = @as(f64, @floatFromInt(k)) * period;
            for (vector.names, vector.values) |name, level| {
                const i = bench.macro.pinIndex(name).?;
                try set(scratch, &waves[i].?, t, bench.volts(i, level));
            }
        }
        return .{ waves, @as(f64, @floatFromInt(vectors.len)) * period };
    }

    /// The commands that load `waves`, and every output's load: `load_on`
    /// on its pin, 1 aF on the rest.
    pub fn drive(bench: *const Bench, scratch: Allocator, waves: []const ?Pwl, load_on: ?struct { usize, f64 }, out: *std.ArrayList(u8)) Allocator.Error!void {
        for (waves, 0..) |wave, i| if (wave) |points| {
            try out.print(scratch, "alter @vp{d}[pwl] = [", .{i});
            if (points.items.len == 0) try out.appendSlice(scratch, " 0 0");
            for (points.items) |p| try out.print(scratch, " {f} {f}", .{ fmtSi(p[0]), fmtSi(p[1]) });
            try out.appendSlice(scratch, " ]\n");
        };
        for (bench.macro.pins, 0..) |pin, i| if (pin.role == .output) {
            const c = if (load_on) |l| (if (l[0] == i) l[1] else 1e-18) else 1e-18;
            try out.print(scratch, "alter cp{d} = {f}\n", .{ i, fmtSi(c) });
        };
    }

    /// A transient to a little past `stop`, so a measurement at `stop` is
    /// inside the simulated interval however the last step rounds.
    pub fn tran(bench: *const Bench, scratch: Allocator, stop: f64, out: *std.ArrayList(u8)) Allocator.Error!void {
        const step = bench.effort.max_step;
        try out.print(scratch, "tran {f} {f} 0 {f}\n", .{ fmtSi(step), fmtSi(stop + 4.0 * step), fmtSi(step) });
    }

    /// A `Measure` error: `corner <name>: <why>`.
    pub fn fail(bench: *const Bench, scratch: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
        diag.message = try scratch.print("corner {s}: " ++ fmt, .{bench.corner.name} ++ args);
        return error.Measure;
    }

    /// Supplies whose energy counts: every supply above ground, `(pin, V)`.
    pub fn energySupplies(bench: *const Bench, scratch: Allocator) Allocator.Error![]const Supply {
        var out: std.ArrayList(Supply) = .empty;
        for (bench.macro.pins, 0..) |pin, i| if (pin.role.isSupply()) {
            const v = bench.corner.supplies.get(pin.name).?;
            if (v != 0.0) try out.append(scratch, .{ .pin = i, .volts = v });
        };
        return out.items;
    }

    fn supply(bench: *const Bench, name: ?[]const u8) f64 {
        return if (name) |n| bench.corner.supplies.get(n).? else 0.0;
    }
};

/// A supply pin and its voltage.
pub const Supply = struct { pin: usize, volts: f64 };

/// One input-slew row of a delay case's tables, one value per load:
/// delay ns, output transition ns, internal energy pJ.
pub const Row = struct { delay: []f64, transition: []f64, energy: []f64 };

/// Rust's `{}` of an `f64`, for a message.
const Display = struct {
    v: f64,
    pub fn format(d: Display, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return float.display(w, d.v);
    }
};

/// Measures row `row` of a delay case: input slew `slews_ns[row]` into every
/// load, one transient per load, in one batch. `Measure` when the vectors
/// already leave the related pin where its edge goes, when the output does
/// not make its edge within `settle_ns`, never completes its swing, or a
/// supply's charge was not measured.
pub fn delayRow(bench: *const Bench, session: *Session, scratch: Allocator, arc: ArcSpec, case: CaseSpec, row: usize, label: []const u8, out: Row, diag: *Diagnostic) Error!void {
    const macro = bench.macro;
    const c = macro.characterization;
    const from = macro.pinIndex(arc.from).?;
    const to = macro.pinIndex(arc.to).?;
    const edge = inputEdge(arc, case);
    const output = case.output.?;
    const out_rails = bench.rails(to);
    const supplies = try bench.energySupplies(scratch);
    const slew = c.slews_ns[row];
    const ramp = bench.ramp(slew);
    const waves, const start = try bench.prepare(scratch, case.vectors);
    const from_wave = &waves[from].?;
    const target = bench.rails(from)[if (edge == .rise) 1 else 0];
    if (@abs(value(from_wave.*) - target) < 1e-9)
        return bench.fail(scratch, diag, "{s}: the vectors leave {s} already {s}, so it cannot {s}", .{ label, arc.from, if (edge == .rise) "high" else "low", @tagName(edge) });
    const t_edge = start + c.vector_ns * 1e-9;
    try rampTo(scratch, from_wave, t_edge, ramp, target);
    const stop = t_edge + ramp + c.settle_ns * 1e-9;
    const window = stop - t_edge;
    const vin = bench.threshold(from, c.input_threshold_pct);
    const vout = bench.threshold(to, c.output_threshold_pct);
    const v_lo = bench.threshold(to, c.slew_lower_pct);
    const v_hi = bench.threshold(to, c.slew_upper_pct);
    const td = fmtSi(t_edge);
    var commands: std.ArrayList(u8) = .empty;
    for (c.loads_pf, 0..) |load, li| {
        try bench.drive(scratch, waves, .{ to, load * 1e-12 }, &commands);
        try bench.tran(scratch, stop, &commands);
        try commands.print(scratch, "meas tran d TRIG v(p{d}) VAL={f} TD={f} {s}=1 TARG v(p{d}) VAL={f} TD={f} {s}=1\n", .{ from, fmtSi(vin), td, riseFall(edge), to, fmtSi(vout), td, riseFall(output) });
        for ([_]struct { []const u8, f64 }{ .{ "tlo", v_lo }, .{ "thi", v_hi } }) |m|
            try commands.print(scratch, "meas tran {s} WHEN v(p{d})={f} TD={f} {s}=1\n", .{ m[0], to, fmtSi(m[1]), td, riseFall(output) });
        for (supplies) |s| {
            try commands.print(scratch, "meas tran q{d} INTEG i(vp{d}) FROM={f} TO={f}\n", .{ s.pin, s.pin, td, fmtSi(stop) });
            try commands.print(scratch, "meas tran i{d} AVG i(vp{d}) FROM={f} TO={f}\n", .{ s.pin, s.pin, fmtSi(stop - 0.05 * window), fmtSi(stop) });
        }
        try commands.print(scratch, "echo \"RES d{d}_{d} $&d\"\necho \"RES lo{d}_{d} $&tlo\"\necho \"RES hi{d}_{d} $&thi\"\n", .{ row, li, row, li, row, li });
        for (supplies) |s| try commands.print(scratch, "echo \"RES q{d}_{d}_{d} $&q{d}\"\necho \"RES i{d}_{d}_{d} $&i{d}\"\n", .{ s.pin, row, li, s.pin, s.pin, row, li, s.pin });
        try commands.appendSlice(scratch, "destroy all\n");
    }
    const results = try session.run(scratch, commands.items, diag);
    for (c.loads_pf, 0..) |load, li| {
        const at = try scratch.print("{s} at slew {f} ns, load {f} pF", .{ label, Display{ .v = slew }, Display{ .v = load } });
        const delay = need(&results, try scratch.print("d{d}_{d}", .{ row, li })) orelse
            return bench.fail(scratch, diag, "{s}: {s} did not {s} within {f} ns of the edge (characterization.settle_ns, if it is only slow)", .{ at, arc.to, @tagName(output), Display{ .v = c.settle_ns } });
        const lo = need(&results, try scratch.print("lo{d}_{d}", .{ row, li }));
        const hi = need(&results, try scratch.print("hi{d}_{d}", .{ row, li }));
        if (lo == null or hi == null)
            return bench.fail(scratch, diag, "{s}: {s} never completed its swing after the edge; if it was still moving when the edge came, the preparation vectors need longer (characterization.vector_ns)", .{ at, arc.to });
        var energy: f64 = 0.0;
        for (supplies) |s| {
            const q = need(&results, try scratch.print("q{d}_{d}_{d}", .{ s.pin, row, li }));
            const i = need(&results, try scratch.print("i{d}_{d}_{d}", .{ s.pin, row, li }));
            if (q == null or i == null) return bench.fail(scratch, diag, "{s}: supply charge was not measured", .{at});
            // Delivered charge is minus the current into the source.
            energy += s.volts * (-q.? + i.? * window);
        }
        const swing = out_rails[1] - out_rails[0];
        const switching = 0.5 * load * 1e-12 * swing * swing;
        out.delay[li] = delay * 1e9;
        out.transition[li] = @abs(hi.? - lo.?) * 1e9;
        out.energy[li] = (energy - switching) * 1e12;
    }
}

/// A sequence's final value of every pin it names.
pub fn merged(scratch: Allocator, sequence: []const Vector) Allocator.Error!Vector {
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(Level) = .empty;
    for (sequence) |vector| for (vector.names, vector.values) |name, level| {
        const at = std.sort.lowerBound([]const u8, names.items, name, orderStr);
        if (at < names.items.len and std.mem.eql(u8, names.items[at], name)) {
            values.items[at] = level;
        } else {
            try names.insert(scratch, at, name);
            try values.insert(scratch, at, level);
        }
    };
    return .{ .names = names.items, .values = values.items };
}

/// Holds `wave` at its value until `t`, then ramps to `v` over `prep_ramp`;
/// a wave's first point is its value from time zero, and a repeat adds none.
pub fn set(scratch: Allocator, wave: *Pwl, t: f64, v: f64) Allocator.Error!void {
    if (wave.items.len == 0) return wave.append(scratch, .{ 0.0, v });
    const last = wave.items[wave.items.len - 1];
    if (@abs(last[1] - v) < 1e-12) return;
    if (t > last[0]) try wave.append(scratch, .{ t, last[1] });
    try wave.append(scratch, .{ @max(t, last[0]) + prep_ramp, v });
}

/// A ramp from the wave's last value to `v`, from `t`, taking `ramp`.
pub fn rampTo(scratch: Allocator, wave: *Pwl, t: f64, ramp: f64, v: f64) Allocator.Error!void {
    const last = wave.items[wave.items.len - 1];
    std.debug.assert(t > last[0]);
    try wave.append(scratch, .{ t, last[1] });
    try wave.append(scratch, .{ t + ramp, v });
}

pub fn value(wave: Pwl) f64 {
    return if (wave.items.len == 0) 0.0 else wave.items[wave.items.len - 1][1];
}

/// Why leakage state `k` has no supply current: the analysis it is read from
/// did not converge, a DC operating point for one vector, a transient for a
/// sequence.
pub fn unmeasuredLeakage(scratch: Allocator, k: usize, state: []const Vector) Allocator.Error![]const u8 {
    if (state.len == 1) return scratch.print("the DC operating point of leakage state {d} did not converge", .{k});
    return scratch.print("the transient of leakage state {d} did not converge", .{k});
}

/// The related pin's edge in a case: the clock edge of a clocked arc, else
/// the case's own `edge`.
pub fn inputEdge(arc: ArcSpec, case: CaseSpec) Edge {
    return arc.kind.clockEdge() orelse case.edge.?;
}

// ---- private ----

fn riseFall(edge: Edge) []const u8 {
    return switch (edge) {
        .rise => "RISE",
        .fall => "FALL",
    };
}

fn orderStr(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

test "a missing leakage names the analysis it came from" {
    // Oracle: `docs/liberty.md`, Leakage: "A one-vector state is a DC
    // operating point. A sequence is simulated", so each message names its
    // own analysis (F35: it always blamed the operating point).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vector: Vector = .{};
    const dc = try unmeasuredLeakage(a, 0, &.{vector});
    try std.testing.expect(std.mem.indexOf(u8, dc, "DC operating point") != null);
    const sequence = try unmeasuredLeakage(a, 1, &.{ vector, vector });
    try std.testing.expect(std.mem.indexOf(u8, sequence, "transient") != null and std.mem.indexOf(u8, sequence, "operating point") == null);
}

test "a wave holds then ramps and skips a repeat" {
    // Oracle: hand-derived from `set`'s doc: the first point is the value
    // from time zero, a change at 2 ns holds 0 until then and reaches 1.8
    // `prep_ramp` later, and setting 1.8 again adds no point.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wave: Pwl = .empty;
    try set(a, &wave, 0.0, 0.0);
    try set(a, &wave, 2e-9, 1.8);
    try set(a, &wave, 4e-9, 1.8);
    try std.testing.expectEqualSlices([2]f64, &.{ .{ 0.0, 0.0 }, .{ 2e-9, 0.0 }, .{ 2e-9 + prep_ramp, 1.8 } }, wave.items);
}
