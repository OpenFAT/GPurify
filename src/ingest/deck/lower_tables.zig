//! The lowering's second half: once layers, rules, connectivity and devices
//! are resolved, the parasitic stack and its corners, the stages, waivers,
//! boundary, `lvs` controls and the cold models → the finished `Deck`.
//! Ported from crates/ingest/src/deck/source.rs (`build_stack`,
//! `temperature_factor`, `build_corners`, `build_stages`, `check_pex_models`,
//! `check_edits`, the tail of `lower`) and mod.rs (`build_lvs`).
//!
//! Contents:
//! - `pub fn finish(c: Ctx, doc: *const DeckSource, layers: LayerTable, rules: tables.RuleTable, connectivity: tables.Connectivity, devices: tables.DeviceRecognition) Error!Deck`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const tables = @import("tables.zig");
const Deck = tables.Deck;
const LayerTable = @import("layers.zig").LayerTable;
const source = @import("source.zig");
const DeckSource = source.DeckSource;
const Error = @import("diagnostic.zig").Error;
const Ctx = @import("lower.zig").Ctx;
const lower_lvs = @import("lower_lvs.zig");

/// Lowers what follows the devices and assembles the deck, in Rust's order.
pub fn finish(c: Ctx, doc: *const DeckSource, layers: LayerTable, rules: tables.RuleTable, connectivity: tables.Connectivity, devices: tables.DeviceRecognition) Error!Deck {
    const stack = try buildStack(c, doc, &layers);
    const corners = try buildCorners(c, doc, stack, &layers);
    const stages = try buildStages(c, doc);
    const waivers = try buildWaivers(c, doc, &layers);
    const boundary: ?LayerId = if (doc.boundary) |name| blk: {
        const layer = try c.layerOf(&layers, name, "boundary");
        if (layers.isDerived(layer)) return c.malformed("boundary {s}: a derived layer; the die outline is drawn", .{name});
        break :blk layer;
    } else null;
    const lvs = try lower_lvs.buildLvs(c, &doc.lvs, doc.devices.items, &layers);
    const temperature_law: ?tables.TemperatureLaw = if (doc.temperature) |t| blk: {
        const rows = try c.arena.alloc(tables.TemperatureRow, doc.pex.items.len);
        for (doc.pex.items, rows) |pex, *row| {
            // `buildStack` refused a row without coefficients.
            const tc = pex.row.tc orelse .{ 0, 0 };
            row.* = .{ .layer = try c.layerOf(&layers, pex.layer, "pex"), .sheet_ohm_sq = pex.row.sheet_res_ohm_sq, .tc1 = tc[0], .tc2 = tc[1] };
        }
        break :blk .{ .operating_k = t.operating_k, .nominal_k = t.nominal_k, .rows = rows };
    } else null;
    try checkPexModels(c, &doc.pex_models, &layers, connectivity);
    try checkEdits(c, &doc.edits, &layers);
    for (doc.pex_models.device.items, 0..) |device, at| {
        const mos = for (doc.devices.items) |d| {
            if (std.mem.eql(u8, d.model, device.model) and d.kind == .mos) break true;
        } else false;
        if (!mos) return c.malformed("pex_device \"{s}\": no `device mos` statement has that model", .{device.model});
        for (doc.pex_models.device.items[0..at]) |d| if (std.mem.eql(u8, d.model, device.model)) return c.malformed("pex_device \"{s}\": stated twice", .{device.model});
    }
    return .{
        .layers = layers,
        .rules = rules,
        .connectivity = connectivity,
        .devices = devices,
        .stack = stack,
        .temperature = if (doc.temperature) |t| .{ .raw = t.operating_k } else null,
        .temperature_law = temperature_law,
        .lvs = lvs,
        .extraction = doc.extraction orelse .{},
        .corners = corners,
        .stages = stages,
        .waivers = waivers,
        .boundary = boundary,
        .pex_models = doc.pex_models,
        .edits = doc.edits,
        .reports = doc.reports,
    };
}

// ---- private ----

/// A waiver for a rule the deck does not have would waive nothing, silently.
fn buildWaivers(c: Ctx, doc: *const DeckSource, layers: *const LayerTable) Error![]const tables.Waiver {
    for (doc.waivers.items, 0..) |w, at| {
        const known = for (doc.rules.items) |r| {
            if (std.mem.eql(u8, r.id, w.rule)) break true;
        } else false;
        if (!known) return c.malformed("waive {s}: no rule of the deck has that id", .{w.rule});
        for (doc.waivers.items[0..at]) |e| {
            if (std.mem.eql(u8, e.rule, w.rule) and std.mem.eql(u8, e.layer, w.layer)) return c.malformed("waive {s}: {s} is stated twice", .{ w.rule, w.layer });
        }
    }
    const out = try c.arena.alloc(tables.Waiver, doc.waivers.items.len);
    for (doc.waivers.items, out) |w, *o| {
        const user = try std.fmt.allocPrint(c.arena, "waive {s}", .{w.rule});
        const layer = try c.layerOf(layers, w.layer, user);
        o.* = .{ .rule = try c.strings.intern(c.gpa, w.rule), .layer = layer };
    }
    return out;
}

