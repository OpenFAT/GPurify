//! Graph colouring for multi-patterning: can a conflict graph over `0 ..
//! node_count` take at most `colors` colours with no conflict joining two
//! nodes of one colour, and can it while honouring pre-coloured (anchored)
//! nodes. Two colours is a bipartiteness test (never gives up); three or
//! more a DSATUR search with backtracking under a budget, whose exhaustion
//! is its own answer, never "colourable". Ported from
//! crates/check/src/drc/rules/patterning.rs (`color_into`, `two_color_into`,
//! `SatQueue`, `anchor_conflict`, `Coloring`, `Anchoring`).
//!
//! Contents:
//! - `pub const Coloring = union(enum)`, `pub const Anchoring = union(enum)`
//! - `pub fn colorInto(gpa: Allocator, node_count: u32, conflicts: []const [2]u32, colors: u8, out: *std.ArrayList(u8)) Allocator.Error!Coloring`
//! - `pub fn anchorConflict(gpa: Allocator, node_count: u32, conflicts: []const [2]u32, anchors: []const u8, colors: u8, out: *std.ArrayList(u8)) Allocator.Error!Anchoring`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// How a colouring attempt ended.
pub const Coloring = union(enum) {
    /// Every node has a colour, in `out`.
    complete,
    /// Proved uncolourable. The node is canonical: the lowest root of an
    /// odd-cycle component (2 colours); otherwise the lowest node
    /// conflicting with itself, else the lowest node the search could not
    /// place.
    infeasible: u32,
    /// The budget ran out with no answer either way (3+ colours only).
    exhausted,
};

/// How honouring pre-coloured nodes ended, on one connected conflict graph.
pub const Anchoring = union(enum) {
    /// A colouring gives every anchored node its anchor's colour.
    honoured,
    /// No colouring exists, anchors aside (`colorInto` proves it).
    unsplittable,
    /// Colourings exist, and none honours the anchors. `node` is anchored.
    /// With two colours `other` is the first anchored node whose anchor the
    /// colouring through `node`'s contradicts (an anchor path), and null
    /// means `node` holds two anchors (an anchor self-conflict); with more,
    /// `node` is the lowest anchored node and `other` is null.
    conflict: struct { node: u32, other: ?u32 },
    /// The colouring search ran out of budget (three or more colours).
    exhausted,
};

/// Search-step floor; a call gets `max(this, nodes × steps_per_node)`.
const search_budget: u32 = 1 << 20;
const steps_per_node: u32 = 64;
const uncolored: u8 = std.math.maxInt(u8);

