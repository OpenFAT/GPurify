//! The simulator-ready netlist (catalog PEX-017) end to end: the corpus's
//! LVS cells run through `gpurify.run` with LVS and PEX, named by
//! `subckt_build.buildInto`, written by `writeSpice` and `writeDspfSubckt`,
//! as the CLI's `pex --reference --format spice` does.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const gpurify = @import("gpurify");
const extract = @import("extract");
const fixtures = @import("fixtures.zig");
const gpa = testing.allocator;
const io = testing.io;
const ex = gpurify.@"export";

const deck = "tests/fixtures/params.deck";
const header: ex.Header = .{ .tool_version = "0.1.0", .deck_path = deck, .layout_path = "layout.gds", .reference_path = "ref.spice" };

/// One cell's run and its netlist, in one arena.
const Netlist = struct {
    arena_state: std.heap.ArenaAllocator,
    run: gpurify.Run = undefined,
    subckt: ex.subckt.Subckt = .{},
    why: []const u8 = "",

    fn deinit(n: *Netlist) void {
        n.arena_state.deinit();
    }

    /// The SPICE text, nominal corner.
    fn spice(n: *Netlist) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(n.arena_state.allocator());
        var diag: ex.Diagnostic = .{};
        try ex.netlist.writeSpice(&out.writer, n.arena_state.allocator(), &n.run.outputs.parasitics.?, &n.subckt, "nominal", &header, &diag);
        return out.written();
    }
};

// ---- private ----

/// Runs LVS and PEX on corpus cell `layout_id` (tests/fixtures/lvs/) against
/// `reference` (text, null for none) from a scratch directory, and builds
/// its netlist; `error.Refused` leaves `why` set.
fn netlistOf(n: *Netlist, layout_id: []const u8, reference: ?[]const u8) !void {
    n.* = .{ .arena_state = .init(gpa) };
    const arena = n.arena_state.allocator();
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    _ = try fixtures.ensure(gpa, root);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gds = try root.readFileAlloc(io, try std.fmt.allocPrint(arena, "tests/fixtures/lvs/{s}.gds", .{layout_id}), arena, .unlimited);
    try tmp.dir.writeFile(io, .{ .sub_path = "layout.gds", .data = gds });
    try tmp.dir.writeFile(io, .{ .sub_path = "params.deck", .data = try root.readFileAlloc(io, deck, arena, .unlimited) });
    if (reference) |text| try tmp.dir.writeFile(io, .{ .sub_path = "ref.spice", .data = text });
    const inputs: gpurify.Inputs = .{ .layout = "layout.gds", .deck = "params.deck", .reference = if (reference != null) &.{"ref.spice"} else &.{} };
    var diag: gpurify.RunDiagnostic = .{};
    n.run = try gpurify.run(gpa, arena, io, tmp.dir, inputs, .{ .checks = .{ .lvs = reference != null, .pex = true } }, &.{}, &diag);
    try gpurify.subckt_build.buildInto(arena, &n.run.loaded, &n.run.extracted, &n.run.outputs, "cells/LVS_INV.gds", &n.run.outputs.parasitics.?, &n.subckt, &n.why);
}

/// A corpus reference netlist's text.
fn referenceText(arena: Allocator, id: []const u8) ![]const u8 {
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    return root.readFileAlloc(io, try std.fmt.allocPrint(arena, "tests/fixtures/lvs_refs/{s}.spice", .{id}), arena, .unlimited);
}

/// The line of `text` starting with `prefix`.
fn lineOf(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return line;
    return null;
}

