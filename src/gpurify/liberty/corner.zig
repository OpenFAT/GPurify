//! One corner, characterized: the prepared circuit and a corner → its cell,
//! worst case, and best case when an arc's cases disagree. Every
//! independent measurement goes on the session pool at once; each task
//! writes its own slot of the caller's tables. Ported from src/liberty/mod.rs
//! (`Prepared::{PRECISION, EFFORT, deck, corner, monte_carlo}`).
//!
//! Contents:
//! - `pub const Run = struct { arena, env, macro, accuracy, work, prepared }`
//! - `pub const Error = session.Error || error{Refused}`
//! - `pub fn characterize(run: Run, corner: *const CornerSpec, notes: *std.ArrayList([]const u8), diag: *Diagnostic) Error![2]?Cell`

const std = @import("std");
const Allocator = std.mem.Allocator;
const float = @import("geom").float;
const spec = @import("spec.zig");
const Accuracy = spec.Accuracy;
const MacroSpec = spec.MacroSpec;
const CornerSpec = spec.CornerSpec;
const Vector = spec.Vector;
const Diagnostic = spec.Diagnostic;
const spice = @import("spice.zig");
const session = @import("session.zig");
const Session = session.Session;
const Env = session.Env;
const measure = @import("measure.zig");
const Bench = measure.Bench;
const measure_static = @import("measure_static.zig");
const measure_constraint = @import("measure_constraint.zig");
const write = @import("write.zig");
const Cell = write.Cell;
const Pin = write.Pin;
const assemble = @import("assemble.zig");
const Grids = assemble.Grids;
const Prepared = @import("prepare.zig").Prepared;
const staticCaps = @import("static_caps.zig").staticCaps;

/// What every corner of one run shares.
pub const Run = struct {
    /// The run's arena: decks, grids, cells, notes, messages.
    arena: Allocator,
    env: Env,
    macro: *const MacroSpec,
    accuracy: Accuracy,
    /// Where decks and logs go, `env.dir`-relative; created by the caller.
    work: []const u8,
    prepared: *const Prepared,
};

/// `Refused`: `statistical` asked of a corner with no `mc_models`.
pub const Error = session.Error || error{Refused};

/// The corner's cell, worst case first, then the best case when cases
/// disagree (else null). Notes the constraints clamped to the window.
pub fn characterize(run: Run, corner: *const CornerSpec, notes: *std.ArrayList([]const u8), diag: *Diagnostic) Error![2]?Cell {
    const a = run.arena;
    const macro = run.macro;
    var cell: Cell = .{ .name = macro.cell, .pins = try a.alloc(Pin, macro.pins.len) };
    for (cell.pins, macro.pins) |*p, s| p.* = .{ .spec = s };
    if (run.accuracy == .interface) return .{ cell, null };
    const bench: Bench = .{ .macro = macro, .corner = corner, .effort = effort, .reltol = precision.reltol };
    const states = try assemble.leakageStates(a, macro, try measure_static.allLow(&bench, a));
    const leakage = try a.alloc(f64, states.len);
    const deck = try writeDeck(run, corner, false, diag);
    var tasks: std.ArrayList(Task) = .empty;
    if (@intFromEnum(run.accuracy) < @intFromEnum(Accuracy.spice)) {
        try tasks.append(a, .leakage);
        const ctx: Ctx = .{ .bench = &bench, .tasks = tasks.items, .states = states, .leakage = leakage, .pins = cell.pins, .grids = &.{} };
        try session.runPool(run.env, macro.simulator, deck, corner.name, 1, 1, &ctx, Ctx.task, a, diag);
        try assemble.setLeakage(a, &cell, macro, states, leakage);
        const path = try a.print("{s}/{s}__{s}_devices.cir", .{ run.work, macro.cell, corner.name });
        try staticCaps(a, run.env, macro, corner, &run.prepared.circuit.?, run.prepared.wire_ff, path, cell.pins, diag);
        return .{ cell, null };
    }

    // Everything independent goes on the pool at once.
    for (macro.pins, 0..) |pin, i| switch (pin.role) {
        .input, .clock => try tasks.append(a, .{ .cap = @intCast(i) }),
        .analog => try tasks.append(a, .{ .analog = @intCast(i) }),
        .power, .ground, .nwell, .pwell, .output => {},
    };
    try tasks.append(a, .leakage);
    try arcTasks(a, macro, null, &tasks);
    const grids = try a.alloc(Grids, 1);
    grids[0] = try .init(a, macro);
    const ctx: Ctx = .{ .bench = &bench, .tasks = tasks.items, .states = states, .leakage = leakage, .pins = cell.pins, .grids = grids };
    try session.runPool(run.env, macro.simulator, deck, corner.name, run.prepared.workers, @intCast(tasks.items.len), &ctx, Ctx.task, a, diag);
    try assemble.setLeakage(a, &cell, macro, states, leakage);
    const c = macro.characterization;
    for (macro.arcs, 0..) |arc, k_arc| if (arc.kind.isConstraint()) for (0..arc.cases.len) |k| {
        const window = c.constraint_window_ns;
        const clamped = for (grids[0].constraintOf(grids[0].caseIndex(k_arc, k))) |v| (if (v <= -window) break true) else false;
        if (clamped) try notes.append(a, try a.print("{s}: arc {s} -> {s} case {d} passes even {f} ns on the wrong side of the clock; its constraint is clamped to -{f} ns", .{ corner.name, arc.from, arc.to, k, Display{ .v = window }, Display{ .v = window } }));
    };
    const sigma: ?*const Grids = if (run.accuracy == .statistical) try monteCarlo(run, corner, &bench, diag) else null;
    const worst = try assemble.assemble(a, macro, cell, &grids[0], sigma, .worst);
    const best = if (assemble.casesDisagree(macro)) try assemble.assemble(a, macro, cell, &grids[0], sigma, .best) else null;
    return .{ worst, best };
}

