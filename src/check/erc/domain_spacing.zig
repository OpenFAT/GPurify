//! The geometric voltage-domain kinds, over a usable intent: spacing a
//! voltage table sets between two nets (`voltage_spacing`), the lateral
//! gap a dielectric's field rating sets (`dielectric_field`), and the tag a
//! high-voltage figure must sit inside (`hv_tag`). In: the design, the
//! propagated voltages, a kind's table. Out: violations and one `RuleRun`
//! per row. Ported from crates/check/src/erc/rules/domain.rs
//! (`check_voltage_spacing`, `step_space`, `check_dielectric_field`,
//! `check_hv_tag`).
//!
//! Contents:
//! - `pub fn voltageSpacing(r: Record, design: Design, voltage: *const NetVoltage, t: *const VoltageSpacingTable) Allocator.Error!void`
//! - `pub fn dielectricField(r: Record, design: Design, voltage: *const NetVoltage, grid: Grid, t: *const DielectricFieldTable) Allocator.Error!void`
//! - `pub fn hvTag(r: Record, design: Design, voltage: *const NetVoltage, t: *const HvTagTable) Allocator.Error!void`
//! - the judges `netPairSpacing` and `insideWhere` call: `StepNeed.needOf`, `FieldNeed.needOf` (`needOf`), `HighVoltage.judge` (`judge`)

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Grid = geom.Grid;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const Millivolts = report.Millivolts;
const proximity = @import("../proximity.zig");
const insideWhere = @import("../proximity_inside.zig").insideWhere;
const NetId = @import("../topology/net.zig").NetId;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const NetVoltage = @import("voltage.zig").NetVoltage;
const tables = @import("domain_tables.zig");
const DielectricFieldTable = tables.DielectricFieldTable;
const HvTagTable = tables.HvTagTable;
const VoltageSpacingTable = tables.VoltageSpacingTable;

/// A pair's need from a voltage table.
const StepNeed = struct {
    voltage: *const NetVoltage,
    volts: []const Millivolts,
    spaces: []const Dbu,

    pub fn needOf(n: StepNeed, a: u32, b: u32) proximity.Need {
        if (a == b) return .unjudged;
        const delta = n.voltage.worstDelta(@fromBackingInt(a), @fromBackingInt(b)) orelse return .unjudged;
        // The step with the largest voltage at or below `delta`.
        var step = n.volts.len;
        while (step > 0) : (step -= 1) if (n.volts[step - 1].raw <= delta) return .{ .limit = n.spaces[step - 1] };
        return .free;
    }
};

/// A pair's need from a dielectric's field rating.
const FieldNeed = struct {
    voltage: *const NetVoltage,
    field: f64,
    vertical: f64,
    per_um: f64,

    pub fn needOf(n: FieldNeed, a: u32, b: u32) proximity.Need {
        if (a == b) return .unjudged;
        const delta = n.voltage.worstDelta(@fromBackingInt(a), @fromBackingInt(b)) orelse return .unjudged;
        return if (n.lateral(delta)) |l| .{ .limit = l } else .free;
    }

    /// The lateral gap `delta` mV needs, grid units rounded up; null when
    /// the vertical dielectric alone suffices.
    fn lateral(n: FieldNeed, delta: f64) ?Dbu {
        // The separation the voltage needs, nm, then its lateral part.
        const separation = delta / n.field;
        if (!(separation > n.vertical)) return null;
        const nm = @sqrt(separation * separation - n.vertical * n.vertical);
        return @intFromFloat(@ceil(nm * n.per_um / 1000.0));
    }
};

/// A figure is judged when its net can reach `from` mV or more.
const HighVoltage = struct {
    design: Design,
    voltage: *const NetVoltage,
    from: f64,

    pub fn judge(h: HighVoltage, owner: PolyId) bool {
        const net = h.design.nets.netOf(owner);
        return h.voltage.known(net) and h.voltage.hi.items[@backingInt(net)] >= h.from;
    }
};

