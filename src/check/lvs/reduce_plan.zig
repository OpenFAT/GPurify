//! One reduction pass's decision: which devices become one device under
//! one law, and which nets die with them. In: a `Graph`, the `ParamNames`,
//! a law. Out: a `Plan` (groups as `(root, row)` order, the consumed nets,
//! the net renumbering). Every condition is a refusal: under-reduction is
//! safe, over-reduction is not. Ported from crates/check/src/lvs/reduce.rs
//! (`plan_into`, `prepare`, `join_parallel`, `join_series`, `passive_pair`,
//! `dissolve_invalid`, `group_is_sound`, `mark_consumed`, `rank_nets`).
//!
//! Contents:
//! - `pub const MergeKind = enum { parallel, series }`
//! - `pub const Plan = struct`, `deinit(p: *Plan, gpa: Allocator) void`, `keys(p: *const Plan, device: u32) []const u64`
//! - `pub fn planInto(gpa: Allocator, src: *const Graph, names: ParamNames, mode: MergeKind, plan: *Plan) Allocator.Error!bool`
//! - `pub fn splitKeys(run: []const u64) [2][]const u64`, `pub fn keyNet(key: u64) u32`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const law = @import("reduce_law.zig");
const ParamNames = law.ParamNames;
const Law = law.Law;
const Sig = law.Sig;

/// Which law a merge applied.
pub const MergeKind = enum {
    /// Devices on the same nets became one: `W`/`nf` summed, or a count `m`,
    /// a relaxed value combined, or a gate's transistors kept.
    parallel,
    /// Devices stacked through an internal net became one and the net was
    /// consumed: `L` summed, a relaxed value combined, or a gate kept.
    series,
};

/// What one pass decided. Columns are per device (`root`, `parallel_ok`,
/// `series_ok`, the CSR runs) or per net (`consumed`, `new_net`, `is_port`).
pub const Plan = struct {
    /// The group's lowest device row; a device alone is its own root.
    root: std.ArrayList(u32) = .empty,
    /// Device rows sorted by `(root, row)`: a group is a contiguous run.
    order: std.ArrayList(u32) = .empty,
    /// Nets a series merge swallowed; never a port.
    consumed: std.ArrayList(bool) = .empty,
    /// The surviving net's row, or `no_net` for a consumed one, ascending.
    new_net: std.ArrayList(u32) = .empty,
    /// No terminal on no net, no black box, and a `W` (all four diffusions
    /// or none), a law, or the `m` name to count in.
    parallel_ok: std.ArrayList(bool) = .empty,
    /// Each device's terminal keys ascending, CSR.
    key_start: std.ArrayList(u32) = .empty,
    key: std.ArrayList(u64) = .empty,
    is_port: std.ArrayList(bool) = .empty,
    /// Candidate series nets and the two devices each joins, ascending by net.
    series: std.ArrayList([3]u32) = .empty,
    /// What a parallel merge needs equal (all but the summed), CSR.
    parallel_sig_start: std.ArrayList(u32) = .empty,
    parallel_sig: std.ArrayList(Sig) = .empty,
    /// Whether a device may merge in series at all (it states `L`, or is a
    /// relaxed passive, with every terminal on a net); then its signature, CSR.
    series_ok: std.ArrayList(bool) = .empty,
    series_sig_start: std.ArrayList(u32) = .empty,
    series_sig: std.ArrayList(Sig) = .empty,
    mode: MergeKind = .parallel,
    /// Groups after dissolution, and surviving nets: the counts emission writes.
    groups: u32 = 0,
    nets: u32 = 0,

    pub fn deinit(p: *Plan, gpa: Allocator) void {
        inline for (.{ "root", "order", "consumed", "new_net", "parallel_ok", "key_start", "key", "is_port", "series", "parallel_sig_start", "parallel_sig", "series_ok", "series_sig_start", "series_sig" }) |f| @field(p, f).deinit(gpa);
    }

    /// One device's terminal keys, ascending.
    pub fn keys(p: *const Plan, device: u32) []const u64 {
        return p.key.items[p.key_start.items[device]..p.key_start.items[device + 1]];
    }

    fn parallelSig(p: *const Plan, device: u32) []const Sig {
        return p.parallel_sig.items[p.parallel_sig_start.items[device]..p.parallel_sig_start.items[device + 1]];
    }

    fn seriesSig(p: *const Plan, device: u32) []const Sig {
        return p.series_sig.items[p.series_sig_start.items[device]..p.series_sig_start.items[device + 1]];
    }

    /// Both may merge in series and their signatures agree.
    fn seriesAgree(p: *const Plan, a: u32, b: u32) bool {
        return p.series_ok.items[a] and p.series_ok.items[b] and law.sigOrder(p.seriesSig(a), p.seriesSig(b)) == .eq;
    }
};

