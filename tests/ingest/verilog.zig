//! Structural Verilog over a SPICE cell library (catalog LVS-075): each
//! construct of the subset against the SPICE hierarchy that states the same
//! connections, and the refusals. Ported from crates/ingest/tests/verilog.rs.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const nl = ingest.netlist;
const Netlist = nl.Netlist;
const StrTable = geom.StrTable;
const gpa = testing.allocator;

/// The cell library: an inverter `INV A Y VDD VSS` and a cell with a bus
/// port, `REG D[1] D[0] Q VDD VSS`.
const cells =
    \\.subckt INV A Y VDD VSS
    \\M0 Y A VSS VSS nfet
    \\M1 Y A VDD VDD pfet
    \\.ends
    \\.subckt REG D[1] D[0] Q VDD VSS
    \\M0 Q D[1] VSS VSS nfet
    \\M1 Q D[0] VDD VDD pfet
    \\.ends
    \\
;

/// A flattened netlist as text: port names in order, and every device as
/// its model then terminal net names, sorted.
const Flat = struct {
    arena: std.heap.ArenaAllocator,
    ports: []const []const u8,
    devices: []const []const u8,

    fn deinit(f: *Flat) void {
        f.arena.deinit();
    }

    fn expectSame(f: *const Flat, g: *const Flat) !void {
        try testing.expectEqual(f.ports.len, g.ports.len);
        for (f.ports, g.ports) |a, b| try testing.expectEqualStrings(a, b);
        try testing.expectEqual(f.devices.len, g.devices.len);
        for (f.devices, g.devices) |a, b| try testing.expectEqualStrings(a, b);
    }
};

// ---- private ----

/// `n` flattened below `top`.
fn flat(n: *const Netlist, top: ?nl.SubcktId, strings: *StrTable, diag: *nl.Diagnostic) nl.Error!Flat {
    var f: Flat = .{ .arena = .init(gpa), .ports = &.{}, .devices = &.{} };
    errdefer f.arena.deinit();
    const a = f.arena.allocator();
    var flattened = try nl.flattenTop(gpa, n, top.?, strings, diag);
    defer flattened.deinit(gpa);
    const ports = try a.alloc([]const u8, flattened.port_net.items.len);
    for (flattened.port_net.items, ports) |p, *s| s.* = try a.dupe(u8, strings.resolve(flattened.net_name.items[@backingInt(p)]));
    const devices = try a.alloc([]const u8, flattened.device_model.items.len);
    for (devices, 0..) |*d, row| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, strings.resolve(flattened.device_model.items[row]));
        for (flattened.terminalsOf(@intCast(row))) |t| try text.print(a, " {s}", .{strings.resolve(flattened.net_name.items[@backingInt(t)])});
        d.* = text.items;
    }
    std.mem.sort([]const u8, devices, {}, lessText);
    f.ports = ports;
    f.devices = devices;
    return f;
}

fn lessText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `text` read over the library, flattened.
fn fromVerilog(text: []const u8, diag: *nl.Diagnostic) nl.Error!Flat {
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var n = try nl.readSpice(gpa, cells, &strings, &.{}, diag);
    defer n.deinit(gpa);
    const rows = try nl.readVerilogInto(gpa, &.{text}, &strings, &n, diag);
    return flat(&n, try n.topIn(gpa, rows[0], rows[1]), &strings, diag);
}

/// `top`, SPICE `X` cards over the library, flattened.
fn fromSpice(top: []const u8) !Flat {
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: nl.Diagnostic = .{};
    const text = try std.mem.concat(gpa, u8, &.{ cells, top });
    defer gpa.free(text);
    var n = try nl.readSpice(gpa, text, &strings, &.{}, &diag);
    defer n.deinit(gpa);
    return flat(&n, try n.topIn(gpa, 2, n.subcktCount()), &strings, &diag);
}

/// The error `text` is refused with, or null when it reads.
fn refusal(text: []const u8) ?nl.Error {
    var diag: nl.Diagnostic = .{};
    var f = fromVerilog(text, &diag) catch |err| return err;
    f.deinit();
    return null;
}

fn wrap(body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "module TOP (a, y, VDD, VSS);\n{s}\nendmodule\n", .{body});
}

