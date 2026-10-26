//! The per-net tables every ERC run computes once and most rules read. In:
//! nets, devices, ports, the optional design intent. Out: `NetFacts` (the
//! terminal roles on each net), `IntentMap` (the intent keyed by `NetId`),
//! each power state's map (`resolveStatesInto`, `inState`), the AC-current
//! loads (`withBudget`) and `NetTypes` (the intent's net types per net).
//! `IntentMap.isUsable` is the one skip decision. Ported from
//! crates/check/src/erc/facts.rs.
//!
//! Contents:
//! - `pub const RoleMask = packed struct(u8)`, `RoleMask.of(role: TerminalRole) RoleMask`,
//!   `contains(m, other: RoleMask) bool`, `intersects(m, other) bool`, `merge(m, other) RoleMask`, `isEmpty(m) bool`
//! - `pub const NetFacts = struct`, `deinit`, `isDeviceConnected(f: *const NetFacts, net: NetId) bool`
//! - `pub fn classifyNetsInto(gpa: Allocator, nets: *const NetTable, devices: *const DeviceTable, out: *NetFacts) Allocator.Error!void`
//! - `pub const IntentMap = struct`, `deinit`, `supply(m, net: NetId) ?SupplyOf`, `nominalVoltage(m, net) ?Millivolts`,
//!   `heldAt(m, row: usize) Millivolts`, `limitsOf(m, net) NetLimits`, `isUsable(m) bool`,
//!   `inState(m, gpa: Allocator, state: *const StateMap) Allocator.Error!IntentMap`,
//!   `withBudget(m, gpa: Allocator, comptime pick: Budget) Allocator.Error!IntentMap`, `pub const Budget`, `pub const SupplyOf`
//! - `pub const StateMap = struct`, `deinit`
//! - `pub fn resolveStatesInto(gpa: Allocator, intent: ?*const DesignIntent, ports: *const PortTable, nets: *const NetTable, out: *std.ArrayList(StateMap)) Allocator.Error!void`
//! - `pub fn resolveIntentInto(gpa: Allocator, intent: ?*const DesignIntent, ports: *const PortTable, nets: *const NetTable, out: *IntentMap) Allocator.Error!void`
//! - `pub const NetTypes = struct`, `deinit`, `bit(t, name: StrId) ?u64`, `of(t, net: NetId) u64`
//! - `pub fn resolveNetTypesInto(gpa: Allocator, intent: ?*const DesignIntent, ports: *const PortTable, nets: *const NetTable, devices: *const DeviceTable, supplies: *const IntentMap, strings: *const StrTable, out: *NetTypes) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const intent_ = @import("ingest").intent;
const DesignIntent = intent_.DesignIntent;
const DomainId = intent_.DomainId;
const NetLimits = intent_.NetLimits;
const SupplyRole = intent_.SupplyRole;
const Millivolts = intent_.Millivolts;
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const device_ = @import("../topology/device.zig");
const DeviceTable = device_.DeviceTable;
const DeviceId = device_.DeviceId;
const TerminalRole = device_.TerminalRole;
const PortTable = @import("../topology/port.zig").PortTable;

/// Which terminal roles land on a net, one bit each. Every `pin` is one
/// bit: a symmetric device's pin index carries no meaning. Source and drain
/// are as extraction assigns them, by terminal order.
pub const RoleMask = packed struct(u8) {
    gate: bool = false,
    source: bool = false,
    drain: bool = false,
    bulk: bool = false,
    base: bool = false,
    emitter: bool = false,
    collector: bool = false,
    /// Any pin of a resistor, capacitor, diode or inductor.
    pin: bool = false,

    pub fn of(role: TerminalRole) RoleMask {
        return switch (role) {
            .gate => .{ .gate = true },
            .source => .{ .source = true },
            .drain => .{ .drain = true },
            .bulk => .{ .bulk = true },
            .base => .{ .base = true },
            .emitter => .{ .emitter = true },
            .collector => .{ .collector = true },
            .pin => .{ .pin = true },
        };
    }

    /// Every bit of `other` set in `m`.
    pub fn contains(m: RoleMask, other: RoleMask) bool {
        return bits(m) & bits(other) == bits(other);
    }

    pub fn intersects(m: RoleMask, other: RoleMask) bool {
        return bits(m) & bits(other) != 0;
    }

    pub fn merge(m: RoleMask, other: RoleMask) RoleMask {
        return @bitCast(bits(m) | bits(other));
    }

    /// No device terminal on the net.
    pub fn isEmpty(m: RoleMask) bool {
        return bits(m) == 0;
    }

    fn bits(m: RoleMask) u8 {
        return @bitCast(m);
    }
};

