//! Reading a settled partition as a verdict: a class with exactly one node
//! per side pairs them, and each paired device must also agree on kind,
//! model, terminals (by role, never position) and parameters. In: the two
//! reduced graphs and their `Partition`. Out: a `Verdict` and its
//! discrepancies (appended), in the user-visible order: class imbalances,
//! per-pair rows in layout order, unpaired layout nodes, unpaired reference
//! nodes. Ported from crates/check/src/lvs/compare.rs (`interpret`,
//! `compare_identity`, `compare_terminals`, `crossed`, `compare_params`,
//! `report_unpaired`).
//!
//! Contents:
//! - `pub fn interpretInto(gpa: Allocator, layout: *const Graph, reference: *const Graph, partition: *const Partition, tolerance: f64, names: ParamNames, controls: *const LvsControls, found: *std.ArrayList(Discrepancy), mates: ?*std.ArrayList(u32)) Allocator.Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const StrId = @import("geom").StrId;
const LvsControls = @import("ingest").deck.LvsControls;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Param = graph.Param;
const no_net = graph.no_net;
const ParamNames = @import("reduce_law.zig").ParamNames;
const bound = @import("controls.zig").bound;
const Partition = @import("refine_partition.zig").Partition;
const verdict = @import("verdict.zig");
const Verdict = verdict.Verdict;
const Discrepancy = verdict.Discrepancy;
const Side = verdict.Side;

/// A node no class paired.
const unpaired: u32 = std.math.maxInt(u32);

const Joined = struct {
    code: u64,
    node: u32,
    slot: u32,

    fn less(_: void, a: Joined, b: Joined) bool {
        if (a.code != b.code) return a.code < b.code;
        if (a.node != b.node) return a.node < b.node;
        return a.slot < b.slot;
    }
};

const Scratch = struct {
    mine: std.ArrayList(Joined) = .empty,
    theirs: std.ArrayList(Joined) = .empty,
    layout_params: std.ArrayList(Param) = .empty,
    ref_params: std.ArrayList(Param) = .empty,

    fn deinit(s: *Scratch, gpa: Allocator) void {
        inline for (@typeInfo(Scratch).@"struct".field_names) |f| @field(s, f).deinit(gpa);
    }
};

/// Appends the partition's discrepancies to `found` and returns `match`
/// when there are none, `mismatch` otherwise. A paired device's parameters
/// compared are those its reference card states (F68), each within the
/// deck's bound for its model or the run's `tolerance` (a count exactly).
/// `mates`, when given, is refilled with each reference node's layout
/// partner (devices, then nets), `maxInt(u32)` for none.
pub fn interpretInto(gpa: Allocator, layout: *const Graph, reference: *const Graph, partition: *const Partition, tolerance: f64, names: ParamNames, controls: *const LvsControls, found: *std.ArrayList(Discrepancy), mates: ?*std.ArrayList(u32)) Allocator.Error!Verdict {
    const before = found.items.len;
    const ld = layout.deviceCount();
    const rd = reference.deviceCount();
    // More than one node per side: no single node can be blamed. Members
    // are also reported unpaired below; the double report is deliberate.
    for (partition.layout_tally.items, partition.ref_tally.items) |a, b| {
        if (a > 1 and b > 1) try found.append(gpa, .{ .class_imbalance = .{ .layout_nodes = a, .ref_nodes = b } });
    }
    const layout_mate = try gpa.alloc(u32, ld + layout.netCount());
    defer gpa.free(layout_mate);
    const ref_mate = try gpa.alloc(u32, rd + reference.netCount());
    defer gpa.free(ref_mate);
    @memset(layout_mate, unpaired);
    @memset(ref_mate, unpaired);
    // Classes holding exactly one node per side, ascending by layout node.
    for (partition.layout_class.items, 0..) |class, node| {
        if (partition.layout_tally.items[class] != 1 or partition.ref_tally.items[class] != 1) continue;
        const mate = partition.ref_first.items[class];
        // Classes seed devices apart from nets and only ever split.
        assert(mate != no_net and (node < ld) == (mate < rd));
        layout_mate[node] = mate;
        ref_mate[mate] = @intCast(node);
    }
    if (mates) |m| {
        m.clearRetainingCapacity();
        try m.appendSlice(gpa, ref_mate);
    }
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    for (layout_mate[0..ld], 0..) |mate, node| {
        if (mate == unpaired) continue;
        const pair: [2]u32 = .{ @intCast(node), mate };
        const same_model = try compareIdentity(gpa, layout, reference, pair, found);
        try compareTerminals(gpa, layout, reference, pair, layout_mate, &scratch, found);
        // Two models' parameters are not one model's to compare.
        if (same_model) {
            const is_crossed = crossed(layout, reference, pair, layout_mate);
            try compareParams(gpa, layout, reference, pair, tolerance, names, controls, is_crossed, &scratch, found);
        }
    }
    try reportUnpaired(gpa, layout, layout_mate, .layout, found);
    try reportUnpaired(gpa, reference, ref_mate, .reference, found);
    return if (found.items.len == before) .match else .mismatch;
}

