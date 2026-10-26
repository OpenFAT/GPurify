//! The path kinds of the topological family: nets joined through MOS
//! source/drain and resistor pins. `supply_path` (ERC-G9, US20100306720A1
//! paths and breaks, Calibre `ERC PATHCHK`), `gate_path` (ERC-H3, shortest
//! device count to a rail), `net_type` (the patent's net checks over the
//! intent's net types) and `combinational_loop` (ERC-G8, cycles among
//! channel-connected components, Bryant ICCAD '91), and the pull-network
//! count `multiple_drivers` reads. In: nets, devices, facts, intent, net
//! types. Out: violations and one run per row. Ported from
//! crates/check/src/erc/rules/topology.rs.
//!
//! Contents:
//! - `pub fn checkSupplyPath(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, intent: *const IntentMap, t: *const SupplyPathTable) Allocator.Error!void`
//! - `pub fn checkGatePath(r: Record, design: Design, intent: *const IntentMap, t: *const GatePathTable) Allocator.Error!void`
//! - `pub fn checkNetType(r: Record, design: Design, facts: *const NetFacts, types: *const NetTypes, t: *const NetTypeTable) Allocator.Error!void`
//! - `pub fn checkCombinationalLoop(r: Record, design: Design, intent: *const IntentMap, t: *const CombinationalLoopTable) Allocator.Error!void`
//! - `pub fn driversInto(gpa: Allocator, design: Design, intent: *const IntentMap, out: *std.ArrayList([2]u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const components = geom.connectivity.componentsInto;
const NetId = @import("../topology/net.zig").NetId;
const PortTable = @import("../topology/port.zig").PortTable;
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const facts_ = @import("facts.zig");
const NetFacts = facts_.NetFacts;
const IntentMap = facts_.IntentMap;
const NetTypes = facts_.NetTypes;
const tables = @import("topology_tables.zig");
const Condition = tables.Condition;
const SupplyPathTable = tables.SupplyPathTable;
const GatePathTable = tables.GatePathTable;
const NetTypeTable = tables.NetTypeTable;
const CombinationalLoopTable = tables.CombinationalLoopTable;

/// No net: a device with no gate, or a channel end on no net.
const none: u32 = std.math.maxInt(u32);

/// A condition as masks; unsatisfiable when it requires an undeclared type.
const Masks = struct { present: u64 = 0, absent: u64 = 0, possible: bool = true };

/// Nets with no path to the supplies: paths join through MOS source/drain
/// and resistor pins, a declared supply breaks a path and gives it its role,
/// and with `labels_are_ports` a labelled net stops a path too. `both`
/// needs power and ground. `examined` counts device-connected non-supply
/// nets; a finding measures the roles reached against those needed.
pub fn checkSupplyPath(r: Record, design: Design, facts: *const NetFacts, ports: *const PortTable, intent: *const IntentMap, t: *const SupplyPathTable) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const count: u32 = @intCast(facts.role.items.len);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try pathEdgesInto(gpa, design, count, &edges);
    var examined: std.ArrayList(u32) = .empty;
    defer examined.deinit(gpa);
    for (0..count) |n| {
        const net: NetId = @fromBackingInt(@as(u32, @intCast(n)));
        if (intent.supply(net) == null and facts.isDeviceConnected(net)) try examined.append(gpa, @intCast(n));
    }
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var inner: std.ArrayList([2]u32) = .empty;
    defer inner.deinit(gpa);
    var flagged: std.ArrayList(u32) = .empty;
    defer flagged.deinit(gpa);
    const reach = try gpa.alloc(u8, count);
    defer gpa.free(reach);
    for (t.head.rule.items, t.head.severity.items, t.both.items, t.labels_are_ports.items) |rule, severity, both, stops| {
        // Paths joined away from the supplies (and, with ports, away from
        // them); each edge onto a supply marks its path with that role.
        inner.clearRetainingCapacity();
        for (edges.items) |e| {
            if (intent.supply(@fromBackingInt(e[0])) != null or intent.supply(@fromBackingInt(e[1])) != null) continue;
            if (stops and (isPort(intent, ports, e[0]) or isPort(intent, ports, e[1]))) continue;
            try inner.append(gpa, e);
        }
        try components(gpa, count, inner.items, &labels);
        // Per path: bit 0 a path to power, bit 1 a path to ground.
        @memset(reach, 0);
        for (edges.items) |e| for ([2][2]u32{ e, .{ e[1], e[0] } }) |ft| {
            if (intent.supply(@fromBackingInt(ft[0])) != null) continue;
            const to = intent.supply(@fromBackingInt(ft[1])) orelse continue;
            reach[labels.items[ft[0]]] |= switch (to.role) {
                .power => 1,
                .ground => 2,
            };
        };
        const before = r.out.len();
        const need: u32 = if (both) 2 else 1;
        for (0..need) |found| {
            flagged.clearRetainingCapacity();
            for (examined.items) |n| if (@popCount(reach[labels.items[n]]) == found) try flagged.append(gpa, n);
            try r.netViolations(design, flagged.items, rule, severity, .count(@intCast(found)), .count(need));
        }
        try r.run(rule, before, .ran, examined.items.len);
    }
}

