//! What the deck's per-model `lvs` statements change in how terminals and
//! parameters compare: the roles `lvs asymmetric` and `lvs permute` give
//! pins, the bound `lvs tolerance` puts on a parameter, and the refinement
//! seeds `lvs ports_by_name` and `lvs same_nets` start nets in. In: the
//! controls and the graphs. Out: roles rewritten in place, a `Bound`, seeds.
//! Ported from crates/check/src/lvs/controls.rs (`Classes`, `assign_roles`,
//! `report_roles`, `Bound`, `bound`, `port_names`, `port_seeds`).
//!
//! Contents:
//! - `pub const fixed_source: TerminalRole`, `pub const fixed_drain: TerminalRole`, `pub const permuted: u8`
//! - `pub const Classes = struct`, `of(kind: DeviceKind, model: StrId, controls: *const LvsControls) ?Classes`,
//!   `role(c: Classes, position: u8) TerminalRole`, `reported(c: Classes, role: TerminalRole) TerminalRole`
//! - `pub fn assignRoles(gpa: Allocator, g: *Graph, controls: *const LvsControls) Allocator.Error!void`
//! - `pub fn reportRoles(found: []Discrepancy, reference: *const Graph, controls: *const LvsControls) void`
//! - `pub const Bound = struct`, `agree(b: Bound, a: f64, b: f64) bool`
//! - `pub fn bound(controls: *const LvsControls, default: f64, model: StrId, param: StrId) Bound`
//! - `pub fn portNamesInto(gpa: Allocator, reference: *const Graph, out: *std.ArrayList(StrId)) Allocator.Error!void`
//! - `pub fn portSeedsInto(gpa: Allocator, layout: *const Graph, reference: *const Graph, names: []const StrId, same_nets: []const SameNets, out: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const deck = @import("ingest").deck;
const DeviceKind = deck.DeviceKind;
const LvsControls = deck.LvsControls;
const SameNets = deck.SameNets;
const device_mod = @import("../topology/device.zig");
const TerminalRole = device_mod.TerminalRole;
const roleAt = device_mod.roleAt;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const Discrepancy = @import("verdict.zig").Discrepancy;

/// The role an asymmetric transistor's source compares under: a pin of its
/// own, so it never trades places with the drain.
pub const fixed_source: TerminalRole = .{ .pin = 0 };

/// The role an asymmetric transistor's drain compares under.
pub const fixed_drain: TerminalRole = .{ .pin = 1 };

/// Pins `lvs permute` joins share `pin = permuted + p`, `p` the class's
/// lowest position: past every role a four-pin device has, and no channel.
pub const permuted: u8 = 8;

