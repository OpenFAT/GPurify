//! The root crate's `antenna_electrical` fixtures, and GF180's MIM antenna
//! rows, run through fixture.zig: subtractive diode credit (sky130 EGAR,
//! Table Ig), LEF/DEF Appendix C's cumulative model and its Examples 2-4,
//! GF180 ANT.14-16, the PWL limit, sky130's two forms agreeing, .ar.1's
//! exempt tap and IHP Ant.g. Each fixture's expectation is derived in its
//! comment. Ported from crates/check/tests/erc/ported.rs
//! (`antenna_electrical` and the groups it extends, `gf180_mim`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fixture = @import("fixture.zig");
const pa = @import("ported_antenna.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Net = pa.Net;
const Out = pa.Out;
const rect = pa.rect;
const sweep = pa.sweep;
const side = pa.side;
const ratioAt = pa.ratioAt;
const ratioFindings = pa.ratioFindings;
const antennaDeck = pa.antennaDeck;

/// One layer's figures of a cumulative LEF node: `(area, diff_area,
/// gate_area)` in µm².
const Node = [3]f64;

const g1 = [2]i64{ 500, 500 };

const g2 = [2]i64{ 6500, 0 };

// ---- private ----

/// A typed division, so the quotient is the f64 the engine computes.
fn r(num: f64, den: f64) f64 {
    return num / den;
}

/// An `antenna_electrical` row with every factor neutral but those given.
fn aeRow(arena: Allocator, id: []const u8, gate: []const u8, collectors: []const u8, max: f64, sidewall: []const u8, cut: f64, diode: []const u8, credit: f64, bonus: f64, minus: f64, plus: f64, reduce: []const u8, diode_max: []const u8, exempt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "rule {s} antenna_electrical({s}, {s}; max_ratio: {d}, sidewall: {s}, cut_factor: {d}, diode: {s}, diode_credit: {d}, diode_bonus: {d}, area_minus_diode: {d}, gate_plus_diode: {d}, diode_reduce: {s}, diode_max_ratio: {s}, exempt: {s})", .{ id, gate, collectors, max, sidewall, cut, diode, credit, bonus, minus, plus, reduce, diode_max, exempt });
}

/// An `antenna_electrical` row "ae" with every factor neutral but the two
/// piecewise-linear tables.
fn pwlRow(arena: Allocator, id: []const u8, collectors: []const u8, max: f64, sidewall: []const u8, reduce: []const u8, diode_max: []const u8) ![]const u8 {
    return aeRow(arena, id, "gate", collectors, max, sidewall, 1, "diff", 0, 0, 0, 0, reduce, diode_max, "none");
}

/// A 1.0 µm² gate under 2.0 µm² of met1, optionally with a 0.15 µm² diode
/// on diffusion contacted to the same met1.
fn diodeStub(a: Allocator, diode: bool) !Layout {
    var l = try pa.gateStub(a, "gate");
    try rect(a, &l, "met1", .{ 0, 1600, 5000, 2000 });
    if (diode) {
        try rect(a, &l, "diff", .{ 4000, 1650, 4500, 1950 });
        try rect(a, &l, "cont", .{ 4150, 1700, 4350, 1900 });
    }
    return l;
}