/// Gate nets whose shortest device path to a supply of the asked role
/// (power, or ground with `ground`) passes more than `max_devices`
/// devices, or that have none. No supply breaks the path. `examined`
/// counts MOS gate nets.
pub fn checkGatePath(r: Record, design: Design, intent: *const IntentMap, t: *const GatePathTable) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const count = design.nets.netCount();
    const devices = design.devices;
    const gate_net = try gpa.alloc(bool, count);
    defer gpa.free(gate_net);
    @memset(gate_net, false);
    for (0..devices.len()) |d| {
        if (devices.kind.items[d] != .mos) continue;
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        for (term.nets, term.roles) |net, role| {
            if (role == .gate and net != .none and @backingInt(net) < count) gate_net[@backingInt(net)] = true;
        }
    }
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try pathEdgesInto(gpa, design, count, &edges);
    // Undirected adjacency, CSR by net.
    const start = try gpa.alloc(u32, count + 1);
    defer gpa.free(start);
    @memset(start, 0);
    for (edges.items) |e| {
        start[e[0] + 1] += 1;
        start[e[1] + 1] += 1;
    }
    for (0..count) |i| start[i + 1] += start[i];
    const fill = try gpa.dupe(u32, start);
    defer gpa.free(fill);
    const adjacent = try gpa.alloc(u32, start[count]);
    defer gpa.free(adjacent);
    for (edges.items) |e| for ([2][2]u32{ e, .{ e[1], e[0] } }) |ft| {
        adjacent[fill[ft[0]]] = ft[1];
        fill[ft[0]] += 1;
    };
    const dist = try gpa.alloc(u32, count);
    defer gpa.free(dist);
    const queue = try gpa.alloc(u32, count);
    defer gpa.free(queue);
    var gates: u64 = 0;
    for (gate_net) |g| gates += @intFromBool(g);
    for (t.head.rule.items, t.head.severity.items, t.ground.items, t.max_devices.items) |rule, severity, ground, max| {
        const before = r.out.len();
        // Breadth first from every supply of the asked role: devices passed.
        @memset(dist, none);
        var tail: usize = 0;
        for (intent.supply_net.items, intent.supply_role.items) |net, role| {
            if ((role == .ground) != ground or @backingInt(net) >= count) continue;
            dist[@backingInt(net)] = 0;
            queue[tail] = @backingInt(net);
            tail += 1;
        }
        var at_q: usize = 0;
        while (at_q < tail) : (at_q += 1) {
            const at = queue[at_q];
            for (adjacent[start[at]..start[at + 1]]) |to| if (dist[to] == none) {
                dist[to] = dist[at] + 1;
                queue[tail] = to;
                tail += 1;
            };
        }
        for (gate_net, dist, 0..) |g, d, n| {
            if (!g) continue;
            const measured: u32, const limit: u32 = if (d == none) .{ 0, 1 } else if (d > max) .{ d, max } else continue;
            try r.netViolations(design, &.{@intCast(n)}, rule, severity, .count(measured), .count(limit));
        }
        try r.run(rule, before, .ran, gates);
    }
}

