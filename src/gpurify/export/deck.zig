//! The deck dump (`gpurify deck <deck> --format json`): a compiled deck →
//! its tables and the deck query layer's answers as one JSON document, so
//! a layout generator reads GPurify's one parse of the deck and never the
//! deck language. In: a `CompiledDeck` compiled on a 1 nm grid and its
//! string table. Out: the document below. No spec clause: the format is
//! GPurify's own, versioned by `format`.
//!
//! Units. Lengths are integer nm (`_nm`), areas integer nm² (`_nm2`): the
//! deck is compiled on a 1 nm grid, so they are exact. Every other number
//! is in the unit its key's suffix names, or, in a rule parameter, its
//! `unit` field: the engine unit of its dimension (`mV`, `uA`, `A/m`,
//! `ohm`, `K`, `eV`, `W/mK`, `h`, `V/um`, `MHz`, `aF`, `nH`, `aF/um2`,
//! `aF/um`, `1/K`, `1/K2`, `deg`), SI for the mismatch coefficients
//! (`V*m`, `m`, `V/m`), and `1` for a fraction (0..1, `%` already divided),
//! a ratio or a count. A number is its shortest round-trip decimal. `null`
//! is "the deck states none", never 0. Ids are `LayerId`s: indexes into
//! `layers`. Every array is in the deck's own order (layers in id order),
//! so the bytes are a function of the deck text alone.
//!
//! The document, keys in this order; a top-level array has one element
//! per line:
//! - `format`: `"gpurify-deck/1"`. A consumer pins it: a key's meaning
//!   changes only with it.
//! - `deck`: the deck's name or path as given. `grid_nm`: its `grid`
//!   statement (`null` without one).
//! - `layers`: one per id, drawn ones first (ascending by name), then
//!   derived ones in declaration order, including the hidden layers a
//!   nested or inline expression makes (`x#1`, `<rule>@k`). `id`, `name`,
//!   and either `gds: [layer, datatype]` or `derived: {op, operands,
//!   ...}`: `op` as the deck spells it (`and`, `sized`, `not_interacting`,
//!   ...), `operands` the ids it reads (receiver first), and its
//!   parameters: `sized` `dx_nm`, `dy_nm`; `with_area` `min_nm2`,
//!   `max_nm2`; `with_length`, `with_bbox_max|min` `min_nm`, `max_nm`
//!   (inclusive, `null` open); `with_width` `min_2w2_nm2`, `max_2w2_nm2`
//!   (inclusive bounds on 2·w·|w|, as stored); `with_rect|without_rect`
//!   `w_nm`, `h_nm`; `extended` `begin_nm`, `end_nm`, `out_nm`, `in_nm`;
//!   `with_text|without_text` `text`; `in_cells|not_in_cells` `cells`.
//! - `rules`: `id`; `kind`, the engine kind (`min_width`, unique per check);
//!   `keyword`, the deck's spelling (`width`); `domain`, `drc` or `erc`
//!   (LVS and PEX are configured by `lvs` and `pex`, not rules);
//!   `severity`, `error` or `warning`; `layers`, ids in the order the
//!   engine kind takes them (an enclosure: outer, inner); `params`, each
//!   `{name, ...}` with the engine's parameter name (the comparison's
//!   value is `limit`) and one of: `value` + `unit` (a number; a length
//!   list's `none` is `value: null`), `value` (a boolean flag), `word` (a
//!   keyword: `same`/`different`, a corner kind), `layer` (an id),
//!   `model` (a device model) or `name` (a quoted non-model name). A list
//!   is one entry per element, in order; a parameter written `none` is
//!   absent.
//! - `connectivity`: `conductors`, `vias` (`cut`, `connects: [a, b]`),
//!   `touch_within_layer`, `global`, `labels` (`layer`, `names`).
//! - `devices`: `kind` (`mos`, `bjt`, `resistor`, `capacitor`, `diode`,
//!   `inductor`), `model`, `marker`, `terminals` (mos gate, source, drain
//!   [, bulk]; bjt base, emitter, collector [, bulk]; two-pin kinds pin 0,
//!   pin 1), `fins`, then the stated values `sheet_ohm_sq`,
//!   `area_cap_af_um2`, `fringe_cap_af_um`, `inductance_nh`,
//!   `on_gate_min_mv`, `on_gate_max_mv`.
//! - `matching`: `model`, `basis` (`pair` or `single`), and `coefficients`
//!   as stated: `avt_v_m`, `abeta_m`, `ar_m`, `svt_v_per_m`, `ka_m`.
//! - `lvs`: every `lvs` control, under its `LvsControls` field name;
//!   models and names as strings, `tolerance` rows' `absolute` with its
//!   `absolute_unit` (as stated), `range` bounds as `{value, unit}`,
//!   `max_res_ohm`, `min_caps_af`, `lde` `max_nm` and `well`
//!   (`{layer, scref_nm}`), and `netlist_scale_nm`.
//! - `pex`: `temperature_k`, `nominal_k`; `extraction` (`kind`,
//!   `coupling_threshold_af`, `coupling_halo`, a ratio); `stack`, one row
//!   per layer with a `pex` line: `layer`, `thickness_nm`, `height_nm`,
//!   `sheet_ohm_sq` (at the operating temperature), `dielectric_k`,
//!   `area_cap_af_um2`, `fringe_cap_af_um`, then `sheet_nominal_ohm_sq`,
//!   `tc1_per_k`, `tc2_per_k2` (`null` without a `temperature`);
//!   `corners`, each `name` and its whole `stack` in the same rows less the
//!   last three.
//! - `answers`: deck_answers.zig. `layers`, one per id: `layer`,
//!   `min_width_nm` (`minWidth`), `min_area_nm2`, `min_enclosed_area_nm2`,
//!   `min_step_nm`, `max_aspect_ratio`, `max_total_area_nm2`,
//!   `allowed_widths_nm`, `allowed_widths_from_nm`, `cut_classes_nm`
//!   (`[short, long]`), `spacing_nm` (`requiredSpacing` at the two
//!   queries `spacingQueries` names: `min_width`, `strictest`),
//!   `cut_spacing_nm`, `cut_spacing_center_nm`, `max_via_stack`,
//!   `via_array_spacing` (`{cuts, spacing_nm}` at one past each threshold),
//!   `cut_class_spacing` (`short_nm`, `long_nm`, `space_nm` as
//!   `CutClassTable` stores them), `density` (`rule`, `window_nm: [side,
//!   step]` or `null` for the whole die, `limit`, `sense`), `antenna`
//!   (`rule`, `gate`, `max_ratio`, `sidewall_nm`, `null` for area,
//!   `diode`), `em` (`rule`, `max_density_a_per_m`,
//!   `max_current_per_cut_ua`). `enclosures`, one per (inner, outer) pair an
//!   enclosure rule names: `all_sides_nm`, `opposite_nm`,
//!   `noncoincident_nm`, `at_most_nm`, `full_width`. `projection_spacing`
//!   (`a`, `b`, `spacing_nm`), `contains` (`outer`, `inner`, `min`, `max`),
//!   `minimum_cuts` (`cut`, `wide`, `wire_width_nm` one past the rule's
//!   width, `cuts`). `models`, each device model: `model`,
//!   `gate_oxide_mv`, `drain_source_mv` (`fetLimits`), `matching` (the
//!   pair coefficients `matching` answers, or `null`).
//!
//! Not written: stages, waivers, the boundary layer, ignored stream pairs,
//! the `pex_*` models, layout edits and reports.
//!
//! Contents:
//! - `pub const format = "gpurify-deck/1"`
//! - `pub const Error` (deck_answers.zig)
//! - `pub fn writeDeck(w: *std.Io.Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable, name: []const u8) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const ingest_deck = @import("ingest").deck;
const kinds = ingest_deck.kinds;
const Dim = kinds.Dim;
const Param = kinds.Param;
const ProcessStack = ingest_deck.ProcessStack;
const check = @import("check");
const CompiledDeck = check.deck.CompiledDeck;
const writeString = @import("json.zig").writeString;
const answers = @import("deck_answers.zig");
const number = answers.number;
const optNumber = answers.optNumber;
const optInt = answers.optInt;
const ids = answers.ids;
const item = answers.item;
const close = answers.close;

