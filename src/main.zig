//! gpurify, the command line: argv and the working directory → the report
//! on stdout, errors on stderr, and exit 0 only on a pass. Ported from
//! src/bin/gpurify/main.rs and src/cli/mod.rs (`main_with`, `write_edit`,
//! `render`, `write_checks`, `header`, `reports`, `liberty`, `fail`).
//!
//! `gpurify <drc|erc|lvs|pex|all|lib> <layout> --deck <deck> [options]`,
//! `xor <layout> <other>`, `<fill|enhance> <layout> <output.gds>`,
//! `system <system.json> --reference <netlist>` or `compare <reference>
//! <candidate>` (cli/args.zig, cli/compare.zig). `--deck` names a deck file
//! or a shipped deck (`sky130`, `gf180mcu`, `ihp_sg13g2`, `asap7`, or `generic_finfet`, asap7's old name).
//! A run's whole report is rendered before the first byte is printed, so an
//! error leaves stdout empty.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init) u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const gpurify = @import("gpurify");
const float = gpurify.float;
const args = @import("cli/args.zig");
const compare = @import("cli/compare.zig");
const errors = @import("cli/errors.zig");

/// Written into every report header; Rust's `CARGO_PKG_VERSION`, which the
/// goldens carry.
const tool_version = "0.1.0";

/// What the CLI runs against: everything a run reads besides argv.
const Env = struct { gpa: Allocator, io: std.Io, dir: std.Io.Dir, environ: *const std.process.Environ.Map };

/// One run's results, from `gpurify.run` or `gpurify.xor.run` (no `extracted`).
const Ran = struct { loaded: *const gpurify.Loaded, extracted: ?*const gpurify.Extracted, outputs: *const gpurify.Outputs, summary: gpurify.Summary };

/// `Reported`: the error is already on stderr.
const Failure = error{ Reported, OutOfMemory, WriteFailed };

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const raw = init.minimal.args.toSlice(arena) catch return 1;
    const argv = arena.alloc([]const u8, raw.len -| 1) catch return 1;
    for (argv, 1..) |*a, k| a.* = raw[k];
    var out_buf: [64 * 1024]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    const env: Env = .{ .gpa = init.gpa, .io = init.io, .dir = std.Io.Dir.cwd(), .environ = init.environ_map };
    const code = cli(env, argv, &out.interface, &err.interface);
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    return code;
}

// ---- private ----

/// Parses `argv`, runs, prints, and returns the exit code.
fn cli(env: Env, argv: []const []const u8, out: *Writer, err: *Writer) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return dispatch(env, arena, argv, out, err) catch |e| switch (e) {
        error.Reported => 1,
        error.OutOfMemory => fail(err, "out of memory", .{}),
        error.WriteFailed => 1,
    };
}

