//! The deck dump's `answers` section: a compiled deck → what the deck query
//! layer (check/deck/query.zig) answers, written as JSON, one call per
//! value. In: a `CompiledDeck` on a 1 nm grid. Out: the object documented
//! in deck.zig under `answers`, every value the query function's return
//! value, `null` where it returns none. Also the JSON number primitives
//! deck.zig writes with. No spec clause: the queries are GPurify's own.
//!
//! Contents:
//! - `pub const Error = error{Unrepresentable} || std.Io.Writer.Error || std.mem.Allocator.Error`
//! - `pub fn writeAnswers(w: *std.Io.Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable) Error!void`
//! - `pub fn spacingQueries(cd: *const CompiledDeck, layer: LayerId) [2]SpacingQuery`
//! - `pub fn number(w: *std.Io.Writer, v: f64) Error!void`, `pub fn optNumber(w: *std.Io.Writer, v: ?f64) Error!void`,
//!   `pub fn optInt(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void`,
//!   `pub fn ids(w: *std.Io.Writer, layers: []const LayerId) std.Io.Writer.Error!void`,
//!   `pub fn item(w: *std.Io.Writer, at: usize) std.Io.Writer.Error!void`, `pub fn close(w: *std.Io.Writer, n: usize) std.Io.Writer.Error!void`
//! - `pub fn matchingObject(w: *std.Io.Writer, m: Matching) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const float = geom.float;
const check = @import("check");
const query = check.deck.query;
const SpacingQuery = query.SpacingQuery;
const CompiledDeck = check.deck.CompiledDeck;
const Matching = @import("ingest").deck.Matching;
const writeString = @import("json.zig").writeString;

/// `Unrepresentable`: a NaN or infinite value, which JSON cannot carry
/// (RFC 8259 §6). The output so far is partial: discard it.
pub const Error = error{Unrepresentable} || Writer.Error || Allocator.Error;

/// Writes the `answers` object. `scratch` holds the query lists and the
/// layer pairs until return. Asserts `cd.grid` is 1 nm.
pub fn writeAnswers(w: *Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    assert(cd.grid.dbu_per_um == 1000);
    const n = cd.deck.layers.len();
    try w.writeAll("{\"layers\":[");
    for (0..n) |i| {
        try item(w, i);
        try layer(w, scratch, cd, strings, @fromBackingInt(@as(u16, @intCast(i))));
    }
    try close(w, n);
    try pairs(w, scratch, cd);
    try models(w, scratch, cd, strings);
    try w.writeByte('}');
}

/// The two queries `spacing_nm` answers for `layer`: two shapes of its
/// `minWidth` (0 without one) side by side with no run (`min_width`), and
/// two shapes as wide as a coordinate reaches running alongside as far,
/// facing on ends of line (`strictest`).
pub fn spacingQueries(cd: *const CompiledDeck, layer: LayerId) [2]SpacingQuery {
    const narrow = query.minWidth(cd, layer) orelse 0;
    const far: Dbu = geom.max_abs_dbu;
    return .{
        .{ .width_a = narrow, .width_b = narrow, .run_length = 0 },
        .{ .width_a = far, .width_b = far, .run_length = far, .end_of_line = 0 },
    };
}

/// A finite `f64` as its shortest round-trip decimal (geom.float.display).
pub fn number(w: *Writer, v: f64) Error!void {
    if (!std.math.isFinite(v)) return error.Unrepresentable;
    try float.display(w, v);
}

pub fn optNumber(w: *Writer, v: ?f64) Error!void {
    if (v) |x| try number(w, x) else try w.writeAll("null");
}

/// An optional integer, or `null`.
pub fn optInt(w: *Writer, v: anytype) Writer.Error!void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

/// Layer ids as a JSON array.
pub fn ids(w: *Writer, layers: []const LayerId) Writer.Error!void {
    try w.writeByte('[');
    for (layers, 0..) |l, i| try w.print("{s}{d}", .{ if (i > 0) "," else "", @backingInt(l) });
    try w.writeByte(']');
}

/// What goes before element `at` of a one-element-per-line array.
pub fn item(w: *Writer, at: usize) Writer.Error!void {
    try w.writeAll(if (at == 0) "\n" else ",\n");
}

