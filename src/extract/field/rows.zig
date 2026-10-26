//! Host threads for a row kernel: the CPU half of ARCHITECTURE.md's row
//! kernels. In: a row count, a thread count and a body over a row range.
//! Out: the body run over disjoint blocks of rows, every row once. Each
//! block writes only its own rows, so the result is the same for any thread
//! count and any interleaving.
//!
//! Rung 5 (comptime body): five bodies today (potential rows, field rows,
//! both near-pair passes, Henry's Zb rows), one runner.
//!
//! Contents:
//! - `pub const block: u32`
//! - `pub fn forBlocks(threads: u16, rows: u32, work: u64, ctx: anytype, comptime body: fn (@TypeOf(ctx), u32, u32) void) void`

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Rows a worker takes at a time.
pub const block: u32 = 64;

/// Pair evaluations below which threads cost more than they save: a spawn is
/// tens of microseconds, a pair a few nanoseconds.
// ponytail: a calibration knob, measured once on a laptop; `zig build bench` when it matters.
const min_parallel_work: u64 = 1 << 18;

const max_threads = 64;

/// Runs `body(ctx, lo, hi)` over `0..rows` in blocks of `block` rows, on up
/// to `threads` threads (the caller's included), taking blocks by an atomic
/// ticket. `work` estimates the total cost in pair evaluations: below
/// `min_parallel_work` the caller runs every block itself, so a small solve
/// pays no thread spawn. A failed spawn leaves its share to the threads that
/// did start.
pub fn forBlocks(threads: u16, rows: u32, work: u64, ctx: anytype, comptime body: fn (@TypeOf(ctx), u32, u32) void) void {
    const Ctx = @TypeOf(ctx);
    const blocks = std.math.divCeil(u32, rows, block) catch unreachable;
    const want: u32 = if (work < min_parallel_work or builtin.single_threaded) 1 else @min(@max(threads, 1), blocks, max_threads);
    if (want <= 1) {
        var lo: u32 = 0;
        while (lo < rows) : (lo += block) body(ctx, lo, @min(lo + block, rows));
        return;
    }
    var ticket = std.atomic.Value(u32).init(0);
    const Worker = struct {
        fn run(c: Ctx, t: *std.atomic.Value(u32), n: u32, count: u32) void {
            while (true) {
                const b = t.fetchAdd(1, .monotonic);
                if (b >= count) return;
                const lo = b * block;
                body(c, lo, @min(lo + block, n));
            }
        }
    };
    var pool: [max_threads]std.Thread = undefined;
    var spawned: usize = 0;
    for (pool[0 .. want - 1]) |*th| {
        th.* = std.Thread.spawn(.{}, Worker.run, .{ ctx, &ticket, rows, blocks }) catch break;
        spawned += 1;
    }
    Worker.run(ctx, &ticket, rows, blocks);
    for (pool[0..spawned]) |th| th.join();
}

test "every row runs once whatever the thread count" {
    // Oracle: construct-from-answer. Each row writes its own index; every
    // thread count from 1 to 9, over row counts crossing block boundaries,
    // leaves `out[i] == i`, and a large `work` forces the threaded path.
    const gpa = std.testing.allocator;
    const out = try gpa.alloc(u32, 3 * block + 1);
    defer gpa.free(out);
    const Body = struct {
        fn run(o: []u32, lo: u32, hi: u32) void {
            for (lo..hi) |i| o[i] = @intCast(i);
        }
    };
    for (1..10) |threads| {
        for ([_]u32{ 0, 1, block - 1, block, 3 * block + 1 }) |rows| {
            @memset(out, std.math.maxInt(u32));
            forBlocks(@intCast(threads), rows, 1 << 30, out, Body.run);
            for (out[0..rows], 0..) |v, i| try std.testing.expectEqual(i, v);
        }
    }
}
