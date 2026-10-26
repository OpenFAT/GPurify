//! The side tables a rule row names by index, as views over a `RuleSet`'s
//! CSR columns: spacing tables, cut-class tables, class tables, span tables,
//! cover bands, cut-area bands and defect sizes. In: slices. Out: each
//! table's validity (what the deck compiler refuses) and the lookups the
//! checks and `requiredSpacing` share. Ported from
//! crates/check/src/drc/ruleset.rs (`SpacingTable`, `CutClassTable`,
//! `ClassTable`, `SpanTable`, `CoverBands`, `CutAreaBands`, `DefectSizes`,
//! `is_wide`, `prl_holds`, `is_end_of_line`).
//!
//! Contents:
//! - `pub const SpacingTable = struct`, `isValid(t: SpacingTable) bool`, `at(t, row: usize, column: usize) Dbu`,
//!   `rowSquare(t, row: usize) Dbu`, `column(t, row: usize, run_at: anytype) usize`
//! - `pub const CutClassTable = struct`, `isValid`, `at`, `classOf(t, w: Dbu, h: Dbu) ?usize`
//! - `pub const ClassTable = struct`, `isValidTips(t) bool`, `isValidTwoWidths(t) bool`, `at`
//! - `pub const SpanTable = struct`, `isValid`, `pub fn nextLegal(legal: []const Dbu, span: i64) ?i64`
//! - `pub const CoverBands = struct`, `isValid`, `need(b, coverage: f64) ?f64`
//! - `pub const CutAreaBands = struct`, `isValid`, `limit(b, cuts: u32) ?DbuArea`
//! - `pub const DefectSizes = struct`, `isValid`
//! - `pub fn isWide(width: Dbu, side: Dbu) bool`, `pub fn prlHolds(run: i64, threshold: Dbu) bool`,
//!   `pub fn isEndOfLine(length: i64, eol_width: Dbu) bool`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;

/// LEF `SPACINGTABLE PARALLELRUNLENGTH`: a pair needs `space[row][column]`,
/// `row` the last width the wider shape exceeds, `column` the last run the
/// pair exceeds; the first row and column always apply.
pub const SpacingTable = struct {
    /// Run lengths heading the columns: from 0, strictly rising.
    prl: []const Dbu,
    /// Widths heading the rows: from 0, strictly rising.
    width: []const Dbu,
    /// Row-major, `width.len` rows of `prl.len` positive cells.
    space: []const Dbu,

    /// Complete and monotone: cells never fall along a row or down a column.
    pub fn isValid(t: SpacingTable) bool {
        const columns = t.prl.len;
        if (!startsAndRises(t.prl) or !startsAndRises(t.width)) return false;
        if (t.space.len != columns * t.width.len) return false;
        for (t.space) |cell| if (cell <= 0) return false;
        for (0..t.width.len) |r| for (1..columns) |c| if (t.at(r, c - 1) > t.at(r, c)) return false;
        for (columns..t.space.len) |i| if (t.space[i - columns] > t.space[i]) return false;
        return true;
    }

    pub fn at(t: SpacingTable, row: usize, column_: usize) Dbu {
        return t.space[row * t.prl.len + column_];
    }

    /// The side of the square that makes a part wide enough for `row`: one
    /// past the row's width, a row holding what is strictly wider.
    pub fn rowSquare(t: SpacingTable, row: usize) Dbu {
        return t.width[row] + 1;
    }

    /// The column a pair takes in `row`: the last whose run the pair's run
    /// strictly exceeds, the run read by `run_at.run(space)` off edges at
    /// most that column's cell apart; 0 when it exceeds none.
    pub fn column(t: SpacingTable, row: usize, run_at: anytype) usize {
        var c = t.prl.len;
        while (c > 1) {
            c -= 1;
            if (t.prl[c] < run_at.run(t.at(row, c))) return c;
        }
        return 0;
    }
};