/// The pins of one device as `lvs asymmetric` and `lvs permute` leave them:
/// `root[p]` is the lowest position interchangeable with position `p`, in
/// `device` statement order.
pub const Classes = struct {
    kind: DeviceKind,
    root: [4]u8,
    asymmetric: bool,

    /// The default classes (a transistor's source and drain unless
    /// asymmetric, a resistor's ends) joined with every `lvs permute` pair of
    /// the model. Null when no control names the model.
    pub fn of(kind: DeviceKind, model: StrId, controls: *const LvsControls) ?Classes {
        const asymmetric = kind == .mos and std.mem.indexOfScalar(StrId, controls.asymmetric, model) != null;
        var named = false;
        for (controls.permute) |row| named = named or row.model == model;
        if (!asymmetric and !named) return null;
        var c: Classes = .{ .kind = kind, .root = .{ 0, 1, 2, 3 }, .asymmetric = asymmetric };
        switch (kind) {
            .mos => if (!asymmetric) c.join(1, 2),
            .resistor, .inductor => c.join(0, 1),
            .bjt, .capacitor, .diode, .cell => {},
        }
        for (controls.permute) |row| if (row.model == model) c.join(row.a, row.b);
        return c;
    }

    /// The role position `position` compares under: the default classes keep
    /// the builders' roles, an asymmetric transistor's lone ends are
    /// `fixed_source` and `fixed_drain`, any other lone pin keeps its role,
    /// and every other class is `pin = permuted + lowest position`.
    pub fn role(c: Classes, position: u8) TerminalRole {
        const class = c.classOf(position);
        if (c.kind == .mos and class == 0b0110) return roleAt(c.kind, position);
        if ((c.kind == .resistor or c.kind == .inductor) and class == 0b0011) return .{ .pin = 0 };
        if (std.math.isPowerOfTwo(class)) {
            if (c.asymmetric and position == 1) return fixed_source;
            if (c.asymmetric and position == 2) return fixed_drain;
            return roleAt(c.kind, position);
        }
        return .{ .pin = permuted + c.root[position] };
    }

    /// The role a terminal compared under `r` is reported as: a fixed end as
    /// the end it is, a permuted class as its lowest pin.
    pub fn reported(c: Classes, r: TerminalRole) TerminalRole {
        switch (r) {
            .pin => |pin| {
                if (c.asymmetric and pin == fixed_source.pin) return .source;
                if (c.asymmetric and pin == fixed_drain.pin) return .drain;
                if (pin >= permuted) return roleAt(c.kind, pin - permuted);
                return r;
            },
            .gate, .source, .drain, .bulk, .base, .emitter, .collector => return r,
        }
    }

    // ---- private ----

    /// Joins the classes of positions `a` and `b`; past four is no pin.
    fn join(c: *Classes, a: u8, b: u8) void {
        if (a >= 4 or b >= 4) return;
        const low = @min(c.root[a], c.root[b]);
        const high = @max(c.root[a], c.root[b]);
        for (&c.root) |*r| if (r.* == high) {
            r.* = low;
        };
    }

    /// The positions in `position`'s class, as a bit mask.
    fn classOf(c: Classes, position: u8) u8 {
        var mask: u8 = 0;
        for (0..4) |p| if (c.root[p] == c.root[position]) {
            mask |= @as(u8, 1) << @intCast(p);
        };
        return mask;
    }
};

/// How far apart two values of one parameter may be and still agree.
pub const Bound = struct {
    /// A fraction of the larger value.
    relative: f64,
    /// In the parameter's SI unit.
    absolute: f64,

    /// `|a - b| <= absolute + relative·max(|a|, |b|)`; `NaN` never agrees.
    pub fn agree(self: Bound, a: f64, b: f64) bool {
        return @abs(a - b) <= self.absolute + self.relative * @max(@abs(a), @abs(b));
    }
};

/// Gives every device of a model `lvs asymmetric` or `lvs permute` names the
/// roles `Classes.role` says, both directions of the incidence. A class
/// other than the default channel is no channel, so no series merge takes
/// it. Untouched with neither control.
pub fn assignRoles(gpa: Allocator, g: *Graph, controls: *const LvsControls) Allocator.Error!void {
    if (controls.asymmetric.len == 0 and controls.permute.len == 0) return;
    var changed = false;
    for (0..g.deviceCount()) |d| {
        const kind = g.device_kind.items[d];
        const classes = Classes.of(kind, g.device_model.items[d], controls) orelse continue;
        const from = g.device_terminal_start.items[d];
        const to = g.device_terminal_start.items[d + 1];
        for (g.terminal_role.items[from..to]) |*r| {
            if (positionOf(kind, r.*)) |position| r.* = classes.role(position);
        }
        changed = true;
    }
    if (changed) try graph.transposeInto(gpa, g, g.netCount());
}

/// Names each terminal mismatch in `found` by a role its device was drawn
/// with: an asymmetric end as that end, a permuted pin as its class's
/// lowest. `reference` is the reduced reference graph the rows index.
pub fn reportRoles(found: []Discrepancy, reference: *const Graph, controls: *const LvsControls) void {
    for (found) |*d| switch (d.*) {
        .terminal_mismatch => |*t| {
            const classes = Classes.of(reference.device_kind.items[t.ref_device], reference.device_model.items[t.ref_device], controls) orelse continue;
            t.role = classes.reported(t.role);
        },
        .unpaired_device, .unpaired_net, .parameter_mismatch, .undeclared_param, .model_mismatch, .class_imbalance => {},
    };
}

