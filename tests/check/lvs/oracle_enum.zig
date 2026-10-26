//! Every small circuit and every single fault: the enumeration the LVS
//! oracle is held against. Every circuit of one to three `nmos`/`pmos` over
//! one to four nets, every net used, one per class under renaming nets and
//! devices and swapping source with drain (4223 circuits), and the single
//! faults of a reference. Ported from tests/exhaustive/lvs.rs (`key`,
//! `circuits`, `faults`, and the tests `orbits`,
//! `the_enumeration_has_every_canonical_circuit`).
//!
//! Contents:
//! - `pub const Key`, `pub fn key(c: *const Circuit) Key`
//! - `pub fn circuitsInto(gpa: Allocator, out: *std.ArrayList(Circuit)) !void`
//! - `pub const Fault`, `pub fn faultsInto(gpa: Allocator, c: *const Circuit, out: *std.ArrayList(Fault)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const oracle = @import("oracle.zig");
const Circuit = oracle.Circuit;
const Dev = oracle.Dev;
const Model = oracle.Model;

/// A circuit up to renaming nets and devices and swapping source with
/// drain: the least sorted list of device codes over every renaming of the
/// nets that lists them by how many gates and channel ends each carries.
pub const Key = [4]u64;

/// One single fault of a reference: its label (kind, then where) and the
/// faulted circuit, compacted.
pub const Fault = struct { kind: []const u8, at: u32, circuit: Circuit };

pub fn key(c: *const Circuit) Key {
    const n = c.nets;
    var count: [oracle.max_nets][2]u8 = @splat(.{ 0, 0 });
    for (c.devices()) |d| {
        count[d.pins[0]][0] += 1;
        count[d.pins[1]][1] += 1;
        count[d.pins[2]][1] += 1;
    }
    var sorted = count;
    std.mem.sortUnstable([2]u8, sorted[0..n], {}, lessCount);
    var rank: [oracle.max_nets][2]u8 = undefined;
    for (0..n) |k| {
        var lo: u8 = 0;
        var hi: u8 = 0;
        for (sorted[0..n]) |s| {
            lo += @intFromBool(lessCount({}, s, count[k]));
            hi += @intFromBool(!lessCount({}, count[k], s));
        }
        rank[k] = .{ lo, hi };
    }
    var best: Key = @splat(std.math.maxInt(u64));
    var perm: [oracle.max_nets]u8 = undefined;
    var used: [oracle.max_nets]bool = @splat(false);
    searchKey(c, &rank, &perm, &used, 0, &best);
    return best;
}

/// Every circuit of one to three `nmos`/`pmos` over one to four nets, every
/// net used, one per isomorphism class, in Rust's enumeration order.
pub fn circuitsInto(gpa: Allocator, out: *std.ArrayList(Circuit)) !void {
    var seen: std.AutoHashMapUnmanaged(Key, void) = .empty;
    defer seen.deinit(gpa);
    var types: std.ArrayList(Dev) = .empty;
    defer types.deinit(gpa);
    for (1..5) |nets_usize| {
        const nets: u8 = @intCast(nets_usize);
        types.clearRetainingCapacity();
        seen.clearRetainingCapacity();
        for ([_]Model{ .n, .p }) |model| for (0..nets) |g| for (0..nets) |s| for (s..nets) |d| {
            try types.append(gpa, Dev.mos(model, @intCast(g), @intCast(s), @intCast(d)));
        };
        const t = types.items;
        for (0..t.len) |a| {
            try pick(gpa, nets, &.{t[a]}, &seen, out);
            for (a..t.len) |b| {
                try pick(gpa, nets, &.{ t[a], t[b] }, &seen, out);
                for (t[b..]) |third| try pick(gpa, nets, &.{ t[a], t[b], third }, &seen, out);
            }
        }
    }
}

