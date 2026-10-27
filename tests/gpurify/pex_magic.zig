//! PEX-017's gate against Magic (`-Dcomparison-tests`, inside `nix develop
//! .#comparison`): the sky130 differential pair of tests/fixtures/pex_spice
//! (diffpair.py draws it), its netlist written by GPurify (`pex --reference
//! --format spice`, through the library) and by Magic's `ext2spice` from
//! the same GDS, each run in one ESPice bench. A missing tool, PDK or
//! simulator fails, never skips: Magic and the sky130 models come from
//! `$PDK_ROOT` (default `$HOME/.volare`), ESPice from `$ESPICE` (default
//! `espice` on the path).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;
const ex = gpurify.@"export";

/// The bench, the netlist under test included in place of the schematic:
/// 10 kΩ loads to 1.8 V, a 100 µA tail, the inputs at 0.9 V driven ±0.5 V
/// AC; the gain single-ended and differential at 1 kHz, and the
/// differential -3 dB bandwidth.
const bench =
    \\* PEX-017 differential pair bench
    \\.lib "{s}/sky130A/libs.tech/ngspice/sky130.lib.spice" tt
    \\.include "{s}"
    \\X1 {s} diffpair
    \\Vdd vdd 0 1.8
    \\Vss vss 0 0
    \\Rp vdd outp 10k
    \\Rn vdd outn 10k
    \\Itail tail 0 100u
    \\Vp inp 0 dc 0.9 ac 0.5
    \\Vn inn 0 dc 0.9 ac 0.5 180
    \\Ed outd 0 outp outn 1
    \\.ac dec 50 1k 1T
    \\.meas ac gain_se find vdb(outp) at=1k
    \\.meas ac gain_diff find vdb(outd) at=1k
    \\.meas ac bw when vdb(outd)='gain_diff-3' fall=1
    \\.end
    \\
;

const magic_script =
    \\gds read diffpair.gds
    \\load diffpair
    \\select top cell
    \\extract all
    \\ext2spice lvs
    \\ext2spice cthresh 0
    \\ext2spice -o magic.spice
    \\quit -noprompt
    \\
;

const Result = struct { gain_se: f64, gain_diff: f64, bw: f64 };

// ---- private ----

/// The bench over the netlist file `name` in `dir` (its text `text`), its X card
/// on the subcircuit's own pin order, run by ESPice.
fn simulate(a: Allocator, dir: std.Io.Dir, espice: []const u8, pdk: []const u8, name: []const u8, text: []const u8) !Result {
    const marker = ".subckt diffpair ";
    const at = std.mem.indexOf(u8, text, marker) orelse return error.NoSubckt;
    const pins = text[at + marker.len .. std.mem.indexOfScalarPos(u8, text, at, '\n').?];
    const deck_name = try a.print("{s}.sp", .{name});
    try dir.writeFile(io, .{ .sub_path = deck_name, .data = try a.print(bench, .{ pdk, name, pins }) });
    const ran = std.process.run(a, io, .{ .argv = &.{ espice, deck_name }, .cwd = .{ .dir = dir } }) catch |err| {
        // `.#comparison` carries no ESPice; a comparison that did not run fails.
        std.debug.print("cannot run ESPice as `{s}` ({t}): set ESPICE to its binary or put espice on PATH\n", .{ espice, err });
        return err;
    };
    var out: Result = undefined;
    inline for (.{ "gain_se", "gain_diff", "bw" }) |key| {
        @field(out, key) = measure(ran.stdout, key) orelse {
            std.debug.print("{s}: no {s}:\n{s}\n{s}\n", .{ deck_name, key, ran.stdout, ran.stderr });
            return error.NoMeasure;
        };
    }
    return out;
}

/// `key = value` from a `.meas` report.
fn measure(stdout: []const u8, key: []const u8) ?f64 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t=");
        const k = words.next() orelse continue;
        if (!std.mem.eql(u8, k, key)) continue;
        return std.fmt.parseFloat(f64, words.next() orelse return null) catch null;
    }
    return null;
}