/// The bound on `param` of `model`: the deck's `lvs tolerance` row, whose
/// parts replace the run's, or the run's relative `default` alone.
///
/// ponytail: a linear scan per parameter; a deck states a handful of rows.
pub fn bound(controls: *const LvsControls, default: f64, model: StrId, param: StrId) Bound {
    for (controls.tolerance) |row| {
        if (row.model == model and row.param == param) return .{ .relative = row.relative, .absolute = row.absolute };
    }
    return .{ .relative = default, .absolute = 0.0 };
}

/// The names of `reference`'s ports, ascending, each once: what `lvs
/// ports_by_name` pairs by.
pub fn portNamesInto(gpa: Allocator, reference: *const Graph, out: *std.ArrayList(StrId)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (reference.port_net.items) |n| if (reference.net_name.items[n]) |name| try out.append(gpa, name);
    std.mem.sortUnstable(StrId, out.items, {}, lessStr);
    var kept: usize = 0;
    for (out.items) |name| {
        if (kept > 0 and out.items[kept - 1] == name) continue;
        out.items[kept] = name;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
}

/// The refinement seed of every node of the two reduced graphs, layout
/// first, devices before nets on each side, into `out`: a layout net
/// labelled with a port name and the reference port of that name share the
/// name's rank; the layout net labelled and the reference net named by one
/// `lvs same_nets` row share a rank after the ports (a port's own wins).
/// Every other node is `no_net`.
pub fn portSeedsInto(gpa: Allocator, layout: *const Graph, reference: *const Graph, names: []const StrId, same_nets: []const SameNets, out: *std.ArrayList(u32)) Allocator.Error!void {
    const split = layout.deviceCount() + layout.netCount();
    out.clearRetainingCapacity();
    try out.appendNTimes(gpa, no_net, @as(usize, split) + reference.deviceCount() + reference.netCount());
    for (layout.net_name.items, 0..) |name, n| {
        out.items[layout.deviceCount() + n] = rank(names, name) orelse paired(names, same_nets, name, .layout) orelse no_net;
    }
    const base = split + reference.deviceCount();
    for (reference.net_name.items, 0..) |name, n| {
        out.items[base + n] = paired(names, same_nets, name, .reference) orelse no_net;
    }
    for (reference.port_net.items) |n| {
        if (rank(names, reference.net_name.items[n])) |r| out.items[base + n] = r;
    }
}

// ---- private ----

/// The position a built role stands at for `kind`, the inverse of `roleAt`;
/// a resistor's ends, both built `pin = 0`, read as position 0.
fn positionOf(kind: DeviceKind, r: TerminalRole) ?u8 {
    for (0..4) |p| if (graph.roleEql(roleAt(kind, @intCast(p)), r)) return @intCast(p);
    return null;
}

fn lessStr(_: void, a: StrId, b: StrId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn rank(names: []const StrId, name: ?StrId) ?u32 {
    const n = name orelse return null;
    const at = std.sort.binarySearch(StrId, names, n, struct {
        fn order(want: StrId, item: StrId) std.math.Order {
            return std.math.order(@backingInt(want), @backingInt(item));
        }
    }.order) orelse return null;
    return @intCast(at);
}

fn paired(names: []const StrId, same_nets: []const SameNets, name: ?StrId, side: enum { layout, reference }) ?u32 {
    const n = name orelse return null;
    for (same_nets, 0..) |row, at| {
        const want = switch (side) {
            .layout => row.layout,
            .reference => row.reference,
        };
        if (want == n) return @intCast(names.len + at);
    }
    return null;
}