/// The roles on each net, indexed by `NetId`.
pub const NetFacts = struct {
    role: std.ArrayList(RoleMask) = .empty,

    pub fn deinit(f: *NetFacts, gpa: Allocator) void {
        f.role.deinit(gpa);
    }

    /// Some device terminal lands on `net`; false for `.none`.
    pub fn isDeviceConnected(f: *const NetFacts, net: NetId) bool {
        return net != .none and !f.role.items[@backingInt(net)].isEmpty();
    }
};

/// A declared supply's role and its domain's nominal voltage.
pub const SupplyOf = struct { role: SupplyRole, nominal: Millivolts };

/// Design intent re-keyed from names onto extracted nets. Invariant: the
/// `supply_*` columns are parallel and `supply_net` strictly ascends; so do
/// `limit_net` and `limit` (each with at least one limit set). The two net
/// lists may share nets.
pub const IntentMap = struct {
    /// False when no design intent was supplied at all.
    declared: bool = false,
    supply_net: std.ArrayList(NetId) = .empty,
    supply_role: std.ArrayList(SupplyRole) = .empty,
    supply_domain: std.ArrayList(DomainId) = .empty,
    /// The domain's nominal, whatever the role.
    supply_voltage: std.ArrayList(Millivolts) = .empty,
    limit_net: std.ArrayList(NetId) = .empty,
    limit: std.ArrayList(NetLimits) = .empty,

    pub fn deinit(m: *IntentMap, gpa: Allocator) void {
        inline for (.{ "supply_net", "supply_role", "supply_domain", "supply_voltage", "limit_net", "limit" }) |f| @field(m, f).deinit(gpa);
    }

    pub fn supply(m: *const IntentMap, net: NetId) ?SupplyOf {
        const row = findNet(m.supply_net.items, net) orelse return null;
        return .{ .role = m.supply_role.items[row], .nominal = m.supply_voltage.items[row] };
    }

    /// The voltage a declared supply net is held at.
    pub fn nominalVoltage(m: *const IntentMap, net: NetId) ?Millivolts {
        const row = findNet(m.supply_net.items, net) orelse return null;
        return m.heldAt(row);
    }

    /// Supply row `row`'s voltage: its domain's nominal for power, 0 for
    /// ground.
    pub fn heldAt(m: *const IntentMap, row: usize) Millivolts {
        return switch (m.supply_role.items[row]) {
            .power => m.supply_voltage.items[row],
            .ground => .{ .raw = 0.0 },
        };
    }

    /// The limits declared for a net; all null means *not checked*.
    pub fn limitsOf(m: *const IntentMap, net: NetId) NetLimits {
        const row = findNet(m.limit_net.items, net) orelse return .{};
        return m.limit.items[row];
    }

    /// True means *run*: intent was supplied and names a supply or a
    /// limited net this layout has.
    pub fn isUsable(m: *const IntentMap) bool {
        return m.declared and !(m.supply_net.items.len == 0 and m.limit_net.items.len == 0);
    }

    /// The supplies of power state `state`: every declared supply it does
    /// not switch off and does not hold, then every held net as a supply at
    /// its voltage (exactly 0 mV a ground, else power of domain 0). Limits
    /// are not carried. The caller owns the result.
    pub fn inState(m: *const IntentMap, gpa: Allocator, state: *const StateMap) Allocator.Error!IntentMap {
        const Row = struct { net: NetId, role: SupplyRole, domain: DomainId, volts: Millivolts };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(gpa);
        for (m.supply_net.items, 0..) |net, row| {
            const off = findNet(state.off.items, net) != null;
            const held = std.mem.indexOfScalar(NetId, state.input_net.items, net) != null;
            if (off or held) continue;
            try rows.append(gpa, .{ .net = net, .role = m.supply_role.items[row], .domain = m.supply_domain.items[row], .volts = m.supply_voltage.items[row] });
        }
        for (state.input_net.items, state.input_mv.items) |net, volts| {
            const role: SupplyRole = if (volts.raw == 0.0) .ground else .power;
            try rows.append(gpa, .{ .net = net, .role = role, .domain = @fromBackingInt(0), .volts = volts });
        }
        std.sort.block(Row, rows.items, {}, struct {
            fn less(_: void, a: Row, b: Row) bool {
                return @backingInt(a.net) < @backingInt(b.net);
            }
        }.less);
        var out: IntentMap = .{ .declared = true };
        errdefer out.deinit(gpa);
        for (rows.items) |r| {
            try out.supply_net.append(gpa, r.net);
            try out.supply_role.append(gpa, r.role);
            try out.supply_domain.append(gpa, r.domain);
            try out.supply_voltage.append(gpa, r.volts);
        }
        return out;
    }

    /// This intent with each net's current budget replaced by `pick` of its
    /// limits (its RMS or peak current), its frequency kept and no other
    /// limit: the loads `power_extract.extractInto` spreads for an AC
    /// current rule. A net `pick` gives nothing carries no load.
    pub fn withBudget(m: *const IntentMap, gpa: Allocator, comptime pick: Budget) Allocator.Error!IntentMap {
        var out: IntentMap = .{ .declared = m.declared };
        errdefer out.deinit(gpa);
        try out.supply_net.appendSlice(gpa, m.supply_net.items);
        try out.supply_role.appendSlice(gpa, m.supply_role.items);
        try out.supply_domain.appendSlice(gpa, m.supply_domain.items);
        try out.supply_voltage.appendSlice(gpa, m.supply_voltage.items);
        for (m.limit_net.items, m.limit.items) |net, limits| {
            const current = @field(limits, @tagName(pick)) orelse continue;
            try out.limit_net.append(gpa, net);
            try out.limit.append(gpa, .{ .budget_current_ua = current, .frequency_mhz = limits.frequency_mhz });
        }
        return out;
    }
};

