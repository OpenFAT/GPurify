//! Two extractions of one layout compared net by net: the netlist diff a
//! PEX flow is qualified with. In: a reference and a candidate
//! `ParasiticNetwork` over the same net ids, both canonical. Out: a
//! `Comparison`, each metric's value per net in both, and `errors`, the
//! statistics a qualification reports. Ported from
//! crates/extract/src/compare.rs.
//!
//! The metrics are Silvaco PEX Certify's: total and ground capacitance per
//! net (fF); net-to-net coupling (fF); pin-to-pin resistance, from the
//! net's first node (its driver) to the node farthest from it, the largest
//! `(G⁻¹)_jj` of its resistor network with the driver grounded (Ω); and the
//! Elmore delay (Elmore, J. Appl. Phys. 19(1), 1948) to its slowest node,
//! `max_j Σ_k (G⁻¹)_jk C_k`, each node's C its ground and coupling together
//! (Ω·fF = fs). A node no resistance reaches from the driver is left out of
//! both; a net of one node reads 0 of each. Inductance plays no part.
//!
//! Contents:
//! - `pub const max_dense_nodes: usize`
//! - `pub fn Metric(comptime K: type) type`, `Metric.deinit`
//! - `pub const Errors = struct`, `pub fn errors(reference: []const f64, candidate: []const f64, tolerance: f64, floor: f64) Errors`
//! - `pub const Comparison = struct`, `Comparison.empty`, `deinit`
//! - `pub fn compareInto(gpa: Allocator, reference: *const ParasiticNetwork, candidate: *const ParasiticNetwork, out: *Comparison) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const cholesky = @import("cholesky.zig");
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;

/// The largest net whose resistance and delay `compareInto` computes: its
/// conductance matrix is dense, 32 MiB at this size.
// ponytail: dense per net, capped; a sparse factorisation if a larger net is ever qualified.
pub const max_dense_nodes: usize = 2048;

/// How far the candidate is from the reference, relative to the reference.
pub const Errors = struct {
    /// Rows compared: those where either value reaches the floor.
    count: usize = 0,
    /// Of those, the rows within the tolerance.
    within: usize = 0,
    /// The largest relative error `|c − r| / |r|`, signed as `c − r`; 0 when
    /// nothing is compared, infinite where the reference is 0.
    worst: f64 = 0.0,
    /// The row it is in, null when nothing is compared.
    worst_row: ?usize = null,
    /// The mean of `|c − r| / |r|`.
    mean: f64 = 0.0,
    /// The root mean square of the relative errors.
    rms: f64 = 0.0,
};

/// Every metric of two extractions, over the nets both hold.
pub const Comparison = struct {
    /// Each net's total capacitance, ground and every coupling, fF.
    total_cap: Metric(u32) = .{},
    /// Each net's capacitance to ground, fF.
    ground_cap: Metric(u32) = .{},
    /// The coupling between two nets, fF; a pair coupled in only one
    /// extraction reads 0 in the other.
    coupling: Metric([2]u32) = .{},
    /// Pin-to-pin resistance, driver to its farthest node, Ω.
    resistance: Metric(u32) = .{},
    /// Elmore delay, driver to its slowest node, fs (Ω·fF).
    delay: Metric(u32) = .{},
    /// Nets with nodes in the reference only.
    only_reference: std.ArrayList(u32) = .empty,
    /// Nets with nodes in the candidate only.
    only_candidate: std.ArrayList(u32) = .empty,

    pub const empty: Comparison = .{};

    pub fn deinit(c: *Comparison, gpa: Allocator) void {
        c.total_cap.deinit(gpa);
        c.ground_cap.deinit(gpa);
        c.coupling.deinit(gpa);
        c.resistance.deinit(gpa);
        c.delay.deinit(gpa);
        c.only_reference.deinit(gpa);
        c.only_candidate.deinit(gpa);
    }
};

