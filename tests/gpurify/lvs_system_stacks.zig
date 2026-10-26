//! The brute-force oracle on the flattened system: every stack of two
//! enumerated circuits, bonded net to net, against its own system netlist,
//! every single fault of either die's subcircuit, and every missing and
//! swapped bump; the oracle (`lvs_oracle.equivalent`) reads a flat circuit
//! the test builds from the circuits and the bumps it drew, never from the
//! tool. Ported from tests/exhaustive/lvs/system.rs (`Stack`, `classes`,
//! `flat`, `drawn_joins`, `stack_reference`, `Case`, `stack_cases`,
//! `stacks`, `verdict`, `agree`, `flat_nets`).
//!
//! Contents:
//! - `pub const Stack = struct { a, b, bonds }`
//! - `pub fn stacksInto(arena: Allocator, count: usize, seed: u64, out: *std.ArrayList(Stack)) !void`
//! - `pub fn flat(arena: Allocator, a: *const Circuit, b: *const Circuit, joined: []const [2]usize) !Circuit`
//! - `pub fn flatNets(arena: Allocator, stack: *const Stack) ![2][]const usize`
//! - `pub fn stackReference(arena: Allocator, stack: *const Stack, fa: *const Circuit, fb: *const Circuit) !struct { []const u8, Circuit }`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const paths = @import("paths");
const Rng = @import("testgen").Rng;
const circuit = @import("lvs_circuit.zig");
const Circuit = circuit.Circuit;
const Dev = circuit.Dev;
const oracle = @import("lvs_oracle.zig");
const lvs_enum = @import("lvs_enum.zig");
const sys = @import("lvs_system.zig");
const gpa = testing.allocator;

/// Two enumerated circuits stacked: die `XA`'s net `bonds[s][0]` meets die
/// `XB`'s net `bonds[s][1]` in bump slot `s`.
pub const Stack = struct { a: Circuit, b: Circuit, bonds: []const [2]usize };

/// A bump of a case: a net and its slot.
const Slot = [2]usize;

/// One verdict the oracle decides: a stack drawn with `XB`'s bumps in
/// `b_slots`, against a netlist with these cells.
const Case = struct {
    name: []const u8,
    a_slots: []const Slot,
    b_slots: []const Slot,
    reference: []const u8,
    layout_flat: Circuit,
    reference_flat: Circuit,
};

/// Stacks of two enumerated circuits of at most two devices each, drawn by
/// `seed`: the first `min(2, nets)` nets of `XA` bonded to distinct nets of
/// `XB`, so the flattened system has at most six nets, seven after a fault,
/// within the oracle's reach.
pub fn stacksInto(arena: Allocator, count: usize, seed: u64, out: *std.ArrayList(Stack)) !void {
    var all: std.ArrayList(Circuit) = .empty;
    try lvs_enum.circuitsInto(arena, &all);
    var small: std.ArrayList(Circuit) = .empty;
    for (all.items) |c| if (c.devs.len <= 2) try small.append(arena, c);
    var rng: Rng = .init(seed);
    for (0..count) |_| {
        const a = small.items[@intCast(rng.below(small.items.len))];
        const b = small.items[@intCast(rng.below(small.items.len))];
        const k = @min(a.nets(), b.nets(), 2);
        var free: std.ArrayList(usize) = .empty;
        for (0..b.nets()) |n| try free.append(arena, n);
        const bonds = try arena.alloc([2]usize, k);
        for (bonds, 0..) |*bond, i| bond.* = .{ i, free.orderedRemove(@intCast(rng.below(free.items.len))) };
        try out.append(arena, .{ .a = try a.clone(arena), .b = try b.clone(arena), .bonds = bonds });
    }
}

/// Two dies' circuits as flattened: `a`'s nets, then `b`'s, the pairs in
/// `joined` (`a` net, `b` net) merged (`classes`); every net a port.
pub fn flat(arena: Allocator, a: *const Circuit, b: *const Circuit, joined: []const [2]usize) !Circuit {
    const class, const next = try classes(arena, a.nets(), b.nets(), joined);
    var devs: std.ArrayList(Dev) = .empty;
    for ([_]struct { *const Circuit, usize }{ .{ a, 0 }, .{ b, a.nets() } }) |side| for (side[0].devs) |dev| {
        var moved = dev;
        for (moved.pins[0..moved.npins]) |*p| p.* = class[side[1] + p.*];
        try devs.append(arena, moved);
    };
    return Circuit.init(arena, next, devs.items);
}

/// Each die's nets as numbered in `flat(a, b, bonds)`.
pub fn flatNets(arena: Allocator, stack: *const Stack) ![2][]const usize {
    const na = stack.a.nets();
    const class, _ = try classes(arena, na, stack.b.nets(), stack.bonds);
    return .{ class[0..na], class[na..] };
}

