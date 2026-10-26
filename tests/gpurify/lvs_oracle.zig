//! LVS's independent oracle under the deck's `lvs` controls: two small
//! circuits match iff, after the documented reductions (docs/usage.md,
//! "LVS reduction"), a bijection of devices and nets preserves kind, model
//! and terminal incidence up to the interchangeable roles, every parameter
//! within its tolerance and every count equal (F99). Net names never take
//! part, and neither does card order. A brute force over every net
//! bijection, decided from the documented semantics alone, never from the
//! tool. Ported from tests/exhaustive/lvs.rs (`Reduced`, `Declared`,
//! `reduce`, `same_pins`, `crossed`, `pairs`, `assign`, `equivalent`,
//! `equivalent_under`, `gate_reassignments`, `matches`).
//!
//! Contents:
//! - `pub fn equivalent(arena: Allocator, layout: *const Circuit, reference: *const Circuit) !bool`
//! - `pub fn equivalentUnder(arena: Allocator, layout: *const Circuit, reference: *const Circuit, controls: *const Controls) !bool`
//! - `pub fn gateReassignmentsInto(arena: Allocator, c: *const Circuit, out: *std.ArrayList(Circuit)) !void`
//! - `pub fn reducedCount(arena: Allocator, c: *const Circuit) !usize`

const std = @import("std");
const Allocator = std.mem.Allocator;
const circuit = @import("lvs_circuit.zig");
const Model = circuit.Model;
const Dev = circuit.Dev;
const Prm = circuit.Prm;
const Circuit = circuit.Circuit;
const controls_ = @import("lvs_controls.zig");
const Controls = controls_.Controls;
const measured = controls_.measured;

/// A MOS's source and drain diffusion area and perimeter, in the order a
/// merge or a swapped card trades `as` with `ad` and `ps` with `pd` (F16).
const diffusions = [4][]const u8{ "as", "ad", "ps", "pd" };

/// A device after reduction: `w`, `l` in nm where it is sized by them,
/// summed by merges, and how many identical devices in parallel it stands
/// for, which is how a device with no width to sum keeps its count (F20,
/// F21, F83).
const Reduced = struct {
    model: Model,
    pins: [4]usize,
    npins: u8,
    w: ?f64,
    l: ?f64,
    mult: u32,
    area: ?i64,
    value: ?f64,
    params: [4]Prm,
    nparams: u8,
    /// A MOS's `diffusions` in SI, where stated: drawn, or written.
    sd: [4]?f64,

    fn pinsOf(r: *const Reduced) []const usize {
        return r.pins[0..r.npins];
    }

    fn paramsOf(r: *const Reduced) []const Prm {
        return r.params[0..r.nparams];
    }
};

/// A circuit reduced: its devices, the nets that survive, how many nets it
/// had, and its devices' models sorted, the cheapest test there is; and
/// its nets' names and which are ports (labelled, in a layout).
const Reduction = struct {
    devs: []const Reduced,
    live: []const usize,
    nets: usize,
    models: []const Model,
    names: []const []const u8,
    ports: []const bool,
};

/// The parameter names a reference's cards state, per model: what the
/// layout is measured on, since a measure no card of the model declares is
/// dropped before reduction (F22).
const Declared = struct {
    rows: std.ArrayList(struct { Model, []const u8 }) = .empty,

    fn of(arena: Allocator, reference: *const Circuit) !Declared {
        var d: Declared = .{};
        for (reference.devs) |*dev| {
            if (dev.model.isMos()) {
                if (dev.writes_w) try d.rows.append(arena, .{ dev.model, "w" });
                if (dev.writes_l) try d.rows.append(arena, .{ dev.model, "l" });
            }
            if (dev.area != null) try d.rows.append(arena, .{ dev.model, "area" });
            if (dev.value != null) try d.rows.append(arena, .{ dev.model, dev.model.primary() });
            for (dev.paramsOf()) |p| try d.rows.append(arena, .{ dev.model, p.name });
        }
        return d;
    }

    fn has(d: *const Declared, model: Model, name: []const u8) bool {
        for (d.rows.items) |row| if (row[0] == model and std.mem.eql(u8, row[1], name)) return true;
        return false;
    }
};

