//! A small circuit of transistors and taps on four nets, drawn as layout
//! (diffusion, poly and a channel marker per transistor, met1 risers to one
//! met2 track per net) and judged by a naive oracle of every rule in
//! `topo_rules` (board_expect.zig). This file holds the board, its drawing,
//! its intent and the brute-force voltage model. Ported from
//! crates/check/tests/erc/ported.rs (`TOPO_PROCESS`, `TOPO_RULES`, `Board`,
//! `Model`, `Dev`, `riser`, `intent`, `Board::{layout, intent, reach}`).
//!
//! Every slice a board holds is the caller's (an arena or a constant).
//!
//! Contents:
//! - `pub const nets: usize`, `pub const pitch: i64`, `pub const track_h: i64`, `pub fn trackY(net: usize) i64`
//! - `pub const topo_process`, `pub const TopoRule`, `pub const topo_rules`, `pub const Limits`, `pub fn topoDeck(arena, limits: Limits) ![]const u8`
//! - `pub const Model = enum`, `marker(m) []const u8`, `condition(m) ?Condition`, `pub const Condition`
//! - `pub const Dev = struct`, `pub fn dev(model: Model, g: usize, s: usize, d: usize) Dev`
//! - `pub const Supply`, `pub const Reach`, `pub const BoardState`, `pub const Input`, `pub const Domain`, `pub const Tap`, `pub const Rect`
//! - `pub const Board = struct`, `columns(b) usize`, `layout(b, arena) !Layout`, `intentJson(b, arena) ![]const u8`,
//!   `supply(b, net) ?Supply`, `stateSupplies(b, arena, st) ![]const Supply`, `reach(b) [nets]?Reach`, `reachWith(b, supplies) [nets]?Reach`
//! - `pub fn intentText(arena, domains: []const Domain, supplies: []const [3][]const u8, limits: []const []const u8) ![]const u8`
//! - `pub fn rect(l: *Layout, arena, layer, r: Rect) !void`, `pub fn riser(l: *Layout, arena, x: i64, base: i64, net: usize) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;

/// Nets per board: one met2 track each.
pub const nets: usize = 4;
pub const pitch: i64 = 4000;
pub const track_h: i64 = 400;

/// A box `(xlo, ylo, xhi, yhi)` in nanometres.
pub const Rect = [4]i64;

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

/// One rule a board is checked against: its id, its row, and whether it
/// needs intent.
pub const TopoRule = struct { id: []const u8, row: []const u8, intent: bool };

/// Every rule a board is checked against.
pub const topo_rules = [_]TopoRule{
    .{ .id = "fg", .row = "floating_gate(; labels_are_ports: false)", .intent = false },
    .{ .id = "fgp", .row = "floating_gate(; labels_are_ports: true)", .intent = false },
    .{ .id = "md1", .row = "multiple_drivers(; max: 1)", .intent = true },
    .{ .id = "md2", .row = "multiple_drivers(; max: 2)", .intent = true },
    .{ .id = "thl", .row = "tie_high_low()", .intent = true },
    .{ .id = "up", .row = "unconnected_pin(met1, met2)", .intent = false },
    .{ .id = "ss", .row = "supply_short(ntap, ptap)", .intent = false },
    .{ .id = "ssw", .row = "supply_short(ntap, ptap, nwpm)", .intent = false },
    .{ .id = "soft", .row = "soft_connection(well)", .intent = false },
    .{ .id = "fo", .row = "fanout(; max: 1)", .intent = false },
    .{ .id = "sp1", .row = "supply_path(; both: false, labels_are_ports: false)", .intent = true },
    .{ .id = "sp2", .row = "supply_path(; both: true, labels_are_ports: false)", .intent = true },
    .{ .id = "sp3", .row = "supply_path(; both: true, labels_are_ports: true)", .intent = true },
    .{ .id = "gp0", .row = "gate_path(; ground: true, max_devices: 0)", .intent = true },
    .{ .id = "gp1", .row = "gate_path(; ground: false, max_devices: 1)", .intent = true },
    .{ .id = "cl", .row = "combinational_loop()", .intent = true },
    .{ .id = "ug", .row = "undriven_gate()", .intent = true },
    .{ .id = "iso", .row = "missing_isolation(; isolation: [\"pfet\"])", .intent = true },
    .{ .id = "gox", .row = "gate_oxide(; models: [\"nfet\", \"nfet_b\", \"pfet_b\"], max: {gox})", .intent = true },
    .{ .id = "vds", .row = "drain_source(; models: [\"nfet\", \"pfet\", \"nfet_b\", \"pfet_b\"], max: {vds})", .intent = true },
    .{ .id = "ls", .row = "missing_level_shifter(; shifters: [\"pfet\"])", .intent = true },
    .{ .id = "xing", .row = "domain_crossing()", .intent = true },
    .{ .id = "hv", .row = "hv_domain(; max_delta: {hv}, isolation: iso)", .intent = true },
    .{ .id = "wb", .row = "well_bias(; pmos: [\"pfet_b\"], nmos: [\"nfet_b\"])", .intent = true },
    .{ .id = "esd", .row = "esd_topological(pad; clamps: [\"clamp\"])", .intent = true },
    .{ .id = "esdl", .row = "esd_latchup(pad, ring; min_guard_ring_width: 500nm, max_tap_distance: 2000nm, clamps: [\"clamp\"])", .intent = true },
};