/// One network's metrics, dense by net id, and its pair couplings ascending.
const Summary = struct {
    held: []bool = &.{},
    total: []f64 = &.{},
    ground: []f64 = &.{},
    resistance: []f64 = &.{},
    delay: []f64 = &.{},
    pair_key: std.ArrayList([2]u32) = .empty,
    pair_value: std.ArrayList(f64) = .empty,

    fn deinit(s: *Summary, gpa: Allocator) void {
        inline for (.{ "held", "total", "ground", "resistance", "delay" }) |f| gpa.free(@field(s, f));
        s.pair_key.deinit(gpa);
        s.pair_value.deinit(gpa);
    }

    fn holds(s: *const Summary, net: u32) bool {
        return net < s.held.len and s.held[net];
    }

    fn of(s: *Summary, gpa: Allocator, n: *const ParasiticNetwork) Allocator.Error!void {
        var totals: std.ArrayList(f64) = .empty;
        defer totals.deinit(gpa);
        try n.capacitancePerNetInto(gpa, &totals);
        const nets = totals.items.len;
        s.held = try gpa.alloc(bool, nets);
        @memset(s.held, false);
        s.total = try gpa.dupe(f64, totals.items);
        s.ground = try gpa.alloc(f64, nets);
        @memset(s.ground, 0.0);
        s.resistance = try gpa.alloc(f64, nets);
        s.delay = try gpa.alloc(f64, nets);
        // Each node's capacitance, ground and coupling alike; each net's
        // ground part; each pair's coupling, in element order.
        const node_cap = try gpa.alloc(f64, n.nodeCount());
        defer gpa.free(node_cap);
        @memset(node_cap, 0.0);
        var pairs: std.ArrayList(Pair) = .empty;
        defer pairs.deinit(gpa);
        const net_of = n.node_net.items;
        for (n.from.items, n.to.items, n.kind.items, n.value.items) |near, far, kind, v| {
            switch (kind) {
                .ground_cap => {
                    node_cap[@backingInt(near)] += v;
                    s.ground[net_of[@backingInt(near)]] += v;
                },
                .coupling_cap => {
                    if (far == .ground) continue;
                    node_cap[@backingInt(near)] += v;
                    node_cap[@backingInt(far)] += v;
                    const a = net_of[@backingInt(near)];
                    const b = net_of[@backingInt(far)];
                    if (a != b) try pairs.append(gpa, .{ .key = .{ @min(a, b), @max(a, b) }, .value = v });
                },
                .resistance, .inductance, .mutual_inductance, .substrate_resistance => {},
            }
        }
        // Stable: each pair's run keeps element order, a strict fold.
        std.mem.sort(Pair, pairs.items, {}, Pair.less);
        s.pair_key.clearRetainingCapacity();
        s.pair_value.clearRetainingCapacity();
        for (pairs.items, 0..) |p, k| {
            if (k > 0 and std.mem.eql(u32, &pairs.items[k - 1].key, &p.key)) {
                s.pair_value.items[s.pair_value.items.len - 1] += p.value;
            } else {
                try s.pair_key.append(gpa, p.key);
                try s.pair_value.append(gpa, 0.0 + p.value);
            }
        }
        var start: usize = 0;
        while (start < net_of.len) {
            const net = net_of[start];
            var end = start;
            while (end < net_of.len and net_of[end] == net) end += 1;
            s.held[net] = true;
            const rd = try resistanceAndDelay(gpa, n, start, end, node_cap);
            s.resistance[net] = rd[0];
            s.delay[net] = rd[1];
            start = end;
        }
    }
};

const Pair = struct {
    key: [2]u32,
    value: f64,

    fn less(_: void, a: Pair, b: Pair) bool {
        return pairLess({}, a.key, b.key);
    }
};

const Resistor = struct { a: usize, b: usize, ohm: f64 };

