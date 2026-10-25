//! The boolean sweep for rectilinear operands. In: two flat ring tables,
//! every edge horizontal or vertical. Out: the rings of `op(a, b)`, outers
//! counter-clockwise and holes clockwise, in the connected corner model
//! (`boolean.unionInto`). Between two consecutive axis x the occupied set is
//! a constant list of y-intervals (nonzero winding); the operation combines
//! the lists slab by slab, and a trace walks the boundary back into rings.
//! Ported from crates/geom/src/boolean.rs (the slab half).
//!
//! Contents:
//! - `pub fn combineInto(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const flat = @import("flat_rings.zig");
const Rings = flat.Rings;
const Op = flat.Op;

/// One vertical edge: the y-range it spans and the winding it adds to every
/// cut to its right (downward `+1`, upward `-1`).
const VEdge = struct {
    x: i64,
    ylo: i64,
    yhi: i64,
    delta: i32,

    fn lessThan(_: void, a: VEdge, b: VEdge) bool {
        return a.x < b.x;
    }
};

/// One boundary segment of the result, interior on its left.
const Piece = struct {
    sx: i64,
    sy: i64,
    ex: i64,
    ey: i64,

    fn head(p: Piece) [2]i64 {
        return .{ p.sx, p.sy };
    }

    fn tail(p: Piece) [2]i64 {
        return .{ p.ex, p.ey };
    }

    fn dir(p: Piece) [2]i64 {
        return .{ std.math.sign(p.ex - p.sx), std.math.sign(p.ey - p.sy) };
    }
};

/// The occupied y-intervals of every x-slab, CSR: slab `c` spans
/// `axis[c]..axis[c + 1]` and holds `ivals[start[c]..start[c + 1]]`,
/// ascending, disjoint, half-open in y.
const Slabs = struct {
    start: std.ArrayList(u32) = .empty,
    ivals: std.ArrayList([2]i64) = .empty,

    fn deinit(s: *Slabs, gpa: Allocator) void {
        s.start.deinit(gpa);
        s.ivals.deinit(gpa);
    }

    fn open(s: *Slabs, gpa: Allocator) Allocator.Error!void {
        s.start.clearRetainingCapacity();
        s.ivals.clearRetainingCapacity();
        try s.start.append(gpa, 0);
    }

    fn closeSlab(s: *Slabs, gpa: Allocator) Allocator.Error!void {
        try s.start.append(gpa, @intCast(s.ivals.items.len));
    }

    fn slab(s: *const Slabs, c: usize) []const [2]i64 {
        return s.ivals.items[s.start.items[c]..s.start.items[c + 1]];
    }
};

/// Every buffer the sweep reuses, each cleared where it is filled.
const Sweep = struct {
    /// The running winding-change map of one operand, ascending in y.
    ymap: std.ArrayList(Delta) = .empty,
    pending: std.ArrayList(Delta) = .empty,
    merged: std.ArrayList(Delta) = .empty,
    /// The merged interval endpoints of whichever two lists are walked.
    ends: std.ArrayList(i64) = .empty,
    /// The horizontal runs still open: `(y, sense, from x)`.
    open: std.ArrayList([3]i64) = .empty,
    next_open: std.ArrayList([3]i64) = .empty,
    cur: std.ArrayList([2]i64) = .empty,
    horizontals: std.ArrayList(Piece) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    /// Pieces ordered by head and by tail, and the successor of each.
    order: std.ArrayList(u32) = .empty,
    by_end: std.ArrayList(u32) = .empty,
    next: std.ArrayList(u32) = .empty,

    fn deinit(s: *Sweep, gpa: Allocator) void {
        inline for (@typeInfo(Sweep).@"struct".field_names) |name| @field(s, name).deinit(gpa);
    }
};

const Delta = struct {
    y: i64,
    d: i32,

    fn lessThan(_: void, a: Delta, b: Delta) bool {
        return a.y < b.y or (a.y == b.y and a.d < b.d);
    }
};