/// The merge code the channel collapses onto, past every `roleCode`
/// (at most 16 + 255): a device's channel keys sort last.
const channel_code: u64 = 1 << 16;

/// The lowest key a channel terminal carries.
const channel_base: u64 = channel_code << 32;

const ParallelCtx = struct {
    src: *const Graph,
    plan: *const Plan,

    /// `(kind, model, terminal keys, signature)`: what the device is and
    /// where every terminal lands.
    fn order(c: ParallelCtx, a: u32, b: u32) std.math.Order {
        const k = std.math.order(graph.kindCode(c.src.device_kind.items[a]), graph.kindCode(c.src.device_kind.items[b]));
        if (k != .eq) return k;
        const m = std.math.order(@backingInt(c.src.device_model.items[a]), @backingInt(c.src.device_model.items[b]));
        if (m != .eq) return m;
        const keys = std.mem.order(u64, c.plan.keys(a), c.plan.keys(b));
        if (keys != .eq) return keys;
        return law.sigOrder(c.plan.parallelSig(a), c.plan.parallelSig(b));
    }

    fn less(c: ParallelCtx, a: u32, b: u32) bool {
        const o = c.order(a, b);
        return if (o != .eq) o == .lt else a < b;
    }
};

const Far = struct { other: u32, symmetric: bool };

/// Decides one pass under `mode` into `plan`; returns whether anything
/// merged, the fixed-point test. Groups first, then (series) validation,
/// then the net renumbering, so a group that does not survive validation
/// does not take its nets with it.
pub fn planInto(gpa: Allocator, src: *const Graph, names: ParamNames, mode: MergeKind, plan: *Plan) Allocator.Error!bool {
    try prepare(gpa, src, names, plan);
    plan.mode = mode;
    switch (mode) {
        .parallel => try joinParallel(gpa, src, plan),
        .series => try joinSeries(gpa, src, plan),
    }
    // A parallel group needs no validation: its members share the head's
    // every terminal key (testing-plan F57).
    try orderByGroup(gpa, plan);
    switch (mode) {
        .parallel => {},
        .series => {
            dissolveInvalid(src, plan);
            try orderByGroup(gpa, plan);
        },
    }
    markConsumed(plan);
    try rankNets(gpa, plan);
    plan.groups = countGroups(plan);
    return plan.groups < src.deviceCount();
}

/// The non-channel prefix of a device's sorted keys, and the channel suffix.
pub fn splitKeys(run: []const u64) [2][]const u64 {
    var at: usize = 0;
    while (at < run.len and run[at] < channel_base) at += 1;
    return .{ run[0..at], run[at..] };
}

/// The net half of a terminal key.
pub fn keyNet(key: u64) u32 {
    return @truncate(key);
}

// ---- private ----

/// One terminal as a sortable `u64`: its merge code (the channel collapsed)
/// above its net. Injective in `(role class, net)`.
fn terminalKey(role: TerminalRole, net: u32) u64 {
    const code = if (law.isChannel(role)) channel_code else graph.roleCode(role);
    return (code << 32) | net;
}

