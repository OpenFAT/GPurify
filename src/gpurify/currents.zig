//! A simulator's terminal currents → the layout device terminals LVS pairs
//! them with (catalog ERC-E14). In: the loaded run (its reference, its
//! `espice-emir/1` file, its labels), the extraction and the LVS options.
//! Out: an `erc.TerminalCurrents`, or the refusal in words.
//!
//! LVS runs first: the reference's top and the layout are compared as the
//! LVS stage compares them (checks_lvs.zig `compareInto`). A file instance
//! names a reference device by its flattened name (`x1.mn1`, case-blind),
//! or by a name under it (`xm1.msky130_fd_pr__nfet_01v8`, the device a
//! PDK wrapper subcircuit the simulator expanded holds), below one scope:
//! the top, or the instance path a testbench placed the reference under
//! (`xdut.`). Instances outside the scope are the testbench's and are
//! left out. An instance's terminals, in file order, are its card's
//! terminals in card order (ESPice writes a device's ports so). A terminal
//! goes to the layout net LVS pairs its reference net with, on the
//! terminals of the paired layout devices that sit on that net, split
//! evenly over them (a reduced parallel or series group shares it).
//!
//! Refused, each naming the cause: no reference; a comparison that could
//! not be made or did not conclude; a file instance in the scope that is
//! no reference device, a reference device the file has no current for,
//! or one listed as several devices (the file is another netlist's); a
//! terminal count that is not the card's; an instance or a net LVS left
//! unmatched; a black box; and a net that is neither labelled (a port:
//! a supply is found by its label) nor balanced, whose current has
//! nowhere to return. A device the deck's `lvs ignore` left out, and a
//! net reduction consumed (a series stack's inner node), carry no current
//! into the grid.
//!
//! Contents:
//! - `pub fn placeCurrents(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, options: CompareOptions, why: *[]const u8) (Allocator.Error || error{Refused})!TerminalCurrents`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const Netlist = ingest.netlist.Netlist;
const check = @import("check");
const lvs = check.lvs;
const CompareOptions = lvs.CompareOptions;
const unpaired = lvs.compare.unpaired;
const erc = check.erc;
const TerminalCurrents = erc.TerminalCurrents;
const NetId = check.topology.NetId;
const DeviceId = check.topology.DeviceId;
const Load = check.report.Load;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const checks_lvs = @import("checks_lvs.zig");

/// The placed rows being collected, one per layout terminal share.
const Rows = struct {
    net: std.ArrayList(NetId) = .empty,
    device: std.ArrayList(DeviceId) = .empty,
    /// avg, em, rms, peak, µA.
    value: std.ArrayList([4]f64) = .empty,
    name: std.ArrayList(Load) = .empty,

    fn push(r: *Rows, gpa: Allocator, net: NetId, device: DeviceId, name: Load) Allocator.Error!void {
        try r.net.append(gpa, net);
        try r.device.append(gpa, device);
        try r.value.append(gpa, undefined);
        try r.name.append(gpa, name);
    }

    /// The rows as `TerminalCurrents`, ascending by net, then device.
    fn sorted(r: *const Rows, gpa: Allocator) Allocator.Error!TerminalCurrents {
        const n = r.net.items.len;
        const order = try gpa.alloc(u32, n);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, r, struct {
            fn less(rows: *const Rows, a: u32, b: u32) bool {
                const na = @backingInt(rows.net.items[a]);
                const nb = @backingInt(rows.net.items[b]);
                if (na != nb) return na < nb;
                return @backingInt(rows.device.items[a]) < @backingInt(rows.device.items[b]);
            }
        }.less);
        const net = try gpa.alloc(NetId, n);
        const device = try gpa.alloc(DeviceId, n);
        const name = try gpa.alloc(Load, n);
        var columns: [4][]f64 = undefined;
        for (&columns) |*c| c.* = try gpa.alloc(f64, n);
        for (order, 0..) |o, i| {
            net[i] = r.net.items[o];
            device[i] = r.device.items[o];
            name[i] = r.name.items[o];
            for (&columns, r.value.items[o]) |c, v| c[i] = v;
        }
        return .{ .net = net, .device = device, .avg = columns[0], .em = columns[1], .rms = columns[2], .peak = columns[3], .name = name };
    }
};

/// The file's rows grouped by instance, CSR: group `g` is one instance's
/// rows in file order.
const Groups = struct {
    start: []const u32,
    row: []const u32,
    /// Each group's instance, lowercased.
    name: []const []const u8,

    fn rowsOf(g: Groups, group: u32) []const u32 {
        return g.row[g.start[group]..g.start[group + 1]];
    }
};

