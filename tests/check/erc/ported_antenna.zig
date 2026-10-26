//! The root crate's antenna fixtures, run through fixture.zig: LEF/DEF 5.8
//! Appendix C's Figure C-20 ratios, sidewall area, the gate variants (a
//! derived gate, oxide classes, a MIM victim, a single-gate stack, the
//! double-counting cases), metal over a gate, a gate on its device's poly
//! and IHP's Figure 7.1. Each fixture's expectation is derived in its
//! comment from the rule's definition. Ported from
//! crates/check/tests/erc/ported.rs (`antenna_lef`, `antenna_sidewall`,
//! `antenna_variants`, `metal_over_a_gate`, `gate_on_its_device_poly`,
//! `ihp_area_ratio` and their helpers); the `antenna_electrical` groups are
//! ported_antenna_electrical.zig.
//!
//! Contents:
//! - `pub const Rect`, `pub const Net`, `pub const offsets`, `pub const antenna_process`
//! - `pub const Out = struct`, `add(o, f: Fixture) !void`, `placed(o, f: Fixture) !void`, `offset(o, f: Fixture) !void`
//! - `pub fn rect(arena, l: *Layout, layer, r: Rect) !void`, `pub fn sweep(value: f64) [3]f64`, `pub fn side(limit: f64, value: f64) []const u8`
//! - `pub fn ratio(v: f64) Finding`, `pub fn ratioAt(v: f64, at: [2]i64) Finding`, `pub fn ratioFindings(arena, values: []const Net, limit: f64) ![]const Finding`
//! - `pub fn antennaDeck(arena, rules) ![]const u8`, `pub fn rule(arena, id, findings) ![]const Expect`, `pub fn clean(id) Expect`
//! - `pub fn lefC20(arena) !Layout`, `pub fn gateStub(arena, gate_layer) !Layout`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const check = @import("check");
const fixture = @import("fixture.zig");
const Measurement = check.report.Measurement;
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const Symmetry = fixture.Symmetry;

/// A box `(xlo, ylo, xhi, yhi)` in nanometres.
pub const Rect = [4]i64;

/// One value a row reads on a gate net, at the centre of the net's lowest
/// gate polygon.
pub const Net = struct { value: f64, at: [2]i64 };

/// The translations a placed case is repeated at.
pub const offsets = [2][2]i64{ .{ 0, 0 }, .{ -1_234_567, 987_654 } };

/// Conductors bottom-up diff, poly, met1-met3, with a drawn gate marker (not
/// a conductor, so it joins the poly under it), a second gate oxide, a MIM
/// victim, and the derived `poly and diff` gate.
pub const antenna_process =
    \\grid 1nm
    \\layer diff = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer gate = gds(3, 0)
    \\layer gate2 = gds(4, 0)
    \\layer mim = gds(5, 0)
    \\layer cont = gds(6, 0)
    \\layer met1 = gds(7, 0)
    \\layer via1 = gds(8, 0)
    \\layer met2 = gds(9, 0)
    \\layer via2 = gds(10, 0)
    \\layer met3 = gds(11, 0)
    \\layer gated = poly and diff
    \\connect conductors [diff, poly, met1, met2, met3]
    \\connect touch_within_layer
    \\connect via cont [diff, met1]
    \\connect via cont [poly, met1]
    \\connect via via1 [met1, met2]
    \\connect via via2 [met2, met3]
    \\
;

/// The fixtures a group builds, in the caller's arena.
pub const Out = struct {
    arena: Allocator,
    list: std.ArrayList(Fixture) = .empty,

    pub fn add(o: *Out, f: Fixture) !void {
        try o.list.append(o.arena, f);
    }

    /// `f` as drawn, transposed (a quarter turn then a mirror) at the far
    /// offset, and turned half way: every pinned marker moves off both axes.
    pub fn placed(o: *Out, f: Fixture) !void {
        const transpose: Symmetry = .{ .turns = 1, .mirror = true };
        const half: Symmetry = .{ .turns = 2, .mirror = false };
        try o.add(try f.transformed(o.arena, .identity, 0, 0));
        try o.add(try f.transformed(o.arena, transpose, offsets[1][0], offsets[1][1]));
        try o.add(try f.transformed(o.arena, half, 0, 0));
    }

    /// `f` translated to every offset, unrotated.
    pub fn offset(o: *Out, f: Fixture) !void {
        for (offsets) |d| try o.add(try f.transformed(o.arena, .identity, d[0], d[1]));
    }
};