const Tables = struct {
    ea: std.ArrayList(VEdge) = .empty,
    eb: std.ArrayList(VEdge) = .empty,
    xs: std.ArrayList(i64) = .empty,
    sa: Slabs = .{},
    sb: Slabs = .{},
    result: Slabs = .{},
    sweep: Sweep = .{},

    fn deinit(t: *Tables, gpa: Allocator) void {
        t.ea.deinit(gpa);
        t.eb.deinit(gpa);
        t.xs.deinit(gpa);
        t.sa.deinit(gpa);
        t.sb.deinit(gpa);
        t.result.deinit(gpa);
        t.sweep.deinit(gpa);
    }
};

/// The rings of `op(a, b)` into `out` (cleared and refilled). Cost:
/// `O(s · k)` for `s` slabs and `k` intervals crossing a slab.
pub fn combineInto(gpa: Allocator, a: *const Rings, b: *const Rings, op: Op, out: *Rings) Allocator.Error!void {
    var t: Tables = .{};
    defer t.deinit(gpa);
    try vedgesInto(gpa, a, &t.ea);
    try vedgesInto(gpa, b, &t.eb);
    // One shared axis: every edge's x, ascending, distinct.
    for (t.ea.items) |e| try t.xs.append(gpa, e.x);
    for (t.eb.items) |e| try t.xs.append(gpa, e.x);
    std.mem.sortUnstable(i64, t.xs.items, {}, std.sort.asc(i64));
    t.xs.shrinkRetainingCapacity(dedup(i64, t.xs.items));

    try occupancy(gpa, t.ea.items, t.xs.items, &t.sweep, &t.sa);
    try occupancy(gpa, t.eb.items, t.xs.items, &t.sweep, &t.sb);
    try combineSlabs(gpa, t.xs.items.len, &t.sa, &t.sb, op, &t.sweep, &t.result);
    try segments(gpa, t.xs.items, &t.result, &t.sweep);
    try successorsInto(gpa, &t.sweep);
    try link(gpa, &t.sweep, out);
    if (builtin.mode == .debug) assert(ringsArea2(out) == 2 * regionArea(t.xs.items, &t.result));
}

// ---- private ----

/// Drops consecutive repeats of a sorted slice in place; returns the length.
fn dedup(comptime T: type, items: []T) usize {
    var kept: usize = 0;
    for (items) |v| {
        if (kept > 0 and items[kept - 1] == v) continue;
        items[kept] = v;
        kept += 1;
    }
    return kept;
}

/// Every vertical edge of one operand, ascending in x.
fn vedgesInto(gpa: Allocator, rings: *const Rings, out: *std.ArrayList(VEdge)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (0..rings.count()) |k| {
        const lo, const hi = rings.range(k);
        const n = hi - lo;
        for (0..n) |i| {
            const a = lo + i;
            const b = lo + (i + 1) % n;
            if (rings.xs.items[a] != rings.xs.items[b]) continue;
            const y0 = rings.ys.items[a];
            const y1 = rings.ys.items[b];
            try out.append(gpa, .{ .x = rings.xs.items[a], .ylo = @min(y0, y1), .yhi = @max(y0, y1), .delta = if (y1 > y0) -1 else 1 });
        }
    }
    std.mem.sortUnstable(VEdge, out.items, {}, VEdge.lessThan);
}

/// Merges one cut's winding changes (ascending in y) into the running map,
/// dropping entries that cancel to zero.
fn mergeDeltas(gpa: Allocator, base: []const Delta, add: []const Delta, out: *std.ArrayList(Delta)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    var j: usize = 0;
    while (i < base.len or j < add.len) {
        const left = if (i < base.len) base[i].y else std.math.maxInt(i64);
        const right = if (j < add.len) add[j].y else std.math.maxInt(i64);
        const y = @min(left, right);
        var acc: i32 = 0;
        while (i < base.len and base[i].y == y) : (i += 1) acc += base[i].d;
        while (j < add.len and add[j].y == y) : (j += 1) acc += add[j].d;
        if (acc != 0) try out.append(gpa, .{ .y = y, .d = acc });
    }
}

