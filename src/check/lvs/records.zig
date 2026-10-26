//! LVS rows for the report that read no layout graph: the discrepancies of
//! a mismatch, the reference instances it left whole and unpaired, and the
//! deck's per-model parameter ranges and device counts. In: discrepancies,
//! traced reference rows, placements, or the extracted device table. Out:
//! rows appended to `Violations`, and a `RuleRun` where the row is a rule.
//! Ported from crates/check/src/lvs/checks.rs (`RULE_IDS`,
//! `intern_rule_ids`, `record_discrepancies`, `unpaired_instances`,
//! `record_unpaired_instances`, `check_param_ranges`,
//! `check_device_counts`, `graph_violation`, `on_first_shape`).
//!
//! Contents:
//! - `pub const rule_ids: [16][]const u8`, `pub fn internRuleIds(gpa: Allocator, strings: *StrTable) Allocator.Error!void`
//! - `pub fn recordDiscrepancies(gpa: Allocator, found: []const Discrepancy, strings: *const StrTable, out: *Violations) Allocator.Error!void`
//! - `pub const UnpairedInstance = struct { placement: u32, devices: u32 }`
//! - `pub fn unpairedInstancesInto(gpa: Allocator, found: []const Discrepancy, row_start: []const u32, rows_of: []const u32, placements: []const Placement, out: *std.ArrayList(UnpairedInstance)) Allocator.Error!void`
//! - `pub fn recordUnpairedInstances(gpa: Allocator, instances: []const UnpairedInstance, strings: *const StrTable, out: *Violations) Allocator.Error!void`
//! - `pub fn checkParamRanges(gpa: Allocator, design: Design, ranges: []const LvsRange, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`
//! - `pub fn checkDeviceCounts(gpa: Allocator, design: Design, counts: []const LvsCount, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`
//! - `pub fn graphViolation(rule: StrId, shape_a: PolyId, shape_b: PolyId, measured: u32, limit: u32) Violation`
//! - `pub fn onFirstShape(store: *const GeometryStore, row: Violation) Violation`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const deck = ingest.deck;
const LvsRange = deck.LvsRange;
const LvsCount = deck.LvsCount;
const LvsLimit = deck.LvsLimit;
const Placement = ingest.netlist.Placement;
const report = @import("../report.zig");
const Violation = report.Violation;
const Violations = report.Violations;
const Measurement = report.Measurement;
const RuleRun = report.RuleRun;
const device_mod = @import("../topology/device.zig");
const DeviceParam = device_mod.DeviceParam;
const DeviceMeasure = device_mod.DeviceMeasure;
const project = @import("project.zig");
const Design = project.Design;
const Discrepancy = @import("verdict.zig").Discrepancy;

/// Every rule id LVS reports under, in interning order. The first six and
/// `lvs.model_mismatch` are `Discrepancy` variants', the next five
/// `checkLayout`'s, then `lvs.param_range` (`checkParamRanges`),
/// `lvs.short_path` (with `lvs.net_seed_conflict`), `lvs.unpaired_instance`
/// and `lvs.device_count`.
pub const rule_ids = [16][]const u8{
    "lvs.unpaired_device",   "lvs.unpaired_net",    "lvs.terminal_mismatch", "lvs.parameter_mismatch",
    "lvs.undeclared_param",  "lvs.class_imbalance", "lvs.floating_net",      "lvs.label_conflict",
    "lvs.net_seed_conflict", "lvs.terminal_net",    "lvs.terminal_count",    "lvs.param_range",
    "lvs.model_mismatch",    "lvs.short_path",      "lvs.unpaired_instance", "lvs.device_count",
};

/// One reference instance a mismatch left without a partner (catalog
/// LVS-017): `placement` a row of the flattened reference's placements,
/// `devices` how many of its devices the comparison kept, all unpaired.
pub const UnpairedInstance = struct { placement: u32, devices: u32 };

/// How a measure stands against a bound.
const Judged = union(enum) { inside, broken: [2]Measurement, incomparable };

/// Interns every LVS rule id; call before any LVS row is written, or the
/// row carries `maxInt(u32)`, which `StrTable.resolve` asserts on.
pub fn internRuleIds(gpa: Allocator, strings: *StrTable) Allocator.Error!void {
    for (rule_ids) |name| _ = try strings.intern(gpa, name);
}