/// The end of a one-element-per-line array of `n` elements.
pub fn close(w: *Writer, n: usize) Writer.Error!void {
    try w.writeAll(if (n == 0) "]" else "\n]");
}

/// A `Matching` as an object, each coefficient in SI.
pub fn matchingObject(w: *Writer, m: Matching) Error!void {
    try w.writeAll("{\"avt_v_m\":");
    try optNumber(w, m.avt);
    try w.writeAll(",\"abeta_m\":");
    try optNumber(w, m.abeta);
    try w.writeAll(",\"ar_m\":");
    try optNumber(w, m.ar);
    try w.writeAll(",\"svt_v_per_m\":");
    try optNumber(w, m.svt);
    try w.writeAll(",\"ka_m\":");
    try optNumber(w, m.ka);
    try w.writeByte('}');
}

// ---- private ----

/// One layer's entry: every single-layer query.
fn layer(w: *Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable, l: LayerId) Error!void {
    try w.print("{{\"layer\":{d},\"min_width_nm\":", .{@backingInt(l)});
    try optInt(w, query.minWidth(cd, l));
    try w.writeAll(",\"min_area_nm2\":");
    try optInt(w, query.minArea(cd, l));
    try w.writeAll(",\"min_enclosed_area_nm2\":");
    try optInt(w, query.minEnclosedArea(cd, l));
    try w.writeAll(",\"min_step_nm\":");
    try optInt(w, query.minStep(cd, l));
    try w.writeAll(",\"max_aspect_ratio\":");
    try optNumber(w, query.maxAspectRatio(cd, l));
    try w.writeAll(",\"max_total_area_nm2\":");
    try optInt(w, query.maxTotalArea(cd, l));
    try w.writeAll(",\"allowed_widths_nm\":");
    if (query.allowedWidths(cd, l)) |widths| try ints(w, widths) else try w.writeAll("null");
    try w.writeAll(",\"allowed_widths_from_nm\":");
    try optInt(w, query.allowedWidthsFrom(cd, l));
    try w.writeAll(",\"cut_classes_nm\":");
    if (query.cutClasses(cd, l)) |classes| {
        try w.writeByte('[');
        for (classes, 0..) |c, i| try w.print("{s}[{d},{d}]", .{ if (i > 0) "," else "", c[0], c[1] });
        try w.writeByte(']');
    } else try w.writeAll("null");
    const q = spacingQueries(cd, l);
    try w.writeAll(",\"spacing_nm\":{\"min_width\":");
    try optInt(w, query.requiredSpacing(cd, l, q[0]));
    try w.writeAll(",\"strictest\":");
    try optInt(w, query.requiredSpacing(cd, l, q[1]));
    try w.writeAll("},\"cut_spacing_nm\":");
    try optInt(w, query.cutSpacing(cd, l, false));
    try w.writeAll(",\"cut_spacing_center_nm\":");
    try optInt(w, query.cutSpacing(cd, l, true));
    try w.writeAll(",\"max_via_stack\":");
    try optInt(w, query.maxViaStack(cd, l));
    try w.writeAll(",\"via_array_spacing\":[");
    try viaArrays(w, scratch, cd, l);
    try w.writeAll("],\"cut_class_spacing\":");
    if (query.cutClassSpacing(cd, l)) |t| {
        try w.writeAll("{\"short_nm\":");
        try ints(w, t.short);
        try w.writeAll(",\"long_nm\":");
        try ints(w, t.long);
        try w.writeAll(",\"space_nm\":");
        try ints(w, t.space);
        try w.writeByte('}');
    } else try w.writeAll("null");
    try perLayerLists(w, scratch, cd, strings, l);
    try w.writeByte('}');
}

