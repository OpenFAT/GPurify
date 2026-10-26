//! LVS fixtures' circuits: devices on numbered nets, the drawer that turns
//! one into a real layout, and the writer that turns one into a SPICE or
//! Spectre reference. Ported from tests/exhaustive/lvs.rs (`MOS_DECK`,
//! `EXTRA_DECK`, `Model`, `Dev`, `Circuit`, the drawer and the reference
//! writer).
//!
//! The drawer: a MOS is poly across diffusion under an implant, a passive
//! a marker over its terminal pads, and every terminal is contacted to a
//! met1 stub that climbs to its net's met2 track, which carries the net's
//! label when the net is a port. Every circuit lives in the caller's arena.
//!
//! Contents:
//! - `pub const mos_deck`, `pub const extra_deck`, `pub const full_deck`, `pub const tolerance`
//! - `pub const Model`, `isMos`, `name`, `primary`, `letter`; `pub const pin2_area`, `pub const bjt_area`
//! - `pub const Prm`, `pub const Dev`, `mos`, `onPins`, `sized`, `writes`, `bulk`, `times`, `withArea`, `valued`, `param`, `pinsOf`, `paramsOf`
//! - `pub const Circuit`, `init`, `clone`, `internal`, `nets`, `compact`, `code`
//! - `pub const sd`, `pub fn draw(arena, c) !Layout`
//! - `pub fn spice(arena, c) ![]const u8`, `spiceOrdered`, `spectre`, `edited`, `spiceHier`, `flatten`
//! - `Sci.format`: Rust's `{:e}`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Layout = harness.Layout;

/// The comparator's relative tolerance, `CompareOptions`'s documented
/// default.
pub const tolerance: f64 = 0.02;

/// `nmos` and `pmos` only: the deck of the enumeration. `nmos` excludes the
/// `hvt` implant, so the flavour row of `extra_deck` splits it (LVS-066).
pub const mos_deck =
    \\grid 1nm
    \\layer diff = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer nsdm = gds(3, 0)
    \\layer psdm = gds(4, 0)
    \\layer hvt = gds(5, 0)
    \\layer cont = gds(8, 0)
    \\layer met1 = gds(10, 0)
    \\layer via1 = gds(11, 0)
    \\layer met2 = gds(12, 0)
    \\layer met2_label = gds(12, 5)
    \\layer diff_active = diff not poly
    \\layer gate = poly and diff
    \\layer gate_n = gate and nsdm
    \\layer gate_nl = gate_n not hvt
    \\layer gate_p = gate and psdm
    \\connect conductors [diff_active, poly, met1, met2]
    \\connect touch_within_layer
    \\connect via cont [diff_active, met1]
    \\connect via cont [poly, met1]
    \\connect via via1 [met1, met2]
    \\connect label met2_label names met2
    \\device mos gate_nl model "nmos" terminals [poly, diff_active, diff_active]
    \\device mos gate_p model "pmos" terminals [poly, diff_active, diff_active]
    \\lvs tolerance default relative 2%
    \\
;

/// Every other device: the `hvt` flavour, a MOS with a bulk terminal on
/// `pwell`, and one passive or bipolar per kind, each a marker over pads.
/// The resistor states its sheet resistance and the capacitor its area and
/// fringe capacitance, so the layout's `r` and `c` follow (`measured`).
pub const extra_deck =
    \\layer bsdm = gds(6, 0)
    \\layer pwell = gds(7, 0)
    \\layer tap = gds(9, 0)
    \\layer pina = gds(13, 0)
    \\layer pinb = gds(14, 0)
    \\layer pinc = gds(15, 0)
    \\layer resm = gds(16, 0)
    \\layer capm = gds(17, 0)
    \\layer diom = gds(18, 0)
    \\layer bjtm = gds(19, 0)
    \\layer indm = gds(30, 0)
    \\layer gate_nh = gate_n and hvt
    \\layer gate_b = gate and bsdm
    \\connect conductors [pwell, pina, pinb, pinc]
    \\connect via cont [pina, met1]
    \\connect via cont [pinb, met1]
    \\connect via cont [pinc, met1]
    \\connect via tap [pwell, met1]
    \\device mos gate_nh model "nmos_hvt" terminals [poly, diff_active, diff_active]
    \\device mos gate_b model "nmosb" terminals [poly, diff_active, diff_active, pwell]
    \\device resistor resm model "rpoly" terminals [pina, pina] sheet 100ohm
    \\device capacitor capm model "cmim" terminals [pina, pinb] area_cap 1fF/um2 fringe_cap 100aF/um
    \\device diode diom model "dpn" terminals [pina, pinb]
    \\device bjt bjtm model "npn" terminals [pina, pinb, pinc]
    \\device inductor indm model "spiral" terminals [pina, pina] inductance 2nH
    \\