/// The voltage limits of a board's `gate_oxide`, `drain_source` and
/// `hv_domain` rows, mV.
pub const Limits = struct { gox: f64 = 1800.0, vds: f64 = 1800.0, hv: f64 = 1000.0 };

/// A transistor model of `topo_process`.
pub const Model = enum {
    nfet,
    pfet,
    clamp,
    nfet_b,
    pfet_b,
    /// Conducts while its gate can reach 1 V or more.
    nfet_c,
    /// Conducts while its gate can fall to 2.5 V or less.
    pfet_c,

    pub fn marker(m: Model) []const u8 {
        return switch (m) {
            .nfet => "mkn",
            .pfet => "mkp",
            .clamp => "mkc",
            .nfet_b => "mknb",
            .pfet_b => "mkpb",
            .nfet_c => "mkcn",
            .pfet_c => "mkcp",
        };
    }

    /// The deck row's gate condition, as `topo_process` states it.
    pub fn condition(m: Model) ?Condition {
        return switch (m) {
            .nfet_c => .{ .at_least = true, .mv = 1000.0 },
            .pfet_c => .{ .at_least = false, .mv = 2500.0 },
            .nfet, .pfet, .clamp, .nfet_b, .pfet_b => null,
        };
    }
};

/// A gate condition: on at or above (`at_least`), else at or below, `mv`.
pub const Condition = struct { at_least: bool, mv: f64 };

/// One transistor: the nets of its gate, its source (the diffusion drawn
/// first, which extraction calls the source) and drain, and its bulk for
/// the `_b` models.
pub const Dev = struct { model: Model, g: usize, s: usize, d: usize, b: ?usize = null };

/// A supply as the intent declares it; `domain` is the domain's index in
/// name order, its bit in a power mask.
pub const Supply = struct { net: usize, power: bool, domain: u32, nominal: f64 };

/// What a net can reach from the supplies (`erc.voltage`'s model).
pub const Reach = struct { lo: f64, hi: f64, nominal_lo: f64, nominal_hi: f64, power: u64 };

/// A held input of a power state, mV.
pub const Input = struct { net: usize, mv: f64 };

/// A power state: the supply nets it switches off and the nets it holds.
pub const BoardState = struct { name: []const u8, off: []const usize = &.{}, inputs: []const Input = &.{} };

/// A domain `(name, mV)`.
pub const Domain = struct { name: []const u8, mv: f64 };

/// A tap stub: n-tap (else p-tap), and its net.
pub const Tap = struct { n: bool, net: usize };

