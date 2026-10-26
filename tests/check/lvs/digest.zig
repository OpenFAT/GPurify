//! Byte-identity lock on the whole comparison: every verdict of a seeded
//! corpus, folded into one FNV-1a hash twice: as listed (Rust's `{:?}`),
//! and with each report's lines sorted. Class numbering orders
//! `ClassImbalance`, so a numbering change moves only the first; a change in
//! what is reported moves both. Ported from crates/check/tests/lvs/digest.rs
//! and common/mod.rs (`seeded_corpus`): 320 random graphs against a
//! permuted twin, every other one perturbed, then chains and a differential
//! pair against themselves. The hashes are Rust's, last moved when unsized
//! transistors in parallel began to keep their count in `m` (testing-plan
//! F83): 186 of 325 verdicts match.

const std = @import("std");
const testing = std.testing;
const Rng = @import("testgen").Rng;
const Graph = @import("check").lvs.Graph;
const common = @import("common.zig");
const gpa = testing.allocator;

const Digests = struct { listed: u64, canonical: u64, verdicts: u32 };

// ---- private ----

fn fnv(hash: *u64, text: []const u8) void {
    for (text) |byte| hash.* = (hash.* ^ byte) *% 0x100_0000_01b3;
}

fn fold(d: *Digests, r: *const common.Result) !void {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try common.writeVerdict(&buf.writer, r);
    fnv(&d.listed, buf.written());
    buf.clearRetainingCapacity();
    try common.writeCanonical(&buf.writer, r);
    fnv(&d.canonical, buf.written());
    d.verdicts += 1;
}

fn run(d: *Digests, layout: *const Graph, reference: *const Graph) !void {
    var r = try common.compare(layout, reference, .{});
    defer r.deinit(gpa);
    try fold(d, &r);
}

/// Every verdict of the seeded corpus, folded as Rust's `seeded_corpus`
/// orders them.
fn seededCorpus() !Digests {
    var d: Digests = .{ .listed = 0xcbf2_9ce4_8422_2325, .canonical = 0xcbf2_9ce4_8422_2325, .verdicts = 0 };
    var rng = Rng.init(0x5eed);
    for (0..320) |round| {
        const scale: u64 = if (round < 300) 40 else 400;
        const devices: u32 = 1 + @as(u32, @intCast(rng.below(scale)));
        const nets: u32 = 1 + @as(u32, @intCast(rng.below(scale * 3 / 4)));
        var g = try common.randomGraph(&rng, devices, nets);
        defer g.deinit(gpa);
        const dm = try common.perm(&rng, g.deviceCount());
        defer gpa.free(dm);
        const nm = try common.perm(&rng, g.netCount());
        defer gpa.free(nm);
        var twin = try common.permute(&g, dm, nm);
        defer twin.deinit(gpa);
        if (round % 2 == 0) {
            var other = try common.perturbed(&rng, &twin);
            defer other.deinit(gpa);
            try run(&d, &g, &other);
        } else try run(&d, &g, &twin);
    }
    for ([_]u32{ 1, 2, 7, 40 }) |len| {
        var c = try common.chain(len);
        defer c.deinit(gpa);
        try run(&d, &c, &c);
    }
    var pair = try common.differentialPair();
    defer pair.deinit(gpa);
    try run(&d, &pair, &pair);
    return d;
}

test "the seeded corpus verdicts are unchanged" {
    // Oracle: golden, Rust's digest.rs hashes over the same corpus; its
    // change log is the review. Both the order each report lists its
    // discrepancies in and what each report says, whatever its order.
    const d = try seededCorpus();
    try testing.expectEqual(@as(u32, 325), d.verdicts);
    try testing.expectEqual(@as(u64, 15_831_399_851_773_943_039), d.listed);
    try testing.expectEqual(@as(u64, 13_774_904_995_842_023_266), d.canonical);
}