;

/// The deck of the curated fixtures.
pub const full_deck = mos_deck ++ extra_deck;

/// A device's kind and model in one: the deck has one recogniser per model.
pub const Model = enum(u8) {
    /// `nmos`: gate, source, drain.
    n,
    /// `pmos`.
    p,
    /// `nmos_hvt`, the `hvt` flavour of `nmos`.
    h,
    /// `nmosb`: gate, source, drain, bulk.
    b,
    /// `rpoly`: two interchangeable ends.
    r,
    /// `cmim`: plate 0, plate 1, ordered.
    c,
    /// `dpn`: anode, cathode, ordered.
    d,
    /// `npn`: base, emitter, collector, ordered.
    q,
    /// `spiral`: an inductor, two interchangeable ends.
    l,

    pub fn isMos(m: Model) bool {
        return switch (m) {
            .n, .p, .h, .b => true,
            .r, .c, .d, .q, .l => false,
        };
    }

    pub fn name(m: Model) []const u8 {
        return switch (m) {
            .n => "nmos",
            .p => "pmos",
            .h => "nmos_hvt",
            .b => "nmosb",
            .r => "rpoly",
            .c => "cmim",
            .d => "dpn",
            .q => "npn",
            .l => "spiral",
        };
    }

    /// The parameter a card's positional value states: a capacitor's `c`,
    /// an inductor's `ind`, anything else's `r`.
    pub fn primary(m: Model) []const u8 {
        return switch (m) {
            .c => "c",
            .l => "ind",
            .n, .p, .h, .b, .r, .d, .q => "r",
        };
    }

    /// One letter, for fixture names and the cards of two-pin devices.
    pub fn letter(m: Model) u8 {
        return switch (m) {
            .n => 'N',
            .p => 'P',
            .h => 'H',
            .b => 'B',
            .r => 'R',
            .c => 'C',
            .d => 'D',
            .q => 'Q',
            .l => 'L',
        };
    }
};

/// The marker area of every two-pin device, 800 x 400 nm, in nm².
pub const pin2_area: i64 = 800 * 400;

/// The marker area of a bipolar, 1600 x 400 nm, in nm².
pub const bjt_area: i64 = 1600 * 400;

/// A stated `name=value`, in SI.
pub const Prm = struct { name: []const u8, value: f64 };

