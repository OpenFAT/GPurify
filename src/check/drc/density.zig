//! The density windows' covered areas, a row kernel: one generic body per
//! window sums the clipped areas of the disjoint rectangles binned to its
//! window row. In: a window grid and disjoint rectangles. Out: one exact
//! covered area per window, in row order (`iy`, then `ix`), bit-identical on
//! the CPU threads and the GPU. Ported from crates/check/src/drc/rules/area.rs
//! (`WindowGrid`, `window_areas`, `positions`).
//!
//! Exactness decision: every area is an `i64`. A window side is refused at
//! or past `max_side` (2^31), so a window's area, and the sum of the
//! disjoint clips inside it, stays below 2^62; device buffers carry no
//! `i128`, and none is needed. The body reads plain `i64`/`u32` columns and
//! names no `geom` declaration, so the device compile exports geom's kernels
//! once. The device root exports it as `check_window_area`; the CPU runs it
//! over contiguous window blocks, one `std.Thread` per block.
//!
//! Contents:
//! - `pub const max_side: i64`
//! - `pub const Grid = struct`, `Grid.over(die: Bbox, window: Dbu, step: Dbu) ?Grid`, `Grid.count(g) u64`,
//!   `Grid.window(g, w: u64) Bbox`
//! - `pub const Bins = struct`, `Bins.deinit`, `Bins.fill(b, gpa: Allocator, g: Grid, rects: []const Bbox) Allocator.Error!void`
//! - `pub const Error`, `pub const GpuError`
//! - `pub fn windowAreasInto(gpa: Allocator, device: Device, g: Grid, rects: []const Bbox, out: *std.ArrayList(i64)) Error!void`
//! - `pub fn visits(g: Grid, bins: *const Bins) u64`
//! - `pub fn windowAreasCpu(g: Grid, bins: *const Bins, threads: u16, out: []i64) std.Thread.SpawnError!void`
//! - `pub fn windowAreasGpu(gpa: Allocator, backend: Device.Backend, g: Grid, bins: *const Bins, out: []i64) GpuError!void`
//! - `pub fn windowArea(w: u64, cols: u64, x0: i64, y0: i64, side: i64, stride: i64, row_start: anytype, reach: anytype, xlo: anytype, ylo: anytype, xhi: anytype, yhi: anytype) i64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const g_ = @import("gompute");
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const Device = geom.Device;

/// A window side at or past this is refused: below it every window area is
/// under 2^62, exact in an `i64`. Spelled without `geom` (device compile).
pub const max_side: i64 = 1 << 31;

pub const Error = Allocator.Error || std.Thread.SpawnError;

pub const GpuError = Allocator.Error || g_.Error || error{
    /// This build carries no device artifact for the backend asked for.
    NotBuilt,
};

/// A density sweep: `cols x ways` windows of `side`, origins `stride`
/// apart from `(x0, y0)`.
pub const Grid = struct {
    x0: i64,
    y0: i64,
    side: i64,
    stride: i64,
    cols: u32,
    ways: u32,

    /// The windows of side `window`, origins `step` apart from `die`'s lower
    /// left corner, covering it; null (refused) when the sweep leaves the
    /// coordinate domain, the side reaches `max_side`, or the count passes
    /// `u32` per axis.
    pub fn over(die: Bbox, side: Dbu, step: Dbu) ?Grid {
        if (side >= max_side) return null;
        const cols = positions(die.xhi - die.xlo, side, step);
        const ways = positions(die.yhi - die.ylo, side, step);
        if (cols > std.math.maxInt(u32) or ways > std.math.maxInt(u32)) return null;
        if (!geom.inDomain(die.xlo + (cols - 1) * step + side) or !geom.inDomain(die.ylo + (ways - 1) * step + side)) return null;
        return .{ .x0 = die.xlo, .y0 = die.ylo, .side = side, .stride = step, .cols = @intCast(cols), .ways = @intCast(ways) };
    }

    pub fn count(g: Grid) u64 {
        return @as(u64, g.cols) * g.ways;
    }

    /// Window `w`, in row order.
    pub fn window(g: Grid, w: u64) Bbox {
        const iy: i64 = @intCast(w / g.cols);
        const ix: i64 = @intCast(w % g.cols);
        const x = g.x0 + ix * g.stride;
        const y = g.y0 + iy * g.stride;
        return .{ .xlo = x, .ylo = y, .xhi = x + g.side, .yhi = y + g.side };
    }
};