/// The format version every dump starts with.
pub const format = "gpurify-deck/1";

pub const Error = answers.Error;

/// Writes `cd` as the deck dump, `name` as its `deck`. `scratch` holds
/// the answers' query lists until return. Asserts `cd.grid` is 1 nm.
/// `Unrepresentable`: a non-finite value, or a rule parameter whose unit
/// the kind table does not state; the output so far is partial.
pub fn writeDeck(w: *Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable, name: []const u8) Error!void {
    assert(cd.grid.dbu_per_um == 1000);
    const d = &cd.deck;
    try w.print("{{\"format\":\"{s}\",\"deck\":", .{format});
    try writeString(w, name);
    try w.writeAll(",\"grid_nm\":");
    try optNumber(w, d.grid_nm);
    try w.writeAll(",\n\"layers\":[");
    try layers(w, cd, strings);
    try w.writeAll(",\n\"rules\":[");
    try rules(w, cd, strings);
    try w.writeAll(",\n\"connectivity\":");
    try connectivity(w, cd);
    try w.writeAll(",\n\"devices\":[");
    try devices(w, cd, strings);
    try w.writeAll(",\n\"matching\":[");
    for (d.matching, 0..) |row, i| {
        try item(w, i);
        try w.writeAll("{\"model\":");
        try writeString(w, strings.resolve(row.model));
        try w.print(",\"basis\":\"{t}\",\"coefficients\":", .{row.basis});
        try answers.matchingObject(w, row.stated);
        try w.writeByte('}');
    }
    try close(w, d.matching.len);
    try w.writeAll(",\n\"lvs\":");
    try lvs(w, cd, strings);
    try w.writeAll(",\n\"pex\":");
    try pex(w, cd, strings);
    try w.writeAll(",\n\"answers\":");
    try answers.writeAnswers(w, scratch, cd, strings);
    try w.writeAll("}\n");
}

