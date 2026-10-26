//! Chip, frame and device-family rows the generic kinds express, as
//! exhaustive fixtures: pad, seal-ring and resistor-marker geometry, the
//! varactor and precision-resistor rules, the seal ring at the origin,
//! counts and total areas per chip, and frame rules. Ported from
//! tests/exhaustive/drc_overlay.rs (`chip_and_device`, `device_family`,
//! `seal_origin`, `chip_count`, `frame`, `chip_area`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Symmetry = harness.Symmetry;
const c = @import("drc_common.zig");

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try chipAndDeviceInto(arena, out);
    try deviceFamilyInto(arena, out);
    try sealOriginInto(arena, out);
    try chipCountInto(arena, out);
    try frameInto(arena, out);
    try chipAreaInto(arena, out);
}

// ---- private ----

/// Rectangles on one layer, as a new layout.
fn on(arena: Allocator, layer: []const u8, boxes: []const c.Rect) !Layout {
    var l: Layout = .{};
    try c.rects(arena, &l, layer, boxes);
    return l;
}

/// Chip and device geometry the deck expresses with the generic kinds: a
/// pad opening enclosed by top metal (`enclosure(pad, met5) >= 1um`,
/// DRC-096), a seal ring's width (`width(seal) >= 1um` on a ring of bands,
/// DRC-095), and a resistor body enclosed by its marker (`enclosure(poly,
/// rpm) >= 200nm`, DRC-090), each swept one step either side.
fn chipAndDeviceInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck_pad = try c.newDeck(arena, &.{ "pad", "met5" }, "rule pad.2 enclosure(pad, met5) >= 1um\n");
    const deck_seal = try c.newDeck(arena, &.{"seal"}, "rule seal.w width(seal) >= 1um\n");
    const deck_res = try c.newDeck(arena, &.{ "poly", "rpm" }, "rule rpm.1c enclosure(poly, rpm) >= 200nm\n");
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(1000)) |sw| {
        const m = sw.value;
        var pad = try on(arena, "pad", &.{.{ 0, 0, 10_000, 10_000 }});
        try pad.rect(arena, "met5", -m, -3000, 10_000 + 3000, 13_000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "pad_enclosure/{s}", .{sw.side}), &.{ "DRC-096", "DRC-040" }, deck_pad, pad, &.{.{ "pad.2", try c.below(arena, m, 1000) }}));
        const seal = try on(arena, "seal", &.{ .{ -1200, -1200, 20_000, 0 }, .{ -1200, 20_000, 20_000, 21_200 }, .{ -1200, 0, 0, 20_000 }, .{ 20_000, -1200, 20_000 + m, 21_200 } });
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "seal_ring/{s}", .{sw.side}), &.{"DRC-095"}, deck_seal, seal, &.{.{ "seal.w", try c.below(arena, m, 1000) }}));
    }
    for (c.sweep3(200)) |sw| {
        const m = sw.value;
        var res = try on(arena, "poly", &.{.{ 0, 0, 330, 2000 }});
        try res.rect(arena, "rpm", -m, -1000, 330 + m, 3000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "resistor_marker/{s}", .{sw.side}), &.{ "DRC-090", "DRC-040" }, deck_res, res, &.{.{ "rpm.1c", try c.below(arena, m, 200) }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// A varactor: poly 180 wide crossing a tap `w` tall, all in n-well.
fn varactor(arena: Allocator, w: i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "nwell", -2000, -2000, 2180, w + 2000);
    try l.rect(arena, "tap", -600, 0, 780, w);
    try l.rect(arena, "poly", 0, -300, 180, w + 300);
    return l;
}

/// A resistor along y: two terminals either side of its body, each holding
/// `low` and `high` licons, 100 square and 100 apart.
fn resistor(arena: Allocator, low: i64, high: i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "rpm", -500, -500, 1100, 5500);
    try l.rect(arena, "poly", 0, 0, 600, 5000);
    try l.rect(arena, "poly_rs", -100, 1000, 700, 4000);
    for ([2][2]i64{ .{ low, 400 }, .{ high, 4500 } }) |t| {
        var i: i64 = 0;
        while (i < t[0]) : (i += 1) try l.rect(arena, "licon", 50 + 200 * i, t[1], 150 + 200 * i, t[1] + 100);
    }
    return l;
}