/// Colours a conflict graph over `0 .. node_count` with at most `colors`
/// colours. `out` holds the colouring on `complete` and is left empty
/// otherwise. Exact either way it answers; three or more colours are capped
/// at `max(2^20, 64 * node_count)` placements. Zero colours is infeasible
/// for any non-empty graph; a conflict `(a, a)` makes any graph infeasible.
/// Asserts every conflict names a node below `node_count`.
pub fn colorInto(gpa: Allocator, node_count: u32, conflicts: []const [2]u32, colors: u8, out: *std.ArrayList(u8)) Allocator.Error!Coloring {
    out.clearRetainingCapacity();
    const n: usize = node_count;
    if (n == 0) return .complete;
    if (colors == 0) return .{ .infeasible = 0 };
    const k: usize = colors;
    // CSR adjacency, one entry per endpoint.
    const adj_start = try gpa.alloc(u32, n + 1);
    defer gpa.free(adj_start);
    @memset(adj_start, 0);
    for (conflicts) |e| {
        assert(e[0] < node_count and e[1] < node_count);
        adj_start[e[0] + 1] += 1;
        adj_start[e[1] + 1] += 1;
    }
    for (1..n + 1) |node| adj_start[node] += adj_start[node - 1];
    const cursor = try gpa.dupe(u32, adj_start);
    defer gpa.free(cursor);
    const adj = try gpa.alloc(u32, 2 * conflicts.len);
    defer gpa.free(adj);
    for (conflicts) |e| {
        adj[cursor[e[0]]] = e[1];
        cursor[e[0]] += 1;
        adj[cursor[e[1]]] = e[0];
        cursor[e[1]] += 1;
    }
    try out.appendNTimes(gpa, uncolored, n);
    if (colors == 2) return twoColor(gpa, adj_start, adj, out);
    // A node conflicting with itself takes no colour; the search below
    // never checks a placed node against itself.
    var self_loop: ?u32 = null;
    for (conflicts) |e| if (e[0] == e[1]) {
        self_loop = @min(self_loop orelse e[0], e[0]);
    };
    if (self_loop) |node| {
        out.clearRetainingCapacity();
        return .{ .infeasible = node };
    }
    // `adjacent[node * k + c]`: neighbours of `node` holding colour `c`.
    const adjacent = try gpa.alloc(u32, n * k);
    defer gpa.free(adjacent);
    @memset(adjacent, 0);
    const sat = try gpa.alloc(u32, n);
    defer gpa.free(sat);
    @memset(sat, 0);
    // The search stack: node placed at each depth, next colour to try, and
    // distinct colours used above it.
    const pick = try gpa.alloc(u32, n);
    defer gpa.free(pick);
    const next = try gpa.alloc(u8, n);
    defer gpa.free(next);
    @memset(next, 0);
    const used = try gpa.alloc(u8, n + 1);
    defer gpa.free(used);
    @memset(used, 0);
    var queue = try SatQueue.init(gpa, n, k, adj_start);
    defer queue.deinit(gpa);
    var budget = @max(search_budget, node_count *| steps_per_node);
    var unplaceable: u32 = std.math.maxInt(u32);
    var depth: usize = 0;
    pick[0] = queue.pick();
    while (depth < n) {
        const node: usize = pick[depth];
        // Symmetry breaking: a colour past the ones used is a rename of the
        // first unused one.
        const limit = @min(colors, used[depth] +| 1);
        var color = next[depth];
        while (color < limit and adjacent[node * k + color] > 0) color += 1;
        if (color < limit) {
            if (budget == 0) {
                out.clearRetainingCapacity();
                return .exhausted;
            }
            budget -= 1;
            next[depth] = color + 1;
            used[depth + 1] = @max(used[depth], color + 1);
            out.items[node] = color;
            queue.remove(pick[depth], sat[node]);
            for (adj[adj_start[node]..adj_start[node + 1]]) |nb| {
                const slot = @as(usize, nb) * k + color;
                const bump: u32 = @intFromBool(adjacent[slot] == 0);
                adjacent[slot] += 1;
                if (bump == 1 and out.items[nb] == uncolored) queue.shift(nb, sat[nb], sat[nb] + 1);
                sat[nb] += bump;
            }
            depth += 1;
            if (depth < n) {
                pick[depth] = queue.pick();
                next[depth] = 0;
            }
        } else {
            // Only a node that failed before trying any colour is unplaceable.
            if (next[depth] == 0) unplaceable = @min(unplaceable, pick[depth]);
            if (depth == 0) {
                out.clearRetainingCapacity();
                return .{ .infeasible = @min(unplaceable, node_count - 1) };
            }
            depth -= 1;
            const placed: usize = pick[depth];
            const placed_color = out.items[placed];
            for (adj[adj_start[placed]..adj_start[placed + 1]]) |nb| {
                const slot = @as(usize, nb) * k + placed_color;
                adjacent[slot] -= 1;
                const drop: u32 = @intFromBool(adjacent[slot] == 0);
                if (drop == 1 and out.items[nb] == uncolored) queue.shift(nb, sat[nb], sat[nb] - 1);
                sat[nb] -= drop;
            }
            out.items[placed] = uncolored;
            queue.insert(pick[depth], sat[placed]);
        }
    }
    return .complete;
}