fn dispatch(env: Env, arena: Allocator, argv: []const []const u8, out: *Writer, err: *Writer) Failure!u8 {
    // Two netlists and no layout or deck: its own command line.
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "compare")) {
        var why: []const u8 = "";
        var text: Writer.Allocating = .init(arena);
        const passed = compare.run(arena, env.io, env.dir, argv[1..], &text.writer, &why) catch |e| switch (e) {
            error.Refused => return fail(err, "{s}", .{why}),
            error.OutOfMemory, error.WriteFailed => |x| return x,
        };
        try out.writeAll(text.written());
        return @intFromBool(!passed);
    }
    var message: []const u8 = "";
    var parsed = args.parse(arena, argv, &message) catch |e| switch (e) {
        error.Usage => return fail(err, "{s}", .{message}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const backend = try backendOf(parsed.backend, err);
    const threads = parsed.threads orelse cpuThreads();
    parsed.options.device = .{ .backend = backend, .min_work = minWork(env.gpa, env.io, parsed.backend, backend, threads), .threads = threads };
    switch (parsed.command) {
        .lib => |lib| return liberty(env, arena, parsed.inputs, lib, out, err),
        .system => |path| return system(env, arena, &parsed, path, out, err),
        // An edit writes its layout, then reports DRC on what it wrote.
        .edit => |edit| {
            try writeEdit(env, arena, parsed.inputs, edit.edit, edit.output, err);
            parsed.inputs.layout = edit.output;
        },
        .check, .xor => {},
    }
    var text: Writer.Allocating = .init(arena);
    const summary = try render(env, arena, &parsed, &text.writer, err);
    try out.writeAll(text.written());
    return @intFromBool(!summary.passed());
}

/// `auto`: the first GPU backend that runs here, else the CPU. A named GPU
/// backend that does not run here is refused rather than quietly dropped.
fn backendOf(choice: args.Backend, err: *Writer) Failure!gpurify.Device.Backend {
    const named: gpurify.Device.Backend = switch (choice) {
        .auto => return for ([_]gpurify.Device.Backend{ .cuda, .hip }) |b| (if (gpurify.Device.available(b)) break b) else .cpu,
        .cpu => .cpu,
        .cuda => .cuda,
        .hip => .hip,
    };
    if (!gpurify.Device.available(named)) {
        _ = fail(err, "--backend {t}: this build carries no {t} kernels, or no {t} driver or device loads here", .{ named, named, named });
        return error.Reported;
    }
    return named;
}

/// A named GPU backend runs every kernel call there (it was asked for);
/// `auto` on a GPU sends a call there only from its class's crossover,
/// measured here and now (gpurify/calibrate.zig), and keeps everything on
/// the CPU when the calibration itself fails. Where a call runs never
/// changes its result.
fn minWork(gpa: Allocator, io: std.Io, choice: args.Backend, backend: gpurify.Device.Backend, threads: u16) gpurify.Device.MinWork {
    return switch (choice) {
        .cpu, .cuda, .hip => .always,
        .auto => if (backend == .cpu) .always else blk: {
            const fits = gpurify.calibrate.measure(gpa, io, backend, threads) catch break :blk .never;
            break :blk gpurify.calibrate.minWork(fits);
        },
    };
}

fn cpuThreads() u16 {
    return @intCast(@min(std.Thread.getCpuCount() catch 1, std.math.maxInt(u16)));
}

/// `fill` or `enhance`: the edited layout written to `output`, and what was
/// added, on stderr (stdout carries the report).
fn writeEdit(env: Env, arena: Allocator, inputs: gpurify.Inputs, edit: args.Edit, output: []const u8, err: *Writer) Failure!void {
    const decks = &gpurify.pdks.decks;
    var note: []const u8 = undefined;
    const bytes = switch (edit) {
        .fill => blk: {
            var counts: std.ArrayList(u32) = .empty;
            var diag: gpurify.fill.Diagnostic = .{};
            const bytes = gpurify.fill.fillGds(env.gpa, arena, env.io, env.dir, inputs, decks, &counts, &diag) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (e == error.NotRectilinear or e == error.NoDensityRule) {
                    _ = fail(err, "fill {s}: layer {s}: {t}", .{ diag.fill, diag.layer, e });
                } else try errors.writeLoad(err, e, &diag.load);
                return error.Reported;
            };
            var total: u64 = 0;
            for (counts.items) |c| total += c;
            note = try std.fmt.allocPrint(arena, "{d} fill squares", .{total});
            break :blk bytes;
        },
        .enhance => blk: {
            var kept: gpurify.enhance.Enhanced = .{};
            var diag: gpurify.enhance.Diagnostic = .{};
            const bytes = gpurify.enhance.enhanceGds(env.gpa, arena, env.io, env.dir, inputs, decks, &kept, &diag) catch |e| {
                try errors.writeRun(err, e, &diag);
                return error.Reported;
            };
            note = try std.fmt.allocPrint(arena, "{d} redundant cuts, {d} strap sides widened", .{ kept.cuts, kept.sides });
            break :blk bytes;
        },
    };
    env.dir.writeFile(env.io, .{ .sub_path = output, .data = bytes }) catch |e| {
        _ = fail(err, "{s}: {t}", .{ output, e });
        return error.Reported;
    };
    try err.print("wrote {s}: {s}\n", .{ output, note });
}