// ---- private ----

fn layers(w: *Writer, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    const t = &cd.deck.layers;
    for (0..t.len()) |i| {
        const id: LayerId = @fromBackingInt(@as(u16, @intCast(i)));
        try item(w, i);
        try w.print("{{\"id\":{d},\"name\":", .{i});
        try writeString(w, strings.resolve(t.name(id)));
        const op = t.op(id) orelse {
            const s = t.streamOf(id);
            try w.print(",\"gds\":[{d},{d}]}}", .{ s[0], s[1] });
            continue;
        };
        try w.print(",\"derived\":{{\"op\":\"{s}\",\"operands\":", .{opWord(op)});
        try ids(w, t.operands(id));
        switch (op) {
            .@"and", .@"or", .not, .interacting, .inside, .outside, .overlapping, .covering, .holes, .extents, .rectangles, .edges, .part, .oriented, .texts_outside => {},
            .sized => |s| try w.print(",\"dx_nm\":{d},\"dy_nm\":{d}", .{ s.dx, s.dy }),
            .with_area => |r| try range(w, "nm2", r.lo, r.hi),
            .with_width => |r| try range(w, "2w2_nm2", r.lo, r.hi),
            .with_length => |r| try range(w, "nm", r.lo, r.hi),
            .with_bbox => |b| try range(w, "nm", b.lo, b.hi),
            .with_rect => |r| try w.print(",\"w_nm\":{d},\"h_nm\":{d}", .{ r.w, r.h }),
            .extended => |e| try w.print(",\"begin_nm\":{d},\"end_nm\":{d},\"out_nm\":{d},\"in_nm\":{d}", .{ e.begin, e.end, e.outside, e.inside }),
            .with_text => |x| {
                try w.writeAll(",\"text\":");
                try writeString(w, t.text(x.text));
            },
            .in_cells => {
                try w.writeAll(",\"cells\":");
                try strs(w, t.cellSelection(op));
            },
        }
        try w.writeAll("}}");
    }
    try close(w, t.len());
}

/// A derived operation as the deck spells it (print_layers.zig `expr`).
fn opWord(op: ingest_deck.DerivedOp) []const u8 {
    return switch (op) {
        .covering => |keep| if (keep) "covering" else "not_covering",
        .interacting => |keep| if (keep) "interacting" else "not_interacting",
        .part => |inside| if (inside) "inside_part" else "outside_part",
        .rectangles => |x| if (x.keep) (if (x.square) "squares" else "rectangles") else (if (x.square) "non_squares" else "non_rectangles"),
        .oriented => |vertical| if (vertical) "vertical" else "horizontal",
        .with_bbox => |b| if (b.longer) "with_bbox_max" else "with_bbox_min",
        .with_rect => |r| if (r.keep) "with_rect" else "without_rect",
        .with_text => |x| if (x.keep) "with_text" else "without_text",
        .in_cells => |c| if (c.keep) "in_cells" else "not_in_cells",
        .@"and", .@"or", .not, .sized, .inside, .outside, .overlapping, .holes, .extents, .with_area, .with_width, .edges, .with_length, .texts_outside, .extended => @tagName(op),
    };
}

/// `min_<unit>` and `max_<unit>`, each `null` at its `i128` extreme.
fn range(w: *Writer, comptime unit: []const u8, lo: i128, hi: i128) Writer.Error!void {
    try w.writeAll(",\"min_" ++ unit ++ "\":");
    try optInt(w, if (lo == std.math.minInt(i128)) null else lo);
    try w.writeAll(",\"max_" ++ unit ++ "\":");
    try optInt(w, if (hi == std.math.maxInt(i128)) null else hi);
}

fn rules(w: *Writer, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    const t = cd.deck.rules;
    const warning = strings.get("warning");
    for (t.spec, 0..) |spec, i| {
        const kind = strings.resolve(spec.kind);
        const severity = if (warning) |id| (if (t.findParam(spec, id)) |v| v == .flag and v.flag else false) else false;
        try item(w, i);
        try w.writeAll("{\"id\":");
        try writeString(w, strings.resolve(spec.id));
        try w.writeAll(",\"kind\":");
        try writeString(w, kind);
        try w.writeAll(",\"keyword\":");
        try writeString(w, keyword(kind) orelse return error.Unrepresentable);
        try w.print(",\"domain\":\"{s}\",\"severity\":\"{s}\",\"layers\":", .{
            if (check.drc.kinds.byName(kind) != null) "drc" else "erc",
            if (severity) "warning" else "error",
        });
        try ids(w, t.layersOf(spec));
        try w.writeAll(",\"params\":[");
        for (t.paramsOf(spec), 0..) |p, k| {
            if (k > 0) try w.writeByte(',');
            try param(w, strings, kind, p);
        }
        try w.writeAll("]}");
    }
    try close(w, t.spec.len);
}

