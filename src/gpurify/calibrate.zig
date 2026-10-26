//! `--backend auto`'s thresholds, measured on the machine present: one
//! small representative kernel per `Device.MinWork` class, timed on the CPU
//! (the configured threads) and on the GPU, and each class's crossover work
//! from the two fitted cost lines. In: the GPU backend, the thread count, a
//! clock. Out: `Device.MinWork`. Runs once per process, before the run.
//!
//! Each side's cost is a line `t(W) = fixed + per_work · W`, its per-call
//! transfers included: the f64 class's `x` up and `y` down per apply (the
//! columns go up once per solve, so are left out); the resident class's
//! pair list up and distances down, the store already resident (uploaded
//! once per run, paid by the first call that goes to the GPU); the
//! streamed class's whole binned input up per call. On each side the size
//! doubles until one call takes `stop_ns`, so a big card or a many-core
//! host is measured busy and a small one stops early; the line runs
//! through the last two sizes, its `fixed` at least the smallest call's
//! time. Calibration moves calls between devices and never changes a
//! result: every GPU kernel is bit-identical to its CPU body.
//!
//! Contents:
//! - `pub const Line = struct { fixed_ns: f64, per_work_ns: f64 }`, `pub const Fit = struct { cpu: Line, gpu: Line }`,
//!   `pub const Fits = struct { float: Fit, resident: Fit, streamed: Fit }`
//! - `pub fn measure(gpa: Allocator, io: std.Io, backend: Device.Backend, threads: u16) !Fits`
//! - `pub fn minWork(fits: Fits) Device.MinWork`
//! - `pub fn crossover(fit: Fit) u64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Device = geom.Device;
const Bbox = geom.Bbox;
const check = @import("check");
const distance = check.proximity_distance;
const density = check.drc.density;
const extract = @import("extract");
const Potential = extract.matvec.Potential;

/// A call's cost in ns at work `W`: `fixed_ns + per_work_ns · W`.
pub const Line = struct { fixed_ns: f64, per_work_ns: f64 };

/// One class's cost on each side.
pub const Fit = struct { cpu: Line, gpu: Line };

pub const Fits = struct { float: Fit, resident: Fit, streamed: Fit };

/// One call at least this long ends a side's size sweep: long enough that
/// the CPU's threads and the GPU's lanes are busy, so the last two sizes
/// give the marginal cost of the big calls the threshold is for.
const stop_ns: f64 = 8 * std.time.ns_per_ms;

/// One timed size.
const Point = struct { work: f64, ns: f64 };

/// One side's growing sizes: the smallest call and the last two.
const Sweep = struct {
    first: ?Point = null,
    prev: ?Point = null,
    last: ?Point = null,

    fn add(s: *Sweep, work: f64, ns: f64) void {
        const p: Point = .{ .work = work, .ns = ns };
        if (s.first == null) s.first = p;
        s.prev = s.last;
        s.last = p;
    }

    fn more(s: Sweep) bool {
        const last = s.last orelse return true;
        return s.prev == null or last.ns < stop_ns;
    }

    fn line(s: Sweep) Line {
        return through(s.prev.?, s.last.?, s.first.?.ns);
    }
};

/// Times one class's kernel on both sides. `threads` is the run's CPU
/// thread count; `backend` a GPU backend that runs here.
pub fn measure(gpa: Allocator, io: std.Io, backend: Device.Backend, threads: u16) !Fits {
    assert(backend != .cpu);
    return .{
        .float = try floatFit(gpa, io, backend, threads),
        .resident = try residentFit(gpa, io, backend, threads),
        .streamed = try streamedFit(gpa, io, backend, threads),
    };
}

/// Each class's crossover.
pub fn minWork(fits: Fits) Device.MinWork {
    return .{ .float = crossover(fits.float), .resident = crossover(fits.resident), .streamed = crossover(fits.streamed) };
}

/// The least work at which the GPU line is below the CPU line: never
/// (`maxInt`) when the GPU's marginal cost is no lower, 0 when the GPU is
/// cheaper everywhere.
pub fn crossover(fit: Fit) u64 {
    const gain = fit.cpu.per_work_ns - fit.gpu.per_work_ns;
    if (!(gain > 0)) return std.math.maxInt(u64);
    const w = @ceil((fit.gpu.fixed_ns - fit.cpu.fixed_ns) / gain);
    if (w <= 0) return 0;
    return if (w >= 0x1p63) std.math.maxInt(u64) else @intFromFloat(w);
}

// ---- private ----

