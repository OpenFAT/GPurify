//! Effective resistance between every terminal pair of one per-net
//! network row: interior nodes Kron-eliminated in minimum-degree order (a
//! Schur complement, which leaves every survivor-to-survivor effective
//! resistance unchanged), then each component's `k × k` terminal Laplacian
//! grounded at its lowest terminal and inverted exactly by Cholesky. In: a
//! `NetNetworks` row. Out: `(a, b, ohms)` with `a < b` ascending; a pair in
//! different components is absent (not infinite). Ported from
//! crates/check/src/erc/power.rs (`ElimGraph`, `cholesky_inverse_into`,
//! `effective_resistance_into`).
//!
//! Contents:
//! - `pub const Probe = struct { a: u32, b: u32, ohms: Ohms }`
//! - `pub const ProbeScratch = struct`, `deinit`
//! - `pub fn effectiveResistanceInto(gpa: Allocator, networks: *const NetNetworks, row: u32, scratch: *ProbeScratch, out: *std.ArrayList(Probe), diag: *PowerDiag) (PowerError || Allocator.Error)!void`
//! - `pub fn choleskyInverseInto(gpa: Allocator, a: []f64, n: usize, out: *std.ArrayList(f64)) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Ohms = @import("../report.zig").Ohms;
const grid_ = @import("power_grid.zig");
const NetNetworks = grid_.NetNetworks;
const PowerError = grid_.PowerError;
const PowerDiag = grid_.PowerDiag;
const none = grid_.not_a_node;
const badResistance = @import("power_solve.zig").badResistance;

/// One terminal pair's effective resistance, row-local node indices.
pub const Probe = struct { a: u32, b: u32, ohms: Ohms };

/// The probe workspace, reused row after row.
pub const ProbeScratch = struct {
    pairs: std.ArrayList([2]u32) = .empty,
    labels: std.ArrayList(u32) = .empty,
    done: std.ArrayList(bool) = .empty,
    elim: ElimGraph = .{},
    /// The `k × k` terminal Laplacian, row-major.
    dense: std.ArrayList(f64) = .empty,
    local: std.ArrayList(f64) = .empty,
    inverse: std.ArrayList(f64) = .empty,
    probe: std.ArrayList(f64) = .empty,
    /// Which terminal a node is, or `none`.
    terminal_of_node: std.ArrayList(u32) = .empty,
    group: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *ProbeScratch, gpa: Allocator) void {
        inline for (@typeInfo(ProbeScratch).@"struct".field_names) |f| @field(s, f).deinit(gpa);
    }
};

const QueueEntry = struct { degree: u32, v: u32 };

