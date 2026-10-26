//! What the ported ESD and voltage fixture groups share: the placements a
//! case is repeated at, the limit sweep, the finding constructors, the ESD
//! strip process and its layout, the diode process, the domain nets and
//! their intents, and `circuitPins`. Ported from
//! crates/check/tests/erc/ported.rs (`every_placement`, `side`, `sweep`,
//! `ohms`, `microamps`, `ESD_PROCESS`, `ESD_CLAMPS`, `STRIP`, `STRIP_Y`,
//! `Diode`, `esd_layout`, `esd_intent`, `diode_process`, `circuit_pins`,
//! `DOMAIN_NETS`, `domain_intent`).
//!
//! Every slice a helper returns lives in the caller's arena.
//!
//! Contents:
//! - `pub const esd_process`, `pub const esd_clamps`, `pub const strip`, `pub const strip_y`, `pub const Diode = enum`, `marker(d) Marker`, `pub const Marker`, `pub const Placed`
//! - `pub const diode_process`, `pub const Pin`, `pub const domain_nets`
//! - `pub fn everyPlacementInto(arena, fixtures: []const Fixture, out: *std.ArrayList(Fixture)) !void`
//! - `pub fn side(limit: f64, value: f64) []const u8`, `pub fn sweep(value: f64) [3]f64`
//! - `pub fn ohms(x: f64) Finding`, `pub fn microamps(x: f64) Finding`, `pub fn area(nm2: i128) Finding`, `pub fn at(f: Finding, x: i64, y: i64) Finding`
//! - `pub fn rule(arena, id: []const u8, findings: []const Finding) !Expect`, `pub fn expects(arena, e: []const Expect) ![]const Expect`
//! - `pub fn esdLayout(arena, w: [3]i64, diodes: []const Placed) !Layout`, `pub fn pinVss(l: *Layout, arena) !void`, `pub fn esdIntent(arena) ![]const u8`
//! - `pub fn circuitPins(arena, labels: []const []const u8, devs: []const Dev, pins: []const Pin) !Layout`, `pub fn padOn(l: *Layout, arena, net: usize) !void`
//! - `pub fn domainIntent(arena) ![]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const check = @import("check");
const Measurement = check.report.Measurement;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Finding = fixture.Finding;
const Layout = fixture.Layout;
const board = @import("board.zig");
const Dev = board.Dev;
const rect = board.rect;
const riser = board.riser;

/// A pad and its two supplies as three strips on three conductors, joined
/// only by diode clamps whose markers span two of them: the pad on `pad`
/// (0.0625 Ω/sq), the ground rail VSS on `met1` (0.125 Ω/sq), the power
/// rail VDD on `met2` (0.0625 Ω/sq). `mkd` a down diode (VSS to the pad),
/// `mku` an up diode (pad to VDD), `mkr` a rail diode (VSS to VDD), `mkx`
/// and `mky` the up and rail diodes reversed. `padv` joins a supply's own
/// pad pin to its rail.
pub const esd_process =
    \\grid 1nm
    \\layer pad = gds(1, 0)
    \\layer met1 = gds(2, 0)
    \\layer met2 = gds(3, 0)
    \\layer padv = gds(4, 0)
    \\layer padtxt = gds(1, 1)
    \\layer m1txt = gds(2, 1)
    \\layer m2txt = gds(3, 1)
    \\layer mkd = gds(10, 0)
    \\layer mku = gds(11, 0)
    \\layer mkr = gds(12, 0)
    \\layer mkx = gds(13, 0)
    \\layer mky = gds(14, 0)
    \\connect conductors [pad, met1, met2]
    \\connect touch_within_layer
    \\connect via padv [met1, pad]
    \\connect label padtxt names pad
    \\connect label m1txt names met1
    \\connect label m2txt names met2
    \\device diode mkd model "down" terminals [met1, pad]
    \\device diode mku model "up" terminals [pad, met2]
    \\device diode mkr model "rail" terminals [met1, met2]
    \\device diode mkx model "up_rev" terminals [met2, pad]
    \\device diode mky model "rail_rev" terminals [met2, met1]
    \\pex pad thickness 100nm height 500nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met1 thickness 100nm height 100nm sheet 0.125ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met2 thickness 100nm height 300nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex padv thickness 100nm height 400nm sheet 0.25ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\
;

/// Every diode model of `esd_process`, as a deck's `clamps` list.
pub const esd_clamps = "[\"down\", \"up\", \"rail\", \"up_rev\", \"rail_rev\"]";

/// Every strip's length: x from 0 to 20 µm, tapped at its centre.
pub const strip: i64 = 20_000;

