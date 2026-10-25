//! The reference netlist: its top-cell rule, a card-for-card read, the two
//! readers' refusal to guess, and flattening. Ported from
//! crates/ingest/tests/netlist.rs; its `#[ignore]`d nightly timing test
//! (`flattening_is_linear_in_the_placements`) waits for the bench wave.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const nl = ingest.netlist;
const Netlist = nl.Netlist;
const StrTable = geom.StrTable;
const StrId = geom.StrId;
const DeviceRecognition = ingest.deck.DeviceRecognition;
const DeviceKind = ingest.deck.DeviceKind;
const gpa = testing.allocator;

/// A netlist read, its strings and diagnostic, freed together.
const Read = struct {
    strings: StrTable = .empty,
    diag: nl.Diagnostic = .{},

    fn deinit(r: *Read) void {
        r.strings.deinit(gpa);
    }

    fn spice(r: *Read, text: []const u8, devices: *const DeviceRecognition) nl.Error!Netlist {
        return nl.readSpice(gpa, text, &r.strings, devices, &r.diag);
    }

    fn spectre(r: *Read, text: []const u8, devices: *const DeviceRecognition) nl.Error!Netlist {
        return nl.readSpectre(gpa, text, &r.strings, devices, &r.diag);
    }

    fn name(r: *const Read, id: StrId) []const u8 {
        return r.strings.resolve(id);
    }

    /// A deck of `(model, kind)` recognisers, models interned.
    fn deck(r: *Read, a: std.mem.Allocator, models: []const struct { []const u8, DeviceKind }) !DeviceRecognition {
        const kind = try a.alloc(DeviceKind, models.len);
        const model = try a.alloc(StrId, models.len);
        for (models, kind, model) |m, *k, *id| {
            k.* = m[1];
            id.* = try r.strings.intern(gpa, m[0]);
        }
        return .{ .kind = kind, .model = model };
    }
};

const none: DeviceRecognition = .{};

// ---- private ----

fn list(comptime T: type, items: []const T) !std.ArrayList(T) {
    var out: std.ArrayList(T) = .empty;
    try out.appendSlice(gpa, items);
    return out;
}

fn net(i: u32) nl.RefNetId {
    return @fromBackingInt(i);
}

fn sub(i: u32) nl.SubcktId {
    return @fromBackingInt(i);
}

/// Device `row`'s terminal nets as names.
fn terminalNames(r: *const Read, n: *const Netlist, a: std.mem.Allocator, row: u32) ![]const []const u8 {
    const ts = n.terminalsOf(row);
    const out = try a.alloc([]const u8, ts.len);
    for (ts, out) |t, *o| o.* = r.name(n.net_name.items[@backingInt(t)]);
    return out;
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

/// `c{k}` placing `c{k + 1}` twice through `one` and `two`, then the leaf `last`.
fn chain(a: std.mem.Allocator, n: u32, one: []const u8, two: []const u8, last: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..n) |k| try text.print(a, ".subckt c{d} a b\nX1 {s} c{d}\nX2 {s} c{d}\n.ends\n", .{ k, one, k + 1, two, k + 1 });
    try text.print(a, ".subckt c{d} a b\n{s}.ends\n", .{ n, last });
    return text.items;
}

/// `text` flattened from its one top: device and net counts.
fn flatCounts(text: []const u8, diag: *nl.Diagnostic) nl.Error![2]usize {
    var r: Read = .{};
    defer r.deinit();
    var n = try r.spice(text, &none);
    defer n.deinit(gpa);
    var flat = try nl.flattenTop(gpa, &n, (try n.top(gpa)).?, &r.strings, diag);
    defer flat.deinit(gpa);
    return .{ flat.device_model.items.len, flat.net_name.items.len };
}

