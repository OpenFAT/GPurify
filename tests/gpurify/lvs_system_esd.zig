//! Package, die-to-die and system-level ESD (catalog ERC-C12, ERC-C13):
//! hand-derived package and die-to-die cases, and the merge-depth stacks
//! with every die's `n0` a power and `n1` a ground rail held to a search
//! written here over the circuits as drawn. Ported from
//! tests/exhaustive/lvs/system.rs (`RAILS`, `ESD`, `Guard`, `esd_stack`,
//! `reached`, `enumerated_rails` and the ESD tests).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Measurement = @import("check").report.Measurement;
const gpurify = @import("gpurify");
const circuit = @import("lvs_circuit.zig");
const Circuit = circuit.Circuit;
const Dev = circuit.Dev;
const Model = circuit.Model;
const sys = @import("lvs_system.zig");
const Row = sys.Row;
const RunRow = sys.RunRow;
const stacks_ = @import("lvs_system_stacks.zig");
const gpa = testing.allocator;

/// What a die carries: a diode from its pad net up to power, one down from
/// ground, a system-rated bipolar across both, and a rail clamp.
const Guard = struct { up: bool, down: bool, bipolar: bool, clamp: bool };

/// Both rails of one domain, by the dies' own labels.
const rails =
    \\{ "domains": { "core": { "voltage_mv": 1800 } },
    \\  "supplies": [ { "net": "vdd", "domain": "core", "role": "power" },
    \\                { "net": "vss", "domain": "core", "role": "ground" } ] }
;

/// Diodes and the rail clamp guard the die-to-die and package pins; only a
/// bipolar is rated for system-level stress, on the pin `pad`.
const esd =
    \\{ "clamps": ["dpn", "nmos_hvt"], "system_clamps": ["npn"],
    \\  "system_pins": ["pad"] }
;

const full: Guard = .{ .up = true, .down = true, .bipolar = true, .clamp = true };

const bare: Guard = .{ .up = false, .down = false, .bipolar = false, .clamp = false };

// ---- private ----

fn guarded(arena: Allocator, devs: []const Dev, guard: Guard) ![]const Dev {
    var out: std.ArrayList(Dev) = .empty;
    try out.appendSlice(arena, devs);
    if (guard.up) try out.append(arena, Dev.onPins(.d, &.{ 0, 1 }));
    if (guard.down) try out.append(arena, Dev.onPins(.d, &.{ 2, 0 }));
    if (guard.bipolar) try out.append(arena, Dev.onPins(.q, &.{ 0, 2, 1 }));
    if (guard.clamp) try out.append(arena, Dev.mos(.h, 2, 2, 1));
    return out.items;
}

/// A two-die stack: `XT`'s inverter input `sig` reaches the package pin
/// `pad` of the base die `XB` through bump slot 0, the rails through slots
/// 1 and 2; `XB`'s `pad`, `vdd` and `vss` are package bumps (slots 10 to
/// 12). Each die gets its `Guard`'s devices. Returns the dies, the system
/// file and its netlist.
fn esdStack(arena: Allocator, top: Guard, base: Guard, esd_text: []const u8) !struct { []sys.DieSpec, []const u8, []const u8 } {
    const t = try sys.named(arena, &.{ "sig", "vdd", "vss", "out" }, try guarded(arena, &.{ Dev.mos(.n, 0, 2, 3), Dev.mos(.p, 0, 1, 3) }, top));
    const b = try sys.named(arena, &.{ "pad", "vdd", "vss" }, try guarded(arena, &.{}, base));
    const rail_bumps = [_]sys.Bump{ .{ .net = 0, .slot = 0, .face = "bump" }, .{ .net = 1, .slot = 1, .face = "bump" }, .{ .net = 2, .slot = 2, .face = "bump" } };
    const base_bumps = rail_bumps ++ [_]sys.Bump{ .{ .net = 0, .slot = 10, .face = "c4" }, .{ .net = 1, .slot = 11, .face = "c4" }, .{ .net = 2, .slot = 12, .face = "c4" } };
    const dies = try arena.dupe(sys.DieSpec, &.{
        .{ .name = "XT", .layout = try sys.dieLayout(arena, &t, &rail_bumps), .intent = rails },
        .{ .name = "XB", .layout = try sys.dieLayout(arena, &b, &base_bumps), .intent = rails },
    });
    const system = try sys.systemJson(arena, dies, &.{.{ .{ "XT", "bump" }, .{ "XB", "bump" } }}, .{ "XB", "c4" }, esd_text);
    const reference = try sys.systemSpice(arena, &.{ .{ "DT", &t }, .{ "DB", &b } }, &.{ "pad", "vdd", "vss" }, &.{
        .{ "XT", "DT", &.{ "pad", "vdd", "vss", "tout" } },
        .{ "XB", "DB", &.{ "pad", "vdd", "vss" } },
    });
    return .{ dies, system, reference };
}