/// The oracle: whether `layout` and `reference` are one circuit, by brute
/// force over every bijection of their reduced nets.
pub fn equivalent(arena: Allocator, layout: *const Circuit, reference: *const Circuit) !bool {
    return equivalentUnder(arena, layout, reference, &.{});
}

/// `equivalent` under the deck's `lvs` statements.
pub fn equivalentUnder(arena: Allocator, layout: *const Circuit, reference: *const Circuit, controls: *const Controls) !bool {
    if (controls.gates) {
        // deck.md's `lvs recognize_gates`: the inputs of a stack or a
        // parallel group swap freely, so the circuits match when some
        // reassignment of each group's gates among its members matches
        // without the control. A brute force over every reassignment.
        var plain = controls.*;
        plain.gates = false;
        var variants: std.ArrayList(Circuit) = .empty;
        try gateReassignmentsInto(arena, layout, &variants);
        for (variants.items) |*v| if (try equivalentUnder(arena, v, reference, &plain)) return true;
        return false;
    }
    const stripped = try controls.strip(arena, reference);
    const declared = try Declared.of(arena, &stripped);
    const kept_layout = try controls.kept(arena, layout, true);
    const kept_reference = try controls.kept(arena, &stripped, false);
    return matches(arena, &try reduce(arena, &kept_layout, &declared, true, controls), &try reduce(arena, &kept_reference, &declared, false, controls), controls);
}

/// `c` with the gates of each group deck.md's `lvs recognize_gates` names
/// reassigned among its members, every way: groups of MOS of one model and
/// one size and count, each on a gate of its own, either on one source and
/// drain pair (parallel) or chained through nets that are no port and that
/// only the two neighbours' channel ends touch (series). The first is `c`
/// itself. Small circuits only: every reassignment of every group.
pub fn gateReassignmentsInto(arena: Allocator, c: *const Circuit, out: *std.ArrayList(Circuit)) !void {
    const n = c.devs.len;
    // Union of devices joined in parallel or in series.
    const group = try arena.alloc(usize, n);
    for (group, 0..) |*g, i| g.* = i;
    for (0..n) |i| for (i + 1..n) |j| {
        const a = &c.devs[i];
        const b = &c.devs[j];
        if (!sameGroup(a, b) or a.pins[0] == b.pins[0]) continue;
        const parallel = @min(a.pins[1], a.pins[2]) == @min(b.pins[1], b.pins[2]) and @max(a.pins[1], a.pins[2]) == @max(b.pins[1], b.pins[2]);
        var series_ = false;
        for ([_]usize{ 1, 2 }) |ea| for ([_]usize{ 1, 2 }) |eb| {
            const x = a.pins[ea];
            if (x == b.pins[eb] and !c.ports[x] and touchesDevs(c.devs, x) == 2) series_ = true;
        };
        if (parallel or series_) {
            const ra = root(group, i);
            const rb = root(group, j);
            group[@max(ra, rb)] = @min(ra, rb);
        }
    };
    var variants: std.ArrayList(Circuit) = .empty;
    try variants.append(arena, try c.clone(arena));
    for (0..n) |head| {
        var members: std.ArrayList(usize) = .empty;
        for (0..n) |d| if (root(group, d) == head) try members.append(arena, d);
        if (members.items.len < 2) continue;
        const gates = try arena.alloc(usize, members.items.len);
        for (members.items, gates) |d, *g| g.* = c.devs[d].pins[0];
        var next: std.ArrayList(Circuit) = .empty;
        const perms = try permutations(arena, members.items.len);
        for (variants.items) |variant| for (perms) |perm| {
            var v = try variant.clone(arena);
            for (members.items, 0..) |d, k| v.devs[d].pins[0] = gates[perm[k]];
            try next.append(arena, v);
        };
        variants = next;
    }
    try out.appendSlice(arena, variants.items);
}

/// How many devices `c`'s own cards reduce to under the default
/// controls (`reduce(c, Declared::of(c), false, default)` in Rust).
pub fn reducedCount(arena: Allocator, c: *const Circuit) !usize {
    const declared = try Declared.of(arena, c);
    return (try reduce(arena, c, &declared, false, &.{})).devs.len;
}