test "the top subcircuit is the uninstantiated one and ambiguity is refused" {
    // Oracle: construct-from-answer. `top` is "the one nothing else
    // instantiates": one subcircuit is the top, none is no top, and two
    // uninstantiated ones are an ambiguity `lvs` must refuse.
    var r: Read = .{};
    defer r.deinit();
    var empty: Netlist = .{};
    try testing.expectEqual(null, try empty.top(gpa));
    var single: Netlist = .{
        .subckt_name = try list(StrId, &.{try r.strings.intern(gpa, "only")}),
        .subckt_port_start = try list(u32, &.{ 0, 0 }),
        .subckt_device_start = try list(u32, &.{ 0, 0 }),
    };
    defer single.deinit(gpa);
    try testing.expectEqual(sub(0), (try single.top(gpa)).?);
    // Two subcircuits, three devices, terminal and parameter runs of three
    // lengths including an empty one; nothing instantiates anything.
    var two: Netlist = .{
        .subckt_name = try list(StrId, &.{ try r.strings.intern(gpa, "inv"), try r.strings.intern(gpa, "term") }),
        .subckt_port_start = try list(u32, &.{ 0, 2, 4 }),
        .port_net = try list(nl.RefNetId, &.{ net(0), net(1), net(0), net(4) }),
        .subckt_device_start = try list(u32, &.{ 0, 2, 3 }),
        .device_model = try list(StrId, &.{ try r.strings.intern(gpa, "nfet"), try r.strings.intern(gpa, "pfet"), try r.strings.intern(gpa, "rpoly") }),
        .device_kind = try list(DeviceKind, &.{ .mos, .mos, .resistor }),
        .device_terminal_start = try list(u32, &.{ 0, 4, 8, 10 }),
        .terminal_net = try list(nl.RefNetId, &.{ net(1), net(0), net(2), net(2), net(1), net(0), net(3), net(3), net(4), net(5) }),
        .device_param_start = try list(u32, &.{ 0, 2, 3, 3 }),
        .param = try list(nl.Param, &.{ .{ .name = try r.strings.intern(gpa, "w"), .value = 1.0 }, .{ .name = try r.strings.intern(gpa, "l"), .value = 0.15 }, .{ .name = try r.strings.intern(gpa, "w"), .value = 2.0 } }),
        .net_name = try list(StrId, &.{ try r.strings.intern(gpa, "n0"), try r.strings.intern(gpa, "n1"), try r.strings.intern(gpa, "n2"), try r.strings.intern(gpa, "n3"), try r.strings.intern(gpa, "n4"), try r.strings.intern(gpa, "n5") }),
        .net_subckt = try list(nl.SubcktId, &.{ sub(0), sub(0), sub(0), sub(0), sub(1), sub(1) }),
    };
    defer two.deinit(gpa);
    try testing.expectEqual(null, try two.top(gpa));
}

test "a subcircuit of two transistors reads back card for card" {
    // Oracle: construct-from-answer. The SPICE card grammar is an external
    // specification: `.subckt <name> <ports…>` names its ports in order, and
    // `M<name> <d> <g> <s> <b> <model> <k>=<v>…` is a four-terminal device in
    // that order. Names compare through `resolve`, nets through id equality.
    const source =
        \\* an inverter, ports in declaration order
        \\.subckt inv a y vdd vss
        \\mn y a vss vss nfet w=2 l=1
        \\mp y a vdd vdd pfet w=4
        \\.ends
        \\
    ;
    var r: Read = .{};
    defer r.deinit();
    var n = try r.spice(source, &none);
    defer n.deinit(gpa);
    try testing.expectEqual(1, n.subcktCount());
    try testing.expectEqual(sub(0), (try n.top(gpa)).?);
    try testing.expectEqualStrings("inv", r.name(n.subckt_name.items[0]));
    const ports = n.portsOf(sub(0));
    var port_names: [4][]const u8 = undefined;
    for (ports, &port_names) |p, *name| name.* = r.name(n.net_name.items[@backingInt(p)]);
    try expectNames(&.{ "a", "y", "vdd", "vss" }, &port_names);
    try testing.expectEqual([2]u32{ 0, 2 }, n.devicesOf(sub(0)));
    for ([_][]const u8{ "nfet", "pfet" }, 0..) |model, row| {
        try testing.expectEqualStrings(model, r.name(n.device_model.items[row]));
        try testing.expectEqual(DeviceKind.mos, n.device_kind.items[row]);
        try testing.expectEqual(4, n.terminalsOf(@intCast(row)).len);
    }
    // Drain, gate, source, bulk: the order the card states them in.
    try testing.expectEqualSlices(nl.RefNetId, &.{ ports[1], ports[0], ports[3], ports[3] }, n.terminalsOf(0));
    try testing.expectEqualSlices(nl.RefNetId, &.{ ports[1], ports[0], ports[2], ports[2] }, n.terminalsOf(1));
    const want = [_][]const struct { []const u8, f64 }{ &.{ .{ "w", 2.0 }, .{ "l", 1.0 } }, &.{.{ "w", 4.0 }} };
    for (want, 0..) |params, device| {
        const got = n.paramsOf(@intCast(device));
        try testing.expectEqual(params.len, got.len);
        for (params, got) |w, g| {
            try testing.expectEqualStrings(w[0], r.name(g.name));
            try testing.expect(@abs(g.value - w[1]) <= 1e-12);
        }
    }
    for (n.net_subckt.items) |s| try testing.expectEqual(sub(0), s);
}