/// Nets whose own types meet `net` and whose path's types meet `path`,
/// paths stopping at nets meeting `break` (a break net's types join the
/// path, less `exclude`). `examined` counts device-connected nets. Skipped
/// when the intent declares no net type.
pub fn checkNetType(r: Record, design: Design, facts: *const NetFacts, types: *const NetTypes, t: *const NetTypeTable) Allocator.Error!void {
    if (types.name.items.len == 0) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const count: u32 = @intCast(facts.role.items.len);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try pathEdgesInto(gpa, design, count, &edges);
    var examined: std.ArrayList(u32) = .empty;
    defer examined.deinit(gpa);
    for (0..count) |n| if (facts.isDeviceConnected(@fromBackingInt(@as(u32, @intCast(n))))) try examined.append(gpa, @intCast(n));
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var inner: std.ArrayList([2]u32) = .empty;
    defer inner.deinit(gpa);
    var flagged: std.ArrayList(u32) = .empty;
    defer flagged.deinit(gpa);
    const path_mask = try gpa.alloc(u64, count);
    defer gpa.free(path_mask);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const break_list = t.breaks.items[t.break_start.items[row]..t.break_start.items[row + 1]];
        const breaks = masksOf(types, break_list);
        const B = struct {
            fn breaking(ty: *const NetTypes, list: []const Condition, m: Masks, n: u32) bool {
                return list.len > 0 and meets(ty.of(@fromBackingInt(n)), m);
            }
        };
        var exclude: u64 = 0;
        for (t.exclude.items[t.exclude_start.items[row]..t.exclude_start.items[row + 1]]) |name| exclude |= types.bit(name) orelse 0;
        inner.clearRetainingCapacity();
        for (edges.items) |e| if (!B.breaking(types, break_list, breaks, e[0]) and !B.breaking(types, break_list, breaks, e[1])) try inner.append(gpa, e);
        try components(gpa, count, inner.items, &labels);
        @memset(path_mask, 0);
        for (0..count) |n| path_mask[labels.items[n]] |= types.of(@fromBackingInt(@as(u32, @intCast(n))));
        for (edges.items) |e| for ([2][2]u32{ e, .{ e[1], e[0] } }) |ft| {
            if (B.breaking(types, break_list, breaks, ft[1]) and labels.items[ft[0]] != labels.items[ft[1]]) {
                path_mask[labels.items[ft[0]]] |= types.of(@fromBackingInt(ft[1])) & ~exclude;
            }
        };
        const net_cond = masksOf(types, t.net.items[t.net_start.items[row]..t.net_start.items[row + 1]]);
        const path_cond = masksOf(types, t.path.items[t.path_start.items[row]..t.path_start.items[row + 1]]);
        flagged.clearRetainingCapacity();
        for (examined.items) |n| {
            if (meets(types.of(@fromBackingInt(n)), net_cond) and meets(path_mask[labels.items[n]], path_cond)) try flagged.append(gpa, n);
        }
        try r.netViolations(design, flagged.items, rule, severity, .count(1), .count(0));
        try r.run(rule, before, .ran, examined.items.len);
    }
}