/// Whether a connected conflict graph over `0 .. node_count` can be
/// coloured with `colors` colours so that each anchored node takes its
/// anchor's colour: node `i` is anchored to colour `c` when bit `c` of
/// `anchors[i]` is set (two bits can never both be honoured). `out` is
/// scratch. Exact: two colours compare against `colorInto`'s colouring
/// (unique up to a swap on a connected graph); more colour the graph plus a
/// clique of one node per colour, each anchored node joined to every colour
/// node but its anchor's, under the same search and budget.
pub fn anchorConflict(gpa: Allocator, node_count: u32, conflicts: []const [2]u32, anchors: []const u8, colors: u8, out: *std.ArrayList(u8)) Allocator.Error!Anchoring {
    assert(anchors.len >= node_count);
    switch (try colorInto(gpa, node_count, conflicts, colors, out)) {
        .complete => {},
        .infeasible => return .unsplittable,
        .exhausted => return .exhausted,
    }
    var first: ?u32 = null;
    for (0..node_count) |node| if (anchors[node] != 0) {
        first = @intCast(node);
        break;
    };
    const u = first orelse return .honoured;
    if (@popCount(anchors[u]) > 1) return .{ .conflict = .{ .node = u, .other = null } };
    if (colors == 2) {
        for (u + 1..node_count) |v_| {
            const v: u32 = @intCast(v_);
            if (anchors[v] == 0) continue;
            if (@popCount(anchors[v]) > 1) return .{ .conflict = .{ .node = v, .other = null } };
            const same_anchor = anchors[v] == anchors[u];
            if (same_anchor != (out.items[v] == out.items[u])) return .{ .conflict = .{ .node = u, .other = v } };
        }
        return .honoured;
    }
    const k: u32 = colors;
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try edges.appendSlice(gpa, conflicts);
    for (0..k) |a| for (a + 1..k) |b| try edges.append(gpa, .{ node_count + @as(u32, @intCast(a)), node_count + @as(u32, @intCast(b)) });
    for (0..node_count) |node| {
        const held = anchors[node];
        if (held == 0) continue;
        const own: u32 = if (@popCount(held) > 1) std.math.maxInt(u32) else @ctz(held);
        for (0..k) |c| if (c != own) try edges.append(gpa, .{ @intCast(node), node_count + @as(u32, @intCast(c)) });
    }
    return switch (try colorInto(gpa, node_count + k, edges.items, colors, out)) {
        .complete => .honoured,
        .infeasible => .{ .conflict = .{ .node = u, .other = null } },
        .exhausted => .exhausted,
    };
}

// ---- private ----

/// Two colours by BFS from each component's lowest node; the reported node
/// is the root of the first odd-cycle component.
fn twoColor(gpa: Allocator, adj_start: []const u32, adj: []const u32, out: *std.ArrayList(u8)) Allocator.Error!Coloring {
    const n = out.items.len;
    const frontier = try gpa.alloc(u32, n);
    defer gpa.free(frontier);
    var len: usize = 0;
    var head: usize = 0;
    for (0..n) |root| {
        if (out.items[root] != uncolored) continue;
        out.items[root] = 0;
        frontier[len] = @intCast(root);
        len += 1;
        var odd = false;
        while (head < len) {
            const node = frontier[head];
            head += 1;
            const here = out.items[node];
            for (adj[adj_start[node]..adj_start[node + 1]]) |nb| {
                odd = odd or out.items[nb] == here;
                if (out.items[nb] == uncolored) {
                    out.items[nb] = here ^ 1;
                    frontier[len] = nb;
                    len += 1;
                }
            }
        }
        if (odd) {
            out.clearRetainingCapacity();
            return .{ .infeasible = @intCast(root) };
        }
    }
    return .complete;
}