/// The currents of `loaded.currents` (non-null) placed on the layout, in
/// `scratch`; `error.Refused` with `why` (in `run_arena`) saying why not.
pub fn placeCurrents(scratch: Allocator, run_arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, options: CompareOptions, why: *[]const u8) (Allocator.Error || error{Refused})!TerminalCurrents {
    const file = &loaded.currents.?;
    const strings = &loaded.strings;
    const reference = if (loaded.reference) |*r| r else return refuse(run_arena, why, "--currents needs the reference netlist (--reference): LVS is what places each simulated instance on a layout device", .{});

    // LVS first: the pairing the currents are placed through.
    var layout: lvs.Graph = .{};
    try checks_lvs.layoutGraph(scratch, loaded, extracted, &layout);
    var ref_graph: lvs.Graph = .{};
    var traced: lvs.Traced = .{};
    if (try checks_lvs.compareInto(scratch, run_arena, loaded, extracted, options, &layout, &ref_graph, &traced)) |cause| return refuse(run_arena, why, "--currents: LVS made no comparison to place them through: {s}", .{cause});
    if (traced.verdict == .inconclusive) return refuse(run_arena, why, "--currents: LVS did not conclude, so no device pairing places them", .{});
    const first = reference.devicesOf((try reference.top(scratch)).?)[0];
    const names = try deviceNames(scratch, reference, first, ref_graph.deviceCount(), strings);

    // The file's instances, each with its rows in file order.
    const groups = try groupRows(scratch, file.instance, strings);
    const hit = try matchScope(scratch, run_arena, names, groups, why);

    // Each reduced device and net back to the given rows it stands for.
    // `reference_mate` numbers each side's nets after its devices.
    const reduced_devices: u32 = @intCast(traced.reference_row_start.items.len - 1);
    const layout_devices: u32 = @intCast(traced.layout_row_start.items.len - 1);
    const mismatch = if (traced.verdict == .mismatch) " (the layout does not match the reference)" else "";
    const device_of = try inverse(scratch, ref_graph.deviceCount(), traced.reference_row_start.items, traced.reference_row.items);
    const net_of = try inverseOrigin(scratch, ref_graph.netCount(), traced.reference_net_origin.items);

    var rows: Rows = .{};
    for (hit, names, 0..) |g, name, d| {
        const group = groups.rowsOf(g);
        const card = ref_graph.terminalsOf(@intCast(d)).nets;
        const instance = file.instance[group[0]];
        if (group.len != card.len) return refuse(run_arena, why, "--currents: {s} has {d} terminals in the current file and {d} on the reference card of {s}", .{ strings.resolve(instance), group.len, card.len, name });
        // `lvs ignore` left it out: nothing in the layout to carry it.
        const reduced = device_of[d] orelse continue;
        const mate = traced.reference_mate.items[reduced];
        if (mate == unpaired) return refuse(run_arena, why, "--currents: {s} ({s}) is a reference device LVS left unmatched{s}, so its current has no layout device", .{ strings.resolve(instance), name, mismatch });
        for (group, card) |row, ref_net| {
            // Consumed by reduction: a series stack's inner node.
            const reduced_net = net_of[ref_net] orelse continue;
            const layout_net = traced.reference_mate.items[reduced_devices + reduced_net];
            const terminal = file.terminal[row];
            if (layout_net == unpaired) return refuse(run_arena, why, "--currents: {s} {s} is on a net LVS left unmatched{s}", .{ strings.resolve(instance), strings.resolve(terminal), mismatch });
            const on = traced.layout_net_origin.items[layout_net - layout_devices];
            // The layout terminals on that net, of every device the mate stands for.
            const start = rows.net.items.len;
            for (traced.layoutRowsOf(mate)) |l| {
                if (l >= extracted.devices.len()) return refuse(run_arena, why, "--currents: {s} is paired with a black box, which the grid has no terminals of", .{strings.resolve(instance)});
                const nets = extracted.devices.terminalsOf(@fromBackingInt(l)).nets;
                for (layout.terminalsOf(l).nets, nets) |n, net| if (n == on) try rows.push(scratch, net, @fromBackingInt(l), .{ .instance = instance, .terminal = terminal });
            }
            const shares = rows.net.items.len - start;
            if (shares == 0) return refuse(run_arena, why, "--currents: {s} {s}: LVS pairs its net with none of its layout device's terminals", .{ strings.resolve(instance), strings.resolve(terminal) });
            // A magnitude takes its average's sign, so a net's loads add in phase.
            const sign: f64 = if (file.avg[row] < 0) -1.0 else 1.0;
            const k: f64 = @floatFromInt(shares);
            for (start..rows.net.items.len) |i| rows.value.items[i] = .{ file.avg[row] / k, sign * file.em_avg[row] / k, sign * file.rms[row] / k, sign * file.peak[row] / k };
        }
    }
    const placed = try rows.sorted(scratch);
    try requirePorts(run_arena, &placed, extracted, strings, why);
    return placed;
}

