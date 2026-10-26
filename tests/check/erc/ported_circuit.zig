//! The named-circuit helpers of the ported fixture groups: the transistor
//! process with its diode and resistor recognisers, circuits of transistors
//! and two-pin devices wired by met1 risers to one met2 track per net, the
//! intent JSON, the three placements and the finding constructors. Ported
//! from crates/check/tests/erc/ported.rs (`TOPO_PROCESS`, `diode_process`,
//! `circuit`, `circuit_pins`, `bulk`, `riser`, `intent`, `domain_intent`,
//! `every_placement`, `count`, `length`, `ratio`, `millivolts`, `side`,
//! `sweep`).
//!
//! Every slice here is the caller's arena's or a constant.
//!
//! Contents:
//! - `pub const Rect`, `pub const Model = enum`, `marker(m) []const u8`, `pub const Dev = struct`, `pub const Pin = struct`
//! - `pub const pitch`, `pub const track_h`, `pub const nets`, `pub const topo_process`, `pub const diode_process`, `pub const domain_nets`
//! - `pub fn dev(model: Model, g: usize, s: usize, d: usize) Dev`, `pub fn bulk(model: Model, g: usize, s: usize, d: usize, b: usize) Dev`, `pub fn trackY(net: usize) i64`
//! - `pub fn rect(l: *Layout, arena, layer, r: Rect) !void`, `pub fn riser(l: *Layout, arena, x: i64, base: i64, net: usize) !void`
//! - `pub fn circuit(arena, labels, devs, diodes: []const [2]usize) !Layout`, `pub fn circuitPins(arena, labels, devs, pins: []const Pin) !Layout`
//! - `pub fn intentText(arena, domains: []const Domain, supplies: []const [3][]const u8) ![]const u8`, `pub const Domain`, `pub fn domainIntent(arena) ![]const u8`
//! - `pub fn everyPlacement(arena, out: *std.ArrayList(Fixture), f: Fixture) !void`
//! - `pub fn count(n: u32) Finding`, `length`, `ratio`, `millivolts`, `pub fn repeat(arena, f: Finding, n: usize) ![]const Finding`
//! - `pub fn side(limit: f64, value: f64) []const u8`, `pub fn sweep(value: f64) [3]f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;

/// A box `(xlo, ylo, xhi, yhi)` in nanometres.
pub const Rect = [4]i64;

/// A transistor model of `topo_process`.
pub const Model = enum {
    nfet,
    pfet,
    clamp,
    nfet_b,
    pfet_b,

    pub fn marker(m: Model) []const u8 {
        return switch (m) {
            .nfet => "mkn",
            .pfet => "mkp",
            .clamp => "mkc",
            .nfet_b => "mknb",
            .pfet_b => "mkpb",
        };
    }
};

/// One transistor: the nets of its gate, its source (the diffusion drawn
/// first), its drain, and its well bulk for the `_b` models.
pub const Dev = struct { model: Model, g: usize, s: usize, d: usize, b: ?usize = null };

/// A two-pin device: its recogniser's marker layer, the first pin's net
/// (its diffusion drawn first) and the second's.
pub const Pin = struct { marker: []const u8, a: usize, b: usize };

/// A domain `(name, mV)`.
pub const Domain = struct { name: []const u8, mv: f64 };

pub const pitch: i64 = 4000;

pub const track_h: i64 = 400;

/// Tracks the matched-unit boards draw.
pub const nets: usize = 4;

