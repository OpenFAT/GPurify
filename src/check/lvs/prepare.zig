//! The rewrites that make two projected graphs comparable before and after
//! reduction, none a deck control: the reference bulk a three-terminal
//! layout cannot extract, the layout measures no reference card of the
//! model declares, the reference nets a layout label protects, the
//! stress-distance pair's order, and the count every card has. In: graphs.
//! Out: the same graphs rewritten in place. Ported from
//! crates/check/src/lvs/graph.rs (`drop_unextracted_bulk`,
//! `keep_declared_params`), compare.rs (`protect_labelled`, `state_count`)
//! and lde.rs (`sort_stress_pair`).
//!
//! Contents:
//! - `pub fn dropUnextractedBulk(gpa: Allocator, layout: *const Graph, g: *Graph) Allocator.Error!void`
//! - `pub fn keepDeclaredParams(gpa: Allocator, reference: *const Graph, layout: *Graph) Allocator.Error!void`
//! - `pub fn protectLabelled(gpa: Allocator, layout: *const Graph, reference: *Graph) Allocator.Error!void`
//! - `pub fn sortStressPair(g: *Graph, stress: [2]?StrId) void`
//! - `pub fn stateCount(gpa: Allocator, g: *Graph, multiplier: StrId) Allocator.Error!void`
//! - private `KeepCtx`, `CountCtx`: its `rewrite` is `pub` only because `graph.rewriteParams` looks it up at comptime

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Param = graph.Param;

const Declared = struct {
    kind: u64,
    model: u32,
    name: u32,

    fn less(_: void, a: Declared, b: Declared) bool {
        if (a.kind != b.kind) return a.kind < b.kind;
        if (a.model != b.model) return a.model < b.model;
        return a.name < b.name;
    }

    fn order(want: Declared, item: Declared) std.math.Order {
        if (less({}, want, item)) return .lt;
        if (less({}, item, want)) return .gt;
        return .eq;
    }
};

const KeepCtx = struct {
    declared: []const Declared,

    pub fn rewrite(c: KeepCtx, gpa: Allocator, g: *const Graph, device: u32, out: *std.ArrayList(Param)) Allocator.Error!void {
        for (g.paramsOf(device)) |p| {
            if (std.sort.binarySearch(Declared, c.declared, declaredOf(g, device, p.name), Declared.order) != null) try out.append(gpa, p);
        }
    }
};

const CountCtx = struct {
    multiplier: StrId,

    pub fn rewrite(c: CountCtx, gpa: Allocator, g: *const Graph, device: u32, out: *std.ArrayList(Param)) Allocator.Error!void {
        const params = g.paramsOf(device);
        try out.appendSlice(gpa, params);
        if (indexOf(params, c.multiplier) == null) try out.append(gpa, .{ .name = c.multiplier, .value = 1.0 });
    }
};

/// Drops every `bulk` terminal of `g` when no layout terminal is a bulk (the
/// deck extracts none). Side-wide, so a missing bulk strap still mismatches.
/// Only terminals go, never nets.
pub fn dropUnextractedBulk(gpa: Allocator, layout: *const Graph, g: *Graph) Allocator.Error!void {
    if (hasBulk(layout) or !hasBulk(g)) return;
    var kept: usize = 0;
    var device: usize = 0;
    var from: u32 = 0;
    // In place: kept terminals only move left.
    while (device < g.deviceCount()) : (device += 1) {
        const to = g.device_terminal_start.items[device + 1];
        for (from..to) |slot| {
            if (g.terminal_role.items[slot] == .bulk) continue;
            g.terminal_net.items[kept] = g.terminal_net.items[slot];
            g.terminal_role.items[kept] = g.terminal_role.items[slot];
            kept += 1;
        }
        from = to;
        g.device_terminal_start.items[device + 1] = @intCast(kept);
    }
    g.terminal_net.shrinkRetainingCapacity(kept);
    g.terminal_role.shrinkRetainingCapacity(kept);
    try graph.transposeInto(gpa, g, g.netCount());
}

