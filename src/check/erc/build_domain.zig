//! The voltage-domain kinds' row builders: `gate_oxide`, `drain_source`,
//! `well_bias`, `missing_level_shifter`, `missing_isolation`, `hv_tag`,
//! `dielectric_field`, `voltage_spacing`, `power_switch`, `hot_carrier`
//! and `well_sharing`. In: one deck row (`Ctx`). Out: its columns pushed
//! onto its kind's table, parameters read in Rust's order. Ported from
//! crates/check/src/erc/ruleset.rs (`RuleSet::from_deck`, those arms, and
//! `vertical_gap`).
//!
//! Contents:
//! - `pub fn modelLimit(c: Ctx, t: *ModelLimitTable) Error!void`, `wellBias`, `missingLevelShifter`, `missingIsolation`,
//!   `hvTag`, `dielectricField`, `voltageSpacing`, `powerSwitch`, `hotCarrier`, `wellSharing`
//! - `pub fn verticalGap(stack: *const ProcessStack, a: LayerId, b: LayerId) ?f64`

const std = @import("std");
const geom = @import("geom");
const LayerId = geom.LayerId;
const ProcessStack = @import("ingest").deck.ProcessStack;
const Error = @import("../drc/params.zig").Error;
const compile = @import("compile.zig");
const Ctx = compile.Ctx;
const pushCsr = compile.pushCsr;
const domain = @import("domain_tables.zig");
const ModelLimitTable = domain.ModelLimitTable;

pub fn modelLimit(c: Ctx, t: *ModelLimitTable) Error!void {
    _ = try c.row.layers(0);
    const models = try c.row.models("model");
    const max_voltage = try c.row.number("max_voltage");
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.model_start, &t.model, models);
    try t.max_voltage.append(c.gpa, .{ .raw = max_voltage });
}

pub fn wellBias(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const pmos = try c.row.models("pmos");
    const nmos = try c.row.models("nmos");
    const t = &c.rs.tables.well_bias;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.pmos_start, &t.pmos, pmos);
    try pushCsr(c.gpa, &t.nmos_start, &t.nmos, nmos);
}

pub fn missingLevelShifter(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const shifters = try c.row.models("shifter");
    const t = &c.rs.tables.missing_level_shifter;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.shifter_start, &t.shifter, shifters);
}

pub fn missingIsolation(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const isolation = try c.row.models("isolation");
    const t = &c.rs.tables.missing_isolation;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.isolation_start, &t.isolation, isolation);
}

pub fn hvTag(c: Ctx) Error!void {
    const layers = try c.row.layers(2);
    const voltage = try c.row.number("voltage");
    const t = &c.rs.tables.hv_tag;
    try c.row.head(c.gpa, &t.head);
    try t.layer.append(c.gpa, layers[0]);
    try t.tag.append(c.gpa, layers[1]);
    try t.voltage.append(c.gpa, .{ .raw = voltage });
}

pub fn dielectricField(c: Ctx) Error!void {
    const n = c.row.r.spec.layer_len;
    const layers = try c.row.layersWhere(2, n >= 1 and n <= 2);
    const max_field = try c.row.number("max_field");
    const vertical: ?f64 = if (layers.len == 1) 0.0 else verticalGap(&c.deck.stack, layers[0], layers[1]);
    const t = &c.rs.tables.dielectric_field;
    try c.row.head(c.gpa, &t.head);
    try t.layer.append(c.gpa, layers[0]);
    try t.other.append(c.gpa, if (layers.len > 1) layers[1] else null);
    try t.max_field.append(c.gpa, max_field);
    try t.vertical_nm.append(c.gpa, vertical);
}

pub fn voltageSpacing(c: Ctx) Error!void {
    const n = c.row.r.spec.layer_len;
    const layers = try c.row.layersWhere(2, n >= 1 and n <= 2);
    const table = try c.row.voltageTable();
    const t = &c.rs.tables.voltage_spacing;
    const gpa = c.gpa;
    try c.row.head(gpa, &t.head);
    try t.layer.append(gpa, layers[0]);
    try t.other.append(gpa, if (layers.len > 1) layers[1] else null);
    for (table.voltage) |v| try t.voltage.append(gpa, .{ .raw = v });
    try pushCsr(gpa, &t.step_start, &t.space, table.space);
}

pub fn powerSwitch(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const models = try c.row.models("model");
    const t = &c.rs.tables.power_switch;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.model_start, &t.model, models);
}

pub fn hotCarrier(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const models = try c.row.models("model");
    const max_length = try c.row.length("max_length");
    const t = &c.rs.tables.hot_carrier;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.model_start, &t.model, models);
    try t.max_length.append(c.gpa, max_length);
}

pub fn wellSharing(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const models = try c.row.models("model");
    const resistors = try c.row.flagOr("resistors", false);
    const t = &c.rs.tables.well_sharing;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.model_start, &t.model, models);
    try t.resistors.append(c.gpa, resistors);
}

/// The dielectric between two `pex` stack layers, nm: the upper layer's
/// height less the lower layer's height and thickness. Null when the stack
/// does not state both (no row, or a thickness of 0) or they overlap.
pub fn verticalGap(stack: *const ProcessStack, a: LayerId, b: LayerId) ?f64 {
    var lower = rowOf(stack, a) orelse return null;
    var upper = rowOf(stack, b) orelse return null;
    if (upper[0] < lower[0]) std.mem.swap([2]f64, &lower, &upper);
    const gap = upper[0] - (lower[0] + lower[1]);
    return if (gap > 0.0) gap else null;
}

// ---- private ----

/// A layer's `(height, thickness)`, null without a positive thickness.
fn rowOf(stack: *const ProcessStack, layer: LayerId) ?[2]f64 {
    const i = @backingInt(layer);
    if (i >= stack.thickness_nm.len) return null;
    const thickness = stack.thickness_nm[i];
    return if (thickness > 0.0) .{ stack.height_nm[i], thickness } else null;
}

test "vertical gap is the dielectric between two layers" {
    // Oracle: closed form, by hand. Layers (height, thickness): 0 at
    // (0, 100), 1 at (300, 50), 2 at (50, 100), 3 with no thickness, 4 at
    // (100, 10). 1 over 0: 300 - 100 = 200; 1 over 2: 300 - 150 = 150; 2
    // overlaps 0 (50 < 100); 4 sits on 0's top (gap 0).
    var thickness = [_]f64{ 100.0, 50.0, 100.0, 0.0, 10.0 };
    var height = [_]f64{ 0.0, 300.0, 50.0, 500.0, 100.0 };
    const stack: ProcessStack = .{ .thickness_nm = &thickness, .height_nm = &height };
    const gap = struct {
        fn of(s: *const ProcessStack, a: u16, b: u16) ?f64 {
            return verticalGap(s, @fromBackingInt(a), @fromBackingInt(b));
        }
    }.of;
    try std.testing.expectEqual(@as(?f64, 200.0), gap(&stack, 0, 1));
    try std.testing.expectEqual(@as(?f64, 200.0), gap(&stack, 1, 0));
    try std.testing.expectEqual(@as(?f64, 150.0), gap(&stack, 2, 1));
    try std.testing.expectEqual(@as(?f64, 150.0), gap(&stack, 1, 2));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 0, 2));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 2, 0));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 0, 4));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 4, 0));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 0, 3));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 3, 1));
    try std.testing.expectEqual(@as(?f64, null), gap(&stack, 0, 9));
}
