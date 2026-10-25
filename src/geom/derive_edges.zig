//! Edge layers: a polygon layer's boundary as directed segments (material on
//! the left of travel), edge booleans, edge parts inside or outside a layer,
//! interacting edges, extended boxes and length selection. In: segments and
//! merged `ValidatedLayer`s. Out: merged segments (collinear pieces that touch
//! become one), or boxes. KLayout's edge semantics; exact at any angle.
//! Ported from crates/geom/src/derive.rs (the edge layers).
//!
//! Contents:
//! - `pub const EdgeOp = enum { @"and", not, @"or" }`
//! - `pub fn edgesInto(gpa: Allocator, a: *const ValidatedLayer, out: *std.ArrayList(Seg)) Allocator.Error!void`
//! - `pub fn edgeBooleanInto(gpa: Allocator, a: []const Seg, b: []const Seg, op: EdgeOp, out: *std.ArrayList(Seg)) Allocator.Error!void`
//! - `pub fn edgePartInto(gpa: Allocator, a: []const Seg, b: *const ValidatedLayer, inside: bool, out: *std.ArrayList(Seg)) Allocator.Error!void`
//! - `pub fn edgeInteractingInto(gpa: Allocator, a: []const Seg, b: *const ValidatedLayer, keep: bool, out: *std.ArrayList(Seg)) Allocator.Error!void`
//! - `pub const Extension = struct { begin: Dbu, end: Dbu, outside: Dbu, inside: Dbu }`
//! - `pub fn extendedInto(gpa: Allocator, a: []const Seg, by: Extension, out: *ValidatedLayer) Error!void`
//! - `pub fn withLengthInto(gpa: Allocator, a: []const Seg, lo: i128, hi: i128, out: *std.ArrayList(Seg)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const Bbox = @import("bbox.zig").Bbox;
const ops = @import("ops.zig");
const Point = ops.Point;
const Seg = ops.Seg;
const ValidatedLayer = @import("view.zig").ValidatedLayer;
const width = @import("width.zig");
const size = @import("derive_size.zig");
const Error = size.Error;
const relate = @import("derive_relate.zig");

/// How an edge boolean combines its operands.
pub const EdgeOp = enum {
    /// Parts of `a` coincident with `b`.
    @"and",
    /// Parts of `a` not coincident with `b`.
    not,
    /// `a`, plus the parts of `b` not coincident with `a`.
    @"or",
};

/// KLayout `extended(begin, end, out, in)`: how far each edge's box reaches
/// before its start, past its end, to its right (away from its shape) and to
/// its left.
pub const Extension = struct { begin: Dbu, end: Dbu, outside: Dbu, inside: Dbu };

/// A line's direction: its intercept `pos` is `y`, `x`, `y - x`, `y + x`, or
/// `step.y·x - step.x·y`; its parameter is `x` but on a vertical line, `y`.
const Dir = enum(u8) { horizontal, vertical, rising, falling, skew };

/// One edge on its line: `lo < hi` the span of the line's parameter,
/// `forward` whether it travels toward `hi`; a skew line carries its
/// primitive direction `step` (`step[0] > 0`; `{0, 0}` for the others).
const Run = struct {
    dir: Dir,
    step: [2]i64,
    pos: i128,
    lo: i64,
    hi: i64,
    forward: bool,

    /// The order `emitRuns` merges in: by line, then direction, then start.
    fn lessThan(_: void, a: Run, b: Run) bool {
        if (a.dir != b.dir) return @backingInt(a.dir) < @backingInt(b.dir);
        if (a.step[0] != b.step[0]) return a.step[0] < b.step[0];
        if (a.step[1] != b.step[1]) return a.step[1] < b.step[1];
        if (a.pos != b.pos) return a.pos < b.pos;
        if (a.forward != b.forward) return !a.forward;
        return a.lo < b.lo;
    }
};

/// A line as `A·x + B·y = C`, and the lattice step of its parameter.
const Line = struct { a: i128, b: i128, c: i128, step: i64 };

/// KLayout `edges`: the boundary of every polygon of `a`, material on the
/// left, merged, into `out` (cleared and refilled).
pub fn edgesInto(gpa: Allocator, a: *const ValidatedLayer, out: *std.ArrayList(Seg)) Allocator.Error!void {
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    for (0..a.len()) |i| {
        var it = width.polyEdges(a.get(@intCast(i)));
        while (it.next()) |s| try runs.append(gpa, runOf(s));
    }
    try emitRuns(gpa, &runs, out);
}