/// `antenna_electrical`: `ratio - diode_credit × diode_area - diode_bonus`,
/// the subtractive credit of sky130's EGAR and LEF `ANTENNAAREAMINUSDIFF`.
/// With no credit it is `antenna`: 2.0 swept. With a diode on the net and a
/// bonus of 0.5: 1.5 swept. A bonus is credit for a diode, so a net without
/// one keeps 2.0 (F35). IHP Ant.b (without diode, 1.5 here) and Ant.e (with
/// diode, 100): a net with a diode is held to Ant.e only, so at 2.0 it is
/// clean (F60); without the diode Ant.b fails it and Ant.e does not apply.
fn antennaElectrical(o: *Out) !void {
    const a = o.arena;
    const at: []const Net = &.{.{ .value = 2.0, .at = g1 }};
    for (sweep(2.0)) |limit| try o.add(.{
        .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/no_credit/{s}", .{side(limit, 2.0)}),
        .deck = try antennaDeck(a, try aeRow(a, "ae", "gate", "met1", limit, "none", 1, "none", 0, 0, 0, 0, "none", "none", "none")),
        .layout = try diodeStub(a, false),
        .expect = try pa.rule(a, "ae", try ratioFindings(a, at, limit)),
    });
    for (sweep(1.5)) |limit| try o.add(.{
        .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/bonus_with_diode/{s}", .{side(limit, 1.5)}),
        .deck = try antennaDeck(a, try aeRow(a, "ae", "gate", "met1", limit, "none", 1, "diff", 0, 0.5, 0, 0, "none", "none", "none")),
        .layout = try diodeStub(a, true),
        .expect = try pa.rule(a, "ae", try ratioFindings(a, &.{.{ .value = 1.5, .at = g1 }}, limit)),
    });
    try o.add(.{
        .name = "erc/antenna_electrical/bonus_without_diode",
        .deck = try antennaDeck(a, try aeRow(a, "ae", "gate", "met1", 1.75, "none", 1, "diff", 0, 0.5, 0, 0, "none", "none", "none")),
        .layout = try diodeStub(a, false),
        .expect = try pa.rule(a, "ae", &.{ratioAt(2.0, g1)}),
    });
    try sky130TableIg(o);
    try lefC20Cumulative(o);
    try lefGatePlusDiode(o);
    try gf180Ant16(o);
    try lefExample4(o);
    try lefPwlLimit(o);
    try sky130LefAgreesWithEgar(o);
    try sky130Ar1(o);
    try ihpAntG(o);
    const ihp = try antennaDeck(a, try std.mem.concat(a, u8, &.{ "rule Ant.b antenna(gate, met1; max_ratio: 1.5, sidewall: none, diode: diff, diode_area: none, diode_min: none)\n", try aeRow(a, "Ant.e", "gate", "met1", 100, "none", 1, "diff", 0, 0, 0, 0, "none", "none", "none") }));
    try o.add(.{ .name = "erc/antenna_electrical/ihp_b_e/with_diode", .deck = ihp, .layout = try diodeStub(a, true), .expect = try a.dupe(Expect, &.{ pa.clean("Ant.b"), pa.clean("Ant.e") }) });
    try o.add(.{ .name = "erc/antenna_electrical/ihp_b_e/without_diode", .deck = ihp, .layout = try diodeStub(a, false), .expect = try a.dupe(Expect, &.{ .{ .id = "Ant.b", .findings = try a.dupe(fixture.Finding, &.{ratioAt(2.0, g1)}) }, pa.clean("Ant.e") }) });
}

/// A 1.0 µm² gate whose poly a 100 × 100 contact joins to met1 at
/// (450..550, 1750..1850), and, with `diode_um2`, a 1000-nm-wide diode
/// contacted at (-1050..-950, 1750..1850) to the same met1.
fn egarStub(a: Allocator, diode_um2: ?f64) !Layout {
    var l: Layout = .{};
    try rect(a, &l, "poly", .{ 0, 0, 1000, 2000 });
    try rect(a, &l, "gate", .{ 0, 0, 1000, 1000 });
    try rect(a, &l, "cont", .{ 450, 1750, 550, 1850 });
    if (diode_um2) |um2| {
        const half: i64 = @intFromFloat(@round(um2 * 500.0));
        try rect(a, &l, "diff", .{ -1500, 1800 - half, -500, 1800 + half });
        try rect(a, &l, "cont", .{ -1050, 1750, -950, 1850 });
    }
    return l;
}

/// `count` square via1 cuts of side `side_nm` on a met1 plate over both
/// contacts of `egarStub`, 25 to a row at twice their side.
fn cutArray(a: Allocator, diode_um2: ?f64, count: i64, side_nm: i64) !Layout {
    var l = try egarStub(a, diode_um2);
    const rows = std.math.divCeil(i64, count, 25) catch unreachable;
    try rect(a, &l, "met1", .{ -1100, 1700, 1200 + 50 * side_nm, 1900 + 2 * side_nm * rows });
    for (0..@intCast(count)) |k| {
        const i: i64 = @intCast(k);
        const x = 1200 + @mod(i, 25) * 2 * side_nm;
        const y = 1900 + @divTrunc(i, 25) * 2 * side_nm;
        try rect(a, &l, "via1", .{ x, y, x + side_nm, y + side_nm });
    }
    return l;
}

/// A met1 line `width` × `length` nm from x = -1100, over both contacts of
/// `egarStub`: perimeter `2 (length + width)`.
fn line(a: Allocator, diode_um2: ?f64, width: i64, length: i64) !Layout {
    var l = try egarStub(a, diode_um2);
    const ylo = 1800 - @divTrunc(width, 2);
    try rect(a, &l, "met1", .{ -1100, ylo, -1100 + length, ylo + width });
    return l;
}

