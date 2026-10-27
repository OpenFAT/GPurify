//! ERC-E14 through the real reader and engine: a drawn VDD rail with three
//! resistor loads, its reference netlist, a design intent and an
//! `espice-emir/1` file the loads' currents come from, placed on the layout
//! through LVS (gpurify/currents.zig). The EM findings against the closed
//! form of the tapped wire, each named by the instance loading it most; and
//! the refusals, each naming its cause. The grid laws themselves are
//! tests/check/erc/simulated_currents.zig's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Fixture = harness.Fixture;
const Layout = harness.Layout;

/// tests/check/erc/closed_form.zig's process (met1 0.125 Ω/sq), poly text
/// naming the loads' far ends, an LVS tolerance, and one EM row that every
/// loaded met1 segment breaks.
const deck =
    \\grid 1nm
    \\layer met1 = gds(1, 0)
    \\layer via1 = gds(2, 0)
    \\layer met2 = gds(3, 0)
    \\layer poly = gds(4, 0)
    \\layer mk   = gds(5, 0)
    \\layer met1_text = gds(11, 0)
    \\layer poly_text = gds(14, 0)
    \\connect conductors [met1, met2, poly]
    \\connect touch_within_layer
    \\connect via via1 [met1, met2]
    \\connect label met1_text names met1
    \\connect label poly_text names poly
    \\device resistor mk model "load" terminals [met1, poly]
    \\pex met1 thickness 100nm height 100nm sheet 0.125ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex via1 thickness 100nm height 200nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex met2 thickness 100nm height 300nm sheet 0.0625ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex poly thickness 100nm height 50nm sheet 8ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\lvs tolerance default relative 2%
    \\rule em em_current_density(met1; max_density: 1uA/um, max_current_per_cut: 1000uA, narrow: none)
    \\rule ir ir_drop()
    \\
;

/// VDD at 1.8 V, a 3 mA budget the simulated currents replace, a 0.5 mV
/// drop limit every load breaks.
const intent =
    \\{"temperature_c":85,"domains":{"core":{"voltage_mv":1800}},"supplies":[{"net":"VDD","domain":"core","role":"power"}],
    \\ "limits":[{"net":"VDD","budget_current_ua":3000,"max_drop_mv":0.5}]}
;

// ---- private ----

/// The loads at 12, 14 and 18 µm on a 20 µm × 1 µm rail fed at its
/// centre; load `x`'s far end is a poly stub named `n<µm>` unless
/// `unnamed` is it.
fn rail(arena: Allocator, loads: []const i64, unnamed: ?i64) !Layout {
    var l: Layout = .{};
    try l.rect(arena, "met1", 0, 0, 20_000, 1000);
    try l.label(arena, "met1_text", 5000, 500, "VDD");
    for (loads) |x| {
        try l.rect(arena, "mk", x - 100, -100, x + 100, 100);
        try l.rect(arena, "poly", x - 100, -400, x + 100, -50);
        if (unnamed != x) try l.label(arena, "poly_text", x, -225, try std.fmt.allocPrint(arena, "n{d}", .{@divTrunc(x, 1000)}));
    }
    return l;
}

/// The schematic: three loads from VDD to their own far ends, `n18` a
/// port unless the layout leaves it unnamed.
fn reference(n18_port: bool) []const u8 {
    const body = "R12 VDD n12 load\nR14 VDD n14 load\nR18 VDD n18 load\n.ends\n";
    return if (n18_port) ".subckt top VDD n12 n14 n18\n" ++ body else ".subckt top VDD n12 n14\n" ++ body;
}

