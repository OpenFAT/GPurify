//! Structural Verilog over a cell library → that `Netlist` with one
//! subcircuit per module appended, each holding instances only: how Netgen
//! reads a digital top level (`readnet verilog` into the netlist the cells
//! were read into) and what Calibre's `v2lvs` converts (catalog LVS-075).
//! A bus is its bits, `d[3]`, most significant first; a library cell's bit
//! ports take a bus connected by its base name bit for bit; an open port is
//! a net of its own, `instance.port`; a module with no instance and no
//! `assign`, named as a library cell with as many ports, declares that cell
//! and adds nothing. Ported from crates/ingest/src/netlist/verilog.rs
//! (`read_into`, `append`, `connect`, `Nets`, `base`).
//!
//! Contents:
//! - `pub fn readInto(gpa: Allocator, sources: []const []const u8, strings: *StrTable, n: *Netlist, diag: *Diagnostic) Error![2]u32`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const netlist = @import("netlist.zig");
const Netlist = netlist.Netlist;
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;
const SubcktId = netlist.SubcktId;
const RefNetId = netlist.RefNetId;
const parse = @import("verilog_parse.zig");
const Module = parse.Module;
const Inst = parse.Inst;

/// An instance's callee and the net on each of its ports, null where open.
const Resolved = struct { callee: u32, bits: []const ?[]const u8 };

/// A module's nets: bits `assign` made one, as a union-find over names, and
/// the row each class became.
const Nets = struct {
    arena: Allocator,
    parent: std.StringHashMapUnmanaged([]const u8) = .empty,
    row: std.StringHashMapUnmanaged(RefNetId) = .empty,

    fn root(nets: *const Nets, name: []const u8) []const u8 {
        var at = name;
        while (nets.parent.get(at)) |up| at = up;
        return at;
    }

    /// The net row of `name`'s class in `subckt`, appended on its first use
    /// under the class's root name.
    fn net(nets: *Nets, gpa: Allocator, name: []const u8, subckt: SubcktId, strings: *StrTable, out: *Netlist) Error!RefNetId {
        const r = nets.root(name);
        if (nets.row.get(r)) |row| return row;
        const row: RefNetId = @fromBackingInt(@as(u32, @intCast(out.net_name.items.len)));
        try out.net_name.append(gpa, try strings.intern(gpa, r));
        try out.net_subckt.append(gpa, subckt);
        try nets.row.put(nets.arena, r, row);
        return row;
    }

    /// Joins the classes of `a` and `b`, the lesser name the root, so the
    /// result does not depend on the order of the assignments.
    fn join(nets: *Nets, a: []const u8, b: []const u8) Allocator.Error!void {
        const ra = nets.root(a);
        const rb = nets.root(b);
        if (std.mem.eql(u8, ra, rb)) return;
        const less = std.mem.order(u8, ra, rb) == .lt;
        try nets.parent.put(nets.arena, if (less) rb else ra, if (less) ra else rb);
    }
};

/// Reads each of `sources` into `n`, a library already read (or an empty
/// netlist), interning names into `strings` (allocating with `gpa`, as
/// `n`'s lists do). Returns the subcircuit rows `[first, end)` the modules
/// became, in file order: the top is the one no other instantiates
/// (`Netlist.topIn`). `n` is unchanged on error: every check runs before
/// any row is written.
pub fn readInto(gpa: Allocator, sources: []const []const u8, strings: *StrTable, n: *Netlist, diag: *Diagnostic) Error![2]u32 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var modules: std.ArrayList(Module) = .empty;
    for (sources) |source| try parse.parse(arena, source, &modules, diag);
    return append(gpa, arena, modules.items, strings, n, diag);
}

// ---- private ----

