//! A board's expected findings, re-derived from each rule's definition by
//! a naive graph oracle over the circuit as planted: role masks per net,
//! pull networks to the declared rails, supply reach over the channels that
//! can conduct, the clamp path from a pad, the guard ring's box, and each
//! power state's reach. Ported from crates/check/tests/erc/ported.rs
//! (`Board::{expect, expect_states, fixture}`).
//!
//! Contents:
//! - `pub fn fixtureOf(b: *const Board, arena: Allocator, name: []const u8) !Fixture`
//! - `pub fn expectInto(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void`
//! - `pub fn count(n: u32) Finding`, `pub fn millivolts(x: f64) Finding`, `pub fn length(nm: i64) Finding`

const std = @import("std");
const Allocator = std.mem.Allocator;
const check = @import("check");
const Measurement = check.report.Measurement;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Expect = fixture.Expect;
const Finding = fixture.Finding;
const board = @import("board.zig");
const Board = board.Board;
const Dev = board.Dev;
const Reach = board.Reach;
const nets = board.nets;

const Terminals = struct { g: bool, s: bool, d: bool, b: bool };

/// A board's fixture: the topology deck at its limits, its layout, every
/// expectation, and its intent when it has one.
pub fn fixtureOf(b: *const Board, arena: Allocator, name: []const u8) !Fixture {
    var expect: std.ArrayList(Expect) = .empty;
    try expectInto(b, arena, &expect);
    return .{
        .name = try arena.dupe(u8, name),
        .deck = try board.topoDeck(arena, b.limits),
        .layout = try b.layout(arena),
        .intent = if (b.with_intent) try b.intentJson(arena) else null,
        .expect = expect.items,
    };
}