test "a Verilog top flattens as its SPICE twin" {
    // Oracle: the SPICE hierarchy stating the same connections (IEEE
    // 1364-2005 §12.3.6: a port connected by name takes that connection, by
    // position the one in its place). `assign y2 = y` makes one net, named by
    // the lesser name, so the twin's `y2` reads `y`.
    var diag: nl.Diagnostic = .{};
    var got = try fromVerilog(
        \\// a comment
        \\(* top *)
        \\module TOP (a, y, y2, d, VDD, VSS);
        \\  input a; output y, y2; input [1:0] d;
        \\  inout VDD, VSS;
        \\  wire m;
        \\  INV u1 (.Y(m), .VDD(VDD), .A(a), .VSS(VSS));
        \\  INV u2 (m, y, VDD, VSS); /* in order */
        \\  REG r1 (.D(d), .Q(q), .VDD(VDD), .VSS(VSS));
        \\  assign y2 = y;
        \\endmodule
        \\
    , &diag);
    defer got.deinit();
    var want = try fromSpice(
        \\.subckt TOP a y y d[1] d[0] VDD VSS
        \\Xu1 a m VDD VSS INV
        \\Xu2 m y VDD VSS INV
        \\Xr1 d[1] d[0] q VDD VSS REG
        \\.ends
        \\
    );
    defer want.deinit();
    try got.expectSame(&want);
}

test "ports in place, concatenations and open ports read as written" {
    // Oracle: IEEE 1364-2005 (ports declared in place §12.3.4; a part select
    // and a concatenation §5.2.1, §5.1.14; an escaped identifier §3.7.1; an
    // unconnected port §12.3.6) against the SPICE twin.
    var diag: nl.Diagnostic = .{};
    var got = try fromVerilog(
        \\module TOP (input [1:0] d, output \q , inout VDD, VSS);
        \\  wire [1:0] x;
        \\  REG r1 (.D({d[0], d[1]}), .Q(x[1]), .VDD(VDD), .VSS(VSS));
        \\  INV u1 (.A(x[1]), .Y(q), .VDD(VDD), .VSS());
        \\endmodule
        \\
    , &diag);
    defer got.deinit();
    var want = try fromSpice(
        \\.subckt TOP d[1] d[0] q VDD VSS
        \\Xr1 d[0] d[1] x[1] VDD VSS REG
        \\Xu1 x[1] q VDD u1.VSS INV
        \\.ends
        \\
    );
    defer want.deinit();
    try got.expectSame(&want);
}

test "what the subset leaves out is refused" {
    // Oracle: the module docs' refusals, each stated by construction: a
    // directive, a constant, a parameter, an instance array, behavioural code,
    // a cell defined nowhere, a port the cell lacks, a bus of the wrong width,
    // a port connected twice, too few ordered connections, and a module named
    // as a cell it does not merely declare; an empty stub declaring a library
    // cell is read.
    const cases = [_]struct { []const u8, bool, nl.Error }{
        .{ "`ifdef USE_POWER_PINS\n`endif", false, error.Unsupported },
        .{ "INV u1 (.A(1'b0), .Y(y), .VDD(VDD), .VSS(VSS));", true, error.Unsupported },
        .{ "INV #(1) u1 (a, y, VDD, VSS);", true, error.Unsupported },
        .{ "INV u1 [1:0] (a, y, VDD, VSS);", true, error.Unsupported },
        .{ "reg r;", true, error.Unsupported },
        .{ "always @(a) y = a;", true, error.Unsupported },
        .{ "NAND u1 (a, y, VDD, VSS);", true, error.UndefinedSubckt },
        .{ "INV u1 (.B(a), .Y(y), .VDD(VDD), .VSS(VSS));", true, error.Unexpected },
        .{ "wire [2:0] w;\nREG r1 (.D(w), .Q(y), .VDD(VDD), .VSS(VSS));", true, error.Unexpected },
        .{ "INV u1 (.A(a), .A(y), .VDD(VDD), .VSS(VSS));", true, error.Unexpected },
        .{ "INV u1 (a, y, VDD);", true, error.TerminalCount },
    };
    for (cases) |c| {
        const text = if (c[1]) try wrap(c[0]) else try gpa.dupe(u8, c[0]);
        defer gpa.free(text);
        const got = refusal(text);
        if (got == null or got.? != c[2]) {
            std.debug.print("{s}: {?}\n", .{ text, got });
            return error.TestUnexpectedResult;
        }
    }
    const top = try wrap("INV u1 (a, y, VDD, VSS);");
    defer gpa.free(top);
    const redefined = try std.mem.concat(gpa, u8, &.{ "module INV (A, Y, VDD, VSS);\nassign Y = A;\nendmodule\n", top });
    defer gpa.free(redefined);
    try testing.expectEqual(@as(?nl.Error, error.Redefined), refusal(redefined));
    const stub = try std.mem.concat(gpa, u8, &.{ "module INV (A, Y, VDD, VSS);\ninput A;\nendmodule\n", top });
    defer gpa.free(stub);
    var diag: nl.Diagnostic = .{};
    var f = try fromVerilog(stub, &diag);
    defer f.deinit();
    try testing.expectEqual(2, f.devices.len);
}
