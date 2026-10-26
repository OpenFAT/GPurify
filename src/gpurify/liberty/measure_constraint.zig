//! Characterization, the clocked half: a bench and a session → one setup or
//! hold table point by bisection over data-to-clock offsets, the Monte
//! Carlo redraw, and the per-point sample sigma. Ported from
//! src/liberty/measure.rs (`constraint_point`, `constraint_trial`, `Trial`,
//! `redraw`, `sigma`).
//!
//! The offset is between the midpoints of the clock and data ramps, the
//! data edge that far before the clock for setup, after it for hold. A trial
//! passes when the check pin ends on the side of its `output_threshold_pct`
//! of the value it should capture, and its clock-to-check delay stays within
//! `pushout_pct` of the delay with the data a whole `constraint_window_ns`
//! clear. The result is the smallest passing offset in the window, found by
//! bisection to `Effort.resolution` and taken from the passing end:
//! pessimistic by at most that, never optimistic. A transient that does not
//! finish (a latch caught metastable) is retried at `reltol = 1e-3`, then
//! counted a failed capture, which can only lengthen the constraint.
//!
//! Contents:
//! - `pub fn constraintPoint(bench: *const Bench, session: *Session, scratch: Allocator, arc: ArcSpec, case: CaseSpec, clock_slew: f64, data_slew: f64, label: []const u8, diag: *Diagnostic) Error!f64`
//! - `pub fn redraw(session: *Session, scratch: Allocator, sample: u32, diag: *Diagnostic) Error!void`
//! - `pub fn sigmaInto(samples: []const []const f64, out: []f64) void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const float = @import("geom").float;
const spec = @import("spec.zig");
const ArcSpec = spec.ArcSpec;
const CaseSpec = spec.CaseSpec;
const Edge = spec.Edge;
const Diagnostic = spec.Diagnostic;
const fmtSi = @import("spice.zig").fmtSi;
const session_ = @import("session.zig");
const Session = session_.Session;
const Error = session_.Error;
const need = session_.need;
const measure = @import("measure.zig");
const Bench = measure.Bench;

/// Setup or hold of one constraint case at one table point, ns: clock
/// transition `clock_slew` and data transition `data_slew`, both ns. A
/// capture passing even at `-constraint_window_ns` returns that bound.
/// `Measure` when the capture fails even with the data a whole window clear.
pub fn constraintPoint(bench: *const Bench, session: *Session, scratch: Allocator, arc: ArcSpec, case: CaseSpec, clock_slew: f64, data_slew: f64, label: []const u8, diag: *Diagnostic) Error!f64 {
    const c = bench.macro.characterization;
    const window = c.constraint_window_ns * 1e-9;
    const reference = switch (try trial(bench, session, scratch, arc, case, clock_slew, data_slew, window, diag)) {
        .pass => |delay| delay,
        .fail => return bench.fail(scratch, diag, "{s} at clock {f} ns, data {f} ns: the check fails even with the data {f} ns clear of the clock, so the case describes no capture", .{ label, Display{ .v = clock_slew }, Display{ .v = data_slew }, Display{ .v = c.constraint_window_ns } }),
    };
    const limit = 1.0 + c.pushout_pct / 100.0;
    var lo = -window;
    var hi = window;
    if (passes(try trial(bench, session, scratch, arc, case, clock_slew, data_slew, lo, diag), reference, limit)) return lo * 1e9;
    while (hi - lo > bench.effort.resolution) {
        const mid = 0.5 * (lo + hi);
        if (passes(try trial(bench, session, scratch, arc, case, clock_slew, data_slew, mid, diag), reference, limit)) hi = mid else lo = mid;
    }
    return hi * 1e9;
}

/// Monte Carlo prologue: redraws every statistical parameter, seeding the
/// simulator with `sample + 1` so a sample number names one draw.
pub fn redraw(session: *Session, scratch: Allocator, sample: u32, diag: *Diagnostic) Error!void {
    _ = try session.run(scratch, try scratch.print("setseed {d}\nreset\n", .{sample + 1}), diag);
}

/// The sample standard deviation (divisor `n − 1`) of each column across
/// `samples` into `out`; fewer than two samples give zeros.
pub fn sigmaInto(samples: []const []const f64, out: []f64) void {
    if (samples.len < 2) return @memset(out, 0.0);
    const n: f64 = @floatFromInt(samples.len);
    for (out, 0..) |*s, k| {
        var sum: f64 = 0.0;
        for (samples) |row| sum += row[k];
        const mean = sum / n;
        var squares: f64 = 0.0;
        for (samples) |row| squares += (row[k] - mean) * (row[k] - mean);
        s.* = @sqrt(squares / (n - 1.0));
    }
}