pub fn rect(arena: Allocator, l: *Layout, layer: []const u8, r: Rect) !void {
    try l.rect(arena, layer, r[0], r[1], r[2], r[3]);
}

/// `value` and one part in a thousand either side.
pub fn sweep(value: f64) [3]f64 {
    return .{ value * 0.999, value, value * 1.001 };
}

/// Where a limit sits against the value it is swept around.
pub fn side(limit: f64, value: f64) []const u8 {
    return switch (std.math.order(limit, value)) {
        .lt => "below",
        .eq => "at",
        .gt => "above",
    };
}

pub fn ratio(v: f64) Finding {
    return .{ .measured = Measurement.ratio(v) };
}

pub fn ratioAt(v: f64, at: [2]i64) Finding {
    return .{ .measured = Measurement.ratio(v), .at = at };
}

/// Findings of a ratio row at `limit`: every value strictly above it, at
/// its marker.
pub fn ratioFindings(arena: Allocator, values: []const Net, limit: f64) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (values) |n| if (n.value > limit) try out.append(arena, ratioAt(n.value, n.at));
    return out.items;
}

pub fn antennaDeck(arena: Allocator, rules: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ antenna_process, rules, "\n" });
}

/// The one claim on `id`: it ran with exactly `findings` (copied, so a
/// temporary array may be passed).
pub fn rule(arena: Allocator, id: []const u8, findings: []const Finding) ![]const Expect {
    return arena.dupe(Expect, &.{.{ .id = id, .findings = try arena.dupe(Finding, findings) }});
}

pub fn clean(id: []const u8) Expect {
    return .{ .id = id };
}

/// LEF/DEF 5.8 Appendix C, Figure C-20, at nanometre scale: G1 = 1.0 and
/// G2 = 2.0 gates, every contact and via 0.1, D1 = 0.5, M1,1 = 1.0, M1,2 =
/// 2.0, M1,3 = 3.0, M2,1 = 4.0, M2,2 = 5.0, M3,1 = 6.0, M3,2 = 9.0 µm². G1
/// reaches M1,2 through C1; G2 and D1 reach M1,3 through C2 and C3; V1,2
/// and V1,3 lift M1,2 to M2,1 and M2,2, V1,4 lifts M1,3 to M2,2, V1,1 lifts
/// M1,1 to M2,1; V2,1 and V2,2 lift M2,1 and M2,2 to M3,1 and M3,2. No metal
/// passes over a gate.
pub fn lefC20(arena: Allocator) !Layout {
    var l: Layout = .{};
    const shapes = [_]struct { []const u8, Rect }{
        // G1, the first gate drawn: the lowest-numbered gate of every net it joins.
        .{ "poly", .{ 0, 0, 1000, 2000 } },         .{ "gate", .{ 0, 0, 1000, 1000 } },
        .{ "cont", .{ 300, 1500, 700, 1750 } },     .{ "met1", .{ 0, 1250, 4000, 1750 } },
        .{ "via1", .{ 750, 1400, 1150, 1650 } },    .{ "via1", .{ 3000, 1400, 3400, 1650 } },
        .{ "met1", .{ -3000, 1250, -2000, 2250 } }, .{ "via1", .{ -2700, 1600, -2300, 1850 } },
        .{ "met2", .{ -2800, 1400, 1200, 2400 } },
        // G2 and the diode D1.
         .{ "poly", .{ 6000, -1000, 7000, 1600 } },
        .{ "gate", .{ 6000, -1000, 7000, 1000 } },  .{ "cont", .{ 6300, 1300, 6700, 1550 } },
        .{ "diff", .{ 7400, 1300, 7900, 2300 } },   .{ "cont", .{ 7450, 1950, 7850, 2200 } },
        .{ "met1", .{ 5000, 1250, 8000, 2250 } },   .{ "via1", .{ 5200, 1900, 5600, 2150 } },
        .{ "met2", .{ 2900, 1300, 7900, 2300 } },
        // The third metal.
          .{ "via2", .{ -2000, 1900, -1600, 2150 } },
        .{ "met3", .{ -3000, 1400, 0, 3400 } },     .{ "via2", .{ 4000, 1900, 4400, 2150 } },
        .{ "met3", .{ 3000, 1300, 6000, 4300 } },
    };
    for (shapes) |s| try rect(arena, &l, s[0], s[1]);
    return l;
}

