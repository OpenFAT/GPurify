//! The tables a rule set carries beside its rules, and what they answer:
//! each `isValid` against the conditions its struct states, one condition
//! broken at a time from a valid table and each boundary value on both
//! sides, and the band lookups (`CutAreaBands.limit`, `CoverBands.need`,
//! the pattern anchor), and `deck.query.requiredSpacing` rule by rule.
//! Ported from crates/check/tests/drc/tables.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const tables = check.drc.tables;
const Rule = check.drc.Rule;
const RuleSet = check.drc.RuleSet;

/// A pattern by value: window, shapes and don't-care boxes.
const Pattern = struct {
    window: [2]Dbu,
    shapes: []const Bbox,
    ignore: []const Bbox,

    fn anchor(p: Pattern) !?[2]i64 {
        return check.drc.pattern.anchorOf(gpa, p.window, p.shapes, p.ignore);
    }

    fn isValid(p: Pattern) !bool {
        return check.drc.pattern.isValid(gpa, p.window, p.shapes, p.ignore);
    }
};

/// An L of 100-wide arms in a 300 window: `[0, 300] x [0, 100]` and `[0,
/// 100] x [100, 300]`.
const ell_shapes = [2]Bbox{ box(.{ 0, 0, 300, 100 }), box(.{ 0, 100, 100, 300 }) };

// ---- private ----

fn box(b: [4]i64) Bbox {
    return .{ .xlo = b[0], .ylo = b[1], .xhi = b[2], .yhi = b[3] };
}

fn ell(ignore: []const Bbox) Pattern {
    return .{ .window = .{ 300, 300 }, .shapes = &ell_shapes, .ignore = ignore };
}

/// `rule` validated alone; the error, or null when it passes, with the
/// refused value.
fn validated(rule: Rule) !?i64 {
    var rs: RuleSet = .{};
    defer rs.deinit(gpa);
    var diag: check.drc.params.Diagnostic = .{};
    check.drc.validate.validate(common.rule_id, rule, &rs, &diag) catch |e| {
        try testing.expectEqual(error.NonPositiveLimit, e);
        return diag.limit;
    };
    return null;
}

test "cut area bands hold their stated shape and pick the last band reached" {
    // Oracle: `CutAreaBands`' rustdoc: "at least 1, rising strictly" starts,
    // one change per band, "0 or more" changes; and `limit` takes the last
    // band whose start the count reaches. The valid base `[1, 4] -> [10000,
    // 40000]` is broken one condition at a time; 0 and 1 are the first
    // start's two sides, -1 and 0 the change's, equal starts the rise's.
    // Counts 0 to 5 read: none below 1, 10000 from 1 to 3, 40000 from 4.
    const B = tables.CutAreaBands;
    try testing.expect((B{ .cuts = &.{ 1, 4 }, .change = &.{ 10_000, 40_000 } }).isValid());
    try testing.expect((B{ .cuts = &.{ 1, 4 }, .change = &.{ 0, 0 } }).isValid());
    const broken = [_]B{
        .{ .cuts = &.{}, .change = &.{} },
        .{ .cuts = &.{ 0, 4 }, .change = &.{ 10_000, 40_000 } },
        .{ .cuts = &.{ 1, 4 }, .change = &.{10_000} },
        .{ .cuts = &.{ 1, 1 }, .change = &.{ 10_000, 40_000 } },
        .{ .cuts = &.{ 4, 1 }, .change = &.{ 10_000, 40_000 } },
        .{ .cuts = &.{ 1, 4 }, .change = &.{ -1, 40_000 } },
        .{ .cuts = &.{ 1, 4 }, .change = &.{ 10_000, -1 } },
    };
    for (broken) |b| try testing.expect(!b.isValid());
    const table: B = .{ .cuts = &.{ 1, 4 }, .change = &.{ 10_000, 40_000 } };
    const want = [6]?DbuArea{ null, 10_000, 10_000, 10_000, 40_000, 40_000 };
    for (want, 0..) |w, n| try testing.expectEqual(w, table.limit(@intCast(n)));
}

