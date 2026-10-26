//! Series and parallel reduction to a fixed point, run on both sides. In:
//! a `Graph` and the `ParamNames`. Out: the reduced `Graph` and every merge
//! made, in the order made. Under-reduction is safe, over-reduction is not,
//! so every condition is what must hold before a merge. Ported from
//! crates/check/src/lvs/reduce.rs (`reduce`, `reduce_with`,
//! `fold_multiplier`); the passes are reduce_plan.zig and reduce_emit.zig,
//! the laws reduce_law.zig, logic gates gates.zig.
//!
//! A merge keeps what it combines, by the device's law:
//!
//! | Kind | Parallel | Series | `m` |
//! |---|---|---|---|
//! | MOS stating `W` | sums `W`, `nf`, `as`, `ad`, `ps`, `pd` (each to its channel end); the rest, `L` included, agrees | sums `L`, which both state; never with a diffusion stated | folded into `W` and the diffusions |
//! | MOS stating no `W` | sums the count `m`; the rest agrees | as above | kept |
//! | resistor, capacitor, diode, bipolar, inductor | sums `m`; the rest agrees | never | kept |
//! | a black box | never | never | kept |
//! | the same under `relaxed`, stating its value | combines the value by its law (`r`, `ind` harmonically; `c`, `area`, `ae` adding) and adds `w`, `area`, `perim`, `pe` | resistor, capacitor, inductor only: the opposite law, adding `area`, `perim`, a resistor's `l`; `w` agrees | folded in |
//!
//! "Agrees" is bit-identical: the comparison's tolerance plays no part.
//! Parallel (catalog LVS-040, LVS-043, LVS-044): one kind and model whose
//! terminals land on the same nets role for role. Series (LVS-041): two
//! channels meeting at a net carrying exactly those two terminals, no port,
//! every other terminal on the same nets, at least one such terminal; the
//! net is consumed. Netgen 1.5.323 merges no MOS in series; Netgen's `l
//! critical` merges near-equal `L` in parallel, here `L` must be identical.
//! Multiplier (LVS-046): with `W` and `m` named, each MOS's `W` is
//! multiplied by its `m`, which is dropped; an `m` of 1 is dropped
//! everywhere. Each pass applies one law to the whole graph, parallel first;
//! passes repeat until neither merges, then (with `gates`) one gate pass,
//! and the laws again.
//!
//! Contents:
//! - `pub const ParamNames`, `pub const MergeKind`
//! - `pub const Merges = struct`, `deinit`, `len(m: *const Merges) u32`, `devicesOf(m: *const Merges, merge: u32) []const u32`
//! - `pub fn reduceWith(gpa: Allocator, src: *const Graph, names: ParamNames, out: *Graph, merges: *Merges) Allocator.Error!void`
//! - private `FoldCtx`: its `rewrite` is `pub` only because `graph.rewriteParams` looks it up at comptime

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Param = graph.Param;
const law = @import("reduce_law.zig");
const Law = law.Law;
const plan_mod = @import("reduce_plan.zig");
const Plan = plan_mod.Plan;
const emitInto = @import("reduce_emit.zig").emitInto;
const gates = @import("gates.zig");

pub const ParamNames = law.ParamNames;

pub const MergeKind = plan_mod.MergeKind;

/// Merges for the report: the input devices that became one, CSR. Rows are
/// rows of the graph `reduceWith` was given, ascending, so a device merged
/// twice lists every row it stands for in both merges.
pub const Merges = struct {
    kind: std.ArrayList(MergeKind) = .empty,
    /// The model of every device merged.
    model: std.ArrayList(StrId) = .empty,
    /// One longer than `kind` once a merge is appended; empty before.
    device_start: std.ArrayList(u32) = .empty,
    device: std.ArrayList(u32) = .empty,

    pub fn deinit(m: *Merges, gpa: Allocator) void {
        inline for (@typeInfo(Merges).@"struct".field_names) |f| @field(m, f).deinit(gpa);
    }

    pub fn len(m: *const Merges) u32 {
        return @intCast(m.kind.items.len);
    }

    pub fn devicesOf(m: *const Merges, merge: u32) []const u32 {
        return m.device.items[m.device_start.items[merge]..m.device_start.items[merge + 1]];
    }

    // ---- private ----

    fn clear(m: *Merges) void {
        inline for (@typeInfo(Merges).@"struct".field_names) |f| @field(m, f).clearRetainingCapacity();
    }

    fn push(m: *Merges, gpa: Allocator, kind: MergeKind, model: StrId, rows: []const u32) Allocator.Error!void {
        if (m.device_start.items.len == 0) try m.device_start.append(gpa, 0);
        try m.kind.append(gpa, kind);
        try m.model.append(gpa, model);
        try m.device.appendSlice(gpa, rows);
        try m.device_start.append(gpa, @intCast(m.device.items.len));
    }
};

/// Rows grouped, CSR.
const Csr = struct {
    start: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(u32) = .empty,

    fn deinit(c: *Csr, gpa: Allocator) void {
        c.start.deinit(gpa);
        c.rows.deinit(gpa);
    }

    fn clear(c: *Csr, gpa: Allocator) Allocator.Error!void {
        c.start.clearRetainingCapacity();
        c.rows.clearRetainingCapacity();
        try c.start.append(gpa, 0);
    }

    fn append(c: *Csr, gpa: Allocator, rows: []const u32) Allocator.Error!void {
        try c.rows.appendSlice(gpa, rows);
        try c.start.append(gpa, @intCast(c.rows.items.len));
    }
};

