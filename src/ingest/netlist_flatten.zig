//! A hierarchical `Netlist` and a top → one flat subcircuit holding every
//! leaf device, wired as the hierarchy wires it: the top's nets, then each
//! instance's inner nets under the instance path (`X1.X2.n1`), and each
//! placement recorded. Cycles, chains past the depth cap and results past
//! the flat cap are refused by counting first, before anything is expanded.
//! A subcircuit matching a black-box glob stays one `cell` device on its
//! ports (catalog LVS-033). Ported from crates/ingest/src/netlist.rs
//! (`flatten_top`, `flatten_top_with`, `flat_size`, `flat_below`, `expand`,
//! `keep_whole`, `Hierarchy`, `group`).
//!
//! Contents:
//! - `pub fn flattenTop(gpa: Allocator, n: *const Netlist, top: SubcktId, strings: *StrTable, diag: *Diagnostic) Error!Netlist`
//! - `pub fn flattenTopWith(gpa: Allocator, n: *const Netlist, top: SubcktId, black_boxes: []const []const u8, strings: *StrTable, diag: *Diagnostic) Error!Netlist`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const netlist = @import("netlist.zig");
const Netlist = netlist.Netlist;
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;
const SubcktId = netlist.SubcktId;
const RefNetId = netlist.RefNetId;
const globMatches = @import("glob.zig").globMatches;

/// What both walks read per subcircuit, indexed once: its instances in file
/// order and its nets in row order (CSR), and whether each net is a port.
const Hierarchy = struct {
    instance_start: []u32,
    instance: []u32,
    net_start: []u32,
    net: []u32,
    on_port: []bool,
    /// Per subcircuit, whether its instances are kept whole; empty for none.
    kept: std.ArrayList(bool) = .empty,

    fn of(gpa: Allocator, n: *const Netlist) Allocator.Error!Hierarchy {
        const cells = n.subcktCount();
        const instances = try group(gpa, n.instance_subckt.items, cells);
        errdefer gpa.free(instances[0]);
        errdefer gpa.free(instances[1]);
        const nets = try group(gpa, n.net_subckt.items, cells);
        errdefer gpa.free(nets[0]);
        errdefer gpa.free(nets[1]);
        const on_port = try gpa.alloc(bool, n.net_name.items.len);
        @memset(on_port, false);
        for (n.port_net.items) |p| on_port[@backingInt(p)] = true;
        return .{ .instance_start = instances[0], .instance = instances[1], .net_start = nets[0], .net = nets[1], .on_port = on_port };
    }

    fn deinit(h: *Hierarchy, gpa: Allocator) void {
        gpa.free(h.instance_start);
        gpa.free(h.instance);
        gpa.free(h.net_start);
        gpa.free(h.net);
        gpa.free(h.on_port);
        h.kept.deinit(gpa);
    }

    fn isKept(h: *const Hierarchy, cell: SubcktId) bool {
        const i = @backingInt(cell);
        return i < h.kept.items.len and h.kept.items[i];
    }

    fn instancesOf(h: *const Hierarchy, cell: SubcktId) []const u32 {
        const i = @backingInt(cell);
        return h.instance[h.instance_start[i]..h.instance_start[i + 1]];
    }

    fn netsOf(h: *const Hierarchy, cell: SubcktId) []const u32 {
        const i = @backingInt(cell);
        return h.net[h.net_start[i]..h.net_start[i + 1]];
    }
};

const Count = struct { count: u64, levels: u32 };

/// The counting walk's tables.
const Walk = struct {
    n: *const Netlist,
    h: *const Hierarchy,
    inner: []const u64,
    strings: *const StrTable,
    diag: *Diagnostic,
    counted: []?Count,
    on_chain: []bool,

    /// The devices and instances below one placement of `cell`, `depth`
    /// levels down (the top is 1), each instance with the nets it adds; and
    /// the levels `cell` spans. Memoised, so a cell counted shallow and met
    /// deep is held to the cap as walking it again would be. Refuses a cycle
    /// and a chain past the cap, so `expand` meets neither; recursion depth
    /// is bounded by the cap.
    fn flatBelow(w: Walk, cell: SubcktId, depth: u32) Error!Count {
        const row = @backingInt(cell);
        if (w.counted[row]) |c| {
            if (depth + c.levels - 1 > netlist.max_hierarchy_depth) return w.named(error.TooDeep, cell);
            return c;
        }
        if (w.on_chain[row]) return w.named(error.CyclicHierarchy, cell);
        if (depth > netlist.max_hierarchy_depth) return w.named(error.TooDeep, cell);
        w.on_chain[row] = true;
        const devices = w.n.devicesOf(cell);
        var count: u64 = devices[1] - devices[0];
        var levels: u32 = 1;
        for (w.h.instancesOf(cell)) |instance| {
            const callee = w.n.instance_of.items[instance];
            if (w.h.isKept(callee)) {
                const ports: u32 = @intCast(w.n.portsOf(callee).len);
                if (ports > netlist.max_cell_pins) {
                    w.diag.got = ports;
                    return w.named(error.TooManyPins, callee);
                }
                count +|= 1;
                continue;
            }
            const below = try w.flatBelow(callee, depth + 1);
            count = count +| (1 +| w.inner[@backingInt(callee)]) +| below.count;
            levels = @max(levels, below.levels + 1);
        }
        w.on_chain[row] = false;
        w.counted[row] = .{ .count = count, .levels = levels };
        return .{ .count = count, .levels = levels };
    }

    fn named(w: Walk, err: Error, cell: SubcktId) Error {
        w.diag.set(0, "{s}", .{w.strings.resolve(w.n.subckt_name.items[@backingInt(cell)])});
        return err;
    }
};