/// Transistors (diffusion source and drain, a poly gate, a channel marker;
/// the `_b` models add a well bulk), tap stubs, pads and markers, wired by
/// cuts and met1 risers to one met2 track per net, every conductor with a
/// sheet resistance.
pub const topo_process =
    \\grid 1nm
    \\layer diff = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer well = gds(3, 0)
    \\layer ntap = gds(4, 0)
    \\layer ptap = gds(5, 0)
    \\layer cont = gds(6, 0)
    \\layer met1 = gds(7, 0)
    \\layer via1 = gds(8, 0)
    \\layer met2 = gds(9, 0)
    \\layer m2txt = gds(9, 1)
    \\layer padv = gds(10, 0)
    \\layer pad = gds(11, 0)
    \\layer mkn = gds(20, 0)
    \\layer mkp = gds(21, 0)
    \\layer mkc = gds(22, 0)
    \\layer mknb = gds(23, 0)
    \\layer mkpb = gds(24, 0)
    \\layer nwpm = gds(30, 0)
    \\layer ring = gds(31, 0)
    \\layer iso = gds(32, 0)
    \\layer mkcn = gds(25, 0)
    \\layer mkcp = gds(26, 0)
    \\connect conductors [diff, poly, well, ntap, ptap, met1, met2, pad]
    \\connect touch_within_layer
    \\connect via cont [diff, met1]
    \\connect via cont [poly, met1]
    \\connect via cont [well, met1]
    \\connect via cont [ntap, met1]
    \\connect via cont [ptap, met1]
    \\connect via via1 [met1, met2]
    \\connect via padv [met2, pad]
    \\connect label m2txt names met2
    \\device mos mkn model "nfet" terminals [poly, diff, diff]
    \\device mos mkp model "pfet" terminals [poly, diff, diff]
    \\device mos mkc model "clamp" terminals [poly, diff, diff]
    \\device mos mknb model "nfet_b" terminals [poly, diff, diff, well]
    \\device mos mkpb model "pfet_b" terminals [poly, diff, diff, well]
    \\device mos mkcn model "nfet_c" terminals [poly, diff, diff] on_gate_min 1V
    \\device mos mkcp model "pfet_c" terminals [poly, diff, diff] on_gate_max 2.5V
    \\pex well thickness 100nm height 5nm sheet 1000ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex diff thickness 100nm height 10nm sheet 100ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex ntap thickness 100nm height 10nm sheet 100ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex ptap thickness 100nm height 10nm sheet 100ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex poly thickness 100nm height 20nm sheet 10ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex cont thickness 100nm height 50nm sheet 5ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met1 thickness 100nm height 100nm sheet 0.125ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex via1 thickness 100nm height 200nm sheet 1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met2 thickness 100nm height 300nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex padv thickness 100nm height 400nm sheet 1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex pad thickness 100nm height 500nm sheet 0.01ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\
;

/// `topo_process` with a diode recogniser `mkdi` (model `dio`): its anode
/// the first diffusion under the marker, its cathode the second; and a
/// resistor recogniser `mkres` (model `rs`) drawn the same way.
pub const diode_process = topo_process ++
    \\layer mkdi = gds(27, 0)
    \\layer mkres = gds(28, 0)
    \\device diode mkdi model "dio" terminals [diff, diff]
    \\device resistor mkres model "rs" terminals [diff, diff]
    \\
;

/// Nets of the domain fixtures: two 1.8 V domains and a third ground.
pub const domain_nets = [_][]const u8{ "VDD1", "VSS1", "VDD2", "VSS2", "VSS3", "SIG", "OUT" };

const track_y0: i64 = 3000;

const track_pitch: i64 = 1000;

pub fn dev(model: Model, g: usize, s: usize, d: usize) Dev {
    return .{ .model = model, .g = g, .s = s, .d = d };
}

/// A bulk transistor: `dev` with its bulk on net `b`.
pub fn bulk(model: Model, g: usize, s: usize, d: usize, b: usize) Dev {
    return .{ .model = model, .g = g, .s = s, .d = d, .b = b };
}

pub fn trackY(net: usize) i64 {
    return track_y0 + @as(i64, @intCast(net)) * track_pitch;
}

pub fn rect(l: *Layout, arena: Allocator, layer: []const u8, r: Rect) !void {
    try l.rect(arena, layer, r[0], r[1], r[2], r[3]);
}

/// A met1 riser at column `x` (200 wide) from a cut at `base` to a via in
/// `net`'s track.
pub fn riser(l: *Layout, arena: Allocator, x: i64, base: i64, net: usize) !void {
    const ty = trackY(net);
    try rect(l, arena, "cont", .{ x + 50, base + 50, x + 150, base + 150 });
    try rect(l, arena, "met1", .{ x, base, x + 200, ty + track_h });
    try rect(l, arena, "via1", .{ x + 50, ty + 150, x + 150, ty + 250 });
}

/// Transistors and `(anode, cathode)` diodes on `labels.len` nets.
pub fn circuit(arena: Allocator, labels: []const []const u8, devs: []const Dev, diodes: []const [2]usize) !Layout {
    const pins = try arena.alloc(Pin, diodes.len);
    for (pins, diodes) |*p, d| p.* = .{ .marker = "mkdi", .a = d[0], .b = d[1] };
    return circuitPins(arena, labels, devs, pins);
}

