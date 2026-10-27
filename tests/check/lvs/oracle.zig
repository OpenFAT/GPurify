//! LVS's independent oracle: two small circuits match iff, after the documented
//! reductions (docs/src/reference/lvs/reduction.md), a bijection of devices and
//! nets preserves kind, model and terminal incidence up to the interchangeable
//! roles, every parameter within the 2 % relative tolerance and every count
//! equal (F99). A brute force over every net bijection, decided from the
//! documented semantics alone, never from the tool. Ported from
//! tests/exhaustive/lvs.rs (`Model`, `Dev`, `Circuit`, `Declared`, `reduce`,
//! `pairs`, `measured`, `assign`, `matches`, `equivalent`) under the default
//! deck controls only: the controlled fixtures that need the others wait for
//! the engine harness (wave 5).
//!
//! Contents:
//! - `pub const max_devs`, `pub const max_nets`, `pub const Prm`
//! - `pub const Model`: `isMos`, `name`, `primary`, `letter`
//! - `pub const Dev`: `mos`, `onPins`, `sized`, `writes`, `times`, `valued`, `param`, `pinsOf`
//! - `pub const Circuit`: `init`, `push`, `remove`, `devices`, `internal`, `compact`
//! - `pub fn equivalent(layout: *const Circuit, reference: *const Circuit) bool`

const std = @import("std");

pub const max_devs = 8;
pub const max_nets = 8;

/// A device's kind and model in one: the deck has one recogniser per model.
pub const Model = enum(u8) {
    /// `nmos`: gate, source, drain.
    n,
    /// `pmos`.
    p,
    /// `rpoly`: two interchangeable ends.
    r,
    /// `cmim`: plate 0, plate 1, ordered.
    c,
    /// `dpn`: anode, cathode, ordered.
    d,
    /// `npn`: base, emitter, collector, ordered.
    q,

    pub fn isMos(m: Model) bool {
        return m == .n or m == .p;
    }

    pub fn name(m: Model) []const u8 {
        return switch (m) {
            .n => "nmos",
            .p => "pmos",
            .r => "rpoly",
            .c => "cmim",
            .d => "dpn",
            .q => "npn",
        };
    }

    /// The parameter a card's positional value states.
    pub fn primary(m: Model) []const u8 {
        return switch (m) {
            .c => "c",
            .n, .p, .r, .d, .q => "r",
        };
    }

    pub fn letter(m: Model) u8 {
        return switch (m) {
            .n => 'N',
            .p => 'P',
            .r => 'R',
            .c => 'C',
            .d => 'D',
            .q => 'Q',
        };
    }
};

/// A stated `name=value`, in SI.
pub const Prm = struct { name: []const u8, value: f64 };

