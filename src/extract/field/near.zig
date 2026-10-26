//! Near-pair corrections to a dense kernel, built as two row passes. In: a
//! pair rule (which columns of a row are near, and each one's exact minus
//! dense entry). Out: `NearPairs`, CSR by row, ascending by column. Ported
//! from crates/extract/src/field/matvec.rs (`NearPairs`, `near`).
//!
//! The build is count → exclusive scan → fill: a count pass per row, a
//! host scan into `start`, then a fill pass writing each row's slots. Both
//! passes are row bodies over the rule, so they run on the host threads
//! (`rows.zig`) and could run on the GPU unchanged; each row writes only its
//! own slots, so the CSR is the same for any thread count.
//!
//! Rung 5 (comptime rule): two rules today, the potential's and the field's.
//!
//! Contents:
//! - `pub const NearPairs = struct`, `NearPairs.empty`, `deinit`, `rows(np) u32`,
//!   `buildInto(np: *NearPairs, gpa: Allocator, threads: u16, rows: u32, panels: u32, rule: anytype) Allocator.Error!void`
//! - `pub fn near(a: Ref, b: Ref, factor: f64) bool`
//! - `pub fn foldRow(start: anytype, column: anytype, value: anytype, i: usize, x: anytype, acc: f64) f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ref = @import("panel.zig").Ref;
const hypot = @import("integrals.zig").hypot;
const row_threads = @import("rows.zig");

/// Row `i`'s pairs are `column[start[i]..start[i + 1]]`, ascending, with
/// `value` the exact entry less the dense kernel's.
pub const NearPairs = struct {
    start: std.ArrayList(u32) = .empty,
    column: std.ArrayList(u32) = .empty,
    value: std.ArrayList(f64) = .empty,

    pub const empty: NearPairs = .{};

    pub fn deinit(np: *NearPairs, gpa: Allocator) void {
        np.start.deinit(gpa);
        np.column.deinit(gpa);
        np.value.deinit(gpa);
    }

    pub fn rows(np: *const NearPairs) u32 {
        return @intCast(np.start.items.len -| 1);
    }

    /// Clears and refills from `rule`: `rule.count(i)` near columns in row
    /// `i`, then `rule.fill(i, column, value)` writing exactly that many,
    /// ascending. `panels` sizes the work estimate (each row tests every
    /// panel). Asserts the pair count fits a `u32`.
    pub fn buildInto(np: *NearPairs, gpa: Allocator, threads: u16, rows_: u32, panels: u32, rule: anytype) Allocator.Error!void {
        try np.start.resize(gpa, @as(usize, rows_) + 1);
        const Rule = @TypeOf(rule);
        const work = @as(u64, rows_) * panels;
        const Count = struct {
            r: Rule,
            start: []u32,
            fn run(c: @This(), lo: u32, hi: u32) void {
                for (lo..hi) |i| c.start[i + 1] = c.r.count(@intCast(i));
            }
        };
        np.start.items[0] = 0;
        row_threads.forBlocks(threads, rows_, work, Count{ .r = rule, .start = np.start.items }, Count.run);
        var total: u64 = 0;
        for (np.start.items[1..]) |*s| {
            total += s.*;
            assert(total <= std.math.maxInt(u32));
            s.* = @intCast(total);
        }
        try np.column.resize(gpa, @intCast(total));
        try np.value.resize(gpa, @intCast(total));
        const Fill = struct {
            r: Rule,
            np: *NearPairs,
            fn run(f: @This(), lo: u32, hi: u32) void {
                for (lo..hi) |i| {
                    const from = f.np.start.items[i];
                    const to = f.np.start.items[i + 1];
                    f.r.fill(@intCast(i), f.np.column.items[from..to], f.np.value.items[from..to]);
                }
            }
        };
        row_threads.forBlocks(threads, rows_, work, Fill{ .r = rule, .np = np }, Fill.run);
    }
};

/// Whether panels `a` and `b` are near: centroids closer than `factor`
/// times the sum of their half-diagonals.
pub fn near(a: Ref, b: Ref, factor: f64) bool {
    var d2: f64 = 0.0;
    for (a.centre, b.centre) |p, q| d2 += (p - q) * (p - q);
    const limit = factor * (hypot(a.half[0], a.half[1]) + hypot(b.half[0], b.half[1]));
    return d2 < limit * limit;
}

/// Row `i`'s pairs folded onto `acc` in column order: `acc + Σ v·x[c]`, the
/// strict order the output bits depend on. Many-pointers or slices: the
/// same body on the host and the device.
pub inline fn foldRow(start: anytype, column: anytype, value: anytype, i: usize, x: anytype, acc: f64) f64 {
    var sum = acc;
    var e: usize = start[i];
    const end: usize = start[i + 1];
    while (e < end) : (e += 1) sum = sum + value[e] * x[column[e]];
    return sum;
}