/// Cycles among channel-connected components (nets joined through MOS
/// source/drain, never through a supply): a strongly connected set of two
/// or more, or one component driving itself. `examined` counts
/// components; a loop is one finding at its lowest net, measuring its
/// component count against 0. Skipped without a declared supply.
pub fn checkCombinationalLoop(r: Record, design: Design, intent: *const IntentMap, t: *const CombinationalLoopTable) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const count = design.nets.netCount();
    const devices = design.devices;
    // Per MOS: its gate net and its channel's non-rail ends (CSR).
    var gate_of: std.ArrayList(u32) = .empty;
    defer gate_of.deinit(gpa);
    var end_start: std.ArrayList(u32) = .empty;
    defer end_start.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    var joins: std.ArrayList([2]u32) = .empty;
    defer joins.deinit(gpa);
    try end_start.append(gpa, 0);
    for (0..devices.len()) |d| {
        if (devices.kind.items[d] != .mos) continue;
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        var gate: u32 = none;
        const first = ends.items.len;
        for (term.nets, term.roles) |net, role| {
            if (net == .none or @backingInt(net) >= count) continue;
            switch (role) {
                .gate => if (gate == none) {
                    gate = @backingInt(net);
                },
                .source, .drain => if (intent.supply(net) == null) try ends.append(gpa, @backingInt(net)),
                .bulk, .base, .emitter, .collector, .pin => {},
            }
        }
        try gate_of.append(gpa, gate);
        try end_start.append(gpa, @intCast(ends.items.len));
        if (ends.items.len - first == 2) try joins.append(gpa, .{ ends.items[first], ends.items[first + 1] });
    }
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    try components(gpa, count, joins.items, &labels);
    // Components are the labels of channel ends; number them densely.
    const component = try gpa.alloc(u32, count);
    defer gpa.free(component);
    @memset(component, none);
    var n_comp: u32 = 0;
    for (ends.items) |net| {
        const root = labels.items[net];
        if (component[root] == none) {
            component[root] = n_comp;
            n_comp += 1;
        }
    }
    const Of = struct {
        fn net(comp: []const u32, lab: []const u32, i: *const IntentMap, n: u32) ?u32 {
            const c = comp[lab[n]];
            return if (c != none and i.supply(@fromBackingInt(n)) == null) c else null;
        }
    };
    // Driver component -> driven component, deduplicated.
    var arcs: std.ArrayList([2]u32) = .empty;
    defer arcs.deinit(gpa);
    for (gate_of.items, 0..) |gate, k| {
        if (gate == none or end_start.items[k] == end_start.items[k + 1]) continue;
        const from = Of.net(component, labels.items, intent, gate) orelse continue;
        const to = Of.net(component, labels.items, intent, ends.items[end_start.items[k]]) orelse continue;
        try arcs.append(gpa, .{ from, to });
    }
    sortDedup(&arcs);
    const scc = try gpa.alloc(u32, n_comp);
    defer gpa.free(scc);
    try stronglyConnected(gpa, arcs.items, scc);
    const size = try gpa.alloc(u32, n_comp);
    defer gpa.free(size);
    @memset(size, 0);
    for (scc) |s| size[s] += 1;
    const looping = try gpa.alloc(bool, n_comp);
    defer gpa.free(looping);
    for (looping, size) |*l, k| l.* = k > 1;
    for (arcs.items) |a| if (a[0] == a[1]) {
        looping[scc[a[0]]] = true;
    };
    // The lowest net of each looping component group.
    const lowest = try gpa.alloc(u32, n_comp);
    defer gpa.free(lowest);
    @memset(lowest, none);
    for (0..count) |net| if (Of.net(component, labels.items, intent, @intCast(net))) |c| {
        lowest[scc[c]] = @min(lowest[scc[c]], @as(u32, @intCast(net)));
    };
    for (t.head.rule.items, t.head.severity.items) |rule, severity| {
        const before = r.out.len();
        for (looping, 0..) |l, s| if (l) try r.netViolations(design, &.{lowest[s]}, rule, severity, .count(size[s]), .count(0));
        try r.run(rule, before, .ran, n_comp);
    }
}