/// BEM potential rows of `P` panels (P² pairs), P doubling from 256 to
/// at most 32768.
fn floatFit(gpa: Allocator, io: std.Io, backend: Device.Backend, threads: u16) !Fit {
    const Ctx = struct {
        p: *Potential,
        gpu: ?*extract.gpu.Gpu,
        x: []const f64,
        y: []f64,
        fn run(c: @This()) !void {
            if (c.gpu) |gp| try gp.apply(c.x, c.y) else c.p.apply(c.x, c.y);
        }
    };
    var cpu: Sweep = .{};
    var gpu: Sweep = .{};
    var n: u32 = 256;
    while ((cpu.more() or gpu.more()) and n <= 32768) : (n *= 2) {
        var p = try potential(gpa, n, threads);
        defer p.deinit(gpa);
        const xy = try gpa.alloc(f64, 2 * n);
        defer gpa.free(xy);
        @memset(xy, 1e-15);
        const work = @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(n));
        var ctx: Ctx = .{ .p = &p, .gpu = null, .x = xy[0..n], .y = xy[n..] };
        if (cpu.more()) cpu.add(work, try timeNs(io, cpu.first == null, ctx, Ctx.run));
        if (!gpu.more()) continue;
        const device: Device = .{ .backend = backend, .min_work = .always, .threads = threads };
        var on = extract.gpu.Gpu.init(gpa, device, &p, null) orelse return error.NoGpu;
        defer on.deinit();
        ctx.gpu = &on;
        gpu.add(work, try timeNs(io, gpu.first == null, ctx, Ctx.run));
    }
    return .{ .cpu = cpu.line(), .gpu = gpu.line() };
}

/// Pair distances over a store of 65536 rectangles (16 edge pairs a pair),
/// the store resident, the pair count doubling from 16k to at most 4M.
fn residentFit(gpa: Allocator, io: std.Io, backend: Device.Backend, threads: u16) !Fit {
    const rects = 1 << 16;
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    {
        var b: geom.GeometryStoreBuilder = .empty;
        defer b.deinit(gpa);
        for (0..rects) |i| {
            const x: i64 = @intCast(i % 256 * 300);
            const y: i64 = @intCast(i / 256 * 300);
            _ = try b.push(gpa, @fromBackingInt(0), &.{ x, x + 200, x + 200, x }, &.{ y, y, y + 100, y + 100 });
        }
        var perm: std.ArrayList(u32) = .empty;
        defer perm.deinit(gpa);
        try b.finish(gpa, 1, &store, &perm);
    }
    const max_pairs = 1 << 22;
    const pairs = try gpa.alloc(geom.index.Pair, max_pairs);
    defer gpa.free(pairs);
    for (pairs, 0..) |*p, i| p.* = .{ .a = @fromBackingInt(@intCast(i % rects)), .b = @fromBackingInt(@intCast((i * 7 + 1) % rects)) };
    const out = try gpa.alloc(i64, max_pairs);
    defer gpa.free(out);
    var resident: geom.ResidentStore = .empty;
    defer resident.deinit();
    const Ctx = struct {
        gpa: Allocator,
        backend: ?Device.Backend,
        resident: *geom.ResidentStore,
        store: *const geom.GeometryStore,
        pairs: []const geom.index.Pair,
        threads: u16,
        out: []i64,
        fn run(c: @This()) !void {
            if (c.backend) |b| {
                try distance.cappedDistancesGpu(c.gpa, b, c.resident, c.store, c.pairs, c.out);
            } else try distance.cappedDistancesCpu(c.store, c.pairs, c.threads, c.out);
        }
    };
    var cpu: Sweep = .{};
    var gpu: Sweep = .{};
    var n: usize = 1 << 14;
    while ((cpu.more() or gpu.more()) and n <= max_pairs) : (n *= 2) {
        const work: f64 = @floatFromInt(16 * n);
        var ctx: Ctx = .{ .gpa = gpa, .backend = null, .resident = &resident, .store = &store, .pairs = pairs[0..n], .threads = threads, .out = out[0..n] };
        if (cpu.more()) cpu.add(work, try timeNs(io, cpu.first == null, ctx, Ctx.run));
        ctx.backend = backend;
        if (gpu.more()) gpu.add(work, try timeNs(io, gpu.first == null, ctx, Ctx.run));
    }
    return .{ .cpu = cpu.line(), .gpu = gpu.line() };
}

/// Density windows over a die of side `S` tiled by 1000-DBU squares at a
/// 2000 pitch, 20000-DBU windows every 10000 (the bench's grid), work in
/// rectangle visits, S doubling from 100k to at most 800k.
fn streamedFit(gpa: Allocator, io: std.Io, backend: Device.Backend, threads: u16) !Fit {
    const Ctx = struct {
        gpa: Allocator,
        backend: ?Device.Backend,
        grid: density.Grid,
        bins: *const density.Bins,
        threads: u16,
        out: []i64,
        fn run(c: @This()) !void {
            if (c.backend) |b| {
                try density.windowAreasGpu(c.gpa, b, c.grid, c.bins, c.out);
            } else try density.windowAreasCpu(c.grid, c.bins, c.threads, c.out);
        }
    };
    var cpu: Sweep = .{};
    var gpu: Sweep = .{};
    var side: i64 = 100_000;
    while ((cpu.more() or gpu.more()) and side <= 800_000) : (side *= 2) {
        const per: usize = @intCast(@divExact(side, 2000));
        const rects = try gpa.alloc(Bbox, per * per);
        defer gpa.free(rects);
        for (rects, 0..) |*r, i| {
            const x: i64 = @intCast(i % per * 2000);
            const y: i64 = @intCast(i / per * 2000);
            r.* = .{ .xlo = x, .ylo = y, .xhi = x + 1000, .yhi = y + 1000 };
        }
        const grid = density.Grid.over(.{ .xlo = 0, .ylo = 0, .xhi = side, .yhi = side }, 20_000, 10_000).?;
        var bins: density.Bins = .{};
        defer bins.deinit(gpa);
        try bins.fill(gpa, grid, rects);
        const out = try gpa.alloc(i64, grid.count());
        defer gpa.free(out);
        const work: f64 = @floatFromInt(density.visits(grid, &bins));
        var ctx: Ctx = .{ .gpa = gpa, .backend = null, .grid = grid, .bins = &bins, .threads = threads, .out = out };
        if (cpu.more()) cpu.add(work, try timeNs(io, cpu.first == null, ctx, Ctx.run));
        ctx.backend = backend;
        if (gpu.more()) gpu.add(work, try timeNs(io, gpu.first == null, ctx, Ctx.run));
    }
    return .{ .cpu = cpu.line(), .gpu = gpu.line() };
}

