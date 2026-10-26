//! LVS against its independent oracle over the enumeration, at the merge
//! depth: every one-device circuit and a seeded sample (one in 40) of the
//! rest, each drawn and compared with its own reference, the same cards in
//! reverse order, the same in Spectre, and every single fault of its
//! reference, deduplicated up to isomorphism; the tool's verdict must be
//! the oracle's. Ported from tests/exhaustive/lvs.rs (`enumerated`,
//! `fixtures` at `Depth::Merge`, the enumeration fixtures `lvs/enum/...`).

const std = @import("std");
const testing = std.testing;
const Rng = @import("testgen").Rng;
const oracle = @import("oracle.zig");
const Circuit = oracle.Circuit;
const oracle_enum = @import("oracle_enum.zig");
const harness = @import("harness.zig");
const gpa = testing.allocator;

/// One merge-depth circuit in this many, past the one-device ones.
const sample_one_in: u64 = 40;

// ---- private ----

/// The circuit's short code: `N0.1.2` per MOS, joined by `+`.
fn printCode(c: *const Circuit) void {
    for (c.devices(), 0..) |d, i| {
        if (i > 0) std.debug.print("+", .{});
        std.debug.print("{c}{d}.{d}.{d}", .{ d.model.letter(), d.pins[0], d.pins[1], d.pins[2] });
    }
}

/// `c` against each of its fixtures: its own reference, reversed, in
/// Spectre, and its faults deduplicated up to isomorphism (the
/// source/drain swaps kept, since they differ only in text). Returns how
/// many disagreed with the oracle, each printed.
fn enumerated(c: *const Circuit, faults: *std.ArrayList(oracle_enum.Fault), text: *std.ArrayList(u8)) !usize {
    var failed: usize = 0;
    var seen: std.AutoHashMapUnmanaged(oracle_enum.Key, void) = .empty;
    defer seen.deinit(gpa);
    try seen.put(gpa, oracle_enum.key(c), {});
    try harness.spiceInto(gpa, c, false, text);
    failed += try expect(c, "base", text.items, false, true);
    if (c.ndevs > 1) {
        try harness.spiceInto(gpa, c, true, text);
        failed += try expect(c, "reversed", text.items, false, true);
    }
    try harness.spectreInto(gpa, c, text);
    failed += try expect(c, "spectre", text.items, true, true);
    try oracle_enum.faultsInto(gpa, c, faults);
    for (faults.items) |f| {
        if (!std.mem.eql(u8, f.kind, "sd")) {
            const gop = try seen.getOrPut(gpa, oracle_enum.key(&f.circuit));
            if (gop.found_existing) continue;
        }
        try harness.spiceInto(gpa, &f.circuit, false, text);
        failed += try expect(c, f.kind, text.items, false, oracle.equivalent(c, &f.circuit));
    }
    return failed;
}

fn expect(c: *const Circuit, label: []const u8, text: []const u8, spectre: bool, want: bool) !usize {
    const got = try harness.lvsMatches(gpa, c, text, spectre);
    if (got == want) return 0;
    std.debug.print("lvs/enum/n{d}:", .{c.nets});
    printCode(c);
    std.debug.print("/{s}: the tool says {}, the oracle {}\n{s}\n", .{ label, got, want, text });
    return 1;
}

test "every sampled circuit and fault gets the oracle's verdict" {
    // Oracle: brute force (oracle.zig `equivalent`), the documented
    // semantics decided over every net bijection, never from the tool:
    // each drawn circuit against its own reference, the same reversed and
    // in Spectre (all match) and each single fault of its reference.
    var all: std.ArrayList(Circuit) = .empty;
    defer all.deinit(gpa);
    try oracle_enum.circuitsInto(gpa, &all);
    var faults: std.ArrayList(oracle_enum.Fault) = .empty;
    defer faults.deinit(gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var sample = Rng.init(0x1A5_0005);
    var failed: usize = 0;
    var circuits: usize = 0;
    for (all.items) |*c| {
        const sampled = c.ndevs == 1 or sample.below(sample_one_in) == 0;
        if (!sampled) continue;
        circuits += 1;
        failed += try enumerated(c, &faults, &text);
    }
    try testing.expect(circuits > 100);
    try testing.expectEqual(@as(usize, 0), failed);
}