test "a subcircuit defined twice is refused at the line that redefines it" {
    // Oracle: construct-from-answer. The input holds exactly one duplicate
    // definition, on line 5; the line as well as the variant is asserted.
    var r: Read = .{};
    defer r.deinit();
    try testing.expectError(error.Redefined, r.spice("* a comment card\n.subckt inv a y\nM1 y a 0 0 nfet w=1u l=0.15u\n.ends\n.subckt inv a y\n.ends\n", &none));
    try testing.expectEqual(5, r.diag.line);
    try testing.expectEqualStrings("inv", r.diag.token());
}

test "a call to an undefined subcircuit is refused rather than left dangling" {
    // Oracle: construct-from-answer. A call to a subcircuit never defined is
    // unresolvable, and the reader says so rather than leaving a hole.
    var r: Read = .{};
    defer r.deinit();
    try testing.expectError(error.UndefinedSubckt, r.spice(".subckt top a y\nX1 a y missing_cell\n.ends\n", &none));
    try testing.expectEqual(2, r.diag.line);
    try testing.expectEqualStrings("missing_cell", r.diag.token());
}

test "a Spectre statement outside the declared subset is refused with its line" {
    // Oracle: construct-from-answer. The Spectre reader's subset has no
    // `alter`; it is `Unsupported` with its line, never skipped.
    var r: Read = .{};
    defer r.deinit();
    try testing.expectError(error.Unsupported, r.spectre("subckt inv a y\nends inv\nalter corner_tt dev=nfet param=vth value=0.4\n", &none));
    try testing.expectEqual(3, r.diag.line);
}

test "an X card calling a deck model is the same device as the M card" {
    // Oracle: the M-card form. A sky130 primitive called as a subcircuit
    // (bare W/L in µm under `netlist_scale 1um`, upper-case names) reads as
    // the same device as `M` with suffixed lower-case parameters: a bare
    // length times the scale, a bare area times its square, a count as is.
    var r: Read = .{};
    defer r.deinit();
    const model = try r.strings.intern(gpa, "sky130_fd_pr__nfet_01v8");
    const devices: DeviceRecognition = .{ .kind = &.{.mos}, .model = &.{model}, .netlist_scale_nm = 1000.0 };
    const card = ".subckt c d g s b\nXM1 d g s b sky130_fd_pr__nfet_01v8 W=0.42 L=0.15 AS=0.1 PS=1.4 nf=1\n.ends\n";
    var x = try r.spice(card, &devices);
    defer x.deinit(gpa);
    var m = try r.spice(".subckt c d g s b\nM1 d g s b sky130_fd_pr__nfet_01v8 w=0.42u l=0.15u as=0.1p ps=1.4u nf=1\n.ends\n", &devices);
    defer m.deinit(gpa);
    try testing.expectEqual(0, x.instance_of.items.len);
    try testing.expectEqualSlices(DeviceKind, &.{.mos}, x.device_kind.items);
    try testing.expectEqualSlices(StrId, m.device_model.items, x.device_model.items);
    try testing.expectEqualSlices(nl.RefNetId, m.terminal_net.items, x.terminal_net.items);
    try testing.expectEqual(m.param.items.len, x.param.items.len);
    for (x.param.items, m.param.items) |xp, mp| {
        try testing.expectEqualStrings(r.name(mp.name), r.name(xp.name));
        try testing.expect(@abs(xp.value - mp.value) <= 1e-12 * @abs(mp.value));
    }
    // With no `netlist_scale` a bare value is SI, as SPICE reads it.
    var unscaled = devices;
    unscaled.netlist_scale_nm = null;
    var si = try r.spice(card, &unscaled);
    defer si.deinit(gpa);
    const w = for (si.param.items) |p| {
        if (std.mem.eql(u8, r.name(p.name), "w")) break p.value;
    } else null;
    try testing.expectEqual(0.42, w.?);
    // Without the deck naming the model it is still an undefined subcircuit.
    if (r.spice(".subckt c d g s b\nXM1 d g s b sky130_fd_pr__nfet_01v8 W=0.42 L=0.15\n.ends\n", &none)) |*ok| {
        var bad = ok.*;
        bad.deinit(gpa);
        return error.TestUnexpectedResult;
    } else |err| try testing.expect(err == error.Unsupported or err == error.UndefinedSubckt);
}

