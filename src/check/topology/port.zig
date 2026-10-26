//! Port binding: layout labels attached to extracted nets. In: a
//! `NetTable` and the layout's labels (`Provenance.labels()`). Out: a
//! `PortTable`, one row per distinct `(net, name)`. A name on several nets
//! (an open) and a net with several names (a short) bind as drawn, never
//! resolved by picking a side. Ported from crates/check/src/topology/port.rs.
//!
//! Contents:
//! - `pub const PortTable = struct`, `deinit`, `len(t: *const PortTable) u32`,
//!   `nameOf(t: *const PortTable, net: NetId) ?StrId`, `namesOf(t: *const PortTable, net: NetId) []const StrId`,
//!   `netsOf(t: *const PortTable, name: StrId) []const NetId`, `netOf(t: *const PortTable, name: StrId) ?NetId`,
//!   `splitName(t: *const PortTable) ?StrId`, `shortedNet(t: *const PortTable) ?NetId`
//! - `pub const PortError = error{OrphanLabel}`
//! - `pub fn bindPortsInto(gpa: Allocator, nets: *const NetTable, labels: []const Label, out: *PortTable) (PortError || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const Label = @import("ingest").provenance.Label;
const net = @import("net.zig");
const NetId = net.NetId;
const NetTable = net.NetTable;

/// Named nets. Invariant: `net`, `name`, `poly` are parallel and ascend by
/// `(net, name)`, `poly` the lowest polygon carrying that name on that net;
/// `by_name`/`by_name_net` are the same rows ascending by `(name, net)`.
pub const PortTable = struct {
    net: std.ArrayList(NetId) = .empty,
    name: std.ArrayList(StrId) = .empty,
    poly: std.ArrayList(PolyId) = .empty,
    by_name: std.ArrayList(StrId) = .empty,
    by_name_net: std.ArrayList(NetId) = .empty,

    pub fn deinit(t: *PortTable, gpa: Allocator) void {
        inline for (@typeInfo(PortTable).@"struct".field_names) |f| @field(t, f).deinit(gpa);
    }

    /// Distinct `(net, name)` bindings.
    pub fn len(t: *const PortTable) u32 {
        return @intCast(t.net.items.len);
    }

    /// A net's name, the first in `StrId` order when it has several.
    pub fn nameOf(t: *const PortTable, n: NetId) ?StrId {
        const names = t.namesOf(n);
        return if (names.len == 0) null else names[0];
    }

    /// Every name a net carries, ascending; more than one is a short.
    pub fn namesOf(t: *const PortTable, n: NetId) []const StrId {
        const from = std.sort.lowerBound(NetId, t.net.items, n, orderNet);
        const to = std.sort.upperBound(NetId, t.net.items, n, orderNet);
        return t.name.items[from..to];
    }

    /// Every net a name is on, ascending; more than one is an open.
    pub fn netsOf(t: *const PortTable, name: StrId) []const NetId {
        const from = std.sort.lowerBound(StrId, t.by_name.items, name, orderStr);
        const to = std.sort.upperBound(StrId, t.by_name.items, name, orderStr);
        return t.by_name_net.items[from..to];
    }

    /// The net a name refers to when exactly one net carries it.
    pub fn netOf(t: *const PortTable, name: StrId) ?NetId {
        const nets = t.netsOf(name);
        return if (nets.len == 1) nets[0] else null;
    }

    /// The first name in `StrId` order on several nets: an open.
    pub fn splitName(t: *const PortTable) ?StrId {
        const names = t.by_name.items;
        for (names[0..names.len -| 1], names[@min(1, names.len)..]) |a, b| if (a == b) return a;
        return null;
    }

    /// The lowest net carrying several names: a short.
    pub fn shortedNet(t: *const PortTable) ?NetId {
        const nets = t.net.items;
        for (nets[0..nets.len -| 1], nets[@min(1, nets.len)..]) |a, b| if (a == b) return a;
        return null;
    }
};

pub const PortError = error{
    /// A label sits on a shape on no net (a layer that is not a conductor).
    OrphanLabel,
};

const Bound = struct {
    net: NetId,
    name: StrId,
    poly: PolyId,

    fn byNet(_: void, a: Bound, b: Bound) bool {
        if (a.net != b.net) return @backingInt(a.net) < @backingInt(b.net);
        if (a.name != b.name) return @backingInt(a.name) < @backingInt(b.name);
        return @backingInt(a.poly) < @backingInt(b.poly);
    }

    fn byName(_: void, a: Bound, b: Bound) bool {
        if (a.name != b.name) return @backingInt(a.name) < @backingInt(b.name);
        return @backingInt(a.net) < @backingInt(b.net);
    }
};

/// Binds every label to its net into `out` (cleared and refilled; left
/// empty on error). The same name twice on one net binds once. `nets` must
/// come from the store the labels describe.
pub fn bindPortsInto(gpa: Allocator, nets: *const NetTable, labels: []const Label, out: *PortTable) (PortError || Allocator.Error)!void {
    inline for (@typeInfo(PortTable).@"struct".field_names) |f| @field(out, f).clearRetainingCapacity();
    const bound = try gpa.alloc(Bound, labels.len);
    defer gpa.free(bound);
    for (bound, labels) |*b, l| {
        b.* = .{ .net = nets.netOf(l.poly), .name = l.name, .poly = l.poly };
        if (b.net == .none) return error.OrphanLabel;
    }
    // Sorted, a binding's lowest polygon leads its run and survives.
    std.mem.sortUnstable(Bound, bound, {}, Bound.byNet);
    var kept: usize = 0;
    for (bound) |b| {
        if (kept > 0 and bound[kept - 1].net == b.net and bound[kept - 1].name == b.name) continue;
        bound[kept] = b;
        kept += 1;
    }
    for (bound[0..kept]) |b| {
        try out.net.append(gpa, b.net);
        try out.name.append(gpa, b.name);
        try out.poly.append(gpa, b.poly);
    }
    std.mem.sortUnstable(Bound, bound[0..kept], {}, Bound.byName);
    for (bound[0..kept]) |b| {
        try out.by_name.append(gpa, b.name);
        try out.by_name_net.append(gpa, b.net);
    }
}

// ---- private ----

fn orderNet(want: NetId, item: NetId) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(item));
}

fn orderStr(want: StrId, item: StrId) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(item));
}