/// A testbench's current file: the reference placed as `xdut`, each load
/// drawing `ua` µA in at VDD and out at its far end, and one testbench
/// device (`rbias`) outside the scope. `rename` replaces `r18`.
fn currents(arena: Allocator, ua: [3]f64, rename: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\{"format": "espice-emir/1", "deck": "tb.sp", "variant": {"kind": "nominal"}, "analysis": "tran", "temp": 125,
        \\ "window": [1e-06, 3e-06], "em_recovery": 1, "terminals": [
        \\  {"instance": "rbias", "model": "r", "terminal": "p", "net": "vb", "avg": 1e-3, "em_avg": 1e-3, "rms": 1e-3, "peak": 1e-3}
    );
    for ([_][]const u8{ "r12", "r14", rename orelse "r18" }, [_][]const u8{ "n12", "n14", "n18" }, ua) |name, far, u| {
        const a = u * 1e-6;
        try out.print(arena, ",\n  {{\"instance\": \"xdut.{s}\", \"model\": \"load\", \"terminal\": \"p\", \"net\": \"vdd\", \"avg\": {e}, \"em_avg\": {e}, \"rms\": {e}, \"peak\": {e}}}", .{ name, a, a, a, a });
        try out.print(arena, ",\n  {{\"instance\": \"xdut.{s}\", \"model\": \"load\", \"terminal\": \"n\", \"net\": \"xdut.{s}\", \"avg\": {e}, \"em_avg\": {e}, \"rms\": {e}, \"peak\": {e}}}", .{ name, far, -a, a, a, a });
    }
    try out.appendSlice(arena, "\n ], \"sources\": []}\n");
    return out.items;
}

/// One ERC run of `layout` against the reference with `file`'s currents.
fn ercWith(arena: Allocator, layout: Layout, file: []const u8, ref: ?[]const u8) !gpurify.Run {
    var f: Fixture = .init("erc/currents", &.{"ERC-E14"}, deck, .{ .erc = true });
    f.layout = layout;
    f.intent = intent;
    f.currents = file;
    f.reference = ref;
    return harness.run(arena, &f);
}

/// The ERC stage's refusal; fails unless it refused saying `cause`.
fn expectRefused(ran: *const gpurify.Run, cause: []const u8) !void {
    switch (ran.summary.erc) {
        .refused => |why| if (std.mem.indexOf(u8, why, cause) == null) {
            std.debug.print("refused: {s}\nwanted: {s}\n", .{ why, cause });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("erc: {any}, wanted refused: {s}\n", .{ ran.summary.erc, cause });
            return error.TestUnexpectedResult;
        },
    }
}

test "simulated currents placed through LVS load each segment with the currents beyond it" {
    // Oracle: closed form (tests/check/erc/simulated_currents.zig's tapped
    // wire): taps at 12, 14 and 18 µm drawing 1000, 1500 and 500 µA from a
    // pad at 10 µm load the segments with 3000, 2000 and 500 µA, the first
    // two loaded most by r14 and the last by r18, and drop the taps 0.75,
    // 1.25 and 1.5 mV below the pad. The file names the
    // devices under a testbench's `xdut`, lowercase against the
    // reference's `R12`; the testbench's own `rbias` is left out. A
    // placement that swapped the resistors' interchangeable ends sources
    // VDD instead (no drop), and one that put r14's current at r18 fails
    // the numbers or the names.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ran = try ercWith(arena, try rail(arena, &.{ 12_000, 14_000, 18_000 }, null), try currents(arena, .{ 1000.0, 1500.0, 500.0 }, null), reference(true));
    if (ran.summary.erc != .ran) {
        std.debug.print("erc: {any}\n", .{ran.summary.erc});
        return error.TestUnexpectedResult;
    }
    const strings = &ran.loaded.strings;
    const v = &ran.outputs.violations;
    const want = [_]struct { x: i64, ua: f64, by: []const u8 }{
        .{ .x = 10_000, .ua = 3000.0, .by = "xdut.r14" },
        .{ .x = 12_000, .ua = 2000.0, .by = "xdut.r14" },
        .{ .x = 14_000, .ua = 500.0, .by = "xdut.r18" },
    };
    const drops = [_]struct { x: i64, mv: f64 }{ .{ .x = 12_000, .mv = 0.75 }, .{ .x = 14_000, .mv = 1.25 }, .{ .x = 18_000, .mv = 1.5 } };
    var seen: u32 = 0;
    var dropped: u32 = 0;
    for (0..v.len()) |i| {
        const row = v.get(@intCast(i));
        const rule = strings.resolve(row.rule);
        if (std.mem.eql(u8, rule, "ir")) {
            const d = for (drops) |d| {
                if (d.x == row.at.x) break d;
            } else return error.TestUnexpectedResult;
            try testing.expectApproxEqRel(d.mv, row.measured.float(), 1e-9);
            dropped += 1;
            continue;
        }
        if (std.mem.eql(u8, rule, "erc.budget_unused")) {
            try testing.expectApproxEqRel(@as(f64, 3000.0), row.measured.float(), 1e-9);
            continue;
        }
        if (!std.mem.eql(u8, rule, "em")) continue;
        const w = for (want) |w| {
            if (w.x == row.at.x) break w;
        } else return error.TestUnexpectedResult;
        try testing.expectApproxEqRel(w.ua, row.measured.float(), 1e-9);
        try testing.expectEqualStrings(w.by, strings.resolve(v.loadOf(@intCast(i)).?.instance));
        seen += 1;
    }
    try testing.expectEqual(3, seen);
    try testing.expectEqual(3, dropped);
}

test "a layout that does not match its reference refuses the currents" {
    // Oracle: the refusal contract (catalog ERC-E14, docs/usage.md): the
    // layout draws no load at 18 µm, so VDD carries two loads against the
    // reference's three and LVS reports a mismatch; any mismatch refuses,
    // before a current is placed on the loads LVS could still pair.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ran = try ercWith(arena, try rail(arena, &.{ 12_000, 14_000 }, null), try currents(arena, .{ 1000.0, 1500.0, 500.0 }, null), reference(true));
    try expectRefused(&ran, "--currents: the layout does not match its reference (LVS found");
}

test "a current file of another netlist is refused" {
    // Oracle: the refusal contract: a file whose `xdut` holds an `r99` the
    // reference does not, and no `r18`, is another netlist's.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ran = try ercWith(arena, try rail(arena, &.{ 12_000, 14_000, 18_000 }, null), try currents(arena, .{ 1000.0, 1500.0, 500.0 }, "r99"), reference(true));
    try expectRefused(&ran, "xdut.r99 is no device of the reference");
}

test "currents without a reference are refused" {
    // Oracle: the refusal contract: no reference, no LVS, no placement.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ran = try ercWith(arena, try rail(arena, &.{ 12_000, 14_000, 18_000 }, null), try currents(arena, .{ 1000.0, 1500.0, 500.0 }, null), null);
    try expectRefused(&ran, "--currents needs the reference netlist");
}

test "a terminal on a net with no port to return to is refused" {
    // Oracle: the refusal contract: R18's far end is an unlabelled net
    // (no port) carrying only its -500 µA, which does not balance, so the
    // current has nowhere to return.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ran = try ercWith(arena, try rail(arena, &.{ 12_000, 14_000, 18_000 }, 18_000), try currents(arena, .{ 1000.0, 1500.0, 500.0 }, null), reference(false));
    try expectRefused(&ran, "xdut.r18 n is on a net with no label to return its current through");
}