test "defect sizes hold their stated shape" {
    // Oracle: `DefectSizes`' rustdoc: radii "positive and rising strictly",
    // "one weight per radius, from 0 to 1". Broken one condition at a time;
    // radius 0 against 1, weights -0.1 and 1.1 against 0 and 1.
    const S = tables.DefectSizes;
    try testing.expect((S{ .radius = &.{ 1, 20 }, .weight = &.{ 0.0, 1.0 } }).isValid());
    const broken = [_]S{
        .{ .radius = &.{}, .weight = &.{} },
        .{ .radius = &.{ 0, 20 }, .weight = &.{ 0.5, 0.5 } },
        .{ .radius = &.{ 10, 20 }, .weight = &.{0.5} },
        .{ .radius = &.{ 20, 20 }, .weight = &.{ 0.5, 0.5 } },
        .{ .radius = &.{ 20, 10 }, .weight = &.{ 0.5, 0.5 } },
        .{ .radius = &.{ 10, 20 }, .weight = &.{ -0.1, 0.5 } },
        .{ .radius = &.{ 10, 20 }, .weight = &.{ 0.5, 1.1 } },
    };
    for (broken) |b| try testing.expect(!b.isValid());
}

test "cover bands hold their stated shape and read a start as written" {
    // Oracle: `CoverBands`' rustdoc: fractions in `0..=1`, one density per
    // band, starts rising strictly; `need` takes the last band whose start
    // the coverage reaches, at the start itself only when `inclusive`. Bands
    // from 25 %, 50 % and 100 % asking 25 %, 50 % and 75 %: 20 % is below
    // every band; exactly 50 % is the 50 % band inclusive and the 25 % band
    // exclusive; exactly 25 % exclusive is below every band; full cover is
    // the last band inclusive and the middle one exclusive.
    const C = tables.CoverBands;
    const cover = [_]f64{ 0.25, 0.5, 1.0 };
    const density = [_]f64{ 0.25, 0.5, 0.75 };
    try testing.expect((C{ .cover = &cover, .density = &density, .inclusive = true }).isValid());
    try testing.expect((C{ .cover = &.{ 0.0, 1.0 }, .density = &.{ 0.0, 1.0 }, .inclusive = false }).isValid());
    const broken = [_]C{
        .{ .cover = &.{}, .density = &.{}, .inclusive = true },
        .{ .cover = &.{ 0.25, 0.5 }, .density = &.{0.25}, .inclusive = true },
        .{ .cover = &.{ -0.01, 0.5 }, .density = &.{ 0.25, 0.5 }, .inclusive = true },
        .{ .cover = &.{ 0.25, 1.01 }, .density = &.{ 0.25, 0.5 }, .inclusive = true },
        .{ .cover = &.{ 0.25, 0.5 }, .density = &.{ -0.01, 0.5 }, .inclusive = true },
        .{ .cover = &.{ 0.25, 0.5 }, .density = &.{ 0.25, 1.01 }, .inclusive = true },
        .{ .cover = &.{ 0.5, 0.5 }, .density = &.{ 0.25, 0.5 }, .inclusive = true },
    };
    for (broken) |b| try testing.expect(!b.isValid());
    const inclusive: C = .{ .cover = &cover, .density = &density, .inclusive = true };
    const exclusive: C = .{ .cover = &cover, .density = &density, .inclusive = false };
    const cases = [_]struct { f64, ?f64, ?f64 }{
        .{ 0.2, null, null },
        .{ 0.25, 0.25, null },
        .{ 0.3, 0.25, 0.25 },
        .{ 0.5, 0.5, 0.25 },
        .{ 0.6, 0.5, 0.5 },
        .{ 1.0, 0.75, 0.5 },
    };
    for (cases) |cs| {
        try testing.expectEqual(cs[1], inclusive.need(cs[0]));
        try testing.expectEqual(cs[2], exclusive.need(cs[0]));
    }
}

test "span tables hold both lists to positive strict rises" {
    // Oracle: `SpanTable`'s rustdoc: both lists "positive and rising
    // strictly". Broken in either list: empty, a first length of 0 (1 is
    // valid), equal neighbours, falling neighbours.
    const T = tables.SpanTable;
    try testing.expect((T{ .x = &.{ 1, 200 }, .y = &.{120} }).isValid());
    const broken = [_]T{
        .{ .x = &.{}, .y = &.{120} },
        .{ .x = &.{ 60, 200 }, .y = &.{} },
        .{ .x = &.{ 0, 200 }, .y = &.{120} },
        .{ .x = &.{ 60, 200 }, .y = &.{0} },
        .{ .x = &.{ 200, 200 }, .y = &.{120} },
        .{ .x = &.{ 60, 200 }, .y = &.{ 120, 60 } },
    };
    for (broken) |b| try testing.expect(!b.isValid());
}