/// The device-family rules DRC-090 listed as missing, written with the
/// generic kinds (SkyWater SKY130 periphery rules, varac and rpm sections):
///
/// - varac.2 "Min channel width (tap width) of `Var_channel`" 1.0 µm, the
///   channel's extent along the poly, between its edges on the tap's edge:
///   `width(var_channel.edges() and tap.edges()) >= 1um`, as difftap.2 is
///   written for a MOS channel (DRC-011). `RTimothyEdwards/open_pdks`
///   `sky130.lydrc` measures the same subject, the varactor channel's edges
///   that are tap edges;
/// - varac.6 "Min spacing between `VaracTap` and difftap" 0.27 µm, the tap
///   holding a channel against every other diffusion or tap figure:
///   `space(var_tap, difftap.not_interacting(var_tap)) >= 270nm`, so a
///   diffusion butted to the varactor tap (one figure with it) is not
///   measured, as `sky130.lydrc` drops its zero-area edge pairs;
/// - rpm.1g "Only 1 licon is allowed in `xhrpoly_0p35`
///   `prec_resistor_terminal`" and rpm.1i "Only 2 licons ... `xhrpoly_1p41`":
///   `contains(term, licon) <= n` on each terminal, the resistor's poly under
///   its marker off the body (`poly_rs`). The manual does not define
///   `prec_resistor_terminal`; this derivation is the fixture's, not a
///   foundry deck's, and no public deck writes rpm.1g-1k.
///
/// Oracle: construct-from-answer at the manual's numbers: a 180-wide poly
/// crossing a tap `W` tall (`W` = 999, 1000, 1001: one finding of `W` below
/// 1000; `width(var_channel)` would read the 180 channel length); a diffusion
/// 269, 270 or 271 from the varactor tap, and one butted to it; terminals
/// holding 1 and 2 licons, each terminal counted alone.
fn deviceFamilyInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck_var = try c.newDeck(arena, &.{ "poly", "tap", "nwell", "diff" },
        \\layer var_channel = (poly and tap) and nwell
        \\layer var_tap = tap.overlapping(var_channel)
        \\layer difftap = diff or tap
        \\rule varac.2 width(var_channel.edges() and tap.edges()) >= 1um
        \\rule varac.6 space(var_tap, difftap.not_interacting(var_tap)) >= 270nm
        \\
    );
    var cases: std.ArrayList(Fixture) = .empty;
    for (c.sweep3(1000)) |sw| {
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "device_family/varac_width/{s}", .{sw.side}), &.{ "DRC-090", "DRC-011" }, deck_var, try varactor(arena, sw.value), &.{ .{ "varac.2", try c.below(arena, sw.value, 1000) }, .{ "varac.6", &.{} } }));
    }
    for (c.sweep3(270)) |sw| {
        var l = try varactor(arena, 1000);
        try l.rect(arena, "diff", 780 + sw.value, 0, 1780 + sw.value, 1000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "device_family/varac_tap_space/{s}", .{sw.side}), &.{"DRC-090"}, deck_var, l, &.{ .{ "varac.2", &.{} }, .{ "varac.6", try c.below(arena, sw.value, 270) } }));
    }
    var butted = try varactor(arena, 1000);
    try butted.rect(arena, "diff", 780, 0, 1780, 1000);
    try cases.append(arena, try c.fixture(arena, "device_family/varac_tap_butted", &.{"DRC-090"}, deck_var, butted, &.{ .{ "varac.2", &.{} }, .{ "varac.6", &.{} } }));

    const deck_rpm = try c.newDeck(arena, &.{ "poly", "rpm", "poly_rs", "licon" },
        \\layer term = (poly and rpm) not poly_rs
        \\rule rpm.1g contains(term, licon) <= 1
        \\rule rpm.1i contains(term, licon) <= 2
        \\
    );
    for ([_][2]i64{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 0, 1 } }) |held| {
        var over: [2]std.ArrayList(Finding) = .{ .empty, .empty };
        for ([_]i64{ 1, 2 }, &over) |n, *o| for (held) |h| {
            if (h > n) try o.append(arena, c.count(@intCast(h)));
        };
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "device_family/rpm_terminal/{d}_{d}", .{ held[0], held[1] }), &.{ "DRC-090", "DRC-049" }, deck_rpm, try resistor(arena, held[0], held[1]), &.{ .{ "rpm.1g", over[0].items }, .{ "rpm.1i", over[1].items } }));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

