//! The LVS oracle's own tests and the relations that compare runs: gate
//! recognition, a missing instance named once, the oracle on hand
//! derivations, and the enumeration against Burnside's count. Ported from
//! tests/exhaustive/lvs.rs (`mod tests`: `reassigning_a_gate_group_s_inputs_keeps_a_match`,
//! `gate_recognition_swaps_inputs_only_where_defined`,
//! `a_missing_instance_is_named_once_at_its_outermost`,
//! `the_oracle_agrees_with_hand_derivations`, `orbits`,
//! `the_enumeration_has_every_canonical_circuit`, `report`, `sample`).
//!
//! Contents:
//! - `pub fn report(arena: Allocator, layout: Layout, reference: []const u8) ![]const []const u8`
//! - `pub fn sample(arena: Allocator) ![]const Circuit`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const harness = @import("harness.zig");
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const Controls = @import("lvs_controls.zig").Controls;
const oracle = @import("lvs_oracle.zig");
const fixture = @import("lvs_fixture.zig");
const lvs_enum = @import("lvs_enum.zig");
const gpa = testing.allocator;

/// A run of `layout` on the full deck against `reference`, as sorted text
/// with names resolved: every rule row and every finding, then whether LVS
/// matched (`matched true`, `matched false`, `matched none`).
pub fn report(arena: Allocator, layout: Layout, reference: []const u8) ![]const []const u8 {
    var f: Fixture = .init("lvs/relation", &.{"LVS-019"}, circuit.full_deck, fixture.lvs);
    f.layout = layout;
    f.reference = reference;
    const r = try harness.run(arena, &f);
    const strings = &r.loaded.strings;
    var lines: std.ArrayList([]const u8) = .empty;
    for (r.outputs.runs.items) |row| try lines.append(arena, switch (row.outcome) {
        .ran => try std.fmt.allocPrint(arena, "{s} ran", .{strings.resolve(row.rule)}),
        .refused => try std.fmt.allocPrint(arena, "{s} refused", .{strings.resolve(row.rule)}),
        .skipped => |why| try std.fmt.allocPrint(arena, "{s} skipped({t})", .{ strings.resolve(row.rule), why }),
    });
    const v = &r.outputs.violations;
    for (0..v.len()) |i| {
        const row = v.get(@intCast(i));
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s} {t}({f}) ({d}, {d})", .{ strings.resolve(row.rule), row.measured.kind, row.measured, row.at.x, row.at.y }));
    }
    std.mem.sort([]const u8, lines.items, {}, lessString);
    const matched: []const u8 = if (r.outputs.lvs) |t| (if (t.verdict == .match) "true" else "false") else "none";
    try lines.append(arena, try std.fmt.allocPrint(arena, "matched {s}", .{matched}));
    return lines.items;
}

/// Every one-device circuit of the enumeration and every 211th other
/// (ponytail: a fixed stride, not a seeded draw; the fixtures sample the
/// rest).
pub fn sample(arena: Allocator) ![]const Circuit {
    var all: std.ArrayList(Circuit) = .empty;
    try lvs_enum.circuitsInto(arena, &all);
    var out: std.ArrayList(Circuit) = .empty;
    for (all.items, 0..) |c, index| if (c.devs.len == 1 or index % 211 == 0) try out.append(arena, c);
    return out.items;
}

// ---- private ----

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The NAND2 of the gate fixtures: its stack's gates `top` and `bottom`,
/// the lower stacked transistor `wide` nm wide.
fn nand(arena: Allocator, top: usize, bottom: usize, wide: i64) !Circuit {
    const c = try Circuit.init(arena, 6, &.{
        Dev.mos(.n, top, 4, 2),
        Dev.mos(.n, bottom, 3, 4).sized(wide, 150),
        Dev.mos(.p, 0, 5, 2),
        Dev.mos(.p, 1, 5, 2),
        Dev.mos(.n, 0, 3, 5).sized(500, 150),
    });
    return c.internal(arena, 4);
}