/// Resolves every module and appends it; nothing is written before the
/// last check passes.
fn append(gpa: Allocator, arena: Allocator, modules: []const Module, strings: *StrTable, out: *Netlist, diag: *Diagnostic) Error![2]u32 {
    // Every cell by name and each one's port names: the library's, then the modules'.
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    var ports: std.ArrayList([]const []const u8) = .empty;
    const first = out.subcktCount();
    for (0..first) |cell| {
        const id: SubcktId = @fromBackingInt(@as(u32, @intCast(cell)));
        const names = try arena.alloc([]const u8, out.portsOf(id).len);
        for (out.portsOf(id), names) |net, *name| name.* = try arena.dupe(u8, strings.resolve(out.net_name.items[@backingInt(net)]));
        try ports.append(arena, names);
        try by_name.put(arena, try arena.dupe(u8, strings.resolve(out.subckt_name.items[cell])), @intCast(cell));
    }
    // Modules that become subcircuits, and the stubs that declare a cell.
    var kept: std.ArrayList(*const Module) = .empty;
    for (modules) |*m| {
        const bits = try m.portBits(arena);
        if (by_name.get(m.name)) |cell| {
            const stub = m.insts.items.len == 0 and m.assigns.items.len == 0;
            if (stub and cell < first and ports.items[cell].len == bits.len) continue;
            diag.set(m.line, "{s}", .{m.name});
            return error.Redefined;
        }
        try by_name.put(arena, m.name, @intCast(ports.items.len));
        try ports.append(arena, bits);
        try kept.append(arena, m);
    }
    // Resolve every instance before writing anything.
    var resolved: std.ArrayList([]const Resolved) = .empty;
    for (kept.items) |m| {
        const insts = try arena.alloc(Resolved, m.insts.items.len);
        for (m.insts.items, insts) |inst, *r| {
            const callee = by_name.get(inst.cell) orelse {
                diag.set(inst.line, "{s}", .{inst.cell});
                return error.UndefinedSubckt;
            };
            r.* = .{ .callee = callee, .bits = try connect(arena, &inst, ports.items[callee], diag) };
        }
        try resolved.append(arena, insts);
    }
    // Append: per module its nets (bits joined by `assign`), ports, then instances.
    if (out.subckt_port_start.items.len == 0) {
        try out.subckt_port_start.append(gpa, 0);
        try out.subckt_device_start.append(gpa, 0);
        try out.device_terminal_start.append(gpa, 0);
        try out.device_param_start.append(gpa, 0);
    }
    const devices: u32 = @intCast(out.device_model.items.len);
    for (kept.items, resolved.items, 0..) |m, insts, k| {
        const id: SubcktId = @fromBackingInt(first + @as(u32, @intCast(k)));
        try out.subckt_name.append(gpa, try strings.intern(gpa, m.name));
        var nets: Nets = .{ .arena = arena };
        for (m.assigns.items) |pair| try nets.join(pair[0], pair[1]);
        for (ports.items[@backingInt(id)]) |bit| try out.port_net.append(gpa, try nets.net(gpa, bit, id, strings, out));
        try out.subckt_port_start.append(gpa, @intCast(out.port_net.items.len));
        try out.subckt_device_start.append(gpa, devices);
        for (m.insts.items, insts) |inst, r| {
            if (out.instance_net_start.items.len == 0) try out.instance_net_start.append(gpa, 0);
            try out.instance_of.append(gpa, @fromBackingInt(r.callee));
            try out.instance_subckt.append(gpa, id);
            try out.instance_name.append(gpa, try strings.intern(gpa, inst.name));
            for (ports.items[r.callee], r.bits) |port, bit| {
                // An open port is a net of its own, `instance.port`.
                const name = bit orelse try std.fmt.allocPrint(arena, "{s}.{s}", .{ inst.name, port });
                try out.instance_net.append(gpa, try nets.net(gpa, name, id, strings, out));
            }
            try out.instance_net_start.append(gpa, @intCast(out.instance_net.items.len));
        }
    }
    return .{ first, out.subcktCount() };
}