/// SKY130 antenna rules, Table Ig and its "design limitations due to
/// antenna rules (FET gate = 1um2)", the foundry's own worked examples of
/// `EGAR = EA / A_gate - K x (AntennaDiode_area in um2) - diode_bonus`, each
/// at its stated limit (clean) and one step past it, with no diode and with
/// a 1 µm² diode:
/// - Mcon (max 3, K 18; 0.17 µm cuts): 103 cuts without a diode (2.977),
///   726 with (20.981 - 18); 104 (3.006) and 727 (3.010) fail.
/// - LI (FLT 0.1 µm, max 75, K 450; width 0.17 µm): 370 µm without
///   (74.034), 2620 µm with (524.034 - 450); 375 and 2625 µm fail.
/// - Met1 (FLT 0.35 µm, max 400, K 400, bonus 2200; width 0.14 µm): 570
///   µm without (399.098), 4280 µm with (396.098); 572 and 4286 µm fail.
/// Then off the table: a 0.5 µm² diode halves the credit, so with Via's K
/// 36 and max 6, 0.15 µm cuts pass at 1066 (23.985 - 18) and fail at 1067.
fn sky130TableIg(o: *Out) !void {
    const a = o.arena;
    const mcon = try aeRow(a, "ae", "gate", "via1", 3, "none", 1, "diff", 18, 0, 0, 0, "none", "none", "none");
    const li = try aeRow(a, "ae", "gate", "met1", 75, "100nm", 1, "diff", 450, 0, 0, 0, "none", "none", "none");
    const met1 = try aeRow(a, "ae", "gate", "met1", 400, "350nm", 1, "diff", 400, 2200, 0, 0, "none", "none", "none");
    const via = try aeRow(a, "ae", "gate", "via1", 6, "none", 1, "diff", 36, 0, 0, 0, "none", "none", "none");
    const Case = struct { name: []const u8, rule: []const u8, layout: Layout, ratio: f64, credit: f64, max: f64 };
    const S = struct {
        fn cuts(n: i64, s: f64) f64 {
            return @as(f64, @floatFromInt(n)) * s * s / 1e6;
        }
        fn sideArea(width: i64, length: i64, flt: i64) f64 {
            return @as(f64, @floatFromInt(2 * (length + width) * flt)) / 1e6;
        }
    };
    var cases: std.ArrayList(Case) = .empty;
    for ([_]struct { i64, ?f64 }{ .{ 103, null }, .{ 104, null }, .{ 726, 1.0 }, .{ 727, 1.0 } }) |c| try cases.append(a, .{ .name = "mcon", .rule = mcon, .layout = try cutArray(a, c[1], c[0], 170), .ratio = S.cuts(c[0], 170.0), .credit = if (c[1]) |d| 18.0 * d else 0.0, .max = 3.0 });
    for ([_]struct { i64, ?f64 }{ .{ 370, null }, .{ 375, null }, .{ 2620, 1.0 }, .{ 2625, 1.0 } }) |c| try cases.append(a, .{ .name = "li", .rule = li, .layout = try line(a, c[1], 170, c[0] * 1000), .ratio = S.sideArea(170, c[0] * 1000, 100), .credit = if (c[1]) |d| 450.0 * d else 0.0, .max = 75.0 });
    for ([_]struct { i64, ?f64 }{ .{ 570, null }, .{ 572, null }, .{ 4280, 1.0 }, .{ 4286, 1.0 } }) |c| try cases.append(a, .{ .name = "met1", .rule = met1, .layout = try line(a, c[1], 140, c[0] * 1000), .ratio = S.sideArea(140, c[0] * 1000, 350), .credit = if (c[1]) |d| 400.0 * d + 2200.0 else 0.0, .max = 400.0 });
    for ([_]i64{ 1066, 1067 }) |n| try cases.append(a, .{ .name = "via_half_um2_diode", .rule = via, .layout = try cutArray(a, 0.5, n, 150), .ratio = S.cuts(n, 150.0), .credit = 36.0 * 0.5, .max = 6.0 });
    for (cases.items) |c| {
        const value = c.ratio - c.credit;
        try o.add(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/sky130_table_ig/{s}/{s}/{s}_{d:.3}", .{ c.name, if (c.credit > 0.0) "diode" else "no_diode", if (value > c.max) "fails" else "passes", c.ratio }),
            .deck = try antennaDeck(a, c.rule),
            .layout = c.layout,
            .expect = try pa.rule(a, "ae", try ratioFindings(a, &.{.{ .value = value, .at = g1 }}, c.max)),
        });
    }
}

/// LEF/DEF 5.8 Appendix C's cumulative ratio, one partial ratio per layer
/// in etch order, each `(area - minus × diff_area) / gate_area`, the
/// running sum truncated at zero after each layer (Example 2).
fn lefCar(minus: f64, nodes: []const Node) f64 {
    var car: f64 = 0.0;
    for (nodes) |n| car = @max(car + (n[0] - minus * n[1]) / n[2], 0.0);
    return car;
}