/// KLayout's edge booleans: coincidence ignores direction, and each result
/// piece keeps the direction of the operand it came from.
pub fn edgeBooleanInto(gpa: Allocator, a: []const Seg, b: []const Seg, op: EdgeOp, out: *std.ArrayList(Seg)) Allocator.Error!void {
    const ra = try runsOf(gpa, a);
    defer gpa.free(ra);
    const rb = try runsOf(gpa, b);
    defer gpa.free(rb);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    switch (op) {
        .@"and" => try splitRuns(gpa, ra, rb, true, &runs),
        .not => try splitRuns(gpa, ra, rb, false, &runs),
        .@"or" => {
            try runs.appendSlice(gpa, ra);
            try splitRuns(gpa, rb, ra, false, &runs);
        },
    }
    try emitRuns(gpa, &runs, out);
}

/// KLayout `inside_part` (`inside`) / `outside_part`: the parts of each edge
/// strictly inside / strictly outside `b`; parts on `b`'s boundary are in
/// neither. Where `b`'s boundary crosses an edge between points of its
/// line's lattice, the part ends at the last lattice point inside it.
pub fn edgePartInto(gpa: Allocator, a: []const Seg, b: *const ValidatedLayer, inside: bool, out: *std.ArrayList(Seg)) Allocator.Error!void {
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    var cand: std.ArrayList(u32) = .empty;
    defer cand.deinit(gpa);
    try edgeCandidates(gpa, a, b, &start, &cand);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    // Cut points as fractions of the line's parameter, `[num, den]`, den > 0;
    // spans of `b`'s boundary on the line in whole units.
    var cuts: std.ArrayList([2]i128) = .empty;
    defer cuts.deinit(gpa);
    var on_line: std.ArrayList([2]i64) = .empty;
    defer on_line.deinit(gpa);
    for (a, 0..) |s, i| {
        const r = runOf(s);
        const polys = cand.items[start.items[i]..start.items[i + 1]];
        cuts.clearRetainingCapacity();
        on_line.clearRetainingCapacity();
        try cuts.appendSlice(gpa, &.{ .{ r.lo, 1 }, .{ r.hi, 1 } });
        for (polys) |p| {
            var it = width.polyEdges(b.get(p));
            while (it.next()) |e| {
                const t = runOf(e);
                if (sameLine(t, r)) {
                    try cuts.appendSlice(gpa, &.{ .{ t.lo, 1 }, .{ t.hi, 1 } });
                    try on_line.append(gpa, .{ t.lo, t.hi });
                } else if (crossing(r, t)) |c| {
                    if (cmp(c[1], .{ t.lo, 1 }) != .lt and cmp(c[1], .{ t.hi, 1 }) != .gt) try cuts.append(gpa, c[0]);
                }
            }
        }
        var kept: usize = 0;
        for (cuts.items) |c| {
            if (cmp(c, .{ r.lo, 1 }) == .lt or cmp(c, .{ r.hi, 1 }) == .gt) continue;
            cuts.items[kept] = c;
            kept += 1;
        }
        cuts.shrinkRetainingCapacity(kept);
        std.mem.sort([2]i128, cuts.items, {}, struct {
            fn lessThan(_: void, p: [2]i128, q: [2]i128) bool {
                return cmp(p, q) == .lt;
            }
        }.lessThan);
        kept = 0;
        for (cuts.items) |c| {
            if (kept > 0 and cmp(cuts.items[kept - 1], c) == .eq) continue;
            cuts.items[kept] = c;
            kept += 1;
        }
        cuts.shrinkRetainingCapacity(kept);
        // The lattice of the line: r.lo + k·step, ends moved inward onto it.
        const step = lineOf(r).step;
        for (cuts.items[0..cuts.items.len -| 1], cuts.items[@min(1, cuts.items.len)..]) |c0, c1| {
            const from = snap(r.lo, step, c0, .up);
            const to = snap(r.lo, step, c1, .down);
            if (from >= to) continue;
            var covered = false;
            for (on_line.items) |sp| covered = covered or (sp[0] <= from and to <= sp[1]);
            if (covered) continue;
            // The piece's middle, at twice scale: on no ring of `b`.
            const p = onLine(r, r.pos, from);
            const q = onLine(r, r.pos, to);
            if (relate.insideAny(b, polys, p[0] + q[0], p[1] + q[1], 2) == inside) {
                var piece = r;
                piece.lo = from;
                piece.hi = to;
                try runs.append(gpa, piece);
            }
        }
    }
    try emitRuns(gpa, &runs, out);
}