// ---- private ----

/// The file's rows into `Groups`, in order of each instance's first row.
fn groupRows(gpa: Allocator, instance: []const StrId, strings: *const StrTable) Allocator.Error!Groups {
    const order = try gpa.alloc(u32, instance.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    // Stable: an instance's rows keep their file order.
    std.mem.sort(u32, order, instance, struct {
        fn less(ids: []const StrId, a: u32, b: u32) bool {
            return @backingInt(ids[a]) < @backingInt(ids[b]);
        }
    }.less);
    var start: std.ArrayList(u32) = .empty;
    var name: std.ArrayList([]const u8) = .empty;
    for (order, 0..) |row, i| if (i == 0 or instance[order[i - 1]] != instance[row]) {
        try start.append(gpa, @intCast(i));
        try name.append(gpa, try std.ascii.allocLowerString(gpa, strings.resolve(instance[row])));
    };
    try start.append(gpa, @intCast(order.len));
    return .{ .start = start.items, .row = order, .name = name.items };
}

/// Each reference device's flattened name, lowercased: its innermost
/// placement's path, a dot and its card's name, a black box's path alone,
/// a top-level card's name as written.
fn deviceNames(gpa: Allocator, reference: *const Netlist, first: u32, count: u32, strings: *const StrTable) Allocator.Error![]const []const u8 {
    // Placements nest and come parent first, so the last to hold a row is its innermost.
    const inner = try gpa.alloc(?u32, count);
    @memset(inner, null);
    for (reference.placements.items, 0..) |p, k| {
        for (@max(p.devices[0], first)..@min(p.devices[1], first + count)) |row| inner[row - first] = @intCast(k);
    }
    const out = try gpa.alloc([]const u8, count);
    for (out, inner, 0..) |*name, placement, d| {
        const card = strings.resolve(reference.device_name.items[first + d]);
        const full = if (placement) |k| blk: {
            const path = strings.resolve(reference.placements.items[k].path);
            break :blk if (reference.device_kind.items[first + d] == .cell) path else try std.mem.concat(gpa, u8, &.{ path, ".", card });
        } else card;
        name.* = try std.ascii.allocLowerString(gpa, full);
    }
    return out;
}

/// The file's group that names each reference device, below the one scope
/// (module doc) that names every reference device and nothing else; the
/// first candidate's refusal when none does.
fn matchScope(gpa: Allocator, run_arena: Allocator, names: []const []const u8, groups: Groups, why: *[]const u8) (Allocator.Error || error{Refused})![]const u32 {
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    for (names, 0..) |n, d| try by_name.put(gpa, n, @intCast(d));
    if (names.len == 0) return &.{};
    // Every scope a file instance names the first reference device under.
    var scopes: std.ArrayList([]const u8) = .empty;
    for (groups.name) |f| {
        var p: usize = 0;
        while (true) {
            if (resolve(&by_name, f[p..])) |d| if (d == 0) {
                const scope = f[0..p];
                for (scopes.items) |s| {
                    if (std.mem.eql(u8, s, scope)) break;
                } else try scopes.append(gpa, scope);
            };
            p = 1 + (std.mem.indexOfScalarPos(u8, f, p, '.') orelse break);
        }
    }
    if (scopes.items.len == 0) return refuse(run_arena, why, "--currents: no instance of the current file is the reference's {s}: the file is another netlist's", .{names[0]});
    const hit = try gpa.alloc(u32, names.len);
    var first_refusal: ?[]const u8 = null;
    for (scopes.items) |scope| {
        if (try assignScope(run_arena, &by_name, names, groups, scope, hit)) |refusal| {
            if (first_refusal == null) first_refusal = refusal;
            continue;
        }
        return hit;
    }
    why.* = first_refusal.?;
    return error.Refused;
}

/// `hit` for one scope, or why the file is not the reference below it.
fn assignScope(run_arena: Allocator, by_name: *const std.StringHashMapUnmanaged(u32), names: []const []const u8, groups: Groups, scope: []const u8, hit: []u32) Allocator.Error!?[]const u8 {
    @memset(hit, std.math.maxInt(u32));
    for (groups.name, 0..) |f, g| {
        if (!std.mem.startsWith(u8, f, scope)) continue;
        const d = resolve(by_name, f[scope.len..]) orelse return try std.fmt.allocPrint(run_arena, "--currents: {s} is no device of the reference: the current file is another netlist's", .{f});
        if (hit[d] != std.math.maxInt(u32)) return try std.fmt.allocPrint(run_arena, "--currents: the current file lists {s} as several devices ({s}, {s}), which LVS compares as one", .{ names[d], groups.name[hit[d]], f });
        hit[d] = @intCast(g);
    }
    for (hit, names) |g, n| if (g == std.math.maxInt(u32)) return try std.fmt.allocPrint(run_arena, "--currents: the reference's {s} has no current in the file: the file is another netlist's", .{n});
    return null;
}

/// The reference device `rest` names, or the one a name under it does.
fn resolve(by_name: *const std.StringHashMapUnmanaged(u32), rest: []const u8) ?u32 {
    var key = rest;
    while (key.len > 0) {
        if (by_name.get(key)) |d| return d;
        key = key[0 .. std.mem.lastIndexOfScalar(u8, key, '.') orelse return null];
    }
    return null;
}

/// Each given row's reduced group, from a CSR of rows per group.
fn inverse(gpa: Allocator, rows: u32, start: []const u32, row: []const u32) Allocator.Error![]const ?u32 {
    const out = try gpa.alloc(?u32, rows);
    @memset(out, null);
    for (0..start.len - 1) |group| {
        for (row[start[group]..start[group + 1]]) |r| out[r] = @intCast(group);
    }
    return out;
}

/// Each given net's reduced net, from each reduced net's given row.
fn inverseOrigin(gpa: Allocator, nets: u32, origin: []const u32) Allocator.Error![]const ?u32 {
    const out = try gpa.alloc(?u32, nets);
    @memset(out, null);
    for (origin, 0..) |given, reduced| out[given] = @intCast(reduced);
    return out;
}

/// Refuses a net whose current has nowhere to return: no label (a supply
/// is found by its label, so a port is a label) and an average that does
/// not balance. ponytail: balanced within 0.1 % of the net's total plus
/// 1 pA, the simulator's own Kirchhoff tolerance (reltol 1e-3); its
/// `.option reltol` if a deck tightens it.
fn requirePorts(run_arena: Allocator, placed: *const TerminalCurrents, extracted: *const Extracted, strings: *const StrTable, why: *[]const u8) error{ Refused, OutOfMemory }!void {
    var i: usize = 0;
    while (i < placed.net.len) {
        const net = placed.net[i];
        var end = i;
        var sum: f64 = 0.0;
        var total: f64 = 0.0;
        while (end < placed.net.len and placed.net[end] == net) : (end += 1) {
            sum += placed.avg[end];
            total += @abs(placed.avg[end]);
        }
        if (extracted.ports.namesOf(net).len == 0 and @abs(sum) > 1e-3 * total + 1e-6) {
            const name = placed.name[i];
            return refuse(run_arena, why, "--currents: {s} {s} is on a net with no label to return its current through, and the net's terminal currents sum to {d} uA, not 0", .{ strings.resolve(name.instance), strings.resolve(name.terminal), sum });
        }
        i = end;
    }
}

fn refuse(run_arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) error{ Refused, OutOfMemory } {
    why.* = try std.fmt.allocPrint(run_arena, fmt, args);
    return error.Refused;
}

test "a name resolves to the device it names or a device it sits under" {
    // Oracle: the scope rule of this file's header, hand-worked: `xm1` is a
    // reference device, so `xm1.msky130` (the device its PDK wrapper holds)
    // names it; `x2.mn1` names nothing; the empty name nothing.
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_name.deinit(std.testing.allocator);
    try by_name.put(std.testing.allocator, "xm1", 0);
    try by_name.put(std.testing.allocator, "x1.mn1", 1);
    try std.testing.expectEqual(@as(?u32, 0), resolve(&by_name, "xm1.msky130"));
    try std.testing.expectEqual(@as(?u32, 1), resolve(&by_name, "x1.mn1"));
    try std.testing.expectEqual(@as(?u32, null), resolve(&by_name, "x2.mn1"));
    try std.testing.expectEqual(@as(?u32, null), resolve(&by_name, ""));
}