test "an X card calling a deck model is that device when the netlist defines it too" {
    // Oracle: construct-from-answer, catalog LVS-067 (KLayout's
    // `wants_subcircuit`): the call is the device (`w=2` is 2 µm under
    // `netlist_scale 1um`), its definition is no candidate top.
    var r: Read = .{};
    defer r.deinit();
    const devices: DeviceRecognition = .{ .kind = &.{.resistor}, .model = &.{try r.strings.intern(gpa, "rhigh")}, .netlist_scale_nm = 1000.0 };
    var n = try r.spice(".subckt rhigh a b\nR0 a b rinner r=1k\n.ends\n.subckt top n1 n2\nXR1 n1 n2 rhigh w=2 l=10\n.ends\n", &devices);
    defer n.deinit(gpa);
    try testing.expectEqual(0, n.instance_of.items.len);
    const top = (try n.top(gpa)).?;
    try testing.expectEqualStrings("top", r.name(n.subckt_name.items[@backingInt(top)]));
    var flat = try nl.flattenTop(gpa, &n, top, &r.strings, &r.diag);
    defer flat.deinit(gpa);
    try testing.expectEqual(1, flat.device_model.items.len);
    try testing.expectEqualStrings("rhigh", r.name(flat.device_model.items[0]));
    try testing.expectEqualSlices(DeviceKind, &.{.resistor}, flat.device_kind.items);
    const wl = [_]StrId{ try r.strings.intern(gpa, "w"), try r.strings.intern(gpa, "l") };
    try testing.expectEqual(2, flat.param.items.len);
    for (flat.param.items, wl, [_]f64{ 2e-6, 10e-6 }) |p, name, want| {
        try testing.expectEqual(name, p.name);
        try testing.expect(@abs(p.value - want) <= 1e-12 * want);
    }
}

test "flattening keeps a black box whole on its ports" {
    // Oracle: construct-from-answer, catalog LVS-033 (Netgen's blackbox:
    // pin names and order only). Each placement of `BB1` is one `cell`
    // device on the caller's nets in port order, no parameter, its body never
    // expanded, its ports listed once; `INV` still expands. A box of 257
    // ports is refused, of 256 is not.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Read = .{};
    defer r.deinit();
    var n = try r.spice(".subckt BB1 P Q R\nM0 P Q R R nfet\nM1 Q P R R pfet\n.ends\n.subckt INV A Y\nM0 Y A Y Y nfet\n.ends\n.subckt TOP a b c\nX1 c a b BB1\nX2 b b a BB1\nX3 a b INV\n.ends\n", &none);
    defer n.deinit(gpa);
    const top = (try n.top(gpa)).?;
    var flat = try nl.flattenTopWith(gpa, &n, top, &.{"BB*"}, &r.strings, &r.diag);
    defer flat.deinit(gpa);
    var models: [3][]const u8 = undefined;
    for (flat.device_model.items, &models) |m, *s| s.* = r.name(m);
    try expectNames(&.{ "BB1", "BB1", "nfet" }, &models);
    try testing.expectEqualSlices(DeviceKind, &.{ .cell, .cell, .mos }, flat.device_kind.items);
    try expectNames(&.{ "c", "a", "b" }, try terminalNames(&r, &flat, a, 0));
    try expectNames(&.{ "b", "b", "a" }, try terminalNames(&r, &flat, a, 1));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, flat.device_param_start.items[0..3]);
    try testing.expectEqual(1, flat.black_box_cell.items.len);
    try testing.expectEqualStrings("BB1", r.name(flat.black_box_cell.items[0]));
    var ports: [3][]const u8 = undefined;
    for (flat.blackBoxPorts(0), &ports) |p, *s| s.* = r.name(p);
    try expectNames(&.{ "P", "Q", "R" }, &ports);
    try testing.expectEqual(3, flat.placements.items.len);
    for (flat.placements.items, [_][]const u8{ "X1", "X2", "X3" }, [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } }) |p, path, devices| {
        try testing.expectEqualStrings(path, r.name(p.path));
        try testing.expectEqual(devices, p.devices);
    }
    for ([_]struct { u32, bool }{ .{ 256, false }, .{ 257, true } }) |c| {
        var pins: std.ArrayList(u8) = .empty;
        for (0..c[0]) |k| try pins.print(a, "{s}p{d}", .{ if (k == 0) "" else " ", k });
        const text = try std.fmt.allocPrint(a, ".subckt WIDE {s}\n.ends\n.subckt T {s}\nX1 {s} WIDE\n.ends\n", .{ pins.items, pins.items, pins.items });
        var wide = try r.spice(text, &none);
        defer wide.deinit(gpa);
        const t = (try wide.top(gpa)).?;
        if (nl.flattenTopWith(gpa, &wide, t, &.{"WIDE"}, &r.strings, &r.diag)) |ok| {
            var f = ok;
            f.deinit(gpa);
            try testing.expect(!c[1]);
        } else |err| {
            try testing.expect(c[1] and err == error.TooManyPins and r.diag.got == 257);
        }
    }
}

