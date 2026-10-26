//! The shared hot kernel of every spacing, enclosure and net rule: the exact
//! boundary distance of each candidate pair. In: a `GeometryStore`, the
//! candidate pairs and the rule's limit. Out: one squared distance per pair,
//! exact wherever it is below `limit²`, and never below `limit²` where the
//! exact value is not. Ported from crates/check/src/drc/rules/mod.rs
//! (`pair_distances_into`, `capped_distances`, `capped_dist2_*`).
//!
//! A row kernel (ARCHITECTURE.md, GPU): `cappedDist2` is one generic body per
//! pair, integer-only (every gap clamped to `2^26`, so `gx² + gy² <= 2^53`
//! fits an `i64`), so the CPU threads and the GPU give the same bits. The
//! device root exports it as `check_capped_dist2`; the CPU runs it over
//! contiguous pair blocks, one `std.Thread` per block (0.18 has no
//! `std.Thread.Pool`). Rust used f64 lanes for SIMD; integers are as exact
//! and lower everywhere. A pair with a non-axis edge reads -1 from the body
//! and is measured on the host by `rects.polyDist2`.
//!
//! Contents:
//! - `pub const gap_cap: i64`
//! - `pub const Error = error{ OutOfMemory, SystemResources, ThreadQuotaExceeded, LockedMemoryLimitExceeded, Unexpected }`
//! - `pub fn pairDistancesInto(gpa: Allocator, device: Device, store: *const GeometryStore, pairs: []const Pair, limit: Dbu, dists: *std.ArrayList(DbuArea)) Error!void`
//! - `pub fn cappedDistancesCpu(store: *const GeometryStore, pairs: []const Pair, threads: u16, out: []i64) error{ SystemResources, ThreadQuotaExceeded, LockedMemoryLimitExceeded, Unexpected }!void`
//! - `pub fn cappedDistancesGpu(gpa: Allocator, backend: Device.Backend, store: *const GeometryStore, pairs: []const Pair, out: []i64) GpuError!void`, `pub const GpuError`
//! - `pub fn cappedDist2(a: u32, b: u32, vert_start: anytype, vert_len: anytype, xs: anytype, ys: anytype) i64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const g = @import("gompute");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Device = geom.Device;
const GeometryStore = geom.GeometryStore;
const Pair = geom.index.Pair;
const polyDist2 = @import("rects.zig").polyDist2;

/// Gaps are clamped here so `gx² + gy²` is exact in an `i64` (and in f64:
/// at most `2^53`). A limit at or past it takes the exact `i128` path. An
/// `i64` (a `Dbu`) spelled without `geom`: the device compile must reach no
/// `geom` declaration, or geom's own kernels export twice.
pub const gap_cap: i64 = 1 << 26;

pub const Error = Allocator.Error || std.Thread.SpawnError;

pub const GpuError = Allocator.Error || g.Error || error{
    /// This build carries no device artifact for the backend asked for.
    NotBuilt,
};

/// Lanes per device block.
const block = 256;

/// Squared boundary distance for every pair, into `dists` (cleared and
/// refilled): exact below `limit²`, and never below `limit²` where the exact
/// value is not. Rectilinear pairs under a limit below `gap_cap` take the
/// row kernel, on the GPU when `device` says so and the work is at least
/// `device.min_gpu_work` edge pairs, falling back to the CPU without a
/// driver; the answer is bit-identical either way.
pub fn pairDistancesInto(gpa: Allocator, device: Device, store: *const GeometryStore, pairs: []const Pair, limit: Dbu, dists: *std.ArrayList(DbuArea)) Error!void {
    assert(limit >= 0);
    try dists.resize(gpa, pairs.len);
    if (limit >= gap_cap) {
        for (dists.items, pairs) |*d, p| d.* = polyDist2(store, p.a, p.b);
        return;
    }
    const capped = try gpa.alloc(i64, pairs.len);
    defer gpa.free(capped);
    const on_gpu = switch (device.backend) {
        .cpu => false,
        .cuda, .hip => edgePairs(store, pairs) >= device.min_gpu_work,
    };
    const done = on_gpu and if (cappedDistancesGpu(gpa, device.backend, store, pairs, capped)) true else |_| false;
    if (!done) try cappedDistancesCpu(store, pairs, device.threads, capped);
    for (dists.items, capped, pairs) |*d, c, p| d.* = if (c >= 0) c else polyDist2(store, p.a, p.b);
}