// ---- private ----

/// A trial's outcome: failed, or passed with the clock-to-check delay (null
/// when the check pin did not move after the clock).
const Trial = union(enum) { fail, pass: ?f64 };

/// Rust's `{}` of an `f64`, for a message.
const Display = struct {
    v: f64,
    pub fn format(d: Display, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return float.display(w, d.v);
    }
};

fn passes(t: Trial, reference: ?f64, limit: f64) bool {
    return switch (t) {
        .fail => false,
        .pass => |delay| if (reference) |r| (if (delay) |d| d <= r * limit else false) else true,
    };
}

/// One trial: the data edge `tau` before (setup) or after (hold) the clock.
fn trial(bench: *const Bench, session: *Session, scratch: Allocator, arc: ArcSpec, case: CaseSpec, clock_slew: f64, data_slew: f64, tau: f64, diag: *Diagnostic) Error!Trial {
    const macro = bench.macro;
    const c = macro.characterization;
    const clock = macro.pinIndex(arc.from).?;
    const data = macro.pinIndex(arc.to).?;
    const check = case.check.?;
    const watch = macro.pinIndex(check.pin).?;
    const clock_ramp = bench.ramp(clock_slew);
    const data_ramp = bench.ramp(data_slew);
    const window = c.constraint_window_ns * 1e-9;
    const waves, const start = try bench.prepare(scratch, case.vectors);
    const clock_mid = start + c.vector_ns * 1e-9 + window + data_ramp + clock_ramp;
    const data_mid = if (arc.kind.isHold()) clock_mid + tau else clock_mid - tau;
    const clock_start = clock_mid - 0.5 * clock_ramp;
    const data_start = data_mid - 0.5 * data_ramp;
    // Two edges on the timeline, in time order (the clock first on a tie).
    const Step = struct { t: f64, pin: usize, ramp: f64, v: f64 };
    var edges = [2]Step{
        .{ .t = clock_start, .pin = clock, .ramp = clock_ramp, .v = target(bench, clock, arc.kind.clockEdge().?) },
        .{ .t = data_start, .pin = data, .ramp = data_ramp, .v = target(bench, data, case.data.?) },
    };
    if (edges[1].t < edges[0].t) std.mem.swap(Step, &edges[0], &edges[1]);
    for (edges) |e| try measure.rampTo(scratch, &waves[e.pin].?, e.t, e.ramp, e.v);
    const stop = clock_mid + window + c.settle_ns * 1e-9;
    var commands: std.ArrayList(u8) = .empty;
    try bench.drive(scratch, waves, null, &commands);
    try bench.tran(scratch, stop, &commands);
    const want = bench.volts(watch, check.value);
    const vth = bench.threshold(watch, c.output_threshold_pct);
    const rising = want > vth;
    try commands.print(scratch, "meas tran vend FIND v(p{d}) AT={f}\nmeas tran tchk WHEN v(p{d})={f} TD={f} {s}=LAST\necho \"RES v $&vend\"\necho \"RES t $&tchk\"\ndestroy all", .{ watch, fmtSi(stop), watch, fmtSi(vth), fmtSi(clock_start), if (rising) "RISE" else "FALL" });
    var results = try session.run(scratch, commands.items, diag);
    if (need(&results, "v") == null) {
        // Not finished: a latch at its metastable point. Retried looser.
        const relaxed = try scratch.print("option reltol=1e-3\n{s}option reltol={f}\n", .{ commands.items, fmtSi(bench.reltol) });
        results = try session.run(scratch, relaxed, diag);
    }
    const end = need(&results, "v") orelse return .fail;
    if ((end > vth) != rising) return .fail;
    return .{ .pass = if (need(&results, "t")) |t| t - clock_mid else null };
}

fn target(bench: *const Bench, i: usize, edge: Edge) f64 {
    return bench.rails(i)[if (edge == .rise) 1 else 0];
}

test "sigma is the sample standard deviation" {
    // Oracle: closed form. The sample standard deviation (n - 1) of {1, 3}
    // is sqrt(2), and of {5, 5} is 0.
    var s: [2]f64 = undefined;
    sigmaInto(&.{ &.{ 1.0, 5.0 }, &.{ 3.0, 5.0 } }, &s);
    try std.testing.expect(@abs(s[0] - @sqrt(2.0)) < 1e-12 and s[1] == 0.0);
}