/// Which AC current an `IntentMap.withBudget` loads the grid with.
pub const Budget = enum { rms_current_ua, peak_current_ua };

/// One declared power state re-keyed onto extracted nets. A name no
/// labelled net carries is dropped, as for `IntentMap`.
pub const StateMap = struct {
    name: StrId,
    /// Supply nets switched off in this state, ascending.
    off: std.ArrayList(NetId) = .empty,
    /// Nets held in this state, ascending, and their voltages.
    input_net: std.ArrayList(NetId) = .empty,
    input_mv: std.ArrayList(Millivolts) = .empty,

    pub fn deinit(s: *StateMap, gpa: Allocator) void {
        s.off.deinit(gpa);
        s.input_net.deinit(gpa);
        s.input_mv.deinit(gpa);
    }
};

/// The design's net types (US20100306720A1's net types and type sets) per
/// net. Bit `i` of a mask is `name[i]`: the declared types, then the sets,
/// in the intent's order, at most 64.
pub const NetTypes = struct {
    name: std.ArrayList(StrId) = .empty,
    /// Per net; empty when the intent declares none.
    mask: std.ArrayList(u64) = .empty,

    pub fn deinit(t: *NetTypes, gpa: Allocator) void {
        t.name.deinit(gpa);
        t.mask.deinit(gpa);
    }

    /// The bit of type or set `name`, or null for one not declared.
    pub fn bit(t: *const NetTypes, name: StrId) ?u64 {
        const at = std.mem.indexOfScalar(StrId, t.name.items, name) orelse return null;
        return @as(u64, 1) << @intCast(at);
    }

    /// The types and sets of `net`; none past the table.
    pub fn of(t: *const NetTypes, net: NetId) u64 {
        const i = @backingInt(net);
        return if (i < t.mask.items.len) t.mask.items[i] else 0;
    }
};