/// The base of a port bit's name, `D` for `D[3]`, and whether it is a bit.
fn base(port: []const u8) struct { []const u8, bool } {
    if (port.len > 0 and port[port.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, port[0 .. port.len - 1], '[')) |open| {
            const index = port[open + 1 .. port.len - 1];
            const digits = for (index) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (digits and index.len > 0) return .{ port[0..open], true };
        }
    }
    return .{ port, false };
}

fn isBitOf(port: []const u8, head: []const u8) bool {
    const b = base(port);
    return b[1] and std.mem.eql(u8, b[0], head);
}

/// The net each of the callee's `ports` connects to, null where left open.
/// By name: a port takes the connection of its name, a bus port's bits the
/// bits of the connection named for their base. In order: the k-th
/// expression takes the k-th port, a run of one base's bits one port.
fn connect(arena: Allocator, inst: *const Inst, ports: []const []const u8, diag: *Diagnostic) Error![]const ?[]const u8 {
    const out = try arena.alloc(?[]const u8, ports.len);
    @memset(out, null);
    const named = for (inst.conns) |c| {
        if (c.port != null) break true;
    } else false;
    if (named) {
        for (inst.conns) |conn| {
            const port = conn.port orelse {
                diag.set(inst.line, "{s}: ordered and named connections mixed", .{inst.name});
                return error.Unexpected;
            };
            var slots: std.ArrayList(usize) = .empty;
            for (ports, 0..) |p, at| if (std.mem.eql(u8, p, port)) {
                try slots.append(arena, at);
                break;
            };
            if (slots.items.len == 0) for (ports, 0..) |p, at| if (isBitOf(p, port)) try slots.append(arena, at);
            if (slots.items.len == 0) {
                diag.set(conn.line, "{s}: {s} has no port {s}", .{ inst.name, inst.cell, port });
                return error.Unexpected;
            }
            if (conn.bits.len == 0) continue;
            if (conn.bits.len != slots.items.len) {
                diag.set(conn.line, "{s}: {d} bits on the {d}-bit port {s}", .{ inst.name, conn.bits.len, slots.items.len, port });
                return error.Unexpected;
            }
            for (slots.items, conn.bits) |slot, bit| {
                if (out[slot] != null) {
                    diag.set(conn.line, "{s}: port {s} connected twice", .{ inst.name, port });
                    return error.Unexpected;
                }
                out[slot] = bit;
            }
        }
        return out;
    }
    // In order: group the ports into runs of one base.
    var groups: std.ArrayList([2]usize) = .empty;
    var at: usize = 0;
    while (at < ports.len) {
        const head = base(ports[at]);
        var end = at + 1;
        while (head[1] and end < ports.len and isBitOf(ports[end], head[0])) end += 1;
        try groups.append(arena, .{ at, end });
        at = end;
    }
    if (groups.items.len != inst.conns.len) {
        diag.set(inst.line, "{s}", .{inst.name});
        diag.got = @intCast(inst.conns.len);
        diag.want = @intCast(groups.items.len);
        return error.TerminalCount;
    }
    for (groups.items, inst.conns) |g, conn| {
        if (conn.bits.len != g[1] - g[0]) {
            diag.set(conn.line, "{s}: {d} bits on the {d}-bit port {s}", .{ inst.name, conn.bits.len, g[1] - g[0], base(ports[g[0]])[0] });
            return error.Unexpected;
        }
        for (out[g[0]..g[1]], conn.bits) |*slot, bit| slot.* = bit;
    }
    return out;
}

test "a port bit's base is its name before a numeric index" {
    // Oracle: IEEE 1364-2005 §6.1: `D[12]` is bit 12 of `D`; `D[x]` and `D`
    // are whole names.
    try std.testing.expectEqualStrings("D", base("D[12]")[0]);
    try std.testing.expect(base("D[12]")[1]);
    try std.testing.expectEqualStrings("D[x]", base("D[x]")[0]);
    try std.testing.expect(!base("D[x]")[1]);
    try std.testing.expect(!base("D")[1]);
}
