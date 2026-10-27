//! Every corpus case through every output the CLI has, byte for byte
//! against Rust's bytes in tests/golden/<domain>/. Ported from
//! tests/golden.rs. The CLI is a later wave, so `render` does what its
//! `render` does for these jobs: `all --format json`, `pex --format spef`
//! (with `--quasistatic` on the first eight nets it names), and `lvs
//! --reference <case>.spice --format json`, as `exit N`, stdout, stderr.
//!
//! Oracles:
//! - Golden: Rust's reviewed snapshots. A difference is investigated, not
//!   regenerated; `-Dupdate-goldens=true` writes missing or changed files
//!   and fails the run, so every regeneration is reviewed in the diff.
//! - Determinism: every run is made twice and must be byte-identical; a
//!   field-solved run is made again on one thread and must match (Rust's
//!   `RAYON_NUM_THREADS=1`). The eight `PEX_NEG_*` field solves are the
//!   slow cells: they run under `-Dslow-tests` only. Under `-Dgpu-tests`
//!   every `all` run is made again with every kernel call on the GPU (the
//!   DRC pair distances over the run's resident store) and must match.
//! A golden file no run produces is stale and fails the test.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const gpurify = @import("gpurify");
const fixtures = @import("fixtures.zig");
const Device = @import("geom").Device;
const gpa = testing.allocator;
const io = testing.io;

const deck = "tests/fixtures/params.deck";

const domains = [_][]const u8{ "drc", "erc", "lvs", "pex" };

/// Which CLI command a job renders.
const Command = enum { all, pex, pex_qs, lvs };

const Job = struct { domain: []const u8, id: []const u8, command: Command, qs_nets: []const []const u8 };

// ---- private ----

/// What the CLI prints for `job`: exit code, stdout, stderr, as Rust's
/// golden harness joins them, the kernels on `device`.
fn render(arena: Allocator, root: std.Io.Dir, job: Job, device: Device) ![]const u8 {
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const layout = try std.fmt.allocPrint(arena, "tests/fixtures/{s}/{s}.gds", .{ job.domain, job.id });
    const reference = try std.fmt.allocPrint(arena, "tests/fixtures/lvs_refs/{s}.spice", .{job.id});
    const inputs: gpurify.Inputs = .{ .layout = layout, .deck = deck, .reference = if (job.command == .lvs) &.{reference} else &.{} };
    const checks: gpurify.Checks = switch (job.command) {
        .all => .all,
        .pex, .pex_qs => .{ .pex = true },
        .lvs => .{ .lvs = true },
    };
    const options: gpurify.RunOptions = .{ .checks = checks, .quasistatic_nets = if (job.command == .pex_qs) job.qs_nets else &.{}, .device = device };
    var diag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, run_arena.allocator(), io, root, inputs, options, &.{}, &diag);
    const header: gpurify.@"export".Header = .{ .tool_version = "0.1.0", .deck_path = deck, .layout_path = layout };
    var stdout: std.Io.Writer.Allocating = .init(arena);
    var stderr: []const u8 = "";
    var exit: u8 = if (r.summary.passed()) 0 else 1;
    switch (job.command) {
        .all, .lvs => try gpurify.@"export".json.writeReport(&stdout.writer, &header, &r.loaded.strings, &r.loaded.deck.deck.layers, r.loaded.grid, &r.outputs.violations, &r.outputs.waived, r.outputs.runs.items, r.outputs.run_domain.items, r.summary),
        .pex, .pex_qs => if (r.outputs.parasitics) |*network| {
            const corners = try arena.alloc(*const @import("extract").network.ParasiticNetwork, r.outputs.corners.items.len);
            for (r.outputs.corners.items, corners) |*c, *o| o.* = &c.network;
            var wdiag: gpurify.@"export".Diagnostic = .{};
            try gpurify.@"export".spef.writeSpefCorners(&stdout.writer, run_arena.allocator(), network, corners, &r.extracted.ports, &r.loaded.strings, &header, &wdiag);
        } else {
            stderr = "--format spef asked for a parasitic network, but extraction produced none, and an empty netlist would read as a design with no parasitics\n";
            exit = 1;
        },
    }
    return std.fmt.allocPrint(arena, "exit {d}\n--- stdout\n{s}--- stderr\n{s}", .{ exit, stdout.written(), stderr });
}

/// The first eight nets a SPEF names, as `--quasistatic` arguments.
fn quasistaticNets(arena: Allocator, rendered: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        if (out.items.len == 8) break;
        if (!std.mem.startsWith(u8, line, "*D_NET ")) continue;
        var words = std.mem.tokenizeAny(u8, line["*D_NET ".len..], " \t");
        if (words.next()) |net| try out.append(arena, net);
    }
    return out.items;
}

