//! Two metamorphic laws over the whole overlay family, run as one deck:
//! translation across the origin moves only the report, and scaling geometry
//! and deck together scales only the measurements. Both laws run every rule
//! into one table in a fixed call order, so the sequence, not just the set,
//! is compared. Every shape is drawn wholly negative and every strip and gap
//! it reports on has an odd width, so a truncating midpoint (rather than a
//! floored one) is caught by the translation. Ported from
//! crates/check/tests/drc/overlay_laws.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const Sink = common.Sink;
const gpa = common.gpa;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const RuleRun = check.report.RuleRun;
const LayoutBuilder = testgen.shapes.LayoutBuilder;

const enc_inner: u16 = 0;
const enc_outer: u16 = 1;
const ext_line: u16 = 2;
const ext_ref: u16 = 3;
const ovl_a: u16 = 4;
const ovl_b: u16 = 5;
const well: u16 = 6;
const tap_layer: u16 = 7;
/// Holds one triangle with an edge at a slope of 2, so a kind that reads
/// straight out from edges refuses a row naming it.
const bad: u16 = 8;
/// Declared and never drawn on: the tap rule skips a row naming it.
const empty: u16 = 9;
const layer_count = 10;

const ENC: StrId = @fromBackingInt(0);
const ENC_REFUSED: StrId = @fromBackingInt(1);
const ASYM: StrId = @fromBackingInt(2);
const EXT: StrId = @fromBackingInt(3);
const OVL: StrId = @fromBackingInt(4);
const TAP: StrId = @fromBackingInt(5);
const TAP_EMPTY: StrId = @fromBackingInt(6);

/// The five rules that must each report at least one violation before
/// either law compares anything.
const must_fire = [5]StrId{ ENC, ASYM, EXT, OVL, TAP };

/// The largest coordinate magnitude any shape reaches, and the largest
/// limit any rule carries, each checked against the domain under scale.
const coord_reach: i64 = 3_000;
const limit_reach: i64 = 499;

/// The nine midpoints this fixture makes the family compute: the two
/// operands, the floored answer, and the answer truncation would give.
const midpoints = [9][4]i64{
    .{ -110, -101, -106, -105 }, // min_enclosure, deficient left strip, x
    .{ -101, -50, -76, -75 }, // the inner shape's span: min_enclosure y, asymmetric x
    .{ -501, -400, -451, -450 }, // the unhosted shape's own centre, x
    .{ -403, -300, -352, -351 }, // the unhosted shape's own centre, y
    .{ -130, -101, -116, -115 }, // asymmetric_enclosure, the bottom strip, y
    .{ -300, -261, -281, -280 }, // min_extension, the left overhang, x
    .{ -251, -200, -226, -225 }, // min_extension, the shared span, y
    .{ -751, -700, -726, -725 }, // overlap, the intersection figure, x
    .{ -651, -600, -626, -625 }, // overlap, the intersection figure, y
};

/// The base run's reported points, in the order the calls produce them.
const base_points = [7][2]i64{
    .{ -106, -76 }, // min_enclosure, the hosted inner shape
    .{ -451, -352 }, // min_enclosure, the unhosted one
    .{ -76, -116 }, // asymmetric_enclosure, the hosted inner shape
    .{ -451, -352 }, // asymmetric_enclosure, the unhosted one
    .{ -281, -226 }, // min_extension
    .{ -726, -626 }, // overlap
    .{ -1_000, -1_000 }, // max_distance_to_tap, a raw vertex rather than a midpoint
};

/// Odd, and different per axis so a transposed coordinate cannot pass;
/// large enough that the whole design lands strictly positive.
const dx: i64 = 3_001;
const dy: i64 = 3_003;

/// A vertex map: identity, a translation or a uniform scale.
const Map = struct {
    add: [2]i64 = .{ 0, 0 },
    k: i64 = 1,

    fn at(m: Map, x: i64, y: i64) [2]i64 {
        return .{ x * m.k + m.add[0], y * m.k + m.add[1] };
    }
};

// ---- private ----

