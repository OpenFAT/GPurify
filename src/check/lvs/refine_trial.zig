//! Breaking a balanced stall: pair the stalled class's lowest layout node
//! with the reference node of the class whose parameters are closest (for a
//! net, whose pairing puts the paired transistors' diffusions closest at
//! each channel end, testing-plan F98), on a tie the net its label names
//! (KLayout's `consider_net_names`), then the lowest; Netgen's "resolving
//! symmetries by property value". While a match is possible the pairing is
//! a trial (testing-plan F58): settled, it is kept when no class is short
//! of layout nodes and every device pair it formed agrees on parameters,
//! else undone and the next closest tried, up to `tries`. In: a settled
//! `Partition`. Out: the partition with the stall resolved. Ported from
//! crates/check/src/lvs/refine.rs (`resolve`, `closest`, `ranked`, `fits`,
//! `pair`, `settle`, `stalled`, `settled`, `distance`, `end_distance`,
//! `named_apart`, `agrees`).
//!
//! Contents:
//! - `pub const tries: usize`
//! - `pub fn settle(p: *Partition, gpa: Allocator, sides: Sides, max_rounds: u32, pass_no: *u32) Allocator.Error!bool`
//! - `pub fn stalled(p: *const Partition, node: u32) bool`, `pub fn settled(p: *const Partition, node: u32) bool`
//! - `pub fn resolve(p: *Partition, gpa: Allocator, node: u32, sides: Sides, max_rounds: u32, tolerance: f64, pass_no: *u32) Allocator.Error!bool`
//! - private `EndCtx`: its `visit` is `pub` only because `Sides.forEachNeighbour` looks it up at comptime

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const StrId = @import("geom").StrId;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const graph = @import("graph.zig");
const Param = graph.Param;
const no_net = graph.no_net;
const bound = @import("controls.zig").bound;
const part = @import("refine_partition.zig");
const Partition = part.Partition;
const Sides = part.Sides;

/// The most reference nodes a stall tries its layout node against.
///
/// ponytail: depth one, eight wide. A wrong pairing exposed only after a
/// later tie-break is kept, and so is one whose right partner ranks past
/// the eighth; a search over several stalls fixes both if a circuit needs it.
pub const tries: usize = 8;

const Ranked = struct {
    apart: f64,
    named_apart: bool,
    mate: u32,

    fn less(_: void, a: Ranked, b: Ranked) bool {
        const o = totalOrder(a.apart, b.apart);
        if (o != .eq) return o == .lt;
        if (a.named_apart != b.named_apart) return !a.named_apart;
        return a.mate < b.mate;
    }
};

const EndCtx = struct {
    p: *const Partition,
    sides: Sides,
    ref_net: u32,
    sum: f64 = 0.0,

    /// For a source or drain whose transistor a class pairs one to one and
    /// whose mate has a channel end on `ref_net`: each diffusion the mate
    /// states there against the layout's at its own end.
    pub fn visit(c: *EndCtx, role: TerminalRole, device: u32) void {
        const mine = channelEnd(role) orelse return;
        const class = c.p.class.items[device];
        if (c.p.size.items[class] != 2 or c.p.layout_size.items[class] != 1) return;
        const from = c.p.start.items[class];
        const other = @max(c.p.member.items[from], c.p.member.items[from + 1]) - c.sides.split;
        const t = c.sides.reference.terminalsOf(other);
        const theirs = for (t.nets, t.roles) |n, r| {
            if (channelEnd(r)) |end| if (n == c.ref_net) break end;
        } else return;
        const names = c.sides.names.diffusion;
        const layout = c.sides.layout.paramsOf(device);
        const reference = c.sides.reference.paramsOf(other);
        // Area, then perimeter.
        for ([_]usize{ 0, 2 }) |k| {
            const read = names[mine + k] orelse continue;
            const stated = names[theirs + k] orelse continue;
            const b = find(reference, stated) orelse continue;
            c.sum += if (find(layout, read)) |a| relative(a, b) else 1.0;
        }
    }
};

/// Passes until no class splits. False when more than `max_rounds` passes
/// in a row split one.
pub fn settle(p: *Partition, gpa: Allocator, sides: Sides, max_rounds: u32, pass_no: *u32) Allocator.Error!bool {
    var rounds: u32 = 0;
    while (p.dirty.items.len != 0) {
        pass_no.* += 1;
        if (try p.pass(gpa, sides, pass_no.*)) {
            if (rounds == max_rounds) return false;
            rounds += 1;
        }
    }
    return true;
}

/// A layout node's class holds as many nodes on each side, more than one:
/// a symmetry only a tie-break resolves.
pub fn stalled(p: *const Partition, node: u32) bool {
    const class = p.class.items[node];
    const layout = p.layout_size.items[class];
    return layout >= 2 and p.size.items[class] == 2 * layout;
}