/// The stack's system netlist with `fa` and `fb` as the two dies' cells,
/// wired by name: a bond's two pins share the top net `t<s>`, every other
/// port is a top net of its own. Returns the text and the flat circuit it
/// means: the pins of a bond whose name a fault removed join nothing.
pub fn stackReference(arena: Allocator, stack: *const Stack, fa: *const Circuit, fb: *const Circuit) !struct { []const u8, Circuit } {
    const ta = try topNets(arena, stack, fa, "XA", &stack.a, 0);
    const tb = try topNets(arena, stack, fb, "XB", &stack.b, 1);
    var ports: std.ArrayList([]const u8) = .empty;
    try ports.appendSlice(arena, ta);
    try ports.appendSlice(arena, tb);
    std.mem.sort([]const u8, ports.items, {}, lessString);
    var unique: std.ArrayList([]const u8) = .empty;
    for (ports.items) |p| if (unique.items.len == 0 or !std.mem.eql(u8, unique.items[unique.items.len - 1], p)) try unique.append(arena, p);
    const text = try sys.systemSpice(arena, &.{ .{ "DA", fa }, .{ "DB", fb } }, unique.items, &.{ .{ "XA", "DA", ta }, .{ "XB", "DB", tb } });
    var joined: std.ArrayList([2]usize) = .empty;
    for (stack.bonds) |bond| {
        const i = index(fa, &stack.a, bond[0]) orelse continue;
        const j = index(fb, &stack.b, bond[1]) orelse continue;
        try joined.append(arena, .{ i, j });
    }
    return .{ text, try flat(arena, fa, fb, joined.items) };
}

// ---- private ----

/// Each net of two circuits of `na` and `nb` nets (`a`'s, then `b`'s), as
/// numbered once the pairs in `joined` (`a` net, `b` net) are merged: a
/// class per merged set, by its lowest member. Returns the numbering and
/// the class count.
fn classes(arena: Allocator, na: usize, nb: usize, joined: []const [2]usize) !struct { []usize, usize } {
    const parent = try arena.alloc(usize, na + nb);
    for (parent, 0..) |*p, i| p.* = i;
    for (joined) |pair| {
        const x = root(parent, pair[0]);
        const y = root(parent, na + pair[1]);
        parent[@max(x, y)] = @min(x, y);
    }
    const class = try arena.alloc(usize, na + nb);
    @memset(class, std.math.maxInt(usize));
    var next: usize = 0;
    for (0..na + nb) |k| {
        const r = root(parent, k);
        if (class[r] == std.math.maxInt(usize)) {
            class[r] = next;
            next += 1;
        }
        class[k] = class[r];
    }
    return .{ class, next };
}

fn root(parent: []const usize, from: usize) usize {
    var x = from;
    while (parent[x] != x) x = parent[x];
    return x;
}

/// The drawn joins: for every slot both dies have a bump in, its two nets.
fn drawnJoins(arena: Allocator, a_slots: []const Slot, b_slots: []const Slot) ![]const [2]usize {
    var out: std.ArrayList([2]usize) = .empty;
    for (a_slots) |sa| for (b_slots) |sb| if (sb[1] == sa[1]) {
        try out.append(arena, .{ sa[0], sb[0] });
        break;
    };
    return out.items;
}

/// The top nets `c`'s ports land on: `t<s>` for a port named as bond `s`'s
/// net of `base` on `side`, else `<die>_<name>`.
fn topNets(arena: Allocator, stack: *const Stack, c: *const Circuit, die: []const u8, base: *const Circuit, side: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (c.names, c.ports) |name, port| {
        if (!port) continue;
        const bond: ?usize = for (stack.bonds, 0..) |b, s| (if (std.mem.eql(u8, base.names[b[side]], name)) break s) else null;
        try out.append(arena, if (bond) |s| try std.fmt.allocPrint(arena, "t{d}", .{s}) else try std.fmt.allocPrint(arena, "{s}_{s}", .{ die, name }));
    }
    return out.items;
}