/// One device on numbered nets.
pub const Dev = struct {
    model: Model,
    /// MOS: gate, source, drain; two-pin: pin 0, pin 1; bipolar: base,
    /// emitter, collector.
    pins: [4]u8 = .{ 0, 0, 0, 0 },
    npins: u8,
    /// Drawn or declared width and length in nm; MOS only.
    w: i64 = 0,
    l: i64 = 0,
    /// Whether the card writes `w` and `l` (F83, F84).
    writes_w: bool = false,
    writes_l: bool = false,
    /// The card's `m`; 1 writes none.
    m: u32 = 1,
    /// An `area=` the card declares, in nm².
    area: ?i64 = null,
    /// A resistor's or capacitor's value, written positionally.
    value: ?f64 = null,
    params: [2]Prm = undefined,
    nparams: u8 = 0,

    /// A MOS of 1000 / 150 nm.
    pub fn mos(model: Model, g: u8, s: u8, d: u8) Dev {
        return .{ .model = model, .pins = .{ g, s, d, 0 }, .npins = 3, .w = 1000, .l = 150, .writes_w = true, .writes_l = true };
    }

    /// A resistor, capacitor, diode or bipolar on `pins`.
    pub fn onPins(model: Model, pins: []const u8) Dev {
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

    pub fn writes(d: Dev, w: bool, l: bool) Dev {
        var out = d;
        out.writes_w = w;
        out.writes_l = l;
        return out;
    }

    pub fn times(d: Dev, m: u32) Dev {
        var out = d;
        out.m = m;
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

    pub fn pinsOf(d: *const Dev) []const u8 {
        return d.pins[0..d.npins];
    }
};

/// Devices on nets `0..nets`, net `k` named `n{k}`. A port is a labelled
/// net in the layout and a `.subckt` port in the reference.
pub const Circuit = struct {
    devs: [max_devs]Dev = undefined,
    ndevs: u8 = 0,
    nets: u8,
    ports: [max_nets]bool = @splat(true),

    /// Nets `n0..`, every one a port.
    pub fn init(nets: u8, devs: []const Dev) Circuit {
        var c: Circuit = .{ .nets = nets };
        for (devs) |d| c.push(d);
        return c;
    }

    pub fn push(c: *Circuit, d: Dev) void {
        c.devs[c.ndevs] = d;
        c.ndevs += 1;
    }

    pub fn remove(c: *Circuit, at: usize) void {
        for (at..c.ndevs - 1) |i| c.devs[i] = c.devs[i + 1];
        c.ndevs -= 1;
    }

    pub fn devices(c: *const Circuit) []const Dev {
        return c.devs[0..c.ndevs];
    }

    /// The same circuit with `net` internal.
    pub fn internal(c: Circuit, net: u8) Circuit {
        var out = c;
        out.ports[net] = false;
        return out;
    }

    /// Drops every net no device touches, renumbering the rest in order.
    pub fn compact(c: Circuit) Circuit {
        var used: [max_nets]bool = @splat(false);
        for (c.devices()) |d| for (d.pinsOf()) |p| {
            used[p] = true;
        };
        var map: [max_nets]u8 = undefined;
        var out = c;
        var next: u8 = 0;
        for (0..c.nets) |k| if (used[k]) {
            map[k] = next;
            out.ports[next] = c.ports[k];
            next += 1;
        };
        out.nets = next;
        for (out.devs[0..out.ndevs]) |*d| for (d.pins[0..d.npins]) |*p| {
            p.* = map[p.*];
        };
        return out;
    }
};

/// `|a - b| <= tol·max(|a|, |b|)`, `CompareOptions`'s documented default.
const tolerance: f64 = 0.02;

/// The marker area of every two-pin device, 800 × 400 nm, in nm².
const pin2_area: i64 = 800 * 400;

/// The marker area of a bipolar, 1600 × 400 nm.
const bjt_area: i64 = 1600 * 400;

/// Source and drain diffusion length, the drawer's.
const sd_length: i64 = 500;

/// A MOS's diffusions, in the order a merge trades `as`/`ad`, `ps`/`pd`.
const diffusions = [4][]const u8{ "as", "ad", "ps", "pd" };

/// A device after reduction: `w`, `l` in nm where sized by them, summed by
/// merges, and its count of identical devices in parallel (F20, F21, F83).
const Reduced = struct {
    model: Model,
    pins: [4]u8,
    npins: u8,
    w: ?f64,
    l: ?f64,
    mult: u32,
    area: ?i64,
    value: ?f64,
    params: [2]Prm,
    nparams: u8,
    /// A MOS's diffusions in SI, where stated: drawn, or written.
    sd: [4]?f64,
};

/// A circuit reduced: its devices, the surviving nets, its net count, its
/// models sorted.
const Reduction = struct {
    devs: [max_devs]Reduced = undefined,
    ndevs: u8 = 0,
    live: [max_nets]u8 = undefined,
    nlive: u8 = 0,
    nets: u8,
    models: [max_devs]Model = undefined,
};

/// The parameter names a reference's cards state, per model (F22).
const Declared = struct {
    rows: [32]struct { Model, []const u8 } = undefined,
    n: usize = 0,

    fn of(reference: *const Circuit) Declared {
        var d: Declared = .{};
        for (reference.devices()) |dev| {
            if (dev.writes_w and dev.model.isMos()) d.add(dev.model, "w");
            if (dev.writes_l and dev.model.isMos()) d.add(dev.model, "l");
            if (dev.area != null) d.add(dev.model, "area");
            if (dev.value != null) d.add(dev.model, dev.model.primary());
            for (dev.params[0..dev.nparams]) |p| d.add(dev.model, p.name);
        }
        return d;
    }

    fn add(d: *Declared, model: Model, name: []const u8) void {
        if (d.has(model, name)) return;
        d.rows[d.n] = .{ model, name };
        d.n += 1;
    }

    fn has(d: *const Declared, model: Model, name: []const u8) bool {
        for (d.rows[0..d.n]) |r| if (r[0] == model and std.mem.eql(u8, r[1], name)) return true;
        return false;
    }
};

const identity: [max_nets]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };

/// The oracle: whether `layout` and `reference` are one circuit, by brute
/// force over every bijection of their reduced nets.
pub fn equivalent(layout: *const Circuit, reference: *const Circuit) bool {
    const declared = Declared.of(reference);
    const a = reduce(layout, &declared, true);
    const b = reduce(reference, &declared, false);
    return matches(&a, &b);
}

// ---- private ----

fn close(a: f64, b: f64) bool {
    return @abs(a - b) <= tolerance * @max(@abs(a), @abs(b));
}

fn eqlOpt(a: ?f64, b: ?f64) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

/// What the layout measures on a drawn MOS's diffusion `i`, in SI: the
/// drawer's source and drain, each 500 by `w` nm.
fn drawnDiffusion(i: usize, w: i64) f64 {
    return if (i < 2) @as(f64, @floatFromInt(sd_length * w)) * 1e-18 else @as(f64, @floatFromInt(2 * (sd_length + w))) * 1e-9;
}

/// Whether `b`'s source is on `a`'s drain net, `a`'s nets read through
/// `map`; a MOS whose source and drain share a net is never crossed.
fn crossed(a: *const Reduced, b: *const Reduced, map: []const u8) bool {
    return a.model.isMos() and a.pins[1] != a.pins[2] and map[a.pins[2]] == b.pins[1];
}

/// The default classes of interchangeable pin positions
/// (docs/src/reference/deck/lvs-controls.md, Interchangeable pins): a MOS's
/// source and drain, a resistor's ends; every other pin alone.
fn classOf(model: Model, position: usize) u8 {
    return switch (model) {
        .n, .p => if (position == 2) 1 else @intCast(position),
        .r => if (position == 1) 0 else @intCast(position),
        .c, .d, .q => @intCast(position),
    };
}

/// Two devices of `model` on the same nets role for role, up to exchanging
/// the pins of one class; `a`'s nets read through `map`.
fn samePins(model: Model, a: []const u8, b: []const u8, map: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..4) |class| {
        var na: [4]u8 = undefined;
        var nb: [4]u8 = undefined;
        var k: usize = 0;
        for (0..a.len) |p| if (classOf(model, p) == class) {
            na[k] = map[a[p]];
            nb[k] = b[p];
            k += 1;
        };
        std.mem.sortUnstable(u8, na[0..k], {}, std.sort.asc(u8));
        std.mem.sortUnstable(u8, nb[0..k], {}, std.sort.asc(u8));
        if (!std.mem.eql(u8, na[0..k], nb[0..k])) return false;
    }
    return true;
}