// ---- private ----

/// Two devices of one recognise-gates group: MOS of one model, size,
/// writes and count, no parameters, the same bulk.
fn sameGroup(a: *const Dev, b: *const Dev) bool {
    const bulk_a: ?usize = if (a.npins > 3) a.pins[3] else null;
    const bulk_b: ?usize = if (b.npins > 3) b.pins[3] else null;
    return a.model.isMos() and a.model == b.model and a.w == b.w and a.l == b.l and a.writes_w == b.writes_w and a.writes_l == b.writes_l and a.m == b.m and a.nparams == 0 and b.nparams == 0 and bulk_a == bulk_b;
}

fn root(group: []const usize, from: usize) usize {
    var at = from;
    while (group[at] != at) at = group[at];
    return at;
}

fn touchesDevs(devs: []const Dev, net: usize) usize {
    var n: usize = 0;
    for (devs) |*d| for (d.pinsOf()) |p| {
        if (p == net) n += 1;
    };
    return n;
}

fn touches(devs: []const Reduced, net: usize) usize {
    var n: usize = 0;
    for (devs) |*d| for (d.pinsOf()) |p| {
        if (p == net) n += 1;
    };
    return n;
}

/// Every permutation of `0..n`, `n` at most 7.
fn permutations(arena: Allocator, n: usize) ![]const []const usize {
    std.debug.assert(n <= 7);
    var all: std.ArrayList([]const usize) = .empty;
    try all.append(arena, &.{});
    for (1..n + 1) |k| {
        var next: std.ArrayList([]const usize) = .empty;
        for (all.items) |rest| for (0..k) |at| {
            const p = try arena.alloc(usize, k);
            @memcpy(p[0..at], rest[0..at]);
            p[at] = k - 1;
            @memcpy(p[at + 1 ..], rest[at..]);
            try next.append(arena, p);
        };
        all = next;
    }
    return all.items;
}

/// What the layout measures on a drawn MOS's diffusion `diffusions[i]`,
/// in SI: the drawer's source and drain, each `sd` by `w` nm, of area
/// `sd · w` and perimeter `2 (sd + w)`. Each device has a column of its
/// own, so no diffusion is shared.
fn drawnDiffusion(i: usize, w: i64) f64 {
    return if (i < 2) @as(f64, @floatFromInt(circuit.sd * w)) * 1e-18 else @as(f64, @floatFromInt(2 * (circuit.sd + w))) * 1e-9;
}

/// Whether `b`'s source is on `a`'s drain net, `a`'s nets read through
/// `map` (null: as they are): `b`'s `as` is then `a`'s `ad`, and so on. A
/// MOS whose source and drain share a net is never crossed.
fn crossed(a: *const Reduced, b: *const Reduced, map: ?[]const usize) bool {
    return a.model.isMos() and a.pins[1] != a.pins[2] and read(map, a.pins[2]) == b.pins[1];
}

fn read(map: ?[]const usize, net: usize) usize {
    return if (map) |m| m[net] else net;
}

/// Whether two devices of `model` land on the same nets role for role, up
/// to exchanging the pins of one `Controls.classes` class: by default a
/// MOS's source and drain either way round and a resistor's ends either
/// way, everything else in order. `a`'s nets are read through `map`.
fn samePins(model: Model, a: []const usize, b: []const usize, map: ?[]const usize, controls: *const Controls) bool {
    if (a.len != b.len) return false;
    const class = controls.classes(model);
    for (0..4) |head| {
        if (class[head] != head) continue;
        var on_a: [4]usize = undefined;
        var on_b: [4]usize = undefined;
        var n: usize = 0;
        for (0..4) |k| if (class[k] == head and k < a.len) {
            on_a[n] = read(map, a[k]);
            on_b[n] = b[k];
            n += 1;
        };
        std.mem.sort(usize, on_a[0..n], {}, std.sort.asc(usize));
        std.mem.sort(usize, on_b[0..n], {}, std.sort.asc(usize));
        if (!std.mem.eql(usize, on_a[0..n], on_b[0..n])) return false;
    }
    return true;
}