/// Rectangles binned by the window rows they overlap, CSR by row, each row
/// sorted by `xlo`, with its widest rectangle (`reach`).
pub const Bins = struct {
    row_start: std.ArrayList(u32) = .empty,
    reach: std.ArrayList(i64) = .empty,
    xlo: std.ArrayList(i64) = .empty,
    ylo: std.ArrayList(i64) = .empty,
    xhi: std.ArrayList(i64) = .empty,
    yhi: std.ArrayList(i64) = .empty,

    pub fn deinit(b: *Bins, gpa: Allocator) void {
        inline for (@typeInfo(Bins).@"struct".field_names) |name| @field(b, name).deinit(gpa);
    }

    /// Refills from disjoint `rects` over grid `g`.
    pub fn fill(b: *Bins, gpa: Allocator, g: Grid, rects: []const Bbox) Allocator.Error!void {
        try b.row_start.resize(gpa, @as(usize, g.ways) + 1);
        @memset(b.row_start.items, 0);
        for (rects) |r| {
            const rows = hit(g, r.ylo, r.yhi, g.y0, g.ways);
            for (rows[0]..rows[1]) |iy| b.row_start.items[iy + 1] += 1;
        }
        for (1..b.row_start.items.len) |i| b.row_start.items[i] += b.row_start.items[i - 1];
        const total = b.row_start.items[g.ways];
        const order = try gpa.alloc(Bbox, total);
        defer gpa.free(order);
        const next = try gpa.dupe(u32, b.row_start.items[0..g.ways]);
        defer gpa.free(next);
        for (rects) |r| {
            const rows = hit(g, r.ylo, r.yhi, g.y0, g.ways);
            for (rows[0]..rows[1]) |iy| {
                order[next[iy]] = r;
                next[iy] += 1;
            }
        }
        try b.reach.resize(gpa, g.ways);
        inline for (.{ "xlo", "ylo", "xhi", "yhi" }) |name| try @field(b, name).resize(gpa, total);
        for (0..g.ways) |iy| {
            const row = order[b.row_start.items[iy]..b.row_start.items[iy + 1]];
            std.mem.sortUnstable(Bbox, row, {}, lessXlo);
            var reach: i64 = 0;
            for (row, b.row_start.items[iy]..) |r, k| {
                b.xlo.items[k] = r.xlo;
                b.ylo.items[k] = r.ylo;
                b.xhi.items[k] = r.xhi;
                b.yhi.items[k] = r.yhi;
                reach = @max(reach, r.xhi - r.xlo);
            }
            b.reach.items[iy] = reach;
        }
    }
};

/// Lanes per device block.
const block = 256;

/// The exact covered area of every window of `g` for disjoint `rects`, into
/// `out` (cleared and refilled), row order. On the GPU when `device` says so
/// and the work is at least `device.min_work.streamed` rectangle visits
/// (`visits`), falling back to the CPU without a driver; the answer is
/// bit-identical either way.
pub fn windowAreasInto(gpa: Allocator, device: Device, g: Grid, rects: []const Bbox, out: *std.ArrayList(i64)) Error!void {
    var bins: Bins = .{};
    defer bins.deinit(gpa);
    try bins.fill(gpa, g, rects);
    try out.resize(gpa, g.count());
    const on_gpu = switch (device.backend) {
        .cpu => false,
        .cuda, .hip => visits(g, &bins) >= device.min_work.streamed,
    };
    const done = on_gpu and if (windowAreasGpu(gpa, device.backend, g, &bins, out.items)) true else |_| false;
    if (!done) try windowAreasCpu(g, &bins, device.threads, out.items);
}

