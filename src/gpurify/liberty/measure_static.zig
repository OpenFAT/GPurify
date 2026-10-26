//! Characterization, the static half: a bench and a session → a digital
//! input's charge-integrated rise and fall capacitance, an analog pin's
//! small-signal capacitance, and the static power of each leakage state.
//! Ported from src/liberty/measure.rs (`Cap`, `Context`, `contexts`,
//! `all_low`, `input_cap`, `analog_cap`, `leakage`).
//!
//! Pin capacitance, pF: the charge the pin's source delivers while the pin
//! swings, less the static current it drew before, over the swing; rise and
//! fall separately, averaged over every state the pin switches in
//! (integrating past the ramp would make them equal by charge conservation).
//! Leakage, nW: `V·I` summed over every supply.
//!
//! Contents:
//! - `pub const Cap = struct { rise, fall }`, `pub const Context = struct { vectors, edge }`
//! - `pub fn contexts(bench: *const Bench, scratch: Allocator, pin: []const u8) Allocator.Error![]const Context`
//! - `pub fn allLow(bench: *const Bench, scratch: Allocator) Allocator.Error!Vector`
//! - `pub fn inputCap(bench: *const Bench, session: *Session, scratch: Allocator, pin: []const u8, diag: *Diagnostic) Error!Cap`
//! - `pub fn analogCap(bench: *const Bench, session: *Session, scratch: Allocator, pin: []const u8, diag: *Diagnostic) Error!f64`
//! - `pub fn leakage(bench: *const Bench, session: *Session, scratch: Allocator, states: []const []const Vector, out: []f64, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const spec = @import("spec.zig");
const Edge = spec.Edge;
const Level = spec.Level;
const Vector = spec.Vector;
const Diagnostic = spec.Diagnostic;
const fmtSi = @import("spice.zig").fmtSi;
const session_ = @import("session.zig");
const Session = session_.Session;
const Error = session_.Error;
const need = session_.need;
const measure = @import("measure.zig");
const Bench = measure.Bench;

/// Rise and fall capacitance of one pin, pF.
pub const Cap = struct { rise: f64, fall: f64 };

/// A state a pin is switched in, and its first edge there; the measurement
/// then switches it back.
pub const Context = struct { vectors: []const Vector, edge: Edge };

/// The states a digital input switches in: its arcs' cases, else the
/// leakage states, else everything low.
pub fn contexts(bench: *const Bench, scratch: Allocator, pin: []const u8) Allocator.Error![]const Context {
    const macro = bench.macro;
    var out: std.ArrayList(Context) = .empty;
    for (macro.arcs) |arc| for (arc.cases) |case| {
        if (std.mem.eql(u8, arc.from, pin) and !arc.kind.isConstraint())
            try out.append(scratch, .{ .vectors = case.vectors, .edge = measure.inputEdge(arc, case) });
        if (std.mem.eql(u8, arc.to, pin) and arc.kind.isConstraint())
            try out.append(scratch, .{ .vectors = case.vectors, .edge = case.data.? });
    };
    if (out.items.len > 0) return out.items;
    const states: []const []const Vector = if (macro.leakage_states.len > 0) macro.leakage_states else &.{try scratch.dupe(Vector, &.{try allLow(bench, scratch)})};
    for (states) |vectors| {
        var last: ?Level = null;
        var k = vectors.len;
        while (k > 0 and last == null) {
            k -= 1;
            last = vectors[k].get(pin);
        }
        const low = last == null or last.? == .low;
        try out.append(scratch, .{ .vectors = vectors, .edge = if (low) .rise else .fall });
    }
    return out.items;
}

/// Every digital input low: the state used when the spec names none.
pub fn allLow(bench: *const Bench, scratch: Allocator) Allocator.Error!Vector {
    var states: std.ArrayList(Vector) = .empty;
    for (bench.macro.pins) |pin| if (pin.role.isDigitalInput()) {
        try states.append(scratch, .{ .names = try scratch.dupe([]const u8, &.{pin.name}), .values = try scratch.dupe(Level, &.{.low}) });
    };
    return measure.merged(scratch, states.items);
}