/// Per non-rail net with a channel end, `(net, distinct drivers)`, into
/// `out`. A transistor with a channel end on the net pulls it when a walk
/// from its other end through every channel touching the nets reached
/// (stopping at rails, never back through the net) reaches a rail; its
/// network is every transistor walked. Networks sharing a gate net are one
/// driver; one reaching no rail drives nothing; one with no gate is none.
pub fn driversInto(gpa: Allocator, design: Design, intent: *const IntentMap, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const devices = design.devices;
    const n_dev = devices.len();
    // Per device: its first gate's net and its channel's two ends.
    const gate = try gpa.alloc(u32, n_dev);
    defer gpa.free(gate);
    const ends = try gpa.alloc([2]u32, n_dev);
    defer gpa.free(ends);
    var channel: std.ArrayList([2]u32) = .empty;
    defer channel.deinit(gpa);
    for (0..n_dev) |d| {
        gate[d] = none;
        ends[d] = .{ none, none };
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        for (term.nets, term.roles) |net, role| {
            const end: usize = switch (role) {
                .gate => {
                    if (gate[d] == none) gate[d] = @backingInt(net);
                    continue;
                },
                .source => 0,
                .drain => 1,
                .bulk, .base, .emitter, .collector, .pin => continue,
            };
            if (ends[d][end] == none) ends[d][end] = @backingInt(net);
        }
        for (ends[d]) |net| if (net != none) try channel.append(gpa, .{ net, @intCast(d) });
    }
    sortDedup(&channel);
    // ponytail: one walk per member; a pass-transistor array walked from
    // each of its nets is quadratic. Share the walks per far net if it bites.
    const seen = try gpa.alloc(u32, design.nets.netCount());
    defer gpa.free(seen);
    @memset(seen, 0);
    var stamp: u32 = 0;
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    // `(gate net, member)` for every gate of each member's pull network.
    var gates: std.ArrayList([2]u32) = .empty;
    defer gates.deinit(gpa);
    var shared: std.ArrayList([2]u32) = .empty;
    defer shared.deinit(gpa);
    var labels: std.ArrayList(u32) = .empty;
    defer labels.deinit(gpa);
    var drivers: std.ArrayList(u32) = .empty;
    defer drivers.deinit(gpa);
    var start: usize = 0;
    while (start < channel.items.len) {
        const net = channel.items[start][0];
        const run = channelOn(channel.items, net);
        start += run.len;
        if (isRail(intent, net)) continue;
        gates.clearRetainingCapacity();
        for (run, 0..) |c, member| {
            const device = c[1];
            if (gate[device] == none) continue;
            const mine = gates.items.len;
            try gates.append(gpa, .{ gate[device], @intCast(member) });
            stamp += 1;
            var rail = false;
            queue.clearRetainingCapacity();
            try queue.append(gpa, across(ends, device, net));
            while (queue.pop()) |at| {
                const fresh = at < seen.len and seen[at] != stamp;
                if (at == net or !fresh) continue;
                seen[at] = stamp;
                if (isRail(intent, at)) {
                    rail = true;
                    continue;
                }
                for (channelOn(channel.items, at)) |nc| {
                    if (gate[nc[1]] != none) try gates.append(gpa, .{ gate[nc[1]], @intCast(member) });
                    try queue.append(gpa, across(ends, nc[1], at));
                }
            }
            // A pass gate that reaches no rail drives nothing by itself.
            if (!rail) gates.shrinkRetainingCapacity(mine);
        }
        std.mem.sortUnstable([2]u32, gates.items, {}, lessPair);
        shared.clearRetainingCapacity();
        for (gates.items[0..gates.items.len -| 1], gates.items[@min(1, gates.items.len)..]) |a, b| {
            if (a[0] == b[0]) try shared.append(gpa, .{ a[1], b[1] });
        }
        try components(gpa, @intCast(run.len), shared.items, &labels);
        drivers.clearRetainingCapacity();
        for (gates.items) |g| try drivers.append(gpa, labels.items[g[1]]);
        std.mem.sortUnstable(u32, drivers.items, {}, std.sort.asc(u32));
        var distinct: u32 = 0;
        for (drivers.items, 0..) |dv, i| distinct += @intFromBool(i == 0 or drivers.items[i - 1] != dv);
        try out.append(gpa, .{ net, distinct });
    }
}

// ---- private ----

fn isRail(intent: *const IntentMap, net: u32) bool {
    return net != none and intent.supply(@fromBackingInt(net)) != null;
}

/// A labelled net that is no supply: a top-cell port.
fn isPort(intent: *const IntentMap, ports: *const PortTable, net: u32) bool {
    return intent.supply(@fromBackingInt(net)) == null and ports.nameOf(@fromBackingInt(net)) != null;
}

/// Every two-net pair a path may cross, into `out`: a MOS's source and
/// drain, a resistor's two pins, both ends on nets below `count`.
fn pathEdgesInto(gpa: Allocator, design: Design, count: u32, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const devices = design.devices;
    for (0..devices.len()) |d| {
        const kind = devices.kind.items[d];
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        var found: [3]u32 = undefined;
        var n: usize = 0;
        for (term.nets, term.roles) |net, role| {
            const conducts = switch (kind) {
                .mos => role == .source or role == .drain,
                .resistor => role == .pin,
                .bjt, .capacitor, .diode, .inductor, .cell => false,
            };
            if (!conducts) continue;
            if (n < 3) found[n] = @backingInt(net);
            n += 1;
        }
        if (n != 2 or found[0] == none or found[1] == none) continue;
        if (found[0] < count and found[1] < count) try out.append(gpa, .{ found[0], found[1] });
    }
}

fn masksOf(types: *const NetTypes, condition: []const Condition) Masks {
    var m: Masks = .{};
    for (condition) |c| {
        if (types.bit(c.name)) |b| {
            if (c.negated) m.absent |= b else m.present |= b;
        } else if (!c.negated) m.possible = false;
    }
    return m;
}

