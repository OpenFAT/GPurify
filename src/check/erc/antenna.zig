//! The process-stage kinds: antenna ratios per etch stage (`antenna`, LEF's
//! PAR/CAR; `antenna_electrical`, with protection-diode credit, sky130's
//! EGAR), and windowed density with its CMP excursion (`density_cmp`). In:
//! the design, the macro pins' LEF antenna data, the etch stack, the die.
//! Out: violations (antenna findings with a protection-diode fix hint where
//! the row's model gives one) and one run per row; no design intent needed.
//! Ported from crates/check/src/erc/rules/antenna.rs (`check_antenna`,
//! `check_antenna_electrical`, `check_density_cmp`); the row model is
//! antenna_row.zig, the stage nets antenna_stage.zig, the windows
//! antenna_density.zig.
//!
//! Contents:
//! - `pub fn checkAntenna(r: Record, design: Design, pins: []const MacroPinAntenna, t: *const AntennaTable, stack: Stack, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkAntennaElectrical(r: Record, design: Design, pins: []const MacroPinAntenna, grid: Grid, t: *const AntennaElectricalTable, stack: Stack, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkDensityCmp(r: Record, design: Design, die: Bbox, t: *const DensityCmpTable, scratch: *Scratch) Allocator.Error!void`
//! - `Plain.of`, `Electrical.of`: the row judges (pub for antenna_row.zig's generic call)

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const DbuArea = geom.DbuArea;
const Grid = geom.Grid;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("antenna_tables.zig");
const AntennaElectricalTable = tables.AntennaElectricalTable;
const AntennaTable = tables.AntennaTable;
const AreaPoint = tables.AreaPoint;
const DensityCmpTable = tables.DensityCmpTable;
const MacroPinAntenna = tables.MacroPinAntenna;
const Stack = tables.Stack;
const row_ = @import("antenna_row.zig");
const Judged = row_.Judged;
const density = @import("antenna_density.zig");

/// An `antenna` row's judge: a gate with diode area on its net is left to
/// another row; the fix hint is `diode_area` times the ratio, at least
/// `diode_min`.
const Plain = struct {
    t: *const AntennaTable,
    row: usize,

    pub fn of(p: Plain, ratio: f64, diode: DbuArea) ?Judged {
        if (diode != 0) return null;
        const fix: ?DbuArea = if (p.t.diode_area.items[p.row]) |per| @max(row_.areaTimes(per, ratio), p.t.diode_min.items[p.row] orelse 0) else null;
        return .{ .value = ratio, .limit = p.t.max_ratio.items[p.row], .fix = fix };
    }
};

/// An `antenna_electrical` row's judge: the diode credit and the
/// diode-dependent limit for a gate with a diode, the plain ratio for one
/// without; the fix hint the least added diode that clears it, when the
/// ratio does not itself move with the diode.
const Electrical = struct {
    t: *const AntennaElectricalTable,
    row: usize,
    per_um2: f64,

    pub fn of(e: Electrical, ratio: f64, diode: DbuArea) ?Judged {
        const t = e.t;
        const row = e.row;
        const table: []const AreaPoint = t.diode_max_ratio.items[t.diode_max_ratio_start.items[row]..t.diode_max_ratio_start.items[row + 1]];
        const fixed = t.area_minus_diode.items[row] == 0.0 and t.gate_plus_diode.items[row] == 0.0 and t.diode_reduce_start.items[row] == t.diode_reduce_start.items[row + 1];
        const model: row_.Credit = .{ .ratio = ratio, .per_dbu2 = t.diode_credit.items[row] / e.per_um2, .bonus = t.diode_bonus.items[row], .max_ratio = t.max_ratio.items[row], .table = table };
        const fix: ?DbuArea = if (fixed) (if (model.leastDiode(diode)) |area| area - diode else null) else null;
        // Every credit is for a diode: no diode on the net, none given.
        if (diode == 0) return .{ .value = ratio, .limit = t.max_ratio.items[row], .fix = fix };
        return .{ .value = model.credited(diode), .limit = model.limit(diode), .fix = fix };
    }
};

/// Every row: one ratio per gate group, summed over the row's etch stages.
/// `examined` counts the gate groups judged, less those the row's `diode`
/// leaves to another row; a violation sits at the centre of the group's
/// lowest gate polygon's box. A row with gate shapes refuses when one of
/// its layers will not validate.
pub fn checkAntenna(r: Record, design: Design, pins: []const MacroPinAntenna, t: *const AntennaTable, stack: Stack, scratch: *Scratch) Allocator.Error!void {
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const from = t.collector_start.items[row];
        const to = t.collector_start.items[row + 1];
        const examined = try row_.antennaRow(r, design, pins, .{
            .rule = rule,
            .severity = severity,
            .gate = t.gate.items[row],
            .collectors = t.collector.items[from..to],
            .measures = t.collector_measure.items[from..to],
            .diode = t.diode.items[row],
        }, stack, Plain{ .t = t, .row = row }, scratch);
        try record(r, rule, before, examined);
    }
}

/// Every row: the credited ratio per gate group, against `max_ratio` or,
/// for a gate with a diode, `diode_max_ratio` read at its area. `grid`
/// turns the diode's square database units into the µm² its credit is per.
pub fn checkAntennaElectrical(r: Record, design: Design, pins: []const MacroPinAntenna, grid: Grid, t: *const AntennaElectricalTable, stack: Stack, scratch: *Scratch) Allocator.Error!void {
    const per_um2: f64 = @floatFromInt(grid.dbu_per_um * grid.dbu_per_um);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const from = t.collector_start.items[row];
        const to = t.collector_start.items[row + 1];
        const reduce = t.diode_reduce.items[t.diode_reduce_start.items[row]..t.diode_reduce_start.items[row + 1]];
        const examined = try row_.antennaRow(r, design, pins, .{
            .rule = rule,
            .severity = severity,
            .gate = t.gate.items[row],
            .collectors = t.collector.items[from..to],
            .measures = t.collector_measure.items[from..to],
            .diode = t.diode.items[row],
            .exempt = t.exempt.items[row],
            .par = .{ .cut_factor = t.cut_factor.items[row], .minus = t.area_minus_diode.items[row], .plus = t.gate_plus_diode.items[row], .reduce = reduce },
        }, stack, Electrical{ .t = t, .row = row, .per_um2 = per_um2 }, scratch);
        try record(r, rule, before, examined);
    }
}

/// Every row over the window grid laid on `die` (antenna_density.zig).
pub fn checkDensityCmp(r: Record, design: Design, die: Bbox, t: *const DensityCmpTable, scratch: *Scratch) Allocator.Error!void {
    try density.densityRows(r, design, die, t, scratch);
}

// ---- private ----

fn record(r: Record, rule: geom.StrId, before: u32, examined: ?u64) Allocator.Error!void {
    if (examined) |n| try r.run(rule, before, .ran, n) else try r.run(rule, before, .refused, 0);
}