/// `density`, `antenna` and `em`: the three list queries on `l`.
fn perLayerLists(w: *Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable, l: LayerId) Error!void {
    var density: std.ArrayList(query.DensityLimit) = .empty;
    defer density.deinit(scratch);
    try query.densityInto(scratch, cd, l, &density);
    try w.writeAll(",\"density\":[");
    for (density.items, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"rule\":");
        try writeString(w, strings.resolve(d.rule));
        try w.writeAll(",\"window_nm\":");
        if (d.window) |win| try w.print("[{d},{d}]", .{ win[0], win[1] }) else try w.writeAll("null");
        try w.writeAll(",\"limit\":");
        try number(w, d.limit);
        try w.print(",\"sense\":\"{t}\"}}", .{d.sense});
    }
    var antenna: std.ArrayList(query.AntennaLimit) = .empty;
    defer antenna.deinit(scratch);
    try query.antennaInto(scratch, cd, l, &antenna);
    try w.writeAll("],\"antenna\":[");
    for (antenna.items, 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"rule\":");
        try writeString(w, strings.resolve(a.rule));
        try w.print(",\"gate\":{d},\"max_ratio\":", .{@backingInt(a.gate)});
        try number(w, a.max_ratio);
        try w.writeAll(",\"sidewall_nm\":");
        try optInt(w, switch (a.measure) {
            .area => null,
            .sidewall => |height| @as(?Dbu, height),
        });
        try w.writeAll(",\"diode\":");
        try optInt(w, if (a.diode) |d| @backingInt(d) else null);
        try w.writeByte('}');
    }
    var em: std.ArrayList(query.EmLimit) = .empty;
    defer em.deinit(scratch);
    try query.emLimitInto(scratch, cd, l, &em);
    try w.writeAll("],\"em\":[");
    for (em.items, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"rule\":");
        try writeString(w, strings.resolve(e.rule));
        try w.writeAll(",\"max_density_a_per_m\":");
        try number(w, e.max_density.raw);
        try w.writeAll(",\"max_current_per_cut_ua\":");
        try number(w, e.max_current_per_cut.raw);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// `viaArraySpacing` at one past each `via_array_spacing` threshold on
/// `cut`, ascending: every count where the answer can change.
fn viaArrays(w: *Writer, scratch: Allocator, cd: *const CompiledDeck, cut: LayerId) Error!void {
    var counts: std.ArrayList(u32) = .empty;
    defer counts.deinit(scratch);
    const t = cd.drc.table(.via_array_spacing);
    for (t.items(.layer), t.items(.array_threshold)) |on, th| if (on == cut and th < std.math.maxInt(u32)) try counts.append(scratch, th + 1);
    std.mem.sortUnstable(u32, counts.items, {}, std.sort.asc(u32));
    var written: usize = 0;
    for (counts.items, 0..) |cuts, i| {
        if (i > 0 and counts.items[i - 1] == cuts) continue;
        if (written > 0) try w.writeByte(',');
        written += 1;
        try w.print("{{\"cuts\":{d},\"spacing_nm\":", .{cuts});
        try optInt(w, query.viaArraySpacing(cd, cut, cuts));
        try w.writeByte('}');
    }
}