/// Keeps each layout parameter only where the reference declares that name
/// on some device of the same kind and model: a reference sizing one model
/// says nothing about another (testing-plan F22), so such a measure must
/// not block a merge. Which parameters a pair compares is decided per
/// device after reduction (F68).
pub fn keepDeclaredParams(gpa: Allocator, reference: *const Graph, layout: *Graph) Allocator.Error!void {
    var declared: std.ArrayList(Declared) = .empty;
    defer declared.deinit(gpa);
    for (0..reference.deviceCount()) |d| {
        for (reference.paramsOf(@intCast(d))) |p| try declared.append(gpa, declaredOf(reference, @intCast(d), p.name));
    }
    std.mem.sortUnstable(Declared, declared.items, {}, Declared.less);
    try graph.rewriteParams(gpa, layout, KeepCtx{ .declared = declared.items });
}

/// Makes every reference net a layout label names a port of `reference`: a
/// label makes a layout port, and a series merge never crosses a port, so
/// the reference's net of that name must stop the merge too (testing-plan
/// F12).
pub fn protectLabelled(gpa: Allocator, layout: *const Graph, reference: *Graph) Allocator.Error!void {
    var labels: std.ArrayList(StrId) = .empty;
    defer labels.deinit(gpa);
    for (layout.port_net.items) |n| if (layout.net_name.items[n]) |name| try labels.append(gpa, name);
    std.mem.sortUnstable(StrId, labels.items, {}, lessStr);
    const is_port = try gpa.alloc(bool, reference.netCount());
    defer gpa.free(is_port);
    @memset(is_port, false);
    for (reference.port_net.items) |n| is_port[n] = true;
    for (is_port, 0..) |port, n| {
        const name = reference.net_name.items[n] orelse continue;
        if (!port and containsStr(labels.items, name)) try reference.port_net.append(gpa, @intCast(n));
    }
}

/// Sorts each device's `sa` and `sb`, smaller first, as the layout's are
/// measured: the stress model reads them only as a pair. A device stating
/// one alone keeps it.
pub fn sortStressPair(g: *Graph, stress: [2]?StrId) void {
    const sa = stress[0] orelse return;
    const sb = stress[1] orelse return;
    for (0..g.deviceCount()) |d| {
        const params = g.param.items[g.device_param_start.items[d]..g.device_param_start.items[d + 1]];
        const a = indexOf(params, sa) orelse continue;
        const b = indexOf(params, sb) orelse continue;
        if (params[a].value > params[b].value) std.mem.swap(f64, &params[a].value, &params[b].value);
    }
}

/// Writes `m = 1` on each device that states no count: a card without `m`
/// is one device, compared like any stated count (a count is no measure,
/// so per-device presence, F68, does not apply).
pub fn stateCount(gpa: Allocator, g: *Graph, multiplier: StrId) Allocator.Error!void {
    try graph.rewriteParams(gpa, g, CountCtx{ .multiplier = multiplier });
}

// ---- private ----

fn declaredOf(g: *const Graph, device: u32, name: StrId) Declared {
    return .{ .kind = graph.kindCode(g.device_kind.items[device]), .model = @backingInt(g.device_model.items[device]), .name = @backingInt(name) };
}

fn hasBulk(g: *const Graph) bool {
    for (g.terminal_role.items) |r| if (r == .bulk) return true;
    return false;
}

fn indexOf(params: []const Param, name: StrId) ?usize {
    for (params, 0..) |p, at| if (p.name == name) return at;
    return null;
}

fn lessStr(_: void, a: StrId, b: StrId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn containsStr(sorted: []const StrId, name: StrId) bool {
    return std.sort.binarySearch(StrId, sorted, name, struct {
        fn order(want: StrId, item: StrId) std.math.Order {
            return std.math.order(@backingInt(want), @backingInt(item));
        }
    }.order) != null;
}