fn index(c: *const Circuit, base: *const Circuit, net: usize) ?usize {
    for (c.names, 0..) |name, i| if (std.mem.eql(u8, name, base.names[net])) return i;
    return null;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The stack against its own netlist, against every single fault of either
/// die's cell (as the enumeration faults one circuit), and drawn with each
/// bump of `XB` missing and each pair of neighbours swapped.
fn stackCasesInto(arena: Allocator, stack: *const Stack, label: []const u8, out: *std.ArrayList(Case)) !void {
    const a_slots = try arena.alloc(Slot, stack.bonds.len);
    const b_slots = try arena.alloc(Slot, stack.bonds.len);
    for (stack.bonds, a_slots, b_slots, 0..) |b, *sa, *sb, s| {
        sa.* = .{ b[0], s };
        sb.* = .{ b[1], s };
    }
    try pushCase(arena, stack, out, try std.fmt.allocPrint(arena, "{s}/base", .{label}), a_slots, b_slots, &stack.a, &stack.b);
    var faults: std.ArrayList(lvs_enum.Fault) = .empty;
    try lvs_enum.faultsInto(arena, &stack.a, &faults);
    for (faults.items) |f| try pushCase(arena, stack, out, try std.fmt.allocPrint(arena, "{s}/a/{s}", .{ label, f.name }), a_slots, b_slots, &f.circuit, &stack.b);
    faults = .empty;
    try lvs_enum.faultsInto(arena, &stack.b, &faults);
    for (faults.items) |f| try pushCase(arena, stack, out, try std.fmt.allocPrint(arena, "{s}/b/{s}", .{ label, f.name }), a_slots, b_slots, &stack.a, &f.circuit);
    for (0..b_slots.len) |s| {
        var missing: std.ArrayList(Slot) = .empty;
        try missing.appendSlice(arena, b_slots);
        _ = missing.orderedRemove(s);
        try pushCase(arena, stack, out, try std.fmt.allocPrint(arena, "{s}/missing/{d}", .{ label, s }), a_slots, missing.items, &stack.a, &stack.b);
        if (s + 1 < b_slots.len) {
            const swapped = try arena.dupe(Slot, b_slots);
            swapped[s][1] = s + 1;
            swapped[s + 1][1] = s;
            try pushCase(arena, stack, out, try std.fmt.allocPrint(arena, "{s}/swapped/{d}", .{ label, s }), a_slots, swapped, &stack.a, &stack.b);
        }
    }
}

fn pushCase(arena: Allocator, stack: *const Stack, out: *std.ArrayList(Case), name: []const u8, a_slots: []const Slot, b_slots: []const Slot, fa: *const Circuit, fb: *const Circuit) !void {
    const reference, const reference_flat = try stackReference(arena, stack, fa, fb);
    const layout_flat = try flat(arena, &stack.a, &stack.b, try drawnJoins(arena, a_slots, b_slots));
    try out.append(arena, .{ .name = name, .a_slots = a_slots, .b_slots = b_slots, .reference = reference, .layout_flat = layout_flat, .reference_flat = reference_flat });
}

/// The tool's verdict on one case, with the dies drawn as it says.
fn verdict(arena: Allocator, case: *const Case, stack: *const Stack) !bool {
    const dies = [_]sys.DieSpec{
        sys.die("XA", try sys.dieLayout(arena, &stack.a, try bumps(arena, case.a_slots))),
        sys.die("XB", try sys.dieLayout(arena, &stack.b, try bumps(arena, case.b_slots))),
    };
    const system = try sys.systemJson(arena, &dies, &.{.{ .{ "XA", "bump" }, .{ "XB", "bump" } }}, null, null);
    var diag: @import("gpurify").system.Diagnostic = .{};
    const r = try sys.checkDies(arena, &dies, system, case.reference, &diag);
    return r.matched();
}

fn bumps(arena: Allocator, slots: []const Slot) ![]const sys.Bump {
    const out = try arena.alloc(sys.Bump, slots.len);
    for (slots, out) |s, *o| o.* = .{ .net = s[0], .slot = s[1], .face = "bump" };
    return out;
}

/// Every case of `count` stacks drawn by `seed`, the tool against the
/// oracle; fails listing every disagreement.
fn agree(count: usize, seed: u64) !void {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    var stacks: std.ArrayList(Stack) = .empty;
    try stacksInto(a, count, seed, &stacks);
    var broken: usize = 0;
    var matched: usize = 0;
    var total: usize = 0;
    for (stacks.items, 0..) |*stack, k| {
        var cases: std.ArrayList(Case) = .empty;
        try stackCasesInto(a, stack, try std.fmt.allocPrint(a, "stack{d}", .{k}), &cases);
        for (cases.items) |*case| {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const want = try oracle.equivalent(scratch.allocator(), &case.layout_flat, &case.reference_flat);
            const have = verdict(scratch.allocator(), case, stack);
            total += 1;
            matched += @intFromBool(want);
            const same = if (have) |h| h == want else |_| false;
            if (!same) {
                broken += 1;
                if (broken <= 40) std.debug.print("{s}: tool {any}, oracle {}\n", .{ case.name, have, want });
            }
        }
    }
    if (broken != 0) {
        std.debug.print("{d} of {d} cases disagree\n", .{ broken, total });
        return error.TestOracleDisagrees;
    }
    // Both verdicts occur.
    try testing.expect(matched > 0 and matched < total);
}

test "system LVS agrees with the brute-force oracle on the flattened system" {
    // Oracle: the brute-force isomorphism of the LVS enumeration
    // (`equivalent`) on the flattened system: the test flattens the two
    // circuits through the bumps it drew, and the netlist's two cells
    // through the bonds it wrote, and the tool's verdict on the drawn dies
    // must be the oracle's, on a seeded sample of stacks with every die
    // fault and every missing and swapped bump.
    try agree(6, 0x5_7AC6);
}

test "system LVS agrees with the brute-force oracle at nightly depth" {
    // Oracle: the brute-force isomorphism of the LVS enumeration on the
    // flattened system, as in the merge-depth test, over a hundred stacks.
    // Rust's `#[ignore]` nightly test: run under -Dslow-tests.
    if (!paths.slow_tests) return;
    try agree(100, 0x5_7AC7);
}
