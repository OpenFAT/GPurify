//! Point-to-point resistance and net-to-net coupling between nets a user
//! names (catalog PEX-016): what a PEX run's text report prints for the
//! deck's `report p2p` and `report coupling` lines. Ported from
//! src/engine/p2p.rs.
//!
//! Point to point: between points on one net, the effective resistance of
//! the net's resistor network between each pair (every conducting shape a
//! chain of `sheet · ∫ ds / w(s)`, each via cut its layer's resistance per
//! cut, the points tapped where they lie: ERC's `p2p_resistance` model,
//! `erc.power_nets.extractPointsInto`), as Calibre PERC's P2P and Voltus
//! report it; a parallel strap can only lower it. Net to net: the sum of
//! every coupling element between a node of one net and a node of the other.
//!
//! Contents:
//! - `pub const Pair = struct { i: u32, j: u32, ohms: f64 }`, `pub const Error`
//! - `pub fn resistanceInto(scratch: Allocator, arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, name: []const u8, points: []const [2]Dbu, out: *std.ArrayList(Pair), why: *[]const u8) Error!void`
//! - `pub fn coupling(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, network: *const ParasiticNetwork, a: []const u8, b: []const u8, why: *[]const u8) Error!f64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Point = geom.Point;
const check = @import("check");
const erc = check.erc;
const NetId = check.topology.NetId;
const ParasiticNetwork = @import("extract").network.ParasiticNetwork;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;

/// The resistance between points `i < j`, in the order given.
pub const Pair = struct { i: u32, j: u32, ohms: f64 };

/// `Refused`, with `why` in the arena: no net or several of the name, a
/// point on none of its conducting shapes, or a layer with no resistance.
pub const Error = error{Refused} || Allocator.Error;

/// The resistance between every two of `points` on the net `name`, into
/// `out` (appended); a pair the net does not join is absent.
pub fn resistanceInto(scratch: Allocator, arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, name: []const u8, points: []const [2]Dbu, out: *std.ArrayList(Pair), why: *[]const u8) Error!void {
    const net = try netNamed(arena, loaded, extracted, name, why);
    const at = try scratch.alloc(Point, points.len);
    for (points, at) |p, *a| a.* = .{ .x = p[0], .y = p[1] };
    const deck = &loaded.deck.deck;
    const process: erc.power_grid.Process = .{ .grid = loaded.grid, .stack = &deck.stack, .connectivity = &deck.connectivity };
    var networks: erc.power_grid.NetNetworks = .{};
    var nodes: std.ArrayList(u32) = .empty;
    var diag: erc.power_grid.PowerDiag = .{};
    erc.power_nets.extractPointsInto(scratch, &loaded.store, &extracted.nets, process, net, at, &networks, &nodes, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotOnNet => {
            const per_um: f64 = @floatFromInt(loaded.grid.dbu_per_um);
            const p = points[diag.at];
            why.* = try std.fmt.allocPrint(arena, "point ({d}, {d}) µm lies on no conducting shape of {s}", .{ @as(f64, @floatFromInt(p[0])) / per_um, @as(f64, @floatFromInt(p[1])) / per_um, name });
            return error.Refused;
        },
        else => |e| return refuse(arena, why, e, diag),
    };
    var probes: std.ArrayList(erc.power_probe.Probe) = .empty;
    var probe_scratch: erc.power_probe.ProbeScratch = .{};
    erc.power_probe.effectiveResistanceInto(scratch, &networks, 0, &probe_scratch, &probes, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return refuse(arena, why, e, diag),
    };
    const n = nodes.items;
    for (0..n.len) |i| for (i + 1..n.len) |j| {
        const a = @min(n[i], n[j]);
        const b = @max(n[i], n[j]);
        if (a == b) {
            try out.append(arena, .{ .i = @intCast(i), .j = @intCast(j), .ohms = 0 });
            continue;
        }
        for (probes.items) |pr| if (pr.a == a and pr.b == b) {
            try out.append(arena, .{ .i = @intCast(i), .j = @intCast(j), .ohms = pr.ohms.raw });
            break;
        };
    };
}

/// The total coupling capacitance in fF between the nets `a` and `b`.
pub fn coupling(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, network: *const ParasiticNetwork, a: []const u8, b: []const u8, why: *[]const u8) Error!f64 {
    const na = @backingInt(try netNamed(arena, loaded, extracted, a, why));
    const nb = @backingInt(try netNamed(arena, loaded, extracted, b, why));
    // From +0.0: an uncoupled pair must not print as "-0.000000".
    var total: f64 = 0.0;
    for (network.from.items, network.to.items, network.kind.items, network.value.items) |from, to, k, q| {
        if (k != .coupling_cap or to == .ground) continue;
        const p = .{ network.node_net.items[@backingInt(from)], network.node_net.items[@backingInt(to)] };
        if ((p[0] == na and p[1] == nb) or (p[0] == nb and p[1] == na)) total += q;
    }
    return total;
}

// ---- private ----

/// The one net `name` labels, or `Refused` saying why there is none.
fn netNamed(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, name: []const u8, why: *[]const u8) Error!NetId {
    const pieces = if (loaded.strings.get(name)) |id| extracted.ports.netsOf(id) else &.{};
    switch (pieces.len) {
        1 => return pieces[0],
        0 => why.* = try std.fmt.allocPrint(arena, "no net is named {s}", .{name}),
        else => why.* = try std.fmt.allocPrint(arena, "{s} labels {d} disconnected nets, an open", .{ name, pieces.len }),
    }
    return error.Refused;
}

fn refuse(arena: Allocator, why: *[]const u8, err: erc.power_grid.PowerError, diag: erc.power_grid.PowerDiag) Error {
    why.* = try std.fmt.allocPrint(arena, "{t} at {d}", .{ err, diag.at });
    return error.Refused;
}
