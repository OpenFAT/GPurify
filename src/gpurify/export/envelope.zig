//! A nominal network and its process corners as three aligned networks:
//! per slot, the smallest value, the nominal's, and the largest, which SPEF
//! writes as `min:typ:max`. Ported from src/export/parasitic.rs (`slots`,
//! `envelope`).
//!
//! A slot is canonical order's key less the value: near node, far node
//! (ground first), kind. Elements sharing a slot combine first:
//! capacitances and mutual inductances add, resistances and inductances
//! (substrate included) combine in parallel, folded in row order. A
//! capacitance a network lacks reads 0 there (a coupling a corner's
//! thinner layer leaves out of the closed forms' reach); any other missing
//! element is refused.
//!
//! Contents:
//! - `pub fn envelopeInto(gpa: Allocator, nominal: *const ParasiticNetwork, corners: []const *const ParasiticNetwork, out: *[3]ParasiticNetwork, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const network_mod = @import("extract").network;
const Kind = network_mod.Kind;
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const header = @import("header.zig");
const Error = header.Error;
const Diagnostic = header.Diagnostic;

/// One slot of one network: `from << 72 | far << 8 | kind`, far 0 for
/// ground and node + 1 otherwise, so keys sort as canonical order does.
const Slot = struct { key: u128, value: f64 };

/// Fills `out` (each cleared) with the low, nominal and high networks on
/// `nominal`'s nodes. `corners` must have `nominal`'s nodes; `gpa` holds
/// scratch until return.
pub fn envelopeInto(gpa: Allocator, nominal: *const ParasiticNetwork, corners: []const *const ParasiticNetwork, out: *[3]ParasiticNetwork, diag: *Diagnostic) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try arena.alloc([]const Slot, corners.len + 1);
    all[0] = try slots(arena, nominal);
    for (corners, all[1..]) |corner, *s| s.* = try slots(arena, corner);
    var keys: std.ArrayList(u128) = .empty;
    for (all) |s| for (s) |slot| try keys.append(arena, slot.key);
    std.mem.sortUnstable(u128, keys.items, {}, std.sort.asc(u128));
    for (out) |*n| {
        n.clear();
        try n.node_net.appendSlice(gpa, nominal.node_net.items);
        try n.node_layer.appendSlice(gpa, nominal.node_layer.items);
    }
    const cursor = try arena.alloc(usize, all.len);
    @memset(cursor, 0);
    const values = try arena.alloc(f64, all.len);
    for (keys.items, 0..) |key, i| {
        if (i > 0 and keys.items[i - 1] == key) continue;
        const kind: Kind = @fromBackingInt(@intCast(@as(u8, @truncate(key))));
        for (all, cursor, values) |s, *at, *v| {
            if (at.* < s.len and s[at.*].key == key) {
                v.* = s[at.*].value;
                at.* += 1;
            } else switch (kind) {
                // A coupling out of reach at one stack is no coupling there.
                .ground_cap, .coupling_cap => v.* = 0.0,
                .resistance, .inductance, .mutual_inductance, .substrate_resistance => {
                    diag.what = "a resistance or inductance at one process corner and not another";
                    return error.Unrepresentable;
                },
            }
        }
        var low = std.math.inf(f64);
        var high = -std.math.inf(f64);
        for (values) |v| {
            low = @min(low, v);
            high = @max(high, v);
        }
        const from: NodeId = @fromBackingInt(@intCast(key >> 72));
        const far_plus: u64 = @truncate(key >> 8);
        const to: NodeId = if (far_plus == 0) .ground else @fromBackingInt(@intCast(far_plus - 1));
        for (out, [3]f64{ low, values[0], high }) |*n, raw| try n.push(gpa, from, to, kind, raw);
    }
}

// ---- private ----

/// `network`'s elements by slot, ascending, those sharing one combined in
/// row order (the sort is stable).
fn slots(arena: Allocator, network: *const ParasiticNetwork) Allocator.Error![]const Slot {
    const raw = try arena.alloc(Slot, network.elementCount());
    for (raw, network.from.items, network.to.items, network.kind.items, network.value.items) |*s, from, to, kind, value| {
        const far: u128 = if (to == .ground) 0 else @as(u128, @backingInt(to)) + 1;
        s.* = .{ .key = @as(u128, @backingInt(from)) << 72 | far << 8 | @backingInt(kind), .value = value };
    }
    std.mem.sort(Slot, raw, {}, keyLess);
    var n: usize = 0;
    for (raw) |s| {
        if (n > 0 and raw[n - 1].key == s.key) {
            const a = raw[n - 1].value;
            raw[n - 1].value = switch (@as(Kind, @fromBackingInt(@intCast(@as(u8, @truncate(s.key)))))) {
                .resistance, .inductance, .substrate_resistance => a * s.value / (a + s.value),
                .ground_cap, .coupling_cap, .mutual_inductance => a + s.value,
            };
        } else {
            raw[n] = s;
            n += 1;
        }
    }
    return raw[0..n];
}

fn keyLess(_: void, a: Slot, b: Slot) bool {
    return a.key < b.key;
}