/// The documented reductions to a fixed point, parallel first. A MOS is
/// sized by `w` and `l` where its card writes them, or, `drawn`, where some
/// reference card of its model does. Multiplier: a MOS's `m` multiplies its
/// `W`; any other `m` is that many in parallel. Parallel: devices of one
/// model on the same nets role for role become one, summing `W` (and the
/// diffusions end by end) or their count. Series (MOS only): two stating
/// `L`, gates on one net, equal `W` and count, channels meeting at a net no
/// port and no other terminal touches, become one with `L` summed. A net
/// survives as a port or under a terminal.
fn reduce(c: *const Circuit, declared: *const Declared, drawn: bool) Reduction {
    var out: Reduction = .{ .nets = c.nets };
    for (c.devices()) |d| {
        const stated_w = if (drawn) declared.has(d.model, "w") else d.writes_w;
        const stated_l = if (drawn) declared.has(d.model, "l") else d.writes_l;
        var w: ?f64 = if (d.model.isMos() and stated_w) @floatFromInt(d.w) else null;
        const l: ?f64 = if (d.model.isMos() and stated_l) @floatFromInt(d.l) else null;
        // A drawn device is one device; only a card counts more.
        const m: u32 = if (drawn) 1 else d.m;
        var sd: [4]?f64 = @splat(null);
        var r: Reduced = .{ .model = d.model, .pins = d.pins, .npins = d.npins, .w = null, .l = l, .mult = m, .area = d.area, .value = d.value, .params = undefined, .nparams = 0, .sd = undefined };
        for (d.params[0..d.nparams]) |p| {
            const is_diffusion = for (diffusions) |n| (if (std.mem.eql(u8, n, p.name)) break true) else false;
            if (d.model.isMos() and is_diffusion) continue;
            r.params[r.nparams] = p;
            r.nparams += 1;
        }
        if (d.model.isMos()) for (diffusions, 0..) |name, i| {
            sd[i] = if (drawn)
                (if (declared.has(d.model, name)) drawnDiffusion(i, d.w) else null)
            else for (d.params[0..d.nparams]) |p| (if (std.mem.eql(u8, p.name, name)) break p.value) else null;
        };
        // `m` folds into `W` and the diffusions where there is a `W`.
        if (w) |width| {
            for (&sd) |*v| if (v.*) |x| {
                v.* = x * @as(f64, @floatFromInt(m));
            };
            w = width * @as(f64, @floatFromInt(m));
            r.mult = 1;
        }
        r.w = w;
        r.sd = sd;
        out.devs[out.ndevs] = r;
        out.ndevs += 1;
    }
    var alive: [max_nets]bool = @splat(true);
    pass: while (true) {
        for (0..out.ndevs) |i| for (i + 1..out.ndevs) |j| {
            const a = &out.devs[i];
            const b = &out.devs[j];
            var stated: usize = 0;
            for (a.sd) |v| stated += @intFromBool(v != null);
            const same_presence = for (a.sd, b.sd) |x, y| (if ((x == null) != (y == null)) break false) else true;
            const same_values = for (a.sd, b.sd) |x, y| (if (!eqlOpt(x, y)) break false) else true;
            const diffusions_ok = if (a.w != null) same_presence and (stated == 0 or stated == 4) else same_values;
            const params_ok = eqlOpt(a.l, b.l) and (a.w != null) == (b.w != null) and diffusions_ok and
                std.meta.eql(a.area, b.area) and eqlOpt(a.value, b.value) and sameParams(a, b);
            if (a.model == b.model and params_ok and samePins(a.model, a.pins[0..a.npins], b.pins[0..b.npins], &identity)) {
                const across: usize = @intFromBool(crossed(a, b, &identity));
                const merged = b.*;
                if (a.w != null and merged.w != null) {
                    a.w = a.w.? + merged.w.?;
                    for (0..4) |k| a.sd[k] = if (a.sd[k] != null and merged.sd[k ^ across] != null) a.sd[k].? + merged.sd[k ^ across].? else null;
                } else a.mult += merged.mult;
                removeReduced(&out, j);
                continue :pass;
            }
        };
        for (0..out.ndevs) |i| for (0..out.ndevs) |j| {
            if (i == j) continue;
            const a = &out.devs[i];
            const b = &out.devs[j];
            const mergeable = a.model.isMos() and a.model == b.model and a.pins[0] == b.pins[0] and
                std.mem.eql(u8, a.pins[3..a.npins], b.pins[3..b.npins]) and a.l != null and b.l != null and
                allNull(a.sd) and allNull(b.sd) and eqlOpt(a.w, b.w) and a.mult == b.mult;
            if (!mergeable) continue;
            for (1..3) |ea| for (1..3) |eb| {
                const x = a.pins[ea];
                if (x == b.pins[eb] and !c.ports[x] and touches(&out, x) == 2) {
                    const far_a = a.pins[3 - ea];
                    const far_b = b.pins[3 - eb];
                    a.pins[1] = far_a;
                    a.pins[2] = far_b;
                    a.l = a.l.? + b.l.?;
                    removeReduced(&out, j);
                    alive[x] = false;
                    continue :pass;
                }
            };
        };
        break;
    }
    for (0..c.nets) |k| {
        var held = c.ports[k];
        for (out.devs[0..out.ndevs]) |d| held = held or std.mem.indexOfScalar(u8, d.pins[0..d.npins], @intCast(k)) != null;
        if (alive[k] and held) {
            out.live[out.nlive] = @intCast(k);
            out.nlive += 1;
        }
    }
    for (out.devs[0..out.ndevs], 0..) |d, i| out.models[i] = d.model;
    std.mem.sortUnstable(Model, out.models[0..out.ndevs], {}, struct {
        fn less(_: void, x: Model, y: Model) bool {
            return @backingInt(x) < @backingInt(y);
        }
    }.less);
    return out;
}

