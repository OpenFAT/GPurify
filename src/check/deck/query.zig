//! What a compiled deck enforces, read from the typed rules the checks run.
//! In: a `CompiledDeck` and a layer (or two). Out: the limit a consumer
//! that draws layout (a router, a generator) must meet, the same one the
//! checker reports, read through the condition functions the checks call
//! (`tables.isWide`, `prlHolds`, `isEndOfLine`), so the two cannot disagree.
//! Every length is in grid units of `CompiledDeck.grid`. Each query reads
//! one kind's table (SoA) in deck order. Ported from
//! crates/check/src/deck/query.rs and drc/ruleset.rs
//! (`Rule::required_spacing`, `SpacingQuery`), and the ERC queries
//! (`antenna`, `em_limit`, `fet_limits`). A device model's mismatch
//! coefficients (`matching`) are its `matching` statement's, for a pair.
//!
//! Contents:
//! - `pub const Enclosure = struct`, `pub const DensityLimit = struct`, `pub const SpacingQuery = struct`
//! - `pub fn allowedWidths(cd: *const CompiledDeck, layer: LayerId) ?[]const Dbu`, `allowedWidthsFrom(cd, layer) ?Dbu`,
//!   `cutClasses(cd, layer) ?[]const [2]Dbu`, `maxAspectRatio(cd, layer) ?f64`, `maxTotalArea(cd, layer) ?DbuArea`,
//!   `minStep(cd, layer) ?Dbu`, `minWidth(cd, layer) ?Dbu`, `minArea(cd, layer) ?DbuArea`, `minEnclosedArea(cd, layer) ?DbuArea`
//! - `pub fn requiredSpacing(cd: *const CompiledDeck, layer: LayerId, q: SpacingQuery) ?Dbu`
//! - `pub fn enclosure(cd: *const CompiledDeck, inner: LayerId, outer: LayerId) Enclosure`
//! - `pub fn viaArraySpacing(cd, cut: LayerId, cuts: u32) ?Dbu`, `cutSpacing(cd, cut: LayerId, center: bool) ?Dbu`,
//!   `cutClassSpacing(cd, cut: LayerId) ?CutClassTable`, `minimumCuts(cd, cut: LayerId, wide: LayerId, wire_width: Dbu) ?u16`,
//!   `maxViaStack(cd, cut: LayerId) ?u16`, `projectionSpacing(cd, a: LayerId, b: LayerId) ?Dbu`,
//!   `contains(cd, outer: LayerId, inner: LayerId) ?[2]u32`
//! - `pub fn densityInto(gpa: Allocator, cd: *const CompiledDeck, layer: LayerId, out: *std.ArrayList(DensityLimit)) Allocator.Error!void`
//! - `pub const AntennaLimit = struct`, `pub const EmLimit = struct`, `pub const FetLimits = struct`
//! - `pub fn antennaInto(gpa: Allocator, cd: *const CompiledDeck, collector: LayerId, out: *std.ArrayList(AntennaLimit)) Allocator.Error!void`
//! - `pub fn emLimitInto(gpa: Allocator, cd: *const CompiledDeck, layer: LayerId, out: *std.ArrayList(EmLimit)) Allocator.Error!void`
//! - `pub fn fetLimits(cd: *const CompiledDeck, model: StrId) FetLimits`
//! - `pub fn matching(cd: *const CompiledDeck, model: StrId) ?Matching`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const LimitSense = @import("../report.zig").LimitSense;
const tables = @import("../drc/tables.zig");
const CutClassTable = tables.CutClassTable;
const Kind = @import("../drc/kinds.zig").Kind;
const rows = @import("../drc/rows.zig");
const erc_antenna = @import("../erc/antenna_tables.zig");
const erc_electrical = @import("../erc/electrical_tables.zig");
const Millivolts = @import("../report.zig").Millivolts;
const Microamps = @import("../report.zig").Microamps;
const ModelLimitTable = @import("../erc/domain_tables.zig").ModelLimitTable;
const CompiledDeck = @import("compile.zig").CompiledDeck;
const Matching = @import("ingest").deck.Matching;