fn eqlParams(a: []const Prm, b: []const Prm) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.name, y.name) or x.value != y.value) return false;
    return true;
}

fn eqlSd(a: [4]?f64, b: [4]?f64) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// One device as reduction starts it: sized where it is (by its card, or,
/// `drawn`, where some reference card of its model declares the size), its
/// `m` folded into `W` and the diffusions where there is a `W`, else kept
/// as a count, and, relaxed, a resistor's or capacitor's value folded too.
fn start(d: *const Dev, declared: *const Declared, drawn: bool, controls: *const Controls) Reduced {
    const stated_w = if (drawn) declared.has(d.model, "w") else d.writes_w;
    const stated_l = if (drawn) declared.has(d.model, "l") else d.writes_l;
    var w: ?f64 = if (d.model.isMos() and stated_w) @floatFromInt(d.w) else null;
    const l: ?f64 = if (d.model.isMos() and stated_l) @floatFromInt(d.l) else null;
    // A drawn device is one device; only a card counts more.
    const m: u32 = if (drawn) 1 else d.m;
    var sd: [4]?f64 = @splat(null);
    var params: [4]Prm = undefined;
    var nparams: u8 = 0;
    for (d.paramsOf()) |p| {
        const is_diffusion = d.model.isMos() and for (diffusions) |name| (if (std.mem.eql(u8, name, p.name)) break true) else false;
        if (is_diffusion) continue;
        params[nparams] = p;
        nparams += 1;
    }
    if (d.model.isMos()) for (diffusions, 0..) |name, i| {
        sd[i] = if (drawn)
            (if (declared.has(d.model, name)) drawnDiffusion(i, d.w) else null)
        else for (d.paramsOf()) |p| (if (std.mem.eql(u8, p.name, name)) break p.value) else null;
    };
    // `m` folds into `W` and the diffusions where there is a `W`.
    var mult = m;
    if (w) |wv| {
        for (&sd) |*v| if (v.*) |x| {
            v.* = x * @as(f64, @floatFromInt(m));
        };
        w = wv * @as(f64, @floatFromInt(m));
        mult = 1;
    }
    // Relaxed, a resistor's or capacitor's value is what the layout
    // measures where a card declares it, or what the card writes, and `m`
    // folds into it: `r/m`, `m c`.
    var value = d.value;
    if (controls.valueLaw(d.model)) |law| {
        const v: ?f64 = if (drawn) (if (declared.has(d.model, law[0])) measured(d.model, law[0]) else null) else d.value;
        if (v) |x| {
            value = if (law[1]) x / @as(f64, @floatFromInt(mult)) else x * @as(f64, @floatFromInt(mult));
            mult = 1;
        } else value = null;
    }
    return .{ .model = d.model, .pins = d.pins, .npins = d.npins, .w = w, .l = l, .mult = mult, .area = d.area, .value = value, .params = params, .nparams = nparams, .sd = sd };
}