/// G1's and G2's nodes on Figure C-20 in etch order (cont, met1, via1,
/// met2, via2, met3), each cut's area times `cut` (LEF's
/// `ANTENNAAREAFACTOR` on a cut layer).
fn c20Nodes(cut: f64) [2][6]Node {
    return .{
        .{ .{ 0.1 * cut, 0.0, 1.0 }, .{ 2.0, 0.0, 1.0 }, .{ 0.2 * cut, 0.0, 1.0 }, .{ 9.0, 0.5, 3.0 }, .{ 0.2 * cut, 0.5, 3.0 }, .{ 15.0, 0.5, 3.0 } },
        .{ .{ 0.1 * cut, 0.0, 2.0 }, .{ 3.0, 0.5, 2.0 }, .{ 0.1 * cut, 0.5, 2.0 }, .{ 9.0, 0.5, 3.0 }, .{ 0.2 * cut, 0.5, 3.0 }, .{ 15.0, 0.5, 3.0 } },
    };
}

/// LEF/DEF 5.8 Appendix C's cumulative model on Figure C-20, metal and cut
/// accumulated as one CAR (`ANTENNACUMROUTINGPLUSCUT`), each value from
/// `lefCar` over `c20Nodes`, swept a part in a thousand either side:
/// Example 1 (cut factor 10: G1 reads 13.67 at met3, its "12.34" in step 15
/// a slip for 5 + 8.67; G2 11.17), Example 2 (`ANTENNAAREAMINUSDIFF 100`:
/// from met2 up every sum truncates to 0, clean at any limit), minus 4 with
/// no cut factor (G1 8.367, G2 6.067, G2 truncated at via1), and `antenna`
/// itself listing the cuts with the metals (G1 10.367, G2 9.667).
fn lefC20Cumulative(o: *Out) !void {
    const a = o.arena;
    const all = "cont, met1, via1, met2, via2, met3";
    const Case = struct { []const u8, []const u8, usize, f64, f64 };
    const cases = [_]Case{
        .{ "example1", all, 6, 0.0, 10.0 },
        .{ "example1_via1", "cont, met1, via1", 3, 0.0, 10.0 },
        .{ "example2", all, 6, 100.0, 10.0 },
        .{ "example2_via1", "cont, met1, via1", 3, 100.0, 10.0 },
        .{ "minus4", all, 6, 4.0, 1.0 },
        .{ "antenna", all, 6, 0.0, 1.0 },
    };
    const layout = try pa.lefC20(a);
    for (cases) |c| {
        const nodes = c20Nodes(c[4]);
        const nets = try a.dupe(Net, &.{ .{ .value = lefCar(c[3], nodes[0][0..c[2]]), .at = g1 }, .{ .value = lefCar(c[3], nodes[1][0..c[2]]), .at = g2 } });
        var limits: std.ArrayList(f64) = .empty;
        for (nets) |n| if (n.value > 0.0) try limits.appendSlice(a, &.{ n.value * 0.999, n.value * 1.001 });
        // A value of zero is clean at any positive limit.
        if (limits.items.len == 0) try limits.append(a, 1e-3);
        for (limits.items) |limit| {
            const row = if (std.mem.eql(u8, c[0], "antenna"))
                try std.fmt.allocPrint(a, "rule ae antenna(gate, {s}; max_ratio: {d}, sidewall: none, diode: none, diode_area: none, diode_min: none)", .{ c[1], limit })
            else
                try aeRow(a, "ae", "gate", c[1], limit, "none", c[4], "diff", 0, 0, c[3], 0, "none", "none", "none");
            try o.add(.{
                .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/lef_c20_cumulative/{s}/{d:.4}", .{ c[0], limit }),
                .deck = try antennaDeck(a, row),
                .layout = layout,
                .expect = try pa.rule(a, "ae", try ratioFindings(a, nets, limit)),
            });
        }
    }
}