/// The graph a Kron elimination edits in place: a half-edge pool (edge `e`
/// is slots `2e`, `2e + 1`, twin `h ^ 1`) with linked incidence lists. A
/// dead half-edge carries zero conductance and is unlinked lazily.
const ElimGraph = struct {
    /// Head half-edge of each vertex's list, or `none`.
    head: std.ArrayList(u32) = .empty,
    alive: std.ArrayList(bool) = .empty,
    next: std.ArrayList(u32) = .empty,
    dst: std.ArrayList(u32) = .empty,
    /// Conductance per half-edge; zero is dead.
    g: std.ArrayList(f64) = .empty,
    /// Sparse accumulator: `slot[v]` valid only where `stamp[v] == epoch`.
    slot: std.ArrayList(u32) = .empty,
    stamp: std.ArrayList(u32) = .empty,
    epoch: u32 = 0,
    /// Deduplicated neighbours of the vertex being eliminated.
    fringe: std.ArrayList(Fringe) = .empty,
    /// Min-degree queue keyed `(degree, vertex)`, lazily invalidated; the
    /// vertex tie-break fixes the elimination order and so every rounding.
    queue: std.PriorityQueue(QueueEntry, void, queueOrder) = .empty,

    const Fringe = struct { v: u32, w: f64 };

    fn deinit(e: *ElimGraph, gpa: Allocator) void {
        inline for (.{ "head", "alive", "next", "dst", "g", "slot", "stamp", "fringe", "queue" }) |f| @field(e, f).deinit(gpa);
    }

    fn reset(e: *ElimGraph, gpa: Allocator, vertices: u32) Allocator.Error!void {
        inline for (.{ "head", "alive", "next", "dst", "g", "slot", "stamp", "fringe" }) |f| @field(e, f).clearRetainingCapacity();
        e.queue.clearRetainingCapacity();
        try e.head.appendNTimes(gpa, none, vertices);
        try e.alive.appendNTimes(gpa, true, vertices);
        try e.slot.appendNTimes(gpa, none, vertices);
        try e.stamp.appendNTimes(gpa, 0, vertices);
        e.epoch = 0;
    }

    /// A conductance between two distinct live vertices.
    fn link(e: *ElimGraph, gpa: Allocator, a: u32, b: u32, w: f64) Allocator.Error!void {
        assert(e.next.items.len + 2 < none);
        const h: u32 = @intCast(e.next.items.len);
        try e.next.appendSlice(gpa, &.{ e.head.items[a], e.head.items[b] });
        try e.dst.appendSlice(gpa, &.{ b, a });
        try e.g.appendSlice(gpa, &.{ w, w });
        e.head.items[a] = h;
        e.head.items[b] = h + 1;
    }

    /// Unlinks every dead half-edge of `v`; returns its live degree.
    fn refresh(e: *ElimGraph, v: u32) u32 {
        var live: u32 = 0;
        var prev = none;
        var h = e.head.items[v];
        while (h != none) {
            const after = e.next.items[h];
            const dead = !(e.g.items[h] > 0.0) or !e.alive.items[e.dst.items[h]] or e.dst.items[h] == v;
            if (dead) {
                if (prev == none) e.head.items[v] = after else e.next.items[prev] = after;
            } else {
                live += 1;
                prev = h;
            }
            h = after;
        }
        return live;
    }

    /// Kron-eliminates `v`: each neighbour pair gains `g_i g_j / d`. The
    /// touched neighbours are left in `fringe`.
    fn eliminate(e: *ElimGraph, gpa: Allocator, v: u32) Allocator.Error!void {
        e.epoch += 1;
        var epoch = e.epoch;
        e.fringe.clearRetainingCapacity();
        // Gather, deduplicate and unhook in one walk.
        var h = e.head.items[v];
        while (h != none) : (h = e.next.items[h]) {
            const u = e.dst.items[h];
            const w = e.g.items[h];
            if (w > 0.0 and e.alive.items[u] and u != v) {
                if (e.stamp.items[u] == epoch) {
                    e.fringe.items[e.slot.items[u]].w += w;
                } else {
                    e.stamp.items[u] = epoch;
                    e.slot.items[u] = @intCast(e.fringe.items.len);
                    try e.fringe.append(gpa, .{ .v = u, .w = w });
                }
            }
            e.g.items[h] = 0.0;
            e.g.items[h ^ 1] = 0.0;
        }
        e.alive.items[v] = false;
        e.head.items[v] = none;
        // Left fold in fringe order: the same bits every run.
        var total: f64 = 0.0;
        for (e.fringe.items) |f| total += f.w;
        if (!(total > 0.0 and std.math.isFinite(total))) return;
        for (0..e.fringe.items.len) |i| {
            const a = e.fringe.items[i];
            // Index `a`'s live neighbours so fill adds into an existing edge
            // instead of growing a parallel strand.
            _ = e.refresh(a.v);
            e.epoch += 1;
            epoch = e.epoch;
            var ha = e.head.items[a.v];
            while (ha != none) : (ha = e.next.items[ha]) {
                const u = e.dst.items[ha];
                e.stamp.items[u] = epoch;
                e.slot.items[u] = ha;
            }
            for (e.fringe.items[i + 1 ..]) |b| {
                const delta = a.w * b.w / total;
                if (e.stamp.items[b.v] == epoch) {
                    const slot = e.slot.items[b.v];
                    e.g.items[slot] += delta;
                    e.g.items[slot ^ 1] += delta;
                } else try e.link(gpa, a.v, b.v, delta);
            }
        }
    }
};

