//! The shipped asap7 deck on OpenROAD-flow-scripts' ASAP7 standard cells
//! (tests/fixtures/asap7, from asap7sc7p5t_28): LVS against the cells' own
//! CDL with `nfin` compared exactly, split gates, the PEX refusal of the
//! unsourced middle of line, the sourced metal capacitance, and the
//! supply short between taps.
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const testgen = @import("testgen");
const check = @import("check");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;

/// The fixture cells: inverters at each threshold (one model each), two
/// fingers in parallel (INVx2), a stack (NAND2x1), a stack drawn as split
/// fingers (AOI21x1), a one-fin device and a tied gate (TIEHIx1), two
/// stages (BUFx2).
const cells = [_][]const u8{
    "INVx1_ASAP7_75t_R", "INVx1_ASAP7_75t_L",   "INVx1_ASAP7_75t_SL",  "INVx1_ASAP7_75t_SRAM",
    "INVx2_ASAP7_75t_R", "NAND2x1_ASAP7_75t_R", "AOI21x1_ASAP7_75t_R", "TIEHIx1_ASAP7_75t_R",
    "BUFx2_ASAP7_75t_R",
};

// ---- private ----

fn fixtures() !std.Io.Dir {
    const path = try std.fmt.allocPrint(gpa, "{s}/tests/fixtures/asap7", .{paths.root});
    defer gpa.free(path);
    return std.Io.Dir.cwd().openDir(io, path, .{});
}

/// `cell`'s layout against `reference` (a file in `dir`) under `deck`.
fn lvsOf(a: Allocator, dir: std.Io.Dir, cell: []const u8, reference: []const u8, deck: []const u8) !gpurify.Run {
    var diag: gpurify.RunDiagnostic = .{};
    const layout = try std.fmt.allocPrint(a, "{s}.gds", .{cell});
    return gpurify.run(gpa, a, io, dir, .{ .layout = layout, .deck = deck, .reference = &.{reference} }, .{ .checks = .{ .lvs = true } }, &gpurify.pdks.decks, &diag);
}

/// `cell`'s fixture GDS copied into `tmp`, with `cdl` beside it.
fn staged(a: Allocator, tmp: std.Io.Dir, cell: []const u8, cdl: []const u8) !void {
    var dir = try fixtures();
    defer dir.close(io);
    const name = try std.fmt.allocPrint(a, "{s}.gds", .{cell});
    try tmp.writeFile(io, .{ .sub_path = name, .data = try dir.readFileAlloc(io, name, a, .unlimited) });
    try tmp.writeFile(io, .{ .sub_path = "ref.cdl", .data = cdl });
}

/// The fixture CDL of `cell` with `from` replaced by `to` once.
fn editedCdl(a: Allocator, cell: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    var dir = try fixtures();
    defer dir.close(io);
    const text = try dir.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}.cdl", .{cell}), a, .unlimited);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, from));
    return std.mem.replaceOwned(u8, a, text, from, to);
}

fn hasParameterMismatch(found: []const check.lvs.verdict.Discrepancy) bool {
    for (found) |d| if (d == .parameter_mismatch) return true;
    return false;
}

/// Runs `structure` (one cell, 1 nm grid) under the asap7 deck.
fn drawn(a: Allocator, structure: testgen.gds.Structure, checks: gpurify.Checks) !gpurify.Run {
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeLibrary(a, &.{structure}, &bytes);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "top.gds", .data = bytes.items });
    var diag: gpurify.RunDiagnostic = .{};
    return gpurify.run(gpa, a, io, tmp.dir, .{ .layout = "top.gds", .deck = "asap7" }, .{ .checks = checks }, &gpurify.pdks.decks, &diag);
}

fn violationsOf(r: *const gpurify.Run, id: []const u8) !u32 {
    for (r.outputs.runs.items) |rr| if (std.mem.eql(u8, r.loaded.strings.resolve(rr.rule), id)) {
        try testing.expect(rr.outcome == .ran and rr.examined > 0);
        return rr.violations;
    };
    return error.TestRuleNotRun;
}

/// An n-tap at x 0 and a p-tap at x 300, each ACTIVE under SDT, joined by
/// one LISD (`joined`) or each under its own.
fn taps(joined: bool) [9]struct { u16, u16, [4]i32 } {
    return .{
        .{ 1, 0, .{ -50, -50, 150, 150 } }, .{ 11, 0, .{ 0, 0, 100, 100 } },                                                   .{ 12, 0, .{ -20, -20, 120, 120 } },
        .{ 88, 0, .{ 20, 20, 80, 80 } },    .{ 11, 0, .{ 300, 0, 400, 100 } },                                                 .{ 13, 0, .{ 280, -20, 420, 120 } },
        .{ 88, 0, .{ 320, 20, 380, 80 } },  if (joined) .{ 17, 0, .{ 10, 10, 390, 90 } } else .{ 17, 0, .{ 10, 10, 90, 90 } }, .{ 17, 0, .{ 310, 10, 390, 90 } },
    };
}