/// Each pair of shapes on two different reached nets, within the row's
/// largest space (one layer: in different merged figures), held to the
/// step of the largest voltage at or below what the two can reach apart.
/// `examined` counts judged pairs; a violation sits at the midpoint of the
/// pair's nearest points. A row is refused when a layer will not validate
/// or holds a shape on no net.
pub fn voltageSpacing(r: Record, design: Design, voltage: *const NetVoltage, t: *const VoltageSpacingTable) Allocator.Error!void {
    var s: proximity.Scratch = .{};
    defer s.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const from = t.step_start.items[row];
        const to = t.step_start.items[row + 1];
        const need: StepNeed = .{ .voltage = voltage, .volts = t.voltage.items[from..to], .spaces = t.space.items[from..to] };
        const widest = std.mem.max(Dbu, need.spaces);
        const verdict = try pairs(r, design, rule, t.layer.items[row], t.other.items[row], widest, &s, need);
        @memset(r.out.severity.items[before..], severity);
        try r.run(rule, before, verdict.outcome, verdict.examined);
    }
}

/// Each pair of shapes on two different reached nets closer laterally than
/// `sqrt(sep² - vertical²)`, `sep` their voltage apart over `max_field`,
/// within the largest lateral limit any two nets of the layout need. A row
/// is refused when its stack leaves the vertical gap unstated, or a layer
/// will not validate or holds a shape on no net.
pub fn dielectricField(r: Record, design: Design, voltage: *const NetVoltage, grid: Grid, t: *const DielectricFieldTable) Allocator.Error!void {
    // The widest voltage any two reached nets can span, mV.
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (voltage.lo.items, voltage.hi.items) |l, h| if (l <= h) {
        lo = @min(lo, l);
        hi = @max(hi, h);
    };
    const widest_delta = @max(hi - lo, 0.0);
    var s: proximity.Scratch = .{};
    defer s.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const verdict: Verdict = if (t.vertical_nm.items[row]) |vertical| blk: {
            const need: FieldNeed = .{ .voltage = voltage, .field = t.max_field.items[row], .vertical = vertical, .per_um = @floatFromInt(grid.dbu_per_um) };
            const widest = @max(need.lateral(widest_delta) orelse 0, 1);
            break :blk try pairs(r, design, rule, t.layer.items[row], t.other.items[row], widest, &s, need);
        } else report.refused;
        @memset(r.out.severity.items[before..], severity);
        try r.run(rule, before, verdict.outcome, verdict.examined);
    }
}

/// Each merged figure of `L` whose net can reach `voltage` or more must lie
/// inside `tag`: the area outside against 0, at the centre of its first
/// rectangle. `examined` counts the high-voltage figures. A row is refused
/// when a layer will not validate or merge, or `L` holds a shape on no net.
pub fn hvTag(r: Record, design: Design, voltage: *const NetVoltage, t: *const HvTagTable) Allocator.Error!void {
    var s: proximity.Scratch = .{};
    defer s.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const layer = t.layer.items[row];
        const rows = design.store.polysOnLayer(layer);
        const unnetted = for (rows.start..rows.end) |p| {
            if (design.nets.netOf(@fromBackingInt(@as(u32, @intCast(p)))) == .none) break true;
        } else false;
        const verdict = if (unnetted) report.refused else try insideWhere(r.gpa, design.store, rule, layer, t.tag.items[row], &s, r.out, HighVoltage{ .design = design, .voltage = voltage, .from = t.voltage.items[row].raw });
        @memset(r.out.severity.items[before..], severity);
        try r.run(rule, before, verdict.outcome, verdict.examined);
    }
}

// ---- private ----

/// `netPairSpacing` with its thread-spawn failures read as a refused row
/// (fail closed): the ERC transforms surface only allocation failure.
fn pairs(r: Record, design: Design, rule: geom.StrId, a: geom.LayerId, b: ?geom.LayerId, widest: Dbu, s: *proximity.Scratch, need: anytype) Allocator.Error!Verdict {
    return proximity.netPairSpacing(r.gpa, design.store, design.nets.netColumn(), rule, a, b, widest, s, r.out, need) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => report.refused,
    };
}