/// One error row per discrepancy, under its variant's id, with no layer,
/// location or shape; measured 1 against 0, except `lvs.class_imbalance`
/// (layout nodes against reference nodes) and `lvs.parameter_mismatch` (the
/// two values, when both are finite). Records no `RuleRun`.
pub fn recordDiscrepancies(gpa: Allocator, found: []const Discrepancy, strings: *const StrTable, out: *Violations) Allocator.Error!void {
    for (found) |d| {
        const name: []const u8, const measured: u32, const limit: u32 = switch (d) {
            .unpaired_device => .{ "lvs.unpaired_device", 1, 0 },
            .unpaired_net => .{ "lvs.unpaired_net", 1, 0 },
            .terminal_mismatch => .{ "lvs.terminal_mismatch", 1, 0 },
            .parameter_mismatch => .{ "lvs.parameter_mismatch", 1, 0 },
            .undeclared_param => .{ "lvs.undeclared_param", 1, 0 },
            .model_mismatch => .{ "lvs.model_mismatch", 1, 0 },
            .class_imbalance => |c| .{ "lvs.class_imbalance", c.layout_nodes, c.ref_nodes },
        };
        var row = graphViolation(report.ruleId(strings, name), report.no_shape, report.no_shape, measured, limit);
        switch (d) {
            .parameter_mismatch => |p| if (std.math.isFinite(p.layout_value) and std.math.isFinite(p.ref_value)) {
                row.measured = .ratio(p.layout_value);
                row.limit = .ratio(p.ref_value);
            },
            .unpaired_device, .unpaired_net, .terminal_mismatch, .undeclared_param, .model_mismatch, .class_imbalance => {},
        }
        try out.push(gpa, row);
    }
}

/// The reference instances whose every kept device is unpaired, each the
/// outermost such, into `out` (cleared). `row_start`/`rows_of` are
/// `Traced.reference_row_*` of the same comparison. An instance placing no kept
/// device is never reported. Only names what the flat comparison found;
/// it never changes a verdict.
pub fn unpairedInstancesInto(gpa: Allocator, found: []const Discrepancy, row_start: []const u32, rows_of: []const u32, placements: []const Placement, out: *std.ArrayList(UnpairedInstance)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var rows: usize = 0;
    for (rows_of) |r| rows = @max(rows, @as(usize, r) + 1);
    for (placements) |p| rows = @max(rows, p.devices[1]);
    const kept = try gpa.alloc(bool, rows);
    defer gpa.free(kept);
    const unpaired = try gpa.alloc(bool, rows);
    defer gpa.free(unpaired);
    @memset(kept, false);
    @memset(unpaired, false);
    for (rows_of) |r| kept[r] = true;
    const devices = row_start.len -| 1;
    for (found) |d| switch (d) {
        .unpaired_device => |u| if (u.side == .reference and u.device < devices) {
            for (rows_of[row_start[u.device]..row_start[u.device + 1]]) |r| unpaired[r] = true;
        },
        .unpaired_net, .terminal_mismatch, .parameter_mismatch, .undeclared_param, .model_mismatch, .class_imbalance => {},
    };
    var covered: u32 = 0;
    for (placements, 0..) |p, at| {
        if (p.devices[0] < covered) continue;
        var ours: u32 = 0;
        var whole = true;
        for (p.devices[0]..p.devices[1]) |r| {
            ours += @intFromBool(kept[r]);
            whole = whole and (!kept[r] or unpaired[r]);
        }
        if (ours > 0 and whole) {
            try out.append(gpa, .{ .placement = @intCast(at), .devices = ours });
            covered = p.devices[1];
        }
    }
}

/// One error row `lvs.unpaired_instance` per instance, measured its device
/// count against 0, with no layer, location or shape. Records no `RuleRun`.
pub fn recordUnpairedInstances(gpa: Allocator, instances: []const UnpairedInstance, strings: *const StrTable, out: *Violations) Allocator.Error!void {
    for (instances) |i| try out.push(gpa, graphViolation(report.ruleId(strings, "lvs.unpaired_instance"), report.no_shape, report.no_shape, i.devices, 0));
}

/// The `lvs.param_range` row (catalog LVS-068): every layout device of a
/// model an `lvs range` row names, its measured parameter held to the row's
/// bounds (a value at a bound is legal). Nothing when `ranges` is empty;
/// otherwise one `RuleRun` examining one device per row naming its model.
/// An error on the marker per broken bound: a length or area exactly, a
/// count as a count, a shared diffusion as a ratio of database units. A
/// device of a ranged model the parameter was not measured on refuses the
/// run, its other rows kept.
pub fn checkParamRanges(gpa: Allocator, design: Design, ranges: []const LvsRange, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    if (ranges.len == 0) return;
    const rule = report.ruleId(strings, "lvs.param_range");
    const before = out.len();
    const devices = design.devices;
    var examined: u64 = 0;
    var unmeasured = false;
    for (0..devices.len()) |d| {
        for (ranges) |range| {
            if (range.model != devices.model.items[d]) continue;
            examined += 1;
            const measure = measuredValue(strings, devices, @intCast(d), range.param) orelse {
                unmeasured = true;
                continue;
            };
            for ([_]?LvsLimit{ range.min, range.max }, [_]bool{ true, false }) |limit_opt, least| {
                const limit = limit_opt orelse continue;
                const pair = switch (outOfBounds(measure, limit, least)) {
                    .inside => continue,
                    .incomparable => {
                        unmeasured = true;
                        continue;
                    },
                    .broken => |pair| pair,
                };
                var row = graphViolation(rule, devices.marker.items[d], report.no_shape, 0, 0);
                row.measured = pair[0];
                row.limit = pair[1];
                try out.push(gpa, onFirstShape(design.store, row));
            }
        }
    }
    try report.recordRun(gpa, runs, out, before, rule, if (unmeasured) .refused else .ran, examined);
}

