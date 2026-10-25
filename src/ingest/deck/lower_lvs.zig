//! The `lvs` statements by name → `LvsControls` by id. A control on a model
//! no `device` statement declares is refused: it would change nothing,
//! silently. Models are interned in statement-kind order (permute, ignore,
//! ignore_shorted, supply, connect_explicit, thresholds, lde, count,
//! same_nets, range, asymmetric, ignore_parameter, tolerance), as Rust does.
//! Ported from crates/ingest/src/deck/mod.rs (`build_lvs`).
//!
//! Contents:
//! - `pub fn buildLvs(c: Ctx, declared: *const LvsSrc, devices: []const DeviceSource, layers: *const LayerTable) Error!LvsControls`

const std = @import("std");
const geom = @import("geom");
const StrId = geom.StrId;
const tables = @import("tables.zig");
const LvsControls = tables.LvsControls;
const LayerTable = @import("layers.zig").LayerTable;
const source = @import("source.zig");
const LvsSrc = source.LvsSrc;
const DeviceSource = source.DeviceSource;
const Error = @import("diagnostic.zig").Error;
const Ctx = @import("lower.zig").Ctx;
const globMatches = @import("../glob.zig").globMatches;

/// Resolves the `lvs` statements against the deck's devices and layers.
pub fn buildLvs(c: Ctx, declared: *const LvsSrc, devices: []const DeviceSource, layers: *const LayerTable) Error!LvsControls {
    var lvs: LvsControls = .{ .default_tolerance = declared.default_tolerance };
    const permute = try c.arena.alloc(tables.Permute, declared.permute.items.len);
    for (declared.permute.items, permute) |row, *out| {
        try known(c, devices, row.model, "permute");
        const kind = kindOf(devices, row.model);
        const names = tables.pinNames(kind);
        const a = try pinPosition(c, names, row.model, row.a);
        const b = try pinPosition(c, names, row.model, row.b);
        if (a == b) return c.malformed("lvs permute: \"{s}\" permutes `{s}` with itself", .{ row.model, names[a] });
        const channel = kind == .mos and @min(a, b) == 1 and @max(a, b) == 2;
        if (channel and contains(declared.asymmetric.items, row.model)) return c.malformed("lvs permute: \"{s}\" is asymmetric, so its source and drain do not permute", .{row.model});
        out.* = .{ .model = try c.strings.intern(c.gpa, row.model), .a = a, .b = b };
    }
    lvs.permute = permute;
    lvs.ignore = try internAll(c, declared.ignore.items);
    lvs.ignore_shorted = try internAll(c, declared.ignore_shorted.items);
    lvs.ports_by_name = declared.ports_by_name;
    lvs.recognize_gates = declared.recognize_gates;
    for (declared.blackbox.items) |pattern| {
        // A model is a device by its recogniser; one also boxed would be two
        // things on the reference side.
        for (devices) |d| if (globMatches(pattern, d.model)) {
            return c.malformed("lvs blackbox: \"{s}\" matches the device model \"{s}\"; a model is compared as its device statement says", .{ pattern, d.model });
        };
    }
    lvs.blackbox = declared.blackbox.items;
    lvs.filter_unused = declared.filter_unused.items;
    if (std.mem.indexOfScalar(tables.UnusedFilter, lvs.filter_unused, .c) != null and declared.supply.items.len == 0) {
        return c.malformed("lvs filter_unused c holds a gate to the supply nets, and no lvs supply names one", .{});
    }
    lvs.supply = try internAll(c, declared.supply.items);
    lvs.relaxed = declared.topology == true;
    lvs.connect_implicit = declared.connect_implicit.items;
    const explicit = try c.arena.alloc([]const StrId, declared.connect_explicit.items.len);
    for (declared.connect_explicit.items, explicit) |group, *out| out.* = try internAll(c, group);
    lvs.connect_explicit = explicit;
    lvs.max_res = declared.max_res;
    lvs.min_caps = declared.min_caps;
    // A threshold is held to the value LVS computes from the drawing, which
    // it computes only under an interned name.
    if (lvs.max_res != null) _ = try c.strings.intern(c.gpa, "r");
    if (lvs.min_caps != null) _ = try c.strings.intern(c.gpa, "c");
    const lde = try c.arena.alloc(tables.LvsLde, declared.lde.items.len);
    for (declared.lde.items, lde) |row, *out| {
        try known(c, devices, row.model, "lde");
        if (notMos(devices, row.model)) return c.malformed("lvs lde: \"{s}\" is not a mos device; layout-dependent effects are a transistor's", .{row.model});
        const od = try ldeLayer(c, layers, row.model, row.od);
        const well: ?tables.LdeWell = if (row.well) |w| .{ .layer = try ldeLayer(c, layers, row.model, w.layer), .scref = w.scref } else null;
        out.* = .{ .model = try c.strings.intern(c.gpa, row.model), .od = od, .max = row.max, .well = well };
    }
    lvs.lde = lde;
    const count = try c.arena.alloc(tables.LvsCount, declared.count.items.len);
    for (declared.count.items, count) |row, *out| {
        try known(c, devices, row.model, "count");
        out.* = .{ .model = try c.strings.intern(c.gpa, row.model), .min = row.min, .max = row.max };
    }
    lvs.count = count;
    const same_nets = try c.arena.alloc(tables.SameNets, declared.same_nets.items.len);
    for (declared.same_nets.items, same_nets) |row, *out| {
        const layout = try c.strings.intern(c.gpa, row.a);
        out.* = .{ .layout = layout, .reference = try c.strings.intern(c.gpa, row.b) };
    }
    lvs.same_nets = same_nets;
    const range = try c.arena.alloc(tables.LvsRange, declared.range.items.len);
    for (declared.range.items, range) |row, *out| {
        try known(c, devices, row.model, "range");
        const model = try c.strings.intern(c.gpa, row.model);
        out.* = .{ .model = model, .param = try c.strings.intern(c.gpa, row.param), .min = row.min, .max = row.max };
    }
    lvs.range = range;
    const asymmetric = try c.arena.alloc(StrId, declared.asymmetric.items.len);
    for (declared.asymmetric.items, asymmetric) |model, *out| {
        try known(c, devices, model, "asymmetric");
        if (notMos(devices, model)) return c.malformed("lvs asymmetric: \"{s}\" is not a mos device; only a transistor has a source and a drain", .{model});
        out.* = try c.strings.intern(c.gpa, model);
    }
    lvs.asymmetric = asymmetric;
    const ignore_parameter = try c.arena.alloc(tables.ModelParam, declared.ignore_parameter.items.len);
    for (declared.ignore_parameter.items, ignore_parameter) |row, *out| {
        try known(c, devices, row.a, "ignore_parameter");
        for (declared.tolerance.items) |t| if (std.mem.eql(u8, t.model, row.a) and std.mem.eql(u8, t.param, row.b)) {
            return c.malformed("lvs tolerance: `{s}` of \"{s}\" is ignored, so a tolerance on it means nothing", .{ t.param, t.model });
        };
        const model = try c.strings.intern(c.gpa, row.a);
        out.* = .{ .model = model, .param = try c.strings.intern(c.gpa, row.b) };
    }
    lvs.ignore_parameter = ignore_parameter;
    const tolerance = try c.arena.alloc(tables.LvsTolerance, declared.tolerance.items.len);
    for (declared.tolerance.items, tolerance) |row, *out| {
        try known(c, devices, row.model, "tolerance");
        const to_si = if (tables.absoluteUnit(row.param)) |u| u.to_si else 1.0;
        const model = try c.strings.intern(c.gpa, row.model);
        out.* = .{ .model = model, .param = try c.strings.intern(c.gpa, row.param), .relative = row.relative, .absolute = row.absolute * to_si, .stated = row.absolute };
    }
    lvs.tolerance = tolerance;
    return lvs;
}

