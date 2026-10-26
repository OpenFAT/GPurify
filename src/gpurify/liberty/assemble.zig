//! Measured grids → the cell's Liberty groups: the leakage states and their
//! `when`s, and per arc the timing tables, sigma twins and internal power,
//! folding the cases that share an edge worst case (or best, for `min/`).
//! In: the spec, the bare cell, the grids. Out: a `write.Cell`. Ported from
//! src/liberty/mod.rs (`leakage_states`, `set_leakage`, `when`, `Grids`,
//! `gather`, `fold`, `assemble`, `sense`).
//!
//! Contents:
//! - `pub const Grids = struct`, `init`, `caseIndex`, `delayRow`, `constraintAt`, `delayOf`, `transitionOf`, `energyOf`, `constraintOf`
//! - `pub const Pick = enum { worst, best }`
//! - `pub fn leakageStates(arena: Allocator, macro: *const MacroSpec, all_low: Vector) Allocator.Error![]const []const Vector`
//! - `pub fn setLeakage(arena: Allocator, cell: *Cell, macro: *const MacroSpec, states: []const []const Vector, leakage: []const f64) Allocator.Error!void`
//! - `pub fn assemble(arena: Allocator, macro: *const MacroSpec, base: Cell, grids: *const Grids, sigma: ?*const Grids, pick: Pick) Allocator.Error!Cell`
//! - `pub fn casesDisagree(macro: *const MacroSpec) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const spec = @import("spec.zig");
const MacroSpec = spec.MacroSpec;
const ArcSpec = spec.ArcSpec;
const Edge = spec.Edge;
const Level = spec.Level;
const Vector = spec.Vector;
const write = @import("write.zig");
const Cell = write.Cell;
const Pin = write.Pin;
const Table = write.Table;
const NamedTable = write.NamedTable;
const Timing = write.Timing;
const InternalPower = write.InternalPower;
const merged = @import("measure.zig").merged;

/// Every case's tables, row-major, case `c` (cases numbered across arcs in
/// spec order) at `c * delay_n` in the delay columns and `c * constraint_n²`
/// in `constraint`.
pub const Grids = struct {
    delay: []f64,
    transition: []f64,
    energy: []f64,
    constraint: []f64,
    /// Each arc's first case number; one longer than the arcs.
    case_start: []u32,
    loads: usize,
    delay_n: usize,
    constraint_n: usize,

    pub fn init(arena: Allocator, macro: *const MacroSpec) Allocator.Error!Grids {
        const c = macro.characterization;
        const case_start = try arena.alloc(u32, macro.arcs.len + 1);
        case_start[0] = 0;
        for (macro.arcs, 0..) |arc, a| case_start[a + 1] = case_start[a] + @as(u32, @intCast(arc.cases.len));
        const cases = case_start[macro.arcs.len];
        const delay_n = c.slews_ns.len * c.loads_pf.len;
        const cn = c.constraint_slews_ns.len;
        const g: Grids = .{
            .delay = try arena.alloc(f64, cases * delay_n),
            .transition = try arena.alloc(f64, cases * delay_n),
            .energy = try arena.alloc(f64, cases * delay_n),
            .constraint = try arena.alloc(f64, cases * cn * cn),
            .case_start = case_start,
            .loads = c.loads_pf.len,
            .delay_n = delay_n,
            .constraint_n = cn,
        };
        inline for (.{ g.delay, g.transition, g.energy, g.constraint }) |col| @memset(col, 0.0);
        return g;
    }

    pub fn caseIndex(g: *const Grids, a: usize, k: usize) usize {
        return g.case_start[a] + k;
    }

    /// Row `row` of case `case`'s delay, transition and energy tables.
    pub fn delayRow(g: *const Grids, case: usize, row: usize) @import("measure.zig").Row {
        const at = case * g.delay_n + row * g.loads;
        return .{ .delay = g.delay[at..][0..g.loads], .transition = g.transition[at..][0..g.loads], .energy = g.energy[at..][0..g.loads] };
    }

    pub fn constraintAt(g: *const Grids, case: usize, i: usize, j: usize) *f64 {
        return &g.constraint[case * g.constraint_n * g.constraint_n + i * g.constraint_n + j];
    }

    pub fn delayOf(g: *const Grids, case: usize) []f64 {
        return g.delay[case * g.delay_n ..][0..g.delay_n];
    }

    pub fn transitionOf(g: *const Grids, case: usize) []f64 {
        return g.transition[case * g.delay_n ..][0..g.delay_n];
    }

    pub fn energyOf(g: *const Grids, case: usize) []f64 {
        return g.energy[case * g.delay_n ..][0..g.delay_n];
    }

    pub fn constraintOf(g: *const Grids, case: usize) []f64 {
        const n = g.constraint_n * g.constraint_n;
        return g.constraint[case * n ..][0..n];
    }
};

/// How cases sharing an edge fold point by point.
pub const Pick = enum { worst, best };