/// `cappedDist2` over every pair, into `out`, on `threads` CPU threads over
/// contiguous blocks (the caller's thread takes the first).
pub fn cappedDistancesCpu(store: *const GeometryStore, pairs: []const Pair, threads: u16, out: []i64) std.Thread.SpawnError!void {
    assert(out.len == pairs.len);
    // A thread under ~1k pairs costs more to spawn than it saves.
    const blocks: usize = @max(1, @min(threads, pairs.len / 1024));
    var workers: [64]std.Thread = undefined;
    const spawned = @min(blocks, workers.len) - 1;
    var started: usize = 0;
    defer for (workers[0..started]) |w| w.join();
    const per = std.math.divCeil(usize, pairs.len, spawned + 1) catch unreachable;
    for (0..spawned) |k| {
        const from = @min((k + 1) * per, pairs.len);
        const to = @min(from + per, pairs.len);
        workers[k] = try std.Thread.spawn(.{}, runBlock, .{ store, pairs[from..to], out[from..to] });
        started += 1;
    }
    runBlock(store, pairs[0..@min(per, pairs.len)], out[0..@min(per, pairs.len)]);
}

/// `cappedDist2` over every pair, into `out`, on the GPU through the raw
/// kernel `check_capped_dist2`. Fails (never falls back) when the build or
/// the machine has no such device: the strict path a differential test
/// needs.
pub fn cappedDistancesGpu(gpa: Allocator, backend: Device.Backend, store: *const GeometryStore, pairs: []const Pair, out: []i64) GpuError!void {
    assert(out.len == pairs.len);
    return switch (backend) {
        .cpu => error.NotBuilt,
        inline .cuda, .hip => |b| if (comptime built(b)) runGpu(b, gpa, store, pairs, out) else error.NotBuilt,
    };
}

/// The squared boundary distance of store rows `a` and `b`, each gap
/// clamped to `gap_cap`, so exact below `gap_cap²` and at least it
/// otherwise; -1 when either ring has a non-axis edge. Row `r`'s ring is
/// `xs[vert_start[r]..][0..vert_len[r]]`, likewise `ys`: the store's
/// columns, as host slices or device pointers. An axis segment is its own
/// box, so two are `gx² + gy²` apart, `g` the per-axis box gap.
pub fn cappedDist2(a: u32, b: u32, vert_start: anytype, vert_len: anytype, xs: anytype, ys: anytype) i64 {
    const a0 = vert_start[a];
    const an = vert_len[a];
    const b0 = vert_start[b];
    const bn = vert_len[b];
    if (!isRectilinear(a0, an, xs, ys) or !isRectilinear(b0, bn, xs, ys)) return -1;
    var best: i64 = std.math.maxInt(i64);
    var i: u32 = 0;
    while (i < an) : (i += 1) {
        const ia = a0 + i;
        const ja = a0 + if (i + 1 == an) 0 else i + 1;
        const axlo = @min(xs[ia], xs[ja]);
        const axhi = @max(xs[ia], xs[ja]);
        const aylo = @min(ys[ia], ys[ja]);
        const ayhi = @max(ys[ia], ys[ja]);
        var k: u32 = 0;
        while (k < bn) : (k += 1) {
            const ib = b0 + k;
            const jb = b0 + if (k + 1 == bn) 0 else k + 1;
            const gx = std.math.clamp(@max(axlo, @min(xs[ib], xs[jb])) - @min(axhi, @max(xs[ib], xs[jb])), 0, gap_cap);
            const gy = std.math.clamp(@max(aylo, @min(ys[ib], ys[jb])) - @min(ayhi, @max(ys[ib], ys[jb])), 0, gap_cap);
            best = @min(best, gx * gx + gy * gy);
        }
    }
    return best;
}

