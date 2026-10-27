//! `zig build bench`: every GPU-capable kernel timed on the CPU (one thread and
//! every thread) and on the GPU across a size sweep, against the startup
//! calibration `--backend auto` runs (gpurify/calibrate.zig), which it prints
//! first with its cost (docs/src/explanation/cpu-and-gpu.md, How
//! `--backend auto` decides). In: nothing but the machine. Out: one table on
//! stdout, a row per kernel and size, then each kernel's crossover. GPU timings
//! include the kernel load and the per-call bulk upload (geom.bulk) and
//! download; `setup` is what is uploaded once and amortized: a BEM solve's
//! columns over its applies, the resident store over one call per spacing rule
//! of the sky130 deck. Ported in spirit from examples/bench_all.rs (the scale
//! corpus sweep); a timing is not a check, so nothing is gated.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const g = @import("gompute");
const geom = @import("geom");
const check = @import("check");
const extract = @import("extract");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const density = check.drc.density;
const distance = check.proximity_distance;

/// One timed row: work in the kernel's own unit, times in ms (null: not run).
const Row = struct { size: u64, work: u64, cpu1: ?f64, cpun: ?f64, setup: ?f64, gpu: ?f64 };

/// Applies a BEM solve makes per upload; the crossover amortizes `setup`
/// over this many. A GMRES column takes tens of iterations and a solve has
/// one column per conductor.
const solve_applies = 30;