/// Each strip's lower edge: the pad at 0, VSS 3 µm below, VDD 3 µm above.
pub const strip_y = [3]i64{ 0, -3000, 3000 };

/// One diode clamp of `esd_process` by its recogniser.
pub const Diode = enum {
    /// `mkd`: VSS to the pad.
    down,
    /// `mku`: the pad to VDD.
    up,
    /// `mkr`: VSS to VDD.
    rail,
    /// `mkx`: VDD to the pad, forward-biased in operation.
    up_reversed,
    /// `mky`: VDD to VSS, drawn the other way round.
    rail_reversed,

    /// The marker layer and the strips (0 pad, 1 VSS, 2 VDD) it spans.
    pub fn marker(d: Diode) Marker {
        return switch (d) {
            .down => .{ .layer = "mkd", .a = 1, .b = 0 },
            .up => .{ .layer = "mku", .a = 0, .b = 2 },
            .rail => .{ .layer = "mkr", .a = 1, .b = 2 },
            .up_reversed => .{ .layer = "mkx", .a = 0, .b = 2 },
            .rail_reversed => .{ .layer = "mky", .a = 1, .b = 2 },
        };
    }
};

pub const Marker = struct { layer: []const u8, a: usize, b: usize };

/// A diode and the x its marker is centred on.
pub const Placed = struct { Diode, i64 };

/// `board.topo_process` with a diode recogniser `mkdi` (model `dio`), its
/// anode the first diffusion under the marker, and a resistor recogniser
/// `mkres` (model `rs`) drawn the same way.
pub const diode_process = board.topo_process ++
    \\layer mkdi = gds(27, 0)
    \\layer mkres = gds(28, 0)
    \\device diode mkdi model "dio" terminals [diff, diff]
    \\device resistor mkres model "rs" terminals [diff, diff]
    \\
;

/// A two-pin device column: its marker layer and its two pins' nets, the
/// first pin's diffusion drawn first.
pub const Pin = struct { []const u8, usize, usize };

/// Nets of the domain fixtures: two 1.8 V domains and a third ground.
pub const domain_nets = [_][]const u8{ "VDD1", "VSS1", "VDD2", "VSS2", "VSS3", "SIG", "OUT" };

/// Each fixture as drawn, transposed (a quarter turn then a mirror) at the
/// far offset, and turned half way: three placements move every pinned
/// marker off both axes.
pub fn everyPlacementInto(arena: Allocator, fixtures: []const Fixture, out: *std.ArrayList(Fixture)) !void {
    for (fixtures) |*f| {
        try out.append(arena, try f.transformed(arena, .identity, 0, 0));
        try out.append(arena, try f.transformed(arena, .{ .turns = 1, .mirror = true }, -1_234_567, 987_654));
        try out.append(arena, try f.transformed(arena, .{ .turns = 2, .mirror = false }, 0, 0));
    }
}

/// Where a limit sits against the value it is swept around.
pub fn side(limit: f64, value: f64) []const u8 {
    return if (limit < value) "below" else if (limit == value) "at" else "above";
}

/// `value` and one part in a thousand either side.
pub fn sweep(value: f64) [3]f64 {
    return .{ value * 0.999, value, value * 1.001 };
}

pub fn ohms(x: f64) Finding {
    return .{ .measured = Measurement.resistance(.{ .raw = x }) };
}

pub fn microamps(x: f64) Finding {
    return .{ .measured = Measurement.current(.{ .raw = x }) };
}

pub fn area(nm2: i128) Finding {
    return .{ .measured = Measurement.area(nm2) };
}

/// `f` with its marker pinned at `(x, y)`.
pub fn at(f: Finding, x: i64, y: i64) Finding {
    var out = f;
    out.at = .{ x, y };
    return out;
}

/// A rule that ran and found exactly `findings`, copied into the arena.
pub fn rule(arena: Allocator, id: []const u8, findings: []const Finding) !Expect {
    return .{ .id = id, .findings = try arena.dupe(Finding, findings) };
}

pub fn expects(arena: Allocator, e: []const Expect) ![]const Expect {
    return arena.dupe(Expect, e);
}