/// A layout node's class can never stall again: paired one to one, or
/// holding no reference node.
pub fn settled(p: *const Partition, node: u32) bool {
    const class = p.class.items[node];
    const layout = p.layout_size.items[class];
    return p.size.items[class] == layout or (layout == 1 and p.size.items[class] == 2);
}

/// Breaks the stall at layout node `node`. False when a settle runs out of
/// rounds. When nothing tried fits, the closest is kept and no later stall
/// tries again, since a match is then out of reach.
pub fn resolve(p: *Partition, gpa: Allocator, node: u32, sides: Sides, max_rounds: u32, tolerance: f64, pass_no: *u32) Allocator.Error!bool {
    const closest = closestOf(p, node, sides);
    if (p.hopeless or p.deficit > 0) {
        try pair(p, gpa, node, closest, sides.split);
        return settle(p, gpa, sides, max_rounds, pass_no);
    }
    const deficit = p.deficit;
    const fresh = p.start.items.len;
    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(gpa);
    var have_ranked = false;
    var tried: usize = 0;
    var mate = closest;
    while (true) {
        p.trial = true;
        p.log.clearRetainingCapacity();
        try pair(p, gpa, node, mate, sides.split);
        const ok = try settle(p, gpa, sides, max_rounds, pass_no);
        p.trial = false;
        if (!ok) return false;
        if (fits(p, sides, tolerance, fresh)) return true;
        p.undo();
        p.deficit = deficit;
        p.assertValid(sides.split);
        if (!have_ranked) {
            try rankInto(gpa, p, node, sides, closest, &ranked);
            have_ranked = true;
        }
        if (tried >= ranked.items.len) break;
        mate = ranked.items[tried].mate;
        tried += 1;
    }
    p.hopeless = true;
    try pair(p, gpa, node, closest, sides.split);
    return settle(p, gpa, sides, max_rounds, pass_no);
}

// ---- private ----

/// `f64::total_cmp`.
fn totalOrder(a: f64, b: f64) std.math.Order {
    const key = struct {
        fn of(x: f64) i64 {
            const bits: i64 = @bitCast(x);
            return bits ^ @as(i64, @bitCast(@as(u64, @bitCast(bits >> 63)) >> 1));
        }
    }.of;
    return std.math.order(key(a), key(b));
}

/// The reference nodes of `node`'s class, each ranked.
fn rankOf(p: *const Partition, node: u32, mate: u32, sides: Sides) Ranked {
    return .{ .apart = apart(p, node, mate, sides), .named_apart = namedApart(sides, node, mate), .mate = mate };
}

fn membersOf(p: *const Partition, node: u32) []const u32 {
    const class = p.class.items[node];
    return p.member.items[p.start.items[class]..][0..p.size.items[class]];
}

/// The closest reference node of `node`'s class.
///
/// ponytail: O(class size) per stall; keep members sorted per class if a
/// huge class of isolated nodes shows up in a profile.
fn closestOf(p: *const Partition, node: u32, sides: Sides) u32 {
    var best: ?Ranked = null;
    for (membersOf(p, node)) |mate| {
        if (mate < sides.split) continue;
        const r = rankOf(p, node, mate, sides);
        if (best == null or Ranked.less({}, r, best.?)) best = r;
    }
    return best.?.mate;
}

/// The next `tries - 1` reference nodes after `closest`, in the same order.
fn rankInto(gpa: Allocator, p: *const Partition, node: u32, sides: Sides, closest: u32, out: *std.ArrayList(Ranked)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (membersOf(p, node)) |mate| {
        if (mate < sides.split or mate == closest) continue;
        try out.append(gpa, rankOf(p, node, mate, sides));
    }
    std.mem.sortUnstable(Ranked, out.items, {}, Ranked.less);
    out.shrinkRetainingCapacity(@min(out.items.len, tries - 1));
}

/// How far apart layout node `node` and reference node `mate` are: their
/// parameters for devices, the diffusions pairing them would put at one
/// channel end for nets.
fn apart(p: *const Partition, node: u32, mate: u32, sides: Sides) f64 {
    if (node < sides.layout.deviceCount()) return distance(sides, node, mate);
    return endDistance(p, node, mate, sides);
}

/// `|a - b|` relative to the larger magnitude; zero when both are zero.
fn relative(a: f64, b: f64) f64 {
    const scale = @max(@abs(a), @abs(b));
    return if (scale == 0.0) 0.0 else @abs(a - b) / scale;
}

fn find(params: []const Param, name: ?StrId) ?f64 {
    const n = name orelse return null;
    for (params) |q| if (q.name == n) return q.value;
    return null;
}