/// One device on numbered nets, a value (copied freely).
pub const Dev = struct {
    model: Model,
    /// MOS: gate, source, drain, and bulk for `.b`; two-pin: the card's pin
    /// 0, pin 1; bipolar: base, emitter, collector.
    pins: [4]usize = .{ 0, 0, 0, 0 },
    npins: u8,
    /// Drawn or declared width and length in nm; MOS only.
    w: i64 = 0,
    l: i64 = 0,
    /// Whether the card writes `w` and `l`: a MOS card may leave either
    /// out, and is then sized by neither (testing-plan F83, F84).
    writes_w: bool = false,
    writes_l: bool = false,
    /// The card's `m`; 1 writes none.
    m: u32 = 1,
    /// An `area=` the card declares, in nm². The layout always has its
    /// marker's, and it is compared only where the reference declares one.
    area: ?i64 = null,
    /// A resistor's or capacitor's value, `r` or `c` in SI, written
    /// positionally between the nets and the model.
    value: ?f64 = null,
    /// Any other `name=value` the card states, in SI, each compared with
    /// what the layout measures (`measured`).
    params: [4]Prm = undefined,
    nparams: u8 = 0,

    /// A MOS of 1000 / 150 nm.
    pub fn mos(model: Model, g: usize, s: usize, d: usize) Dev {
        return .{ .model = model, .pins = .{ g, s, d, 0 }, .npins = 3, .w = 1000, .l = 150, .writes_w = true, .writes_l = true };
    }

    /// A resistor, capacitor, diode or bipolar on `pins`.
    pub fn onPins(model: Model, pins: []const usize) Dev {
        var d: Dev = .{ .model = model, .npins = @intCast(pins.len) };
        @memcpy(d.pins[0..pins.len], pins);
        return d;
    }

    pub fn sized(d: Dev, w: i64, l: i64) Dev {
        var out = d;
        out.w = w;
        out.l = l;
        return out;
    }

    /// The card writes `w` only where `w`, `l` only where `l`.
    pub fn writes(d: Dev, w: bool, l: bool) Dev {
        var out = d;
        out.writes_w = w;
        out.writes_l = l;
        return out;
    }

    pub fn bulk(d: Dev, net: usize) Dev {
        var out = d;
        out.pins[out.npins] = net;
        out.npins += 1;
        return out;
    }

    pub fn times(d: Dev, m: u32) Dev {
        var out = d;
        out.m = m;
        return out;
    }

    pub fn withArea(d: Dev, nm2: i64) Dev {
        var out = d;
        out.area = nm2;
        return out;
    }

    pub fn valued(d: Dev, si: f64) Dev {
        var out = d;
        out.value = si;
        return out;
    }

    pub fn param(d: Dev, name: []const u8, si: f64) Dev {
        var out = d;
        out.params[out.nparams] = .{ .name = name, .value = si };
        out.nparams += 1;
        return out;
    }

    pub fn pinsOf(d: *const Dev) []const usize {
        return d.pins[0..d.npins];
    }

    pub fn paramsOf(d: *const Dev) []const Prm {
        return d.params[0..d.nparams];
    }
};

/// Devices on nets `0..names.len`. A port is a labelled net in the layout
/// and a `.subckt` port in the reference.
pub const Circuit = struct {
    devs: []Dev,
    names: [][]const u8,
    ports: []bool,

    /// Nets `n0..`, every one a port.
    pub fn init(arena: Allocator, net_count: usize, devs: []const Dev) !Circuit {
        const names = try arena.alloc([]const u8, net_count);
        for (names, 0..) |*n, i| n.* = try std.fmt.allocPrint(arena, "n{d}", .{i});
        const ports = try arena.alloc(bool, net_count);
        @memset(ports, true);
        return .{ .devs = try arena.dupe(Dev, devs), .names = names, .ports = ports };
    }

    pub fn clone(c: Circuit, arena: Allocator) !Circuit {
        return .{ .devs = try arena.dupe(Dev, c.devs), .names = try arena.dupe([]const u8, c.names), .ports = try arena.dupe(bool, c.ports) };
    }

    /// The same circuit with `net` internal: unlabelled in the layout, not
    /// a port of the reference.
    pub fn internal(c: Circuit, arena: Allocator, net: usize) !Circuit {
        var out = try c.clone(arena);
        out.ports[net] = false;
        return out;
    }

    pub fn nets(c: *const Circuit) usize {
        return c.names.len;
    }

    /// Drops every net no device touches, renumbering the rest in order.
    pub fn compact(c: Circuit, arena: Allocator) !Circuit {
        var out = try c.clone(arena);
        const used = try arena.alloc(bool, c.nets());
        @memset(used, false);
        for (c.devs) |*d| for (d.pinsOf()) |p| {
            used[p] = true;
        };
        const map = try arena.alloc(usize, used.len);
        var names: std.ArrayList([]const u8) = .empty;
        var ports: std.ArrayList(bool) = .empty;
        for (used, 0..) |u, i| if (u) {
            map[i] = names.items.len;
            try names.append(arena, c.names[i]);
            try ports.append(arena, c.ports[i]);
        };
        for (out.devs) |*d| for (d.pins[0..d.npins]) |*p| {
            p.* = map[p.*];
        };
        out.names = names.items;
        out.ports = ports.items;
        return out;
    }

    /// A short code naming the circuit: `N0.1.2` per MOS (gate, source,
    /// drain), joined by `+`.
    pub fn code(c: *const Circuit, arena: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (c.devs, 0..) |*d, i| {
            if (i > 0) try out.append(arena, '+');
            try out.append(arena, d.model.letter());
            for (d.pinsOf(), 0..) |p, k| try out.print(arena, "{s}{d}", .{ if (k > 0) "." else "", p });
        }
        return out.items;
    }
};