/// sky130 x.19 "Lower left corner of the seal ring should be at origin i.e
/// (0,0)" (`origin(seal)`, DRC-095, DRC-097): a 4000 square seal ring with a
/// 100 wall, drawn from `(dx, dy)` with a met1 square inside, under each of
/// the eight symmetries about the origin. The rule is anchored on the
/// origin, so a turn or mirror moves the corner it reads, and each
/// placement's expectation is computed, not mapped.
///
/// Oracle: the image of the ring's box under the symmetry: its lower-left
/// corner, and that corner's distance from the origin (3, 4 is 5), one
/// finding there unless it is `(0, 0)`: only the unturned ring drawn from
/// the origin passes, so a rule reading the box's first vertex, or any
/// other corner, breaks a turned case.
fn sealOriginInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "seal", "met1" }, "rule x.19 origin(seal)\n");
    for ([_][2]i64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 3, 4 } }) |d| {
        const dx = d[0];
        const dy = d[1];
        var drawn = try on(arena, "met1", &.{.{ dx + 500, dy + 500, dx + 600, dy + 600 }});
        try c.ring(arena, &drawn, "seal", .{ dx, dy, dx + 4000, dy + 4000 }, .{ dx + 100, dy + 100, dx + 3900, dy + 3900 });
        for (Symmetry.all) |s| {
            var x: i64 = std.math.maxInt(i64);
            var y: i64 = std.math.maxInt(i64);
            for ([_][2]i64{ .{ dx, dy }, .{ dx + 4000, dy }, .{ dx, dy + 4000 }, .{ dx + 4000, dy + 4000 } }) |p| {
                const q = s.apply(p);
                x = @min(x, q[0]);
                y = @min(y, q[1]);
            }
            const found: []const Finding = if (x == 0 and y == 0) &.{} else try arena.dupe(Finding, &.{Finding.length(c.floorSqrt(x * x + y * y)).pinned(x, y)});
            try out.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "origin/{d}_{d}/{s}", .{ dx, dy, try s.name(arena) }), &.{ "DRC-095", "DRC-097" }, deck, try drawn.transformed(arena, s, 0, 0), &.{.{ "x.19", found }}));
        }
    }
}

/// A finding at the die's centre measuring a count.
fn countAt(arena: Allocator, n: u32) ![]const Finding {
    return arena.dupe(Finding, &.{c.count(n).pinned(2000, 2000)});
}

/// A seal ring of 100 wall over `[lo, hi]²`, added to `l`.
fn ringAt(arena: Allocator, l: *Layout, lo: i64, hi: i64) !void {
    try c.ring(arena, l, "seal", .{ lo, lo, hi, hi }, .{ lo + 100, lo + 100, hi - 100, hi - 100 });
}

