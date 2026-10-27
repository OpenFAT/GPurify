//! Every rule kind and layer operation the shipped decks do not exercise: its
//! constructor, the printer and the query API, on one deck that states each of
//! them (the spellings of docs/src/reference/deck and docs/src/reference/drc).
//! Ported from crates/check/tests/deck/kinds.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const DeckBuilder = check.deck.DeckBuilder;
const query = check.deck.query;
const row = check.deck.rules.row;
const l = check.deck.expr.layer;

const text =
    \\grid 1nm
    \\layer m = gds(1, 0)
    \\layer r = gds(2, 0)
    \\layer v = gds(3, 0)
    \\layer v2 = gds(4, 0)
    \\layer m2 = gds(5, 0)
    \\layer t = gds(6, 0)
    \\layer rects = m.rectangles()
    \\layer squares = m.squares()
    \\layer odd = m.non_rectangles()
    \\layer long = m.with_bbox_max(> 1000nm)
    \\layer thin = v.non_squares().with_bbox_min(>= 100nm, < 200nm)
    \\layer roomy = m.with_rect(300nm x 100nm)
    \\layer cramped = m.without_rect(200nm x 200nm)
    \\layer stray = t.texts_outside(m)
    \\rule c.min count(m) >= 1
    \\rule c.max count(m) <= 4
    \\rule ar aspect_ratio(m) <= 3
    \\rule ta total_area(m) <= 1000000nm2
    \\rule cc size(v; allowed: [150nm x 150nm, 230nm x 150nm])
    \\rule ew width(m.edges().horizontal()) >= 40nm
    \\rule fs facing_space(m.edges().vertical()) >= 30nm
    \\rule fs.prl facing_space(m.edges().vertical(); prl: 50nm) >= 30nm
    \\rule rd.min region_density(m, r) >= 0.1
    \\rule rd.max region_density(m, r) <= 0.5
    \\rule aw width(m; allowed: [350nm, 690nm])
    \\rule aw.open width(thin; allowed: [100nm, 150nm], open_last: true)
    \\rule ia.m interior_angle(m) >= 87deg
    \\rule ia interior_angle() >= 90deg
    \\rule vd.m valid(m)
    \\rule vd valid()
    \\rule ms.edges min_step(m; max_edges: 2) >= 50nm
    \\rule ms.inside min_step(m; corner: inside, length_sum: 100nm) >= 50nm
    \\rule ms.step min_step(m; corner: step, length_sum: none) >= 60nm
    \\rule msa min_step(m; adjacent: 60nm, except_rectangle: true) >= 50nm
    \\rule msa.eol min_step(m; adjacent: 30nm, adjacent_eol: 120nm, except_rectangle: false) >= 50nm
    \\rule msa.between min_step(m; between_eol: 120nm) >= 50nm
    \\rule vs.single via_stack(m, v, m2, v2, r, single) <= 2
    \\rule ss stack_space(v2, v, m2; same_net: true) >= 200nm
    \\rule ss.all stack_space(v2, v, m2) >= 200nm
    \\rule vm via_map(v, m, m2; below_min: 40nm, below_max: 60nm, above_min: 80nm, above_max: 80nm, cut: 30nm x 40nm)
    \\rule mcs max_space(v) <= 2000nm
    \\rule mcs.cls max_space(thin, v) <= 2000nm
    \\rule odd.none forbidden(odd)
    \\rule stray.none forbidden(stray)
    \\rule tip tip_space_table(m; length: [0nm, 100nm], space: [[60nm, 70nm], [70nm, 80nm]])
    \\rule tw two_width_table(m; width: [0nm, 200nm], prl: [none, 300nm], space: [[50nm, 60nm], [60nm, 90nm]])
    \\rule sl span_length(m; x: [100nm, 200nm], y: [150nm])
    \\rule sl.except span_length(m; x: [100nm, 200nm], y: [150nm], x_except: 300nm, y_except: none)
    \\rule fsp forbidden_space(m; min: 40nm, max: 50nm, prl: 0nm)
    \\rule eol.w eol_space(m; eol_width: 60nm, within: 20nm, parallel: none, end_to_end: none) >= 80nm
    \\rule eol.p eol_space(m; eol_width: 60nm, within: 20nm, parallel: (space: 120nm, within: 50nm, two_edges: true), end_to_end: 70nm) >= 80nm
    \\rule eol.58 eol_space(m; eol_width: 60nm, within: 20nm, parallel: (space: 120nm, within: 50nm, two_edges: true), end_to_end: 70nm, side_length: (length: 100nm, maximum: false, two_sides: true), opposite_width: 80nm, parallel_more: (subtract_eol_width: true, min_length: 90nm), end_prl: (space: 100nm, prl: 30nm), wrong_dir: (space: 90nm, horizontal: true), extension: 10nm, enclose_cut: (cut: v, within: 40nm, space: 110nm, all_cuts: true)) >= 80nm
    \\rule ko eol_keep_out(m; eol_width: 60nm, backward: 0nm, side: 30nm, forward: 90nm)
    \\rule ko.q eol_keep_out(m; eol_width: 60nm, backward: 0nm, side: 30nm, forward: 90nm, except_within: (low: 10nm, high: 40nm), corner_only: true)
    \\rule ext eol_extension_space(m; eol_width: [110nm, 150nm], extension: [140nm, 120nm], end_to_end: [none, 130nm], side_length: (length: 300nm, two_sides: true)) >= 100nm
    \\rule ext.one eol_extension_space(m; eol_width: [110nm], extension: [140nm], end_to_end: [none], side_length: none) >= 100nm
    \\rule or origin(r)
    \\rule mca critical_area(m; radii: [50nm, 100nm, 200nm], weights: [0.6, 0.3, 0.1]) <= 1um2
    \\rule vr via_redundancy(v, m, m2; pitch: 300nm, space: 100nm) >= 0.9
    \\rule dfm dfm_score(m; check: space, required: 180nm, recommended: 220nm, rate: 0.01) >= 0.99
    \\rule dfm.enc dfm_score(v, m; check: enclosure, required: 10nm, recommended: 40nm, rate: 0.5) >= 0.9
    \\rule pat pattern(m; window: 300nm x 300nm, shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm, 100nm x 300nm], ignore: [150nm x 150nm, 300nm x 300nm])
    \\rule pat.none pattern(m; window: 300nm x 300nm, shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm, 100nm x 300nm], ignore: none)
    \\rule ir cut_area_change(v, v2, m, m2; cuts: [1, 11, 101], change: [200000nm2, 300000nm2, 700000nm2])
    \\rule cvd cover_density(m, r; window: 700um, step: 70um, cover: [30%, 40%, 100%], density: [30%, 40%, 70%], inclusive: true)
    \\rule pw protrusion_width(m; wide: 1200nm) >= 280nm
    \\rule koz keep_out_zone(v; class: 100nm x 300nm, to: none, end_side: 10nm, end_forward: 80nm, side_side: 50nm, side_forward: 20nm)
    \\rule koz.to keep_out_zone(v; class: 100nm x 300nm, to: 100nm x 100nm, end_side: 0nm, end_forward: 80nm, side_side: 50nm, side_forward: 0nm)
    \\rule cs corner_space(m; corner_to_corner: true, except_eol: 60nm) >= 100nm
    \\rule cs.none corner_space(m; corner_to_corner: false, except_eol: none) >= 100nm
    \\rule pv pitch(m, vertical) == 27nm
    \\rule ph pitch(m, horizontal) == 54nm
    \\rule ps space(m, r, projection) >= 235nm
    \\rule en.band enclosure(v, m; width: 400nm, below: 1000nm) >= 30nm
    \\rule en.op enclosure(v, m, opposite; below: 340nm) >= 60nm
    \\rule en.except enclosure(v, m; width: 300nm, except_extra_cut: 200nm, other: m2) >= 30nm
    \\rule en.extra enclosure(v, m, opposite; width: 300nm, below: 1000nm, extra_cut: 200nm, other: m2) >= 50nm
    \\rule en.long enclosure(v, m, opposite; length: 700nm) >= 50nm
    \\rule en.short enclosure(v, m; length_below: 700nm, below: 1000nm) >= 30nm
    \\rule en.nc enclosure(v, m, noncoincident) >= 20nm
    \\rule fw full_width(v, m)
    \\rule en.max enclosure(v, m) <= 95nm
    \\rule bend bend(m, r)
    \\rule corner covers_corner(m, r)
    \\rule mc min_cuts(v, m2, m; width: 1000nm, within: 300nm) >= 2
    \\rule mc.thin min_cuts(v, m2, m; width: 1000nm, length: 20000nm, distance: 5000nm) >= 2
    \\rule mc.any min_cuts(v, m, m2; width: 500nm) >= 3
    \\rule stack via_stack(v, v2) <= 2
    \\rule cs.center space(v, center) >= 250nm
    \\rule cs.adj adjacent_space(v; cuts: 3, within: 250nm) >= 180nm
    \\rule ccs cut_class_space(v;
    \\    short: [170nm, 190nm],
    \\    long:  [170nm, 2000nm],
    \\    space: [[170nm, 170nm, 510nm, 510nm],
    \\            [170nm, 170nm, 510nm, 510nm],
    \\            [510nm, 510nm, 350nm, 510nm],
    \\            [510nm, 510nm, 510nm, 510nm]])
    \\rule mc.ge contains(m, v) >= 1
    \\rule mc.le contains(r, v) <= 1
    \\rule mc.eq contains(m2, v) == 2
    \\temperature 358.15K nominal 303.15K
    \\pex m thickness 360nm height 1376nm sheet 0.125ohm area_cap 25.8aF/um2 fringe_cap 40.5aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
    \\
