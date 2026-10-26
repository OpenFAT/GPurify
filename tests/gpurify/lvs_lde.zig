//! LVS-074: layout-dependent effects, as exhaustive fixtures. Ported from
//! tests/exhaustive/lvs.rs (`silvaco_wpe`, `lde_fixtures`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const lf = @import("lvs_fixture.zig");

/// A card parameter: name and value in SI.
const Param = struct { []const u8, f64 };

/// A well rectangle around or beside the gate.
const Well = enum { around, right };

/// LVS-074: layout-dependent effects, construct-from-answer. One `nmos`
/// drawn at the origin (the drawer's MOS): its gate is `x` 500..650 by `y`
/// 0..1000, its OD 0..1150 by 0..1000, and an OD strip `x` -300..0 by `y`
/// 0..500 makes the source side's edge 800 nm from the gate over half the
/// width and 500 nm over the other: BSIM4's effective distance is
/// `1/(0.5/875 + 0.5/575) - 75` nm, 619.0 nm, and the drain side's 500
/// nm, so `sa` 500 nm and `sb` 619.0 nm. A well `x` -1500..2650 by `y`
/// -2000..4000 puts the gate's edges 2000, 2000, 2000 and 3000 nm from its
/// edges (`SC1` across the source end, `SC2` below, `SC3` across the drain
/// end, `SC4` above); a well to the right only, from `x` 1000, puts the
/// drain end 350 nm from it and the rest past `max`, 5000 nm. The cards
/// state these, or one of them 5 % off.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    const one = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    const deck = circuit.full_deck ++ "layer wellm = gds(31, 0)\nlvs lde \"nmos\" od diff max 5000nm well wellm scref 1000nm\n";
    const w = 1000e-9;
    const l = 150e-9;
    const scref = 1000e-9;
    const sb = (1.0 / (0.5 / 875.0 + 0.5 / 575.0) - 75.0) * 1e-9;
    const enclosed = silvacoWpe(.{ 2000e-9, 2000e-9, 2000e-9, 3000e-9 }, w, l, scref);
    const beside = silvacoWpe(.{ 5000e-9, 5000e-9, 350e-9, 5000e-9 }, w, l, scref);
    const enc = lde(sb, enclosed);
    var swapped = enc;
    std.mem.swap(Param, &swapped[0], &swapped[1]);
    // Name, drawing, the card's parameters, whether it matches.
    const cases = [_]struct { []const u8, Well, [5]Param, bool }{
        .{ "enclosed", .around, enc, true },
        .{ "enclosed_sa_sb_either_way", .around, swapped, true },
        .{ "enclosed_sb_off", .around, off(enc, "sb"), false },
        .{ "enclosed_sca_off", .around, off(enc, "sca"), false },
        .{ "enclosed_scb_off", .around, off(enc, "scb"), false },
        .{ "well_beside", .right, lde(sb, beside), true },
        .{ "well_beside_vs_enclosed", .right, enc, false },
    };
    for (cases) |case| {
        var layout = try circuit.draw(arena, &one);
        try layout.rect(arena, "diff", -300, 0, 0, 500);
        switch (case[1]) {
            .around => try layout.rect(arena, "wellm", -1500, -2000, 2650, 4000),
            .right => try layout.rect(arena, "wellm", 1000, -3000, 3000, 4000),
        }
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/lde/{s}", .{case[0]}), &.{"LVS-074"}, deck, lf.lvs);
        f.layout = layout;
        try f.claim(arena, .{ .lvs = case[3] });
        f.reference = try card(arena, &one, &case[2]);
        try out.append(arena, f);
    }
}

// ---- private ----

/// Silvaco's well-proximity terms for a gate `w` by `l` whose edges are
/// `sc` from the well: `sca`, `scb`, `scc`.
fn silvacoWpe(sc: [4]f64, w: f64, l: f64, scref: f64) [3]f64 {
    const sca = scref * scref / (w * l) * (w * (1.0 / sc[0] - 1.0 / (sc[0] + l)) + l * (1.0 / sc[1] - 1.0 / (sc[1] + w)) + w * (1.0 / sc[2] - 1.0 / (sc[2] + l)) + l * (1.0 / sc[3] - 1.0 / (sc[3] + w)));
    return .{ sca, integral(10.0, sc, w, l, scref), integral(20.0, sc, w, l, scref) };
}

fn integral(n: f64, sc: [4]f64, w: f64, l: f64, scref: f64) f64 {
    return edgeTerm(n, sc[1], w, scref) + edgeTerm(n, sc[3], w, scref) + edgeTerm(n, sc[0], l, scref) + edgeTerm(n, sc[2], l, scref);
}

fn edgeTerm(n: f64, s: f64, e: f64, scref: f64) f64 {
    return 1.0 / (e * scref) * (scref / n * s * @exp(-n * s / scref) + scref * scref / (n * n) * @exp(-n * s / scref) - scref / n * (s + e) * @exp(-n * (s + e) / scref) - scref * scref / (n * n) * @exp(-n * (s + e) / scref));
}

fn lde(sb: f64, enc: [3]f64) [5]Param {
    return .{ .{ "sa", 500e-9 }, .{ "sb", sb }, .{ "sca", enc[0] }, .{ "scb", enc[1] }, .{ "scc", enc[2] } };
}

/// `params` with `name` 5 % high.
fn off(params: [5]Param, name: []const u8) [5]Param {
    var out = params;
    for (&out) |*p| if (std.mem.eql(u8, p[0], name)) {
        p[1] *= 1.05;
    };
    return out;
}

/// The one `nmos`'s card stating `params` after its size. `Dev` holds four
/// parameters, so the five are appended to the written card, as
/// `Dev.param` would write them (Rust's `{:e}`).
fn card(arena: Allocator, c: *const Circuit, params: []const Param) ![]const u8 {
    var tail: std.ArrayList(u8) = .empty;
    try tail.appendSlice(arena, "l=150n");
    for (params) |p| {
        const text = try std.fmt.allocPrint(arena, "{e}", .{p[1]});
        try tail.print(arena, " {s}=", .{p[0]});
        for (text) |ch| if (ch != '+') try tail.append(arena, ch);
    }
    try tail.append(arena, '\n');
    return circuit.edited(arena, try circuit.spice(arena, c), "l=150n\n", tail.items);
}

test "every lde fixture holds" {
    // Oracle: construct-from-answer: BSIM4's effective `sa`/`sb` and
    // Silvaco's well-proximity integrals over the distances drawn (above),
    // matching as stated and failing 5 % off.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