/// A 1.0 µm² gate on poly, contacted at (400..600, 1700..1900).
pub fn gateStub(arena: Allocator, gate_layer: []const u8) !Layout {
    var l: Layout = .{};
    try rect(arena, &l, "poly", .{ 0, 0, 1000, 2000 });
    try rect(arena, &l, gate_layer, .{ 0, 0, 1000, 1000 });
    try rect(arena, &l, "cont", .{ 400, 1700, 600, 1900 });
    return l;
}

// ---- private ----

/// One `antenna` row with no sidewall, diode or fix hint.
fn plainRow(arena: Allocator, id: []const u8, gate: []const u8, collectors: []const u8, limit: f64) ![]const u8 {
    return antennaDeck(arena, try std.fmt.allocPrint(arena, "rule {s} antenna({s}, {s}; max_ratio: {d}, sidewall: none, diode: none, diode_area: none, diode_min: none)", .{ id, gate, collectors, limit }));
}

/// The LEF/DEF Appendix C ratios of Figure C-20 without its area factors:
/// PAR = collecting area on the node / gate area connected to it at that
/// etch. At met1 G1's node holds M1,2 (2.0/1.0, the manual's step 2) and
/// G2's M1,3 (3.0/2.0); from met2 up one node holds both gates (step 8: 9/3
/// = 3.0, step 14: 15/3 = 5.0). A cut stands on its lower conductor: the
/// contacts on bare poly (0.1/1.0, 0.1/2.0), via1 on met1 (0.2 on G1, 0.1
/// on G2), via2 on met2 (0.2/3). The cumulative row over met1-met3 is the
/// manual's CAR, the sum of each gate's PARs: 10.0 for G1 and 9.5 for G2.
/// Pooling all the metal at met3, 30/3, would miss G2 below 9.5 (F59).
/// Every row is swept across each of its nets' values; the met1 row also
/// under every placement.
fn antennaLef(o: *Out) !void {
    const r = struct {
        fn f(num: f64, den: f64) f64 {
            return num / den;
        }
    }.f;
    const g1 = [2]i64{ 500, 500 };
    const g2 = [2]i64{ 6500, 0 };
    const Row = struct { id: []const u8, collectors: []const u8, nets: []const Net };
    const rows = [_]Row{
        .{ .id = "par.cont", .collectors = "cont", .nets = &.{ .{ .value = r(100_000, 1_000_000), .at = g1 }, .{ .value = r(100_000, 2_000_000), .at = g2 } } },
        .{ .id = "par.met1", .collectors = "met1", .nets = &.{ .{ .value = r(2_000_000, 1_000_000), .at = g1 }, .{ .value = r(3_000_000, 2_000_000), .at = g2 } } },
        .{ .id = "par.via1", .collectors = "via1", .nets = &.{ .{ .value = r(200_000, 1_000_000), .at = g1 }, .{ .value = r(100_000, 2_000_000), .at = g2 } } },
        .{ .id = "par.met2", .collectors = "met2", .nets = &.{.{ .value = r(9_000_000, 3_000_000), .at = g1 }} },
        .{ .id = "par.via2", .collectors = "via2", .nets = &.{.{ .value = r(200_000, 3_000_000), .at = g1 }} },
        .{ .id = "par.met3", .collectors = "met3", .nets = &.{.{ .value = r(15_000_000, 3_000_000), .at = g1 }} },
        .{ .id = "car.met123", .collectors = "met1, met2, met3", .nets = &.{ .{ .value = r(2_000_000, 1_000_000) + 3.0 + 5.0, .at = g1 }, .{ .value = r(3_000_000, 2_000_000) + 3.0 + 5.0, .at = g2 } } },
    };
    const layout = try lefC20(o.arena);
    for (rows) |row| for (row.nets, 0..) |net, n| for (sweep(net.value)) |limit| {
        const f: Fixture = .{
            .name = try std.fmt.allocPrint(o.arena, "erc/antenna/lef_c20/{s}/net{d}/{s}", .{ row.id, n, side(limit, net.value) }),
            .deck = try plainRow(o.arena, row.id, "gate", row.collectors, limit),
            .layout = layout,
            .expect = try rule(o.arena, row.id, try ratioFindings(o.arena, row.nets, limit)),
        };
        try o.add(f);
        if (std.mem.eql(u8, row.id, "par.met1") and n == 1 and limit < net.value) {
            var p = f;
            p.name = try std.fmt.allocPrint(o.arena, "{s}/placed", .{f.name});
            try o.placed(p);
        }
    };
}