// ---- private ----

fn known(c: Ctx, devices: []const DeviceSource, model: []const u8, control: []const u8) Error!void {
    for (devices) |d| if (std.mem.eql(u8, d.model, model)) return;
    return c.malformed("lvs {s}: model \"{s}\" is not declared by any device statement", .{ control, model });
}

fn kindOf(devices: []const DeviceSource, model: []const u8) tables.DeviceKind {
    for (devices) |d| if (std.mem.eql(u8, d.model, model)) return d.kind;
    return .mos;
}

fn notMos(devices: []const DeviceSource, model: []const u8) bool {
    for (devices) |d| if (std.mem.eql(u8, d.model, model) and d.kind != .mos) return true;
    return false;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e, item)) return true;
    return false;
}

fn pinPosition(c: Ctx, names: []const []const u8, model: []const u8, pin: []const u8) Error!u8 {
    for (names, 0..) |n, at| if (std.mem.eql(u8, n, pin)) return @intCast(at);
    const joined = try std.mem.join(c.arena, ", ", names);
    return c.malformed("lvs permute: \"{s}\" has no pin `{s}`; its pins are {s}", .{ model, pin, joined });
}

fn internAll(c: Ctx, names: []const []const u8) Error![]const StrId {
    const out = try c.arena.alloc(StrId, names.len);
    for (names, out) |n, *o| o.* = try c.strings.intern(c.gpa, n);
    return out;
}

fn ldeLayer(c: Ctx, layers: *const LayerTable, model: []const u8, name: []const u8) Error!StrId {
    if (layers.id(c.strings, name) == null) return c.malformed("lvs lde \"{s}\": unknown layer {s}", .{ model, name });
    return c.strings.intern(c.gpa, name);
}