/// The documented reductions to a fixed point, parallel first. A MOS is
/// sized by `w` and `l` where its card writes them, or, `drawn`, where
/// some reference card of its model does:
///
/// - multiplier: a MOS's `m` multiplies its `W`; any other device's `m`, a
///   MOS with no `W` included, is that many in parallel;
/// - parallel: devices of one model on the same nets role for role become
///   one; a MOS with `W` needs its other sizes equal and sums `W`,
///   anything else needs its parameters equal and sums its count;
/// - series (MOS only): two devices that both state `L`, with gates (and
///   bulks) on one net and equal `W` and count, whose channels meet at a
///   net that is not a port and that no other terminal touches, become one
///   with `L` summed; the net is consumed.
///
/// A net no terminal lands on survives only as a port: a floating shape is
/// not a node, and SPICE cannot even write one. Under `controls`, the pins
/// a parallel merge may exchange are `Controls.classes`, and an asymmetric
/// transistor never merges in series.
fn reduce(arena: Allocator, c: *const Circuit, declared: *const Declared, drawn: bool, controls: *const Controls) !Reduction {
    var devs: std.ArrayList(Reduced) = .empty;
    for (c.devs) |*d| try devs.append(arena, start(d, declared, drawn, controls));
    const alive = try arena.alloc(bool, c.nets());
    @memset(alive, true);
    pass: while (true) {
        for (0..devs.items.len) |i| for (i + 1..devs.items.len) |j| {
            const a = &devs.items[i];
            const b = &devs.items[j];
            // A `W` sums the diffusions end by end, all four or none
            // stated; without one they must be the same, as any value.
            var stated: usize = 0;
            for (a.sd) |v| stated += @intFromBool(v != null);
            const same_presence = for (a.sd, b.sd) |x, y| (if ((x != null) != (y != null)) break false) else true;
            const diffusions_ok = if (a.w != null) same_presence and (stated == 0 or stated == 4) else eqlSd(a.sd, b.sd);
            // Relaxed, two values of one law combine instead of agreeing.
            const law = if (a.value != null and b.value != null) controls.valueLaw(a.model) else null;
            const params = a.l == b.l and (a.w != null) == (b.w != null) and diffusions_ok and a.area == b.area and (a.value == b.value or law != null) and eqlParams(a.paramsOf(), b.paramsOf());
            if (a.model == b.model and params and samePins(a.model, a.pinsOf(), b.pinsOf(), null, controls)) {
                const across: usize = @intFromBool(crossed(a, b, null));
                const gone = devs.orderedRemove(j);
                const keep = &devs.items[i];
                if (law) |lw| {
                    keep.value = if (lw[1]) 1.0 / (1.0 / keep.value.? + 1.0 / gone.value.?) else keep.value.? + gone.value.?;
                } else if (keep.w != null and gone.w != null) {
                    keep.w = keep.w.? + gone.w.?;
                    for (0..4) |k| keep.sd[k] = if (keep.sd[k] != null and gone.sd[k ^ across] != null) keep.sd[k].? + gone.sd[k ^ across].? else null;
                } else keep.mult += gone.mult;
                continue :pass;
            }
        };
        for (0..devs.items.len) |i| for (0..devs.items.len) |j| {
            const a = devs.items[i];
            const b = devs.items[j];
            // Relaxed, deck.md's: two resistors or capacitors stating their
            // value chain through a net only they touch, no port, their far
            // ends two other nets; `r` adds and `c` combines harmonically.
            // Ordered plates chain plate to plate. The fixtures state no
            // other parameter on such a passive, so this oracle refuses one
            // that does.
            const passive_model = switch (a.model) {
                .r, .c, .l => true,
                .n, .p, .h, .b, .d, .q => false,
            };
            const passive = i != j and a.model == b.model and passive_model and controls.valueLaw(a.model) != null and a.value != null and b.value != null and a.nparams == 0 and b.nparams == 0 and a.area == null and b.area == null;
            if (passive) {
                const class = controls.classes(a.model);
                const ordered = class[0] == 0 and class[1] == 1 and class[2] == 2 and class[3] == 3;
                for (0..2) |ea| for (0..2) |eb| {
                    const x = a.pins[ea];
                    const far_a = a.pins[1 - ea];
                    const far_b = b.pins[1 - eb];
                    if (x != b.pins[eb] or c.ports[x] or touches(devs.items, x) != 2 or far_a == x or far_b == x or far_a == far_b or (ordered and ea == eb)) continue;
                    const va = a.value.?;
                    const vb = b.value.?;
                    const value = switch (a.model) {
                        .r, .l => va + vb,
                        .c, .n, .p, .h, .b, .d, .q => 1.0 / (1.0 / va + 1.0 / vb),
                    };
                    var pins: [2]usize = .{ far_a, far_b };
                    if (ordered) {
                        pins[1 - ea] = far_a;
                        pins[ea] = far_b;
                    }
                    devs.items[i].pins[0] = pins[0];
                    devs.items[i].pins[1] = pins[1];
                    devs.items[i].npins = 2;
                    devs.items[i].value = value;
                    _ = devs.orderedRemove(j);
                    alive[x] = false;
                    continue :pass;
                };
            }
            const bulks_equal = std.mem.eql(usize, a.pinsOf()[@min(3, a.npins)..], b.pinsOf()[@min(3, b.npins)..]);
            const no_sd = eqlSd(a.sd, @splat(null)) and eqlSd(b.sd, @splat(null));
            const mergeable = i != j and a.model.isMos() and controls.series(a.model) and a.model == b.model and a.pins[0] == b.pins[0] and bulks_equal and a.l != null and b.l != null and no_sd and a.w == b.w and a.mult == b.mult;
            if (!mergeable) continue;
            for (1..3) |ea| for (1..3) |eb| {
                const x = a.pins[ea];
                if (x == b.pins[eb] and !c.ports[x] and touches(devs.items, x) == 2) {
                    devs.items[i].pins[1] = a.pins[3 - ea];
                    devs.items[i].pins[2] = b.pins[3 - eb];
                    devs.items[i].l = a.l.? + b.l.?;
                    _ = devs.orderedRemove(j);
                    alive[x] = false;
                    continue :pass;
                }
            };
        };
        break;
    }
    var live: std.ArrayList(usize) = .empty;
    for (0..c.nets()) |k| if (alive[k] and (c.ports[k] or touches(devs.items, k) > 0)) try live.append(arena, k);
    const models = try arena.alloc(Model, devs.items.len);
    for (devs.items, models) |d, *m| m.* = d.model;
    std.mem.sort(Model, models, {}, lessModel);
    return .{ .devs = devs.items, .live = live.items, .nets = c.nets(), .models = models, .names = c.names, .ports = c.ports };
}