/// Every power state the intent declares, keyed onto extracted nets, in
/// file order; empty without intent or states. `out`'s old states are
/// freed first.
pub fn resolveStatesInto(gpa: Allocator, intent: ?*const DesignIntent, ports: *const PortTable, nets: *const NetTable, out: *std.ArrayList(StateMap)) Allocator.Error!void {
    for (out.items) |*s| s.deinit(gpa);
    out.clearRetainingCapacity();
    const i = intent orelse return;
    for (i.states) |state| {
        try out.append(gpa, .{ .name = state.name });
        const map = &out.items[out.items.len - 1];
        for (0..nets.netCount()) |n| {
            const net: NetId = @fromBackingInt(@as(u32, @intCast(n)));
            const name = ports.nameOf(net) orelse continue;
            if (std.mem.indexOfScalar(StrId, state.off, name) != null) try map.off.append(gpa, net);
            if (std.mem.indexOfScalar(StrId, state.input_net, name)) |at| {
                try map.input_net.append(gpa, net);
                try map.input_mv.append(gpa, state.input_mv[at]);
            }
        }
    }
}

/// Folds every device terminal into its net's role mask; `out` is refilled
/// to `nets.netCount()` rows. A terminal on no net, or past `nets`, drops.
pub fn classifyNetsInto(gpa: Allocator, nets: *const NetTable, devices: *const DeviceTable, out: *NetFacts) Allocator.Error!void {
    // A scrap row past the end takes `.none` (and any id past this
    // extraction) so its roles cannot leak onto a real net.
    const scrap = nets.netCount();
    out.role.clearRetainingCapacity();
    try out.role.appendNTimes(gpa, .{}, scrap + 1);
    for (devices.terminal_net.items, devices.terminal_role.items) |net, role| {
        const row = @min(@backingInt(net), scrap);
        out.role.items[row] = out.role.items[row].merge(.of(role));
    }
    out.role.shrinkRetainingCapacity(scrap);
}

/// Re-keys design intent onto extracted nets by each net's label name;
/// `out` is cleared and refilled. Null leaves `declared` false, which is
/// how the intent rules report skipped. A supply or limit no labelled net
/// carries is dropped without a report.
pub fn resolveIntentInto(gpa: Allocator, intent: ?*const DesignIntent, ports: *const PortTable, nets: *const NetTable, out: *IntentMap) Allocator.Error!void {
    out.deinit(gpa);
    out.* = .{};
    const i = intent orelse return;
    out.declared = !i.isEmpty();
    // ponytail: a declared supply the layout never labelled is silently
    // absent; reporting it needs a way to enumerate the intent's names.
    for (0..nets.netCount()) |n| {
        const net: NetId = @fromBackingInt(@as(u32, @intCast(n)));
        const name = ports.nameOf(net) orelse continue;
        if (i.supplyRole(name)) |s| {
            try out.supply_net.append(gpa, net);
            try out.supply_role.append(gpa, s.role);
            try out.supply_domain.append(gpa, s.domain);
            try out.supply_voltage.append(gpa, i.domainVoltage(s.domain));
        }
        const limits = i.limits(name);
        if (limits.max_drop != null or limits.max_drop_fraction != null or limits.max_overvoltage != null or
            limits.budget_current_ua != null or limits.rms_current_ua != null or limits.peak_current_ua != null)
        {
            try out.limit_net.append(gpa, net);
            try out.limit.append(gpa, limits);
        }
    }
}