/// Side-area antenna: collecting area = merged perimeter × thickness (350
/// nm), over the 1.0 µm² gate. A 3000 × 400 bar has perimeter 6800 (ratio
/// 2.38) however it is drawn: whole, as two abutting halves (a per-polygon
/// perimeter would read 7600), or as two overlapping pieces (8800). An L of
/// arms 3000 × 400 and 400 × 2400 has perimeter 10 800 (ratio 3.78).
fn antennaSidewall(o: *Out) !void {
    const a = o.arena;
    var bar = try gateStub(a, "gate");
    try rect(a, &bar, "met1", .{ 0, 1600, 3000, 2000 });
    var halves = try gateStub(a, "gate");
    try rect(a, &halves, "met1", .{ 0, 1600, 1500, 2000 });
    try rect(a, &halves, "met1", .{ 1500, 1600, 3000, 2000 });
    var overlapping = try gateStub(a, "gate");
    try rect(a, &overlapping, "met1", .{ 0, 1600, 2000, 2000 });
    try rect(a, &overlapping, "met1", .{ 1000, 1600, 3000, 2000 });
    var l_shape = try gateStub(a, "gate");
    try l_shape.polygon(a, "met1", &.{ .{ 0, 1600 }, .{ 3000, 1600 }, .{ 3000, 4000 }, .{ 2600, 4000 }, .{ 2600, 2000 }, .{ 0, 2000 } });
    const shapes = [_]struct { []const u8, i64, Layout }{ .{ "bar", 6800, bar }, .{ "abutting_halves", 6800, halves }, .{ "overlapping", 6800, overlapping }, .{ "l_shape", 10_800, l_shape } };
    for (shapes) |s| {
        const value = @as(f64, @floatFromInt(s[1] * 350)) / 1_000_000.0;
        for (sweep(value)) |limit| {
            const f: Fixture = .{
                .name = try std.fmt.allocPrint(a, "erc/antenna/sidewall/{s}/{s}", .{ s[0], side(limit, value) }),
                .deck = try antennaDeck(a, try std.fmt.allocPrint(a, "rule ant.side antenna(gate, met1; max_ratio: {d}, sidewall: 350nm, diode: none, diode_area: none, diode_min: none)", .{limit})),
                .layout = s[2],
                .expect = try rule(a, "ant.side", try ratioFindings(a, &.{.{ .value = value, .at = .{ 500, 500 } }}, limit)),
            };
            if (limit < value and (std.mem.eql(u8, s[0], "bar") or std.mem.eql(u8, s[0], "l_shape"))) {
                var p = f;
                p.name = try std.fmt.allocPrint(a, "{s}/placed", .{f.name});
                try o.placed(p);
            }
            try o.add(f);
        }
    }
}

/// One swept `antenna` row on `layout`: `value` at `at`.
fn sweptRow(o: *Out, name: []const u8, id: []const u8, gate: []const u8, collectors: []const u8, layout: Layout, value: f64, at: [2]i64) !void {
    for (sweep(value)) |limit| try o.add(.{
        .name = try std.fmt.allocPrint(o.arena, "{s}/{s}", .{ name, side(limit, value) }),
        .deck = try plainRow(o.arena, id, gate, collectors, limit),
        .layout = layout,
        .expect = try rule(o.arena, id, try ratioFindings(o.arena, &.{.{ .value = value, .at = at }}, limit)),
    });
}