/// Source and drain diffusion length.
pub const sd: i64 = 500;

/// Columns are this far apart; each device sits in its own.
const pitch: i64 = 3000;

/// The lowest met2 track; every device fits below it.
const track0: i64 = 4000;

/// Track spacing; tracks are 200 nm tall.
const track_pitch: i64 = 400;

/// A float as Rust's `{:e}` writes it: the shortest mantissa that reads
/// back, `e`, the exponent with no `+` and no padding (`2e2`, `1.5e-15`).
const Sci = struct {
    v: f64,

    pub fn format(s: Sci, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{e}", .{s.v}) catch unreachable;
        // Zig writes `2e2` / `1.5e-15` already; drop a `+` if one appears.
        for (text) |ch| if (ch != '+') try w.writeByte(ch);
    }
};

/// The layout of `c`: device `i` in column `i`, net `k` a met2 track,
/// labelled with its name when it is a port.
pub fn draw(arena: Allocator, c: *const Circuit) !Layout {
    var layout: Layout = .{};
    for (c.devs, 0..) |*dev, i| {
        if (dev.model.isMos()) try drawMos(arena, &layout, column(i), dev) else try drawPins(arena, &layout, column(i), dev);
    }
    const right = column(c.devs.len);
    for (0..c.nets()) |k| {
        const t = track(k);
        try layout.rect(arena, "met2", -1000, t, right, t + 200);
        if (c.ports[k]) try layout.label(arena, "met2_label", -900, t + 100, c.names[k]);
    }
    return layout;
}

/// `c` as one subcircuit `TOP`.
pub fn spice(arena: Allocator, c: *const Circuit) ![]const u8 {
    const order = try arena.alloc(usize, c.devs.len);
    for (order, 0..) |*o, i| o.* = i;
    return spiceOrdered(arena, c, order);
}

/// `spice` with the cards in `order`.
pub fn spiceOrdered(arena: Allocator, c: *const Circuit, order: []const usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "* generated by tests/exhaustive/lvs.rs\n");
    try subcktInto(arena, &out, "TOP", c, order);
    try out.appendSlice(arena, ".ends\n");
    return out.items;
}

/// `c` as one Spectre subcircuit `TOP`: `spice` in the reader's other
/// dialect (LVS-071). Every model gets a `model` card naming its master: a
/// primitive master with none is the deck's one recogniser of its kind
/// (F97), and the deck has four MOS.
pub fn spectre(arena: Allocator, c: *const Circuit) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "// generated by tests/exhaustive/lvs.rs\nmodel nmos bsim4\nmodel pmos bsim4\nmodel nmos_hvt bsim4\nmodel nmosb bsim4\nmodel rpoly resistor\nmodel cmim capacitor\nmodel dpn diode\nmodel npn bjt\nmodel spiral inductor\nsubckt TOP");
    for (c.names, c.ports) |net, p| if (p) try out.print(arena, " {s}", .{net});
    try out.append(arena, '\n');
    for (c.devs, 0..) |*dev, i| try cardInto(arena, &out, i, dev, c.names, true);
    try out.appendSlice(arena, "ends TOP\n");
    return out.items;
}

/// `text` with `from` replaced by `to`. A reference edit whose anchor is
/// gone would leave the fixture testing the unedited circuit, so it fails.
pub fn edited(arena: Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, from) == null) {
        std.debug.print("{s} is not in the reference:\n{s}\n", .{ from, text });
        return error.TestEditAnchorMissing;
    }
    return std.mem.replaceOwned(u8, arena, text, from, to);
}

/// `top` with one instance of `block`, whose ports land on `on` in order.
pub fn spiceHier(arena: Allocator, top: *const Circuit, block: *const Circuit, on: []const usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "* generated by tests/exhaustive/lvs.rs\n");
    const block_order = try arena.alloc(usize, block.devs.len);
    for (block_order, 0..) |*o, i| o.* = i;
    try subcktInto(arena, &out, "BLK", block, block_order);
    try out.appendSlice(arena, ".ends\n");
    const top_order = try arena.alloc(usize, top.devs.len);
    for (top_order, 0..) |*o, i| o.* = i;
    try subcktInto(arena, &out, "TOP", top, top_order);
    try out.appendSlice(arena, "X0");
    for (on) |net| try out.print(arena, " {s}", .{top.names[net]});
    try out.appendSlice(arena, " BLK\n.ends\n");
    return out.items;
}