// ---- private ----

/// Tolerances every analysis runs at. Against a reltol 1e-6, 0.1 ps-step
/// reference these agree to 0.03 % on a 10 ps edge into 0.5 fF and to
/// 0.0002 % on a 1.5 ns one, at a fifth of a fixed sub-ps step's cost.
const precision: spice.Precision = .{ .reltol = 1e-6, .abstol = 1e-15, .vntol = 1e-7, .trtol = 1.0 };

const effort: measure.Effort = .{ .max_step = 10e-12, .resolution = 0.5e-12 };

/// One unit of pool work and the slot it writes.
const Task = union(enum) {
    cap: u32,
    analog: u32,
    leakage,
    row: Point,
    constraint: Point,
};

/// A table point of one case: arc, case within it, and the row (delay) or
/// clock and data slews (constraint); `sample` a Monte Carlo redraw.
const Point = struct { arc: u32, k: u32, i: u32, j: u32 = 0, sample: ?u32 = null };

/// The pool's view of one corner's tables.
const Ctx = struct {
    bench: *const Bench,
    tasks: []const Task,
    states: []const []const Vector,
    leakage: []f64,
    pins: []Pin,
    /// Indexed by sample, or `[0]` outside Monte Carlo.
    grids: []Grids,

    fn task(ctx: *const Ctx, s: *Session, scratch: Allocator, index: u32, diag: *Diagnostic) session.Error!void {
        const bench = ctx.bench;
        const macro = bench.macro;
        switch (ctx.tasks[index]) {
            .cap => |i| {
                const cap = try measure_static.inputCap(bench, s, scratch, macro.pins[i].name, diag);
                ctx.pins[i].capacitance = .{ cap.rise, cap.fall };
            },
            .analog => |i| {
                const farads = try measure_static.analogCap(bench, s, scratch, macro.pins[i].name, diag);
                ctx.pins[i].capacitance = .{ farads, farads };
            },
            .leakage => try measure_static.leakage(bench, s, scratch, ctx.states, ctx.leakage, diag),
            .row, .constraint => |p| {
                const arc = macro.arcs[p.arc];
                const case = arc.cases[p.k];
                const label = if (p.sample) |n|
                    try scratch.print("{s} arc {s} -> {s} case {d} sample {d}", .{ @tagName(arc.kind), arc.from, arc.to, p.k, n })
                else
                    try scratch.print("{s} arc {s} -> {s} case {d}", .{ @tagName(arc.kind), arc.from, arc.to, p.k });
                const g = &ctx.grids[p.sample orelse 0];
                const c = g.caseIndex(p.arc, p.k);
                if (p.sample) |n| try measure_constraint.redraw(s, scratch, n, diag);
                if (ctx.tasks[index] == .row) return measure.delayRow(bench, s, scratch, arc, case, p.i, label, g.delayRow(c, p.i), diag);
                const slews = macro.characterization.constraint_slews_ns;
                g.constraintAt(c, p.i, p.j).* = try measure_constraint.constraintPoint(bench, s, scratch, arc, case, slews[p.i], slews[p.j], label, diag);
            },
        }
    }
};