fn ranEsd(a: Allocator, top: Guard, base: Guard) !sys.Ran {
    const dies, const system, const reference = try esdStack(a, top, base, esd);
    return sys.ran(a, dies, system, reference);
}

/// Rows of `rule` measuring `count(n)` at each of `slots`' centres.
fn counted(a: Allocator, rule: []const u8, slots: []const usize, n: u32) ![]const Row {
    const out = try a.alloc(Row, slots.len);
    for (slots, out) |s, *o| o.* = .{ .rule = rule, .at = sys.slotCentre(s), .measured = .count(n) };
    return out;
}

/// The rail kinds `pad` reaches in `c` through devices of `clamps`, with
/// `supply` bits (1 power, 2 ground) per net: searched here from the
/// definition, over the circuit as drawn.
fn reached(a: Allocator, c: *const Circuit, supply: []const u8, clamps: []const Model, pad: usize) !u32 {
    const seen = try a.alloc(bool, c.nets());
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    try stack.append(a, pad);
    seen[pad] = true;
    var bits: u8 = 0;
    while (stack.pop()) |net| {
        bits |= supply[net];
        if (supply[net] == 0 and net != pad) continue;
        for (c.devs) |*dev| {
            if (std.mem.findScalar(Model, clamps, dev.model) == null) continue;
            if (std.mem.findScalar(usize, dev.pinsOf(), net) == null) continue;
            for (dev.pinsOf()) |next| if (!seen[next]) {
                seen[next] = true;
                try stack.append(a, next);
            };
        }
    }
    return @as(u32, bits & 1) + @as(u32, bits >> 1 & 1);
}

/// Rail bits of a circuit whose `n0` is power and `n1` ground.
fn enumeratedRails(a: Allocator, c: *const Circuit) ![]u8 {
    const out = try a.alloc(u8, c.nets());
    for (out, 0..) |*o, k| o.* = switch (k) {
        0 => 1,
        1 => 2,
        else => 0,
    };
    return out;
}

fn lessMeasurement(_: void, x: Measurement, y: Measurement) bool {
    return x.raw < y.raw;
}

/// The measures of `rule`'s rows, sorted.
fn measuredOf(r: *const sys.Ran, rule: []const u8) ![]Measurement {
    const rows = try r.of(rule);
    const out = try r.arena.alloc(Measurement, rows.len);
    for (rows, out) |row, *o| o.* = row.measured;
    std.mem.sort(Measurement, out, {}, lessMeasurement);
    return out;
}

fn expectMeasures(got: []const Measurement, want: []Measurement) !void {
    std.mem.sort(Measurement, want, {}, lessMeasurement);
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| try testing.expect(g.eql(w));
}

/// A die's intent: `n0` its power rail and, with a second net, `n1` its
/// ground.
fn intent(a: Allocator, c: *const Circuit) ![]const u8 {
    const supplies = if (c.nets() > 1)
        \\{ "net": "n0", "domain": "d", "role": "power" }, { "net": "n1", "domain": "d", "role": "ground" }
    else
        \\{ "net": "n0", "domain": "d", "role": "power" }
    ;
    return std.fmt.allocPrint(a, "{{ \"domains\": {{ \"d\": {{ \"voltage_mv\": 1000 }} }}, \"supplies\": [{s}] }}", .{supplies});
}