fn allNull(sd: [4]?f64) bool {
    for (sd) |v| if (v != null) return false;
    return true;
}

fn sameParams(a: *const Reduced, b: *const Reduced) bool {
    if (a.nparams != b.nparams) return false;
    for (a.params[0..a.nparams], b.params[0..b.nparams]) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or x.value != y.value) return false;
    }
    return true;
}

fn removeReduced(r: *Reduction, at: usize) void {
    for (at..r.ndevs - 1) |i| r.devs[i] = r.devs[i + 1];
    r.ndevs -= 1;
}

fn touches(r: *const Reduction, net: u8) usize {
    var n: usize = 0;
    for (r.devs[0..r.ndevs]) |d| for (d.pins[0..d.npins]) |p| {
        n += @intFromBool(p == net);
    };
    return n;
}

/// What the layout measures on a drawn passive or bipolar, in SI: the
/// marker's `area` and `perim` (800, or 1600 for a bipolar, by 400 nm); a
/// resistor's `l` 800, `w` 400 nm and `r` = 100 Ω/□ × 800/400 = 200 Ω; a
/// capacitor's `c` = 1 fF/µm² × 0.32 µm² + 0.1 fF/µm × 2.4 µm = 0.56 fF; a
/// bipolar's emitter, its middle pad, `ae` 0.16 µm², `pe` 1.6 µm.
fn measured(model: Model, name: []const u8) ?f64 {
    const along: f64 = if (model == .q) 1600e-9 else 800e-9;
    const across: f64 = 400e-9;
    const area = along * across;
    const perim = 2.0 * (along + across);
    if (std.mem.eql(u8, name, "area")) return area;
    if (std.mem.eql(u8, name, "perim")) return perim;
    return switch (model) {
        .r => if (std.mem.eql(u8, name, "l")) along else if (std.mem.eql(u8, name, "w")) across else if (std.mem.eql(u8, name, "r")) 100.0 * along / across else null,
        .c => if (std.mem.eql(u8, name, "c")) 1e-3 * area + 1e-10 * perim else null,
        .q => if (std.mem.eql(u8, name, "ae")) 400e-9 * 400e-9 else if (std.mem.eql(u8, name, "pe")) 1600e-9 else null,
        .n, .p, .d => null,
    };
}