/// The deck spelling of engine kind `kind`: its first kind-table row's.
fn keyword(kind: []const u8) ?[]const u8 {
    for (kinds.kinds) |k| if (std.mem.eql(u8, k.engine, kind)) return k.name;
    return null;
}

/// One parameter, typed by its `ParamValue` tag and, for a number, the
/// dimension the kind table gives its name.
fn param(w: *Writer, strings: *const StrTable, kind: []const u8, p: ingest_deck.NamedValue) Error!void {
    const name = strings.resolve(p.name);
    try w.writeAll("{\"name\":");
    try writeString(w, name);
    const dim = dimOf(kind, name);
    switch (p.value) {
        .length => |v| try w.print(",\"value\":{d},\"unit\":\"nm\"", .{v}),
        .area => |v| try w.print(",\"value\":{d},\"unit\":\"nm2\"", .{v}),
        .layer => |l| try w.print(",\"layer\":{d}", .{@backingInt(l)}),
        .model => |m| {
            try w.writeAll(if (dim != null and dim.? == .names) ",\"name\":" else ",\"model\":");
            try writeString(w, strings.resolve(m));
        },
        .flag => |on| if (dim != null and dim.? == .nets) {
            try w.print(",\"word\":\"{s}\"", .{if (on) "same" else "different"});
        } else if (dim != null and dim.? == .opt_length_list and !on) {
            try w.writeAll(",\"value\":null,\"unit\":\"nm\"");
        } else try w.print(",\"value\":{}", .{on}),
        .count => |n| switch (dim orelse return error.Unrepresentable) {
            .word => |words| {
                if (n >= words.len) return error.Unrepresentable;
                try w.print(",\"word\":\"{s}\"", .{words[n]});
            },
            .angle, .angle_list => try w.print(",\"value\":{d},\"unit\":\"deg\"", .{n}),
            else => try w.print(",\"value\":{d},\"unit\":\"1\"", .{n}), // else: a count
        },
        .ratio => |v| {
            try w.writeAll(",\"value\":");
            try number(w, v);
            try w.print(",\"unit\":\"{s}\"", .{unitOf(dim orelse return error.Unrepresentable) orelse return error.Unrepresentable});
        },
    }
    try w.writeByte('}');
}

/// The dimension the kind table gives engine parameter `name` of `kind`:
/// a row's limit or parameter, inside a group, or the second name of a
/// pair; null when no row of the kind names it.
fn dimOf(kind: []const u8, name: []const u8) ?Dim {
    for (kinds.kinds) |k| {
        if (!std.mem.eql(u8, k.engine, kind)) continue;
        if (k.limit) |l| if (dimIn(l, name)) |d| return d;
        for (k.params) |p| if (dimIn(p, name)) |d| return d;
    }
    return null;
}

fn dimIn(p: Param, name: []const u8) ?Dim {
    if (std.mem.eql(u8, p.engine, name)) return p.dim;
    return switch (p.dim) {
        .group => |inner| for (inner) |q| {
            if (dimIn(q, name)) |d| break d;
        } else null,
        .length_pair, .length_pair_list => |second| if (std.mem.eql(u8, second, name)) .length else null,
        .area_table => |second| if (std.mem.eql(u8, second, name)) .scalar else null,
        else => null, // else: no other dimension carries a second name
    };
}

/// The engine unit a real number of `dim` is stored in (kinds.zig `Dim`).
fn unitOf(dim: Dim) ?[]const u8 {
    return switch (dim) {
        .voltage, .voltage_list => "mV",
        .current => "uA",
        .current_per_width, .current_per_width_rows => "A/m",
        .resistance => "ohm",
        .temperature => "K",
        .energy => "eV",
        .thermal_conductivity => "W/mK",
        .time => "h",
        .field => "V/um",
        .cap_per_area => "aF/um2",
        .cap_per_length => "aF/um",
        .per_kelvin => "1/K",
        .per_kelvin2 => "1/K2",
        .capacitance => "aF",
        .inductance => "nH",
        .voltage_length => "V*m",
        .fraction_length => "m",
        .voltage_per_length => "V/m",
        .frequency, .frequency_list => "MHz",
        .angle, .angle_list => "deg",
        .fraction, .fraction_list, .scalar, .count, .count_list, .area_table => "1",
        .length, .area, .bool, .layer, .length_pair, .models, .names, .group, .nets, .length_list, .area_list, .length_rows, .length_pair_list, .word, .opt_length_list => null,
    };
}