/// `out` refilled with every connected terminal pair's resistance.
/// `BadResistance` (`diag` the edge within the row) for an edge not
/// positive and finite; `NotFinite` (`diag` the component's grounded
/// terminal) when a terminal Laplacian will not invert. Asserts `row` is a
/// row of `networks`.
pub fn effectiveResistanceInto(gpa: Allocator, networks: *const NetNetworks, row: u32, scratch: *ProbeScratch, out: *std.ArrayList(Probe), diag: *PowerDiag) (PowerError || Allocator.Error)!void {
    out.clearRetainingCapacity();
    assert(row < networks.len());
    const nodes: u32 = @intCast(networks.nodesOf(row).len);
    const terminal = networks.terminalsOf(row);
    const edges = networks.edgesOf(row);
    try badResistance(edges.resistance, diag);
    const s = scratch;
    s.pairs.clearRetainingCapacity();
    for (edges.from, edges.to) |a, b| try s.pairs.append(gpa, .{ a, b });
    try geom.connectivity.componentsInto(gpa, nodes, s.pairs.items, &s.labels);
    const k = terminal.len;
    s.terminal_of_node.clearRetainingCapacity();
    try s.terminal_of_node.appendNTimes(gpa, none, nodes);
    for (terminal, 0..) |t, i| s.terminal_of_node.items[t] = @intCast(i);
    const of_node = s.terminal_of_node.items;

    // Kron-eliminate every interior node.
    const e = &s.elim;
    try e.reset(gpa, nodes);
    for (edges.from, edges.to, edges.resistance) |a, b, r| if (a != b) try e.link(gpa, a, b, 1.0 / r.raw);
    for (of_node, 0..) |t, node| if (t == none) {
        const v: u32 = @intCast(node);
        try e.queue.push(gpa, .{ .degree = e.refresh(v), .v = v });
    };
    // A popped entry whose degree is stale is re-queued at its current one.
    while (e.queue.pop()) |top| {
        if (!e.alive.items[top.v]) continue;
        const now = e.refresh(top.v);
        if (now != top.degree) {
            try e.queue.push(gpa, .{ .degree = now, .v = top.v });
            continue;
        }
        try e.eliminate(gpa, top.v);
        for (e.fringe.items) |f| if (of_node[f.v] == none) try e.queue.push(gpa, .{ .degree = e.refresh(f.v), .v = f.v });
    }

    // The terminal Laplacian.
    s.dense.clearRetainingCapacity();
    try s.dense.appendNTimes(gpa, 0.0, k * k);
    const dense = s.dense.items;
    for (terminal, 0..) |t, i| {
        _ = e.refresh(t);
        var h = e.head.items[t];
        while (h != none) : (h = e.next.items[h]) {
            const j = of_node[e.dst.items[h]];
            const w = e.g.items[h];
            dense[i * k + j] -= w;
            dense[i * k + i] += w;
        }
    }

    // Per component: ground its lowest terminal and invert the rest.
    s.probe.clearRetainingCapacity();
    try s.probe.appendNTimes(gpa, 0.0, k * k);
    s.done.clearRetainingCapacity();
    try s.done.appendNTimes(gpa, false, k);
    const labels = s.labels.items;
    for (0..k) |start| {
        if (s.done.items[start]) continue;
        const component = labels[terminal[start]];
        s.group.clearRetainingCapacity();
        for (terminal[start..], start..) |t, i| if (labels[t] == component) {
            s.done.items[i] = true;
            try s.group.append(gpa, @intCast(i));
        };
        const group = s.group.items;
        const m = group.len - 1;
        if (m == 0) continue;
        s.local.clearRetainingCapacity();
        try s.local.appendNTimes(gpa, 0.0, m * m);
        for (0..m) |p| for (0..m) |q| {
            s.local.items[p * m + q] = dense[group[p + 1] * k + group[q + 1]];
        };
        if (!try choleskyInverseInto(gpa, s.local.items, m, &s.inverse)) {
            diag.at = terminal[group[0]];
            return error.NotFinite;
        }
        const inv = s.inverse.items;
        // `R(a, b) = X_aa + X_bb - 2 X_ab`, the grounded terminal reading zero.
        for (0..group.len) |p| for (p + 1..group.len) |q| {
            const keep: f64 = @floatFromInt(@intFromBool(p != 0));
            const pi = @max(p, 1) - 1;
            const qi = q - 1;
            const xaa = inv[pi * m + pi] * keep;
            const xbb = inv[qi * m + qi];
            const xab = inv[pi * m + qi] * keep;
            s.probe.items[group[p] * k + group[q]] = xaa + xbb - 2.0 * xab;
        };
    }
    for (terminal, 0..) |a, i| for (terminal[i + 1 ..], i + 1..) |b, j| {
        if (labels[a] == labels[b]) try out.append(gpa, .{ .a = a, .b = b, .ohms = .{ .raw = s.probe.items[i * k + j] } });
    };
}