/// The three strips, widths `w` (pad, VSS, VDD), labelled PAD, VSS and VDD,
/// with a 200 nm marker centred on x for each diode, reaching 100 nm into
/// both strips it spans.
pub fn esdLayout(arena: Allocator, w: [3]i64, diodes: []const Placed) !Layout {
    var l: Layout = .{};
    const names = [3][3][]const u8{ .{ "pad", "padtxt", "PAD" }, .{ "met1", "m1txt", "VSS" }, .{ "met2", "m2txt", "VDD" } };
    for (names, 0..) |n, k| {
        try rect(&l, arena, n[0], .{ 0, strip_y[k], strip, strip_y[k] + w[k] });
        try l.label(arena, n[1], 100, strip_y[k] + @divTrunc(w[k], 2), n[2]);
    }
    for (diodes) |p| {
        const m = p[0].marker();
        const lo, const hi = if (strip_y[m.a] < strip_y[m.b]) .{ m.a, m.b } else .{ m.b, m.a };
        try rect(&l, arena, m.layer, .{ p[1] - 100, strip_y[lo] + w[lo] - 100, p[1] + 100, strip_y[hi] + 100 });
    }
    return l;
}

/// VSS's own pin: a `pad` square centred at 18 µm joined to the 1 µm VSS
/// strip by one `padv` cut under its centre.
pub fn pinVss(l: *Layout, arena: Allocator) !void {
    try rect(l, arena, "pad", .{ 17_500, -3000, 18_500, -2000 });
    try rect(l, arena, "padv", .{ 17_900, -2600, 18_100, -2400 });
}

/// VDD a 1.8 V power supply and VSS its ground.
pub fn esdIntent(arena: Allocator) ![]const u8 {
    return board.intentText(arena, &.{.{ .name = "a", .mv = 1800.0 }}, &.{ .{ "VDD", "a", "power" }, .{ "VSS", "a", "ground" } }, &.{});
}

/// Transistors and two-pin devices drawn as `Board` draws its transistors:
/// one met2 track per net labelled `labels[net]` (an empty name leaves it
/// unlabelled), from x -1 µm to past the last column (20 µm at least). A
/// two-pin device is two diffusion boxes under one 400 × 200 nm marker,
/// each wired to its net's track by a riser.
pub fn circuitPins(arena: Allocator, labels: []const []const u8, devs: []const Dev, pins: []const Pin) !Layout {
    var l: Layout = .{};
    for (devs, 0..) |dv, i| {
        const x0 = @as(i64, @intCast(i)) * board.pitch;
        try rect(&l, arena, "diff", .{ x0, 0, x0 + 1000, 1000 });
        try rect(&l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, 1000 });
        try rect(&l, arena, "poly", .{ x0 + 1000, 0, x0 + 1200, 1600 });
        try rect(&l, arena, dv.model.marker(), .{ x0 + 1000, 0, x0 + 1200, 1000 });
        try riser(&l, arena, x0 + 400, 400, dv.s);
        try riser(&l, arena, x0 + 1600, 400, dv.d);
        try riser(&l, arena, x0 + 1000, 1400, dv.g);
    }
    for (pins, 0..) |p, j| {
        const x0 = @as(i64, @intCast(devs.len + j)) * board.pitch;
        try rect(&l, arena, "diff", .{ x0, 0, x0 + 1000, 1000 });
        try rect(&l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, 1000 });
        try rect(&l, arena, p[0], .{ x0 + 900, 400, x0 + 1300, 600 });
        try riser(&l, arena, x0 + 400, 400, p[1]);
        try riser(&l, arena, x0 + 1600, 400, p[2]);
    }
    // At least 20 µm, so a riser beside the columns still lands on its track.
    const right = @max(@as(i64, @intCast(devs.len + pins.len)) * board.pitch + 1000, 20_000);
    for (labels, 0..) |name, net| {
        const ty = board.trackY(net);
        try rect(&l, arena, "met2", .{ -1000, ty, right, ty + board.track_h });
        if (name.len > 0) try l.label(arena, "m2txt", -900, ty + 200, name);
    }
    return l;
}

/// A pad on `net`'s track, joined to it by one `padv` cut.
pub fn padOn(l: *Layout, arena: Allocator, net: usize) !void {
    const ty = board.trackY(net);
    try rect(l, arena, "pad", .{ -1000, ty, -400, ty + board.track_h });
    try rect(l, arena, "padv", .{ -800, ty + 150, -600, ty + 250 });
}

/// VDD1 and VSS1 are domain `d1`, VDD2 and VSS2 domain `d2`, VSS3 the only
/// supply of `d3`, each at 1.8 V.
pub fn domainIntent(arena: Allocator) ![]const u8 {
    return board.intentText(arena, &.{ .{ .name = "d1", .mv = 1800.0 }, .{ .name = "d2", .mv = 1800.0 }, .{ .name = "d3", .mv = 1800.0 } }, &.{
        .{ "VDD1", "d1", "power" },
        .{ "VSS1", "d1", "ground" },
        .{ "VDD2", "d2", "power" },
        .{ "VSS2", "d2", "ground" },
        .{ "VSS3", "d3", "ground" },
    }, &.{});
}