/// The layer-pair queries, each over the pairs its rules name, first
/// mention first: `enclosures`, `projection_spacing`, `contains`,
/// `minimum_cuts`.
fn pairs(w: *Writer, scratch: Allocator, cd: *const CompiledDeck) Error!void {
    const rs = &cd.drc;
    var seen: std.ArrayList([2]LayerId) = .empty;
    defer seen.deinit(scratch);
    for (rs.order.items) |slot| switch (slot.kind) {
        inline .min_enclosure, .asymmetric_enclosure, .adjacent_enclosure, .noncoincident_enclosure, .max_enclosure, .full_width => |k| {
            const r = rs.table(k).get(slot.row);
            try addPair(scratch, &seen, .{ r.inner, r.outer });
        },
        else => {}, // else: only the enclosure kinds name an enclosure pair
    };
    try w.writeAll(",\"enclosures\":[");
    for (seen.items, 0..) |p, i| {
        try item(w, i);
        const e = query.enclosure(cd, p[0], p[1]);
        try w.print("{{\"inner\":{d},\"outer\":{d},\"all_sides_nm\":", .{ @backingInt(p[0]), @backingInt(p[1]) });
        try optInt(w, e.all_sides);
        try w.writeAll(",\"opposite_nm\":");
        try optInt(w, e.opposite);
        try w.writeAll(",\"noncoincident_nm\":");
        try optInt(w, e.noncoincident);
        try w.writeAll(",\"at_most_nm\":");
        try optInt(w, e.at_most);
        try w.print(",\"full_width\":{}}}", .{e.full_width});
    }
    try close(w, seen.items.len);

    seen.clearRetainingCapacity();
    const ps = rs.table(.projection_spacing);
    for (ps.items(.a), ps.items(.b)) |a, b| try addPair(scratch, &seen, .{ a, b });
    try w.writeAll(",\"projection_spacing\":[");
    for (seen.items, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"a\":{d},\"b\":{d},\"spacing_nm\":", .{ @backingInt(p[0]), @backingInt(p[1]) });
        try optInt(w, query.projectionSpacing(cd, p[0], p[1]));
        try w.writeByte('}');
    }

    seen.clearRetainingCapacity();
    const mc = rs.table(.must_contain);
    for (mc.items(.outer), mc.items(.inner)) |o, in| try addPair(scratch, &seen, .{ o, in });
    try w.writeAll("],\"contains\":[");
    for (seen.items, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        const bounds = query.contains(cd, p[0], p[1]).?;
        try w.print("{{\"outer\":{d},\"inner\":{d},\"min\":{d},\"max\":", .{ @backingInt(p[0]), @backingInt(p[1]), bounds[0] });
        try optInt(w, if (bounds[1] == std.math.maxInt(u32)) null else bounds[1]);
        try w.writeByte('}');
    }

    // One past each counted rule's width: where the answer can change.
    const cuts = rs.table(.minimum_cut);
    try w.writeAll("],\"minimum_cuts\":[");
    var written: usize = 0;
    for (cuts.items(.cut), cuts.items(.wide), cuts.items(.width), cuts.items(.thin), 0..) |c, wide, width, thin, row| {
        if (thin != null) continue;
        const dup = for (0..row) |before| {
            if (cuts.items(.cut)[before] == c and cuts.items(.wide)[before] == wide and cuts.items(.width)[before] == width and cuts.items(.thin)[before] == null) break true;
        } else false;
        if (dup) continue;
        if (written > 0) try w.writeByte(',');
        written += 1;
        try w.print("{{\"cut\":{d},\"wide\":{d},\"wire_width_nm\":{d},\"cuts\":", .{ @backingInt(c), @backingInt(wide), width + 1 });
        try optInt(w, query.minimumCuts(cd, c, wide, width + 1));
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn addPair(scratch: Allocator, seen: *std.ArrayList([2]LayerId), p: [2]LayerId) Allocator.Error!void {
    for (seen.items) |s| if (s[0] == p[0] and s[1] == p[1]) return;
    try seen.append(scratch, p);
}

/// `models`: each device model, device rows first then `matching` rows,
/// first mention first, with `fetLimits` and `matching`.
fn models(w: *Writer, scratch: Allocator, cd: *const CompiledDeck, strings: *const StrTable) Error!void {
    var names: std.ArrayList(StrId) = .empty;
    defer names.deinit(scratch);
    for (cd.deck.devices.model) |m| if (std.mem.indexOfScalar(StrId, names.items, m) == null) try names.append(scratch, m);
    for (cd.deck.matching) |row| if (std.mem.indexOfScalar(StrId, names.items, row.model) == null) try names.append(scratch, row.model);
    try w.writeAll(",\"models\":[");
    for (names.items, 0..) |m, i| {
        try item(w, i);
        try w.writeAll("{\"model\":");
        try writeString(w, strings.resolve(m));
        const fet = query.fetLimits(cd, m);
        try w.writeAll(",\"gate_oxide_mv\":");
        try optNumber(w, if (fet.gate_oxide) |v| v.raw else null);
        try w.writeAll(",\"drain_source_mv\":");
        try optNumber(w, if (fet.drain_source) |v| v.raw else null);
        try w.writeAll(",\"matching\":");
        if (query.matching(cd, m)) |coeffs| try matchingObject(w, coeffs) else try w.writeAll("null");
        try w.writeByte('}');
    }
    try close(w, names.items.len);
}

fn ints(w: *Writer, values: anytype) Writer.Error!void {
    try w.writeByte('[');
    for (values, 0..) |v, i| try w.print("{s}{d}", .{ if (i > 0) "," else "", v });
    try w.writeByte(']');
}