const Bench = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    threads: u16,
    backend: ?geom.Device.Backend,
    /// The sky130 deck's spacing rules: the pair-distance calls one DRC run
    /// makes over one resident store.
    spacing_rules: u32,

    /// `--backend auto`'s calibration: each class's fitted lines, its
    /// threshold, and the wall time it costs at startup.
    fn calibration(b: Bench) !void {
        const backend = b.backend orelse return b.out.print("\ncalibration: no GPU here, auto stays on the CPU\n", .{});
        // The first run in a process pays the kernel loads; the second is
        // what calibration itself costs.
        var ms: [2]f64 = undefined;
        var fits: gpurify.calibrate.Fits = undefined;
        for (&ms) |*t| {
            const start = Io.Timestamp.now(b.io, .awake);
            fits = try gpurify.calibrate.measure(b.gpa, b.io, backend, b.threads);
            t.* = @as(f64, @floatFromInt(start.durationTo(Io.Timestamp.now(b.io, .awake)).nanoseconds)) / std.time.ns_per_ms;
        }
        const min = gpurify.calibrate.minWork(fits);
        try b.out.print("\ncalibration ({d:.0} ms first in the process, {d:.0} ms again): cost = fixed + per-work\n  {s:>9} {s:>12} {s:>12} {s:>12} {s:>12} {s:>14}\n", .{ ms[0], ms[1], "class", "cpu us", "cpu ns/work", "gpu us", "gpu ns/work", "min_work" });
        inline for (.{ "float", "resident", "streamed" }) |name| {
            const f = @field(fits, name);
            try b.out.print("  {s:>9} {d:>12.1} {d:>12.5} {d:>12.1} {d:>12.5}", .{ name, f.cpu.fixed_ns / 1e3, f.cpu.per_work_ns, f.gpu.fixed_ns / 1e3, f.gpu.per_work_ns });
            const w = @field(min, name);
            if (w == std.math.maxInt(u64)) try b.out.print(" {s:>14}\n", .{"never"}) else try b.out.print(" {d:>14}\n", .{w});
        }
        try b.out.flush();
    }

    /// The dense potential or field rows, `P` panels: P² pair evaluations
    /// per apply, f64.
    fn bem(b: Bench, comptime kind: enum { potential, field }) !void {
        const sizes = [_]u64{ 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
        var rows: [sizes.len]Row = undefined;
        for (sizes, &rows) |n, *row| {
            var rng: testgen.Rng = .init(n);
            var op = try Operator.init(b.gpa, &rng, n, kind == .field);
            defer op.deinit(b.gpa);
            const x = try b.gpa.alloc(f64, n);
            defer b.gpa.free(x);
            for (x) |*v| v.* = rng.unit() * 2e-15 - 1e-15;
            const y = try b.gpa.alloc(f64, n);
            defer b.gpa.free(y);
            row.* = .{ .size = n, .work = n * n, .cpu1 = null, .cpun = null, .setup = null, .gpu = null };
            const Cpu = struct {
                op: *Operator,
                x: []const f64,
                y: []f64,
                fn run(c: @This()) !void {
                    c.op.apply(c.x, c.y);
                    std.mem.doNotOptimizeAway(c.y[c.y.len - 1]);
                }
            };
            op.setThreads(1);
            row.cpu1 = if (n <= 16384) try timeMs(b.io, Cpu{ .op = &op, .x = x, .y = y }, Cpu.run) else null;
            op.setThreads(b.threads);
            row.cpun = try timeMs(b.io, Cpu{ .op = &op, .x = x, .y = y }, Cpu.run);
            const backend = b.backend orelse continue;
            const device: geom.Device = .{ .backend = backend, .min_work = .always, .threads = b.threads };
            const Setup = struct {
                gpa: Allocator,
                device: geom.Device,
                op: *Operator,
                fn run(s: @This()) !void {
                    var gpu = extract.gpu.Gpu.init(s.gpa, s.device, &s.op.potential, if (s.op.field) |*f| f else null) orelse return error.NoGpu;
                    gpu.deinit();
                }
            };
            row.setup = try timeMs(b.io, Setup{ .gpa = b.gpa, .device = device, .op = &op }, Setup.run);
            var gpu = extract.gpu.Gpu.init(b.gpa, device, &op.potential, if (op.field) |*f| f else null) orelse return error.NoGpu;
            defer gpu.deinit();
            const Apply = struct {
                gpu: *extract.gpu.Gpu,
                x: []const f64,
                y: []f64,
                fn run(a: @This()) !void {
                    try a.gpu.apply(a.x, a.y);
                    std.mem.doNotOptimizeAway(a.y[a.y.len - 1]);
                }
            };
            row.gpu = try timeMs(b.io, Apply{ .gpu = &gpu, .x = x, .y = y }, Apply.run);
        }
        try b.table(if (kind == .potential) "bem potential rows (f64)" else "bem field rows (f64)", "panels", "P^2", &rows, solve_applies);
    }

    /// The capped exact distance of every candidate pair on the scale
    /// corpus's finger layer, 500 DBU apart: edge pairs (16 per rectangle
    /// pair), integer. `setup` is the store's one upload (`ResidentStore`),
    /// amortized over one call per sky130 spacing rule; `gpu` a call over
    /// the resident store: the pair list up, the distances down.
    fn pairs(b: Bench) !void {
        const sizes = [_]u32{ 1_000, 10_000, 100_000, 1_000_000, 4_000_000 };
        var rows: [sizes.len]Row = undefined;
        for (sizes, &rows) |polygons, *row| {
            var corpus = try testgen.scale.scaleCorpus(b.gpa, .{ .seed = 0x5EED, .polygons = polygons, .nets = @max(polygons / 16, 1), .hierarchy_depth = 2 });
            defer corpus.deinit(b.gpa);
            var ix: geom.index.SpatialIndex = .empty;
            defer ix.deinit(b.gpa);
            try ix.build(b.gpa, &corpus.store, @fromBackingInt(1));
            var list: std.ArrayList(geom.index.Pair) = .empty;
            defer list.deinit(b.gpa);
            try geom.index.candidatePairsInto(b.gpa, &corpus.store, &ix, 500, &list);
            const got = try b.gpa.alloc(i64, list.items.len);
            defer b.gpa.free(got);
            var edges: u64 = 0;
            const vl = corpus.store.poly_vert_len.items;
            for (list.items) |p| edges += @as(u64, vl[@backingInt(p.a)]) * vl[@backingInt(p.b)];
            row.* = .{ .size = list.items.len, .work = edges, .cpu1 = null, .cpun = null, .setup = null, .gpu = null };
            const Cpu = struct {
                store: *const geom.GeometryStore,
                pairs: []const geom.index.Pair,
                threads: u16,
                out: []i64,
                fn run(c: @This()) !void {
                    try distance.cappedDistancesCpu(c.store, c.pairs, c.threads, c.out);
                    std.mem.doNotOptimizeAway(c.out.ptr);
                }
            };
            row.cpu1 = try timeMs(b.io, Cpu{ .store = &corpus.store, .pairs = list.items, .threads = 1, .out = got }, Cpu.run);
            row.cpun = try timeMs(b.io, Cpu{ .store = &corpus.store, .pairs = list.items, .threads = b.threads, .out = got }, Cpu.run);
            const backend = b.backend orelse continue;
            const Upload = struct {
                gpa: Allocator,
                backend: geom.Device.Backend,
                store: *const geom.GeometryStore,
                pairs: []const geom.index.Pair,
                out: []i64,
                fn run(c: @This()) !void {
                    var resident: geom.ResidentStore = .empty;
                    defer resident.deinit();
                    try distance.cappedDistancesGpu(c.gpa, c.backend, &resident, c.store, c.pairs[0..1], c.out[0..1]);
                }
            };
            row.setup = try timeMs(b.io, Upload{ .gpa = b.gpa, .backend = backend, .store = &corpus.store, .pairs = list.items, .out = got }, Upload.run);
            var resident: geom.ResidentStore = .empty;
            defer resident.deinit();
            const Gpu = struct {
                gpa: Allocator,
                backend: geom.Device.Backend,
                resident: *geom.ResidentStore,
                store: *const geom.GeometryStore,
                pairs: []const geom.index.Pair,
                out: []i64,
                fn run(c: @This()) !void {
                    try distance.cappedDistancesGpu(c.gpa, c.backend, c.resident, c.store, c.pairs, c.out);
                    std.mem.doNotOptimizeAway(c.out.ptr);
                }
            };
            row.gpu = try timeMs(b.io, Gpu{ .gpa = b.gpa, .backend = backend, .resident = &resident, .store = &corpus.store, .pairs = list.items, .out = got }, Gpu.run);
        }
        try b.table("pair distances (i64), resident store", "pairs", "edge pairs", &rows, b.spacing_rules);
        const last = rows[rows.len - 1];
        if (last.gpu) |gpu| try b.out.print("  one DRC run, {d} spacing rules at {d} pairs: GPU {d:.1} ms upload + {d} x {d:.1} ms = {d:.1} ms; CPU {d} x {d:.1} ms = {d:.1} ms\n", .{ b.spacing_rules, last.size, last.setup.?, b.spacing_rules, gpu, last.setup.? + gpu * @as(f64, @floatFromInt(b.spacing_rules)), b.spacing_rules, cpuBest(last), cpuBest(last) * @as(f64, @floatFromInt(b.spacing_rules)) });
        try b.out.flush();
    }

    /// The density windows' covered areas: a die of `S` DBU tiled by
    /// 1000-DBU squares at a 2000 pitch, 20000-DBU windows every 10000 (a
    /// window holds ~100 rectangles), integer. Work: rectangle visits
    /// (`density.visits`), the estimate the GPU threshold reads.
    fn windows(b: Bench) !void {
        const sides = [_]i64{ 100_000, 300_000, 1_000_000, 2_000_000, 5_000_000 };
        var rows: [sides.len]Row = undefined;
        for (sides, &rows) |side, *row| {
            const per: usize = @intCast(@divExact(side, 2000));
            const rects = try b.gpa.alloc(geom.Bbox, per * per);
            defer b.gpa.free(rects);
            for (rects, 0..) |*r, k| {
                const x: i64 = @intCast(k % per * 2000);
                const y: i64 = @intCast(k / per * 2000);
                r.* = .{ .xlo = x, .ylo = y, .xhi = x + 1000, .yhi = y + 1000 };
            }
            const grid = density.Grid.over(.{ .xlo = 0, .ylo = 0, .xhi = side, .yhi = side }, 20_000, 10_000).?;
            var bins: density.Bins = .{};
            defer bins.deinit(b.gpa);
            try bins.fill(b.gpa, grid, rects);
            const got = try b.gpa.alloc(i64, grid.count());
            defer b.gpa.free(got);
            row.* = .{ .size = rects.len, .work = density.visits(grid, &bins), .cpu1 = null, .cpun = null, .setup = null, .gpu = null };
            const Cpu = struct {
                grid: density.Grid,
                bins: *const density.Bins,
                threads: u16,
                out: []i64,
                fn run(c: @This()) !void {
                    try density.windowAreasCpu(c.grid, c.bins, c.threads, c.out);
                    std.mem.doNotOptimizeAway(c.out.ptr);
                }
            };
            row.cpu1 = try timeMs(b.io, Cpu{ .grid = grid, .bins = &bins, .threads = 1, .out = got }, Cpu.run);
            row.cpun = try timeMs(b.io, Cpu{ .grid = grid, .bins = &bins, .threads = b.threads, .out = got }, Cpu.run);
            const backend = b.backend orelse continue;
            const Gpu = struct {
                gpa: Allocator,
                backend: geom.Device.Backend,
                grid: density.Grid,
                bins: *const density.Bins,
                out: []i64,
                fn run(c: @This()) !void {
                    try density.windowAreasGpu(c.gpa, c.backend, c.grid, c.bins, c.out);
                    std.mem.doNotOptimizeAway(c.out.ptr);
                }
            };
            row.gpu = try timeMs(b.io, Gpu{ .gpa = b.gpa, .backend = backend, .grid = grid, .bins = &bins, .out = got }, Gpu.run);
        }
        try b.table("density windows (i64)", "rects", "visits", &rows, 1);
    }

    /// `geom.linalg.axpy` over `n` f64 (xpay is the same zip shape): the
    /// Gompute CPU kernel against the GPU round trip (two columns up, one
    /// down). The CPU kernel is single-threaded, so cpuN is not run.
    fn axpy(b: Bench) !void {
        const sizes = [_]u64{ 1 << 10, 1 << 14, 1 << 18, 1 << 20, 1 << 22, 1 << 24 };
        var rows: [sizes.len]Row = undefined;
        for (sizes, &rows) |n, *row| {
            const x = try b.gpa.alloc(f64, n);
            defer b.gpa.free(x);
            const y = try b.gpa.alloc(f64, n);
            defer b.gpa.free(y);
            const z = try b.gpa.alloc(f64, n);
            defer b.gpa.free(z);
            for (x, y, 0..) |*xi, *yi, i| {
                xi.* = @floatFromInt(i);
                yi.* = 1.0;
            }
            row.* = .{ .size = n, .work = n, .cpu1 = null, .cpun = null, .setup = null, .gpu = null };
            row.cpu1 = try timeMs(b.io, Zip(.cpu){ .x = x, .y = y, .z = z }, Zip(.cpu).run);
            const backend = b.backend orelse continue;
            row.gpu = switch (backend) {
                .cpu => unreachable,
                inline .cuda, .hip => |tag| blk: {
                    const Auto = g.AutoKernel(geom.linalg.axpy);
                    const T = Zip(@field(g.Backend, @tagName(tag)));
                    const built = if (tag == .cuda) Auto.Cuda.available else Auto.Hip.available;
                    break :blk if (comptime built) try timeMs(b.io, T{ .x = x, .y = y, .z = z }, T.run) else null;
                },
            };
        }
        try b.table("geom axpy (f64)", "n", "n", &rows, 1);
    }

    /// Prints a kernel's rows, then its crossover: the smallest work from
    /// which the GPU (setup amortized over `applies` calls) beats every CPU
    /// thread at every larger size.
    fn table(b: Bench, name: []const u8, size_unit: []const u8, work_unit: []const u8, rows: []const Row, applies: u32) !void {
        const o = b.out;
        try o.print("\n{s}\n  {s:>10} {s:>14} {s:>10} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{ name, size_unit, work_unit, "cpu1 ms", "cpuN ms", "setup ms", "gpu ms", "cpuN/gpu" });
        for (rows) |r| {
            try o.print("  {d:>10} {d:>14}", .{ r.size, r.work });
            for ([_]?f64{ r.cpu1, r.cpun, r.setup, r.gpu }) |t| {
                if (t) |ms| try o.print(" {d:>10.3}", .{ms}) else try o.print(" {s:>10}", .{"-"});
            }
            if (gpuCost(r, applies)) |gpu| try o.print(" {d:>8.2}\n", .{cpuBest(r) / gpu}) else try o.writeAll("        -\n");
        }
        var from: ?u64 = null;
        for (rows) |r| {
            const gpu = gpuCost(r, applies) orelse break;
            if (gpu < cpuBest(r)) {
                if (from == null) from = r.work;
            } else from = null;
        }
        if (b.backend == null) try o.print("  crossover: no GPU here\n", .{}) else if (from) |w| try o.print("  crossover: GPU wins from {d} {s}\n", .{ w, work_unit }) else try o.print("  crossover: GPU never wins in this sweep\n", .{});
        try o.flush();
    }
};

/// A random BEM operator of `n` panels without near pairs (the dense rows
/// are the cost): the potential rows alone, or the field rows of every
/// panel over a potential with no rows.
const Operator = struct {
    potential: extract.matvec.Potential,
    field: ?extract.dielectric.Field,

    fn init(gpa: Allocator, rng: *testgen.Rng, n: u64, field: bool) !Operator {
        var p: extract.matvec.Potential = .{ .cx = try column(gpa, rng, n, 2e-5), .cy = try column(gpa, rng, n, 2e-5), .cz = try column(gpa, rng, n, 2e-5), .radius = try column(gpa, rng, n, 1e-7), .k = try column(gpa, rng, n, 1e10), .near = .empty, .threads = 1 };
        try p.near.start.appendNTimes(gpa, 0, if (field) 1 else n + 1);
        if (!field) return .{ .potential = p, .field = null };
        var f: extract.dielectric.Field = .{ .first = 0, .cx = try gpa.dupe(f64, p.cx), .cy = try gpa.dupe(f64, p.cy), .cz = try gpa.dupe(f64, p.cz), .weight = try column(gpa, rng, n, 1), .scale = try column(gpa, rng, n, 1e6), .inverse_area = try column(gpa, rng, n, 1e12), .near = .empty, .threads = 1 };
        try f.near.start.appendNTimes(gpa, 0, n + 1);
        return .{ .potential = p, .field = f };
    }

    fn deinit(op: *Operator, gpa: Allocator) void {
        op.potential.deinit(gpa);
        if (op.field) |*f| f.deinit(gpa);
    }

    fn setThreads(op: *Operator, threads: u16) void {
        op.potential.threads = threads;
        if (op.field) |*f| f.threads = threads;
    }

    fn apply(op: *const Operator, x: []const f64, y: []f64) void {
        op.potential.apply(x, y);
        if (op.field) |*f| f.apply(x, y);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    const threads: u16 = @intCast(@min(std.Thread.getCpuCount() catch 1, 64));
    const backend: ?geom.Device.Backend = if (extract.gpu.compiled) |b| (if (geom.Device.available(b)) b else null) else null;
    try out.print("gpurify bench: {d} CPU threads, GPU {s}\n", .{ threads, if (backend) |b| @tagName(b) else "none (CPU columns only)" });
    const b = Bench{ .gpa = gpa, .io = io, .out = out, .threads = threads, .backend = backend, .spacing_rules = try spacingRules(gpa) };
    try b.calibration();
    try b.bem(.potential);
    try b.bem(.field);
    try b.pairs();
    try b.windows();
    try b.axpy();
    try out.flush();
}

// ---- private ----

/// The faster CPU column.
fn cpuBest(r: Row) f64 {
    return @min(r.cpu1 orelse std.math.inf(f64), r.cpun orelse std.math.inf(f64));
}

/// One GPU call with its setup amortized over `applies` calls.
fn gpuCost(r: Row, applies: u32) ?f64 {
    const gpu = r.gpu orelse return null;
    return gpu + (r.setup orelse 0) / @as(f64, @floatFromInt(applies));
}

/// The fastest of the repeats after a warm-up, in ms: at least two runs,
/// more until 0.3 s is spent (at most 20); one run when it alone takes 2 s.
fn timeMs(io: Io, ctx: anytype, comptime run: fn (@TypeOf(ctx)) anyerror!void) !f64 {
    var best: i96 = std.math.maxInt(i96);
    var spent: i96 = 0;
    var runs: u32 = 0;
    while (runs < 2 or (spent < 300 * std.time.ns_per_ms and runs < 20)) : (runs += 1) {
        const start = Io.Timestamp.now(io, .awake);
        try run(ctx);
        const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        spent += ns;
        if (runs > 0) best = @min(best, ns);
        if (runs == 0 and ns > 2 * std.time.ns_per_s) {
            best = ns;
            break;
        }
    }
    return @as(f64, @floatFromInt(best)) / std.time.ns_per_ms;
}

/// `out = alpha x + y` through Gompute's kernel on `backend`, the whole
/// round trip each call.
fn Zip(comptime backend: g.Backend) type {
    return struct {
        x: []const f64,
        y: []const f64,
        z: []f64,
        fn run(c: @This()) !void {
            var k = try g.Kernel(geom.linalg.axpy, backend).init(0);
            defer k.deinit();
            try k.run(c.x, c.y, c.z, .{ .alpha = 0.5 });
            std.mem.doNotOptimizeAway(c.z[c.z.len - 1]);
        }
    };
}

/// The sky130 deck's `min_spacing` rules.
fn spacingRules(gpa: Allocator) !u32 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var strings: geom.StrTable = .empty;
    var diag: check.deck.compile.Diag = .{};
    const deck = try check.deck.compile.compile(arena, arena, gpurify.pdks.sky130, try .init(1000), &strings, &diag);
    var n: u32 = 0;
    for (0..deck.drc.len()) |at| n += @intFromBool(deck.drc.get(@intCast(at)) == .min_spacing);
    return n;
}

/// `n` uniform values in `[0, scale)`.
fn column(gpa: Allocator, rng: *testgen.Rng, n: u64, scale: f64) ![]f64 {
    const c = try gpa.alloc(f64, n);
    for (c) |*v| v.* = rng.unit() * scale;
    return c;
}
