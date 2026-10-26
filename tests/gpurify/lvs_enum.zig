//! The LVS enumeration and its single faults: every circuit of one to
//! three `nmos`/`pmos` over one to four nets, every net used, one per
//! isomorphism class, and each fault the module docs list. Ported from
//! tests/exhaustive/lvs.rs (`Key`, `key`, `circuits`, `faults`).
//!
//! Contents:
//! - `pub const Key`, `pub fn key(c: *const Circuit) Key`
//! - `pub const Fault = struct { name, circuit, blocked }`
//! - `pub fn circuitsInto(arena: Allocator, out: *std.ArrayList(Circuit)) !void`
//! - `pub fn faultsInto(arena: Allocator, c: *const Circuit, out: *std.ArrayList(Fault)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const circuit = @import("lvs_circuit.zig");
const Model = circuit.Model;
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;

/// An enumerated circuit (MOS only, every net a port) up to renaming nets
/// and devices and swapping source with drain: the least sorted list of
/// device codes over every renaming of the nets that lists them by how
/// many gates and channel ends each carries. An isomorphism keeps those
/// counts, so it maps the renamings of one circuit onto the other's, and
/// the least is the same.
pub const Key = [4]u64;

/// One single fault of a reference: its label, the faulted (compacted)
/// reference, and the catalog rows it proves.
pub const Fault = struct { name: []const u8, circuit: Circuit, blocked: []const []const u8 };

/// Most nets `keyOf` takes: a fault adds one to the enumeration's four.
const max_nets = 8;

pub fn key(c: *const Circuit) Key {
    return keyOf(c.devs, c.nets());
}

/// Every circuit of one to three `nmos`/`pmos` over one to four nets, every
/// net used, one per isomorphism class, in Rust's order.
pub fn circuitsInto(arena: Allocator, out: *std.ArrayList(Circuit)) !void {
    for (1..5) |nets| {
        var types: std.ArrayList(Dev) = .empty;
        for ([_]Model{ .n, .p }) |model| for (0..nets) |g| for (0..nets) |s| for (s..nets) |d| {
            try types.append(arena, Dev.mos(model, g, s, d));
        };
        var seen: std.AutoHashMapUnmanaged(Key, void) = .empty;
        const t = types.items;
        for (0..t.len) |a| {
            try pick(arena, &seen, nets, &.{t[a]}, out);
            for (a..t.len) |b| {
                try pick(arena, &seen, nets, &.{ t[a], t[b] }, out);
                for (t[b..]) |third| try pick(arena, &seen, nets, &.{ t[a], t[b], third }, out);
            }
        }
    }
}

/// Every single fault of the module docs applied to `c`'s reference, plus
/// the source/drain swaps, which must keep the verdict, in Rust's order.
pub fn faultsInto(arena: Allocator, c: *const Circuit, out: *std.ArrayList(Fault)) !void {
    const n = c.nets();
    const terminals = [_][]const u8{ "g", "s", "d" };
    for (c.devs, 0..) |dev, i| {
        if (dev.pins[1] != dev.pins[2]) {
            var r = try c.clone(arena);
            std.mem.swap(usize, &r.devs[i].pins[1], &r.devs[i].pins[2]);
            try push(arena, out, try std.fmt.allocPrint(arena, "sd/{d}", .{i}), r, &.{"LVS-030"});
        }
        for (terminals, 0..) |terminal, t| {
            for (0..n) |k| {
                if (k == dev.pins[t]) continue;
                var r = try c.clone(arena);
                r.devs[i].pins[t] = k;
                try push(arena, out, try std.fmt.allocPrint(arena, "term/{d}{s}-n{d}", .{ i, terminal, k }), r, &.{"LVS-015"});
            }
            const net = dev.pins[t];
            var on_net: usize = 0;
            for (c.devs) |*d| for (d.pinsOf()) |p| {
                if (p == net) on_net += 1;
            };
            if (on_net >= 2) {
                var r = try withNet(arena, c);
                r.devs[i].pins[t] = n;
                try push(arena, out, try std.fmt.allocPrint(arena, "open/{d}{s}", .{ i, terminal }), r, &.{"LVS-015"});
            }
        }
        var swapped = try c.clone(arena);
        swapped.devs[i].model = if (dev.model == .n) .p else .n;
        try push(arena, out, try std.fmt.allocPrint(arena, "model/{d}", .{i}), swapped, &.{ "LVS-011", "LVS-013" });
        var deleted = try c.clone(arena);
        var kept: std.ArrayList(Dev) = .empty;
        try kept.appendSlice(arena, c.devs[0..i]);
        try kept.appendSlice(arena, c.devs[i + 1 ..]);
        deleted.devs = kept.items;
        try push(arena, out, try std.fmt.allocPrint(arena, "delete/{d}", .{i}), deleted, &.{"LVS-012"});
        var added = try c.clone(arena);
        added.devs = try std.mem.concat(arena, Dev, &.{ c.devs, &.{dev} });
        try push(arena, out, try std.fmt.allocPrint(arena, "add/copy{d}", .{i}), added, &.{ "LVS-012", "LVS-040" });
        for ([_]struct { []const u8, i64 }{ .{ "1.9", 19 }, .{ "2.1", 21 } }) |pd| {
            var r = try c.clone(arena);
            r.devs[i].w += @divTrunc(dev.w * pd[1], 1000);
            try push(arena, out, try std.fmt.allocPrint(arena, "w+{s}/{d}", .{ pd[0], i }), r, &.{ "LVS-014", "LVS-060" });
        }
    }
    var fresh = try withNet(arena, c);
    fresh.devs = try std.mem.concat(arena, Dev, &.{ c.devs, &.{Dev.mos(.n, n - 1, 0, n)} });
    try push(arena, out, "add/new", fresh, &.{"LVS-012"});
    for (0..n) |a| for (a + 1..n) |b| {
        const r = try c.clone(arena);
        for (r.devs) |*d| for (d.pins[0..d.npins]) |*p| {
            if (p.* == b) p.* = a;
        };
        try push(arena, out, try std.fmt.allocPrint(arena, "short/n{d}+n{d}", .{ a, b }), r, &.{"LVS-015"});
    };
}

