//! A deck by name → a `Deck` by id: resolves every name, assigns layer ids,
//! and refuses what contradicts itself, so a source built by anyone lowers
//! to a deck the engines can trust as one parsed from text. Strings are
//! interned in section order (layers, derived layers, rules, connectivity,
//! devices, corners, stages, waivers, lvs), so the same source and table
//! state give the same `StrId`s. Ported from crates/ingest/src/deck/source.rs
//! (`lower`, `check_operands`, `build_layers`, `build_rules`,
//! `build_connectivity`, `build_devices`, `layer_of`).
//!
//! Contents:
//! - `pub fn lower(arena: Allocator, gpa: Allocator, doc: *const DeckSource, strings: *StrTable, diag: *Diag) Error!Deck`
//! - `pub const Ctx`, `Ctx.malformed(c: Ctx, comptime fmt: []const u8, args: anytype) Error`,
//!   `Ctx.layerOf(c: Ctx, layers: *const LayerTable, name: []const u8, user: []const u8) Error!LayerId`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const tables = @import("tables.zig");
const Deck = tables.Deck;
const layers_mod = @import("layers.zig");
const LayerTable = layers_mod.LayerTable;
const DerivedOp = layers_mod.DerivedOp;
const source = @import("source.zig");
const DeckSource = source.DeckSource;
const kinds = @import("kinds.zig");
const diagnostic = @import("diagnostic.zig");
const Error = diagnostic.Error;
const Diag = diagnostic.Diag;
const lower_tables = @import("lower_tables.zig");

/// What every lowering step allocates with and reports through.
pub const Ctx = struct {
    arena: Allocator,
    gpa: Allocator,
    strings: *StrTable,
    diag: *Diag,

    /// `Malformed`, its message formatted into the arena.
    pub fn malformed(c: Ctx, comptime fmt: []const u8, args: anytype) Error {
        c.diag.malformed = try std.fmt.allocPrint(c.arena, fmt, args);
        return error.Malformed;
    }

    /// A layer by name, or `Malformed` naming the statement that used it.
    pub fn layerOf(c: Ctx, layers: *const LayerTable, name: []const u8, user: []const u8) Error!LayerId {
        return layers.id(c.strings, name) orelse c.malformed("{s}: unknown layer {s}", .{ user, name });
    }
};

/// Resolves `doc` to a `Deck` in `arena`, interning into `strings` (which
/// allocates with `gpa`). Drawn layers take ids ascending by name bytes;
/// derived layers follow in declaration order. `Malformed` for the first
/// contradiction: a name declared twice or used before it is declared, an
/// edge layer where polygons are wanted or the reverse, a text layer that is
/// not drawn, a rule or a `matching` statement naming a model no device (of
/// the coefficient's kind) declares, net spacing on a non-conductor, a
/// global layer also a conductor, a bad label row. The
/// parser refuses these with a location first; a source built in code meets
/// them here.
pub fn lower(arena: Allocator, gpa: Allocator, doc: *const DeckSource, strings: *StrTable, diag: *Diag) Error!Deck {
    const c: Ctx = .{ .arena = arena, .gpa = gpa, .strings = strings, .diag = diag };
    var layers = try buildLayers(c, doc.layers.items);
    // First: any later section may name a derived layer.
    for (doc.derived.items) |row| {
        if (layers.id(strings, row.name) != null) return c.malformed("layer {s} is declared twice", .{row.name});
        const operands = try arena.alloc(LayerId, row.layers.len);
        for (row.layers, operands) |name, *o| o.* = try c.layerOf(&layers, name, row.name);
        if (operands.len == 0) return c.malformed("layer {s}: an operation needs a layer", .{row.name});
        try checkOperands(c, &layers, row, operands);
        try layers.pushDerived(arena, try strings.intern(gpa, row.name), row.op, operands);
    }
    try layers.texts.appendSlice(arena, doc.texts.items);
    const texts = std.math.lossyCast(u32, doc.texts.items.len);
    for (doc.derived.items) |row| switch (row.op) {
        .with_text => |w| if (w.text >= texts) return c.malformed("layer {s}: its text pattern is missing", .{row.name}),
        else => {}, // else: only `with_text` names a text pattern here
    };
    // What the parser refuses, refused for a source built by hand too.
    var selections: usize = 0;
    for (doc.derived.items) |row| {
        const sel = switch (row.op) {
            .in_cells => |sel| sel,
            else => continue, // else: only `in_cells` selects by cell
        };
        selections += 1;
        const end = @addWithOverflow(sel.first, sel.count);
        if (end[1] != 0 or sel.count == 0 or end[0] > texts) return c.malformed("layer {s}: its cell-name patterns are missing", .{row.name});
        for (doc.texts.items[sel.first..end[0]]) |pattern| {
            if (pattern.len == 0 or std.mem.indexOfAny(u8, pattern, "[]{}\\") != null) {
                return c.malformed("layer {s}: a cell-name pattern is empty or holds `[`, `]`, `{{`, `}}` or `\\`", .{row.name});
            }
        }
    }
    if (selections > layers_mod.max_cell_selections) return c.malformed("a deck holds at most {d} cell selections", .{layers_mod.max_cell_selections});
    try layers.ignored.appendSlice(arena, doc.ignored.items);
    std.mem.sortUnstable([2]u16, layers.ignored.items, {}, lessPair);
    for (doc.rules.items) |rule| for (rule.params) |param| switch (param.value) {
        // A misspelt model would match no device and silently check nothing.
        // A `names` param (`net_type`'s net types) names no model.
        .model => |model| if (namesModels(rule.kind, param.name) and !declaresModel(doc, model)) {
            return c.malformed("rule {s}: model \"{s}\" is not declared by any device statement", .{ rule.id, model });
        },
        .value, .layer => {},
    };
    const rules = try buildRules(c, doc.rules.items, &layers);
    const connectivity = try buildConnectivity(c, &doc.connectivity, &layers);
    try checkNetted(c, doc, &layers, connectivity);
    var devices = try buildDevices(c, doc.devices.items, &layers);
    devices.netlist_scale_nm = doc.netlist_scale_nm;
    return lower_tables.finish(c, doc, layers, rules, connectivity, devices);
}