/// The line through `a` and `b`, its slope positive and its intercept at
/// least `floor_ns`, so it never promises a call cheaper than one measured.
fn through(a: Point, b: Point, floor_ns: f64) Line {
    assert(b.work > a.work);
    const per = @max((b.ns - a.ns) / (b.work - a.work), 1e-6);
    return .{ .fixed_ns = @max(b.ns - per * b.work, floor_ns), .per_work_ns = per };
}

/// One run's wall time in ns, after an untimed one when `warm` (a side's
/// first size: the kernel load and the first touch of its memory).
fn timeNs(io: std.Io, warm: bool, ctx: anytype, comptime run: fn (@TypeOf(ctx)) anyerror!void) !f64 {
    if (warm) try run(ctx);
    const start = std.Io.Timestamp.now(io, .awake);
    try run(ctx);
    return @floatFromInt(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}

/// `n` random panels with no near pairs (the dense rows are the cost):
/// the bench's operator, every row written.
fn potential(gpa: Allocator, n: u32, threads: u16) !Potential {
    var seed: u64 = 0x9e37_79b9_7f4a_7c15 ^ @as(u64, n);
    var p: Potential = .{ .cx = &.{}, .cy = &.{}, .cz = &.{}, .radius = &.{}, .k = &.{}, .near = .empty, .threads = threads };
    errdefer p.deinit(gpa);
    inline for (.{ "cx", "cy", "cz", "radius", "k" }, .{ 2e-5, 2e-5, 2e-5, 1e-7, 1e10 }) |name, scale| {
        @field(p, name) = try gpa.alloc(f64, n);
        for (@field(p, name)) |*v| v.* = unit(&seed) * scale;
    }
    try p.near.start.appendNTimes(gpa, 0, n + 1);
    return p;
}

/// Uniform in `[0, 1)`, xorshift.
fn unit(seed: *u64) f64 {
    seed.* ^= seed.* << 13;
    seed.* ^= seed.* >> 7;
    seed.* ^= seed.* << 17;
    return @as(f64, @floatFromInt(seed.* >> 11)) * 0x1p-53;
}

test "crossover solves the two cost lines" {
    // Oracle: by hand. CPU 1 + 2W, GPU 101 + 1W meet at W = 100; a GPU
    // cheaper at every size crosses at 0; a GPU whose marginal cost is no
    // lower never crosses.
    try std.testing.expectEqual(@as(u64, 100), crossover(.{ .cpu = .{ .fixed_ns = 1, .per_work_ns = 2 }, .gpu = .{ .fixed_ns = 101, .per_work_ns = 1 } }));
    try std.testing.expectEqual(@as(u64, 0), crossover(.{ .cpu = .{ .fixed_ns = 50, .per_work_ns = 2 }, .gpu = .{ .fixed_ns = 10, .per_work_ns = 1 } }));
    try std.testing.expectEqual(std.math.maxInt(u64), crossover(.{ .cpu = .{ .fixed_ns = 50, .per_work_ns = 1 }, .gpu = .{ .fixed_ns = 10, .per_work_ns = 1 } }));
    try std.testing.expectEqual(std.math.maxInt(u64), crossover(.{ .cpu = .{ .fixed_ns = 0, .per_work_ns = 1e-6 }, .gpu = .{ .fixed_ns = 1e18, .per_work_ns = 0 } }));
}

test "a line never promises less than the smallest measured call" {
    // Oracle: by hand. Through (10, 30) and (20, 40): slope 1, intercept 20,
    // raised to the floor 25; a falling pair keeps a positive slope.
    const l = through(.{ .work = 10, .ns = 30 }, .{ .work = 20, .ns = 40 }, 25);
    try std.testing.expectEqual(@as(f64, 1), l.per_work_ns);
    try std.testing.expectEqual(@as(f64, 25), l.fixed_ns);
    try std.testing.expect(through(.{ .work = 1, .ns = 9 }, .{ .work = 2, .ns = 8 }, 0).per_work_ns > 0);
}
