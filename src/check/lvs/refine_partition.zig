//! The refinement partition over both graphs as one node space, and the
//! pass that splits it: every neighbour of a node whose class changed is
//! re-signed by the commutative wrapping sum of `mix(role, class)` over its
//! terminals, and each class splits by signature. In: two graphs and the
//! seeds. Out: a `Partition` (class per node, members grouped by class, the
//! undo log of a trial). Ported from crates/check/src/lvs/refine.rs
//! (`Partition`, `seed`, `place`, `carve`, `undo`, `pass`, `Sides`,
//! `mix`, `neighbour`).
//!
//! Node index is devices first, then nets, on each side; layout nodes come
//! first (`0 .. split`) and reference nodes follow.
//!
//! Contents:
//! - `pub const Sides = struct`, `forEachNeighbour(s: Sides, node: u32, ctx: anytype) void`
//! - `pub const Undo = union(enum)`, `pub const Partition = struct`, `deinit`,
//!   `short(p: *const Partition, class: u32) bool`, `seed(p: *Partition, gpa: Allocator, sides: Sides) Allocator.Error!void`,
//!   `place(p: *Partition, gpa: Allocator, node: u32, to: u32) Allocator.Error!void`,
//!   `carve(p: *Partition, gpa: Allocator, parent: u32, from: u32, count: u32, split: u32) Allocator.Error!void`,
//!   `undo(p: *Partition) void`, `assertValid(p: *const Partition, split: u32) void`, `pass(p: *Partition, gpa: Allocator, sides: Sides, pass_no: u32) Allocator.Error!bool`
//! - private `TouchCtx`, `SignCtx`: its `visit` is `pub` only because `Sides.forEachNeighbour` looks it up at comptime

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const LvsControls = @import("ingest").deck.LvsControls;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const ParamNames = @import("reduce_law.zig").ParamNames;

/// Both graphs as one node space, and what a trial's devices are held to.
pub const Sides = struct {
    layout: *const Graph,
    reference: *const Graph,
    /// The first reference node.
    split: u32,
    names: ParamNames,
    controls: *const LvsControls,
    /// Each node's seed, layout nodes first: nets of one seed start in a
    /// class of their own; `no_net`, or a node past the end, has none.
    seeds: []const u32,
    /// Devices of one kind start in one class whatever their model.
    models_aside: bool,

    /// Calls `ctx.visit(role, neighbour)` for each edge of `node`; a
    /// terminal on no net has none.
    pub fn forEachNeighbour(s: Sides, node: u32, ctx: anytype) void {
        const on_layout = node < s.split;
        const g = if (on_layout) s.layout else s.reference;
        const offset: u32 = if (on_layout) 0 else s.split;
        const local = node - offset;
        const devices = g.deviceCount();
        if (local < devices) {
            const t = g.terminalsOf(local);
            for (t.nets, t.roles) |n, role| if (n != no_net) ctx.visit(role, offset + devices + n);
        } else {
            const t = g.terminalsOn(local - devices);
            for (t.devices, t.roles) |d, role| ctx.visit(role, offset + d);
        }
    }
};

/// One change a trial made, so a rejected trial can be taken back.
pub const Undo = union(enum) {
    /// `place` swapped these two `member` slots.
    swap: [2]u32,
    /// `carve` made the last class out of this one.
    carve: u32,
    /// A pass moved this class's start from this offset.
    start: [2]u32,
};