fn connectivity(w: *Writer, cd: *const CompiledDeck) Writer.Error!void {
    const c = cd.deck.connectivity;
    try w.writeAll("{\"conductors\":");
    try ids(w, c.conductors);
    try w.writeAll(",\"vias\":[");
    for (c.via_cut, c.via_connects, 0..) |cut, joins, i| {
        try w.print("{s}{{\"cut\":{d},\"connects\":", .{ if (i > 0) "," else "", @backingInt(cut) });
        try ids(w, &joins);
        try w.writeByte('}');
    }
    try w.print("],\"touch_within_layer\":{},\"global\":", .{c.intra_layer_touch});
    try ids(w, c.global);
    try w.writeAll(",\"labels\":[");
    for (c.label_layer, c.label_names, 0..) |l, n, i| {
        try w.print("{s}{{\"layer\":{d},\"names\":{d}}}", .{ if (i > 0) "," else "", @backingInt(l), @backingInt(n) });
    }
    try w.writeAll("]}");
}

fn devices(w: *Writer, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    const t = cd.deck.devices;
    for (t.kind, t.marker, t.model, 0..) |kind, marker, model, i| {
        try item(w, i);
        try w.print("{{\"kind\":\"{t}\",\"model\":", .{kind});
        try writeString(w, strings.resolve(model));
        try w.print(",\"marker\":{d},\"terminals\":", .{@backingInt(marker)});
        try ids(w, t.terminal[t.terminal_start[i]..t.terminal_start[i + 1]]);
        try w.writeAll(",\"fins\":");
        const fins: ?LayerId = if (i < t.fins.len) t.fins[i] else null;
        try optInt(w, if (fins) |f| @backingInt(f) else null);
        const v: ingest_deck.DeviceValue = if (i < t.value.len) t.value[i] else .{};
        try w.writeAll(",\"sheet_ohm_sq\":");
        try optNumber(w, v.sheet_ohm_sq);
        try w.writeAll(",\"area_cap_af_um2\":");
        try optNumber(w, v.area_cap_af_um2);
        try w.writeAll(",\"fringe_cap_af_um\":");
        try optNumber(w, v.fringe_cap_af_um);
        try w.writeAll(",\"inductance_nh\":");
        try optNumber(w, v.inductance_nh);
        try w.writeAll(",\"on_gate_min_mv\":");
        try optNumber(w, v.on_gate_min_mv);
        try w.writeAll(",\"on_gate_max_mv\":");
        try optNumber(w, v.on_gate_max_mv);
        try w.writeByte('}');
    }
    try close(w, t.kind.len);
}