/// Null when `got` is the golden's bytes; else the failure, after writing
/// the golden under `-Dupdate-goldens` or when it is missing.
fn compareGolden(arena: Allocator, root: std.Io.Dir, golden: []const u8, got: []const u8) !?[]const u8 {
    const want = root.readFileAlloc(io, golden, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try root.writeFile(io, .{ .sub_path = golden, .data = got });
            return try std.fmt.allocPrint(arena, "{s}: new golden written; review it and commit", .{golden});
        },
        else => return err,
    };
    if (std.mem.eql(u8, want, got)) return null;
    if (paths.update_goldens) {
        try root.writeFile(io, .{ .sub_path = golden, .data = got });
        return try std.fmt.allocPrint(arena, "{s}: golden rewritten (-Dupdate-goldens); review the diff", .{golden});
    }
    const at = std.mem.indexOfDiff(u8, want, got).?;
    const from = at -| 120;
    return try std.fmt.allocPrint(arena, "{s}: differs from its golden at byte {d}\n    golden: {s}\n    now:    {s}", .{ golden, at, want[from..@min(want.len, at + 120)], got[from..@min(got.len, at + 120)] });
}

/// Every kernel call on `threads` CPU threads.
fn cpu(threads: u16) Device {
    return .{ .backend = .cpu, .min_work = .never, .threads = threads };
}

/// Every kernel call on this build's GPU backend; an error, never a skip,
/// in a build without device kernels.
fn gpuDevice() !Device {
    const backend = @import("extract").gpu.compiled orelse return error.BuiltWithoutGpuKernels;
    return .{ .backend = backend, .min_work = .always, .threads = 8 };
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "every corpus output is its golden and deterministic" {
    // Oracle: golden, Rust's snapshots under tests/golden/, and determinism:
    // every run made twice, byte-identical, and a field solve on one thread
    // equal to one on many (module doc).
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    _ = try fixtures.ensure(gpa, root);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = try fixtures.cases(arena, root, "expectations.json");

    var failures: std.ArrayList([]const u8) = .empty;
    var produced: std.StringHashMapUnmanaged(void) = .empty;
    var jobs: usize = 0;
    for (cases) |case| {
        const commands: []const Command = if (std.mem.eql(u8, case.domain, "pex"))
            &.{ .all, .pex, .pex_qs }
        else if (std.mem.eql(u8, case.domain, "lvs")) &.{ .all, .lvs } else &.{.all};
        var qs_nets: []const []const u8 = &.{};
        for (commands) |command| {
            if (command == .pex_qs and qs_nets.len == 0) continue;
            const slow = std.mem.startsWith(u8, case.id, "PEX_NEG_");
            if (command == .pex_qs and slow and !paths.slow_tests) continue;
            const ext = switch (command) {
                .all => "all",
                .pex => "spef",
                .pex_qs => "qs",
                .lvs => "lvs",
            };
            const golden = try std.fmt.allocPrint(arena, "tests/golden/{s}/{s}.{s}", .{ case.domain, case.id, ext });
            try produced.put(arena, golden, {});
            jobs += 1;
            const job: Job = .{ .domain = case.domain, .id = case.id, .command = command, .qs_nets = qs_nets };
            const first = try render(arena, root, job, cpu(8));
            if (!std.mem.eql(u8, first, try render(arena, root, job, cpu(8))))
                try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: two runs of the same inputs differ", .{golden}));
            if (paths.gpu_tests and command == .all and !std.mem.eql(u8, first, try render(arena, root, job, try gpuDevice())))
                try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: the GPU run differs from the CPU run", .{golden}));
            if (command == .pex_qs and !std.mem.eql(u8, first, try render(arena, root, job, cpu(1))))
                try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: one thread and many threads differ", .{golden}));
            if (command == .pex) qs_nets = try quasistaticNets(arena, first);
            if (try compareGolden(arena, root, golden, first)) |failure| try failures.append(arena, failure);
        }
    }
    // A golden no job produces is stale.
    for (domains) |d| {
        const sub = try std.fmt.allocPrint(arena, "tests/golden/{s}", .{d});
        var dir = try root.openDir(io, sub, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, entry.name });
            // The slow cells' field solves are not run outside -Dslow-tests.
            const skipped_slow = !paths.slow_tests and std.mem.startsWith(u8, entry.name, "PEX_NEG_") and std.mem.endsWith(u8, entry.name, ".qs");
            if (!produced.contains(name) and !skipped_slow) try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: no run produces this golden; delete it", .{name}));
        }
    }
    // Every golden file is a job: 237, the eight slow field solves aside in Debug.
    try testing.expectEqual(@as(usize, if (paths.slow_tests) 237 else 229), jobs);
    std.mem.sort([]const u8, failures.items, {}, lessString);
    for (failures.items) |f| std.debug.print("{s}\n", .{f});
    if (failures.items.len != 0) {
        std.debug.print("{d} of {d} runs failed\n", .{ failures.items.len, jobs });
        return error.TestGoldenMismatch;
    }
}