/// Inverts a dense SPD `n × n` row-major matrix by Cholesky into `out`;
/// `a` is consumed. False when a pivot is not positive and finite.
pub fn choleskyInverseInto(gpa: Allocator, a: []f64, n: usize, out: *std.ArrayList(f64)) Allocator.Error!bool {
    out.clearRetainingCapacity();
    try out.appendNTimes(gpa, 0.0, n * n);
    for (0..n) |j| {
        var d = a[j * n + j];
        for (0..j) |kk| d -= a[j * n + kk] * a[j * n + kk];
        if (!(d > 0.0 and std.math.isFinite(d))) return false;
        const l = @sqrt(d);
        a[j * n + j] = l;
        for (j + 1..n) |i| {
            var sum = a[i * n + j];
            for (0..j) |kk| sum -= a[i * n + kk] * a[j * n + kk];
            a[i * n + j] = sum / l;
        }
    }
    // One forward and one back substitution per unit vector.
    for (0..n) |c| {
        const row = out.items[c * n ..][0..n];
        row[c] = 1.0;
        for (0..n) |i| {
            var y = row[i];
            for (0..i) |kk| y -= a[i * n + kk] * row[kk];
            row[i] = y / a[i * n + i];
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            var x = row[i];
            for (i + 1..n) |kk| x -= a[kk * n + i] * row[kk];
            row[i] = x / a[i * n + i];
        }
    }
    return true;
}

// ---- private ----

fn queueOrder(_: void, a: QueueEntry, b: QueueEntry) std.math.Order {
    if (a.degree != b.degree) return std.math.order(a.degree, b.degree);
    return std.math.order(a.v, b.v);
}

/// Rust's in-file xorshift, a draw in `lo ..= hi`.
fn draw(state: *u64, lo: i64, hi: i64) i64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return lo + @as(i64, @intCast(state.* % @as(u64, @intCast(hi - lo + 1))));
}

test "cholesky inversion inverts a positive definite matrix and refuses others" {
    // Oracle: law: `A · A⁻¹ = I` (to 1e-9) for `A = B Bᵀ + I` over random
    // `B`, sizes 1 to 6; hand-derived refusals: `[[1, 2], [2, 1]]` has
    // second pivot `1 - 2² = -3`, `[[0]]` a zero pivot, `[[NaN]]` none; and
    // `[[4, 2], [2, 3]]` has inverse `[[3, -2], [-2, 4]] / 8`.
    const gpa = std.testing.allocator;
    var state: u64 = 0x1234_5678_9ABC_DEF1;
    var out: std.ArrayList(f64) = .empty;
    defer out.deinit(gpa);
    var a: [36]f64 = undefined;
    var keep: [36]f64 = undefined;
    var b: [36]f64 = undefined;
    for (1..7) |n| for (0..10) |_| {
        for (b[0 .. n * n]) |*x| x.* = @as(f64, @floatFromInt(draw(&state, -9, 9))) / 3.0;
        for (0..n) |i| for (0..n) |j| {
            var sum: f64 = 0.0;
            for (0..n) |kk| sum += b[i * n + kk] * b[j * n + kk];
            a[i * n + j] = sum + @as(f64, if (i == j) 1.0 else 0.0);
        };
        keep = a;
        try std.testing.expect(try choleskyInverseInto(gpa, a[0 .. n * n], n, &out));
        for (0..n) |i| for (0..n) |j| {
            var p: f64 = 0.0;
            for (0..n) |kk| p += keep[i * n + kk] * out.items[kk * n + j];
            try std.testing.expect(@abs(p - @as(f64, if (i == j) 1.0 else 0.0)) < 1e-9);
        };
    };
    var bad = [_]f64{ 1, 2, 2, 1 };
    try std.testing.expect(!try choleskyInverseInto(gpa, &bad, 2, &out));
    for ([_]f64{ 0.0, std.math.nan(f64), std.math.inf(f64) }) |x| {
        var one = [_]f64{x};
        try std.testing.expect(!try choleskyInverseInto(gpa, &one, 1, &out));
    }
    var good = [_]f64{ 4, 2, 2, 3 };
    try std.testing.expect(try choleskyInverseInto(gpa, &good, 2, &out));
    for (out.items, [_]f64{ 3.0 / 8.0, -2.0 / 8.0, -2.0 / 8.0, 4.0 / 8.0 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-12);
}
