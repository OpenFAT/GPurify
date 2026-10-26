//! DFM score: a spacing, width or enclosure check run at its recommended
//! value, its findings replaced by at most one, the design's score
//! `Π (1 - rate · (1 - s))` over the findings' scores `s` (the measured
//! value placed between required and recommended, clamped to [0, 1]), at
//! the lowest-scoring finding's marker, when it is below the limit. In: one
//! `DfmScore` row. Out: zero or one violation. Ported from
//! crates/check/src/drc/ruleset.rs (the `DfmScore` arm and `dfm_scored`).
//!
//! Contents:
//! - `pub fn dfmScore(c: *const Ctx, r: DfmScore) Error!Verdict`

const std = @import("std");
const geom = @import("geom");
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const width = @import("width.zig");
const spacing = @import("spacing.zig");
const enc = @import("overlay_enclosure.zig");

pub fn dfmScore(c: *const Ctx, r: rows.DfmScore) Error!Verdict {
    const before = c.out.len();
    const found: Verdict = switch (r.check) {
        .space => try spacing.minSpacing(c, .{ .layer = r.layer, .limit = r.recommended }),
        .width => try width.facing(c, r.layer, r.recommended, .width),
        .enclosure => if (r.outer) |outer| try enc.enclosure(c, outer, r.layer, r.recommended, .any, .every_side) else report.refused,
    };
    const span: f64 = @floatFromInt(r.recommended - r.required);
    var worst: ?u32 = null;
    var worst_score: f64 = 0;
    var design: f64 = 1;
    for (before..c.out.len()) |k| {
        const row = c.out.get(@intCast(k));
        const s: f64 = if (row.measured.kind == .length) std.math.clamp(@as(f64, @floatFromInt(@as(i64, @intCast(row.measured.exact())) - r.required)) / span, 0, 1) else 0;
        // The first lowest score, as Rust's `min_by` over `total_cmp`.
        if (worst == null or s < worst_score) {
            worst = @intCast(k);
            worst_score = s;
        }
        design *= 1 - r.rate * (1 - s);
    }
    const kept: ?report.Violation = if (worst != null and design < r.limit) c.out.get(worst.?) else null;
    c.out.truncate(before);
    if (kept) |row| {
        var v = row;
        v.measured = .ratio(design);
        v.limit = .ratio(r.limit);
        try c.push(v);
    }
    return found;
}