// ---- private ----

/// A pair must agree on kind and model. One kind, two models: a
/// `model_mismatch` (only a refinement with models aside pairs those); two
/// kinds: both unpaired. Returns whether the models agree.
fn compareIdentity(gpa: Allocator, layout: *const Graph, reference: *const Graph, pair: [2]u32, found: *std.ArrayList(Discrepancy)) Allocator.Error!bool {
    const lm = layout.device_model.items[pair[0]];
    const rm = reference.device_model.items[pair[1]];
    const same_kind = layout.device_kind.items[pair[0]] == reference.device_kind.items[pair[1]];
    if (same_kind and lm == rm) return true;
    if (same_kind) {
        try found.append(gpa, .{ .model_mismatch = .{ .layout_device = pair[0], .ref_device = pair[1], .layout_model = lm, .ref_model = rm } });
        return false;
    }
    try found.append(gpa, .{ .unpaired_device = .{ .side = .layout, .device = pair[0], .model = lm } });
    try found.append(gpa, .{ .unpaired_device = .{ .side = .reference, .device = pair[1], .model = rm } });
    return false;
}

fn mismatch(pair: [2]u32, role: TerminalRole) Discrepancy {
    return .{ .terminal_mismatch = .{ .layout_device = pair[0], .ref_device = pair[1], .role = role } };
}

/// Terminals matched by role code (never slot) onto counterpart nets, as a
/// sorted multiset merge; both tails reported, so the report is mirror-
/// symmetric. A terminal on no net, or on an unpaired net, matches nothing.
fn compareTerminals(gpa: Allocator, layout: *const Graph, reference: *const Graph, pair: [2]u32, layout_mate: []const u32, s: *Scratch, found: *std.ArrayList(Discrepancy)) Allocator.Error!void {
    const ld = layout.deviceCount();
    const rd = reference.deviceCount();
    const lt = layout.terminalsOf(pair[0]);
    const rt = reference.terminalsOf(pair[1]);
    s.mine.clearRetainingCapacity();
    s.theirs.clearRetainingCapacity();
    // Both sides in reference node space.
    for (lt.nets, lt.roles, 0..) |n, role, slot| {
        const node = if (n == no_net) null else @as(?u64, @as(u64, ld) + n);
        const mate: u32 = if (node != null and node.? < layout_mate.len) layout_mate[@intCast(node.?)] else unpaired;
        if (mate == unpaired) {
            try found.append(gpa, mismatch(pair, role));
        } else try s.mine.append(gpa, .{ .code = graph.roleCode(role), .node = mate, .slot = @intCast(slot) });
    }
    for (rt.nets, rt.roles, 0..) |n, role, slot| {
        // Rust's `checked_add`: only an overflow is refused here; a net
        // past the table pairs with nothing in the merge below.
        if (@as(u64, rd) + n > std.math.maxInt(u32)) {
            try found.append(gpa, mismatch(pair, role));
        } else try s.theirs.append(gpa, .{ .code = graph.roleCode(role), .node = rd + n, .slot = @intCast(slot) });
    }
    std.mem.sortUnstable(Joined, s.mine.items, {}, Joined.less);
    std.mem.sortUnstable(Joined, s.theirs.items, {}, Joined.less);
    var i: usize = 0;
    var j: usize = 0;
    while (i < s.mine.items.len and j < s.theirs.items.len) {
        const a = s.mine.items[i];
        const b = s.theirs.items[j];
        if (a.code == b.code and a.node == b.node) {
            i += 1;
            j += 1;
        } else if (a.code < b.code or (a.code == b.code and a.node < b.node)) {
            try found.append(gpa, mismatch(pair, lt.roles[a.slot]));
            i += 1;
        } else {
            try found.append(gpa, mismatch(pair, rt.roles[b.slot]));
            j += 1;
        }
    }
    for (s.mine.items[i..]) |a| try found.append(gpa, mismatch(pair, lt.roles[a.slot]));
    for (s.theirs.items[j..]) |b| try found.append(gpa, mismatch(pair, rt.roles[b.slot]));
}