/// What `spiceHier` means, flat: `block`'s devices in `top`, its ports on
/// `on`, its other nets new internal nets.
pub fn flatten(arena: Allocator, top: *const Circuit, block: *const Circuit, on: []const usize) !Circuit {
    var devs: std.ArrayList(Dev) = .empty;
    try devs.appendSlice(arena, top.devs);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(arena, top.names);
    var ports: std.ArrayList(bool) = .empty;
    try ports.appendSlice(arena, top.ports);
    const map = try arena.alloc(usize, block.nets());
    var next_port: usize = 0;
    for (map, 0..) |*m, k| {
        if (block.ports[k]) {
            m.* = on[next_port];
            next_port += 1;
        } else {
            try names.append(arena, try std.fmt.allocPrint(arena, "x0.{s}", .{block.names[k]}));
            try ports.append(arena, false);
            m.* = names.items.len - 1;
        }
    }
    for (block.devs) |dev| {
        var moved = dev;
        for (moved.pins[0..moved.npins]) |*p| p.* = map[p.*];
        try devs.append(arena, moved);
    }
    return .{ .devs = devs.items, .names = names.items, .ports = ports.items };
}

// ---- private ----

fn track(net: usize) i64 {
    return track0 + track_pitch * @as(i64, @intCast(net));
}

fn column(i: usize) i64 {
    return pitch * @as(i64, @intCast(i));
}

/// A met1 stub from `y0` up to `net`'s track over `x0..x1`, with the via
/// there.
fn stub(arena: Allocator, layout: *Layout, x0: i64, x1: i64, y0: i64, net: usize) !void {
    const t = track(net);
    try layout.rect(arena, "met1", x0, y0, x1, t + 200);
    try layout.rect(arena, "via1", x0, t, x1, t + 200);
}

/// Poly across diffusion: the channel is `l` along x and `w` along y, so
/// the recogniser measures exactly `w` and `l`. Source left, drain right,
/// each contacted near the bottom; the gate is contacted on the poly above
/// the diffusion.
fn drawMos(arena: Allocator, layout: *Layout, x0: i64, dev: *const Dev) !void {
    const w = dev.w;
    const l = dev.l;
    std.debug.assert(w >= 500 and w <= track0 - 1000); // a width the drawer fits
    const xd = x0 + sd + l;
    try layout.rect(arena, "diff", x0, 0, xd + sd, w);
    try layout.rect(arena, "poly", x0 + sd, -200, xd, w + 500);
    const implants: []const []const u8 = switch (dev.model) {
        .n => &.{"nsdm"},
        .h => &.{ "nsdm", "hvt" },
        .p => &.{"psdm"},
        .b => &.{"bsdm"},
        .r, .c, .d, .q, .l => unreachable, // not a MOS
    };
    for (implants) |layer| try layout.rect(arena, layer, x0 - 200, -300, xd + sd + 200, w + 200);
    if (dev.model == .b) {
        try layout.rect(arena, "pwell", x0 - 900, -400, xd + sd + 300, w + 300);
        try layout.rect(arena, "tap", x0 - 700, 100, x0 - 400, 400);
        try stub(arena, layout, x0 - 700, x0 - 400, 100, dev.pins[3]);
    }
    try layout.rect(arena, "cont", x0 + 100, 100, x0 + 400, 400);
    try layout.rect(arena, "cont", xd + 100, 100, xd + 400, 400);
    try layout.rect(arena, "cont", x0 + sd, w + 250, xd, w + 400);
    try stub(arena, layout, x0 + 100, x0 + 400, 100, dev.pins[1]);
    try stub(arena, layout, xd + 100, xd + 400, 100, dev.pins[2]);
    try stub(arena, layout, x0 + sd, xd, w + 250, dev.pins[0]);
}