// ---- private ----

fn lessPair(_: void, a: [2]u16, b: [2]u16) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

/// Whether a model-typed parameter of `kind` names device models (it does
/// unless the kind declares it `names`).
fn namesModels(kind: []const u8, param: []const u8) bool {
    for (kinds.kinds) |k| {
        if (!std.mem.eql(u8, k.engine, kind)) continue;
        for (k.params) |p| if (std.mem.eql(u8, p.engine, param) and p.dim == .names) return false;
    }
    return true;
}

fn declaresModel(doc: *const DeckSource, model: []const u8) bool {
    for (doc.devices.items) |d| if (std.mem.eql(u8, d.model, model)) return true;
    return false;
}

/// Only a conductor's shapes carry a net: every layer of a spacing by net,
/// and the judged layer of a tag rule, is one, or (for `net_spacing`) is
/// derived from one, its shapes taking the nets of the conductor under them.
fn checkNetted(c: Ctx, doc: *const DeckSource, layers: *const LayerTable, connectivity: tables.Connectivity) Error!void {
    var from: std.ArrayList(LayerId) = .empty;
    for (doc.rules.items) |rule| {
        const k = rule.kind;
        const judged: []const []const u8 = if (eql(k, "net_spacing") or eql(k, "voltage_spacing") or eql(k, "dielectric_field"))
            rule.layers
        else if (eql(k, "hv_tag") or eql(k, "mixed_tag"))
            rule.layers[0..@min(1, rule.layers.len)]
        else
            &.{};
        for (judged) |name| {
            const id = try c.layerOf(layers, name, rule.id);
            from.clearRetainingCapacity();
            try from.append(c.arena, id);
            const netted = while (from.pop()) |next| {
                if (std.mem.indexOfScalar(LayerId, connectivity.conductors, next) != null) break true;
                if (eql(k, "net_spacing") and layers.isDerived(next)) try from.appendSlice(c.arena, layers.operands(next));
            } else false;
            if (!netted) return c.malformed("rule {s}: judges nets on {s}, which is not a conductor", .{ rule.id, name });
        }
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether a derived row's operands are of the kind its operation takes.
fn checkOperands(c: Ctx, layers: *const LayerTable, row: source.DerivedSource, operands: []const LayerId) Error!void {
    const edges = layers.isEdges(operands[0]);
    switch (row.op) {
        .@"and", .@"or", .not => for (operands) |o| {
            if (layers.isEdges(o) != edges) return c.malformed("layer {s}: cannot combine an edge layer with a polygon layer", .{row.name});
        },
        .part, .with_length, .oriented, .extended => if (!edges) return c.malformed("layer {s}: the operation needs an edge layer, not polygons", .{row.name}),
        .sized, .inside, .outside, .overlapping, .covering, .holes, .extents, .rectangles, .with_bbox, .with_rect, .edges, .with_area, .with_width, .with_text, .texts_outside => if (edges) return c.malformed("layer {s}: the operation needs a polygon layer, not edges", .{row.name}),
        .interacting, .in_cells => {},
    }
    const takes_argument = switch (row.op) {
        .@"and", .@"or", .not => false,
        else => true, // else: every other operation takes a layer argument, if any
    };
    if (takes_argument and operands.len > 1) {
        const argument = operands[1];
        if (layers.isEdges(argument)) return c.malformed("layer {s}: a layer argument is a polygon layer", .{row.name});
        if (row.op == .with_text and layers.isDerived(argument)) return c.malformed("layer {s}: text is drawn on a GDS layer, not a derived one", .{row.name});
    }
    if (row.op == .with_rect and (row.op.with_rect.w <= 0 or row.op.with_rect.h <= 0)) return c.malformed("layer {s}: a box has positive sides", .{row.name});
    // Texts are drawn on a GDS layer.
    if (row.op == .texts_outside and layers.isDerived(operands[0])) return c.malformed("layer {s}: text is drawn on a GDS layer, not a derived one", .{row.name});
    // A cell tag belongs to a drawn ring; a derived layer has none.
    if (row.op == .in_cells and (operands.len != 1 or layers.isDerived(operands[0]))) return c.malformed("layer {s}: a cell selection reads one drawn layer", .{row.name});
}

/// Drawn layers to a `LayerTable`, ids ascending by name bytes.
fn buildLayers(c: Ctx, declared: []const source.DrawnLayer) Error!LayerTable {
    const sorted = try c.arena.dupe(source.DrawnLayer, declared);
    std.mem.sortUnstable(source.DrawnLayer, sorted, {}, struct {
        fn less(_: void, a: source.DrawnLayer, b: source.DrawnLayer) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    if (sorted.len > 1) for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| {
        if (eql(a.name, b.name)) return c.malformed("layer {s} is declared twice", .{a.name});
    };
    const entries = try c.arena.alloc(LayerTable.Entry, sorted.len);
    for (sorted, entries) |s, *e| e.* = .{ .name = try c.strings.intern(c.gpa, s.name), .layer = s.stream[0], .datatype = s.stream[1] };
    return LayerTable.build(c.arena, entries);
}

/// The rules to a `RuleTable`, in deck order.
fn buildRules(c: Ctx, declared: []const source.RuleSource, layers: *const LayerTable) Error!tables.RuleTable {
    var spec: std.ArrayList(tables.RuleSpec) = .empty;
    var layer_ref: std.ArrayList(LayerId) = .empty;
    var param: std.ArrayList(tables.NamedValue) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (declared) |rule| {
        if ((try seen.getOrPut(c.arena, rule.id)).found_existing) return c.malformed("duplicate rule id `{s}`", .{rule.id});
        const id = try c.strings.intern(c.gpa, rule.id);
        // Which slots take edges: a kind not listed takes polygons only.
        const slots = kinds.edgeSlots(rule.kind);
        const layer_start = layer_ref.items.len;
        for (rule.layers, 0..) |name, at| {
            const layer = try c.layerOf(layers, name, rule.id);
            const edges = layers.isEdges(layer);
            const want: ?bool = if (at < slots.len) slots[at] else false;
            if (want) |w| if (w != edges) {
                const want_text = if (w) "an edge layer" else "a polygon layer";
                const got_text = if (w) "polygons" else "edges";
                return c.malformed("rule {s}: {s} here takes {s}; {s} is {s}", .{ rule.id, rule.kind, want_text, name, got_text });
            };
            try layer_ref.append(c.arena, layer);
        }
        const param_start = param.items.len;
        for (rule.params) |stated| {
            const value: tables.ParamValue = switch (stated.value) {
                .value => |v| v,
                .layer => |name| blk: {
                    const layer = try c.layerOf(layers, name, rule.id);
                    if (layers.isEdges(layer)) return c.malformed("rule {s}: parameter {s} takes a polygon layer", .{ rule.id, stated.name });
                    break :blk .{ .layer = layer };
                },
                .model => |model| .{ .model = try c.strings.intern(c.gpa, model) },
            };
            try param.append(c.arena, .{ .name = try c.strings.intern(c.gpa, stated.name), .value = value });
        }
        try spec.append(c.arena, .{
            .id = id,
            .kind = try c.strings.intern(c.gpa, rule.kind),
            .layer_start = @intCast(layer_start),
            .layer_len = @intCast(layer_ref.items.len - layer_start),
            .param_start = @intCast(param_start),
            .param_len = @intCast(param.items.len - param_start),
        });
    }
    return .{ .spec = spec.items, .layer_ref = layer_ref.items, .param = param.items };
}

/// A connect statement's layer: declared, and not an edge layer.
fn connectLayer(c: Ctx, layers: *const LayerTable, name: []const u8) Error!LayerId {
    const layer = try c.layerOf(layers, name, "connect");
    if (layers.isEdges(layer)) return c.malformed("connect: {s} is an edge layer, which carries no net", .{name});
    return layer;
}

/// Connectivity, layers resolved; a label row names a drawn layer and a
/// conductor.
fn buildConnectivity(c: Ctx, declared: *const source.ConnectivitySource, layers: *const LayerTable) Error!tables.Connectivity {
    const conductors = try c.arena.alloc(LayerId, declared.conductors.items.len);
    for (declared.conductors.items, conductors) |n, *l| l.* = try connectLayer(c, layers, n);
    const global = try c.arena.alloc(LayerId, declared.global.items.len);
    for (declared.global.items, global) |n, *l| l.* = try connectLayer(c, layers, n);
    const via_cut = try c.arena.alloc(LayerId, declared.vias.items.len);
    const via_connects = try c.arena.alloc([2]LayerId, declared.vias.items.len);
    for (declared.vias.items, via_cut, via_connects) |via, *cut, *joins| {
        cut.* = try connectLayer(c, layers, via.layer);
        joins.* = .{ try connectLayer(c, layers, via.connects[0]), try connectLayer(c, layers, via.connects[1]) };
    }
    for (declared.global.items, global) |name, g| {
        if (std.mem.indexOfScalar(LayerId, conductors, g) != null) return c.malformed("connect global {s}: a global layer is net-only, not a conductor", .{name});
    }
    const label_layer = try c.arena.alloc(LayerId, declared.labels.items.len);
    const label_names = try c.arena.alloc(LayerId, declared.labels.items.len);
    for (declared.labels.items, label_layer, label_names) |label, *text_layer, *named| {
        const names = try connectLayer(c, layers, label.names);
        // Fail closed here rather than at run time, where nothing can say
        // which deck row was wrong.
        if (std.mem.indexOfScalar(LayerId, conductors, names) == null) return c.malformed("connect label {s} names {s}, which is not a conductor", .{ label.layer, label.names });
        const text = try connectLayer(c, layers, label.layer);
        // A `TEXT` record carries a stream pair and a derived layer has none.
        if (layers.isDerived(text)) return c.malformed("connect label {s}: a derived layer carries no text records", .{label.layer});
        text_layer.* = text;
        named.* = names;
    }
    return .{
        .conductors = conductors,
        .via_cut = via_cut,
        .via_connects = via_connects,
        .intra_layer_touch = declared.intra_layer_touch,
        .global = global,
        .label_layer = label_layer,
        .label_names = label_names,
    };
}

/// Device recognisers as CSR; terminal order is the role.
fn buildDevices(c: Ctx, declared: []const source.DeviceSource, layers: *const LayerTable) Error!tables.DeviceRecognition {
    // Sentinel included only with a device: `[0]` would claim a row.
    if (declared.len == 0) return .{};
    var kind: std.ArrayList(tables.DeviceKind) = .empty;
    var marker: std.ArrayList(LayerId) = .empty;
    var terminal_start: std.ArrayList(u32) = .empty;
    var terminal: std.ArrayList(LayerId) = .empty;
    var model: std.ArrayList(StrId) = .empty;
    var value: std.ArrayList(tables.DeviceValue) = .empty;
    try terminal_start.append(c.arena, 0);
    for (declared) |device| {
        const user = try std.fmt.allocPrint(c.arena, "device {s}", .{device.model});
        const m = try devicePolygons(c, layers, device.marker, user);
        for (device.terminals) |name| try terminal.append(c.arena, try devicePolygons(c, layers, name, user));
        try kind.append(c.arena, device.kind);
        try marker.append(c.arena, m);
        try model.append(c.arena, try c.strings.intern(c.gpa, device.model));
        try terminal_start.append(c.arena, @intCast(terminal.items.len));
        try value.append(c.arena, device.value);
    }
    return .{ .kind = kind.items, .marker = marker.items, .terminal_start = terminal_start.items, .terminal = terminal.items, .model = model.items, .value = value.items };
}

fn devicePolygons(c: Ctx, layers: *const LayerTable, name: []const u8, user: []const u8) Error!LayerId {
    const layer = try c.layerOf(layers, name, user);
    if (layers.isEdges(layer)) return c.malformed("{s}: {s} is an edge layer, not a device's shapes", .{ user, name });
    return layer;
}
