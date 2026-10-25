//! A seeded `xorshift64*` generator whose stream is fixed for all time: a
//! seed gives the same values on every platform and release, so a failing
//! seed replays. Ported from crates/testgen/src/rng.rs.
//!
//! Contents:
//! - `pub const Rng = struct`, `Rng.init(seed: u64) Rng`, `Rng.next(r: *Rng) u64`,
//!   `Rng.below(r: *Rng, bound: u64) u64`, `Rng.range(r: *Rng, lo: i64, hi: i64) i64`,
//!   `Rng.unit(r: *Rng) f64`, `Rng.shuffle(r: *Rng, comptime T: type, items: []T) void`

const std = @import("std");
const assert = std.debug.assert;

/// Period `2^64 - 1`. Invariant: `state != 0`, set by `init` and kept by
/// every step.
pub const Rng = struct {
    state: u64,

    /// Every `u64` is a legal seed, zero included. The seed passes through
    /// the SplitMix64 finaliser, so adjacent seeds start unrelated streams.
    pub fn init(seed: u64) Rng {
        var z = seed +% 0x9E37_79B9_7F4A_7C15;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        z ^= z >> 31;
        return .{ .state = if (z == 0) scramble else z };
    }

    /// One step of the stream; every other draw is built from these.
    pub fn next(r: *Rng) u64 {
        var x = r.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        r.state = x;
        return x *% scramble;
    }

    /// Uniform in `0..bound`, without modulo bias: a draw from the biased
    /// tail is redrawn, so one call may consume several steps. Asserts
    /// `bound > 0`.
    pub fn below(r: *Rng, bound: u64) u64 {
        assert(bound > 0);
        const ceiling = (std.math.maxInt(u64) / bound) * bound;
        while (true) {
            const draw = r.next();
            if (draw < ceiling) return draw % bound;
        }
    }

    /// Uniform in `lo..hi`, half-open; any span fits. Asserts `lo < hi`.
    pub fn range(r: *Rng, lo: i64, hi: i64) i64 {
        assert(lo < hi);
        const span = @as(u64, @bitCast(hi)) -% @as(u64, @bitCast(lo));
        return lo +% @as(i64, @bitCast(r.below(span)));
    }

    /// Uniform in `[0, 1)` from the top 53 bits of one step.
    pub fn unit(r: *Rng) f64 {
        return @as(f64, @floatFromInt(r.next() >> 11)) / 0x1p53;
    }

    /// Fisher-Yates: every permutation equally likely.
    pub fn shuffle(r: *Rng, comptime T: type, items: []T) void {
        var i = items.len;
        while (i > 1) {
            i -= 1;
            const j: usize = @intCast(r.below(i + 1));
            std.mem.swap(T, &items[i], &items[j]);
        }
    }
};

/// The xorshift64* output multiplier, and the state when the seed
/// finalises to zero.
const scramble: u64 = 0x2545_F491_4F6C_DD1D;

test "adjacent seeds start unrelated streams" {
    // Oracle: law, the avalanche property the SplitMix64 finaliser is built
    // for (Steele, Lea and Flood, "Fast Splittable Pseudorandom Number
    // Generators", OOPSLA 2014; its constants are Stafford's Mix13, "Better
    // Bit Mixing", 2011): a changed input flips each output bit with
    // probability 1/2. Over 256 adjacent pairs each (draw, bit) cell counts
    // the pairs that differ there, Binomial(256, 1/2) for unrelated streams:
    // mean 128, sd 8, and the test allows 6 sd. And `x * SCRAMBLE` is a
    // bijection (the multiplier is odd), so a value common to both windows is
    // a common state: one stream the other shifted by under 64 draws.
    var differ: [64][64]u32 = @splat(@splat(0));
    for (0..256) |seed| {
        var a: [64]u64 = undefined;
        var b: [64]u64 = undefined;
        var ra = Rng.init(seed);
        var rb = Rng.init(seed + 1);
        for (&a, &b) |*x, *y| {
            x.* = ra.next();
            y.* = rb.next();
        }
        for (a) |x| try std.testing.expect(std.mem.indexOfScalar(u64, &b, x) == null);
        for (&differ, a, b) |*cells, x, y| {
            for (cells, 0..) |*count, bit| count.* += @intCast(((x ^ y) >> @intCast(bit)) & 1);
        }
    }
    for (differ) |cells| for (cells) |count| try std.testing.expect(count >= 80 and count <= 176);
}

test "below stays within its bound for every bound" {
    // Oracle: the documented range of `below(n)`, `0..n`, on every bound from
    // 1 to 63.
    var r = Rng.init(0);
    for (1..64) |bound| {
        for (0..256) |_| try std.testing.expect(r.below(bound) < bound);
    }
}

test "range is half open" {
    // Oracle: the documented half-open range: every draw in `-5..5`, and `-5`
    // occurs, which 4096 draws miss with probability 0.9^4096.
    var r = Rng.init(3);
    var saw_lo = false;
    for (0..4096) |_| {
        const v = r.range(-5, 5);
        try std.testing.expect(v >= -5 and v < 5);
        saw_lo = saw_lo or v == -5;
    }
    try std.testing.expect(saw_lo);
}

test "shuffle is a permutation" {
    // Oracle: law. A shuffle is a permutation, so sorting it gives back
    // `0..97`; coming back sorted has odds of 1 in 97!.
    var r = Rng.init(11);
    var items: [97]u32 = undefined;
    for (&items, 0..) |*v, i| v.* = @intCast(i);
    r.shuffle(u32, &items);
    var sorted = items;
    std.mem.sortUnstable(u32, &sorted, {}, std.sort.asc(u32));
    for (sorted, 0..) |v, i| try std.testing.expectEqual(@as(u32, @intCast(i)), v);
    try std.testing.expect(!std.mem.eql(u32, &items, &sorted));
}

test "unit is in the half open unit interval with mean one half" {
    // Oracle: closed form. A uniform draw on [0, 1) has mean 1/2 and standard
    // deviation 1/sqrt(12), so the mean of 4096 has standard error 0.0045 and
    // 0.02 is over four of them.
    var r = Rng.init(5);
    var total: f64 = 0;
    for (0..4096) |_| {
        const v = r.unit();
        try std.testing.expect(v >= 0 and v < 1);
        total += v;
    }
    try std.testing.expect(@abs(total / 4096.0 - 0.5) < 0.02);
}
