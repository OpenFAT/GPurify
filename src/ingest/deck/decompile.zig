//! A lowered deck's tables → names again: the layers, connectivity, devices
//! and stack as a `DeckSource` (no rules), and the `lvs` controls as an
//! `LvsSrc`, so that `lower` resolves them to the same tables in the same
//! string table. What a compiled deck decompiles to. Ported from
//! crates/ingest/src/deck/source.rs (`DeckSource::from_tables`) and mod.rs
//! (`LvsSrc::from_controls`).
//!
//! Contents:
//! - `pub fn fromTables(arena: Allocator, layers: *const LayerTable, connectivity: tables.Connectivity, devices: tables.DeviceRecognition, stack: tables.ProcessStack, temperature: ?f64, strings: *const StrTable) Allocator.Error!DeckSource`
//! - `pub fn fromControls(arena: Allocator, controls: tables.LvsControls, devices: []const source.DeviceSource, strings: *const StrTable) Allocator.Error!source.LvsSrc`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const tables = @import("tables.zig");
const LayerTable = @import("layers.zig").LayerTable;
const source = @import("source.zig");
const DeckSource = source.DeckSource;

/// The layers, connectivity, devices and stack, back to names, and no rule.
/// A `pex` row is one whose thickness is stated. The sheet resistances are
/// already at `temperature`, so a deck with one is written at it: nominal
/// equal to operating and every row's coefficients zero, which lowers to
/// the same stack.
pub fn fromTables(arena: Allocator, layers: *const LayerTable, connectivity: tables.Connectivity, devices: tables.DeviceRecognition, stack: tables.ProcessStack, temperature: ?f64, strings: *const StrTable) Allocator.Error!DeckSource {
    var doc: DeckSource = .{};
    const n = layers.len();
    for (0..n) |i| {
        const id: LayerId = @fromBackingInt(@as(u16, @intCast(i)));
        if (!layers.isDerived(id)) try doc.layers.append(arena, .{ .name = strings.resolve(layers.name(id)), .stream = layers.streamOf(id) });
    }
    try doc.ignored.appendSlice(arena, layers.ignored.items);
    for (0..layers.derivedCount()) |k| {
        const id: LayerId = @fromBackingInt(@as(u16, @intCast(layers.derived_start + k)));
        try doc.derived.append(arena, .{ .name = strings.resolve(layers.name(id)), .op = layers.op(id).?, .layers = try names(arena, layers, layers.operands(id), strings) });
    }
    try doc.texts.appendSlice(arena, layers.texts.items);
    const c = &doc.connectivity;
    try c.conductors.appendSlice(arena, try names(arena, layers, connectivity.conductors, strings));
    c.intra_layer_touch = connectivity.intra_layer_touch;
    try c.global.appendSlice(arena, try names(arena, layers, connectivity.global, strings));
    for (connectivity.via_cut, connectivity.via_connects) |cut, joins| {
        try c.vias.append(arena, .{ .layer = name(layers, cut, strings), .connects = .{ name(layers, joins[0], strings), name(layers, joins[1], strings) } });
    }
    for (connectivity.label_layer, connectivity.label_names) |text, named| {
        try c.labels.append(arena, .{ .layer = name(layers, text, strings), .names = name(layers, named, strings) });
    }
    for (devices.kind, 0..) |kind, row| {
        const span = devices.terminal[devices.terminal_start[row]..devices.terminal_start[row + 1]];
        try doc.devices.append(arena, .{
            .kind = kind,
            .marker = name(layers, devices.marker[row], strings),
            .model = strings.resolve(devices.model[row]),
            .terminals = try names(arena, layers, span, strings),
            .value = if (row < devices.value.len) devices.value[row] else .{},
            .fins = if (row < devices.fins.len) if (devices.fins[row]) |f| name(layers, f, strings) else null else null,
        });
    }
    doc.netlist_scale_nm = devices.netlist_scale_nm;
    for (0..n) |at| {
        if (at >= stack.thickness_nm.len or !(stack.thickness_nm[at] > 0.0)) continue;
        const id: LayerId = @fromBackingInt(@as(u16, @intCast(at)));
        try doc.pex.append(arena, .{ .layer = name(layers, id, strings), .row = .{
            .thickness_nm = stack.thickness_nm[at],
            .height_nm = stack.height_nm[at],
            .sheet_res_ohm_sq = stack.sheet_res_ohm_sq[at],
            .area_cap_af_um2 = stack.area_cap_af_um2[at],
            .fringe_cap_af_um = stack.fringe_cap_af_um[at],
            .dielectric_k = stack.dielectric_k[at],
            .tc = if (temperature != null) .{ 0, 0 } else null,
        } });
    }
    if (temperature) |kelvin| doc.temperature = .{ .operating_k = kelvin, .nominal_k = kelvin };
    return doc;
}