/// LEF/DEF 5.8 Appendix C, Example 3 (`ANTENNAGATEPLUSDIFF 2.0`) on Figure
/// C-20: `PAR = metal_area / (gate_area + 2.0 × diff_area)`. G1: PAR(M1) =
/// 2, PAR(M2) = 9 / (3 + 1) = 2.25, PAR(M3) = 15 / 4 = 3.75 (CAR 8.0). G2's
/// node at met1 already reaches D1: 3 / (2 + 1) = 1.0, CAR 7.0. Every value
/// is exact in binary, so each is swept below, at and above.
fn lefGatePlusDiode(o: *Out) !void {
    const a = o.arena;
    const rows = [_]struct { []const u8, []const u8, []const Net }{
        .{ "par.met1", "met1", &.{ .{ .value = 2.0, .at = g1 }, .{ .value = 1.0, .at = g2 } } },
        .{ "par.met2", "met2", &.{.{ .value = 2.25, .at = g1 }} },
        .{ "par.met3", "met3", &.{.{ .value = 3.75, .at = g1 }} },
        .{ "car.met123", "met1, met2, met3", &.{ .{ .value = 8.0, .at = g1 }, .{ .value = 7.0, .at = g2 } } },
    };
    const layout = try pa.lefC20(a);
    for (rows) |row| for (row[2], 0..) |net, n| for (sweep(net.value)) |limit| try o.add(.{
        .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/lef_example3/{s}/net{d}/{s}", .{ row[0], n, side(limit, net.value) }),
        .deck = try antennaDeck(a, try aeRow(a, "ae", "gate", row[1], limit, "none", 1, "diff", 0, 0, 0, 2, "none", "none", "none")),
        .layout = layout,
        .expect = try pa.rule(a, "ae", try ratioFindings(a, row[2], limit)),
    });
}

/// GF180MCU DRM ANT.16: "gate area = (thin gate area + MF * (COMP area
/// directly connection that node))", MF 2 for a thin gate and 15 for a
/// thick one, each against its own oxide (ERC-A12). A 1.0 µm² thin gate
/// and a 2.0 µm² thick one share 2.4 µm² of met1 and a 0.5 µm² diode: the
/// thin row reads 2.4 / (1 + 1) = 1.2, the thick 2.4 / (2 + 7.5) = 0.2526.
fn gf180Ant16(o: *Out) !void {
    const a = o.arena;
    var l = try pa.gateStub(a, "gate");
    try rect(a, &l, "poly", .{ 2000, 0, 4000, 2000 });
    try rect(a, &l, "gate2", .{ 2000, 0, 4000, 1000 });
    try rect(a, &l, "cont", .{ 2900, 1700, 3100, 1900 });
    try rect(a, &l, "met1", .{ 0, 1600, 6000, 2000 });
    try rect(a, &l, "diff", .{ 4500, 1500, 5500, 2000 });
    try rect(a, &l, "cont", .{ 4900, 1700, 5100, 1900 });
    for ([_]struct { []const u8, []const u8, f64, f64, [2]i64 }{
        .{ "thin", "gate", 2, r(4_800_000, 4_000_000), .{ 500, 500 } },
        .{ "thick", "gate2", 15, r(4_800_000, 19_000_000), .{ 3000, 500 } },
    }) |c| for (sweep(c[3])) |limit| try o.add(.{
        .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/gf180_ant16/{s}/{s}", .{ c[0], side(limit, c[3]) }),
        .deck = try antennaDeck(a, try aeRow(a, "ae", c[1], "met1", limit, "none", 1, "diff", 0, 0, 0, c[2], "none", "none", "none")),
        .layout = l,
        .expect = try pa.rule(a, "ae", try ratioFindings(a, &.{.{ .value = c[3], .at = c[4] }}, limit)),
    });
}

