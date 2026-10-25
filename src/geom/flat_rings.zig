//! The flat ring table the three boolean sweeps read and write, and the set
//! operation they apply. In: rings pushed vertex by vertex. Out: CSR rings
//! (ring `k` is `xs[start[k]..start[k + 1]]` and the same of `ys`). Split
//! out of crates/geom/src/boolean.rs so the sweeps share it without a cycle.
//!
//! Contents:
//! - `pub const Op = enum { unite, intersect, subtract }`, `Op.apply(op: Op, in_a: bool, in_b: bool) bool`
//! - `pub const Rings = struct`, `Rings.deinit`, `Rings.reset(r: *Rings, gpa: Allocator) Allocator.Error!void`,
//!   `Rings.push(r: *Rings, gpa: Allocator, x: i64, y: i64) Allocator.Error!void`,
//!   `Rings.closeRing(r: *Rings, gpa: Allocator) Allocator.Error!void`, `Rings.count(r: *const Rings) u32`,
//!   `Rings.range(r: *const Rings, k: usize) [2]usize`, `Rings.scale(r: *Rings, by: i64) void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// "Is this point in the result" from "is it in `a`" and "is it in `b`"
/// (a nonzero winding number); false for neither, which every sweep relies on.
pub const Op = enum {
    unite,
    intersect,
    subtract,

    pub fn apply(op: Op, in_a: bool, in_b: bool) bool {
        return switch (op) {
            .unite => in_a or in_b,
            .intersect => in_a and in_b,
            .subtract => in_a and !in_b,
        };
    }
};

/// Every ring of one operand or result, flattened. Invariant: `start` is
/// `count() + 1` long after `reset`, ending at `xs.len`, except while a ring
/// is open between `push` and `closeRing`. A `.{}` table reads as no rings.
pub const Rings = struct {
    xs: std.ArrayList(i64) = .empty,
    ys: std.ArrayList(i64) = .empty,
    start: std.ArrayList(u32) = .empty,

    pub fn deinit(r: *Rings, gpa: Allocator) void {
        r.xs.deinit(gpa);
        r.ys.deinit(gpa);
        r.start.deinit(gpa);
    }

    /// Empty and ready for the first ring, keeping the allocations.
    pub fn reset(r: *Rings, gpa: Allocator) Allocator.Error!void {
        r.xs.clearRetainingCapacity();
        r.ys.clearRetainingCapacity();
        r.start.clearRetainingCapacity();
        try r.start.append(gpa, 0);
    }

    pub fn push(r: *Rings, gpa: Allocator, x: i64, y: i64) Allocator.Error!void {
        try r.xs.append(gpa, x);
        try r.ys.append(gpa, y);
    }

    /// Ends the ring whose vertices were pushed since the last one ended.
    pub fn closeRing(r: *Rings, gpa: Allocator) Allocator.Error!void {
        assert(r.start.items.len > 0 and r.xs.items.len <= std.math.maxInt(u32));
        try r.start.append(gpa, @intCast(r.xs.items.len));
    }

    pub fn count(r: *const Rings) u32 {
        return @intCast(@max(r.start.items.len, 1) - 1);
    }

    /// Ring `k`'s run of vertex rows, `[from, to)`.
    pub fn range(r: *const Rings, k: usize) [2]usize {
        return .{ r.start.items[k], r.start.items[k + 1] };
    }

    /// Every coordinate times `by`: the octilinear sweep's doubled scale.
    pub fn scale(r: *Rings, by: i64) void {
        for (r.xs.items) |*c| c.* *= by;
        for (r.ys.items) |*c| c.* *= by;
    }
};