/// A count per chip (`count`, DRC-091: IHP npn13G2.bR's devices per chip)
/// and one seal ring per chip (DRC-095): `count(a) <= 2` and `count(a) >= 2`
/// on one, two and three shapes, each finding at the die's centre measuring
/// the count; the die is a frame on another layer, `[0, 4000]²`.
///
/// Oracle: counts fixed by construction, at the limit and one either side:
/// three drawn boxes two of which abut, or meet only at a corner, are two
/// shapes (a check counting drawn rows reads three), and an empty layer on a
/// drawn die counts zero. A seal ring drawn as four abutting bands is one
/// ring; a second ring is two.
fn chipCountInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "a", "frame" }, "rule cmax count(a) <= 2\nrule cmin count(a) >= 2\n");
    const p: c.Rect = .{ 100, 100, 300, 300 };
    const q: c.Rect = .{ 500, 100, 700, 300 };
    const r: c.Rect = .{ 900, 100, 1100, 300 };
    const counts = [_]struct { []const u8, []const c.Rect, []const Finding, []const Finding }{
        .{ "none", &.{}, &.{}, try countAt(arena, 0) },
        .{ "one", &.{p}, &.{}, try countAt(arena, 1) },
        .{ "two", &.{ p, q }, &.{}, &.{} },
        .{ "three", &.{ p, q, r }, try countAt(arena, 3), &.{} },
        .{ "three_drawn_two_abut", &.{ p, q, .{ 700, 100, 900, 300 } }, &.{}, &.{} },
        .{ "three_drawn_two_at_a_corner", &.{ p, q, .{ 700, 300, 900, 500 } }, &.{}, &.{} },
    };
    var cases: std.ArrayList(Fixture) = .empty;
    for (counts) |k| {
        var l = try on(arena, "frame", &.{.{ 0, 0, 4000, 4000 }});
        try c.rects(arena, &l, "a", k[1]);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "count/{s}", .{k[0]}), &.{"DRC-091"}, deck, l, &.{ .{ "cmax", k[2] }, .{ "cmin", k[3] } }));
    }
    const seal_deck = try c.newDeck(arena, &.{ "seal", "frame" }, "rule seal.one count(seal) <= 1\nrule seal.any count(seal) >= 1\n");
    var one: Layout = .{};
    try ringAt(arena, &one, 0, 4000);
    var two: Layout = .{};
    try ringAt(arena, &two, 0, 4000);
    try ringAt(arena, &two, 1000, 3000);
    const seals = [_]struct { []const u8, Layout, []const Finding, []const Finding }{
        .{ "one", one, &.{}, &.{} },
        .{ "two", two, try countAt(arena, 2), &.{} },
        .{ "none", .{}, &.{}, try countAt(arena, 0) },
    };
    for (seals) |k| {
        var l = k[1];
        try l.rect(arena, "frame", 0, 0, 4000, 4000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "count/seal_ring/{s}", .{k[0]}), &.{ "DRC-095", "DRC-091" }, seal_deck, l, &.{ .{ "seal.one", k[2] }, .{ "seal.any", k[3] } }));
    }
    // Nothing outside the seal ring: the ring with its hole filled is the
    // chip, and what lies off it is forbidden, reported with its area.
    var outside: Layout = .{};
    try ringAt(arena, &outside, 0, 4000);
    try c.rects(arena, &outside, "met1", &.{ .{ 500, 500, 1000, 1000 }, .{ 5000, 0, 5100, 100 }, .{ 3950, 100, 4100, 200 } });
    try cases.append(arena, try c.fixture(arena, "count/seal_ring/outside", &.{"DRC-095"}, try c.newDeck(arena, &.{ "seal", "met1" }, "layer chip = seal or seal.holes()\nrule seal.out forbidden(met1 not chip)\n"), outside, &.{.{ "seal.out", try c.areas(arena, &.{ 10_000, 10_000 }) }}));
    try c.everyPlacementInto(arena, cases.items, out);
}

/// Frame and die rules the generic kinds express (DRC-097): sky130 x.23a
/// "areaid.sl must not overlap diff" as `forbidden(sl and diff)`, x.23b
/// "diff cannot straddle areaid.sl" as `forbidden((diff and
/// sl).interacting(diff not sl))`, and IHP LBE.h "no LBE ring allowed" as
/// `forbidden(lbe.holes())`, each finding reporting its shape's area.
///
/// Oracle: areas fixed by construction: a diffusion apart from the scribe
/// marker (nothing), inside it (an overlap, no straddle), across its edge
/// (both, on the 100 x 200 part inside); an LBE ring (its 400 square hole)
/// and a solid LBE plate (nothing).
fn frameInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "diff", "sl", "lbe" },
        \\rule x.23a forbidden(sl and diff)
        \\rule x.23b forbidden((diff and sl).interacting(diff not sl))
        \\rule LBE.h forbidden(lbe.holes())
        \\
    );
    var lbe_ring: Layout = .{};
    try c.ring(arena, &lbe_ring, "lbe", .{ 3000, 0, 4000, 1000 }, .{ 3300, 300, 3700, 700 });
    const cases = [_]struct { []const u8, Layout, [3][]const Finding }{
        .{ "diff_apart", try on(arena, "diff", &.{.{ 2000, 0, 2500, 500 }}), .{ &.{}, &.{}, &.{} } },
        .{ "diff_inside", try on(arena, "diff", &.{.{ 100, 100, 300, 300 }}), .{ try c.areas(arena, &.{40_000}), &.{}, &.{} } },
        .{ "diff_across", try on(arena, "diff", &.{.{ 900, 100, 1100, 300 }}), .{ try c.areas(arena, &.{20_000}), try c.areas(arena, &.{20_000}), &.{} } },
        .{ "lbe_ring", lbe_ring, .{ &.{}, &.{}, try c.areas(arena, &.{160_000}) } },
        .{ "lbe_plate", try on(arena, "lbe", &.{.{ 3000, 0, 4000, 1000 }}), .{ &.{}, &.{}, &.{} } },
    };
    var fixtures: std.ArrayList(Fixture) = .empty;
    for (cases) |k| {
        var l = k[1];
        try l.rect(arena, "sl", 0, 0, 1000, 1000);
        try fixtures.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "frame/{s}", .{k[0]}), &.{"DRC-097"}, deck, l, &.{ .{ "x.23a", k[2][0] }, .{ "x.23b", k[2][1] }, .{ "LBE.h", k[2][2] } }));
    }
    try c.everyPlacementInto(arena, fixtures.items, out);
}