/// The derived `poly and diff` gate, oxide classes, a MIM victim, a
/// single-gate cumulative stack, the double-counting cases (F29) and IHP's
/// Figure 7.1.
fn antennaVariants(o: *Out) !void {
    const a = o.arena;
    // A derived gate: poly over a wider diffusion; 2.0 µm² of met1 on 1.0.
    var derived: Layout = .{};
    try rect(a, &derived, "diff", .{ -500, 0, 1500, 1000 });
    try rect(a, &derived, "poly", .{ 0, 0, 1000, 2000 });
    try rect(a, &derived, "cont", .{ 400, 1700, 600, 1900 });
    try rect(a, &derived, "met1", .{ 0, 1600, 4000, 2100 });
    try sweptRow(o, "erc/antenna/derived_gate", "ant.d", "gated", "met1", derived, 2.0, .{ 500, 500 });

    // Oxide classes: a thin gate of 1.0 and a thick one of 2.0 share 2.4 of
    // met1; each row counts only its own gate layer (LEF ANTENNAMODEL OXIDEn).
    var oxides = try gateStub(a, "gate");
    try rect(a, &oxides, "poly", .{ 2000, 0, 4000, 2000 });
    try rect(a, &oxides, "gate2", .{ 2000, 0, 4000, 1000 });
    try rect(a, &oxides, "cont", .{ 2900, 1700, 3100, 1900 });
    try rect(a, &oxides, "met1", .{ 0, 1600, 6000, 2000 });
    try sweptRow(o, "erc/antenna/oxide/ant.thin", "ant.thin", "gate", "met1", oxides, 2.4, .{ 500, 500 });
    try sweptRow(o, "erc/antenna/oxide/ant.thick", "ant.thick", "gate2", "met1", oxides, 1.2, .{ 3000, 500 });

    // A MIM capacitor as the victim: 1.0 µm² of dielectric under a 2.0 µm²
    // met2 plate.
    var mim: Layout = .{};
    try rect(a, &mim, "met2", .{ 0, 0, 2000, 1000 });
    try rect(a, &mim, "mim", .{ 0, 0, 1000, 1000 });
    try sweptRow(o, "erc/antenna/mim", "ant.mim", "mim", "met2", mim, 2.0, .{ 500, 500 });

    // One gate under a stack of 2.0 + 3.0 + 5.0: every cumulative reading is
    // 10.0.
    var stack = try gateStub(a, "gate");
    try rect(a, &stack, "met1", .{ 0, 1600, 4000, 2100 });
    try rect(a, &stack, "via1", .{ 3000, 1700, 3200, 1900 });
    try rect(a, &stack, "met2", .{ 3000, 1600, 6000, 2600 });
    try rect(a, &stack, "via2", .{ 5000, 1700, 5200, 1900 });
    try rect(a, &stack, "met3", .{ 5000, 1600, 10_000, 2600 });
    try sweptRow(o, "erc/antenna/car_single_gate", "car", "gate", "met1, met2, met3", stack, 10.0, .{ 500, 500 });

    // F29: the collecting area of a node is its drawn area, the union. Two
    // overlapping met1 pieces cover 1.5 µm², not their 2.0 sum: at a limit
    // of 1.75 the gate is clean.
    var over_collect = try gateStub(a, "gate");
    try rect(a, &over_collect, "met1", .{ 0, 1600, 2000, 2100 });
    try rect(a, &over_collect, "met1", .{ 1000, 1600, 3000, 2100 });
    try o.add(.{ .name = "erc/antenna/f29/overlapping_collectors", .deck = try plainRow(a, "ant", "gate", "met1", 1.75), .layout = over_collect, .expect = try rule(a, "ant", &.{}) });
    // F29, the other way: a gate drawn as two overlapping polygons is 1.5
    // µm² of oxide, so 3.0 µm² of met1 is a ratio of 2.0, above 1.75.
    // Summed per polygon the gate reads 2.0 µm² and the ratio 1.5: a false
    // clean.
    var over_gate: Layout = .{};
    try rect(a, &over_gate, "poly", .{ 0, 0, 1500, 2000 });
    try rect(a, &over_gate, "gate", .{ 0, 0, 1000, 1000 });
    try rect(a, &over_gate, "gate", .{ 500, 0, 1500, 1000 });
    try rect(a, &over_gate, "cont", .{ 400, 1700, 600, 1900 });
    try rect(a, &over_gate, "met1", .{ 0, 1600, 6000, 2100 });
    try o.add(.{ .name = "erc/antenna/f29/overlapping_gate", .deck = try plainRow(a, "ant", "gate", "met1", 1.75), .layout = over_gate, .expect = try rule(a, "ant", &.{ratioAt(2.0, .{ 500, 500 })}) });
    try o.add(try ihpAreaRatio(a));
    try metalOverAGate(o);
    try o.add(try gateOnItsDevicePoly(a));
}