/// KLayout edge `interacting` (`keep`) / `not_interacting`: whole edges that
/// touch or cross a polygon of `b`, or lie inside one, into `out`.
pub fn edgeInteractingInto(gpa: Allocator, a: []const Seg, b: *const ValidatedLayer, keep: bool, out: *std.ArrayList(Seg)) Allocator.Error!void {
    var start: std.ArrayList(u32) = .empty;
    defer start.deinit(gpa);
    var cand: std.ArrayList(u32) = .empty;
    defer cand.deinit(gpa);
    try edgeCandidates(gpa, a, b, &start, &cand);
    out.clearRetainingCapacity();
    for (a, 0..) |s, i| {
        var meets = false;
        for (cand.items[start.items[i]..start.items[i + 1]]) |p| {
            const poly = b.get(p);
            var it = width.polyEdges(poly);
            while (it.next()) |t| meets = meets or ops.segmentsIntersect(s, t);
            meets = meets or relate.containsScaled(poly, s.a.x, s.a.y, 1);
        }
        if (meets == keep) try out.append(gpa, s);
    }
}

/// KLayout `extended(begin, end, out, in)` on edges, material on the left:
/// one box per edge, lengthened by `begin` before its start and `end` past
/// its end, widened by `outside` to its right and `inside` to its left,
/// unmerged. A box with no area is `error.Invalid`, an edge that is not
/// horizontal or vertical `error.NotRectilinear`.
pub fn extendedInto(gpa: Allocator, a: []const Seg, by: Extension, out: *ValidatedLayer) Error!void {
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    for (a) |s| {
        const r = runOf(s);
        const vertical = switch (r.dir) {
            .horizontal => false,
            .vertical => true,
            .rising, .falling, .skew => return error.NotRectilinear,
        };
        const pos: i64 = @intCast(r.pos);
        // Travelling toward `hi`, the material (left) is +y on a horizontal
        // edge and -x on a vertical one.
        const left_positive = r.forward != vertical;
        const before = if (r.forward) by.begin else by.end;
        const after = if (r.forward) by.end else by.begin;
        const below = if (left_positive) by.outside else by.inside;
        const above = if (left_positive) by.inside else by.outside;
        const lo = try at(r.lo - before);
        const hi = try at(r.hi + after);
        const across_lo = try at(pos - below);
        const across_hi = try at(pos + above);
        try boxes.append(gpa, if (vertical) .{ .xlo = across_lo, .ylo = lo, .xhi = across_hi, .yhi = hi } else .{ .xlo = lo, .ylo = across_lo, .xhi = hi, .yhi = across_hi });
    }
    try size.boxesInto(gpa, boxes.items, out);
}

/// KLayout `with_length`: edges whose length in grid units is in `lo..=hi`.
/// A diagonal edge `k` steps long is `k·√2`, and one at any other angle
/// `√(dx² + dy²)`, compared squared, exactly.
pub fn withLengthInto(gpa: Allocator, a: []const Seg, lo: i128, hi: i128, out: *std.ArrayList(Seg)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (a) |s| {
        const r = runOf(s);
        const keep = switch (r.dir) {
            .horizontal, .vertical => blk: {
                const k: i128 = r.hi - r.lo;
                break :blk k >= lo and k <= hi;
            },
            .rising, .falling, .skew => blk: {
                const dx: i128 = s.b.x - s.a.x;
                const dy: i128 = s.b.y - s.a.y;
                const length2 = dx * dx + dy * dy;
                const above = lo <= 0 or (if (std.math.mul(i128, lo, lo)) |l2| l2 <= length2 else |_| false);
                const below = hi >= 0 and (if (std.math.mul(i128, hi, hi)) |h2| length2 <= h2 else |_| true);
                break :blk above and below;
            },
        };
        if (keep) try out.append(gpa, s);
    }
}

// ---- private ----

fn at(v: i64) Error!Dbu {
    return if (dbu.inDomain(v)) v else error.OutOfRange;
}