/// `LEF58_SPACINGTABLE CUTCLASS`: class `i` is a `short[i] x long[i]` cut;
/// `space` is square, two rows and columns per class (END, then SIDE).
pub const CutClassTable = struct {
    short: []const Dbu,
    long: []const Dbu,
    space: []const Dbu,

    /// Complete and symmetric, with distinct positive classes.
    pub fn isValid(t: CutClassTable) bool {
        const n = t.short.len;
        if (n == 0 or t.long.len != n or t.space.len != 4 * n * n) return false;
        for (t.short, t.long, 0..) |s, l, i| {
            if (s <= 0 or s > l) return false;
            for (0..i) |j| if (t.short[j] == s and t.long[j] == l) return false;
        }
        for (t.space) |cell| if (cell <= 0) return false;
        for (0..2 * n) |r| for (0..2 * n) |c| if (t.at(r, c) != t.at(c, r)) return false;
        return true;
    }

    pub fn at(t: CutClassTable, row: usize, column: usize) Dbu {
        return t.space[row * 2 * t.short.len + column];
    }

    /// The class a `w x h` cut belongs to, either way round.
    pub fn classOf(t: CutClassTable, w: Dbu, h: Dbu) ?usize {
        const s = @min(w, h);
        const l = @max(w, h);
        for (t.short, t.long, 0..) |ts, tl, i| if (ts == s and tl == l) return i;
        return null;
    }
};

/// A square table indexed by the classes of two edges or shapes: a pair
/// needs `space[i][j]`. Classes start at 0.
pub const ClassTable = struct {
    /// Class thresholds: from 0, rising.
    class: []const Dbu,
    /// Per class, a run a pair must exceed, null for none; empty for a table
    /// that reads no runs.
    prl: []const ?Dbu,
    /// Row-major, `class.len` squared positive cells, symmetric.
    space: []const Dbu,

    /// What `tip_spacing_table` reads: square, symmetric, positive, classes
    /// strictly rising, no runs.
    pub fn isValidTips(t: ClassTable) bool {
        return t.prl.len == 0 and t.isSquare() and strictlyRising(t.class);
    }

    /// What `two_width_spacing_table` reads: square, symmetric, positive,
    /// cells never falling along a row, widths from 0 never falling, runs
    /// starting with none and never falling among those stated.
    pub fn isValidTwoWidths(t: ClassTable) bool {
        const n = t.class.len;
        if (t.prl.len != n or n == 0 or t.prl[0] != null) return false;
        var last: Dbu = 0;
        for (t.prl) |p| if (p) |run| {
            if (run < 0 or run < last) return false;
            last = run;
        };
        if (!t.isSquare()) return false;
        for (1..n) |i| if (t.class[i - 1] > t.class[i]) return false;
        for (0..n) |i| for (1..n) |j| if (t.at(i, j - 1) > t.at(i, j)) return false;
        return true;
    }

    pub fn at(t: ClassTable, i: usize, j: usize) Dbu {
        return t.space[i * t.class.len + j];
    }

    // ---- private ----

    fn isSquare(t: ClassTable) bool {
        const n = t.class.len;
        if (n == 0 or t.class[0] != 0 or t.space.len != n * n) return false;
        for (t.space) |cell| if (cell <= 0) return false;
        for (0..n) |i| for (0..i) |j| if (t.at(i, j) != t.at(j, i)) return false;
        return true;
    }
};

/// The legal spans of `span_length`, per axis: every listed length but the
/// last exactly, and the last and anything longer.
pub const SpanTable = struct {
    x: []const Dbu,
    y: []const Dbu,
    /// `EXCEPTOTHERSPAN` of `x`: a horizontal span is held only when the
    /// rectangle's height is greater; null holds every one.
    x_except: ?Dbu = null,
    y_except: ?Dbu = null,

    /// Both lists non-empty, positive and strictly rising.
    pub fn isValid(t: SpanTable) bool {
        for ([2][]const Dbu{ t.x, t.y }) |legal| {
            if (legal.len == 0 or legal[0] <= 0 or !strictlyRising(legal)) return false;
        }
        return true;
    }
};

/// The bands of `cover_density`: from each coverage of the covering layer,
/// the density the held layer needs.
pub const CoverBands = struct {
    cover: []const f64,
    density: []const f64,
    /// A coverage exactly at a band's start is in that band (else below).
    inclusive: bool,

    pub fn isValid(b: CoverBands) bool {
        if (b.cover.len == 0 or b.cover.len != b.density.len) return false;
        for (b.cover, b.density, 0..) |c, d, i| {
            if (!(c >= 0 and c <= 1 and d >= 0 and d <= 1)) return false;
            if (i > 0 and !(b.cover[i - 1] < c)) return false;
        }
        return true;
    }

    /// The density a window covered to `coverage` needs, null below every band.
    pub fn need(b: CoverBands, coverage: f64) ?f64 {
        var i = b.cover.len;
        while (i > 0) {
            i -= 1;
            const reaches = if (b.inclusive) coverage >= b.cover[i] else coverage > b.cover[i];
            if (reaches) return b.density[i];
        }
        return null;
    }
};