/// Rust's `{}` of an `f64`.
const Display = struct {
    v: f64,
    pub fn format(d: Display, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return float.display(w, d.v);
    }
};

/// Every table point of every arc case, in spec order.
fn arcTasks(a: Allocator, macro: *const MacroSpec, sample: ?u32, tasks: *std.ArrayList(Task)) Allocator.Error!void {
    const c = macro.characterization;
    for (macro.arcs, 0..) |arc, ai| for (0..arc.cases.len) |k| {
        if (arc.kind.isConstraint()) {
            for (0..c.constraint_slews_ns.len) |i| for (0..c.constraint_slews_ns.len) |j|
                try tasks.append(a, .{ .constraint = .{ .arc = @intCast(ai), .k = @intCast(k), .i = @intCast(i), .j = @intCast(j), .sample = sample } });
        } else for (0..c.slews_ns.len) |row| {
            try tasks.append(a, .{ .row = .{ .arc = @intCast(ai), .k = @intCast(k), .i = @intCast(row), .sample = sample } });
        }
    };
}

/// Writes a corner's testbench deck under the work directory; its path.
fn writeDeck(run: Run, corner: *const CornerSpec, statistical: bool, diag: *Diagnostic) Error![]const u8 {
    const a = run.arena;
    var subckt: std.Io.Writer.Allocating = .init(a);
    spice.writeSubckt(&run.prepared.circuit.?, run.macro, &subckt.writer) catch return error.OutOfMemory;
    var deck: std.Io.Writer.Allocating = .init(a);
    spice.writeDeck(run.macro, corner, subckt.written(), precision, statistical, &deck.writer) catch return error.OutOfMemory;
    const path = try a.print("{s}/{s}__{s}{s}.cir", .{ run.work, run.macro.cell, corner.name, if (statistical) "_mc" else "" });
    run.env.dir.writeFile(run.env.io, .{ .sub_path = path, .data = deck.written() }) catch |err| {
        diag.message = try a.print("io: {s}: {s}", .{ path, @errorName(err) });
        return error.Io;
    };
    return path;
}

/// Per table point, the standard deviation over `mc_samples` redraws.
fn monteCarlo(run: Run, corner: *const CornerSpec, bench: *const Bench, diag: *Diagnostic) Error!*const Grids {
    const a = run.arena;
    const macro = run.macro;
    if (corner.mc_models.len == 0) {
        diag.message = try a.print("statistical accuracy needs corner {s}'s mc_models: the model lines with variation switched on", .{corner.name});
        return error.Refused;
    }
    const deck = try writeDeck(run, corner, true, diag);
    const samples = macro.characterization.mc_samples;
    var tasks: std.ArrayList(Task) = .empty;
    for (0..samples) |n| try arcTasks(a, macro, @intCast(n), &tasks);
    const per_sample = try a.alloc(Grids, samples);
    for (per_sample) |*g| g.* = try .init(a, macro);
    const ctx: Ctx = .{ .bench = bench, .tasks = tasks.items, .states = &.{}, .leakage = &.{}, .pins = &.{}, .grids = per_sample };
    try session.runPool(run.env, macro.simulator, deck, corner.name, run.prepared.workers, @intCast(tasks.items.len), &ctx, Ctx.task, a, diag);
    const sigma = try a.create(Grids);
    sigma.* = try .init(a, macro);
    const columns = try a.alloc([]const f64, samples);
    const cases = sigma.case_start[macro.arcs.len];
    inline for (.{ "delayOf", "transitionOf", "constraintOf" }) |of| for (0..cases) |case| {
        for (columns, per_sample) |*col, *g| col.* = @field(Grids, of)(g, case);
        measure_constraint.sigmaInto(columns, @field(Grids, of)(sigma, case));
    };
    return sigma;
}