/// The uncoloured nodes bucketed by saturation. Within a bucket the order
/// is static (highest degree, then lowest index), so a bucket is a bitset
/// over ranks, with one summary bit per non-zero word.
const SatQueue = struct {
    /// `by_rank[r]` is the node at rank `r`; `rank` is the inverse.
    by_rank: []u32,
    rank: []u32,
    bits: []u64,
    summary: []u64,
    /// Live nodes per bucket.
    count: []u32,
    words: usize,
    summary_words: usize,

    /// Every node uncoloured at saturation zero.
    fn init(gpa: Allocator, n: usize, k: usize, adj_start: []const u32) Allocator.Error!SatQueue {
        const words = std.math.divCeil(usize, n, 64) catch unreachable;
        const summary_words = std.math.divCeil(usize, words, 64) catch unreachable;
        const by_rank = try gpa.alloc(u32, n);
        errdefer gpa.free(by_rank);
        for (by_rank, 0..) |*r, i| r.* = @intCast(i);
        std.mem.sortUnstable(u32, by_rank, adj_start, struct {
            fn less(a: []const u32, p: u32, q: u32) bool {
                const dp = a[p + 1] - a[p];
                const dq = a[q + 1] - a[q];
                return dp > dq or (dp == dq and p < q);
            }
        }.less);
        const rank = try gpa.alloc(u32, n);
        errdefer gpa.free(rank);
        for (by_rank, 0..) |node, r| rank[node] = @intCast(r);
        const bits = try gpa.alloc(u64, (k + 1) * words);
        errdefer gpa.free(bits);
        @memset(bits, 0);
        const summary = try gpa.alloc(u64, (k + 1) * summary_words);
        errdefer gpa.free(summary);
        @memset(summary, 0);
        const count = try gpa.alloc(u32, k + 1);
        @memset(count, 0);
        // Bucket zero starts full; tail words are masked so no bit past node
        // `n - 1` is live.
        @memset(bits[0..words], ~@as(u64, 0));
        bits[words - 1] >>= @intCast((64 - n % 64) % 64);
        @memset(summary[0..summary_words], ~@as(u64, 0));
        summary[summary_words - 1] >>= @intCast((64 - words % 64) % 64);
        count[0] = @intCast(n);
        return .{ .by_rank = by_rank, .rank = rank, .bits = bits, .summary = summary, .count = count, .words = words, .summary_words = summary_words };
    }

    fn deinit(q: *SatQueue, gpa: Allocator) void {
        gpa.free(q.by_rank);
        gpa.free(q.rank);
        gpa.free(q.bits);
        gpa.free(q.summary);
        gpa.free(q.count);
    }

    fn insert(q: *SatQueue, node: u32, sat: u32) void {
        const s = q.slots(node, sat);
        q.bits[s.word] |= @as(u64, 1) << s.bit;
        q.summary[s.sword] |= @as(u64, 1) << s.sbit;
        q.count[sat] += 1;
    }

    fn remove(q: *SatQueue, node: u32, sat: u32) void {
        const s = q.slots(node, sat);
        q.bits[s.word] &= ~(@as(u64, 1) << s.bit);
        if (q.bits[s.word] == 0) q.summary[s.sword] &= ~(@as(u64, 1) << s.sbit);
        q.count[sat] -= 1;
    }

    fn shift(q: *SatQueue, node: u32, from: u32, to: u32) void {
        q.remove(node, from);
        q.insert(node, to);
    }

    const Slots = struct { word: usize, bit: u6, sword: usize, sbit: u6 };

    fn slots(q: *const SatQueue, node: u32, sat: u32) Slots {
        const r: usize = q.rank[node];
        return .{ .word = sat * q.words + r / 64, .bit = @intCast(r % 64), .sword = sat * q.summary_words + r / 64 / 64, .sbit = @intCast(r / 64 % 64) };
    }

    /// The next DSATUR node: highest saturation, then highest degree, then
    /// lowest index.
    fn pick(q: *const SatQueue) u32 {
        var sat = q.count.len;
        while (sat > 0) {
            sat -= 1;
            if (q.count[sat] != 0) break;
        } else unreachable;
        const sbase = sat * q.summary_words;
        const sword = for (q.summary[sbase .. sbase + q.summary_words], 0..) |w, i| {
            if (w != 0) break i;
        } else unreachable;
        const word = sword * 64 + @ctz(q.summary[sbase + sword]);
        const live = q.bits[sat * q.words + word];
        return q.by_rank[word * 64 + @ctz(live)];
    }
};