/// The work estimate the GPU threshold reads: the window-rectangle pairs
/// the kernel clips, each binned rectangle once per window of its row it
/// overlaps along x, plus one row search per window. (Binned rectangles
/// times columns, the old estimate, counted every window of the row for
/// every rectangle.)
pub fn visits(g: Grid, bins: *const Bins) u64 {
    var work: u64 = g.count();
    for (bins.xlo.items, bins.xhi.items) |lo, hi| {
        const cols = hit(g, lo, hi, g.x0, g.cols);
        work += cols[1] - cols[0];
    }
    return work;
}

/// `windowArea` over every window, into `out`, on `threads` CPU threads over
/// contiguous blocks (the caller's thread takes the first).
pub fn windowAreasCpu(g: Grid, bins: *const Bins, threads: u16, out: []i64) std.Thread.SpawnError!void {
    assert(out.len == g.count());
    // A thread under ~1k windows costs more to spawn than it saves.
    const blocks: usize = @max(1, @min(threads, out.len / 1024));
    var workers: [64]std.Thread = undefined;
    const spawned = @min(blocks, workers.len) - 1;
    var started: usize = 0;
    defer for (workers[0..started]) |w| w.join();
    const per = std.math.divCeil(usize, out.len, spawned + 1) catch unreachable;
    for (0..spawned) |k| {
        const from = @min((k + 1) * per, out.len);
        const to = @min(from + per, out.len);
        workers[k] = try std.Thread.spawn(.{}, runBlock, .{ g, bins, from, out[from..to] });
        started += 1;
    }
    runBlock(g, bins, 0, out[0..@min(per, out.len)]);
}

/// `windowArea` over every window, into `out`, on the GPU through the raw
/// kernel `check_window_area`. Fails (never falls back) when the build or
/// the machine has no such device: the strict path a differential needs.
pub fn windowAreasGpu(gpa: Allocator, backend: Device.Backend, g: Grid, bins: *const Bins, out: []i64) GpuError!void {
    assert(out.len == g.count());
    return switch (backend) {
        .cpu => error.NotBuilt,
        inline .cuda, .hip => |b| if (comptime built(b)) runGpu(b, gpa, g, bins, out) else error.NotBuilt,
    };
}

/// The covered area of window `w` (row order, `cols` per row): the clipped
/// areas of the rectangles binned to its row (`row_start` CSR over `xlo`,
/// `ylo`, `xhi`, `yhi`, each row ascending by `xlo`, `reach` its widest),
/// summed. Host slices or device pointers alike.
pub fn windowArea(w: u64, cols: u64, x0: i64, y0: i64, side: i64, stride: i64, row_start: anytype, reach: anytype, xlo: anytype, ylo: anytype, xhi: anytype, yhi: anytype) i64 {
    const iy = w / cols;
    const ix = w - iy * cols;
    const wx = x0 + @as(i64, @intCast(ix)) * stride;
    const wy = y0 + @as(i64, @intCast(iy)) * stride;
    const wxh = wx + side;
    const wyh = wy + side;
    var lo: u32 = row_start[iy];
    var hi: u32 = row_start[iy + 1];
    const end = hi;
    // The first rectangle that can reach the window: `xlo >= wx - reach`.
    const from = wx - reach[iy];
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        if (xlo[m] < from) lo = m + 1 else hi = m;
    }
    var sum: i64 = 0;
    var k = lo;
    while (k < end and xlo[k] < wxh) : (k += 1) {
        const width = @max(@min(xhi[k], wxh) - @max(xlo[k], wx), 0);
        const height = @max(@min(yhi[k], wyh) - @max(ylo[k], wy), 0);
        sum += width * height;
    }
    return sum;
}

// ---- private ----

