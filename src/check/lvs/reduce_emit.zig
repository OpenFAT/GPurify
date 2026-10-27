//! Writes the graph one reduction pass planned: each group one device, the
//! consumed nets gone, the summed parameters totalled by the group's law,
//! the net side rebuilt by the transpose. In: a `Graph` and its `Plan`.
//! Out: a `Graph` (cleared and refilled). Ported from
//! crates/check/src/lvs/reduce.rs (`emit_into`, `merge_terminals`).
//!
//! Contents:
//! - `pub fn emitInto(gpa: Allocator, src: *const Graph, plan: *const Plan, names: ParamNames, out: *Graph) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const StrId = @import("geom").StrId;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const law = @import("reduce_law.zig");
const ParamNames = law.ParamNames;
const Law = law.Law;
const plan_mod = @import("reduce_plan.zig");
const Plan = plan_mod.Plan;

const Terminal = struct {
    role: TerminalRole,
    net: u32,

    fn less(_: void, a: Terminal, b: Terminal) bool {
        const ca = graph.roleCode(a.role);
        const cb = graph.roleCode(b.role);
        return if (ca != cb) ca < cb else a.net < b.net;
    }
};

/// Writes `plan` of `src` into `out`. A group of one is the device it
/// started as, which is what brings an unreducible graph through
/// byte-identical; a parallel group keeps its head's terminals; a series
/// group its head's non-channel terminals and one per surviving channel net.
pub fn emitInto(gpa: Allocator, src: *const Graph, plan: *const Plan, names: ParamNames, out: *Graph) Allocator.Error!void {
    inline for (@typeInfo(Graph).@"struct".field_names) |f| @field(out, f).clearRetainingCapacity();
    // A consumed net is never named, so dropping its row loses no name.
    for (src.net_name.items, plan.consumed.items) |name, dead| {
        if (!dead) try out.net_name.append(gpa, name);
    }
    for (src.port_net.items) |n| try out.port_net.append(gpa, plan.new_net.items[n]);
    try out.device_terminal_start.append(gpa, 0);
    try out.device_param_start.append(gpa, 0);

    var merged: std.ArrayList(Terminal) = .empty;
    defer merged.deinit(gpa);
    const order = plan.order.items;
    var at: usize = 0;
    while (at < order.len) {
        const head = order[at];
        var end = at + 1;
        while (end < order.len and plan.root.items[order[end]] == plan.root.items[head]) end += 1;
        const group = order[at..end];
        try out.device_kind.append(gpa, src.device_kind.items[head]);
        try out.device_model.append(gpa, src.device_model.items[head]);
        if (group.len == 1 or plan.mode == .parallel) {
            const t = src.terminalsOf(head);
            for (t.nets, t.roles) |n, role| {
                try out.terminal_net.append(gpa, if (n < plan.new_net.items.len) plan.new_net.items[n] else no_net);
                try out.terminal_role.append(gpa, role);
            }
        } else {
            try mergeTerminals(gpa, src, plan, group, &merged);
            for (merged.items) |t| {
                try out.terminal_net.append(gpa, plan.new_net.items[t.net]);
                try out.terminal_role.append(gpa, t.role);
            }
        }
        if (group.len == 1) {
            try out.param.appendSlice(gpa, src.paramsOf(head));
        } else {
            try mergeParams(gpa, src, plan, names, group, out);
        }
        try out.device_terminal_start.append(gpa, @intCast(out.terminal_net.items.len));
        try out.device_param_start.append(gpa, @intCast(out.param.items.len));
        at = end;
    }
    try graph.transposeInto(gpa, out, plan.nets);
}

// ---- private ----