/// Per name the reference states, the relative difference when the layout
/// states it too and one when it does not, summed; a layout-only name is
/// not compared (F68); zero for nets. Diffusions are read both ways round
/// and the closer taken.
fn distance(sides: Sides, layout: u32, mate: u32) f64 {
    const reference = mate - sides.split;
    if (layout >= sides.layout.deviceCount() or reference >= sides.reference.deviceCount()) return 0.0;
    const mine = sides.layout.paramsOf(layout);
    const theirs = sides.reference.paramsOf(reference);
    var sums: [2]f64 = .{ -0.0, -0.0 };
    for ([_]bool{ false, true }, &sums) |crossed, *sum| {
        for (theirs) |t| {
            const read = if (crossed) sides.names.across(t.name) else t.name;
            sum.* += if (find(mine, read)) |a| relative(a, t.value) else 1.0;
        }
    }
    return @min(sums[0], sums[1]);
}

/// Which channel end a role is: 0 the source, 1 the drain.
fn channelEnd(role: TerminalRole) ?usize {
    return switch (role) {
        .source => 0,
        .drain => 1,
        .gate, .bulk, .base, .emitter, .collector, .pin => null,
    };
}

/// How far apart the diffusions are that pairing layout net `net` with
/// reference net `mate` puts at one channel end.
fn endDistance(p: *const Partition, net: u32, mate: u32, sides: Sides) f64 {
    var ctx: EndCtx = .{ .p = p, .sides = sides, .ref_net = mate - sides.split - sides.reference.deviceCount() };
    sides.forEachNeighbour(net, &ctx);
    return ctx.sum;
}

/// Whether the two nodes are other than two nets of one name, the layout
/// net's label the reference net's name (catalog LVS-032).
fn namedApart(sides: Sides, layout: u32, mate: u32) bool {
    const reference = mate - sides.split;
    const ld = sides.layout.deviceCount();
    const rd = sides.reference.deviceCount();
    if (layout < ld or reference < rd) return true;
    const label = sides.layout.net_name.items[layout - ld] orelse return true;
    const name = sides.reference.net_name.items[reference - rd] orelse return true;
    return label != name;
}

/// Whether the two would pass the verdict's parameter comparison: every
/// name the reference states stated by the layout too, within its bound,
/// diffusions either way round. Nets always do.
fn agrees(sides: Sides, layout: u32, mate: u32, tolerance: f64) bool {
    const reference = mate - sides.split;
    if (layout >= sides.layout.deviceCount() or reference >= sides.reference.deviceCount()) return true;
    const model = sides.reference.device_model.items[reference];
    const mine = sides.layout.paramsOf(layout);
    const theirs = sides.reference.paramsOf(reference);
    for ([_]bool{ false, true }) |crossed| {
        const all = for (theirs) |t| {
            const read = if (crossed) sides.names.across(t.name) else t.name;
            const within = bound(sides.controls, sides.names.tolerance(t.name, tolerance), model, t.name);
            const any = for (mine) |m| (if (read != null and m.name == read.? and within.agree(m.value, t.value)) break true) else false;
            if (!any) break false;
        } else true;
        if (all) return true;
    }
    return false;
}

/// Pairs `node` with `mate`, a reference node of its class, as a new class
/// of their own whose two nodes are dirty.
fn pair(p: *Partition, gpa: Allocator, node: u32, mate: u32, split: u32) Allocator.Error!void {
    const class = p.class.items[node];
    assert(node < split and mate >= split and p.class.items[mate] == class);
    const end = p.start.items[class] + p.size.items[class];
    try p.place(gpa, node, end - 2);
    try p.place(gpa, mate, end - 1);
    p.next_dirty.clearRetainingCapacity();
    try p.carve(gpa, class, end - 2, 2, split);
    std.mem.swap(std.ArrayList(u32), &p.dirty, &p.next_dirty);
}

/// Whether a settled trial can still be part of a match: no class short of
/// layout nodes, and every one-to-one device class it made (from `fresh`
/// on, and the ones they were carved from) agreeing on parameters.
fn fits(p: *const Partition, sides: Sides, tolerance: f64, fresh: usize) bool {
    if (p.deficit != 0) return false;
    for (fresh..p.start.items.len) |c| if (!pairAgrees(p, sides, tolerance, @intCast(c))) return false;
    for (p.log.items) |change| switch (change) {
        .carve => |parent| if (!pairAgrees(p, sides, tolerance, parent)) return false,
        .swap, .start => {},
    };
    return true;
}

fn pairAgrees(p: *const Partition, sides: Sides, tolerance: f64, class: u32) bool {
    if (p.size.items[class] != 2 or p.layout_size.items[class] != 1) return true;
    const from = p.start.items[class];
    const a = p.member.items[from];
    const b = p.member.items[from + 1];
    return agrees(sides, @min(a, b), @max(a, b), tolerance);
}
