//! Logic-gate reduction (catalog LVS-047): plain transistors of one model
//! stacked in series, or set in parallel, on different gates become one
//! device whose gates are interchangeable. Silvaco Guardian LVS's
//! definition ("Parallel/Series Merge and Reduction of Devices", and "Logic
//! Gate Recognition in Guardian LVS", 2020): a CMOS `NAND_N` is N n-channel
//! in series and N p-channel in parallel on the same N inputs, "all N input
//! terminals are swappable". In: a reduced `Graph`. Out: the graph with one
//! law applied once (cleared and refilled), and which input rows each output
//! device stands for, CSR. Ported from crates/check/src/lvs/gates.rs.
//!
//! What must hold, each a refusal otherwise (a false mismatch, never a false
//! match): every member a plain transistor (one gate, source, drain, at most
//! one bulk, every terminal on a net, no diffusion or stress stated); one
//! model and bit-identical parameters; one bulk net or none; each member on
//! a gate net of its own; parallel: one source/drain pair either way round;
//! series: a chain through nets only its two neighbours touch and no port,
//! ending on two distinct nets. Members already merged into a multi-gate
//! device are not plain, so nesting (an AOI) is not reduced.
//!
//! Contents:
//! - `pub fn passInto(gpa: Allocator, g: *const Graph, names: ParamNames, out: *Graph, group_start: *std.ArrayList(u32), group_rows: *std.ArrayList(u32)) Allocator.Error!?MergeKind`

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const law = @import("reduce_law.zig");
const ParamNames = law.ParamNames;
const Sig = law.Sig;
const MergeKind = @import("reduce_plan.zig").MergeKind;

/// A plain transistor's nets: gate, source, drain, bulk (`no_net` if none).
const Plain = struct { gate: u32, source: u32, drain: u32, bulk: u32 };

/// A run of `Work.group_rows`.
const Group = struct {
    from: u32,
    to: u32,

    fn less(rows: []u32, a: Group, b: Group) bool {
        return rows[a.from] < rows[b.from];
    }
};

/// `passInto`'s working tables, dead on return.
const Work = struct {
    plains: std.ArrayList(?Plain) = .empty,
    sig_start: std.ArrayList(u32) = .empty,
    sig: std.ArrayList(Sig) = .empty,
    root: std.ArrayList(u32) = .empty,
    consumed: std.ArrayList(bool) = .empty,
    is_port: std.ArrayList(bool) = .empty,
    keyed: std.ArrayList(u32) = .empty,
    group_start: std.ArrayList(u32) = .empty,
    group_rows: std.ArrayList(u32) = .empty,

    fn deinit(w: *Work, gpa: Allocator) void {
        inline for (@typeInfo(Work).@"struct".field_names) |f| @field(w, f).deinit(gpa);
    }

    fn sigOf(w: *const Work, d: u32) []const Sig {
        return w.sig.items[w.sig_start.items[d]..w.sig_start.items[d + 1]];
    }
};

/// The parallel key: model, the source/drain pair low end first, bulk,
/// signature; then gate and row.
const KeyCtx = struct {
    g: *const Graph,
    w: *const Work,

    fn pair(p: Plain) [2]u32 {
        return .{ @min(p.source, p.drain), @max(p.source, p.drain) };
    }

    fn sharedOrder(c: KeyCtx, a: u32, b: u32) std.math.Order {
        const pa = c.w.plains.items[a].?;
        const pb = c.w.plains.items[b].?;
        const m = std.math.order(@backingInt(c.g.device_model.items[a]), @backingInt(c.g.device_model.items[b]));
        if (m != .eq) return m;
        const p = std.mem.order(u32, &pair(pa), &pair(pb));
        if (p != .eq) return p;
        if (pa.bulk != pb.bulk) return std.math.order(pa.bulk, pb.bulk);
        return law.sigOrder(c.w.sigOf(a), c.w.sigOf(b));
    }

    fn shared(c: KeyCtx, a: u32, b: u32) bool {
        return c.sharedOrder(a, b) == .eq;
    }

    fn less(c: KeyCtx, a: u32, b: u32) bool {
        const o = c.sharedOrder(a, b);
        if (o != .eq) return o == .lt;
        const ga = c.w.plains.items[a].?.gate;
        const gb = c.w.plains.items[b].?.gate;
        return if (ga != gb) ga < gb else a < b;
    }
};