/// `top` with every instance below it expanded; see `flattenTopWith`.
pub fn flattenTop(gpa: Allocator, n: *const Netlist, top: SubcktId, strings: *StrTable, diag: *Diagnostic) Error!Netlist {
    return flattenTopWith(gpa, n, top, &.{}, strings, diag);
}

/// `top` flattened, every instance of a subcircuit whose name matches one
/// of `black_boxes` kept whole as one `cell` device, its model the
/// subcircuit's name and its terminals the instance's nets in port order.
/// `CyclicHierarchy`, `TooDeep`, `TooManyPins` and `TooLarge` are found by
/// counting before anything is expanded. Linear in the netlist and in what
/// the expansion produces. Asserts `top` is a row.
pub fn flattenTopWith(gpa: Allocator, n: *const Netlist, top: SubcktId, black_boxes: []const []const u8, strings: *StrTable, diag: *Diagnostic) Error!Netlist {
    std.debug.assert(@backingInt(top) < n.subcktCount());
    var h = try Hierarchy.of(gpa, n);
    defer h.deinit(gpa);
    if (black_boxes.len > 0) {
        try h.kept.resize(gpa, n.subcktCount());
        for (n.subckt_name.items, h.kept.items) |name, *kept| {
            kept.* = for (black_boxes) |pattern| {
                if (globMatches(pattern, strings.resolve(name))) break true;
            } else false;
        }
    }
    const size = try flatSize(gpa, n, top, &h, strings, diag);
    if (size > netlist.max_flat_elements) {
        diag.count = size;
        return error.TooLarge;
    }
    var out: Netlist = .{};
    errdefer out.deinit(gpa);
    try out.subckt_name.append(gpa, n.subckt_name.items[@backingInt(top)]);
    try out.subckt_port_start.append(gpa, 0);
    try out.subckt_device_start.append(gpa, 0);
    try out.device_terminal_start.append(gpa, 0);
    try out.device_param_start.append(gpa, 0);
    // The caller's nets for `top`: its own, under their own names.
    const map = try gpa.alloc(u32, n.net_name.items.len);
    defer gpa.free(map);
    @memset(map, std.math.maxInt(u32));
    for (h.netsOf(top)) |net| {
        map[net] = @intCast(out.net_name.items.len);
        try out.net_name.append(gpa, n.net_name.items[net]);
        try out.net_subckt.append(gpa, @fromBackingInt(0));
    }
    for (n.portsOf(top)) |port| try out.port_net.append(gpa, @fromBackingInt(map[@backingInt(port)]));
    try out.subckt_port_start.append(gpa, @intCast(out.port_net.items.len));
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    try expand(gpa, n, top, &h, map, &path, strings, &out);
    try out.subckt_device_start.append(gpa, @intCast(out.device_model.items.len));
    return out;
}

// ---- private ----

/// The rows of `owner` grouped by the subcircuit each names, ascending
/// within a group: a CSR start column and the rows.
fn group(gpa: Allocator, owner: []const SubcktId, cells: u32) Allocator.Error![2][]u32 {
    const start = try gpa.alloc(u32, cells + 1);
    errdefer gpa.free(start);
    @memset(start, 0);
    for (owner) |c| start[@backingInt(c) + 1] += 1;
    for (1..start.len) |at| start[at] += start[at - 1];
    const next = try gpa.dupe(u32, start);
    defer gpa.free(next);
    const rows = try gpa.alloc(u32, owner.len);
    for (owner, 0..) |c, row| {
        const at = &next[@backingInt(c)];
        rows[at.*] = @intCast(row);
        at.* += 1;
    }
    return .{ start, rows };
}

/// What flattening `top` produces, counted from the tables: devices, nets
/// and instances all the way down, saturating.
fn flatSize(gpa: Allocator, n: *const Netlist, top: SubcktId, h: *const Hierarchy, strings: *const StrTable, diag: *Diagnostic) Error!u64 {
    const cells = n.subcktCount();
    const inner = try gpa.alloc(u64, cells);
    defer gpa.free(inner);
    for (inner, 0..) |*count, cell| {
        count.* = 0;
        for (h.netsOf(@fromBackingInt(@as(u32, @intCast(cell))))) |net| count.* += @intFromBool(!h.on_port[net]);
    }
    const counted = try gpa.alloc(?Count, cells);
    defer gpa.free(counted);
    @memset(counted, null);
    const on_chain = try gpa.alloc(bool, cells);
    defer gpa.free(on_chain);
    @memset(on_chain, false);
    const walk: Walk = .{ .n = n, .h = h, .inner = inner, .strings = strings, .diag = diag, .counted = counted, .on_chain = on_chain };
    const below = try walk.flatBelow(top, 1);
    return std.math.add(u64, h.netsOf(top).len, below.count) catch std.math.maxInt(u64);
}

