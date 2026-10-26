//! The field operator on the GPU: the host half of the row kernels
//! `extract_potential_rows` (matvec.zig) and `extract_field_rows`
//! (dielectric.zig). In: the operator's columns and near pairs, uploaded
//! once per solve. Out: `y = A x` per GMRES iteration, `x` up and `y` down;
//! `dot` and `nrm2` stay the host's strict folds (ARCHITECTURE.md, GPU).
//!
//! The device runs the same row bodies as the host threads, so a GPU solve
//! gives the CPU's bits. A build without device artifacts, or a machine
//! without the driver, gets no `Gpu` and the caller stays on the CPU.
//!
//! Contents:
//! - `pub const Gpu = struct`, `deinit`,
//!   `init(device: Device, potential: *const Potential, field: ?*const Field) ?Gpu`,
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

/// One device's copy of the operator, or none: a build may carry CUDA, HIP,
/// both or neither.
pub const Gpu = struct {
    engine: union(enum) {
        cuda: if (artifacts.has_cuda) Engine(.cuda) else void,
        hip: if (artifacts.has_hip) Engine(.hip) else void,
    },

    /// Loads the kernels and uploads the columns on `device.backend`; null
    /// when that backend is not in this build or its driver or device is
    /// missing, so the caller stays on the CPU.
    pub fn init(device: Device, potential: *const Potential, field: ?*const Field) ?Gpu {
        switch (device.backend) {
            .cpu => return null,
            .cuda => if (comptime artifacts.has_cuda) {
                const e = Engine(.cuda).init(potential, field) catch return null;
                return .{ .engine = .{ .cuda = e } };
            } else return null,
            .hip => if (comptime artifacts.has_hip) {
                const e = Engine(.hip).init(potential, field) catch return null;
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
/// asked for, and a dense product of at least `min_gpu_work` pairs.
pub fn wanted(device: Device, panels: usize) bool {
    return device.backend != .cpu and @as(u64, panels) * panels >= device.min_gpu_work;
}

// ---- private ----

fn Engine(comptime backend: g.Backend) type {
    return struct {
        const Self = @This();
        const Raw = g.RawByName(backend);
        const Buffer = Raw.Buffer;
        const Col = enum { cx, cy, cz, radius, k, near_start, near_col, near_val, fcx, fcy, fcz, weight, scale, inverse_area, fnear_start, fnear_col, fnear_val, x, y };

        potential_kernel: Raw,
        field_kernel: ?Raw,
        buffer: [@typeInfo(Col).@"enum".field_names.len]?Buffer = @splat(null),
        n: u64,
        rows: u64,
        first: u64,
        field_rows: u64,

        fn init(potential: *const Potential, field: ?*const Field) g.Error!Self {
            var pk = try g.rawKernelByName(backend, "extract_potential_rows", 0);
            errdefer pk.deinit();
            var fk: ?Raw = if (field != null) try g.rawKernelByName(backend, "extract_field_rows", 0) else null;
            errdefer if (fk) |*k| k.deinit();
            var e: Self = .{
                .potential_kernel = pk,
                .field_kernel = fk,
                .n = potential.cx.len,
                .rows = potential.near.rows(),
                .first = if (field) |f| f.first else potential.cx.len,
                .field_rows = if (field) |f| f.near.rows() else 0,
            };
            errdefer e.freeBuffers();
            try e.upload(.cx, f64, potential.cx);
            try e.upload(.cy, f64, potential.cy);
            try e.upload(.cz, f64, potential.cz);
            try e.upload(.radius, f64, potential.radius);
            try e.upload(.k, f64, potential.k);
            try e.upload(.near_start, u32, potential.near.start.items);
            try e.upload(.near_col, u32, potential.near.column.items);
            try e.upload(.near_val, f64, potential.near.value.items);
            if (field) |f| {
                try e.upload(.fcx, f64, f.cx);
                try e.upload(.fcy, f64, f.cy);
                try e.upload(.fcz, f64, f.cz);
                try e.upload(.weight, f64, f.weight);
                try e.upload(.scale, f64, f.scale);
                try e.upload(.inverse_area, f64, f.inverse_area);
                try e.upload(.fnear_start, u32, f.near.start.items);
                try e.upload(.fnear_col, u32, f.near.column.items);
                try e.upload(.fnear_val, f64, f.near.value.items);
            }
            try e.alloc(.x, e.n * @sizeOf(f64));
            try e.alloc(.y, e.n * @sizeOf(f64));
            return e;
        }

        fn deinit(e: *Self) void {
            e.freeBuffers();
            e.potential_kernel.deinit();
            if (e.field_kernel) |*k| k.deinit();
        }

        fn apply(e: *Self, x: []const f64, y: []f64) g.Error!void {
            assert(x.len >= e.n and y.len >= e.n);
            if (e.n == 0) return;
            try e.buf(.x).upload(x.ptr, e.n * @sizeOf(f64));
            const arg = g.interface.arg;
            if (e.rows > 0) {
                try e.potential_kernel.launch(.linear(e.rows, matvec.gpu_block), .{ .x = matvec.gpu_block }, 0, &.{
                    arg(&e.n),                 arg(&e.rows),              e.buf(.cx).argPtr(), e.buf(.cy).argPtr(),
                    e.buf(.cz).argPtr(),       e.buf(.radius).argPtr(),   e.buf(.k).argPtr(),  e.buf(.near_start).argPtr(),
                    e.buf(.near_col).argPtr(), e.buf(.near_val).argPtr(), e.buf(.x).argPtr(),  e.buf(.y).argPtr(),
                });
            }
            if (e.field_kernel) |*fk| if (e.field_rows > 0) {
                try fk.launch(.linear(e.field_rows, matvec.gpu_block), .{ .x = matvec.gpu_block }, 0, &.{
                    arg(&e.n),                     arg(&e.first),                arg(&e.field_rows),         e.buf(.fcx).argPtr(),
                    e.buf(.fcy).argPtr(),          e.buf(.fcz).argPtr(),         e.buf(.weight).argPtr(),    e.buf(.scale).argPtr(),
                    e.buf(.inverse_area).argPtr(), e.buf(.fnear_start).argPtr(), e.buf(.fnear_col).argPtr(), e.buf(.fnear_val).argPtr(),
                    e.buf(.x).argPtr(),            e.buf(.y).argPtr(),
                });
            };
            // A synchronous copy on the NULL stream waits for both launches.
            const written = e.first + e.field_rows;
            try e.buf(.y).download(y.ptr, written * @sizeOf(f64));
        }

        fn buf(e: *Self, col: Col) *Buffer {
            return &e.buffer[@backingInt(col)].?;
        }

        fn alloc(e: *Self, col: Col, bytes: usize) g.Error!void {
            // A zero-byte allocation is not portable; every buffer is at
            // least one word.
            e.buffer[@backingInt(col)] = try e.potential_kernel.alloc(@max(bytes, 8));
        }

        fn upload(e: *Self, col: Col, comptime T: type, values: []const T) g.Error!void {
            try e.alloc(col, values.len * @sizeOf(T));
            if (values.len > 0) try e.buf(col).upload(values.ptr, values.len * @sizeOf(T));
        }

        fn freeBuffers(e: *Self) void {
            for (&e.buffer) |*b| if (b.*) |*live| {
                live.free();
                b.* = null;
            };
        }
    };
}
