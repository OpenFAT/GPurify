//! The `spice` level against a direct ngspice run (testing-plan §4 L6,
//! ledger F3), ported from tests/liberty.rs `ngspice_differential_inverter`.
//! Built only with `-Dngspice-tests=true`, and then it fails, never skips,
//! when `ngspice` is not on `PATH`.
//!
//! GPurify characterises the corpus inverter on its extracted RC netlist.
//! The reference takes that netlist, the `.subckt` GPurify wrote, and
//! nothing else from it: its own batch deck per table point with the
//! documented stimulus (a linear ramp whose full swing takes `slew / 0.6`,
//! the input held at its old level beforehand), its own `.meas` of the
//! documented definitions (50 % to 50 % delay, 20 %–80 % transition) at a
//! fixed 0.5 ps maximum step, and a DC operating point per input state for
//! leakage, `Σ V·(−I)` over the supplies.
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const gpurify = @import("gpurify");
const liberty = gpurify.liberty;
const corpus = @import("liberty.zig");

/// BSIM4 at its defaults behind three-terminal subcircuits of the deck's
/// model names (the deck's MOS have no bulk): the nfet's bulk on ground, the
/// pfet's on its source, the supply. Any model would do: both runs simulate
/// the same netlist with the same models.
const models = [_][]const u8{
    ".model nch nmos level=54 version=4.5",
    ".model pch pmos level=54 version=4.5",
    ".subckt nfet_01v8 d g s w=1 l=1 nf=1 ad=0 as=0 pd=0 ps=0 sa=0 sb=0",
    "m0 d g s 0 nch w={w} l={l} ad={ad} as={as} pd={pd} ps={ps}",
    ".ends",
    ".subckt pfet_01v8 d g s w=1 l=1 nf=1 ad=0 as=0 pd=0 ps=0 sa=0 sb=0",
    "m0 d g s s pch w={w} l={l} ad={ad} as={as} pd={pd} ps={ps}",
    ".ends",
};

const slews = [_]f64{ 0.05, 0.5 };

const loads = [_]f64{ 0.002, 0.02 };

/// A delay or transition within 0.5 % plus 0.1 ps (ns): GPurify's 0.03 %
/// against a 0.1 ps-step run, plus the runs' different edge times and step
/// sequences; the 0.1 ps is for a delay near zero.
const edge_tolerance = [2]f64{ 5e-3, 1e-4 };

// ---- private ----

/// The values of the first table named `group` in `lib`, row-major.
fn libTable(arena: Allocator, lib: []const u8, group: []const u8) ![]f64 {
    const start = std.mem.indexOf(u8, lib, try arena.print("{s} (", .{group})) orelse return error.TestNoTable;
    const rest = lib[start..];
    const from = std.mem.indexOf(u8, rest, "values(").? + 7;
    const body = rest[from .. from + std.mem.indexOf(u8, rest[from..], ");").?];
    var out: std.ArrayList(f64) = .empty;
    var words = std.mem.tokenizeAny(u8, body, "\",\\ \n\t");
    while (words.next()) |w| try out.append(arena, try std.fmt.parseFloat(f64, w));
    return out.items;
}

/// The `value` of the `leakage_power` group whose `when` is `when`, nW.
fn libLeakage(arena: Allocator, lib: []const u8, when: []const u8) !f64 {
    var groups = std.mem.splitSequence(u8, lib, "leakage_power () {");
    _ = groups.next();
    const needle = try arena.print("when : \"{s}\";", .{when});
    while (groups.next()) |g| {
        if (std.mem.indexOf(u8, g, needle) == null) continue;
        const at = std.mem.indexOf(u8, g, "value : ").? + 8;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, g[at .. at + std.mem.indexOfScalar(u8, g[at..], ';').?], " "));
    }
    return error.TestNoLeakage;
}

/// Runs `text` as `name` in ngspice batch mode in `dir`; the value printed
/// as `key = value` (`.meas` and `print` both write that form).
fn simulate(arena: Allocator, dir: std.Io.Dir, name: []const u8, text: []const u8, keys: []const []const u8, out: []f64) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
    const ran = try std.process.run(arena, testing.io, .{ .argv = &.{ "ngspice", "-b", name }, .cwd = .{ .dir = dir } });
    for (keys, out) |key, *v| {
        v.* = blk: {
            var lines = std.mem.splitScalar(u8, ran.stdout, '\n');
            while (lines.next()) |line| {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
                var words = std.mem.tokenizeAny(u8, line[eq + 1 ..], " \t");
                break :blk std.fmt.parseFloat(f64, words.next() orelse continue) catch continue;
            }
            std.debug.print("{s} not measured in {s}:\n{s}\n", .{ key, name, ran.stdout });
            return error.TestNotMeasured;
        };
    }
}

/// 1 when `got` is off `want` by more than `relative · |want| + absolute`.
fn check(what: []const u8, slew: f64, load: f64, got: f64, want: f64, tolerance: [2]f64) usize {
    const off = @abs(got - want) > tolerance[0] * @abs(want) + tolerance[1];
    std.debug.print("{s} at slew {d} ns, load {d} pF: GPurify {e}, ngspice {e}, {d:.4} %{s}\n", .{ what, slew, load, got, want, (got - want) / want * 100.0, if (off) "  BROKEN" else "" });
    return @intFromBool(off);
}