/// One cut's winding-change map turned into occupied y-intervals, appended.
fn intervalsInto(gpa: Allocator, ymap: []const Delta, out: *std.ArrayList([2]i64)) Allocator.Error!void {
    var sum: i32 = 0;
    var open: i64 = 0;
    for (ymap) |e| {
        const was = sum;
        sum += e.d;
        // No zero delta, so `was == 0` means the sum just left zero.
        if (was == 0) {
            open = e.y;
        } else if (sum == 0) {
            try out.append(gpa, .{ open, e.y });
        }
    }
    // Every edge adds its delta at `ylo` and takes it back at `yhi`.
    assert(sum == 0);
}

/// The exact area of a slab list over its axis.
fn regionArea(xs: []const i64, region: *const Slabs) i128 {
    var total: i128 = 0;
    for (0..xs.len -| 1) |c| {
        var height: i128 = 0;
        for (region.slab(c)) |iv| height += iv[1] - iv[0];
        total += @as(i128, xs[c + 1] - xs[c]) * height;
    }
    return total;
}

fn ringsArea2(r: *const Rings) i128 {
    var total: i128 = 0;
    for (0..r.count()) |k| {
        const lo, const hi = r.range(k);
        for (lo..hi) |i| {
            const j = if (i + 1 == hi) lo else i + 1;
            total += @as(i128, r.xs.items[i]) * r.ys.items[j] - @as(i128, r.xs.items[j]) * r.ys.items[i];
        }
    }
    return total;
}

/// Occupancy of every x-slab by the nonzero-winding rule. `xs` holds every
/// edge's x and may hold more (a shared axis); `segments` merges the extra
/// splits back out.
fn occupancy(gpa: Allocator, edges: []const VEdge, xs: []const i64, sweep: *Sweep, out: *Slabs) Allocator.Error!void {
    try out.open(gpa);
    sweep.ymap.clearRetainingCapacity();
    var next: usize = 0;
    for (xs[0..xs.len -| 1]) |x| {
        sweep.pending.clearRetainingCapacity();
        while (next < edges.len and edges[next].x == x) : (next += 1) {
            try sweep.pending.append(gpa, .{ .y = edges[next].ylo, .d = edges[next].delta });
            try sweep.pending.append(gpa, .{ .y = edges[next].yhi, .d = -edges[next].delta });
        }
        if (sweep.pending.items.len > 0) {
            std.mem.sortUnstable(Delta, sweep.pending.items, {}, Delta.lessThan);
            try mergeDeltas(gpa, sweep.ymap.items, sweep.pending.items, &sweep.merged);
            std.mem.swap(std.ArrayList(Delta), &sweep.ymap, &sweep.merged);
        }
        try intervalsInto(gpa, sweep.ymap.items, &out.ivals);
        try out.closeSlab(gpa);
    }
}

/// Whether an ascending, disjoint interval list covers `y`.
fn covers(ivals: []const [2]i64, y: i64) bool {
    const after = std.sort.partitionPoint([2]i64, ivals, y, struct {
        fn atOrBelow(at: i64, iv: [2]i64) bool {
            return iv[0] <= at;
        }
    }.atOrBelow);
    return after > 0 and ivals[after - 1][1] > y;
}

/// Every endpoint of two interval lists, ascending and distinct.
fn endpoints(gpa: Allocator, a: []const [2]i64, b: []const [2]i64, out: *std.ArrayList(i64)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (a) |iv| try out.appendSlice(gpa, &iv);
    for (b) |iv| try out.appendSlice(gpa, &iv);
    std.mem.sortUnstable(i64, out.items, {}, std.sort.asc(i64));
    out.shrinkRetainingCapacity(dedup(i64, out.items));
}

