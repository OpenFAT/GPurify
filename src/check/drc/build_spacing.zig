//! The deck builders of the spacing, facing and patterning kinds that need
//! more than a line (`anchored_patterning`, `sadp`, `net_spacing`, the
//! spacing, tip, two-width and span tables, `forbidden_spacing`,
//! `eol_within_spacing`, `eol_keep_out`, `eol_extension_spacing`). In: one
//! row's `Ctx`. Out: its `Rule`, side tables filed into the set. Ported from
//! the matching arms of crates/check/src/drc/ruleset.rs `RuleSet::from_deck`.
//!
//! Contents:
//! - `pub fn anchoredPatterning(c: Ctx) Error!Rule`, `sadp`, `netSpacing`, `spacingTable`,
//!   `tipSpacingTable`, `twoWidthSpacingTable`, `spanLength`, `forbiddenSpacing`,
//!   `eolWithinSpacing`, `eolKeepOut`, `eolExtensionSpacing`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const rows = @import("rows.zig");
const Rule = rows.Rule;
const params = @import("params.zig");
const Error = params.Error;
const Reader = params.Reader;
const Ctx = @import("compile.zig").Ctx;

pub fn anchoredPatterning(c: Ctx) Error!Rule {
    const r = c.r;
    const all = r.table.layersOf(r.spec);
    const colors = try r.count("colors", std.math.maxInt(u8));
    const most = @min(colors, 4);
    if (all.len < 2 or all.len > 1 + most) {
        r.diag.* = .{ .rule = r.spec.id, .kind = r.spec.kind, .expected = 1 + most, .found = r.spec.layer_len };
        return error.WrongLayerCount;
    }
    var anchors: [4]?LayerId = @splat(null);
    for (all[1..], 0..) |a, i| anchors[i] = a;
    return .{ .anchored_patterning = .{ .layer = all[0], .anchors = anchors, .colors = @intCast(colors), .color_spacing = try r.length("color_spacing") } };
}

pub fn sadp(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const different = try r.length("different");
    const same = try r.length("same");
    const width = try r.optLength("track_width");
    const space = try r.optLength("track_space");
    if (width == null and space != null) return r.fail(error.MissingParam, "track_width");
    if (width != null and space == null) return r.fail(error.MissingParam, "track_space");
    return .{ .sadp = .{ .layer = layer, .different = different, .same = same, .track = if (width) |w| .{ w, space.? } else null } };
}

/// Files, per derived layer read, the drawn layers it is computed from: a
/// shape of it on no net of its own takes the net of the drawn shapes it
/// overlaps.
pub fn netSpacing(c: Ctx) Error!Rule {
    const r = c.r;
    const l = try r.bounded();
    const same_net = try r.flag("same_net");
    // Across two layers one net's shapes overlap where a cut joins them:
    // only different nets are spaced.
    if (same_net and l.other != null) return r.fail(error.WrongParamType, "same_net");
    for ([2]?LayerId{ l.layer, l.other }) |maybe| {
        const read = maybe orelse continue;
        if (!c.layers.isDerived(read)) continue;
        if (std.mem.indexOfScalar(LayerId, c.rs.net_source_layer.items, read) != null) continue;
        var drawn: std.ArrayList(LayerId) = .empty;
        var todo: std.ArrayList(LayerId) = .empty;
        try todo.append(r.scratch, read);
        while (todo.pop()) |next| {
            if (c.layers.isDerived(next)) {
                try todo.appendSlice(r.scratch, c.layers.operands(next));
            } else if (std.mem.indexOfScalar(LayerId, drawn.items, next) == null) {
                try drawn.append(r.scratch, next);
            }
        }
        std.mem.sortUnstable(LayerId, drawn.items, {}, lessLayer);
        try c.rs.net_source_layer.append(c.gpa, read);
        _ = try c.rs.net_source_drawn.push(c.gpa, drawn.items);
    }
    return .{ .net_spacing = .{ .layer = l.layer, .other = l.other, .same_net = same_net, .limit = try r.length("limit") } };
}

/// Filed unchecked: `validate` refuses a table that is not complete and
/// monotone.
pub fn spacingTable(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const index = try c.rs.addSpacingTable(c.gpa, .{ .prl = try r.list(.length, "prl"), .width = try r.list(.length, "width"), .space = try r.list(.length, "space") });
    return .{ .spacing_table = .{ .layer = layer, .table = index } };
}

pub fn tipSpacingTable(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const t: @import("tables.zig").ClassTable = .{ .class = try r.list(.length, "length"), .prl = &.{}, .space = try r.list(.length, "space") };
    if (!t.isValidTips()) return r.badTable();
    return .{ .tip_spacing_table = .{ .layer = layer, .table = try c.rs.addClassTable(c.gpa, t) } };
}

pub fn twoWidthSpacingTable(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const t: @import("tables.zig").ClassTable = .{ .class = try r.list(.length, "width"), .prl = try optLengths(r, "prl"), .space = try r.list(.length, "space") };
    if (!t.isValidTwoWidths()) return r.badTable();
    return .{ .two_width_spacing_table = .{ .layer = layer, .table = try c.rs.addClassTable(c.gpa, t) } };
}