/// The device entry: one lane per window.
fn kernel(n: u64, cols: u64, x0: i64, y0: i64, side: i64, stride: i64, row_start: g_.GlobalPtr(u32), reach: g_.GlobalPtr(i64), xlo: g_.GlobalPtr(i64), ylo: g_.GlobalPtr(i64), xhi: g_.GlobalPtr(i64), yhi: g_.GlobalPtr(i64), out: g_.GlobalPtr(i64)) callconv(g_.kernel_callconv) void {
    const i = g_.globalIdX(block);
    if (i >= n) return;
    out[i] = windowArea(i, cols, x0, y0, side, stride, row_start, reach, xlo, ylo, xhi, yhi);
}

comptime {
    if (g_.is_device) g_.exportRaw("check_window_area", &kernel);
}

fn runBlock(g: Grid, bins: *const Bins, first: usize, out: []i64) void {
    for (out, first..) |*o, w| o.* = windowArea(w, g.cols, g.x0, g.y0, g.side, g.stride, bins.row_start.items, bins.reach.items, bins.xlo.items, bins.ylo.items, bins.xhi.items, bins.yhi.items);
}

/// Window origins a sweep of `span` takes, rounded up so the far edge is
/// covered; at least one.
fn positions(span: i64, window: i64, step: i64) i64 {
    return @divTrunc(@max(span - window, 0) + step - 1, step) + 1;
}

/// The window indices along one axis that `lo..hi` overlaps with positive
/// length, `[first, end)`.
fn hit(g: Grid, lo: i64, hi: i64, origin: i64, n: u32) [2]usize {
    const nn: i64 = n;
    const first = std.math.clamp(@divFloor(lo - origin - g.side, g.stride) + 1, 0, nn);
    const last = @min(@divFloor(hi - origin - 1, g.stride), nn - 1);
    return .{ @intCast(first), @intCast(@max(last + 1, first)) };
}

fn lessXlo(_: void, a: Bbox, b: Bbox) bool {
    return a.xlo < b.xlo or (a.xlo == b.xlo and (a.ylo < b.ylo or (a.ylo == b.ylo and a.xhi < b.xhi)));
}

/// Whether this build compiled the kernel roots for `backend`.
fn built(comptime backend: Device.Backend) bool {
    const Auto = g_.AutoKernel(geom.linalg.axpy);
    return switch (backend) {
        .cpu => false,
        .cuda => Auto.Cuda.available,
        .hip => Auto.Hip.available,
    };
}

fn runGpu(comptime backend: Device.Backend, gpa: Allocator, g: Grid, bins: *const Bins, out: []i64) GpuError!void {
    const tag: g_.Backend = switch (backend) {
        .cpu => unreachable,
        .cuda => .cuda,
        .hip => .hip,
    };
    var k = try g_.RawKernel("check_window_area", tag).init(0);
    defer k.deinit();
    if (out.len == 0) return;
    // One allocation and one copy for every column, `out` reserved after them.
    const bytes = std.mem.sliceAsBytes;
    const columns = [_][]const u8{ bytes(bins.row_start.items), bytes(bins.reach.items), bytes(bins.xlo.items), bytes(bins.ylo.items), bytes(bins.xhi.items), bytes(bins.yhi.items) };
    var offsets: [7]usize = undefined;
    var addresses: [7]usize = undefined;
    var buffer = try geom.bulk.upload(@TypeOf(k), &k, gpa, &columns, &.{out.len * @sizeOf(i64)}, &offsets, &addresses);
    defer buffer.free();
    var n: u64 = out.len;
    var cols: u64 = g.cols;
    var x0 = g.x0;
    var y0 = g.y0;
    var side = g.side;
    var stride = g.stride;
    var args: [13]g_.interface.Arg = undefined;
    args[0] = g_.interface.arg(&n);
    args[1] = g_.interface.arg(&cols);
    args[2] = g_.interface.arg(&x0);
    args[3] = g_.interface.arg(&y0);
    args[4] = g_.interface.arg(&side);
    args[5] = g_.interface.arg(&stride);
    for (args[6..], &addresses) |*a, *address| a.* = g_.interface.arg(address);
    try k.launch(g_.Dim3.linear(out.len, block), .{ .x = block }, 0, &args);
    try k.synchronize();
    try buffer.downloadAt(out.ptr, offsets[6], out.len * @sizeOf(i64));
}