/// Whether layout device `a`, its nets renamed by `map`, is reference
/// device `b`. An area is compared only where the reference declares one.
fn pairs(a: *const Reduced, b: *const Reduced, map: []const u8) bool {
    if (a.model != b.model or a.mult != b.mult) return false;
    if (!samePins(a.model, a.pins[0..a.npins], b.pins[0..b.npins], map)) return false;
    const drawn_area: i64 = if (a.model == .q) bjt_area else pin2_area;
    if (b.area) |declared| {
        if (!close(@floatFromInt(a.area orelse drawn_area), @floatFromInt(declared))) return false;
    }
    // Every other value the card states, against what was drawn.
    for (b.params[0..b.nparams]) |p| {
        const d = measured(b.model, p.name) orelse return false;
        if (!close(d, p.value)) return false;
    }
    if (b.value) |v| {
        const d = measured(b.model, b.model.primary()) orelse return false;
        if (!close(d, v)) return false;
    }
    const across: usize = @intFromBool(crossed(a, b, map));
    if (!sizeAgrees(a.w, b.w) or !sizeAgrees(a.l, b.l)) return false;
    for (0..4) |k| if (!sizeAgrees(a.sd[k ^ across], b.sd[k])) return false;
    return true;
}

/// A size the card writes against the layout's: compared where written.
fn sizeAgrees(a: ?f64, b: ?f64) bool {
    const want = b orelse return true;
    const got = a orelse return false;
    return close(got, want);
}