// ---- private ----

/// The device entry: one lane per pair; `pairs` interleaves `(a, b)`.
fn kernel(n: u64, pairs: g.GlobalPtr(u32), vert_start: g.GlobalPtr(u32), vert_len: g.GlobalPtr(u32), xs: g.GlobalPtr(i64), ys: g.GlobalPtr(i64), out: g.GlobalPtr(i64)) callconv(g.kernel_callconv) void {
    const i = g.globalIdX(block);
    if (i >= n) return;
    out[i] = cappedDist2(pairs[2 * i], pairs[2 * i + 1], vert_start, vert_len, xs, ys);
}

comptime {
    if (g.is_device) g.exportRaw("check_capped_dist2", &kernel);
}

fn runBlock(store: *const GeometryStore, pairs: []const Pair, out: []i64) void {
    const vs = store.poly_vert_start.items;
    const vl = store.poly_vert_len.items;
    const xs = store.verts_x.items;
    const ys = store.verts_y.items;
    for (pairs, out) |p, *o| o.* = cappedDist2(@backingInt(p.a), @backingInt(p.b), vs, vl, xs, ys);
}

/// Every edge axis-aligned (or zero-length).
fn isRectilinear(start: u32, n: u32, xs: anytype, ys: anytype) bool {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const j = if (i + 1 == n) 0 else i + 1;
        if (xs[start + i] != xs[start + j] and ys[start + i] != ys[start + j]) return false;
    }
    return true;
}

/// The work estimate the GPU threshold reads: edge pairs examined.
fn edgePairs(store: *const GeometryStore, pairs: []const Pair) u64 {
    const vl = store.poly_vert_len.items;
    var work: u64 = 0;
    for (pairs) |p| work += @as(u64, vl[@backingInt(p.a)]) * vl[@backingInt(p.b)];
    return work;
}

/// Whether this build compiled the kernel roots for `backend`; any spec
/// answers for the whole build.
fn built(comptime backend: Device.Backend) bool {
    const Auto = g.AutoKernel(geom.linalg.axpy);
    return switch (backend) {
        .cpu => false,
        .cuda => Auto.Cuda.available,
        .hip => Auto.Hip.available,
    };
}

fn runGpu(comptime backend: Device.Backend, gpa: Allocator, store: *const GeometryStore, pairs: []const Pair, out: []i64) GpuError!void {
    const tag: g.Backend = switch (backend) {
        .cpu => unreachable,
        .cuda => .cuda,
        .hip => .hip,
    };
    var k = try g.RawKernel("check_capped_dist2", tag).init(0);
    defer k.deinit();
    const flat = try gpa.alloc(u32, 2 * pairs.len);
    defer gpa.free(flat);
    for (pairs, 0..) |p, i| {
        flat[2 * i] = @backingInt(p.a);
        flat[2 * i + 1] = @backingInt(p.b);
    }
    const columns = .{ flat, store.poly_vert_start.items, store.poly_vert_len.items, store.verts_x.items, store.verts_y.items };
    var bufs: [6]@TypeOf(k).Buffer = undefined;
    var made: usize = 0;
    defer for (bufs[0..made]) |*buf| buf.free();
    inline for (columns, 0..) |col, c| {
        bufs[c] = try k.alloc(@max(1, std.mem.sliceAsBytes(col).len));
        made += 1;
        if (col.len > 0) try bufs[c].upload(col.ptr, std.mem.sliceAsBytes(col).len);
    }
    bufs[5] = try k.alloc(@max(1, out.len * @sizeOf(i64)));
    made += 1;
    if (pairs.len == 0) return;
    var n: u64 = pairs.len;
    var args: [7]g.interface.Arg = undefined;
    args[0] = g.interface.arg(&n);
    for (args[1..], &bufs) |*a, *buf| a.* = buf.argPtr();
    try k.launch(g.Dim3.linear(pairs.len, block), .{ .x = block }, 0, &args);
    try k.synchronize();
    try bufs[5].download(out.ptr, out.len * @sizeOf(i64));
}