/// Every rule's expectation, from the definitions in each kind's doc.
pub fn expectInto(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void {
    // floating_gate: a net whose every terminal is a gate.
    var fg: std.ArrayList(Finding) = .empty;
    var fgp: std.ArrayList(Finding) = .empty;
    for (0..nets) |n| {
        const t = terminals(b, n);
        if (!(t.g and !t.s and !t.d and !t.b)) continue;
        try fg.append(arena, count(0));
        if (b.labels[n] == null) try fgp.append(arena, count(0));
    }
    try out.append(arena, .{ .id = "fg", .findings = fg.items });
    try out.append(arena, .{ .id = "fgp", .findings = fgp.items });
    // unconnected_pin(met1, met2): every met1 and met2 polygon of a net no
    // device terminal reaches: its track, and each tap riser on it.
    var up: std.ArrayList(Finding) = .empty;
    for (0..nets) |n| {
        const t = terminals(b, n);
        if (t.g or t.s or t.d or t.b) continue;
        var taps: usize = 0;
        for (b.taps) |tap| taps += @intFromBool(tap.net == n);
        for (0..taps + 1) |_| try up.append(arena, count(0));
    }
    try out.append(arena, .{ .id = "up", .findings = up.items });
    // supply_short: a net holding an n-tap and a p-tap; with `within`, only
    // n-taps inside an nwpm polygon count.
    for ([_]struct { []const u8, bool }{ .{ "ss", false }, .{ "ssw", true } }) |case| {
        var found: std.ArrayList(Finding) = .empty;
        for (0..nets) |n| {
            var a = false;
            var p = false;
            for (b.taps, 0..) |tap, j| {
                if (tap.n and tap.net == n and (!case[1] or std.mem.indexOfScalar(usize, b.nwpm, j) != null)) a = true;
                if (!tap.n and tap.net == n) p = true;
            }
            if (a and p) try found.append(arena, count(2));
        }
        try out.append(arena, .{ .id = case[0], .findings = found.items });
    }
    // soft_connection: every well hangs off a riser that also holds the
    // rest of its net.
    try out.append(arena, .{ .id = "soft" });
    // fanout(; max: 1): a net with two or more gates, measuring the count.
    var fo: std.ArrayList(Finding) = .empty;
    for (0..nets) |n| {
        var gates: u32 = 0;
        for (b.devs) |d| gates += @intFromBool(d.g == n);
        if (gates > 1) try fo.append(arena, count(gates));
    }
    try out.append(arena, .{ .id = "fo", .findings = fo.items });
    if (!b.with_intent) {
        for (board.topo_rules) |r| if (r.intent) try out.append(arena, .{ .id = r.id, .outcome = .skipped });
        return;
    }
    try expectStates(b, arena, out);
    try expectDrivers(b, arena, out);
    try expectPaths(b, arena, out);
    try expectVoltages(b, arena, out);
    try expectEsd(b, arena, out);
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn count(n: u32) Finding {
    return .{ .measured = Measurement.count(n) };
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn millivolts(x: f64) Finding {
    return .{ .measured = Measurement.voltage(.{ .raw = x }) };
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn length(nm: i64) Finding {
    return .{ .measured = Measurement.length(nm) };
}

// ---- private ----

fn terminals(b: *const Board, net: usize) Terminals {
    var t: Terminals = .{ .g = false, .s = false, .d = false, .b = false };
    for (b.devs) |d| {
        t.g = t.g or d.g == net;
        t.s = t.s or d.s == net;
        t.d = t.d or d.d == net;
        t.b = t.b or (d.b != null and d.b.? == net);
    }
    return t;
}

fn rail(b: *const Board, n: usize) bool {
    return b.supply(n) != null;
}

fn far(d: Dev, n: usize) usize {
    return if (d.s == n) d.d else d.s;
}

/// multiple_drivers: a transistor with a channel end on a non-rail net
/// pulls it when a walk from its other end, through every transistor with
/// a channel end on the nets reached, stopping at rails and never back
/// through the net, reaches a rail; its gates are those of every transistor
/// the walk passes. Networks sharing a gate net are one driver.
fn expectDrivers(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void {
    for ([_]struct { []const u8, usize }{ .{ "md1", 1 }, .{ "md2", 2 } }) |case| {
        var found: std.ArrayList(Finding) = .empty;
        for (0..nets) |n| {
            if (rail(b, n)) continue;
            // Each driver's gate set, as a bit mask over nets.
            var gates: std.ArrayList(u8) = .empty;
            for (b.devs) |m| {
                if (m.s != n and m.d != n) continue;
                var set: u8 = @as(u8, 1) << @intCast(m.g);
                var seen: [nets]bool = @splat(false);
                var walk: std.ArrayList(usize) = .empty;
                try walk.append(arena, far(m, n));
                var reached = false;
                while (walk.pop()) |at| {
                    if (at == n or seen[at]) continue;
                    seen[at] = true;
                    if (rail(b, at)) {
                        reached = true;
                        continue;
                    }
                    for (b.devs) |u| if (u.s == at or u.d == at) {
                        set |= @as(u8, 1) << @intCast(u.g);
                        try walk.append(arena, far(u, at));
                    };
                }
                if (reached) try gates.append(arena, set);
            }
            const group = try arena.alloc(usize, gates.items.len);
            for (group, 0..) |*g, i| g.* = i;
            var changed = true;
            while (changed) {
                changed = false;
                for (0..gates.items.len) |i| for (0..gates.items.len) |j| {
                    if (gates.items[i] & gates.items[j] == 0 or group[j] <= group[i]) continue;
                    const old = group[j];
                    const new = group[i];
                    for (group) |*g| if (g.* == old) {
                        g.* = new;
                    };
                    changed = true;
                };
            }
            std.mem.sortUnstable(usize, group, {}, std.sort.asc(usize));
            var distinct: u32 = 0;
            for (group, 0..) |g, i| distinct += @intFromBool(i == 0 or group[i - 1] != g);
            if (distinct > case[1]) try found.append(arena, count(distinct));
        }
        try out.append(arena, .{ .id = case[0], .findings = found.items });
    }
}

/// supply_path, gate_path, combinational_loop, tie_high_low.
fn expectPaths(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void {
    // supply_path: from each non-rail net a device terminal reaches, walk
    // source to drain, stopping at rails (a rail gives its role). `sp1`
    // flags no rail reached, `sp2` power or ground missed; `sp3` is `sp2`
    // with every labelled non-rail net a top-cell port (a break that
    // carries no role: a walk never steps past a port, and one from a port
    // takes one step).
    var sp: [3]std.ArrayList(Finding) = .{ .empty, .empty, .empty };
    for (0..nets) |n| {
        const t = terminals(b, n);
        if (rail(b, n) or !(t.g or t.s or t.d or t.b)) continue;
        const found = rolesFrom(b, n, false);
        if (found == 0) try sp[0].append(arena, count(0));
        if (found < 2) try sp[1].append(arena, count(found));
        const with_ports = rolesFrom(b, n, true);
        if (with_ports < 2) try sp[2].append(arena, count(with_ports));
    }
    for ([_][]const u8{ "sp1", "sp2", "sp3" }, sp) |id, f| try out.append(arena, .{ .id = id, .findings = f.items });
    // gate_path: the fewest transistors a walk from a gate's net passes to
    // reach a rail of the asked role (other rails passed like any net); more
    // than `max` measures the count, no walk measures 0.
    for ([_]struct { []const u8, bool, u32 }{ .{ "gp0", true, 0 }, .{ "gp1", false, 1 } }) |case| {
        var dist: [nets]u32 = @splat(std.math.maxInt(u32));
        var frontier: std.ArrayList(usize) = .empty;
        for (0..nets) |n| if (b.supply(n)) |s| if (s.power != case[1]) {
            dist[n] = 0;
            try frontier.append(arena, n);
        };
        var step: u32 = 0;
        while (frontier.items.len > 0) {
            step += 1;
            var next: std.ArrayList(usize) = .empty;
            for (frontier.items) |at| for (b.devs) |u| if (u.s == at or u.d == at) {
                const to = far(u, at);
                if (dist[to] == std.math.maxInt(u32)) {
                    dist[to] = step;
                    try next.append(arena, to);
                }
            };
            frontier = next;
        }
        var found: std.ArrayList(Finding) = .empty;
        for (0..nets) |n| {
            if (!terminals(b, n).g) continue;
            if (dist[n] == std.math.maxInt(u32)) try found.append(arena, count(0)) else if (dist[n] > case[2]) try found.append(arena, count(dist[n]));
        }
        try out.append(arena, .{ .id = case[0], .findings = found.items });
    }
    try out.append(arena, .{ .id = "cl", .findings = try loops(b, arena) });
    // tie_high_low: a rail that reaches a gate.
    var thl: std.ArrayList(Finding) = .empty;
    for (0..nets) |n| if (rail(b, n) and terminals(b, n).g) try thl.append(arena, count(0));
    try out.append(arena, .{ .id = "thl", .findings = thl.items });
}

/// The roles (power, ground) a walk from `n` reaches.
fn rolesFrom(b: *const Board, n: usize, ports: bool) u32 {
    var seen: [nets]bool = @splat(false);
    var walk: [64]usize = undefined;
    var top: usize = 1;
    walk[0] = n;
    var roles: [2]bool = .{ false, false };
    while (top > 0) {
        top -= 1;
        const at = walk[top];
        if (seen[at]) continue;
        seen[at] = true;
        if (b.supply(at)) |s| {
            roles[@intFromBool(!s.power)] = true;
            continue;
        }
        // A port ends the walk that reaches it, and one from a port ends one
        // device out.
        if (ports and at != n and (isPort(b, at) or isPort(b, n))) continue;
        for (b.devs) |u| if (u.s == at or u.d == at) {
            walk[top] = far(u, at);
            top += 1;
        };
    }
    return @as(u32, @intFromBool(roles[0])) + @intFromBool(roles[1]);
}

fn isPort(b: *const Board, n: usize) bool {
    return b.labels[n] != null and b.supply(n) == null;
}

/// combinational_loop: components are the non-rail nets joined by
/// transistors with both channel ends off the rails; a transistor whose
/// channel touches a component belongs to it, and its gate's component
/// (when the gate is a channel end) drives it. A loop is a set of
/// components each reaching every other, of two or more, or one driving
/// itself; it measures its components.
fn loops(b: *const Board, arena: Allocator) ![]const Finding {
    var comp: [nets]usize = undefined;
    for (&comp, 0..) |*c, n| c.* = n;
    while (true) {
        var changed = false;
        for (b.devs) |d| {
            if (rail(b, d.s) or rail(b, d.d)) continue;
            const low = @min(comp[d.s], comp[d.d]);
            const cs = comp[d.s];
            const cd = comp[d.d];
            for (&comp) |*c| if ((c.* == cs or c.* == cd) and c.* != low) {
                c.* = low;
                changed = true;
            };
        }
        if (!changed) break;
    }
    var drives: [nets][nets]bool = @splat(@splat(false));
    for (b.devs) |d| {
        const to: ?usize = if (!rail(b, d.s)) d.s else if (!rail(b, d.d)) d.d else null;
        if (to != null and isEnd(b, d.g)) drives[comp[d.g]][comp[to.?]] = true;
    }
    for (0..nets) |k| for (0..nets) |i| for (0..nets) |j| {
        drives[i][j] = drives[i][j] or (drives[i][k] and drives[k][j]);
    };
    var roots: std.ArrayList(usize) = .empty;
    for (0..nets) |n| if (isEnd(b, n) and comp[n] == n) try roots.append(arena, n);
    var done: [nets]bool = @splat(false);
    var found: std.ArrayList(Finding) = .empty;
    for (roots.items) |c| {
        if (done[c] or !drives[c][c]) continue;
        var members: u32 = 0;
        for (roots.items) |o| if (o == c or (drives[c][o] and drives[o][c])) {
            done[o] = true;
            members += 1;
        };
        try found.append(arena, count(members));
    }
    return found.items;
}

fn isEnd(b: *const Board, n: usize) bool {
    if (rail(b, n)) return false;
    for (b.devs) |d| if (d.s == n or d.d == n) return true;
    return false;
}

/// gate_oxide, drain_source, missing_level_shifter, domain_crossing,
/// hv_domain and well_bias, from the board's reach.
fn expectVoltages(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void {
    const reach = b.reach();
    var gox: std.ArrayList(Finding) = .empty;
    var vds: std.ArrayList(Finding) = .empty;
    var ls: std.ArrayList(Finding) = .empty;
    var xing: std.ArrayList(Finding) = .empty;
    var hv: std.ArrayList(Finding) = .empty;
    var wb: std.ArrayList(Finding) = .empty;
    for (b.devs, 0..) |dv, i| {
        // gate_oxide: the worst gate-to-source, -drain or -bulk difference.
        if (dv.model == .nfet or dv.model == .nfet_b or dv.model == .pfet_b) {
            var stress: ?f64 = null;
            for ([3]?usize{ dv.s, dv.d, dv.b }) |x| if (x) |n| if (worst(&reach, dv.g, n)) |v| {
                stress = @max(stress orelse v, v);
            };
            if (stress) |v| if (v > b.limits.gox) try gox.append(arena, millivolts(v));
        }
        if (dv.model == .nfet or dv.model == .pfet or dv.model == .nfet_b or dv.model == .pfet_b) {
            if (worst(&reach, dv.s, dv.d)) |v| if (v > b.limits.vds) try vds.append(arena, millivolts(v));
        }
        // missing_level_shifter: a gate domain neither channel end has.
        if (dv.model != .pfet) {
            const gate = power(&reach, dv.g);
            const channel = power(&reach, dv.s) | power(&reach, dv.d);
            if (gate != 0 and channel != 0 and gate & ~channel != 0) try ls.append(arena, count(@popCount(gate & ~channel)));
        }
        // domain_crossing: two power domains on one channel.
        const mask = power(&reach, dv.s) | power(&reach, dv.d);
        if (@popCount(mask) > 1) try xing.append(arena, count(@popCount(mask)));
        // hv_domain: the domain span over every terminal, all reached.
        var lo = std.math.inf(f64);
        var hi = -std.math.inf(f64);
        var all = true;
        for ([4]?usize{ dv.g, dv.s, dv.d, dv.b }) |x| if (x) |n| {
            const r = reach[n] orelse {
                all = false;
                continue;
            };
            lo = @min(lo, r.nominal_lo);
            hi = @max(hi, r.nominal_hi);
        };
        if (all and std.mem.indexOfScalar(usize, b.iso, i) == null and hi - lo > b.limits.hv) try hv.append(arena, millivolts(hi - lo));
        // well_bias: a pmos end above its well's lowest, an nmos end below
        // its substrate's highest.
        if (dv.b) |bulk_net| if (dv.model == .nfet_b or dv.model == .pfet_b) if (reach[bulk_net]) |bulk| {
            var ends_hi = -std.math.inf(f64);
            var ends_lo = std.math.inf(f64);
            var any = false;
            for ([2]usize{ dv.s, dv.d }) |n| if (reach[n]) |r| {
                ends_hi = @max(ends_hi, r.hi);
                ends_lo = @min(ends_lo, r.lo);
                any = true;
            };
            if (any) {
                const excess = if (dv.model == .pfet_b) ends_hi - bulk.lo else bulk.hi - ends_lo;
                if (excess > 0.0) try wb.append(arena, millivolts(excess));
            }
        };
    }
    for ([_][]const u8{ "gox", "vds", "ls", "xing", "hv", "wb" }, [_][]const Finding{ gox.items, vds.items, ls.items, xing.items, hv.items, wb.items }) |id, f| try out.append(arena, .{ .id = id, .findings = f });
}

fn worst(reach: *const [nets]?Reach, a: usize, b_: usize) ?f64 {
    const x = reach[a] orelse return null;
    const y = reach[b_] orelse return null;
    return @max(x.hi - y.lo, y.hi - x.lo);
}

fn power(reach: *const [nets]?Reach, n: usize) u64 {
    return if (reach[n]) |r| r.power else 0;
}

/// esd_topological: from the pad, any clamp terminal; from a supply, onward
/// through clamps; another signal net ends the path. esd_latchup: the pad
/// check, then the ring's narrow side against 500 nm and its gap to the
/// nearest supply track against 2 µm.
fn expectEsd(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void {
    var esd: std.ArrayList(Finding) = .empty;
    if (b.pad) |pad| {
        var seen: [nets]bool = @splat(false);
        var stack: [64]usize = undefined;
        var top: usize = 1;
        stack[0] = pad;
        seen[pad] = true;
        var p = false;
        var g = false;
        while (top > 0) {
            top -= 1;
            const net = stack[top];
            if (b.supply(net)) |s| {
                if (s.power) p = true else g = true;
            } else if (net != pad) continue;
            for (b.devs) |dv| {
                if (dv.model != .clamp) continue;
                const all = [4]?usize{ dv.g, dv.s, dv.d, dv.b };
                const on = for (all) |x| {
                    if (x != null and x.? == net) break true;
                } else false;
                if (!on) continue;
                for (all) |x| if (x) |next| if (!seen[next]) {
                    seen[next] = true;
                    stack[top] = next;
                    top += 1;
                };
            }
        }
        const rails = @as(u32, @intFromBool(p)) + @intFromBool(g);
        if (rails < 2) try esd.append(arena, count(rails));
    }
    try out.append(arena, .{ .id = "esd", .findings = esd.items });
    var esdl: std.ArrayList(Finding) = .empty;
    try esdl.appendSlice(arena, esd.items);
    if (b.ring) |r| {
        const width = @min(r[2] - r[0], r[3] - r[1]);
        if (width < 500) try esdl.append(arena, length(width));
        const right = @as(i64, @intCast(b.columns())) * board.pitch + 1000;
        var gap: ?i64 = null;
        for (b.supplies) |s| {
            const tlo = board.trackY(s.net);
            const thi = tlo + board.track_h;
            const dx = @max(-1000 - r[2], r[0] - right, 0);
            const dy = @max(tlo - r[3], r[1] - thi, 0);
            const here = @max(dx, dy);
            gap = @min(gap orelse here, here);
        }
        if (gap) |v| {
            if (v > 2000) try esdl.append(arena, length(v));
        } else try esdl.append(arena, count(0));
    }
    try out.append(arena, .{ .id = "esdl", .findings = esdl.items });
}

/// `undriven_gate` and `missing_isolation(; isolation: ["pfet"])`: per
/// declared state, the reach from that state's supplies. A gate net
/// reached with every supply on that a state leaves unreached floats
/// there; a non-pfet transistor whose gate floats while a power supply
/// reaches its source or drain leaks. Each measures its count of states;
/// without states both are skipped.
fn expectStates(b: *const Board, arena: Allocator, out: *std.ArrayList(Expect)) !void {
    if (b.states.len == 0) {
        try out.append(arena, .{ .id = "ug", .outcome = .skipped });
        try out.append(arena, .{ .id = "iso", .outcome = .skipped });
        return;
    }
    const base = b.reach();
    const states = try arena.alloc([nets]?Reach, b.states.len);
    for (states, b.states) |*r, st| r.* = b.reachWith(try b.stateSupplies(arena, st));
    var ug: std.ArrayList(Finding) = .empty;
    for (0..nets) |n| {
        if (!terminals(b, n).g) continue;
        var off: u32 = 0;
        for (states) |*r| off += @intFromBool(base[n] != null and r[n] == null);
        if (off > 0) try ug.append(arena, count(off));
    }
    var iso: std.ArrayList(Finding) = .empty;
    for (b.devs) |d| {
        if (d.model == .pfet) continue;
        var off: u32 = 0;
        for (states) |*r| {
            const floats = base[d.g] != null and r[d.g] == null;
            off += @intFromBool(floats and (power(r, d.s) | power(r, d.d)) != 0);
        }
        if (off > 0) try iso.append(arena, count(off));
    }
    try out.append(arena, .{ .id = "ug", .findings = ug.items });
    try out.append(arena, .{ .id = "iso", .findings = iso.items });
}