fn meets(mask: u64, m: Masks) bool {
    return m.possible and mask & m.present == m.present and mask & m.absent == 0;
}

/// The `(net, device)` channel ends on `net` in a sorted list.
fn channelOn(channel: []const [2]u32, net: u32) []const [2]u32 {
    var lo: usize = 0;
    var hi: usize = channel.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (channel[mid][0] < net) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < channel.len and channel[end][0] == net) end += 1;
    return channel[lo..end];
}

/// The end of `device`'s channel away from `net` (`net` when both are).
fn across(ends: []const [2]u32, device: u32, net: u32) u32 {
    const e = ends[device];
    return if (e[0] == net) e[1] else e[0];
}

fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
}

fn sortDedup(list: *std.ArrayList([2]u32)) void {
    std.mem.sortUnstable([2]u32, list.items, {}, lessPair);
    var kept: usize = 0;
    for (list.items) |p| if (kept == 0 or list.items[kept - 1][0] != p[0] or list.items[kept - 1][1] != p[1]) {
        list.items[kept] = p;
        kept += 1;
    };
    list.shrinkRetainingCapacity(kept);
}

/// Kosaraju's strongly connected components of the graph on `scc.len`
/// nodes given by sorted, distinct `arcs`: each node's component, numbered
/// in the order the second pass finds them.
fn stronglyConnected(gpa: Allocator, arcs: []const [2]u32, scc: []u32) Allocator.Error!void {
    const n = scc.len;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rev_arcs = try arena.alloc([2]u32, arcs.len);
    for (rev_arcs, arcs) |*ra, a| ra.* = .{ a[1], a[0] };
    std.mem.sortUnstable([2]u32, rev_arcs, {}, lessPair);
    const fwd_start = try csrStart(arena, n, arcs);
    const rev_start = try csrStart(arena, n, rev_arcs);
    // First pass: finishing order, iteratively.
    var order: std.ArrayList(u32) = .empty;
    const seen = try arena.alloc(bool, n);
    @memset(seen, false);
    var stack: std.ArrayList([2]usize) = .empty;
    for (0..n) |root| {
        if (seen[root]) continue;
        seen[root] = true;
        try stack.append(arena, .{ root, fwd_start[root] });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const node = top[0];
            if (top[1] < fwd_start[node + 1]) {
                const to = arcs[top[1]][1];
                top[1] += 1;
                if (!seen[to]) {
                    seen[to] = true;
                    try stack.append(arena, .{ to, fwd_start[to] });
                }
            } else {
                try order.append(arena, @intCast(node));
                _ = stack.pop();
            }
        }
    }
    // Second pass on the reversed graph, in reverse finishing order.
    @memset(scc, none);
    var found: u32 = 0;
    var work: std.ArrayList(u32) = .empty;
    var i = order.items.len;
    while (i > 0) {
        i -= 1;
        const root = order.items[i];
        if (scc[root] != none) continue;
        scc[root] = found;
        try work.append(arena, root);
        while (work.pop()) |node| {
            for (rev_arcs[rev_start[node]..rev_start[node + 1]]) |a| if (scc[a[1]] == none) {
                scc[a[1]] = found;
                try work.append(arena, a[1]);
            };
        }
        found += 1;
    }
}

/// CSR offsets of sorted arcs by source node.
fn csrStart(arena: Allocator, n: usize, arcs: []const [2]u32) Allocator.Error![]usize {
    const start = try arena.alloc(usize, n + 1);
    @memset(start, 0);
    for (arcs) |a| start[a[0] + 1] += 1;
    for (0..n) |k| start[k + 1] += start[k];
    return start;
}

test "kosaraju finds a two-cycle and a self-loop apart from a chain" {
    // Oracle: hand-derived: arcs 0->1, 1->0, 2->3, 3->3 give {0,1} one
    // component, 2 and 3 each their own; the self-loop leaves 3 alone.
    var scc: [4]u32 = undefined;
    try stronglyConnected(std.testing.allocator, &.{ .{ 0, 1 }, .{ 1, 0 }, .{ 2, 3 }, .{ 3, 3 } }, &scc);
    try std.testing.expectEqual(scc[0], scc[1]);
    try std.testing.expect(scc[2] != scc[3] and scc[2] != scc[0] and scc[3] != scc[0]);
}