/// The set operation slab by slab; both operands share one axis.
fn combineSlabs(gpa: Allocator, lines: usize, a: *const Slabs, b: *const Slabs, op: Op, sweep: *Sweep, out: *Slabs) Allocator.Error!void {
    try out.open(gpa);
    for (0..lines -| 1) |c| {
        const left = a.slab(c);
        const right = b.slab(c);
        try endpoints(gpa, left, right, &sweep.ends);
        var open = false;
        var from: i64 = 0;
        const ends = sweep.ends.items;
        for (ends, 0..) |y, k| {
            // The last endpoint forces every run closed.
            const keep = k + 1 < ends.len and op.apply(covers(left, y), covers(right, y));
            if (keep == open) continue;
            if (open) try out.ivals.append(gpa, .{ from, y });
            from = y;
            open = keep;
        }
        try out.closeSlab(gpa);
    }
}

/// Every boundary piece of a slab list, interior on the left (outers come
/// out counter-clockwise, holes clockwise), maximal collinear runs merged.
fn segments(gpa: Allocator, xs: []const i64, region: *const Slabs, sweep: *Sweep) Allocator.Error!void {
    const slabs = xs.len -| 1;
    sweep.pieces.clearRetainingCapacity();
    sweep.horizontals.clearRetainingCapacity();
    const none: []const [2]i64 = &.{};
    for (xs, 0..) |x, i| {
        const left = if (i > 0) region.slab(i - 1) else none;
        const right = if (i < slabs) region.slab(i) else none;
        try endpoints(gpa, left, right, &sweep.ends);
        var run: i32 = 0;
        var from: i64 = 0;
        const ends = sweep.ends.items;
        for (ends, 0..) |y, k| {
            // Left inside runs up, right inside runs down; the last closes.
            const side: i32 = if (k + 1 < ends.len) @as(i32, @intFromBool(covers(left, y))) - @intFromBool(covers(right, y)) else 0;
            if (side == run) continue;
            try pushRun(gpa, &sweep.pieces, run, .{ x, from }, .{ x, y });
            run = side;
            from = y;
        }
    }

    // Horizontals: an interval start runs right, an end runs left. A run
    // continues while the next slab has the same end with the same sense.
    sweep.open.clearRetainingCapacity();
    for (xs, 0..) |x, c| {
        sweep.cur.clearRetainingCapacity();
        // Past the last slab `cur` stays empty, closing every run.
        if (c < slabs) for (region.slab(c)) |iv| {
            try sweep.cur.append(gpa, .{ iv[0], 1 });
            try sweep.cur.append(gpa, .{ iv[1], -1 });
        };
        sweep.next_open.clearRetainingCapacity();
        var p: usize = 0;
        var q: usize = 0;
        const sentinel = [2]i64{ std.math.maxInt(i64), std.math.maxInt(i64) };
        while (p < sweep.open.items.len or q < sweep.cur.items.len) {
            const ahead: [2]i64 = if (p < sweep.open.items.len) sweep.open.items[p][0..2].* else sentinel;
            const here: [2]i64 = if (q < sweep.cur.items.len) sweep.cur.items[q] else sentinel;
            switch (std.mem.order(i64, &ahead, &here)) {
                .eq => {
                    try sweep.next_open.append(gpa, sweep.open.items[p]);
                    p += 1;
                    q += 1;
                },
                .lt => {
                    const o = sweep.open.items[p];
                    try pushRun(gpa, &sweep.horizontals, @intCast(o[1]), .{ o[2], o[0] }, .{ x, o[0] });
                    p += 1;
                },
                .gt => {
                    try sweep.next_open.append(gpa, .{ here[0], here[1], x });
                    q += 1;
                },
            }
        }
        std.mem.swap(std.ArrayList([3]i64), &sweep.open, &sweep.next_open);
    }

    // Canonical order: verticals by (x, y) off the sweep, horizontals by (y, x).
    std.mem.sortUnstable(Piece, sweep.horizontals.items, {}, struct {
        fn lessThan(_: void, a: Piece, b: Piece) bool {
            if (a.sy != b.sy) return a.sy < b.sy;
            return @min(a.sx, a.ex) < @min(b.sx, b.ex);
        }
    }.lessThan);
    try sweep.pieces.appendSlice(gpa, sweep.horizontals.items);
}