test "spacing tables are complete and never fall" {
    // Oracle: `SpacingTable`'s rustdoc: run lengths and widths "start at 0
    // and strictly rise", `width.len()` rows of `prl.len()` positive cells
    // that "never fall along a row or column". A 2 x 2 base `[[10, 20], [30,
    // 40]]`, and equal cells everywhere (never falling, so valid), broken one
    // condition at a time.
    const T = tables.SpacingTable;
    try testing.expect((T{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30, 40 } }).isValid());
    try testing.expect((T{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 10, 10, 10 } }).isValid());
    const broken = [_]T{
        .{ .prl = &.{ 1, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30, 40 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 1, 200 }, .space = &.{ 10, 20, 30, 40 } },
        .{ .prl = &.{ 0, 0 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30, 40 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 0 }, .space = &.{ 10, 20, 30, 40 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 20, 30 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 0, 20, 30, 40 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 20, 10, 30, 40 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 30, 40, 10, 20 } },
        .{ .prl = &.{ 0, 100 }, .width = &.{ 0, 200 }, .space = &.{ 10, 40, 30, 35 } },
    };
    for (broken) |b| try testing.expect(!b.isValid());
}

test "cut class tables are complete symmetric and distinct" {
    // Oracle: `CutClassTable`'s rustdoc: classes with a positive short side
    // no longer than the long one, distinct, `2n` x `2n` positive cells,
    // symmetric. The two-class base (170 x 170 and 190 x 2000) and a square
    // class (short equal to long, valid) broken one condition at a time.
    const T = tables.CutClassTable;
    const flat = [16]Dbu{ 170, 170, 510, 510, 170, 170, 510, 510, 510, 510, 350, 510, 510, 510, 510, 510 };
    try testing.expect((T{ .short = &.{ 170, 190 }, .long = &.{ 170, 2000 }, .space = &flat }).isValid());
    var asymmetric = flat;
    asymmetric[1] = 200;
    var zero = flat;
    zero[5] = 0;
    const broken = [_]T{
        .{ .short = &.{}, .long = &.{}, .space = &.{} },
        .{ .short = &.{ 170, 190 }, .long = &.{170}, .space = &flat },
        .{ .short = &.{ 0, 190 }, .long = &.{ 170, 2000 }, .space = &flat },
        .{ .short = &.{ 171, 190 }, .long = &.{ 170, 2000 }, .space = &flat },
        .{ .short = &.{ 170, 170 }, .long = &.{ 170, 170 }, .space = &flat },
        .{ .short = &.{ 170, 190 }, .long = &.{ 170, 2000 }, .space = flat[0..15] },
        .{ .short = &.{ 170, 190 }, .long = &.{ 170, 2000 }, .space = &zero },
        .{ .short = &.{ 170, 190 }, .long = &.{ 170, 2000 }, .space = &asymmetric },
    };
    for (broken) |b| try testing.expect(!b.isValid());
}

