//! The field operator on the GPU: the host half of the row kernels
//! `extract_potential_rows` (matvec.zig) and `extract_field_rows`
//! (dielectric.zig). In: the operator's columns and near pairs, uploaded
//! once per solve in one allocation and one copy (geom.bulk). Out: `y = A x` per GMRES iteration, `x` up and `y` down;
//! `dot` and `nrm2` stay the host's strict folds (ARCHITECTURE.md, GPU).
//!
//! The device runs the same row bodies as the host threads, so a GPU solve
//! gives the CPU's bits. A build without device artifacts, or a machine
//! without the driver, gets no `Gpu` and the caller stays on the CPU.
//!
//! Contents:
//! - `pub const Gpu = struct`, `deinit`,
//!   `init(gpa: Allocator, device: Device, potential: *const Potential, field: ?*const Field) ?Gpu`,
//!   `apply(gpu: *Gpu, x: []const f64, y: []f64) g.Error!void`
//! - `pub const compiled: ?Device.Backend`
//! - `pub fn wanted(device: Device, panels: usize) bool`

const std = @import("std");
const assert = std.debug.assert;
const g = @import("gompute");
const artifacts = @import("gompute_kernels");
const geom = @import("geom");
const Device = geom.Device;
const matvec = @import("matvec.zig");
const Potential = matvec.Potential;
const Field = @import("dielectric.zig").Field;
const Allocator = std.mem.Allocator;

/// One device's copy of the operator, or none: a build may carry CUDA, HIP,
/// both or neither.
pub const Gpu = struct {
    engine: union(enum) {
        cuda: if (artifacts.has_cuda) Engine(.cuda) else void,
        hip: if (artifacts.has_hip) Engine(.hip) else void,
    },

    /// Loads the kernels and uploads every column in one copy (`gpa` holds
    /// the staging block only during `init`) on `device.backend`; null
    /// when that backend is not in this build or its driver or device is
    /// missing, so the caller stays on the CPU.
    pub fn init(gpa: Allocator, device: Device, potential: *const Potential, field: ?*const Field) ?Gpu {
        switch (device.backend) {
            .cpu => return null,
            .cuda => if (comptime artifacts.has_cuda) {
                const e = Engine(.cuda).init(gpa, potential, field) catch return null;
                return .{ .engine = .{ .cuda = e } };
            } else return null,
            .hip => if (comptime artifacts.has_hip) {
                const e = Engine(.hip).init(gpa, potential, field) catch return null;
                return .{ .engine = .{ .hip = e } };
            } else return null,
        }
    }

    pub fn deinit(gpu: *Gpu) void {
        switch (gpu.engine) {
            .cuda => |*e| if (comptime artifacts.has_cuda) e.deinit(),
            .hip => |*e| if (comptime artifacts.has_hip) e.deinit(),
        }
    }

    /// `y = A x` on the device: the potential rows, then the field rows.
    /// Asserts `x` and `y` as long as the panels.
    pub fn apply(gpu: *Gpu, x: []const f64, y: []f64) g.Error!void {
        switch (gpu.engine) {
            .cuda => |*e| if (comptime artifacts.has_cuda) return e.apply(x, y) else unreachable,
            .hip => |*e| if (comptime artifacts.has_hip) return e.apply(x, y) else unreachable,
        }
    }
};

/// The GPU backend this build carries device kernels for, CUDA first; null
/// in a build without device artifacts (`-Dgpu=false`).
pub const compiled: ?Device.Backend = if (artifacts.has_cuda) .cuda else if (artifacts.has_hip) .hip else null;

/// Whether a solve of `panels` panels should try the GPU: a GPU backend
/// asked for, and a dense product of at least `min_work.float` pairs.
pub fn wanted(device: Device, panels: usize) bool {
    return device.backend != .cpu and @as(u64, panels) * panels >= device.min_work.float;
}

// ---- private ----