/// The head's parameters, the summed ones totalled over the group (each
/// stated on every member or on none), a counted `m` written last.
fn mergeParams(gpa: Allocator, src: *const Graph, plan: *const Plan, names: ParamNames, group: []const u32, out: *Graph) Allocator.Error!void {
    const head = group[0];
    const kind = src.device_kind.items[head];
    const head_params = src.paramsOf(head);
    const wide = law.sumsWidth(kind, head_params, names);
    const head_law = Law.of(kind, head_params, names);
    const parallel_law: ?Law = if (plan.mode == .parallel) head_law else null;
    // A relaxed passive's series law, where this group is one.
    const series_sums: ?law.Sums = if (plan.mode == .series) (if (head_law) |l| l.seriesSums(kind, names) else null) else null;
    const summed: law.Sums = switch (plan.mode) {
        .series => series_sums orelse .{ names.length, null, null, null, null, null, null },
        .parallel => if (parallel_law) |l| l.sums() else law.parallelSums(wide, names),
    };
    // Combined harmonically: a resistance in parallel, a capacitance in series.
    const harmonic: ?struct { name: StrId, yes: bool } = blk: {
        if (parallel_law) |l| break :blk .{ .name = l.value, .yes = l.harmonic };
        if (series_sums != null) break :blk .{ .name = head_law.?.value, .yes = !head_law.?.harmonic };
        break :blk null;
    };
    // A member whose source is on the head's drain adds its `as` to the
    // head's `ad`: a diffusion is its net's.
    const head_ends = graph.channelEnds(src, head);
    // A device with no `W` keeps its count in `m`, summed with a missing one
    // read as 1, and written last.
    const counted: ?StrId = if (plan.mode == .parallel and !wide and parallel_law == null) names.multiplier else null;
    for (head_params) |p| {
        if (law.is(counted, p.name)) continue;
        var in_sum = false;
        for (summed) |s| in_sum = in_sum or law.is(s, p.name);
        var total = p.value;
        if (in_sum) {
            const harmonic_here = if (harmonic) |h| h.name == p.name and h.yes else false;
            var acc: f64 = -0.0;
            for (group) |d| {
                const crossed = !eqlOpt(head_ends[0], head_ends[1]) and eqlOpt(graph.channelEnds(src, d)[0], head_ends[1]);
                const read = if (crossed) names.across(p.name) else p.name;
                for (src.paramsOf(d)) |q| {
                    if (!law.is(read, q.name)) continue;
                    acc += if (harmonic_here) 1.0 / q.value else q.value;
                }
            }
            total = if (harmonic_here) 1.0 / acc else acc;
        }
        try out.param.append(gpa, .{ .name = p.name, .value = total });
    }
    if (counted) |multiplier| {
        var count: f64 = 0;
        for (group) |d| count += law.countOf(src.paramsOf(d), multiplier);
        try out.param.append(gpa, .{ .name = multiplier, .value = count });
    }
}

fn eqlOpt(a: ?u32, b: ?u32) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

/// One series-merged device's terminals in `(roleCode, net)` order: a
/// passive chain's two surviving ends with their roles; otherwise the head's
/// non-channel terminals plus one per surviving channel net.
fn mergeTerminals(gpa: Allocator, src: *const Graph, plan: *const Plan, group: []const u32, out: *std.ArrayList(Terminal)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const head = group[0];
    if (law.seriesPassive(src.device_kind.items[head])) {
        for (group) |d| {
            const t = src.terminalsOf(d);
            for (t.nets, t.roles) |n, role| {
                if (!plan.consumed.items[n]) try out.append(gpa, .{ .role = role, .net = n });
            }
        }
        std.mem.sortUnstable(Terminal, out.items, {}, Terminal.less);
        return;
    }
    const ht = src.terminalsOf(head);
    for (ht.nets, ht.roles) |n, role| {
        if (!law.isChannel(role)) try out.append(gpa, .{ .role = role, .net = n });
    }
    const fixed = out.items.len;
    for (group) |d| {
        const t = src.terminalsOf(d);
        for (t.nets, t.roles) |n, role| {
            if (!law.isChannel(role) or plan.consumed.items[n]) continue;
            const taken = for (out.items[fixed..]) |o| (if (o.net == n) break true) else false;
            if (!taken) try out.append(gpa, .{ .role = role, .net = n });
        }
    }
    std.mem.sortUnstable(Terminal, out.items, {}, Terminal.less);
}