/// The classes of one to three `nmos`/`pmos` on nets `0..nets`, not every
/// net used, under renaming nets and devices and swapping source with
/// drain, by Burnside's lemma: the mean, over the renamings of the nets,
/// of the circuits each one fixes. A circuit is a multiset of device types
/// (model, gate, unordered channel ends), and the multisets of `m` types a
/// renaming fixes are the `x^m` coefficient of the product, over its
/// cycles on the types, of `1 / (1 - x^length)` (Pólya). No canonical form
/// and none of `key`, `circuitsInto` or the oracle's permutations.
fn orbits(arena: Allocator, nets: usize) !usize {
    var types: std.ArrayList([4]usize) = .empty;
    for (0..2) |model| for (0..nets) |g| for (0..nets) |s| for (s..nets) |d| {
        try types.append(arena, .{ model, g, s, d });
    };
    var group: usize = 0;
    var fixed: usize = 0;
    const seen = try arena.alloc(bool, types.items.len);
    for (0..std.math.pow(usize, nets, nets)) |code| {
        // Net k goes to digit k of `code` in base `nets`: every map of the
        // nets, and a renaming where the digits are distinct.
        var rest = code;
        var rename: [4]usize = undefined;
        for (0..nets) |k| {
            rename[k] = rest % nets;
            rest /= nets;
        }
        const distinct = for (0..nets) |k| {
            if (std.mem.findScalar(usize, rename[k + 1 .. nets], rename[k]) != null) break false;
        } else true;
        if (!distinct) continue;
        group += 1;
        @memset(seen, false);
        var series: [4]usize = .{ 1, 0, 0, 0 };
        for (0..types.items.len) |begin| {
            var at = begin;
            var length: usize = 0;
            while (!seen[at]) {
                seen[at] = true;
                length += 1;
                const t = types.items[at];
                const s = rename[t[2]];
                const d = rename[t[3]];
                const next: [4]usize = .{ t[0], rename[t[1]], @min(s, d), @max(s, d) };
                at = for (types.items, 0..) |u, i| (if (std.mem.eql(usize, &u, &next)) break i) else unreachable; // a renaming permutes the types
            }
            if (length > 0) for (length..series.len) |degree| {
                series[degree] += series[degree - length];
            };
        }
        fixed += series[1] + series[2] + series[3];
    }
    try testing.expectEqual(0, fixed % group); // Burnside: a whole number of orbits
    return fixed / group;
}

test "reassigning a gate group's inputs keeps a match" {
    // LVS-047: reassigning a group's inputs never changes a match under
    // `lvs recognize_gates`.
    // Oracle: metamorphic relation. Each circuit of `sample` (whose
    // parallel transistors on different gates are groups) drawn and
    // compared with every reassignment of its groups' gates
    // (`gateReassignmentsInto`) matches with gates recognised, as it
    // matches itself; a reassignment the tool reads as another circuit
    // breaks it. The NAND2 of the fixtures, whose stack is a series group,
    // is held to the same.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nand2 = try (try Circuit.init(a, 6, &.{
        Dev.mos(.n, 0, 4, 2),
        Dev.mos(.n, 1, 3, 4),
        Dev.mos(.p, 0, 5, 2),
        Dev.mos(.p, 1, 5, 2),
        Dev.mos(.n, 0, 3, 5).sized(500, 150),
    })).internal(a, 4);
    const gated: Controls = .{ .gates = true };
    const circuits = try std.mem.concat(a, Circuit, &.{ try sample(a), &.{nand2} });
    var checked: usize = 0;
    for (circuits) |*c| {
        var variants: std.ArrayList(Circuit) = .empty;
        try oracle.gateReassignmentsInto(a, c, &variants);
        if (variants.items.len < 2) continue;
        for (variants.items[1..]) |*variant| {
            var run_arena: std.heap.ArenaAllocator = .init(gpa);
            defer run_arena.deinit();
            const ra = run_arena.allocator();
            const f = try fixture.comparedUnder(ra, "lvs/gates/relation", &.{"LVS-047"}, c, variant, &gated);
            const r = try harness.run(ra, &f);
            const matched = if (r.outputs.lvs) |t| t.verdict == .match else false;
            if (!matched) {
                std.debug.print("{s} against {s}\n", .{ try c.code(a), try variant.code(a) });
                return error.TestGateReassignmentMismatched;
            }
            checked += 1;
        }
    }
    try testing.expect(checked >= 3); // reassignments compared
}

