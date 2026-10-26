//! Whether a typed rule's values are ones its kind can hold: every length,
//! area and fraction positive (a fraction finite), every required count at
//! least 1, an angle rule allowing some angle, a spacing table complete and
//! monotone. The deck compiler holds every row to it; a rule built in code
//! is held to the same. In: one `Rule`, its set (for its spacing table) and
//! its id. Out: nothing, or the first failing value in field order as a
//! named error. Ported from crates/check/src/drc/ruleset.rs (`Rule::validate`).
//!
//! Contents:
//! - `pub fn validate(id: StrId, rule: Rule, rs: *const RuleSet, diag: *Diagnostic) Error!void`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const StrId = geom.StrId;
const rows = @import("rows.zig");
const Rule = rows.Rule;
const RuleSet = @import("rule_set.zig").RuleSet;
const params = @import("params.zig");
const Error = params.Error;
const Diagnostic = params.Diagnostic;

/// The checks, each recording the row and the failing value.
const Check = struct {
    id: StrId,
    diag: *Diagnostic,

    fn refuse(c: Check, limit: i64) Error {
        c.diag.* = .{ .rule = c.id, .limit = limit };
        return error.NonPositiveLimit;
    }

    fn badTable(c: Check) Error {
        c.diag.* = .{ .rule = c.id };
        return error.BadTable;
    }

    fn length(c: Check, value: Dbu) Error!void {
        if (value <= 0) return c.refuse(value);
    }

    fn lengths(c: Check, values: []const Dbu) Error!void {
        for (values) |x| try c.length(x);
    }

    fn atLeastZero(c: Check, value: Dbu) Error!void {
        if (value < 0) return c.refuse(value);
    }

    fn area(c: Check, value: DbuArea) Error!void {
        if (value <= 0) return c.refuse(std.math.cast(i64, value) orelse std.math.minInt(i64));
    }

    /// `!(x > 0)` also refuses NaN, which would compare clean everywhere.
    fn fraction(c: Check, value: f64) Error!void {
        if (value > 0 and std.math.isFinite(value)) return;
        const shown: i64 = if (std.math.isNan(value)) 0 else std.math.lossyCast(i64, value);
        return c.refuse(shown);
    }

    fn count(c: Check, value: u32) Error!void {
        if (value == 0) return c.refuse(0);
    }
};