/// GF180MCU ANT.14 and ANT.15 (ERC-A11) on the DRM's MIM topology: the
/// FuseTop top plate reached from above by Via2 to Metal3, over a Metal2
/// bottom plate it does not touch. Per metal layer the perimeter area
/// `2 (L + 1) x 0.54` against 400 (399.6 at L = 369 µm, clean; 401.76 at
/// 371 µm); per cut layer the area against 20 (a Via3 cut 4.4 µm square,
/// 19.36, clean; 4.5 µm, 20.25); the Metal2 bottom plate is another net.
fn gf180Mim(o: *Out) !void {
    const a = o.arena;
    const deck =
        \\grid 1nm
        \\layer metal2 = gds(1, 0)
        \\layer fusetop = gds(2, 0)
        \\layer via2 = gds(3, 0)
        \\layer metal3 = gds(4, 0)
        \\layer via3 = gds(5, 0)
        \\layer metal4 = gds(6, 0)
        \\connect conductors [metal2, fusetop, metal3, metal4]
        \\connect touch_within_layer
        \\connect via via2 [metal2, metal3]
        \\connect via via2 [fusetop, metal3]
        \\connect via via3 [metal3, metal4]
        \\rule ant14.m3 antenna(fusetop, metal3; max_ratio: 400, sidewall: 540nm, diode: none, diode_area: none, diode_min: none)
        \\rule ant14.m2 antenna(fusetop, metal2; max_ratio: 400, sidewall: 540nm, diode: none, diode_area: none, diode_min: none)
        \\rule ant15.v3 antenna(fusetop, via3; max_ratio: 20, sidewall: none, diode: none, diode_area: none, diode_min: none)
        \\
    ;
    for ([_]i64{ 369_000, 371_000 }) |length| {
        const value = 2.0 * (@as(f64, @floatFromInt(length)) + 1000.0) * 540.0 / 1e6;
        var l = try plates(a);
        try rect(a, &l, "metal3", .{ 0, 0, length, 1000 });
        try o.placed(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna/gf180_ant14/{d}", .{length}),
            .deck = deck,
            .layout = l,
            .expect = try a.dupe(Expect, &.{ .{ .id = "ant14.m3", .findings = try ratioFindings(a, &.{.{ .value = value, .at = g1 }}, 400.0) }, pa.clean("ant14.m2"), pa.clean("ant15.v3") }),
        });
    }
    for ([_]i64{ 4400, 4500 }) |s| {
        const value = @as(f64, @floatFromInt(s * s)) / 1e6;
        var l = try plates(a);
        try rect(a, &l, "metal3", .{ 0, 0, 7000, 5000 });
        try rect(a, &l, "via3", .{ 2200, 200, 2200 + s, 200 + s });
        try rect(a, &l, "metal4", .{ 2000, 0, 7000, 5000 });
        try o.placed(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna/gf180_ant15/{d}", .{s}),
            .deck = deck,
            .layout = l,
            .expect = try a.dupe(Expect, &.{ .{ .id = "ant15.v3", .findings = try ratioFindings(a, &.{.{ .value = value, .at = g1 }}, 20.0) }, pa.clean("ant14.m2") }),
        });
    }
}

fn plates(a: Allocator) !Layout {
    var l: Layout = .{};
    try rect(a, &l, "metal2", .{ -500, -500, 1500, 1500 });
    try rect(a, &l, "fusetop", .{ 0, 0, 1000, 1000 });
    try rect(a, &l, "via2", .{ 400, 400, 600, 600 });
    return l;
}

/// LEF/DEF 5.8 Appendix C, Example 4 (`ANTENNAAREADIFFREDUCEPWL ((0.0 1.0)
/// (0.0999 1.0) (0.1 0.2) (1.0 0.1) (1000.0 0.1))`, cumulative over the
/// metals) on Figure C-20. The factor at D1's 0.5 µm² is 0.2 - 0.1 × 0.4 /
/// 0.9 = 0.1556; G1's node at met1 reaches no diffusion, so it reads 2 + (3
/// + 5) × 0.1556 = 3.244; G2's reaches D1 from met1, (1.5 + 3 + 5) × 0.1556
/// = 1.478. Both swept a part in a thousand either side.
fn lefExample4(o: *Out) !void {
    const a = o.arena;
    // Typed, so the arithmetic is f64's (as the engine's), not comptime's.
    const lo: f64 = 0.1;
    const hi: f64 = 0.2;
    const at: f64 = 0.5;
    const one: f64 = 1.0;
    const factor = hi + (lo - hi) * ((at - lo) / (one - lo));
    const nets = try a.dupe(Net, &.{ .{ .value = 2.0 + 8.0 * factor, .at = g1 }, .{ .value = 9.5 * factor, .at = g2 } });
    const reduce = "[(0um2, 1.0), (0.0999um2, 1.0), (0.1um2, 0.2), (1um2, 0.1), (1000um2, 0.1)]";
    const layout = try pa.lefC20(a);
    for (nets, 0..) |net, n| for ([_]f64{ net.value * 0.999, net.value * 1.001 }) |limit| try o.add(.{
        .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/lef_example4/net{d}/{s}", .{ n, side(limit, net.value) }),
        .deck = try antennaDeck(a, try pwlRow(a, "ae", "met1, met2, met3", limit, "none", reduce, "none")),
        .layout = layout,
        .expect = try pa.rule(a, "ae", try ratioFindings(a, nets, limit)),
    });
}