/// A circuit on `nets` nets, drawn as layout and judged by a naive oracle.
pub const Board = struct {
    devs: []const Dev = &.{},
    taps: []const Tap = &.{},
    /// Tap indices an `nwpm` polygon covers.
    nwpm: []const usize = &.{},
    /// The net a pad sits on.
    pad: ?usize = null,
    /// A guard ring's box.
    ring: ?Rect = null,
    /// Device indices an `iso` polygon covers.
    iso: []const usize = &.{},
    labels: [nets]?[]const u8 = @splat(null),
    supplies: []const Supply = &.{},
    /// In name order.
    domains: []const Domain = &.{},
    with_intent: bool = false,
    limits: Limits = .{},
    states: []const BoardState = &.{},

    pub fn columns(b: *const Board) usize {
        return b.devs.len + b.taps.len;
    }

    pub fn layout(b: *const Board, arena: Allocator) !Layout {
        var l: Layout = .{};
        for (b.devs, 0..) |dv, i| {
            const x0 = @as(i64, @intCast(i)) * pitch;
            try rect(&l, arena, "diff", .{ x0, 0, x0 + 1000, 1000 });
            try rect(&l, arena, "diff", .{ x0 + 1200, 0, x0 + 2200, 1000 });
            try rect(&l, arena, "poly", .{ x0 + 1000, 0, x0 + 1200, 1600 });
            try rect(&l, arena, dv.model.marker(), .{ x0 + 1000, 0, x0 + 1200, 1000 });
            try riser(&l, arena, x0 + 400, 400, dv.s);
            try riser(&l, arena, x0 + 1600, 400, dv.d);
            try riser(&l, arena, x0 + 1000, 1400, dv.g);
            if (dv.b) |bulk| {
                try rect(&l, arena, "well", .{ x0 + 1000, -600, x0 + 2700, 0 });
                try riser(&l, arena, x0 + 2400, -500, bulk);
            }
            if (std.mem.indexOfScalar(usize, b.iso, i) != null) try rect(&l, arena, "iso", .{ x0 + 900, -100, x0 + 1300, 1100 });
        }
        for (b.taps, 0..) |t, j| {
            const x0 = @as(i64, @intCast(b.devs.len + j)) * pitch;
            try rect(&l, arena, if (t.n) "ntap" else "ptap", .{ x0, 0, x0 + 600, 600 });
            try riser(&l, arena, x0 + 200, 200, t.net);
            if (std.mem.indexOfScalar(usize, b.nwpm, j) != null) try rect(&l, arena, "nwpm", .{ x0 - 100, -100, x0 + 700, 700 });
        }
        const right = @as(i64, @intCast(b.columns())) * pitch + 1000;
        for (0..nets) |net| {
            const ty = trackY(net);
            try rect(&l, arena, "met2", .{ -1000, ty, right, ty + track_h });
            if (b.labels[net]) |name| try l.label(arena, "m2txt", -900, ty + 200, name);
        }
        if (b.pad) |net| {
            const ty = trackY(net);
            try rect(&l, arena, "pad", .{ -1000, ty, -400, ty + track_h });
            try rect(&l, arena, "padv", .{ -800, ty + 150, -600, ty + 250 });
        }
        if (b.ring) |r| try rect(&l, arena, "ring", r);
        return l;
    }

    /// The board's design-intent JSON: its supplies by label, and its
    /// power states.
    pub fn intentJson(b: *const Board, arena: Allocator) ![]const u8 {
        var supplies: std.ArrayList([3][]const u8) = .empty;
        for (b.supplies) |s| try supplies.append(arena, .{ b.labels[s.net].?, b.domains[s.domain].name, if (s.power) "power" else "ground" });
        const base = try intentText(arena, b.domains, supplies.items, &.{});
        if (b.states.len == 0) return base;
        var states: std.ArrayList(u8) = .empty;
        for (b.states, 0..) |st, k| {
            if (k > 0) try states.append(arena, ',');
            try states.print(arena, "{{\"name\":\"{s}\",\"off\":[", .{st.name});
            for (st.off, 0..) |n, i| try states.print(arena, "{s}\"{s}\"", .{ if (i > 0) "," else "", b.labels[n].? });
            try states.appendSlice(arena, "],\"inputs\":[");
            for (st.inputs, 0..) |in, i| try states.print(arena, "{s}{{\"net\":\"{s}\",\"voltage_mv\":{d}}}", .{ if (i > 0) "," else "", b.labels[in.net].?, in.mv });
            try states.appendSlice(arena, "]}");
        }
        return std.fmt.allocPrint(arena, "{s},\"states\":[{s}]}}", .{ base[0 .. base.len - 1], states.items });
    }

    pub fn supply(b: *const Board, net: usize) ?Supply {
        return supplyIn(b.supplies, net);
    }

    /// The supplies of power state `st`, as `IntentMap.inState` states them:
    /// every supply it neither switches off nor holds, then each held net as
    /// a supply at its voltage (0 V a ground, otherwise power of domain 0).
    pub fn stateSupplies(b: *const Board, arena: Allocator, st: BoardState) ![]const Supply {
        var out: std.ArrayList(Supply) = .empty;
        for (b.supplies) |s| {
            const off = std.mem.indexOfScalar(usize, st.off, s.net) != null;
            const held = for (st.inputs) |in| {
                if (in.net == s.net) break true;
            } else false;
            if (!off and !held) try out.append(arena, s);
        }
        for (st.inputs) |in| try out.append(arena, .{ .net = in.net, .power = in.mv != 0.0, .domain = 0, .nominal = in.mv });
        return out.items;
    }

    /// `erc.voltage`'s model by brute force: a supply sits at its nominal
    /// (power) or 0 V (ground); every conducting transistor widens each
    /// non-supply source and drain net to the union of both, swept until
    /// nothing changes; gates and bulks pass nothing. A conditioned
    /// transistor conducts while its gate's range reaches the condition, or
    /// when its gate is free (unreached with every channel on, or still
    /// unreached after a sweep).
    pub fn reach(b: *const Board) [nets]?Reach {
        return b.reachWith(b.supplies);
    }

    pub fn reachWith(b: *const Board, supplies: []const Supply) [nets]?Reach {
        var all_free: [16]bool = @splat(true);
        const everything = sweep(b, supplies, all_free[0..b.devs.len]);
        var free: [16]bool = undefined;
        for (b.devs, 0..) |d, i| free[i] = everything[d.g] == null;
        while (true) {
            const r = sweep(b, supplies, free[0..b.devs.len]);
            var any = false;
            for (b.devs, 0..) |d, i| if (!free[i] and r[d.g] == null) {
                free[i] = true;
                any = true;
            };
            if (!any) return r;
        }
    }
};