fn lvs(w: *Writer, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    const c = cd.deck.lvs;
    try w.writeAll("{\"default_tolerance\":");
    try optNumber(w, c.default_tolerance);
    try w.writeAll(",\"tolerance\":[");
    for (c.tolerance, 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        try modelParam(w, strings, row.model, row.param);
        try w.writeAll(",\"relative\":");
        try number(w, row.relative);
        try w.writeAll(",\"absolute\":");
        try number(w, row.stated);
        const unit = ingest_deck.absoluteUnit(strings.resolve(row.param)) orelse return error.Unrepresentable;
        try w.print(",\"absolute_unit\":\"{s}\"}}", .{if (unit.unit.len == 0) "1" else unit.unit});
    }
    try w.writeAll("],\"ignore_parameter\":[");
    for (c.ignore_parameter, 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        try modelParam(w, strings, row.model, row.param);
        try w.writeByte('}');
    }
    try w.writeAll("],\"asymmetric\":");
    try names(w, strings, c.asymmetric);
    try w.writeAll(",\"permute\":[");
    for (c.permute, 0..) |row, i| {
        try w.writeAll(if (i > 0) ",{\"model\":" else "{\"model\":");
        try writeString(w, strings.resolve(row.model));
        try w.print(",\"a\":{d},\"b\":{d}}}", .{ row.a, row.b });
    }
    try w.writeAll("],\"ignore\":");
    try names(w, strings, c.ignore);
    try w.writeAll(",\"ignore_shorted\":");
    try names(w, strings, c.ignore_shorted);
    try w.print(",\"ports_by_name\":{},\"range\":[", .{c.ports_by_name});
    for (c.range, 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        try modelParam(w, strings, row.model, row.param);
        try w.writeAll(",\"min\":");
        try limit(w, row.min);
        try w.writeAll(",\"max\":");
        try limit(w, row.max);
        try w.writeByte('}');
    }
    try w.print("],\"relaxed\":{},\"connect_implicit\":", .{c.relaxed});
    try strs(w, c.connect_implicit);
    try w.writeAll(",\"connect_explicit\":[");
    for (c.connect_explicit, 0..) |group, i| {
        if (i > 0) try w.writeByte(',');
        try names(w, strings, group);
    }
    try w.writeAll("],\"max_res_ohm\":");
    try optNumber(w, c.max_res);
    try w.writeAll(",\"min_caps_af\":");
    try optNumber(w, c.min_caps);
    try w.writeAll(",\"same_nets\":[");
    for (c.same_nets, 0..) |row, i| {
        try w.writeAll(if (i > 0) ",{\"layout\":" else "{\"layout\":");
        try writeString(w, strings.resolve(row.layout));
        try w.writeAll(",\"reference\":");
        try writeString(w, strings.resolve(row.reference));
        try w.writeByte('}');
    }
    try w.writeAll("],\"count\":[");
    for (c.count, 0..) |row, i| {
        try w.writeAll(if (i > 0) ",{\"model\":" else "{\"model\":");
        try writeString(w, strings.resolve(row.model));
        try w.writeAll(",\"min\":");
        try optInt(w, row.min);
        try w.writeAll(",\"max\":");
        try optInt(w, row.max);
        try w.writeByte('}');
    }
    try w.writeAll("],\"lde\":[");
    for (c.lde, 0..) |row, i| {
        try w.writeAll(if (i > 0) ",{\"model\":" else "{\"model\":");
        try writeString(w, strings.resolve(row.model));
        try w.writeAll(",\"od\":");
        try writeString(w, strings.resolve(row.od));
        try w.print(",\"max_nm\":{d},\"well\":", .{row.max});
        if (row.well) |well| {
            try w.writeAll("{\"layer\":");
            try writeString(w, strings.resolve(well.layer));
            try w.print(",\"scref_nm\":{d}}}", .{well.scref});
        } else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.print("],\"recognize_gates\":{},\"split_gates\":{},\"blackbox\":", .{ c.recognize_gates, c.split_gates });
    try strs(w, c.blackbox);
    try w.writeAll(",\"filter_unused\":[");
    for (c.filter_unused, 0..) |f, i| try w.print("{s}\"{s}\"", .{ if (i > 0) "," else "", f.name() });
    try w.writeAll("],\"supply\":");
    try names(w, strings, c.supply);
    try w.writeAll(",\"netlist_scale_nm\":");
    try optNumber(w, cd.deck.devices.netlist_scale_nm);
    try w.writeByte('}');
}

/// Opens a row object with its `model` and `param`; the caller closes it.
fn modelParam(w: *Writer, strings: *const StrTable, model: StrId, p: StrId) Writer.Error!void {
    try w.writeAll("{\"model\":");
    try writeString(w, strings.resolve(model));
    try w.writeAll(",\"param\":");
    try writeString(w, strings.resolve(p));
}

fn limit(w: *Writer, bound: ?ingest_deck.LvsLimit) Writer.Error!void {
    const b = bound orelse return w.writeAll("null");
    switch (b) {
        .length => |v| try w.print("{{\"value\":{d},\"unit\":\"nm\"}}", .{v}),
        .area => |v| try w.print("{{\"value\":{d},\"unit\":\"nm2\"}}", .{v}),
        .count => |v| try w.print("{{\"value\":{d},\"unit\":\"1\"}}", .{v}),
    }
}

fn pex(w: *Writer, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    const d = &cd.deck;
    const law = d.temperature_law;
    try w.writeAll("{\"temperature_k\":");
    try optNumber(w, if (d.temperature) |t| t.raw else null);
    try w.writeAll(",\"nominal_k\":");
    try optNumber(w, if (law) |l| l.nominal_k else null);
    try w.print(",\"extraction\":{{\"kind\":\"{t}\",\"coupling_threshold_af\":", .{d.extraction.kind});
    try number(w, d.extraction.coupling_threshold_af);
    try w.writeAll(",\"coupling_halo\":");
    try optNumber(w, d.extraction.coupling_halo);
    try w.writeAll("},\"stack\":[");
    try stackRows(w, d.stack, law, .nominal);
    try w.writeAll("],\"corners\":[");
    for (d.corners, 0..) |corner, i| {
        try w.writeAll(if (i > 0) ",{\"name\":" else "{\"name\":");
        try writeString(w, strings.resolve(corner.name));
        try w.writeAll(",\"stack\":[");
        try stackRows(w, corner.stack, law, .corner);
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

/// One row per layer whose thickness is stated (decompile.zig's `pex`
/// rows); a `.nominal` row also its sheet at the nominal temperature and
/// its coefficients, from `law`.
fn stackRows(w: *Writer, s: ProcessStack, law: ?ingest_deck.TemperatureLaw, row_kind: enum { nominal, corner }) Error!void {
    var written: usize = 0;
    for (s.thickness_nm, 0..) |thickness, at| {
        if (!(thickness > 0.0)) continue;
        if (written > 0) try w.writeByte(',');
        written += 1;
        try w.print("{{\"layer\":{d},\"thickness_nm\":", .{at});
        try number(w, thickness);
        try w.writeAll(",\"height_nm\":");
        try number(w, s.height_nm[at]);
        try w.writeAll(",\"sheet_ohm_sq\":");
        try number(w, s.sheet_res_ohm_sq[at]);
        try w.writeAll(",\"dielectric_k\":");
        try optNumber(w, if (s.dielectric_k[at] > 0.0) s.dielectric_k[at] else null);
        try w.writeAll(",\"area_cap_af_um2\":");
        try number(w, s.area_cap_af_um2[at]);
        try w.writeAll(",\"fringe_cap_af_um\":");
        try number(w, s.fringe_cap_af_um[at]);
        if (row_kind == .nominal) {
            const row = if (law) |l| for (l.rows) |r| {
                if (@backingInt(r.layer) == at) break r;
            } else null else null;
            try w.writeAll(",\"sheet_nominal_ohm_sq\":");
            try optNumber(w, if (row) |r| r.sheet_ohm_sq else null);
            try w.writeAll(",\"tc1_per_k\":");
            try optNumber(w, if (row) |r| r.tc1 else null);
            try w.writeAll(",\"tc2_per_k2\":");
            try optNumber(w, if (row) |r| r.tc2 else null);
        }
        try w.writeByte('}');
    }
}

fn names(w: *Writer, strings: *const StrTable, list: []const StrId) Writer.Error!void {
    try w.writeByte('[');
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, strings.resolve(s));
    }
    try w.writeByte(']');
}

fn strs(w: *Writer, list: []const []const u8) Writer.Error!void {
    try w.writeByte('[');
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, s);
    }
    try w.writeByte(']');
}