/// Refinement state for both graphs. Invariants (`assertValid`): `member` is
/// a permutation of the nodes that `slot` inverts; the classes, none empty,
/// tile it, each member labelled by its own class; `layout_size` counts each
/// class's layout members; `deficit` counts the short classes.
pub const Partition = struct {
    /// Output, valid after a refinement that did not run out: each layout
    /// node's class, nodes per class on each side, the lowest reference node
    /// per class (`no_net` when none).
    layout_class: std.ArrayList(u32) = .empty,
    layout_tally: std.ArrayList(u32) = .empty,
    ref_tally: std.ArrayList(u32) = .empty,
    ref_first: std.ArrayList(u32) = .empty,

    class: std.ArrayList(u32) = .empty,
    /// Class `c` is `member[start[c] .. start[c] + size[c]]`.
    member: std.ArrayList(u32) = .empty,
    slot: std.ArrayList(u32) = .empty,
    start: std.ArrayList(u32) = .empty,
    size: std.ArrayList(u32) = .empty,
    layout_size: std.ArrayList(u32) = .empty,
    /// Nodes whose class changed since the last pass, and the next set.
    dirty: std.ArrayList(u32) = .empty,
    next_dirty: std.ArrayList(u32) = .empty,
    /// Every node a pass re-signs.
    touched: std.ArrayList(Touched) = .empty,
    /// The pass that last touched each node.
    seen: std.ArrayList(u32) = .empty,
    /// `(offset, length)` of each part a class splits into.
    parts: std.ArrayList([2]u32) = .empty,
    /// Classes with more reference than layout nodes. Splitting one leaves a
    /// part that still is, so above zero no match is left to find.
    deficit: u32 = 0,
    /// Every change since the current trial began, while `trial` is set.
    log: std.ArrayList(Undo) = .empty,
    trial: bool = false,
    /// A stall found no candidate that fits: later stalls take their closest.
    hopeless: bool = false,

    pub fn deinit(p: *Partition, gpa: Allocator) void {
        inline for (.{ "layout_class", "layout_tally", "ref_tally", "ref_first", "class", "member", "slot", "start", "size", "layout_size", "dirty", "next_dirty", "touched", "seen", "parts", "log" }) |f| @field(p, f).deinit(gpa);
    }

    /// Whether `class` holds more reference nodes than layout nodes.
    pub fn short(p: *const Partition, class: u32) bool {
        return p.size.items[class] > 2 * p.layout_size.items[class];
    }

    /// Devices one class per `(kind, model)` (per kind with
    /// `models_aside`), nets one class per seed then one for the rest;
    /// every node dirty.
    pub fn seed(p: *Partition, gpa: Allocator, sides: Sides) Allocator.Error!void {
        var key: std.ArrayList([2]u64) = .empty;
        defer key.deinit(gpa);
        for ([_]*const Graph{ sides.layout, sides.reference }, [_]u32{ 0, sides.split }) |g, offset| {
            for (0..g.deviceCount()) |d| {
                const model: u64 = if (sides.models_aside) 0 else @backingInt(g.device_model.items[d]);
                try key.append(gpa, .{ (graph.kindCode(g.device_kind.items[d]) << 32) | model, offset + d });
            }
            for (0..g.netCount()) |n| {
                const node = offset + g.deviceCount() + @as(u32, @intCast(n));
                // Below every unseeded net and above every device key.
                const s = if (node < sides.seeds.len) sides.seeds[node] else no_net;
                try key.append(gpa, .{ if (s != no_net) std.math.maxInt(u64) - 1 - @as(u64, s) else std.math.maxInt(u64), node });
            }
        }
        std.mem.sortUnstable([2]u64, key.items, {}, lessPair);
        const nodes = key.items.len;
        inline for (.{ "class", "slot", "member", "start", "size", "layout_size", "dirty", "seen", "log" }) |f| @field(p, f).clearRetainingCapacity();
        try p.class.resize(gpa, nodes);
        try p.slot.resize(gpa, nodes);
        for (key.items, 0..) |k, at| {
            if (at == 0 or k[0] != key.items[at - 1][0]) {
                try p.start.append(gpa, @intCast(at));
                try p.size.append(gpa, 0);
                try p.layout_size.append(gpa, 0);
            }
            const class: u32 = @intCast(p.start.items.len - 1);
            const node: u32 = @intCast(k[1]);
            p.class.items[node] = class;
            p.slot.items[node] = @intCast(at);
            try p.member.append(gpa, node);
            p.size.items[class] += 1;
            p.layout_size.items[class] += @intFromBool(node < sides.split);
        }
        for (0..nodes) |n| try p.dirty.append(gpa, @intCast(n));
        try p.seen.appendNTimes(gpa, 0, nodes);
        p.deficit = 0;
        for (0..p.start.items.len) |c| p.deficit += @intFromBool(p.short(@intCast(c)));
        p.trial = false;
        p.hopeless = false;
    }

    /// Moves `node` to position `to` of `member`, swapping out what was there.
    pub fn place(p: *Partition, gpa: Allocator, node: u32, to: u32) Allocator.Error!void {
        const from = p.slot.items[node];
        const other = p.member.items[to];
        std.mem.swap(u32, &p.member.items[from], &p.member.items[to]);
        p.slot.items[other] = from;
        p.slot.items[node] = to;
        if (p.trial) try p.log.append(gpa, .{ .swap = .{ from, to } });
    }

    /// Carves `member[from .. from + count]` out of `parent` into a new class
    /// whose nodes become dirty. The caller re-points `parent`'s range.
    pub fn carve(p: *Partition, gpa: Allocator, parent: u32, from: u32, count: u32, split: u32) Allocator.Error!void {
        const class: u32 = @intCast(p.start.items.len);
        const was_short = p.short(parent);
        var layout: u32 = 0;
        for (p.member.items[from .. from + count]) |node| {
            p.class.items[node] = class;
            try p.next_dirty.append(gpa, node);
            layout += @intFromBool(node < split);
        }
        try p.start.append(gpa, from);
        try p.size.append(gpa, count);
        try p.layout_size.append(gpa, layout);
        p.size.items[parent] -= count;
        p.layout_size.items[parent] -= layout;
        p.deficit = p.deficit - @intFromBool(was_short) + @intFromBool(p.short(parent)) + @intFromBool(p.short(class));
        if (p.trial) try p.log.append(gpa, .{ .carve = parent });
    }

    /// Takes back every change the log holds, newest first, leaving the
    /// partition as the trial found it but for `deficit`, which the caller
    /// restores.
    pub fn undo(p: *Partition) void {
        while (p.log.pop()) |change| switch (change) {
            .swap => |ab| {
                std.mem.swap(u32, &p.member.items[ab[0]], &p.member.items[ab[1]]);
                p.slot.items[p.member.items[ab[0]]] = ab[0];
                p.slot.items[p.member.items[ab[1]]] = ab[1];
            },
            .carve => |parent| {
                const class = p.start.items.len - 1;
                const from = p.start.items[class];
                for (p.member.items[from .. from + p.size.items[class]]) |node| p.class.items[node] = parent;
                p.size.items[parent] += p.size.items[class];
                p.layout_size.items[parent] += p.layout_size.items[class];
                _ = p.start.pop();
                _ = p.size.pop();
                _ = p.layout_size.pop();
            },
            .start => |cf| p.start.items[cf[0]] = cf[1],
        };
        p.dirty.clearRetainingCapacity();
        p.next_dirty.clearRetainingCapacity();
    }

    /// Re-signs every neighbour of a dirty node and splits its class by
    /// signature. Nodes of a class no dirty node touches keep their
    /// signature and stay together; the largest part keeps the class id.
    /// Returns whether anything split.
    ///
    /// ponytail: CPU, one node at a time. The GPU path is a segmented
    /// wrapping-add of `mix(role, class)` over the CSR incidence (one
    /// segment per touched node) then a device sort of `(class, signature,
    /// node)`: the sum is commutative, so any reduction order gives these
    /// bits.
    pub fn pass(p: *Partition, gpa: Allocator, sides: Sides, pass_no: u32) Allocator.Error!bool {
        p.touched.clearRetainingCapacity();
        for (p.dirty.items) |node| {
            var visit: TouchCtx = .{ .p = p, .gpa = gpa, .pass_no = pass_no };
            sides.forEachNeighbour(node, &visit);
            if (visit.failed) return error.OutOfMemory;
        }
        for (p.touched.items) |*entry| {
            var sum: SignCtx = .{ .class = p.class.items };
            sides.forEachNeighbour(entry.node, &sum);
            entry.signature = sum.signature;
        }
        std.mem.sortUnstable(Touched, p.touched.items, {}, Touched.less);

        p.next_dirty.clearRetainingCapacity();
        const touched = p.touched.items;
        var run_start: usize = 0;
        while (run_start < touched.len) {
            const parent = touched[run_start].class;
            var run_end = run_start + 1;
            while (run_end < touched.len and touched[run_end].class == parent) run_end += 1;
            const run = touched[run_start..run_end];
            run_start = run_end;

            const untouched = p.size.items[parent] - @as(u32, @intCast(run.len));
            if (untouched == 0 and run[0].signature == run[run.len - 1].signature) continue;
            // Touched nodes to the tail, grouped by signature; untouched lead.
            const base = p.start.items[parent] + untouched;
            for (run, 0..) |t, at| try p.place(gpa, t.node, base + @as(u32, @intCast(at)));
            // Parts: the untouched lead, then one per signature.
            p.parts.clearRetainingCapacity();
            if (untouched > 0) try p.parts.append(gpa, .{ p.start.items[parent], untouched });
            var group: usize = 0;
            for (1..run.len + 1) |at| {
                if (at == run.len or run[at].signature != run[group].signature) {
                    try p.parts.append(gpa, .{ base + @as(u32, @intCast(group)), @intCast(at - group) });
                    group = at;
                }
            }
            // The longest part keeps the id, the first of equals.
            var keep: usize = 0;
            for (p.parts.items, 0..) |part, at| {
                if (part[1] > p.parts.items[keep][1]) keep = at;
            }
            if (p.trial) try p.log.append(gpa, .{ .start = .{ parent, p.start.items[parent] } });
            p.start.items[parent] = p.parts.items[keep][0];
            for (p.parts.items, 0..) |part, at| {
                if (at != keep) try p.carve(gpa, parent, part[0], part[1], sides.split);
            }
        }
        std.mem.swap(std.ArrayList(u32), &p.dirty, &p.next_dirty);
        return p.dirty.items.len != 0;
    }

    /// Asserts the invariants in the type's doc comment (Debug only).
    pub fn assertValid(p: *const Partition, split: u32) void {
        if (!std.debug.runtime_safety) return;
        const nodes = p.class.items.len;
        assert(p.member.items.len == nodes and p.slot.items.len == nodes);
        for (0..nodes) |at| assert(p.slot.items[p.member.items[at]] == at);
        var total: usize = 0;
        var deficit: u32 = 0;
        for (0..p.start.items.len) |c| {
            const run = p.member.items[p.start.items[c]..][0..p.size.items[c]];
            assert(run.len > 0);
            var layout: u32 = 0;
            for (run) |node| {
                assert(p.class.items[node] == c);
                layout += @intFromBool(node < split);
            }
            assert(layout == p.layout_size.items[c]);
            total += run.len;
            deficit += @intFromBool(p.short(@intCast(c)));
        }
        assert(total == nodes and deficit == p.deficit);
    }
};