/// Whether a paired MOS's layout source is on its reference drain's net:
/// then the layout's `as` is the card's `ad`. A device whose source and
/// drain share a net, or that is no MOS, is never crossed.
fn crossed(layout: *const Graph, reference: *const Graph, pair: [2]u32, layout_mate: []const u32) bool {
    const l = graph.channelEnds(layout, pair[0]);
    const r = graph.channelEnds(reference, pair[1]);
    const source = l[0] orelse return false;
    const drain = l[1] orelse return false;
    const ref_drain = r[1] orelse return false;
    if (source == drain) return false;
    // `Option` equality as Rust's `checked_add` and `get` give it: two
    // nones agree.
    const node = @as(u64, layout.deviceCount()) + source;
    const mine: ?u32 = if (node < layout_mate.len) layout_mate[@intCast(node)] else null;
    const want = @as(u64, reference.deviceCount()) + ref_drain;
    const theirs: ?u32 = if (want <= std.math.maxInt(u32)) @intCast(want) else null;
    if (mine == null or theirs == null) return mine == null and theirs == null;
    return mine.? == theirs.?;
}

fn lessParam(_: void, a: Param, b: Param) bool {
    return @backingInt(a.name) < @backingInt(b.name);
}

/// The parameters the reference card states, each joined by name to the
/// layout's within its bound (`NaN` fails); the layout's diffusions read the
/// other way round when `is_crossed`. One the layout does not measure is
/// `undeclared_param`; one only the layout measures is not compared (F68).
fn compareParams(gpa: Allocator, layout: *const Graph, reference: *const Graph, pair: [2]u32, tolerance: f64, names: ParamNames, controls: *const LvsControls, is_crossed: bool, s: *Scratch, found: *std.ArrayList(Discrepancy)) Allocator.Error!void {
    const model = reference.device_model.items[pair[1]];
    s.layout_params.clearRetainingCapacity();
    for (layout.paramsOf(pair[0])) |p| {
        const name = if (is_crossed) names.across(p.name) orelse continue else p.name;
        try s.layout_params.append(gpa, .{ .name = name, .value = p.value });
    }
    s.ref_params.clearRetainingCapacity();
    try s.ref_params.appendSlice(gpa, reference.paramsOf(pair[1]));
    // Stable: rows sharing a name pair off in declaration order.
    std.mem.sort(Param, s.layout_params.items, {}, lessParam);
    std.mem.sort(Param, s.ref_params.items, {}, lessParam);
    const mine = s.layout_params.items;
    const theirs = s.ref_params.items;
    var i: usize = 0;
    var j: usize = 0;
    while (i < mine.len and j < theirs.len) {
        const a = mine[i];
        const b = theirs[j];
        if (@backingInt(a.name) < @backingInt(b.name)) {
            // Measured, but this card says nothing about it.
            i += 1;
            continue;
        }
        if (@backingInt(a.name) > @backingInt(b.name)) {
            try found.append(gpa, undeclared(pair, b.name));
            j += 1;
            continue;
        }
        i += 1;
        j += 1;
        const within = bound(controls, names.tolerance(b.name, tolerance), model, b.name);
        if (!within.agree(a.value, b.value)) {
            try found.append(gpa, .{ .parameter_mismatch = .{ .layout_device = pair[0], .ref_device = pair[1], .param = a.name, .layout_value = a.value, .ref_value = b.value } });
        }
    }
    for (theirs[j..]) |b| try found.append(gpa, undeclared(pair, b.name));
}

fn undeclared(pair: [2]u32, param: StrId) Discrepancy {
    return .{ .undeclared_param = .{ .side = .reference, .layout_device = pair[0], .ref_device = pair[1], .param = param } };
}

/// Every node of one side no class paired, devices then nets. A net with no
/// terminal and no name has nothing to pair with (`lvs.floating_net`
/// reports it on the layout).
fn reportUnpaired(gpa: Allocator, g: *const Graph, mate: []const u32, side: Side, found: *std.ArrayList(Discrepancy)) Allocator.Error!void {
    const devices = g.deviceCount();
    for (mate[0..devices], 0..) |partner, d| {
        if (partner == unpaired) try found.append(gpa, .{ .unpaired_device = .{ .side = side, .device = @intCast(d), .model = g.device_model.items[d] } });
    }
    for (mate[devices..], 0..) |partner, n| {
        const invisible = g.terminalsOn(@intCast(n)).devices.len == 0 and g.net_name.items[n] == null;
        if (partner == unpaired and !invisible) try found.append(gpa, .{ .unpaired_net = .{ .side = side, .net = @intCast(n), .name = g.net_name.items[n] } });
    }
}