test "class tables hold what each kind reads" {
    // Oracle: `ClassTable`'s rustdoc. A tip table: no runs, classes from 0
    // rising strictly, square, symmetric, positive. A two-width table: one
    // run per class, the first none, runs 0 or more and never falling,
    // classes from 0 never falling, cells never falling along a row. Each
    // base broken one condition at a time; equal classes separate the two
    // (strict for tips, allowed for widths).
    const T = tables.ClassTable;
    try testing.expect((T{ .class = &.{ 0, 100 }, .prl = &.{}, .space = &.{ 10, 20, 20, 30 } }).isValidTips());
    const broken_tips = [_]T{
        .{ .class = &.{ 0, 100 }, .prl = &.{ null, null }, .space = &.{ 10, 20, 20, 30 } },
        .{ .class = &.{ 1, 100 }, .prl = &.{}, .space = &.{ 10, 20, 20, 30 } },
        .{ .class = &.{ 0, 0 }, .prl = &.{}, .space = &.{ 10, 20, 20, 30 } },
        .{ .class = &.{ 0, 100 }, .prl = &.{}, .space = &.{ 10, 20, 20 } },
        .{ .class = &.{ 0, 100 }, .prl = &.{}, .space = &.{ 10, 0, 0, 30 } },
        .{ .class = &.{ 0, 100 }, .prl = &.{}, .space = &.{ 10, 20, 25, 30 } },
    };
    for (broken_tips) |b| try testing.expect(!b.isValidTips());
    const runs = [_]?Dbu{ null, 50, 50 };
    const cells = [_]Dbu{ 10, 20, 30, 20, 20, 30, 30, 30, 40 };
    try testing.expect((T{ .class = &.{ 0, 100, 100 }, .prl = &runs, .space = &cells }).isValidTwoWidths());
    try testing.expect((T{ .class = &.{ 0, 100 }, .prl = &.{ null, 0 }, .space = &.{ 10, 10, 10, 10 } }).isValidTwoWidths());
    const broken_widths = [_]T{
        .{ .class = &.{ 0, 100, 100 }, .prl = &.{ null, 50 }, .space = &cells },
        .{ .class = &.{ 0, 100, 100 }, .prl = &.{ 0, 50, 50 }, .space = &cells },
        .{ .class = &.{ 0, 100, 100 }, .prl = &.{ null, -1, 50 }, .space = &cells },
        .{ .class = &.{ 0, 100, 100 }, .prl = &.{ null, 50, 40 }, .space = &cells },
        .{ .class = &.{ 0, 100, 50 }, .prl = &runs, .space = &cells },
        .{ .class = &.{ 0, 100, 100 }, .prl = &runs, .space = &.{ 10, 20, 30, 20, 20, 30, 30, 30 } },
        .{ .class = &.{ 0, 100, 100 }, .prl = &runs, .space = &.{ 30, 20, 10, 20, 20, 30, 10, 30, 40 } },
        .{ .class = &.{ 0, 100, 100 }, .prl = &runs, .space = &.{ 10, 20, 30, 20, 40, 30, 30, 30, 40 } },
        .{ .class = &.{ 0, 100, 100 }, .prl = &runs, .space = &.{ 10, 20, 30, 15, 20, 30, 30, 30, 40 } },
    };
    for (broken_widths) |b| try testing.expect(!b.isValidTwoWidths());
}

test "a pattern anchors on its least free inner corner" {
    // Oracle: `Pattern`'s rustdoc. The merged L's corners are (0, 0), (300,
    // 0), (300, 100), (100, 100), (100, 300) and (0, 300); only (100, 100)
    // lies strictly inside the window, so it is the anchor. A don't-care box
    // covering it, or whose edge or corner passes through it ("their edges
    // included"), leaves no anchor; one starting a unit past it does not.
    const anchored: ?[2]i64 = .{ 100, 100 };
    try testing.expectEqual(anchored, try ell(&.{}).anchor());
    try testing.expectEqual(anchored, try ell(&.{box(.{ 150, 150, 300, 300 })}).anchor());
    try testing.expectEqual(anchored, try ell(&.{box(.{ 101, 101, 300, 300 })}).anchor());
    for ([_][4]i64{ .{ 50, 50, 150, 150 }, .{ 100, 100, 200, 200 }, .{ 0, 0, 100, 100 }, .{ 0, 100, 100, 200 } }) |ig| {
        try testing.expectEqual(@as(?[2]i64, null), try ell(&.{box(ig)}).anchor());
    }
    // Two shapes side by side, (100, 0) shared: the merged bar's corners
    // all lie on the window's edge, so there is no anchor.
    const bar: Pattern = .{ .window = .{ 300, 300 }, .shapes = &.{ box(.{ 0, 0, 100, 300 }), box(.{ 100, 0, 300, 300 }) }, .ignore = &.{} };
    try testing.expectEqual(@as(?[2]i64, null), try bar.anchor());
}