test "gate recognition swaps inputs only where defined" {
    // LVS-047: the gate fixtures' verdicts, derived by hand, so the
    // fixtures cannot pass by both sides agreeing on nothing.
    // Oracle: hand-derived from Guardian's definition ("all N input
    // terminals are swappable"): a NAND2 whose stack order is swapped is
    // the same gate once gates are recognised and another circuit without;
    // one whose stacked transistors differ in width is not reduced, so the
    // swap stays a mismatch.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const gated: Controls = .{ .gates = true };
    try testing.expect(try oracle.equivalentUnder(a, &try nand(a, 0, 1, 1000), &try nand(a, 1, 0, 1000), &gated));
    try testing.expect(!try oracle.equivalent(a, &try nand(a, 0, 1, 1000), &try nand(a, 1, 0, 1000)));
    try testing.expect(!try oracle.equivalentUnder(a, &try nand(a, 0, 1, 2000), &try nand(a, 1, 0, 2000), &gated));
    var controlled: std.ArrayList(harness.Fixture) = .empty;
    try @import("lvs_controlled_topology.zig").fixturesInto(a, .merge, &controlled);
    const gate_fixture = for (controlled.items) |f| (if (std.mem.eql(u8, f.name, "lvs/gates/nand2_inputs_swapped/gates")) break f) else return error.TestNoGateFixture;
    const claims_match = for (gate_fixture.expect.items) |e| (if (e == .lvs and e.lvs) break true) else false;
    try testing.expect(claims_match);
}

test "a missing instance is named once at its outermost" {
    // LVS-017: the reference instances a mismatch leaves whole and
    // unpaired are named, outermost first, and only those.
    // Oracle: construct-from-answer. `TOP` holds an `nmos` and places `BLK`
    // (one `pmos`) as `X0` and `OUTER` as `X1`, which places `BLKH` (one
    // `nmos_hvt`) as `X2`, `X1` on nets of its own; three models, so no
    // device can stand in for another, and a block left out leaves the rest
    // to pair (refinement cannot pair what a missing neighbour perturbs,
    // which is why `X1` has nets of its own). Drawn whole, the run matches
    // and names no instance. With `X1`'s block not drawn, the one row is
    // `X1`, measured its one device, not `X1.X2` inside it; with `X0`'s not
    // drawn, the one row is `X0`. Breaks if an instance is named whose
    // devices paired, an inner one is named again, or a missing one is not
    // named.
    const reference =
        \\.subckt BLK a b c
        \\M0 b a c c pmos
        \\.ends
        \\.subckt BLKH a b c
        \\M0 b a c c nmos_hvt
        \\.ends
        \\.subckt OUTER a b c
        \\X2 a b c BLKH
        \\.ends
        \\.subckt TOP n0 n1 n2 n3 n4 n5
        \\M0 n1 n0 n2 n2 nmos
        \\X0 n1 n0 n2 BLK
        \\X1 n3 n4 n5 OUTER
        \\.ends
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const top = Dev.mos(.n, 0, 2, 1);
    const x0 = Dev.mos(.p, 1, 2, 0);
    const x1 = Dev.mos(.h, 3, 5, 4);
    const one = "lvs.unpaired_instance count(1) (0, 0)";
    const cases = [_]struct { []const Dev, []const []const u8 }{
        .{ &.{ top, x0, x1 }, &.{"matched true"} },
        .{ &.{ top, x0 }, &.{ one, "matched false" } },
        .{ &.{ top, x1 }, &.{ one, "matched false" } },
    };
    for (cases) |case| {
        const lines = try report(a, try circuit.draw(a, &try Circuit.init(a, 6, case[0])), reference);
        var instances: std.ArrayList([]const u8) = .empty;
        for (lines) |line| if (std.mem.startsWith(u8, line, "lvs.unpaired_instance") or std.mem.startsWith(u8, line, "matched")) try instances.append(a, line);
        try testing.expectEqual(case[1].len, instances.items.len);
        for (case[1], instances.items) |want, got| try testing.expectEqualStrings(want, got);
    }
}