/// Assigns the intent's net types to nets; `out` is refilled, empty
/// without intent or a declared type. A type by name marks every net whose
/// first label matches one of its patterns (`lvsPower`/`lvsGround` the
/// supplies `supplies` resolved, `lvsOutline` every labelled net); a type by
/// device marks the nets on the listed pins of the listed models' devices.
/// A set marks a net with any member, in declaration order.
pub fn resolveNetTypesInto(gpa: Allocator, intent: ?*const DesignIntent, ports: *const PortTable, nets: *const NetTable, devices: *const DeviceTable, supplies: *const IntentMap, strings: *const StrTable, out: *NetTypes) Allocator.Error!void {
    out.name.clearRetainingCapacity();
    out.mask.clearRetainingCapacity();
    const i = intent orelse return;
    if (i.net_types.len == 0) return;
    for (i.net_types) |t| if (std.mem.indexOfScalar(StrId, out.name.items, t.name) == null) try out.name.append(gpa, t.name);
    for (i.type_sets) |s| try out.name.append(gpa, s.name);
    assert(out.name.items.len <= intent_.max_net_types);
    const count = nets.netCount();
    try out.mask.appendNTimes(gpa, 0, count);
    for (i.net_types) |t| {
        const b = out.bit(t.name).?;
        switch (t.by) {
            .names => |patterns| for (out.mask.items, 0..) |*mask, n| {
                const net: NetId = @fromBackingInt(@as(u32, @intCast(n)));
                const label = ports.nameOf(net);
                const role: ?SupplyRole = if (supplies.supply(net)) |s| s.role else null;
                const hit = for (patterns) |p| {
                    const yes = if (std.mem.eql(u8, p, "lvsPower"))
                        role == .power
                    else if (std.mem.eql(u8, p, "lvsGround"))
                        role == .ground
                    else if (std.mem.eql(u8, p, "lvsOutline"))
                        label != null
                    else if (label) |name| glob(p, strings.resolve(name)) else false;
                    if (yes) break true;
                } else false;
                if (hit) mask.* |= b;
            },
            .devices => |d| for (0..devices.len()) |dev| {
                const listed_model = std.mem.indexOfScalar(StrId, d.models, devices.model.items[dev]) != null;
                if (listed_model == d.negate) continue;
                const terms = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(dev))));
                for (terms.nets, terms.roles) |net, role| {
                    const listed = d.pins.len == 0 or for (d.pins) |p| {
                        if (std.mem.eql(u8, p, pinName(role))) break true;
                    } else false;
                    if (listed and @backingInt(net) < count) out.mask.items[@backingInt(net)] |= b;
                }
            },
        }
    }
    for (i.type_sets) |s| {
        const b = out.bit(s.name).?;
        var members: u64 = 0;
        for (s.types) |m| members |= out.bit(m) orelse 0;
        for (out.mask.items) |*mask| if (mask.* & members != 0) {
            mask.* |= b;
        };
    }
}

// ---- private ----

/// The row of `net` in an ascending column.
fn findNet(column: []const NetId, net: NetId) ?usize {
    return std.sort.binarySearch(NetId, column, net, struct {
        fn order(a: NetId, b: NetId) std.math.Order {
            return std.math.order(@backingInt(a), @backingInt(b));
        }
    }.order);
}

/// `text` matches `pattern` whole, a `?` matching zero or more characters
/// (US20100306720A1 [0201]).
fn glob(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '?') {
        for (0..text.len + 1) |skip| if (glob(pattern[1..], text[skip..])) return true;
        return false;
    }
    return text.len > 0 and text[0] == pattern[0] and glob(pattern[1..], text[1..]);
}

/// The pin name a device-assigned net type lists for a role.
fn pinName(role: TerminalRole) []const u8 {
    return switch (role) {
        .gate => "g",
        .source => "s",
        .drain => "d",
        .bulk, .base => "b",
        .emitter => "e",
        .collector => "c",
        .pin => |p| switch (p) {
            0 => "pos",
            1 => "neg",
            else => "",
        },
    };
}

test "a glob's ? matches any run, the rest whole" {
    // Oracle: hand-derived from US20100306720A1 [0201]: `?` is zero or more
    // characters, everything else literal and anchored at both ends.
    try std.testing.expect(glob("VDD?", "VDD"));
    try std.testing.expect(glob("VDD?", "VDD_IO"));
    try std.testing.expect(glob("?A?", "xAy"));
    try std.testing.expect(!glob("VDD", "VDD1"));
    try std.testing.expect(!glob("A?B", "AxC"));
    try std.testing.expect(glob("", ""));
}