/// One quantity per key in both extractions, as parallel columns in
/// ascending key order. Rung 5 (comptime key): two keys today, a net
/// (`u32`) and a pair of nets (`[2]u32`, lower first).
pub fn Metric(comptime K: type) type {
    return struct {
        key: std.ArrayList(K) = .empty,
        reference: std.ArrayList(f64) = .empty,
        candidate: std.ArrayList(f64) = .empty,

        const Self = @This();

        pub fn deinit(m: *Self, gpa: Allocator) void {
            m.key.deinit(gpa);
            m.reference.deinit(gpa);
            m.candidate.deinit(gpa);
        }

        // ---- private ----

        fn clear(m: *Self) void {
            m.key.clearRetainingCapacity();
            m.reference.clearRetainingCapacity();
            m.candidate.clearRetainingCapacity();
        }

        fn push(m: *Self, gpa: Allocator, key: K, reference: f64, candidate: f64) Allocator.Error!void {
            try m.key.append(gpa, key);
            try m.reference.append(gpa, reference);
            try m.candidate.append(gpa, candidate);
        }
    };
}

/// The relative error statistics over every row where the reference or the
/// candidate reaches `floor` in magnitude; a row is within when its
/// relative error is at most `tolerance`. Rows fold in order, so the result
/// is a function of the two columns alone.
pub fn errors(reference: []const f64, candidate: []const f64, tolerance: f64, floor: f64) Errors {
    assert(reference.len == candidate.len);
    var out: Errors = .{};
    var sum: f64 = 0.0;
    var squares: f64 = 0.0;
    for (reference, candidate, 0..) |r, c, row| {
        if (!(@abs(r) >= floor or @abs(c) >= floor)) continue;
        // Equal values are no error, a zero reference among them.
        const err = if (c - r == 0.0) 0.0 else (c - r) / @abs(r);
        const size = @abs(err);
        out.count += 1;
        out.within += @intFromBool(size <= tolerance);
        if (out.worst_row == null or size > @abs(out.worst)) {
            out.worst = err;
            out.worst_row = row;
        }
        sum += size;
        squares += size * size;
    }
    if (out.count > 0) {
        const n: f64 = @floatFromInt(out.count);
        out.mean = sum / n;
        out.rms = @sqrt(squares / n);
    }
    return out;
}

/// Compares `candidate` against `reference` into `out` (cleared), net by
/// net. Both must hold the node invariant and be canonical, as every
/// extraction leaves them. A net of more than `max_dense_nodes` nodes reads
/// NaN resistance and delay: not computed.
pub fn compareInto(gpa: Allocator, reference: *const ParasiticNetwork, candidate: *const ParasiticNetwork, out: *Comparison) Allocator.Error!void {
    inline for (.{ "total_cap", "ground_cap", "coupling", "resistance", "delay" }) |f| @field(out, f).clear();
    out.only_reference.clearRetainingCapacity();
    out.only_candidate.clearRetainingCapacity();
    var r: Summary = .{};
    defer r.deinit(gpa);
    try r.of(gpa, reference);
    var c: Summary = .{};
    defer c.deinit(gpa);
    try c.of(gpa, candidate);
    const nets = @max(r.held.len, c.held.len);
    for (0..nets) |n| {
        const net: u32 = @intCast(n);
        const here = r.holds(net);
        const there = c.holds(net);
        if (here and !there) try out.only_reference.append(gpa, net);
        if (there and !here) try out.only_candidate.append(gpa, net);
        if (!(here and there)) continue;
        try out.total_cap.push(gpa, net, r.total[n], c.total[n]);
        try out.ground_cap.push(gpa, net, r.ground[n], c.ground[n]);
        try out.resistance.push(gpa, net, r.resistance[n], c.resistance[n]);
        try out.delay.push(gpa, net, r.delay[n], c.delay[n]);
    }
    // Both pair lists ascend, so a merge visits every pair once in order.
    var i: usize = 0;
    var j: usize = 0;
    const rp = r.pair_key.items;
    const cp = c.pair_key.items;
    while (i < rp.len or j < cp.len) {
        const take_r = j == cp.len or (i < rp.len and !pairLess({}, cp[j], rp[i]));
        const take_c = i == rp.len or (j < cp.len and !pairLess({}, rp[i], cp[j]));
        const key = if (take_r) rp[i] else cp[j];
        const rv = if (take_r) r.pair_value.items[i] else 0.0;
        const cv = if (take_c) c.pair_value.items[j] else 0.0;
        i += @intFromBool(take_r);
        j += @intFromBool(take_c);
        if (r.holds(key[0]) and r.holds(key[1]) and c.holds(key[0]) and c.holds(key[1])) try out.coupling.push(gpa, key, rv, cv);
    }
}