fn Engine(comptime backend: g.Backend) type {
    return struct {
        const Self = @This();
        const Raw = g.RawByName(backend);
        /// Every region of the one device buffer: the columns, then the
        /// solve's `x` and `y`.
        const Col = enum { cx, cy, cz, radius, k, near_start, near_col, near_val, fcx, fcy, fcz, weight, scale, inverse_area, fnear_start, fnear_col, fnear_val, x, y };
        const cols = @typeInfo(Col).@"enum".field_names.len;

        potential_kernel: Raw,
        field_kernel: ?Raw,
        buffer: Raw.Buffer,
        offset: [cols]usize,
        /// Kernel arguments point into this, so it lives as long as the engine.
        address: [cols]usize,
        n: u64,
        rows: u64,
        first: u64,
        field_rows: u64,

        /// One allocation and one copy for every column (geom.bulk).
        fn init(gpa: Allocator, potential: *const Potential, field: ?*const Field) !Self {
            var pk = try g.rawKernelByName(backend, "extract_potential_rows", 0);
            errdefer pk.deinit();
            var fk: ?Raw = if (field != null) try g.rawKernelByName(backend, "extract_field_rows", 0) else null;
            errdefer if (fk) |*k| k.deinit();
            const bytes = std.mem.sliceAsBytes;
            const none: []const u8 = &.{};
            const f = field;
            const columns = [_][]const u8{
                bytes(potential.cx),                             bytes(potential.cy),                            bytes(potential.cz),
                bytes(potential.radius),                         bytes(potential.k),                             bytes(potential.near.start.items),
                bytes(potential.near.column.items),              bytes(potential.near.value.items),              if (f) |v| bytes(v.cx) else none,
                if (f) |v| bytes(v.cy) else none,                if (f) |v| bytes(v.cz) else none,               if (f) |v| bytes(v.weight) else none,
                if (f) |v| bytes(v.scale) else none,             if (f) |v| bytes(v.inverse_area) else none,     if (f) |v| bytes(v.near.start.items) else none,
                if (f) |v| bytes(v.near.column.items) else none, if (f) |v| bytes(v.near.value.items) else none,
            };
            const n = potential.cx.len;
            var e: Self = .{
                .potential_kernel = pk,
                .field_kernel = fk,
                .buffer = undefined,
                .offset = undefined,
                .address = undefined,
                .n = n,
                .rows = potential.near.rows(),
                .first = if (field) |v| v.first else n,
                .field_rows = if (field) |v| v.near.rows() else 0,
            };
            e.buffer = try geom.bulk.upload(Raw, &e.potential_kernel, gpa, &columns, &.{ n * @sizeOf(f64), n * @sizeOf(f64) }, &e.offset, &e.address);
            return e;
        }

        fn deinit(e: *Self) void {
            e.buffer.free();
            e.potential_kernel.deinit();
            if (e.field_kernel) |*k| k.deinit();
        }

        fn apply(e: *Self, x: []const f64, y: []f64) g.Error!void {
            assert(x.len >= e.n and y.len >= e.n);
            if (e.n == 0) return;
            try e.buffer.uploadAt(x.ptr, e.offset[@backingInt(Col.x)], e.n * @sizeOf(f64));
            const arg = g.interface.arg;
            if (e.rows > 0) {
                try e.potential_kernel.launch(.linear(e.rows, matvec.gpu_block), .{ .x = matvec.gpu_block }, 0, &.{
                    arg(&e.n),       arg(&e.rows),    e.at(.cx), e.at(.cy),
                    e.at(.cz),       e.at(.radius),   e.at(.k),  e.at(.near_start),
                    e.at(.near_col), e.at(.near_val), e.at(.x),  e.at(.y),
                });
            }
            if (e.field_kernel) |*fk| if (e.field_rows > 0) {
                try fk.launch(.linear(e.field_rows, matvec.gpu_block), .{ .x = matvec.gpu_block }, 0, &.{
                    arg(&e.n),           arg(&e.first),      arg(&e.field_rows), e.at(.fcx),
                    e.at(.fcy),          e.at(.fcz),         e.at(.weight),      e.at(.scale),
                    e.at(.inverse_area), e.at(.fnear_start), e.at(.fnear_col),   e.at(.fnear_val),
                    e.at(.x),            e.at(.y),
                });
            };
            // A synchronous copy on the NULL stream waits for both launches.
            const written = e.first + e.field_rows;
            try e.buffer.downloadAt(y.ptr, e.offset[@backingInt(Col.y)], written * @sizeOf(f64));
        }

        /// Region `col`'s device address as a kernel argument.
        fn at(e: *Self, col: Col) g.interface.Arg {
            return g.interface.arg(&e.address[@backingInt(col)]);
        }
    };
}