/// One whole run, rendered in the requested format into `text`.
/// `system`: several dies and their netlist, checked as one assembly. A
/// system has no one deck or layout, so the header names the system file
/// for both; the text report is its violations and summary (src/cli/mod.rs).
fn system(env: Env, arena: Allocator, cli_: *const args.Cli, path: []const u8, out: *Writer, err: *Writer) Failure!u8 {
    var diag: gpurify.system.Diagnostic = .{};
    const ran = gpurify.system.run(env.gpa, arena, env.io, env.dir, path, cli_.inputs.reference[0], &diag) catch |e| {
        try errors.writeSystem(err, e, &diag);
        return error.Reported;
    };
    var text: Writer.Allocating = .init(arena);
    const o = &ran.outputs;
    switch (cli_.format) {
        .json => {
            const header: gpurify.@"export".Header = .{ .tool_version = tool_version, .deck_path = path, .layout_path = path };
            gpurify.@"export".json.writeReport(&text.writer, &header, &ran.strings, ran.grid, &o.violations, &o.waived, o.runs.items) catch |e| switch (e) {
                error.Unrepresentable => return fail(err, "json: a value the report cannot represent", .{}),
                error.WriteFailed => return error.WriteFailed,
            };
        },
        .text, .spef, .dspf, .spice => {
            try gpurify.@"export".text.writeViolations(&text.writer, &ran.strings, ran.grid, &o.violations, &o.waived);
            try gpurify.@"export".text.writeSummary(&text.writer, ran.summary);
        },
    }
    try out.writeAll(text.written());
    return @intFromBool(!ran.summary.passed());
}

fn render(env: Env, arena: Allocator, cli_: *const args.Cli, text: *Writer, err: *Writer) Failure!gpurify.Summary {
    const decks = &gpurify.pdks.decks;
    const inputs = cli_.inputs;
    var run: gpurify.Run = undefined;
    var xor: gpurify.xor.Xor = undefined;
    const ran: Ran = switch (cli_.command) {
        .xor => |other| blk: {
            var diag: gpurify.xor.Diagnostic = .{};
            xor = gpurify.xor.run(env.gpa, arena, env.io, env.dir, inputs, other, decks, &diag) catch |e| {
                if (e == error.GridMismatch) {
                    _ = fail(err, "the two layouts' UNITS differ: {d} and {d} database units per um", .{ diag.grids[0], diag.grids[1] });
                } else try errors.writeLoad(err, e, &diag.load);
                return error.Reported;
            };
            break :blk .{ .loaded = &xor.loaded, .extracted = null, .outputs = &xor.outputs, .summary = xor.summary };
        },
        .check, .edit => blk: {
            var diag: gpurify.RunDiagnostic = .{};
            run = gpurify.run(env.gpa, arena, env.io, env.dir, inputs, cli_.options, decks, &diag) catch |e| {
                try errors.writeRun(err, e, &diag);
                return error.Reported;
            };
            break :blk .{ .loaded = &run.loaded, .extracted = &run.extracted, .outputs = &run.outputs, .summary = run.summary };
        },
        .lib, .system => unreachable, // dispatched before a run
    };
    const header: gpurify.@"export".Header = .{ .tool_version = tool_version, .deck_path = inputs.deck, .layout_path = inputs.layout };
    const strings = &ran.loaded.strings;
    const o = ran.outputs;
    switch (cli_.format) {
        .text => {
            try writeText(text, ran);
            var why: []const u8 = "";
            reports(arena, env.gpa, cli_.options.checks.pex, ran, text, &why) catch |e| switch (e) {
                error.Refused => {
                    _ = fail(err, "{s}", .{why});
                    return error.Reported;
                },
                error.OutOfMemory, error.WriteFailed => |x| return x,
            };
        },
        .json => gpurify.@"export".json.writeReport(text, &header, strings, ran.loaded.grid, &o.violations, &o.waived, o.runs.items) catch |e| switch (e) {
            error.Unrepresentable => {
                _ = fail(err, "json: a value the report cannot represent", .{});
                return error.Reported;
            },
            error.WriteFailed => return error.WriteFailed,
        },
        .spef, .dspf, .spice => {
            // An empty netlist would read as a design with no parasitics.
            const network = if (o.parasitics) |*n| n else {
                _ = fail(err, "--format {t} asked for a parasitic network, but extraction produced none, and an empty netlist would read as a design with no parasitics", .{cli_.format});
                return error.Reported;
            };
            if (cli_.format == .spef) {
                // The deck's process corners, if any, as min:typ:max triplets.
                const corners = try arena.alloc(*const @TypeOf(network.*), o.corners.items.len);
                for (o.corners.items, corners) |*c, *p| p.* = &c.network;
                var diag: gpurify.@"export".Diagnostic = .{};
                const written = gpurify.@"export".spef.writeSpefCorners(text, arena, network, corners, &ran.extracted.?.ports, strings, &header, &diag);
                try writerRefusal(err, cli_.format, written, &diag);
            } else try writeNetlist(env, arena, cli_, ran, network, text, err);
        },
    }
    return ran.summary;
}