// ---- private ----

fn pairLess(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

/// The pin-to-pin resistance and Elmore delay of the net on nodes
/// `start..end`, driven at `start`: the largest `(G⁻¹)_jj` and `(G⁻¹ c)_j`
/// over the nodes a resistance reaches, `G` the conductance matrix with the
/// driver grounded. `(0, 0)` for a net of one reachable node.
fn resistanceAndDelay(gpa: Allocator, n: *const ParasiticNetwork, start: usize, end: usize, node_cap: []const f64) Allocator.Error![2]f64 {
    const count = end - start;
    if (count > max_dense_nodes) return .{ std.math.nan(f64), std.math.nan(f64) };
    // A net's resistances all start on its own nodes: one run of a
    // canonical network.
    const first = lowerBound(n.from.items, start);
    const last = lowerBound(n.from.items, end);
    var resistors: std.ArrayList(Resistor) = .empty;
    defer resistors.deinit(gpa);
    for (n.from.items[first..last], n.to.items[first..last], n.kind.items[first..last], n.value.items[first..last]) |near, far, kind, v| {
        if (kind != .resistance or far == .ground) continue;
        const a: usize = @backingInt(near);
        const b: usize = @backingInt(far);
        if (a >= start and a < end and b >= start and b < end and v > 0.0) try resistors.append(gpa, .{ .a = a - start, .b = b - start, .ohm = v });
    }
    const reached = try gpa.alloc(bool, count);
    defer gpa.free(reached);
    @memset(reached, false);
    reached[0] = true;
    var grew = true;
    while (grew) {
        grew = false;
        for (resistors.items) |r| {
            if (reached[r.a] == reached[r.b]) continue;
            reached[r.a] = true;
            reached[r.b] = true;
            grew = true;
        }
    }
    // The reached nodes but the driver, numbered from 0.
    const index = try gpa.alloc(usize, count);
    defer gpa.free(index);
    var m: usize = 0;
    for (reached, index, 0..) |here, *ix, node| {
        ix.* = if (here and node > 0) m else std.math.maxInt(usize);
        m += @intFromBool(here and node > 0);
    }
    if (m == 0) return .{ 0.0, 0.0 };
    const g = try gpa.alloc(f64, m * m);
    defer gpa.free(g);
    @memset(g, 0.0);
    for (resistors.items) |r| {
        const conductance = 1.0 / r.ohm;
        for ([2][2]usize{ .{ r.a, r.b }, .{ r.b, r.a } }) |xy| {
            const x = xy[0];
            const y = xy[1];
            if (x == 0 or !reached[x]) continue;
            g[index[x] * m + index[x]] += conductance;
            if (y != 0) g[index[x] * m + index[y]] -= conductance;
        }
    }
    if (!cholesky.factorInPlace(g, m)) return .{ std.math.nan(f64), std.math.nan(f64) };
    const work = try gpa.alloc(f64, m);
    defer gpa.free(work);
    for (reached[1..], index[1..], 1..) |here, ix, node| {
        if (here) work[ix] = node_cap[start + node];
    }
    cholesky.solveInPlace(g, m, work);
    var delay: f64 = 0.0;
    for (work) |d| delay = @max(delay, d);
    var resistance: f64 = 0.0;
    for (0..m) |j| {
        @memset(work, 0.0);
        work[j] = 1.0;
        cholesky.solveInPlace(g, m, work);
        resistance = @max(resistance, work[j]);
    }
    return .{ resistance, delay };
}

/// The first element whose near node is at or past `node`.
fn lowerBound(from: []const NodeId, node: usize) usize {
    var lo: usize = 0;
    var hi: usize = from.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@backingInt(from[mid]) < node) lo = mid + 1 else hi = mid;
    }
    return lo;
}