/// LEF/DEF 5.8 Appendix C, "Example Using the Antenna Keywords": a
/// cumulative metal ratio of 1000, and with a diode over 0.1 µm² "ratio =
/// diode_area x 2000 + 5000", `ANTENNACUMDIFFAREARATIO PWL ((0 1000) (0.099
/// 1000) (0.1 5200) (100 205000))`. With a 0.5 µm² diode the limit is 6000:
/// 5994 passes, 6006 fails; with 0.05 µm², below the step, it is 1000, as
/// without a diode; with no table a diode changes nothing.
fn lefPwlLimit(o: *Out) !void {
    const a = o.arena;
    const table = "[(0um2, 1000), (0.099um2, 1000), (0.1um2, 5200), (100um2, 205000)]";
    for ([_]struct { ?f64, i64, i64, []const u8, bool }{
        .{ 0.5, 99_900, 60_000, table, false },
        .{ 0.5, 100_100, 60_000, table, true },
        .{ 0.05, 99_900, 10_000, table, false },
        .{ 0.05, 100_100, 10_000, table, true },
        .{ null, 99_900, 10_000, table, false },
        .{ null, 100_100, 10_000, table, true },
        .{ 0.5, 99_900, 60_000, "none", true },
    }) |c| {
        var l = try egarStub(a, c[0]);
        try rect(a, &l, "met1", .{ -1100, 1700, -1100 + c[1], 1700 + c[2] });
        const value = @as(f64, @floatFromInt(c[1] * c[2])) / 1e6;
        const with = if (c[0]) |d| try std.fmt.allocPrint(a, "diode_{d}", .{d}) else "no_diode";
        try o.add(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/lef_pwl_limit/{s}/{s}/{d}", .{ if (std.mem.eql(u8, c[3], "none")) "no_table" else "table", with, value }),
            .deck = try antennaDeck(a, try pwlRow(a, "ae", "met1", 1000.0, "none", "none", c[3])),
            .layout = l,
            .expect = try pa.rule(a, "ae", if (c[4]) try a.dupe(fixture.Finding, &.{ratioAt(value, g1)}) else &.{}),
        });
    }
}

/// Two public statements of sky130's met1 antenna limit agree: EGAR (max
/// 400, K 400, bonus 2200, 0.35 µm sidewall) and the technology LEF's
/// `ANTENNADIFFSIDEAREARATIO PWL ((0 400) (0.0125 400) (0.0225 2609) (22.5
/// 11600))`, slope 400 per µm² past 0.0225: both allow 2600 + 400 × D. On
/// 0.14 µm lines (ratio 0.7 × (L + 0.14)) with a 1 µm² diode both pass 4280
/// µm and fail 4286 µm, with 0.5 µm² both pass 3990 and fail 4000, without
/// one both pass 570 and fail 572. EGAR reports the credited ratio, the LEF
/// row the plain ratio against its interpolated limit.
fn sky130LefAgreesWithEgar(o: *Out) !void {
    const a = o.arena;
    const egar = try aeRow(a, "egar", "gate", "met1", 400, "350nm", 1, "diff", 400, 2200, 0, 0, "none", "none", "none");
    const lef = try pwlRow(a, "lef", "met1", 400.0, "350nm", "none", "[(0um2, 400), (0.0125um2, 400), (0.0225um2, 2609), (22.5um2, 11600)]");
    const deck = try antennaDeck(a, try std.mem.concat(a, u8, &.{ egar, "\n", lef }));
    for ([_]struct { ?f64, i64, bool }{ .{ 1.0, 4280, false }, .{ 1.0, 4286, true }, .{ 0.5, 3990, false }, .{ 0.5, 4000, true }, .{ null, 570, false }, .{ null, 572, true } }) |c| {
        const ratio_of = @as(f64, @floatFromInt(2 * (c[1] * 1000 + 140) * 350)) / 1e6;
        const credit = if (c[0]) |d| 400.0 * d + 2200.0 else 0.0;
        const with = if (c[0]) |d| try std.fmt.allocPrint(a, "diode_{d}", .{d}) else "no_diode";
        const egar_found: []const fixture.Finding = if (c[2]) try a.dupe(fixture.Finding, &.{ratioAt(ratio_of - credit, g1)}) else &.{};
        const lef_found: []const fixture.Finding = if (c[2]) try a.dupe(fixture.Finding, &.{ratioAt(ratio_of, g1)}) else &.{};
        try o.add(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/sky130_lef_vs_egar/{s}/{d}um", .{ with, c[1] }),
            .deck = deck,
            .layout = try line(a, c[0], 140, c[1] * 1000),
            .expect = try a.dupe(Expect, &.{ .{ .id = "egar", .findings = egar_found }, .{ .id = "lef", .findings = lef_found } }),
        });
    }
}