test "flattening wires instances through their ports" {
    // Oracle: hand-derived. Flattening `BUF` by hand: two `INV` placements of
    // two devices each, ports `IN OUT VDD VSS`, X1's nfet on drain `n1`,
    // gate `IN`, source `X1.mid`, bulk `VSS`, and X2's on `OUT`, `n1`,
    // `X2.mid`.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r: Read = .{};
    defer r.deinit();
    var n = try r.spice(".subckt INV A Y VDD VSS\nM0 Y A mid VSS nfet\nM1 mid A VDD VDD pfet\n.ends\n.subckt BUF IN OUT VDD VSS\nX1 IN n1 VDD VSS INV\nX2 n1 OUT VDD VSS INV\n.ends\n", &none);
    defer n.deinit(gpa);
    var flat = try nl.flattenTop(gpa, &n, (try n.top(gpa)).?, &r.strings, &r.diag);
    defer flat.deinit(gpa);
    try testing.expectEqual(1, flat.subcktCount());
    try testing.expectEqualStrings("BUF", r.name(flat.subckt_name.items[0]));
    try testing.expectEqual(4, flat.device_model.items.len);
    var ports: [4][]const u8 = undefined;
    for (flat.port_net.items, &ports) |p, *s| s.* = r.name(flat.net_name.items[@backingInt(p)]);
    try expectNames(&.{ "IN", "OUT", "VDD", "VSS" }, &ports);
    try expectNames(&.{ "n1", "IN", "X1.mid", "VSS" }, try terminalNames(&r, &flat, arena.allocator(), 0));
    try expectNames(&.{ "OUT", "n1", "X2.mid", "VSS" }, try terminalNames(&r, &flat, arena.allocator(), 2));
}

test "flattening refuses a cycle" {
    // Oracle: construct-from-answer. `A` places `B` and `B` places `A`, so
    // the hierarchy under `TOP` is cyclic by construction.
    var r: Read = .{};
    defer r.deinit();
    var n = try r.spice(".subckt A x\nX1 x B\n.ends\n.subckt B x\nX1 x A\n.ends\n.subckt TOP x\nX1 x A\n.ends\n", &none);
    defer n.deinit(gpa);
    try testing.expectError(error.CyclicHierarchy, nl.flattenTop(gpa, &n, (try n.top(gpa)).?, &r.strings, &r.diag));
}

test "a reference over the flat cap is refused before it is expanded" {
    // Oracle: closed form (testing-plan F89). `c0` to `c{n-1}` each place the
    // next twice: devices 2ⁿ, nets 2, instances 2ⁿ⁺¹ − 2, so 3·2ⁿ in all;
    // the nets chain joins placements through `m`, 3·2ⁿ − 1. At n = 3 the
    // hand-expanded netlists (8 devices, 2 nets; 0 devices, 9 nets); at
    // n = 30 each is refused with its count at once.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: nl.Diagnostic = .{};
    try testing.expectEqual([2]usize{ 8, 2 }, try flatCounts(try chain(a, 3, "a b", "a b", "R1 a b 1k rpoly\n"), &diag));
    try testing.expectEqual([2]usize{ 0, 9 }, try flatCounts(try chain(a, 3, "a m", "m b", ""), &diag));
    for ([_]struct { []const u8, u64 }{ .{ try chain(a, 30, "a b", "a b", "R1 a b 1k rpoly\n"), 3 << 30 }, .{ try chain(a, 30, "a m", "m b", ""), (3 << 30) - 1 } }) |c| {
        try testing.expect(c[1] > nl.max_flat_elements);
        try testing.expectError(error.TooLarge, flatCounts(c[0], &diag));
        try testing.expectEqual(c[1], diag.count);
    }
}