/// The first value of `rule` that fails, in field order:
/// `NonPositiveLimit` for a value that is not positive, `MissingParam` for
/// an angle rule allowing nothing, `BadTable` for a missing or invalid
/// table, `WrongParamType` for an SADP rule whose same-colour space is
/// below its different-colour space.
pub fn validate(id: StrId, rule: Rule, rs: *const RuleSet, diag: *Diagnostic) Error!void {
    const v: Check = .{ .id = id, .diag = diag };
    switch (rule) {
        .min_width, .max_width, .min_edge_length, .notch, .min_spacing, .corner_to_corner, .edge_min_length, .edge_width => |r| try v.length(r.limit),
        .min_spacing_diff, .projection_spacing, .overlap => |r| try v.length(r.limit),
        .noncoincident_enclosure, .max_enclosure, .adjacent_enclosure => |r| try v.length(r.limit),
        .min_extension => |r| try v.length(r.limit),
        .max_distance_to_tap => |r| try v.length(r.limit),
        .off_grid => |r| try v.length(r.pitch),
        .net_spacing => |r| try v.length(r.limit),
        .via_array_spacing => |r| try v.length(r.limit),
        .edge_spacing => |r| try v.length(r.limit),
        .edge_enclosure => |r| try v.length(r.limit),
        .edge_facing_space => |r| try v.length(r.limit),
        .max_cut_spacing => |r| try v.length(r.limit),
        .stack_spacing => |r| try v.length(r.limit),
        .min_step => |r| {
            try v.length(r.limit);
            if (r.length_sum) |s| try v.length(s);
        },
        .min_step_adjacent => |r| {
            try v.length(r.limit);
            switch (r.neighbour) {
                .adjacent => |a| {
                    try v.length(a.length);
                    if (a.eol) |e| try v.length(e);
                },
                .between_eol => |e| try v.length(e),
            }
        },
        .cut_size => |r| {
            try v.length(r.width);
            try v.length(r.height);
        },
        .metal_width_via => |r| {
            try v.length(r.below_band.from);
            try v.length(r.above_band.from);
            try v.length(r.width);
            try v.length(r.height);
            if (!r.below_band.widthsOnly() or !r.above_band.widthsOnly()) return v.badTable();
        },
        .min_enclosure, .asymmetric_enclosure => |r| {
            try v.length(r.limit);
            if (r.wire.extra_cut) |e| try v.length(e.within);
            if (r.wire.length[0]) |l| try v.length(l);
            if (r.wire.length[1]) |l| try v.length(l);
        },
        .eol_spacing => |r| try v.lengths(&.{ r.eol_width, r.limit }),
        .prl_spacing => |r| try v.lengths(&.{ r.prl_threshold, r.limit }),
        .wide_dependent_spacing => |r| try v.lengths(&.{ r.width_threshold, r.limit }),
        .attached_wide_spacing => |r| try v.lengths(&.{ r.width_threshold, r.attached, r.limit }),
        .min_area, .min_enclosed_area, .total_area => |r| try v.area(r.limit),
        .cheesing => |r| try v.area(r.max_unslotted),
        .density => |r| {
            try v.lengths(&.{ r.window, r.step });
            try v.fraction(r.limit);
        },
        .density_balance => |r| {
            try v.lengths(&.{ r.window, r.step });
            try v.fraction(r.limit);
        },
        // The bands are checked where they are filed.
        .cover_density => |r| try v.lengths(&.{ r.window, r.step }),
        .cut_area_change, .pattern_match => {},
        .mean_critical_area => |r| try v.area(r.limit),
        .via_redundancy => |r| {
            try v.length(r.pitch);
            if (r.space < 0) return v.refuse(r.space);
            try v.fraction(r.limit);
        },
        .dfm_score => |r| {
            try v.length(r.required);
            try v.length(r.recommended - r.required);
            try v.fraction(r.rate);
            try v.fraction(r.limit);
        },
        .global_density => |r| try v.fraction(r.limit),
        .aspect_ratio => |r| try v.fraction(r.limit),
        .region_density => |r| try v.fraction(r.limit),
        .min_interior_angle => |r| try v.fraction(r.limit),
        .angle => |r| if (r.allowed == 0) {
            diag.* = .{ .rule = id, .param = "angle" };
            return error.MissingParam;
        },
        .redundant_via => |r| {
            try v.count(r.min_count);
            try v.length(r.within);
        },
        .multi_patterning => |r| {
            try v.count(r.colors);
            try v.length(r.color_spacing);
        },
        .anchored_patterning => |r| {
            try v.count(r.colors);
            try v.length(r.color_spacing);
        },
        .sadp_line_end => |r| try v.lengths(&.{ r.ends.adjacent, r.ends.tip, r.ends.overlap, r.ends.corner, r.ends.offset }),
        .sadp => |r| {
            try v.lengths(&.{ r.different, r.same });
            if (r.track) |t| try v.lengths(&t);
            if (r.same < r.different) {
                diag.* = .{ .rule = id, .param = "same" };
                return error.WrongParamType;
            }
        },
        .critical_area => |r| {
            try v.length(r.radius);
            try v.area(r.limit);
        },
        .minimum_cut => |r| {
            try v.length(r.width);
            if (r.thin) |t| try v.lengths(&t);
            if (r.within) |w| try v.length(w);
            try v.count(r.min_count);
        },
        .via_stack => |r| try v.count(r.max_height),
        .cut_spacing => |r| {
            try v.length(r.limit);
            if (r.adjacent != 0) try v.length(r.within);
        },
        // The bound stated: `max_count` when there is one, else `min_count`.
        .must_contain => |r| try v.count(if (r.max_count == std.math.maxInt(u32)) r.min_count else r.max_count),
        // A shape count of zero is a limit; the lists, class and span tables,
        // runs that may be 0 and a forbidden range's order are checked where
        // they are filed.
        .forbidden, .origin => {},
        .must_be_inside, .count, .cut_class, .allowed_width, .polygon_validity => {},
        .tip_spacing_table, .two_width_spacing_table, .span_length, .cut_class_spacing => {},
        .full_width, .gate_corner => {},
        .forbidden_spacing => |r| try v.lengths(&.{ r.min, r.max }),
        .eol_within_spacing => |r| {
            try v.length(r.eol_width);
            if (r.parallel) |p| try v.length(p.space);
            if (r.end_to_end) |e| try v.length(e);
            try v.length(r.limit);
            const q = r.lef58;
            if (q.side_length) |s| try v.length(s.length);
            if (q.opposite_width) |w| try v.length(w);
            if (q.parallel_min_length) |l| try v.length(l);
            if (q.end_prl) |e| try v.lengths(&e);
            if (q.wrong_dir) |w| try v.length(w.space);
            if (q.extension) |e| try v.length(e);
            if (q.enclose_cut) |e| try v.lengths(&.{ e.within, e.space });
        },
        .eol_keep_out => |r| {
            try v.lengths(&.{ r.eol_width, r.forward });
            if (r.except_within) |w| if (w[1] <= w[0]) return v.refuse(w[1] - w[0]);
        },
        .eol_extension_spacing => |r| {
            // One to three rows, stated first, their widths rising strictly.
            if (r.rows[0] == null) return v.badTable();
            for (1..3) |i| if (r.rows[i]) |b| {
                const a = r.rows[i - 1] orelse return v.badTable();
                if (!(a.eol_width < b.eol_width)) return v.badTable();
            };
            for (r.rows) |maybe| if (maybe) |row| {
                try v.length(row.eol_width);
                try v.atLeastZero(row.extension);
                if (row.end_to_end) |e| try v.atLeastZero(e);
            };
            if (r.side_length) |s| try v.length(s.length);
            try v.length(r.limit);
        },
        .protrusion_width => |r| try v.lengths(&.{ r.wide, r.limit }),
        .keep_out_zone => |r| {
            // An oblong class: a square one has no long axis to grow along.
            try v.length(r.class[0]);
            try v.length(r.class[1] - r.class[0]);
            if (r.to) |t| try v.length(t[0]);
            for ([4]Dbu{ r.end[0], r.end[1], r.side[0], r.side[1] }) |x| try v.atLeastZero(x);
        },
        .convex_corner_spacing => |r| {
            if (r.except_eol) |e| try v.length(e);
            try v.length(r.limit);
        },
        .exact_pitch => |r| try v.length(r.pitch),
        .spacing_table => |r| if (r.table >= rs.spacing_space.len() or !rs.spacingTable(r.table).isValid()) return v.badTable(),
    }
}

// ---- private ----