/// The enclosure rules between one inner and one outer layer. A rule with
/// a wire band counts as if it held every wire: the strictest it can be.
pub const Enclosure = struct {
    /// The largest `min_enclosure` limit.
    all_sides: ?Dbu = null,
    /// The largest `asymmetric_enclosure` or `adjacent_enclosure` limit:
    /// for a rectangular cut in a shape whose edges do not step along its
    /// sides the two read the same enclosure.
    opposite: ?Dbu = null,
    /// The largest `noncoincident_enclosure` limit.
    noncoincident: ?Dbu = null,
    /// The most the host may reach past the inner shape: the smallest
    /// `max_enclosure` limit.
    at_most: ?Dbu = null,
    /// Whether a `full_width` rule holds the inner shape to span the host.
    full_width: bool = false,
};

/// One density rule on a layer.
pub const DensityLimit = struct {
    rule: StrId,
    /// The window side and step of a `density` rule; null for
    /// `global_density`, which measures the whole die.
    window: ?[2]Dbu,
    /// A fraction of the window or die.
    limit: f64,
    sense: LimitSense,
};

/// One `antenna` or `antenna_electrical` row whose collectors include a
/// layer.
pub const AntennaLimit = struct {
    rule: StrId,
    /// The gate layer the ratio is taken against.
    gate: LayerId,
    /// The largest collector-to-gate ratio the row allows.
    max_ratio: f64,
    /// Whether the collector counts its area or its sidewall.
    measure: erc_antenna.AntennaMeasure,
    /// The diode layer: whose gates an `antenna` row skips, whose area an
    /// `antenna_electrical` row credits.
    diode: ?LayerId,
};

/// The current a layer may carry, from one `em_current_density` row.
pub const EmLimit = struct {
    rule: StrId,
    /// Wire current per unit width, A/m.
    max_density: erc_electrical.CurrentDensity,
    /// The current one cut may carry.
    max_current_per_cut: Microamps,
};

/// The voltages a device model may see: the smallest `gate_oxide` and
/// `drain_source` limits naming it, null without one.
pub const FetLimits = struct {
    /// The most its gate may differ from its source, drain or bulk.
    gate_oxide: ?Millivolts,
    /// The most its drain may differ from its source.
    drain_source: ?Millivolts,
};

/// Two shapes as the spacing rules see them. A width is the narrowest a
/// shape is anywhere (the narrower side of a rectangle).
pub const SpacingQuery = struct {
    width_a: Dbu,
    width_b: Dbu,
    /// How far the shapes' facing edges project onto each other.
    run_length: Dbu,
    /// The length of the edge facing the other shape when it may be a line
    /// end; null when no end-of-line rule reads the sides they face along.
    end_of_line: ?Dbu = null,
};

/// A spacing table column's run: the query's, whatever the cell.
const Run = struct {
    length: Dbu,

    pub fn run(r: Run, _: Dbu) i64 {
        return r.length;
    }
};

/// The widths `layer`'s shapes must be one of, sorted; the first
/// `allowed_width` rule on it, null without one.
pub fn allowedWidths(cd: *const CompiledDeck, layer: LayerId) ?[]const Dbu {
    const t = cd.drc.table(.allowed_width);
    for (t.items(.layer), t.items(.widths)) |on, w| if (on == layer) return cd.drc.widths.get(w);
    return null;
}

/// The width from which every wider width of `layer` is legal too: the last
/// allowed width when its rule leaves it open (LEF58 `WIDTHTABLE`), null
/// when the list is exact or there is none.
pub fn allowedWidthsFrom(cd: *const CompiledDeck, layer: LayerId) ?Dbu {
    const t = cd.drc.table(.allowed_width);
    for (t.items(.layer), t.items(.widths), t.items(.open_last)) |on, w, open| if (on == layer) {
        const widths = cd.drc.widths.get(w);
        return if (open and widths.len > 0) widths[widths.len - 1] else null;
    };
    return null;
}

/// The cut sizes `layer`'s shapes must be one of, each `(short, long)`,
/// sorted; null when no `cut_class` rule lists them.
pub fn cutClasses(cd: *const CompiledDeck, layer: LayerId) ?[]const [2]Dbu {
    const t = cd.drc.table(.cut_class);
    for (t.items(.layer), t.items(.classes)) |on, k| if (on == layer) return cd.drc.classes.get(k);
    return null;
}

/// The strictest `aspect_ratio` limit on `layer`.
pub fn maxAspectRatio(cd: *const CompiledDeck, layer: LayerId) ?f64 {
    return extreme(cd, .aspect_ratio, layer, .least);
}

/// The strictest `total_area` limit on `layer`.
pub fn maxTotalArea(cd: *const CompiledDeck, layer: LayerId) ?DbuArea {
    return extreme(cd, .total_area, layer, .least);
}