/// F81: a deck with a direct diffusion-poly cut (`connect via bc [diff,
/// poly]`) reaches poly upward from the diffusion, so by conductors and vias
/// alone the poly is "over" a derived `poly and diff` gate and the gate fell
/// to the diffusion, a net with no met1: a false clean. The deck's `device
/// mos` row names poly as the gate terminal, so the gate is on its poly,
/// which the contact joins to 2.0 µm² of met1 over the 1.0 µm² gate: 2.0.
/// No `bc` shape is drawn, so diffusion and poly stay apart.
fn gateOnItsDevicePoly(a: Allocator) !Fixture {
    var l: Layout = .{};
    try rect(a, &l, "diff", .{ -500, 0, 1500, 1000 });
    try rect(a, &l, "poly", .{ 0, 0, 1000, 2000 });
    try rect(a, &l, "cont", .{ 400, 1700, 600, 1900 });
    try rect(a, &l, "met1", .{ 0, 1600, 4000, 2100 });
    const deck = try antennaDeck(a,
        \\layer bc = gds(12, 0)
        \\layer sd = diff not poly
        \\connect via bc [diff, poly]
        \\device mos gated model "nfet" terminals [poly, sd, sd]
        \\rule ant antenna(gated, met1; max_ratio: 1.0, sidewall: none, diode: none, diode_area: none, diode_min: none)
    );
    return .{ .name = "erc/antenna/f81/direct_diff_poly_cut", .deck = deck, .layout = l, .expect = try rule(a, "ant", &.{ratioAt(2.0, .{ 500, 500 })}) };
}

/// F72: a gate's net is that of the poly it lies on, never metal drawn over
/// it. The 1.0 µm² gate's poly is contacted to 2.0 µm² of met1, so the met1
/// ratio is 2.0 whatever unconnected met1 crosses the gate: a 10 × 0.6 µm
/// strip, a 2.5 × 1.8 µm plate wholly over it, or the strip over a derived
/// gate. A via1 cut sits on the met1 it lands on, not on another net's poly
/// under that met1: 0.04 µm² of via1 over the 1.0 µm² gate's net is 0.04.
fn metalOverAGate(o: *Out) !void {
    const a = o.arena;
    const contacted: Rect = .{ 0, 1600, 2000, 2600 };
    const strip: Rect = .{ -5000, 200, 5000, 800 };
    var derived: Layout = .{};
    try rect(a, &derived, "diff", .{ -500, 0, 1500, 1000 });
    try rect(a, &derived, "poly", .{ 0, 0, 1000, 2000 });
    try rect(a, &derived, "cont", .{ 400, 1700, 600, 1900 });
    const cases = [_]struct { []const u8, []const u8, Layout, Rect }{
        .{ "strip", "gate", try gateStub(a, "gate"), strip },
        .{ "plate", "gate", try gateStub(a, "gate"), .{ -1000, -500, 1500, 1300 } },
        .{ "derived_gate", "gated", derived, strip },
    };
    for (cases) |c| {
        var l = c[2];
        try rect(a, &l, "met1", contacted);
        try rect(a, &l, "met1", c[3]);
        try o.add(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna/f72/{s}", .{c[0]}),
            .deck = try plainRow(a, "ant", c[1], "met1", 1.0),
            .layout = l,
            .expect = try rule(a, "ant", &.{ratioAt(2.0, .{ 500, 500 })}),
        });
    }
    // A second poly line, on its own net, runs under the gate's met1; the
    // via1 cut over it lands on that met1.
    var cut = try gateStub(a, "gate");
    try rect(a, &cut, "met1", contacted);
    try rect(a, &cut, "poly", .{ 1200, 2000, 1800, 3000 });
    try rect(a, &cut, "via1", .{ 1400, 2200, 1600, 2400 });
    try o.add(.{ .name = "erc/antenna/f72/cut_over_other_poly", .deck = try plainRow(a, "ant", "gate", "via1", 0.01), .layout = cut, .expect = try rule(a, "ant", &.{ratioAt(0.04, .{ 500, 500 })}) });
}