/// The per-row columns every later step reads.
fn prepare(gpa: Allocator, src: *const Graph, names: ParamNames, plan: *Plan) Allocator.Error!void {
    const devices = src.deviceCount();
    const nets = src.netCount();
    plan.root.clearRetainingCapacity();
    for (0..devices) |d| try plan.root.append(gpa, @intCast(d));
    plan.consumed.clearRetainingCapacity();
    try plan.consumed.appendNTimes(gpa, false, nets);
    plan.series.clearRetainingCapacity();
    plan.is_port.clearRetainingCapacity();
    try plan.is_port.appendNTimes(gpa, false, nets);
    for (src.port_net.items) |n| plan.is_port.items[n] = true;

    inline for (.{ "key", "key_start", "parallel_ok", "parallel_sig", "parallel_sig_start", "series_ok", "series_sig", "series_sig_start" }) |f| @field(plan, f).clearRetainingCapacity();
    try plan.key_start.append(gpa, 0);
    try plan.parallel_sig_start.append(gpa, 0);
    try plan.series_sig_start.append(gpa, 0);
    for (0..devices) |di| {
        const device: u32 = @intCast(di);
        const t = src.terminalsOf(device);
        const from = plan.key.items.len;
        for (t.nets, t.roles) |n, role| try plan.key.append(gpa, terminalKey(role, n));
        std.mem.sortUnstable(u64, plan.key.items[from..], {}, std.sort.asc(u64));
        try plan.key_start.append(gpa, @intCast(plan.key.items.len));

        // Every refusal is stated in reduce.zig's header.
        const params = src.paramsOf(device);
        const kind = src.device_kind.items[device];
        const bound = std.mem.indexOfScalar(u32, t.nets, no_net) == null;
        // A merge with no `W` keeps the count under the `m` name (F83);
        // one with a `W` needs nothing else (F84).
        const wide = law.sumsWidth(kind, params, names);
        const device_law = Law.of(kind, params, names);
        // Diffusions are summed end by end: all four or none.
        const diffusions = names.diffusionsIn(params);
        const whole = diffusions == 0 or diffusions == names.diffusion.len;
        const counts = !wide and device_law == null and names.multiplier != null;
        const cell = kind == .cell;
        try plan.parallel_ok.append(gpa, bound and !cell and ((wide and whole) or device_law != null or counts));
        const counted = if (!wide and device_law == null) names.multiplier else null;
        const sums = if (device_law) |l| l.sums() else law.parallelSums(wide, names);
        try law.signatureInto(gpa, params, &sums, counted, &plan.parallel_sig);
        try plan.parallel_sig_start.append(gpa, @intCast(plan.parallel_sig.items.len));

        // A relaxed resistor or capacitor stating its value merges in
        // series by its law; any other device by its `L`.
        const passive: ?law.Sums = if (device_law) |l| (if (t.roles.len == 2) l.seriesSums(kind, names) else null) else null;
        var stressed = false;
        for (names.stress) |s| stressed = stressed or law.states(params, s);
        if (passive) |sums_series| {
            try plan.series_ok.append(gpa, bound);
            if (bound) try law.signatureInto(gpa, params, &sums_series, null, &plan.series_sig);
        } else {
            const ok = law.states(params, names.length) and bound and diffusions == 0 and !stressed and !law.seriesPassive(kind);
            try plan.series_ok.append(gpa, ok);
            if (ok) try law.signatureInto(gpa, params, &.{names.length}, null, &plan.series_sig);
        }
        try plan.series_sig_start.append(gpa, @intCast(plan.series_sig.items.len));
    }
}

/// Joins every run of devices whose whole terminal map and signature agree,
/// row as final tie-break; an unmergeable device is skipped, never splitting
/// the run it sits in.
fn joinParallel(gpa: Allocator, src: *const Graph, plan: *Plan) Allocator.Error!void {
    plan.order.clearRetainingCapacity();
    for (0..src.deviceCount()) |d| try plan.order.append(gpa, @intCast(d));
    const ctx: ParallelCtx = .{ .src = src, .plan = plan };
    std.mem.sortUnstable(u32, plan.order.items, ctx, ParallelCtx.less);
    const order = plan.order.items;
    var at: usize = 0;
    while (at < order.len) {
        var end = at + 1;
        while (end < order.len and ctx.order(order[at], order[end]) == .eq) end += 1;
        var anchor: u32 = no_net;
        for (order[at..end]) |device| {
            if (!plan.parallel_ok.items[device]) continue;
            if (anchor == no_net) anchor = device else graph.join(plan.root.items, anchor, device);
        }
        at = end;
    }
}