/// The whole overlay fixture under `t`. The push order fixes the rows, and
/// no transform reorders them.
fn fixture(t: Map) !common.Built {
    var lb = LayoutBuilder.init(layer_count);
    const boxes = [_]struct { u16, [4]i64 }{
        // Margins 9 left, 29 right, 29 bottom, 30 top: `worst` is the left 9,
        // two opposite sides the bottom 29.
        .{ enc_inner, .{ -101, -101, -50, -50 } },
        // No host anywhere: enclosure zero, reported at its own centre.
        .{ enc_inner, .{ -501, -403, -400, -300 } },
        .{ enc_outer, .{ -110, -130, -21, -20 } },
        // The stripe runs 39 past the bar on the left, 111 on the right.
        .{ ext_line, .{ -300, -251, -100, -200 } },
        .{ ext_ref, .{ -261, -400, -211, -50 } },
        // Intersection 51 by 51.
        .{ ovl_a, .{ -800, -700, -700, -600 } },
        .{ ovl_b, .{ -751, -651, -650, -550 } },
        // 3-4-5: the well's vertex 0 is exactly 500 from the tap.
        .{ well, .{ -1_000, -1_000, -900, -900 } },
        .{ tap_layer, .{ -600, -700, -500, -600 } },
    };
    for (boxes) |b| {
        const lo = t.at(b[1][0], b[1][1]);
        const hi = t.at(b[1][2], b[1][3]);
        _ = try lb.rect(gpa, b[0], lo[0], lo[1], hi[0], hi[1]);
    }
    // Not octilinear under any transform below.
    const apex = t.at(-2_950, -2_900);
    const left = t.at(-3_000, -3_000);
    const right = t.at(-2_900, -3_000);
    _ = try lb.push(gpa, bad, &.{ left[0], right[0], apex[0] }, &.{ left[1], right[1], apex[1] });
    return common.finish(&lb);
}

fn layer(l: u16) LayerId {
    return @fromBackingInt(l);
}

/// Every overlay rule over one store, every limit multiplied by `k`.
fn runOverlay(sink: *Sink, store: *const geom.GeometryStore, k: i64) !void {
    try common.runRules(sink, store, &.{
        .{ .id = ENC, .rule = .{ .min_enclosure = .{ .outer = layer(enc_outer), .inner = layer(enc_inner), .limit = 10 * k } } },
        .{ .id = ENC_REFUSED, .rule = .{ .asymmetric_enclosure = .{ .outer = layer(bad), .inner = layer(enc_inner), .limit = 30 * k } } },
        .{ .id = ASYM, .rule = .{ .asymmetric_enclosure = .{ .outer = layer(enc_outer), .inner = layer(enc_inner), .limit = 30 * k } } },
        .{ .id = EXT, .rule = .{ .min_extension = .{ .layer = layer(ext_line), .reference = layer(ext_ref), .limit = 40 * k } } },
        .{ .id = OVL, .rule = .{ .overlap = .{ .a = layer(ovl_a), .b = layer(ovl_b), .limit = 52 * k } } },
        .{ .id = TAP, .rule = .{ .max_distance_to_tap = .{ .well = layer(well), .tap = layer(tap_layer), .limit = 499 * k } } },
        .{ .id = TAP_EMPTY, .rule = .{ .max_distance_to_tap = .{ .well = layer(empty), .tap = layer(tap_layer), .limit = 499 * k } } },
    });
}

/// Every rule fired, and the two non-`ran` outcomes were both produced.
fn expectNotVacuous(sink: *const Sink) !void {
    for (must_fire) |rule| {
        var n: usize = 0;
        for (sink.out.rule.items) |r| n += @intFromBool(r == rule);
        try testing.expect(n >= 1);
    }
    var refused = false;
    var skipped = false;
    for (sink.runs.items) |r| {
        refused = refused or (r.rule == ENC_REFUSED and r.outcome == .refused);
        skipped = skipped or (r.rule == TAP_EMPTY and std.meta.eql(r.outcome, check.report.Outcome{ .skipped = .empty_layer }));
    }
    try testing.expect(refused and skipped);
    try testing.expect(std.mem.indexOfScalar(geom.PolyId, sink.out.shape_b.items, check.report.no_shape) != null);
}

fn baseRun(sink: *Sink) !void {
    var built = try fixture(.{});
    defer built.deinit();
    try runOverlay(sink, &built.store, 1);
    try expectNotVacuous(sink);
}

fn lengthOf(m: check.report.Measurement) i128 {
    std.debug.assert(m.kind == .length);
    return m.exact();
}