fn runOf(s: Seg) Run {
    const dx = s.b.x - s.a.x;
    const dy = s.b.y - s.a.y;
    const ax: i128 = s.a.x;
    const ay: i128 = s.a.y;
    var r: Run = .{ .dir = .horizontal, .step = .{ 0, 0 }, .pos = ay, .lo = @min(s.a.x, s.b.x), .hi = @max(s.a.x, s.b.x), .forward = s.b.x > s.a.x };
    if (dy == 0) return r;
    if (dx == 0) return .{ .dir = .vertical, .step = .{ 0, 0 }, .pos = ax, .lo = @min(s.a.y, s.b.y), .hi = @max(s.a.y, s.b.y), .forward = s.b.y > s.a.y };
    if (dx == dy) {
        r.dir = .rising;
        r.pos = ay - ax;
    } else if (dx == -dy) {
        r.dir = .falling;
        r.pos = ay + ax;
    } else {
        const g: i64 = @as(i64, @intCast(std.math.gcd(@abs(dx), @abs(dy)))) * std.math.sign(dx);
        r.dir = .skew;
        r.step = .{ @divExact(dx, g), @divExact(dy, g) };
        r.pos = @as(i128, r.step[1]) * ax - @as(i128, r.step[0]) * ay;
    }
    return r;
}

fn runsOf(gpa: Allocator, segs: []const Seg) Allocator.Error![]Run {
    const out = try gpa.alloc(Run, segs.len);
    for (out, segs) |*r, s| r.* = runOf(s);
    return out;
}

fn sameLine(a: Run, b: Run) bool {
    return a.dir == b.dir and a.step[0] == b.step[0] and a.step[1] == b.step[1] and a.pos == b.pos;
}

/// The point at parameter `t` on a run's line of intercept `pos`, all scaled
/// alike; on a skew line `t` must be a point of the lattice it passes.
fn onLine(r: Run, pos: i128, t: i64) [2]i64 {
    return switch (r.dir) {
        .horizontal => .{ t, @intCast(pos) },
        .vertical => .{ @intCast(pos), t },
        .rising => .{ t, t + @as(i64, @intCast(pos)) },
        .falling => .{ t, @as(i64, @intCast(pos)) - t },
        .skew => blk: {
            const num = @as(i128, r.step[1]) * t - pos;
            break :blk .{ t, @intCast(@divExact(num, r.step[0])) };
        },
    };
}

fn segOf(r: Run) Seg {
    const from = if (r.forward) r.lo else r.hi;
    const to = if (r.forward) r.hi else r.lo;
    const p = onLine(r, r.pos, from);
    const q = onLine(r, r.pos, to);
    return .{ .a = .{ .x = p[0], .y = p[1] }, .b = .{ .x = q[0], .y = q[1] } };
}

fn lineOf(r: Run) Line {
    return switch (r.dir) {
        .horizontal => .{ .a = 0, .b = 1, .c = r.pos, .step = 1 },
        .vertical => .{ .a = 1, .b = 0, .c = r.pos, .step = 1 },
        .rising => .{ .a = -1, .b = 1, .c = r.pos, .step = 1 },
        .falling => .{ .a = 1, .b = 1, .c = r.pos, .step = 1 },
        .skew => .{ .a = r.step[1], .b = -r.step[0], .c = r.pos, .step = r.step[0] },
    };
}

/// Two fractions `[num, den]`, `den > 0`, ordered exactly.
fn cmp(p: [2]i128, q: [2]i128) std.math.Order {
    return ops.cmpProducts(p[0], q[1], q[0], p[1]);
}

/// Where the lines of `r` and `t` cross, as the fraction of the parameter
/// along each, or null for parallel lines.
fn crossing(r: Run, t: Run) ?[2][2]i128 {
    const l1 = lineOf(r);
    const l2 = lineOf(t);
    var det = l1.a * l2.b - l2.a * l1.b;
    if (det == 0) return null;
    var x = l1.c * l2.b - l2.c * l1.b;
    var y = l1.a * l2.c - l2.a * l1.c;
    if (det < 0) {
        det = -det;
        x = -x;
        y = -y;
    }
    return .{ .{ if (r.dir == .vertical) y else x, det }, .{ if (t.dir == .vertical) y else x, det } };
}

/// The lattice point `base + k·step` at or past the fraction `c`, rounding
/// `.up` (toward `hi`) or `.down`.
fn snap(base: i64, step: i64, c: [2]i128, comptime way: enum { up, down }) i64 {
    const n = c[0] - @as(i128, base) * c[1];
    const d = @as(i128, step) * c[1];
    const k = switch (way) {
        .up => -@divFloor(-n, d),
        .down => @divFloor(n, d),
    };
    return @intCast(base + k * step);
}