/// The bands of `cut_area_change`: from each cut count, the change allowed.
pub const CutAreaBands = struct {
    cuts: []const u32,
    change: []const DbuArea,

    pub fn isValid(b: CutAreaBands) bool {
        if (b.cuts.len == 0 or b.cuts[0] < 1 or b.cuts.len != b.change.len) return false;
        for (1..b.cuts.len) |i| if (b.cuts[i - 1] >= b.cuts[i]) return false;
        for (b.change) |c| if (c < 0) return false;
        return true;
    }

    /// The change a connector of `cuts` cuts may have, null below every band.
    pub fn limit(b: CutAreaBands, cuts: u32) ?DbuArea {
        var i = b.cuts.len;
        while (i > 0) {
            i -= 1;
            if (cuts >= b.cuts[i]) return b.change[i];
        }
        return null;
    }
};

/// The defect sizes of `mean_critical_area`: radii and their weights.
pub const DefectSizes = struct {
    radius: []const Dbu,
    weight: []const f64,

    pub fn isValid(d: DefectSizes) bool {
        if (d.radius.len == 0 or d.radius[0] <= 0 or d.radius.len != d.weight.len) return false;
        if (!strictlyRising(d.radius)) return false;
        for (d.weight) |w| if (!(w >= 0 and w <= 1)) return false;
        return true;
    }
};

/// The shortest legal span on `legal` longer than `span`, or null when
/// `span` itself is legal.
pub fn nextLegal(legal: []const Dbu, span: i64) ?i64 {
    if (legal.len == 0) return null;
    if (span >= legal[legal.len - 1]) return null;
    for (legal) |l| if (l == span) return null;
    for (legal) |l| if (l > span) return l;
    return null;
}

/// Whether a shape `width` wide holds an axis-aligned `side` square.
pub fn isWide(width: Dbu, side: Dbu) bool {
    return width >= side;
}

/// Whether facing edges running `run` alongside are held to a `prl_spacing`
/// of `threshold`.
pub fn prlHolds(run: i64, threshold: Dbu) bool {
    return run >= threshold;
}

/// Whether an edge `length` long is an end of line to an `eol_spacing` of
/// `eol_width`: strictly shorter.
pub fn isEndOfLine(length: i64, eol_width: Dbu) bool {
    return length < eol_width;
}

// ---- private ----

fn startsAndRises(steps: []const Dbu) bool {
    return steps.len > 0 and steps[0] == 0 and strictlyRising(steps);
}

fn strictlyRising(steps: []const Dbu) bool {
    for (1..steps.len) |i| if (steps[i - 1] >= steps[i]) return false;
    return true;
}

test "a spacing table is valid only complete and monotone" {
    // Oracle: `SpacingTable::is_valid`'s definition, hand-built tables: one
    // that falls down a column, one that does not start at 0, one short.
    const good: SpacingTable = .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30, 40 } };
    try std.testing.expect(good.isValid());
    try std.testing.expect(!(SpacingTable{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 5, 40 } }).isValid());
    try std.testing.expect(!(SpacingTable{ .prl = &.{ 1, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30, 40 } }).isValid());
    try std.testing.expect(!(SpacingTable{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30 } }).isValid());
}

test "next legal span and cover band lookups" {
    // Oracle: hand values from the definitions: 150 on [100, 200, 400] next
    // takes 200; 200 and 500 are legal. Bands start at 0.2 and 0.5.
    const legal = [_]Dbu{ 100, 200, 400 };
    try std.testing.expectEqual(@as(?i64, 200), nextLegal(&legal, 150));
    try std.testing.expectEqual(@as(?i64, null), nextLegal(&legal, 200));
    try std.testing.expectEqual(@as(?i64, null), nextLegal(&legal, 500));
    const bands: CoverBands = .{ .cover = &.{ 0.2, 0.5 }, .density = &.{ 0.1, 0.3 }, .inclusive = false };
    try std.testing.expectEqual(@as(?f64, null), bands.need(0.2));
    try std.testing.expectEqual(@as(?f64, 0.1), bands.need(0.3));
    try std.testing.expectEqual(@as(?f64, 0.3), bands.need(0.9));
}