test "a small deck dumps to the bytes worked out by hand from its text" {
    // Oracle: hand-worked from `small_deck` and the language (docs/deck.md):
    // drawn ids ascend by name (met1 0, poly 1, via 2), the derived layer
    // follows (3); lengths are nm on the 1 nm grid (0.083 um2 is 83000
    // nm2, 700 um is 700000); 77% is 0.77, 1.8 V is 1800 mV, 5 mV·um is
    // 5e-9 V·m and 2% is 0.02; an enclosure's engine layers are outer then
    // inner; a parser row lists named params, then the comparison's
    // `limit`, then the kind's fixed flags, then `warning`. The answers
    // follow each query's definition: met1's narrowest width 140, its one
    // spacing 140 at either query, its density row a maximum; via in met1
    // 30 on all sides; nfet's oxide limit 1800 mV and its pair coefficient
    // as stated. Every other answer is null or empty.
    const small_deck =
        \\grid 5nm
        \\layer met1 = gds(68, 20)
        \\layer poly = gds(66, 20)
        \\layer via = gds(68, 44)
        \\layer met1_big = met1.sized(10nm)
        \\rule m1.1 width(met1) >= 140nm
        \\rule m1.2 warning space(met1) >= 140nm
        \\rule m1.6 area(met1) >= 0.083um2
        \\rule m1.d density(met1; window: 700um, step: 70um) <= 77%
        \\rule via.e enclosure(via, met1) >= 30nm
        \\rule GOX gate_oxide(; models: ["nfet"], max: 1.8V)
        \\connect conductors [poly, met1]
        \\connect via via [poly, met1]
        \\device mos met1_big model "nfet" terminals [poly, met1, met1]
        \\matching "nfet" pair avt 5mV·um
        \\lvs tolerance default relative 2%
        \\lvs range "nfet" w >= 420nm
        \\pex met1 thickness 360nm height 1000nm sheet 0.125ohm dielectric 4 area_cap 25aF/um2 fringe_cap 40aF/um
        \\corner slow met1 sheet 0.15ohm
        \\
    ;
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var strings: StrTable = .empty;
    var diag: check.deck.compile.Diag = .{};
    const cd = try check.deck.compile.compile(arena, arena, small_deck, .{ .dbu_per_um = 1000 }, &strings, &diag);
    var out: Writer.Allocating = .init(arena);
    try writeDeck(&out.writer, arena, &cd, &strings, "t.deck");
    const none_layer =
        \\"min_width_nm":null,"min_area_nm2":null,"min_enclosed_area_nm2":null,"min_step_nm":null,"max_aspect_ratio":null,"max_total_area_nm2":null,"allowed_widths_nm":null,"allowed_widths_from_nm":null,"cut_classes_nm":null,"spacing_nm":{"min_width":null,"strictest":null},"cut_spacing_nm":null,"cut_spacing_center_nm":null,"max_via_stack":null,"via_array_spacing":[],"cut_class_spacing":null,"density":[],"antenna":[],"em":[]}
    ;
    const want =
        \\{"format":"gpurify-deck/1","deck":"t.deck","grid_nm":5,
        \\"layers":[
        \\{"id":0,"name":"met1","gds":[68,20]},
        \\{"id":1,"name":"poly","gds":[66,20]},
        \\{"id":2,"name":"via","gds":[68,44]},
        \\{"id":3,"name":"met1_big","derived":{"op":"sized","operands":[0],"dx_nm":10,"dy_nm":10}}
        \\],
        \\"rules":[
        \\{"id":"m1.1","kind":"min_width","keyword":"width","domain":"drc","severity":"error","layers":[0],"params":[{"name":"limit","value":140,"unit":"nm"}]},
        \\{"id":"m1.2","kind":"min_spacing","keyword":"space","domain":"drc","severity":"warning","layers":[0],"params":[{"name":"limit","value":140,"unit":"nm"},{"name":"warning","value":true}]},
        \\{"id":"m1.6","kind":"min_area","keyword":"area","domain":"drc","severity":"error","layers":[0],"params":[{"name":"limit","value":83000,"unit":"nm2"}]},
        \\{"id":"m1.d","kind":"density","keyword":"density","domain":"drc","severity":"error","layers":[0],"params":[{"name":"window","value":700000,"unit":"nm"},{"name":"step","value":70000,"unit":"nm"},{"name":"limit","value":0.77,"unit":"1"},{"name":"maximum","value":true}]},
        \\{"id":"via.e","kind":"min_enclosure","keyword":"enclosure","domain":"drc","severity":"error","layers":[0,2],"params":[{"name":"limit","value":30,"unit":"nm"}]},
        \\{"id":"GOX","kind":"gate_oxide","keyword":"gate_oxide","domain":"erc","severity":"error","layers":[],"params":[{"name":"model","model":"nfet"},{"name":"max_voltage","value":1800,"unit":"mV"}]}
        \\],
        \\"connectivity":{"conductors":[1,0],"vias":[{"cut":2,"connects":[1,0]}],"touch_within_layer":false,"global":[],"labels":[]},
        \\"devices":[
        \\{"kind":"mos","model":"nfet","marker":3,"terminals":[1,0,0],"fins":null,"sheet_ohm_sq":null,"area_cap_af_um2":null,"fringe_cap_af_um":null,"inductance_nh":null,"on_gate_min_mv":null,"on_gate_max_mv":null}
        \\],
        \\"matching":[
        \\{"model":"nfet","basis":"pair","coefficients":{"avt_v_m":0.000000005,"abeta_m":null,"ar_m":null,"svt_v_per_m":null,"ka_m":null}}
        \\],
        \\"lvs":{"default_tolerance":0.02,"tolerance":[],"ignore_parameter":[],"asymmetric":[],"permute":[],"ignore":[],"ignore_shorted":[],"ports_by_name":false,"range":[{"model":"nfet","param":"w","min":{"value":420,"unit":"nm"},"max":null}],"relaxed":false,"connect_implicit":[],"connect_explicit":[],"max_res_ohm":null,"min_caps_af":null,"same_nets":[],"count":[],"lde":[],"recognize_gates":false,"split_gates":false,"blackbox":[],"filter_unused":[],"supply":[],"netlist_scale_nm":null},
        \\"pex":{"temperature_k":null,"nominal_k":null,"extraction":{"kind":"rcc","coupling_threshold_af":0,"coupling_halo":null},"stack":[{"layer":0,"thickness_nm":360,"height_nm":1000,"sheet_ohm_sq":0.125,"dielectric_k":4,"area_cap_af_um2":25,"fringe_cap_af_um":40,"sheet_nominal_ohm_sq":null,"tc1_per_k":null,"tc2_per_k2":null}],"corners":[{"name":"slow","stack":[{"layer":0,"thickness_nm":360,"height_nm":1000,"sheet_ohm_sq":0.15,"dielectric_k":4,"area_cap_af_um2":25,"fringe_cap_af_um":40}]}]},
        \\"answers":{"layers":[
        \\{"layer":0,"min_width_nm":140,"min_area_nm2":83000,"min_enclosed_area_nm2":null,"min_step_nm":null,"max_aspect_ratio":null,"max_total_area_nm2":null,"allowed_widths_nm":null,"allowed_widths_from_nm":null,"cut_classes_nm":null,"spacing_nm":{"min_width":140,"strictest":140},"cut_spacing_nm":null,"cut_spacing_center_nm":null,"max_via_stack":null,"via_array_spacing":[],"cut_class_spacing":null,"density":[{"rule":"m1.d","window_nm":[700000,70000],"limit":0.77,"sense":"maximum"}],"antenna":[],"em":[]},
        \\{"layer":1,
    ++ none_layer ++ ",\n{\"layer\":2," ++ none_layer ++ ",\n{\"layer\":3," ++ none_layer ++ "\n" ++
        \\],"enclosures":[
        \\{"inner":2,"outer":0,"all_sides_nm":30,"opposite_nm":null,"noncoincident_nm":null,"at_most_nm":null,"full_width":false}
        \\],"projection_spacing":[],"contains":[],"minimum_cuts":[],"models":[
        \\{"model":"nfet","gate_oxide_mv":1800,"drain_source_mv":null,"matching":{"avt_v_m":0.000000005,"abeta_m":null,"ar_m":null,"svt_v_per_m":null,"ka_m":null}}
        \\]}}
        \\
    ;
    try testing.expectEqualStrings(want, out.written());
}