const track_y0: i64 = 3000;
const track_pitch: i64 = 1000;

pub fn trackY(net: usize) i64 {
    return track_y0 + @as(i64, @intCast(net)) * track_pitch;
}

/// `topo_process` and every `topo_rules` row with `limits` filled in.
pub fn topoDeck(arena: Allocator, limits: Limits) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, topo_process);
    const gox = try std.fmt.allocPrint(arena, "{d}mV", .{limits.gox});
    const vds = try std.fmt.allocPrint(arena, "{d}mV", .{limits.vds});
    const hv = try std.fmt.allocPrint(arena, "{d}mV", .{limits.hv});
    for (topo_rules) |r| {
        const a = try std.mem.replaceOwned(u8, arena, r.row, "{gox}", gox);
        const c = try std.mem.replaceOwned(u8, arena, a, "{vds}", vds);
        const d = try std.mem.replaceOwned(u8, arena, c, "{hv}", hv);
        try out.print(arena, "rule {s} {s}\n", .{ r.id, d });
    }
    return out.items;
}

pub fn dev(model: Model, g: usize, s: usize, d: usize) Dev {
    return .{ .model = model, .g = g, .s = s, .d = d };
}

/// A design-intent file: `domains`, `supplies` as `(net, domain, role)`,
/// and `limits` as raw JSON objects.
pub fn intentText(arena: Allocator, domains: []const Domain, supplies: []const [3][]const u8, limits: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"domains\":{");
    for (domains, 0..) |d, i| try out.print(arena, "{s}\"{s}\":{{\"voltage_mv\":{d}}}", .{ if (i > 0) "," else "", d.name, d.mv });
    try out.appendSlice(arena, "},\"supplies\":[");
    for (supplies, 0..) |s, i| try out.print(arena, "{s}{{\"net\":\"{s}\",\"domain\":\"{s}\",\"role\":\"{s}\"}}", .{ if (i > 0) "," else "", s[0], s[1], s[2] });
    try out.appendSlice(arena, "],\"limits\":[");
    for (limits, 0..) |l, i| try out.print(arena, "{s}{s}", .{ if (i > 0) "," else "", l });
    try out.appendSlice(arena, "]}");
    return out.items;
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

// ---- private ----

fn supplyIn(supplies: []const Supply, net: usize) ?Supply {
    for (supplies) |s| if (s.net == net) return s;
    return null;
}

fn merge(a: ?Reach, b: ?Reach) ?Reach {
    const x = a orelse return b;
    const y = b orelse return a;
    return .{ .lo = @min(x.lo, y.lo), .hi = @max(x.hi, y.hi), .nominal_lo = @min(x.nominal_lo, y.nominal_lo), .nominal_hi = @max(x.nominal_hi, y.nominal_hi), .power = x.power | y.power };
}

fn same(a: ?Reach, b: ?Reach) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

fn sweep(b: *const Board, supplies: []const Supply, free: []const bool) [nets]?Reach {
    var r: [nets]?Reach = undefined;
    for (&r, 0..) |*x, net| x.* = if (supplyIn(supplies, net)) |s| .{
        .lo = if (s.power) s.nominal else 0.0,
        .hi = if (s.power) s.nominal else 0.0,
        .nominal_lo = s.nominal,
        .nominal_hi = s.nominal,
        .power = if (s.power) @as(u64, 1) << @intCast(s.domain) else 0,
    } else null;
    while (true) {
        var changed = false;
        for (b.devs, 0..) |dv, i| {
            const on = if (dv.model.condition()) |c| free[i] or (if (r[dv.g]) |g| (if (c.at_least) g.hi >= c.mv else g.lo <= c.mv) else false) else true;
            if (!on) continue;
            const both = merge(r[dv.s], r[dv.d]);
            for ([2]usize{ dv.s, dv.d }) |n| {
                const widened = merge(r[n], both);
                if (supplyIn(supplies, n) == null and !same(widened, r[n])) {
                    r[n] = widened;
                    changed = true;
                }
            }
        }
        if (!changed) return r;
    }
}