test "die to die and package pins need their ESD paths" {
    // Catalog ERC-C12: package, 2.5D and 3D ESD.
    // Oracle: hand-derived from the definitions in system_checks.zig
    // (TR18.0-01 §6.5 and §6.7, JEP196 §3.3 and §6.2). Both dies guarded:
    // every die-to-die bump net of `XT` (3) and of `XB` (3) and every
    // package pin (3) reaches both rails, the netlist matches, and the run
    // passes. `XT` bare but for its rail clamp: its `sig` bump (slot 0)
    // reaches no rail on its own die, though the package pin reaches `XB`'s
    // diodes across the bond. `XB` bare: its nets reach no device on `XB`
    // and are not examined, and the package pin `pad` is protected by
    // `XT`'s diodes across the bond. `XT` with the ground diode and no rail
    // clamp, `XB` bare: nothing joins the rails, so `sig`, `vdd` and `vss`
    // each reach one rail kind, on the die (the bumps in slots 0 to 2) and
    // at the package (slots 10 to 12).
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const both = try ranEsd(a, full, full);
    try testing.expect(try both.matched());
    try sys.expectRows(try both.rows(), &.{});
    try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 6, .violations = 0 }, try both.runOf("system.esd_d2d"));
    try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 3, .violations = 0 }, try both.runOf("system.esd_package"));
    try testing.expect(both.summary.passed());

    var clamp_only = bare;
    clamp_only.clamp = true;
    const top_bare = try ranEsd(a, clamp_only, full);
    try testing.expect(try top_bare.matched());
    try sys.expectRows(try top_bare.of("system.esd_d2d"), try counted(a, "system.esd_d2d", &.{0}, 0));
    try sys.expectRows(try top_bare.of("system.esd_package"), &.{});

    const base_bare = try ranEsd(a, full, bare);
    try testing.expect(try base_bare.matched());
    try sys.expectRows(try base_bare.of("system.esd_d2d"), &.{});
    try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 3, .violations = 0 }, try base_bare.runOf("system.esd_d2d"));
    try sys.expectRows(try base_bare.of("system.esd_package"), &.{});

    var down_only = bare;
    down_only.down = true;
    const one_rail = try ranEsd(a, down_only, bare);
    try sys.expectRows(try one_rail.of("system.esd_d2d"), try counted(a, "system.esd_d2d", &.{ 0, 1, 2 }, 1));
    try sys.expectRows(try one_rail.of("system.esd_package"), try counted(a, "system.esd_package", &.{ 10, 11, 12 }, 1));

    // No intent on any die: every ESD row is skipped, and the run fails.
    const dies, const system, const reference = try esdStack(a, full, full, esd);
    for (dies) |*d| d.intent = null;
    const blind = try sys.ran(a, dies, system, reference);
    for ([_][]const u8{ "system.esd_d2d", "system.esd_package", "system.esd_iec" }) |rule| {
        try testing.expectEqual(RunRow{ .outcome = .{ .skipped = .no_design_intent }, .examined = 0, .violations = 0 }, try blind.runOf(rule));
    }
    try testing.expect(!blind.summary.passed());
}

test "a system pin needs a system-rated clamp" {
    // Catalog ERC-C13: system-level ESD, the part a layout shows.
    // Oracle: hand-derived from the definition of `system.esd_iec` (WP3
    // Part I §1.6 and §6.3.1): the pin `pad` the system names must reach
    // both rails through a system-rated clamp (`npn`). With the bipolar on
    // the base die it does; with only diodes on either die it reaches none
    // (the diodes are not rated), a row at the package bump (slot 10)
    // measured 0, though `system.esd_package` passes. A named pin no package
    // bump carries refuses the assembly.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const rated = try ranEsd(a, bare, full);
    try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 1, .violations = 0 }, try rated.runOf("system.esd_iec"));
    var diodes = full;
    diodes.bipolar = false;
    const unrated = try ranEsd(a, diodes, diodes);
    try sys.expectRows(try unrated.of("system.esd_iec"), try counted(a, "system.esd_iec", &.{10}, 0));
    try sys.expectRows(try unrated.of("system.esd_package"), &.{});
    const dies, const system, const reference = try esdStack(a, full, full,
        \\{ "clamps": ["dpn"], "system_clamps": ["npn"], "system_pins": ["usb"] }
    );
    var diag: gpurify.system.Diagnostic = .{};
    try testing.expectError(error.Assembly, sys.checkDies(a, dies, system, reference, &diag));
    try testing.expect(std.mem.find(u8, diag.why, "system pin usb labels no bump") != null);
}