/// Every single fault of the module docs applied to `c`'s reference, plus
/// the source/drain swaps, which must keep the verdict.
pub fn faultsInto(gpa: Allocator, c: *const Circuit, out: *std.ArrayList(Fault)) !void {
    out.clearRetainingCapacity();
    const n = c.nets;
    for (c.devices(), 0..) |dev, i| {
        const at: u32 = @intCast(i);
        if (dev.pins[1] != dev.pins[2]) {
            var r = c.*;
            std.mem.swap(u8, &r.devs[i].pins[1], &r.devs[i].pins[2]);
            try push(gpa, out, "sd", at, r);
        }
        for (0..3) |t| {
            for (0..n) |k| {
                if (k == dev.pins[t]) continue;
                var r = c.*;
                r.devs[i].pins[t] = @intCast(k);
                try push(gpa, out, "term", at * 16 + @as(u32, @intCast(t * 4 + k)), r);
            }
            var on_net: usize = 0;
            for (c.devices()) |d| for (d.pinsOf()) |p| {
                on_net += @intFromBool(p == dev.pins[t]);
            };
            if (on_net >= 2) {
                var r = c.*;
                r.ports[n] = true;
                r.nets = n + 1;
                r.devs[i].pins[t] = n;
                try push(gpa, out, "open", at * 4 + @as(u32, @intCast(t)), r);
            }
        }
        var model = c.*;
        model.devs[i].model = if (dev.model == .n) .p else .n;
        try push(gpa, out, "model", at, model);
        var deleted = c.*;
        deleted.remove(i);
        try push(gpa, out, "delete", at, deleted);
        var added = c.*;
        added.push(dev);
        try push(gpa, out, "add", at, added);
        for ([_]i64{ 19, 21 }) |delta| {
            var r = c.*;
            r.devs[i].w += @divTrunc(dev.w * delta, 1000);
            try push(gpa, out, if (delta == 19) "w+1.9" else "w+2.1", at, r);
        }
    }
    var fresh = c.*;
    fresh.ports[n] = true;
    fresh.nets = n + 1;
    fresh.push(Dev.mos(.n, n - 1, 0, n));
    try push(gpa, out, "add/new", 0, fresh);
    for (0..n) |a| for (a + 1..n) |b| {
        var r = c.*;
        for (r.devs[0..r.ndevs]) |*d| for (d.pins[0..d.npins]) |*p| {
            if (p.* == b) p.* = @intCast(a);
        };
        try push(gpa, out, "short", @intCast(a * 8 + b), r);
    };
}

// ---- private ----

fn lessCount(_: void, a: [2]u8, b: [2]u8) bool {
    return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
}

fn code(d: *const Dev, perm: []const u8) u64 {
    const g: u64 = perm[d.pins[0]];
    const s: u64 = perm[d.pins[1]];
    const d2: u64 = perm[d.pins[2]];
    const model: u64 = @intFromBool(d.model == .p);
    const size: u64 = @intCast(d.w << 20 | d.l);
    return model << 60 | g << 56 | @min(s, d2) << 52 | @max(s, d2) << 48 | size;
}

/// Over every renaming `perm` keeping each net within its count's rank
/// range, the least sorted code list.
fn searchKey(c: *const Circuit, rank: *const [oracle.max_nets][2]u8, perm: *[oracle.max_nets]u8, used: *[oracle.max_nets]bool, at: usize, best: *Key) void {
    if (at == c.nets) {
        var k: Key = @splat(std.math.maxInt(u64));
        for (c.devices(), 0..) |*d, i| k[i] = code(d, perm[0..c.nets]);
        std.mem.sortUnstable(u64, &k, {}, std.sort.asc(u64));
        if (std.mem.order(u64, &k, best) == .lt) best.* = k;
        return;
    }
    for (rank[at][0]..rank[at][1]) |target| {
        if (used[target]) continue;
        used[target] = true;
        perm[at] = @intCast(target);
        searchKey(c, rank, perm, used, at + 1, best);
        used[target] = false;
    }
}