/// One pass, parallel groups first and, when there are none, series chains:
/// null when nothing merges. Otherwise writes the reduced graph to `out` and
/// each output device's input rows, ascending, to the CSR `group_*`, devices
/// ordered by their lowest row, as `reduceWith` orders its own groups.
pub fn passInto(gpa: Allocator, g: *const Graph, names: ParamNames, out: *Graph, group_start: *std.ArrayList(u32), group_rows: *std.ArrayList(u32)) Allocator.Error!?MergeKind {
    const devices = g.deviceCount();
    var w: Work = .{};
    defer w.deinit(gpa);
    try w.plains.resize(gpa, devices);
    try w.sig_start.append(gpa, 0);
    for (0..devices) |di| {
        const d: u32 = @intCast(di);
        w.plains.items[d] = plain(g, d, names);
        try law.signatureInto(gpa, g.paramsOf(d), &.{}, null, &w.sig);
        try w.sig_start.append(gpa, @intCast(w.sig.items.len));
        try w.root.append(gpa, d);
    }
    try w.consumed.appendNTimes(gpa, false, g.netCount());

    // Parallel: one source/drain pair, one bulk, model and signature, each
    // member on a gate of its own.
    for (0..devices) |di| {
        if (w.plains.items[di] != null) try w.keyed.append(gpa, @intCast(di));
    }
    const ctx: KeyCtx = .{ .g = g, .w = &w };
    std.mem.sortUnstable(u32, w.keyed.items, ctx, KeyCtx.less);
    var parallel = false;
    var at: usize = 0;
    const keyed = w.keyed.items;
    while (at < keyed.len) {
        var end = at + 1;
        while (end < keyed.len and ctx.shared(keyed[at], keyed[end])) end += 1;
        const run = keyed[at..end];
        at = end;
        // A gate shared within the run is a same-gate parallel merge's,
        // which reduction makes first; one left here keeps the run apart.
        if (run.len < 2) continue;
        const same_gate = for (run[0 .. run.len - 1], run[1..]) |a, b| {
            if (w.plains.items[a].?.gate == w.plains.items[b].?.gate) break true;
        } else false;
        if (same_gate) continue;
        for (run[1..]) |member| graph.join(w.root.items, run[0], member);
        parallel = true;
    }

    const kind: MergeKind = if (parallel) .parallel else blk: {
        // Series: chain plain transistors through nets only the two touch.
        try w.is_port.appendNTimes(gpa, false, g.netCount());
        for (g.port_net.items) |n| w.is_port.items[n] = true;
        var chained = false;
        for (0..g.netCount()) |ni| {
            const on = g.terminalsOn(@intCast(ni));
            if (on.devices.len != 2) continue;
            const a = on.devices[0];
            const b = on.devices[1];
            if (w.is_port.items[ni] or a == b or !law.isChannel(on.roles[0]) or !law.isChannel(on.roles[1])) continue;
            const pa = w.plains.items[a] orelse continue;
            const pb = w.plains.items[b] orelse continue;
            const same = g.device_model.items[a] == g.device_model.items[b] and
                law.sigOrder(w.sigOf(a), w.sigOf(b)) == .eq and pa.bulk == pb.bulk and pa.gate != pb.gate;
            if (same) {
                graph.join(w.root.items, a, b);
                w.consumed.items[ni] = true;
                chained = true;
            }
        }
        if (!chained) return null;
        break :blk .series;
    };

    // Groups, each checked; one that is not a sound chain falls apart.
    const all = try gpa.alloc(u32, devices);
    defer gpa.free(all);
    for (all, 0..) |*slot, d| slot.* = @intCast(d);
    try graph.groupsByRootInto(gpa, w.root.items, all, &w.group_start, &w.group_rows);
    var heads: std.ArrayList(Group) = .empty;
    defer heads.deinit(gpa);
    var merged_any = false;
    for (0..w.group_start.items.len - 1) |gi| {
        const group = w.group_rows.items[w.group_start.items[gi]..w.group_start.items[gi + 1]];
        if (group.len < 2 or sound(&w, group)) {
            merged_any = merged_any or group.len >= 2;
            try heads.append(gpa, .{ .from = w.group_start.items[gi], .to = w.group_start.items[gi + 1] });
        } else {
            for (group) |d| for (g.terminalsOf(d).nets) |n| {
                w.consumed.items[n] = false;
            };
            for (w.group_start.items[gi]..w.group_start.items[gi + 1]) |row| try heads.append(gpa, .{ .from = @intCast(row), .to = @intCast(row + 1) });
        }
    }
    if (!merged_any) return null;
    std.mem.sortUnstable(Group, heads.items, w.group_rows.items, Group.less);
    group_start.clearRetainingCapacity();
    group_rows.clearRetainingCapacity();
    try group_start.append(gpa, 0);
    for (heads.items) |h| {
        try group_rows.appendSlice(gpa, w.group_rows.items[h.from..h.to]);
        try group_start.append(gpa, @intCast(group_rows.items.len));
    }
    try emit(gpa, g, &w, group_start.items, group_rows.items, out);
    return kind;
}

// ---- private ----