/// IHP SG13G2 layout rules §7.1, Figure 7.1 and its `AreaRatio` formula,
/// the catalog's oracle for the cumulative ratio (ERC-A3): `AreaRatio(G1) =
/// (M1(i) + M2(i)) / G1 + M3(i) / (G1 + G2 + G3)`, one ratio per layer over
/// the gates connected when it is etched. With every gate 1.0 µm², M1(i) =
/// 100, M2(i) = 50, M1(ii) = M1(iii) = 2, M2(ii) = 4 and M3(i) = 30: G1
/// reads 150 + 10 = 160, G2 and G3 read 14. Against Ant.b's limit, scaled
/// to 100, G1 fails; pooling everything at the top, 62.7, passes it (F59).
fn ihpAreaRatio(a: Allocator) !Fixture {
    var l: Layout = .{};
    // G1 under a 100 µm² met1 plate and a 50 µm² met2 plate.
    try rect(a, &l, "poly", .{ 0, 0, 1000, 2000 });
    try rect(a, &l, "gate", .{ 0, 0, 1000, 1000 });
    try rect(a, &l, "cont", .{ 400, 1700, 600, 1900 });
    try rect(a, &l, "met1", .{ 0, 1500, 10_000, 11_500 });
    try rect(a, &l, "via1", .{ 2000, 5000, 2200, 5200 });
    try rect(a, &l, "met2", .{ 0, 1500, 5000, 11_500 });
    // G2 and G3, joined on met2.
    for ([_]i64{ 20_000, 30_000 }) |x| {
        try rect(a, &l, "poly", .{ x, 0, x + 1000, 2000 });
        try rect(a, &l, "gate", .{ x, 0, x + 1000, 1000 });
        try rect(a, &l, "cont", .{ x + 400, 1700, x + 600, 1900 });
        try rect(a, &l, "met1", .{ x, 1500, x + 2000, 2500 });
    }
    try rect(a, &l, "via1", .{ 21_500, 2100, 21_700, 2300 });
    try rect(a, &l, "via1", .{ 30_300, 2100, 30_500, 2300 });
    try rect(a, &l, "met2", .{ 21_000, 2000, 31_000, 2400 });
    // M3(i) joins the two met2 nodes.
    try rect(a, &l, "via2", .{ 4500, 2500, 4700, 2700 });
    try rect(a, &l, "via2", .{ 22_000, 2100, 22_200, 2300 });
    try rect(a, &l, "met3", .{ 4000, 2000, 24_000, 3500 });
    const g1 = (100.0 + 50.0) / 1.0 + 30.0 / 3.0;
    return .{ .name = "erc/antenna/ihp_fig7_1", .deck = try plainRow(a, "ant.b", "gate", "met1, met2, met3", 100), .layout = l, .expect = try rule(a, "ant.b", &.{ratioAt(g1, .{ 500, 500 })}) };
}

test "antenna rows match lef and the foundry tables" {
    // Oracle: LEF/DEF 5.8 Appendix C's antenna ratios (its example C-20
    // worked by hand), the foundry tables each fixture cites, and the
    // area arithmetic in each group's comment.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var o: Out = .{ .arena = arena_state.allocator() };
    try antennaLef(&o);
    try antennaSidewall(&o);
    try antennaVariants(&o);
    try fixture.checkAll(o.list.items);
}