pub fn spanLength(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const t: @import("tables.zig").SpanTable = .{
        .x = try r.list(.length, "x_spans"),
        .y = try r.list(.length, "y_spans"),
        .x_except = try r.optLength("x_except"),
        .y_except = try r.optLength("y_except"),
    };
    if (!t.isValid()) return r.badTable();
    return .{ .span_length = .{ .layer = layer, .table = try c.rs.addSpanTable(c.gpa, t) } };
}

pub fn forbiddenSpacing(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const min = try r.length("min");
    const max = try r.length("max");
    const prl = try r.atLeastZero("prl");
    if (min > max) return r.badTable();
    return .{ .forbidden_spacing = .{ .layer = layer, .min = min, .max = max, .prl = prl } };
}

pub fn eolWithinSpacing(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const eol_width = try r.length("eol_width");
    const within = try r.atLeastZero("eol_within");
    const parallel: ?rows.EolParallel = if (r.stated("par_space")) .{
        .space = try r.length("par_space"),
        .within = try r.atLeastZero("par_within"),
        .two_edges = try r.flag("two_edges"),
    } else null;
    const end_to_end = try r.optLength("end_to_end");
    var lef58: rows.Eol58 = .none;
    if (r.stated("side_length")) lef58.side_length = .{
        .length = try r.length("side_length"),
        .maximum = try r.flag("side_length_maximum"),
        .two_sides = try r.flag("side_length_two_sides"),
    };
    if (r.stated("end_prl_space")) lef58.end_prl = .{ try r.length("end_prl_space"), try r.length("end_prl") };
    if (r.stated("wrong_dir_space")) lef58.wrong_dir = .{ .space = try r.length("wrong_dir_space"), .horizontal = try r.flag("wrong_dir_horizontal") };
    lef58.extension = try r.optLength("eol_extension");
    if (r.optional("enclose_cut_layer")) |v| {
        if (v != .layer) return r.fail(error.WrongParamType, "enclose_cut_layer");
        lef58.enclose_cut = .{
            .cut = v.layer,
            .within = try r.length("enclose_cut_within"),
            .space = try r.length("enclose_cut_space"),
            .all = try r.flag("enclose_cut_all"),
        };
    }
    const limit = try r.length("limit");
    lef58.opposite_width = try r.optLength("opposite_width");
    lef58.subtract_eol_width = if (r.optional("par_subtract_eol_width")) |v| v == .flag and v.flag else false;
    lef58.parallel_min_length = try r.optLength("par_min_length");
    return .{ .eol_within_spacing = .{ .layer = layer, .eol_width = eol_width, .within = within, .parallel = parallel, .end_to_end = end_to_end, .limit = limit, .lef58 = lef58 } };
}

pub fn eolKeepOut(c: Ctx) Error!Rule {
    const r = c.r;
    return .{ .eol_keep_out = .{
        .layer = try r.one(),
        .eol_width = try r.length("eol_width"),
        .backward = try r.atLeastZero("backward"),
        .side = try r.atLeastZero("side"),
        .forward = try r.length("forward"),
        .except_within = if (r.stated("within_low")) .{ try r.atLeastZero("within_low"), try r.length("within_high") } else null,
        .corner_only = if (r.optional("corner_only")) |v| v == .flag and v.flag else false,
    } };
}

pub fn eolExtensionSpacing(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const widths = try r.list(.length, "eol_width");
    const extensions = try r.list(.length, "extension");
    const end_to_end = try optLengths(r, "end_to_end");
    if (widths.len > 3 or extensions.len != widths.len or end_to_end.len != widths.len) return r.badTable();
    var table: [3]?rows.EolExtension = @splat(null);
    for (widths, extensions, end_to_end, 0..) |w, e, t, i| table[i] = .{ .eol_width = w, .extension = e, .end_to_end = t };
    const side_length: ?rows.SideLengthTwo = if (r.stated("side_length")) .{
        .length = try r.length("side_length"),
        .two_sides = try r.flag("side_length_two_sides"),
    } else null;
    return .{ .eol_extension_spacing = .{ .layer = layer, .rows = table, .side_length = side_length, .limit = try r.length("limit") } };
}

// ---- private ----

/// A list of lengths where `none` (the flag false) leaves an entry empty.
fn optLengths(r: Reader, param: []const u8) Error![]?Dbu {
    var out: std.ArrayList(?Dbu) = .empty;
    const name = r.strings.get(param) orelse return out.items;
    for (r.table.paramsOf(r.spec)) |p| {
        if (p.name != name) continue;
        const v: ?Dbu = switch (p.value) {
            .length => |l| l,
            .flag => |set| if (set) return r.fail(error.WrongParamType, param) else null,
            .ratio, .count, .area, .layer, .model => return r.fail(error.WrongParamType, param),
        };
        try out.append(r.scratch, v);
    }
    return out.items;
}

fn lessLayer(_: void, a: LayerId, b: LayerId) bool {
    return @backingInt(a) < @backingInt(b);
}