/// Transistors then two-pin devices, one column each, and one met2 track
/// per net from x -1 µm to past the last column (20 µm at least), labelled
/// `labels[net]` unless that is empty.
pub fn circuitPins(arena: Allocator, labels: []const []const u8, devs: []const Dev, pins: []const Pin) !Layout {
    var l: Layout = .{};
    for (devs, 0..) |dv, i| {
        const x0 = @as(i64, @intCast(i)) * pitch;
        try rect(&l, arena, "diff", .{ x0, 0, x0 + 1000, 1000 });
        try rect(&l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, 1000 });
        try rect(&l, arena, "poly", .{ x0 + 1000, 0, x0 + 1200, 1600 });
        try rect(&l, arena, dv.model.marker(), .{ x0 + 1000, 0, x0 + 1200, 1000 });
        try riser(&l, arena, x0 + 400, 400, dv.s);
        try riser(&l, arena, x0 + 1600, 400, dv.d);
        try riser(&l, arena, x0 + 1000, 1400, dv.g);
        if (dv.b) |b| {
            try rect(&l, arena, "well", .{ x0 + 1000, -600, x0 + 2700, 0 });
            try riser(&l, arena, x0 + 2400, -500, b);
        }
    }
    for (pins, 0..) |p, j| {
        const x0 = @as(i64, @intCast(devs.len + j)) * pitch;
        try rect(&l, arena, "diff", .{ x0, 0, x0 + 1000, 1000 });
        try rect(&l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, 1000 });
        try rect(&l, arena, p.marker, .{ x0 + 900, 400, x0 + 1300, 600 });
        try riser(&l, arena, x0 + 400, 400, p.a);
        try riser(&l, arena, x0 + 1600, 400, p.b);
    }
    // At least 20 µm, so a riser beside the columns still lands on its track.
    const right = @max(@as(i64, @intCast(devs.len + pins.len)) * pitch + 1000, 20_000);
    for (labels, 0..) |name, net| {
        const ty = trackY(net);
        try rect(&l, arena, "met2", .{ -1000, ty, right, ty + track_h });
        if (name.len > 0) try l.label(arena, "m2txt", -900, ty + 200, name);
    }
    return l;
}

/// A design-intent file: `domains`, `supplies` as `(net, domain, role)`,
/// no limits.
pub fn intentText(arena: Allocator, domains: []const Domain, supplies: []const [3][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"domains\":{");
    for (domains, 0..) |d, i| try out.print(arena, "{s}\"{s}\":{{\"voltage_mv\":{d}}}", .{ if (i > 0) "," else "", d.name, d.mv });
    try out.appendSlice(arena, "},\"supplies\":[");
    for (supplies, 0..) |s, i| try out.print(arena, "{s}{{\"net\":\"{s}\",\"domain\":\"{s}\",\"role\":\"{s}\"}}", .{ if (i > 0) "," else "", s[0], s[1], s[2] });
    try out.appendSlice(arena, "],\"limits\":[]}");
    return out.items;
}

/// VDD1 and VSS1 are domain `d1`, VDD2 and VSS2 domain `d2`, VSS3 the only
/// supply of `d3`, each at 1.8 V.
pub fn domainIntent(arena: Allocator) ![]const u8 {
    return intentText(arena, &.{ .{ .name = "d1", .mv = 1800 }, .{ .name = "d2", .mv = 1800 }, .{ .name = "d3", .mv = 1800 } }, &.{
        .{ "VDD1", "d1", "power" },
        .{ "VSS1", "d1", "ground" },
        .{ "VDD2", "d2", "power" },
        .{ "VSS2", "d2", "ground" },
        .{ "VSS3", "d3", "ground" },
    });
}

/// The fixture as drawn, transposed (a quarter turn then a mirror) at the
/// far offset, and turned half way: three placements that move every pinned
/// marker off both axes.
pub fn everyPlacement(arena: Allocator, out: *std.ArrayList(Fixture), f: Fixture) !void {
    try out.append(arena, try f.transformed(arena, .identity, 0, 0));
    try out.append(arena, try f.transformed(arena, .{ .turns = 1, .mirror = true }, -1_234_567, 987_654));
    try out.append(arena, try f.transformed(arena, .{ .turns = 2, .mirror = false }, 0, 0));
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn count(n: u32) Finding {
    return .{ .measured = .count(n) };
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn length(nm: i64) Finding {
    return .{ .measured = .length(nm) };
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn ratio(x: f64) Finding {
    return .{ .measured = .ratio(x) };
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn millivolts(x: f64) Finding {
    return .{ .measured = .voltage(.{ .raw = x }) };
}

/// `n` copies of `f`.
pub fn repeat(arena: Allocator, f: Finding, n: usize) ![]const Finding {
    const out = try arena.alloc(Finding, n);
    @memset(out, f);
    return out;
}

/// Where a limit sits against the value it is swept around.
pub fn side(limit: f64, value: f64) []const u8 {
    return switch (std.math.order(limit, value)) {
        .lt => "below",
        .eq => "at",
        .gt => "above",
    };
}

/// `value` and one part in a thousand either side.
pub fn sweep(value: f64) [3]f64 {
    return .{ value * 0.999, value, value * 1.001 };
}