const FoldCtx = struct {
    names: ParamNames,
    multiplier: StrId,

    /// Each MOS's `m` folded into its `W` and diffusions; a relaxed
    /// passive's into its value and what adds; every other `m` kept as the
    /// count, except an `m` of 1, which every card has.
    pub fn rewrite(c: FoldCtx, gpa: Allocator, g: *const Graph, device: u32, out: *std.ArrayList(Param)) Allocator.Error!void {
        const params = g.paramsOf(device);
        const m = law.countOf(params, c.multiplier);
        const kind = g.device_kind.items[device];
        const into: ?StrId = if (law.sumsWidth(kind, params, c.names)) c.names.width else null;
        const device_law = Law.of(kind, params, c.names);
        for (params) |p| {
            if (p.name == c.multiplier) {
                // Folded, or a count of one: nothing left to say.
                if (into == null and device_law == null and m != 1.0) try out.append(gpa, p);
            } else if (into != null and (law.is(into, p.name) or isDiffusion(c.names, p.name))) {
                try out.append(gpa, .{ .name = p.name, .value = p.value * m });
            } else if (device_law != null and device_law.?.combines(p.name)) {
                try out.append(gpa, .{ .name = p.name, .value = device_law.?.times(p.name, p.value, m) });
            } else try out.append(gpa, p);
        }
    }
};

/// Reduces `src` to parallel and series normal form into `out` (cleared
/// and refilled), every merge made into `merges` (cleared), in order.
/// Devices come out one per group ascending by the group's lowest row;
/// surviving nets keep their order; the output is a fixed point. With no
/// names nothing merges and `src` comes through byte-identical. Each pass
/// that changes anything drops a device, so passes are bounded by devices.
pub fn reduceWith(gpa: Allocator, src: *const Graph, names: ParamNames, out: *Graph, merges: *Merges) Allocator.Error!void {
    merges.clear();
    var work = try src.clone(gpa);
    defer work.deinit(gpa);
    try foldMultiplier(gpa, &work, names);
    var spare: Graph = .{};
    defer spare.deinit(gpa);
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    // `origin`: the input rows each current device stands for, CSR.
    var origin: Csr = .{};
    defer origin.deinit(gpa);
    var next: Csr = .{};
    defer next.deinit(gpa);
    try origin.start.append(gpa, 0);
    for (0..src.deviceCount()) |d| {
        try origin.rows.append(gpa, @intCast(d));
        try origin.start.append(gpa, @intCast(d + 1));
    }
    var groups: Csr = .{};
    defer groups.deinit(gpa);
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(gpa);
    var pass: usize = 0;
    while (pass <= 2 * @as(usize, src.deviceCount())) : (pass += 1) {
        const mode: MergeKind = if (try plan_mod.planInto(gpa, &work, names, .parallel, &plan))
            .parallel
        else if (try plan_mod.planInto(gpa, &work, names, .series, &plan))
            .series
        else if (names.gates) {
            // Logic-gate reduction, once nothing else merges; its groups come
            // ascending by lowest row, as a plan's do.
            const kind = (try gates.passInto(gpa, &work, names, &spare, &groups.start, &groups.rows)) orelse break;
            try next.clear(gpa);
            for (0..groups.start.items.len - 1) |gi| {
                const group = groups.rows.items[groups.start.items[gi]..groups.start.items[gi + 1]];
                try gatherRows(gpa, &origin, group, &rows);
                if (group.len > 1) try merges.push(gpa, kind, work.device_model.items[group[0]], rows.items);
                try next.append(gpa, rows.items);
            }
            std.mem.swap(Csr, &origin, &next);
            std.mem.swap(Graph, &work, &spare);
            continue;
        } else break;
        try next.clear(gpa);
        const order = plan.order.items;
        var at: usize = 0;
        while (at < order.len) {
            var end = at + 1;
            while (end < order.len and plan.root.items[order[end]] == plan.root.items[order[at]]) end += 1;
            try gatherRows(gpa, &origin, order[at..end], &rows);
            if (end - at > 1) try merges.push(gpa, mode, work.device_model.items[order[at]], rows.items);
            try next.append(gpa, rows.items);
            at = end;
        }
        std.mem.swap(Csr, &origin, &next);
        try emitInto(gpa, &work, &plan, names, &spare);
        std.mem.swap(Graph, &work, &spare);
    }
    std.mem.swap(Graph, out, &work);
}

// ---- private ----

/// The input rows a group of current devices stands for, ascending.
fn gatherRows(gpa: Allocator, origin: *const Csr, group: []const u32, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (group) |d| try out.appendSlice(gpa, origin.rows.items[origin.start.items[d]..origin.start.items[d + 1]]);
    std.mem.sortUnstable(u32, out.items, {}, std.sort.asc(u32));
}

fn isDiffusion(names: ParamNames, name: StrId) bool {
    for (names.diffusion) |d| if (law.is(d, name)) return true;
    return false;
}

/// `m` devices in parallel are one of `m` times the width and diffusion.
/// Untouched without the `m` name.
fn foldMultiplier(gpa: Allocator, g: *Graph, names: ParamNames) Allocator.Error!void {
    const multiplier = names.multiplier orelse return;
    try graph.rewriteParams(gpa, g, FoldCtx{ .names = names, .multiplier = multiplier });
}