test "flattening keeps each placement's nets apart" {
    // Oracle: construct-from-answer (testing-plan F95), derived by hand: a
    // cell's devices before its instances, instances in file order.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r: Read = .{};
    defer r.deinit();
    var n = try r.spice(".subckt leaf p\nR1 p q rpoly\n.ends\n.subckt mid x\nX1 x leaf\nX2 y leaf\nR1 x y rpoly\n.ends\n.subckt top a\nXa a mid\nXb a leaf\nXc b mid\nR1 a b rpoly\n.ends\n", &none);
    defer n.deinit(gpa);
    var flat = try nl.flattenTop(gpa, &n, (try n.top(gpa)).?, &r.strings, &r.diag);
    defer flat.deinit(gpa);
    const want = [_][2][]const u8{ .{ "a", "b" }, .{ "a", "Xa.y" }, .{ "a", "Xa.X1.q" }, .{ "Xa.y", "Xa.X2.q" }, .{ "a", "Xb.q" }, .{ "b", "Xc.y" }, .{ "b", "Xc.X1.q" }, .{ "Xc.y", "Xc.X2.q" } };
    try testing.expectEqual(want.len, flat.device_model.items.len);
    for (want, 0..) |w, device| try expectNames(&w, try terminalNames(&r, &flat, arena.allocator(), @intCast(device)));
    try testing.expectEqual(9, flat.net_name.items.len);
}

test "a reference deeper than the layout's depth cap is refused, not overflowed" {
    // Oracle: the stated cap (testing-plan F96), as the layout's: 1024
    // levels, the top included. A chain of 1024 flattens to the resistor and
    // two nets; at 1025 and 10 000, `c1024` is named in the refusal.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(1024, nl.max_hierarchy_depth);
    for ([_]u32{ 1024, 1025, 10_000 }) |levels| {
        var text: std.ArrayList(u8) = .empty;
        for (0..levels - 1) |k| try text.print(a, ".subckt c{d} a\nX1 a c{d}\n.ends\n", .{ k, k + 1 });
        try text.print(a, ".subckt c{d} a\nR1 a b rpoly\n.ends\n", .{levels - 1});
        var diag: nl.Diagnostic = .{};
        if (levels == 1024) {
            try testing.expectEqual([2]usize{ 1, 2 }, try flatCounts(text.items, &diag));
        } else {
            try testing.expectError(error.TooDeep, flatCounts(text.items, &diag));
            try testing.expectEqualStrings("c1024", diag.token());
        }
    }
}

test "an R or C card's positional value is its r or c" {
    // Oracle: SPICE's card syntax (ngspice manual, `RXXXXXXX n+ n- <value>
    // <mname>`): the positional value is the device's `r` or `c` (1k is 1000
    // ohms, 1p is 1e-12 F); a value with no model against a deck with no
    // recogniser of its kind is refused, as is a value stated both ways.
    var r: Read = .{};
    defer r.deinit();
    var positional = try r.spice(".subckt top a b\nR1 a b 1k rpoly w=1u\nC1 a b 1p cmim\n.ends\n", &none);
    defer positional.deinit(gpa);
    var named = try r.spice(".subckt top a b\nR1 a b rpoly r=1k w=1u\nC1 a b cmim c=1p\n.ends\n", &none);
    defer named.deinit(gpa);
    const rr = try r.strings.intern(gpa, "r");
    const w = try r.strings.intern(gpa, "w");
    const c = try r.strings.intern(gpa, "c");
    try testing.expectEqualSlices(nl.Param, &.{ .{ .name = rr, .value = 1000.0 }, .{ .name = w, .value = 1e-6 }, .{ .name = c, .value = 1e-12 } }, positional.param.items);
    try testing.expectEqualSlices(nl.Param, named.param.items, positional.param.items);
    try testing.expectEqualSlices(u32, named.device_param_start.items, positional.device_param_start.items);
    try testing.expectEqualSlices(StrId, named.device_model.items, positional.device_model.items);
    try testing.expectEqualSlices(DeviceKind, &.{ .resistor, .capacitor }, positional.device_kind.items);
    for ([_][]const u8{ ".subckt top a b\nR1 a b 1k\n.ends\n", ".subckt top a b\nC1 a b 1p\n.ends\n" }) |text| {
        try testing.expectError(error.NoModel, r.spice(text, &none));
        try testing.expectEqual(2, r.diag.line);
    }
    try testing.expectError(error.Unexpected, r.spice(".subckt top a b\nR1 a b 1k rpoly r=2k\n.ends\n", &none));
    try testing.expectEqual(2, r.diag.line);
    try testing.expectEqualStrings("r=2k", r.diag.token());
}