// ---- private ----

/// `c` with one more port net, `n<nets>`.
fn withNet(arena: Allocator, c: *const Circuit) !Circuit {
    var r = try c.clone(arena);
    r.names = try std.mem.concat(arena, []const u8, &.{ c.names, &.{try std.fmt.allocPrint(arena, "n{d}", .{c.nets()})} });
    r.ports = try std.mem.concat(arena, bool, &.{ c.ports, &.{true} });
    return r;
}

fn push(arena: Allocator, out: *std.ArrayList(Fault), name: []const u8, r: Circuit, blocked: []const []const u8) !void {
    try out.append(arena, .{ .name = name, .circuit = try r.compact(arena), .blocked = blocked });
}

/// `devs` as a circuit on `nets` nets when every net is used and its class
/// is new.
fn pick(arena: Allocator, seen: *std.AutoHashMapUnmanaged(Key, void), nets: usize, devs: []const Dev, out: *std.ArrayList(Circuit)) !void {
    var used: u32 = 0;
    for (devs) |*d| for (d.pinsOf()) |p| {
        used |= @as(u32, 1) << @intCast(p);
    };
    if (@popCount(used) != nets) return;
    if ((try seen.getOrPut(arena, keyOf(devs, nets))).found_existing) return;
    try out.append(arena, try Circuit.init(arena, nets, devs));
}

fn code(d: *const Dev, perm: []const usize) u64 {
    const g: u64 = perm[d.pins[0]];
    const s = perm[d.pins[1]];
    const d2 = perm[d.pins[2]];
    const model: u64 = @intFromBool(d.model == .p);
    const size: u64 = @intCast(d.w << 20 | d.l);
    return model << 60 | g << 56 | @as(u64, @min(s, d2)) << 52 | @as(u64, @max(s, d2)) << 48 | size;
}

/// `key` over a device list on `n` nets: no allocation. As Rust's, only
/// the first four devices are coded.
fn keyOf(devs: []const Dev, n: usize) Key {
    std.debug.assert(n <= max_nets);
    var count: [max_nets][2]u8 = @splat(.{ 0, 0 });
    for (devs) |d| {
        count[d.pins[0]][0] += 1;
        count[d.pins[1]][1] += 1;
        count[d.pins[2]][1] += 1;
    }
    // Each net's range of ranks among the sorted counts.
    var rank: [max_nets][2]usize = undefined;
    for (0..n) |k| {
        var lo: usize = 0;
        var hi: usize = 0;
        for (0..n) |j| {
            const order = std.math.order(@as(u16, count[j][0]) << 8 | count[j][1], @as(u16, count[k][0]) << 8 | count[k][1]);
            if (order == .lt) lo += 1;
            if (order != .gt) hi += 1;
        }
        rank[k] = .{ lo, hi };
    }
    var best: Key = @splat(std.math.maxInt(u64));
    var perm: [max_nets]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    permute(devs, n, &rank, &perm, 0, &best);
    return best;
}

/// Every permutation of `perm[0..n]` from `at` on, each that respects the
/// ranks folded into `best` as its sorted codes.
fn permute(devs: []const Dev, n: usize, rank: *const [max_nets][2]usize, perm: *[max_nets]usize, at: usize, best: *Key) void {
    if (at == n) {
        for (0..n) |k| if (perm[k] < rank[k][0] or perm[k] >= rank[k][1]) return;
        var k: Key = @splat(std.math.maxInt(u64));
        for (devs[0..@min(4, devs.len)], 0..) |*d, i| k[i] = code(d, perm[0..n]);
        std.mem.sort(u64, &k, {}, std.sort.asc(u64));
        if (std.mem.order(u64, &k, best) == .lt) best.* = k;
        return;
    }
    for (at..n) |i| {
        std.mem.swap(usize, &perm[at], &perm[i]);
        permute(devs, n, rank, perm, at + 1, best);
        std.mem.swap(usize, &perm[at], &perm[i]);
    }
}