/// Joins every pair of devices meeting at a net nothing else reaches. Every
/// condition reads the graph as given, so all joins are decided before any
/// is made, which folds a chain of three in one pass.
fn joinSeries(gpa: Allocator, src: *const Graph, plan: *Plan) Allocator.Error!void {
    for (0..src.netCount()) |ni| {
        const net: u32 = @intCast(ni);
        const on = src.terminalsOn(net);
        if (on.devices.len != 2) continue;
        const first = on.devices[0];
        const second = on.devices[1];
        // A port is reachable from outside; a name alone does not stop the
        // merge, since every reference net has one (testing-plan F12).
        if (plan.is_port.items[net]) continue;
        // Two terminals of one device: a shorted device, nothing to join.
        if (first == second) continue;
        if (law.seriesPassive(src.device_kind.items[first])) {
            if (passivePair(src, plan, net, first, second, on.roles)) {
                graph.join(plan.root.items, first, second);
                try plan.series.append(gpa, .{ net, first, second });
            }
            continue;
        }
        if (!(law.isChannel(on.roles[0]) and law.isChannel(on.roles[1]))) continue;
        // Two stacked devices are one only as long as the two lengths (F67).
        if (src.device_kind.items[first] != src.device_kind.items[second] or
            src.device_model.items[first] != src.device_model.items[second] or
            !plan.seriesAgree(first, second)) continue;
        const a = splitKeys(plan.keys(first));
        const b = splitKeys(plan.keys(second));
        // Every terminal outside the channel agrees, and there is one.
        if (a[0].len == 0 or !std.mem.eql(u64, a[0], b[0])) continue;
        // Exactly two channel ends each, or "the other end" is not one net.
        if (a[1].len != 2 or b[1].len != 2) continue;
        // Two devices in parallel read as in series through either shared net.
        if (otherEnd(a[1], net) == otherEnd(b[1], net)) continue;
        graph.join(plan.root.items, first, second);
        try plan.series.append(gpa, .{ net, first, second });
    }
}

/// Whether two relaxed passives meet in series at `net`: one kind, one
/// model, agreeing series signatures, far ends on two other nets; ordered
/// plates (unless one role covers both pins) chain plate to plate.
fn passivePair(src: *const Graph, plan: *const Plan, net: u32, first: u32, second: u32, roles: []const TerminalRole) bool {
    if (src.device_kind.items[first] != src.device_kind.items[second] or
        src.device_model.items[first] != src.device_model.items[second] or
        !plan.seriesAgree(first, second)) return false;
    const fa = far(src, first, net);
    const fb = far(src, second, net);
    return fa.other != net and fb.other != net and fa.other != fb.other and (fa.symmetric or !graph.roleEql(roles[0], roles[1]));
}

fn far(src: *const Graph, device: u32, net: u32) Far {
    const t = src.terminalsOf(device);
    return .{
        .other = if (t.nets[0] == net) t.nets[1] else t.nets[0],
        .symmetric = graph.roleEql(t.roles[0], t.roles[1]),
    };
}

/// The far net of a two-terminal channel from `net`; `net` itself when both
/// ends are on it.
fn otherEnd(channel: []const u64, net: u32) u32 {
    const low = keyNet(channel[0]);
    return if (low == net) keyNet(channel[1]) else low;
}

/// Device rows sorted into `(root, row)` order, roots resolved first.
fn orderByGroup(gpa: Allocator, plan: *Plan) Allocator.Error!void {
    const root = plan.root.items;
    for (0..root.len) |d| root[d] = graph.find(root, @intCast(d));
    plan.order.clearRetainingCapacity();
    for (0..root.len) |d| {
        assert(root[d] <= d and root[root[d]] == root[d]);
        try plan.order.append(gpa, @intCast(d));
    }
    std.mem.sortUnstable(u32, plan.order.items, root, struct {
        fn less(r: []u32, a: u32, b: u32) bool {
            return if (r[a] != r[b]) r[a] < r[b] else a < b;
        }
    }.less);
}