test "the oracle agrees with hand derivations" {
    // Oracle: hand-derived from the documented semantics, case by case:
    // source and drain swap and device order are free, a short is not, W
    // within 2 % matches, parallel devices add width and series ones length.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const eq = oracle.equivalent;
    const inv = try Circuit.init(a, 4, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.p, 0, 3, 2) });
    try testing.expect(try eq(a, &inv, &inv));
    const swapped = try inv.clone(a);
    std.mem.swap(usize, &swapped.devs[0].pins[1], &swapped.devs[0].pins[2]);
    try testing.expect(try eq(a, &inv, &swapped)); // source and drain swap
    const reversed = try inv.clone(a);
    std.mem.reverse(Dev, reversed.devs);
    try testing.expect(try eq(a, &inv, &reversed)); // order never matters
    const short = try inv.clone(a);
    short.devs[1].pins[1] = 1;
    try testing.expect(!try eq(a, &inv, &try short.compact(a))); // a short
    const wide = try inv.clone(a);
    wide.devs[0].w = 1021;
    try testing.expect(!try eq(a, &inv, &wide)); // 2.1 % over
    wide.devs[0].w = 1019;
    try testing.expect(try eq(a, &inv, &wide)); // 1.9 % over
    const two = try Circuit.init(a, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 2, 1) });
    const one = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150)});
    try testing.expect(try eq(a, &two, &one)); // two in parallel are one twice as wide
    const stack = try Circuit.init(a, 4, &.{ Dev.mos(.n, 0, 1, 3), Dev.mos(.n, 0, 3, 2) });
    const long = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300)});
    try testing.expect(!try eq(a, &stack, &long)); // a port is never consumed
    try testing.expect(try eq(a, &try stack.internal(a, 3), &long)); // a stack is one twice as long
    try testing.expect(!try eq(a, &try fixture.polar(a, Dev.onPins(.d, &.{ 0, 1 })), &try fixture.polar(a, Dev.onPins(.d, &.{ 1, 0 })))); // a diode is ordered
    try testing.expect(try eq(a, &try fixture.polar(a, Dev.onPins(.r, &.{ 0, 1 })), &try fixture.polar(a, Dev.onPins(.r, &.{ 1, 0 })))); // a resistor is not
    const caps = try Circuit.init(a, 2, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 0, 1 }) });
    const cap = try Circuit.init(a, 2, &.{Dev.onPins(.c, &.{ 0, 1 })});
    try testing.expect(!try eq(a, &caps, &cap)); // two capacitors are not one
    const m2 = try Circuit.init(a, 2, &.{Dev.onPins(.c, &.{ 0, 1 }).times(2)});
    try testing.expect(try eq(a, &caps, &m2)); // but they are one of m = 2
    const pairs = try Circuit.init(a, 4, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 2, 3 }), Dev.onPins(.c, &.{ 2, 3 }) });
    const bare_and_m2 = try Circuit.init(a, 4, &.{ Dev.onPins(.c, &.{ 0, 1 }), Dev.onPins(.c, &.{ 2, 3 }).times(2) });
    try testing.expect(!try eq(a, &pairs, &bare_and_m2)); // four are not three
    const bare_one = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).writes(false, false)});
    try testing.expect(!try eq(a, &two, &bare_one)); // two unsized transistors are not one
    const bare_m2 = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).times(2).writes(false, false)});
    try testing.expect(try eq(a, &two, &bare_m2)); // but they are one of m = 2
    const w_only = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150).writes(true, false)});
    try testing.expect(try eq(a, &two, &w_only)); // W alone sums
    const l_only = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(2000, 150).writes(false, true)});
    try testing.expect(!try eq(a, &two, &l_only)); // L alone counts two
    const inner = try stack.internal(a, 3);
    const l_long = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300).writes(false, true)});
    try testing.expect(try eq(a, &inner, &l_long)); // L alone stacks
    const w_long = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 1, 2).sized(1000, 300).writes(true, false)});
    try testing.expect(!try eq(a, &inner, &w_long)); // W alone does not
    const res = try Circuit.init(a, 2, &.{Dev.onPins(.r, &.{ 0, 1 })});
    try testing.expect(try eq(a, &res, &try Circuit.init(a, 2, &.{Dev.onPins(.r, &.{ 0, 1 }).valued(200.0)}))); // 100 ohm/sq over 800 / 400
    try testing.expect(!try eq(a, &res, &try Circuit.init(a, 2, &.{Dev.onPins(.r, &.{ 0, 1 }).valued(210.0)}))); // 5 % over
    try testing.expect(try eq(a, &cap, &try Circuit.init(a, 2, &.{Dev.onPins(.c, &.{ 0, 1 }).valued(5.6e-16)}))); // 0.32 fF of plate and 0.24 fF of fringe
    try testing.expect(!try eq(a, &cap, &try Circuit.init(a, 2, &.{Dev.onPins(.c, &.{ 0, 1 }).valued(3.2e-16)}))); // the plate alone
    const diode = try Circuit.init(a, 2, &.{Dev.onPins(.d, &.{ 0, 1 })});
    try testing.expect(try eq(a, &diode, &try Circuit.init(a, 2, &.{Dev.onPins(.d, &.{ 0, 1 }).param("perim", 2.4e-6)}))); // 2 (800 + 400) nm
    try testing.expect(!try eq(a, &diode, &try Circuit.init(a, 2, &.{Dev.onPins(.d, &.{ 0, 1 }).param("perim", 2.64e-6)}))); // 10 % over
    const top = try Circuit.init(a, 3, &.{Dev.mos(.n, 0, 2, 1)});
    const block = try Circuit.init(a, 3, &.{Dev.mos(.p, 1, 2, 0)});
    const flat = try circuit.flatten(a, &top, &block, &.{ 1, 0, 2 });
    try testing.expectEqualSlices(usize, &.{ 0, 2, 1 }, flat.devs[1].pinsOf()); // the block lands on its ports
}

test "the enumeration has every canonical circuit" {
    // The enumeration has one circuit per class, for each count of nets.
    // Oracle: differential against an independent count, `orbits`, by
    // Burnside's lemma rather than a canonical form. A class on nets `0..n`
    // uses some `k <= n` of them and is, renumbered, a class on `0..k`
    // using every net, which is what `circuitsInto` lists for `k`: so it
    // lists `orbits(n) - orbits(n - 1)` for `n` nets, and `orbits(4)`, the
    // 4223 the module docs state, in all. A canonical form that splits a
    // class or merges two, or an enumeration that misses a circuit, changes
    // a count.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var all: std.ArrayList(Circuit) = .empty;
    try lvs_enum.circuitsInto(a, &all);
    for (1..5) |nets| {
        var n: usize = 0;
        for (all.items) |c| n += @intFromBool(c.nets() == nets);
        try testing.expectEqual(try orbits(a, nets) - try orbits(a, nets - 1), n);
    }
    try testing.expectEqual(4223, all.items.len);
    try testing.expectEqual(4223, try orbits(a, 4));
}