/// The shortest edge a `min_step` rule allows on `layer`, the strictest.
pub fn minStep(cd: *const CompiledDeck, layer: LayerId) ?Dbu {
    return extreme(cd, .min_step, layer, .most);
}

/// The narrowest legal width of `layer`: the largest `min_width` limit, the
/// width its check reports as a too-narrow shape's limit.
pub fn minWidth(cd: *const CompiledDeck, layer: LayerId) ?Dbu {
    return extreme(cd, .min_width, layer, .most);
}

/// The smallest legal area of a shape on `layer`.
pub fn minArea(cd: *const CompiledDeck, layer: LayerId) ?DbuArea {
    return extreme(cd, .min_area, layer, .most);
}

/// The smallest legal hole in `layer`.
pub fn minEnclosedArea(cd: *const CompiledDeck, layer: LayerId) ?DbuArea {
    return extreme(cd, .min_enclosed_area, layer, .most);
}

/// The space two shapes on `layer` described by `q` must keep: the largest
/// any of the layer's same-layer spacing rules requires of them, the
/// `limit` the checker reports when they are closer. Null when none holds
/// them.
pub fn requiredSpacing(cd: *const CompiledDeck, layer: LayerId, q: SpacingQuery) ?Dbu {
    const rs = &cd.drc;
    const wider = @max(q.width_a, q.width_b);
    var best: ?Dbu = null;
    const ms = rs.table(.min_spacing);
    for (ms.items(.layer), ms.items(.limit)) |on, limit| if (on == layer) bump(&best, limit);
    const wd = rs.table(.wide_dependent_spacing);
    for (wd.items(.layer), wd.items(.width_threshold), wd.items(.limit)) |on, w, limit| if (on == layer and tables.isWide(wider, w)) bump(&best, limit);
    const aw = rs.table(.attached_wide_spacing);
    for (aw.items(.layer), aw.items(.width_threshold), aw.items(.limit)) |on, w, limit| if (on == layer and tables.isWide(wider, w)) bump(&best, limit);
    const prl = rs.table(.prl_spacing);
    for (prl.items(.layer), prl.items(.prl_threshold), prl.items(.limit)) |on, p, limit| if (on == layer and tables.prlHolds(q.run_length, p)) bump(&best, limit);
    const eol = rs.table(.eol_spacing);
    for (eol.items(.layer), eol.items(.eol_width), eol.items(.limit)) |on, w, limit| if (on == layer) {
        if (q.end_of_line) |edge| if (tables.isEndOfLine(edge, w)) bump(&best, limit);
    };
    const st = rs.table(.spacing_table);
    for (st.items(.layer), st.items(.table)) |on, i| if (on == layer) {
        const t = rs.spacingTable(i);
        const run: Run = .{ .length = q.run_length };
        for (0..t.width.len) |row| if (row == 0 or tables.isWide(wider, t.rowSquare(row))) bump(&best, t.at(row, t.column(row, run)));
    };
    return best;
}

/// The enclosure rules holding `inner` inside `outer`.
pub fn enclosure(cd: *const CompiledDeck, inner: LayerId, outer: LayerId) Enclosure {
    const rs = &cd.drc;
    var found: Enclosure = .{};
    inline for (.{ .min_enclosure, .asymmetric_enclosure, .adjacent_enclosure, .noncoincident_enclosure, .max_enclosure }) |k| {
        const t = rs.table(k);
        for (t.items(.outer), t.items(.inner), t.items(.limit)) |o, i, limit| if (o == outer and i == inner) switch (k) {
            .min_enclosure => bump(&found.all_sides, limit),
            .asymmetric_enclosure, .adjacent_enclosure => bump(&found.opposite, limit),
            .noncoincident_enclosure => bump(&found.noncoincident, limit),
            .max_enclosure => found.at_most = if (found.at_most) |m| @min(m, limit) else limit,
            else => comptime unreachable,
        };
    }
    const fw = rs.table(.full_width);
    for (fw.items(.outer), fw.items(.inner)) |o, i| found.full_width = found.full_width or (o == outer and i == inner);
    return found;
}