/// The models, checked: each `pex_tsv` a via cut once, each substrate port
/// and `pex_fill` layer a conductor, each fill layer once.
fn checkPexModels(c: Ctx, models: *const tables.PexModels, layers: *const LayerTable, connectivity: tables.Connectivity) Error!void {
    for (models.tsv.items, 0..) |tsv, at| {
        const id = try c.layerOf(layers, tsv.layer, "pex_tsv");
        if (std.mem.indexOfScalar(LayerId, connectivity.via_cut, id) == null) return c.malformed("pex_tsv {s}: not a `connect via` cut layer", .{tsv.layer});
        for (models.tsv.items[0..at]) |e| if (std.mem.eql(u8, e.layer, tsv.layer)) return c.malformed("pex_tsv {s}: stated twice", .{tsv.layer});
    }
    if (models.substrate) |s| for (s.ports) |layer| {
        const id = try c.layerOf(layers, layer, "pex_substrate");
        if (std.mem.indexOfScalar(LayerId, connectivity.conductors, id) == null) return c.malformed("pex_substrate port {s}: not a `connect conductors` layer, so it holds no net", .{layer});
    };
    for (models.fill.items, 0..) |fill, at| {
        const id = try c.layerOf(layers, fill.layer, "pex_fill");
        if (std.mem.indexOfScalar(LayerId, connectivity.conductors, id) == null) return c.malformed("pex_fill {s}: not a `connect conductors` layer, so it holds no net", .{fill.layer});
        for (models.fill.items[0..at]) |e| if (std.mem.eql(u8, e.layer, fill.layer)) return c.malformed("pex_fill {s}: stated twice", .{fill.layer});
    }
}

/// The edits, checked: every layer named is the deck's, and the layers an
/// edit draws on are drawn layers.
fn checkEdits(c: Ctx, edits: *const tables.Edits, layers: *const LayerTable) Error!void {
    for (edits.fill.items) |fill| {
        try drawnLayer(c, layers, fill.layer, "fill");
        _ = try c.layerOf(layers, fill.density, "fill");
        for (fill.avoid) |layer| _ = try c.layerOf(layers, layer, "fill");
    }
    for (edits.widen.items) |widen| try drawnLayer(c, layers, widen.layer, "widen");
}

fn drawnLayer(c: Ctx, layers: *const LayerTable, name: []const u8, what: []const u8) Error!void {
    const id = try c.layerOf(layers, name, what);
    if (layers.isDerived(id)) return c.malformed("{s} {s}: a derived layer, which a layout cannot draw on", .{ what, name });
}

/// The stages, each rule id resolved to its stage.
fn buildStages(c: Ctx, doc: *const DeckSource) Error!tables.Stages {
    var names: std.ArrayList(StrId) = .empty;
    var of_rule: std.ArrayList(tables.StageOf) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (doc.stages.items, 0..) |stage, at| {
        for (doc.stages.items[0..at]) |e| if (std.mem.eql(u8, e.name, stage.name)) return c.malformed("stage {s} is stated twice", .{stage.name});
        if (at > std.math.maxInt(u16)) return c.malformed("a deck has at most 65535 stages", .{});
        try names.append(c.arena, try c.strings.intern(c.gpa, stage.name));
        for (stage.rules.items) |id| {
            if (seen.contains(id)) return c.malformed("stage {s}: rule {s} is already in a stage", .{ stage.name, id });
            const known = for (doc.rules.items) |r| {
                if (std.mem.eql(u8, r.id, id)) break true;
            } else false;
            if (!known) return c.malformed("stage {s}: no rule {s}", .{ stage.name, id });
            try seen.put(c.arena, id, {});
            try of_rule.append(c.arena, .{ .rule = try c.strings.intern(c.gpa, id), .stage = @intCast(at) });
        }
    }
    return .{ .name = names.items, .of_rule = of_rule.items };
}

/// The PEX stack, a column per parameter indexed by `LayerId`, each row's
/// sheet resistance moved from nominal to the operating temperature.
fn buildStack(c: Ctx, doc: *const DeckSource, layers: *const LayerTable) Error!tables.ProcessStack {
    if (doc.pex.items.len == 0) return .{};
    const stack = try zeroStack(c.arena, layers.len());
    for (doc.pex.items) |pex| {
        const name = try std.fmt.allocPrint(c.arena, "pex {s}", .{pex.layer});
        const factor = try temperatureFactor(c, name, doc.temperature, pex.row.tc);
        const at = @backingInt(try c.layerOf(layers, pex.layer, "pex"));
        stack.thickness_nm[at] = pex.row.thickness_nm;
        stack.height_nm[at] = pex.row.height_nm;
        stack.sheet_res_ohm_sq[at] = pex.row.sheet_res_ohm_sq * factor;
        stack.area_cap_af_um2[at] = pex.row.area_cap_af_um2;
        stack.fringe_cap_af_um[at] = pex.row.fringe_cap_af_um;
        stack.dielectric_k[at] = pex.row.dielectric_k;
    }
    return stack;
}