test "ESD rows agree with a search of the circuits" {
    // Oracle: naive reference. On the merge-depth stacks, every die's `n0`
    // a power and `n1` a ground rail, `nmos` the clamps and `pmos` the
    // system-rated ones, every net of `XA` a package pin and `n0` the
    // system pin: the tool's ESD rows hold exactly the pads a search written
    // here over the circuits as drawn (each die alone for its bonded nets,
    // the flattened stack for the package pins) finds short of both rails,
    // with the measured kinds.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const esd_text =
        \\{ "clamps": ["nmos"], "system_clamps": ["pmos"], "system_pins": ["n0"] }
    ;
    var stacks: std.ArrayList(stacks_.Stack) = .empty;
    try stacks_.stacksInto(a, 12, 0xE5D, &stacks);
    for (stacks.items, 0..) |*stack, k| {
        errdefer std.debug.print("stack{d}\n", .{k});
        var a_bumps: std.ArrayList(sys.Bump) = .empty;
        var b_bumps: std.ArrayList(sys.Bump) = .empty;
        for (stack.bonds, 0..) |b, s| {
            try a_bumps.append(a, .{ .net = b[0], .slot = s, .face = "bump" });
            try b_bumps.append(a, .{ .net = b[1], .slot = s, .face = "bump" });
        }
        for (0..stack.a.nets()) |net| try a_bumps.append(a, .{ .net = net, .slot = 10 + net, .face = "c4" });
        const dies = [_]sys.DieSpec{
            .{ .name = "XA", .layout = try sys.dieLayout(a, &stack.a, a_bumps.items), .intent = try intent(a, &stack.a) },
            .{ .name = "XB", .layout = try sys.dieLayout(a, &stack.b, b_bumps.items), .intent = try intent(a, &stack.b) },
        };
        const system = try sys.systemJson(a, &dies, &.{.{ .{ "XA", "bump" }, .{ "XB", "bump" } }}, .{ "XA", "c4" }, esd_text);
        const reference, _ = try stacks_.stackReference(a, stack, &stack.a, &stack.b);
        const r = try sys.ran(a, &dies, system, reference);

        // Die to die: each die alone, its bonded nets once each.
        var d2d: std.ArrayList(Measurement) = .empty;
        for ([_]*const Circuit{ &stack.a, &stack.b }, 0..) |c, side| {
            var pads: std.ArrayList(usize) = .empty;
            for (stack.bonds) |b| if (std.mem.findScalar(usize, pads.items, b[side]) == null) try pads.append(a, b[side]);
            const supply = try enumeratedRails(a, c);
            for (pads.items) |p| {
                const got = try reached(a, c, supply, &.{.n}, p);
                if (got < 2) try d2d.append(a, .count(got));
            }
        }
        // The package: the stack flattened, rails joined where their nets are.
        const joined = try stacks_.flat(a, &stack.a, &stack.b, stack.bonds);
        const supply = try a.alloc(u8, joined.nets());
        @memset(supply, 0);
        const map = try stacks_.flatNets(a, stack);
        for ([_]*const Circuit{ &stack.a, &stack.b }, 0..) |c, d| for (try enumeratedRails(a, c), 0..) |bits, net| {
            supply[map[d][net]] |= bits;
        };
        var pins: std.ArrayList(usize) = .empty;
        for (0..stack.a.nets()) |net| if (std.mem.findScalar(usize, pins.items, map[0][net]) == null) try pins.append(a, map[0][net]);
        var package: std.ArrayList(Measurement) = .empty;
        for (pins.items) |p| {
            const got = try reached(a, &joined, supply, &.{.n}, p);
            if (got < 2) try package.append(a, .count(got));
        }
        var iec: std.ArrayList(Measurement) = .empty;
        const got_iec = try reached(a, &joined, supply, &.{.p}, map[0][0]);
        if (got_iec < 2) try iec.append(a, .count(got_iec));

        try expectMeasures(try measuredOf(&r, "system.esd_d2d"), d2d.items);
        try expectMeasures(try measuredOf(&r, "system.esd_package"), package.items);
        try expectMeasures(try measuredOf(&r, "system.esd_iec"), iec.items);
        // Every package pin examined.
        try testing.expectEqual(@as(u64, pins.items.len), (try r.runOf("system.esd_package")).examined);
    }
}