fn lessModel(_: void, a: Model, b: Model) bool {
    return @backingInt(a) < @backingInt(b);
}

/// Whether layout device `a`, its nets renamed by `map`, is reference
/// device `b` under `controls`. An area is compared only where the
/// reference declares one (F22).
fn pairs(a: *const Reduced, b: *const Reduced, map: []const usize, controls: *const Controls) bool {
    if (a.model != b.model or a.mult != b.mult) return false;
    if (!samePins(a.model, a.pinsOf(), b.pinsOf(), map, controls)) return false;
    const model = b.model;
    // The layout side always has its marker's area: what was drawn.
    const drawn_area: i64 = if (a.model == .q) circuit.bjt_area else circuit.pin2_area;
    if (b.area) |declared| if (!controls.close(model, "area", @floatFromInt(a.area orelse drawn_area), @floatFromInt(declared), 1e-18)) return false;
    // Every other value the card states, against what was drawn; one the
    // layout cannot measure never agrees. Relaxed, the layout's value is
    // the one its merges combined.
    const law_value: ?struct { []const u8, f64 } = if (controls.valueLaw(model)) |law| (if (a.value) |v| .{ law[0], v } else null) else null;
    const primary = model.primary();
    for (b.paramsOf()) |p| if (!statedAgrees(model, law_value, p.name, p.value, controls)) return false;
    if (b.value) |v| if (!statedAgrees(model, law_value, primary, v, controls)) return false;
    // A size the card writes, against the layout's, which measures it since
    // the card's model declares it, in nm (`si` 1e-9); a diffusion at its
    // channel end, in SI.
    const across: usize = @intFromBool(crossed(a, b, map));
    for (0..4) |k| if (!sizeAgrees(model, diffusions[k], a.sd[k ^ across], b.sd[k], 1.0, controls)) return false;
    return sizeAgrees(model, "w", a.w, b.w, 1e-9, controls) and sizeAgrees(model, "l", a.l, b.l, 1e-9, controls);
}

fn statedAgrees(model: Model, law_value: ?struct { []const u8, f64 }, name: []const u8, v: f64, controls: *const Controls) bool {
    const drawn: ?f64 = if (law_value) |lv| (if (std.mem.eql(u8, lv[0], name)) lv[1] else measured(model, name)) else measured(model, name);
    return if (drawn) |d| controls.close(model, name, d, v, 1.0) else false;
}

fn sizeAgrees(model: Model, name: []const u8, a: ?f64, b: ?f64, si: f64, controls: *const Controls) bool {
    const want = b orelse return true;
    const got = a orelse return false;
    return controls.close(model, name, got, want, si);
}

