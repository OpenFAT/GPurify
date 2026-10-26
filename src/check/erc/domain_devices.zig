//! The device-list kinds of the domain family, dispatched with the
//! topological kinds: `power_switch` (ERC-F14 partial: a switch joins an
//! always-on supply to a switched one of the same role, and its gate is
//! driven in every power state; IEEE 1801 scope, Liu DVCon), `hot_carrier`
//! (ERC-F4, GF180MCU §14.1.4.1: a minimum-length device used in both
//! directions) and `well_sharing` (ERC-D9, US 5,638,286: a transistor fed
//! from a supply other than its well's). In: devices, nets, the intent and
//! each power state's reach. Out: violations and one run per row. Ported
//! from crates/check/src/erc/rules/domain.rs.
//!
//! Contents:
//! - `pub fn checkPowerSwitch(r: Record, design: Design, intent: *const IntentMap, switched: []const NetId, states: []const NetVoltage, t: *const PowerSwitchTable) Allocator.Error!void`
//! - `pub fn checkHotCarrier(r: Record, design: Design, intent: *const IntentMap, t: *const HotCarrierTable) Allocator.Error!void`
//! - `pub fn checkWellSharing(r: Record, design: Design, t: *const WellSharingTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const StrId = geom.StrId;
const NetId = @import("../topology/net.zig").NetId;
const device_ = @import("../topology/device.zig");
const DeviceId = device_.DeviceId;
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const terminalNet = head.terminalNet;
const IntentMap = @import("facts.zig").IntentMap;
const NetVoltage = @import("voltage.zig").NetVoltage;
const tables = @import("domain_tables.zig");
const HotCarrierTable = tables.HotCarrierTable;
const PowerSwitchTable = tables.PowerSwitchTable;
const WellSharingTable = tables.WellSharingTable;

/// Every MOS's channel ends and the scratch of a net walk.
const Walker = struct {
    /// `[source, drain]` per device; `.none` for another kind.
    ends: [][2]NetId,
    seen: []u32,
    stamp: u32 = 0,
    walk: std.ArrayList(NetId) = .empty,

    fn init(gpa: Allocator, design: Design) Allocator.Error!Walker {
        const devices = design.devices;
        const ends = try gpa.alloc([2]NetId, devices.len());
        errdefer gpa.free(ends);
        for (ends, 0..) |*e, d| {
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            e.* = if (devices.kind.items[d] == .mos) .{ terminalNet(term.nets, term.roles, .source), terminalNet(term.nets, term.roles, .drain) } else .{ .none, .none };
        }
        const seen = try gpa.alloc(u32, design.nets.netCount());
        @memset(seen, 0);
        return .{ .ends = ends, .seen = seen };
    }

    fn deinit(w: *Walker, gpa: Allocator) void {
        gpa.free(w.ends);
        gpa.free(w.seen);
        w.walk.deinit(gpa);
    }

    /// `from` reaches a power and a ground supply through MOS channels,
    /// never through a device joining `cut`'s two nets.
    fn bothRails(w: *Walker, gpa: Allocator, design: Design, intent: *const IntentMap, from: NetId, cut: [2]NetId) Allocator.Error!bool {
        w.stamp += 1;
        var power = false;
        var ground = false;
        w.walk.clearRetainingCapacity();
        try w.walk.append(gpa, from);
        while (w.walk.pop()) |at| {
            const i = @backingInt(at);
            if (i >= w.seen.len or w.seen[i] == w.stamp) continue;
            w.seen[i] = w.stamp;
            if (intent.supply(at)) |s| {
                switch (s.role) {
                    .power => power = true,
                    .ground => ground = true,
                }
                continue;
            }
            for (design.devices.devicesOn(at)) |other| {
                const a, const b = w.ends[@backingInt(other)];
                if (a == .none or b == .none) continue;
                if ((a == cut[0] and b == cut[1]) or (a == cut[1] and b == cut[0])) continue;
                if (a == at or b == at) try w.walk.append(gpa, if (a == at) b else a);
            }
        }
        return power and ground;
    }

    /// A chain of channels of transistors other than `skip` whose bulk is
    /// `well` joins one of `from` to `well`.
    fn chained(w: *Walker, gpa: Allocator, design: Design, bulk: []const NetId, from: [2]NetId, well: NetId, skip: u32) Allocator.Error!bool {
        w.stamp += 1;
        w.walk.clearRetainingCapacity();
        for (from) |n| if (n != .none) try w.walk.append(gpa, n);
        while (w.walk.pop()) |at| {
            if (at == well) return true;
            const i = @backingInt(at);
            if (i >= w.seen.len or w.seen[i] == w.stamp) continue;
            w.seen[i] = w.stamp;
            for (design.devices.devicesOn(at)) |other_id| {
                const other = @backingInt(other_id);
                const a, const b = w.ends[other];
                if (other == skip or bulk[other] != well or a == .none or b == .none) continue;
                if (a == at or b == at) try w.walk.append(gpa, if (a == at) b else a);
            }
        }
        return false;
    }
};