/// A marker over one 400 nm pad per pin, 800 nm apart; pad `k` is on
/// `pina`, `pinb`, `pinc` by position, except a resistor's or inductor's,
/// which are both `pina`.
fn drawPins(arena: Allocator, layout: *Layout, x0: i64, dev: *const Dev) !void {
    const marker: []const u8, const layers: [3][]const u8 = switch (dev.model) {
        .r => .{ "resm", .{ "pina", "pina", "" } },
        .c => .{ "capm", .{ "pina", "pinb", "" } },
        .d => .{ "diom", .{ "pina", "pinb", "" } },
        .q => .{ "bjtm", .{ "pina", "pinb", "pinc" } },
        .l => .{ "indm", .{ "pina", "pina", "" } },
        .n, .p, .h, .b => unreachable, // a MOS
    };
    var right = x0;
    for (dev.pinsOf(), 0..) |net, k| {
        // The pad of pin `k`.
        const x = x0 + 800 * @as(i64, @intCast(k));
        try layout.rect(arena, layers[k], x, 0, x + 400, 400);
        try layout.rect(arena, "cont", x + 100, 100, x + 300, 300);
        try stub(arena, layout, x + 100, x + 300, 100, net);
        right = x;
    }
    try layout.rect(arena, marker, x0 + 200, 0, right + 200, 400);
}

/// One card, SPICE or (`spectre_`) Spectre, which differ here only in the
/// parentheses round the nets. A three-terminal MOS's bulk is written as
/// its source: the deck extracts no bulk for it, so the comparison drops it.
fn cardInto(arena: Allocator, out: *std.ArrayList(u8), index: usize, dev: *const Dev, names: []const []const u8, spectre_: bool) !void {
    const open = if (spectre_) "(" else "";
    const close = if (spectre_) ")" else "";
    const n = struct {
        fn at(d: *const Dev, all: []const []const u8, k: usize) []const u8 {
            return all[d.pins[k]];
        }
    }.at;
    switch (dev.model) {
        .n, .p, .h, .b => {
            const bulk_net = if (dev.model == .b) n(dev, names, 3) else n(dev, names, 1);
            try out.print(arena, "M{d} {s}{s} {s} {s} {s}{s} {s}", .{ index, open, n(dev, names, 2), n(dev, names, 0), n(dev, names, 1), bulk_net, close, dev.model.name() });
            if (dev.writes_w) try out.print(arena, " w={d}n", .{dev.w});
            if (dev.writes_l) try out.print(arena, " l={d}n", .{dev.l});
        },
        .r, .c, .d, .l => {
            try out.print(arena, "{c}{d} {s}{s} {s}{s}", .{ dev.model.letter(), index, open, n(dev, names, 0), n(dev, names, 1), close });
            if (dev.value) |v| {
                std.debug.assert(!spectre_); // Spectre has no positional value
                try out.print(arena, " {f}", .{Sci{ .v = v }});
            }
            try out.print(arena, " {s}", .{dev.model.name()});
        },
        .q => try out.print(arena, "Q{d} {s}{s} {s} {s}{s} npn", .{ index, open, n(dev, names, 2), n(dev, names, 0), n(dev, names, 1), close }),
    }
    if (dev.m != 1) try out.print(arena, " m={d}", .{dev.m});
    // nm² as µm², which SPICE writes with `p` (1e-12 m²).
    if (dev.area) |a| try out.print(arena, " area={d}p", .{@as(f64, @floatFromInt(a)) / 1e6});
    for (dev.paramsOf()) |p| try out.print(arena, " {s}={f}", .{ p.name, Sci{ .v = p.value } });
    try out.append(arena, '\n');
}

/// Subcircuit `name`'s `.subckt` line and cards; `c`'s port nets are its
/// ports.
fn subcktInto(arena: Allocator, out: *std.ArrayList(u8), name: []const u8, c: *const Circuit, order: []const usize) !void {
    try out.print(arena, ".subckt {s}", .{name});
    for (c.names, c.ports) |net, p| if (p) try out.print(arena, " {s}", .{net});
    try out.append(arena, '\n');
    for (order) |i| try cardInto(arena, out, i, &c.devs[i], c.names, false);
}

test "a card writes Rust's exponent form" {
    // Oracle: Rust's `{:e}` on f64: 200.0 is `2e2`, 0.56e-15 is `5.6e-16`,
    // 1e-12 is `1e-12` (the shortest round-trip mantissa).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { f64, []const u8 }{ .{ 200.0, "2e2" }, .{ 0.56e-15, "5.6e-16" }, .{ 1e-12, "1e-12" } }) |case| {
        try std.testing.expectEqualStrings(case[1], try std.fmt.allocPrint(a, "{f}", .{Sci{ .v = case[0] }}));
    }
}