test "a pattern is valid only inside a positive window with an anchor" {
    // Oracle: `Pattern::is_valid`'s rustdoc: a positive window, every shape
    // and don't-care box a rectangle with positive sides inside it, at least
    // one shape, and an anchor. The L is valid; a shape or box touching the
    // window's far edge is still inside; each other case breaks one
    // condition.
    try testing.expect(try ell(&.{}).isValid());
    try testing.expect(try ell(&.{box(.{ 200, 200, 300, 300 })}).isValid());
    const shifted = struct {
        fn f(i: usize, b: [4]i64) [2]Bbox {
            var s = ell_shapes;
            s[i] = box(b);
            return s;
        }
    }.f;
    const s0 = shifted(0, .{ -1, 0, 300, 100 });
    const s1 = shifted(0, .{ 0, -1, 300, 100 });
    const s2 = shifted(1, .{ 0, 100, 0, 300 });
    const s3 = shifted(0, .{ 0, 0, 300, 0 });
    const cases = [_]Pattern{
        .{ .window = .{ 0, 300 }, .shapes = &ell_shapes, .ignore = &.{} },
        .{ .window = .{ 300, 0 }, .shapes = &ell_shapes, .ignore = &.{} },
        .{ .window = .{ 299, 300 }, .shapes = &ell_shapes, .ignore = &.{} },
        .{ .window = .{ 300, 299 }, .shapes = &ell_shapes, .ignore = &.{} },
        .{ .window = .{ 300, 300 }, .shapes = &.{}, .ignore = &.{} },
        .{ .window = .{ 300, 300 }, .shapes = &s0, .ignore = &.{} },
        .{ .window = .{ 300, 300 }, .shapes = &s1, .ignore = &.{} },
        .{ .window = .{ 300, 300 }, .shapes = &s2, .ignore = &.{} },
        .{ .window = .{ 300, 300 }, .shapes = &s3, .ignore = &.{} },
        ell(&.{box(.{ 250, 250, 301, 300 })}),
        ell(&.{box(.{ 250, 250, 250, 300 })}),
        ell(&.{box(.{ 90, 90, 110, 110 })}),
    };
    for (cases) |p| try testing.expect(!try p.isValid());
}

test "validate holds each value to its stated range" {
    // Oracle: `Rule::validate`'s rustdoc and each variant's: a via
    // redundancy's `space` is "0 or more"; a DFM score's recommended value
    // lies above its required one (refused with their difference); a keep-out
    // zone's class is oblong (its long side past its short one, refused with
    // the difference), its `to` class positive, its zone reaches 0 or more.
    // Each value is read at the line and one unit past it.
    const a = common.a;
    const b = common.b;
    const c: geom.LayerId = @fromBackingInt(2);
    const redundancy = struct {
        fn f(l: [3]geom.LayerId, space: i64) Rule {
            return .{ .via_redundancy = .{ .cut = l[0], .lower = l[1], .upper = l[2], .pitch = 200, .space = space, .limit = 0.5 } };
        }
    }.f;
    try testing.expectEqual(@as(?i64, null), try validated(redundancy(.{ a, b, c }, 0)));
    try testing.expectEqual(@as(?i64, -1), try validated(redundancy(.{ a, b, c }, -1)));
    const dfm = struct {
        fn f(required: i64, recommended: i64) Rule {
            return .{ .dfm_score = .{ .check = .space, .layer = common.a, .outer = null, .required = required, .recommended = recommended, .rate = 0.5, .limit = 0.9 } };
        }
    }.f;
    try testing.expectEqual(@as(?i64, null), try validated(dfm(100, 101)));
    try testing.expectEqual(@as(?i64, 0), try validated(dfm(100, 100)));
    try testing.expectEqual(@as(?i64, -1), try validated(dfm(100, 99)));
    const zone = struct {
        fn f(class: [2]i64, to: ?[2]i64, end: [2]i64, side: [2]i64) Rule {
            return .{ .keep_out_zone = .{ .layer = common.a, .class = class, .to = to, .end = end, .side = side } };
        }
    }.f;
    try testing.expectEqual(@as(?i64, null), try validated(zone(.{ 100, 101 }, .{ 1, 1 }, .{ 0, 0 }, .{ 0, 0 })));
    try testing.expectEqual(@as(?i64, 0), try validated(zone(.{ 100, 100 }, null, .{ 10, 80 }, .{ 50, 20 })));
    try testing.expectEqual(@as(?i64, -1), try validated(zone(.{ 100, 99 }, null, .{ 10, 80 }, .{ 50, 20 })));
    try testing.expectEqual(@as(?i64, 0), try validated(zone(.{ 0, 300 }, null, .{ 10, 80 }, .{ 50, 20 })));
    try testing.expectEqual(@as(?i64, 0), try validated(zone(.{ 100, 300 }, .{ 0, 100 }, .{ 10, 80 }, .{ 50, 20 })));
    const bad = [_]struct { [2]i64, [2]i64, i64 }{
        .{ .{ -1, 80 }, .{ 50, 20 }, -1 },
        .{ .{ 10, -2 }, .{ 50, 20 }, -2 },
        .{ .{ 10, 80 }, .{ -3, 20 }, -3 },
        .{ .{ 10, 80 }, .{ 50, -4 }, -4 },
    };
    for (bad) |cs| try testing.expectEqual(@as(?i64, cs[2]), try validated(zone(.{ 100, 300 }, null, cs[0], cs[1])));
}