test "the pins come in the reference's order, the devices under its names and LVS's sizes" {
    // Oracle: the reference netlists. LVS_CLEAN_MATCH and LVS_SD_PERMUTE
    // compare one layout (cell LVS_INV) against `.subckt LVS_INV Y A VSS
    // VDD` and `.subckt LVS_INV VSS A Y VDD`, both matching, so the pins
    // are written in each one's order. Each card is the reference's (M0
    // the nfet, M1 the pfet), its sizes the layout's measures LVS compared
    // (the device table's, in metres: no `netlist_scale`), one card per
    // extracted device.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{ .{ "LVS_CLEAN_MATCH", ".subckt LVS_INV Y A VSS VDD" }, .{ "LVS_SD_PERMUTE", ".subckt LVS_INV VSS A Y VDD" } }) |case| {
        var n: Netlist = undefined;
        try netlistOf(&n, "LVS_CLEAN_MATCH", try referenceText(arena, case[0]));
        defer n.deinit();
        const text = try n.spice();
        try testing.expectEqualStrings(case[1], lineOf(text, ".subckt").?);
        const devices = &n.run.extracted.devices;
        try testing.expectEqual(devices.len(), n.subckt.deviceCount());
        const per_unit = 1e9 * @as(f64, @floatFromInt(n.run.loaded.grid.dbu_per_um)) / 1000.0;
        for (0..devices.len()) |d| {
            const model = n.run.loaded.strings.resolve(devices.model.items[d]);
            try testing.expectEqualStrings(if (std.mem.eql(u8, model, "nfet_01v8")) "M0" else "M1", n.subckt.device_name.items[d]);
            const card = lineOf(text, n.subckt.device_name.items[d]).?;
            try testing.expect(std.mem.indexOf(u8, card, model) != null);
            const params = devices.paramsOf(@fromBackingInt(@intCast(d)));
            for (params.names, params.measures) |name, measure| {
                if (name != .width and name != .length) continue;
                const want = try std.fmt.allocPrint(arena, " {s}={e}", .{ if (name == .width) "w" else "l", @as(f64, @floatFromInt(measure.length)) / per_unit });
                testing.expect(std.mem.indexOf(u8, card, want) != null) catch |err| {
                    std.debug.print("card {s}, wanted {s}\n", .{ card, want });
                    return err;
                };
            }
        }
    }
}

test "the c cards sum to each net's total capacitance" {
    // Oracle: law, charge conservation in the writer: every C card is one
    // capacitance, counted on each net it touches, so its cards sum per
    // net to the total SPEF's `*D_NET` and DSPF's `*|NET` state
    // (`capacitancePerNetInto`). Read back from the DSPF the same holds.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n: Netlist = undefined;
    try netlistOf(&n, "LVS_CLEAN_MATCH", try referenceText(arena, "LVS_CLEAN_MATCH"));
    defer n.deinit();
    const network = &n.run.outputs.parasitics.?;
    var totals: std.ArrayList(f64) = .empty;
    try network.capacitancePerNetInto(arena, &totals);
    const names = n.subckt.net_name.items;
    const sums = try arena.alloc(f64, names.len);
    @memset(sums, 0);
    var lines = std.mem.splitScalar(u8, try n.spice(), '\n');
    var cards: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != 'C') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        _ = words.next();
        const a = words.next().?;
        const b = words.next().?;
        const value = extract.dspf.spiceNumber(words.next().?).? * 1e15;
        for ([_][]const u8{ a, b }) |node| {
            if (std.mem.eql(u8, node, "0")) continue;
            const net = node[0 .. std.mem.findScalar(u8, node, '#') orelse node.len];
            for (names, 0..) |name, i| if (std.mem.eql(u8, name.?, net)) {
                sums[i] += value;
            };
        }
        cards += 1;
    }
    try testing.expect(cards > 0);
    // Each card is written to 1e-6 fF.
    for (totals.items, 0..) |total, net| try testing.expectApproxEqAbs(total, sums[net], 1e-6 * @as(f64, @floatFromInt(cards)));

    var dspf: std.Io.Writer.Allocating = .init(arena);
    var diag: ex.Diagnostic = .{};
    try ex.dspf.writeDspfSubckt(&dspf.writer, arena, network, &n.subckt, &header, &diag);
    var read: extract.foreign.Read = .empty;
    defer read.deinit(gpa);
    var rdiag: extract.foreign.Diagnostic = .{};
    try extract.dspf.readInto(gpa, dspf.written(), &read, &rdiag);
    var read_totals: std.ArrayList(f64) = .empty;
    defer read_totals.deinit(gpa);
    try read.network.capacitancePerNetInto(gpa, &read_totals);
    var sum_written: f64 = 0;
    var sum_read: f64 = 0;
    for (totals.items) |t| sum_written += t;
    for (read_totals.items) |t| sum_read += t;
    // DSPF writes each card to 1e-6 fF too.
    try testing.expectApproxEqAbs(sum_written, sum_read, 1e-6 * @as(f64, @floatFromInt(cards)));
    // Every device terminal is declared on its node.
    try testing.expect(std.mem.indexOf(u8, dspf.written(), "*|I (") != null);
    try testing.expect(std.mem.indexOf(u8, dspf.written(), "\n* instance section\nM0 ") != null);
}