/// The states leakage is taken in: the spec's, else each case's
/// preparation, else everything low; duplicates once.
pub fn leakageStates(arena: Allocator, macro: *const MacroSpec, all_low: Vector) Allocator.Error![]const []const Vector {
    if (macro.leakage_states.len > 0) return macro.leakage_states;
    var states: std.ArrayList([]const Vector) = .empty;
    for (macro.arcs) |arc| for (arc.cases) |case| {
        const seen = for (states.items) |s| (if (sequenceEql(s, case.vectors)) break true) else false;
        if (!seen) try states.append(arena, case.vectors);
    };
    if (states.items.len == 0) try states.append(arena, try arena.dupe(Vector, &.{all_low}));
    return states.items;
}

/// The cell's leakage: the mean, and a `when` per state only when every
/// state is a distinct logic state.
pub fn setLeakage(arena: Allocator, cell: *Cell, macro: *const MacroSpec, states: []const []const Vector, leakage: []const f64) Allocator.Error!void {
    if (leakage.len == 0) return;
    var sum: f64 = 0.0;
    for (leakage) |l| sum += l;
    cell.leakage_nw = sum / @as(f64, @floatFromInt(leakage.len));
    const whens = try arena.alloc([]const u8, states.len);
    for (states, whens) |s, *w| w.* = try when(arena, macro, try merged(arena, s));
    var distinct = states.len > 1;
    for (whens, 0..) |w, i| {
        if (w.len == 0) distinct = false;
        for (whens[0..i]) |other| if (std.mem.eql(u8, w, other)) {
            distinct = false;
        };
    }
    if (distinct) {
        cell.leakage_when = whens;
        cell.leakage_value = leakage;
    }
}

/// Builds the cell's timing and power groups from the measured grids;
/// `sigma` adds the LVF twins, always folded worst case.
pub fn assemble(arena: Allocator, macro: *const MacroSpec, base: Cell, grids: *const Grids, sigma: ?*const Grids, pick: Pick) Allocator.Error!Cell {
    const c = macro.characterization;
    var cell = base;
    cell.pins = try arena.dupe(Pin, base.pins);
    const timings = try arena.alloc(std.ArrayList(Timing), cell.pins.len);
    @memset(timings, .empty);
    const powers = try arena.alloc(std.ArrayList(InternalPower), cell.pins.len);
    @memset(powers, .empty);
    for (macro.arcs, 0..) |arc, a| {
        const to = macro.pinIndex(arc.to).?;
        const constraint = arc.kind.isConstraint();
        var tables: std.ArrayList(NamedTable) = .empty;
        var power: InternalPower = .{ .related = arc.from };
        for ([_]Edge{ .rise, .fall }) |edge| {
            var ks: std.ArrayList(usize) = .empty;
            for (arc.cases, 0..) |case, k| if ((case.output orelse case.data) == edge) try ks.append(arena, grids.caseIndex(a, k));
            const e = @tagName(edge);
            const axes: [2][]const f64 = if (constraint) .{ c.constraint_slews_ns, c.constraint_slews_ns } else .{ c.slews_ns, c.loads_pf };
            var buf: [2]Column = undefined;
            const columns: []const Column = if (constraint) blk: {
                buf[0] = .{ .group = try arena.print("{s}_constraint", .{e}), .sigma_group = try arena.print("ocv_sigma_{s}_constraint", .{e}), .of = Grids.constraintOf };
                break :blk buf[0..1];
            } else blk: {
                buf[0] = .{ .group = try arena.print("cell_{s}", .{e}), .sigma_group = try arena.print("ocv_sigma_cell_{s}", .{e}), .of = Grids.delayOf };
                buf[1] = .{ .group = try arena.print("{s}_transition", .{e}), .sigma_group = try arena.print("ocv_sigma_{s}_transition", .{e}), .of = Grids.transitionOf };
                break :blk buf[0..2];
            };
            for (columns) |col| if (try fold(arena, grids, ks.items, col.of, pick)) |v|
                try tables.append(arena, .{ .group = col.group, .table = .{ .index_1 = axes[0], .index_2 = axes[1], .values = v } });
            if (sigma) |s| for (columns) |col| if (try fold(arena, s, ks.items, col.of, .worst)) |v| {
                for ([_][]const u8{ "early", "late" }) |side|
                    try tables.append(arena, .{ .group = col.sigma_group, .sigma = side, .table = .{ .index_1 = axes[0], .index_2 = axes[1], .values = v } });
            };
            if (constraint) continue;
            const energy: ?Table = if (try fold(arena, grids, ks.items, Grids.energyOf, pick)) |v| .{ .index_1 = axes[0], .index_2 = axes[1], .values = v } else null;
            switch (edge) {
                .rise => power.rise = energy,
                .fall => power.fall = energy,
            }
        }
        const pin = &cell.pins[to];
        if (!constraint) {
            var worst: f64 = 0.0;
            for (tables.items) |t| if (std.mem.endsWith(u8, t.group, "_transition") and t.sigma == null) {
                for (t.table.values) |v| worst = @max(worst, v);
            };
            pin.max_capacitance_pf = c.loads_pf[c.loads_pf.len - 1];
            pin.max_transition_ns = @max(pin.max_transition_ns orelse 0.0, worst);
            if (power.rise != null or power.fall != null) try powers[to].append(arena, power);
        }
        try timings[to].append(arena, .{ .related = arc.from, .kind = arc.kind, .sense = sense(arc), .tables = tables.items });
        const from = macro.pinIndex(arc.from).?;
        const limit = if (constraint) c.constraint_slews_ns[c.constraint_slews_ns.len - 1] else c.slews_ns[c.slews_ns.len - 1];
        for ([_]usize{ from, if (constraint) to else from }) |i| {
            const p = &cell.pins[i];
            p.max_transition_ns = if (p.max_transition_ns) |m| @min(m, limit) else limit;
        }
    }
    for (cell.pins, timings, powers) |*pin, t, p| {
        if (t.items.len > 0) pin.timing = t.items;
        if (p.items.len > 0) pin.power = p.items;
    }
    return cell;
}