test "the asap7 standard cells LVS-match their CDL, nfin compared" {
    // Oracle: the cell library's own schematics (asap7sc7p5t_28's CDL, the
    // netlists its authors signed off the layouts against): every fixture
    // cell matches, and its layout checks are clean.
    var dir = try fixtures();
    defer dir.close(io);
    for (cells) |cell| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try lvsOf(a, dir, cell, try std.fmt.allocPrint(a, "{s}.cdl", .{cell}), "asap7");
        errdefer std.debug.print("{s}: {any}\n", .{ cell, r.outputs.lvs.?.found.items });
        try testing.expect(r.outputs.lvs.?.verdict == .match);
        try testing.expectEqual(@as(u32, 0), r.summary.violations);
    }
}

test "nfin is compared exactly, while w is left out" {
    // Oracle: the deck's own statements. INVx2 draws 6 fins a transistor;
    // a schematic of 6.1 is within the 2 % default but not a fin count, so
    // it mismatches; a schematic w off by 5 % is not compared (`lvs
    // ignore_parameter ... w`), so it still matches.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cell = "INVx2_ASAP7_75t_R";
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try staged(a, tmp.dir, cell, try editedCdl(a, cell, "VSS nmos_rvt w=162.00n l=20n nfin=6", "VSS nmos_rvt w=162.00n l=20n nfin=6.1"));
    const fins = try lvsOf(a, tmp.dir, cell, "ref.cdl", "asap7");
    try testing.expect(fins.outputs.lvs.?.verdict == .mismatch);
    try testing.expect(hasParameterMismatch(fins.outputs.lvs.?.found.items));
    try staged(a, tmp.dir, cell, try editedCdl(a, cell, "VSS nmos_rvt w=162.00n", "VSS nmos_rvt w=170.00n"));
    const width = try lvsOf(a, tmp.dir, cell, "ref.cdl", "asap7");
    try testing.expect(width.outputs.lvs.?.verdict == .match);
}

test "AOI21x1's split fingers match only with split gates" {
    // Oracle: the schematic, against the deck with and without its `lvs
    // split_gates`: AOI21x1 draws its 6-fin A1-A2 stack as two 3-fin stacks
    // whose middle nets nothing joins, where its CDL has one stack.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cell = "AOI21x1_ASAP7_75t_R";
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try staged(a, tmp.dir, cell, try editedCdl(a, cell, ".ENDS", ".ENDS"));
    const deck = try std.mem.replaceOwned(u8, a, gpurify.pdks.asap7, "\nlvs split_gates\n", "\n");
    try testing.expect(deck.len < gpurify.pdks.asap7.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "unsplit.deck", .data = deck });
    const unsplit = try lvsOf(a, tmp.dir, cell, "ref.cdl", "unsplit.deck");
    try testing.expect(unsplit.outputs.lvs.?.verdict == .mismatch);
    const split = try lvsOf(a, tmp.dir, cell, "ref.cdl", "asap7");
    try testing.expect(split.outputs.lvs.?.verdict == .match);
}

test "PEX on the middle of line is refused, naming the layer" {
    // Oracle: the deck's stated blocker: no public source gives LIG (nor
    // the rest of the middle of line) a resistance, so a cell, which draws
    // it, is refused by that layer's name rather than read as 0 ohms.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try fixtures();
    defer dir.close(io);
    var diag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, a, io, dir, .{ .layout = "INVx1_ASAP7_75t_R.gds", .deck = "asap7" }, .{ .checks = .{ .pex = true } }, &gpurify.pdks.decks, &diag);
    try testing.expectEqualStrings("layer LIG: no pex row gives this conductor a positive sheet resistance", r.summary.pex.refused);
    try testing.expect(r.outputs.parasitics == null);
}

test "an M1 wire's capacitance is the sourced fringe over its perimeter" {
    // Oracle: closed form from the deck's source: OpenROAD-flow-scripts'
    // rcx_patterns.rules, "Metal 1 OVER 0" at 0.216 um, 4.99271e-05 fF per
    // nm of wire, halved per um of perimeter: 24.96355 aF/um. A 1000 x 18
    // nm wire has 2.036 um of perimeter: 50.8257878 aF.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try drawn(a, .{ .name = "TOP", .rects = &.{.{ 19, 0, .{ 0, 0, 1000, 18 } }} }, .{ .pex = true });
    var caps: std.ArrayList(f64) = .empty;
    try r.outputs.parasitics.?.capacitancePerNetInto(a, &caps);
    try testing.expectEqual(@as(usize, 1), caps.items.len);
    try testing.expectApproxEqRel(24.96355 * 2.036 / 1000.0, caps.items[0], 1e-9);
}

test "an n-tap and a p-tap on one net short the supplies" {
    // Oracle: construct-from-answer: one LISD over both taps' SDT puts
    // them on one net (SDT joins ACTIVE to LISD, DRM Table 2.1.1); apart,
    // they are two.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const shorted = try drawn(a, .{ .name = "TOP", .rects = &taps(true) }, .{ .erc = true });
    try testing.expectEqual(@as(u32, 1), try violationsOf(&shorted, "supply_short"));
    const apart = try drawn(a, .{ .name = "TOP", .rects = &taps(false) }, .{ .erc = true });
    try testing.expectEqual(@as(u32, 0), try violationsOf(&apart, "supply_short"));
}