/// SKY130 antenna rule .ar.1, "antenna rules not checked for features
/// connected to a pAntennaShort", with AntennaDiode excluding it. Table
/// Ig's met1 row on a 4286 µm line with a 1 µm² diode reads 400.298
/// against 400; a 1 µm² `ptap` contacted to the same line exempts the gate
/// from `antenna_electrical`'s `exempt` and from `antenna`'s `diode`: both
/// rows are clean. Without the tap both flag the gate, `antenna` at the
/// plain ratio 3000.298.
fn sky130Ar1(o: *Out) !void {
    const a = o.arena;
    const rules = try std.mem.concat(a, u8, &.{ "layer ptap = gds(13, 0)\nlayer adiode = diff not ptap\n", try aeRow(a, "ae", "gate", "met1", 400, "350nm", 1, "adiode", 400, 2200, 0, 0, "none", "none", "ptap"), "\nrule an antenna(gate, met1; max_ratio: 400, sidewall: 350nm, diode: ptap, diode_area: none, diode_min: none)" });
    const ratio_of = @as(f64, @floatFromInt(2 * (4_286_000 + 140) * 350)) / 1e6;
    for ([_]bool{ false, true }) |tap| {
        var l = try line(a, 1.0, 140, 4_286_000);
        if (tap) {
            try rect(a, &l, "diff", .{ 2000, 1300, 3000, 2300 });
            try rect(a, &l, "ptap", .{ 2000, 1300, 3000, 2300 });
            try rect(a, &l, "cont", .{ 2450, 1750, 2550, 1850 });
        }
        const ae: []const fixture.Finding = if (tap) &.{} else try a.dupe(fixture.Finding, &.{ratioAt(ratio_of - 2600.0, g1)});
        const an: []const fixture.Finding = if (tap) &.{} else try a.dupe(fixture.Finding, &.{ratioAt(ratio_of, g1)});
        try o.add(.{
            .name = if (tap) "erc/antenna_electrical/sky130_ar1/tap_exempts" else "erc/antenna_electrical/sky130_ar1/no_tap",
            .deck = try antennaDeck(a, rules),
            .layout = l,
            .expect = try a.dupe(Expect, &.{ .{ .id = "ae", .findings = ae }, .{ .id = "an", .findings = an } }),
        });
    }
}

/// IHP SG13G2 §7.1, Ant.g: "size of protection diode (µm²) 0.16", the least
/// diode that lets a gate be held to Ant.e instead of Ant.b, written as the
/// derived `diff.with_area(>= 0.16um2)` both rows read. A 1.0 µm² gate
/// under 2.0 µm² of met1 (Ant.b scaled to 1.5, Ant.e to 100): a 0.15 µm²
/// diode is too small, so Ant.b flags 2.0; a 0.16 µm² diode protects it.
fn ihpAntG(o: *Out) !void {
    const a = o.arena;
    const deck = try antennaDeck(a, try std.mem.concat(a, u8, &.{ "layer prot = diff.with_area(>= 0.16um2)\nrule Ant.b antenna(gate, met1; max_ratio: 1.5, sidewall: none, diode: prot, diode_area: none, diode_min: none)\n", try aeRow(a, "Ant.e", "gate", "met1", 100, "none", 1, "prot", 0, 0, 0, 0, "none", "none", "none"), "\nrule Ant.g area(diff) >= 0.16um2" }));
    for ([_]struct { []const u8, pa.Rect, i64 }{ .{ "0.15um2", .{ 4000, 1650, 4500, 1950 }, 150_000 }, .{ "0.16um2", .{ 4000, 1600, 4400, 2000 }, 160_000 } }) |c| {
        var l = try pa.gateStub(a, "gate");
        try rect(a, &l, "met1", .{ 0, 1600, 5000, 2000 });
        try rect(a, &l, "diff", c[1]);
        try rect(a, &l, "cont", .{ 4150, 1700, 4350, 1900 });
        const found: []const fixture.Finding = if (c[2] < 160_000) try a.dupe(fixture.Finding, &.{ratioAt(2.0, g1)}) else &.{};
        try o.add(.{
            .name = try std.fmt.allocPrint(a, "erc/antenna_electrical/ihp_ant_g/{s}/erc", .{c[0]}),
            .deck = deck,
            .layout = l,
            .expect = try a.dupe(Expect, &.{ .{ .id = "Ant.b", .findings = found }, pa.clean("Ant.e") }),
        });
    }
}

test "antenna electrical rows match lef and the foundry tables" {
    // Oracle: LEF/DEF 5.8 Appendix C's cumulative model and Examples 2-4
    // (worked by hand), SKY130 Table Ig, GF180 ANT.14-16 and IHP Ant.g, as
    // each group's comment derives; with ported_antenna.zig the whole of
    // `antenna_rows_match_lef_and_the_foundry_tables`.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var o: Out = .{ .arena = arena_state.allocator() };
    try antennaElectrical(&o);
    try gf180Mim(&o);
    try fixture.checkAll(o.list.items);
}