/// The space the cuts of an array of `cuts` cuts on `cut` must keep: the
/// largest `via_array_spacing` limit among the rules for which `cuts` makes
/// an array (more than its threshold).
pub fn viaArraySpacing(cd: *const CompiledDeck, cut: LayerId, cuts: u32) ?Dbu {
    const t = cd.drc.table(.via_array_spacing);
    var best: ?Dbu = null;
    for (t.items(.layer), t.items(.array_threshold), t.items(.limit)) |on, th, limit| if (on == cut and cuts > th) bump(&best, limit);
    return best;
}

/// The space every cut on `cut` must keep from every other, centre to
/// centre when `center`: the largest `cut_spacing` limit that holds every
/// cut (no `adjacent`).
pub fn cutSpacing(cd: *const CompiledDeck, cut: LayerId, center: bool) ?Dbu {
    const t = cd.drc.table(.cut_spacing);
    var best: ?Dbu = null;
    for (t.items(.layer), t.items(.center), t.items(.adjacent), t.items(.limit)) |on, c, adj, limit| if (on == cut and c == center and adj == 0) bump(&best, limit);
    return best;
}

/// The first `cut_class_spacing` table on `cut`.
pub fn cutClassSpacing(cd: *const CompiledDeck, cut: LayerId) ?CutClassTable {
    const t = cd.drc.table(.cut_class_spacing);
    for (t.items(.layer), t.items(.table)) |on, i| if (on == cut) return cd.drc.cutClassTable(i);
    return null;
}

/// The fewest cuts on `cut` a via needs where it lands on a `wide` wire
/// `wire_width` wide: the largest `minimum_cut` count among the rules whose
/// `width` the wire strictly exceeds; a `LENGTH WITHIN` rule holds the thin
/// wires beside it, not the wire, and is not counted.
pub fn minimumCuts(cd: *const CompiledDeck, cut: LayerId, wide: LayerId, wire_width: Dbu) ?u16 {
    const t = cd.drc.table(.minimum_cut);
    var best: ?u16 = null;
    for (t.items(.cut), t.items(.wide), t.items(.width), t.items(.thin), t.items(.min_count)) |c, w, width, thin, count| {
        if (c == cut and w == wide and thin == null and wire_width > width) best = @max(best orelse count, count);
    }
    return best;
}

/// The tallest stack of overlapping cuts through `cut`: the smallest
/// `via_stack` height among the stacks naming it (a single-cut stack names
/// its metals too, at even places).
pub fn maxViaStack(cd: *const CompiledDeck, cut: LayerId) ?u16 {
    const t = cd.drc.table(.via_stack);
    var best: ?u16 = null;
    for (t.items(.stack), t.items(.single), t.items(.max_height)) |stack, single, height| {
        const layers = cd.drc.stacks.get(stack);
        var i: usize = @intFromBool(single);
        const named = while (i < layers.len) : (i += if (single) 2 else 1) {
            if (layers[i] == cut) break true;
        } else false;
        if (named) best = @min(best orelse height, height);
    }
    return best;
}

/// The largest `projection_spacing` limit between `a` and `b`, either order.
pub fn projectionSpacing(cd: *const CompiledDeck, a: LayerId, b: LayerId) ?Dbu {
    const t = cd.drc.table(.projection_spacing);
    var best: ?Dbu = null;
    for (t.items(.a), t.items(.b), t.items(.limit)) |x, y, limit| if ((x == a and y == b) or (x == b and y == a)) bump(&best, limit);
    return best;
}

/// How many `inner` shapes an `outer` shape must hold, `(fewest, most)`:
/// the tightest bounds of the `must_contain` rules between them, `maxInt`
/// for no most.
pub fn contains(cd: *const CompiledDeck, outer: LayerId, inner: LayerId) ?[2]u32 {
    const t = cd.drc.table(.must_contain);
    var best: ?[2]u32 = null;
    for (t.items(.outer), t.items(.inner), t.items(.min_count), t.items(.max_count)) |o, i, lo, hi| if (o == outer and i == inner) {
        best = if (best) |b| .{ @max(b[0], lo), @min(b[1], hi) } else .{ lo, hi };
    };
    return best;
}

/// The density rules on `layer`, in deck order, into `out` (cleared).
pub fn densityInto(gpa: Allocator, cd: *const CompiledDeck, layer: LayerId, out: *std.ArrayList(DensityLimit)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const rs = &cd.drc;
    for (rs.order.items, 0..) |slot, at| switch (slot.kind) {
        .density => {
            const r = rs.table(.density).get(slot.row);
            if (r.layer == layer) try out.append(gpa, .{ .rule = rs.id.items[at], .window = .{ r.window, r.step }, .limit = r.limit, .sense = r.sense });
        },
        .global_density => {
            const r = rs.table(.global_density).get(slot.row);
            if (r.layer == layer) try out.append(gpa, .{ .rule = rs.id.items[at], .window = null, .limit = r.limit, .sense = r.sense });
        },
        else => {},
    };
}

