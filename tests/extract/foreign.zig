//! Another tool's SPEF or DSPF read into a network. Ported from
//! crates/extract/src/foreign/tests.rs.
//!
//! Contents: `spef_text`; helpers `readSpef`, `values`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const foreign = extract.foreign;
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;

/// A SPEF as an extractor writes one: picofarads and kilohms, a name map, a
/// driver pin, triplets, and the coupling listed in both nets' sections.
const spef_text =
    \\*SPEF "IEEE 1481-2009"
    \\*DESIGN "top"
    \\*DIVIDER /
    \\*DELIMITER :
    \\*BUS_DELIMITER [ ]
    \\*T_UNIT 1 NS
    \\*C_UNIT 1 PF
    \\*R_UNIT 1 KOHM
    \\*L_UNIT 1 HENRY
    \\
    \\*NAME_MAP
    \\*1 a\[0\]
    \\*2 b
    \\*3 u1
    \\
    \\*PORTS
    \\*1 I
    \\
    \\*D_NET *1 0.0030
    \\*CONN
    \\*I *3:Y O *L 0.001 *D INV
    \\*P *1 I
    \\*N *1:2 *C 1.0 2.0
    \\*CAP
    \\1 *1:2 0.0010:0.0012:0.0014
    \\2 *3:Y 0.0005
    \\3 *1:2 *2:1 0.0008
    \\*RES
    \\1 *3:Y *1:2 0.050
    \\2 *1:2 *1 0.025
    \\*END
    \\
    \\*D_NET *2 0.0011
    \\*CONN
    \\*P *2 O
    \\*CAP
    \\1 *2:1 0.0003
    \\2 *2:1 *1:2 0.0008
    \\*RES
    \\1 *2 *2:1 0.010
    \\*END
    \\
;

// ---- private ----

fn readSpef(text: []const u8, out: *foreign.Read, diag: *foreign.Diagnostic) foreign.Error!void {
    return extract.spef.readInto(gpa, text, out, diag);
}

/// Every element of `kind`, in element order.
fn values(n: *const ParasiticNetwork, kind: extract.network.Kind, out: *std.ArrayList(f64)) !void {
    out.clearRetainingCapacity();
    for (n.kind.items, n.value.items) |k, v| {
        if (k == kind) try out.append(gpa, v);
    }
}

fn totals(n: *const ParasiticNetwork, out: *std.ArrayList(f64)) !void {
    try n.capacitancePerNetInto(gpa, out);
}

fn replaced(from: []const u8, to: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, spef_text, from, to);
}

test "a spef reads in ff and ohms with its names mapped" {
    // Oracle: hand-derived from IEEE 1481's units and forms: 1 PF is 1000 fF
    // and 1 KOHM 1000 Ω; `*1` reads as the mapped name with its escapes
    // removed; a triplet reads as its middle value; the coupling listed in
    // both nets is one 0.8 fF capacitor, so `a[0]` totals 1.2 + 0.5 + 0.8 =
    // 2.5 fF and `b` 0.3 + 0.8 = 1.1 fF; the driver is the output pin `u1:Y`,
    // 50 + 25 = 75 Ω from the port, its farthest node.
    var read: foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: foreign.Diagnostic = .{};
    try readSpef(spef_text, &read, &diag);
    try testing.expectEqual(2, read.nameCount());
    try testing.expectEqualStrings("a[0]", read.name(0));
    try testing.expectEqualStrings("b", read.name(1));
    var got: std.ArrayList(f64) = .empty;
    defer got.deinit(gpa);
    try totals(&read.network, &got);
    try testing.expectApproxEqAbs(2.5, got.items[0], 1e-9);
    try testing.expectApproxEqAbs(1.1, got.items[1], 1e-9);
    try values(&read.network, .coupling_cap, &got);
    try testing.expectEqual(1, got.items.len);
    try values(&read.network, .resistance, &got);
    try testing.expectEqual(3, got.items.len);
    var fifty = false;
    for (got.items) |r| fifty = fifty or @abs(r - 50.0) < 1e-9;
    try testing.expect(fifty);
    var both: extract.compare.Comparison = .empty;
    defer both.deinit(gpa);
    try extract.compare.compareInto(gpa, &read.network, &read.network, &both);
    try testing.expectApproxEqAbs(75.0, both.resistance.reference.items[0], 1e-9);
}

