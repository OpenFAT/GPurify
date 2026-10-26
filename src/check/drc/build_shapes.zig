//! The deck builders of the shape kinds that need more than a line: lists,
//! side tables and variants (`mean_critical_area`, `dfm_score`,
//! `pattern_match`, `angle`, `must_contain`, `cut_class`, `allowed_width`,
//! `min_step`, `min_step_adjacent`). In: one row's `Ctx`. Out: its `Rule`,
//! side tables filed into the set. Ported from the matching arms of
//! crates/check/src/drc/ruleset.rs `RuleSet::from_deck`.
//!
//! Contents:
//! - `pub fn meanCriticalArea(c: Ctx) Error!Rule`, `dfmScore`, `patternMatch`, `angle`, `mustContain`,
//!   `cutClass`, `allowedWidth`, `minStep`, `minStepAdjacent`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Rule = @import("rows.zig").Rule;
const params = @import("params.zig");
const Error = params.Error;
const Ctx = @import("compile.zig").Ctx;
const pattern = @import("pattern.zig");

pub fn meanCriticalArea(c: Ctx) Error!Rule {
    const layer = try c.r.one();
    const sizes: @import("tables.zig").DefectSizes = .{ .radius = try c.r.list(.length, "radii"), .weight = try c.r.list(.ratio, "weights") };
    if (!sizes.isValid()) return c.r.badTable();
    const index = try c.rs.addDefectSizes(c.gpa, sizes);
    return .{ .mean_critical_area = .{ .layer = layer, .sizes = index, .limit = try c.r.area("limit") } };
}

pub fn dfmScore(c: Ctx) Error!Rule {
    const r = c.r;
    const check: @import("rows.zig").DfmCheck = switch (try r.count("check", 2)) {
        0 => .space,
        1 => .width,
        else => .enclosure,
    };
    const outer = if (check == .enclosure) blk: {
        try r.layerCount(2);
        break :blk r.layer(1);
    } else blk: {
        try r.layerCount(1);
        break :blk null;
    };
    const required = try r.length("required");
    const recommended = try r.length("recommended");
    if (required >= recommended) return r.badTable();
    return .{ .dfm_score = .{
        .check = check,
        .layer = r.layer(0),
        .outer = outer,
        .required = required,
        .recommended = recommended,
        .rate = try r.ratio("rate"),
        .limit = try r.ratio("limit"),
    } };
}

pub fn patternMatch(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const window: [2]Dbu = .{ try r.length("window_w"), try r.length("window_h") };
    const shapes = try boxes(c, "shape_x", "shape_y");
    const ignore = try boxes(c, "ignore_x", "ignore_y");
    const valid = pattern.isValid(c.gpa, window, shapes, ignore) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    if (!valid) return r.badTable();
    try c.rs.pattern_window.append(c.gpa, window);
    _ = try c.rs.pattern_shapes.push(c.gpa, shapes);
    const index = try c.rs.pattern_ignore.push(c.gpa, ignore);
    return .{ .pattern_match = .{ .layer = layer, .pattern = index } };
}

pub fn angle(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = if (r.spec.layer_len == 0) null else try r.one();
    var allowed: u8 = 0;
    for (try r.list(.count, "angle")) |stated| {
        const degrees: i32 = @intCast(stated % 360);
        if (@mod(degrees, 45) != 0) {
            r.diag.* = .{ .rule = r.spec.id, .kind = r.spec.kind, .degrees = degrees };
            return error.UnrepresentableAngle;
        }
        allowed |= @as(u8, 1) << @intCast(@divTrunc(@mod(degrees, 180), 45));
    }
    if (allowed == 0) return r.fail(error.MissingParam, "angle");
    return .{ .angle = .{ .layer = layer, .allowed = allowed } };
}

pub fn mustContain(c: Ctx) Error!Rule {
    const r = c.r;
    const l = try r.two();
    // `==` states `count`, `>=` `min_count`, `<=` `max_count`.
    const max = std.math.maxInt(u32);
    const exact: ?u32 = if (r.stated("count")) try r.count("count", max) else null;
    const min_count: ?u32 = exact orelse if (r.stated("min_count")) try r.count("min_count", max) else null;
    const max_count: ?u32 = exact orelse if (r.stated("max_count")) try r.count("max_count", max) else null;
    if (min_count == null and max_count == null) return r.fail(error.MissingParam, "min_count");
    return .{ .must_contain = .{ .outer = l[0], .inner = l[1], .min_count = min_count orelse 0, .max_count = max_count orelse max } };
}