/// `device` read as a plain transistor, or null.
fn plain(g: *const Graph, device: u32, names: ParamNames) ?Plain {
    if (g.device_kind.items[device] != .mos) return null;
    const t = g.terminalsOf(device);
    var slots: [4]u32 = @splat(no_net);
    for (t.nets, t.roles) |n, role| {
        if (n == no_net) return null;
        const slot: usize = switch (role) {
            .gate => 0,
            .source => 1,
            .drain => 2,
            .bulk => 3,
            .base, .emitter, .collector, .pin => return null,
        };
        if (slots[slot] != no_net) return null;
        slots[slot] = n;
    }
    const params = g.paramsOf(device);
    for (names.diffusion ++ names.stress) |name| if (law.states(params, name)) return null;
    if (slots[0] == no_net or slots[1] == no_net or slots[2] == no_net) return null;
    return .{ .gate = slots[0], .source = slots[1], .drain = slots[2], .bulk = slots[3] };
}

/// Whether a group is one multi-gate transistor: every gate its own net, and
/// the terminals on unconsumed nets one source and one drain on two distinct
/// nets (a parallel group's are its shared ends).
fn sound(w: *const Work, group: []const u32) bool {
    for (group, 0..) |a, i| for (group[i + 1 ..]) |b| {
        if (w.plains.items[a].?.gate == w.plains.items[b].?.gate) return false;
    };
    var ends: usize = 0;
    var first: [2]u32 = undefined;
    for (group) |d| {
        const p = w.plains.items[d].?;
        for ([_]u32{ p.source, p.drain }) |n| {
            if (w.consumed.items[n]) continue;
            if (ends < 2) first[ends] = n;
            ends += 1;
        }
    }
    if (ends == 2 * group.len) {
        // Every member on the head's two ends.
        const head = KeyCtx.pair(w.plains.items[group[0]].?);
        for (group) |d| if (!std.mem.eql(u32, &KeyCtx.pair(w.plains.items[d].?), &head)) return false;
        return head[0] != head[1];
    }
    return ends == 2 and first[0] != first[1];
}

/// `g` with each group one device, in group order, and the consumed nets
/// dropped, the survivors in their order.
fn emit(gpa: Allocator, g: *const Graph, w: *const Work, start: []const u32, rows: []const u32, out: *Graph) Allocator.Error!void {
    inline for (@typeInfo(Graph).@"struct".field_names) |f| @field(out, f).clearRetainingCapacity();
    const new_net = try gpa.alloc(u32, g.netCount());
    defer gpa.free(new_net);
    var next: u32 = 0;
    for (new_net, w.consumed.items, g.net_name.items) |*slot, dead, name| {
        slot.* = if (dead) no_net else next;
        if (!dead) {
            next += 1;
            try out.net_name.append(gpa, name);
        }
    }
    for (g.net_origin.items, 0..) |origin, n| if (new_net[n] != no_net) try out.net_origin.append(gpa, origin);
    for (g.port_net.items) |n| try out.port_net.append(gpa, new_net[n]);
    try out.device_terminal_start.append(gpa, 0);
    try out.device_param_start.append(gpa, 0);
    var gates: std.ArrayList(u32) = .empty;
    defer gates.deinit(gpa);
    for (0..start.len - 1) |gi| {
        const group = rows[start[gi]..start[gi + 1]];
        const head = group[0];
        try out.device_kind.append(gpa, g.device_kind.items[head]);
        try out.device_model.append(gpa, g.device_model.items[head]);
        try out.param.appendSlice(gpa, g.paramsOf(head));
        try out.device_param_start.append(gpa, @intCast(out.param.items.len));
        if (group.len == 1) {
            const t = g.terminalsOf(head);
            for (t.nets, t.roles) |n, role| {
                try out.terminal_net.append(gpa, if (n < new_net.len) new_net[n] else no_net);
                try out.terminal_role.append(gpa, role);
            }
        } else {
            gates.clearRetainingCapacity();
            for (group) |d| try gates.append(gpa, w.plains.items[d].?.gate);
            std.mem.sortUnstable(u32, gates.items, {}, std.sort.asc(u32));
            for (gates.items) |n| {
                try out.terminal_net.append(gpa, new_net[n]);
                try out.terminal_role.append(gpa, .gate);
            }
            // The chain's two surviving ends; a parallel group's head's.
            var ends: [2]u32 = undefined;
            var count: usize = 0;
            for (group) |d| {
                const p = w.plains.items[d].?;
                for ([_]u32{ p.source, p.drain }) |n| {
                    if (w.consumed.items[n]) continue;
                    if (count < 2) ends[count] = n;
                    count += 1;
                }
            }
            const lead = w.plains.items[head].?;
            if (count != 2) ends = .{ lead.source, lead.drain };
            try out.terminal_net.appendSlice(gpa, &.{ new_net[ends[0]], new_net[ends[1]] });
            try out.terminal_role.appendSlice(gpa, &.{ .source, .drain });
            if (lead.bulk != no_net) {
                try out.terminal_net.append(gpa, new_net[lead.bulk]);
                try out.terminal_role.append(gpa, .bulk);
            }
        }
        try out.device_terminal_start.append(gpa, @intCast(out.terminal_net.items.len));
    }
    try graph.transposeInto(gpa, out, next);
}