/// Appends `cell`'s devices on nets mapped by `map`, then each instance in
/// it, recursively, under `path`. An instance writes only its callee's rows
/// of `map`, and no subcircuit is on the chain twice, so one map serves
/// every placement. Recursion depth is bounded by `flatSize`'s depth cap.
fn expand(gpa: Allocator, n: *const Netlist, cell: SubcktId, h: *const Hierarchy, map: []u32, path: *std.ArrayList(u8), strings: *StrTable, out: *Netlist) Error!void {
    const devices = n.devicesOf(cell);
    for (devices[0]..devices[1]) |device| {
        const d: u32 = @intCast(device);
        try out.device_model.append(gpa, n.device_model.items[d]);
        try out.device_kind.append(gpa, n.device_kind.items[d]);
        try out.device_name.append(gpa, n.device_name.items[d]);
        for (n.terminalsOf(d)) |net| try out.terminal_net.append(gpa, @fromBackingInt(map[@backingInt(net)]));
        try out.device_terminal_start.append(gpa, @intCast(out.terminal_net.items.len));
        try out.param.appendSlice(gpa, n.paramsOf(d));
        try out.device_param_start.append(gpa, @intCast(out.param.items.len));
    }
    for (h.instancesOf(cell)) |instance| {
        const callee = n.instance_of.items[instance];
        const mark = path.items.len;
        defer path.shrinkRetainingCapacity(mark);
        if (mark > 0) try path.append(gpa, '.');
        try path.appendSlice(gpa, strings.resolve(n.instance_name.items[instance]));
        const passed = n.instance_net.items[n.instance_net_start.items[instance]..n.instance_net_start.items[instance + 1]];
        if (h.isKept(callee)) {
            const first: u32 = @intCast(out.device_model.items.len);
            try out.placements.append(gpa, .{ .path = try strings.intern(gpa, path.items), .cell = n.subckt_name.items[@backingInt(callee)], .devices = .{ first, first + 1 } });
            try keepWhole(gpa, n, callee, n.instance_name.items[instance], passed, map, out);
            continue;
        }
        // Ports first: each takes the caller's net the instance passes.
        for (n.portsOf(callee), passed) |port, net| map[@backingInt(port)] = map[@backingInt(net)];
        // Every other net of the callee is new, named under the path.
        for (h.netsOf(callee)) |net| {
            if (h.on_port[net]) continue;
            map[net] = @intCast(out.net_name.items.len);
            const named = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path.items, strings.resolve(n.net_name.items[net]) });
            defer gpa.free(named);
            try out.net_name.append(gpa, try strings.intern(gpa, named));
            try out.net_subckt.append(gpa, @fromBackingInt(0));
        }
        const at = out.placements.items.len;
        const first: u32 = @intCast(out.device_model.items.len);
        try out.placements.append(gpa, .{ .path = try strings.intern(gpa, path.items), .cell = n.subckt_name.items[@backingInt(callee)], .devices = .{ first, first } });
        try expand(gpa, n, callee, h, map, path, strings, out);
        out.placements.items[at].devices[1] = @intCast(out.device_model.items.len);
    }
}

/// One placement of `cell` kept whole: a `cell` device on the caller's
/// nets `passed`, and `cell`'s port names recorded the first time.
fn keepWhole(gpa: Allocator, n: *const Netlist, cell: SubcktId, instance: StrId, passed: []const RefNetId, map: []const u32, out: *Netlist) Allocator.Error!void {
    const name = n.subckt_name.items[@backingInt(cell)];
    try out.device_model.append(gpa, name);
    try out.device_kind.append(gpa, .cell);
    try out.device_name.append(gpa, instance);
    for (passed) |net| try out.terminal_net.append(gpa, @fromBackingInt(map[@backingInt(net)]));
    try out.device_terminal_start.append(gpa, @intCast(out.terminal_net.items.len));
    try out.device_param_start.append(gpa, @intCast(out.param.items.len));
    if (std.mem.indexOfScalar(StrId, out.black_box_cell.items, name) != null) return;
    if (out.black_box_port_start.items.len == 0) try out.black_box_port_start.append(gpa, 0);
    try out.black_box_cell.append(gpa, name);
    for (n.portsOf(cell)) |port| try out.black_box_port.append(gpa, n.net_name.items[@backingInt(port)]);
    try out.black_box_port_start.append(gpa, @intCast(out.black_box_port.items.len));
}