test "required spacing answers for its own layer at its thresholds" {
    // Oracle: `Rule::required_spacing`'s doc: a rule answers only for its
    // own layer, a wide rule only for a pair whose wider width reaches the
    // threshold (`isWide`: at it counts), a run rule only for a run reaching
    // its threshold, an end-of-line rule only for a facing edge strictly
    // shorter than its width, a table its largest applicable row. Each case
    // is read at the threshold and one unit short of it, and on the other
    // layer.
    const a = common.a;
    const b = common.b;
    const Q = check.deck.query;
    const rules = [_]Rule{
        .{ .wide_dependent_spacing = .{ .layer = a, .width_threshold = 3000, .limit = 400 } },
        .{ .attached_wide_spacing = .{ .layer = a, .width_threshold = 3000, .attached = 500, .limit = 450 } },
        .{ .prl_spacing = .{ .layer = a, .prl_threshold = 1000, .limit = 300 } },
        .{ .eol_spacing = .{ .layer = a, .eol_width = 200, .limit = 250 } },
        .{ .min_spacing = .{ .layer = a, .limit = 140 } },
        .{ .spacing_table = .{ .layer = a, .table = 0 } },
    };
    const q = struct {
        fn f(width: i64, run: i64, eol: ?i64) Q.SpacingQuery {
            return .{ .width_a = 100, .width_b = width, .run_length = run, .end_of_line = eol };
        }
    }.f;
    const at = struct {
        fn f(rule: Rule, layer: geom.LayerId, query: Q.SpacingQuery) !?i64 {
            var cd: check.deck.CompiledDeck = .{ .grid = try geom.Grid.init(1000), .deck = .{}, .drc = .{} };
            defer cd.deinit(gpa);
            _ = try cd.drc.addSpacingTable(gpa, .{ .prl = &.{ 0, 1000 }, .width = &.{ 0, 2999 }, .space = &.{ 140, 200, 300, 500 } });
            try cd.drc.push(gpa, common.rule_id, rule, .@"error");
            return Q.requiredSpacing(&cd, layer, query);
        }
    }.f;
    for (rules) |r| try testing.expectEqual(@as(?i64, null), try at(r, b, q(3000, 1000, 10)));
    const min = rules[4];
    const wide = rules[0];
    const attached = rules[1];
    const prl = rules[2];
    const eol = rules[3];
    const table = rules[5];
    try testing.expectEqual(@as(?i64, 140), try at(min, a, q(100, 0, null)));
    try testing.expectEqual(@as(?i64, 400), try at(wide, a, q(3000, 0, null)));
    try testing.expectEqual(@as(?i64, null), try at(wide, a, q(2999, 0, null)));
    try testing.expectEqual(@as(?i64, 450), try at(attached, a, q(3000, 0, null)));
    try testing.expectEqual(@as(?i64, null), try at(attached, a, q(2999, 0, null)));
    try testing.expectEqual(@as(?i64, 300), try at(prl, a, q(100, 1000, null)));
    try testing.expectEqual(@as(?i64, null), try at(prl, a, q(100, 999, null)));
    try testing.expectEqual(@as(?i64, 250), try at(eol, a, q(100, 0, 199)));
    try testing.expectEqual(@as(?i64, null), try at(eol, a, q(100, 0, 200)));
    try testing.expectEqual(@as(?i64, null), try at(eol, a, q(100, 0, null)));
    // Row 1 holds widths past 2999 (a 3000 square fits), column 1 runs past
    // 1000.
    try testing.expectEqual(@as(?i64, 140), try at(table, a, q(100, 1000, null)));
    try testing.expectEqual(@as(?i64, 200), try at(table, a, q(100, 1001, null)));
    try testing.expectEqual(@as(?i64, 300), try at(table, a, q(3000, 1000, null)));
    try testing.expectEqual(@as(?i64, 500), try at(table, a, q(3000, 1001, null)));
    try testing.expectEqual(@as(?i64, 200), try at(table, a, q(2999, 1001, null)));
}