test "a reduced net and an orphan node are refused" {
    // Oracle: the module's refusal list: a section before any `*D_NET` is
    // refused at its line (the fuzz crasher
    // `fuzz/regressions/spef/conn_before_any_net`), a reduced net is not
    // read, and a node no net owns is refused at its line.
    var read: foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: foreign.Diagnostic = .{};
    const headless = try std.mem.replaceOwned(u8, gpa, spef_text, "*D_NET *1", "*D_NOT *1");
    defer gpa.free(headless);
    try testing.expectError(error.SectionBeforeNet, readSpef(headless, &read, &diag));
    try testing.expect(diag.line > 0);
    const reduced = try replaced("*D_NET *2", "*R_NET *2");
    defer gpa.free(reduced);
    try testing.expectError(error.Unsupported, readSpef(reduced, &read, &diag));
    try testing.expectEqualStrings("*R_NET", diag.token);
    const orphan = try replaced("2 *2:1 *1:2 0.0008", "2 *2:1 zz:9 0.0008");
    defer gpa.free(orphan);
    try testing.expectError(error.OrphanNode, readSpef(orphan, &read, &diag));
    try testing.expectEqualStrings("zz:9", diag.token);
    try testing.expect(diag.line > 0);
}

test "a dspf reads its cards with their suffixes" {
    // Oracle: hand-derived: SPICE cards with scale suffixes (`f`, `k`, `p`)
    // and a `+` continuation; a coupling card between two nets' nodes;
    // ground named by `*|GROUND_NET`. `a` totals 200 fF + 100 fF, `b` the
    // 100 fF coupling; 1.5 kΩ and 3 pH read as written.
    const text = "*|DSPF 1.5\n*|DELIMITER :\n*|GROUND_NET VSS\n.SUBCKT top a b\n" ++
        "*|NET a 0.3PF\n*|P (a I 0.0 0 0)\n*|S (a:1 1 2)\n" ++
        "*|NET b 0.1PF\n*|I (u2:A u2 A I 0.0 0 0)\n" ++
        "R1 a a:1 1.5k\nC1 a:1 VSS 200f\nC2 a:1\n+ u2:A 0.1p\nL1 a a:1 3p\nK1 L1 L2 0.5\n" ++
        "Xu2 a b INV\n.ENDS\n";
    var read: foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: foreign.Diagnostic = .{};
    try extract.dspf.readInto(gpa, text, &read, &diag);
    try testing.expectEqualStrings("a", read.name(0));
    try testing.expectEqualStrings("b", read.name(1));
    var got: std.ArrayList(f64) = .empty;
    defer got.deinit(gpa);
    try totals(&read.network, &got);
    try testing.expectApproxEqAbs(300.0, got.items[0], 1e-9);
    try testing.expectApproxEqAbs(100.0, got.items[1], 1e-9);
    try values(&read.network, .resistance, &got);
    try testing.expectApproxEqAbs(1500.0, got.items[0], 1e-9);
    try values(&read.network, .inductance, &got);
    try testing.expectApproxEqAbs(3.0, got.items[0], 1e-9);
}

test "two files meet on the union of their names" {
    // Oracle: construct-from-answer: a file put on the union of two files'
    // names keeps one net id per name, in order.
    var read: foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: foreign.Diagnostic = .{};
    try readSpef(spef_text, &read, &diag);
    var on: ParasiticNetwork = .empty;
    defer on.deinit(gpa);
    try read.onNamesInto(gpa, &.{ "a[0]", "b", "c" }, &on);
    try testing.expectEqual(0, on.node_net.items[0]);
    try testing.expectEqual(1, on.node_net.items[on.node_net.items.len - 1]);
}

test "a spef name is unescaped exactly once" {
    // Oracle: IEEE 1481-2009 §9.2.2: `\` escapes the next character, so
    // `a\\b` names `a\b`, and its `*CONN` node `a\\b:1` is the `*CAP` node
    // of the same spelling. Rust unescaped a net or `*CONN` name twice (once
    // resolving, once declaring), reading the net `ab` and losing the node
    // to the element's own net.
    const text = "*SPEF \"IEEE 1481-2009\"\n*C_UNIT 1 FF\n*D_NET a\\\\b 1\n*CONN\n*P a\\\\b:1 I\n*CAP\n1 a\\\\b:1 0.5\n*END\n";
    var read: foreign.Read = .empty;
    defer read.deinit(gpa);
    var diag: foreign.Diagnostic = .{};
    try readSpef(text, &read, &diag);
    try testing.expectEqualStrings("a\\b", read.name(0));
    try testing.expectEqual(1, read.network.nodeCount());
}