/// Rust's in-file xorshift.
fn rand(seed: *u64, n: i64) i64 {
    seed.* ^= seed.* << 13;
    seed.* ^= seed.* >> 7;
    seed.* ^= seed.* << 17;
    return @intCast(seed.* % @as(u64, @intCast(n)));
}

test "window areas match clipping every rectangle" {
    // Oracle: differential against clipping every rectangle to every window
    // (`geom.rects.clippedArea`), over 2000 random grids and disjoint
    // rectangle sets (one rectangle per 40-high band). Ported from
    // crates/check/src/drc/rules/area.rs `window_areas_match_clipping_every_rect`.
    const gpa = std.testing.allocator;
    var seed: u64 = 0x9e37_79b9_7f4a_7c15;
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(gpa);
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    for (0..2000) |_| {
        rects.clearRetainingCapacity();
        const n = rand(&seed, 12);
        for (0..@intCast(n)) |k| {
            const x = rand(&seed, 200) - 50;
            const y = @as(i64, @intCast(k)) * 40 - 30 + rand(&seed, 10);
            try rects.append(gpa, .{ .xlo = x, .ylo = y, .xhi = x + 1 + rand(&seed, 150), .yhi = y + 1 + rand(&seed, 29) });
        }
        const g: Grid = .{ .x0 = rand(&seed, 40) - 60, .y0 = rand(&seed, 40) - 60, .side = 1 + rand(&seed, 120), .stride = 1 + rand(&seed, 90), .cols = @intCast(1 + rand(&seed, 8)), .ways = @intCast(1 + rand(&seed, 8)) };
        try windowAreasInto(gpa, .cpu, g, rects.items, &out);
        for (out.items, 0..) |got, w| try std.testing.expectEqual(@as(i128, got), geom.rects.clippedArea(rects.items, g.window(w)));
    }
}

test "visits counts each binned rectangle once per window it overlaps along x" {
    // Oracle: brute force over every window of every grid: one row search,
    // plus each rectangle binned to its row whose x-span meets the window's
    // with positive length; 500 random grids and rectangle sets.
    const gpa = std.testing.allocator;
    var seed: u64 = 0x2545_f491_4f6c_dd1d;
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    var bins: Bins = .{};
    defer bins.deinit(gpa);
    for (0..500) |_| {
        rects.clearRetainingCapacity();
        for (0..@intCast(rand(&seed, 12))) |k| {
            const x = rand(&seed, 200) - 50;
            const y = @as(i64, @intCast(k)) * 40 - 30 + rand(&seed, 10);
            try rects.append(gpa, .{ .xlo = x, .ylo = y, .xhi = x + 1 + rand(&seed, 150), .yhi = y + 1 + rand(&seed, 29) });
        }
        const g: Grid = .{ .x0 = rand(&seed, 40) - 60, .y0 = rand(&seed, 40) - 60, .side = 1 + rand(&seed, 120), .stride = 1 + rand(&seed, 90), .cols = @intCast(1 + rand(&seed, 8)), .ways = @intCast(1 + rand(&seed, 8)) };
        try bins.fill(gpa, g, rects.items);
        var want: u64 = 0;
        for (0..g.count()) |w| {
            const win = g.window(w);
            const iy = w / g.cols;
            want += 1;
            for (bins.row_start.items[iy]..bins.row_start.items[iy + 1]) |k| {
                want += @intFromBool(@min(bins.xhi.items[k], win.xhi) > @max(bins.xlo.items[k], win.xlo));
            }
        }
        try std.testing.expectEqual(want, visits(g, &bins));
    }
}