/// The `antenna` rows, then the `antenna_electrical` rows, that count
/// `collector` among their collectors, each in deck order; `out` refilled.
pub fn antennaInto(gpa: Allocator, cd: *const CompiledDeck, collector: LayerId, out: *std.ArrayList(AntennaLimit)) Allocator.Error!void {
    out.clearRetainingCapacity();
    try antennaRows(gpa, &cd.erc.tables.antenna, collector, out);
    try antennaRows(gpa, &cd.erc.tables.antenna_electrical, collector, out);
}

/// The `em_current_density` rows naming `layer`, in deck order; `out`
/// refilled.
pub fn emLimitInto(gpa: Allocator, cd: *const CompiledDeck, layer: LayerId, out: *std.ArrayList(EmLimit)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const t = &cd.erc.tables.em_current_density;
    for (t.head.rule.items, 0..) |rule, row| {
        const from = t.layer_start.items[row];
        const at = from + (std.mem.indexOfScalar(LayerId, t.layer.items[from..t.layer_start.items[row + 1]], layer) orelse continue);
        try out.append(gpa, .{ .rule = rule, .max_density = t.max_density.items[at], .max_current_per_cut = t.max_current_per_cut.items[at] });
    }
}

/// The voltage limits on device model `model` (an interned model name).
pub fn fetLimits(cd: *const CompiledDeck, model: StrId) FetLimits {
    return .{ .gate_oxide = smallest(&cd.erc.tables.gate_oxide, model), .drain_source = smallest(&cd.erc.tables.drain_source, model) };
}

/// The mismatch coefficients of device model `model` (an interned model
/// name), in SI, each for a pair of devices: a `single` statement's area
/// coefficients times √2, since two independent devices' difference has
/// twice one's variance. Null when no `matching` statement names it.
pub fn matching(cd: *const CompiledDeck, model: StrId) ?Matching {
    for (cd.deck.matching) |row| if (row.model == model) {
        var pair = row.stated;
        if (row.basis == .single) {
            inline for (.{ "avt", "abeta", "ar", "ka" }) |f| if (@field(pair, f)) |v| {
                @field(pair, f) = v * std.math.sqrt2;
            };
        }
        return pair;
    };
    return null;
}

// ---- private ----

fn antennaRows(gpa: Allocator, t: anytype, collector: LayerId, out: *std.ArrayList(AntennaLimit)) Allocator.Error!void {
    for (t.head.rule.items, 0..) |rule, row| {
        const from = t.collector_start.items[row];
        const at = from + (std.mem.indexOfScalar(LayerId, t.collector.items[from..t.collector_start.items[row + 1]], collector) orelse continue);
        try out.append(gpa, .{ .rule = rule, .gate = t.gate.items[row], .max_ratio = t.max_ratio.items[row], .measure = t.collector_measure.items[at], .diode = t.diode.items[row] });
    }
}

/// The least `max_voltage` of the rows naming `model`.
fn smallest(t: *const ModelLimitTable, model: StrId) ?Millivolts {
    var best: ?Millivolts = null;
    for (t.max_voltage.items, 0..) |v, row| {
        const models = t.model.items[t.model_start.items[row]..t.model_start.items[row + 1]];
        if (std.mem.indexOfScalar(StrId, models, model) == null) continue;
        if (best == null or v.raw < best.?.raw) best = v;
    }
    return best;
}

fn bump(best: *?Dbu, limit: Dbu) void {
    best.* = @max(best.* orelse limit, limit);
}

/// The least or most `limit` of kind `k`'s rows on `layer`.
fn extreme(cd: *const CompiledDeck, comptime k: Kind, layer: LayerId, comptime pick: enum { least, most }) ?@FieldType(rows.Row(k), "limit") {
    const t = cd.drc.table(k);
    var best: ?@FieldType(rows.Row(k), "limit") = null;
    for (t.items(.layer), t.items(.limit)) |on, limit| if (on == layer) {
        best = if (best) |b| (if (pick == .least) @min(b, limit) else @max(b, limit)) else limit;
    };
    return best;
}
