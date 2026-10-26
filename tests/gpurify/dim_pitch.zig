//! Forbidden spacing (DRC-033), exact pitch (DRC-035) and span length
//! (DRC-036) as exhaustive fixtures. Ported from
//! tests/exhaustive/drc_dimension.rs (`forbidden_spacing`, `exact_pitch`,
//! `span_length_except`, `span_length`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const c = @import("drc_common.zig");

/// LEF/DEF 5.8's span tables for its vertical METAL2 (`SPANLENGTHTABLE 0.06
/// 0.08 0.12 0.16 0.20 ;` and `SPANLENGTHTABLE 0.12 0.16 0.20 WRONGDIRECTION
/// ;`): horizontal spans, a vertical wire's width, on the first; vertical
/// spans, parallel to the layer's direction, on the wrong-direction one.
const spans = "rule s span_length(met1; x: [60nm, 80nm, 120nm, 160nm, 200nm], y: [120nm, 160nm, 200nm])";

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    try forbiddenSpacingInto(arena, depth, out);
    try exactPitchInto(arena, depth, out);
    try spanLengthInto(arena, depth, out);
    try spanLengthExceptInto(arena, depth, out);
}

// ---- private ----

/// One finding at the doubled midpoint `(x2, y2)`.
fn pinned(arena: Allocator, f: Finding, x2: i64, y2: i64) ![]const Finding {
    return arena.dupe(Finding, &.{c.pin(f, x2, y2)});
}

/// A one-row fixture on rule `id`.
fn oneRow(arena: Allocator, name: []const u8, catalog: []const []const u8, deck: []const u8, layout: Layout, id: []const u8, findings: []const Finding) !Fixture {
    return c.fixture(arena, name, catalog, deck, layout, &.{.{ id, findings }});
}

/// `forbidden_space(met1; min: 100nm, max: 150nm, prl: 200nm)`
/// (`forbidden_spacing`, DRC-033): facing edges of different figures that
/// run alongside for more than 200 at a gap from 100 to 150, both included,
/// are forbidden; one finding per pair of figures, its smallest forbidden
/// gap, at the middle of the stretch the two edges face each other over.
///
/// The gap swept around both ends of the range (both are forbidden: 99 and
/// 151 are legal), the run swept around 200 at a gap of 120 (200 is not
/// more than 200). Clean: a diagonal pair, a U whose arms are 120 apart
/// (one figure). Three bars 120 apart, two findings. A figure facing a bar
/// 90 away along one step and 130 along another: the narrower gap is below
/// the range and legal, and the finding is the 130.
fn forbiddenSpacingInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const rule = "rule f forbidden_space(met1; min: 100nm, max: 150nm, prl: 200nm)";
    const deck = try c.oneLayerDeck(arena, rule);
    const cat: []const []const u8 = &.{"DRC-033"};
    var cases: std.ArrayList(Fixture) = .empty;
    for ([_]struct { []const u8, i64 }{ .{ "min", 100 }, .{ "max", 150 } }) |e| {
        const end, const limit = e;
        for (try c.sweep(arena, depth, limit)) |g| {
            const findings: []const Finding = if (g >= 100 and g <= 150) try pinned(arena, .length(g), 200 + g, 1000) else &.{};
            try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "forbidden_spacing/gap_{s}/{s}", .{ end, try c.side(arena, g, limit) }), cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 100 + g, 0, 200 + g, 1000 } }), "f", findings));
        }
    }
    for (try c.sweep(arena, depth, 200)) |r| {
        const findings: []const Finding = if (r > 200) try pinned(arena, .length(120), 320, 2000 - r) else &.{};
        try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "forbidden_spacing/run/{s}", .{try c.side(arena, r, 200)}), cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 220, 1000 - r, 320, 2000 - r } }), "f", findings));
    }
    try cases.append(arena, try oneRow(arena, "forbidden_spacing/diagonal", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 220, 1100, 320, 2000 } }), "f", &.{}));
    try cases.append(arena, try oneRow(arena, "forbidden_spacing/one_figure", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 220, 0, 320, 1000 }, .{ 0, -100, 320, 0 } }), "f", &.{}));
    try cases.append(arena, try oneRow(arena, "forbidden_spacing/three_bars", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 220, 0, 320, 1000 }, .{ 440, 0, 540, 1000 } }), "f", &.{
        Finding.length(120).pinned(160, 500),
        Finding.length(120).pinned(380, 500),
    }));
    // The bar's side x = 100 faces the figure's step x = 190 over
    // y = 0..400 (90: below the range, legal) and x = 230 over y = 400..1000
    // (130, run 600: forbidden), marked at (165, 700).
    try cases.append(arena, try oneRow(arena, "forbidden_spacing/narrower_step_is_legal", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 1000 }, .{ 190, 0, 290, 400 }, .{ 230, 400, 330, 1000 } }), "f", &.{Finding.length(130).pinned(165, 700)}));
    try c.everyPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "forbidden_spacing", cat, rule, &.{"f"}));
}