;

// ---- private ----

/// `text` built in code, statement by statement.
fn build(b: *DeckBuilder) anyerror!void {
    @setEvalBranchQuota(100_000);
    for ([_][]const u8{ "m", "r", "v", "v2", "m2", "t" }, 1..) |name, gds| try b.layer(name, .{ @intCast(gds), 0 });
    try b.derived("rects", l("m").rectangles());
    try b.derived("squares", l("m").squares());
    try b.derived("odd", l("m").nonRectangles());
    try b.derived("long", l("m").withBboxMax(&.{.{ .above = 1000 }}));
    try b.derived("thin", l("v").nonSquares().withBboxMin(&.{ .{ .at_least = 100 }, .{ .below = 200 } }));
    try b.derived("roomy", l("m").withRect(300, 100));
    try b.derived("cramped", l("m").withoutRect(200, 200));
    try b.derived("stray", l("t").textsOutside(l("m")));
    try b.rule("c.min", row(.count, .{ .layer = l("m") }, .{ .limit = 1, .maximum = false }));
    try b.rule("c.max", row(.count, .{ .layer = l("m") }, .{ .limit = 4, .maximum = true }));
    try b.rule("ar", row(.aspect_ratio, .{ .layer = l("m") }, .{ .limit = 3.0 }));
    try b.rule("ta", row(.total_area, .{ .layer = l("m") }, .{ .limit = 1_000_000 }));
    try b.rule("cc", row(.cut_class, .{ .layer = l("v") }, .{ .width = &.{ 150, 230 }, .height = &.{ 150, 150 } }));
    try b.rule("ew", row(.edge_width, .{ .edges = l("m").edges().horizontal() }, .{ .limit = 40 }));
    try b.rule("fs", row(.edge_facing_space, .{ .edges = l("m").edges().vertical() }, .{ .limit = 30 }));
    try b.rule("fs.prl", row(.edge_facing_space, .{ .edges = l("m").edges().vertical() }, .{ .limit = 30, .prl = 50 }));
    try b.rule("rd.min", row(.region_density, .{ .layer = l("m"), .region = l("r") }, .{ .limit = 0.1, .maximum = false }));
    try b.rule("rd.max", row(.region_density, .{ .layer = l("m"), .region = l("r") }, .{ .limit = 0.5, .maximum = true }));
    try b.rule("aw", row(.allowed_width, .{ .layer = l("m") }, .{ .width = &.{ 350, 690 } }));
    try b.rule("aw.open", row(.allowed_width, .{ .layer = l("thin") }, .{ .width = &.{ 100, 150 }, .open_last = true }));
    try b.rule("ia.m", row(.min_interior_angle, .{ .layer = l("m") }, .{ .limit = 87.0 }));
    try b.rule("ia", row(.min_interior_angle, .{}, .{ .limit = 90.0 }));
    try b.rule("vd.m", row(.polygon_validity, .{ .layer = l("m") }, .{}));
    try b.rule("vd", row(.polygon_validity, .{}, .{}));
    try b.rule("ms.edges", row(.min_step, .{ .layer = l("m") }, .{ .limit = 50, .max_edges = 2 }));
    try b.rule("ms.inside", row(.min_step, .{ .layer = l("m") }, .{ .limit = 50, .corner = .inside, .length_sum = 100 }));
    try b.rule("ms.step", row(.min_step, .{ .layer = l("m") }, .{ .limit = 60, .corner = .step }));
    try b.rule("msa", row(.min_step_adjacent, .{ .layer = l("m") }, .{ .limit = 50, .adjacent = 60, .except_rectangle = true }));
    try b.rule("msa.eol", row(.min_step_adjacent, .{ .layer = l("m") }, .{ .limit = 50, .adjacent = 30, .adjacent_eol = 120, .except_rectangle = false }));
    try b.rule("msa.between", row(.min_step_adjacent, .{ .layer = l("m") }, .{ .limit = 50, .between_eol = 120 }));
    try b.rule("vs.single", row(.via_stack, .{ .cuts = &.{ "m", "v", "m2", "v2", "r" } }, .{ .max_height = 2, .single = true }));
    try b.rule("ss", row(.stack_spacing, .{ .a = l("v2"), .b = l("v"), .metal = l("m2") }, .{ .same_net = true, .limit = 200 }));
    try b.rule("ss.all", row(.stack_spacing, .{ .a = l("v2"), .b = l("v"), .metal = l("m2") }, .{ .same_net = false, .limit = 200 }));
    try b.rule("vm", row(.metal_width_via, .{ .cut = l("v"), .below = l("m"), .above = l("m2") }, .{ .below_min = 40, .below_max = 60, .above_min = 80, .above_max = 80, .cut_width = 30, .cut_height = 40 }));
    try b.rule("mcs", row(.max_cut_spacing, .{ .cut = l("v") }, .{ .limit = 2000 }));
    try b.rule("mcs.cls", row(.max_cut_spacing, .{ .cut = l("thin"), .others = l("v") }, .{ .limit = 2000 }));
    try b.rule("odd.none", row(.forbidden, .{ .layer = l("odd") }, .{}));
    try b.rule("stray.none", row(.forbidden, .{ .layer = l("stray") }, .{}));
    try b.rule("tip", row(.tip_spacing_table, .{ .layer = l("m") }, .{ .length = &.{ 0, 100 }, .space = &.{ 60, 70, 70, 80 } }));
    try b.rule("tw", row(.two_width_spacing_table, .{ .layer = l("m") }, .{ .width = &.{ 0, 200 }, .prl = &.{ null, 300 }, .space = &.{ 50, 60, 60, 90 } }));
    try b.rule("sl", row(.span_length, .{ .layer = l("m") }, .{ .x_spans = &.{ 100, 200 }, .y_spans = &.{150} }));
    try b.rule("sl.except", row(.span_length, .{ .layer = l("m") }, .{ .x_spans = &.{ 100, 200 }, .y_spans = &.{150}, .x_except = 300 }));
    try b.rule("fsp", row(.forbidden_spacing, .{ .layer = l("m") }, .{ .min = 40, .max = 50, .prl = 0 }));
    try b.rule("eol.w", row(.eol_within_spacing, .{ .layer = l("m") }, .{ .eol_width = 60, .eol_within = 20, .limit = 80 }));
    try b.rule("eol.p", row(.eol_within_spacing, .{ .layer = l("m") }, .{ .eol_width = 60, .eol_within = 20, .par_space = 120, .par_within = 50, .two_edges = true, .end_to_end = 70, .limit = 80 }));
    try b.rule("eol.58", row(.eol_within_spacing, .{ .layer = l("m") }, .{
        .eol_width = 60,
        .eol_within = 20,
        .par_space = 120,
        .par_within = 50,
        .two_edges = true,
        .end_to_end = 70,
        .limit = 80,
        .side_length = 100,
        .side_length_maximum = false,
        .side_length_two_sides = true,
        .opposite_width = 80,
        .par_subtract_eol_width = true,
        .par_min_length = 90,
        .end_prl_space = 100,
        .end_prl = 30,
        .wrong_dir_space = 90,
        .wrong_dir_horizontal = true,
        .eol_extension = 10,
        .enclose_cut_layer = "v",
        .enclose_cut_within = 40,
        .enclose_cut_space = 110,
        .enclose_cut_all = true,
    }));
    try b.rule("ko", row(.eol_keep_out, .{ .layer = l("m") }, .{ .eol_width = 60, .backward = 0, .side = 30, .forward = 90 }));
    try b.rule("ko.q", row(.eol_keep_out, .{ .layer = l("m") }, .{ .eol_width = 60, .backward = 0, .side = 30, .forward = 90, .within_low = 10, .within_high = 40, .corner_only = true }));
    try b.rule("ext", row(.eol_extension_spacing, .{ .layer = l("m") }, .{ .eol_width = &.{ 110, 150 }, .extension = &.{ 140, 120 }, .end_to_end = &.{ null, 130 }, .limit = 100, .side_length = 300, .side_length_two_sides = true }));
    try b.rule("ext.one", row(.eol_extension_spacing, .{ .layer = l("m") }, .{ .eol_width = &.{110}, .extension = &.{140}, .end_to_end = &.{null}, .limit = 100 }));
    try b.rule("or", row(.origin, .{ .layer = l("r") }, .{}));
    try b.rule("mca", row(.mean_critical_area, .{ .layer = l("m") }, .{ .radii = &.{ 50, 100, 200 }, .weights = &.{ 0.6, 0.3, 0.1 }, .limit = 1_000_000 }));
    try b.rule("vr", row(.via_redundancy, .{ .cut = l("v"), .lower = l("m"), .upper = l("m2") }, .{ .pitch = 300, .space = 100, .limit = 0.9 }));
    try b.rule("dfm", row(.dfm_score, .{ .layer = l("m") }, .{ .check = .space, .required = 180, .recommended = 220, .rate = 0.01, .limit = 0.99 }));
    try b.rule("dfm.enc", row(.dfm_score, .{ .layer = l("v"), .outer = l("m") }, .{ .check = .enclosure, .required = 10, .recommended = 40, .rate = 0.5, .limit = 0.9 }));
    const shape_x = [_]i64{ 0, 300, 0, 100 };
    const shape_y = [_]i64{ 0, 100, 100, 300 };
    try b.rule("pat", row(.pattern_match, .{ .layer = l("m") }, .{ .window_w = 300, .window_h = 300, .shape_x = &shape_x, .shape_y = &shape_y, .ignore_x = &.{ 150, 300 }, .ignore_y = &.{ 150, 300 } }));
    try b.rule("pat.none", row(.pattern_match, .{ .layer = l("m") }, .{ .window_w = 300, .window_h = 300, .shape_x = &shape_x, .shape_y = &shape_y, .ignore_x = &.{}, .ignore_y = &.{} }));
    try b.rule("ir", row(.cut_area_change, .{ .pre = l("v"), .post = l("v2"), .lower = l("m"), .upper = l("m2") }, .{ .cuts = &.{ 1, 11, 101 }, .change = &.{ 200_000, 300_000, 700_000 } }));
    try b.rule("cvd", row(.cover_density, .{ .layer = l("m"), .by = l("r") }, .{ .window = 700_000, .step = 70_000, .cover = &.{ 0.3, 0.4, 1.0 }, .density = &.{ 0.3, 0.4, 0.7 }, .inclusive = true }));
    try b.rule("pw", row(.protrusion_width, .{ .layer = l("m") }, .{ .wide = 1200, .limit = 280 }));
    try b.rule("koz", row(.keep_out_zone, .{ .layer = l("v") }, .{ .short = 100, .long = 300, .end_side = 10, .end_forward = 80, .side_side = 50, .side_forward = 20 }));
    try b.rule("koz.to", row(.keep_out_zone, .{ .layer = l("v") }, .{ .short = 100, .long = 300, .to_short = 100, .to_long = 100, .end_side = 0, .end_forward = 80, .side_side = 50, .side_forward = 0 }));
    try b.rule("cs", row(.convex_corner_spacing, .{ .layer = l("m") }, .{ .corner_to_corner = true, .except_eol = 60, .limit = 100 }));
    try b.rule("cs.none", row(.convex_corner_spacing, .{ .layer = l("m") }, .{ .corner_to_corner = false, .limit = 100 }));
    try b.rule("pv", row(.exact_pitch, .{ .layer = l("m") }, .{ .vertical = true, .limit = 27 }));
    try b.rule("ph", row(.exact_pitch, .{ .layer = l("m") }, .{ .vertical = false, .limit = 54 }));
    try b.rule("ps", row(.projection_spacing, .{ .a = l("m"), .b = l("r") }, .{ .limit = 235 }));
    try b.rule("en.band", row(.min_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .limit = 30, .wire_width = 400, .wire_below = 1000 }));
    try b.rule("en.op", row(.asymmetric_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .min_one_side = 60, .wire_below = 340 }));
    try b.rule("en.except", row(.min_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .limit = 30, .wire_width = 300, .extra_cut_within = 200, .extra_cut_other = "m2", .extra_cut_only = false }));
    try b.rule("en.extra", row(.asymmetric_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .min_one_side = 50, .wire_width = 300, .wire_below = 1000, .extra_cut_within = 200, .extra_cut_other = "m2", .extra_cut_only = true }));
    try b.rule("en.long", row(.asymmetric_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .min_one_side = 50, .length_from = 700 }));
    try b.rule("en.short", row(.min_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .limit = 30, .wire_below = 1000, .length_below = 700 }));
    try b.rule("en.nc", row(.noncoincident_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .limit = 20 }));
    try b.rule("fw", row(.full_width, .{ .inner = l("v"), .outer = l("m") }, .{}));
    try b.rule("en.max", row(.max_enclosure, .{ .inner = l("v"), .outer = l("m") }, .{ .limit = 95 }));
    try b.rule("bend", row(.gate_corner, .{ .layer = l("m"), .reference = l("r") }, .{ .of_reference = false }));
    try b.rule("corner", row(.gate_corner, .{ .layer = l("m"), .reference = l("r") }, .{ .of_reference = true }));
    try b.rule("mc", row(.minimum_cut, .{ .cut = l("v"), .wide = l("m2"), .other = l("m") }, .{ .width = 1000, .within = 300, .min_count = 2 }));
    try b.rule("mc.thin", row(.minimum_cut, .{ .cut = l("v"), .wide = l("m2"), .other = l("m") }, .{ .width = 1000, .min_count = 2, .length = 20_000, .distance = 5000 }));
    try b.rule("mc.any", row(.minimum_cut, .{ .cut = l("v"), .wide = l("m"), .other = l("m2") }, .{ .width = 500, .min_count = 3 }));
    try b.rule("stack", row(.via_stack, .{ .cuts = &.{ "v", "v2" } }, .{ .max_height = 2 }));
    try b.rule("cs.center", row(.cut_spacing, .{ .layer = l("v") }, .{ .center = true, .limit = 250 }));
    try b.rule("cs.adj", row(.cut_spacing, .{ .layer = l("v") }, .{ .center = false, .adjacent = 3, .within = 250, .limit = 180 }));
    try b.rule("ccs", row(.cut_class_spacing, .{ .layer = l("v") }, .{
        .class_short = &.{ 170, 190 },
        .class_long = &.{ 170, 2000 },
        .space = &.{ 170, 170, 510, 510, 170, 170, 510, 510, 510, 510, 350, 510, 510, 510, 510, 510 },
    }));
    try b.rule("mc.ge", row(.must_contain, .{ .outer = l("m"), .inner = l("v") }, .{ .min_count = 1 }));
    try b.rule("mc.le", row(.must_contain, .{ .outer = l("r"), .inner = l("v") }, .{ .max_count = 1 }));
    try b.rule("mc.eq", row(.must_contain, .{ .outer = l("m2"), .inner = l("v") }, .{ .count = 2 }));
    b.doc.temperature = .{ .operating_k = 358.15, .nominal_k = 303.15 };
    try b.doc.pex.append(b.arena, .{ .layer = "m", .row = .{ .thickness_nm = 360, .height_nm = 1376, .sheet_res_ohm_sq = 0.125, .area_cap_af_um2 = 25.8, .fringe_cap_af_um = 40.5, .tc = .{ 3.179e-3, 3.094e-7 } } });
}