/// Runs to merged segments, into `out` (cleared and refilled): collinear
/// pieces of one direction that touch or overlap become one, zero-length
/// ones go.
fn emitRuns(gpa: Allocator, runs: *std.ArrayList(Run), out: *std.ArrayList(Seg)) Allocator.Error!void {
    var kept: usize = 0;
    for (runs.items) |r| {
        if (r.lo >= r.hi) continue;
        runs.items[kept] = r;
        kept += 1;
    }
    runs.shrinkRetainingCapacity(kept);
    std.mem.sortUnstable(Run, runs.items, {}, Run.lessThan);
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < runs.items.len) {
        var cur = runs.items[i];
        i += 1;
        while (i < runs.items.len and sameLine(runs.items[i], cur) and runs.items[i].forward == cur.forward and runs.items[i].lo <= cur.hi) : (i += 1) {
            cur.hi = @max(cur.hi, runs.items[i].hi);
        }
        try out.append(gpa, segOf(cur));
    }
}

/// Parts of `a` that `b` covers (`covered`) or does not, direction ignored,
/// appended to `out`.
fn splitRuns(gpa: Allocator, a: []const Run, b: []const Run, covered: bool, out: *std.ArrayList(Run)) Allocator.Error!void {
    // `b`'s coverage per line, undirected, merged and sorted.
    var cover: std.ArrayList(Run) = .empty;
    defer cover.deinit(gpa);
    for (b) |r| {
        var c = r;
        c.forward = false;
        try cover.append(gpa, c);
    }
    std.mem.sortUnstable(Run, cover.items, {}, Run.lessThan);
    var merged: std.ArrayList(Run) = .empty;
    defer merged.deinit(gpa);
    for (cover.items) |c| {
        if (merged.items.len > 0) {
            const m = &merged.items[merged.items.len - 1];
            if (sameLine(m.*, c) and c.lo <= m.hi) {
                m.hi = @max(m.hi, c.hi);
                continue;
            }
        }
        try merged.append(gpa, c);
    }
    for (a) |r| {
        // The first coverage on `r`'s line ending past `r.lo`.
        const first = std.sort.partitionPoint(Run, merged.items, r, struct {
            fn before(want: Run, m: Run) bool {
                return lineBefore(m, want);
            }
        }.before);
        var from = r.lo;
        for (merged.items[first..]) |m| {
            if (!sameLine(m, r) or m.lo >= r.hi) break;
            const lo = @max(m.lo, r.lo);
            const hi = @min(m.hi, r.hi);
            var piece = r;
            if (covered) {
                piece.lo = lo;
                piece.hi = hi;
            } else {
                piece.lo = from;
                piece.hi = lo;
            }
            try out.append(gpa, piece);
            from = hi;
        }
        if (!covered) {
            var piece = r;
            piece.lo = from;
            try out.append(gpa, piece);
        }
    }
}

/// Whether coverage `m` sorts before `r`'s line, or on it ending at or
/// before `r.lo` (Rust's `(m.line, m.hi) <= (line(r), r.lo)`).
fn lineBefore(m: Run, r: Run) bool {
    if (!sameLine(m, r)) {
        var mm = m;
        var rr = r;
        mm.forward = false;
        rr.forward = false;
        mm.lo = 0;
        rr.lo = 0;
        return Run.lessThan({}, mm, rr);
    }
    return m.hi <= r.lo;
}

/// Candidate polygons of `b` per edge of `a`, CSR: edge `i` owns
/// `cand[start[i]..start[i + 1]]`.
fn edgeCandidates(gpa: Allocator, a: []const Seg, b: *const ValidatedLayer, start: *std.ArrayList(u32), cand: *std.ArrayList(u32)) Allocator.Error!void {
    const boxes = try gpa.alloc(Bbox, a.len);
    defer gpa.free(boxes);
    for (boxes, a) |*bx, s| bx.* = Bbox.point(s.a.x, s.a.y).include(s.b.x, s.b.y);
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    try relate.boxPairs(gpa, boxes, b.bboxes(), &pairs);
    start.clearRetainingCapacity();
    cand.clearRetainingCapacity();
    try start.append(gpa, 0);
    var k: usize = 0;
    for (0..a.len) |i| {
        while (k < pairs.items.len and pairs.items[k][0] == i) : (k += 1) try cand.append(gpa, pairs.items[k][1]);
        try start.append(gpa, @intCast(cand.items.len));
    }
}