/// Closes one run: `+1` keeps the walk's direction, `-1` reverses it, `0`
/// is no boundary.
fn pushRun(gpa: Allocator, pieces: *std.ArrayList(Piece), run: i32, low: [2]i64, high: [2]i64) Allocator.Error!void {
    if (run > 0) try pieces.append(gpa, .{ .sx = low[0], .sy = low[1], .ex = high[0], .ey = high[1] });
    if (run < 0) try pieces.append(gpa, .{ .sx = high[0], .sy = high[1], .ex = low[0], .ey = low[1] });
}

fn lessByHead(pieces: []const Piece, a: u32, b: u32) bool {
    return std.mem.order(i64, &pieces[a].head(), &pieces[b].head()) == .lt;
}

fn lessByTail(pieces: []const Piece, a: u32, b: u32) bool {
    return std.mem.order(i64, &pieces[a].tail(), &pieces[b].tail()) == .lt;
}

/// Which piece continues the walk from each piece's tail: a linear merge of
/// the pieces ordered by head against the same ordered by tail. Vertices
/// have degree two or four; a degree-four vertex is a pinch, where two cells
/// meet only at a corner, and the walk takes the right turn there, staying
/// with the material across the corner and keeping the two empty quadrants
/// apart. That makes `next` a permutation whose cycles are the boundaries a
/// figure has against each empty component: its outer ring, or a hole.
fn successorsInto(gpa: Allocator, sweep: *Sweep) Allocator.Error!void {
    const pieces = sweep.pieces.items;
    const n: u32 = @intCast(pieces.len);
    try sweep.order.resize(gpa, n);
    try sweep.by_end.resize(gpa, n);
    for (sweep.order.items, sweep.by_end.items, 0..) |*o, *e, i| {
        o.* = @intCast(i);
        e.* = @intCast(i);
    }
    std.mem.sortUnstable(u32, sweep.order.items, pieces, lessByHead);
    std.mem.sortUnstable(u32, sweep.by_end.items, pieces, lessByTail);
    try sweep.next.resize(gpa, n);
    @memset(sweep.next.items, std.math.maxInt(u32));
    const order = sweep.order.items;
    const by_end = sweep.by_end.items;

    var head: usize = 0;
    var tail: usize = 0;
    while (tail < n) {
        const point = pieces[by_end[tail]].tail();
        var tail_end = tail;
        while (tail_end < n and std.mem.eql(i64, &pieces[by_end[tail_end]].tail(), &point)) tail_end += 1;
        var head_end = head;
        while (head_end < n and std.mem.eql(i64, &pieces[order[head_end]].head(), &point)) head_end += 1;
        // A dropped piece would trace a polyline that validates as a polygon
        // of the wrong area.
        assert(head < head_end);
        for (by_end[tail..tail_end]) |arrival| {
            const d = pieces[arrival].dir();
            const want = [2]i64{ d[1], -d[0] };
            // The right turn if present (a pinch), else the group's first.
            var pick = order[head];
            for (order[head..head_end]) |departure| {
                if (std.mem.eql(i64, &pieces[departure].dir(), &want)) pick = departure;
            }
            sweep.next.items[arrival] = pick;
        }
        head = head_end;
        tail = tail_end;
    }
}

/// Walks the successor permutation into closed rings, into `out` (cleared
/// and refilled).
fn link(gpa: Allocator, sweep: *Sweep, out: *Rings) Allocator.Error!void {
    const pieces = sweep.pieces.items;
    const next = sweep.next.items;
    try out.reset(gpa);
    const used = try gpa.alloc(bool, pieces.len);
    defer gpa.free(used);
    @memset(used, false);
    for (0..pieces.len) |seed| {
        if (used[seed]) continue;
        var cur = seed;
        while (true) {
            used[cur] = true;
            try out.push(gpa, pieces[cur].sx, pieces[cur].sy);
            const step: usize = next[cur];
            if (step == seed) break;
            // `next` is a permutation (see `successorsInto`).
            assert(!used[step]);
            cur = step;
        }
        try out.closeRing(gpa);
    }
    // A piece in no ring is area missing from the result.
    assert(out.xs.items.len == pieces.len);
}