/// Whether some assignment pairs each of `a[from..]` with a distinct unused
/// device of `b`.
fn assign(a: []const Reduced, b: []const Reduced, map: []const u8, used: []bool, from: usize) bool {
    if (from == a.len) return true;
    for (b, 0..) |*dev, j| {
        if (used[j] or !pairs(&a[from], dev, map)) continue;
        used[j] = true;
        if (assign(a, b, map, used, from + 1)) return true;
        used[j] = false;
    }
    return false;
}

/// Whether some bijection of `a`'s surviving nets onto `b`'s pairs every
/// device.
fn matches(a: *const Reduction, b: *const Reduction) bool {
    if (a.nlive != b.nlive or a.ndevs != b.ndevs) return false;
    if (!std.mem.eql(Model, a.models[0..a.ndevs], b.models[0..b.ndevs])) return false;
    var map: [max_nets]u8 = @splat(0xff);
    var taken: [max_nets]bool = @splat(false);
    return bijection(a, b, &map, &taken, 0);
}

fn bijection(a: *const Reduction, b: *const Reduction, map: *[max_nets]u8, taken: *[max_nets]bool, at: usize) bool {
    if (at == a.nlive) {
        var used: [max_devs]bool = @splat(false);
        return assign(a.devs[0..a.ndevs], b.devs[0..b.ndevs], map, used[0..b.ndevs], 0);
    }
    for (0..b.nlive) |t| {
        if (taken[t]) continue;
        taken[t] = true;
        map[a.live[at]] = b.live[t];
        if (bijection(a, b, map, taken, at + 1)) return true;
        taken[t] = false;
    }
    return false;
}