test "ngspice differential: the inverter's spice-level delay, transition and leakage" {
    // Oracle: differential against ngspice, run directly on the netlist
    // GPurify wrote with its own stimulus and `.meas` of the documented
    // definitions, within 0.5 % + 0.1 ps on every delay and transition and
    // 1e-4 on each leakage (the same DC operating point at reltol 1e-6).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extra = try a.print(
        \\, "arcs": [{{"from": "LVS_INV_n5", "to": "LVS_INV_n4", "kind": "combinational",
        \\   "cases": [{{"vectors": [{{"LVS_INV_n5": "0"}}], "edge": "rise", "output": "fall"}},
        \\             {{"vectors": [{{"LVS_INV_n5": "1"}}], "edge": "fall", "output": "rise"}}]}}],
        \\ "characterization": {{"slews_ns": [0.05, 0.5], "loads_pf": [0.002, 0.02]}},
        \\ "simulator": {{"workers": 1}}
    , .{});
    var macro = try corpus.specWith(a, corpus.pins, extra);
    var corner = macro.corners[0];
    corner.name = "tt";
    corner.models = &models;
    macro.corners = try a.dupe(liberty.spec.CornerSpec, &.{corner});
    const loaded = try corpus.loadInverter(a, false);
    var ediag: gpurify.ExtractDiagnostic = .none;
    const extracted = try gpurify.extract(a, &loaded, &ediag);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: liberty.Diagnostic = .{};
    const generated = liberty.generate(a, &loaded, &extracted, .{
        .spec = &macro,
        .accuracy = .spice,
        .work = "work",
        .tool_version = "test",
        .env = .{ .gpa = testing.allocator, .io = testing.io, .dir = tmp.dir },
    }, &diag) catch |err| {
        // The simulator's own words and the deck it read, not a path on a
        // machine that is gone by the time anyone reads the report.
        const deck = tmp.dir.readFileAlloc(testing.io, "work/LVS_INV__tt.cir", a, .unlimited) catch "";
        const log = tmp.dir.readFileAlloc(testing.io, "work/LVS_INV__tt.0.log", a, .unlimited) catch "";
        std.debug.print("the inverter does not characterise: {s}: {s}\ndeck:\n{s}\nlog:\n{s}\n", .{ @errorName(err), diag.message, deck, log });
        return err;
    };
    const lib = generated.files[1].text;
    const deck = try tmp.dir.readFileAlloc(testing.io, "work/LVS_INV__tt.cir", a, .unlimited);
    const from = std.mem.indexOf(u8, deck, ".subckt LVS_INV").?;
    const subckt = deck[from .. std.mem.indexOf(u8, deck, ".ends LVS_INV").? + 13];
    var model_lines: std.ArrayList(u8) = .empty;
    for (models) |m| try model_lines.print(a, "{s}\n", .{m});

    var broken: usize = 0;
    // The spec's pin order is A, Y, VDD, VSS.
    for ([_]struct { bool, []const u8, []const u8, []const u8 }{
        .{ true, "FALL", "cell_fall", "fall_transition" },
        .{ false, "RISE", "cell_rise", "rise_transition" },
    }) |row| {
        const rise, const out_edge, const delay_group, const transition_group = row;
        const delays = try libTable(a, lib, delay_group);
        const transitions = try libTable(a, lib, transition_group);
        for (slews, 0..) |slew, s| for (loads, 0..) |load, l| {
            const v0: f64, const v1: f64, const in_edge = if (rise) .{ 0.0, 1.8, "RISE" } else .{ 1.8, 0.0, "FALL" };
            const text = try a.print("* F3 reference\n{s}.option scale=1e-6 reltol=1e-6 abstol=1e-15 vntol=1e-7\n.temp 25\n{s}\nxdut a y vdd vss LVS_INV\nvdd vdd 0 1.8\nvss vss 0 0\nva a 0 PWL(0 {d} 1n {d} {d}n {d})\ncload y 0 {d}p\n.tran 0.1p 12n 0 0.5p\n.meas tran d TRIG v(a) VAL=0.9 {s}=1 TARG v(y) VAL=0.9 {s}=1\n.meas tran tlo WHEN v(y)=0.36 {s}=1\n.meas tran thi WHEN v(y)=1.44 {s}=1\n.end\n", .{ model_lines.items, subckt, v0, v0, 1.0 + slew / 0.6, v1, load, in_edge, out_edge, out_edge, out_edge });
            var got: [3]f64 = undefined;
            try simulate(a, tmp.dir, try a.print("{s}_{d}_{d}.cir", .{ delay_group, s, l }), text, &.{ "d", "tlo", "thi" }, &got);
            const k = s * loads.len + l;
            broken += check(delay_group, slew, load, delays[k], got[0] * 1e9, edge_tolerance);
            broken += check(transition_group, slew, load, transitions[k], @abs(got[2] - got[1]) * 1e9, edge_tolerance);
        };
    }
    for ([_]struct { f64, []const u8 }{ .{ 0.0, "!LVS_INV_n5" }, .{ 1.8, "LVS_INV_n5" } }) |state| {
        const text = try a.print("* F3 reference\n{s}.option scale=1e-6 reltol=1e-6 abstol=1e-15 vntol=1e-7\n.temp 25\n{s}\nxdut a y vdd vss LVS_INV\nvdd vdd 0 1.8\nvss vss 0 0\nva a 0 {d}\ncload y 0 1e-18\n.control\nop\nlet p = -1.8 * vdd#branch * 1e9\nprint p\n.endc\n.end\n", .{ model_lines.items, subckt, state[0] });
        var got: [1]f64 = undefined;
        try simulate(a, tmp.dir, try a.print("leak_{d}.cir", .{state[0]}), text, &.{"p"}, &got);
        broken += check(state[1], 0, 0, try libLeakage(a, lib, state[1]), got[0], .{ 1e-4, 0.0 });
    }
    try testing.expectEqual(0, broken);
}