test "the extracted differential pair simulates as Magic's ext2spice netlist does" {
    // Oracle: differential against Magic 8.3 `ext2spice` on the same GDS,
    // in the same ESPice bench (sky130 tt models): the low-frequency gain
    // is the devices' alone (both write W, L and the same as, ad, ps, pd),
    // so it agrees to 0.05 dB; the bandwidth is set by the wiring
    // capacitance each tool extracts, Magic's by its own overlap and
    // sidewall rules and with no wire resistance, so it agrees to 10 % of
    // Magic's (measured: 6.50 GHz against 6.18 GHz, 5.2 %; gains 2.929 and
    // 8.950 dB in both).
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pdk = testing.environ.getPosix("PDK_ROOT") orelse try a.print("{s}/.volare", .{testing.environ.getPosix("HOME").?});
    const espice = testing.environ.getPosix("ESPICE") orelse "espice";
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "diffpair.gds", "diffpair.spice" }) |name| {
        const bytes = try root.readFileAlloc(io, try a.print("tests/fixtures/pex_spice/{s}", .{name}), a, .unlimited);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }

    // GPurify's netlist.
    var diag: gpurify.RunDiagnostic = .{};
    const inputs: gpurify.Inputs = .{ .layout = "diffpair.gds", .deck = "sky130", .reference = &.{"diffpair.spice"} };
    const run = try gpurify.run(gpa, a, io, tmp.dir, inputs, .{ .checks = .{ .lvs = true, .pex = true } }, &gpurify.pdks.decks, &diag);
    try testing.expect(run.outputs.lvs.?.verdict == .match);
    var s: ex.subckt.Subckt = .{};
    var why: []const u8 = "";
    gpurify.subckt_build.buildInto(a, &run.loaded, &run.extracted, &run.outputs, inputs.layout, &run.outputs.parasitics.?, &s, &why) catch |err| {
        std.debug.print("refused: {s}\n", .{why});
        return err;
    };
    var text: std.Io.Writer.Allocating = .init(a);
    var wdiag: ex.Diagnostic = .{};
    const header: ex.Header = .{ .tool_version = "test", .deck_path = "sky130", .layout_path = inputs.layout, .reference_path = inputs.reference[0] };
    try ex.netlist.writeSpice(&text.writer, a, &run.outputs.parasitics.?, &s, "nominal", &header, &wdiag);
    try tmp.dir.writeFile(io, .{ .sub_path = "gpurify.spice", .data = text.written() });

    // Magic's, from the same GDS.
    try tmp.dir.writeFile(io, .{ .sub_path = "ext.tcl", .data = magic_script });
    const tech = try a.print("{s}/sky130A/libs.tech/magic/sky130A.tech", .{pdk});
    const magic = try std.process.run(a, io, .{ .argv = &.{ "magic", "-dnull", "-noconsole", "-rcfile", "/dev/null", "-T", tech, "ext.tcl" }, .cwd = .{ .dir = tmp.dir } });
    const magic_text = tmp.dir.readFileAlloc(io, "magic.spice", a, .unlimited) catch |err| {
        std.debug.print("magic wrote no netlist:\n{s}\n{s}\n", .{ magic.stdout, magic.stderr });
        return err;
    };

    const ours = try simulate(a, tmp.dir, espice, pdk, "gpurify.spice", text.written());
    const theirs = try simulate(a, tmp.dir, espice, pdk, "magic.spice", magic_text);
    std.debug.print("gpurify: {d:.3} dB, {d:.3} dB, {e:.4} Hz; magic: {d:.3} dB, {d:.3} dB, {e:.4} Hz\n", .{ ours.gain_se, ours.gain_diff, ours.bw, theirs.gain_se, theirs.gain_diff, theirs.bw });
    try testing.expectApproxEqAbs(theirs.gain_se, ours.gain_se, 0.05);
    try testing.expectApproxEqAbs(theirs.gain_diff, ours.gain_diff, 0.05);
    try testing.expect(@abs(ours.bw - theirs.bw) <= 0.1 * theirs.bw);
}
