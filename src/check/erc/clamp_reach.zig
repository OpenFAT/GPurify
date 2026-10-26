//! Which supplies a pad reaches through clamp devices: the walk the ESD,
//! reliability and supply kinds share. In: the design, the intent's
//! supplies, a clamp model list, a pad net. Out: the nets reached (pad
//! first, then each declared supply in visit order), how many of the two
//! rail kinds they cover, and whether a diode clamp is wired to conduct
//! only under stress. Ported from crates/check/src/erc/rules/supply.rs
//! (`clamp_rails`, `clamp_reach_into`, `reverse_biased`).
//!
//! Contents:
//! - `pub const Walk = struct`, `deinit`
//! - `pub fn clampRails(gpa: Allocator, design: Design, intent: *const IntentMap, clamps: []const StrId, pad: NetId, walk: *Walk) Allocator.Error!u32`
//! - `pub fn clampReachInto(gpa: Allocator, design: Design, intent: *const IntentMap, clamps: []const StrId, pad: NetId, walk: *Walk) Allocator.Error!void`
//! - `pub fn reverseBiased(design: Design, intent: *const IntentMap, device: DeviceId) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const NetId = @import("../topology/net.zig").NetId;
const DeviceId = @import("../topology/device.zig").DeviceId;
const Design = @import("head.zig").Design;
const IntentMap = @import("facts.zig").IntentMap;

/// The walk's scratch and result: `seen` per net, the stack, and the nets
/// reached.
pub const Walk = struct {
    seen: std.ArrayList(bool) = .empty,
    stack: std.ArrayList(NetId) = .empty,
    reached: std.ArrayList(NetId) = .empty,

    pub fn deinit(w: *Walk, gpa: Allocator) void {
        w.seen.deinit(gpa);
        w.stack.deinit(gpa);
        w.reached.deinit(gpa);
    }
};

/// How many of the two rail kinds (power, ground) `pad` reaches through
/// devices of the `clamps` models.
pub fn clampRails(gpa: Allocator, design: Design, intent: *const IntentMap, clamps: []const StrId, pad: NetId, walk: *Walk) Allocator.Error!u32 {
    try clampReachInto(gpa, design, intent, clamps, pad, walk);
    var power = false;
    var ground = false;
    for (walk.reached.items) |net| if (intent.supply(net)) |s| switch (s.role) {
        .power => power = true,
        .ground => ground = true,
    };
    return @as(u32, @intFromBool(power)) + @intFromBool(ground);
}

/// Every net `pad` reaches through devices of the `clamps` models, into
/// `walk.reached`: `pad` first, then each declared supply in visit order.
/// The path is a clamp from the pad to a supply, then any chain of clamps
/// between supplies (rail clamps); another signal net is not a path, and a
/// diode clamp wired forward-biased carries nothing (`reverseBiased`).
pub fn clampReachInto(gpa: Allocator, design: Design, intent: *const IntentMap, clamps: []const StrId, pad: NetId, walk: *Walk) Allocator.Error!void {
    const devices = design.devices;
    // ponytail: O(nets) reset per pad net; pads are few.
    walk.seen.clearRetainingCapacity();
    try walk.seen.appendNTimes(gpa, false, design.nets.netCount());
    walk.stack.clearRetainingCapacity();
    walk.reached.clearRetainingCapacity();
    try walk.stack.append(gpa, pad);
    walk.seen.items[@backingInt(pad)] = true;
    while (walk.stack.pop()) |net| {
        if (net != pad and intent.supply(net) == null) continue;
        try walk.reached.append(gpa, net);
        for (devices.devicesOn(net)) |d| {
            const model = devices.model.items[@backingInt(d)];
            if (std.mem.indexOfScalar(StrId, clamps, model) == null or !reverseBiased(design, intent, d)) continue;
            for (devices.terminalsOf(d).nets) |next| {
                if (next == .none or walk.seen.items[@backingInt(next)]) continue;
                walk.seen.items[@backingInt(next)] = true;
                try walk.stack.append(gpa, next);
            }
        }
    }
}

/// False for a pad diode its declared supplies forward-bias, which conducts
/// in operation and is no clamp: a diode between a supply and another net
/// whose anode (pin 0) sits above its cathode (pin 1), the other net between
/// ground and every power supply; so an anode on a power supply, or a
/// cathode on a ground supply, is wired the wrong way round. A diode between
/// two supplies, between two other nets, and any non-diode, count as wired.
pub fn reverseBiased(design: Design, intent: *const IntentMap, device: DeviceId) bool {
    const devices = design.devices;
    if (devices.kind.items[@backingInt(device)] != .diode) return true;
    const t = devices.terminalsOf(device);
    const anode = pinVolts(intent, t.nets, t.roles, 0);
    const cathode = pinVolts(intent, t.nets, t.roles, 1);
    const a = anode orelse return true;
    const c = cathode orelse return true;
    if (a != null and c == null) return a.? <= 0.0;
    if (a == null and c != null) return c.? > 0.0;
    return true;
}

// ---- private ----

/// Pin `k`'s supply voltage: null when the device has no pin `k`, a null
/// voltage when the pin's net is no supply.
fn pinVolts(intent: *const IntentMap, nets: []const NetId, roles: anytype, k: u8) ??f64 {
    for (nets, roles) |net, role| switch (role) {
        .pin => |p| if (p == k) {
            // Typed first: a bare `null` would coerce to the outer null,
            // "no such pin", and pass a forward-biased diode as a clamp.
            const volts: ?f64 = if (intent.nominalVoltage(net)) |v| v.raw else null;
            return volts;
        },
        else => {},
    };
    return null;
}