/// The statements that `lower` resolves to `controls`, for a deck whose
/// devices are `devices`.
pub fn fromControls(arena: Allocator, controls: tables.LvsControls, devices: []const source.DeviceSource, strings: *const StrTable) Allocator.Error!source.LvsSrc {
    var s: source.LvsSrc = .{ .default_tolerance = controls.default_tolerance };
    for (controls.tolerance) |row| try s.tolerance.append(arena, .{ .model = strings.resolve(row.model), .param = strings.resolve(row.param), .relative = row.relative, .absolute = row.stated });
    for (controls.ignore_parameter) |row| try s.ignore_parameter.append(arena, .{ .a = strings.resolve(row.model), .b = strings.resolve(row.param) });
    for (controls.asymmetric) |id| try s.asymmetric.append(arena, strings.resolve(id));
    for (controls.permute) |row| {
        const model = strings.resolve(row.model);
        const kind = for (devices) |d| {
            if (std.mem.eql(u8, d.model, model)) break d.kind;
        } else .mos;
        const pins = tables.pinNames(kind);
        try s.permute.append(arena, .{ .model = model, .a = pins[row.a], .b = pins[row.b] });
    }
    for (controls.ignore) |id| try s.ignore.append(arena, strings.resolve(id));
    for (controls.ignore_shorted) |id| try s.ignore_shorted.append(arena, strings.resolve(id));
    s.ports_by_name = controls.ports_by_name;
    s.recognize_gates = controls.recognize_gates;
    s.split_gates = controls.split_gates;
    try s.blackbox.appendSlice(arena, controls.blackbox);
    try s.filter_unused.appendSlice(arena, controls.filter_unused);
    for (controls.supply) |id| try s.supply.append(arena, strings.resolve(id));
    for (controls.lde) |row| try s.lde.append(arena, .{
        .model = strings.resolve(row.model),
        .od = strings.resolve(row.od),
        .max = row.max,
        .well = if (row.well) |w| .{ .layer = strings.resolve(w.layer), .scref = w.scref } else null,
    });
    for (controls.range) |row| try s.range.append(arena, .{ .model = strings.resolve(row.model), .param = strings.resolve(row.param), .min = row.min, .max = row.max });
    s.topology = if (controls.relaxed) true else null;
    try s.connect_implicit.appendSlice(arena, controls.connect_implicit);
    for (controls.connect_explicit) |group| {
        const out = try arena.alloc([]const u8, group.len);
        for (group, out) |id, *o| o.* = strings.resolve(id);
        try s.connect_explicit.append(arena, out);
    }
    s.max_res = controls.max_res;
    s.min_caps = controls.min_caps;
    for (controls.same_nets) |row| try s.same_nets.append(arena, .{ .a = strings.resolve(row.layout), .b = strings.resolve(row.reference) });
    for (controls.count) |row| try s.count.append(arena, .{ .model = strings.resolve(row.model), .min = row.min, .max = row.max });
    return s;
}

// ---- private ----

fn name(layers: *const LayerTable, id: LayerId, strings: *const StrTable) []const u8 {
    return strings.resolve(layers.name(id));
}

fn names(arena: Allocator, layers: *const LayerTable, ids: []const LayerId, strings: *const StrTable) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, ids.len);
    for (ids, out) |id, *o| o.* = name(layers, id, strings);
    return out;
}