/// Breaks up every series group that would not be one well-formed device:
/// pairwise joins close transitively (three tied-gate transistors in a ring
/// are three legal pairs and no device).
fn dissolveInvalid(src: *const Graph, plan: *Plan) void {
    markConsumed(plan);
    const order = plan.order.items;
    var at: usize = 0;
    while (at < order.len) {
        const end = runEnd(plan, at);
        if (end - at > 1 and !groupIsSound(src, plan, order[at..end])) {
            for (order[at..end]) |device| plan.root.items[device] = device;
        }
        at = end;
    }
}

/// The end of the group run starting at `at` in `plan.order`.
fn runEnd(plan: *const Plan, at: usize) usize {
    const order = plan.order.items;
    var end = at + 1;
    while (end < order.len and plan.root.items[order[end]] == plan.root.items[order[at]]) end += 1;
    return end;
}

/// One series group is one device: same kind and model, same non-channel
/// keys, and as many surviving channel ends as one member has.
fn groupIsSound(src: *const Graph, plan: *const Plan, group: []const u32) bool {
    const head = group[0];
    const kind = src.device_kind.items[head];
    const model = src.device_model.items[head];
    if (law.seriesPassive(kind)) return passiveGroupIsSound(src, plan, group);
    const head_keys = splitKeys(plan.keys(head));
    // More than two channel ends is malformed: a refusal, not an assert.
    var seen: [2]u32 = .{ no_net, no_net };
    if (head_keys[1].len > seen.len) return false;
    var survivors: usize = 0;
    for (group) |device| {
        const k = splitKeys(plan.keys(device));
        if (src.device_kind.items[device] != kind or src.device_model.items[device] != model) return false;
        if (!std.mem.eql(u64, k[0], head_keys[0]) or k[1].len != head_keys[1].len) return false;
        for (k[1]) |key| {
            const n = keyNet(key);
            // A swallowed net, or one already a surviving end, is no new end.
            if (plan.consumed.items[n] or std.mem.indexOfScalar(u32, &seen, n) != null) continue;
            if (survivors == seen.len) return false;
            seen[survivors] = n;
            survivors += 1;
        }
    }
    return survivors == head_keys[1].len;
}

/// A series group of passives is one passive: one kind and model, and
/// exactly two terminals left on unconsumed nets, two different ones.
fn passiveGroupIsSound(src: *const Graph, plan: *const Plan, group: []const u32) bool {
    const head = group[0];
    var ends: [2]u32 = undefined;
    var count: usize = 0;
    for (group) |device| {
        if (src.device_kind.items[device] != src.device_kind.items[head] or
            src.device_model.items[device] != src.device_model.items[head]) return false;
        for (src.terminalsOf(device).nets) |n| {
            if (plan.consumed.items[n]) continue;
            if (count == ends.len) return false;
            ends[count] = n;
            count += 1;
        }
    }
    return count == 2 and ends[0] != ends[1];
}

/// Marks every candidate net whose two devices ended in one group.
fn markConsumed(plan: *Plan) void {
    @memset(plan.consumed.items, false);
    for (plan.series.items) |s| {
        if (plan.root.items[s[1]] == plan.root.items[s[2]]) plan.consumed.items[s[0]] = true;
    }
}

/// Ranks the surviving nets, ascending, into `new_net`.
fn rankNets(gpa: Allocator, plan: *Plan) Allocator.Error!void {
    plan.new_net.clearRetainingCapacity();
    var rank: u32 = 0;
    for (plan.consumed.items) |dead| {
        try plan.new_net.append(gpa, if (dead) no_net else rank);
        rank += @intFromBool(!dead);
    }
    plan.nets = rank;
}

/// Distinct roots, read off the sorted order.
fn countGroups(plan: *const Plan) u32 {
    var groups: u32 = 0;
    var last: u32 = no_net;
    for (plan.order.items) |device| {
        const head = plan.root.items[device];
        groups += @intFromBool(head != last);
        last = head;
    }
    return groups;
}