/// Whether some assignment pairs each of `a[from..]` with a distinct
/// unused device of `b`.
fn assign(a: []const Reduced, b: []const Reduced, map: []const usize, controls: *const Controls, used: []bool, from: usize) bool {
    if (from == a.len) return true;
    for (b, 0..) |*dev, j| if (!used[j] and pairs(&a[from], dev, map, controls)) {
        used[j] = true;
        if (assign(a, b, map, controls, used, from + 1)) return true;
        used[j] = false;
    };
    return false;
}

/// Whether some bijection of `a`'s surviving nets onto `b`'s pairs every
/// device.
fn matches(arena: Allocator, a: *const Reduction, b: *const Reduction, controls: *const Controls) !bool {
    if (a.live.len != b.live.len or !std.mem.eql(Model, a.models, b.models)) return false;
    // Under `lvs ports_by_name`, deck.md's: each reference port pairs with
    // the layout net its name labels, which must exist.
    if (controls.ports_by_name) for (0..b.nets) |r| if (b.ports[r] and labelled(a, b.names[r]) == null) return false;
    // Under `lvs same_nets`, deck.md's: the layout net labelled with the
    // row's first name pairs with the reference net of its second, and a
    // row only one side has a net for is unpaired.
    const rows = try arena.alloc([2]?usize, controls.same_nets.len);
    for (controls.same_nets, rows) |row, *out| {
        const layout_net: ?usize = for (a.live) |k| (if (a.ports[k] and std.mem.eql(u8, a.names[k], row.layout)) break k) else null;
        const reference_net: ?usize = for (b.live) |r| (if (std.mem.eql(u8, b.names[r], row.reference)) break r) else null;
        if ((layout_net != null) != (reference_net != null)) return false;
        out.* = .{ layout_net, reference_net };
    }
    const map = try arena.alloc(usize, a.nets);
    @memset(map, std.math.maxInt(usize));
    const used = try arena.alloc(bool, b.devs.len);
    for (try permutations(arena, a.live.len)) |perm| {
        for (a.live, 0..) |k, i| map[k] = b.live[perm[i]];
        const same = for (rows) |row| (if (row[0] != null and map[row[0].?] != row[1].?) break false) else true;
        if (!same) continue;
        if (controls.ports_by_name) {
            const named = for (a.live) |k| {
                if (!a.ports[k]) continue;
                if (portOf(b, a.names[k])) |r| if (map[k] != r) break false;
            } else true;
            if (!named) continue;
        }
        @memset(used, false);
        if (assign(a.devs, b.devs, map, controls, used, 0)) return true;
    }
    return false;
}

fn portOf(b: *const Reduction, name: []const u8) ?usize {
    for (0..b.nets) |r| if (b.ports[r] and std.mem.eql(u8, b.names[r], name)) return r;
    return null;
}

fn labelled(a: *const Reduction, name: []const u8) ?usize {
    for (0..a.nets) |k| if (a.ports[k] and std.mem.eql(u8, a.names[k], name)) return k;
    return null;
}

test "the oracle agrees with hand derivations" {
    // Oracle: hand-derived from docs/usage.md's reductions: a circuit
    // matches itself; two parallel nmos match one of double width; a stack
    // through an internal net matches one of double length; a stack through
    // a port does not; source and drain swap; a pmos is not an nmos.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2)});
    try std.testing.expect(try equivalent(a, &one, &one));
    const two = try Circuit.init(a, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 1, 2) });
    const wide = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150)});
    try std.testing.expect(try equivalent(a, &two, &wide));
    const stack = try (try Circuit.init(a, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) })).internal(a, 3);
    const long = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300)});
    try std.testing.expect(try equivalent(a, &stack, &long));
    const labelled_stack = try Circuit.init(a, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) });
    try std.testing.expect(!try equivalent(a, &labelled_stack, &long));
    const swapped = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 2, 1)});
    try std.testing.expect(try equivalent(a, &one, &swapped));
    const pmos = try Circuit.init(a, 3, &.{Dev.mos(.p, 0, 1, 2)});
    try std.testing.expect(!try equivalent(a, &one, &pmos));
}