test "a two-pin card with no model is the deck's one recogniser of its kind" {
    // Oracle: construct-from-answer (testing-plan F86): `R1 a b 1k` and `R2 a
    // b r=2k` are `rpoly` of 1000 and 2000 ohms, `C1 a b 1p` is `cmim`, `D1`
    // and `D2` are `dpn`; a deck with two resistors, or none, has no one to
    // bind `R1` to, and the refusal names what it has.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Read = .{};
    defer r.deinit();
    const one_each = try r.deck(a, &.{ .{ "nfet", .mos }, .{ "rpoly", .resistor }, .{ "cmim", .capacitor }, .{ "dpn", .diode } });
    var n = try r.spice(".subckt top a b\nR1 a b 1k\nR2 a b r=2k\nC1 a b 1p\nD1 a b\nD2 a b area=1p\n.ends\n", &one_each);
    defer n.deinit(gpa);
    var models: [5][]const u8 = undefined;
    for (n.device_model.items, &models) |m, *s| s.* = r.name(m);
    try expectNames(&.{ "rpoly", "rpoly", "cmim", "dpn", "dpn" }, &models);
    const rr = try r.strings.intern(gpa, "r");
    const c = try r.strings.intern(gpa, "c");
    const area = try r.strings.intern(gpa, "area");
    try testing.expectEqualSlices(nl.Param, &.{ .{ .name = rr, .value = 1000.0 }, .{ .name = rr, .value = 2000.0 }, .{ .name = c, .value = 1e-12 }, .{ .name = area, .value = 1e-12 } }, n.param.items);
    const two = try r.deck(a, &.{ .{ "rpoly", .resistor }, .{ "rdiff", .resistor } });
    const no_resistor = try r.deck(a, &.{.{ "cmim", .capacitor }});
    for ([_]struct { *const DeviceRecognition, []const []const u8 }{ .{ &two, &.{ "rpoly", "rdiff" } }, .{ &no_resistor, &.{} } }) |case| {
        try testing.expectError(error.NoModel, r.spice(".subckt top a b\nR1 a b 1k\n.ends\n", case[0]));
        try testing.expectEqual(2, r.diag.line);
        try testing.expectEqualStrings("R1", r.diag.token());
        for (case[1]) |name| try testing.expect(std.mem.indexOf(u8, r.diag.has(), name) != null);
        try testing.expect(std.mem.indexOf(u8, r.diag.has(), "cmim") == null);
    }
}

test "a Spectre primitive with no model card is the deck's one recogniser of its kind" {
    // Oracle: construct-from-answer (testing-plan F97): `R1 (a b) resistor
    // r=1k` is `rpoly` of 1000 ohms, `C1` `cmim`, `M1` `nfet`, an instance of
    // a `model` card is that card's name; two resistors or none refuse.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Read = .{};
    defer r.deinit();
    const one_each = try r.deck(a, &.{ .{ "nfet", .mos }, .{ "rpoly", .resistor }, .{ "cmim", .capacitor } });
    var n = try r.spectre("model rhi resistor\nsubckt top a b\nR1 (a b) resistor r=1k\nC1 (a b) capacitor\nM1 (a b a a) nmos\nR2 (a b) rhi\nends top\n", &one_each);
    defer n.deinit(gpa);
    var models: [4][]const u8 = undefined;
    for (n.device_model.items, &models) |m, *s| s.* = r.name(m);
    try expectNames(&.{ "rpoly", "cmim", "nfet", "rhi" }, &models);
    try testing.expectEqualSlices(nl.Param, &.{.{ .name = try r.strings.intern(gpa, "r"), .value = 1000.0 }}, n.param.items);
    const two = try r.deck(a, &.{ .{ "rpoly", .resistor }, .{ "rdiff", .resistor } });
    const no_resistor = try r.deck(a, &.{.{ "cmim", .capacitor }});
    for ([_]struct { *const DeviceRecognition, []const []const u8 }{ .{ &two, &.{ "rpoly", "rdiff" } }, .{ &no_resistor, &.{} } }) |case| {
        try testing.expectError(error.NoModel, r.spectre("subckt top a b\nR1 (a b) resistor r=1k\nends top\n", case[0]));
        try testing.expectEqual(2, r.diag.line);
        try testing.expectEqualStrings("R1", r.diag.token());
        for (case[1]) |name| try testing.expect(std.mem.indexOf(u8, r.diag.has(), name) != null);
        try testing.expect(std.mem.indexOf(u8, r.diag.has(), "cmim") == null);
    }
}