/// A digital input's charge-integrated capacitance: in each context the
/// edge and back, both at the middle slew of `slews_ns`, averaged over the
/// contexts. `Measure` when a charge was not measured.
pub fn inputCap(bench: *const Bench, session: *Session, scratch: Allocator, pin: []const u8, diag: *Diagnostic) Error!Cap {
    const c = bench.macro.characterization;
    const i = bench.macro.pinIndex(pin).?;
    const ramp = bench.ramp(c.slews_ns[c.slews_ns.len / 2]);
    const settle = @min(c.settle_ns, 2.0) * 1e-9;
    const rails = bench.rails(i);
    const found = try contexts(bench, scratch, pin);
    var commands: std.ArrayList(u8) = .empty;
    for (found, 0..) |context, k| {
        const waves, const start = try bench.prepare(scratch, context.vectors);
        const wave = &waves[i].?;
        const t0 = start + c.vector_ns * 1e-9;
        const t1 = t0 + measure.prep_ramp + settle;
        const t2 = t1 + ramp + settle;
        const stop = t2 + ramp + settle;
        const near, const far = if (context.edge == .rise) .{ rails[0], rails[1] } else .{ rails[1], rails[0] };
        // A state already holding the pin at the far rail starts from the near one.
        if (@abs(measure.value(wave.*) - near) > 1e-9) try measure.rampTo(scratch, wave, t0, measure.prep_ramp, near);
        try measure.rampTo(scratch, wave, t1, ramp, far);
        try measure.rampTo(scratch, wave, t2, ramp, near);
        try bench.drive(scratch, waves, null, &commands);
        try bench.tran(scratch, stop, &commands);
        // The charge the pin draws while it swings: what its driver sees.
        for ([_]struct { []const u8, f64 }{ .{ "qa", t1 }, .{ "qb", t2 } }) |m|
            try commands.print(scratch, "meas tran {s} INTEG i(vp{d}) FROM={f} TO={f}\n", .{ m[0], i, fmtSi(m[1]), fmtSi(m[1] + ramp) });
        try commands.print(scratch, "meas tran qi AVG i(vp{d}) FROM={f} TO={f}\n", .{ i, fmtSi(t1 - 0.5 * settle), fmtSi(t1) });
        try commands.print(scratch, "echo \"RES qa{d} $&qa\"\necho \"RES qb{d} $&qb\"\necho \"RES qi{d} $&qi\"\ndestroy all\n", .{ k, k, k });
    }
    const results = try session.run(scratch, commands.items, diag);
    var rise: f64 = 0.0;
    var fall: f64 = 0.0;
    const swing = rails[1] - rails[0];
    for (found, 0..) |context, k| {
        var q: [3]f64 = undefined;
        for (&q, [_][]const u8{ "qi", "qa", "qb" }) |*slot, key|
            slot.* = need(&results, try scratch.print("{s}{d}", .{ key, k })) orelse
                return bench.fail(scratch, diag, "capacitance of {s}: the charge was not measured", .{pin});
        // Less the static current the pin drew before it moved.
        const base = q[0] * ramp;
        const qa = -(q[1] - base);
        const qb = -(q[2] - base);
        const up, const down = if (context.edge == .rise) .{ qa / swing, -qb / swing } else .{ qb / swing, -qa / swing };
        rise += up * 1e12;
        fall += down * 1e12;
    }
    const n: f64 = @floatFromInt(found.len);
    return .{ .rise = rise / n, .fall = fall / n };
}

/// An analog pin's small-signal capacitance, pF, at its bias and
/// `analog_frequency_hz`: `−Im(I)/ω`, Miller included; every other pin in
/// the final state of the first leakage state, or all inputs low.
pub fn analogCap(bench: *const Bench, session: *Session, scratch: Allocator, pin: []const u8, diag: *Diagnostic) Error!f64 {
    const i = bench.macro.pinIndex(pin).?;
    const state = if (bench.macro.leakage_states.len > 0) try measure.merged(scratch, bench.macro.leakage_states[0]) else try allLow(bench, scratch);
    const waves, _ = try bench.prepare(scratch, &.{state});
    var commands: std.ArrayList(u8) = .empty;
    try bench.drive(scratch, waves, null, &commands);
    const f = fmtSi(bench.macro.characterization.analog_frequency_hz);
    try commands.print(scratch, "alter @vp{d}[acmag] = 1\nac lin 1 {f} {f}\nlet cpin = -imag(vp{d}#branch)/(2*pi*{f})\necho \"RES c $&cpin\"\ndestroy all\nalter @vp{d}[acmag] = 0\n", .{ i, f, f, i, f, i });
    const results = try session.run(scratch, commands.items, diag);
    const farads = need(&results, "c") orelse return bench.fail(scratch, diag, "capacitance of analog pin {s} was not measured", .{pin});
    return farads * 1e12;
}

/// Static power in each state, nW, into `out` in `states` order: a
/// one-vector state is a DC operating point; a sequence is simulated and its
/// supply current averaged over the last tenth of `settle_ns` after it.
pub fn leakage(bench: *const Bench, session: *Session, scratch: Allocator, states: []const []const Vector, out: []f64, diag: *Diagnostic) Error!void {
    var commands: std.ArrayList(u8) = .empty;
    const settle = bench.macro.characterization.settle_ns * 1e-9;
    const pins = bench.macro.pins;
    for (states, 0..) |state, k| {
        const waves, const end = try bench.prepare(scratch, state);
        try bench.drive(scratch, waves, null, &commands);
        if (state.len == 1) {
            try commands.appendSlice(scratch, "op\n");
            for (pins, 0..) |p, s| if (p.role.isSupply())
                try commands.print(scratch, "let l{d} = vp{d}#branch\necho \"RES l{d}_{d} $&l{d}\"\n", .{ s, s, s, k, s });
        } else {
            const stop = end + settle;
            try bench.tran(scratch, stop, &commands);
            for (pins, 0..) |p, s| if (p.role.isSupply())
                try commands.print(scratch, "meas tran l{d} AVG i(vp{d}) FROM={f} TO={f}\necho \"RES l{d}_{d} $&l{d}\"\n", .{ s, s, fmtSi(stop - 0.1 * settle), fmtSi(stop), s, k, s });
        }
        try commands.appendSlice(scratch, "destroy all\n");
    }
    const results = try session.run(scratch, commands.items, diag);
    for (states, out, 0..) |state, *nw, k| {
        var watts: f64 = 0.0;
        for (pins, 0..) |p, s| if (p.role.isSupply()) {
            const i = need(&results, try scratch.print("l{d}_{d}", .{ s, k })) orelse
                return bench.fail(scratch, diag, "{s}", .{try measure.unmeasuredLeakage(scratch, k, state)});
            watts += bench.corner.supplies.get(p.name).? * -i;
        };
        nw.* = watts * 1e9;
    }
}
