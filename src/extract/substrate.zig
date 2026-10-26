//! Substrate resistance network (catalog PEX-013): the resistive coupling
//! through the silicon between the nets that touch it, the taps and wells,
//! and from each to the backside. In: the network, the layout and its
//! per-polygon net column, the deck's `pex_substrate` profile and port
//! layers, the die's extent. Out: `substrate_resistance` elements between
//! the port nets' first nodes and from each to ground. Ported from
//! crates/extract/src/substrate.rs (`add_into`, the model and its limits);
//! the solve is substrate_solve.zig.
//!
//! A port is every shape on the port layers, grouped by net: each net's
//! shapes are one equipotential contact on the silicon's top face. The rest
//! of the top face and the die's sides carry no current. The network
//! written is `Y` as resistors: `R_pq = −1/Y_pq` between two ports and
//! `1/Σ_q Y_pq` to a grounded backside. Resistive and quasi-static only: no
//! substrate capacitance, no well junction or depth, no lateral doping, no
//! contact resistance; the current crowding at a contact's edge is resolved
//! to the grid, which at `level` reads a 1 µm contact 1.4 % low.
//!
//! Contents:
//! - `pub const Profile`, `Backside`, `Lines`, `Admittance`, `Error`, `Refusal`, `max_lines`, `no_port`, `linesInto`, `admittanceInto` (substrate_solve.zig)
//! - `pub const level: u32`
//! - `pub fn addInto(gpa: Allocator, threads: u16, network: *ParasiticNetwork, store: *const GeometryStore, poly_net: []const u32, profile: Profile, port_layers: []const LayerId, domain: Bbox, grid: Grid, refusal: *Refusal) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Grid = geom.Grid;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const none = @import("stack.zig").none;
const network_mod = @import("network.zig");
const NodeId = network_mod.NodeId;
const ParasiticNetwork = network_mod.ParasiticNetwork;
const solve = @import("substrate_solve.zig");

pub const Profile = solve.Profile;
pub const Backside = solve.Backside;
pub const Lines = solve.Lines;
pub const Admittance = solve.Admittance;
pub const Error = solve.Error;
pub const Refusal = solve.Refusal;
pub const max_lines = solve.max_lines;
pub const no_port = solve.no_port;
pub const linesInto = solve.linesInto;
pub const admittanceInto = solve.admittanceInto;

/// The refinement level the engine extracts at.
pub const level: u32 = 2;

/// One port shape: its net and row.
const Shape = struct {
    net: u32,
    poly: PolyId,

    fn less(_: void, a: Shape, b: Shape) bool {
        return a.net < b.net or (a.net == b.net and @backingInt(a.poly) < @backingInt(b.poly));
    }
};

/// Solves every net's shapes on `port_layers` under `domain` and appends
/// the network as resistors between the nets' first nodes and from each to
/// ground (a grounded backside only), then restores canonical order. A shape
/// on no net, or on a net with no node, is no port. Errors: as
/// `linesInto` and `admittanceInto`.
pub fn addInto(gpa: Allocator, threads: u16, network: *ParasiticNetwork, store: *const GeometryStore, poly_net: []const u32, profile: Profile, port_layers: []const LayerId, domain: Bbox, grid: Grid, refusal: *Refusal) Error!void {
    assert(poly_net.len == store.polyCount());
    var shapes: std.ArrayList(Shape) = .empty;
    defer shapes.deinit(gpa);
    for (port_layers) |layer| {
        const on = store.polysOnLayer(layer);
        for (on.start..on.end) |row| {
            const net = poly_net[row];
            if (net == none or network.firstNode(net) == null) continue;
            try shapes.append(gpa, .{ .net = net, .poly = @fromBackingInt(@intCast(row)) });
        }
    }
    if (shapes.items.len == 0) return;
    std.mem.sortUnstable(Shape, shapes.items, {}, Shape.less);
    // Each shape's port: its net's rank among the port nets.
    const port = try gpa.alloc(u32, shapes.items.len);
    defer gpa.free(port);
    var nodes: std.ArrayList(NodeId) = .empty;
    defer nodes.deinit(gpa);
    for (shapes.items, port, 0..) |s, *p, k| {
        if (k == 0 or shapes.items[k - 1].net != s.net) try nodes.append(gpa, network.firstNode(s.net).?);
        p.* = @intCast(nodes.items.len - 1);
    }
    const per_um: f64 = @floatFromInt(grid.dbu_per_um);
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(gpa);
    for (shapes.items) |s| {
        const ring = store.polyVerts(s.poly);
        for (ring.xs, ring.ys) |x, y| {
            try xs.append(gpa, @as(f64, @floatFromInt(x)) / per_um);
            try ys.append(gpa, @as(f64, @floatFromInt(y)) / per_um);
        }
    }
    const um = [4]f64{ @as(f64, @floatFromInt(domain.xlo)) / per_um, @as(f64, @floatFromInt(domain.ylo)) / per_um, @as(f64, @floatFromInt(domain.xhi)) / per_um, @as(f64, @floatFromInt(domain.yhi)) / per_um };
    var lines: Lines = .empty;
    defer lines.deinit(gpa);
    try linesInto(gpa, profile, um, xs.items, ys.items, level, &lines, refusal);
    // The port covering each top-face node, the first in net then row order.
    // ponytail: a linear scan per top-face node; index the shapes when port counts grow past thousands.
    const ny = lines.y.items.len;
    const held = try gpa.alloc(u32, lines.x.items.len * ny);
    defer gpa.free(held);
    for (lines.x.items, 0..) |x, i| {
        for (lines.y.items, 0..) |y, j| {
            const point: geom.Point = .{ .x = @intFromFloat(@round(x * per_um)), .y = @intFromFloat(@round(y * per_um)) };
            held[i * ny + j] = for (shapes.items, port) |s, p| {
                const b = store.polyBbox(s.poly);
                if (b.xlo <= point.x and point.x <= b.xhi and b.ylo <= point.y and point.y <= b.yhi and store.polyContainsPoint(s.poly, point)) break p;
            } else no_port;
        }
    }
    const count: u32 = @intCast(nodes.items.len);
    var solved: Admittance = .empty;
    defer solved.deinit(gpa);
    try admittanceInto(gpa, threads, profile, &lines, held, count, &solved);
    for (0..count) |p| {
        for (p + 1..count) |q| {
            const g = solved.between(p, q);
            if (g > 0.0) try network.push(gpa, nodes.items[p], nodes.items[q], .substrate_resistance, 1.0 / g);
        }
        // A floating backside leaves a rounding residue, not a path.
        const g = solved.toBackside(p);
        if (profile.backside == .grounded and g > 0.0) try network.push(gpa, nodes.items[p], .ground, .substrate_resistance, 1.0 / g);
    }
    try network.sortCanonical(gpa);
}