/// The layer `name` of `c`'s deck.
fn layerOf(c: *const common.Compiled, name: []const u8) @import("geom").LayerId {
    return c.cd.deck.layers.id(&c.strings, name).?;
}

test "every new kind has a constructor equal to its text" {
    // Oracle: differential against the parser, the same deck written as text.
    try common.assertBuildEqualsText("new kinds", text, build);
}

test "every new kind survives printing" {
    // Oracle: round trip.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    try common.assertRoundTrip("new kinds", &c);
}

test "the new queries read what the deck states" {
    // Oracle: the deck text above: widths 350 and 690 nm; cut sizes 150 x
    // 150 and 150 x 230 nm (short side first, sorted); aspect ratio 3; total
    // area 10^6 nm^2; the strictest `min_step` 60 nm.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    const m = layerOf(&c, "m");
    const v = layerOf(&c, "v");
    try testing.expectEqualSlices(i64, &.{ 350, 690 }, query.allowedWidths(&c.cd, m).?);
    try testing.expectEqualSlices([2]i64, &.{ .{ 150, 150 }, .{ 150, 230 } }, query.cutClasses(&c.cd, v).?);
    try testing.expectEqual(@as(?f64, 3.0), query.maxAspectRatio(&c.cd, m));
    try testing.expectEqual(@as(?i128, 1_000_000), query.maxTotalArea(&c.cd, m));
    try testing.expectEqual(@as(?i64, 60), query.minStep(&c.cd, m));
    try testing.expectEqual(null, query.allowedWidths(&c.cd, v));
    try testing.expectEqual(null, query.allowedWidthsFrom(&c.cd, m));
    try testing.expectEqual(@as(?i64, 150), query.allowedWidthsFrom(&c.cd, layerOf(&c, "thin")));
}