/// Whether some arc's cases make one edge more than once: a data-dependent
/// arc, which writes a `min/` library too.
pub fn casesDisagree(macro: *const MacroSpec) bool {
    for (macro.arcs) |arc| {
        var seen = [3]bool{ false, false, false };
        for (arc.cases) |case| {
            const slot: usize = if (case.output orelse case.data) |e| @intFromEnum(e) else 2;
            if (seen[slot]) return true;
            seen[slot] = true;
        }
    }
    return false;
}

// ---- private ----

/// One timing table family of an edge: its group, its sigma twin's, and
/// the grid column it reads.
const Column = struct { group: []const u8, sigma_group: []const u8, of: *const fn (*const Grids, usize) []f64 };

/// The cases `ks` of one table folded point by point; null with no case.
fn fold(arena: Allocator, grids: *const Grids, ks: []const usize, of: *const fn (*const Grids, usize) []f64, pick: Pick) Allocator.Error!?[]f64 {
    if (ks.len == 0) return null;
    const out = try arena.dupe(f64, of(grids, ks[0]));
    for (ks[1..]) |k| for (out, of(grids, k)) |*o, v| {
        o.* = switch (pick) {
            .worst => @max(o.*, v),
            .best => @min(o.*, v),
        };
    };
    return out;
}

/// A state as a Liberty boolean of its logic-level inputs.
fn when(arena: Allocator, macro: *const MacroSpec, state: Vector) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (macro.pins) |pin| {
        const level = state.get(pin.name) orelse continue;
        const bang = switch (level) {
            .high => "",
            .low => "!",
            .volts => continue,
        };
        if (out.items.len > 0) try out.append(arena, '&');
        try out.print(arena, "{s}{s}", .{ bang, pin.name });
    }
    return out.items;
}

/// A combinational arc's unateness from its cases; null for a clocked one.
fn sense(arc: ArcSpec) ?[]const u8 {
    if (arc.kind != .combinational) return null;
    var same = true;
    var opposite = true;
    for (arc.cases) |c| {
        same = same and c.edge == c.output;
        opposite = opposite and (if (c.edge) |e| e.flip() else null) == c.output;
    }
    return if (same) "positive_unate" else if (opposite) "negative_unate" else "non_unate";
}

fn sequenceEql(a: []const Vector, b: []const Vector) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.names.len != y.names.len) return false;
        for (x.names, y.names, x.values, y.values) |n, m, v, w| {
            if (!std.mem.eql(u8, n, m) or !levelEql(v, w)) return false;
        }
    }
    return true;
}

fn levelEql(a: Level, b: Level) bool {
    return switch (a) {
        .low => b == .low,
        .high => b == .high,
        .volts => |v| b == .volts and b.volts == v,
    };
}

test "an inverter's arc is negative unate and its cases agree" {
    // Oracle: Liberty's `timing_sense` definition: an input rise that makes
    // the output fall in every case is `negative_unate`; one edge per case
    // means no `min/` library; a second fall case makes the cases disagree.
    const fall_case: spec.CaseSpec = .{ .vectors = &.{}, .edge = .rise, .output = .fall };
    const rise_case: spec.CaseSpec = .{ .vectors = &.{}, .edge = .fall, .output = .rise };
    const arc: ArcSpec = .{ .from = "A", .to = "Y", .kind = .combinational, .cases = &.{ fall_case, rise_case } };
    try std.testing.expectEqualStrings("negative_unate", sense(arc).?);
    var macro: MacroSpec = .{ .cell = "inv", .pins = &.{}, .corners = &.{}, .arcs = &.{arc} };
    try std.testing.expect(!casesDisagree(&macro));
    macro.arcs = &.{.{ .from = "A", .to = "Y", .kind = .combinational, .cases = &.{ fall_case, fall_case } }};
    try std.testing.expect(casesDisagree(&macro));
}