pub fn cutClass(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const widths = try positiveLengths(r, "width");
    const heights = try positiveLengths(r, "height");
    if (widths.len == 0 or widths.len != heights.len) return r.fail(error.MissingParam, "allowed");
    const classes = try r.scratch.alloc([2]Dbu, widths.len);
    for (classes, widths, heights) |*k, w, h| k.* = .{ @min(w, h), @max(w, h) };
    std.mem.sortUnstable([2]Dbu, classes, {}, lessPair);
    const index = try c.rs.classes.push(c.gpa, dedup([2]Dbu, classes));
    return .{ .cut_class = .{ .layer = layer, .classes = index } };
}

pub fn allowedWidth(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const widths = r.list(.length, "width") catch |e| return if (e == error.WrongParamType) r.fail(error.WrongParamType, "allowed") else e;
    for (widths) |w| if (w <= 0) return r.nonPositive(w);
    if (widths.len == 0) return r.fail(error.MissingParam, "allowed");
    std.mem.sortUnstable(Dbu, widths, {}, std.sort.asc(Dbu));
    const index = try c.rs.widths.push(c.gpa, dedup(Dbu, widths));
    return .{ .allowed_width = .{ .layer = layer, .widths = index, .open_last = try r.optFlag("open_last") } };
}

pub fn minStep(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const limit = try r.length("limit");
    const kind: @import("rows.zig").StepKind = if (r.stated("max_edges"))
        .{ .max_edges = @intCast(try r.count("max_edges", std.math.maxInt(u16))) }
    else switch (try r.count("corner", 2)) {
        0 => .outside_corner,
        1 => .inside_corner,
        else => .step,
    };
    return .{ .min_step = .{ .layer = layer, .limit = limit, .kind = kind, .length_sum = try r.optLength("length_sum") } };
}

pub fn minStepAdjacent(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const limit = try r.length("limit");
    const neighbour: @import("rows.zig").StepNeighbour = if (r.stated("between_eol"))
        .{ .between_eol = try r.length("between_eol") }
    else
        .{ .adjacent = .{
            .length = try r.length("adjacent"),
            .eol = try r.optLength("adjacent_eol"),
            .except_rectangle = try r.flag("except_rectangle"),
        } };
    return .{ .min_step_adjacent = .{ .layer = layer, .limit = limit, .neighbour = neighbour } };
}

// ---- private ----

/// Rectangles by two opposite corners each, in order, in scratch.
fn boxes(c: Ctx, xs_name: []const u8, ys_name: []const u8) Error![]Bbox {
    const xs = try c.r.list(.length, xs_name);
    const ys = try c.r.list(.length, ys_name);
    if (xs.len != ys.len or xs.len % 2 != 0) return c.r.badTable();
    const out = try c.r.scratch.alloc(Bbox, xs.len / 2);
    for (out, 0..) |*b, k| b.* = .{
        .xlo = @min(xs[2 * k], xs[2 * k + 1]),
        .ylo = @min(ys[2 * k], ys[2 * k + 1]),
        .xhi = @max(xs[2 * k], xs[2 * k + 1]),
        .yhi = @max(ys[2 * k], ys[2 * k + 1]),
    };
    return out;
}

fn positiveLengths(r: params.Reader, param: []const u8) Error![]Dbu {
    const values = try r.list(.length, param);
    for (values) |v| if (v <= 0) return r.nonPositive(v);
    return values;
}

fn lessPair(_: void, a: [2]Dbu, b: [2]Dbu) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

/// Drops adjacent repeats of a sorted slice in place.
fn dedup(comptime T: type, items: []T) []T {
    if (items.len == 0) return items;
    var kept: usize = 1;
    for (items[1..]) |v| {
        if (std.meta.eql(v, items[kept - 1])) continue;
        items[kept] = v;
        kept += 1;
    }
    return items[0..kept];
}