/// Every MOS of a row's models. `examined` counts the switches. A wiring
/// finding (no joined always-on and switched pair of one role) measures 0
/// against 1; a control finding the states its gate floats in against 0.
/// Skipped without usable intent or without a declared power state.
pub fn checkPowerSwitch(r: Record, design: Design, intent: *const IntentMap, switched: []const NetId, states: []const NetVoltage, t: *const PowerSwitchTable) Allocator.Error!void {
    if (!intent.isUsable() or states.len == 0) return r.skipRows(&t.head);
    const devices = design.devices;
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const before = r.out.len();
        const models = t.model.items[t.model_start.items[row]..t.model_start.items[row + 1]];
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            if (devices.kind.items[d] != .mos or !has(models, devices.model.items[d])) continue;
            examined += 1;
            const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
            const s = terminalNet(term.nets, term.roles, .source);
            const dr = terminalNet(term.nets, term.roles, .drain);
            const gate = terminalNet(term.nets, term.roles, .gate);
            const wired = blk: {
                const a = intent.supply(s) orelse break :blk false;
                const b = intent.supply(dr) orelse break :blk false;
                break :blk a.role == b.role and isOn(switched, s) != isOn(switched, dr);
            };
            if (!wired) try r.deviceViolation(design, @intCast(d), rule, severity, .count(0), .count(1));
            var floats: u32 = 0;
            for (states) |*state| floats += @intFromBool(gate == .none or !state.known(gate));
            if (floats > 0) try r.deviceViolation(design, @intCast(d), rule, severity, .count(floats), .count(0));
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every device of a row's models drawn at most `max_length` long whose
/// two non-supply channel ends each still reach a power and a ground supply
/// with this device (and any device across the same two nets) cut out.
/// `examined` counts the short devices; a finding measures the length
/// against `max_length`. Skipped without a declared supply.
pub fn checkHotCarrier(r: Record, design: Design, intent: *const IntentMap, t: *const HotCarrierTable) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const devices = design.devices;
    var w: Walker = try .init(gpa, design);
    defer w.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.max_length.items, 0..) |rule, severity, limit, row| {
        const before = r.out.len();
        const models = t.model.items[t.model_start.items[row]..t.model_start.items[row + 1]];
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            if (!has(models, devices.model.items[d])) continue;
            const length = lengthOf(devices.paramsOf(@fromBackingInt(@as(u32, @intCast(d))))) orelse continue;
            if (length > limit) continue;
            examined += 1;
            const s, const dr = w.ends[d];
            if (s == .none or dr == .none or s == dr) continue;
            if (intent.supply(s) != null or intent.supply(dr) != null) continue;
            // ponytail: one walk per side of every short device; share walks
            // per cut pair if a large design makes this quadratic.
            if (try w.bothRails(gpa, design, intent, s, .{ s, dr }) and try w.bothRails(gpa, design, intent, dr, .{ s, dr })) {
                try r.deviceViolation(design, @intCast(d), rule, severity, .length(length), .length(limit));
            }
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every MOS of a row's models with a bulk on a net passes when a channel
/// end is on the bulk net, (with `resistors`) a resistor joins an end to it,
/// or a chain of channels of other transistors on the same bulk does.
/// `examined` counts those devices; a finding measures 0 against 1.
pub fn checkWellSharing(r: Record, design: Design, t: *const WellSharingTable) Allocator.Error!void {
    const gpa = r.gpa;
    const devices = design.devices;
    var w: Walker = try .init(gpa, design);
    defer w.deinit(gpa);
    const bulk = try gpa.alloc(NetId, devices.len());
    defer gpa.free(bulk);
    for (bulk, 0..) |*b, d| {
        const term = devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d))));
        b.* = if (devices.kind.items[d] == .mos) terminalNet(term.nets, term.roles, .bulk) else .none;
    }
    for (t.head.rule.items, t.head.severity.items, t.resistors.items, 0..) |rule, severity, resistors, row| {
        const before = r.out.len();
        const models = t.model.items[t.model_start.items[row]..t.model_start.items[row + 1]];
        var examined: u64 = 0;
        for (0..devices.len()) |d| {
            const well = bulk[d];
            if (well == .none or !has(models, devices.model.items[d])) continue;
            examined += 1;
            const channel = w.ends[d];
            const on = (channel[0] != .none and channel[0] == well) or (channel[1] != .none and channel[1] == well);
            const through = resistors and ((channel[0] != .none and resistorBetween(design, channel[0], well)) or (channel[1] != .none and resistorBetween(design, channel[1], well)));
            if (on or through or try w.chained(gpa, design, bulk, channel, well, @intCast(d))) continue;
            try r.deviceViolation(design, @intCast(d), rule, severity, .count(0), .count(1));
        }
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

fn has(models: []const StrId, model: StrId) bool {
    return std.mem.indexOfScalar(StrId, models, model) != null;
}

/// The net is not switched off by any power state.
fn isOn(switched: []const NetId, net: NetId) bool {
    return std.sort.binarySearch(NetId, switched, net, struct {
        fn order(a: NetId, b: NetId) std.math.Order {
            return std.math.order(@backingInt(a), @backingInt(b));
        }
    }.order) == null;
}

/// The device's first measured length.
fn lengthOf(params: device_.Params) ?Dbu {
    for (params.names, params.measures) |name, m| if (name == .length) switch (m) {
        .length => |l| return l,
        .area, .count, .area_share, .length_share => {},
    };
    return null;
}

/// A two-pin resistor joins `a` and `b`.
fn resistorBetween(design: Design, a: NetId, b: NetId) bool {
    const devices = design.devices;
    for (devices.devicesOn(a)) |other| {
        if (devices.kind.items[@backingInt(other)] != .resistor) continue;
        const nets = devices.terminalsOf(other).nets;
        if (nets.len == 2 and ((nets[0] == a and nets[1] == b) or (nets[0] == b and nets[1] == a))) return true;
    }
    return false;
}