/// `--format dspf` or `spice`: the network with its devices, named in the
/// reference's terms (PEX-017); SPICE's process corners each into
/// `-o`'s `FILE.<corner>`.
fn writeNetlist(env: Env, arena: Allocator, cli_: *const args.Cli, ran: Ran, network: *const gpurify.foreign.ParasiticNetwork, text: *Writer, err: *Writer) Failure!void {
    const ex = gpurify.@"export";
    const inputs = cli_.inputs;
    const reference: ?[]const u8 = if (inputs.reference.len > 0) inputs.reference[0] else null;
    const header: ex.Header = .{ .tool_version = tool_version, .deck_path = inputs.deck, .layout_path = inputs.layout, .reference_path = reference };
    if (reference == null) try err.writeAll("warning: no --reference, so devices are named by layout index and pins come in label order: this netlist cannot be back-annotated\n");
    var s: ex.subckt.Subckt = .{};
    var why: []const u8 = "";
    var diag: ex.Diagnostic = .{};
    try build(arena, cli_.format, ran, inputs.layout, network, &s, &why, err);
    if (cli_.format == .dspf) return writerRefusal(err, .dspf, ex.dspf.writeDspfSubckt(text, arena, network, &s, &header, &diag), &diag);
    try writerRefusal(err, .spice, ex.netlist.writeSpice(text, arena, network, &s, "nominal", &header, &diag), &diag);
    const file = cli_.output orelse return;
    for (ran.outputs.corners.items) |*c| {
        const corner = ran.loaded.strings.resolve(c.name);
        try build(arena, .spice, ran, inputs.layout, &c.network, &s, &why, err);
        var bytes: Writer.Allocating = .init(arena);
        try writerRefusal(err, .spice, ex.netlist.writeSpice(&bytes.writer, arena, &c.network, &s, corner, &header, &diag), &diag);
        const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ file, corner });
        env.dir.writeFile(env.io, .{ .sub_path = path, .data = bytes.written() }) catch |e| {
            _ = fail(err, "{s}: {t}", .{ path, e });
            return error.Reported;
        };
        try err.print("wrote {s}: corner {s}\n", .{ path, corner });
    }
}