/// `pitch(met1, vertical) == 27nm` and `pitch(met1, horizontal) == 54nm`
/// (`exact_pitch`, DRC-035), ASAP7 FIN.S.1 (7 nm fins, 27 nm pitch) and
/// GATE.S.1 (20 nm gates, 54 nm pitch): each rectangle's nearest neighbours
/// past it that overlap it across must have their centre lines exactly the
/// pitch apart; one finding per pair off it, in the middle of their gap.
///
/// Three fins and three gates with the pitch swept one step either side
/// (FR): both neighbouring pairs off the pitch, and none at it. A missing
/// fin is a pitch of 54. Fins that do not overlap across are no neighbours.
/// A bent shape refuses the rule. Placed under the symmetries that keep the
/// axes: a quarter turn swaps a vertical pitch for a horizontal one.
fn exactPitchInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const fins = try c.oneLayerDeck(arena, "rule p pitch(met1, vertical) == 27nm");
    const gates = try c.oneLayerDeck(arena, "rule p pitch(met1, horizontal) == 54nm");
    const cat: []const []const u8 = &.{"DRC-035"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 27)) |p| if (p > 7) {
        const findings: []const Finding = if (p == 27) &.{} else try arena.dupe(Finding, &.{ c.pin(.length(p), 1000, p + 7), c.pin(.length(p), 1000, 3 * p + 7) });
        try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "exact_pitch/fins/{s}", .{try c.side(arena, p, 27)}), cat, fins, try c.met1(arena, &.{ .{ 0, 0, 1000, 7 }, .{ 0, p, 1000, p + 7 }, .{ 0, 2 * p, 1000, 2 * p + 7 } }), "p", findings));
    };
    for (try c.sweep(arena, depth, 54)) |p| if (p > 20) {
        const findings: []const Finding = if (p == 54) &.{} else try arena.dupe(Finding, &.{ c.pin(.length(p), p + 20, 1000), c.pin(.length(p), 3 * p + 20, 1000) });
        try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "exact_pitch/gates/{s}", .{try c.side(arena, p, 54)}), cat, gates, try c.met1(arena, &.{ .{ 0, 0, 20, 1000 }, .{ p, 0, p + 20, 1000 }, .{ 2 * p, 0, 2 * p + 20, 1000 } }), "p", findings));
    };
    try cases.append(arena, try oneRow(arena, "exact_pitch/missing_fin", cat, fins, try c.met1(arena, &.{ .{ 0, 0, 1000, 7 }, .{ 0, 27, 1000, 34 }, .{ 0, 81, 1000, 88 } }), "p", try pinned(arena, .length(54), 1000, 115)));
    try cases.append(arena, try oneRow(arena, "exact_pitch/no_overlap_across", cat, fins, try c.met1(arena, &.{ .{ 0, 0, 1000, 7 }, .{ 2000, 30, 3000, 37 } }), "p", &.{}));
    try c.everyAxisPlacementInto(arena, cases.items, out);
    var bent: Fixture = .init("exact_pitch/bent_is_refused", cat, fins, harness.drc);
    try bent.layout.polygon(arena, "met1", &.{ .{ 0, 0 }, .{ 1000, 0 }, .{ 1000, 7 }, .{ 7, 7 }, .{ 7, 500 }, .{ 0, 500 } });
    try bent.claim(arena, Expect.outcome("p", .refused));
    try out.append(arena, bent);
    try out.append(arena, try c.vacuous(arena, "exact_pitch", cat, "rule p pitch(met1, vertical) == 27nm", &.{"p"}));
}

/// `span_length(met1; x: [100nm, 300nm], y: [100nm, 300nm], x_except:
/// 200nm, y_except: none)` (DRC-036): LEF58 `SPANLENGTHTABLE 0.1 0.3
/// EXCEPTOTHERSPAN 0.2`, "the span length rule only applies if the span
/// length on the perpendicular direction is greater than the specified
/// otherSpanlength", on the `x` list only.
///
/// Oracle: the LEF text, rectangles by construction: a 150 wide rectangle,
/// its height swept around 200: its 150 horizontal span is held (against
/// 300) only above 200, its vertical span (199 to 201, illegal on `y`)
/// always. An L, which LEF leaves undefined, is held with no exception: its
/// 150 x 100 foot reports 150. Placed under the symmetries that keep the
/// axes.
fn spanLengthExceptInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    const deck = try c.oneLayerDeck(arena, "rule s span_length(met1; x: [100nm, 300nm], y: [100nm, 300nm], x_except: 200nm, y_except: none)");
    const cat: []const []const u8 = &.{"DRC-036"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (try c.sweep(arena, depth, 200)) |h| {
        var findings: std.ArrayList(Finding) = .empty;
        try findings.append(arena, c.pin(.length(h), 150, h));
        if (h > 200) try findings.append(arena, c.pin(.length(150), 150, h));
        try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "span_length_except/rectangle/{s}", .{try c.side(arena, h, 200)}), cat, deck, try c.met1(arena, &.{.{ 0, 0, 150, h }}), "s", findings.items));
    }
    try cases.append(arena, try oneRow(arena, "span_length_except/l_shape", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 150, 100 }, .{ 0, 100, 100, 1000 } }), "s", &.{Finding.length(150).pinned(75, 50)}));
    try c.everyAxisPlacementInto(arena, cases.items, out);
}