/// A finding at the die's centre measuring an area.
fn areaAt(arena: Allocator, area: i128) ![]const Finding {
    return arena.dupe(Finding, &.{Finding.area(area).pinned(2000, 2000)});
}

/// A total area per chip (`total_area`, DRC-091: IHP MIM.gR's total MIM
/// area): `total_area(a) <= 30000nm2`, one finding at the die's centre
/// measuring the area; the die is a frame on another layer, `[0, 4000]²`.
///
/// Oracle: areas fixed by construction at the limit and one 100 nm² step
/// either side; the area summed over separate shapes; two overlapping
/// shapes counted once (summing drawn rows reads 40100 for the 30100 they
/// cover); a ring of 30200 whose filled box is 40200; an empty layer.
fn chipAreaInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.newDeck(arena, &.{ "a", "frame" }, "rule ta total_area(a) <= 30000nm2\n");
    const Case = struct { []const u8, Layout, []const Finding };
    var shapes: std.ArrayList(Case) = .empty;
    for (c.sweep3(300)) |sw| {
        const area: i128 = 100 * sw.value;
        try shapes.append(arena, .{ try std.fmt.allocPrint(arena, "bar/{s}", .{sw.side}), try on(arena, "a", &.{.{ 100, 100, 200, 100 + sw.value }}), if (area > 30_000) try areaAt(arena, area) else &.{} });
    }
    try shapes.append(arena, .{ "summed_over_shapes", try on(arena, "a", &.{ .{ 100, 100, 200, 250 }, .{ 500, 100, 600, 251 } }), try areaAt(arena, 30_100) });
    try shapes.append(arena, .{ "overlap_counted_once", try on(arena, "a", &.{ .{ 100, 100, 200, 300 }, .{ 100, 200, 200, 401 } }), try areaAt(arena, 30_100) });
    var ring: Layout = .{};
    try c.ring(arena, &ring, "a", .{ 100, 100, 300, 301 }, .{ 150, 150, 250, 250 });
    try shapes.append(arena, .{ "ring", ring, try areaAt(arena, 30_200) });
    try shapes.append(arena, .{ "empty", .{}, &.{} });
    var cases: std.ArrayList(Fixture) = .empty;
    for (shapes.items) |k| {
        var l = k[1];
        try l.rect(arena, "frame", 0, 0, 4000, 4000);
        try cases.append(arena, try c.fixture(arena, try std.fmt.allocPrint(arena, "total_area/{s}", .{k[0]}), &.{"DRC-091"}, deck, l, &.{.{ "ta", k[2] }}));
    }
    try c.everyPlacementInto(arena, cases.items, out);
}

test "every chip, frame and device-family fixture holds" {
    // Oracle: each fixture's expected answer, fixed by construction from
    // the rule's definition (the doc comments above): margins, counts and
    // areas drawn to known values, under every symmetry at two translations
    // (the origin rule's expectations computed per symmetry).
    try c.checkGenerated(fixturesInto);
}