/// The `lvs.device_count` row (catalog LVS-068): the layout devices of each
/// model an `lvs count` row names, held to its bounds (a count at a bound
/// is legal; IHP SG13G2 allows at most 4000 `npn13G2` emitters a chip).
/// Nothing when `counts` is empty; otherwise one `RuleRun` examining one
/// model per row. Over the maximum: an error on the first device past it;
/// under the minimum: on the model's first device, or nowhere with none.
pub fn checkDeviceCounts(gpa: Allocator, design: Design, counts: []const LvsCount, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    if (counts.len == 0) return;
    const rule = report.ruleId(strings, "lvs.device_count");
    const before = out.len();
    const devices = design.devices;
    var of_model: std.ArrayList(u32) = .empty;
    defer of_model.deinit(gpa);
    for (counts) |row| {
        of_model.clearRetainingCapacity();
        for (devices.model.items, 0..) |m, d| if (m == row.model) try of_model.append(gpa, @intCast(d));
        const n: u32 = @intCast(of_model.items.len);
        if (row.max) |max| if (n > max) {
            const marker = devices.marker.items[of_model.items[max]];
            try out.push(gpa, onFirstShape(design.store, graphViolation(rule, marker, report.no_shape, n, max)));
        };
        if (row.min) |min| if (n < min) {
            if (of_model.items.len == 0) {
                try out.push(gpa, graphViolation(rule, report.no_shape, report.no_shape, n, min));
            } else {
                const marker = devices.marker.items[of_model.items[0]];
                try out.push(gpa, onFirstShape(design.store, graphViolation(rule, marker, report.no_shape, n, min)));
            }
        };
    }
    try report.recordRun(gpa, runs, out, before, rule, .ran, counts.len);
}

/// An error row on no layer and nowhere, measured and limit as counts.
pub fn graphViolation(rule: StrId, shape_a: PolyId, shape_b: PolyId, measured: u32, limit: u32) Violation {
    return .{
        .rule = rule,
        .layer = report.no_layer,
        .severity = .@"error",
        .at = report.nowhere,
        .measured = .count(measured),
        .limit = .count(limit),
        .shape_a = shape_a,
        .shape_b = shape_b,
    };
}

/// `row` located at its first shape's first vertex, on its layer.
pub fn onFirstShape(store: *const GeometryStore, row: Violation) Violation {
    var out = row;
    out.layer = store.polyLayer(row.shape_a);
    out.at = store.firstVertex(row.shape_a);
    return out;
}

// ---- private ----

/// The measure of device `d` an `lvs range` row's parameter name stands
/// for, or null when it is no measured name or was not measured.
fn measuredValue(strings: *const StrTable, devices: *const device_mod.DeviceTable, d: u32, name: StrId) ?DeviceMeasure {
    const text = strings.resolve(name);
    const param = for (std.enums.values(DeviceParam)) |p| (if (std.mem.eql(u8, project.spiceParamName(p), text)) break p) else return null;
    const params = devices.paramsOf(@fromBackingInt(@intCast(d)));
    for (params.names, params.measures) |n, m| if (n == param) return m;
    return null;
}

/// Whether `measure` breaks `limit` (the least legal value when `least`),
/// with the `(measured, limit)` pair reported; `incomparable` when the two
/// are of different kinds. A share of `ways` is compared exactly, its bound
/// scaled by `ways`.
fn outOfBounds(measure: DeviceMeasure, limit: LvsLimit, least: bool) Judged {
    const v: i128, const l: i128, const scale: u32 = switch (measure) {
        .length => |m| switch (limit) {
            .length => |b| .{ m, b, 0 },
            .area, .count => return .incomparable,
        },
        .area => |m| switch (limit) {
            .area => |b| .{ m, b, 0 },
            .length, .count => return .incomparable,
        },
        .count => |m| switch (limit) {
            .count => |b| .{ m, b, 0 },
            .length, .area => return .incomparable,
        },
        .length_share => |m| switch (limit) {
            .length => |b| .{ m.length, b, m.ways },
            .area, .count => return .incomparable,
        },
        .area_share => |m| switch (limit) {
            .area => |b| .{ m.area, b, m.ways },
            .length, .count => return .incomparable,
        },
    };
    const bound = if (scale == 0) l else l * scale;
    if (!(if (least) v < bound else v > bound)) return .inside;
    if (scale != 0) return .{ .broken = .{ ratioOf(v, scale), .ratio(@floatFromInt(l)) } };
    return .{
        .broken = switch (measure) {
            .length => .{ .length(@intCast(v)), .length(@intCast(l)) },
            .area => .{ .area(v), .area(l) },
            .count => .{ .count(@intCast(v)), .count(@intCast(l)) },
            .length_share, .area_share => unreachable, // else: shares returned above
        },
    };
}

fn ratioOf(value: anytype, ways: u32) Measurement {
    return .ratio(@as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(ways)));
}