test "a layout with one swapped net is refused" {
    // Oracle: the reference, edited. LVS_INV's nfet written with its gate
    // and drain swapped (`M0 A Y VSS VSS`) is another circuit: LVS does
    // not match it, and no netlist is written for a layout that does not
    // match.
    var n: Netlist = undefined;
    const swapped = ".subckt LVS_INV Y A VSS VDD\nM0 A Y VSS VSS nfet_01v8\nM1 Y A VDD VDD pfet_01v8\n.ends\n";
    try testing.expectError(error.Refused, netlistOf(&n, "LVS_CLEAN_MATCH", swapped));
    defer n.deinit();
    try testing.expect(std.mem.indexOf(u8, n.why, "does not match its reference") != null);
}

test "without a reference the netlist is the layout's own" {
    // Oracle: docs/usage.md (PEX-017): the cell is the layout's file stem,
    // the pins its labelled nets in ascending net order, each device its
    // family's letter and layout index.
    var n: Netlist = undefined;
    try netlistOf(&n, "LVS_CLEAN_MATCH", null);
    defer n.deinit();
    try testing.expectEqualStrings("LVS_INV", n.subckt.name);
    for ([_][]const u8{ "M0", "M1" }, n.subckt.device_name.items) |want, got| try testing.expectEqualStrings(want, got);
    const pins = n.subckt.pin_net.items;
    for (1..pins.len) |i| try testing.expect(pins[i - 1] < pins[i]);
    const ports = &n.run.extracted.ports;
    for (pins) |p| try testing.expectEqualStrings(n.run.loaded.strings.resolve(ports.nameOf(@fromBackingInt(p)).?), n.subckt.net_name.items[p].?);
}

test "a terminal sits on the node of the region it touches" {
    // Oracle: definition. Each MOS's gate terminal lands on a poly node of
    // its gate net, and its source and drain on diffusion nodes: the
    // layers the deck's `device` line names, never a metal strap above.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var n: Netlist = undefined;
    try netlistOf(&n, "LVS_CLEAN_MATCH", try referenceText(arena_state.allocator(), "LVS_CLEAN_MATCH"));
    defer n.deinit();
    const network = &n.run.outputs.parasitics.?;
    const loaded = &n.run.loaded;
    const layers = &loaded.deck.deck.layers;
    const poly = layers.id(&loaded.strings, "poly").?;
    const diff = layers.id(&loaded.strings, "diff_active").?;
    for (0..n.subckt.deviceCount()) |d| {
        const t = n.subckt.terminalsOf(d);
        // Card order: drain, gate, source.
        for (t.nodes, [_]@TypeOf(poly){ diff, poly, diff }) |node, want| {
            try testing.expect(node != .ground);
            try testing.expectEqual(want, network.node_layer.items[@backingInt(node)]);
        }
    }
}