fn zeroStack(arena: Allocator, rows: usize) Allocator.Error!tables.ProcessStack {
    var stack: tables.ProcessStack = undefined;
    inline for (.{ "thickness_nm", "height_nm", "sheet_res_ohm_sq", "area_cap_af_um2", "fringe_cap_af_um", "dielectric_k" }) |f| {
        @field(stack, f) = try arena.alloc(f64, rows);
        @memset(@field(stack, f), 0);
    }
    return stack;
}

fn cloneStack(arena: Allocator, s: tables.ProcessStack) Allocator.Error!tables.ProcessStack {
    var out: tables.ProcessStack = undefined;
    inline for (.{ "thickness_nm", "height_nm", "sheet_res_ohm_sq", "area_cap_af_um2", "fringe_cap_af_um", "dielectric_k" }) |f| {
        @field(out, f) = try arena.dupe(f64, @field(s, f));
    }
    return out;
}

/// The factor `1 + tc1·ΔT + tc2·ΔT²` (the ngspice resistor law) moving a
/// sheet resistance stated at nominal to the operating temperature; 1
/// without a temperature. Refuses coefficients without a temperature, a
/// temperature without coefficients, and a factor that is not positive.
fn temperatureFactor(c: Ctx, name: []const u8, temperature: ?source.Temperature, tc: ?[2]f64) Error!f64 {
    const t = temperature orelse {
        if (tc == null) return 1.0;
        return c.malformed("{s}: tc1 and tc2 need a `temperature` statement to say how far from nominal the run is", .{name});
    };
    const coefficients = tc orelse return c.malformed("{s}: the deck states a temperature, so the row needs tc1 and tc2 (0/K and 0/K2 for a resistance that does not vary)", .{name});
    const delta = t.operating_k - t.nominal_k;
    const factor = 1.0 + coefficients[0] * delta + coefficients[1] * delta * delta;
    if (std.math.isFinite(factor) and factor > 0.0) return factor;
    return c.malformed("{s}: tc1 and tc2 scale its resistance by {d} at the deck's temperature; a resistance stays positive", .{ name, factor });
}

/// Each corner's stack: the nominal one with the corner's stated values in
/// place, corners in the order the deck first names them; a corner's
/// `sheet` moves to the operating temperature by its own `tc1`/`tc2` where
/// it gives both, else by the row's.
fn buildCorners(c: Ctx, doc: *const DeckSource, nominal: tables.ProcessStack, layers: *const LayerTable) Error![]const tables.ProcessCorner {
    var corners: std.ArrayList(tables.ProcessCorner) = .empty;
    var stated: std.ArrayList(std.ArrayList(tables.CornerStated)) = .empty;
    for (doc.corners.items) |line| {
        const name = try std.fmt.allocPrint(c.arena, "corner {s} {s}", .{ line.corner, line.layer });
        const base = for (doc.pex.items) |pex| {
            if (std.mem.eql(u8, pex.layer, line.layer)) break pex.row;
        } else return c.malformed("corner {s}: layer {s} has no pex row to vary", .{ line.corner, line.layer });
        const any = for (line.values) |v| {
            if (v != null) break true;
        } else false;
        if (!any) return c.malformed("{s}: states nothing", .{name});
        const at = for (corners.items, 0..) |corner, i| {
            if (std.mem.eql(u8, c.strings.resolve(corner.name), line.corner)) break i;
        } else blk: {
            try corners.append(c.arena, .{ .name = try c.strings.intern(c.gpa, line.corner), .stack = try cloneStack(c.arena, nominal), .stated = &.{} });
            try stated.append(c.arena, .empty);
            break :blk corners.items.len - 1;
        };
        const layer = try c.layerOf(layers, line.layer, name);
        for (stated.items[at].items) |s| if (s.layer == layer) return c.malformed("{s}: the layer is stated twice", .{name});
        try stated.items[at].append(c.arena, .{ .layer = layer, .values = line.values });
        const stack = corners.items[at].stack;
        const row = @backingInt(layer);
        const columns = [_][]f64{ stack.thickness_nm, stack.height_nm, stack.sheet_res_ohm_sq, stack.dielectric_k, stack.area_cap_af_um2, stack.fringe_cap_af_um };
        for (columns, line.values[0..6]) |column, value| if (value) |v| {
            column[row] = v;
        };
        const tc: ?[2]f64 = if (line.values[6] != null and line.values[7] != null)
            .{ line.values[6].?, line.values[7].? }
        else if (line.values[6] == null and line.values[7] == null)
            base.tc
        else
            return c.malformed("{s}: gives one of tc1 and tc2; give both, or neither", .{name});
        stack.sheet_res_ohm_sq[row] = (line.values[2] orelse base.sheet_res_ohm_sq) * try temperatureFactor(c, name, doc.temperature, tc);
    }
    for (corners.items, stated.items) |*corner, s| corner.stated = s.items;
    return corners.items;
}