test "the oracle agrees with hand derivations" {
    // Oracle: hand-derived from the documented semantics, case by case:
    // source and drain swap and device order are free, a short is not, W
    // within 2 % matches, parallel devices add width and series ones
    // length, a diode is ordered and a resistor not, two capacitors are one
    // of m = 2, a value is compared against what the layout measures.
    // (Rust's last assertion, on the hierarchy writer's `flatten`, moves
    // with the hierarchy fixtures to the engine harness.)
    const N = Model.n;
    const P = Model.p;
    const inv = Circuit.init(4, &.{ Dev.mos(N, 0, 1, 2), Dev.mos(P, 0, 3, 2) });
    try std.testing.expect(equivalent(&inv, &inv));
    var swapped = inv;
    std.mem.swap(u8, &swapped.devs[0].pins[1], &swapped.devs[0].pins[2]);
    try std.testing.expect(equivalent(&inv, &swapped));
    const reversed = Circuit.init(4, &.{ inv.devs[1], inv.devs[0] });
    try std.testing.expect(equivalent(&inv, &reversed));
    var short = inv;
    short.devs[1].pins[1] = 1;
    const short_c = short.compact();
    try std.testing.expect(!equivalent(&inv, &short_c));
    var wide = inv;
    wide.devs[0].w = 1021;
    try std.testing.expect(!equivalent(&inv, &wide));
    wide.devs[0].w = 1019;
    try std.testing.expect(equivalent(&inv, &wide));
    const two = Circuit.init(3, &.{ Dev.mos(N, 0, 1, 2), Dev.mos(N, 0, 2, 1) });
    const one = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).sized(2000, 150)});
    try std.testing.expect(equivalent(&two, &one));
    const stack = Circuit.init(4, &.{ Dev.mos(N, 0, 1, 3), Dev.mos(N, 0, 3, 2) });
    const long = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).sized(1000, 300)});
    try std.testing.expect(!equivalent(&stack, &long));
    const inner = stack.internal(3);
    try std.testing.expect(equivalent(&inner, &long));
    const polar = struct {
        fn f(m: Model, a: u8, b: u8) Circuit {
            return Circuit.init(4, &.{ Dev.onPins(m, &.{ a, b }), Dev.mos(N, 0, 2, 3) });
        }
    }.f;
    try std.testing.expect(!equivalent(&polar(.d, 0, 1), &polar(.d, 1, 0)));
    try std.testing.expect(equivalent(&polar(.r, 0, 1), &polar(.r, 1, 0)));
    const caps = Circuit.init(2, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 0, 1 }) });
    const cap = Circuit.init(2, &.{Dev.onPins(.c, &.{ 0, 1 })});
    try std.testing.expect(!equivalent(&caps, &cap));
    const m2 = Circuit.init(2, &.{Dev.onPins(.c, &.{ 0, 1 }).times(2)});
    try std.testing.expect(equivalent(&caps, &m2));
    const pairs4 = Circuit.init(4, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 2, 3 }), Dev.onPins(.c, &.{ 2, 3 }) });
    const bare_and_m2 = Circuit.init(4, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 2, 3 }).times(2) });
    try std.testing.expect(!equivalent(&pairs4, &bare_and_m2));
    const bare = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).writes(false, false)});
    try std.testing.expect(!equivalent(&two, &bare));
    const bare2 = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).writes(false, false).times(2)});
    try std.testing.expect(equivalent(&two, &bare2));
    const w_only = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).sized(2000, 150).writes(true, false)});
    try std.testing.expect(equivalent(&two, &w_only));
    const l_only = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).sized(2000, 150).writes(false, true)});
    try std.testing.expect(!equivalent(&two, &l_only));
    const l_stack = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).sized(1000, 300).writes(false, true)});
    try std.testing.expect(equivalent(&inner, &l_stack));
    const w_stack = Circuit.init(3, &.{Dev.mos(N, 0, 1, 2).sized(1000, 300).writes(true, false)});
    try std.testing.expect(!equivalent(&inner, &w_stack));
    const res = Circuit.init(2, &.{Dev.onPins(.r, &.{ 0, 1 })});
    try std.testing.expect(equivalent(&res, &Circuit.init(2, &.{Dev.onPins(.r, &.{ 0, 1 }).valued(200.0)})));
    try std.testing.expect(!equivalent(&res, &Circuit.init(2, &.{Dev.onPins(.r, &.{ 0, 1 }).valued(210.0)})));
    try std.testing.expect(equivalent(&cap, &Circuit.init(2, &.{Dev.onPins(.c, &.{ 0, 1 }).valued(5.6e-16)})));
    try std.testing.expect(!equivalent(&cap, &Circuit.init(2, &.{Dev.onPins(.c, &.{ 0, 1 }).valued(3.2e-16)})));
    const diode = Circuit.init(2, &.{Dev.onPins(.d, &.{ 0, 1 })});
    try std.testing.expect(equivalent(&diode, &Circuit.init(2, &.{Dev.onPins(.d, &.{ 0, 1 }).param("perim", 2.4e-6)})));
    try std.testing.expect(!equivalent(&diode, &Circuit.init(2, &.{Dev.onPins(.d, &.{ 0, 1 }).param("perim", 2.64e-6)})));
}