fn build(arena: Allocator, format: args.Format, ran: Ran, layout: []const u8, network: *const gpurify.foreign.ParasiticNetwork, s: *gpurify.@"export".subckt.Subckt, why: *[]const u8, err: *Writer) Failure!void {
    gpurify.subckt_build.buildInto(arena, ran.loaded, ran.extracted.?, ran.outputs, layout, network, s, why) catch |e| switch (e) {
        error.Refused => {
            _ = fail(err, "--format {t}: {s}", .{ format, why.* });
            return error.Reported;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// A writer's refusal on stderr, naming what it refused.
fn writerRefusal(err: *Writer, format: args.Format, written: gpurify.@"export".Error!void, diag: *const gpurify.@"export".Diagnostic) Failure!void {
    written catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => |x| return x,
        else => {
            _ = fail(err, "{t}: {t}: {s} net {d}", .{ format, e, diag.what, diag.net });
            return error.Reported;
        },
    };
}

/// The text report: rule records, violations, LVS merges and verdict, summary.
fn writeText(w: *Writer, ran: Ran) Writer.Error!void {
    const text = gpurify.@"export".text;
    const o = ran.outputs;
    const strings = &ran.loaded.strings;
    try text.writeRuns(w, strings, o.runs.items);
    try text.writeViolations(w, strings, ran.loaded.grid, &o.violations, &o.waived);
    const none: @typeInfo(@TypeOf(o.lvs)).optional.child = .{};
    const traced = if (o.lvs) |*t| t else &none;
    const placements = if (ran.loaded.reference) |*r| r.placements.items else &.{};
    try text.writeMerges(w, strings, placements, o.lvs_unpaired.items, &traced.layout_merges, &traced.reference_merges);
    try text.writeVerdict(w, if (o.lvs) |t| t.verdict else null, traced.found.items);
    try text.writeSummary(w, ran.summary);
}

/// The deck's `report` lines: `cluster`, one line per cluster, after any
/// check (FLOW-010), and, when PEX ran, `p2p` and `coupling`, one line per
/// pair (PEX-016). `why` says why on `Refused`.
fn reports(arena: Allocator, gpa: Allocator, pex: bool, ran: Ran, w: *Writer, why: *[]const u8) (error{Refused} || Allocator.Error || Writer.Error)!void {
    const loaded = ran.loaded;
    const wanted = &loaded.deck.deck.reports;
    const per_um: f64 = @floatFromInt(loaded.grid.dbu_per_um);
    if (wanted.cluster) |reach| {
        var clusters: gpurify.triage.Clusters = .{};
        defer clusters.deinit(gpa);
        try gpurify.triage.clusterInto(gpa, &ran.outputs.violations, reach, &clusters);
        for (0..clusters.len()) |k| {
            const lo = clusters.lo.items[k];
            const hi = clusters.hi.items[k];
            try w.print("cluster {s} {d} violations within ({d}, {d})-({d}, {d}) um\n", .{ loaded.strings.resolve(clusters.rule.items[k]), clusters.rowsOf(@intCast(k)).len, um(lo.x, per_um), um(lo.y, per_um), um(hi.x, per_um), um(hi.y, per_um) });
        }
    }
    // A deck serves every check; its PEX reports print when PEX ran.
    const extracted = ran.extracted orelse return;
    if (!pex) return;
    for (wanted.p2p.items) |p| {
        var pairs: std.ArrayList(gpurify.p2p.Pair) = .empty;
        try gpurify.p2p.resistanceInto(arena, arena, loaded, extracted, p.net, p.points, &pairs, why);
        for (pairs.items) |pair| {
            const a = p.points[pair.i];
            const b = p.points[pair.j];
            // Rust's `{}` for the points and `{:.6}` for the ohms, exactly.
            try w.print("p2p {s} (", .{p.net});
            try float.display(w, um(a[0], per_um));
            try w.writeAll(", ");
            try float.display(w, um(a[1], per_um));
            try w.writeAll(") um to (");
            try float.display(w, um(b[0], per_um));
            try w.writeAll(", ");
            try float.display(w, um(b[1], per_um));
            try w.writeAll(") um: ");
            try float.fixed6(w, pair.ohms);
            try w.writeAll(" ohm\n");
        }
    }
    for (wanted.coupling.items) |c| {
        const network = if (ran.outputs.parasitics) |*n| n else {
            why.* = "report coupling needs a parasitic network, and PEX made none";
            return error.Refused;
        };
        const ff = try gpurify.p2p.coupling(arena, loaded, extracted, network, c.a, c.b, why);
        try w.print("coupling {s} {s}: ", .{ c.a, c.b });
        try float.fixed6(w, ff);
        try w.writeAll(" fF\n");
    }
}

fn um(d: i64, per_um: f64) f64 {
    return @as(f64, @floatFromInt(d)) / per_um;
}

/// `lib`: load and extract once, then generate every accuracy the spec asks
/// for; `"accuracy": "all"` writes each level under its own subdirectory.
fn liberty(env: Env, arena: Allocator, inputs: gpurify.Inputs, lib: args.Lib, out: *Writer, err: *Writer) Failure!u8 {
    const L = gpurify.liberty;
    const spec_text = env.dir.readFileAlloc(env.io, lib.spec, arena, .unlimited) catch |e| return fail(err, "{s}: {t}", .{ lib.spec, e });
    var sdiag: L.Diagnostic = .{};
    const spec = L.spec.parse(arena, spec_text, &sdiag) catch |e| return fail(err, "{s}: {t}: {s}", .{ lib.spec, e, sdiag.message });
    const lef: ?[]const u8 = if (lib.lef) |path| env.dir.readFileAlloc(env.io, path, arena, .unlimited) catch |e| return fail(err, "{s}: {t}", .{ path, e }) else null;
    var ldiag: gpurify.LoadDiagnostic = .{};
    var loaded = gpurify.load(env.gpa, arena, env.io, env.dir, inputs, &gpurify.pdks.decks, &ldiag) catch |e| {
        try errors.writeLoad(err, e, &ldiag);
        return 1;
    };
    var ediag: gpurify.ExtractDiagnostic = .none;
    const extracted = gpurify.extract(arena, &loaded, &ediag) catch |e| {
        try errors.writeExtract(err, e, &ediag);
        return 1;
    };
    // ngspice's own OpenMP threads would oversubscribe the worker pool.
    var environ = try env.environ.clone(arena);
    try environ.put("OMP_NUM_THREADS", "1");
    const levels = spec.accuracy.levels;
    for (levels) |accuracy| {
        const name = accuracy.name();
        const dir = if (levels.len > 1) try std.fs.path.join(arena, &.{ lib.output_dir, name }) else lib.output_dir;
        // Simulator decks and logs; kept only when a simulation fails, to debug it.
        // ponytail: under the output directory, where Rust used the temp dir.
        const work = try std.fs.path.join(arena, &.{ dir, ".gpurify-work" });
        const request: L.Request = .{ .spec = &spec, .accuracy = accuracy, .lef = lef, .work = work, .tool_version = tool_version, .env = .{ .gpa = env.gpa, .io = env.io, .dir = env.dir, .environ = &environ } };
        const started = std.Io.Timestamp.now(env.io, .awake);
        var gdiag: L.Diagnostic = .{};
        const generated = L.generate(arena, &loaded, &extracted, request, &gdiag) catch |e| {
            _ = fail(err, "{s} accuracy: {t}: {s}", .{ name, e, gdiag.message });
            if (env.dir.access(env.io, work, .{})) |_| try err.print("simulator decks and logs are kept in {s}\n", .{work}) else |_| {}
            return 1;
        };
        for (generated.files) |file| {
            const path = try std.fs.path.join(arena, &.{ dir, file.path });
            if (std.fs.path.dirname(path)) |parent| env.dir.createDirPath(env.io, parent) catch |e| return fail(err, "{s}: {t}", .{ parent, e });
            env.dir.writeFile(env.io, .{ .sub_path = path, .data = file.text }) catch |e| return fail(err, "{s}: {t}", .{ path, e });
            try out.print("{s}: wrote {s}\n", .{ name, path });
        }
        for (generated.notes) |note| try out.print("{s}: note: {s}\n", .{ name, note });
        const ns = started.untilNow(env.io, .awake).nanoseconds;
        try out.print("{s}: done in {d:.1} s\n", .{ name, @as(f64, @floatFromInt(ns)) / 1e9 });
        env.dir.deleteTree(env.io, work) catch {};
    }
    return 0;
}

/// `error: ` and the message on stderr; the exit code of a failure.
fn fail(err: *Writer, comptime fmt: []const u8, a: anytype) u8 {
    err.print("error: " ++ fmt ++ "\n", a) catch {};
    return 1;
}

/// A GDSII library on a 1 nm grid holding one `w` × `h` nm met1 rectangle
/// (sky130's `gds(68, 20)`) at the origin, in cell `top`.
fn met1Gds(arena: Allocator, w: i32, h: i32) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    const Rec = struct {
        fn put(list: *std.ArrayList(u8), a: Allocator, kind: u16, data: []const u8) !void {
            var head: [4]u8 = undefined;
            std.mem.writeInt(u16, head[0..2], @intCast(4 + data.len), .big);
            std.mem.writeInt(u16, head[2..4], kind, .big);
            try list.appendSlice(a, &head);
            try list.appendSlice(a, data);
        }
    };
    const dates: [24]u8 = @splat(0);
    // UNITS: 1e-3 user units and 1e-9 m per database unit, GDSII reals.
    const units = [_]u8{ 0x3e, 0x41, 0x89, 0x37, 0x4b, 0xc6, 0xa7, 0xf0, 0x39, 0x44, 0xb8, 0x2f, 0xa0, 0x9b, 0x5a, 0x54 };
    var xy: [40]u8 = undefined;
    for ([_]i32{ 0, 0, w, 0, w, h, 0, h, 0, 0 }, 0..) |v, k| std.mem.writeInt(i32, xy[4 * k ..][0..4], v, .big);
    try Rec.put(&b, arena, 0x0002, &.{ 0x02, 0x58 });
    try Rec.put(&b, arena, 0x0102, &dates);
    try Rec.put(&b, arena, 0x0206, "lib\x00");
    try Rec.put(&b, arena, 0x0305, &units);
    try Rec.put(&b, arena, 0x0502, &dates);
    try Rec.put(&b, arena, 0x0606, "top\x00");
    try Rec.put(&b, arena, 0x0800, "");
    try Rec.put(&b, arena, 0x0D02, &.{ 0, 68 });
    try Rec.put(&b, arena, 0x0E02, &.{ 0, 20 });
    try Rec.put(&b, arena, 0x1003, &xy);
    try Rec.put(&b, arena, 0x1100, "");
    try Rec.put(&b, arena, 0x0700, "");
    try Rec.put(&b, arena, 0x0400, "");
    return b.items;
}

/// Runs `argv` through `cli` in `dir`; the exit code, stdout and stderr.
fn runIn(arena: Allocator, dir: std.Io.Dir, argv: []const []const u8) !struct { u8, []const u8, []const u8 } {
    var environ: std.process.Environ.Map = .init(arena);
    var out: Writer.Allocating = .init(arena);
    var err: Writer.Allocating = .init(arena);
    const code = cli(.{ .gpa = std.testing.allocator, .io = std.testing.io, .dir = dir, .environ = &environ }, argv, &out.writer, &err.writer);
    return .{ code, out.written(), err.written() };
}

test {
    _ = args;
    _ = compare;
    _ = errors;
}

test "a named gpu takes every call; auto on the cpu calibrates nothing" {
    // Oracle: the selection rule (ARCHITECTURE.md GPU, Selection): `--backend
    // cuda|hip` is the user's order, every class at 0; `auto` that resolved
    // to the CPU has no GPU to measure, and its backend sends nothing there.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const always: gpurify.Device.MinWork = .always;
    try std.testing.expectEqual(always, minWork(gpa, io, .cuda, .cuda, 4));
    try std.testing.expectEqual(always, minWork(gpa, io, .hip, .hip, 4));
    try std.testing.expectEqual(always, minWork(gpa, io, .auto, .cpu, 4));
}

test "drc on the shipped sky130 deck passes a 1 um met1 square and fails a 100 nm strip on m1.1" {
    // Oracle: the SkyWater SKY130 periphery rules, m1.1: met1 width at least
    // 0.140 um. A 1 x 1 um square is clean (exit 0); a 0.1 um wide strip is one
    // m1.1 error measured at its 100 nm width (exit 1). The shipped deck is
    // named, not read from a file.
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "square.gds", .data = try met1Gds(arena, 1000, 1000) });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "strip.gds", .data = try met1Gds(arena, 100, 1000) });

    const square = try runIn(arena, tmp.dir, &.{ "drc", "square.gds", "--deck", "sky130", "--backend", "auto" });
    try testing.expectEqualStrings("", square[2]);
    try testing.expectEqual(0, square[0]);
    try testing.expect(std.mem.indexOf(u8, square[1], "violations: 0\nsummary:\n  drc: ran\n  erc: not selected\n") != null);
    try testing.expect(std.mem.endsWith(u8, square[1], "  0 rules skipped\n  265 rules clean\n  0 violations: 0 errors, 0 warnings\n"));

    const strip = try runIn(arena, tmp.dir, &.{ "drc", "strip.gds", "--deck", "sky130", "--threads", "2" });
    try testing.expectEqual(1, strip[0]);
    try testing.expect(std.mem.indexOf(u8, strip[1], "  m1.1: ran, examined 1 shapes, found 1 violations\n") != null);
    try testing.expect(std.mem.indexOf(u8, strip[1], "violations: 1\n  m1.1 error layer 35 at (50 nm, 500 nm) measured 100 nm against limit 140 nm on shape 0\n") != null);
}

test "a refusal exits 1 with one error line and no report" {
    // Oracle: src/cli/mod.rs: every failure is `error: <why>` on stderr, exit
    // 1, and nothing on stdout; a missing system description or layout
    // names the input at fault.
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "drc", "t.gds" }, "error: --deck <deck> is required\n" },
        .{ &.{ "system", "s.json", "--reference", "r.spice" }, "error: system: " },
        .{ &.{ "compare", "a.spef" }, "error: compare takes two parasitic netlists: compare <reference> <candidate>\n" },
        .{ &.{ "drc", "missing.gds", "--deck", "sky130" }, "error: layout missing.gds: " },
        .{ &.{ "lib", "missing.gds", "--deck", "sky130", "--spec", "missing.json", "--output-dir", "o" }, "error: missing.json: " },
    };
    for (cases) |c| {
        const r = try runIn(arena, tmp.dir, c[0]);
        try testing.expectEqual(1, r[0]);
        try testing.expectEqualStrings("", r[1]);
        try testing.expect(std.mem.startsWith(u8, r[2], c[1]));
    }
}