/// Each value and one step either side.
fn around(arena: Allocator, values: []const i64) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (values) |v| try out.appendSlice(arena, &.{ v - 1, v, v + 1 });
    return out.items;
}

/// `span_length` (`span_length`, DRC-036): every chord a horizontal or
/// vertical line cuts from a merged figure is one of its axis's lengths, or
/// at least the last; one finding per maximal region of an unchanged
/// illegal chord, at its centre, measuring the chord.
///
/// LEF's own lists, each value and one step either side (SE): a vertical
/// wire's width on `x`, a horizontal piece's height on `y` (the longer
/// chords, 1000, are legal). A U with a stepped arm: the left arm's 100 is
/// one region however many vertices the right arm adds beside it, and the
/// base's 100 one region across the step. A ring's band, four regions. A
/// 200 long piece drawn as two 100 long halves is one legal span. Placed
/// under the symmetries that keep the axes: a quarter turn moves a span
/// from one list to the other.
fn spanLengthInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    const deck = try c.oneLayerDeck(arena, spans);
    const cat: []const []const u8 = &.{"DRC-036"};
    var cases: std.ArrayList(Fixture) = .empty;
    for (try around(arena, &.{ 60, 80, 120, 160, 200 })) |w| {
        const legal = std.mem.findScalar(i64, &.{ 60, 80, 120, 160 }, w) != null or w >= 200;
        const findings: []const Finding = if (legal) &.{} else try pinned(arena, .length(w), w, 1000);
        try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "span_length/x/w{d}", .{w}), cat, deck, try c.met1(arena, &.{.{ 0, 0, w, 1000 }}), "s", findings));
    }
    for (try around(arena, &.{ 120, 160, 200 })) |h| {
        const legal = std.mem.findScalar(i64, &.{ 120, 160 }, h) != null or h >= 200;
        const findings: []const Finding = if (legal) &.{} else try pinned(arena, .length(h), 1000, h);
        try cases.append(arena, try oneRow(arena, try std.fmt.allocPrint(arena, "span_length/y/h{d}", .{h}), cat, deck, try c.met1(arena, &.{.{ 0, 0, 1000, h }}), "s", findings));
    }
    try cases.append(arena, try oneRow(arena, "span_length/stepped_u", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 1000, 100 }, .{ 0, 0, 100, 1000 }, .{ 900, 0, 1000, 500 }, .{ 850, 500, 1000, 1000 } }), "s", &.{
        c.pin(.length(100), 100, 1100),
        c.pin(.length(100), 1900, 600),
        c.pin(.length(150), 1850, 1500),
        c.pin(.length(100), 1000, 100),
    }));
    var ring: Layout = .{};
    try ring.polygon(arena, "met1", try c.holed(arena, .{ 0, 0, 1000, 1000 }, .{ 100, 100, 900, 900 }));
    try cases.append(arena, try oneRow(arena, "span_length/ring", cat, deck, ring, "s", &.{
        c.pin(.length(100), 100, 1000),
        c.pin(.length(100), 1900, 1000),
        c.pin(.length(100), 1000, 100),
        c.pin(.length(100), 1000, 1900),
    }));
    try cases.append(arena, try oneRow(arena, "span_length/drawn_in_halves", cat, deck, try c.met1(arena, &.{ .{ 0, 0, 100, 120 }, .{ 100, 0, 200, 120 } }), "s", &.{}));
    try c.everyAxisPlacementInto(arena, cases.items, out);
    try out.append(arena, try c.vacuous(arena, "span_length", cat, spans, &.{"s"}));
}

test "every forbidden spacing, pitch and span fixture holds" {
    // Oracle: each fixture's expected answer, derived from the rule kinds'
    // definitions (the doc comments above; ASAP7 FIN.S.1 and GATE.S.1, the
    // LEF/DEF 5.8 span tables): each limit swept one grid step either side,
    // under the symmetries the rule keeps at two translations.
    try c.checkGenerated(fixturesInto);
}