/// A node a pass re-signs, with its class before the pass.
const Touched = struct {
    class: u32,
    signature: u64,
    node: u32,

    fn less(_: void, a: Touched, b: Touched) bool {
        if (a.class != b.class) return a.class < b.class;
        if (a.signature != b.signature) return a.signature < b.signature;
        return a.node < b.node;
    }
};

const TouchCtx = struct {
    p: *Partition,
    gpa: Allocator,
    pass_no: u32,
    failed: bool = false,

    pub fn visit(c: *TouchCtx, _: TerminalRole, next: u32) void {
        if (c.p.seen.items[next] == c.pass_no) return;
        c.p.seen.items[next] = c.pass_no;
        c.p.touched.append(c.gpa, .{ .class = c.p.class.items[next], .signature = 0, .node = next }) catch {
            c.failed = true;
        };
    }
};

const SignCtx = struct {
    class: []const u32,
    signature: u64 = 0,

    pub fn visit(c: *SignCtx, role: TerminalRole, next: u32) void {
        c.signature +%= neighbour(role, c.class[next]);
    }
};

// ---- private ----

/// Splitmix64's finaliser.
fn mix(z0: u64) u64 {
    var z = (z0 ^ (z0 >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
}

/// One neighbour's contribution; summed with wrapping add, so order-free.
fn neighbour(role: TerminalRole, class: u32) u64 {
    return mix(0x21 ^ (graph.roleCode(role) << 8) ^ (@as(u64, class) << 24));
}

fn lessPair(_: void, a: [2]u64, b: [2]u64) bool {
    return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
}