test "the fixture reports at odd negative midpoints" {
    // Oracle: closed form, and the anti-vacuity guard for the translation
    // law: every midpoint this fixture drives is the floor of an odd,
    // negative half-sum, so the floored and truncated midpoints differ at
    // all nine, and the reported points are the floored ones.
    for (midpoints) |m| {
        const sum = m[0] + m[1];
        try testing.expect(sum < 0);
        try testing.expect(@rem(sum, 2) != 0);
        try testing.expectEqual(m[2], @divFloor(sum, 2));
        try testing.expectEqual(m[3], @divTrunc(sum, 2));
    }
    var sink: Sink = .{};
    defer sink.deinit();
    try baseRun(&sink);
    try testing.expectEqual(@as(u32, base_points.len), sink.out.len());
    for (base_points, 0..) |p, row| {
        const at = sink.out.get(@intCast(row)).at;
        try testing.expectEqual(p, [2]i64{ at.x, at.y });
    }
}

test "the tap distance is an exact integer" {
    // Oracle: closed form. The well's vertex 0 at (-1000, -1000) is 400
    // across and 300 up from the tap's nearest corner at (-600, -700), so
    // the distance is the integer 500 and scales exactly by `k`.
    var sink: Sink = .{};
    defer sink.deinit();
    try baseRun(&sink);
    const row = std.mem.indexOfScalar(StrId, sink.out.rule.items, TAP).?;
    try testing.expectEqual(@as(i64, 500 * 500), 400 * 400 + 300 * 300);
    try testing.expectEqual(@as(i128, 500), lengthOf(sink.out.get(@intCast(row)).measured));
}

test "translating the overlay design across the origin moves only the report" {
    // Oracle: law. Layout geometry has no privileged origin: adding a
    // constant to every coordinate, the deck untouched, moves every reported
    // point by that constant and changes nothing else, bit for bit.
    var base: Sink = .{};
    defer base.deinit();
    try baseRun(&base);
    for (base.out.at.items) |p| try testing.expect(p.x < 0 and p.y < 0);
    var built = try fixture(.{ .add = .{ dx, dy } });
    defer built.deinit();
    var moved: Sink = .{};
    defer moved.deinit();
    try runOverlay(&moved, &built.store, 1);
    for (moved.out.at.items) |p| try testing.expect(p.x > 0 and p.y > 0);
    try testing.expectEqual(base.runs.items.len, moved.runs.items.len);
    for (base.runs.items, moved.runs.items) |p, q| try testing.expect(std.meta.eql(p, q));
    try testing.expectEqual(base.out.len(), moved.out.len());
    for (0..base.out.len()) |k| {
        var p = base.out.get(@intCast(k));
        const q = moved.out.get(@intCast(k));
        p.at.x += dx;
        p.at.y += dy;
        try testing.expect(std.meta.eql(p, q));
    }
}

test "scaling the overlay geometry and deck together scales only the measurements" {
    // Oracle: law. Multiplying every coordinate and every limit by the same
    // integer `k` re-states the question on a finer grid: the same verdicts
    // on the same shapes, every measurement exactly `k` times. `at` is not
    // compared for the lithographic rules (a floored odd midpoint does not
    // scale), but the tap rule reports a raw vertex, which does.
    var base: Sink = .{};
    defer base.deinit();
    try baseRun(&base);
    for ([_]i64{ 2, 3, 7 }) |k| {
        try testing.expect(k * coord_reach <= geom.max_abs_dbu and k * limit_reach <= geom.max_abs_dbu);
        var built = try fixture(.{ .k = k });
        defer built.deinit();
        var scaled: Sink = .{};
        defer scaled.deinit();
        try runOverlay(&scaled, &built.store, k);
        try testing.expectEqual(base.runs.items.len, scaled.runs.items.len);
        for (base.runs.items, scaled.runs.items) |p, q| {
            try testing.expectEqual(p.rule, q.rule);
            try testing.expect(std.meta.eql(p.outcome, q.outcome));
            try testing.expectEqual(p.examined, q.examined);
            try testing.expectEqual(p.violations, q.violations);
        }
        try testing.expectEqual(base.out.len(), scaled.out.len());
        for (0..base.out.len()) |row| {
            const p = base.out.get(@intCast(row));
            const q = scaled.out.get(@intCast(row));
            try testing.expectEqual(p.rule, q.rule);
            try testing.expectEqual(p.layer, q.layer);
            try testing.expectEqual(p.severity, q.severity);
            try testing.expectEqual(p.shape_a, q.shape_a);
            try testing.expectEqual(p.shape_b, q.shape_b);
            try testing.expectEqual(lengthOf(p.limit) * k, lengthOf(q.limit));
            try testing.expectEqual(lengthOf(p.measured) * k, lengthOf(q.measured));
            if (p.rule == TAP) {
                try testing.expectEqual(p.at.x * k, q.at.x);
                try testing.expectEqual(p.at.y * k, q.at.y);
            }
        }
    }
}
