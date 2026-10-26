//! Black boxes on the layout side (catalog LVS-033, LVS-067): each
//! placement of a cell the deck's `lvs blackbox` names becomes one device of
//! kind `cell` on its pins' nets, and the devices drawn inside it leave the
//! comparison, as KLayout's `blank_circuit` and Netgen's `model ...
//! blackbox` compare a cell by its pins alone. In: the layout graph, the
//! design it came from, the placements and their bound pins, the port names
//! the reference kept for each such cell. Out: the graph rewritten in
//! place. Ported from crates/check/src/lvs/blackbox.rs.
//!
//! Contents:
//! - `pub const Boxes = struct`, `pub const BoxPorts = struct`, `pub const Error`
//! - `pub fn addBlackBoxes(gpa: Allocator, layout: *Graph, design: Design, boxes: Boxes, ports: BoxPorts, strings: *const StrTable, bad_cell: *StrId) (Error || Allocator.Error)!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const BoxPin = @import("ingest").provenance.BoxPin;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Design = @import("project.zig").Design;
const retainDevices = @import("retain.zig").retainDevices;

/// The layout's black boxes: placement `i` is `cell[i]` over `extent[i]`,
/// and `pins` the pins label resolution bound (`Provenance`'s columns).
pub const Boxes = struct { cell: []const StrId, extent: []const Bbox, pins: []const BoxPin };

/// The ports the reference states for each cell it kept whole, CSR
/// (`Netlist.black_box_*`).
pub const BoxPorts = struct { cell: []const StrId = &.{}, port_start: []const u32 = &.{}, port: []const StrId = &.{} };

pub const Error = error{
    /// A box whose pins need a position past 255 (`bad_cell` names its
    /// cell), which a device's pin role cannot hold.
    TooManyPins,
};

/// Replaces what each black box holds with one `cell` device whose model is
/// the cell's name: every device whose marker lies wholly inside a box's
/// extent is dropped, with the nets only such devices reached that are no
/// port; each box gets one terminal per distinct `(pin name, net)`, role
/// `pin = k` with `k` the name's position among the reference's ports for
/// the cell, a name it does not state past them in name order. The box's
/// own wiring stays in the nets as drawn.
pub fn addBlackBoxes(gpa: Allocator, layout: *Graph, design: Design, boxes: Boxes, ports: BoxPorts, strings: *const StrTable, bad_cell: *StrId) (Error || Allocator.Error)!void {
    if (boxes.cell.len == 0) return;
    const drawn = layout.deviceCount();
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(gpa);
    for (0..drawn) |d| {
        const extent = design.store.polyBbox(design.devices.marker.items[d]);
        const inside = for (boxes.extent) |e| (if (e.contains(extent)) break true) else false;
        if (!inside) try kept.append(gpa, @intCast(d));
    }
    for (0..boxes.cell.len) |b| try kept.append(gpa, drawn + @as(u32, @intCast(b)));

    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(gpa);
    var terminals: std.ArrayList([2]u32) = .empty;
    defer terminals.deinit(gpa);
    for (boxes.cell, 0..) |cell, at| {
        const stated = statedPorts(ports, cell);
        extra.clearRetainingCapacity();
        for (boxes.pins) |p| {
            if (p.box == at and std.mem.indexOfScalar(StrId, stated, p.name) == null) try extra.append(gpa, strings.resolve(p.name));
        }
        std.mem.sortUnstable([]const u8, extra.items, {}, lessText);
        var unique: usize = 0;
        for (extra.items) |t| {
            if (unique > 0 and std.mem.eql(u8, extra.items[unique - 1], t)) continue;
            extra.items[unique] = t;
            unique += 1;
        }
        extra.shrinkRetainingCapacity(unique);
        terminals.clearRetainingCapacity();
        for (boxes.pins) |p| {
            if (p.box != at) continue;
            const position = std.mem.indexOfScalar(StrId, stated, p.name) orelse
                stated.len + (rankOf(extra.items, strings.resolve(p.name)) orelse 0);
            if (position > std.math.maxInt(u8)) {
                bad_cell.* = cell;
                return error.TooManyPins;
            }
            try terminals.append(gpa, .{ @intCast(position), @backingInt(design.nets.netOf(p.poly)) });
        }
        std.mem.sortUnstable([2]u32, terminals.items, {}, lessPair);
        try layout.device_kind.append(gpa, .cell);
        try layout.device_model.append(gpa, cell);
        for (terminals.items, 0..) |t, i| {
            if (i > 0 and terminals.items[i - 1][0] == t[0] and terminals.items[i - 1][1] == t[1]) continue;
            try layout.terminal_net.append(gpa, t[1]);
            try layout.terminal_role.append(gpa, .{ .pin = @intCast(t[0]) });
        }
        try layout.device_terminal_start.append(gpa, @intCast(layout.terminal_net.items.len));
        try layout.device_param_start.append(gpa, @intCast(layout.param.items.len));
    }
    try graph.transposeInto(gpa, layout, layout.netCount());
    try retainDevices(gpa, layout, kept.items);
}

// ---- private ----

fn statedPorts(ports: BoxPorts, cell: StrId) []const StrId {
    for (ports.cell, 0..) |c, row| if (c == cell) return ports.port[ports.port_start[row]..ports.port_start[row + 1]];
    return &.{};
}

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
    return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
}

fn rankOf(sorted: []const []const u8, text: []const u8) ?usize {
    for (sorted, 0..) |t, at| if (std.mem.eql(u8, t, text)) return at;
    return null;
}