test "the cut and enclosure queries read what the deck states" {
    // Oracle: the deck text above: projection 235 nm between `m` and `r`;
    // enclosures 30 nm all round (its band counted as every wire), 60 nm
    // opposite, 20 nm off `m`'s edge, at most 95 nm, full width; 2 cuts on
    // `m2` wider than 1000 nm and 3 on `m` wider than 500 nm; stacks of at
    // most 2; cut spacing 250 nm centre to centre, none edge to edge for
    // every cut (the 180 nm one holds only crowded cuts); the cut-class
    // table's 350 nm cell; `contains` bounds 1 to unbounded, 0 to 1 and
    // exactly 2.
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    const m = layerOf(&c, "m");
    const r = layerOf(&c, "r");
    const v = layerOf(&c, "v");
    const v2 = layerOf(&c, "v2");
    const m2 = layerOf(&c, "m2");
    try testing.expectEqual(@as(?i64, 235), query.projectionSpacing(&c.cd, r, m));
    const e = query.enclosure(&c.cd, v, m);
    try testing.expectEqual(@as(?i64, 30), e.all_sides);
    try testing.expectEqual(@as(?i64, 60), e.opposite);
    try testing.expectEqual(@as(?i64, 20), e.noncoincident);
    try testing.expectEqual(@as(?i64, 95), e.at_most);
    try testing.expect(e.full_width);
    try testing.expectEqual(@as(?u16, 2), query.minimumCuts(&c.cd, v, m2, 1001));
    try testing.expectEqual(null, query.minimumCuts(&c.cd, v, m2, 1000));
    try testing.expectEqual(@as(?u16, 3), query.minimumCuts(&c.cd, v, m, 501));
    try testing.expectEqual(@as(?u16, 2), query.maxViaStack(&c.cd, v2));
    try testing.expectEqual(null, query.maxViaStack(&c.cd, m));
    try testing.expectEqual(@as(?i64, 250), query.cutSpacing(&c.cd, v, true));
    try testing.expectEqual(null, query.cutSpacing(&c.cd, v, false));
    const table = query.cutClassSpacing(&c.cd, v).?;
    try testing.expectEqualSlices(i64, &.{ 170, 2000 }, table.long);
    try testing.expectEqual(@as(i64, 350), table.space[10]);
    try testing.expectEqual(@as(?[2]u32, .{ 1, std.math.maxInt(u32) }), query.contains(&c.cd, m, v));
    try testing.expectEqual(@as(?[2]u32, .{ 0, 1 }), query.contains(&c.cd, r, v));
    try testing.expectEqual(@as(?[2]u32, .{ 2, 2 }), query.contains(&c.cd, m2, v));
}