test "a diode's pj and KLayout's A and P are its area and perimeter" {
    // Oracle: construct-from-answer (testing-plan F87): KLayout's `A=1p P=4u`
    // is `area=1p perim=4u` and ngspice's diode `pj=4u` is `perim=4u`; a
    // perimeter under two of its names is refused at the second.
    var r: Read = .{};
    defer r.deinit();
    var aliased = try r.spice(".subckt top a b\nD1 a b dpn A=1p P=4u\nD2 a b dpn pj=4u\n.ends\n", &none);
    defer aliased.deinit(gpa);
    var named = try r.spice(".subckt top a b\nD1 a b dpn area=1p perim=4u\nD2 a b dpn perim=4u\n.ends\n", &none);
    defer named.deinit(gpa);
    const area = try r.strings.intern(gpa, "area");
    const perim = try r.strings.intern(gpa, "perim");
    try testing.expectEqualSlices(nl.Param, &.{ .{ .name = area, .value = 1e-12 }, .{ .name = perim, .value = 4e-6 }, .{ .name = perim, .value = 4e-6 } }, aliased.param.items);
    try testing.expectEqualSlices(nl.Param, named.param.items, aliased.param.items);
    try testing.expectError(error.Unexpected, r.spice(".subckt top a b\nD1 a b dpn perim=4u pj=4u\n.ends\n", &none));
    try testing.expectEqual(2, r.diag.line);
    try testing.expectEqualStrings("pj=4u", r.diag.token());
}

test "an L card is an inductor whose l is its inductance" {
    // Oracle: construct-from-answer (catalog LVS-065; Netgen reads an `L`
    // card as an inductor with its positional value, Spectre's `inductor`
    // takes `l`): `L1 a b 2n spiral`, `L2 a b spiral l=3n` and a model-less
    // `L3 a b 1n` are inductors of `spiral`, compared as `ind`.
    var r: Read = .{};
    defer r.deinit();
    const spiral = try r.strings.intern(gpa, "spiral");
    const deck: DeviceRecognition = .{ .kind = &.{.inductor}, .model = &.{spiral} };
    var n = try r.spice(".subckt top a b\nL1 a b 2n spiral\nL2 a b spiral l=3n\nL3 a b 1n\n.ends\n", &deck);
    defer n.deinit(gpa);
    try testing.expectEqualSlices(DeviceKind, &.{ .inductor, .inductor, .inductor }, n.device_kind.items);
    try testing.expectEqualSlices(StrId, &.{ spiral, spiral, spiral }, n.device_model.items);
    const ind = try r.strings.intern(gpa, "ind");
    // `3n` is 3 times 1e-9 in f64, as the reader scales every suffix.
    const three_nano = @as(f64, 3.0) * @as(f64, 1e-9);
    try testing.expectEqualSlices(nl.Param, &.{ .{ .name = ind, .value = 2e-9 }, .{ .name = ind, .value = three_nano }, .{ .name = ind, .value = 1e-9 } }, n.param.items);
    var twin = try r.spectre("subckt top a b\nL1 (a b) inductor l=2n\nends top\n", &deck);
    defer twin.deinit(gpa);
    try testing.expectEqualSlices(DeviceKind, &.{.inductor}, twin.device_kind.items);
    try testing.expectEqualSlices(StrId, &.{spiral}, twin.device_model.items);
    try testing.expectEqualSlices(nl.Param, &.{.{ .name = ind, .value = 2e-9 }}, twin.param.items);
}