fn pick(gpa: Allocator, nets: u8, devs: []const Dev, seen: *std.AutoHashMapUnmanaged(Key, void), out: *std.ArrayList(Circuit)) !void {
    var used: u32 = 0;
    for (devs) |d| for (d.pinsOf()) |p| {
        used |= @as(u32, 1) << @intCast(p);
    };
    if (@popCount(used) != nets) return;
    const c = Circuit.init(nets, devs);
    const gop = try seen.getOrPut(gpa, key(&c));
    if (!gop.found_existing) try out.append(gpa, c);
}

fn push(gpa: Allocator, out: *std.ArrayList(Fault), kind: []const u8, at: u32, r: Circuit) !void {
    try out.append(gpa, .{ .kind = kind, .at = at, .circuit = r.compact() });
}

/// The classes of one to three `nmos`/`pmos` on nets `0..nets`, not every
/// net used, by Burnside's lemma: the mean over the renamings of the nets
/// of the circuits each fixes, a circuit a multiset of device types (model,
/// gate, unordered channel ends) and the multisets of `m` types a renaming
/// fixes the `x^m` coefficient of the product over its cycles of
/// `1/(1 - x^length)` (Pólya). No canonical form and none of `key`.
fn orbits(nets: usize) usize {
    var types: [2 * 4 * 4 * 4][4]usize = undefined;
    var ntypes: usize = 0;
    for (0..2) |model| for (0..nets) |g| for (0..nets) |s| for (s..nets) |d| {
        types[ntypes] = .{ model, g, s, d };
        ntypes += 1;
    };
    var group: usize = 0;
    var fixed: usize = 0;
    var code_n: usize = 0;
    const total = std.math.pow(usize, nets, nets);
    while (code_n < total) : (code_n += 1) {
        var rename: [4]usize = undefined;
        var rest = code_n;
        for (0..nets) |k| {
            rename[k] = rest % nets;
            rest /= nets;
        }
        const distinct = for (0..nets) |k| (if (std.mem.indexOfScalar(usize, rename[k + 1 .. nets], rename[k]) != null) break false) else true;
        if (!distinct) continue;
        group += 1;
        var seen: [128]bool = @splat(false);
        var series = [4]usize{ 1, 0, 0, 0 };
        for (0..ntypes) |start| {
            var at = start;
            var len: usize = 0;
            while (!seen[at]) {
                seen[at] = true;
                len += 1;
                const t = types[at];
                const s = rename[t[2]];
                const d = rename[t[3]];
                const next = [4]usize{ t[0], rename[t[1]], @min(s, d), @max(s, d) };
                at = for (types[0..ntypes], 0..) |u, i| (if (std.mem.eql(usize, &u, &next)) break i) else unreachable;
            }
            if (len > 0) {
                var degree = len;
                while (degree < series.len) : (degree += 1) series[degree] += series[degree - len];
            }
        }
        fixed += series[1] + series[2] + series[3];
    }
    std.debug.assert(fixed % group == 0);
    return fixed / group;
}

test "the enumeration has every canonical circuit" {
    // Oracle: differential against an independent count, `orbits`, by
    // Burnside's lemma rather than a canonical form. A class on nets 0..n
    // uses some k <= n of them, so `circuitsInto` lists orbits(n) -
    // orbits(n - 1) for n nets and orbits(4), the 4223 the module docs
    // state, in all.
    const gpa = std.testing.allocator;
    var all: std.ArrayList(Circuit) = .empty;
    defer all.deinit(gpa);
    try circuitsInto(gpa, &all);
    for (1..5) |nets| {
        var count: usize = 0;
        for (all.items) |c| count += @intFromBool(c.nets == nets);
        try std.testing.expectEqual(orbits(nets) - orbits(nets - 1), count);
    }
    try std.testing.expectEqual(@as(usize, 4223), all.items.len);
    try std.testing.expectEqual(@as(usize, 4223), orbits(4));
}
